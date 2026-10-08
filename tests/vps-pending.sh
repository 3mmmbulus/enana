#!/bin/bash
# 「部署完成但验证没通过」的恢复流程 (Linux / macOS 都能跑, 不需要 sing-box / sshd / 真实服务器):
#   P1  待验证记录的存取 (权限 600, 摘要不含节点凭据, 同一 host:ssh_port 只留一条, 过期清理)
#   P2  失败原因判断矩阵 (vps_diagnose / vps_reason_msg): 只断言证据支持的, 没证据就明说无法确定
#   P3  本机 TCP 预检: 真实的监听端口 = ok, 关着的端口 = refused; 全部不通时不再启动临时核心
#   P4  部署任务: 远端部署成功但端口不通 → 失败结果带 pending / reason / 实际端口 (不写死 443), 并留下待验证记录
#   P5  重新验证任务: 只在本机验证 (没有 SSH、没有凭据), 通过后保存; 已有的节点不重复添加、不被改动; 记录随后删除
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd -P)
w=$(mktemp -d /tmp/enana-vps-pending.XXXXXX)
trap 'kill $(cat "$w"/pids 2>/dev/null) 2>/dev/null || true; rm -rf "$w"' EXIT
export ENANA_HOME=$w/h ENANA_LANG=zh TMPDIR=$w
mkdir -p "$w/h/jobs"; : > "$w/pids"
set +e
. "$repo/lib/common.sh"; init_paths "$repo/install.sh"
LIB=$repo/lib; DATA=$repo/data
. "$LIB/i18n.sh"; . "$LIB/jobs.sh"; . "$LIB/logs.sh"; . "$LIB/servers.sh"; . "$LIB/vps.sh"
load_settings
set -e
auth_rand_hex() { od -An -N"${1:-16}" -tx1 /dev/urandom | tr -d ' \n'; }
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; exit 1; }
eq() { [ "$2" = "$3" ] && ok "$1" || { echo "  got:  $2"; echo "  want: $3"; bad "$1"; }; }
jget() { python3 -c 'import sys,json; d=json.load(open(sys.argv[1])); '"$2" "$1"; }
mode_of() { if stat -c %a "$1" >/dev/null 2>&1; then stat -c %a "$1"; else stat -f %Lp "$1"; fi; }
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

# ---------- P1 待验证记录 ----------
VD=$w/vd1; mkdir -p "$VD"; chmod 700 "$VD"
printf 'My-VPS-203.0.113.9\t203.0.113.9\t2053\tvless\t{"role":"pin","outbound":{"type":"vless","tag":"My-VPS-203.0.113.9","server":"203.0.113.9","server_port":2053,"uuid":"SECRET-UUID-1"}}\t{"type":"vless","tag":"My-VPS-203.0.113.9","server":"203.0.113.9","server_port":2053,"uuid":"SECRET-UUID-1"}\n' > "$VD/nodes.tsv"
printf 'My-VPS-203.0.113.10\t203.0.113.10\t2053\tvless\t{"role":"pin","outbound":{"type":"vless","tag":"My-VPS-203.0.113.10","server":"203.0.113.10","server_port":2053,"uuid":"SECRET-UUID-1"}}\t{"type":"vless","tag":"My-VPS-203.0.113.10","server":"203.0.113.10","server_port":2053,"uuid":"SECRET-UUID-1"}\n' >> "$VD/nodes.tsv"
VPS_REC_ID=v-aaaaaa; VPS_REC_NAME=My-VPS; VPS_REC_HOST=198.51.100.7; VPS_REC_PORT=22; VPS_REC_USER=root; VPS_REC_OS="Debian GNU/Linux 12 (bookworm)"; VPS_REC_HOSTKEY=SHA256:$(printf 'A%.0s' $(seq 1 43)); VPS_REC_ROLE=pin; VPS_REC_SAVE=1
vps_pending_write p-0a1b2c pending 0
eq "待验证记录: 目录 700 / 文件 600" "$(mode_of "$VPS_PENDING_DIR"):$(mode_of "$VPS_PENDING_DIR/p-0a1b2c")" "700:600"
eq "同一个 host:ssh_port 能找回编号" "$(vps_pending_find 198.51.100.7 22)" "p-0a1b2c"
eq "别的 host / 端口找不到" "$(vps_pending_find 198.51.100.7 2222)$(vps_pending_find 198.51.100.8 22)" ""
j=$(vps_pending_json); echo "{\"pending\":[$j]}" > "$w/p1.json"
eq "摘要: 端口以节点为准 (2053), 两个出口 IP, 不含任何节点凭据" "$(jget "$w/p1.json" 'p=d["pending"][0]; print(p["ports"], p["nodes"], p["ips"], "SECRET" in open(sys.argv[1]).read())')" "[2053] 2 ['203.0.113.9', '203.0.113.10'] False"
vps_pending_note p-0a1b2c blocked_cloud; vps_pending_note p-0a1b2c blocked_cloud
eq "再失败一次: 次数累加, 原因被记下, 节点行没丢" "$(vps_pending_field p-0a1b2c tries):$(vps_pending_field p-0a1b2c reason):$(grep -c '^node	' "$VPS_PENDING_DIR/p-0a1b2c"):$(mode_of "$VPS_PENDING_DIR/p-0a1b2c")" "2:blocked_cloud:2:600"
created=$(vps_pending_field p-0a1b2c created); sleep 1; vps_pending_write p-0a1b2c pending 0
eq "重新写入保留创建时间" "$(vps_pending_field p-0a1b2c created)" "$created"
vps_pending_id_ok 'p-0a1b2c' && ! vps_pending_id_ok '../p-0a1b2c' && ! vps_pending_id_ok 'p-0a1b2c/x' && ! vps_pending_id_ok 'p-0A1B2C' && ok "编号格式严格校验 (不允许路径)" || bad "编号格式严格校验"
touch -t 200001010000 "$VPS_PENDING_DIR/p-0a1b2c"; vps_pending_prune
[ ! -e "$VPS_PENDING_DIR/p-0a1b2c" ] && ok "超过保存期限的自动清理" || bad "过期清理"
vps_pending_write p-0a1b2c pending 0; vps_pending_delete p-0a1b2c
[ ! -e "$VPS_PENDING_DIR/p-0a1b2c" ] && ok "放弃 / 成功后删除" || bad "删除"

# ---------- P2 原因判断矩阵 ----------
mk_tcp() { : > "$VD/tcp"; for r in "$@"; do printf 'n\t%s\t1\n' "$r" >> "$VD/tcp"; done; }
diag() { VPS_EV_LISTEN=$1; VPS_EV_FW=$2; shift 2; mk_tcp "$@"; vps_diagnose; echo "$VPS_TCP/$VPS_REASON"; }
eq "端口全部超时 + 服务在监听 + 没有服务器防火墙 → 多半是云安全组" "$(diag 1 ufw_inactive timeout timeout)" "timeout/blocked_cloud"
eq "端口超时 + 服务在监听 + ufw 启用 → 服务器防火墙或云安全组 (两个都可能)" "$(diag 1 ufw_active timeout)" "timeout/blocked_server"
eq "端口超时 + 没有服务器端证据 → 无法确定 (不断言是防火墙)" "$(diag '' '' timeout)" "timeout/blocked_unknown"
eq "端口超时 + 服务器说没有进程在监听 → 服务没起来, 与防火墙无关" "$(diag 0 none timeout)" "timeout/not_listening"
eq "被明确拒绝 (RST) → 不是云安全组的典型表现" "$(diag '' '' refused)" "refused/refused"
eq "没有路由 → 本机网络问题" "$(diag '' '' unreachable)" "unreachable/unreachable"
eq "TCP 是通的 → 不是防火墙问题 (握手 / 配置 / 时间)" "$(diag '' ufw_active ok ok)" "ok/handshake"
eq "一个通一个不通, 经节点访问都失败 → 以通的为准, 防火墙不是原因" "$(diag 1 ufw_active ok timeout)" "mixed/handshake"
eq "没有做 TCP 预检的协议 (UDP) → 原因无法确定" "$(diag '' '' )" "none/unknown"
VPS_REASON=blocked_cloud; vps_reason_msg 2053
case $VPS_ERR in *"TCP 2053"*"云服务商的安全组"*) ok "原因说明带实际端口 (2053), 不是写死的 443" ;; *) bad "原因说明: $VPS_ERR" ;; esac
case $VPS_ERR in *443*) bad "说明里不应出现 443: $VPS_ERR" ;; *) ok "说明里没有写死的 443" ;; esac
VPS_REASON=handshake; vps_reason_msg 2053
case $VPS_ERR in *"不是防火墙问题"*) ok "握手失败时明确说不是防火墙问题" ;; *) bad "握手说明: $VPS_ERR" ;; esac
VPS_REASON=blocked_unknown; vps_reason_msg 8443 redetect
case $VPS_ERR in "新增的节点没有通过验证 (TCP 8443)"*"无法确定"*) ok "重新识别的措辞 + 不确定性" ;; *) bad "redetect 说明: $VPS_ERR" ;; esac

# ---------- P3 本机 TCP 预检 ----------
OPEN=$(free_port); python3 -c '
import socket,sys,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("127.0.0.1",int(sys.argv[1]))); s.listen(16)
while True:
    c,_=s.accept(); c.close()' "$OPEN" & echo $! >> "$w/pids"
CLOSED=$(free_port); sleep 0.5
VD=$w/vd3; mkdir -p "$VD"
printf '{"type":"vless","tag":"up","server":"127.0.0.1","server_port":%s,"uuid":"x"}\n{"type":"vless","tag":"down","server":"127.0.0.1","server_port":%s,"uuid":"x"}\n{"type":"hysteria2","tag":"udp","server":"127.0.0.1","server_port":%s,"password":"x"}\n' "$OPEN" "$CLOSED" "$CLOSED" > "$VD/nodes.out"
vps_tcp_precheck "$VD/nodes.out"
eq "预检: 监听中的端口 = ok, 关着的 = refused, UDP 协议不检查" "$(cut -f1,2 "$VD/tcp" | paste -sd, -)" "up	ok,down	refused"
printf '{"type":"vless","tag":"down","server":"127.0.0.1","server_port":%s,"uuid":"x"}\n' "$CLOSED" > "$VD/nodes.out"
SB=/nonexistent/sing-box
if vps_verify "$VD/nodes.out"; then bad "端口都不通时验证应该失败"; fi
eq "端口都不通: 不启动临时核心 (没有 sing-box 也能得出结论), 该节点记为 fail" "$(cat "$VD/verify")" "down	fail	"
vps_diagnose; eq "诊断: 全部 refused" "$VPS_TCP/$VPS_REASON" "refused/refused"

# ---------- P4 / P5 任务级流程 (假 ssh + 模拟部署脚本, 全部在本机) ----------
PLAY=$w/playbook; mkdir -p "$PLAY"; cp "$repo"/tests/fixtures/content/vps/*.sh "$PLAY/"
content_file() { printf '%s/%s' "$PLAY" "${1#vps/}"; }
vps_fingerprints() { printf 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\tssh-ed25519\tfixture ssh-ed25519 AAAA\n'; }
export ENANA_MOCK_CTL=$w/vpsctl FAKE_STATE=$w/fs FAKE_SSH_PW='pw-fixture-1' ENANA_SSH=$repo/tests/fakebin/fakessh
mkdir -p "$FAKE_STATE"
HOP=$(free_port)                                  # 模拟「节点端口」: 先让它关着 (= 端口没放行 / 没有监听)
printf 'hop=%s\nips=2\n' "$HOP" > "$ENANA_MOCK_CTL"
HK=SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
SB=/nonexistent/sing-box; SRV_SAVE=''
vps_cred_write "$H/jobs/prov.cred" 127.0.0.1 22 tester password "$FAKE_SSH_PW" '' '' '' "$HK" My-VPS pin 0 '' 0 1
JOB_NAME=vps-provision; JOB_ID=$(job_new vps-provision '连接服务器|检测系统与环境|安装依赖|安装服务端|生成配置与密钥|开放端口并启动|验证连通|识别出口 IP|保存到本机')
( set +e; vps_provision_job "$H/jobs/prov.cred" ) > "$w/job.out" 2>&1 || true
J=$H/jobs/$JOB_ID.json
eq "部署任务: 远端已部署, 本机验证失败 → error / E_VPS_VERIFY" "$(jget "$J" 'print(d["state"], d["result"]["code"])')" "error E_VPS_VERIFY"
eq "失败结果: 实际端口来自节点 (不是写死的 443), 带原因和待验证编号" "$(jget "$J" 'r=d["result"]; print(r["port"]=='"$HOP"', r["ports"]==['"$HOP"'], r["reason"], r["pending"].startswith("p-"), r["nodes"], r["failed"])')" "True True not_listening True 2 2"
case $(jget "$J" 'print(d["msg"])') in *"TCP $HOP"*"没有进程在监听"*) ok "错误说明用实际端口 ($HOP), 并指出服务没有在监听" ;; *) bad "错误说明: $(jget "$J" 'print(d["msg"])')" ;; esac
PID=$(jget "$J" 'print(d["result"]["pending"])')
[ -f "$VPS_PENDING_DIR/$PID" ] && ok "留下了待验证记录 $PID" || bad "待验证记录"
[ ! -e "$H/jobs/prov.cred" ] && ok "凭据临时文件已删除" || bad "凭据文件还在"
eq "步骤: 验证连通失败, 前 6 步已完成 (部署本身没有失败)" "$(jget "$J" 'print([s["state"] for s in d["steps"]][:7])')" "['done', 'done', 'done', 'done', 'done', 'done', 'error']"
printf 'hop=%s\nips=2\n' "$HOP" > "$ENANA_MOCK_CTL"
echo "{\"p\":[$(vps_pending_json)]}" > "$w/p4.json"
eq "待验证列表: 服务器还没有任何节点被保存 (servers.jsonl 为空), 摘要里没有凭据" "$([ -s "$H/servers.jsonl" ] && echo has || echo empty):$(jget "$w/p4.json" 'print(len(d["p"]), d["p"][0]["ports"]==['"$HOP"'])')" "empty:1 True"

# 重新验证 (端口放行了: 让模拟的节点端口真的有人监听) —— 只在本机, 没有 SSH
python3 -c '
import socket,sys
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("127.0.0.1",int(sys.argv[1]))); s.listen(16)
while True:
    c,_=s.accept(); c.close()' "$HOP" & echo $! >> "$w/pids"; sleep 0.5
op_txn() { shift; "$@"; local rc=$?; [ "$rc" = 0 ] && job_ok "完成" "${TXN_RESULT:-{\}}"; return $rc; }
sync_after_save() { :; }
vps_verify() { # 替身: 这里只验证流程 (真正的临时核心验证在 macOS CI 里跑); 端口预检仍是真的
  vps_tcp_precheck "$1"; : > "$VD/verify"
  while IFS= read -r l; do t=$(vps_ob_field "$l" tag); if awk -F'\t' -v t="$t" '$1 == t && $2 != "ok" {f=1} END{exit !f}' "$VD/tcp"; then printf '%s\tfail\t\n' "$t" >> "$VD/verify"; else printf '%s\tok\t203.0.113.9\n' "$t" >> "$VD/verify"; fi; done < "$1"
  grep -q '	ok	' "$VD/verify"
}
ssh_calls_before=$(wc -l < "$FAKE_STATE/ssh.log" 2>/dev/null || echo 0)
JOB_NAME=vps-verify; JOB_ID=$(job_new vps-verify '读取部署记录|检查端口|验证连通|识别出口 IP|保存到本机')
( set +e; vps_verify_job "$PID" ) > "$w/job2.out" 2>&1 || true
J=$H/jobs/$JOB_ID.json
eq "重新验证: 通过 → done, 2 个节点已保存到本机" "$(jget "$J" 'r=d["result"]; print(d["state"], r["added"], r["unchanged"], len(r["nodes"]), all(n["verified"] for n in r["nodes"]))')" "done 2 0 2 True"
eq "没有再 SSH 到服务器 (不重复部署, 不需要凭据)" "$(wc -l < "$FAKE_STATE/ssh.log" 2>/dev/null || echo 0)" "$ssh_calls_before"
eq "节点已写入 servers.jsonl (角色沿用向导里选的 pin)" "$(srv_list | awk -F'\t' '{print $1 ":" $5}' | paste -sd, -)" "My-VPS-203.0.113.9:pin,My-VPS-203.0.113.10:pin"
[ ! -e "$VPS_PENDING_DIR/$PID" ] && ok "保存成功后待验证记录已删除" || bad "待验证记录没删"
[ "$(sed -n 's/.*"vps":"\(v-[0-9a-f]*\)".*/\1/p' "$J" | head -1)" != "" ] && ok "服务器记录 (vps.jsonl) 同时写好" || bad "没有 vps 记录"
JOB_NAME=vps-verify; JOB_ID=$(job_new vps-verify 'a|b|c|d|e'); ( set +e; vps_verify_job "$PID" ) > "$w/job3.out" 2>&1 || true
eq "再点一次 (记录已经没了) → E_NOT_FOUND, 不会重复添加" "$(jget "$H/jobs/$JOB_ID.json" 'print(d["state"], d["result"]["code"])'):$(srv_list | wc -l | tr -d ' ')" "error E_NOT_FOUND:2"

# 已有节点: 完全一样的不动; 用户改过角色的保留角色; 不会被覆盖
srv_set_role My-VPS-203.0.113.10 auto
VD=$w/vd5; mkdir -p "$VD"; chmod 700 "$VD"
printf 'hop=%s\nips=2\n' "$HOP" > "$ENANA_MOCK_CTL"
vps_collect_nodes pin_unused >/dev/null 2>&1 || true
# 手工构造和已有节点完全一致 / 同名但密钥变了 的两条
oldob=$(srv_emit | awk -F'\t' '$2 == "My-VPS-203.0.113.9" {print $3}')
printf 'My-VPS-203.0.113.9\t203.0.113.9\t%s\tsocks\t{"role":"pin","outbound":%s}\t%s\n' "$HOP" "$oldob" "$oldob" > "$VD/nodes.tsv"
newob=$(printf '%s' "$(srv_emit | awk -F'\t' '$2 == "My-VPS-203.0.113.10" {print $3}')" | sed 's/"server_port":\([0-9]*\)/"server_port":\1,"x":"changed"/')
printf 'My-VPS-203.0.113.10\t203.0.113.10\t%s\tsocks\t{"role":"pin","outbound":%s}\t%s\n' "$HOP" "$newob" "$newob" >> "$VD/nodes.tsv"
vps_nodes_plan "$VD/nodes.tsv"
eq "已有节点比较: 完全一样 1 个原样保留, 同名但内容不同 1 个更新, 新增 0" "$VPS_PLAN_SAME/$VPS_PLAN_UPD/$VPS_PLAN_NEW" "1/1/0"
eq "更新的那个沿用你设的角色 (auto), 不被向导里的 pin 覆盖" "$(sed -n 's/^{"role":"\([a-z]*\)".*/\1/p' "$VD/nodes.save.jsonl")" "auto"

# ---------- P6 探测结果: 云端脚本告诉的「将要用的端口」+ 本机记着的待验证部署 ----------
printf 'hop=%s\nips=1\nbusy=1\n' "$HOP" > "$ENANA_MOCK_CTL"
VD=$w/vd6; mkdir -p "$VD"; chmod 700 "$VD"
printf 'My-VPS-203.0.113.9\t203.0.113.9\t2053\tvless\t{"role":"pin","outbound":{"type":"vless","tag":"My-VPS-203.0.113.9","server":"203.0.113.9","server_port":2053,"uuid":"u"}}\t{"type":"vless","tag":"My-VPS-203.0.113.9","server":"203.0.113.9","server_port":2053,"uuid":"u"}\n' > "$VD/nodes.tsv"
VPS_REC_ID=v-bbbbbb; VPS_REC_HOST=127.0.0.1; VPS_REC_PORT=22; vps_pending_write p-6a6a6a pending 0
vps_cred_write "$H/jobs/probe6.cred" 127.0.0.1 22 tester password "$FAKE_SSH_PW" '' '' '' '' '' pin 0 '' 0
JOB_NAME=vps-probe; JOB_ID=$(job_new vps-probe '连接服务器|检测系统与环境|整理结果')
( set +e; vps_probe_job "$H/jobs/probe6.cred" ) > "$w/job6.out" 2>&1 || true
J=$H/jobs/$JOB_ID.json
eq "探测: 云端脚本给了 plan_port 就带上 (默认端口被占用时改用 2053), 没有给就是 null (界面不假设端口)" "$(jget "$J" 'r=d["result"]; print(r["plan"]["port"], r["plan"]["reason"], 443 in r["listening"])')" "2053 default_busy True"
eq "探测: 本机有这台服务器的待验证部署 → node.installed 为 true (不再显示「尚未部署」), 并带 pending 摘要" "$(jget "$J" 'r=d["result"]; print(r["node"]["installed"], r["pending"]["id"], r["pending"]["ports"], "uuid" in open(sys.argv[1]).read())')" "True p-6a6a6a [2053] False"
printf 'hop=%s\nips=1\n' "$HOP" > "$ENANA_MOCK_CTL"; vps_pending_delete p-6a6a6a
JOB_NAME=vps-probe; JOB_ID=$(job_new vps-probe '连接服务器|检测系统与环境|整理结果')
vps_cred_write "$H/jobs/probe7.cred" 127.0.0.1 22 tester password "$FAKE_SSH_PW" '' '' '' '' '' pin 0 '' 0
( set +e; vps_probe_job "$H/jobs/probe7.cred" ) > "$w/job7.out" 2>&1 || true
eq "探测: 没有 plan_port、没有待验证记录 → plan / pending 都是 null" "$(jget "$H/jobs/$JOB_ID.json" 'r=d["result"]; print(r["plan"], r["pending"], r["node"]["installed"])')" "None None False"

# ---------- 并发保护: 同一条记录同时只允许一个验证任务 ----------
vps_pending_write p-ffffff pending 0 2>/dev/null || { VD=$w/vd1; vps_pending_write p-ffffff pending 0; }
vps_pending_lock p-ffffff && ok "第一个验证任务拿到锁" || bad "拿锁"
vps_pending_lock p-ffffff && bad "第二个不应该拿到锁" || ok "第二个验证任务被挡住 (E_BUSY)"
vps_pending_unlock p-ffffff; vps_pending_lock p-ffffff && ok "释放后可以再拿" || bad "释放后拿锁"
echo "ALL PASS"
