# 连接健康记录 (2.3.8): 让「ChatGPT 连不上」这类问题能事后判断是 节点 / 出口 IP / 本机接管 / 被退出登录 里的哪一个。依赖 common.sh logs.sh servers.sh config.sh os-darwin.sh (bash 3.2 兼容)。
#
#   $H/logs/health-YYYY-MM-DD.log   制表符分隔: 时间 种类 目标 结果 毫秒 说明(键=值); 和操作记录一起按「日志保留时长」清理 / 压缩; 格式见 docs/DIAGNOSTICS.md 和 lib/health.pl 的头部
#   由 `enana tick` 每分钟调用 health_tick:
#     node    每分钟  本机直接连「固定出口 / 自动线路」服务器端口的 TCP 连接 (成功 + 耗时 / 超时 / 拒绝 / 不可达 / 解析失败): 服务器是否稳定的唯一客观证据
#             走 UDP 的协议 (hysteria / hysteria2 / tuic / wireguard, 2.3.27) 不做 TCP 探测 (服务器上没有对应的 TCP 端口, 永远是 refused, 一天几十条假失败):
#             只有 AUTO / PINAUTO 当前选中的那一个, 改为请核心经它测一次速 (Clash API /proxies/<节点>/delay), 行里 probe=core, 结果 ok / timeout / error
#     canary  每 ~5 分钟  经本机代理访问 Google 204 / chatgpt.com / api.openai.com (403 = 出口 IP 被 OpenAI 限制), 以及不经代理的苹果对照站点 (本机网络本身是否正常)
#     state   状态变化时 + 每 ~9 分钟  核心 / 控制接口 / 总开关 / 系统代理 / 登录 / TUN / 网络接口 —— 以前这些只在导出的那一刻采样一次, 看不出「什么时候开始不对的」
#             断网的那一分钟 (2.3.27): 一行 `state network outage` 代替这一分钟各个节点的失败 (见 health_nodes)
#     tick    两次定时任务相隔 > 3 分钟 (电脑休眠 / 后台被暂停)
#   状态变化同时写一条操作记录 (来源 auto): 「环境状态变化 item=sysproxy from=1 to=0」「核心进程已重启」……
#   自动线路 (2.3.26): node 探测发现 AUTO / PINAUTO 当前选中的节点连不上, 立刻请核心重新测速这个组 (它当场改选), 见下面的 health_failover;
#     真的换了节点才记一条操作记录「环境状态变化 item=auto_select from=旧节点 to=新节点 group=AUTO probe=timeout」
#     2.3.27: 走 UDP 的选中节点按核心的测速结果同样处理 (probe=core-timeout / core-error); 本机断网时不换节点 (换哪个都一样), 只记一条「item=network from=ok to=outage」;
#     换了节点、而且旧节点自己的核心测速也失败了, 就断开核心里还经这个组用着旧节点的连接 (核心自己不会断开: 坏节点上已经建立的连接会一直挂着), 记录里多一项 closed=条数
#   「操作记录」开关关闭时一并不记 (隐私: 这些记录也包含时间线); 只在 macOS 上运行 (Windows 之后跟进)。
# 诊断导出里的 health / health_summary / outages / verdict 分区由 _b_health* / _b_verdict 生成 (verdict 是 lib/health.pl 的自动判定)。

HEALTH_CANARY_EVERY=280      # 秒
HEALTH_STATE_EVERY=540       # 秒: 状态没变化时也每隔这么久写一行, 让「持续了多久」可以从记录里直接算出来
HEALTH_NODE_MAX=8
HEALTH_RETEST_MS=18000       # 毫秒: 请核心重测一个自动选线组时给它的时间 —— 要长过核心测一个节点的上限 (15 秒): 时间到了还没测完的节点核心不会判为不可用, 它的旧延迟还在, 不一定被换掉
HEALTH_RETEST_GAP=60         # 秒: 同一个组最多每分钟重测一次
HEALTH_RETEST_HOLD=300       # 秒: 重测之后核心仍然选它、并且它这次测速是通的 (核心经代理测得通, 只是本机直连它的端口不通) 时, 同一个节点 5 分钟内不再触发
HEALTH_TEST_URLQ='http%3A%2F%2Fwww.gstatic.com%2Fgenerate_204'    # 测速地址 (已 URL 编码): 和 lib/config.sh 里 AUTO / PINAUTO 的 url 是同一个
HEALTH_CORE_MS=5000          # 毫秒: 请核心经「走 UDP 的选中节点」测一次速 (GET /proxies/<节点>/delay) 的超时
HEALTH_CORE_GAP=55           # 秒: 同一个组的这种测速两次至少相隔这么久 = 每分钟的定时任务最多一次 (少几秒是给定时任务启动时间的抖动; 手动 / 重叠的 tick 不会多测)
HEALTH_OUTAGE_MERGE=600      # 秒: 断网只在开始时记一条操作记录; 距上一次断网的那一分钟不到这么久, 算同一次 (时断时续的网络不会每次都记)
HEALTH_CLOSE_MAX=200         # 换节点后最多断开这么多条还经这个组用着旧节点的连接
HEALTH_CLOSE_SECS=10         # …最多花这么多秒 (每分钟的定时任务不能被拖长; 接口出错就停)
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
    if grep -qE '"(process_name|process_path|domain|domain_suffix)"' "$(rule_file "$f.json")" 2>/dev/null; then n=$((n + 1)); fi
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
  printf 'core=%s pid=%s api=%s proxy=%s mode=%s capture=%s sysproxy=%s login=%s tun=%s if=%s gw=%s pin=%s orphans=%s' "$run" "${pid:--}" "$api" "${PROXY_ENABLED:-0}" "${PROXY_MODE:-auto}" "${NETWORK_MODE:-system}" "$(health_sysproxy_eff)" "$(auth_logged_in && echo 1 || echo 0)" "$tun" "${ifc:--}" "${gw:--}" "$(health_pin_state)" "$(health_orphans)"
}
health_orphans() { # 指定了「已经不是固定出口的服务器」的应用 / 网站个数 (它们暂时退回默认固定出口, 出口 IP / 国家可能和你以为的不一样); 见 lib/exits.sh
  if type exits_orphan_count >/dev/null 2>&1; then exits_orphan_count; else printf 0; fi
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
    for k in core api proxy sysproxy login tun capture if gw pin orphans; do
      pv=$(_hv "$k" "$prev"); cv=$(_hv "$k" "$cur"); [ "$pv" != "$cv" ] || continue
      [ "$k" != orphans ] || [ -n "$pv" ] || [ "$cv" != 0 ] || continue        # 升级后第一次: 旧的状态行里还没有这一项, 0 不算变化
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
        orphans) _health_event exit_orphans "${pv:--}" "$cv" names "$(exits_orphan_names 2>/dev/null)" ;;     # 指定的固定出口没了 / 不再是固定出口 (订阅刷新删掉了节点、角色被改): 这些应用 / 网站现在走默认固定出口, 出口 IP 可能变了
      esac
    done
    pv=$(_hv pid "$prev"); cv=$(_hv pid "$cur")
    if [ "$(_hv core "$prev")" = 1 ] && [ "$(_hv core "$cur")" = 1 ] && [ "$pv" != "$cv" ] && [ "$pv" != - ] && [ "$cv" != - ]; then
      write=1; oplog auto "核心进程已重启" "$(kv old_pid "$pv" new_pid "$cv")" ok      # 崩溃后被 launchd 拉起 / 手动重启: 这是「为什么连接突然断了一下」的直接证据
    fi
  else
    write=1
    [ "$(_hv pin "$cur")" != empty ] || _health_event pin - empty pin_servers 0 dependents "$(pin_dependents)"      # 第一次观察就已经是空的 (例如重装后): 也记一笔
    [ "$(_hv orphans "$cur")" = 0 ] || _health_event exit_orphans - "$(_hv orphans "$cur")" names "$(exits_orphan_names 2>/dev/null)"
  fi
  [ "$(( $(now) - ${lastw:-0} ))" -lt "$HEALTH_STATE_EVERY" ] || write=1
  printf '%s\n' "$cur" > "$f"
  if [ "$write" = 1 ]; then now > "$w"; _health_line state capture ok 0 "$cur"; fi
}

# ---------- 服务器端口 (每分钟) ----------
health_nodes() { # [这一分钟金丝雀的输出文件] [金丝雀后台任务的 pid]  标准输出: node 行 (断网的那一分钟: 一行 state network outage + 通的节点)。然后视情况让自动线路换节点 (health_failover)
  # 只探测「固定出口」和「自动线路」里的服务器 (订阅里几十个备用节点不探); 自动选线组当前选中的节点排在最前面, 一定会被探测
  local can=${1:-} cpid=${2:-} list tcp res core='' tag result ms how role sel ifx='' d='' g cur f last pids='' i=0 cn='' n_all n_bad out=0 bad
  sel=$(health_auto_sel)
  # 清单: 角色 标签 主机 端口 类型; 顺序 = 选中的节点 → 固定出口 → 自动线路 (同一类里保持 servers.jsonl 的顺序), 最多 HEALTH_NODE_MAX 个。
  # 走 UDP 的协议 (hysteria / hysteria2 / tuic / wireguard) 不做 TCP 探测: 只有自动选线组当前选中的那一个进清单 (不需要地址), 改为请核心经它测速 (health_core_delay)
  list=$(srv_list | HEALTH_SEL="$sel" LC_ALL=C awk -F'\t' '
    BEGIN { n = split(ENVIRON["HEALTH_SEL"], a, "\n"); for (i = 1; i <= n; i++) { p = index(a[i], "\t"); if (p) s[substr(a[i], p + 1)] = 1 } }
    $5 != "pin" && $5 != "auto" { next }
    $2 ~ /^(hysteria.*|tuic|wireguard)$/ { if ($1 in s) print 0 "\t" $5 "\t" $1 "\t" $3 "\t" $4 "\t" $2; next }
    $3 != "" && $4 ~ /^[0-9]+$/ { print (($1 in s) ? 0 : ($5 == "pin" ? 1 : 2)) "\t" $5 "\t" $1 "\t" $3 "\t" $4 "\t" $2 }' | LC_ALL=C sort -s -n -k1,1 | cut -f2- | head -n "$HEALTH_NODE_MAX")
  [ -n "$list" ] || return 0
  # 选中的是走 UDP 的节点: 在后台请核心经它测速 (和下面的 TCP 探测同时进行, 这一分钟的任务不变长); 同一个组每分钟最多一次
  while IFS=$'\t' read -r g cur; do
    [ -n "$g" ] && [ -n "$cur" ] || continue
    printf '%s\n' "$list" | HT="$cur" LC_ALL=C awk -F'\t' '$2 == ENVIRON["HT"] && $5 ~ /^(hysteria.*|tuic|wireguard)$/ { f = 1 } END { exit !f }' || continue
    f="$H/.health.core-$g"; last=0
    [ -f "$f" ] && IFS= read -r last < "$f"
    case $last in ''|*[!0-9]*) last=0 ;; esac
    [ $(( $(now) - last )) -ge "$HEALTH_CORE_GAP" ] || continue
    [ -n "$d" ] || d=$(mktemp -d) || break
    now > "$f"; i=$((i + 1))
    ( r=$(health_core_delay "$cur"); [ -z "$r" ] || printf '%s\t%s\tcore\n' "$cur" "$r" ) > "$d/$i" 2>/dev/null &
    pids="$pids $!"
  done <<EOF
$sel
EOF
  tcp=$(printf '%s\n' "$list" | LC_ALL=C awk -F'\t' '$5 !~ /^(hysteria.*|tuic|wireguard)$/ { print $2 "\t" $3 "\t" $4 }')
  res=''
  if [ -n "$tcp" ]; then
    # TUN 模式: 探测绑定到物理网卡, 否则 TUN 会在本机应答握手, 「可达」就是假的 (耗时只有几毫秒)
    if [ "${NETWORK_MODE:-system}" = tun ]; then
      ifx=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2; exit}')
      case $ifx in utun*|'') ifx='' ;; *) ifx=$(ifconfig -v "$ifx" 2>/dev/null | sed -n '1s/.* index \([0-9][0-9]*\).*/\1/p') ;; esac
    fi
    res=$(printf '%s\n' "$tcp" | ENANA_PROBE_IFINDEX="$ifx" perl "$LIB/health.pl" probe 4 | HOW="${ifx:+bound}" LC_ALL=C awk -F'\t' '$1 != "" { print $1 "\t" $2 "\t" $3 "\t" ENVIRON["HOW"] }')
  fi
  [ -z "$pids" ] || wait $pids 2>/dev/null || true
  if [ -n "$d" ]; then core=$(cat "$d"/* 2>/dev/null); rm -rf "$d"; fi
  res=$(printf '%s\n%s\n' "$res" "$core" | awk 'NF')      # 每行: 标签 结果 毫秒 方式 (空 / bound = TCP 探测, core = 核心测速)
  [ -n "$res" ] || return 0
  # 同一分钟里不经代理的对照站点 (金丝雀每 ~5 分钟做一次, 在后台和上面的探测同时跑; 这一分钟没做就是空)
  [ -z "$cpid" ] || wait "$cpid" 2>/dev/null || true
  [ -z "$can" ] || [ ! -f "$can" ] || cn=$(LC_ALL=C awk -F'\t' '$2 == "canary" && $3 == "cn_direct" { print $4; exit }' "$can")
  # 断网: 这一分钟探测的节点全部失败 (至少探测了 2 个), 或者同一分钟里对照站点也失败了 (而且有节点失败) —— 是本机网络的问题, 换哪个节点都一样:
  # 不换节点; 只写一行 state network outage, 不记各个节点的失败 (免得把本机断网算在服务器头上, 通的节点照常记); 操作记录只在开始时记一条
  n_all=$(printf '%s\n' "$res" | grep -c .)
  n_bad=$(printf '%s\n' "$res" | LC_ALL=C awk -F'\t' '$2 != "ok"' | grep -c .)
  if [ "$n_bad" -gt 0 ]; then
    [ "$n_all" -lt 2 ] || [ "$n_bad" != "$n_all" ] || out=1
    case $cn in ''|ok) ;; *) out=1 ;; esac
  fi
  while IFS=$'\t' read -r tag result ms how; do
    [ -n "$tag" ] || continue
    [ "$out" = 0 ] || [ "$result" = ok ] || continue
    role=$(printf '%s\n' "$list" | HT="$tag" LC_ALL=C awk -F'\t' '$2 == ENVIRON["HT"] { print $1; exit }')
    _health_line node "$tag" "$result" "$ms" "$(kv role "$role" mode "${NETWORK_MODE:-system}" probe "$how")"
  done <<EOF
$res
EOF
  if [ "$out" = 1 ]; then
    bad=$(printf '%s\n' "$res" | LC_ALL=C awk -F'\t' '$2 != "ok" { printf "%s%s", (n++ ? "," : ""), $1 }')
    _health_line state network outage 0 "$(kv probed "$n_all" failed "$n_bad" cn_direct "$cn" mode "${NETWORK_MODE:-system}" nodes "$bad")"
    f="$H/.health.net"; last=0
    [ -f "$f" ] && IFS= read -r last < "$f"
    case $last in ''|*[!0-9]*) last=0 ;; esac
    [ $(( $(now) - last )) -le "$HEALTH_OUTAGE_MERGE" ] || _health_event network ok outage probed "$n_all" failed "$n_bad" cn_direct "$cn"
    now > "$f"
    return 0
  fi
  [ -z "$sel" ] || health_failover "$sel" "$res" >/dev/null 2>&1 || true
}

# ---------- 自动线路: 选中的节点坏了就马上让核心重新选 (2.3.26) ----------
# 核心 (sing-box urltest, 见 lib/config.sh 的 AUTO / PINAUTO) 只在定时测速 (每 3 分钟) 时改选; 选中的节点坏了以后, 新连接照样交给它 (连接失败只删掉它的测速记录, 不改选),
# 最长要等 3 分钟。每分钟的服务器端口探测发现「当前选中的节点」连不上 / 超时, 就调用 Clash API 的组测速 GET /group/<组>/delay:
# 对 urltest 组它会强制测一遍组里所有节点, 然后按结果改选 (和定时测速是同一段代码: URLTest → urlTest(force) → performUpdateCheck), 返回时已经换好。
# 探测是通的 / 没探测到 (官方线路没有地址) / 总开关关着 / 本机断网 (health_nodes 判断, 换哪个节点都一样): 什么都不做。
# 走 UDP 的协议 (2.3.27): TCP 端口不通不说明节点坏了, 所以根本不做 TCP 探测; 选中的那一个由核心经它测速 (health_core_delay), 测速超时 / 失败就同样请核心重测这个组。
# 换节点不会断开已经建立的连接 (AUTO / PINAUTO 没有 interrupt_exist_connections; 坏节点上的连接会一直挂着, 应用以为还连着):
# 换了节点、而且旧节点自己的核心测速也失败了, 就断开核心里还经这个组用着旧节点的连接 (health_close_conns), 应用重连时走新节点。旧节点其实是通的 (只是慢 / 本机直连它的端口不通) 就不断开。
health_urlenc() { printf '%s' "$1" | perl -pe 's/([^A-Za-z0-9_.~-])/sprintf("%%%02X", ord($1))/ge'; }     # 路径里的节点名: 按 UTF-8 字节逐个编码 (中文 / 空格 / & / ? / # / /)
health_group_now() { # <组> -> 核心里这个自动选线组当前选中的节点 (按 UTF-8 输出, 和 servers.jsonl 里的标签一致); 核心没运行 / 没有这个组 → 空
  clash GET "/proxies/$1" 2>/dev/null | perl -MJSON::PP -e 'my $j = eval { JSON::PP->new->utf8->decode(join "", <STDIN>) }; my $n = ref $j eq "HASH" ? $j->{now} : undef;
    exit 0 unless defined $n && !ref $n && length $n; utf8::encode($n); $n =~ tr/\t\r\n/   /; print $n' 2>/dev/null
}
health_core_delay() { # <节点>  -> 结果<TAB>毫秒: 核心经这个节点访问测速地址 (GET /proxies/<节点>/delay, 地址和组测速一样, 超时 HEALTH_CORE_MS)
  # 200 {"delay":N} → ok N · 504 (到时间没测完) → timeout · 503 (测速出错) → error; 核心没响应 / 不认识这个节点 (404) / 返回看不懂 → 空 (不知道就不记, 也不据此换节点)
  local out code ms nl='
'
  out=$(curl -s -m $(( HEALTH_CORE_MS / 1000 + 2 )) --noproxy '*' -w '\n%{http_code}' -H "Authorization: Bearer $(auth_secret)" \
    "http://127.0.0.1:$UI_PORT/proxies/$(health_urlenc "$1")/delay?url=$HEALTH_TEST_URLQ&timeout=$HEALTH_CORE_MS" 2>/dev/null) || return 0
  code=${out##*"$nl"}
  case $code in
    200) ms=$(printf '%s' "${out%"$nl"*}" | sed -n 's/.*"delay": *\([0-9][0-9]*\).*/\1/p' | head -1); [ -z "$ms" ] || printf 'ok\t%s\n' "$ms" ;;
    504) printf 'timeout\t%s\n' "$HEALTH_CORE_MS" ;;
    503) printf 'error\t0\n' ;;
  esac
  return 0
}
_health_delay_of() { # <组测速的返回 (JSON)> <节点>  -> ok: 测到了它的延迟 · fail: 这次测了整组 (结果不是空的) 而它不在里面 = 它的测速失败了 · 空: 返回无效 / 空对象 (核心正在自己测速 / 接口没响应), 不知道
  printf '%s' "$1" | perl -MJSON::PP -e 'my $j = eval { JSON::PP->new->utf8->decode(join "", <STDIN>) }; exit 0 unless ref $j eq "HASH" && %$j;
    for my $k (keys %$j) { my $t = $k; utf8::encode($t); next unless $t eq $ARGV[0]; print((defined $j->{$k} && $j->{$k} =~ /^[0-9]+$/) ? "ok" : "fail"); exit 0 } print "fail"' "$2" 2>/dev/null
}
health_old_failed() { # <组测速的返回> <旧节点> <它这一分钟的探测方式>  -> 1 = 核心自己经它测速也失败了 (这时才断开还在用它的连接); 0 = 通的 / 不知道
  local v; v=$(_health_delay_of "$1" "$2")
  if [ -z "$v" ]; then      # 组测速没给出结论: 走 UDP 的节点这一分钟已经问过核心 (失败了才会走到换节点这一步); 其它节点现在单独请核心测一次
    if [ "$3" = core ]; then v=fail
    else case $(health_core_delay "$2") in ok*) v=ok ;; timeout*|error*) v=fail ;; esac; fi
  fi
  if [ "$v" = fail ]; then printf 1; else printf 0; fi
}
health_close_conns() { # <组> <旧节点>  -> 断开了几条。核心里还经这个组用着旧节点的连接 = chains 里同时有组名和旧节点 (直接选了这个节点的 Global / PIN 等不动: 重连还是它, 断了没用)
  # GET /connections → DELETE /connections/<id> (id 只接受字母数字和 -); 最多 HEALTH_CLOSE_MAX 条 / HEALTH_CLOSE_SECS 秒, 接口出错就停
  local ids id n=0 t0
  ids=$(clash GET /connections 2>/dev/null | perl -MJSON::PP -e 'my ($g, $old) = @ARGV; my $j = eval { JSON::PP->new->utf8->decode(join "", <STDIN>) };
    exit 0 unless ref $j eq "HASH" && ref $j->{connections} eq "ARRAY";
    for my $c (@{ $j->{connections} }) {
      next unless ref $c eq "HASH" && ref $c->{chains} eq "ARRAY" && defined $c->{id} && !ref $c->{id} && $c->{id} =~ /^[0-9A-Za-z-]{1,64}$/;
      my %in; for my $t (@{ $c->{chains} }) { next if !defined $t || ref $t; my $u = $t; utf8::encode($u); $in{$u} = 1 }
      print "$c->{id}\n" if $in{$old} && $in{$g} }' "$1" "$2" 2>/dev/null)
  t0=$(now)
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ "$n" -lt "$HEALTH_CLOSE_MAX" ] && [ $(( $(now) - t0 )) -lt "$HEALTH_CLOSE_SECS" ] || break
    clash DELETE "/connections/$id" >/dev/null 2>&1 || break
    n=$((n + 1))
  done <<EOF
$ids
EOF
  printf '%s' "$n"
}
health_auto_sel() { # -> 组<TAB>当前选中的节点 (每组一行): AUTO 有自己的自动线路服务器时才看, PINAUTO 固定出口有 2 个以上时才有; 总开关关着 / 核心没运行 → 空
  [ "${PROXY_ENABLED:-0}" = 1 ] || return 0
  local roles g n
  roles=$(srv_list | awk -F'\t' '{ print $5 }')
  for g in AUTO PINAUTO; do
    if [ "$g" = AUTO ]; then printf '%s\n' "$roles" | grep -qx auto || continue
    else [ "$(printf '%s\n' "$roles" | grep -cx pin)" -ge 2 ] || continue; fi
    n=$(health_group_now "$g")
    [ -z "$n" ] || printf '%s\t%s\n' "$g" "$n"
  done
}
health_failover() { # <组<TAB>选中的节点 行…> <探测结果: 标签<TAB>结果<TAB>毫秒<TAB>方式 行…>  (方式: 空 / bound = TCP 探测, core = 核心测速)
  # 限频 ($H/.health.retest-<组>: 时间<TAB>节点<TAB>结果): 同一个组最多每分钟一次; 结果 same (仍然选它, 而且返回的测速结果里它是通的) 时同一个节点 HEALTH_RETEST_HOLD 秒内不再触发;
  # busy (仍然选它但它没有测速结果: 核心正在自己测速 / 到时间还没测完 / 组里全部连不上 / 接口没响应) 和 changed 只受每分钟一次的限制
  local g cur r how probe f last ltag lout t0 body after out took n
  while IFS=$'\t' read -r g cur; do
    [ -n "$g" ] && [ -n "$cur" ] || continue
    r=$(printf '%s\n' "$2" | HT="$cur" LC_ALL=C awk -F'\t' '$1 == ENVIRON["HT"] { print $2; exit }')
    case $r in ''|ok) continue ;; esac
    how=$(printf '%s\n' "$2" | HT="$cur" LC_ALL=C awk -F'\t' '$1 == ENVIRON["HT"] { print $4; exit }')
    probe=$r; [ "$how" != core ] || probe="core-$r"       # 记录里分得清是 TCP 探测 (refused / timeout …) 还是核心测速 (core-timeout / core-error)
    f="$H/.health.retest-$g"; last=0; ltag=''; lout=''
    [ -f "$f" ] && IFS=$'\t' read -r last ltag lout < "$f"
    case $last in ''|*[!0-9]*) last=0 ;; esac
    t0=$(now)
    [ $(( t0 - last )) -ge "$HEALTH_RETEST_GAP" ] || continue
    if [ "$lout" = same ] && [ "$ltag" = "$cur" ] && [ $(( t0 - last )) -lt "$HEALTH_RETEST_HOLD" ]; then continue; fi
    printf '%s\t%s\tpending\n' "$t0" "$cur" > "$f"           # 先占位: 同时跑的另一次定时任务不会再触发一次
    body=$(curl -s -m $(( HEALTH_RETEST_MS / 1000 + 4 )) --noproxy '*' -H "Authorization: Bearer $(auth_secret)" \
      "http://127.0.0.1:$UI_PORT/group/$g/delay?url=$HEALTH_TEST_URLQ&timeout=$HEALTH_RETEST_MS" 2>/dev/null) || body=''
    after=$(health_group_now "$g")
    if [ -n "$after" ] && [ "$after" != "$cur" ]; then
      out=changed; took=$(( $(now) - t0 )); n=''
      if [ "$(health_old_failed "$body" "$cur" "$how")" = 1 ]; then n=$(health_close_conns "$g" "$cur"); case $n in ''|0|*[!0-9]*) n='' ;; esac; fi
      _health_event auto_select "$cur" "$after" group "$g" probe "$probe" took_s "$took" closed "$n"
    elif [ "$(_health_delay_of "$body" "$cur")" = ok ]; then out=same
    else out=busy; fi
    printf '%s\t%s\t%s\n' "$t0" "$cur" "$out" > "$f"
  done <<EOF
$1
EOF
}

# ---------- 经本机代理访问关键站点 (每 ~5 分钟) ----------
health_chain() { # <选择器> -> a>b>c: 沿着选择器当前的选择最多跟 3 层 (svc-chatgpt>PIN>Tokyo-Fix = 这条连接实际用了哪个出口)
  local cur=$1 out=$1 i nxt enc
  for i in 1 2 3; do
    case $cur in *[!A-Za-z0-9_.~-]*) enc=$(printf '%s' "$cur" | perl -pe 's/([^A-Za-z0-9_.~-])/sprintf("%%%02X", ord($1))/ge') ;; *) enc=$cur ;; esac
    nxt=$(clash GET "/proxies/$enc" 2>/dev/null | sed -n 's/.*"now": *"\([^"]*\)".*/\1/p' | head -1)
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
  local T now_ last=0 gap lc=0 f="$H/.health.tick" c="$H/.health.canary" cpid=''
  mkdir -p "$LOGS"; T=$(mktemp); HEALTH_TS=$(date '+%F %T'); now_=$(now)
  [ -f "$f" ] && IFS= read -r last < "$f"
  printf '%s\n' "$now_" > "$f"
  gap=$(( now_ - ${last:-0} ))
  if [ "${last:-0}" -gt 0 ] && [ "$gap" -gt 180 ]; then _health_line tick gap gap "$gap" "$(kv note "no tick for ${gap}s (sleep or background pause)")" >> "$T"; fi
  health_state_tick >> "$T" 2>/dev/null || true
  # 金丝雀 (每 ~5 分钟) 在后台和服务器探测同时跑: 断网判断 (health_nodes) 要用同一分钟里对照站点的结果, 这一分钟的任务也不因此变长; 写进记录时仍排在 node 行后面
  [ -f "$c" ] && IFS= read -r lc < "$c"
  if [ $(( now_ - ${lc:-0} )) -ge "$HEALTH_CANARY_EVERY" ]; then now > "$c"; ( health_canaries > "$T.can" 2>/dev/null ) & cpid=$!; fi
  health_nodes "$T.can" "$cpid" >> "$T" 2>/dev/null || true
  [ -z "$cpid" ] || wait "$cpid" 2>/dev/null || true       # health_nodes 没有服务器可探测时不等它
  [ ! -s "$T.can" ] || cat "$T.can" >> "$T"
  if [ -s "$T" ]; then cat "$T" >> "$(health_file)"; fi
  rm -f "$T" "$T.can"
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
