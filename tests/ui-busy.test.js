#!/usr/bin/env node
// Exercise real component callbacks without a browser or external dependencies.
const fs = require('fs'), vm = require('vm'), assert = require('assert');
class Element {
  constructor(tag) { this.tagName = tag; this.children = []; this.attrs = {}; this.events = {}; this.disabled = false; this.value = ''; this.checked = false; this.text = ''; this.className = ''; this.classList = { contains: c => this.className.split(' ').includes(c), add: c => this.classList.toggle(c, true), remove: c => this.classList.toggle(c, false), toggle: (c, on) => { const a = new Set(this.className.split(' ').filter(Boolean)); if (on) a.add(c); else a.delete(c); this.className = [...a].join(' '); } }; }
  get textContent() { return this.text + this.children.map(x => x.textContent).join(''); }
  set textContent(s) { this.text = String(s); this.children = []; }
  setAttribute(k,v) { this.attrs[k] = String(v); if(k==='class') this.className=String(v); }
  getAttribute(k) { return this.attrs[k] ?? null; }
  removeAttribute(k) { delete this.attrs[k]; }
  appendChild(c) { if(c.parentNode) c.parentNode.removeChild(c); this.children.push(c); c.parentNode=this; return c; }
  removeChild(c) { this.children.splice(this.children.indexOf(c),1); c.parentNode=null; }
  insertBefore(c,b) { this.appendChild(c); }
  replaceChild(c,b) { this.removeChild(b); this.appendChild(c); }
  addEventListener(e,fn) { (this.events[e] ||= []).push(fn); }
  fire(e) { return Promise.all((this.events[e] || []).map(fn => fn({preventDefault(){},stopPropagation(){}}))); }
  querySelectorAll(sel) { const a=[]; const visit=x=>{ for(const c of x.children) { if(sel==='button' ? c.tagName==='button' : sel.startsWith('[data-id=') ? c.getAttribute('data-id')===sel.slice(10,-2) : sel==='[data-autofocus]' ? c.getAttribute('data-autofocus')!==null : sel.includes('.btn') ? c.classList.contains('btn') : false) a.push(c); visit(c); } }; visit(this); return a; }
  querySelector(s) { return this.querySelectorAll(s)[0] || null; }
  contains(x) { return this===x || this.children.some(c=>c.contains(x)); }
  focus() {}
  showModal() { this.open=true; }
  close() { this.open=false; }
}
const document={body:new Element('body'),activeElement:null,createTextNode:s=>{const x=new Element('#text');x.textContent=s;return x;},querySelectorAll:()=>[],contains:()=>true};
const I={t:k=>k,L:k=>k,isL:()=>false,attr:(e,k,v)=>e.setAttribute(k,v)};
const TP={on:()=>{},ui:{},S:{},h:(tag,a,...children)=>{const x=new Element(tag);for(const k in a || {}) x.setAttribute(k,a[k]);for(const c of children.flat()) if(c!=null)x.appendChild(c instanceof Element ? c : document.createTextNode(c));return x;},setText:(e,s)=>e.textContent=s,clear:e=>e.textContent='',byId:()=>null,errMsg:e=>e.message};
vm.runInNewContext(fs.readFileSync(require('path').join(__dirname,'../ui/ui.js'),'utf8'),{window:{TP,I18N:I},document,Promise,console,setTimeout,clearTimeout});
TP.ui.toast=()=>{};
const tick=()=>new Promise(r=>setImmediate(r));
const deferred=()=>{let resolve;const promise=new Promise(r=>resolve=r);return{promise,resolve};};
(async()=>{
 const u=TP.ui, b=u.btn('Save');let count=0,d=deferred();u.act(b,()=>{count++;return d.promise;});
 b.fire('click');b.fire('click');await tick();assert.equal(count,1);assert(b.disabled);assert.equal(b.getAttribute('aria-busy'),'true');assert.equal(b.textContent,'common.loading');
 d.resolve();await tick();assert(!b.disabled);assert.equal(b.textContent,'Save');
 const f=u.btn('Fail');u.act(f,()=>Promise.reject(new Error('expected')));f.fire('click');await tick();assert(!f.disabled);assert.equal(f.textContent,'Fail');
 let cur='system';d=deferred();const sel=new Element('select');u.selectAct(sel,()=>cur,async want=>{count++;await d.promise;cur=want;});sel.value='tun';sel.fire('change');sel.value='system';sel.fire('change');await tick();assert(sel.disabled);assert.equal(count,2);d.resolve();await tick();assert(!sel.disabled);assert.equal(sel.value,'tun');
 d=deferred();let segCount=0;const seg=u.seg('Mode',[{v:'one',label:'One'},{v:'two',label:'Two'}],async v=>{segCount++;seg.set(v);await d.promise;});seg.set('one');seg.inputs.two.checked=true;seg.inputs.two.fire('change');seg.inputs.two.fire('change');await tick();assert.equal(segCount,1);assert(Object.values(seg.inputs).every(x=>x.disabled));assert.equal(seg.el.getAttribute('aria-busy'),'true');d.resolve();await tick();assert(Object.values(seg.inputs).every(x=>!x.disabled));
 const m=u.modal({title:'Export',actions:[{id:'export',label:'Export',keep:true,onClick:async()=>{count++;await d.promise;return false;}},{id:'cancel',label:'Cancel',cancel:true}]});
 m.setBusy(true);assert(m.foot.children.every(b=>b.disabled));m.setActions([{label:'Replacement',keep:true}]);assert(m.foot.children[0].disabled);m.setBusy(false);assert(!m.foot.children[0].disabled);
 d=deferred();m.setActions([{label:'Deploy',keep:true,onClick:async api=>{count++;api.setActions([{label:'Next',keep:true,onClick:()=>{throw Error('duplicate');}}]);await d.promise;return false;}}]);const old=m.foot.children[0];old.fire('click');old.fire('click');await tick();assert.equal(count,3);assert(m.foot.children[0].disabled);assert.equal(m.el.getAttribute('aria-busy'),'true');await m.request();assert(m.el.open);d.resolve();await tick();assert(!m.foot.children[0].disabled);m.close();
 console.log('PASS: async double-submit prevention, visible busy state, error recovery, select state, export modal, footer replacement during provisioning');
})().catch(e=>{console.error(e);process.exitCode=1;});
