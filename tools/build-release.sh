#!/bin/bash
# Build the public client download only; never include local state or cloud keys.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd -P)
out=${1:?Usage: bash tools/build-release.sh OUTPUT_DIRECTORY}
version=$(tr -d '[:space:]' < "$repo/VERSION")
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 2
mkdir -p "$out"; out=$(cd "$out" && pwd -P)
[ "$out" != "$repo" ] || exit 2
stage=$(mktemp -d); trap 'rm -rf "$stage"' EXIT
bundle="enana-$version"; mkdir "$stage/$bundle"
for name in install.sh lib data ui VERSION CHANGELOG.md get.sh LICENSE THIRD_PARTY_NOTICES.md; do
  [ ! -e "$repo/$name" ] || cp -R "$repo/$name" "$stage/$bundle/$name"
done
COPYFILE_DISABLE=1 tar -C "$stage" -czf "$out/$bundle.tar.gz" "$bundle"
sum=$(shasum -a 256 "$out/$bundle.tar.gz" | awk '{print $1}')
size=$(wc -c < "$out/$bundle.tar.gz" | tr -d ' ')
printf '{"version":"%s","sha256":"%s","size":%s,"url":"/dl/%s.tar.gz","released":"%s"}\n' \
  "$version" "$sum" "$size" "$bundle" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$out/manifest.json"
cp "$repo/VERSION" "$repo/CHANGELOG.md" "$repo/get.sh" "$out/"
chmod 644 "$out/$bundle.tar.gz" "$out/manifest.json" "$out/VERSION" "$out/CHANGELOG.md" "$out/get.sh"
printf 'Built %s (%s bytes), SHA-256 %s\n' "$bundle" "$size" "$sum"
