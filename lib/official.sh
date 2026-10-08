# 官方线路 (会员): 从云端取回 Pro 账号可用的官方节点, 与用户自己的服务器分开存放, 只进入自动线路 (AUTO) 池。
# 依赖 common.sh servers.sh session.sh plan.sh jobs.sh config.sh ops.sh。纯 bash 3.2 + macOS 自带工具。
#
#   $H/official.jsonl   每行 {"role":"auto","official":true,"outbound":{"type":…,"tag":"官方-…",…}} (权限 600)。
#                       不在 servers.jsonl 里 (srv_check_line 只收用户导入的行), 也不在配置快照 / 云端同步 / 导出的文件白名单里 (lib/snapshot.pl),
#                       节点的地址和凭据不会显示、不会导出、不会同步。节点必须交给本地核心才能使用, 所以这不是 DRM: 电脑的主人能从核心的配置里读到它们。
#   $H/official.state   key=value: ok=<云端上次确认节点的时间> try=<上次尝试> fails=<连续失败次数> entitled=0|1 planon=0|1 bad=<被拒绝的候选的校验和> bad_at=<时间> deferred=0|1
#
# 流程: 登录后 / 套餐刷新后 (official_kick) 和每分钟的 enana tick (official_tick, 间隔 4 小时, 失败退避) → GET /api/enana/v1/nodes (session_call)
#       → official.pl 校验并整理 → 与现有的 official.jsonl 逐字节比较: 没有变化 = 什么都不做 (不重新生成配置, 不重启核心);
#       有变化 = op_txn (备份 → 写入 → apply_config 校验 → 失败自动回滚)。
# 没有资格 (云端 entitled:false, 例如订阅到期) → 下一次成功同步时全部移除; 连不上云端 → 最多再保留 OFFICIAL_GRACE (3 天) 后移除。
# Enhanced/TUN 模式下每一次真正的配置变化都要管理员授权: 后台的 tick 不会自己弹授权框, 变化先记下 (deferred=1), 等用户在仪表盘里 (登录 / 刷新套餐) 时再应用。
OFFICIAL_PREFIX='官方-'
OFFICIAL_INTERVAL=14400        # 正常同步间隔: 4 小时
OFFICIAL_GRACE=259200          # 连不上云端时本机最多再保留 3 天
OFFICIAL_MAX=300               # 最多接受多少个节点

official_file() { printf '%s\n' "$H/official.jsonl"; }

official_state_get() { sed -n "s/^$1=//p" "$H/official.state" 2>/dev/null | head -1; }
official_state_set() { # key=value …   原子重写; 没提到的键保留
  local f="$H/official.state" tmp="$H/official.state.new" kv k
  mkdir -p "$H"; touch "$f"; cp "$f" "$tmp"
  for kv in "$@"; do k=${kv%%=*}; { grep -v "^$k=" "$tmp" || true; printf '%s\n' "$kv"; } > "$tmp.2" && mv "$tmp.2" "$tmp"; done
  chmod 600 "$tmp"; mv "$tmp" "$f"
}

official_list() { # 与 srv_list 同样的列 (tag type server port role sub), 另加第 7 列 = 1 (官方); 地址和端口留空: 界面不显示官方节点的地址
  [ -s "$H/official.jsonl" ] || return 0
  LC_ALL=C awk '
    {
      i = index($0, ",\"outbound\":{\"type\":\""); if (!i) next
      rest = substr($0, i + 21); t = substr(rest, 1, index(rest, "\"") - 1)
      r2 = substr(rest, length(t) + 2); tag = ""
      if (substr(r2, 1, 8) == ",\"tag\":\"") { r3 = substr(r2, 9); tag = substr(r3, 1, index(r3, "\"") - 1) }
      if (tag == "") next
      printf "%s\t%s\t\t\tauto\t\t1\n", tag, t
    }' "$H/official.jsonl"
}
official_has_tag() { official_list | awk -F'\t' -v t="$1" '$1==t {f=1} END{exit f?0:1}'; }
official_count() { official_list | wc -l | tr -d ' '; }

official_emit() { # role<TAB>tag<TAB>outbound_json, 与 srv_emit 同格式 (role 一律 auto); 给配置生成器用。
  # 和用户自己的服务器同名的官方行不输出: 用户的优先, 核心配置里不能出现重复的标签。
  [ -s "$H/official.jsonl" ] || return 0
  LC_ALL=C awk -v own="$H/servers.jsonl" '
    BEGIN {
      while ((getline l < own) > 0) {
        i = index(l, ",\"outbound\":{\"type\":\""); if (!i) continue
        rest = substr(l, i + 21); r2 = substr(rest, index(rest, "\"") + 1)
        if (substr(r2, 1, 8) == ",\"tag\":\"") { r3 = substr(r2, 9); taken[substr(r3, 1, index(r3, "\"") - 1)] = 1 }
      }
    }
    {
      i = index($0, ",\"outbound\":{\"type\":\""); if (!i) next
      ob = substr($0, i + 12, length($0) - (i + 12))
      rest = substr($0, i + 21); r2 = substr(rest, index(rest, "\"") + 1); tag = ""
      if (substr(r2, 1, 8) == ",\"tag\":\"") { r3 = substr(r2, 9); tag = substr(r3, 1, index(r3, "\"") - 1) }
      if (tag == "" || (tag in taken)) next
      printf "auto\t%s\t%s\n", tag, ob
    }' "$H/official.jsonl"
}

# ---------- 整理云端的响应 ----------
official_check_lines() { # <文件>  每一行都必须是合法的官方节点行 (和 official.pl 的输出重复检查一遍: 以云端内容为输入的最后一道闸门)
  local f=$1 re bad
  re='^\{"role":"auto","official":true,"outbound":\{"type":"(trojan|http|socks|tuic|hysteria2|vless|vmess|shadowsocks|anytls)","tag":"'"$OFFICIAL_PREFIX"'[^"\\[:cntrl:]]{1,96}",.+\}\}$'
  bad=$(LC_ALL=C grep -Evc "$re" "$f" || true)
  [ "${bad:-1}" = 0 ] || return 1
  ! LC_ALL=C grep -Eq '"detour"|@CERTS@' "$f"
}
official_ingest() { # <响应文件> <输出文件>  0 = 有资格且有节点 (已写出)  3 = 云端说没有资格  4 = 有资格但没有可用节点  1 = 响应不对
  local noany=0 rc
  sb_ver 2>/dev/null || true
  if [ "${SB_MAJOR:-0}" -eq 1 ] && [ "${SB_MINOR:-12}" -lt 12 ]; then noany=1; fi        # 本机核心太旧, 不认识 anytls: 整个配置会校验失败
  /usr/bin/perl "$LIB/official.pl" ingest "$1" "$2" "$OFFICIAL_PREFIX" "$OFFICIAL_MAX" "$noany"; rc=$?
  if [ "$rc" = 0 ]; then official_check_lines "$2" || rc=1; fi
  return $rc
}

# ---------- 应用 ----------
txn_official_apply() { # op_txn 持锁期间运行: OFFICIAL_CAND = 候选文件, "-" = 清空
  if [ "$OFFICIAL_CAND" = - ]; then rm -f "$H/official.jsonl"
  else cp "$OFFICIAL_CAND" "$H/official.jsonl.new" && chmod 600 "$H/official.jsonl.new" && mv "$H/official.jsonl.new" "$H/official.jsonl"; fi
}
official_sum() { cksum < "$1" | cut -d' ' -f1; }
official_apply() { # <候选文件|-> 内容和现有的逐字节相同 = 什么都不做 (不重新生成配置, 不重启); 0 = 已应用或无需应用  1 = 配置没有通过校验 / 核心没起来 (已回滚)
  local cand=$1 cur="$H/official.jsonl" sum='' bad badat now_
  now_=$(now)
  if [ "$cand" = - ]; then [ -e "$cur" ] || { official_state_set deferred=0; return 0; }
  else [ -f "$cur" ] && cmp -s "$cur" "$cand" && { official_state_set deferred=0; return 0; }
    sum=$(official_sum "$cand"); bad=$(official_state_get bad); badat=$(official_state_get bad_at)
    # 上次就是这一份被配置校验拒绝的: 一天之内不再重试 (否则每个周期都会重新生成配置、重启核心)
    if [ -n "$bad" ] && [ "$bad" = "$sum" ] && [ $(( now_ - ${badat:-0} )) -lt 86400 ]; then return 1; fi
  fi
  if [ "${NETWORK_MODE:-system}" = tun ] && [ "${OP_WHO:-auto}" = auto ]; then
    official_state_set deferred=1; oplog auto "官方线路更新待应用" "$(kv mode tun note "applies when the dashboard is open; TUN changes need administrator authorization")" ok
    return 0
  fi
  OFFICIAL_CAND=$cand; OFFICIAL_N=0; [ "$cand" = - ] || OFFICIAL_N=$(wc -l < "$cand" | tr -d ' ')
  if OP_WHO=${OP_WHO:-auto} op_txn "官方线路同步" txn_official_apply; then
    rm -f "$H/official.jsonl.prev"           # op_txn 的备份里还有被替换 / 被移除的节点: 成功之后不再留着凭据副本
    official_state_set deferred=0 bad= bad_at=; return 0
  fi
  [ -z "$sum" ] || official_state_set bad="$sum" bad_at="$now_"
  return 1
}

official_expire_check() { # 本机宽限期: 云端上次确认节点之后超过 OFFICIAL_GRACE 就移除 (不联网, 很便宜)
  [ -s "$H/official.jsonl" ] || return 0
  local ok; ok=$(official_state_get ok)
  if [ -z "$ok" ]; then official_state_set ok="$(now)"; return 0; fi        # 状态丢了: 从现在开始计宽限期
  [ $(( $(now) - ok )) -gt "$OFFICIAL_GRACE" ] || return 0
  official_apply - || true
}

plan_official_on() { # 缓存的套餐里官方线路现在是否可用 (1 / 0)
  [ -s "$H/plan.json" ] || { printf 0; return 0; }
  case $(sed -n 's/.*"official_proxy":{\([^}]*\)}.*/\1/p' "$H/plan.json" | head -1) in *'"enabled":true'*) printf 1 ;; *) printf 0 ;; esac
}

official_lock() {
  mkdir "$H/.official.lock" 2>/dev/null && return 0
  if [ -n "$(find "$H/.official.lock" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then rmdir "$H/.official.lock" 2>/dev/null || true; mkdir "$H/.official.lock" 2>/dev/null && return 0; fi
  return 1
}
official_unlock() { rmdir "$H/.official.lock" 2>/dev/null || true; }

official_sync() { # 向云端取一次官方节点并应用。0 = 完成 (含「没有变化」)  1 = 没有完成 (没登录 / 连不上 / 云端回了意外的内容 / 配置未通过校验)
  local out cand code rc now_ fails planon
  auth_logged_in && [ -n "$(session_id)" ] || return 1
  official_lock || return 1
  now_=$(now); out=$(mktemp); cand=$(mktemp)
  code=$(CLOUD_MAXTIME=12 CLOUD_CONNECT=4 session_call "$out" GET /api/enana/v1/nodes)
  if [ "$code" = 200 ]; then official_ingest "$out" "$cand"; rc=$?; else rc=9; fi
  rm -f "$out"
  planon=$(plan_official_on)
  case $rc in
    0) official_state_set ok="$now_" try="$now_" fails=0 entitled=1 planon="$planon"; official_apply "$cand"; rc=$? ;;
    3) official_state_set ok="$now_" try="$now_" fails=0 entitled=0 planon="$planon"; official_apply -; rc=$? ;;       # 云端明确说没有资格 (订阅到期 / 邮箱未验证): 全部移除
    4) official_state_set try="$now_" fails=0 entitled=1 planon="$planon"; official_expire_check; rc=0 ;;               # 有资格但云端暂时没有节点: 保留现有的, 由宽限期兜底
    *) fails=$(official_state_get fails); fails=$(( ${fails:-0} + 1 )); [ "$fails" -le 8 ] || fails=8
       official_state_set try="$now_" fails="$fails" planon="$planon"
       [ "$fails" != 1 ] || oplog "${OP_WHO:-auto}" "官方线路同步" "$(kv step fetch http "$code" rc "$rc")" error        # 只记第一次失败 (之后按退避重试, 不刷屏)
       official_expire_check; rc=1 ;;
  esac
  rm -f "$cand"; official_unlock
  return $rc
}

official_due() { # 到点了吗: 正常 4 小时一次; 失败后退避 15 分钟 → 30 分钟 → 1 小时 → 2 小时 → 4 小时
  local last fails step
  last=$(official_state_get try); fails=$(official_state_get fails); last=${last:-0}; fails=${fails:-0}
  step=$OFFICIAL_INTERVAL
  if [ "$fails" -gt 0 ]; then step=$(( 900 << (fails > 5 ? 4 : fails - 1) )); [ "$step" -le "$OFFICIAL_INTERVAL" ] || step=$OFFICIAL_INTERVAL; fi
  [ $(( $(now) - last )) -ge "$step" ]
}
official_tick() { # 由 enana tick 每分钟调用: 几乎总是瞬间返回, 只有到点了才联网
  auth_logged_in || return 0
  if [ -z "$(session_id)" ]; then official_expire_check; return 0; fi        # 离线登录没有云端会话: 不联网, 但宽限期照样计算
  if official_due; then OP_WHO=auto official_sync || true; else official_expire_check; fi
  return 0
}
official_kick() { # 套餐刷新成功之后调用: 套餐里官方线路的状态和上次同步时不一样了 (刚买了 Pro / 订阅到期 / 节点上线), 或者有等着用户在场时才应用的更新 → 马上后台同步一次
  local want have def last
  type job_spawn >/dev/null 2>&1 || return 0
  auth_logged_in && [ -n "$(session_id)" ] || return 0
  want=$(plan_official_on); have=$(official_state_get planon); def=$(official_state_get deferred)
  [ "$want" != "${have:-0}" ] || [ "${def:-0}" = 1 ] || return 0
  last=$(official_state_get try)
  [ $(( $(now) - ${last:-0} )) -ge 60 ] || return 0
  job_spawn official-sync "$APPLY_STEPS" >/dev/null 2>&1 || true
}
official_job() { # enana _job official-sync (op_txn 已经写好了任务结果; 没走到 op_txn 时在这里补上)
  local rc
  official_sync; rc=$?
  grep -q '"state":"running"' "$H/jobs/${JOB_ID:-x}.json" 2>/dev/null || return $rc
  if [ "$rc" = 0 ]; then job_ok "完成"; else job_fail "官方线路同步没有完成, 稍后会自动重试" 1; fi
  return $rc
}
