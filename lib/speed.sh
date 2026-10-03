# 本机 IP 查询 + 多线路测速 (仪表盘「测速」页)。依赖 common.sh config.sh(clash) servers.sh jobs.sh logs.sh(_AWK_ESC) i18n.sh。
#
# 原理: 核心里有一个只给测速用的本地入站 (127.0.0.1:$SPEED_PORT) 和一个选择器 SPEEDTEST (成员: direct / PIN / Global / 每个节点)。
#       测某个节点时先把 SPEEDTEST 切到它, 再让 curl 走这个入站 — 流量只走被测节点, 不影响用户正常的分流。
#       「本地直连」直接用 curl --noproxy (不经过核心), 测的是这台电脑真实的直连网络。
# 状态文件 (都在 $H/speedtest/ 下, 不含任何账号/服务器密码):
#   <id>.sel 选择 · <id>.meta 进度 · <id>.routes/.targets 列与行 · <id>.cells 每格结果(追加) · <id>.speeds 下载速度 · <id>.ip IP 汇总 · <id>.pid/.stop
#   last 最近一次结束的任务 id;  $H/netinfo.json  本机 IP 缓存
# 判定 IP 是否受限是启发式的 (只作参考): 有 HTTP 响应但状态码不在期望集合里(403/429/451…)=「受限」, 完全没响应=「失败」。

SPEED_CONF=${ENANA_SPEEDTEST_CONF:-$DATA/speedtest.conf}      # 测试时可指向本地目标
SPEED_IP_URL=${ENANA_IPLOOKUP_URL:-https://ipwho.is/}
SPEED_IP_URL2=${ENANA_IPLOOKUP_URL2:-https://www.cloudflare.com/cdn-cgi/trace}
SPEED_UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15'
SPEED_SLOW_MS=800
SPEED_PAR=8
SPEED_MAX_NODES=12
SPEED_FILE_SECS=8

speed_dir() { printf '%s/speedtest' "$H"; }
speed_id_ok() { case $1 in st-[0-9]*-[0-9]*) case $1 in *[!A-Za-z0-9-]*) return 1 ;; esac; return 0 ;; esac; return 1; }
speed_proxy_url() { printf 'http://127.0.0.1:%s' "$SPEED_PORT"; }

speed_lock() { # 选择器是共享资源: IP 查询与测速不能同时切换它
  local i=0
  while ! mkdir "$H/.speed.lock" 2>/dev/null; do
    if [ -n "$(find "$H/.speed.lock" -maxdepth 0 -mmin +5 2>/dev/null)" ]; then rmdir "$H/.speed.lock" 2>/dev/null || true; continue; fi
    i=$((i+1)); [ "$i" -gt "${1:-60}" ] && return 1; sleep 0.5
  done
}
speed_unlock() { rmdir "$H/.speed.lock" 2>/dev/null || true; }

speed_nodes() { srv_list | awk -F'\t' '$5=="pin"||$5=="auto"{print $1 "\t" $5}'; }   # tag<TAB>role (只有 pin/auto 会写进核心配置)
speed_node_ready() { [ -n "$(speed_nodes | head -1)" ] && nc -z 127.0.0.1 "$SPEED_PORT" 2>/dev/null; }
speed_route_select() { clash PUT /proxies/SPEEDTEST "{\"name\":\"$(jesc "$1")\"}" >/dev/null 2>&1; sleep 0.3; }

# ---------------------------------------------------------------- 单次探测
# speed_probe <代理地址|''> <url> <期望状态码,逗号分隔>  -> st<TAB>ms<TAB>connect<TAB>ttfb<TAB>http<TAB>err
speed_probe() {
  local px=$1 url=$2 expect=$3 out rc code c t ms cm st err=''
  local args=(-sS -o /dev/null -m 7 --connect-timeout 5 -4 --max-filesize 262144 -A "$SPEED_UA" -w '%{http_code} %{time_connect} %{time_starttransfer}')
  if [ -n "$px" ]; then args+=(-x "$px"); else args+=(--noproxy '*'); fi
  out=$(curl "${args[@]}" "$url" 2>/dev/null); rc=$?
  set -- $out; code=${1:-000}; c=${2:-0}; t=${3:-0}
  ms=$(awk -v t="$t" 'BEGIN{printf "%d", t * 1000 + 0.5}'); cm=$(awk -v t="$c" 'BEGIN{printf "%d", t * 1000 + 0.5}')
  if [ "$code" = 000 ] || [ "$code" = 0 ]; then
    case $rc in 28) err=timeout ;; 6) err=dns ;; 7) err=refused ;; 35|51|58|59|60|77|83) err=tls ;; 52|55|56) err=reset ;; *) err=error ;; esac
    st=fail; ms=0; code=0
  else
    case ",$expect," in
      *",$code,"*) if [ "$ms" -gt "$SPEED_SLOW_MS" ] || [ "$rc" = 28 ]; then st=slow; else st=ok; fi ;;
      *) case $code in 5??) st=fail; err=upstream ;; *) st=limited ;; esac ;;
    esac
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$st" "$ms" "$cm" "$ms" "$code" "$err"
}

# speed_probe_route <路由 id> <代理|''> <cells 文件> <targets 文件(tsv: id group zh en url expect icon)>  并发探测所有目标
speed_probe_route() {
  local rid=$1 px=$2 cells=$3 tf=$4 tid grp zh en url expect icon
  while IFS=$'\t' read -r tid grp zh en url expect icon; do
    [ -n "$tid" ] || continue
    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$SPEED_PAR" ]; do sleep 0.1; done
    ( printf '%s\t%s\t%s\n' "$tid" "$rid" "$(speed_probe "$px" "$url" "$expect")" >> "$cells" ) &
  done < "$tf"
  wait
}

# speed_dl <代理|''> <url> <range|''>  -> KB/s (整数, 失败 0); 最多下载 $SPEED_FILE_SECS 秒
speed_dl() {
  local px=$1 url=$2 rng=$3 out
  local args=(-sS -o /dev/null -m "$SPEED_FILE_SECS" --connect-timeout 5 -4 -A "$SPEED_UA" -w '%{speed_download} %{size_download}')
  [ -n "$rng" ] && args+=(-r "$rng")
  if [ -n "$px" ]; then args+=(-x "$px"); else args+=(--noproxy '*'); fi
  out=$(curl "${args[@]}" "$url" 2>/dev/null || true); set -- $out
  awk -v s="${1:-0}" -v b="${2:-0}" 'BEGIN{ if (b + 0 < 100000) print 0; else printf "%d", s / 1024 }'
}

# ---------------------------------------------------------------- 本机 IP
_jstr() { sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" | head -1; }
_jnum() { sed -n "s/.*\"$1\": *\([0-9][0-9]*\).*/\1/p" | head -1; }
_ip_clean() { printf '%s' "$1" | tr -d '"\\\r\n\t' | cut -c1-80; }

# speed_ip_lookup <代理|''>  -> 设置 IPL_OK IPL_IP IPL_CC IPL_COUNTRY IPL_REGION IPL_CITY IPL_ISP IPL_ASN IPL_SRC IPL_REASON
speed_ip_lookup() {
  local px=$1 body rc code tmp; tmp=$(mktemp)
  local args=(-sS -m 6 --connect-timeout 4 -4 -A "$SPEED_UA" -o "$tmp" -w '%{http_code}')
  if [ -n "$px" ]; then args+=(-x "$px"); else args+=(--noproxy '*'); fi
  IPL_OK=0; IPL_IP=''; IPL_CC=''; IPL_COUNTRY=''; IPL_REGION=''; IPL_CITY=''; IPL_ISP=''; IPL_ASN=''; IPL_SRC=''; IPL_REASON=''
  code=$(curl "${args[@]}" "$SPEED_IP_URL" 2>/dev/null); rc=$?
  body=$(cat "$tmp")
  if [ "$code" = 200 ] && printf '%s' "$body" | grep -q '"success": *true'; then
    IPL_IP=$(printf '%s' "$body" | _jstr ip); IPL_CC=$(printf '%s' "$body" | _jstr country_code); IPL_COUNTRY=$(printf '%s' "$body" | _jstr country)
    IPL_REGION=$(printf '%s' "$body" | _jstr region); IPL_CITY=$(printf '%s' "$body" | _jstr city)
    IPL_ISP=$(printf '%s' "$body" | _jstr isp); IPL_ASN=$(printf '%s' "$body" | _jnum asn); [ -n "$IPL_ASN" ] && IPL_ASN="AS$IPL_ASN"
    IPL_SRC=ipwho.is
  else
    IPL_REASON=$(speed_reason "$rc" "$code")
    code=$(curl "${args[@]}" "$SPEED_IP_URL2" 2>/dev/null); rc=$?
    body=$(cat "$tmp")
    if [ "$code" = 200 ]; then
      IPL_IP=$(printf '%s\n' "$body" | sed -n 's/^ip=//p' | head -1 | tr -d '\r'); IPL_CC=$(printf '%s\n' "$body" | sed -n 's/^loc=//p' | head -1 | tr -d '\r'); IPL_SRC=cloudflare
    else [ -n "$IPL_REASON" ] || IPL_REASON=$(speed_reason "$rc" "$code"); fi
  fi
  rm -f "$tmp"
  # 只接受看起来像 IP 的结果
  case $IPL_IP in ''|*[!0-9A-Fa-f:.]*) IPL_IP=''; IPL_OK=0 ;; *) IPL_OK=1; IPL_REASON='' ;; esac
  [ "$IPL_OK" = 1 ] || { IPL_CC=''; IPL_COUNTRY=''; IPL_REGION=''; IPL_CITY=''; IPL_ISP=''; IPL_ASN=''; IPL_SRC=''; [ -n "$IPL_REASON" ] || IPL_REASON=error; }
}
speed_reason() { # curl 退出码 + HTTP 码 -> 简短原因
  case ${1:-0}:${2:-000} in
    28:*) echo timeout ;; 6:*) echo dns ;; 7:*) echo refused ;; 35:*|51:*|58:*|59:*|60:*|77:*) echo tls ;; 52:*|55:*|56:*) echo reset ;;
    0:000|*:000) echo error ;; *:200) echo error ;; *:*) echo "http_${2:-0}" ;;
  esac
}
speed_ip_json() { # 把 IPL_* 变成 JSON 对象的字段 (不含花括号)
  if [ "$IPL_OK" = 1 ]; then
    printf '"ok":true,"ip":"%s","country":"%s","country_name":"%s","region":"%s","city":"%s","isp":"%s","asn":"%s","source":"%s"' \
      "$(_ip_clean "$IPL_IP")" "$(_ip_clean "$IPL_CC")" "$(_ip_clean "$IPL_COUNTRY")" "$(_ip_clean "$IPL_REGION")" "$(_ip_clean "$IPL_CITY")" "$(_ip_clean "$IPL_ISP")" "$(_ip_clean "$IPL_ASN")" "$IPL_SRC"
  else printf '"ok":false,"reason":"%s"' "$(_ip_clean "$IPL_REASON")"; fi
}
speed_lan_json() {
  local iface ip=''; iface=$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')
  [ -n "$iface" ] && ip=$(ipconfig getifaddr "$iface" 2>/dev/null || true)
  printf '{"ip":"%s","iface":"%s"}' "$(_ip_clean "$ip")" "$(_ip_clean "$iface")"
}

# speed_ip_collect <输出文件>  收集 本机直连 + (有节点时) 固定出口/自动线路 的出口 IP -> JSON 文件 (包含 state/reason)
# 调用方需要已持有 speed_lock (要切换选择器)。
speed_ip_collect() {
  local out=$1 dj routes='' rid rname n_ok=0 n_tot=0 d_ok state reason='' T; T=$(mktemp -d)
  ( speed_ip_lookup ''; speed_ip_json > "$T/direct" ; printf '%s' "$IPL_OK" > "$T/direct.ok" ) &
  if speed_node_ready; then
    for rid in PIN Global; do
      grep -q "^$rid$" "$T/skip" 2>/dev/null && continue
      speed_route_select "$rid"
      speed_ip_lookup "$(speed_proxy_url)"
      if [ "$rid" = PIN ]; then rname=$(_t "固定出口"); else rname=$(_t "自动线路"); fi
      routes="$routes${routes:+,}{\"id\":\"$rid\",\"name\":\"$(jesc "$rname")\",$(speed_ip_json)}"
      n_tot=$((n_tot+1)); [ "$IPL_OK" = 1 ] && n_ok=$((n_ok+1))
    done
    speed_route_select direct
  fi
  wait
  d_ok=$(cat "$T/direct.ok" 2>/dev/null || echo 0); dj=$(cat "$T/direct" 2>/dev/null)
  if [ "$d_ok" != 1 ] && [ "$n_ok" -eq 0 ]; then state=blocked; reason=$(_t "查询不到任何出口 IP: 网络不通, 或这个 IP 被限制访问")
  elif [ "$n_tot" -gt 0 ] && [ "$n_ok" -lt "$n_tot" ]; then state=limited; reason=$(_t "部分线路查询失败: 对应节点可能不可用或出口 IP 被限制")
  else state=normal; fi
  printf '{"checked":%s,"state":"%s","reason":"%s","lan":%s,"direct":{%s},"routes":[%s]}' "$(now)" "$state" "$(jesc "$reason")" "$(speed_lan_json)" "$dj" "$routes" > "$out.new" && mv "$out.new" "$out"
  rm -rf "$T"
}

speed_netinfo_json() { # GET /api/net/info 的主体 (含 checked)
  if [ -s "$H/netinfo.json" ]; then sed 's/^{//; s/}$//' "$H/netinfo.json"; else printf '"checked":0'; fi
}
op_net_refresh() { # 后台任务: net-info
  job_step 0 10 "查询本机与各线路的出口 IP"
  speed_lock 40 || { job_fail "测速任务正在使用线路, 请稍后重试" 0; return 1; }
  speed_ip_collect "$H/netinfo.json"
  speed_unlock
  job_ok "已更新"
}

# ---------------------------------------------------------------- 测速目标: 内置 + 用户的增 / 删 / 改
# 内置目标在 $SPEED_CONF (随程序发布); 用户的改动单独存在 $SPEED_CUSTOM, 升级不会覆盖:
#   add|id|分组|名称|URL|状态码|图标    用户添加      mod|id|分组|名称|URL|状态码|图标    覆盖内置目标      hide|id    隐藏内置目标
SPEED_CUSTOM=${ENANA_SPEEDTEST_CUSTOM:-$H/speedtest-custom.tsv}
SPEED_GROUPS="global cn carrier dev media"
SPEED_ERR=''

# 全部目标 (含已隐藏的), 每行: target|id|分组|中文名|英文名|URL|状态码|图标|默认勾选|内置|已修改|已隐藏
speed_targets_all() {
  local cf=$SPEED_CUSTOM; [ -f "$cf" ] || cf=/dev/null
  awk -F'|' -v OFS='|' -v cf="$cf" '
    BEGIN { while ((getline l < cf) > 0) { split(l, a, "|")
        if (a[1] == "hide") hid[a[2]] = 1
        else if (a[1] == "mod") mod[a[2]] = a[3] "|" a[4] "|" a[5] "|" a[6] "|" a[7]
        else if (a[1] == "add") { na++; addl[na] = a[2] "|" a[3] "|" a[4] "|" a[5] "|" a[6] "|" a[7] } } }
    $1 == "target" {
      id = $2; df = ($9 == "" ? 1 : $9); md = 0
      if (id in mod) { split(mod[id], b, "|"); $3 = b[1]; $4 = b[2]; $5 = b[2]; $6 = b[3]; $7 = b[4]; $8 = b[5]; md = 1 }
      print "target", id, $3, $4, $5, $6, $7, $8, df, 1, md, ((id in hid) ? 1 : 0); next }
    END { for (i = 1; i <= na; i++) { split(addl[i], b, "|"); print "target", b[1], b[2], b[3], b[3], b[4], b[5], b[6], 1, 0, 0, 0 } }' "$SPEED_CONF"
}

speed_target_exists() { speed_targets_all | awk -F'|' -v id="$1" '$2==id{f=1} END{exit f?0:1}'; }
speed_target_builtin() { awk -F'|' -v id="$1" '$1=="target" && $2==id{f=1} END{exit f?0:1}' "$SPEED_CONF"; }

# 校验用户填的目标 (成功 0; 失败 1, SPEED_ERR 是原因, 中文原文)
speed_target_check() { # <名称> <分组> <URL> <状态码> <图标>
  local name=$1 group=$2 url=$3 exp=$4 icon=$5 nch
  case "$name$group$url$exp$icon" in *$'\n'*|*$'\r'*) SPEED_ERR="内容里不能有换行"; return 1 ;; esac
  nch=$(printf '%s' "$name" | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d ' ')          # 按字符数 (UTF-8: 去掉后续字节再数)
  [ "$nch" -ge 1 ] && [ "$nch" -le 40 ] || { SPEED_ERR="名称不能为空, 最多 40 个字符"; return 1; }
  case $name in *'|'*|*'<'*|*'>'*) SPEED_ERR="名称里不能有 | < > 这些字符"; return 1 ;; esac
  printf '%s' "$name" | LC_ALL=C grep -q '[[:cntrl:]]' && { SPEED_ERR="名称里不能有控制字符"; return 1; }
  case " $SPEED_GROUPS " in *" $group "*) ;; *) SPEED_ERR="分组无效"; return 1 ;; esac
  [ ${#url} -le 300 ] && printf '%s\n' "$url" | LC_ALL=C grep -Eq '^https?://[A-Za-z0-9._~:/?#@!$&()*+,;=%-]+$' || { SPEED_ERR="网址必须以 http:// 或 https:// 开头, 不能有空格和引号, 最长 300 个字符"; return 1; }
  printf '%s\n' "$exp" | grep -Eq '^[1-5][0-9][0-9](,[1-5][0-9][0-9]){0,9}$' || { SPEED_ERR="状态码格式不对: 用逗号分隔, 如 200,204,301"; return 1; }
  printf '%s\n' "$icon" | grep -Eq '^[a-z0-9-]{0,30}$' || { SPEED_ERR="图标名无效"; return 1; }
  return 0
}

_speed_custom_lock() { local i; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do mkdir "$H/.speed-custom.lock" 2>/dev/null && return 0; sleep 0.2; done; return 1; }
_speed_custom_unlock() { rmdir "$H/.speed-custom.lock" 2>/dev/null || true; }
_speed_custom_write() { # 参数: awk 程序 + 附加 -v; 在锁内改写自定义文件 (原子替换, 权限 600)
  local prog=$1; shift
  [ -f "$SPEED_CUSTOM" ] || : > "$SPEED_CUSTOM"
  awk -F'|' "$@" "$prog" "$SPEED_CUSTOM" > "$SPEED_CUSTOM.new" && chmod 600 "$SPEED_CUSTOM.new" && mv "$SPEED_CUSTOM.new" "$SPEED_CUSTOM"
}

# speed_target_save <id|空> <名称> <分组> <URL> <状态码> <图标>  -> 成功后目标 id 在 SPEED_ID (不要放进 $(...), 否则 SPEED_ERR 会丢)
speed_target_save() {
  local id=$1 name icon exp; name=$(printf '%s' "$2" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'); exp=${5:-200,204,301,302}; icon=${6:-}
  SPEED_ERR=''; SPEED_ID=''
  speed_target_check "$name" "$3" "$4" "$exp" "$icon" || return 1
  _speed_custom_lock || { SPEED_ERR="系统繁忙, 请重试"; return 1; }
  if [ -z "$id" ]; then
    local n; n=$(grep -c '^add|' "$SPEED_CUSTOM" 2>/dev/null || true)         # 文件还不存在时 grep 没有输出, 按 0 算
    [ "${n:-0}" -lt 100 ] || { _speed_custom_unlock; SPEED_ERR="自己添加的测速目标太多了 (最多 100 个)"; return 1; }
    n=0; id=$(printf 'u-%04x%02x' $RANDOM $((RANDOM % 256)))
    while speed_target_exists "$id" && [ $n -lt 20 ]; do id=$(printf 'u-%04x%02x' $RANDOM $((RANDOM % 256))); n=$((n + 1)); done
    _speed_custom_write 'BEGIN { OFS = "|" } { print } END { print "add", id, g, nm, u, e, ic }' -v id="$id" -v g="$3" -v nm="$name" -v u="$4" -v e="$exp" -v ic="$icon"
  else
    case $id in *[!a-z0-9_-]*|'') _speed_custom_unlock; SPEED_ERR="目标编号无效"; return 1 ;; esac
    if ! speed_target_exists "$id"; then _speed_custom_unlock; SPEED_ERR="找不到这个测速目标"; return 1; fi
    if speed_target_builtin "$id"; then
      _speed_custom_write 'BEGIN { OFS = "|" } !($1 == "mod" && $2 == id) { print } END { print "mod", id, g, nm, u, e, ic }' -v id="$id" -v g="$3" -v nm="$name" -v u="$4" -v e="$exp" -v ic="$icon"
    else
      _speed_custom_write 'BEGIN { OFS = "|" } $1 == "add" && $2 == id { print "add", id, g, nm, u, e, ic; next } { print }' -v id="$id" -v g="$3" -v nm="$name" -v u="$4" -v e="$exp" -v ic="$icon"
    fi
  fi
  _speed_custom_unlock; SPEED_ID=$id
}

speed_target_delete() { # 内置: 隐藏; 自定义: 删除
  SPEED_ERR=''; speed_target_exists "$1" || { SPEED_ERR="找不到这个测速目标"; return 1; }
  _speed_custom_lock || { SPEED_ERR="系统繁忙, 请重试"; return 1; }
  if speed_target_builtin "$1"; then
    _speed_custom_write 'BEGIN { OFS = "|" } !($1 == "hide" && $2 == id) { print } END { print "hide", id }' -v id="$1"
  else
    _speed_custom_write '!($1 == "add" && $2 == id)' -v id="$1"
  fi
  _speed_custom_unlock
}
speed_target_restore() { # 取消隐藏, 并撤销对内置目标的修改
  SPEED_ERR=''; speed_target_builtin "$1" || { SPEED_ERR="找不到这个内置测速目标"; return 1; }
  _speed_custom_lock || { SPEED_ERR="系统繁忙, 请重试"; return 1; }
  _speed_custom_write '!(($1 == "hide" || $1 == "mod") && $2 == id)' -v id="$1"
  _speed_custom_unlock
}
speed_targets_reset() { _speed_custom_lock || { SPEED_ERR="系统繁忙, 请重试"; return 1; }; rm -f "$SPEED_CUSTOM"; _speed_custom_unlock; }

speed_targets_json() { # GET /api/speedtest/targets 的主体
  local lang=${I18N_LANG:-${LANG_UI:-zh}} list
  list=$(speed_targets_all | awk -F'|' -v lang="$lang" "$_AWK_ESC"'
    { printf "%s{\"id\":\"%s\",\"group\":\"%s\",\"name\":\"%s\",\"url\":\"%s\",\"expect\":\"%s\",\"icon\":\"%s\",\"builtin\":%s,\"modified\":%s,\"hidden\":%s,\"default\":%s}",
        (n++ ? "," : ""), $2, $3, esc(lang == "zh" ? $4 : $5), esc($6), $7, esc($8), ($10 == 1 ? "true" : "false"), ($11 == 1 ? "true" : "false"), ($12 == 1 ? "true" : "false"), ($9 == 0 ? "false" : "true")
      if ($12 == 1) h++; if ($10 == 0) c++ }
    END { printf "\001%d\001%d", h, c }')
  printf '"targets":[%s],"groups":["global","cn","carrier","dev","media"],"hidden":%s,"custom":%s' "${list%%$'\001'*}" \
    "$(printf '%s' "$list" | awk -F'\001' '{print $2+0}')" "$(printf '%s' "$list" | awk -F'\001' '{print $3+0}')"
}

# ---------------------------------------------------------------- 测速计划 (默认选择 / 估算)
speed_delays() { # 打印 tag<TAB>毫秒 (核心 AUTO/PIN 组的最近延迟; 缓存 60 秒)
  local f="$H/.speed-delays" g
  if [ -f "$f" ] && [ -z "$(find "$f" -mmin +1 2>/dev/null)" ]; then cat "$f"; return 0; fi
  : > "$f.new"
  for g in AUTO PIN; do
    clash GET "/group/$g/delay?url=http%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=3000" 2>/dev/null | awk '{ s = $0
      while (match(s, /"([^"\\]|\\.)*":[0-9]+/)) { m = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH); k = m; sub(/":[0-9]+$/, "", k); sub(/^"/, "", k); v = m; sub(/.*":/, "", v); if (v + 0 > 0) print k "\t" v } }' >> "$f.new"
  done
  mv "$f.new" "$f"; cat "$f"
}

speed_plan_json() { # GET /api/speedtest/plan 的主体
  local lang=${I18N_LANG:-${LANG_UI:-zh}} tg nd defs n_def=0 nn secs mb d_ok=true n_ok=false
  [ -n "$(speed_nodes | head -1)" ] && n_ok=true
  tg=$(speed_targets_all | awk -F'|' -v lang="$lang" "$_AWK_ESC"'$12 != 1 { printf "%s{\"id\":\"%s\",\"group\":\"%s\",\"name\":\"%s\",\"url\":\"%s\",\"icon\":\"%s\",\"default\":%s}", (n++ ? "," : ""), $2, $3, esc(lang == "zh" ? $4 : $5), esc($6), esc($8), ($9 == 0 ? "false" : "true") }')
  # 节点 + 延迟; 默认选择: 固定出口(最多 2 个) + 延迟最低的自动节点, 合计 4 个
  local T; T=$(mktemp); speed_delays > "$T.d"; speed_nodes > "$T.n"
  awk -F'\t' -v dfile="$T.d" "$_AWK_ESC"'
    BEGIN { while ((getline l < dfile) > 0) { split(l, a, "\t"); dl[a[1]] = a[2] } }
    { tag[NR] = $1; role[NR] = $2; d[NR] = ($1 in dl) ? dl[$1] + 0 : 0 }
    END { printf "{\"nodes\":["
      for (i = 1; i <= NR; i++) printf "%s{\"tag\":\"%s\",\"role\":\"%s\",\"delay\":%s}", (i > 1 ? "," : ""), esc(tag[i]), role[i], (d[i] > 0 ? d[i] : "null")
      printf "],\"defaults\":["; c = 0
      for (i = 1; i <= NR && c < 2; i++) if (role[i] == "pin") { printf "%s\"%s\"", (c++ ? "," : ""), esc(tag[i]); used[i] = 1 }
      while (c < 4) { best = 0; for (i = 1; i <= NR; i++) if (!used[i] && role[i] == "auto") { if (best == 0 || (d[i] > 0 && (d[best] == 0 || d[i] < d[best]))) best = i }
        if (best == 0) break; printf "%s\"%s\"", (c++ ? "," : ""), esc(tag[best]); used[best] = 1 }
      printf "],\"count\":%d}", c }' "$T.n" > "$T.out"
  nd=$(sed 's/^{"nodes"://; s/,"defaults":.*$//' "$T.out"); defs=$(sed 's/^.*"defaults":\(\[[^]]*\]\).*$/\1/' "$T.out"); n_def=$(sed 's/.*"count":\([0-9]*\)}$/\1/' "$T.out")
  rm -f "$T" "$T.d" "$T.n" "$T.out"
  nn=${n_def:-0}; secs=$((6 + 9 + nn * 8 + 8 * 2 + nn * 8)); mb=$(( (2 + nn) * 8 ))
  printf '"direct_available":%s,"node_available":%s,"targets":[%s],"nodes":%s,"defaults":{"mode":"%s","speed":true,"nodes":%s},"est":{"seconds":%s,"mb":%s}' \
    "$d_ok" "$n_ok" "$tg" "$nd" "$([ "$n_ok" = true ] && echo both || echo direct)" "${defs:-[]}" "$secs" "$mb"
}

# ---------------------------------------------------------------- 一次测速
speed_running() { # 是否有测速正在运行 -> 0=有 (打印 id)
  local d f id pid; d=$(speed_dir)
  for f in "$d"/st-*.pid; do
    [ -f "$f" ] || continue
    id=$(basename "$f" .pid); pid=$(cat "$f" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ "$(speed_meta_get "$id" state)" = running ]; then printf '%s' "$id"; return 0; fi
  done
  return 1
}
speed_meta_set() { local f="$(speed_dir)/$1.meta" k=$2 v=$3; { grep -v "^$k=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } > "$f.new" && mv "$f.new" "$f"; }
speed_meta_get() { sed -n "s/^$2=//p" "$(speed_dir)/$1.meta" 2>/dev/null | head -1; }

# speed_start <mode> <speed 0|1> <nodes 逗号> <targets 逗号> -> 打印 id; 失败返回: 2=已有测速在跑 3=没有可测的节点 4=参数无效
speed_start() {
  local mode=$1 spd=$2 nodes=$3 tgts=$4 id d t n bad='' list=''
  case $mode in direct|node|both) ;; *) return 4 ;; esac
  case $spd in 0|1) ;; *) return 4 ;; esac
  d=$(speed_dir); mkdir -p "$d"; find "$d" -type f -mtime +2 -exec rm -f {} + 2>/dev/null || true
  speed_running >/dev/null && return 2
  if [ "$mode" != direct ]; then
    # 节点: 必须是现有的 pin/auto 服务器 (白名单), 最多 12 个; 缺省取计划里的默认选择
    if [ -z "$nodes" ]; then nodes=$(speed_plan_json | sed 's/.*"defaults":{[^}]*"nodes":\[\([^]]*\)\].*/\1/' | tr -d '"'); fi
    local IFS=','; for n in $nodes; do
      [ -n "$n" ] || continue
      speed_nodes | awk -F'\t' -v t="$n" '$1==t{f=1} END{exit f?0:1}' || { bad=1; continue; }
      list="$list${list:+$'\n'}$n"
    done
    unset IFS
    list=$(printf '%s\n' "$list" | awk 'NF && !seen[$0]++' | head -n "$SPEED_MAX_NODES")
    if [ -z "$list" ]; then if [ "$mode" = node ]; then return 3; else mode=direct; fi; fi
  fi
  id="st-$(now)-$RANDOM"
  printf 'mode=%s\nspeed=%s\n' "$mode" "$spd" > "$d/$id.sel"
  printf '%s\n' "$list" | awk 'NF' > "$d/$id.nodes"
  : > "$d/$id.cells"; : > "$d/$id.speeds"
  # 目标: 白名单 (按 id 过滤, 已隐藏的不测); 没指定 = 所有「默认勾选」的
  speed_targets_all | awk -F'|' -v want="$tgts" 'BEGIN { n = split(want, a, ","); for (i = 1; i <= n; i++) if (a[i] != "") w[a[i]] = 1 }
    $12 != 1 && ((want == "" && $9 != 0) || ($2 in w)) { print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7 "\t" $8 }' > "$d/$id.targets"
  [ -s "$d/$id.targets" ] || { rm -f "$d/$id".*; return 4; }
  printf 'state=running\nphase=ip\nmsg=%s\nstarted=%s\n' "正在查询本机 IP" "$(now)" > "$d/$id.meta"
  printf '%s' "$id"
}

speed_finish() { # <id> <done|stopped|error> [消息]
  local id=$1 st=$2 d; d=$(speed_dir)
  speed_meta_set "$id" state "$st"; speed_meta_set "$id" ended "$(now)"; [ -n "${3:-}" ] && speed_meta_set "$id" msg "$3"
  rm -f "$d/$id.pid"
  printf '%s' "$id" > "$d/last"
  speed_unlock
}
speed_abort() { # 收到 TERM: 杀掉探测子进程, 恢复选择器, 结束
  local id=$1; kill $(jobs -p) 2>/dev/null || true
  speed_route_select direct 2>/dev/null || true
  speed_finish "$id" stopped "已停止"
  exit 0
}

# speed_run <id>  (后台任务 `enana _job speedtest <id>`)
speed_run() {
  local id=$1 d mode spd tf rf rid rname n kind url rng kbps total=0 nodes_n=0 ipf
  speed_id_ok "$id" || return 1
  d=$(speed_dir); [ -f "$d/$id.sel" ] || return 1
  mode=$(sed -n 's/^mode=//p' "$d/$id.sel"); spd=$(sed -n 's/^speed=//p' "$d/$id.sel")
  tf="$d/$id.targets"; rf="$d/$id.routes"
  printf '%s\n' $$ > "$d/$id.pid"; trap 'speed_abort "$id"' TERM INT
  speed_lock 30 || { speed_finish "$id" error "测速或 IP 查询正在使用线路, 请稍后重试"; return 1; }
  # 列 (路由): 本地直连 + 选中的节点
  : > "$rf"
  [ "$mode" != node ] && printf 'direct\t%s\tdirect\t\n' "$(_t "本地直连")" >> "$rf"
  if [ "$mode" != direct ]; then
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      printf '%s\t%s\tnode\t%s\n' "$n" "$n" "$(speed_nodes | awk -F'\t' -v t="$n" '$1==t{print $2; exit}')" >> "$rf"; nodes_n=$((nodes_n+1))
    done < "$d/$id.nodes"
  fi
  total=$(( $(wc -l < "$rf") * $(wc -l < "$tf") ))
  if [ "$spd" = 1 ]; then
    [ "$mode" != node ] && total=$((total + 2))
    total=$((total + nodes_n))
  fi
  speed_meta_set "$id" total "$total"; speed_meta_set "$id" mode "$mode"; speed_meta_set "$id" speed "$spd"
  # 1) IP
  speed_meta_set "$id" phase ip; speed_meta_set "$id" msg "正在查询本机与各线路的出口 IP"
  speed_ip_collect "$d/$id.ipfull"
  cp "$d/$id.ipfull" "$H/netinfo.json" 2>/dev/null || true
  # 2) 本地直连
  if [ "$mode" != node ]; then
    speed_meta_set "$id" phase direct; speed_meta_set "$id" msg "正在测试本地直连"
    speed_probe_route direct '' "$d/$id.cells" "$tf"
  fi
  # 3) 节点 (逐个: 切换选择器 → 并发探测)
  if [ "$mode" != direct ]; then
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      [ -f "$d/$id.stop" ] && break
      speed_meta_set "$id" phase nodes; speed_meta_set "$id" msg "正在测试 $n"
      speed_route_select "$n"
      speed_probe_route "$n" "$(speed_proxy_url)" "$d/$id.cells" "$tf"
    done < "$d/$id.nodes"
  fi
  # 4) 下载速度 (国内文件只测直连; 海外文件测直连和每个节点)
  if [ "$spd" = 1 ] && [ ! -f "$d/$id.stop" ]; then
    if [ "$mode" != node ]; then
      speed_meta_set "$id" phase speed; speed_meta_set "$id" msg "正在测试下载速度: 本地直连"
      while IFS='|' read -r _ fid kind _ url rng; do
        [ "$kind" = cn ] || continue
        printf '%s\t%s\t%s\n' direct cn "$(speed_dl '' "$url" "$rng")" >> "$d/$id.speeds"; break
      done < <(grep '^file|' "$SPEED_CONF")
      while IFS='|' read -r _ fid kind _ url rng; do
        [ "$kind" = global ] || continue
        printf '%s\t%s\t%s\n' direct global "$(speed_dl '' "$url" "$rng")" >> "$d/$id.speeds"; break
      done < <(grep '^file|' "$SPEED_CONF")
    fi
    if [ "$mode" != direct ]; then
      while IFS= read -r n; do
        [ -n "$n" ] || continue
        [ -f "$d/$id.stop" ] && break
        speed_meta_set "$id" phase speed; speed_meta_set "$id" msg "正在测试下载速度: $n"
        speed_route_select "$n"
        while IFS='|' read -r _ fid kind _ url rng; do
          [ "$kind" = global ] || continue
          printf '%s\t%s\t%s\n' "$n" global "$(speed_dl "$(speed_proxy_url)" "$url" "$rng")" >> "$d/$id.speeds"; break
        done < <(grep '^file|' "$SPEED_CONF")
      done < "$d/$id.nodes"
    fi
  fi
  speed_route_select direct 2>/dev/null || true
  speed_ip_refine "$id"
  if [ -f "$d/$id.stop" ]; then speed_finish "$id" stopped "已停止"; else speed_finish "$id" done "测速完成"; fi
  oplog terminal "测速" "$mode · $nodes_n 个节点" ok 2>/dev/null || true
}

# 用探测结果修正 IP 状态: 每条线路只看「与它相关」的目标 (直连看国内/运营商, 节点看海外), 失败/受限占比高 -> limited/blocked
speed_ip_refine() {
  local id=$1 d res st reason; d=$(speed_dir)
  res=$(awk -F'\t' -v tf="$d/$id.targets" -v rf="$d/$id.routes" '
    BEGIN { while ((getline l < tf) > 0) { split(l, a, "\t"); grp[a[1]] = a[2] }
            while ((getline l < rf) > 0) { split(l, b, "\t"); kind[b[1]] = b[3] } }
    { t = $1; r = $2; s = $3; g = grp[t]
      rel = (kind[r] == "direct") ? (g == "cn" || g == "carrier") : (g == "global")
      if (!rel) next
      n[r]++; if (s == "fail") f[r]++; else if (s == "limited") lim[r]++; else ok[r]++ }
    END { worst = ""; state = "normal"; any = 0; allbad = 1
      for (r in n) { any = 1; ratio = (f[r] + lim[r]) / n[r]
        if (ratio < 0.8) allbad = 0
        if (ratio >= 0.4 || lim[r] >= 2) { state = "limited"; worst = r } }
      if (any && allbad) state = "blocked"
      print state "\t" worst }' "$d/$id.cells")
  st=${res%%$'\t'*}; reason=${res#*$'\t'}
  case $st in
    blocked) reason=$(_t "几乎所有目标都没有响应: 网络不通, 或这个 IP 被限制访问") ;;
    limited) reason=$(_t "部分目标拒绝或没有响应: 这个 IP 可能被部分网站限制") ;;
    *) reason='' ;;
  esac
  # 只在探测结果比 IP 查询更差时覆盖 (IP 查询已经判定 blocked/limited 的保留)
  local cur; cur=$(sed -n 's/.*"state":"\([a-z]*\)".*/\1/p' "$d/$id.ipfull" | head -1)
  case "$cur:$st" in blocked:*) st=blocked ;; limited:normal) st=limited ;; esac
  sed "s/\"state\":\"[a-z]*\",\"reason\":\"[^\"]*\"/\"state\":\"$st\",\"reason\":\"$(jesc "$reason")\"/" "$d/$id.ipfull" > "$d/$id.ip" 2>/dev/null || cp "$d/$id.ipfull" "$d/$id.ip"
}

speed_stop() { # <id>
  local id=$1 d pid; d=$(speed_dir); speed_id_ok "$id" || return 1
  touch "$d/$id.stop"; pid=$(cat "$d/$id.pid" 2>/dev/null)
  [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null || true
  return 0
}

# speed_render <id>  -> 完整状态 JSON (GET /api/speedtest/status 与 last)
speed_render() {
  local id=$1 d state phase msg pct started ended total done_n el lang
  speed_id_ok "$id" || { printf '{"ok":false,"code":"E_NOT_FOUND","error":"%s"}' "$(_t "找不到该测速任务")"; return; }
  d=$(speed_dir); [ -f "$d/$id.meta" ] || { printf '{"ok":false,"code":"E_NOT_FOUND","error":"%s"}' "$(_t "找不到该测速任务")"; return; }
  lang=${I18N_LANG:-${LANG_UI:-zh}}
  state=$(speed_meta_get "$id" state); phase=$(speed_meta_get "$id" phase); msg=$(speed_meta_get "$id" msg)
  started=$(speed_meta_get "$id" started); ended=$(speed_meta_get "$id" ended); total=$(speed_meta_get "$id" total)
  # 运行中的任务如果进程已经没了 (被杀/断电) -> 标记为出错
  if [ "$state" = running ]; then
    local pid; pid=$(cat "$d/$id.pid" 2>/dev/null)
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
      if [ -n "$(find "$d/$id.meta" -mmin +1 2>/dev/null)" ] || [ -z "$pid" ] && [ "$(( $(now) - ${started:-0} ))" -gt 20 ]; then speed_meta_set "$id" state error; state=error; msg="测速进程意外中断"; fi
    fi
  fi
  done_n=$(( $(cat "$d/$id.cells" "$d/$id.speeds" 2>/dev/null | wc -l) )); case $total in ''|0) total=1 ;; esac
  pct=$(( done_n * 100 / total )); [ "$pct" -gt 99 ] && pct=99; [ "$state" = running ] || pct=100; [ "$state" = error ] && pct=${pct:-0}
  if [ -n "$ended" ]; then el=$((ended - started)); else el=$(( $(now) - ${started:-0} )); fi
  printf '{"ok":true,"id":"%s","state":"%s","pct":%s,"phase":"%s","msg":"%s","started":%s,"elapsed":%s,"mode":"%s","speed":%s,' \
    "$id" "$state" "$pct" "$phase" "$(jesc "$(_t "$msg")")" "${started:-0}" "$el" "$(speed_meta_get "$id" mode)" "$([ "$(speed_meta_get "$id" speed)" = 1 ] && echo true || echo false)"
  { printf '@@ROUTES\n'; cat "$d/$id.routes" 2>/dev/null; printf '@@TARGETS\n'; cat "$d/$id.targets" 2>/dev/null
    printf '@@CELLS\n'; cat "$d/$id.cells" 2>/dev/null; printf '@@SPEEDS\n'; cat "$d/$id.speeds" 2>/dev/null; } | awk -F'\t' -v lang="$lang" "$_AWK_ESC"'
    /^@@ROUTES$/ { m = 1; next } /^@@TARGETS$/ { m = 2; next } /^@@CELLS$/ { m = 3; next } /^@@SPEEDS$/ { m = 4; next }
    m == 1 && NF { nr++; rid[nr] = $1; rname[nr] = $2; rkind[nr] = $3; rrole[nr] = $4; next }
    m == 2 && NF { nt++; tid[nt] = $1; tgrp[nt] = $2; tname[nt] = (lang == "zh" ? $3 : $4); next }
    m == 3 && NF { k = $1 SUBSEP $2; st[k] = $3; ms[k] = $4; cn[k] = $5; tf[k] = $6; hc[k] = $7; er[k] = $8; next }
    m == 4 && NF { ns++; sr[ns] = $1; sk[ns] = $2; sv[ns] = $3; next }
    END {
      printf "\"routes\":["
      for (i = 1; i <= nr; i++) printf "%s{\"id\":\"%s\",\"name\":\"%s\",\"kind\":\"%s\"%s}", (i > 1 ? "," : ""), esc(rid[i]), esc(rname[i]), rkind[i], (rrole[i] != "" ? ",\"role\":\"" rrole[i] "\"" : "")
      printf "],\"targets\":["
      for (j = 1; j <= nt; j++) printf "%s{\"id\":\"%s\",\"group\":\"%s\",\"name\":\"%s\"}", (j > 1 ? "," : ""), tid[j], tgrp[j], esc(tname[j])
      printf "],\"cells\":["; c = 0
      for (i = 1; i <= nr; i++) for (j = 1; j <= nt; j++) {
        k = tid[j] SUBSEP rid[i]
        if (k in st) {
          printf "%s{\"t\":\"%s\",\"r\":\"%s\",\"st\":\"%s\",\"ms\":%d,\"connect\":%d,\"ttfb\":%d,\"http\":%d,\"err\":\"%s\"}", (c++ ? "," : ""), tid[j], esc(rid[i]), st[k], ms[k] + 0, cn[k] + 0, tf[k] + 0, hc[k] + 0, er[k]
          n[rid[i]]++; if (st[k] == "ok" || st[k] == "slow") { okc[rid[i]]++; sum[rid[i]] += ms[k] }; if (st[k] == "limited") lim[rid[i]]++
        } else printf "%s{\"t\":\"%s\",\"r\":\"%s\",\"st\":\"pending\"}", (c++ ? "," : ""), tid[j], esc(rid[i])
      }
      printf "],\"speeds\":["
      for (i = 1; i <= ns; i++) printf "%s{\"r\":\"%s\",\"kind\":\"%s\",\"kbps\":%d}", (i > 1 ? "," : ""), esc(sr[i]), sk[i], sv[i] + 0
      printf "],\"@IP@\":0,\"summary\":{"
      best = ""; for (i = 1; i <= nr; i++) if (rkind[i] == "node" && n[rid[i]] > 0) { r = rid[i]
        if (best == "" || okc[r] > okc[best] || (okc[r] == okc[best] && okc[r] > 0 && sum[r] / okc[r] < sum[best] / okc[best])) best = r }
      if (best == "") for (i = 1; i <= nr; i++) if (n[rid[i]] > 0) { best = rid[i]; break }
      printf "\"best\":\"%s\",\"avg_ms\":{", esc(best)
      for (i = 1; i <= nr; i++) { r = rid[i]; printf "%s\"%s\":%d", (i > 1 ? "," : ""), esc(r), (okc[r] > 0 ? sum[r] / okc[r] : 0) }
      printf "},\"ok\":{"; for (i = 1; i <= nr; i++) printf "%s\"%s\":%d", (i > 1 ? "," : ""), esc(rid[i]), okc[rid[i]]
      printf "},\"total\":{"; for (i = 1; i <= nr; i++) printf "%s\"%s\":%d", (i > 1 ? "," : ""), esc(rid[i]), n[rid[i]]
      printf "},\"limited\":{"; for (i = 1; i <= nr; i++) printf "%s\"%s\":%d", (i > 1 ? "," : ""), esc(rid[i]), lim[rid[i]]
      printf "}}}" }' | sed "s/\"@IP@\":0,/\"ip\":$(speed_ip_for "$id" | sed 's/[&|\\]/\\&/g'),/"
}
speed_ip_for() { # 优先 refine 后的 <id>.ip, 否则 <id>.ipfull, 否则空对象
  local d f; d=$(speed_dir)
  for f in "$d/$1.ip" "$d/$1.ipfull"; do [ -s "$f" ] && { cat "$f"; return; }; done
  printf '{"state":"unknown"}'
}

speed_last_id() { local d; d=$(speed_dir); [ -s "$d/last" ] && cat "$d/last"; }
