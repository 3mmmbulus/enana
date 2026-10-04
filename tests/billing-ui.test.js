'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs'),crypto=require('node:crypto');
const script=fs.readFileSync(require('node:path').join(__dirname,'../ui/billing.js'),'utf8');
function node(tag,attrs,...children){return {tag,attrs:attrs||{},children:children.flat().filter(x=>x!=null),appendChild(x){this.children.push(x);return x},value:attrs?.value||''};}
function flatten(n){return n&&typeof n==='object'?[n,...(n.children||[]).flatMap(flatten)]:[];}
function find(root,label){const b=flatten(root).find(n=>n.tag==='button'&&n.label===label);assert.ok(b,'missing '+label);return b;}
const invoice={id:'abcdefghijklmno',kind:'plan',sku:'m1',price:'4.000000',amount:'4.000037',address:'TMiyPt3gfLQNJRPqUzGke9EJWhhyoHR8RU',status:'pending',created_at:Math.floor(Date.now()/1000),expires_at:Math.floor(Date.now()/1000)+1800};
function status(extra={}){return {ok:true,payments_available:true,email:{verified:true,address:'one@example.test',mail_available:true},wallet:{balance:'10.000000',auto_renew:false},catalog:[{id:'m1',price:'4.000000',months:1},{id:'m3',price:'10.000000',months:3}],orders:[],ledger:[],...extra};}
function fixture(handler){
 const callbacks={},calls=[],modals=[],copies=[],timers=new Map(),toasts=[],confirmations=[];let id=0;
 const emit=(ev,arg)=>{(callbacks[ev]||[]).forEach(fn=>fn(arg));};
 const ui={btn(label){return Object.assign(node('button'),{label});},avail(b,why){b.reason=why;},actionBusy(b,on){b.disabled=on;},act(b,fn){b.click=async()=>b.reason||b.disabled?null:fn();},badge(label){return node('badge',null,label);},toast(...x){toasts.push(x);},copy(v){copies.push(v);},confirmDialog:async o=>{confirmations.push(o);return true;},modal(o){const d={body:o.body,actions:o.actions||[],setActions(a){d.actions=a;},close(){d.closed=true;o.onClose?.();}};modals.push(d);return d;}};
 const TP={S:{locked:false},h:node,ui,why:{helper:()=>''},clear:n=>{n.children=[];},on:(ev,fn)=>{(callbacks[ev]||=[]).push(fn);},emit,errMsg:e=>e.message||e.code||'error',mkErr:(kind,message)=>({kind,message}),helper:async(...args)=>{calls.push(args);return handler(...args);},plan:{load:()=>{}},fmt:{dateTime:String}};
 const document={hidden:false};const I={t:(k,args)=>k+(args?JSON.stringify(args):''),L:k=>k,has:k=>k.startsWith('billing.err.')};
 vm.runInNewContext(script,{window:{TP,I18N:I,crypto},document,setInterval:()=>0,setTimeout:fn=>{timers.set(++id,fn);return id},clearTimeout:i=>timers.delete(i),console});
 return {B:TP.billing,TP,calls,modals,copies,toasts,confirmations,timers,document,emit};
}
test('receiving disabled and unverified email independently block checkout; free account remains usable',async()=>{
 for(const s of [status({payments_available:false}),status({email:{verified:false,address:'u@example.test',mail_available:false}})]){
  const f=fixture(async()=>s),root=f.B.mount();await f.B.load(true);
  assert.ok(find(root,'billing.payUSDT').reason);await find(root,'billing.payUSDT').click();assert.equal(f.calls.length,1);
  if(!s.email.verified)assert.ok(find(root,'billing.sendVerification').reason);
 }
});
test('unknown-result checkout retains request key and retry cannot create a second financial operation',async()=>{
 let writes=0,done;
 const f=fixture(async(m,p,o)=>{if(m==='GET')return status();writes++;if(writes===1)throw {code:'E_ACCOUNT_UNREACHABLE'};return new Promise(r=>{done=r});});
 const root=f.B.mount();await f.B.load(true);await find(root,'billing.payUSDT').click();
 const retry=find(root,'billing.payUSDT').click();await Promise.resolve();
 await find(root,'billing.payUSDT').click();assert.equal(writes,2);
 const posts=f.calls.filter(c=>c[0]==='POST').map(c=>JSON.parse(c[2].body));assert.equal(posts[0].request_key,posts[1].request_key);assert.equal(posts[0].sku,'m1');assert.ok(!('price' in posts[0]));
 done({ok:true,order:invoice});await retry;assert.equal(f.modals.length,1);
});
test('invoice copies the six-decimal server quote without rounding; hidden pages pause polling; close stops it',async()=>{
 const f=fixture(async()=>({ok:true,order:invoice}));f.B.openOrder(invoice);const d=f.modals[0];
 await find(d.body,'billing.copyAmount').click();await find(d.body,'billing.copyAddress').click();assert.deepEqual(f.copies,[invoice.amount,invoice.address]);
 f.document.hidden=true;let task=[...f.timers.values()][0];f.timers.clear();await task();assert.equal(f.calls.length,0);
 f.document.hidden=false;task=[...f.timers.values()][0];f.timers.clear();await task();assert.equal(f.calls.length,1);
 d.close();assert.equal(f.timers.size,0);
});
test('paid status only follows cloud order response and cancellation invalidates an older poll',async()=>{
 let resolvePoll;
 const f=fixture(async(m,p)=>{if(p==='/api/billing')return status();if(p==='/api/billing/order')return new Promise(r=>resolvePoll=r);if(p==='/api/billing/cancel')return {ok:true,order:{...invoice,status:'cancelled'}};});
 await f.B.load(true);f.B.openOrder(invoice);const d=f.modals[0],poll=[...f.timers.values()][0];f.timers.clear();const run=poll();await Promise.resolve();
 const cancel=d.actions.find(a=>a.label==='billing.cancelInvoice');await cancel.onClick();resolvePoll({ok:true,order:invoice});await run;
 assert.ok(flatten(d.body).some(n=>n.attrs?.role==='status'&&n.children.includes('billing.status.cancelled')));
 assert.equal(f.timers.size,0);
});
test('closed and past-deadline invoices retain history but cannot encourage another transfer',async()=>{
 for(const o of [{...invoice,status:'cancelled'},{...invoice,status:'paid'},{...invoice,expires_at:Math.floor(Date.now()/1000)-1}]){
  const f=fixture(async()=>({ok:true,order:o}));f.B.openOrder(o);const d=f.modals[0];
  assert.equal(find(d.body,'billing.copyAmount').reason,'billing.invoiceClosed');
  assert.equal(find(d.body,'billing.copyAddress').reason,'billing.invoiceClosed');
  await find(d.body,'billing.copyAmount').click();assert.equal(f.copies.length,0);d.close();
 }
});
test('logout discards a late status response and closes invoices before another account can see them',async()=>{
 let done;const f=fixture(()=>new Promise(r=>{done=r}));const root=f.B.mount(),load=f.B.load(true);f.B.openOrder(invoice);f.emit('auth',false);done(status());await load;
 assert.equal(f.modals[0].closed,true);assert.ok(!JSON.stringify(root).includes('one@example.test'));assert.equal(f.timers.size,0);
});
test('wallet purchase and automatic renewal disclose the debit before sending it; decimal remainder stays visible',async()=>{
 const f=fixture(async(m,p)=>m==='GET'?status({wallet:{balance:'10.000037',auto_renew:false}}):{ok:true});const root=f.B.mount();await f.B.load(true);
 await find(root,'billing.balancePay').click();const purchase=f.calls.find(c=>c[1]==='/api/billing/purchase');assert.equal(JSON.parse(purchase[2].body).sku,'m1');assert.ok(f.confirmations[0].message.includes('4'));
 await find(root,'billing.enableRenew').click();assert.ok(f.confirmations[1].message.includes('billing.renewConfirm'));assert.equal(JSON.parse(f.calls.find(c=>c[1]==='/api/billing/auto-renew')[2].body).enabled,true);
 assert.ok(flatten(root).some(n=>n.tag==='strong'&&n.children.some(s=>String(s).includes('10.000037'))));
});
test('mail sends only the current authenticated account and ignores repeat clicks in cooldown',async()=>{
 const f=fixture(async(m)=>m==='GET'?status({email:{verified:false,address:'u@example.test',mail_available:true}}):{ok:true,sent:true,retry_after:60});const root=f.B.mountEmail();await f.B.load(true);
 await find(root,'billing.sendVerification').click();await find(root,'billing.sendVerification').click();const sent=f.calls.filter(c=>c[1]==='/api/email/send');assert.equal(sent.length,1);assert.deepEqual(JSON.parse(sent[0][2].body),{});
});
