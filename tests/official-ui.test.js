'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),vm=require('vm'),fs=require('fs'),path=require('path');
function node(tag,attrs,...children){return {tag,attrs:attrs||{},children:children.flat().filter(x=>x!=null),appendChild(x){this.children.push(x);return x}}}
function fixture(handler,confirm=async()=>true){
 const calls=[],callbacks={},dialogs=[];let jobs=0;
 const ui={btn(label){return Object.assign(node('button'),{label})},icon(){return node('icon')},badge(label){return node('badge',null,label)},avail(b,reason){b.reason=reason},act(b,fn){b.click=fn},actionBusy(b,on){b.disabled=on},confirmDialog:confirm,toast(){},modal(o){const d={...o,close(){d.closed=true}};dialogs.push(d);return d}};
 const TP={S:{locked:false},ui,h:node,why:{helper:()=>''},clear(n){n.children=[]},on(ev,fn){(callbacks[ev]||=[]).push(fn)},errMsg(e){return e.code||'error'},helper:async(...args)=>{calls.push(args);return handler(...args)},loadState:async()=>{},plan:{load:async()=>{}},jobs:{runInDock:async(title,start)=>{jobs++;return start()}}};
 vm.runInNewContext(fs.readFileSync(path.join(__dirname,'../ui/official.js'),'utf8'),{window:{TP,I18N:{t:k=>k,L:k=>k}}});
 return {O:TP.official,TP,calls,dialogs,jobs:()=>jobs,emit(ev,v){(callbacks[ev]||[]).forEach(f=>f(v))}};
}
test('opening and rereading an official page performs only state GETs; cancel never applies',async()=>{
 const f=fixture(async()=>({ok:true,nodes:24,pending:true}),async()=>false);f.O.mount();await f.O.load();await f.O.load();await f.O.refresh();assert.equal(f.jobs(),0);assert.ok(f.calls.every(x=>x[0]==='GET'&&x[1]==='/api/official/status'));
});
test('refresh applies once after confirmation, not after logout during confirmation',async()=>{
 let confirm;const f=fixture(async()=>({ok:true,nodes:0}),()=>new Promise(r=>confirm=r));const run=f.O.refresh();f.emit('auth',false);confirm(true);await run;assert.equal(f.calls.length,0);assert.equal(f.jobs(),0);
 const g=fixture(async()=>({ok:true,nodes:24}));await g.O.refresh();assert.equal(g.jobs(),1);assert.equal(g.calls.filter(x=>x[0]==='POST'&&x[1]==='/api/official/refresh').length,1);
});
test('old account responses never repopulate official status',async()=>{
 let resolve;const f=fixture(()=>new Promise(r=>resolve=r));const root=f.O.mount(),load=f.O.load();f.emit('auth',false);resolve({ok:true,nodes:777,pending:true});await load;assert.ok(!JSON.stringify(root).includes('777'));
});
test('user sharing needs explicit separate consent and cannot upload official or subscription nodes',async()=>{
 const f=fixture(async()=>({ok:true,shares:[]}));await f.O.share({tag:'Official',official:true});await f.O.share({tag:'Subscription',sub:'provider'});assert.equal(f.calls.length,0);
 await f.O.share({tag:'Own'});assert.equal(f.calls[0][0],'GET');const action=f.dialogs[0].actions[0];await action.onClick();const r=f.calls.find(x=>x[0]==='POST');assert.equal(r[1],'/api/servers/share');assert.deepEqual(JSON.parse(r[2].body),{tag:'Own',consent:true,revision:'server-sharing-v1'});assert.ok(!r[2].body.includes('outbound'));
});
test('logout closes share dialogs and invalidates pending consent',async()=>{
 let confirm;const f=fixture(async()=>({ok:true,shares:[]}),()=>new Promise(r=>confirm=r));await f.O.share({tag:'Own'});const run=f.dialogs[0].actions[0].onClick();f.emit('auth',false);confirm(true);await run;assert.ok(f.dialogs[0].closed);assert.equal(f.calls.filter(x=>x[0]==='POST').length,0);
});
