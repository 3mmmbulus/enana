#!/bin/bash
# Tests the signature check in get.ps1 with PowerShell (pwsh). Throwaway keys live in a temp dir.
# Needs: pwsh (PowerShell 7+ on macOS/Linux for these logic tests; Windows CI runs the CNG path).
set -u
repo=$(cd "$(dirname "$0")/.." && pwd -P)
command -v pwsh >/dev/null 2>&1 || { echo 'pwsh is required: brew install --cask powershell'; exit 2; }
W=$(mktemp -d /tmp/enana-sigtest.XXXXXX); trap 'rm -rf "$W"' EXIT
openssl ecparam -name prime256v1 -genkey -noout -out "$W/k.pem"; openssl ec -in "$W/k.pem" -pubout -out "$W/pub.pem" 2>/dev/null
openssl ecparam -name prime256v1 -genkey -noout -out "$W/o.pem"; openssl ec -in "$W/o.pem" -pubout -out "$W/opub.pem" 2>/dev/null
printf '{"platform":"windows","version":"9.9.9","sha256":"%064d","size":1,"url":"/dl/x.zip"}\n' 0 > "$W/m.json"
openssl dgst -sha256 -sign "$W/k.pem" -out "$W/m.sig" "$W/m.json"
cp "$W/m.json" "$W/m-tampered.json"; printf 'x' >> "$W/m-tampered.json"
# corrupt one byte of the signature (inside the DER body)
python3 -c "import sys; b=bytearray(open(sys.argv[1],'rb').read()); b[len(b)//2]^=0x01; open(sys.argv[2],'wb').write(bytes(b))" "$W/m.sig" "$W/m-badsig.sig"
printf 'not a der signature' > "$W/garbage.sig"
run() { pwsh -NoProfile -File "$repo/tests/windows-signature.ps1" "$@" 2>&1 | grep '^RESULT:' | tail -1; }
pass=0; fail=0
check() { local name=$1 want=$2 got=$3; if [ "$got" = "$want" ]; then echo "  ok   $name"; pass=$((pass+1)); else echo "  FAIL $name (want $want, got $got)"; fail=$((fail+1)); fi; }
check "valid signature with the matching key" 'RESULT:True' "$(run -Data "$W/m.json" -Sig "$W/m.sig" -Pub "$W/pub.pem")"
check "manifest changed by one byte" 'RESULT:False' "$(run -Data "$W/m-tampered.json" -Sig "$W/m.sig" -Pub "$W/pub.pem")"
check "signature by another key" 'RESULT:False' "$(run -Data "$W/m.json" -Sig "$W/m.sig" -Pub "$W/opub.pem")"
check "signature with one flipped byte" 'RESULT:False' "$(run -Data "$W/m.json" -Sig "$W/m-badsig.sig" -Pub "$W/pub.pem")"
case "$(run -Data "$W/m.json" -Sig "$W/garbage.sig" -Pub "$W/pub.pem")" in RESULT:THROW*) check "malformed signature is rejected with an error" ok ok; pass=$((pass)) ;; *) check "malformed signature is rejected with an error" ok bad; fail=$((fail)) ;; esac
if [ -f "$repo/data/release-pub.pem" ] && [ -n "${REAL_SIG_DIR:-}" ]; then
  check "built-in release key verifies the published manifest" 'RESULT:True' "$(run -Data "$REAL_SIG_DIR/windows-manifest.json" -Sig "$REAL_SIG_DIR/windows-manifest.json.sig")"
fi
echo "passed $pass, failed $fail"; [ "$fail" = 0 ]
