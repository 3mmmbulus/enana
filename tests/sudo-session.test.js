#!/usr/bin/env node
// 敏感操作的再次验证令牌 (step-up / sudo, ui/auth.js) 刷新页面后还在: 真实的 ui/core.js + ui/ui.js + ui/auth.js, 假的浏览器 (tests/ui-dom.js), 假的辅助服务 (fetch 替身)。
// 1. 第一次: 403 E_SUDO_REQUIRED -> 密码框 -> POST /api/auth/verify -> 带着 X-Enana-Sudo 重试; {token, exp} 记进 sessionStorage, 绝不进 localStorage。
// 2. 刷新 (同一个标签页的 sessionStorage, 新的页面): 到期之前直接带上令牌, 不再弹密码框; 不需要验证的接口照样不带。
// 3. 过期 / 没有登录令牌 / 格式不对 (换行、到期时间远得离谱、不是对象、不是 JSON) 的: 不恢复, 并从 sessionStorage 删掉; 在内存里过期了也一样删掉。
// 4. 403 E_SUDO_REQUIRED (例如辅助服务重启过)、锁定 / 退出 (A.lock)、登录失效 (401 -> A.expire) 时连同 sessionStorage 一起丢弃。
// 5. 存储不可用 (隐私模式, 读写都抛异常): 照常验证, 令牌只在内存里, 刷新后要重新输入; 不抛异常。
'use strict';
const assert = require('assert');
const { makeBrowser, storage, fakeI18n, settle } = require('./ui-dom.js');

const SUDO = '0123456789abcdef0123456789abcdef', LOGIN = '"login-token-1"', KEY = 'enana.sudo';
const clock = { now: 1760000000000 };
class FakeDate extends Date { static now() { return clock.now; } }

/* 一次「打开页面」: 同一个标签页的 sessionStorage 跨刷新保留 (测试把同一个对象传进来) */
function boot(ss, ls, rules) {
  const calls = [];
  const fetch = (url, opt) => {
    const u = new URL(url, 'http://127.0.0.1'), hd = opt.headers || {};
    const c = { method: opt.method, path: u.pathname, sudo: hd['X-Enana-Sudo'] || '', token: hd['X-Enana-Token'] || '', body: opt.body || '' };
    calls.push(c);
    const r = (rules && rules(c)) || { status: 200, body: { ok: true } };
    return Promise.resolve({ status: r.status, ok: r.status >= 200 && r.status < 300, headers: {}, text: () => Promise.resolve(JSON.stringify(r.body)) });
  };
  const b = makeBrowser({ sessionStorage: ss, localStorage: ls, Date: FakeDate, fetch });
  b.win.I18N = fakeI18n();
  ['ui/core.js', 'ui/ui.js', 'ui/auth.js'].forEach(f => b.load(f));
  b.calls = calls; b.TP = b.win.TP;
  b.dialogs = () => b.doc.body.children.filter(x => x.tagName === 'dialog' && x.open);
  return b;
}
/* 假的辅助服务: 白名单里的接口要带对的 X-Enana-Sudo; verify 收到密码 pw-1 时发令牌 */
function helperRules(o) {
  o = o || {};
  return c => {
    if (c.path === '/api/auth/verify') return c.body === 'password=pw-1' ? { status: 200, body: { ok: true, sudo: SUDO, ttl: 300 } } : { status: 200, body: { ok: false, code: 'E_BAD_CREDENTIALS', error: 'bad' } };
    if (c.path === '/api/auth/status') return { status: 200, body: { ok: true, required: true } };
    if (o.unauth && c.path === o.unauth) return { status: 401, body: { ok: false, code: 'E_AUTH', error: 'expired' } };
    if (['/api/servers/delete', '/api/export', '/api/logs/clear'].indexOf(c.path) >= 0 && (o.rejectAll || c.sudo !== SUDO)) return { status: 403, body: { ok: false, code: 'E_SUDO_REQUIRED', error: 'step-up needed' } };
    return { status: 200, body: { ok: true } };
  };
}
const stored = ss => (Object.prototype.hasOwnProperty.call(ss, KEY) ? JSON.parse(ss[KEY]) : undefined);
function noLocal(ls) {
  Object.keys(ls).forEach(k => { assert(!/sudo/i.test(k), 'localStorage key ' + k); assert(ls[k].indexOf(SUDO) < 0, 'the token never reaches localStorage (' + k + ')'); });
}
async function enterPassword(b, pw) {
  const dlg = b.dialogs().slice(-1)[0];
  assert(dlg, 'the password dialog is open');
  const inp = dlg.querySelector('input[type=password]');
  assert(inp, 'password field');
  inp.value = pw;
  dlg.querySelector('[data-id="go"]').click();
  await settle(12);
  return { dlg, inp };
}

(async () => {
  const ss = storage(), ls = storage();
  ss['enana.token'] = LOGIN;

  // 1. 第一次需要验证: 弹密码框, 验证, 重试; 记进 sessionStorage
  let b = boot(ss, ls, helperRules());
  assert.equal(b.TP.sudo.valid(), false, 'a fresh tab has no step-up token');
  let p = b.TP.helper('POST', '/api/servers/delete', { form: { tag: 'n1' } });
  await settle();
  assert.equal(b.dialogs().length, 1, '403 E_SUDO_REQUIRED opens the password dialog');
  const { dlg, inp } = await enterPassword(b, 'pw-1');
  assert.deepEqual(await p, { ok: true });
  assert.deepEqual(b.calls.map(c => [c.method + ' ' + c.path, c.sudo]), [['POST /api/servers/delete', ''], ['POST /api/auth/verify', ''], ['POST /api/servers/delete', SUDO]]);
  assert(!dlg.open && !dlg.parentNode, 'the dialog closed'); assert.equal(inp.value, '', 'the typed password is wiped');
  assert.deepEqual(stored(ss), { token: SUDO, exp: clock.now + 295000 }, '{token, exp} in sessionStorage (ttl 300 s minus 5 s)');
  noLocal(ls);

  // 2. 刷新页面 (同一个标签页): 2 分钟后令牌还能用, 直接带上, 不弹框
  clock.now += 120000;
  b = boot(ss, ls, helperRules());
  assert.equal(b.TP.sudo.valid(), true, 'restored after a reload');
  assert.equal(b.TP.sudo.token(), SUDO);
  assert.deepEqual(await b.TP.helper('POST', '/api/servers/delete', { form: { tag: 'n2' } }), { ok: true });
  await b.TP.helper('GET', '/api/state');
  assert.deepEqual(b.calls.map(c => [c.path, c.sudo]), [['/api/servers/delete', SUDO], ['/api/state', '']], 'sudo paths carry it at once; other requests never do');
  assert.equal(b.dialogs().length, 0, 'no password dialog after the reload');
  noLocal(ls);

  // 3a. 在内存里过期: token() 返回空并删掉 sessionStorage 里的
  clock.now += 200000;
  assert.equal(b.TP.sudo.valid(), false); assert.equal(b.TP.sudo.token(), '');
  assert.equal(stored(ss), undefined, 'an expired token is removed from sessionStorage');
  // 3b. 刷新时已经过期: 不恢复, 删掉
  ss[KEY] = JSON.stringify({ token: SUDO, exp: clock.now - 1 });
  b = boot(ss, ls, helperRules());
  assert.equal(b.TP.sudo.valid(), false); assert.equal(stored(ss), undefined, 'expired at load: removed');
  // 3c. 没有登录令牌 (已经退出登录的标签页): 不恢复, 删掉
  const ss2 = storage(); ss2[KEY] = JSON.stringify({ token: SUDO, exp: clock.now + 60000 });
  b = boot(ss2, ls, helperRules());
  assert.equal(b.TP.sudo.valid(), false); assert.equal(stored(ss2), undefined, 'no login token: removed');
  // 3d. 格式不对的一律不用
  for (const bad of [JSON.stringify({ token: 'abc\r\nX-Evil: 1', exp: clock.now + 60000 }), JSON.stringify({ token: SUDO, exp: clock.now + 2 * 3600000 }),
    JSON.stringify({ token: 12345, exp: clock.now + 60000 }), JSON.stringify({ token: '', exp: clock.now + 60000 }), JSON.stringify({ token: SUDO }),
    JSON.stringify(SUDO), JSON.stringify([SUDO, clock.now + 60000]), 'not json {']) {
    ss[KEY] = bad;
    b = boot(ss, ls, helperRules());
    assert.equal(b.TP.sudo.valid(), false, 'not restored: ' + bad); assert.equal(stored(ss), undefined, 'removed: ' + bad);
  }

  // 4a. 恢复出来的令牌被辅助服务拒绝 (403 E_SUDO_REQUIRED): 内存和 sessionStorage 都清掉, 重新问密码; 取消 = kind cancel
  ss[KEY] = JSON.stringify({ token: SUDO, exp: clock.now + 60000 });
  b = boot(ss, ls, helperRules({ rejectAll: true }));
  assert.equal(b.TP.sudo.valid(), true);
  p = b.TP.helper('POST', '/api/logs/clear', { form: {} });
  await settle();
  assert.equal(stored(ss), undefined, '403 E_SUDO_REQUIRED drops the stored token'); assert.equal(b.TP.sudo.valid(), false);
  assert.equal(b.dialogs().length, 1, 'and asks again');
  b.dialogs()[0].querySelector('.dlg-a').children[0].click();               // 取消
  await assert.rejects(p, e => e.kind === 'cancel');
  assert.equal(b.calls.filter(c => c.path === '/api/logs/clear').length, 1, 'cancel does not retry');
  // 4b. 锁定 / 退出账号都走 A.lock (auth=false)
  ss[KEY] = JSON.stringify({ token: SUDO, exp: clock.now + 60000 });
  b = boot(ss, ls, helperRules());
  assert.equal(b.TP.sudo.valid(), true);
  b.TP.auth.lock('');
  assert.equal(stored(ss), undefined, 'lock / logout drop the stored token'); assert.equal(b.TP.sudo.valid(), false);
  assert(b.doc.body.children.some(x => x.tagName === 'dialog' && x.classList.contains('authpage')), 'the login page is shown');
  // 4c. 登录失效 (任何请求 401 -> A.expire -> A.lock)
  ss['enana.token'] = LOGIN; ss[KEY] = JSON.stringify({ token: SUDO, exp: clock.now + 60000 });
  b = boot(ss, ls, helperRules({ unauth: '/api/state' }));
  assert.equal(b.TP.sudo.valid(), true);
  await assert.rejects(b.TP.helper('GET', '/api/state'), e => e.kind === 'auth');
  await settle();
  assert.equal(stored(ss), undefined, 'losing the session drops the stored token'); assert.equal(b.TP.sudo.valid(), false);
  noLocal(ls);

  // 5. 存储不可用: 验证照常, 令牌只在内存里; 刷新后要重新输入
  const off = storage(true), offLs = storage(true);
  b = boot(off, offLs, helperRules());
  p = b.TP.helper('GET', '/api/export', { text: true });
  await settle();
  await enterPassword(b, 'pw-1');
  await p;
  assert.equal(b.TP.sudo.valid(), true, 'kept in memory when sessionStorage is unavailable');
  assert.equal(b.calls.filter(c => c.path === '/api/export' && c.sudo === SUDO).length, 1);
  b = boot(off, offLs, helperRules());
  assert.equal(b.TP.sudo.valid(), false, 'nothing to restore without storage');

  console.log('PASS: the step-up token survives a reload in sessionStorage only until it expires, and is dropped on 403, lock, logout and session loss');
})().catch(e => { console.error(e); process.exitCode = 1; });
