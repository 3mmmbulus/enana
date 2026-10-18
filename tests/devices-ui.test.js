#!/usr/bin/env node
// 设置 → 账号与设备 → 我的设备: ui/v-settings.js 里真实的设备卡片 + ui/auth.js 里真实的 deviceRow 和小锁 + 真实的 ui/ui.js, 假 DOM (不需要浏览器、不碰辅助服务):
// 1. 当前设备没有「下线」按钮, 只有「当前设备」标记 (带一句说明); 其它设备的「下线」带小锁 (要再次输入登录密码)
// 2. 离线的设备显示「离线（仍保持登录）」并带说明 (云端只返回还登录着的设备); 在线的照旧显示「在线」; 不再出现光秃秃的「离线」
// 3. 下线: 取消确认 / 云端失败时这一行留着; 成功后这一行马上消失 (不等重新读取), 重新读取后以云端为准
// 4. 辅助服务不可用时其它设备的「下线」说明原因, 当前设备照样没有按钮
const fs = require('fs'), vm = require('vm'), assert = require('assert'), path = require('path');
const read = f => fs.readFileSync(path.join(__dirname, '..', f), 'utf8');
const tick = () => new Promise(r => setImmediate(r));
const flush = async () => { for (let i = 0; i < 12; i++) await tick(); };
const defer = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };

function attrOk(el, a) {
  const m = /^\[([\w-]+)(?:=(?:"([^"]*)"|'([^']*)'|([^\]]*)))?\]$/.exec(a); assert(m, 'unsupported selector ' + a);
  const v = el.getAttribute(m[1]), want = m[2] !== undefined ? m[2] : m[3] !== undefined ? m[3] : m[4];
  return want === undefined ? v !== null : v === want;
}
function matches(el, sel) {
  if (el.tagName === '#text') return false;
  return sel.split(',').some(part => {
    const nots = []; part = part.trim().replace(/:not\(([^)]*)\)/g, (_, x) => { nots.push(x); return ''; });
    const m = /^([a-z]*)((?:\.[\w-]+)*)((?:\[[^\]]+\])*)$/i.exec(part); assert(m, 'unsupported selector ' + part);
    if (m[1] && el.tagName !== m[1]) return false;
    if (m[2].split('.').filter(Boolean).some(c => !el.classList.contains(c))) return false;
    if ((m[3].match(/\[[^\]]+\]/g) || []).some(x => !attrOk(el, x))) return false;
    return !nots.some(x => attrOk(el, x));
  });
}
class El {
  constructor(tag) {
    this.tagName = tag; this.children = []; this.attrs = {}; this.events = {}; this.text = ''; this.className = ''; this.disabled = false; this.hidden = false; this.title = ''; this.value = ''; this.style = {}; this.parentNode = null;
    const self = this;
    this.classList = { contains: c => self.className.split(' ').includes(c), add: c => self.classList.toggle(c, true), remove: c => self.classList.toggle(c, false),
      toggle: (c, on) => { const s = new Set(self.className.split(' ').filter(Boolean)); if (on === undefined) on = !s.has(c); if (on) s.add(c); else s.delete(c); self.className = [...s].join(' '); return !!on; } };
  }
  get textContent() { return this.text + this.children.map(x => x.textContent).join(''); }
  set textContent(s) { this.children.forEach(c => { c.parentNode = null; }); this.children = []; this.text = String(s); }
  get firstChild() { return this.children[0] || null; }
  setAttribute(k, v) { if (k === 'class') this.className = String(v); else this.attrs[k] = String(v); }
  getAttribute(k) { return k === 'class' ? (this.className || null) : (k in this.attrs ? this.attrs[k] : null); }
  removeAttribute(k) { if (k === 'title') this.title = ''; delete this.attrs[k]; }
  appendChild(c) { if (c.parentNode) c.parentNode.removeChild(c); this.children.push(c); c.parentNode = this; return c; }
  insertBefore(c, ref) { if (!ref) return this.appendChild(c); if (c.parentNode) c.parentNode.removeChild(c); this.children.splice(this.children.indexOf(ref), 0, c); c.parentNode = this; return c; }
  removeChild(c) { const i = this.children.indexOf(c); assert(i >= 0, 'removeChild of a node that is not a child'); this.children.splice(i, 1); c.parentNode = null; return c; }
  replaceChild(c, old) { this.insertBefore(c, old); this.removeChild(old); return old; }
  addEventListener(e, fn) { (this.events[e] = this.events[e] || []).push(fn); }
  removeEventListener(e, fn) { const a = this.events[e] || [], i = a.indexOf(fn); if (i >= 0) a.splice(i, 1); }
  fire(type, ev) { const e = Object.assign({ type: type, target: this, preventDefault() {}, stopPropagation() {} }, ev || {}); (this.events[type] || []).slice().forEach(fn => fn(e)); }
  contains(x) { for (let n = x; n; n = n.parentNode) if (n === this) return true; return false; }
  querySelectorAll(sel) { const out = []; (function walk(n) { for (const c of n.children) { if (matches(c, sel)) out.push(c); walk(c); } })(this); return out; }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
  focus() { document.activeElement = this; }
  getBoundingClientRect() { return { left: 0, right: 0, top: 0, bottom: 0, width: 0, height: 0 }; }
}
const document = {
  body: new El('body'), activeElement: null,
  createTextNode: s => { const x = new El('#text'); x.text = String(s); return x; },
  createElement: tag => new El(tag),
  querySelectorAll: sel => document.body.querySelectorAll(sel),
  contains: x => document.body.contains(x),
  addEventListener() {}, removeEventListener() {}
};
const PROPS = { checked: 1, disabled: 1, selected: 1, hidden: 1, open: 1, multiple: 1, indeterminate: 1, readOnly: 1 };
function add(el, kids) { for (const k of kids) { if (k == null || k === false || k === true) continue; if (Array.isArray(k)) add(el, k); else el.appendChild(k instanceof El ? k : document.createTextNode(String(k))); } }
function h(tag, props, ...kids) {
  const el = new El(tag);
  for (const k of Object.keys(props || {})) {
    const v = props[k];
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v; else if (k === 'text') el.textContent = v; else if (k === 'on') Object.keys(v).forEach(ev => el.addEventListener(ev, v[ev]));
    else if (k === 'value') el.value = v; else if (PROPS[k]) el[k] = v; else el.setAttribute(k, v === true ? '' : String(v));
  }
  add(el, kids);
  return el;
}
const all = (root, pred) => { const out = []; (function walk(n) { for (const c of n.children) { if (pred(c)) out.push(c); walk(c); } })(root); return out; };
// t(key, {a:1}) -> "key:1" so the tests can see which parameters a message got
const I = { t: (k, p) => (p ? k + ':' + Object.keys(p).map(x => p[x]).join(',') : k), L: k => k, isL: () => false, attr: (e, k, v) => e.setAttribute(k, v), has: () => false, lang: 'en' };
let helperWhy = '';
const TP = { on() {}, ui: {}, S: {}, h, setText: (e, s) => { e.textContent = s; }, clear: e => { while (e.children.length) e.removeChild(e.children[0]); e.text = ''; return e; }, byId: () => null, errMsg: e => e.message, CFG: {},
  fmt: { rel: s => 'rel(' + s + ')' }, why: { helper: () => helperWhy, clash: () => '' } };
const window = { TP, I18N: I };
const ctx = vm.createContext({ window, document, console, Promise, setTimeout, clearTimeout, setInterval: () => 1, clearInterval() {}, navigator: {} });
function slice(src, from, to) { const a = src.indexOf(from), b = src.indexOf(to, a + 1); assert(a >= 0 && b > a, 'cannot find ' + JSON.stringify(from) + ' .. ' + JSON.stringify(to)); return src.slice(a, b); }

vm.runInContext(read('ui/ui.js'), ctx, { filename: 'ui.js' });
const toasts = []; TP.ui.toast = (m, k) => { toasts.push([m, k]); };
// ui/auth.js: the real lock marker (TP.sudo.icon / mark) and the real device row (platName + A.deviceRow)
const authSrc = read('ui/auth.js');
const sudoLines = authSrc.split('\n').filter(l => /^  sudo\.(icon|mark) = function/.test(l));
assert.equal(sudoLines.length, 2, 'TP.sudo.icon and TP.sudo.mark in ui/auth.js');
vm.runInContext('(function () { var TP = window.TP, h = TP.h, ui = TP.ui, L = window.I18N.L; var sudo = TP.sudo = {};\n' + sudoLines.join('\n') + '\n})();', ctx, { filename: 'auth.js (sudo marker)' });
vm.runInContext('(function () { var TP = window.TP, h = TP.h, ui = TP.ui, I = window.I18N, t = I.t; var A = TP.auth = {};\n' +
  slice(authSrc, '  function platName(p)', '  /* 下线一台设备前的二次确认 */') + '\n})();', ctx, { filename: 'auth.js (deviceRow)' });
let answer = true, signedIn = true; const confirms = [];
TP.auth.confirmKick = (d, loginNow) => { confirms.push(d.uid + ':' + loginNow); return Promise.resolve(answer); };
TP.auth.signedIn = () => signedIn;                    // 2.3.27: 「我的设备」只在登录了 enana 账号时读取 (没有登录时辅助服务只会回 E_LOGIN_REQUIRED)
const reqs = [];
TP.helper = (method, url, o) => { const d = defer(); reqs.push({ call: method + ' ' + url, o: o || null, d }); return d.promise; };
vm.runInContext('(function () { var TP = window.TP, S = TP.S, h = TP.h, ui = TP.ui, setText = TP.setText, I = window.I18N, t = I.t, L = I.L, el = {};\n  function hl() { return null; }\n' +
  slice(read('ui/v-settings.js'), '  /* ---- 我的设备', '  /* ---- 导出配置备份') +
  '\nwindow.DV = { card: devicesCard, load: loadDevices, render: renderDevices, el: el }; })();', ctx, { filename: 'v-settings.js (my devices)' });
const DV = window.DV;

const NOW = 1790000000;
const ME = { uid: 'dev-me-0001', name: 'This Mac', platform: 'macos', os: '26.0', arch: 'arm64', app: '2.3.26', last_seen: NOW, online: true, ip_hint: '192.0.*.*', current: true };
const HOME = { uid: 'dev-home-0002', name: 'Home iMac', platform: 'macos', os: '15.0', arch: 'arm64', app: '2.3.25', last_seen: NOW - 30, online: true, ip_hint: '203.0.*.*', current: false };
const OLD = { uid: 'dev-old-0003', name: 'Old MacBook', platform: 'macos', os: '14.5', arch: 'x86_64', app: '2.3.20', last_seen: NOW - 5000, online: false, ip_hint: '198.51.*.*', current: false };
const listOf = (...d) => ({ ok: true, platform: 'macos', limit: 2, devices: d.map(x => Object.assign({}, x)) });

const rows = () => all(DV.el.devList, x => x.tagName === 'div' && x.classList.contains('dev'));
const nameOf = r => all(r, x => x.tagName === 'b')[0].textContent;
const rowOf = n => { const r = rows().filter(x => nameOf(x) === n); assert.equal(r.length, 1, 'one row for ' + n); return r[0]; };
const buttons = r => all(r, x => x.tagName === 'button');
const status = r => { const s = all(r, x => x.classList.contains('dev-st')); assert.equal(s.length, 1, 'one status label'); return s[0]; };
async function answerGet(data) {
  const q = reqs.filter(x => x.call === 'GET /api/devices' && !x.done);
  assert.equal(q.length, 1, 'one pending device list request'); q[0].done = true; q[0].d.resolve(data); await flush();
}

(async () => {
  document.body.appendChild(DV.card());
  const first = DV.load(false); await flush();
  await answerGet(listOf(OLD, HOME, ME)); await first;

  // 1. 当前设备: 没有任何按钮, 只有「当前设备」标记 (带说明); 排在最前面
  assert.deepEqual(rows().map(nameOf), ['This Mac', 'Home iMac', 'Old MacBook'], 'current first, then online, then the rest');
  const me = rowOf('This Mac');
  assert(me.classList.contains('is-cur'));
  assert.equal(buttons(me).length, 0, 'no Sign out button on the device in use');
  const badge = all(me, x => x.classList.contains('badge'));
  assert.equal(badge.length, 1); assert.equal(badge[0].textContent, 'auth.dev.current');
  assert.equal(badge[0].getAttribute('title'), 'set.dev.current', 'the badge explains how to sign this device out');
  assert(me.textContent.includes('enana 2.3.26'), 'the reported version is shown');
  // 其它设备: 「下线」带小锁
  const homeRow = rowOf('Home iMac'), hb = buttons(homeRow);
  assert.equal(hb.length, 1); assert.equal(hb[0].textContent, 'set.dev.kick');
  assert(hb[0].classList.contains('has-sudo') && all(hb[0], x => x.classList.contains('sudo-l')).length === 1, 'Sign out asks for the password again');
  assert(!hb[0]._un, 'available');

  // 2. 在线 / 离线 (仍保持登录)
  const on = status(homeRow);
  assert.equal(on.className, 'dev-st on'); assert.equal(on.textContent, 'auth.dev.online'); assert.equal(on.getAttribute('title'), null);
  const oldRow = rowOf('Old MacBook'), off = status(oldRow);
  assert(oldRow.classList.contains('is-off'));
  assert.equal(off.className, 'dev-st off');
  assert.equal(off.textContent, 'set.dev.offKept', 'offline is labelled as still signed in');
  assert.equal(off.getAttribute('title'), 'set.dev.offTip', 'with an explanation');
  assert.equal(all(off, x => x.tagName === 'i' && x.classList.contains('dev-dot')).length, 1, 'the status dot is kept');
  assert(!DV.el.devList.textContent.includes('auth.dev.offline'), 'no bare "Offline" label is left');
  assert.equal(buttons(oldRow).length, 1, 'an offline device that is still signed in can be signed out');

  // 3a. 取消确认: 不发请求, 这一行留着
  answer = false; buttons(oldRow)[0].fire('click'); await flush();
  assert.deepEqual(confirms, ['dev-old-0003:false']);
  assert.equal(reqs.filter(x => x.call === 'POST /api/devices/kick').length, 0, 'nothing is sent after Cancel');
  assert.deepEqual(rows().map(nameOf), ['This Mac', 'Home iMac', 'Old MacBook']);

  // 3b. 云端失败: 报错, 这一行留着, 不重新读取
  answer = true; buttons(rowOf('Old MacBook'))[0].fire('click'); await flush();
  let kicks = reqs.filter(x => x.call === 'POST /api/devices/kick');
  assert.equal(kicks.length, 1);
  assert.deepEqual(kicks[0].o.form, { uid: 'dev-old-0003' }); assert.equal(kicks[0].o.sudoWhy, 'set.dev.sudoWhy:Old MacBook');
  assert.equal(kicks[0].o.confirmed, true, 'the kick was already confirmed here, so a guest-mode confirmation would never be added on top');
  kicks[0].d.reject(new Error('cloud down')); await flush();
  assert.deepEqual(toasts[toasts.length - 1], ['cloud down', 'err']);
  assert.deepEqual(rows().map(nameOf), ['This Mac', 'Home iMac', 'Old MacBook'], 'a failed sign-out keeps the row');
  assert.equal(reqs.filter(x => x.call === 'GET /api/devices').length, 1, 'no reload after a failure');

  // 3c. 成功: 这一行马上消失, 再读一次列表; 列表以云端为准
  buttons(rowOf('Old MacBook'))[0].fire('click'); await flush();
  kicks = reqs.filter(x => x.call === 'POST /api/devices/kick');
  assert.equal(kicks.length, 2);
  kicks[1].d.resolve({ ok: true }); await flush();
  assert.deepEqual(toasts[toasts.length - 1], ['set.dev.kicked:Old MacBook', 'ok']);
  assert.deepEqual(rows().map(nameOf), ['This Mac', 'Home iMac'], 'the signed-out device disappears before the reload answers');
  assert.equal(reqs.filter(x => x.call === 'GET /api/devices').length, 2, 'the list is read again');
  await answerGet(listOf(HOME, ME));
  assert.deepEqual(rows().map(nameOf), ['This Mac', 'Home iMac']);
  assert.equal(buttons(rowOf('This Mac')).length, 0);

  // 4. 辅助服务不可用: 「下线」说明原因; 当前设备照样没有按钮
  helperWhy = 'helper.down'; DV.render();
  const hb2 = buttons(rowOf('Home iMac'));
  assert.equal(hb2.length, 1); assert(hb2[0]._un && hb2[0]._un.reason === 'helper.down'); assert.equal(hb2[0].getAttribute('aria-disabled'), 'true');
  assert.equal(buttons(rowOf('This Mac')).length, 0);

  // 5. 没有登录 enana 账号 (2.3.27): 不读设备列表 (不发 GET /api/devices), 手动刷新也一样; 设备卡片记在 el.devCard 上, 由设置页在未登录时整块隐藏
  helperWhy = ''; signedIn = false;
  const gets = () => reqs.filter(x => x.call === 'GET /api/devices').length, n0 = gets();
  await DV.load(false); await DV.load(true); await flush();
  assert.equal(gets(), n0, 'no device list request while not signed in');
  assert(DV.el.devCard && DV.el.devCard.tagName === 'section', 'the devices card is exposed so the settings page can hide it for guests');
  signedIn = true; DV.load(false); await flush();
  assert.equal(gets(), n0 + 1, 'signed in again: the list is read');
  console.log('PASS: no Sign out on the device in use, offline devices say they are still signed in, a signed-out device leaves the list at once, guests never load the list');
})().catch(e => { console.error(e); process.exitCode = 1; });
