'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('fs'),os=require('os'),path=require('path');
const {refresh}=require('../server/catalog/refresh.js');
test('private source preflight validates accepted proxies without changing data or leaking URLs',{concurrency:false},async()=>{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'enana-catalog-test-'));const original=global.fetch,log=console.log;let output=[];
 try{
  fs.mkdirSync(path.join(dir,'catalog'));fs.mkdirSync(path.join(dir,'pb_hooks'));fs.copyFileSync(path.join(__dirname,'../ui/importer.js'),path.join(dir,'catalog/importer.js'));fs.copyFileSync(path.join(__dirname,'../server/pb_hooks/enana_nodes_domain.js'),path.join(dir,'pb_hooks/enana_nodes_domain.js'));
  const input=path.join(dir,'source.json'),url='https://source.example.invalid/private-source-token';fs.writeFileSync(input,JSON.stringify({url}),{mode:0o600});
  let body=JSON.stringify({outbounds:[{type:'http',tag:'US fixture',server:'proxy.example.com',server_port:443,password:'private-fixture',tls:{enabled:true}}]});
  global.fetch=async(u,o)=>{assert.equal(String(u),url);assert.equal(o.redirect,'error');return new Response(body)};console.log=s=>output.push(s);
  assert.equal(await refresh(input,dir,path.join(dir,'data'),{validateOnly:true}),1);assert.ok(!output.join().includes('private-source-token'));assert.ok(!output.join().includes('private-fixture'));assert.ok(!fs.existsSync(path.join(dir,'data')));
  body='empty invalid upstream';await assert.rejects(refresh(input,dir,path.join(dir,'data'),{validateOnly:true}));
  body=JSON.stringify({outbounds:[{type:'http',tag:'bad',server:'127.0.0.1',server_port:443}]});await assert.rejects(refresh(input,dir,path.join(dir,'data'),{validateOnly:true}));
  global.fetch=async()=>new Response(body,{headers:{'subscription-userinfo':'expire=1'}});await assert.rejects(refresh(input,dir,path.join(dir,'data'),{validateOnly:true}));
  global.fetch=async()=>new Response('blocked',{status:403});await assert.rejects(refresh(input,dir,path.join(dir,'data'),{validateOnly:true}));
 }finally{global.fetch=original;console.log=log;fs.rmSync(dir,{recursive:true,force:true})}
});
test('nginx allowlist updates only the existing enana route line and is idempotent',()=>{
 const {spawnSync}=require('child_process');const result=spawnSync('python3',['-c',"import importlib.util;s=importlib.util.spec_from_file_location('u','server/update-nodes-nginx.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m);t='other project untouched\\n|email/status|email/send\\ninternal excluded\\n';n=m.update(t);assert m.update(n)==n;assert n.replace('|servers/shares|servers/share','')==t"],{cwd:path.join(__dirname,'..'),encoding:'utf8'});assert.equal(result.status,0,result.stderr);
});
