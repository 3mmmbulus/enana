#!/bin/bash
# Execute the privileged helper only after replacing its fixed Library paths in
# a TEMPORARY COPY. All privileged/OS commands are fakes; never calls sudo.
set -eu
R=$(cd "$(dirname "$0")/.." && pwd -P)
W=$(mktemp -d /tmp/enana-root-test.XXXXXX); trap 'rm -rf "$W"' EXIT
export FIXTURE="$W"; mkdir -p "$W/bin" "$W/stage/rules"
python3 - "$R" "$W" <<'PY'
import sys
r,w=sys.argv[1:]; s=open(r+'/lib/enhanced-root.sh').read()
s=s.replace('root="/Library/Application Support/enana-$uid"','root="'+w+'/runtime"')
s=s.replace('plist="/Library/LaunchDaemons/$label.plist"','plist="'+w+'/daemon.plist"')
open(w+'/helper.sh','w').write(s)
PY
for c in chown sleep; do printf '#!/bin/sh\nexit 0\n' > "$W/bin/$c"; done
printf '#!/bin/sh\necho 0\n' > "$W/bin/id"
printf '#!/bin/sh\necho 0\n' > "$W/bin/stat"
printf '#!/bin/sh\necho "interface: utun42"\n' > "$W/bin/route"
printf '#!/bin/sh\necho "inet 172.19.0.1 netmask 0xfffffffc"\n' > "$W/bin/ifconfig"
cat > "$W/bin/launchctl" <<'MOCK'
#!/bin/sh
echo "$*" >> "$FIXTURE/calls"
case $1 in
 print) echo 'pid = 100'; exit 0 ;;
 bootstrap) if [ -f "$FIXTURE/fail-bootstrap" ]; then rm "$FIXTURE/fail-bootstrap"; exit 1; fi ;;
esac
exit 0
MOCK
cat > "$W/stage/sing-box" <<'MOCK'
#!/bin/sh
[ "$1" = check ]
MOCK
chmod +x "$W/bin/"* "$W/stage/sing-box"
export PATH="$W/bin:$PATH"
printf '{"snapshot":"first"}\n' > "$W/stage/config.json"
printf '{}\n' > "$W/stage/rules/one.json"
bash "$W/helper.sh" install 501 "$W/stage" com.enana.proxy 1
cmp "$W/stage/config.json" "$W/runtime/config.json"
printf '{"snapshot":"second"}\n' > "$W/stage/config.json"
touch "$W/fail-bootstrap"
if bash "$W/helper.sh" install 501 "$W/stage" com.enana.proxy 1; then echo 'FAIL: bootstrap failure succeeded'; exit 1; fi
grep -q first "$W/runtime/config.json"
grep -q 'asuser 501 launchctl enable gui/501/com.enana.proxy' "$W/calls"
[ -f "$W/daemon.plist" ]
# Reject staged symlinks before replacing any running service.
ln -s /tmp "$W/stage/link"
if bash "$W/helper.sh" install 501 "$W/stage" com.enana.proxy 1; then echo 'FAIL: snapshot symlink accepted'; exit 1; fi
grep -q first "$W/runtime/config.json"
rm "$W/stage/link"
# A successful bootstrap with wrong ownership of routes must also roll back.
printf '#!/bin/sh\necho "inet 10.0.0.1 netmask 0xffffff00"\n' > "$W/bin/ifconfig"
if bash "$W/helper.sh" install 501 "$W/stage" com.enana.proxy 1; then echo 'FAIL: route mismatch accepted'; exit 1; fi
grep -q first "$W/runtime/config.json"
[ -z "$(find "$W/runtime" -name '.prepare.*' -o -name '.rollback.*')" ]
echo 'PASS: root snapshot install, bootstrap rollback, GUI recovery, symlink rejection, foreign VPN route rollback, staging cleanup'
