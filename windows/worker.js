'use strict';
// Unprivileged supervisor. It never launches a privileged command or a TUN core.
const fs=require('node:fs'),path=require('node:path'),net=require('node:net'),crypto=require('node:crypto');
const {spawn,execFileSync}=require('node:child_process');
const {atomic,settings,state,probe,requestSize}=require('./helper.js');
async function serve(home) {
  const runtime=path.join(home,'runtime');fs.mkdirSync(runtime,{recursive:true});
  if(state(home))throw Error('enana dashboard is already running');
  const boot=crypto.randomUUID(), logfile=fs.openSync(path.join(home,'api.log'),'a');
  const bash=path.join(runtime,'git','bin','bash.exe'), cygpath=path.join(runtime,'git','usr','bin','cygpath.exe');
  const posix=p=>execFileSync(cygpath,['-u',p],{encoding:'utf8',windowsHide:true}).trim();
  const sid=execFileSync('powershell.exe',['-NoProfile','-Command','[Security.Principal.WindowsIdentity]::GetCurrent().User.Value'],{encoding:'utf8',windowsHide:true}).trim();
  const env={...process.env,ENANA_HOME:posix(home),ENANA_WINDOWS_HOME:home,ENANA_API_PIPE:'1',ENANA_WINDOWS_SID:sid,ENANA_WINDOWS_ARCH:process.arch==='arm64'?'arm64':'amd64',
    PATH:[path.join(runtime,'node'),path.join(runtime,'git','usr','bin'),...['ucrt64','mingw64','mingw32','clangarm64'].map(d=>path.join(runtime,'git',d,'bin')),process.env.PATH].join(path.delimiter)};
  const api=posix(path.join(home,'lib','api.sh')),entry=posix(path.join(home,'enana'));
  execFileSync('powershell.exe',['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',path.join(home,'windows','platform.ps1'),'-Action','cleanup-core','-HomeDir',home],{windowsHide:true,stdio:['ignore','ignore','inherit']});
  let core=null,desired=settings(home).AUTOSTART==='1',closing=false,commandsBusy=false,active=0,restartAt=0;
  const tasks=new Map(),children=new Set(),sockets=new Set();
  function publish(){atomic(path.join(runtime,'service.json'),JSON.stringify({pid:process.pid,corePid:core?.pid||null,boot,updated:Date.now()}));}
  function kill(child){if(!child||child.exitCode!==null)return;
    try{execFileSync('taskkill.exe',['/PID',String(child.pid),'/T','/F'],{windowsHide:true,stdio:'ignore'});}catch(_){child.kill();}}
  async function stopCore(){desired=false;const c=core;core=null;if(c){kill(c);for(let i=0;i<50&&c.exitCode===null;i++)await new Promise(r=>setTimeout(r,100));if(c.exitCode===null)throw Error('Could not stop the owned core');}publish();}
  async function startCore(){
    if(core)return;
    const file=path.join(home,'config.json');const j=JSON.parse(fs.readFileSync(file,'utf8'));
    if(j.inbounds.some(b=>b.type==='tun'))throw Error('Enhanced/TUN must be started by the administrator helper');
    const fd=fs.openSync(path.join(home,'sing-box.log'),'a');
    const c=spawn(path.join(home,'sing-box.exe'),['run','-c',file,'-D',home],{cwd:home,env,windowsHide:true,stdio:['ignore',fd,fd]});fs.closeSync(fd);core=c;
    c.on('error',e=>{fs.writeSync(logfile,'core.start='+e.message+'\n');if(core===c)core=null;});
    c.on('exit',()=>{if(core===c)core=null;restartAt=Date.now()+3000;publish();});
    desired=true;publish();
    const p=Number(settings(home).PORT);
    for(let i=0;i<100;i++){if(c.exitCode!==null||!core)break;if(await probe('127.0.0.1',p,150)){publish();return;}await new Promise(r=>setTimeout(r,100));}
    await stopCore();throw Error('Proxy did not become ready; see sing-box.log');
  }
  function runPeriodic(cmd,file,limit){if(tasks.has(cmd)||closing)return;
    const fd=fs.openSync(path.join(home,file),'a');const c=spawn(bash,[entry,cmd,'--quiet'],{cwd:home,env,windowsHide:true,stdio:['ignore',fd,fd]});fs.closeSync(fd);tasks.set(cmd,c);
    const timer=setTimeout(()=>kill(c),limit);const finish=()=>{clearTimeout(timer);tasks.delete(cmd);};c.on('exit',finish);c.on('error',finish);
  }
  const server=net.createServer(socket=>{
    if(active>=32){socket.end('HTTP/1.1 503 Busy\r\nContent-Length: 0\r\nConnection: close\r\n\r\n');return;}
    active++;sockets.add(socket);let chunks=[],bytes=0,dispatched=false,child=null,timer;
    socket.setTimeout(15000);socket.on('timeout',()=>socket.destroy());socket.on('error',()=>{});
    socket.on('close',()=>{active--;sockets.delete(socket);if(timer)clearTimeout(timer);if(child&&child.exitCode===null)kill(child);});
    socket.on('data',data=>{
      if(dispatched){socket.destroy();return;}chunks.push(data);bytes+=data.length;
      if(bytes>4194304+32772){socket.destroy();return;}
      const input=Buffer.concat(chunks);let length;
      try{length=requestSize(input);}catch(_){socket.end('HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n');return;}
      if(length===null||bytes<length)return;
      if(bytes!==length){socket.destroy();return;}dispatched=true;chunks=[];socket.setTimeout(0);
      child=spawn(bash,[api],{cwd:home,env,windowsHide:true,stdio:['pipe','pipe',logfile]});children.add(child);
      timer=setTimeout(()=>{kill(child);socket.destroy();},180000);
      child.stdin.on('error',()=>{});child.stdin.end(input);
      child.stdout.pipe(socket,{end:false});child.on('error',()=>socket.destroy());
      child.on('close',()=>{children.delete(child);clearTimeout(timer);socket.end();});
    });
  });
  const apiPort=Number(settings(home).API_PORT);if(!Number.isInteger(apiPort)||apiPort<1||apiPort>65535)throw Error('Invalid API port');
  await new Promise((resolve,reject)=>{server.once('error',reject);server.listen({host:'127.0.0.1',port:apiPort,exclusive:true},resolve);});
  publish();
  const commandDir=path.join(runtime,'commands');fs.mkdirSync(commandDir,{recursive:true});
  async function commands(){if(commandsBusy||closing)return;commandsBusy=true;
    try{for(const f of fs.readdirSync(commandDir).filter(f=>/^[a-f0-9-]{73}\.json$/.test(f))){
      const file=path.join(commandDir,f);let r={ok:false,error:'Invalid command'};
      try{const req=JSON.parse(fs.readFileSync(file,'utf8'));if(req.boot!==boot)throw Error('Stale worker command');
        if(req.action==='stop')await stopCore();else if(req.action==='start')await startCore();else if(req.action==='restart'){await stopCore();await startCore();}
        else if(req.action==='shutdown'){await stopCore();setTimeout(shutdown,500);}else throw Error('Invalid command');r={ok:true};
      }catch(e){r={ok:false,error:e.message};}
      fs.unlinkSync(file);atomic(file.replace(/\.json$/,'.reply'),JSON.stringify(r));
    }}finally{commandsBusy=false;}
  }
  const cursorFile=path.join(runtime,'tun-log-cursor.json');let cursor={offset:0,key:''};
  try{const saved=JSON.parse(fs.readFileSync(cursorFile,'utf8'));if(Number.isSafeInteger(saved.offset)&&saved.offset>=0&&typeof saved.key==='string')cursor=saved;}catch(_){}
  function mirrorRootLog(){
    if(settings(home).NETWORK_MODE!=='tun')return;
    const file=path.join(process.env.ProgramData,'enana',sid,'sing-box.log');
    try{const st=fs.statSync(file),size=st.size,key=st.ino+':'+st.birthtimeMs;if(size<cursor.offset||key!==cursor.key)cursor={offset:0,key};
      if(size>cursor.offset){const fd=fs.openSync(file,'r'),length=Math.min(size-cursor.offset,1048576),b=Buffer.alloc(length);
        const read=fs.readSync(fd,b,0,length,cursor.offset);fs.closeSync(fd);fs.appendFileSync(path.join(home,'sing-box.log'),b.subarray(0,read));cursor.offset+=read;atomic(cursorFile,JSON.stringify(cursor));}
    }catch(e){if(e.code!=='ENOENT'&&e.code!=='EACCES')fs.writeSync(logfile,'worker.log='+e.message+'\n');}
  }
  const timer=setInterval(()=>{publish();mirrorRootLog();commands().catch(e=>fs.writeSync(logfile,'worker.command='+e.message+'\n'));
    if(desired&&!core&&!commandsBusy&&Date.now()>restartAt&&settings(home).NETWORK_MODE!=='tun') {restartAt=Date.now()+30000;startCore().catch(e=>fs.writeSync(logfile,'worker.restart='+e.message+'\n'));}
  },500);
  const tick=setInterval(()=>runPeriodic('tick','tick.log',55000),60000);
  const maintain=setInterval(()=>{const day=new Date().toISOString().slice(0,10);let old='';try{old=fs.readFileSync(path.join(runtime,'maintained-day'),'utf8');}catch(_){}
    if(old!==day){runPeriodic('maintain','update.log',600000);atomic(path.join(runtime,'maintained-day'),day);}
  },3600000);
  async function shutdown(){if(closing)return;closing=true;clearInterval(timer);clearInterval(tick);clearInterval(maintain);server.close();
    for(const s of sockets)s.destroy();for(const c of [...children,...tasks.values()])kill(c);await stopCore();
    try{fs.unlinkSync(path.join(runtime,'service.json'));}catch(_){}fs.closeSync(logfile);process.exit(0);
  }
  process.once('SIGTERM',shutdown);process.once('SIGINT',shutdown);
  if(desired&&settings(home).NETWORK_MODE!=='tun')await startCore();
  runPeriodic('tick','tick.log',55000);
}
if(require.main===module){if(process.platform!=='win32')throw Error('The Windows worker must run on Windows');serve(path.resolve(process.argv[2])).catch(e=>{console.error(e.message);process.exit(1);});}
module.exports={serve};
