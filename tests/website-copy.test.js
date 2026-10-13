#!/usr/bin/env node
// enana.cc 的复制按钮 (website/site.js, 真实脚本 + 假页面 + 手动时钟, 不需要浏览器、不发网络请求):
// 先后点两个复制按钮 (例如 macOS 下的 curl 和 wget), 每个按钮 2.2 秒后都要恢复成「复制」, 后点的不能取消先点的那个的恢复;
// 状态行只跟最近一次复制计时; 复制失败时按钮不再显示「已复制」, 失败提示不会被之前那次成功的计时提前抹掉。
const fs = require('fs'), vm = require('vm'), assert = require('assert'), path = require('path');
const source = fs.readFileSync(path.join(__dirname, '../website/site.js'), 'utf8');
// 词典里的按钮文字和提示 (第一处是 zh, 第二处是 en), 不在测试里重复写一遍
function entries(key) {
  const k = key.replace(/\./g, '\\.'), re = new RegExp("^      (?:'" + k + "'|" + k + "): '((?:[^'\\\\]|\\\\['\\\\])*)',?$", 'gm'), out = [];
  let m; while ((m = re.exec(source))) out.push(m[1].replace(/\\(['\\])/g, '$1'));
  assert.equal(out.length, 2, 'DICT.zh and DICT.en both define ' + key);
  return { zh: out[0], en: out[1] };
}
const COPY = entries('copy'), COPIED = entries('copied'), OK = entries('copy.ok'), FAIL = entries('copy.fail');
assert.notEqual(COPY.zh, COPIED.zh); assert.notEqual(COPY.en, COPIED.en);

class El {
  constructor(tag, attrs, text) { this.tagName = tag; this.attrs = Object.assign({}, attrs || {}); this.textContent = text || ''; this.className = this.attrs.class || ''; this.hidden = 'hidden' in this.attrs; this.events = {}; }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  addEventListener(e, fn) { (this.events[e] = this.events[e] || []).push(fn); }
  click() { (this.events.click || []).forEach(fn => fn({ preventDefault() {}, stopPropagation() {} })); }
  select() {}
}
const COMMANDS = { 'cmd-unix': 'curl -fsSL https://install.enana.cc | bash', 'cmd-unix2': 'wget -qO- https://install.enana.cc | bash', 'cmd-win': 'irm https://install.enana.cc/get.ps1 | iex' };
const nodes = [
  new El('button', { 'data-lang': 'zh' }), new El('button', { 'data-lang': 'en' }),
  new El('div', { id: 'os-switch', hidden: '' }), new El('button', { 'data-os': 'unix' }), new El('button', { 'data-os': 'win' }),
  new El('div', { 'data-cmd': 'unix' }), new El('div', { 'data-cmd': 'win' }),
  new El('code', { id: 'release-manifest' }), new El('p', { id: 'copy-status', class: 'status' })
];
const code = {}, btn = {};
Object.keys(COMMANDS).forEach(id => {
  code[id] = new El('code', { id: id }, COMMANDS[id]);
  btn[id] = new El('button', { 'data-copy': id, 'data-i18n': 'copy' }, COPY.zh);
  nodes.push(code[id], btn[id]);
});
const status = nodes.find(n => n.attrs.id === 'copy-status');

// 手动时钟: 只有 advance() 才会让 setTimeout 到期
let now = 0, seq = 0; const timers = new Map();
function setTimeoutFake(fn, ms) { const id = ++seq; timers.set(id, { fn, at: now + (+ms || 0) }); return id; }
function clearTimeoutFake(id) { timers.delete(id); }
function advance(ms) {
  const end = now + ms;
  for (;;) {
    let next = null;
    for (const [id, x] of timers) if (x.at <= end && (!next || x.at < next[1].at || (x.at === next[1].at && id < next[0]))) next = [id, x];
    if (!next) break;
    timers.delete(next[0]); now = next[1].at; next[1].fn();
  }
  now = end;
}
const tick = () => new Promise(r => setImmediate(r));

let clipboardOk = true, writes = [], selected = null, execCalls = 0;
const document = {
  readyState: 'complete', title: '', documentElement: { lang: '' }, body: { appendChild() {}, removeChild() {} },
  querySelectorAll(sel) { const m = /^\[([\w-]+)\]$/.exec(sel); assert(m, 'unexpected selector ' + sel); return nodes.filter(n => n.getAttribute(m[1]) !== null); },
  querySelector(sel) { assert.equal(sel, 'meta[name="description"]'); return null; },
  getElementById(id) { return nodes.find(n => n.attrs.id === id) || null; },
  addEventListener() { throw new Error('the page is already loaded'); },
  createElement(tag) { return new El(tag); },
  createRange() { return { selectNodeContents(n) { this.node = n; } }; },
  execCommand(cmd) { assert.equal(cmd, 'copy'); execCalls++; return false; }
};
const ctx = {
  document, console, Promise, setTimeout: setTimeoutFake, clearTimeout: clearTimeoutFake, isSecureContext: true,
  navigator: { language: 'zh-CN', platform: 'MacIntel', userAgent: 'fixture', clipboard: { writeText(text) { writes.push(text); return clipboardOk ? Promise.resolve() : Promise.reject(new Error('denied')); } } },
  localStorage: { getItem() { return null; }, setItem() {} },
  getSelection() { return { removeAllRanges() { selected = null; }, addRange(r) { selected = r.node; } }; }
};
ctx.window = ctx;
vm.runInNewContext(source, ctx, { filename: 'site.js' });

(async () => {
  // 初始: 中文, macOS 命令, 按钮都是「复制」, 没有计时
  assert.equal(document.documentElement.lang, 'zh-CN');
  Object.keys(btn).forEach(id => assert.equal(btn[id].textContent, COPY.zh, id));
  assert.equal(timers.size, 0);

  // curl 复制成功
  btn['cmd-unix'].click(); await tick();
  assert.deepEqual(writes, [COMMANDS['cmd-unix']]);
  assert.equal(btn['cmd-unix'].textContent, COPIED.zh);
  assert.equal(status.textContent, OK.zh); assert.equal(status.className, 'status');
  // 1 秒后 wget 也复制成功: 两个都显示「已复制」
  advance(1000);
  btn['cmd-unix2'].click(); await tick();
  assert.deepEqual(writes, [COMMANDS['cmd-unix'], COMMANDS['cmd-unix2']]);
  assert.equal(btn['cmd-unix'].textContent, COPIED.zh);
  assert.equal(btn['cmd-unix2'].textContent, COPIED.zh);
  // curl 的 2.2 秒到了: curl 恢复 (以前共用一个计时, wget 的点击把它取消了, curl 一直停在「已复制」), wget 还没到
  advance(1200);
  assert.equal(btn['cmd-unix'].textContent, COPY.zh, 'the first button resets on its own timer');
  assert.equal(btn['cmd-unix2'].textContent, COPIED.zh);
  assert.equal(status.textContent, OK.zh, 'the status line follows the most recent copy');
  // wget 的 2.2 秒到了: 两个都恢复, 状态行清空, 没有剩下的计时
  advance(1000);
  assert.equal(btn['cmd-unix'].textContent, COPY.zh);
  assert.equal(btn['cmd-unix2'].textContent, COPY.zh);
  assert.equal(status.textContent, ''); assert.equal(status.className, 'status');
  assert.equal(timers.size, 0);

  // 同一个按钮连点: 计时从最后一次算起, 只留一个计时
  btn['cmd-unix'].click(); await tick(); advance(2000);
  btn['cmd-unix'].click(); await tick();
  assert.equal(timers.size, 2, 'one label timer for the button and one status timer');
  advance(2000); assert.equal(btn['cmd-unix'].textContent, COPIED.zh);
  advance(200); assert.equal(btn['cmd-unix'].textContent, COPY.zh); assert.equal(status.textContent, '');

  // 成功之后马上失败: 按钮不再显示「已复制」, 选中命令方便手动复制, 失败提示一直留着 (之前成功的计时不会把它清掉)
  btn['cmd-unix'].click(); await tick();
  assert.equal(btn['cmd-unix'].textContent, COPIED.zh);
  clipboardOk = false; advance(500);
  btn['cmd-unix'].click(); await tick(); await tick();
  assert.equal(execCalls, 1, 'falls back to execCommand once');
  assert.equal(btn['cmd-unix'].textContent, COPY.zh, 'a failed copy does not keep the earlier "copied" label');
  assert.equal(status.textContent, FAIL.zh); assert.equal(status.className, 'status bad');
  assert.equal(selected, code['cmd-unix']);
  assert.equal(timers.size, 0);
  advance(10000);
  assert.equal(status.textContent, FAIL.zh, 'the failure notice is not wiped by the earlier success timer');
  clipboardOk = true;

  // 切换语言: 恢复时用当前语言
  btn['cmd-win'].click(); await tick();
  assert.equal(btn['cmd-win'].textContent, COPIED.zh);
  nodes.find(n => n.attrs['data-lang'] === 'en').click();
  assert.equal(document.documentElement.lang, 'en');
  assert.equal(status.textContent, '');
  btn['cmd-unix'].click(); await tick();
  assert.equal(btn['cmd-unix'].textContent, COPIED.en);
  assert.equal(status.textContent, OK.en);
  advance(2200);
  Object.keys(btn).forEach(id => assert.equal(btn[id].textContent, COPY.en, id));
  assert.equal(status.textContent, '');
  assert.equal(timers.size, 0);
  console.log('PASS: website copy buttons reset on their own timers, the status follows the latest copy, failures keep their notice');
})().catch(e => { console.error(e); process.exitCode = 1; });
