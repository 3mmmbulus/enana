'use strict';
// This module has no mutable request globals. Every financial write uses txApp;
// no mail/provider requests run inside a database transaction.
const base=require('./enana_lib.js'), D=require('./enana_billing_domain.js');
const MICRO=1000000, MONTHLY=4*MICRO, ORDER_TTL=1800;
function now(){return Math.floor(Date.now()/1000)}
function iso(t){return new Date(t*1000).toISOString().replace('T',' ')}
function unix(r,k){const d=r.getDateTime(k);return d&&!d.isZero()?d.unix():0}
function error(code,status){const e=Error(code);e.status=status||400;throw e}
function find(app,c,f,p){try{return app.findFirstRecordByFilter(c,f,p||{})}catch(_){return null}}
function record(app,c){return new Record(app.findCollectionByNameOrId(c))}
function config(){try{return JSON.parse(toString($os.readFile($os.getenv('ENANA_BILLING_CONFIG')||'/etc/enana/billing.json')))}catch(_){return {}}}
function configured(c){return c.payments_enabled===true&&typeof c.scanner_secret==='string'&&c.scanner_secret.length>=32&&typeof c.provider_key==='string'&&c.provider_key.length>0&&Array.isArray(c.addresses)&&c.addresses.length>0&&c.addresses.length<=20&&c.addresses.every(a=>/^T[1-9A-HJ-NP-Za-km-z]{33}$/.test(a))}
function ready(app){const c=config(),h=find(app,'billing_health','code="scanner"');return configured(c)&&h&&h.getBool('healthy')&&unix(h,'checked_at')>=now()-180}
function wrap(e,fn){try{return fn()}catch(err){const code=/^E_[A-Z_]+$/.test(err.message)?err.message:'E_BILLING_INTERNAL';return e.json(err.status||500,{ok:false,code:code,message:code})}}
function user(e,verified){const g=base.needSession(e);if(g.res)return null;g.user=$app.findRecordById('users',g.user.id);if(verified&&!g.user.verified())error('E_EMAIL_UNVERIFIED',403);return g}
function current(tx,g,verified){const u=tx.findRecordById('users',g.user.id),s=tx.findRecordById('device_sessions',g.session.id);if(u.getBool('disabled')||s.getString('user')!==u.id||unix(s,'revoked_at')||unix(s,'expires_at')<=now())error('E_AUTH',401);if(verified&&!u.verified())error('E_EMAIL_UNVERIFIED',403);return u}
function internal(e){const c=config(),key=e.request.header.get('X-Enana-Payments')||'';if(!['127.0.0.1','::1'].includes(e.remoteIP())||typeof c.scanner_secret!=='string'||c.scanner_secret.length<32||!$security.equal(key,c.scanner_secret))error('E_NOT_FOUND',404);return c}
function body(e){const b=base.readJSON(e,32768);if(!b)error('E_INVALID');return b}
function key(v){if(typeof v!=='string'||!/^[a-zA-Z0-9_-]{16,80}$/.test(v))error('E_REQUEST_KEY');return v}
function wallet(app,uid,create){let w=find(app,'billing_wallets','user={:u}',{u:uid});if(!w&&create){w=record(app,'billing_wallets');w.set('user',uid);w.set('balance',0);w.set('auto_renew',false);app.save(w)}return w}
function ledger(tx,w,entry,delta,kind,order,sku,expires){
 if(!Number.isSafeInteger(delta)||!delta)error('E_INVALID');
 const next=w.getInt('balance')+delta;if(!Number.isSafeInteger(next)||next<0||next>9000000000000)error('E_BALANCE',409);
 const row=record(tx,'billing_ledger');row.set('user',w.getString('user'));row.set('entry_key',entry);row.set('delta',delta);row.set('balance_after',next);row.set('kind',kind);row.set('order_id',order||'');row.set('sku',sku||'');if(expires)row.set('expires_after',iso(expires));tx.save(row);w.set('balance',next);tx.save(w);return row;
}
function grant(tx,uid,months,t){
 const u=tx.findRecordById('users',uid),p=base.planFor(tx,u,t);if(p.code==='pro'&&!p.expires_at)error('E_ALREADY_UNLIMITED',409);
 const start=p.code==='pro'?Math.max(t,p.expires_at||t):t,end=D.addMonths(start,months);
 let sub=find(tx,'subscriptions','user={:u}',{u:uid});if(!sub)sub=record(tx,'subscriptions');
 sub.set('user',uid);sub.set('plan',tx.findFirstRecordByData('plans','code','pro').id);sub.set('status','active');sub.set('expires_at',iso(end));sub.set('source','payment');tx.save(sub);return end;
}
function renew(tx,uid,t){const u=tx.findRecordById('users',uid);if(u.getBool('disabled')||!u.verified())return false;const w=wallet(tx,uid,false);if(!w||!w.getBool('auto_renew')||w.getInt('balance')<MONTHLY)return false;
 const p=base.planFor(tx,u,t);if(p.code==='pro')return false;
 const sub=find(tx,'subscriptions','user={:u}',{u:uid}),entry='renew:'+uid+':'+(sub?sub.id:'new')+':'+(sub?unix(sub,'expires_at'):0);
 if(find(tx,'billing_ledger','entry_key={:k}',{k:entry}))return false;
 const end=grant(tx,uid,1,t);ledger(tx,w,entry,-MONTHLY,'auto_renew','','m1',end);return true;
}
function publicOrder(r){let s=r.getString('status');if(s==='pending'&&unix(r,'expires_at')<=now())s='expired';return {id:r.id,kind:r.getString('kind'),sku:r.getString('sku'),price:D.format(r.getInt('price')),amount:D.format(r.getInt('amount')),network:'TRC20',currency:'USDT',address:r.getString('address'),status:s,created_at:unix(r,'created'),expires_at:unix(r,'expires_at'),paid_at:unix(r,'paid_at')||null,event_key:r.getString('event_key')||null}}
function mailAvailable(){return !!$app.settings().smtp.enabled}
function status(e){return wrap(e,()=>{const g=user(e,false);if(!g)return;const w=wallet($app,g.user.id,false),p=base.planFor($app,g.user,now());
 const orders=$app.findRecordsByFilter('billing_orders','user={:u}','-created',30,0,{u:g.user.id}).map(publicOrder);
 const rows=$app.findRecordsByFilter('billing_ledger','user={:u}','-created',40,0,{u:g.user.id}).map(r=>({id:r.id,kind:r.getString('kind'),delta:(r.getInt('delta')<0?'-':'')+D.format(Math.abs(r.getInt('delta'))),balance_after:D.format(r.getInt('balance_after')),sku:r.getString('sku'),created_at:unix(r,'created'),expires_after:unix(r,'expires_after')||null}));
 return e.json(200,{ok:true,payments_available:!!ready($app),email:{address:g.user.email(),verified:g.user.verified(),mail_available:mailAvailable()},wallet:{balance:D.format(w?w.getInt('balance'):0),auto_renew:!!(w&&w.getBool('auto_renew')),monthly_price:'4.000000'},catalog:D.SKUS.map(s=>({id:s.id,months:s.months,price:D.format(s.price)})),plan:{code:p.code,expires_at:p.expires_at},orders:orders,ledger:rows,order_ttl:ORDER_TTL});})}
function checkout(e){return wrap(e,()=>{const g=user(e,true);if(!g)return;const b=body(e),req=key(b.request_key);let q;try{q=D.quoteBase(b)}catch(_){error('E_INVALID')}
 let out;$app.runInTransaction(tx=>{current(tx,g,true);const existing=find(tx,'billing_orders','user={:u}&&request_key={:k}',{u:g.user.id,k:req});if(existing){if(existing.getString('kind')!==q.kind||existing.getString('sku')!==q.sku||existing.getInt('price')!==q.price)error('E_REQUEST_CONFLICT',409);out=publicOrder(existing);return}
 if(!ready(tx))error('E_PAYMENTS_UNAVAILABLE',503);
 const pending=find(tx,'billing_orders','user={:u}&&status="pending"&&expires_at>{:t}',{u:g.user.id,t:iso(now())});if(pending)error('E_ORDER_PENDING',409);
 const c=config(),seed=Number($security.randomStringWithAlphabet(8,'0123456789'));let address='',amount=0;
 // Unique quotes are NEVER reused, even after expiry/cancel, so a delayed
 // transfer cannot pay a newer user's invoice. Reserve inside the write lock.
 for(let i=0;i<500;i++){const a=c.addresses[(seed+i)%c.addresses.length],n=q.price+1+(seed+i)%9999;if(!find(tx,'billing_orders','address={:a}&&amount={:n}',{a:a,n:n})){address=a;amount=n;break}}
 if(!address)error('E_QUOTE_CAPACITY',503);const r=record(tx,'billing_orders');r.set('user',g.user.id);r.set('request_key',req);r.set('kind',q.kind);r.set('sku',q.sku);r.set('months',q.months);r.set('price',q.price);r.set('amount',amount);r.set('address',address);r.set('expires_at',iso(now()+ORDER_TTL));r.set('status','pending');tx.save(r);out=publicOrder(r);
 });return e.json(200,{ok:true,order:out});})}
function order(e){return wrap(e,()=>{const g=user(e,false);if(!g)return;const id=e.request.url.query().get('id'),r=find($app,'billing_orders','id={:id}&&user={:u}',{id:id,u:g.user.id});if(!r)error('E_NOT_FOUND',404);return e.json(200,{ok:true,order:publicOrder(r)});})}
function cancel(e){return wrap(e,()=>{const g=user(e,false);if(!g)return;const b=body(e);let out;$app.runInTransaction(tx=>{current(tx,g,false);const r=find(tx,'billing_orders','id={:id}&&user={:u}',{id:b.id||'',u:g.user.id});if(!r)error('E_NOT_FOUND',404);if(r.getString('status')==='pending'){r.set('status','cancelled');tx.save(r)}out=publicOrder(r)});return e.json(200,{ok:true,order:out});})}
function purchase(e){return wrap(e,()=>{const g=user(e,true);if(!g)return;const b=body(e),req=key(b.request_key);let s;try{s=D.sku(b.sku)}catch(_){error('E_INVALID')}let end;
 $app.runInTransaction(tx=>{current(tx,g,true);const entry='purchase:'+g.user.id+':'+req,old=find(tx,'billing_ledger','entry_key={:k}',{k:entry});if(old){if(old.getString('sku')!==s.id)error('E_REQUEST_CONFLICT',409);end=unix(old,'expires_after');return}const w=wallet(tx,g.user.id,true);if(w.getInt('balance')<s.price)error('E_BALANCE',409);end=grant(tx,g.user.id,s.months,now());ledger(tx,w,entry,-s.price,'plan_purchase','',s.id,end)});
 return e.json(200,{ok:true,expires_at:end});})}
function autoRenew(e){return wrap(e,()=>{const g=user(e,true);if(!g)return;const b=body(e);if(typeof b.enabled!=='boolean')error('E_INVALID');$app.runInTransaction(tx=>{current(tx,g,true);const w=wallet(tx,g.user.id,true);w.set('auto_renew',b.enabled);tx.save(w);if(b.enabled)renew(tx,g.user.id,now())});return e.json(200,{ok:true,auto_renew:b.enabled});})}
function settle(tx,b,t){
 if(!/^[a-f0-9]{64}:\d{1,5}$/.test(b.event_key)||!/^T[1-9A-HJ-NP-Za-km-z]{33}$/.test(b.address)||!Number.isSafeInteger(b.amount)||b.amount<1||b.amount>9000000000000||!Number.isSafeInteger(b.chain_at)||b.chain_at<=0||b.chain_at>t+30)error('E_INVALID');
 const old=find(tx,'billing_events','event_key={:k}',{k:b.event_key});if(old){if(old.getString('address')!==b.address||old.getInt('amount')!==b.amount||unix(old,'chain_at')!==b.chain_at)error('E_EVENT_CONFLICT',409);return {duplicate:true,status:old.getString('status')}}
 const ev=record(tx,'billing_events');ev.set('event_key',b.event_key);ev.set('address',b.address);ev.set('amount',b.amount);ev.set('chain_at',iso(b.chain_at));ev.set('status','unmatched');
 const r=find(tx,'billing_orders','address={:a}&&amount={:n}',{a:b.address,n:b.amount});
 if(r&&b.chain_at>=unix(r,'created')&&!r.getString('event_key')){
  const uid=r.getString('user'),w=wallet(tx,uid,true);ledger(tx,w,'deposit:'+b.event_key,b.amount,'deposit',r.id);
  const u=tx.findRecordById('users',uid),inTime=r.getString('status')==='pending'&&b.chain_at<=unix(r,'expires_at');
  let paid=inTime;
  if(inTime&&r.getString('kind')==='plan'){
   // A disabled/unverified account keeps its deposit in the wallet; it does
   // not receive Pro. No funds disappear when account state changes in flight.
   if(u.getBool('disabled')||!u.verified()||(base.planFor(tx,u,t).code==='pro'&&!base.planFor(tx,u,t).expires_at))paid=false;
   else{const end=grant(tx,uid,r.getInt('months'),t);ledger(tx,w,'plan:'+r.id,-r.getInt('price'),'plan_purchase',r.id,r.getString('sku'),end)}
  }
  r.set('status',paid?'paid':'credited_late');r.set('paid_at',iso(t));r.set('event_key',b.event_key);tx.save(r);ev.set('order_id',r.id);ev.set('status','matched');
  if(r.getString('kind')==='topup')renew(tx,uid,t);
 }
 tx.save(ev);return {duplicate:false,status:ev.getString('status')};
}
function events(e){return wrap(e,()=>{internal(e);const b=body(e);let out;$app.runInTransaction(tx=>{out=settle(tx,b,now())});return e.json(200,{ok:true,result:out});})}
function health(e){return wrap(e,()=>{internal(e);const b=body(e);if(typeof b.healthy!=='boolean')error('E_INVALID');let h=find($app,'billing_health','code="scanner"');if(!h)h=record($app,'billing_health');h.set('code','scanner');h.set('healthy',b.healthy);h.set('checked_at',iso(now()));h.set('message',b.healthy?'ready':'provider_unavailable');$app.save(h);return e.json(200,{ok:true});})}
function work(e){return wrap(e,()=>{const c=internal(e),pending=$app.findRecordsByFilter('billing_orders','status="pending"&&expires_at>{:t}','created',200,0,{t:iso(now())});return e.json(200,{ok:true,addresses:c.addresses||[],active_addresses:Array.from(new Set(pending.map(r=>r.getString('address'))))});})}
function renewAll(){const rows=arrayOf(new DynamicModel({user:''}));$app.db().newQuery('SELECT w.user FROM billing_wallets w JOIN users u ON u.id=w.user LEFT JOIN subscriptions s ON s.user=w.user WHERE w.auto_renew=1 AND w.balance>=4000000 AND u.verified=1 AND u.disabled=0 AND (s.id IS NULL OR s.plan=(SELECT id FROM plans WHERE code="free") OR (s.expires_at!="" AND s.expires_at<={:t})) ORDER BY w.updated LIMIT 100').bind({t:iso(now())}).all(rows);for(const row of rows)$app.runInTransaction(tx=>{renew(tx,row.user,now())})}
function emailStatus(e){return wrap(e,()=>{const g=user(e,false);if(!g)return;return e.json(200,{ok:true,email:g.user.email(),verified:g.user.verified(),mail_available:mailAvailable()});})}
function emailSend(e){return wrap(e,()=>{const g=user(e,false);if(!g)return;if(g.user.verified())return e.json(200,{ok:true,verified:true});if(!mailAvailable())error('E_MAIL_UNAVAILABLE',503);
 $app.runInTransaction(tx=>{current(tx,g,false);let r=find(tx,'email_requests','user={:u}',{u:g.user.id});if(r&&unix(r,'requested_at')>now()-60)error('E_MAIL_WAIT',429);if(!r)r=record(tx,'email_requests');r.set('user',g.user.id);r.set('requested_at',iso(now()));tx.save(r)});
 try{$mails.sendRecordVerification($app,g.user)}catch(_){error('E_MAIL_UNAVAILABLE',503)}return e.json(200,{ok:true,sent:true,retry_after:60});})}
function registrationMail(userRecord){if(!userRecord.verified()&&mailAvailable())try{$mails.sendRecordVerification($app,userRecord)}catch(_){/* account remains usable; resend is available */}}
module.exports={status:status,checkout:checkout,order:order,cancel:cancel,purchase:purchase,autoRenew:autoRenew,events:events,health:health,work:work,renewAll:renewAll,emailStatus:emailStatus,emailSend:emailSend,registrationMail:registrationMail,config:config};
