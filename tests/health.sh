#!/bin/bash
# 连接健康记录 (lib/health.sh + lib/health.pl) 和会话心跳事件: 几秒钟, 不需要 sing-box / 网络 / 管理员权限, macOS 和 Linux 都能跑。
#   · 每分钟 tick: 服务器端口 (真实的本机监听端口 / 关闭的端口) · 经代理的金丝雀分类 (ok / region-blocked / timeout …) · 状态变化 → 操作记录 + state 行 · 休眠间隔
#   · 「操作记录」开关关闭时一并不记 · 心跳失败 / 恢复 / 被踢下线的操作记录
#   · 自动判定 (verdict): 每种原因都用合成数据验证 —— 系统代理没开 / 节点不可达 / 本机断网 / OpenAI 拒绝出口 IP / 被退出登录 / 代理核心没运行 / 数据不足
# curl / scutil / route / launchctl / nc 全部用本文件里的函数替身 (函数优先于 PATH 里的命令), 不碰真实系统。
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P); REPO=$(dirname "$HERE")
W=$(mktemp -d /tmp/enana-health.XXXXXX); W=$(cd "$W" && pwd -P)
LPID=''; trap 'rm -rf "$W"; [ -z "$LPID" ] || kill "$LPID" 2>/dev/null' EXIT; : > "$W/.pass"; : > "$W/.fail"
tpass() { echo p >> "$W/.pass"; echo "  ✓ $1"; }
tfail() { echo f >> "$W/.fail"; echo "  ✗ $1"; [ -n "${2:-}" ] && printf '      ↳ %s\n' "$(printf '%s' "$2" | head -c 700)"; return 0; }
eq()    { if [ "$2" = "$3" ]; then tpass "$1"; else tfail "$1" "期望 [$3] 实际 [$2]"; fi; }
has()   { if printf '%s\n' "$3" | grep -q -- "$2"; then tpass "$1"; else tfail "$1" "没有找到 /$2/ 于: $3"; fi; }
hasnt() { if ! printf '%s\n' "$3" | grep -q -- "$2"; then tpass "$1"; else tfail "$1" "不应出现 /$2/: $3"; fi; }

export HOME=$W/home ENANA_HOME=$W/h LC_ALL=C ENANA_LANG=zh PORT=37890 UI_PORT=37891 API_PORT=37892 SPEED_PORT=37893 ENANA_PLATFORM=darwin
mkdir -p "$HOME" "$ENANA_HOME"
. "$REPO/lib/common.sh"; init_paths "$REPO/install.sh"
LIB=$REPO/lib; DATA=$REPO/data
for _f in i18n os-darwin enhanced auth session logs servers health config; do . "$LIB/$_f.sh"; done
load_settings; QUIET=1
[ "$H" = "$W/h" ] || { echo "REFUSING: 数据目录不是临时目录 ($H)"; exit 1; }
command -v perl >/dev/null || { echo "跳过: 需要 perl"; exit 77; }

# ---- 替身
STUB_SP=1 STUB_CORE=1 STUB_PID=4001 STUB_IF=en0 STUB_LOGIN=1 C_GOOGLE=204 C_CHATGPT=403 C_OPENAI=401 C_CN=200
scutil()    { printf '<dictionary> {\n  HTTPEnable : %s\n  HTTPPort : %s\n  HTTPProxy : 127.0.0.1\n}\n' "$STUB_SP" "$PORT"; }
route()     { printf '   route to: default\n  gateway: 192.168.1.1\n  interface: %s\n' "$STUB_IF"; }
launchctl() { case ${2:-} in system/*) return 113 ;; esac; [ "$STUB_CORE" = 1 ] || return 113; printf 'state = running\n\tpid = %s\n' "$STUB_PID"; }
nc()        { return 0; }
auth_secret() { printf 'stub-secret'; }
auth_logged_in() { [ "$STUB_LOGIN" = 1 ]; }
curl() {
  local url='' a v
  for a in "$@"; do case $a in http*) url=$a ;; esac; done
  case $url in
    */version) printf '200'; return 0 ;;
    */proxies/svc-chatgpt) printf '{"now":"PIN","type":"Selector"}'; return 0 ;;
    */proxies/PIN) printf '{"now":"Pin-A","type":"Selector"}'; return 0 ;;
    */proxies/Final) printf '{"now":"Global","type":"Selector"}'; return 0 ;;
    */proxies/*) printf '{"type":"Socks"}'; return 0 ;;
    *gstatic*) v=$C_GOOGLE ;; *chatgpt.com*) v=$C_CHATGPT ;; *api.openai.com*) v=$C_OPENAI ;; *captive.apple*) v=$C_CN ;; *) v=200 ;;
  esac
  case $v in rc*) return "${v#rc}" ;; esac
  printf '%s\t0.012\t0.250' "$v"
}

# 本机监听端口 = 「服务器」; 另一个关闭的端口 = 「挂掉的服务器」
python3 - "$W/port" <<'PY' &
import socket, sys, time
s = socket.socket(); s.bind(('127.0.0.1', 0)); s.listen(8); open(sys.argv[1], 'w').write(str(s.getsockname()[1]))
s.settimeout(0.3); end = time.time() + 120
while time.time() < end:
    try: c, _ = s.accept(); c.close()
    except Exception: pass
PY
LPID=$!
for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$W/port" ] && break; sleep 0.25; done
OPEN=$(cat "$W/port" 2>/dev/null); [ -n "$OPEN" ] || { echo "跳过: 起不来本机监听端口"; exit 77; }
CLOSED=$(python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()")
setsrv() { printf '{"role":"pin","outbound":{"type":"socks","tag":"Tokyo-Fix","server":"127.0.0.1","server_port":%s}}\n' "$1" > "$H/servers.jsonl"; }
reset() { rm -rf "$LOGS" "$H"/.health.* ; mkdir -p "$LOGS"; PROXY_ENABLED=1; LOG_OPS=1; STUB_SP=1 STUB_CORE=1 STUB_PID=4001 STUB_IF=en0 STUB_LOGIN=1 C_GOOGLE=204 C_CHATGPT=403 C_OPENAI=401 C_CN=200; }
hf() { cat "$LOGS"/health-*.log 2>/dev/null; }
ops() { cat "$LOGS"/ops-*.log 2>/dev/null; }

echo "== H1. 第一次 tick: 服务器端口 + 状态基线 + 金丝雀 (没有「变化」, 不写操作记录)"
reset; setsrv "$OPEN"
health_tick
H1=$(hf)
has "node 行: 本机监听端口连得上 → ok, 带耗时和角色" "	node	Tokyo-Fix	ok	[0-9]*	role=pin mode=system" "$H1"
has "state 行: 第一次一定写基线, 带 core / proxy / sysproxy / capture" "	state	capture	ok	0	core=1 pid=4001 api=1 proxy=1 mode=auto capture=system sysproxy=1 login=1" "$H1"
has "canary google_204 经代理: ok, 路径用 Final 选择器" "	canary	google_204	ok	250	http=204 connect_ms=12 via=proxy chain=Final>Global" "$H1"
has "canary chatgpt_web: 403 (Cloudflare 人机验证页) 也算连得上, 并记下实际用的出口链 svc-chatgpt>PIN>Tokyo-Fix" "	canary	chatgpt_web	ok	250	http=403 connect_ms=12 via=proxy chain=svc-chatgpt>PIN>Pin-A" "$H1"
has "canary openai_api: 401 = 正常" "	canary	openai_api	ok	250	http=401" "$H1"
has "canary cn_direct: 不经代理的对照站点" "	canary	cn_direct	ok	250	http=200 connect_ms=12 via=direct" "$H1"
eq "第一次没有「环境状态变化」操作记录" "$(ops | grep -c 环境状态变化)" "0"
reset; setsrv "$OPEN"; health_tick; : > "$H/.health.canary.never"; health_tick
eq "再 tick 一次 (距上次不到 5 分钟): 不重复做金丝雀, 但服务器端口每分钟都记" "$(hf | grep -c '	canary	google_204	')/$(hf | grep -c '	node	Tokyo-Fix	')" "1/2"

echo "== H2. 状态变化 → 操作记录 (来源 auto) + 新的 state 行"
reset; setsrv "$OPEN"; health_tick
STUB_SP=0; health_tick
O=$(ops)
has "系统代理 1→0: 「环境状态变化 item=sysproxy from=1 to=0」" "auto	环境状态变化	item=sysproxy from=1 to=0 capture=system	ok" "$O"
has "state 行记下 sysproxy=0 (verdict 靠它算「自什么时候起」)" "	state	capture	ok	0	.*sysproxy=0" "$(hf)"
STUB_PID=4002; health_tick
has "核心进程 pid 变了 (崩溃后被 launchd 拉起 / 手动重启): 「核心进程已重启 old_pid=4001 new_pid=4002」" "核心进程已重启	old_pid=4001 new_pid=4002" "$(ops)"
STUB_CORE=0; health_tick
has "核心停止: item=core_running from=1 to=0" "item=core_running from=1 to=0" "$(ops)"
PROXY_ENABLED=0; STUB_LOGIN=0; STUB_IF=en1; health_tick
O=$(ops)
has "总开关 1→0" "item=proxy from=1 to=0" "$O"
has "登录 1→0" "item=login from=1 to=0" "$O"
has "默认网络接口 en0→en1 (换了 Wi-Fi / 网线)" "item=net_if from=en0 to=en1" "$O"
hasnt "密码 / 令牌 / 完整服务器地址不会出现在记录里" "stub-secret" "$(hf; ops)"

echo "== H3. 服务器端口不可达 / 金丝雀分类 / 休眠间隔 / 开关"
reset; setsrv "$CLOSED"; health_tick
has "关着的端口 → refused" "	node	Tokyo-Fix	refused	" "$(hf)"
reset; setsrv "$OPEN"; C_GOOGLE=rc28 C_CHATGPT=rc35 C_OPENAI=403 C_CN=rc7; health_tick
H3=$(hf)
has "curl 退出码 28 → timeout" "	canary	google_204	timeout	" "$H3"
has "curl 退出码 35 → tls" "	canary	chatgpt_web	tls	" "$H3"
has "OpenAI 对出口 IP 返回 403 → region-blocked (而不是笼统的 http-403)" "	canary	openai_api	region-blocked	" "$H3"
has "对照站点连不上 → refused" "	canary	cn_direct	refused	" "$H3"
reset; setsrv "$OPEN"; health_tick; printf '%s\n' "$(( $(now) - 900 ))" > "$H/.health.tick"; health_tick
has "两次定时任务相隔 15 分钟 (休眠 / 后台被暂停): 记一行 tick gap" "	tick	gap	gap	9[0-9][0-9]	" "$(hf)"
reset; setsrv "$OPEN"; PROXY_ENABLED=0; health_tick
hasnt "总开关关闭时不做经代理的金丝雀 (只保留不经代理的对照)" "	canary	google_204	" "$(hf)"
has "…但对照站点和服务器端口照常记录" "	canary	cn_direct	" "$(hf)"
reset; setsrv "$OPEN"; LOG_OPS=0; health_tick
eq "关闭「操作记录」: 健康记录和状态变化一并不写 (隐私)" "$(ls "$LOGS" | wc -l | tr -d ' ')" "0"

echo "== H4. 会话心跳: 失败只记一次, 恢复记时长; 被踢下线记原因 + 当时总开关状态"
reset; PROXY_ENABLED=1; printf 'sid-1\n' > "$H/session"; printf 'tok-1\n' > "$H/cloud.token"
session_call() { printf '000'; }                       # 连不上云端
session_heartbeat; session_heartbeat
eq "连续两次连不上: 只记一条「会话心跳失败」" "$(ops | grep -c 会话心跳失败)" "1"
has "详情带 http=000" "会话心跳失败	http=000" "$(ops)"
printf '%s\n' "$(( $(date +%s) - 600 ))" > "$H/hb.fail"
session_call() { printf '200'; printf '{"token":"t"}' > "$1"; }
session_heartbeat
has "恢复: 「会话心跳恢复 down_s=…」(约 600 秒)" "会话心跳恢复	down_s=6[0-9][0-9]" "$(ops)"
eq "恢复后不再有失败标记" "$([ -f "$H/hb.fail" ] && echo yes || echo no)" "no"
auth_logout_local() { :; }; op_sync_secret() { :; }
session_call() { printf '401'; printf '{"reason":"limit"}' > "$1"; }
session_heartbeat; rc=$?
eq "云端撤销会话: 返回 1" "$rc" "1"
has "「已被退出登录」: 来源 auto, 详情 reason=limit http=401 proxy_was=1 (以前是 terminal 且详情不是 key=value)" "auto	已被退出登录	reason=limit http=401 proxy_was=1	ok" "$(ops)"

echo "== H5. 自动判定 (verdict): 每种原因都用合成数据验证"
SP=$W/v; mkdir -p "$SP"
NOW=$(date +%s)
python3 - "$SP" "$NOW" <<'PY'
import sys, datetime as dt
sp, now = sys.argv[1], int(sys.argv[2])
def t(m): return dt.datetime.fromtimestamp(now - m * 60).strftime('%Y-%m-%d %H:%M:%S')
def L(m, kind, target, result, ms, det=''): return f"{t(m)}\t{kind}\t{target}\t{result}\t{ms}\t{det}\n"
def write(name, rows): open(f'{sp}/{name}', 'w').write(''.join(rows))
# A: 节点一直正常, 系统代理 120 分钟前被关
a = []
for m in range(180, 0, -1):
    a.append(L(m, 'node', 'Tokyo-Fix', 'ok', 40, 'role=pin'))
    if m % 5 == 0:
        for n, r in (('google_204', 'ok'), ('chatgpt_web', 'ok'), ('openai_api', 'ok'), ('cn_direct', 'ok')): a.append(L(m, 'canary', n, r, 200))
a.append(L(180, 'state', 'capture', 'ok', 0, 'core=1 proxy=1 sysproxy=1')); a.append(L(120, 'state', 'capture', 'ok', 0, 'core=1 proxy=1 sysproxy=0')); a.append(L(3, 'state', 'capture', 'ok', 0, 'core=1 proxy=1 sysproxy=0'))
write('A', a)
# B: 最近 20 分钟节点不可达, 对照正常
b = []
for m in range(180, 0, -1):
    b.append(L(m, 'node', 'Tokyo-Fix', 'ok' if m > 20 else 'timeout', 40 if m > 20 else 0, 'role=pin'))
    if m % 5 == 0: b.append(L(m, 'canary', 'google_204', 'ok' if m > 20 else 'timeout', 200)); b.append(L(m, 'canary', 'cn_direct', 'ok', 60))
write('B', b)
# C: 同样的故障但对照站点也不通 → 本机断网
c = []
for m in range(60, 0, -1):
    c.append(L(m, 'node', 'Tokyo-Fix', 'ok' if m > 20 else 'timeout', 40))
    if m % 5 == 0: c.append(L(m, 'canary', 'cn_direct', 'ok' if m > 20 else 'timeout', 60))
write('C', c)
# D: 代理正常, OpenAI 对出口 IP 返回 403
d = []
for m in range(60, 0, -1):
    d.append(L(m, 'node', 'Tokyo-Fix', 'ok', 40))
    if m % 5 == 0: d += [L(m, 'canary', 'google_204', 'ok', 200), L(m, 'canary', 'openai_api', 'region-blocked', 300, 'http=403'), L(m, 'canary', 'cn_direct', 'ok', 60)]
write('D', d)
# E: 一切正常
e = []
for m in range(60, 0, -1):
    e.append(L(m, 'node', 'Tokyo-Fix', 'ok', 40))
    if m % 5 == 0: e += [L(m, 'canary', 'google_204', 'ok', 200), L(m, 'canary', 'chatgpt_web', 'ok', 400), L(m, 'canary', 'openai_api', 'ok', 300), L(m, 'canary', 'cn_direct', 'ok', 60)]
write('E', e)
# F: 节点间歇性不可达 (现在正常)
f = []
for m in range(180, 0, -1):
    f.append(L(m, 'node', 'Tokyo-Fix', 'timeout' if 100 <= m < 110 else 'ok', 40))
write('F', f)
# access: ChatGPT 的连接全部直连 (app 被设成「关」)
acc = "ts\tid\tnet\thost\tport\tapp\tuser\troute\tnode\treason\tresult\terr\tdur\tips\terrmsg\tpath\tcapture\n"
for i in range(8): acc += f"{t(2 + i)}\t{i}\ttcp\tchatgpt.com\t443\tChatGPT\t<user>\tdirect\tdirect-app\tapp\terror\ttimeout\t10000\t\t\t\tmixed\n"
open(f'{sp}/acc', 'w').write(acc)
# ops: 8 分钟前被其它设备踢下线
open(f'{sp}/ops', 'w').write(f"ts\twho\taction\tdetail\tresult\n{t(480)}\tdashboard\t开启代理\tenabled=1\tok\n{t(8)}\tauto\t已被退出登录\treason=kicked http=401 proxy_was=1\tok\n")
PY
printf 'proxy.enabled=1\nservice.running=1\ncapture.mode=system\nports.proxy=%s\naccount.logged_in=yes\n' "$PORT" > "$SP/meta"
printf 'sysproxy.HTTPEnable=1\nsysproxy.HTTPProxy=127.0.0.1\nsysproxy.HTTPPort=%s\nsysproxy.points_to_enana=yes\n' "$PORT" > "$SP/env"
printf 'sysproxy.HTTPEnable=0\nsysproxy.points_to_enana=no\n' > "$SP/env.off"
printf 'proxy.enabled=0\nservice.running=1\ncapture.mode=system\nports.proxy=%s\naccount.logged_in=no\n' "$PORT" > "$SP/meta.off"
printf 'proxy.enabled=1\nservice.running=0\ncapture.mode=system\nports.proxy=%s\naccount.logged_in=yes\n' "$PORT" > "$SP/meta.core"
v() { perl "$LIB/health.pl" verdict "$NOW" "$SP/$1" "${2:-/dev/null}" "${3:-/dev/null}" "${4:-$SP/meta}" "${5:-$SP/env}" "Tokyo-Fix:pin"; }
V=$(v A /dev/null /dev/null "$SP/meta" "$SP/env.off")
has "A 系统代理没开 (节点一直正常): cause=sysproxy-off, 归因 client, 高置信" "^verdict.cause=sysproxy-off" "$V"; has "A: blame=client" "^verdict.blame=client" "$V"; has "A: 说明自哪个时刻起 (120 分钟前的 state 行)" "^verdict.since=" "$V"
has "A: 摘要点明「不需要终端」" "不需要终端" "$V"; has "A: 节点可达率 100% 作为证据" "^verdict.node.Tokyo-Fix=role=pin reachable=100.0%" "$V"
V=$(v A "$SP/ops" "$SP/acc" "$SP/meta" "$SP/env.off")
has "A+访问记录: ChatGPT 直连 (app 被设成关) 也被列出 (also)" "chatgpt-direct" "$V"
V=$(v B)
has "B 节点最近 20 分钟不可达、对照站点正常: cause=node-down, blame=node" "^verdict.cause=node-down" "$V"; has "B: blame=node" "^verdict.blame=node" "$V"; has "B: 故障时段 (ONGOING)" "^verdict.outage.*node/Tokyo-Fix timeout ONGOING" "$V"
V=$(v C)
has "C 对照站点也不通 → local-network-down (blame=network), 不会冤枉服务器" "^verdict.cause=local-network-down" "$V"
V=$(v D)
has "D OpenAI 对出口 IP 返回 403: cause=openai-region-blocked, blame=exit-ip" "^verdict.cause=openai-region-blocked" "$V"; has "D: blame=exit-ip" "^verdict.blame=exit-ip" "$V"
V=$(v E)
has "E 一切正常: cause=no-issue-found, blame=none" "^verdict.cause=no-issue-found" "$V"
V=$(v F)
has "F 节点曾间歇性不可达 (现在正常): cause=node-unstable" "^verdict.cause=node-unstable" "$V"
V=$(v E "$SP/ops" /dev/null "$SP/meta.off" "$SP/env")
has "G 总开关是关闭的: cause=proxy-disabled" "^verdict.cause=proxy-disabled" "$V"; has "G: 说明是被其它设备踢下线触发的 (reason=kicked)" "reason=kicked" "$V"
V=$(v E /dev/null /dev/null "$SP/meta.core" "$SP/env")
has "H 代理核心没运行: cause=core-down" "^verdict.cause=core-down" "$V"
printf 'sysproxy.enabled=1\nsysproxy.server=http=127.0.0.1:%s;https=127.0.0.1:%s\nsysproxy.pac_present=False\n' "$PORT" "$PORT" > "$SP/env.win"
printf 'sysproxy.enabled=0\nsysproxy.server=\n' > "$SP/env.win.off"
printf 'capture.mode=system\n' > "$SP/env.unknown"
V=$(v E /dev/null /dev/null "$SP/meta" "$SP/env.win")
has "Windows 导出 (sysproxy.enabled / server) 指向 enana: 不误报系统代理没开" "^verdict.cause=no-issue-found" "$V"
V=$(v E /dev/null /dev/null "$SP/meta" "$SP/env.win.off")
has "Windows 导出里系统代理没开: 同样判 sysproxy-off" "^verdict.cause=sysproxy-off" "$V"
V=$(v E /dev/null /dev/null "$SP/meta" "$SP/env.unknown")
hasnt "拿不到系统代理信息 (旧版导出): 不做这一项判断, 不乱下结论" "^verdict.cause=sysproxy-off" "$V"
printf '' > "$SP/empty"
V=$(v empty /dev/null /dev/null "$SP/meta" "$SP/env")
has "I 没有任何数据 (刚升级): cause=insufficient-data, 不乱下结论" "^verdict.cause=insufficient-data" "$V"
V=$(perl "$LIB/health.pl" outages < "$SP/F")
has "outages: 找出 10 分钟的间歇故障时段" "node	Tokyo-Fix	timeout	10" "$V"
V=$(perl "$LIB/health.pl" summary 30 < "$SP/F" | head -3)
has "summary: 分桶统计带列名和 fail 次数" "^bucket	kind	target	n	ok	fail" "$V"

P=$(grep -c . "$W/.pass"); F=$(grep -c . "$W/.fail")
echo; echo "健康记录测试: $P 通过, $F 失败"
[ "$F" = 0 ]
