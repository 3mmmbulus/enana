#!/bin/bash
# Execute the privileged helper only after replacing its fixed Library paths in
# a TEMPORARY COPY. All privileged/OS commands are fakes; never calls sudo.
set -eu
R=$(cd "$(dirname "$0")/.." && pwd -P)
W=$(mktemp -d /tmp/enana-root-test.XXXXXX); trap 'rm -rf "$W"' EXIT
export FIXTURE="$W"; mkdir -p "$W/bin" "$W/stage/rules"
touch "$W/gui.plist"
python3 - "$R" "$W" <<'PY'
import sys
r,w=sys.argv[1:]; s=open(r+'/lib/enhanced-root.sh').read()
s=s.replace('root="/Library/Application Support/enana-$uid"','root="'+w+'/runtime"')
s=s.replace('plist="/Library/LaunchDaemons/$label.plist"','plist="'+w+'/daemon.plist"')
s=s.replace('libexec="/usr/local/libexec/enana"; sudoers_dir="/etc/sudoers.d"','libexec="'+w+'/libexec"; sudoers_dir="'+w+'/sudoers.d"')
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
 print) echo 'pid = 100'; echo "path = $FIXTURE/gui.plist"; exit 0 ;;
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
grep -q '^asuser 501 launchctl bootout gui/501/com.enana.proxy$' "$W/calls"
! grep -q '^asuser 501 launchctl kill ' "$W/calls"
printf '{"snapshot":"second"}\n' > "$W/stage/config.json"
touch "$W/fail-bootstrap"
if bash "$W/helper.sh" install 501 "$W/stage" com.enana.proxy 1; then echo 'FAIL: bootstrap failure succeeded'; exit 1; fi
grep -q first "$W/runtime/config.json"
grep -q 'asuser 501 launchctl enable gui/501/com.enana.proxy' "$W/calls"
grep -q "asuser 501 launchctl bootstrap gui/501 $W/gui.plist" "$W/calls"
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
rm -f "$W/daemon.plist"
bash "$W/helper.sh" remove 501
[ ! -e "$W/runtime" ] && [ ! -e "$W/daemon.plist" ]
grep -q 'enable system/com.enana.proxy.tun.501' "$W/calls"
# ---- the rule-data helper is installed by the same authorisation (best effort), validated first, and removed with the service ----
printf '#!/bin/sh\necho "inet 172.19.0.1 netmask 0xfffffffc"\n' > "$W/bin/ifconfig"
cat > "$W/bin/install" <<'MOCK'
#!/bin/bash
# fake install: ignore -o/-g (the test is not root), support -m and -d
mode=''; args=(); while [ $# -gt 0 ]; do case $1 in -m) mode=$2; shift 2 ;; -o|-g) shift 2 ;; -d) shift ;; *) args+=("$1"); shift ;; esac; done
cp "${args[0]}" "${args[1]}" && { [ -z "$mode" ] || chmod "$mode" "${args[1]}"; }
MOCK
chmod +x "$W/bin/install"
mkdir -p "$W/stage/rules"; printf '{"snapshot":"third"}\n' > "$W/stage/config.json"
sed 's|@VERSION@|1|g' "$R/lib/tunrules-helper.pl" > "$W/stage/tunrules-helper"
bash "$W/helper.sh" install 501 "$W/stage" com.enana.proxy 1 tester
[ -x "$W/libexec/tunrules-501" ]
grep -qx "tester ALL=(root) NOPASSWD: $W/libexec/tunrules-501" "$W/sudoers.d/enana-tunrules-501"
[ "$(wc -l < "$W/sudoers.d/enana-tunrules-501" | tr -d ' ')" = 1 ]
[ "$(stat -f %Lp "$W/libexec/tunrules-501")" = 755 ] && [ "$(stat -f %Lp "$W/sudoers.d/enana-tunrules-501")" = 440 ]
! grep -q '@ROOT@\|@ROOTUID@\|@VERSION@' "$W/libexec/tunrules-501"
grep -q "my \$ROOT = '$W/runtime'" "$W/libexec/tunrules-501"
grep -q 'my \$ROOT_UID = 0;' "$W/libexec/tunrules-501"
/usr/bin/perl -c "$W/libexec/tunrules-501" >/dev/null 2>&1
/usr/sbin/visudo -cf "$W/sudoers.d/enana-tunrules-501" >/dev/null
[ ! -e "$W/stage/../runtime/.helper."* ] 2>/dev/null
# A bad user name, a non-perl helper or a helper that does not compile never blocks or breaks the TUN install, and leaves no rule behind.
rm -rf "$W/libexec" "$W/sudoers.d"
bash "$W/helper.sh" install 501 "$W/stage" com.enana.proxy 1 'bad user;name'
[ ! -e "$W/libexec/tunrules-501" ] && [ ! -e "$W/sudoers.d/enana-tunrules-501" ]
printf '#!/bin/sh\necho pwned\n' > "$W/stage/tunrules-helper"
bash "$W/helper.sh" install 501 "$W/stage" com.enana.proxy 1 tester
[ ! -e "$W/libexec/tunrules-501" ] && [ ! -e "$W/sudoers.d/enana-tunrules-501" ]
printf '#!/usr/bin/perl\nthis is not perl (\n' > "$W/stage/tunrules-helper"
bash "$W/helper.sh" install 501 "$W/stage" com.enana.proxy 1 tester
[ ! -e "$W/libexec/tunrules-501" ] && [ ! -e "$W/sudoers.d/enana-tunrules-501" ]
rm -f "$W/stage/tunrules-helper"
bash "$W/helper.sh" install 501 "$W/stage" com.enana.proxy 1 tester
[ ! -e "$W/libexec/tunrules-501" ]
# Installing a good helper again and then removing the service removes the helper and its sudoers rule.
sed 's|@VERSION@|1|g' "$R/lib/tunrules-helper.pl" > "$W/stage/tunrules-helper"
bash "$W/helper.sh" install 501 "$W/stage" com.enana.proxy 1 tester
[ -x "$W/libexec/tunrules-501" ] && [ -f "$W/sudoers.d/enana-tunrules-501" ]
bash "$W/helper.sh" remove 501
[ ! -e "$W/libexec/tunrules-501" ] && [ ! -e "$W/sudoers.d/enana-tunrules-501" ] && [ ! -e "$W/libexec" ]
echo 'PASS: root snapshot install, bootstrap rollback, GUI recovery, symlink rejection, foreign VPN route rollback, staging cleanup, rule-data helper install / validation / removal'
