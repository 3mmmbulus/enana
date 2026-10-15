#!/usr/bin/env node
// 订阅刷新 (ui/v-servers.js 的订阅部分: 真实代码 + 真实的 ui/core.js / ui/ui.js, 假 DOM; 不需要浏览器, 不碰辅助服务, 全部是占位数据):
// 1. 打开仪表盘时的自动刷新先干跑 (dry=1): 没有变化 → 不开任务、没有进度卡片, 只有一个不起眼的提示 (辅助服务已经记下这次刷新)
// 2. 有变化、系统代理模式 → 静默应用 (background=1, 没有进度卡片), 完成后一个小提示, 写的是真实的数量
// 3. 有变化、应用要管理员授权 (辅助服务说 admin, 或者是 TUN 模式) → 不应用, 没有任务; 订阅这一行显示「订阅有更新 …」和「应用更新」;
//    刷新页面后还在; 订阅之后在别处刷新过 (更新时间变了) 就去掉; 同一组更新只提示一次
// 4. 「应用更新」→ 确认框 (一定带管理员授权的提示, 不提供「不再询问」) → 手动刷新 (进度卡片 + 任务), 成功后提示消失
// 5. 手动「刷新」照旧: 真实的数量「新增 · 有变化 · 移除 · 未变」, 什么都没变时「订阅已是最新」
// 6. autoCheck: 只刷新到期的订阅, 同一个订阅最多每小时试一次, 有任务在跑时不试
// 7. 词典: 用到的 servers.subs.* 键中英文都有, 占位符一致; 中文文案和需求一致
'use strict';
const fs = require('fs'), vm = require('vm'), assert = require('assert'), path = require('path');
const read = f => fs.readFileSync(path.join(__dirname, '..', f), 'utf8');
const tick = () => new Promise(r => setImmediate(r));
const settle = async () => { for (let i = 0; i < 40; i++) await tick(); };

/* ---------- 假 DOM (只实现这几个文件用到的部分) ---------- */
class El {
  constructor(tag) {
    this.tagName = tag; this.nodeType = tag === '#text' ? 3 : 1; this.children = []; this.attrs = {}; this.events = {}; this.text = ''; this.className = '';
    this.disabled = false; this.hidden = false; this.title = ''; this.value = ''; this.style = {}; this.parentNode = null;
    const self = this;
    this.classList = { contains: c => self.className.split(' ').includes(c), add: c => self.classList.toggle(c, true), remove: c => self.classList.toggle(c, false),
      toggle: (c, on) => { const s = new Set(self.className.split(' ').filter(Boolean)); if (on === undefined) on = !s.has(c); if (on) s.add(c); else s.delete(c); self.className = [...s].join(' '); return !!on; } };
  }
  get textContent() { return this.text + this.children.map(x => x.textContent).join(''); }
  set textContent(s) { this.children.forEach(c => { c.parentNode = null; }); this.children = []; this.text = String(s); }
  get firstChild() { return this.children[0] || null; }
  get nextSibling() { if (!this.parentNode) return null; const a = this.parentNode.children; return a[a.indexOf(this) + 1] || null; }
  setAttribute(k, v) { if (k === 'class') this.className = String(v); else this.attrs[k] = String(v); }
  getAttribute(k) { return k === 'class' ? (this.className || null) : (k in this.attrs ? this.attrs[k] : null); }
  removeAttribute(k) { if (k === 'title') this.title = ''; delete this.attrs[k]; }
  appendChild(c) { if (c.parentNode) c.parentNode.removeChild(c); this.children.push(c); c.parentNode = this; return c; }
  insertBefore(c, ref) { if (!ref) return this.appendChild(c); if (c.parentNode) c.parentNode.removeChild(c); this.children.splice(this.children.indexOf(ref), 0, c); c.parentNode = this; return c; }
  removeChild(c) { const i = this.children.indexOf(c); assert(i >= 0, 'removeChild of a node that is not a child'); this.children.splice(i, 1); c.parentNode = null; return c; }
  replaceChild(c, old) { this.insertBefore(c, old); this.removeChild(old); return old; }
  addEventListener(e, fn) { (this.events[e] = this.events[e] || []).push(fn); }
  removeEventListener(e, fn) { const a = this.events[e] || [], i = a.indexOf(fn); if (i >= 0) a.splice(i, 1); }
  fire(type) { const e = { type, target: this, preventDefault() {}, stopPropagation() {} }; (this.events[type] || []).slice().forEach(fn => fn(e)); }
  contains(x) { for (let n = x; n; n = n.parentNode) if (n === this) return true; return false; }
}
const all = (root, pred) => { const out = []; (function walk(n) { for (const c of n.children) { if (pred(c)) out.push(c); walk(c); } })(root); return out; };

/* ---------- 一个页面 (同一份 localStorage 可以开第二个页面, 测刷新页面后的状态) ---------- */
const storage = new Map();
const area = { getItem: k => (storage.has(k) ? storage.get(k) : null), setItem: (k, v) => storage.set(k, String(v)), removeItem: k => storage.delete(k), key: () => null };
const stored = k => (storage.has('enana.' + k) ? JSON.parse(storage.get('enana.' + k)) : undefined);
const nowSec = () => Math.floor(Date.now() / 1000);
const fmtVars = v => (v ? JSON.stringify(v) : '');
const plain = x => JSON.parse(JSON.stringify(x));         // 页面里 (另一个 vm 领域) 创建的对象 / 数组: 先转成这里的, deepStrictEqual 才会比较内容而不是原型

function page(o) {
  o = o || {};
  const document = {
    body: new El('body'), hidden: false, activeElement: null,
    createElement: tag => new El(tag), createTextNode: s => { const x = new El('#text'); x.text = String(s); return x; },
    getElementById: () => null, querySelectorAll: () => [], contains: x => document.body.contains(x), addEventListener() {}, removeEventListener() {}
  };
  const I = { lang: 'en', t: (k, v) => k + fmtVars(v), L: k => k, isL: () => false, has: () => false, attr: (e, k, v) => e.setAttribute(k, v), node: k => document.createTextNode(k) };
  const window = { I18N: I, localStorage: area, sessionStorage: area };
  const ctx = vm.createContext({ window, document, console, Promise, navigator: {}, setTimeout: () => 0, clearTimeout() {}, setInterval: () => 0, clearInterval() {} });
  vm.runInContext(read('ui/core.js'), ctx, { filename: 'core.js' });
  vm.runInContext(read('ui/ui.js'), ctx, { filename: 'ui.js' });
  const TP = window.TP, S = TP.S, log = { calls: [], cards: [], toasts: [], dialogs: [], follows: [], applied: 0, loads: 0 };
  let answers = o.answers || [], fetchErr = null, fetched = o.fetched || null;
  S.locked = false; S.clash = 'ok';
  S.state = { proxy: { network_mode: o.mode || 'system' },
    servers: [{ tag: 'A-1', role: 'pin', sub: 'A' }, { tag: 'A-2', role: 'auto', sub: 'A' }, { tag: 'M1', role: 'auto', sub: '' }],
    subs: [{ name: 'A', host: 'a.example', updated: o.updated || nowSec() - 13 * 3600, count: 2, interval: 12, usage: null }] };
  TP.fmt.rel = () => 'rel'; TP.fmt.usage = () => '';
  TP.why = { helper: () => '' }; TP.noHelper = () => false; TP.sudo = { mark: x => x }; TP.paintBtn = (b, st) => { b._st = st; };
  TP.exits = { subImpact: async () => null };
  TP.errMsg = e => (e && e.message) || String(e);
  TP.tunNote = () => (S.state.proxy.network_mode === 'tun' ? 'tun.admin.note' : null);
  TP.tunDetail = (detail, force) => ({ detail, force: !!force });
  TP.loadState = () => { log.loads++; return Promise.resolve(); };
  TP.afterApply = () => { log.applied++; };
  TP.subs = {};
  let active = 0;
  TP.jobs.active = () => active;
  TP.jobs.follow = async (id, card) => { log.follows.push({ id, card }); if (card && card.fromJob) card.fromJob({ pct: 50, msg: 'job.msg' }); return { state: 'done' }; };
  TP.jobs.runInDock = async (title, start) => { await start(); return { ok: true }; };
  TP.imp = { busy: () => false, fetchSub: async q => {
    log.fetches = (log.fetches || 0) + 1; log.fetchArg = q;
    if (fetchErr) throw fetchErr;
    // 导入器给的角色一律是 auto; A-9 带警告 (链接里没有账号密码) 而且不在这个订阅里: 不该被带上
    return fetched || { servers: [{ role: 'auto', outbound: { type: 'trojan', tag: 'A-1' }, warn: '' }, { role: 'auto', outbound: { type: 'trojan', tag: 'A-2' }, warn: '' }, { role: 'auto', outbound: { type: 'http', tag: 'A-9' }, warn: 'import.warn.noAuth' }],
      usage: { used: 10.4, total: 100, expire: 2000000000 }, interval: 0 };
  } };
  ctx.TPImporter = { toJSONL: (servers, sub) => servers.map(s => sub + '/' + s.outbound.tag + ':' + s.role).join('\n') + '\n' };
  let responder = () => { throw new Error('no responder'); };
  TP.helper = async (method, url, opt) => { log.calls.push({ method, url, q: Object.assign({}, opt && opt.q), body: opt && opt.body }); return responder(method, url, opt || {}); };
  TP.ui.taskCard = title => { const c = { title, sets: [], set(x) { this.sets.push(x); }, done(m) { this.doneMsg = m; }, fail(m) { this.failMsg = m; }, close() { this.closed = true; } }; log.cards.push(c); return c; };
  TP.ui.dock = () => {};
  TP.ui.toast = (msg, kind, ms, opt) => { log.toasts.push({ msg, kind, ms, opt }); };
  TP.ui.confirmDialog = d => { log.dialogs.push(d); return Promise.resolve(answers.length ? answers.shift() : true); };
  const el = { subs: new El('div'), subsSkel: { hidden: false }, subsEmpty: { hide() {}, show() {} } };
  window.F = { el, servers: () => S.state.servers, setTip: (b, s) => { b._tip = s; }, showSubUrl: () => Promise.resolve(), V: { render: () => { if (window.SUBS) window.SUBS.renderSubs(); } } };
  const src = read('ui/v-servers.js'), a = src.indexOf('  /* ================= 订阅 ================= */'), b = src.indexOf('  /* ================= 服务器详情', a + 1);
  assert(a > 0 && b > a, 'the subscription section of ui/v-servers.js');
  vm.runInContext('(function () { var TP = window.TP, S = TP.S, h = TP.h, ui = TP.ui, setText = TP.setText, I = window.I18N, t = I.t, L = I.L, F = window.F;\n' +
    'var V = F.V, el = F.el, servers = F.servers, setTip = F.setTip, showSubUrl = F.showSubUrl, refreshing = {}, refreshedAt = {};\n' + src.slice(a, b) +
    '\nwindow.SUBS = { renderSubs: renderSubs, autoCheck: autoCheck, pendOf: pendOf, refreshing: refreshing }; })();', ctx, { filename: 'v-servers.js (subscriptions)' });
  const row = () => { window.SUBS.renderSubs(); assert.strictEqual(el.subs.children.length, 1, 'one subscription row'); return el.subs.children[0]; };
  return { TP, S, log, window, el, row,
    respond: fn => { responder = fn; }, failFetch: e => { fetchErr = e; }, setActive: n => { active = n; }, answer: (...v) => { answers = v; },
    reset: () => { log.calls = []; log.cards = []; log.toasts = []; log.dialogs = []; log.follows = []; log.applied = 0; log.loads = 0; } };
}
const importer = (fn) => (method, url, opt) => { assert.strictEqual(method + ' ' + url, 'POST /api/servers/import'); return fn(opt.q || {}); };
const Q = { sub: 'A', mode: 'replace', interval: 12, used: 10, total: 100, expire: 2000000000 };     // 刷新间隔沿用现在的; 用量取这次下载的响应头 (取整)
const BODY = 'A/A-1:pin\nA/A-2:auto\n';                                                               // A-1 保留用户固定的角色; 带警告的 A-9 不在里面

(async () => {
  let p = page();

  /* ---- 1. 自动刷新, 没有变化 ---- */
  p.respond(importer(q => ({ ok: true, dry: true, same: true, recorded: true, admin: false, added: 0, replaced: 2, changed: 0, unchanged: 2, removed: 0, errors: [] })));
  let r = await p.TP.subs.refresh('A', true); await settle();
  assert.deepStrictEqual(plain(r), { ok: true, same: true });
  assert.strictEqual(p.log.calls.length, 1, 'only the dry run, no import job');
  assert.deepStrictEqual(p.log.calls[0].q, Object.assign({ dry: 1 }, Q));
  assert.strictEqual(p.log.calls[0].body, BODY);
  assert.deepStrictEqual(plain(p.log.fetchArg.existingTags), ['M1'], 'tags of other sources stay reserved');
  assert.strictEqual(p.log.cards.length, 0, 'no task card for an unchanged automatic refresh');
  assert.strictEqual(p.log.follows.length, 0); assert.strictEqual(p.log.applied, 0, 'nothing was applied');
  assert.deepStrictEqual(p.log.toasts.map(x => [x.msg, x.kind]), [['servers.subs.sameToast{"name":"A","n":2}', '']], 'one low-key toast');
  assert(stored('subtry.A') > 0, 'the attempt is remembered'); assert.strictEqual(stored('subpend.A'), undefined);
  assert.strictEqual(p.log.loads, 1, 'state reloaded (the helper recorded the new update time)');
  assert.strictEqual(p.row()._r.pend.hidden, true, 'no pending notice');

  /* ---- 2. 自动刷新, 有变化, 系统代理模式: 静默应用 ---- */
  p.reset();
  p.respond(importer(q => (q.dry ? { ok: true, dry: true, same: false, recorded: false, admin: false, added: 1, replaced: 2, changed: 1, unchanged: 1, removed: 0, errors: [] }
    : { ok: true, added: 1, replaced: 2, changed: 1, unchanged: 1, removed: 0, errors: [], job: 'servers-import-1' })));
  r = await p.TP.subs.refresh('A', true); await settle();
  assert.deepStrictEqual(plain(r), { ok: true });
  assert.deepStrictEqual(p.log.calls.map(c => c.q), [Object.assign({ dry: 1 }, Q), Object.assign({ background: 1 }, Q)], 'dry run first, then the background import (never prompts)');
  assert.strictEqual(p.log.calls[1].body, BODY);
  assert.deepStrictEqual(p.log.follows, [{ id: 'servers-import-1', card: null }], 'the job is followed without a task card');
  assert.strictEqual(p.log.cards.length, 0);
  assert.deepStrictEqual(p.log.toasts.map(x => [x.msg, x.kind]), [['servers.subs.doneToast{"name":"A","msg":"servers.subs.result{\\"added\\":1,\\"changed\\":1,\\"removed\\":0,\\"unchanged\\":1}"}', 'ok']]);
  assert.strictEqual(p.log.applied, 1);

  /* ---- 3. 自动刷新, 有变化, 应用要管理员授权: 不应用, 显示待应用的更新 ---- */
  p.reset();
  const dryAdmin = () => importer(q => { assert.strictEqual(q.dry, 1, 'only dry runs while an update waits for the user'); return { ok: true, dry: true, same: false, recorded: false, admin: true, added: 2, replaced: 1, changed: 1, unchanged: 0, removed: 3, errors: [] }; });
  p.respond(dryAdmin());
  r = await p.TP.subs.refresh('A', true); await settle();
  assert.deepStrictEqual(plain(r), { ok: true, pending: true });
  assert.strictEqual(p.log.calls.length, 1, 'no import job'); assert.strictEqual(p.log.follows.length, 0); assert.strictEqual(p.log.cards.length, 0); assert.strictEqual(p.log.applied, 0);
  const upd0 = p.S.state.subs[0].updated;
  assert.deepStrictEqual(stored('subpend.A'), { added: 2, changed: 1, removed: 3, unchanged: 0, admin: true, u: upd0 }, 'the pending update is kept in this browser');
  assert.strictEqual(p.log.toasts.length, 1); assert.strictEqual(p.log.toasts[0].msg, 'servers.subs.pendingToast{"name":"A"}'); assert.strictEqual(p.log.toasts[0].kind, '');
  assert.strictEqual(p.log.toasts[0].opt.action.label, 'servers.subs.applyUpdate', 'the toast offers to apply');
  let rw = p.row();
  assert.strictEqual(rw._r.pend.hidden, false, 'the subscription row shows the pending update');
  assert.strictEqual(rw._r.pendTxt.textContent, 'servers.subs.pending{"added":2,"changed":1,"removed":3}');
  assert(rw._r.pend.contains(rw._r.apply) && rw._r.apply.textContent.includes('servers.subs.applyUpdate'), 'with an "Apply update" button');
  assert(rw._r.meta.textContent.indexOf('servers.subs.due') < 0, 'no "will refresh automatically" while it waits for the user');
  p.reset(); r = await p.TP.subs.refresh('A', true); await settle();
  assert.deepStrictEqual(plain(r), { ok: true, pending: true }); assert.strictEqual(p.log.toasts.length, 0, 'the same pending update is announced only once');

  // 刷新页面: 提示还在 (另一个页面, 同一份 localStorage)
  p = page({ updated: upd0 });
  rw = p.row();
  assert.strictEqual(rw._r.pend.hidden, false, 'the notice survives a page reload');
  assert(!rw._r.meta.textContent.includes('servers.subs.due'));

  // TUN 模式: 辅助服务没说 admin, 也照样等用户
  let t2 = page({ mode: 'tun', updated: upd0 - 60 });
  t2.respond(importer(q => { assert.strictEqual(q.dry, 1); return { ok: true, dry: true, same: false, recorded: false, admin: false, added: 0, replaced: 2, changed: 2, unchanged: 0, removed: 0, errors: [] }; }));
  r = await t2.TP.subs.refresh('A', true); await settle();
  assert.deepStrictEqual(plain(r), { ok: true, pending: true }); assert.strictEqual(t2.log.calls.length, 1); assert.strictEqual(t2.log.follows.length, 0);
  assert.deepStrictEqual(stored('subpend.A'), { added: 0, changed: 2, removed: 0, unchanged: 0, admin: true, u: upd0 - 60 });

  // 订阅之后在别处刷新过 (更新时间变了): 提示过时, 去掉
  t2.S.state.subs[0].updated = nowSec();
  assert.strictEqual(t2.row()._r.pend.hidden, true, 'a later refresh elsewhere clears the notice');
  assert.strictEqual(stored('subpend.A'), undefined);

  /* ---- 4. 「应用更新」: 确认 (带管理员授权的提示, 不提供「不再询问」) → 手动刷新 ---- */
  p = page({ updated: upd0 });
  p.respond(dryAdmin()); await p.TP.subs.refresh('A', true); await settle();
  assert.strictEqual(p.row()._r.pend.hidden, false);
  p.reset();
  p.respond(importer(q => { assert(!('dry' in q) && !('background' in q), 'the user-approved apply is a normal import'); return { ok: true, added: 2, replaced: 1, changed: 1, unchanged: 0, removed: 3, errors: [], job: 'servers-import-2' }; }));
  p.answer(false);
  p.row()._r.apply.fire('click'); await settle();
  assert.strictEqual(p.log.dialogs.length, 1); assert.strictEqual(p.log.calls.length, 0, 'cancel: nothing happens');
  let d = p.log.dialogs[0];
  assert.strictEqual(d.confirmText, 'servers.subs.applyUpdate'); assert.strictEqual(d.detail.force, true, 'the confirm always carries the administrator note');
  assert.strictEqual(d.rememberKey, null, 'no "don\'t ask again" for an update that needs administrator authorization');
  assert.strictEqual(p.row()._r.pend.hidden, false, 'still pending after cancel');
  p.answer(true); p.reset();
  p.row()._r.apply.fire('click'); await settle();
  assert.strictEqual(p.log.dialogs.length, 1);
  assert.deepStrictEqual(p.log.calls.map(c => c.q), [Q]);
  assert.strictEqual(p.log.cards.length, 1, 'a task card, like any manual refresh'); assert.strictEqual(p.log.cards[0].title, 'servers.subs.refreshJob{"name":"A"}');
  assert.strictEqual(p.log.follows.length, 1); assert.strictEqual(p.log.follows[0].id, 'servers-import-2'); assert(p.log.follows[0].card && typeof p.log.follows[0].card.fromJob === 'function');
  assert.strictEqual(p.log.cards[0].doneMsg, 'servers.subs.result{"added":2,"changed":1,"removed":3,"unchanged":0}');
  assert.deepStrictEqual(p.log.toasts.map(x => x.kind), ['ok']);
  assert.strictEqual(stored('subpend.A'), undefined, 'applied: the pending update is gone');
  assert.strictEqual(p.row()._r.pend.hidden, true);
  assert.strictEqual(p.log.applied, 1);

  /* ---- 5. 手动「刷新」: 照旧开任务, 写真实的数量; 什么都没变时「订阅已是最新」 ---- */
  p.reset();
  p.respond(importer(q => { assert(!('dry' in q)); return { ok: true, added: 0, replaced: 2, changed: 0, unchanged: 2, removed: 0, errors: [], job: 'servers-import-3' }; }));
  p.row()._r.refresh.fire('click'); await settle();
  d = p.log.dialogs[0];
  assert.strictEqual(d.confirmText, 'servers.subs.refresh'); assert.strictEqual(d.rememberKey, 'subrefresh'); assert.strictEqual(d.detail.force, false, 'the usual TUN note only (TP.tunDetail decides)');
  assert.deepStrictEqual(p.log.calls.map(c => c.q), [Q]); assert.strictEqual(p.log.follows[0].id, 'servers-import-3');
  assert.strictEqual(p.log.cards.length, 1); assert.strictEqual(p.log.cards[0].doneMsg, 'servers.subs.upToDate{"n":2}');
  assert.deepStrictEqual(p.log.toasts.map(x => [x.msg, x.kind]), [['servers.subs.sameToast{"name":"A","n":2}', 'ok']]);
  // 老的辅助服务 (没有 changed / unchanged): 退回 replaced, 不会把「替换了 2 个」说成「已是最新」
  p.reset();
  p.respond(importer(() => ({ ok: true, added: 0, replaced: 2, removed: 0, errors: [], job: 'servers-import-4' })));
  await p.TP.subs.refresh('A', false); await settle();
  assert.strictEqual(p.log.cards[0].doneMsg, 'servers.subs.result{"added":0,"changed":2,"removed":0,"unchanged":0}');

  /* ---- 自动刷新失败: 只有一个警告提示, 没有进度卡片 ---- */
  p.reset(); p.failFetch(new Error('download failed'));
  r = await p.TP.subs.refresh('A', true); await settle();
  assert.strictEqual(r.ok, false); assert.strictEqual(p.log.cards.length, 0); assert.strictEqual(p.log.calls.length, 0);
  assert.deepStrictEqual(p.log.toasts.map(x => [x.msg, x.kind]), [['servers.subs.autoFail{"name":"A","reason":"download failed"}', 'warn']]);
  p.failFetch(null);

  /* ---- 6. autoCheck: 只刷新到期的; 同一个订阅最多每小时试一次; 有任务在跑时不试 ---- */
  storage.clear();
  let c = page();
  c.respond(importer(() => ({ ok: true, dry: true, same: true, recorded: true, admin: false, added: 0, replaced: 2, changed: 0, unchanged: 2, removed: 0, errors: [] })));
  c.setActive(1); c.window.SUBS.autoCheck(); await settle();
  assert.strictEqual(c.log.calls.length, 0, 'not while a job is running');
  c.setActive(0); c.window.SUBS.autoCheck(); await settle();
  assert.strictEqual(c.log.calls.length, 1, 'a due subscription is checked'); assert.strictEqual(c.log.calls[0].q.dry, 1, 'automatic checks always start with a dry run');
  c.window.SUBS.autoCheck(); await settle();
  assert.strictEqual(c.log.calls.length, 1, 'tried less than an hour ago: not again');
  storage.set('enana.subtry.A', JSON.stringify(Date.now() - 3600001)); c.S.state.subs[0].updated = nowSec() - 60;
  c.window.SUBS.autoCheck(); await settle();
  assert.strictEqual(c.log.calls.length, 1, 'refreshed within its interval: not due');
  c.S.state.subs[0].updated = nowSec() - 12 * 3600 - 60; c.window.SUBS.autoCheck(); await settle();
  assert.strictEqual(c.log.calls.length, 2, 'due again after a full interval');

  /* ---- 7. 词典 ---- */
  const dictOf = code => {
    const dict = {}, box = { I18N: { register: (cc, dd) => { Object.assign(dict[cc] || (dict[cc] = {}), dd); } } };
    box.window = box.self = box.globalThis = box;
    vm.runInNewContext(read('ui/i18n/' + code + '.js'), box, { filename: code + '.js' });
    return dict[code];
  };
  const names = v => [...new Set((typeof v === 'string' ? v : Object.values(v).join(' ')).match(/\{\w+\}/g) || [])].map(m => m.slice(1, -1)).sort();
  const zh = dictOf('zh'), en = dictOf('en');
  const want = { 'servers.subs.result': ['added', 'changed', 'removed', 'unchanged'], 'servers.subs.upToDate': ['n'], 'servers.subs.sameToast': ['n', 'name'], 'servers.subs.pending': ['added', 'changed', 'removed'],
    'servers.subs.pendingToast': ['name'], 'servers.subs.applyUpdate': [], 'servers.subs.doneToast': ['msg', 'name'], 'servers.subs.autoFail': ['name', 'reason'], 'servers.subs.refreshJob': ['name'] };
  for (const k of Object.keys(want)) {
    assert(zh[k] !== undefined && en[k] !== undefined, k + ' in both dictionaries');
    assert.deepStrictEqual(names(zh[k]), want[k], k + ' (zh) placeholders'); assert.deepStrictEqual(names(en[k]), want[k], k + ' (en) placeholders');
    if (typeof en[k] === 'object') assert.deepStrictEqual(names(en[k].other), want[k], k + ' (en, other) placeholders');
  }
  assert.strictEqual(zh['servers.subs.result'], '新增 {added} · 有变化 {changed} · 移除 {removed} · 未变 {unchanged}');
  assert.strictEqual(zh['servers.subs.upToDate'], '订阅已是最新（{n} 个节点未变）');
  assert.strictEqual(zh['servers.subs.pending'], '订阅有更新（新增 {added}、有变化 {changed}、移除 {removed}），应用需要管理员授权');
  assert.strictEqual(zh['servers.subs.applyUpdate'], '应用更新');
  assert.strictEqual(zh['servers.subs.autoJob'], undefined, 'the automatic refresh has no task card any more');
  assert(!read('ui/v-servers.js').includes('servers.subs.autoJob'));

  console.log('PASS: automatic subscription refresh dry-runs first (unchanged: recorded, no task card, one quiet toast; system proxy: silent background apply; ' +
    'administrator needed: no apply, a pending notice with "Apply update" that survives a reload and clears after a later refresh), manual refresh shows honest counts, hourly/interval cadence, dictionary keys');
})().catch(e => { console.error(e); process.exitCode = 1; });
