# 组合操作: 供后台任务 (仪表盘的进度条)、命令行、定时维护共用。依赖 config.sh fetch.sh servers.sh jobs.sh logs.sh dns.sh auth.sh update.sh speed.sh。
#
# 事务: 任何会改动服务器/订阅/规则/DNS/设置的操作都在同一把锁下完成 [备份 → 变更 → 生成配置 → 校验 → 应用 → 失败回滚],
# 因此连续快速的操作不会互相覆盖备份, 坏配置绝不会留在磁盘上。每次操作都会写一条「操作记录」(不含任何密码/令牌)。

APPLY_STEPS='生成配置|校验配置|应用并重启|等待就绪'
TXN_FILES="servers.jsonl subs.tsv dns.conf rules.state custom-rulesets.tsv settings.env overrides.tsv autosites.tsv autosites.dismissed custom-apps.tsv site-domains.tsv hosts.tsv speedtest-custom.tsv prefs.json vps.jsonl apps.seen"
TXN_ERR=''; TXN_RESULT=''

op_wait_turn() { # 轮到我了吗? 等所有「更早创建且还在运行」的排队任务结束 (任务进程已死/卡住超过 5 分钟的忽略)
  [ -n "${JOB_ID:-}" ] && [ -f "$H/jobs/$JOB_ID.ticket" ] || return 0
  local mine other f id busy i=0
  IFS= read -r mine < "$H/jobs/$JOB_ID.ticket" || [ -n "$mine" ] || return 0     # (没有结尾换行时 read 返回 1 但已读到值)
  while [ "$i" -lt 1500 ]; do
    busy=0
    for f in "$H/jobs"/*.ticket; do
      [ -f "$f" ] || continue
      id=$(basename "$f" .ticket); [ "$id" = "$JOB_ID" ] && continue
      IFS= read -r other < "$f" 2>/dev/null || [ -n "$other" ] || continue
      [ "${other:-0}" -lt "$mine" ] || continue
      if grep -q '"state":"running"' "$H/jobs/$id.json" 2>/dev/null && [ -z "$(find "$H/jobs/$id.json" -mmin +5 2>/dev/null)" ]; then busy=1; break; fi
    done
    [ "$busy" = 0 ] && return 0
    sleep 0.2; i=$((i+1))
  done
  return 0
}
OP_LOCK_HELD=0     # 本进程是否持有 apply 锁 (锁是目录锁, 不可重入: 持有时嵌套的操作不能再拿, 见 proxy_locked)
op_lock() { op_wait_turn; local i=0; while ! mkdir "$H/.apply.lock" 2>/dev/null; do
    if [ -d "$H/.apply.lock" ] && [ -n "$(find "$H/.apply.lock" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then rmdir "$H/.apply.lock" 2>/dev/null || true; continue; fi
    i=$((i+1)); [ "$i" -gt 240 ] && return 1; sleep 0.5; done; OP_LOCK_HELD=1; }
op_unlock() { rmdir "$H/.apply.lock" 2>/dev/null || true; OP_LOCK_HELD=0; }

txn_backup() {
  local f
  for f in $TXN_FILES; do
    if [ -f "$H/$f" ]; then cp -p "$H/$f" "$H/$f.prev"; else rm -f "$H/$f.prev"; fi
  done
  if [ -L "$H/cloud/content" ]; then readlink "$H/cloud/content" > "$H/cloud/.content.prev"; else rm -f "$H/cloud/.content.prev"; fi     # 云端内容 (符号链接) 也能回滚
}
txn_restore() {
  local f t
  for f in $TXN_FILES; do
    if [ -f "$H/$f.prev" ]; then cp -p "$H/$f.prev" "$H/$f"; else rm -f "$H/$f"; fi
  done
  if [ -f "$H/cloud/.content.prev" ]; then t=$(cat "$H/cloud/.content.prev"); [ -d "$H/cloud/$t" ] && ln -sfn "$t" "$H/cloud/content"
  elif [ -d "$H/cloud" ]; then rm -f "$H/cloud/content"; fi
  load_settings
}
_txn_end() { # ok|fail 消息 [步骤序号]   后台任务里写进度, 命令行里直接打印; 成功时任务结果取 TXN_RESULT (调用方在 op_txn 之前设置)
  if [ -n "${JOB_ID:-}" ]; then if [ "$1" = ok ]; then job_ok "$2" "${3:-${TXN_RESULT:-}}"; else job_fail "$2" "${3:-0}"; fi
  elif [ "$1" = ok ]; then ok "$2"; else warn "$2"; fi
}

# 操作记录里的「详情」: 按操作类型写成 key=value (见 lib/logs.sh 的 kv), 人和程序都能读; 在变更之前调用, 所以能带上「原来的值」
_txn_detail() { # <变更函数> <参数…>
  local fn=$1 kvp k v out=''; shift
  case $fn in
    txn_import)        kv sub "${1:-}" mode "${2:-merge}" save "${TXN_SAVE:-}" ;;
    txn_subs_refresh)  kv subs "$(cut -d'|' -f1 "$1/index" 2>/dev/null | paste -sd, -)" ;;
    txn_delete)        kv tag "$1" role "$(srv_list | awk -F'\t' -v t="$1" '$1==t {print $5; exit}')" ;;
    txn_role)          kv tag "$1" from "$(srv_list | awk -F'\t' -v t="$1" '$1==t {print $5; exit}')" to "$2" ;;
    txn_subdel)        kv sub "$1" ;;
    txn_rules_toggle)  kv rule "$1" enabled "$2" ;;
    txn_rules_add)     kv name "$1" policy "$3" ;;
    txn_rules_delete)  kv rule "$1" ;;
    txn_dns_set)       for kvp in "$@"; do out="$out${out:+ }$(kv "${kvp%%=*}" "${kvp#*=}")"; done; printf '%s' "$out" ;;
    txn_dns_hosts)     kv action "$1" domain "$2" ip "${3:-}" new "${4:-}" ;;
    txn_settings)
      for kvp in "$@"; do
        k=${kvp%%=*}; v=${kvp#*=}
        case $k in LOG_HOURS) o=$(logs_hours) ;; ACCESS_LOG) o=${ACCESS_LOG:-1} ;; LOG_CORE) o=${LOG_CORE:-1} ;; AUTO_SITES) o=${AUTO_SITES:-0} ;; AUTO_UPDATE) o=${AUTO_UPDATE:-1} ;; LANG_UI) o=${LANG_UI:-zh} ;; *) o='' ;; esac
        out="$out${out:+ }$(kv setting "$k" from "$o" to "$v")"
      done; printf '%s' "$out" ;;
    txn_site_domain)   kv id "$1" action "$2" domain "$3" new "${4:-}" ;;
    txn_site_reset)    kv id "$1" ;;
    txn_app_custom_add) kv path "$1" state "$2" ;;
    txn_app_custom_delete) kv name "$1" ;;
    txn_content)       kv force "${TXN_FORCE:-}" seq_before "$(cloud_seq)" ;;
    txn_reset_official) reset_counts ;;
    txn_reset_undo)    kv backup "$(basename "$(reset_latest_backup)" 2>/dev/null)" ;;
    txn_sync_apply)    kv mode "$1" ;;
    txn_vps_save)      kv host "$1" ;;
    txn_none)          printf '' ;;
    *)                 printf '%s' "$*" ;;
  esac
}

# op_txn <描述> <变更函数> [参数…]   变更函数失败时可把原因放进 TXN_ERR
op_txn() {
  local desc=$1 fn=$2 rc line detail; shift 2
  detail=$(_txn_detail "$fn" "$@"); TXN_ERR=''
  op_lock || { _txn_end fail "另一个配置任务正在运行, 请稍后重试"; return 1; }
  txn_backup
  if ! "$fn" "$@"; then
    txn_restore; op_unlock
    oplog "${OP_WHO:-terminal}" "$desc" "$detail" error
    _txn_end fail "${TXN_ERR:-$desc 失败: 没有可应用的更改}"; return 1
  fi
  apply_config; rc=$?
  case $rc in
    0) op_unlock; oplog "${OP_WHO:-terminal}" "$desc" "$detail" ok
       _txn_end ok "$([ "${APPLY_CHANGED:-1}" = 1 ] && echo "$desc 完成, 配置已应用" || echo "$desc 完成 (配置无变化, 未重启)")"; return 0 ;;
    1) line=$(grep -m1 -iE 'error|fatal|decode|unknown|invalid|missing' "$H/check.log" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-200 || true)
       txn_restore; apply_config >/dev/null 2>&1 || true; op_unlock
       oplog "${OP_WHO:-terminal}" "$desc" "$detail" error
       _txn_end fail "配置未通过校验, 已撤销本次更改${line:+: $line}" 1; return 1 ;;
    *) txn_restore; apply_config >/dev/null 2>&1 || true; op_unlock
       oplog "${OP_WHO:-terminal}" "$desc" "$detail" error
       _txn_end fail "新配置无法启动, 已撤销本次更改并恢复原配置" 3; return 1 ;;
  esac
}

# ---- 变更函数 (在 op_txn 持锁期间运行) ----
txn_override() {
  local kind=$1 value=$2 state=$3 target=${4:-}
  ovr_valid "$kind" "$value" && ovr_target_valid "$target" || return 1
  case $state in follow|direct|pin|auto) ;; *) return 1 ;; esac
  if [ "$kind" = site ] && [ "$state" = follow ]; then ovr_delete site "$value"; autosite_forget "$value" dismiss
  else ovr_set "$kind" "$value" "$state" ack "$target"; fi
}
txn_apps_adopt() {
  local f=''
  if [ -n "${1:-}" ]; then f=$(mktemp); printf '%s\n' "$1" > "$f"; fi
  apps_adopt "$f"; [ -z "$f" ] || rm -f "$f"; return 0
}
txn_apps_scan() { apps_scan >/dev/null; }
txn_autosites_clear() { autosite_remove_all >/dev/null; }
txn_none()   { return 0; }
txn_import() { # sub mode   (内容来自 $JOB_BODY; 订阅信息来自 TXN_* 变量)
  local sub=${1:-} mode=${2:-merge} res a r
  res=$(SRV_SAVE=${TXN_SAVE:-} srv_import "$sub" "$mode" < "$JOB_BODY" 2>/dev/null) || return 1
  a=${res%% *}; r=${res#* }; r=${r%% *}
  [ $(( ${a:-0} + ${r:-0} )) -gt 0 ] || return 1
  if [ -n "$sub" ]; then
    sub_touch "$sub" "$(srv_list | awk -F'\t' -v s="$sub" '$6==s' | wc -l | tr -d ' ')" "${TXN_INTERVAL:-12}" "${TXN_USED:-0}" "${TXN_TOTAL:-0}" "${TXN_EXPIRE:-0}"
  fi
  rm -f "$JOB_BODY"
  if [ "${TXN_SAVE:-}" = 1 ]; then sync_after_save; fi                    # 勾选了「保存到云端」: 第一次用会自动打开云端同步, 马上上传
  return 0
}
txn_subs_refresh() { # <批次目录>  同一个事务里刷新一批订阅 (op_subs_refresh 准备好的: index 每行 名称|刷新间隔|已用|总量|到期|节点数, 第 N 行对应 N.jsonl); 一次应用、一次回滚
  local dir=$1 i=0 name iv used total expire t
  while IFS='|' read -r -u 3 name iv used total expire t; do
    i=$((i+1))
    cp "$dir/$i.jsonl" "$dir/$i.run" || return 1
    JOB_BODY="$dir/$i.run" TXN_INTERVAL=$iv TXN_USED=$used TXN_TOTAL=$total TXN_EXPIRE=$expire TXN_SAVE='' txn_import "$name" replace || { TXN_ERR="订阅「$name」没有可导入的节点"; return 1; }
  done 3< "$dir/index"
}
txn_delete() { srv_delete "$1"; }
txn_role()   { srv_set_role "$1" "$2"; }
txn_subdel() { sub_delete "$1"; }

txn_rules_toggle() { # tag 0|1
  rules_set_enabled "$1" "$2"; local rc=$?
  case $rc in 0) ;; 3) TXN_ERR="必选规则集不能停用"; return 1 ;; 2) TXN_ERR="找不到这个规则集"; return 1 ;; *) TXN_ERR="参数无效"; return 1 ;; esac
  [ "$2" = 1 ] && rules_update "$1" >/dev/null 2>&1 || true      # 新启用的先下载; 失败不致命 (生成配置时只引用已有文件)
  return 0
}
txn_rules_add() { # name url policy
  custom_rs_add "$1" "$2" "$3"; local rc=$?
  case $rc in 0) return 0 ;; 2) TXN_ERR="名称、链接或策略不合法 (链接必须是 http/https 的 .srs 规则集)" ;; 3) TXN_ERR="已经有同名的规则集" ;; *) TXN_ERR="规则集下载失败或不是有效的 .srs 文件" ;; esac
  return 1
}
txn_rules_delete() { custom_rs_delete "$1" || { TXN_ERR="找不到这个规则集"; return 1; }; }
txn_dns_set() { # KEY=VALUE…
  DNS_ERR=''
  dns_set "$@" || { TXN_ERR=${DNS_ERR:-DNS 设置无效}; return 1; }
  dns_load
  if [ "$DNS_ADS" = 1 ]; then rules_set_enabled geosite-ads 1 && rules_update geosite-ads >/dev/null 2>&1 || true
  else rules_set_enabled geosite-ads 0 || true; fi
  return 0
}
txn_dns_hosts() { dns_hosts_edit "$@" || { TXN_ERR=${DNS_ERR:-操作失败}; return 1; }; }        # <add|update|remove> 域名 IP [新域名]
txn_dns_hosts_reset() { dns_hosts_reset; }
txn_settings() { # KEY=VALUE… (LOG_HOURS ACCESS_LOG AUTO_SITES LANG_UI AUTO_UPDATE)
  local kv k v
  for kv in "$@"; do
    k=${kv%%=*}; v=${kv#*=}
    case $k in
      NETWORK_MODE)
        case $v in system|tun) ;; *) TXN_ERR="流量接管模式无效"; return 1 ;; esac
        if [ "$v" = tun ] && ! enhanced_supported; then TXN_ERR="Enhanced/TUN 需要 sing-box 1.12 或更新版本"; return 1; fi
        settings_set NETWORK_MODE "$v" ;;
      LOG_HOURS)   settings_set LOG_HOURS "$(logs_hours_clamp "$v")"; sed -i '' '/^LOG_DAYS=/d' "$H/settings.env" 2>/dev/null || true ;;
      AUTO_SITES)  case $v in 0|1) settings_set AUTO_SITES "$v" ;; *) TXN_ERR="参数无效"; return 1 ;; esac ;;
      ACCESS_LOG)  case $v in 0|1) settings_set ACCESS_LOG "$v" ;; *) TXN_ERR="参数无效"; return 1 ;; esac ;;
      LOG_CORE)    case $v in 0|1) settings_set LOG_CORE "$v" ;; *) TXN_ERR="参数无效"; return 1 ;; esac ;;
      AUTO_UPDATE) case $v in 0|1) settings_set AUTO_UPDATE "$v" ;; *) TXN_ERR="参数无效"; return 1 ;; esac ;;
      LANG_UI)     case " $I18N_LANGS " in *" $v "*) settings_set LANG_UI "$v" ;; *) TXN_ERR="不支持的语言"; return 1 ;; esac ;;
      *) TXN_ERR="参数无效"; return 1 ;;
    esac
  done
  load_settings
}

txn_app_custom_add() { apps_custom_add "$1" "$2" || { TXN_ERR=$APPS_ERR; return 1; }; }       # 路径 状态
txn_app_custom_delete() { apps_custom_delete "$1" || { TXN_ERR=$APPS_ERR; return 1; }; }

txn_site_domain() { sites_edit "$@" || { TXN_ERR=$SITES_ERR; return 1; }; }       # 条目id 操作 域名 [新域名]
txn_site_reset() { sites_reset "$1" || { TXN_ERR=$SITES_ERR; return 1; }; }

# ---- 恢复官方默认规则 (设置 → 代理 → 恢复默认规则) ----
# 清掉所有「自己改过的规则」, 回到官方默认: 以云端下发的官方内容 (签名校验) 为准 —— 不是云同步里保存的那一份 (那份可能已经带着错误的设置)。
# 不动: 服务器 / 订阅 / 账号 / 流量接管模式 / 端口 / 语言 / 日志设置 / 测速自定义目标 / 界面偏好。重置前把被清掉的文件打包到 $H/backups/ (最近 3 份), 可以在设置里撤销。
RESET_FILES="overrides.tsv autosites.tsv autosites.dismissed rules.state custom-rulesets.tsv custom-apps.tsv site-domains.tsv hosts.tsv dns.conf"
RESET_KEEP=3
reset_latest_backup() { ls -1 "$H"/backups/reset-*.tgz 2>/dev/null | sort | tail -1; }
_reset_lines() { [ -s "$H/$1" ] && awk 'NF {n++} END{print n+0}' "$H/$1" || echo 0; }
reset_selector_diff() { # 每个网站 / 服务的出口开关 (svc-*) 和兜底出口 (Final) 的选择是代理核心自己记住的 (cache.db), 不在上面那些文件里。
  # 打印「标签<TAB>现在<TAB>默认」(默认 = 当前 config.json 里每个开关的 default), 只列和默认不一样的; 核心没运行 / 读不到就什么都不打印。
  local px; [ -s "$H/config.json" ] || return 0
  px=$(clash GET /proxies 2>/dev/null) || return 0; [ -n "$px" ] || return 0
  printf '%s' "$px" | /usr/bin/perl -MJSON::PP -e '
    my $cfg = shift; local $/; my $p = eval { JSON::PP->new->decode(<STDIN>) } or exit 0;
    open my $fh, "<", $cfg or exit 0; my $c = eval { JSON::PP->new->decode(<$fh>) } or exit 0;
    for my $o (@{ $c->{outbounds} || [] }) {
      next unless ($o->{type} // "") eq "selector" && ($o->{tag} // "") =~ /^(svc-[a-z0-9-]+|Final)$/ && defined $o->{default};
      my $now = $p->{proxies}{ $o->{tag} }{now}; next unless defined $now && $now ne $o->{default};
      print "$o->{tag}\t$now\t$o->{default}\n";
    }' "$H/config.json" 2>/dev/null || true
}
reset_selectors_apply() { # <差异文件>  逐个切回默认 (热切换, 不重启核心); 打印切了几个
  local tag now def n=0
  while IFS=$'\t' read -r tag now def; do [ -n "$tag" ] && [ -n "$def" ] || continue
    [ -z "$(clash PUT "/proxies/$tag" "{\"name\":\"$(jesc "$def")\"}" 2>/dev/null)" ] && n=$((n + 1))
  done < "$1"
  echo "$n"
}
reset_selectors_restore() { # <差异文件>  把 reset_selectors_apply 改过的开关切回「现在」那一列 (撤销 / 回滚用; 开关已经不存在就跳过)
  local tag now def
  while IFS=$'\t' read -r tag now def; do [ -n "$tag" ] && [ -n "$now" ] || continue
    clash PUT "/proxies/$tag" "{\"name\":\"$(jesc "$now")\"}" >/dev/null 2>&1 || true
  done < "$1"
}
reset_counts() { # -> 一行 key=value: 各类「自己改过的」规则的数量 (确认框和操作记录用; 只数不动)
  local apps sites autos
  apps=$(awk -F'|' '$1=="app" && $4!="def" && $4!="new" {n++} END{print n+0}' "$H/overrides.tsv" 2>/dev/null); autos=$(_reset_lines autosites.tsv)
  sites=$(awk -F'|' '$1=="site" {n++} END{print n+0}' "$H/overrides.tsv" 2>/dev/null); sites=$(( ${sites:-0} - autos )); [ "$sites" -ge 0 ] || sites=0
  printf 'apps=%s sites=%s auto_sites=%s services=%s rulesets=%s toggles=%s custom_apps=%s domains=%s hosts=%s dns=%s auto_on=%s' \
    "${apps:-0}" "$sites" "$autos" "$(reset_selector_diff | awk 'NF {n++} END{print n+0}')" "$(_reset_lines custom-rulesets.tsv)" "$(_reset_lines rules.state)" "$(_reset_lines custom-apps.tsv)" "$(_reset_lines site-domains.tsv)" "$(_reset_lines hosts.tsv)" "$([ -s "$H/dns.conf" ] && echo 1 || echo 0)" "${AUTO_SITES:-0}"
}
reset_total() { local c t=0; for c in $(reset_counts); do case $c in auto_on=*) ;; *) t=$((t + ${c#*=})) ;; esac; done; echo "$t"; }
reset_preview_json() { # GET /api/settings/reset 的主体
  local c k v out='' b bt=0 bn='' total=0 logged=false
  for c in $(reset_counts); do k=${c%%=*}; v=${c#*=}; out="$out\"$k\":$v,"; [ "$k" = auto_on ] || total=$((total + v)); done
  b=$(reset_latest_backup); [ -n "$b" ] && { bn=$(basename "$b"); bt=${bn#reset-}; bt=${bt%.tgz}; }       # 文件名里就是时间 (epoch 秒)
  auth_logged_in && logged=true
  printf '%s"total":%s,"logged_in":%s,"content":{%s},"sync":{"enabled":%s,"auto":%s},"backup":%s' "$out" "$total" "$logged" "$(cloud_status_json)" \
    "$(sync_enabled && echo true || echo false)" "$(sync_auto && echo true || echo false)" "$([ -n "$b" ] && printf '{"name":"%s","time":%s}' "$(jesc "$bn")" "${bt:-0}" || echo null)"
}
reset_backup() { # 打包即将清掉的文件; 没有任何自定义内容就不建
  local f list='' d="$H/backups" ts out
  [ "$(reset_total)" -gt 0 ] || [ "${AUTO_SITES:-0}" = 1 ] || return 0                   # 本来就是默认状态: 没有什么可备份的
  for f in $RESET_FILES; do [ -f "$H/$f" ] && list="$list $f"; done
  mkdir -p "$d"; chmod 700 "$d" 2>/dev/null || true
  printf 'AUTO_SITES=%s\n' "${AUTO_SITES:-0}" > "$H/.reset.meta"
  reset_selector_diff > "$H/.reset.sel"                                                  # 出口开关原来的选择也放进备份 (撤销时切回去)
  list="$list .reset.sel"
  ts=$(now); out="$d/reset-$ts.tgz"
  # shellcheck disable=SC2086
  if ( cd "$H" && { COPYFILE_DISABLE=1 tar -czf "$out.new" --no-xattrs .reset.meta $list || COPYFILE_DISABLE=1 tar -czf "$out.new" .reset.meta $list; } ) 2>/dev/null; then mv "$out.new" "$out"; chmod 600 "$out" 2>/dev/null || true; else rm -f "$out.new"; fi
  rm -f "$H/.reset.meta"
  ls -1 "$d"/reset-*.tgz 2>/dev/null | sort | awk -v k="$RESET_KEEP" '{ a[NR] = $0 } END { for (i = 1; i <= NR - k; i++) print a[i] }' | while IFS= read -r f; do rm -f "$f"; done
  return 0
}
txn_reset_official() {
  local f src=baseline err='' rc
  job_step 0 10 "准备"
  rm -f "$H/.reset.sel"; reset_backup
  for f in $RESET_FILES; do rm -f "$H/$f"; done
  rm -f "$H/apps.seen" "$H/.autosite.off" "$H/.autosite.ev"                 # (自定义规则集的文件等重置成功之后再删, 见 op_rules_reset: 失败回滚时登记会恢复, 文件不能已经没了)
  settings_set AUTO_SITES 0; AUTO_SITES=0
  job_step 1 30 "下载规则集"
  cloud_content_install 1; rc=$?                      # 强制重新下载云端官方内容 (签名 + 校验和), 就算序号没变也换一份干净的
  case $rc in
    0) src=cloud ;;
    *) err=$CLOUD_ERR; [ -s "$H/cloud/content/SEQ" ] && src=cached                 # 连不上 / 没登录: 用本机已验证过的官方内容; 一份都没有就用随程序自带的基线
       [ "$rc" = 2 ] || cloud_state_set "$err" ;;
  esac
  [ -s "$H/.reset.sel" ] && reset_selectors_apply "$H/.reset.sel" >/dev/null          # 网站 / 服务的出口开关切回默认 (热切换)
  apps_scan >/dev/null                               # 像第一次安装那样重新识别应用: 推荐值来自官方内容
  rules_update >/dev/null 2>&1 || true               # 默认启用的规则集可能和以前不一样: 缺的先下载 (失败不致命)
  TXN_RESULT="{\"content\":\"$src\",\"seq\":$(cloud_seq),\"error\":\"$(jesc "$(_t "$err")")\"}"
  return 0
}
op_rules_reset() { # 重置; 成功后清掉已经没有登记的自定义规则集文件; 失败时连同刚建的备份一起撤掉 (不让人误以为可以撤销)
  local was now_b; was=$(reset_latest_backup)
  if op_txn "恢复官方默认规则" txn_reset_official; then rm -f "$H"/rules/custom-*.srs "$H/.reset.sel"; return 0; fi
  [ -s "$H/.reset.sel" ] && reset_selectors_restore "$H/.reset.sel"; rm -f "$H/.reset.sel"      # 失败回滚: 出口开关也切回原来的
  now_b=$(reset_latest_backup); [ -z "$now_b" ] || [ "$now_b" = "$was" ] || rm -f "$now_b"
  return 1
}
txn_reset_undo() { # 撤销最近一次重置: 把当时清掉的文件放回去
  local b t f
  b=$(reset_latest_backup); [ -n "$b" ] || { TXN_ERR="没有可以撤销的重置"; return 1; }
  tar -tzf "$b" 2>/dev/null | sed 's#^\./##' | grep -Ev '^\._' | grep -Evq '^(\.reset\.meta|\.reset\.sel|overrides\.tsv|autosites\.tsv|autosites\.dismissed|rules\.state|custom-rulesets\.tsv|custom-apps\.tsv|site-domains\.tsv|hosts\.tsv|dns\.conf)$' && { TXN_ERR="备份文件不完整, 不能撤销"; return 1; }
  t=$(mktemp -d); tar -xzf "$b" -C "$t" 2>/dev/null || { rm -rf "$t"; TXN_ERR="备份文件无法读取, 不能撤销"; return 1; }
  for f in $RESET_FILES; do rm -f "$H/$f"; [ -f "$t/$f" ] && cp -p "$t/$f" "$H/$f"; done
  [ "$(sed -n 's/^AUTO_SITES=//p' "$t/.reset.meta" 2>/dev/null | head -1)" = 1 ] && { settings_set AUTO_SITES 1; AUTO_SITES=1; }
  [ -s "$t/.reset.sel" ] && reset_selectors_restore "$t/.reset.sel"                       # 网站 / 服务的出口开关切回重置前的选择
  rm -rf "$t"; rm -f "$b"
  custom_rs_refresh_all; ovr_sync                    # 自定义规则集文件不在备份里: 按登记的链接重新下载
  return 0
}

op_apply() { op_txn "应用配置" txn_none; }

op_restart() {
  job_step 0 20 "重启服务"
  os_service_restart || { job_fail "核心未能重启 (Enhanced/TUN 需要管理员授权)" 0; return 1; }
  job_step 1 60 "等待服务就绪"
  if wait_port "$PORT" 15 && enhanced_ready; then proxy_sync_mode; oplog "${OP_WHO:-terminal}" "重启服务" "" ok; job_ok "服务已重启"; else oplog "${OP_WHO:-terminal}" "重启服务" "" error; job_fail "服务没有在 15 秒内启动, 运行 enana doctor 查看原因" 1; return 1; fi
}

# 开启 / 关闭系统代理 (仪表盘「开启系统代理」按钮和总开关共用): 后台任务 —— macOS 可能弹出管理员密码窗口, 等用户输入时不能卡住 HTTP 请求。
# 系统代理只在「System Proxy」接管方式下使用; Enhanced/TUN 保留用户现有的系统代理设置, 不会改动它。
op_sysproxy() { # on|off
  local want=${1:-on} rc msg
  case $want in on|off) ;; *) job_fail "参数无效" 0; return 1 ;; esac
  if [ "$want" = on ] && [ "${NETWORK_MODE:-system}" = tun ]; then job_ok "Enhanced/TUN 模式不使用系统代理" '{"method":"tun"}'; return 0; fi
  job_step 0 25 "修改系统代理"
  os_sysproxy_apply "$want"; rc=$?
  sysproxy_record "${OP_WHO:-dashboard}" "$want" "$rc"
  job_step 1 90 "确认结果"
  if [ "$rc" = 0 ]; then job_ok "$([ "$want" = on ] && echo '系统代理已指向 enana' || echo '系统代理已关闭')" "{\"method\":\"${SYSPROXY_METHOD:-}\"}"; return 0; fi
  case ${SYSPROXY_ERR:-} in
    user-canceled)   msg="已取消授权, 系统代理没有改动。需要时再点一次「开启系统代理」。" ;;
    wrong-password)  msg="管理员密码不正确, 系统代理没有改动。请再试一次。" ;;
    not-admin)       msg="当前 macOS 账户不是管理员, 无法修改系统代理。请用管理员账户登录 macOS 后再试。" ;;
    no-gui-session)  msg="找不到可以弹出密码窗口的桌面会话。请在这台 Mac 的桌面上打开仪表盘再试。" ;;
    not-authorized)  msg="macOS 没有允许 enana 弹出授权窗口。请在「系统设置 → 隐私与安全性 → 自动化」里允许后再试。" ;;
    no-network-service) msg="没有找到已启用的网络服务, 请先连接网络。" ;;
    *)               msg="系统代理没有改成功 (原因代码: ${SYSPROXY_ERR:-unknown}), 可以重试; 仍然失败请在「日志 → 导出」里导出诊断文件。" ;;
  esac
  job_fail "$msg" 0; return 1
}

op_update_rules() { # 规则集 (本地规则集文件变化后 sing-box 自动重载, 无需重启)
  job_step 0 5 "准备"
  QUIET=1
  if rules_update; then
    job_step 2 90 "应用规则集"
    local rc=1
    if op_lock; then apply_config >/dev/null 2>&1; rc=$?; op_unlock; fi
    if [ "$rc" != 0 ]; then job_fail "规则已下载, 但未应用到核心 (Enhanced/TUN 需要管理员授权)" 2; return 1; fi
    oplog "${OP_WHO:-terminal}" "更新规则集" "$RULES_CHANGED 个有变化, $RULES_FAILED 个失败" ok
    job_ok "规则集已更新 ($RULES_CHANGED 个有变化, $RULES_FAILED 个失败)" "{\"changed\":$RULES_CHANGED,\"failed\":$RULES_FAILED}"
  else oplog "${OP_WHO:-terminal}" "更新规则集" "全部下载失败" error; job_fail "所有规则集下载失败, 已保留旧规则" 1; return 1; fi
}

# 一个订阅单独走一个事务 (和以前每个订阅各一个事务时完全一样): 只有一个订阅要刷新, 或者合并刷新没有通过时用
_subs_refresh_one() { # <批次目录> <序号>
  local dir=$1 i=$2 name iv used total expire t rc saved_body=${JOB_BODY:-}
  IFS='|' read -r name iv used total expire t < <(sed -n "${i}p" "$dir/index")
  cp "$dir/$i.jsonl" "$dir/$i.run" || return 1
  JOB_BODY="$dir/$i.run"; TXN_INTERVAL=$iv; TXN_USED=$used; TXN_TOTAL=$total; TXN_EXPIRE=$expire; TXN_SAVE=''
  if op_txn "订阅「$name」刷新" txn_import "$name" replace; then info "订阅「$name」已刷新: $t 个节点"; rc=0
  else warn "订阅「$name」刷新后配置无效, 已保留旧节点"; rc=1; fi
  rm -f "$dir/$i.run"; JOB_BODY=$saved_body; return "$rc"
}
# 刷新已保存的订阅 (用 JXA 运行 importer.js, 无需 node). stale_only=1 时只刷新超过刷新间隔的。
# 先把所有要刷新的订阅都下载并解析好, 再放进「一个」事务里导入 + 应用 (以前每个订阅各应用一次, 调用方随后又应用一次): 内容没变的刷新不会改动 servers.jsonl,
# 配置也就不变、不重启核心; 合并的事务没通过 (比如某个订阅的节点让配置无效) 就退回逐个订阅各自一个事务, 好的订阅照样刷新, 坏的保留旧节点。
# 设置 SUBS_APPLIED=1 表示这次已经成功应用过配置 (调用方不用再应用一遍)。
op_subs_refresh() {
  local stale_only=${1:-0} name url updated count interval hdr out jsonl ua usage t dir n=0 i used total expire
  SUBS_APPLIED=0
  [ -s "$H/subs.tsv" ] || return 0
  dir=$(mktemp -d); : > "$dir/index"
  while IFS='|' read -r name url updated count interval _; do
    [ -n "$name" ] || continue
    if [ "$stale_only" = 1 ] && [ $(( $(now) - ${updated:-0} )) -lt $(( ${interval:-12} * 3600 )) ]; then continue; fi
    out=$(mktemp); hdr=$(mktemp); jsonl=''
    for ua in auto clash v2ray; do
      sub_fetch "$url" "$ua" "$out" "$hdr" || continue
      jsonl=$(os_import_subscription "$out" auto "$name" 2>/dev/null || true)
      [ -n "$jsonl" ] && break
    done
    if [ -n "$jsonl" ]; then
      n=$((n+1))
      printf '%s\n' "$jsonl" | srv_keep_roles "$name" > "$dir/$n.jsonl"           # 用户给订阅里某个节点固定的角色 (pin 等) 不会被改回自动
      usage=$(grep -i '^subscription-userinfo:' "$hdr" | head -1 | tr -d '\r')
      used=$(printf '%s' "$usage" | sed -n 's/.*download=\([0-9]*\).*/\1/p'); total=$(printf '%s' "$usage" | sed -n 's/.*total=\([0-9]*\).*/\1/p'); expire=$(printf '%s' "$usage" | sed -n 's/.*expire=\([0-9]*\).*/\1/p')
      t=$(printf '%s\n' "$jsonl" | wc -l | tr -d ' ')
      printf '%s|%s|%s|%s|%s|%s\n' "$name" "$interval" "$used" "$total" "$expire" "$t" >> "$dir/index"
    else warn "订阅「$name」刷新失败 (保留旧节点)"; fi
    rm -f "$out" "$hdr"
  done < "$H/subs.tsv"
  if [ "$n" = 1 ]; then _subs_refresh_one "$dir" 1 && SUBS_APPLIED=1
  elif [ "$n" -gt 1 ]; then
    if op_txn "订阅刷新 ($n 个)" txn_subs_refresh "$dir"; then
      SUBS_APPLIED=1
      while IFS='|' read -r -u 3 name interval used total expire t; do info "订阅「$name」已刷新: $t 个节点"; done 3< "$dir/index"
    else
      i=0; while [ "$i" -lt "$n" ]; do i=$((i+1)); if _subs_refresh_one "$dir" "$i"; then SUBS_APPLIED=1; fi; done
    fi
  fi
  rm -rf "$dir"
  return 0
}

# 终端「退出账号」: 关闭代理 + 令牌轮换 (+ purge 时清除离线登录缓存) + 让核心换上新令牌 (所有浏览器立即退出登录)
op_logout() { # [purge]
  local rc
  job_step 0 20 "退出账号"
  op_lock || { _txn_end fail "另一个配置任务正在运行, 请稍后重试" 0; return 1; }
  auth_logout
  job_step 1 50 "生成配置"
  apply_config >/dev/null 2>&1; rc=$?
  op_unlock
  oplog "${OP_WHO:-terminal}" "退出账号" "" "$([ "$rc" = 0 ] && echo ok || echo error)"
  if [ "$rc" = 0 ]; then _txn_end ok "已退出账号并关闭代理, 所有浏览器需要重新登录"; else _txn_end fail "代理已关闭、令牌已更换, 但核心没有成功重启, 运行 enana doctor 查看原因" 3; return 1; fi
}
# 仪表盘退出账号后的收尾: 令牌已经换了, 让核心也换上 (期间核心已是全部直连, 不会影响上网)
op_sync_secret() {
  local rc
  op_lock || { job_fail "另一个配置任务正在运行" 0; return 1; }
  apply_config >/dev/null 2>&1; rc=$?; op_unlock
  if [ "$rc" = 0 ]; then job_ok "完成"
  else job_fail "核心令牌尚未更新; Enhanced/TUN 需要管理员授权, 运行 enana doctor 查看原因" 1; return 1; fi
}

# 发送完整诊断给开发者 (用户在日志页点了按钮): 打包 → 上传, 完成后任务结果里带报告编号
op_diag_send() { # [小时]
  OP_WHO=dashboard
  job_step 0 20 "打包完整诊断"
  job_step 1 60 "上传"
  if diag_send_full "${1:-24}"; then job_ok "已发送, 报告编号 $DIAG_ID" "{\"id\":\"$DIAG_ID\"}"; return 0; fi
  case ${DIAG_ERR:-} in
    not-logged-in) job_fail "需要先登录" 1 ;;
    too-large)     job_fail "诊断文件太大, 请在设置里缩短日志保留时长后再试" 1 ;;
    http-429)      job_fail "今天发送的次数已经够多了, 请明天再试" 1 ;;
    *)             job_fail "发送失败 (${DIAG_ERR:-unknown}), 检查网络后重试" 1 ;;
  esac
  return 1
}

# 升级核心: 先下载, 用新核心校验现有配置, 通过才替换, 否则回退
op_core_upgrade() { # [版本|latest]  latest = 兼容清单里和当前 enana 兼容的最新核心 (没有清单就不升级); 写明版本号 = 照做 (有 SHA-256 才逐个校验)
  local old new want=${1:-latest}; old=$(core_version)
  job_step 0 10 "查询最新版本"
  if [ "$want" = latest ]; then
    core_manifest_refresh >/dev/null 2>&1 || true
    want=$(core_latest_compat)
    if [ -z "$want" ]; then
      oplog "${OP_WHO:-terminal}" "升级核心" "$(kv reason no-compatible-version current "$old")" error
      _txn_end fail "没有经过验证的兼容版本可升级, 保持 sing-box $old" 1; return 1
    fi
    if [ -n "$old" ] && ! version_gt "$want" "$old"; then _txn_end ok "已经是兼容的最新版本 sing-box $old"; return 0; fi
  fi
  cp "$SB" "$SB.old" 2>/dev/null
  job_step 1 30 "下载并校验新核心"
  if ! SINGBOX_VERSION=$want core_install chain >/dev/null 2>&1; then
    rm -f "$SB.old"; oplog "${OP_WHO:-terminal}" "升级核心" "$(kv reason download-failed from "$old" to "$want")" error; _txn_end fail "升级失败, 保持原版本 $old" 1; return 1
  fi
  job_step 2 70 "用新核心校验现有配置"
  if "$SB" check -c "$H/config.json" >/dev/null 2>&1; then
    job_step 3 85 "重启服务"
    if ! os_service_restart || ! wait_port "$PORT" 15 || ! enhanced_ready; then
      mv "$SB.old" "$SB"; os_service_restart >/dev/null 2>&1 || true
      oplog "${OP_WHO:-terminal}" "升级核心" "新版本未就绪, 已回退" error
      _txn_end fail "新版本未能启动, 已回退到 $old" 3; return 1
    fi
    rm -f "$SB.old"; proxy_sync_mode
    new=$(core_version); rm -f "$H/.core-version"; update_check force >/dev/null 2>&1 || true
    oplog "${OP_WHO:-terminal}" "升级核心" "$old → $new" ok; _txn_end ok "已升级到 sing-box $new"
  else
    mv "$SB.old" "$SB"; oplog "${OP_WHO:-terminal}" "升级核心" "新版本无法加载当前配置, 已回退" error
    _txn_end fail "新版本无法加载当前配置, 已回退到 $old" 2; return 1
  fi
}

# 更新 enana 本体: 重新运行 get.sh 的升级流程 (下载 → 校验 SHA-256 → 替换文件 → 重新生成配置)
op_self_update() {
  local rc line new
  job_step 0 5 "检查新版本"
  update_check force >/dev/null 2>&1 || true
  if ! update_has_new; then _txn_end ok "已经是最新版本 ($VERSION)"; return 0; fi
  [ -f "$H/get.sh" ] || { _txn_end fail "缺少升级脚本 get.sh, 请重新运行安装命令" 1; return 1; }
  if [ "${ENANA_PLATFORM:-darwin}" = windows ]; then
    job_step 1 30 "下载并校验新版本"
    if win_bridge self-update >> "$H/api.log" 2>&1; then
      IFS= read -r new < "$H/VERSION"; _txn_end ok "已更新到 v$new"; return 0
    else _txn_end fail "Windows 更新失败, 已保留当前版本 (详情见 api.log)" 2; return 1; fi
  fi
  # get.sh 在 ENANA_PROGRESS=1 时打印「##job 步骤序号 百分比 文字」, 这里转成任务进度
  ENANA_PROGRESS=1 ENANA_LANG="${I18N_LANG:-}" bash "$H/get.sh" --upgrade --yes 2>>"$H/api.log" | while IFS= read -r line; do
    case $line in '##job '*) set -- ${line#\#\#job }; job_step "$1" "$2" "${line#\#\#job $1 $2 }" ;; esac
  done
  rc=${PIPESTATUS[0]}
  if [ "$rc" = 0 ]; then
    IFS= read -r new < "$H/VERSION" 2>/dev/null || new=$VERSION
    oplog "${OP_WHO:-terminal}" "更新 enana" "$VERSION → $new" ok; _txn_end ok "已更新到 v$new"
  else oplog "${OP_WHO:-terminal}" "更新 enana" "失败" error; _txn_end fail "更新失败, 已保留当前版本 (详情见 $H/api.log)" 2; return 1; fi
}

# 每天一次的维护 (launchd 触发): 日志按天切分/压缩/按保留期清理 · 检查更新 · 每 3 天更新规则集与订阅
op_maintain() {
  local last=0
  logs_maintain; stats_purge
  update_check force >/dev/null 2>&1 || true
  auth_logged_in && op_txn "更新云端内容" txn_content >/dev/null 2>&1 || true            # 每天顺带检查一次云端内容更新 (没登录就跳过)
  auth_logged_in && plan_refresh >/dev/null 2>&1 || true                                 # 以及套餐 (订阅到期后界面提示会跟着变)
  [ "${AUTO_UPDATE:-1}" = 1 ] || return 0
  [ -f "$H/.maintain-rules" ] && IFS= read -r last < "$H/.maintain-rules"
  if [ $(( $(now) - ${last:-0} )) -ge 259200 ]; then
    rules_update >/dev/null 2>&1 || true
    op_subs_refresh 1
    # 订阅那一步成功应用过配置时, 它已经带上了刚下载的规则集 (规则集在它之前就下载好了), 这里不用再应用一遍; 没有订阅要刷新 / 没有刷新成功才单独应用一次
    # (配置和规则都没变的话 apply_config 什么也不做: 不重启核心, TUN 下也不要管理员授权)。
    if [ "${SUBS_APPLIED:-0}" != 1 ] && op_lock; then apply_config >/dev/null 2>&1 || true; op_unlock; fi
    now > "$H/.maintain-rules"
    oplog "${OP_WHO:-terminal}" "自动更新" "规则集与订阅" ok
  fi
  return 0
}

# 供 `enana _job <名称> <id> [参数…]` 在后台运行
job_dispatch() {
  JOB_NAME=$1; JOB_ID=$2; shift 2
  JOB_BODY="$H/jobs/$JOB_ID.body"
  case $JOB_NAME in
    apply)          op_apply ;;
    override)       op_txn "修改应用/网站策略" txn_override "$@" ;;
    apps-adopt)     op_txn "采用推荐设置" txn_apps_adopt "$@" ;;
    apps-scan)      op_txn "识别已安装的应用" txn_apps_scan ;;
    autosites-clear) op_txn "自动识别: 全部撤销" txn_autosites_clear ;;
    restart)        op_restart ;;
    sysproxy)       op_sysproxy "$@" ;;
    update-rules)   op_update_rules ;;
    servers-import) TXN_INTERVAL=${3:-}; TXN_USED=${4:-}; TXN_TOTAL=${5:-}; TXN_EXPIRE=${6:-}; TXN_SAVE=${7:-}; op_txn "导入服务器" txn_import "${1:-}" "${2:-merge}" ;;
    servers-delete) op_txn "删除服务器" txn_delete "$1" ;;
    servers-role)   op_txn "修改服务器角色" txn_role "$1" "$2" ;;
    sub-delete)     op_txn "删除订阅" txn_subdel "$1" ;;
    content-sync)   APPLY_BASE=2; TXN_FORCE=${1:-}; op_txn "更新云端内容" txn_content ;;
    rules-toggle)   APPLY_BASE=2; op_txn "启用/停用规则集" txn_rules_toggle "$1" "$2" ;;
    rules-add)      APPLY_BASE=2; op_txn "添加规则集" txn_rules_add "$1" "$2" "$3" ;;
    rules-delete)   op_txn "删除规则集" txn_rules_delete "$1" ;;
    dns-set)        APPLY_BASE=2; op_txn "修改 DNS 设置" txn_dns_set "$@" ;;
    dns-hosts)      op_txn "修改自定义解析" txn_dns_hosts "$@" ;;
    dns-hosts-reset) op_txn "清空自定义解析" txn_dns_hosts_reset ;;
    dns-bench)      dns_bench ;;
    vps-probe)      vps_probe_job "$@" ;;
    vps-provision)  vps_provision_job "$@" ;;
    vps-redetect)   vps_redetect_job "$@" ;;
    sync-push)      sync_push_job "$@" ;;
    sync-login)     sync_login_auto ;;
    sync-pull)      sync_pull_job "$@" ;;
    network-mode) op_txn "切换流量接管模式" txn_settings "NETWORK_MODE=$1" ;;
    settings-apply) APPLY_BASE=2; op_txn "修改设置" txn_settings "$@" ;;
    site-domain)    op_txn "修改网站域名" txn_site_domain "$@" ;;
    site-domain-reset) op_txn "重置网站域名" txn_site_reset "$1" ;;
    app-custom)     op_txn "添加自定义软件" txn_app_custom_add "$1" "$2" ;;
    app-custom-delete) op_txn "删除自定义软件" txn_app_custom_delete "$1" ;;
    rules-reset)    APPLY_BASE=2; op_rules_reset ;;
    rules-reset-undo) APPLY_BASE=2; op_txn "撤销恢复默认" txn_reset_undo ;;
    auth-sync)      op_sync_secret ;;
    auth-logout)    op_logout "$@" ;;
    self-update)    op_self_update ;;
    core-upgrade)   op_core_upgrade "${1:-latest}" ;;
    maintain)       op_maintain ;;
    diag-send)      op_diag_send "${1:-24}" ;;
    net-info)       op_net_refresh ;;
    speedtest)      speed_run "$1" ;;
    *) job_fail "未知任务: $JOB_NAME" ;;
  esac
}
