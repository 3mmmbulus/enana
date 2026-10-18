#!/bin/bash
# Make the signed cloud content on the enana account host downloadable without an enana account (2.3.27).
# Only the api.enana.cc `location /v1/ {` block of the nginx configuration changes (server/update-nginx-content.py): its
# auth_request and 401 error_page lines go. GET only, the rate limit, the JSON 403 page, root and no-cache stay, and so does
# everything else (location = /_enana_auth, @enana_unauthorized, session/check). /var/www/enana-cloud/v1/ holds only
# manifest.json, manifest.sig, content-<seq>.tar.gz and ping.json, and a client uses nothing it has not verified (manifest
# signature, no older sequence, sha256 and size, file-name allow-list), so public is safe.
# Same safety as deploy-prefs.sh, for nginx alone: no PocketBase stop or start, no hook, no migration, no download file.
#   * refuses unless it runs as root, the staged edit script and the host layout exist (the manifest, its signature and
#     the bundle it names), `nginx -t` passes now, the edit applies (exactly one location /v1/ block with exactly those two
#     lines) and nginx answers an anonymous GET /v1/manifest.json locally with 401. The local requests go to
#     https://api.enana.cc through 127.0.0.1:443 (--resolve: the real SNI and Host; -k: the origin certificate need not be
#     valid for that address) and carry no session;
#   * --check stops there: it prints the edit and the current answer and changes nothing;
#   * the install takes a lock, keeps a backup (/var/backups/enana/releases/content-public-<UTC time>-<pid>, mode 700: the
#     previous file, the edited file, before/after snapshots), checks that the live file is still the one the edit was
#     computed from, installs exactly the edited file (same owner and mode; temp file + mv), runs nginx -t, reloads nginx
#     (graceful; never a restart) and checks anonymously: manifest.json, manifest.sig and the bundle answer 200 with the
#     bytes on disk, /v1/ lists nothing (403/404), /v1/../ variants are refused (400/404), a POST is refused (403/405);
#     then that the installed file is still the edited one and that every other nginx/systemd file, every running service
#     (a reload keeps the nginx master PID) and every download and content file are unchanged;
#   * any failure after the install puts the previous file back (and reloads nginx when the edited file had been loaded)
#     and exits non-zero. A host where /v1/ is public already and served anonymously: nothing to do, exit 0.
#   Usage: deploy-content-public.sh STAGED_REPOSITORY            (as root; STAGED_REPOSITORY contains server/)
#          deploy-content-public.sh --check STAGED_REPOSITORY    (read-only: preconditions, the edit, the current answer)
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: deploy-content-public.sh [--check] STAGED_REPOSITORY
  --check   validate, print the nginx edit and what an anonymous request gets now; change nothing
Run as root on the enana account host (STAGED_REPOSITORY contains server/).
EOF
  exit 2
}
die() { echo "deploy-content-public: $*" >&2; exit 2; }
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
nginx_link=${ENANA_NGINX_CONF:-/etc/nginx/sites-enabled/zz-enana.cc.conf}
watch=("${ENANA_NGINX_DIR:-/etc/nginx}" "${ENANA_SYSTEMD_DIR:-/etc/systemd/system}")
cloud=${ENANA_CLOUD_DIR:-/var/www/enana-cloud}
dl=${ENANA_DL_DIR:-/var/www/enana-dl}
backups=${ENANA_BACKUP_ROOT:-/var/backups/enana}
port=${ENANA_PROBE_PORT:-443}
wait_s=${ENANA_RELOAD_WAIT:-10}
host=api.enana.cc
base=https://$host; [ "$port" = 443 ] || base=$base:$port
edit=$src/server/update-nginx-content.py

# One anonymous request to the local nginx as https://api.enana.cc (no Authorization, no session header). Prints the HTTP
# status (000 = no answer) and writes the body to the given file.
probe() { # <path> <body file> [curl options...]
  local path=$1 out=$2; shift 2
  curl -q -s -k --noproxy '*' --path-as-is --max-time 10 --resolve "$host:$port:127.0.0.1" -o "$out" -w '%{http_code}' "$@" "$base$path" 2>/dev/null || true
}

# ------------------------------------------------------------------------------------------- checks
for c in python3 nginx curl flock systemctl sha256sum diff cmp readlink; do command -v "$c" >/dev/null || die "$c is required."; done
[ -f "$edit" ] || die "$src is not a staged enana repository ($edit is missing)."
[ -e "$nginx_link" ] || die "unexpected host layout: $nginx_link is missing."
nginx_file=$(readlink -f -- "$nginx_link")
[ -f "$nginx_file" ] || die "unexpected host layout: $nginx_link is not a regular file."
for f in manifest.json manifest.sig; do [ -f "$cloud/v1/$f" ] || die "unexpected host layout: $cloud/v1/$f is missing."; done
bundle=$(python3 -I - "$cloud/v1/manifest.json" 2>/dev/null <<'PY'
import json, re, sys
url = json.load(open(sys.argv[1], encoding='utf-8'))['bundles']['content']['url']
if not isinstance(url, str) or not re.fullmatch(r'/v1/content-[0-9]+\.tar\.gz', url):
    sys.exit(1)
print(url)
PY
) || die "$cloud/v1/manifest.json does not name a content bundle a client accepts (/v1/content-<seq>.tar.gz)."
[ -f "$cloud$bundle" ] || die "unexpected host layout: the bundle the manifest names is missing ($cloud$bundle)."

tmpd=$(mktemp -d)
trap 'rm -rf -- "$tmpd"' EXIT
nginx -t >"$tmpd/nginx-t" 2>&1 || { cat "$tmpd/nginx-t" >&2; die 'nginx -t fails on the current configuration; fix that first. Nothing was changed.'; }

# The edit is computed once, from a copy. The file shown below is exactly the file that gets installed.
cp -p -- "$nginx_file" "$tmpd/nginx.conf"
rc=0; python3 -I "$edit" "$tmpd/nginx.conf" "$tmpd/nginx.updated" 2>"$tmpd/edit.err" || rc=$?
if [ "$rc" = 3 ]; then
  code=$(probe /v1/manifest.json /dev/null)
  [ "$code" = 200 ] || die "$nginx_file no longer requires a session for /v1/, but an anonymous GET $base/v1/manifest.json answers HTTP $code (expected 200): the running nginx has probably not loaded that file. Review it, then: nginx -t && systemctl reload nginx. Nothing was changed."
  note "The cloud content is public already: $nginx_file has no auth_request for /v1/ and an anonymous GET $base/v1/manifest.json answers 200. Nothing to do."
  exit 0
fi
[ "$rc" = 0 ] || { cat "$tmpd/edit.err" >&2; die 'the nginx edit was refused (reason above). Nothing was changed.'; }
note "The nginx edit ($nginx_file):"
diff -u --label "$nginx_file" --label "$nginx_file (edited)" "$tmpd/nginx.conf" "$tmpd/nginx.updated" || true

code=$(probe /v1/manifest.json /dev/null)
case $code in
  401) note "Now: an anonymous GET $base/v1/manifest.json answers 401 (an account session is required)." ;;
  000) die "nginx does not answer $base through 127.0.0.1:$port, so the content could not be checked after the reload. Nothing was changed." ;;
  *) die "an anonymous GET $base/v1/manifest.json answers HTTP $code now (expected 401 from the session check); review before editing. Nothing was changed." ;;
esac

if [ "$mode" = check ]; then
  note 'Check passed: the edit above would be installed, nginx tested and reloaded (not restarted) and the content checked anonymously. Nothing was changed.'
  exit 0
fi

# ------------------------------------------------------------------------------------------- install
ensure_backup_dir() { [ -d "$backups" ] || install -d -m 700 "$backups"; [ -d "$backups/releases" ] || install -d -m 700 "$backups/releases"; }
ensure_backup_dir
exec 9>"$backups/content-publish.lock"
flock -n 9 || die 'Another content publication is running.'
backup="$backups/releases/content-public-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -m 700 "$backup"
cp -p -- "$tmpd/nginx.conf" "$backup/nginx.conf"
cp -- "$tmpd/nginx.updated" "$backup/nginx.updated"
# The edit was computed from a copy taken before the lock: the live file must still be exactly that copy.
cmp -s -- "$nginx_file" "$backup/nginx.conf" || die "$nginx_file changed while this ran (another deployment?). Nothing was changed; run it again."

dirs=(); for d in "${watch[@]}"; do [ -d "$d" ] && dirs+=("$(readlink -f -- "$d")"); done
content=(); for d in "$dl" "$cloud"; do [ -d "$d" ] && content+=("$d"); done
snapshot_services() {
  systemctl list-units --type=service --state=running --no-pager --plain --no-legend | awk '{print $1}' | sort | while read -r service; do
    systemctl show "$service" --property=Id,MainPID,ActiveEnterTimestamp
  done
}
snapshot_configs() { { [ ${#dirs[@]} -eq 0 ] || find "${dirs[@]}" -type f ! -path "$nginx_file" -exec sha256sum {} + 2>/dev/null || true; } | sort; }
snapshot_content() { { find "${content[@]}" -type f -exec sha256sum {} + 2>/dev/null || true; } | sort; }
snapshot_services > "$backup/services.before"
snapshot_configs > "$backup/configs.before"
snapshot_content > "$backup/content.before"

nginx_tmp="$(dirname -- "$nginx_file")/.$(basename -- "$nginx_file").enana-$$"
installed=0; reloaded=0; committed=0
rollback() {
  local rc=$?
  trap - EXIT
  set +e                             # attempt every restore step even if one of them fails
  if [ "$committed" = 0 ] && [ "$installed" = 1 ]; then
    [ "$rc" != 0 ] || rc=1
    echo "deploy-content-public: FAILED (exit $rc); restoring the previous nginx configuration." >&2
    if cp -p -- "$backup/nginx.conf" "$nginx_tmp" && mv -f -- "$nginx_tmp" "$nginx_file" && cmp -s -- "$backup/nginx.conf" "$nginx_file"; then
      if [ "$reloaded" = 0 ]; then
        echo "Rolled back: $nginx_file is the previous file again; the edited one was never loaded. Backup: $backup" >&2
      elif nginx -t >/dev/null 2>&1 && systemctl reload nginx 9>&-; then
        echo "Rolled back: the previous configuration is back and nginx reloaded it. Backup: $backup" >&2
      else
        echo "RESTORED $nginx_file, BUT nginx -t OR THE RELOAD FAILED: run nginx -t, then systemctl reload nginx. Backup: $backup" >&2
      fi
    else
      echo "ROLLBACK FAILED: copy $backup/nginx.conf over $nginx_file by hand, then: nginx -t && systemctl reload nginx" >&2
    fi
  fi
  rm -f -- "$nginx_tmp"; rm -rf -- "$tmpd"
  exit "$rc"
}
trap rollback EXIT

installed=1                          # set first: from here on any failure puts the previous file back
cp -- "$backup/nginx.updated" "$nginx_tmp"
chown --reference="$nginx_file" -- "$nginx_tmp"
chmod --reference="$nginx_file" -- "$nginx_tmp"
mv -f -- "$nginx_tmp" "$nginx_file"
cmp -s -- "$backup/nginx.updated" "$nginx_file" || { echo "the installed $nginx_file differs from the edited copy." >&2; exit 1; }
nginx -t >"$tmpd/nginx-t" 2>&1 || { cat "$tmpd/nginx-t" >&2; echo 'nginx -t rejects the edited configuration.' >&2; exit 1; }
reloaded=1                           # set first: a reload that fails half-way may already have loaded the edited file
systemctl reload nginx 9>&-          # the lock descriptor must not leak into anything the reload spawns

# A graceful reload: the old workers may answer a moment longer. Wait until the anonymous request is served.
code=000
for _ in $(seq 1 $((wait_s * 2))); do
  sleep 0.5
  code=$(probe /v1/manifest.json "$tmpd/manifest.json")
  [ "$code" != 200 ] || break
done
[ "$code" = 200 ] || { echo "an anonymous GET $base/v1/manifest.json still answers HTTP $code after the reload (expected 200); an auth_request at the server or http level, or another location for /v1/, would explain it." >&2; exit 1; }
cmp -s -- "$tmpd/manifest.json" "$cloud/v1/manifest.json" || { echo "the anonymous GET /v1/manifest.json did not return $cloud/v1/manifest.json: nginx served other bytes." >&2; exit 1; }
for path in /v1/manifest.sig "$bundle"; do
  code=$(probe "$path" "$tmpd/body")
  [ "$code" = 200 ] && cmp -s -- "$tmpd/body" "$cloud$path" || { echo "an anonymous GET $path answered HTTP $code, not $cloud$path (expected 200 with the file's bytes)." >&2; exit 1; }
done
code=$(probe /v1/ /dev/null)
case $code in 403|404) ;; *) echo "GET /v1/ answered HTTP $code (expected 403 or 404): the content directory must not be listed." >&2; exit 1 ;; esac
for path in '/v1/../../etc/passwd' '/v1/%2e%2e/%2e%2e/etc/passwd' '/v1/..%2f..%2fetc/passwd'; do
  code=$(probe "$path" /dev/null)
  case $code in 400|404) ;; *) echo "GET $path answered HTTP $code (expected 400 or 404): a path out of /v1/ must be refused." >&2; exit 1 ;; esac
done
post=$(probe /v1/manifest.json /dev/null --data '')
case $post in 403|405) ;; *) echo "POST /v1/manifest.json answered HTTP $post (expected 403 or 405): the content must stay read-only." >&2; exit 1 ;; esac

cmp -s -- "$backup/nginx.updated" "$nginx_file" || { echo "$nginx_file changed during the deployment." >&2; exit 1; }
snapshot_services > "$backup/services.after"
snapshot_configs > "$backup/configs.after"
snapshot_content > "$backup/content.after"
cmp -s "$backup/services.before" "$backup/services.after" || { echo 'another running service changed during the deployment (a reload keeps the nginx master PID; a restart would not).' >&2; exit 1; }
cmp -s "$backup/configs.before" "$backup/configs.after" || { echo 'another nginx/systemd file changed during the deployment.' >&2; exit 1; }
cmp -s "$backup/content.before" "$backup/content.after" || { echo 'a download or content file changed during the deployment.' >&2; exit 1; }

committed=1
trap - EXIT
rm -rf -- "$tmpd"
note "The signed cloud content is public: anonymous GETs of $base/v1/manifest.json, /v1/manifest.sig and $bundle answer 200 with the files on disk; /v1/ is not listed, /v1/../ is refused, POST answers $post. nginx was reloaded, not restarted; other services, nginx/systemd files, downloads and content are unchanged."
note "Backup: $backup   (to undo by hand: cp -p $backup/nginx.conf $nginx_file && nginx -t && systemctl reload nginx)"
