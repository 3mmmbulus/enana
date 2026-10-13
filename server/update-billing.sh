#!/bin/bash
# Update the membership billing hooks and their schema migrations on an enana account host where deploy-billing.sh
# has already run. Do NOT run deploy-billing.sh again on such a host (its nginx step refuses an already updated
# configuration and rolls back); update-official.sh does not touch the billing files.
#
#   update-billing.sh [--check] STAGED_REPOSITORY
#
# What it does, in order, and what it refuses:
#   * refuses unless it runs as root, billing is already deployed (hooks + migration 1790000003), PocketBase runs as
#     the service user and is healthy now, node >= 18 and python3 are present, every staged file exists, the staged
#     hooks and migrations parse, no installed billing migration differs from the staged one (an applied migration
#     is never rewritten) and, when something would be installed, the backup filesystem has room for a copy of the
#     data directory and the migrations plus a margin (10 % + 256 MiB), so that the copy can never fill the disk
#     under the service it restarts;
#   * --check validates all of that and prints what would change; it changes nothing;
#   * takes the lock shared with deploy-billing.sh and update-official.sh and backs up the billing hooks it replaces
#     and the whole pb_migrations directory (/var/backups/enana/releases/billing-update-<UTC time>-<pid>, mode 700);
#   * stops enana-payments.service (when it runs) and then PocketBase, so that no receipt is settled while the
#     database is copied or could be replaced by a rollback; copies the stopped PocketBase data directory into the
#     backup (a consistent copy, like deploy-billing.sh);
#   * installs enana_billing.pb.js, enana_billing.js, enana_billing_domain.js and the billing migrations
#     (1790000004_billing_lease.js, 1790000006_billing_amount.js) as 644 root:root through a temp file + mv, runs
#     `pocketbase migrate up` as the service user, checks the migrated schema offline (read-only), starts PocketBase,
#     waits for /api/health, checks that the billing routes are served (401 without a session, never 404/5xx) and
#     that every other running service and the nginx/systemd files are unchanged; only then, as the last step, it
#     starts the payments scanner again (if it was running) and checks that it is back;
#   * on ANY failure after the first change it stops the scanner first (it may already have been started again),
#     then PocketBase, restores the hooks from the backup, starts PocketBase (and the scanner, if it was running)
#     again and exits non-zero. The data directory and the migrations directory are restored from the copy, together,
#     only when PocketBase has not been started on the migrated database yet. From that start on the live database is
#     kept with its migration files: it may hold orders, sign-ups, sessions and settled receipts that a restore would
#     delete (the scanner would never send those receipts again), and the previous hooks run on it (the new migration
#     only widens a bound).
#     A data copy that failed half-way (a full disk) is removed from the backup.
#     Nothing is committed until all checks passed.
# It never reads or writes /etc/enana/billing.json (the receiving switch), never touches nginx, the website, the
# scanner files or the downloads, and prints no secret (only file names, counts, HTTP codes and the backup path).
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: update-billing.sh [--check] STAGED_REPOSITORY
  --check        validate everything and print what would change; change nothing
Run as root on the enana account host (where deploy-billing.sh already ran).
EOF
  exit 2
}
die() { echo "update-billing: $*" >&2; exit 2; }
note() { printf '%s\n' "$*"; }

mode=install; src=''
while [ $# -gt 0 ]; do
  case $1 in
    --check) mode=check ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) [ -z "$src" ] || usage; src=$1 ;;
  esac
  shift
done
[ -n "$src" ] || usage
[ "$(id -u)" = 0 ] || die 'Run as root on the enana account host.'

# Locations. The defaults are the production layout; the overrides exist for the test suite.
root=${ENANA_ROOT:-/opt/enana-cc}
data=${ENANA_DATA:-/var/lib/enana-cc/pb_data}
backups=${ENANA_BACKUP_ROOT:-/var/backups/enana}
api=${ENANA_API:-http://127.0.0.1:8090}
svc_user=${ENANA_USER:-enana}
unit=${ENANA_UNIT:-enana-pocketbase.service}
wait_s=${ENANA_HEALTH_WAIT:-30}
payments=enana-payments.service
hooks=$root/pb_hooks
migs=$root/pb_migrations
hook_files=(enana_billing.pb.js enana_billing.js enana_billing_domain.js)
mig_files=(1790000004_billing_lease.js 1790000006_billing_amount.js)

ensure_backup_dir() { [ -d "$backups" ] || install -d -m 700 "$backups"; [ -d "$backups/releases" ] || install -d -m 700 "$backups/releases"; }
healthy() { curl -fsS --max-time 3 "$api/api/health" >/dev/null 2>&1; }
wait_healthy() { local _; for _ in $(seq 1 "$wait_s"); do healthy && return 0; sleep 1; done; return 1; }
http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" 2>/dev/null || true; }

# ------------------------------------------------------------------------------------------- checks
[ -d "$src/server/pb_hooks" ] && [ -d "$src/server/pb_migrations" ] || die "$src is not a staged enana repository (server/pb_hooks or server/pb_migrations missing)."
for f in "${hook_files[@]}"; do [ -f "$src/server/pb_hooks/$f" ] || die "staged file missing: server/pb_hooks/$f"; done
for f in "${mig_files[@]}"; do [ -f "$src/server/pb_migrations/$f" ] || die "staged file missing: server/pb_migrations/$f"; done
command -v node >/dev/null || die 'node >= 18 is required.'
node -e 'if(Number(process.versions.node.split(".")[0])<18)process.exit(2)' || die 'node >= 18 is required.'
command -v python3 >/dev/null || die 'python3 is required (read-only schema check).'

for f in enana_billing.pb.js enana_v1.pb.js enana_lib.js; do
  [ -f "$hooks/$f" ] || die "$hooks/$f is missing: billing is not deployed here. Run deploy-billing.sh first (initial deployment only)."
done
[ -f "$migs/1790000003_enana_billing.js" ] || die 'the billing migration file is missing: billing is not deployed here.'
[ -d "$data" ] && [ -f "$data/data.db" ] || die "$data/data.db is missing: unexpected host layout."
[ -x "$root/pocketbase" ] || die "$root/pocketbase is missing: unexpected host layout."
[ "$(systemctl show "$unit" --property=User --value)" = "$svc_user" ] || die "$unit does not run as $svc_user."
healthy || die "PocketBase is not healthy now ($api/api/health). Refusing to touch a service that is already failing."

# The staged files must at least parse (PocketBase runs them with ES6 support; this catches typos and truncation),
# and the pure domain module must load and keep the published amount rules.
for f in "${hook_files[@]}"; do node --check "$src/server/pb_hooks/$f" 2>/dev/null || die "staged file does not parse: server/pb_hooks/$f"; done
for f in "${mig_files[@]}"; do node --check "$src/server/pb_migrations/$f" 2>/dev/null || die "staged file does not parse: server/pb_migrations/$f"; done
node - "$src/server/pb_hooks/enana_billing_domain.js" 2>/dev/null <<'JS' || die 'the staged domain module does not load or breaks the amount rules (base price first, at most 999 tails up to +0.999).'
const D = require(require('path').resolve(process.argv[2])), M = 1000000
const a = D.allocate(4 * M, ['A'], [], 0), b = D.allocate(4 * M, ['A'], [{ address: 'A', amount: 4 * M, lease_until: 10, status: 'pending' }], 0)
if (a.amount !== 4 * M || b.amount !== 4 * M + 100000 || D.TAILS.length !== 999 || Math.max(...D.TAILS) !== 999000 || D.TAIL_SPAN !== 999000) process.exit(1)
JS

changed=()
for f in "${hook_files[@]}"; do
  if [ ! -e "$hooks/$f" ]; then note "  new        pb_hooks/$f"; changed+=("pb_hooks/$f")
  elif cmp -s "$src/server/pb_hooks/$f" "$hooks/$f"; then note "  unchanged  pb_hooks/$f"
  else
    add=$(diff "$hooks/$f" "$src/server/pb_hooks/$f" | grep -c '^>' || true); del=$(diff "$hooks/$f" "$src/server/pb_hooks/$f" | grep -c '^<' || true)
    note "  changed    pb_hooks/$f (+$add -$del lines; review with: diff -u $hooks/$f $src/server/pb_hooks/$f)"; changed+=("pb_hooks/$f")
  fi
done
new_migs=()
for f in "${mig_files[@]}"; do
  if [ ! -e "$migs/$f" ]; then note "  new        pb_migrations/$f (applied by this update)"; changed+=("pb_migrations/$f"); new_migs+=("$f")
  elif cmp -s "$src/server/pb_migrations/$f" "$migs/$f"; then note "  unchanged  pb_migrations/$f"
  else die "$migs/$f differs from the staged file. An installed migration may already be applied and is never rewritten; review: diff -u $migs/$f $src/server/pb_migrations/$f"
  fi
done

# The backup takes a full copy of the data directory (earlier backups are never pruned). Refuse before anything is
# stopped unless the backup filesystem has room for it plus a margin, so that the copy cannot fill the disk under the
# service it restarts. The margin also leaves PocketBase room to write once it runs again.
if [ ${#changed[@]} -gt 0 ]; then
  space_dir=$backups; while [ ! -d "$space_dir" ]; do space_dir=$(dirname "$space_dir"); done
  need_kb=$({ du -sk "$data" "$migs" 2>/dev/null || true; } | awk '{s += $1} END {print s + 0}')
  free_kb=$({ df -Pk "$space_dir" 2>/dev/null || true; } | awk 'NR == 2 {print $4}')
  margin_kb=$(( need_kb / 10 + 262144 ))
  [ "$need_kb" -gt 0 ] && [[ $free_kb =~ ^[0-9]+$ ]] || die "cannot measure the size of $data or the free space under $space_dir; nothing was changed."
  [ "$free_kb" -ge $(( need_kb + margin_kb )) ] || die "not enough free space for the backup under $space_dir: $free_kb KiB free, the copy of $data and $migs needs $need_kb KiB plus a $margin_kb KiB margin. Free space (earlier backups are under $backups/releases) and run again; nothing was changed."
fi

if [ "$mode" = check ]; then
  if [ ${#changed[@]} -eq 0 ]; then note 'Check passed: the billing files are already up to date; nothing would be restarted.'
  else note "Check passed: ${#changed[@]} file(s) would be installed; $payments (if running) and $unit would be stopped, the database backed up ($need_kb KiB; $free_kb KiB free under $space_dir) and migrated, PocketBase started and checked, and the scanner started again last. Nothing was changed."; fi
  exit 0
fi
if [ ${#changed[@]} -eq 0 ]; then
  note 'The billing files are already up to date; nothing was restarted.'
  exit 0
fi

# ------------------------------------------------------------------------------------------- install
ensure_backup_dir
exec 9>"$backups/billing-publish.lock"
flock -n 9 || die 'Another billing publication is running.'
backup="$backups/releases/billing-update-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -m 700 "$backup" "$backup/pb_hooks"
for f in "${hook_files[@]}"; do
  if [ -e "$hooks/$f" ]; then cp -p "$hooks/$f" "$backup/pb_hooks/$f"; echo "$f existing" >> "$backup/MANIFEST"; else echo "$f absent" >> "$backup/MANIFEST"; fi
done
cp -a "$migs" "$backup/pb_migrations"

watch_dirs=(); for d in /etc/nginx /etc/systemd/system; do [ -d "$d" ] && watch_dirs+=("$d"); done
snapshot_services() {
  systemctl list-units --type=service --state=running --no-pager --plain --no-legend | awk -v a="$unit" -v b="$payments" '$1!=a && $1!=b {print $1}' | sort | while read -r service; do
    systemctl show "$service" --property=Id,MainPID,ActiveEnterTimestamp
  done
}
snapshot_configs() { { [ ${#watch_dirs[@]} -eq 0 ] || find "${watch_dirs[@]}" -type f -exec sha256sum {} + 2>/dev/null || true; } | sort; }
snapshot_services > "$backup/services.before"
snapshot_configs > "$backup/configs.before"
pay_before=$(systemctl is-active "$payments" 2>/dev/null || true)

pay_stopped=0; stopped=0; database_saved=0; served=0; committed=0
restore_hooks() {
  local f state
  while read -r f state; do
    if [ "$state" = existing ]; then cp -p "$backup/pb_hooks/$f" "$hooks/$f"; else rm -f "$hooks/$f"; fi
  done < "$backup/MANIFEST"
  rm -f "$hooks"/.enana_billing*.new
}
rollback() {
  local rc=$? pay_down=1 pb_down=1 what
  trap - EXIT
  set +e                             # attempt every restore step even if one of them fails
  [ "$rc" != 0 ] || rc=1
  if [ "$committed" = 0 ] && { [ "$stopped" = 1 ] || [ "$pay_stopped" = 1 ]; }; then
    echo "update-billing: FAILED (exit $rc); restoring the previous state." >&2
    # The scanner first, before anything is put back: its start is the last step, so it may be running again, and no
    # receipt may be settled into files or a database that are being restored.
    if [ "$pay_stopped" = 1 ]; then systemctl stop "$payments" 9>&- || pay_down=0; fi
    if [ "$stopped" = 1 ]; then
      systemctl stop "$unit" 9>&- || pb_down=0
      if [ "$database_saved" = 0 ]; then
        # The copy failed (typically a full disk) before anything was installed. A partial copy must not stay behind:
        # PocketBase would come back on a disk that the backup filled.
        what='the previous hooks, migrations and database (nothing had been installed yet)'
        if [ -n "$backup" ] && [ -e "$backup/pb_data" ]; then
          if rm -rf "$backup/pb_data"; then echo "Removed the incomplete database copy from $backup." >&2
          else echo "COULD NOT REMOVE THE INCOMPLETE DATABASE COPY $backup/pb_data; remove it to free the disk." >&2; fi
        fi
      else
        restore_hooks
        # The migrations directory goes back only together with the database, so that every migration the database
        # records as applied always has its file.
        if [ "$served" = 1 ]; then
          # PocketBase was started on the migrated database: it may have taken orders, sign-ups, sessions and settled
          # receipts since. Replacing it with the copy would delete them (an order lost this way frees its address and
          # amount for another user; a lost receipt is never sent again by the scanner). The previous hooks run on
          # the migrated database (the new migration only widens a bound), and its migration files stay installed.
          what="the previous hooks on the migrated database (its migration files stay installed). The database was kept, because PocketBase served on it after the update; never restore the copy taken before the update ($backup/pb_data) over it"
        elif [ "$pay_down" = 1 ] && [ "$pb_down" = 1 ] && [ -n "$data" ] && [ -d "$backup/pb_data" ]; then
          rm -rf "$migs" && cp -a "$backup/pb_migrations" "$migs"
          rm -rf "$data" && cp -a "$backup/pb_data" "$data"
          what='the previous hooks, migrations and database'
        else
          what="the previous hooks only. THE DATABASE AND MIGRATIONS WERE NOT RESTORED because $payments or $unit did not stop; the copy taken before the update is $backup/pb_data"
        fi
      fi
      systemctl start "$unit" 9>&- || true
      if wait_healthy; then echo "Rolled back. $unit is healthy again with $what. Backup: $backup" >&2
      else echo "ROLLED BACK BUT $unit IS NOT HEALTHY ($what). Inspect: journalctl -u $unit -n 80; backup: $backup" >&2; fi
    fi
    if [ "$pay_stopped" = 1 ]; then
      systemctl start "$payments" 9>&- || true
      [ "$(systemctl is-active "$payments" 2>/dev/null || true)" = active ] || echo "$payments did not start again. Inspect: journalctl -u $payments -n 80" >&2
    fi
  fi
  exit "$rc"
}
trap rollback EXIT

# No receipt may be settled into a database that is being copied or that a rollback would replace.
# The flags are set first: if a stop fails half-way, the rollback still starts the service again.
if [ "$pay_before" = active ]; then pay_stopped=1; systemctl stop "$payments" 9>&-; note "Stopped $payments for the update."; fi
stopped=1; systemctl stop "$unit" 9>&-
cp -a "$data" "$backup/pb_data"    # a failure here (a full disk) makes the rollback remove the partial copy
database_saved=1

for rel in "${changed[@]}"; do
  dst=$root/$rel; tmp=${dst%/*}/.${dst##*/}.new
  cp "$src/server/$rel" "$tmp"
  chown root:root "$tmp"; chmod 644 "$tmp"
  mv -f "$tmp" "$dst"
  cmp -s "$src/server/$rel" "$dst" || { echo "installed $rel differs from the staged file." >&2; exit 1; }
done
runuser -u "$svc_user" -- "$root/pocketbase" migrate up --dir="$data" --migrationsDir="$migs" --hooksDir="$hooks" --hooksWatch=false --automigrate=false 9>&-

# Read-only check of the migrated schema while PocketBase is still stopped (no request has been served yet). It runs as
# the service user: opening a WAL database may create its -shm/-wal files, which must never end up owned by root.
runuser -u "$svc_user" -- python3 -I - "$data/data.db" 9>&- <<'PY' || { echo 'the migrated billing schema is not what this release needs.' >&2; exit 1; }
import json, pathlib, sqlite3, sys
c = sqlite3.connect(pathlib.Path(sys.argv[1]).resolve().as_uri() + '?mode=ro', uri=True)
row = c.execute("select fields, indexes from _collections where name = 'billing_orders'").fetchone()
assert row, 'billing_orders collection is missing'
fields = {f.get('name'): f for f in json.loads(row[0] or '[]')}
assert fields.get('amount', {}).get('max') == 1000999000, 'billing_orders.amount does not accept 1000.999 USDT (migration 1790000006)'
assert 'pay_by' in fields and 'manual' in (fields.get('status', {}).get('values') or []), '24-hour lease fields are missing (migration 1790000004)'
assert 'idx_order_quote' not in (row[1] or ''), 'the old permanent (address, amount) index is still present'
print('Schema checked: amounts up to 1000.999 USDT, 24-hour leases, no permanent (address, amount) index.')
PY

# From the start on PocketBase may serve requests on the migrated database, and a rollback keeps that database (see
# rollback). The flag is set first: a start that fails half-way may already have served.
served=1
systemctl start "$unit" 9>&-      # the lock descriptor must not leak into anything the start spawns
wait_healthy || { echo "$unit did not become healthy after the start." >&2; exit 1; }

# The billing routes are served by the new hooks: without a session every one of them refuses with 401 (404 = the
# routes are not registered, 5xx = a hook module does not load). The operator queue is superuser-only (401/403).
c=$(http_code "$api/api/enana/v1/billing"); [ "$c" = 401 ] || { echo "GET billing answered HTTP ${c:-none} (expected 401); the new hooks did not load." >&2; exit 1; }
c=$(http_code "$api/api/enana/v1/billing?orders_page=2&orders_per_page=10"); [ "$c" = 401 ] || { echo "GET billing with paging answered HTTP ${c:-none} (expected 401)." >&2; exit 1; }
for r in billing/checkout billing/auto-renew; do
  c=$(http_code -X POST -H 'Content-Type: application/json' -d '{}' "$api/api/enana/v1/$r"); [ "$c" = 401 ] || { echo "POST $r answered HTTP ${c:-none} (expected 401); the new hooks did not load." >&2; exit 1; }
done
c=$(http_code "$api/api/enana/admin/billing/manual"); case $c in 401|403) ;; *) echo "the billing operator route answered HTTP ${c:-none}; the new hooks did not load." >&2; exit 1 ;; esac
c=$(http_code "$api/api/enana/v1/plan"); [ "$c" = 401 ] || { echo "the existing plan route answered HTTP ${c:-none} (expected 401)." >&2; exit 1; }

# Every check that can still fail runs before the scanner is started again, so that its start is the last step.
snapshot_services > "$backup/services.after"
snapshot_configs > "$backup/configs.after"
cmp -s "$backup/services.before" "$backup/services.after" || { echo 'another running service changed during the update.' >&2; exit 1; }
cmp -s "$backup/configs.before" "$backup/configs.after" || { echo 'an nginx/systemd file changed during the update.' >&2; exit 1; }

# The last step: the scanner settles receipts again (it rereads the receive history, so transfers made during the
# update are settled now). If it does not come back, the rollback stops it before restoring anything and keeps the
# database it may already have written to.
if [ "$pay_stopped" = 1 ]; then systemctl start "$payments" 9>&-; fi
pay_after=$(systemctl is-active "$payments" 2>/dev/null || true)
[ "$pay_before" = "$pay_after" ] || { echo "$payments changed state ($pay_before -> $pay_after)." >&2; exit 1; }

committed=1
trap - EXIT
note "Installed ${#changed[@]} file(s)${new_migs[0]+; applied ${new_migs[*]}}; $unit restarted and healthy; billing routes answer; other services and nginx/systemd files unchanged; $payments ${pay_after:-unknown} as before."
note "Backup (hooks, migrations, database copy): $backup"
