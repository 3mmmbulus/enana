# DNS 设置: 国内域名 → 国内 DNS(直连); 其它域名 → 海外 DNS(经代理, 防污染/防泄漏)。依赖 common.sh。
#
# 注意范围: 这里只管「代理核心自己发起的解析」(直连网站、规则匹配时的解析)。通过代理访问的网站由服务器解析,
# 本机其它程序仍用系统 DNS (系统代理模式不改系统 DNS)。设置保存在 $H/dns.conf (KEY=VALUE, 不会被当作脚本执行)。

DNS_KEYS="CN CN_CUSTOM GLOBAL GLOBAL_CUSTOM VIA STRATEGY LEAK ADS"
DNS_PRESETS=${ENANA_DNS_PRESETS:-$DATA/dns-presets.conf}      # 测试时可指向本地的预设表
DNS_HOSTS_FILE=${DNS_HOSTS_FILE:-$H/hosts.tsv}               # 自定义解析 (hosts): 域名|IP, 每行一条
DNS_HOSTS_MAX=200
DNS_ERR=''

dns_load() { # 读 dns.conf (只取白名单键) -> DNS_<KEY>
  DNS_CN=alidns; DNS_CN_CUSTOM=; DNS_GLOBAL=cloudflare; DNS_GLOBAL_CUSTOM=; DNS_VIA=Global; DNS_STRATEGY=prefer_ipv4; DNS_LEAK=1; DNS_ADS=0
  [ -f "$H/dns.conf" ] || return 0
  local k v
  for k in $DNS_KEYS; do
    v=$(sed -n "s/^$k=//p" "$H/dns.conf" | head -1)
    [ -n "$v" ] || continue
    eval "DNS_$k=\$v"
  done
}

dns_preset_field() { awk -F'|' -v s="$1" -v i="$2" -v f="$3" '$1==s && $2==i {print $f; exit}' "$DNS_PRESETS" 2>/dev/null; }
dns_url_for() { # cn|global -> 实际 URL
  local id custom
  if [ "$1" = cn ]; then id=$DNS_CN; custom=$DNS_CN_CUSTOM; else id=$DNS_GLOBAL; custom=$DNS_GLOBAL_CUSTOM; fi
  if [ "$id" = custom ]; then printf '%s' "$custom"; else dns_preset_field "$1" "$id" 5; fi
}
dns_valid_url() { # system / udp:// tls:// https://  (自定义 URL 的白名单校验)
  [ "$1" = system ] && return 0
  [ ${#1} -le 200 ] && printf '%s' "$1" | LC_ALL=C grep -Eq '^(udp|tls|https)://(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9.-]+)(:[0-9]{1,5})?(/[A-Za-z0-9._~/%-]*)?$'
}

dns_server_json() { # dns_server_json <tag> <url> [detour]  -> 一个 sing-box DNS 服务器对象
  local tag=$1 url=$2 detour=${3:-} scheme rest hostport host port path='' extra=''
  case $url in system|'') printf '{"type":"local","tag":"%s"}' "$tag"; return ;; esac
  scheme=${url%%://*}; rest=${url#*://}; hostport=${rest%%/*}
  case $rest in */*) path=/${rest#*/} ;; esac
  case $hostport in
    \[*\]*) host=${hostport%%]*}; host=${host#\[}; port=${hostport#*]}; port=${port#:} ;;
    *) host=${hostport%%:*}; case $hostport in *:*) port=${hostport##*:} ;; *) port= ;; esac ;;
  esac
  [ -n "$port" ] && extra=",\"server_port\":$port"
  if [ "$scheme" = https ]; then extra="$extra,\"path\":\"${path:-/dns-query}\""; fi
  case $host in *[!0-9.]*:*|*:*) ;; *[!0-9.]*) extra="$extra,\"domain_resolver\":\"dns-local\"" ;; esac     # 域名需要引导解析, IP 不需要
  [ -n "$detour" ] && extra="$extra,\"detour\":\"$detour\""
  printf '{"type":"%s","tag":"%s","server":"%s"%s}' "$scheme" "$tag" "$host" "$extra"
}

# ---------------------------------------------------------------- 自定义解析 (hosts): 域名|IP, 每行一条
# 生效方式: ① DNS 里有一个 hosts 服务器, 命中的域名直接返回你填的 IP (「测试解析」也能看到)
#           ② 路由里对每个域名加一条 route-options(override_address): 所有连接 (直连 / 经代理) 都改连这个 IP, 和系统 hosts 文件的效果一致
_HOSTS_OK='$1 ~ /^[a-z0-9.-]+$/ && $2 ~ /^[0-9a-f:.]+$/ '       # awk 条件: 只放行格式合法的行 (文件被手工改坏也不会写进配置)
dns_hosts_list() { [ -f "$DNS_HOSTS_FILE" ] && cat "$DNS_HOSTS_FILE"; return 0; }
dns_hosts_count() { dns_hosts_list | awk -F'|' "$_HOSTS_OK"'{ n++ } END { print n + 0 }'; }
dns_hosts_json() { dns_hosts_list | awk -F'|' "$_HOSTS_OK"'{ printf "%s{\"domain\":\"%s\",\"ip\":\"%s\"}", (n++ ? "," : ""), $1, $2 }'; }
dns_hosts_server_json() { # sing-box 的 hosts 服务器对象 (没有记录时无输出)
  dns_hosts_list | awk -F'|' "$_HOSTS_OK"'{ printf "%s\"%s\":[\"%s\"]", (n++ ? "," : ""), $1, $2 } END { if (n) printf "}}\n" }' | sed 's/^/{"type":"hosts","tag":"dns-hosts","predefined":{/'
}
dns_hosts_route_rules() { # 每条记录一行 JSON (config.sh 放进路由规则最前面)
  dns_hosts_list | awk -F'|' "$_HOSTS_OK"'{ printf "{\"domain\":[\"%s\"],\"action\":\"route-options\",\"override_address\":\"%s\"}\n", $1, $2 }'
}
dns_ip_valid() { # IPv4 (点分十进制, 不带前导零) 或 IPv6
  local ip=$1
  case $ip in ''|*[!0-9a-f:.]*) return 1 ;; esac
  [ ${#ip} -le 45 ] || return 1
  case $ip in
    *:*) perl -MSocket=inet_pton,AF_INET6 -e 'exit(defined inet_pton(AF_INET6, $ARGV[0]) ? 0 : 1)' -- "$ip" ;;
    *)   printf '%s\n' "$ip" | grep -Eq '^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$' && perl -MSocket=inet_pton,AF_INET -e 'exit(defined inet_pton(AF_INET, $ARGV[0]) ? 0 : 1)' -- "$ip" ;;
  esac
}
# dns_hosts_edit <add|update|remove> <域名> [IP] [新域名]   成功 0; 失败 1, 原因在 DNS_ERR (中文原文)
dns_hosts_edit() {
  local act=$1 d ip new has=0 n
  DNS_ERR=''
  d=$(site_domain_norm "$2"); ip=$(printf '%s' "${3:-}" | tr 'A-F' 'a-f' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'); new=$(site_domain_norm "${4:-}")
  site_domain_valid "$d" || { DNS_ERR="域名格式不正确: 只能是字母 / 数字 / 连字符和点, 不含 http://、路径、空格和通配符 (中文域名请填 xn-- 开头的写法)"; return 1; }
  touch "$DNS_HOSTS_FILE"
  awk -F'|' -v d="$d" '$1==d{f=1} END{exit f?0:1}' "$DNS_HOSTS_FILE" && has=1
  case $act in
    add)
      [ "$has" = 0 ] || { DNS_ERR="这个域名已经有解析记录了, 请直接修改它"; return 1; }
      dns_ip_valid "$ip" || { DNS_ERR="IP 地址格式不正确 (支持 IPv4 和 IPv6)"; return 1; }
      n=$(wc -l < "$DNS_HOSTS_FILE" | tr -d ' '); [ "$n" -lt "$DNS_HOSTS_MAX" ] || { DNS_ERR="自定义解析太多了 (最多 $DNS_HOSTS_MAX 条)"; return 1; }
      printf '%s|%s\n' "$d" "$ip" >> "$DNS_HOSTS_FILE" ;;
    update)
      [ "$has" = 1 ] || { DNS_ERR="没有这条解析记录"; return 1; }
      [ -n "$new" ] || new=$d
      [ -n "$ip" ] || ip=$(awk -F'|' -v d="$d" '$1==d{print $2; exit}' "$DNS_HOSTS_FILE")        # 只改域名时沿用原来的 IP
      site_domain_valid "$new" || { DNS_ERR="新的域名格式不正确"; return 1; }
      dns_ip_valid "$ip" || { DNS_ERR="IP 地址格式不正确 (支持 IPv4 和 IPv6)"; return 1; }
      if [ "$new" != "$d" ] && awk -F'|' -v d="$new" '$1==d{f=1} END{exit f?0:1}' "$DNS_HOSTS_FILE"; then DNS_ERR="新的域名已经有解析记录了"; return 1; fi
      awk -F'|' -v OFS='|' -v d="$d" -v nd="$new" -v ip="$ip" '$1==d { print nd, ip; next } { print }' "$DNS_HOSTS_FILE" > "$DNS_HOSTS_FILE.new" && mv "$DNS_HOSTS_FILE.new" "$DNS_HOSTS_FILE" ;;
    remove)
      [ "$has" = 1 ] || { DNS_ERR="没有这条解析记录"; return 1; }
      awk -F'|' -v d="$d" '$1!=d' "$DNS_HOSTS_FILE" > "$DNS_HOSTS_FILE.new" && mv "$DNS_HOSTS_FILE.new" "$DNS_HOSTS_FILE" ;;
    *) DNS_ERR="操作无效"; return 1 ;;
  esac
  return 0
}
dns_hosts_reset() { rm -f "$DNS_HOSTS_FILE"; }

# ---------------------------------------------------------------- DNS 服务器测速 (后台任务 dns-bench, 结果在任务的 result 里)
# 国内预设直连测; 海外预设经「DNS 使用的线路」(自动线路 / 固定出口) 测 —— 和真正查询时走的路径一致。
# 每个服务器测一次「稳定状态下的一次查询」: DoH = 同一条连接上的第二次请求; UDP = dig 的 Query time; DoT = TCP 连接耗时 (≈ 网络往返)。
dns_dnsq_b64() { # 域名 -> base64url 的 DNS A 记录查询报文 (DoH GET 的 ?dns= 参数)
  perl -MMIME::Base64 -e '$q = pack("n6", 0, 0x0100, 1, 0, 0, 0) . join("", map { chr(length) . $_ } split /\./, $ARGV[0]) . "\0" . pack("n2", 1, 1); $b = encode_base64($q, ""); $b =~ tr{+/}{-_}; $b =~ s/=+$//; print $b' -- "$1"
}
dns_bench_one() { # <url> <查询的域名> [代理 URL]  -> 打印毫秒; 不通则没有输出
  local url=$1 name=$2 px=${3:-} scheme rest hostport host port q out k='' t
  scheme=${url%%://*}; rest=${url#*://}; hostport=${rest%%/*}
  case $hostport in
    \[*\]*) host=${hostport%%]*}; host=${host#\[}; port=${hostport#*]}; port=${port#:} ;;
    *) host=${hostport%%:*}; case $hostport in *:*) port=${hostport##*:} ;; *) port= ;; esac ;;
  esac
  case $host in 127.*|localhost|::1) k=-k ;; esac                # 只有本机回环地址 (测试用的本地服务) 才不校验证书
  case $scheme in
    https)
      q=$(dns_dnsq_b64 "$name")
      out=$(curl -s $k -o /dev/null -o /dev/null -H 'accept: application/dns-message' --connect-timeout 3 --max-time 6 ${px:+-x "$px"} -w '%{http_code} %{time_total}\n' "$url?dns=$q" "$url?dns=$q" 2>/dev/null | tail -1)
      [ "${out%% *}" = 200 ] && awk -v t="${out#* }" 'BEGIN { printf "%d", t * 1000 + 0.5 }' ;;
    udp)
      if [ "${ENANA_PLATFORM:-darwin}" = windows ]; then windows_node dns-probe "$host" "${port:-53}" "$name" 2>/dev/null; return 0; fi
      out=$(/usr/bin/dig +time=2 +tries=1 +noall +stats -p "${port:-53}" "@$host" "$name" A 2>/dev/null | sed -n 's/.*Query time: \([0-9]*\) msec.*/\1/p' | head -1)
      [ -z "$out" ] || printf '%s' "$out" ;;
    tls)      # 只要 TCP 连接耗时 (≈ 网络往返); 用 perl 在进程内计时 (curl 的 time_connect 在 macOS 上对 TLS 连接不准)
      t=$(perl -MIO::Socket::IP -MTime::HiRes=time -e '$t = time; IO::Socket::IP->new(PeerAddr => $ARGV[0], PeerPort => $ARGV[1], Proto => "tcp", Timeout => 3) or exit 1; printf "%d", (time - $t) * 1000 + 0.5' -- "$host" "${port:-853}" 2>/dev/null) && printf '%s' "$t" ;;
  esac
  return 0
}
dns_bench() { # 后台任务: 逐个测 (并行会互相抢带宽, 数字偏大); 国内直连, 海外经 DNS 使用的线路
  local scope id url px='' via=direct name out first v
  dns_load
  job_step 0 5 "准备"
  speed_lock 30 || { job_fail "测速或 IP 查询正在使用线路, 请稍后重试"; return 1; }
  if speed_node_ready; then px=$(speed_proxy_url); via=$DNS_VIA; speed_route_select "$DNS_VIA"; fi
  out=''
  for scope in cn global; do
    if [ "$scope" = cn ]; then job_step 1 20 "测试国内 DNS"; name=www.baidu.com; else job_step 2 60 "测试海外 DNS"; name=www.google.com; fi
    out="$out${out:+,}\"$scope\":["; first=1
    while IFS='|' read -r _ id _ _ url; do
      case $id in system|custom|'') continue ;; esac
      v=$(dns_bench_one "$url" "$name" "$([ "$scope" = global ] && printf '%s' "$px")")
      out="$out$([ "$first" = 1 ] || printf ,){\"id\":\"$id\",\"ms\":${v:-null}}"; first=0
    done < <(awk -F'|' -v s="$scope" '$1==s' "$DNS_PRESETS")
    out="$out]"
  done
  speed_route_select direct 2>/dev/null || true; speed_unlock
  job_ok "完成" "{$out,\"via\":\"$via\"}"
}

dns_block_json() { # dns_block_json <have 文件(已就绪且启用的规则集 tag)>  -> 整个 "dns":{...} 片段 (无结尾逗号)
  dns_load
  local cn_url gl_url servers rules='' final
  cn_url=$(dns_url_for cn); gl_url=$(dns_url_for global)
  dns_valid_url "$cn_url" || cn_url=system; dns_valid_url "$gl_url" || gl_url=https://1.1.1.1/dns-query
  servers='{"type":"local","tag":"dns-local"}'
  servers="$servers,$(dns_server_json dns-cn "$cn_url")"
  if [ "$DNS_LEAK" = 1 ]; then servers="$servers,$(dns_server_json dns-global "$gl_url" "$DNS_VIA")"; fi
  if [ "$(dns_hosts_count)" -gt 0 ]; then       # 自定义解析排在最前面: 命中的域名直接用你填的 IP
    servers="$servers,$(dns_hosts_server_json)"
    rules="{\"domain\":[$(dns_hosts_list | awk -F'|' "$_HOSTS_OK"'{ printf "%s\"%s\"", (n++ ? "," : ""), $1 }')],\"action\":\"route\",\"server\":\"dns-hosts\"}"
  fi
  # TUN also intercepts public DNS. The master-off mode must not keep sending
  # DNS over the proxy just because leak guard's normal final server is global.
  rules="$rules${rules:+,}{\"clash_mode\":\"Direct\",\"action\":\"route\",\"server\":\"dns-cn\"}"
  if [ "$DNS_ADS" = 1 ] && grep -qx geosite-ads "$1" 2>/dev/null; then rules="$rules${rules:+,}{\"rule_set\":[\"geosite-ads\"],\"action\":\"reject\"}"; fi
  if grep -qx geosite-cn "$1" 2>/dev/null; then rules="$rules${rules:+,}{\"rule_set\":[\"geosite-cn\"],\"action\":\"route\",\"server\":\"dns-cn\"}"; fi
  final=dns-cn; [ "$DNS_LEAK" = 1 ] && final=dns-global
  # reverse_mapping: 记住「IP → 域名」, 日志和连接列表里直接用 IP 访问的连接也能显示域名。
  # (核心 1.14 起各 DNS 服务器的缓存互相独立, 不需要也不应该再写 independent_cache)
  printf '"dns":{"servers":[%s],"rules":[%s],"final":"%s","strategy":"%s","reverse_mapping":true}' "$servers" "$rules" "$final" "$DNS_STRATEGY"
}

# dns_set: 从键值参数写入 dns.conf (调用方已 urldecode). 参数形如 CN=alidns LEAK=1 ...; 非法值返回 1 并在 DNS_ERR 里说明
dns_set() {
  local kv k v tmp="$H/dns.conf.new"
  dns_load
  for kv in "$@"; do
    k=${kv%%=*}; v=${kv#*=}
    case $k in
      CN)     [ -n "$(dns_preset_field cn "$v" 2)" ] || { DNS_ERR="未知的国内 DNS 预设"; return 1; }; DNS_CN=$v ;;
      GLOBAL) [ -n "$(dns_preset_field global "$v" 2)" ] || { DNS_ERR="未知的海外 DNS 预设"; return 1; }; DNS_GLOBAL=$v ;;
      CN_CUSTOM)     dns_valid_url "$v" || [ -z "$v" ] || { DNS_ERR="国内自定义 DNS 地址格式不正确"; return 1; }; DNS_CN_CUSTOM=$v ;;
      GLOBAL_CUSTOM) { dns_valid_url "$v" && [ "$v" != system ]; } || [ -z "$v" ] || { DNS_ERR="海外自定义 DNS 地址格式不正确"; return 1; }; DNS_GLOBAL_CUSTOM=$v ;;
      VIA)      case $v in Global|PIN) DNS_VIA=$v ;; *) DNS_ERR="线路只能是 自动线路 或 固定出口"; return 1 ;; esac ;;
      STRATEGY) case $v in prefer_ipv4|ipv4_only|prefer_ipv6|ipv6_only) DNS_STRATEGY=$v ;; *) DNS_ERR="IP 策略无效"; return 1 ;; esac ;;
      LEAK) case $v in 0|1) DNS_LEAK=$v ;; *) DNS_ERR="防泄漏取值无效"; return 1 ;; esac ;;
      ADS)  case $v in 0|1) DNS_ADS=$v ;; *) DNS_ERR="屏蔽广告取值无效"; return 1 ;; esac ;;
      *) ;;
    esac
  done
  [ "$DNS_CN" = custom ] && ! dns_valid_url "$DNS_CN_CUSTOM" && { DNS_ERR="选择了自定义国内 DNS, 请填写地址"; return 1; }
  [ "$DNS_GLOBAL" = custom ] && ! { dns_valid_url "$DNS_GLOBAL_CUSTOM" && [ "$DNS_GLOBAL_CUSTOM" != system ]; } && { DNS_ERR="选择了自定义海外 DNS, 请填写地址"; return 1; }
  printf 'CN=%s\nCN_CUSTOM=%s\nGLOBAL=%s\nGLOBAL_CUSTOM=%s\nVIA=%s\nSTRATEGY=%s\nLEAK=%s\nADS=%s\n' \
    "$DNS_CN" "$DNS_CN_CUSTOM" "$DNS_GLOBAL" "$DNS_GLOBAL_CUSTOM" "$DNS_VIA" "$DNS_STRATEGY" "$DNS_LEAK" "$DNS_ADS" > "$tmp" && mv "$tmp" "$H/dns.conf"
}

_dns_name() { # cn|global -> 显示名
  local id url
  if [ "$1" = cn ]; then id=$DNS_CN; else id=$DNS_GLOBAL; fi
  if [ "$id" = custom ]; then url=$(dns_url_for "$1"); printf '自定义 (%s)' "${url#*://}"; else dns_preset_field "$1" "$id" 3; fi
}
_dns_presets_json() { # cn|global -> [{id,name,desc,url}]
  awk -F'|' -v s="$1" 'BEGIN{printf "["} $1==s {printf "%s{\"id\":\"%s\",\"name\":\"%s\",\"desc\":\"%s\",\"url\":\"%s\"}", (n++?",":""), $2, $3, $4, $5} END{printf "]"}' "$DNS_PRESETS"
}

dns_state_json() { # GET /api/dns 的主体 (不含最外层 ok)
  dns_load
  local via_name='直连' cnn gln pipe='' nh
  cnn=$(_dns_name cn); gln=$(_dns_name global); nh=$(dns_hosts_count)
  if [ "$DNS_LEAK" = 1 ]; then case $DNS_VIA in PIN) via_name='经固定出口' ;; *) via_name='经自动线路' ;; esac; fi
  [ "$nh" -gt 0 ] && pipe="{\"id\":\"hosts\",\"match\":\"自定义解析 ($nh 条)\",\"server\":\"本地对照表\",\"via\":\"-\",\"detail\":\"命中的域名直接用你填的 IP, 不再询问任何 DNS; 访问时也会直接连到这个 IP\"}"
  [ "$DNS_ADS" = 1 ] && pipe="$pipe${pipe:+,}{\"id\":\"ads\",\"match\":\"广告与追踪域名 (geosite-ads)\",\"server\":\"拒绝解析\",\"via\":\"-\",\"detail\":\"直接返回空结果, 相关连接也会被拒绝\"}"
  pipe="$pipe${pipe:+,}{\"id\":\"direct\",\"match\":\"直连的网站 (含你设为「直连」的应用与网站)\",\"server\":\"$cnn\",\"via\":\"直连\",\"detail\":\"直连的网站一律用国内 DNS 解析: 苹果、微软等在国内有 CDN 的域名会解析到离你最近的节点, 速度更快\"}"
  pipe="$pipe,{\"id\":\"cn\",\"match\":\"国内网站 (geosite-cn)\",\"server\":\"$cnn\",\"via\":\"直连\",\"detail\":\"国内域名用国内 DNS 解析, 速度快、结果准确\"}"
  pipe="$pipe,{\"id\":\"proxy\",\"match\":\"经代理访问的网站\",\"server\":\"代理服务器\",\"via\":\"经代理\",\"detail\":\"域名直接交给代理服务器解析, 本机不会向任何 DNS 询问, 不会被污染或泄漏\"}"
  if [ "$DNS_LEAK" = 1 ]; then
    pipe="$pipe,{\"id\":\"global\",\"match\":\"其它所有域名\",\"server\":\"$gln\",\"via\":\"$via_name\",\"detail\":\"只有规则判断需要时才会解析; 海外域名通过代理解析, 避免本地 DNS 污染与泄漏\"}"
  else
    pipe="$pipe,{\"id\":\"global\",\"match\":\"其它所有域名\",\"server\":\"$cnn\",\"via\":\"直连\",\"detail\":\"防泄漏已关闭: 所有解析都用国内 DNS (可能被污染)\"}"
  fi
  printf '"settings":{"cn":"%s","cn_custom":"%s","global":"%s","global_custom":"%s","via":"%s","strategy":"%s","leak_guard":%s,"ads_block":%s},"presets":{"cn":%s,"global":%s},"hosts":[%s],"pipeline":[%s]' \
    "$DNS_CN" "$DNS_CN_CUSTOM" "$DNS_GLOBAL" "$DNS_GLOBAL_CUSTOM" "$DNS_VIA" "$DNS_STRATEGY" "$([ "$DNS_LEAK" = 1 ] && echo true || echo false)" "$([ "$DNS_ADS" = 1 ] && echo true || echo false)" \
    "$(_dns_presets_json cn)" "$(_dns_presets_json global)" "$(dns_hosts_json)" "$pipe"
}
