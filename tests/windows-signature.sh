#!/bin/bash
# Tests the signature check in get.ps1 with PowerShell. Throwaway keys live in a temp dir.
#   PS_BIN       PowerShell to use: pwsh (default) or powershell (Windows PowerShell 5.1 on Windows CI)
#   REAL_SIG_DIR optional directory with the published windows-manifest.json and .sig: checked with the built-in key
# Windows CI runs this under Git Bash with both PowerShell versions, so the CNG path is tested for real.
set -u
repo=$(cd "$(dirname "$0")/.." && pwd -P)
PS_BIN=${PS_BIN:-pwsh}
command -v "$PS_BIN" >/dev/null 2>&1 || { echo "$PS_BIN is required"; exit 2; }
command -v openssl >/dev/null 2>&1 || { echo 'openssl is required'; exit 2; }
W=$(mktemp -d "${TMPDIR:-/tmp}/enana-sigtest.XXXXXX"); trap 'rm -rf "$W"' EXIT
# PowerShell on Windows needs Windows paths
wp() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
openssl ecparam -name prime256v1 -genkey -noout -out "$W/k.pem"; openssl ec -in "$W/k.pem" -pubout -out "$W/pub.pem" 2>/dev/null
openssl ecparam -name prime256v1 -genkey -noout -out "$W/o.pem"; openssl ec -in "$W/o.pem" -pubout -out "$W/opub.pem" 2>/dev/null
printf '{"platform":"windows","version":"9.9.9","sha256":"%064d","size":1,"url":"/dl/x.zip"}\n' 0 > "$W/m.json"
openssl dgst -sha256 -sign "$W/k.pem" -out "$W/m.sig" "$W/m.json"
cp "$W/m.json" "$W/m-tampered.json"; printf 'x' >> "$W/m-tampered.json"
perl -e 'open my $f, "<:raw", $ARGV[0] or die; local $/; my $b = <$f>; substr($b, int(length($b)/2), 1) ^= "\x01"; open my $o, ">:raw", $ARGV[1] or die; print $o $b' "$W/m.sig" "$W/m-badsig.sig"
printf 'not a der signature' > "$W/garbage.sig"
run() { # run <args for windows-signature.ps1 (files given as paths)>
  local args=() a
  for a in "$@"; do args+=("$a"); done
  "$PS_BIN" -NoProfile -File "$(wp "$repo/tests/windows-signature.ps1")" "${args[@]}" 2>&1 | tr -d '\r' | grep '^RESULT:' | tail -1
}
pass=0; fail=0
check() { local name=$1 want=$2 got=$3; if [ "$got" = "$want" ]; then echo "  ok   $name"; pass=$((pass+1)); else echo "  FAIL $name (want: $want, got: $got)"; fail=$((fail+1)); fi; }
echo "PowerShell: $("$PS_BIN" -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null | tr -d '\r')"
check "valid signature with the matching key" 'RESULT:True' "$(run -Data "$(wp "$W/m.json")" -Sig "$(wp "$W/m.sig")" -Pub "$(wp "$W/pub.pem")")"
check "manifest changed by one byte" 'RESULT:False' "$(run -Data "$(wp "$W/m-tampered.json")" -Sig "$(wp "$W/m.sig")" -Pub "$(wp "$W/pub.pem")")"
check "signature by another key" 'RESULT:False' "$(run -Data "$(wp "$W/m.json")" -Sig "$(wp "$W/m.sig")" -Pub "$(wp "$W/opub.pem")")"
check "signature with one flipped byte" 'RESULT:False' "$(run -Data "$(wp "$W/m.json")" -Sig "$(wp "$W/m-badsig.sig")" -Pub "$(wp "$W/pub.pem")")"
case "$(run -Data "$(wp "$W/m.json")" -Sig "$(wp "$W/garbage.sig")" -Pub "$(wp "$W/pub.pem")")" in
  RESULT:THROW*) check "malformed signature is rejected with an error" ok ok ;;
  *) check "malformed signature is rejected with an error" ok bad ;;
esac
if [ -n "${REAL_SIG_DIR:-}" ]; then
  check "built-in release key verifies the published manifest" 'RESULT:True' "$(run -Data "$(wp "$REAL_SIG_DIR/windows-manifest.json")" -Sig "$(wp "$REAL_SIG_DIR/windows-manifest.json.sig")")"
fi
echo "passed $pass, failed $fail"; [ "$fail" = 0 ]
