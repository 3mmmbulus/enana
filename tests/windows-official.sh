#!/bin/bash
# Real Windows runtime; isolated fake Pro session, no remote credentials or UAC.
set -u
repo=$(cd "$(dirname "$0")/.." && pwd -P)
. "$repo/lib/common.sh"; init_paths "$repo/install.sh"
for f in i18n jobs servers apps sites fetch os enhanced auth device session cloud dns config plan official snapshot; do . "$LIB/$f.sh"; done
[ "${ENANA_PLATFORM:-}" = windows ] || exit 2
. "$LIB/enhanced-windows.sh"; load_settings
# Use the actual installed runtime paths; the native suite owns this fresh home.
for file in official.json official.roles.json session cloud.token; do [ ! -e "$H/$file" ] || { echo 'REFUSING: account data exists in acceptance home'; exit 2; }; done
trap 'rm -f "$H/official.json" "$H/session" "$H/config.json.new"' EXIT
printf '%s\n' fixturetestsess > "$H/session"
perl -MJSON::PP -e 'print encode_json({ok=>JSON::PP::true,entitled=>JSON::PP::true,email_verified=>JSON::PP::true,user_id=>"fixturetestuser",session_id=>"fixturetestsess",expires_at=>time+3600,nodes=>[{label=>"Official US",outbound=>{type=>"http",tag=>"enana-official-abcdefghijklmno Official US",server=>"proxy.example.com",server_port=>443,password=>"fixture-private",tls=>{enabled=>JSON::PP::true}}}]})' > "$H/official.json"
mkdir -p "$H/rules"
for mode in system tun; do
 NETWORK_MODE=$mode
 gen_config --no-rulesets || exit 1
 MSYS2_ARG_CONV_EXCL='*' "$SB" check -c "$(cygpath -w "$H/config.json.new")" || exit 1
 grep -q '"tag":"enana-official-' "$H/config.json.new" || exit 1
 printf 'PASS: Windows core accepts official nodes in %s mode\n' "$mode"
done
snap_build all | grep -q 'fixture-private' && exit 1
session_clear
[ ! -e "$H/official.json" ] || exit 1
printf 'PASS: Windows official credentials excluded from backup and removed on logout\n'
