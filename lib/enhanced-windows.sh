# Loaded after enhanced.sh, replacing only macOS lifecycle/OS diagnostics.
enhanced_paths() {
  local sid=${ENANA_WINDOWS_SID:-}; [ -n "$sid" ] || sid=$(powershell.exe -NoProfile -Command '[Security.Principal.WindowsIdentity]::GetCurrent().User.Value' | tr -d '\r')
  local program_data=${ENANA_WINDOWS_PROGRAMDATA:-${ProgramData:-${PROGRAMDATA:-}}}
  [ -n "$program_data" ] || program_data=$(win_bridge program-data) || return 1
  TUN_UID=$sid; TUN_LABEL="Enana Enhanced $sid"; TUN_ROOT="$(cygpath -u "$program_data")/enana/$sid"; TUN_PLIST="$TUN_ROOT/config.json"
}
enhanced_loaded() { local s; s=$(win_bridge tun-info); case $s in '1 1 '*) return 0 ;; *) return 1 ;; esac; }
enhanced_start() {
  enhanced_paths
  local stage rc
  stage=$(mktemp -d)
  clash GET /proxies > "$stage/selectors.json" 2>/dev/null || true
  cp -R "$H/rules" "$stage/rules" && cp "$H/runtime/cache/core.zip" "$stage/core.zip" || { rm -rf "$stage"; return 1; }
  [ ! -d "$H/certs" ] || cp -R "$H/certs" "$stage/certs"
  for f in tun.ps1 common.ps1 runtime-pins.json; do cp "$H/windows/$f" "$stage/$f" || { rm -rf "$stage"; return 1; }; done
  # Rewrite native paths only. The privileged helper uses a fixed ProgramData root.
  enhanced_stage_config "$H/config.json" "$(cygpath -m "$H")" "$(cygpath -m "$TUN_ROOT")" > "$stage/config.json" || { rm -rf "$stage"; return 1; }
  printf '{"arch":"%s"}\n' "${ENANA_WINDOWS_ARCH:-amd64}" > "$stage/snapshot.json"
  # Authorization is requested before touching the user core. Once authorized,
  # the task installer stops only the executable owned by this installation.
  win_bridge tun-install "$(cygpath -w "$stage")" > "$H/enhanced-check.log" 2>&1; rc=$?
  if [ "$rc" = 0 ]; then os_system_service_stop; enhanced_restore_selectors "$stage/selectors.json"; enhanced_fingerprint > "$H/.enhanced-fingerprint"
  else cat "$H/enhanced-check.log" >> "$H/check.log"; fi
  rm -rf "$stage"; return "$rc"
}
enhanced_stop() { win_bridge tun-stop; }
enhanced_remove() { win_bridge tun-remove; }
enhanced_system_log() { :; }
enhanced_ready() { enhanced_configured || return 0; win_bridge tun-ready; }
enhanced_fingerprint() {
  { printf 'autostart=%s\n' "${AUTOSTART:-1}"; shasum -a 256 "$SB" "$H/config.json"; find "$H/rules" "$H/certs" -type f -exec sha256sum {} \; 2>/dev/null;
    shasum -a 256 "$H/windows/tun.ps1" "$H/windows/common.ps1"; } | LC_ALL=C sort | shasum -a 256 | awk '{print $1}'
}
network_socket_diagnostics() { win_bridge diagnostics; }
network_diagnostics() {
  printf 'capture.mode=%s\ncapture.system_proxy_scope=opt-in-apps-only\ncapture.tun.ready=%s\n' "${NETWORK_MODE:-system}" "$(enhanced_configured && enhanced_ready && echo yes || echo no)"
  printf 'capture.priority=master-off,lan,app-pin/nonbrowser,website,browser-fallback,global,cn,final\n'
  win_bridge sysproxy-diagnostics; network_socket_diagnostics
}
