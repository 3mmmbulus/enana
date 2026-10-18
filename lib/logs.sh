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
sysproxy_record() { # <来源> <on|off> <返回码>  把「开启 / 关闭系统代理」的结果写进操作记录: 用了哪种授权方式 (method) 和失败原因 (err) —— 以前系统代理没开成功时不留任何痕迹
  oplog "$1" "$([ "$2" = on ] && echo 开启系统代理 || echo 关闭系统代理)" "$(kv method "${SYSPROXY_METHOD:-}" helper "${SYSPROXY_HELPER:-}" err "${SYSPROXY_ERR:-}" port "${PORT:-}" mode "${NETWORK_MODE:-system}")" "$([ "$3" = 0 ] && echo ok || echo error)"
}

# 调用链 (最近的在前, 用 < 连接, 最多 <最多层数> 层): 「核心为什么重启了 / 总开关为什么变了」这类事后很难追查的动作, 在动手前记下是谁触发的。
call_chain() { # [跳过层数, 默认 1 = 不含 call_chain 自己] [最多层数, 默认 5]
  local skip=${1:-1} max=${2:-5} i out='' n=0
  [ -n "${FUNCNAME[*]+x}" ] || return 0
  for ((i = skip; i < ${#FUNCNAME[@]}; i++)); do
    case ${FUNCNAME[$i]} in main|source) continue ;; esac
    out="$out${out:+<}${FUNCNAME[$i]}"; n=$((n + 1)); [ "$n" -ge "$max" ] && break
  done
  printf '%s' "$out"
}
core_restart_note() { # 核心重启前记一笔: 谁触发的 (调用链) · 当前核心 pid · 代理总开关
  oplog "${OP_WHO:-auto}" "重启核心" "$(kv via "$(call_chain 2 6)" pid "$(os_service_pid 2>/dev/null || true)" proxy "${PROXY_ENABLED:-0}")" ok
}
switch_note() { # <设置名> <旧值> <新值>  代理总开关 / 模式的每一次变化都记下是谁改的; 「为什么自己关了」可以直接从操作记录读出来
  oplog "${OP_WHO:-auto}" "总开关变更" "$(kv key "$1" from "$2" to "$3" via "$(call_chain 2 6)" pid "$$")" ok
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
  for f in "$LOGS"/proxy-*.log "$LOGS"/ops-*.log "$LOGS"/health-*.log; do
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
      case $f in */proxy-unknown.log*) if [ -n "$(find "$f" -maxdepth 0 -mmin +$((hours * 60)) 2>/dev/null)" ]; then sz=$(file_size "$f" 2>/dev/null || echo 0); freed=$((freed + sz)); rm -f "$f"; fi ;; esac
      continue
    fi
    sz=$(file_size "$f" 2>/dev/null || echo 0)
    if [ "$d" \< "$cday" ]; then freed=$((freed + sz)); rm -f "$f"
    elif [ "$d" = "$cday" ]; then
      case $f in */ops-*|*/health-*) kind=ops ;; *) kind=proxy ;; esac      # 健康记录和操作记录一样每行以时间戳开头
      tmp=$(mktemp)
      case $f in *.gz) gzip -dc "$f" 2>/dev/null ;; *) cat "$f" ;; esac | _logs_trim "$kind" "$cutoff" > "$tmp"
      if [ -s "$tmp" ]; then
        case $f in *.gz) gzip -9 -c "$tmp" > "$f.new" ;; *) cp "$tmp" "$f.new" ;; esac
        mv "$f.new" "$f"; sz2=$(file_size "$f" 2>/dev/null || echo 0); freed=$((freed + sz - sz2))
      else freed=$((freed + sz)); rm -f "$f"; fi
      rm -f "$tmp"
    fi
  done
  for f in "$H"/api.log.[0-9]; do                  # api.log 的历史代 (见下面 logs_rotate_api) 也按保留期删
    [ -f "$f" ] || continue
    if [ -n "$(find "$f" -maxdepth 0 -mmin +$((hours * 60)) 2>/dev/null)" ]; then sz=$(file_size "$f" 2>/dev/null || echo 0); freed=$((freed + sz)); rm -f "$f"; fi
  done
  echo "$freed"
}

# api.log (辅助服务的标准错误 + 后台任务的输出) 超过 5 MB 就切开: 保留三代 api.log.1 .. api.log.3。和 logs_rotate 一样先复制再清空 (服务以追加方式写它, 不能换文件名)
API_LOG_MAX=5242880
logs_rotate_api() {
  local f="$H/api.log" sz
  [ -f "$f" ] || return 0
  sz=$(file_size "$f" 2>/dev/null || echo 0)
  [ "${sz:-0}" -gt "$API_LOG_MAX" ] || return 0
  rm -f "$f.3"
  if [ -f "$f.2" ]; then mv -f "$f.2" "$f.3"; fi
  if [ -f "$f.1" ]; then mv -f "$f.1" "$f.2"; fi
  if cp "$f" "$f.1"; then : > "$f"; fi
  return 0
}

# tick.log (每分钟任务的输出: macOS 由 launchd 追加写, Windows 由辅助服务追加写) 没有别的清理: 超过 1 MB 就只留最后 2000 行。
#   原地写回 (先取尾部再覆盖同一个文件), 不换文件名: 正在运行的那一次 tick 的输出也还写在同一个文件里
TICK_LOG_MAX=1048576
logs_trim_tick() {
  local f="$H/tick.log" sz tmp
  [ -f "$f" ] || return 0
  sz=$(file_size "$f" 2>/dev/null || echo 0)
  [ "${sz:-0}" -gt "$TICK_LOG_MAX" ] || return 0
  tmp=$(mktemp) || return 0
  if tail -n 2000 "$f" > "$tmp"; then cat "$tmp" > "$f"; fi
  rm -f "$tmp"
  return 0
}

logs_maintain() { logs_rotate; logs_rotate_api; logs_trim_tick; logs_compress; logs_purge >/dev/null; }

logs_tick() { # 由 enana tick 每分钟调用一次; 每小时真正做一次 (切分 + 压缩 + 按保留期清理), 所以 12 小时的保留期也准
  local last=0 f="$H/.logs.last"
  [ -f "$f" ] && IFS= read -r last < "$f"
  [ $(( $(now) - ${last:-0} )) -ge 3600 ] || return 0
  now > "$f"; logs_maintain
}

# ---------- 查询 (仪表盘「日志」页) ----------
# 一天的代理日志可以有 100 MB / 七十多万行, 所以查询不再把整天读进一个 awk (以前一次 3 – 8 秒, 「实时」每 5 秒重复一次):
#   代理日志: 条数 (全部 / 警告 / 错误) 用 grep 数, 这一页用 tail 取, 只有这一页交给 awk 排版 —— 结果和 2.3.26 逐行读取的逐字节相同
#             (tests/logs-query.sh 拿 tests/fixtures/logs-2.3.26 里的旧实现对比)。搜索词仍是不分大小写的固定字符串, 和 awk 看到的完全一样 (见 _lq_qe)。
#   网站访问: 连接要按编号归并 (lib/access.awk), 只读这一天最后的一段 (先 4 MB; 不够这一页就放大再读, 至少 ×4), 读到整天时结果和以前完全相同;
#             没读完整天时返回 "partial":true, total = 已经读到的条数, 汇总也只算读到的部分 (仪表盘显示「最近的 N 条」和「加载更早的记录」)。
#             搜索时先用 grep 找出含搜索词的连接编号, 只把这些连接的行交给 access.awk (结果相同)。
#   日期列表: 实时日志只看第一条和最后一条带时间的行 (它按时间顺序写, 每小时切一次; 中间的日子由已经切分的文件给出), 不再整份扫描。
# 这些查询只由辅助服务调用 (lib/api.sh 设了 LC_ALL=C): grep / awk 都按字节比较, 大小写只认 ASCII, 和以前的 awk 一致。
# 诊断导出 (logs_bundle) 和旧的单类导出 (logs_export) 仍按原来的方式整天读取 (_logs_stream), 不受影响。
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

# 实时日志里的一行「带时间」= 第一个字段以 + / - 开头 (时区), 第二个字段以 4 位数字和 - 开头 (日期); 和 _logs_stream / 以前的 logs_days 用 awk 判断的是同一件事
_LQ_DAYRE='^[[:blank:]]*[+-][^[:blank:]]*[[:blank:]]+[0-9]{4}-'
_lq_dnum() { # YYYY-MM-DD -> 按天递增的一个数 (公历; 只用来判断两个日期是不是相邻); 不是这种格式 -> 返回 1
  local y m d
  case $1 in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) return 1 ;; esac
  y=$((10#${1%%-*})); m=${1#*-}; d=$((10#${m#*-})); m=$((10#${m%%-*}))
  [ "$m" -le 2 ] && { y=$((y - 1)); m=$((m + 12)); }
  printf '%s' "$(( 365 * y + y / 4 - y / 100 + y / 400 + (153 * (m - 3) + 2) / 5 + d ))"
}
_lq_adjacent() { local x y; x=$(_lq_dnum "$1") && y=$(_lq_dnum "$2") || return 1; [ $((x - y)) -le 1 ] && [ $((y - x)) -le 1 ]; }
_logs_live_days() { # 实时日志里有记录的日期: 只读第一条和最后一条带时间的行 (最后一条从文件末尾往前找, 找不到再往前多读一些), 不整份扫描
  local f="$H/sing-box.log" a b k=256
  [ -s "$f" ] || return 0
  a=$(LC_ALL=C grep -a -m 1 -E "$_LQ_DAYRE" "$f" 2>/dev/null | awk '{ print $2 }')
  [ -n "$a" ] || return 0
  while :; do
    if [ "$k" -gt 4194304 ]; then b=$(LC_ALL=C grep -a -E "$_LQ_DAYRE" "$f" 2>/dev/null | tail -n 1 | awk '{ print $2 }'); break; fi
    b=$(tail -n "$k" "$f" 2>/dev/null | LC_ALL=C grep -a -E "$_LQ_DAYRE" | tail -n 1 | awk '{ print $2 }')
    [ -n "$b" ] && break
    k=$((k * 16))
  done
  if [ -n "$b" ] && [ "$b" != "$a" ] && ! _lq_adjacent "$a" "$b"; then          # 首尾隔了不止一天 (每小时的切分没有在运行): 和以前一样整份扫描, 中间的日子不漏
    awk '{ c = substr($1,1,1); if ((c == "+" || c == "-") && $2 ~ /^[0-9][0-9][0-9][0-9]-/) print $2 }' "$f"
    return 0
  fi
  printf '%s\n' "$a"
  [ -z "$b" ] || [ "$b" = "$a" ] || printf '%s\n' "$b"
}

logs_days() { # 打印有记录的日期 (新→旧), 每行一个
  { ls -1 "$LOGS" 2>/dev/null | sed -nE 's/^(ops|proxy)-([0-9]{4}-[0-9]{2}-[0-9]{2})\.log(\.gz)?$/\2/p'
    _logs_live_days
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

_logs_access_head() { # access.awk 输入的开头: 固定出口 / 自动线路节点名 (@@PINS / @@AUTOS 两段), 最后一行 @@LOG (后面接核心日志)
  printf '%s\n' "@@PINS"; srv_list | awk -F'\t' '$5=="pin"{print $1}'
  printf '%s\n' "@@AUTOS"; { srv_list; type official_list >/dev/null 2>&1 && official_list; } | awk -F'\t' '$5=="auto"{print $1}'
  printf '%s\n' "@@LOG"
}
_logs_access_input() { # <日期…>  -> access.awk 的标准输入: 固定出口 / 自动线路节点名 + 这些天的核心日志
  local d
  _logs_access_head
  for d in "$@"; do _logs_stream access "$d"; done
}

# ---- 查询用的「这一天的日志流」: 和 _logs_stream proxy 逐字节相同, 但分成几段文件, 这样可以只读最后一段、用 grep / tail 直接读文件 ----
#   LQ_P = 各段的文件 (按顺序: 已切分的文件 · 压缩文件解压到 $LQT/gz · 实时日志里这一天的行写到 $LQT/live; 空的不要), LQ_S = 各段的字节数
_LQ_NL=$'\n'
_LQ_ESC=$(printf '\033')
_logs_live_day() { # <日期>  实时日志里属于这一天的行, 和 _logs_stream 的 awk 读法结果相同 (行首字段以 + / - 开头的行决定它和后面的行属于哪一天; 核心日志关闭时只留连接行)
  local d=$1 f="$H/sing-box.log" hit all n0      #   平时实时日志里「行首是 + / -」的行全是同一天的: 那就是从第一条这样的行到文件末尾, 用 grep 数一数 + tail, 不必逐行跑 awk
  [ -s "$f" ] || return 0
  hit=$(LC_ALL=C grep -a -c -E "^[[:blank:]]*[+-][^[:blank:]]*[[:blank:]]+$d([[:blank:]]|\$)" "$f" 2>/dev/null)
  case $hit in ''|0|*[!0-9]*) return 0 ;; esac                                      # 没有一行是这一天的
  all=$(LC_ALL=C grep -a -c -E '^[[:blank:]]*[+-]' "$f" 2>/dev/null); n0=''
  [ "$all" = "$hit" ] && n0=$(LC_ALL=C grep -a -n -m 1 -E '^[[:blank:]]*[+-]' "$f" 2>/dev/null | cut -d: -f1)
  if [ -n "$n0" ]; then
    if [ "${LOG_CORE:-1}" = 1 ]; then tail -n +"$n0" "$f"; else tail -n +"$n0" "$f" | LC_ALL=C grep -a -E '[[][0-9]+ [^]]*[]] '; fi
  else                                                                               # 跨了日期 (半夜到下一次切分之间) 或有别的日期的行: 和 _logs_stream 一样逐行判断
    awk -v d="$d" -v core="${LOG_CORE:-1}" '{ c = substr($1, 1, 1); if (c == "+" || c == "-") keep = ($2 == d); if (keep && (core == 1 || $0 ~ /\[[0-9]+ [^]]*\] /)) print }' "$f"
  fi
  return 0
}
_lq_open() { [ -s "$1" ] && [ "$(tail -c 1 "$1" | wc -l | tr -d ' ')" = 0 ]; }        # 最后一个字节不是换行 (最后一行没有写完)
_lq_endnl() { if _lq_open "$1"; then printf '\n' >> "$1"; fi; return 0; }           # awk 输出的每一行都以换行结尾: tail 直接取的那段补上
_lq_lines() { local n; n=$(wc -l < "$1" | tr -d ' '); _lq_open "$1" && n=$((n + 1)); printf '%s' "${n:-0}"; }    # 行数 (和 awk 的记录数一样: 最后一行没有换行也算)
_lq_prep() { # <日期>  准备 LQ_P / LQ_S
  local d=$1 i n
  LQ_P=(); LQ_S=()
  [ -s "$LOGS/proxy-$d.log" ] && LQ_P[${#LQ_P[@]}]="$LOGS/proxy-$d.log"
  if [ -f "$LOGS/proxy-$d.log.gz" ]; then gzip -dc "$LOGS/proxy-$d.log.gz" > "$LQT/gz" 2>/dev/null; [ -s "$LQT/gz" ] && LQ_P[${#LQ_P[@]}]="$LQT/gz"; fi
  _logs_live_day "$d" > "$LQT/live"; _lq_endnl "$LQT/live"; [ -s "$LQT/live" ] && LQ_P[${#LQ_P[@]}]="$LQT/live"
  n=${#LQ_P[@]}; i=0
  while [ "$i" -lt $((n - 1)) ]; do              # 前面的某段不是以换行结尾 (正常不会): 它的最后半行和下一段的第一行连成一行, 合并成一个文件才和整条流读出来的一样
    if _lq_open "${LQ_P[$i]}"; then cat "${LQ_P[@]}" > "$LQT/all"; LQ_P=("$LQT/all"); break; fi
    i=$((i + 1))
  done
  n=${#LQ_P[@]}; i=0
  while [ "$i" -lt "$n" ]; do LQ_S[$i]=$(file_size "${LQ_P[$i]}" 2>/dev/null || echo 0); i=$((i + 1)); done
  return 0
}
_lq_window() { # <字节数>  这一天日志流的最后 N 字节, 从某一行的行首开始 (切到一半的那一行不要); N 不小于全部时就是整条流
  local want=$1 i n=${#LQ_P[@]} k=-1 off=0
  [ "$n" -gt 0 ] || return 0
  i=$((n - 1))
  while [ "$i" -ge 0 ]; do
    if [ "$want" -lt "${LQ_S[$i]}" ]; then k=$i; off=$((LQ_S[i] - want)); break; fi
    want=$((want - LQ_S[i])); i=$((i - 1))
  done
  if [ "$k" -lt 0 ]; then cat "${LQ_P[@]}"; return 0; fi
  tail -c +"$off" "${LQ_P[$k]}" | tail -n +2           # 从窗口前的那个字节读起, 去掉到第一个换行为止
  i=$((k + 1)); while [ "$i" -lt "$n" ]; do cat "${LQ_P[$i]}"; i=$((i + 1)); done
  return 0
}
_lq_norm() { local v=${1#"${1%%[!0]*}"}; [ -n "$v" ] || v=0; [ ${#v} -gt 9 ] && v=big; printf '%s' "$v"; }      # 条数 / 跳过数: 去掉前导 0; 十亿以上记成 big (比任何一天的行数都多)
# 搜索词: logs_query 用 tr 转成小写后以 -v q= 交给 awk, -v 还会处理反斜杠转义; 用同一个 awk 读一遍, 得到 awk 真正比较的那个词 (LQ_QE)。
#   LQ_NEVER=1: 它不可能出现在转成小写的一行里 (含换行 / 大写字母 / NUL), 以前的结果就是一条也没有
_lq_qe() { # <q>
  local r len
  LQ_QE=''; LQ_NEVER=0
  [ -n "$1" ] || return 0
  r=$(LC_ALL=C awk -v q="$1" 'BEGIN { printf "%d:%s.", length(q), q }' 2>/dev/null)     # 末尾的点保住结尾的换行; 长度对不上 = 含 NUL (被 shell 丢掉了)
  len=${r%%:*}; r=${r#*:}; LQ_QE=${r%.}
  [ "${#LQ_QE}" = "$len" ] || LQ_NEVER=1
  case $LQ_QE in *"$_LQ_NL"*|*[ABCDEFGHIJKLMNOPQRSTUVWXYZ]*) LQ_NEVER=1 ;; esac
  return 0
}

# ---- 代理日志: 以前的 awk 对每一行做的事 —— 去颜色 · 按搜索词 (小写) 过滤 · 认级别 · 数 全部 / 警告 / 错误 · 按筛选留下 · 取最后 offset+limit 行倒序输出 ----
_LQ_WE='^[+-][0-9]{4} [0-9-]+ [0-9:]+ (ERROR|FATAL|PANIC|WARN|WARNING) '       # 和以前一样: 行头的第 4 个字段是级别
_LQ_ER='^[+-][0-9]{4} [0-9-]+ [0-9:]+ (ERROR|FATAL|PANIC) '
_lq_grepq() { if [ -n "$LQ_QE" ]; then LC_ALL=C grep -a -i -F -e "$LQ_QE"; else cat; fi; }
_lq_wecand() { # 各段里可能是警告 / 错误的行 (按顺序, 一般很少; 先用固定字符串粗筛, 快) 和带颜色控制符的行 -> $LQT/cand
  local p
  for p in "${LQ_P[@]}"; do LC_ALL=C grep -a -F -e ' ERROR ' -e ' FATAL ' -e ' PANIC ' -e ' WARN ' -e ' WARNING ' -e "$_LQ_ESC" "$p"; done > "$LQT/cand"
}
_lq_proxy() { # <q 小写> <筛选> <条数> <跳过>  -> {"total":…,"rows":[…],"summary":{…}}
  local f=$2 lim=$3 off=$4 i n c all=0 nwe nerr t k rem ln on
  local -a cnt take
  _lq_qe "$1"
  n=${#LQ_P[@]}; : > "$LQT/we"
  if [ "$LQ_NEVER" = 0 ] && [ "$n" -gt 0 ]; then
    _lq_wecand
    if LC_ALL=C grep -a -q -F -e "$_LQ_ESC" "$LQT/cand"; then     # 有颜色控制符: 和以前一样先去掉再比较 (正常的核心日志没有, 这条慢路几乎不会走)
      cat "${LQ_P[@]}" | LC_ALL=C awk '{ gsub(/\033\[[0-9;]*m/, ""); print }' > "$LQT/plain"; LQ_P=("$LQT/plain"); n=1
      _lq_wecand
    fi
    LC_ALL=C grep -a -E "$_LQ_WE" "$LQT/cand" | _lq_grepq > "$LQT/we"           # 用和以前相同的行头规则确认级别
    i=0
    while [ "$i" -lt "$n" ]; do
      if [ -z "$LQ_QE" ]; then c=$(_lq_lines "${LQ_P[$i]}"); else c=$(LC_ALL=C grep -a -c -i -F -e "$LQ_QE" "${LQ_P[$i]}"); fi
      case $c in ''|*[!0-9]*) c=0 ;; esac
      cnt[$i]=$c; all=$((all + c)); i=$((i + 1))
    done
  fi
  nwe=$(_lq_lines "$LQT/we"); nerr=$(LC_ALL=C grep -a -c -E "$_LQ_ER" "$LQT/we"); case $nerr in ''|*[!0-9]*) nerr=0 ;; esac
  case $f in error) t=$nerr ;; warn) t=$nwe ;; *) t=$all ;; esac
  ln=$(_lq_norm "$lim"); on=$(_lq_norm "$off")                     # 这一页要的是筛选后最后 offset+limit 行里较早的 limit 行
  if [ "$ln" = 0 ] || [ "$on" = big ]; then k=0
  elif [ "$on" -ge "$t" ]; then k=0
  elif [ "$ln" = big ]; then k=$t
  else k=$((on + ln)); [ "$k" -gt "$t" ] && k=$t; fi
  : > "$LQT/page"
  if [ "$k" -gt 0 ]; then
    case $f in
      error) LC_ALL=C grep -a -E "$_LQ_ER" "$LQT/we" | tail -n "$k" > "$LQT/page" ;;
      warn) tail -n "$k" "$LQT/we" > "$LQT/page" ;;
      *) rem=$k; i=$((n - 1))                                       # 从最后一段往前取, 每段取它自己的最后几行 (实时日志那段通常就够了)
         while [ "$i" -ge 0 ] && [ "$rem" -gt 0 ]; do c=${cnt[$i]}; [ "$c" -gt "$rem" ] && c=$rem; take[$i]=$c; rem=$((rem - c)); i=$((i - 1)); done
         i=$((i + 1))
         while [ "$i" -lt "$n" ]; do
           c=${take[$i]:-0}
           if [ "$c" -gt 0 ]; then
             if [ -z "$LQ_QE" ]; then tail -n "$c" "${LQ_P[$i]}"; else LC_ALL=C grep -a -i -F -e "$LQ_QE" "${LQ_P[$i]}" | tail -n "$c"; fi
           fi
           i=$((i + 1))
         done > "$LQT/page" ;;
    esac
  fi
  LC_ALL=C awk -v lim="$lim" -v off="$off" -v n="$t" -v all="$all" -v nwarn="$((nwe - nerr))" -v nerr="$nerr" "$_AWK_ESC"'
    { a[NR] = $0 }
    END { printf "{\"total\":%d,\"rows\":[", n; c = 0
      for (i = NR - off; i >= 1 && c < lim; i--) { l = a[i]; ts = ""; lv = ""; msg = l
        if (match(l, /^[+-][0-9][0-9][0-9][0-9] [0-9-]+ [0-9:]+ [A-Z]+ /)) { split(substr(l, RSTART, RLENGTH), p, " "); ts = p[2] " " p[3]; lv = p[4]; msg = substr(l, RLENGTH + 1) }
        printf "%s{\"ts\":\"%s\",\"level\":\"%s\",\"msg\":\"%s\"}", (c++ ? "," : ""), esc(ts), esc(lv), esc(msg) }
      printf "],\"summary\":{\"all\":%d,\"warn\":%d,\"error\":%d}}", all + 0, nwarn + 0, nerr + 0 }' "$LQT/page"
}

# ---- 网站访问: 只读这一天最后的一段, 不够这一页就放大 ----
_LQ_HDR='^[+-][0-9]{4} [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]+ [A-Z]+ '         # access.awk 认的行头
_lq_ids() { # stdin: 日志行 -> 这些行的连接编号, 每行一个 (和 access.awk 一样: 行头之后紧跟 [编号 耗时])
  LC_ALL=C awk 'match($0, /^[+-][0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9:]+ [A-Z]+ \[[0-9]+ [^]]*\] /) { s = substr($0, RSTART, RLENGTH); s = substr(s, index(s, "[") + 1); print substr(s, 1, index(s, " ") - 1) }'
}
_lq_pick() { # <编号文件>  stdin -> 只留这些连接的行 (行头里没有 "[", 所以第一个 " [" 后面就是编号; 不是连接的行 access.awk 本来就不看)
  LQ_IDS=$1 LC_ALL=C awk 'BEGIN { f = ENVIRON["LQ_IDS"]; while ((getline l < f) > 0) s[l] = 1; close(f) }
    { if ((i = index($0, " [")) > 0) { r = substr($0, i + 2, 24); j = index(r, " "); if (j > 1 && (substr(r, 1, j - 1) in s)) print } }'
}
_lq_acc_awk() { # <窗口模式 0|1> <窗口第一行的时间|空>  stdin -> access.awk 的 JSON (其余参数和以前的查询一样)
  LC_ALL=C awk -f "$LIB/access.awk" -v mode=json -v q="$LQ_Q" -v f="$LQ_F" -v lim="$LQ_LIM" -v off="$LQ_OFF" -v since= -v mask=0 -v win="$1" -v t0="$2"
}
_lq_cands() { # <字节数> <按搜索词 0|1>  这一段里「可能符合」的行数 (每条符合的连接至少有一行这样的行); 不搜索也不筛选时不输出
  local p d
  if [ "$2" = 1 ]; then _lq_window "$1" | LC_ALL=C grep -a -c -i -F -e "$LQ_QE"; return 0; fi
  case $LQ_F in
    error) _lq_window "$1" | LC_ALL=C grep -a -c -F -e '] dns: lookup failed' -e '] dns: exchange failed' -e '] connection: open ' ;;
    direct) _lq_window "$1" | LC_ALL=C grep -a -c -F -e '[direct' ;;
    proxy) p=$(_lq_window "$1" | LC_ALL=C grep -a -c -F -e ']: outbound connection to ' -e ']: outbound packet connection to ')
           d=$(_lq_window "$1" | LC_ALL=C grep -a -c -E '[[]direct(-[a-z]+)?[]]: outbound (packet )?connection to ')
           printf '%s\n' "$(( ${p:-0} - ${d:-0} ))" ;;
  esac
  return 0
}
_lq_grow() { # <窗口> <读到的条数> <需要的条数>  -> 下一次的窗口: 至少 ×4; 照读到的密度估计还差得多时, 一次放到估计值的 1.5 倍 (一条都没读到 = 整天)
  local w=$1 got=$2 need=$3 x y
  x=$((w * 4))
  if [ "$got" -le 0 ]; then y=$((x * 1024)); else y=$(( (w / got + 1) * need * 3 / 2 )); fi
  [ "$y" -gt "$x" ] && x=$y
  printf '%s' "$x"
}
_lq_access() { # <q 小写> <筛选> <条数> <跳过>  -> access.awk 的 JSON; 没有读完整天时创建 $LQT/partial
  local B=0 i W need ln on whole=0 pre=0 esc=0 usepre=0 out tot t0 cand
  LQ_Q=$1 LQ_F=$2 LQ_LIM=$3 LQ_OFF=$4
  _logs_access_head > "$LQT/hdr"
  i=0; while [ "$i" -lt "${#LQ_P[@]}" ]; do B=$((B + ${LQ_S[$i]:-0})); i=$((i + 1)); done
  ln=$(_lq_norm "$LQ_LIM"); on=$(_lq_norm "$LQ_OFF")
  if [ "$ln" = big ] || [ "$on" = big ]; then need=all; else need=$((on + ln)); fi
  _lq_qe "$LQ_Q"
  if [ "$LQ_NEVER" = 1 ]; then _lq_acc_awk 0 '' < "$LQT/hdr"; return 0; fi            # 搜索词不可能出现在任何连接里: 和读完整天一样, 一条也没有
  if [ -n "$LQ_QE" ]; then                     # 只把含搜索词的连接交给 access.awk. 搜索比较的是「网站 应用 出口 原因 失败类型 地址」用空格连起来的文字 (都转成小写):
    pre=1                                      #   网站 / 应用 / 出口 / 地址都是原始行里的原文, 所以符合的连接一定有一行含这个词 (不分大小写)。例外的不预选:
    case $LQ_QE in *' '*) pre=0 ;; esac        #   带空格的词可能跨字段; 原因 (policy …) / 失败类型 (timeout …) 是推算出来的, 原始行里不一定有
    case 'policy timeout refused reset unreachable dns tls eof rejected other' in *"$LQ_QE"*) pre=0 ;; esac
  fi
  W=$(test_env ENANA_LOGS_WINDOW 4194304); case $W in ''|*[!0-9]*|0) W=4194304 ;; esac
  while :; do
    whole=0; if [ "$need" = all ] || [ "$W" -ge "$B" ]; then whole=1; W=$B; fi
    esc=0; usepre=0                            # 这一段有颜色控制符 (ESC; 正常没有) 时原始行和 access.awk 看到的不一样: 不预选, 也不用行数估计
    if [ "$pre" = 1 ] || { [ -n "$LQ_F" ] && [ "$whole" = 0 ]; }; then _lq_window "$W" | LC_ALL=C grep -a -q -F -e "$_LQ_ESC" && esc=1; fi
    [ "$pre" = 1 ] && [ "$esc" = 0 ] && usepre=1
    if [ "$whole" = 0 ] && [ "$esc" = 0 ]; then
      cand=$(_lq_cands "$W" "$usepre")
      if [ -n "$cand" ] && [ "$cand" -lt "$need" ]; then W=$((W * 4)); continue; fi      # 这一段里可能符合的行都不够这一页: 不必跑 access.awk, 直接放大
    fi
    if [ "$usepre" = 1 ]; then
      _lq_window "$W" | LC_ALL=C grep -a -i -F -e "$LQ_QE" | _lq_ids > "$LQT/ids"
      t0=''; [ "$whole" = 1 ] || t0=$(_lq_window "$W" | LC_ALL=C grep -a -m 1 -E "$_LQ_HDR" | cut -d' ' -f3)
      out=$({ cat "$LQT/hdr"; if [ -s "$LQT/ids" ]; then _lq_window "$W" | _lq_pick "$LQT/ids"; fi; } | _lq_acc_awk "$((1 - whole))" "$t0")
    else
      out=$({ cat "$LQT/hdr"; _lq_window "$W"; } | _lq_acc_awk "$((1 - whole))" '')
    fi
    tot=${out#\{\"total\":}; tot=${tot%%,*}; case $tot in ''|*[!0-9]*) tot=0 ;; esac
    if [ "$whole" = 0 ] && [ "$tot" -lt "$need" ]; then W=$(_lq_grow "$W" "$tot" "$need"); continue; fi
    break
  done
  [ "$whole" = 1 ] || : > "$LQT/partial"
  printf '%s' "$out"
}

# logs_query <类型> <日期> <q> <limit> <offset> [筛选]  -> {"ok":true,"days":[…],"total":N,"rows":[…],"summary":{…}}
#   筛选: ops: error | dashboard | terminal | auto   access: direct | proxy | error   proxy: warn (警告和错误) | error
#   access 没读完整天时多一个 "partial":true (total / summary 只算读到的部分); 读完整天时和以前的结果逐字节相同
logs_query() {
  local type=$1 day=$2 q=$3 limit=$4 off=$5 f=${6:-} rows part='' LQT LQ_QE LQ_NEVER LQ_Q LQ_F LQ_LIM LQ_OFF
  local -a LQ_P LQ_S
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
    proxy|access)
      LQT=$(mktemp -d 2>/dev/null) || LQT="$H/.logs-query.$$"
      mkdir -p "$LQT"
      _lq_prep "$day"
      if [ "$type" = proxy ]; then rows=$(_lq_proxy "$q" "$f" "$limit" "$off"); else rows=$(_lq_access "$q" "$f" "$limit" "$off"); fi
      [ -e "$LQT/partial" ] && part='"partial":true,'
      rm -rf "$LQT" ;;
    *) printf '{"ok":false,"error":"日志类型无效"}'; return ;;
  esac
  printf '{"ok":true,"days":%s,%s%s}' "$(_logs_days_json)" "$part" "$(printf '%s' "$rows" | sed 's/^{//; s/}$//')"
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
  for f in "$LOGS"/ops-* "$LOGS"/health-*; do [ -f "$f" ] && { sz=$(file_size "$f" 2>/dev/null || echo 0); o=$((o+sz)); }; done      # 健康记录算在「操作记录」里
  for f in "$LOGS"/proxy-* "$H/sing-box.log"; do [ -f "$f" ] && { sz=$(file_size "$f" 2>/dev/null || echo 0); p=$((p+sz)); }; done
  a=$p   # 网站访问从代理日志里归并出来, 占用即代理日志的占用
  printf '{"ops":%s,"access":%s,"proxy":%s,"total":%s}' "$o" "$a" "$p" "$((o + p))"
}

logs_clear() { # <类型 ops|access|proxy|all> [before=YYYY-MM-DD] -> 打印释放的字节数
  local type=$1 before=${2:-} f d freed=0 sz
  case $type in ops|access|proxy|all) ;; *) return 1 ;; esac
  for f in "$LOGS"/*; do
    [ -f "$f" ] || continue
    case $type in ops) case $f in */ops-*|*/health-*) ;; *) continue ;; esac ;; access|proxy) case $f in */proxy-*) ;; *) continue ;; esac ;; esac
    d=$(printf '%s' "$f" | sed -nE 's/.*-([0-9]{4}-[0-9]{2}-[0-9]{2})\.log(\.gz)?$/\1/p')
    if [ -n "$before" ] && [ -n "$d" ] && ! [ "$d" \< "$before" ]; then continue; fi
    sz=$(file_size "$f" 2>/dev/null || echo 0); freed=$((freed + sz)); rm -f "$f"
  done
  if [ "$type" != ops ] && [ -z "$before" ] && [ -s "$H/sing-box.log" ]; then sz=$(file_size "$H/sing-box.log" 2>/dev/null || echo 0); freed=$((freed + sz)); : > "$H/sing-box.log"; fi
  echo "$freed"
}

settings_json() { # GET /api/settings 的 settings 与 usage
  printf '"settings":{"log_hours":%s,"log_hours_min":%s,"log_hours_max":%s,"log_ops":%s,"access_log":%s,"log_core":%s,"auto_sites":%s,"diag_upload":%s},"usage":%s' \
    "$(logs_hours)" "$LOG_HOURS_MIN" "$LOG_HOURS_MAX" "$([ "${LOG_OPS:-1}" = 1 ] && echo true || echo false)" "$([ "${ACCESS_LOG:-1}" = 1 ] && echo true || echo false)" "$([ "${LOG_CORE:-1}" = 1 ] && echo true || echo false)" "$([ "${AUTO_SITES:-0}" = 1 ] && echo true || echo false)" "$([ "${DIAG_UPLOAD:-0}" = 1 ] && echo true || echo false)" "$(logs_usage_json)"
}

# ======================================================================================================================
# 诊断导出
# ======================================================================================================================
BUNDLE_FORMAT=1

_b_mask_user() { sed -E 's#/Users/[^/ ,"]+#/Users/<user>#g; s#[A-Za-z]:\\*Users\\*[^\\"]+#C:\\Users\\<user>#g; s#user: (root|_[A-Za-z0-9_]+)#user:@@K@@\1#g; s#user: [A-Za-z0-9._-]+#user: <user>#g; s#user:@@K@@#user: #g'; }   # Windows: C:\Users\<name> (JSON 行里是 \\ 也一样)

# 打码的 awk 函数库 (地址 / URL / 文字共用; mask1 与 _b_mask_host 同一规则: 1.2.3.4 -> 1.2.*.* · a.b.example.com -> a***.example.com · IPv6 -> 前两段:*)
_B_TEXT_AWK='
function mask1(h,   n, p, s, i) {
  if (h ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { split(h, p, "."); return p[1] "." p[2] ".*.*" }
  if (index(h, ":") > 0) { split(h, p, ":"); return p[1] ":" p[2] ":*" }
  if (h == "") return ""
  n = split(h, p, "."); if (n <= 2) return substr(h, 1, 1) "***"
  s = substr(p[1], 1, 1) "***"; for (i = 2; i <= n; i++) s = s "." p[i]; return s
}
function ip4s(s,   out, t, pre, rest) {          # 文字里的 IPv4 (前后不能紧挨着数字, 免得误伤 1.2.3.4.5 这类版本号; 句末的句号不算)
  out = ""
  while (match(s, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) {
    pre = substr(s, 1, RSTART - 1); t = substr(s, RSTART, RLENGTH); rest = substr(s, RSTART + RLENGTH); s = rest
    if (pre ~ /[0-9]\.?$/ || rest ~ /^[0-9]/ || rest ~ /^\.[0-9]/) out = out pre t; else out = out pre mask1(t)
  }
  return out s
}
function ip6s(s,   out, t, u, c, pre, rest) {    # 文字里的 IPv6: 至少两个冒号, 且有 :: 或至少四个冒号 (所以 10:00:00 这样的时刻不算); 「标签:」的冒号不算地址的一部分
  out = ""
  while (match(s, /[0-9A-Fa-f]*:[0-9A-Fa-f:]*/)) {
    pre = substr(s, 1, RSTART - 1); t = substr(s, RSTART, RLENGTH); rest = substr(s, RSTART + RLENGTH); s = rest
    if (substr(t, 1, 1) == ":" && substr(t, 2, 1) != ":") { pre = pre ":"; t = substr(t, 2) }
    u = t; c = gsub(/:/, ":", u)
    if (c < 2 || (index(t, "::") == 0 && c < 4)) out = out pre t; else out = out pre mask1(t)
  }
  return out s
}
function lit(s, a, b,   out, i) {                # 字面替换 (服务器地址 / 标签; 不当正则)
  out = ""
  while ((i = index(s, a)) > 0) { out = out substr(s, 1, i - 1) b; s = substr(s, i + length(a)) }
  return out s
}
function redact(s,   out, a, e, h) {             # URL: 用户名 / 密码 (最后一个 @ 之前) 去掉; 路径 / 查询串 / 片段换成 /<path>; IP 形式的主机同 mask1; 域名保留
  out = ""
  while (match(s, /:\/\/[^| \t]+/)) {
    out = out substr(s, 1, RSTART - 1) "://"
    a = substr(s, RSTART + 3, RLENGTH - 3); s = substr(s, RSTART + RLENGTH)
    if (match(a, /[\/?#]/)) a = substr(a, 1, RSTART - 1)
    for (e = length(a); e >= 1; e--) if (substr(a, e, 1) == "@") { a = substr(a, e + 1); break }
    if (substr(a, 1, 1) == "[") { e = index(a, "]"); if (e > 0) a = "[" mask1(substr(a, 2, e - 2)) substr(a, e) }
    else if (match(a, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) { h = substr(a, 1, RLENGTH); a = mask1(h) substr(a, RLENGTH + 1) }
    out = out a "/<path>"
  }
  return out s
}
function hostmask(d,   o, t, v, k, p, pre, lead) {   # 操作记录详情里的 host=<地址>[:端口]: 地址打码 (同 mask1), 端口保留
  o = ""
  while (match(d, /(^|[ ])host=[^ "]+/)) {
    pre = substr(d, 1, RSTART - 1); t = substr(d, RSTART, RLENGTH); d = substr(d, RSTART + RLENGTH)
    k = index(t, "host="); lead = substr(t, 1, k + 4); v = substr(t, k + 5); p = ""
    if (v !~ /:.*:/ && match(v, /:[0-9]+$/)) { p = substr(v, RSTART); v = substr(v, 1, RSTART - 1) }
    o = o pre lead mask1(v) p
  }
  return o d
}
'
_b_mask_host() { # stdin 每行一个地址 -> 打码 (见 _B_TEXT_AWK 的 mask1)
  awk "$_B_TEXT_AWK"' { print mask1($0) }'
}
_b_scrub_text() { LC_ALL=C awk "$_B_TEXT_AWK"'{ print ip6s(ip4s($0)) }'; }      # 文字 (标准输入) 里的 IP 打码

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
  printf 'settings.log_ops=%s\nsettings.access_log=%s\nsettings.log_core=%s\nsettings.log_hours=%s\nsettings.auto_sites=%s\nsettings.auto_update=%s\nsettings.diag_upload=%s\n' "${LOG_OPS:-1}" "${ACCESS_LOG:-1}" "${LOG_CORE:-1}" "$(logs_hours)" "${AUTO_SITES:-0}" "${AUTO_UPDATE:-1}" "${DIAG_UPLOAD:-0}"
  printf 'ports.proxy=%s\nports.clash=%s\nports.api=%s\nports.speed=%s\n' "$PORT" "$UI_PORT" "$API_PORT" "$SPEED_PORT"
  printf 'servers.total=%s\nservers.pin=%s\nservers.auto=%s\nservers.other=%s\n' "$(srv_count)" "$role_pin" "$role_auto" "$role_other"
  printf 'account.logged_in=%s\ncontent.seq=%s\ncontent.version=%s\nrules.updated=%s\n' "$(auth_logged_in && echo yes || echo no)" "$(cloud_seq)" "$(cloud_version)" "$(rules_updated_at)"
}

_b_env() {
  if [ "${ENANA_PLATFORM:-darwin}" = windows ]; then network_diagnostics | _b_mask_user; _b_helperlogs; return; fi
  local p pid out
  network_diagnostics | _b_mask_user
  scutil --proxy 2>/dev/null | awk '/^[[:space:]]+(HTTP|HTTPS|SOCKS|ProxyAutoConfig|ProxyAutoDiscovery|Exclude|FTP|RTSP|Gopher)[A-Za-z]* :/ { k = $1; $1 = ""; $2 = ""; sub(/^  */, ""); print "sysproxy." k "=" $0 }'
  printf 'sysproxy.points_to_enana=%s\n' "$(os_sysproxy_ok && echo yes || echo no)"
  printf 'dns.system=%s\n' "$(scutil --dns 2>/dev/null | awk '/nameserver\[[0-9]+\]/ {print $3}' | sort -u | head -6 | paste -sd' ' -)"
  route -n get default 2>/dev/null | awk '/interface:/ {print "net.interface=" $2} /gateway:/ {print "net.gateway=" $2}'
  detect_others 2>/dev/null; printf 'other_proxy_software=%s\n' "${OTHER_PROXY:-}"
  for p in "$PORT" "$UI_PORT" "$API_PORT" "$SPEED_PORT"; do
    out=$(lsof -nP -iTCP:"$p" -sTCP:LISTEN -Fc 2>/dev/null | sed -n 's/^c//p' | sort -u | paste -sd, -)
    # TUN: 核心是 root 的系统服务, 当前用户的 lsof 看不到它的监听端口 —— 显示 none 会误导成「没有在监听」
    [ -n "$out" ] || { [ "${NETWORK_MODE:-system}" = tun ] && enhanced_loaded 2>/dev/null && out='root-service(not visible to lsof)'; }
    printf 'listen.%s=%s\n' "$p" "${out:-none}"
  done
  pid=${SVC_PID:-$(os_service_pid 2>/dev/null)}
  if [ -n "$pid" ]; then ps -o etime=,rss= -p "$pid" 2>/dev/null | awk -v p="$pid" '{ print "core.pid=" p; print "core.uptime=" $1; print "core.rss_kb=" $2 }'; fi
  # launchd 眼里的核心进程: 退出码 / 被拉起过几次 (崩溃后反复重启时 runs 会很大); 会话心跳 / 被退出登录的原因
  launchctl print "$GUI/$LABEL" 2>/dev/null | awk '/^[[:space:]]*(last exit code|runs) = / { k = $0; sub(/^[[:space:]]*/, "", k); gsub(/ = /, "=", k); gsub(/ /, "_", k); print "service." k }'
  [ -f "$H/hb.fail" ] && printf 'session.heartbeat_failing_since=%s\n' "$(os_date_at "$(cat "$H/hb.fail" 2>/dev/null)" 2>/dev/null || cat "$H/hb.fail")"
  [ -s "$H/notice" ] && printf 'session.last_end_reason=%s\n' "$(head -1 "$H/notice")"
  _b_sessionfacts; _b_pinfacts
  stats_summary                         # 流量统计: 最近 7 天每天采样了多少分钟 (有数据的日子 samples=N; 没有行 = 那天一次都没采到, 不是「没流量」)
  printf 'disk.free_kb=%s\n' "$(df -k "$H" 2>/dev/null | awk 'NR==2 {print $4}')"
  printf 'logs.size_kb=%s\n' "$(du -sk "$LOGS" 2>/dev/null | awk '{print $1}')"
  if [ -x "$SB" ] && [ -s "$H/config.json" ]; then
    if out=$("$SB" check -c "$H/config.json" 2>&1); then printf 'config.check=ok\n'; else printf 'config.check=error: %s\n' "$(printf '%s' "$out" | head -1 | cut -c1-200)"; fi
  fi
  _b_helperlogs
  return 0
}

_b_env_masked() { _b_env | _b_mask_user; }      # 整个分区过一遍用户名打码: 核心配置检查的报错里会有 ~/.enana/… 的路径
_b_helperlogs() { # 辅助服务日志里最近的错误 (macOS 和 Windows 都导出; Windows 的 worker.log 是 JSON 行, 启动 / 核心就绪 / 失败事件也在里面)
  local p
  # api.log 整段 (最后 200 行) 放在 apilog 分区, 见 _b_apilog; 这里不再重复抽取
  for p in tick.log check.log worker.log launcher.log; do
    [ -s "$H/$p" ] && tail -n 40 "$H/$p" 2>/dev/null | grep -iE 'error|fail|fatal|warn|denied|worker\.start|core\.ready' | tail -n 8 | _b_mask_user | sed "s/^/helperlog.$p: /"
  done
  [ "${BUNDLE_OPS:-0}" = 1 ] && _b_update_failed      # 它来自操作记录: 只在导出了操作记录的时候才写
  return 0
}
_b_apilog() { # [起始时间|空] api.log 最后 200 行 (先上一代 api.log.1): 只留导出时间范围内的行 (没时间的行跟随前一行); 服务器标签 → <server>, 其余打码同 _B_TEXT_AWK
  local since=${1:-} lst
  lst=$(mktemp) || return 1
  srv_list | while IFS=$'\t' read -r tag _ host _; do
    [ -n "$tag" ] && printf '%s\t%s\t%s\n' "${#tag}" "$tag" '<server>'
    [ -n "$host" ] && printf '%s\t%s\t%s\n' "${#host}" "$host" "$(printf '%s\n' "$host" | _b_mask_host)"
  done | sort -t "$(printf '\t')" -k1,1nr > "$lst"            # 长的先替换 (主机名里可能含标签)
  { tail -n 2000 "$H/api.log.1" 2>/dev/null; tail -n 2000 "$H/api.log" 2>/dev/null; } |
    LC_ALL=C awk -v s="$since" -v lst="$lst" "$_B_TEXT_AWK"'
      BEGIN { keep = (s == ""); n = 0; while ((getline ln < lst) > 0) { m = split(ln, kv, "\t"); if (m >= 3) { n++; fr[n] = kv[2]; to[n] = kv[3] } }; close(lst) }
      /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]/ { keep = (s == "" || substr($0, 1, 19) >= s) }
      keep { l = $0; for (i = 1; i <= n; i++) l = lit(l, fr[i], to[i]); print redact(ip6s(ip4s(l))) }' |
    tail -n 200 | _b_mask_user
  rm -f "$lst"
}
_b_update_failed() { # 最近一次「更新 enana」的结果: 只看操作记录, 从新到旧找到最近的一条; 失败 → 时间 + 详情; 成功或从没更新过 → none
  local d hit=''
  for d in $(ls -1 "$LOGS" 2>/dev/null | sed -nE 's/^ops-([0-9]{4}-[0-9]{2}-[0-9]{2})\.log(\.gz)?$/\1/p' | sort -ur); do
    hit=$(_logs_stream ops "$d" | awk -F'\t' '$3 == "更新 enana"' | tail -n 1)
    [ -n "$hit" ] && break
  done
  if [ -n "$hit" ] && [ "$(printf '%s\n' "$hit" | cut -f5)" = error ]; then
    printf '%s\n' "$hit" | awk -F'\t' '{ printf "update.last_failed.ts=%s\nupdate.last_failed.detail=%s\n", $1, $4 }' | _b_mask_user | _b_scrub_text
  else printf 'update.last_failed=none\n'; fi
}

_b_pinfacts() { # 「固定出口」是不是真的存在: 没有任何服务器的 role 是 pin 时, 选了「固定出口」的应用 / 服务全部直连 (verdict 的 pin-empty 读这里; *_names 只在本机导出里, 上传摘要时会去掉)
  printf 'pin.servers=%s\n' "$(srv_list | awk -F'\t' '$5=="pin"' | wc -l | tr -d ' ')"
  clash GET /proxies 2>/dev/null | perl -MJSON::PP -e '
    local $/; my $j = eval { decode_json(<STDIN>) } or exit 0; my $p = $j->{proxies} || {};
    print "pin.group_members=", join(",", @{ ($p->{PIN} || {})->{all} || [] }), "\n";
    my @on = sort grep { (($p->{$_}{type} // "") =~ /^selector$/i) && (($p->{$_}{now} // "") eq "PIN") } keys %$p;
    print "pin.selectors_on_pin=", scalar(@on), "\n";
    print "pin.selectors_on_pin_names=", join(",", @on[0 .. ($#on > 15 ? 15 : $#on)]), "\n" if @on;'
  [ -s "$H/.apps.now" ] || apps_installed > "$H/.apps.now" 2>/dev/null
  apps_json 2>/dev/null | perl -MJSON::PP -e '
    local $/; my $l = eval { decode_json(<STDIN>) } || []; my @a = map { $_->{name} // "" } grep { ($_->{state} // "") eq "pin" } @$l;
    print "pin.app_policies=", scalar(@a), "\n"; print "pin.app_policy_names=", join(",", @a[0 .. ($#a > 15 ? 15 : $#a)]), "\n" if @a;'
}
_b_sessionfacts() { # 登录会话 + 心跳的现状: 最近一次心跳是什么时候 / 什么结果 / 最近一次成功是什么时候 (被退出登录前后最关键的证据)
  local last code okts now_ sid; now_=$(date +%s)
  auth_logged_in || { printf 'session.state=logged-out\n'; return 0; }
  last=$(session_hb_get last); code=$(session_hb_get code); okts=$(session_hb_get ok); sid=$(session_id)
  printf 'session.state=logged-in\nsession.id_tail=%s\nsession.device_tail=%s\n' "${sid: -4}" "$(device_uid | cut -c1-8)"
  [ -z "$last" ] || printf 'session.last_heartbeat_age_s=%s\nsession.last_heartbeat_code=%s\n' "$((now_ - last))" "${code:-}"
  [ -z "$okts" ] || printf 'session.last_heartbeat_ok_age_s=%s\n' "$((now_ - okts))"
  [ ! -s "$H/cloud.token" ] || printf 'session.token_age_s=%s\n' "$(( now_ - $(file_mtime "$H/cloud.token" 2>/dev/null || echo "$now_") ))"
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
  ' "$H/config.json" | _b_mask_user      # 配置里的日志 / 入站路径含系统用户名 (C:/Users/<名字>/…), 必须打码
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
      custom-rulesets.tsv|dns.conf) _b_url_redact < "$H/$f" ;;                  # 自定义规则集 / 自定义 DNS 的地址可能带着令牌, host 之后的部分不导出
      hosts.tsv) _b_hosts_mask < "$H/$f" ;;                                      # 域名|IP: IP 打码, 和服务器地址同样处理
      *) cat "$H/$f" ;;
    esac
  done
}
_b_url_redact() { LC_ALL=C awk "$_B_TEXT_AWK"'{ print redact($0) }'; }      # 地址: 用户名 / 密码去掉; host 之后的路径 / 查询串换成 /<path>; IP 形式的主机打码 (同 _b_mask_host)
_b_hosts_mask() { local d ip; while IFS='|' read -r d ip || [ -n "$d" ]; do printf '%s|%s\n' "$d" "$(printf '%s\n' "$ip" | _b_mask_host)"; done; }
_b_policy_masked() { _b_policy | _b_mask_user; }      # 整个分区再过一遍用户名打码 (路径里可能有 /Users/<名字>)

_b_servers() { # tag type host(打码) port role sub
  printf 'tag\ttype\thost\tport\trole\tsub\n'
  srv_list | while IFS=$'\t' read -r tag type host port role sub; do printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$tag" "$type" "$(printf '%s\n' "$host" | _b_mask_host)" "$port" "$role" "$sub"; done
}

_b_apps() { # 已识别的应用 + 当前设置
  [ -s "$H/.apps.now" ] || apps_installed > "$H/.apps.now"
  printf 'name\tstate\tflag\ttarget\tknown\trec\tgroup\tpath\n'
  apps_json | perl -MJSON::PP -e 'local $/; my $l = eval { decode_json(<STDIN>) } || []; for my $a (@$l) { my $p = $a->{path} // ""; $p =~ s{/Users/[^/]+}{/Users/<user>}; print join("\t", map { $_ // "" } @$a{qw(name state flag target)}, ($a->{known} ? "yes" : "no"), @$a{qw(rec group)}, $p), "\n" }' | _b_mask_user
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
  for d in "$@"; do _logs_stream ops "$d"; done | LC_ALL=C awk -v s="$since" "$_B_TEXT_AWK"'BEGIN { FS = OFS = "\t" } { if (s == "" || substr($0, 1, 19) >= s) { $4 = hostmask($4); print } }' | _b_mask_user
}
_b_access() { # <起始时间|空> <日期…>
  local since=$1; shift
  _logs_access_input "$@" | LC_ALL=C awk -f "$LIB/access.awk" -v mode=tsv -v q= -v lim=0 -v off=0 -v since="$since" -v mask=1
}
_b_proxy() { # <起始时间|空> <日期…>
  local since=$1 d; shift
  for d in "$@"; do _logs_stream proxy "$d"; done | sed $'s/\033\\[[0-9;]*m//g' | LC_ALL=C awk -v s="$since" '{ ch = substr($0, 1, 1); if ((ch == "+" || ch == "-") && $2 ~ /^[0-9][0-9][0-9][0-9]-/) keep = (s == "" || ($2 " " $3) >= s); if (keep) print }' | _b_mask_user
}

_b_gen() { # <名称> <格式> <函数> [参数…]  生成一个分区: 内容写到 $BT/<名称>, 完整分区 (含 @@SECTION 行) 写到 $BT/sec.<名称>; 之后按需要的顺序输出 (自动判定要读别的分区, 但应该排在文件开头)
  local name=$1 fmt=$2; shift 2
  "$@" > "$BT/$name" 2>/dev/null || true
  { printf '@@SECTION %s format=%s rows=%s\n' "$name" "$fmt" "$(wc -l < "$BT/$name" | tr -d ' ')"; cat "$BT/$name"; } > "$BT/sec.$name"
}
_b_emit() { local n; for n in "$@"; do [ -f "$BT/sec.$n" ] && cat "$BT/sec.$n"; done; return 0; }

# logs_bundle <小时数|all> <分区 逗号分隔: ops access proxy snapshot>  -> 打印诊断导出文件 (UTF-8 文本)
#   输出顺序: meta · verdict (自动判定) · env config policy servers apps probes live · health_summary outages health · ops · access · proxy
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
  case ",$secs," in *,snapshot,*) declared="$declared,verdict,env,config,policy,servers,apps,probes,live,health_summary,outages,health,apilog" ;; esac
  case ",$secs," in *,ops,*) declared="$declared,ops" ;; esac
  case ",$secs," in *,access,*) declared="$declared,access" ;; esac
  case ",$secs," in *,proxy,*) declared="$declared,proxy" ;; esac
  printf '#sections=%s\n' "$declared"
  printf '%s\n' '#about=这是 enana 的诊断导出文件, 用来排查「网站打不开 / 走错出口 / 应用没识别 / 某个 App 连不上」之类的问题。每个 "@@SECTION 名称 format=… rows=N" 开始一个分区, 到下一个 "@@SECTION" 或 "@@END" 结束; 以 "#" 开头的行是说明; format=kv 是 键=值, tsv 的第一行是列名 (制表符分隔), raw 是原始日志行。先看 verdict 分区: 它是根据 health (每分钟的服务器端口探测 + 每 5 分钟经代理的探测) / 状态变化 / 访问记录自动给出的判断和证据。'
  printf '%s\n' '#privacy=不含任何密码 / 令牌 / 服务器凭据; 服务器地址和系统用户名已打码; 但包含访问过的域名和应用名, 请只发给你信任的人。'
  printf '%s\n' '#route-reasons=出口名 direct-mode(代理总开关关闭) direct-lan(本机/局域网) direct-site(你把该网站设为直连) direct-app(你把该应用设为直连/关) direct-cn(国内规则) direct(策略选了直连) 都是直连; 其它名字是代理服务器节点。'
  _b_gen meta kv _b_meta
  BUNDLE_OPS=0; case ",$secs," in *,ops,*) BUNDLE_OPS=1 ;; esac
  case ",$secs," in *,snapshot,*)
    _b_gen env kv _b_env_masked
    _b_gen config text _b_config
    _b_gen policy text _b_policy_masked
    _b_gen servers tsv _b_servers
    _b_gen apps tsv _b_apps
    _b_gen probes tsv _b_probes
    _b_gen live tsv _b_live
    _b_gen health tsv _b_health "$since"
    _b_gen health_summary tsv _b_health_summary "$since" "$hours"
    _b_gen outages tsv _b_health_outages "$since"
    _b_gen apilog raw _b_apilog "$since" ;; esac
  # shellcheck disable=SC2086
  case ",$secs," in *,ops,*) _b_gen ops tsv _b_ops "$since" $days ;; esac
  case ",$secs," in *,access,*) _b_gen access tsv _b_access "$since" $days ;; esac
  # 自动判定读 meta / env / health, 以及用户选了导出的 ops / access (没选的分区不会被拿来分析)
  case ",$secs," in *,snapshot,*) _b_gen verdict kv _b_verdict "$since" ;; esac
  _b_emit meta verdict env config policy servers apps probes live health_summary outages health apilog ops access
  # shellcheck disable=SC2086
  case ",$secs," in *,proxy,*) _b_sec proxy raw _b_proxy "$since" $days ;; esac      # 最大的一个分区: 直接流式输出
  printf '@@END\n'
  rm -rf "$BT"
}
