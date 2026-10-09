#!/bin/bash
# Sign the public download manifests of a release directory with the release (cloud) ECDSA P-256 key.
#   tools/sign-release.sh RELEASE_DIR PRIVATE_KEY_PEM [PUBLIC_KEY_PEM]
# The private key is only passed to openssl here; this script never reads or prints it.
# Each signature is verified with the public key before it is written, and the public key is
# copied into the release directory as release-pubkey.pem so the publish scripts can verify again.
set -euo pipefail
release=${1:?Usage: sign-release.sh RELEASE_DIR PRIVATE_KEY_PEM [PUBLIC_KEY_PEM]}
key=${2:?private key path}
pub=${3:-$(cd "$(dirname "$0")/.." && pwd -P)/data/cloud-pub.pem}
[ -d "$release" ] && [ -f "$key" ] && [ -f "$pub" ] || { echo 'release directory, private key and public key must exist' >&2; exit 2; }
signed=0
for name in manifest.json windows-manifest.json; do
  [ -f "$release/$name" ] || continue
  openssl dgst -sha256 -sign "$key" -out "$release/$name.sig.new" "$release/$name"
  if ! openssl dgst -sha256 -verify "$pub" -signature "$release/$name.sig.new" "$release/$name" >/dev/null 2>&1; then
    rm -f "$release/$name.sig.new"; echo "signature for $name does not verify with the public key; nothing written" >&2; exit 1
  fi
  mv -f "$release/$name.sig.new" "$release/$name.sig"; echo "signed $name"; signed=$((signed+1))
done
[ "$signed" -gt 0 ] || { echo 'no manifest.json or windows-manifest.json in the release directory' >&2; exit 2; }
cp "$pub" "$release/release-pubkey.pem"
echo "release-pubkey.pem written; $signed manifest(s) signed"
