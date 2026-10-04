'use strict';
// The source URL is a private server file, never a release asset or log field.
const fs=require('fs'),path=require('path'),crypto=require('crypto'),{spawnSync}=require('child_process');
async function refresh(file,root='/opt/enana-cc',data='/var/lib/enana-cc/pb_data',options={}){
 const c=JSON.parse(fs.readFileSync(file,'utf8')),url=new URL(c.url);
 if(url.protocol!=='https:')throw Error('private_source_invalid');
 // Providers negotiate by User-Agent. Request the supported Clash subscription
 // representation instead of accidentally parsing their HTML landing page.
 const res=await fetch(url,{headers:{'User-Agent':'Clash/1.18.0'},signal:AbortSignal.timeout(20000),redirect:'error'});if(!res.ok)throw Error('source_unavailable');
 const t=Math.floor(Date.now()/1000),info=res.headers.get('subscription-userinfo')||'',exp=info.match(/(?:^|;)\s*expire=(\d+)/);
 const freshUntil=Math.min(t+2*86400,exp&&Number(exp[1])>0?Number(exp[1]):t+2*86400);if(freshUntil<=t)throw Error('source_expired');
 const parts=[];let size=0;for await(const chunk of res.body){size+=chunk.length;if(size>1048576)throw Error('source_too_large');parts.push(chunk)}
 const body=Buffer.concat(parts).toString('utf8');if(/<!doctype\s+html|<html(?:\s|>)/i.test(body))throw Error('source_html_response');
 const parsed=require(path.join(root,'catalog/importer.js')).parse(body,{role:'auto'});
 if(!parsed.servers.length)throw Error('source_parse_failed');
 const D=require(path.join(root,'pb_hooks/enana_nodes_domain.js'));
 const nodes=parsed.servers.map(r=>{const o=r.outbound;return {key:crypto.createHash('sha256').update(o.type+'\0'+o.server+'\0'+o.server_port+'\0'+o.tag).digest('hex').slice(0,32),label:D.label(o.tag),outbound:D.outbound(o)}});
 if(!nodes.length||nodes.length>300)throw Error('source_empty_or_too_large');
 if(options.validateOnly){console.log('Official source validated ('+nodes.length+' nodes); credentials withheld.');return nodes.length}
 const temp=fs.mkdtempSync(path.join(path.dirname(data),'catalog-'));fs.chmodSync(temp,0o700);
 try{const input=path.join(temp,'input.json');fs.writeFileSync(input,JSON.stringify({nodes,fresh_until:freshUntil}),{mode:0o600});
  const apply=spawnSync(path.join(root,'pocketbase'),['enana-nodes-import',input,'--dir='+data,'--hooksDir='+path.join(root,'admin'),'--migrationsDir='+path.join(root,'pb_migrations')],{encoding:'utf8',timeout:30000,maxBuffer:4096});
  if(apply.status!==0)throw Error('catalog_apply_failed');console.log('Official catalog refreshed ('+nodes.length+' nodes); private source withheld.');
 }finally{fs.rmSync(temp,{recursive:true,force:true})}
}
if(require.main===module)refresh(process.argv[2]||'/etc/enana/official-source.json').catch(()=>{console.error('Official catalog refresh failed; previous catalog retained until its existing expiry.');process.exitCode=1});
module.exports={refresh};
