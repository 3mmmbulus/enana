'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const D=require('../server/pb_hooks/enana_billing_domain.js');
const T=require('../server/payments/tron.js'),{TronGrid}=require('../server/payments/provider.js'),{Scanner}=require('../server/payments/scanner.js');
const address=T.encodeAddress('11'.repeat(20)),other=T.encodeAddress('22'.repeat(20)),id='a'.repeat(64),M=1000000;
function receipt(logs){return {id,receipt:{result:'SUCCESS'},blockNumber:100,blockTimeStamp:1700000000123,log:logs||[{address:T.decodeAddress(T.USDT).subarray(1).toString('hex'),topics:[T.TRANSFER,'0'.repeat(24)+'22'.repeat(20),'0'.repeat(24)+'11'.repeat(20)],data:(4000123n).toString(16).padStart(64,'0')}]}}
test('catalog prices and decimal money cannot be supplied as floating point or forged',()=>{
 assert.deepEqual(D.SKUS.map(s=>[s.months,s.price]),[[1,4000000],[3,10000000],[6,19000000],[12,35000000],[24,56000000],[36,72000000],[60,100000000]]);
 assert.equal(D.quoteBase({kind:'plan',sku:'m1',price:1,months:999}).price,4000000);
 for(const bad of [4,4.01,'3.999999','1000.000001','4e0','4.0000001','04','-4','Infinity','NaN'])assert.throws(()=>D.amount(bad));
 assert.equal(D.amount('1000'),1000000000);assert.equal(D.format(4000001),'4.000001');
 assert.throws(()=>D.quoteBase({kind:'plan',sku:'forged'}));assert.throws(()=>D.format(Number.MAX_SAFE_INTEGER+1));
});
test('top-ups are whole USDT from 4 to 1000; decimals, signs, padding and other types are refused',()=>{
 assert.deepEqual(['4','5','10','99','100','999','1000'].map(D.amount),[4,5,10,99,100,999,1000].map(n=>n*M));
 for(const bad of ['3','0','1001','9999','10000','4.0','4.5','4.000001','10.01','04','004','+4','-4',' 4','4 ','4\n','','1e3','0x10','\uff14',4,10,null,undefined,true,{},['10']])assert.throws(()=>D.amount(bad),/invalid_amount/,String(bad));
 assert.deepEqual(D.quoteBase({kind:'topup',amount:'25',price:1}),{kind:'topup',sku:'',months:0,price:25*M});
 assert.throws(()=>D.quoteBase({kind:'topup',amount:'25.5'}),/invalid_amount/);
 assert.deepEqual(D.SKUS.map(s=>D.quoteBase({kind:'plan',sku:s.id}).price),[4,10,19,35,56,72,100].map(n=>n*M),'plan prices are unchanged');
});
test('calendar month renewal clamps month end and preserves UTC time',()=>{
 for(const [start,n,end] of [['2024-01-31T08:09:10Z',1,'2024-02-29T08:09:10Z'],['2025-01-31T08:09:10Z',1,'2025-02-28T08:09:10Z'],['2024-02-29T08:09:10Z',12,'2025-02-28T08:09:10Z']])assert.equal(D.addMonths(Date.parse(start)/1000,n),Date.parse(end)/1000);
});
test('TRON addresses require Base58Check, mainnet prefix and uniqueness',()=>{
 assert.equal(T.decodeAddress(address).toString('hex'),'41'+'11'.repeat(20));
 assert.deepEqual(T.validateAddresses([address,other]),[address,other]);
 assert.throws(()=>T.decodeAddress(address.slice(0,-1)+(address.endsWith('1')?'2':'1')));
 assert.throws(()=>T.validateAddresses([address,address]));assert.throws(()=>T.validateAddresses([]));
});
test('only solidified successful USDT Transfer logs to the receive pool settle',()=>{
 const r=receipt();assert.deepEqual(T.receiptTransfers(r,id,100,[address]),[{event_key:id+':0',address,amount:4000123,chain_at:1700000000}]);
 assert.throws(()=>T.receiptTransfers(r,id,99,[address]));assert.throws(()=>T.receiptTransfers({...r,id:'b'.repeat(64)},id,100,[address]));
 assert.throws(()=>T.receiptTransfers({...r,receipt:{result:'REVERT'}},id,100,[address]));
 for(const log of [{...r.log[0],address:'ff'.repeat(20)},{...r.log[0],data:'ff'.repeat(32)},{...r.log[0],data:'00'.repeat(32)},{...r.log[0],topics:[T.TRANSFER,r.log[0].topics[1],'0'.repeat(24)+'33'.repeat(20)]}])assert.deepEqual(T.receiptTransfers(receipt([log]),id,100,[address]),[]);
 assert.deepEqual(T.receiptTransfers(receipt([{...r.log[0],address:'ff'.repeat(20)},r.log[0],r.log[0]]),id,100,[address]).map(x=>x.event_key),[id+':1',id+':2']);
});
test('pagination never follows an indexer URL with a secret header; HTTP bodies stay private',async()=>{
 const calls=[],p=new TronGrid('test-secret',{fetchImpl:async(url,opts)=>{calls.push([url.href,opts.headers]);return new Response(JSON.stringify(calls.length===1?{data:[],meta:{fingerprint:'opaque',links:{next:'https://attacker.invalid/steal'}}}:{data:[],meta:{}}))}});
 await p.transactions(address,1000,async()=>{});assert.equal(calls.length,2);assert.ok(calls.every(x=>x[0].startsWith('https://api.trongrid.io/')));assert.ok(calls[1][0].includes('fingerprint=opaque'));
 await assert.rejects(()=>p.request('https://attacker.invalid/'),/unsafe_provider_url/);
 const bad=new TronGrid('test-secret',{fetchImpl:async()=>new Response('private upstream details',{status:403})});await assert.rejects(()=>bad.solidHeight(),e=>e.message==='provider_http'&&!e.message.includes('private'));
});
test('API daily budget survives a worker restart',async()=>{
 let usage;const opts={budget:1,onUsage:u=>{usage=u},fetchImpl:async()=>new Response('{"block_header":{"raw_data":{"number":10}}}')};
 await new TronGrid('test-secret',opts).solidHeight();await assert.rejects(()=>new TronGrid('test-secret',{...opts,usage}).solidHeight(),/provider_budget_exhausted/);
});
test('crash after one log acknowledgement replays remaining logs without losing funds',async()=>{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'enana-scanner-test-'));let fail=true,calls=[];
 const config={addresses:[address],provider_key:'test',scanner_secret:'x'.repeat(40)};
 const provider={transactions:async(a,since,cb)=>cb([{transaction_id:id}]),receipt:async()=>receipt([receipt().log[0],receipt().log[0]])};
 const fetchImpl=async(url,opts)=>{const b=JSON.parse(opts.body);calls.push(b.event_key);if(fail&&b.event_key.endsWith(':1'))return new Response('{"ok":false}',{status:503});return new Response('{"ok":true}')};
 const opts={provider,fetchImpl,stateFile:path.join(dir,'state.json')};
 try {await assert.rejects(()=>new Scanner(config,opts).scan(address,100));assert.equal(JSON.parse(fs.readFileSync(opts.stateFile)).seen[id],undefined);fail=false;await new Scanner(config,opts).scan(address,100);assert.deepEqual(calls,[id+':0',id+':1',id+':0',id+':1']);assert.equal(JSON.parse(fs.readFileSync(opts.stateFile)).seen[id],true)}finally{fs.rmSync(dir,{recursive:true,force:true})}
});
test('partial pagination and missing receipts cannot mark a scan complete',async()=>{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'enana-scanner-test-'));const config={addresses:[address],provider_key:'test',scanner_secret:'x'.repeat(40)};
 try {const s=new Scanner(config,{stateFile:path.join(dir,'state.json'),provider:{transactions:async(a,t,cb)=>{await cb([{transaction_id:id}]);throw Error('provider_page_limit')},receipt:async()=>({})}});await assert.rejects(()=>s.scan(address,100),/receipt_pending/);assert.equal(s.state.last[address],undefined);assert.equal(s.state.seen[id],undefined)}finally{fs.rmSync(dir,{recursive:true,force:true})}
});

// ---- payment product rules (2.3.16 spec; tails and order limit 2.3.25) ----
const T0=1700000000;
// Book n orders the way checkout does: each amount allocate() hands out becomes a held 24-hour lease.
function fill(price,addrs,n){const held=[],out=[];for(let i=0;i<n;i++){const s=D.allocate(price,addrs,held,T0);out.push(s);held.push({address:s.address,amount:s.amount,lease_until:T0+D.LEASE,status:'pending'})}return {held,out}}
test('allocation: integer price while any address is free; tails only when every address holds that price',()=>{
 const addrs=['A','B'];
 assert.deepEqual(D.allocate(10*M,addrs,[],T0),{address:'A',amount:10*M,tail:0});
 const one=[{address:'A',amount:10*M,lease_until:T0+100,status:'pending'}];
 assert.deepEqual(D.allocate(10*M,addrs,one,T0),{address:'B',amount:10*M,tail:0});
 const both=[...one,{address:'B',amount:10*M,lease_until:T0+100,status:'pending'}];
 assert.deepEqual(D.allocate(10*M,addrs,both,T0),{address:'A',amount:10*M+100000,tail:1},'the first tail is +0.1, on the first address');
});
test('tails: +0.1..+0.9, then two decimals without whole tenths, then three decimals without whole hundredths; 999 in all',()=>{
 assert.equal(D.TAIL_MAX,999);assert.equal(D.TAILS.length,999);assert.equal(new Set(D.TAILS).size,999,'no tail is offered twice');
 assert.deepEqual(D.TAILS.slice(0,9),[1,2,3,4,5,6,7,8,9].map(k=>k*100000));
 assert.deepEqual(D.TAILS.slice(9,19),[1,2,3,4,5,6,7,8,9,11].map(k=>k*10000),'+0.10 is skipped: it equals +0.1');
 assert.equal(D.TAILS.indexOf(200000),1);assert.equal(D.TAILS.indexOf(20000),10);
 const two=D.TAILS.slice(9,99),three=D.TAILS.slice(99);
 assert.equal(two.length,90);assert.ok(two.every(n=>n%10000===0&&n%100000!==0&&n<1000000),'two-decimal tails are never whole tenths');
 assert.equal(three.length,900);assert.ok(three.every(n=>n%1000===0&&n%10000!==0&&n<1000000),'three-decimal tails are never whole hundredths');
 assert.deepEqual([two[0],two[89],three[0],three[1],three[9],three[899]],[10000,990000,1000,2000,11000,999000]);
 assert.equal(D.TAIL_SPAN,999000);assert.equal(Math.max(...D.TAILS),D.TAIL_SPAN,'every slot of a price lies in [price, price + 0.999]');
 assert.ok(D.TAILS.every(n=>n%1000===0),'never more than three decimals');
});
test('allocation: the tail is the outer loop and the address the inner one; capacity is 1000 amounts per address, then E_QUOTE_CAPACITY',()=>{
 const one=fill(10*M,['A'],1000).out.map(s=>s.amount-10*M);
 assert.deepEqual(one.slice(0,12),[0,100000,200000,300000,400000,500000,600000,700000,800000,900000,10000,20000],'base, +0.1 ... +0.9, then +0.01');
 assert.equal(one[19],110000,'+0.10 is skipped: after +0.09 comes +0.11');
 assert.equal(one[99],990000);assert.equal(one[100],1000,'after +0.99 the first three-decimal tail +0.001');
 assert.equal(one[999],999000,'the last slot is +0.999');assert.equal(new Set(one).size,1000,'every amount is unique');
 assert.ok(one.every(n=>n>=0&&n<1000000&&n%1000===0),'never a units digit, never more than three decimals');
 assert.throws(()=>D.allocate(10*M,['A'],fill(10*M,['A'],1000).held,T0),/E_QUOTE_CAPACITY/);
 const ten=['A1','A2','A3','A4','A5','A6','A7','A8','A9','A10'],f=fill(4*M,ten,22).out;
 assert.deepEqual(f.slice(0,10).map(s=>[s.address,s.amount,s.tail]),ten.map(a=>[a,4*M,0]),'every address takes the base price first');
 assert.deepEqual(f.slice(10,20).map(s=>[s.address,s.amount,s.tail]),ten.map(a=>[a,4*M+100000,1]),'then +0.1 on each address in turn: the 10th address gets 4.1 too');
 assert.deepEqual(f.slice(20).map(s=>[s.address,s.amount,s.tail]),[['A1',4*M+200000,2],['A2',4*M+200000,2]],'only then +0.2');
 const skip=[{address:'A',amount:10*M,lease_until:T0+1000,status:'pending'},{address:'A',amount:10*M+100000,lease_until:T0+1000,status:'pending'}];
 assert.equal(D.allocate(10*M,['A'],skip,T0).amount,10*M+200000,'an occupied tail is skipped');
 assert.equal(D.allocate(10*M,['A'],[...skip,{address:'A',amount:10*M+200000,lease_until:T0+1000,status:'paid'}],T0).amount,10*M+200000,'a paid order frees its amount at once');
 assert.equal(D.allocate(1000*M,['A'],[{address:'A',amount:1000*M,lease_until:T0+1000,status:'pending'}],T0).amount,1000*M+100000,'a 1000 USDT top-up can take a tail');
 assert.ok(fill(1000*M,['A'],1000).out.every(s=>s.amount<=1000999000),'nothing above 1000.999 USDT (the stored maximum)');
});
test('slots are held for 24h unless paid; a paid or expired order frees its slot at once / after the lease',()=>{
 const o={address:'A',amount:10*M,lease_until:T0+D.LEASE,status:'pending'};
 assert.equal(D.holdsSlot(o,T0+D.LEASE-1),true);assert.equal(D.holdsSlot(o,T0+D.LEASE),false);
 assert.equal(D.holdsSlot({...o,status:'paid'},T0+1),false);
 assert.equal(D.allocate(10*M,['A'],[o],T0+D.LEASE).amount,10*M);
});
test('matching: exact amount inside the 24h lease activates; late, wrong, duplicate and unmatched go to manual',()=>{
 const o={id:'o1',address:'A',amount:10*M,created:T0,lease_until:T0+D.LEASE,status:'pending'};
 assert.equal(D.matchPayment([o],{address:'A',amount:10*M,chain_at:T0+3700}).action,'activate','paying after the 1h countdown still activates inside 24h');
 assert.equal(D.matchPayment([o],{address:'A',amount:10*M,chain_at:T0+D.LEASE+1}).action,'manual','after 24h: manual queue');
 assert.deepEqual(D.matchPayment([o],{address:'A',amount:10*M+10000,chain_at:T0+5}).reason,'overpaid','overpaid never auto-activates; the one order in the window is shown as under manual review');
 assert.deepEqual(D.matchPayment([o],{address:'A',amount:10*M-10000,chain_at:T0+5}).reason,'underpaid','underpaid never auto-activates');
 assert.equal(D.matchPayment([o,{...o,id:'o2',amount:10*M+10000}],{address:'A',amount:10*M+20000,chain_at:T0+5}).reason,'ambiguous','several orders in the window and no exact amount: queue, never guess');
 assert.equal(D.matchPayment([o],{address:'A',amount:10*M,chain_at:T0-1}).action,'manual','a transfer before the order was created is not this order');
 const paid={...o,status:'paid'};assert.deepEqual([D.matchPayment([paid],{address:'A',amount:10*M,chain_at:T0+5}).reason],['duplicate']);
});
test('order limit: 5 orders in any rolling 24 hours; the wait is until the oldest counted order is 24 hours old (1..86400 s)',()=>{
 assert.equal(D.ORDER_LIMIT,5);assert.equal(D.ORDER_WINDOW,86400);
 assert.equal(D.orderWait([],T0),0);assert.equal(D.orderWait([T0-1,T0-2,T0-3,T0-4],T0),0,'four orders: a fifth is allowed');
 assert.equal(D.orderWait([T0-10,T0-20,T0-30,T0-40,T0-3600],T0),86400-3600,'five: wait until the oldest of them is 24 h old');
 assert.equal(D.orderWait([T0,T0,T0,T0,T0],T0),86400,'never more than 24 h');
 assert.equal(D.orderWait([T0-1,T0-2,T0-3,T0-4,T0-86400],T0),1,'never less than one second');
 assert.equal(D.orderWait([T0-1,T0-2,T0-3,T0-4,T0-50,T0-80000],T0),86350,'more rows than the limit (older history): the fifth newest decides');
});
test('trimMoney drops trailing zeros for display only',()=>{
 assert.equal(D.trimMoney('10.000000'),'10');assert.equal(D.trimMoney('10.010000'),'10.01');assert.equal(D.trimMoney('10.100000'),'10.1');
 assert.equal(D.trimMoney('4.008146'),'4.008146');assert.equal(D.trimMoney('0.000000'),'0');
});
test('a paid order does not make a later transfer ambiguous: the order still holding the slot wins; only paid matches are duplicates',()=>{
 const paid={id:'p',address:'A',amount:10*M,created:T0,lease_until:T0+D.LEASE,status:'paid'};
 const open={id:'n',address:'A',amount:10*M,created:T0+5,lease_until:T0+5+D.LEASE,status:'pending'};
 assert.equal(D.matchPayment([paid,open],{address:'A',amount:10*M,chain_at:T0+10}).order.id,'n');
 assert.equal(D.matchPayment([paid],{address:'A',amount:10*M,chain_at:T0+10}).reason,'duplicate');
});
