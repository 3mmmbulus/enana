# Windows 10/11 adapter, run by enana's private PortableGit runtime.
win_bridge() {
  local action=$1 value=${2:-}
  MSYS2_ARG_CONV_EXCL='*' powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(cygpath -w "$H/windows/platform.ps1")" -Action "$action" -HomeDir "$(cygpath -w "$H")" -Value "$value" | tr -d '\r'
  return "${PIPESTATUS[0]}"
}
windows_node() { "$H/runtime/node/node.exe" "$H/windows/helper.js" "$@"; }
windows_worker_alive() { local s; s=$(windows_node state "$H"); case $s in '1 '*) return 0 ;; *) return 1 ;; esac; }
windows_control() { windows_node control "$H" "$1"; }
os_detect() {
  OS=Windows; MACOS=0; MACOS_MAJOR=0; ARCH=${ENANA_WINDOWS_ARCH:-amd64}; CHIP=$ARCH; BREW=''; IS_ADMIN=$(win_bridge admin)
}
os_system_service_info() { local s; s=$(windows_node state "$H"); read -r SVC_LOADED SVC_RUNNING SVC_PID <<< "$s"; }
os_system_service_loaded() { windows_worker_alive; }
os_system_service_running() { os_system_service_info; [ "${SVC_RUNNING:-0}" = 1 ]; }
os_system_service_pid() { os_system_service_info; printf '%s' "${SVC_PID:-}"; }
os_system_service_start() { os_aux_load || return 1; windows_control start; }
os_system_service_restart() { os_aux_load || return 1; windows_control restart; }
os_system_service_stop() { windows_control stop; }
os_service_info() {
  local s; s=$(win_bridge tun-info)
  case $s in '1 1 '*) read -r SVC_LOADED SVC_RUNNING SVC_PID <<< "$s" ;; *) os_system_service_info ;; esac
}
os_service_loaded() { os_service_info; [ "${SVC_LOADED:-0}" = 1 ]; }
os_service_running() { os_service_info; [ "${SVC_RUNNING:-0}" = 1 ]; }
os_service_pid() { os_service_info; printf '%s' "${SVC_PID:-}"; }
os_service_start() {
  if enhanced_configured; then enhanced_start
  else enhanced_stop || return 1; os_system_service_start; fi
}
os_service_restart() { if enhanced_configured || enhanced_loaded; then os_service_start; else os_system_service_restart; fi; }
os_service_stop() { enhanced_stop || return 1; os_system_service_stop; }
os_write_plists() { local out; out=$(win_bridge task-register) || return 2; [ "$out" = unchanged ] && return 0; return 1; }
os_aux_load() {
  windows_worker_alive && return 0
  win_bridge worker-start || return 1
  local i=0; while [ "$i" -lt 40 ]; do windows_worker_alive && return 0; i=$((i+1)); sleep 0.25; done
  return 1
}
os_aux_unload() { windows_control shutdown || return 1; win_bridge worker-remove; }
os_sysproxy_ok() { win_bridge sysproxy-ok >/dev/null; }
os_sysproxy_mine() { os_sysproxy_ok; }
os_sysproxy_cached() { os_sysproxy_ok; }
os_sysproxy_foreign() { win_bridge sysproxy-foreign; }
os_sysproxy_backup() { :; } # The native setter captures all WinINet/PAC values transactionally.
os_sysproxy_services() { printf '%s\n' Windows-user; }
os_sysproxy_set() { case $1 in on|off) win_bridge "sysproxy-$1" ;; *) return 1 ;; esac; }
os_open() { win_bridge open "$1"; }
os_date_minus_days() { date -d "$1 days ago" +%F; }
os_date_minus_hours() { date -d "$1 hours ago" '+%F %T'; }
os_legacy_cleanup() { :; }
shortcut_path() { [ -f "$H/bin/enana.cmd" ] && printf '%s' "$H/bin/enana.cmd"; }
shortcut_install() { [ -f "$H/bin/enana.cmd" ] || return 1; SHORTCUT="$H/bin/enana.cmd"; SHORTCUT_RC=''; }
shortcut_remove() { win_bridge shortcut-remove; }
# PortableGit supplies GNU tools. Keep BSD call sites compatible, scoped to this adapter.
sed() { if [ "${1:-}" = -i ] && [ "${2:-x}" = '' ]; then shift 2; command sed -i "$@"; else command sed "$@"; fi; }
stat() {
  if [ "${1:-}" = -f ]; then
    local fmt=$2; shift 2; fmt=${fmt//%N/%n}; fmt=${fmt//%z/%s}; fmt=${fmt//%m/%Y}; fmt=${fmt//%u/%u}
    command stat -c "$fmt" "$@"
  else command stat "$@"; fi
}
nc() { [ "${1:-}" = -z ] && [ "${2:-}" = 127.0.0.1 ] || return 1; windows_node probe "$2" "$3"; }
shasum() { [ "${1:-}" = -a ] && [ "${2:-}" = 256 ] || return 1; shift 2; command sha256sum "$@"; }
