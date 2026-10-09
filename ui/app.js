/* enana · app.js — 外壳: 左侧导航 (宽屏可折叠 / 中屏自动收成图标栏 / 手机上是抽屉) · 极简顶栏 (标题 · 代理总开关 · 账号菜单) · 提示条 · 主题 · 页面切换 · 轮询 · 启动
 * 页面都是 TP.V.<id> = {init(root), show()} 模块; 没加载成功的页面不会拖垮其它页面。
 * 响应式断点 (拖动窗口时实时生效, 不需要刷新):  >= 1100px 完整侧栏 (用户可以手动折叠, 选择会被记住);
 *   760–1099px 自动收成图标栏;  < 760px 侧栏隐藏, 顶栏的汉堡按钮打开抽屉。越过断点时断点优先, 变宽后自动恢复用户的选择。 */
(function () {
  'use strict';
  var TP = window.TP, S = TP.S, h = TP.h, ui = TP.ui, setText = TP.setText, I = window.I18N, t = I.t, L = I.L;
  /* [页面 id, 图标别名]; 词典键 nav.<id> */
  var NAV = [['overview', 'nav-overview'], ['apps', 'nav-apps'], ['sites', 'nav-sites'], ['rules', 'nav-rules'], ['dns', 'nav-dns'], ['servers', 'nav-servers'], ['conns', 'nav-connections'], ['traffic', 'nav-traffic'], ['speed', 'nav-speed'], ['logs', 'nav-logs'], ['settings', 'nav-settings']];
  var navEls = {}, panels = {}, badges = {}, hd = {}, root = document.documentElement;
  /* 路由: 页面地址是路径形式 —— 后台地址 + 页面 id, 例如 /enana/admin/apps (开发时是 /ui/apps); 旧的 #apps 写法 (书签 / 外部链接) 也认。
   * 页面里的相对地址 (style.css / env.json …) 都相对后台地址解析, 所以页面 id 后面不带斜杠。 */
  var ROUTE_RE = /^(.*\/)([^/]*)$/, ROUTE_BASE = (ROUTE_RE.exec(location.pathname) || [0, '/'])[1];
  function routeId() { var seg = (ROUTE_RE.exec(location.pathname) || [])[2] || ''; return panels[seg] ? seg : (location.hash || '').replace(/^#/, ''); }
  var BP_DRAWER = '(max-width:759px)', BP_WIDE = '(min-width:1100px)';
  var mqDrawer = window.matchMedia ? window.matchMedia(BP_DRAWER) : { matches: false };
  var mqWide = window.matchMedia ? window.matchMedia(BP_WIDE) : { matches: true };
  var navPref = TP.prefs.get('ui.sidebar', TP.ls.get('nav', 'expanded')) === 'collapsed' ? 'collapsed' : 'expanded';     // 用户明确选择的状态 (只在宽屏上起作用; 记在 prefs 里, 换设备同步)
  TP.tab = '';

  /* ================= 主题 (跟随系统 / 浅色 / 深色; 在 <html data-theme> 上, boot.js 会在首屏前先应用一次) ================= */
  TP.theme = TP.prefs.get('ui.theme', TP.ls.get('theme', 'auto'));
  function applyTheme() { if (TP.theme === 'light' || TP.theme === 'dark') root.setAttribute('data-theme', TP.theme); else root.removeAttribute('data-theme'); }
  TP.setTheme = function (m) {
    TP.theme = (m === 'light' || m === 'dark') ? m : 'auto';
    TP.prefs.set('ui.theme', TP.theme); applyTheme(); TP.emit('theme', TP.theme);
  };
  applyTheme();
  /* 表格密度: 舒适 (默认) / 紧凑 -> <html data-density="compact"> */
  TP.setDensity = function (m) { TP.prefs.set('ui.density', m === 'compact' ? 'compact' : 'comfortable'); applyDensity(); TP.emit('density'); };
  function applyDensity() { if (TP.prefs.get('ui.density', 'comfortable') === 'compact') root.setAttribute('data-density', 'compact'); else root.removeAttribute('data-density'); }
  applyDensity();
  TP.on('prefs', function (d) {
    if (d && (d.all || d.key === 'ui.density')) applyDensity();                                       // 别的设备同步过来 / 登录后读到本机的偏好: 主题和侧栏立即跟上
    if (d && (d.all || d.key === 'ui.theme')) { var m = TP.prefs.get('ui.theme', 'auto'); if (m !== TP.theme) { TP.theme = m; applyTheme(); TP.emit('theme', TP.theme); } }
    if (d && (d.all || d.key === 'ui.sidebar')) { var n = TP.prefs.get('ui.sidebar', 'expanded') === 'collapsed' ? 'collapsed' : 'expanded'; if (n !== navPref) { navPref = n; if (typeof applyNav === 'function') applyNav(); } }
  });

  /* 顶栏标题 = 页面名 (+ 面包屑: 设置页的当前标签等, 用 TP.setCrumb(function () { return 文字; }) 设置, 切换页面自动清除) */
  var crumbFn = null;
  function paintTitle() {
    if (!hd.title) return;
    TP.clear(hd.title); hd.title.appendChild(document.createTextNode(TP.tab ? t('nav.' + TP.tab) : ''));
    var c = crumbFn ? crumbFn() : '';
    if (c) hd.title.appendChild(h('span', { class: 'crumb' }, ' / ' + c));
  }
  TP.setCrumb = function (fn) { crumbFn = fn; paintTitle(); };

  /* ================= 页面切换 ================= */
  var navSettled = false, popping = false;   // 用户点击的导航新增历史记录; 前进/后退 (popstate) 和启动时不新增
  TP.go = function (id) {
    if (!panels[id]) id = 'overview';
    var changed = TP.tab !== id;
    TP.tab = id;
    NAV.forEach(function (n) {
      var on = n[0] === id;
      panels[n[0]].hidden = !on;
      if (on) navEls[n[0]].setAttribute('aria-current', 'page'); else navEls[n[0]].removeAttribute('aria-current');
    });
    TP.prefs.set('ui.tab', id);
    try { if (location.pathname !== ROUTE_BASE + id || location.hash) (navSettled && !popping ? history.pushState : history.replaceState).call(history, null, '', ROUTE_BASE + id + location.search); } catch (e) { /* 忽略 */ }
    crumbFn = null; paintTitle();
    try { document.title = t('nav.' + id) + ' · enana'; } catch (e) { /* 忽略 */ }
    var V = TP.V[id];
    if (V && V.show) { try { V.show(); } catch (e) { console.error('[' + id + '.show]', e); } }
    if (changed && hd.scroll) hd.scroll.scrollTop = 0;
    closeDrawer(false);
  };
  /* 添加 / 导入服务器 (弹窗, 在当前页面上直接打开) */
  TP.goAdd = function (mode) { return TP.imp.open(mode || 'import'); };

  /* ================= 左侧导航: 完整 / 图标栏 / 抽屉 ================= */
  function navMode() {
    if (mqDrawer.matches) return 'drawer';
    if (!mqWide.matches) return 'rail';                                  // 中屏: 自动收起
    return navPref === 'collapsed' ? 'rail' : 'full';
  }
  function applyNav() {
    var m = navMode();
    if (m === 'rail') root.setAttribute('data-nav', 'collapsed'); else root.removeAttribute('data-nav');
    root.setAttribute('data-navmode', m);
    if (m !== 'drawer') closeDrawer(false);
    if (hd.collapse) {
      var on = m === 'rail', canToggle = !!mqWide.matches && m !== 'drawer';
      hd.collapse.hidden = !canToggle;
      ui.setBtn(hd.collapse, t(on ? 'nav.expand' : 'nav.collapse'), on ? 'expand' : 'collapse');
      hd.collapse.setAttribute('aria-expanded', on ? 'false' : 'true'); hd.collapse.title = t(on ? 'nav.expand' : 'nav.collapse'); hd.collapse.setAttribute('data-tip', t(on ? 'nav.expand' : 'nav.collapse'));
    }
  }
  function isDrawerOpen() { return document.body.classList.contains('nav-open'); }
  function setInert(on) {
    var m = document.querySelector('.main-col'); if (!m) return;
    try { m.inert = !!on; } catch (e) { /* 旧浏览器: 退回 aria-hidden + 焦点锁定 */ }
    if (on) m.setAttribute('aria-hidden', 'true'); else m.removeAttribute('aria-hidden');
  }
  function openDrawer() {
    if (!mqDrawer.matches) return;
    document.body.classList.add('nav-open'); hd.burger.setAttribute('aria-expanded', 'true'); setInert(true);
    var a = navEls[TP.tab] || hd.nav.querySelector('.nav-i'); if (a) { try { a.focus(); } catch (e) { /* 忽略 */ } }
  }
  function closeDrawer(focusBack) {
    if (!isDrawerOpen()) return;
    document.body.classList.remove('nav-open'); hd.burger.setAttribute('aria-expanded', 'false'); setInert(false);
    if (focusBack) { try { hd.burger.focus(); } catch (e) { /* 忽略 */ } }
  }
  /* 抽屉打开时 Tab 键只在抽屉里循环 */
  function trapDrawerTab(e) {
    if (e.key !== 'Tab' || !isDrawerOpen()) return;
    var side = TP.byId('side'), f = Array.prototype.filter.call(side.querySelectorAll('a[href],button:not([hidden]),[tabindex]:not([tabindex="-1"])'), function (x) { return x.offsetParent !== null; });
    if (!f.length) return;
    var first = f[0], last = f[f.length - 1], act = document.activeElement;
    if (e.shiftKey && (act === first || !side.contains(act))) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && (act === last || !side.contains(act))) { e.preventDefault(); first.focus(); }
  }

  function buildNav() {
    hd.nav = TP.byId('nav');
    NAV.forEach(function (n) {
      var id = n[0], badge = h('span', { class: 'nav-badge', hidden: true });
      var a = h('a', { class: 'nav-i', href: ROUTE_BASE + id, 'data-id': id },
        h('span', { class: 'nav-ic' }, ui.icon(n[1], 20)), h('span', { class: 'nav-l' }, L('nav.' + id)), badge);
      a.setAttribute('aria-label', t('nav.' + id)); a.title = t('nav.' + id); a.setAttribute('data-tip', t('nav.' + id));
      a.addEventListener('click', function (e) {
        if (e.ctrlKey || e.metaKey || e.shiftKey || e.button === 1) return;      // 新标签页打开等照常
        e.preventDefault(); TP.go(id);
      });
      navEls[id] = a; badges[id] = badge; hd.nav.appendChild(a);
      panels[id] = TP.byId('v-' + id);
    });
    function relabel() {
      NAV.forEach(function (n) { var s = t('nav.' + n[0]); navEls[n[0]].setAttribute('aria-label', s); navEls[n[0]].title = s; navEls[n[0]].setAttribute('data-tip', s); });
      renderBadges(); applyNav();
    }
    TP.on('lang', relabel);
    TP.on('lang', function () { if (TP.tab) paintTitle(); });
    TP.on('apps', renderBadges); TP.on('badges', renderBadges); TP.on('update', renderBadges);

    /* 折叠按钮 (只在宽屏出现) / 汉堡 (只在窄屏出现) / 遮罩 */
    hd.collapse = ui.btn(L('nav.collapse'), { kind: 'ghost', icon: 'collapse', cls: 'side-btn nav-collapse' });
    hd.collapse.addEventListener('click', function () {
      navPref = navMode() === 'rail' ? 'expanded' : 'collapsed'; TP.prefs.set('ui.sidebar', navPref); applyNav();
    });
    TP.byId('side-bot').appendChild(hd.collapse);
    hd.burger = ui.ibtn('menu', L('nav.open'), { size: 22 }); hd.burger.classList.add('burger'); hd.burger.setAttribute('aria-controls', 'side'); hd.burger.setAttribute('aria-expanded', 'false');
    hd.burger.addEventListener('click', function () { if (isDrawerOpen()) closeDrawer(true); else openDrawer(); });
    TP.byId('burger-slot').appendChild(hd.burger);
    TP.byId('scrim').addEventListener('click', function () { closeDrawer(true); });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && isDrawerOpen() && !document.querySelector('dialog[open]')) closeDrawer(true);
      else trapDrawerTab(e);
    });
    [mqDrawer, mqWide].forEach(function (mq) { if (mq.addEventListener) mq.addEventListener('change', applyNav); else if (mq.addListener) mq.addListener(applyNav); });
    applyNav();

    /* 侧栏底部: 版本 / 更新状态 (小字); 设置入口上的小圆点也表示有新版本 */
    hd.updSide = TP.byId('upd-side'); TP.updates.bindIndicator(hd.updSide, { cls: 'ind-side', size: 16 });
    hd.updSide.addEventListener('click', function () { closeDrawer(false); });          // 窄屏: 点它会在当前页弹出更新窗口 (不跳转), 先收起抽屉
    renderBadges();
  }
  function renderBadges() {
    var n = (S.apps && +S.apps.new_count) || 0, b = badges.apps;
    if (b) { b.hidden = !n; setText(b, n > 99 ? '99+' : n); navEls.apps.setAttribute('aria-label', n ? t('nav.apps') + ' · ' + t('nav.newApps', { n: n }) : t('nav.apps')); }
    var u = badges.settings;
    if (u) { u.hidden = !S.update.available; u.className = 'nav-badge dot'; setText(u, ''); navEls.settings.setAttribute('aria-label', S.update.available ? t('nav.settings') + ' · ' + t('nav.updateDot') : t('nav.settings')); }
    if (hd.acctDot) hd.acctDot.hidden = !S.update.available;
  }

  /* ================= 顶栏: 只有 页面标题 + 状态 | 代理总开关 + 账号菜单 ================= */
  function modeOf(v) { return TP.actions.modeOf(v); }
  function buildHeader() {
    hd.title = TP.byId('page-title'); hd.scroll = TP.byId('scroll');
    hd.dot = TP.byId('dot'); hd.status = TP.byId('status-text'); hd.chip = TP.byId('status-chip'); hd.sdot = TP.byId('dot-brand');
    /* 代理总开关 */
    hd.pxyS = h('span', { class: 'pxy-s' });
    hd.proxy = h('button', { class: 'pxy', type: 'button', role: 'switch', 'aria-checked': 'false' }, ui.icon('power', 18, 'bi'), h('span', { class: 'pxy-l' }, L('proxy.label')), hd.pxyS);
    ui.act(hd.proxy, function () { return TP.actions.setProxy(!TP.actions.proxyOn()); });
    /* 代理模式 (自动模式 / 全局代理): 紧挨着总开关的小按钮, 点开是一个菜单; 代理关闭时也可以先选, 开启后生效 */
    hd.modeIc = 'auto'; hd.modeI = ui.icon('auto', 16, 'mi'); hd.modeT = h('span', { class: 'pxy-mt' });
    hd.mode = h('button', { class: 'pxy-mode', type: 'button' }, hd.modeI, hd.modeT, ui.icon('chevron-down', 14, 'mc'));
    ui.menu(hd.mode, function () {
      var cur = TP.actions.proxyMode(), items = ['auto', 'global'].map(function (m) {
        return { label: t('pmode.' + m), desc: t('pmode.' + m + '.sub'), icon: m === 'global' ? 'globe' : 'auto', check: cur === m, onClick: function () { return TP.actions.setProxyMode(m); } };
      });
      if (TP.actions.proxyOn() === false) items.push({ sep: true }, { note: t('pmode.offHint') });
      return items;
    }, { label: t('pmode.label'), place: 'bottom-end', cls: 'menu-mode' });
    var grp = h('span', { class: 'pxy-grp' }, hd.proxy, hd.mode);
    TP.byId('proxy-slot').appendChild(grp);
    ['state', 'helper', 'auth', 'lang', 'proxy'].forEach(function (ev) { TP.on(ev, paintProxy); });
    paintProxy();

    /* 账号菜单 (头像 + 邮箱; 窄屏只剩头像) */
    hd.acct = TP.byId('acct-btn'); hd.acctAv = TP.byId('acct-av'); hd.acctT = TP.byId('acct-t'); hd.acctDot = TP.byId('acct-dot');
    hd.acct.insertBefore(ui.icon('chevron-down', 14, 'acct-chev'), hd.acctDot);
    ui.menu(hd.acct, function () {
      var items = [
        { label: TP.auth.label(), icon: 'account', onClick: function () { TP.go('settings'); } },
        { label: t('user.settings'), icon: 'nav-settings', onClick: function () { TP.go('settings'); } }
      ];
      if (S.update.available) items.push({ label: t('upd.ind.new', { v: S.update.latest }), icon: 'update', onClick: function () { TP.updates.openDialog(); } });
      items.push({ sep: true });
      items.push({ label: t('user.switch'), icon: 'refresh', onClick: function () { return TP.auth.logout('switch'); } });
      items.push({ label: t('user.logout'), icon: 'logout', danger: true, onClick: function () { return TP.auth.logout('logout'); } });
      return items;
    }, { label: t('user.menu'), place: 'bottom-end' });
    function paintAcct() {
      var who = TP.auth.email() || '', label = TP.auth.label();
      var ch = (who || label).replace(/[^A-Za-z0-9À-￿]/g, '').charAt(0).toUpperCase();
      setText(hd.acctAv, ch || '?'); setText(hd.acctT, label);
      var hue = 0, i; for (i = 0; i < label.length; i++) hue = (hue * 31 + label.charCodeAt(i)) % 360;
      hd.acctAv.style.setProperty('--hue', hue);
      hd.acct.setAttribute('aria-label', t('user.menuOf', { who: label })); hd.acct.title = label;
    }
    TP.on('lang', paintAcct); TP.on('auth', paintAcct); TP.on('settings', paintAcct); TP.on('state', paintAcct); paintAcct();
    TP.on('update', function () { if (hd.acctDot) hd.acctDot.hidden = !S.update.available; });

    TP.on('clash', renderStatus); TP.on('core', renderStatus); TP.on('applying', renderStatus); TP.on('helper', renderStatus); TP.on('state', renderStatus); TP.on('lang', renderStatus);
    TP.on('auth', renderStatus);
    renderStatus();
  }
  /* 代理总开关: 全部直连 (关) / 按设置分流 (开); 请求进行中显示忙碌状态, 其余时间始终可点 (暂时不能用时点击会说明原因) */
  function paintProxy() {
    var st = TP.actions.proxyState(), b = hd.proxy;
    var cls = 'pxy' + (st.on === true ? ' on' : st.on === false ? ' off' : '') + (st.busy ? ' is-busy' : '');
    if (b.className !== cls) b.className = cls;
    b.setAttribute('aria-checked', st.on === true ? 'true' : 'false');
    setText(hd.pxyS, st.label);
    b._tip = t('proxy.tip');
    var why = st.reason || (st.on === null ? t('proxy.loading') : '');
    ui.avail(b, why);
    if (!why) b.title = b._tip;
    b.setAttribute('aria-label', t('proxy.aria', { state: st.label }));
    if (st.busy) b.setAttribute('aria-busy', 'true'); else b.removeAttribute('aria-busy');
    /* 模式按钮 */
    var m = TP.actions.proxyModeShown(), mb = hd.mode, name = m ? t('pmode.' + m) : t('pmode.unknown');
    var want = m === 'global' ? 'globe' : 'auto';
    if (want !== hd.modeIc) { hd.modeIc = want; var ni = ui.icon(want, 16, 'mi'); mb.replaceChild(ni, hd.modeI); hd.modeI = ni; }
    setText(hd.modeT, m ? t('pmode.' + m + '.short') : '…');
    var mcls = 'pxy-mode' + (st.on === false ? ' off' : '') + (TP.actions.proxyBusy() === 'mode' ? ' is-busy' : '');
    if (mb.className !== mcls) mb.className = mcls;
    mb.setAttribute('aria-label', t('pmode.btnAria', { mode: name }) + (st.on === false ? ' — ' + t('pmode.afterOn') : ''));
    mb.title = m ? t(st.on === false ? 'pmode.btnTipOff' : 'pmode.btnTip', { mode: name }) : t('proxy.loading');
  }
  function renderStatus() {
    var st = S.locked ? 'locked' : TP.isApplying() ? 'applying' : (TP.noHelper() && S.clash == null ? 'nohelper' : S.clash), txt, cls;
    if (st === 'ok') { txt = t('status.ok'); cls = 'ok'; }
    else if (st === 'applying') { txt = t('status.applying'); cls = 'warn'; }
    else if (st === 'down') { txt = t('status.down'); cls = 'err'; }
    else if (st === 'nohelper') { txt = t('status.noHelper'); cls = 'err'; }
    else if (st === 'locked') { txt = t('status.locked'); cls = ''; }
    else { txt = t('status.connecting'); cls = ''; }
    TP.setCls(hd.dot, 'dot ' + cls); TP.setCls(hd.sdot, 'dot ' + cls); setText(hd.status, txt);
    var tip = [txt, S.core, TP.cfg.version ? 'enana v' + TP.cfg.version : ''].filter(Boolean).join(' · ');
    hd.chip.title = tip; hd.sdot.title = tip; hd.sdot.setAttribute('aria-label', txt); hd.chip.setAttribute('aria-label', tip);
  }

  /* ================= 提示条 (所有页面顶部): 同一时间最多一条「出问题了」的提示, 说明受影响的功能 ================= */
  function buildBanners() {
    var box = TP.byId('banners'), out = [];
    if (!S.locked) {
      if (S.helperUp === false && !TP.updates.applying()) out.push({ id: 'helper', kind: 'err', icon: 'wifi-off', title: t('banner.helper.title'), text: t('banner.helper.text'), hint: t('banner.helper.hint'), btn: t('banner.retry'), btnIcon: 'refresh', fn: function () { TP.loadState(); TP.kickAll(); } });
      else if (S.clash === 'down' && !TP.isApplying()) out.push({ id: 'core', kind: 'err', icon: 'plug', title: t('banner.core.title'), text: t('banner.core.text'), hint: t('banner.core.hint'), start: true });
      else if (navigator.onLine === false) out.push({ id: 'net', kind: 'warn', icon: 'wifi-off', title: t('banner.net.title'), text: t('banner.net.text') });
      if (TP.actions.proxyOn() === false) out.push({ id: 'proxyoff', kind: 'info', icon: 'power', title: t('banner.proxyOff.title'), text: t('banner.proxyOff.text'), btn: t('banner.proxyOff.btn'), btnIcon: 'power', btnKind: 'success', fn: function () { return TP.actions.setProxy(true); } });
      else if (TP.actions.sysproxyNeeded() && !TP.actions.sysproxyBusy()) out.push({ id: 'sysproxy', kind: 'warn', icon: 'plug', title: t('banner.sysproxy.title'), text: t('banner.sysproxy.text'), hint: t('banner.sysproxy.hint'), btn: t('banner.sysproxy.btn'), btnIcon: 'power', btnKind: 'success', fn: function () { return TP.actions.fixSysproxy(false); } });
      if (!out.length && modeOf(S.mode) === 'Direct') out.push({ id: 'direct', kind: 'warn', icon: 'direct', title: t('banner.direct.title'), text: t('banner.direct.text'), btn: t('banner.direct.btn'), btnIcon: 'list-checks', fn: function () { return TP.actions.setMode('Rule'); } });
      if (S.state && S.state.rules_watch_error) out.push({ id: 'rulesWatch', kind: 'warn', icon: 'refresh', title: t('banner.rulesWatch.title'), text: t('banner.rulesWatch.text'), btn: t('banner.rulesWatch.btn'), btnIcon: 'restart', fn: function () { return TP.actions.restart(); } });
      if (S.state && !(S.state.servers || []).length) out.push({ id: 'noservers', kind: 'warn', icon: 'server', title: t('banner.noServers.title'), text: t('banner.noServers.text'), btn: t('banner.noServers.btn'), btnIcon: 'plus', fn: function () { TP.goAdd('import'); } });
    }
    ui.memo(box, out.map(function (b) { return b.id; }).join('|'), function () {
      if (!out.length) return null;
      var f = document.createDocumentFragment();
      out.forEach(function (b) {
        var act = null;
        if (b.start) { var sb = TP.bindRestartBtn(ui.btn(L('act.restart.label'), { sm: true, icon: 'power' })); act = h('div', { class: 'banner-a' }, sb); }
        else if (b.btn) { var bt = ui.btn(b.btn, { sm: true, icon: b.btnIcon, kind: b.btnKind }); ui.act(bt, b.fn); act = h('div', { class: 'banner-a' }, bt); }
        f.appendChild(h('div', { class: 'banner ' + b.kind, role: b.kind === 'err' ? 'alert' : 'status' },
          h('span', { class: 'banner-ic' }, ui.icon(b.icon, 22)),
          h('div', { class: 'banner-b' }, h('b', null, b.title), b.text ? h('div', { class: 'sm' }, b.text) : null, b.hint ? h('div', { class: 'sm muted' }, b.hint) : null), act));
      });
      return f;
    });
  }

  /* ================= 页脚 / 图标栏状态下键盘焦点的提示 / 弹窗里的输入框不被软键盘挡住 ================= */
  function renderFoot() {
    var f = TP.byId('foot'); if (!f) return;
    var v = TP.updates.version(), l = h('span', { class: 'foot-l' }, I.rich('foot.text', { cmd: h('code', null, 'enana') }), v ? ' · enana v' + v : '');
    var site = h('a', { class: 'foot-site', href: TP.auth.url('account_url'), target: '_blank', rel: 'noopener noreferrer', title: t('site.title') }, ui.icon('globe', 14, 'ci'), h('span', null, t('site.name')), ui.icon('external-link', 13, 'ci'));
    TP.clear(f); f.appendChild(l); f.appendChild(h('span', { class: 'foot-r' }, site, h('span', { class: 'foot-copy' }, t('foot.copy', { year: new Date().getFullYear() }))));      // 固定在底部: enana 官网链接 + 版权
  }
  function setupTips() {
    var tip = h('div', { id: 'navtip', class: 'navtip', role: 'tooltip', hidden: true }); document.body.appendChild(tip);
    var side = TP.byId('side');
    side.addEventListener('focusin', function (e) {
      var a = e.target;
      if (navMode() !== 'rail' || !a.getAttribute || !a.getAttribute('data-tip')) return;
      try { if (a.matches && !a.matches(':focus-visible')) return; } catch (x) { /* 不支持 :focus-visible 时照常显示 */ }
      var r = a.getBoundingClientRect();
      setText(tip, a.getAttribute('data-tip')); tip.hidden = false;
      tip.style.left = (r.right + 8) + 'px'; tip.style.top = Math.max(6, r.top + r.height / 2 - tip.offsetHeight / 2) + 'px';
    });
    side.addEventListener('focusout', function () { tip.hidden = true; });
    /* 手机上: 聚焦弹窗里的输入框时滚动到可见位置 (软键盘弹出后不会遮住它) */
    document.addEventListener('focusin', function (e) {
      var el = e.target;
      if (!mqDrawer.matches || !el || !el.closest || !el.closest('dialog') || !/^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName)) return;
      setTimeout(function () { try { el.scrollIntoView({ block: 'center', behavior: 'smooth' }); } catch (x) { /* 忽略 */ } }, 280);
    });
  }

  /* ================= 启动 ================= */
  async function boot() {
    I.init();
    await TP.loadEnv();
    buildNav(); buildHeader(); setupTips();
    renderFoot(); TP.on('lang', renderFoot); TP.on('update', renderFoot); TP.on('state', renderFoot);
    NAV.forEach(function (n) {
      var id = n[0], V = TP.V[id];
      try { if (V && V.init) V.init(panels[id]); else throw new Error('module missing'); }
      catch (e) {
        console.error('[' + id + '.init]', e);
        panels[id].appendChild(h('div', { class: 'empty-s' }, ui.icon('warning', 44, 'empty-ic'), h('p', { class: 'empty-t' }, t('app.pageFailed'))));
      }
    });
    ['clash', 'helper', 'state', 'mode', 'applying', 'auth', 'lang', 'proxy'].forEach(function (ev) { TP.on(ev, buildBanners); });
    TP.on('update', buildBanners);
    window.addEventListener('online', function () { buildBanners(); TP.syncBtns(); }); window.addEventListener('offline', function () { buildBanners(); TP.syncBtns(); });
    buildBanners();

    /* 轮询: 隐藏标签页 / 未登录时自动暂停; 串行不重叠 */
    TP.pollers.state = TP.poll(TP.loadState, 10000);
    TP.pollers.proxies = TP.poll(TP.loadProxies, 3000);
    TP.pollers.conns = TP.poll(TP.loadConns, 1000, { when: function () { return S.monitor; } });
    TP.pollers.version = TP.poll(TP.loadVersion, 60000);
    TP.pollers.apps = TP.poll(TP.scanAppsBackground, 60000);
    TP.on('helper', function (up) { if (up && !S.locked) { TP.loadState(); TP.loadApps(false); } });
    TP.on('clash', function (st) { if (st === 'ok') { TP.loadVersion(); } });
    TP.on('auth', function (ok) { if (ok) { TP.loadCatalog(); TP.loadSettings(); TP.updates.check(false); } });
    /* 新登录之后 (不是页面刷新): 如果云端有配置而本机没有服务器, 提示一键同步 (等状态读到后再判断) */
    var offerPending = false;
    TP.on('login', function () { offerPending = true; });
    TP.on('state', function () { if (offerPending && S.state) { offerPending = false; if (TP.sync && TP.sync.offerAfterLogin) { try { TP.sync.offerAfterLogin(); } catch (e) { console.error('[sync.offer]', e); } } } });
    TP.updates.start();
    var shown = TP.ss.get('updated', '');
    if (shown) { TP.ss.del('updated'); setTimeout(function () { ui.toast(t('upd.updatedTo', { v: shown }), 'ok', 6000); }, 800); }

    var start = routeId();
    if (!panels[start]) start = TP.prefs.get('ui.tab', TP.ls.get('tab', 'overview'));
    TP.go(start); navSettled = true;
    TP.auth.start();
  }

  window.addEventListener('unhandledrejection', function (e) {
    if (e.reason && (e.reason.kind === 'auth' || e.reason.kind === 'cancel')) { e.preventDefault(); return; }
    console.error('unhandled:', e.reason);
    ui.toast(t('app.unhandled', { reason: TP.errMsg(e.reason) }), 'err'); e.preventDefault();
  });
  window.addEventListener('hashchange', function () { var id = (location.hash || '').replace(/^#/, ''); if (panels[id] && id !== TP.tab) TP.go(id); });
  window.addEventListener('popstate', function () { popping = true; try { TP.go(routeId()); } finally { popping = false; } });
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot); else boot();
})();
