#!/usr/bin/env node
// 日志页的分页 (2.3.27): 「网站访问」很大的一天后端只读最近的一段, 响应带 partial:true —— 真实的 ui/core.js, ui/data.js, ui/ui.js, ui/v-logs.js,
// 假的浏览器 (tests/ui-dom.js), 辅助服务用替身 (只记录请求), 不需要浏览器、不碰网络。
// 1. partial: 摘要写「最近的 N 条」(logs.countPartial), 筛选按钮上的数字带「+」(logs.f.atLeast), 不显示「另有 N 条新记录」;
//    翻页不再用总数推算新增 (offset 就是 (页码 - 1) × 每页条数), 基准跟着最新的总数, 分页条随之变长。
// 2. 已读部分的最后一页才有「加载更早的记录」: 最后一页不满 -> 重读这一页 (后端接着往前读); 最后一页正好满 -> 读下一页, 分页条按新的总数翻过去;
//    后端读完了整天、没有更早的了 -> 回到最后一页重读, 按钮消失。
// 3. 读完整天 (没有 partial) 之后恢复以前的行为: 翻页期间新增的条数加到 offset 上 (响应显示又新增了就重读一次), 并提示「另有 N 条新记录」。
// 4. 「发送完整诊断」/「删除已上传的诊断」遇到 E_LOGIN_REQUIRED: 有 TP.auth.openLogin 就打开登录框, 任务卡片和提示里不出现失败; 没有它就照旧提示错误。
'use strict';
const assert = require('assert');
const { makeBrowser, fakeI18n, settle } = require('./ui-dom.js');

const b = makeBrowser();
b.win.I18N = fakeI18n();
b.win.I18N.intl.list = a => a.join(', ');
['ui/core.js', 'ui/data.js', 'ui/ui.js'].forEach(f => b.load(f));
const TP = b.win.TP, S = TP.S, h = TP.h;
const prefs = new Map([['logs.tab', 'access']]);
TP.prefs = { get: (k, d) => (prefs.has(k) ? prefs.get(k) : d), set: (k, v) => { if (v === undefined) prefs.delete(k); else prefs.set(k, v); } };
TP.go = id => { TP.tab = id; }; TP.loadSettings = () => Promise.resolve(null); TP.tunDetail = x => x;
const toasts = []; TP.ui.toast = (m, k) => { toasts.push([m, k]); };
const reqs = []; let reply = null;
TP.helper = (method, url, o) => { reqs.push({ method, url, q: (o && o.q) || null }); return reply(method, url, o || {}); };
b.load('ui/v-logs.js');
const dock = h('div', { id: 'dock' }); b.doc.body.appendChild(dock);

S.locked = false; S.helperUp = true;
const pad = n => (n < 10 ? '0' : '') + n, now = new Date();
const today = now.getFullYear() + '-' + pad(now.getMonth() + 1) + '-' + pad(now.getDate());
const rowsFrom = (from, n) => Array.from({ length: n }, (_, i) => ({ ts: today + ' 10:00:00', id: String(from + i), net: 'tcp', host: 'h' + (from + i) + '.example', port: 443, app: 'App', route: 'direct', node: 'direct', reason: 'policy', err: '' }));
const resp = (total, rows, partial) => Object.assign({ ok: true, days: [today], total, rows, summary: { all: total, direct: total, proxy: 0, pin: 0, auto: 0, error: 0, reasons: { policy: total }, top_fail: [] } }, partial ? { partial: true } : {});
let answer = null;                                                  // (q) -> 响应; 每个请求都记下 offset
reply = (method, url, o) => (url === '/api/logs' ? Promise.resolve(answer(o.q)) : Promise.resolve({ ok: true }));
const logReqs = () => reqs.filter(r => r.url === '/api/logs');
const lastOff = () => logReqs().slice(-1)[0].q.offset;

const root = h('section', { id: 'v-logs' }); b.doc.body.appendChild(root);
TP.tab = 'logs';
TP.V.logs.init(root);
const sumTxt = () => root.querySelector('.log-sum').children[0].textContent;
const newerBtn = () => root.querySelector('.log-sum').children[1];
const olderRow = () => root.querySelectorAll('.log-sum')[1];
const olderBtn = () => olderRow().querySelector('button');
const pagerNav = () => root.querySelectorAll('.log-pgw').filter(w => !w.hidden)[0].querySelector('nav.pager');
const pageBtn = label => pagerNav().querySelectorAll('button').filter(x => x.getAttribute('aria-label') === label)[0];
const curPage = () => { const c = pagerNav().querySelectorAll('button').filter(x => x.getAttribute('aria-current') === 'page')[0]; return c ? +c.textContent : 0; };
const hosts = () => root.querySelector('.log-list').children.map(li => li.querySelector('.log-hn').textContent);
const allLabel = () => root.querySelectorAll('.seg').filter(s => !s.hidden)[0].querySelector('.sl').textContent;
async function click(btn) { assert(btn, 'button exists'); btn.click(); await settle(12); }

(async () => {
  /* ---- 1. 第一次读取: partial ---- */
  answer = q => (q.offset === 0 ? resp(120, rowsFrom(0, 50), true) : assert.fail('unexpected offset ' + q.offset));
  TP.V.logs.show(); await settle(12);
  assert.deepEqual(logReqs()[0].q, { type: 'access', day: '', q: '', f: '', limit: 50, offset: 0 }, 'first request: newest page of today');
  assert.equal(sumTxt(), 'logs.countPartial {"n":120,"num":"120"}', 'partial: "most recent N", not a day total');
  assert.equal(allLabel(), 'logs.f.all logs.f.atLeast {"num":"120"}', 'filter numbers are lower bounds');
  assert(newerBtn().hidden, 'no "newer" hint while partial');
  assert(olderRow().hidden, '"load older" only on the last page of what was read');
  assert.equal(hosts()[0], 'h0.example:443');
  assert.equal(curPage(), 1);

  /* ---- 翻页: offset 不加「新增」(总数变了也不加), 基准跟着最新的总数 ---- */
  answer = q => resp(q.offset === 100 ? 180 : assert.fail('offset ' + q.offset), rowsFrom(100, 50), true);
  await click(pageBtn('pager.page {"n":3}'));
  assert.equal(lastOff(), 100, 'page 3 = offset 100, no "newer" correction from partial totals');
  assert.equal(logReqs().length, 2, 'no retry for a changed partial total');
  assert.equal(sumTxt(), 'logs.countPartial {"n":180,"num":"180"}');
  assert(newerBtn().hidden, 'a bigger partial total is not "newer entries"');
  assert.equal(curPage(), 3); assert(olderRow().hidden, 'page 3 of 4: not the last page yet');

  /* ---- 2. 最后一页 (不满): 「加载更早的记录」重读这一页 ---- */
  answer = q => resp(180, rowsFrom(150, 30), true);
  await click(pageBtn('pager.last'));
  assert.equal(lastOff(), 150); assert.equal(curPage(), 4);
  assert(!olderRow().hidden, '"load older" on the last page of what was read');
  answer = q => (q.offset === 150 ? resp(400, rowsFrom(150, 50), true) : assert.fail('offset ' + q.offset));
  await click(olderBtn());
  assert.equal(lastOff(), 150, 'the unfinished last page is read again (the backend reads further back to fill it)');
  assert.equal(curPage(), 4); assert.equal(hosts().length, 50);
  assert.equal(sumTxt(), 'logs.countPartial {"n":400,"num":"400"}');
  assert(olderRow().hidden, 'page 4 of 8 now');

  /* ---- 最后一页正好满: 读下一页, 分页条按新的总数翻过去 ---- */
  answer = q => resp(400, rowsFrom(350, 50), true);
  await click(pageBtn('pager.last'));
  assert.equal(lastOff(), 350); assert.equal(curPage(), 8); assert(!olderRow().hidden);
  answer = q => (q.offset === 400 ? resp(900, rowsFrom(400, 50), true) : assert.fail('offset ' + q.offset));
  await click(olderBtn());
  assert.equal(lastOff(), 400, 'next page after what was read');
  assert.equal(curPage(), 9, 'the pager moved to the new page');
  assert.equal(hosts()[0], 'h400.example:443');
  assert(olderRow().hidden);

  /* ---- 没有更早的了 (后端读完了整天): 回到最后一页重读, 按钮消失 ---- */
  answer = q => resp(900, rowsFrom(850, 50), true);
  await click(pageBtn('pager.last'));
  assert.equal(curPage(), 18); assert(!olderRow().hidden);
  const before = logReqs().length;
  answer = q => (q.offset === 900 ? resp(900, [], false) : q.offset === 850 ? resp(900, rowsFrom(850, 50), false) : assert.fail('offset ' + q.offset));
  await click(olderBtn());
  assert.deepEqual(logReqs().slice(before).map(r => r.q.offset), [900, 850], 'nothing older: the last page is read again');
  assert.equal(curPage(), 18);
  assert.equal(sumTxt(), 'logs.count {"n":900,"num":"900"}', 'whole day read: the exact total again');
  assert.equal(allLabel(), 'logs.f.all 900', 'no "+" once the whole day was read');
  assert(olderRow().hidden, 'no "load older" without partial');

  /* ---- 3. 读完整天之后: 翻页期间新增的条数照旧加到 offset 上 ---- */
  const b2 = logReqs().length;
  answer = q => resp(903, rowsFrom(q.offset, 50), false);
  await click(pageBtn('pager.page {"n":17}'));
  assert.deepEqual(logReqs().slice(b2).map(r => r.q.offset), [800, 803], 'full totals: new entries shift the page (one retry with the new count)');
  assert(!newerBtn().hidden, '"newer" hint is back');
  assert.equal(newerBtn().textContent, 'logs.newer {"n":3,"num":"3"}');

  /* ---- 4. 诊断: 需要登录 ---- */
  S.prefs = { settings: { log_hours: 72, log_hours_min: 12, log_hours_max: 720, log_ops: true, access_log: true, log_core: true, diag_upload: false }, usage: null };
  TP.ui.confirmDialog = () => Promise.resolve(true);
  const logins = [];
  TP.auth = { openLogin: o => { logins.push(o); } };
  const needLogin = () => Promise.reject(TP.mkErr('api', 'login needed', { ok: false, code: 'E_LOGIN_REQUIRED', error: 'login needed' }));
  reply = (method, url) => (url === '/api/diag/send' || url === '/api/diag/delete' ? needLogin() : Promise.resolve({ ok: true }));
  TP.logs.openSettings(); await settle();
  const dlg = b.doc.body.children.filter(x => x.tagName === 'dialog' && x.open).slice(-1)[0];
  assert(dlg, 'log settings dialog is open');
  const btnByText = t => dlg.querySelectorAll('button').filter(x => x.textContent === t)[0];
  toasts.length = 0;
  await click(btnByText('logs.diag.send'));
  assert.equal(logins.length, 1, 'send: the login dialog opens');
  assert.equal(logins[0].mode, 'login'); assert.equal(logins[0].reason, 'logs.diag.loginWhy');
  assert.deepEqual(toasts.filter(x => x[1] === 'err'), [], 'send: no failure toast');
  assert.equal(dock.children.length, 0, 'send: the task card is closed quietly');
  await click(btnByText('logs.diag.del'));
  assert.equal(logins.length, 2, 'delete: the login dialog opens');
  assert.deepEqual(toasts.filter(x => x[1] === 'err'), [], 'delete: no failure toast');
  TP.auth = {};                                                         // 没有登录框 (旧界面): 照旧提示错误
  await click(btnByText('logs.diag.del'));
  assert.equal(logins.length, 2);
  assert.deepEqual(toasts.filter(x => x[1] === 'err').map(x => x[0]), ['login needed'], 'without TP.auth.openLogin the error is shown as before');

  console.log('logs-ui: ok');
})().catch(e => { console.error(e); process.exit(1); });
