# 日志: 操作记录 + 网站访问 + 代理日志 + 诊断导出。默认保留 3 天, 可改成 12 小时 – 30 天; 超期的内容每小时自动清理一次。依赖 common.sh os-darwin.sh。
#
#   $H/logs/ops-YYYY-MM-DD.log       操作记录 (制表符分隔: 时间 来源 动作 详情 结果)   —— 由辅助服务/终端命令写入, 不含任何密码或令牌
#                                    详情一律写成 key=value (值里有空格时用引号), 方便人和程序都能读懂; 见下面的 kv()
#   $H/sing-box.log                  代理核心的实时日志 (info 级别包含每条连接的目标、应用与出站)
#   $H/logs/proxy-YYYY-MM-DD.log[.gz]  每小时把实时日志按日期切开 (copytruncate), 2 天前的会被压缩
#   「网站访问」不单独存文件: 从代理日志里按连接编号归并出 时间/域名/端口/应用/出站/失败原因 (lib/access.awk), 隐私上等同于代理日志, 一起保留一起清理。
# 三种日志各有一个开关 (设置 → 日志): 操作记录 LOG_OPS · 网站访问 ACCESS_LOG · 代理核心日志 LOG_CORE。关闭只影响「之后」的记录, 已有的仍按保留期清理。
#   网站访问关闭 → 核心只记录警告和错误 (level warn); 网站访问和核心日志都关闭 → 核心完全不写日志 (log.disabled)。
#   核心日志关闭但网站访问开着 → 核心照常写 (连接记录要用), 只是把和连接无关的核心事件行在切分时丢掉、读取时不显示。
# 诊断导出 (logs_bundle): 一个自描述的文本文件, 含 环境 / 脱敏后的配置与策略 / 实时自检 / 操作记录 / 网站访问 / 代理日志, 格式见 docs/DIAGNOSTICS.md;
#   不含任何密码 / 令牌 / 服务器凭据, 服务器地址和用户名都做了打码; 但会包含访问过的域名和应用名, 只发给信任的人。

LOGS="$H/logs"
LOG_HOURS_MIN=12
LOG_HOURS_MAX=720

logs_hours_clamp() { local h=$1; case $h in ''|*[!0-9]*) h=72 ;; esac; [ "$h" -lt $LOG_HOURS_MIN ] && h=$LOG_HOURS_MIN; [ "$h" -gt $LOG_HOURS_MAX ] && h=$LOG_HOURS_MAX; echo "$h"; }
logs_hours() { logs_hours_clamp "${LOG_HOURS:-72}"; }

kv() { # kv 键 值 [键 值 …] -> 键=值 键="有 空格 的值" ...  (值里的引号 / 反斜杠转义, 制表符和换行换成空格; 空值省略不写)
  local out='' k v
  while [ $# -ge 2 ]; do
    k=$1; v=$2; shift 2
    [ -n "$v" ] || continue
    v=$(printf '%s' "$v" | tr '\t\r\n' '   ')
    case $v in *[[:space:]\"\\]*) v=${v//\\/\\\\}; v=${v//\"/\\\"}; v="\"$v\"" ;; esac
    out="$out${out:+ }$k=$v"
  done
  printf '%s' "$out"
}

oplog() { # oplog <来源 dashboard|terminal|auto> <动作> <详情 (用 kv 生成)> <结果 ok|error>   (设置里关闭了「操作记录」就不记; 关闭 / 开启这个开关本身用 oplog_force 记)
  [ "${LOG_OPS:-1}" = 1 ] || return 0
  oplog_force "$@"
}
oplog_force() {
  local f ts; mkdir -p "$LOGS"
  ts=$(date '+%F %T'); f="$LOGS/ops-${ts%% *}.log"
  printf '%s\t%s\t%s\t%s\t%s\n' "$ts" "$1" "$(printf '%s' "$2" | tr '\t\r\n' '   ' | cut -c1-60)" "$(printf '%s' "$3" | tr '\t\r\n' '   ' | cut -c1-400)" "${4:-ok}" >> "$f"
}

# 把核心实时日志按行首日期切到 logs/proxy-<日期>.log, 然后原地清空 (核心以追加方式打开文件, 不会丢失后续日志)
logs_rotate() {
  local live="$H/sing-box.log" tmp
  [ -s "$live" ] || return 0
  mkdir -p "$LOGS"; tmp=$(mktemp)
  cp "$live" "$tmp" && : > "$live"
  awk -v dir="$LOGS" -v core="${LOG_CORE:-1}" '{
      d = ""; c = substr($1, 1, 1)
      if ((c == "+" || c == "-") && $2 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) d = $2
      if (d == "") d = (last == "" ? "unknown" : last)
      last = d
      if (core != 1 && $0 !~ /\[[0-9]+ [^]]*\] /) next                # 核心日志关闭: 只留和连接有关的行 (带 [编号 耗时])
      print >> (dir "/proxy-" d ".log")
    }' "$tmp"
  rm -f "$tmp"
}

logs_compress() { # 压缩 2 天前的日志
  local f today yday d
  today=$(date +%F); yday=$(os_date_minus_days 1)
  for f in "$LOGS"/proxy-*.log "$LOGS"/ops-*.log; do
    [ -f "$f" ] || continue
    d=$(printf '%s' "$f" | sed -E 's/.*-([0-9]{4}-[0-9]{2}-[0-9]{2})\.log$/\1/')
    [ "$d" = "$today" ] || [ "$d" = "$yday" ] || gzip -9 -f "$f" 2>/dev/null || true
  done
}

_logs_trim() { # <ops|proxy> <截止时间 YYYY-MM-DD HH:MM:SS>  标准输入 -> 标准输出: 去掉早于截止时间的行 (没有时间戳的续行跟随上一行)
  case $1 in
    ops) LC_ALL=C awk -v c="$2" '{ if (substr($0, 1, 19) >= c) print }' ;;
    *)   LC_ALL=C awk -v c="$2" '{ ch = substr($0, 1, 1); if ((ch == "+" || ch == "-") && $2 ~ /^[0-9][0-9][0-9][0-9]-/) keep = (($2 " " $3) >= c); if (keep) print }' ;;
  esac
}

# 删除早于保留期 (精确到小时) 的日志: 整天都过期的文件直接删, 截止时间所在的那一天里更早的行逐行裁掉; 返回释放的字节数
logs_purge() {
  local hours cutoff cday f d kind freed=0 sz sz2 tmp
  hours=$(logs_hours); cutoff=$(os_date_minus_hours "$hours"); cday=${cutoff%% *}
  for f in "$LOGS"/*; do
    [ -f "$f" ] || continue
    d=$(printf '%s' "$f" | sed -nE 's/.*-([0-9]{4}-[0-9]{2}-[0-9]{2})\.log(\.gz)?$/\1/p')
    if [ -z "$d" ]; then   # proxy-unknown.log: 没有日期可比, 按修改时间
      case $f in */proxy-unknown.log*) if [ -n "$(find "$f" -maxdepth 0 -mmin +$((hours * 60)) 2>/dev/null)" ]; then sz=$(stat -f %z "$f" 2>/dev/null || echo 0); freed=$((freed + sz)); rm -f "$f"; fi ;; esac
      continue
    fi
    sz=$(stat -f %z "$f" 2>/dev/null || echo 0)
    if [ "$d" \< "$cday" ]; then freed=$((freed + sz)); rm -f "$f"
    elif [ "$d" = "$cday" ]; then
      case $f in */ops-*) kind=ops ;; *) kind=proxy ;; esac
      tmp=$(mktemp)
      case $f in *.gz) gzip -dc "$f" 2>/dev/null ;; *) cat "$f" ;; esac | _logs_trim "$kind" "$cutoff" > "$tmp"
      if [ -s "$tmp" ]; then
        case $f in *.gz) gzip -9 -c "$tmp" > "$f.new" ;; *) cp "$tmp" "$f.new" ;; esac
        mv "$f.new" "$f"; sz2=$(stat -f %z "$f" 2>/dev/null || echo 0); freed=$((freed + sz - sz2))
      else freed=$((freed + sz)); rm -f "$f"; fi
      rm -f "$tmp"
    fi
  done
  echo "$freed"
}

logs_maintain() { logs_rotate; logs_compress; logs_purge >/dev/null; }

logs_tick() { # 由 enana tick 每分钟调用一次; 每小时真正做一次 (切分 + 压缩 + 按保留期清理), 所以 12 小时的保留期也准
  local last=0 f="$H/.logs.last"
  [ -f "$f" ] && IFS= read -r last < "$f"
  [ $(( $(now) - ${last:-0} )) -ge 3600 ] || return 0
  now > "$f"; logs_maintain
}

# ---------- 查询 (仪表盘「日志」页) ----------
_logs_stream() { # <类型 proxy|access|ops> <日期>  -> 该天的原始行 (按时间顺序)
  local d=$2 f
  case $1 in
    ops)
      [ -f "$LOGS/ops-$d.log" ] && cat "$LOGS/ops-$d.log"
      [ -f "$LOGS/ops-$d.log.gz" ] && gzip -dc "$LOGS/ops-$d.log.gz"
      ;;
    *)
      [ -f "$LOGS/proxy-$d.log" ] && cat "$LOGS/proxy-$d.log"
      [ -f "$LOGS/proxy-$d.log.gz" ] && gzip -dc "$LOGS/proxy-$d.log.gz"
      f="$H/sing-box.log"
      [ -s "$f" ] && awk -v d="$d" -v core="${LOG_CORE:-1}" '{ c = substr($1, 1, 1); if (c == "+" || c == "-") keep = ($2 == d); if (keep && (core == 1 || $0 ~ /\[[0-9]+ [^]]*\] /)) print }' "$f" ;;
  esac
  return 0
}

logs_days() { # 打印有记录的日期 (新→旧), 每行一个
  { ls -1 "$LOGS" 2>/dev/null | sed -nE 's/^(ops|proxy)-([0-9]{4}-[0-9]{2}-[0-9]{2})\.log(\.gz)?$/\2/p'
    [ -s "$H/sing-box.log" ] && awk '{ c = substr($1,1,1); if ((c == "+" || c == "-") && $2 ~ /^[0-9][0-9][0-9][0-9]-/) print $2 }' "$H/sing-box.log"
    ls -1 "$LOGS"/ops-"$(date +%F)".log >/dev/null 2>&1 && date +%F
  } | sort -ur
}
_logs_days_json() { local out='' d; while IFS= read -r d; do out="$out${out:+,}\"$d\""; done < <(logs_days); printf '[%s]' "$out"; }

_logs_ops_localized() { # <日期>  -> 操作记录原始行, 其中「动作」「详情」翻译成当前语言
  local lang=${I18N_LANG:-${LANG_UI:-zh}} T
  if [ "$lang" = zh ] || [ ! -f "$DATA/i18n/$lang.tsv" ]; then _logs_stream ops "$1"; return 0; fi
  T=$(mktemp -d); _logs_stream ops "$1" > "$T/raw"
  cut -f3 "$T/raw" | i18n_filter > "$T/a"; cut -f4 "$T/raw" | i18n_filter > "$T/d"
  paste -d'\t' <(cut -f1,2 "$T/raw") "$T/a" "$T/d" <(cut -f5 "$T/raw")
  rm -rf "$T"
}

# 通用 JSON 转义 (awk 函数文本, 供各查询复用)
_AWK_ESC='function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/[\001-\037]/, " ", s); return s }'

_logs_access_input() { # <日期…>  -> access.awk 的标准输入: 固定出口 / 自动线路节点名 + 这些天的核心日志
  local d
  printf '%s\n' "@@PINS"; srv_list | awk -F'\t' '$5=="pin"{print $1}'
  printf '%s\n' "@@AUTOS"; srv_list | awk -F'\t' '$5=="auto"{print $1}'
  printf '%s\n' "@@LOG"
  for d in "$@"; do _logs_stream access "$d"; done
}

# logs_query <类型> <日期> <q> <limit> <offset> [筛选]  -> {"ok":true,"days":[…],"total":N,"rows":[…]}   (access 还带 summary)
#   筛选: ops: error | dashboard | terminal | auto   access: direct | proxy | error   proxy: warn (警告和错误) | error
logs_query() {
  local type=$1 day=$2 q=$3 limit=$4 off=$5 f=${6:-} rows
  case $limit in ''|*[!0-9]*) limit=500 ;; esac; [ "$limit" -gt 2000 ] && limit=2000
  case $off in ''|*[!0-9]*) off=0 ;; esac
  case $f in ''|error|warn|direct|proxy|dashboard|terminal|auto) ;; *) f='' ;; esac
  [ -n "$day" ] || day=$(date +%F)
  q=$(printf '%s' "$q" | tr '[:upper:]' '[:lower:]')
  case $type in
    ops)
      rows=$(_logs_ops_localized "$day" | awk -F'\t' -v q="$q" -v f="$f" -v lim="$limit" -v off="$off" "$_AWK_ESC"'
        { line = tolower($0); if (q != "" && index(line, q) == 0) next
          all++; if ($5 == "error") nerr++
          if (f == "error" && $5 != "error") next
          if ((f == "dashboard" || f == "terminal" || f == "auto") && $2 != f) next
          n++; a[n] = $0 }
        END { printf "{\"total\":%d,\"rows\":[", n; c = 0
          for (i = n - off; i >= 1 && c < lim; i--) { split(a[i], x, "\t"); printf "%s{\"ts\":\"%s\",\"who\":\"%s\",\"action\":\"%s\",\"detail\":\"%s\",\"result\":\"%s\"}", (c++ ? "," : ""), esc(x[1]), esc(x[2]), esc(x[3]), esc(x[4]), esc(x[5]) }
          printf "],\"summary\":{\"all\":%d,\"error\":%d}}", all + 0, nerr + 0 }') ;;
    proxy)
      rows=$(_logs_stream proxy "$day" | awk -v q="$q" -v f="$f" -v lim="$limit" -v off="$off" "$_AWK_ESC"'
        { gsub(/\033\[[0-9;]*m/, ""); line = tolower($0); if (q != "" && index(line, q) == 0) next
          lv = ""; if (match($0, /^[+-][0-9][0-9][0-9][0-9] [0-9-]+ [0-9:]+ [A-Z]+ /)) { split(substr($0, RSTART, RLENGTH), p, " "); lv = p[4] }
          all++; if (lv == "ERROR" || lv == "FATAL" || lv == "PANIC") nerr++; else if (lv == "WARN" || lv == "WARNING") nwarn++
          if (f == "error" && !(lv == "ERROR" || lv == "FATAL" || lv == "PANIC")) next
          if (f == "warn" && !(lv == "ERROR" || lv == "FATAL" || lv == "PANIC" || lv == "WARN" || lv == "WARNING")) next
          n++; a[n] = $0 }
        END { printf "{\"total\":%d,\"rows\":[", n; c = 0
          for (i = n - off; i >= 1 && c < lim; i--) { l = a[i]; ts = ""; lv = ""; msg = l
            if (match(l, /^[+-][0-9][0-9][0-9][0-9] [0-9-]+ [0-9:]+ [A-Z]+ /)) { split(substr(l, RSTART, RLENGTH), p, " "); ts = p[2] " " p[3]; lv = p[4]; msg = substr(l, RLENGTH + 1) }
            printf "%s{\"ts\":\"%s\",\"level\":\"%s\",\"msg\":\"%s\"}", (c++ ? "," : ""), esc(ts), esc(lv), esc(msg) }
          printf "],\"summary\":{\"all\":%d,\"warn\":%d,\"error\":%d}}", all + 0, nwarn + 0, nerr + 0 }') ;;
    access)
      rows=$(_logs_access_input "$day" | LC_ALL=C awk -f "$LIB/access.awk" -v mode=json -v q="$q" -v f="$f" -v lim="$limit" -v off="$off" -v since= -v mask=0) ;;
    *) printf '{"ok":false,"error":"日志类型无效"}'; return ;;
  esac
  printf '{"ok":true,"days":%s,%s}' "$(_logs_days_json)" "$(printf '%s' "$rows" | sed 's/^{//; s/}$//')"
}

logs_export() { # <类型> <日期>  -> 纯文本 (旧接口; 仪表盘现在用 logs_bundle)
  case $1 in
    ops) _logs_ops_localized "$2" ;;
    proxy) _logs_stream proxy "$2" | sed $'s/\033\\[[0-9;]*m//g' ;;
    access) _logs_access_input "$2" | LC_ALL=C awk -f "$LIB/access.awk" -v mode=tsv -v q= -v lim=0 -v off=0 -v since= -v mask=0 ;;
  esac
}

logs_usage_json() { # 各类日志占用的字节数
  local o=0 a=0 p=0 f sz
  for f in "$LOGS"/ops-*; do [ -f "$f" ] && { sz=$(stat -f %z "$f" 2>/dev/null || echo 0); o=$((o+sz)); }; done
  for f in "$LOGS"/proxy-* "$H/sing-box.log"; do [ -f "$f" ] && { sz=$(stat -f %z "$f" 2>/dev/null || echo 0); p=$((p+sz)); }; done
  a=$p   # 网站访问从代理日志里归并出来, 占用即代理日志的占用
  printf '{"ops":%s,"access":%s,"proxy":%s,"total":%s}' "$o" "$a" "$p" "$((o + p))"
}

logs_clear() { # <类型 ops|access|proxy|all> [before=YYYY-MM-DD] -> 打印释放的字节数
  local type=$1 before=${2:-} f d freed=0 sz
  case $type in ops|access|proxy|all) ;; *) return 1 ;; esac
  for f in "$LOGS"/*; do
    [ -f "$f" ] || continue
    case $type in ops) case $f in */ops-*) ;; *) continue ;; esac ;; access|proxy) case $f in */proxy-*) ;; *) continue ;; esac ;; esac
    d=$(printf '%s' "$f" | sed -nE 's/.*-([0-9]{4}-[0-9]{2}-[0-9]{2})\.log(\.gz)?$/\1/p')
    if [ -n "$before" ] && [ -n "$d" ] && ! [ "$d" \< "$before" ]; then continue; fi
    sz=$(stat -f %z "$f" 2>/dev/null || echo 0); freed=$((freed + sz)); rm -f "$f"
  done
  if [ "$type" != ops ] && [ -z "$before" ] && [ -s "$H/sing-box.log" ]; then sz=$(stat -f %z "$H/sing-box.log" 2>/dev/null || echo 0); freed=$((freed + sz)); : > "$H/sing-box.log"; fi
  echo "$freed"
}

settings_json() { # GET /api/settings 的 settings 与 usage
  printf '"settings":{"log_hours":%s,"log_hours_min":%s,"log_hours_max":%s,"log_ops":%s,"access_log":%s,"log_core":%s,"auto_sites":%s},"usage":%s' \
    "$(logs_hours)" "$LOG_HOURS_MIN" "$LOG_HOURS_MAX" "$([ "${LOG_OPS:-1}" = 1 ] && echo true || echo false)" "$([ "${ACCESS_LOG:-1}" = 1 ] && echo true || echo false)" "$([ "${LOG_CORE:-1}" = 1 ] && echo true || echo false)" "$([ "${AUTO_SITES:-0}" = 1 ] && echo true || echo false)" "$(logs_usage_json)"
}

# ======================================================================================================================
# 诊断导出
# ======================================================================================================================
BUNDLE_FORMAT=1

_b_mask_user() { sed -E 's#/Users/[^/ ,"]+#/Users/<user>#g; s#user: (root|_[A-Za-z0-9_]+)#user:@@K@@\1#g; s#user: [A-Za-z0-9._-]+#user: <user>#g; s#user:@@K@@#user: #g'; }

_b_mask_host() { # stdin 每行一个地址 -> 打码: 1.2.3.4 -> 1.2.*.*   a.b.example.com -> a***.example.com   IPv6 -> 前两段:*
  awk '{ h = $0
    if (h ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { split(h, p, "."); print p[1] "." p[2] ".*.*" }
    else if (index(h, ":") > 0) { n = split(h, p, ":"); print p[1] ":" p[2] ":*" }
    else if (h == "") print ""
    else { n = split(h, p, "."); if (n <= 2) print substr(h, 1, 1) "***"; else { s = substr(p[1], 1, 1) "***"; for (i = 2; i <= n; i++) s = s "." p[i]; print s } } }'
}

_b_sec() { # <名称> <格式 kv|tsv|raw|text> <函数> [参数…]  一个分区: 先生成到临时文件, 再写「@@SECTION 名称 format=… rows=N」和内容
  local name=$1 fmt=$2; shift 2
  "$@" > "$BT/$name" 2>/dev/null || true
  printf '@@SECTION %s format=%s rows=%s\n' "$name" "$fmt" "$(wc -l < "$BT/$name" | tr -d ' ')"
  cat "$BT/$name"
}

_b_meta() {
  local osv arch core tz clash_mode role_pin role_auto role_other
  osv=$(os_version 2>/dev/null); arch=$(os_arch); core=$(core_version 2>/dev/null); tz=$(date +%z)
  os_service_info
  clash_mode=$(clash GET /configs 2>/dev/null | sed -n 's/.*"mode":"\([A-Za-z]*\)".*/\1/p' | head -1)
  role_pin=$(srv_list | awk -F'\t' '$5=="pin"' | wc -l | tr -d ' '); role_auto=$(srv_list | awk -F'\t' '$5=="auto"' | wc -l | tr -d ' ')
  role_other=$(( $(srv_count) - role_pin - role_auto ))
  printf 'app=enana\nversion=%s\ncore=%s\nos=%s %s\narch=%s\nlang=%s\ntimezone=%s\nnow=%s\nepoch=%s\n' "$VERSION" "$core" "$(os_name)" "$osv" "$arch" "${LANG_UI:-zh}" "$tz" "$(date '+%F %T')" "$(now)"
  printf 'service.loaded=%s\nservice.running=%s\nservice.pid=%s\n' "${SVC_LOADED:-0}" "${SVC_RUNNING:-0}" "${SVC_PID:-}"
  printf 'capture.mode=%s\n' "${NETWORK_MODE:-system}"
  printf 'proxy.enabled=%s\nproxy.mode=%s\nclash.mode=%s\n' "${PROXY_ENABLED:-0}" "${PROXY_MODE:-auto}" "${clash_mode:-unknown}"
  printf 'settings.log_ops=%s\nsettings.access_log=%s\nsettings.log_core=%s\nsettings.log_hours=%s\nsettings.auto_sites=%s\nsettings.auto_update=%s\n' "${LOG_OPS:-1}" "${ACCESS_LOG:-1}" "${LOG_CORE:-1}" "$(logs_hours)" "${AUTO_SITES:-0}" "${AUTO_UPDATE:-1}"
  printf 'ports.proxy=%s\nports.clash=%s\nports.api=%s\nports.speed=%s\n' "$PORT" "$UI_PORT" "$API_PORT" "$SPEED_PORT"
  printf 'servers.total=%s\nservers.pin=%s\nservers.auto=%s\nservers.other=%s\n' "$(srv_count)" "$role_pin" "$role_auto" "$role_other"
  printf 'account.logged_in=%s\ncontent.seq=%s\ncontent.version=%s\nrules.updated=%s\n' "$(auth_logged_in && echo yes || echo no)" "$(cloud_seq)" "$(cloud_version)" "$(rules_updated_at)"
}

_b_env() {
  if [ "${ENANA_PLATFORM:-darwin}" = windows ]; then network_diagnostics | _b_mask_user; return; fi
  local p pid out
  network_diagnostics | _b_mask_user
  scutil --proxy 2>/dev/null | awk '/^[[:space:]]+(HTTP|HTTPS|SOCKS|ProxyAutoConfig|ProxyAutoDiscovery|Exclude|FTP|RTSP|Gopher)[A-Za-z]* :/ { k = $1; $1 = ""; $2 = ""; sub(/^  */, ""); print "sysproxy." k "=" $0 }'
  printf 'sysproxy.points_to_enana=%s\n' "$(os_sysproxy_ok && echo yes || echo no)"
  printf 'dns.system=%s\n' "$(scutil --dns 2>/dev/null | awk '/nameserver\[[0-9]+\]/ {print $3}' | sort -u | head -6 | paste -sd' ' -)"
  route -n get default 2>/dev/null | awk '/interface:/ {print "net.interface=" $2} /gateway:/ {print "net.gateway=" $2}'
  detect_others 2>/dev/null; printf 'other_proxy_software=%s\n' "${OTHER_PROXY:-}"
  for p in "$PORT" "$UI_PORT" "$API_PORT" "$SPEED_PORT"; do
    out=$(lsof -nP -iTCP:"$p" -sTCP:LISTEN -Fc 2>/dev/null | sed -n 's/^c//p' | sort -u | paste -sd, -)
    printf 'listen.%s=%s\n' "$p" "${out:-none}"
  done
  pid=${SVC_PID:-$(os_service_pid 2>/dev/null)}
  if [ -n "$pid" ]; then ps -o etime=,rss= -p "$pid" 2>/dev/null | awk -v p="$pid" '{ print "core.pid=" p; print "core.uptime=" $1; print "core.rss_kb=" $2 }'; fi
  printf 'disk.free_kb=%s\n' "$(df -k "$H" 2>/dev/null | awk 'NR==2 {print $4}')"
  printf 'logs.size_kb=%s\n' "$(du -sk "$LOGS" 2>/dev/null | awk '{print $1}')"
  if [ -x "$SB" ] && [ -s "$H/config.json" ]; then
    if out=$("$SB" check -c "$H/config.json" 2>&1); then printf 'config.check=ok\n'; else printf 'config.check=error: %s\n' "$(printf '%s' "$out" | head -1 | cut -c1-200)"; fi
  fi
  for p in api.log tick.log check.log; do
    [ -s "$H/$p" ] && tail -n 40 "$H/$p" 2>/dev/null | grep -iE 'error|fail|fatal|warn|denied' | tail -n 8 | _b_mask_user | sed "s/^/helperlog.$p: /"
  done
  return 0
}

_b_config() { # 脱敏后的运行配置: 日志 / 入站 / 路由规则 (按顺序, 先匹配先生效) / 规则集 / 出站 (服务器只留 类型 + 打码地址) / DNS
  [ -s "$H/config.json" ] || return 0
  perl -MJSON::PP -e '
    my $f = shift; open my $fh, "<", $f or exit 1; local $/; my $raw = <$fh>; my $j = eval { JSON::PP->new->utf8->decode($raw) } or exit 1;
    my $E = JSON::PP->new->utf8->canonical;
    sub mh { my ($h) = @_; return "" unless defined $h; return "$1.$2.*.*" if $h =~ /^(\d+)\.(\d+)\.\d+\.\d+$/; return "$1:$2:*" if $h =~ /^([0-9a-fA-F]+):([0-9a-fA-F]*):/;
             my @p = split /\./, $h; return substr($h, 0, 1) . "***" if @p <= 2; my $s = substr($p[0], 0, 1) . "***"; $s .= ".$p[$_]" for 1..$#p; return $s }
    print "log ", $E->encode($j->{log} || {}), "\n";
    my %ca = %{ $j->{experimental}{clash_api} || {} }; delete $ca{secret}; print "clash_api ", $E->encode(\%ca), "\n";
    for my $i (0 .. $#{ $j->{inbounds} || [] }) { my $b = $j->{inbounds}[$i]; print "inbound[$i] type=$b->{type} tag=$b->{tag} listen=", ($b->{listen} // ""), ":", ($b->{listen_port} // ""), "\n" }
    for my $b (@{ $j->{inbounds} || [] }) { if ($b->{type} eq "tun") { print "tun ", $E->encode($b), "\n"; } }
    my $r = $j->{route} || {};
    print "route auto_detect_interface=", ($r->{auto_detect_interface} ? 1 : 0), "\n";
    print "route final=", ($r->{final} // ""), " find_process=", ($r->{find_process} ? 1 : 0), " default_domain_resolver=", ($r->{default_domain_resolver} // ""), "\n";
    for my $i (0 .. $#{ $r->{rules} || [] }) { print "rule[$i] ", $E->encode($r->{rules}[$i]), "\n" }
    for my $s (@{ $r->{rule_set} || [] }) { (my $p = $s->{path} // $s->{url} // "") =~ s{.*/}{}; print "ruleset tag=$s->{tag} type=$s->{type} format=", ($s->{format} // ""), " file=$p\n" }
    for my $o (@{ $j->{outbounds} || [] }) {
      my $t = $o->{type} // "";
      if ($t =~ /^(selector|urltest|fallback)$/) { my @m = @{ $o->{outbounds} || [] }; my $n = @m; @m = @m[0 .. 19] if $n > 20;
        print "outbound tag=$o->{tag} type=$t default=", ($o->{default} // ""), " members=$n list=", join(",", @m), ($n > 20 ? ",…" : ""), "\n" }
      elsif ($t =~ /^(direct|block|dns)$/) { print "outbound tag=$o->{tag} type=$t\n" }
      else { my $tls = $o->{tls} || {}; my $tr = $o->{transport} || {};
        print "server tag=$o->{tag} type=$t host=", mh($o->{server}), " port=", ($o->{server_port} // ""), " tls=", ($tls->{enabled} ? 1 : 0), " sni=", mh($tls->{server_name}), " transport=", ($tr->{type} // ""), " network=", ($o->{network} // ""), "\n" }
    }
    if (my $d = $j->{dns}) { for my $s (@{ $d->{servers} || [] }) { my %c = %$s; print "dns.server ", $E->encode(\%c), "\n" } for my $i (0 .. $#{ $d->{rules} || [] }) { print "dns.rule[$i] ", $E->encode($d->{rules}[$i]), "\n" } print "dns.final=", ($d->{final} // ""), "\n" }
  ' "$H/config.json"
}

_b_policy() { # 当前生效的策略: 代理模式 / 每个选择器当前选了谁 / 你对应用和网站的覆盖 / 自动识别添加的网站 / 自定义项
  local f
  printf 'mode.setting=%s/%s\n' "${PROXY_ENABLED:-0}" "${PROXY_MODE:-auto}"
  clash GET /proxies 2>/dev/null | perl -MJSON::PP -e '
    local $/; my $j = eval { decode_json(<STDIN>) } or exit 0; my $p = $j->{proxies} || {};
    for my $n (sort keys %$p) { my $o = $p->{$n}; next unless ($o->{type} // "") =~ /^(Selector|URLTest|Fallback)$/i; my @a = @{ $o->{all} || [] };
      print "selector tag=$n type=$o->{type} now=", ($o->{now} // ""), " members=", scalar(@a), "\n" }'
  for f in overrides.tsv autosites.tsv site-domains.tsv custom-rulesets.tsv custom-apps.tsv hosts.tsv dns.conf; do
    [ -s "$H/$f" ] || continue
    printf '%s\n' "--- file $f (列用 | 分隔)"
    case $f in
      custom-apps.tsv) cut -d'|' -f1,2 "$H/$f" ;;
      overrides.tsv) awk -F'|' '$1 == "site" || $4 != "def"' "$H/$f" ;;          # 没动过的应用默认值 (def) 在 apps 分区里, 这里只列网站和你设置过 / 新发现的应用
      *) cat "$H/$f" ;;
    esac
  done
}

_b_servers() { # tag type host(打码) port role sub
  printf 'tag\ttype\thost\tport\trole\tsub\n'
  srv_list | while IFS=$'\t' read -r tag type host port role sub; do printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$tag" "$type" "$(printf '%s\n' "$host" | _b_mask_host)" "$port" "$role" "$sub"; done
}

_b_apps() { # 已识别的应用 + 当前设置
  [ -s "$H/.apps.now" ] || apps_installed > "$H/.apps.now"
  printf 'name\tstate\tflag\ttarget\tknown\trec\tgroup\tpath\n'
  apps_json | perl -MJSON::PP -e 'local $/; my $l = eval { decode_json(<STDIN>) } || []; for my $a (@$l) { my $p = $a->{path} // ""; $p =~ s{/Users/[^/]+}{/Users/<user>}; print join("\t", map { $_ // "" } @$a{qw(name state flag target)}, ($a->{known} ? "yes" : "no"), @$a{qw(rec group)}, $p), "\n" }'
}

_b_probe() { # <名称> <经过 proxy|direct> <地址> [curl 参数…]
  local n=$1 via=$2 url=$3 out rc; shift 3
  out=$(curl -s -o /dev/null -m 8 --connect-timeout 5 "$@" -w '%{http_code}\t%{time_connect}\t%{time_total}\t%{remote_ip}' "$url" 2>&1); rc=$?
  if [ "$rc" = 0 ]; then printf '%s\t%s\t%s\t%s\n' "$n" "$via" "$url" "$(printf '%s' "$out" | awk -F'\t' '{ printf "%s\t%d\t%d\t%s\tok", $1, $2*1000, $3*1000, $4 }')"
  else printf '%s\t%s\t%s\t000\t0\t0\t\tcurl-exit-%s\n' "$n" "$via" "$url" "$rc"; fi
}
_b_probes() { # --noproxy bypasses an explicit proxy, but never bypasses TUN.
  local d i n native=direct; [ "${NETWORK_MODE:-system}" != tun ] || native=tun
  d=$(mktemp -d); printf 'probe\tvia\turl\thttp\tconnect_ms\ttotal_ms\tremote_ip\tnote\n'
  if [ -n "${ENANA_SKIP_PROBE:-}" ]; then printf 'skipped\t-\t-\t000\t0\t0\t\tENANA_SKIP_PROBE\n'; rm -rf "$d"; return 0; fi        # 离线 / 测试: 不联网
  if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
    _b_probe google_204 proxy http://www.gstatic.com/generate_204 -x "http://127.0.0.1:$PORT" > "$d/1" &
    _b_probe google_page proxy https://www.google.com/ -x "http://127.0.0.1:$PORT" > "$d/2" &
    _b_probe github proxy https://github.com/ -x "http://127.0.0.1:$PORT" > "$d/3" &
    _b_probe baidu proxy https://www.baidu.com/ -x "http://127.0.0.1:$PORT" > "$d/4" &
  fi
  _b_probe google_204 "$native" http://www.gstatic.com/generate_204 --noproxy '*' > "$d/5" &
  _b_probe google_page "$native" https://www.google.com/ --noproxy '*' > "$d/6" &
  _b_probe baidu "$native" https://www.baidu.com/ --noproxy '*' > "$d/7" &
  wait
  for i in 1 2 3 4 5 6 7; do [ -f "$d/$i" ] && cat "$d/$i"; done
  local system_dns
  if [ "${ENANA_PLATFORM:-darwin}" = windows ]; then system_dns=$(win_bridge dns-system www.google.com 2>/dev/null)
  else system_dns=$(dscacheutil -q host -a name www.google.com 2>/dev/null | awk '/^(ip_address|ipv6_address):/ {print $2}' | head -4 | paste -sd' ' -); fi
  printf 'dns_system\tsystem\twww.google.com\t-\t-\t-\t%s\t\n' "$system_dns"
  n=$(clash GET "/dns/query?name=www.google.com&type=A" 2>/dev/null | perl -MJSON::PP -e 'local $/; my $j = eval { decode_json(<STDIN>) } or exit 0; print join(" ", map { $_->{data} // "" } @{ $j->{Answer} || [] })')
  printf 'dns_core\tcore\twww.google.com\t-\t-\t-\t%s\t%s\n' "$n" "$([ -n "$n" ] || echo no-answer)"
  rm -rf "$d"
}
_b_live() { # 此刻核心里还开着的连接 (最多 60 条, 按下载量): 含命中的规则 (rule) —— 能直接看出「为什么走了这个出口」
  printf 'start\tnet\thost\tport\tapp\tchain\trule\tup\tdown\n'
  clash GET /connections 2>/dev/null | perl -MJSON::PP -e '
    local $/; my $j = eval { decode_json(<STDIN>) } or exit 0; my @c = sort { ($b->{download} // 0) <=> ($a->{download} // 0) } @{ $j->{connections} || [] }; @c = @c[0 .. 59] if @c > 60;
    for my $c (@c) { my $m = $c->{metadata} || {}; my $pp = $m->{processPath} // ""; $pp =~ s{\\}{/}g; my $app = $pp =~ m{([^/]+)\.app/} ? $1 : ($pp =~ m{([^/]+)$} ? $1 : "");
      my $r = join(" ", grep { length } ($c->{rule} // "", $c->{rulePayload} // ""));
      print join("\t", ($c->{start} // ""), ($m->{network} // ""), ($m->{host} || $m->{destinationIP} || ""), ($m->{destinationPort} // ""), $app, join(">", reverse @{ $c->{chains} || [] }), $r, ($c->{upload} // 0), ($c->{download} // 0)), "\n" }'
}

_b_days() { # <小时数|all> -> 要读取的日期 (旧→新)
  local h=$1 first
  if [ "$h" = all ]; then logs_days | sort; return; fi
  first=$(os_date_minus_hours "$h"); first=${first%% *}
  logs_days | sort | awk -v f="$first" '$0 >= f'
}
_b_ops() { # <起始时间|空> <日期…>
  local since=$1 d; shift
  printf 'ts\twho\taction\tdetail\tresult\n'
  for d in "$@"; do _logs_stream ops "$d"; done | LC_ALL=C awk -v s="$since" 'BEGIN { FS = "\t" } { if (s == "" || substr($0, 1, 19) >= s) print }' | _b_mask_user
}
_b_access() { # <起始时间|空> <日期…>
  local since=$1; shift
  _logs_access_input "$@" | LC_ALL=C awk -f "$LIB/access.awk" -v mode=tsv -v q= -v lim=0 -v off=0 -v since="$since" -v mask=1
}
_b_proxy() { # <起始时间|空> <日期…>
  local since=$1 d; shift
  for d in "$@"; do _logs_stream proxy "$d"; done | sed $'s/\033\\[[0-9;]*m//g' | LC_ALL=C awk -v s="$since" '{ ch = substr($0, 1, 1); if ((ch == "+" || ch == "-") && $2 ~ /^[0-9][0-9][0-9][0-9]-/) keep = (s == "" || ($2 " " $3) >= s); if (keep) print }' | _b_mask_user
}

# logs_bundle <小时数|all> <分区 逗号分隔: ops access proxy snapshot>  -> 打印诊断导出文件 (UTF-8 文本)
logs_bundle() {
  local hours=${1:-24} secs=${2:-ops,access,proxy,snapshot} since='' days dlist BT declared=meta
  case $hours in all) ;; ''|*[!0-9]*) hours=24 ;; esac
  [ "$hours" = all ] || { [ "$hours" -lt 1 ] && hours=1; [ "$hours" -gt $LOG_HOURS_MAX ] && hours=$LOG_HOURS_MAX; since=$(os_date_minus_hours "$hours"); }
  days=$(_b_days "$hours"); dlist=$(printf '%s' "$days" | paste -sd, -)
  BT=$(mktemp -d)
  printf '#ENANA-DIAGNOSTICS format=%s\n' "$BUNDLE_FORMAT"
  printf '#generated=%s tz=%s app=enana version=%s\n' "$(date '+%F %T')" "$(date +%z)" "$VERSION"
  printf '#range since="%s" hours=%s days=%s\n' "${since:-beginning}" "$hours" "${dlist:-none}"
  # macOS bash 3.2 misparses unparenthesized case patterns inside quoted $().
  case ",$secs," in *,snapshot,*) declared="$declared,env,config,policy,servers,apps,probes,live" ;; esac
  case ",$secs," in *,ops,*) declared="$declared,ops" ;; esac
  case ",$secs," in *,access,*) declared="$declared,access" ;; esac
  case ",$secs," in *,proxy,*) declared="$declared,proxy" ;; esac
  printf '#sections=%s\n' "$declared"
  printf '%s\n' '#about=这是 enana 的诊断导出文件, 用来排查「网站打不开 / 走错出口 / 应用没识别」之类的问题。每个 "@@SECTION 名称 format=… rows=N" 开始一个分区, 到下一个 "@@SECTION" 或 "@@END" 结束; 以 "#" 开头的行是说明; format=kv 是 键=值, tsv 的第一行是列名 (制表符分隔), raw 是原始日志行。'
  printf '%s\n' '#privacy=不含任何密码 / 令牌 / 服务器凭据; 服务器地址和系统用户名已打码; 但包含访问过的域名和应用名, 请只发给你信任的人。'
  printf '%s\n' '#route-reasons=出口名 direct-mode(代理总开关关闭) direct-lan(本机/局域网) direct-site(你把该网站设为直连) direct-app(你把该应用设为直连/关) direct-cn(国内规则) direct(策略选了直连) 都是直连; 其它名字是代理服务器节点。'
  _b_sec meta kv _b_meta
  case ",$secs," in *,snapshot,*)
    _b_sec env kv _b_env
    _b_sec config text _b_config
    _b_sec policy text _b_policy
    _b_sec servers tsv _b_servers
    _b_sec apps tsv _b_apps
    _b_sec probes tsv _b_probes
    _b_sec live tsv _b_live ;; esac
  # shellcheck disable=SC2086
  case ",$secs," in *,ops,*) _b_sec ops tsv _b_ops "$since" $days ;; esac
  case ",$secs," in *,access,*) _b_sec access tsv _b_access "$since" $days ;; esac
  case ",$secs," in *,proxy,*) _b_sec proxy raw _b_proxy "$since" $days ;; esac
  printf '@@END\n'
  rm -rf "$BT"
}
