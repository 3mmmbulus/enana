"""server/update-nginx-content.py: the 2.3.27 nginx edit that makes the signed cloud content under api.enana.cc/v1/ public.

TextEdit (pure text, runs anywhere): on tests/fixtures/nginx-enana.cc.conf (shaped like the live zz-enana.cc.conf, with
the live `location /v1/ {` block byte for byte) the edit removes exactly the auth_request and the 401 error_page lines of
that block, puts one comment (public, signed, rate limited) in their place and keeps every other byte, CRLF and bytes that
are not UTF-8 included. It refuses, writing nothing, when the block is missing or duplicated (a commented-out copy does not
count), holds other or nested auth lines, inherits an auth_request (server or file level; a sibling location's own one is
fine) or the file does not balance (exit 2), and when the block is public already (exit 3).
RealNginx: the same fixture before and after the edit on a private nginx (as the current user, 127.0.0.1, a free port, a
temp prefix): both pass `nginx -t`; before, an anonymous GET /v1/manifest.json is 401 from @enana_unauthorized; after, every
file is 200 with its bytes and Cache-Control: no-cache (also with the session headers older clients send), HEAD works,
POST / PUT are 403 from @enana_forbidden, /v1/ lists nothing (403), the /v1/../ variants deploy-content-public.sh probes are
400 or 404 (the codes it accepts), /_enana_auth stays internal (404) and the rate limit still applies (503 after the burst).
Skipped without nginx unless ENANA_REQUIRE_NGINX=1 (CI sets it).
"""
import difflib
import http.client
import importlib.util
import os
import pathlib
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest

repo = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = repo / 'server/update-nginx-content.py'
DEPLOY = repo / 'server/deploy-content-public.sh'
FIXTURE = repo / 'tests/fixtures/nginx-enana.cc.conf'
spec = importlib.util.spec_from_file_location('update_nginx_content', SCRIPT)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

AUTH_LINE = '        auth_request /_enana_auth;\n'
UNAUTH_LINE = '        error_page 401 = @enana_unauthorized;   # 失败时回 JSON, 方便 curl 脚本判断\n'
COMMENT_LINE = '        ' + mod.COMMENT + '\n'
LIVE_BLOCK = '''    location /v1/ {
        limit_except GET { deny all; }     # 只读 (GET 含 HEAD)
        limit_req zone=enana_apihost burst=10 nodelay;
        auth_request /_enana_auth;
        error_page 401 = @enana_unauthorized;   # 失败时回 JSON, 方便 curl 脚本判断
        error_page 403 = @enana_forbidden;
        root /var/www/enana-cloud;
        expires -1;                        # no-cache; Cloudflare 上还应加一条「绕过缓存」规则 (见 README)
    }
'''
TRAVERSAL = ('/v1/../../etc/passwd', '/v1/%2e%2e/%2e%2e/etc/passwd', '/v1/..%2f..%2fetc/passwd')


def run(text=None, raw=None):
    """Run the script on a temp file: (exit code, stderr, output bytes or None when it wrote nothing)."""
    with tempfile.TemporaryDirectory() as d:
        src, dst = pathlib.Path(d, 'in.conf'), pathlib.Path(d, 'out.conf')
        src.write_bytes(raw if raw is not None else text.encode('utf-8'))
        r = subprocess.run([sys.executable, '-I', str(SCRIPT), str(src), str(dst)], capture_output=True, text=True, timeout=60)
        return r.returncode, r.stderr, (dst.read_bytes() if dst.exists() else None)


def v1_block(text):
    start = text.index('    location /v1/ {\n')
    return text[start:text.index('\n    }\n', start) + 7]


class TextEdit(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = FIXTURE.read_text(encoding='utf-8')

    def expected(self, text=None):
        """The fixture (or a variant) with exactly the two session lines replaced by the comment."""
        lines = (self.text if text is None else text).splitlines(keepends=True)
        self.assertEqual((lines.count(AUTH_LINE), lines.count(UNAUTH_LINE)), (1, 1))
        return ''.join(COMMENT_LINE if l == AUTH_LINE else l for l in lines if l != UNAUTH_LINE)

    def refused(self, text, why, code=2):
        self.assertNotEqual(text, self.text, 'the variant must differ from the fixture')
        rc, err, out = run(text)
        self.assertEqual((rc, out), (code, None), err)
        self.assertIn(why, err)
        self.assertIn('nothing written', err)

    def insert_after(self, anchor, extra, text=None):
        text = self.text if text is None else text
        self.assertEqual(text.count(anchor), 1, anchor)
        return text.replace(anchor, anchor + extra)

    def test_the_fixture_carries_the_live_block_and_the_auth_locations(self):
        self.assertEqual(self.text.count(LIVE_BLOCK), 1)
        for keep in ('location = /_enana_auth {', 'location @enana_unauthorized {', 'location @enana_forbidden {', 'session/check'):
            self.assertIn(keep, self.text)

    def test_removes_exactly_the_two_session_lines(self):
        rc, err, out = run(self.text)
        self.assertEqual((rc, err), (0, ''))
        new = out.decode('utf-8')
        self.assertEqual(new, self.expected())
        diff = [l for l in difflib.unified_diff(self.text.splitlines(), new.splitlines(), lineterm='', n=0)
                if l[:1] in ('+', '-') and l[:3] not in ('+++', '---')]
        self.assertEqual(diff, ['-' + AUTH_LINE.rstrip('\n'), '-' + UNAUTH_LINE.rstrip('\n'), '+' + COMMENT_LINE.rstrip('\n')])
        block = v1_block(new)
        for keep in ('limit_except GET { deny all; }', 'limit_req zone=enana_apihost burst=10 nodelay;', 'error_page 403 = @enana_forbidden;',
                     'root /var/www/enana-cloud;', 'expires -1;'):
            self.assertIn(keep, block)
        self.assertNotIn('auth_request', block)
        self.assertNotIn('error_page 401', block)
        for keep in ('location = /_enana_auth {', 'location @enana_unauthorized {', 'session/check'):
            self.assertIn(keep, new, 'kept for other tooling')

    def test_the_comment_says_public_signed_and_rate_limited(self):
        for word in ('公开', '2.3.27', '签名', 'sha256', '限流'):
            self.assertIn(word, mod.COMMENT)
        self.assertTrue(mod.COMMENT.startswith('# '))
        self.assertNotIn('\n', mod.COMMENT)

    def test_public_already_exits_3_and_writes_nothing(self):
        self.refused(self.expected(), 'public already', code=3)

    def test_a_missing_or_duplicated_block_is_refused(self):
        self.refused(self.text.replace('    location /v1/ {', '    location /v2/ {'), 'no "location /v1/ {" block')
        self.refused(self.insert_after('    server_name enana.cc;\n', LIVE_BLOCK), 'expected exactly one')

    def test_a_commented_out_block_does_not_count(self):
        commented = ''.join('#' + l for l in LIVE_BLOCK.splitlines(keepends=True))
        text = self.insert_after('    server_name enana.cc;\n', commented)
        rc, err, out = run(text)
        self.assertEqual(rc, 0, err)
        self.assertEqual(out.decode('utf-8'), self.expected(text))

    def test_other_session_lines_are_refused(self):
        cases = {
            'another auth location': self.text.replace(AUTH_LINE, '        auth_request /_other_auth;\n'),
            'no 401 page': self.text.replace(UNAUTH_LINE, ''),
            'two auth_request lines': self.text.replace(AUTH_LINE, AUTH_LINE * 2),
            'two 401 pages': self.text.replace(UNAUTH_LINE, UNAUTH_LINE * 2),
            'both on one line': self.text.replace(AUTH_LINE + UNAUTH_LINE, '        auth_request /_enana_auth; error_page 401 = @enana_unauthorized;\n'),
            'auth_request_set as well': self.text.replace(AUTH_LINE, AUTH_LINE + '        auth_request_set $who $upstream_http_x_user;\n'),
            'a nested location with its own auth': self.text.replace(UNAUTH_LINE, UNAUTH_LINE + '        location /v1/private/ { auth_request /_enana_auth; }\n'),
        }
        for name, text in cases.items():
            with self.subTest(name):
                self.refused(text, 'location /v1/ block')

    def test_an_inherited_auth_request_is_refused(self):
        self.refused(self.insert_after('    server_name api.enana.cc;\n', '    auth_request /_enana_auth;\n'), 'inherit')
        self.refused('auth_request /_enana_auth;\n' + self.text, 'inherit')

    def test_a_sibling_location_with_its_own_auth_is_fine(self):
        text = self.insert_after('    server_name api.enana.cc;\n', '    location /stats/ { auth_request /_enana_auth; return 204; }\n')
        rc, err, out = run(text)
        self.assertEqual(rc, 0, err)
        self.assertEqual(out.decode('utf-8'), self.expected(text))

    def test_braces_and_hashes_in_quotes_comments_and_variables_are_not_structure(self):
        tricky = ('    # 注释里的 } 不是结构 {\n'
                  '    add_header X-Enana-Test "a } b { # c" always;\n'
                  "    add_header X-Enana-Test2 'd } e \\' {' always;\n"
                  '    set $x a#b}c;\n'
                  '    set $y ${host}x;\n')
        text = self.insert_after('    server_name api.enana.cc;\n', tricky)
        rc, err, out = run(text)
        self.assertEqual(rc, 0, err)
        self.assertEqual(out.decode('utf-8'), self.expected(text))

    def test_an_unbalanced_file_is_refused(self):
        cut = self.text.rstrip('\n')
        self.refused(cut[:cut.rindex('}')] + '\n', 'unbalanced')
        self.refused(self.text + '}\n', 'closes nothing')
        self.refused(self.text + 'add_header X-Enana-Open "never closed;\n', 'unterminated quote')   # at the end: no later quote closes it

    def test_crlf_and_bytes_that_are_not_utf8_are_kept(self):
        mark, odd = b'# Test fixture', b'# \xff\xfe Test fixture'
        raw = self.text.replace('\n', '\r\n').encode('utf-8')
        self.assertEqual(raw.count(mark), 1)
        rc, err, out = run(raw=raw.replace(mark, odd))
        self.assertEqual(rc, 0, err)
        self.assertEqual(out, self.expected().replace('\n', '\r\n').encode('utf-8').replace(mark, odd))

    def test_the_comment_takes_the_indentation_of_the_removed_line(self):
        rc, err, out = run(self.text.replace(AUTH_LINE, '\t\tauth_request\t/_enana_auth;\n'))
        self.assertEqual(rc, 0, err)
        self.assertIn('\n\t\t' + mod.COMMENT + '\n', out.decode('utf-8'))

    def test_usage_and_unreadable_input(self):
        r = subprocess.run([sys.executable, '-I', str(SCRIPT)], capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 2)
        self.assertIn('Usage:', r.stderr)
        with tempfile.TemporaryDirectory() as d:
            out = pathlib.Path(d, 'out.conf')
            r = subprocess.run([sys.executable, '-I', str(SCRIPT), str(pathlib.Path(d, 'missing.conf')), str(out)], capture_output=True, text=True, timeout=60)
            self.assertEqual((r.returncode, out.exists()), (2, False), r.stderr)

    def test_the_deploy_script_probes_what_this_file_checks_on_nginx(self):
        text = DEPLOY.read_text(encoding='utf-8')
        for path in TRAVERSAL:
            self.assertIn("'%s'" % path, text)
        for accepted in ('400|404) ;;', '403|404) ;;', '403|405) ;;'):
            self.assertIn(accepted, text)


NGINX = shutil.which('nginx') or next((p for p in ('/usr/sbin/nginx', '/usr/local/sbin/nginx') if os.access(p, os.X_OK)), None)
REQUIRE = os.environ.get('ENANA_REQUIRE_NGINX') == '1'
MAIN = '''worker_processes 1;
pid %(d)s/nginx.pid;
error_log %(d)s/logs/error.log;
events { worker_connections 64; }
http {
    access_log off;
    %(temp)s
    include %(site)s;
}
'''


def free_port():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    port = s.getsockname()[1]
    s.close()
    return port


@unittest.skipUnless(NGINX or REQUIRE, 'nginx is not installed (CI sets ENANA_REQUIRE_NGINX=1)')
class RealNginx(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not NGINX:
            raise AssertionError('ENANA_REQUIRE_NGINX=1, but there is no nginx binary')
        v = subprocess.run([NGINX, '-V'], capture_output=True, text=True, timeout=30)
        configure = v.stdout + v.stderr
        if '--with-http_auth_request_module' not in configure:
            raise AssertionError('this nginx was built without the auth_request module: ' + configure)
        h = subprocess.run([NGINX, '-h'], capture_output=True, text=True, timeout=30)
        cls.tmp = tempfile.TemporaryDirectory()
        d = cls.d = pathlib.Path(cls.tmp.name)
        cls.prefix = ['-p', str(d) + '/'] + (['-e', str(d / 'logs/startup.log')] if '-e filename' in h.stdout + h.stderr else [])
        for sub in ('cloud/v1', 'site', 'dl', 'tmp', 'logs'):
            (d / sub).mkdir(parents=True)
        cls.files = {'manifest.json': b'{"channel":"stable","bundles":{"content":{"seq":7,"url":"/v1/content-7.tar.gz"}}}',
                     'manifest.sig': os.urandom(70), 'content-7.tar.gz': os.urandom(5000), 'ping.json': b'{"ok":true}\n'}
        for name, data in cls.files.items():
            (d / 'cloud/v1' / name).write_bytes(data)
        (d / 'site/index.html').write_text('site\n')
        (d / 'dl/VERSION').write_text('2.3.26\n')
        cls.port = free_port()
        site = (FIXTURE.read_text(encoding='utf-8').replace('@PORT@', str(cls.port)).replace('/var/www/enana-cloud', str(d / 'cloud'))
                .replace('/var/www/enana-dl', str(d / 'dl')).replace('/opt/enana-cc/site', str(d / 'site')))
        (d / 'before.conf').write_text(site, encoding='utf-8')
        r = subprocess.run([sys.executable, '-I', str(SCRIPT), str(d / 'before.conf'), str(d / 'after.conf')], capture_output=True, text=True, timeout=60)
        if r.returncode != 0:
            raise AssertionError(r.stderr)
        # A non-root nginx cannot create the packaged temp paths (/var/lib/nginx/...): every compiled-in one goes to the prefix.
        temp = ['client_body_temp_path %s/tmp/body;' % d]
        for module in ('proxy', 'fastcgi', 'uwsgi', 'scgi'):
            if '--without-http_%s_module' % module not in configure:
                temp.append('%s_temp_path %s/tmp/%s;' % (module, d, module))
        for which in ('before', 'after'):
            (d / ('nginx-%s.conf' % which)).write_text(MAIN % {'d': d, 'temp': '\n    '.join(temp), 'site': d / ('%s.conf' % which)})

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def nginx(self, which, *args):
        return [NGINX] + self.prefix + ['-c', str(self.d / ('nginx-%s.conf' % which))] + list(args)

    def serve(self, which):
        """A private nginx with the configuration before / after the edit, stopped at the end of the test."""
        p = subprocess.Popen(self.nginx(which, '-g', 'daemon off;'), stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.addCleanup(self.stop, p)
        for _ in range(200):
            if p.poll() is not None:
                log = self.d / 'logs/error.log'
                self.fail('nginx exited: %s %s' % (p.stdout.read().decode(errors='replace'), log.read_text(errors='replace') if log.exists() else ''))
            try:
                socket.create_connection(('127.0.0.1', self.port), timeout=0.2).close()
                return
            except OSError:
                time.sleep(0.05)
        self.fail('nginx did not listen on 127.0.0.1:%d' % self.port)

    @staticmethod
    def stop(p):
        p.terminate()
        try:
            p.wait(15)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
        p.stdout.close()

    def request(self, path, method='GET', body=None, headers=None):
        c = http.client.HTTPConnection('127.0.0.1', self.port, timeout=10)
        try:
            c.request(method, path, body=body, headers=dict({'Host': 'api.enana.cc'}, **(headers or {})))
            r = c.getresponse()
            return r.status, r.read(), {k.lower(): v for k, v in r.getheaders()}
        finally:
            c.close()

    def test_both_configurations_pass_nginx_t(self):
        for which in ('before', 'after'):
            r = subprocess.run(self.nginx(which, '-t'), capture_output=True, text=True, timeout=60)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn('test is successful', r.stderr)

    def test_before_the_edit_the_content_needs_a_session(self):
        self.serve('before')
        self.assertEqual(self.request('/v1/manifest.json')[:2], (401, b'{"code":"unauthorized"}'))

    def test_after_the_edit_the_content_is_public_and_read_only(self):
        self.serve('after')
        for name, data in self.files.items():
            code, body, h = self.request('/v1/' + name)
            self.assertEqual((name, code, body, h.get('cache-control')), (name, 200, data, 'no-cache'))
        old = {'Authorization': 'Bearer from-an-older-client', 'X-Enana-Session': 'abc123'}
        self.assertEqual(self.request('/v1/manifest.json', headers=old)[:2], (200, self.files['manifest.json']), 'older clients still send their session')
        code, body, h = self.request('/v1/manifest.json', method='HEAD')
        self.assertEqual((code, body, h.get('content-length')), (200, b'', str(len(self.files['manifest.json']))))
        for method in ('POST', 'PUT'):
            self.assertEqual((method,) + self.request('/v1/manifest.json', method=method, body=b'')[:2], (method, 403, b'{"code":"forbidden"}'))
        self.assertEqual(self.request('/v1/')[0], 403, 'the content directory is not listed')
        for path in TRAVERSAL:
            self.assertIn(self.request(path)[0], (400, 404), path)
        self.assertEqual(self.request('/_enana_auth')[0], 404, 'the auth location stays internal')

    def test_the_rate_limit_still_applies_to_anonymous_downloads(self):
        self.serve('after')
        codes = [self.request('/v1/ping.json')[0] for _ in range(40)]
        self.assertEqual(codes[0], 200)
        self.assertIn(503, codes, 'limit_req (burst 10) refuses the requests after the burst')
        self.assertEqual(set(codes), {200, 503})


if __name__ == '__main__':
    unittest.main(verbosity=2)
