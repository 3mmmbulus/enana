'use strict';
const SKUS=[{id:'m1',months:1,price:4000000},{id:'m3',months:3,price:10000000},{id:'m6',months:6,price:19000000},{id:'y1',months:12,price:35000000},{id:'y2',months:24,price:56000000},{id:'y3',months:36,price:72000000},{id:'y5',months:60,price:100000000}];
function amount(v){if(typeof v!=='string'||!/^(0|[1-9]\d{0,3})(\.\d{1,6})?$/.test(v))throw Error('invalid_amount');let p=v.split('.');let n=Number(p[0])*1000000+Number(((p[1]||'')+'000000').slice(0,6));if(n<4000000||n>1000000000)throw Error('invalid_amount');return n}
function format(n){if(!Number.isSafeInteger(n)||n<0)throw Error('invalid_amount');return Math.floor(n/1000000)+'.'+String(n%1000000).padStart(6,'0')}
function sku(id){const s=SKUS.find(s=>s.id===id);if(!s)throw Error('invalid_sku');return s}
function addMonths(sec,n){let d=new Date(sec*1000),day=d.getUTCDate();d.setUTCDate(1);d.setUTCMonth(d.getUTCMonth()+n);let end=new Date(Date.UTC(d.getUTCFullYear(),d.getUTCMonth()+1,0)).getUTCDate();d.setUTCDate(Math.min(day,end));return Math.floor(d.getTime()/1000)}
function quoteBase(body){if(body.kind==='plan'){const s=sku(body.sku);return {kind:'plan',sku:s.id,months:s.months,price:s.price}}if(body.kind==='topup')return {kind:'topup',sku:'',months:0,price:amount(body.amount)};throw Error('invalid_kind')}
module.exports={SKUS:SKUS,amount:amount,format:format,sku:sku,addMonths:addMonths,quoteBase:quoteBase};
