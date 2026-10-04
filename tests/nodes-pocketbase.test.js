'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('fs'),os=require('os'),path=require('path'),net=require('net'),crypto=require('crypto');
const {spawn,spawnSync}=require('child_process'),REPO=path.resolve(__dirname,'..');
const fixture={type:'http',tag:'Own proxy',server:'proxy.example.com',server_port:443,username:'fixture-user',password:'private-fixture-only',tls:{enabled:true}};
test('real Pro node delivery, consent lifecycle and session gates',{timeout:90000},async t=>{
 const binary=process.env.PB_BIN;assert.ok(binary,'PB_BIN required');const dir=fs.mkdtempSync(path.join(os.tmpdir(),'enana-nodes-test-')),data=path.join(dir,'data'),password=crypto.randomBytes(24).toString('hex');
 const socket=net.createServer();await new Promise(r=>socket.listen(0,'127.0.0.1',r));const host='http://127.0.0.1:'+socket.address().port;await new Promise(r=>socket.close(r));
 const args=['--dir='+data,'--hooksDir='+path.join(REPO,'server/pb_hooks'),'--migrationsDir='+path.join(REPO,'server/pb_migrations'),'--hooksWatch=false'];
 const setup=spawnSync(binary,['superuser','upsert','admin@example.invalid',password,...args],{encoding:'utf8'});assert.equal(setup.status,0,'isolated migration setup');
 const pb=spawn(binary,['serve','--http='+host.slice(7),...args],{stdio:['ignore','ignore','ignore']});
 async function req(route,body,u,method){const headers={'Content-Type':'application/json'};if(u){headers.Authorization=u.token;if(u.session)headers['X-Enana-Session']=u.session.id;headers['X-Enana-Client-Version']=u.client_version||'2.3.8'}
  const r=await fetch(host+route,{method:method||(body?'POST':'GET'),headers,body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(10000)});return {status:r.status,body:r.status===204?null:await r.json()}}
 let i=0,admin;
 async function user(verified=true,pro=false,platform='macos'){
  const email='u'+(++i)+'@example.invalid';const r=await req('/api/collections/users/records',{email,password,passwordConfirm:password});assert.equal(r.status,200);
  if(verified)assert.equal((await req('/api/collections/users/records/'+r.body.id,{verified:true},admin,'PATCH')).status,200);
  const login=await req('/api/enana/v1/auth/login',{email,password,device:{uid:crypto.randomUUID(),platform,name:'Nodes test'}});assert.equal(login.status,200);const u=login.body;
  if(pro){const p=(await req('/api/collections/plans/records?filter=code%3D%22pro%22',null,admin)).body.items[0];const sub=(await req('/api/collections/subscriptions/records?filter='+encodeURIComponent('user="'+u.user.id+'"'),null,admin)).body.items[0];assert.equal((await req('/api/collections/subscriptions/records/'+sub.id,{plan:p.id,status:'active',expires_at:new Date(Date.now()+86400000).toISOString()},admin,'PATCH')).status,200)}
  return u;
 }
 const api='/api/enana/v1/';const share=(u,consent=true,extra={})=>req(api+'servers/share',{key:'a'.repeat(32),consent,revision:'server-sharing-v1',label:'Own proxy',outbound:fixture,...extra},u);
 try{
  for(let n=0;n<150;n++){try{if((await req('/api/health')).status===200)break}catch(_){}await new Promise(r=>setTimeout(r,40))}
  const a=await req('/api/collections/_superusers/auth-with-password',{identity:'admin@example.invalid',password});assert.equal(a.status,200);admin={token:a.body.token};
  assert.equal((await req('/api/settings',{rateLimits:{enabled:false}},admin,'PATCH')).status,200);
  const free=await user(),pro=await user(true,true),windows=await user(true,true,'windows'),unverified=await user(false,true);
  const input=path.join(dir,'private-catalog.json');fs.writeFileSync(input,JSON.stringify({fresh_until:Math.floor(Date.now()/1000)+86400,nodes:[{key:'b'.repeat(32),label:'Official US',outbound:fixture}]}),{mode:0o600});
  const cli=(...a)=>spawnSync(binary,[...a,'--dir='+data,'--hooksDir='+path.join(REPO,'server/admin'),'--migrationsDir='+path.join(REPO,'server/pb_migrations')],{encoding:'utf8'});
  await t.test('admin import is private, free/unverified sessions never receive credentials',async()=>{
   const r=cli('enana-nodes-import',input);assert.equal(r.status,0,r.stderr);assert.ok(!r.stdout.includes(fixture.password));
   assert.equal((await req(api+'nodes')).status,401);
   for(const u of [free,unverified]){const r=await req(api+'nodes',null,u);assert.equal(r.status,200);assert.deepEqual(r.body.nodes,[]);assert.ok(!JSON.stringify(r.body).includes(fixture.password))}
   assert.equal((await req('/api/collections/official_nodes/records',null,pro)).status,403);
   const old={...pro,client_version:'2.3.7'};assert.equal((await req(api+'nodes',null,old)).body.reason,'upgrade_client');assert.deepEqual((await req(api+'nodes',null,old)).body.nodes,[]);assert.equal((await req(api+'plan',null,old)).body.features.official_proxy.enabled,false);assert.equal((await req(api+'plan',null,pro)).body.features.official_proxy.enabled,true);
   for(const u of [pro,windows]){const r=(await req(api+'nodes',null,u)).body;assert.equal(r.nodes.length,1);assert.equal(r.user_id,u.user.id);assert.equal(r.session_id,u.session.id);assert.ok(r.expires_at<=Math.floor(Date.now()/1000)+3600);assert.equal(r.nodes[0].outbound.password,fixture.password);assert.match(r.nodes[0].outbound.tag,/^enana-official-/)}
  });
  await t.test('sharing is opt-in, owned, reviewed and excluded from ordinary backup',async()=>{
   assert.equal((await share(unverified)).body.code,'E_EMAIL_UNVERIFIED');assert.equal((await share(free,true,{revision:'wrong'})).body.code,'E_SHARE_CONSENT');
   assert.equal((await share(free,true,{outbound:{...fixture,ssh_password:'never-upload'}})).body.code,'E_NODE_INVALID');
   assert.equal((await share(free)).body.status,'pending');assert.equal((await req(api+'nodes',null,pro)).body.nodes.length,1);
   const key='shared-'+free.user.id+'-'+'a'.repeat(32);assert.equal(cli('enana-share-review',key,'approve').status,0);
   assert.equal((await req(api+'nodes',null,pro)).body.nodes.length,2);
   assert.equal((await share(free)).body.status,'approved','same credentials keep approval');
   assert.equal((await req(api+'servers/shares',null,windows)).body.shares.length,0);
   assert.ok(!JSON.stringify((await req(api+'servers/shares',null,free)).body).includes(fixture.password));
   assert.equal((await share(free,true,{outbound:{...fixture,password:'changed-fixture'}})).body.status,'pending');assert.equal((await req(api+'nodes',null,pro)).body.nodes.length,1);
   assert.equal(cli('enana-share-review',key,'approve').status,0);assert.equal((await share(free,false)).body.status,'revoked');assert.equal((await req(api+'nodes',null,pro)).body.nodes.length,1);
   const rows=(await req('/api/collections/official_nodes/records?filter='+encodeURIComponent('node_key="'+key+'"'),null,admin)).body.items;assert.equal(rows[0].outbound,null);assert.equal(rows[0].consent,false);
   const events=(await req('/api/collections/server_share_events/records',null,admin)).body.items;assert.ok(events.length>=6);assert.ok(!JSON.stringify(events).includes('private-fixture'));
  });
  await t.test('expired Pro, stale catalogs, disabled owners and revoked device sessions are blocked',async()=>{
   const subs=(await req('/api/collections/subscriptions/records?filter='+encodeURIComponent('user="'+windows.user.id+'"'),null,admin)).body.items;
   await req('/api/collections/subscriptions/records/'+subs[0].id,{expires_at:'2020-01-01 00:00:00Z'},admin,'PATCH');assert.equal((await req(api+'nodes',null,windows)).body.nodes.length,0);
   await share(free);const key='shared-'+free.user.id+'-'+'a'.repeat(32);assert.equal(cli('enana-share-review',key,'approve').status,0);
   await req('/api/collections/users/records/'+free.user.id,{disabled:true},admin,'PATCH');assert.equal((await req(api+'nodes',null,pro)).body.nodes.length,1);
   const official=(await req('/api/collections/official_nodes/records?filter=origin%3D%22official%22',null,admin)).body.items[0];await req('/api/collections/official_nodes/records/'+official.id,{fresh_until:'2020-01-01 00:00:00Z'},admin,'PATCH');assert.equal((await req(api+'nodes',null,pro)).body.nodes.length,0);
   await req(api+'session/logout',{},pro);assert.equal((await req(api+'nodes',null,pro)).status,401);
  });
 }finally{pb.kill('SIGTERM');await new Promise(r=>pb.once('exit',r));fs.rmSync(dir,{recursive:true,force:true})}
});
