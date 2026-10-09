#!/bin/bash
# Publish the stable macOS client only. Keep Windows downloads, every daemon
# and shared host configuration unchanged; never restart any host project.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo 'Run as root on the download host.' >&2; exit 2; }
release=${1:?Usage: deploy-macos-release.sh RELEASE_DIR VERSION}
version=${2:?}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 2
dl=/var/www/enana-dl
[ -d "$release" ] && [ ! -L "$release" ] && [ -d "$dl" ] && [ ! -L "$dl" ] || exit 2
archive="enana-$version.tar.gz"
[ ! -e "$dl/$archive" ] || { echo 'Version already published; refusing replacement.' >&2; exit 2; }
mkdir -p /var/backups/enana/releases
exec 9>/var/backups/enana/macos-publish.lock
flock -n 9 || exit 2
[ -f "$release/manifest.json.sig" ] && [ -f "$release/release-pubkey.pem" ] || { echo 'Missing manifest.json.sig or release-pubkey.pem: run tools/sign-release.sh first.' >&2; exit 2; }
openssl dgst -sha256 -verify "$release/release-pubkey.pem" -signature "$release/manifest.json.sig" "$release/manifest.json" >/dev/null 2>&1 || { echo 'manifest.json signature does not verify; refusing to publish.' >&2; exit 2; }
python3 - "$release" "$version" <<'PY'
import hashlib,json,pathlib,sys,tarfile
r=pathlib.Path(sys.argv[1]);v=sys.argv[2];m=json.loads((r/'manifest.json').read_text());a=r/f'enana-{v}.tar.gz'
assert m['version']==v and m['url']==f'/dl/{a.name}' and m['size']==a.stat().st_size
assert m['sha256']==hashlib.sha256(a.read_bytes()).hexdigest()
assert (r/'VERSION').read_text().strip()==v
with tarfile.open(a) as t:
    assert all(not e.issym() and not e.islnk() and not e.name.startswith('/') and '..' not in e.name.split('/') for e in t)
    assert t.extractfile(f'enana-{v}/VERSION').read().strip()==v.encode()
    assert t.extractfile(f'enana-{v}/get.sh').read()==(r/'get.sh').read_bytes()
print('Verified stable macOS archive and installer.')
PY
backup="/var/backups/enana/releases/macos-$version-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$backup/download"; chmod 700 "$backup"
snapshot_services() {
  systemctl list-units --type=service --state=running --no-pager --plain --no-legend | awk '{print $1}' | sort | while read -r service; do
    systemctl show "$service" --property=Id,MainPID,ActiveEnterTimestamp
  done
}
snapshot_config() { find /etc/nginx /etc/systemd/system -type f -exec sha256sum {} + | sort; }
snapshot_other_downloads() {
  (cd "$dl"; find . -maxdepth 1 -type f ! -name manifest.json ! -name manifest.json.sig ! -name VERSION ! -name CHANGELOG.md ! -name get.sh ! -name "$archive" ! -name '.enana-macos-publish-*' -exec sha256sum {} + | sort)
}
snapshot_services > "$backup/services.before"
snapshot_config > "$backup/config.before"
snapshot_other_downloads > "$backup/other-downloads.before"
for name in manifest.json manifest.json.sig VERSION CHANGELOG.md get.sh; do [ ! -e "$dl/$name" ] || cp -p "$dl/$name" "$backup/download/$name"; done
committed=0
rollback() {
  rc=$?
  if [ "$committed" = 0 ]; then
    for name in manifest.json manifest.json.sig VERSION CHANGELOG.md get.sh; do
      if [ -e "$backup/download/$name" ]; then cp -p "$backup/download/$name" "$dl/$name"; else rm -f "$dl/$name"; fi
    done
    rm -f "$dl/$archive"
  fi
  rm -f "$dl/.enana-macos-publish-$$"
  exit "$rc"
}
trap rollback EXIT
for name in "$archive" get.sh CHANGELOG.md VERSION manifest.json.sig manifest.json; do   # 签名先于清单: 线上的清单和签名始终配套
  install -m 644 -o root -g root "$release/$name" "$dl/.enana-macos-publish-$$"
  mv -f "$dl/.enana-macos-publish-$$" "$dl/$name"
done
snapshot_services > "$backup/services.after"
snapshot_config > "$backup/config.after"
snapshot_other_downloads > "$backup/other-downloads.after"
cmp "$backup/services.before" "$backup/services.after"
cmp "$backup/config.before" "$backup/config.after"
cmp "$backup/other-downloads.before" "$backup/other-downloads.after"
committed=1
printf 'Published stable macOS %s. Windows downloads, all service PIDs and shared configs unchanged. Backup: %s\n' "$version" "$backup"
