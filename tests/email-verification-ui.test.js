'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs'),path=require('node:path');
const script=fs.readFileSync(path.join(__dirname,'../website/verify.js'),'utf8');
function fixture(fetchImpl,hash='#token='+'a'.repeat(40)){
 const elements={'verify-submit':{disabled:false,addEventListener:(type,fn)=>{elements.click=fn}},'verify-status':{textContent:''}},calls=[];
 vm.runInNewContext(script,{document:{getElementById:id=>elements[id]},location:{hash,pathname:'/verify'},history:{replaceState:(...args)=>calls.push(args)},URLSearchParams,AbortSignal,fetch:fetchImpl});return {elements,calls};
}
test('verification token is removed from history; confirmation requires one explicit click',async()=>{
 let done,calls=0;const f=fixture(async()=>{calls++;return new Promise(r=>{done=r})});assert.deepEqual(f.calls[0],[null,'','/verify']);assert.equal(calls,0);
 const first=f.elements.click();await f.elements.click();assert.equal(calls,1);assert.equal(f.elements['verify-submit'].disabled,true);done({ok:true});await first;await f.elements.click();assert.equal(calls,1);assert.equal(f.elements['verify-submit'].disabled,true);
});
test('network failure offers retry; invalid links never send requests',async()=>{
 let calls=0;const f=fixture(async()=>{calls++;if(calls===1)throw Error('network');return {ok:true}});await f.elements.click();assert.equal(f.elements['verify-submit'].disabled,false);await f.elements.click();assert.equal(calls,2);
 const bad=fixture(()=>{throw Error('should not fetch')},'#token=bad');assert.equal(bad.elements['verify-submit'].disabled,true);await bad.elements.click();
});
test('expired token response is terminal without printing upstream details',async()=>{
 const f=fixture(async()=>({ok:false}));await f.elements.click();assert.equal(f.elements['verify-submit'].disabled,true);assert.ok(f.elements['verify-status'].textContent.includes('失效'));
});
