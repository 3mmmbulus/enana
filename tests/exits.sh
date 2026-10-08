#!/bin/bash
# 出口分配 (lib/exits.sh · lib/api.sh 的 /api/exits* 与服务器删除 / 改角色 / 删订阅的保护 · lib/health.sh 的孤儿事件 · 固定出口上限): 几秒钟, 不需要 sing-box / 管理员权限 / 真实的 launchd。
#   · 归属表: 跟随默认 / 指定 / 自动选 / 孤儿 (已删除 | 不再是固定出口 | 超出上限), 服务 (核心里的 svc-* 选择器) 一并读
#   · 默认固定出口: 核心里正在用的 > 持久化的 ($H/pin-default) > 第一个; 老安装第一次读到时记下来; 核心重启后校正; 第一个固定出口的顺序变了也不影响
#   · 批量移动 / 钉住 (freeze): 一次事务改写 overrides.tsv, 规则集热加载, 服务切换选择器; 不合法的去向被拒
#   · 删除 / 改角色 / 删订阅的保护: 有人在用 → 必须带 reassign / accept_orphans, 否则结构化错误 (E_EXIT_IN_USE + impact), 什么也不改; 带了 → 改派 + 默认出口跟着换
#   · TUN 模式: 移动走后台任务 (经 op_txn → apply_config), 失败时服务选择器切回去
#   · 健康记录: 孤儿数量变化写一条「环境状态变化 item=exit_orphans」
# 核心的 Clash API 用 tests/fake-core.py 模拟 (只实现 /proxies 与选择器切换); apply_config 换成只重新生成规则集的假函数 (不启动 sing-box)。
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P); REPO=$(dirname "$HERE")
command -v python3 >/dev/null && command -v perl >/dev/null || { echo "跳过: 需要 python3 / perl"; exit 77; }
W=$(mktemp -d /tmp/enana-exits.XXXXXX); W=$(cd "$W" && pwd -P); CORE_PID=''
cleanup() { [ -z "$CORE_PID" ] || kill "$CORE_PID" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT; : > "$W/.pass"; : > "$W/.fail"
tpass() { echo p >> "$W/.pass"; echo "  ✓ $1"; }
tfail() { echo f >> "$W/.fail"; echo "  ✗ $1"; [ -n "${2:-}" ] && printf '      ↳ %s\n' "$(printf '%s' "$2" | head -c 900)"; return 0; }
eq()    { if [ "$2" = "$3" ]; then tpass "$1"; else tfail "$1" "期望 [$3] 实际 [$2]"; fi; }
has()   { if printf '%s\n' "$3" | grep -Eq -- "$2"; then tpass "$1"; else tfail "$1" "没有找到 /$2/ 于: $3"; fi; }
hasnt() { if printf '%s\n' "$3" | grep -Eq -- "$2"; then tfail "$1" "不该出现 /$2/ 于: $3"; else tpass "$1"; fi; }
py()    { python3 -c 'import sys,json; d=json.load(sys.stdin); '"$1"; }
chk()   { local d=$1 code=$2 in; in=$(cat); if out=$(printf '%s' "$in" | py "$code" 2>&1); then tpass "$d"; else tfail "$d" "$out | $in"; fi; }

BASE=$((30000 + RANDOM % 20000))
export HOME=$W/home ENANA_HOME=$W/h LC_ALL=C ENANA_LANG=zh ENANA_NO_MDFIND=1 ENANA_SKIP_PROBE=1 ENANA_NO_DIAG=1 ENANA_PLATFORM=darwin
export PORT=$BASE UI_PORT=$((BASE + 1)) API_PORT=$((BASE + 2)) SPEED_PORT=$((BASE + 3))
mkdir -p "$HOME" "$W/h/rules" "$W/h/logs"
. "$REPO/lib/common.sh"; init_paths "$REPO/install.sh"; LIB=$REPO/lib; DATA=$REPO/data
for _f in i18n jobs servers apps autosites sites fetch os-darwin enhanced auth device session cloud dns logs health update config ops exits; do . "$LIB/$_f.sh"; done
load_settings; QUIET=1
[ "$H" = "$W/h" ] || { echo "REFUSING: 数据目录不是临时目录 ($H)"; exit 1; }
printf 'test-token\n' > "$H/secret"; : > "$H/.apps.now"
OPSLOG() { cat "$LOGS"/ops-*.log 2>/dev/null; }

# ---------- 夹具 ----------
pin()  { printf '{"role":"%s","outbound":{"type":"socks","tag":"%s","server":"127.0.0.1","server_port":1}}\n' "${2:-pin}" "$1" >> "$H/servers.jsonl"; }        # pin <名称> [角色]
pins() { : > "$H/servers.jsonl"; local t; for t in "$@"; do pin "$t"; done; }
subpin() { printf '{"role":"pin","sub":"%s","outbound":{"type":"socks","tag":"%s","server":"127.0.0.1","server_port":1}}\n' "$2" "$1" >> "$H/servers.jsonl"; }
ovr()  { printf '%s\n' "$@" > "$H/overrides.tsv"; }
tag_of() { awk -F'|' -v k="$1" -v v="$2" '$1==k && $2==v {print $5}' "$H/overrides.tsv"; }
rs()   { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d["rules"], ensure_ascii=False, sort_keys=True))' "$H/rules/ovr-$1.json"; }
mkcore() { # mkcore <PIN 当前选择> [服务=当前选择 …]   固定出口取自 servers.jsonl 里 role=pin 的; 服务选择器的选项和真实配置一样 (固定出口 ≥ 2 个才有 PINAUTO 和各固定出口)
  python3 - "$W/core.json" "$H/servers.jsonl" "$@" <<'PY'
import json, sys
st, srv, now, *svcs = sys.argv[1:]
pins = []
for l in open(srv):
    try: d = json.loads(l)
    except ValueError: continue
    if d.get('role') == 'pin': pins.append(d['outbound']['tag'])
sel = {'PIN': {'now': now if now in pins else (pins[0] if pins else 'direct'), 'all': pins or ['direct']}}
opts = ['PIN', 'Global', 'direct'] + (['PINAUTO'] + pins if len(pins) >= 2 else [])
for s in svcs:
    tag, n = s.split('=', 1)
    sel[tag] = {'now': n, 'all': opts}
json.dump({'selectors': sel}, open(st, 'w'))
PY
}
cnow() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["selectors"][sys.argv[2]]["now"])' "$W/core.json" "$1"; }      # 核心里某个选择器当前的选择
cset() { python3 - "$W/core.json" "$1" "$2" <<'PY'
import json, sys
f, tag, n = sys.argv[1:]; s = json.load(open(f)); s['selectors'][tag]['now'] = n; json.dump(s, open(f, 'w'))
PY
}
python3 "$HERE/fake-core.py" "$UI_PORT" "$W/core.json" & CORE_PID=$!
pins Pin-A; mkcore Pin-A
for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do curl -s --noproxy '*' -o /dev/null "http://127.0.0.1:$UI_PORT/proxies" && break; sleep 0.25; done
curl -s --noproxy '*' "http://127.0.0.1:$UI_PORT/proxies" | grep -q '"PIN"' || { echo "假核心没有启动"; exit 1; }
# 不启动 sing-box: apply_config 只重新生成规则集 (真实的 apply_config 先做这一步); 需要观察「是否重启」时由用例自己设 APPLY_CHANGED
APPLIES=0; apply_config() { APPLIES=$((APPLIES + 1)); ovr_sync; APPLY_CHANGED=0; return 0; }

echo "== E1. 归属表: 跟随默认 / 指定 / 自动选 / 孤儿 (已删除 · 不再是固定出口 · 超出上限) · 服务也算"
pins Pin-A Pin-B Pin-C; pin Auto-1 auto
ovr 'app|ChatGPT|pin|def|' 'app|Cursor|pin|ack|Pin-B' 'site|a.io|pin|ack|Pin-A' 'site|b.io|pin|ack|PINAUTO' 'site|gone.io|pin|ack|Pin-Z' 'site|role.io|pin|ack|Auto-1' 'site|d.io|direct|ack|' 'site|f.io|auto|ack|' 'app|Safari|follow|ack|'
mkcore Pin-B svc-chatgpt=PIN svc-claude=Pin-C svc-gemini=PINAUTO svc-other=Global svc-tools=direct
items=$(exits_items)
eq "应用 / 网站: 只有状态是 pin 的才有归属 (直连 / 自动线路 / 跟随规则的不算)" "$(printf '%s\n' "$items" | cut -f1,2,3,4,5 | paste -sd';' -)" "app	ChatGPT	follow		;app	Cursor	bound	Pin-B	;site	a.io	bound	Pin-A	;site	b.io	auto	PINAUTO	;site	gone.io	orphan	Pin-Z	deleted;site	role.io	orphan	Auto-1	role"
svc=$(mktemp); exits_services_scan > "$svc"
eq "服务: 核心里 svc-* 选择器当前的选择 (只有 svc- 开头的)" "$(paste -sd';' - < "$svc")" "svc-chatgpt	PIN;svc-claude	Pin-C;svc-gemini	PINAUTO;svc-other	Global;svc-tools	direct"
items=$(exits_items "$svc"); rm -f "$svc"
eq "服务的归属: PIN = 跟随默认; 某个固定出口 = 指定; PINAUTO = 自动选; Global / direct 不在这里" "$(printf '%s\n' "$items" | awk -F'\t' '$1=="svc" {printf "%s=%s/%s;", $2, $3, $4}')" "svc-chatgpt=follow/;svc-claude=bound/Pin-C;svc-gemini=auto/PINAUTO;"
eq "孤儿计数 / 名单 (健康记录和终端用)" "$(exits_orphan_count):$(exits_orphan_names)" "2:gone.io->Pin-Z(deleted),role.io->Auto-1(role)"
exits_json | sed 's/^/{/; s/$/}/' | chk "GET /api/exits 的主体: 默认出口 · 每个出口上的应用 / 网站 / 服务 · 跟随默认 · 自动选 · 孤儿" 'p={x["tag"]:x for x in d["pins"]}; assert d["default"]["tag"]=="Pin-B" and d["default"]["source"]=="live" and d["services_known"] and d["max"]==32 and d["count"]==3; assert p["Pin-A"]["sites"]==["a.io"] and p["Pin-B"]["apps"]==["Cursor"] and p["Pin-B"]["default"] and p["Pin-C"]["services"]==["svc-claude"] and not p["Pin-A"]["default"]; assert d["follow"]["apps"]==["ChatGPT"] and d["follow"]["services"]==["svc-chatgpt"] and d["follow"]["dns"] is False; assert d["auto"]["sites"]==["b.io"] and d["auto"]["services"]==["svc-gemini"]; o={x["name"]:x for x in d["orphans"]}; assert o["gone.io"]["reason"]=="deleted" and o["role.io"]["reason"]=="role" and o["role.io"]["target"]=="Auto-1" and d["orphan_count"]==2'
J=$(UI_PORT=$((BASE + 9)) exits_json | sed 's/^/{/; s/$/}/')
printf '%s' "$J" | chk "核心没运行: 服务读不到 (services_known=false), 应用 / 网站照常; 默认出口退回持久化的 / 第一个" 'assert d["services_known"] is False and d["follow"]["services"]==[] and d["follow"]["apps"]==["ChatGPT"] and d["default"]["source"] in ("stored","first")'
ENANA_EXITS_NO_LIVE=1 exits_resolve; eq "不问核心 (ENANA_EXITS_NO_LIVE): 默认出口 = 第一个固定出口, 来源 first" "$EXITS_DEF/$EXITS_SRC" "Pin-A/first"

echo "== E2. 默认固定出口: 核心里的 > 持久化的 > 第一个 · 老安装第一次读到时记下来 · 核心重启后校正"
rm -f "$H/pin-default"; mkcore Pin-B
exits_resolve; eq "没有持久化文件 (老安装): 默认 = 核心里正在用的 (来源 live), 不是第一个" "$EXITS_DEF/$EXITS_SRC/${EXITS_STORED:-none}" "Pin-B/live/none"
exits_adopt; eq "第一次读到时记下来 (exits_adopt)" "$(cat "$H/pin-default")" "Pin-B"
pins Pin-C Pin-B Pin-A; mkcore Pin-B
eq "服务器顺序变了 (重新导入): 默认出口不变, 不再是「文件里的第一个」" "$(exits_resolve; echo "$EXITS_DEF")" "Pin-B"
cset PIN Pin-A; exits_adopt; eq "核心里被别处切换过: 以核心为准, 持久化的值跟上" "$(cat "$H/pin-default")" "Pin-A"
printf 'Pin-C\n' > "$H/pin-default"
exits_sync_default; eq "核心重启后选择被重置 (缓存丢了): 校正回持久化的默认出口" "$(cnow PIN)" "Pin-C"
has "…并写进操作记录 (来源 auto)" "恢复默认固定出口	from=Pin-A to=Pin-C" "$(OPSLOG)"
exits_sync_default; eq "已经一致: 什么也不做" "$(cnow PIN)" "Pin-C"
rm -f "$H/pin-default"; cset PIN Pin-B; exits_sync_default; eq "没有持久化文件: 不动核心里的选择 (老安装的行为不变)" "$(cnow PIN)" "Pin-B"
printf 'Not-A-Pin\n' > "$H/pin-default"; exits_sync_default; eq "持久化的已经不是固定出口: 忽略, 不动核心" "$(cnow PIN):$(exits_stored)" "Pin-B:"
rm -f "$H/pin-default"
UI_PORT=$((BASE + 9)) exits_adopt; eq "核心读不到: 不用「第一个固定出口」去覆盖用户的选择 (不写文件)" "$([ -f "$H/pin-default" ] && echo wrote || echo none)" "none"

echo "== E3. 批量移动 / 钉住: 一次改写 overrides.tsv; 只动状态是 pin 的行; 标记 ack; 规则集热加载; 服务切换选择器"
pins Pin-A Pin-B Pin-C
ovr 'app|ChatGPT|pin|def|' 'app|Cursor|pin|ack|Pin-B' 'site|a.io|pin|ack|' 'site|b.io|pin|ack|Pin-B' 'site|c.io|pin|ack|PINAUTO' 'site|gone.io|pin|ack|Pin-Z' 'site|d.io|direct|ack|' 'app|Safari|follow|ack|'
mkcore Pin-A svc-chatgpt=PIN svc-claude=PIN svc-gemini=Pin-B svc-auto=PINAUTO
exits_move_check DEFAULT Pin-A ""; eq "检查: 默认 → 某个固定出口" "$?" "0"
exits_move_check DEFAULT Nope ""; eq "检查: 不存在的出口被拒" "$?:$EXITS_ERR" "1:指定的固定出口不存在 (固定出口至少要有 2 个才能单独指定)"
exits_move_check DEFAULT Pin-A bogus; eq "检查: 类型只能是 app / site / service" "$?" "1"
exits_move_check 'a|b' Pin-A ""; eq "检查: 来源里不能有 | " "$?" "1"
OP_WHO=test; r=$(exits_move_rows DEFAULT Pin-A site)
eq "只改网站 (kind=site): 跟随默认的网站钉在 Pin-A, 应用不动" "$r:$(tag_of site a.io):[$(tag_of app ChatGPT)]" "0 1:Pin-A:[]"
r=$(exits_move_rows DEFAULT Pin-A "")
eq "全部: 跟随默认的应用也钉住 (标记变成 ack)" "$r:$(tag_of app ChatGPT):$(awk -F'|' '$2=="ChatGPT" {print $4}' "$H/overrides.tsv")" "1 0:Pin-A:ack"
r=$(exits_move_rows DEFAULT Pin-A ""); eq "再来一次: 没有可移动的 (幂等)" "$r" "0 0"
eq "不是 pin 状态的行 (直连 / 跟随规则) 一个字符都没动" "$(grep -c '^site|d.io|direct|ack|$' "$H/overrides.tsv"):$(grep -c '^app|Safari|follow|ack|$' "$H/overrides.tsv")" "1:1"
r=$(exits_move_rows Pin-B DEFAULT ""); eq "Pin-B → 跟随默认 (清掉指定)" "$r:[$(tag_of app Cursor)]:[$(tag_of site b.io)]" "1 1:[]:[]"
r=$(exits_move_rows PINAUTO Pin-C site); eq "PINAUTO → Pin-C" "$r:$(tag_of site c.io)" "0 1:Pin-C"
r=$(exits_move_rows ORPHAN DEFAULT ""); eq "ORPHAN (指定的出口已经不是固定出口的全部) → 跟随默认" "$r:[$(tag_of site gone.io)]" "0 1:[]"
ovr 'app|ChatGPT|pin|def|' 'site|a.io|pin|ack|' 'site|b.io|pin|ack|Pin-B'
mkcore Pin-A svc-chatgpt=PIN svc-claude=PIN svc-gemini=Pin-B svc-auto=PINAUTO
exits_move_run DEFAULT Pin-A ""
eq "同步路径 (非 TUN): 计数 + 规则集已更新 (ovr-pin-1 里有钉住的应用和网站, 默认的 ovr-pin 里没有)" "$EXITS_M_APPS $EXITS_M_SITES:$(rs pin-1 | grep -c ChatGPT):$(rs pin-1 | grep -c a.io):$(rs pin | grep -c 'ChatGPT\|a.io')" "1 1:1:1:0"
eq "…服务也切了: 选 PIN 的 → Pin-A; 指定了别的出口 / PINAUTO 的不动" "$(cnow svc-chatgpt),$(cnow svc-claude),$(cnow svc-gemini),$(cnow svc-auto):$EXITS_M_SVC:$EXITS_M_SVCFAIL:$EXITS_SVC_KNOWN" "Pin-A,Pin-A,Pin-B,PINAUTO:2:0:1"
has "…写进操作记录: 谁 / 从哪里 / 到哪里 / 各改了几个" "移动固定出口	from=DEFAULT to=Pin-A apps=1 sites=1 services=2" "$(OPSLOG)"
exits_move_run Pin-A DEFAULT service; eq "kind=service: 只动服务, 应用 / 网站不动" "$(cnow svc-chatgpt),$(cnow svc-claude):$(tag_of app ChatGPT)" "PIN,PIN:Pin-A"
exits_move_run Pin-B PINAUTO service; eq "服务 Pin-B → PINAUTO" "$(cnow svc-gemini)" "PINAUTO"
pins Pin-A; mkcore Pin-A svc-chatgpt=PIN
exits_move_check DEFAULT Pin-A ""; eq "只有 1 个固定出口: 不能指定出口 (只能 DEFAULT)" "$?" "1"
exits_move_check Pin-A DEFAULT ""; eq "…但可以移回「跟随默认」" "$?" "0"

echo "== E4. 影响检查 (删除 / 改角色 / 换默认之前): 谁会换出口 IP"
pins Pin-A Pin-B Pin-C
ovr 'app|ChatGPT|pin|def|' 'site|a.io|pin|ack|Pin-A' 'site|b.io|pin|ack|Pin-B' 'site|c.io|pin|ack|PINAUTO' 'site|f.io|pin|ack|'
mkcore Pin-A svc-chatgpt=PIN svc-claude=Pin-A svc-gemini=Pin-B
exits_impact_calc remove Pin-A
eq "删除默认出口 Pin-A: 指定了它的 (a.io + svc-claude) + 跟随默认的 (ChatGPT / f.io / svc-chatgpt) 都受影响; 默认出口会变" "$EXITS_ISPIN/$EXITS_DEF_CHANGES/$EXITS_REMAIN/$EXITS_AFFECTED" "1/1/2/5"
printf '{%s}' "$EXITS_IMPACT_JSON" | chk "影响明细 (界面用): bound / follow / candidates / default_changes" 'assert d["op"]=="remove" and d["tag"]=="Pin-A" and d["is_pin"] and d["default"]=="Pin-A" and d["default_changes"]; assert d["bound"]["sites"]==["a.io"] and d["bound"]["services"]==["svc-claude"] and d["bound"]["apps"]==[]; assert d["follow"]["apps"]==["ChatGPT"] and d["follow"]["sites"]==["f.io"] and d["follow"]["services"]==["svc-chatgpt"]; assert [c["tag"] for c in d["candidates"]]==["Pin-B","Pin-C"] and d["remaining"]==2 and d["affected"]==5'
exits_impact_calc remove Pin-B
eq "删除非默认出口 Pin-B: 只有指定了它的 (b.io + svc-gemini); 默认出口不变, 跟随默认的不受影响" "$EXITS_DEF_CHANGES/$EXITS_AFFECTED" "0/2"
exits_impact_calc remove Pin-C; eq "删除没人用的 Pin-C: 没有受影响的 (PINAUTO 的自动选少一个候选, 不算换出口)" "$EXITS_AFFECTED" "0"
exits_impact_calc remove Auto-Nope; eq "不是固定出口的名字: 不受保护 (is_pin=0)" "$EXITS_ISPIN/$EXITS_AFFECTED" "0/0"
exits_impact_calc default Pin-B; eq "把默认出口换成 Pin-B: 跟随默认的 (ChatGPT / f.io / svc-chatgpt) 受影响" "$EXITS_DEF_CHANGES/$EXITS_AFFECTED" "1/3"
exits_impact_calc default Pin-A; eq "换成现在就是默认的: 没有变化" "$EXITS_DEF_CHANGES/$EXITS_AFFECTED" "0/0"
printf 'VIA=PIN\nLEAK=1\n' > "$H/dns.conf"
exits_impact_calc default Pin-B; eq "DNS 的线路设为固定出口: 也算受影响 (DNS 查询跟着默认出口走), 明细里 follow.dns=true" "$EXITS_AFFECTED" "4"
printf '{%s}' "$EXITS_IMPACT_JSON" | chk "…impact.follow.dns" 'assert d["follow"]["dns"] is True'
rm -f "$H/dns.conf"

echo "== E5. 删除 / 改角色的保护 (op_txn): 有人在用 → 必须指明去向或明确接受后果; 失败什么都不改"
reset_srv() { pins Pin-A Pin-B Pin-C; ovr 'app|ChatGPT|pin|def|' 'site|a.io|pin|ack|Pin-A' 'site|b.io|pin|ack|Pin-B' 'site|f.io|pin|ack|'; rm -f "$H/pin-default"; mkcore Pin-A svc-chatgpt=PIN; }
reset_srv; B4=$(cat "$H/servers.jsonl")$(cat "$H/overrides.tsv")
op_txn "删除服务器" txn_delete Pin-A >/dev/null 2>&1; rc=$?
eq "删除正被使用的默认出口, 没有指明去向: 被拒, 服务器和覆盖原样 (事务回滚)" "$rc:$([ "$B4" = "$(cat "$H/servers.jsonl")$(cat "$H/overrides.tsv")" ] && echo unchanged)" "1:unchanged"
has "…原因写明白 (界面 / 任务结果里就是这句)" "正在使用这个固定出口" "$TXN_ERR"
op_txn "修改服务器角色" txn_role Pin-B auto >/dev/null 2>&1; eq "把正被指定的出口改成别的角色: 同样被拒" "$?:$(srv_list | awk -F'\t' '$1=="Pin-B" {print $5}')" "1:pin"
op_txn "删除服务器" txn_delete Pin-C >/dev/null 2>&1; eq "删除没人用的固定出口: 照常删除" "$?:$(srv_list | awk -F'\t' '$1=="Pin-C"' | wc -l | tr -d ' ')" "0:0"
reset_srv
op_txn "删除服务器" txn_delete Pin-B "" 0 1 >/dev/null 2>&1; eq "明确接受后果 (accept): 删除成功, 指定了它的网站成了孤儿 (仍然记着 Pin-B)" "$?:$(srv_list | awk -F'\t' '$1=="Pin-B"' | wc -l | tr -d ' '):$(tag_of site b.io):$(exits_orphan_count)" "0:0:Pin-B:1"
has "…操作记录里留下「没有改派」" "固定出口移除时没有改派	tag=Pin-B affected=1" "$(OPSLOG)"
reset_srv
op_txn "删除服务器" txn_delete Pin-B Pin-C >/dev/null 2>&1; eq "改派到 Pin-C: b.io 现在指定 Pin-C; 默认出口 (Pin-A) 和跟随默认的不变" "$?:$(tag_of site b.io):[$(tag_of site f.io)]:[$(cat "$H/pin-default" 2>/dev/null)]:$(srv_list | awk -F'\t' '$1=="Pin-B"' | wc -l | tr -d ' ')" "0:Pin-C:[]:[]:0"
reset_srv
op_txn "删除服务器" txn_delete Pin-A Pin-C >/dev/null 2>&1
eq "删除默认出口 Pin-A 并改派到 Pin-C: 指定了它的 (a.io) → Pin-C; 默认出口也换成 Pin-C (跟随默认的随它走, 仍然跟随)" "$?:$(tag_of site a.io):[$(tag_of site f.io)]:[$(tag_of app ChatGPT)]:$(cat "$H/pin-default")" "0:Pin-C:[]:[]:Pin-C"
reset_srv
op_txn "删除服务器" txn_delete Pin-A Pin-C 1 >/dev/null 2>&1
eq "同上 + freeze: 跟随默认的也钉在 Pin-C 上 (以后默认再换也不动它们)" "$?:$(tag_of site f.io):$(tag_of app ChatGPT):$(awk -F'|' '$2=="ChatGPT" {print $4}' "$H/overrides.tsv")" "0:Pin-C:Pin-C:ack"
reset_srv
op_txn "修改服务器角色" txn_role Pin-B auto DEFAULT >/dev/null 2>&1; eq "改角色 + 改派到「跟随默认」: b.io 清掉指定" "$?:[$(tag_of site b.io)]:$(srv_list | awk -F'\t' '$1=="Pin-B" {print $5}')" "0:[]:auto"
reset_srv
op_txn "删除服务器" txn_delete Pin-B Pin-B >/dev/null 2>&1; eq "去向不能是正要移除的这一个" "$?" "1"
op_txn "删除服务器" txn_delete Pin-A DEFAULT >/dev/null 2>&1; eq "默认出口自己不能改派到「跟随默认」" "$?" "1"
op_txn "删除服务器" txn_delete Pin-A PINAUTO >/dev/null 2>&1; eq "默认出口不能改派到 PINAUTO (跟随默认的会没有明确的去向)" "$?" "1"
op_txn "删除服务器" txn_delete Pin-B Nope >/dev/null 2>&1; eq "去向不存在: 被拒" "$?" "1"
op_txn "修改服务器角色" txn_role Pin-B pin >/dev/null 2>&1; eq "角色改成 pin (没有变化): 不受保护" "$?" "0"
pins Pin-A; ovr 'app|ChatGPT|pin|def|' 'site|f.io|pin|ack|'; mkcore Pin-A svc-chatgpt=PIN
op_txn "删除服务器" txn_delete Pin-A >/dev/null 2>&1; eq "唯一的固定出口还有人跟随: 没有去向可选, 必须明确接受" "$?" "1"
op_txn "删除服务器" txn_delete Pin-A "" 0 1 >/dev/null 2>&1; eq "…接受后果: 删除; 它们现在没有固定出口 (规则集退回 PIN → 直连, 健康记录会提示)" "$?:$(srv_list | wc -l | tr -d ' '):$(rs pin | grep -c f.io)" "0:0:1"
pins Pin-A Auto-X; pin Auto-Y auto; ovr 'app|ChatGPT|pin|def|'
op_txn "删除服务器" txn_delete Auto-Y >/dev/null 2>&1; eq "删除自动线路的服务器: 不受保护" "$?" "0"

echo "== E6. 删订阅的保护: 订阅里有被使用的固定出口 → 必须明确接受"
: > "$H/servers.jsonl"; pin Pin-Own; subpin Sub-1 SubA; subpin Sub-2 SubA; printf 'SubA|https://example.invalid/x|0|2|12|0|0|0\n' > "$H/subs.tsv"
ovr 'site|a.io|pin|ack|Sub-1' 'site|b.io|pin|ack|Pin-Own' 'app|ChatGPT|pin|def|'
mkcore Pin-Own svc-chatgpt=PIN
exits_sub_check SubA 0; rc=$?; eq "订阅里的 Sub-1 被 a.io 指定: 拒绝, 结构化信息里有服务器和受影响个数" "$rc:$EXITS_CODE" "1:E_EXIT_IN_USE"
printf '{%s}' "$EXITS_IMPACT_JSON" | chk "…impact = {servers:[…], affected:1}" 'assert d["servers"]==["Sub-1","Sub-2"] and d["affected"]==1'
exits_sub_check SubA 1; eq "明确接受: 放行" "$?" "0"
op_txn "删除订阅" txn_subdel SubA >/dev/null 2>&1; eq "事务里同样被拒, 订阅和服务器原样" "$?:$(srv_list | wc -l | tr -d ' ')" "1:3"
op_txn "删除订阅" txn_subdel SubA 1 >/dev/null 2>&1; eq "接受后果: 订阅连同它的服务器一起删除; a.io 成了孤儿" "$?:$(srv_list | wc -l | tr -d ' '):$(exits_orphan_count)" "0:1:1"
exits_sub_check Nope 0; eq "没有这个订阅 / 订阅里没有固定出口: 不受保护" "$?" "0"

echo "== E7. 固定出口上限 OVR_PIN_MAX (32): 超出的不能单独指定, 但仍是固定出口, 并被标成孤儿 (cap)"
: > "$H/servers.jsonl"; for _i in $(seq 1 34); do pin "Node-$_i"; done
eq "ovr_pins 只列前 32 个" "$(ovr_pins | wc -l | tr -d ' '):$(ovr_pins | tail -1)" "32:Node-32"
ovr 'site|x.io|pin|ack|Node-32' 'site|y.io|pin|ack|Node-33' 'app|Z|pin|ack|Node-34'
ovr_sync
eq "第 32 个出口有自己的规则集; 第 33 个没有 (超出上限的退回默认 ovr-pin)" "$([ -f "$H/rules/ovr-pin-32.json" ] && echo y):$([ -f "$H/rules/ovr-pin-33.json" ] && echo y || echo n):$(rs pin-32 | grep -c x.io):$(rs pin | grep -c y.io)" "y:n:1:1"
eq "三类规则集 (网站 / 应用 / 浏览器) 都按序号生成: 32 个出口 = 96 + 11 个文件" "$(ls "$H"/rules/ovr-*.json | wc -l | tr -d ' ')" "107"
exits_json | sed 's/^/{/; s/$/}/' | chk "总览: 第 33 / 34 个 targetable=false; 指定了它们的是孤儿, 原因 cap" 'p=d["pins"]; assert len(p)==34 and p[31]["targetable"] and not p[32]["targetable"] and not p[33]["targetable"]; o={x["name"]:x["reason"] for x in d["orphans"]}; assert o=={"y.io":"cap","Z":"cap"}'
ovr_target_valid Node-33; eq "ovr_target_valid 也拒绝超出上限的出口" "$?" "1"
rm -f "$H"/rules/ovr-*-3[2-9].json "$H"/rules/ovr-*-[4-9][0-9].json

echo "== E8. 健康记录: 孤儿数量变化写一条「环境状态变化 item=exit_orphans」(升级后第一次 / 没有孤儿不记)"
os_service_info() { SVC_RUNNING=0; SVC_PID=''; }; health_sysproxy_eff() { echo 0; }; route() { :; }; ifconfig() { :; }; auth_logged_in() { return 1; }
rm -f "$H/.health.state" "$H/.health.state.written"; rm -rf "$LOGS"; mkdir -p "$LOGS"
pins Pin-A; ovr 'site|g1.io|pin|ack|Gone-1' 'site|g2.io|pin|ack|Gone-2'
v=$(health_state_vector); has "状态向量里有 orphans=2" "orphans=2( |$)" "$v"
health_state_tick >/dev/null
has "第一次观察就有孤儿: 记一笔 (from=-)" "环境状态变化	item=exit_orphans from=- to=2 names=" "$(OPSLOG)"
has "…名单里有名称 -> 出口 (原因)" "g1.io->Gone-1\(deleted\)" "$(OPSLOG)"
ovr 'site|g1.io|pin|ack|Gone-1'; health_state_tick >/dev/null
has "孤儿变少: item=exit_orphans from=2 to=1" "item=exit_orphans from=2 to=1" "$(OPSLOG)"
n=$(OPSLOG | grep -c exit_orphans); health_state_tick >/dev/null; eq "没有变化: 不重复记" "$(OPSLOG | grep -c exit_orphans)" "$n"
ovr; health_state_tick >/dev/null; has "孤儿清零: to=0" "item=exit_orphans from=1 to=0" "$(OPSLOG)"
rm -f "$H/.health.state" "$H/.health.state.written"; rm -rf "$LOGS"; mkdir -p "$LOGS"
printf 'core=0 pid=- api=0 proxy=0 mode=auto capture=system sysproxy=0 login=0 tun=- if=- gw=- pin=ok\n' > "$H/.health.state"; health_state_tick >/dev/null
hasnt "升级后第一次 (旧的状态行里还没有 orphans 这一项, 现在是 0): 不记事件" "exit_orphans" "$(OPSLOG)"

echo "== E9. HTTP 接口 (lib/api.sh 直接读请求): /api/exits · impact · move · freeze · 删除 / 改角色 / 删订阅的保护 · 策略切换记下默认出口"
TOKEN=test-token; SUDOTOK=$(auth_sudo_issue)
api() { # api <METHOD> <路径+查询> -> 响应正文 (JSON); 不会真的启动后台任务 (没有 $H/enana: job_launch 只写一个失败的任务文件); 总是带着有效的 sudo 令牌 (删除服务器 / 订阅属于需要再次验证密码的接口)
  printf '%s %s HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nX-Enana: 1\r\nX-Enana-Token: %s\r\nX-Enana-Sudo: %s\r\nContent-Length: 0\r\n\r\n' "$1" "$2" "$API_PORT" "$TOKEN" "$SUDOTOK" | ENANA_API_PIPE=1 bash "$REPO/lib/api.sh" 2>/dev/null | tr -d '\r' | sed '1,/^$/d'
}
pins Pin-A Pin-B Pin-C; rm -f "$H/pin-default" "$H/subs.tsv"
ovr 'app|ChatGPT|pin|def|' 'site|a.io|pin|ack|Pin-A' 'site|b.io|pin|ack|Pin-B' 'site|gone.io|pin|ack|Pin-Z'
mkcore Pin-A svc-chatgpt=PIN svc-claude=Pin-B
api GET /api/exits | chk "GET /api/exits: ok + 默认出口 + 孤儿" 'assert d["ok"] and d["default"]["tag"]=="Pin-A" and d["orphan_count"]==1 and d["follow"]["apps"]==["ChatGPT"] and d["follow"]["services"]==["svc-chatgpt"]'
eq "…第一次读到时把核心里的默认出口记下来 (老安装迁移)" "$(cat "$H/pin-default")" "Pin-A"
api GET '/api/exits/impact?op=remove&tag=Pin-A' | chk "GET /api/exits/impact?op=remove: 明细" 'assert d["ok"] and d["is_pin"] and d["default_changes"] and d["affected"]==3 and d["bound"]["sites"]==["a.io"] and d["follow"]["apps"]==["ChatGPT"]'
api GET '/api/exits/impact?op=bogus&tag=x' | chk "…op 不合法: 被拒" 'assert d["ok"] is False'
api GET /api/exits/impact | chk "…缺 tag: 被拒" 'assert d["ok"] is False'
api POST '/api/exits/move?from=DEFAULT&to=Nope' | chk "POST /api/exits/move 去向不存在: E_INVALID" 'assert d["ok"] is False and d["code"]=="E_INVALID"'
api POST '/api/exits/move?from=DEFAULT&to=Pin-B&kind=bogus' | chk "…kind 不合法: E_INVALID" 'assert d["ok"] is False and d["code"]=="E_INVALID"'
api POST '/api/exits/move?from=DEFAULT&to=Pin-C' | chk "POST /api/exits/move (非 TUN): 同步完成, 返回各改了几个 (含服务)" 'assert d["ok"] and d["moved"]=={"apps":1,"sites":0,"services":1} and d["services_known"] and d["services_failed"]==0 and "job" not in d'
eq "…覆盖和核心里的服务选择都变了, 没有重启 (没有调用 apply_config)" "$(tag_of app ChatGPT):$(cnow svc-chatgpt):$(rs pin-3 | grep -c ChatGPT)" "Pin-C:Pin-C:1"
api POST /api/exits/freeze | chk "POST /api/exits/freeze: 跟随默认的 (此时没有了) → 0 项" 'assert d["ok"] and d["moved"]=={"apps":0,"sites":0,"services":0}'
ovr 'app|ChatGPT|pin|def|' 'site|f.io|pin|ack|'; cset svc-chatgpt PIN
api POST /api/exits/freeze | chk "…有跟随默认的: 钉在当前默认出口 Pin-A 上" 'assert d["ok"] and d["moved"]=={"apps":1,"sites":1,"services":1}'
eq "…应用 / 网站明确指定 Pin-A, 服务改选 Pin-A" "$(tag_of app ChatGPT),$(tag_of site f.io),$(cnow svc-chatgpt)" "Pin-A,Pin-A,Pin-A"
pins Pin-A; mkcore Pin-A svc-chatgpt=PIN
api POST /api/exits/freeze | chk "只有一个固定出口: 没什么可钉的 (skipped=single)" 'assert d["ok"] and d["skipped"]=="single"'
pins Pin-A Pin-B Pin-C; ovr 'app|ChatGPT|pin|def|' 'site|a.io|pin|ack|Pin-A' 'site|b.io|pin|ack|Pin-B'; mkcore Pin-A svc-chatgpt=PIN svc-claude=Pin-B; rm -f "$H/pin-default"
api POST '/api/servers/delete?tag=Pin-A' | chk "POST /api/servers/delete 删默认出口且有人在用, 没带参数: E_EXIT_IN_USE + impact (什么也没改)" 'assert d["ok"] is False and d["code"]=="E_EXIT_IN_USE" and d["impact"]["affected"]==3 and d["impact"]["default_changes"] and d["impact"]["bound"]["sites"]==["a.io"]'
eq "…服务器还在, 核心里的选择也没动" "$(srv_list | wc -l | tr -d ' '):$(cnow PIN)" "3:Pin-A"
api POST '/api/servers/delete?tag=Pin-A&reassign=Pin-A' | chk "reassign 不能是它自己: E_INVALID" 'assert d["ok"] is False and d["code"]=="E_INVALID"'
api POST '/api/servers/delete?tag=Pin-A&reassign=Pin-B' | chk "带 reassign=Pin-B: 通过, 交给后台任务 (这里没有真的启动)" 'assert d["ok"] and d["job"].startswith("servers-delete-") and "services_failed" not in d'
eq "…核心里已趁两个出口都在时切好: 默认出口 → Pin-B; 指定了 Pin-A 的服务 / 跟随默认的服务照旧跟随" "$(cnow PIN),$(cnow svc-chatgpt),$(cnow svc-claude)" "Pin-B,PIN,Pin-B"
api POST '/api/servers/delete?tag=Pin-C' | chk "删除没人用的 Pin-C: 不需要任何参数" 'assert d["ok"] and d["job"].startswith("servers-delete-")'
api POST '/api/servers/role?tag=Pin-B&role=auto' | chk "POST /api/servers/role 把默认出口改成 auto: 同样要选去向 (E_EXIT_IN_USE)" 'assert d["ok"] is False and d["code"]=="E_EXIT_IN_USE"'
api POST '/api/servers/role?tag=Pin-B&role=bogus' | chk "角色不合法: 仍然是 E_INVALID" 'assert d["ok"] is False'
api POST '/api/servers/role?tag=Pin-B&role=pin' | chk "角色没变 (pin → pin): 不受保护" 'assert d["ok"] and d["job"].startswith("servers-role-")'
api POST '/api/servers/delete?tag=Pin-B&accept_orphans=1' | chk "accept_orphans=1: 明确接受后果, 放行" 'assert d["ok"] and d["job"].startswith("servers-delete-")'
api POST '/api/servers/delete?tag=Pin-B&accept_orphans=2' | chk "accept_orphans 只能是 0 / 1" 'assert d["ok"] is False'
printf '' > "$H/subs.tsv"; : > "$H/servers.jsonl"; pin Pin-Own; subpin Sub-1 SubA; printf 'SubA|https://example.invalid/x|0|1|12|0|0|0\n' > "$H/subs.tsv"; ovr 'site|a.io|pin|ack|Sub-1'; mkcore Pin-Own
api POST '/api/sub/delete?name=SubA' | chk "POST /api/sub/delete 订阅里有被使用的固定出口: E_EXIT_IN_USE + impact{servers,affected}" 'assert d["ok"] is False and d["code"]=="E_EXIT_IN_USE" and d["impact"]=={"servers":["Sub-1"],"affected":1}'
api POST '/api/sub/delete?name=SubA&accept_orphans=1' | chk "…accept_orphans=1: 放行" 'assert d["ok"] and d["job"].startswith("sub-delete-")'
pins Pin-A Pin-B; rm -f "$H/pin-default"; mkcore Pin-A svc-chatgpt=PIN
api POST '/api/policy?tag=PIN&name=Pin-B' | chk "POST /api/policy 切换默认固定出口 (老接口照常工作)" 'assert d["ok"] and d["from"]=="Pin-A" and d["to"]=="Pin-B"'
eq "…并把它记成默认固定出口 (核心重启后校正用)" "$(cat "$H/pin-default"):$(cnow PIN)" "Pin-B:Pin-B"
api POST '/api/policy?tag=svc-chatgpt&name=Pin-A' >/dev/null; eq "切换服务不改默认固定出口" "$(cat "$H/pin-default")" "Pin-B"

echo "== E10. TUN 模式: 移动走后台任务 (op_txn → apply_config → 免密助手同步); 事务失败时服务选择器切回去"
printf 'NETWORK_MODE=tun\n' > "$H/settings.env"
pins Pin-A Pin-B; ovr 'app|ChatGPT|pin|def|' 'site|f.io|pin|ack|'; mkcore Pin-A svc-chatgpt=PIN
api POST '/api/exits/move?from=DEFAULT&to=Pin-B' | chk "TUN: POST /api/exits/move 返回后台任务, 请求本身什么也没改" 'assert d["ok"] and d["job"].startswith("exits-move-") and "moved" not in d'
eq "…覆盖和服务选择都还没动" "[$(tag_of app ChatGPT)]:[$(tag_of site f.io)]:$(cnow svc-chatgpt)" "[]:[]:PIN"
load_settings; OP_WHO=dashboard
jid() { job_new exits-move "$APPLY_STEPS"; }       # 任务编号 (job_dispatch 的第二个参数); 任务进度写进 $H/jobs
APPLIES=0; job_dispatch exits-move "$(jid)" DEFAULT Pin-B "" >/dev/null 2>&1; rc=$?
eq "任务运行 (job_dispatch exits-move): 覆盖已改, 服务已切, 经过一次 apply_config (TUN 下由它同步给 root 的核心)" "$rc:$(tag_of app ChatGPT),$(tag_of site f.io):$(cnow svc-chatgpt):$APPLIES" "0:Pin-B,Pin-B:Pin-B:1"
cset svc-chatgpt PIN; ovr 'app|ChatGPT|pin|def|'
apply_config() { APPLIES=$((APPLIES + 1)); return 1; }
job_dispatch exits-move "$(jid)" DEFAULT Pin-B "" >/dev/null 2>&1; rc=$?
eq "apply_config 失败 (例如取消了管理员授权): 事务整体回滚, 服务选择器也切回原来的" "$rc:[$(tag_of app ChatGPT)]:$(cnow svc-chatgpt)" "1:[]:PIN"
apply_config() { APPLIES=$((APPLIES + 1)); ovr_sync; APPLY_CHANGED=0; return 0; }
job_dispatch exits-move "$(jid)" DEFAULT Nope "" >/dev/null 2>&1; eq "去向不合法的任务: 失败, 不改任何东西" "$?:[$(tag_of app ChatGPT)]" "1:[]"
rm -f "$H/settings.env"; load_settings

P=$(wc -l < "$W/.pass" | tr -d ' '); F=$(wc -l < "$W/.fail" | tr -d ' ')
echo; echo "exits.sh: $P passed, $F failed"; [ "$F" = 0 ]
