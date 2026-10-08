# Optional macOS TUN backend. No networksetup calls: selecting a capture mode
# never changes the user's HTTP/HTTPS/SOCKS settings. Privileged operations use
# sudo in a terminal, or the native macOS administrator dialog in the dashboard.
enhanced_paths() {
  TUN_UID=$(id -u)
  TUN_LABEL="$LABEL.tun.$TUN_UID"
  # Fixture overrides apply only to unprivileged lookups. The root helper
  # independently uses its fixed Library paths and never trusts these values.
  TUN_ROOT="${ENANA_TUN_ROOT:-/Library/Application Support/enana-$TUN_UID}"
  TUN_PLIST="${ENANA_TUN_PLIST_DIR:-/Library/LaunchDaemons}/$TUN_LABEL.plist"
}
enhanced_configured() { grep -q '"type":"tun"' "$H/config.json" 2>/dev/null; }
enhanced_loaded() { enhanced_paths; launchctl print "system/$TUN_LABEL" >/dev/null 2>&1; }
enhanced_supported() { sb_ver; [ "$SB_MAJOR" -gt 1 ] || { [ "$SB_MAJOR" -eq 1 ] && [ "$SB_MINOR" -ge 12 ]; }; }
# Shell quoting and AppleScript quoting are distinct. Never interpolate user
# paths into shell/AppleScript source without quoting both layers.
enhanced_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
enhanced_admin() {
  local cmd='' a
  for a in "$@"; do cmd="$cmd${cmd:+ }$(enhanced_quote "$a")"; done
  if [ -t 0 ] && [ -t 1 ]; then sudo "$@"
  elif sudo -n true >/dev/null 2>&1; then sudo -n "$@"
  else
    cmd=$(printf '%s' "$cmd" | sed 's/\\/\\\\/g; s/"/\\"/g')
    osascript -e "do shell script \"$cmd\" with administrator privileges" >&2
  fi
}
# The fingerprint of everything the root core was installed from EXCEPT the app/site policy rule sets (rules/ovr-*.json): those are plain routing data
# that enhanced_sync_ovr can push into the root snapshot without a restart (see enhanced_ovr_fingerprint). A change to anything else needs a full,
# administrator-authorised install, so the fingerprint must only move when the root snapshot would really differ:
#   - config.json is hashed with the clash_api "default_mode" value blanked. proxy_apply_mode rewrites that value in place on every master-switch / mode
#     toggle, but it is only the mode the core starts in when it has no remembered one: the live mode is pushed through the API (PATCH /configs) and
#     the core keeps it in cache.db (sing-box restores it on start), and every restart enana makes is followed by proxy_sync_mode. The one thing left
#     is a core that restarts on its own with a stale seed, which apply_config covers (enhanced_mode_resync).
#   - hidden files (rules/.updated is rewritten by every `enana update` even when no rule changed, .DS_Store), *.new and *.tmp (downloads and writes in
#     progress) are bookkeeping, not rule data.
enhanced_config_hash() { sed 's/"default_mode":"[A-Za-z]*"/"default_mode":"-"/' "$H/config.json" 2>/dev/null | shasum -a 256 | awk '{print $1}'; }
enhanced_data_hashes() { find "$H/rules" "$H/certs" -type f ! -name 'ovr-*.json' ! -name '.*' ! -name '*.new' ! -name '*.tmp' -exec shasum -a 256 {} \; 2>/dev/null; }
enhanced_fingerprint() {
  {
    printf 'autostart=%s\n' "${AUTOSTART:-1}"; shasum -a 256 "$SB"; printf 'config:%s\n' "$(enhanced_config_hash)"
    # Source checkouts and the installed copy must fingerprint identically.
    local impl
    for impl in enhanced.sh enhanced-root.sh; do printf 'implementation:%s %s\n' "$impl" "$(shasum -a 256 "$LIB/$impl" | awk '{print $1}')"; done
    enhanced_data_hashes
  } | LC_ALL=C sort | shasum -a 256 | awk '{print $1}'
}
enhanced_record_install() { # after a successful root install: remember what it was built from (see apply_config)
  enhanced_fingerprint > "$H/.enhanced-fingerprint"; enhanced_ovr_fingerprint > "$H/.enhanced-ovr-fingerprint"
  rm -f "$H/.enhanced-stopped"
  if type proxy_clash_mode >/dev/null 2>&1; then proxy_clash_mode > "$H/.enhanced-mode"; fi
}
enhanced_mode_resync() { # the mode baked into the root snapshot is only a seed (see above): when the wanted one differs, push it to the live core and remember it once the core reports it
  local want got; want=$(proxy_clash_mode)
  [ "$(cat "$H/.enhanced-mode" 2>/dev/null)" != "$want" ] || return 0
  proxy_sync_mode
  got=$(clash GET /configs 2>/dev/null | sed -n 's/.*"mode":"\([A-Za-z]*\)".*/\1/p' | head -1)
  [ "$(printf '%s' "$got" | tr 'A-Z' 'a-z')" != "$(printf '%s' "$want" | tr 'A-Z' 'a-z')" ] || printf '%s\n' "$want" > "$H/.enhanced-mode"
  return 0
}
enhanced_ovr_fingerprint() { # the app/site policy rule sets (written by ovr_sync); empty directory => a fixed hash
  { find "$H/rules" -maxdepth 1 -type f -name 'ovr-*.json' -exec shasum -a 256 {} \; 2>/dev/null; echo ovr; } | LC_ALL=C sort | shasum -a 256 | awk '{print $1}'
}

# ---- root helper: change an app/site policy in TUN mode (`sync`) or bounce the root core (`restart`) without an administrator prompt ----
# Version 2 added `restart`. A helper installed by an older enana reports version 1, so enhanced_helper_ok rejects it and the next full install (one
# administrator authorisation, the same one that already follows any upgrade of enhanced.sh / enhanced-root.sh) replaces it. Nothing silently
# calls a helper that lacks the action.
TUNRULES_HELPER_VERSION=2
enhanced_helper_path() { enhanced_paths; printf '%s/usr/local/libexec/enana/tunrules-%s' "${ENANA_ROOT_PREFIX:-}" "$TUN_UID"; }
enhanced_helper_ok() { os_helper_trusted "$(enhanced_helper_path)" "$TUNRULES_HELPER_VERSION"; }
enhanced_ovr_bundle() { # {"ovr-pin.json": {...}, ...} from $H/rules/ovr-*.json (the helper validates it again, strictly)
  perl -MJSON::PP -MFile::Glob=:bsd_glob -e '
    my %o; for my $f (bsd_glob("$ARGV[0]/rules/ovr-*.json")) { my ($n) = $f =~ m{([^/]+)$}; open my $fh, "<", $f or next; local $/; my $d = eval { JSON::PP->new->utf8->decode(scalar <$fh>) }; $o{$n} = $d if ref $d eq "HASH"; }
    print JSON::PP->new->utf8->canonical->encode(\%o);' "$H"
}
enhanced_sync_ovr() { # 0 = synced (the running root core hot-reloads the files); non-zero = no/untrusted helper or rejected data -> caller does the full install
  local h; h=$(enhanced_helper_path)
  enhanced_helper_ok || return 1
  enhanced_ovr_bundle | sudo -n "$h" sync >/dev/null 2>"$H/enhanced-sync.log" || return 1
  enhanced_ovr_fingerprint > "$H/.enhanced-ovr-fingerprint"
}
# Restart the running root core without an administrator prompt: the root helper's `restart` action only runs `launchctl kickstart -k` on this user's
# own TUN daemon (see lib/tunrules-helper.pl). It is the right tool when nothing about the root snapshot changed (fingerprint identical): a full install
# would copy the very same files again and ask for a password for nothing. Returns non-zero when it cannot be used or failed; the caller then does
# the full, authorised install. ENHANCED_FAST_WHY says why (for the operation log).
enhanced_restart_fast() {
  ENHANCED_FAST_WHY=''
  enhanced_paths
  enhanced_configured || { ENHANCED_FAST_WHY=not-tun; return 1; }
  enhanced_loaded || { ENHANCED_FAST_WHY=not-loaded; return 1; }
  [ "$(enhanced_fingerprint)" = "$(cat "$H/.enhanced-fingerprint" 2>/dev/null)" ] || { ENHANCED_FAST_WHY=changed; return 1; }
  enhanced_helper_ok || { ENHANCED_FAST_WHY=no-helper; return 1; }
  # A policy edit that is still pending must reach the root snapshot before the restart loads it.
  if [ "$(enhanced_ovr_fingerprint)" != "$(cat "$H/.enhanced-ovr-fingerprint" 2>/dev/null)" ]; then enhanced_sync_ovr || { ENHANCED_FAST_WHY=sync-failed; return 1; }; fi
  sudo -n "$(enhanced_helper_path)" restart >/dev/null 2>"$H/enhanced-restart.log" || { ENHANCED_FAST_WHY=rejected; return 1; }
}
enhanced_stage_config() {
  # Explicitly open the config: decode(<>) evaluates the diamond in list
  # context and consumes the home/root arguments as additional filenames.
  perl -MJSON::PP -e '
    my ($file,$h,$r)=@ARGV; open my $fh,"<",$file or die "$file: $!";
    local $/; my $j=JSON::PP->new->utf8->decode(scalar <$fh>);
    sub walk { my ($x)=@_; if(ref $x eq "HASH") { for my $k(keys %$x) { if(($k eq "path" || $k eq "output" || $k =~ /_path$/) && !ref($x->{$k}) && index($x->{$k}, "$h/")==0) { $x->{$k}=$r.substr($x->{$k},length($h)); } else { walk($x->{$k}); } } } elsif(ref $x eq "ARRAY") { walk($_) for @$x; } }
    walk($j); print JSON::PP->new->utf8->encode($j);
  ' "$1" "$2" "$3"
}
enhanced_start() {
  local stage rc name choice
  enhanced_paths
  enhanced_supported || { printf '%s\n' 'Enhanced/TUN requires sing-box >= 1.12 (enana upgrade).' > "$H/check.log"; return 1; }
  stage=$(mktemp -d)
  clash GET /proxies > "$stage/selectors.json" 2>/dev/null || true
  cp "$SB" "$stage/sing-box" && cp -R "$H/rules" "$stage/rules" || { rm -rf "$stage"; return 1; }
  [ ! -d "$H/certs" ] || cp -R "$H/certs" "$stage/certs"
  # Rewrite only local filesystem paths, never server names or credentials.
  enhanced_stage_config "$H/config.json" "$H" "$TUN_ROOT" > "$stage/config.json" || { rm -rf "$stage"; return 1; }
  # The privileged AppleScript process cannot read TCC-protected Desktop or
  # Downloads checkouts. Stage the reviewed helper beside its input snapshot.
  cp "$LIB/enhanced-root.sh" "$stage/enhanced-root.sh" || { rm -rf "$stage"; return 1; }
  # The rule-data helper is installed by the same administrator authorisation (best effort, see enhanced-root.sh).
  sed "s|@VERSION@|$TUNRULES_HELPER_VERSION|g" "$LIB/tunrules-helper.pl" > "$stage/tunrules-helper" 2>/dev/null || true
  # The root helper never sources settings.env and never installs user scripts
  # as launchd programs. The executable and configuration are root-owned copies.
  enhanced_admin /bin/bash "$stage/enhanced-root.sh" install "$TUN_UID" "$stage" "$LABEL" "${AUTOSTART:-1}" "$(id -un)" > "$H/enhanced-check.log" 2>&1; rc=$?
  if [ "$rc" != 0 ]; then rm -rf "$stage"; cat "$H/enhanced-check.log" >> "$H/check.log"; return "$rc"; fi
  logs_rotate
  [ ! -f "$H/sing-box.log" ] || [ -L "$H/sing-box.log" ] || mv "$H/sing-box.log" "$H/sing-box.system.log"
  ln -sfn "$TUN_ROOT/sing-box.log" "$H/sing-box.log"
  # Switching from the user core to the root core uses a separate cache.
  # Restore selector choices through the authenticated API, never copy a live DB.
  enhanced_restore_selectors "$stage/selectors.json"
  rm -rf "$stage"
  enhanced_record_install
}
enhanced_restore_selectors() {
  local name choice
  while IFS="$(printf '\t')" read -r name choice; do
    [ -n "$name" ] || continue
    clash PUT "/proxies/$name" "$choice" >/dev/null 2>&1 || true
  done < <(perl -MJSON::PP -e '
    local $/; my $j=eval { decode_json(<>) }; exit unless ref $j eq "HASH";
    my $p=$j->{proxies} || {}; for my $n(sort keys %$p) {
      next unless ($p->{$n}{type} // "") eq "Selector" && $n ne "SPEEDTEST" && defined $p->{$n}{now};
      my $url=$n; utf8::encode($url); $url =~ s/([^A-Za-z0-9_.~-])/sprintf("%%%02X",ord($1))/ge;
      print $url,"\t",JSON::PP->new->utf8->encode({name=>$p->{$n}{now}}),"\n";
    }' "$1")
}
# 0 = there is nothing for `stop` to do: the root daemon is not loaded AND cannot come back on its own. `stop` (enhanced-root.sh) unloads the job and also
# disables it, so it does not return at the next boot next to the user's own core; that state outlives the process. We know it holds when launchd lists
# the job as disabled (no root needed to ask) or when our own earlier `stop` succeeded and nothing has loaded the job since (the marker is dropped the
# moment a loaded daemon is seen and by every install). Unloaded but still enabled (someone booted it out by hand) is NOT idle: `stop` runs and disables it.
enhanced_idle() {
  enhanced_paths
  if enhanced_loaded; then rm -f "$H/.enhanced-stopped"; return 1; fi
  [ -f "$H/.enhanced-stopped" ] && return 0
  launchctl print-disabled system 2>/dev/null | grep -F "\"$TUN_LABEL\"" | grep -Eq '=> (true|disabled)'
}
# The plist stays after a stop (only `remove` deletes it), so "plist exists" alone does not mean a daemon is running: asking for administrator rights to
# stop an already-stopped daemon made every System Proxy start / stop prompt once the user had tried TUN.
enhanced_stop() {
  local rc; enhanced_paths; [ -e "$TUN_PLIST" ] || return 0
  enhanced_idle && return 0
  enhanced_admin /bin/bash "$LIB/enhanced-root.sh" stop "$TUN_UID"; rc=$?
  [ "$rc" != 0 ] || : > "$H/.enhanced-stopped"
  return "$rc"
}
enhanced_remove() {
  enhanced_paths; [ -e "$TUN_PLIST" ] || [ -e "$TUN_ROOT" ] || return 0
  enhanced_admin /bin/bash "$LIB/enhanced-root.sh" remove "$TUN_UID" || return $?
  rm -f "$H/.enhanced-stopped"
}
enhanced_system_log() {
  if [ -L "$H/sing-box.log" ] && [ "$(readlink "$H/sing-box.log")" = "$TUN_ROOT/sing-box.log" ]; then
    logs_rotate; rm -f "$H/sing-box.log"; : > "$H/sing-box.log"
  fi
}
enhanced_ready() {
  enhanced_configured || return 0
  enhanced_loaded || return 1
  # Port readiness alone may refer to a leftover mixed-only core. Verify that
  # both address families actually route public traffic into a utun interface.
  local v4 v6
  v4=$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/ {print $2}')
  v6=$(route -n get -inet6 2606:4700:4700::1111 2>/dev/null | awk '/interface:/ {print $2}')
  case $v4:$v6 in utun*:utun*) [ "$v4" = "$v6" ] && ifconfig "$v4" 2>/dev/null | grep -q 'inet 172.19.0.1 ' ;; *) return 1 ;; esac
}
network_mode_set() {
  case ${1:-} in system|tun) ;; *) warn 'network-mode: system | tun'; return 1 ;; esac
  op_txn '切换流量接管模式' txn_settings "NETWORK_MODE=$1"
}

network_socket_diagnostics() {
  local tmp; tmp=$(mktemp -d)
  lsof -nP -a -u "$(id -un)" -iTCP -iUDP -FpcfnPT > "$tmp/sockets" 2>/dev/null || true
  ps -axo pid=,comm= > "$tmp/processes" 2>/dev/null || true
  clash GET /connections > "$tmp/connections" 2>/dev/null || true
  perl "$LIB/network-diagnostics.pl" "$tmp/sockets" "$tmp/processes" "$tmp/connections" "$H/overrides.tsv" "${NETWORK_MODE:-system}"
  rm -rf "$tmp"
}
network_diagnostics() {
  enhanced_paths
  printf 'capture.mode=%s\ncapture.system_proxy_scope=opt-in-apps-only\n' "${NETWORK_MODE:-system}"
  printf 'capture.tun.configured=%s\ncapture.tun.ready=%s\ncapture.tun.service=%s\n' "$(enhanced_configured && echo yes || echo no)" "$(enhanced_configured && enhanced_ready && echo yes || echo no)" "$TUN_LABEL"
  launchctl print "system/$TUN_LABEL" 2>/dev/null | awk '/^[[:space:]]*(state|pid|last exit code) = / {k=$0; sub(/^[[:space:]]*/,"",k); print "capture.tun." k}'
  printf 'capture.priority=master-off,lan,app-pin/nonbrowser,website,browser-fallback,global,cn,final\n'
  printf 'capture.note=No sing-box log does not prove an App had no traffic; inspect OS sockets.\n'
  route -n get 1.1.1.1 2>/dev/null | awk '/interface:/ {print "capture.route.ipv4=" $2}'
  route -n get -inet6 2606:4700:4700::1111 2>/dev/null | awk '/interface:/ {print "capture.route.ipv6=" $2}'
  route -n get 127.0.0.1 2>/dev/null | awk '/interface:/ {print "capture.route.localhost=" $2}'
  network_socket_diagnostics
}
