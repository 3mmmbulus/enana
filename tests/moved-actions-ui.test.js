#!/usr/bin/env node
// 2.3.25 把几个操作从按钮 / 弹窗底部挪进了正文或「更多」菜单; 这里检查它们以前的保护都还在 (真实的 ui/ui.js + 从页面脚本里切出来的真实代码, 假 DOM, 不需要浏览器、不碰辅助服务):
// 1. 服务器详情 (ui/v-servers.js openNode): 正文里的「设为固定出口 / 设为自动线路 / 测试」运行期间整个弹窗是忙碌的:
//    删除 / 显示凭据 / 关闭 / ✕ / ESC / 点遮罩都不起作用, 另外两个也不能点; 「显示凭据」运行期间正文的三个按钮同样不能点; 失败之后锁会解开。
// 2. 网站页「⋯ → 恢复网站默认」(ui/v-sites.js resetAllSites): 确认 + 后台任务 + 重新读取状态没结束时, 再选一次只提示稍等, 不会开第二个任务; 成功 / 失败 / 取消之后都能再用。
// 3. 日志页「更多 → 清除日志」(ui/v-logs.js): 菜单项带和 TP.sudo.mark 一样的小锁 (要再次输入登录密码), 其它菜单项没有。
const fs = require('fs'), vm = require('vm'), assert = require('assert'), path = require('path');
const read = f => fs.readFileSync(path.join(__dirname, '..', f), 'utf8');
const tick = () => new Promise(r => setImmediate(r));
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
  showModal() { this.open = true; this.attrs.open = ''; }
  close() { this.open = false; delete this.attrs.open; }
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
const I = { t: k => k, L: k => k, isL: () => false, attr: (e, k, v) => e.setAttribute(k, v), has: () => false, lang: 'en' };
const TP = { on() {}, ui: {}, S: { proxies: {} }, h, setText: (e, s) => { e.textContent = s; }, clear: e => { while (e.children.length) e.removeChild(e.children[0]); e.text = ''; return e; }, byId: () => null, errMsg: e => e.message, CFG: {} };
const window = { TP, I18N: I };
const ctx = vm.createContext({ window, document, console, Promise, setTimeout, clearTimeout, setInterval: () => 1, clearInterval() {}, navigator: {} });
vm.runInContext(read('ui/ui.js'), ctx, { filename: 'ui.js' });
const toasts = []; TP.ui.toast = (m, k) => { toasts.push([m, k]); };
// 小锁: 用 ui/auth.js 里真实的 TP.sudo.icon / TP.sudo.mark
const sudoLines = read('ui/auth.js').split('\n').filter(l => /^  sudo\.(icon|mark) = function/.test(l));
assert.equal(sudoLines.length, 2, 'TP.sudo.icon and TP.sudo.mark in ui/auth.js');
vm.runInContext('(function () { var TP = window.TP, h = TP.h, ui = TP.ui, L = window.I18N.L; var sudo = TP.sudo = {};\n' + sudoLines.join('\n') + '\n})();', ctx, { filename: 'auth.js (sudo marker)' });
function slice(src, from, to) { const a = src.indexOf(from), b = src.indexOf(to, a + 1); assert(a >= 0 && b > a, 'cannot find ' + JSON.stringify(from) + ' .. ' + JSON.stringify(to)); return src.slice(a, b); }

async function nodeDialog() {
  let sw = null, tst = null, rev = null;
  const calls = { switch: [], test: [], del: [], reveal: 0 };
  window.F = {
    servers: () => [{ tag: 'n1', role: 'pin', type: 'vless', server: '192.0.2.10', port: 443 }],
    switchTo: (pol, tag) => { calls.switch.push(pol + ':' + tag); sw = defer(); return sw.promise; },
    testOne: tag => { calls.test.push(tag); tst = defer(); return tst.promise; },
    del: s => { calls.del.push(s.tag); return Promise.resolve(); },
    askRole: () => Promise.resolve()
  };
  TP.S.proxies = { PIN: { now: 'other', all: ['n1', 'other'] }, Global: { now: 'other', all: ['n1', 'other'] }, n1: {} };
  TP.delayOf = () => null; TP.name = { role: r => 'role.' + r }; TP.globalPinned = () => false; TP.why = { helper: () => '', clash: () => '' };
  TP.helper = (method, url) => { assert.equal(method + ' ' + url, 'GET /api/servers/secret'); calls.reveal++; rev = defer(); return rev.promise; };
  vm.runInContext('(function () { var TP = window.TP, S = TP.S, h = TP.h, ui = TP.ui, I = window.I18N, t = I.t, L = I.L, F = window.F;\n' +
    'var servers = F.servers, switchTo = F.switchTo, testOne = F.testOne, del = F.del, askRole = F.askRole, pendingDel = {}, test = { running: false };\n' +
    slice(read('ui/v-servers.js'), '  var nodeDlg = null;', '  async function showSubUrl(') + '\nwindow.openNode = openNode; })();', ctx, { filename: 'v-servers.js (openNode)' });

  window.openNode('n1');
  const dlg = document.body.children.find(x => x.tagName === 'dialog');
  assert(dlg && dlg.open, 'the node dialog is open');
  const byText = s => { const r = all(dlg, x => x.tagName === 'button' && x.textContent === s); assert.equal(r.length, 1, s); return r[0]; };
  const bPin = byText('servers.row.usePin'), bAuto = byText('servers.row.useAuto'), bTest = byText('servers.nd.test');
  const fDel = dlg.querySelector('[data-id="del"]'), fRev = dlg.querySelector('[data-id="rev"]'), fClose = byText('common.close'), xBtn = dlg.querySelector('.dlg-x');
  assert(fDel && fRev && xBtn);
  assert(!fDel.contains(bPin) && !dlg.querySelector('.dlg-a').contains(bPin), 'the three actions sit in the body, not in the footer');
  const body = [bPin, bAuto, bTest], foot = [fDel, fRev, fClose, xBtn];
  [...body, fDel, fRev].forEach(b => assert(!b._un, 'available: ' + b.textContent));
  const idle = where => {
    [...body, ...foot].forEach(b => assert(!b.disabled, where + ': enabled ' + (b.textContent || 'x')));
    assert.equal(dlg.getAttribute('aria-busy'), 'false', where);
    assert(dlg.open && dlg.parentNode === document.body, where + ': still open');
  };
  const lockedExcept = (where, running) => {
    [...body, ...foot].forEach(b => assert(b.disabled, where + ': disabled ' + (b.textContent || 'x')));
    assert(running._busy, where + ': the clicked control shows it is working');
    assert.equal(dlg.getAttribute('aria-busy'), 'true', where);
  };
  // 每一种关闭 / 删除 / 再点其它操作的方式都不起作用, 只提示「正在处理」
  const pokeEverything = async () => {
    const before = { switch: calls.switch.length, test: calls.test.length, reveal: calls.reveal }, busyToasts = toasts.filter(x => x[0] === 'modal.busy').length;
    fDel.fire('click'); fRev.fire('click'); fClose.fire('click'); xBtn.fire('click'); bPin.fire('click'); bAuto.fire('click'); bTest.fire('click');
    dlg.fire('keydown', { key: 'Escape' }); dlg.fire('cancel'); dlg.fire('mousedown', { target: dlg }); dlg.fire('click', { target: dlg });
    await tick();
    assert.deepEqual(calls.del, [], 'Delete cannot start while an action is running');
    assert.deepEqual([calls.switch.length, calls.test.length, calls.reveal], [before.switch, before.test, before.reveal], 'no second action starts');
    assert(dlg.open && dlg.parentNode === document.body, 'the dialog refuses to close while busy');
    assert.equal(toasts.filter(x => x[0] === 'modal.busy').length - busyToasts, 4, 'x, Escape, cancel and the backdrop each say it is busy');
  };
  idle('initial');

  // 「设为固定出口」: 切换完成之前弹窗锁住
  bPin.fire('click'); await tick();
  assert.deepEqual(calls.switch, ['PIN:n1']);
  lockedExcept('use as fixed exit', bPin);
  await pokeEverything();
  sw.resolve(); await tick();
  idle('after the switch');
  assert.equal(bPin.textContent, 'servers.row.usePin', 'the label comes back');

  // 「设为自动线路」失败: 报错, 锁解开
  bAuto.fire('click'); await tick();
  assert.deepEqual(calls.switch, ['PIN:n1', 'Global:n1']);
  lockedExcept('use as auto route', bAuto);
  await pokeEverything();
  sw.reject(new Error('switch failed')); await tick();
  assert.deepEqual(toasts[toasts.length - 1], ['switch failed', 'err']);
  idle('after a failed switch');

  // 「测试」
  bTest.fire('click'); await tick();
  assert.deepEqual(calls.test, ['n1']);
  lockedExcept('test', bTest);
  await pokeEverything();
  tst.resolve(); await tick();
  idle('after the test');

  // 底部「显示凭据」(密码框 / 请求进行中): 正文的三个按钮同样不能点
  fRev.fire('click'); await tick();
  assert.equal(calls.reveal, 1);
  lockedExcept('show credentials', fRev);
  await pokeEverything();
  rev.resolve({ fields: [] }); await tick();
  idle('after showing credentials');

  // 不忙的时候删除照常: 关闭弹窗再开始删除
  fDel.fire('click'); await tick();
  assert.deepEqual(calls.del, ['n1']);
  assert(!dlg.open && dlg.parentNode === null, 'Delete closes the dialog first');
}

async function sitesReset() {
  let confirms = 0, answer = true, loads = 0, helperWhy = '';
  const jobs = [], posts = [];
  TP.ui.confirmDialog = o => { confirms++; assert.equal(o.title, 'sites.resetAll.title'); assert.equal(o.danger, true); return Promise.resolve(answer); };
  TP.tunDetail = x => x;
  TP.why = { helper: () => helperWhy, clash: () => '' };
  TP.jobs = { runInDock: (title, fn) => { const d = defer(); jobs.push({ title, d }); return Promise.resolve(fn()).then(() => d.promise); } };
  TP.helper = (method, url) => { posts.push(method + ' ' + url); return Promise.resolve({ ok: true }); };
  TP.loadState = () => { loads++; return Promise.resolve(); };
  vm.runInContext('(function () { var TP = window.TP, ui = TP.ui, I = window.I18N, t = I.t;\n' +
    slice(read('ui/v-sites.js'), '    var resetting = false;', '    el.more = ui.ibtn(') + '\nwindow.resetAllSites = resetAllSites; })();', ctx, { filename: 'v-sites.js (resetAllSites)' });
  toasts.length = 0;

  const p1 = window.resetAllSites(); await tick();
  assert.equal(confirms, 1); assert.deepEqual(jobs.map(j => j.title), ['sites.resetAll.title']); assert.deepEqual(posts, ['POST /api/sites/reset']);
  // 任务还在跑: 再选一次不再确认、不再开任务, 只提示稍等
  await window.resetAllSites();
  await window.resetAllSites();
  assert.equal(confirms, 1); assert.equal(jobs.length, 1); assert.deepEqual(posts, ['POST /api/sites/reset']);
  assert.deepEqual(toasts, [['sites.dm.busy', 'warn'], ['sites.dm.busy', 'warn']]);
  // 任务结束后还要重新读取状态; 读完才算结束
  jobs[0].d.resolve(); await p1;
  assert.equal(loads, 1);

  // 结束以后可以再做一次; 失败也会解开
  const p3 = window.resetAllSites(); await tick();
  assert.equal(confirms, 2); assert.equal(jobs.length, 2);
  await window.resetAllSites(); assert.equal(confirms, 2); assert.equal(jobs.length, 2);
  jobs[1].d.reject(new Error('reset failed'));
  await assert.rejects(p3, /reset failed/);
  assert.equal(loads, 1);
  // 取消确认也会解开
  answer = false; await window.resetAllSites();
  assert.equal(confirms, 3); assert.equal(jobs.length, 2);
  answer = true; const p5 = window.resetAllSites(); await tick();
  assert.equal(confirms, 4); assert.equal(jobs.length, 3);
  jobs[2].d.resolve(); await p5;
  assert.equal(loads, 2);
  // 辅助服务不可用: 只说原因, 也不会把「正在恢复」留在那里
  toasts.length = 0; helperWhy = 'helper.down';
  await window.resetAllSites();
  assert.deepEqual(toasts, [['helper.down', 'warn']]); assert.equal(confirms, 4);
  helperWhy = ''; answer = false;
  await window.resetAllSites();
  assert.equal(confirms, 5); assert.equal(jobs.length, 3);
  assert.deepEqual(toasts, [['helper.down', 'warn']]);
}

async function logsClearLock() {
  let exported = 0, settings = 0, cleared = 0;
  window.LF = { openExport: () => { exported++; }, openSettings: () => { settings++; }, clearFromMenu: () => { cleared++; } };
  vm.runInContext('(function () { var TP = window.TP, h = TP.h, ui = TP.ui, I = window.I18N, t = I.t, L = I.L, el = {}, LG = { openSettings: window.LF.openSettings }, openExport = window.LF.openExport, clearFromMenu = window.LF.clearFromMenu;\n' +
    slice(read('ui/v-logs.js'), "    el.more = ui.btn(L('common.more')", "    el.noticeTxt = h('span');") + '\nwindow.logsMore = el.more; })();', ctx, { filename: 'v-logs.js (more menu)' });
  const more = window.logsMore;
  assert.equal(more.getAttribute('aria-haspopup'), 'menu');
  const openMenu = () => {
    more.fire('click');
    const menus = document.body.children.filter(x => x.className === 'menu');
    assert.equal(menus.length, 1, 'one menu is open');
    const items = all(menus[0], x => x.tagName === 'button' && x.classList.contains('menu-i'));
    assert.equal(items.length, 3, 'export, log settings, clear logs');
    return { menu: menus[0], items };
  };
  const locksIn = n => all(n, x => x.classList.contains('sudo-l'));
  let m = openMenu();
  const clr = m.items[2];
  assert(clr.classList.contains('bad'), 'clear logs is the danger item');
  const locks = locksIn(clr);
  assert.equal(locks.length, 1, 'clear logs carries the password lock');
  assert.equal(locks[0].getAttribute('role'), 'img');
  assert.equal(locks[0].getAttribute('aria-label'), 'sudo.lockTip');
  const title = all(clr, x => x.classList.contains('mt'));
  assert.equal(title.length, 1);
  assert(title[0].contains(locks[0]), 'the lock is next to the item title');
  assert.equal(title[0].textContent, 'logs.clear.btn');
  assert.equal(all(clr, x => x.classList.contains('md'))[0].textContent, 'logs.clear.menuDesc');
  m.items.slice(0, 2).forEach(it => assert.equal(locksIn(it).length, 0, 'no lock on ' + it.textContent));
  clr.fire('click'); await tick();
  assert.equal(cleared, 1); assert.equal(exported + settings, 0);
  assert(!document.body.children.includes(m.menu), 'choosing an item closes the menu');
  // 再打开: 新的菜单项带自己的小锁 (不是把上一次的挪过来)
  m = openMenu();
  const again = locksIn(m.items[2]);
  assert.equal(again.length, 1); assert.notEqual(again[0], locks[0]);
  m.items[0].fire('click'); await tick();
  assert.equal(exported, 1); assert.equal(cleared, 1);
}

(async () => {
  await nodeDialog();
  await sitesReset();
  await logsClearLock();
  console.log('PASS: node dialog body actions lock the dialog, site reset cannot start twice, the Clear logs menu item keeps its password lock');
})().catch(e => { console.error(e); process.exitCode = 1; });
