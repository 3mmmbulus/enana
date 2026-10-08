#!/bin/bash
# 单元测试 (几秒钟; 不需要 sing-box / 网络 / 管理员权限): 直接加载 lib/*.sh, 在临时目录里验证
#   访问记录解析 (access.awk) · 自动识别的事件与候选 · 日志保留 (小时) · 三个日志开关 · 应用扫描与覆盖层 · 规则集拆分 · 诊断导出的格式与脱敏
# 用法: bash tests/units.sh        (tests/run.sh 最后也会调用它)
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P); REPO=$(dirname "$HERE")
UW=$(mktemp -d /tmp/enana-unit.XXXXXX); UW=$(cd "$UW" && pwd -P); trap 'rm -rf "$UW"' EXIT; : > "$UW/.pass"; : > "$UW/.fail"
tpass()   { echo p >> "$UW/.pass"; echo "  ✓ $1"; }              # 计数写文件: chk 常在管道的子 shell 里运行
tfail()  { echo f >> "$UW/.fail"; echo "  ✗ $1"; [ -n "${2:-}" ] && printf '      ↳ %s\n' "$(printf '%s' "$2" | head -c 600)"; return 0; }
t()    { local d=$1; shift; local out; if out=$("$@" 2>&1); then tpass "$d"; else tfail "$d" "$out"; fi; }
py()   { python3 -c 'import sys,json; d=json.load(sys.stdin); '"$1"; }
chk()  { local d=$1 code=$2 in; in=$(cat); if out=$(printf '%s' "$in" | py "$code" 2>&1); then tpass "$d"; else tfail "$d" "$out | $in"; fi; }
eq()   { if [ "$2" = "$3" ]; then tpass "$1"; else tfail "$1" "期望 [$3] 实际 [$2]"; fi; }

export HOME=$UW/home ENANA_HOME=$UW/h LC_ALL=C ENANA_LANG=zh ENANA_NO_MDFIND=1 ENANA_APPS_ROOTS="$UW/home/Applications" ENANA_SKIP_PROBE=1
export PORT=39700 UI_PORT=39701 API_PORT=39702 SPEED_PORT=39703
mkdir -p "$UW/home/Applications" "$UW/h/rules" "$UW/h/logs"
. "$REPO/lib/common.sh"; init_paths "$REPO/install.sh"
LIB=$REPO/lib; DATA=$REPO/data
for _f in i18n jobs servers apps autosites sites fetch os-darwin enhanced auth device session cloud dns logs health update config ops speed stats prefs snapshot plan official sync vps; do . "$LIB/$_f.sh"; done
load_settings; QUIET=1
[ "$H" = "$UW/h" ] || { echo "REFUSING: 数据目录不是临时目录 ($H)"; exit 1; }

L() { printf '+0800 %s %s %s [%s %s] %s\n' "$1" "$2" "$3" "$4" "$5" "$6"; }      # L 日期 时间 级别 编号 耗时 消息

echo "== U1. 访问记录解析 (access.awk): 一条连接一行 · 路由 / 直连原因 / 应用 / 失败类型 / DNS 结果"
D=2026-10-02
{
  L $D 22:34:01 INFO 1001 0ms 'inbound/mixed[in]: inbound connection to chatgpt.com:443'
  L $D 22:34:01 INFO 1001 0ms 'router: found process path: /Applications/Google Chrome.app/Contents/MacOS/Google Chrome, user: fa'
  L $D 22:34:01 INFO 1001 3ms 'dns: lookup succeed for chatgpt.com: 104.18.32.47 172.64.155.209'
  L $D 22:34:01 INFO 1001 3ms 'outbound/direct[direct-app]: outbound connection to chatgpt.com:443'
  L $D 22:34:02 INFO 1002 0ms 'inbound/mixed[in]: inbound connection to www.example.org:443'
  L $D 22:34:02 INFO 1002 0ms 'router: found process path: /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper, user: fa'
  L $D 22:34:02 INFO 1002 4ms 'outbound/socks[Fix-Pin]: outbound connection to www.example.org:443'
  L $D 22:34:03 INFO 1003 0ms 'inbound/mixed[in]: inbound connection to api.example.net:443'
  L $D 22:34:03 INFO 1003 0ms 'router: found process path: /usr/bin/curl, user: root'
  L $D 22:34:03 INFO 1003 1ms 'outbound/direct[direct-mode]: outbound connection to api.example.net:443'
  L $D 22:34:04 INFO 1004 0ms 'inbound/mixed[in]: inbound connection to 192.168.1.1:80'
  L $D 22:34:04 INFO 1004 0ms 'outbound/direct[direct-lan]: outbound connection to 192.168.1.1:80'
  L $D 22:34:05 INFO 1005 0ms 'inbound/mixed[in]: inbound connection to www.baidu.com:443'
  L $D 22:34:05 INFO 1005 1ms 'outbound/direct[direct-cn]: outbound connection to www.baidu.com:443'
  L $D 22:34:06 INFO 1006 0ms 'inbound/mixed[in]: inbound connection to blocked.example:443'
  L $D 22:34:06 INFO 1006 0ms 'router: found process path: /Applications/Telegram.app/Contents/MacOS/Telegram, user: fa'
  L $D 22:34:06 INFO 1006 1ms 'outbound/socks[Fix-Pin]: outbound connection to blocked.example:443'
  L $D 22:34:10 ERROR 1006 4s 'connection: open connection to blocked.example:443 using outbound/socks[Fix-Pin]: dial tcp 127.0.0.1:1: connect: connection refused'
  L $D 22:34:11 INFO 1007 0ms 'inbound/mixed[in]: inbound connection to slow.example:443'
  L $D 22:34:11 INFO 1007 1ms 'outbound/direct[direct]: outbound connection to slow.example:443'
  L $D 22:34:21 ERROR 1007 10s 'connection: open connection to slow.example:443 using outbound/direct[direct]: dial tcp 10.9.8.7:443: i/o timeout'
  L $D 22:34:22 INFO 1008 0ms 'inbound/mixed[in]: inbound packet connection to dns.example:53'
  L $D 22:34:22 INFO 1008 0ms 'outbound/direct[direct-mode]: outbound packet connection to dns.example:53'
  L $D 22:34:23 INFO 1009 0ms 'inbound/mixed[in]: inbound connection to [2001:db8::1]:443'
  L $D 22:34:23 INFO 1009 2ms 'outbound/http[Local-Hop]: outbound connection to [2001:db8::1]:443'
  L $D 22:34:24 INFO 1010 0ms 'inbound/mixed[in]: inbound connection to tag.example:443'
  L $D 22:34:24 INFO 1010 2ms 'outbound/vmess[JP [1] node]: outbound connection to tag.example:443'
  L $D 22:34:25 INFO 1011 0ms 'inbound/mixed[in]: inbound connection to nxd.example:443'
  L $D 22:34:25 ERROR 1011 0ms 'dns: lookup failed for nxd.example: dns: no such host'
  printf '%s\n' 'FATAL something without a header should be ignored'
} > "$UW/proxy.log"
acc() { { printf '@@PINS\nFix-Pin\n@@AUTOS\nLocal-Hop\n@@LOG\n'; cat "$UW/proxy.log"; } | LC_ALL=C awk -f "$REPO/lib/access.awk" -v mode=json -v q="${Q:-}" -v f="${F:-}" -v lim=50 -v off=0 -v since="${SINCE:-}" -v mask=0; }
acc | chk "11 条连接按编号归并 (新→旧), 无头部的行被忽略" 'assert d["total"]==11 and [r["id"] for r in d["rows"]][:2]==["1011","1010"] and d["rows"][-1]["id"]=="1001"'
acc | chk "1001: Chrome → chatgpt.com, direct-app = 直连 (原因: 你把这个应用设成了关), 带解析出的地址" 'r={x["id"]:x for x in d["rows"]}["1001"]; assert (r["host"],r["port"],r["app"],r["route"],r["node"],r["reason"])==("chatgpt.com",443,"Google Chrome","direct","direct-app","app") and r["ips"].split()[0]=="104.18.32.47" and r["err"]==""'
acc | chk "1002: 浏览器的 Helper 子进程算在最外层的应用 (Google Chrome) 上; 固定出口 = 代理, 没有直连原因" 'r={x["id"]:x for x in d["rows"]}["1002"]; assert r["app"]=="Google Chrome" and r["route"]=="pin" and r["node"]=="Fix-Pin" and r["reason"]==""'
acc | chk "1003: 命令行工具按文件名归类 (curl); direct-mode = 总开关关闭 / 直连模式" 'r={x["id"]:x for x in d["rows"]}["1003"]; assert r["app"]=="curl" and r["reason"]=="mode" and r["route"]=="direct"'
acc | chk "1004 / 1005: direct-lan = 局域网, direct-cn = 国内规则" 'r={x["id"]:x for x in d["rows"]}; assert r["1004"]["reason"]=="lan" and r["1005"]["reason"]=="cn" and r["1004"]["host"]=="192.168.1.1"'
acc | chk "1006: 经过固定出口失败 → err=refused, 带原始错误和被拒绝的拨号地址" 'r={x["id"]:x for x in d["rows"]}["1006"]; assert r["route"]=="pin" and r["err"]=="refused" and "connection refused" in r["errmsg"] and r["app"]=="Telegram" and r["ips"]=="127.0.0.1"'
acc | chk "1007: 直连超时 → reason=policy (策略选了直连), err=timeout, 地址取自拨号失败" 'r={x["id"]:x for x in d["rows"]}["1007"]; assert r["route"]=="direct" and r["node"]=="direct" and r["reason"]=="policy" and r["err"]=="timeout" and r["ips"]=="10.9.8.7"'
acc | chk "1008: UDP (packet connection) → net=udp" 'r={x["id"]:x for x in d["rows"]}["1008"]; assert r["net"]=="udp" and r["port"]==53 and r["reason"]=="mode"'
acc | chk "1009: IPv6 地址 [2001:db8::1]:443 拆成主机和端口; 自动线路节点 → route=auto" 'r={x["id"]:x for x in d["rows"]}["1009"]; assert r["host"]=="2001:db8::1" and r["port"]==443 and r["route"]=="auto"'
acc | chk "1010: 节点名里带方括号 (JP [1] node) 能完整取出; 不在服务器列表里 → route=other (算代理)" 'r={x["id"]:x for x in d["rows"]}["1010"]; assert r["node"]=="JP [1] node" and r["route"]=="other"'
acc | chk "1011: DNS 解析失败 → err=dns, 没有出口 (route=none)" 'r={x["id"]:x for x in d["rows"]}["1011"]; assert r["err"]=="dns" and r["route"]=="none"'
acc | chk "概览: 全部 11 / 直连 6 / 代理 4 / 失败 3; 直连原因分布 app1 mode2 lan1 cn1 policy1" 's=d["summary"]; assert (s["all"],s["direct"],s["proxy"],s["pin"],s["auto"],s["error"])==(11,6,4,2,1,3) and s["reasons"]=={"app":1,"mode":2,"lan":1,"cn":1,"policy":1}'
acc | chk "概览: 失败最多的网站排行 (含失败类型 / 应用 / 出口)" 'f={x["host"]:x for x in d["summary"]["top_fail"]}; assert f["blocked.example"]["err"]=="refused" and f["blocked.example"]["app"]=="Telegram" and f["slow.example"]["err"]=="timeout"'
F=direct acc | chk "筛选 直连: 只剩直连的 6 条; 概览数字不随筛选变化 (按钮上的数字固定)" 'assert d["total"]==6 and all(r["route"]=="direct" for r in d["rows"]) and d["summary"]["all"]==11'
F=proxy acc | chk "筛选 代理: 4 条 (固定出口 / 自动线路 / 其它)" 'assert d["total"]==4 and all(r["route"] in ("pin","auto","other") for r in d["rows"])'
F=error acc | chk "筛选 失败: 3 条" 'assert d["total"]==3 and all(r["err"] for r in d["rows"])'
Q=chrome acc | chk "搜索: 按应用名 (chrome) 找到 2 条" 'assert d["total"]==2'
Q=chrome acc | chk "搜索不会把没有错误的连接变成「失败」(概览里失败 = 0)" 'assert d["summary"]["error"]==0 and d["summary"]["all"]==2'
F=error Q=chrome acc | chk "搜索 + 筛选失败: 没有结果" 'assert d["total"]==0'
Q=refused acc | chk "搜索: 按失败类型 (refused) 找到 1 条" 'assert d["total"]==1 and d["rows"][0]["id"]=="1006"'
Q=104.18 acc | chk "搜索: 按解析出的地址找到 1 条" 'assert d["total"]==1 and d["rows"][0]["id"]=="1001"'
SINCE="$D 22:34:10" acc | chk "起始时间: 只保留之后开始的连接" 'assert d["total"]==5 and d["rows"][-1]["id"]=="1007"'
{ printf '@@PINS\nFix-Pin\n@@AUTOS\n@@LOG\n'; cat "$UW/proxy.log"; } | LC_ALL=C awk -f "$REPO/lib/access.awk" -v mode=tsv -v q= -v f= -v lim=0 -v off=0 -v since= -v mask=1 > "$UW/acc.tsv"
eq "导出表格 (tsv): 表头列固定" "$(head -1 "$UW/acc.tsv")" "$(printf 'ts\tid\tnet\thost\tport\tapp\tuser\troute\tnode\treason\tresult\terr\tdur\tips\terrmsg\tpath\tcapture')"
eq "导出表格: 11 行数据 + 1 行表头, 每行 17 列" "$(awk -F'\t' 'NF==17 {n++} END{print n" "NR}' "$UW/acc.tsv")" "12 12"
t "导出表格打码: 用户名只剩 <user> (root 保留), 路径里的 /Users/<名字> 被替换" sh -c "! grep -q $'\tfa\t' '$UW/acc.tsv' && grep -q $'\troot\t' '$UW/acc.tsv'"

echo "== U2. 自动识别: 事件提取 · 候选判定 · 误报保护"
NOW=2000000000
E=$UW/ev.txt
{
  # 打不开的网站 stuck.io: 同一个应用 4 次直连 (direct-cn) 都超时 → 候选
  for i in 1 2 3 4; do
    L $D 10:00:0$i INFO 20$i 0ms 'router: found process path: /Applications/Safari.app/Contents/MacOS/Safari, user: fa'
    L $D 10:00:0$i INFO 20$i 1ms "outbound/direct[direct-cn]: outbound connection to cdn.stuck.io:443"
    L $D 10:00:1$i ERROR 20$i 9s "connection: open connection to cdn.stuck.io:443 using outbound/direct[direct-cn]: dial tcp 9.9.9.9:443: i/o timeout"
  done
  # 正常网站 fine.com: 10 次直连成功, 1 次失败 → 失败比例太低, 不算
  for i in 1 2 3 4 5 6 7 8 9 10; do L $D 10:01:$i INFO 30$i 0ms 'outbound/direct[direct]: outbound connection to www.fine.com:443'; done
  L $D 10:01:30 ERROR 3099 9s 'connection: open connection to www.fine.com:443 using outbound/direct[direct]: dial tcp 8.8.8.8:443: i/o timeout'
  # 用户明确设成直连的网站 / 应用: 不参与 (出口名 direct-site / direct-app)
  for i in 1 2 3 4; do L $D 10:02:0$i ERROR 40$i 9s 'connection: open connection to mine.io:443 using outbound/direct[direct-site]: dial tcp 7.7.7.7:443: i/o timeout'; done
  # 经过代理失败的 (不是直连): 不参与
  for i in 1 2 3 4; do L $D 10:03:0$i ERROR 50$i 9s 'connection: open connection to viaproxy.io:443 using outbound/socks[Fix-Pin]: dial tcp 127.0.0.1:1: connect: connection refused'; done
  # 共享托管域名 (github.io): 取完整主机名, 不把整个 github.io 加进去
  for i in 1 2 3; do L $D 10:04:0$i ERROR 60$i 9s "connection: open connection to user$i.github.io:443 using outbound/direct[direct]: dial tcp 5.5.5.5:443: connection reset by peer"; done
} | _autosite_events "$NOW" > "$E"
eq "事件: 只记录出口名 direct / direct-cn 的尝试 (A) 和失败 (F); direct-site / direct-app / 走代理的不记" "$(cut -f2 "$E" | sort | uniq -c | awk '{printf "%s%s ", $2, $1}')" "A14 F8 "
eq "事件: 带上应用 (从 router 行取) 和失败类型" "$(awk -F'\t' '$2=="F" && $4=="cdn.stuck.io" {print $6 "/" $7; exit}' "$E")" "timeout/Safari"
: > "$UW/skip"
_autosite_candidates "$NOW" "$E" "$UW/skip" > "$UW/cand"
eq "候选: 只有 stuck.io (4 次失败 / 4 次尝试, 取最后两段); 正常网站 (失败 1/11) 不算" "$(cut -f1 "$UW/cand" | sort | paste -sd, -)" "stuck.io"
eq "候选: github.io 这类共享托管域名按完整主机名 (每个子站点单独判断, 这里每个只失败 1 次, 不够)" "$(grep -c 'github.io' "$UW/cand")" "0"
printf 'stuck.io\n' > "$UW/skip"
eq "候选: 目录里已有 / 已经有覆盖 / 删除过的域名 (skip 文件) 不再候选" "$(_autosite_candidates "$NOW" "$E" "$UW/skip" | wc -l | tr -d ' ')" "0"
printf 'io\n' > "$UW/skip"
eq "候选: skip 文件里是上级域名时, 子域名也算已覆盖" "$(_autosite_candidates "$NOW" "$E" "$UW/skip" | wc -l | tr -d ' ')" "0"
: > "$UW/skip"
eq "候选: 超出统计窗口 (15 分钟) 的事件被忽略" "$(_autosite_candidates $((NOW + 3600)) "$E" "$UW/skip" | wc -l | tr -d ' ')" "0"
{ for i in 1 2 3 4 5 6 7 8 9; do L $D 11:00:0$i ERROR 7$i 9s "connection: open connection to h$i.big$i.io:443 using outbound/direct[direct]: dial tcp 4.4.4.4:443: i/o timeout"; done; } | _autosite_events "$NOW" > "$UW/ev2"
eq "断网保护: 几乎所有直连都在失败 (≥ 8 个, > 80%) → 整体判为断网 (OUTAGE), 不添加任何网站" "$(_autosite_candidates "$NOW" "$UW/ev2" "$UW/skip")" "OUTAGE"
eq "没有直连失败的日志 → 没有事件" "$(printf '%s\n' "$(L $D 10:00:00 INFO 1 0ms 'outbound/direct[direct]: outbound connection to a.com:443')" | _autosite_events "$NOW" | cut -f2 | paste -sd, -)" "A"

echo "== U3. 日志保留 (按小时) · 三个独立开关 · kv 格式"
eq "保留时长: 默认 72 小时 (3 天)" "$(unset LOG_HOURS; logs_hours)" "72"
eq "保留时长: 下限 12 小时 / 上限 720 小时 (30 天) / 乱写 → 默认" "$(LOG_HOURS=1 logs_hours),$(LOG_HOURS=99999 logs_hours),$(LOG_HOURS=abc logs_hours),$(LOG_HOURS=12 logs_hours),$(LOG_HOURS=720 logs_hours)" "12,720,72,12,720"
eq "kv: 空值省略, 带空格的值加引号, 引号和反斜杠转义, 制表符/换行换成空格" "$(kv a 1 b '' c 'x y' d 'q"z' e "$(printf 'p\tq')")" 'a=1 c="x y" d="q\"z" e="p q"'
# ---- 小时精度的清理: 构造 now-20h / now-5h / now-1h 三条记录 (12 小时保留 → 只留后两条)
T20=$(date -v-20H '+%F %T'); T5=$(date -v-5H '+%F %T'); T1=$(date -v-1H '+%F %T')
for ts in "$T20" "$T5" "$T1"; do printf '%s\tdashboard\t测试\tk=v\tok\n' "$ts" >> "$LOGS/ops-${ts%% *}.log"; done
OLDEST=$(date -v-5d +%F); printf '%s 00:00:00\tdashboard\t很旧\t\tok\n' "$OLDEST" > "$LOGS/ops-$OLDEST.log"
# Records belong in their own daily file even when the fixture spans midnight.
printf '+0800 %s INFO [1 0ms] inbound/mixed[in]: inbound connection to a.example:443\n' "$T20" >> "$LOGS/proxy-${T20%% *}.log"
printf '+0800 %s INFO [1 0ms] outbound/direct[direct]: outbound connection to a.example:443\n' "$T1" >> "$LOGS/proxy-${T1%% *}.log"
LOG_HOURS=12 logs_purge >/dev/null
all_ops=$(cat "$LOGS"/ops-*.log 2>/dev/null | cut -f1 | sort | paste -sd, -)
case $all_ops in *"$T20"*) tfail "12 小时保留: 20 小时前的操作记录被裁掉" "$all_ops" ;; *) tpass "12 小时保留: 20 小时前的操作记录被裁掉 (同一天里按小时裁剪)" ;; esac
case $all_ops in *"$T5"*"$T1"*) tpass "12 小时保留: 5 小时前和 1 小时前的记录保留" ;; *) tfail "12 小时保留: 5 小时前和 1 小时前的记录保留" "$all_ops" ;; esac
t "12 小时保留: 5 天前的整天文件被直接删除" test ! -e "$LOGS/ops-$OLDEST.log"
case $(cat "$LOGS"/proxy-*.log 2>/dev/null) in *"$T20 INFO"*) tfail "代理日志同样按小时裁剪 (20 小时前的行被去掉)" ;; *"$T1 INFO"*) tpass "代理日志同样按小时裁剪 (20 小时前的行被去掉, 1 小时前的保留)" ;; *) tfail "代理日志按小时裁剪" "$(cat "$LOGS"/proxy-*.log)" ;; esac
# ---- 切分: 核心日志关闭时只保留带连接编号的行
rm -f "$LOGS"/*; TS=$(date '+%F %T')
printf '+0800 %s INFO [5 0ms] inbound/mixed[in]: inbound connection to a.example:443\n+0800 %s INFO router: updated rule-set\n+0800 %s WARN [5 0ms] something\n' "$TS" "$TS" "$TS" > "$H/sing-box.log"
LOG_CORE=0 logs_rotate
eq "核心日志关闭: 切分时只留和连接有关的行 (带 [编号 耗时]), 其余核心事件丢掉" "$(cat "$LOGS"/proxy-*.log | wc -l | tr -d ' ')" "2"
eq "切分后实时日志被清空" "$(wc -c < "$H/sing-box.log" | tr -d ' ')" "0"
LOG_OPS=0 oplog dashboard "不应记录" "" ok; t "关闭「操作记录」后 oplog 不再写入" test ! -e "$LOGS/ops-$(date +%F).log"
LOG_OPS=0 oplog_force dashboard "修改设置" "setting=log_ops from=1 to=0" ok; t "但开关自己的变化用 oplog_force 照样留痕 (否则无法知道什么时候关的)" grep -q 'setting=log_ops' "$LOGS/ops-$(date +%F).log"

echo "== U4. 应用扫描: 子目录 · 浏览器 · 首次 / 之后 / 旧版升级 · 重新套用推荐"
APPS=$UW/home/Applications
mkapp() { local app="$1/$2.app"; mkdir -p "$app/Contents/MacOS"; printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>t.%s</string></dict></plist>' "${2// /-}" > "$app/Contents/Info.plist"; }
mkbrowser() { mkapp "$1" "$2"; plutil -insert CFBundleURLTypes -json '[{"CFBundleURLSchemes":["http","https"]}]' "$1/$2.app/Contents/Info.plist"; }
mkapp "$APPS" "Plain App"; mkapp "$APPS/Utilities" "Terminal"; mkbrowser "$APPS" "Odd Browser"; mkapp "$APPS" "ChatGPT"
mkdir -p "$APPS/Deep/A/B/C/D"; mkapp "$APPS/Deep/A/B/C" "Too Deep"                          # 5 层: 超出扫描深度 (不进目录树深处)
mkdir -p "$APPS/Plain App.app/Contents/Helpers"; mkapp "$APPS/Plain App.app/Contents/Helpers" "Inner Helper"    # 应用内部嵌的辅助程序不算
echo 'Terminal|follow|终端
Safari|follow|浏览器
ChatGPT|pin|AI' > "$UW/apps.conf"
content_file() { case $1 in apps.conf) echo "$UW/apps.conf" ;; *) echo "$DATA/$1" ;; esac; }
n=$(apps_scan)
eq "首次扫描: 识别到 4 个 (Utilities 子目录里的 Terminal 也在; 太深的和应用内部的辅助程序不算)" "$n:$(apps_installed | cut -f1 | paste -sd, -)" "4:ChatGPT,Odd Browser,Plain App,Terminal"
eq "首次扫描: 标记全是 def (不弹「新应用」), 新应用数 0" "$(awk -F'|' '$1=="app" {print $4}' "$H/overrides.tsv" | sort -u | paste -sd, -):$(apps_new_count)" "def:0"
eq "首次扫描: 已知应用按推荐 (ChatGPT=pin, Terminal=follow); 浏览器 (声明能打开 http/https) = follow; 其它 = direct" "$(awk -F'|' '$1=="app" {print $2 "=" $3}' "$H/overrides.tsv" | sort | paste -sd, -)" "ChatGPT=pin,Odd Browser=follow,Plain App=direct,Terminal=follow"
# ---- 之后新装的应用: 浏览器跟随 / 其它直连, 标记 new, 弹提示
mkapp "$APPS" "Later App"; mkbrowser "$APPS" "Later Browser"; mkapp "$APPS" "Terminal Two"
n=$(apps_scan)
eq "之后新装的 3 个应用: 标记 new, 新应用数 3 (发现新应用写进操作记录)" "$n:$(apps_new_count):$(grep -c '发现新应用' "$LOGS/ops-$(date +%F).log")" "3:3:1"
eq "之后新装: 浏览器默认跟随, 其它默认直连 (推荐表里没有 \"Terminal Two\")" "$(awk -F'|' '$4=="new" {print $2 "=" $3}' "$H/overrides.tsv" | sort | paste -sd, -)" "Later App=direct,Later Browser=follow,Terminal Two=direct"
eq "再扫描一次不会重复标记 / 重复记录" "$(apps_scan):$(apps_new_count)" "0:3"
apps_ack "Later App"; eq "确认单个应用 (访问「应用」页前先确认)" "$(apps_new_count)" "2"
apps_ack all; eq "全部确认后不再提示" "$(apps_new_count)" "0"
# ---- 2.1.0 留下的错误默认值: 新装的浏览器被设成了直连 (标记 new) → 升级后第一次扫描改回跟随; 你自己设置过的 (ack) 和非浏览器不动
mkbrowser "$APPS" "Old Chrome"; mkbrowser "$APPS" "Mine Browser"; mkapp "$APPS" "Not Browser"
printf 'app|Old Chrome|direct|new|\napp|Mine Browser|direct|ack|\napp|Not Browser|direct|new|\n' >> "$H/overrides.tsv"
apps_scan >/dev/null
eq "升级修复: 标记 new 的直连浏览器 → 跟随 (仍标 new, 还会提示); 自己设为直连的 (ack) / 非浏览器不动" "$(awk -F'|' '$2 == "Old Chrome" || $2 == "Mine Browser" || $2 == "Not Browser" {print $2 "=" $3 "/" $4}' "$H/overrides.tsv" | sort | paste -sd, -)" "Mine Browser=direct/ack,Not Browser=direct/new,Old Chrome=follow/new"
eq "升级修复写进操作记录 (来源 auto)" "$(grep -c '修复浏览器的默认设置.*names="\?Old Chrome' "$LOGS/ops-$(date +%F).log")" "1"
eq "再扫描一次不会重复修复" "$(apps_scan >/dev/null; grep -c '修复浏览器的默认设置' "$LOGS/ops-$(date +%F).log")" "1"
apps_ack all
# ---- 旧版本 (扫描范围更小) 升级后第一次扫描: 新发现的老应用算「首次」(标记 def, 不当作新应用)
echo 1 > "$H/apps.seen"; mkapp "$APPS" "Old Tool"; mkapp "$APPS" "Old Browser Pro"
n=$(apps_scan)
eq "旧版升级后的首次扫描: 新发现的老应用标 def, 不提示" "$n:$(apps_new_count):$(awk -F'|' '$2=="Old Tool" {print $3 "/" $4}' "$H/overrides.tsv")" "2:0:direct/def"
eq "扫描范围版本已记录 (以后不再按「首次」处理)" "$(cat "$H/apps.seen")" "$APPS_SCAN_V"
# ---- 云端推荐稍后才到: 首次扫描给的默认值 (def + 直连) 刷新成推荐; 用户设置过的 (ack) 不动
printf 'app|Cloud Later|direct|def|\napp|User Set|direct|ack|\napp|Already Follow|follow|def|\n' >> "$H/overrides.tsv"
printf 'Cloud Later|pin|X\nUser Set|pin|X\nAlready Follow|pin|X\n' >> "$UW/apps.conf"
apps_rerecommend
eq "云端推荐更新后: def+直连 → 推荐 (pin); ack (用户设置过) 不动; 非直连的默认值不动" "$(awk -F'|' '$2=="Cloud Later" || $2=="User Set" || $2=="Already Follow" {print $2 "=" $3}' "$H/overrides.tsv" | sort | paste -sd, -)" "Already Follow=follow,Cloud Later=pin,User Set=direct"
# ---- 采用推荐: 只处理 new 的 (或指定名称); 没有推荐值的不动
printf 'app|New Known|direct|new|\napp|New Unknown|direct|new|\n' >> "$H/overrides.tsv"; printf 'New Known|follow|X\n' >> "$UW/apps.conf"
apps_adopt
eq "采用推荐: 已知 → 推荐值并确认 (ack), 未知保持关 (仍是 new)" "$(awk -F'|' '$2 ~ /^New / {print $2 "=" $3 "/" $4}' "$H/overrides.tsv" | sort | paste -sd, -)" "New Known=follow/ack,New Unknown=direct/new"

echo "== U5. 覆盖层 → 规则集: 应用直连 / 网站直连 分开 · 固定出口指定 · 自动选 · 出口被删除"
rs() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d["rules"], ensure_ascii=False, sort_keys=True))' "$H/rules/ovr-$1.json"; }
printf '%s\n' '{"role":"pin","outbound":{"type":"socks","tag":"Pin-A","server":"127.0.0.1","server_port":1}}' > "$H/servers.jsonl"
: > "$H/overrides.tsv"
printf 'site|direct.io|direct|ack|\nsite|proxy.io|pin|ack|\nsite|auto.io|auto|ack|\napp|Plain App|direct|ack|\napp|Odd Browser|pin|ack|\napp|Auto App|auto|ack|\napp|Cursor|follow|ack|\n' > "$H/overrides.tsv"
ovr_sync
eq "网站直连 → ovr-direct (domain_suffix); 应用直连 → ovr-appdirect (process_path_regex) —— 两个规则集分开, 才能在日志里区分原因" "$(rs direct | grep -c direct.io):$(rs direct | grep -c Plain):$(rs appdirect | grep -c 'Plain App'):$(rs appdirect | grep -c direct.io)" "1:0:1:0"
eq "固定出口网站 → ovr-pin; 浏览器 PIN → 独立兜底规则; 自动线路 → ovr-auto; 跟随的不写进任何规则集" "$(rs pin | grep -c proxy.io):$(rs browserpin | grep -c 'Odd Browser'):$(rs pin | grep -c 'Odd Browser'):$(rs auto | grep -c auto.io):$(rs auto | grep -c 'Auto App'):$(cat "$H"/rules/ovr-*.json | grep -c Cursor)" "1:1:0:1:1:0"
eq "应用名按正则转义写入 (点号 / 括号不会匹配到别的应用)" "$(printf 'app|Foo.Bar (x)|direct|ack|\n' >> "$H/overrides.tsv"; ovr_sync; rs appdirect | grep -o '(?i)/Foo[^"]*' | head -1)" '(?i)/Foo\\.Bar \\(x\\)\\.app/'
eq "只有 1 个固定出口: 不能指定出口 (只能是默认)" "$(ovr_target_valid '' && echo ok1; ovr_target_valid Pin-A || echo no1; ovr_target_valid PINAUTO || echo no2)" "ok1
no1
no2"
# 加第二个固定出口: 可以指定
printf '%s\n' '{"role":"pin","outbound":{"type":"socks","tag":"Pin-B","server":"127.0.0.2","server_port":1}}' >> "$H/servers.jsonl"
eq "2 个固定出口: 可以指定其中一个 / 自动选 / 默认; 不存在的出口被拒" "$(ovr_target_valid Pin-B && echo ok; ovr_target_valid PINAUTO && echo ok; ovr_target_valid '' && echo ok; ovr_target_valid Nope || echo no)" "ok
ok
ok
no"
: > "$H/overrides.tsv"
printf 'site|a.io|pin|ack|Pin-A\nsite|b.io|pin|ack|Pin-B\nsite|c.io|pin|ack|PINAUTO\nsite|d.io|pin|ack|\napp|AppB|pin|ack|Pin-B\nsite|gone.io|pin|ack|Pin-Z\n' > "$H/overrides.tsv"
ovr_sync
eq "指定出口: Pin-A → ovr-pin-1, Pin-B → ovr-pin-2 (网站和应用都可以)" "$(rs pin-1 | grep -c a.io):$(rs pin-2 | grep -c b.io):$(rs pin-2 | grep -c AppB):$(rs pin-1 | grep -c b.io)" "1:1:1:0"
eq "PINAUTO → ovr-pinauto; 没指定 → 默认固定出口 ovr-pin" "$(rs pinauto | grep -c c.io):$(rs pin | grep -c d.io)" "1:1"
eq "指定的出口已被删除 (Pin-Z) → 退回默认固定出口 ovr-pin, 不会丢设置" "$(rs pin | grep -c gone.io)" "1"
eq "没有任何设置的规则集写入占位 (文件一定存在, 核心才能加载)" "$(rs appdirect | grep -c placeholder)" "1"
printf '%s\n' '{"role":"pin","outbound":{"type":"socks","tag":"Pin-C","server":"127.0.0.3","server_port":1}}' >> "$H/servers.jsonl"
ovr_sync; t "第 3 个固定出口也有自己的规则集 (ovr-pin-3)" test -f "$H/rules/ovr-pin-3.json"
eq "ovr_pins 只列固定出口, 顺序和配置里一致 (和规则集序号对应)" "$(ovr_pins | paste -sd, -)" "Pin-A,Pin-B,Pin-C"
ovr_json=$(overrides_json)
printf '%s' "$ovr_json" | chk "网站覆盖 JSON: target / target_ok (出口已删除 → false) / src (user 自己加的)" 'o={x["value"]:x for x in d}; assert o["b.io"]["target"]=="Pin-B" and o["b.io"]["target_ok"] and not o["gone.io"]["target_ok"] and o["c.io"]["target"]=="PINAUTO" and o["a.io"]["src"]=="user"'
printf 'a.io|1700000000|timeout|3|Safari\n' > "$H/autosites.tsv"
overrides_json | chk "自动识别添加的网站: src=auto, 带添加时间 / 原因 / 失败次数 / 应用" 'o={x["value"]:x for x in d}["a.io"]; assert o["src"]=="auto" and o["at"]==1700000000 and o["why"]=="timeout" and o["fails"]==3 and o["app"]=="Safari"'
eq "autosite_count / autosite_registry_has" "$(autosite_count):$(autosite_registry_has a.io && echo y):$(autosite_registry_has b.io || echo n)" "1:y:n"
autosite_forget a.io dismiss; eq "autosite_forget dismiss: 从记录中去掉并记入「不再自动添加」" "$(autosite_count):$(cat "$H/autosites.dismissed")" "0:a.io"

echo "== U6. 诊断导出: 格式 · 分区 · 行数自洽 · 脱敏"
mkdir -p "$LOGS"; rm -f "$LOGS"/*; TODAY=$(date +%F)
printf '%s\tdashboard\t修改应用/网站策略\tkind=site name=chatgpt.com from=follow to=pin target_to=Pin-B\tok\n%s\tauto\t发现新应用\tcount=1 names=Terminal\tok\n' "$(date '+%F %T')" "$(date '+%F %T')" > "$LOGS/ops-$TODAY.log"
printf '+0800 %s %s INFO [9 0ms] inbound/mixed[in]: inbound connection to google.com:443
+0800 %s %s INFO [9 0ms] router: found process path: /Users/someone/Applications/Foo.app/Contents/MacOS/foo, user: someone
+0800 %s %s INFO [9 1ms] outbound/direct[direct-app]: outbound connection to google.com:443
' "$TODAY" "$(date +%T)" "$TODAY" "$(date +%T)" "$TODAY" "$(date +%T)" > "$LOGS/proxy-$TODAY.log"
# 健康记录 (lib/health.sh 每分钟写入): 服务器端口 + 经代理的金丝雀 + 状态行; 用于验证 health / health_summary / outages / verdict 分区
{ for _m in 5 4 3 2 1; do printf '%s\tnode\tPin-A\tok\t41\trole=pin mode=system\n' "$(date -v-${_m}M '+%F %T' 2>/dev/null || date -d "-${_m} min" '+%F %T')"; done
  printf '%s\tcanary\tgoogle_204\tok\t210\thttp=204 via=proxy\n%s\tstate\tcapture\tok\t0\tcore=1 proxy=1 sysproxy=1 capture=system\n' "$(date '+%F %T')" "$(date '+%F %T')"; } > "$LOGS/health-$TODAY.log"
printf '{"role":"pin","outbound":{"type":"socks","tag":"Pin-A","server":"203.0.113.77","server_port":1080,"username":"u-secret","password":"PW-SECRET-123"}}\n' > "$H/servers.jsonl"
echo '{"log":{"level":"info"},"route":{"rules":[{"rule_set":["ovr-direct"],"action":"route","outbound":"direct-site"}],"final":"Final"},"outbounds":[{"type":"socks","tag":"Pin-A","server":"203.0.113.77","server_port":1080,"username":"u-secret","password":"PW-SECRET-123"}],"experimental":{"clash_api":{"external_controller":"127.0.0.1:1","secret":"CLASH-SECRET-XYZ"}}}' > "$H/config.json"
logs_bundle 24 ops,access,proxy,snapshot > "$UW/bundle.txt" 2>/dev/null
eq "第一行是格式标记 (#ENANA-DIAGNOSTICS format=1)" "$(head -1 "$UW/bundle.txt")" "#ENANA-DIAGNOSTICS format=1"
eq "bash 3.2: 导出分区声明完整, 不混入 shell 代码" "$(sed -n '/^#sections=/p' "$UW/bundle.txt")" "#sections=meta,verdict,env,config,policy,servers,apps,probes,live,health_summary,outages,health,ops,access,proxy"
python3 - "$UW/bundle.txt" > "$UW/bundle.check" 2>&1 <<'PY'
import sys, re
lines = open(sys.argv[1], encoding='utf-8').read().split('\n')
secs, cur, n = {}, None, 0
for l in lines:
    m = re.match(r'@@SECTION (\S+) format=(\S+) rows=(\d+)$', l)
    if m:
        cur = m.group(1); secs[cur] = [m.group(2), int(m.group(3)), 0]; continue
    if l == '@@END': cur = None; continue
    if cur is not None and l != '': secs[cur][2] += 1
need = ['meta','verdict','env','config','policy','servers','apps','probes','live','health_summary','outages','health','ops','access','proxy']
assert [k for k in need if k not in secs] == [], 'missing sections: %s' % [k for k in need if k not in secs]
bad = {k: v for k, v in secs.items() if v[2] > v[1] + 1 or v[2] < v[1] - 1}
assert not bad, 'rows mismatch: %s' % bad
assert secs['ops'][0] == 'tsv' and secs['meta'][0] == 'kv' and secs['proxy'][0] == 'raw'
assert lines[-2] == '@@END' or lines[-1] == '@@END', 'no @@END'
print('ok')
PY
eq "每个分区都有 @@SECTION 名称 format rows=N, 行数自洽, 以 @@END 结尾 (meta verdict env config policy servers apps probes live health_summary outages health ops access proxy)" "$(cat "$UW/bundle.check")" "ok"
awk -v d="$UW" '/^@@SECTION /{ if (f) close(f); f = d "/sec." $2; printf "" > f; next } /^@@END/{ if (f) close(f); f = ""; next } f { print > f }' "$UW/bundle.txt"
has() { grep -q -- "$2" "$UW/sec.$1"; }                       # has <分区> <正则>
nothas() { ! grep -q -- "$2" "$UW/sec.$1"; }
t "meta: 版本 / 日志开关 / 保留时长 / 服务器数量" sh -c "grep -q '^version=' '$UW/sec.meta' && grep -q '^settings.access_log=' '$UW/sec.meta' && grep -q '^settings.log_hours=' '$UW/sec.meta' && grep -q '^servers.pin=1' '$UW/sec.meta'"
eq "ops 分区: 第一行是列名" "$(head -1 "$UW/sec.ops")" "$(printf 'ts\twho\taction\tdetail\tresult')"
t "ops 分区: 详情是 key=value (谁 / 什么 / 从什么改成什么 / 指定的出口)" has ops 'kind=site name=chatgpt.com from=follow to=pin target_to=Pin-B'
eq "access 分区: google.com 一条连接一行, 直连原因 app, 路径里的用户名已打码" "$(awk -F'\t' 'NR>1 && $4=="google.com" {print $8 "/" $10 "/" $16}' "$UW/sec.access")" "direct/app//Users/<user>/Applications/Foo.app/Contents/MacOS/foo"
eq "meta 之后紧跟 verdict (自动判定排在文件开头)" "$(grep '^@@SECTION' "$UW/bundle.txt" | sed -n '1,2p' | awk '{print $2}' | paste -sd, -)" "meta,verdict"
t "verdict: 有结论字段 (cause / blame / confidence / 中英文摘要)" sh -c "grep -q '^verdict.cause=' '$UW/sec.verdict' && grep -q '^verdict.blame=' '$UW/sec.verdict' && grep -q '^verdict.summary.zh=' '$UW/sec.verdict' && grep -q '^verdict.summary.en=' '$UW/sec.verdict'"
t "verdict: 节点可达率来自健康记录 (Pin-A reachable=100.0%)" has verdict '^verdict.node.Pin-A=role=pin reachable=100.0%'
eq "health 分区: 第一行是列名, 原始记录一行一条" "$(head -1 "$UW/sec.health")" "$(printf 'ts\tkind\ttarget\tresult\tms\tdetail')"
t "health_summary / outages 分区: 有列名" sh -c "head -1 '$UW/sec.health_summary' | grep -q '^bucket	kind	target' && head -1 '$UW/sec.outages' | grep -q '^start	end	minutes'"
t "servers 分区: 地址已打码 (203.0.*.*)" has servers '203\.0\.\*\.\*'
t "servers 分区: 不出现完整地址" nothas servers '203\.0\.113\.77'
t "config 分区: 规则按顺序列出 (rule[0] …)" has config '^rule\[0\] '
t "config 分区: 服务器只留类型 / 打码地址 / 端口" has config '^server tag=Pin-A type=socks host=203\.0\.\*\.\*'
t "整个文件没有任何密码 / 令牌 / 完整服务器地址 / 真实用户名 (PW-SECRET-123 · u-secret · CLASH-SECRET-XYZ · 203.0.113.77 · someone)" sh -c "! grep -E 'PW-SECRET-123|u-secret|CLASH-SECRET-XYZ|203\.0\.113\.77|someone' '$UW/bundle.txt'"
# 诊断摘要 (lib/diag.pl): 用真实导出做端到端检查 —— 格式没对上 (分区 / 列的位置) 或者有敏感内容漏出去, 这里会立刻发现
perl "$LIB/diag.pl" summary < "$UW/bundle.txt" > "$UW/summary.json" 2>"$UW/summary.err"
eq "诊断摘要: 真实导出可以生成合法 JSON (v=1, 带 meta / verdict / env / health / ops)" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["v"], sorted(k for k in ("meta","verdict","env","health","ops") if d.get(k)))' "$UW/summary.json" 2>&1)" "1 ['env', 'health', 'meta', 'ops', 'verdict']"
eq "诊断摘要: 版本 / 服务器数量来自 meta, 判定原因来自 verdict" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(bool(d["meta"]["version"]), d["meta"]["servers.pin"], bool(d["verdict"]["cause"]))' "$UW/summary.json" 2>&1)" "True 1 True"
eq "诊断摘要: 健康记录里的服务器换成了别名 (Pin-A → node1)" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(sorted(set(r["target"] for r in d["health"] if r["kind"]=="node")))' "$UW/summary.json" 2>&1)" "['node1']"
t "诊断摘要: 没有任何域名 / 应用名 / 服务器标签 / 地址 / 密码 / 用户名 (chatgpt.com · google.com · Foo · Pin-A · 203.0.113.77 · PW-SECRET-123 · u-secret · someone)" sh -c "! grep -E 'chatgpt[.]com|google[.]com|Foo|Pin-A|203[.]0[.]113|PW-SECRET-123|u-secret|CLASH-SECRET-XYZ|someone|/Users/' '$UW/summary.json'"
t "诊断摘要: 操作记录里「修改应用/网站策略」这类动作还在, 详情里的 name= / kind= / target_to= 被丢弃" sh -c "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); o=[x for x in d[\"ops\"] if x[\"action\"].startswith(\"修改\")]; assert o and all(\"name=\" not in x[\"detail\"] and \"target_to=\" not in x[\"detail\"] and \"kind=\" not in x[\"detail\"] for x in o)' '$UW/summary.json'"
t "诊断摘要: 没有 stderr 输出 (没有 Perl 警告)" test ! -s "$UW/summary.err"
logs_bundle 24 ops > "$UW/b2.txt" 2>/dev/null
eq "只勾选「操作记录」时: 只有 meta + ops 两个分区 (没有 access / proxy / 当前状态)" "$(grep '^@@SECTION' "$UW/b2.txt" | awk '{print $2}' | paste -sd, -)" "meta,ops"
logs_bundle 1 access,proxy > "$UW/b3.txt" 2>/dev/null
eq "只勾选「网站访问」「代理日志」: meta + access + proxy" "$(grep '^@@SECTION' "$UW/b3.txt" | awk '{print $2}' | paste -sd, -)" "meta,access,proxy"
logs_bundle abc ops > "$UW/b4.txt" 2>/dev/null; eq "时间范围写错 → 回落到 24 小时, 不会失败" "$(grep -c '^#range since=' "$UW/b4.txt")" "1"
python3 "$REPO/tools/diag-summary.py" "$UW/bundle.txt" > "$UW/summary.txt" 2>&1; eq "tools/diag-summary.py 能解读导出文件 (有概览 / 自动判断)" "$(grep -c '^== 概览\|^== 自动判断' "$UW/summary.txt")" "2"
echo

echo "== U7. 仪表盘静态检查 (控制台报错的回归保护)"
t "仪表盘不会自动去访问第三方网站查 IP (ipify / ipinfo): 出口 IP 由本机辅助服务查, 浏览器里不再出现 ERR_CONNECTION_RESET" sh -c "! grep -nE 'api\\.ipify\\.org|ipinfo\\.io' '$REPO'/ui/*.js"
t "v-vps.js: 重置错误提示时只对有 setErr 的项调用 (「保存到云端」勾选框不是输入项; 以前这里抛 TypeError, 「添加自己的服务器」面板打不开)" grep -q 'b\[k\] && b\[k\].setErr' "$REPO/ui/v-vps.js"
t "页面声明了标签页图标, 文件都在" sh -c "grep -q 'rel=\"icon\"' '$REPO/ui/index.html' && test -s '$REPO/ui/favicon.svg' && test -s '$REPO/ui/favicon.png'"
echo "== U8. 官方线路 (会员): 云端响应整理 · 与用户服务器分开 · 只进自动线路池 · 没变化不重启 · 失败退避 / 宽限期 / 退出清除"
# 只用占位数据: *.example.invalid 的主机、假的凭据、假的区域名。云端用桩函数代替 (不联网)。
OFFD=$UW/off; mkdir -p "$OFFD"; : > "$OFFD/applies"
cat > "$OFFD/mk.py" <<'PYEOF'
import json, sys
kind = sys.argv[1]
def http(i, **kw):
    o = {"type": "http", "tag": "官方-区域%d" % i, "server": "n%d.example.invalid" % i, "server_port": 443, "username": "u%d" % i, "password": "pw%d" % i, "tls": {"enabled": True, "server_name": "n%d.example.invalid" % i}}
    o.update(kw); return {"outbound": o}
nodes = [http(1), http(2)]
nodes.append({"outbound": {"type": "tuic", "tag": "官方-图克", "server": "t.example.invalid", "server_port": 8443, "uuid": "00000000-0000-0000-0000-000000000001", "password": "pw", "congestion_control": "bbr", "tls": {"enabled": True, "alpn": ["h3"]}}})
nodes.append({"outbound": {"type": "hysteria2", "tag": "官方-海星", "server": "y.example.invalid", "server_port": 8443, "password": "pw", "obfs": {"type": "salamander", "password": "ob"}, "tls": {"enabled": True}}})
nodes.append({"outbound": {"type": "vless", "tag": "官方-维斯", "server": "v.example.invalid", "server_port": 443, "uuid": "00000000-0000-0000-0000-000000000002", "flow": "xtls-rprx-vision", "tls": {"enabled": True, "reality": {"enabled": True, "public_key": "PUB", "short_id": "ab"}}}})
if kind == "ok":
    bad = [http(9, tag="没有前缀"), http(10, detour="direct"), http(11, server="127.0.0.1"), http(12, type="wireguard"), http(13, server_port="443"), http(1), http(14, tag='官方-引"号'), http(15, tls={"certificate_path": "@CERTS@/x.crt"})]
    print(json.dumps({"entitled": True, "nodes": nodes + bad}, ensure_ascii=False))
elif kind == "ok2":    # 与 ok 同样的节点, 只是云端换了顺序和键的顺序
    n = [dict(sorted(x["outbound"].items(), reverse=True)) for x in reversed(nodes)]
    print(json.dumps({"entitled": True, "nodes": [{"outbound": o} for o in n]}, ensure_ascii=False))
elif kind == "changed":
    print(json.dumps({"entitled": True, "nodes": nodes[:3] + [http(7)]}, ensure_ascii=False))
elif kind == "no":
    print(json.dumps({"entitled": False, "nodes": []}))
elif kind == "empty":
    print(json.dumps({"entitled": True, "nodes": []}))
elif kind == "junk":
    print("<html>login</html>")
PYEOF
for k in ok ok2 changed no empty junk; do python3 "$OFFD/mk.py" $k > "$OFFD/$k.json"; done

official_ingest "$OFFD/ok.json" "$OFFD/cand.jsonl"; eq "整理云端响应: 有资格且有节点 → 退出码 0" "$?" "0"
eq "整理云端响应: 只留 5 个合格节点 (没有保留前缀 / detour / 回环地址 / 不支持的协议 / 端口不是数字 / 重复 / 引号 / 本机证书占位符 全部丢弃)" "$(wc -l < "$OFFD/cand.jsonl" | tr -d ' ')" "5"
t "每一行都通过 official_check_lines (role=auto, official:true, type 和 tag 在最前)" official_check_lines "$OFFD/cand.jsonl"
eq "行按节点名排序, 每行是合法 JSON" "$(python3 -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]; t=[x["outbound"]["tag"] for x in r]; assert t==sorted(t, key=lambda s: s.encode()); assert all(list(x["outbound"])[:2]==["type","tag"] and x["role"]=="auto" and x["official"] is True for x in r); print(len(t))' "$OFFD/cand.jsonl")" "5"
official_ingest "$OFFD/ok2.json" "$OFFD/cand2.jsonl"; t "云端换了节点顺序 / 键顺序: 整理后的文件逐字节相同 (没变化就不会重启)" cmp -s "$OFFD/cand.jsonl" "$OFFD/cand2.jsonl"
official_ingest "$OFFD/no.json" "$OFFD/x" ; eq "云端说没有资格 (entitled:false) → 退出码 3" "$?" "3"
official_ingest "$OFFD/empty.json" "$OFFD/x" ; eq "有资格但云端暂时没有节点 → 退出码 4 (保留现有节点)" "$?" "4"
official_ingest "$OFFD/junk.json" "$OFFD/x" ; eq "不是 JSON → 退出码 1" "$?" "1"
t "拒绝过的内容不会写出文件 (没有部分写入)" test ! -e "$OFFD/x"

# 与用户的服务器分开存放; 配置生成时只进自动线路池
printf '%s\n' '{"role":"pin","outbound":{"type":"socks","tag":"Pin-A","server":"203.0.113.77","server_port":1080,"version":"5"}}' '{"role":"auto","outbound":{"type":"trojan","tag":"Auto-1","server":"198.51.100.4","server_port":443,"password":"x"}}' > "$H/servers.jsonl"
cp "$OFFD/cand.jsonl" "$H/official.jsonl"
eq "official_emit: 每个官方节点一行 (role=auto)" "$(official_emit | cut -f1 | sort | uniq -c | tr -s ' ')" " 5 auto"
eq "official_emit: 第三列是去掉外层的出站 JSON, 不含 official 标记" "$(official_emit | cut -f3 | python3 -c 'import sys,json; print(all("official" not in json.loads(l) and list(json.loads(l))[:2]==["type","tag"] for l in sys.stdin))')" "True"
eq "official_list: 第 7 列 = 1, 地址和端口留空 (界面不显示官方节点的地址)" "$(official_list | awk -F'\t' '$7=="1" && $3=="" && $4=="" && $5=="auto" {n++} END{print n}')" "5"
eq "srv_list 不含官方节点 (它们不是用户的服务器): 数量 / 首次使用判断不受影响" "$(srv_count)" "2"
t "official_has_tag" official_has_tag "官方-图克"
printf '%s\n' '{"role":"auto","outbound":{"type":"trojan","tag":"官方-图克","server":"203.0.113.9","server_port":443,"password":"mine"}}' >> "$H/servers.jsonl"
eq "用户自己有同名节点时, 官方的那一行不输出 (核心配置里不能出现重复标签)" "$(official_emit | cut -f2 | grep -c '^官方-图克$')" "0"
sed -i.bak '$d' "$H/servers.jsonl"; rm -f "$H/servers.jsonl.bak"
t "用户导入的节点不能占用保留前缀 官方-" sh -c ". '$LIB/servers.sh'; ! srv_check_line '{\"role\":\"auto\",\"outbound\":{\"type\":\"trojan\",\"tag\":\"官方-我的\",\"server\":\"203.0.113.9\",\"server_port\":443,\"password\":\"p\"}}'"
t "也不能占用 enana-official- 前缀 (旧的模拟器 / 文档里用过)" sh -c ". '$LIB/servers.sh'; ! srv_check_line '{\"role\":\"auto\",\"outbound\":{\"type\":\"trojan\",\"tag\":\"enana-official-x\",\"server\":\"203.0.113.9\",\"server_port\":443,\"password\":\"p\"}}'"
t "普通节点名照常接受" sh -c ". '$LIB/servers.sh'; srv_check_line '{\"role\":\"auto\",\"outbound\":{\"type\":\"trojan\",\"tag\":\"官方版本\",\"server\":\"203.0.113.9\",\"server_port\":443,\"password\":\"p\"}}'"
srv_secret_fields "官方-图克" >/dev/null; eq "官方节点的凭据永远不显示 (srv_secret_fields 退出码 3)" "$?" "3"
srv_secret_fields "Auto-1" >/dev/null; eq "用户自己的节点仍可查看 (退出码 0)" "$?" "0"
printf '%s\n' '{"role":"auto","outbound":{"type":"trojan","tag":"香港节点","server":"198.51.100.8","server_port":443,"password":"cn-pw"}}' >> "$H/servers.jsonl"
eq "含中文名字的用户节点也能查看凭据 (srv_secret_fields 以前拿字节和已解码的字符串比较, 中文名永远对不上)" "$(srv_secret_fields 香港节点 | python3 -c 'import sys,json; print(json.load(sys.stdin)[0]["value"])')" "cn-pw"
sed -i.bak '$d' "$H/servers.jsonl"; rm -f "$H/servers.jsonl.bak"

gen_config >/dev/null 2>&1; cp "$H/config.json.new" "$OFFD/cfg1.json"
eq "配置: 官方节点在 AUTO 池和 Global 里, 不在 PIN 里 (只进自动线路)" "$(python3 - "$OFFD/cfg1.json" <<'PYEOF'
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8")); o = {x["tag"]: x for x in c["outbounds"]}
off = sorted(t for t in o if t.startswith("官方-"))
print(len(off), all(t in o["AUTO"]["outbounds"] and t in o["Global"]["outbounds"] and t not in o["PIN"]["outbounds"] for t in off), o["PIN"]["outbounds"], "official" in json.dumps(c))
PYEOF
)" "5 True ['Pin-A'] False"
gen_config >/dev/null 2>&1; t "官方节点没变化: 重新生成的配置逐字节相同" cmp -s "$OFFD/cfg1.json" "$H/config.json.new"
python3 "$OFFD/mk.py" changed > /dev/null; official_ingest "$OFFD/changed.json" "$OFFD/cand3.jsonl"; cp "$OFFD/cand3.jsonl" "$H/official.jsonl"
gen_config >/dev/null 2>&1; t "官方节点变了: 配置也跟着变" sh -c "! cmp -s '$OFFD/cfg1.json' '$H/config.json.new'"
: > "$H/official.jsonl"; gen_config >/dev/null 2>&1; eq "官方节点清空后: 配置里一个官方节点都没有" "$(grep -c '官方-' "$H/config.json.new" || true)" "0"

# 同步流程 (云端、授权、配置校验都用桩函数)
auth_logged_in() { return 0; }; session_id() { printf sid; }; session_token() { printf tok; }
session_call() { local out=$1; if [ -n "${FAKE_BODY:-}" ]; then cp "$FAKE_BODY" "$out"; else : > "$out"; fi; printf '%s' "${FAKE_CODE:-200}"; }
apply_config() { echo x >> "$OFFD/applies"; APPLY_CHANGED=1; [ -z "${STUB_FAIL:-}" ]; }
napply() { wc -l < "$OFFD/applies" | tr -d ' '; }
rm -f "$H/official.jsonl" "$H/official.state"; NETWORK_MODE=system; unset OP_WHO
FAKE_BODY=$OFFD/ok.json FAKE_CODE=200 official_sync; eq "同步: 第一次 → 写入并应用 (apply_config 调用 1 次)" "$?:$(napply):$(wc -l < "$H/official.jsonl" | tr -d ' ')" "0:1:5"
eq "同步: 文件权限 600, 状态里 entitled=1、fails=0" "$(ls -l "$H/official.jsonl" | cut -c1-10):$(official_state_get entitled):$(official_state_get fails)" "-rw-------:1:0"
cp "$H/official.jsonl" "$OFFD/keep.jsonl"
FAKE_BODY=$OFFD/ok2.json FAKE_CODE=200 official_sync; eq "同步: 云端内容没变 (顺序不同) → 不重新生成配置、不重启 (apply_config 仍是 1 次), 文件逐字节不变" "$?:$(napply):$(cmp -s "$OFFD/keep.jsonl" "$H/official.jsonl" && echo same)" "0:1:same"
FAKE_BODY=$OFFD/changed.json FAKE_CODE=200 official_sync; eq "同步: 节点变了 → 应用 (apply_config 共 2 次)" "$?:$(napply)" "0:2"
FAKE_BODY=$OFFD/changed.json FAKE_CODE=503 official_sync; eq "同步: 云端 503 → 失败 (退出码 1), 现有节点原样保留, 没有应用, fails=1" "$?:$(napply):$(wc -l < "$H/official.jsonl" | tr -d ' '):$(official_state_get fails)" "1:2:4:1"
FAKE_BODY=$OFFD/junk.json FAKE_CODE=200 official_sync; eq "同步: 云端回了网页 → 当作失败, 现有节点保留, fails=2" "$?:$(wc -l < "$H/official.jsonl" | tr -d ' '):$(official_state_get fails)" "1:4:2"
FAKE_BODY=$OFFD/empty.json FAKE_CODE=200 official_sync; eq "同步: 有资格但云端暂时没有节点 → 保留现有节点, fails 归零" "$?:$(wc -l < "$H/official.jsonl" | tr -d ' '):$(official_state_get fails)" "0:4:0"
now_=$(now); due() { official_due && echo due || echo wait; }
official_state_set try="$now_" fails=0; eq "到点判断: 刚同步过 → 还没到点" "$(due)" wait
official_state_set try=$((now_ - 14500)) fails=0; eq "到点判断: 超过 4 小时 → 到点" "$(due)" due
official_state_set try=$((now_ - 1000)) fails=1; eq "失败退避: 第 1 次失败后 15 分钟到点" "$(due)" due
official_state_set try=$((now_ - 800)) fails=1; eq "失败退避: 15 分钟内不重试" "$(due)" wait
official_state_set try=$((now_ - 1000)) fails=2; eq "失败退避: 第 2 次失败后要等 30 分钟" "$(due)" wait
official_state_set try=$((now_ - 3000)) fails=8; eq "失败退避: 多次失败后最长 4 小时一次" "$(due)" wait
official_state_set ok=$((now_ - 100000)) try="$now_" fails=1
FAKE_CODE=503 official_sync; eq "宽限期: 离线不到 3 天 → 节点保留" "$?:$(wc -l < "$H/official.jsonl" | tr -d ' '):$(napply)" "1:4:2"
official_state_set ok=$((now_ - 270000)) try=0
FAKE_CODE=503 official_sync; eq "宽限期: 离线超过 3 天 → 节点移除并应用 (apply_config 共 3 次)" "$?:$(test -e "$H/official.jsonl" && echo present || echo gone):$(napply)" "1:gone:3"
FAKE_BODY=$OFFD/ok.json FAKE_CODE=200 official_sync; FAKE_BODY=$OFFD/no.json FAKE_CODE=200 official_sync
eq "同步: 云端明确说没有资格 (订阅到期 / 邮箱未验证) → 下一次成功同步时全部移除" "$?:$(test -e "$H/official.jsonl" && echo present || echo gone):$(official_state_get entitled)" "0:gone:0"
n0=$(napply); FAKE_BODY=$OFFD/no.json FAKE_CODE=200 official_sync; eq "同步: 本来就没有节点时 entitled:false 不触发任何应用" "$(napply)" "$n0"
t "移除官方节点之后不留凭据副本 (op_txn 的备份 official.jsonl.prev 也删掉)" test ! -e "$H/official.jsonl.prev"

# 配置没通过校验: 回滚到原来的节点, 同一份内容一天之内不再重试
FAKE_BODY=$OFFD/ok.json FAKE_CODE=200 official_sync; cp "$H/official.jsonl" "$OFFD/good.jsonl"; n1=$(napply)
STUB_FAIL=1 FAKE_BODY=$OFFD/changed.json FAKE_CODE=200 official_sync
eq "校验失败: 退出码 1, 回滚到原来的节点 (official.jsonl 没变), 记下被拒绝的内容" "$?:$(cmp -s "$OFFD/good.jsonl" "$H/official.jsonl" && echo same):$([ -n "$(official_state_get bad)" ] && echo marked)" "1:same:marked"
n2=$(napply); STUB_FAIL=1 FAKE_BODY=$OFFD/changed.json FAKE_CODE=200 official_sync
eq "校验失败: 同一份被拒绝的内容不会再次尝试 (没有额外的 apply_config)" "$(napply)" "$n2"
official_state_set bad_at=$(( $(now) - 90000 )); FAKE_BODY=$OFFD/changed.json FAKE_CODE=200 official_sync; eq "拒绝记录超过一天后重新尝试并成功" "$?:$(wc -l < "$H/official.jsonl" | tr -d ' '):$(official_state_get bad)" "0:4:"

# Enhanced/TUN: 后台 (auto) 不弹授权, 记下 deferred; 仪表盘里 (用户在场) 才应用
FAKE_BODY=$OFFD/ok.json FAKE_CODE=200 official_sync; n3=$(napply); cp "$H/official.jsonl" "$OFFD/tun0.jsonl"
NETWORK_MODE=tun OP_WHO=auto FAKE_BODY=$OFFD/changed.json FAKE_CODE=200 official_sync
eq "TUN + 后台: 节点有变化 → 不应用、不改文件、记下 deferred=1" "$?:$(napply):$(cmp -s "$OFFD/tun0.jsonl" "$H/official.jsonl" && echo same):$(official_state_get deferred)" "0:$n3:same:1"
NETWORK_MODE=tun OP_WHO=dashboard FAKE_BODY=$OFFD/changed.json FAKE_CODE=200 official_sync
eq "TUN + 仪表盘: 用户在场 → 正常应用, deferred 清零" "$?:$(napply):$(official_state_get deferred)" "0:$((n3 + 1)):0"
NETWORK_MODE=tun OP_WHO=auto FAKE_BODY=$OFFD/changed.json FAKE_CODE=200 official_sync; eq "TUN + 后台: 内容没变 → 什么都不做 (也不记 deferred)" "$(napply):$(official_state_get deferred)" "$((n3 + 1)):0"
NETWORK_MODE=system; unset OP_WHO

# 套餐刷新后判断是否需要同步 / 退出账号清除
printf '%s' '{"plan":{"code":"pro"},"features":{"core":{"enabled":true,"tier":"free"},"official_proxy":{"enabled":true,"tier":"pro"}},"official":{"available":true,"nodes":33}}' > "$H/plan.json"
eq "plan_official_on: 套餐里 official_proxy.enabled=true → 1" "$(plan_official_on)" "1"
printf '%s' '{"plan":{"code":"free"},"features":{"official_proxy":{"enabled":false,"tier":"pro","reason":"upgrade","coming_soon":true}}}' > "$H/plan.json"
eq "plan_official_on: 免费版 / 即将推出 → 0" "$(plan_official_on)" "0"
rm -f "$H/plan.json"; eq "plan_official_on: 没有缓存 → 0" "$(plan_official_on)" "0"
t "退出账号 (auth_logout_local) 会删除 official.jsonl、它的备份和 official.state: 官方节点属于账号" sh -c "grep -q '\$H/official.jsonl\" \"\$H/official.jsonl.prev\" \"\$H/official.state' '$LIB/auth.sh'"
unset -f auth_logged_in session_id session_token session_call apply_config
echo
PASS=$(wc -l < "$UW/.pass" 2>/dev/null | tr -d ' '); FAIL=$(wc -l < "$UW/.fail" 2>/dev/null | tr -d ' ')
echo "单元测试: ${PASS:-0} 通过, ${FAIL:-0} 失败"
[ "${FAIL:-0}" = 0 ]
