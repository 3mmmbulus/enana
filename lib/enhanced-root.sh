#!/bin/bash
# Runs only after explicit OS administrator authorization. Arguments are data;
# no settings.env, eval or arbitrary launchd program. The one persistent
# privilege it leaves behind is a narrowly scoped rule-data helper (see
# install_tun_helper): it can only write validated routing-rule JSON into the
# root snapshot, so changing an app/site policy does not need another
# administrator prompt. It never accepts executables or core configuration.
set -eu
[ "$(id -u)" = 0 ] || { echo 'Administrator authorization required'; exit 1; }
action=${1:-}; uid=${2:-}
case $uid in ''|*[!0-9]*) exit 2 ;; esac
root="/Library/Application Support/enana-$uid"
label="com.enana.proxy.tun.$uid"
plist="/Library/LaunchDaemons/$label.plist"
libexec="/usr/local/libexec/enana"; sudoers_dir="/etc/sudoers.d"      # fixed paths (tests substitute them in a temporary copy)
case $action in
  stop) launchctl disable "system/$label"; launchctl bootout "system/$label" 2>/dev/null || true; exit 0 ;;
  remove)
    launchctl bootout "system/$label" 2>/dev/null || true
    launchctl enable "system/$label" 2>/dev/null || true
    rm -f "$plist"; rm -rf "$root"
    rm -f "$sudoers_dir/enana-tunrules-$uid" "$libexec/tunrules-$uid"; rmdir "$libexec" 2>/dev/null || true
    exit 0 ;;
  install) ;;
  *) exit 2 ;;
esac
stage=${3:-}; agent=${4:-}; autostart=${5:-0}; username=${6:-}
[ "$agent" = com.enana.proxy ] || exit 2
case $autostart in 0|1) ;; *) exit 2 ;; esac
[ -d "$stage" ] && [ ! -L "$stage" ] || exit 2
# Don't let a copied symlink become a writable root executable/configuration.
[ -z "$(find "$stage" -type l -print)" ] || { echo 'Symlinks are not allowed in the privileged snapshot'; exit 2; }
[ ! -L "$root" ] && [ ! -L "$plist" ] || exit 2
if [ -e "$root" ]; then
  [ "$(stat -f %u "$root")" = 0 ] && [ -z "$(find "$root" -type l -print)" ] || exit 2
fi
mkdir -p "$root"; chown root:wheel "$root"; chmod 711 "$root"
work=$(mktemp -d "$root/.prepare.XXXXXX")
backup=$(mktemp -d "$root/.rollback.XXXXXX")
changed=0; committed=0; had_root=0; had_gui=0; gui_plist=''
launchctl print "system/$label" >/dev/null 2>&1 && had_root=1
if gui_info=$(launchctl print "gui/$uid/$agent" 2>/dev/null); then
  had_gui=1
  gui_plist=$(printf '%s\n' "$gui_info" | sed -n 's/^[[:space:]]*path = //p' | head -1)
  [ -n "$gui_plist" ] && [ -f "$gui_plist" ] || { echo 'Cannot save existing user service for rollback'; exit 2; }
fi
for name in sing-box config.json rules certs; do
  [ ! -e "$root/$name" ] || cp -R "$root/$name" "$backup/$name"
done
[ ! -e "$plist" ] || cp "$plist" "$backup/daemon.plist"
rollback() {
  rc=$?
  if [ "$changed" = 1 ] && [ "$committed" = 0 ]; then
    launchctl bootout "system/$label" 2>/dev/null || true
    for name in sing-box config.json rules certs; do
      rm -rf "$root/$name"
      [ ! -e "$backup/$name" ] || mv "$backup/$name" "$root/$name"
    done
    rm -f "$plist"
    if [ -e "$backup/daemon.plist" ]; then
      mv "$backup/daemon.plist" "$plist"
      if [ "$had_root" = 1 ]; then
        launchctl enable "system/$label" || true
        launchctl bootstrap system "$plist" || true
        launchctl kickstart "system/$label" || true
      else launchctl disable "system/$label" || true; fi
    fi
    if [ "$had_gui" = 1 ]; then
      launchctl asuser "$uid" launchctl enable "gui/$uid/$agent" || true
      launchctl asuser "$uid" launchctl bootstrap "gui/$uid" "$gui_plist" || true
      launchctl asuser "$uid" launchctl kickstart "gui/$uid/$agent" || true
    fi
  fi
  rm -rf "$work" "$backup"
  exit "$rc"
}
trap rollback EXIT
cp -R "$stage/." "$work/"
chown -R root:wheel "$work"; chmod -R go-rwx "$work"; chmod 755 "$work/sing-box"
# Validate using the staged rules/certificates before stopping the old core.
perl -MJSON::PP -e 'local $/; my $s=<>; my ($r,$w)=@ARGV; $s =~ s/\Q$r\E/$w/g; print $s' "$work/config.json" "$root" "$work" > "$work/check.json"
"$work/sing-box" check -c "$work/check.json"
rm "$work/check.json"
# The stable log file is user-writable for existing rotation, but its directory
# is root-owned, so the user cannot replace it with a symlink followed by root.
if [ ! -e "$root/sing-box.log" ]; then touch "$root/sing-box.log"; fi
[ ! -L "$root/sing-box.log" ] || exit 2
chown "$uid" "$root/sing-box.log"; chmod 600 "$root/sing-box.log"
changed=1
launchctl bootout "system/$label" 2>/dev/null || true
launchctl asuser "$uid" launchctl disable "gui/$uid/$agent" 2>/dev/null || true
# Disabling a loaded KeepAlive job does not unload it; killing its process
# allows launchd to respawn it against the new TUN config. Remove the job.
if [ "$had_gui" = 1 ]; then
  launchctl asuser "$uid" launchctl bootout "gui/$uid/$agent"
fi
# Preserve the root-owned cache (selected PIN/Global nodes) across restarts.
for name in sing-box config.json rules certs; do
  [ -e "$work/$name" ] || continue
  rm -rf "$root/$name"; mv "$work/$name" "$root/$name"
done
# Best effort and never fatal: the rule-data helper + a one-line sudoers rule for this user (validated with visudo -cf before it is written).
install_tun_helper() {
  [ -n "$username" ] && [ -f "$stage/tunrules-helper" ] && [ ! -L "$stage/tunrules-helper" ] || return 0
  case $username in *[!A-Za-z0-9._-]*) return 0 ;; esac
  local t h s; t=$(mktemp -d "$root/.helper.XXXXXX") || return 0
  h="$libexec/tunrules-$uid"; s="$sudoers_dir/enana-tunrules-$uid"
  # Copy first (the stage directory is user-writable), then validate and install that same copy.
  cp "$stage/tunrules-helper" "$t/in" || { rm -rf "$t"; return 0; }
  R="$root" perl -pe 's/\@ROOT\@/$ENV{R}/g; s/\@ROOTUID\@/0/g' "$t/in" > "$t/h"
  head -1 "$t/h" | grep -q '^#!/usr/bin/perl$' && /usr/bin/perl -c "$t/h" >/dev/null 2>&1 || { rm -rf "$t"; return 0; }
  printf '%s ALL=(root) NOPASSWD: %s\n' "$username" "$h" > "$t/s"
  /usr/sbin/visudo -cf "$t/s" >/dev/null 2>&1 || { rm -rf "$t"; return 0; }
  mkdir -p "$libexec" && chown root:wheel "$libexec" && chmod 755 "$libexec" \
    && install -m 755 -o root -g wheel "$t/h" "$h" \
    && mkdir -p "$sudoers_dir" && install -m 440 -o root -g wheel "$t/s" "$s"
  rm -rf "$t"
}
install_tun_helper || true
run='<false/>'; [ "$autostart" = 1 ] && run='<true/>'
# Fixed root-owned paths, no home path or arbitrary program in the daemon plist.
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array><string>$root/sing-box</string><string>run</string><string>-c</string><string>$root/config.json</string><string>-D</string><string>$root</string></array>
<key>RunAtLoad</key>$run
<key>KeepAlive</key>$run
<key>StandardOutPath</key><string>$root/service.log</string>
<key>StandardErrorPath</key><string>$root/service.log</string>
</dict></plist>
PLIST
chown root:wheel "$plist"; chmod 600 "$plist"
launchctl enable "system/$label"
launchctl bootstrap system "$plist"
launchctl kickstart "system/$label"

# Bootstrap can succeed even when the core immediately exits. Confirm its PID
# and both public routes belong to our address-bearing interface before commit.
n=0
while [ "$n" -lt 15 ]; do
  v4=$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/ {print $2}')
  v6=$(route -n get -inet6 2606:4700:4700::1111 2>/dev/null | awk '/interface:/ {print $2}')
  case $v4 in utun*)
    if [ "$v4" = "$v6" ] && ifconfig "$v4" | grep -q 'inet 172.19.0.1 ' && launchctl print "system/$label" | grep -q 'pid = '; then
      committed=1; exit 0
    fi ;;
  esac
  n=$((n + 1)); sleep 1
done
echo 'TUN did not take ownership of IPv4/IPv6 routes; restored previous core' >&2
exit 1
