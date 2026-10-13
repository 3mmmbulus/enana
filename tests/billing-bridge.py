"""Exercise the shared bridge without a real account or payment provider."""
import json
import http.server
import os
import pathlib
import subprocess
import tempfile
import threading
import unittest

repo = pathlib.Path(__file__).resolve().parents[1]

class BillingBridge(unittest.TestCase):
    def body(self, op, value):
        with tempfile.NamedTemporaryFile(mode='w') as f:
            json.dump(value, f); f.flush()
            return subprocess.run(['/bin/bash', '-c', '. "$1/lib/billing.sh"; billing_body "$2" "$3"', 'test', str(repo), op, f.name], capture_output=True, text=True)

    def test_checkout_whitelist_ignores_forged_prices_credentials_and_destinations(self):
        r = self.body('checkout', {'kind': 'plan', 'sku': 'm1', 'request_key': 'a'*32, 'price': 0, 'address': 'attacker', 'provider_key': 'secret'})
        self.assertEqual(r.returncode, 0)
        self.assertEqual(json.loads(r.stdout), {'kind':'plan','sku':'m1','request_key':'a'*32})
        for value in ['4', '10', '999', '1000']:   # top-ups are whole USDT, 4..1000; the cloud adds any decimals itself
            r = self.body('checkout', {'kind':'topup','amount':value,'request_key':'a'*32,'address':'attacker'})
            self.assertEqual(r.returncode, 0, value)
            self.assertEqual(json.loads(r.stdout), {'kind':'topup','amount':value,'request_key':'a'*32})

    def test_malformed_amount_keys_sku_and_boolean_rejected(self):
        for value in ['4.0000007','1e6','4;echo unsafe','-4',{},'4\n',
                      '4.000037','4.5','4.0','10.01','3','0','1001','9999','10000','04','+4',' 10','10 ','',None,True,[10]]:
            self.assertNotEqual(self.body('checkout', {'kind':'topup','amount':value,'request_key':'a'*32}).returncode, 0, repr(value))
        self.assertNotEqual(self.body('purchase', {'sku':'y99','request_key':'a'*32}).returncode, 0)
        self.assertNotEqual(self.body('auto-renew', {'enabled':'false'}).returncode, 0)
        self.assertEqual(json.loads(self.body('auto-renew', {'enabled':False}).stdout), {'enabled':False})
        self.assertNotEqual(self.body('cancel', {'id':'../private'}).returncode, 0)

    def response(self, status, content, session=True):
        with tempfile.TemporaryDirectory() as d:
            f=pathlib.Path(d)/'response'; f.write_text(content)
            code='''
              . "$1/lib/billing.sh"
              session_id() { [ "$5" = yes ] && printf sid; }
              session_token() { [ "$5" = yes ] && printf token; }
              # Function parameters are separate from script positional args.
              mode=$5; fixture=$3; http=$2
              session_id() { [ "$mode" = yes ] && printf sid; }
              session_token() { [ "$mode" = yes ] && printf token; }
              session_call() { cp "$fixture" "$1"; if [ "$http" = 0 ]; then printf 000; else printf %s "$http"; fi; }
              billing_request GET billing; rc=$?; printf "\\ncode=%s" "${BILLING_CODE:-}" >&2; exit "$rc"
            '''
            return subprocess.run(['/bin/bash','-c',code,'test',str(repo),str(status),str(f),'unused','yes' if session else 'no'],capture_output=True,text=True)

    def test_no_offline_payment_or_html_credentials_relay(self):
        # Nothing from an unexpected body is relayed; each failure maps to the code that tells the user what to do next.
        for status, value, session, code in [
            (200,'<html>private</html>',True,'E_ACCOUNT_UNREACHABLE'),        # captive portal / proxy page
            (200,'{"ok":true,"token":"secret"}',True,'E_ACCOUNT_UNREACHABLE'),
            (302,'<html>login</html>',True,'E_ACCOUNT_UNREACHABLE'),
            (0,'',True,'E_ACCOUNT_UNREACHABLE'),                              # curl could not connect (000)
            (401,'{"ok":false,"code":"E_AUTH"}',True,'E_AUTH'),               # token / session no longer valid
            (401,'{"code":"session_revoked","reason":"kicked"}',True,'E_AUTH'),
            (401,'<html>unauthorized</html>',True,'E_AUTH'),
            (200,'{"ok":true}',False,'E_AUTH'),                               # offline login: no cloud session, sign in again online
            (500,'<html>private</html>',True,'E_SERVER_ERROR'),               # reachable but broken: not "unreachable"
            (502,'<html>bad gateway</html>',True,'E_SERVER_ERROR'),
            (504,'',True,'E_SERVER_ERROR'),
            (500,'{"status":500,"message":"internal"}',True,'E_SERVER_ERROR'),
            (503,'<html>maintenance</html>',True,'E_SERVER_ERROR'),
            (404,'<html>not found</html>',True,'E_SERVER_ERROR'),
            (429,'{"status":429,"message":"rate"}',True,'E_RATE_LIMITED'),
        ]:
            r=self.response(status,value,session); self.assertNotEqual(r.returncode,0,(status,value)); self.assertEqual(r.stdout,'',(status,value)); self.assertIn('code='+code,r.stderr,(status,value))
        r=self.response(500,'{"ok":false,"code":"E_BILLING_INTERNAL","message":"private"}')   # our own error body is still relayed (whitelisted fields only)
        self.assertEqual(r.returncode,0); self.assertEqual(json.loads(r.stdout),{'ok':False,'code':'E_BILLING_INTERNAL'})
        r=self.response(503,'{"ok":false,"code":"E_PAYMENTS_UNAVAILABLE","message":"private provider error"}')
        self.assertEqual(r.returncode,0); self.assertEqual(json.loads(r.stdout),{'ok':False,'code':'E_PAYMENTS_UNAVAILABLE'})
        r=self.response(200,'{"ok":true,"wallet":{"balance":"4.000037"}}')
        self.assertEqual(json.loads(r.stdout)['wallet']['balance'],'4.000037')

    def test_order_limit_relays_only_validated_integers(self):
        # E_ORDER_LIMIT is the one error whose extra fields reach the dashboard: limit and retry_after, integers in range, nothing else.
        r=self.response(429,'{"ok":false,"code":"E_ORDER_LIMIT","limit":5,"retry_after":3600,"message":"private","user":"u1","address":"T1"}')
        self.assertEqual(r.returncode,0); self.assertEqual(json.loads(r.stdout),{'ok':False,'code':'E_ORDER_LIMIT','limit':5,'retry_after':3600})
        for limit,retry in [(1,1),(5,86400),(1000,59)]:
            r=self.response(429,json.dumps({'ok':False,'code':'E_ORDER_LIMIT','limit':limit,'retry_after':retry}))
            self.assertEqual(json.loads(r.stdout),{'ok':False,'code':'E_ORDER_LIMIT','limit':limit,'retry_after':retry},(limit,retry))
        # Out of range or junk values are dropped; the code (and any valid field) is still relayed.
        for bad in ['0','-1','86401','1.5','1e9','1000000','true','null','"3600; rm -rf /"','"soon"','[60]','{"s":60}']:
            r=self.response(429,'{"ok":false,"code":"E_ORDER_LIMIT","limit":5,"retry_after":%s}'%bad)
            self.assertEqual(r.returncode,0,bad); self.assertEqual(json.loads(r.stdout),{'ok':False,'code':'E_ORDER_LIMIT','limit':5},bad)
        for bad in ['0','1001','-5','2.5','false','"5 or more"','{}']:
            r=self.response(429,'{"ok":false,"code":"E_ORDER_LIMIT","limit":%s,"retry_after":60}'%bad)
            self.assertEqual(json.loads(r.stdout),{'ok':False,'code':'E_ORDER_LIMIT','retry_after':60},bad)
        r=self.response(429,'{"ok":false,"code":"E_ORDER_LIMIT"}')
        self.assertEqual(json.loads(r.stdout),{'ok':False,'code':'E_ORDER_LIMIT'})
        # Every other error code keeps the strict {ok, code} filter, even when it carries the same fields.
        r=self.response(409,'{"ok":false,"code":"E_ORDER_PENDING","limit":5,"retry_after":60}')
        self.assertEqual(json.loads(r.stdout),{'ok':False,'code':'E_ORDER_PENDING'})

    def test_actual_cgi_auth_routes_and_cloud_identity(self):
        calls=[]; mode={'status':200,'payload':{'ok':True,'wallet':{'balance':'4.000037'}}}
        class Cloud(http.server.BaseHTTPRequestHandler):
            def do_GET(self): self.respond()
            def do_POST(self): self.respond()
            def respond(self):
                raw=self.rfile.read(int(self.headers.get('Content-Length','0')))
                calls.append((self.path,self.headers.get('Authorization'),self.headers.get('X-Enana-Session'),raw))
                body=json.dumps(mode['payload']).encode()
                self.send_response(mode['status']); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
            def log_message(self,*args): pass
        server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Cloud)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        try:
            with tempfile.TemporaryDirectory() as d:
                home=pathlib.Path(d);(home/'secret').write_text('local-test-token\n');(home/'session').write_text('device-test-id\n');(home/'cloud.token').write_text('cloud-test-token\n')
                env={**os.environ,'ENANA_HOME':d,'ENANA_API_PIPE':'1','ENANA_ACCOUNT_URL':f'http://127.0.0.1:{server.server_port}','API_PORT':'19379','PORT':'19380'}
                def cgi(path,body=None,token=True):
                    raw=json.dumps(body).encode() if body is not None else b''
                    request=(f'{"POST" if body is not None else "GET"} {path} HTTP/1.1\r\nHost: 127.0.0.1:19379\r\nX-Enana: 1\r\n'+('X-Enana-Token: local-test-token\r\n' if token else '')+f'Content-Length: {len(raw)}\r\nContent-Type: application/json\r\n\r\n').encode()+raw
                    r=subprocess.run(['/bin/bash',str(repo/'lib/api.sh')],env=env,input=request,capture_output=True,timeout=10)
                    self.assertEqual(r.returncode,0,r.stderr.decode());return json.loads(r.stdout.split(b'\r\n\r\n',1)[1])
                self.assertEqual(cgi('/api/billing',token=False)['code'],'E_AUTH');self.assertEqual(calls,[])
                self.assertEqual(cgi('/api/billing')['wallet']['balance'],'4.000037')
                self.assertEqual(calls[-1][:3],('/api/enana/v1/billing','Bearer cloud-test-token','device-test-id'))
                self.assertEqual(cgi('/api/billing/order?id=../../private')['code'],'E_INVALID')
                cgi('/api/billing/checkout',{'kind':'plan','sku':'m1','request_key':'a'*32,'price':0,'address':'attacker'})
                self.assertEqual(json.loads(calls[-1][3]),{'kind':'plan','sku':'m1','request_key':'a'*32})
                cgi('/api/email/send',{})
                self.assertEqual(calls[-1][0],'/api/enana/v1/email/send');self.assertEqual(json.loads(calls[-1][3]),{})
                # The cloud answers 401 / 5xx / junk: the dashboard gets a precise, translated code (HTTP 200 so the local dashboard stays unlocked).
                for status,payload,code in [(401,{'code':'session_revoked','reason':'kicked'},'E_AUTH'),(502,{'message':'bad gateway'},'E_SERVER_ERROR'),(429,{'status':429},'E_RATE_LIMITED')]:
                    mode['status']=status; mode['payload']=payload
                    r=cgi('/api/billing'); self.assertEqual(r['ok'],False); self.assertEqual(r['code'],code); self.assertTrue(r['error'])
                mode['status']=200; mode['payload']={'ok':True,'wallet':{'balance':'4.000037'}}
                self.assertEqual(cgi('/api/billing')['wallet']['balance'],'4.000037')
                # Orders paging: only the two validated parameters reach the cloud; an empty value is the same as leaving it out.
                for query,forwarded in [('orders_page=2&orders_per_page=10','?orders_page=2&orders_per_page=10'),
                                        ('orders_per_page=30&orders_page=1000','?orders_page=1000&orders_per_page=30'),
                                        ('orders_per_page=5','?orders_per_page=5'),('orders_page=1','?orders_page=1'),
                                        ('orders_page=3&id=x&provider_key=y&orders_page_x=9&address=T1','?orders_page=3'),
                                        ('foo=bar&orders_page=&orders_per_page=','')]:
                    self.assertEqual(cgi('/api/billing?'+query)['wallet']['balance'],'4.000037',query)
                    self.assertEqual(calls[-1][0],'/api/enana/v1/billing'+forwarded,query)
                sent=len(calls)
                for query in ['orders_page=0','orders_page=1001','orders_page=-1','orders_page=01','orders_page=1.5','orders_page=abc',
                              'orders_page=2%3Bid','orders_page=2%26provider_key%3Dx','orders_page=%2e%2e','orders_per_page=4','orders_per_page=31',
                              'orders_per_page=05','orders_per_page=1e1','orders_page=2&orders_per_page=100']:
                    r=cgi('/api/billing?'+query); self.assertEqual((r['ok'],r['code']),(False,'E_INVALID'),query); self.assertTrue(r['error'],query)
                self.assertEqual(len(calls),sent,'an out-of-range or junk page is refused locally and never sent')
                # The order limit reaches the dashboard with its two integers; a top-up with decimals never leaves the computer.
                mode['status']=429; mode['payload']={'ok':False,'code':'E_ORDER_LIMIT','limit':5,'retry_after':3600,'message':'private'}
                self.assertEqual(cgi('/api/billing/checkout',{'kind':'topup','amount':'10','request_key':'b'*32}),{'ok':False,'code':'E_ORDER_LIMIT','limit':5,'retry_after':3600})
                self.assertEqual(json.loads(calls[-1][3]),{'kind':'topup','amount':'10','request_key':'b'*32})
                sent=len(calls)
                self.assertEqual(cgi('/api/billing/checkout',{'kind':'topup','amount':'10.5','request_key':'b'*32})['code'],'E_INVALID')
                self.assertEqual(len(calls),sent)
                mode['status']=200; mode['payload']={'ok':True,'wallet':{'balance':'4.000037'}}
        finally: server.shutdown();server.server_close();thread.join()

if __name__ == '__main__': unittest.main()
