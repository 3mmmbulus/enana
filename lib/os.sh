# Select a real platform adapter; shared routing/account code stays identical.
case "$(uname -s)" in
  Darwin) ENANA_PLATFORM=darwin; . "$LIB/os-darwin.sh" ;;
  MINGW*|MSYS*) ENANA_PLATFORM=windows; . "$LIB/os-windows.sh" ;;
  *) printf '%s\n' 'Unsupported platform: use macOS or the Windows PowerShell installer.' >&2; return 1 ;;
esac
export ENANA_PLATFORM
