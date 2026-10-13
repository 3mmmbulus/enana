'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs'),crypto=require('node:crypto');
const script=fs.readFileSync(require('node:path').join(__dirname,'../ui/billing.js'),'utf8');
function node(tag,attrs,...children){return {tag,attrs:attrs||{},children:children.flat(Infinity).filter(x=>x!=null),appendChild(x){this.children.push(x);return x},setAttribute(k,v){this.attrs[k]=String(v)},value:attrs?.value||''};}
function flatten(n){return n&&typeof n==='object'?[n,...(n.children||[]).flatMap(flatten)]:[];}
function find(root,label){const b=flatten(root).find(n=>n.tag==='button'&&n.label===label);assert.ok(b,'missing '+label);return b;}
const cls=n=>String(n?.className??n?.attrs?.class??'');
const byClass=(root,c)=>flatten(root).filter(n=>cls(n).split(' ').includes(c));
const textOf=n=>typeof n==='string'?n:(n.children||[]).map(textOf).join('');
const strings=n=>typeof n==='string'?[n]:(n&&n.children||[]).flatMap(strings);
const hasAny=(root,key)=>strings(root).some(x=>x.startsWith(key));
const now=()=>Math.floor(Date.now()/1000);
/* What a pending invoice looks like now: a whole-USDT price plus a short decimal tail, 1 hour to pay (pay_by), the amount leased for 24 hours (expires_at). */
const invoice={id:'abcdefghijklmno',kind:'plan',sku:'m1',price:'4.000000',amount:'4.010000',address:'TMiyPt3gfLQNJRPqUzGke9EJWhhyoHR8RU',status:'pending',created_at:now()-60,pay_by:now()+3540,expires_at:now()+86340};
const CATALOG=[['m1',1,4],['m3',3,10],['m6',6,19],['y1',12,35],['y2',24,56],['y3',36,72],['y5',60,100]].map(([id,months,p])=>({id,months,price:p+'.000000'}));
function status(extra={}){return {ok:true,payments_available:true,email:{verified:true,address:'one@example.test',mail_available:true},wallet:{balance:'10.000000',auto_renew:false,monthly_price:'4.000000'},catalog:[{id:'m1',price:'4.000000',months:1},{id:'m3',price:'10.000000',months:3}],plan:{code:'free',expires_at:null},orders:[],ledger:[],...extra};}
function fixture(handler,opts={}){
 const callbacks={},calls=[],modals=[],copies=[],copyMsgs=[],timers=new Map(),intervals=new Map(),toasts=[],confirmations=[],signIns=[],planLoads=[],segs=[],tabs=[];let id=0;
 const emit=(ev,arg)=>{(callbacks[ev]||[]).forEach(fn=>fn(arg));};
 const ui={btn(label){return Object.assign(node('button'),{label});},avail(b,why,fix){b.reason=why;b.fix=why?fix||null:null;},actionBusy(b,on){b.disabled=on;},act(b,fn){b.click=async()=>b.reason||b.disabled?null:fn();},badge(label,kind){return node('badge',{kind},label);},
  toast(...x){toasts.push(x);},copy(v,m){copies.push(v);copyMsgs.push(m);},confirmDialog:async o=>{confirmations.push(o);return true;},
  field(label,ctl,hint){return node('label',{class:'fld'},node('span',{class:'fld-l'},label),ctl,hint?node('span',{class:'fld-h'},hint):null);},
  /* ui.seg: an unavailable option only explains itself (toast + fix); onPick decides and calls set() */
  seg(label,opts,onPick,o){const s={label,opts,cur:'',un:{},el:node('seg'),set(v){s.cur=v;},avail(v,reason,fix){if(reason)s.un[v]={reason,fix:fix||null};else delete s.un[v];},
   async pick(v){if(s.un[v]){toasts.push([s.un[v].reason,'warn']);return 'blocked';}if(s.cur===v){o?.onSame?.(v);return 'same';}await onPick(v);return 'picked';}};segs.push(s);return s;},
  modal(o){const d={o,body:o.body,actions:o.actions||[],setActions(a){d.actions=a;},close(v){if(d.closed)return;d.closed=true;o.onClose?.(v);}};modals.push(d);return d;}};
 const TP={S:{locked:false},h:node,ui,why:{helper:()=>''},clear:n=>{n.children=[];},setText:(n,v)=>{n.children=[String(v)];},on:(ev,fn)=>{(callbacks[ev]||=[]).push(fn);},emit,errMsg:e=>e.message||e.code||'error',mkErr:(kind,message)=>({kind,message}),
  helper:async(...args)=>{calls.push(args);return handler(...args);},plan:{load:(...a)=>{planLoads.push(a)}},fmt:{dateTime:String,clock:s=>'clock:'+s,date:s=>'date:'+s},auth:{logout:async(kind)=>{signIns.push(kind)}}};
 if(opts.tabs!==false)TP.settingsTab=id=>{tabs.push(id);};
 const document={hidden:false};const I={t:(k,args)=>k+(args?JSON.stringify(args):''),L:k=>k,has:k=>k.startsWith('billing.')};
 vm.runInNewContext(script,{window:{TP,I18N:I,crypto:'crypto' in opts?opts.crypto:crypto,qrcode:opts.qrcode},document,setInterval:(fn,ms)=>{intervals.set(++id,{fn,ms});return id},clearInterval:i=>intervals.delete(i),setTimeout:fn=>{timers.set(++id,fn);return id},clearTimeout:i=>timers.delete(i),console});
 return {B:TP.billing,TP,calls,modals,copies,copyMsgs,toasts,confirmations,timers,intervals,document,emit,signIns,planLoads,segs,tabs};
}
/* Press a dialog action the way ui.modal does: unavailable/disabled -> nothing; cancel -> close; otherwise run it and close unless it returned false or keeps the dialog. */
async function press(d,label){const a=d.actions.find(x=>x.label===label);assert.ok(a,'missing action '+label);if(a.unavail||a.disabled)return 'blocked';if(a.cancel){d.close('cancel');return 'cancel';}
 const r=a.onClick?await a.onClick(d):undefined;if(r!==false&&!a.keep)d.close(a.value!==undefined?a.value:true);return r;}
const flush=()=>new Promise(r=>setImmediate(r));
/* Arrays / objects created inside the sandbox (billing.js) have the sandbox's prototypes: spread them before a deepEqual. Nodes come from the fake h() and are ours. */
const posts=f=>f.calls.filter(c=>c[0]==='POST');
const switchOf=root=>{const s=flatten(root).find(n=>n.attrs?.role==='switch');assert.ok(s,'auto-renew switch');return s;};
const termCards=d=>flatten(d.body).filter(n=>n.tag==='label'&&cls(n).split(' ').includes('billing-term'));
const pickTerm=(d,sku)=>{const c=termCards(d).find(n=>n._item.id===sku);assert.ok(c,'term '+sku);c._inp.attrs.on.change();};

test('receiving disabled and unverified email independently block checkout; free account remains usable',async()=>{
 for(const s of [status({payments_available:false}),status({email:{verified:false,address:'u@example.test',mail_available:false}})]){
  const f=fixture(async()=>s),root=f.B.mount();await f.B.load(true);
  if(s.email.verified){
   assert.equal(find(root,'billing.buy').reason,'','prices and balance payment stay reachable while receiving is closed');
   assert.equal(find(root,'billing.topup').reason,'billing.unavailable');
   await find(root,'billing.buy').click();const seg=f.segs[0];
   assert.equal(seg.un.usdt.reason,'billing.unavailable');assert.equal(seg.cur,'wallet','the balance can still pay');
   assert.equal(await seg.pick('usdt'),'blocked');assert.equal(seg.cur,'wallet');assert.ok(!f.modals[0].actions.some(a=>a.label==='common.next'));
  }else{
   assert.equal(find(root,'billing.buy').reason,'billing.verifyFirst');await find(root,'billing.buy').click();assert.equal(f.modals.length,0);
   assert.equal(find(root,'billing.topup').reason,'billing.verifyFirst');assert.equal(switchOf(root).reason,'billing.verifyFirst');
   assert.ok(!flatten(root).some(n=>n.label==='billing.sendVerification'),'the verification block lives on the account tab only');
   const email=f.B.mountEmail();assert.equal(find(email,'billing.sendVerification').reason,'billing.mailUnavailable');
  }
  assert.equal(f.calls.length,1,'nothing but the status read was sent');
 }
});
test('unknown-result checkout retains request key and retry cannot create a second financial operation',async()=>{
 let writes=0,done;
 const f=fixture(async(m,p,o)=>{if(m==='GET')return status();writes++;if(writes===1)throw {code:'E_ACCOUNT_UNREACHABLE'};return new Promise(r=>{done=r});});
 const root=f.B.mount();await f.B.load(true);await find(root,'billing.buy').click();const pick=f.modals[0];
 assert.equal(await press(pick,'common.next'),false);assert.ok(!pick.closed,'a failed checkout keeps the dialog open');
 const retry=press(pick,'common.next');await Promise.resolve();
 assert.equal(await press(pick,'common.next'),false,'a click while the retry is in flight does nothing');assert.equal(writes,2);
 const body=posts(f).map(c=>JSON.parse(c[2].body));assert.equal(body[0].request_key,body[1].request_key);assert.equal(body[0].sku,'m1');assert.equal(body[0].kind,'plan');assert.ok(!('price' in body[0]));
 done({ok:true,order:invoice});await retry;
 assert.equal(pick.closed,true,'the picker closes before the invoice opens');assert.equal(f.modals.length,2);assert.ok(find(f.modals[1].body,'billing.copyAmount'));
});
test('the purchase dialog: every term with total, per-month price and saving, 12 months recommended and preselected, then the payment method',async()=>{
 const f=fixture(async(m)=>m==='GET'?status({catalog:CATALOG}):{ok:true});const root=f.B.mount();await f.B.load(true);
 assert.equal(byClass(root,'billing-price').length,0,'no always-visible price cards');
 await find(root,'billing.buy').click();const d=f.modals[0],seg=f.segs[0],cards=termCards(d);
 assert.equal(d.o.title,'billing.buy');assert.deepEqual(cards.map(c=>c._item.id),['m1','m3','m6','y1','y2','y3','y5']);
 const card=id=>cards.find(c=>c._item.id===id),texts=strings;
 assert.deepEqual(cards.filter(c=>cls(c).split(' ').includes('on')).map(c=>c._item.id),['y1']);assert.equal(card('y1')._inp.attrs.checked,true);
 assert.deepEqual(cards.filter(c=>texts(c).includes('billing.recommended')).map(c=>c._item.id),['y1']);
 assert.ok(texts(card('y1')).includes('35 USDT'));assert.ok(texts(card('y1')).includes('billing.perMonth{"amount":"2.92"}'));assert.ok(texts(card('m1')).includes('billing.perMonthExact{"amount":"4"}'));assert.ok(texts(card('y3')).includes('billing.perMonthExact{"amount":"2"}'));
 assert.deepEqual(cards.map(c=>texts(c).find(x=>x.startsWith('billing.save'))||''),['','billing.save{"pct":16}','billing.save{"pct":20}','billing.save{"pct":27}','billing.save{"pct":41}','billing.save{"pct":50}','billing.save{"pct":58}']);
 assert.deepEqual([...seg.opts].map(o=>o.v),['usdt','wallet']);assert.equal(seg.cur,'usdt');
 assert.deepEqual([...d.actions].map(a=>a.label),['common.cancel','common.next']);assert.equal(d.actions[1].kind,'primary');
 assert.equal(seg.un.wallet.reason,'billing.insufficientFor{"balance":"10","price":"35"}');assert.equal(seg.un.wallet.fix.label,'billing.topup');
 pickTerm(d,'m1');assert.equal(seg.un.wallet,undefined,'10 USDT covers one month');assert.deepEqual(cards.filter(c=>cls(c).split(' ').includes('on')).map(c=>c._item.id),['m1']);
 assert.equal(await seg.pick('wallet'),'picked');assert.equal(d.actions[1].label,'billing.confirmPay');
 pickTerm(d,'y1');assert.ok(d.actions[1].unavail,'balance too low for 12 months');assert.equal(await press(d,'billing.confirmPay'),'blocked');
 const note=flatten(d.body).find(n=>n.tag==='p'&&n.attrs['aria-live']==='polite');assert.equal(cls(note),'hint warn');assert.deepEqual(note.children,['billing.insufficientFor{"balance":"10","price":"35"}']);
 seg.un.wallet.fix.fn();assert.equal(d.closed,true);const tu=f.modals[1];assert.ok(tu.actions.some(a=>a.label==='billing.createInvoice'));assert.equal(flatten(tu.body).find(n=>n.tag==='input').value,'25','the top-up is prefilled with what is missing');
 assert.equal(posts(f).length,0);
 const pro=fixture(async()=>status({plan:{code:'pro',expires_at:now()+86400}})),r2=pro.B.mount();await pro.B.load(true);assert.ok(find(r2,'billing.renewPlan'));
});
test('invoice copies exactly the amount it shows; hidden pages pause polling; close stops every timer',async()=>{
 const f=fixture(async()=>({ok:true,order:invoice})),base=f.intervals.size;f.B.openOrder(invoice);const d=f.modals[0];
 await find(d.body,'billing.copyAmount').click();await find(d.body,'billing.copyAddress').click();assert.deepEqual(f.copies,['4.01',invoice.address]);
 assert.equal(textOf(flatten(d.body).find(n=>n.tag==='code'&&!n.attrs.class)),'4.01','the copied text is what is shown');
 assert.equal(f.copyMsgs[0],'billing.amountCopied{"amount":"4.01"}');assert.equal(f.copyMsgs[1],'billing.addrCopied{"head":"TMiyPt","tail":"oHR8RU"}');
 assert.equal(f.intervals.size,base+1,'one countdown');
 f.document.hidden=true;let task=[...f.timers.values()][0];f.timers.clear();await task();assert.equal(f.calls.length,0);
 f.document.hidden=false;task=[...f.timers.values()][0];f.timers.clear();await task();assert.equal(f.calls.length,1);
 d.close();assert.equal(f.timers.size,0);assert.equal(f.intervals.size,base);
});
test('invoice: what is bought, QR first, highlighted decimal tail and address ends, one ticking countdown to pay_by, footer with cancel and close only',async()=>{
 const qrSrc=fs.readFileSync(require('node:path').join(__dirname,'../ui/vendor/qrcode.js'),'utf8');const sandbox={};sandbox.window=sandbox;vm.createContext(sandbox);vm.runInContext(qrSrc,sandbox);
 const f=fixture(async()=>({ok:true,order:invoice}),{qrcode:sandbox.qrcode}),base=new Set(f.intervals.keys());f.B.openOrder(invoice);const d=f.modals[0],kids=d.body.children;
 assert.equal(textOf(kids[0].children[0]),'billing.inv.plan{"term":"billing.term.m1"}');assert.equal(textOf(kids[0].children[1]),'billing.orderMeta{"id":"abcdefghijklmno","time":"'+invoice.created_at+'"}');
 const at=c=>kids.findIndex(n=>cls(n)===c),exact=kids.map((n,i)=>cls(n)==='billing-exact'?i:-1).filter(i=>i>=0);
 assert.ok(at('billing-qr')>0&&at('billing-qr')<exact[0],'QR before the amount');assert.ok(textOf(kids[exact[0]]).startsWith('billing.exactAmount'));assert.ok(textOf(kids[exact[1]]).startsWith('billing.address'));
 assert.ok(at('hint warn')<exact[0]&&textOf(kids[at('hint warn')])==='billing.exactNote','the exact-amount note sits right above the amount it describes');
 assert.deepEqual(byClass(d.body,'amt-tail').map(textOf),['.01']);assert.deepEqual(byClass(d.body,'addr-hl').map(textOf),['TMiyPt','oHR8RU']);
 assert.equal(textOf(byClass(d.body,'billing-addr')[0]),invoice.address);
 const cds=byClass(d.body,'billing-cd');assert.equal(cds.length,1);assert.match(textOf(cds[0]),/^billing\.countdown\{"time":"5[89]:\d\d","at":"clock:\d+"\}$/,'mm:ss left until pay_by and the clock time');assert.ok(!JSON.stringify(d.body).includes('leaseLeft'),'no second countdown');
 const tick=[...f.intervals.entries()].find(([k])=>!base.has(k));assert.equal(tick[1].ms,1000);
 cds[0].children=['stale'];tick[1].fn();assert.ok(textOf(cds[0]).startsWith('billing.countdown'),'the countdown text is refreshed every second');assert.equal(byClass(d.body,'billing-cd')[0],cds[0],'without rebuilding the dialog');
 assert.deepEqual([...d.actions].map(a=>a.label),['billing.cancelInvoice','common.close']);assert.equal(d.actions[0].kind,'soft-bad');assert.equal(d.actions[0].cls,'billing-cancel');
 const st=byClass(d.body,'billing-inv-st')[0];assert.ok(find(st,'billing.recheck'),'Check again sits next to the status line');assert.ok(flatten(st).some(n=>n.attrs?.role==='status'&&n.children[0]==='billing.status.pending'));
 d.close();assert.equal(f.intervals.size,base.size);
});
test('paid status only follows cloud order response and cancellation invalidates an older poll',async()=>{
 let resolvePoll;
 const f=fixture(async(m,p)=>{if(p==='/api/billing')return status();if(p==='/api/billing/order')return new Promise(r=>resolvePoll=r);if(p==='/api/billing/cancel')return {ok:true,order:{...invoice,status:'cancelled'}};});
 await f.B.load(true);const base=f.intervals.size;f.B.openOrder(invoice);const d=f.modals[0],poll=[...f.timers.values()][0];f.timers.clear();const run=poll();await Promise.resolve();
 const cancel=d.actions.find(a=>a.label==='billing.cancelInvoice');await cancel.onClick();resolvePoll({ok:true,order:invoice});await run;
 assert.equal(f.confirmations[0].danger,true,'cancel asks first');
 assert.ok(flatten(d.body).some(n=>n.attrs?.role==='status'&&n.children.includes('billing.status.cancelled')));
 assert.equal(f.timers.size,0);assert.equal(f.intervals.size,base,'the countdown stops after cancelling');assert.deepEqual([...d.actions].map(a=>a.label),['common.close']);
});
test('closed and past-deadline invoices retain history but cannot encourage another transfer',async()=>{
 const t=now();
 for(const o of [{...invoice,status:'cancelled'},{...invoice,status:'paid'},{...invoice,pay_by:t-1},{...invoice,pay_by:t-90000,expires_at:t-1}]){
  const f=fixture(async()=>({ok:true,order:o}),{qrcode:()=>{throw Error('no QR for a closed invoice')}});f.B.openOrder(o);const d=f.modals[0];
  assert.equal(find(d.body,'billing.copyAmount').reason,'billing.invoiceClosed');
  assert.equal(find(d.body,'billing.copyAddress').reason,'billing.invoiceClosed');
  assert.equal(byClass(d.body,'billing-cd').length,0,'no countdown');
  await find(d.body,'billing.copyAmount').click();assert.equal(f.copies.length,0);d.close();
 }
 const late={...invoice,pay_by:t-1},f=fixture(async()=>({ok:true,order:late}));f.B.openOrder(late);const d=f.modals[0];
 assert.ok(flatten(d.body).some(n=>n.tag==='p'&&n.children.includes('billing.overdueNote')),'after pay_by: do not pay any more, Check again if you already did');
 assert.ok(flatten(d.body).some(n=>n.attrs?.role==='status'&&n.children[0]==='billing.status.overdue'));assert.equal(find(d.body,'billing.recheck').reason,'','the lease is still open, so it can be checked again');
});
test('logout discards a late status response and closes invoices before another account can see them',async()=>{
 let done;const f=fixture(()=>new Promise(r=>{done=r}));const root=f.B.mount(),load=f.B.load(true),base=f.intervals.size;f.B.openOrder(invoice);f.emit('auth',false);done(status());await load;
 assert.equal(f.modals[0].closed,true);assert.ok(!JSON.stringify(root).includes('one@example.test'));assert.equal(f.timers.size,0);assert.equal(f.intervals.size,base,'the invoice countdown is gone too');
});
test('wallet purchase and automatic renewal disclose the debit before sending it; decimal remainder stays visible',async()=>{
 const f=fixture(async(m,p)=>m==='GET'?status({wallet:{balance:'10.000037',auto_renew:false,monthly_price:'4.000000'}}):p==='/api/billing/auto-renew'?{ok:true,auto_renew:true,charged:true,needs_topup:false,balance:'6.000037',monthly_price:'4.000000'}:{ok:true,expires_at:1900000000});
 const root=f.B.mount();await f.B.load(true);
 await find(root,'billing.buy').click();const d=f.modals[0],seg=f.segs[0];assert.equal(await seg.pick('wallet'),'picked');
 const note=flatten(d.body).find(n=>n.tag==='p'&&n.attrs['aria-live']==='polite');assert.deepEqual(note.children,['billing.purchaseConfirm{"amount":"4","term":"billing.term.m1","balance":"10.000037"}']);
 assert.equal(posts(f).length,0,'nothing is sent before Confirm payment');
 assert.equal(await press(d,'billing.confirmPay'),true);const purchase=f.calls.find(c=>c[1]==='/api/billing/purchase');assert.equal(JSON.parse(purchase[2].body).sku,'m1');assert.equal(d.closed,true);
 assert.ok(f.toasts.some(x=>x[0]==='billing.purchasedUntil{"term":"billing.term.m1","date":"date:1900000000"}'&&x[1]==='ok'));
 await flush();
 const sw=switchOf(root);assert.equal(sw.attrs['aria-checked'],'false');assert.ok(strings(sw).includes('billing.renewOffState'));
 await sw.click();assert.ok(f.confirmations[0].message.startsWith('billing.renewConfirm'));assert.ok(f.confirmations[0].message.includes('"price":"4"'),'the price comes from wallet.monthly_price');
 assert.equal(JSON.parse(f.calls.find(c=>c[1]==='/api/billing/auto-renew')[2].body).enabled,true);assert.ok(f.toasts.some(x=>x[0]==='billing.renewCharged{"price":"4"}'&&x[1]==='ok'));
 assert.ok(flatten(root).some(n=>n.tag==='strong'&&n.children.some(s=>String(s).includes('10.000037'))));
});
test('turning on auto-renewal with less than a month of balance explains that nothing is charged: Top up first / Turn on anyway / Cancel',async()=>{
 const reply={ok:true,auto_renew:true,charged:false,needs_topup:true,balance:'0.000000',monthly_price:'5.000000'};
 const f=fixture(async(m)=>m==='GET'?status({wallet:{balance:'0.000000',auto_renew:false,monthly_price:'5.000000'}}):reply);const root=f.B.mount();await f.B.load(true);
 let run=switchOf(root).click(),d=f.modals[0];
 assert.deepEqual([...d.actions].map(a=>a.label),['common.cancel','billing.renewAnyway','billing.topupFirst']);assert.equal(d.actions[2].kind,'primary');
 assert.ok(strings(d.body).includes('billing.renewLow{"balance":"0","price":"5"}'));assert.equal(f.confirmations.length,0);
 await press(d,'billing.topupFirst');await run;assert.equal(f.modals.length,2);assert.equal(flatten(f.modals[1].body).find(n=>n.tag==='input').value,'5','Top up first opens the top-up');assert.equal(posts(f).length,0);
 run=switchOf(root).click();await press(f.modals[2],'common.cancel');await run;assert.equal(posts(f).length,0,'Cancel sends nothing');
 run=switchOf(root).click();await press(f.modals[3],'billing.renewAnyway');await run;
 assert.deepEqual(JSON.parse(posts(f)[0][2].body),{enabled:true});assert.ok(f.toasts.some(x=>x[0]==='billing.renewWaiting{"price":"5"}'&&x[1]==='warn'),'enabled; renews once the balance is enough');
});
test('a whole amount has no decimal tail to highlight, so the note does not mention red decimals',async()=>{
 const whole={...invoice,amount:'4.000000'};const f=fixture(async()=>({ok:true,order:whole}));f.B.openOrder(whole);const d=f.modals[0],kids=d.body.children;
 assert.equal(textOf(kids.find(n=>cls(n)==='hint warn')),'billing.exactNoteWhole');assert.deepEqual(byClass(d.body,'amt-tail'),[],'nothing to highlight');
 assert.ok(textOf(kids.find(n=>cls(n)==='billing-exact')).includes('4'),'the amount is still shown');
});
test('top-up takes whole USDT 4..1000 in a proper field with inline validation and preset chips',async()=>{
 const f=fixture(async(m)=>m==='GET'?status():{ok:true,order:{...invoice,kind:'topup',sku:'',price:'20.000000',amount:'20.100000'}});const root=f.B.mount();await f.B.load(true);
 await find(root,'billing.topup').click();const d=f.modals[0],input=flatten(d.body).find(n=>n.tag==='input'),msg=byClass(d.body,'billing-tu-msg')[0];
 assert.equal(input.attrs.class,'inp');assert.equal(input.attrs.inputmode,'numeric');assert.ok(flatten(d.body).some(n=>n.tag==='label'&&n.attrs.class==='fld'&&n.children.includes(input)));
 assert.deepEqual([...d.actions].map(a=>a.label),['common.cancel','billing.createInvoice']);assert.deepEqual(msg.children,['billing.topupRange']);
 for(const [v,key] of [['10.5','billing.topupWhole'],['4.000001','billing.topupWhole'],['abc','billing.topupWhole'],['3','billing.topupOut'],['0','billing.topupOut'],['1001','billing.topupOut'],['','billing.topupEmpty']]){
  input.value=v;assert.equal(await press(d,'billing.createInvoice'),false,v);assert.deepEqual(msg.children,[key],v);assert.equal(cls(msg),'billing-tu-msg bad');assert.equal(input.attrs['aria-invalid'],'true');
 }
 assert.equal(posts(f).length,0,'invalid amounts never reach the helper');assert.equal(f.toasts.length,0,'validation is inline, not a toast');
 const chips=flatten(d.body).filter(n=>n.tag==='button'&&cls(n).includes('billing-chip'));assert.deepEqual(chips.map(textOf),['10 USDT','20 USDT','50 USDT','100 USDT']);
 chips[2].attrs.on.click();assert.equal(input.value,'50');assert.equal(cls(chips[2]),'chip billing-chip on');assert.deepEqual(msg.children,['billing.topupRange']);
 input.value='\uFF10\uFF12\uFF10';assert.equal(await press(d,'billing.createInvoice'),false);
 assert.deepEqual({...JSON.parse(posts(f)[0][2].body),request_key:'k'},{kind:'topup',amount:'20',request_key:'k'},'full-width digits and a leading zero become "20"');
 assert.equal(d.closed,true);assert.ok(strings(f.modals[1].body).includes('billing.inv.topup{"amount":"20"}'));
});
test('the 24-hour order limit is explained with the time a new order is possible again',async()=>{
 let data={ok:false,code:'E_ORDER_LIMIT',limit:5,retry_after:5400};
 const f=fixture(async(m)=>{if(m==='GET')return status();throw {code:'E_ORDER_LIMIT',data};});const root=f.B.mount();await f.B.load(true);
 await find(root,'billing.buy').click();const before=now();assert.equal(await press(f.modals[0],'common.next'),false);
 const text=f.toasts.find(x=>x[1]==='err')[0],args=JSON.parse(text.slice('billing.err.E_ORDER_LIMIT'.length)),at=+/clock:(\d+)$/.exec(args.time)[1];
 assert.ok(text.startsWith('billing.err.E_ORDER_LIMIT{'));assert.equal(args.n,5);assert.equal(at%60,0,'rounded to a whole minute');assert.ok(at>=before+5400&&at<=now()+5400+60,'never earlier than the server allows');
 data={ok:false,code:'E_ORDER_LIMIT',retry_after:'soon'};await press(f.modals[0],'common.next');assert.ok(f.toasts.some(x=>x[0]==='billing.orderLimitLater{"n":5}'),'no usable retry_after: a plain "try later"');
});
test('pay_by, not the 24-hour lease, decides whether an order still blocks new payments; the notice clears when pay_by passes',async()=>{
 const t=now(),late={...invoice,pay_by:t-5,expires_at:t+80000};
 const f=fixture(async()=>status({orders:[late]})),root=f.B.mount();await f.B.load(true);
 assert.ok(!hasText(root,'billing.notice.pending'));assert.equal(find(root,'billing.topup').reason,'');
 assert.ok(flatten(root).some(n=>n.tag==='badge'&&n.children[0]==='billing.st.overdue'&&n.attrs.kind==='warn'));
 const soon={...invoice,pay_by:now()+2},g=fixture(async()=>status({orders:[soon]})),r2=g.B.mount(),tickAll=[...g.intervals.values()][0];await g.B.load(true);
 assert.ok(hasText(r2,'billing.notice.pending{"amount":"4.01","time":"clock:'+soon.pay_by+'"}'));assert.equal(find(r2,'billing.topup').reason,'billing.pendingFirst');
 await new Promise(r=>setTimeout(r,2100));tickAll.fn();
 assert.ok(!hasText(r2,'billing.notice.pending'),'gone once pay_by has passed');assert.equal(find(r2,'billing.topup').reason,'');
});
test('recent orders: a compact table, 10 per page from the server, a previous/next pager that is hidden on a single page',async()=>{
 const mk=i=>({...invoice,id:'o'+String(i).padStart(14,'0'),status:i===0?'paid':'cancelled',created_at:1700000000-i*60});
 let total=23;const f=fixture(async(m,p,o)=>{const page=o.q.orders_page,per=o.q.orders_per_page,all=Array.from({length:total},(_,i)=>mk(i));return status({orders:all.slice((page-1)*per,page*per),orders_total:total,orders_page:page,orders_per_page:per});});
 const root=f.B.mount();await f.B.load(true);assert.deepEqual({...f.calls[0][2].q},{orders_page:1,orders_per_page:10});
 const table=()=>flatten(root).find(n=>n.tag==='table'&&cls(n).split(' ').includes('rt'));
 assert.deepEqual(flatten(table()).filter(n=>n.tag==='th').map(textOf),['billing.col.item','billing.col.amount','billing.col.status','billing.col.time','billing.col.view']);
 const rows=()=>flatten(table()).filter(n=>n.tag==='tr').slice(1);assert.equal(rows().length,10);
 const first=rows()[0].children;assert.equal(textOf(first[0]),'billing.what.plan{"term":"billing.term.m1"}');assert.equal(textOf(first[1]),'4.01 USDT');assert.equal(first[2].children[0].tag,'badge');assert.equal(first[2].children[0].children[0],'billing.st.paid');assert.ok(find(first[4],'billing.view'));
 assert.equal(find(root,'pager.prev').reason,'billing.pageFirst');assert.ok(hasAny(root,'billing.pageOf{"page":1,"pages":3}'));
 await find(root,'pager.next').click();assert.deepEqual({...f.calls.at(-1)[2].q},{orders_page:2,orders_per_page:10});assert.ok(hasAny(root,'billing.pageOf{"page":2,"pages":3}'));
 await find(root,'pager.next').click();assert.equal(rows().length,3);assert.equal(find(root,'pager.next').reason,'billing.pageLast');
 await find(rows()[0].children[4],'billing.view').click();assert.equal(f.modals.length,1);
 total=4;await f.B.load(true);assert.equal(f.calls.at(-1)[2].q.orders_page,3,'a reload keeps the page');await find(root,'pager.prev').click();
 assert.equal(byClass(root,'billing-pg').length,0,'one page: no pager');assert.equal(rows().length,4);
});
test('wallet activity: trimmed signed amounts, the first 10 rows, then Show more',async()=>{
 const ledger=Array.from({length:12},(_,i)=>({id:'l'+i,kind:i%2?'auto_renew':'deposit',delta:i%2?'-4.000000':'35.100000',balance_after:'1.000000',created_at:1700000000-i}));
 const f=fixture(async()=>status({ledger})),root=f.B.mount();await f.B.load(true);
 const sec=byClass(root,'billing-sec')[1],rows=()=>flatten(byClass(root,'billing-sec')[1]).filter(n=>n.tag==='tr').slice(1);
 assert.equal(rows().length,10);assert.deepEqual(rows().slice(0,2).map(r=>textOf(r.children[1])),['+35.1 USDT','-4 USDT']);assert.deepEqual(rows().slice(0,2).map(r=>textOf(r.children[0])),['billing.ledger.deposit','billing.ledger.auto_renew']);
 await find(sec,'billing.showMore').click();assert.equal(rows().length,12);assert.ok(!flatten(root).some(n=>n.label==='billing.showMore'));
});
test('mail sends only the current authenticated account and ignores repeat clicks in cooldown',async()=>{
 const f=fixture(async(m)=>m==='GET'?status({email:{verified:false,address:'u@example.test',mail_available:true}}):{ok:true,sent:true,retry_after:60});const root=f.B.mountEmail();await f.B.load(true);
 await find(root,'billing.sendVerification').click();await find(root,'billing.sendVerification').click();const sent=f.calls.filter(c=>c[1]==='/api/email/send');assert.equal(sent.length,1);assert.deepEqual(JSON.parse(sent[0][2].body),{});
});

const texts=root=>flatten(root).filter(n=>typeof n==='string'||n?.tag==='p').flatMap(n=>typeof n==='string'?[n]:n.children.filter(c=>typeof c==='string'));
const hasText=(root,key)=>texts(root).some(x=>x.startsWith(key));
test('every blocked state is explained by a persistent inline notice next to the buttons, not only by dimming plus a toast',async()=>{
 const cases=[
  [status({payments_available:false}),'billing.notice.closed',null],
  [status({email:{verified:false,address:'u@example.test',mail_available:true}}),'billing.notice.verify','plan.verifyGo'],
  [status({email:{verified:false,address:'u@example.test',mail_available:false}}),'billing.notice.verifyNoMail','billing.checkAgain'],
 ];
 for(const [s,key,action] of cases){
  const f=fixture(async()=>s),root=f.B.mount();await f.B.load(true);
  assert.ok(hasText(root,key),'missing notice '+key);
  assert.ok(flatten(root).some(n=>n.attrs?.role==='status'&&String(n.attrs.class).split(' ').includes('billing-notice')),'notice is a status region');
  assert.deepEqual(f.toasts,[],'no toast is needed to learn the reason');
  if(action==='plan.verifyGo'){await find(root,action).click();assert.deepEqual(f.tabs,['account'],'verification happens on the account tab');}
  if(action==='billing.checkAgain'){await find(root,action).click();assert.equal(f.calls.length,2,'Check again re-reads the status');}
 }
 const noTab=fixture(async()=>cases[1][0],{tabs:false}),r0=noTab.B.mount();await noTab.B.load(true);assert.ok(hasText(r0,'billing.notice.verify'));assert.ok(!flatten(r0).some(n=>n.label==='plan.verifyGo'),'no dead button without the settings page');
 const open=fixture(async()=>status()),r=open.B.mount();await open.B.load(true);
 assert.ok(!flatten(r).some(n=>String(n.attrs?.class||'').split(' ').includes('billing-notice')),'a fully usable account sees no blocker notice');
 assert.equal(find(r,'billing.buy').reason,'');assert.equal(find(r,'billing.topup').reason,'');assert.equal(switchOf(r).reason,'');
});
test('without SMTP the send button explains itself and Check again recovers once mail is switched on',async()=>{
 let mail=false;
 const f=fixture(async()=>status({email:{verified:false,address:'u@example.test',mail_available:mail}})),root=f.B.mountEmail();await f.B.load(true);
 assert.equal(find(root,'billing.sendVerification').reason,'billing.mailUnavailable');assert.ok(hasText(root,'billing.mailOffNote'));
 mail=true;await find(root,'billing.checkAgain').click();
 assert.equal(find(root,'billing.sendVerification').reason,'');assert.ok(hasText(root,'billing.verifyNote'));
});
test('verifying the email makes the dashboard re-read the plan at once (official routes move from "verify" to available)',async()=>{
 let verified=false;
 const f=fixture(async()=>status({email:{verified,address:'u@example.test',mail_available:true}})),root=f.B.mountEmail();await f.B.load(true);
 assert.equal(f.planLoads.length,0);await f.B.load(true);assert.equal(f.planLoads.length,0,'still unverified: nothing to re-read');
 verified=true;await find(root,'billing.checkVerification').click();assert.deepEqual(f.planLoads,[[true]]);
 await f.B.load(true);assert.equal(f.planLoads.length,1,'only the unverified -> verified transition triggers it');
});
test('an unfinished invoice is announced with an action that opens it; payment buttons stay blocked meanwhile',async()=>{
 const f=fixture(async()=>status({orders:[invoice]})),root=f.B.mount();await f.B.load(true);
 assert.ok(hasText(root,'billing.notice.pending'));assert.equal(find(root,'billing.topup').reason,'billing.pendingFirst');assert.equal(find(root,'billing.topup').fix.label,'billing.viewPending');
 await find(root,'billing.viewPending').click();assert.equal(f.modals.length,1);assert.ok(find(f.modals[0].body,'billing.copyAmount'));
 await find(root,'billing.buy').click();const seg=f.segs[0];assert.equal(seg.un.usdt.reason,'billing.pendingFirst');assert.equal(seg.un.usdt.fix.label,'billing.viewPending');
 assert.equal(seg.cur,'wallet','10 USDT still buys from the balance meanwhile');pickTerm(f.modals[1],'m3');assert.equal(f.modals[1].actions[1].label,'billing.confirmPay');assert.equal(f.modals[1].actions[1].unavail,null,'exactly 10 USDT covers 3 months');
});
test('a revoked cloud session is explained as sign-in expiry with a sign-in-again action, not as a network outage',async()=>{
 const f=fixture(async()=>{throw {code:'E_AUTH',message:'x'}}),root=f.B.mount();await f.B.load(true);
 assert.ok(hasText(root,'billing.err.E_AUTH'));await find(root,'billing.signInAgain').click();assert.deepEqual(f.signIns,['switch']);
 const net=fixture(async()=>{throw {code:'E_SERVER_ERROR',message:'x'}}),r2=net.B.mount();await net.B.load(true);
 assert.ok(hasText(r2,'billing.err.E_SERVER_ERROR'));assert.ok(!hasText(r2,'billing.err.E_ACCOUNT_UNREACHABLE'));
});
test('the idempotency key survives a browser without crypto.randomUUID (or without crypto at all)',async()=>{
 for(const c of [{},{getRandomValues:a=>crypto.getRandomValues(a)},undefined]){
  const f=fixture(async(m)=>m==='GET'?status():{ok:true,order:invoice},{crypto:c}),root=f.B.mount();await f.B.load(true);
  await find(root,'billing.buy').click();await press(f.modals[0],'common.next');const post=f.calls.find(x=>x[0]==='POST');
  assert.ok(post,'checkout still sends');assert.match(JSON.parse(post[2].body).request_key,/^[A-Za-z0-9_-]{16,80}$/);
 }
});
test('payable invoice shows a QR code of the receive address (vendored library, inline SVG)',()=>{
 const qrSrc=fs.readFileSync(require('node:path').join(__dirname,'../ui/vendor/qrcode.js'),'utf8');
 const sandbox={};sandbox.window=sandbox;vm.createContext(sandbox);vm.runInContext(qrSrc,sandbox);
 const f=fixture(async()=>({ok:true,order:invoice}),{qrcode:sandbox.qrcode});
 f.B.openOrder(invoice);const d=f.modals[0];
 const box=flatten(d.body).find(n=>n.attrs&&n.attrs.class==='billing-qr');
 assert.ok(box,'a payable invoice should render the QR box');
 assert.match(box.innerHTML,/^<svg/);
});
