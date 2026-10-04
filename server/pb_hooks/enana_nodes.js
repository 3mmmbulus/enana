'use strict';
const base=require(__hooks+'/enana_lib.js'),D=require(__hooks+'/enana_nodes_domain.js');
const REVISION='server-sharing-v1',FRESH=7*86400,LEASE=3600;
const now=()=>Math.floor(Date.now()/1000),iso=t=>new Date(t*1000).toISOString().replace('T',' ');
function unix(r,k){const d=r.getDateTime(k);return d&&!d.isZero()?d.unix():0}
function json(r,k){try{return JSON.parse(toString(r.get(k)))}catch(_){return null}}
function bad(e,code,status){return e.json(status||400,{ok:false,code})}
function event(app,user,key,action){const r=new Record(app.findCollectionByNameOrId('server_share_events'));r.set('user',user);r.set('node_key',key);r.set('action',action);r.set('revision',REVISION);app.save(r)}
function current(tx,g){const u=tx.findRecordById('users',g.user.id),s=tx.findRecordById('device_sessions',g.session.id);if(u.getBool('disabled')||s.getString('user')!==u.id||unix(s,'revoked_at')||unix(s,'expires_at')<=now())throw Error('E_SESSION');return {user:u,session:s}}
function available(app,t){
 const out=[];
 for(const r of app.findRecordsByFilter('official_nodes','enabled = true && approved = true','node_key',300,0)){
  if(unix(r,'fresh_until')<=t)continue;
  if(r.getString('origin')==='shared'){
   if(!r.getBool('consent')||r.getString('consent_revision')!==REVISION)continue;
   let u;try{u=app.findRecordById('users',r.getString('owner'))}catch(_){continue}
   if(u.getBool('disabled')||!u.getBool('verified'))continue;
  }
  try{const ob=D.outbound(json(r,'outbound')),label=D.label(r.getString('label'));out.push({record:r,label,outbound:ob})}catch(_){/* An invalid private catalog row is never delivered. */}
 }
 return out;
}
function clientReady(e){const v=(e.request.header.get('X-Enana-Client-Version')||'').match(/^(\d+)\.(\d+)\.(\d+)$/);return !!(v&&(Number(v[1])>2||Number(v[1])===2&&(Number(v[2])>3||Number(v[2])===3&&Number(v[3])>=8)))}
function summary(app,user,p,t){const eligible=p.granted.includes('official_proxy')&&!p.expired;return {available:available(app,t).length>0,nodes:eligible&&user.getBool('verified')?available(app,t).length:0,email_verified:user.getBool('verified'),dedicated:{claude_clean:available(app,t).filter(x=>x.record.getString('capability')==='claude_clean').length}}}
function nodes(e){
 const g=base.needSession(e);if(g.res)return;const t=now(),p=base.planFor($app,g.user,t),entitled=p.granted.includes('official_proxy')&&!p.expired;
 const compatible=clientReady(e),ready=entitled&&g.user.getBool('verified')&&compatible,rows=ready?available($app,t):[];
 e.response.header().set('Cache-Control','no-store');
 return e.json(200,{ok:true,entitled,email_verified:g.user.getBool('verified'),reason:!entitled?(p.expired?'expired':'upgrade'):!g.user.getBool('verified')?'email_unverified':!compatible?'upgrade_client':'',user_id:g.user.id,session_id:g.session.id,expires_at:Math.min(t+LEASE,ready?(p.expires_at||t+LEASE):t+LEASE,unix(g.session,'expires_at'),...rows.map(x=>unix(x.record,'fresh_until'))),
  nodes:rows.map(x=>({label:x.label,capability:x.record.getString('capability')||'general',outbound:Object.assign({type:x.outbound.type,tag:'enana-official-'+x.record.id+' '+x.label},x.outbound)}))});
}
function shares(e){const g=base.needSession(e);if(g.res)return;return e.json(200,{ok:true,revision:REVISION,shares:$app.findRecordsByFilter('official_nodes','owner = {:u} && origin = "shared"','-updated',100,0,{u:g.user.id}).map(r=>({key:r.getString('node_key').slice(23),label:r.getString('label'),status:!r.getBool('consent')?'revoked':!r.getBool('enabled')?'rejected':unix(r,'fresh_until')<=now()?'expired':r.getBool('approved')?'approved':'pending',expires_at:unix(r,'fresh_until')}))})}
function share(e){
 const g=base.needSession(e);if(g.res)return;const b=base.readJSON(e,16384);
 if(!b||typeof b.consent!=='boolean'||typeof b.key!=='string'||!/^[a-f0-9]{32}$/.test(b.key))return bad(e,'E_SHARE_INVALID');
 if(b.consent&&b.revision!==REVISION)return bad(e,'E_SHARE_CONSENT');
 if(b.consent&&!g.user.getBool('verified'))return bad(e,'E_EMAIL_UNVERIFIED',403);
 let ob,label;if(b.consent){try{ob=D.outbound(b.outbound);label=D.label(b.label)}catch(_){return bad(e,'E_NODE_INVALID')}}
 const key='shared-'+g.user.id+'-'+b.key;let result;
 try{$app.runInTransaction(tx=>{
  const g2=current(tx,g);if(b.consent&&!g2.user.getBool('verified'))throw Error('E_EMAIL_UNVERIFIED');
  let r;try{r=tx.findFirstRecordByData('official_nodes','node_key',key)}catch(_){r=null}
  if(r&&r.getString('owner')!==g2.user.id)throw Error('E_SHARE_INVALID');
  if(!r&&!b.consent){result='revoked';return}
  if((!r||!r.getBool('consent'))&&b.consent&&tx.countRecords('official_nodes',$dbx.exp('owner={:u} AND consent=true',{u:g2.user.id}))>=10)throw Error('E_SHARE_LIMIT');
  if(!r){if(tx.countRecords('official_nodes',$dbx.exp('owner={:u} AND consent=true',{u:g2.user.id}))>=10)throw Error('E_SHARE_LIMIT');r=new Record(tx.findCollectionByNameOrId('official_nodes'));r.set('node_key',key);r.set('owner',g2.user.id);r.set('origin','shared');r.set('capability','general')}
  if(!b.consent){r.set('outbound',null);r.set('consent',false);r.set('approved',false);r.set('enabled',false);tx.save(r);event(tx,g2.user.id,key,'revoke');result='revoked';return}
  const same=r.getBool('consent')&&JSON.stringify(D.canonical(json(r,'outbound')))===JSON.stringify(D.canonical(ob))&&r.getString('label')===label;
  if(!same){r.set('approved',false);r.set('approved_at','')}
  const first=!r.getBool('consent');r.set('outbound',ob);r.set('label',label);r.set('consent',true);r.set('enabled',true);r.set('consent_revision',REVISION);if(first)r.set('consent_at',iso(now()));r.set('fresh_until',iso(now()+FRESH));tx.save(r);
  event(tx,g2.user.id,key,first?'consent':same?'renew':'change');result=r.getBool('approved')?'approved':'pending';
 })}catch(err){return bad(e,['E_SHARE_LIMIT','E_EMAIL_UNVERIFIED','E_SHARE_INVALID'].includes(String(err.message))?err.message:'E_SHARE_UNAVAILABLE',409)}
 return e.json(200,{ok:true,status:result});
}
module.exports={nodes,summary,clientReady,share,shares,available,event,REVISION};
