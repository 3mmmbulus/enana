#!/bin/bash
# Isolated upgrade of the existing enana account service; no receiving switch,
# website download or other project's service/configuration is touched.
set -euo pipefail
[ "$(id -u)" = 0 ] || exit 2
source_dir=${1:?Usage: deploy-nodes.sh STAGED_REPOSITORY PRIVATE_SOURCE_CONFIG}
private_source=${2:?}
root=/opt/enana-cc
data=/var/lib/enana-cc/pb_data
nginx_file=$(readlink -f /etc/nginx/sites-enabled/zz-enana.cc.conf)
[ -x "$root/pocketbase" ] && [ -d "$data" ] && [ -f "$nginx_file" ] || exit 2
[ "$(systemctl show enana-pocketbase.service --property=User --value)" = enana ] || exit 2
python3 - "$private_source" <<'PY'
import json,sys,urllib.parse
d=json.load(open(sys.argv[1]));u=urllib.parse.urlparse(d['url'])
assert set(d)=={'url'} and u.scheme=='https' and u.hostname and not u.username
assert json.load(open('/etc/enana/billing.json'))['payments_enabled'] is False
print('Private source validated; receiving remains disabled.')
PY
mkdir -p /var/backups/enana/releases
exec 9>/var/backups/enana/nodes-publish.lock
flock -n 9 || exit 2
backup="/var/backups/enana/releases/nodes-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -m 700 "$backup"
snapshot_services() {
 systemctl list-units --type=service --state=running --no-pager --plain --no-legend | awk '$1!="enana-pocketbase.service" && $1!="enana-catalog-refresh.service" {print $1}' | sort | while read -r service; do systemctl show "$service" --property=Id,MainPID,ActiveEnterTimestamp; done
}
snapshot_configs() { find /etc/nginx /etc/systemd/system -type f ! -path "$nginx_file" ! -name enana-catalog-refresh.service ! -name enana-catalog-refresh.timer -exec sha256sum {} + | sort; }
snapshot_downloads() { find /var/www/enana-dl /var/www/enana-cloud -type f -exec sha256sum {} + | sort; }
snapshot_services > "$backup/services.before"
snapshot_configs > "$backup/configs.before"
snapshot_downloads > "$backup/downloads.before"
cp -a "$root/pb_hooks" "$root/pb_migrations" "$backup/"
cp -p "$nginx_file" "$backup/nginx.conf"
cp -p /etc/enana/billing.json "$backup/billing.json"
for name in admin catalog; do [ ! -e "$root/$name" ] || cp -a "$root/$name" "$backup/$name"; done
for name in enana-catalog-refresh.service enana-catalog-refresh.timer; do [ ! -e "/etc/systemd/system/$name" ] || cp -p "/etc/systemd/system/$name" "$backup/$name"; done
[ ! -e /etc/enana/official-source.json ] || cp -p /etc/enana/official-source.json "$backup/official-source.json"
# Validate the real source before stopping even the enana account service.
install -d -m 700 "$backup/preflight/catalog" "$backup/preflight/pb_hooks"
cp "$source_dir/ui/importer.js" "$backup/preflight/catalog/importer.js"
cp "$source_dir/server/pb_hooks/enana_nodes_domain.js" "$backup/preflight/pb_hooks/"
node - "$source_dir/server/catalog/refresh.js" "$private_source" "$backup/preflight" <<'JS'
require(process.argv[2]).refresh(process.argv[3],process.argv[4],'/unused',{validateOnly:true}).catch(()=>{console.error('Private source validation failed; no services stopped.');process.exitCode=1});
JS
committed=0;stopped=0;restarted=0
rollback() {
 rc=$?
 if [ "$committed" = 0 ] && [ "$stopped" = 1 ]; then
  systemctl stop enana-catalog-refresh.timer enana-catalog-refresh.service 2>/dev/null || true
  systemctl stop enana-pocketbase.service
  rm -rf "$root/pb_hooks" "$root/pb_migrations" "$root/admin" "$root/catalog"
  cp -a "$backup/pb_hooks" "$backup/pb_migrations" "$root/"
  for name in admin catalog; do [ ! -e "$backup/$name" ] || cp -a "$backup/$name" "$root/$name"; done
  # Before restart no public writes occurred. After restart retain financial
  # rows; the additive migration remains compatible with previous hooks.
  if [ "$restarted" = 0 ] && [ -d "$backup/pb_data" ]; then rm -rf "$data"; cp -a "$backup/pb_data" "$data"; fi
  cp -p "$backup/nginx.conf" "$nginx_file"
  for name in enana-catalog-refresh.service enana-catalog-refresh.timer; do
   if [ -e "$backup/$name" ]; then cp -p "$backup/$name" "/etc/systemd/system/$name"; else rm -f "/etc/systemd/system/$name"; fi
  done
  if [ -e "$backup/official-source.json" ]; then cp -p "$backup/official-source.json" /etc/enana/official-source.json; else rm -f /etc/enana/official-source.json; fi
  systemctl daemon-reload;systemctl start enana-pocketbase.service
  nginx -t && systemctl reload nginx
 fi
 exit "$rc"
}
trap rollback EXIT
systemctl stop enana-pocketbase.service;stopped=1
cp -a "$data" "$backup/pb_data"
install -d -m 755 -o root -g root "$root/admin" "$root/catalog"
for name in enana_lib.js enana_nodes.js enana_nodes.pb.js enana_nodes_domain.js; do install -m 644 -o root -g root "$source_dir/server/pb_hooks/$name" "$root/pb_hooks/$name"; done
install -m 644 -o root -g root "$source_dir/server/pb_migrations/1790000004_enana_nodes.js" "$root/pb_migrations/1790000004_enana_nodes.js"
install -m 644 -o root -g root "$source_dir/server/admin/nodes.pb.js" "$root/admin/nodes.pb.js"
install -m 644 -o root -g root "$source_dir/server/catalog/refresh.js" "$root/catalog/refresh.js"
install -m 644 -o root -g root "$source_dir/ui/importer.js" "$root/catalog/importer.js"
install -m 640 -o root -g enana "$private_source" /etc/enana/official-source.json
runuser -u enana -- "$root/pocketbase" migrate up --dir="$data" --hooksDir="$root/pb_hooks" --migrationsDir="$root/pb_migrations" --automigrate=false >/dev/null
python3 "$source_dir/server/update-nodes-nginx.py" "$nginx_file" "$backup/nginx.next"
install -m 644 -o root -g root "$backup/nginx.next" "$nginx_file"
cat > /etc/systemd/system/enana-catalog-refresh.service <<'UNIT'
[Unit]
Description=enana private official catalog refresh
After=network-online.target enana-pocketbase.service
[Service]
Type=oneshot
User=enana
Group=enana
ExecStart=/usr/bin/node /opt/enana-cc/catalog/refresh.js
TimeoutStartSec=60
UMask=0077
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=/var/lib/enana-cc
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
MemoryMax=256M
TasksMax=64
UNIT
cat > /etc/systemd/system/enana-catalog-refresh.timer <<'UNIT'
[Unit]
Description=Refresh enana official catalog every six hours
[Timer]
OnBootSec=10min
OnUnitActiveSec=6h
RandomizedDelaySec=5min
[Install]
WantedBy=timers.target
UNIT
nginx -t
systemctl daemon-reload
systemctl start enana-pocketbase.service;restarted=1
for attempt in 1 2 3 4 5; do curl -fsS --max-time 3 http://127.0.0.1:8090/api/health >/dev/null && break; [ "$attempt" != 5 ] || exit 1;sleep 1; done
systemctl start enana-catalog-refresh.service
systemctl enable --now enana-catalog-refresh.timer
systemctl reload nginx
cmp "$backup/billing.json" /etc/enana/billing.json
snapshot_services > "$backup/services.after"
snapshot_configs > "$backup/configs.after"
snapshot_downloads > "$backup/downloads.after"
cmp "$backup/services.before" "$backup/services.after"
cmp "$backup/configs.before" "$backup/configs.after"
cmp "$backup/downloads.before" "$backup/downloads.after"
committed=1
printf 'Official node delivery installed; receiving disabled, other services/downloads preserved. Backup: %s\n' "$backup"
