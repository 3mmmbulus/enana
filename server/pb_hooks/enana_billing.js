'use strict';
// This module has no mutable request globals. Every financial write uses txApp;
// no mail/provider requests run inside a database transaction.
const base=require('./enana_lib.js'), D=require('./enana_billing_domain.js');
const MICRO=1000000, MONTHLY=4*MICRO;
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
function publicOrder(r){let s=r.getString('status');const lease=unix(r,'expires_at');if(s==='pending'&&lease<=now())s='expired';return {id:r.id,kind:r.getString('kind'),sku:r.getString('sku'),price:D.format(r.getInt('price')),amount:D.format(r.getInt('amount')),network:'TRC20',currency:'USDT',address:r.getString('address'),status:s,created_at:unix(r,'created'),pay_by:unix(r,'pay_by'),expires_at:lease,paid_at:unix(r,'paid_at')||null,tx_hash:r.getString('tx_hash')||null,event_key:r.getString('event_key')||null,recheck_at:unix(r,'recheck_at')||null}}
function mailAvailable(){return !!$app.settings().smtp.enabled}
function status(e){return wrap(e,()=>{const g=user(e,false);if(!g)return;const w=wallet($app,g.user.id,false),p=base.planFor($app,g.user,now());
 const orders=$app.findRecordsByFilter('billing_orders','user={:u}','-created',30,0,{u:g.user.id}).map(publicOrder);
 const rows=$app.findRecordsByFilter('billing_ledger','user={:u}','-created',40,0,{u:g.user.id}).map(r=>({id:r.id,kind:r.getString('kind'),delta:(r.getInt('delta')<0?'-':'')+D.format(Math.abs(r.getInt('delta'))),balance_after:D.format(r.getInt('balance_after')),sku:r.getString('sku'),created_at:unix(r,'created'),expires_after:unix(r,'expires_after')||null}));
 return e.json(200,{ok:true,payments_available:!!ready($app),email:{address:g.user.email(),verified:g.user.verified(),mail_available:mailAvailable()},wallet:{balance:D.format(w?w.getInt('balance'):0),auto_renew:!!(w&&w.getBool('auto_renew')),monthly_price:'4.000000'},catalog:D.SKUS.map(s=>({id:s.id,months:s.months,price:D.format(s.price)})),plan:{code:p.code,expires_at:p.expires_at},orders:orders,ledger:rows,order_ttl:D.PAY_BY,lease_ttl:D.LEASE});})}
// Slot leases: every (address, amount) still held by an unpaid order for 24 hours.
function leases(tx){return tx.findRecordsByFilter('billing_orders','expires_at>{:t}','created',5000,0,{t:iso(now())}).map(r=>({address:r.getString('address'),amount:r.getInt('amount'),lease_until:unix(r,'expires_at'),status:r.getString('status'),created:unix(r,'created')}))}
function billingAlert(kind,price){console.log('enana-billing-alert '+kind+' price='+price+' time='+iso(now())+' action=add_payment_addresses')}
function checkout(e){return wrap(e,()=>{const g=user(e,true);if(!g)return;const b=body(e),req=key(b.request_key);let q;try{q=D.quoteBase(b)}catch(_){error('E_INVALID')}
 let out;$app.runInTransaction(tx=>{current(tx,g,true);const existing=find(tx,'billing_orders','user={:u}&&request_key={:k}',{u:g.user.id,k:req});if(existing){if(existing.getString('kind')!==q.kind||existing.getString('sku')!==q.sku||existing.getInt('price')!==q.price)error('E_REQUEST_CONFLICT',409);out=publicOrder(existing);return}
 if(!ready(tx))error('E_PAYMENTS_UNAVAILABLE',503);
 // One invoice at a time until its 1-hour payment countdown ends; the slot itself stays leased for 24 hours.
 const pending=find(tx,'billing_orders','user={:u}&&status="pending"&&pay_by>{:t}',{u:g.user.id,t:iso(now())});if(pending)error('E_ORDER_PENDING',409);
 const c=config();let slot;
 // Integer price first; tails +0.01..+0.99 only when every address holds that price; never a units digit.
 try{slot=D.allocate(q.price,c.addresses,leases(tx),now())}catch(err){if(err.message==='E_QUOTE_CAPACITY'){billingAlert('quote_capacity',q.price);error('E_QUOTE_CAPACITY',503)}throw err}
 const r=record(tx,'billing_orders');r.set('user',g.user.id);r.set('request_key',req);r.set('kind',q.kind);r.set('sku',q.sku);r.set('months',q.months);r.set('price',q.price);r.set('amount',slot.amount);r.set('address',slot.address);r.set('pay_by',iso(now()+D.PAY_BY));r.set('expires_at',iso(now()+D.LEASE));r.set('status','pending');tx.save(r);out=publicOrder(r);
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
 // Orders on this address whose lease covered the transfer time (any amount, so under/over-payments can be shown to the user).
 const win=tx.findRecordsByFilter('billing_orders','address={:a}&&created<{:c}&&expires_at>={:d}','created',200,0,{a:b.address,c:iso(b.chain_at+1),d:iso(b.chain_at)}).map(r=>({id:r.id,address:r.getString('address'),amount:r.getInt('amount'),created:unix(r,'created'),lease_until:unix(r,'expires_at'),status:r.getString('status'),rec:r}));
 const m=D.matchPayment(win,{address:b.address,amount:b.amount,chain_at:b.chain_at}), hash=b.event_key.split(':')[0];
 if(m.action==='activate'){
  const r=m.order.rec,uid=r.getString('user'),u=tx.findRecordById('users',uid),w=wallet(tx,uid,true),plan=r.getString('kind')==='plan';
  const pl=base.planFor(tx,u,t);
  // Only a clean, verified account gets an automatic plan; anything else goes to the manual queue (never auto-activated, never silently credited).
  if(plan&&(u.getBool('disabled')||!u.verified()||(pl.code==='pro'&&!pl.expires_at))){queueManual(tx,ev,b,m.order,'not_payable',hash);tx.save(ev);return {duplicate:false,status:'unmatched',reason:'not_payable'}}
  ledger(tx,w,'deposit:'+b.event_key,b.amount,'deposit',r.id);
  if(plan){const end=grant(tx,uid,r.getInt('months'),t);ledger(tx,w,'plan:'+r.id,-r.getInt('price'),'plan_purchase',r.id,r.getString('sku'),end)}
  r.set('status','paid');r.set('paid_at',iso(t));r.set('event_key',b.event_key);r.set('tx_hash',hash);tx.save(r);ev.set('order_id',r.id);ev.set('status','matched');
  if(!plan)renew(tx,uid,t);
  tx.save(ev);return {duplicate:false,status:'matched'};
 }
 queueManual(tx,ev,b,m.order||null,m.reason,hash);tx.save(ev);
 return {duplicate:false,status:'unmatched',reason:m.reason};
}
// Manual queue: nothing is opened, refunded or credited automatically. The order (if any) shows that it is under review.
function queueManual(tx,ev,b,order,reason,hash){
 if(order){ev.set('order_id',order.id);if(order.rec){const rec=order.rec,st=rec.getString('status');if(st!=='paid'&&st!=='activated'){rec.set('status','manual');rec.set('tx_hash',hash);rec.set('event_key',b.event_key);tx.save(rec)}}}
 const mr=record(tx,'billing_manual');mr.set('event_key',b.event_key);mr.set('address',b.address);mr.set('amount',b.amount);mr.set('chain_at',iso(b.chain_at));mr.set('reason',reason);
 if(order&&order.rec)mr.set('user',order.rec.getString('user'));
 mr.set('order_id',order?order.id:'');mr.set('status','open');mr.set('resolution','none');mr.set('actions',[]);tx.save(mr);return mr}
function events(e){return wrap(e,()=>{internal(e);const b=body(e);let out;$app.runInTransaction(tx=>{out=settle(tx,b,now())});return e.json(200,{ok:true,result:out});})}
function health(e){return wrap(e,()=>{internal(e);const b=body(e);if(typeof b.healthy!=='boolean')error('E_INVALID');let h=find($app,'billing_health','code="scanner"');if(!h)h=record($app,'billing_health');h.set('code','scanner');h.set('healthy',b.healthy);h.set('checked_at',iso(now()));h.set('message',b.healthy?'ready':'provider_unavailable');$app.save(h);return e.json(200,{ok:true});})}
function work(e){return wrap(e,()=>{const c=internal(e),t=iso(now()),active=$app.findRecordsByFilter('billing_orders','(status="pending"&&pay_by>{:t})||(recheck_at>{:r}&&expires_at>{:t})','created',200,0,{t:t,r:iso(now()-300)});return e.json(200,{ok:true,addresses:c.addresses||[],active_addresses:Array.from(new Set(active.map(r=>r.getString('address'))))});})}
function renewAll(){const rows=arrayOf(new DynamicModel({user:''}));$app.db().newQuery('SELECT w.user FROM billing_wallets w JOIN users u ON u.id=w.user LEFT JOIN subscriptions s ON s.user=w.user WHERE w.auto_renew=1 AND w.balance>=4000000 AND u.verified=1 AND u.disabled=0 AND (s.id IS NULL OR s.plan=(SELECT id FROM plans WHERE code="free") OR (s.expires_at!="" AND s.expires_at<={:t})) ORDER BY w.updated LIMIT 100').bind({t:iso(now())}).all(rows);for(const row of rows)$app.runInTransaction(tx=>{renew(tx,row.user,now())})}
function emailStatus(e){return wrap(e,()=>{const g=user(e,false);if(!g)return;return e.json(200,{ok:true,email:g.user.email(),verified:g.user.verified(),mail_available:mailAvailable()});})}
function emailSend(e){return wrap(e,()=>{const g=user(e,false);if(!g)return;if(g.user.verified())return e.json(200,{ok:true,verified:true});if(!mailAvailable())error('E_MAIL_UNAVAILABLE',503);
 $app.runInTransaction(tx=>{current(tx,g,false);let r=find(tx,'email_requests','user={:u}',{u:g.user.id});if(r&&unix(r,'requested_at')>now()-60)error('E_MAIL_WAIT',429);if(!r)r=record(tx,'email_requests');r.set('user',g.user.id);r.set('requested_at',iso(now()));tx.save(r)});
 try{$mails.sendRecordVerification($app,g.user)}catch(_){error('E_MAIL_UNAVAILABLE',503)}return e.json(200,{ok:true,sent:true,retry_after:60});})}
function registrationMail(userRecord){if(!userRecord.verified()&&mailAvailable())try{$mails.sendRecordVerification($app,userRecord)}catch(_){/* account remains usable; resend is available */}}
// User: confirm a waiting or manual-review order now (the scanner checks its address within ~10s). At most once per 30 seconds per order.
function recheck(e){return wrap(e,()=>{const g=user(e,false);if(!g)return;const b=body(e);let out;$app.runInTransaction(tx=>{current(tx,g,false);const r=find(tx,'billing_orders','id={:id}&&user={:u}',{id:b.id||'',u:g.user.id});if(!r)error('E_NOT_FOUND',404);const st=r.getString('status');if(st!=='pending'&&st!=='manual')error('E_INVALID',409);if(unix(r,'expires_at')<=now())error('E_EXPIRED',409);const last=unix(r,'recheck_at');if(last&&last>now()-30)error('E_RATE_LIMITED',429);r.set('recheck_at',iso(now()));tx.save(r);out=publicOrder(r)});return e.json(200,{ok:true,order:out});})}
// Operators (superuser routes): list open manual items; resolve with a note. Every action is appended to the item's log.
function actionsOf(r){const v=r.get('actions');let text;if(typeof v==='string')text=v;else if(Array.isArray(v)&&v.every(n=>typeof n==='number'))text=decodeURIComponent(v.map(b=>'%'+('0'+b.toString(16)).slice(-2)).join(''));else text=JSON.stringify(v);let a=[];try{a=JSON.parse(text)}catch(_){a=[]}return Array.isArray(a)?a:[]}
function manualPublic(r){return {id:r.id,event_key:r.getString('event_key'),address:r.getString('address'),amount:D.format(r.getInt('amount')),chain_at:unix(r,'chain_at'),reason:r.getString('reason'),order_id:r.getString('order_id')||null,status:r.getString('status'),resolution:r.getString('resolution'),refund_tx:r.getString('refund_tx')||null,actions:actionsOf(r)}}
function manualList(e){return wrap(e,()=>{const rows=$app.findRecordsByFilter('billing_manual','status="open"','created',200,0);return e.json(200,{ok:true,items:rows.map(manualPublic)})})}
function activateManual(tx,r,mr,t){
 const uid=r.getString('user'),w=wallet(tx,uid,true),plan=r.getString('kind')==='plan';
 ledger(tx,w,'deposit:'+mr.getString('event_key'),r.getInt('amount'),'deposit',r.id);
 if(plan){const end=grant(tx,uid,r.getInt('months'),t);ledger(tx,w,'plan:'+r.id,-r.getInt('price'),'plan_purchase',r.id,r.getString('sku'),end)}
 r.set('status','paid');r.set('paid_at',iso(t));r.set('event_key',mr.getString('event_key'));r.set('tx_hash',mr.getString('event_key').split(':')[0]);tx.save(r);
}
function manualResolve(e){return wrap(e,()=>{const b=body(e),note=typeof b.note==='string'?b.note.trim():'';if(!note||note.length>500)error('E_INVALID');if(!['activate','refund','note'].includes(b.action))error('E_INVALID');
 const admin=e.auth?e.auth.getString('email'):'';let out;
 $app.runInTransaction(tx=>{const mr=find(tx,'billing_manual','id={:id}',{id:b.id||''});if(!mr)error('E_NOT_FOUND',404);if(mr.getString('status')!=='open')error('E_ALREADY_RESOLVED',409);
  if(b.action==='activate'){const oid=mr.getString('order_id');if(!oid)error('E_INVALID');const r=find(tx,'billing_orders','id={:id}',{id:oid});if(!r)error('E_NOT_FOUND',404);if(r.getString('status')!=='paid'&&r.getString('status')!=='activated')activateManual(tx,r,mr,now());mr.set('resolution','activated')}
  else if(b.action==='refund'){const rt=typeof b.refund_tx==='string'?b.refund_tx.toLowerCase():'';if(!/^[a-f0-9]{64}$/.test(rt))error('E_INVALID');mr.set('refund_tx',rt);mr.set('resolution','refunded')}
  else mr.set('resolution','noted');
  mr.set('status','resolved');const acts=actionsOf(mr); /* plain copy: the stored JSON value is not a plain array */acts.push({by:admin,at:iso(now()),action:b.action,note:note});mr.set('actions',acts);tx.save(mr);out=manualPublic(mr)});
 console.log('enana-billing-manual '+b.action+' id='+b.id+' by='+admin+' at='+iso(now()));return e.json(200,{ok:true,item:out});})}
module.exports={recheck:recheck,manualList:manualList,manualResolve:manualResolve,status:status,checkout:checkout,order:order,cancel:cancel,purchase:purchase,autoRenew:autoRenew,events:events,health:health,work:work,renewAll:renewAll,emailStatus:emailStatus,emailSend:emailSend,registrationMail:registrationMail,config:config};
