'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),D=require('../server/pb_hooks/enana_nodes_domain.js');
const node={type:'http',tag:'US example',server:'proxy.example.com',server_port:443,username:'user',password:'fixture-only',tls:{enabled:true}};
test('delivery strips input tags and accepts bounded proxy credentials',()=>{const out=D.outbound(node);assert.equal(out.password,node.password);assert.ok(!('tag'in out));assert.equal(D.label('Tokyo'),'Tokyo')});
test('shared nodes cannot inject local routes, files, SSH material or other protocol fields',()=>{
 for(const extra of [{detour:'direct'},{bind_interface:'lo0'},{private_key:'ssh-key'},{certificate_path:'/etc/passwd'},{subscription_url:'https://private.example.com'},{uuid:'unexpected'}])assert.throws(()=>D.outbound({...node,...extra}));
 assert.throws(()=>D.outbound({...node,tls:{enabled:true,certificate_path:'/private/file'}}));assert.throws(()=>D.outbound({...node,tls:{enabled:true,insecure:true}}));
 for(const server of ['localhost','a.local','127.0.0.1','10.1.2.3','172.16.1.2','192.168.1.2','169.254.1.2','100.64.0.1','198.18.0.1','224.0.0.1','2130706433','127.1','999.2.3.4','::1','0x7f000001'])assert.throws(()=>D.outbound({...node,server}),server);
 for(const server_port of [0,-1,65536,1.1,'443'])assert.throws(()=>D.outbound({...node,server_port}));
});
test('canonical comparison preserves approval across JSON key order changes',()=>{assert.deepEqual(D.canonical({z:{b:2,a:1},a:0}),D.canonical({a:0,z:{a:1,b:2}}))});
