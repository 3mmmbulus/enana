#!/bin/bash
# Read-only SSH job regressions: bounded retries, cancellation of child processes,
# credential cleanup and a failed launcher. No real SSH or server mutation.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd -P)
w=$(mktemp -d /tmp/enana-vps-test.XXXXXX)
trap 'rm -rf "$w"' EXIT
export ENANA_HOME=$w/h ENANA_LANG=zh TEST_VPS_DIR=$w
mkdir -p "$w/h/jobs" "$w/playbook"
set +e # Library initialization also uses harmless boolean probes.
. "$repo/lib/common.sh"; init_paths "$repo/install.sh"
LIB=$repo/lib; DATA=$repo/data
. "$LIB/i18n.sh"; . "$LIB/jobs.sh"; . "$LIB/logs.sh"; . "$LIB/vps.sh"
load_settings
set -e
for f in lib probe provision redetect; do printf '# fixture\n' > "$w/playbook/$f.sh"; done
content_file() { printf '%s/playbook/%s' "$w" "${1#vps/}"; }
vps_fingerprints() {
  if [ "$TEST_VPS_MODE" = hostkey-hang ]; then
    sleep 30 & printf '%s\n' "$!" >> "$w/children"; wait
  else printf 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\tssh-ed25519\tfixture ssh-ed25519 AAAA\n'; fi
}
cat > "$w/ssh" <<'SH'
#!/bin/bash
n=$(cat "$TEST_VPS_DIR/count" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$TEST_VPS_DIR/count"
cat >/dev/null
case $TEST_VPS_MODE in
  ssh-hang) echo $$ >> "$TEST_VPS_DIR/children"; sleep 30 & echo $! >> "$TEST_VPS_DIR/children"; wait; exit 0 ;;
  auth) echo 'Permission denied (publickey,password).' >&2; exit 255 ;;
  unreachable) echo 'Connection timed out' >&2; exit 255 ;;
  flaky) if [ "$n" -lt 3 ]; then echo 'Connection timed out' >&2; exit 255; fi ;;
esac
echo '##kv os_pretty=FixtureOS'
echo '##kv supported=1'
echo '##kv privilege=root'
SH
chmod 700 "$w/ssh"; export ENANA_SSH=$w/ssh
run_probe() {
  : > "$w/children"; echo 0 > "$w/count"
  JOB_NAME=vps-probe; JOB_ID=$(job_new vps-probe '连接服务器|检测系统与环境|整理结果')
  vps_cred_write "$H/jobs/$JOB_ID.cred" fixture.invalid 22 root password fixture-password '' '' '' '' '' pin 0 '' 0
  ( set +e; vps_probe_job "$H/jobs/$JOB_ID.cred" ) > "$w/job.out" 2>&1 & probe_pid=$!
}
finish_probe() { wait "$probe_pid" || true; }
assert_result() {
  python3 - "$H/jobs/$JOB_ID.json" "$1" "${2:-}" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d['state']==sys.argv[2],d
if sys.argv[3]: assert d['result']['code']==sys.argv[3],d
PY
  [ ! -e "$H/jobs/$JOB_ID.cred" ]
}
export TEST_VPS_MODE=flaky
run_probe; finish_probe; assert_result done
[ "$(cat "$w/count")" = 3 ]; echo 'PASS: transient SSH failures retry at most three attempts and can recover'
export TEST_VPS_MODE=unreachable
run_probe; finish_probe; assert_result error E_SSH_UNREACHABLE
[ "$(cat "$w/count")" = 3 ]; echo 'PASS: persistent failure stops after three attempts'
export TEST_VPS_MODE=auth
run_probe; finish_probe; assert_result error E_SSH_AUTH
[ "$(cat "$w/count")" = 1 ]; echo 'PASS: rejected credentials are never automatically retried'
for mode in hostkey-hang ssh-hang; do
  export TEST_VPS_MODE=$mode; run_probe
  for i in $(seq 1 60); do [ -s "$w/children" ] && break; sleep 0.1; done
  [ -s "$w/children" ]; : > "$H/jobs/$JOB_ID.cancel"
  finish_probe; assert_result error E_CANCELLED
  while read -r child; do ! kill -0 "$child" 2>/dev/null; done < "$w/children"
  echo "PASS: cancellation terminates $mode and its child processes, with no credentials retained"
done
export TEST_VPS_MODE=ssh-hang
VPS_PROBE_TIMEOUT=1; run_probe; finish_probe; assert_result error E_SSH_UNREACHABLE
[ "$(cat "$w/count")" = 3 ]
while read -r child; do ! kill -0 "$child" 2>/dev/null; done < "$w/children"
echo 'PASS: each timed-out connection and its children are stopped before retry'
id=$(job_new vps-probe '连接服务器')
echo fixture-secret > "$H/jobs/$id.cred"
if job_launch vps-probe "$id" "$H/jobs/$id.cred"; then exit 1; fi
JOB_ID=$id; assert_result error E_JOB_LAUNCH
echo 'PASS: non-executable launcher reports failure and clears temporary credentials'
# Exercise the actual cancellation endpoint, including queued jobs with no PID.
python3 - "$repo/lib/api.sh" "$H" <<'PY'
import json,pathlib,subprocess,sys
source=pathlib.Path(sys.argv[1]).read_text()
function=source[source.index('ep_vps_cancel() {'):]; function=function[:function.index('\n}')+2]
h=pathlib.Path(sys.argv[2]); jobs=h/'jobs'
stub='''fp() { printf '%s' "$TEST_ID"; }
fail() { printf '%s' "$2"; exit 9; }
okj() { printf '{"ok":true,%s}' "$1"; }
oplog() { :; }; kv() { :; }
job_write() { printf '{"name":"%s","state":"%s","result":%s}' "$2" "$3" "$7" > "$H/jobs/$1.json"; }
'''
def invoke(identifier):
 import os
 return subprocess.run(['/bin/bash','-c',stub+function+'\nep_vps_cancel'],capture_output=True,text=True,
  env=dict(os.environ,H=str(h),TEST_ID=identifier))
for identifier,code in [('../unsafe','E_INVALID'),('vps-provision-1','E_INVALID'),('vps-probe-missing','E_NOT_FOUND')]:
 r=invoke(identifier); assert r.returncode==9 and r.stdout==code,(identifier,r)
identifier='vps-probe-queued'
(jobs/(identifier+'.json')).write_text('{"name":"vps-probe","state":"running","steps":[{"state":"pending"}]}')
(jobs/(identifier+'.cred')).write_text('fixture secret')
r=invoke(identifier); assert r.returncode==0 and json.loads(r.stdout)['requested'] is True,r
assert json.loads((jobs/(identifier+'.json')).read_text())['result']['code']=='E_CANCELLED'
assert not (jobs/(identifier+'.cred')).exists()
print('PASS: cancellation API rejects unsafe/non-probe IDs and finishes queued jobs without retaining credentials')
PY
