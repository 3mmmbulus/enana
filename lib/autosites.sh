# 自动识别「打不开的网站」并加入代理 (设置里打开 AUTO_SITES=1 才工作; 默认关闭)。依赖 common.sh servers.sh apps.sh logs.sh config.sh。
#
# 做法: 每分钟 (enana tick) 只读一次核心日志里「新增」的那部分, 找出「走直连却连不上」的连接 (超时 / 被重置 / 被拒绝);
#       同一个网站 15 分钟内多次失败、而且几乎每次都失败 (≥ 3 次, ≥ 60%), 就把它加进「网站」的覆盖里 (自动线路, 没有自动线路就用固定出口),
#       先用代理实际访问一次验证: 通了才保留, 还是不通就撤销 (24 小时内不再试)。加进去的网站另记在 $H/autosites.tsv, 网站页据此标「自动识别」。
# 不会动的: 你明确设置过的 (网站直连 direct-site / 应用直连 direct-app 的连接不参与)、局域网、目录里已有的服务、你已经有覆盖的网站、你从自动识别里删掉过的网站、
#           代理总开关关闭 / 全局模式时 (那时直连失败没有参考意义)、整个网络都在失败时 (断网, 不是某个网站的问题)。
# 参与判断的只有出口名 direct (策略选了直连/默认出口) 和 direct-cn (国内规则判成直连) 的失败: 国内规则把国外网站误判成直连, 正是最常见的情况。
#
#   $H/autosites.tsv        域名|添加时间|原因|失败次数|应用            自动添加的网站 (和 overrides.tsv 里的覆盖配套)
#   $H/autosites.dismissed  每行一个域名: 你从自动识别里删掉的, 不再自动添加
#   $H/.autosite.off        上次读到核心日志的位置 (inode 偏移)
#   $H/.autosite.ev         最近 15 分钟的事件: 时间 类型(A 直连尝试/F 直连失败) 连接编号 域名 出口 失败类型 应用
#   $H/.autosite.cool       验证没通过的域名和时间 (24 小时内不再试)

AUTOSITE_WIN=900                 # 统计窗口 (秒)
AUTOSITE_MIN_FAILS=3
AUTOSITE_PER_HOUR=5              # 每小时最多自动添加几个
AUTOSITE_MAX=200                 # 一共最多自动添加几个

autosite_on() { [ "${AUTO_SITES:-0}" = 1 ]; }
autosite_ready() { # 现在适合自动识别吗: 已开启 + 代理开着且是规则模式 + 至少有一个服务器
  autosite_on || return 1
  [ "${PROXY_ENABLED:-0}" = 1 ] && [ "${PROXY_MODE:-auto}" = auto ] || return 1
  [ -n "$(srv_list | awk -F'\t' '$5=="pin" || $5=="auto" {print "x"; exit}')" ]
}

# 从核心日志的新增部分里提取事件 (标准输入: 新增的日志行; 输出: 事件行)
_autosite_events() { # <当前秒数>
  LC_ALL=C awk -v now="$1" '
    function cls(m,   l) { l = tolower(m)
      if (l ~ /i\/o timeout|timed out|deadline exceeded|timeout/) return "timeout"
      if (l ~ /connection reset|broken pipe/) return "reset"
      if (l ~ /connection refused/) return "refused"
      if (l ~ /(^|[^a-z])eof/) return "eof"
      return "" }
    { line = $0; gsub(/\033\[[0-9;]*m/, "", line)
      if (!match(line, /^[+-][0-9][0-9][0-9][0-9] [0-9-]+ [0-9:]+ [A-Z]+ /)) next
      rest = substr(line, RLENGTH + 1)
      if (!match(rest, /^\[[0-9]+ [^]]*\] /)) next
      split(substr(rest, 2, RLENGTH - 3), idt, " "); id = idt[1]; msg = substr(rest, RLENGTH + 1)
      if (index(msg, "router: found process path: ") == 1) { pp = substr(msg, 29); sub(/, user: .*/, "", pp); if (match(pp, /[^\/]+\.app\//)) app[id] = substr(pp, RSTART, RLENGTH - 5); else { n = split(pp, pa, "/"); app[id] = pa[n] }; next }
      if (msg ~ /^outbound\/direct\[direct(-cn)?\]: outbound connection to /) {
        tg = msg; sub(/^outbound\/direct\[/, "", tg); sub(/\].*/, "", tg)
        hp = msg; sub(/.*outbound connection to /, "", hp); h = hp; sub(/:[0-9]+$/, "", h)
        print now "\tA\t" id "\t" h "\t" tg "\t\t" app[id]; next }
      if (index(msg, "connection: open connection to ") == 1 && msg ~ / using outbound\/direct\[direct(-cn)?\]: /) {
        hp = msg; sub(/^connection: open connection to /, "", hp); sub(/ using .*/, "", hp); h = hp; sub(/:[0-9]+$/, "", h)
        tg = msg; sub(/.* using outbound\/direct\[/, "", tg); sub(/\]: .*/, "", tg)
        m = msg; sub(/.*\]: /, "", m); c = cls(m)
        if (c != "") print now "\tF\t" id "\t" h "\t" tg "\t" c "\t" app[id] } }'
}

# 事件 -> 候选: 每行 域名<TAB>失败数<TAB>尝试数<TAB>失败类型<TAB>应用<TAB>示例域名 ; 整个网络都在失败时只输出一行 OUTAGE
_autosite_candidates() { # <当前秒数> <事件文件> <不处理的域名文件 (目录里的服务 / 已有覆盖 / 已记录 / 删除过 / 验证失败过)>
  LC_ALL=C awk -F'\t' -v now="$1" -v win="$AUTOSITE_WIN" -v minf="$AUTOSITE_MIN_FAILS" -v exf="$3" '
    function reg(h,   n, p, i, l2, l3) {                       # 要加入覆盖的域名: 一般取最后两段 (co.uk 之类取三段); 共享托管域名取完整主机名; IP / 本地域名不处理
      h = tolower(h); if (h ~ /^[0-9.]+$/ || index(h, ":") > 0 || index(h, ".") == 0) return ""
      n = split(h, p, "."); if (p[n] ~ /^(local|lan|localhost|internal|home|arpa|test|invalid|example|corp|intranet|private|onion)$/) return ""
      l2 = p[n-1] "." p[n]; l3 = (n >= 3) ? p[n-2] "." l2 : ""
      if (l2 in shared) return h
      if (l2 in sld) return (n >= 3) ? l3 : ""
      return l2 }
    function covered(h,   n, p, i, s) { n = split(h, p, "."); s = ""; for (i = n; i >= 1; i--) { s = (s == "" ? p[i] : p[i] "." s); if (s in skip) return 1 } return 0 }
    BEGIN {
      n = split("com.cn net.cn org.cn gov.cn edu.cn com.hk org.hk com.tw org.tw com.sg co.jp or.jp ne.jp co.kr or.kr co.uk org.uk ac.uk gov.uk com.au net.au org.au com.br co.in co.nz com.my com.ph com.vn co.id co.th", S, " "); for (i = 1; i <= n; i++) sld[S[i]] = 1
      n = split("amazonaws.com cloudfront.net github.io githubusercontent.com blogspot.com azurewebsites.net herokuapp.com vercel.app netlify.app pages.dev workers.dev web.app firebaseapp.com appspot.com onrender.com fly.dev r2.dev googleusercontent.com akamaized.net fastly.net cdn77.org b-cdn.net", S, " "); for (i = 1; i <= n; i++) shared[S[i]] = 1
      while ((getline l < exf) > 0) if (l != "") skip[tolower(l)] = 1; close(exf)
    }
    $1 + 0 >= now - win {
      d = reg($4); if (d == "") next
      if ($2 == "A" || $2 == "F") { key = d SUBSEP $3; if (!(key in seen)) { seen[key] = 1; na[d]++; sa[$3] = 1 } ; samp[d] = $4 }
      if ($2 == "F" && !(($3 SUBSEP "f") in fseen)) { fseen[$3 SUBSEP "f"] = 1; nf[d]++; ef[d] = $6; ap[d] = $7; tg[d] = $5; fall[$3] = 1 }
    }
    END {
      tot = 0; for (k in sa) tot++; bad = 0; for (k in fall) bad++
      if (tot >= 8 && bad * 10 > tot * 8) { print "OUTAGE"; exit }                                                  # 几乎所有直连都失败: 断网了, 不是某个网站的问题
      for (d in nf) if (nf[d] >= minf && nf[d] * 10 >= na[d] * 6 && !covered(d) && !covered(samp[d])) print d "\t" nf[d] "\t" na[d] "\t" ef[d] "\t" ap[d] "\t" samp[d] "\t" tg[d]
    }' "$2"
}

autosite_forget() { # <域名> [dismiss]  从自动识别的记录里去掉 (dismiss: 以后也不再自动添加)
  local d=$1
  [ -f "$H/autosites.tsv" ] && { LC_ALL=C awk -F'|' -v d="$d" '$1 != d' "$H/autosites.tsv" > "$H/autosites.tsv.new" && mv "$H/autosites.tsv.new" "$H/autosites.tsv"; }
  if [ "${2:-}" = dismiss ]; then touch "$H/autosites.dismissed"; grep -qxF -- "$d" "$H/autosites.dismissed" || printf '%s\n' "$d" >> "$H/autosites.dismissed"; fi
  return 0
}

autosite_registry_has() { awk -F'|' -v d="$1" '$1 == d {f=1} END{exit f?0:1}' "$H/autosites.tsv" 2>/dev/null; }

autosite_state() { # 加到哪一种: 有自动线路用自动线路, 否则固定出口
  if [ -n "$(srv_list | awk -F'\t' '$5=="auto" {print "x"; exit}')" ]; then echo auto; else echo pin; fi
}

# 添加一个网站 (先加覆盖 -> 用代理访问验证 -> 通了保留, 不通撤销); 0 = 已添加  1 = 没通过验证 (已撤销)  2 = 其它原因没添加
autosite_add() { # <域名> <失败数> <尝试数> <失败类型> <应用> <示例主机> <出口名>
  local d=$1 nf=$2 na=$3 ec=$4 app=$5 host=$6 tg=$7 st code out ms
  ovr_valid site "$d" || return 2
  st=$(autosite_state)
  if [ "${NETWORK_MODE:-system}" = tun ]; then
    op_txn "自动识别: 添加网站到代理" txn_override site "$d" "$st" '' >/dev/null 2>&1 || return 2
  else
    lock_take || return 2
    ovr_set site "$d" "$st" ack ''; ovr_sync; lock_drop
  fi
  sleep 2                                                                       # 规则集是文件监视热加载, 等它生效
  out=$(curl -s -o /dev/null -m 8 --connect-timeout 6 -x "http://127.0.0.1:$PORT" -w 'ENANA:%{http_code}:%{time_total}' "${ENANA_AUTOSITE_VERIFY_URL:-https://${host:-$d}/}" 2>/dev/null || true)       # (ENANA_AUTOSITE_VERIFY_URL: 只给测试用, 让验证不去连真实的互联网)
  code=${out#ENANA:}; code=${code%%:*}
  case $code in
    000|'') ;;                                                                  # 没有任何响应 (超时 / 被重置 / 代理也连不上)
    *) ms=$(printf '%s' "${out##*:}" | awk '{printf "%d", $1 * 1000}')
       printf '%s|%s|%s|%s|%s\n' "$d" "$(now)" "$ec" "$nf" "$app" >> "$H/autosites.tsv"; chmod 600 "$H/autosites.tsv" 2>/dev/null || true
       oplog auto "自动识别: 添加网站到代理" "$(kv domain "$d" state "$st" fails "$nf" attempts "$na" err "$ec" app "$app" was "$tg" verify "http=$code ${ms}ms")" ok
       return 0 ;;
  esac
  if [ "${NETWORK_MODE:-system}" = tun ]; then
    op_txn "自动识别: 撤销网站" txn_override site "$d" follow '' >/dev/null 2>&1 || return 2
  else lock_take && { ovr_delete site "$d"; ovr_sync; lock_drop; }; fi
  printf '%s %s\n' "$d" "$(now)" >> "$H/.autosite.cool"
  oplog auto "自动识别: 放弃网站" "$(kv domain "$d" fails "$nf" attempts "$na" err "$ec" app "$app" was "$tg" verify "no response through proxy")" error
  return 1
}

autosite_tick() { # 由 enana tick 每分钟调用一次 (必须排在 logs_tick 之前: 日志切分会清空实时日志)
  local log="$H/sing-box.log" ino sz off=0 oino='' T now n added=0 hour_cnt cool
  autosite_ready || { rm -f "$H/.autosite.off" "$H/.autosite.ev"; return 0; }
  [ -s "$log" ] || return 0
  ino=$(stat -f %i "$log"); sz=$(stat -f %z "$log"); now=$(now)
  if [ -f "$H/.autosite.off" ]; then read -r oino off < "$H/.autosite.off" || true; fi
  case ${off:-} in ''|*[!0-9]*) off=0 ;; esac
  [ "$oino" = "$ino" ] && [ "$off" -le "$sz" ] || off=0
  printf '%s %s\n' "$ino" "$sz" > "$H/.autosite.off"
  [ "$off" -eq 0 ] && [ ! -f "$H/.autosite.ev" ] && off=$sz          # 第一次: 从现在开始, 不翻历史
  T=$(mktemp -d)
  [ "$sz" -gt "$off" ] && tail -c +$((off + 1)) "$log" | head -c $((sz - off)) | _autosite_events "$now" >> "$H/.autosite.ev"
  touch "$H/.autosite.ev"
  LC_ALL=C awk -F'\t' -v c=$((now - AUTOSITE_WIN)) '$1 + 0 >= c' "$H/.autosite.ev" > "$T/ev" && cat "$T/ev" > "$H/.autosite.ev"        # 只留窗口内的
  # 不处理的域名: 目录里已有的服务 + 你已经有覆盖的网站 + 已经自动添加的 + 你删掉过的 + 24 小时内验证失败的
  { cat "$H/catalog.domains" 2>/dev/null; awk -F'|' '$1=="site" {print $2}' "$H/overrides.tsv" 2>/dev/null; cut -d'|' -f1 "$H/autosites.tsv" 2>/dev/null; cat "$H/autosites.dismissed" 2>/dev/null
    [ -f "$H/.autosite.cool" ] && awk -v c=$((now - 86400)) '$2 + 0 >= c {print $1}' "$H/.autosite.cool"; } | awk 'NF' > "$T/skip"
  _autosite_candidates "$now" "$H/.autosite.ev" "$T/skip" > "$T/cand"
  if [ -s "$T/cand" ] && ! grep -qx OUTAGE "$T/cand"; then
    hour_cnt=$(awk -F'|' -v c=$((now - 3600)) '$2 + 0 >= c {n++} END{print n+0}' "$H/autosites.tsv" 2>/dev/null)
    n=$(cat "$H/autosites.tsv" 2>/dev/null | wc -l | tr -d ' ')
    while IFS=$'\t' read -r d nf na ec app host tg; do
      [ "${hour_cnt:-0}" -lt "$AUTOSITE_PER_HOUR" ] && [ "${n:-0}" -lt "$AUTOSITE_MAX" ] && [ "$added" -lt 2 ] || break
      if autosite_add "$d" "$nf" "$na" "$ec" "$app" "$host" "$tg"; then hour_cnt=$((hour_cnt + 1)); n=$((n + 1)); fi
      added=$((added + 1))
    done < "$T/cand"
  fi
  rm -rf "$T"
  return 0
}

autosite_remove_all() { # 把自动添加的网站全部撤销 (设置里的「全部撤销」); 打印撤销的数量
  local d n=0
  [ -s "$H/autosites.tsv" ] || { echo 0; return 0; }
  lock_take || { echo 0; return 1; }
  while IFS='|' read -r d _; do [ -n "$d" ] || continue; ovr_delete site "$d"; autosite_forget "$d" dismiss; n=$((n + 1)); done < "$H/autosites.tsv"
  ovr_sync; lock_drop
  echo "$n"
}
autosite_count() { awk -F'|' 'NF {n++} END{print n+0}' "$H/autosites.tsv" 2>/dev/null; }
