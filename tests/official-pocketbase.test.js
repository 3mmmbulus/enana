'use strict';
// Official route nodes against a REAL PocketBase + SQLite, with a local HTTPS server standing in for the
// third-party subscription. Everything is synthetic: *.example.invalid nodes, a fake token, a throw-away
// self-signed certificate (trusted only by the PocketBase child via SSL_CERT_FILE).
//   PB_BIN=/path/to/pocketbase node --test tests/official-pocketbase.test.js
// Linux only: Go ignores SSL_CERT_FILE on macOS, where the fetch would (correctly) fail certificate validation.
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path'),net=require('node:net'),https=require('node:https'),crypto=require('node:crypto');
const {spawn,spawnSync}=require('node:child_process');
const REPO=path.resolve(__dirname,'..');
const TOKEN='SECRET-TOKEN-FOR-TEST-ONLY';
async function port(){const s=net.createServer();await new Promise(r=>s.listen(0,'127.0.0.1',r));const p=s.address().port;await new Promise(r=>s.close(r));return p}
const delay=ms=>new Promise(r=>setTimeout(r,ms));
function node(i,extra={}){return {type:'http',tag:'区域'+i,server:`n${i}.example.invalid`,server_port:443,username:'u'+i,password:'pw'+i,tls:{enabled:true,server_name:`n${i}.example.invalid`},...extra}}
function body(n,drop=[]){
 const o=[{type:'selector',tag:'PROXY',outbounds:['x']},{type:'direct',tag:'direct'}];
 for(let i=0;i<n;i++)if(!drop.includes(i))o.push(node(i));
 o.push({type:'vless',tag:'剩余流量：1GB',server:'info.example.invalid',server_port:443,uuid:'u'});
 o.push({type:'trojan',tag:'T',server:'t.example.invalid',server_port:443,password:'pw',detour:'direct',tls:{enabled:true,certificate_path:'/etc/passwd'}});
 return JSON.stringify({outbounds:o});
}
test('official nodes: scheduled import, entitlement gate, failure handling and secrecy',{timeout:150000,skip:process.platform==='darwin'?'needs SSL_CERT_FILE support (Linux)':false},async t=>{
 const binary=process.env.PB_BIN;if(!binary)throw Error('PB_BIN is required for the real database integration test');
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'enana-official-test-')),data=path.join(dir,'data'),hooks=path.join(dir,'hooks'),cfgFile=path.join(dir,'official.json');
 fs.cpSync(path.join(REPO,'server/pb_hooks'),hooks,{recursive:true});
 fs.writeFileSync(path.join(hooks,'test_cron.pb.js'),'routerAdd("POST","/__test/cron",(e)=>e.json(200,{r:require(`${__hooks}/enana_official.js`).sync(false)}));routerAdd("POST","/__test/backdate",(e)=>{const b=JSON.parse(toString(e.request.body));$app.db().newQuery("UPDATE official_nodes SET fresh_until={:t}").bind(b).execute();return e.json(200,{ok:true})});');
 // throw-away certificate for https://localhost:<port>
 const key=path.join(dir,'key.pem'),crt=path.join(dir,'cert.pem');
 const ossl=spawnSync('openssl',['req','-x509','-newkey','rsa:2048','-nodes','-keyout',key,'-out',crt,'-days','2','-subj','/CN=localhost','-addext','subjectAltName=DNS:localhost,IP:127.0.0.1'],{encoding:'utf8'});assert.equal(ossl.status,0,'openssl is needed for the local HTTPS fixture: '+ossl.stderr);
 // fake subscription provider
 const up={mode:'ok',n:6,drop:[],hits:0,agents:[],paths:[]};
 const srv=https.createServer({key:fs.readFileSync(key),cert:fs.readFileSync(crt)},(rq,rs)=>{
  up.hits++;up.agents.push(rq.headers['user-agent']);up.paths.push(rq.url);
  if(up.mode==='500'){rs.writeHead(500);return rs.end('boom')}
  if(up.mode==='html'){rs.writeHead(200,{'Content-Type':'text/html'});return rs.end('<html>login</html>')}
  if(up.mode==='empty'){rs.writeHead(200,{'Content-Type':'application/json'});return rs.end('{"outbounds":[{"type":"direct","tag":"d"}]}')}
  if(up.mode==='huge'){rs.writeHead(200,{'Content-Type':'application/json'});return rs.end(' '.repeat(5*1024*1024)+'{}')}
  rs.writeHead(200,{'Content-Type':'application/json','subscription-userinfo':'upload=1; download=2; total=3; expire=4'});rs.end(body(up.n,up.drop));
 });
 const sport=await port();await new Promise(r=>srv.listen(sport,'127.0.0.1',r));
 const source={id:'main',url:`https://localhost:${sport}/subs/${TOKEN}`,ua:'sing-box/1.12.0',prefix:'官方-',enabled:true};
 const writeCfg=(sources=[source],extra={})=>fs.writeFileSync(cfgFile,JSON.stringify({sources,...extra}),{mode:0o600});
 writeCfg();
 const pw=crypto.randomBytes(24).toString('hex'),host='http://127.0.0.1:'+await port();
 const args=['--dir='+data,'--hooksDir='+hooks,'--migrationsDir='+path.join(REPO,'server/pb_migrations'),'--hooksWatch=false'];
 const env={...process.env,ENANA_OFFICIAL_CONFIG:cfgFile,ENANA_BILLING_CONFIG:path.join(dir,'none.json'),SSL_CERT_FILE:crt};
 assert.equal(spawnSync(binary,['superuser','upsert','admin@example.invalid',pw,...args],{env,encoding:'utf8'}).status,0,'isolated database setup');
 const pb=spawn(binary,['serve','--http='+host.replace('http://',''),...args],{env,stdio:['ignore','ignore','ignore']});
 async function req(route,b,s,admin,method){const h={'Content-Type':'application/json'};if(s){h.Authorization=s.token;h['X-Enana-Session']=s.session.id}if(admin)h.Authorization=admin;
  const r=await fetch(host+route,{method:method||(b?'POST':'GET'),headers:h,body:b?JSON.stringify(b):undefined,signal:AbortSignal.timeout(60000)});const text=await r.text();let json=null;try{json=JSON.parse(text)}catch(_){}return {status:r.status,body:json,text}}
 const patch=async(route,b,admin)=>{const r=await req(route,b,null,admin,'PATCH');assert.equal(r.status,200,'fixture update '+route+' '+r.text);return r.body};
 let counter=0;
 async function user(admin,{verified=true,pro=false}={}){
  const email='u'+(++counter)+'@example.invalid',r=await req('/api/collections/users/records',{email,password:pw,passwordConfirm:pw});assert.equal(r.status,200,'register');
  if(verified)await patch('/api/collections/users/records/'+r.body.id,{verified:true},admin);
  const l=await req('/api/enana/v1/auth/login',{email,password:pw,device:{uid:crypto.randomUUID(),platform:'macos',name:'Official test'}});assert.equal(l.status,200,'login');
  if(pro){
   const plans=(await req('/api/collections/plans/records?filter='+encodeURIComponent('code="pro"'),null,null,admin)).body.items;
   const subs=(await req('/api/collections/subscriptions/records?filter='+encodeURIComponent('user="'+r.body.id+'"'),null,null,admin)).body.items;
   await patch('/api/collections/subscriptions/records/'+subs[0].id,{plan:plans[0].id,status:'active',expires_at:new Date(Date.now()+30*86400000).toISOString().replace('T',' ')},admin);
  }
  return {...l.body,email,id:r.body.id};
 }
 try{
  for(let i=0;i<100;i++){try{if((await req('/api/health')).status===200)break}catch(_){}if(i===99)throw Error('test database did not become ready');await delay(50)}
  const admin=(await req('/api/collections/_superusers/auth-with-password',{identity:'admin@example.invalid',password:pw})).body.token;
  await patch('/api/settings',{rateLimits:{enabled:false}},admin);
  const free=await user(admin),pro=await user(admin,{pro:true}),unverified=await user(admin,{verified:false,pro:true}),lapsed=await user(admin);
  const nodes=u=>req('/api/enana/v1/nodes',null,u),plan=async u=>(await req('/api/enana/v1/plan',null,u)).body;
  const sync=()=>req('/api/enana/admin/official/sync',{},null,admin);

  await t.test('before any sync the feature is still "coming soon" and nobody receives nodes',async()=>{
   assert.equal((await req('/api/enana/v1/nodes')).status,401);
   assert.deepEqual((await nodes(free)).body,{entitled:false,nodes:[]});
   assert.deepEqual((await nodes(pro)).body,{entitled:true,nodes:[]});                 // entitled, but nothing is fresh yet
   assert.deepEqual((await nodes(unverified)).body,{entitled:false,nodes:[]});
   for(const u of [free,pro]){const p=await plan(u);assert.equal(JSON.stringify(p.features.official_proxy).includes('"coming_soon":true'),true);assert.deepEqual(p.official,{available:false,nodes:0})}
   assert.equal((await req('/api/enana/admin/official/sync',{})).status,401);assert.equal((await req('/api/enana/admin/official/sync',{},pro,null)).status,403,'a normal user cannot trigger or read the admin routes');
   assert.equal((await req('/api/enana/admin/official/status',null,pro)).status,403);
   assert.equal((await req('/api/collections/official_nodes/records',null,pro)).status,403);
  });

  await t.test('forced sync imports only real nodes through HTTPS with the configured User-Agent',async()=>{
   const r=await sync();assert.equal(r.status,200);const s=r.body.sources;assert.equal(s.length,1);assert.equal(s[0].ok,true);assert.equal(s[0].nodes,7);   // 6 http + the trojan; group / direct / info dropped
   assert.deepEqual([up.hits,up.agents[0],up.paths[0]],[1,'sing-box/1.12.0','/subs/'+TOKEN]);
   const st=(await req('/api/enana/admin/official/status',null,null,admin)).body;assert.equal(st.sources[0].fresh,7);assert.equal(st.sources[0].nodes,7);assert.ok(st.sources[0].last_ok>0);
   assert.ok(!r.text.includes(TOKEN)&&!JSON.stringify(st).includes(TOKEN)&&!r.text.includes('localhost'),'the admin API never echoes the URL');
  });

  await t.test('entitled users receive the exact rows; free, unverified and lapsed users receive none',async()=>{
   const n=await nodes(pro);assert.equal(n.status,200);assert.equal(n.body.entitled,true);assert.equal(n.body.nodes.length,7);
   assert.ok(n.body.nodes.every(x=>Object.keys(x).join()==='outbound'&&x.outbound.tag.startsWith('官方-')));
   const tags=n.body.nodes.map(x=>x.outbound.tag);assert.deepEqual(tags,tags.slice().sort());assert.equal(new Set(tags).size,7);
   for(const x of n.body.nodes){assert.ok(n.text.includes('{"outbound":{"type":"'+x.outbound.type+'","tag":"'+x.outbound.tag+'"'),'type and tag are the first two keys on the wire')}
   const trojan=n.body.nodes.find(x=>x.outbound.type==='trojan').outbound;assert.ok(!('detour' in trojan)&&!JSON.stringify(trojan).includes('/etc/passwd'));
   for(const k of [TOKEN,'localhost','"main"','node_key','fresh_until','subscription'])assert.ok(!n.text.includes(k),'response leaks '+k);
   for(const u of [free,unverified,lapsed])assert.deepEqual((await nodes(u)).body,{entitled:false,nodes:[]});
   assert.equal((await nodes(pro)).text,n.text,'same data, same bytes');
  });

  await t.test('the plan reports the feature live for exactly the entitled users',async()=>{
   const p=await plan(pro);assert.deepEqual(p.features.official_proxy,{enabled:true,tier:'pro'});assert.deepEqual(p.official,{available:true,nodes:7});
   assert.deepEqual((await plan(free)).features.official_proxy,{enabled:false,tier:'pro',reason:'upgrade'});assert.deepEqual((await plan(free)).official,{available:false,nodes:0});
   assert.deepEqual((await plan(unverified)).features.official_proxy,{enabled:false,tier:'pro',reason:'verify'});
   for(const k of [TOKEN,'localhost'])assert.ok(!JSON.stringify(await plan(pro)).includes(k));
  });

  await t.test('expired Pro stops receiving nodes immediately; renewal brings them back',async()=>{
   const plans=(await req('/api/collections/plans/records?filter='+encodeURIComponent('code="pro"'),null,null,admin)).body.items;
   const subs=(await req('/api/collections/subscriptions/records?filter='+encodeURIComponent('user="'+pro.id+'"'),null,null,admin)).body.items;
   await patch('/api/collections/subscriptions/records/'+subs[0].id,{expires_at:'2020-01-01 00:00:00Z'},admin);
   assert.deepEqual((await nodes(pro)).body,{entitled:false,nodes:[]});assert.equal((await plan(pro)).features.official_proxy.reason,'expired');
   await patch('/api/collections/subscriptions/records/'+subs[0].id,{plan:plans[0].id,expires_at:new Date(Date.now()+30*86400000).toISOString().replace('T',' ')},admin);
   assert.equal((await nodes(pro)).body.nodes.length,7);
  });

  await t.test('upstream failures never wipe existing nodes',async()=>{
   const before=(await nodes(pro)).text;
   for(const [mode,code] of [['500','http_500'],['html','bad_format'],['empty','no_nodes'],['huge','too_large']]){
    up.mode=mode;const r=await sync();up.mode='ok';assert.equal(r.body.sources[0].ok,false);assert.equal(r.body.sources[0].error,code,mode);assert.ok(!r.text.includes(TOKEN));
    assert.equal((await nodes(pro)).text,before,'nodes unchanged after '+mode);
   }
  });

  await t.test('a sync with unchanged upstream is a no-op on the wire; changes add, rename and remove nodes',async()=>{
   const before=(await nodes(pro)).text;assert.equal((await sync()).body.sources[0].nodes,7);assert.equal((await nodes(pro)).text,before);
   up.n=8;up.drop=[2];                                      // node 2 vanishes, nodes 6 and 7 appear
   assert.equal((await sync()).body.sources[0].nodes,8);
   const tags=(await nodes(pro)).body.nodes.map(x=>x.outbound.tag);
   assert.ok(!tags.includes('官方-区域2')&&tags.includes('官方-区域6')&&tags.includes('官方-区域7')&&tags.length===8);
   up.n=6;up.drop=[];assert.equal((await sync()).body.sources[0].nodes,7);
  });

  await t.test('the hourly job fetches only when due; a failing source retries without touching nodes',async()=>{
   const hits=up.hits,r=await req('/__test/cron',{});assert.equal(r.body.r[0].due,false);assert.equal(up.hits,hits,'fresh source: no request');
   const before=(await nodes(pro)).text;
   await req('/__test/backdate',{t:new Date(Date.now()-4*3600*1000).toISOString().replace('T',' ')});          // last success 4h+ ago, rows still fresh (ttl 24h) -> due
   await req('/__test/backdate',{t:new Date(Date.now()+20*3600*1000).toISOString().replace('T',' ')});
   up.mode='500';const f=await req('/__test/cron',{});assert.equal(f.body.r[0].ok,false);assert.equal(up.hits,hits+1);assert.equal((await nodes(pro)).text,before,'a failed run keeps serving');
   up.mode='ok';const g=await req('/__test/cron',{});assert.equal(g.body.r[0].ok,true);assert.equal(up.hits,hits+2);
  });

  await t.test('rows that are no longer fresh stop being served and the feature falls back to "coming soon"',async()=>{
   await req('/__test/backdate',{t:'2020-01-01 00:00:00.000Z'});
   assert.deepEqual((await nodes(pro)).body,{entitled:true,nodes:[]});
   assert.ok((await plan(pro)).features.official_proxy.coming_soon);assert.deepEqual((await plan(pro)).official,{available:false,nodes:0});
   assert.equal((await sync()).body.sources[0].ok,true);assert.equal((await nodes(pro)).body.nodes.length,7);
  });

  await t.test('configuration safety: unreadable file keeps nodes, http:// and userinfo URLs are ignored, disabling removes the source',async()=>{
   fs.renameSync(cfgFile,cfgFile+'.off');const hits=up.hits;
   assert.deepEqual((await sync()).body.sources,[]);assert.equal(up.hits,hits);assert.equal((await nodes(pro)).body.nodes.length,7,'a missing file must never retire nodes');
   fs.renameSync(cfgFile+'.off',cfgFile);
   writeCfg([{...source,url:`http://localhost:${sport}/subs/${TOKEN}`}]);assert.deepEqual((await sync()).body.sources,[]);assert.equal(up.hits,hits,'plain http is never fetched');
   assert.deepEqual((await nodes(pro)).body,{entitled:true,nodes:[]},'a valid config without usable sources retires the old nodes');
   writeCfg([source]);assert.equal((await sync()).body.sources[0].nodes,7);
   writeCfg([{...source,enabled:false}]);assert.deepEqual((await sync()).body.sources,[]);assert.equal((await nodes(pro)).body.nodes.length,0);
   writeCfg([source]);await sync();
  });

  await t.test('a second source is independent: its nodes join, and removing it removes only its own',async()=>{
   writeCfg([source,{...source,id:'second',prefix:'官方-乙-',url:`https://localhost:${sport}/subs/${TOKEN}-2`}]);
   const r=await sync();assert.equal(r.body.sources.length,2);const tags=(await nodes(pro)).body.nodes.map(x=>x.outbound.tag);
   assert.equal(tags.length,14);assert.equal(tags.filter(x=>x.startsWith('官方-乙-')).length,7);assert.ok(up.paths.some(p=>p.endsWith('-2')));
   writeCfg([source]);await sync();assert.equal((await nodes(pro)).body.nodes.length,7);
  });

  await t.test('the URL and node credentials appear nowhere an operator or log reader could see them',async()=>{
   const logs=await req('/api/logs?perPage=200',null,null,admin);assert.equal(logs.status,200);assert.ok(!logs.text.includes(TOKEN),'PocketBase request logs');
   const rows=await req('/api/collections/official_nodes/records?perPage=50',null,null,admin);assert.ok(!rows.text.includes(TOKEN),'database rows');
   assert.ok(rows.body.items.every(x=>x.origin==='official'&&x.approved===true&&x.enabled===true&&x.node_key.startsWith('main~')));
  });
 }finally{pb.kill('SIGTERM');await new Promise(r=>pb.once('exit',r));await new Promise(r=>srv.close(r));fs.rmSync(dir,{recursive:true,force:true})}
});
