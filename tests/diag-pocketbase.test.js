'use strict';
// 诊断上传 (摘要 + 完整诊断): 真实的 PocketBase + SQLite, 不碰生产数据库、不联网。
//   PB_BIN=/path/to/pocketbase node --test tests/diag-pocketbase.test.js
// 覆盖: 权限 (只有登录会话能写、普通用户读不到) · 摘要的形状 / 大小检查 · 限频 · 每台设备的保留条数 · 7 天清理 (完整诊断的文件一并删除)
//       · 账号删除时级联删除 · 完整诊断的 multipart 上传 / 大小 / 次数限制 · nginx 路由脚本。
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path'),net=require('node:net'),crypto=require('node:crypto');
const {spawn,spawnSync}=require('node:child_process');
const REPO=path.resolve(__dirname,'..');
async function port(){const s=net.createServer();await new Promise(r=>s.listen(0,'127.0.0.1',r));const p=s.address().port;await new Promise(r=>s.close(r));return p}
function delay(ms){return new Promise(r=>setTimeout(r,ms))}

test('diagnostic uploads: permissions, limits, retention and cleanup on a real database',{timeout:120000},async t=>{
 const binary=process.env.PB_BIN;if(!binary)throw Error('PB_BIN is required for the real database integration test');
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'enana-diag-test-')),data=path.join(dir,'data'),hooks=path.join(dir,'hooks');
 fs.cpSync(path.join(REPO,'server/pb_hooks'),hooks,{recursive:true});
 // Test-only routes live in this disposable copy of the hooks, never in a release.
 fs.writeFileSync(path.join(hooks,'test_diag.pb.js'),`
  routerAdd("POST","/__test/diag/seed",(e)=>{
   const b=JSON.parse(toString(e.request.body));
   for(let i=0;i<b.n;i++){
    const r=new Record($app.findCachedCollectionByNameOrId("diag_reports"));
    r.set("user",b.user);r.set("device",b.device);r.set("kind",b.kind);r.set("trigger","seed");
    if(b.kind==="full")r.set("bundle",$filesystem.fileFromBytes([1,2,3,i%250],"seed"+i+".gz"));else r.set("payload",{v:1});
    $app.save(r);
    const age=new Date(Date.now()-b.age_days*86400000-i*1000).toISOString().replace("T"," ");
    $app.db().newQuery("UPDATE diag_reports SET created={:c} WHERE id={:id}").bind({c:age,id:r.id}).execute();
   }
   return e.json(200,{ok:true});
  });
  routerAdd("POST","/__test/diag/gc",(e)=>{require(\`\${__hooks}/enana_diag.js\`).gc();return e.json(200,{ok:true})});
  routerAdd("GET","/__test/diag/count",(e)=>{
   const out={};for(const k of ["summary","full"])out[k]=$app.countRecords("diag_reports",$dbx.exp("kind={:k}",{k}));
   return e.json(200,out);
  });
 `);
 const password=crypto.randomBytes(24).toString('hex'),host='http://127.0.0.1:'+await port();
 const args=['--dir='+data,'--hooksDir='+hooks,'--migrationsDir='+path.join(REPO,'server/pb_migrations'),'--hooksWatch=false'];
 const cli=spawnSync(binary,['superuser','upsert','admin@example.invalid',password,...args],{encoding:'utf8'});assert.equal(cli.status,0,'isolated database setup: '+cli.stderr);
 const pb=spawn(binary,['serve','--http='+host.replace('http://',''),...args],{stdio:['ignore','ignore','ignore']});
 async function raw(route,opts={}){const res=await fetch(host+route,{...opts,signal:AbortSignal.timeout(20000)});let body=null;const ct=res.headers.get('content-type')||'';if(res.status!==204)body=ct.includes('json')?await res.json():Buffer.from(await res.arrayBuffer());return {status:res.status,body}}
 const json=(route,body,session,admin,method)=>{const headers={'Content-Type':'application/json'};if(session){headers.Authorization=session.token;headers['X-Enana-Session']=session.session.id}if(admin)headers.Authorization=admin;return raw(route,{method:method||(body?'POST':'GET'),headers,body:body?JSON.stringify(body):undefined})};
 let counter=0;
 async function user(admin,platform='macos'){
  const email='d'+(++counter)+'@example.invalid';
  const r=await json('/api/collections/users/records',{email,password,passwordConfirm:password});assert.equal(r.status,200,'register fixture user');
  const l=await json('/api/enana/v1/auth/login',{email,password,device:{uid:crypto.randomUUID(),platform,name:'Diag test'}});assert.equal(l.status,200,'login fixture user');
  return {...l.body,userId:r.body.id};
 }
 const summary=(over={})=>({v:1,generated:'2026-10-05 03:00:00',meta:{version:'2.3.9',os:'macOS 27.0.1','capture.mode':'system'},verdict:{cause:'pin-empty',blame:'client',confidence:'high'},env:{'pin.servers':'0'},ops:[{ts:'2026-10-05 03:00:00',who:'auto',action:'总开关变更',detail:'key=PROXY_ENABLED from=0 to=1',result:'ok'}],...over});
 try{
  for(let i=0;i<100;i++){try{if((await json('/api/health')).status===200)break}catch(_){}if(i===99)throw Error('test database did not become ready');await delay(50)}
  const adminLogin=await json('/api/collections/_superusers/auth-with-password',{identity:'admin@example.invalid',password});assert.equal(adminLogin.status,200);const admin=adminLogin.body.token;
  await json('/api/settings',{rateLimits:{enabled:false}},null,admin,'PATCH');
  const a=await user(admin),b=await user(admin);
  const list=(filter)=>json('/api/collections/diag_reports/records?perPage=500&sort=-created'+(filter?'&filter='+encodeURIComponent(filter):''),null,null,admin);
  const counts=()=>json('/__test/diag/count');

  await t.test('only a logged-in session can upload; ordinary users cannot read the collection',async()=>{
   const noSession=await json('/api/enana/v1/diag',{trigger:'login',payload:summary()});
   assert.equal(noSession.status,401,'no token / session');
   const tokenOnly=await raw('/api/enana/v1/diag',{method:'POST',headers:{'Content-Type':'application/json',Authorization:a.token},body:JSON.stringify({trigger:'login',payload:summary()})});
   assert.equal(tokenOnly.status,401,'a token without the device session is not enough');
   const ok=await json('/api/enana/v1/diag',{trigger:'login',payload:summary()},a);
   assert.equal(ok.status,200,JSON.stringify(ok.body));assert.ok(ok.body.id);
   const own=await json('/api/collections/diag_reports/records',null,{token:a.token,session:{id:a.session.id}});
   assert.ok([401,403,404].includes(own.status),'users must not read diag_reports through the REST API (got '+own.status+')');
   const rows=(await list()).body.items;assert.equal(rows.length,1);
   assert.equal(rows[0].user,a.userId,'the record belongs to the uploader');
   assert.equal(rows[0].kind,'summary');assert.equal(rows[0].trigger,'login');assert.equal(rows[0].cause,'pin-empty','cause is copied out for filtering');assert.equal(rows[0].app_version,'2.3.9');
   assert.deepEqual(rows[0].payload.env,{'pin.servers':'0'});
  });

  await t.test('payload shape: version, allowed sections, depth, size',async()=>{
   const bad=async(payload,label,codes=[400])=>{const r=await json('/api/enana/v1/diag',{trigger:'login',payload},b);assert.ok(codes.includes(r.status),label+' -> '+r.status+' '+JSON.stringify(r.body))};
   await bad(null,'no payload');await bad([1,2],'array payload');await bad({v:2},'wrong version');
   await bad(summary({access:[{host:'example.org'}]}),'sections that could carry browsing data are rejected (access)');
   await bad(summary({proxy:'raw core log'}),'raw core log is rejected');
   await bad(summary({env:{a:{b:{c:{d:{e:{f:{g:1}}}}}}}}),'too deeply nested');
   await bad(summary({ops:new Array(601).fill('x')}),'too many items');
   await bad(summary({meta:{k:'x'.repeat(2001)}}),'a string that is too long');
   await bad(summary({ops:new Array(200).fill('x'.repeat(1000))}),'larger than the summary limit',[400,413]);
   assert.equal((await counts()).body.summary,1,'rejected uploads stored nothing (only the first test row exists)');
  });

  await t.test('rate limits: gap between event summaries, login summaries exempt, daily cap',async()=>{
   const first=await json('/api/enana/v1/diag',{trigger:'event:sysproxy',payload:summary()},b);assert.equal(first.status,200,JSON.stringify(first.body));
   const second=await json('/api/enana/v1/diag',{trigger:'event:sysproxy',payload:summary()},b);assert.equal(second.status,429);assert.equal(second.body.code,'rate_limited');
   const login=await json('/api/enana/v1/diag',{trigger:'login',payload:summary()},b);assert.equal(login.status,200,'login/register summaries are not gap-limited');
   // 每台设备每天最多 60 份: 已经传了 2 份, 再传 58 份 login 触发的到上限, 第 61 份被拒
   for(let i=0;i<58;i++){const r=await json('/api/enana/v1/diag',{trigger:'login',payload:summary()},b);assert.equal(r.status,200,'upload '+i)}
   const over=await json('/api/enana/v1/diag',{trigger:'login',payload:summary()},b);assert.equal(over.status,429,'daily cap');
   const other=await json('/api/enana/v1/diag',{trigger:'login',payload:summary()},a);assert.equal(other.status,200,'another device is not affected');
  });

  await t.test('retention: newest 200 summaries per device are kept',async()=>{
   const c=await user(admin);const dev=(await list(`user="${c.userId}"`)).body.items;assert.equal(dev.length,0);
   const device=(await json('/api/collections/devices/records?filter='+encodeURIComponent(`user="${c.userId}"`),null,null,admin)).body.items[0].id;
   await json('/__test/diag/seed',{user:c.userId,device,kind:'summary',n:205,age_days:1});
   const r=await json('/api/enana/v1/diag',{trigger:'login',payload:summary()},c);assert.equal(r.status,200);
   const rows=(await list(`user="${c.userId}"`)).body.items;assert.equal(rows.length,200,'205 seeded + 1 new, pruned to 200');
   assert.ok(rows.some(x=>x.id===r.body.id),'the newest upload is kept');
  });

  await t.test('full diagnostics: multipart upload, file stored, size and count limits',async()=>{
   const d=await user(admin);
   const gz=zlib=>zlib.gzipSync(Buffer.from('@@SECTION proxy format=raw rows=1\nfake full bundle\n'));
   const bundle=gz(require('node:zlib'));
   const send=async(files,fields={app:'2.3.9'})=>{const f=new FormData();for(const [k,v] of Object.entries(fields))f.append(k,v);for(const file of files)f.append('bundle',new Blob([file],{type:'application/gzip'}),'diag.gz');return raw('/api/enana/v1/diag/full',{method:'POST',headers:{Authorization:d.token,'X-Enana-Session':d.session.id},body:f})};
   const noAuth=await raw('/api/enana/v1/diag/full',{method:'POST',body:new FormData()});assert.equal(noAuth.status,401);
   assert.equal((await send([])).status,400,'no bundle');
   assert.equal((await send([bundle,bundle])).status,400,'more than one file');
   const ok=await send([bundle]);assert.equal(ok.status,200,JSON.stringify(ok.body));assert.ok(ok.body.id,'the id is the report code the user sends to the developer');
   const rec=(await json('/api/collections/diag_reports/records/'+ok.body.id,null,null,admin)).body;
   assert.equal(rec.kind,'full');assert.equal(rec.trigger,'manual');assert.equal(rec.app_version,'2.3.9');assert.ok(rec.bundle,'a file was stored');
   const dl=await raw('/api/files/diag_reports/'+rec.id+'/'+rec.bundle,{headers:{Authorization:admin}});
   assert.equal(dl.status,200);assert.ok(Buffer.compare(dl.body,bundle)===0,'the stored file is byte-identical');
   const big=await send([crypto.randomBytes(8*1024*1024+1024)]);assert.ok([400,413].includes(big.status),'8 MB+ is refused ('+big.status+')');
   assert.equal((await send([bundle])).status,200);assert.equal((await send([bundle])).status,200);
   assert.equal((await send([bundle])).status,429,'the 4th full diagnostic of the day is refused (limit 3)');
  });

  await t.test('daily cleanup removes reports older than 7 days (and the files of full ones)',async()=>{
   const e2=await user(admin);const device=(await json('/api/collections/devices/records?filter='+encodeURIComponent(`user="${e2.userId}"`),null,null,admin)).body.items[0].id;
   const before=(await counts()).body;
   await json('/__test/diag/seed',{user:e2.userId,device,kind:'summary',n:3,age_days:9});
   await json('/__test/diag/seed',{user:e2.userId,device,kind:'full',n:2,age_days:9});
   await json('/__test/diag/seed',{user:e2.userId,device,kind:'full',n:1,age_days:1});
   const old=(await list(`user="${e2.userId}" && kind="full"`)).body.items;assert.equal(old.length,3);
   const storage=path.join(data,'storage');const filesBefore=fs.existsSync(storage)?fs.readdirSync(storage,{recursive:true}).filter(f=>/seed\d+/.test(f)&&!f.endsWith('.attrs')).length:0;      // PocketBase 为每个文件另写一个 .attrs 旁文件, 不算
   assert.ok(filesBefore>=3,'seeded full reports have files on disk');
   assert.equal((await json('/__test/diag/gc',{})).status,200);
   const after=(await list(`user="${e2.userId}"`)).body.items;
   assert.equal(after.filter(x=>x.kind==='summary').length,0,'old summaries are gone');
   assert.equal(after.filter(x=>x.kind==='full').length,1,'only the recent full report remains');
   const filesAfter=fs.readdirSync(storage,{recursive:true}).filter(f=>/seed\d+/.test(f)&&!f.endsWith('.attrs')).length;
   assert.equal(filesAfter,filesBefore-2,'files of the deleted full reports were removed from disk');
   assert.equal((await counts()).body.summary>=before.summary,true);
  });

  await t.test('full reports are limited to the newest 5 per device',async()=>{
   const f=await user(admin);const device=(await json('/api/collections/devices/records?filter='+encodeURIComponent(`user="${f.userId}"`),null,null,admin)).body.items[0].id;
   await json('/__test/diag/seed',{user:f.userId,device,kind:'full',n:6,age_days:1});
   const form=new FormData();form.append('app','2.3.9');form.append('bundle',new Blob([require('node:zlib').gzipSync('x')],{type:'application/gzip'}),'d.gz');
   const r=await raw('/api/enana/v1/diag/full',{method:'POST',headers:{Authorization:f.token,'X-Enana-Session':f.session.id},body:form});assert.equal(r.status,200,JSON.stringify(r.body));
   assert.equal((await list(`user="${f.userId}" && kind="full"`)).body.items.length,5,'6 seeded + 1 new, pruned to 5');
  });

  await t.test('a user can delete everything they uploaded, and only theirs',async()=>{
   const m=await user(admin),n=await user(admin);
   for(let i=0;i<3;i++)assert.equal((await json('/api/enana/v1/diag',{trigger:'login',payload:summary()},m)).status,200);
   assert.equal((await json('/api/enana/v1/diag',{trigger:'login',payload:summary()},n)).status,200);
   const form=new FormData();form.append('bundle',new Blob([require('node:zlib').gzipSync('x')],{type:'application/gzip'}),'d.gz');
   assert.equal((await raw('/api/enana/v1/diag/full',{method:'POST',headers:{Authorization:m.token,'X-Enana-Session':m.session.id},body:form})).status,200);
   assert.equal((await json('/api/enana/v1/diag',null,null,null,'DELETE')).status,401,'needs a session');
   const del=await json('/api/enana/v1/diag',null,m,null,'DELETE');assert.equal(del.status,200,JSON.stringify(del.body));assert.equal(del.body.deleted,4,'3 summaries + 1 full');
   assert.equal((await list(`user="${m.userId}"`)).body.items.length,0,'everything of the caller is gone');
   assert.equal((await list(`user="${n.userId}"`)).body.items.length,1,'other users are untouched');
   const again=await json('/api/enana/v1/diag',null,m,null,'DELETE');assert.equal(again.body.deleted,0,'idempotent');
  });

  await t.test('deleting the account deletes its diagnostics (cascade)',async()=>{
   const g=await user(admin);
   assert.equal((await json('/api/enana/v1/diag',{trigger:'login',payload:summary()},g)).status,200);
   assert.equal((await list(`user="${g.userId}"`)).body.items.length,1);
   const del=await raw('/api/collections/users/records/'+g.userId,{method:'DELETE',headers:{Authorization:admin}});assert.equal(del.status,204);
   assert.equal((await list(`user="${g.userId}"`)).body.items.length,0,'the account is gone, so are its reports');
  });
 }finally{pb.kill('SIGTERM');await new Promise(r=>pb.once('exit',r));fs.rmSync(dir,{recursive:true,force:true})}
});

test('update-nginx-diag.py adds exactly two exact-path routes and refuses to run twice',()=>{
 const script=path.join(REPO,'server/update-nginx-diag.py'),dir=fs.mkdtempSync(path.join(os.tmpdir(),'enana-nginx-test-'));
 try{
  const conf='server {\n    location = /x { return 204; }\n    # 同步快照: 内容是密文\n    location = /api/enana/v1/sync/snapshot { client_max_body_size 1500k; }\n}\n';
  const src=path.join(dir,'in.conf'),out=path.join(dir,'out.conf');fs.writeFileSync(src,conf);
  const run=(a,b)=>spawnSync('python3',[script,a,b],{encoding:'utf8'});
  assert.equal(run(src,out).status,0);
  const text=fs.readFileSync(out,'utf8');
  assert.equal((text.match(/location = \/api\/enana\/v1\/diag \{/g)||[]).length,1);assert.equal((text.match(/location = \/api\/enana\/v1\/diag\/full \{/g)||[]).length,1);
  assert.match(text,/location = \/api\/enana\/v1\/diag \{[\s\S]*?client_max_body_size 128k;/);assert.match(text,/location = \/api\/enana\/v1\/diag\/full \{[\s\S]*?client_max_body_size 9m;/);
  assert.match(text,/limit_except POST DELETE \{ deny all; \}/,'only POST (upload) and DELETE (remove my uploads) are allowed on /diag');
  assert.match(text,/location = \/api\/enana\/v1\/diag\/full \{\s*limit_except POST \{ deny all; \}/,'the full-upload route is POST only');
  assert.ok(text.indexOf('/api/enana/v1/diag {')<text.indexOf('# 同步快照'),'inserted before the sync section');
  assert.ok(text.includes('location = /api/enana/v1/sync/snapshot { client_max_body_size 1500k; }'),'existing routes are untouched');
  const again=run(out,path.join(dir,'out2.conf'));assert.notEqual(again.status,0,'running twice is refused');assert.match(again.stderr,/already installed/);
  fs.writeFileSync(src,'server { }\n');assert.notEqual(run(src,out).status,0,'unexpected config (no anchor) is refused');
 }finally{fs.rmSync(dir,{recursive:true,force:true})}
});
