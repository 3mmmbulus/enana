#!/usr/bin/env node
// 2.3.27 不需要账号的仪表盘: 真实的 ui/core.js + ui/data.js + ui/ui.js + ui/auth.js, 假的浏览器 (tests/ui-dom.js), 假的辅助服务 (fetch 替身, 按 docs/API.md 的共同约定)。
// 1. 打开: 没有令牌 -> POST /api/auth/local (不带令牌、不要任何密码) -> 记下本机令牌 -> 仪表盘; 没有整页的登录框; 没有登录 = guest (<html data-acct="guest">)
// 2. 401 -> 悄悄取一次新的本机令牌并重试 (Clash API 也一样); 取到了还是 401 -> 失去连接 (只取一次, 不循环), 稍后自动重连;
//    一开始就连不上本机服务 -> 不挡住页面的「连不上」状态 + 「重试」
// 3. 登录 / 注册是对话框 (TP.auth.openLogin): 同一时间一个; 成功后仪表盘不动、令牌不变、状态变成 user; 密码不对留在对话框里; 只记邮箱; …/login、…/register 打开时弹出它
// 4. E_LOGIN_REQUIRED: 界面切到未登录; 用户的操作 (POST) 弹一次登录框 (带原因), 读取 (GET) 从不弹, 刚关掉 / 短时间里重复也不再弹 (不会一直弹); 不另报错
// 5. 没有登录时的敏感操作: 发出之前恰好一次确认 (原因来自调用方), 取消不发请求; confirmed:true 和「清除日志」(调用方自己问过两次) 不再问;
//    登录时不弹这个确认, 照旧由 403 弹出密码框; 没有登录时 CSS 藏起小锁
// 6. 退出账号 / 切换账号 / 被其它设备下线: 仪表盘照常开着, 令牌不变; 被下线时 auth/status 的 notice 只提示一次 (刷新页面也不再提示), 下次登录成功后忘掉
// 7. 词典: 新增的键中英文都有、占位符一致; 删掉的键 (自动锁定 / 切换账号 / 整页登录 / 只能用本机内容) 两边都没有了, 代码里也不再用
'use strict';
const assert = require('assert'), fs = require('fs'), path = require('path'), vm = require('vm');
const { makeBrowser, storage, fakeI18n, settle } = require('./ui-dom.js');
const read = f => fs.readFileSync(path.join(__dirname, '..', f), 'utf8');

const SUDO = 'fedcba9876543210fedcba9876543210';
const clock = { now: 1770000000000 };
class FakeDate extends Date { static now() { return clock.now; } }
/* 只有 enana 账号能用的接口 (没有登录时 E_LOGIN_REQUIRED) 与再次验证白名单 (只在登录时检查) —— 和 lib/api.sh / tools/mock-server.js 一致的子集 */
const ACCOUNT = ['/api/devices', '/api/devices/kick', '/api/password', '/api/auth/verify', '/api/sync/settings', '/api/sync/push', '/api/sync/pull', '/api/sync/clear', '/api/billing', '/api/diag/send', '/api/diag/delete'];
const SUDO_P = ['/api/servers/delete', '/api/sub/delete', '/api/servers/secret', '/api/sub/url', '/api/logs/clear', '/api/devices/kick', '/api/sync/clear', '/api/export'];

/* 假的辅助服务: st.token = 本机令牌 (= Clash secret), st.in = 这台电脑有没有登录 enana 账号, st.notice = auth/status 的说明 */
function helper(o) {
  const st = Object.assign({ token: 'local-1', in: false, notice: '', localFails: false, rejectAll: false }, o);
  st.calls = [];
  st.fetch = (url, opt) => {
    const u = new URL(url, 'http://127.0.0.1'), hd = opt.headers || {}, body = String(opt.body || ''), form = new URLSearchParams(body);
    const c = { method: opt.method, path: u.pathname, token: hd['X-Enana-Token'] || '', sudo: hd['X-Enana-Sudo'] || '', auth: hd.Authorization || '', body };
    st.calls.push(c);
    const json = (status, b) => Promise.resolve({ status, ok: status >= 200 && status < 300, headers: {}, text: () => Promise.resolve(JSON.stringify(b)), json: () => Promise.resolve(b) });
    if (c.path === '/api/auth/local') return st.localFails ? Promise.reject(new TypeError('Failed to fetch')) : json(200, { ok: true, token: st.token, logged_in: st.in });
    if (c.path === '/api/auth/status') return json(200, { ok: true, required: false, local: true, logged_in: st.in, account_hint: 'd***@e***.com', notice: st.notice, wait: 0 });
    if (c.path === '/api/login') {
      if (form.get('user') === 'demo@example.com' && form.get('password') === 'demo1234') { st.in = true; st.notice = ''; return json(200, { ok: true, token: st.token, account: 'demo@example.com', via: 'online' }); }
      return json(200, { ok: false, code: 'E_BAD_CREDENTIALS', error: 'bad' });
    }
    if (!/^\/api\//.test(c.path)) return !st.rejectAll && c.auth === 'Bearer ' + st.token ? json(200, { version: 'sing-box 1.14.2' }) : json(401, { message: 'Unauthorized' });     // Clash API
    if (st.rejectAll || c.token !== st.token) return json(401, { ok: false, code: 'E_AUTH', error: 'no token' });
    if (c.path === '/api/logout') { st.in = false; return json(200, { ok: true }); }
    if (ACCOUNT.indexOf(c.path) >= 0 && !st.in) return json(200, { ok: false, code: 'E_LOGIN_REQUIRED', error: 'login required' });
    if (SUDO_P.indexOf(c.path) >= 0 && st.in && c.sudo !== SUDO) return json(403, { ok: false, code: 'E_SUDO_REQUIRED', error: 'step-up' });
    if (c.path === '/api/auth/verify') return form.get('password') === 'demo1234' ? json(200, { ok: true, sudo: SUDO, ttl: 300 }) : json(200, { ok: false, code: 'E_BAD_CREDENTIALS', error: 'bad' });
    if (c.path === '/api/state') return json(200, { ok: true, account: { email: st.in ? 'demo@example.com' : '' } });
    return json(200, { ok: true });
  };
  return st;
}
/* 一次「打开页面」(o.path: 打开的地址; o.ss / o.ls: 同一个浏览器的存储, 刷新页面时传同一个) */
async function boot(st, o) {
  o = o || {};
  const b = makeBrowser({ sessionStorage: o.ss || storage(), localStorage: o.ls || storage(), Date: FakeDate, fetch: st.fetch });
  if (o.path) b.win.location.pathname = o.path;
  b.win.I18N = fakeI18n();
  const toasts = b.doc.createElement('div'); toasts.setAttribute('id', 'toasts'); b.doc.body.appendChild(toasts);
  ['ui/core.js', 'ui/data.js', 'ui/ui.js', 'ui/auth.js'].forEach(f => b.load(f));
  b.TP = b.win.TP; b.toasts = toasts;
  b.ev = { auth: [], account: [], login: [] };
  ['auth', 'account', 'login'].forEach(k => b.TP.on(k, v => b.ev[k].push(v)));
  b.dialogs = () => b.doc.body.children.filter(x => x.tagName === 'dialog' && x.open);
  b.toastsWith = s => b.toasts.children.filter(x => x.textContent.indexOf(s) >= 0).length;
  await b.TP.auth.start(); await settle();
  return b;
}
const title = d => d.querySelector('.dlg-t').textContent;
const lines = st => st.calls.map(c => c.method + ' ' + c.path);
async function confirmTop(b, yes) { const d = b.dialogs().slice(-1)[0]; assert(d, 'a dialog is open'); d.querySelector('.dlg-a').children[yes ? 1 : 0].click(); await settle(12); }

(async () => {
  /* ================= 1. 打开: 不要密码 ================= */
  let st = helper(), b = await boot(st);
  assert.deepEqual(lines(st), ['POST /api/auth/local', 'GET /api/auth/status'], 'no token yet: the public POST /api/auth/local first, then the public status');
  assert.equal(st.calls[0].token, '', 'auth/local is sent without a token'); assert.equal(st.calls[0].body, '', 'and without any password');
  assert.equal(b.TP.getToken(), 'local-1'); assert.equal(JSON.parse(b.win.sessionStorage['enana.token']), 'local-1', 'the local token lives in sessionStorage');
  assert(!Object.keys(b.win.localStorage).some(k => String(b.win.localStorage[k]).indexOf('local-1') >= 0), 'never in localStorage');
  assert.equal(b.TP.S.locked, false, 'the dashboard is open'); assert.deepEqual(b.ev.auth, [true]); assert.deepEqual(b.ev.account, [false]);
  assert.equal(b.TP.auth.state(), 'guest'); assert.equal(b.doc.documentElement.getAttribute('data-acct'), 'guest');
  assert(b.doc.documentElement.classList.contains('ui-ready'), 'the shell is shown at once');
  assert.equal(b.dialogs().length, 0, 'no login page and no login dialog'); assert.equal(b.TP.auth.label(), 'auth.guest.label', 'the header says "not signed in"');
  assert.equal(b.TP.auth.email(), '');
  {
    const s2 = helper({ in: true }), ss = storage(); ss['enana.token'] = JSON.stringify('local-1');
    const b2 = await boot(s2, { ss });
    assert.deepEqual(lines(s2), ['GET /api/auth/status'], 'a tab that already has its local token does not fetch it again');
    assert.equal(b2.TP.auth.state(), 'user'); assert.equal(b2.doc.documentElement.getAttribute('data-acct'), 'user'); assert.equal(b2.dialogs().length, 0);
  }

  /* ================= 2. 401 / 失去连接 / 连不上 ================= */
  st.token = 'local-2'; st.calls.length = 0;                                      // 辅助服务重新安装过: secret 变了
  assert.deepEqual(await b.TP.helper('GET', '/api/state'), { ok: true, account: { email: '' } });
  assert.deepEqual(st.calls.map(c => [c.method + ' ' + c.path, c.token]), [['GET /api/state', 'local-1'], ['POST /api/auth/local', ''], ['GET /api/state', 'local-2']], '401: one silent re-fetch, then the same request with the new token');
  assert.equal(b.TP.getToken(), 'local-2'); assert.equal(b.TP.S.locked, false); assert.deepEqual(b.ev.auth, [true], 'not treated as a lost connection');
  clock.now += 6000; st.token = 'local-3'; st.calls.length = 0;
  assert.equal((await b.TP.clash('GET', '/version')).version, 'sing-box 1.14.2');
  assert.deepEqual(st.calls.map(c => [c.method + ' ' + c.path, c.auth]), [['GET /version', 'Bearer local-2'], ['POST /api/auth/local', ''], ['GET /version', 'Bearer local-3']], 'the Clash API (same secret) re-fetches the same way');
  clock.now += 6000; st.calls.length = 0; st.rejectAll = true;                    // 辅助服务坏了: 什么令牌都 401
  await assert.rejects(b.TP.helper('GET', '/api/state'), e => e.kind === 'auth');
  assert.deepEqual(lines(st), ['GET /api/state', 'POST /api/auth/local', 'GET /api/state'], 'exactly one re-fetch, then give up (no loop)');
  assert.equal(b.TP.S.locked, true, 'polling stops'); assert.equal(b.TP.auth.connState(), 'fail', 'the "cannot reach the local service" state'); assert.deepEqual(b.ev.auth, [true, false]);
  assert.equal(b.TP.getToken(), '', 'the useless token is dropped'); assert.equal(b.dialogs().length, 0, 'never a login page');
  await assert.rejects(b.TP.helper('GET', '/api/state'), e => e.kind === 'auth');
  assert.equal(st.calls.filter(c => c.path === '/api/auth/local').length, 1, 'another 401 within 5 s does not fetch again (no request storm)');
  st.rejectAll = false; st.token = 'local-5';
  b.timers.filter(x => x.ms === 2000).pop().fn(); await settle();                // 自动重连 (lost() 排的定时器)
  assert.equal(b.TP.S.locked, false, 'reconnects on its own'); assert.equal(b.TP.getToken(), 'local-5'); assert.equal(b.TP.auth.connState(), 'ok'); assert.deepEqual(b.ev.auth, [true, false, true]);
  {
    const s3 = helper({ localFails: true }), b3 = await boot(s3);
    assert.equal(b3.TP.S.locked, true); assert.equal(b3.TP.auth.connState(), 'fail', 'the local service is down at start: a non-blocking state, not a login page');
    assert.equal(b3.dialogs().length, 0); assert(b3.doc.documentElement.classList.contains('ui-ready'), 'the shell is still shown');
    assert.equal(b3.TP.why.helper(), 'why.locked', 'controls explain that the dashboard is still connecting');
    s3.localFails = false; await b3.TP.auth.retryConnect(); await settle();
    assert.equal(b3.TP.S.locked, false, '"Retry" connects'); assert.equal(b3.TP.auth.connState(), 'ok'); assert.equal(b3.TP.getToken(), 'local-1');
  }

  /* ================= 3. 登录 / 注册对话框 ================= */
  st = helper(); b = await boot(st);
  const p1 = b.TP.auth.openLogin({ mode: 'login' }), p2 = b.TP.auth.openLogin({ mode: 'login' });
  assert.strictEqual(p1, p2, 'one dialog at a time: a second call returns the same promise');
  let dl = b.dialogs(); assert.equal(dl.length, 1); assert(dl[0].classList.contains('authdlg') && !/authpage/.test(dl[0].className), 'a normal dialog over the dashboard, not a full page');
  assert.equal(title(dl[0]), 'auth.page.login');
  const email = dl[0].querySelector('input[name=username]'), pw = dl[0].querySelector('input[name=password]');
  email.value = 'demo@example.com'; pw.value = 'wrong';
  dl[0].querySelector('form').dispatch('submit'); await settle(12);
  assert.equal(b.dialogs().length, 1, 'a wrong password keeps the dialog open'); assert.equal(b.TP.auth.state(), 'guest');
  assert(dl[0].querySelector('.login-err').classList.contains('on'), 'and shows the error');
  pw.value = 'demo1234'; dl[0].querySelector('form').dispatch('submit'); await settle(12);
  assert.equal(await p1, true, 'openLogin resolves true after signing in');
  assert.equal(b.dialogs().length, 0); assert.equal(b.TP.auth.state(), 'user'); assert.equal(b.TP.auth.email(), 'demo@example.com');
  assert.equal(b.TP.getToken(), 'local-1', 'the same local token; the dashboard did not move'); assert.equal(b.TP.S.locked, false);
  assert.equal(b.ev.login.length, 1); assert.equal(b.ev.login[0].registered, false); assert.deepEqual(b.ev.account, [false, true]);
  const logins = st.calls.filter(c => c.path === '/api/login');
  assert.equal(logins.length, 2); assert.equal(logins[1].token, '', 'sign-in is a public request'); assert.equal(new URLSearchParams(logins[1].body).get('password'), 'demo1234', 'the password only travels in the request body');
  assert.equal(pw.value, '', 'the typed password is wiped');
  assert.equal(b.win.localStorage['enana.login.email'], JSON.stringify('demo@example.com'), 'only the email is remembered');
  [b.win.localStorage, b.win.sessionStorage].forEach(s => Object.keys(s).forEach(k => assert(String(s[k]).indexOf('demo1234') < 0, 'the password is never stored (' + k + ')')));
  {
    const s5 = helper(), b5 = await boot(s5);
    const pr = b5.TP.auth.openLogin({ mode: 'register' }), d5 = b5.dialogs()[0];
    assert.equal(title(d5), 'auth.page.reg'); assert.equal(d5.querySelector('input[name=password2]').parentNode.parentNode.hidden, false, 'register asks for the password twice');
    d5.querySelector('.ap-sw').click(); await settle();
    assert.equal(title(d5), 'auth.page.login', 'the link at the bottom switches to sign-in'); assert.equal(d5.querySelector('input[name=password2]').parentNode.parentNode.hidden, true);
    d5.querySelector('.dlg-x').click(); await settle();
    assert.equal(await pr, false, 'closing it resolves false'); assert.equal(b5.dialogs().length, 0); assert.equal(b5.TP.auth.state(), 'guest');
    const b6 = await boot(helper(), { path: '/enana/admin/register' });
    assert.equal(b6.dialogs().length, 1, '…/register opens the dashboard with the register dialog'); assert.equal(title(b6.dialogs()[0]), 'auth.page.reg'); assert.equal(b6.TP.S.locked, false);
    const b7 = await boot(helper(), { path: '/enana/admin/login' });
    assert.equal(b7.dialogs().length, 1); assert.equal(title(b7.dialogs()[0]), 'auth.page.login', '…/login opens the sign-in dialog');
    const b8 = await boot(helper({ in: true }), { path: '/enana/admin/login' });
    assert.equal(b8.dialogs().length, 0, 'already signed in: …/login just opens the dashboard');
  }

  /* ================= 4. E_LOGIN_REQUIRED ================= */
  st = helper({ in: true }); b = await boot(st);
  assert.equal(b.TP.auth.state(), 'user');
  st.in = false; clock.now += 6000;                                               // 辅助服务那边刚刚退出了账号 (例如被下线), 仪表盘还不知道
  const before = b.toasts.children.length;
  await assert.rejects(b.TP.helper('POST', '/api/diag/send', { form: { hours: 24 } }), e => e.kind === 'cancel' && e.code === 'E_LOGIN_REQUIRED');
  await settle();
  assert.equal(b.TP.auth.state(), 'guest', 'the dashboard switches to its guest view'); assert.equal(b.ev.account.slice(-1)[0], false);
  dl = b.dialogs(); assert.equal(dl.length, 1, 'one sign-in dialog'); assert(dl[0].classList.contains('authdlg'));
  assert.equal(dl[0].querySelector('.login-msg').textContent, 'error.E_LOGIN_REQUIRED', 'it says why');
  await assert.rejects(b.TP.helper('POST', '/api/diag/delete'), e => e.code === 'E_LOGIN_REQUIRED'); await settle();
  assert.equal(b.dialogs().length, 1, 'another account-only action while it is open: still one dialog');
  dl[0].querySelector('.dlg-x').click(); await settle();
  await assert.rejects(b.TP.helper('GET', '/api/devices'), e => e.code === 'E_LOGIN_REQUIRED'); await settle();
  assert.equal(b.dialogs().length, 0, 'a read (GET, e.g. polling) never opens the dialog');
  await assert.rejects(b.TP.helper('POST', '/api/diag/send', { form: { hours: 24 } }), e => e.code === 'E_LOGIN_REQUIRED'); await settle();
  assert.equal(b.dialogs().length, 0, 'right after the user closed it, a burst does not reopen it (never a loop)');
  await assert.rejects(b.TP.helper('POST', '/api/diag/send', { form: { hours: 24 }, quiet: true }), e => e.code === 'E_LOGIN_REQUIRED');
  clock.now += 3500; await settle();
  assert.equal(b.dialogs().length, 0, 'quiet:true never opens it');
  await assert.rejects(b.TP.helper('POST', '/api/diag/send', { form: { hours: 24 } }), e => e.code === 'E_LOGIN_REQUIRED'); await settle();
  assert.equal(b.dialogs().length, 1, 'a later user action asks again');
  assert.equal(b.toasts.children.length, before, 'no error toast on top of the dialog');
  b.dialogs()[0].querySelector('.dlg-x').click(); await settle();

  /* ================= 5. 没有登录时的敏感操作: 恰好一次确认 ================= */
  st = helper(); b = await boot(st); st.calls.length = 0;
  let pp = b.TP.helper('GET', '/api/servers/secret', { q: { tag: 'n1' }, sudoWhy: 'why: reveal n1' }); await settle();
  assert.equal(st.calls.length, 0, 'nothing is sent before the confirmation');
  let cd = b.dialogs(); assert.equal(cd.length, 1, 'exactly one confirmation');
  assert.equal(cd[0].querySelector('.cfm-m').textContent, 'why: reveal n1', 'the reason comes from the caller'); assert(!cd[0].querySelector('input[type=password]'), 'no password field: there is no account to verify');
  await confirmTop(b, true);
  assert.deepEqual(await pp, { ok: true }); assert.deepEqual(st.calls.map(c => [c.path, c.sudo]), [['/api/servers/secret', '']], 'sent once, without X-Enana-Sudo');
  assert.equal(b.dialogs().length, 0, 'no second dialog');
  st.calls.length = 0; pp = b.TP.helper('GET', '/api/sub/url', { q: { name: 's' } }); await settle();
  cd = b.dialogs(); assert.equal(cd.length, 1); assert.equal(cd[0].querySelector('.cfm-m').textContent, 'sudo.guest.msg', 'a generic reason when the caller gives none');
  await confirmTop(b, false);
  await assert.rejects(pp, e => e.kind === 'cancel'); assert.equal(st.calls.length, 0, 'cancel sends nothing');
  for (const x of [['POST', '/api/servers/delete', { q: { tag: 'n1' }, confirmed: true }], ['POST', '/api/sub/delete', { q: { name: 's' }, confirmed: true }], ['GET', '/api/export', { text: true, confirmed: true }], ['POST', '/api/logs/clear', { form: { type: 'ops' } }]]) {
    st.calls.length = 0; await b.TP.helper(x[0], x[1], x[2]); await settle();
    assert.equal(b.dialogs().length, 0, x[1] + ': the caller already confirmed -> no second confirmation'); assert.deepEqual(lines(st), [x[0] + ' ' + x[1]]);
  }
  st.calls.length = 0; await b.TP.helper('POST', '/api/override', { q: { kind: 'site', value: 'a.example', state: 'pin' } }); assert.equal(b.dialogs().length, 0, 'ordinary actions are not affected');
  assert(read('ui/style.css').indexOf('html[data-acct="guest"] .sudo-l{display:none}') >= 0, 'no lock icons while not signed in');
  st.in = true; b.TP.emit('state', { ok: true, account: { email: 'demo@example.com' } }); await settle();      // 在别处登录了: 下一次 /api/state 看到
  assert.equal(b.TP.auth.state(), 'user'); assert.equal(b.doc.documentElement.getAttribute('data-acct'), 'user');
  st.calls.length = 0; pp = b.TP.helper('GET', '/api/servers/secret', { q: { tag: 'n1' }, sudoWhy: 'why' }); await settle();
  assert.deepEqual(lines(st), ['GET /api/servers/secret'], 'signed in: sent at once (the helper decides) ...');
  cd = b.dialogs(); assert.equal(cd.length, 1); const spw = cd[0].querySelector('input[type=password]');
  assert(spw, '... and its 403 opens the password dialog instead of the guest confirmation');
  spw.value = 'demo1234'; cd[0].querySelector('[data-id="go"]').click(); await settle(12);
  assert.deepEqual(await pp, { ok: true }); assert.deepEqual(st.calls.map(c => [c.path, c.sudo]), [['/api/servers/secret', ''], ['/api/auth/verify', ''], ['/api/servers/secret', SUDO]]);
  assert.equal(b.dialogs().length, 0);

  /* ================= 6. 退出 / 切换 / 被下线: 仪表盘留着 ================= */
  const ls6 = storage(), ss6 = storage();
  st = helper({ in: true }); b = await boot(st, { ls: ls6, ss: ss6 });
  let lo = b.TP.auth.logout('logout'); await settle(); await confirmTop(b, true); await lo;
  assert.deepEqual(st.calls.filter(c => c.path === '/api/logout').map(c => c.method), ['POST']);
  assert.equal(b.TP.auth.state(), 'guest'); assert.equal(b.TP.getToken(), 'local-1', 'logout keeps the local token'); assert.equal(b.TP.S.locked, false, 'the dashboard stays open');
  assert.equal(b.dialogs().length, 0, 'no login page / dialog after logout'); assert.equal(b.toastsWith('auth.signedOut'), 1, 'a short note says the proxy settings are kept');
  st.in = true; clock.now += 6000; b.TP.emit('state', { ok: true, account: { email: 'demo@example.com' } }); await settle();
  assert.equal(b.TP.auth.state(), 'user');
  lo = b.TP.auth.logout('switch'); await settle(); await confirmTop(b, true); await lo;
  assert.equal(b.TP.auth.state(), 'guest'); dl = b.dialogs();
  assert.equal(dl.length, 1, 'switch account = log out, then the sign-in dialog'); assert.equal(dl[0].querySelector('.login-msg').textContent, 'auth.switched');
  dl[0].querySelector('.dlg-x').click(); await settle();
  assert.equal(st.calls.filter(c => c.path === '/api/logout').length, 2); assert.equal(b.TP.getToken(), 'local-1');
  /* 被其它设备下线: 下一次 /api/state 的 account.email 是空的 -> 读 auth/status 的 notice, 提示一次 */
  st.in = true; clock.now += 6000; b.TP.emit('state', { ok: true, account: { email: 'demo@example.com' } }); await settle();
  st.in = false; st.notice = 'KICKED-NOTICE'; clock.now += 6000;
  b.TP.emit('state', { ok: true, account: { email: '' } }); await settle(12);
  assert.equal(b.TP.auth.state(), 'guest'); assert.equal(b.dialogs().length, 0, 'kicked: the dashboard stays open, no login page');
  assert.equal(b.toastsWith('KICKED-NOTICE'), 1, 'the notice from auth/status is shown once');
  b.TP.emit('state', { ok: true, account: { email: '' } }); await settle(12); assert.equal(b.toastsWith('KICKED-NOTICE'), 1, 'not again');
  b = await boot(st, { ls: ls6, ss: ss6 });                                       // 刷新页面
  assert.equal(b.TP.auth.state(), 'guest'); assert.equal(b.toastsWith('KICKED-NOTICE'), 0, 'not again after a reload either');
  b.TP.auth.openLogin(); dl = b.dialogs();
  dl[0].querySelector('input[name=username]').value = 'demo@example.com'; dl[0].querySelector('input[name=password]').value = 'demo1234';
  dl[0].querySelector('form').dispatch('submit'); await settle(12);
  assert.equal(b.TP.auth.state(), 'user'); assert.equal(ls6['enana.authNotice'], undefined, 'a successful sign-in forgets the shown notice (the next kick is explained again)');

  /* ================= 7. 词典 ================= */
  const dict = f => { const d = {}; vm.runInNewContext(read(f), { window: { I18N: { register: (c, o) => Object.assign(d, o) } } }); return d; };
  const zh = dict('ui/i18n/zh.js'), en = dict('ui/i18n/en.js');
  const ph = v => [...new Set((typeof v === 'string' ? [v] : Object.values(v)).join(' ').match(/\{\w+\}/g) || [])].sort();
  const ADDED = ['auth.register', 'auth.guest.label', 'auth.guest.title', 'auth.guest.acct', 'auth.guest.sync', 'auth.guest.plan', 'auth.guest.official', 'error.E_LOGIN_REQUIRED',
    'banner.local.title', 'banner.local.text', 'banner.local.hint', 'sudo.guest.title', 'sudo.guest.msg', 'sudo.guest.note', 'sudo.guest.go', 'set.bk.goGuest'];
  for (const k of ADDED) {
    assert(k in zh && k in en, 'both dictionaries have ' + k); assert.deepEqual(ph(zh[k]), ph(en[k]), 'same placeholders: ' + k);
    assert(/[一-鿿]/.test(zh[k]) && !/[一-鿿]/.test(en[k]), 'zh is Chinese and en is not: ' + k);
  }
  const GONE = ['auth.autoLock', 'auth.expired', 'auth.logout.d1', 'auth.logout.d3', 'auth.logout.d4', 'set.lock.title', 'set.lock.hint', 'set.lock.default', 'dur.min', 'dur.hour', 'dur.hour1', 'dur.day', 'dur.day1',
    'status.locked', 'user.switch', 'set.acc.switch', 'set.reset.fromLocal'];
  const code = fs.readdirSync(path.join(__dirname, '..', 'ui')).filter(f => /\.js$/.test(f)).map(f => read('ui/' + f)).join('\n');
  for (const k of GONE) { assert(!(k in zh) && !(k in en), 'removed: ' + k); assert(code.indexOf("'" + k + "'") < 0, 'no code uses ' + k); }
  for (const f of ['ui/auth.js', 'ui/app.js', 'ui/core.js', 'ui/v-settings.js', 'ui/v-sync.js', 'ui/billing.js', 'ui/plan.js', 'ui/v-servers.js']) {
    const src = read(f).replace(/\/\*[\s\S]*?\*\//g, '');
    for (const m of src.matchAll(/\b(?:t|L)\('([a-z]\w*(?:\.[\w-]+)+)'/g)) assert(m[1] in zh && m[1] in en, f + ' uses ' + m[1] + ', missing in a dictionary');
  }
  for (const kind of ['acct', 'sync', 'plan', 'official']) assert(('auth.guest.' + kind) in zh, 'guest text for ' + kind);
  assert(/'auth\.guest\.' \+ kind/.test(read('ui/auth.js')), 'the guest texts are picked by kind');
  for (const [f, kind] of [['ui/v-settings.js', 'acct'], ['ui/v-settings.js', 'plan'], ['ui/v-sync.js', 'sync'], ['ui/v-servers.js', 'official']]) assert(read(f).indexOf("('" + kind + "')") >= 0, f + ' shows the ' + kind + ' guest text');

  console.log('PASS: the dashboard opens without a password (local token), 401 re-fetches it once, sign-in is a dialog, E_LOGIN_REQUIRED opens it without loops, guests confirm sensitive actions exactly once, logout and kicks keep the dashboard open');
})().catch(e => { console.error(e); process.exitCode = 1; });
