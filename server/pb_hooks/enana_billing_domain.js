'use strict';
const SKUS=[{id:'m1',months:1,price:4000000},{id:'m3',months:3,price:10000000},{id:'m6',months:6,price:19000000},{id:'y1',months:12,price:35000000},{id:'y2',months:24,price:56000000},{id:'y3',months:36,price:72000000},{id:'y5',months:60,price:100000000}];
// 充值金额: 只收整数 USDT, 4 … 1000 (字符串, 不带小数点、正负号、前导 0 或空格)。区分订单的小数尾数由服务器分配, 不能由用户自己带。
function amount(v){if(typeof v!=='string'||!/^[1-9][0-9]{0,3}$/.test(v))throw Error('invalid_amount');const n=Number(v);if(n<4||n>1000)throw Error('invalid_amount');return n*1000000}
function format(n){if(!Number.isSafeInteger(n)||n<0)throw Error('invalid_amount');return Math.floor(n/1000000)+'.'+String(n%1000000).padStart(6,'0')}
function sku(id){const s=SKUS.find(s=>s.id===id);if(!s)throw Error('invalid_sku');return s}
function addMonths(sec,n){let d=new Date(sec*1000),day=d.getUTCDate();d.setUTCDate(1);d.setUTCMonth(d.getUTCMonth()+n);let end=new Date(Date.UTC(d.getUTCFullYear(),d.getUTCMonth()+1,0)).getUTCDate();d.setUTCDate(Math.min(day,end));return Math.floor(d.getTime()/1000)}
function quoteBase(body){if(body.kind==='plan'){const s=sku(body.sku);return {kind:'plan',sku:s.id,months:s.months,price:s.price}}if(body.kind==='topup')return {kind:'topup',sku:'',months:0,price:amount(body.amount)};throw Error('invalid_kind')}
// 金额分配 (产品规则, 单位 micro-USDT):
//  1. 默认收基础价 (套餐价或整数充值额); 只要这个价格在某个地址上是空闲的, 就用基础价, 不加任何小数。
//  2. 基础价在所有地址上都被占用时, 才加区分尾数, 依次:
//     一位小数 +0.1 … +0.9; 再两位小数 +0.01 … +0.99 (跳过 +0.10、+0.20 … 这些整十分);
//     再三位小数 +0.001 … +0.999 (跳过 0.01 的整数倍)。共 999 个尾数, 最多三位小数。
//     外层是尾数、内层是地址: 一个尾数先在每个地址上都试过, 再换下一个尾数。
//  3. 尾数也用完时不再加个位数, 直接报 E_QUOTE_CAPACITY (界面提示稍后再试, 并告警补地址)。
// 时效: 界面 1 小时付款倒计时 (PAY_BY); 槽位 (地址, 金额) 保留 24 小时 (LEASE)。
// 已付款 (paid / activated) 的订单立即释放槽位; 其它订单 (待付款 / 已取消 / 人工处理 …) 持有到 lease_until。
const PAY_BY=3600, LEASE=86400;
const TAILS=[];for(let k=1;k<=9;k++)TAILS.push(k*100000);for(let k=1;k<=99;k++)if(k%10)TAILS.push(k*10000);for(let k=1;k<=999;k++)if(k%10)TAILS.push(k*1000);
const TAIL_MAX=TAILS.length, TAIL_SPAN=999000; // 999 个尾数; 最大的尾数 +0.999: 一个价格的所有槽位都在 [价格, 价格 + 0.999] 之内
function holdsSlot(o,t){return o.lease_until>t&&o.status!=='paid'&&o.status!=='activated'}
function allocate(price,addresses,orders,t){
 if(!Array.isArray(addresses)||addresses.length===0)throw Error('E_PAYMENTS_UNAVAILABLE');
 const held=new Set();for(const o of orders)if(holdsSlot(o,t))held.add(o.address+'|'+o.amount);
 for(const a of addresses)if(!held.has(a+'|'+price))return {address:a,amount:price,tail:0};
 for(let k=0;k<TAILS.length;k++){const n=price+TAILS[k];for(const a of addresses)if(!held.has(a+'|'+n))return {address:a,amount:n,tail:k+1}}
 throw Error('E_QUOTE_CAPACITY');
}
// 下单次数: 每个账号在任意连续 24 小时内最多 ORDER_LIMIT 个订单 (任何类型、任何状态, 已取消的也算; 同一个 request_key 的重放不算)。
// created: 这 24 小时内订单的创建时间 (unix 秒, 新的在前; 取最新的 ORDER_LIMIT 个就够)。
// 返回 0 = 可以下单; 否则 = 还要等几秒 (1 … 86400), 也就是计入的最早一个订单满 24 小时的时刻。
const ORDER_LIMIT=5, ORDER_WINDOW=86400;
function orderWait(created,t){if(created.length<ORDER_LIMIT)return 0;return Math.min(ORDER_WINDOW,Math.max(1,created[ORDER_LIMIT-1]+ORDER_WINDOW-t))}
// 到账匹配: 先取同一地址、租约窗口内 (创建 .. lease_until) 的订单。
//  - 金额完全相等的唯一订单, 且未付款: activate (按时付款, 直接开通)。
//  - 窗口内只有一个订单但金额不符: manual (少付/多付, 显示「金额不符, 已转人工处理」, 不自动开通)。
//  - 其它 (无订单、超过 24 小时、重复付款、已取消后到账等): manual (进人工队列)。
// 结果只取决于金额相等的订单 (有的话); 没有时只取决于窗口里有 0 个、1 个 (是哪一个) 还是多个订单。
// 所以调用方有金额相等的订单时只传这些, 没有时传窗口里的前两个就够, 不会因为截断而漏掉正在付款的订单。
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
module.exports={SKUS:SKUS,amount:amount,format:format,sku:sku,addMonths:addMonths,quoteBase:quoteBase,PAY_BY:PAY_BY,LEASE:LEASE,TAILS:TAILS,TAIL_MAX:TAIL_MAX,TAIL_SPAN:TAIL_SPAN,holdsSlot:holdsSlot,allocate:allocate,ORDER_LIMIT:ORDER_LIMIT,ORDER_WINDOW:ORDER_WINDOW,orderWait:orderWait,matchPayment:matchPayment,trimMoney:trimMoney};
