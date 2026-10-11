'use strict';
// 偏好设置与配置快照的云端规则: 真实的 PocketBase + SQLite, 不碰生产数据库、不联网。
//   PB_BIN=/path/to/pocketbase node --test tests/prefs-pocketbase.test.js
// 覆盖: 需要登录会话 · 每个账号一份、互不可见 · 改动时间新的获胜 (旧的得 409) · 形状 / 大小检查 · 清除快照后版本号接着往上走。
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path'),net=require('node:net'),crypto=require('node:crypto');
const {spawn,spawnSync}=require('node:child_process');
const REPO=path.resolve(__dirname,'..');
async function port(){const s=net.createServer();await new Promise(r=>s.listen(0,'127.0.0.1',r));const p=s.address().port;await new Promise(r=>s.close(r));return p}
function delay(ms){return new Promise(r=>setTimeout(r,ms))}

test('preferences and the cloud snapshot on a real database',{timeout:120000},async t=>{
 const binary=process.env.PB_BIN;if(!binary)throw Error('PB_BIN is required for the real database integration test');
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'enana-prefs-test-')),data=path.join(dir,'data'),hooks=path.join(dir,'hooks');
 fs.cpSync(path.join(REPO,'server/pb_hooks'),hooks,{recursive:true});
 const password=crypto.randomBytes(24).toString('hex'),host='http://127.0.0.1:'+await port();
 const args=['--dir='+data,'--hooksDir='+hooks,'--migrationsDir='+path.join(REPO,'server/pb_migrations'),'--hooksWatch=false'];
 const cli=spawnSync(binary,['superuser','upsert','admin@example.invalid',password,...args],{encoding:'utf8'});assert.equal(cli.status,0,'isolated database setup: '+cli.stderr);
 const pb=spawn(binary,['serve','--http='+host.replace('http://',''),...args],{stdio:['ignore','ignore','ignore']});
 async function call(route,{method='GET',body,session,token,admin}={}){
  const headers={};
  if(body!==undefined)headers['Content-Type']='application/json';
  if(session){headers.Authorization=session.token;headers['X-Enana-Session']=session.session.id}
  if(token)headers.Authorization=token;
  if(admin)headers.Authorization=admin;
  const res=await fetch(host+route,{method,headers,body:body===undefined?undefined:(typeof body==='string'?body:JSON.stringify(body)),signal:AbortSignal.timeout(20000)});
  const text=await res.text();let json=null;try{json=JSON.parse(text)}catch(_){}
  return {status:res.status,body:json};
 }
 let counter=0;
 async function user(){
  const email='p'+(++counter)+'@example.invalid';
  const r=await call('/api/collections/users/records',{method:'POST',body:{email,password,passwordConfirm:password}});assert.equal(r.status,200,'register fixture user');
  const l=await call('/api/enana/v1/auth/login',{method:'POST',body:{email,password,device:{uid:crypto.randomUUID(),platform:'macos',name:'Prefs test'}}});assert.equal(l.status,200,'login fixture user');
  return {...l.body,userId:r.body.id};
 }
 const prefs=(stamp,body)=>({stamp,prefs:body});
 try{
  for(let i=0;i<100;i++){try{if((await call('/api/health')).status===200)break}catch(_){}if(i===99)throw Error('test database did not become ready');await delay(50)}
  const adminLogin=await call('/api/collections/_superusers/auth-with-password',{method:'POST',body:{identity:'admin@example.invalid',password}});assert.equal(adminLogin.status,200);
  await call('/api/settings',{method:'PATCH',body:{rateLimits:{enabled:false}},admin:adminLogin.body.token});
  const a=await user(),b=await user();

  await t.test('preferences need a logged-in session',async()=>{
   assert.equal((await call('/api/enana/v1/prefs')).status,401,'no token');
   assert.equal((await call('/api/enana/v1/prefs',{token:a.token})).status,401,'a token without the device session is not enough');
   const c=await user();
   assert.equal((await call('/api/enana/v1/prefs',{method:'PUT',session:c,body:prefs(100,{})})).status,200,'a session can write');
  });

  await t.test('one copy per account: a new account has none, and the other account cannot read it',async()=>{
   const fresh=await user();
   assert.deepEqual((await call('/api/enana/v1/prefs',{session:fresh})).body,{exists:false});
   const w=await call('/api/enana/v1/prefs',{method:'PUT',session:a,body:prefs(100,{'ui.theme':'dark'})});
   assert.equal(w.status,200);assert.deepEqual(w.body,{version:1,stamp:100});
   const r=await call('/api/enana/v1/prefs',{session:a});
   assert.deepEqual(r.body,{exists:true,version:1,stamp:100,prefs:{'ui.theme':'dark'}});
   assert.deepEqual((await call('/api/enana/v1/prefs',{session:b})).body,{exists:false},'account b must not see account a');
  });

  await t.test('the newer change wins: a stale write is refused, and a newer one is accepted',async()=>{
   const stale=await call('/api/enana/v1/prefs',{method:'PUT',session:a,body:prefs(90,{'ui.theme':'old'})});
   assert.equal(stale.status,409);assert.deepEqual(stale.body,{code:'stale',version:1,stamp:100});
   const newer=await call('/api/enana/v1/prefs',{method:'PUT',session:a,body:prefs(150,{'ui.theme':'light'})});
   assert.equal(newer.status,200);assert.deepEqual(newer.body,{version:2,stamp:150});
   assert.deepEqual((await call('/api/enana/v1/prefs',{session:a})).body.prefs,{'ui.theme':'light'});
  });

  await t.test('shape and size limits',async()=>{
   assert.equal((await call('/api/enana/v1/prefs',{method:'PUT',session:a,body:prefs(200,[1,2])})).status,400,'an array is not a preferences object');
   assert.equal((await call('/api/enana/v1/prefs',{method:'PUT',session:a,body:prefs(-1,{})})).status,400,'a negative stamp');
   const big=await call('/api/enana/v1/prefs',{method:'PUT',session:a,body:prefs(200,{big:'x'.repeat(17000)})});
   assert.equal(big.status,400);assert.equal(big.body.code,'too_large');
  });

  await t.test('clearing the cloud snapshot keeps its version counting up (no restart at 1)',async()=>{
   const put=(base,payload,size)=>call('/api/enana/v1/sync/snapshot',{method:'PUT',session:a,body:{base_version:base,payload,size}});
   assert.deepEqual((await put(0,'QUFB',3)).body,{version:1});
   assert.equal((await call('/api/enana/v1/sync/snapshot',{session:a})).body.version,1);
   assert.deepEqual((await call('/api/enana/v1/sync/snapshot',{method:'DELETE',session:a})).body,{ok:true});
   assert.deepEqual((await call('/api/enana/v1/sync/snapshot',{session:a})).body,{exists:false});
   assert.deepEqual((await put(0,'Q0M=',2)).body,{version:2},'after a clear, a push from base 0 continues the count');
   const stale=await put(1,'WFg=',2);
   assert.equal(stale.status,409);assert.deepEqual(stale.body,{code:'conflict',version:2},'a device still on the old version is refused');
  });
 }finally{
  pb.kill();
  fs.rmSync(dir,{recursive:true,force:true});
 }
});
