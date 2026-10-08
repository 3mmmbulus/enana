'use strict';
// ui/plan.js: the Upgrade button inside the "Learn more" dialog must close that dialog before switching
// to the membership page (otherwise the page changes behind a dialog that stays on top and the click
// looks dead), and a forced plan reload must ask the helper for a synchronous cloud refresh.
const test=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs'),path=require('node:path');
const script=fs.readFileSync(path.join(__dirname,'../ui/plan.js'),'utf8');
function node(tag,attrs,...children){return {tag,attrs:attrs||{},children:children.flat().filter(x=>x!=null),appendChild(x){this.children.push(x);return x}};}
function flatten(n){return n&&typeof n==='object'?[n,...(n.children||[]).flatMap(flatten)]:[];}
function fixture(planBody,{billing=true}={}){
 const log=[],modals=[],calls=[],callbacks={};
 const ui={btn(label){return Object.assign(node('button'),{label});},act(b,fn){b.click=async()=>fn();},badge(label){return node('badge',null,label);},toast(...x){log.push(['toast',...x]);},
  modal(o){const d={body:o.body,actions:o.actions,closed:false,close(v){d.closed=true;d.value=v;log.push(['close',v]);}};modals.push(d);return d;}};
 const TP={S:{locked:false},h:node,ui,on:(ev,fn)=>{(callbacks[ev]||=[]).push(fn);},emit(){},
  helper:async(m,p,o)=>{calls.push([m,p,o]);return planBody;},
  settingsTab:id=>{log.push(['tab',id,modals.length&&modals[modals.length-1].closed]);}};
 if(billing)TP.billing={};
 const I={t:(k,a)=>k+(a?JSON.stringify(a):''),L:k=>k,has:()=>false};
 vm.runInNewContext(script,{window:{TP,I18N:I},console});
 return {P:TP.plan,TP,log,modals,calls};
}
const free={ok:true,plan:{code:'free',title:'Free'},features:{core:{enabled:true,tier:'free'},official_proxy:{enabled:false,tier:'pro',reason:'upgrade',coming_soon:false}},official:{available:false,nodes:0}};
test('Upgrade closes the explanation dialog first, then opens the membership tab',async()=>{
 const f=fixture(free);await f.P.load(true);const dlg=f.P.explain('official_proxy');
 const up=flatten(dlg.body).find(n=>n.tag==='button');assert.ok(up,'upgrade button present');assert.equal(up.label,'plan.upgradeGo');
 await up.click();
 assert.deepEqual(f.log.filter(x=>x[0]==='close'||x[0]==='tab').map(x=>x.slice(0,2)),[['close','upgrade'],['tab','plan']],'dialog closes before the tab switch');
 assert.equal(f.log.find(x=>x[0]==='tab')[2],true,'the dialog was already closed when the page changed');
});
test('without the billing module the button keeps its old behaviour (a toast), and never throws',async()=>{
 const f=fixture(free,{billing:false});await f.P.load(true);const dlg=f.P.explain('official_proxy');
 await flatten(dlg.body).find(n=>n.tag==='button').click();
 assert.ok(f.log.some(x=>x[0]==='toast'));assert.ok(!f.log.some(x=>x[0]==='tab'||x[0]==='close'));
});
test('a feature that is already included shows no Upgrade button',async()=>{
 const f=fixture(free);await f.P.load(true);const dlg=f.P.explain('core');
 assert.ok(!flatten(dlg.body).some(n=>n.tag==='button'));
});
test('forced reload asks the helper for a synchronous cloud refresh; a normal reload does not',async()=>{
 const f=fixture(free);await f.P.load(false);assert.equal(f.calls[0][2].q,undefined);
 await f.P.load(true);assert.equal(JSON.stringify(f.calls[1][2].q),'{"refresh":"1"}');assert.ok(f.calls[1][2].timeout>=12000);
});
