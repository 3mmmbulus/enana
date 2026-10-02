# 日志: 操作记录 + 网站访问 + 代理日志。默认保留 30 天, 可在设置里改成 1–365 天; 超期每天自动清理。依赖 common.sh os-darwin.sh。
#
#   $H/logs/ops-YYYY-MM-DD.log       操作记录 (制表符分隔: 时间 来源 动作 详情 结果)   —— 由辅助服务/终端命令写入, 不含任何密码或令牌
#   $H/sing-box.log                  代理核心的实时日志 (info 级别包含每条连接的目标、应用与出站)
#   $H/logs/proxy-YYYY-MM-DD.log[.gz]  每天凌晨由 `enana maintain` 把实时日志按日期切开 (copytruncate), 2 天前的会被压缩
#   「网站访问」不单独存文件: 从代理日志里按连接编号归并出 时间/域名/端口/应用/出站, 隐私上等同于代理日志, 一起保留一起清理。
# 关闭「记录网站访问」后核心只记录警告和错误 (已有的访问记录仍按保留天数清理)。

LOGS="$H/logs"
LOG_DAYS_MAX=365

oplog() { # oplog <来源 dashboard|terminal> <动作> <详情> <结果 ok|error>
  local f ts; mkdir -p "$LOGS"
  ts=$(date '+%F %T'); f="$LOGS/ops-${ts%% *}.log"
  printf '%s\t%s\t%s\t%s\t%s\n' "$ts" "$1" "$(printf '%s' "$2" | tr '\t\r\n' '   ' | cut -c1-60)" "$(printf '%s' "$3" | tr '\t\r\n' '   ' | cut -c1-200)" "${4:-ok}" >> "$f"
}

logs_days_clamp() { local d=$1; case $d in ''|*[!0-9]*) d=30 ;; esac; [ "$d" -lt 1 ] && d=1; [ "$d" -gt $LOG_DAYS_MAX ] && d=$LOG_DAYS_MAX; echo "$d"; }

# 把核心实时日志按行首日期切到 logs/proxy-<日期>.log, 然后原地清空 (核心以追加方式打开文件, 不会丢失后续日志)
logs_rotate() {
  local live="$H/sing-box.log" tmp
  [ -s "$live" ] || return 0
  mkdir -p "$LOGS"; tmp=$(mktemp)
  cp "$live" "$tmp" && : > "$live"
  awk -v dir="$LOGS" '{
      d = ""; c = substr($1, 1, 1)
      if ((c == "+" || c == "-") && $2 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) d = $2
      if (d == "") d = (last == "" ? "unknown" : last)
      last = d; print >> (dir "/proxy-" d ".log")
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

# 删除早于保留期的日志; 返回释放的字节数
logs_purge() {
  local days cutoff f d freed=0 sz; days=$(logs_days_clamp "${LOG_DAYS:-30}"); cutoff=$(os_date_minus_days "$days")
  for f in "$LOGS"/*; do
    [ -f "$f" ] || continue
    d=$(printf '%s' "$f" | sed -nE 's/.*-([0-9]{4}-[0-9]{2}-[0-9]{2})\.log(\.gz)?$/\1/p'); [ -n "$d" ] || continue
    if [ "$d" \< "$cutoff" ]; then sz=$(stat -f %z "$f" 2>/dev/null || echo 0); freed=$((freed + sz)); rm -f "$f"; fi
  done
  echo "$freed"
}

logs_maintain() { logs_rotate; logs_compress; logs_purge >/dev/null; }

# ---------- 查询 (仪表盘「日志」页) ----------
_logs_stream() { # <类型 proxy|access|ops> <日期>  -> 该天的原始行 (按时间顺序)
  local d=$2 f
  case $1 in
    ops)
      [ -f "$LOGS/ops-$d.log" ] && cat "$LOGS/ops-$d.log"
      [ -f "$LOGS/ops-$d.log.gz" ] && gzip -dc "$LOGS/ops-$d.log.gz" ;;
    *)
      [ -f "$LOGS/proxy-$d.log" ] && cat "$LOGS/proxy-$d.log"
      [ -f "$LOGS/proxy-$d.log.gz" ] && gzip -dc "$LOGS/proxy-$d.log.gz"
      f="$H/sing-box.log"
      [ -s "$f" ] && awk -v d="$d" '{ c = substr($1, 1, 1); if (c == "+" || c == "-") keep = ($2 == d); if (keep) print }' "$f" ;;
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

# logs_query <类型> <日期> <q> <limit> <offset>  -> {"ok":true,"total":N,"days":[…],"rows":[…]}
logs_query() {
  local type=$1 day=$2 q=$3 limit=$4 off=$5 pins autos rows
  case $limit in ''|*[!0-9]*) limit=500 ;; esac; [ "$limit" -gt 2000 ] && limit=2000
  case $off in ''|*[!0-9]*) off=0 ;; esac
  [ -n "$day" ] || day=$(date +%F)
  q=$(printf '%s' "$q" | tr '[:upper:]' '[:lower:]')
  case $type in
    ops)
      rows=$(_logs_ops_localized "$day" | awk -F'\t' -v q="$q" -v lim="$limit" -v off="$off" "$_AWK_ESC"'
        { line = tolower($0); if (q != "" && index(line, q) == 0) next; n++; a[n] = $0 }
        END { printf "{\"total\":%d,\"rows\":[", n; c = 0
          for (i = n - off; i >= 1 && c < lim; i--) { split(a[i], f, "\t"); printf "%s{\"ts\":\"%s\",\"who\":\"%s\",\"action\":\"%s\",\"detail\":\"%s\",\"result\":\"%s\"}", (c++ ? "," : ""), esc(f[1]), esc(f[2]), esc(f[3]), esc(f[4]), esc(f[5]) }
          printf "]}" }') ;;
    proxy)
      rows=$(_logs_stream proxy "$day" | awk -v q="$q" -v lim="$limit" -v off="$off" "$_AWK_ESC"'
        { line = tolower($0); if (q != "" && index(line, q) == 0) next; n++; a[n] = $0 }
        END { printf "{\"total\":%d,\"rows\":[", n; c = 0
          for (i = n - off; i >= 1 && c < lim; i--) { l = a[i]; ts = ""; lv = ""; msg = l
            if (match(l, /^[+-][0-9][0-9][0-9][0-9] [0-9-]+ [0-9:]+ [A-Z]+ /)) { split(substr(l, RSTART, RLENGTH), p, " "); ts = p[2] " " p[3]; lv = p[4]; msg = substr(l, RLENGTH + 1) }
            printf "%s{\"ts\":\"%s\",\"level\":\"%s\",\"msg\":\"%s\"}", (c++ ? "," : ""), esc(ts), esc(lv), esc(msg) }
          printf "]}" }') ;;
    access)
      pins=$(srv_list | awk -F'\t' '$5=="pin"{print $1}'); autos=$(srv_list | awk -F'\t' '$5=="auto"{print $1}')
      rows=$( { printf '%s\n' "@@PINS"; printf '%s\n' "$pins"; printf '%s\n' "@@AUTOS"; printf '%s\n' "$autos"; printf '%s\n' "@@LOG"; _logs_stream access "$day"; } | awk -v q="$q" -v lim="$limit" -v off="$off" "$_AWK_ESC"'
        /^@@PINS$/ { mode = 1; next } /^@@AUTOS$/ { mode = 2; next } /^@@LOG$/ { mode = 3; next }
        mode == 1 { if ($0 != "") pin[$0] = 1; next }
        mode == 2 { if ($0 != "") auto[$0] = 1; next }
        mode == 3 {
          if (!match($0, /\[[0-9]+ /)) next
          id = substr($0, RSTART + 1, RLENGTH - 2)
          if (index($0, "inbound connection to ") > 0) {
            hp = substr($0, index($0, "inbound connection to ") + 22); p = hp; sub(/.*:/, "", p); h = hp; sub(/:[^:]*$/, "", h)
            host[id] = h; port[id] = p; ts[id] = $2 " " $3
          } else if (index($0, "found process path: ") > 0) {
            pp = substr($0, index($0, "found process path: ") + 20); sub(/, user: .*/, "", pp)
            if (match(pp, /[^\/]+\.app/)) app[id] = substr(pp, RSTART, RLENGTH - 4); else { app[id] = pp; sub(/.*\//, "", app[id]) }
          } else if (index($0, "outbound connection to ") > 0 && match($0, /outbound\/[a-z0-9]+\[/)) {
            t = substr($0, RSTART + RLENGTH); e = index(t, "]: outbound connection"); tag = (e > 0) ? substr(t, 1, e - 1) : t
            cls = (tag == "direct") ? "direct" : ((tag in pin) ? "pin" : ((tag in auto) ? "auto" : "other"))
            if (id in host) {
              line = tolower(host[id] " " app[id] " " tag); if (q != "" && index(line, q) == 0) next
              n++; R[n] = "{\"ts\":\"" esc(ts[id]) "\",\"host\":\"" esc(host[id]) "\",\"port\":" (port[id] + 0) ",\"app\":\"" esc(app[id]) "\",\"route\":\"" cls "\",\"node\":\"" esc(tag) "\"}"
            }
            delete host[id]; delete port[id]; delete ts[id]; delete app[id]
          }
        }
        END { printf "{\"total\":%d,\"rows\":[", n; c = 0; for (i = n - off; i >= 1 && c < lim; i--) printf "%s%s", (c++ ? "," : ""), R[i]; printf "]}" }') ;;
    *) printf '{"ok":false,"error":"日志类型无效"}'; return ;;
  esac
  printf '{"ok":true,"total":%s,"days":%s,"rows":%s}' "$(printf '%s' "$rows" | sed -n 's/^{"total":\([0-9]*\),.*/\1/p')" "$(_logs_days_json)" "$(printf '%s' "$rows" | sed 's/^{"total":[0-9]*,"rows"://; s/}$//')"
}

logs_export() { # <类型> <日期>  -> 纯文本
  case $1 in
    ops) _logs_ops_localized "$2" ;;
    proxy) _logs_stream proxy "$2" ;;
    access) logs_query access "$2" "" 2000 0 | sed 's/},{/}\n{/g' ;;
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
  printf '"settings":{"log_days":%s,"log_days_max":%s,"access_log":%s},"usage":%s' \
    "$(logs_days_clamp "${LOG_DAYS:-30}")" "$LOG_DAYS_MAX" "$([ "${ACCESS_LOG:-1}" = 1 ] && echo true || echo false)" "$(logs_usage_json)"
}
