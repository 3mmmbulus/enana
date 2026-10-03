'use strict';
const fs = require('node:fs');
const path = require('node:path');
const net = require('node:net');
const crypto = require('node:crypto');
const vm = require('node:vm');
const dgram = require('node:dgram');

function atomic(file, value) {
  const tmp = file + '.' + crypto.randomUUID() + '.tmp';
  fs.writeFileSync(tmp, value, {mode: 0o600});
  for(let i=0;;i++){try{fs.renameSync(tmp,file);break;}catch(e){
    if(!['EACCES','EPERM','EBUSY'].includes(e.code)||i>=20){try{fs.unlinkSync(tmp);}catch(_){}throw e;}
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,5);
  }}
}
function settings(home) {
  const s = {PORT:'7890', UI_PORT:'9090', API_PORT:'9091', AUTOSTART:'1', NETWORK_MODE:'system'};
  try { for (const line of fs.readFileSync(path.join(home,'settings.env'),'utf8').split(/\r?\n/)) {
    const m = /^([A-Z_]+)=(.*)$/.exec(line); if (m) s[m[1]]=m[2];
  }} catch (e) { if (e.code !== 'ENOENT') throw e; }
  return s;
}
function state(home) {
  try {
    const s = JSON.parse(fs.readFileSync(path.join(home,'runtime','service.json'),'utf8'));
    if (!Number.isInteger(s.pid) || !/^[a-f0-9-]{36}$/.test(s.boot) || Date.now()-s.updated > 5000) return null;
    process.kill(s.pid, 0); return s;
  } catch (_) { return null; }
}
function probe(host, port, timeout=1200) {
  return new Promise(resolve => {
    const s=net.createConnection({host,port}); const finish=ok=>{s.destroy();resolve(ok);};
    s.setTimeout(timeout); s.once('connect',()=>finish(true)); s.once('error',()=>finish(false)); s.once('timeout',()=>finish(false));
  });
}
function escapeRegex(s) { return s.replace(/[.*+?^${}()|[\]\\]/g,'\\$&'); }
function applicationRegex(name, exe) {
  if (!exe || !/^[A-Za-z]:[\\/]/.test(exe)) return '(?i)[\\\\/]'+escapeRegex(name.replace(/\.exe$/i,''))+'\\.exe$';
  let dir=path.win32.dirname(exe);
  if (/^(app-[\d.]+|[\d.]+)$/i.test(path.win32.basename(dir))) dir=path.win32.dirname(dir);
  const generic=/^(windows|system32|syswow64|program files(?: \(x86\))?|windowsapps|programs|local|roaming|desktop|downloads|bin)$/i.test(path.win32.basename(dir));
  // Never match an entire shared directory because one executable lives there.
  const target=generic ? exe : dir+'\\';
  const rx=target.replace(/\//g,'\\').split('\\').map(escapeRegex).join('[\\\\/]');
  return '(?i)^'+rx+(generic?'$':'.*\\.exe$');
}
function windowsRules(home) {
  const names=new Map();
  try {for(const line of fs.readFileSync(path.join(home,'.apps.now'),'utf8').split(/\r?\n/)) {
    const [name,exe]=line.split('\t'); if(name && exe) names.set('(?i)/'+escapeRegex(name)+'\\.app/',applicationRegex(name,exe));
  }} catch(e) {if(e.code!=='ENOENT') throw e;}
  function walk(x) {
    if(Array.isArray(x)) {x.forEach(walk);return;}
    if(!x || typeof x!=='object') return;
    for(const [k,v] of Object.entries(x)) {
      if(k==='process_path_regex' && Array.isArray(v)) x[k]=v.map(rx=>{
        if(names.has(rx)) return names.get(rx);
        // Old overrides for uninstalled apps must never silently become global.
        if(rx.startsWith('(?i)/') && rx.endsWith('\\.app/')) return '(?i)[\\\\/]'+rx.slice(5,-6)+'\\.exe$';
        return rx;
      }); else walk(v);
    }
  }
  for(const f of fs.readdirSync(path.join(home,'rules')).filter(f=>/^ovr-.*\.json$/.test(f))) {
    const file=path.join(home,'rules',f), old=fs.readFileSync(file,'utf8'), j=JSON.parse(old);walk(j);
    const body=JSON.stringify(j)+'\n';if(body!==old)fs.writeFileSync(file,body);
  }
}
function regexMap(home) {
  const names=new Map();
  for(const file of ['.apps.now','overrides.tsv']){
    try{for(const line of fs.readFileSync(path.join(home,file),'utf8').split(/\r?\n/)){
      if(file==='.apps.now'){const [name,exe]=line.split('\t');if(name&&exe)names.set(name,exe);}
      else {const [kind,name]=line.split('|');if(kind==='app'&&!names.has(name))names.set(name,null);}
    }}catch(e){if(e.code!=='ENOENT')throw e;}
  }
  return [...names].map(([name,exe])=>name+'\t'+JSON.stringify(applicationRegex(name,exe))).join('\n')+'\n';
}
function nativePaths(file, posixHome, nativeHome) {
  const j=JSON.parse(fs.readFileSync(file,'utf8'));
  function walk(x) {
    if(Array.isArray(x)) return x.forEach(walk);
    if(!x || typeof x!=='object')return;
    for(const [k,v] of Object.entries(x)) {
      if((k==='path' || k==='output' || k.endsWith('_path')) && typeof v==='string' && v.startsWith(posixHome+'/')) x[k]=nativeHome.replace(/\\/g,'/')+v.slice(posixHome.length);
      else walk(v);
    }
  }
  walk(j);atomic(file,JSON.stringify(j)+'\n');
}
// Strict one-request framing. The existing Bash API keeps Host/Origin/token checks.
function requestSize(buffer) {
  const end=buffer.indexOf('\r\n\r\n');
  if(end<0){if(buffer.length>32768)throw Error('Header too large');return null;}
  if(end>32768)throw Error('Header too large');
  const lines=buffer.subarray(0,end).toString('latin1').split('\r\n');
  if(!/^(GET|HEAD|POST|PUT|PATCH|DELETE|OPTIONS) [^\s]+ HTTP\/1\.[01]$/.test(lines.shift()))throw Error('Invalid request');
  const seen=new Set();let length=0;
  for(const l of lines){const m=/^([!#$%&'*+.^_`|~\w-]+):[ \t]*(.*)$/.exec(l);if(!m)throw Error('Invalid header');
    const key=m[1].toLowerCase();if(seen.has(key))throw Error('Duplicate header');seen.add(key);
    if(key==='transfer-encoding')throw Error('Transfer encoding is unsupported');
    if(key==='content-length'){if(!/^(0|[1-9]\d*)$/.test(m[2]))throw Error('Invalid content length');length=Number(m[2]);}
  }
  if(length>4194304)throw Error('Body too large');
  return end+4+length;
}
function dnsProbe(host, port, name) {
  if(!Number.isInteger(port)||port<1||port>65535||!name.split('.').every(p=>/^[a-zA-Z0-9-]{1,63}$/.test(p))||name.length>253)throw Error('Invalid DNS query');
  return new Promise((resolve,reject)=>{
    const id=crypto.randomBytes(2), header=Buffer.alloc(12);id.copy(header);header.writeUInt16BE(0x100,2);header.writeUInt16BE(1,4);
    const query=Buffer.concat([header,...name.split('.').map(p=>Buffer.concat([Buffer.from([p.length]),Buffer.from(p)])),Buffer.from([0,0,1,0,1])]);
    const socket=dgram.createSocket(net.isIP(host)===6?'udp6':'udp4'),start=performance.now();
    let finished=false;
    const finish=(error)=>{if(finished)return;finished=true;clearTimeout(timer);socket.close();error?reject(error):resolve(Math.max(1,Math.round(performance.now()-start)));};
    const timer=setTimeout(()=>finish(Error('DNS query timed out')),2500);socket.once('error',finish);
    socket.on('message',b=>{if(b.length>=12&&b.subarray(0,2).equals(id)&&(b[2]&0x80))finish();});
    socket.connect(port,host,()=>socket.send(query));
  });
}
async function control(home, action) {
  if(!['start','stop','restart','shutdown'].includes(action))throw Error('Invalid worker command');
  const s=state(home);if(!s){if(action==='stop'||action==='shutdown')return;throw Error('Dashboard worker is not running');}
  const id=s.boot+'-'+crypto.randomUUID(), dir=path.join(home,'runtime','commands');
  fs.mkdirSync(dir,{recursive:true});const file=path.join(dir,id+'.json');
  atomic(file,JSON.stringify({boot:s.boot,action}));
  const ack=path.join(dir,id+'.reply');
  try {
    for(let i=0;i<300;i++){await new Promise(r=>setTimeout(r,100));
      if(fs.existsSync(ack)){
        const r=JSON.parse(fs.readFileSync(ack,'utf8'));if(!r.ok)throw Error(r.error);
        // A shutdown reply acknowledges the request before the supervisor
        // closes its sockets and children. Upgrades/uninstall must wait for
        // the acknowledged worker itself to exit, not just its state file.
        if(action==='shutdown'){
          for(let n=0;n<300;n++){
            try{process.kill(s.pid,0);}catch(e){if(e.code==='ESRCH')return;throw e;}
            await new Promise(resolve=>setTimeout(resolve,100));
          }
          throw Error('Dashboard worker did not finish shutting down');
        }
        return;
      }
      if(!state(home))throw Error('Dashboard worker stopped');
    }
    throw Error('Proxy command timed out');
  } finally {for(const f of [file,ack])try{fs.unlinkSync(f);}catch(_) {}}
}
async function main(args) {
  const [cmd,...a]=args;
  if(cmd==='probe'){const p=Number(a[1]);if(a[0]!=='127.0.0.1'||!Number.isInteger(p)||p<1||p>65535)throw Error('Only local port probes are supported');process.exitCode=(await probe(a[0],p))?0:1;}
  else if(cmd==='state'){const s=state(a[0]);console.log(s ? `1 ${s.corePid?1:0} ${s.corePid||''}`:'0 0');}
  else if(cmd==='control') await control(a[0],a[1]);
  else if(cmd==='paths')nativePaths(a[0],a[1],a[2]);
  else if(cmd==='rules')windowsRules(a[0]);
  else if(cmd==='regex-map')process.stdout.write(regexMap(a[0]));
  else if(cmd==='dns-probe')console.log(await dnsProbe(a[0],Number(a[1]),a[2]));
  else if(cmd==='import'){
    const sandbox={};vm.createContext(sandbox);vm.runInContext(fs.readFileSync(a[0],'utf8'),sandbox,{timeout:3000});
    const r=sandbox.TPImporter.parse(fs.readFileSync(a[1],'utf8'),{role:a[2]||'auto'});
    process.stdout.write(sandbox.TPImporter.toJSONL(r.servers,a[3]||''));
  } else throw Error('Unknown Windows helper command');
}
module.exports={atomic,settings,state,probe,applicationRegex,windowsRules,nativePaths,requestSize,control,dnsProbe,regexMap};
if(require.main===module)main(process.argv.slice(2)).catch(e=>{console.error(e.message);process.exitCode=1;});
