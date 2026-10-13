#!/bin/bash
# server/update-billing.sh against a fake account host (Linux only; needs root or passwordless sudo).
# The host is a temp directory tree. systemctl is a fake that "starts PocketBase" by reading the hook files it finds,
# runuser runs the command directly (and records the user), the PocketBase binary is a fake whose `migrate up`
# applies the migration files it has not recorded yet to a small SQLite file shaped like PocketBase's
# (_migrations, _collections), and a tiny HTTP server plays /api/health and the billing routes.
#   B1  usage and preconditions (not staged, staged file missing, billing not deployed, unhealthy, a staged file does
#       not parse, the domain rules are broken, an installed migration differs): nothing is touched
#   B2  --check changes nothing
#   B3  a failing migration and a wrongly migrated schema roll back hooks, migrations and the database
#   B4  the first install: backup (hooks, migrations, a copy of the stopped database), scanner stopped before
#       PocketBase and started after it, files 644 root:root, migration run once as the service user, routes checked
#   B5  a second run is a no-op (no stop, no start, no backup)
#   B6  every failure after the start rolls back: no health, routes not registered, another service disturbed,
#       the payments scanner does not come back; a good change installs afterwards
#   B7  the lock shared with deploy-billing.sh; /etc/enana/billing.json is never referenced; no secret is printed
set -eu
[ "$(id -u)" = 0 ] || exec sudo -n env "PATH=$PATH" bash "$0" "$@"
repo=$(cd "$(dirname "$0")/.." && pwd -P)
w=$(mktemp -d /tmp/enana-update-billing.XXXXXX)
trap 'kill $(cat "$w/pids" 2>/dev/null) 2>/dev/null || true; rm -rf "$w"' EXIT
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; [ ! -s "$w/out" ] || sed 's/^/    | /' "$w/out" | head -40; exit 1; }
eq() { [ "$2" = "$3" ] && ok "$1" || { echo "  got:  $2"; echo "  want: $3"; bad "$1"; }; }
has() { grep -qF -- "$2" "$w/out" && ok "$1" || bad "$1 (expected: $2)"; }
lacks() { ! grep -qF -- "$2" "$w/out" && ok "$1" || bad "$1 (found: $2)"; }
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
mode_of() { stat -c %a "$1"; }
lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
tree_sum() { (cd "$1" && find . -type f | LC_ALL=C sort | while read -r f; do sha256sum "$f"; done | sha256sum | cut -d' ' -f1); }
db_state() { # <data.db>  ->  amount maximum : applied migrations
  python3 - "${1:-$w/data/data.db}" <<'PY'
import json, sqlite3, sys
c = sqlite3.connect(sys.argv[1])
f = {x['name']: x for x in json.loads(c.execute("select fields from _collections where name = 'billing_orders'").fetchone()[0])}
print('%s:%s' % (f['amount']['max'], ','.join(r[0] for r in c.execute('select file from _migrations order by file'))))
PY
}
state() { echo "$(tree_sum "$w/opt/pb_hooks"):$(tree_sum "$w/opt/pb_migrations"):$(db_state)"; }
health() { curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$ENANA_API/api/health" || true; }
backups_count() { ls -d "$w"/bk/releases/billing-update-* 2>/dev/null | wc -l | tr -d ' '; }

PROVIDER=PROVIDER-SECRET-9876
OLD_DB='1000010000:1790000003_enana_billing.js,1790000004_billing_lease.js'
NEW_DB='1000999000:1790000003_enana_billing.js,1790000004_billing_lease.js,1790000006_billing_amount.js'

# ---------- fake host: the previous billing release, migrations 1790000003 and 1790000004 applied ----------
mkdir -p "$w/opt/pb_hooks" "$w/opt/pb_migrations" "$w/data" "$w/etc" "$w/bk" "$w/st" "$w/bin" "$w/stage/server"
cp -r "$repo/server/pb_hooks" "$repo/server/pb_migrations" "$w/stage/server/"
for f in enana_billing.pb.js enana_billing.js enana_billing_domain.js; do echo "// old $f" > "$w/opt/pb_hooks/$f"; done
for f in enana_v1.pb.js enana_lib.js enana_official.js; do echo "// other $f" > "$w/opt/pb_hooks/$f"; done
cp "$repo/server/pb_migrations/1790000003_enana_billing.js" "$repo/server/pb_migrations/1790000004_billing_lease.js" "$w/opt/pb_migrations/"
printf '{"payments_enabled": true, "provider_key": "%s", "sentinel": "billing-untouched"}\n' "$PROVIDER" > "$w/etc/billing.json"
bill_sum=$(sha256sum "$w/etc/billing.json" | cut -d' ' -f1)
python3 - "$w/data/data.db" <<'PY'
import json, sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute('create table _migrations (file text primary key not null, applied integer not null)')
c.execute('create table _collections (id text primary key, name text, fields text, indexes text)')
for f in ('1790000003_enana_billing.js', '1790000004_billing_lease.js'): c.execute('insert into _migrations values (?, 1)', (f,))
fields = [{'name': 'amount', 'type': 'number', 'onlyInt': True, 'min': 1, 'max': 1000010000}, {'name': 'pay_by', 'type': 'date'},
          {'name': 'status', 'type': 'select', 'values': ['pending', 'paid', 'expired', 'cancelled', 'credited_late', 'manual']}]
c.execute("insert into _collections values ('pbc_orders', 'billing_orders', ?, ?)", (json.dumps(fields), json.dumps(['CREATE UNIQUE INDEX `idx_order_request` ON `billing_orders` (user, request_key)'])))
c.commit()
PY
echo running > "$w/data/running.pid"     # the fake PocketBase keeps this file in its data directory while it runs

cat > "$w/bin/systemctl" <<'SH'
#!/bin/bash
st=$FAKE_ST
case "$1" in
  show)
    case "$3" in
      --property=User) echo enana ;;
      *) echo "Id=$2"; echo "MainPID=$(cat "$st/pid.$2" 2>/dev/null || echo 100)"; echo "ActiveEnterTimestamp=t0" ;;
    esac ;;
  list-units) printf 'ssh.service loaded active running OpenSSH\nnginx.service loaded active running nginx\nenana-pocketbase.service loaded active running PB\nenana-payments.service loaded active running pay\n' ;;
  is-active)
    if [ "$2" = enana-payments.service ]; then f=payments_stopped; else f=pb_stopped; fi
    if [ -e "$st/$f" ]; then echo inactive; exit 3; fi
    echo active ;;
  stop)
    echo "stop $2" >> "$st/actions"
    if [ "$2" = enana-payments.service ]; then touch "$st/payments_stopped"; else touch "$st/pb_stopped"; rm -f "$FAKE_DATA/running.pid"; fi ;;
  start)
    echo "start $2" >> "$st/actions"
    if [ "$2" = enana-payments.service ]; then
      [ -e "$st/payments_wont_start" ] || rm -f "$st/payments_stopped"
    else
      rm -f "$st/pb_stopped" "$st/down" "$st/no_routes"; echo running > "$FAKE_DATA/running.pid"
      if grep -rq 'BREAK_ON_START' "$FAKE_HOOKS" 2>/dev/null; then touch "$st/down"; fi
      if grep -rq 'NO_ROUTES' "$FAKE_HOOKS" 2>/dev/null; then touch "$st/no_routes"; fi
      if [ -e "$st/disturb_other" ]; then echo 999 > "$st/pid.nginx.service"; fi
    fi ;;
  *) exit 1 ;;
esac
exit 0
SH
cat > "$w/bin/runuser" <<'SH'
#!/bin/bash
# runuser -u USER -- COMMAND ...: record the user and the command name, then run it (the test already runs as root).
[ "$1" = -u ] && [ "$3" = -- ] || exit 64
echo "$2 ${4##*/}" >> "$FAKE_ST/runuser"
shift 3
exec "$@"
SH
cat > "$w/opt/pocketbase" <<'PY'
#!/usr/bin/env python3
# Fake `pocketbase migrate up`: applies every migration file not recorded yet, in name order, to the fixture database.
import glob, json, os, sqlite3, sys
args = sys.argv[1:]
if args[:2] != ['migrate', 'up']: sys.exit(64)
opt = dict(a[2:].split('=', 1) for a in args[2:] if a.startswith('--') and '=' in a)
with open(os.environ['FAKE_ST'] + '/migrate', 'a') as log: log.write(' '.join(args) + '\n')
db = sqlite3.connect(os.path.join(opt['dir'], 'data.db'))
done = {r[0] for r in db.execute('select file from _migrations')}
for path in sorted(glob.glob(os.path.join(opt['migrationsDir'], '*.js'))):
    name = os.path.basename(path)
    if name in done: continue
    text = open(path).read()
    db.execute('insert into _migrations values (?, 1)', (name,))
    if 'FAIL_MIGRATION' in text:
        db.commit(); print('Error: failed to apply migration ' + name, file=sys.stderr); sys.exit(1)
    if "getByName('amount')" in text and '1000999000' in text and 'SKIP_SCHEMA' not in text:
        fields = json.loads(db.execute("select fields from _collections where name = 'billing_orders'").fetchone()[0])
        for f in fields:
            if f['name'] == 'amount': f['max'] = 1000999000
        db.execute("update _collections set fields = ? where name = 'billing_orders'", (json.dumps(fields),))
    db.commit(); print('Applied ' + name)
PY
chmod +x "$w/bin/systemctl" "$w/bin/runuser" "$w/opt/pocketbase"

cat > "$w/fake-pb.py" <<'PY'
import http.server, os, sys
port, st = int(sys.argv[1]), sys.argv[2]
ROUTES = {('GET', '/api/enana/v1/billing'), ('POST', '/api/enana/v1/billing/checkout'), ('POST', '/api/enana/v1/billing/auto-renew'), ('GET', '/api/enana/admin/billing/manual')}
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def out(self, code):
        body = b'{}'
        self.send_response(code); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def route(self):
        with open(st + '/requests', 'a') as log: log.write(self.command + ' ' + self.path + '\n')
        if os.path.exists(st + '/pb_stopped') or os.path.exists(st + '/down'): return self.out(503)
        path = self.path.split('?', 1)[0]
        if path == '/api/health': return self.out(200)
        if path == '/api/enana/v1/plan': return self.out(401)
        if (self.command, path) in ROUTES: return self.out(404 if os.path.exists(st + '/no_routes') else 401)
        self.out(404)
    def do_GET(self): self.route()
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length') or 0)); self.route()
http.server.ThreadingHTTPServer(('127.0.0.1', port), H).serve_forever()
PY
port=$(free_port)
python3 "$w/fake-pb.py" "$port" "$w/st" & echo $! > "$w/pids"
for _ in $(seq 1 50); do curl -fsS --max-time 1 "http://127.0.0.1:$port/api/health" >/dev/null 2>&1 && break; sleep 0.1; done

export PATH="$w/bin:$PATH" FAKE_ST=$w/st FAKE_HOOKS=$w/opt/pb_hooks FAKE_DATA=$w/data
export ENANA_ROOT=$w/opt ENANA_DATA=$w/data ENANA_BACKUP_ROOT=$w/bk ENANA_API=http://127.0.0.1:$port ENANA_USER=enana ENANA_HEALTH_WAIT=3
S=$repo/server/update-billing.sh
rc=0
run() { set +e; "$@" >"$w/out" 2>&1; rc=$?; set -e; cat "$w/out" >> "$w/all"; }
cp "$w/stage/server/pb_hooks/enana_billing.js" "$w/billing.js.good"
cp "$w/stage/server/pb_hooks/enana_billing_domain.js" "$w/domain.js.good"
cp "$w/stage/server/pb_migrations/1790000006_billing_amount.js" "$w/m6.good"

# ---------- B1 usage and preconditions ----------
bash -n "$S" && ok "syntax"
eq "the fixture database starts at the previous schema" "$(db_state)" "$OLD_DB"
run "$S"; eq "no arguments: usage, exit 2" "$rc" "2"; has "…prints the usage" "Usage:"
run "$S" "$w/nowhere"; eq "a directory that is not a staged repository: exit 2" "$rc" "2"
base=$(state)
mv "$w/stage/server/pb_migrations/1790000006_billing_amount.js" "$w/m6.moved"
run "$S" "$w/stage"; eq "a staged migration is missing: refused (exit 2)" "$rc" "2"; has "…names it" "server/pb_migrations/1790000006_billing_amount.js"
mv "$w/m6.moved" "$w/stage/server/pb_migrations/1790000006_billing_amount.js"
mv "$w/opt/pb_hooks/enana_v1.pb.js" "$w/v1.moved"
run "$S" "$w/stage"; eq "billing not deployed: refused (exit 2)" "$rc" "2"; has "…tells the operator to run deploy-billing.sh first" "deploy-billing.sh"
mv "$w/v1.moved" "$w/opt/pb_hooks/enana_v1.pb.js"
touch "$w/st/down"
run "$S" "$w/stage"; eq "PocketBase already unhealthy: refused (exit 2)" "$rc" "2"; has "…says why" "already failing"
rm -f "$w/st/down"
echo 'function (' >> "$w/stage/server/pb_hooks/enana_billing.js"
run "$S" "$w/stage"; eq "a staged hook that does not parse: refused before any change" "$rc" "2"; has "…names the file" "enana_billing.js"
cp "$w/billing.js.good" "$w/stage/server/pb_hooks/enana_billing.js"
echo 'module.exports.TAILS=[];' >> "$w/stage/server/pb_hooks/enana_billing_domain.js"
run "$S" "$w/stage"; eq "a staged domain module that breaks the amount rules: refused" "$rc" "2"; has "…says so" "breaks the amount rules"
cp "$w/domain.js.good" "$w/stage/server/pb_hooks/enana_billing_domain.js"
echo '// edited on the host' >> "$w/opt/pb_migrations/1790000004_billing_lease.js"
run "$S" "$w/stage"; eq "an installed migration that differs from the staged one: refused (exit 2)" "$rc" "2"; has "…an applied migration is never rewritten" "never rewritten"
cp "$repo/server/pb_migrations/1790000004_billing_lease.js" "$w/opt/pb_migrations/1790000004_billing_lease.js"
eq "…nothing was touched: files, database, no stop/start, no migration, no backup" "$(state):$(lines "$w/st/actions"):$(lines "$w/st/migrate"):$(backups_count)" "$base:0:0:0"

# ---------- B2 --check ----------
run "$S" --check "$w/stage"; eq "--check: exit 0" "$rc" "0"
has "…lists the changed hooks" "changed    pb_hooks/enana_billing.js"; has "…the new migration" "new        pb_migrations/1790000006_billing_amount.js"
has "…and the migration that is already there" "unchanged  pb_migrations/1790000004_billing_lease.js"
eq "…nothing changed" "$(state):$(lines "$w/st/actions"):$(lines "$w/st/migrate"):$(backups_count)" "$base:0:0:0"

# ---------- B3 a failing migration / a wrong schema roll everything back ----------
echo '/* FAIL_MIGRATION */' >> "$w/stage/server/pb_migrations/1790000006_billing_amount.js"
run "$S" "$w/stage"; eq "the migration fails: exit non-zero" "$([ "$rc" != 0 ] && echo failed)" "failed"
has "…says it rolled back" "Rolled back"
eq "…hooks, migrations and database (the half-applied migration included) are as before; PocketBase healthy; scanner active" "$(state):$(health):$(systemctl is-active enana-payments.service)" "$base:200:active"
cp "$w/m6.good" "$w/stage/server/pb_migrations/1790000006_billing_amount.js"
echo '/* SKIP_SCHEMA */' >> "$w/stage/server/pb_migrations/1790000006_billing_amount.js"
r0=$(lines "$w/st/requests")
run "$S" "$w/stage"; eq "the migrated schema is not what the release needs: rolled back" "$([ "$rc" != 0 ] && echo failed):$(state):$(health)" "failed:$base:200"
has "…names the cause" "does not accept 1000.999 USDT"
eq "…the check ran before PocketBase served anything (no billing route was asked)" "$(sed -n "$((r0+1)),\$p" "$w/st/requests" | grep -c '/api/enana/' || true)" "0"
cp "$w/m6.good" "$w/stage/server/pb_migrations/1790000006_billing_amount.js"

# ---------- B4 the first install ----------
a0=$(lines "$w/st/actions"); m0=$(lines "$w/st/migrate"); u0=$(lines "$w/st/runuser"); r0=$(lines "$w/st/requests")
run "$S" "$w/stage"; eq "first install: exit 0" "$rc" "0"
has "…reports what it did" "Installed 4 file(s); applied 1790000006_billing_amount.js"; has "…verified the routes" "billing routes answer"
b=$(sed -n 's/^Backup (hooks, migrations, database copy): //p' "$w/out")
same=1; for f in pb_hooks/enana_billing.pb.js pb_hooks/enana_billing.js pb_hooks/enana_billing_domain.js pb_migrations/1790000006_billing_amount.js; do cmp -s "$w/stage/server/$f" "$w/opt/$f" || same=0; done
eq "…the three hooks and the new migration are the staged files" "$same" "1"
eq "…installed as 644 root:root" "$(mode_of "$w/opt/pb_hooks/enana_billing.js"):$(stat -c %U:%G "$w/opt/pb_hooks/enana_billing.js"):$(mode_of "$w/opt/pb_migrations/1790000006_billing_amount.js"):$(stat -c %U:%G "$w/opt/pb_migrations/1790000006_billing_amount.js")" "644:root:root:644:root:root"
eq "…no temp file left behind; other hooks untouched" "$(find "$w/opt" -name '.*.new' | wc -l | tr -d ' '):$(cat "$w/opt/pb_hooks/enana_lib.js")" "0:// other enana_lib.js"
eq "…the database is migrated" "$(db_state)" "$NEW_DB"
eq "…migrate ran once, then the schema check, both as the service user" "$(( $(lines "$w/st/migrate") - m0 )):$(sed -n "$((u0+1)),\$p" "$w/st/runuser" | tr '\n' ',')" "1:enana pocketbase,enana python3,"
eq "…the scanner stops before PocketBase and starts after it; PocketBase stops and starts once" "$(sed -n "$((a0+1)),\$p" "$w/st/actions" | tr '\n' ',')" "stop enana-payments.service,stop enana-pocketbase.service,start enana-pocketbase.service,start enana-payments.service,"
eq "…PocketBase healthy, scanner active again" "$(health):$(systemctl is-active enana-payments.service)" "200:active"
grep -qF 'GET /api/enana/v1/billing?orders_page=2&orders_per_page=10' "$w/st/requests" && ok "…the billing routes were checked, paging included" || bad "…the paging route was not checked"
eq "…the backup is mode 700 with the old hooks, the old migrations and a manifest" "$(mode_of "$b"):$(head -1 "$b/pb_hooks/enana_billing.js"):$(ls "$b/pb_migrations" | LC_ALL=C sort | tr '\n' ','):$(LC_ALL=C sort "$b/MANIFEST" | tr '\n' ',')" \
  "700:// old enana_billing.js:1790000003_enana_billing.js,1790000004_billing_lease.js,:enana_billing.js existing,enana_billing.pb.js existing,enana_billing_domain.js existing,"
eq "…the database copy was taken with PocketBase stopped, before the migration" "$([ -e "$b/pb_data/running.pid" ] && echo live || echo stopped):$(db_state "$b/pb_data/data.db")" "stopped:$OLD_DB"
installed=$(state)

# ---------- B5 idempotent ----------
a0=$(lines "$w/st/actions"); n0=$(backups_count)
run "$S" "$w/stage"; eq "second run: exit 0" "$rc" "0"; has "…reports up to date" "already up to date"
eq "…no stop/start, no new backup, nothing changed" "$(lines "$w/st/actions"):$(backups_count):$(state)" "$a0:$n0:$installed"

# ---------- B6 rollback after the start ----------
change() { echo "/* $1 */" >> "$w/stage/server/pb_hooks/enana_billing.js"; }
reset_stage() { cp "$w/billing.js.good" "$w/stage/server/pb_hooks/enana_billing.js"; }
change BREAK_ON_START
run "$S" "$w/stage"; eq "PocketBase does not become healthy: rolled back" "$([ "$rc" != 0 ] && echo failed):$(state):$(health):$(systemctl is-active enana-payments.service)" "failed:$installed:200:active"
has "…says it rolled back" "Rolled back"; has "…names the cause" "did not become healthy"
reset_stage

change NO_ROUTES
run "$S" "$w/stage"; eq "billing routes not registered (404): rolled back" "$([ "$rc" != 0 ] && echo failed):$(state):$(health)" "failed:$installed:200"
has "…names the cause" "the new hooks did not load"
reset_stage

change touch-other; touch "$w/st/disturb_other"
run "$S" "$w/stage"; eq "another service disturbed during the update: rolled back" "$([ "$rc" != 0 ] && echo failed):$(state)" "failed:$installed"
has "…names the cause" "another running service changed"
rm -f "$w/st/disturb_other" "$w/st/pid.nginx.service"; reset_stage

change scanner-stuck; touch "$w/st/payments_wont_start"
run "$S" "$w/stage"; eq "the payments scanner does not come back: rolled back" "$([ "$rc" != 0 ] && echo failed):$(state):$(health)" "failed:$installed:200"
has "…names the cause" "enana-payments.service changed state (active -> inactive)"; has "…and tells the operator" "did not start again"
rm -f "$w/st/payments_wont_start"; systemctl start enana-payments.service; reset_stage
eq "…and a good change installs after all that" "$(change v2; run "$S" "$w/stage"; echo "$rc"):$(db_state):$(systemctl is-active enana-payments.service)" "0:$NEW_DB:active"
reset_stage

# ---------- B7 lock, receiving switch, secrets ----------
change locked
flock "$w/bk/billing-publish.lock" sleep 6 & lockpid=$!
sleep 0.5
h0=$(state); a0=$(lines "$w/st/actions")
run "$S" "$w/stage"; eq "another billing publication holds the lock: refused (exit 2)" "$rc" "2"; has "…says so" "Another billing publication"
eq "…nothing changed" "$(state):$(lines "$w/st/actions")" "$h0:$a0"
kill "$lockpid" 2>/dev/null || true; wait "$lockpid" 2>/dev/null || true
eq "the script never refers to billing.json outside its comments" "$(grep -v '^[[:space:]]*#' "$S" | grep -c 'billing\.json' || true)" "0"
eq "…and the receiving switch file is unchanged" "$(sha256sum "$w/etc/billing.json" | cut -d' ' -f1)" "$bill_sum"
cp "$w/all" "$w/out"; lacks "no run printed a secret" "$PROVIDER"
echo "ALL PASS"
