# 2.3.26 的日志查询, 逐字复制自 2.3.26 (064bc1f) 的 lib/logs.sh 第 152-234 行 —— 不要修改, 它是对比的基准。
# tests/logs-query.sh 在子 shell 里 source 它 (覆盖同名的新函数), 并把 LIB 指向本目录: 这里的 access.awk 是 2.3.26 的 lib/access.awk 原样副本。

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
  printf '%s\n' "@@AUTOS"; { srv_list; type official_list >/dev/null 2>&1 && official_list; } | awk -F'\t' '$5=="auto"{print $1}'
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
