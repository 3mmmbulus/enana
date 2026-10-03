#!/bin/bash
# Native Windows CI only: generate/check both modes without activating TUN,
# modifying saved settings or invoking a privileged helper.
set -u
repo=$(cd "$(dirname "$0")/.." && pwd -P)
. "$repo/lib/common.sh"; init_paths "$repo/install.sh"
for f in i18n jobs servers apps sites fetch os enhanced auth dns config; do . "$LIB/$f.sh"; done
[ "${ENANA_PLATFORM:-}" = windows ] || exit 2
. "$LIB/enhanced-windows.sh"; load_settings
trap 'rm -f "$H/config.json.new"' EXIT
for mode in system tun; do
  NETWORK_MODE=$mode
  gen_config --no-rulesets || exit 1
  MSYS2_ARG_CONV_EXCL='*' "$SB" check -c "$(cygpath -w "$H/config.json.new")" || exit 1
  printf 'PASS: native Windows core accepts %s configuration\n' "$mode"
done
