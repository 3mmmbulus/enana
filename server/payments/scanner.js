'use strict';
const fs=require('node:fs'),path=require('node:path');
const {TronGrid}=require('./provider.js');
const {validateAddresses,receiptTransfers}=require('./tron.js');
function readConfig(file){const c=JSON.parse(fs.readFileSync(file,'utf8'));validateAddresses(c.addresses);if(typeof c.scanner_secret!=='string'||c.scanner_secret.length<32)throw Error('invalid_scanner_configuration');return c}
function saveState(file,state){fs.mkdirSync(path.dirname(file),{recursive:true,mode:0o700});const temp=file+'.tmp';fs.writeFileSync(temp,JSON.stringify(state),{mode:0o600});fs.renameSync(temp,file)}
class Scanner {
 constructor(config,{provider,api='http://127.0.0.1:8090',stateFile='/var/lib/enana-cc/payments/state.json',fetchImpl=fetch,now=()=>Date.now()}={}) {
  if(!/^http:\/\/127\.0\.0\.1:\d+$/.test(api))throw Error('invalid_local_api');
  this.config=config;this.addresses=validateAddresses(config.addresses);this.api=api;this.file=stateFile;this.fetch=fetchImpl;this.now=now;
  try{this.state=JSON.parse(fs.readFileSync(stateFile,'utf8'))}catch(e){if(e.code!=='ENOENT')throw Error('scanner_state_unreadable');this.state={since:config.start_at||now()-60000,seen:{},last:{}};saveState(this.file,this.state)}
  if(!Number.isSafeInteger(this.state.since)||this.state.since<1||!this.state.seen||!this.state.last)throw Error('scanner_state_invalid');
  this.provider=provider||new TronGrid(config.provider_key,{budget:config.daily_budget||90000,usage:this.state.usage,now:now,onUsage:usage=>{this.state.usage=usage;saveState(this.file,this.state)}});
 }
 async local(route,body){let res,d;try{res=await this.fetch(this.api+'/api/enana/internal/billing/'+route,{method:body?'POST':'GET',redirect:'error',headers:{'X-Enana-Payments':this.config.scanner_secret,'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(10000)});d=await res.json()}catch(_){throw Error('billing_service_unavailable')}if(!res.ok||!d.ok)throw Error('billing_service_rejected');return d}
 async scan(address,solid){
  const ids=new Set();
  // Re-read the entire receive history since deployment. Do not advance a
  // timestamp cursor past an indexer delay, a missing receipt or a partial page.
  // Receipt acknowledgements suppress repeated RPCs; PB independently dedups.
  await this.provider.transactions(address,this.state.since,async rows=>{
   for(const row of rows){const id=row.transaction_id;if(typeof id!=='string'||!/^[a-f0-9]{64}$/.test(id))throw Error('provider_transaction_id');if(this.state.seen[id]||ids.has(id))continue;ids.add(id);
    const r=await this.provider.receipt(id);
    if(!r.id||!Number.isSafeInteger(r.blockNumber)||r.blockNumber>solid)throw Error('receipt_pending');
    const events=receiptTransfers(r,id,solid,this.addresses);
    for(const event of events)await this.local('event',event);
    // Persist only after all logs were accepted. A crash between logs or before
    // this write replays safely against the server's unique event/ledger keys.
    this.state.seen[id]=true;saveState(this.file,this.state);
   }
  });
  this.state.last[address]=this.now();saveState(this.file,this.state);
 }
 async round(){
  const work=await this.local('work'),active=new Set(work.active_addresses||[]);
  if(work.addresses?.join(',')!==this.addresses.join(','))throw Error('address_pool_mismatch');
  const due=this.addresses.filter(a=>this.now()-(this.state.last[a]||0)>=(active.has(a)?10000:300000));
  if(due.length){const solid=await this.provider.solidHeight();for(const address of due)await this.scan(address,solid)}
  await this.local('health',{healthy:true});
 }
}
async function main(){
 const cfgFile=process.env.ENANA_BILLING_CONFIG||'/etc/enana/billing.json';
 const scanner=new Scanner(readConfig(cfgFile));let delay=10000,last='';
 while(true){
  try{
   await scanner.round();delay=10000;
   if(last!=='ready'){process.stdout.write('payment scanner ready\n');last='ready'}
  }catch(e){
   if(scanner)try{await scanner.local('health',{healthy:false})}catch(_){}
   const code=/^[a-z_]+$/.test(e.message)?e.message:'scanner_unavailable';
   if(last!==code){process.stderr.write('payment scanner: '+code+'\n');last=code}
   delay=Math.min(300000,delay*2);
  }
  await new Promise(resolve=>setTimeout(resolve,delay+Math.floor(Math.random()*1000)));
 }
}
if(require.main===module)main().catch(()=>{process.stderr.write('scanner_start_failed\n');process.exitCode=1});
module.exports={Scanner,readConfig,saveState};
