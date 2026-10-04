#!/usr/bin/env node
// ui.sorter (所有表格的表头排序): 排序规则 / 空值在最后 / 稳定 / 三态点击 / 记住选择 / aria-sort / 语言切换。不需要浏览器。
const fs = require('fs'), vm = require('vm'), assert = require('assert'), path = require('path');
class Element {
  constructor(tag) { this.tagName = String(tag).toUpperCase(); this.children = []; this.attrs = {}; this.events = {}; this.text = ''; this.className = ''; this.disabled = false; this.value = ''; this.checked = false; this.title = ''; this.hidden = false; this.classList = { contains: c => this.className.split(' ').includes(c), add: c => { this.className = (this.className + ' ' + c).trim(); }, remove: c => { this.className = this.className.split(' ').filter(x => x !== c).join(' '); }, toggle: (c, on) => { on ? this.classList.add(c) : this.classList.remove(c); } }; }
  get textContent() { return this.text + this.children.map(x => x.textContent).join(''); }
  set textContent(s) { this.text = String(s); this.children = []; }
  setAttribute(k, v) { this.attrs[k] = String(v); if (k === 'class') this.className = String(v); }
  getAttribute(k) { return this.attrs[k] ?? null; }
  removeAttribute(k) { delete this.attrs[k]; }
  appendChild(c) { if (c.parentNode) c.parentNode.removeChild(c); this.children.push(c); c.parentNode = this; return c; }
  removeChild(c) { this.children.splice(this.children.indexOf(c), 1); c.parentNode = null; }
  addEventListener(e, fn) { (this.events[e] ||= []).push(fn); }
  click() { (this.events.click || []).forEach(fn => fn({ preventDefault() {}, stopPropagation() {} })); }
  querySelector(sel) { const cls = sel.replace(/^\./, ''); const find = x => { for (const c of x.children) { if (c.className.split(' ').includes(cls)) return c; const r = find(c); if (r) return r; } return null; }; return find(this); }
  contains() { return true; }
}
const document = { createTextNode: s => { const x = new Element('#text'); x.textContent = s; return x; }, contains: () => true };
const prefs = {}; const handlers = {};
const dict = { 'sort.aria': 'Sort by {col}', 'sort.asc': 'asc', 'sort.desc': 'desc', 'sort.toAsc': 'to asc', 'sort.toDesc': 'to desc', 'sort.clear': 'clear' };
const I = { lang: 'en', t: (k, v) => String(dict[k] ?? k).replace(/\{(\w+)\}/g, (_, n) => v && v[n] != null ? v[n] : ''), L: k => k, isL: () => false, attr: (e, k, v) => e.setAttribute(k, v) };
const TP = {
  on: (e, fn) => { (handlers[e] ||= []).push(fn); }, ui: {}, S: {},
  h: (tag, a, ...children) => { const x = new Element(tag); for (const k in a || {}) if (a[k] != null) x.setAttribute(k, a[k]); for (const c of children.flat()) if (c != null) x.appendChild(c instanceof Element ? c : document.createTextNode(c)); return x; },
  setText: (e, s) => { e.textContent = s; }, clear: e => { e.textContent = ''; }, byId: () => null, errMsg: e => e.message,
  prefs: { get: (k, d) => (k in prefs ? prefs[k] : d), set: (k, v) => { if (v === undefined) delete prefs[k]; else prefs[k] = v; } }
};
vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../ui/ui.js'), 'utf8'), { window: { TP, I18N: I }, document, Promise, console, setTimeout, clearTimeout, Intl, Object, JSON, Date, Array, String, Math });
const ui = TP.ui;
const names = rows => rows.map(r => r.n).join(',');
const same = (a, b, m) => assert.strictEqual(JSON.stringify(a), JSON.stringify(b), m);      // vm 里创建的对象和这里不是同一个 realm, 不能用 deepStrictEqual
let changes = 0;
const mk = (id, o) => ui.sorter(id, { n: { get: r => r.n }, num: { type: 'num', get: r => r.num }, when: { type: 'date', get: r => r.when } }, Object.assign({ onChange: () => { changes++; } }, o));

// 1. 文本: 不分大小写、数字按大小 (App 2 在 App 10 前面); 稳定; 空值永远在最后
let so = mk('t1');
const rows = [{ n: 'app 10', num: 3 }, { n: 'App 2', num: null }, { n: 'beta', num: 1 }, { n: '', num: 2 }, { n: 'Alpha', num: 1 }];
assert.strictEqual(names(so.apply(rows)), 'app 10,App 2,beta,,Alpha', '没有选排序: 保持原来的顺序');
so.set('n', 'asc'); assert.strictEqual(names(so.apply(rows)), 'Alpha,App 2,app 10,beta,', '升序: 数字按大小, 空值在最后');
so.set('n', 'desc'); assert.strictEqual(names(so.apply(rows)), 'beta,app 10,App 2,Alpha,', '降序时空值仍然在最后');
// 2. 数字: 空值 (null) 在最后; 相同的值保持原来的相对顺序 (稳定)
so.set('num', 'asc'); assert.strictEqual(names(so.apply(rows)), 'beta,Alpha,,app 10,App 2', '数字升序 (beta 和 Alpha 都是 1, 保持原来的先后), null 在最后');
so.set('num', 'desc'); assert.strictEqual(names(so.apply(rows)), 'app 10,,beta,Alpha,App 2', '数字降序: 同值仍稳定');
// 3. 日期: 时间戳和 "YYYY-MM-DD HH:MM:SS" 都可以
so.set('when', 'asc');
const d = [{ n: 'c', when: '2026-10-03 12:00:00' }, { n: 'a', when: 1700000000000 }, { n: 'b', when: '2026-09-01' }, { n: 'z', when: null }];
assert.strictEqual(names(so.apply(d)), 'a,b,c,z', '日期升序 (空值最后)');
assert.strictEqual(so.apply(rows).length, rows.length, '不丢行');
assert.strictEqual(rows[0].n, 'app 10', '不修改原数组');

// 4. 表头: 点击三态 升序 → 降序 → 不排序; 记住选择; aria-sort; onChange
prefs['sort.t2'] = undefined; delete prefs['sort.t2']; changes = 0;
so = mk('t2');
const th = so.th('n', () => 'Name');
assert.strictEqual(th.getAttribute('aria-sort'), 'none'); assert.strictEqual(th.tagName, 'TH');
const btn = th.querySelector('th-sort'); assert(btn, '表头里有按钮');
btn.click(); same(so.state(), { key: 'n', dir: 'asc' }); assert.strictEqual(prefs['sort.t2'], 'n:asc'); assert.strictEqual(th.getAttribute('aria-sort'), 'ascending');
assert(/Sort by Name/.test(btn.getAttribute('aria-label')) && /asc/.test(btn.getAttribute('aria-label')), '读屏标签带列名和当前方向');
btn.click(); same(so.state(), { key: 'n', dir: 'desc' }); assert.strictEqual(th.getAttribute('aria-sort'), 'descending');
btn.click(); assert.strictEqual(so.state(), null); assert.strictEqual(prefs['sort.t2'], 'none'); assert.strictEqual(th.getAttribute('aria-sort'), 'none');
assert.strictEqual(changes, 3, '每次点击都通知一次 (视图据此重画)');
// 5. 换列: 重新从升序开始
const th2 = so.th('num', () => 'Num'); th.querySelector('th-sort').click(); th2.querySelector('th-sort').click();
same(so.state(), { key: 'num', dir: 'asc' });
assert.strictEqual(th.getAttribute('aria-sort'), 'none', '另一列被选中后, 原来那列的箭头清除');

// 6. 下次打开: 从 prefs 恢复; 未知的列 / 坏数据忽略
prefs['sort.t3'] = 'num:desc'; so = mk('t3'); same(so.state(), { key: 'num', dir: 'desc' });
prefs['sort.t4'] = 'nope:asc'; so = mk('t4'); assert.strictEqual(so.state(), null);
prefs['sort.t5'] = 'garbage'; so = mk('t5'); assert.strictEqual(so.state(), null);
// 7. 默认排序: 从没选过 = 默认; 用户点到「不排序」(none) = 真的不排序
delete prefs['sort.t6']; so = mk('t6', { def: { key: 'num', dir: 'desc' } }); same(so.state(), { key: 'num', dir: 'desc' }, '没选过 → 默认排序');
const t6 = so.th('num', () => 'Num'); t6.querySelector('th-sort').click(); assert.strictEqual(so.state(), null, '默认是降序, 再点一次 → 不排序'); assert.strictEqual(prefs['sort.t6'], 'none');
so = mk('t6', { def: { key: 'num', dir: 'desc' } }); assert.strictEqual(so.state(), null, '明确选了不排序: 下次打开仍然不排序');

// 8. 语言切换: 表头文字用当前语言的列名
let label = 'Name'; so = mk('t7'); const th7 = so.th('n', () => label); assert.strictEqual(th7.textContent.replace(/[▲▼↕]/g, ''), 'Name');
label = '名称'; (handlers.lang || []).forEach(fn => fn()); assert.strictEqual(th7.querySelector('th-t').textContent, '名称', '切换语言后表头文字更新');
// 9. 把已有的元素变成可点击表头 (attach)
const span = TP.h('span', null, 'Plain'); so = mk('t8'); so.attach(span, 'n'); so.set('n', 'desc'); assert.strictEqual(span.getAttribute('data-sort'), 'desc');
console.log('PASS: ui.sorter — text/number/date ordering, nulls last, stable, 3-state click, persistence, aria-sort, language, default sort');
