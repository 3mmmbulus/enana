#!/bin/bash
# 单元测试 (几秒钟; 不需要 sing-box / 网络 / 管理员权限): 直接加载 lib/*.sh, 在临时目录里验证
#   访问记录解析 (access.awk) · 自动识别的事件与候选 · 日志保留 (小时) · 三个日志开关 · 应用扫描与覆盖层 · 规则集拆分 · 诊断导出的格式与脱敏
#   更新失败记在真正失败的步骤 · 原因取最后一条「✗」 · api.log 带时间与轮转 · 导出的 api.log 尾部与时间范围 · 任务文件只留最近的 (过一天的删) · 管理员重启的结果 · 导出的打码 (IP / URL 用户名 / host=) · 导入失败删掉粘贴的数据
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
eq "首次扫描: 每个应用都有「识别时间」(apps.times 不是空的; 以前 NR==FNR 写法在旧文件为空时把整个文件清空, 应用页的安装 / 识别时间全是空白)" "$(awk -F'\t' '$2 + 0 > 0 {n++} END {print n + 0}' "$H/apps.times"):$(wc -l < "$H/apps.times" | tr -d ' ')" "4:4"
t_seen=$(awk -F'\t' '$1 == "Plain App" {print $2}' "$H/apps.times"); apps_scan >/dev/null
eq "再扫描: 已有应用的识别时间不变 (只记第一次看到的时间)" "$(awk -F'\t' '$1 == "Plain App" {print $2}' "$H/apps.times")" "$t_seen"
: > "$H/apps.times"; apps_scan >/dev/null
eq "apps.times 被清空 (旧版本留下的) 后, 下一次扫描自动补回" "$(awk -F'\t' '$2 + 0 > 0 {n++} END {print n + 0}' "$H/apps.times")" "4"
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
# ---- 后台扫描 (TUN, 界面每分钟自动发起): 没有变化 → 保留结果、不写操作记录、返回 1 (不开应用任务); 覆盖层或规则集会变 → 覆盖层还原、返回 0; 正在应用配置 → 这次不扫
echo "== U4b. 后台扫描: 没有变化不写操作记录; 覆盖层 / 规则集有变化才交给应用任务; 应用配置时不扫"
apps_scan >/dev/null; apps_scan >/dev/null
ops_rows() { cat "$LOGS"/ops-*.log 2>/dev/null | wc -l | tr -d ' '; }
ovr_sum() { cksum < "$H/overrides.tsv"; }
o0=$(ops_rows); s0=$(ovr_sum); rc=0; apps_scan_bg || rc=$?
eq "没有变化: 返回 1 (调用方直接返回列表, 不开应用任务)" "$rc" "1"
eq "没有变化: 不写操作记录, 覆盖层一个字节都不变" "$(ops_rows):$(ovr_sum)" "$o0:$s0"
t "没有变化: 扫描结束后释放应用锁" test ! -d "$H/.apply.lock"
mkapp "$APPS" "Bg Newcomer"; rc=0; apps_scan_bg || rc=$?
eq "新装了应用: 返回 0 (调用方开应用任务)" "$rc" "0"
eq "…覆盖层还原到扫描前 (新应用没有写进去), 操作记录也没有写" "$(grep -c 'Bg Newcomer' "$H/overrides.tsv"):$(ops_rows)" "0:$o0"
apps_scan >/dev/null
eq "…应用任务随后的扫描照常把它记为新应用 (不是首次扫描的默认值)" "$(awk -F'|' '$2 == "Bg Newcomer" {print $3 "/" $4}' "$H/overrides.tsv")" "direct/new"
o1=$(ops_rows); rc=0; apps_scan_bg || rc=$?
eq "应用任务之后再后台扫描: 又没有变化 (返回 1, 操作记录不变)" "$rc:$(ops_rows)" "1:$o1"
mkbrowser "$APPS" "Gone Browser"; printf 'app|Gone Browser|direct|ack|\n' >> "$H/overrides.tsv"; apps_scan >/dev/null
t "卸载前: 直连的浏览器在 browserdirect 规则集里" grep -q 'Gone Browser' "$H/rules/ovr-browserdirect/ovr-browserdirect.json"
rm -rf "$APPS/Gone Browser.app"; rc=0; apps_scan_bg || rc=$?
eq "只有规则集会变 (覆盖层一行没动, 卸载了直连的浏览器): 返回 0" "$rc" "0"
apps_scan >/dev/null
t "应用任务把它从 browserdirect 挪到 appdirect" sh -c "! grep -q 'Gone Browser' '$H/rules/ovr-browserdirect/ovr-browserdirect.json' && grep -q 'Gone Browser' '$H/rules/ovr-appdirect/ovr-appdirect.json'"
mkdir "$H/.apply.lock"; mkapp "$APPS" "Busy Newcomer"; rc=0; apps_scan_bg || rc=$?
eq "正在应用配置 (应用锁被占着): 这次不扫, 返回 1, 覆盖层不动" "$rc:$(grep -c 'Busy Newcomer' "$H/overrides.tsv")" "1:0"
rmdir "$H/.apply.lock"; rc=0; apps_scan_bg || rc=$?
eq "锁释放后: 下一次后台扫描照常发现新应用 (返回 0)" "$rc" "0"
apps_scan >/dev/null

# ---- 后台扫描, TUN 根服务已装 (指纹一致): 助手不可信 → 2 (待应用: 不开任务、覆盖层不动); 助手可信 → 0 (由后台开任务); 失败后 24 小时内不自动重试同一组变化
echo "== U4c. 后台扫描 (TUN, 根服务已装): 需要授权的变化只记为待应用 · 助手可信才自动开任务 · 失败的一组 24 小时内不自动重试 · 用户按「应用」后清掉"
NETWORK_MODE=tun
enhanced_loaded() { return 0; }
enhanced_fingerprint() { printf 'FP\n'; }
enhanced_helper_ok() { [ "${FAKE_HELPER:-0}" = 1 ]; }
printf 'FP\n' > "$H/.enhanced-fingerprint"; enhanced_ovr_fingerprint > "$H/.enhanced-ovr-fingerprint"
rm -f "$H/.apps-pending" "$H/.apps-bg-tried"
FAKE_HELPER=0; o2=$(ops_rows); s2=$(ovr_sum); rc=0
mkapp "$APPS" "Tun Newcomer"; apps_scan_bg || rc=$?
eq "助手不可信: 变化要管理员授权 → 返回 2 (调用方不开任务)" "$rc" "2"
eq "…覆盖层一个字节都不动, 操作记录也没有写" "$(ovr_sum):$(ops_rows)" "$s2:$o2"
t "…记下待应用 (界面的「应用」卡片读它)" grep -q 'Tun Newcomer' "$H/.apps-pending"
eq "…待应用的内容: 1 个新应用, 名称正确 (JSON 合法)" "$(apps_pending_json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["count"], d["names"][0])')" "1 Tun Newcomer"
t "…没有记为已开过后台任务" test ! -f "$H/.apps-bg-tried"
rc=0; apps_scan_bg || rc=$?
eq "同一组变化再来一次 (还没应用): 仍是待应用 (2), 不会每分钟都想开任务" "$rc" "2"
FAKE_HELPER=1; rc=0; apps_scan_bg || rc=$?
eq "助手可信 (只有规则数据变了): 免密同步, 返回 0 (由后台开任务)" "$rc" "0"
eq "…开任务之前覆盖层已经还原 (任务自己重新扫描、写入)" "$(ovr_sum)" "$s2"
t "…这组变化记为后台已开过 (.apps-bg-tried)" test -s "$H/.apps-bg-tried"
t "…待应用记录清掉 (已经在应用)" test ! -f "$H/.apps-pending"
rc=0; apps_scan_bg || rc=$?
eq "上一次后台开的任务没有应用成功 (模拟: 没有执行): 24 小时内同一组变化不再自动重开, 改为待应用 (2)" "$rc" "2"
read -r tc tt < "$H/.apps-bg-tried"; printf '%s\t%s\n' "$tc" "$((tt - 86401))" > "$H/.apps-bg-tried"
rc=0; apps_scan_bg || rc=$?
eq "超过 24 小时: 再由后台开一次 (0)" "$rc" "0"
apps_scan >/dev/null; apps_pending_clear; enhanced_ovr_fingerprint > "$H/.enhanced-ovr-fingerprint"     # 真正的应用任务同步根快照后会记下指纹 (这里模拟)
rc=0; apps_scan_bg || rc=$?
eq "用户按「应用」 (手动扫描) 之后: 没有变化 (1)" "$rc" "1"
t "…没有变化时待应用记录也清掉" test ! -f "$H/.apps-pending"
# 恢复真实的函数, 其它测试不受影响
. "$LIB/enhanced.sh"; NETWORK_MODE=system; rm -f "$H/.apps-pending" "$H/.apps-bg-tried" "$H/.enhanced-fingerprint" "$H/.enhanced-ovr-fingerprint"

echo "== U5. 覆盖层 → 规则集: 应用直连 / 网站直连 分开 · 固定出口指定 · 自动选 · 出口被删除"
rs() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d["rules"], ensure_ascii=False, sort_keys=True))' "$H/rules/ovr-$1/ovr-$1.json"; }
printf '%s\n' '{"role":"pin","outbound":{"type":"socks","tag":"Pin-A","server":"127.0.0.1","server_port":1}}' > "$H/servers.jsonl"
: > "$H/overrides.tsv"
printf 'site|direct.io|direct|ack|\nsite|proxy.io|pin|ack|\nsite|auto.io|auto|ack|\napp|Plain App|direct|ack|\napp|Odd Browser|pin|ack|\napp|Auto App|auto|ack|\napp|Cursor|follow|ack|\n' > "$H/overrides.tsv"
ovr_sync
eq "网站直连 → ovr-direct (domain_suffix); 应用直连 → ovr-appdirect (process_path_regex) —— 两个规则集分开, 才能在日志里区分原因" "$(rs direct | grep -c direct.io):$(rs direct | grep -c Plain):$(rs appdirect | grep -c 'Plain App'):$(rs appdirect | grep -c direct.io)" "1:0:1:0"
eq "固定出口网站 → ovr-pin; 浏览器 PIN → 独立兜底规则; 网站自动 → ovr-auto; 应用自动 → ovr-appauto (N1: 不和网站自动共用); 跟随的不写进任何规则集" "$(rs pin | grep -c proxy.io):$(rs browserpin | grep -c 'Odd Browser'):$(rs pin | grep -c 'Odd Browser'):$(rs auto | grep -c auto.io):$(rs appauto | grep -c 'Auto App'):$(cat "$H"/rules/ovr-*/ovr-*.json | grep -c Cursor)" "1:1:0:1:1:0"
eq "应用名按正则转义写入 (点号 / 括号不会匹配到别的应用)" "$(printf 'app|Foo.Bar (x)|direct|ack|\n' >> "$H/overrides.tsv"; ovr_sync; rs appdirect | grep -o '(?i)/Foo[^"]*' | head -1)" '(?i)/Foo\\.Bar \\(x\\)\\.app/'
eq "覆盖规则: 名字里的换行 / 竖线被拒绝 (N2)" "$(ovr_valid site "$(printf 'a.com\nx')" && echo ok || echo no):$(ovr_valid site 'a.com' && echo ok || echo no):$(ovr_valid app "$(printf 'Foo\nSite')" && echo ok || echo no):$(ovr_valid app 'Foo|x' && echo ok || echo no)" "no:ok:no:no"
eq "规则监视失败 (N13/N15): 只看本次核心启动之后的日志: 空日志 → false; 启动后有错误 → true" "$(: > "$H/sing-box.log"; rules_watch_state):$(printf "enana: core start A\nwatch rule-set file: x\n" > "$H/sing-box.log"; rules_watch_state)" "false:true"
eq "规则监视失败 (N15): 新的一次启动之后错误消失 → false (不再因为旧错误误报)" "$(printf "enana: core start B\n" >> "$H/sing-box.log"; rules_watch_state)" "false"
eq "规则监视失败 (N15): 本次启动后的错误, 之后有大量流量日志也仍为 true (不会因日志滚动漏报)" "$(printf "watch rule-set file: y\n" >> "$H/sing-box.log"; for i in $(seq 1 600); do echo "traffic $i" >> "$H/sing-box.log"; done; rules_watch_state)" "true"
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
ovr_sync; t "第 3 个固定出口也有自己的规则集 (ovr-pin-3)" test -f "$H/rules/ovr-pin-3/ovr-pin-3.json"
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
eq "bash 3.2: 导出分区声明完整, 不混入 shell 代码" "$(sed -n '/^#sections=/p' "$UW/bundle.txt")" "#sections=meta,verdict,env,config,policy,servers,apps,probes,live,health_summary,outages,health,apilog,ops,access,proxy"
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

echo "== U8. 订阅刷新 (srv_import replace): 就地更新, 顺序稳定; 内容没变的刷新不改动文件; 多个订阅只应用一次"
SF="$H/servers.jsonl"
sline() { # <角色> <订阅名 (没有就写 '')> <tag> <服务器> [端口]  -> 一行 servers.jsonl
  if [ -n "$2" ]; then printf '{"role":"%s","sub":"%s","outbound":{"type":"trojan","tag":"%s","server":"%s","server_port":%s,"password":"pw"}}\n' "$1" "$2" "$3" "$4" "${5:-443}"
  else printf '{"role":"%s","outbound":{"type":"trojan","tag":"%s","server":"%s","server_port":%s,"password":"pw"}}\n' "$1" "$3" "$4" "${5:-443}"; fi
}
srv_order() { srv_list | cut -f1 | paste -sd, -; }
pin_first() { srv_emit | awk -F'\t' '$1=="pin" {print $2; exit}'; }          # 配置生成器的默认固定出口 = pin 列表的第一个
mk_base() { # 两个订阅 (A B) 和两台手动服务器交错排列; 用户把订阅 A 的第一个节点固定成了 pin
  { sline auto '' M1 m1.example; sline pin A A-1 a1.example; sline auto A A-2 a2.example; sline auto B B-1 b1.example; sline pin '' M2 m2.example; sline auto B B-2 b2.example; sline auto A A-3 a3.example; } > "$SF"
}
a_same() { sline pin A A-1 a1.example; sline auto A A-2 a2.example; sline auto A A-3 a3.example; }       # 订阅 A 没变的内容 (和 mk_base 里存的一模一样)
b_same() { sline auto B B-1 b1.example; sline auto B B-2 b2.example; }
stray() { ls "$SF.new" "$SF.tags" "$SF.pairs" "$SF.counts" "$SF.new.2" 2>/dev/null | wc -l | tr -d ' '; }
rm -f "$H"/servers.sync "$H"/subs.sync
mk_base; cp "$SF" "$UW/before"
res=$(a_same | srv_import A replace)
eq "订阅 A 内容完全相同的刷新: servers.jsonl 一个字节都没变 (以前 A 的行被挪到文件末尾)" "$(cmp -s "$SF" "$UW/before" && echo same || echo changed)" "same"
eq "…计数: 0 新增 · 3 保留 (replaced) · 0 移除 —— 导入的调用方用「新增 + 保留 > 0」判断有没有有效节点" "$res" "0 3 0"
res=$(b_same | srv_import B replace)
eq "订阅 B 同样: 文件不变, 0 2 0" "$(cmp -s "$SF" "$UW/before" && echo same):$res" "same:0 2 0"
eq "…文件里的顺序不变 (手动服务器和两个订阅交错), 默认固定出口仍是 A-1 (以前会变成 M2, 生成出不同的配置)" "$(srv_order):$(pin_first)" "M1,A-1,A-2,B-1,M2,B-2,A-3:A-1"
res=$({ sline auto A A-3 a3.example; sline pin A A-1 a1.example; sline auto A A-2 a2.example; } | srv_import A replace)
eq "订阅端调整了节点顺序: 已有节点保持原来的位置 (文件不变)" "$(cmp -s "$SF" "$UW/before" && echo same):$res" "same:0 3 0"
eq "…没有留下临时文件; 文件权限 600" "$(stray):$(stat -f %Lp "$SF")" "0:600"

mk_base
res=$({ sline pin A A-1 a1.example; sline auto A A-2 a2-NEW.example 8443; sline auto A A-3 a3.example; } | srv_import A replace)
eq "A-2 的服务器 / 端口变了: 原地覆盖 (仍在第 3 行), 其它每一行都原样不动" "$(sed -n 3p "$SF" | grep -c 'a2-NEW.example.*8443'):$(diff <(sed 3d "$UW/before") <(sed 3d "$SF") >/dev/null && echo rest-same):$res" "1:rest-same:0 3 0"
eq "…顺序不变" "$(srv_order)" "M1,A-1,A-2,B-1,M2,B-2,A-3"

mk_base
res=$({ sline pin A A-1 a1.example; sline auto A A-3 a3.example; sline auto A A-4 a4.example; } | srv_import A replace)
eq "A-2 从订阅里消失、A-4 新增: A-2 的行删掉, A-4 追加到末尾, 手动服务器和订阅 B 的位置不动" "$(srv_order)" "M1,A-1,B-1,M2,B-2,A-3,A-4"
eq "…计数: 1 新增 · 2 保留 · 1 移除" "$res" "1 2 1"
eq "…别的来源的行原样保留 (M1 M2 B-1 B-2)" "$(grep -c '"tag":"M1"\|"tag":"M2"\|"tag":"B-1"\|"tag":"B-2"' "$SF")" "4"

mk_base
res=$({ sline auto A A-1 a1.example; sline auto A M1 m1-via-sub.example; } | srv_import A replace)
eq "订阅里的 tag 和手动服务器重名: 就地换成订阅的版本 (和 merge 一样「后来者取代」), 位置不变, 不会出现两行" "$(srv_order):$(sed -n 1p "$SF" | grep -c '"sub":"A".*m1-via-sub.example')" "M1,A-1,B-1,M2,B-2:1"
eq "…计数: 0 新增 · 2 保留 (A-1 和 M1) · 2 移除 (A-2 A-3)" "$res" "0 2 2"

mk_base
res=$({ sline auto A A-1 first.example; sline auto A A-1 second.example; sline auto A N-1 n.example; } | srv_import A replace)
eq "同一批里 tag 重复: 只留一行 (后一行的内容), 位置是已有的那一行" "$(srv_order):$(grep -c second.example "$SF"):$(grep -c first.example "$SF")" "M1,A-1,B-1,M2,B-2,N-1:1:0"
eq "…计数: 1 新增 · 2 保留 (重复的算一次替换) · 2 移除" "$res" "1 2 2"

mk_base
res=$({ sline pin A A-1 a1.example; printf 'garbage\n'; sline auto A A-2 a2.example; } | srv_import A replace 2>"$UW/imp.err")
eq "格式不对的行被忽略并报行号, 其余照常导入 (A-3 不在新数据里 → 移除)" "$(grep -c '第 2 行' "$UW/imp.err"):$res:$(srv_order)" "1:0 2 1:M1,A-1,A-2,B-1,M2,B-2"
mk_base; cp "$SF" "$UW/before"
JOB_BODY="$UW/jobbody"; printf 'garbage\n' > "$JOB_BODY"; printf 'A|https://a.example/s|0|3|12|0|0|0\n' > "$H/subs.tsv"
txn_import A replace; rc=$?
eq "txn_import: 整批都不合格 → 失败 (op_txn 据此回滚, 保留旧节点)" "$rc" "1"
a_same > "$JOB_BODY"; mk_base; txn_import A replace; rc=$?
eq "txn_import: 内容完全相同的刷新 → 成功 (「保留」的节点也算有效), 文件不变" "$rc:$(cmp -s "$SF" "$UW/before" && echo same)" "0:same"

mk_base; res=$(sline pin '' M1 m1-new.example | srv_import '' merge)
eq "merge (添加服务器 / 保存 VPS) 行为不变: 已有的 tag 被取代、新行追加到末尾, 计数 0 1 0" "$(srv_order):$res" "A-1,A-2,B-1,M2,B-2,A-3,M1:0 1 0"
mk_base; res=$(a_same | srv_import A merge)
eq "merge 带订阅名也不变 (只有 replace 才就地合并): A 的三行被重新追加到末尾" "$(srv_order):$res" "M1,B-1,M2,B-2,A-1,A-2,A-3:0 3 0"
rm -f "$SF"; res=$(b_same | srv_import B replace)
eq "还没有 servers.jsonl: 创建, 节点按订阅顺序, 2 0 0, 权限 600" "$(srv_order):$res:$(stat -f %Lp "$SF")" "B-1,B-2:2 0 0:600"
mk_base; cp "$SF" "$UW/before"; cp "$SF" "$UW/plan"
res=$({ sline pin A A-1 a1.example; sline auto A A-9 a9.example; } | SRV_FILE="$UW/plan" srv_import A replace)
eq "干跑 (SRV_FILE 副本, 仪表盘预览数量用): 计数 1 1 2, 真实文件没动, 没有临时文件留下" "$res:$(cmp -s "$SF" "$UW/before" && echo real-same):$(ls "$UW"/plan.* 2>/dev/null | wc -l | tr -d ' ')" "1 1 2:real-same:0"
eq "…干跑的副本里 A-9 追加在末尾, A-2 A-3 已移除" "$(sed -n 's/.*"tag":"\([^"]*\)".*/\1/p' "$UW/plan" | paste -sd, -)" "M1,A-1,B-1,M2,B-2,A-9"
mk_base; : > "$H/servers.sync"
a_same | SRV_SAVE=1 srv_import A replace >/dev/null
eq "「保存到云端」(SRV_SAVE=1): 订阅的全部节点和订阅名进入同步清单 (刷新后也一样)" "$(sort "$H/servers.sync" | paste -sd, -):$(cat "$H/subs.sync")" "A-1,A-2,A-3:A"
a_same | SRV_SAVE=0 srv_import A replace >/dev/null
eq "…SRV_SAVE=0 把它们从清单里去掉" "$(grep -c . "$H/servers.sync" || true):$(grep -c . "$H/subs.sync" || true)" "0:0"
rm -f "$H/servers.sync" "$H/subs.sync"

# 命令行 / 定时刷新用导入器的默认角色 (auto) 解析订阅: srv_keep_roles 把订阅里已有节点的角色带回来, 否则用户固定的出口会被悄悄改回自动
mk_base
out=$({ sline auto A A-1 a1.example; sline auto A A-2 a2.example; sline auto A N-9 n9.example; sline auto A B-1 b1.example; } | srv_keep_roles A)
eq "srv_keep_roles: 已有节点沿用现在的角色 (A-1=pin), 新节点保持 auto, 其它订阅的同名节点 (B-1) 不受影响" "$(printf '%s\n' "$out" | sed -n 's/^{"role":"\([a-z]*\)".*"tag":"\([^"]*\)".*/\2=\1/p' | paste -sd, -)" "A-1=pin,A-2=auto,N-9=auto,B-1=auto"
eq "…除了角色, 每一行都原样 (订阅名 / 出站内容不变)" "$(printf '%s\n' "$out" | sed 's/^{"role":"[a-z]*"//')" "$({ sline auto A A-1 a1.example; sline auto A A-2 a2.example; sline auto A N-9 n9.example; sline auto A B-1 b1.example; } | sed 's/^{"role":"[a-z]*"//')"

# op_subs_refresh: 先全部下载解析, 再「一个」事务里导入并应用一次; 内容没变的刷新不改动配置
(
  SUBFIX="$UW/subfix"; rm -rf "$SUBFIX"; mkdir -p "$SUBFIX"
  APPLY_OK=0; APPLIED="$UW/applied"; ORDER_LOG="$UW/refresh.out"
  sub_fetch() { case $1 in *b.example*) [ ! -f "$SUBFIX/b.fail" ] || return 1 ;; esac; echo x > "$3"; printf 'HTTP/1.1 200 OK\r\nsubscription-userinfo: upload=1; download=10; total=100; expire=2000000000\r\n' > "$4"; }
  os_import_subscription() { cat "$SUBFIX/$3.jsonl" 2>/dev/null; }                  # 导入器给的角色一律是 auto
  apply_config() { # 假的应用: 只要服务器文件和上次应用时不一样就算「配置变了」; 出现 POISON 节点就像 sing-box check 不通过一样失败
    if grep -q POISON "$H/servers.jsonl"; then return 1; fi
    APPLY_OK=$((APPLY_OK + 1)); if cmp -s "$H/servers.jsonl" "$APPLIED"; then APPLY_CHANGED=0; else APPLY_CHANGED=1; cp "$H/servers.jsonl" "$APPLIED"; fi; return 0
  }
  fixtures_same() { { sline auto A A-1 a1.example; sline auto A A-2 a2.example; sline auto A A-3 a3.example; } > "$SUBFIX/A.jsonl"; b_same > "$SUBFIX/B.jsonl"; }
  fresh_state() { mk_base; cp "$SF" "$APPLIED"; APPLY_OK=0; fixtures_same; rm -f "$SUBFIX/b.fail"
    printf 'A|https://a.example/s|0|3|12|0|0|0\nB|https://b.example/s|0|2|12|0|0|0\nC|https://c.example/s|%s|1|12|0|0|0\n' "$(now)" > "$H/subs.tsv"; rmdir "$H/.apply.lock" 2>/dev/null || true; }
  touched() { awk -F'|' -v n="$1" '$1==n {print ($3 > 0 ? "yes" : "no")}' "$H/subs.tsv"; }
  fresh_state; cp "$SF" "$UW/before"
  SUBS_APPLIED=x; op_subs_refresh 1 > "$ORDER_LOG" 2>&1
  eq "两个订阅都过期、内容没变: 一次应用 (以前每个订阅各一次, 调用方随后又一次); servers.jsonl 一个字节没变" "$APPLY_OK:$SUBS_APPLIED:$(cmp -s "$SF" "$UW/before" && echo same)" "1:1:same"
  eq "…用户固定的角色保留 (A-1 仍是 pin; 导入器给的是 auto); 刚刷新过的订阅 C 没有被重新下载" "$(srv_list | awk -F'\t' '$1=="A-1" {print $5}'):$(grep -c '订阅「C」' "$ORDER_LOG" || true)" "pin:0"
  eq "…两个订阅的刷新时间 / 节点数都记下了 (A B 已刷新, 节点数 3 和 2)" "$(touched A)$(touched B):$(awk -F'|' '$1=="A" {print $4} $1=="B" {print $4}' "$H/subs.tsv" | paste -sd, -)" "yesyes:3,2"
  eq "…操作记录里是一条合并的事务 (订阅刷新), 不是每个订阅一条" "$(cat "$LOGS"/ops-*.log 2>/dev/null | grep -c '订阅刷新 (2 个)')" "1"
  eq "…终端输出每个订阅一行「已刷新」" "$(grep -c '已刷新' "$ORDER_LOG")" "2"

  fresh_state
  { sline auto A A-1 a1-NEW.example; sline auto A A-2 a2.example; sline auto A A-3 a3.example; sline auto A A-4 a4.example; } > "$SUBFIX/A.jsonl"
  { sline auto B B-1 b1.example; sline auto B B-2 b2-NEW.example; } > "$SUBFIX/B.jsonl"
  op_subs_refresh 1 > "$ORDER_LOG" 2>&1
  eq "两个订阅都有变化: 仍然只应用一次, 节点在原来的位置上更新 (顺序不变, 新节点追加)" "$APPLY_OK:$APPLY_CHANGED:$(srv_order)" "1:1:M1,A-1,A-2,B-1,M2,B-2,A-3,A-4"
  eq "…A-1 内容更新但角色仍是 pin; B-2 更新" "$(srv_list | awk -F'\t' '$1=="A-1" {print $3 "/" $5} $1=="B-2" {print $3}' | paste -sd, -)" "a1-NEW.example/pin,b2-NEW.example"

  fresh_state; awk -F'|' -v t="$(now)" 'BEGIN{OFS="|"} $1=="A" {$3=t} {print}' "$H/subs.tsv" > "$H/subs.tsv.x" && mv "$H/subs.tsv.x" "$H/subs.tsv"
  op_subs_refresh 1 > "$ORDER_LOG" 2>&1
  eq "只有一个订阅过期: 仍然是一次应用 (走单个订阅的事务)" "$APPLY_OK:$SUBS_APPLIED:$(touched B)" "1:1:yes"
  fresh_state; awk -F'|' -v t="$(now)" 'BEGIN{OFS="|"} {$3=t; print}' "$H/subs.tsv" > "$H/subs.tsv.x" && mv "$H/subs.tsv.x" "$H/subs.tsv"
  op_subs_refresh 1 > "$ORDER_LOG" 2>&1
  eq "没有订阅过期: 什么都不做 (没有下载, 没有应用)" "$APPLY_OK:$SUBS_APPLIED" "0:0"
  fresh_state; sline auto C C-1 c1.example > "$SUBFIX/C.jsonl"; op_subs_refresh 0 > "$ORDER_LOG" 2>&1
  eq "不限过期 (enana update): 三个订阅都刷新, 仍是一次应用" "$APPLY_OK:$(grep -c '已刷新' "$ORDER_LOG")" "1:3"

  fresh_state; touch "$SUBFIX/b.fail"
  op_subs_refresh 1 > "$ORDER_LOG" 2>&1
  eq "某个订阅下载失败: 它的旧节点保留, 其它订阅照常刷新并应用" "$(grep -c '订阅「B」刷新失败' "$ORDER_LOG"):$APPLY_OK:$SUBS_APPLIED:$(touched A)$(touched B)" "1:1:1:yesno"

  fresh_state
  { sline auto A A-1 a1.example; sline auto A A-2 a2-NEW.example; sline auto A A-3 a3.example; } > "$SUBFIX/A.jsonl"
  { sline auto B B-1 b1.example; sline auto B POISON b-bad.example; } > "$SUBFIX/B.jsonl"
  op_subs_refresh 1 > "$ORDER_LOG" 2>&1
  eq "合并的事务没通过 (订阅 B 的节点让配置无效): 整体回滚, 再逐个订阅重试 —— A 照常刷新, B 保留旧节点" "$(grep -c POISON "$SF"):$(grep -c a2-NEW.example "$SF"):$(grep -c 'b2.example' "$SF"):$SUBS_APPLIED" "0:1:1:1"
  eq "…B 的提示是「刷新后配置无效, 已保留旧节点」, 顺序没乱" "$(grep -c '订阅「B」刷新后配置无效' "$ORDER_LOG"):$(srv_order)" "1:M1,A-1,A-2,B-1,M2,B-2,A-3"
)

# 每日维护: 订阅那一步已经成功应用过配置 (带上了刚下载的规则集), 就不再单独应用一遍; 没有应用过才补一次
(
  logs_maintain() { :; }; stats_purge() { :; }; update_check() { :; }; auth_logged_in() { return 1; }
  AUTO_UPDATE=1; AC=0; rules_update() { :; }; apply_config() { AC=$((AC + 1)); return 0; }
  op_subs_refresh() { SUBS_APPLIED=$FAKE_APPLIED; }
  rm -f "$H/.maintain-rules"; FAKE_APPLIED=1; op_maintain
  eq "订阅刷新已经应用过 → 维护不再重复应用" "$AC" "0"
  rm -f "$H/.maintain-rules"; FAKE_APPLIED=0; op_maintain
  eq "订阅没有应用过 (没有订阅要刷新 / 没刷新成功) → 维护应用一次, 把刚下载的规则集带上" "$AC" "1"
  FAKE_APPLIED=0; op_maintain
  eq "3 天内刚做过: 什么都不做" "$AC" "1"
)
t "install.sh 的 enana update 同样: 订阅刷新应用过配置就不再 op_apply" grep -q 'SUBS_APPLIED' "$REPO/install.sh"
echo

echo "== U7. 仪表盘静态检查 (控制台报错的回归保护)"
t "仪表盘不会自动去访问第三方网站查 IP (ipify / ipinfo): 出口 IP 由本机辅助服务查, 浏览器里不再出现 ERR_CONNECTION_RESET" sh -c "! grep -nE 'api\\.ipify\\.org|ipinfo\\.io' '$REPO'/ui/*.js"
t "v-vps.js: 重置错误提示时只对有 setErr 的项调用 (「保存到云端」勾选框不是输入项; 以前这里抛 TypeError, 「添加自己的服务器」面板打不开)" grep -q 'b\[k\] && b\[k\].setErr' "$REPO/ui/v-vps.js"
t "页面声明了标签页图标, 文件都在" sh -c "grep -q 'rel=\"icon\"' '$REPO/ui/index.html' && test -s '$REPO/ui/favicon.svg' && test -s '$REPO/ui/favicon.png'"
echo "== U9. 官方线路 (会员): 云端响应整理 · 与用户服务器分开 · 只进自动线路池 · 没变化不重启 · 失败退避 / 宽限期 / 退出清除"
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
echo "== U10. 规则集目录布局: 迁移是复制 (旧文件留给回滚) · 清理只删有副本的旧文件 · 自定义规则集删除不会越出 rules/"
mig=$(H=$UW/mig; rm -rf "$H"; mkdir -p "$H/rules/ovr-auto"; printf 'OLD' > "$H/rules/geosite-cn.srs"; printf 'PIN' > "$H/rules/ovr-pin.json"; printf 'NEW' > "$H/rules/ovr-auto/ovr-auto.json"; printf 'STALE' > "$H/rules/ovr-auto.json"; touch -t 202001010000 "$H/rules/geosite-cn.srs" "$H/rules/ovr-pin.json" "$H/rules/ovr-auto.json"; touch -t 202601010000 "$H/rules/ovr-auto/ovr-auto.json"; rules_layout_migrate; echo "$(cat "$H/rules/geosite-cn/geosite-cn.srs"):$(cat "$H/rules/ovr-pin/ovr-pin.json"):$(cat "$H/rules/ovr-auto/ovr-auto.json"):$(ls "$H"/rules/*.srs "$H"/rules/ovr-*.json 2>/dev/null | wc -l | tr -d ' ')")
eq "迁移: 平铺的规则集复制到 rules/<名字>/; 新位置里更新的文件保留; 平铺的旧文件不删 (回滚还要用)" "$mig" "OLD:PIN:NEW:3"
eq "迁移重复执行: 不覆盖更新过的副本" "$(H=$UW/mig; printf 'EDIT' > "$H/rules/geosite-cn/geosite-cn.srs"; touch -t 202602010000 "$H/rules/geosite-cn/geosite-cn.srs"; rules_layout_migrate; cat "$H/rules/geosite-cn/geosite-cn.srs")" "EDIT"
mf=$(H=$UW/mfail; rm -rf "$H"; mkdir -p "$H/rules"; printf 'OLD' > "$H/rules/geosite-cn.srs"; printf 'file' > "$H/rules/geosite-cn"; rules_layout_migrate 2>/dev/null; echo "rc=$?:$(cat "$H/rules/geosite-cn.srs")")
eq "迁移失败 (新位置被占用): 返回 1, 旧文件原样保留 (gen_config 据此放弃生成新配置)" "$mf" "rc=1:OLD"
pr=$(H=$UW/prune; rm -rf "$H"; mkdir -p "$H/rules/newer"; printf 'A' > "$H/rules/nocopy.srs"; printf 'N' > "$H/rules/newer.srs"; printf 'OLDCOPY' > "$H/rules/newer/newer.srs"; touch -t 202001010000 "$H/rules/newer/newer.srs"; touch -t 202601010000 "$H/rules/newer.srs"; rules_layout_prune; echo "$(test -f "$H/rules/nocopy.srs" && echo nocopy-kept):$(test -f "$H/rules/newer.srs" && echo newer-kept)")
eq "清理: 没有副本的旧文件保留; 比副本新的旧文件保留 (副本可能是过期的)" "$pr" "nocopy-kept:newer-kept"
pm=$(H=$UW/mig2; rm -rf "$H"; mkdir -p "$H/rules/ovr-auto"; printf 'OLD' > "$H/rules/geosite-cn.srs"; printf 'NEW' > "$H/rules/ovr-auto/ovr-auto.json"; printf 'STALE' > "$H/rules/ovr-auto.json"; touch -t 202001010000 "$H/rules/geosite-cn.srs" "$H/rules/ovr-auto.json"; touch -t 202601010000 "$H/rules/ovr-auto/ovr-auto.json"; rules_layout_migrate; rules_layout_prune; echo "$(ls "$H"/rules/*.srs "$H"/rules/ovr-*.json 2>/dev/null | wc -l | tr -d ' '):$(cat "$H/rules/geosite-cn/geosite-cn.srs"):$(cat "$H/rules/ovr-auto/ovr-auto.json")")
eq "成功启动后清理: 平铺的旧文件删掉, 副本内容不变" "$pm" "0:OLD:NEW"
del=$(H=$UW/cdel; mkdir -p "$H/rules/custom-a" "$H/rules/custom-x"; printf 'a|A|pin|0|https://example.invalid/a.srs\nx/../..|X|pin|0|https://example.invalid/x.srs\n' > "$H/custom-rulesets.tsv"; printf 'SRS' > "$H/rules/custom-a/custom-a.srs"; printf 'keep' > "$H/keep.txt"; custom_rs_delete 'x/../..'; echo "rc=$?:$(cat "$H/keep.txt"):$(wc -l < "$H/custom-rulesets.tsv" | tr -d ' ')"; custom_rs_delete a; echo "rc=$?:$(test -e "$H/rules/custom-a" && echo y || echo n):$(wc -l < "$H/custom-rulesets.tsv" | tr -d ' ')")
eq "自定义规则集删除: 登记里的路径名 (x/../..) 被拒绝, 什么都不删; 合法名字删掉目录和登记" "$del" $'rc=1:keep:2\nrc=0:n:1'
echo
echo "== U11. apply_config 启动失败路径: 系统代理先关 (不弹框, 应用不再连已停止的代理) · 旧规则集文件保留到确认启动成功 · 迁移失败不写新配置"
apply_mocks() {
  load_settings() { :; }
  ovr_sync() { :; }
  gen_config() { printf '{"new":1}' > "$H/config.json.new"; }
  proxy_sync_mode() { echo proxy_sync >> "$LOG"; }
  os_service_loaded() { return "${LOADED_RC:-0}"; }
  os_service_running() { return "${RUNNING_RC:-0}"; }
  os_service_pid() { echo 123; }
  os_service_restart() { echo restart >> "$LOG"; return "${RESTART_RC:-0}"; }
  wait_port() { echo "wait $2" >> "$LOG"; return "${WAIT_RC:-0}"; }
  enhanced_ready() { return 0; }
  enhanced_configured() { return 1; }
  tun_residual_clean() { echo cleanup >> "$LOG"; }
  os_sysproxy_mine() { return "${MINE_RC:-1}"; }
  os_sysproxy_apply() { echo "apply $*" >> "$LOG"; return "${APPLY_RC:-0}"; }
  sysproxy_record() { echo "record $*" >> "$LOG"; }
  SB=/usr/bin/true; APPLY_QUIET=1
}
apply_run() { # 名字 [变量=值 ...] -> rc|调用顺序|配置|平铺旧文件|警告
  local name=$1; shift
  (
    H=$UW/ap-$name; rm -rf "$H"; mkdir -p "$H/rules/geosite-cn"
    printf '{"old":1}' > "$H/config.json"
    printf 'OLD' > "$H/rules/geosite-cn.srs"; printf 'OLD' > "$H/rules/geosite-cn/geosite-cn.srs"
    touch -t 202001010000 "$H/rules/geosite-cn.srs" "$H/rules/geosite-cn/geosite-cn.srs"
    NETWORK_MODE=system; unset OP_WHO
    [ $# -gt 0 ] && export "$@"
    . "$LIB/config.sh"; apply_mocks
    LOG=$UW/ap-$name.log; : > "$LOG"
    rc=0; out=$(apply_config 2>&1) || rc=$?
    printf '%s|%s|%s|%s|%s\n' "$rc" "$(paste -sd';' "$LOG")" "$(cat "$H/config.json")" \
      "$([ -f "$H/rules/geosite-cn.srs" ] && echo kept || echo pruned)" \
      "$(printf '%s' "$out" | grep -Eo '已先关闭|没能自动关闭' | paste -sd',' -)"
  )
}
eq "启动成功: 配置换成新的; 启动确认之后才清理平铺的旧规则集文件" "$(apply_run ok)" '0|restart;wait 15;proxy_sync|{"new":1}|pruned|'
eq "新核心没起来, 旧核心还活着 (授权取消后已回滚): 不重启, 系统代理不动, 旧规则集文件保留" "$(apply_run alive RESTART_RC=1)" '3|restart;wait 2;proxy_sync|{"old":1}|kept|'
eq "…旧核心还活着且系统代理指向 enana: 端口仍通, 不关系统代理" "$(apply_run alive2 RESTART_RC=1 MINE_RC=0)" '3|restart;wait 2;proxy_sync;wait 1|{"old":1}|kept|'
eq "核心没起来 + 系统代理指向 enana: 先静默关闭系统代理 (应用不再连已停止的代理), 记入操作记录, 提示用户" "$(apply_run down RESTART_RC=1 WAIT_RC=1 RUNNING_RC=1 MINE_RC=0)" '3|restart;cleanup;restart;wait 15;cleanup;proxy_sync;wait 1;apply off quiet;record auto off 0|{"old":1}|kept|已先关闭'
eq "核心没起来 + 系统代理关不掉 (需要管理员授权): 记入操作记录 (off 1), 提示去仪表盘关闭" "$(apply_run stuck RESTART_RC=1 WAIT_RC=1 RUNNING_RC=1 MINE_RC=0 APPLY_RC=1)" '3|restart;cleanup;restart;wait 15;cleanup;proxy_sync;wait 1;apply off quiet;record auto off 1|{"old":1}|kept|没能自动关闭'
eq "核心没起来 + 系统代理不是 enana 的: 不碰系统代理" "$(apply_run other RESTART_RC=1 WAIT_RC=1 RUNNING_RC=1 MINE_RC=1)" '3|restart;cleanup;restart;wait 15;cleanup;proxy_sync|{"old":1}|kept|'
eq "TUN 模式核心没起来 + 系统代理指向 enana: 同样先静默关闭系统代理 (指向死端口的代理会断网)" "$(apply_run tun NETWORK_MODE=tun RESTART_RC=1 WAIT_RC=1 RUNNING_RC=1 MINE_RC=0)" '3|restart;cleanup;restart;wait 15;cleanup;proxy_sync;wait 1;apply off quiet;record auto off 0|{"old":1}|kept|已先关闭'
eq "TUN 模式核心没起来 + 系统代理关不掉: 记入操作记录 (off 1), 提示去仪表盘关闭" "$(apply_run tunstuck NETWORK_MODE=tun RESTART_RC=1 WAIT_RC=1 RUNNING_RC=1 MINE_RC=0 APPLY_RC=1)" '3|restart;cleanup;restart;wait 15;cleanup;proxy_sync;wait 1;apply off quiet;record auto off 1|{"old":1}|kept|没能自动关闭'
eq "服务没有加载 (还没启动核心): 只写配置, 不重启, 不清理旧文件" "$(apply_run noload LOADED_RC=1)" '0||{"new":1}|kept|'
gcf=$(H=$UW/gcfail; rm -rf "$H"; mkdir -p "$H/rules"; printf 'file' > "$H/rules/geosite-cn"; printf 'OLD' > "$H/rules/geosite-cn.srs"; printf '{"old":1}' > "$H/config.json"; . "$LIB/config.sh"; sb_ver() { :; }; dns_load() { :; }; srv_emit() { :; }; official_emit() { :; }; NETWORK_MODE=system; rc=0; out=$(gen_config 2>&1) || rc=$?; echo "rc=$rc|$(test -e "$H/config.json.new" && echo new-written || echo no-new)|$(cat "$H/config.json")|$(printf '%s' "$out" | grep -c '规则集目录整理失败')")
eq "规则集迁移失败 (新位置被占用): gen_config 返回 1, 不写新配置, 原配置不动, 给出提示" "$gcf" 'rc=1|no-new|{"old":1}|1'
echo
echo "== U12. 核心升级 (op_core_upgrade): 先在临时端口试运行新核心, 通过才重启; 失败时还原旧二进制、清残留 TUN 路由; 试运行失败不碰服务和系统代理"
upg_run() { # 名字 [变量=值 ...] -> rc|调用顺序|警告|当前二进制 (old/new)
  local name=$1; shift
  (
    H=$UW/up-$name; rm -rf "$H"; mkdir -p "$H"; SB=$H/sing-box
    printf '#!/bin/sh\n# OLD\nexit 0\n' > "$SB"; chmod +x "$SB"; printf '{"old":1}' > "$H/config.json"
    NETWORK_MODE=system; unset OP_WHO
    [ $# -gt 0 ] && export "$@"
    core_version() { echo 1.14.2; }; job_step() { :; }; update_check() { :; }; proxy_sync_mode() { :; }
    core_install() { # 新核心带 NEW 标记; CHECK_RC 控制它的 check 子命令; STOP_IN_INSTALL 模拟 Windows 替换前先停掉核心
      [ -z "${STOP_IN_INSTALL:-}" ] || WAIT_RC=1
      [ "${INSTALL_RC:-0}" = 0 ] || return 1
      printf '#!/bin/sh\n# NEW\n[ "$1" = check ] && exit "${CHECK_RC:-0}"\nexit 0\n' > "$SB"; chmod +x "$SB"
    }
    core_trial() { echo trial >> "$LOG"; return "${TRIAL_RC:-0}"; }
    os_service_restart() { echo restart >> "$LOG"; [ -z "${UP_AFTER_RESTART:-}" ] || WAIT_RC=0; return "${RESTART_RC:-0}"; }
    wait_port() { echo "wait $2" >> "$LOG"; return "${WAIT_RC:-0}"; }
    tun_residual_clean() { echo cleanup >> "$LOG"; }
    enhanced_ready() { return 0; }
    os_sysproxy_mine() { return "${MINE_RC:-1}"; }
    os_sysproxy_apply() { echo "apply $*" >> "$LOG"; return "${APPLY_RC:-0}"; }
    sysproxy_record() { echo "record $*" >> "$LOG"; }
    oplog() { :; }; _txn_end() { echo "txn $1${3:+ $3}" >> "$LOG"; echo "$2"; }
    LOG=$UW/up-$name.log; : > "$LOG"
    [ -z "${BACKUP_FAIL:-}" ] || chmod 500 "$H"
    rc=0; out=$(op_core_upgrade 1.14.3 2>&1) || rc=$?
    chmod 700 "$H"
    printf '%s|%s|%s|%s\n' "$rc" "$(paste -sd';' "$LOG")" "$(printf '%s' "$out" | grep -Eo '已先关闭|没能自动关闭|没能自动启动' | paste -sd',' -)" "$(grep -q '# NEW' "$SB" && echo new || echo old)"
  )
}
eq "核心升级成功: 试运行通过 → 才重启 → 新二进制保留" "$(upg_run ok)" '0|wait 1;trial;restart;wait 15;txn ok||new'
eq "新核心试运行没通过 (临时端口没起来): 不重启、不动系统代理, 还原旧二进制, 失败码 3" "$(upg_run trialfail TRIAL_RC=1 MINE_RC=0 WAIT_RC=1)" '1|wait 1;trial;txn fail 3||old'
eq "…TUN 模式同样: 服务和系统代理都不碰" "$(upg_run trialtun NETWORK_MODE=tun TRIAL_RC=1 MINE_RC=0 WAIT_RC=1)" '1|wait 1;trial;txn fail 3||old'
eq "新核心 check 不通过 (不能加载现有配置): 不试运行, 还原旧二进制, 失败码 2" "$(upg_run checkfail CHECK_RC=1)" '1|wait 1;wait 1;txn fail 2||old'
eq "下载失败: 不试运行, 不重启, 失败码 1" "$(upg_run dlfail INSTALL_RC=1)" '1|wait 1;wait 1;txn fail 1||old'
eq "新核心重启后没就绪 (TUN): 清残留路由 → 还原旧二进制 → 重启旧核心 → 再清一次 → 关系统代理, 失败码 4" "$(upg_run tun NETWORK_MODE=tun RESTART_RC=1 WAIT_RC=1 MINE_RC=0)" '1|wait 1;trial;restart;cleanup;restart;wait 15;cleanup;wait 1;apply off quiet;record auto off 0;txn fail 4|已先关闭|old'
eq "…系统代理模式: 同上" "$(upg_run sys RESTART_RC=1 WAIT_RC=1 MINE_RC=0)" '1|wait 1;trial;restart;cleanup;restart;wait 15;cleanup;wait 1;apply off quiet;record auto off 0;txn fail 4|已先关闭|old'
eq "…系统代理关不掉 (需要管理员授权): 记入操作记录 (off 1), 提示去仪表盘关闭" "$(upg_run stuck NETWORK_MODE=tun RESTART_RC=1 WAIT_RC=1 MINE_RC=0 APPLY_RC=1)" '1|wait 1;trial;restart;cleanup;restart;wait 15;cleanup;wait 1;apply off quiet;record auto off 1;txn fail 4|没能自动关闭|old'
eq "…旧核心还活着 (端口通): 不关系统代理" "$(upg_run alive NETWORK_MODE=tun RESTART_RC=1 WAIT_RC=0 MINE_RC=0)" '1|wait 1;trial;restart;cleanup;restart;wait 15;cleanup;wait 1;txn fail 4||old'
eq "…系统代理不是 enana 的: 不碰系统代理" "$(upg_run other NETWORK_MODE=tun RESTART_RC=1 WAIT_RC=1 MINE_RC=1)" '1|wait 1;trial;restart;cleanup;restart;wait 15;cleanup;txn fail 4||old'
eq "重启成功但 15 秒内端口不通 (TUN): 同样回退" "$(upg_run notready NETWORK_MODE=tun WAIT_RC=1 MINE_RC=0)" '1|wait 1;trial;restart;wait 15;cleanup;restart;wait 15;cleanup;wait 1;apply off quiet;record auto off 0;txn fail 4|已先关闭|old'
eq "核心没在运行时升级失败: 不拉起服务 (用户停掉的服务不能被升级顺手启动)" "$(upg_run stopdl WAIT_RC=1 INSTALL_RC=1)" '1|wait 1;txn fail 1||old'
eq "升级前在运行, 替换时核心被停掉 (Windows), 随后失败: 拉起旧核心, 报告保持原版本" "$(upg_run winrevive STOP_IN_INSTALL=1 INSTALL_RC=1 UP_AFTER_RESTART=1)" '1|wait 1;wait 1;restart;wait 15;txn fail 1||old'
eq "…旧核心也拉不起来: 报告请手动启动" "$(upg_run winfail STOP_IN_INSTALL=1 INSTALL_RC=1)" '1|wait 1;wait 1;restart;wait 15;txn fail 1|没能自动启动|old'
eq "备份旧核心失败: 不下载、不替换、不碰服务" "$(upg_run nobackup BACKUP_FAIL=1)" '1|wait 1;txn fail 1||old'
echo
echo "== U13. 核心试运行 (core_trial): 副本换成临时端口、临时缓存和日志, 去掉 TUN 入站与系统代理开关 → 不改动 config.json, 不写正式的缓存和日志"
TR=$UW/trial; rm -rf "$TR"; mkdir -p "$TR"
cat > "$TR/fake-sb" <<'PY'
#!/usr/bin/env python3
# 假的 sing-box: 只检查 core_trial 生成的副本是否合规; 合规就在 external_controller 上提供带令牌的 /version
import http.server, json, os, socket, sys
if sys.argv[1:2] != ['run']: sys.exit(0)
path = sys.argv[sys.argv.index('-c') + 1]
cfg = json.load(open(path))
def fail(msg):
    print('fake-sb: ' + msg, file=sys.stderr); sys.exit(1)
if os.environ.get('FAKE_CRASH'): fail('crash on start')
inb = cfg.get('inbounds', [])
tags = {i.get('tag') for i in inb}
for i in inb:
    if i.get('type') == 'tun': fail('tun inbound left in trial config')
    if 'set_system_proxy' in i: fail('set_system_proxy left in trial config')
    if 'listen_port' in i:
        s = socket.socket()
        try: s.bind((i.get('listen', '127.0.0.1'), i['listen_port']))
        except OSError as e: fail('port %s unavailable: %s' % (i['listen_port'], e))
        finally: s.close()
if 'output' in cfg.get('log', {}): fail('log.output left in trial config')
cache = cfg.get('experimental', {}).get('cache_file', {}).get('path')
if cache and not cache.startswith(os.path.dirname(path) + os.sep): fail('cache file outside trial dir: ' + cache)
def check_rules(rules):
    for r in rules or []:
        if not isinstance(r, dict): continue
        v = r.get('inbound', [])
        for t in (v if isinstance(v, list) else [v]):
            if t not in tags: fail('rule refers to missing inbound %r' % t)
        check_rules(r.get('rules'))
for sec in ('route', 'dns'):
    check_rules(cfg.get(sec, {}).get('rules'))
api = cfg['experimental']['clash_api']
host, port = api['external_controller'].rsplit(':', 1)
secret = api.get('secret', '')
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != '/version': return self.reply(404, b'')
        if self.headers.get('Authorization') != 'Bearer ' + secret: return self.reply(401, b'')
        self.reply(200, b'{"version":"fake"}')
    def reply(self, code, body):
        self.send_response(code); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer((host, int(port)), Handler).serve_forever()
PY
cat > "$TR/mkcfg.py" <<'PY'
import json, sys
# mkcfg.py <H> <混合端口> api|noapi: 正式配置 (有 TUN 入站、系统代理开关、日志文件、缓存文件, 规则引用 TUN)
h, port, mode = sys.argv[1], int(sys.argv[2]), sys.argv[3]
cfg = {
  "log": {"level": "info", "output": h + "/sing-box.log"},
  "experimental": {"clash_api": {"external_controller": "127.0.0.1:39800", "secret": "tok"},
                   "cache_file": {"enabled": True, "path": h + "/cache.db"}},
  "inbounds": [
    {"type": "tun", "tag": "tun-in", "interface_name": "utun9", "address": ["172.19.0.1/30"]},
    {"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": port, "set_system_proxy": True}],
  "route": {"rules": [{"inbound": "tun-in", "action": "sniff"},
                      {"type": "logical", "mode": "and", "outbound": "direct",
                       "rules": [{"inbound": ["tun-in"], "domain_suffix": ["x.example"]}]}],
            "final": "direct"},
  "dns": {"rules": [{"inbound": "tun-in", "server": "local"}]}
}
if mode == "noapi": del cfg["experimental"]["clash_api"]
json.dump(cfg, sys.stdout, indent=1)
PY
chmod +x "$TR/fake-sb"
trial_run() { # 名字 混合端口 api|noapi [变量=值 ...] -> rc|config.json|正式的日志/缓存|临时目录|日志文件|日志内容
  local name=$1 port=$2 mode=$3; shift 3
  (
    H=$TR/h-$name; LOGS=$TR/logs-$name; rm -rf "$H" "$LOGS"; mkdir -p "$H"; SB=$TR/fake-sb
    python3 "$TR/mkcfg.py" "$H" "$port" "$mode" > "$H/config.json"; cp "$H/config.json" "$TR/$name.orig"
    [ $# -gt 0 ] && export "$@"
    rc=0; core_trial || rc=$?
    same=$(cmp -s "$H/config.json" "$TR/$name.orig" && echo same || echo changed)
    live=$(ls "$H" | grep -E '^(sing-box\.log|cache\.db)$' | paste -sd, -)
    left=$(test -e "$H/core-trial" && echo left || echo cleaned)
    logf=$(test -f "$LOGS/core-trial.log" && echo log || echo nolog)
    echo "$rc|$same|${live:-none}|$left|$logf|$(grep -Eo 'crash on start|no clash_api' "$LOGS/core-trial.log" 2>/dev/null | paste -sd, -)"
  )
}
eq "健康配置 (TUN 入站、系统代理开关、日志和缓存文件, 规则引用 TUN): 试运行通过; config.json 一个字节没变; 不写正式的日志和缓存; 临时目录清掉" "$(trial_run ok 39810 api)" '0|same|none|cleaned|nolog|'
busy=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
python3 -c 'import socket, sys, time; s = socket.socket(); s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(); time.sleep(60)' "$busy" &
busy_pid=$!
for _ in $(seq 1 50); do nc -z 127.0.0.1 "$busy" 2>/dev/null && break; sleep 0.1; done
eq "正式的混合端口被别的程序占用: 副本换用空闲端口, 试运行照样通过" "$(trial_run busy "$busy" api)" '0|same|none|cleaned|nolog|'
kill "$busy_pid" 2>/dev/null; wait "$busy_pid" 2>/dev/null || true
eq "假核心启动即崩溃: 试运行失败, 原因写进 core-trial.log, 临时目录清掉" "$(trial_run crash 39811 api FAKE_CRASH=1)" '1|same|none|cleaned|log|crash on start'
eq "配置里没有 clash_api (无法确认就绪): 不启动核心, 失败, 日志写明原因" "$(trial_run noapi 39812 noapi)" '1|same|none|cleaned|log|no clash_api'
echo "== U14. 网站条目 (site_entry): 直接读服务文件, 注释 / 空行 / 缩进行不算条目, 找不到或文件不存在时为空, 条目在文件前面时不报 Broken pipe"
SE=$UW/site-entry; rm -rf "$SE"; mkdir -p "$SE/h/cloud/content" "$SE/nodata"
{
  printf '# 注释行\n\n  indented|x|y|pin|a.example|||缩进行\n\ttabbed|x|y|pin|b.example|||缩进行\n#hidden|x|y|pin|c.example|||注释行\n'
  printf 'alpha|甲|search|auto|alpha.example,alpha2.example|||第一个\nbeta|乙|search|pin|beta.example|||第二个\n'
  awk 'BEGIN { for (i = 1; i <= 20000; i++) printf "bulk%d|批量|search|auto|bulk%d.example|||占位\n", i, i }'
} > "$SE/h/cloud/content/services.conf"
CF_REAL=$(sed -n '/^content_file() {/,/^}/p' "$REPO/lib/common.sh")   # 上面 U4/U5 替换过 content_file (只认 apps.conf), 这里取回 common.sh 里真正的函数
site_get() { ( eval "$CF_REAL"; H=$SE/h; site_entry "$1" ); }        # 子 shell 里改 H 和 content_file, 不影响后面的测试
eq "site_entry: 条目原样返回 (前面有注释、空行、缩进行)" "$(site_get alpha)" 'alpha|甲|search|auto|alpha.example,alpha2.example|||第一个'
eq "site_entry: 文件里最后的条目也能找到" "$(site_get beta)" 'beta|乙|search|pin|beta.example|||第二个'
eq "site_entry: 注释行 / 缩进行不算条目 (找不到则为空)" "$(site_get indented)$(site_get tabbed)$(site_get hidden)" ""
eq "site_entry: 没有这个条目 → 空" "$(site_get nope)" ""
eq "site_entry: 服务文件不存在 → 空, 退出码 0" "$(eval "$CF_REAL"; H=$SE/none; DATA=$SE/nodata; site_entry alpha; echo "rc=$?")" "rc=0"
se_err=$( (trap '' PIPE; eval "$CF_REAL"; H=$SE/h; site_entry alpha >/dev/null) 2>&1 )
eq "site_entry: 条目在前、后面还有 2 万行, SIGPIPE 被忽略 (api.log 的情形) 时不报 Broken pipe" "$(printf '%s' "$se_err" | grep -c 'Broken pipe')" "0"

echo "== U15. 程序文件替换 (install.sh install_files): 复制 / 换入 / VERSION 失败时原来的 lib 与 data 原样保留; 成功后与源码一致; 缺 common.sh 时安装器与 lib/api.sh 报错退出"
IF=$UW/install-files; rm -rf "$IF"; mkdir -p "$IF"
fn_src() { sed -n "/^$1() {/,/^}/p" "$REPO/install.sh"; }        # install.sh 末尾会直接运行安装, 不能整个 source, 只取出需要的函数
mk_old() { rm -rf "$1"; mkdir -p "$1/lib" "$1/data"; printf 'OLD-LIB\n' > "$1/lib/marker.sh"; printf 'OLD-DATA\n' > "$1/data/marker"; }
leftovers() { ls -d "$1".stage.* "$1".old.* 2>/dev/null | wc -l | tr -d ' '; }
PT=$(fn_src _program_tree_fail; fn_src program_tree_replace; fn_src install_files)
mk_old "$IF/a/h"
( H=$IF/a/h; SRC=$REPO; eval "$PT"; cp() { return 1; }; install_files ) >/dev/null 2>&1; rc=$?
eq "复制失败 (cp 报错): 安装中止, 退出码非 0" "$([ "$rc" != 0 ] && echo aborted)" "aborted"
eq "复制失败: 原来的 lib 与 data 原样保留" "$(cat "$IF/a/h/lib/marker.sh" "$IF/a/h/data/marker" | paste -sd, -)" "OLD-LIB,OLD-DATA"
eq "复制失败: 没有留下临时目录" "$(leftovers "$IF/a/h")" "0"
mk_old "$IF/b/h"
( H=$IF/b/h; SRC=$REPO; eval "$PT"; mv() { case $1 in *.stage.*) return 1 ;; esac; command mv "$@"; }; install_files ) >/dev/null 2>&1; rc=$?
eq "换入失败 (新目录挪不进去): 安装中止, 退出码非 0" "$([ "$rc" != 0 ] && echo aborted)" "aborted"
eq "换入失败: 旧的 lib 与 data 换回原位, 原样保留" "$(cat "$IF/b/h/lib/marker.sh" "$IF/b/h/data/marker" | paste -sd, -)" "OLD-LIB,OLD-DATA"
eq "换入失败: 没有留下临时目录" "$(leftovers "$IF/b/h")" "0"
mk_old "$IF/c/h"; mkdir -p "$IF/c/src"; cp -R "$REPO/lib" "$REPO/data" "$IF/c/src/"; printf 'not-a-version\n' > "$IF/c/src/VERSION"
( H=$IF/c/h; SRC=$IF/c/src; eval "$PT"; install_files ) >/dev/null 2>&1; rc=$?
eq "VERSION 不对: 安装中止, 退出码非 0" "$([ "$rc" != 0 ] && echo aborted)" "aborted"
eq "VERSION 不对: 原来的 lib 与 data 原样保留" "$(cat "$IF/c/h/lib/marker.sh" "$IF/c/h/data/marker" | paste -sd, -)" "OLD-LIB,OLD-DATA"
mk_old "$IF/d/h"
( H=$IF/d/h; SRC=$REPO; eval "$PT"; install_files ) >/dev/null 2>&1; rc=$?
eq "成功: 退出码 0" "$rc" "0"
eq "成功: lib 与源码一致 (旧的 marker 已经不在了)" "$(diff -rq "$REPO/lib" "$IF/d/h/lib" >/dev/null 2>&1 && [ ! -e "$IF/d/h/lib/marker.sh" ] && echo same)" "same"
eq "成功: data 与源码一致" "$(diff -rq "$REPO/data" "$IF/d/h/data" >/dev/null 2>&1 && echo same)" "same"
eq "成功: 没有留下临时目录" "$(leftovers "$IF/d/h")" "0"
EG=$IF/entry; mkdir -p "$EG/api"; cp "$REPO/install.sh" "$EG/install.sh"; cp "$REPO/lib/api.sh" "$EG/api/api.sh"
out=$( cd "$EG" && bash "$EG/install.sh" </dev/null 2>&1 ); rc=$?
eq "install.sh (已安装的 enana 也是它): 缺 lib/common.sh 时报错退出, 退出码 1, 写明原因" "rc=$rc:$(printf '%s' "$out" | grep -c '无法加载')" "rc=1:1"
out=$( cd "$EG/api" && bash "$EG/api/api.sh" </dev/null 2>&1 ); rc=$?
eq "lib/api.sh: 缺 common.sh 时报错退出, 退出码 1, 写明原因" "rc=$rc:$(printf '%s' "$out" | grep -c '无法加载')" "rc=1:1"
echo
echo "== U14. 更新失败记在真正失败的那一步 · 原因取最后一条「✗」 · api.log 带时间 · 轮转 · 诊断导出的 api.log 尾部 · 任务文件只留最近的 · 管理员框的结果 · 打码 · 导入失败删掉粘贴的数据"
(
  H=$UW/h14u; LOGS=$H/logs; rm -rf "$H"; mkdir -p "$H/jobs" "$LOGS"; : > "$H/api.log"
  update_check() { :; }; update_has_new() { return 0; }                     # 不联网: 假装有新版本
  jst() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["state"] + ":" + ",".join(s["state"] for s in d["steps"]))' "$1"; }
  upd() { awk -F'\t' '$3 == "更新 enana" { print $4 "\t" $5 }' "$LOGS"/ops-*.log 2>/dev/null; }
  STEPS='检查新版本|下载并校验新版本|安装并重新生成配置|完成'
  export T14_H=$H
  cat > "$H/get.sh" <<'SH'
#!/bin/bash
ls "$T14_H/jobs" > "$T14_H/seen.txt" 2>/dev/null                         # 更新运行中: 错误文件在 jobs/ 下、以任务编号命名
echo '##job 0 10 检查新版本'
echo '##job 1 30 下载并校验新版本'
echo '##job 2 50 安装并重新生成配置'
printf '\n  \033[31m✗ 旧的错误\033[0m\n' >&2
printf '    detail\n' >&2
printf '\n  ✗ 安装器没有通过校验\n' >&2
exit 1
SH
  JOB_NAME=self-update; JOB_ID=$(job_new self-update "$STEPS"); op_self_update >/dev/null 2>&1
  eq "更新失败: 进度记在真正失败的那一步 (第 3 步 error, 前两步 done, 后面 todo), 不再硬编码第 2 步" "$(jst "$H/jobs/$JOB_ID.json")" "error:done,done,error,todo"
  eq "操作记录: 失败的步骤和原因 (最后一条 ✗ 行) 写进详情, 结果 error" "$(upd | tail -n 1)" "from=$VERSION step=安装并重新生成配置 reason=安装器没有通过校验	error"
  eq "api.log: 两条 ✗ 行都带日期时间, 颜色码去掉了" "$(grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} +✗ ' "$H/api.log"):$(grep -c "$(printf '\033')" "$H/api.log")" "2:0"
  eq "错误输出按任务各写一个文件 (jobs/<任务编号>.get.err): 运行中可以看到它, 结束后删掉" "$(grep -cx "$JOB_ID.get.err" "$H/seen.txt"):$(test -e "$H/jobs/$JOB_ID.get.err" && echo left || echo gone)" "1:gone"
  cat > "$H/get.sh" <<'SH'
#!/bin/bash
printf '\n  ✗ 连不上下载服务\n' >&2
exit 1
SH
  JOB_ID=$(job_new self-update "$STEPS"); op_self_update >/dev/null 2>&1
  eq "没有任何进度就失败: 记在第 1 步 (检查新版本), 不是安装那一步" "$(jst "$H/jobs/$JOB_ID.json")" "error:error,todo,todo,todo"
  eq "…原因是这条 ✗ 行, 步骤名用默认的「检查新版本」" "$(upd | tail -n 1)" "from=$VERSION step=检查新版本 reason=连不上下载服务	error"
  cat > "$H/get.sh" <<'SH'
#!/bin/bash
echo '##job 3 100 完成'
exit 0
SH
  echo 9.9.9 > "$H/VERSION"
  JOB_ID=$(job_new self-update "$STEPS"); op_self_update >/dev/null 2>&1
  eq "成功: 四步全部 done, 操作记录写「旧版本 → 新版本」 ok" "$(jst "$H/jobs/$JOB_ID.json"):$(upd | tail -n 1)" "done:done,done,done,done:$VERSION → 9.9.9	ok"
)
(
  H=$UW/h14k; LOGS=$H/logs; rm -rf "$H"; mkdir -p "$H/jobs" "$LOGS"; : > "$H/api.log"
  update_check() { :; }; update_has_new() { return 0; }
  export T14_H=$H
  cat > "$H/get.sh" <<'SH'
#!/bin/bash
echo '##job 1 30 下载并校验新版本'
printf '\n  ✗ 写到一半被结束\n' >&2
kill -TERM "$PPID"; exit 1                                              # 模拟: 更新进程在下载途中被结束
SH
  JOB_NAME=self-update; JOB_ID=$(job_new self-update 'a|b|c')
  ( op_self_update ) >/dev/null 2>&1; rc=$?                             # 这一层被结束 (不是外面的测试进程)
  eq "更新进程中途被结束 (TERM): 退出码 143; 写到一半的 ✗ 行在退出时补进 api.log (带日期时间); 错误文件删掉; 没有写操作记录" "$rc:$(grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} +✗ 写到一半被结束$' "$H/api.log"):$(test -e "$H/jobs/$JOB_ID.get.err" && echo left || echo gone):$(cat "$LOGS"/ops-*.log 2>/dev/null | grep -c '更新 enana')" "143:1:gone:0"
)
(
  H=$UW/h14r; LOGS=$H/logs; rm -rf "$H"; mkdir -p "$LOGS"
  printf 'old-3\n' > "$H/api.log.3"; printf 'old-2\n' > "$H/api.log.2"; printf 'old-1\n' > "$H/api.log.1"
  head -c 1000000 /dev/zero | tr '\0' a > "$H/api.log"
  logs_rotate_api
  eq "api.log 不到 5 MB: 不轮转, 三代都不动" "$(cat "$H/api.log.1"):$(cat "$H/api.log.2"):$(cat "$H/api.log.3")" "old-1:old-2:old-3"
  { head -c 5300000 /dev/zero | tr '\0' b; echo; echo LATEST-LINE; } > "$H/api.log"
  logs_rotate_api
  eq "超过 5 MB: 当前文件转成第 1 代 (内容保留), 原第 1 代 → 第 2 代, 原第 2 代 → 第 3 代, 最旧的那一代删掉" "$(tail -n 1 "$H/api.log.1"):$(cat "$H/api.log.2"):$(cat "$H/api.log.3")" "LATEST-LINE:old-1:old-2"
  eq "轮转后当前的 api.log 是空的, 之后的日志接着写进来" "$(wc -c < "$H/api.log" | tr -d ' ')" "0"
  { head -c 5300000 /dev/zero | tr '\0' c; } > "$H/api.log"; logs_maintain >/dev/null 2>&1
  eq "日常 / 每小时的维护 (logs_maintain) 也会检查轮转" "$(wc -c < "$H/api.log" | tr -d ' '):$(test -s "$H/api.log.1" && echo gen1)" "0:gen1"
)
(
  H=$UW/h14t; LOGS=$H/logs; rm -rf "$H"; mkdir -p "$LOGS"
  printf 'old\n' > "$H/api.log.2"; printf 'new\n' > "$H/api.log.1"
  python3 -c 'import os,sys,time; t=time.time()-3*86400; os.utime(sys.argv[1],(t,t))' "$H/api.log.2"
  LOG_HOURS=24; logs_purge >/dev/null
  eq "api.log 的历史代也按保留期删: 超过 24 小时的 api.log.2 删掉, 刚写的 api.log.1 留着" "$(test -e "$H/api.log.2" && echo kept || echo gone):$(test -e "$H/api.log.1" && echo kept || echo gone)" "gone:kept"
)
(
  H=$UW/h14d; LOGS=$H/logs; rm -rf "$H"; mkdir -p "$LOGS"
  srv_list() { printf 'Pin-A\tsocks\tvps.example.net\t1080\tpin\t\n'; }     # 一台服务器: 标签 Pin-A, 地址 vps.example.net
  seq -f 'g1-%g' 1 300 > "$H/api.log.1"
  { seq -f 'cur-%g' 1 5; echo 'router: found process path: /Users/example/Applications/X.app, user: example'; } > "$H/api.log"
  out=$(_b_apilog)
  eq "诊断导出的 api.log 尾部: 只取 200 行 (上一代末尾 194 行 + 当前文件 6 行)" "$(printf '%s\n' "$out" | wc -l | tr -d ' '):$(printf '%s\n' "$out" | head -n 1)" "200:g1-107"
  eq "…行里的用户名打码 (和其它分区一样)" "$(printf '%s\n' "$out" | tail -n 1)" "router: found process path: /Users/<user>/Applications/X.app, user: <user>"
  printf '2026-10-01 10:00:00 OLD-LINE\ncontinuation-of-old\n' > "$H/api.log.1"
  printf '2026-10-10 12:00:00 NEW-LINE\n  cont-new\n2026-10-09 23:59:59 BEFORE-WINDOW\nafter-before\n' > "$H/api.log"
  out=$(_b_apilog '2026-10-10 00:00:00')
  eq "导出时间范围: 早于范围的行和它的续行不导出; 范围内的行和它的续行导出" "$out" "$(printf '2026-10-10 12:00:00 NEW-LINE\n  cont-new')"
  printf '2026-10-10 12:00:01 dial 203.0.113.9:443 failed; via [2001:db8:1:2::7]:443; error contacting vps.example.net (Pin-A); ver 2.3.22 at 10:00:00\n' > "$H/api.log"; : > "$H/api.log.1"
  out=$(_b_apilog '2026-10-10 00:00:00')
  eq "文字里的 IPv4 / IPv6 同 _b_mask_host 打码 (版本号和时刻不动); 服务器地址 → 同 _b_mask_host, 标签 → <server>" "$out" "2026-10-10 12:00:01 dial 203.0.*.*:443 failed; via [2001:db8:*]:443; error contacting v***.example.net (<server>); ver 2.3.22 at 10:00:00"
  printf '2026-10-10 12:00:03 connect 203.0.113.9. and addr:2001:db8::1 end; server:198.51.100.7, ok 1.2.3.4.5\n' > "$H/api.log"
  out=$(_b_apilog '2026-10-10 00:00:00')
  eq "句末的地址也打码 (句号不算版本号的一部分); 「标签:」后面的 IPv6 打码; 1.2.3.4.5 这类不误伤" "$out" "2026-10-10 12:00:03 connect 203.0.*.*. and addr:2001:db8:* end; server:198.51.*.*, ok 1.2.3.4.5"
  printf '2026-10-10 12:00:02 fetch https://user:pw123@198.51.100.7:8443/x?token=TOKEN123 and https://feed.example/a/b?key=K9 failed\n' > "$H/api.log"
  out=$(_b_apilog '2026-10-10 00:00:00')
  eq "URL: 用户名 / 密码, 路径和查询串去掉; IP 主机打码; 域名保留" "$out" "2026-10-10 12:00:02 fetch https://198.51.*.*:8443/<path> and https://feed.example/<path> failed"
  out=$(printf 'my-rules|My|direct|1700000000|https://user:pw123@rules.example:8443/tok/abc.srs?key=SECRET99\nCN=https://[2001:db8::1]:443/x?t=ABC\n' | _b_url_redact)
  eq "自定义规则集 / DNS 地址: user:pass@ 整段去掉 (域名保留, 路径 / 查询串换成 /<path>); IPv6 字面地址打码" "$out" "$(printf 'my-rules|My|direct|1700000000|https://rules.example:8443/<path>\nCN=https://[2001:db8:*]:443/<path>')"
  out=$(printf 'app.example|203.0.113.9\nlast.example|198.51.100.7' | _b_hosts_mask)
  eq "hosts.tsv: 最后一行没有换行也导出; IP 打码" "$out" "$(printf 'app.example|203.0.*.*\nlast.example|198.51.*.*')"
  unset -f srv_list
  printf '2026-10-10 12:00:02 fetch https://user:pw123@198.51.100.7:8443/x failed\n' > "$H/api.log"; : > "$H/api.log.1"
  ( logs_bundle 24 snapshot > "$H/bundle.txt" 2>/dev/null )
  eq "完整诊断 (完整上传用的同一份导出): 辅助服务日志里的 IP / URL 用户名不出现原文, apilog 分区存在" "$(grep -c '198.51.100.7' "$H/bundle.txt"):$(grep -c 'pw123' "$H/bundle.txt"):$(grep -c '^@@SECTION apilog ' "$H/bundle.txt")" "0:0:1"
)
(
  H=$UW/h14j; LOGS=$H/logs; rm -rf "$H"; mkdir -p "$H/jobs" "$LOGS"
  python3 - "$H/jobs" <<'PY'
import os, sys, time
d = sys.argv[1]; now = time.time()
def w(name, body, t):
    p = os.path.join(d, name)
    with open(p, 'w') as f: f.write(body)
    os.utime(p, (t, t))
def rec(jid, state, t):
    w(jid + '.json', '{"ok":true,"id":"%s","name":"core","state":"%s","pct":100,"msg":"ok","steps":[{"label":"a","state":"done"}],"result":{}}\n' % (jid, state), t)
    w(jid + '.steps', 'a', t)
for i in range(260):                                             # 260 个已结束的任务, 都在一小时之内: 只留最近的 200 个
    jid = 'core-%03d' % i; t = now - 3600 + i * 5
    rec(jid, 'done', t); w(jid + '.ticket', '1', t)
w('core-259.cred', 'SECRET-CRED', now - 2 * 86400)               # 记录还在最近 200 个之内, 但凭据超过一天: 删
w('core-258.body', 'BODY', now - 60)                              # 刚写的: 留着
rec('old-done', 'done', now - 2 * 86400); w('old-done.cred', 'OLD-CRED', now - 2 * 86400)   # 超过一天的已结束任务: 整份删, 即使数量没超
rec('err-old', 'error', now - 3 * 86400)
rec('apply-run', 'running', now - 3 * 86400); w('apply-run.cred', 'LIVE-CRED', now - 3 * 86400); w('apply-run.pid', '1', now - 3 * 86400)   # 进行中: 一个文件都不动
w('stale.steps', 'x', now - 3 * 86400); w('fresh.steps', 'x', now); w('stale.body', 'x', now - 2 * 86400)   # 没有记录的残留
PY
  job_prune
  eq "只留最近 200 个已结束的任务 (最旧的 60 个删掉, 最新的 core-259 还在)" "$(ls "$H/jobs" | grep -c '^core-[0-9]*\.json$'):$(test -f "$H/jobs/core-259.json" && echo kept):$(ls "$H/jobs" | grep -c '^core-000\.')" "200:kept:0"
  eq "超过一天的已结束任务整份删掉 (数量没超也删): old-done / err-old 的全部文件" "$(ls "$H/jobs" | grep -c -e '^old-done\.' -e '^err-old\.')" "0"
  eq "凭据 / 粘贴的数据 (.cred .body): 非运行中的任务超过一天就删, 不管记录还在不在 (core-259.cred 删掉); 刚写的 core-258.body 留着" "$(test -e "$H/jobs/core-259.cred" && echo kept || echo gone):$(test -e "$H/jobs/core-258.body" && echo kept || echo gone)" "gone:kept"
  eq "进行中的任务一个文件都不动 (记录写着 running, 即使很旧, 包括它的凭据)" "$(ls "$H/jobs" | grep -c '^apply-run\.')" "4"
  eq "没有记录的残留文件: 超过一天的删掉 (stale.steps / stale.body), 刚写的留着 (fresh.steps)" "$(test -e "$H/jobs/stale.steps" && echo kept || echo gone):$(test -e "$H/jobs/stale.body" && echo kept || echo gone):$(test -e "$H/jobs/fresh.steps" && echo kept || echo gone)" "gone:gone:kept"
  J=$(job_new apply 'a|b')
  eq "新建任务时也会整理: 已结束的仍是 200 个; 新任务和进行中的旧任务都还在" "$(grep -L '"state":"running"' "$H/jobs"/*.json | wc -l | tr -d ' '):$(test -f "$H/jobs/$J.json" && echo new-kept):$(test -f "$H/jobs/apply-run.json" && echo run-kept)" "200:new-kept:run-kept"
)
(
  H=$UW/h14i; LOGS=$H/logs; rm -rf "$H"; mkdir -p "$H/jobs" "$LOGS"
  JID=imp-test-1; printf 'host-x PW-IMPORT-SECRET\n' > "$H/jobs/$JID.body"          # 粘贴的服务器数据 (整批都不合格: 导入失败)
  ( job_dispatch servers-import "$JID" '' merge '' '' '' '' '' ) >/dev/null 2>&1
  eq "服务器导入失败 (整批都不合格): 粘贴的数据在进程结束时删掉; 任务记为失败" "$(test -e "$H/jobs/$JID.body" && echo left || echo gone):$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["state"])' "$H/jobs/$JID.json")" "gone:error"
)
(
  H=$UW/h14f; LOGS=$H/logs; rm -rf "$H"; mkdir -p "$LOGS"
  logs_days() { : > "$H/logs_days_called"; }
  printf '2026-10-10 09:00:00\tdashboard\t更新 enana\tfrom=2.3.22 step=安装并重新生成配置 reason=/Users/example/.enana/x\terror\n' > "$LOGS/ops-2026-10-10.log"
  printf '2026-10-11 10:00:00\tdashboard\t更新 enana\t2.3.22 → 2.3.23\tok\n' > "$LOGS/ops-2026-10-11.log"
  eq "诊断导出: 之后又有成功的更新 → 不报告旧的失败 (写 none)" "$(_b_update_failed)" "update.last_failed=none"
  rm -f "$LOGS/ops-2026-10-11.log"
  eq "最近一次更新失败: 写时间 + 详情, 路径里的用户名打码" "$(_b_update_failed)" "$(printf 'update.last_failed.ts=2026-10-10 09:00:00\nupdate.last_failed.detail=from=2.3.22 step=安装并重新生成配置 reason=/Users/<user>/.enana/x')"
  eq "…只读操作记录, 不调用 logs_days (不扫 sing-box.log)" "$(test -e "$H/logs_days_called" && echo called || echo none)" "none"
  : > "$LOGS/ops-2026-10-10.log"
  eq "没有更新记录: 写 none" "$(_b_update_failed)" "update.last_failed=none"
  printf '2026-10-10 09:00:00\tdashboard\t更新 enana\tfrom=2.3.22 step=检查新版本 reason=x\terror\n' > "$LOGS/ops-2026-10-10.log"
  eq "没有选操作记录的导出: env 不带 update.last_failed" "$(BUNDLE_OPS=0; _b_helperlogs | grep -c 'update.last_failed')" "0"
  eq "选了操作记录的导出: env 带 update.last_failed" "$(BUNDLE_OPS=1; _b_helperlogs | grep -c '^update.last_failed.ts=')" "1"
)
(
  H=$UW/h14o; LOGS=$H/logs; rm -rf "$H"; mkdir -p "$LOGS"
  printf '2026-10-10 09:00:00\tdashboard\t添加自己的服务器\thost=203.0.113.9 code=E_X\terror\n2026-10-10 09:01:00\tdashboard\t探测服务器\thost=vps.example.net:22 os=Ubuntu\tok\n' > "$LOGS/ops-2026-10-10.log"
  out=$(_b_ops "" 2026-10-10)
  eq "导出的操作记录: 详情里的 host= 打码 (IPv4 / 域名, 端口保留), 其它详情和结果不动" "$(printf '%s\n' "$out" | tail -n 2)" "$(printf '2026-10-10 09:00:00\tdashboard\t添加自己的服务器\thost=203.0.*.* code=E_X\terror\n2026-10-10 09:01:00\tdashboard\t探测服务器\thost=v***.example.net:22 os=Ubuntu\tok')"
)
(
  H=$UW/h14v; LOGS=$H/logs; rm -rf "$H"; mkdir -p "$H/jobs" "$LOGS"
  job_write() { :; }
  JOB_NAME=vps-probe JOB_ID=vps-probe-x V_HOST=203.0.113.9 V_PORT=22 VPS_CODE=E_SSH_UNREACHABLE VPS_ATTEMPT=3 VPS_ATTEMPTS=3 vps_job_error 1
  eq "探测失败: 记成「探测服务器」一行 (本机记录里 host 原样, 导出时打码), 结果 error" "$(awk -F'\t' '{ print $3 "|" $4 "|" $5 }' "$LOGS"/ops-*.log)" "探测服务器|host=203.0.113.9 code=E_SSH_UNREACHABLE|error"
)
(
  H=$UW/h14a; LOGS=$H/logs; rm -rf "$H"; mkdir -p "$LOGS"
  enhanced_configured() { return 0; }; enhanced_restart_fast() { ENHANCED_FAST_WHY=changed; return 1; }
  core_restart_note() { :; }; core_mark_start() { :; }
  row() { awk -F'\t' '$3 == "重启核心方式" { print $4 "\t" $5 }' "$LOGS"/ops-*.log | tail -n 1; }
  os_service_start() { ENHANCED_ADMIN_ERR=cancelled; echo "before=$(cat "$LOGS"/ops-*.log 2>/dev/null | wc -l | tr -d ' ')" > "$H/before"; return 1; }
  os_service_restart; rc=$?
  eq "管理员框被取消: 操作记录写 via=admin why=changed rc=1, 结果 cancelled (不再先写 ok)" "$rc:$(row)" "1:mode=tun via=admin why=changed rc=1	cancelled"
  eq "…这一行是在管理员框的结果出来之后才写 (框弹出时还没有任何记录)" "$(cat "$H/before")" "before=0"
  os_service_start() { ENHANCED_ADMIN_ERR=failed; return 3; }
  os_service_restart; rc=$?
  eq "管理员框之后失败: 结果 error, 带上返回码" "$rc:$(row)" "3:mode=tun via=admin why=changed rc=3	error"
  os_service_start() { return 0; }
  os_service_restart; rc=$?
  eq "成功: 结果 ok, 没有返回码" "$rc:$(row)" "0:mode=tun via=admin why=changed	ok"
  sudo() { return 1; }
  osascript() { echo 'execution error: User canceled. (-128)' >&2; return 1; }
  enhanced_admin '/bin/true x' </dev/null 2>"$H/err"; rc=$?
  eq "弹框被取消: 返回 1, 结果 cancelled, 错误文字照样输出 (弹框本身不变)" "$rc:$ENHANCED_ADMIN_ERR:$(enhanced_result "$rc"):$(grep -c 'User canceled' "$H/err")" "1:cancelled:cancelled:1"
  osascript() { echo 'execution error: something broke (1)' >&2; return 1; }
  enhanced_admin '/bin/true x' </dev/null 2>"$H/err"; rc=$?
  eq "弹框的其它失败: 结果 error" "$rc:$ENHANCED_ADMIN_ERR:$(enhanced_result "$rc")" "1:failed:error"
  osascript() { echo 'execution error: Foo failed (-1280)' >&2; return 1; }
  enhanced_admin '/bin/true x' </dev/null 2>"$H/err"; rc=$?
  eq "错误码 -1280 不是取消 (只认带括号的 (-128)): 结果 error" "$rc:$ENHANCED_ADMIN_ERR:$(enhanced_result "$rc")" "1:failed:error"
  osascript() { echo 'execution error: cannot open /tmp/-128/x (1)' >&2; return 1; }
  enhanced_admin '/bin/true x' </dev/null 2>"$H/err"; rc=$?
  eq "路径里含 -128 不是取消: 结果 error" "$rc:$ENHANCED_ADMIN_ERR:$(enhanced_result "$rc")" "1:failed:error"
  osascript() { echo 'execution error: User canceled. (-128)' >&2; return 1; }
  enhanced_admin '/bin/true x' </dev/null 2>"$H/err"; rc=$?
  eq "取消的写法不变: (-128) 仍然是 cancelled" "$rc:$ENHANCED_ADMIN_ERR" "1:cancelled"
  osascript() { : > "$H/osa.called"; return 0; }
  mktemp() { return 1; }
  enhanced_admin '/bin/true x' </dev/null 2>"$H/err"; rc=$?
  eq "建不了临时文件: 管理员框照样弹出 (osascript 被调用), 返回 0, 结果 ok" "$rc:$(test -e "$H/osa.called" && echo shown):$(enhanced_result "$rc")" "0:shown:ok"
  unset -f mktemp
  osascript() { return 0; }
  enhanced_admin '/bin/true x' </dev/null 2>"$H/err"; rc=$?
  eq "弹框通过: 返回 0, 结果 ok" "$rc:$(enhanced_result "$rc")" "0:ok"
)
echo
PASS=$(wc -l < "$UW/.pass" 2>/dev/null | tr -d ' '); FAIL=$(wc -l < "$UW/.fail" 2>/dev/null | tr -d ' ')
echo "单元测试: ${PASS:-0} 通过, ${FAIL:-0} 失败"
[ "${FAIL:-0}" = 0 ]
