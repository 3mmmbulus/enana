#!/usr/bin/env python3
"""测试用: 本地「互联网」。提供测速目标、IP 查询、测速文件, 不产生任何外部流量。
用法: python3 mock-net.py <端口> [规则集目录] [DoH 端口 证书 私钥]      (/rules/<文件名> 从该目录取; 没有同名文件就返回 _default.srs)
  同一个端口号上还有一个 UDP DNS 服务 (任何查询都返回 1.2.3.4); 给了第 3~5 个参数时, 另起一个 TLS 的 DoH 服务 (/dns-query?dns=…, 自签名证书)
  /204      -> 204                      (正常)
  /ok       -> 200 (立即)
  /slow     -> 200 (延迟 1.0 秒后响应)   (慢)
  /limited  -> 403                       (疑似 IP 受限)
  /ip       -> ipwho.is 风格的 JSON, ip 取决于请求来源端口 (用来区分经过哪条线路: 没有区别, 这里固定 203.0.113.9)
  /ipraw    -> 纯文本 IP (SSH 部署的「验证连通」用)
  /trace    -> cloudflare 风格的文本
  /file     -> 3 MB 数据 (测速文件)
"""
import base64, os, socket, ssl, sys, threading, time, urllib.parse
RULES_DIR = sys.argv[2] if len(sys.argv) > 2 else ''
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def dns_answer(q):
    """把查询原样带上, 加一条 A 记录 1.2.3.4 (测试 DNS 测速用)"""
    if len(q) < 17:
        return b''
    i = 12
    while i < len(q) and q[i] != 0:
        i += q[i] + 1
    end = i + 5
    return q[:2] + b'\x81\x80' + q[4:6] + b'\x00\x01\x00\x00\x00\x00' + q[12:end] + b'\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04\x01\x02\x03\x04'


def udp_dns(port):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(('127.0.0.1', port))
    while True:
        data, addr = s.recvfrom(512)
        r = dns_answer(data)
        if r:
            s.sendto(r, addr)


class DoH(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'     # 保持连接: DoH 测速取同一条连接上的第二次请求

    def log_message(self, *a):
        pass

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query).get('dns', [''])[0]
        body = b''
        if u.path == '/dns-query' and q:
            body = dns_answer(base64.urlsafe_b64decode(q + '=' * (-len(q) % 4)))
        self.send_response(200 if body else 400)
        self.send_header('Content-Type', 'application/dns-message')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *a):
        pass

    def _reply(self, code, body=b'', ctype='text/plain'):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Connection', 'close')
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        p = self.path.split('?')[0]
        if p == '/204':
            return self._reply(204)
        if p == '/ok':
            return self._reply(200, b'ok')
        if p == '/slow':
            time.sleep(1.0)
            return self._reply(200, b'slow')
        if p == '/limited':
            return self._reply(403, b'forbidden')
        if p == '/ip':
            return self._reply(200, b'{"ip":"203.0.113.9","success":true,"type":"IPv4","country":"Testland","country_code":"TL","region":"Test Region","city":"Test City","connection":{"asn":64500,"org":"Test Org","isp":"Test ISP"}}', 'application/json')
        if p == '/ipraw':
            return self._reply(200, b'203.0.113.9\n')
        if p == '/trace':
            return self._reply(200, b'fl=1\nip=203.0.113.9\nloc=TL\n')
        if p.startswith('/rules/') and RULES_DIR:
            name = urllib.parse.unquote(p[len('/rules/'):])
            f = os.path.join(RULES_DIR, os.path.basename(name))
            if not os.path.isfile(f):
                f = os.path.join(RULES_DIR, '_default.srs')
            with open(f, 'rb') as fh:
                return self._reply(200, fh.read(), 'application/octet-stream')
        if p == '/dl/VERSION':
            return self._reply(200, b'9.9.9\n')
        if p == '/dl/CHANGELOG.md':
            return self._reply(200, '# Changelog\n\n## 9.9.9 (2099-01-01)\n\n### 中文\n- 测试更新说明\n- 第二条\n\n### English\n- Test release notes\n\n## 2.1.0\n\n### 中文\n- 旧版本\n'.encode('utf-8'))
        if p.startswith('/dl/core/') and os.environ.get('MOCK_CORE_DIR'):     # sing-box 兼容清单 + 签名 (tests/run.sh 用测试私钥生成)
            f = os.path.join(os.environ['MOCK_CORE_DIR'], os.path.basename(p))
            if os.path.isfile(f):
                with open(f, 'rb') as fh:
                    return self._reply(200, fh.read(), 'application/octet-stream')
        if p == '/file':
            return self._reply(200, b'x' * 3000000, 'application/octet-stream')
        self._reply(404, b'not found')


if __name__ == '__main__':
    threading.Thread(target=udp_dns, args=(int(sys.argv[1]),), daemon=True).start()
    if len(sys.argv) > 5:
        doh = ThreadingHTTPServer(('127.0.0.1', int(sys.argv[3])), DoH)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(sys.argv[4], sys.argv[5])
        doh.socket = ctx.wrap_socket(doh.socket, server_side=True)
        threading.Thread(target=doh.serve_forever, daemon=True).start()
    ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
