#!/bin/bash
# Publish only the Windows preview and its website entry on the existing host.
# Keep stable macOS downloads, daemon configs and every running service intact.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo 'Run as root on the download host.' >&2; exit 2; }
release=${1:?Usage: deploy-windows-release.sh RELEASE_DIR WEBSITE_DIR VERSION}
site_source=${2:?}
version=${3:?}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 2
dl=/var/www/enana-dl
site=/opt/enana-cc/site
for dir in "$release" "$site_source" "$dl" "$site"; do
  [ -d "$dir" ] && [ ! -L "$dir" ] || exit 2
done
archive="enana-$version-windows.zip"
[ ! -e "$dl/$archive" ] || { echo 'Version already published; refusing replacement.' >&2; exit 2; }
mkdir -p /var/backups/enana/releases
exec 9>/var/backups/enana/windows-publish.lock
flock -n 9 || { echo 'Another Windows publication is running.' >&2; exit 2; }
python3 - "$release" "$site_source" "$version" <<'PY'
import hashlib,json,pathlib,sys,zipfile
release,site=map(pathlib.Path,sys.argv[1:3]); version=sys.argv[3]
m=json.loads((release/'windows-manifest.json').read_text())
name=f'enana-{version}-windows.zip'; package=release/name
assert m['platform']=='windows' and m['channel']=='preview' and m['version']==version
assert m['url']==f'/dl/{name}' and package.stat().st_size==m['size']
assert hashlib.sha256(package.read_bytes()).hexdigest()==m['sha256']
with zipfile.ZipFile(package) as z:
    assert all(not n.startswith('/') and '..' not in n.split('/') and ':' not in n for n in z.namelist())
    assert z.read(f'enana-{version}/VERSION').strip()==version.encode()
    assert z.read(f'enana-{version}/get.ps1')==(release/'get.ps1').read_bytes()
assert b'https://install.enana.cc/get.ps1' in (site/'index.html').read_bytes()
assert b'windows-manifest.json' in (site/'site.js').read_bytes()
print('Verified Windows package, bootstrap and website entry.')
PY
backup="/var/backups/enana/releases/windows-$version-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$backup/download" "$backup/site"; chmod 700 "$backup"
snapshot_services() {
  systemctl list-units --type=service --state=running --no-pager --plain --no-legend | awk '{print $1}' | sort | while read -r service; do
    systemctl show "$service" --property=Id,MainPID,ActiveEnterTimestamp
  done
}
snapshot_config() { find /etc/nginx /etc/systemd/system -type f -exec sha256sum {} + | sort; }
snapshot_macos() {
  local stable; stable=$(python3 -c 'import json,sys; print("enana-"+json.load(open(sys.argv[1]))["version"]+".tar.gz")' "$dl/manifest.json")
  [[ $stable =~ ^enana-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz$ ]] || return 1
  (cd "$dl"; sha256sum manifest.json VERSION CHANGELOG.md get.sh "$stable")
}
snapshot_services > "$backup/services.before"
snapshot_config > "$backup/config.before"
snapshot_macos > "$backup/macos.before"
for name in get.ps1 windows-manifest.json windows-CHANGELOG.md; do
  [ ! -e "$dl/$name" ] || cp -p "$dl/$name" "$backup/download/$name"
done
for name in index.html site.js; do cp -p "$site/$name" "$backup/site/$name"; done
committed=0
rollback() {
  rc=$?
  if [ "$committed" = 0 ]; then
    for name in get.ps1 windows-manifest.json windows-CHANGELOG.md; do
      if [ -e "$backup/download/$name" ]; then cp -p "$backup/download/$name" "$dl/$name"; else rm -f "$dl/$name"; fi
    done
    for name in index.html site.js; do cp -p "$backup/site/$name" "$site/$name"; done
    rm -f "$dl/$archive"
  fi
  rm -f "$dl/.enana-windows-publish-$$" "$site/.enana-windows-publish-$$"
  exit "$rc"
}
trap rollback EXIT
# Exact allowlist; publish the manifest after its immutable archive is present.
for name in "$archive" get.ps1 windows-CHANGELOG.md windows-manifest.json; do
  install -m 644 -o root -g root "$release/$name" "$dl/.enana-windows-publish-$$"
  mv -f "$dl/.enana-windows-publish-$$" "$dl/$name"
done
for name in index.html site.js; do
  install -m 644 -o root -g root "$site_source/$name" "$site/.enana-windows-publish-$$"
  mv -f "$site/.enana-windows-publish-$$" "$site/$name"
done
snapshot_services > "$backup/services.after"
snapshot_config > "$backup/config.after"
snapshot_macos > "$backup/macos.after"
cmp "$backup/services.before" "$backup/services.after"
cmp "$backup/config.before" "$backup/config.after"
cmp "$backup/macos.before" "$backup/macos.after"
committed=1
printf 'Published Windows %s preview. Stable macOS files, service PIDs and shared configs unchanged. Backup: %s\n' "$version" "$backup"
