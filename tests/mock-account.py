#!/usr/bin/env python3
"""测试用: 模拟 enana.cc 云端 (只实现本地辅助服务用到的接口, 契约见 docs/CLOUD_API.md)。
用法: python3 mock-account.py <端口> [/v1 静态目录]    (/v1/* 只有带有效 Bearer + X-Enana-Session 的请求才能下载, 模拟网关的 auth_request)
  POST /api/enana/v1/auth/login            {email,password,device{uid,name,platform,os,arch,app},kick_device_uid} -> 200 / 409 device_limit / 400 / 429
  POST /api/collections/users/records      注册 {email,password,passwordConfirm} -> 200 / 400 (data.email.code / data.password.code)
  POST /api/enana/v1/session/heartbeat     (Bearer + X-Enana-Session) -> 200 {token} / 401 session_revoked
  POST /api/enana/v1/session/logout        GET /api/enana/v1/devices      POST /api/enana/v1/devices/kick {device_uid}
  POST /api/enana/v1/account/password      {old_password,new_password} -> 200 {token,session} / 400 bad_credentials|weak_password (其它会话全部撤销: password_changed)
  GET  /api/enana/v1/plan                  套餐与权益 (默认 free; POST /_test/plan?code=pro 切换)
  GET  /api/enana/v1/nodes                 官方线路节点 (会员): {entitled, nodes:[{outbound}]}; POST /_test/nodes?mode=none|ok|ok2|changed|empty|junk|500 切换 (全部是占位数据: *.example.invalid)
  GET|PUT|DELETE /api/enana/v1/sync/snapshot   端到端加密的快照 (只存密文; PUT 带 base_version 做乐观锁, 不对返回 409 conflict)
  GET  /api/health
  测试控制:  POST /_test/mode?m=ok|down|ratelimit|badjson    POST /_test/passwd?email=..&pw=..    GET /_test/hits
             POST /_test/revoke?uid=..&reason=kicked         (模拟云端/其它设备把某设备的会话撤销)   POST /_test/limit?n=2
             POST /_test/seed?email=..&uid=..&platform=macos&name=..   (让某账号在另一台设备上已经登录)   GET /_test/sessions
"""
import json, os, sys, threading, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

USERS = {  # email -> [id, password]
    'user1@example.test': ['rec1abc23', 'Passw0rd!'],
    'user2@example.test': ['rec2def45', 'Another-Pass1'],
}
DEVICES = {}   # user_id -> {uid: {...}}
SESSIONS = {}  # session_id -> {...}
STATE = {'mode': 'ok', 'hits': 0, 'limit': 2, 'plan': 'free', 'nodes': 'none'}
SNAPS = {}     # user_id -> {version, payload, size, updated, device}
V1_DIR = sys.argv[2] if len(sys.argv) > 2 else ''
LOCK = threading.Lock()
ONLINE_TTL = 600


def active(s):
    return s['revoked'] is None and s['exp'] > time.time() and s['hb'] > time.time() - ONLINE_TTL


def plan_obj():
    pro = STATE['plan'] == 'pro'
    off = {'enabled': pro, 'tier': 'pro', 'coming_soon': not pro}
    if not pro:
        off['reason'] = 'upgrade'
    return {'plan': {'code': STATE['plan'], 'title': 'Pro' if pro else 'Free', 'max_devices_per_platform': STATE['limit']}, 'expires_at': 1790000000 if pro else None,
            'limits': {'devices_per_platform': STATE['limit']},
            'features': {'core': {'enabled': True, 'tier': 'free'}, 'sync': {'enabled': True, 'tier': 'free'}, 'vps_deploy': {'enabled': True, 'tier': 'free'}, 'official_proxy': off},
            'official': {'available': pro, 'nodes': len(NODES) if pro else 0}}


def _node(i, **kw):
    o = {'type': 'http', 'tag': '官方-区域%d' % i, 'server': 'n%d.example.invalid' % i, 'server_port': 443, 'username': 'u%d' % i, 'password': 'pw%d' % i, 'tls': {'enabled': True, 'server_name': 'n%d.example.invalid' % i}}
    o.update(kw)
    return {'outbound': o}


NODES = [_node(1), _node(2), {'outbound': {'type': 'hysteria2', 'tag': '官方-海星', 'server': 'y.example.invalid', 'server_port': 8443, 'password': 'pw', 'tls': {'enabled': True}}}]


def nodes_body():
    m = STATE['nodes']
    if m == 'ok':
        return {'entitled': True, 'nodes': NODES}
    if m == 'ok2':      # same nodes, other order / key order
        return {'entitled': True, 'nodes': [{'outbound': dict(reversed(list(n['outbound'].items())))} for n in reversed(NODES)]}
    if m == 'changed':
        return {'entitled': True, 'nodes': NODES + [_node(7)]}
    if m == 'empty':
        return {'entitled': True, 'nodes': []}
    return {'entitled': False, 'nodes': []}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):  # 不记录任何请求 (避免密码出现在日志里)
        pass

    def _send(self, code, obj):
        b = json.dumps(obj, separators=(',', ':')).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _session(self):
        sid = self.headers.get('X-Enana-Session', '')
        auth = self.headers.get('Authorization', '')
        s = SESSIONS.get(sid)
        if not s or auth != 'Bearer tok-' + sid:
            return None, 'invalid'
        if s['revoked'] is not None:
            return s, s['revoked']
        if s['exp'] <= time.time():
            s['revoked'] = 'expired'
            return s, 'expired'
        return s, None

    def _devlist(self, uid_user, platform=None, cur_uid=None):
        out = []
        for uid, d in DEVICES.get(uid_user, {}).items():
            if platform and d['platform'] != platform:
                continue
            on = any(active(s) for s in SESSIONS.values() if s['user'] == uid_user and s['uid'] == uid)
            out.append({'app': d.get('app', ''), 'current': uid == cur_uid, 'ip_hint': '203.0.*.*', 'last_seen': int(d['last_seen']), 'name': d['name'],
                        'online': on, 'os': d.get('os', ''), 'platform': d['platform'], 'uid': uid})
        return out

    def do_GET(self):
        u = urlparse(self.path)
        if u.path == '/api/health':
            return self._send(200, {'message': 'API is healthy.', 'code': 200, 'data': {}})
        if u.path.startswith('/v1/') and V1_DIR:
            if STATE['mode'] == 'down':
                return self._send(502, {'message': 'bad gateway'})
            with LOCK:
                s, why = self._session()
            if s is None or why:
                return self._send(401, {'code': 'session_revoked', 'reason': why or 'invalid'})
            f = os.path.join(V1_DIR, os.path.basename(u.path))
            if not os.path.isfile(f):
                return self._send(404, {'message': 'not found'})
            b = open(f, 'rb').read()
            self.send_response(200); self.send_header('Content-Type', 'application/octet-stream'); self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
            return
        if u.path == '/_test/hits':
            return self._send(200, {'hits': STATE['hits'], 'node_hits': STATE.get('node_hits', 0)})
        if u.path == '/_test/sessions':
            return self._send(200, {'sessions': [{'id': k, 'user': v['user'], 'uid': v['uid'], 'platform': v['platform'], 'revoked': v['revoked'], 'active': active(v)} for k, v in SESSIONS.items()]})
        if u.path == '/api/enana/v1/devices':
            if STATE['mode'] == 'down':
                return self._send(502, {'message': 'bad gateway'})
            with LOCK:
                s, why = self._session()
                if s is None or why:
                    return self._send(401, {'code': 'session_revoked', 'reason': why or 'invalid'})
                return self._send(200, {'devices': self._devlist(s['user'], None, s['uid']), 'limit': STATE['limit'], 'platform': s['platform']})
        if u.path == '/api/enana/v1/plan':
            if STATE['mode'] == 'down':
                return self._send(502, {'message': 'bad gateway'})
            with LOCK:
                s, why = self._session()
                if s is None or why:
                    return self._send(401, {'code': 'session_revoked', 'reason': why or 'invalid'})
            return self._send(200, plan_obj())
        if u.path == '/api/enana/v1/nodes':
            if STATE['mode'] == 'down':
                return self._send(502, {'message': 'bad gateway'})
            with LOCK:
                s, why = self._session()
                if s is None or why:
                    return self._send(401, {'code': 'session_revoked', 'reason': why or 'invalid'})
                STATE['node_hits'] = STATE.get('node_hits', 0) + 1
            if STATE['nodes'] == '500':
                return self._send(500, {'message': 'boom'})
            if STATE['nodes'] == 'junk':
                b = b'<html>login</html>'
                self.send_response(200); self.send_header('Content-Type', 'text/html'); self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
                return
            return self._send(200, nodes_body())
        if u.path == '/api/enana/v1/sync/snapshot':
            if STATE['mode'] == 'down':
                return self._send(502, {'message': 'bad gateway'})
            with LOCK:
                s, why = self._session()
                if s is None or why:
                    return self._send(401, {'code': 'session_revoked', 'reason': why or 'invalid'})
                sn = SNAPS.get(s['user'])
                if not sn:
                    return self._send(200, {'exists': False})
                out = {'exists': True, 'version': sn['version'], 'updated': int(sn['updated']), 'size': sn['size'], 'device': sn['device']}
                if parse_qs(u.query).get('payload', [''])[0] == '1':
                    out['payload'] = sn['payload']
                return self._send(200, out)
        self._send(404, {'message': 'not found'})

    def _body(self):
        n = int(self.headers.get('Content-Length') or 0)
        raw = self.rfile.read(n) if n else b''
        try:
            return json.loads(raw or b'{}')
        except Exception:
            return None

    def do_PUT(self):
        u = urlparse(self.path)
        body = self._body()
        if STATE['mode'] == 'down':
            return self._send(502, {'message': 'bad gateway'})
        if u.path != '/api/enana/v1/sync/snapshot':
            return self._send(404, {'message': 'not found'})
        with LOCK:
            s, why = self._session()
            if s is None or why:
                return self._send(401, {'code': 'session_revoked', 'reason': why or 'invalid'})
            if not isinstance(body, dict) or not isinstance(body.get('payload'), str) or not body['payload']:
                return self._send(400, {'code': 'bad_payload'})
            cur = SNAPS.get(s['user'], {'version': 0})['version']
            if int(body.get('base_version', -1)) != cur:
                return self._send(409, {'code': 'conflict', 'version': cur})
            SNAPS[s['user']] = {'version': cur + 1, 'payload': body['payload'], 'size': int(body.get('size', 0)), 'updated': time.time(), 'device': DEVICES[s['user']][s['uid']]['name']}
            return self._send(200, {'version': cur + 1})

    def do_DELETE(self):
        u = urlparse(self.path)
        if STATE['mode'] == 'down':
            return self._send(502, {'message': 'bad gateway'})
        if u.path != '/api/enana/v1/sync/snapshot':
            return self._send(404, {'message': 'not found'})
        with LOCK:
            s, why = self._session()
            if s is None or why:
                return self._send(401, {'code': 'session_revoked', 'reason': why or 'invalid'})
            SNAPS.pop(s['user'], None)
            return self._send(200, {'ok': True})

    def do_POST(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        n = int(self.headers.get('Content-Length') or 0)
        raw = self.rfile.read(n) if n else b''
        if u.path == '/_test/mode':
            STATE['mode'] = q.get('m', ['ok'])[0]
            return self._send(200, {'mode': STATE['mode']})
        if u.path == '/_test/limit':
            STATE['limit'] = int(q.get('n', ['2'])[0])
            return self._send(200, {'limit': STATE['limit']})
        if u.path == '/_test/passwd':
            with LOCK:
                USERS[q['email'][0]][1] = q['pw'][0]
            return self._send(200, {'ok': True})
        if u.path == '/_test/nodes':
            STATE['nodes'] = q.get('mode', ['none'])[0]
            return self._send(200, {'nodes': STATE['nodes']})
        if u.path == '/_test/plan':
            STATE['plan'] = q.get('code', ['free'])[0]
            return self._send(200, {'plan': STATE['plan']})
        if u.path == '/_test/snap':    # 看云端到底存了什么 (应该只有密文)
            with LOCK:
                return self._send(200, {'snaps': {k: {'version': v['version'], 'payload': v['payload'], 'size': v['size']} for k, v in SNAPS.items()}})
        if u.path == '/_test/revoke':
            with LOCK:
                c = 0
                for s in SESSIONS.values():
                    if s['uid'] == q['uid'][0] and s['revoked'] is None:
                        s['revoked'] = q.get('reason', ['kicked'])[0]; c += 1
            return self._send(200, {'revoked': c})
        if u.path == '/_test/seed':   # 让某账号在另一台设备上已经登录
            em = q['email'][0]; uid = q['uid'][0]
            with LOCK:
                self._login_ok(USERS[em][0], {'uid': uid, 'name': q.get('name', ['其它设备'])[0], 'platform': q.get('platform', ['macos'])[0], 'os': '14.5', 'arch': 'arm64', 'app': '2.1.0'})
            return self._send(200, {'ok': True})
        # ---- 以下是被测接口 (test mode 对它们全部生效: down = 云端不可用, ratelimit = 限流) ----
        mode = STATE['mode']
        if mode == 'down':
            return self._send(502, {'message': 'bad gateway'})
        if mode == 'ratelimit':
            return self._send(429, {'message': 'Too Many Requests.', 'status': 429})
        try:
            body = json.loads(raw or b'{}')
        except Exception:
            body = None
        if u.path == '/api/enana/v1/account/password':
            with LOCK:
                s, why = self._session()
                if s is None or why:
                    return self._send(401, {'code': 'session_revoked', 'reason': why or 'invalid'})
                em = [e for e, v in USERS.items() if v[0] == s['user']][0]
                old_, new_ = (body or {}).get('old_password', ''), (body or {}).get('new_password', '')
                if USERS[em][1] != old_:
                    return self._send(400, {'code': 'bad_credentials'})
                if not (8 <= len(new_) <= 71) or new_ == old_:
                    return self._send(400, {'code': 'weak_password'})
                USERS[em][1] = new_
                for sid, t in SESSIONS.items():
                    if t is not s and t['user'] == s['user'] and t['revoked'] is None:
                        t['revoked'] = 'password_changed'
                sid = [k for k, v in SESSIONS.items() if v is s][0]
                return self._send(200, {'ok': True, 'token': 'tok-' + sid, 'session': {'id': sid, 'expires_at': int(s['exp'])}})
        if u.path in ('/api/enana/v1/session/heartbeat', '/api/enana/v1/session/logout', '/api/enana/v1/devices/kick'):
            with LOCK:
                s, why = self._session()
                if s is None:
                    return self._send(401, {'code': 'session_revoked', 'reason': 'invalid'})
                if why:
                    return self._send(401, {'code': 'session_revoked', 'reason': why})
                if u.path.endswith('/heartbeat'):
                    s['hb'] = time.time(); DEVICES[s['user']][s['uid']]['last_seen'] = time.time()
                    return self._send(200, {'ok': True, 'token': 'tok-' + [k for k, v in SESSIONS.items() if v is s][0], 'expires_at': int(s['exp'])})
                if u.path.endswith('/logout'):
                    s['revoked'] = 'logout'
                    return self._send(200, {'ok': True})
                tgt = (body or {}).get('device_uid', '')
                if tgt == s['uid']:
                    return self._send(400, {'code': 'cannot_kick_self'})
                c = 0
                for t in SESSIONS.values():
                    if t['user'] == s['user'] and t['uid'] == tgt and t['revoked'] is None:
                        t['revoked'] = 'kicked'; c += 1
                return self._send(200, {'ok': True, 'revoked': c})
        if u.path not in ('/api/enana/v1/auth/login', '/api/collections/users/records'):
            return self._send(404, {'message': 'not found'})
        with LOCK:
            STATE['hits'] += 1
        if mode == 'badjson':
            return self._send(200, {'unexpected': True})
        if body is None:
            return self._send(400, {'message': 'Failed to read request body.', 'status': 400, 'data': {}})
        if u.path == '/api/collections/users/records':   # 注册
            em = (body.get('email') or '').lower(); pw = body.get('password') or ''
            err = {}
            if '@' not in em or '.' not in em.split('@')[-1]:
                err['email'] = {'code': 'validation_is_email', 'message': 'Must be a valid email address.'}
            elif em in USERS:
                err['email'] = {'code': 'validation_not_unique', 'message': 'The email is invalid or already in use.'}
            if len(pw) < 8:
                err['password'] = {'code': 'validation_length_out_of_range', 'message': 'The length must be between 8 and 72.'}
            if pw != body.get('passwordConfirm'):
                err['passwordConfirm'] = {'code': 'validation_values_mismatch', 'message': "Values don't match."}
            if err:
                return self._send(400, {'data': err, 'message': 'Failed to create record.', 'status': 400})
            with LOCK:
                USERS[em] = ['rec%08d' % (len(USERS) + 100), pw]
            return self._send(200, {'collectionId': '_pb_users_auth_', 'collectionName': 'users', 'email': em, 'id': USERS[em][0], 'verified': False})
        # 登录
        em = (body.get('email') or '').lower(); pw = body.get('password') or ''
        u_ = USERS.get(em)
        if not u_ or u_[1] != pw:
            return self._send(400, {'code': 'bad_credentials', 'message': 'Failed to authenticate.'})
        dev = body.get('device') or {}
        if not dev.get('uid'):
            return self._send(400, {'code': 'bad_device'})
        with LOCK:
            kick = body.get('kick_device_uid') or ''
            if kick:
                for s in SESSIONS.values():
                    if s['user'] == u_[0] and s['uid'] == kick and s['revoked'] is None:
                        s['revoked'] = 'kicked'
            for s in SESSIONS.values():   # 同一设备重新登录: 旧会话作废, 不占名额
                if s['user'] == u_[0] and s['uid'] == dev['uid'] and s['revoked'] is None:
                    s['revoked'] = 'logout'
            plat = dev.get('platform', 'macos')
            act = {s['uid'] for s in SESSIONS.values() if s['user'] == u_[0] and s['platform'] == plat and active(s)}
            if len(act) >= STATE['limit']:
                devs = [d for d in self._devlist(u_[0], plat) if d['uid'] in act]
                return self._send(409, {'code': 'device_limit', 'devices': devs, 'limit': STATE['limit'], 'platform': plat})
            sid = self._login_ok(u_[0], dev)
            s = SESSIONS[sid]
        return self._send(200, {'heartbeat_secs': 120, 'plan': {'code': 'free', 'max_devices_per_platform': STATE['limit']},
                                'session': {'expires_at': int(s['exp']), 'id': sid}, 'token': 'tok-' + sid, 'user': {'email': em, 'id': u_[0]}})

    def _login_ok(self, user_id, dev):
        DEVICES.setdefault(user_id, {})[dev['uid']] = {'name': dev.get('name', ''), 'platform': dev.get('platform', 'macos'), 'os': dev.get('os', ''),
                                                       'arch': dev.get('arch', ''), 'app': dev.get('app', ''), 'last_seen': time.time()}
        sid = uuid.uuid4().hex[:15]
        SESSIONS[sid] = {'user': user_id, 'uid': dev['uid'], 'platform': dev.get('platform', 'macos'), 'hb': time.time(), 'exp': time.time() + 30 * 86400, 'revoked': None}
        return sid


if __name__ == '__main__':
    ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
