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
enhanced_fingerprint() {
  {
    printf 'autostart=%s\n' "${AUTOSTART:-1}"; shasum -a 256 "$SB" "$H/config.json"
    # Source checkouts and the installed copy must fingerprint identically.
    local impl
    for impl in enhanced.sh enhanced-root.sh; do printf 'implementation:%s %s\n' "$impl" "$(shasum -a 256 "$LIB/$impl" | awk '{print $1}')"; done
    find "$H/rules" "$H/certs" -type f -exec shasum -a 256 {} \; 2>/dev/null
  } | LC_ALL=C sort | shasum -a 256 | awk '{print $1}'
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
  # The root helper never sources settings.env and never installs user scripts
  # as launchd programs. The executable and configuration are root-owned copies.
  enhanced_admin /bin/bash "$stage/enhanced-root.sh" install "$TUN_UID" "$stage" "$LABEL" "${AUTOSTART:-1}" > "$H/enhanced-check.log" 2>&1; rc=$?
  if [ "$rc" != 0 ]; then rm -rf "$stage"; cat "$H/enhanced-check.log" >> "$H/check.log"; return "$rc"; fi
  logs_rotate
  [ ! -f "$H/sing-box.log" ] || [ -L "$H/sing-box.log" ] || mv "$H/sing-box.log" "$H/sing-box.system.log"
  ln -sfn "$TUN_ROOT/sing-box.log" "$H/sing-box.log"
  # Switching from the user core to the root core uses a separate cache.
  # Restore selector choices through the authenticated API, never copy a live DB.
  enhanced_restore_selectors "$stage/selectors.json"
  rm -rf "$stage"
  enhanced_fingerprint > "$H/.enhanced-fingerprint"
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
enhanced_stop() { enhanced_paths; [ -e "$TUN_PLIST" ] || return 0; enhanced_admin /bin/bash "$LIB/enhanced-root.sh" stop "$TUN_UID"; }
enhanced_remove() { enhanced_paths; [ -e "$TUN_PLIST" ] || return 0; enhanced_admin /bin/bash "$LIB/enhanced-root.sh" remove "$TUN_UID"; }
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
