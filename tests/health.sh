#!/bin/bash
# 连接健康记录 (lib/health.sh + lib/health.pl) 和会话心跳事件: 几秒钟, 不需要 sing-box / 网络 / 管理员权限, macOS 和 Linux 都能跑。
#   · 每分钟 tick: 服务器端口 (真实的本机监听端口 / 关闭的端口) · 经代理的金丝雀分类 (ok / region-blocked / timeout …) · 状态变化 → 操作记录 + state 行 · 休眠间隔
#   · 「操作记录」开关关闭时一并不记 · 心跳失败 / 恢复 / 被踢下线的操作记录
#   · 自动线路 (AUTO / PINAUTO) 选中的节点探测不通 → 立刻请核心重测这个组 (限频 / 不触发的情形 / 只在真的换了节点时记录)
#   · 2.3.27: 走 UDP 的节点不做 TCP 探测, 选中的那一个由核心测速 (H11) · 本机断网时不换节点, 只记一行断网 (H12) · 换了节点后断开坏节点上的连接 (H13) · 断网的判定 (H14)
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
  local url='' a v g m=GET prev=''
  for a in "$@"; do case $prev in -X) m=$a ;; esac; case $a in http*) url=$a ;; esac; prev=$a; done
  case $url in
    */version) printf '200'; return 0 ;;
    # 单个节点测速 (H11-H13: 走 UDP 的选中节点 / 换节点后单独测旧节点): 记下调用 (路径里的节点名保持 URL 编码的原样);
    # $W/pd.<路径里的名字> 是 HTTP 状态码 (没有这个文件 = 200, 延迟 88; rcN = curl 自己失败, 退出码 N); 照 curl -w '\n%{http_code}' 的样子最后一行输出状态码
    */proxies/*/delay*) g=${url#*/proxies/}; g=${g%%/delay*}; printf '%s %s\n' "$g" "$url" >> "$W/pdelay.calls"; v=$(cat "$W/pd.$g" 2>/dev/null || printf 200)
      case $v in rc*) return "${v#rc}" ;; 200) printf '{"delay":88}\n200' ;; 503) printf '{"message":"An error occurred in the delay test"}\n503' ;; 504) printf '{"message":"Timeout"}\n504' ;; *) printf '{"message":"Resource not found"}\n%s' "$v" ;; esac
      return 0 ;;
    # 核心里的连接 (H13): GET /connections 返回 $W/conns.json; DELETE /connections/<id> 记下 「方法 id」; 有 $W/del.rc 时断开失败 (curl 退出码)
    */connections) printf 'x\n' >> "$W/conns.calls"; cat "$W/conns.json" 2>/dev/null; return 0 ;;
    */connections/*) printf '%s %s\n' "$m" "${url##*/}" >> "$W/closed"; [ ! -f "$W/del.rc" ] || return "$(cat "$W/del.rc")"; return 0 ;;
    */proxies/svc-chatgpt) printf '{"now":"PIN","type":"Selector"}'; return 0 ;;
    */proxies/PIN) printf '{"now":"Pin-A","type":"Selector"}'; return 0 ;;
    */proxies/Final) printf '{"now":"Global","type":"Selector"}'; return 0 ;;
    # 自动选线组 (H10): 当前选择来自 $W/now.<组> (JSON 字符串里的原文); 没有这个文件 = 核心没运行 / 没有这个组。
    # 组测速: 记下调用; 有 $W/next.<组> 就把它变成当前选择 (= 核心测完改选了), 返回 $W/delay.body
    */proxies/AUTO|*/proxies/PINAUTO) g=${url##*/}; [ ! -f "$W/now.$g" ] || printf '{"type":"URLTest","name":"%s","now":"%s","all":[]}' "$g" "$(cat "$W/now.$g")"; return 0 ;;
    */group/*/delay*) g=${url#*/group/}; g=${g%%/*}; printf '%s %s\n' "$g" "$url" >> "$W/delay.calls"; [ ! -f "$W/next.$g" ] || mv -f "$W/next.$g" "$W/now.$g"; cat "$W/delay.body" 2>/dev/null; return 0 ;;
    */proxies/*) printf '{"type":"Socks"}'; return 0 ;;
    *gstatic*) v=$C_GOOGLE ;; *chatgpt.com*) v=$C_CHATGPT ;; *api.openai.com*) v=$C_OPENAI ;; *captive.apple*) v=$C_CN ;; *) v=200 ;;
  esac
  case $v in rc*) return "${v#rc}" ;; esac
  printf '%s\t0.012\t0.250' "$v"
}

# 本机监听端口 = 「服务器」; 另一个关闭的端口 = 「挂掉的服务器」
# 监听器放在子 shell 里启动: health_canaries 里的 wait 会等本 shell 的所有后台任务, 监听器不能是它的子任务
cat > "$W/listener.py" <<'PY'
import os, socket, sys, time
s = socket.socket(); s.bind(('127.0.0.1', 0)); s.listen(8)
open(sys.argv[1] + '.pid', 'w').write(str(os.getpid())); open(sys.argv[1], 'w').write(str(s.getsockname()[1]))
s.settimeout(0.3); end = time.time() + 900
while time.time() < end:
    try: c, _ = s.accept(); c.close()
    except Exception: pass
PY
( python3 "$W/listener.py" "$W/port" >/dev/null 2>&1 & )
for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$W/port" ] && break; sleep 0.25; done
LPID=$(cat "$W/port.pid" 2>/dev/null)
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
OPS4=$(ops)
has "「已被退出登录」: 来源 auto, 详情 reason=limit http=401 proxy_was=1 (以前是 terminal 且详情不是 key=value)" "auto	已被退出登录	reason=limit http=401 proxy_was=1 " "$OPS4"
has "…带上距上次心跳成功的秒数 since_ok_s (判断「一直正常后被撤销」还是「早就连不上」)" "已被退出登录.*since_ok_s=[0-9][0-9]*" "$OPS4"
has "…带上会话尾号和调用链 (session=… via=session_heartbeat)" "session=id-1 via=session_heartbeat" "$OPS4"
has "…云端没给 code 时只记 raw_reason, 不凭空编 resp_code" "raw_reason=limit	ok" "$OPS4"
session_call() { printf '401'; printf '{"code":"unauthorized"}' > "$1"; }
session_heartbeat >/dev/null
has "令牌被云端直接拒绝 (没有 reason, resp_code=unauthorized): 登录框仍记 kicked, 日志里能和「真被踢」区分" "reason=kicked http=401 .*resp_code=unauthorized" "$(ops)"
eq "心跳状态文件记下最近一次结果 (code=401)" "$(session_hb_get code)" "401"
eq "…并保留最近一次成功的时间 (ok 不被失败覆盖)" "$([ -n "$(session_hb_get ok)" ] && echo kept || echo lost)" "kept"

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


echo "== H6. 自动判定 (新): 固定出口为空 · 节点按角色判断 · TUN 下 DNS 绕过 · 总开关是被谁关的"
python3 - "$SP" "$NOW" <<'PY'
import sys, os, datetime as dt
sp, now = sys.argv[1], int(sys.argv[2])
def t(m): return dt.datetime.fromtimestamp(now - m * 60).strftime('%Y-%m-%d %H:%M:%S')
def L(m, kind, target, result, ms, det=''): return f"{t(m)}\t{kind}\t{target}\t{result}\t{ms}\t{det}\n"
def w(name, txt): open(f'{sp}/{name}', 'w').write(txt)
def build(down, ai=False):
    rows = []
    for m in range(60, 0, -1):
        for n in ('Auto-1', 'Auto-2', 'Auto-3', 'Auto-4', 'Tokyo-Fix'):
            bad = n in down and m <= 40
            rows.append(L(m, 'node', n, 'timeout' if bad else 'ok', 0 if bad else 40))
        if m % 5 == 0:
            rows += [L(m, 'canary', 'google_204', 'ok', 200), L(m, 'canary', 'cn_direct', 'ok', 60)]
            if ai: rows += [L(m, 'canary', 'chatgpt_web', 'timeout', 0), L(m, 'canary', 'openai_api', 'timeout', 0)]
    return ''.join(rows)
w('P1', build({'Auto-4'}, ai=True))                 # 4 台自动节点坏 1 台, 同时 AI 站点全部超时 (真实案例: 38 台里坏 1 台)
w('N1', build({'Auto-1', 'Auto-2', 'Auto-3'}))      # 一半以上的自动节点不可达
w('N2', build({'Tokyo-Fix'}))                       # 固定出口节点不可达
w('N3', build({'Auto-4'}))                          # 只有 1 个自动节点不可达, 没有别的问题
acc = "ts\tid\tnet\thost\tport\tapp\tuser\troute\tnode\treason\tresult\terr\tdur\tips\terrmsg\tpath\tcapture\n"
for i in range(9): acc += f"{t(2 + i)}\t{i}\ttcp\tchatgpt.com\t443\tChatGPT\t<user>\tdirect\tdirect\tpolicy\terror\ttimeout\t10000\t\t\t\tmixed\n"
w('accp', acc)
base = f"sysproxy.HTTPEnable=1\nsysproxy.HTTPProxy=127.0.0.1\nsysproxy.HTTPPort={os.environ['PORT']}\nsysproxy.points_to_enana=yes\n"
w('env.pin0', base + 'pin.servers=0\npin.app_policies=1\npin.selectors_on_pin=7\n')
w('env.pin1', base + 'pin.servers=1\npin.app_policies=1\npin.selectors_on_pin=7\n')
w('env.pinnone', base + 'pin.servers=0\npin.app_policies=0\npin.selectors_on_pin=0\n')
w('env.old', base)
w('env.tun', 'capture.tun.ready=yes\ndns.system=192.168.10.1 fe80::10%en0\n')
w('meta.tun', 'proxy.enabled=1\nservice.running=1\ncapture.mode=tun\nports.proxy=9\naccount.logged_in=yes\n')
hdr = "probe\tvia\turl\thttp\tconnect_ms\ttotal_ms\tremote_ip\tnote\n"
def probes(tun_http, sysans, coreans):
    return (hdr + "google_204\tproxy\thttp://www.gstatic.com/generate_204\t204\t0\t400\t127.0.0.1\tok\n"
        "google_page\tproxy\thttps://www.google.com/\t200\t0\t600\t127.0.0.1\tok\n"
        f"google_page\ttun\thttps://www.google.com/\t{tun_http}\t0\t0\t\t{'ok' if tun_http != '000' else 'curl-exit-28'}\n"
        f"dns_system\tsystem\twww.google.com\t-\t-\t-\t{sysans}\t\n"
        f"dns_core\tcore\twww.google.com\t-\t-\t-\t{coreans}\t\n")
w('pr.bad', probes('000', '2001::1 104.244.42.197', '142.251.155.119 142.251.153.119'))
w('pr.overlap', probes('000', '142.251.155.119', '142.251.155.119 142.251.153.119'))
w('pr.ok', probes('200', '2001::1 104.244.42.197', '142.251.155.119 142.251.153.119'))
# ops: 8 分钟前总开关被关 (调用链 via 记在「总开关变更」里), 随后记「已被退出登录」
w('ops.sw', f"ts\twho\taction\tdetail\tresult\n{t(8)}\tauto\t总开关变更\tkey=PROXY_ENABLED from=1 to=0 via=_proxy_set<auth_logout_local<session_local_end<session_heartbeat pid=4242\tok\n{t(8)}\tauto\t已被退出登录\treason=kicked http=401 proxy_was=1\tok\n")
PY
V2() { perl "$LIB/health.pl" verdict "$NOW" "$SP/$1" "${2:-/dev/null}" "${3:-/dev/null}" "$4" "$5" "$6" "${7:-/dev/null}"; }
AUTO4="Auto-1:auto,Auto-2:auto,Auto-3:auto,Auto-4:auto"
V=$(V2 P1 /dev/null "$SP/accp" "$SP/meta" "$SP/env.pin0" "$AUTO4")
has "P1 固定出口为空 (总开关开着, 4 台自动节点坏 1 台): 主因是 pin-empty, 而不是那台坏节点" "^verdict.cause=pin-empty" "$V"
has "P1: 归因 client" "^verdict.blame=client" "$V"; has "P1: 有 policy 直连连接 → 高置信" "^verdict.confidence=high" "$V"
has "P1: 摘要点明 unsupported_country_region_territory 不是线路不稳定" "unsupported_country_region_territory 就是这个原因" "$V"
has "P1: 证据里有 pin.servers=0 和 policy 直连条数" "pin.servers=0 pin.app_policies=1 pin.selectors_on_pin=7 policy_direct_30m=9" "$V"
hasnt "P1: 只坏了 1 台自动节点, 不再被判成 node-down" "^verdict.cause=node-down" "$V"
has "P1: 那台坏节点只作为附带说明 (note.node_degraded)" "^note.node_degraded=" "$V"
has "P1: ChatGPT 直连仍作为附带结论列出" "chatgpt-direct" "$V"
has "P1: verdict.pin 汇总" "^verdict.pin=servers=0 app_policies=1 selectors_on_pin=7 policy_direct_30m=9" "$V"
V=$(V2 P1 /dev/null "$SP/accp" "$SP/meta.off" "$SP/env.pin0" "$AUTO4")
has "P2 总开关关着 + 固定出口为空: 主因仍是 proxy-disabled (最直接)" "^verdict.cause=proxy-disabled" "$V"; has "P2: pin-empty 在 also 里" "verdict.also.*pin-empty" "$V"
V=$(V2 P1 /dev/null "$SP/accp" "$SP/meta" "$SP/env.pin1" "$AUTO4")
hasnt "P3 已经有固定出口服务器: 不报 pin-empty" "pin-empty" "$V"
V=$(V2 P1 /dev/null "$SP/accp" "$SP/meta" "$SP/env.pinnone" "$AUTO4")
hasnt "P4 没有任何应用 / 服务选「固定出口」: 固定出口为空无所谓, 不报" "pin-empty" "$V"
V=$(V2 P1 /dev/null "$SP/accp" "$SP/meta" "$SP/env.old" "$AUTO4")
hasnt "P5 旧版导出 (env 里没有 pin.*): 不凭空下结论" "pin-empty" "$V"
V=$(V2 N1 /dev/null /dev/null "$SP/meta" "$SP/env.old" "$AUTO4")
has "N1 一半以上自动节点不可达: 仍判 node-down" "^verdict.cause=node-down" "$V"
V=$(V2 N2 /dev/null /dev/null "$SP/meta" "$SP/env.old" "Tokyo-Fix:pin,Auto-1:auto,Auto-2:auto,Auto-3:auto,Auto-4:auto")
has "N2 固定出口节点不可达: 判 node-down (固定出口不会漂移, 真的会影响使用)" "^verdict.cause=node-down" "$V"
V=$(V2 N3 /dev/null /dev/null "$SP/meta" "$SP/env.old" "Tokyo-Fix:pin,Auto-1:auto,Auto-2:auto,Auto-3:auto,Auto-4:auto")
hasnt "N3 只有 1 台自动节点不可达、没有别的问题: 不是 node-down" "^verdict.cause=node-down" "$V"
has "N3: 结论是没发现明确故障" "^verdict.cause=no-issue-found" "$V"; has "N3: 坏节点只在 note 里" "^note.node_degraded=" "$V"
V=$(V2 N3 /dev/null /dev/null "$SP/meta" "$SP/env.old" "")
has "没有角色信息 (旧导出): 按原来的方式, 坏节点算 node-down" "^verdict.cause=node-down" "$V"
V=$(V2 E /dev/null /dev/null "$SP/meta.tun" "$SP/env.tun" "Tokyo-Fix:pin" "$SP/pr.bad")
has "T1 TUN + 系统 DNS 是局域网地址 + 答案和核心完全不同 + 走 TUN 的探测失败: tun-dns-bypass" "^verdict.cause=tun-dns-bypass" "$V"
has "T1: 摘要写明系统 DNS 和两边的答案" "192[.]168[.]10[.]1.*104[.]244[.]42[.]197.*142[.]251[.]155[.]119" "$V"
V=$(V2 E /dev/null /dev/null "$SP/meta.tun" "$SP/env.tun" "Tokyo-Fix:pin" "$SP/pr.overlap")
hasnt "T2 答案有交集 (只是 CDN 差异): 不报" "tun-dns-bypass" "$V"
V=$(V2 E /dev/null /dev/null "$SP/meta.tun" "$SP/env.tun" "Tokyo-Fix:pin" "$SP/pr.ok")
hasnt "T3 走 TUN 的探测是通的: 不报 (DNS 不一样但没造成问题)" "tun-dns-bypass" "$V"
V=$(V2 E /dev/null /dev/null "$SP/meta" "$SP/env.tun" "Tokyo-Fix:pin" "$SP/pr.bad")
hasnt "T4 不是 TUN 模式: 不报 (系统代理模式下解析在代理端完成)" "tun-dns-bypass" "$V"
V=$(V2 E "$SP/ops.sw" /dev/null "$SP/meta.off" "$SP/env.old" "Tokyo-Fix:pin")
has "S1 总开关是被谁关的: 摘要里带调用链 via=…session_local_end<session_heartbeat" "via=_proxy_set<auth_logout_local<session_local_end<session_heartbeat" "$V"

echo "== H7. 埋点: 总开关变更 · 核心重启 · 心跳状态 · 固定出口 / 会话事实"
reset; PROXY_ENABLED=0
caller_a() { proxy_set_enabled "$1"; }; caller_b() { caller_a "$1"; }
caller_b 1
O7=$(ops)
has "总开关 0→1: 记「总开关变更」, 带来源 key / from / to" "auto	总开关变更	key=PROXY_ENABLED from=0 to=1 " "$O7"
has "…调用链说明是谁改的" "via=_proxy_set<proxy_locked<proxy_set_enabled<caller_a<caller_b" "$O7"
caller_b 1
eq "值没有变化 (1→1) 不重复记录" "$(ops | grep -c 总开关变更)" "1"
OP_WHO=dashboard caller_b 0
has "来源取 OP_WHO (dashboard): 1→0 时再记一条" "dashboard	总开关变更	key=PROXY_ENABLED from=1 to=0 " "$(ops)"
os_service_pid() { printf '4321'; }
restart_via() { core_restart_note; }; restart_via2() { restart_via; }
OP_WHO=terminal restart_via2
has "核心重启前记「重启核心」: 带调用链和当时的核心 pid / 总开关" "terminal	重启核心	via=restart_via<restart_via2 pid=4321 proxy=0	ok" "$(ops)"
reset; printf 'sid-9999\n' > "$H/session"; printf 'tok\n' > "$H/cloud.token"; printf 'a@b.c 1\n' > "$H/loggedin"
session_hb_note 200; sleep 1; session_hb_note 000
eq "心跳状态: code 取最近一次, ok 保留最近一次成功" "$(session_hb_get code)/$([ -n "$(session_hb_get ok)" ] && echo ok-kept)" "000/ok-kept"
device_uid() { printf 'abcd1234-aaaa-bbbb-cccc-dddddddddddd'; }
STUB_LOGIN=1; S7=$(_b_sessionfacts)
has "会话事实: state=logged-in" "session.state=logged-in" "$S7"; has "…会话尾号 session.id_tail=9999" "session.id_tail=9999" "$S7"; has "…设备尾号 (和云端 device_uid 前 8 位对得上)" "session.device_tail=abcd1234" "$S7"
has "…最近一次心跳的结果" "session.last_heartbeat_code=000" "$S7"; has "…最近一次成功距现在多久" "session.last_heartbeat_ok_age_s=[0-9][0-9]*" "$S7"
STUB_LOGIN=0; eq "没登录: 只报 logged-out" "$(_b_sessionfacts)" "session.state=logged-out"
srv_list() { printf 'N1\tvless\t1.2.3.4\t443\tauto\t\nN2\tvless\t1.2.3.5\t443\tauto\t\n'; }
clash() { printf '{"proxies":{"PIN":{"type":"Selector","now":"direct","all":["direct"]},"svc-chatgpt":{"type":"Selector","now":"PIN","all":["PIN","Global","direct"]},"svc-claude":{"type":"Selector","now":"PIN","all":["PIN","Global","direct"]},"Global":{"type":"Selector","now":"AUTO","all":["AUTO"]}}}'; }
apps_json() { printf '[{"name":"ChatGPT","state":"pin"},{"name":"Safari","state":"direct"}]'; }; apps_installed() { :; }
PF=$(_b_pinfacts)
has "固定出口事实: 没有 pin 角色的服务器 → pin.servers=0" "^pin.servers=0$" "$PF"; has "…PIN 组里只有 direct" "^pin.group_members=direct$" "$PF"
has "…有几个选择器当前选的是 PIN (svc-chatgpt / svc-claude)" "^pin.selectors_on_pin=2$" "$PF"; has "…选了固定出口的应用数" "^pin.app_policies=1$" "$PF"
unset -f apps_json apps_installed device_uid; . "$LIB/servers.sh"; . "$LIB/config.sh"; . "$LIB/os-darwin.sh"      # 还原上面为 H7 临时替换的函数, 不影响后面的测试


echo "== H8. 固定出口为空: 状态里的 pin=… · 状态变化事件 · 第一次观察就为空也记一笔"
reset; setsrv "$OPEN"; printf '{"outbounds":[{"type":"selector","tag":"svc-chatgpt","default":"PIN"}]}' > "$H/config.json"
health_tick
has "有固定出口服务器: state 行里 pin=ok" "pin=ok" "$(hf)"
printf '{"role":"auto","outbound":{"type":"socks","tag":"Auto-A","server":"127.0.0.1","server_port":%s}}\n' "$OPEN" > "$H/servers.jsonl"
health_tick
has "固定出口服务器没了 + 有服务默认走固定出口: pin=empty" "pin=empty" "$(hf)"
has "状态变化记一笔: item=pin from=ok to=empty (带依赖数)" "环境状态变化	item=pin from=ok to=empty pin_servers=0 dependents=1" "$(ops)"
reset; printf '{"role":"auto","outbound":{"type":"socks","tag":"Auto-A","server":"127.0.0.1","server_port":%s}}\n' "$OPEN" > "$H/servers.jsonl"; printf '{"outbounds":[{"type":"selector","tag":"svc-claude","default":"PIN"}]}' > "$H/config.json"
health_tick
has "第一次观察就是空的 (例如重装后): 也记一笔 (from=-)" "item=pin from=- to=empty" "$(ops)"
reset; printf '{"role":"auto","outbound":{"type":"socks","tag":"Auto-A","server":"127.0.0.1","server_port":%s}}\n' "$OPEN" > "$H/servers.jsonl"; printf '{"outbounds":[]}' > "$H/config.json"; rm -rf "$H/rules"
health_tick
has "没有任何服务 / 应用 / 网站依赖固定出口: pin=ok (空也无所谓)" "pin=ok" "$(hf)"
hasnt "…也不记事件" "item=pin" "$(ops)"
mkdir -p "$H/rules/ovr-apppin"; printf '{"version":2,"rules":[{"process_name":["ChatGPT"]}]}' > "$H/rules/ovr-apppin/ovr-apppin.json"
eq "应用选了固定出口 (ovr-apppin 规则集有内容): 算一个依赖" "$(pin_dependents)" "1"
printf '{"outbounds":[{"tag":"a","default":"PIN"},{"tag":"b","default":"PIN"}]}' > "$H/config.json"
eq "再加 2 个默认走固定出口的服务: 共 3 个依赖" "$(pin_dependents)" "3"
rm -rf "$H/rules" "$H/config.json"


echo "== H9. 经某台服务器的连接超时 (node-connect-timeouts) · TUN 下的探测绑定物理网卡"
python3 - "$SP" "$NOW" <<'PY'
import sys, datetime as dt
sp, now = sys.argv[1], int(sys.argv[2])
def t(m): return dt.datetime.fromtimestamp(now - m * 60).strftime('%Y-%m-%d %H:%M:%S')
def acc(rows):
    out = "ts\tid\tnet\thost\tport\tapp\tuser\troute\tnode\treason\tresult\terr\tdur\tips\terrmsg\tpath\tcapture\n"
    for i, (m, route, node, res, err) in enumerate(rows):
        out += f"{t(m)}\t{i}\ttcp\th{i}.example\t443\tChatGPT\t<user>\t{route}\t{node}\t\t{res}\t{err}\t100\t\t\t\tmixed\n"
    return out
def mk(pin_n, pin_to, auto_n=200, auto_to=1, recent_to=None):
    rows = []
    for i in range(pin_n):
        bad = i < pin_to
        m = (2 + i % 20) if (bad and (recent_to is None or i < recent_to)) else (40 + i % 100)
        rows.append((m, 'pin', 'Tokyo-Pin', 'error' if bad else 'ok', 'timeout' if bad else ''))
    for i in range(auto_n): rows.append((40 + i % 100, 'auto', 'Auto-1', 'error' if i < auto_to else 'ok', 'timeout' if i < auto_to else ''))
    return acc(rows)
open(f'{sp}/acc.t6', 'w').write(mk(100, 6))                        # 固定出口 6% 超时, 一直在发生
open(f'{sp}/acc.t1', 'w').write(mk(100, 1))                        # 固定出口 1%: 正常的偶发
open(f'{sp}/acc.tfew', 'w').write(mk(20, 10))                      # 样本太少 (20 条)
open(f'{sp}/acc.tauto', 'w').write(mk(100, 0, auto_n=200, auto_to=16))   # 自动线路节点 8% (=16/200): 达到自动线路的阈值
open(f'{sp}/acc.tauto5', 'w').write(mk(100, 0, auto_n=200, auto_to=10))  # 自动线路节点 5%: 不够
open(f'{sp}/acc.told', 'w').write(mk(100, 6, recent_to=0))         # 超时都发生在 30 分钟之前
rows = ''
for m in range(120, 0, -1):
    rows += f"{t(m)}\tnode\tTokyo-Pin\tok\t4\trole=pin mode=tun\n"
    if m % 5 == 0: rows += f"{t(m)}\tcanary\tgoogle_204\tok\t200\n{t(m)}\tcanary\tcn_direct\tok\t60\n"
open(f'{sp}/H.tun', 'w').write(rows)
open(f'{sp}/H.bound', 'w').write(rows.replace('role=pin mode=tun', 'role=pin mode=tun probe=bound'))
open(f'{sp}/meta.tunok', 'w').write('proxy.enabled=1\nservice.running=1\ncapture.mode=tun\nports.proxy=9\naccount.logged_in=yes\n')
open(f'{sp}/env.tunok', 'w').write('capture.tun.ready=yes\npin.servers=1\npin.app_policies=1\npin.selectors_on_pin=3\n')
PY
RPIN="Tokyo-Pin:pin,Auto-1:auto"
V=$(V2 H.tun /dev/null "$SP/acc.t6" "$SP/meta.tunok" "$SP/env.tunok" "$RPIN")
has "N1 固定出口 6% 连接超时 (健康探测显示 100% 可达): 主因是 node-connect-timeouts, 归因 node" "^verdict.cause=node-connect-timeouts" "$V"; has "N1: blame=node" "^verdict.blame=node" "$V"; has "N1: 一直在发生 → 置信 high" "^verdict.confidence=high" "$V"
has "N1: 证据带连接数 / 超时数 / 百分比" "verdict.evidence.1=node=Tokyo-Pin conns=100 timeouts=6 [(]6[.]0%[)]" "$V"
has "N1: 摘要点明固定出口不会漂移、直接影响 ChatGPT / Claude" "固定出口不会漂移到别的国家" "$V"
V=$(V2 H.tun /dev/null "$SP/acc.t1" "$SP/meta.tunok" "$SP/env.tunok" "$RPIN"); hasnt "N2 固定出口 1% 超时 (偶发): 不报" "node-connect-timeouts" "$V"
V=$(V2 H.tun /dev/null "$SP/acc.tfew" "$SP/meta.tunok" "$SP/env.tunok" "$RPIN"); hasnt "N3 样本太少 (20 条): 不下结论" "node-connect-timeouts" "$V"
V=$(V2 H.tun /dev/null "$SP/acc.tauto" "$SP/meta.tunok" "$SP/env.tunok" "$RPIN"); has "N4 自动线路节点 8% 超时: 报" "^verdict.cause=node-connect-timeouts" "$V"
V=$(V2 H.tun /dev/null "$SP/acc.tauto5" "$SP/meta.tunok" "$SP/env.tunok" "$RPIN"); hasnt "N5 自动线路节点 5% 超时: 不够, 不报 (自动选线会避开)" "node-connect-timeouts" "$V"
V=$(V2 H.tun /dev/null "$SP/acc.told" "$SP/meta.tunok" "$SP/env.tunok" "$RPIN"); has "N6 超时都在 30 分钟之前: 仍报, 但置信降为 medium" "^verdict.confidence=medium" "$V"
V=$(V2 H.tun /dev/null /dev/null "$SP/meta.tunok" "$SP/env.tunok" "$RPIN"); has "N7 TUN + 探测不是绑定网卡做的: 说明 100% 可达不可信 (note.node_probe_tun)" "^note.node_probe_tun=120" "$V"
V=$(V2 H.bound /dev/null /dev/null "$SP/meta.tunok" "$SP/env.tunok" "$RPIN"); hasnt "N8 探测已绑定物理网卡: 没有这条说明" "node_probe_tun" "$V"
export ENANA_PROBE_IFINDEX=$(ifconfig -v lo0 2>/dev/null | sed -n '1s/.* index \([0-9][0-9]*\).*/\1/p')
if [ -n "$ENANA_PROBE_IFINDEX" ]; then
  PB=$(printf 'o\t127.0.0.1\t%s\nc\t127.0.0.1\t%s\n' "$OPEN" "$CLOSED" | perl "$LIB/health.pl" probe 3)
  has "绑定接口的探测 (lo0): 开着的端口 → ok" "^o	ok	" "$PB"; has "绑定接口的探测: 关着的端口 → refused" "^c	refused	" "$PB"
  PB=$(printf 'o\t127.0.0.1\t%s\n' "$OPEN" | ENANA_PROBE_IFINDEX=65000 perl "$LIB/health.pl" probe 3)
  has "接口序号无效: 退回原来的探测, 不会因此失败" "^o	ok	" "$PB"
fi
unset ENANA_PROBE_IFINDEX


echo "== H10. 自动线路: 选中的节点探测不通 → 立刻请核心重测这个组 (每组每分钟最多一次; 真的换了节点才记一笔); 探测正常时什么都不做"
r10() { reset; rm -f "$W"/now.* "$W"/next.* "$W/delay.calls" "$W"/pd.* "$W/pdelay.calls" "$W/conns.json" "$W/conns.calls" "$W/closed" "$W/del.rc"; printf '{"Auto-Live":120}' > "$W/delay.body"; }
srvl() { printf '{"role":"%s","outbound":{"type":"%s","tag":"%s","server":"127.0.0.1","server_port":%s}}\n' "$1" "$2" "$3" "$4"; }    # <角色> <类型> <标签> <端口>
setauto() { { srvl auto socks Auto-Dead "$CLOSED"; srvl auto socks Auto-Live "$OPEN"; } > "$H/servers.jsonl"; }       # 一台不通 (关着的端口) + 一台通的
calls() { cat "$W/delay.calls" 2>/dev/null | grep -c .; }
age() { awk -F'\t' -v s="$2" 'BEGIN { OFS = "\t" } { $1 -= s; print }' "$H/.health.retest-$1" > "$W/age.t" && mv -f "$W/age.t" "$H/.health.retest-$1"; }   # <组> <秒>: 上一次重测往前挪 (= 过了这么久)
r10; setauto; printf 'Auto-Live' > "$W/now.AUTO"
health_tick
eq "选中的 Auto-Live 是通的 (另一台不通): 不重测 —— 探测正常时行为不变" "$(calls)" "0"
hasnt "…没有自动线路的操作记录" "item=auto_select" "$(ops)"
has "…没选中的那台照常探测、照常记录" "	node	Auto-Dead	refused	" "$(hf)"
r10; setauto; printf 'Auto-Dead' > "$W/now.AUTO"; printf 'Auto-Live' > "$W/next.AUTO"
health_tick
eq "选中的 Auto-Dead 探测不通 (refused): 当场调用一次组测速" "$(calls)" "1"
has "…调用 /group/AUTO/delay, 给核心 18 秒 (长过它测一个节点的 15 秒上限, 坏节点才会被判为不可用)" "^AUTO http://127.0.0.1:$UI_PORT/group/AUTO/delay?url=http%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=18000$" "$(cat "$W/delay.calls")"
has "…核心改选了: 记「环境状态变化 item=auto_select from=Auto-Dead to=Auto-Live group=AUTO probe=refused」(来源 auto)" "	auto	环境状态变化	item=auto_select from=Auto-Dead to=Auto-Live group=AUTO probe=refused took_s=[0-9][0-9]*	ok$" "$(ops)"
health_tick
eq "下一次 tick 选中的是 Auto-Live (通的): 不再调用, 不会来回测" "$(calls)/$(ops | grep -c item=auto_select)" "1/1"
r10; setauto; printf 'Auto-Dead' > "$W/now.AUTO"; printf '{}' > "$W/delay.body"
health_tick; health_tick
eq "核心没给出任何结果 (它正在自己测速 / 全部连不上): 选择没变就不记录; 同一分钟内的第二次 tick 不再调用" "$(calls)/$(ops | grep -c item=auto_select)" "1/0"
age AUTO 61; health_tick
eq "…一分钟后仍然不通: 再试一次 (没有结果时不额外等待)" "$(calls)" "2"
r10; setauto; printf 'Auto-Dead' > "$W/now.AUTO"      # 返回 {"Auto-Live":120}: 别的节点测到了, 选中的那台没有结果 (到时间还没测完, 旧延迟还在) 却仍被选着
health_tick; age AUTO 61; health_tick
eq "核心仍选着它、但它自己没有测速结果: 不算「核心确认它是通的」, 一分钟后再试" "$(calls)/$(ops | grep -c item=auto_select)" "2/0"
r10; setauto; printf 'Auto-Dead' > "$W/now.AUTO"; printf '{"Auto-Dead":90,"Auto-Live":160}' > "$W/delay.body"
health_tick
eq "核心经代理测得通、仍然选它 (只是本机直连它的端口不通): 调用一次, 选择没变不记录" "$(calls)/$(ops | grep -c item=auto_select)" "1/0"
age AUTO 61; health_tick
eq "…同一个节点 5 分钟内不再触发 (不会每分钟把整组测一遍)" "$(calls)" "1"
age AUTO 300; health_tick
eq "…5 分钟后仍是它、仍不通: 再测一次" "$(calls)" "2"
r10; { srvl pin socks Pin-Dead "$CLOSED"; srvl pin socks Pin-Live "$OPEN"; } > "$H/servers.jsonl"
printf 'Pin-Dead' > "$W/now.PINAUTO"; printf 'Pin-Live' > "$W/next.PINAUTO"; printf 'Auto-X' > "$W/now.AUTO"
health_tick
eq "固定出口里自动选 (PINAUTO) 选中的 Pin-Dead 不通: 只重测 PINAUTO (没有自己的自动线路服务器时不看 AUTO; PIN 本身永远不动)" "$(cut -d' ' -f1 "$W/delay.calls" | paste -sd, -)" "PINAUTO"
has "…记一笔 group=PINAUTO" "item=auto_select from=Pin-Dead to=Pin-Live group=PINAUTO probe=refused" "$(ops)"
r10; { srvl auto hysteria2 Auto-H2 "$CLOSED"; srvl auto socks Auto-Live "$OPEN"; } > "$H/servers.jsonl"; printf 'Auto-H2' > "$W/now.AUTO"
health_tick
eq "选中的是 hysteria2 (走 UDP, TCP 端口不通不说明它坏了), 核心经它测得通: 不重测" "$(calls)" "0"
hasnt "…2.3.27 起根本不做 TCP 探测 (以前每分钟记一条假的 refused)" "	node	Auto-H2	refused	" "$(hf)"
has "…这一行的结果来自核心 (probe=core, 毫秒 = 核心测得的延迟)" "	node	Auto-H2	ok	88	role=auto mode=system probe=core$" "$(hf)"
r10; setauto; printf 'Auto-Dead' > "$W/now.AUTO"; PROXY_ENABLED=0
health_tick
eq "总开关关着 (流量都直连, 选哪个节点无所谓): 不重测" "$(calls)" "0"
r10; setauto
health_tick
eq "读不到组的当前选择 (核心没运行 / 没有这个组): 不重测, tick 照常完成" "$(calls)/$(hf | grep -c '	node	')" "0/2"
r10; { for _i in 1 2 3 4 5 6 7 8 9; do srvl auto socks "Auto-$_i" "$OPEN"; done; srvl auto socks Auto-Dead "$CLOSED"; } > "$H/servers.jsonl"
printf 'Auto-Dead' > "$W/now.AUTO"; printf 'Auto-1' > "$W/next.AUTO"
health_tick
eq "10 台自动线路服务器 (最多探测 8 台): 排在最后的选中节点排到最前面、一定被探测, 总数仍是 8" "$(hf | grep -c '	node	')/$(hf | grep -c '	node	Auto-Dead	refused	')" "8/1"
eq "…并且触发了重测" "$(calls)" "1"
r10; { srvl auto socks '东京 & 1' "$CLOSED"; srvl auto socks Auto-Live "$OPEN"; } > "$H/servers.jsonl"
BS=$(printf '\\')       # 一个反斜杠: 核心的 JSON 里中文是原样的 UTF-8, & 写成 ${BS}u0026 (Go 的 HTML 转义)
printf '%s' "东京 ${BS}u0026 1" > "$W/now.AUTO"; printf 'Auto-Live' > "$W/next.AUTO"
eq "测试数据本身: 核心返回的 now 里 & 是转义写法" "$(curl -s "http://127.0.0.1:$UI_PORT/proxies/AUTO" | grep -c '"now":"东京 \\u0026 1"')" "1"
health_tick
has "标签带中文 / 空格 / &: 核心返回的 now 解码后和 servers.jsonl 里的标签对得上, 照样重测并记录" "item=auto_select from=\"东京 & 1\" to=Auto-Live group=AUTO probe=refused" "$(ops)"
rm -f "$W"/now.* "$W"/next.* "$W/delay.calls" "$W/delay.body"


echo "== H11. 走 UDP 的节点 (hysteria2 / tuic, 2.3.27): 不做 TCP 探测; 只有自动选线组选中的那一个请核心经它测速 (probe=core), 测速失败同样当场重测这个组"
setudp() { { srvl auto hysteria2 Auto-H2 "$CLOSED"; srvl auto socks Auto-Live "$OPEN"; } > "$H/servers.jsonl"; printf 'Auto-H2' > "$W/now.AUTO"; }   # 选中的 hysteria2 + 一台通的 TCP 节点
pcalls() { cat "$W/pdelay.calls" 2>/dev/null | grep -c .; }
agec() { printf '%s\n' "$(( $(cat "$H/.health.core-$1") - $2 ))" > "$H/.health.core-$1"; }      # <组> <秒>: 上一次核心测速往前挪 (= 过了这么久)
r10; { srvl auto hysteria2 Auto-H2 "$CLOSED"; srvl auto tuic Auto-T "$CLOSED"; srvl auto socks Auto-Live "$OPEN"; } > "$H/servers.jsonl"; printf 'Auto-Live' > "$W/now.AUTO"
health_tick
hasnt "没选中的 hysteria2: 不做 TCP 探测 (以前一天几十条假的 refused)" "	node	Auto-H2	" "$(hf)"
hasnt "没选中的 tuic: 同样不探测" "	node	Auto-T	" "$(hf)"
eq "…也不问核心 (只问选中的那一个); TCP 节点照常探测" "$(pcalls)/$(hf | grep -c '	node	Auto-Live	ok	')" "0/1"
r10; setudp; health_tick
eq "选中的 hysteria2: 请核心经它测一次速, 测速地址和组测速一样, 超时 5 秒" "$(cat "$W/pdelay.calls")" "Auto-H2 http://127.0.0.1:$UI_PORT/proxies/Auto-H2/delay?url=http%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=5000"
r10; setudp; printf 'Auto-Live' > "$W/next.AUTO"; printf 504 > "$W/pd.Auto-H2"
health_tick
has "核心测速超时 (504): node 行记 timeout, probe=core" "	node	Auto-H2	timeout	5000	role=auto mode=system probe=core$" "$(hf)"
eq "…快速切换也覆盖走 UDP 的节点: 当场重测 AUTO (一次)" "$(cut -d' ' -f1 "$W/delay.calls" 2>/dev/null | paste -sd, -)" "AUTO"
has "…换了节点才记一笔, 写明是核心测速超时 (probe=core-timeout)" "	auto	环境状态变化	item=auto_select from=Auto-H2 to=Auto-Live group=AUTO probe=core-timeout took_s=[0-9][0-9]*	ok$" "$(ops)"
r10; setudp; printf 'Auto-Live' > "$W/next.AUTO"; printf 503 > "$W/pd.Auto-H2"
health_tick
has "核心测速出错 (503): 记 error" "	node	Auto-H2	error	0	role=auto mode=system probe=core$" "$(hf)"
has "…同样重测并记录 (probe=core-error)" "item=auto_select from=Auto-H2 to=Auto-Live group=AUTO probe=core-error " "$(ops)"
r10; setudp; health_tick; health_tick
eq "同一个组每分钟最多问一次核心: 紧接着的第二次 tick 不再问, 也不记这一行" "$(pcalls)/$(hf | grep -c '	node	Auto-H2	')" "1/1"
agec AUTO 60; health_tick
eq "…一分钟后再问" "$(pcalls)/$(hf | grep -c '	node	Auto-H2	')" "2/2"
r10; setudp; printf 404 > "$W/pd.Auto-H2"; health_tick
eq "核心不认识这个节点 (404): 不记这一行 (不知道就不乱记), 也不重测" "$(pcalls)/$(hf | grep -c '	node	Auto-H2	')/$(calls)" "1/0/0"
r10; setudp; printf rc28 > "$W/pd.Auto-H2"; health_tick
eq "控制接口没响应 (curl 超时): 同样不记、不重测; TCP 节点照常记" "$(hf | grep -c '	node	Auto-H2	')/$(calls)/$(hf | grep -c '	node	Auto-Live	ok	')" "0/0/1"
r10; { srvl pin tuic Pin-T "$CLOSED"; srvl pin socks Pin-Live "$OPEN"; } > "$H/servers.jsonl"; printf 'Pin-T' > "$W/now.PINAUTO"; printf 'Pin-Live' > "$W/next.PINAUTO"; printf 504 > "$W/pd.Pin-T"
health_tick
has "固定出口里自动选 (PINAUTO) 选中的 tuic 测速超时: 重测 PINAUTO 并记录" "item=auto_select from=Pin-T to=Pin-Live group=PINAUTO probe=core-timeout" "$(ops)"
eq "…只问了选中的 tuic 一次" "$(cut -d' ' -f1 "$W/pdelay.calls" | paste -sd, -)" "Pin-T"
r10; { srvl auto hysteria2 '大阪 & 2' "$CLOSED"; srvl auto socks Auto-Live "$OPEN"; } > "$H/servers.jsonl"
printf '%s' "大阪 ${BS}u0026 2" > "$W/now.AUTO"; printf 'Auto-Live' > "$W/next.AUTO"; printf 504 > "$W/pd.%E5%A4%A7%E9%98%AA%20%26%202"
printf '{"connections":[{"id":"cccccccc-0000-0000-0000-000000000001","chains":["大阪 %su0026 2","AUTO","Global","Final"]},{"id":"cccccccc-0000-0000-0000-000000000002","chains":["Auto-Live","AUTO","Global","Final"]}]}' "$BS" > "$W/conns.json"
health_tick
eq "标签带中文 / 空格 / &: 路径里的节点名按 UTF-8 逐字节 URL 编码" "$(cut -d' ' -f1 "$W/pdelay.calls")" "%E5%A4%A7%E9%98%AA%20%26%202"
has "…node 行用原来的标签" "	node	大阪 & 2	timeout	5000	role=auto mode=system probe=core$" "$(hf)"
has "…照样换节点; chains 里的 \\u0026 解码后对得上, 断开了经 AUTO 用着它的那条连接 (closed=1)" "item=auto_select from=\"大阪 & 2\" to=Auto-Live group=AUTO probe=core-timeout took_s=[0-9][0-9]* closed=1	ok$" "$(ops)"
eq "…断开的正是那一条" "$(cat "$W/closed")" "DELETE cccccccc-0000-0000-0000-000000000001"


echo "== H12. 本机断网 (2.3.27): 这一分钟探测的节点全部失败 (≥ 2 个) 或同一分钟里对照站点也失败 → 不换节点; 只记一行 state network outage, 不记各个节点的失败; 操作记录只在开始时记一条"
r10; { srvl auto socks Auto-Dead "$CLOSED"; srvl auto socks Auto-Dead2 "$CLOSED"; } > "$H/servers.jsonl"; printf 'Auto-Dead' > "$W/now.AUTO"; printf 'Auto-Dead2' > "$W/next.AUTO"
health_tick
eq "探测的 2 个节点全部失败: 不换节点 (换哪个都一样; 10-15 那次本机断网时 AUTO 还是被换了)" "$(calls)/$(ops | grep -c item=auto_select)" "0/0"
eq "…不记各个节点的失败, 只记一行 state network outage" "$(hf | grep -c '	node	')/$(hf | grep -c '	state	network	outage	')" "0/1"
has "…这一行带探测数 / 失败数 / 同一分钟的对照站点 / 失败的节点" "	state	network	outage	0	probed=2 failed=2 cn_direct=ok mode=system nodes=Auto-Dead,Auto-Dead2$" "$(hf)"
has "…操作记录一条「环境状态变化 item=network from=ok to=outage」" "	auto	环境状态变化	item=network from=ok to=outage probed=2 failed=2 cn_direct=ok	ok$" "$(ops)"
health_tick
eq "断网持续: 每分钟一行, 操作记录仍只有一条, 仍不换节点" "$(hf | grep -c '	state	network	outage	')/$(ops | grep -c item=network)/$(calls)" "2/1/0"
{ srvl auto socks Auto-Dead "$OPEN"; srvl auto socks Auto-Dead2 "$OPEN"; } > "$H/servers.jsonl"; health_tick
eq "网络恢复: 照常记 node 行, 没有新的断网行" "$(hf | grep -c '	node	Auto-Dead	ok	')/$(hf | grep -c '	state	network	')" "1/2"
{ srvl auto socks Auto-Dead "$CLOSED"; srvl auto socks Auto-Dead2 "$CLOSED"; } > "$H/servers.jsonl"; health_tick
eq "10 分钟内又断一次: 算同一次, 不再记操作记录 (时断时续的网络不会刷屏), 仍不换节点" "$(ops | grep -c item=network)/$(calls)" "1/0"
printf '%s\n' "$(( $(now) - 601 ))" > "$H/.health.net"; health_tick
eq "隔了 10 分钟以上再断: 新的一次, 再记一条" "$(ops | grep -c item=network)" "2"
r10; srvl auto socks Auto-Dead "$CLOSED" > "$H/servers.jsonl"; printf 'Auto-Dead' > "$W/now.AUTO"; printf 'Auto-X' > "$W/next.AUTO"
health_tick
eq "只探测了 1 个节点 (失败): 不算断网 (至少 2 个才这样判断), 照常记它的失败、照常重测" "$(hf | grep -c '	state	network	')/$(hf | grep -c '	node	Auto-Dead	refused	')/$(calls)" "0/1/1"
r10; setauto; printf 'Auto-Dead' > "$W/now.AUTO"; printf 'Auto-Live' > "$W/next.AUTO"; C_CN=rc28
health_tick
eq "同一分钟里对照站点 (cn_direct, 不经代理) 也失败: 不换节点" "$(calls)" "0"
has "…一行 state network outage, 带对照站点的结果和失败的节点" "	state	network	outage	0	probed=2 failed=1 cn_direct=timeout mode=system nodes=Auto-Dead$" "$(hf)"
has "…通的节点照常记" "	node	Auto-Live	ok	" "$(hf)"
hasnt "…失败的那一个不单独记" "	node	Auto-Dead	" "$(hf)"
health_tick
eq "…下一分钟 (这一分钟不做对照) 选中的节点仍不通、另一台是通的: 照常重测" "$(calls)" "1"
r10; { srvl auto socks Auto-Live "$OPEN"; srvl auto socks Auto-L2 "$OPEN"; } > "$H/servers.jsonl"; printf 'Auto-Live' > "$W/now.AUTO"; C_CN=rc28
health_tick
eq "对照站点失败但节点都通: 不算断网 (没有节点失败就没有可记的断网)" "$(hf | grep -c '	state	network	')/$(ops | grep -c item=network)/$(hf | grep -c '	node	Auto-')" "0/0/2"
r10; { srvl auto hysteria2 Auto-H2 "$CLOSED"; srvl auto socks Auto-Dead "$CLOSED"; } > "$H/servers.jsonl"; printf 'Auto-H2' > "$W/now.AUTO"; printf 504 > "$W/pd.Auto-H2"
health_tick
has "核心测速超时 + 另一台 TCP 探测失败 (全部 2 个): 同样是断网" "	state	network	outage	0	probed=2 failed=2 cn_direct=ok mode=system nodes=Auto-Dead,Auto-H2$" "$(hf)"
eq "…不重测" "$(calls)" "0"


echo "== H13. 换了节点、而且旧节点自己的核心测速也失败了: 断开核心里还经这个组用着旧节点的连接 (核心自己不会断开: 坏节点上已建立的连接会一直挂着)"
cat > "$W/conns.fixture" <<'J'
{"downloadTotal":10,"uploadTotal":10,"connections":[
 {"id":"aaaaaaaa-0000-0000-0000-000000000001","metadata":{"host":"a.example"},"chains":["Auto-Dead","AUTO","Global","Final"],"rule":"final"},
 {"id":"aaaaaaaa-0000-0000-0000-000000000002","metadata":{"host":"b.example"},"chains":["Auto-Live","AUTO","Global","Final"],"rule":"final"},
 {"id":"aaaaaaaa-0000-0000-0000-000000000003","metadata":{"host":"c.example"},"chains":["Auto-Dead","Global","Final"],"rule":"final"},
 {"id":"aaaaaaaa-0000-0000-0000-000000000004","metadata":{"host":"d.example"},"chains":["Auto-Dead","AUTO","svc-chatgpt"],"rule":"rule_set=geosite-openai"},
 {"id":"../version","chains":["Auto-Dead","AUTO"]},
 {"id":"aaaaaaaa-0000-0000-0000-000000000006","chains":"Auto-Dead AUTO"}],"memory":1}
J
nclosed() { cat "$W/closed" 2>/dev/null | grep -c .; }
nconns() { cat "$W/conns.calls" 2>/dev/null | grep -c .; }
dead() { r10; setauto; printf 'Auto-Dead' > "$W/now.AUTO"; printf 'Auto-Live' > "$W/next.AUTO"; cp "$W/conns.fixture" "$W/conns.json"; }    # 选中的 Auto-Dead 不通, 核心会改选 Auto-Live
dead; health_tick
eq "组测速结果里没有旧节点 (它的测速失败了): 只断开经 AUTO 用着它的连接 —— 直接选了它的 Global、id 不合规的、格式不对的都不碰" "$(paste -sd, - < "$W/closed")" "DELETE aaaaaaaa-0000-0000-0000-000000000001,DELETE aaaaaaaa-0000-0000-0000-000000000004"
has "…换节点的记录带 closed=2" "	auto	环境状态变化	item=auto_select from=Auto-Dead to=Auto-Live group=AUTO probe=refused took_s=[0-9][0-9]* closed=2	ok$" "$(ops)"
eq "…组测速已经说明旧节点不通: 不再单独测它" "$(pcalls)" "0"
dead; printf '{"Auto-Dead":300,"Auto-Live":120}' > "$W/delay.body"; health_tick
eq "换了节点, 但组测速里旧节点自己是通的 (只是本机直连它的端口不通 / 别的更快): 不读也不断开连接" "$(nconns)/$(nclosed)/$(pcalls)" "0/0/0"
has "…换节点照常记 (没有 closed)" "item=auto_select from=Auto-Dead to=Auto-Live group=AUTO probe=refused took_s=[0-9][0-9]*	ok$" "$(ops)"
dead; printf '{}' > "$W/delay.body"; printf 504 > "$W/pd.Auto-Dead"; health_tick
eq "组测速没给出结论 (核心正在自己测速) 但选择变了: 单独请核心测一次旧节点, 超时 → 断开" "$(cut -d' ' -f1 "$W/pdelay.calls")/$(nclosed)" "Auto-Dead/2"
dead; printf '{}' > "$W/delay.body"; health_tick
eq "…单独测旧节点是通的: 不断开" "$(pcalls)/$(nclosed)" "1/0"
r10; setudp; printf 'Auto-Live' > "$W/next.AUTO"; printf 504 > "$W/pd.Auto-H2"; printf '{}' > "$W/delay.body"
printf '{"connections":[{"id":"bbbbbbbb-0000-0000-0000-000000000001","chains":["Auto-H2","AUTO","Global","Final"]}]}' > "$W/conns.json"
health_tick
eq "走 UDP 的旧节点: 这一分钟核心已经测过它 (超时), 组测速没结论时不测第二次, 直接断开" "$(pcalls)/$(cat "$W/closed")" "1/DELETE bbbbbbbb-0000-0000-0000-000000000001"
r10; { srvl pin socks Pin-Dead "$CLOSED"; srvl pin socks Pin-Live "$OPEN"; } > "$H/servers.jsonl"; printf 'Pin-Dead' > "$W/now.PINAUTO"; printf 'Pin-Live' > "$W/next.PINAUTO"
printf '{"connections":[{"id":"dddddddd-0000-0000-0000-000000000001","chains":["Pin-Dead","PINAUTO","svc-chatgpt"]},{"id":"dddddddd-0000-0000-0000-000000000002","chains":["Pin-Dead","PIN","svc-claude"]}]}' > "$W/conns.json"
health_tick
eq "PINAUTO 换了节点: 只断开经 PINAUTO 的连接; 经 PIN (固定出口本身, 永远不动) 用着它的不碰" "$(cat "$W/closed")" "DELETE dddddddd-0000-0000-0000-000000000001"
dead; rm -f "$W/next.AUTO"; printf '{"Auto-Dead":90,"Auto-Live":160}' > "$W/delay.body"; health_tick
eq "核心仍然选它 (没换节点): 不碰任何连接" "$(nconns)/$(nclosed)" "0/0"
dead; printf 7 > "$W/del.rc"; health_tick
eq "断开时接口出错: 立刻停下 (不会对着没响应的接口一条条等超时), 记录里没有 closed" "$(nclosed)/$(ops | grep -c 'closed=')" "1/0"
has "…换节点本身照常记" "item=auto_select from=Auto-Dead to=Auto-Live group=AUTO probe=refused" "$(ops)"
dead; HEALTH_CLOSE_MAX=1; health_tick; HEALTH_CLOSE_MAX=200
eq "一次最多断开 HEALTH_CLOSE_MAX 条 (这里设成 1)" "$(nclosed)/$(ops | grep -c 'closed=1	ok$')" "1/1"
rm -f "$W"/now.* "$W"/next.* "$W/delay.calls" "$W/delay.body" "$W"/pd.* "$W/pdelay.calls" "$W/conns.json" "$W/conns.calls" "$W/closed" "$W/del.rc"


echo "== H14. 自动判定 (2.3.27): 断网的分钟 (state network outage) → local-network-down, 不冤枉服务器 · state network 行不影响「自什么时候起」· TUN 下核心测速的行可信"
python3 - "$SP" "$NOW" <<'PY'
import sys, datetime as dt
sp, now = sys.argv[1], int(sys.argv[2])
def t(m): return dt.datetime.fromtimestamp(now - m * 60).strftime('%Y-%m-%d %H:%M:%S')
def L(m, kind, target, result, ms, det=''): return f"{t(m)}\t{kind}\t{target}\t{result}\t{ms}\t{det}\n"
def write(name, rows): open(f'{sp}/{name}', 'w').write(''.join(rows))
def build(out, cn_down=True):      # out = 断网的分钟: 这些分钟只有一行 state network outage (2.3.27 起不再有各个节点的失败行)
    rows = []
    for m in range(60, 0, -1):
        if m in out: rows.append(L(m, 'state', 'network', 'outage', 0, 'probed=2 failed=2 mode=system nodes=Tokyo-Fix,Auto-1'))
        else: rows += [L(m, 'node', 'Tokyo-Fix', 'ok', 40, 'role=pin mode=system'), L(m, 'node', 'Auto-1', 'ok', 40, 'role=auto mode=system')]
        if m % 5 == 0:
            bad = m in out
            rows += [L(m, 'canary', 'google_204', 'timeout' if bad else 'ok', 200), L(m, 'canary', 'cn_direct', 'timeout' if bad and cn_down else 'ok', 60)]
    return rows
write('O1', build(set(range(1, 21))))                    # 最近 20 分钟断网, 对照站点也不通
write('O1b', build(set(range(1, 21)), cn_down=False))    # 同上, 但对照站点是通的 (服务器全部同时连不上)
write('O2', build({7, 8}))                               # 30 分钟里只断了 2 分钟 (一闪而过)
a = []                                                   # O3: 系统代理 120 分钟前被关 (同 H5 的 A), 最后两分钟又断网
for m in range(180, 0, -1):
    a.append(L(m, 'node', 'Tokyo-Fix', 'ok', 40, 'role=pin'))
    if m % 5 == 0:
        for n in ('google_204', 'chatgpt_web', 'openai_api', 'cn_direct'): a.append(L(m, 'canary', n, 'ok', 200))
a += [L(180, 'state', 'capture', 'ok', 0, 'core=1 proxy=1 sysproxy=1'), L(120, 'state', 'capture', 'ok', 0, 'core=1 proxy=1 sysproxy=0'), L(3, 'state', 'capture', 'ok', 0, 'core=1 proxy=1 sysproxy=0')]
write('O3a', a)
write('O3', a + [L(2, 'state', 'network', 'outage', 0, 'probed=1 failed=1 cn_direct=timeout mode=system nodes=Tokyo-Fix'), L(1, 'state', 'network', 'outage', 0, 'probed=1 failed=1 mode=system nodes=Tokyo-Fix')])
o4 = []                                                  # O4: TUN, 节点行是绑定网卡的 TCP 探测 (probe=bound) 和核心测速 (probe=core)
for m in range(120, 0, -1):
    o4 += [L(m, 'node', 'Tokyo-Pin', 'ok', 4, 'role=pin mode=tun probe=bound'), L(m, 'node', 'Auto-H2', 'ok', 120, 'role=auto mode=tun probe=core')]
    if m % 5 == 0: o4 += [L(m, 'canary', 'google_204', 'ok', 200), L(m, 'canary', 'cn_direct', 'ok', 60)]
write('O4', o4)
PY
ROLES14="Tokyo-Fix:pin,Auto-1:auto"
V=$(V2 O1 /dev/null /dev/null "$SP/meta" "$SP/env.old" "$ROLES14")
has "O1 最近 20 分钟只有断网行 (没有节点的失败行): cause=local-network-down" "^verdict.cause=local-network-down$" "$V"
has "O1: blame=network" "^verdict.blame=network$" "$V"
has "O1: 证据是断网的分钟数 / 最近 30 分钟里有数据的分钟数" "^verdict.evidence.1=network_outage_minutes_30m=20/30$" "$V"
hasnt "O1: 不冤枉服务器 (没有 node-down)" "node-down" "$V"
hasnt "O1: …也没有 node-unstable" "node-unstable" "$V"
has "O1: 故障时段里有这 20 分钟的断网 (state/network, 仍在继续)" "^verdict.outage.*20min state/network outage ONGOING$" "$V"
V=$(V2 O1b /dev/null /dev/null "$SP/meta" "$SP/env.old" "$ROLES14")
has "O1b 对照站点是通的、但每分钟服务器全部连不上: 同样判 local-network-down" "^verdict.cause=local-network-down$" "$V"
hasnt "O1b: 不报 proxy-path-failing (断网时端口本来就连不上, 不是「端口通、代理不通」)" "proxy-path-failing" "$V"
V=$(V2 O2 /dev/null /dev/null "$SP/meta" "$SP/env.old" "$ROLES14")
hasnt "O2 30 分钟里只断了 2 分钟: 不算本机网络故障" "local-network-down" "$V"
has "O2: 结论是没发现明确故障" "^verdict.cause=no-issue-found$" "$V"
V=$(perl "$LIB/health.pl" outages < "$SP/O1")
has "outages: 断网时段单独一行 (state network, 20 分钟, 20 个样本)" "	20	state	network	outage	20$" "$V"
V=$(perl "$LIB/health.pl" summary 10 < "$SP/O1")
hasnt "summary: 断网行不是样本, 不进分桶统计" "	state	" "$V"
eq "O3 最后两分钟断网 (state network 行) 不挡住「系统代理自什么时候起没开」" "$(V2 O3 /dev/null /dev/null "$SP/meta" "$SP/env.off" "Tokyo-Fix:pin" | grep '^verdict.since=')" "$(V2 O3a /dev/null /dev/null "$SP/meta" "$SP/env.off" "Tokyo-Fix:pin" | grep '^verdict.since=')"
has "O3: …而且确实算出了时刻" "^verdict.since=" "$(V2 O3 /dev/null /dev/null "$SP/meta" "$SP/env.off" "Tokyo-Fix:pin")"
V=$(V2 O4 /dev/null /dev/null "$SP/meta.tunok" "$SP/env.tunok" "Tokyo-Pin:pin,Auto-H2:auto")
hasnt "O4 TUN 下核心测速的行 (probe=core) 不经过 TUN: 不算「TUN 下的旧探测不可信」" "node_probe_tun" "$V"
has "O4: 核心测速的节点照常有可达率" "^verdict.node.Auto-H2=role=auto reachable=100.0%" "$V"

P=$(grep -c . "$W/.pass"); F=$(grep -c . "$W/.fail")
echo; echo "健康记录测试: $P 通过, $F 失败"
[ "$F" = 0 ]
