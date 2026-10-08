/* 出口分配 (ui/exits.js + ui/data.js 的出口辅助函数): 用假的 TP / 假的 DOM 直接加载真实的脚本, 不需要浏览器。
 *   · 总览模型: 每个固定出口 / 跟随默认 / 自动选 / 孤儿; 默认出口怎么确定
 *   · 出口选择器: 「默认 (当前是哪一个)」; 只有一个固定出口时只读; 孤儿的原因 (已删除 / 不再是固定出口 / 超出上限)
 *   · 换默认固定出口的事前检查: 没有谁跟随 → 普通确认; 有 → 列出来, 选「继续走原出口」(先钉住再切换) 或「跟着换」; 取消什么也不改; 读不到明细 → 退回普通确认
 *   · 删除 / 改角色的事前检查: 去向下拉、不改派必须勾选「我知道」、唯一的固定出口只能明确接受、默认出口的 freeze
 *   · 改派对话框 → POST /api/exits/move 的参数; 总览卡片的渲染
 * 用法: node tests/exits-ui.test.js */
const assert = require('assert');
const fs = require('fs');
const vm = require('vm');
const path = require('path');

const same = (a, b, m) => assert.strictEqual(JSON.stringify(a), JSON.stringify(b), m);      // vm 里创建的对象和这里不是同一个 realm, 不能用 deepStrictEqual
const tick = () => new Promise(r => setImmediate(r));

/* ---------- 假的 DOM ---------- */
class Txt { constructor(s) { this.t = s; } }
class El {
  constructor(tag) { this.tag = tag; this.children = []; this.attrs = {}; this.handlers = {}; this.className = ''; this.hidden = false; this.value = ''; this.checked = false; this.textContent = null; }
  appendChild(c) { this.children.push(c); return c; }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  addEventListener(ev, fn) { (this.handlers[ev] = this.handlers[ev] || []).push(fn); }
  dispatch(ev) { (this.handlers[ev] || []).forEach(fn => fn({ target: this, preventDefault() {} })); }
  get text() { return (this.textContent == null ? '' : this.textContent) + this.children.map(c => c instanceof Txt ? c.t : c.text).join(''); }
}
function h(tag, props, ...kids) {
  const el = new El(tag);
  if (props) for (const [k, v] of Object.entries(props)) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k === 'text') el.textContent = v;
    else if (k === 'on') for (const [ev, fn] of Object.entries(v)) el.addEventListener(ev, fn);
    else if (k === 'value') el.value = v;
    else if (['checked', 'disabled', 'selected', 'hidden', 'open'].includes(k)) el[k] = v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  const add = list => list.forEach(k => { if (k == null || k === false || k === true) return; if (Array.isArray(k)) return add(k); el.appendChild(typeof k === 'object' ? k : new Txt(String(k))); });
  add(kids);
  return el;
}
function find(root, pred, out = []) {
  if (root instanceof El) { if (pred(root)) out.push(root); root.children.forEach(c => find(c, pred, out)); }
  return out;
}
const byTag = (root, tag) => find(root, e => e.tag === tag);

/* ---------- 加载真实脚本 ---------- */
function setup(over = {}) {
  const log = { helper: [], toasts: [], confirms: [], modals: [], dock: [], policy: [], avail: [], applied: 0, emits: [] };
  const cfg = Object.assign({
    servers: [{ tag: 'Pin-A', role: 'pin' }, { tag: 'Pin-B', role: 'pin' }, { tag: 'Pin-C', role: 'pin' }, { tag: 'Auto-1', role: 'auto' }],
    pinNow: 'Pin-A', confirm: true, impact: null, impactErr: null, exits: null, moveResp: { ok: true, moved: { apps: 1, sites: 2, services: 3 } }, dockOk: true
  }, over);
  const bus = {};
  const I18N = { lang: 'en', t: (k, p) => k + (p ? JSON.stringify(p) : ''), L: k => k, isL: () => false, has: () => true, pick: e => e.name };
  const S = { state: { servers: cfg.servers }, proxies: { PIN: { now: cfg.pinNow } }, exits: null, svcByTag: { 'svc-chatgpt': { group: 'ai', name: 'N:chatgpt' }, 'svc-claude': { group: 'ai', name: 'N:claude' }, 'svc-news': { group: 'media', name: 'N:news' } } };
  const TP = {
    S, h, I18N, V: {}, cfg: {},
    on: (ev, fn) => { (bus[ev] = bus[ev] || []).push(fn); },
    emit: (ev, d) => { log.emits.push(ev); (bus[ev] || []).forEach(fn => fn(d)); },
    setText: (el, v) => { el.textContent = String(v); },
    clear: el => { el.children = []; return el; },
    opt: (v, label) => h('option', { value: v }, label),
    enc: encodeURIComponent, ls: { get: (k, d) => d, set() {} },
    name: { role: r => 'role:' + r },
    afterApply: () => { log.applied++; },
    setPolicy: async (tag, name) => { log.policy.push([tag, name]); },
    jobs: {
      runInDock: async (title, start) => { log.dock.push(title); const res = await start(); return cfg.dockOk ? { ok: true, res } : { ok: false, error: new Error('failed') }; }
    },
    helper: async (method, p, opts) => {
      log.helper.push([method, p, opts && opts.q]);
      if (p === '/api/exits/impact') { if (cfg.impactErr) throw cfg.impactErr; return cfg.impact; }
      if (p === '/api/exits') return cfg.exits || { ok: true, default: { tag: cfg.pinNow }, pins: [] };
      if (p === '/api/exits/move' || p === '/api/exits/freeze') return cfg.moveResp;
      throw new Error('unexpected ' + p);
    },
    ui: {
      confirmDialog: async o => { log.confirms.push(o); return cfg.confirm; },
      toast: (...a) => log.toasts.push(a),
      btn: (label, o) => { const b = h('button', { class: 'btn' }, label); b.label = label; b.opts = o; return b; },
      act: (el, fn) => { el._act = fn; },
      badge: (text, kind) => { const b = h('span', { class: 'badge ' + (kind || '') }, text); b.kind = kind; return b; },
      icon: () => h('i'), help: () => h('button', { class: 'help-i' }),
      avail: (el, reason) => { el._un = reason ? { reason } : null; log.avail.push([el, reason]); },
      modal: o => {
        let resolve; const api = { closed: new Promise(r => { resolve = r; }), isClosed: false, close(v) { if (api.isClosed) return; api.isClosed = true; resolve(v); } };
        api.content = typeof o.body === 'function' ? o.body(api) : o.body;
        api.o = o; log.modals.push(api); return api;
      }
    }
  };
  const win = { TP, I18N };
  const ctx = { window: win, console, Date, JSON, Promise, setTimeout, clearTimeout, Math, Array, Object, String, Number, encodeURIComponent };
  for (const f of ['data.js', 'exits.js']) vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../ui/' + f), 'utf8'), ctx, { filename: f });
  Object.assign(S, { state: { servers: cfg.servers }, proxies: { PIN: { now: cfg.pinNow } }, exits: null, svcByTag: { 'svc-chatgpt': { group: 'ai', name: 'N:chatgpt' }, 'svc-claude': { group: 'ai', name: 'N:claude' }, 'svc-news': { group: 'media', name: 'N:news' } } });     // data.js 加载时会把这些清空: 加载之后再放夹具
  TP.afterApply = () => { log.applied++; };                                                         // data.js 里的真实实现会去刷新状态 / 应用列表: 这里只计数
  TP.setPolicy = async (tag, name) => { log.policy.push([tag, name]); };                           // 同上: 真实实现 POST /api/policy 并刷新代理
  return { TP, S, log, X: TP.exits, I18N, cfg };
}
/* 模拟用户点弹窗里的按钮 (和 ui.modal 的 renderActions 一样: cancel 关闭为 cancel; onClick 返回 false / keep 不关闭; 否则以 value 关闭) */
async function press(m, id) {
  const a = m.o.actions.find(x => x.id === id || (id === 'cancel' && x.cancel));
  assert.ok(a, 'no action ' + id);
  if (a.cancel) { m.close('cancel'); return; }
  const r = a.onClick ? await a.onClick(m) : undefined;
  if (r === false || a.keep) return;
  m.close(a.value !== undefined ? a.value : true);
}
const impactDefault = (extra = {}) => Object.assign({ ok: true, op: 'default', tag: 'Pin-B', is_pin: true, default: 'Pin-A', default_changes: true, bound: { apps: [], sites: [], services: [] },
  follow: { apps: ['ChatGPT', 'Cursor'], sites: ['a.io'], services: ['svc-chatgpt', 'svc-news'], dns: false }, affected: 5, remaining: 2, candidates: [], services_known: true }, extra);
const impactRemove = (extra = {}) => Object.assign({ ok: true, op: 'remove', tag: 'Pin-B', is_pin: true, default: 'Pin-A', default_changes: false, bound: { apps: ['Cursor'], sites: ['b.io'], services: ['svc-claude'] },
  follow: { apps: [], sites: [], services: [], dns: false }, affected: 3, remaining: 2, candidates: [{ tag: 'Pin-A', targetable: true }, { tag: 'Pin-C', targetable: true }], services_known: true }, extra);

(async () => {
  let c, r, m;

  /* ===== 1. 出口选择器的辅助函数 (data.js 的上限 + exits.js 的显示) ===== */
  c = setup();
  assert.strictEqual(c.TP.PIN_MAX, 32, '可以单独指定的固定出口上限和后端 OVR_PIN_MAX 一致');
  same(c.TP.pinServers(), ['Pin-A', 'Pin-B', 'Pin-C']);
  assert.ok(c.TP.hasPin() && c.TP.canPickPin());
  const many = Array.from({ length: 40 }, (_, i) => ({ tag: 'N' + i, role: 'pin' }));
  c = setup({ servers: many });
  assert.strictEqual(c.TP.pinServers().length, 32, 'TP.pinServers 只列前 32 个');
  c = setup({ servers: [{ tag: 'Only', role: 'pin' }], pinNow: 'Only' });
  assert.ok(c.TP.hasPin() && !c.TP.canPickPin(), '一个固定出口: 看得到, 不能指定');
  c = setup({ servers: [{ tag: 'Auto-1', role: 'auto' }], pinNow: 'direct' });
  assert.ok(!c.TP.hasPin());

  c = setup(); const X = c.X;
  assert.strictEqual(X.defaultTag(), 'Pin-A', '默认出口 = 核心里 PIN 选择器选中的');
  c.S.proxies.PIN.now = 'Pin-C'; assert.strictEqual(X.defaultTag(), 'Pin-C');
  c.S.proxies.PIN.now = 'direct'; c.S.exits = { default: { tag: 'Pin-B' } }; assert.strictEqual(X.defaultTag(), 'Pin-B', '核心没给出时用后端告诉的');
  c.S.exits = null; assert.strictEqual(X.defaultTag(), 'Pin-A', '都没有: 第一个固定出口');
  c.S.proxies.PIN.now = 'Pin-A';
  assert.strictEqual(X.targetName('PIN'), 'apps.tg.defaultNow{"tag":"Pin-A"}', '「默认」旁边显示它现在是哪一个');
  assert.strictEqual(X.targetName(''), X.targetName('PIN'));
  assert.strictEqual(X.targetName('PINAUTO'), 'apps.tg.auto');
  assert.strictEqual(X.targetName('Pin-B'), 'Pin-B');
  assert.ok(X.targetDetail('PIN').indexOf('apps.tg.dDefault{"tag":"PIN","def":"Pin-A"}') === 0, '说明里带上当前默认出口');
  assert.ok(X.targetDetail('Pin-B').indexOf('apps.tg.dOne') === 0 && X.targetDetail('PINAUTO').indexOf('apps.tg.dAuto') === 0);
  const sel = h('select'); X.fillTargets(sel);
  same(sel.children.map(o => o.value), ['PIN', 'PINAUTO', 'Pin-A', 'Pin-B', 'Pin-C'], '2 个以上: 默认 / 自动选 / 每个固定出口');
  assert.strictEqual(sel.children[0].text, 'apps.tg.defaultNow{"tag":"Pin-A"}');
  const n1 = sel.children.length; X.fillTargets(sel); assert.strictEqual(sel.children.length, n1, '没有变化不重画 (保留用户的操作)');
  c.S.proxies.PIN.now = 'Pin-B'; X.fillTargets(sel); assert.strictEqual(sel.children[0].text, 'apps.tg.defaultNow{"tag":"Pin-B"}', '默认出口换了: 选项文字跟着更新');
  X.targetAvail(sel, ''); assert.strictEqual(sel._un, null, '2 个以上: 可以改');
  X.targetAvail(sel, '核心没运行'); assert.strictEqual(sel._un.reason, '核心没运行', '通用原因优先');
  c = setup({ servers: [{ tag: 'Only', role: 'pin' }], pinNow: 'Only' });
  const sel1 = h('select'); c.X.fillTargets(sel1);
  same(sel1.children.map(o => o.value), ['PIN'], '只有一个固定出口: 只有「默认 (它)」一项');
  assert.strictEqual(sel1.children[0].text, 'apps.tg.defaultNow{"tag":"Only"}');
  c.X.targetAvail(sel1, ''); assert.strictEqual(sel1._un.reason, 'apps.tg.single', '…并说明为什么不能选');
  c = setup({ servers: [{ tag: 'Pin-A', role: 'pin' }, { tag: 'Auto-1', role: 'auto' }].concat(Array.from({ length: 32 }, (_, i) => ({ tag: 'P' + i, role: 'pin' }))) });
  assert.strictEqual(c.X.orphanWhy('Gone'), 'deleted'); assert.strictEqual(c.X.orphanWhy('Auto-1'), 'role');
  assert.strictEqual(c.X.orphanWhy('P31'), 'cap', '服务器还是固定出口, 但排在上限之后');
  c.S.proxies.PIN.now = 'Pin-A';
  assert.strictEqual(c.X.orphanText('Gone'), 'apps.tg.gone{"tag":"Gone","def":"Pin-A","why":"exits.why.deleted"}', '孤儿的提示: 哪个出口 / 为什么 / 现在实际用的是哪个默认出口');
  assert.strictEqual(c.X.orphanText('Auto-1'), 'apps.tg.gone{"tag":"Auto-1","def":"Pin-A","why":"exits.why.role"}');

  /* ===== 2. 总览模型 ===== */
  c = setup(); const D = {
    ok: true, default: { tag: 'Pin-B', source: 'live' }, max: 32, count: 3, services_known: true,
    pins: [{ tag: 'Pin-A', targetable: true, default: false, apps: ['Cursor'], sites: ['a.io', 'b.io'], services: [] }, { tag: 'Pin-B', targetable: true, default: true, apps: [], sites: [], services: ['svc-claude'] }, { tag: 'Pin-Z', targetable: false, default: false, apps: [], sites: [], services: [] }],
    follow: { apps: ['ChatGPT'], sites: [], services: ['svc-chatgpt'], dns: true }, auto: { apps: [], sites: ['c.io'], services: [] },
    orphans: [{ kind: 'site', name: 'gone.io', target: 'Old-1', reason: 'deleted' }, { kind: 'app', name: 'Foo', target: 'Auto-1', reason: 'role' }], orphan_count: 2
  };
  r = c.X.model(D);
  assert.strictEqual(r.def, 'Pin-B');
  same(r.pins.map(p => [p.tag, p.n, p.isDefault, p.targetable]), [['Pin-A', 3, false, true], ['Pin-B', 1, true, true], ['Pin-Z', 0, false, false]]);
  assert.strictEqual(r.follow.n, 3, '跟随默认: 1 应用 + 1 服务 + DNS (线路设为固定出口也跟着默认走)');
  assert.strictEqual(r.auto.n, 1); assert.strictEqual(r.orphans.length, 2); assert.strictEqual(r.total, 3 + 1 + 0 + 2 + 1 + 2);
  r = c.X.model(null); assert.ok(r.pins.length === 0 && r.total === 0 && r.follow.n === 0, '没有数据也不出错');
  c.S.exits = D; assert.ok(c.X.followLine().indexOf('servers.pin.follow{"n":3,"apps":1,"sites":0,"svc":1}') === 0);
  c.S.exits = Object.assign({}, D, { follow: { apps: [], sites: [], services: [], dns: false } }); assert.strictEqual(c.X.followLine(), 'servers.pin.followNone');
  c.S.exits = null; assert.strictEqual(c.X.followLine(), ''); assert.strictEqual(c.X.orphanCount(), 0);
  c.S.exits = D; assert.strictEqual(c.X.orphanCount(), 2);
  assert.strictEqual(c.X.riskCount({ svc: ['svc-chatgpt', 'svc-news', 'svc-claude'], app: [], site: [] }), 2, '对 IP 变化敏感的服务 (AI / 账号 / 交易所)');

  /* ===== 3. 换默认固定出口的事前检查 ===== */
  // 3a. 没有谁跟随默认: 不弹对话框, 调用方走普通确认
  c = setup({ impact: impactDefault({ follow: { apps: [], sites: [], services: [], dns: false }, affected: 0 }) });
  r = await c.X.askDefault('Pin-A', 'Pin-B'); same(r, { none: true }); assert.strictEqual(c.log.modals.length, 0);
  same(c.log.helper[0], ['GET', '/api/exits/impact', { op: 'default', tag: 'Pin-B' }], '问的是「换成 Pin-B 会影响谁」');
  // 3b. 有人跟随: 列出来, 默认选「继续走原出口」
  c = setup({ impact: impactDefault() });
  let p = c.X.askDefault('Pin-A', 'Pin-B'); await tick();
  assert.strictEqual(c.log.modals.length, 1); m = c.log.modals[0];
  const txt = m.content.text;
  for (const name of ['ChatGPT', 'Cursor', 'a.io', 'N:chatgpt', 'N:news']) assert.ok(txt.indexOf(name) >= 0, '受影响的列在对话框里: ' + name);
  assert.ok(txt.indexOf('exits.risk{"n":1}') >= 0, '提示其中有 1 个对出口 IP 敏感的服务 (ChatGPT)');
  const radios = byTag(m.content, 'input').filter(i => i.attrs.type === 'radio');
  same(radios.map(i => [i.value, i.checked]), [['keep', true], ['follow', false]], '默认选中「继续走原出口」(安全的那个)');
  await press(m, 'go'); same(await p, { freeze: true });
  p = c.X.askDefault('Pin-A', 'Pin-B'); await tick(); m = c.log.modals[1];
  const rf = byTag(m.content, 'input').filter(i => i.attrs.type === 'radio')[1]; rf.checked = true; rf.dispatch('change');
  await press(m, 'go'); same(await p, { freeze: false }, '选「跟着换」');
  p = c.X.askDefault('Pin-A', 'Pin-B'); await tick(); await press(c.log.modals[2], 'cancel'); assert.strictEqual(await p, null, '取消');
  // 3c. 读不到明细 (旧版辅助服务): 退回普通确认; 登录失效照常抛出
  c = setup({ impactErr: Object.assign(new Error('not found'), { kind: 'http' }) });
  same(await c.X.askDefault('Pin-A', 'Pin-B'), { legacy: true }); assert.strictEqual(c.log.modals.length, 0);
  c = setup({ impactErr: Object.assign(new Error('auth'), { kind: 'auth' }) });
  await assert.rejects(c.X.askDefault('Pin-A', 'Pin-B'), /auth/);

  /* ===== 4. 换默认的完整流程: 先钉住再切换 ===== */
  const flow = async (impact, choose, plain) => {
    const k = setup({ impact });
    const pr = k.X.switchDefault('Pin-A', 'Pin-B', plain);
    await tick();
    if (k.log.modals.length) { const mm = k.log.modals[0]; if (choose === 'follow') { const rr = byTag(mm.content, 'input').filter(i => i.attrs.type === 'radio')[1]; rr.checked = true; rr.dispatch('change'); } await press(mm, choose === 'cancel' ? 'cancel' : 'go'); }
    return { k, done: await pr };
  };
  let f = await flow(impactDefault(), 'keep');
  assert.strictEqual(f.done, true);
  same(f.k.log.helper.filter(x => x[0] === 'POST').map(x => x[1]), ['/api/exits/freeze'], '选「继续走原出口」: 先 POST /api/exits/freeze (把跟随默认的钉在原出口上)');
  same(f.k.log.policy, [['PIN', 'Pin-B']], '…然后才切换默认出口');
  assert.ok(f.k.log.helper.findIndex(x => x[1] === '/api/exits/freeze') < f.k.log.helper.length, 'freeze 在切换之前');
  f = await flow(impactDefault(), 'follow');
  assert.strictEqual(f.done, true); same(f.k.log.helper.filter(x => x[0] === 'POST'), [], '选「跟着换」: 不钉住'); same(f.k.log.policy, [['PIN', 'Pin-B']]);
  f = await flow(impactDefault(), 'cancel');
  assert.strictEqual(f.done, false); same(f.k.log.policy, [], '取消: 什么也不改'); same(f.k.log.helper.filter(x => x[0] === 'POST'), []);
  let asked = 0;
  f = await flow(impactDefault({ follow: { apps: [], sites: [], services: [], dns: false }, affected: 0 }), '', async pre => { asked++; assert.ok(pre.none); return true; });
  assert.strictEqual(f.done, true); assert.strictEqual(asked, 1, '没有谁跟随: 走调用方的普通确认'); same(f.k.log.policy, [['PIN', 'Pin-B']]);
  f = await flow(impactDefault({ follow: { apps: [], sites: [], services: [], dns: false }, affected: 0 }), '', async () => false);
  assert.strictEqual(f.done, false); same(f.k.log.policy, [], '普通确认被取消: 不切换');
  {
    const k = setup({ impactErr: Object.assign(new Error('x'), { kind: 'http' }) }); let seen = null;
    assert.strictEqual(await k.X.switchDefault('Pin-A', 'Pin-B', async pre => { seen = pre; return true; }), true);
    assert.ok(seen.legacy, '读不到影响明细: 普通确认 (旧版辅助服务照常能换)'); same(k.log.policy, [['PIN', 'Pin-B']]);
  }
  {
    const k = setup({ impact: impactDefault(), moveResp: { ok: true, job: 'exits-move-1' } });   // TUN: 钉住是后台任务, 切换必须等它结束
    const pr = k.X.switchDefault('Pin-A', 'Pin-B'); await tick(); await press(k.log.modals[0], 'go'); assert.strictEqual(await pr, true);
    assert.strictEqual(k.log.dock.length, 1, 'TUN 下的钉住显示在 dock 里, 完成后才切换'); same(k.log.policy, [['PIN', 'Pin-B']]);
  }
  {
    const k = setup({ impact: impactDefault(), moveResp: { ok: true, job: 'exits-move-1' }, dockOk: false });
    const pr = k.X.switchDefault('Pin-A', 'Pin-B'); await tick(); await press(k.log.modals[0], 'go');
    await assert.rejects(pr, /failed/); same(k.log.policy, [], '钉住失败 (例如取消了管理员授权): 不切换默认出口, 跟随默认的原样');
  }

  /* ===== 5. 删除 / 改角色的事前检查 ===== */
  const S1 = { tag: 'Pin-B', role: 'pin' };
  c = setup({ impact: impactRemove({ affected: 0, bound: { apps: [], sites: [], services: [] } }) });
  same(await c.X.askRemove(S1, ''), {}); assert.strictEqual(c.log.modals.length, 0);
  same(c.log.helper[0], ['GET', '/api/exits/impact', { op: 'remove', tag: 'Pin-B' }]);
  c = setup({ impact: impactRemove({ is_pin: false }) }); same(await c.X.askRemove(S1, 'auto'), {}, '它现在不是固定出口: 没什么要保护的');
  c = setup({ impactErr: Object.assign(new Error('x'), { kind: 'http' }) }); same(await c.X.askRemove(S1, ''), {}, '读不到明细: 照常继续, 由后端的保护兜底');
  // 5a. 非默认出口: 去向 = 其它固定出口 + 跟随默认 + 自动选; 默认选第一个具体的出口
  c = setup({ impact: impactRemove() });
  p = c.X.askRemove(S1, ''); await tick(); m = c.log.modals[0];
  let dsel = byTag(m.content, 'select')[0];
  same(dsel.children.map(o => o.value), ['Pin-A', 'Pin-C', 'DEFAULT', 'PINAUTO', ''], '去向: 其它固定出口 / 跟随默认 / 自动选 / (不改派)');
  assert.strictEqual(dsel.value, 'Pin-A', '默认选中第一个具体的出口, 不是「不改派」');
  for (const name of ['Cursor', 'b.io', 'N:claude']) assert.ok(m.content.text.indexOf(name) >= 0, '列出受影响的: ' + name);
  const checks = byTag(m.content, 'input').filter(i => i.attrs.type === 'checkbox');
  assert.strictEqual(checks.length, 2); assert.ok(m.o.actions.find(a => a.id === 'go').kind === 'danger');
  await press(m, 'go'); same(await p, { reassign: 'Pin-A' });
  p = c.X.askRemove(S1, 'auto'); await tick(); m = c.log.modals[1]; dsel = byTag(m.content, 'select')[0];
  dsel.value = 'DEFAULT'; dsel.dispatch('change'); await press(m, 'go'); same(await p, { reassign: 'DEFAULT' }, '改角色同样走去向选择');
  assert.ok(m.content.text.indexOf('exits.rm.msgRole{"tag":"Pin-B","role":"role:auto","n":3}') >= 0, '改角色的提示写明新角色');
  // 5b. 选「不改派」必须勾选「我知道」
  p = c.X.askRemove(S1, ''); await tick(); m = c.log.modals[2]; dsel = byTag(m.content, 'select')[0];
  dsel.value = ''; dsel.dispatch('change');
  await press(m, 'go'); assert.ok(!m.isClosed, '没勾选: 对话框不关闭'); assert.strictEqual(c.log.toasts.slice(-1)[0][0], 'exits.rm.needAck');
  const ack = byTag(m.content, 'input').filter(i => i.attrs.type === 'checkbox')[1]; ack.checked = true; ack.dispatch('change');
  await press(m, 'go'); same(await p, { accept_orphans: 1 }, '勾选之后: 明确接受后果');
  // 5c. 删除的是默认出口: 没有「跟随默认」/「自动选」可选 (默认没法跟随自己); 有 freeze 选项
  c = setup({ impact: impactRemove({ default_changes: true, follow: { apps: ['ChatGPT'], sites: [], services: ['svc-chatgpt'], dns: false }, affected: 5 }) });
  p = c.X.askRemove(S1, ''); await tick(); m = c.log.modals[0]; dsel = byTag(m.content, 'select')[0];
  same(dsel.children.map(o => o.value), ['Pin-A', 'Pin-C', ''], '默认出口被移除: 只能改派到具体的另一个出口');
  assert.ok(m.content.text.indexOf('ChatGPT') >= 0 && m.content.text.indexOf('exits.rm.follow') >= 0, '跟随它作默认的也列出来');
  assert.ok(m.content.text.indexOf('exits.rm.defNote') >= 0, '说明新的出口会同时成为默认出口');
  const fz = byTag(m.content, 'input').filter(i => i.attrs.type === 'checkbox')[0]; fz.checked = true; fz.dispatch('change');
  await press(m, 'go'); same(await p, { reassign: 'Pin-A', freeze: 1 }, '勾选「同时钉住跟随默认的」');
  // 5c'. 默认出口被移除但没有谁跟随它: 没有「钉住跟随默认的」可勾选
  c = setup({ impact: impactRemove({ default_changes: true, follow: { apps: [], sites: [], services: [], dns: false } }) });
  p = c.X.askRemove(S1, ''); await tick(); m = c.log.modals[0];
  const rows0 = find(m.content, e => e.tag === 'label' && e.className.indexOf('chk-inline') >= 0);
  assert.strictEqual(rows0[0].hidden, true, '没有跟随默认的项目: 不显示 freeze 选项'); await press(m, 'go'); same(await p, { reassign: 'Pin-A' });
  // 5d. 唯一的固定出口: 没有去向可选, 只能明确接受
  c = setup({ impact: impactRemove({ default_changes: true, remaining: 0, candidates: [], follow: { apps: ['ChatGPT'], sites: [], services: [], dns: false }, affected: 4 }) });
  p = c.X.askRemove(S1, ''); await tick(); m = c.log.modals[0];
  assert.strictEqual(byTag(m.content, 'select').length, 0, '没有去向下拉'); assert.ok(m.content.text.indexOf('exits.rm.sole') >= 0, '写明: 没有出口可走, 会用真实 IP 直连');
  await press(m, 'go'); assert.ok(!m.isClosed);
  const ack2 = byTag(m.content, 'input').filter(i => i.attrs.type === 'checkbox')[1]; ack2.checked = true; ack2.dispatch('change');
  await press(m, 'go'); same(await p, { accept_orphans: 1 });
  // 5e. 取消
  c = setup({ impact: impactRemove() }); p = c.X.askRemove(S1, ''); await tick(); await press(c.log.modals[0], 'cancel'); assert.strictEqual(await p, null);
  // 5f. 超出上限的出口不能当去向
  c = setup({ impact: impactRemove({ candidates: [{ tag: 'Pin-A', targetable: true }, { tag: 'Far-1', targetable: false }] }) });
  p = c.X.askRemove(S1, ''); await tick(); dsel = byTag(c.log.modals[0].content, 'select')[0];
  assert.ok(dsel.children.every(o => o.value !== 'Far-1')); await press(c.log.modals[0], 'cancel'); await p;
  // 5g. 只剩 1 个别的出口: 没有「自动选」
  c = setup({ impact: impactRemove({ remaining: 1, candidates: [{ tag: 'Pin-A', targetable: true }] }) });
  p = c.X.askRemove(S1, ''); await tick(); dsel = byTag(c.log.modals[0].content, 'select')[0];
  same(dsel.children.map(o => o.value), ['Pin-A', 'DEFAULT', ''], '剩 1 个: 没有自动选'); await press(c.log.modals[0], 'cancel'); await p;

  /* ===== 6. 订阅里的固定出口 ===== */
  c = setup({ servers: [{ tag: 'Own', role: 'pin' }, { tag: 'S1', role: 'pin', sub: 'SubA' }, { tag: 'S2', role: 'auto', sub: 'SubA' }, { tag: 'S3', role: 'pin', sub: 'SubB' }],
    exits: { ok: true, default: { tag: 'S1' }, max: 32, pins: [{ tag: 'Own', targetable: true, apps: [], sites: ['x.io'], services: [] }, { tag: 'S1', targetable: true, default: true, apps: ['A'], sites: [], services: [] }, { tag: 'S3', targetable: true, apps: [], sites: [], services: [] }],
      follow: { apps: ['B'], sites: ['y.io'], services: [], dns: false }, auto: {}, orphans: [], services_known: true } });
  assert.strictEqual(await c.X.subImpact('SubZ'), null, '没有固定出口的订阅: 不需要提示');
  r = await c.X.subImpact('SubA'); same(r, { pins: ['S1'], n: 3, known: true, defHit: true }, 'SubA 里的 S1: 指定了它的 1 个 + 它是默认出口, 跟随默认的 2 个');
  r = await c.X.subImpact('SubB'); same(r, { pins: ['S3'], n: 0, known: true, defHit: false });

  /* ===== 7. 改派对话框 → POST /api/exits/move ===== */
  c = setup(); c.S.exits = D; const M = c.X.model(D);
  same(c.X.moveDests(M, 'Pin-A').map(d => d.value), ['Pin-B', 'DEFAULT', 'PINAUTO'], 'Pin-A 的去向: 其它可单独指定的出口 / 跟随默认 / 自动选 (Pin-Z 超出上限, 不能当去向)');
  same(c.X.moveDests(M, 'DEFAULT').map(d => d.value), ['Pin-A', 'Pin-B', 'PINAUTO'], '跟随默认的去向: 不含「跟随默认」自己');
  same(c.X.moveDests(c.X.model({ pins: [{ tag: 'Only', targetable: true }], default: { tag: 'Only' } }), 'DEFAULT').map(d => d.value), [], '只有一个固定出口: 没有去向');
  assert.strictEqual(c.X.moveKindOf('svc'), 'service'); assert.strictEqual(c.X.moveKindOf('app'), 'app'); assert.strictEqual(c.X.moveKindOf(''), '');
  p = c.X.askMove(M, M.pins[0]); await tick(); m = c.log.modals[0];
  const ds = byTag(m.content, 'select'); assert.strictEqual(ds.length, 2, '去向 + 范围 (有应用也有网站时才出现)');
  ds[0].value = 'Pin-B'; ds[0].dispatch('change'); await press(m, 'go'); assert.strictEqual(await p, true);
  same(c.log.helper.filter(x => x[0] === 'POST')[0], ['POST', '/api/exits/move', { from: 'Pin-A', to: 'Pin-B' }], '全部范围: 不带 kind');
  assert.ok(c.log.toasts.some(t => t[0].indexOf('exits.moved{"apps":1,"sites":2,"svc":3}') === 0), '提示改了几个'); assert.ok(c.log.applied >= 1, '完成后刷新状态 / 应用列表');
  p = c.X.askMove(M, M.follow); await tick(); m = c.log.modals[1]; const ds2 = byTag(m.content, 'select');
  ds2[0].value = 'Pin-A'; ds2[0].dispatch('change'); ds2[1].value = 'svc'; ds2[1].dispatch('change'); await press(m, 'go'); await p;
  same(c.log.helper.filter(x => x[0] === 'POST')[1], ['POST', '/api/exits/move', { from: 'DEFAULT', to: 'Pin-A', kind: 'service' }], '范围选「只改服务」: kind=service');
  p = c.X.askMove(M, { id: 'orphan', type: 'orphan', items: M.orphans }); await tick(); m = c.log.modals[2]; await press(m, 'go'); await p;
  assert.strictEqual(c.log.helper.filter(x => x[0] === 'POST')[2][2].from, 'ORPHAN', '孤儿: from=ORPHAN');
  p = c.X.askMove(M, M.pins[0]); await tick(); await press(c.log.modals[3], 'cancel'); assert.strictEqual(await p, false); assert.strictEqual(c.log.helper.filter(x => x[0] === 'POST').length, 3, '取消: 不请求');
  c = setup({ moveResp: { ok: true, job: 'exits-move-9' } }); c.S.exits = D;
  p = c.X.askMove(c.X.model(D), c.X.model(D).pins[0]); await tick(); await press(c.log.modals[0], 'go'); await p;
  assert.strictEqual(c.log.dock.length, 1, 'TUN: 后台任务显示在 dock 里');
  c = setup({ servers: [{ tag: 'Only', role: 'pin' }], pinNow: 'Only' });
  r = await c.X.askMove(c.X.model({ pins: [{ tag: 'Only', targetable: true, apps: ['A'] }], default: { tag: 'Only' }, follow: { apps: ['B'] } }), { type: 'follow', lists: { app: ['B'], site: [], svc: [] }, n: 1 });
  assert.strictEqual(r, false); assert.strictEqual(c.log.modals.length, 0); assert.strictEqual(c.log.toasts.slice(-1)[0][0], 'exits.move.noDest', '只有一个固定出口: 说明为什么不能改派');
  // 钉住 (freeze)
  c = setup(); await c.X.freeze('t'); same(c.log.helper.filter(x => x[0] === 'POST')[0], ['POST', '/api/exits/freeze', {}]);
  await c.X.freeze('t', 'app'); same(c.log.helper.filter(x => x[0] === 'POST')[1], ['POST', '/api/exits/freeze', { kind: 'app' }]);

  /* ===== 8. 总览卡片 ===== */
  c = setup(); c.S.exits = D;
  const card = c.X.card();
  const groups = find(card, e => e.attrs && e.attrs['data-g']);
  same(groups.map(g => g.attrs['data-g']), ['pin:Pin-A', 'pin:Pin-B', 'pin:Pin-Z', 'follow', 'auto', 'orphan'], '每个固定出口一组, 然后是 跟随默认 / 自动选 / 孤儿');
  const gA = groups[0], gB = groups[1], gF = groups[3], gO = groups[5];
  assert.ok(gA.text.indexOf('Cursor') >= 0 && gA.text.indexOf('a.io') >= 0 && gA.text.indexOf('b.io') >= 0, '出口上的应用 / 网站');
  assert.ok(gB.text.indexOf('N:claude') >= 0, '服务显示名字 (TP.svcName)'); assert.ok(find(gB, e => e.kind === 'pin').length === 1, '默认出口有「默认」徽标');
  assert.ok(find(groups[2], e => e.kind === 'warn').length === 1 && groups[2].text.indexOf('exits.pin.none') >= 0, '超出上限的出口: 徽标说明不能单独指定; 没有项目时有说明');
  assert.ok(gF.text.indexOf('exits.group.followTo{"tag":"Pin-B"}') >= 0 && gF.text.indexOf('ChatGPT') >= 0 && gF.text.indexOf('N:chatgpt') >= 0 && gF.text.indexOf('exits.dns') >= 0, '跟随默认: 标明现在的默认出口, 含 DNS');
  assert.ok(byTag(gF, 'button').some(b => b.label === 'exits.act.freezeAt{"tag":"Pin-B"}'), '跟随默认有「钉在当前默认出口上」');
  assert.ok(byTag(gA, 'button').every(b => b.label !== 'exits.act.freezeAt{"tag":"Pin-B"}') && byTag(gA, 'button').some(b => b.label === 'exits.act.move'), '指定了它的有「全部改派…」');
  assert.ok(gO.text.indexOf('gone.io') >= 0 && gO.text.indexOf('exits.orphan.was{"tag":"Old-1","why":"exits.why.deleted"}') >= 0 && gO.text.indexOf('exits.orphan.was{"tag":"Auto-1","why":"exits.why.role"}') >= 0, '孤儿按原来指定的出口分组, 写明原因');
  const banner = find(card, e => e.className.indexOf('exits-banner') >= 0)[0]; assert.strictEqual(banner.hidden, false); assert.ok(banner.textContent.indexOf('exits.orphan.banner{"n":2') === 0, '孤儿横幅');
  // 展开 / 收起
  const many2 = { pins: [{ tag: 'Pin-A', targetable: true, default: true, apps: Array.from({ length: 12 }, (_, i) => 'App' + i), sites: [], services: [] }], default: { tag: 'Pin-A' }, follow: {}, auto: {}, orphans: [] };
  c = setup(); c.S.exits = many2; const card2 = c.X.card();
  assert.ok(find(card2, e => /(^| )exg-c( |$)/.test(e.className) && e.text.indexOf('App') === 0).length === 8, '超过 8 个先显示 8 个');
  const more = find(card2, e => e.className.indexOf('exg-more') >= 0)[0]; assert.ok(more.text.indexOf('exits.more{"n":4}') === 0); more.dispatch('click');
  assert.ok(find(card2, e => /(^| )exg-c( |$)/.test(e.className) && e.text.indexOf('App') === 0).length === 12, '展开后全部显示'); assert.ok(find(card2, e => e.className.indexOf('exg-more') >= 0)[0].text.indexOf('exits.less') === 0);
  // 没有数据 / 没有固定出口
  c = setup(); const card3 = c.X.card(); assert.strictEqual(find(card3, e => e.className.indexOf('exits-empty') >= 0)[0].hidden, false, '没读到数据时有占位说明');
  c.S.exits = { ok: true, default: { tag: '' }, pins: [], follow: { apps: ['ChatGPT'] }, auto: {}, orphans: [] }; c.TP.emit('exits');
  const gs = find(card3, e => e.attrs && e.attrs['data-g']); same(gs.map(g => g.attrs['data-g']), ['follow']);
  assert.ok(find(gs[0], e => e.kind === 'bad').length === 1, '没有固定出口但有项目选了固定出口: 红色徽标「正在直连」');

  /* ===== 9. 加载: 共用一次请求; 失败不抛 ===== */
  c = setup({ exits: { ok: true, default: { tag: 'Pin-A' }, pins: [], follow: {}, auto: {}, orphans: [] } });
  const [r1, r2] = await Promise.all([c.X.load(), c.X.load()]);
  assert.strictEqual(c.log.helper.filter(x => x[1] === '/api/exits').length, 1, '并发的读取合并成一次请求'); assert.strictEqual(r1, r2); assert.strictEqual(c.S.exits, r1); assert.ok(c.log.emits.indexOf('exits') >= 0);
  await c.X.load(60000); assert.strictEqual(c.log.helper.filter(x => x[1] === '/api/exits').length, 1, 'maxAge 之内不重复请求');
  c = setup(); c.TP.helper = async () => { throw Object.assign(new Error('boom'), { kind: 'http' }); };
  assert.strictEqual(await c.X.load(), null, '读取失败返回 null 而不是抛出'); assert.strictEqual(c.S.exits, null);

  console.log('PASS: exits UI — model, pickers, default-switch pre-flight (freeze/follow/cancel/legacy), remove pre-flight (reassign/accept/sole/freeze), move dialog, overview card');
})().catch(e => { console.error(e); process.exitCode = 1; });
