'use strict';
// 「我的设备」与会话心跳: 真实的 PocketBase + SQLite, 不碰生产数据库、不联网。
//   PB_BIN=/path/to/pocketbase node --test tests/devices-pocketbase.test.js
// 覆盖: 设备列表只列出还登录着的设备 —— 在「我的设备」里被下线 / 登录时被挤下线 / 退出登录 / 会话过期 / 重新激活时超限 / 改密码后被撤销的都不再出现,
//       离线 (没有最近的心跳) 但仍登录的照样列出 (online=false), 当前设备总在, 同一设备重新登录后只出现一次
//       · 下线之后那台设备马上消失; 再下线一次是幂等的 ok (revoked=0), 不重复记审计; 不能下线自己
//       · 心跳带上 app (enana 版本) / os (系统版本) 时更新设备记录, 只接受合法值; 老客户端 ({} / 没有正文 / 不是 JSON) 照常成功; 被撤销的会话写不进去
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path'),net=require('node:net'),crypto=require('node:crypto');
const {spawn,spawnSync}=require('node:child_process');
const REPO=path.resolve(__dirname,'..');
async function port(){const s=net.createServer();await new Promise(r=>s.listen(0,'127.0.0.1',r));const p=s.address().port;await new Promise(r=>s.close(r));return p}
function delay(ms){return new Promise(r=>setTimeout(r,ms))}

test('my devices and the session heartbeat on a real database',{timeout:120000},async t=>{
 const binary=process.env.PB_BIN;if(!binary)throw Error('PB_BIN is required for the real database integration test');
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'enana-devices-test-')),data=path.join(dir,'data'),hooks=path.join(dir,'hooks');
 fs.cpSync(path.join(REPO,'server/pb_hooks'),hooks,{recursive:true});
 // Test-only route in this disposable copy of the hooks, never in a release: move one session's clock back
 // (expires_at -> an expired session that nothing has marked yet; last_heartbeat_at -> a device that has been offline for a while).
 fs.writeFileSync(path.join(hooks,'test_devices.pb.js'),`
  routerAdd("POST","/__test/devices/age",(e)=>{
   const b=JSON.parse(toString(e.request.body));
   const col={expires_at:"expires_at",last_heartbeat_at:"last_heartbeat_at"}[b.field];
   if(!col)return e.json(400,{code:"bad_field"});
   const at=new Date(Date.now()-b.ago*1000).toISOString().replace("T"," ");
   $app.db().newQuery("UPDATE device_sessions SET "+col+"={:at} WHERE id={:id}").bind({at:at,id:b.session}).execute();
   return e.json(200,{ok:true});
  });
 `);
 const password=crypto.randomBytes(24).toString('hex'),host='http://127.0.0.1:'+await port();
 const args=['--dir='+data,'--hooksDir='+hooks,'--migrationsDir='+path.join(REPO,'server/pb_migrations'),'--hooksWatch=false'];
 const cli=spawnSync(binary,['superuser','upsert','admin@example.invalid',password,...args],{encoding:'utf8'});assert.equal(cli.status,0,'isolated database setup: '+cli.stderr);
 const pb=spawn(binary,['serve','--http='+host.replace('http://',''),...args],{stdio:['ignore','ignore','ignore']});
 async function call(route,{method='GET',body,session,admin}={}){
  const headers={};
  if(body!==undefined)headers['Content-Type']='application/json';
  if(session){headers.Authorization=session.token;headers['X-Enana-Session']=session.session.id}
  if(admin)headers.Authorization=admin;
  const res=await fetch(host+route,{method,headers,body:body===undefined?undefined:(typeof body==='string'?body:JSON.stringify(body)),signal:AbortSignal.timeout(20000)});
  const text=await res.text();let json=null;try{json=JSON.parse(text)}catch(_){}
  return {status:res.status,body:json};
 }
 const email='devices@example.invalid',ids={};
 async function login(name,platform='macos',kick){
  ids[name]=ids[name]||crypto.randomUUID();
  const body={email,password,device:{uid:ids[name],platform,name:'Test '+name,os:'14.5',arch:'arm64',app:'2.3.23'}};
  if(kick)body.kick_device_uid=ids[kick];
  const r=await call('/api/enana/v1/auth/login',{method:'POST',body});assert.equal(r.status,200,'login '+name+': '+JSON.stringify(r.body));
  return r.body;
 }
 const name=uid=>Object.keys(ids).find(k=>ids[k]===uid)||uid;
 async function list(s){
  const r=await call('/api/enana/v1/devices',{session:s});assert.equal(r.status,200,JSON.stringify(r.body));
  return {...r.body,names:r.body.devices.map(x=>name(x.uid)).sort(),by:Object.fromEntries(r.body.devices.map(x=>[name(x.uid),x]))};
 }
 const age=(s,field,ago)=>call('/__test/devices/age',{method:'POST',body:{session:s.session.id,field,ago}});
 const hb=(s,body)=>call('/api/enana/v1/session/heartbeat',{method:'POST',session:s,body});
 const kick=(s,who)=>call('/api/enana/v1/devices/kick',{method:'POST',session:s,body:{device_uid:ids[who]||who}});
 try{
  for(let i=0;i<100;i++){try{if((await call('/api/health')).status===200)break}catch(_){}if(i===99)throw Error('test database did not become ready');await delay(50)}
  const adminLogin=await call('/api/collections/_superusers/auth-with-password',{method:'POST',body:{identity:'admin@example.invalid',password}});assert.equal(adminLogin.status,200);
  const admin=adminLogin.body.token;
  await call('/api/settings',{method:'PATCH',body:{rateLimits:{enabled:false}},admin});
  assert.equal((await call('/api/collections/users/records',{method:'POST',body:{email,password,passwordConfirm:password}})).status,200,'register fixture user');
  const kicks=async()=>(await call('/api/collections/audit_events/records?perPage=200&filter='+encodeURIComponent('type="kick"'),{admin})).body.items.length;
  const A=await login('A'),B=await login('B');
  let E=null;                                       // set below: the device that went offline while still signed in

  await t.test('the list has the expected shape; the current device is marked',async()=>{
   const l=await list(A);
   assert.equal(l.limit,2);assert.equal(l.platform,'macos');assert.deepEqual(l.names,['A','B']);
   assert.deepEqual(Object.keys(l.by.A).sort(),['app','arch','current','ip_hint','last_seen','name','online','os','platform','uid']);
   assert.equal(l.by.A.current,true);assert.equal(l.by.B.current,false);
   assert.equal(l.by.A.online,true);assert.equal(l.by.B.online,true);
   assert.equal(l.devices.filter(x=>x.current).length,1);
  });

  await t.test('a device signed out from "My devices" disappears; signing it out again is a no-op without a second audit event; a device cannot sign itself out',async()=>{
   const r=await kick(A,'B');assert.equal(r.status,200);assert.deepEqual(r.body,{ok:true,revoked:1});
   assert.deepEqual((await list(A)).names,['A'],'the kicked device is gone right away');
   assert.equal(await kicks(),1);
   const again=await kick(A,'B');assert.equal(again.status,200);assert.deepEqual(again.body,{ok:true,revoked:0},'idempotent');
   assert.equal(await kicks(),1,'no second kick audit event for a device that had nothing left to revoke');
   const self=await kick(A,'A');assert.equal(self.status,400);assert.equal(self.body.code,'cannot_kick_self');
   assert.deepEqual((await list(A)).names,['A'],'the current device is always listed');
   const old=await hb(B,{app:'9.9.9',os:'99'});assert.equal(old.status,401);assert.equal(old.body.reason,'kicked','a revoked session cannot report anything');
  });

  await t.test('logged out and expired devices disappear; an offline device that is still signed in stays, marked offline',async()=>{
   const C=await login('C');assert.deepEqual((await list(A)).names,['A','C']);
   assert.equal((await call('/api/enana/v1/session/logout',{method:'POST',session:C,body:{}})).status,200);
   assert.deepEqual((await list(A)).names,['A'],'logged out');
   const D=await login('D');assert.deepEqual((await list(A)).names,['A','D']);
   assert.equal((await age(D,'expires_at',60)).status,200);
   assert.deepEqual((await list(A)).names,['A'],'expired (not yet marked by anything)');
   E=await login('E');assert.equal((await age(E,'last_heartbeat_at',900)).status,200);
   await login('F','windows');
   const l=await list(A);
   assert.deepEqual(l.names,['A','E','F']);
   assert.equal(l.by.E.online,false,'15 minutes without a heartbeat: offline, still signed in');
   assert.equal(l.by.F.online,true);assert.equal(l.by.F.platform,'windows');assert.equal(l.by.A.online,true);
  });

  await t.test('a device pushed out at sign-in disappears; a device that signs in again is listed once',async()=>{
   await login('G');assert.deepEqual((await list(A)).names,['A','E','F','G']);
   await login('H','macos','G');
   assert.deepEqual((await list(A)).names,['A','E','F','H'],'G was signed out by H at sign-in');
   await login('B','macos','H');
   const l=await list(A);
   assert.deepEqual(l.names,['A','B','E','F'],'B is back (once, with its new session); H is gone');
   assert.equal(l.devices.filter(x=>x.uid===ids.B).length,1);
   // E comes back after a long sleep while macOS already has 2 devices online: its session is revoked (limit) and it leaves the list
   const e=await hb(E,{app:'2.3.26'});assert.equal(e.status,401);assert.equal(e.body.reason,'limit');
   assert.deepEqual((await list(A)).names,['A','B','F']);
  });

  await t.test('the heartbeat keeps the version and the OS of the device record current, and accepts only valid values',async()=>{
   const me=async()=>(await list(A)).by.A;
   assert.equal((await me()).app,'2.3.23','written at sign-in');
   const ok=await hb(A,{app:'2.3.26',os:'15.6.1'});
   assert.equal(ok.status,200);assert.equal(ok.body.ok,true);assert.equal(typeof ok.body.token,'string');assert.ok(ok.body.expires_at>0);
   let d=await me();assert.equal(d.app,'2.3.26');assert.equal(d.os,'15.6.1');
   for(const app of ['2.3','2.3.26 ',' 2.3.26','v2.3.26','2.3.26\n','2.3.26-'+'x'.repeat(21),'1234567890.1234567890.1234567890.1','2.3.26-beta_1','2.3.26+build','<b>2.3.27</b>','',2327,null,['2.3.27'],{v:'2.3.27'}]){
    const r=await hb(A,{app});assert.equal(r.status,200,'an invalid app value never fails the heartbeat: '+JSON.stringify(app));
    assert.equal((await me()).app,'2.3.26','ignored: '+JSON.stringify(app));
   }
   for(const o of ['',' 15.7','15.7 ','15.7\n','15\t7','15‮7','15\u00857','x'.repeat(65),15.7,true,{v:'15.7'}]){
    const r=await hb(A,{os:o});assert.equal(r.status,200,'an invalid os value never fails the heartbeat: '+JSON.stringify(o));
    assert.equal((await me()).os,'15.6.1','ignored: '+JSON.stringify(o));
   }
   assert.equal((await hb(A,{app:'2.3.27-beta.1',os:'Windows 11 专业版 24H2'})).status,200);
   d=await me();assert.equal(d.app,'2.3.27-beta.1','a pre-release suffix is fine');assert.equal(d.os,'Windows 11 专业版 24H2','printable non-ASCII is fine');
   assert.equal((await hb(A,{os:'y'.repeat(64)})).status,200);assert.equal((await me()).os,'y'.repeat(64),'64 characters is the limit');
   // old clients: {} / no body / a body that is not JSON
   for(const body of [{},undefined,'not json','[]']){
    const r=await hb(A,body);assert.equal(r.status,200,'old client body '+JSON.stringify(body));assert.equal(r.body.ok,true);
   }
   d=await me();assert.equal(d.app,'2.3.27-beta.1');assert.equal(d.os,'y'.repeat(64),'nothing changes without the fields');
   // the other devices are untouched
   assert.equal((await list(A)).by.B.app,'2.3.23');
  });

  await t.test('devices signed out by a password change disappear',async()=>{
   const np=crypto.randomBytes(16).toString('hex');
   const r=await call('/api/enana/v1/account/password',{method:'POST',session:A,body:{old_password:password,new_password:np}});
   assert.equal(r.status,200,JSON.stringify(r.body));
   const A2={...A,token:r.body.token};
   const l=await list(A2);
   assert.deepEqual(l.names,['A']);assert.equal(l.by.A.current,true);
  });
 }finally{
  pb.kill();
  fs.rmSync(dir,{recursive:true,force:true});
 }
});
