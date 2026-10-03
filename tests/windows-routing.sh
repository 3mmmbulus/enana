#!/bin/bash
# Exercise the REAL shared override/config generator using Windows app paths.
# All OS operations are replaced locally; no host routes/proxies are touched.
set -u
repo=$(cd "$(dirname "$0")/.." && pwd -P)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
export ENANA_HOME="$work/home" ENANA_LANG=en
mkdir -p "$ENANA_HOME/rules"
. "$repo/lib/common.sh"; init_paths "$repo/install.sh"
for f in i18n jobs servers apps sites fetch enhanced auth dns config update; do . "$LIB/$f.sh"; done
load_settings; ENANA_PLATFORM=windows
set -e
windows_node() {
  # Keep the simulated home prefix literal, as the production adapter does.
  # On a native Windows runner only the real input filename is converted;
  # `command cygpath` bypasses the destination stub below.
  local helper="$repo/windows/helper.js" cmd=$1 file; shift
  file=$1; shift
  if type -P cygpath >/dev/null 2>&1; then
    helper=$(command cygpath -m "$helper"); file=$(command cygpath -m "$file")
  fi
  MSYS2_ARG_CONV_EXCL='*' node "$helper" "$cmd" "$file" "$@"
}
app_is_browser() { case $1 in *chrome.exe) return 0 ;; *) return 1 ;; esac; }
core_version() { echo 1.14.2; }
enhanced_paths() { TUN_UID=S-1-5-21-1-2-3-1001; }
cygpath() { [ "$1" = -m ] && printf 'C:/Users/Test User/enana'; }
printf 'app|Google Chrome|auto|ack\napp|Claude|pin|ack\napp|Gemini|pin|ack\napp|ChatGPT|pin|ack\nsite|claude.ai|pin|ack\n' > "$H/overrides.tsv"
printf 'Google Chrome\tC:/Program Files/Google/Chrome/Application/chrome.exe\nClaude\tC:/Users/Test User/AppData/Local/AnthropicClaude/app-1.2.3/Claude.exe\nGemini\tC:/Program Files/Gemini/Gemini.exe\nChatGPT\tC:/Program Files/WindowsApps/OpenAI.ChatGPT_1.0/ChatGPT.exe\n' > "$H/.apps.now"
printf '%s\n' '{"role":"pin","outbound":{"type":"socks","tag":"Tokyo","server":"127.0.0.1","server_port":1}}' > "$H/servers.jsonl"
ovr_sync || { echo 'Shared override generation failed' >&2; exit 1; }
NETWORK_MODE=system; gen_config --no-rulesets || exit 1
cp "$H/config.json.new" "$work/system.json"
NETWORK_MODE=tun; gen_config --no-rulesets || exit 1
node - "$H" "$work/system.json" <<'JS'
const fs=require('fs'),assert=require('assert'),[home,system]=process.argv.slice(2);
const s=JSON.parse(fs.readFileSync(system)),j=JSON.parse(fs.readFileSync(home+'/config.json.new'));
assert(!s.inbounds.some(b=>b.type==='tun'));const tun=j.inbounds.find(b=>b.type==='tun');assert(tun.auto_route&&tun.strict_route);assert.equal(tun.interface_name,'enana-1001');
for(const p of ['127.0.0.0/8','10.0.0.0/8','192.168.0.0/16','::1/128','fc00::/7'])assert(tun.route_exclude_address.includes(p));assert(j.route.auto_detect_interface&&j.route.find_process);
assert(j.route.rule_set.every(r=>r.path.startsWith('C:/Users/Test User/enana/')));
const rules=j.route.rules,idx=rs=>rules.findIndex(r=>(r.rule_set||[]).includes(rs));assert(idx('ovr-apppin')<idx('ovr-pin'));assert(idx('ovr-pin')<idx('ovr-browserauto'));
const app=JSON.parse(fs.readFileSync(home+'/rules/ovr-apppin.json')).rules.flatMap(r=>r.process_path_regex||[]);
for(const exe of ['C:/Program Files/Gemini/helper.exe','C:/Program Files/WindowsApps/OpenAI.ChatGPT_1.0/ChatGPT.exe','C:/Users/Test User/AppData/Local/AnthropicClaude/app-2.0/helper.exe'])assert(app.some(rx=>new RegExp(rx.slice(4),'i').test(exe)));
assert(!app.some(rx=>new RegExp(rx.slice(4),'i').test('C:/Program Files/Unrelated/Other.exe')));
console.log('Windows shared routing, PIN helpers, browser precedence, dual-stack exclusions and native paths passed.');
JS
# The Windows release channel must not consult a macOS VERSION or advertise an
# unreviewed upstream core that the privileged snapshot cannot accept.
mkdir -p "$H/windows"; cp "$repo/windows/runtime-pins.json" "$H/windows/runtime-pins.json"
_update_get() {
  case $1 in
    windows-manifest.json) printf '%s\n' '{"platform":"windows","version":"2.3.1","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":123,"url":"/dl/enana-2.3.1-windows.zip"}' > "$3"; "$2" "$3" ;;
    CHANGELOG.md) return 1 ;;
    *) echo "Wrong platform update source: $1" >&2; exit 1 ;;
  esac
}
core_latest_version() { echo 'Unreviewed upstream core queried' >&2; exit 1; }
update_check force || exit 1
node - "$H/update.json" <<'JS'
const fs=require('fs'),assert=require('assert');const j=JSON.parse(fs.readFileSync(process.argv[2]));assert.equal(j.latest,'2.3.1');assert.equal(j.core_latest,'1.14.2');console.log('Windows update channel and reviewed core version passed.');
JS
