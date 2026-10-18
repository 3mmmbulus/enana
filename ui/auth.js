/* enana · auth.js — 本机连接 · enana 账号 (可选) · 登录 / 注册对话框 · 敏感操作的再次验证
 * 2.3.27 起仪表盘不需要任何密码就能打开 (登录了 enana 账号也好, 没有也好)。enana.cc 账号 (邮箱 + 密码) 只在这些地方需要: 云端同步、会员 (购买 / 余额 / 订单)、
 * 官方线路、我的设备、修改密码、上传诊断。其它一切 (自己的服务器、订阅、导入、一键部署、应用、网站、DNS、规则、日志、测速、更新、代理开关) 不登录也能用。
 * 本机连接: 没有令牌 -> POST /api/auth/local (公开; 辅助服务照样检查 Host / X-Enana / 跨域来源) -> 本机令牌 (= 核心 Clash API 的 secret) -> TP.setToken -> 仪表盘。
 *   之后任何 401 -> 悄悄再取一次 (A.reauth) 并重试那个请求 (core.js); 还是不行 -> 顶部提示「连不上本机的 enana 服务」(不挡住页面), 隔几秒自动重连。
 * 账号状态: A.state() = 'unknown' (还没读到) | 'guest' (没有登录) | 'user'; 变化时发事件 account (true / false), <html data-acct="guest|user"> (没有登录时 CSS 藏起小锁图标)。
 *   来源: POST /api/auth/local 和 GET /api/auth/status 的 logged_in · GET /api/state 的 account.email (每 10 秒: 在别的标签页 / 终端里登录或退出、被其它设备下线、
 *   离线太久自动退出都从这里看到) · 自己的登录 / 注册 / 退出 · 任何 E_LOGIN_REQUIRED。不是自己退出的: 仪表盘照常开着, 只提示一次 GET /api/auth/status 的 notice。
 * 登录 / 注册: A.openLogin({mode:'login'|'register', reason}) -> 对话框 (同一时间一个; 设备已满时列出在线设备, 选一台下线后自动完成登录)。
 *   地址 …/login 和 …/register 打开仪表盘并弹出它; 账号菜单、设置 → 账号、需要账号的页面和任何 E_LOGIN_REQUIRED (A.loginRequired) 也会打开它。
 * 退出账号: POST /api/logout (本机令牌不变, 代理设置保留; 官方线路 / 同步 / 会员停止) -> 仪表盘留在当前页。
 * 最近输入的邮箱会记在 localStorage (只记邮箱, 绝不记密码)。没有「无操作自动锁定」: 仪表盘本来就不需要密码, 锁定没有意义。 */
(function () {
  'use strict';
  var TP = window.TP, S = TP.S, h = TP.h, ui = TP.ui, I = window.I18N, t = I.t, L = I.L;
  var A = TP.auth = { account: '', hint: '', status: null, loggedIn: null };      // loggedIn: null = 还不知道 · true · false
  var seg = (/^(.*\/)([^/]*)$/.exec(location.pathname) || [])[2], firstDialog = seg === 'login' || seg === 'register' ? seg : '';   // 打开的地址是 …/login 或 …/register (在 app.js 把地址改成当前页之前记下来)
  /* 对话框顶部的提示: 带词典键的对象, 切换语言后会按新语言重新生成文字 (String(x) 取当前语言的文字) */
  A.msg = function (key, vars) { return { key: key, vars: vars || null, toString: function () { return t(key, vars); } }; };
  var DEF = { account_url: 'https://enana.cc' };      // 官网只有一个首页: 注册 / 登录 / 改密码 / 设备管理都在仪表盘里完成

  /* 来自辅助服务的链接只接受 https:// ; 否则用默认地址 */
  function urlOf(k) { var u = A.status && A.status[k]; return /^https:\/\//i.test(String(u || '')) ? String(u) : DEF[k]; }
  A.url = urlOf;
  A.openUrl = function (k) { try { window.open(urlOf(k), '_blank', 'noopener,noreferrer'); } catch (e) { /* 弹窗被拦截: 忽略 */ } };

  /* ================= 账号状态 ================= */
  var acctSeq = 0, acctAt = 0, lostN = 0;   // acctSeq: 自己改变账号状态时 +1 (之前发出的 auth/status 晚到的回答作废); acctAt: 自己改变的时刻 (之后 5 秒内 /api/state 里旧的 account.email 不算数); lostN: 见 lost()
  A.signedIn = function () { return A.loggedIn === true; };
  A.guest = function () { return A.loggedIn === false; };
  A.state = function () { return A.loggedIn === true ? 'user' : A.loggedIn === false ? 'guest' : 'unknown'; };
  /* 当前登录的邮箱: 登录结果 > /api/state 的 account.email > /api/settings 的 account.email; 没有登录时是空 */
  A.email = function () {
    if (A.loggedIn === false) return '';
    var a = A.account || (S.state && S.state.account && S.state.account.email) || (S.prefs && S.prefs.account && S.prefs.account.email) || '';
    return a ? String(a) : '';
  };
  A.label = function () { return A.loggedIn === false ? t('auth.guest.label') : (A.email() || A.hint || t('auth.account')); };
  /* own = 这个标签页自己登录 / 注册 / 退出的 (不是从别处看到的) */
  function setLoggedIn(on, own) {
    on = !!on;
    if (own) { acctSeq++; acctAt = Date.now(); }
    if (A.loggedIn === on) return;
    var was = A.loggedIn;
    A.loggedIn = on;
    if (!on) A.account = '';
    try { document.documentElement.setAttribute('data-acct', on ? 'user' : 'guest'); } catch (e) { /* 忽略 */ }
    TP.emit('account', on);
    if (was === true && !on && !own) refreshStatus().then(showNotice);          // 被下线 / 离线过期 / 在别处退出: 说明一次原因
  }
  /* auth/status 的 notice (例如「这台设备已被另一台设备下线, 代理照常使用你自己的服务器」): 没有登录时提示一次; 同一条只提示一次 (记在 localStorage, 下次登录成功后清掉) */
  function showNotice() {
    var n = A.status && A.status.notice ? String(A.status.notice) : '';
    if (!n || A.loggedIn !== false || TP.ls.get('authNotice', '') === n) return;
    TP.ls.set('authNotice', n);
    if (login) { login.repaint(); return; }                                    // 登录框开着: 它自己会显示这条说明, 不再另弹提示
    ui.toast(n, 'warn', 15000, { action: { label: t('auth.login'), fn: function () { A.openLogin({ mode: 'login' }); } } });
  }
  /* GET /api/state (每 10 秒) 的 account.email; 读到了状态也说明和本机服务的连接是好的 (lost() 的退避计数清零) */
  TP.on('state', function (st) {
    var a = st && st.account;
    lostN = 0;
    if (!a || typeof a.email !== 'string' || Date.now() - acctAt < 5000) return;     // 刚刚自己登录 / 退出过: 之前发出的请求可能带回旧状态, 等下一次
    if (a.email && A.loggedIn === true && A.account && String(A.account).toLowerCase() !== a.email.toLowerCase()) { A.account = a.email; TP.emit('account', true); return; }    // 在别处换了账号: 按新账号重新读取
    setLoggedIn(!!a.email, false);
  });

  /* 公开状态 (account_hint / notice / wait / logged_in) */
  function refreshStatus() {
    var seq = acctSeq;
    return TP.helper('GET', '/api/auth/status', { noAuth: true, timeout: 6000 }).then(function (st) {
      if (st && typeof st === 'object') {
        A.status = st; A.hint = st.account_hint ? String(st.account_hint) : A.hint;
        if (typeof st.logged_in === 'boolean' && seq === acctSeq) setLoggedIn(st.logged_in, false);
      }
      return st;
    }, function () { return null; });
  }
  A.refreshStatus = refreshStatus;

  /* ================= 本机连接 (POST /api/auth/local) ================= */
  var conn = { st: 'none', timer: 0, tries: 0, busy: null }, reauthing = null, reauthAt = 0;
  A.connState = function () { return conn.st; };                   // 'none' | 'connecting' | 'ok' | 'fail' (连不上本机服务: 顶部提示条, 自动重连)
  function setConn(st) { if (conn.st !== st) { conn.st = st; TP.emit('conn', st); } }
  function ready() { document.documentElement.classList.add('ui-ready'); }       // 显示页面外壳 (boot.js 在启动之前把它藏起来)
  /* 取本机令牌 (不需要任何密码): 成功 -> true; 辅助服务连不上 / 拒绝 -> false */
  async function fetchLocal() {
    var seq = acctSeq;
    try {
      var r = await TP.helper('POST', '/api/auth/local', { noAuth: true, timeout: 8000 });
      if (!r || typeof r.token !== 'string' || !/^[\x21-\x7e]{8,256}$/.test(r.token)) return false;     // 要能放进请求头
      TP.setToken(r.token);
      if (typeof r.logged_in === 'boolean' && seq === acctSeq) setLoggedIn(r.logged_in, false);
      return true;
    } catch (e) { return false; }
  }
  function unlock() {
    var was = S.locked;
    S.locked = false; conn.tries = 0; clearTimeout(conn.timer);
    setConn('ok');
    if (was) TP.emit('auth', true);
  }
  function connect() {
    if (conn.busy) return conn.busy;
    clearTimeout(conn.timer);
    if (conn.st !== 'fail') setConn('connecting');                  // 已经是「连不上」时重试期间不来回闪
    conn.busy = fetchLocal().then(function (ok) {                   // 登录与否已经在 auth/local 的回答里 (logged_in); 提示语等公开状态由 A.start 另外读
      conn.busy = null;
      if (ok) unlock();
      else { conn.tries++; setConn('fail'); conn.timer = setTimeout(connect, Math.min(30000, 2000 * conn.tries)); }
      return ok;
    });
    return conn.busy;
  }
  A.retryConnect = function () { conn.tries = 0; return connect(); };
  /* 401 (core.js): 令牌失效了 (例如重新安装后 secret 变了) -> 悄悄取一次新的; 刚取过 (5 秒内) 还被拒绝就不再取, 不会来回循环 */
  A.reauth = function () {
    if (reauthing) return reauthing;
    if (Date.now() - reauthAt < 5000) return Promise.resolve(false);
    reauthing = fetchLocal().then(function (ok) { reauthing = null; reauthAt = Date.now(); return ok; });
    return reauthing;
  };
  /* 换了令牌还是 401: 停下轮询, 顶部提示连不上, 稍后自动重连 (连续失去连接时间隔加倍, 最长 30 秒) */
  function lost() {
    if (S.locked) return;
    lostN++; S.locked = true; TP.setToken('');
    setConn('fail'); TP.emit('auth', false);
    clearTimeout(conn.timer); conn.timer = setTimeout(connect, Math.min(30000, 1000 * Math.pow(2, Math.min(lostN, 5))));
  }
  TP.on('unauth', lost);

  /* ================= 启动 ================= */
  A.start = async function () {
    ready();                                                         // 没有整页的登录框了: 外壳马上显示
    if (TP.getToken()) unlock(); else await connect();               // 这个标签页里已经有令牌就直接用 (失效了第一个请求会 401 -> 悄悄换新的)
    await refreshStatus();
    if (A.loggedIn === false) showNotice();
    if (firstDialog) { var m = firstDialog; firstDialog = ''; if (!A.signedIn()) A.openLogin({ mode: m }); }
  };

  /* ================= 需要账号 (TP.helper 收到 E_LOGIN_REQUIRED) =================
   * 辅助服务说这台电脑没有登录: 界面切到未登录状态 (需要账号的页面换成说明 + 登录 / 注册)。用户的操作 (不是 GET) 弹出一次登录框;
   * 读取 (GET, 轮询) 从不弹框, 登录框开着 / 3 秒内刚弹过也不再弹, 所以不会一直弹。 */
  var promptedAt = 0;
  A.loginRequired = function (method, path, o) {
    setLoggedIn(false, false);
    if ((o && o.quiet) || method === 'GET' || login || Date.now() - promptedAt < 3000) return;
    promptedAt = Date.now();
    A.openLogin({ mode: 'login', reason: A.msg('error.E_LOGIN_REQUIRED') });
  };

  /* ================= 需要账号的页面在没有登录时的说明 + 「登录」「注册」 =================
   * kind: acct (设置 → 账号) · sync (云端同步) · plan (会员) · official (服务器 → 官方线路); 文字是 auth.guest.<kind>。
   * guestBlock = 一段说明 + 两个按钮 (放进已有的卡片里); guestCard = 带标题的独立卡片 */
  A.guestBlock = function (kind) {
    var bIn = ui.btn(L('auth.login'), { kind: 'primary', icon: 'account' }), bUp = ui.btn(L('auth.register'), { icon: 'plus' });
    ui.act(bIn, function () { A.openLogin({ mode: 'login' }); });           // 不等对话框关闭 (否则按钮一直转圈)
    ui.act(bUp, function () { A.openLogin({ mode: 'register' }); });
    return h('div', { class: 'guest-b', 'data-kind': kind }, h('p', { class: 'muted guest-t' }, L('auth.guest.' + kind)), h('div', { class: 'row wrap guest-btns' }, bIn, bUp));
  };
  A.guestCard = function (kind) {
    return h('section', { class: 'card set-card guest-card' }, h('div', { class: 'card-h' }, ui.icon('account', 20, 'ci'), h('h2', null, L('auth.guest.title'))), A.guestBlock(kind));
  };

  /* ---------- 设备列表 (登录时设备已满 / 设置里的「我的设备」共用) ---------- */
  function platName(p) { p = String(p || '').toLowerCase(); return p === 'macos' || p === 'darwin' ? 'macOS' : p === 'windows' ? 'Windows' : p === 'linux' ? 'Linux' : String(p || ''); }
  A.platName = platName;
  /* d: {uid,name,platform,os,app,last_seen,online,ip_hint,current}; action: 右侧按钮 (可空) */
  A.deviceRow = function (d, action) {
    var online = d.online !== false, bits = [];
    bits.push(h('span', { class: 'dev-st ' + (online ? 'on' : 'off') }, h('i', { class: 'dev-dot' }), t(online ? 'auth.dev.online' : 'auth.dev.offline')));
    if (d.last_seen) bits.push(t('auth.dev.last', { when: TP.fmt.rel(d.last_seen) }));
    var osText = [platName(d.platform), d.os].filter(Boolean).join(' '); if (osText) bits.push(osText);
    if (d.app) bits.push('enana ' + d.app);
    if (d.ip_hint) bits.push(t('auth.dev.ip', { ip: d.ip_hint }));
    var meta = h('div', { class: 'muted sm dev-m' });
    bits.forEach(function (b, i) { if (i) meta.appendChild(document.createTextNode(' · ')); meta.appendChild(typeof b === 'string' ? document.createTextNode(b) : b); });
    return h('div', { class: 'dev' + (d.current ? ' is-cur' : '') + (online ? '' : ' is-off') },
      h('span', { class: 'dev-ic' }, ui.icon('monitor', 20)),
      h('div', { class: 'dev-main' }, h('div', { class: 'dev-t' }, h('b', null, String(d.name || d.uid || '?')), d.current ? h('span', { class: 'badge new' }, t('auth.dev.current')) : null), meta),
      action || null);
  };
  /* 下线一台设备前的二次确认 */
  A.confirmKick = function (d, loginNow) {
    return ui.confirmDialog({
      title: t('auth.dev.confirmTitle', { name: d.name }), message: t('auth.dev.confirmMsg', { name: d.name }),
      detail: [t('auth.dev.d1'), loginNow ? t('auth.dev.d2') : t('auth.dev.d2b'), t('auth.dev.d3')], confirmText: t(loginNow ? 'auth.dev.go' : 'auth.dev.goOnly'), danger: true, confirmIcon: 'logout'
    });
  };

  /* ================= 登录 / 注册: 一个对话框, 底部的链接在两种之间切换 =================
   * 结构: 副标题 · 打开它的原因 (例如「需要登录 enana 账号才能使用这个功能」) · auth/status 的 notice · 上次登录的账号 · 表单 · 「还没有账号? 立即注册」· 说明。
   * 返回 Promise<是否登录成功>; 已经开着时只切换模式 / 更新原因, 返回同一个 Promise。 */
  var login = null;
  A.openLogin = function (o) {
    o = o || {};
    if (login) { if (o.mode) login.setMode(o.mode); if (o.reason) login.setMsg(o.reason); return login.done; }
    if (A.signedIn()) return Promise.resolve(true);
    return showLogin(o);
  };
  A.loginOpen = function () { return !!login; };
  I.onChange(function () { if (login) login.repaint(); });

  function showLogin(o) {
    var mode = o.mode === 'register' ? 'register' : 'login', dm = null, okDone = false, resolveDone = null;
    var done = new Promise(function (r) { resolveDone = r; });
    var email = h('input', { id: 'ap-email', type: 'text', name: 'username', inputmode: 'email', autocomplete: 'username', autocapitalize: 'off', spellcheck: 'false', placeholder: L('auth.ph.email'), value: TP.ls.get('login.email', '') });
    var pw = h('input', { id: 'ap-pw', type: 'password', name: 'password', autocomplete: 'current-password', spellcheck: 'false', placeholder: L('auth.ph.pw') });
    var pw2 = h('input', { id: 'ap-pw2', type: 'password', name: 'password2', autocomplete: 'new-password', spellcheck: 'false', placeholder: L('auth.ph.pw2') });
    var eyes = [];
    function mkEye(target) {                                              // 显示 / 隐藏密码: 两个密码框一起切换
      var eye = ui.ibtn('eye', L('auth.showPw'), { size: 18 }); eye.classList.add('pw-eye'); eye.setAttribute('aria-pressed', 'false'); eyes.push(eye);
      eye.addEventListener('click', function () {
        var show = pw.type === 'password'; pw.type = show ? 'text' : 'password'; pw2.type = pw.type;
        var lab = t(show ? 'auth.hidePw' : 'auth.showPw');
        eyes.forEach(function (e2) { e2.setAttribute('aria-pressed', show ? 'true' : 'false'); e2.setAttribute('aria-label', lab); e2.title = lab; e2._tip = lab; e2.replaceChild(ui.icon(show ? 'eye-off' : 'eye', 18, 'bi'), e2.firstChild); e2._iconEl = e2.firstChild; });
        target.focus();
      });
      return eye;
    }
    var msgEl = h('p', { class: 'login-msg', 'aria-live': 'polite' }), noticeEl = h('p', { class: 'login-notice', role: 'status' }, ui.icon('info', 16, 'ci'), h('span'));
    var pending = null;                                                    // 设备已满时: {user, password} 只留在这个变量里 (内存); 登录成功 / 取消 / 关闭后清掉
    function wipePending() { if (pending) { pending.password = ''; pending = null; } }
    var err = h('div', { class: 'login-err', role: 'alert' }), errTxt = h('span');
    var errBtn = ui.btn(L('auth.retry'), { sm: true, icon: 'refresh' }); errBtn.hidden = true;
    err.appendChild(errTxt); err.appendChild(errBtn);
    var btn = ui.btn(L('auth.submit.login'), { kind: 'primary', type: 'submit', cls: 'ap-btn' });
    function afield(labelKey, input, icon, extra, hintKey) {              // 带必填星号的标签 + 左侧图标的输入框 (右侧可放「显示密码」按钮 / 标签行右侧放提示)
      var hint = hintKey ? h('span', { class: 'ap-lh' }, L(hintKey)) : null;
      return h('div', { class: 'ap-f' },
        h('div', { class: 'ap-lr' }, h('label', { class: 'ap-l', for: input.id }, L(labelKey), h('span', { class: 'ap-req', 'aria-hidden': 'true' }, '*')), hint),
        h('span', { class: 'ap-in' }, ui.icon(icon, 18, 'ap-ic'), input, extra || null));
    }
    var fEmail = afield('auth.f.email', email, 'mail'), fPw = afield('auth.f.pw', pw, 'lock', mkEye(pw), 'auth.pwMin'), fPw2 = afield('auth.f.pw2', pw2, 'lock', mkEye(pw2));
    var pwMin = fPw.querySelector('.ap-lh');
    var form = h('form', { class: 'ap-form', novalidate: true }, fEmail, fPw, fPw2, err, btn);
    var last = h('p', { class: 'login-bind' }, ui.icon('account', 16, 'ci'), h('span'));
    var note = h('p', { class: 'ap-note' }, ui.icon('info', 14, 'ci'), h('span'));
    var subEl = h('p', { class: 'ap-sub' }), swQ = h('span'), swA = h('button', { class: 'ap-sw', type: 'button' });
    var st = A.status || {}, wait = +st.wait > 0 ? Math.ceil(+st.wait) : 0, timer = 0, busy = false, curMsg = o.reason || '', errState = null, errAct = null;

    function paint() {
      var reg = mode === 'register';
      if (wait > 0) { ui.setBtn(btn, t('auth.waitBtn', { n: wait })); ui.avail(btn, t('auth.waitReason', { n: wait })); }
      else if (busy) { ui.setBtn(btn, t(reg ? 'auth.contacting' : 'auth.verifying')); ui.avail(btn, t('auth.busyReason')); }
      else { ui.setBtn(btn, t(reg ? 'auth.submit.reg' : 'auth.submit.login')); ui.avail(btn, ''); }
      btn.classList.toggle('is-busy', busy); if (busy) btn.setAttribute('aria-busy', 'true'); else btn.removeAttribute('aria-busy');
      email.readOnly = busy; pw.readOnly = busy; pw2.readOnly = busy;
    }
    function setWait(sec) {
      clearInterval(timer); wait = Math.max(0, Math.ceil(+sec || 0)); paint();
      if (wait > 0) timer = setInterval(function () { wait--; if (wait <= 0) { clearInterval(timer); setErr(null); } paint(); }, 1000);
    }
    /* 错误: {key, vars, text, act:{label key, fn}} — 切换语言后用 key 重新生成文字 */
    function setErr(e) { errState = e; renderErr(); }
    function renderErr() {
      var e = errState;
      TP.setText(errTxt, e ? (e.text != null ? e.text : t(e.key, e.vars)) : '');
      errAct = e && e.act ? e.act : null; errBtn.hidden = !errAct;
      if (errAct) ui.setBtn(errBtn, t(errAct.label), errAct.icon || 'refresh');
      err.classList.toggle('on', !!e);
    }
    function setMsg(text) { curMsg = text || ''; TP.setText(msgEl, String(curMsg)); msgEl.hidden = !curMsg; }
    function renderNotice() {
      var n = A.status && A.status.notice ? String(A.status.notice) : '';
      noticeEl.hidden = !n; TP.setText(noticeEl.lastChild, n);
    }
    function renderNote() {                                                // 当前模式的文字: 标题 / 副标题 / 切换链接 / 说明 / 上次账号
      var reg = mode === 'register';
      renderNotice(); setMsg(curMsg);
      if (dm) dm.setTitle(t(reg ? 'auth.page.reg' : 'auth.page.login'));
      TP.setText(subEl, t(reg ? 'auth.page.regSub' : 'auth.page.loginSub'));
      TP.setText(swQ, t(reg ? 'auth.hasAcct' : 'auth.noAcct')); TP.setText(swA, t(reg ? 'auth.toLogin' : 'auth.toReg'));
      TP.setText(note.lastChild, t(reg ? 'auth.note.register' : 'auth.note.login'));
      last.hidden = !(mode === 'login' && A.hint); TP.setText(last.lastChild, A.hint ? t('auth.last', { hint: A.hint }) : '');
    }
    function setMode(m) {
      mode = m === 'register' ? 'register' : 'login';
      var reg = mode === 'register';
      fPw2.hidden = !reg; pwMin.hidden = !reg;
      pw.setAttribute('autocomplete', reg ? 'new-password' : 'current-password');
      setErr(null); pw.value = ''; pw2.value = ''; renderNote(); paint();
      if (dm) { try { (reg || !email.value ? email : pw).focus(); } catch (e) { /* 忽略 */ } }
    }

    function fail(e) {
      var code = e && e.code, d = (e && e.data) || {}, reg = mode === 'register';
      var retry = { label: 'auth.retry', icon: 'refresh', fn: function () { if (pw.value) submit(); else pw.focus(); } };
      if (e.kind === 'unreachable') setErr({ key: 'auth.unreachable', act: retry });
      else if (code === 'E_EMAIL_TAKEN') setErr({ key: 'auth.err.taken', act: { label: 'auth.goLogin', icon: 'lock', fn: function () { var keep = email.value; setMode('login'); email.value = keep; pw.focus(); } } });
      else if (code === 'E_WEAK_PASSWORD') { setErr({ key: 'auth.err.weak' }); pw.focus(); }
      else if (code === 'E_ACCOUNT_UNREACHABLE') setErr({ key: reg ? 'auth.err.unreachableReg' : 'auth.err.unreachableAcct', act: retry });
      else if (code && I.has('error.' + code)) setErr({ key: 'error.' + code });
      else setErr({ text: TP.errMsg(e) });
      if (code === 'E_LOCKED' && +d.wait > 0) setWait(d.wait);
      return e.kind === 'unreachable' || code === 'E_ACCOUNT_UNREACHABLE';     // 只是网络问题: 保留已输入的密码, 方便点「重试」
    }
    async function submit(ev) {
      if (ev) ev.preventDefault();
      if (btn._un) { ui.unavailable(btn); return; }
      var reg = mode === 'register', u = email.value.trim(), p = pw.value;
      if (!u) { setErr({ key: 'auth.needEmail' }); email.focus(); return; }
      if (!/^[^\s@]+@[^\s@]+$/.test(u)) { setErr({ key: 'auth.badEmail' }); email.focus(); return; }
      if (!p) { setErr({ key: 'auth.needPw' }); pw.focus(); return; }
      if (reg) {
        if (p.length < 8) { setErr({ key: 'auth.err.weak' }); pw.focus(); return; }
        if (p.length > 128) { setErr({ key: 'auth.err.long' }); pw.focus(); return; }
        if (p !== pw2.value) { setErr({ key: 'auth.err.mismatchPw' }); pw2.focus(); return; }
      }
      TP.ls.set('login.email', u);                                   // 只记邮箱
      busy = true; setErr(null); paint();
      try {
        var r = await TP.helper('POST', reg ? '/api/register' : '/api/login', { form: { user: u, password: p }, noAuth: true, timeout: 25000 });
        if (!r || !r.token) throw TP.mkErr('api', t('auth.noToken'));
        p = ''; busy = false; finish(r, u, reg);
        return;
      } catch (e) {
        if (!reg && e && e.code === 'E_DEVICE_LIMIT') {                           // 本平台已有 2 台设备在线: 让用户选一台下线, 然后用同样的账号密码 + kick 重新登录
          pending = { user: u, password: p }; pw.value = ''; p = '';
          busy = false; paint(); setErr(null); openDevices(e.data || {});
          return;
        }
        if (!fail(e)) { pw.value = ''; pw2.value = ''; }
        p = ''; if (!errState || !errState.act) pw.focus();
      }
      busy = false; paint();
    }
    /* 登录 / 注册成功之后的收尾 (正常登录、带 kick 的重新登录共用): 本机令牌和原来一样 (照样记下, 没有令牌时也就连上了), 仪表盘留在当前页 */
    function finish(r, u, reg) {
      pw.value = ''; pw2.value = ''; wipePending();
      TP.setToken(r.token); A.account = r.account ? String(r.account) : u; A.hint = '';
      TP.ls.del('authNotice');
      clearInterval(timer);
      okDone = true; if (dm) dm.close('ok');
      if (S.locked) unlock();
      setLoggedIn(true, true);
      TP.emit('login', { registered: reg });
      if (reg) ui.toast(t('auth.registered', { account: A.account }), 'ok', 6000);
      else if (r.via === 'offline') ui.toast(t('auth.offlineLogin'), 'warn', 5200);
      else ui.toast(t('auth.signedIn'), 'ok', 2200);
      if (TP.loadState) TP.loadState();
    }
    /* 设备已满: 弹窗列出在线设备, 每台一个「下线此设备」(先二次确认), 确认后带 kick=<uid> 重新提交同一次登录 */
    function openDevices(data) {
      var devs = Array.isArray(data.devices) ? data.devices.slice() : [], limit = +data.limit || 2, plat = platName(data.platform), busyUid = '';
      var list = h('div', { class: 'devs' }), derr = h('div', { class: 'login-err' }), derrT = h('span'); derr.appendChild(derrT);
      function setDErr(msg) { TP.setText(derrT, msg || ''); derr.classList.toggle('on', !!msg); }
      var ddm = null;
      function draw() {
        TP.clear(list);
        devs.forEach(function (d) {
          var b = ui.btn(busyUid === d.uid ? t('auth.dev.kicking') : t('auth.dev.kick'), { sm: true, kind: 'danger', icon: 'logout' });
          if (busyUid) ui.avail(b, busyUid === d.uid ? t('auth.dev.kicking') : t('auth.dev.busyOther'));
          b.classList.toggle('is-busy', busyUid === d.uid);
          ui.act(b, function () { return kick(d); });
          list.appendChild(A.deviceRow(d, b));
        });
        if (!devs.length) list.appendChild(h('p', { class: 'muted' }, t('auth.dev.none')));
      }
      async function kick(d) {
        if (busyUid || !pending) return;
        var ok = await A.confirmKick(d, true);
        if (!ok || !pending) return;
        busyUid = d.uid; setDErr(''); draw(); ddm.setBusy(true);
        try {
          var r = await TP.helper('POST', '/api/login', { form: { user: pending.user, password: pending.password, kick: d.uid }, noAuth: true, timeout: 25000 });
          if (!r || !r.token) throw TP.mkErr('api', t('auth.noToken'));
          ddm.setBusy(false); ddm.close('ok'); finish(r, pending ? pending.user : '', false);
          return;
        } catch (e) {
          ddm.setBusy(false); busyUid = '';
          if (e && e.code === 'E_DEVICE_LIMIT' && e.data) { devs = Array.isArray(e.data.devices) ? e.data.devices.slice() : devs; setDErr(t('auth.dev.again')); }
          else if (e && e.kind === 'unreachable') setDErr(t('auth.unreachable'));
          else setDErr(TP.errMsg(e));
          draw();
        }
      }
      ddm = ui.modal({
        title: t('auth.dev.title', { platform: plat, limit: limit, n: limit }), icon: 'risk', iconKind: 'bad', size: 'md', cls: 'devdlg',
        lock: function () { return !!busyUid; },
        onClose: function (v) { if (v !== 'ok') wipePending(); },
        body: h('div', null, h('p', { class: 'cfm-m' }, t('auth.dev.intro', { limit: limit, n: limit }), ui.help('settings.devices')), list, derr),
        actions: [{ label: t('common.cancel'), cancel: true }]
      });
      draw();
    }
    form.addEventListener('submit', submit);
    errBtn.addEventListener('click', function () { if (busy || !errAct) return; errAct.fn(); });
    swA.addEventListener('click', function () { if (!busy) setMode(mode === 'register' ? 'login' : 'register'); });
    function repaint() { paint(); renderErr(); renderNote(); }        // 切换语言 / 状态变了之后重新生成文字

    dm = ui.modal({
      title: t(mode === 'register' ? 'auth.page.reg' : 'auth.page.login'), icon: 'account', size: 'sm', cls: 'authdlg',
      body: h('div', { class: 'ap-body' }, subEl, msgEl, noticeEl, last, form, h('p', { class: 'ap-switch' }, swQ, swA), note),
      lock: function () { return busy; },                           // 正在向 enana.cc 校验时不能关
      onClose: function () { clearInterval(timer); pw.value = ''; pw2.value = ''; wipePending(); login = null; resolveDone(okDone); },
      actions: []                                                    // 提交按钮在表单里; 关闭用右上角的 ✕ / ESC
    });
    login = { setMode: setMode, setMsg: setMsg, repaint: repaint, done: done };
    setMode(mode);
    if (wait > 0) setWait(wait);
    /* 对话框已经显示; 悄悄刷新一次状态 (限流剩余时间 / 上次账号提示 / notice 可能变了) */
    refreshStatus().then(function () { if (login && login.repaint === repaint) { renderNote(); if (+(A.status && A.status.wait) > 0 && wait <= 0) setWait(A.status.wait); } });
    return done;
  }

  /* ================= 退出账号 (POST /api/logout) =================
   * 本机令牌不变、代理设置保留 (代理照常使用你自己的服务器); 官方线路、云端同步和会员停止; 仪表盘留在当前页。
   * kind 'switch' = 退出后马上打开登录框 (会员页「重新登录」用它: 云端会话失效时先退出再登录)。 */
  A.logout = async function (kind) {
    var sw = kind === 'switch', who = A.label();
    var why = TP.why.helper();
    if (why) { ui.toast(why, 'warn'); return; }
    if (!A.signedIn()) { if (sw) A.openLogin({ mode: 'login' }); return; }
    var ok = await ui.confirmDialog({
      title: t(sw ? 'auth.switch.title' : 'auth.logout.title'), message: t(sw ? 'auth.switch.msg' : 'auth.logout.msg', { who: who }),
      detail: [t('auth.logout.keep1'), t('auth.logout.keep2'), t('auth.logout.d2'), t('auth.logout.keep3')],
      confirmText: t(sw ? 'auth.switch.go' : 'auth.logout.go'), danger: true, confirmIcon: 'logout'
    });
    if (!ok) return;
    var card = ui.taskCard(t(sw ? 'auth.switch.running' : 'auth.logout.running')), busy = true;
    var m = ui.modal({ title: t(sw ? 'auth.switch.title' : 'auth.logout.title'), icon: 'logout', size: 'sm', static: true, lock: function () { return busy; }, body: card.el, actions: [] });
    m.setBusy(true); card.set({ pct: null, msg: t('job.submitting') });
    try {
      await TP.helper('POST', '/api/logout', { timeout: 20000, quiet: true });
    } catch (e) {
      if (!(e && e.code === 'E_LOGIN_REQUIRED')) {                  // 已经不在登录状态 (例如刚被其它设备下线) 也算退出成功
        busy = false; m.setBusy(false);
        card.fail(TP.errMsg(e)); m.setActions([{ label: t('common.close'), kind: 'primary', cancel: true }]);
        ui.toast(t('auth.logout.failed', { reason: TP.errMsg(e) }), 'err');
        return;
      }
    }
    busy = false; m.setBusy(false); m.close('done');
    A.account = '';
    if (S.state && S.state.account) S.state.account.email = '';
    setLoggedIn(false, true);
    ui.toast(t('auth.signedOut'), 'ok', 4200);
    if (TP.loadState) TP.loadState();
    if (sw) A.openLogin({ mode: 'login', reason: A.msg('auth.switched') });
  };

  /* ================= 敏感操作: 再次验证 (step-up) =================
   * 登录了 enana 账号: 后端有一张白名单, 里面的接口没带有效的 X-Enana-Sudo 时返回 403 E_SUDO_REQUIRED; TP.helper 捕获它 -> TP.sudo.ask() 弹出密码框 -> POST /api/auth/verify
   *   -> 拿到 sudo 令牌 (5 分钟有效) -> 带着 X-Enana-Sudo 重试原请求。
   *   令牌在内存里, 另外 {token, exp} 记在这个标签页的 sessionStorage (和本机令牌一样, 关闭标签页就没了; 绝不写 localStorage): 刷新页面后到期之前不用再输入密码。
   *   读不到 / 写不进 sessionStorage (隐私模式、禁用存储) 时只在内存里, 和以前一样。
   *   退出账号 / 被下线 (account=false) / 和本机服务的连接失效 (auth=false) 以及后端说令牌不能用了 (403 E_SUDO_REQUIRED, core.js 调 sudo.clear) 时, 内存和 sessionStorage 里的一起丢弃。
   * 没有登录: 后端不要求密码 (没有账号可以验证), 白名单里的操作在发出之前弹「恰好一次」确认 (TP.sudo.guestOk, core.js 的 TP.helper 调用);
   *   自己已经确认过的调用方传 confirmed:true; 没有小锁图标 (CSS: html[data-acct=guest] .sudo-l)。
   * 白名单在后端; 这里的 PATHS 用来「提前带上令牌」、显示小锁图标和没登录时的确认 (登录时多一个少一个都不影响正确性: 漏掉的会走 403 → 弹框流程)。 */
  var sudo = TP.sudo = { tok: '', exp: 0 }, sudoDlg = null;
  var SUDO_PATHS = ['/api/servers/delete', '/api/sub/delete', '/api/servers/secret', '/api/sub/url', '/api/logs/clear', '/api/devices/kick', '/api/sync/clear', '/api/export', '/api/billing/purchase', '/api/billing/auto-renew'];
  var SELF_CONFIRMED = ['/api/logs/clear'];                           // 唯一的调用方 (ui/v-logs.js 的「清除日志」) 发出之前总是先问两次 (选范围 + 危险确认): 没登录时不再加第三次
  var SUDO_KEY = 'sudo', SUDO_MAX_MS = 3600000;                       // sessionStorage 键 (实际是 enana.sudo); 恢复时到期时间最多在一小时以后 (后端只发 5 分钟的令牌, 再远就是改过的 / 时钟跳过的, 不用)
  sudo.PATHS = SUDO_PATHS;
  sudo.valid = function () { return !!sudo.tok && Date.now() < sudo.exp; };
  sudo.token = function () { if (sudo.tok && !sudo.valid()) sudo.clear(); return sudo.valid() ? sudo.tok : ''; };      // 过期了顺便把 sessionStorage 里的也清掉
  sudo.forPath = function (path) { return SUDO_PATHS.indexOf(path) >= 0; };
  sudo.clear = function () { sudo.tok = ''; sudo.exp = 0; TP.ss.del(SUDO_KEY); };
  /* 没有登录时的一次确认: 不用问 -> true (同步返回); 要问 -> Promise<是否继续>。登录了 (或者调用方已经确认过 / 不是白名单里的接口) 都不问 */
  sudo.guestOk = function (method, path, o) {
    if (A.signedIn() || !sudo.forPath(path) || (o && o.confirmed) || SELF_CONFIRMED.indexOf(path) >= 0) return true;
    return ui.confirmDialog({ title: t('sudo.guest.title'), message: (o && o.sudoWhy) || t('sudo.guest.msg'), detail: [t('sudo.guest.note')], confirmText: t('sudo.guest.go'), kind: 'warning', confirmIcon: 'check' });
  };
  /* 验证通过: ttl = 后端给的有效秒数 (提前 5 秒当作过期, 免得刚好在路上过期) */
  sudo.keep = function (tok, ttl) {
    sudo.tok = String(tok); sudo.exp = Date.now() + Math.max(10, (+ttl || 300) - 5) * 1000;
    TP.ss.set(SUDO_KEY, { token: sudo.tok, exp: sudo.exp });
  };
  /* 页面刷新后: 这个标签页里还没过期的令牌接着用。没有本机令牌 / 已经过期 / 格式不对 (要能放进请求头) / 读不出来的直接删掉 */
  (function restoreSudo() {
    var v = TP.ss.get(SUDO_KEY, null), now = Date.now();
    if (v && typeof v === 'object' && typeof v.token === 'string' && /^[\x21-\x7e]{1,256}$/.test(v.token) && +v.exp > now && +v.exp - now <= SUDO_MAX_MS && TP.getToken()) { sudo.tok = v.token; sudo.exp = +v.exp; }
    else TP.ss.del(SUDO_KEY);
  })();
  TP.on('auth', function (ok) { if (!ok) sudo.clear(); });
  TP.on('account', function (on) { if (!on) sudo.clear(); });
  /* 小锁图标: 放在需要再次验证的按钮 / 链接旁边 (title 和 aria-label 跟随语言; 没有登录时 CSS 把它藏起来) */
  sudo.icon = function () { return h('span', { class: 'sudo-l', role: 'img', title: L('sudo.lockTip'), 'aria-label': L('sudo.lockTip') }, ui.icon('lock', 13)); };
  sudo.mark = function (btn) { btn.classList.add('has-sudo'); btn.appendChild(sudo.icon()); return btn; };
  /* 弹出「请输入登录密码以继续」; 返回 Promise<令牌 | ''> (同一时间只有一个对话框, 并发请求共用) */
  sudo.ask = function (why) {
    if (sudoDlg) return sudoDlg;
    var resolve, done = false, dm = null, busy = false;
    sudoDlg = new Promise(function (r) { resolve = r; });
    var pw = h('input', { class: 'inp', type: 'password', name: 'sudo-password', autocomplete: 'current-password', spellcheck: 'false', 'aria-label': L('sudo.password') });
    var eye = ui.ibtn('eye', L('auth.showPw'), { size: 18 }); eye.classList.add('pw-eye'); eye.setAttribute('aria-pressed', 'false');
    eye.addEventListener('click', function () {
      var show = pw.type === 'password'; pw.type = show ? 'text' : 'password'; eye.setAttribute('aria-pressed', show ? 'true' : 'false');
      var lab = t(show ? 'auth.hidePw' : 'auth.showPw'); eye.setAttribute('aria-label', lab); eye.title = lab; eye._tip = lab;
      eye.replaceChild(ui.icon(show ? 'eye-off' : 'eye', 18, 'bi'), eye.firstChild); pw.focus();
    });
    var errTxt = h('span'), err = h('div', { class: 'login-err', role: 'alert' }, errTxt);
    function setErr(m) { TP.setText(errTxt, m || ''); err.classList.toggle('on', !!m); }
    var form = h('form', { class: 'sudo-form', novalidate: true },
      h('p', { class: 'cfm-m' }, L('sudo.intro'), ui.help('settings.sudo')), why ? h('p', { class: 'muted sm' }, why) : null,
      ui.field(L('sudo.password'), h('span', { class: 'pw' }, pw, eye)), err,
      h('p', { class: 'hint sudo-ttl' }, ui.icon('clock', 14, 'ci'), h('span', null, L('sudo.ttl'))));
    async function go(api, btn) {
      if (busy) return false;
      var v = pw.value; if (!v) { setErr(t('sudo.need')); pw.focus(); return false; }
      busy = true; setErr(''); api.setBusy(true);
      try {
        var r = await TP.helper('POST', '/api/auth/verify', { form: { password: v }, timeout: 20000, noSudo: true });
        if (!r || !r.sudo) throw TP.mkErr('api', t('sudo.err.none'));
        sudo.keep(r.sudo, r.ttl);
        pw.value = ''; done = true; api.close('ok');
      } catch (e) {
        if (e && (e.kind === 'auth' || e.code === 'E_LOGIN_REQUIRED')) { done = true; api.close('auth'); return false; }      // 和本机服务的连接失效 / 刚刚退出了账号: 关掉 (登录框会另外弹出)
        var d = (e && e.data) || {};
        if (e && e.code === 'E_BAD_CREDENTIALS') setErr(t('sudo.err.bad'));
        else if (e && e.code === 'E_LOCKED') setErr(t('sudo.err.locked', { n: Math.ceil(+d.wait || 0) }));
        else if (e && e.kind === 'unreachable') setErr(t('auth.unreachable'));
        else setErr(TP.errMsg(e));
        pw.select(); pw.focus();
      }
      busy = false; api.setBusy(false);
      return false;
    }
    form.addEventListener('submit', function (ev) { ev.preventDefault(); if (dm) go(dm); });
    dm = ui.modal({
      title: t('sudo.title'), icon: 'lock', size: 'sm', body: form, lock: function () { return busy; },
      onClose: function (v) { sudoDlg = null; pw.value = ''; resolve(done && v === 'ok' ? sudo.token() : ''); },
      actions: [{ label: t('common.cancel'), cancel: true }, { label: t('sudo.go'), kind: 'primary', icon: 'check', id: 'go', keep: true, onClick: go }]
    });
    setTimeout(function () { try { pw.focus(); } catch (e) { /* 忽略 */ } }, 60);
    return sudoDlg;
  };

  /* ================= 修改登录密码 (设置 → 账号与设备): 旧密码 / 新密码 / 确认, 强度提示, POST /api/password (不需要 sudo) =================
   * 成功后当前设备保持登录, 账号下其它设备全部被退出登录 (说明给用户看)。密码只在内存里, 关闭 / 成功后立即清空。 */
  function pwStrength(p) {
    if (!p) return { n: 0, key: '' };
    if (p.length < 8) return { n: 1, key: 'short' };
    var cls = (/[a-z]/.test(p) ? 1 : 0) + (/[A-Z]/.test(p) ? 1 : 0) + (/[0-9]/.test(p) ? 1 : 0) + (/[^A-Za-z0-9]/.test(p) ? 1 : 0);
    var sc = (p.length >= 14 ? 2 : p.length >= 10 ? 1 : 0) + (cls >= 3 ? 1 : 0) + (cls >= 4 ? 1 : 0);
    return sc <= 0 ? { n: 2, key: 'weak' } : sc === 1 ? { n: 3, key: 'fair' } : sc === 2 ? { n: 4, key: 'good' } : { n: 5, key: 'strong' };
  }
  A.changePassword = function () {
    var why = TP.why.helper(); if (why) { ui.toast(why, 'warn'); return Promise.resolve(); }
    var dm = null, busy = false;
    function field(label, ac, name) {
      var inp = h('input', { class: 'inp', type: 'password', name: name, autocomplete: ac, spellcheck: 'false', 'aria-label': label });
      var eye = ui.ibtn('eye', L('auth.showPw'), { size: 18 }); eye.classList.add('pw-eye'); eye.setAttribute('aria-pressed', 'false');
      eye.addEventListener('click', function () {
        var show = inp.type === 'password'; inp.type = show ? 'text' : 'password'; eye.setAttribute('aria-pressed', show ? 'true' : 'false');
        var lab = t(show ? 'auth.hidePw' : 'auth.showPw'); eye.setAttribute('aria-label', lab); eye.title = lab; eye._tip = lab;
        eye.replaceChild(ui.icon(show ? 'eye-off' : 'eye', 18, 'bi'), eye.firstChild); inp.focus();
      });
      var err = h('span', { class: 'fld-h bad-t', hidden: true });
      return { inp: inp, err: err, box: h('div', { class: 'fld' }, h('span', { class: 'fld-l' }, label), h('span', { class: 'pw' }, inp, eye), err) };
    }
    var fOld = field(t('pw.old'), 'current-password', 'old-password'), fNew = field(t('pw.new'), 'new-password', 'new-password'), fCf = field(t('pw.confirm'), 'new-password', 'confirm-password');
    var meter = ui.bar(), mTxt = h('span', { class: 'muted sm' }), gErr = h('div', { class: 'login-err', role: 'alert' }, h('span'));
    function setErr(f, m) { f.err.hidden = !m; TP.setText(f.err, m || ''); f.inp.setAttribute('aria-invalid', m ? 'true' : 'false'); }
    function setG(m) { TP.setText(gErr.firstChild, m || ''); gErr.classList.toggle('on', !!m); }
    function paintMeter() {
      var st = pwStrength(fNew.inp.value);
      meter.set(st.n ? st.n * 20 : 0, st.n >= 4 ? 'ok' : st.n >= 3 ? '' : st.n ? 'err' : '');
      TP.setText(mTxt, st.key ? t('pw.s.' + st.key) : t('pw.hint'));
    }
    fNew.inp.addEventListener('input', function () { setErr(fNew, ''); paintMeter(); });
    fOld.inp.addEventListener('input', function () { setErr(fOld, ''); setG(''); }); fCf.inp.addEventListener('input', function () { setErr(fCf, ''); });
    paintMeter();
    var body = h('form', { class: 'pw-form', novalidate: true }, h('p', { class: 'cfm-m' }, L('pw.intro')), fOld.box, fNew.box, h('div', { class: 'pw-meter' }, meter.el, mTxt), fCf.box, gErr,
      h('p', { class: 'hint' }, ui.icon('info', 14, 'ci'), h('span', null, L('pw.note'))));
    function wipe() { fOld.inp.value = ''; fNew.inp.value = ''; fCf.inp.value = ''; }
    async function go(api) {
      if (busy) return false;
      var o = fOld.inp.value, n = fNew.inp.value, c = fCf.inp.value, bad = false;
      setG('');
      if (!o) { setErr(fOld, t('pw.err.old')); bad = true; }
      if (n.length < 8) { setErr(fNew, t('pw.err.short')); bad = true; } else if (n.length > 128) { setErr(fNew, t('auth.err.long')); bad = true; } else if (n === o) { setErr(fNew, t('pw.err.same')); bad = true; }
      if (!bad && c !== n) { setErr(fCf, t('pw.err.mismatch')); bad = true; }
      if (bad) { (fOld.inp.value ? (fNew.err.hidden ? fCf.inp : fNew.inp) : fOld.inp).focus(); return false; }
      var ok = await ui.confirmDialog({ title: t('pw.cf.title'), message: t('pw.cf.msg'), detail: [t('pw.cf.d1'), t('pw.cf.d2'), t('pw.cf.d3')], confirmText: t('pw.cf.go'), kind: 'warning', confirmIcon: 'password' });
      if (!ok) return false;
      busy = true; api.setBusy(true);
      try {
        await TP.helper('POST', '/api/password', { form: { old: o, 'new': n }, timeout: 25000, noSudo: true });
        wipe(); busy = false; api.setBusy(false); api.close('ok');
        ui.modal({ title: t('pw.done.title'), icon: 'success', iconKind: 'ok', size: 'sm', body: h('div', null, h('p', { class: 'cfm-m' }, t('pw.done.msg')), h('p', { class: 'muted sm' }, t('pw.done.other'))), actions: [{ label: t('help.gotIt'), kind: 'primary', icon: 'check', autofocus: true }] });
        return false;
      } catch (e) {
        var d = (e && e.data) || {};
        if (e && (e.kind === 'auth' || e.code === 'E_LOGIN_REQUIRED')) { busy = false; api.setBusy(false); api.close('auth'); return false; }      // 和本机服务的连接失效 / 已经不在登录状态 (登录框会另外弹出)
        if (e && e.code === 'E_BAD_CREDENTIALS') { setErr(fOld, t('pw.err.bad')); fOld.inp.select(); fOld.inp.focus(); }
        else if (e && e.code === 'E_WEAK_PASSWORD') { setErr(fNew, t('pw.err.weak')); fNew.inp.focus(); }
        else if (e && e.code === 'E_LOCKED') setG(t('sudo.err.locked', { n: Math.ceil(+d.wait || 0) }));
        else if (e && e.code === 'E_ACCOUNT_UNREACHABLE') setG(t('pw.err.offline'));
        else if (e && e.kind === 'unreachable') setG(t('auth.unreachable'));
        else setG(TP.errMsg(e));
      }
      busy = false; api.setBusy(false);
      return false;
    }
    body.addEventListener('submit', function (ev) { ev.preventDefault(); if (dm) go(dm); });
    dm = ui.modal({
      title: t('pw.title'), icon: 'password', size: 'sm', body: body, lock: function () { return busy; },
      dirty: function () { return !!(fOld.inp.value || fNew.inp.value || fCf.inp.value); }, onClose: wipe,
      actions: [{ label: t('common.cancel'), cancel: true }, { label: t('pw.go'), kind: 'primary', icon: 'check', keep: true, onClick: go }]
    });
    setTimeout(function () { try { fOld.inp.focus(); } catch (e) { /* 忽略 */ } }, 60);
    return dm.closed;
  };
})();
