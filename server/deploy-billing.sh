#!/bin/bash
# Install the cloud billing foundation only. Downloads and local client modes
# are separate releases; no payment orders are accepted by this deployment.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo 'Run as root on the enana account host.' >&2; exit 2; }
source_dir=${1:?Usage: deploy-billing.sh STAGED_REPOSITORY PRIVATE_CONFIG}
private_config=${2:?}
root=/opt/enana-cc
data=/var/lib/enana-cc/pb_data
nginx_file=$(readlink -f /etc/nginx/sites-enabled/zz-enana.cc.conf)
[ -d "$data" ] && [ -x "$root/pocketbase" ] && [ -f "$nginx_file" ] || exit 2
[ "$(systemctl show enana-pocketbase.service --property=User --value)" = enana ] || exit 2
node -e 'if(Number(process.versions.node.split(".")[0])<18)process.exit(2)'
node - "$source_dir" "$private_config" <<'JS'
const fs=require('fs'),p=require('path'),[root,file]=process.argv.slice(2);
const c=JSON.parse(fs.readFileSync(file));require(p.join(root,'server/payments/tron.js')).validateAddresses(c.addresses);
if(c.payments_enabled!==false||typeof c.provider_key!=='string'||!c.provider_key||typeof c.scanner_secret!=='string'||c.scanner_secret.length<32)throw Error('private_configuration_invalid_or_receiving_enabled');
console.log('Private configuration validated; receiving stays disabled.');
JS
mkdir -p /var/backups/enana/releases
exec 9>/var/backups/enana/billing-publish.lock
flock -n 9 || { echo 'Another billing publication is running.' >&2; exit 2; }
backup="/var/backups/enana/releases/billing-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -m 700 "$backup"
snapshot_services() {
  systemctl list-units --type=service --state=running --no-pager --plain --no-legend | awk '$1!="enana-pocketbase.service" && $1!="enana-payments.service" {print $1}' | sort | while read -r service; do
    systemctl show "$service" --property=Id,MainPID,ActiveEnterTimestamp
  done
}
snapshot_other_configs() {
  find /etc/nginx /etc/systemd/system -type f ! -path "$nginx_file" ! -name enana-payments.service -exec sha256sum {} + | sort
}
snapshot_downloads() { find /var/www/enana-dl /var/www/enana-cloud -type f -exec sha256sum {} + | sort; }
snapshot_services > "$backup/services.before"
snapshot_other_configs > "$backup/other-configs.before"
snapshot_downloads > "$backup/downloads.before"
cp -a "$root/pb_hooks" "$root/pb_migrations" "$backup/"
cp -p "$nginx_file" "$backup/nginx.conf"
cp -p "$root/site/site.css" "$backup/site.css"
[ ! -e /etc/enana/billing.json ] || cp -p /etc/enana/billing.json "$backup/billing.json"
[ ! -e "$root/payments" ] || cp -a "$root/payments" "$backup/payments"
[ ! -e /etc/systemd/system/enana-payments.service ] || cp -p /etc/systemd/system/enana-payments.service "$backup/payments.service"
committed=0;stopped=0;database_saved=0
rollback() {
  rc=$?
  if [ "$committed" = 0 ] && [ "$stopped" = 1 ]; then
    if [ "$database_saved" = 0 ]; then
      systemctl start enana-pocketbase.service
      echo 'Deployment stopped before edits; original database retained.' >&2
      exit "$rc"
    fi
    systemctl stop enana-payments.service 2>/dev/null || true
    systemctl stop enana-pocketbase.service || true
    rm -rf "$root/pb_hooks" "$root/pb_migrations" "$data"
    cp -a "$backup/pb_hooks" "$backup/pb_migrations" "$root/"
    cp -a "$backup/pb_data" "$data"
    cp -p "$backup/nginx.conf" "$nginx_file"
    cp -p "$backup/site.css" "$root/site/site.css"
    rm -f "$root/site/verify.html" "$root/site/verify.js"
    if [ -f "$backup/billing.json" ]; then cp -p "$backup/billing.json" /etc/enana/billing.json; else rm -f /etc/enana/billing.json; fi
    rm -rf "$root/payments"
    [ ! -e "$backup/payments" ] || cp -a "$backup/payments" "$root/payments"
    if [ -f "$backup/payments.service" ]; then cp -p "$backup/payments.service" /etc/systemd/system/enana-payments.service; else systemctl disable enana-payments.service 2>/dev/null || true; rm -f /etc/systemd/system/enana-payments.service; fi
    systemctl daemon-reload
    systemctl start enana-pocketbase.service
    nginx -t && systemctl reload nginx
    echo "Billing deployment rolled back. Backup: $backup" >&2
  fi
  exit "$rc"
}
trap rollback EXIT
systemctl stop enana-pocketbase.service;stopped=1
cp -a "$data" "$backup/pb_data"
database_saved=1
install -d -m 750 -o root -g enana /etc/enana
install -m 640 -o root -g enana "$private_config" /etc/enana/billing.json
install -d -m 700 -o enana -g enana /var/lib/enana-cc/payments
install -d -m 755 -o root -g root "$root/payments"
for file in enana_billing.pb.js enana_billing.js enana_billing_domain.js; do
  install -m 644 -o root -g root "$source_dir/server/pb_hooks/$file" "$root/pb_hooks/$file"
done
# Add helper exports to the tracked original service; no account behavior changes.
install -m 644 -o root -g root "$source_dir/server/pb_hooks/enana_lib.js" "$root/pb_hooks/enana_lib.js"
install -m 644 -o root -g root "$source_dir/server/pb_migrations/1790000003_enana_billing.js" "$root/pb_migrations/1790000003_enana_billing.js"
for file in tron.js provider.js scanner.js; do install -m 644 -o root -g root "$source_dir/server/payments/$file" "$root/payments/$file"; done
install -m 644 -o root -g root "$source_dir/server/payments/enana-payments.service" /etc/systemd/system/enana-payments.service
runuser -u enana -- "$root/pocketbase" migrate up --dir="$data" --migrationsDir="$root/pb_migrations" --hooksDir="$root/pb_hooks" --hooksWatch=false --automigrate=false
python3 "$source_dir/server/update-nginx.py" "$nginx_file" "$backup/nginx.updated"
install -m 644 -o root -g root "$backup/nginx.updated" "$nginx_file"
for file in verify.html verify.js site.css; do install -m 644 -o root -g root "$source_dir/website/$file" "$root/site/$file"; done
nginx -t
systemctl daemon-reload
systemctl start enana-pocketbase.service
for attempt in 1 2 3 4 5; do
  if curl -fsS --max-time 3 http://127.0.0.1:8090/api/health >/dev/null; then break; fi
  [ "$attempt" != 5 ] || exit 1
  sleep 1
done
systemctl enable --now enana-payments.service
systemctl reload nginx
snapshot_services > "$backup/services.after"
snapshot_other_configs > "$backup/other-configs.after"
snapshot_downloads > "$backup/downloads.after"
cmp "$backup/services.before" "$backup/services.after"
cmp "$backup/other-configs.before" "$backup/other-configs.after"
cmp "$backup/downloads.before" "$backup/downloads.after"
committed=1
printf 'Billing foundation installed with receiving disabled. Other services and downloads preserved. Backup: %s\n' "$backup"
