#!/bin/bash
# 诊断摘要 (lib/diag.pl + lib/diag.sh): 几秒钟, 不需要网络 / sing-box / 管理员权限, macOS 和 Linux 都能跑。
#   · 脱敏: 假导出里塞满敏感内容 (域名 / 应用名 / IP / 节点标签 / 订阅名 / 邮箱 / 用户名 / 令牌), 一个都不能出现在摘要里
#   · 有用的诊断信息还在: 原因代码 / 数字证据 / 节点别名 / 固定出口数量 / 调用链 / 会话事实
#   · 大小上限: 超过上限时丢最旧的记录, 仍是合法 JSON, 最新的记录保留
#   · 上传流程 (lib/diag.sh): 开关 / 没登录不传 · 限频 · 登录触发不受限频 · 结果写进操作记录 · 事件触发 · 完整诊断的打包和重试
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P); REPO=$(dirname "$HERE")
W=$(mktemp -d /tmp/enana-diag.XXXXXX); W=$(cd "$W" && pwd -P)
trap 'rm -rf "$W"' EXIT; : > "$W/.pass"; : > "$W/.fail"
tpass() { echo p >> "$W/.pass"; echo "  ✓ $1"; }
tfail() { echo f >> "$W/.fail"; echo "  ✗ $1"; [ -n "${2:-}" ] && printf '      ↳ %s\n' "$(printf '%s' "$2" | head -c 700)"; return 0; }
eq()    { if [ "$2" = "$3" ]; then tpass "$1"; else tfail "$1" "期望 [$3] 实际 [$2]"; fi; }
hs()    { if printf '%s\n' "$3" | grep -Eq -- "$2"; then tpass "$1"; else tfail "$1" "没有找到 /$2/ 于: $3"; fi; }
hsnt()  { if ! printf '%s\n' "$3" | grep -Eq -- "$2"; then tpass "$1"; else tfail "$1" "不应出现 /$2/: $3"; fi; }
command -v perl >/dev/null && command -v python3 >/dev/null || { echo "跳过: 需要 perl / python3"; exit 77; }

echo "== D1. 脱敏: 敏感内容一个都不能出现在摘要里"
OUT=$(perl "$REPO/lib/diag.pl" summary < "$REPO/tests/fixtures/diag-bundle.txt")
printf '%s\n' "$OUT" > "$W/summary.json"
eq "输出是合法 JSON, v=1" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["v"])' "$W/summary.json" 2>&1)" "1"
for s in 'DeletedNode' 'secret-site.example' 'SecretApp' 'SecretNode-HK' '203.0.113' '198.51.100' '1.2.\*' 'sub.secret-provider' 'secret-sub' 'SHOULD_NOT_APPEAR' '192.168.10.1' '10.20.30.40' 'e\*\*\*@g' 'fe80' 'process_path' '/Applications' 'helperlog' 'bypass-system-proxy'; do
  hsnt "摘要里没有 $s" "$s" "$OUT"
done
hsnt "摘要里没有 access / proxy 分区的内容" '"access"|"proxy"' "$OUT"

echo "== D2. 有用的诊断信息还在"
js() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$W/summary.json" "$1" 2>&1; }
eq "原因代码 verdict.cause=pin-empty, 归因 client, 置信 high" "$(js 'd["verdict"]["cause"]+"/"+d["verdict"]["blame"]+"/"+d["verdict"]["confidence"]')" "pin-empty/client/high"
eq "meta: 版本 / 核心 / 系统 / 接管方式都在" "$(js 'd["meta"]["version"]+"/"+d["meta"]["core"]+"/"+d["meta"]["os"]+"/"+d["meta"]["capture.mode"]')" "2.3.9/1.14.2/macOS 27.0.1/tun"
hsnt "meta: 白名单之外的键被丢弃" "secret.token" "$OUT"
eq "固定出口数量: pin.servers=0 / 应用策略 1 / 选择器 7" "$(js 'd["env"]["pin.servers"]+"/"+d["env"]["pin.app_policies"]+"/"+d["env"]["pin.selectors_on_pin"]')" "0/1/7"
hsnt "…但不含应用名 / 组成员 (pin.*_names / group_members)" "pin\.app_policy_names|group_members" "$OUT"
eq "系统 DNS 只留类别 (private), 不留地址" "$(js 'd["env"]["dns.system_kind"]')" "private"
eq "sysproxy 指向别人的代理只留 other, 不留地址" "$(js 'd["env"]["sysproxy.SOCKSProxy"]')" "other"
eq "config.check 只留 error, 不留报错原文 (原文里有节点名)" "$(js 'd["env"]["config.check"]')" "error"
eq "会话事实在 (尾号 / 设备尾号)" "$(js 'd["env"]["session.id_tail"]+"/"+d["env"]["session.device_tail"]')" "9999/abcd1234"
eq "节点换成了别名 (按标签排序分配: Plain=node1 SecretNode-HK=node2 my-vps…=node3)" "$(js '",".join(sorted(k for k in d["verdict"] if k.startswith("node.")))')" "node.node2,node.node3"
eq "别名对应的可达率还在 (坏节点 node2: 27.3%)" "$(js 'd["verdict"]["node.node2"][:32]')" "role=auto reachable=27.3% (3/11)"
eq "also: 只留原因代码 (chatgpt-direct (client)), 不留带名字的说明" "$(js 'd["verdict"]["also.1"]')" "chatgpt-direct (client)"
eq "chatgpt: 只留数字和原因计数" "$(js 'd["verdict"]["chatgpt"]')" "conns=593 direct=593 proxy=0 errors=587 reasons=[policy×335,mode×258] error_types=[timeout×565,other×14]"
eq "outage: 节点名换成别名" "$(js 'd["verdict"]["outage.1"]')" "2026-10-05 03:05:29 ~ 2026-10-05 03:12:38 8min node/node2 refused ONGOING"
eq "last_proxy_off: 时间 / 来源 / 动作 / 调用链都在, sub= user= 被丢弃" "$(js 'd["verdict"]["last_proxy_off"]')" "2026-10-05 03:03:27 auto 总开关变更 key=PROXY_ENABLED from=1 to=0 via=_proxy_set<auth_logout_local"
eq "verdict.pin / verdict.session 汇总在" "$(js 'd["verdict"]["pin"]')" "servers=0 app_policies=1 selectors_on_pin=7 policy_direct_30m=9"
eq "health: 节点目标换成别名, canary 保留名字" "$(js '",".join(sorted(set(r["target"] for r in d["health"])))')" "cn_direct,node2,node3"
eq "outages: 节点目标换成别名" "$(js 'd["outages"][0]["target"]')" "node2"

echo "== D3. ops: 动作名 + 白名单详情键, 其余全部丢弃"
eq "ops 条数: 11 条都在 (添加网站 example.com 这条只留动作头部「添加网站」)" "$(js 'len(d["ops"])')" "11"
eq "添加网站: 域名拼在动作名后面也不会漏出去, host= 详情也被丢弃" "$(js '[o["action"]+"|"+o["detail"] for o in d["ops"] if o["action"].startswith("添加")][0]')" "添加网站|"
eq "总开关变更: 调用链和 pid 在" "$(js '[o["detail"] for o in d["ops"] if o["action"]=="总开关变更"][0]')" "key=PROXY_ENABLED from=1 to=0 via=_proxy_set<auth_logout_local<session_local_end pid=4242"
eq "已被退出登录: 原因 / 状态码 / 距上次成功多久 / 会话尾号 / 调用链 / 响应码都在" "$(js '[o["detail"] for o in d["ops"] if o["action"]=="已被退出登录"][0]')" "reason=kicked http=401 proxy_was=1 since_ok_s=130 session=9999 via=session_heartbeat resp_code=unauthorized"
eq "导入服务器: sub= 被丢弃, mode 保留" "$(js '[o["detail"] for o in d["ops"] if o["action"]=="导入服务器"][0]')" "mode=replace"
eq "登录: user= 被丢弃, via=online 保留" "$(js '[o["detail"] for o in d["ops"] if o["action"]=="登录"][0]')" "via=online"
eq "订阅「名字」刷新: 动作只留「订阅」, 名字和 tag= 都不在" "$(js '[o["action"]+"|"+o["detail"] for o in d["ops"] if o["action"].startswith("订阅")][0]')" "订阅|count=38"
eq "开启系统代理: 授权方式 / 助手情况在" "$(js '[o["detail"] for o in d["ops"] if o["action"]=="开启系统代理"][0]')" "method=direct helper=used port=7890 mode=system"
eq "切换策略: 到一台已经不在服务器列表里的节点 (DeletedNode-SG): from 保留, to 整个丢弃, 名字不会漏出去" "$(js '[o["detail"] for o in d["ops"] if o["action"]=="切换策略"][0]')" "from=AUTO"
eq "切换策略: 到当前存在的节点: 换成别名 (node2), 不是真名" "$(js '[o["detail"] for o in d["ops"] if o["action"]=="切换策略"][1]')" "from=AUTO to=node2"
eq "修改应用/网站策略: 策略值 from/to 保留, name= target_to= 丢弃" "$(js '[o["detail"] for o in d["ops"] if o["action"]=="修改应用/网站策略"][0]')" "from=follow to=pin src=user"
eq "固定出口为空事件的数量在" "$(js '[o["detail"] for o in d["ops"] if o["action"]=="环境状态变化"][0]')" "item=pin from=ok to=empty pin_servers=0 dependents=7"

echo "== D4. 大小上限: 超过就丢最旧的, 仍是合法 JSON"
python3 - "$REPO/tests/fixtures/diag-bundle.txt" "$W/big.txt" <<'PY'
import sys
src=open(sys.argv[1],encoding='utf-8').read()
head,_,rest=src.partition('@@SECTION ops')
ops=['@@SECTION ops format=tsv rows=3000\n','ts\twho\taction\tdetail\tresult\n']
for i in range(3000):
    ops.append(f'2026-10-05 03:{i//60%60:02d}:{i%60:02d}\tauto\t环境状态变化\titem=net_if from=en{i%7} to=en{(i+1)%7} pid={i} via=' + 'f<'*30 + 'g\tok\n')
ops.append('@@END\n')
open(sys.argv[2],'w',encoding='utf-8').write(head+''.join(ops))
PY
BIG=$(perl "$REPO/lib/diag.pl" summary < "$W/big.txt"); printf '%s\n' "$BIG" > "$W/big.json"
eq "3000 条 ops: 输出不超过服务端上限 (98304 字符)" "$([ "$(python3 -c 'import sys; print(len(open(sys.argv[1],encoding="utf-8").read()))' "$W/big.json")" -le 98304 ] && echo ok || echo too-big)" "ok"
eq "仍是合法 JSON, 保留了最新的记录 (pid=2999)" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(any("pid=2999" in o["detail"] for o in d["ops"]))' "$W/big.json")" "True"
eq "丢的是最旧的 (pid=0 不在了)" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(any(o["detail"].split()[-2]=="pid=0" for o in d["ops"]))' "$W/big.json")" "False"

echo "== D5. 流程 (lib/diag.sh): 开关 · 登录 · 限频 · 结果记进操作记录 · 事件触发"
export HOME=$W/home ENANA_HOME=$W/h LC_ALL=C ENANA_LANG=zh ENANA_PLATFORM=darwin PORT=37990 UI_PORT=37991 API_PORT=37992 SPEED_PORT=37993 ENANA_SKIP_PROBE=1
mkdir -p "$HOME" "$ENANA_HOME"
. "$REPO/lib/common.sh"; init_paths "$REPO/install.sh"; LIB=$REPO/lib; DATA=$REPO/data
for _f in i18n jobs servers apps autosites sites fetch os-darwin enhanced auth device session cloud dns logs health update config ops speed stats prefs snapshot plan sync vps diag; do . "$LIB/$_f.sh"; done
load_settings; QUIET=1; mkdir -p "$H" "$LOGS"
[ "$H" = "$W/h" ] || { echo "REFUSING: 数据目录不是临时目录 ($H)"; exit 1; }
CALLS=$W/calls.log
auth_logged_in() { [ "${STUB_LOGIN:-1}" = 1 ]; }
printf 'sid-9999\n' > "$H/session"; printf 'tok\n' > "$H/cloud.token"
logs_bundle() { cat "$REPO/tests/fixtures/diag-bundle.txt"; }      # 真实导出要跑探测 / 读核心, 这里只测上传流程
session_call() { # <out> <method> <path> [body]  -> 假云端: 记录调用, 返回 $FAKE_CODE
  printf '%s %s bytes=%s\n' "$2" "$3" "${#4}" >> "$CALLS"; printf '%s' "$4" > "$W/last-body.json"
  case ${FAKE_CODE:-200} in 200) printf '{"ok":true,"id":"rep123abc456xyz"}' > "$1" ;; *) printf '{"code":"x"}' > "$1" ;; esac
  printf '%s' "${FAKE_CODE:-200}"
}
reset() { : > "$CALLS"; rm -f "$H/.diag.last" "$H/.diag.pos" "$H"/logs/ops-*.log; DIAG_UPLOAD=1; STUB_LOGIN=1; unset FAKE_CODE ENANA_NO_DIAG; }
ops() { cat "$LOGS"/ops-*.log 2>/dev/null; }

reset
diag_upload login; rc=$?
eq "登录触发: 上传了一次, 目标是 /api/enana/v1/diag" "$rc:$(grep -c '^POST /api/enana/v1/diag bytes=' "$CALLS")" "0:1"
eq "请求体是 {trigger, payload}, payload 已经脱敏" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["trigger"]+"/"+str(d["payload"]["v"])+"/"+d["payload"]["verdict"]["cause"])' "$W/last-body.json")" "login/1/pin-empty"
hsnt "…请求体里没有敏感内容" "secret-site|SecretApp|SecretNode|203[.]0[.]113" "$(cat "$W/last-body.json")"
hs "结果写进操作记录 (用户能看到传了什么时候传的): 诊断上传 trigger=login http=200 bytes=…" "auto	诊断上传	trigger=login http=200 bytes=[0-9]+	ok" "$(ops)"
reset; diag_upload login; diag_upload event:sysproxy
eq "事件触发: 本机限频 (10 分钟内只传一次), 第二次不上传" "$(grep -c '^POST' "$CALLS")" "1"
reset; diag_upload event:sysproxy; diag_upload login
eq "登录触发不受本机限频" "$(grep -c '^POST' "$CALLS")" "2"
reset; DIAG_UPLOAD=0; diag_upload login
eq "设置里关掉上传: 不传" "$(grep -c '^POST' "$CALLS")" "0"
reset; STUB_LOGIN=0; diag_upload login
eq "没登录: 不传" "$(grep -c '^POST' "$CALLS")" "0"
reset; ENANA_NO_DIAG=1 diag_upload login
eq "ENANA_NO_DIAG=1: 不传 (测试 / 受限环境)" "$(grep -c '^POST' "$CALLS")" "0"
reset; FAKE_CODE=429 diag_upload login
hs "云端限频 (429): 记成 error 并带 http=429" "诊断上传	trigger=login http=429 .*	error" "$(ops)"
reset; FAKE_CODE=000 diag_upload login
hs "连不上云端: 记成 error, 不报错退出" "诊断上传	trigger=login http=000 .*	error" "$(ops)"

echo "-- D5b. 事件触发 (diag_tick): 只看新增的操作记录, 只对「值得上报」的事件触发"
reset
O=$LOGS/ops-$(date +%F).log
printf '%s\tdashboard\t开启代理\tenabled=1 mode=auto\tok\n' "$(date '+%F %T')" > "$O"
diag_tick
eq "只有用户自己的操作 (开启代理): 不触发" "$(grep -c '^POST' "$CALLS")" "0"
printf '%s\tauto\t总开关变更\tkey=PROXY_ENABLED from=1 to=0 via=_proxy_set<auth_logout_local pid=1\tok\n' "$(date '+%F %T')" >> "$O"
diag_tick
eq "总开关被自动关闭 (来源 auto, to=0): 触发一次上传" "$(grep -c '^POST' "$CALLS")" "1"
hs "触发原因记成 event:switch_off" "诊断上传	trigger=event:switch_off http=200" "$(ops)"
diag_tick
eq "同一条事件不会重复触发 (位置已推进)" "$(grep -c '^POST' "$CALLS")" "1"
reset; O=$LOGS/ops-$(date +%F).log
printf '%s\tdashboard\t总开关变更\tkey=PROXY_ENABLED from=1 to=0 via=_proxy_set<ep_proxy pid=1\tok\n' "$(date '+%F %T')" > "$O"; diag_tick
eq "用户在仪表盘里自己关的 (来源 dashboard): 不触发" "$(grep -c '^POST' "$CALLS")" "0"
reset; O=$LOGS/ops-$(date +%F).log
printf '%s\tauto\t环境状态变化\titem=pin from=ok to=empty pin_servers=0 dependents=7\tok\n' "$(date '+%F %T')" > "$O"; diag_tick
hs "固定出口变空: 触发 event:pin" "诊断上传	trigger=event:pin " "$(ops)"
reset; O=$LOGS/ops-$(date +%F).log
printf '%s\tauto\t环境状态变化\titem=sysproxy from=1 to=0 capture=system\tok\n' "$(date '+%F %T')" > "$O"; diag_tick
hs "系统代理被关: 触发 event:sysproxy" "诊断上传	trigger=event:sysproxy " "$(ops)"
reset; O=$LOGS/ops-$(date +%F).log
printf '%s\tauto\t环境状态变化\titem=net_if from=en0 to=en1\tok\n' "$(date '+%F %T')" > "$O"; diag_tick
eq "换网络接口这类普通变化: 不触发" "$(grep -c '^POST' "$CALLS")" "0"

P=$(wc -l < "$W/.pass" | tr -d ' '); F=$(wc -l < "$W/.fail" | tr -d ' ')
echo; echo "diag.sh: $P passed, $F failed"; [ "$F" = 0 ]
