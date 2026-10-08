"""Official route nodes through the real local CGI (lib/api.sh): how they appear in the server list, and the guarantees
that they cannot be viewed, deleted, re-roled or exported. Synthetic data only; no network, no sing-box needed."""
import hashlib
import json
import os
import pathlib
import socket
import subprocess
import tempfile
import time
import unittest
import urllib.parse
import urllib.request

repo = pathlib.Path(__file__).resolve().parents[1]
OFFICIAL_TAG = '官方-美国'
OFFICIAL_ROW = {'role': 'auto', 'official': True, 'outbound': {'type': 'http', 'tag': OFFICIAL_TAG, 'server': 'h.example.invalid', 'server_port': 443, 'username': 'official-user', 'password': 'official-secret-pw'}}
MINE_ROW = {'role': 'auto', 'outbound': {'type': 'trojan', 'tag': 'Mine', 'server': '203.0.113.9', 'server_port': 443, 'password': 'mine-secret-pw'}}


def jsonl(*rows):
    return ''.join(json.dumps(r, ensure_ascii=False, separators=(',', ':')) + '\n' for r in rows)


class OfficialBridge(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = pathlib.Path(self.tmp.name)
        (self.home / 'secret').write_text('local-test-token\n')
        (self.home / 'servers.jsonl').write_text(jsonl(MINE_ROW))
        (self.home / 'official.jsonl').write_text(jsonl(OFFICIAL_ROW))
        # a valid step-up (sudo) token: the sensitive routes check "sha256(token) expiry" lines
        (self.home / 'sudo.tokens').write_text('%s %d\n' % (hashlib.sha256(b'0123456789abcdef0123456789abcdef').hexdigest(), int(time.time()) + 300))
        self.env = {**os.environ, 'ENANA_HOME': self.tmp.name, 'ENANA_API_PIPE': '1', 'API_PORT': '19379', 'PORT': '19380'}

    def tearDown(self):
        self.tmp.cleanup()

    def cgi(self, path, body=None, sudo=False):
        raw = json.dumps(body).encode() if body is not None else b''
        head = ('%s %s HTTP/1.1\r\nHost: 127.0.0.1:19379\r\nX-Enana: 1\r\nX-Enana-Token: local-test-token\r\n' % ('POST' if body is not None else 'GET', path)
                + ('X-Enana-Sudo: 0123456789abcdef0123456789abcdef\r\n' if sudo else '') + 'Content-Length: %d\r\nContent-Type: application/json\r\n\r\n' % len(raw)).encode()
        r = subprocess.run(['/bin/bash', str(repo / 'lib/api.sh')], env=self.env, input=head + raw, capture_output=True, timeout=60)
        text = r.stdout.split(b'\r\n\r\n', 1)[1].decode()
        return json.loads(text), text

    def q(self, tag):
        return urllib.parse.quote(tag)

    def test_server_list_marks_official_rows_and_hides_their_address(self):
        d, _ = self.cgi('/api/state')
        by = {s['tag']: s for s in d['servers']}
        self.assertNotIn('official', by['Mine']); self.assertEqual(by['Mine']['server'], '203.0.113.9')
        o = by[OFFICIAL_TAG]
        self.assertIs(o['official'], True); self.assertEqual(o['role'], 'auto'); self.assertEqual(o['type'], 'http')
        self.assertEqual((o['server'], o['port']), ('', 0), 'the dashboard never sees the address of an official node')
        self.assertFalse(d['first_run'])

    def test_only_official_nodes_still_counts_as_first_run(self):
        (self.home / 'servers.jsonl').write_text('')
        d, _ = self.cgi('/api/state')
        self.assertTrue(d['first_run'], 'the setup wizard is about the user\'s own servers')
        self.assertEqual([s['tag'] for s in d['servers']], [OFFICIAL_TAG])

    def test_credentials_of_official_nodes_cannot_be_viewed_but_own_ones_can(self):
        d, text = self.cgi('/api/servers/secret?tag=' + self.q(OFFICIAL_TAG), sudo=True)
        self.assertFalse(d['ok']); self.assertEqual(d['code'], 'E_FORBIDDEN')
        self.assertNotIn('official-secret-pw', text); self.assertNotIn('official-user', text)
        d, _ = self.cgi('/api/servers/secret?tag=Mine', sudo=True)
        self.assertTrue(d['ok']); self.assertEqual({f['name']: f['value'] for f in d['fields']}, {'password': 'mine-secret-pw'})

    def test_official_nodes_cannot_be_deleted_or_given_another_role(self):
        for path in ('/api/servers/delete?tag=' + self.q(OFFICIAL_TAG), '/api/servers/role?tag=%s&role=pin' % self.q(OFFICIAL_TAG)):
            d, _ = self.cgi(path, body={}, sudo=True)
            self.assertFalse(d['ok']); self.assertEqual(d['code'], 'E_FORBIDDEN', path)
        self.assertIn(OFFICIAL_TAG, (self.home / 'official.jsonl').read_text())

    def test_export_and_cloud_sync_snapshot_never_contain_official_nodes(self):
        d, text = self.cgi('/api/export', sudo=True)
        self.assertNotIn('official-secret-pw', text); self.assertNotIn(OFFICIAL_TAG, text); self.assertNotIn('h.example.invalid', text)
        self.assertIn('Mine', text)

    def test_user_cannot_import_a_node_that_takes_an_official_name(self):
        row = {'role': 'auto', 'outbound': {'type': 'trojan', 'tag': '官方-我的', 'server': '203.0.113.20', 'server_port': 443, 'password': 'x'}}
        ok = {'role': 'auto', 'outbound': {'type': 'trojan', 'tag': 'Fine', 'server': '203.0.113.21', 'server_port': 443, 'password': 'x'}}
        raw = jsonl(row, ok)
        r = subprocess.run(['/bin/bash', '-c', '. "$1/lib/common.sh"; init_paths "$1/install.sh"; for f in servers; do . "$LIB/$f.sh"; done; load_settings 2>/dev/null; srv_import "" merge < "$2"', 'test', str(repo), '/dev/stdin'],
                           env=self.env, input=raw.encode(), capture_output=True, timeout=30)
        self.assertEqual(r.stdout.decode().split(), ['1', '0', '0'], r.stderr.decode())
        text = (self.home / 'servers.jsonl').read_text()
        self.assertIn('Fine', text); self.assertNotIn('官方-我的', text)


class OfficialSyncAgainstMockCloud(unittest.TestCase):
    """The real client code (session_call -> curl -> official_ingest -> official_apply) against tests/mock-account.py,
    which implements the documented GET /api/enana/v1/nodes contract. Only apply_config is replaced by a counter."""

    @classmethod
    def setUpClass(cls):
        s = socket.socket(); s.bind(('127.0.0.1', 0)); cls.port = s.getsockname()[1]; s.close()
        cls.cloud = subprocess.Popen(['python3', str(repo / 'tests/mock-account.py'), str(cls.port)])
        cls.base = 'http://127.0.0.1:%d' % cls.port
        for _ in range(100):
            try:
                urllib.request.urlopen(cls.base + '/api/health', timeout=1).read(); break
            except Exception:
                time.sleep(0.05)

    @classmethod
    def tearDownClass(cls):
        cls.cloud.terminate(); cls.cloud.wait()

    def post(self, path):
        return json.loads(urllib.request.urlopen(urllib.request.Request(self.base + path, data=b'{}', method='POST'), timeout=5).read())

    def get(self, path):
        return json.loads(urllib.request.urlopen(self.base + path, timeout=5).read())

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.home = pathlib.Path(self.tmp.name)
        uid = 'dev-official-' + os.urandom(3).hex()
        self.post('/_test/seed?email=user1@example.test&uid=' + uid + '&platform=macos')
        sid = [x['id'] for x in self.get('/_test/sessions')['sessions'] if x['uid'] == uid][0]
        (self.home / 'session').write_text(sid + '\n'); (self.home / 'cloud.token').write_text('tok-' + sid + '\n')
        self.env = {**os.environ, 'ENANA_HOME': self.tmp.name, 'ENANA_ACCOUNT_URL': self.base, 'LC_ALL': 'C', 'PORT': '39800', 'UI_PORT': '39801', 'API_PORT': '39802', 'SPEED_PORT': '39803'}
        self.post('/_test/nodes?mode=none')

    def tearDown(self):
        self.tmp.cleanup()

    def sync(self, mode, extra=''):
        self.post('/_test/nodes?mode=' + mode)
        script = '''. "$1/lib/common.sh"; init_paths "$1/install.sh"; LIB=$1/lib; DATA=$1/data
for _f in i18n jobs servers apps autosites sites fetch os-darwin enhanced auth device session cloud dns logs health update config ops speed stats prefs snapshot plan official sync vps; do . "$LIB/$_f.sh"; done
load_settings; QUIET=1
auth_logged_in() { return 0; }
apply_config() { echo x >> "$H/applies"; APPLY_CHANGED=1; return 0; }
%s
official_sync; echo "rc=$?"''' % extra
        r = subprocess.run(['/bin/bash', '-c', script, 'test', str(repo)], env=self.env, capture_output=True, text=True, timeout=60)
        return r.stdout.strip().splitlines()[-1], r

    def lines(self):
        f = self.home / 'official.jsonl'
        return f.read_text().splitlines() if f.exists() else None

    def applies(self):
        f = self.home / 'applies'
        return len(f.read_text().splitlines()) if f.exists() else 0

    def test_end_to_end_contract(self):
        rc, r = self.sync('ok'); self.assertEqual(rc, 'rc=0', r.stderr)
        rows = [json.loads(x) for x in self.lines()]
        self.assertEqual([x['outbound']['tag'] for x in rows], sorted(x['outbound']['tag'] for x in rows))
        self.assertTrue(all(x['role'] == 'auto' and x['official'] is True and list(x['outbound'])[:2] == ['type', 'tag'] for x in rows)); self.assertEqual(len(rows), 3)
        self.assertEqual(oct((self.home / 'official.jsonl').stat().st_mode & 0o777), '0o600')
        self.assertEqual(self.applies(), 1); self.assertEqual(self.get('/_test/hits')['node_hits'] >= 1, True)
        first = (self.home / 'official.jsonl').read_bytes()
        rc, _ = self.sync('ok2'); self.assertEqual(rc, 'rc=0')
        self.assertEqual((self.home / 'official.jsonl').read_bytes(), first, 'same nodes in another order: identical bytes'); self.assertEqual(self.applies(), 1, 'unchanged -> no config regeneration, no restart')
        rc, _ = self.sync('changed'); self.assertEqual(rc, 'rc=0'); self.assertEqual(len(self.lines()), 4); self.assertEqual(self.applies(), 2)
        rc, _ = self.sync('500'); self.assertEqual(rc, 'rc=1'); self.assertEqual(len(self.lines()), 4, 'a failing cloud never wipes the nodes'); self.assertEqual(self.applies(), 2)
        rc, _ = self.sync('junk'); self.assertEqual(rc, 'rc=1'); self.assertEqual(len(self.lines()), 4)
        rc, _ = self.sync('empty'); self.assertEqual(rc, 'rc=0'); self.assertEqual(len(self.lines()), 4, 'entitled but nothing to serve right now: keep')
        state = (self.home / 'official.state').read_text()
        self.assertIn('entitled=1', state); self.assertIn('fails=0', state)
        rc, _ = self.sync('none'); self.assertEqual(rc, 'rc=0'); self.assertIsNone(self.lines(), 'entitled:false removes every official node'); self.assertEqual(self.applies(), 3)
        self.assertIn('entitled=0', (self.home / 'official.state').read_text())

    def cgi_json(self, path):
        (self.home / 'secret').write_text('local-test-token\n')
        req = ('GET %s HTTP/1.1\r\nHost: 127.0.0.1:39802\r\nX-Enana: 1\r\nX-Enana-Token: local-test-token\r\nContent-Length: 0\r\n\r\n' % path).encode()
        env = {**self.env, 'ENANA_API_PIPE': '1'}
        r = subprocess.run(['/bin/bash', str(repo / 'lib/api.sh')], env=env, input=req, capture_output=True, timeout=60)
        return json.loads(r.stdout.split(b'\r\n\r\n', 1)[1])

    def test_forced_plan_refresh_sees_a_purchase_immediately(self):
        # without ?refresh=1 the helper answers from its local cache (up to an hour old): a paying user would still see Free
        self.post('/_test/plan?code=free')
        self.assertEqual(self.cgi_json('/api/plan')['plan']['code'], 'free')
        self.post('/_test/plan?code=pro')
        self.assertEqual(self.cgi_json('/api/plan')['plan']['code'], 'free', 'cached')
        (self.home / 'plan.checked').write_text('%d\n' % (int(time.time()) - 10))          # older than the 3-second guard, far younger than the 1-hour TTL
        d = self.cgi_json('/api/plan?refresh=1')
        self.assertEqual((d['plan']['code'], d['features']['official_proxy']['enabled']), ('pro', True))
        again = self.cgi_json('/api/plan?refresh=1')                                         # a second forced call within 3 seconds reuses the fresh copy
        self.assertEqual(again['plan']['code'], 'pro')

    def test_session_loss_is_a_failure_not_a_removal(self):
        self.sync('ok')
        (self.home / 'cloud.token').write_text('tok-wrong\n')                    # the cloud answers 401: the heartbeat deals with it, nodes stay
        rc, _ = self.sync('ok'); self.assertEqual(rc, 'rc=1'); self.assertEqual(len(self.lines()), 3)
        self.assertIn('fails=1', (self.home / 'official.state').read_text())

    def test_tick_does_not_call_the_cloud_again_until_due(self):
        self.sync('ok'); hits = self.get('/_test/hits')['node_hits']
        script = '''. "$1/lib/common.sh"; init_paths "$1/install.sh"; LIB=$1/lib; DATA=$1/data
for _f in i18n jobs servers apps autosites sites fetch os-darwin enhanced auth device session cloud dns logs health update config ops speed stats prefs snapshot plan official sync vps; do . "$LIB/$_f.sh"; done
load_settings; QUIET=1; auth_logged_in() { return 0; }; apply_config() { return 0; }
official_tick; official_tick; official_tick'''
        subprocess.run(['/bin/bash', '-c', script, 'test', str(repo)], env=self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(self.get('/_test/hits')['node_hits'], hits, 'a sync a moment ago: the minute tick only reads a small state file')


if __name__ == '__main__':
    unittest.main()
