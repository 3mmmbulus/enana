// Exercise the real wizard job lifecycle with an isolated credential-form fixture.
// No browser storage, real credentials, SSH connections or server mutations.
const assert = require('assert'), fs = require('fs'), vm = require('vm'), path = require('path');
const defer = () => { let resolve, reject; const promise = new Promise((a,b) => { resolve=a; reject=b; }); return {promise,resolve,reject}; };
const tick = () => new Promise(resolve => setImmediate(resolve));
class El {
  constructor(tag) { this.tag=tag; this.children=[]; this.isConnected=true; }
  appendChild(x) { this.children.push(x); return x; }
  addEventListener() {} focus() {} closest() { return null; }
  getClientRects() { return [1]; } querySelector() { return null; }
}
function fixture() {
  let actions=[], busy=false, wipes=0, cancelCalls=0;
  const submit=defer(), follow=defer(), cancel=defer(), messages=[];
  const h=(tag,attrs,...kids)=>{const el=new El(tag); Object.assign(el,attrs); kids.flat().filter(x=>x!=null).forEach(x=>el.appendChild(x)); return el;};
  const I={t:k=>k,L:k=>k};
  const TP={S:{}, h, setText:(e,s)=>e.textContent=s, clear:e=>e.children=[], on(){},
    why:{helper:()=>''}, errMsg:e=>e.message, mkErr:(_,m)=>new Error(m),
    helper:async(_,url)=>{if(url==='/api/vps/probe') return submit.promise; assert.equal(url,'/api/vps/cancel'); cancelCalls++; return cancel.promise;},
    jobs:{follow:async(id,opts)=>{assert.equal(id,'vps-probe-fixture'); opts.fromJob({pct:5,result:{connection:{stage:'ssh',attempt:2,max_attempts:3,elapsed:1,timeout:45}}}); return follow.promise;}},
    ui:{help(){},icon(){},toast(){},taskCard:()=>({el:new El('card'),set:x=>messages.push(x.msg)})}
  };
  // Form validation has its own coverage. Supply fixed non-secret inputs here so
  // the test can drive the actual runProbe/cancelProbe/remote functions and footer.
  let source=fs.readFileSync(path.join(__dirname,'../ui/v-vps.js'),'utf8');
  const a=source.indexOf('  function credForm(o) {'), b=source.indexOf('  /* 同一个弹窗里的',a);
  assert(a>=0 && b>a);
  source=source.slice(0,a)+`function credForm() { return window.formFixture; }\n`+source.slice(b);
  const formFixture={el:new El('form'),check:()=>({host:'fixture.invalid',port:22,user:'root',mode:'password',password:'fixture',role:'pin'}),
    wipeSecrets:()=>wipes++,snapshot:()=>({}),firstInput:()=>null,apply(){},refreshDefaults(){},reset(){}};
  vm.runInNewContext(source,{window:{TP,I18N:I,formFixture},setTimeout(){},WeakMap,URL,console});
  const host={setActions:x=>actions=x,setBusy:x=>busy=x,setTabsHidden(){}};
  const pane=TP.vps.pane('password',host); pane.start();
  const detect=actions.find(x=>x.id==='go').onClick();
  assert(pane.busy() && busy); assert(actions[0].allowBusy);
  return {submit,follow,cancel,pane,detect,messages,get actions(){return actions;},get wipes(){return wipes;},get cancelCalls(){return cancelCalls;}};
}
const cancelledError=()=>Object.assign(new Error('cancelled'),{data:{result:{code:'E_CANCELLED'}}});
(async()=>{
  // Cancelling while POST is in flight must wait for its job ID, then cancel it.
  let f=fixture(), stopping=f.actions[0].onClick(); assert(f.actions[0].disabled); assert.equal(f.cancelCalls,0);
  f.submit.resolve({job:'vps-probe-fixture'}); await tick(); assert.equal(f.cancelCalls,1);
  f.cancel.resolve({ok:true}); f.follow.reject(cancelledError()); await Promise.all([stopping,f.detect]);
  assert(!f.pane.busy()); assert(f.actions.some(x=>x.id==='go')); assert(f.wipes>=2);
  // A failed cancel POST must reveal an already completed probe instead of leaving
  // a permanently busy page that suppresses the job's result.
  f=fixture(); f.submit.resolve({job:'vps-probe-fixture'}); await tick(); stopping=f.actions[0].onClick();
  f.follow.reject(new Error('probe failure')); await tick(); f.cancel.reject(new Error('cancel unavailable'));
  await Promise.all([stopping,f.detect]); assert(!f.pane.busy()); assert(f.actions.some(x=>x.id==='retry'));
  // If cancellation fails while the probe is still running, the normal completion
  // path remains active and the cancel action becomes available again.
  f=fixture(); f.submit.resolve({job:'vps-probe-fixture'}); await tick(); stopping=f.actions[0].onClick();
  f.cancel.reject(new Error('cancel unavailable')); await stopping;
  assert(f.pane.busy()); assert(!f.actions[0].disabled);
  f.follow.reject(new Error('later probe failure')); await f.detect;
  assert(!f.pane.busy()); assert(f.actions.some(x=>x.id==='retry'));
  assert(f.messages.includes('vps.connect.ssh'));
  console.log('PASS: cancellation before job creation, secret cleanup, progress and failed-cancel completion races');
})().catch(e=>{console.error(e);process.exitCode=1;});
