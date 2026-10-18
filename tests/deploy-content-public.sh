#!/bin/bash
# server/deploy-content-public.sh against a fake account host (Linux only; needs root or passwordless sudo).
# The host is a temp directory tree: the nginx configuration (tests/fixtures/nginx-enana.cc.conf as
# sites-available/zz-enana.cc.conf, mode 640, group 1, behind a sites-enabled link; other nginx and systemd files), the
# content directory (v1/: manifest.json, manifest.sig, content-<seq>.tar.gz, ping.json) and a download directory. nginx is
# played by a small HTTPS server on 127.0.0.1 (throw-away certificate) that answers from the configuration it last
# loaded: while that file's location /v1/ block has auth_request, every anonymous GET there is 401; without it the files
# under the block's root are served; POST is 403 (limit_except), the directory 403, a path above the root 400, anything
# outside /v1/ 404. The fake `systemctl reload nginx` loads the current file; the fake `nginx -t` passes unless told not to.
#   C1  usage and preconditions (not staged, no configuration, no signature / bundle, nginx -t fails now, nginx does not
#       answer, anonymous GET already served while the file still requires a session, the edit refuses the file): exit 2
#       and nothing touched (file, owner and mode, reloads, lock, backup, temp files)
#   C2  --check prints the edit and the current answer and changes nothing
#   C3  every failure after the install puts the previous file back with its owner and mode, and reloads only when the
#       edited file had been loaded: nginx -t rejects the edit, the reload fails, the reload does not take effect, other
#       bytes served, the directory listed, traversal served, POST accepted, the file changed meanwhile, another
#       nginx/systemd file / service / download changed; another publication holds the lock
#   C4  the install: backup (700: the previous file with its owner and mode, the edited file), exactly the edited file with
#       the same owner and mode behind the same link, nginx -t before and after, one reload, the anonymous checks it ran
#   C5  a second run (and --check) is a no-op: public already; a file that is public while nginx still refuses anonymous
#       GET (not reloaded) is refused
#   C6  never a restart / stop / start (only `reload nginx`), no temp file left, content and downloads unchanged
set -eu
[ "$(id -u)" = 0 ] || exec sudo -n env "PATH=$PATH" bash "$0" "$@"
repo=$(cd "$(dirname "$0")/.." && pwd -P)
w=$(cd "$(mktemp -d /tmp/enana-content-public.XXXXXX)" && pwd -P)
trap 'kill $(cat "$w/pids" 2>/dev/null) 2>/dev/null || true; rm -rf "$w"' EXIT
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; [ ! -s "$w/out" ] || sed 's/^/    | /' "$w/out" | head -40; exit 1; }
eq() { [ "$2" = "$3" ] && ok "$1" || { echo "  got:  $2"; echo "  want: $3"; bad "$1"; }; }
has() { grep -qF -- "$2" "$w/out" && ok "$1" || bad "$1 (expected: $2)"; }
lacks() { ! grep -qF -- "$2" "$w/out" && ok "$1" || bad "$1 (found: $2)"; }
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
failed() { [ "$rc" != 0 ] && echo failed || echo "exit 0"; }

# ---------- fake host ----------
E=$w/etc/nginx; C=$w/www/enana-cloud; D=$w/www/enana-dl
mkdir -p "$E/sites-available" "$E/sites-enabled" "$E/conf.d" "$w/etc/systemd/system" "$C/v1" "$w/www/other" "$D" "$w/bk" "$w/st" "$w/bin" "$w/stage/server"
cp "$repo/server/update-nginx-content.py" "$w/stage/server/"
conf=$E/sites-available/zz-enana.cc.conf
sed "s#/var/www/enana-cloud#$C#g" "$repo/tests/fixtures/nginx-enana.cc.conf" > "$conf"
chown 0:1 "$conf"; chmod 640 "$conf"
ln -s ../sites-available/zz-enana.cc.conf "$E/sites-enabled/zz-enana.cc.conf"
cp "$conf" "$w/orig.conf"
echo 'include /etc/nginx/sites-enabled/*;' > "$E/nginx.conf"; echo '# another site' > "$E/conf.d/other.conf"
printf '[Service]\nExecStart=/opt/enana-cc/pocketbase serve\n' > "$w/etc/systemd/system/enana-pocketbase.service"
seq=2026101801
head -c 3000 /dev/urandom > "$C/v1/content-$seq.tar.gz"
printf '{"channel":"stable","bundles":{"content":{"seq":%s,"version":"2026.10.18.01","url":"/v1/content-%s.tar.gz","sha256":"%s","size":%s,"min_client":"2.1.0"}}}' \
  "$seq" "$seq" "$(sha256sum "$C/v1/content-$seq.tar.gz" | cut -d' ' -f1)" "$(wc -c < "$C/v1/content-$seq.tar.gz" | tr -d ' ')" > "$C/v1/manifest.json"
head -c 71 /dev/urandom > "$C/v1/manifest.sig"
echo '{"ok":true}' > "$C/v1/ping.json"
cp -a "$C/v1" "$w/www/other/"; echo ' ' >> "$w/www/other/v1/manifest.json"   # what a wrong root would serve: other bytes
printf '2.3.26\n' > "$D/VERSION"; echo '{}' > "$D/manifest.json"
content_sum=$(cd "$w/www" && find . -type f -exec sha256sum {} + | LC_ALL=C sort | sha256sum | cut -d' ' -f1)
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$w/key.pem" -out "$w/cert.pem" -days 2 -subj /CN=api.enana.cc >/dev/null 2>&1

cat > "$w/bin/systemctl" <<'SH'
#!/bin/bash
# A fake systemctl: records every call; `reload nginx` makes the fake nginx load the current configuration file.
st=$FAKE_ST
echo "$*" >> "$st/systemctl"
once() { [ -e "$st/$1" ] && rm -f "$st/$1"; }   # a one-shot flag: true (and gone) when the test set it
case "$1" in
  list-units) printf 'ssh.service loaded active running OpenSSH\nnginx.service loaded active running nginx\nenana-pocketbase.service loaded active running PB\nenana-payments.service loaded active running pay\n' ;;
  show) echo "Id=$2"; echo "MainPID=$(cat "$st/pid.$2" 2>/dev/null || echo 100)"; echo "ActiveEnterTimestamp=t0" ;;
  is-active) echo active ;;
  reload)
    [ "$2" = nginx ] || exit 1
    echo reload >> "$st/reloads"
    if once reload_fails; then echo 'Job for nginx.service failed (test).' >&2; exit 1; fi
    [ -e "$st/reload_noop" ] || cp "$FAKE_CONF" "$st/loaded.conf"
    if once disturb_conf; then echo '# edited by someone else' >> "$FAKE_CONF"; fi
    if once disturb_config; then echo '# changed' >> "$FAKE_OTHER"; fi
    if once disturb_service; then echo 4242 > "$st/pid.ssh.service"; fi
    if once disturb_download; then echo changed >> "$FAKE_DL/VERSION"; fi
    ;;
  *) exit 1 ;;
esac
SH
cat > "$w/bin/nginx" <<'SH'
#!/bin/bash
# A fake nginx binary: only `nginx -t`. It fails when the test says so: always (nginx_t_fails), or only for the edited
# file (nginx_t_rejects_edit: the configuration has no auth_request line any more).
echo "$*" >> "$FAKE_ST/nginx"
[ "$*" = -t ] || exit 64
if [ -e "$FAKE_ST/nginx_t_fails" ] || { [ -e "$FAKE_ST/nginx_t_rejects_edit" ] && ! grep -q 'auth_request /_enana_auth;' "$FAKE_CONF"; }; then
  echo "nginx: [emerg] unexpected \"}\" in $FAKE_CONF (test)" >&2; echo 'nginx: configuration file test failed' >&2; exit 1
fi
echo 'nginx: the configuration file syntax is ok' >&2; echo 'nginx: configuration file test is successful' >&2
SH
chmod +x "$w/bin/systemctl" "$w/bin/nginx"

cat > "$w/fake-nginx.py" <<'PY'
import http.server, os, re, ssl, sys, urllib.parse
port, st, cert, key, other = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
def flag(name): return os.path.exists(os.path.join(st, name))
def loaded():
    """(requires a session, root) for /v1/ in the configuration this nginx last loaded."""
    try:
        text = open(os.path.join(st, 'loaded.conf'), encoding='utf-8').read()
    except OSError:
        return True, None
    m = re.search(r'^[ \t]*location /v1/ \{\n(.*?)^[ \t]*\}', text, re.S | re.M)
    block = m.group(1) if m else ''
    root = re.search(r'^[ \t]*root[ \t]+([^;\s]+);', block, re.M)
    return bool(re.search(r'^[ \t]*auth_request[ \t]', block, re.M)), (root.group(1) if root else None)
def normalize(raw):
    """The path as nginx sees it: decoded, dot segments resolved; None when it climbs above the root (nginx: 400)."""
    path, out = urllib.parse.unquote(raw.split('?', 1)[0]), []
    for seg in path.split('/')[1:]:
        if seg == '..':
            if not out: return None
            out.pop()
        elif seg not in ('', '.'):
            out.append(seg)
    return '/' + '/'.join(out) + ('/' if path.endswith('/') and out else '')
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, body=b'{}'):
        with open(os.path.join(st, 'requests'), 'a') as log: log.write('%s %s %d\n' % (self.command, self.path, code))
        self.send_response(code); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body))); self.end_headers()
        if self.command != 'HEAD': self.wfile.write(body)
    def route(self):
        gated, root = loaded()
        if flag('serve_other'): root = other
        path = normalize(self.path)
        if path is None: return self.reply(200, b'root:x:0:0:') if flag('traversal_ok') else self.reply(400)
        if not path.startswith('/v1/'): return self.reply(404)
        if self.command not in ('GET', 'HEAD'): return self.reply(200 if flag('post_ok') else 403, b'{"code":"forbidden"}')
        if gated: return self.reply(401, b'{"code":"unauthorized"}')
        if path.endswith('/'): return self.reply(200, b'manifest.json\n') if flag('list_ok') else self.reply(403, b'{"code":"forbidden"}')
        try:
            with open(root + path, 'rb') as f: body = f.read()
        except (OSError, TypeError):
            return self.reply(404)
        self.reply(200, body)
    do_GET = do_HEAD = route
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length') or 0)); self.route()
httpd = http.server.ThreadingHTTPServer(('127.0.0.1', port), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(cert, key)
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
httpd.serve_forever()
PY
port=$(free_port)
cp "$conf" "$w/st/loaded.conf"                     # nginx runs with the current file
python3 "$w/fake-nginx.py" "$port" "$w/st" "$w/cert.pem" "$w/key.pem" "$w/www/other" & echo $! > "$w/pids"
# The same request the script makes: https://api.enana.cc through 127.0.0.1, no session.
probe() { curl -q -s -k --noproxy '*' --path-as-is --max-time 5 --resolve "api.enana.cc:$port:127.0.0.1" -o "${2:-/dev/null}" -w '%{http_code}' "https://api.enana.cc:$port$1" 2>/dev/null || true; }
for _ in $(seq 1 50); do [ "$(probe /v1/manifest.json)" = 401 ] && break; sleep 0.1; done

export PATH="$w/bin:$PATH" FAKE_ST=$w/st FAKE_CONF=$conf FAKE_OTHER=$E/conf.d/other.conf FAKE_DL=$D
export ENANA_NGINX_CONF=$E/sites-enabled/zz-enana.cc.conf ENANA_NGINX_DIR=$E ENANA_SYSTEMD_DIR=$w/etc/systemd/system
export ENANA_CLOUD_DIR=$C ENANA_DL_DIR=$D ENANA_BACKUP_ROOT=$w/bk ENANA_PROBE_PORT=$port ENANA_RELOAD_WAIT=2
S=$repo/server/deploy-content-public.sh
rc=0
run() { set +e; "$@" >"$w/out" 2>&1; rc=$?; set -e; cat "$w/out" >> "$w/all"; }
python3 -I "$repo/server/update-nginx-content.py" "$w/orig.conf" "$w/expected.conf"   # what the install must install
hash_of() { sha256sum < "$1" | cut -d' ' -f1; }
conf_state() { echo "$(hash_of "$conf"):$(stat -c %a:%u:%g "$conf")"; }
orig_state="$(hash_of "$w/orig.conf"):640:0:1"; edited_state="$(hash_of "$w/expected.conf"):640:0:1"
reloads() { lines "$w/st/reloads"; }
backups_count() { ls -d "$w"/bk/releases/content-public-* 2>/dev/null | wc -l | tr -d ' '; }
untouched() { echo "$(conf_state):$(reloads):$(backups_count):$([ -e "$w/bk/content-publish.lock" ] && echo locked || echo unlocked)"; }
leftovers() { ls -A "$E/sites-available" | tr '\n' ' '; }
reset() { cat "$w/orig.conf" > "$conf"; cp "$conf" "$w/st/loaded.conf"; }   # the gated original again, owner and mode kept

# ---------- C1 usage and preconditions ----------
bash -n "$S" && ok "syntax"
eq "the fake nginx refuses anonymous GET /v1/manifest.json (401) before the change" "$(probe /v1/manifest.json)" "401"
run "$S"; eq "no arguments: usage, exit 2" "$rc" "2"; has "…prints the usage" "Usage:"
run "$S" "$w/stage" "$w/stage"; eq "two repositories: usage, exit 2" "$rc" "2"
base=$(untouched)
eq "(the fixture starts gated, 640, owner 0, group 1, nothing reloaded, no backup, no lock)" "$base" "$orig_state:0:0:unlocked"
run "$S" "$w/nowhere"; eq "not a staged repository: refused (exit 2)" "$rc" "2"; has "…says so" "is not a staged enana repository"
run env ENANA_NGINX_CONF="$w/missing.conf" "$S" "$w/stage"; eq "no nginx configuration: refused (exit 2)" "$rc" "2"; has "…says why" "unexpected host layout"
mv "$C/v1/manifest.sig" "$w/sig.moved"
run "$S" "$w/stage"; eq "no manifest signature: refused (exit 2)" "$rc" "2"; has "…names it" "$C/v1/manifest.sig is missing"
mv "$w/sig.moved" "$C/v1/manifest.sig"
mv "$C/v1/content-$seq.tar.gz" "$w/bundle.moved"
run "$S" "$w/stage"; eq "the bundle the manifest names is missing: refused (exit 2)" "$rc" "2"; has "…names it" "content-$seq.tar.gz"
mv "$w/bundle.moved" "$C/v1/content-$seq.tar.gz"
touch "$w/st/nginx_t_fails"
run "$S" "$w/stage"; eq "nginx -t fails on the current configuration: refused (exit 2)" "$rc" "2"; has "…says so" "nginx -t fails on the current configuration"
rm -f "$w/st/nginx_t_fails"
run env ENANA_PROBE_PORT="$(free_port)" "$S" "$w/stage"; eq "nginx does not answer locally: refused (exit 2)" "$rc" "2"; has "…says so" "nginx does not answer"
cp "$w/expected.conf" "$w/st/loaded.conf"         # the running nginx is already public although the file is not
run "$S" "$w/stage"; eq "anonymous GET already served while the file still requires a session: refused (exit 2)" "$rc" "2"; has "…shows the answer" "answers HTTP 200 now"
cp "$conf" "$w/st/loaded.conf"
{ cat "$w/orig.conf"; sed -n '/^    location \/v1\/ {$/,/^    }$/p' "$w/orig.conf"; } > "$conf"
run "$S" "$w/stage"; eq "a second location /v1/ block: the edit refuses (exit 2)" "$rc" "2"; has "…with its reason" "expected exactly one"
reset
eq "…none of that touched the file, its owner and mode, reloaded nginx, made a backup or took the lock" "$(untouched)" "$base"
eq "…and no temp file was left next to the configuration" "$(leftovers)" "zz-enana.cc.conf "

# ---------- C2 --check ----------
run "$S" --check "$w/stage"; eq "--check: exit 0" "$rc" "0"
has "…shows the line that goes" "-        auth_request /_enana_auth;"
has "…and the 401 page" "-        error_page 401 = @enana_unauthorized;"
has "…and the comment in their place" "+        # 公开内容"
has "…the current answer" "answers 401"
has "…and that it changed nothing" "Nothing was changed"
eq "…nothing changed" "$(untouched)" "$base"

# ---------- C3 failures after the install: the previous file is back ----------
touch "$w/st/nginx_t_rejects_edit"; r0=$(reloads); n0=$(backups_count)
run "$S" "$w/stage"; eq "nginx -t rejects the edited file: exit non-zero" "$(failed)" "failed"
has "…names the cause" "nginx -t rejects the edited configuration"; has "…the edited file was never loaded" "never loaded"
eq "…the previous file is back with its owner and mode, nothing was reloaded, the backup is kept" "$(conf_state):$(( $(reloads) - r0 )):$(( $(backups_count) - n0 ))" "$orig_state:0:1"
eq "…nginx still refuses anonymous GET" "$(probe /v1/manifest.json)" "401"
rm -f "$w/st/nginx_t_rejects_edit"

touch "$w/st/reload_fails"; r0=$(reloads)
run "$S" "$w/stage"; eq "the reload fails: rolled back, the previous file reloaded" "$(failed):$(conf_state):$(( $(reloads) - r0 ))" "failed:$orig_state:2"
has "…says nginx has the previous configuration again" "nginx reloaded it"
eq "…anonymous GET is refused again" "$(probe /v1/manifest.json)" "401"

touch "$w/st/reload_noop"; r0=$(reloads)
run "$S" "$w/stage"; eq "the reload does not take effect (old workers keep answering): rolled back" "$(failed):$(conf_state):$(( $(reloads) - r0 ))" "failed:$orig_state:2"
has "…names the cause" "still answers HTTP 401 after the reload"
rm -f "$w/st/reload_noop"; reset

check_rollback() { # <flag file> <cause the script prints> <description>
  local r0; r0=$(reloads); touch "$w/st/$1"
  run "$S" "$w/stage"; rm -f "$w/st/$1"
  eq "$3: rolled back, the previous file reloaded" "$(failed):$(conf_state):$(( $(reloads) - r0 ))" "failed:$orig_state:2"
  has "…names the cause" "$2"
  eq "…anonymous GET is refused again" "$(probe /v1/manifest.json)" "401"
}
check_rollback serve_other "nginx served other bytes" "nginx serves other bytes than the files on disk"
check_rollback list_ok "must not be listed" "nginx lists the content directory"
check_rollback traversal_ok "a path out of /v1/ must be refused" "nginx serves a path above /v1/"
check_rollback post_ok "the content must stay read-only" "nginx accepts a POST"
check_rollback disturb_conf "changed during the deployment" "the configuration file is changed by someone else meanwhile"
cp "$E/conf.d/other.conf" "$w/other.good"
check_rollback disturb_config "another nginx/systemd file changed" "another nginx file changes meanwhile"
cp "$w/other.good" "$E/conf.d/other.conf"
check_rollback disturb_service "another running service changed" "another running service changes meanwhile"
rm -f "$w/st/pid.ssh.service"
cp "$D/VERSION" "$w/version.good"
check_rollback disturb_download "a download or content file changed" "a download file changes meanwhile"
cp "$w/version.good" "$D/VERSION"

flock "$w/bk/content-publish.lock" sleep 3 & lockpid=$!
sleep 0.5
before=$(untouched)
run "$S" "$w/stage"; eq "another content publication holds the lock: refused (exit 2)" "$rc" "2"; has "…says so" "Another content publication"
eq "…nothing changed" "$(untouched)" "$before"
wait "$lockpid" 2>/dev/null || true

# ---------- C4 the install ----------
reset; r0=$(reloads); n0=$(backups_count); t0=$(lines "$w/st/nginx"); q0=$(lines "$w/st/requests")
run "$S" "$w/stage"; eq "the install: exit 0" "$rc" "0"
has "…reports it" "The signed cloud content is public"; has "…and the backup" "Backup: "
eq "…exactly the edited file is installed, with the previous owner and mode" "$(conf_state)" "$edited_state"
eq "…the sites-enabled link still points to it" "$(readlink "$E/sites-enabled/zz-enana.cc.conf")" "../sites-available/zz-enana.cc.conf"
eq "…nginx -t before and after the install, one reload, one backup" "$(( $(lines "$w/st/nginx") - t0 )):$(( $(reloads) - r0 )):$(( $(backups_count) - n0 ))" "2:1:1"
b=$(sed -n 's/^Backup: \([^ ]*\).*/\1/p' "$w/out")
eq "…the backup is mode 700 and holds the previous file (owner and mode kept) and the edited one" \
  "$(stat -c %a "$b"):$(hash_of "$b/nginx.conf"):$(stat -c %a:%u:%g "$b/nginx.conf"):$(hash_of "$b/nginx.updated")" "700:$(hash_of "$w/orig.conf"):640:0:1:$(hash_of "$w/expected.conf")"
eq "…anonymous GET now serves the manifest on disk" "$(probe /v1/manifest.json "$w/got"):$(cmp -s "$w/got" "$C/v1/manifest.json" && echo same)" "200:same"
sed -n "$((q0 + 1)),\$p" "$w/st/requests" > "$w/reqs"
for want in "GET /v1/manifest.json 401" "GET /v1/manifest.json 200" "GET /v1/manifest.sig 200" "GET /v1/content-$seq.tar.gz 200" "GET /v1/ 403" \
            "GET /v1/../../etc/passwd 400" "GET /v1/%2e%2e/%2e%2e/etc/passwd 400" "GET /v1/..%2f..%2fetc/passwd 400" "POST /v1/manifest.json 403"; do
  grep -qxF "$want" "$w/reqs" && ok "…it checked: $want" || { sed 's/^/    | /' "$w/reqs"; bad "…it did not check: $want"; }
done
has "…and reports the POST answer" "POST answers 403"

# ---------- C5 a second run ----------
r0=$(reloads); n0=$(backups_count); s0=$(conf_state)
run "$S" "$w/stage"; eq "a second run: exit 0" "$rc" "0"; has "…nothing to do" "public already"
eq "…no reload, no backup, the file unchanged" "$(( $(reloads) - r0 )):$(( $(backups_count) - n0 )):$(conf_state)" "0:0:$s0"
run "$S" --check "$w/stage"; eq "--check on a public host: exit 0, nothing changed" "$rc:$(conf_state)" "0:$s0"; has "…says so" "public already"
cp "$w/orig.conf" "$w/st/loaded.conf"             # the file is public, but the running nginx still has the old one
run "$S" "$w/stage"; eq "the file is public but nginx still refuses anonymous GET (not reloaded): refused (exit 2)" "$rc" "2"
has "…tells the operator to reload" "systemctl reload nginx"
eq "…nothing changed" "$(( $(reloads) - r0 )):$(( $(backups_count) - n0 )):$(conf_state)" "0:0:$s0"
cp "$conf" "$w/st/loaded.conf"

# ---------- C6 never more than a reload ----------
eq "systemctl was never asked to restart, stop or start anything" "$(grep -cvE '^(list-units|show|reload nginx)( |$)' "$w/st/systemctl" || true)" "0"
eq "no temp file was ever left next to the configuration" "$(leftovers)" "zz-enana.cc.conf "
eq "the content and download files are what the test wrote" "$(cd "$w/www" && find . -type f -exec sha256sum {} + | LC_ALL=C sort | sha256sum | cut -d' ' -f1)" "$content_sum"
cp "$w/all" "$w/out"; lacks "no run printed a Python traceback" "Traceback"
echo "ALL PASS"
