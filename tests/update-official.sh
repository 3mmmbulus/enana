#!/bin/bash
# server/update-official.sh against a fake account host (Linux only; needs root or passwordless sudo).
# The host is a temp directory tree; systemctl is a fake that "restarts PocketBase" by loading the hook files it
# finds, and a tiny HTTP server plays PocketBase's /api/health, the operator routes and superuser sign-in.
#   O1  usage, preconditions (billing not deployed / unhealthy / staged file does not parse): nothing is touched
#   O2  --check changes nothing; the first install backs up, installs the four hooks, restarts once, verifies
#   O3  a second run is a no-op (no restart); official.json permissions are fixed
#   O4  every failure after the first change rolls back: crash on restart, routes not registered, another service
#       disturbed, payments service changed state; the previous hooks are back and PocketBase is healthy again
#   O5  invalid / unreadable official.json is refused without ever printing its contents
#   O6  --set-source: hidden input path, 640 root:group, replace / add / reject, backups, URL never printed
#   O7  --sync: sign-in over the loopback API, counts only, password and token never printed
#   O8  the lock shared with deploy-billing.sh; /etc/enana/billing.json is never touched
set -eu
[ "$(id -u)" = 0 ] || exec sudo -n env "PATH=$PATH" bash "$0" "$@"
repo=$(cd "$(dirname "$0")/.." && pwd -P)
w=$(mktemp -d /tmp/enana-update-official.XXXXXX)
trap 'kill $(cat "$w/pids" 2>/dev/null) 2>/dev/null || true; rm -rf "$w"' EXIT
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; [ ! -s "$w/out" ] || sed 's/^/    | /' "$w/out" | head -30; exit 1; }
eq() { [ "$2" = "$3" ] && ok "$1" || { echo "  got:  $2"; echo "  want: $3"; bad "$1"; }; }
has() { grep -qF -- "$2" "$w/out" && ok "$1" || bad "$1 (expected: $2)"; }
lacks() { ! grep -qF -- "$2" "$w/out" && ok "$1" || bad "$1 (found: $2)"; }
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
mode_of() { stat -c %a "$1"; }
hooks_sum() { (cd "$w/opt/pb_hooks" && for f in * .[!.]*; do [ -e "$f" ] && sha256sum "$f"; done | sort | sha256sum | cut -d' ' -f1); }
restarts() { if [ -f "$w/st/restarts" ]; then wc -l < "$w/st/restarts" | tr -d ' '; else echo 0; fi; }

TOKEN=SECRET-TOKEN-1234
URL=https://example.invalid/subs/$TOKEN

# ---------- fake host ----------
mkdir -p "$w/opt/pb_hooks" "$w/opt/pb_migrations" "$w/etc" "$w/bk" "$w/st" "$w/bin" "$w/stage/server"
chmod 750 "$w/etc"
cp -r "$repo/server/pb_hooks" "$w/stage/server/"
for f in enana_billing.pb.js enana_v1.pb.js; do echo "// old $f" > "$w/opt/pb_hooks/$f"; done
echo "// old enana_lib.js (before official nodes)" > "$w/opt/pb_hooks/enana_lib.js"
: > "$w/opt/pb_migrations/1790000003_enana_billing.js"
echo '{"payments_enabled": false, "sentinel": "billing-untouched"}' > "$w/etc/billing.json"
bill_sum=$(sha256sum "$w/etc/billing.json" | cut -d' ' -f1)

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
  is-active) [ -e "$st/payments_stopped" ] && echo inactive || echo active ;;
  restart)
    echo "$2" >> "$st/restarts"
    rm -f "$st/down" "$st/loaded_official"
    grep -rq 'BREAK_ON_RESTART' "$FAKE_HOOKS" 2>/dev/null && touch "$st/down"
    if [ -f "$FAKE_HOOKS/enana_official.pb.js" ] && ! grep -rq 'NO_ROUTES' "$FAKE_HOOKS"; then touch "$st/loaded_official"; fi
    [ ! -e "$st/disturb_other" ] || echo 999 > "$st/pid.nginx.service"
    [ ! -e "$st/stop_payments" ] || touch "$st/payments_stopped"
    ;;
esac
SH
chmod +x "$w/bin/systemctl"

cat > "$w/fake-pb.py" <<'PY'
import http.server, json, os, sys
port, st = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def out(self, code, body=b'{}'):
        self.send_response(code); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if os.path.exists(st + '/down'): return self.out(503)
        if self.path == '/api/health': return self.out(200, b'{"code":200}')
        if self.path == '/api/enana/admin/official/status':
            if not os.path.exists(st + '/loaded_official'): return self.out(404)
            if self.headers.get('Authorization') == 'TOKEN123':
                return self.out(200, b'{"ok":true,"sources":[{"id":"main","stored":3,"fresh":3,"last_ok":"2026-10-08"}]}')
            return self.out(401)
        if self.path == '/api/enana/v1/nodes': return self.out(401)
        self.out(404)
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length') or 0))
        if self.path == '/api/collections/_superusers/auth-with-password':
            d = json.loads(body or b'{}')
            if d.get('identity') == 'admin@example.invalid' and d.get('password') == 'S3cret-pw-123':
                return self.out(200, b'{"token":"TOKEN123"}')
            return self.out(400)
        if self.path == '/api/enana/admin/official/sync' and self.headers.get('Authorization') == 'TOKEN123':
            if os.path.exists(st + '/sync_fail'):
                return self.out(200, b'{"ok":true,"sources":[{"id":"main","ok":false,"nodes":0,"skipped":0,"error":"network"}]}')
            return self.out(200, b'{"ok":true,"sources":[{"id":"main","ok":true,"nodes":38,"skipped":2}]}')
        self.out(404)
http.server.ThreadingHTTPServer(('127.0.0.1', port), H).serve_forever()
PY
port=$(free_port)
python3 "$w/fake-pb.py" "$port" "$w/st" & echo $! > "$w/pids"
for _ in $(seq 1 50); do curl -fsS --max-time 1 "http://127.0.0.1:$port/api/health" >/dev/null 2>&1 && break; sleep 0.1; done

export PATH="$w/bin:$PATH" FAKE_ST=$w/st FAKE_HOOKS=$w/opt/pb_hooks
export ENANA_ROOT=$w/opt ENANA_ETC=$w/etc ENANA_BACKUP_ROOT=$w/bk ENANA_API=http://127.0.0.1:$port ENANA_GROUP=root ENANA_USER=enana
S=$repo/server/update-official.sh
rc=0
run() { set +e; "$@" >"$w/out" 2>&1; rc=$?; set -e; }
run_in() { local input=$1; shift; set +e; printf '%s' "$input" | "$@" >"$w/out" 2>&1; rc=$?; set -e; }
backups_count() { ls -d "$w"/bk/releases/official-2* 2>/dev/null | wc -l | tr -d ' '; }

# ---------- O1 usage and preconditions ----------
bash -n "$S" && ok "syntax"
run "$S"; eq "no arguments: usage, exit 2" "$rc" "2"; has "…prints the usage" "Usage:"
run "$S" "$w/nowhere"; eq "a directory that is not a staged repository: exit 2" "$rc" "2"
base=$(hooks_sum)
mv "$w/opt/pb_hooks/enana_billing.pb.js" "$w/billing.moved"
run "$S" "$w/stage"; eq "billing not deployed: refused (exit 2)" "$rc" "2"; has "…tells the operator to run deploy-billing.sh first" "deploy-billing.sh"
mv "$w/billing.moved" "$w/opt/pb_hooks/enana_billing.pb.js"
touch "$w/st/down"
run "$S" "$w/stage"; eq "PocketBase already unhealthy: refused (exit 2)" "$rc" "2"; has "…says why" "already failing"
rm -f "$w/st/down"
cp "$w/stage/server/pb_hooks/enana_official.js" "$w/official.js.good"
echo 'function (' >> "$w/stage/server/pb_hooks/enana_official.js"
run "$S" "$w/stage"; eq "a staged hook that does not parse: refused before any change" "$rc" "2"; has "…names the file" "enana_official.js"
cp "$w/official.js.good" "$w/stage/server/pb_hooks/enana_official.js"
eq "…nothing was touched, no restart, no backup" "$(hooks_sum):$(restarts):$(backups_count)" "$base:0:0"

# ---------- O2 --check, then the first install ----------
run "$S" --check "$w/stage"; eq "--check: exit 0" "$rc" "0"
has "…lists the files it would install" "new        enana_official.pb.js"; has "…and the changed one" "changed    enana_lib.js"
has "…warns that official.json does not exist yet" "does not exist"
eq "…nothing changed" "$(hooks_sum):$(restarts):$(backups_count)" "$base:0:0"

run_in "$URL"$'\n' "$S" --set-source "$w/stage"; eq "--set-source (non-tty stdin): exit 0" "$rc" "0"
lacks "…the URL is not printed" "$TOKEN"
eq "…official.json is 640 and holds one source" "$(mode_of "$w/etc/official.json"):$(python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); print(len(c["sources"]), c["sources"][0]["id"], c["sources"][0]["enabled"])' "$w/etc/official.json")" "640:1 main True"
chmod 600 "$w/etc/official.json"

run "$S" "$w/stage"; eq "first install: exit 0" "$rc" "0"
has "…verified" "operator routes registered"; has "…reports the backup" "Backup:"
lacks "…the output never contains the source URL" "$TOKEN"
same=1; for f in enana_lib.js enana_official.pb.js enana_official.js enana_official_domain.js; do cmp -s "$w/stage/server/pb_hooks/$f" "$w/opt/pb_hooks/$f" || same=0; done
eq "…all four hooks are the staged files" "$same" "1"
eq "…installed as 644 root:root" "$(mode_of "$w/opt/pb_hooks/enana_official.js"):$(stat -c %U:%G "$w/opt/pb_hooks/enana_official.js")" "644:root:root"
b=$(ls -d "$w"/bk/releases/official-2* | head -1)
eq "…the backup is mode 700, keeps the old enana_lib.js and a copy of official.json (600)" "$(mode_of "$b"):$(head -1 "$b/pb_hooks/enana_lib.js"):$(mode_of "$b/official.json")" "700:// old enana_lib.js (before official nodes):600"
eq "…the manifest records what existed" "$(sort "$b/MANIFEST" | tr '\n' ',')" "enana_lib.js existing,enana_official.js absent,enana_official.pb.js absent,enana_official_domain.js absent,"
eq "…official.json permissions were fixed to 640" "$(mode_of "$w/etc/official.json")" "640"
eq "…exactly one restart" "$(restarts)" "1"
installed=$(hooks_sum)

# ---------- O3 idempotent ----------
run "$S" "$w/stage"; eq "second run: exit 0" "$rc" "0"; has "…reports up to date" "already up to date"
eq "…no restart, no new backup, files unchanged" "$(restarts):$(backups_count):$(hooks_sum)" "1:1:$installed"

# ---------- O4 rollback ----------
change() { echo "/* $1 */" >> "$w/stage/server/pb_hooks/enana_official.js"; }
reset_stage() { cp "$w/official.js.good" "$w/stage/server/pb_hooks/enana_official.js"; }
r0=$(restarts)
change BREAK_ON_RESTART
run "$S" "$w/stage"; eq "PocketBase down after the restart: exit non-zero" "$([ "$rc" != 0 ] && echo failed)" "failed"
has "…says it rolled back" "Rolled back"
eq "…the previous hooks are back, PocketBase is healthy, two restarts (apply + rollback)" "$(hooks_sum):$(curl -s -o /dev/null -w %{http_code} "$ENANA_API/api/health"):$(( $(restarts) - r0 ))" "$installed:200:2"
reset_stage

r0=$(restarts); change NO_ROUTES
run "$S" "$w/stage"; eq "operator routes not registered (404): rolled back" "$([ "$rc" != 0 ] && echo failed):$(hooks_sum)" "failed:$installed"
has "…names the cause" "did not load"
reset_stage

r0=$(restarts); change touch-other; touch "$w/st/disturb_other"
run "$S" "$w/stage"; eq "another service disturbed during the update: rolled back" "$([ "$rc" != 0 ] && echo failed):$(hooks_sum)" "failed:$installed"
has "…names the cause" "another running service changed"
rm -f "$w/st/disturb_other" "$w/st/pid.nginx.service"; reset_stage

change stop-payments; touch "$w/st/stop_payments"
run "$S" "$w/stage"; eq "payments service changed state: rolled back" "$([ "$rc" != 0 ] && echo failed):$(hooks_sum)" "failed:$installed"
has "…names the cause" "enana-payments.service changed state"
rm -f "$w/st/stop_payments" "$w/st/payments_stopped"; reset_stage
eq "…and a good change installs after all that" "$(change v2; run "$S" "$w/stage"; echo $rc)" "0"
reset_stage

# ---------- O5 invalid official.json ----------
good_conf=$(cat "$w/etc/official.json")
printf '{"sources":[{"id":"BAD ID","url":"%s"}]}\n' "$URL" > "$w/etc/official.json"
change after-bad-conf; h0=$(hooks_sum); r0=$(restarts)
run "$S" "$w/stage"; eq "an entry the server would ignore: refused (exit 2)" "$rc" "2"
lacks "…the URL is not printed" "$TOKEN"
printf '{"sources":[{"id":"main","url":"%s"' "$URL" > "$w/etc/official.json"
run "$S" "$w/stage"; eq "malformed JSON: refused (exit 2)" "$rc" "2"
lacks "…the parser's quote of the file is not printed" "$TOKEN"
run "$S" --check "$w/stage"; eq "--check refuses it too" "$rc" "2"
eq "…nothing changed, no restart" "$(hooks_sum):$(restarts)" "$h0:$r0"
printf '%s\n' "$good_conf" > "$w/etc/official.json"; chmod 640 "$w/etc/official.json"; reset_stage

# ---------- O6 --set-source ----------
before=$(sha256sum "$w/etc/official.json" | cut -d' ' -f1)
run_in $'http://example.invalid/subs/x\n' "$S" --set-source "$w/stage"; eq "http:// is rejected" "$([ "$rc" != 0 ] && echo rejected)" "rejected"
run_in $'https://user:pw@example.invalid/subs/x\n' "$S" --set-source "$w/stage"; eq "user:password@ is rejected" "$([ "$rc" != 0 ] && echo rejected)" "rejected"
run_in $'\n' "$S" --set-source "$w/stage"; eq "an empty URL is rejected" "$([ "$rc" != 0 ] && echo rejected)" "rejected"
run_in $'https://example.invalid/x\n' "$S" --set-source --id 'BAD ID' "$w/stage"; eq "a bad id is rejected" "$([ "$rc" != 0 ] && echo rejected)" "rejected"
eq "…official.json is byte-identical after every rejection" "$(sha256sum "$w/etc/official.json" | cut -d' ' -f1)" "$before"
eq "…and no temp file is left behind" "$(ls -A "$w/etc" | grep -c '^\.official' || true)" "0"
run_in $'https://example.invalid/subs/NEW-TOKEN-5678\n' "$S" --set-source "$w/stage"; eq "same id again: replaces the URL (exit 0)" "$rc" "0"
eq "…still one source, with the new URL, 640" "$(python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); print(len(c["sources"]), c["sources"][0]["url"].endswith("NEW-TOKEN-5678"))' "$w/etc/official.json"):$(mode_of "$w/etc/official.json")" "1 True:640"
run_in $'https://example.invalid/subs/SECOND\n' "$S" --set-source --id second "$w/stage"; eq "another id: adds a second source" "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["sources"]))' "$w/etc/official.json")" "2"
has "…prints a summary without the URL" "2 source(s)"; lacks "…the added source's URL is not printed" "SECOND"
eq "…each rewrite of an existing file left a 700 backup of the previous one (replace + add = 2)" "$(ls -d "$w"/bk/releases/official-config-* | wc -l | tr -d ' '):$(mode_of "$(ls -d "$w"/bk/releases/official-config-* | head -1)")" "2:700"

# ---------- O7 --sync ----------
run_in $'admin@example.invalid\nS3cret-pw-123\n' "$S" --sync; eq "--sync: exit 0" "$rc" "0"
has "…shows counts for the fetch" "main: ok, 38 nodes (2 skipped)"; has "…and the status" "main: stored 3, fresh 3"
lacks "…the password is not printed" "S3cret-pw-123"; lacks "…the token is not printed" "TOKEN123"
touch "$w/st/sync_fail"
run_in $'admin@example.invalid\nS3cret-pw-123\n' "$S" --sync; eq "--sync when a source fails to fetch: exit 3" "$rc" "3"
has "…shows the error code" "main: FAILED (network)"; has "…explains what happens to existing nodes" "keep serving until they expire"
rm -f "$w/st/sync_fail"
run_in $'admin@example.invalid\nwrong\n' "$S" --sync; eq "--sync with a wrong password: exit 2" "$rc" "2"; has "…says the sign-in failed" "sign-in failed"

# ---------- O8 lock, payments untouched ----------
change locked
flock "$w/bk/billing-publish.lock" sleep 6 & lockpid=$!
sleep 0.5
h0=$(hooks_sum); r0=$(restarts)
run "$S" "$w/stage"; eq "another billing publication holds the lock: refused (exit 2)" "$rc" "2"; has "…says so" "Another billing publication"
eq "…nothing changed" "$(hooks_sum):$(restarts)" "$h0:$r0"
kill "$lockpid" 2>/dev/null || true; wait "$lockpid" 2>/dev/null || true
eq "/etc/enana/billing.json (the receiving switch) was never touched" "$(sha256sum "$w/etc/billing.json" | cut -d' ' -f1)" "$bill_sum"
echo "ALL PASS"
