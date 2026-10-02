# sing-box 配置生成与应用。依赖 common servers apps(json_list) auth dns fetch(rules_*) 与 os 适配层。
#
# 出站结构:
#   direct                      直连
#   <用户的服务器…>              来自 servers.jsonl
#   AUTO   (urltest)            自动池里最快的节点; 只有别的节点快过当前 50ms 以上才切换 (tolerance=50)
#   PIN    (selector)           固定出口: 只含 role=pin 的服务器, 故障时不会漂移到别的国家 (避免账号风控)
#   Global (selector)           「自动线路」: AUTO + 自动池节点 + 固定出口节点, 可在仪表盘手动指定某个节点
#   svc-<id> (selector)         每个网站/服务一个开关, 选项 PIN / Global / direct (仪表盘一键热切换); 固定出口有 2 个以上时还多出
#                               PINAUTO 和每个固定出口各一项 (这个网站固定走哪一个固定出口 / 在固定出口里自动选一个)
#   PINAUTO (urltest)           固定出口有 2 个以上时才有: 在固定出口里自动选最快的一个 (应用 / 网站可以选它, 不影响 PIN 本身)
#   direct-mode / direct-lan / direct-site / direct-app / direct-cn   都是直连 (类型 direct), 只是名字不同: 日志里的出口名就说明了「为什么直连」
#                               代理总开关关闭 / 本机和局域网 / 你把某个网站设为直连 / 你把某个应用设为直连 (关) / 国内规则;  单独的 direct = 策略选了直连
#   Final  (selector)           其余海外流量的兜底策略
# 路由优先级: 全局直连模式 → 内网 → 你的覆盖(应用/网站) → 屏蔽广告(可选) → 目录里的网站(固定出口类在前) → 自定义规则集
#            → 国内直连 → 海外网站(兜底) → 解析后按 IP 判断国内直连 → 兜底。
# 没有配置任何服务器时, PIN/Global 只含 direct, 所有流量直连 (不会因为空配置而断网)。

sb_ver() { # 设置 SB_MAJOR SB_MINOR
  local v; v=$(core_version 2>/dev/null || true); v=${v:-0.0}
  SB_MAJOR=${v%%.*}; SB_MINOR=${v#*.}; SB_MINOR=${SB_MINOR%%.*}
  case $SB_MAJOR in ''|*[!0-9]*) SB_MAJOR=0 ;; esac; case $SB_MINOR in ''|*[!0-9]*) SB_MINOR=0 ;; esac
}

catalog_list() { local l; [ -f "$(content_file services.conf)" ] || return 0; while IFS= read -r l; do case $l in ''|'#'*|[[:space:]]*) ;; *) printf '%s\n' "$l" ;; esac; done < "$(content_file services.conf)"; }

groups_json() { # groups.conf -> "groups":{id:名称},"order":[id…]
  awk -F'|' 'BEGIN{g="";o=""} /^[ \t]*(#|$)/{next} {gsub(/["\\]/,"",$2); g=g (g==""?"":",") "\"" $1 "\":\"" $2 "\""; o=o (o==""?"":",") "\"" $1 "\""} END{printf "\"groups\":{%s},\"order\":[%s]", g, o}' "$(content_file groups.conf)" 2>/dev/null
}

gen_catalog_json() { # $1 = 临时目录 (含 cat) -> $H/ui/catalog.json (中文) + catalog.<语言>.json (其它语言) 与 env.json (仪表盘读取)
  local l keys
  mkdir -p "$H/ui"
  printf '{"schema":3,%s,"entries":[%s]}\n' "$(groups_json)" "$(cat "$1/cat")" > "$H/ui/catalog.json"
  keys="name|desc|$(awk -F'|' '!/^[ \t]*(#|$)/{printf "%s|", $1}' "$(content_file groups.conf)" 2>/dev/null)"        # 名称 / 说明 / 各分组的显示名
  for l in $I18N_LANGS; do
    [ "$l" = zh ] && continue; [ -f "$DATA/i18n/$l.tsv" ] || continue
    LC_ALL=C awk -v tbl="$(i18n_tbl "$l")" -v keys="$keys" -f "$LIB/i18n-lib.awk" -f "$LIB/i18n-json.awk" "$H/ui/catalog.json" > "$H/ui/catalog.$l.json.new" && mv "$H/ui/catalog.$l.json.new" "$H/ui/catalog.$l.json"
  done
  printf '{"apiPort":%s,"proxyPort":%s,"uiPort":%s,"apiBase":"","clashBase":"http://127.0.0.1:%s","version":"%s"}\n' "$API_PORT" "$PORT" "$UI_PORT" "$UI_PORT" "$VERSION" > "$H/ui/env.json"
}

seqn() { local i=1; while [ "$i" -le "${1:-0}" ]; do printf '%s ' "$i"; i=$((i + 1)); done; }      # 1..N (N=0 什么也不打印; BSD 的 seq 1 0 会倒着数)

gen_config() { # gen_config [--no-rulesets]  -> $H/config.json.new ; 返回 0
  local norules=0 T role tag ob dns_block='' resolver='' rs_defs='' i ctag cname cpol lvl logoff secret ads=0
  [ "${1:-}" = "--no-rulesets" ] && norules=1
  sb_ver; dns_load
  T=$(mktemp -d)
  : > "$T/ob"; : > "$T/pins"; : > "$T/autos"; : > "$T/have"; : > "$T/cust"
  while IFS=$'\t' read -r role tag ob; do
    case $role in pin) printf '%s\n' "$tag" >> "$T/pins" ;; auto) printf '%s\n' "$tag" >> "$T/autos" ;; *) continue ;; esac
    printf '%s\n' "$ob" >> "$T/ob"
  done < <(srv_emit)

  local pin_list pin_def glob_list glob_def
  if [ -s "$T/pins" ]; then pin_list=$(json_list < "$T/pins"); pin_def=$(head -1 "$T/pins"); else pin_list='"direct"'; pin_def=direct; fi
  if [ -s "$T/autos" ]; then
    printf '{"type":"urltest","tag":"AUTO","outbounds":[%s],"url":"http://www.gstatic.com/generate_204","interval":"10m","tolerance":50,"idle_timeout":"30m"}\n' "$(json_list < "$T/autos")" >> "$T/ob"
    glob_list="\"AUTO\",$(json_list < "$T/autos")"; [ -s "$T/pins" ] && glob_list="$glob_list,$pin_list"; glob_def=AUTO
  elif [ -s "$T/pins" ]; then glob_list=$pin_list; glob_def=$pin_def
  else glob_list='"direct"'; glob_def=direct; fi
  printf '{"type":"selector","tag":"PIN","outbounds":[%s],"default":"%s","interrupt_exist_connections":true}\n' "$pin_list" "$pin_def" >> "$T/ob"
  printf '{"type":"selector","tag":"Global","outbounds":[%s],"default":"%s","interrupt_exist_connections":true}\n' "$glob_list" "$glob_def" >> "$T/ob"
  printf '{"type":"selector","tag":"Final","outbounds":["Global","PIN","direct"],"default":"Global","interrupt_exist_connections":true}\n' >> "$T/ob"

  # 测速专用入站 + 选择器 (只有配置了节点才有): 只给仪表盘「测速」页用, 不影响用户流量; 见 lib/speed.sh
  local have_nodes=0 speed_in=''
  if [ -s "$T/pins" ] || [ -s "$T/autos" ]; then
    have_nodes=1
    printf '{"type":"selector","tag":"SPEEDTEST","outbounds":["direct","PIN","Global",%s],"default":"direct"}\n' "$(cat "$T/pins" "$T/autos" | json_list)" >> "$T/ob"
    speed_in=",{\"type\":\"mixed\",\"tag\":\"speed-in\",\"listen\":\"127.0.0.1\",\"listen_port\":$SPEED_PORT}"
  fi

  # 规则集: 规则库里启用且已下载的 + 用户自定义的 (只引用非空文件)
  local tag_rs
  if [ "$norules" = 0 ]; then
    while IFS='|' read -r tag_rs _; do
      [ -s "$H/rules/$tag_rs.srs" ] || continue
      rs_defs="$rs_defs${rs_defs:+,}{\"type\":\"local\",\"tag\":\"$tag_rs\",\"format\":\"binary\",\"path\":\"$H/rules/$tag_rs.srs\"}"
      printf '%s\n' "$tag_rs" >> "$T/have"
    done < <(rules_wanted)
    if [ -s "$H/custom-rulesets.tsv" ]; then
      while IFS='|' read -r ctag cname cpol _; do
        [ -s "$H/rules/custom-$ctag.srs" ] || continue
        rs_defs="$rs_defs${rs_defs:+,}{\"type\":\"local\",\"tag\":\"custom-$ctag\",\"format\":\"binary\",\"path\":\"$H/rules/custom-$ctag.srs\"}"
        printf '%s|%s|%s\n' "$ctag" "$cname" "$cpol" >> "$T/cust"
      done < "$H/custom-rulesets.tsv"
    fi
  fi
  # 固定出口有 2 个以上时: 每个应用 / 网站可以指定走哪一个固定出口 (ovr-pin-<序号>, 最多 16 个) 或「在固定出口里自动选」(ovr-pinauto → PINAUTO)。
  # 规则集的内容由 ovr_sync 按用户的设置写成文件, 切换时核心自己监视文件变化, 不用重启
  : > "$T/pinx"; npinx=0; pinx_opts=''
  if [ -s "$T/pins" ] && [ "$(wc -l < "$T/pins" | tr -d ' ')" -ge 2 ]; then
    head -16 "$T/pins" > "$T/pinx"; npinx=$(wc -l < "$T/pinx" | tr -d ' ')
    printf '{"type":"urltest","tag":"PINAUTO","outbounds":[%s],"url":"http://www.gstatic.com/generate_204","interval":"10m","tolerance":50,"idle_timeout":"30m"}\n' "$(json_list < "$T/pinx")" >> "$T/ob"
    pinx_opts=",\"PINAUTO\",$(json_list < "$T/pinx")"
  fi
  for i in direct appdirect pin pinauto auto $(seqn "$npinx"); do
    case $i in [0-9]*) i="pin-$i" ;; esac
    rs_defs="$rs_defs${rs_defs:+,}{\"type\":\"local\",\"tag\":\"ovr-$i\",\"format\":\"source\",\"path\":\"$H/rules/ovr-$i.json\"}"
  done

  # 服务目录 -> 每项一个开关 + 路由规则 (固定出口类在前, 其它在后)
  : > "$T/sel"; : > "$T/r1"; : > "$T/r2"; : > "$T/cat"
  LC_ALL=C awk -f "$LIB/catalog.awk" -v domf="$T/catdomains" -v pinx="$pinx_opts" -v have="$T/have" -v sel="$T/sel" -v r1="$T/r1" -v r2="$T/r2" -v catf="$T/cat" -v edits="$H/site-domains.tsv" "$(content_file services.conf)"
  cat "$T/sel" >> "$T/ob"
  [ -f "$T/catdomains" ] && sort -u "$T/catdomains" > "$H/catalog.domains" || : > "$H/catalog.domains"
  while IFS='|' read -r ctag cname cpol; do   # 自定义规则集: 各自一个开关
    [ -n "$ctag" ] || continue
    printf '{"type":"selector","tag":"svc-rs-%s","outbounds":["PIN","Global","direct"%s],"default":"%s","interrupt_exist_connections":true}\n' "$ctag" "$pinx_opts" "$(case $cpol in pin) echo PIN ;; direct) echo direct ;; *) echo Global ;; esac)" >> "$T/ob"
    printf '{"rule_set":["custom-%s"],"action":"route","outbound":"svc-rs-%s"}\n' "$ctag" "$ctag" >> "$T/r2"
    printf '%s{"id":"rs-%s","tag":"svc-rs-%s","name":"%s","group":"custom","default":"%s","desc":"自定义规则集","domains":[],"rulesets":["custom-%s"],"cidrs":0,"custom":true}' "$([ -s "$T/cat" ] && echo ,)" "$ctag" "$ctag" "$(printf '%s' "$cname" | tr -d '"\\')" "$cpol" "$ctag" >> "$T/cat"
  done < "$T/cust"

  # 路由规则总表 (先匹配先生效)
  if [ "$DNS_ADS" = 1 ] && grep -qx geosite-ads "$T/have"; then ads=1; fi
  {
    [ "$have_nodes" = 1 ] && printf '%s\n' '{"inbound":["speed-in"],"action":"route","outbound":"SPEEDTEST"}'
    [ "$SB_MAJOR" -gt 1 ] || [ "$SB_MINOR" -ge 12 ] && dns_hosts_route_rules      # 自定义解析: 在所有模式下都生效 (route-options 不终止匹配, 后面的规则照常匹配)
    printf '%s\n' '{"clash_mode":"Direct","action":"route","outbound":"direct-mode"}'
    printf '%s\n' '{"clash_mode":"Rule","domain":["rule.mode.enana.invalid"],"action":"route","outbound":"direct-mode"}'   # 永远不会命中; 只为让核心的模式列表里有 Rule (否则无法从 Direct 切回 Rule)
    printf '%s\n' '{"ip_is_private":true,"action":"route","outbound":"direct-lan"}'
    printf '%s\n' '{"domain_suffix":["local","lan","localhost","home.arpa"],"action":"route","outbound":"direct-lan"}'
    printf '%s\n' '{"rule_set":["ovr-direct"],"action":"route","outbound":"direct-site"}'            # 你的覆盖: 网站设为直连
    printf '%s\n' '{"rule_set":["ovr-appdirect"],"action":"route","outbound":"direct-app"}'          # 你的覆盖: 应用设为直连 (关)
    for i in $(seqn "$npinx"); do printf '{"rule_set":["ovr-pin-%s"],"action":"route","outbound":"%s"}\n' "$i" "$(sed -n "${i}p" "$T/pinx" | sed 's/["\\]//g')"; done
    [ "$npinx" -ge 2 ] && printf '%s\n' '{"rule_set":["ovr-pinauto"],"action":"route","outbound":"PINAUTO"}'
    printf '%s\n' '{"rule_set":["ovr-pin"],"action":"route","outbound":"PIN"}'
    printf '%s\n' '{"rule_set":["ovr-auto"],"action":"route","outbound":"Global"}'
    [ "$ads" = 1 ] && printf '%s\n' '{"rule_set":["geosite-ads"],"action":"reject"}'
    cat "$T/r1"
    printf '%s\n' '{"clash_mode":"Global","action":"route","outbound":"Global"}'      # 全局代理模式: 固定出口类服务 (上面) 仍走固定出口, 其余全部走自动线路 / 所选节点
    cat "$T/r2"
    grep -qx geosite-cn "$T/have" && printf '%s\n' '{"rule_set":["geosite-cn"],"action":"route","outbound":"direct-cn"}'
    grep -qx geosite-notcn "$T/have" && printf '%s\n' '{"rule_set":["geosite-notcn"],"action":"route","outbound":"Final"}'
    if grep -qx geoip-cn "$T/have"; then
      printf '%s\n' '{"action":"resolve"}'
      printf '%s\n' '{"rule_set":["geoip-cn"],"action":"route","outbound":"direct-cn"}'
    fi
  } > "$T/rules"

  if [ "$SB_MAJOR" -gt 1 ] || { [ "$SB_MAJOR" -eq 1 ] && [ "$SB_MINOR" -ge 12 ]; }; then
    dns_block="$(dns_block_json "$T/have"),"
    resolver=',"default_domain_resolver":"dns-cn"'
  fi
  lvl=warn; [ "${ACCESS_LOG:-1}" = 1 ] && lvl=info; [ -n "${ENANA_LOG_LEVEL:-}" ] && lvl=$ENANA_LOG_LEVEL
  logoff=''; [ "${ACCESS_LOG:-1}" != 1 ] && [ "${LOG_CORE:-1}" != 1 ] && logoff='"disabled":true,'          # 网站访问和核心日志都关了: 核心完全不写日志
  secret=$(auth_secret)
  {
    printf '{\n"log":{%s"level":"%s","timestamp":true,"output":"%s/sing-box.log"},\n' "$logoff" "$lvl" "$H"
    printf '%s\n' "$dns_block"
    printf '"inbounds":[{"type":"mixed","tag":"in","listen":"127.0.0.1","listen_port":%s}%s],\n' "$PORT" "$speed_in"
    printf '"outbounds":[{"type":"direct","tag":"direct"},{"type":"direct","tag":"direct-mode"},{"type":"direct","tag":"direct-lan"},{"type":"direct","tag":"direct-site"},{"type":"direct","tag":"direct-app"},{"type":"direct","tag":"direct-cn"},\n%s],\n' "$(paste -sd, - < "$T/ob")"
    printf '"route":{"rule_set":[%s],\n"rules":[\n%s],\n"final":"Final","find_process":true%s},\n' "$rs_defs" "$(paste -sd, - < "$T/rules")" "$resolver"
    # 仪表盘页面不再由核心提供 (改由本地辅助服务在 /enana/admin/ 提供), 核心只留控制接口; 只允许仪表盘的来源跨域访问它 (还要有令牌)
    printf '"experimental":{"cache_file":{"enabled":true,"path":"%s/cache.db"},"clash_api":{"external_controller":"127.0.0.1:%s","default_mode":"%s"%s,"access_control_allow_origin":["http://127.0.0.1:%s","http://localhost:%s"]}}\n}\n' \
      "$H" "$UI_PORT" "$(proxy_clash_mode)" "${secret:+,\"secret\":\"$secret\"}" "$API_PORT" "$API_PORT"
  } > "$H/config.json.new"
  chmod 600 "$H/config.json.new"
  gen_catalog_json "$T"
  rm -rf "$T"
}

_apply_step() { [ "${APPLY_QUIET:-0}" = 1 ] || job_step $(( ${APPLY_BASE:-0} + $1 )) "$2" "$3"; }   # 任务里的步骤序号可整体后移 (前面还有别的步骤时); 静默模式不写进度

# apply_config: 生成 -> sing-box check -> 与现行配置比较 -> 仅在有变化时替换并重启; 失败自动回滚
# 返回: 0 成功/无变化  1 配置无效(详情 $H/check.log)  3 新配置启动失败(已回滚)
apply_config() {
  _apply_step 0 10 "生成配置"
  load_settings        # 生成配置前读最新的设置 (本进程启动之后别的进程可能改过, 例如代理总开关)
  ovr_sync
  gen_config
  _apply_step 1 35 "校验配置"
  if ! "$SB" check -c "$H/config.json.new" > "$H/check.log" 2>&1; then
    if gen_config --no-rulesets && "$SB" check -c "$H/config.json.new" > "$H/check.log.2" 2>&1; then
      warn "社区规则集未通过校验, 已临时停用 (运行 enana update 重新下载)"
    else return 1; fi
  fi
  if [ -f "$H/config.json" ] && cmp -s "$H/config.json" "$H/config.json.new"; then rm -f "$H/config.json.new"; APPLY_CHANGED=0; return 0; fi
  [ -f "$H/config.json" ] && cp -p "$H/config.json" "$H/config.json.bak"
  mv "$H/config.json.new" "$H/config.json"; APPLY_CHANGED=1
  if os_service_loaded; then
    _apply_step 2 60 "应用并重启"
    os_service_restart
    _apply_step 3 80 "等待服务就绪"
    if ! wait_port "$PORT" 15; then
      if [ -f "$H/config.json.bak" ]; then cp -p "$H/config.json.bak" "$H/config.json"; os_service_restart; wait_port "$PORT" 15 || true; proxy_sync_mode; fi
      return 3
    fi
    proxy_sync_mode
  fi
  return 0
}

wait_port() { # 端口 秒数
  local p=$1 n=$(( ${2:-10} * 2 ))
  while [ "$n" -gt 0 ]; do nc -z 127.0.0.1 "$p" 2>/dev/null && return 0; sleep 0.5; n=$((n-1)); done
  return 1
}

clash() { # clash GET|PUT|PATCH|DELETE 路径 [JSON]  -> 响应体 (本机 Clash API, 带登录令牌)
  local m=$1 p=$2 d=${3:-} sec; sec=$(auth_secret)
  if [ -n "$d" ]; then curl -s -m 6 --noproxy '*' -X "$m" -H "Authorization: Bearer $sec" -H 'Content-Type: application/json' -d "$d" "http://127.0.0.1:$UI_PORT$p"
  else curl -s -m 6 --noproxy '*' -X "$m" -H "Authorization: Bearer $sec" "http://127.0.0.1:$UI_PORT$p"; fi
}

# 代理总开关 + 模式 (设置里的 PROXY_ENABLED / PROXY_MODE):
#   关闭 (默认) = 全部直连 (Direct, 不经过任何代理服务器) · 开启 + auto = 自动模式 (Rule: 智能分流, 按规则/策略) · 开启 + global = 全局代理 (Global)
# 热切换 (不重启核心), 同时写进设置和磁盘上的配置, 所以重启 / 重新生成配置后仍是这个状态。
# 刚安装、退出账号后默认是关闭; 只有登录后在仪表盘里手动开启才会生效。
proxy_clash_mode() { if [ "${PROXY_ENABLED:-0}" != 1 ]; then echo Direct; elif [ "${PROXY_MODE:-auto}" = global ]; then echo Global; else echo Rule; fi; }
proxy_apply_mode() { # 把当前设置推给运行中的核心, 并同步磁盘配置的 default_mode
  local mode; mode=$(proxy_clash_mode)
  clash PATCH /configs "{\"mode\":\"$mode\"}" >/dev/null 2>&1 || true
  [ -f "$H/config.json" ] && sed -i '' "s/\"default_mode\":\"[A-Za-z]*\"/\"default_mode\":\"$mode\"/" "$H/config.json"
  return 0
}
# 代理总开关 / 模式要和「生成并应用配置」互斥: 否则后台任务 (比如登录后的云端内容同步) 正在用旧的设置生成配置时, 它会把磁盘配置和运行中的模式改回旧值。
# 已经持有 apply 锁 (退出账号等) 就直接做; 等不到锁 (别的任务卡住了) 也照做, 不能让开关失灵。
proxy_locked() { # <函数> [参数…]
  local rc
  if [ "${OP_LOCK_HELD:-0}" = 1 ] || ! op_lock; then "$@"; return $?; fi
  "$@"; rc=$?; op_unlock; return $rc
}
_proxy_set() { settings_set "$1" "$2"; eval "$1=\$2"; proxy_apply_mode; }
proxy_set_enabled() { proxy_locked _proxy_set PROXY_ENABLED "$1"; }                                           # 0|1
proxy_set_mode() { case $1 in auto|global) ;; *) return 1 ;; esac; proxy_locked _proxy_set PROXY_MODE "$1"; }   # auto|global
proxy_sync_mode() { # 核心刚(重新)启动后调用: 让运行时的模式与设置一致 (缓存文件里可能留着旧模式)
  clash PATCH /configs "{\"mode\":\"$(proxy_clash_mode)\"}" >/dev/null 2>&1 || true
}
