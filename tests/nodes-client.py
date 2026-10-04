#!/usr/bin/env python3
"""Real local CGI, shell generator, private cache and isolated fake cloud."""
import http.server,json,os,pathlib,subprocess,tempfile,threading,time,unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
SID='s'*15
TAG='enana-official-'+'n'*15+' Official US'
NODE={'label':'Official US','capability':'general','outbound':{'type':'http','tag':TAG,'server':'proxy.example.com','server_port':443,'username':'private-test-user','password':'private-test-password','tls':{'enabled':True}}}

class Client(unittest.TestCase):
 def test_cache_routing_export_and_logout(self):
  with tempfile.TemporaryDirectory() as d:
   h=pathlib.Path(d);(h/'session').write_text(SID);(h/'cloud.token').write_text('fixture-token');(h/'secret').write_text('fixture-local-token')
   payload={'ok':True,'entitled':True,'email_verified':True,'user_id':'u'*15,'session_id':SID,'expires_at':int(time.time())+1200,'nodes':[NODE]}
   (h/'official.json').write_text(json.dumps(payload))
   own={'role':'pin','outbound':{'type':'http','tag':'Own','server':'own.example.com','server_port':443,'password':'own-password'}}
   (h/'servers.jsonl').write_text(json.dumps(own,separators=(',',':'))+'\n')
   def shell(code):
    prefix='. lib/common.sh\ninit_paths "$PWD/install.sh"\nfor f in i18n jobs servers apps autosites sites fetch os enhanced auth device session cloud dns logs update config ops speed stats prefs snapshot plan official sync vps; do . "$LIB/$f.sh"; done\nload_settings\n'
    return subprocess.run(['bash','-c',prefix+code],cwd=ROOT,env={**os.environ,'ENANA_HOME':d},capture_output=True,text=True)
   emit=shell('srv_emit');self.assertEqual(emit.returncode,0,emit.stderr);self.assertIn('Own',emit.stdout);self.assertIn(TAG,emit.stdout)
   self.assertIn('pin\t'+TAG,emit.stdout)
   result=shell('gen_config --no-rulesets');self.assertEqual(result.returncode,0,result.stderr)
   config=json.loads((h/'config.json.new').read_text());obs={x['tag']:x for x in config['outbounds']}
   self.assertIn(TAG,obs['PIN']['outbounds']);self.assertEqual(obs['PIN']['default'],'Own');self.assertIn(TAG,obs['Global']['outbounds'])
   result=shell('official_cache role "" '+repr(TAG)+' auto; gen_config --no-rulesets');self.assertEqual(result.returncode,0,result.stderr)
   config=json.loads((h/'config.json.new').read_text());obs={x['tag']:x for x in config['outbounds']};self.assertIn(TAG,obs['AUTO']['outbounds']);self.assertNotIn(TAG,obs['PIN']['outbounds'])
   check=shell('srv_check_line \'{"role":"auto","outbound":{"type":"http","tag":"enana-official-fake","server":"example.com","server_port":443}}\'')
   self.assertNotEqual(check.returncode,0)
   check=shell('srv_secret_fields '+repr(TAG));self.assertEqual(check.returncode,3);self.assertNotIn('private-test',check.stdout)
   snapshot=subprocess.run(['perl',str(ROOT/'lib/snapshot.pl'),'build',d,'2.3.8','fixture','all'],capture_output=True,text=True)
   self.assertEqual(snapshot.returncode,0,snapshot.stderr);self.assertNotIn('private-test',snapshot.stdout);self.assertNotIn(TAG,snapshot.stdout)
   payload['expires_at']=int(time.time())-1;(h/'official.json').write_text(json.dumps(payload))
   result=shell('gen_config --no-rulesets');self.assertEqual(result.returncode,0,result.stderr);self.assertNotIn(TAG,(h/'config.json.new').read_text())
   result=shell('session_clear');self.assertEqual(result.returncode,0,result.stderr);self.assertFalse((h/'official.json').exists());self.assertFalse((h/'official.roles.json').exists())

 def test_authenticated_ui_bridge_does_not_relay_credentials(self):
  calls=[]
  class Cloud(http.server.BaseHTTPRequestHandler):
   def do_GET(self):
    body={'ok':True,'revision':'server-sharing-v1','shares':[]};self.send(body)
   def do_POST(self):
    raw=json.loads(self.rfile.read(int(self.headers.get('Content-Length',0))))
    calls.append((self.path,self.headers.get('Authorization'),self.headers.get('X-Enana-Session'),raw));self.send({'ok':True,'status':'pending','outbound':NODE['outbound']})
   def send(self,v):
    body=json.dumps(v).encode();self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
   def log_message(self,*args):pass
  server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Cloud);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
  try:
   with tempfile.TemporaryDirectory() as d:
    h=pathlib.Path(d);(h/'secret').write_text('local-test-token\n');(h/'session').write_text(SID+'\n');(h/'cloud.token').write_text('cloud-test-token\n');(h/'loggedin').write_text('fixture@example.invalid\n');(h/'account.conf').write_text('id='+'u'*15+'\n')
    (h/'official.json').write_text(json.dumps({'ok':True,'entitled':True,'email_verified':True,'session_id':SID,'user_id':'u'*15,'expires_at':int(time.time())+600,'nodes':[NODE]}))
    (h/'servers.jsonl').write_text(json.dumps({'role':'auto','outbound':{'type':'http','tag':'Own','server':'own.example.com','server_port':443,'password':'own-only'}},separators=(',',':'))+'\n')
    env={**os.environ,'ENANA_HOME':d,'ENANA_API_PIPE':'1','ENANA_ACCOUNT_URL':f'http://127.0.0.1:{server.server_port}','API_PORT':'19379','PORT':'19380'}
    def cgi(route,body=None,sudo=None):
     method='POST' if body is not None else 'GET';raw=json.dumps(body).encode() if body is not None else b''
     request=f'{method} {route} HTTP/1.1\r\nHost: 127.0.0.1:19379\r\nX-Enana: 1\r\nX-Enana-Token: local-test-token\r\nContent-Type: application/json\r\nContent-Length: {len(raw)}\r\n'
     if sudo:request+='X-Enana-Sudo: '+sudo+'\r\n'
     p=subprocess.run(['bash',str(ROOT/'lib/api.sh')],input=request.encode()+b'\r\n'+raw,env=env,capture_output=True,timeout=15)
     return json.loads(p.stdout.split(b'\r\n\r\n',1)[1])
    status=cgi('/api/state');public=json.dumps(status);self.assertNotIn('private-test',public);self.assertNotIn('proxy.example.com',public)
    official=[x for x in status['servers'] if x.get('official')];self.assertEqual(len(official),1);self.assertEqual(official[0]['server'],'');self.assertEqual(official[0]['port'],0)
    self.assertEqual(cgi('/api/official/status')['nodes'],1);self.assertEqual(len(calls),0,'status GET cannot apply configuration')
    self.assertEqual(cgi('/api/servers/share',{'tag':'Own','consent':True,'revision':'server-sharing-v1'})['code'],'E_SUDO_REQUIRED');self.assertEqual(len(calls),0)
    issue=subprocess.run(['bash','-c','. lib/common.sh;init_paths "$PWD/install.sh";. lib/auth.sh;auth_sudo_issue'],cwd=ROOT,env=env,capture_output=True,text=True);self.assertEqual(issue.returncode,0,issue.stderr);sudo=issue.stdout.strip()
    r=cgi('/api/servers/share',{'tag':'Own','consent':True,'revision':'server-sharing-v1','ssh_password':'ignored'},sudo)
    self.assertEqual(r['status'],'pending');self.assertNotIn('private-test',json.dumps(r));self.assertEqual(calls[0][0],'/api/enana/v1/servers/share');self.assertEqual(calls[0][1],'Bearer cloud-test-token');self.assertEqual(calls[0][2],SID);self.assertEqual(calls[0][3]['outbound']['password'],'own-only');self.assertNotIn('ssh_password',calls[0][3]);self.assertTrue((h/'servers.shared').exists())
  finally:server.shutdown();server.server_close();thread.join()

if __name__=='__main__':unittest.main()
