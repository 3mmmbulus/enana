#!/bin/bash
# No administrator calls, real launchd mutations or route changes. Schema check
# uses a real sing-box when SINGBOX is supplied; all fixtures are temporary.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
W=$(mktemp -d /tmp/enana-enhanced.XXXXXX); W=$(cd "$W" && pwd -P); trap 'rm -rf "$W"' EXIT
export ENANA_HOME="$W/h" ENANA_NO_MDFIND=1 ENANA_APPS_ROOTS="$W/apps" ENANA_LANG=en
mkdir -p "$W/h/rules" "$W/apps"
. "$REPO/lib/common.sh"; init_paths "$REPO/install.sh"
LIB=$REPO/lib; DATA=$REPO/data
for f in i18n servers apps autosites sites fetch os-darwin enhanced auth dns logs config jobs ops; do . "$LIB/$f.sh"; done
load_settings
set -e
[ "$H" = "$W/h" ] || exit 1
[ "$NETWORK_MODE" = system ]
printf 'NETWORK_MODE=tun\n' > "$H/settings.env"; load_settings || true; [ "$NETWORK_MODE" = tun ]
printf 'NETWORK_MODE=unknown\n' > "$H/settings.env"; load_settings || true; [ "$NETWORK_MODE" = system ]
: > "$H/settings.env"
core_version() { echo 1.14.2; }
mkdir -p "$W/apps/ChatGPT.app/Contents"
printf '%s\n' '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleURLTypes</key><array><dict><key>CFBundleURLSchemes</key><array><string>http</string><string>https</string><string>codex</string></array></dict></array></dict></plist>' > "$W/apps/ChatGPT.app/Contents/Info.plist"
! app_is_browser "$W/apps/ChatGPT.app" # Native AI apps with HTTP deep links remain native PIN apps.
printf 'app|Google Chrome|direct|ack\napp|Gemini|pin|ack\napp|Claude|pin|ack\napp|ChatGPT|pin|ack\napp|Terminal|auto|ack\n' > "$H/overrides.tsv"
printf 'Google Chrome\t/Applications/Google Chrome.app\nGemini\t/Applications/Gemini.app\nClaude\t/Applications/Claude.app\nChatGPT\t/Applications/ChatGPT.app\nTerminal\t/System/Applications/Utilities/Terminal.app\n' > "$H/.apps.now"
printf '%s\n' '{"role":"pin","outbound":{"type":"socks","tag":"First-PIN","server":"127.0.0.1","server_port":1}}' '{"role":"pin","outbound":{"type":"socks","tag":"Second-PIN","server":"127.0.0.1","server_port":3}}' > "$H/servers.jsonl"
ovr_set site claude.com pin ack Second-PIN
ovr_sync || { echo "FAIL: override generation"; exit 1; }
NETWORK_MODE=system; gen_config --no-rulesets || { echo "FAIL: config generation"; exit 1; }; cp "$H/config.json.new" "$W/system.json"
NETWORK_MODE=tun; gen_config --no-rulesets || { echo "FAIL: config generation"; exit 1; }; cp "$H/config.json.new" "$W/tun.json"
python3 - "$W" "$H" <<'PY'
import json,sys,ipaddress
w,h=sys.argv[1:]; s=json.load(open(w+'/system.json')); t=json.load(open(w+'/tun.json'))
assert not any(i['type']=='tun' for i in s['inbounds'])
i=next(i for i in t['inbounds'] if i['type']=='tun')
assert any(a.get('clash_mode')=='Direct' and a.get('server')=='dns-cn' for a in t['dns']['rules'])
assert i['auto_route'] and t['route']['auto_detect_interface'] and t['route']['find_process']
assert i['stack']=='gvisor'
for ip in ['127.0.0.1','127.1.2.3','10.0.1.1','100.100.100.100','172.20.1.1','192.168.1.1','169.254.1.1','::1','fd12::1','fe80::1']:
 assert any(ipaddress.ip_address(ip) in ipaddress.ip_network(c) for c in i['route_exclude_address'])
for ip in ['8.8.8.8','2606:4700:4700::1111']:
 assert not any(ipaddress.ip_address(ip) in ipaddress.ip_network(c) for c in i['route_exclude_address'])
r=t['route']['rules']; idx=lambda k:next(n for n,a in enumerate(r) if k(a))
assert idx(lambda a:a.get('action')=='hijack-dns') < idx(lambda a:a.get('ip_is_private'))
assert idx(lambda a:a.get('ip_is_private')) < idx(lambda a:a.get('rule_set')==['ovr-pin'])
assert idx(lambda a:a.get('rule_set')==['ovr-apppin']) < idx(lambda a:a.get('rule_set')==['ovr-pin-2'])
assert 'Gemini' in open(h+'/rules/ovr-apppin/ovr-apppin.json').read()
for b in ['ovr-browserdirect','ovr-browserauto','ovr-browserpin','ovr-browserpinauto','ovr-browserpin-2']:
 assert idx(lambda a:a.get('outbound')=='svc-claude') < idx(lambda a:a.get('rule_set')==[b])
 assert idx(lambda a:a.get('rule_set')==['ovr-pin']) < idx(lambda a:a.get('rule_set')==[b])
assert 'Google Chrome' in open(h+'/rules/ovr-browserdirect/ovr-browserdirect.json').read()
assert 'Google Chrome' not in open(h+'/rules/ovr-appdirect/ovr-appdirect.json').read()
assert 'Terminal' in open(h+'/rules/ovr-appauto/ovr-appauto.json').read()   # 应用自动单独成集 (N1)
for app in ['Gemini','Claude','ChatGPT']:
 assert app in open(h+'/rules/ovr-pin/ovr-pin.json').read()
assert s['route']['rules']==[a for a in r if 'tun-in' not in a.get('inbound',[])]
print('PASS: defaults, migration, IPv4/IPv6 exclusions, shared PIN routes, browser fallback priority')
PY
if [ -n "${SINGBOX:-}" ]; then
 "$SINGBOX" check -c "$W/system.json"
 "$SINGBOX" check -c "$W/tun.json"
 echo 'PASS: real sing-box validates both generated configurations'
fi
# Run the actual snapshot transform with directory arguments. A list-context
# diamond used to consume these arguments, leaving root on user cache/logs.
enhanced_stage_config "$W/tun.json" "$H" "$W/root with spaces" > "$W/snapshot.json"
python3 - "$W" "$H" <<'PY'
import json,sys
w,h=sys.argv[1:]; before=json.load(open(w+'/tun.json')); after=json.load(open(w+'/snapshot.json')); root=w+'/root with spaces'
assert after['log']['output']==root+'/sing-box.log'
assert after['experimental']['cache_file']['path']==root+'/cache.db'
assert after['outbounds']==before['outbounds']
for a,b in zip(before['route'].get('rule_set',[]),after['route'].get('rule_set',[])):
 if 'path' in a: assert b['path']==root+a['path'][len(h):]
print('PASS: actual privileged snapshot isolates log/cache/rule paths and preserves outbounds')
PY
# Exercise the installer port decision with a root core and only a helper GUI
# job. A TUN upgrade must keep the ports already used by System Proxy/UI.
(
  eval "$(sed -n '/^pick_ports() {/,/^}/p' "$REPO/install.sh")"
  . "$LIB/detect.sh" || { echo 'FAIL: lib/detect.sh did not load (pick_ports needs port_state)'; exit 1; }
  PORT=7890; UI_PORT=9090; API_PORT=9091; SPEED_PORT=7892
  os_service_loaded() { return 0; }
  launchctl() { [ "$1" = print ] && [ "$2" = "$GUI/$LABEL_API" ]; }
  port_busy() { return 0; }
  lsof() { :; }                  # no visible listener: the root core is invisible to an ordinary account
  port_random() { echo 49999; }
  settings_set() { echo 'FAIL: root core ports were reassigned'; exit 1; }
  set_ui_url() { :; }
  pick_ports
  [ "$PORT:$UI_PORT:$API_PORT:$SPEED_PORT" = 7890:9090:9091:7892 ] || { echo 'FAIL: installer moved a port owned by the root TUN service'; exit 1; }
  [ "$UNSEEN_PORTS" = '7890 / 9090 / 9091 / 7892' ] || { echo "FAIL: unseen ports not reported: [$UNSEEN_PORTS]"; exit 1; }
  [ "$PORTS_VERIFIED" = 0 ] || { echo 'FAIL: ports the installer could not confirm were reported as verified'; exit 1; }
) || exit 1
echo 'PASS: installer preserves ports owned by the root TUN service'
# The installer's upgrade decision for the core (install.sh upgrade_core_plan). TUN hands the core to root, and enana only hands over an official pinned core
# that has not changed since it was verified (core_tun_ok). Everything 2.3.23 and earlier installed has no provenance record: without a re-download the new
# TUN preflight refuses, the configuration step fails, the old program files come back and every self-update fails the same way.
(
  eval "$(sed -n '/^upgrade_core_plan() {/,/^}/p' "$REPO/install.sh")"
  type upgrade_core_plan >/dev/null 2>&1 || { echo 'FAIL: upgrade_core_plan not found in install.sh'; exit 1; }
  . "$LIB/update.sh" || { echo 'FAIL: lib/update.sh did not load (upgrade_core_plan needs version_gt)'; exit 1; }
  H="$W/plan"; SB="$H/sing-box"; DATA="$W/plan-data"; ARCH=arm64; MACOS_MAJOR=14
  mkdir -p "$H" "$DATA"
  printf '#!/bin/sh\necho "sing-box version 1.14.5"\n' > "$SB"; chmod +x "$SB"
  printf '1.14.5|darwin-arm64|%064d\n' 0 > "$DATA/core-pins.conf"          # 1.14.5 has a pinned SHA-256 for this build, 1.14.6 has none
  core_version() { printf '%s\n' "$CUR"; }
  plan() { # <network mode> <installed core version> -> REC_core|SINGBOX_VERSION|CORE_PINNED_ONLY
    ( NETWORK_MODE=$1; CUR=$2; ST_core=1; REC_core=skip; WHY_core='already installed'; unset SINGBOX_VERSION CORE_PINNED_ONLY
      upgrade_core_plan; printf '%s|%s|%s' "$REC_core" "${SINGBOX_VERSION:-}" "${CORE_PINNED_ONLY:-}" )
  }
  want_plan() { local got; got=$(plan "$2" "$3"); [ "$got" = "$4" ] || { echo "FAIL: $1: expected [$4], got [$got]"; exit 1; }; }
  rm -f "$H/core-provenance" "$H/core-binary.sha256"                       # what 2.3.23 leaves behind: no record at all
  want_plan 'TUN, no provenance: re-download the installed version, pinned only' tun 1.14.5 'chain|1.14.5|1'
  want_plan 'TUN, no provenance, no pinned SHA-256 for the installed version: CORE_PIN instead' tun 1.14.6 "chain|$CORE_PIN|1"
  want_plan 'System Proxy, no provenance: keep the core' system 1.14.5 'skip||'
  printf 'pinned 1.14.5 %064d\n' 0 > "$H/core-provenance"; shasum -a 256 "$SB" | awk '{print $1}' > "$H/core-binary.sha256"
  want_plan 'TUN, pinned and unchanged: keep the core' tun 1.14.5 'skip||'
  printf '%064d\n' 0 > "$H/core-binary.sha256"
  want_plan 'TUN, pinned but changed after it was verified: re-download' tun 1.14.5 'chain|1.14.5|1'
  want_plan 'System Proxy, pinned but changed: keep the core (only TUN hands it to root)' system 1.14.5 'skip||'
  rm -f "$H/core-provenance" "$H/core-binary.sha256"
  want_plan 'TUN, core older than CORE_PIN: upgrade to CORE_PIN as before' tun 1.13.0 'chain||'
  want_plan 'System Proxy, core older than CORE_PIN: upgrade to CORE_PIN as before' system 1.13.0 'chain||'
  why=$(NETWORK_MODE=system; CUR=1.13.0; ST_core=1; upgrade_core_plan; printf '%s' "$WHY_core")
  [ "$why" = "本版本要求 sing-box $CORE_PIN, 将升级核心" ] || { echo "FAIL: the reason shown for an old core changed: [$why]"; exit 1; }
  why=$(NETWORK_MODE=tun; CUR=1.14.5; ST_core=1; upgrade_core_plan; printf '%s' "$WHY_core")
  case $why in *'sing-box 1.14.5'*) ;; *) echo "FAIL: the re-pin reason does not name the version it downloads: [$why]"; exit 1 ;; esac
  got=$(NETWORK_MODE=tun; CUR=1.14.5; ST_core=0; REC_core=brew; upgrade_core_plan; printf '%s' "$REC_core")
  [ "$got" = brew ] || { echo "FAIL: without an installed core the recommendation must stay as it was: [$got]"; exit 1; }
) || exit 1
echo 'PASS: an upgrade re-pins the core only for TUN users whose core is unpinned or changed'
# Re-running the install command (no --upgrade; install.sh reinstall_core_plan) keeps an installed core, except that TUN can only use an official pinned core:
# then it re-pins exactly as an upgrade does. Without that the TUN preflight refuses in st_config, the whole install rolls back, and the `enana upgrade` the
# refusal suggests is the old version's command, which only says the core is already the latest.
(
  eval "$(sed -n '/^upgrade_core_plan() {/,/^}/p' "$REPO/install.sh")"
  eval "$(sed -n '/^reinstall_core_plan() {/,/^}/p' "$REPO/install.sh")"
  type reinstall_core_plan >/dev/null 2>&1 || { echo 'FAIL: reinstall_core_plan not found in install.sh'; exit 1; }
  . "$LIB/update.sh" || { echo 'FAIL: lib/update.sh did not load (upgrade_core_plan needs version_gt)'; exit 1; }
  H="$W/replan"; SB="$H/sing-box"; DATA="$W/replan-data"; ARCH=arm64; MACOS_MAJOR=14
  mkdir -p "$H" "$DATA"
  printf '#!/bin/sh\necho "sing-box version 1.14.5"\n' > "$SB"; chmod +x "$SB"
  printf '1.14.5|darwin-arm64|%064d\n' 0 > "$DATA/core-pins.conf"
  core_version() { printf '%s\n' "$CUR"; }
  replan() { # <network mode> <installed core version> <REC_core from recommend> -> REC_core|SINGBOX_VERSION|CORE_PINNED_ONLY
    ( NETWORK_MODE=$1; CUR=$2; ST_core=1; REC_core=$3; WHY_core='already installed'; unset SINGBOX_VERSION CORE_PINNED_ONLY
      reinstall_core_plan; printf '%s|%s|%s' "$REC_core" "${SINGBOX_VERSION:-}" "${CORE_PINNED_ONLY:-}" )
  }
  want_replan() { local got; got=$(replan "$2" "$3" "$4"); [ "$got" = "$5" ] || { echo "FAIL: $1: expected [$5], got [$got]"; exit 1; }; }
  rm -f "$H/core-provenance" "$H/core-binary.sha256"                       # what 2.3.23 leaves behind: no record at all
  want_replan 'TUN, no provenance: re-pin the installed version, pinned only' tun 1.14.5 skip 'chain|1.14.5|1'
  want_replan 'System Proxy, no provenance: keep the installed core as before' system 1.14.5 skip 'skip||'
  want_replan 'TUN, a download already chosen (no core installed, or --force): leave the choice alone' tun 1.14.5 chain 'chain||'
  printf 'pinned 1.14.5 %064d\n' 0 > "$H/core-provenance"; shasum -a 256 "$SB" | awk '{print $1}' > "$H/core-binary.sha256"
  want_replan 'TUN, pinned and unchanged: keep the core' tun 1.14.5 skip 'skip||'
  printf '%064d\n' 0 > "$H/core-binary.sha256"
  want_replan 'TUN, pinned but changed after it was verified: re-pin' tun 1.14.5 skip 'chain|1.14.5|1'
  rm -f "$H/core-provenance" "$H/core-binary.sha256"
  why=$(NETWORK_MODE=tun; CUR=1.14.5; ST_core=1; REC_core=skip; reinstall_core_plan; printf '%s' "$WHY_core")
  case $why in 'TUN 需要官方的'*'sing-box 1.14.5'*) ;; *) echo "FAIL: the install menu does not say why the core is downloaded again: [$why]"; exit 1 ;; esac
) || exit 1
echo 'PASS: re-running the install command re-pins the core only for TUN users whose core TUN cannot use'
# st_config (install.sh) when apply_config returns 5: TUN was refused (config_tun_refused keeps the capture mode, puts the old configuration back and gives the reason).
# The installer must print that reason (TXN_ERR) and say the current version was kept, not "the generated configuration did not pass sing-box validation"
# (which sent users looking for a configuration problem), and the upgrade rollback (EXIT trap -> restore_on_fail) must still run.
(
  eval "$(sed -n '/^st_config() {/,/^}/p' "$REPO/install.sh")"
  type st_config >/dev/null 2>&1 || { echo 'FAIL: st_config not found in install.sh'; exit 1; }
  H="$W/stcfg"; SRC="$W/stcfg-src"; mkdir -p "$H" "$SRC"; printf '2.3.23\n' > "$H/VERSION"
  step() { :; }; install_files() { :; }; auth_init() { :; }; srv_migrate_v1() { return 1; }; migrate_v1_domains() { :; }
  sb_ver() { SB_MAJOR=1; SB_MINOR=14; }; lock_take() { return 1; }; op_lock() { return 1; }; op_unlock() { :; }
  snapshot_program() { echo snapshot >> "$W/stcfg.calls"; }; restore_on_fail() { echo "restore $1" >> "$W/stcfg.calls"; }
  apply_config() { TXN_ERR=$STUB_ERR; [ -z "${STUB_ADMIN+x}" ] || ENHANCED_ADMIN_ERR=$STUB_ADMIN; return "$STUB_RC"; }    # STUB_ADMIN: what the administrator dialog reported (unset: left alone)
  run_st() { # <language> <apply_config return code> <TXN_ERR>  -> rc, out
    : > "$W/stcfg.calls"; I18N_LANG=$1; LANG_UI=$1; STUB_RC=$2; STUB_ERR=$3
    out=$( ( st_config ) 2>&1 ); rc=$?
  }
  run_st zh 5 'TUN 没有启动 (preflight-core-unpinned): 请运行 enana upgrade, 或改用系统代理模式'
  [ "$rc" = 1 ] || { echo "FAIL: st_config must stop the installer (rc=$rc)"; exit 1; }
  printf '%s\n' "$out" | grep -qF '✗ TUN 没有启动 (preflight-core-unpinned): 请运行 enana upgrade, 或改用系统代理模式' || { echo "FAIL: the TUN refusal reason was not printed: $out"; exit 1; }
  printf '%s\n' "$out" | grep -qF '已保留当前版本, 没有升级' || { echo "FAIL: not told that the current version was kept: $out"; exit 1; }
  ! printf '%s\n' "$out" | grep -qF '生成的配置没有通过 sing-box 校验' || { echo "FAIL: a TUN refusal was reported as a sing-box validation failure: $out"; exit 1; }
  [ "$(paste -sd, - < "$W/stcfg.calls")" = 'snapshot,restore 1' ] || { echo "FAIL: the upgrade rollback did not run: $(cat "$W/stcfg.calls")"; exit 1; }
  run_st zh 5 ''
  printf '%s\n' "$out" | grep -qF '✗ TUN 没有启动, 新配置没有应用' || { echo "FAIL: no fallback text when TXN_ERR is empty: $out"; exit 1; }
  run_st en 5 'TUN 没有启动 (preflight-core-unpinned): 请运行 enana upgrade, 或改用系统代理模式'
  printf '%s\n' "$out" | grep -qF 'TUN did not start (preflight-core-unpinned): run enana upgrade, or switch to system proxy mode' || { echo "FAIL: the refusal reason is not translated: $out"; exit 1; }
  printf '%s\n' "$out" | grep -qF 'The current version was kept; nothing was upgraded' || { echo "FAIL: the kept-version hint is not translated: $out"; exit 1; }
  run_st zh 1 ''                                                           # control: a real validation failure keeps its own message
  printf '%s\n' "$out" | grep -qF '生成的配置没有通过 sing-box 校验' || { echo "FAIL: the validation-failure message is gone: $out"; exit 1; }
  # A TUN user who cancels the administrator dialog during the upgrade: apply_config returns 3 with ENHANCED_ADMIN_ERR=cancelled. Root never ran and the old
  # TUN keeps running, so say the authorization was cancelled and the current version was kept, not "the new configuration could not start the proxy core"
  STUB_ADMIN=cancelled; run_st zh 3 ''
  [ "$rc" = 1 ] || { echo "FAIL: a cancelled authorization must stop the installer (rc=$rc)"; exit 1; }
  printf '%s\n' "$out" | grep -qF '✗ 已取消管理员授权, 新配置没有应用' || { echo "FAIL: a cancelled authorization was not reported as cancelled: $out"; exit 1; }
  printf '%s\n' "$out" | grep -qF '已保留当前版本, 没有升级' || { echo "FAIL: not told that the current version was kept after a cancel: $out"; exit 1; }
  ! printf '%s\n' "$out" | grep -qF '新配置没能让代理核心启动' || { echo "FAIL: a cancelled authorization was reported as a core start failure: $out"; exit 1; }
  [ "$(paste -sd, - < "$W/stcfg.calls")" = 'snapshot,restore 1' ] || { echo "FAIL: the upgrade rollback did not run after a cancel: $(cat "$W/stcfg.calls")"; exit 1; }
  run_st en 3 ''
  printf '%s\n' "$out" | grep -qF 'Administrator authorization was cancelled, so the new configuration was not applied' || { echo "FAIL: the cancel message is not translated: $out"; exit 1; }
  unset STUB_ADMIN; ENHANCED_ADMIN_ERR=cancelled; run_st zh 3 ''       # control: a cancel left over from before st_config is not this apply's result; a real start failure keeps its message
  printf '%s\n' "$out" | grep -qF '✗ 新配置没能让代理核心启动, 已回滚到原来的配置' || { echo "FAIL: a stale cancel hid a core start failure: $out"; exit 1; }
  ENHANCED_ADMIN_ERR=''
) || exit 1
echo 'PASS: a TUN refusal or a cancelled authorization while installing reports what happened, keeps the current version and still rolls back'
(
  SB=${SINGBOX:-$(type -P true)}
  cp "$W/tun.json" "$H/config.json"
  enhanced_paths() { TUN_UID=501; TUN_LABEL=com.enana.proxy.tun.501; TUN_ROOT="$W/staged-root"; TUN_PLIST="$W/staged.plist"; mkdir -p "$TUN_ROOT"; }
  enhanced_supported() { return 0; }
  clash() { printf '{"proxies":{}}'; }
  logs_rotate() { :; }
  printf '%s\n' 'pinned 1.12.0 0' > "$H/core-provenance"      # 6.1: 预检要求官方钉死版本的核心
  enhanced_admin() {                                          # 一条命令: 清空环境的 inband 形式; 命令里不能出现 lib/ 下的路径 (脚本和数据都随命令带进去)
    case $1 in *"/usr/bin/env -i PATH="*" inband "*) ;; *) echo "FAIL: not the inband form: ${1:0:160}"; exit 1 ;; esac
    case $1 in *"$LIB/"*) echo 'FAIL: a path under lib/ reached the privileged command'; exit 1 ;; esac
    : > "$TUN_ROOT/sing-box.log"
  }
  enhanced_start
  [ -L "$H/sing-box.log" ]
  rm "$H/sing-box.log"
)
echo 'PASS: actual launch stages helper outside protected source directories'
(
  unset ENANA_SKIP_PROBE
  nc() { return 1; }; dscacheutil() { :; }; clash() { printf '{"Answer":[]}'; }
  _b_probe() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }
  NETWORK_MODE=tun; _b_probes > "$W/probes-tun"
  NETWORK_MODE=system; _b_probes > "$W/probes-system"
  [ "$(awk -F'\t' '$2=="tun" {n++} END {print n+0}' "$W/probes-tun")" = 3 ]
  [ "$(awk -F'\t' '$2=="direct" {n++} END {print n+0}' "$W/probes-system")" = 3 ]
)
echo 'PASS: no-explicit-proxy diagnostics distinguish TUN capture from direct access'
# Self egress readiness must belong to OUR interface, not another VPN.
cp "$W/tun.json" "$H/config.json"
enhanced_loaded() { return 0; }
route() { echo 'interface: utun42'; }
ifconfig() { echo 'inet 172.19.0.1 netmask 0xfffffffc'; }
enhanced_ready
ifconfig() { echo 'inet 10.8.0.1 netmask 0xffffff00'; }
if enhanced_ready; then echo 'FAIL: another VPN counted as our TUN'; exit 1; fi
# Selector migration uses the API, with URL and JSON escaping kept separate.
printf '{"proxies":{"PIN":{"type":"Selector","now":"Fixed Exit"},"a/b":{"type":"Selector","now":"Other"},"AUTO":{"type":"URLTest","now":"Other"}}}' > "$W/selectors.json"
clash() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$W/selector-calls"; }
enhanced_restore_selectors "$W/selectors.json"
grep -q '/proxies/PIN.*"Fixed Exit"' "$W/selector-calls"
grep -q '/proxies/a%2Fb' "$W/selector-calls"
[ "$(wc -l < "$W/selector-calls" | tr -d ' ')" = 2 ]
echo 'PASS: PIN and other selectors preserved with independent URI/JSON escaping'
# TUN -> System must restore these same choices into the user's core cache.
cp "$W/system.json" "$H/config.json"
enhanced_paths() { TUN_PLIST="$W/daemon.plist"; TUN_ROOT="$W/root"; }
touch "$W/daemon.plist"
enhanced_loaded() { return 0; }
enhanced_stop() { echo stop >> "$W/switch-calls"; }
os_write_plists() { echo plist >> "$W/switch-calls"; return 1; }
os_system_service_start() { echo start >> "$W/switch-calls"; }
wait_port() { return 0; }
clash() { if [ "$1" = GET ]; then cat "$W/selectors.json"; else printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$W/switch-calls"; fi; }
os_service_start
[ "$(head -1 "$W/switch-calls")" = stop ]
grep -q '/proxies/PIN.*Fixed Exit' "$W/switch-calls"
echo 'PASS: switching back restores root PIN choice into System core'
# The user-core branch of os_service_start can run while NETWORK_MODE still says tun (the rollback of a failed transaction): the plists it rewrites
# must be written for System Proxy, or RunAtLoad / KeepAlive become false and the user core does not come back after a reboot or a crash.
(
  NETWORK_MODE=tun
  os_write_plists() { printf '%s\n' "${NETWORK_MODE:-}" > "$W/plist-mode"; return 1; }
  enhanced_loaded() { return 1; }
  os_service_start >/dev/null 2>&1
  [ "$(cat "$W/plist-mode")" = system ] || { echo "FAIL: the user core's plist was written for NETWORK_MODE=$(cat "$W/plist-mode")"; exit 1; }
  [ "$NETWORK_MODE" = tun ] || { echo 'FAIL: os_service_start changed NETWORK_MODE'; exit 1; }
) || exit 1
echo 'PASS: starting the user core writes its plist for System Proxy even while the setting still says TUN'

# A denied administrator request leaves a healthy old core alone.
cp "${SINGBOX:-$(type -P true)}" "$H/sing-box"
SB=${SINGBOX:-$(type -P true)}
cp "$W/system.json" "$H/config.json"
settings_set NETWORK_MODE tun
enhanced_loaded() { return 1; }
os_service_loaded() { return 0; }; os_service_pid() { echo 42; }; os_service_running() { return 0; }
os_service_restart() { echo restart >> "$W/denied-calls"; return 1; }
if apply_config; then echo 'FAIL: declined restart succeeded'; exit 1; else rc=$?; fi
[ "$rc" = 3 ]
cmp "$W/system.json" "$H/config.json"
[ "$(wc -l < "$W/denied-calls" | tr -d ' ')" = 1 ]
settings_set NETWORK_MODE system
load_settings || true
echo 'PASS: administrator cancellation restores config without a second restart/prompt'
# S2: a TUN refusal (root refused before changing anything) never switches the capture mode by itself. apply_config puts the previous configuration
# back and returns 5 with the reason; op_txn rolls the change back and reports why: a System -> TUN switch ends on System Proxy again, a change made
# in TUN mode stays on TUN. (With no root daemon running it used to switch to System Proxy and report success, so nobody learned TUN was refused.)
(
  job_step() { :; }; oplog() { :; }; sysproxy_off_if_core_down() { :; }
  _txn_end() { printf '%s|%s|%s\n' "$1" "$2" "${3:-}" > "$W/s2-end"; }
  STARTS=0; os_service_start() { STARTS=$((STARTS + 1)); return 0; }
  os_service_restart() { if enhanced_configured; then ENHANCED_REFUSED=1; ENHANCED_REFUSED_WHY=stage-extra; return 3; fi; return 0; }   # root refuses the TUN snapshot
  enhanced_loaded() { return 1; }                                   # no root daemon at all: exactly the case that used to switch modes
  cp "$W/system.json" "$H/config.json"; rm -f "$H/config.json.bak"; settings_set NETWORK_MODE system; load_settings || true
  if op_txn '切换流量接管模式' txn_settings NETWORK_MODE=tun >/dev/null 2>&1; then echo 'FAIL: S2: a refused System -> TUN switch reported success'; exit 1; fi
  load_settings || true
  [ "$NETWORK_MODE" = system ] || { echo "FAIL: S2: a refused System -> TUN switch did not end on System Proxy ($NETWORK_MODE)"; exit 1; }
  if enhanced_configured; then echo 'FAIL: S2: the refused TUN configuration was left in place'; exit 1; fi
  [ "$(cat "$W/s2-end")" = 'fail|TUN 没有启动 (stage-extra): 原因: stage-extra|5' ] || { echo "FAIL: S2: the refusal was not reported with its reason: $(cat "$W/s2-end")"; exit 1; }
  [ "$STARTS" = 0 ] || { echo "FAIL: S2: the refusal started a core by itself ($STARTS)"; exit 1; }
  # already on TUN: a TUN-mode change (an app policy) that root refuses keeps TUN and the running configuration, and rolls the policy back
  cp "$W/tun.json" "$H/config.json"; rm -f "$H/config.json.bak"; settings_set NETWORK_MODE tun; load_settings || true
  ovr_set app Gemini pin ack ''; ovr_sync || exit 1; before=$(cat "$H/overrides.tsv"); : > "$W/s2-end"
  if op_txn '修改应用/网站策略' txn_override app Gemini direct '' >/dev/null 2>&1; then echo 'FAIL: S2: a refused TUN-mode change reported success'; exit 1; fi
  load_settings || true
  [ "$NETWORK_MODE" = tun ] || { echo "FAIL: S2: a refused TUN-mode change switched the capture mode to $NETWORK_MODE"; exit 1; }
  cmp -s "$W/tun.json" "$H/config.json" || { echo 'FAIL: S2: the TUN configuration was not put back'; exit 1; }
  [ "$(cat "$H/overrides.tsv")" = "$before" ] || { echo 'FAIL: S2: the refused change was not rolled back'; exit 1; }
  [ "$(cat "$W/s2-end")" = 'fail|TUN 没有启动 (stage-extra): 原因: stage-extra|5' ] || { echo "FAIL: S2: the refusal was not reported with its reason: $(cat "$W/s2-end")"; exit 1; }
  [ "$STARTS" = 0 ] || { echo "FAIL: S2: the refusal started a core by itself ($STARTS)"; exit 1; }
  # a stray root daemon is still loaded while System Proxy is configured: after root refused the TUN install (the dialog was already used), the
  # rollback re-apply must not go on to stop that daemon - that is a second administrator dialog for one click; the user's next action stops it
  RESTARTS=0; os_service_restart() { if enhanced_configured; then ENHANCED_REFUSED=1; ENHANCED_REFUSED_WHY=stage-extra; return 3; fi; RESTARTS=$((RESTARTS + 1)); return 0; }
  enhanced_loaded() { return 0; }
  cp "$W/system.json" "$H/config.json"; rm -f "$H/config.json.bak"; settings_set NETWORK_MODE system; load_settings || true; : > "$W/s2-end"
  if op_txn '切换流量接管模式' txn_settings NETWORK_MODE=tun >/dev/null 2>&1; then echo 'FAIL: S2: a refused switch with a stray root daemon reported success'; exit 1; fi
  load_settings || true
  [ "$NETWORK_MODE" = system ] || { echo "FAIL: S2: a refused switch with a stray root daemon did not end on System Proxy ($NETWORK_MODE)"; exit 1; }
  [ "$RESTARTS" = 0 ] || { echo "FAIL: S2: the rollback re-apply restarted to stop the stray root daemon (a second dialog for one click): $RESTARTS"; exit 1; }
) || exit 1
settings_set NETWORK_MODE system; load_settings || true; cp "$W/system.json" "$H/config.json"; ovr_sync >/dev/null 2>&1 || true
echo 'PASS: a TUN refusal keeps the capture mode and the running configuration, rolls the change back and reports why (S2)'
# The refusal says "旧的 TUN 仍在运行" only when the root daemon is actually running, not when launchd merely still lists it (it exited / crashed).
(
  sysproxy_off_if_core_down() { :; }; warn() { :; }; ENHANCED_REFUSED_WHY=stage-extra
  cp "$W/system.json" "$H/config.json.bak"
  enhanced_loaded() { return 0; }; os_service_running() { return 1; }
  config_tun_refused || true
  [ "$TXN_ERR" = 'TUN 没有启动 (stage-extra): 原因: stage-extra' ] || { echo "FAIL: a loaded but not running daemon was reported as running: $TXN_ERR"; exit 1; }
  os_service_running() { return 0; }
  config_tun_refused || true
  [ "$TXN_ERR" = 'TUN 没有启动 (stage-extra): 原因: stage-extra; 旧的 TUN 仍在运行' ] || { echo "FAIL: a running daemon was not mentioned: $TXN_ERR"; exit 1; }
) || exit 1
echo 'PASS: a refusal mentions the old TUN only when its daemon is actually running'
# One click, one administrator dialog: after the user cancels it, apply_config's rollback restart and op_txn's rollback re-apply both need
# authorisation again (the old core is not healthy here), but nothing in the same operation asks again, and the result is reported as cancelled.
# The real os_service_restart / os_service_start / enhanced_admin run; only the staged install is a stand-in (one administrator call).
(
  eval "$(sed -n -e '/^os_service_restart()/,/^}/p' -e '/^os_service_start()/,/^}/p' "$LIB/os-darwin.sh")"
  enhanced_paths() { TUN_UID=501; TUN_LABEL=com.enana.proxy.tun.501; TUN_ROOT="$W/root"; TUN_PLIST="$W/daemon.plist"; }
  job_step() { :; }; oplog() { :; }; sysproxy_off_if_core_down() { :; }; tun_residual_clean() { :; }; proxy_sync_mode() { :; }
  core_mark_start() { :; }; core_restart_note() { :; }
  _txn_end() { printf '%s|%s|%s\n' "$1" "$2" "${3:-}" > "$W/cancel-end"; }
  DIALOGS=0
  sudo() { return 1; }                                               # no terminal and no passwordless sudo: the native dialog branch
  osascript() { DIALOGS=$((DIALOGS + 1)); echo 'execution error: User canceled. (-128)' >&2; return 1; }
  enhanced_start() { enhanced_admin '/bin/true install' > "$H/enhanced-check.log" 2>&1; }
  enhanced_restart_fast() { return 1; }; enhanced_loaded() { return 0; }; enhanced_ready() { return 0; }
  os_service_running() { return 1; }; wait_port() { return 1; }     # the old core is not healthy: apply_config's rollback restarts it
  cp "$W/tun.json" "$H/config.json"; rm -f "$H/config.json.bak"; settings_set NETWORK_MODE tun; load_settings || true
  ovr_set app Gemini pin ack ''; ovr_sync || exit 1; before=$(cat "$H/overrides.tsv")
  if op_txn '修改应用/网站策略' txn_override app Gemini direct '' </dev/null >/dev/null 2>&1; then echo 'FAIL: a cancelled authorisation reported success'; exit 1; fi
  [ "$DIALOGS" = 1 ] || { echo "FAIL: one cancelled click showed $DIALOGS administrator dialogs"; exit 1; }
  [ "$(cat "$W/cancel-end")" = 'fail|已取消管理员授权, 已撤销本次更改|3' ] || { echo "FAIL: a cancel was not reported as cancelled: $(cat "$W/cancel-end")"; exit 1; }
  [ "$(cat "$H/overrides.tsv")" = "$before" ] || { echo 'FAIL: the cancelled change was not rolled back'; exit 1; }
  cmp -s "$W/tun.json" "$H/config.json" || { echo 'FAIL: the configuration that was running was not put back'; exit 1; }
  # with the cancel remembered, the real enhanced_start stages nothing and enhanced_stop runs nothing (and does not record a stop): both return 7
  eval "$(sed -n -e '/^enhanced_start()/,/^}/p' -e '/^enhanced_stop()/,/^}/p' "$LIB/enhanced.sh")"
  mktemp() { echo STAGED >> "$W/cancel-calls"; command mktemp "$@"; }
  touch "$W/daemon.plist"; rm -f "$H/.enhanced-stopped" "$W/cancel-calls"
  rc=0; enhanced_start </dev/null >/dev/null 2>&1 || rc=$?
  [ "$rc:$DIALOGS:$(cat "$W/cancel-calls" 2>/dev/null)" = 7:1: ] || { echo "FAIL: enhanced_start after a cancel: rc:dialogs:calls = $rc:$DIALOGS:$(cat "$W/cancel-calls" 2>/dev/null)"; exit 1; }
  rc=0; enhanced_stop </dev/null >/dev/null 2>&1 || rc=$?
  [ "$rc:$DIALOGS" = 7:1 ] && [ ! -e "$H/.enhanced-stopped" ] || { echo "FAIL: enhanced_stop after a cancel: rc:dialogs = $rc:$DIALOGS, marker $(test -e "$H/.enhanced-stopped" && echo written || echo absent)"; exit 1; }
) || exit 1
settings_set NETWORK_MODE system; load_settings || true; cp "$W/system.json" "$H/config.json"; ovr_sync >/dev/null 2>&1 || true
echo 'PASS: after a cancelled administrator dialog nothing in the same operation asks again; the result is reported as cancelled'
# Core-affecting implementation changes change the snapshot fingerprint; policy-rule-only edits change only the rule-data fingerprint.
SB=${SINGBOX:-$(type -P true)}
before=$(enhanced_fingerprint)
saved_lib=$LIB; mkdir "$W/changed-lib"
cp "$LIB/enhanced.sh" "$LIB/enhanced-root.sh" "$W/changed-lib/"
LIB="$W/changed-lib"; [ "$before" = "$(enhanced_fingerprint)" ]
printf '\n# snapshot implementation update\n' >> "$LIB/enhanced.sh"
[ "$before" != "$(enhanced_fingerprint)" ]; LIB=$saved_lib
# Policy rule-sets (ovr-*.json) are synced to the root snapshot as data by the rules helper (no restart), so they have their own fingerprint.
before_ovr=$(enhanced_ovr_fingerprint)
printf 'app|Google Chrome|auto|ack\napp|Gemini|pin|ack\n' > "$H/overrides.tsv"
ovr_sync || exit 1
[ "$before" = "$(enhanced_fingerprint)" ]
[ "$before_ovr" != "$(enhanced_ovr_fingerprint)" ]
txn_override app Claude pin '' || exit 1
[ "$(ovr_get app Claude)" = pin ]
# Root deployment refusal must roll back both saved policy and generated rules.
job_step() { :; }; oplog() { :; }; _txn_end() { :; }
os_service_loaded() { return 1; }
ovr_sync || exit 1
old=$(cat "$H/overrides.tsv")
apply_config() { ovr_sync; return 3; }
if op_txn fixture txn_override app Gemini direct ''; then echo 'FAIL: failed deployment reported success'; exit 1; fi
[ "$(cat "$H/overrides.tsv")" = "$old" ]
grep -q Gemini "$H/rules/ovr-pin/ovr-pin.json"
echo 'PASS: rule-only fingerprint, PIN policy mutation and rejected privileged deployment rollback'
# Snapshot evidence: captured TCP, bypassing UDP, private callbacks, core egress.
cat > "$W/sockets" <<'DATA'
p100
cGemini
f1
PTCP
n192.168.1.2:55000->8.8.8.8:443
TST=ESTABLISHED
f2
PUDP
n192.168.1.2:55001->8.8.4.4:443
f3
PTCP
n127.0.0.1:55002->127.0.0.1:8080
TST=ESTABLISHED
f4
PTCP
n192.168.1.2:55004->100.64.1.2:443
TST=ESTABLISHED
p101
csing-box
f1
PTCP
n192.168.1.2:55003->1.1.1.1:443
TST=ESTABLISHED
DATA
printf '100 /Applications/Gemini.app/Contents/MacOS/Gemini\n101 /tmp/sing-box\n' > "$W/processes"
printf '{"connections":[{"metadata":{"network":"tcp","sourceIP":"192.168.1.2","sourcePort":"55000"}}]}' > "$W/connections"
perl "$LIB/network-diagnostics.pl" "$W/sockets" "$W/processes" "$W/connections" "$H/overrides.tsv" system > "$W/system.tsv"
perl "$LIB/network-diagnostics.pl" "$W/sockets" "$W/processes" "$W/connections" "$H/overrides.tsv" tun > "$W/tun.tsv"
python3 - "$W" <<'PY'
import csv,sys
w=sys.argv[1]; read=lambda f:list(csv.DictReader((l for l in open(w+'/'+f) if not l.startswith('#')),delimiter='\t'))
a,b=read('system.tsv'),read('tun.tsv')
assert len(a)==len(b)==2
assert [r['observation'] for r in a]==['captured','bypass-system-proxy']
assert [r['observation'] for r in b]==['captured','tun-unobserved']
assert all(r['policy']=='pin' and r['app']=='Gemini' for r in a)
assert all('8.8.*.*' in r['destination'] for r in a)
print('PASS: independent socket evidence, UDP bypass, callback/core exclusion, inconclusive TUN observation')
PY
printf '{}' > "$W/connections"
perl "$LIB/network-diagnostics.pl" "$W/sockets" "$W/processes" "$W/connections" "$H/overrides.tsv" system > "$W/unavailable.tsv"
! grep -q bypass-system-proxy "$W/unavailable.tsv"
grep -q core-api-unavailable "$W/unavailable.tsv"
echo 'PASS: unavailable controller does not become false bypass evidence'
# Exercise the actual endpoint function: a queued privileged scan must neither
# mutate files inline nor append a second JSON response after returning its job.
python3 - "$LIB/api.sh" <<'PY'
import pathlib,subprocess,sys
s=pathlib.Path(sys.argv[1]).read_text()
f=s[s.index('ep_apps_scan() {'):]; f=f[:f.index('\n}')+2]
stub='''NETWORK_MODE=tun; APPLY_STEPS=test
job_spawn() { printf test-job; }
okj() { printf '{"ok":true,%s}\\n' "$1"; }
lock_take() { echo INLINE_SCAN_ERROR; }
apps_scan() { echo INLINE_SCAN_ERROR; }
apps_icons() { :; }
apps_resp() { echo SECOND_RESPONSE_ERROR; }
'''
def run(case):
    r=subprocess.run(['/bin/bash','-c',stub+case+f+'\nep_apps_scan\n'],capture_output=True,text=True,check=True)
    return r.stdout
# Manual scan (no background flag) always delegates; the background check is never consulted.
assert run("qp() { :; }\napps_scan_bg() { echo BG_CHECKED; return 1; }\n")=='{"ok":true,"job":"test-job"}\n'
# Automatic scan that would change rules or overrides still delegates to the apply job.
assert run("qp() { echo 1; }\napps_scan_bg() { return 0; }\n")=='{"ok":true,"job":"test-job"}\n'
# Automatic scan with no change returns the current list and starts no job.
out=run("qp() { echo 1; }\napps_scan_bg() { return 1; }\napps_resp() { echo LIST; }\n")
assert out=='LIST\n',out
# A change that needs administrator approval is recorded as pending by apps_scan_bg: no job, the list (with its pending record) is returned.
out=run("qp() { echo 1; }\napps_scan_bg() { return 2; }\napps_resp() { echo LIST; }\n")
assert out=='LIST\n',out
# The automatic job that does start runs as OP_WHO=auto (the operation log shows it as automatic, not as the dashboard).
out=run("OP_WHO=dashboard\nqp() { echo 1; }\napps_scan_bg() { return 0; }\njob_spawn() { printf \"who=$OP_WHO\"; }\n")
assert out=='{"ok":true,"job":"who=auto"}\n',out
# System Proxy mode scans inline (no administrator approval needed) and drops any pending record that TUN left behind (F1).
out=run("NETWORK_MODE=system\nqp() { :; }\nlock_take() { return 0; }\napps_scan() { :; }\napps_pending_clear() { echo CLEARED; }\napps_resp() { echo LIST; }\n")
assert out=='CLEARED\nLIST\n',out
print('PASS: Enhanced scan endpoint delegates once without inline policy mutation; automatic scans without changes return the list without a job')
PY
# POST /api/proxy (the real ep_proxy and _proxy_start_needs_admin): turning the master switch on may have to start the core first. When that start
# needs administrator authorisation (TUN configured, or the root daemon still loaded / not idle) the request must not sit behind the dialog (the
# dashboard gives up after 25 s): it returns a job at once. Every other start, and every request with the core running, stays immediate.
python3 - "$LIB/api.sh" "$W" <<'PY'
import os,pathlib,subprocess,sys
s=pathlib.Path(sys.argv[1]).read_text(encoding='utf-8'); w=sys.argv[2]
i=s.index('_proxy_start_needs_admin() {'); need=s[i:s.index('\n',i)+1]
i=s.index('ep_proxy() {'); ep=s[i:s.index('\n}',i)+2]
stub='''PROXY_MODE=auto; PORT=1
fp() { case $1 in on) printf '%s' "$ON" ;; mode) printf '%s' "$MODE" ;; esac; }
fail() { printf 'FAIL:%s\\n' "$2"; exit 0; }
okj() { printf '{"ok":true,%s}\\n' "$1"; }
job_spawn() { printf '%s|%s|%s|%s' "$1" "$2" "$3" "$4" > "$OUT.spawn"; printf proxy-job; }
os_service_running() { return "$RUNNING"; }
os_service_start() { echo START >> "$OUT.calls"; return 0; }
wait_port() { return 0; }; enhanced_ready() { return 0; }
enhanced_configured() { return "$TUN"; }; enhanced_loaded() { return "$LOADED"; }; enhanced_paths() { :; }; enhanced_idle() { return "$IDLE"; }
proxy_switch() { echo SWITCH >> "$OUT.calls"; PROXY_SWITCH_JSON='"enabled":true,"mode":"auto"'; }
'''
plist=os.path.join(w,'proxy-test.plist'); open(plist,'w').close()
def run(n, **kw):
    out=os.path.join(w,'ep-proxy-%d'%n)
    env=dict(PATH=os.environ['PATH'], OUT=out, ON='1', MODE='', PROXY_ENABLED='0', RUNNING='1', TUN='1', LOADED='1', IDLE='0', TUN_PLIST=os.path.join(w,'missing.plist'))
    env.update(kw)
    r=subprocess.run(['/bin/bash','-c',stub+need+ep+'\nep_proxy\n'],capture_output=True,text=True,encoding='utf-8',check=True,env=env)
    rd=lambda x: open(out+x,encoding='utf-8').read() if os.path.exists(out+x) else ''
    return r.stdout, rd('.spawn'), rd('.calls')
job=('{"ok":true,"job":"proxy-job"}\n','proxy|启动代理服务|开启代理|1|','')
now=('{"ok":true,"enabled":true,"mode":"auto"}\n','','START\nSWITCH\n')
assert run(1,TUN='0')==job, run(1,TUN='0')                                           # TUN configured, core not running: the start installs the root core
assert run(2)==now, run(2)                                                           # System Proxy, no root daemon: the user's own core starts inline
assert run(3,LOADED='0')==job, run(3,LOADED='0')                                     # System Proxy but the root daemon is still loaded: stopping it needs authorisation
assert run(4,TUN_PLIST=plist,IDLE='1')==job                                          # its plist is there and it is not idle (unloaded but still enabled): same
assert run(5,TUN_PLIST=plist,IDLE='0')==now                                          # ...idle (stopped and disabled): no authorisation, inline
assert run(6,TUN='0',RUNNING='0')==('{"ok":true,"enabled":true,"mode":"auto"}\n','','SWITCH\n')    # core already running: no start, no job
assert run(7,TUN='0',ON='',MODE='global',PROXY_ENABLED='1')==('{"ok":true,"job":"proxy-job"}\n','proxy|启动代理服务|切换代理模式||global','')   # mode change while on
assert run(8,TUN='0',ON='0')==('{"ok":true,"enabled":true,"mode":"auto"}\n','','SWITCH\n')        # turning off never starts anything
print('PASS: /api/proxy hands a start that needs administrator rights to a job and keeps every other request immediate')
PY
# The job behind it (op_proxy) and the switch both paths share (proxy_switch). The job starts the core (the administrator dialog is fine here: the
# dashboard follows the job), reports a cancelled dialog as cancelled, and its result is the usual /api/proxy response.
(
  H="$W/proxyh"; mkdir -p "$H"
  job_step() { :; }; job_ok() { printf 'ok|%s|%s\n' "$1" "$2" > "$W/proxy-job"; }; job_fail() { printf 'fail|%s\n' "$1" > "$W/proxy-job"; }
  os_service_running() { return 1; }; wait_port() { return 0; }; enhanced_ready() { return 0; }
  proxy_switch() { printf 'switch|%s|%s|%s|%s\n' "$@" >> "$W/proxy-calls"; PROXY_SWITCH_JSON='"enabled":true,"mode":"global"'; }
  rm -f "$W/proxy-calls"
  os_service_start() { ENHANCED_ADMIN_ERR=cancelled; return 1; }
  op_proxy 1 '' || true
  [ "$(cat "$W/proxy-job")" = 'fail|已取消管理员授权, 代理没有开启' ] && [ ! -e "$W/proxy-calls" ] || { echo "FAIL: op_proxy after a cancelled dialog: $(cat "$W/proxy-job")"; exit 1; }
  [ ! -d "$H/.apply.lock" ] || { echo 'FAIL: op_proxy left the apply lock behind'; exit 1; }
  os_service_start() { ENHANCED_ADMIN_ERR=failed; return 1; }
  op_proxy 1 '' || true
  [ "$(cat "$W/proxy-job")" = 'fail|代理服务没有运行, 启动也失败了 (运行 enana doctor 查看原因)' ] || { echo "FAIL: op_proxy after a failed start: $(cat "$W/proxy-job")"; exit 1; }
  os_service_start() { ENHANCED_REFUSED=1; ENHANCED_REFUSED_WHY=preflight-core-unpinned; return 6; }      # TUN refused before any dialog: the job says why
  op_proxy 1 '' || true
  [ "$(cat "$W/proxy-job")" = 'fail|TUN 没有启动 (preflight-core-unpinned), 代理没有开启' ] || { echo "FAIL: op_proxy did not give the TUN refusal reason: $(cat "$W/proxy-job")"; exit 1; }
  os_service_start() { return 0; }
  PROXY_ENABLED=0; PROXY_MODE=auto; op_proxy 1 global
  [ "$(cat "$W/proxy-job")" = 'ok|代理已开启|{"enabled":true,"mode":"global"}' ] && [ "$(cat "$W/proxy-calls")" = 'switch|1|global|0|auto' ] || { echo "FAIL: op_proxy success: $(cat "$W/proxy-job") / $(cat "$W/proxy-calls")"; exit 1; }
  op_proxy 2 '' || true
  [ "$(cat "$W/proxy-job")" = 'fail|参数无效' ] || { echo "FAIL: op_proxy accepted on=2: $(cat "$W/proxy-job")"; exit 1; }
  # proxy_switch itself (the real one): the same response the endpoint always gave; the system proxy only follows in System Proxy mode
  eval "$(sed -n '/^proxy_switch() {/,/^}/p' "$LIB/ops.sh")"
  oplog() { :; }; clash() { :; }; switch_note() { :; }; NETWORK_MODE=system
  os_sysproxy_ok() { return 0; }
  PROXY_ENABLED=0; proxy_switch 1 '' 0 auto
  [ "$PROXY_SWITCH_JSON" = '"enabled":true,"mode":"auto","sysproxy":{"state":"on"}' ] || { echo "FAIL: proxy_switch (system proxy on): $PROXY_SWITCH_JSON"; exit 1; }
  os_sysproxy_ok() { return 1; }; os_sysproxy_foreign() { echo Wi-Fi; }
  PROXY_ENABLED=0; proxy_switch 1 '' 0 auto
  [ "$PROXY_SWITCH_JSON" = '"enabled":true,"mode":"auto","sysproxy":{"state":"foreign"}' ] || { echo "FAIL: proxy_switch (foreign proxy): $PROXY_SWITCH_JSON"; exit 1; }
  os_sysproxy_foreign() { :; }; job_spawn() { printf sysproxy-9; }
  PROXY_ENABLED=0; proxy_switch 1 '' 0 auto
  [ "$PROXY_SWITCH_JSON" = '"enabled":true,"mode":"auto","sysproxy":{"state":"pending","job":"sysproxy-9"}' ] || { echo "FAIL: proxy_switch (pending): $PROXY_SWITCH_JSON"; exit 1; }
  NETWORK_MODE=tun; PROXY_ENABLED=0; proxy_switch 1 global 0 auto
  [ "$PROXY_SWITCH_JSON" = '"enabled":true,"mode":"global"' ] || { echo "FAIL: proxy_switch (TUN): $PROXY_SWITCH_JSON"; exit 1; }
  NETWORK_MODE=system; proxy_switch 0 '' 1 global
  [ "$PROXY_SWITCH_JSON" = '"enabled":false,"mode":"global"' ] || { echo "FAIL: proxy_switch (off): $PROXY_SWITCH_JSON"; exit 1; }
) || exit 1
echo 'PASS: the proxy job starts the core, reports a cancelled dialog as cancelled, and returns the usual response'
# Shell and AppleScript quoting test with actual special characters.
v="space and ' quote \$(not_a_command)"; q=$(enhanced_quote "$v")
[ "$(eval "printf '%s' $q")" = "$v" ]
echo 'PASS: privileged argument shell quoting'
# Stopping a daemon that is not loaded must not ask for administrator rights. `stop` never deletes the plist (only `remove` does), so after a single TUN
# session every System Proxy start / stop used to run an admin `stop` on an already-stopped daemon. The REAL functions are re-sourced here (the
# fixtures above replaced them with stubs); only the privileged call, launchd and the paths are fakes.
(
  eval "$(sed -n -e '/^enhanced_idle()/,/^}/p' -e '/^enhanced_stop()/,/^}/p' -e '/^enhanced_remove()/,/^}/p' "$LIB/enhanced.sh")"
  H="$W/stoph"; mkdir -p "$H"
  TUN_LABEL=com.enana.proxy.tun.501; TUN_UID=501; TUN_ROOT="$W/stop-root"; TUN_PLIST="$W/stop.plist"
  enhanced_paths() { :; }
  ADMIN=0; ADMIN_RC=0; ADMIN_LOG="$W/admin-calls"; : > "$ADMIN_LOG"
  # like the real root `stop`: a successful stop unloads the daemon (STOP_LEAVES_LOADED=1: launchd still lists it afterwards)
  enhanced_admin() { ADMIN=$((ADMIN + 1)); printf '%s\n' "$*" >> "$ADMIN_LOG"; [ "$ADMIN_RC" != 0 ] || [ "${STOP_LEAVES_LOADED:-0}" = 1 ] || LOADED=0; return "$ADMIN_RC"; }
  LOADED=0; enhanced_loaded() { [ "$LOADED" = 1 ]; }
  DISABLED=''                                              # launchctl print-disabled system 的输出: 空 = 查不到 / 没有这一项
  launchctl() { [ "$1" = print-disabled ] || return 1; printf 'disabled services = {\n\t"com.apple.example" => disabled\n'; [ -z "$DISABLED" ] || printf '\t"%s" => %s\n' "$TUN_LABEL" "$DISABLED"; printf '}\n'; }
  reset_stop() { ADMIN=0; ADMIN_RC=0; LOADED=0; DISABLED=''; rm -f "$H/.enhanced-stopped"; : > "$TUN_PLIST"; : > "$ADMIN_LOG"; }

  reset_stop; rm -f "$TUN_PLIST"
  enhanced_stop; rc=$?; [ "$rc:$ADMIN" = 0:0 ] || { echo "FAIL: no plist should be a no-op ($rc:$ADMIN)"; exit 1; }
  reset_stop; LOADED=1
  enhanced_stop; rc=$?; [ "$rc:$ADMIN" = 0:1 ] || { echo "FAIL: a loaded daemon must be stopped with one admin call ($rc:$ADMIN)"; exit 1; }
  grep -q "'stop' '501'" "$ADMIN_LOG" || { echo 'FAIL: wrong privileged command'; cat "$ADMIN_LOG"; exit 1; }      # 没有 root 副本: inband 形式; 有副本: root 形式 (见 tests/tun-service.sh)
  # ...and from then on (the daemon is unloaded, the plist is still there) there is nothing left to stop
  LOADED=0; enhanced_stop; enhanced_stop
  [ "$ADMIN" = 1 ] || { echo "FAIL: stopping an already-stopped daemon asked for administrator rights again ($ADMIN calls)"; exit 1; }
  # unloaded but nothing known about it (daemon stopped by an older enana, no marker, launchd cannot tell): one authorised stop, then never again
  reset_stop
  enhanced_stop; enhanced_stop; enhanced_stop
  [ "$ADMIN" = 1 ] || { echo "FAIL: unknown stopped state should cost exactly one administrator call ($ADMIN)"; exit 1; }
  # launchd says the job is disabled (what `stop` does): no call at all, even without a marker
  for d in disabled true; do
    reset_stop; DISABLED=$d
    enhanced_stop; [ "$ADMIN" = 0 ] || { echo "FAIL: a disabled, unloaded job needs no administrator call ($d)"; exit 1; }
  done
  # unloaded but still ENABLED (somebody booted it out by hand): it would come back at the next boot, so `stop` must run and disable it
  for d in enabled false; do
    reset_stop; DISABLED=$d
    enhanced_stop; [ "$ADMIN" = 1 ] || { echo "FAIL: an unloaded but enabled job must still be stopped (disabled) ($d)"; exit 1; }
  done
  # a stale marker never hides a daemon that is loaded again
  reset_stop; : > "$H/.enhanced-stopped"; LOADED=1
  enhanced_stop; [ "$ADMIN" = 1 ] || { echo 'FAIL: stale marker hid a loaded daemon'; exit 1; }
  # root reported the stop as done but the daemon is still loaded: no "stopped" marker (it would hide the daemon once it is unloaded but still enabled)
  reset_stop; LOADED=1; STOP_LEAVES_LOADED=1
  enhanced_stop; rc=$?
  [ "$rc:$ADMIN" = 0:1 ] && [ ! -e "$H/.enhanced-stopped" ] || { echo "FAIL: a stop that left the daemon loaded was recorded as stopped (rc:admin $rc:$ADMIN)"; exit 1; }
  enhanced_stop; [ "$ADMIN" = 2 ] || { echo "FAIL: a daemon still loaded after a stop must be stopped again ($ADMIN calls)"; exit 1; }
  STOP_LEAVES_LOADED=0
  # a failed / cancelled authorisation is reported and not remembered
  reset_stop; ADMIN_RC=1
  if enhanced_stop; then echo 'FAIL: cancelled authorisation reported as success'; exit 1; fi
  [ ! -e "$H/.enhanced-stopped" ] || { echo 'FAIL: marker written after a failed stop'; exit 1; }
  ADMIN_RC=0; LOADED=0; enhanced_stop; [ "$ADMIN" = 2 ] || { echo 'FAIL: a failed stop must be retried'; exit 1; }
  # remove clears the marker
  : > "$H/.enhanced-stopped"; enhanced_remove; [ ! -e "$H/.enhanced-stopped" ] || { echo 'FAIL: remove left the marker'; exit 1; }
  # end to end through the real os_service_start / os_service_stop (System Proxy start after a TUN session): no administrator call
  reset_stop; : > "$H/.enhanced-stopped"
  enhanced_system_log() { :; }; os_write_plists() { return 1; }; STARTS=0; os_system_service_start() { STARTS=$((STARTS + 1)); }
  os_system_service_stop() { :; }
  os_service_start; rc=$?
  [ "$rc:$ADMIN:$STARTS" = 0:0:1 ] || { echo "FAIL: System Proxy start after a stopped TUN daemon: rc:admin:starts = $rc:$ADMIN:$STARTS"; exit 1; }
  os_service_stop; [ "$ADMIN" = 0 ] || { echo 'FAIL: System Proxy stop prompted for administrator rights'; exit 1; }
)
echo 'PASS: enhanced_stop asks for administrator rights only when a daemon is loaded or could still come back'
# A successful root install forgets the stop marker and records the fingerprint, the policy fingerprint and the baked-in mode.
(
  SB=${SINGBOX:-$(type -P true)}; cp "$W/system.json" "$H/config.json"
  : > "$H/.enhanced-stopped"; rm -f "$H/.enhanced-fingerprint" "$H/.enhanced-ovr-fingerprint" "$H/.enhanced-mode"
  PROXY_ENABLED=1; PROXY_MODE=global
  enhanced_record_install
  [ ! -e "$H/.enhanced-stopped" ] && [ "$(cat "$H/.enhanced-fingerprint")" = "$(enhanced_fingerprint)" ] && [ "$(cat "$H/.enhanced-ovr-fingerprint")" = "$(enhanced_ovr_fingerprint)" ] && [ "$(cat "$H/.enhanced-mode")" = Global ]
)
echo 'PASS: a root install records its fingerprints and mode and clears the stop marker'
