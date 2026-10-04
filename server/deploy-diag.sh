#!/bin/bash
# Install the diagnostics upload (pb_hooks/enana_diag*.js + migration 1790000004 + two nginx locations) on the enana account host.
# Same procedure as deploy-billing.sh: stop PocketBase, keep a full backup, install the files, apply the migration, add the exact-path
# nginx locations, check, start, verify, reload nginx; any failure restores everything. Other services, configs and downloads are compared
# before/after and must be unchanged.
#   Usage: deploy-diag.sh STAGED_REPOSITORY            (as root; STAGED_REPOSITORY contains server/)
#          deploy-diag.sh --check STAGED_REPOSITORY    (read-only: validates the preconditions and the nginx edit, changes nothing)
set -euo pipefail
check_only=0
if [ "${1:-}" = --check ]; then check_only=1; shift; fi
source_dir=${1:?Usage: deploy-diag.sh [--check] STAGED_REPOSITORY}
[ "$(id -u)" = 0 ] || { echo 'Run as root on the enana account host.' >&2; exit 2; }
root=/opt/enana-cc
data=/var/lib/enana-cc/pb_data
nginx_file=$(readlink -f /etc/nginx/sites-enabled/zz-enana.cc.conf)
[ -d "$data" ] && [ -x "$root/pocketbase" ] && [ -f "$nginx_file" ] || { echo 'Unexpected host layout.' >&2; exit 2; }
[ "$(systemctl show enana-pocketbase.service --property=User --value)" = enana ] || { echo 'enana-pocketbase is not running as enana.' >&2; exit 2; }
files=(server/pb_hooks/enana_diag.js server/pb_hooks/enana_diag.pb.js server/pb_hooks/enana_lib.js server/pb_migrations/1790000004_enana_diag.js server/update-nginx-diag.py)
for f in "${files[@]}"; do [ -f "$source_dir/$f" ] || { echo "Missing $source_dir/$f" >&2; exit 2; }; done
[ ! -e "$root/pb_hooks/enana_diag.js" ] && [ ! -e "$root/pb_migrations/1790000004_enana_diag.js" ] || { echo 'Diagnostics upload is already installed; review instead of overwriting.' >&2; exit 2; }
python3 "$source_dir/server/update-nginx-diag.py" "$nginx_file" /tmp/enana-nginx-diag.check
trap 'rm -f /tmp/enana-nginx-diag.check' EXIT
if [ "$check_only" = 1 ]; then
  echo "Preconditions OK. The nginx edit would add exactly:"; diff -u "$nginx_file" /tmp/enana-nginx-diag.check | grep '^[+-]' | grep -v '^+++\|^---' || true
  exit 0
fi
mkdir -p /var/backups/enana/releases
exec 9>/var/backups/enana/diag-publish.lock
flock -n 9 || { echo 'Another diagnostics publication is running.' >&2; exit 2; }
backup="/var/backups/enana/releases/diag-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -m 700 "$backup"
snapshot_services() {
  systemctl list-units --type=service --state=running --no-pager --plain --no-legend | awk '$1!="enana-pocketbase.service" {print $1}' | sort | while read -r service; do
    systemctl show "$service" --property=Id,MainPID,ActiveEnterTimestamp
  done
}
snapshot_other_configs() { find /etc/nginx /etc/systemd/system -type f ! -path "$nginx_file" -exec sha256sum {} + | sort; }
snapshot_downloads() { find /var/www/enana-dl /var/www/enana-cloud -type f -exec sha256sum {} + | sort; }
snapshot_services > "$backup/services.before"
snapshot_other_configs > "$backup/other-configs.before"
snapshot_downloads > "$backup/downloads.before"
cp -a "$root/pb_hooks" "$root/pb_migrations" "$backup/"
cp -p "$nginx_file" "$backup/nginx.conf"
committed=0; stopped=0; database_saved=0
rollback() {
  rc=$?
  if [ "$committed" = 0 ] && [ "$stopped" = 1 ]; then
    if [ "$database_saved" = 0 ]; then
      systemctl start enana-pocketbase.service
      echo 'Deployment stopped before edits; original database retained.' >&2
      exit "$rc"
    fi
    systemctl stop enana-pocketbase.service || true
    rm -rf "$root/pb_hooks" "$root/pb_migrations" "$data"
    cp -a "$backup/pb_hooks" "$backup/pb_migrations" "$root/"
    cp -a "$backup/pb_data" "$data"
    cp -p "$backup/nginx.conf" "$nginx_file"
    systemctl start enana-pocketbase.service
    nginx -t && systemctl reload nginx
    echo "Diagnostics deployment rolled back. Backup: $backup" >&2
  fi
  exit "$rc"
}
trap rollback EXIT
systemctl stop enana-pocketbase.service; stopped=1
cp -a "$data" "$backup/pb_data"
database_saved=1
for f in enana_diag.js enana_diag.pb.js enana_lib.js; do install -m 644 -o root -g root "$source_dir/server/pb_hooks/$f" "$root/pb_hooks/$f"; done
install -m 644 -o root -g root "$source_dir/server/pb_migrations/1790000004_enana_diag.js" "$root/pb_migrations/1790000004_enana_diag.js"
runuser -u enana -- "$root/pocketbase" migrate up --dir="$data" --migrationsDir="$root/pb_migrations" --hooksDir="$root/pb_hooks" --hooksWatch=false --automigrate=false
python3 "$source_dir/server/update-nginx-diag.py" "$nginx_file" "$backup/nginx.updated"
install -m 644 -o root -g root "$backup/nginx.updated" "$nginx_file"
nginx -t
systemctl start enana-pocketbase.service
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if curl -fsS --max-time 3 http://127.0.0.1:8090/api/health >/dev/null; then break; fi
  [ "$attempt" != 10 ] || { echo 'PocketBase did not become healthy.' >&2; exit 1; }
  sleep 1
done
# The new routes must exist in the backend (401 = reached the handler and refused for lack of a session) before nginx exposes them.
[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:8090/api/enana/v1/diag)" = 401 ] || { echo 'The diagnostics route is not served by PocketBase.' >&2; exit 1; }
[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST http://127.0.0.1:8090/api/enana/v1/diag/full)" = 401 ] || { echo 'The full-diagnostics route is not served by PocketBase.' >&2; exit 1; }
python3 - "$data/data.db" <<'PY'
import sqlite3,sys
c=sqlite3.connect('file:%s?mode=ro'%sys.argv[1],uri=True)
assert c.execute("select count(*) from _collections where name='diag_reports'").fetchone()[0]==1,'diag_reports collection is missing'
print('diag_reports collection present.')
PY
# Existing endpoints must still answer exactly as before.
[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8090/api/enana/v1/plan)" = 401 ] || { echo 'Existing /plan endpoint changed behavior.' >&2; exit 1; }
systemctl reload nginx
snapshot_services > "$backup/services.after"
snapshot_other_configs > "$backup/other-configs.after"
snapshot_downloads > "$backup/downloads.after"
cmp "$backup/services.before" "$backup/services.after"
cmp "$backup/other-configs.before" "$backup/other-configs.after"
cmp "$backup/downloads.before" "$backup/downloads.after"
committed=1
printf 'Diagnostics upload installed. Other services, configs and downloads preserved. Backup: %s\n' "$backup"
