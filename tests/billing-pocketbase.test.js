'use strict';
// Actual PocketBase + SQLite, no production database or network dependency.
// PB_BIN=/path/to/pocketbase node --test tests/billing-pocketbase.test.js
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path'),net=require('node:net'),crypto=require('node:crypto');
const {spawn,spawnSync}=require('node:child_process'),{encodeAddress}=require('../server/payments/tron.js');
const REPO=path.resolve(__dirname,'..');
async function port(){const s=net.createServer();await new Promise(r=>s.listen(0,'127.0.0.1',r));const p=s.address().port;await new Promise(r=>s.close(r));return p}
function delay(ms){return new Promise(r=>setTimeout(r,ms))}
test('transactional billing, email verification and entitlement integration',{timeout:90000},async t=>{
 const binary=process.env.PB_BIN;if(!binary)throw Error('PB_BIN is required for the real database integration test');
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'enana-billing-test-')),data=path.join(dir,'data'),configFile=path.join(dir,'billing.json'),hooks=path.join(dir,'hooks');
 fs.cpSync(path.join(REPO,'server/pb_hooks'),hooks,{recursive:true});
 // Exercise the actual cron function without waiting for a clock boundary.
 // This hook exists only in this disposable test directory, never in a release.
 fs.writeFileSync(path.join(hooks,'test_renew.pb.js'),'routerAdd("POST","/__test/renew",(e)=>{require(`${__hooks}/enana_billing.js`).renewAll();return e.json(200,{ok:true})});');
 fs.appendFileSync(path.join(hooks,'test_renew.pb.js'),'routerAdd("POST","/__test/backdate",(e)=>{const b=JSON.parse(toString(e.request.body));$app.db().newQuery("UPDATE billing_orders SET created={:created} WHERE id={:id}").bind(b).execute();return e.json(200,{ok:true})});');
 const address=encodeAddress('11'.repeat(20)),secret=crypto.randomBytes(32).toString('hex'),password=crypto.randomBytes(24).toString('hex'),host='http://127.0.0.1:'+await port();
 const cfg={payments_enabled:true,addresses:[address],provider_key:'test-fixture-only',scanner_secret:secret};fs.writeFileSync(configFile,JSON.stringify(cfg),{mode:0o600});
 const args=['--dir='+data,'--hooksDir='+hooks,'--migrationsDir='+path.join(REPO,'server/pb_migrations'),'--hooksWatch=false'];
 const env={...process.env,ENANA_BILLING_CONFIG:configFile};
 const cli=spawnSync(binary,['superuser','upsert','admin@example.invalid',password,...args],{env,encoding:'utf8'});assert.equal(cli.status,0,'isolated database setup');
 const pb=spawn(binary,['serve','--http='+host.replace('http://',''),...args],{env,stdio:['ignore','ignore','ignore']});
 let smtp,messages=[];
 async function req(route,body,session,admin){const headers={'Content-Type':'application/json'};if(session){headers.Authorization=session.token;headers['X-Enana-Session']=session.session.id}if(admin)headers.Authorization=admin;const res=await fetch(host+route,{method:body?'POST':'GET',headers,body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(10000)});return {status:res.status,body:res.status===204?null:await res.json()}}
 async function patch(route,body,admin){const res=await fetch(host+route,{method:'PATCH',headers:{Authorization:admin,'Content-Type':'application/json'},body:JSON.stringify(body)});const doc=await res.json();assert.equal(res.status,200,'admin fixture update: '+route);return doc}
 async function internal(route,body){const res=await fetch(host+'/api/enana/internal/billing/'+route,{method:body?'POST':'GET',headers:{'Content-Type':'application/json','X-Enana-Payments':secret},body:body?JSON.stringify(body):undefined});return {status:res.status,body:await res.json()}}
 let counter=0;const requestKey=()=>crypto.randomUUID();
 async function user(admin,verified=true,platform='macos'){
  const email='u'+(++counter)+'@example.invalid',r=await req('/api/collections/users/records',{email,password,passwordConfirm:password});assert.equal(r.status,200,'register fixture user');
  if(verified)await patch('/api/collections/users/records/'+r.body.id,{verified:true},admin);
  const l=await req('/api/enana/v1/auth/login',{email,password,device:{uid:crypto.randomUUID(),platform,name:'Billing test'}});assert.equal(l.status,200,'login fixture user');return {...l.body,email};
 }
 const quote=(u,kind='plan',value='m1',key=requestKey())=>req('/api/enana/v1/billing/checkout',{kind,...(kind==='plan'?{sku:value}:{amount:value}),request_key:key},u);
 const event=(o,n=0,at=Math.floor(Date.now()/1000))=>({event_key:crypto.randomBytes(32).toString('hex')+':'+n,address:o.address,amount:Math.round(Number(o.amount)*1e6),chain_at:at});
 try {
  for(let i=0;i<100;i++){try{if((await req('/api/health')).status===200)break}catch(_){}if(i===99)throw Error('test database did not become ready');await delay(50)}
  const adminLogin=await req('/api/collections/_superusers/auth-with-password',{identity:'admin@example.invalid',password});assert.equal(adminLogin.status,200);const admin=adminLogin.body.token;
  // Test load/concurrency should not trip generic production IP throttles.
  await patch('/api/settings',{rateLimits:{enabled:false}},admin);
  const u=await user(admin),w=await user(admin,true,'windows'),unverified=await user(admin,false);
  await t.test('email, session, collection and provider-health gates',async()=>{
   assert.equal((await quote(unverified)).body.code,'E_EMAIL_UNVERIFIED');assert.equal((await quote(u)).body.code,'E_PAYMENTS_UNAVAILABLE');
   assert.equal((await req('/api/enana/v1/billing')).status,401);
   assert.equal((await req('/api/collections/billing_wallets/records',null,u)).status,403);
   const spoof=await fetch(host+'/api/enana/internal/billing/health',{method:'POST',headers:{'Content-Type':'application/json','X-Real-IP':'127.0.0.1'},body:'{"healthy":true}'});assert.equal(spoof.status,404);
   assert.equal((await internal('health',{healthy:true})).status,200);
  });
  await t.test('concurrent quote is idempotent, owned, uniquely reserved and uses catalog prices',async()=>{
   const k=requestKey(),rs=await Promise.all([quote(u,'plan','m1',k),quote(u,'plan','m1',k)]);rs.forEach(r=>assert.equal(r.status,200));assert.equal(rs[0].body.order.id,rs[1].body.order.id);
   assert.equal((await quote(u,'plan','m3',k)).body.code,'E_REQUEST_CONFLICT');assert.equal((await quote(u)).body.code,'E_ORDER_PENDING');
   const o=rs[0].body.order;assert.equal((await req('/api/enana/v1/billing/order?id='+o.id,null,w)).status,404);
   assert.equal((await req('/api/enana/v1/billing/order?id='+o.id,null,u)).body.order.id,o.id);
   const incoming=event(o),first=await Promise.all([internal('event',incoming),internal('event',incoming)]);first.forEach(r=>assert.equal(r.status,200));
   const b=(await req('/api/enana/v1/billing',null,u)).body;assert.equal(b.plan.code,'pro');assert.equal(b.wallet.balance,(Number(o.amount)-4).toFixed(6));assert.equal(b.ledger.length,2);assert.equal(b.orders[0].status,'paid');
   assert.equal((await internal('event',{...incoming,amount:incoming.amount+1})).body.code,'E_EVENT_CONFLICT');
  });
  await t.test('wrong amount and old transfers never unlock a plan; cancelled receipts become balance',async()=>{
   const o=(await quote(w)).body.order;
   assert.equal((await internal('event',{...event(o),amount:Math.round(Number(o.amount)*1e6)+1})).body.result.status,'unmatched');
   assert.equal((await internal('event',event(o,0,o.created_at-5))).body.result.status,'unmatched');
   assert.equal((await req('/api/enana/v1/billing',null,w)).body.plan.code,'free');
   assert.equal((await req('/api/enana/v1/billing/cancel',{id:o.id},w)).status,200);
   const late=await internal('event',event(o));assert.equal(late.status,200);assert.equal(late.body.result.reason,'not_payable');const b=(await req('/api/enana/v1/billing',null,w)).body;assert.equal(b.plan.code,'free');assert.equal(b.wallet.balance,'0.000000');assert.equal(b.orders.find(x=>x.id===o.id).status,'manual');
   const next=(await quote(w)).body.order;assert.notEqual(next.amount,o.amount);await req('/api/enana/v1/billing/cancel',{id:next.id},w);
  });
  await t.test('wallet purchase and opt-in renewal debit exactly once; insufficient balance rolls back',async()=>{
   const k=requestKey();const top=(await quote(w,'topup','10')).body.order;assert.equal((await internal('event',event(top))).status,200);const before=(await req('/api/enana/v1/billing',null,w)).body;
   assert.equal((await req('/api/enana/v1/billing/purchase',{sku:'y5',request_key:k},w)).body.code,'E_BALANCE');assert.deepEqual((await req('/api/enana/v1/billing',null,w)).body.wallet,before.wallet);
   const buy={sku:'m1',request_key:requestKey()};const r=await Promise.all([req('/api/enana/v1/billing/purchase',buy,w),req('/api/enana/v1/billing/purchase',buy,w)]);r.forEach(x=>assert.equal(x.status,200));assert.equal(r[0].body.expires_at,r[1].body.expires_at);
   assert.equal((await req('/api/enana/v1/billing/purchase',{...buy,sku:'m3'},w)).body.code,'E_REQUEST_CONFLICT');
   const q=(await quote(w,'topup','10')).body.order;await internal('event',event(q));let b=(await req('/api/enana/v1/billing',null,w)).body;assert.equal(b.wallet.auto_renew,false);
   const subs=(await req('/api/collections/subscriptions/records?filter='+encodeURIComponent('user="'+w.user.id+'"'),null,null,admin)).body.items;
   await patch('/api/collections/subscriptions/records/'+subs[0].id,{expires_at:'2020-01-01 00:00:00Z'},admin);
   const balance=b.wallet.balance;await req('/api/enana/v1/billing/auto-renew',{enabled:true},w);b=(await req('/api/enana/v1/billing',null,w)).body;assert.equal(b.wallet.balance,(Number(balance)-4).toFixed(6));assert.equal(b.plan.code,'pro');
   await req('/api/enana/v1/billing/auto-renew',{enabled:true},w);assert.equal((await req('/api/enana/v1/billing',null,w)).body.wallet.balance,b.wallet.balance);
   await patch('/api/collections/subscriptions/records/'+subs[0].id,{expires_at:'2020-02-01 00:00:00Z'},admin);
   assert.equal((await req('/__test/renew',{})).status,200);
   const renewed=(await req('/api/enana/v1/billing',null,w)).body;assert.equal(renewed.wallet.balance,(Number(b.wallet.balance)-4).toFixed(6));
   assert.equal((await req('/__test/renew',{})).status,200);assert.equal((await req('/api/enana/v1/billing',null,w)).body.wallet.balance,renewed.wallet.balance);
   await req('/api/enana/v1/billing/auto-renew',{enabled:false},w);assert.equal((await req('/api/enana/v1/billing',null,w)).body.wallet.auto_renew,false);
  });
  await t.test('block time determines expiry; late transfers are credited and in-time delayed confirmations grant Pro',async()=>{
   const o=(await quote(u)).body.order,now=Math.floor(Date.now()/1000),date=s=>new Date(s*1000).toISOString();
   await patch('/api/collections/billing_orders/records/'+o.id,{expires_at:date(now-1),pay_by:date(now-1)},admin);
   const before=(await req('/api/enana/v1/billing',null,u)).body;const lateEv=event(o);assert.equal((await internal('event',lateEv)).status,200);
   const late=(await req('/api/enana/v1/billing',null,u)).body;assert.equal(late.orders[0].status,'expired');assert.equal(late.plan.expires_at,before.plan.expires_at);assert.equal(late.wallet.balance,before.wallet.balance);
   assert.ok((await req('/api/enana/admin/billing/manual',null,null,admin)).body.items.some(i=>i.event_key===lateEv.event_key&&i.status==='open'&&!i.order_id),'a transfer after the 24h lease is queued for an operator, never credited');
   const q=(await quote(u)).body.order;
   await patch('/api/collections/billing_orders/records/'+q.id,{expires_at:date(now-20)},admin);
   assert.equal((await req('/__test/backdate',{id:q.id,created:date(now-100).replace('T',' ')})).status,200);
   assert.equal((await internal('event',event(q,0,now-30))).status,200);const paid=(await req('/api/enana/v1/billing/order?id='+q.id,null,u)).body.order;assert.equal(paid.status,'paid');assert.ok((await req('/api/enana/v1/billing',null,u)).body.plan.expires_at>late.plan.expires_at);
  });
  await t.test('disabled receiving switch refuses new checkout without changing existing balances',async()=>{
   fs.writeFileSync(configFile,JSON.stringify({...cfg,payments_enabled:false}),{mode:0o600});assert.equal((await quote(u)).body.code,'E_PAYMENTS_UNAVAILABLE');fs.writeFileSync(configFile,JSON.stringify(cfg),{mode:0o600});
  });
  await t.test('PocketBase SMTP verification sends to the account, rate limits resend and activates token',async()=>{
   smtp=net.createServer(socket=>{socket.setEncoding('utf8');socket.write('220 localhost test SMTP\r\n');let buf='',data=false,mail='';socket.on('data',s=>{buf+=s;let end;while((end=buf.indexOf('\r\n'))!==-1){const line=buf.slice(0,end);buf=buf.slice(end+2);if(data){if(line==='.') {messages.push(mail);mail='';data=false;socket.write('250 queued\r\n')}else mail+=line+'\r\n';continue}if(/^EHLO|^HELO/.test(line))socket.write('250 localhost\r\n');else if(/^DATA/.test(line)){data=true;socket.write('354 send data\r\n')}else if(/^QUIT/.test(line)){socket.end('221 bye\r\n')}else socket.write('250 OK\r\n')}})});await new Promise(r=>smtp.listen(0,'127.0.0.1',r));
   await patch('/api/settings',{smtp:{enabled:true,host:'127.0.0.1',port:smtp.address().port,tls:false,username:'',password:'',authMethod:''}},admin);
   const sent=await req('/api/enana/v1/email/send',{},unverified);assert.equal(sent.status,200);assert.equal(messages.length,1);
   assert.equal((await req('/api/enana/v1/email/send',{},unverified)).status,429);
   assert.ok(messages[0].includes(unverified.email));const text=messages[0].replace(/=\r\n/g,'').replace(/=3D/g,'=');const token=text.match(/verify#token=([a-zA-Z0-9_.-]+)/)?.[1];assert.ok(token,'verification link contains a token');
   const confirmed=await req('/api/collections/users/confirm-verification',{token});assert.equal(confirmed.status,204);assert.equal((await req('/api/enana/v1/email/status',null,unverified)).body.verified,true);
  });
  // ---- 2.3.16 payment rules: integer slots, 24h leases, recheck, operator queue ----
  const iso=d=>new Date(d).toISOString();
  async function closeLeases(){const r=await fetch(host+'/api/collections/billing_orders/records?perPage=500&filter='+encodeURIComponent('expires_at>"'+iso(Date.now())+'"'),{headers:{Authorization:admin}});const docs=(await r.json()).items||[];for(const d of docs)await patch('/api/collections/billing_orders/records/'+d.id,{expires_at:iso(Date.now()-60000),pay_by:iso(Date.now()-60000)},admin)}
  await t.test('integer price when the address is free; a tail only while it is held; the 1-hour countdown blocks a second invoice',async()=>{
   await closeLeases();const a=await user(admin),b=await user(admin);
   const o1=(await quote(a)).body.order;assert.equal(o1.amount,o1.price,'a free address takes the integer price, no decimals');
   const o2=(await quote(b)).body.order;assert.notEqual(o2.amount,o1.amount,'held integer slot: the next buyer gets a tail');
   const tail=Math.round((Number(o2.amount)-Number(o1.price))*100);assert.ok(Number.isInteger(tail)&&tail>=1&&tail<=99,'tail is a whole number of cents between +0.01 and +0.99');
   assert.equal((await quote(a,'plan','m3')).body.code,'E_ORDER_PENDING','one invoice at a time until its 1-hour countdown ends');
  });
  await t.test('recheck is rate-limited to once per 30 seconds per order and puts its address into the next scan',async()=>{
   await closeLeases();const a=await user(admin);const o=(await quote(a)).body.order;
   await patch('/api/collections/billing_orders/records/'+o.id,{pay_by:iso(Date.now()-60000)},admin);
   assert.equal((await req('/api/enana/v1/billing/order/recheck',{id:o.id},a)).status,200);
   const again=await req('/api/enana/v1/billing/order/recheck',{id:o.id},a);assert.equal(again.status,429);assert.equal(again.body.code,'E_RATE_LIMITED');
   assert.ok((await internal('work')).body.active_addresses.includes(o.address),'a rechecked order is scanned on the next pass');
   assert.equal((await req('/api/enana/v1/billing/order/recheck',{id:'nope'},a)).body.code,'E_NOT_FOUND');
  });
  await t.test('underpaid transfers show the order as under manual review; operators can note, refund with a hash, or activate with a note; every action is logged',async()=>{
   await closeLeases();const a=await user(admin),b=await user(admin);
   const o=(await quote(a)).body.order;const under={...event(o),amount:Math.round(Number(o.price)*1e6)-10000};
   assert.equal((await internal('event',under)).body.result.reason,'underpaid');
   assert.equal((await req('/api/enana/v1/billing/order?id='+o.id,null,a)).body.order.status,'manual','the user sees: under review, not a silent failure');
   const items=(await req('/api/enana/admin/billing/manual',null,null,admin)).body.items;const item=items.find(i=>i.event_key===under.event_key);assert.ok(item,'queued');assert.equal(item.order_id,o.id);
   assert.equal((await req('/api/enana/admin/billing/manual/resolve',{id:item.id,action:'note'},null,admin)).body.code,'E_INVALID','every action needs a note');
   const noted=await req('/api/enana/admin/billing/manual/resolve',{id:item.id,action:'note',note:'customer contacted, checked on chain'},null,admin);assert.equal(noted.status,200);
   assert.equal(noted.body.item.status,'resolved');assert.equal(noted.body.item.actions[0].action,'note');assert.equal(noted.body.item.actions[0].by,'admin@example.invalid');assert.ok(noted.body.item.actions[0].at);
   assert.equal((await req('/api/enana/admin/billing/manual/resolve',{id:item.id,action:'note',note:'again'},null,admin)).body.code,'E_ALREADY_RESOLVED');
   // activate an overpaid order after an operator decision
   await closeLeases();const c=await user(admin);const o2=(await quote(c)).body.order;const over={...event(o2),amount:Math.round(Number(o2.price)*1e6)+20000};
   assert.equal((await internal('event',over)).body.result.reason,'overpaid');
   const it2=(await req('/api/enana/admin/billing/manual',null,null,admin)).body.items.find(i=>i.event_key===over.event_key);
   const act=await req('/api/enana/admin/billing/manual/resolve',{id:it2.id,action:'activate',note:'overpaid by 0.02, agreed to credit the rest'},null,admin);assert.equal(act.status,200);
   assert.equal((await req('/api/enana/v1/billing',null,c)).body.plan.code,'pro');
   assert.equal((await req('/api/enana/v1/billing/order?id='+o2.id,null,c)).body.order.status,'paid');
   // refund needs a 64-hex transaction hash; an unmatched transfer has no order
   await closeLeases();const stray={...event(o),address:encodeAddress('22'.repeat(20)),amount:1234567,event_key:crypto.randomBytes(32).toString('hex')+':0'};
   assert.equal((await internal('event',stray)).body.result.reason,'unmatched');
   const it3=(await req('/api/enana/admin/billing/manual',null,null,admin)).body.items.find(i=>i.event_key===stray.event_key);
   assert.equal((await req('/api/enana/admin/billing/manual/resolve',{id:it3.id,action:'refund',note:'refund',refund_tx:'xyz'},null,admin)).body.code,'E_INVALID');
   const rf=await req('/api/enana/admin/billing/manual/resolve',{id:it3.id,action:'refund',note:'refunded to the sender',refund_tx:'ab'.repeat(32)},null,admin);assert.equal(rf.status,200);assert.equal(rf.body.item.resolution,'refunded');assert.equal(rf.body.item.refund_tx,'ab'.repeat(32));
   assert.equal((await req('/api/enana/admin/billing/manual',null,null,admin)).body.items.some(i=>i.id===it3.id),false,'resolved items leave the open queue');
   assert.equal((await req('/api/enana/admin/billing/manual',null,null,null)).status,401,'the operator queue is superuser-only');
  });
 }finally{pb.kill('SIGTERM');await new Promise(r=>pb.once('exit',r));if(smtp)await new Promise(r=>smtp.close(r));fs.rmSync(dir,{recursive:true,force:true})}
});
