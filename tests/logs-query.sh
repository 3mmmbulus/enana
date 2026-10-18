#!/bin/bash
# 日志页的读取 (2.3.27): 新的查询 (lib/logs.sh: grep / tail, 网站访问只读最后一段) 和 2.3.26 的实现 (tests/fixtures/logs-2.3.26, 逐字复制) 对比
#   P. 代理日志: 各种搜索词 (大小写 / 反斜杠转义 / 制表符 / 不可能出现的词) × 筛选 × 分页, 颜色控制符, 压缩文件 + 没有以换行结尾的文件, 核心日志关闭, 实时日志跨两天 —— 逐字节相同
#   A. 网站访问: 读得到整天时逐字节相同 (搜索预选 / 不能预选的词 / 筛选 / 分页); 大的一天只读最后一段: partial:true, 这一页和读整天时的这一页相同,
#      不够这一页就放大 (行数估计 / 读到的密度), 窗口开头只读到后半截的连接不显示; 默认的 4 MB 窗口
#   D. 日期列表只看实时日志的第一条和最后一条带时间的行 (不整份扫描)      T. tick.log 超过 1 MB 只留最后 2000 行 (logs_maintain)
# 不需要 sing-box / 网络 / 管理员权限; macOS (bash 3.2 + BSD 工具) 和 Windows (Git Bash + GNU 工具) 的 CI 都跑。用法: bash tests/logs-query.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P); REPO=$(dirname "$HERE")
W=$(mktemp -d "${TMPDIR:-/tmp}/enana-logsq.XXXXXX"); W=$(cd "$W" && pwd -P); trap 'rm -rf "$W"' EXIT
export LC_ALL=C HOME="$W/home" ENANA_HOME="$W/h" ENANA_TEST=1 ENANA_LANG=zh
unset ENANA_LOGS_WINDOW LOG_CORE
mkdir -p "$HOME" "$ENANA_HOME/logs"
. "$REPO/lib/common.sh"; init_paths "$REPO/install.sh"
LIB=$REPO/lib; DATA=$REPO/data
. "$LIB/servers.sh"; . "$LIB/logs.sh"
[ "$H" = "$W/h" ] || { echo "REFUSING: 数据目录不是临时目录 ($H)"; exit 1; }
OLD=$HERE/fixtures/logs-2.3.26
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [ -n "${2:-}" ] && printf '      ↳ %s\n' "$(printf '%s' "$2" | head -c 1200)"; return 0; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "期望 [$3] 实际 [$2]"; fi; }
filesame() { if command -v cmp >/dev/null 2>&1; then cmp -s "$1" "$2"; else [ "$(cat "$1"; echo .)" = "$(cat "$2"; echo .)" ]; fi; }
old_q() { ( . "$OLD/logs-query.sh"; LIB=$OLD; logs_query "$@" ); }          # 2.3.26 的实现 (子 shell 里覆盖同名函数, access.awk 也用旧的)
old_days() { ( . "$OLD/logs-query.sh"; logs_days ); }
q2() { old_q "$@" > "$W/old.json" 2>/dev/null; logs_query "$@" > "$W/new.json" 2>/dev/null; }
same() { # <说明> <logs_query 的参数…>: 新旧输出逐字节相同
  local d=$1; shift; q2 "$@"
  if [ -s "$W/new.json" ] && filesame "$W/old.json" "$W/new.json"; then ok "$d"; else bad "$d" "旧: $(head -c 500 "$W/old.json") | 新: $(head -c 500 "$W/new.json")"; fi
}
rowsof() { sed 's/.*"rows":[[]\(.*\)[]],"summary".*/\1/' "$1"; }                      # 只取 rows 数组
num() { sed -n "s/.*\"$1\":\([0-9][0-9]*\).*/\1/p" "$2" | head -n 1; }             # 第一个 "键":数字
has_partial() { grep -q '"partial":true,' "$1"; }
page_same() { # <说明> <参数…>: 只读了一部分 (partial) 时, 这一页和 2.3.26 读完整天的这一页相同, total 不超过整天的; 读了整天时整个输出逐字节相同
  local d=$1; shift; q2 "$@"
  if has_partial "$W/new.json"; then
    if [ "$(rowsof "$W/new.json")" = "$(rowsof "$W/old.json")" ] && [ "$(num total "$W/new.json")" -le "$(num total "$W/old.json")" ]; then ok "$d (partial)"; else bad "$d (partial)" "旧: $(head -c 500 "$W/old.json") | 新: $(head -c 500 "$W/new.json")"; fi
  elif filesame "$W/old.json" "$W/new.json"; then ok "$d (整天)"
  else bad "$d" "旧: $(head -c 500 "$W/old.json") | 新: $(head -c 500 "$W/new.json")"; fi
}
L() { printf '+0800 %s %s %s [%s %s] %s\n' "$1" "$2" "$3" "$4" "$5" "$6"; }      # L 日期 时间 级别 编号 耗时 消息
printf '%s\n' '{"role":"pin","outbound":{"type":"socks","tag":"Fix-Pin","server":"127.0.0.1","server_port":1}}' '{"role":"auto","outbound":{"type":"http","tag":"Local-Hop","server":"127.0.0.2","server_port":2}}' > "$H/servers.jsonl"

echo "== P. 代理日志: 和 2.3.26 逐字节相同"
D1=2026-10-03
{
  printf '%s\n' "+0800 $D1 08:00:00 INFO router: updated rule-set geoip-cn"
  L $D1 08:00:01 INFO 101 0ms 'inbound/mixed[in]: inbound connection to www.Google.com:443'
  L $D1 08:00:01 INFO 101 1ms 'router: found process path: /Applications/Google Chrome.app/Contents/MacOS/Google Chrome, user: fa'
  L $D1 08:00:01 INFO 101 2ms 'outbound/trojan[JP [1] node]: outbound connection to www.google.com:443'
  L $D1 08:00:02 WARN 102 5.0s 'connection: open connection to x.example:443 using outbound/direct[direct]: dial tcp 1.2.3.4:443: i/o timeout'
  printf '+0800 %s 08:00:03 WARNING odd "quoted" \\backslash\\ x\ty 100%% done\n' "$D1"
  L $D1 08:00:04 ERROR 103 10s 'connection: open connection to y.example:443 using outbound/socks[Fix-Pin]: dial tcp 127.0.0.1:1: connect: connection refused'
  printf '%s\n' 'goroutine 1 [running]:'; printf '\t%s\n' '/path/file.go:123 +0x1d'; printf '\n'
  printf '%s\n' "+0800 $D1 08:00:05 FATAL core crashed C:\\Program Files\\enana\\x.exe"
  printf '%s\n' "+0800 $D1 08:00:06 PANIC boom" "+0800 $D1 08:00:07 DEBUG [104 0ms] dns: exchange ok" "+0800 $D1 08:00:08 TRACE detail"
  printf '%s\n' "+0800 $D1 08:00:09 ERRORX not an error token" "+0800 $D1 08:00:10 ERROR" "-0500 $D1 08:00:11 INFO negative tz line" "WARN not a header line"
  LC_ALL=C awk -v d="$D1" 'BEGIN { for (i = 0; i < 240; i++) { s = 9 * 3600 + i * 7; lv = (i % 17 == 3) ? "WARN" : (i % 29 == 5) ? "ERROR" : "INFO"
    printf "+0800 %s %02d:%02d:%02d %s [%d %dms] inbound/mixed[in]: inbound connection to host%d.Example.com:443\n", d, int(s / 3600), int(s % 3600 / 60), s % 60, lv, 7000 + i, i % 9, i % 13 } }'
} > "$LOGS/proxy-$D1.log"
{ printf 'enana: core start %s 22:59:00\n' "$D1"
  L $D1 23:00:01 INFO 201 0ms 'inbound/mixed[in]: inbound connection to live.example:443'
  L $D1 23:00:02 ERROR 201 3ms 'connection: open connection to live.example:443 using outbound/direct[direct-cn]: dial tcp 9.9.9.9:443: connection reset by peer'
  printf '%s\n' 'panic: something happened in the live log'
  printf '+0800 %s 23:00:03 INFO last live line without a newline' "$D1"; } > "$H/sing-box.log"
for qq in '' google GOOGLE 'Chrome' 'connection to' 1.2.3.4 'C:\Program' '\\backslash' 'x\ty' '100%' '"quoted"' '[1] node' '\101' 'abc\n' '\0' zzz-no-such; do
  same "q=[$qq]" proxy $D1 "$qq" 500 0 ''
done
for qq in '' google 'C:\Program' '\0' zzz-no-such; do for f in warn error; do same "q=[$qq] f=$f" proxy $D1 "$qq" 500 0 $f; done; done
same "筛选值 direct 对代理日志不起作用" proxy $D1 '' 500 0 direct
for lo in '5 0' '5 3' '3 7' '0 0' '10 100000' '99999999999999999999 0' '5 0007' '7 99999999999999999999' '2000 0' '0050 5'; do
  set -- $lo; same "分页 limit=$1 offset=$2" proxy $D1 '' "$1" "$2" ''
done
for lo in '5 0' '3 7' '10 100000' '99999999999999999999 0'; do set -- $lo; same "分页 limit=$1 offset=$2 (警告)" proxy $D1 '' "$1" "$2" warn; done
same "搜索 + 分页 (从已切分的文件里取, 跨到实时日志那一段)" proxy $D1 example 20 5 ''
D2=2026-10-04
{ printf '+0800 %s 10:00:00 \033[36mINFO\033[0m [301 0ms] inbound/mixed[in]: inbound connection to color.example:443\n' "$D2"
  printf '+0800 %s 10:00:01 \033[33mWARN\033[0m [302 1ms] something warned\n' "$D2"
  printf '+0800 %s 10:00:02 \033[31mERROR\033[0m [303 2ms] connection: open connection to bad.example:443 using outbound/direct[direct]: dial tcp 1.1.1.1:443: i/o timeout\n' "$D2"
  printf '+0800 %s 10:00:03 INFO plain line 36m\n' "$D2"; } > "$LOGS/proxy-$D2.log"
for f in '' warn error; do same "颜色控制符 (先去掉再比较): f=[$f]" proxy $D2 '' 500 0 "$f"; done
for qq in info 36m '[0m' color; do same "颜色控制符: q=[$qq]" proxy $D2 "$qq" 500 0 ''; done
D3=2026-10-05
{ L $D3 07:00:00 INFO 401 0ms 'inbound/mixed[in]: inbound connection to gz.example:443'; L $D3 07:00:01 WARN 401 1ms 'from the compressed file'; } | gzip -c > "$LOGS/proxy-$D3.log.gz"
{ L $D3 08:00:00 INFO 402 0ms 'inbound/mixed[in]: inbound connection to plain.example:443'; printf '+0800 %s 08:00:01 ERROR half a line' "$D3"; } > "$LOGS/proxy-$D3.log"
for f in '' warn error; do same "压缩文件 + 没有以换行结尾的文件 (两段连成一行): f=[$f]" proxy $D3 '' 500 0 "$f"; done
same "…搜索连成一行的那一行" proxy $D3 'half a line+0800' 500 0 ''
same "…搜索 + 筛选" proxy $D3 example 500 0 error
same "…分页" proxy $D3 '' 1 1 ''
cp "$H/sing-box.log" "$W/live1"
{ cat "$W/live1"; printf '\n'; L $D1 23:30:00 INFO 0 0ms x; printf '%s\n' "+0800 $D1 23:30:01 INFO router: not a connection line"; L $D1 23:30:02 WARN 205 1ms 'inbound/mixed[in]: inbound connection to core-off.example:443'; } > "$H/sing-box.log"
for f in '' warn; do LOG_CORE=0; export LOG_CORE; same "核心日志关闭: 实时日志只留连接行 f=[$f]" proxy $D1 '' 500 0 "$f"; same "核心日志关闭: 网站访问 f=[$f]" access $D1 '' 500 0 "$f"; unset LOG_CORE; done
{ cat "$W/live1"; printf '\n'; L $D1 23:59:59 INFO 210 0ms 'inbound/mixed[in]: inbound connection to before-midnight.example:443'
  printf '%s\n' '- a continuation line that starts with a dash'
  L $D2 00:00:01 INFO 211 0ms 'inbound/mixed[in]: inbound connection to after-midnight.example:443'; printf '%s\n' 'continuation after midnight'; } > "$H/sing-box.log"
for d in $D1 $D2; do for f in '' error; do same "实时日志跨两天 (逐行判断那一段): $d f=[$f]" proxy $d '' 500 0 "$f"; done; same "实时日志跨两天: 网站访问 $d" access $d '' 500 0 ''; done
eq "实时日志跨两天: 日期列表和 2.3.26 相同" "$(logs_days | paste -sd, -)" "$(old_days | paste -sd, -)"
cp "$W/live1" "$H/sing-box.log"
same "没有任何记录的一天" proxy 2026-09-01 '' 500 0 ''
same "没有任何记录的一天 (网站访问)" access 2026-09-01 x 500 0 error
printf '%s\tdashboard\t登录\tuser=a@b.c\tok\n%s\tauto\t发现新应用\tcount=1\terror\n' "$D1 09:00:00" "$D1 09:01:00" > "$LOGS/ops-$D1.log"
same "操作记录 (代码没变, 日期列表来自新的 logs_days)" ops $D1 '' 500 0 ''
same "操作记录: 搜索 + 筛选" ops $D1 登录 500 0 error

echo "== A. 网站访问: 读到整天时逐字节相同"
D5=2026-10-07
{
  L $D5 22:34:01 INFO 1001 0ms 'inbound/mixed[in]: inbound connection to chatgpt.com:443'
  L $D5 22:34:01 INFO 1001 0ms 'router: found process path: /Applications/Google Chrome.app/Contents/MacOS/Google Chrome, user: fa'
  L $D5 22:34:01 INFO 1001 3ms 'dns: lookup succeed for chatgpt.com: 104.18.32.47 172.64.155.209'
  L $D5 22:34:01 INFO 1001 3ms 'outbound/direct[direct-app]: outbound connection to chatgpt.com:443'
  L $D5 22:34:02 INFO 1002 0ms 'inbound/mixed[in]: inbound connection to www.example.org:443'
  L $D5 22:34:02 INFO 1002 0ms 'router: found process path: /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper, user: fa'
  L $D5 22:34:02 INFO 1002 4ms 'outbound/socks[Fix-Pin]: outbound connection to www.example.org:443'
  L $D5 22:34:03 INFO 1003 0ms 'inbound/tun[tun-in]: inbound connection to api.example.net:443'
  L $D5 22:34:03 INFO 1003 0ms 'router: found process path: /usr/bin/curl, user: root'
  L $D5 22:34:03 INFO 1003 1ms 'outbound/direct[direct-mode]: outbound connection to api.example.net:443'
  L $D5 22:34:04 INFO 1004 0ms 'inbound/mixed[in]: inbound connection to 192.168.1.1:80'
  L $D5 22:34:04 INFO 1004 0ms 'outbound/direct[direct-lan]: outbound connection to 192.168.1.1:80'
  L $D5 22:34:05 INFO 1006 0ms 'inbound/mixed[in]: inbound connection to blocked.example:443'
  L $D5 22:34:05 INFO 1006 0ms 'router: found process path: /Applications/Telegram.app/Contents/MacOS/Telegram, user: fa'
  L $D5 22:34:05 INFO 1006 1ms 'outbound/socks[Fix-Pin]: outbound connection to blocked.example:443'
  L $D5 22:34:06 INFO 1012 0ms 'router: found process path: /Applications/Grok Bot.app/Contents/MacOS/Grok Bot, user: fa'
  L $D5 22:34:09 ERROR 1006 4s 'connection: open connection to blocked.example:443 using outbound/socks[Fix-Pin]: dial tcp 127.0.0.1:1: connect: connection refused'
  L $D5 22:34:11 INFO 1007 0ms 'inbound/mixed[in]: inbound connection to slow.example:443'
  L $D5 22:34:11 INFO 1007 1ms 'outbound/direct[direct]: outbound connection to slow.example:443'
  L $D5 22:34:21 ERROR 1007 10s 'connection: open connection to slow.example:443 using outbound/direct[direct]: dial tcp 10.9.8.7:443: i/o timeout'
  L $D5 22:34:22 INFO 1008 0ms 'inbound/mixed[in]: inbound packet connection to dns.example:53'
  L $D5 22:34:22 INFO 1008 0ms 'outbound/direct[direct-mode]: outbound packet connection to dns.example:53'
  L $D5 22:34:23 INFO 1009 0ms 'inbound/mixed[in]: inbound connection to [2001:db8::1]:443'
  L $D5 22:34:23 INFO 1009 2ms 'outbound/http[Local-Hop]: outbound connection to [2001:db8::1]:443'
  L $D5 22:34:24 INFO 1010 0ms 'inbound/mixed[in]: inbound connection to tag.example:443'
  L $D5 22:34:24 INFO 1010 2ms 'outbound/vmess[JP [1] node]: outbound connection to tag.example:443'
  L $D5 22:34:25 INFO 1011 0ms 'inbound/mixed[in]: inbound connection to nxd.example:443'
  L $D5 22:34:25 ERROR 1011 0ms 'dns: lookup failed for nxd.example: dns: no such host'
  L $D5 22:34:26 WARN 1013 1ms 'connection: open connection to warned.example:443 using outbound/http[Local-Hop]: EOF'
  L $D5 22:34:27 INFO 1014 0ms 'inbound/mixed[in]: inbound connection to xchg.example:443'
  L $D5 22:34:27 ERROR 1014 1ms 'dns: exchange failed for xchg.example: timeout'
  L $D5 22:40:00 INFO 1001 0ms 'inbound/mixed[in]: inbound connection to reused-id.example:443'
  printf '%s\n' 'FATAL something without a header should be ignored'
} > "$LOGS/proxy-$D5.log"
for qq in '' chrome CHROME chatgpt.com fix-pin 104.18 app direct-app timeout policy 'google chrome' 'jp [1]' dns nomatch.example '\101' telegram 10.9.8.7; do
  same "q=[$qq]" access $D5 "$qq" 500 0 ''
done
for f in direct proxy error; do same "f=$f" access $D5 '' 500 0 $f; same "q=chrome f=$f" access $D5 chrome 500 0 $f; done
for lo in '2 1' '1 0' '2000 0' '5 99999999999999999999' '99999999999999999999 0' '0 0' '3 0004'; do set -- $lo; same "分页 limit=$1 offset=$2" access $D5 '' "$1" "$2" ''; done
same "带颜色控制符的一天 (不预选)" access $D2 '' 500 0 ''
same "带颜色控制符的一天: 搜索" access $D2 color 500 0 error

echo "== A. 网站访问: 大的一天只读最后一段 (测试里把窗口设成 4000 字节)"
gen_conns() { # <日期> <连接数> <起始秒>  每条连接 3 行 (inbound / router / outbound), 每 50 条有一条在 5 秒后失败; 第 3 / 500 条访问 rare.example
  LC_ALL=C awk -v d="$1" -v n="$2" -v s0="$3" '
    function hms(s) { return sprintf("%02d:%02d:%02d", int(s / 3600), int(s % 3600 / 60), s % 60) }
    function host(i) { return (i == 3 || i == 500) ? "rare.example" : "host" (i % 37) ".example" }
    BEGIN { split("direct[direct-cn] socks[Fix-Pin] http[Local-Hop] direct[direct]", R, " ")
      for (i = 0; i < n; i++) { t = hms(s0 + i); id = 50000 + i; app = "App" (i % 5)
        printf "+0800 %s %s INFO [%d 0ms] inbound/mixed[in]: inbound connection to %s:443\n", d, t, id, host(i)
        printf "+0800 %s %s INFO [%d 1ms] router: found process path: /Applications/%s.app/Contents/MacOS/%s, user: fa\n", d, t, id, app, app
        printf "+0800 %s %s INFO [%d 2ms] outbound/%s: outbound connection to %s:443\n", d, t, id, R[i % 4 + 1], host(i)
        j = i - 5; if (j >= 0 && j % 50 == 7) printf "+0800 %s %s ERROR [%d 5.0s] connection: open connection to %s:443 using outbound/%s: dial tcp 10.1.2.3:443: i/o timeout\n", d, t, 50000 + j, host(j), R[j % 4 + 1] } }'
}
D6=2026-10-08
gen_conns $D6 1000 43200 > "$LOGS/proxy-$D6.log"
ENANA_LOGS_WINDOW=4000; export ENANA_LOGS_WINDOW
q2 access $D6 '' 5 0 ''
t1=$(num total "$W/new.json"); a1=$(num all "$W/new.json")
if has_partial "$W/new.json" && [ "$(rowsof "$W/new.json")" = "$(rowsof "$W/old.json")" ] && [ "${t1:-0}" -ge 5 ] && [ "$t1" -lt 1000 ] && [ "$a1" = "$t1" ]; then ok "第 1 页: partial:true, 这一页和读整天时相同, total = 已经读到的条数 ($t1 < 1000), 汇总也只算读到的部分"
else bad "第 1 页: partial" "$(head -c 600 "$W/new.json")"; fi
page_same "第 2 页 (offset 5)" access $D6 '' 5 5 ''
page_same "要的比窗口里的多: 放大窗口 (limit 50 offset 40)" access $D6 '' 50 40 ''
page_same "筛选 直连 (常见)" access $D6 '' 5 0 direct
page_same "筛选 代理" access $D6 '' 5 0 proxy
page_same "筛选 失败 (少: 先按失败行数放大, 再读)" access $D6 '' 5 0 error
page_same "搜索 app3 (预选连接编号)" access $D6 app3 5 0 ''
page_same "搜索 timeout (失败类型是推算的: 不预选, 按读到的密度放大)" access $D6 timeout 5 0 ''
same "搜索 rare (整天只有 2 条): 读完整天, 和 2.3.26 相同" access $D6 rare 5 0 ''
same "整天只有 20 条失败, 要 50 条: 读完整天" access $D6 '' 50 0 error
same "limit 2000: 窗口放大到整天, 和 2.3.26 相同 (没有 partial)" access $D6 '' 2000 0 ''
same "offset 很大: 直接读整天" access $D6 '' 5 99999999999999999999 ''
same "搜索不可能出现的词 (\\101 = 大写 A): 一条也没有" access $D6 '\101' 5 0 ''
eq "partial 只出现在网站访问 (代理日志总是读整天)" "$(logs_query proxy $D6 '' 5 0 '' | grep -c '"partial"')" "0"
same "代理日志: 窗口设置不影响结果" proxy $D6 app3 5 0 ''

echo "== A. 窗口开头只读到后半截的连接不显示"
D7=2026-10-09
{ L $D7 10:00:00 INFO 9001 0ms 'inbound/mixed[in]: inbound connection to straddle.example:443'
  L $D7 10:00:00 INFO 9001 1ms 'router: found process path: /usr/bin/curl, user: root'; } > "$W/head7"
{ L $D7 10:00:01 INFO 9002 0ms 'inbound/mixed[in]: inbound connection to a.example:443'
  L $D7 10:00:01 INFO 9001 1.2s 'outbound/direct[direct]: outbound connection to straddle.example:443'
  L $D7 10:00:01 INFO 9003 2ms 'router: found process path: /Applications/Late.app/Contents/MacOS/Late, user: fa'
  L $D7 10:00:02 INFO 9002 3ms 'outbound/direct[direct-cn]: outbound connection to a.example:443'
  L $D7 10:00:03 INFO 9004 0ms 'router: found process path: /Applications/Grok Bot.app/Contents/MacOS/Grok Bot, user: fa'
  L $D7 10:00:04 INFO 9005 0ms 'inbound/mixed[in]: inbound connection to b.example:443'
  L $D7 10:00:06 ERROR 9001 6.0s 'connection: open connection to straddle.example:443 using outbound/direct[direct]: dial tcp 10.0.0.1:443: i/o timeout'
  L $D7 10:00:07 INFO 9005 1ms 'outbound/socks[Fix-Pin]: outbound connection to b.example:443'
  L $D7 10:00:08 INFO 9006 0ms 'inbound/mixed[in]: inbound connection to c.example:443'
  L $D7 10:00:08 INFO 9006 1ms 'outbound/direct[direct]: outbound connection to c.example:443'; } > "$W/tail7"
cat "$W/head7" "$W/tail7" > "$LOGS/proxy-$D7.log"
ENANA_LOGS_WINDOW=$(wc -c < "$W/tail7" | tr -d ' ')
logs_query access $D7 '' 4 0 '' > "$W/new.json"
eq "窗口正好从 inbound 行之后开始: 只读到后半截的 9001、开头那一秒里不是从 inbound 开始的 9003 都不显示; 9004 (只有 router 行, 在那之后) 照常显示" \
  "$(has_partial "$W/new.json" && echo partial):$(grep -o '"id":"[0-9]*"' "$W/new.json" | cut -d'"' -f4 | paste -sd, -):$(num all "$W/new.json")" "partial:9006,9005,9004,9002:4"
same "读整天时 9001 完整 (和 2.3.26 相同)" access $D7 '' 2000 0 ''
logs_query access $D7 straddle 1 0 '' > "$W/new.json"
eq "预选连接编号时也一样 (搜索 straddle: 窗口里只有它的后半截, 不算; 放大到整天后才完整地出现)" "$(grep -c '"partial"' "$W/new.json"):$(grep -o '"id":"[0-9]*"' "$W/new.json" | cut -d'"' -f4 | paste -sd, -):$(num total "$W/new.json")" "0:9001:1"
logs_query access $D7 '' 1 0 '' > "$W/new.json"
eq "只要 1 条: 窗口里的就够了 (partial)" "$(has_partial "$W/new.json" && echo partial):$(grep -o '"id":"[0-9]*"' "$W/new.json" | cut -d'"' -f4 | paste -sd, -)" "partial:9006"
unset ENANA_LOGS_WINDOW

echo "== A. 默认窗口 (4 MB): 5 MB 的一天"
D9=2026-10-11
gen_conns $D9 15000 3600 > "$LOGS/proxy-$D9.log"
sz=$(wc -c < "$LOGS/proxy-$D9.log" | tr -d ' ')
[ "$sz" -gt 4194304 ] && ok "夹具超过 4 MB ($sz 字节)" || bad "夹具超过 4 MB" "$sz"
q2 access $D9 '' 50 0 ''
if has_partial "$W/new.json" && [ "$(rowsof "$W/new.json")" = "$(rowsof "$W/old.json")" ] && [ "$(num total "$W/new.json")" -lt 15000 ]; then ok "第 1 页只读最后 4 MB: partial:true, 这一页和读整天时相同"
else bad "第 1 页只读最后 4 MB" "$(head -c 600 "$W/new.json")"; fi
same "代理日志第 1 页 (grep / tail)" proxy $D9 '' 50 0 ''
same "代理日志搜索 + 第 3 页" proxy $D9 app3 50 100 ''
same "代理日志 警告和错误" proxy $D9 '' 50 0 warn

echo "== D. 日期列表"
eq "实时日志按时间顺序 (只有一天): 和 2.3.26 相同" "$(logs_days | paste -sd, -)" "$(old_days | paste -sd, -)"
{ L 2026-10-12 08:00:00 INFO 1 0ms a; L 2026-10-06 08:00:01 INFO 2 0ms 'the clock jumped back'; L 2026-10-12 08:00:02 INFO 3 0ms b; } > "$H/sing-box.log"
eq "只看实时日志的第一条和最后一条带时间的行 (不整份扫描): 中间的 10-06 不读" "$(logs_days | grep -c '^2026-10-06$'):$(logs_days | grep -c '^2026-10-12$')" "0:1"
eq "…2.3.26 整份扫描, 会读到中间的 10-06 (行为变化是有意的)" "$(old_days | grep -c '^2026-10-06$')" "1"
{ L 2026-09-20 23:00:00 INFO 1 0ms a; L 2026-09-21 12:00:00 INFO 2 0ms b; L 2026-09-22 01:00:00 INFO 3 0ms c; } > "$H/sing-box.log"
eq "首尾隔了不止一天 (切分没有在运行): 和 2.3.26 一样整份扫描, 中间的 09-21 也在" "$(logs_days | grep -c '^2026-09-21$'):$(logs_days | paste -sd, -)" "1:$(old_days | paste -sd, -)"
{ L 2026-02-28 23:59:00 INFO 1 0ms a; L 2026-03-01 00:01:00 INFO 2 0ms b; } > "$H/sing-box.log"
eq "首尾是相邻的两天 (跨月): 不整份扫描, 和 2.3.26 相同" "$(logs_days | paste -sd, -)" "$(old_days | paste -sd, -)"
{ L 2026-02-28 23:59:00 INFO 1 0ms a; L 2026-02-29 12:00:00 INFO 2 0ms 'not a real date in 2026'; L 2026-03-02 00:01:00 INFO 3 0ms b; } > "$H/sing-box.log"
eq "首尾隔了两天: 整份扫描 (和 2.3.26 相同)" "$(logs_days | grep -c '^2026-02-29$'):$(logs_days | paste -sd, -)" "1:$(old_days | paste -sd, -)"
{ printf 'enana: core start\n'; L 2026-10-13 09:00:00 INFO 1 0ms a; LC_ALL=C awk 'BEGIN { for (i = 0; i < 300; i++) printf "\tstack frame %d\n", i }'; } > "$H/sing-box.log"
eq "最后 300 行都没有时间 (往前多读一些才找到): 日期照样有" "$(logs_days | grep -c '^2026-10-13$'):$(logs_days | paste -sd, -)" "1:$(old_days | paste -sd, -)"
printf 'no timestamps at all\n' > "$H/sing-box.log"
eq "实时日志里没有带时间的行: 只有文件给出的日期 (和 2.3.26 相同)" "$(logs_days | paste -sd, -)" "$(old_days | paste -sd, -)"
: > "$H/sing-box.log"
eq "实时日志是空的" "$(logs_days | paste -sd, -)" "$(old_days | paste -sd, -)"

echo "== T. tick.log"
LC_ALL=C awk 'BEGIN { for (i = 1; i <= 30000; i++) printf "tick line %06d ....................................\n", i }' > "$H/tick.log"
logs_trim_tick
eq "超过 1 MB: 只留最后 2000 行" "$(wc -l < "$H/tick.log" | tr -d ' '):$(head -n 1 "$H/tick.log" | cut -c1-16):$(tail -n 1 "$H/tick.log" | cut -c1-16)" "2000:tick line 028001:tick line 030000"
c0=$(cksum < "$H/tick.log"); logs_trim_tick
eq "不到 1 MB: 不动" "$(cksum < "$H/tick.log")" "$c0"
LC_ALL=C awk 'BEGIN { for (i = 1; i <= 30000; i++) printf "again %06d ........................................\n", i }' > "$H/tick.log"
( logs_rotate() { :; }; logs_rotate_api() { :; }; logs_compress() { :; }; logs_purge() { :; }; logs_maintain )
eq "每小时的维护 (logs_maintain) 会修剪 tick.log" "$(wc -l < "$H/tick.log" | tr -d ' '):$(tail -n 1 "$H/tick.log" | cut -c1-12)" "2000:again 030000"

echo
echo "日志读取: $PASS 通过, $FAIL 失败"
[ "$FAIL" = 0 ]
