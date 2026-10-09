'use strict';
const SKUS=[{id:'m1',months:1,price:4000000},{id:'m3',months:3,price:10000000},{id:'m6',months:6,price:19000000},{id:'y1',months:12,price:35000000},{id:'y2',months:24,price:56000000},{id:'y3',months:36,price:72000000},{id:'y5',months:60,price:100000000}];
function amount(v){if(typeof v!=='string'||!/^(0|[1-9]\d{0,3})(\.\d{1,6})?$/.test(v))throw Error('invalid_amount');let p=v.split('.');let n=Number(p[0])*1000000+Number(((p[1]||'')+'000000').slice(0,6));if(n<4000000||n>1000000000)throw Error('invalid_amount');return n}
function format(n){if(!Number.isSafeInteger(n)||n<0)throw Error('invalid_amount');return Math.floor(n/1000000)+'.'+String(n%1000000).padStart(6,'0')}
function sku(id){const s=SKUS.find(s=>s.id===id);if(!s)throw Error('invalid_sku');return s}
function addMonths(sec,n){let d=new Date(sec*1000),day=d.getUTCDate();d.setUTCDate(1);d.setUTCMonth(d.getUTCMonth()+n);let end=new Date(Date.UTC(d.getUTCFullYear(),d.getUTCMonth()+1,0)).getUTCDate();d.setUTCDate(Math.min(day,end));return Math.floor(d.getTime()/1000)}
function quoteBase(body){if(body.kind==='plan'){const s=sku(body.sku);return {kind:'plan',sku:s.id,months:s.months,price:s.price}}if(body.kind==='topup')return {kind:'topup',sku:'',months:0,price:amount(body.amount)};throw Error('invalid_kind')}
// 金额分配 (产品规则, 单位 micro-USDT):
//  1. 默认收整数价; 只要这个价格在某个地址上是空闲的, 就用整数价, 不加任何小数。
//  2. 整数价在所有地址上都被占用时, 才加区分尾数: 从 +0.01 开始, 依次 +0.02 ... 最多 +0.99。
//  3. 尾数也用完时不再加个位数, 直接报 E_QUOTE_CAPACITY (界面提示稍后再试, 并告警补地址)。
// 时效: 界面 1 小时付款倒计时 (PAY_BY); 槽位 (地址, 金额) 保留 24 小时 (LEASE)。
// 已付款 (paid / activated) 的订单立即释放槽位; 其它订单持有到 lease_until。
const PAY_BY=3600, LEASE=86400, TAIL_STEP=10000, TAIL_MAX=99;
function holdsSlot(o,t){return o.lease_until>t&&o.status!=='paid'&&o.status!=='activated'}
function allocate(price,addresses,orders,t){
 if(!Array.isArray(addresses)||addresses.length===0)throw Error('E_PAYMENTS_UNAVAILABLE');
 const held=(a,n)=>orders.some(o=>o.address===a&&o.amount===n&&holdsSlot(o,t));
 for(const a of addresses)if(!held(a,price))return {address:a,amount:price,tail:0};
 for(let k=1;k<=TAIL_MAX;k++){const n=price+k*TAIL_STEP;for(const a of addresses)if(!held(a,n))return {address:a,amount:n,tail:k}}
 throw Error('E_QUOTE_CAPACITY');
}
// 到账匹配: 先取同一地址、租约窗口内 (创建 .. lease_until) 的订单。
//  - 金额完全相等的唯一订单, 且未付款: activate (按时付款, 直接开通)。
//  - 窗口内只有一个订单但金额不符: manual (少付/多付, 显示「金额不符, 已转人工处理」, 不自动开通)。
//  - 其它 (无订单、超过 24 小时、重复付款、已取消后到账等): manual (进人工队列)。
function matchPayment(orders,ev){
 const win=orders.filter(o=>o.address===ev.address&&o.created<=ev.chain_at&&ev.chain_at<=o.lease_until);
 const exact=win.filter(o=>o.amount===ev.amount);
 // A paid order releases its slot at once, so a new order may hold the same amount; prefer the order still holding the slot.
 const open=exact.filter(o=>o.status!=='paid'&&o.status!=='activated');
 if(open.length>1)return {action:'manual',reason:'ambiguous'};
 if(open.length===1){
  const o=open[0];
  if(o.status==='pending'||o.status==='detected')return {action:'activate',order:o};
  return {action:'manual',order:o,reason:'not_payable'};
 }
 if(exact.length>0)return {action:'manual',order:exact[0],reason:'duplicate'};
 if(win.length===1)return {action:'manual',order:win[0],reason:ev.amount<win[0].amount?'underpaid':'overpaid'};
 if(win.length>1)return {action:'manual',reason:'ambiguous'};
 return {action:'manual',reason:'unmatched'};
}
// 金额显示: 去掉末尾的 0 (10 而不是 10.000000; 10.01 而不是 10.010000)
function trimMoney(v){return /^\d+\.\d{6}$/.test(v)?v.replace(/\.?0+$/,''):v}
module.exports={SKUS:SKUS,amount:amount,format:format,sku:sku,addMonths:addMonths,quoteBase:quoteBase,PAY_BY:PAY_BY,LEASE:LEASE,TAIL_STEP:TAIL_STEP,TAIL_MAX:TAIL_MAX,holdsSlot:holdsSlot,allocate:allocate,matchPayment:matchPayment,trimMoney:trimMoney};
