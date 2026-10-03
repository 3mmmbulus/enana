'use strict';
const {USDT}=require('./tron.js');
// Fixed mainnet origin: neither an invoice nor an indexer pagination link can
// redirect the private API key to another host.
const ORIGIN='https://api.trongrid.io';
class ProviderError extends Error {
 constructor(code,status){super(code);this.code=code;this.status=status||0}
}
class TronGrid {
 constructor(key,{fetchImpl=fetch,budget=90000,now=()=>Date.now(),usage={},onUsage=()=>{}}={}) {
  if(typeof key!=='string'||!key)throw new ProviderError('provider_not_configured');
  this.key=key;this.fetch=fetchImpl;this.budget=budget;this.now=now;this.day=usage.day||'';this.calls=usage.calls||0;this.onUsage=onUsage;
 }
 async request(path,body) {
  const url=new URL(path,ORIGIN);
  if(url.origin!==ORIGIN)throw new ProviderError('unsafe_provider_url');
  const day=new Date(this.now()).toISOString().slice(0,10);
  if(day!==this.day){this.day=day;this.calls=0}
  if(this.calls>=this.budget)throw new ProviderError('provider_budget_exhausted');
  this.calls++;this.onUsage({day:this.day,calls:this.calls});
  let res,doc;
  try {
   res=await this.fetch(url,{method:body?'POST':'GET',redirect:'error',headers:{'TRON-PRO-API-KEY':this.key,'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(15000)});
   if(!res.ok)throw new ProviderError('provider_http',res.status);
   // Never propagate an upstream body/URL into logs or a public response.
   const text=await res.text();if(text.length>4000000)throw new ProviderError('provider_body_limit');
   doc=JSON.parse(text);
  }catch(e){if(e instanceof ProviderError)throw e;throw new ProviderError('provider_unavailable')}
  if(!doc||typeof doc!=='object'||doc.Error||doc.success===false)throw new ProviderError('provider_response');
  return doc;
 }
 async solidHeight(){const d=await this.request('/walletsolidity/getnowblock',{}),n=d.block_header?.raw_data?.number;if(!Number.isSafeInteger(n)||n<1)throw new ProviderError('provider_block');return n}
 receipt(id){if(!/^[a-f0-9]{64}$/.test(id))throw new ProviderError('invalid_transaction_id');return this.request('/walletsolidity/gettransactioninfobyid',{value:id})}
 async transactions(address,since,onPage,{maxPages=100}={}) {
  const q=new URLSearchParams({only_confirmed:'true',only_to:'true',contract_address:USDT,limit:'200',min_timestamp:String(since),order_by:'block_timestamp,asc'});
  let fingerprint='',previous=new Set();
  for(let page=0;page<maxPages;page++){
   if(fingerprint)q.set('fingerprint',fingerprint);
   const d=await this.request('/v1/accounts/'+address+'/transactions/trc20?'+q);
   if(!Array.isArray(d.data))throw new ProviderError('provider_transactions');
   await onPage(d.data);
   // Use the opaque cursor, not the supplied links.next URL.
   const next=d.meta?.fingerprint;
   if(!d.meta?.links?.next)return;
   if(typeof next!=='string'||!next||next.length>4096||previous.has(next))throw new ProviderError('provider_pagination');
   previous.add(next);fingerprint=next;
  }
  throw new ProviderError('provider_page_limit');
 }
}
module.exports={TronGrid,ProviderError};
