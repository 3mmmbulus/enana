'use strict';
// Portable pure validation; use the same policy for imports and user sharing.
// Never accept local file paths, interfaces, detours, SSH keys or subscription URLs.
const TYPES=['http','socks','trojan','shadowsocks','vless','vmess','tuic','hysteria2','anytls'];
function text(v,max){if(typeof v!=='string'||!v.length||v.length>max||/[\x00-\x1f\x7f\\"\u202a-\u202e\u2066-\u2069]/.test(v))throw Error('E_NODE_INVALID');return v}
function host(v){
 text(v,253);v=v.toLowerCase();
 if(!/^[a-z0-9.-]+$/.test(v)||v==='localhost'||/\.(?:local|localhost|internal|invalid|test)$/.test(v))throw Error('E_NODE_INVALID');
 if(/^\d+(?:\.\d+){3}$/.test(v)){
  const n=v.split('.').map(Number);if(n.some(x=>x>255)||n[0]===0||n[0]===10||n[0]===127||n[0]>=224||n[0]===169&&n[1]===254||n[0]===172&&n[1]>=16&&n[1]<=31||n[0]===192&&n[1]===168||n[0]===100&&n[1]>=64&&n[1]<=127||n[0]===198&&[18,19].includes(n[1]))throw Error('E_NODE_INVALID');
 }else if(!v.includes('.')||v.split('.').some(s=>!s.length||s.length>63||s.startsWith('-')||s.endsWith('-'))||/^[0-9.]+$/.test(v))throw Error('E_NODE_INVALID');
 return v;
}
function only(o,keys){if(!o||typeof o!=='object'||Array.isArray(o)||Object.keys(o).some(k=>!keys.includes(k)))throw Error('E_NODE_INVALID')}
function outbound(o){
 only(o,['type','tag','server','server_port','username','password','uuid','method','security','alter_id','flow','tls','transport','obfs','congestion_control','udp_relay_mode','version']);
 if(!TYPES.includes(o.type)||!Number.isInteger(o.server_port)||o.server_port<1||o.server_port>65535)throw Error('E_NODE_INVALID');
 const r={type:o.type,server:host(o.server),server_port:o.server_port};
 const allowed={http:['username','password'],socks:['username','password','version'],trojan:['password'],anytls:['password'],shadowsocks:['method','password'],vless:['uuid','flow'],vmess:['uuid','security','alter_id'],tuic:['uuid','password','congestion_control','udp_relay_mode'],hysteria2:['password']}[o.type];
 for(const k of allowed){if(o[k]===undefined)continue;if(k==='alter_id'){if(!Number.isInteger(o[k])||o[k]<0||o[k]>65535)throw Error('E_NODE_INVALID');r[k]=o[k]}else r[k]=text(o[k],1024)}
 for(const k of ['username','password','uuid','method','security','alter_id','flow','congestion_control','udp_relay_mode','version'])if(o[k]!==undefined&&!allowed.includes(k))throw Error('E_NODE_INVALID');
 if(['vless','vmess','tuic'].includes(o.type)&&!r.uuid)throw Error('E_NODE_INVALID');
 if(['trojan','anytls','shadowsocks','tuic','hysteria2'].includes(o.type)&&!r.password)throw Error('E_NODE_INVALID');
 if(o.type==='shadowsocks'&&!r.method)throw Error('E_NODE_INVALID');
 if(o.tls!==undefined){
  only(o.tls,['enabled','server_name','insecure','alpn','utls','reality']);
  if(typeof o.tls.enabled!=='boolean'||o.tls.insecure===true)throw Error('E_NODE_INVALID');
  r.tls={enabled:o.tls.enabled};if(o.tls.server_name!==undefined)r.tls.server_name=host(o.tls.server_name);
  if(o.tls.alpn!==undefined){if(!Array.isArray(o.tls.alpn)||o.tls.alpn.length>8)throw Error('E_NODE_INVALID');r.tls.alpn=o.tls.alpn.map(v=>text(v,40))}
  if(o.tls.utls){only(o.tls.utls,['enabled','fingerprint']);if(o.tls.utls.enabled!==true)throw Error('E_NODE_INVALID');r.tls.utls={enabled:true,fingerprint:text(o.tls.utls.fingerprint,40)}}
  if(o.tls.reality){only(o.tls.reality,['enabled','public_key','short_id']);if(o.tls.reality.enabled!==true)throw Error('E_NODE_INVALID');r.tls.reality={enabled:true,public_key:text(o.tls.reality.public_key,100),short_id:text(o.tls.reality.short_id,32)}}
 }
 if(o.transport){only(o.transport,['type','path','headers','service_name']);if(!['ws','http','grpc'].includes(o.transport.type))throw Error('E_NODE_INVALID');r.transport={type:o.transport.type};for(const k of ['path','service_name'])if(o.transport[k]!==undefined)r.transport[k]=text(o.transport[k],512);if(o.transport.headers){only(o.transport.headers,['Host']);r.transport.headers={Host:host(o.transport.headers.Host)}}}
 if(o.obfs){only(o.obfs,['type','password']);if(o.type!=='hysteria2'||o.obfs.type!=='salamander')throw Error('E_NODE_INVALID');r.obfs={type:'salamander',password:text(o.obfs.password,1024)}}
 return r;
}
function label(v){const s=text(v,64).trim();if(!s)throw Error('E_NODE_INVALID');return s}
function canonical(v){if(Array.isArray(v))return v.map(canonical);if(v&&typeof v==='object'){const o={};Object.keys(v).sort().forEach(k=>o[k]=canonical(v[k]));return o}return v}
module.exports={outbound,label,TYPES,canonical};
