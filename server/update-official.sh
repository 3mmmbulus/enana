#!/bin/bash
# Install or refresh the official route-node hooks on an enana account host where deploy-billing.sh has
# already run. Do NOT run deploy-billing.sh again on such a host (its nginx step refuses an already updated
# configuration and rolls back).
#
#   update-official.sh [--check] STAGED_REPOSITORY      install / refresh the four hooks and restart PocketBase
#   update-official.sh --set-source [--id ID] STAGED_REPOSITORY
#                                                        type a source URL (hidden) into /etc/enana/official.json
#   update-official.sh --sync                            fetch the sources now (asks for the PocketBase superuser;
#                                                        exit 3 when a source failed to fetch)
#
# What the install does, in order, and what it refuses:
#   * refuses unless billing is already deployed, PocketBase is healthy now, node >= 18 is present, the staged
#     hooks parse, and an existing /etc/enana/official.json is structurally valid (its contents are never printed);
#   * takes the same lock as deploy-billing.sh, backs up the hook files it replaces and official.json
#     (/var/backups/enana/releases/official-<UTC time>, mode 700);
#   * replaces only enana_lib.js, enana_official.pb.js, enana_official.js, enana_official_domain.js;
#     it touches no migration, no database, no nginx or systemd file, no payment setting and no download file;
#   * restarts only enana-pocketbase.service, waits for /api/health, checks that the operator routes are
#     registered (401/403, not 404), that every other running service and the nginx/systemd files are unchanged
#     and that enana-payments.service kept its state;
#   * on ANY failure after the first change it restores the backed-up files, restarts PocketBase again and exits
#     non-zero. Nothing is committed until all checks passed.
# Nothing here enables receiving payments; that switch (/etc/enana/billing.json) is not read or written.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: update-official.sh [--check] STAGED_REPOSITORY
       update-official.sh --set-source [--id ID] STAGED_REPOSITORY
       update-official.sh --sync
  --check        validate everything and print what would change; change nothing
  --set-source   read one source URL without echo and store it in /etc/enana/official.json (default id: main)
  --sync         sign in as the PocketBase superuser (loopback only) and fetch every enabled source now
Run as root on the enana account host.
EOF
  exit 2
}
die() { echo "update-official: $*" >&2; exit 2; }
note() { printf '%s\n' "$*"; }

mode=install; sid=main; src=''
while [ $# -gt 0 ]; do
  case $1 in
    --check) mode=check ;;
    --set-source) mode=source ;;
    --sync) mode=sync ;;
    --id) shift; sid=${1:-}; [ -n "$sid" ] || usage ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) [ -z "$src" ] || usage; src=$1 ;;
  esac
  shift
done
if [ "$mode" = sync ]; then [ -z "$src" ] || usage; else [ -n "$src" ] || usage; fi
[ "$(id -u)" = 0 ] || die 'Run as root on the enana account host.'

# Locations. The defaults are the production layout; the overrides exist for the test suite.
root=${ENANA_ROOT:-/opt/enana-cc}
etc=${ENANA_ETC:-/etc/enana}
backups=${ENANA_BACKUP_ROOT:-/var/backups/enana}
api=${ENANA_API:-http://127.0.0.1:8090}
grp=${ENANA_GROUP:-enana}
svc_user=${ENANA_USER:-enana}
unit=${ENANA_UNIT:-enana-pocketbase.service}
payments=enana-payments.service
hooks=$root/pb_hooks
conf=${ENANA_OFFICIAL_CONFIG:-$etc/official.json}
files=(enana_lib.js enana_official.pb.js enana_official.js enana_official_domain.js)

ensure_backup_dir() { [ -d "$backups" ] || install -d -m 700 "$backups"; [ -d "$backups/releases" ] || install -d -m 700 "$backups/releases"; }
healthy() { curl -fsS --max-time 3 "$api/api/health" >/dev/null 2>&1; }
wait_healthy() { local _; for _ in $(seq 1 "${1:-30}"); do healthy && return 0; sleep 1; done; return 1; }

# ---------------------------------------------------------------------------------------------- --sync
if [ "$mode" = sync ]; then
  command -v node >/dev/null || die 'node is required.'
  healthy || die "PocketBase is not answering on $api."
  if [ -t 0 ]; then
    read -rp 'PocketBase superuser email: ' email
    read -rsp 'PocketBase superuser password (input is hidden): ' pw; echo
  else
    IFS= read -r email || true; IFS= read -r pw || true
  fi
  [ -n "${email:-}" ] && [ -n "${pw:-}" ] || die 'email and password are required.'
  # The password goes to node and curl through the environment / stdin, never through argv.
  token=$(ENANA_SU_EMAIL=$email ENANA_SU_PW=$pw node -e 'process.stdout.write(JSON.stringify({identity:process.env.ENANA_SU_EMAIL,password:process.env.ENANA_SU_PW}))' \
    | curl -s --max-time 15 -X POST -H 'Content-Type: application/json' --data @- "$api/api/collections/_superusers/auth-with-password" \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(String(JSON.parse(s).token||""))}catch(_){}})') || true
  unset pw
  [ -n "$token" ] || die 'superuser sign-in failed (PocketBase only accepts superusers from the host itself).'
  show() { # <sync|status>  prints counts and error codes only; the response never contains a URL or credential
    node -e '
      let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
        let j;try{j=JSON.parse(s)}catch(_){console.log("unreadable response");process.exit(1)}
        if(!j||j.ok!==true){console.log("rejected");process.exit(1)}
        const l=j.sources||[];let failed=0;if(!l.length)console.log("no sources configured");
        for(const x of l){
          if(x.error){failed++;console.log("  "+x.id+": FAILED ("+x.error+")")}
          else if("ok" in x){if(!x.ok)failed++;console.log("  "+x.id+": "+(x.ok?"ok":"not ok")+", "+(x.nodes||0)+" nodes"+(x.skipped?" ("+x.skipped+" skipped)":""))}
          else console.log("  "+x.id+": stored "+(x.stored||0)+", fresh "+(x.fresh||0)+(x.last_ok?", last success "+x.last_ok:""));
        }
        process.exit(failed?3:0)})'
  }
  note 'Fetching the sources now…'
  rc=0
  curl -s --max-time 120 -X POST -H @- "$api/api/enana/admin/official/sync" <<<"Authorization: $token" | show || rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 3 ] || die 'sync was rejected or failed.'
  note 'Status:'
  curl -s --max-time 15 -H @- "$api/api/enana/admin/official/status" <<<"Authorization: $token" | show || die 'status was rejected or failed.'
  if [ "$rc" = 3 ]; then note 'At least one source failed to fetch (error codes above: network, http_<status>, empty, too_large, bad_format, no_nodes, store). Existing nodes keep serving until they expire.'; exit 3; fi
  exit 0
fi

# ------------------------------------------------------------------------------------- shared checks
[ -d "$src/server/pb_hooks" ] || die "$src is not a staged enana repository (server/pb_hooks missing)."
for f in "${files[@]}"; do [ -f "$src/server/pb_hooks/$f" ] || die "staged file missing: server/pb_hooks/$f"; done
[ -f "$src/server/pb_hooks/enana_official_domain.js" ] || die 'staged domain module missing.'
command -v node >/dev/null || die 'node >= 18 is required.'
node -e 'if(Number(process.versions.node.split(".")[0])<18)process.exit(2)' || die 'node >= 18 is required.'

# ---------------------------------------------------------------------------------------- --set-source
if [ "$mode" = source ]; then
  [ -d "$etc" ] || die "$etc does not exist; is this the enana account host?"
  if [ -t 0 ]; then read -rsp "Source URL for '$sid' (input is hidden): " url; echo; else IFS= read -r url || true; fi
  [ -n "${url:-}" ] || die 'no URL given.'
  tmp=$(mktemp "$etc/.official.json.XXXXXX")
  trap 'rm -f "$tmp"' EXIT
  # The URL reaches node through the environment only (argv is visible to other processes). Nothing below prints it.
  summary=$(ENANA_NEW_URL=$url node - "$src" "$conf" "$sid" "$tmp" <<'JS'
const fs = require('fs'), p = require('path')
const [root, file, id, out] = process.argv.slice(2)
try {
const D = require(p.join(root, 'server/pb_hooks/enana_official_domain.js'))
let c = {}
if (fs.existsSync(file)) {
  try { c = JSON.parse(fs.readFileSync(file, 'utf8')) } catch (_) { throw Error('the existing configuration is not valid JSON; fix or remove it first') }
}
if (!c || typeof c !== 'object' || Array.isArray(c)) throw Error('the existing configuration is not an object')
const list = Array.isArray(c.sources) ? c.sources : []
if (list.length !== D.normalizeConfig({ sources: list }).sources.length) throw Error('the existing configuration has entries the server would ignore; fix them first')
const entry = list.find(s => s && s.id === id) || { id: id, ua: 'sing-box/1.12.0', prefix: '官方-' }
entry.url = String(process.env.ENANA_NEW_URL || '').trim()
entry.enabled = true
if (!D.normalizeSource(entry)) throw Error('rejected: id must be [a-z0-9-] (1-16 chars); the URL must be https://, without user:password@, without spaces, at most 2048 characters')
if (!list.includes(entry)) list.push(entry)
if (list.length > 8) throw Error('rejected: at most 8 sources are read')
c.sources = list
fs.writeFileSync(out, JSON.stringify(c, null, 2) + '\n')
console.log("source '" + id + "' stored; " + list.length + ' source(s), ' + list.filter(s => s.enabled !== false).length + ' enabled')
} catch (e) { console.error('update-official: ' + (e && e.message ? e.message : 'failed')); process.exit(1) }
JS
  ) || die 'the URL was not stored (details above; the URL itself is never shown).'
  chown "root:$grp" "$tmp"; chmod 640 "$tmp"
  if [ -e "$conf" ]; then
    ensure_backup_dir
    b="$backups/releases/official-config-$(date -u +%Y%m%dT%H%M%SZ)-$$"; mkdir -m 700 "$b"
    cp -p "$conf" "$b/official.json"; chmod 600 "$b/official.json"
  fi
  mv -f "$tmp" "$conf"
  note "$summary"
  note "Stored in $conf (root:$grp, 640). Next: install the hooks if not done yet, then run: update-official.sh --sync"
  exit 0
fi

# -------------------------------------------------------------------------------- install / --check
for f in enana_billing.pb.js enana_v1.pb.js enana_lib.js; do
  [ -f "$hooks/$f" ] || die "$hooks/$f is missing: billing is not deployed here. Run deploy-billing.sh first (initial deployment only)."
done
[ -f "$root/pb_migrations/1790000003_enana_billing.js" ] || die 'the billing migration file is missing: billing is not deployed here.'
[ "$(systemctl show "$unit" --property=User --value)" = "$svc_user" ] || die "$unit does not run as $svc_user."
healthy || die "PocketBase is not healthy now ($api/api/health). Refusing to touch a service that is already failing."

# The staged hooks must at least parse (PocketBase runs them with ES6 support; this catches typos and truncation).
for f in "${files[@]}"; do
  node --check "$src/server/pb_hooks/$f" 2>/dev/null || die "staged file does not parse: $f"
done

if [ -e "$conf" ]; then
  node - "$conf" "$src" 2>/dev/null <<'JS' || die 'official.json is not valid (see the source table in server/README.md). Contents are never shown.'
const fs = require('fs'), p = require('path'), [file, root] = process.argv.slice(2)
const D = require(p.join(root, 'server/pb_hooks/enana_official_domain.js'))
let c
try { c = JSON.parse(fs.readFileSync(file, 'utf8')) } catch (_) { process.exit(1) }   // the parser's message would quote file text
if (!c || !Array.isArray(c.sources) || D.normalizeConfig(c).sources.length !== c.sources.length) process.exit(1)
console.log('Official source configuration validated (' + c.sources.length + ' source(s), ' + c.sources.filter(s => s.enabled !== false).length + ' enabled; contents not shown).')
JS
else
  note "WARNING: $conf does not exist. The hooks will be installed, but the official lines stay 'coming soon'."
  note "         Create it with: update-official.sh --set-source $src"
fi

changed=()
for f in "${files[@]}"; do
  if [ ! -e "$hooks/$f" ]; then note "  new        $f"; changed+=("$f")
  elif cmp -s "$src/server/pb_hooks/$f" "$hooks/$f"; then note "  unchanged  $f"
  else
    add=$(diff "$hooks/$f" "$src/server/pb_hooks/$f" | grep -c '^>' || true); del=$(diff "$hooks/$f" "$src/server/pb_hooks/$f" | grep -c '^<' || true)
    note "  changed    $f (+$add -$del lines; review with: diff -u $hooks/$f $src/server/pb_hooks/$f)"; changed+=("$f")
  fi
done

fix_config_perms() { [ ! -e "$conf" ] || { chown "root:$grp" "$conf"; chmod 640 "$conf"; }; }

if [ "$mode" = check ]; then
  if [ ${#changed[@]} -eq 0 ]; then note 'Check passed: the hooks are already up to date; nothing would be restarted.'
  else note "Check passed: ${#changed[@]} file(s) would be installed and only $unit would be restarted. Nothing was changed."; fi
  exit 0
fi

fix_config_perms
if [ ${#changed[@]} -eq 0 ]; then
  note 'The hooks are already up to date; nothing was restarted.'
  exit 0
fi

ensure_backup_dir
exec 9>"$backups/billing-publish.lock"
flock -n 9 || die 'Another billing publication is running.'
backup="$backups/releases/official-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -m 700 "$backup" "$backup/pb_hooks"
for f in "${files[@]}"; do
  if [ -e "$hooks/$f" ]; then cp -p "$hooks/$f" "$backup/pb_hooks/$f"; echo "$f existing" >> "$backup/MANIFEST"; else echo "$f absent" >> "$backup/MANIFEST"; fi
done
[ ! -e "$conf" ] || { cp -p "$conf" "$backup/official.json"; chmod 600 "$backup/official.json"; }

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

touched=0; committed=0
restore_files() {
  local f state
  while read -r f state; do
    if [ "$state" = existing ]; then cp -p "$backup/pb_hooks/$f" "$hooks/$f"; else rm -f "$hooks/$f"; fi
  done < "$backup/MANIFEST"
}
rollback() {
  local rc=$?
  trap - EXIT
  if [ "$committed" = 0 ] && [ "$touched" = 1 ]; then
    echo "update-official: FAILED (exit $rc); restoring the previous hooks." >&2
    restore_files
    rm -f "$hooks"/.*.new 2>/dev/null || true
    systemctl restart "$unit" 9>&- || true
    if wait_healthy 30; then echo "Rolled back. $unit is healthy again with the previous hooks. Backup: $backup" >&2
    else echo "ROLLED BACK BUT $unit IS NOT HEALTHY. Inspect: journalctl -u $unit -n 80; backup: $backup" >&2; fi
  fi
  exit "$rc"
}
trap rollback EXIT

touched=1
for f in "${files[@]}"; do
  cp "$src/server/pb_hooks/$f" "$hooks/.$f.new"
  chown root:root "$hooks/.$f.new"; chmod 644 "$hooks/.$f.new"
  mv -f "$hooks/.$f.new" "$hooks/$f"
done
systemctl restart "$unit" 9>&-      # the lock descriptor must not leak into anything the restart spawns
wait_healthy 30 || { echo "$unit did not become healthy after the restart." >&2; exit 1; }

# The operator routes exist only if the new hooks loaded: a superuser-only route answers 401/403 without a token, 404 when absent.
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$api/api/enana/admin/official/status" || true)
case $code in 401|403) ;; *) echo "official operator route answered HTTP ${code:-none}; the new hooks did not load." >&2; exit 1 ;; esac
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$api/api/enana/v1/nodes" || true)
case $code in 2??|401|403|429) ;; *) echo "the member nodes route answered HTTP ${code:-none}." >&2; exit 1 ;; esac

snapshot_services > "$backup/services.after"
snapshot_configs > "$backup/configs.after"
cmp -s "$backup/services.before" "$backup/services.after" || { echo 'another running service changed during the update.' >&2; exit 1; }
cmp -s "$backup/configs.before" "$backup/configs.after" || { echo 'an nginx/systemd file changed during the update.' >&2; exit 1; }
pay_after=$(systemctl is-active "$payments" 2>/dev/null || true)
[ "$pay_before" = "$pay_after" ] || { echo "$payments changed state ($pay_before -> $pay_after)." >&2; exit 1; }

committed=1
trap - EXIT
note "Installed ${#changed[@]} file(s); $unit restarted and healthy; operator routes registered; other services and nginx/systemd files unchanged; $payments still $pay_after."
note "Backup: $backup"
if [ -e "$conf" ]; then note "Next: update-official.sh --sync   (fetches the sources now and shows counts; they are also fetched hourly)"
else note "Next: update-official.sh --set-source $src   then   update-official.sh --sync"; fi
