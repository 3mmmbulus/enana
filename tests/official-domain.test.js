'use strict';
// Pure parts of the official-node pipeline (no PocketBase, no network): sing-box JSON parsing / sanitising and the
// entitlement gate. All data here is synthetic: *.example.invalid hosts, fake credentials, made-up region names.
const test=require('node:test'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const D=require('../server/pb_hooks/enana_official_domain.js'),lib=require('../server/pb_hooks/enana_lib.js');
const sha=s=>crypto.createHash('sha256').update(s).digest('hex');
const REGIONS=['美国西雅图','美国洛杉矶','日本东京','日本大阪','新加坡','香港','台湾','韩国首尔','德国法兰克福','英国伦敦','加拿大','澳大利亚'];
function http(i){return {type:'http',tag:REGIONS[i%REGIONS.length]+(i>=REGIONS.length?' '+Math.floor(i/REGIONS.length):''),server:`h${i}.example.invalid`,server_port:443,username:'user'+i,password:'pw'+i,tls:{enabled:true,server_name:`h${i}.example.invalid`}}}
function subscription(){
 const o=[{type:'selector',tag:'PROXY',outbounds:['x']},{type:'urltest',tag:'AUTO',outbounds:['x']},{type:'direct',tag:'direct'},{type:'block',tag:'block'},{type:'dns',tag:'dns-out'}];
 for(let i=0;i<24;i++)o.push(http(i));
 for(let i=0;i<4;i++)o.push({type:'tuic',tag:'TUIC'+i,server:`t${i}.example.invalid`,server_port:8443,uuid:'00000000-0000-0000-0000-00000000000'+i,password:'pw',congestion_control:'bbr',tls:{enabled:true,alpn:['h3']}});
 for(let i=0;i<4;i++)o.push({type:'hysteria2',tag:'HY'+i,server:`y${i}.example.invalid`,server_port:8443,password:'pw',obfs:{type:'salamander',password:'ob'},tls:{enabled:true,server_name:'y.example.invalid'}});
 o.push({type:'vless',tag:'VLESS',server:'v.example.invalid',server_port:443,uuid:'00000000-0000-0000-0000-000000000009',flow:'xtls-rprx-vision',tls:{enabled:true,reality:{enabled:true,public_key:'PUBKEY',short_id:'ab'}}});
 o.push({type:'vless',tag:'剩余流量：12GB',server:'info.example.invalid',server_port:443,uuid:'u'});
 o.push({type:'http',tag:'套餐到期：2030-01-01',server:'127.0.0.1',server_port:1});
 o.push({type:'wireguard',tag:'wg',server:'w.example.invalid',server_port:51820});
 return JSON.stringify({log:{level:'info'},outbounds:o});
}
test('keeps only real proxy nodes, drops groups / built-ins / information pseudo-nodes / unsupported types',()=>{
 const r=D.parseSingBox(subscription(),{prefix:'官方-'});assert.ok(!r.error);
 assert.equal(r.nodes.length,33);
 const by=t=>r.nodes.filter(n=>n.outbound.type===t).length;
 assert.deepEqual([by('http'),by('tuic'),by('hysteria2'),by('vless')],[24,4,4,1]);
 assert.equal(r.skipped.group,5);assert.equal(r.skipped.info,1);assert.equal(r.skipped.address,1);assert.equal(r.skipped.type,1);
 assert.ok(r.nodes.every(n=>D.TYPES.includes(n.outbound.type)));
});
test('every tag carries the reserved prefix and is unique; type is the first key and tag the second',()=>{
 const r=D.parseSingBox(subscription(),{prefix:'官方-'});const tags=r.nodes.map(n=>n.outbound.tag);
 assert.ok(tags.every(t=>t.startsWith(D.RESERVED_PREFIX)));assert.equal(new Set(tags).size,tags.length);
 for(const n of r.nodes){const keys=Object.keys(n.outbound);assert.deepEqual(keys.slice(0,2),['type','tag']);assert.deepEqual(keys.slice(2),keys.slice(2).slice().sort());
  assert.ok(JSON.stringify(n.outbound).startsWith('{"type":"'+n.outbound.type+'","tag":"'));assert.equal(n.tag,n.outbound.tag)}
 // duplicates in the subscription get numbered, deterministically
 const dup=D.parseSingBox(JSON.stringify({outbounds:[http(0),{...http(1),tag:http(0).tag}]}),{prefix:'官方-'});
 assert.deepEqual(dup.nodes.map(n=>n.tag),['官方-美国西雅图','官方-美国西雅图 2']);
});
test('a configured prefix cannot escape the reserved one; control characters, quotes and long names are cleaned',()=>{
 assert.equal(D.normalizePrefix('Pro-'),'官方-Pro-');assert.equal(D.normalizePrefix(''),'官方-');assert.equal(D.normalizePrefix('官方-A-'),'官方-A-');assert.equal(D.normalizePrefix(undefined),'官方-');
 const r=D.parseSingBox(JSON.stringify({outbounds:[{...http(0),tag:'a"b\\c\n'+'长'.repeat(60)}]}),{prefix:'官方-'});const t=r.nodes[0].tag;
 assert.ok(!/["\\\u0000-\u001f]/.test(t));assert.ok(Buffer.byteLength(t)<=80);assert.ok(t.startsWith('官方-'));
});
test('strips everything the client must not obey: detour, bind interfaces, local file paths, DNS, unknown keys',()=>{
 const evil={type:'trojan',tag:'x',server:'e.example.invalid',server_port:443,password:'pw',detour:'direct',bind_interface:'en0',routing_mark:1,domain_resolver:'local',connect_timeout:'1s',tcp_fast_open:true,
  tls:{enabled:true,server_name:'e.example.invalid',certificate_path:'/etc/passwd',client_key_path:'/Users/x/.ssh/id',ech:{enabled:true,config_path:'/tmp/x',config:['AAAA']},fragment:true,utls:{enabled:true,fingerprint:'chrome',evil:1}},
  transport:{type:'ws',path:'/p',headers:{Host:'h.example.invalid'},unknown:1},multiplex:{enabled:true,brutal:{enabled:true,up_mbps:10,down_mbps:50,x:1}},extra:{a:1}};
 const o=D.parseSingBox(JSON.stringify({outbounds:[evil]}),{}).nodes[0].outbound,j=JSON.stringify(o);
 for(const bad of ['detour','bind_interface','routing_mark','domain_resolver','connect_timeout','tcp_fast_open','_path','/etc/passwd','fragment','unknown','"extra"','evil'])assert.ok(!j.includes(bad),'leaked '+bad);
 assert.equal(o.tls.server_name,'e.example.invalid');assert.equal(o.tls.utls.fingerprint,'chrome');assert.deepEqual(o.tls.ech.config,['AAAA']);assert.equal(o.transport.headers.Host,'h.example.invalid');assert.equal(o.multiplex.brutal.up_mbps,10);
});
test('a malformed node is dropped whole, never shipped half-broken: bad ports, non-host servers, the client cert placeholder, wrong shapes',()=>{
 const bads=[{...http(0),server_port:'443'},{...http(0),server_port:0},{...http(0),server:'bad host'},{...http(0),server:'[::1]'},{...http(0),server:''},{...http(0),password:'x@CERTS@y'},
  {...http(0),tls:true},{...http(0),tls:{enabled:'yes please',x:1,server_name:{}}},{...http(0),username:{a:1}},{...http(0),headers:{'bad name':'x'}},{...http(0),password:'p'.repeat(5000)},null,[],'x'];
 const r=D.parseSingBox(JSON.stringify({outbounds:bads.concat([http(1)])}),{});
 assert.equal(r.nodes.length,1);assert.equal(r.nodes[0].outbound.server,'h1.example.invalid');
 assert.ok(!JSON.stringify(r.nodes).includes('@CERTS@'));
 const nul=D.parseSingBox(JSON.stringify({outbounds:[{...http(0),username:null,tls:{enabled:true,server_name:null}}]}),{}).nodes[0].outbound;assert.ok(!('username' in nul));assert.deepEqual(nul.tls,{enabled:true});
});
test('output bytes do not depend on the upstream key order (a no-op sync must stay a no-op)',()=>{
 const a=D.parseSingBox(subscription(),{prefix:'官方-'}),shuffled=JSON.parse(subscription());
 shuffled.outbounds=shuffled.outbounds.map(o=>Object.fromEntries(Object.entries(o).reverse()));
 const b=D.parseSingBox(JSON.stringify(shuffled),{prefix:'官方-'});
 assert.equal(JSON.stringify(a.nodes),JSON.stringify(b.nodes));
});
test('bad bodies are reported as short codes, never thrown',()=>{
 for(const [body,code] of [['<html>login</html>','bad_format'],['{}','bad_format'],['{"outbounds":{}}','bad_format'],['{"outbounds":[]}','no_nodes'],[JSON.stringify({outbounds:[{type:'direct',tag:'d'}]}),'no_nodes'],['','bad_format']])
  assert.equal(D.parseSingBox(body,{}).error,code,body);
 const many=JSON.stringify({outbounds:Array.from({length:D.MAX_NODES+50},(_,i)=>http(i))});const r=D.parseSingBox(many,{});assert.equal(r.nodes.length,D.MAX_NODES);assert.equal(r.skipped.limit,50);
});
test('stable database keys: source id + hash of the final tag; different sources never collide',()=>{
 const k1=D.nodeKey('main','官方-日本东京',sha),k2=D.nodeKey('main','官方-日本东京',sha),k3=D.nodeKey('b2','官方-日本东京',sha);
 assert.equal(k1,k2);assert.notEqual(k1,k3);assert.match(k1,/^main~[0-9a-f]{32}$/);assert.ok(k1.length<=64);assert.ok(k3.startsWith('b2~'));
});
test('source configuration is validated: https only, no userinfo, safe ids, bounded list; the URL is never echoed',()=>{
 const ok={id:'main',url:'https://example.invalid/subs/TOKEN',ua:'sing-box/1.12.0',prefix:'官方-',enabled:true};
 assert.deepEqual(D.normalizeSource(ok),{...ok});
 for(const bad of [{...ok,url:'http://example.invalid/x'},{...ok,url:'https://user:pw@example.invalid/x'},{...ok,url:'ftp://example.invalid/x'},{...ok,url:'https://example.invalid/a b'},{...ok,url:'https://x/'+'a'.repeat(2100)},{...ok,id:'Main'},{...ok,id:'a_b'},{...ok,id:''},{...ok,id:'x'.repeat(17)},{...ok,ua:'bad\nua'},null,'x'])
  assert.equal(D.normalizeSource(bad),null,JSON.stringify(bad));
 assert.equal(D.normalizeSource({...ok,ua:''}).ua,'sing-box/1.12.0');assert.equal(D.normalizeSource({...ok,enabled:false}).enabled,false);assert.equal(D.normalizeSource({...ok,prefix:'X-'}).prefix,'官方-X-');
 const cfg=D.normalizeConfig({sources:[ok,ok,{...ok,id:'b2'},{...ok,id:'BAD'}].concat(Array.from({length:20},(_,i)=>({...ok,id:'s'+i}))),ttl_hours:9999});
 assert.deepEqual(cfg.sources.slice(0,2).map(s=>s.id),['main','b2']);assert.equal(cfg.sources.length,8);assert.equal(cfg.ttl,168*3600);
 assert.deepEqual(D.normalizeConfig(null),{sources:[],ttl:86400});assert.deepEqual(D.normalizeConfig({sources:'x'}),{sources:[],ttl:86400});
});
test('entitlement gate: nodes only for an active Pro plan with a verified email; the feature turns on with the first fresh node',()=>{
 const free={code:'free',granted:['core','sync','vps_deploy'],expired:false},pro={code:'pro',granted:['core','sync','vps_deploy','official_proxy'],expired:false},lapsed={...free,expired:true};
 assert.deepEqual(lib.officialAccess(free,true),{granted:false,entitled:false});
 assert.deepEqual(lib.officialAccess(pro,false),{granted:true,entitled:false});
 assert.deepEqual(lib.officialAccess(pro,true),{granted:true,entitled:true});
 assert.deepEqual(lib.officialAccess(lapsed,true),{granted:false,entitled:false});
 const f=(p,nodes,verified)=>JSON.stringify(lib.entitlements(p,{nodes,verified}).official_proxy);
 // no fresh node anywhere: "coming soon" for everybody, exactly the previous behaviour
 assert.equal(f(free,0,true),'{"enabled":false,"tier":"pro","reason":"upgrade","coming_soon":true}');
 assert.equal(f(pro,0,true),'{"enabled":false,"tier":"pro","coming_soon":true}');
 assert.equal(JSON.stringify(lib.entitlements(free).official_proxy),'{"enabled":false,"tier":"pro","reason":"upgrade","coming_soon":true}');
 // nodes exist: live feature, gated by plan and verification
 assert.equal(f(free,5,true),'{"enabled":false,"tier":"pro","reason":"upgrade"}');
 assert.equal(f(lapsed,5,true),'{"enabled":false,"tier":"pro","reason":"expired"}');
 assert.equal(f(pro,5,false),'{"enabled":false,"tier":"pro","reason":"verify"}');
 assert.equal(f(pro,5,true),'{"enabled":true,"tier":"pro"}');
 assert.deepEqual(Object.keys(lib.entitlements(pro,{nodes:5,verified:true})),['core','sync','vps_deploy','official_proxy']);
});
