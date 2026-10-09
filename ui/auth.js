/* enana · auth.js — 登录 / 注册 (enana.cc 账号: 邮箱 + 密码)
 * 流程: GET /api/auth/status (公开) -> 没有有效令牌就显示全屏登录框 (登录 | 注册 两个标签, 同一个弹窗)
 *   -> POST /api/login 或 /api/register (urlencoded user= password=, 辅助服务要向 enana.cc 校验, 超时 25 秒)
 *   -> 令牌只放 sessionStorage; 之后辅助服务请求带 X-Enana-Token, Clash API 请求带 Authorization: Bearer; 任何 401 -> 清除令牌并重新显示登录框 (界面状态保留)。
 * 本机不保存、不生成任何管理员密码; 暂不支持找回密码。「退出账号 / 切换账号」= POST /api/logout (会自动关闭代理、让所有浏览器退出)。
 * 最近输入的邮箱会记在 localStorage (只记邮箱, 绝不记密码)。无操作超过 TP.lockIdleMin() 分钟 (设置里可改, 默认 3 天) 自动锁定。 */
(function () {
  'use strict';
  var TP = window.TP, S = TP.S, h = TP.h, ui = TP.ui, I = window.I18N, t = I.t, L = I.L;
  var A = TP.auth = { account: '', hint: '', required: true, expectMsg: '', status: null };
  var lastActive = Date.now(), login = null;
  var firstPage = (/^(.*\/)([^/]*)$/.exec(location.pathname) || [])[2] === 'register' ? 'register' : 'login';      // 打开的地址是 …/register 就先显示注册页 (在 app.js 把地址改成当前页之前记下来)
  /* 登录页顶部的提示: 带词典键的对象, 切换语言后会按新语言重新生成文字 (String(x) 取当前语言的文字) */
  A.msg = function (key, vars) { return { key: key, vars: vars || null, toString: function () { return t(key, vars); } }; };
  /* 分钟数 → 文字 (例如 4320 → 「3 天」, 60 → 「1 小时」, 15 → 「15 分钟」), 按当前语言 */
  A.idleLabel = function (min) {
    var kind = min % 1440 === 0 ? 'day' : min % 60 === 0 ? 'hour' : 'min', n = kind === 'day' ? min / 1440 : kind === 'hour' ? min / 60 : min;
    return t('dur.' + kind + (n === 1 && kind !== 'min' ? '1' : ''), { n: n });
  };
  var DEF = { account_url: 'https://enana.cc' };      // 官网只有一个首页: 注册 / 登录 / 改密码 / 设备管理都在仪表盘里完成

  /* 来自辅助服务的链接只接受 https:// ; 否则用默认地址 */
  function urlOf(k) { var u = A.status && A.status[k]; return /^https:\/\//i.test(String(u || '')) ? String(u) : DEF[k]; }
  A.url = urlOf;
  A.openUrl = function (k) { try { window.open(urlOf(k), '_blank', 'noopener,noreferrer'); } catch (e) { /* 弹窗被拦截: 忽略 */ } };
  /* 当前登录的邮箱: 登录结果 > /api/state 的 account.email > /api/settings 的 account.email */
  A.email = function () {
    var a = A.account || (S.state && S.state.account && S.state.account.email) || (S.prefs && S.prefs.account && S.prefs.account.email) || '';
    return a ? String(a) : '';
  };
  A.label = function () { return A.email() || A.hint || t('auth.account'); };

  /* ---------- 无操作自动锁定 ---------- */
  A.touch = function () { lastActive = Date.now(); };
  ['pointerdown', 'keydown', 'wheel', 'touchstart'].forEach(function (ev) { document.addEventListener(ev, A.touch, { passive: true, capture: true }); });
  setInterval(function () {
    var idle = TP.lockIdleMin();
    if (!S.locked && A.required && Date.now() - lastActive > idle * 60000) A.lock(A.msg('auth.autoLock', { n: A.idleLabel(idle) }));
  }, 15000);

  function unlock(relogin) {
    S.locked = false; lastActive = Date.now();
    TP.emit('auth', true);
    if (relogin) ui.toast(t('auth.signedIn'), 'ok', 2200);
  }

  /* ---------- 启动: 读取状态, 决定要不要登录 ---------- */
  function ready() { document.documentElement.classList.add('ui-ready'); }       // 显示页面外壳 (boot.js 在登录状态确定之前把它藏起来)
  A.start = async function () {
    if (!TP.getToken()) A.lock(''); else ready();                  // 没有令牌: 马上显示登录页 / 注册页, 不等状态请求 (不会先闪一下仪表盘); 有令牌: 直接显示仪表盘
    try {
      var st = await TP.helper('GET', '/api/auth/status', { noAuth: true, timeout: 6000 });
      if (st && typeof st === 'object') {
        A.status = st; A.hint = st.account_hint ? String(st.account_hint) : '';
        if (st.required === false) A.required = false;
      }
    } catch (e) { /* 辅助服务暂时连不上: 仍然显示登录框, 提交时会给出原因 */ }
    if (!A.required || TP.getToken()) {                             // 令牌如果已失效, 第一个请求会 401 并重新弹出登录框
      if (login) { var cur = login; login = null; cur.close('ok'); }  // 不需要登录 (开发用的模拟服务): 收起已经显示的登录页
      unlock(false); ready(); return;
    }
    if (!login) A.lock('');
    ready();
  };
  /* 重新读取公开状态 (登录框显示后悄悄刷新: 限流剩余时间、上次账号提示) */
  async function refreshStatus() {
    try { var st = await TP.helper('GET', '/api/auth/status', { noAuth: true, timeout: 6000 }); if (st && typeof st === 'object') { A.status = st; A.hint = st.account_hint ? String(st.account_hint) : A.hint; } } catch (e) { /* 忽略 */ }
  }

  A.lock = function (msg, opt) {
    S.locked = true; TP.setToken(''); ui.clearSkipFlags();
    TP.emit('auth', false);
    opt = opt || {};
    if (login) { login.setMsg(msg || ''); if (opt.noPrefill) login.clearEmail(); return; }
    showLogin(msg || '', opt);
  };
  A.expire = function (msg) {
    if (A._exp || (S.locked && login)) return;
    var m = A.expectMsg || msg || A.msg('auth.expired'), o = A.expectOpt || {}, plain = !A.expectMsg && !msg;
    A.expectMsg = ''; A.expectOpt = null;
    A._exp = true; S.locked = true;                                  // 立刻停掉轮询; 先重新读一次 /api/auth/status (被其它设备下线时里面有 notice), 再显示登录框
    refreshStatus().then(function () { A._exp = false; A.lock(plain && A.status && A.status.notice ? '' : m, o); });     // 有后端给的说明 (例如被其它设备下线) 时, 不再重复显示「登录已过期」
  };
  TP.on('unauth', function () { A.expire(); });

  function langName() { var a = I.available.filter(function (x) { return x.code === I.lang; })[0]; return a ? a.name : I.lang; }
  I.onChange(function () { if (login && A._repaint) A._repaint(); });

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

  /* ---------- 登录 / 注册: 两个独立的整页 (地址 …/login 与 …/register), 用页面里的链接互相跳转, 不是标签 ----------
   * 页面结构: 右上角语言切换 · 居中的卡片 (标题 + 副标题 / 分隔线 / 表单 / 「还没有账号? 立即注册」) · 卡片下的说明 · 最底部 enana 官网链接和版权。
   * 登录成功后回到锁定之前所在的页面 (A.returnTo)。 */
  var ROUTE = (/^(.*\/)([^/]*)$/.exec(location.pathname) || [0, '/'])[1];            // 后台地址 (和 app.js 里的 ROUTE_BASE 一样)
  function pageFromUrl() { var m = /^(.*\/)([^/]*)$/.exec(location.pathname); return m && m[2] === 'register' ? 'register' : 'login'; }
  function setUrl(mode, push) {
    try { var want = ROUTE + mode; if (location.pathname !== want || location.hash) history[push ? 'pushState' : 'replaceState'](null, '', want + location.search); } catch (e) { /* 忽略 */ }
  }
  function openPage(content) {                                                         // 整页的 <dialog>: 背景不可操作, 焦点锁定在页面里, ESC 关不掉
    var dlg = h('dialog', { class: 'authpage login' }, content);
    dlg.addEventListener('cancel', function (e) { e.preventDefault(); });
    document.body.appendChild(dlg); if (dlg.showModal) dlg.showModal(); else dlg.setAttribute('open', '');
    ui.hostFloaters();
    return {
      el: dlg, setLabel: function (v) { dlg.setAttribute('aria-label', v); },
      close: function () {
        try { if (dlg.open) dlg.close(); } catch (e) { /* 忽略 */ }
        var f = TP.byId('floaters'); if (f && dlg.contains(f)) document.body.appendChild(f);
        if (dlg.parentNode) dlg.parentNode.removeChild(dlg);
        ui.hostFloaters();
      }
    };
  }
  function showLogin(msg, opt) {
    var st = A.status || {}, mode = firstPage, api = null;
    firstPage = 'login';
    if (TP.tab) A.returnTo = TP.tab;                                      // 登录后回到这一页
    var email = h('input', { id: 'ap-email', type: 'text', name: 'username', inputmode: 'email', autocomplete: 'username', autocapitalize: 'off', spellcheck: 'false', placeholder: L('auth.ph.email'), value: opt.noPrefill ? '' : TP.ls.get('login.email', '') });
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
    var titleEl = h('h1', { class: 'ap-t' }), subEl = h('p', { class: 'ap-sub' });
    var swQ = h('span'), swA = h('a', { class: 'ap-sw', href: ROUTE + 'register' });
    var site = h('a', { class: 'ap-site', href: A.url('account_url'), target: '_blank', rel: 'noopener noreferrer' }, ui.icon('globe', 15, 'ci'), h('span', null, L('site.name')), ui.icon('external-link', 13, 'ci'));
    var copy = h('p', { class: 'ap-copy' });
    var wait = +st.wait > 0 ? Math.ceil(+st.wait) : 0, timer = 0, busy = false, curMsg = msg, errState = null, errAct = null;

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
    function setMsg(text) { curMsg = text || ''; TP.setText(msgEl, String(curMsg)); msgEl.hidden = !curMsg || mode === 'register'; }
    function renderNotice() {
      var n = A.status && A.status.notice ? String(A.status.notice) : '';
      noticeEl.hidden = !n; TP.setText(noticeEl.lastChild, n);
    }
    function renderNote() {                                                // 当前页的文字: 标题 / 副标题 / 跳到另一页的链接 / 说明 / 上次账号 / 版权
      var reg = mode === 'register';
      renderNotice(); setMsg(curMsg);                         // 「登录已过期」之类的提示只在登录页显示
      TP.setText(titleEl, t(reg ? 'auth.page.reg' : 'auth.page.login')); TP.setText(subEl, t(reg ? 'auth.page.regSub' : 'auth.page.loginSub'));
      TP.setText(swQ, t(reg ? 'auth.hasAcct' : 'auth.noAcct')); TP.setText(swA, t(reg ? 'auth.toLogin' : 'auth.toReg')); swA.setAttribute('href', ROUTE + (reg ? 'login' : 'register'));
      TP.setText(note.lastChild, t(reg ? 'auth.note.register' : 'auth.note.login'));
      last.hidden = !(mode === 'login' && A.hint); TP.setText(last.lastChild, A.hint ? t('auth.last', { hint: A.hint }) : '');
      TP.setText(copy, t('foot.copy', { year: new Date().getFullYear() })); site.title = t('site.title');
      if (api) api.setLabel(t(reg ? 'auth.page.reg' : 'auth.page.login'));
    }
    function setMode(m, push) {                                            // 切换到另一个整页: 地址跟着变 (push = 记入浏览历史, 后退键可以回来)
      mode = m === 'register' ? 'register' : 'login';
      var reg = mode === 'register';
      setUrl(mode, push);
      fPw2.hidden = !reg; pwMin.hidden = !reg;
      pw.setAttribute('autocomplete', reg ? 'new-password' : 'current-password');
      setErr(null); pw.value = ''; pw2.value = ''; renderNote(); paint();
      if (api) { try { (reg || !email.value ? email : pw).focus(); } catch (e) { /* 忽略 */ } }
    }

    function fail(e) {
      var code = e && e.code, d = (e && e.data) || {}, reg = mode === 'register';
      var retry = { label: 'auth.retry', icon: 'refresh', fn: function () { if (pw.value) submit(); else pw.focus(); } };
      if (e.kind === 'unreachable') setErr({ key: 'auth.unreachable', act: retry });
      else if (code === 'E_EMAIL_TAKEN') setErr({ key: 'auth.err.taken', act: { label: 'auth.goLogin', icon: 'lock', fn: function () { var keep = email.value; setMode('login', true); email.value = keep; pw.focus(); } } });
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
        p = ''; finish(r, u, reg);
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
    /* 登录 / 注册成功之后的收尾 (正常登录、带 kick 的重新登录共用) */
    function finish(r, u, reg) {
      pw.value = ''; pw2.value = ''; wipePending();
      TP.setToken(r.token); A.account = r.account ? String(r.account) : u; A.hint = '';
      clearInterval(timer);
      var cur = login; login = null; cur.close('ok');
      unlock(true);
      if (A.returnTo && TP.go) { var back = A.returnTo; A.returnTo = ''; TP.go(back); }
      TP.emit('login', { registered: reg });
      if (reg) ui.toast(t('auth.registered', { account: A.account }), 'ok', 6000);
      else if (r.via === 'offline') ui.toast(t('auth.offlineLogin'), 'warn', 5200);
    }
    /* 设备已满: 弹窗列出在线设备, 每台一个「下线此设备」(先二次确认), 确认后带 kick=<uid> 重新提交同一次登录 */
    function openDevices(data) {
      var devs = Array.isArray(data.devices) ? data.devices.slice() : [], limit = +data.limit || 2, plat = platName(data.platform), busyUid = '';
      var list = h('div', { class: 'devs' }), derr = h('div', { class: 'login-err' }), derrT = h('span'); derr.appendChild(derrT);
      function setDErr(msg) { TP.setText(derrT, msg || ''); derr.classList.toggle('on', !!msg); }
      var dm = null;
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
        busyUid = d.uid; setDErr(''); draw(); dm.setBusy(true);
        try {
          var r = await TP.helper('POST', '/api/login', { form: { user: pending.user, password: pending.password, kick: d.uid }, noAuth: true, timeout: 25000 });
          if (!r || !r.token) throw TP.mkErr('api', t('auth.noToken'));
          dm.setBusy(false); dm.close('ok'); finish(r, pending ? pending.user : '', false);
          return;
        } catch (e) {
          dm.setBusy(false); busyUid = '';
          if (e && e.code === 'E_DEVICE_LIMIT' && e.data) { devs = Array.isArray(e.data.devices) ? e.data.devices.slice() : devs; setDErr(t('auth.dev.again')); }
          else if (e && e.kind === 'unreachable') setDErr(t('auth.unreachable'));
          else setDErr(TP.errMsg(e));
          draw();
        }
      }
      dm = ui.modal({
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
    swA.addEventListener('click', function (e) {
      if (e.ctrlKey || e.metaKey || e.shiftKey || e.button === 1) return;      // 新标签页打开等照常
      e.preventDefault(); if (busy) return; setMode(mode === 'register' ? 'login' : 'register', true);
    });

    /* 语言切换: 页面右上角 (锁定状态下也能换语言) */
    var langBtn = ui.btn(langName(), { sm: true, kind: 'ghost', icon: 'globe', cls: 'ap-lang' });
    ui.menu(langBtn, function () {
      return I.available.map(function (a) { return { label: a.name, check: a.code === I.lang, onClick: function () { TP.setLang(a.code); } }; });
    }, { label: t('lang.menu'), place: 'bottom-end' });
    function repaint() {                                   // 切换语言后重新生成文字
      ui.setBtn(langBtn, langName()); paint(); setMsg(curMsg); renderErr(); renderNote();
    }
    A._repaint = repaint;
    function onPop() { if (login && !busy) setMode(pageFromUrl(), false); }       // 浏览器的后退 / 前进: 在登录页和注册页之间跟着走
    window.addEventListener('popstate', onPop);

    setMsg(msg);
    api = openPage(h('div', { class: 'ap' },
      h('div', { class: 'ap-top' }, langBtn),
      h('div', { class: 'ap-main' },
        h('section', { class: 'ap-card' },
          h('header', { class: 'ap-head' }, titleEl, subEl),
          h('div', { class: 'ap-body' }, msgEl, noticeEl, last, form),
          h('div', { class: 'ap-switch' }, swQ, swA)),
        note),
      h('footer', { class: 'ap-foot' }, site, copy)));
    setMode(mode, false);
    (email.value ? pw : email).setAttribute('data-autofocus', '');
    try { (mode === 'login' && email.value ? pw : email).focus(); } catch (e) { /* 忽略 */ }
    login = { close: function (v) { window.removeEventListener('popstate', onPop); clearInterval(timer); api.close(v); }, setMsg: setMsg, clearEmail: function () { email.value = ''; pw.value = ''; try { email.focus(); } catch (e) { /* 忽略 */ } } };
    if (wait > 0) setWait(wait);
    /* 页面已经显示; 悄悄刷新一次状态 (限流剩余时间 / 上次账号提示可能变了) */
    refreshStatus().then(function () { if (login) { renderNote(); if (+(A.status && A.status.wait) > 0 && wait <= 0) setWait(A.status.wait); } });
  }

  /* ---------- 退出账号 / 切换账号 (都走 POST /api/logout) ---------- */
  A.logout = async function (kind) {
    var sw = kind === 'switch', who = A.label();
    var why = TP.why.helper();
    if (why) { ui.toast(why, 'warn'); return; }
    var ok = await ui.confirmDialog({
      title: t(sw ? 'auth.switch.title' : 'auth.logout.title'), message: t(sw ? 'auth.switch.msg' : 'auth.logout.msg', { who: who }),
      detail: [t('auth.logout.d1'), t('auth.logout.d2'), t('auth.logout.d3'), t('auth.logout.d4')], confirmText: t(sw ? 'auth.switch.go' : 'auth.logout.go'), danger: true, confirmIcon: 'logout'
    });
    if (!ok) return;
    var card = ui.taskCard(t(sw ? 'auth.switch.running' : 'auth.logout.running')), busy = true;
    var m = ui.modal({ title: t(sw ? 'auth.switch.title' : 'auth.logout.title'), icon: 'logout', size: 'sm', static: true, lock: function () { return busy; }, body: card.el, actions: [] });
    m.setBusy(true); card.set({ pct: null, msg: t('job.submitting') });
    A.expectMsg = A.msg(sw ? 'auth.switched' : 'auth.signedOut'); A.expectOpt = sw ? { noPrefill: true } : null;
    try {
      await TP.helper('POST', '/api/logout', { timeout: 20000 });
    } catch (e) {
      if (!(e && e.kind === 'auth')) {                              // 令牌已经失效 (401) 也算成功: 反正已经退出了
        A.expectMsg = ''; A.expectOpt = null; busy = false; m.setBusy(false);
        card.fail(TP.errMsg(e)); m.setActions([{ label: t('common.close'), kind: 'primary', cancel: true }]);
        ui.toast(t('auth.logout.failed', { reason: TP.errMsg(e) }), 'err');
        return;
      }
    }
    busy = false; m.setBusy(false); m.close('done');
    A.account = ''; A.expectMsg = ''; A.expectOpt = null;
    if (S.state) { S.state.account = null; if (S.state.proxy) S.state.proxy.enabled = false; }
    TP.emit('proxy', false);
    A.lock(A.msg(sw ? 'auth.switched' : 'auth.signedOut'), { noPrefill: sw });
  };

  /* ================= 敏感操作: 再次输入登录密码 (step-up) =================
   * 后端有一张白名单, 里面的接口没带有效的 X-Enana-Sudo 时返回 403 E_SUDO_REQUIRED; TP.helper 捕获它 -> TP.sudo.ask() 弹出密码框 -> POST /api/auth/verify
   * -> 拿到 sudo 令牌 (只放在内存里, 5 分钟有效) -> 带着 X-Enana-Sudo 重试原请求。退出账号 / 锁屏 / 登录失效时立即丢弃。
   * 白名单在后端; 这里的 PATHS 只用来「提前带上令牌」和显示小锁图标 (多一个少一个都不影响正确性: 漏掉的会走 403 → 弹框流程)。 */
  var sudo = TP.sudo = { tok: '', exp: 0 }, sudoDlg = null;
  var SUDO_PATHS = ['/api/servers/delete', '/api/sub/delete', '/api/servers/secret', '/api/sub/url', '/api/logs/clear', '/api/devices/kick', '/api/sync/clear', '/api/export'];
  sudo.PATHS = SUDO_PATHS;
  sudo.valid = function () { return !!sudo.tok && Date.now() < sudo.exp; };
  sudo.token = function () { return sudo.valid() ? sudo.tok : ''; };
  sudo.forPath = function (path) { return SUDO_PATHS.indexOf(path) >= 0; };
  sudo.clear = function () { sudo.tok = ''; sudo.exp = 0; };
  TP.on('auth', function (ok) { if (!ok) sudo.clear(); });
  /* 小锁图标: 放在需要再次验证的按钮 / 链接旁边 (title 和 aria-label 跟随语言) */
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
        sudo.tok = String(r.sudo); sudo.exp = Date.now() + Math.max(10, (+r.ttl || 300) - 5) * 1000;
        pw.value = ''; done = true; api.close('ok');
      } catch (e) {
        if (e && e.kind === 'auth') { done = true; api.close('auth'); return false; }                  // 登录已失效: 交给登录框
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
   * 成功后当前设备保持登录, 账号下其它设备全部被退出登录并关闭代理 (说明给用户看)。密码只在内存里, 关闭 / 成功后立即清空。 */
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
        if (e && e.kind === 'auth') { busy = false; api.setBusy(false); api.close('auth'); return false; }
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
