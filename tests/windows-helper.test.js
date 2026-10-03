'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),dgram=require('node:dgram');
const {applicationRegex,nativePaths,requestSize,regexMap,dnsProbe}=require('../windows/helper.js');
function match(rx,file){return new RegExp(rx.slice(4),'i').test(file);}
function temporary(fn){const dir=fs.mkdtempSync(path.join(os.tmpdir(),'enana-windows-test-'));try{return fn(dir);}finally{fs.rmSync(dir,{recursive:true,force:true});}}
test('Windows PIN matches main exe, nested helpers, both separators and Squirrel versions',()=>{
 const rx=applicationRegex('Claude','C:/Users/Tester/AppData/Local/AnthropicClaude/app-1.2.3/Claude.exe');
 for(const p of ['C:/Users/Tester/AppData/Local/AnthropicClaude/app-1.2.3/Claude.exe','c:/users/tester/appdata/local/anthropicclaude/app-2.0.0/helpers/utility.exe']){
  assert.ok(match(rx,p));assert.ok(match(rx,p.split('/').join(String.fromCharCode(92))));
 }
 assert.ok(!match(rx,'C:/Users/Tester/AppData/Local/OtherApp/Claude.exe'));
});
test('shared folders match only the selected executable; regular-expression metacharacters stay literal',()=>{
 const rx=applicationRegex('Tool','C:/Windows/System32/A+B.exe');
 assert.ok(match(rx,'C:/Windows/System32/A+B.exe'));assert.ok(!match(rx,'C:/Windows/System32/Other.exe'));assert.ok(!match(rx,'C:/Windows/System32/AAAB.exe'));
 const bracket=applicationRegex('Example','C:/Program Files/Example (Beta)/example.exe');assert.ok(match(bracket,'C:/Program Files/Example (Beta)/helper.exe'));
});
test('uninstalled overrides remain scoped to an exe name',()=>{
 const rx=applicationRegex('Gemini',null);assert.ok(match(rx,'C:/Apps/Gemini.exe'));assert.ok(!match(rx,'C:/Apps/MyGemini.exe'));
});
test('native path conversion touches filesystem fields only, including Unicode and spaces',()=>temporary(dir=>{
 const file=path.join(dir,'config.json');fs.writeFileSync(file,JSON.stringify({log:{output:'/c/user/enana/log.txt'},route:{rule_set:[{path:'/c/user/enana/rules/a.json'}]},server:'/c/user/enana/looks-like-a-path',password:'/c/user/enana/secret',tls:{certificate_path:'/c/user/enana/certs/a.pem'}}));
 nativePaths(file,'/c/user/enana','C:/Users/Test User/enana');const j=JSON.parse(fs.readFileSync(file));
 assert.equal(j.log.output,'C:/Users/Test User/enana/log.txt');assert.equal(j.route.rule_set[0].path,'C:/Users/Test User/enana/rules/a.json');assert.equal(j.tls.certificate_path,'C:/Users/Test User/enana/certs/a.pem');
 assert.equal(j.password,'/c/user/enana/secret');assert.equal(j.server,'/c/user/enana/looks-like-a-path');
}));
test('regex map includes exact installed paths and safe old overrides',()=>temporary(dir=>{
 fs.writeFileSync(path.join(dir,'.apps.now'),'Google Chrome\tC:/Program Files/Google/Chrome/Application/chrome.exe\n');fs.writeFileSync(path.join(dir,'overrides.tsv'),'app|Gemini|pin|ack\nsite|google.com|auto|ack\n');
 const entries=new Map(regexMap(dir).trim().split('\n').map(line=>{const i=line.indexOf('\t');return [line.slice(0,i),JSON.parse(line.slice(i+1))];}));
 assert.ok(match(entries.get('Google Chrome'),'C:/Program Files/Google/Chrome/Application/helpers/chrome-helper.exe'));assert.ok(match(entries.get('Gemini'),'C:/Gemini/Gemini.exe'));assert.ok(!entries.has('google.com'));
}));
test('TCP bridge accepts fragmented headers and byte-sized Unicode bodies',()=>{
 assert.equal(requestSize(Buffer.from('GET / HTTP/1.1\r\nHost: local')),null);
 const body=Buffer.from(JSON.stringify({name:'测试'}));const request=Buffer.concat([Buffer.from(`POST /api/login HTTP/1.1\r\nHost: 127.0.0.1:9091\r\nContent-Length: ${body.length}\r\n\r\n`),body]);assert.equal(requestSize(request),request.length);
});
test('TCP bridge rejects request smuggling and unbounded input before spawning Bash',()=>{
 for(const h of ['Content-Length: 0\r\nContent-Length: 1','Content-Length: -1','Content-Length: 1.0','Content-Length: 4194305','Transfer-Encoding: chunked','Host: local\r\nHost: evil',' X-Continuation: yes'])assert.throws(()=>requestSize(Buffer.from('POST /api/login HTTP/1.1\r\n'+h+'\r\n\r\n')));
 assert.throws(()=>requestSize(Buffer.alloc(32769,65)));
});
test('Windows DNS benchmark validates a real local UDP DNS response',async()=>{
 const server=dgram.createSocket('udp4');server.on('message',(b,peer)=>{const reply=Buffer.from(b);reply[2]=0x81;reply[3]=0x80;server.send(reply,peer.port,peer.address);});
 await new Promise(r=>server.bind(0,'127.0.0.1',r));try{assert.ok(await dnsProbe('127.0.0.1',server.address().port,'example.test'));}finally{server.close();}
 assert.throws(()=>dnsProbe('127.0.0.1',53,'bad_name.example'));assert.throws(()=>dnsProbe('127.0.0.1',0,'example.test'));
});
