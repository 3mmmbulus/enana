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
assert 'Gemini' in open(h+'/rules/ovr-apppin.json').read()
for b in ['ovr-browserdirect','ovr-browserauto','ovr-browserpin','ovr-browserpinauto','ovr-browserpin-2']:
 assert idx(lambda a:a.get('outbound')=='svc-claude') < idx(lambda a:a.get('rule_set')==[b])
 assert idx(lambda a:a.get('rule_set')==['ovr-pin']) < idx(lambda a:a.get('rule_set')==[b])
assert 'Google Chrome' in open(h+'/rules/ovr-browserdirect.json').read()
assert 'Google Chrome' not in open(h+'/rules/ovr-appdirect.json').read()
assert 'Terminal' in open(h+'/rules/ovr-auto.json').read()
for app in ['Gemini','Claude','ChatGPT']:
 assert app in open(h+'/rules/ovr-pin.json').read()
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
  PORT=7890; UI_PORT=9090; API_PORT=9091; SPEED_PORT=7892
  os_service_loaded() { return 0; }
  launchctl() { [ "$1" = print ] && [ "$2" = "$GUI/$LABEL_API" ]; }
  port_busy() { return 0; }
  port_random() { echo 49999; }
  settings_set() { echo 'FAIL: root core ports were reassigned'; exit 1; }
  set_ui_url() { :; }
  pick_ports
  [ "$PORT:$UI_PORT:$API_PORT:$SPEED_PORT" = 7890:9090:9091:7892 ]
)
echo 'PASS: installer preserves ports owned by the root TUN service'
(
  SB=${SINGBOX:-$(type -P true)}
  cp "$W/tun.json" "$H/config.json"
  enhanced_paths() { TUN_UID=501; TUN_ROOT="$W/staged-root"; mkdir -p "$TUN_ROOT"; }
  enhanced_supported() { return 0; }
  clash() { printf '{"proxies":{}}'; }
  logs_rotate() { :; }
  enhanced_admin() {
    [ "$2" = "$5/enhanced-root.sh" ]
    cmp "$LIB/enhanced-root.sh" "$2"
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
grep -q Gemini "$H/rules/ovr-pin.json"
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
apps_resp() { echo SECOND_RESPONSE_ERROR; }
'''
r=subprocess.run(['/bin/bash','-c',stub+f+'\nep_apps_scan\n'],capture_output=True,text=True,check=True)
assert r.stdout=='{"ok":true,"job":"test-job"}\n',r.stdout
print('PASS: Enhanced scan endpoint delegates once without inline policy mutation')
PY
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
  enhanced_admin() { ADMIN=$((ADMIN + 1)); printf '%s\n' "$*" >> "$ADMIN_LOG"; return "$ADMIN_RC"; }
  LOADED=0; enhanced_loaded() { [ "$LOADED" = 1 ]; }
  DISABLED=''                                              # launchctl print-disabled system 的输出: 空 = 查不到 / 没有这一项
  launchctl() { [ "$1" = print-disabled ] || return 1; printf 'disabled services = {\n\t"com.apple.example" => disabled\n'; [ -z "$DISABLED" ] || printf '\t"%s" => %s\n' "$TUN_LABEL" "$DISABLED"; printf '}\n'; }
  reset_stop() { ADMIN=0; ADMIN_RC=0; LOADED=0; DISABLED=''; rm -f "$H/.enhanced-stopped"; : > "$TUN_PLIST"; : > "$ADMIN_LOG"; }

  reset_stop; rm -f "$TUN_PLIST"
  enhanced_stop; rc=$?; [ "$rc:$ADMIN" = 0:0 ] || { echo "FAIL: no plist should be a no-op ($rc:$ADMIN)"; exit 1; }
  reset_stop; LOADED=1
  enhanced_stop; rc=$?; [ "$rc:$ADMIN" = 0:1 ] || { echo "FAIL: a loaded daemon must be stopped with one admin call ($rc:$ADMIN)"; exit 1; }
  grep -q "enhanced-root.sh stop 501" "$ADMIN_LOG" || { echo 'FAIL: wrong privileged command'; cat "$ADMIN_LOG"; exit 1; }
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
