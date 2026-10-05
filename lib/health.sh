# 连接健康记录 (2.3.8): 让「ChatGPT 连不上」这类问题能事后判断是 节点 / 出口 IP / 本机接管 / 被退出登录 里的哪一个。依赖 common.sh logs.sh servers.sh config.sh os-darwin.sh (bash 3.2 兼容)。
#
#   $H/logs/health-YYYY-MM-DD.log   制表符分隔: 时间 种类 目标 结果 毫秒 说明(键=值); 和操作记录一起按「日志保留时长」清理 / 压缩; 格式见 docs/DIAGNOSTICS.md 和 lib/health.pl 的头部
#   由 `enana tick` 每分钟调用 health_tick:
#     node    每分钟  本机直接连「固定出口 / 自动线路」服务器端口的 TCP 连接 (成功 + 耗时 / 超时 / 拒绝 / 不可达 / 解析失败): 服务器是否稳定的唯一客观证据
#     canary  每 ~5 分钟  经本机代理访问 Google 204 / chatgpt.com / api.openai.com (403 = 出口 IP 被 OpenAI 限制), 以及不经代理的苹果对照站点 (本机网络本身是否正常)
#     state   状态变化时 + 每 ~9 分钟  核心 / 控制接口 / 总开关 / 系统代理 / 登录 / TUN / 网络接口 —— 以前这些只在导出的那一刻采样一次, 看不出「什么时候开始不对的」
#     tick    两次定时任务相隔 > 3 分钟 (电脑休眠 / 后台被暂停)
#   状态变化同时写一条操作记录 (来源 auto): 「环境状态变化 item=sysproxy from=1 to=0」「核心进程已重启」……
#   「操作记录」开关关闭时一并不记 (隐私: 这些记录也包含时间线); 只在 macOS 上运行 (Windows 之后跟进)。
# 诊断导出里的 health / health_summary / outages / verdict 分区由 _b_health* / _b_verdict 生成 (verdict 是 lib/health.pl 的自动判定)。

HEALTH_CANARY_EVERY=280      # 秒
HEALTH_STATE_EVERY=540       # 秒: 状态没变化时也每隔这么久写一行, 让「持续了多久」可以从记录里直接算出来
HEALTH_NODE_MAX=8
HEALTH_TS=''

health_on() { [ "${ENANA_PLATFORM:-darwin}" = darwin ] && [ "${LOG_OPS:-1}" = 1 ]; }
health_file() { printf '%s/health-%s.log' "$LOGS" "$(date +%F)"; }
_health_line() { # <种类> <目标> <结果> <毫秒> <说明>  -> 标准输出一行 (时间戳取 HEALTH_TS: 一次定时任务里的几行同一时刻)
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${HEALTH_TS:-$(date '+%F %T')}" "$1" "$(printf '%s' "$2" | tr '\t\r\n' '   ')" "$3" "${4:-0}" "$(printf '%s' "${5:-}" | tr '\t\r\n' '   ' | cut -c1-300)"
}
_hv() { printf '%s\n' "$2" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -1; }     # 从 "k=v k=v" 里取一项

# ---------- 状态 ----------
health_sysproxy_eff() { # 当前生效的系统代理 (主网络服务) 是否指向本程序 -> 1 | 0; 比逐个网络服务检查快得多, 也更接近「应用实际用的那个」
  scutil --proxy 2>/dev/null | awk -v p="$PORT" '
    /^[ \t]*HTTPEnable :/ { he = $3 } /^[ \t]*HTTPProxy :/ { hp = $3 } /^[ \t]*HTTPPort :/ { hpt = $3 }
    END { print (he == 1 && (hp == "127.0.0.1" || hp == "localhost") && hpt == p) ? 1 : 0 }'
}
pin_dependents() { # 有多少个选择器 / 规则会把流量交给「固定出口」: 默认走固定出口的服务 (config.json 里 default=PIN 的选择器) + 有内容的应用 / 网站固定出口规则集
  local n=0 f
  [ -s "$H/config.json" ] && n=$(grep -o '"default":"PIN"' "$H/config.json" 2>/dev/null | wc -l | tr -d ' ')
  for f in ovr-apppin ovr-pin ovr-browserpin; do
    if grep -qE '"(process_name|process_path|domain|domain_suffix)"' "$H/rules/$f.json" 2>/dev/null; then n=$((n + 1)); fi
  done
  printf '%s' "${n:-0}"
}
health_pin_state() { # empty = 没有任何服务器是固定出口, 但有应用 / 网站 / AI 服务选了它 → 它们全部直连 (真实 IP 出口, ChatGPT 会报 unsupported_country_region_territory); ok = 没问题
  [ "$(srv_list | awk -F'\t' '$5 == "pin"' | wc -l | tr -d ' ')" = 0 ] || { printf ok; return 0; }
  if [ "$(pin_dependents)" -gt 0 ]; then printf empty; else printf ok; fi
}
health_state_vector() { # -> core=1 pid=… api=1 proxy=1 mode=auto capture=system sysproxy=1 login=1 tun=- if=en0 gw=192.168.1.1
  local run=0 pid='' api=0 tun='-' ifc='' gw='' code
  os_service_info 2>/dev/null; run=${SVC_RUNNING:-0}; pid=${SVC_PID:-}
  if [ "$run" = 1 ]; then
    code=$(curl -s -o /dev/null -m 2 --noproxy '*' -w '%{http_code}' -H "Authorization: Bearer $(auth_secret)" "http://127.0.0.1:$UI_PORT/version" 2>/dev/null || true)
    [ "$code" = 200 ] && api=1
  fi
  [ "${NETWORK_MODE:-system}" != tun ] || { enhanced_ready >/dev/null 2>&1 && tun=1 || tun=0; }
  ifc=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2; exit}'); gw=$(route -n get default 2>/dev/null | awk '/gateway:/ {print $2; exit}')
  printf 'core=%s pid=%s api=%s proxy=%s mode=%s capture=%s sysproxy=%s login=%s tun=%s if=%s gw=%s pin=%s' "$run" "${pid:--}" "$api" "${PROXY_ENABLED:-0}" "${PROXY_MODE:-auto}" "${NETWORK_MODE:-system}" "$(health_sysproxy_eff)" "$(auth_logged_in && echo 1 || echo 0)" "$tun" "${ifc:--}" "${gw:--}" "$(health_pin_state)"
}
_health_event() { # <项目> <旧值> <新值> [额外 键 值…]  -> 操作记录 (来源 auto)
  local item=$1 from=$2 to=$3; shift 3
  oplog auto "环境状态变化" "$(kv item "$item" from "$from" to "$to" "$@")" ok
}
health_state_tick() { # 标准输出: 需要写进健康记录的 state 行 (变化时 / 太久没写时)
  local cur prev='' f="$H/.health.state" lastw=0 w="$H/.health.state.written" k pv cv write=0
  cur=$(health_state_vector)
  [ -f "$f" ] && IFS= read -r prev < "$f"
  [ -f "$w" ] && IFS= read -r lastw < "$w"
  if [ -n "$prev" ]; then
    for k in core api proxy sysproxy login tun capture if gw pin; do
      pv=$(_hv "$k" "$prev"); cv=$(_hv "$k" "$cur"); [ "$pv" != "$cv" ] || continue
      write=1
      case $k in
        core) _health_event core_running "$pv" "$cv" pid "$(_hv pid "$cur")" ;;
        api) [ "$(_hv core "$cur")" = 1 ] && _health_event core_api "$pv" "$cv" ;;
        proxy) _health_event proxy "$pv" "$cv" ;;
        sysproxy) _health_event sysproxy "$pv" "$cv" capture "$(_hv capture "$cur")" ;;
        login) _health_event login "$pv" "$cv" ;;
        tun) _health_event tun_ready "$pv" "$cv" ;;
        capture) _health_event capture_mode "$pv" "$cv" ;;
        if|gw) _health_event "net_$k" "$pv" "$cv" ;;
        pin) _health_event pin "$pv" "$cv" pin_servers 0 dependents "$(pin_dependents)" ;;     # ok → empty: 固定出口没了 (删了服务器 / 重装后没重设), 选了它的应用 / 服务开始直连
      esac
    done
    pv=$(_hv pid "$prev"); cv=$(_hv pid "$cur")
    if [ "$(_hv core "$prev")" = 1 ] && [ "$(_hv core "$cur")" = 1 ] && [ "$pv" != "$cv" ] && [ "$pv" != - ] && [ "$cv" != - ]; then
      write=1; oplog auto "核心进程已重启" "$(kv old_pid "$pv" new_pid "$cv")" ok      # 崩溃后被 launchd 拉起 / 手动重启: 这是「为什么连接突然断了一下」的直接证据
    fi
  else
    write=1
    [ "$(_hv pin "$cur")" != empty ] || _health_event pin - empty pin_servers 0 dependents "$(pin_dependents)"      # 第一次观察就已经是空的 (例如重装后): 也记一笔
  fi
  [ "$(( $(now) - ${lastw:-0} ))" -lt "$HEALTH_STATE_EVERY" ] || write=1
  printf '%s\n' "$cur" > "$f"
  if [ "$write" = 1 ]; then now > "$w"; _health_line state capture ok 0 "$cur"; fi
}

# ---------- 服务器端口 (每分钟) ----------
health_nodes() { # 标准输出: node 行。只探测「固定出口」和「自动线路」里的服务器 (订阅里几十个备用节点不探)
  local list res tag result ms role
  list=$(srv_list | awk -F'\t' '($5 == "pin" || $5 == "auto") && $3 != "" && $4 ~ /^[0-9]+$/ { print $5 "\t" $1 "\t" $3 "\t" $4 }' | LC_ALL=C sort -s -r -k1,1 | head -n "$HEALTH_NODE_MAX")
  [ -n "$list" ] || return 0
  res=$(printf '%s\n' "$list" | awk -F'\t' '{ print $2 "\t" $3 "\t" $4 }' | perl "$LIB/health.pl" probe 4) || return 0
  while IFS=$'\t' read -r tag result ms _; do
    [ -n "$tag" ] || continue
    role=$(printf '%s\n' "$list" | awk -F'\t' -v t="$tag" '$2 == t { print $1; exit }')
    _health_line node "$tag" "$result" "$ms" "$(kv role "$role" mode "${NETWORK_MODE:-system}")"
  done <<EOF
$res
EOF
}

# ---------- 经本机代理访问关键站点 (每 ~5 分钟) ----------
health_chain() { # <选择器> -> a>b>c: 沿着选择器当前的选择最多跟 3 层 (svc-chatgpt>PIN>Tokyo-Fix = 这条连接实际用了哪个出口)
  local cur=$1 out=$1 i nxt enc
  for i in 1 2 3; do
    case $cur in *[!A-Za-z0-9_.~-]*) enc=$(printf '%s' "$cur" | perl -pe 's/([^A-Za-z0-9_.~-])/sprintf("%%%02X", ord($1))/ge') ;; *) enc=$cur ;; esac
    nxt=$(clash GET "/proxies/$enc" 2>/dev/null | sed -n 's/.*"now":"\([^"]*\)".*/\1/p' | head -1)
    [ -n "$nxt" ] || break
    out="$out>$nxt"; cur=$nxt
  done
  printf '%s' "$out"
}
health_svc_selector() { # <域名> -> 目录里包含该域名的服务的选择器 (svc-<id>); 没有就是 Final
  local d=$1 id
  id=$(awk -F'|' -v d="$d" '/^[^#]/ { n = split($5, a, ","); for (i = 1; i <= n; i++) if (a[i] == d) { print $1; exit } }' "$(content_file services.conf)" 2>/dev/null)
  if [ -n "$id" ]; then printf 'svc-%s' "$id"; else printf 'Final'; fi
}
_health_canary_one() { # <输出文件> <名称> <good 状态码,逗号> <地址> <proxy|direct> <选择器|-> [403 的含义: region]
  local out=$1 name=$2 good=$3 url=$4 via=$5 sel=$6 on403=${7:-} r rc code ct tt res chain=''
  if [ "$via" = proxy ]; then r=$(curl -s -o /dev/null -m 8 --connect-timeout 5 -x "http://127.0.0.1:$PORT" -w '%{http_code}\t%{time_connect}\t%{time_total}' "$url" 2>/dev/null); rc=$?
  else r=$(curl -s -o /dev/null -m 8 --connect-timeout 5 --noproxy '*' -w '%{http_code}\t%{time_connect}\t%{time_total}' "$url" 2>/dev/null); rc=$?; fi
  code=$(printf '%s' "$r" | cut -f1); ct=$(printf '%s' "$r" | cut -f2); tt=$(printf '%s' "$r" | cut -f3)
  tt=$(LC_ALL=C awk -v t="${tt:-0}" 'BEGIN { printf "%d", t * 1000 }'); ct=$(LC_ALL=C awk -v t="${ct:-0}" 'BEGIN { printf "%d", t * 1000 }')
  if [ "$rc" = 0 ]; then
    case ",$good," in *",$code,"*) res=ok ;; *) if [ "$on403" = region ] && [ "$code" = 403 ]; then res=region-blocked; else res="http-$code"; fi ;; esac
  else
    case $rc in 6) res=dns ;; 7) res=refused ;; 28) res=timeout ;; 35|51|58|60) res=tls ;; 52|56) res=reset ;; 97) res=proxy-handshake ;; *) res="curl-$rc" ;; esac
  fi
  [ "$sel" = - ] || chain=$(health_chain "$sel")
  _health_line canary "$name" "$res" "$tt" "$(kv http "${code:-000}" connect_ms "$ct" via "$via" chain "$chain" mode "${NETWORK_MODE:-system}")" > "$out"
}
health_canaries() { # 标准输出: canary 行。并行, 最多约 8 秒
  [ -z "${ENANA_SKIP_PROBE:-}" ] || return 0      # 离线 / 测试: 不联网
  local d; d=$(mktemp -d)
  _health_canary_one "$d/4" cn_direct 200 'http://captive.apple.com/hotspot-detect.html' direct - &      # 对照: 不经代理访问苹果 (macOS 自己用来判断联网的地址; 国内外都能直接访问)
  if [ "${PROXY_ENABLED:-0}" = 1 ] && nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1; then
    _health_canary_one "$d/1" google_204 204 'http://www.gstatic.com/generate_204' proxy "$(health_svc_selector gstatic.com)" &
    _health_canary_one "$d/2" chatgpt_web 200,301,302,307,403 'https://chatgpt.com/' proxy "$(health_svc_selector chatgpt.com)" &     # 403 = Cloudflare 人机验证页, 说明「连得上」
    _health_canary_one "$d/3" openai_api 401 'https://api.openai.com/v1/models' proxy "$(health_svc_selector openai.com)" region &   # 401 = 正常 (没带密钥); 403 = 这个出口 IP 所在地区被 OpenAI 限制
  fi
  wait
  cat "$d"/[1-4] 2>/dev/null
  rm -rf "$d"
}

# ---------- 每分钟入口 (由 install.sh 的 cmd_tick 调用) ----------
health_tick() {
  health_on || return 0
  local T now_ last=0 gap lc=0 f="$H/.health.tick" c="$H/.health.canary"
  mkdir -p "$LOGS"; T=$(mktemp); HEALTH_TS=$(date '+%F %T'); now_=$(now)
  [ -f "$f" ] && IFS= read -r last < "$f"
  printf '%s\n' "$now_" > "$f"
  gap=$(( now_ - ${last:-0} ))
  if [ "${last:-0}" -gt 0 ] && [ "$gap" -gt 180 ]; then _health_line tick gap gap "$gap" "$(kv note "no tick for ${gap}s (sleep or background pause)")" >> "$T"; fi
  health_state_tick >> "$T" 2>/dev/null || true
  health_nodes >> "$T" 2>/dev/null || true
  [ -f "$c" ] && IFS= read -r lc < "$c"
  if [ $(( now_ - ${lc:-0} )) -ge "$HEALTH_CANARY_EVERY" ]; then now > "$c"; health_canaries >> "$T" 2>/dev/null || true; fi
  if [ -s "$T" ]; then cat "$T" >> "$(health_file)"; fi
  rm -f "$T"
  return 0
}

# ---------- 诊断导出 ----------
_health_days() { # <起始日期|空>  -> 有健康记录的日期 (旧→新)
  ls -1 "$LOGS" 2>/dev/null | sed -nE 's/^health-([0-9]{4}-[0-9]{2}-[0-9]{2})\.log(\.gz)?$/\1/p' | sort -u | awk -v f="$1" 'f == "" || $0 >= f'
}
_health_stream() { # <日期>
  local d=$1
  [ -f "$LOGS/health-$d.log" ] && cat "$LOGS/health-$d.log"
  [ -f "$LOGS/health-$d.log.gz" ] && gzip -dc "$LOGS/health-$d.log.gz"
  return 0
}
_health_rows() { # <起始时间|空>  -> 范围内的健康记录行 (旧→新)
  local since=$1 first d; first=${since%% *}
  for d in $(_health_days "$first"); do _health_stream "$d"; done | LC_ALL=C awk -v s="$since" 'BEGIN { FS = "\t" } { if (s == "" || substr($0, 1, 19) >= s) print }'
}
_b_health() { # 原始记录 (最近 6000 行); tsv
  printf 'ts\tkind\ttarget\tresult\tms\tdetail\n'
  _health_rows "$1" | tail -n 6000
}
_b_health_summary() { # <起始时间|空> <小时数|all>  分桶统计: 范围 ≤ 24 小时 10 分钟一桶, ≤ 72 小时 30 分钟, 更长 1 小时
  local m=60
  case $2 in all) m=60 ;; *) if [ "$2" -le 24 ]; then m=10; elif [ "$2" -le 72 ]; then m=30; fi ;; esac
  _health_rows "$1" | perl "$LIB/health.pl" summary "$m"
}
_b_health_outages() { _health_rows "$1" | perl "$LIB/health.pl" outages; }
_b_verdict() { # <起始时间|空>  自动判定: 读 health / meta / env (+ 选了的 ops / access 分区) 的生成结果
  local nodes
  nodes=$(srv_list | awk -F'\t' '$5 == "pin" || $5 == "auto" { printf "%s%s:%s", (n++ ? "," : ""), $1, $5 }')
  _health_rows "$1" > "$BT/v.health"
  perl "$LIB/health.pl" verdict "$(now)" "$BT/v.health" "$BT/ops" "$BT/access" "$BT/meta" "$BT/env" "$nodes" "$BT/probes"
}
