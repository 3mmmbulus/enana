#!/usr/bin/env python3
"""No-account mode (2.3.27, docs/API.md「账号 / 登录」): the dashboard and everything local work without an enana account.

Drives the real local helper (lib/api.sh, one CGI process per request as under launchd's inetd mode) and the real
shell libraries against a fake enana cloud on 127.0.0.1 that records every request:
  · GET /api/auth/status: required:false, logged_in, local:true; POST /api/auth/local hands the local token (= the
    Clash API secret) to the dashboard signed out and signed in, and refuses wrong Host / missing X-Enana / foreign
    Origin / cross-site requests; a missing secret is created; a fresh install fetches cloud content once in the background
  · every account-only endpoint answers HTTP 200 E_LOGIN_REQUIRED when signed out and never reaches the cloud;
    GET /api/sync and GET /api/plan stay usable with logged_in:false and a neutral state
  · step-up: no X-Enana-Sudo needed signed out, enforced signed in (incl. POST /api/billing/purchase|auto-renew)
  · signing out (also switch=1), being kicked and the offline expiry keep the proxy setting and the token; signing in to
    another account keeps the proxy setting
  · cloud content without an account: anonymous download (no Authorization / X-Enana-Session) with the same signature /
    anti-rollback / checksum checks; a cloud that still requires sign-in keeps the content calmly and the daily
    maintenance does not log an error every day; `enana on` and `enana content` work without signing in
Synthetic data only: no sing-box, no administrator rights, no traffic outside 127.0.0.1 (tests/fakebin is first in PATH).
Run: python3 tests/no-account.py   (macOS; .github/workflows/macos.yml)"""
import hashlib
import http.server
import json
import os
import pathlib
import re
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.parse

repo = pathlib.Path(__file__).resolve().parents[1]
FAKEBIN = repo / 'tests' / 'fakebin'
LIBS = ('i18n jobs servers apps autosites sites fetch os enhanced auth device session cloud dns logs health update config ops exits '
        'speed stats prefs snapshot plan official sync vps diag')
TOKEN = '0123456789abcdef0123456789abcdef'           # the local token (= $H/secret = Clash API secret)
SUDO = 'fedcba9876543210fedcba9876543210'            # a step-up token (sudo.tokens keeps only its sha256)
LOGIN_ZH = '需要登录 enana 账号才能使用这个功能'
LOGIN_EN = 'Sign in to your enana account to use this feature'
ANON_MSG = '云端内容暂时需要登录 enana 账号才能下载, 已保留本机现有的内容'
PURCHASE = json.dumps({'sku': 'm1', 'request_key': 'k' * 32}).encode()
RENEW = b'{"enabled":true}'
OFFICIAL_ROW = '{"role":"auto","official":true,"outbound":{"type":"http","tag":"官方-测试","server":"o.example.invalid","server_port":443}}\n'

# The contract: every account-only endpoint (docs/API.md「账号功能」). The table in lib/api.sh must list exactly these
# (plus every /api/billing* and /api/email/* route through the prefix rule).
ACCOUNT_ONLY = [
    ('GET', '/api/devices'), ('POST', '/api/devices/kick'), ('POST', '/api/password'), ('POST', '/api/auth/verify'),
    ('POST', '/api/sync/settings'), ('POST', '/api/sync/push'), ('POST', '/api/sync/pull'), ('POST', '/api/sync/preview'),
    ('POST', '/api/sync/clear'), ('POST', '/api/diag/send'), ('POST', '/api/diag/delete'),
    ('GET', '/api/billing'), ('POST', '/api/billing/checkout'), ('GET', '/api/billing/order?id=abcdefghij12345'),
    ('POST', '/api/billing/cancel'), ('POST', '/api/billing/order/recheck'), ('POST', '/api/billing/purchase'),
    ('POST', '/api/billing/auto-renew'), ('GET', '/api/email/status'), ('POST', '/api/email/send'),
]
# Step-up (SUDO_ENDPOINTS): local ones, with what they answer signed out once the step-up is skipped …
SUDO_LOCAL = [
    ('GET', '/api/sub/url?name=nope', b'', 'E_NOT_FOUND'),
    ('GET', '/api/servers/secret?tag=Nope', b'', 'E_NOT_FOUND'),
    ('POST', '/api/servers/delete?tag=Nope', b'', 'E_NOT_FOUND'),
    ('POST', '/api/sub/delete?name=bad%2Fname', b'', 'E_INVALID'),
    ('POST', '/api/logs/clear', b'type=bogus', 'E_INVALID'),
    ('GET', '/api/export', b'', None),                       # the backup itself (attachment)
]
# … and the ones that also need an account (E_LOGIN_REQUIRED signed out, E_SUDO_REQUIRED signed in without step-up)
SUDO_ACCOUNT = [
    ('POST', '/api/devices/kick', b'uid=dev-aaaa-1111'), ('POST', '/api/sync/clear', b''),
    ('POST', '/api/billing/purchase', PURCHASE), ('POST', '/api/billing/auto-renew', RENEW),
]
# … and leaving / replacing the signed-in account: guarded too while signed in (otherwise signing out first, or signing in to an
# account of your own, would skip every step-up above). Signed out they work as usual (logout is a no-op, bad input is refused).
SUDO_SESSION = [
    ('POST', '/api/logout', b'', None),
    ('POST', '/api/login', b'user=not-an-email&password=whatever', 'E_INVALID'),
    ('POST', '/api/register', b'user=not-an-email&password=longenough1', 'E_INVALID'),
]
# shell helpers: no core, no rule downloads, no app scan (only the cloud-content code under test runs for real)
STUB_APPLY = 'apply_config() { printf "%s\\n" "${APPS_BG_JOB:-}" >> "$ENANA_HOME/applies"; APPLY_CHANGED=1; return 0; }\n'
STUB_CONTENT = STUB_APPLY + 'rules_update() { :; }; apps_rerecommend() { :; }; ovr_sync() { :; }\n'
MAINTAIN = STUB_CONTENT + ('logs_maintain() { :; }; stats_purge() { :; }; update_check() { :; }\n'
                           'plan_refresh() { echo plan >> "$ENANA_HOME/plan-calls"; return 0; }\n'
                           'op_maintain; echo "maintained rc=$?"\n')
PRE = '''REPO=$1
. "$REPO/lib/common.sh"; init_paths "$REPO/install.sh"; LIB=$REPO/lib; DATA=$REPO/data
for _f in %s; do . "$LIB/$_f.sh"; done
load_settings; QUIET=1
[ "$H" = "$ENANA_HOME" ] || { echo "REFUSING: the data directory is not the temporary one ($H)"; exit 99; }
''' % LIBS


def free_port():
    s = socket.socket(); s.bind(('127.0.0.1', 0)); p = s.getsockname()[1]; s.close()
    return p


class FakeCloud:
    """The enana cloud as far as the client uses it here. /v1/ serves a signed content bundle; private=True behaves like
    the 2.3.26 gateway (only requests with a valid session get the content, anonymous ones get 401)."""

    def __init__(self):
        self.calls, self.lock = [], threading.Lock()
        self.v1, self.private = None, False
        self.heartbeat = (200, {'ok': True, 'token': 'cloud-tok'})
        cloud = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                cloud.handle(self)

            do_POST = do_PUT = do_DELETE = do_GET

        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.base = 'http://127.0.0.1:%d' % self.server.server_port
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def handle(self, h):
        n = int(h.headers.get('Content-Length') or 0)
        raw = h.rfile.read(n) if n else b''
        path = urllib.parse.urlparse(h.path).path
        with self.lock:
            self.calls.append({'method': h.command, 'path': h.path, 'auth': h.headers.get('Authorization'),
                               'session': h.headers.get('X-Enana-Session'), 'body': raw})
        status, body, ctype = 404, b'{"message":"not found"}', 'application/json'
        if path.startswith('/v1/'):
            signed = h.headers.get('Authorization') == 'Bearer cloud-tok' and h.headers.get('X-Enana-Session') == 'sid-1'
            if self.private and not signed:
                status, body = 401, b'{"code":"session_revoked","reason":"invalid"}'
            elif self.v1 and (self.v1 / os.path.basename(path)).is_file():
                status, body, ctype = 200, (self.v1 / os.path.basename(path)).read_bytes(), 'application/octet-stream'
        elif path == '/api/enana/v1/session/heartbeat':
            status, body = self.heartbeat[0], json.dumps(self.heartbeat[1]).encode()
        elif path == '/api/enana/v1/session/logout':
            status, body = 200, b'{"ok":true}'
        elif path == '/api/enana/v1/sync/snapshot':
            status, body = 200, b'{"exists":false}'
        elif path.startswith(('/api/enana/v1/billing', '/api/enana/v1/email')):
            status, body = 200, json.dumps({'ok': True, 'wallet': {'balance': '1.000000'}, 'route': path}).encode()
        h.send_response(status)
        h.send_header('Content-Type', ctype); h.send_header('Content-Length', str(len(body))); h.end_headers()
        h.wfile.write(body)

    def v1_calls(self):
        with self.lock:
            return [c for c in self.calls if c['path'].startswith('/v1/')]


class NoAccount(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cloud = FakeCloud()
        cls.keys = pathlib.Path(tempfile.mkdtemp(prefix='enana-noaccount-keys-')).resolve()
        for name in ('ckey', 'evil'):
            subprocess.run(['/usr/bin/openssl', 'ecparam', '-genkey', '-name', 'prime256v1', '-noout', '-out', str(cls.keys / (name + '.pem'))], check=True, capture_output=True)
        subprocess.run(['/usr/bin/openssl', 'ec', '-in', str(cls.keys / 'ckey.pem'), '-pubout', '-out', str(cls.keys / 'cpub.pem')], check=True, capture_output=True)
        for name, seq, key in (('b100', 100, 'ckey'), ('b101', 101, 'ckey'), ('b99', 99, 'ckey'), ('evil', 105, 'evil'), ('bad', 102, 'ckey')):
            out = cls.keys / name; out.mkdir()
            subprocess.run(['/bin/bash', str(repo / 'tools/build-content-bundle.sh'), str(repo / 'tests/fixtures/content'), str(out), str(cls.keys / (key + '.pem')), str(seq)],
                           check=True, capture_output=True)
        pkg = cls.keys / 'bad' / 'content-102.tar.gz'
        pkg.write_bytes(pkg.read_bytes() + b'x')                  # changed after the manifest was signed

    @classmethod
    def tearDownClass(cls):
        cls.cloud.server.shutdown(); cls.cloud.server.server_close()
        shutil.rmtree(cls.keys, ignore_errors=True)

    def setUp(self):
        self.root = pathlib.Path(tempfile.mkdtemp(prefix='enana-noaccount-')).resolve()
        self.home = self.root / 'h'
        for d in (self.home, self.root / 'home', self.root / 'fake'):
            d.mkdir()
        (self.home / 'secret').write_text(TOKEN + '\n')
        fake = self.home / 'enana'                                 # background tasks only record how they were launched
        fake.write_text('#!/bin/bash\nprintf "%s|%s|%s|%s\\n" "${OP_WHO:-}" "${APPS_BG_JOB:-}" "$1" "$2" >> "$ENANA_HOME/launched"\n')
        fake.chmod(0o755)
        self.api_port = str(free_port())
        self.ports = {'PORT': str(free_port()), 'UI_PORT': str(free_port()), 'API_PORT': self.api_port, 'SPEED_PORT': str(free_port())}
        with self.cloud.lock:
            self.cloud.calls.clear()
        self.cloud.private, self.cloud.v1 = False, self.keys / 'b100'
        self.cloud.heartbeat = (200, {'ok': True, 'token': 'cloud-tok'})

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    # ---------- helpers ----------
    def env(self, **extra):
        e = {k: v for k, v in os.environ.items() if not k.startswith(('ENANA_', 'TPROXY_'))}
        e.update(self.ports)
        e.update(HOME=str(self.root / 'home'), ENANA_HOME=str(self.home), ENANA_ACCOUNT_URL=self.cloud.base,
                 ENANA_CLOUD_PUBKEY=str(self.keys / 'cpub.pem'), ENANA_LANG='zh', ENANA_NO_DIAG='1', ENANA_SKIP_PROBE='1',
                 LC_ALL='C', FAKE_STATE=str(self.root / 'fake'), PATH='%s:%s' % (FAKEBIN, os.environ.get('PATH', '/usr/bin:/bin')))
        e.update(extra)
        return e

    def cgi(self, method, path, body=b'', token=TOKEN, sudo=None, lang=None, host=None, xenana=True, headers=(), ctype=None):
        h = [('Host', host or '127.0.0.1:' + self.api_port)]
        if xenana:
            h.append(('X-Enana', '1'))
        if token:
            h.append(('X-Enana-Token', token))
        if sudo:
            h.append(('X-Enana-Sudo', sudo))
        if lang:
            h.append(('X-Enana-Lang', lang))
        h += list(headers)
        if body:
            h.append(('Content-Type', ctype or ('application/json' if body[:1] == b'{' else 'application/x-www-form-urlencoded')))
        raw = ('%s %s HTTP/1.1\r\n' % (method, path) + ''.join('%s: %s\r\n' % kv for kv in h) + 'Content-Length: %d\r\n\r\n' % len(body)).encode() + body
        r = subprocess.run(['/bin/bash', str(repo / 'lib/api.sh')], env=self.env(ENANA_API_PIPE='1'), input=raw, capture_output=True, timeout=120)
        head, _, payload = r.stdout.partition(b'\r\n\r\n')
        self.assertTrue(head.startswith(b'HTTP/1.1 '), (method, path, r.stdout[:300], r.stderr[-1500:]))
        return int(head.split()[1]), head.decode('utf-8', 'replace'), payload

    def cgij(self, method, path, **kw):
        status, _, payload = self.cgi(method, path, **kw)
        return status, json.loads(payload.decode('utf-8'))

    def sh(self, body, **extra):
        r = subprocess.run(['/bin/bash', '-c', PRE + body, 'enana-test', str(repo)], env=self.env(**extra), capture_output=True, text=True, timeout=180)
        self.assertNotIn('REFUSING', r.stdout)
        return r

    def sign_in(self, email='user1@example.test'):
        (self.home / 'loggedin').write_text('%s %d\n' % (email, int(time.time())))
        (self.home / 'session').write_text('sid-1\n')
        (self.home / 'cloud.token').write_text('cloud-tok\n')
        (self.home / 'account.conf').write_text('id=rec1abc23\nemail=%s\nsalt=00\niter=1\nhash=%s\nupdated=0\n' % (email, '0' * 64))

    def grant_sudo(self, ttl=300):
        (self.home / 'sudo.tokens').write_text('%s %d\n' % (hashlib.sha256(SUDO.encode()).hexdigest(), int(time.time()) + ttl))

    def official(self):
        (self.home / 'official.jsonl').write_text(OFFICIAL_ROW)
        (self.home / 'official.state').write_text('ok=%d\nentitled=1\n' % time.time())

    def settings(self, **kv):
        (self.home / 'settings.env').write_text(''.join('%s=%s\n' % x for x in kv.items()))

    def setting(self, key):
        f = self.home / 'settings.env'
        found = re.findall(r'(?m)^%s=(.*)$' % key, f.read_text()) if f.exists() else []
        return found[-1] if found else None

    def ops(self):
        return ''.join(p.read_text(encoding='utf-8') for p in sorted((self.home / 'logs').glob('ops-*.log')))

    def ops_results(self, action):
        return [l.split('\t')[4] for l in self.ops().splitlines() if l.split('\t')[2:3] == [action]]

    def jobs(self, name):
        d = self.home / 'jobs'
        return sorted(p.name for p in d.glob(name + '-*.json')) if d.is_dir() else []

    def launched(self):
        f = self.home / 'launched'
        return f.read_text().splitlines() if f.exists() else []

    def applies(self):
        f = self.home / 'applies'
        return f.read_text().splitlines() if f.exists() else []

    def seq(self):
        f = self.home / 'cloud' / 'content' / 'SEQ'
        return f.read_text().strip() if f.exists() else '0'

    def wait_for(self, pred, what, timeout=10):
        end = time.time() + timeout
        while time.time() < end:
            if pred():
                return
            time.sleep(0.1)
        self.fail('timed out waiting for ' + what)

    def install(self, **extra):
        r = self.sh('cloud_content_install; rc=$?; printf "rc=%s seq=%s changed=%s anon=%s\\nerr=%s\\n" "$rc" "$(cloud_seq)" "$CLOUD_CHANGED" "$CLOUD_ANON" "$CLOUD_ERR"', **extra)
        first, _, err = r.stdout.strip().partition('\nerr=')
        out = dict(x.split('=', 1) for x in first.split())
        out['err'] = err
        return out

    # ---------- the local token ----------
    def test_status_says_no_account_needed(self):
        s, d = self.cgij('GET', '/api/auth/status', token=None)
        self.assertEqual(s, 200)
        self.assertEqual(set(d), {'ok', 'required', 'logged_in', 'local', 'account_hint', 'offline_ok', 'notice', 'official_stale', 'account_url', 'wait'})
        self.assertEqual((d['ok'], d['required'], d['logged_in'], d['local'], d['account_hint'], d['offline_ok'], d['official_stale']), (True, False, False, True, '', False, False))
        (self.home / 'official.stale').write_text('')                    # kicked in TUN with official nodes still in the core (session_local_end)
        s, d = self.cgij('GET', '/api/auth/status', token=None)
        self.assertIs(d['official_stale'], True)
        (self.home / 'official.stale').unlink()
        self.sign_in()
        s, d = self.cgij('GET', '/api/auth/status', token=None)
        self.assertEqual((d['required'], d['logged_in'], d['local'], d['offline_ok']), (False, True, True, True))
        self.assertTrue(d['account_hint'].startswith('u***@e***'), d)
        self.assertNotIn('user1@example.test', json.dumps(d), 'the public status only shows a masked account')

    def test_local_token_signed_out_and_signed_in(self):
        s, d = self.cgij('POST', '/api/auth/local', token=None)
        self.assertEqual((s, d), (200, {'ok': True, 'token': TOKEN, 'logged_in': False}))
        s, d = self.cgij('GET', '/api/sync', token=d['token'])
        self.assertEqual((s, d['ok'], d['logged_in']), (200, True, False), 'the token opens the dashboard without an account')
        self.sign_in()
        s, d = self.cgij('POST', '/api/auth/local', token=None)
        self.assertEqual((s, d), (200, {'ok': True, 'token': TOKEN, 'logged_in': True}), 'same token when signed in')
        self.assertEqual((self.home / 'secret').read_text().strip(), TOKEN)
        # only the dashboard of this computer gets it
        s, d = self.cgij('POST', '/api/auth/local', token=None, xenana=False)
        self.assertEqual((s, d['code']), (403, 'E_FORBIDDEN'), 'no X-Enana header (a cross-site page cannot send one)')
        s, d = self.cgij('POST', '/api/auth/local', token=None, host='evil.example:80')
        self.assertEqual((s, d['code']), (403, 'E_FORBIDDEN'), 'DNS rebinding: wrong Host')
        s, d = self.cgij('POST', '/api/auth/local', token=None, headers=[('Origin', 'https://evil.example')])
        self.assertEqual((s, d['code']), (403, 'E_FORBIDDEN'), 'foreign Origin')
        s, d = self.cgij('POST', '/api/auth/local', token=None, headers=[('Origin', 'http://127.0.0.1:' + self.api_port), ('Sec-Fetch-Site', 'cross-site')])
        self.assertEqual((s, d['code']), (403, 'E_FORBIDDEN'), 'the browser says cross-site')
        s, d = self.cgij('POST', '/api/auth/local', token=None, headers=[('Origin', 'http://localhost:' + self.api_port), ('Sec-Fetch-Site', 'same-origin')])
        self.assertEqual((s, d['token']), (200, TOKEN), 'the dashboard itself (same origin)')
        s, d = self.cgij('GET', '/api/auth/local', token=None)
        self.assertEqual((s, d['code']), (401, 'E_AUTH'), 'only POST /api/auth/local is public')
        for tok in (None, 'f' * 32):
            s, d = self.cgij('GET', '/api/sync', token=tok)
            self.assertEqual((s, d['ok'], d['code']), (401, False, 'E_AUTH'), '401 = missing or wrong local token')

    def test_missing_local_token_is_created_once(self):
        (self.home / 'secret').unlink()
        s, d = self.cgij('POST', '/api/auth/local', token=None)
        self.assertEqual((s, d['ok'], d['logged_in']), (200, True, False))
        self.assertRegex(d['token'], r'^[0-9a-f]{32}$')
        f = self.home / 'secret'
        self.assertEqual((f.read_text().strip(), oct(f.stat().st_mode & 0o777)), (d['token'], '0o600'))
        self.wait_for(lambda: 'dashboard||_job|auth-sync' in self.launched(), 'the core to be given the new token')
        s, again = self.cgij('POST', '/api/auth/local', token=None)
        self.assertEqual(again['token'], d['token'])
        self.assertEqual(len(self.jobs('auth-sync')), 1, 'an existing token is never replaced')

    def test_fresh_install_fetches_cloud_content_once_in_the_background(self):
        self.cgij('POST', '/api/auth/local', token=None)
        self.wait_for(lambda: 'auto|1|_job|content-sync' in self.launched(), 'a background content download (never prompts)')
        self.assertEqual(len(self.jobs('content-sync')), 1)
        self.cgij('POST', '/api/auth/local', token=None)
        self.assertEqual(len(self.jobs('content-sync')), 1, 'not again within 6 hours (several tabs, a failed download)')
        marker = self.home / 'cloud' / '.first-try'
        marker.write_text('%d\n' % (time.time() - 7 * 3600))
        self.cgij('POST', '/api/auth/local', token=None)
        self.assertEqual(len(self.jobs('content-sync')), 2, 'retried after 6 hours while there is still no cloud content')
        (self.home / 'cloud' / 'content-5').mkdir()
        (self.home / 'cloud' / 'content-5' / 'SEQ').write_text('5\n')
        os.symlink('content-5', str(self.home / 'cloud' / 'content'))
        marker.write_text('%d\n' % (time.time() - 7 * 3600))
        self.cgij('POST', '/api/auth/local', token=None)
        self.assertEqual(len(self.jobs('content-sync')), 2, 'content already installed: the daily maintenance keeps it fresh')

    # ---------- account-only endpoints ----------
    def test_contract_tables_in_the_helper(self):
        src = (repo / 'lib/api.sh').read_text(encoding='utf-8')
        table = re.search(r'^ACCOUNT_ENDPOINTS=" (.*) "$', src, re.M).group(1).split()
        self.assertEqual(sorted(table), sorted('%s:%s' % (m, p) for m, p in ACCOUNT_ONLY if not p.startswith(('/api/billing', '/api/email'))))
        self.assertIn('case $path in /api/billing|/api/billing/*|/api/email/*) _acct=1 ;; esac', src)
        sudo = re.search(r'^SUDO_ENDPOINTS=" (.*) "$', src, re.M).group(1).split()
        self.assertEqual(sorted(sudo), sorted('%s:%s' % (m, p.split('?')[0]) for m, p, *_ in SUDO_LOCAL + SUDO_ACCOUNT + SUDO_SESSION))

    def test_account_only_endpoints_answer_login_required_when_signed_out(self):
        for method, path in ACCOUNT_ONLY:
            s, d = self.cgij(method, path, body=b'x=1' if method == 'POST' else b'')
            self.assertEqual((s, d), (200, {'ok': False, 'code': 'E_LOGIN_REQUIRED', 'error': LOGIN_ZH}), (method, path))
        for method, path in ACCOUNT_ONLY[:3] + ACCOUNT_ONLY[-3:]:
            s, d = self.cgij(method, path, body=b'x=1' if method == 'POST' else b'', lang='en')
            self.assertEqual((s, d['code'], d['error']), (200, 'E_LOGIN_REQUIRED', LOGIN_EN), (method, path))
        # being signed in is what counts, not a leftover cloud session
        (self.home / 'session').write_text('sid-1\n'); (self.home / 'cloud.token').write_text('cloud-tok\n')
        for method, path in (('GET', '/api/billing'), ('GET', '/api/devices'), ('POST', '/api/sync/push')):
            s, d = self.cgij(method, path, body=b'x=1' if method == 'POST' else b'')
            self.assertEqual((s, d['code']), (200, 'E_LOGIN_REQUIRED'), path)
        with self.cloud.lock:
            self.assertEqual(self.cloud.calls, [], 'nothing reaches the cloud')
        self.assertEqual(self.launched(), [], 'no background task is started')

    def test_page_reads_stay_usable_and_neutral_when_signed_out(self):
        (self.home / 'plan.json').write_text('{"plan":{"code":"pro","title":"Pro"},"features":{"official_proxy":{"enabled":true,"tier":"pro"}},"official":{"available":true,"nodes":3}}')
        (self.home / 'plan.checked').write_text('%d\n' % time.time())
        (self.home / 'sync.conf').write_text('ENABLED=1\nAUTO=1\nACCOUNT=rec1abc23\nBASE_VERSION=7\n')
        s, d = self.cgij('GET', '/api/plan')
        self.assertEqual((s, d['ok'], d['logged_in'], d['plan']['code'], d['checked'], d['official']['available']), (200, True, False, 'free', 0, False),
                         'a signed-out plan is the built-in free one, never an earlier account\'s cache')
        s, d = self.cgij('GET', '/api/sync')
        self.assertEqual((s, d), (200, {'ok': True, 'logged_in': False, 'enabled': False, 'auto': False, 'decided': False, 'has_key': False, 'account': '',
                                        'remote': None, 'local': {'version': 0, 'dirty': False}, 'conflict': False, 'last_pull': 0, 'last_push': 0,
                                        'online': False, 'ask': False}))
        with self.cloud.lock:
            self.assertEqual(self.cloud.calls, [])
        self.sign_in()
        s, d = self.cgij('GET', '/api/sync')
        self.assertEqual((s, d['logged_in'], d['enabled'], d['account'], d['remote']), (200, True, True, 'user1@example.test', {'exists': False}))
        s, d = self.cgij('GET', '/api/plan')
        self.assertEqual((d['logged_in'], d['plan']['code']), (True, 'pro'))
        s, d = self.cgij('GET', '/api/billing')
        self.assertEqual((s, d['ok'], d['wallet']['balance']), (200, True, '1.000000'))
        last = self.cloud.calls[-1]
        self.assertEqual((last['path'], last['auth'], last['session']), ('/api/enana/v1/billing', 'Bearer cloud-tok', 'sid-1'))

    # ---------- step-up ----------
    def test_step_up_is_skipped_when_signed_out(self):
        for method, path, body, code in SUDO_LOCAL:
            s, head, payload = self.cgi(method, path, body=body)
            if code is None:
                self.assertEqual(s, 200, path)
                self.assertRegex(head, r'(?i)content-disposition: attachment; filename="enana-backup-\d{8}\.json"')
                self.assertEqual(json.loads(payload)['app'], 'enana')
            else:
                d = json.loads(payload)
                self.assertEqual((s, d['ok'], d['code']), (200, False, code), path)
        for method, path, body in SUDO_ACCOUNT:
            s, d = self.cgij(method, path, body=body)
            self.assertEqual((s, d['code']), (200, 'E_LOGIN_REQUIRED'), path)
        for method, path, body, code in SUDO_SESSION:
            s, d = self.cgij(method, path, body=body, ctype='application/x-www-form-urlencoded')
            if code is None:
                self.assertEqual((s, d), (200, {'ok': True}), path)
            else:
                self.assertEqual((s, d['ok'], d['code']), (200, False, code), path)
        with self.cloud.lock:
            self.assertEqual(self.cloud.calls, [])

    def test_step_up_is_enforced_when_signed_in(self):
        self.sign_in()
        for method, path, body, *_ in SUDO_LOCAL + SUDO_ACCOUNT + SUDO_SESSION:
            s, d = self.cgij(method, path, body=body, ctype='application/x-www-form-urlencoded' if path.startswith(('/api/login', '/api/register')) else None)
            self.assertEqual((s, d['ok'], d['code']), (403, False, 'E_SUDO_REQUIRED'), path)
        self.assertTrue((self.home / 'loggedin').exists(), 'a refused logout / login / register leaves the account signed in')
        with self.cloud.lock:
            self.assertEqual(self.cloud.calls, [], 'refused before anything reaches the cloud')
        self.grant_sudo()
        s, d = self.cgij('GET', '/api/sub/url?name=nope', sudo=SUDO)
        self.assertEqual((s, d['code']), (200, 'E_NOT_FOUND'), 'a valid step-up passes the gate')
        s, d = self.cgij('POST', '/api/billing/purchase', body=PURCHASE, sudo=SUDO)
        self.assertEqual((s, d['ok']), (200, True))
        last = self.cloud.calls[-1]
        self.assertEqual((last['method'], last['path'], last['auth'], json.loads(last['body'])),
                         ('POST', '/api/enana/v1/billing/purchase', 'Bearer cloud-tok', {'request_key': 'k' * 32, 'sku': 'm1'}))
        s, d = self.cgij('POST', '/api/billing/auto-renew', body=RENEW, sudo=SUDO)
        self.assertEqual((s, d['ok'], self.cloud.calls[-1]['path'], json.loads(self.cloud.calls[-1]['body'])),
                         (200, True, '/api/enana/v1/billing/auto-renew', {'enabled': True}))
        self.grant_sudo(ttl=-10)
        n = len(self.cloud.calls)
        s, d = self.cgij('POST', '/api/billing/purchase', body=PURCHASE, sudo=SUDO)
        self.assertEqual((s, d['code'], len(self.cloud.calls)), (403, 'E_SUDO_REQUIRED', n), 'an expired step-up no longer passes')

    # ---------- signing out / being kicked / signing in to another account ----------
    def test_sign_out_keeps_the_token_and_the_proxy(self):
        for switch in ('', '?switch=1'):
            self.sign_in(); self.settings(PROXY_ENABLED=1, PROXY_MODE='global'); self.official(); self.grant_sudo()
            (self.home / 'plan.json').write_text('{"plan":{"code":"pro"}}'); (self.home / 'sync.key').write_text('k\nm\n')
            before = len(self.launched())
            s, d = self.cgij('POST', '/api/logout' + switch)
            self.assertEqual((s, d['code']), (403, 'E_SUDO_REQUIRED'), 'signing out needs the step-up while signed in ' + switch)
            self.assertTrue((self.home / 'loggedin').exists())
            s, d = self.cgij('POST', '/api/logout' + switch, sudo=SUDO)
            self.assertEqual((s, d), (200, {'ok': True}), switch)
            self.assertEqual((self.home / 'secret').read_text().strip(), TOKEN, 'the local token does not change')
            self.assertEqual((self.setting('PROXY_ENABLED'), self.setting('PROXY_MODE')), ('1', 'global'), 'the proxy keeps running on your own servers ' + switch)
            for f in ('loggedin', 'account.conf', 'session', 'cloud.token', 'official.jsonl', 'official.state', 'sudo.tokens', 'plan.json', 'sync.key'):
                self.assertFalse((self.home / f).exists(), (switch, f))
            self.wait_for(lambda: len(self.launched()) == before + 1, 'the official nodes to be removed from the core')
            self.assertEqual(self.launched()[-1], 'dashboard||_job|auth-sync')
            self.wait_for(lambda: any(c['path'] == '/api/enana/v1/session/logout' and c['auth'] == 'Bearer cloud-tok' for c in self.cloud.calls),
                          'the device slot to be released')
            self.assertIn('\tdashboard\t退出账号\tuser=u***@e***.test' + (' switch=1' if switch else ''), self.ops())
            s, d = self.cgij('GET', '/api/sync')
            self.assertEqual((s, d['logged_in']), (200, False), 'the same token still opens the dashboard')
            with self.cloud.lock:
                self.cloud.calls.clear()
        self.assertNotIn('总开关变更', self.ops())
        # signed out: a no-op
        n, l = len(self.ops_results('退出账号')), len(self.launched())
        s, d = self.cgij('POST', '/api/logout')
        self.assertEqual((s, d), (200, {'ok': True}))
        time.sleep(1)
        self.assertEqual((len(self.ops_results('退出账号')), len(self.launched())), (n, l))
        with self.cloud.lock:
            self.assertEqual(self.cloud.calls, [])

    def test_sign_out_without_official_nodes_changes_nothing_in_the_core(self):
        self.sign_in(); self.settings(PROXY_ENABLED=1); self.grant_sudo()
        s, d = self.cgij('POST', '/api/logout', sudo=SUDO)
        self.assertEqual((s, d), (200, {'ok': True}))
        time.sleep(1)
        self.assertEqual((self.launched(), self.jobs('auth-sync')), ([], []))
        self.assertEqual(self.setting('PROXY_ENABLED'), '1')

    def kicked(self, **extra):
        r = self.sh(STUB_APPLY + 'session_heartbeat; echo "rc=$?"', **extra)
        self.assertIn('rc=1', r.stdout, r.stderr[-1500:])
        self.assertEqual((self.setting('PROXY_ENABLED'), self.setting('PROXY_MODE')), ('1', 'global'), 'the proxy setting stays')
        self.assertEqual((self.home / 'secret').read_text().strip(), TOKEN, 'the local token stays')
        for f in ('loggedin', 'session', 'cloud.token', 'account.conf', 'official.jsonl', 'official.state'):
            self.assertFalse((self.home / f).exists(), f)
        self.assertNotIn('总开关变更', self.ops())
        return (self.home / 'notice').read_text().strip()

    def test_being_kicked_keeps_the_proxy_and_the_token(self):
        self.sign_in(); self.settings(PROXY_ENABLED=1, PROXY_MODE='global'); self.official()
        self.cloud.heartbeat = (401, {'code': 'session_revoked', 'reason': 'kicked'})
        self.assertEqual(self.kicked(), 'kicked')
        self.assertEqual(self.applies(), ['1'], 'one background apply (APPS_BG_JOB=1, never prompts) removes the official nodes')
        self.assertIn('\tauto\t已被退出登录\treason=kicked http=401 proxy_was=1 ', self.ops())
        hb = [c for c in self.cloud.calls if c['path'] == '/api/enana/v1/session/heartbeat']
        self.assertEqual([(c['auth'], c['session']) for c in hb], [('Bearer cloud-tok', 'sid-1')])
        # without official nodes the configuration does not change: nothing is regenerated
        (self.home / 'applies').unlink()
        self.sign_in()
        self.assertEqual(self.kicked(), 'kicked')
        self.assertEqual(self.applies(), [])

    def test_offline_expiry_keeps_the_proxy_and_the_token(self):
        self.sign_in(); self.settings(PROXY_ENABLED=1, PROXY_MODE='global'); self.official()
        (self.home / 'hb.fail').write_text('%d\n' % (time.time() - 8 * 86400))
        self.assertEqual(self.kicked(ENANA_ACCOUNT_URL='http://127.0.0.1:%d' % free_port()), 'offline_expired')
        self.assertEqual(self.applies(), ['1'])

    def test_signing_in_to_another_account_keeps_the_proxy(self):
        self.settings(PROXY_ENABLED=1)
        (self.home / 'last-account').write_text('rec-previous\n')          # written by 2.3.26 and earlier
        r = self.sh('''auth_remote_login() { ACC_ID=rec-other; ACC_EMAIL=$1; SESS_ID=sid-9; CLOUD_TOKEN=tok-9; return 0; }
auth_pbkdf2() { cat >/dev/null; printf '%064d' 7; }
sync_on_login() { :; }; diag_kick() { :; }
proxy_set_enabled() { echo "proxy_set_enabled $1" >> "$ENANA_HOME/calls"; }
auth_login other@example.test 'Passw0rd!x'; echo "rc=$? via=$AUTH_VIA"''')
        self.assertIn('rc=0 via=online', r.stdout, r.stderr[-1500:])
        self.assertEqual(self.setting('PROXY_ENABLED'), '1')
        self.assertFalse((self.home / 'calls').exists(), 'the proxy switch is not touched')
        self.assertTrue((self.home / 'loggedin').read_text().startswith('other@example.test '))
        self.assertEqual((self.home / 'secret').read_text().strip(), TOKEN)

    # ---------- cloud content without an account ----------
    def test_anonymous_download_has_no_credentials_and_the_same_verification(self):
        out = self.install()
        self.assertEqual((out['rc'], out['seq'], out['changed'], out['anon']), ('0', '100', '1', '1'), out)
        self.assertEqual([c['path'] for c in self.cloud.v1_calls()], ['/v1/manifest.json', '/v1/manifest.sig', '/v1/content-100.tar.gz'])
        self.assertEqual(os.readlink(str(self.home / 'cloud' / 'content')), 'content-100')
        self.cloud.v1 = self.keys / 'evil'
        out = self.install()
        self.assertEqual((out['rc'], out['seq']), ('1', '100'), out); self.assertIn('签名校验失败', out['err'])
        self.cloud.v1 = self.keys / 'b99'
        out = self.install()
        self.assertEqual((out['rc'], out['seq']), ('1', '100'), out); self.assertIn('防回滚', out['err'])
        self.cloud.v1 = self.keys / 'bad'
        out = self.install()
        self.assertEqual((out['rc'], out['seq']), ('1', '100'), out); self.assertIn(out['err'], ('内容包大小不对', '内容包校验和不对'))
        calls = self.cloud.v1_calls()
        self.assertGreater(len(calls), 3)
        self.assertEqual({(c['auth'], c['session']) for c in calls}, {(None, None)}, 'no Authorization / X-Enana-Session without an account')

    def test_signed_in_download_still_uses_the_session(self):
        self.sign_in()
        out = self.install()
        self.assertEqual((out['rc'], out['seq'], out['anon']), ('0', '100', '0'), out)
        calls = self.cloud.v1_calls()
        self.assertEqual(len(calls), 3)
        self.assertEqual({(c['auth'], c['session']) for c in calls}, {('Bearer cloud-tok', 'sid-1')})

    def test_cloud_that_requires_sign_in_keeps_the_content_calmly(self):
        self.assertEqual(self.install()['seq'], '100')
        self.cloud.private, self.cloud.v1 = True, self.keys / 'b101'
        with self.cloud.lock:
            self.cloud.calls.clear()
        out = self.install()
        self.assertEqual((out['rc'], out['seq'], out['err']), ('2', '100', ANON_MSG), out)
        self.assertEqual([c['path'] for c in self.cloud.v1_calls()], ['/v1/manifest.json'], 'stops at the first refusal')
        r = self.sh(STUB_CONTENT + 'txn_content; echo "rc=$? err=$TXN_ERR"')
        self.assertIn('rc=1 err=' + ANON_MSG, r.stdout)
        state = (self.home / 'cloud' / 'state').read_text()
        self.assertIn('error=' + ANON_MSG + '\n', state)
        self.assertRegex(state, r'(?m)^anon_refused=\d+$')
        r = self.sh('I18N_LANG=en; cloud_status_json')
        self.assertIn('"source":"cloud","seq":100', r.stdout)
        self.assertIn('Cloud content currently needs a signed-in enana account to download', r.stdout, 'the dashboard shows a translated explanation')
        self.sign_in()
        out = self.install()
        self.assertEqual((out['rc'], out['seq']), ('0', '101'), 'signed in, the session still opens the content')

    def test_daily_maintenance_updates_content_for_everyone_without_daily_errors(self):
        self.settings(AUTO_UPDATE=0)
        # signed out, public content, fresh install
        r = self.sh(MAINTAIN)
        self.assertIn('maintained rc=0', r.stdout, r.stderr[-1500:])
        self.assertEqual((self.seq(), self.ops_results('更新云端内容')), ('100', ['ok']))
        self.assertFalse((self.home / 'plan-calls').exists(), 'the plan belongs to an account')
        # the cloud refuses anonymous downloads (like 2.3.26): one error, then quiet days that only ask
        self.cloud.private, self.cloud.v1 = True, self.keys / 'b101'
        with self.cloud.lock:
            self.cloud.calls.clear()
        for _ in range(3):
            self.assertIn('maintained rc=0', self.sh(MAINTAIN).stdout)
        self.assertEqual(self.ops_results('更新云端内容'), ['ok', 'error'], 'not an error line every day')
        self.assertEqual([(c['path'], c['auth'], c['session']) for c in self.cloud.v1_calls()], [('/v1/manifest.json', None, None)] * 3)
        self.assertEqual(self.seq(), '100')
        # the content becomes public: the next maintenance installs it and forgets the refusal
        self.cloud.private = False
        self.sh(MAINTAIN)
        self.assertEqual((self.seq(), self.ops_results('更新云端内容')), ('101', ['ok', 'error', 'ok']))
        self.assertNotIn('anon_refused', (self.home / 'cloud' / 'state').read_text())
        # signed in: content with the session and the plan refreshed
        self.sign_in()
        with self.cloud.lock:
            self.cloud.calls.clear()
        self.sh(MAINTAIN)
        self.assertEqual((self.home / 'plan-calls').read_text().split(), ['plan'])
        self.assertEqual({(c['auth'], c['session']) for c in self.cloud.v1_calls()}, {('Bearer cloud-tok', 'sid-1')})
        self.assertEqual(self.applies().count('1'), len(self.applies()), 'every apply in the maintenance is a background one')

    # ---------- the terminal ----------
    def test_enana_on_without_signing_in(self):
        r = self.sh('''eval "$(sed -n '/^cmd_on() {/,/^}/p' "$REPO/install.sh")"
cmd_start() { echo start >> "$ENANA_HOME/calls"; return 0; }
proxy_set_enabled() { echo "proxy=$1" >> "$ENANA_HOME/calls"; return 0; }
os_sysproxy_set() { echo "sysproxy=$1" >> "$ENANA_HOME/calls"; return 0; }
NETWORK_MODE=system; cmd_on; echo "rc=$?"; echo -- >> "$ENANA_HOME/calls"; NETWORK_MODE=tun; cmd_on; echo "rc=$?"''')
        self.assertEqual(r.stdout.split(), ['rc=0', 'rc=0'], r.stdout + r.stderr[-1500:])
        self.assertEqual((self.home / 'calls').read_text().split(), ['start', 'proxy=1', 'sysproxy=on', '--', 'start', 'proxy=1'])
        self.assertEqual(self.ops().count('\tterminal\t开启代理\tenabled=1 via="enana on"\tok'), 2)

    def test_enana_content_without_signing_in(self):
        r = self.sh(STUB_CONTENT + '''eval "$(sed -n '/^cmd_content() {/,/^}/p' "$REPO/install.sh")"
FORCE=''; cmd_content; echo "rc=$?"''')
        self.assertIn('rc=0', r.stdout, r.stderr[-1500:])
        self.assertIn('内容来源: cloud · 序号 100', r.stdout)
        self.assertNotIn('还没有登录', r.stdout + r.stderr)
        self.assertEqual(self.seq(), '100')
        self.assertEqual({(c['auth'], c['session']) for c in self.cloud.v1_calls()}, {(None, None)})


if __name__ == '__main__':
    unittest.main()
