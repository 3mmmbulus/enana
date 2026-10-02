/* enana · v-settings.js — 设置页 (标签页, 一次只显示一个标签的内容; 上次打开的标签记在 prefs 里):
 *   常规 (语言 / 主题) · 代理 (总开关 / 模式 / 重启服务) · 同步 (TP.sync.settingsCard) · 日志 (TP.logs.settingsCard) · 更新 (版本 / 自动更新) · 账号与设备 (账号 / 修改密码 / 我的设备 / 导出备份) · 会员 (套餐) · 关于
 * 账号是 enana.cc 账号 (邮箱 + 密码), 可以在这里直接修改密码; 导出备份 / 下线设备等敏感操作会再要一次登录密码 (TP.sudo)。
 * 其它模块要跳到某个标签: TP.settingsTab('sync')。每个设置项旁边有「!」说明图标 (ui.help)。 */
(function () {
  'use strict';
  var TP = window.TP, S = TP.S, h = TP.h, ui = TP.ui, setText = TP.setText, I = window.I18N, t = I.t, L = I.L;
  var V = TP.V.settings = { id: 'settings' };
  var el = {}, REPO = 'https://github.com/3mmmbulus/enana', NOTICES = REPO + '/blob/main/THIRD_PARTY_NOTICES.md';
  var TABS = [['general', 'sliders-horizontal'], ['proxy', 'nav-connections'], ['sync', 'refresh'], ['logs', 'nav-logs'], ['updates', 'update'], ['account', 'account'], ['plan', 'pro'], ['about', 'info']];
  var cur = '', panels = {};

  function active() { return TP.tab === 'settings'; }
  function xlink(href, label) { return h('a', { class: 'xlink', href: href, target: '_blank', rel: 'noopener noreferrer' }, label, ui.icon('external-link', 13, 'ci')); }
  function hl(topic) { return ui.help(topic); }
  /* 一行设置: 标签 (可带 ! 说明) | 内容 | 右侧控件 */
  function row(label, value, extra, help) { return h('div', { class: 'kv-row set-row' }, h('span', { class: 'kv-k' }, label, help ? hl(help) : null), h('span', { class: 'kv-v' }, value), extra || null); }
  /* 一张设置卡片 */
  function card(id, icon, titleL, subL, help) {
    return h('section', { class: 'card set-card', id: 'set-' + id }, h('div', { class: 'card-h' }, ui.icon(icon, 20, 'ci'), h('h2', null, titleL, help ? hl(help) : null), subL ? h('span', { class: 'muted sm' }, subL) : null));
  }
  /* 没有加载成功的模块 (同步 / 日志): 用一张说明卡片顶上, 不让这个标签是空的 */
  function missing(id, icon, titleL) { var c = card(id, icon, titleL); c.appendChild(h('p', { class: 'muted' }, L('app.pageFailed'))); return c; }

  V.init = function (root) {
    el.tabs = ui.tabs(L('set.tabs.aria'), TABS.map(function (x) { return { id: x[0], label: L('set.tab.' + x[0]), icon: x[1] }; }), function (id) { pick(id, true); });
    root.appendChild(h('div', { class: 'intro set-intro' }, h('p', { class: 'muted' }, L('set.intro'), hl('settings.tabs'))));
    root.appendChild(h('div', { class: 'set-tabs' }, el.tabs.el));
    var built = {
      general: [generalCard()], proxy: [proxyCard()],
      sync: [gateBanner('sync'), TP.sync && TP.sync.settingsCard ? TP.sync.settingsCard() : missing('sync', 'refresh', L('set.sync.title'))],
      logs: [TP.logs && TP.logs.settingsCard ? TP.logs.settingsCard() : missing('logs', 'nav-logs', L('set.logs.title'))],
      updates: [updatesCard()], account: [accountCard(), devicesCard(), backupCard()], plan: [planCard()], about: [aboutCard()]
    };
    TABS.forEach(function (x) {
      var p = panels[x[0]] = h('div', { class: 'set-panel', role: 'tabpanel', id: 'set-p-' + x[0], 'aria-labelledby': el.tabs.btn(x[0]).id, hidden: true }, built[x[0]]);
      root.appendChild(p);
    });
    var want = TP.prefs.get('ui.settings.tab', 'general');
    pick(panels[want] ? want : 'general', false);

    TP.on('prefs', function (d) { if (d && (d.all || d.key === 'ui.settings.tab')) { var w = TP.prefs.get('ui.settings.tab', 'general'); if (panels[w] && w !== cur) pick(w, false); } });
    TP.on('update', function () { if (active()) renderUpdates(); });
    TP.on('state', function () { if (active()) { renderAccount(); renderAbout(); renderProxy(); } });
    TP.on('core', function () { if (active()) renderUpdates(); });
    TP.on('helper', function () { if (active()) { renderAccount(); renderUpdates(); renderProxy(); } });
    TP.on('clash', function () { if (active()) renderProxy(); });
    TP.on('proxy', function () { if (active()) renderProxy(); });
    TP.on('auth', function (ok) { if (ok) { renderAccount(); if (active()) { loadDevices(false); TP.plan.load(false); } } });
    TP.on('settings', function () { if (active()) { renderAccount(); renderProxy(); renderUpdates(); } });
    TP.on('plan', function () { renderPlan(); });
    TP.on('lang', function () { renderAccount(); renderGeneral(); renderUpdates(); renderAbout(); renderProxy(); renderDevices(); renderPlan(); });
    V.render();
  };
  V.show = function () {
    TP.setCrumb(function () { return t('set.tab.' + cur); });
    V.render();
    TP.loadSettings(); loadDevices(false); TP.plan.load(false);
    if (!S.update.loaded && !S.update.checking) TP.updates.check(false);
  };
  V.render = function () { renderAccount(); renderGeneral(); renderProxy(); renderUpdates(); renderAbout(); renderPlan(); };

  function pick(id, user) {
    if (!panels[id]) id = 'general';
    cur = id; el.tabs.set(id);
    TP.setCrumb(function () { return t('set.tab.' + cur); });
    TABS.forEach(function (x) { panels[x[0]].hidden = x[0] !== id; });
    if (user) TP.prefs.set('ui.settings.tab', id);
    if (id === 'account' && active()) loadDevices(false);
    if (id === 'plan') TP.plan.load(false);
  }
  /* 其它模块 / 横幅要跳到设置里的某个标签 */
  TP.settingsTab = function (id) { if (panels[id]) pick(id, true); TP.go('settings'); };

  /* 功能被套餐挡住时 (features.<key>.enabled === false) 在这个标签顶部显示一条说明, 并附「了解」按钮 (不是死按钮); 可用时整条隐藏 */
  function gateBanner(key) {
    var b = ui.btn(L('plan.f.more'), { sm: true, icon: 'help-i' }); ui.act(b, function () { TP.plan.explain(key); });
    var txt = h('span'), badge = h('span'), box = h('div', { class: 'hint warn plan-gate', hidden: true }, ui.icon('lock', 15, 'ci'), badge, txt, b);
    function paint() {
      var f = TP.plan.feature(key); box.hidden = f.enabled;
      if (f.enabled) return;
      TP.clear(badge); badge.appendChild(f.comingSoon ? ui.badge(L('plan.soon'), 'info', 'clock') : ui.badge(L('plan.pro'), 'pro', 'pro'));
      setText(txt, t(f.comingSoon ? 'plan.gate.soon' : f.reason === 'expired' ? 'plan.gate.expired' : 'plan.gate.upgrade', { name: TP.plan.name(key) }));
    }
    TP.on('plan', paint); TP.on('lang', paint); paint();
    return box;
  }

  /* ================= 常规: 语言 / 主题 ================= */
  function generalCard() {
    el.lang = ui.seg(L('set.lang.aria'), I.available.map(function (a) { return { v: a.code, label: a.name }; }), function (v) { el.lang.set(I.lang); TP.setLang(v); renderGeneral(); });
    el.theme = ui.seg(L('set.theme.aria'), [
      { v: 'system', label: L('set.theme.auto'), icon: 'monitor' }, { v: 'light', label: L('set.theme.light'), icon: 'light' }, { v: 'dark', label: L('set.theme.dark'), icon: 'dark' }],
      function (v) { TP.setTheme(v === 'system' ? 'auto' : v); renderGeneral(); });          // 分段值不用 'auto': 样式里 data-v=auto 是「自动线路」的绿色
    el.density = ui.seg(L('set.density.aria'), [{ v: 'comfortable', label: L('set.density.comfortable'), icon: 'list-checks' }, { v: 'compact', label: L('set.density.compact'), icon: 'minus' }], function (v) { TP.setDensity(v); renderGeneral(); });
    var c = card('general', 'sliders-horizontal', L('set.general.title'), null, 'settings.general');
    c.appendChild(row(L('set.lang.label'), el.lang.el, null, 'settings.lang')); c.appendChild(h('div', { class: 'muted sm set-note' }, L('set.lang.note')));
    c.appendChild(row(L('set.theme.label'), el.theme.el, null, 'settings.theme'));
    c.appendChild(row(L('set.density.label'), el.density.el, null, 'settings.density'));
    c.appendChild(h('div', { class: 'muted sm set-note' }, ui.icon('refresh', 13, 'ci'), ' ', L('set.prefs.note')));
    return c;
  }
  function renderGeneral() { el.lang.set(I.lang); el.theme.set(TP.theme === 'light' || TP.theme === 'dark' ? TP.theme : 'system'); el.density.set(TP.prefs.get('ui.density', 'comfortable') === 'compact' ? 'compact' : 'comfortable'); }

  /* ================= 代理: 总开关 / 模式 / 重启服务 ================= */
  function proxyCard() {
    el.pm = TP.modeControl();
    el.master = h('input', { type: 'checkbox', role: 'switch', 'aria-label': L('proxy.tip') });
    ui.switchAct(el.master, function () { return TP.actions.proxyOn() === true; }, function (want) { return TP.actions.setProxy(want); });
    el.masterTxt = h('b', { class: 'set-svc' });
    el.svcTxt = h('span', { class: 'set-svc' });
    el.restart = TP.bindRestartBtn(ui.btn(L('act.restart.label'), { sm: true, icon: 'restart' }));
    var c = card('proxy', 'nav-connections', L('set.proxy.title'), L('set.proxy.sub'), 'settings.proxy');
    c.appendChild(h('div', { class: 'kv-row set-row' }, h('span', { class: 'kv-k' }, L('proxy.label'), hl('settings.master')),
      h('span', { class: 'kv-v' }, h('div', null, el.masterTxt), h('div', { class: 'muted sm' }, L('set.proxy.masterNote'))), h('label', { class: 'sw' }, el.master, h('span', { class: 'sw-ui' }))));
    c.appendChild(h('div', { class: 'kv-row set-row set-pm' }, h('span', { class: 'kv-k' }, L('set.proxy.mode'), hl('settings.mode')), h('span', { class: 'kv-v' }, el.pm.el)));
    c.appendChild(h('div', { class: 'muted sm set-note' }, L('set.proxy.modeNote')));
    c.appendChild(row(L('set.proxy.service'), el.svcTxt, el.restart, 'settings.service'));
    return c;
  }
  function renderProxy() {
    var on = TP.actions.proxyOn();
    el.master.checked = on === true;
    ui.avail(el.master, TP.actions.proxyWhy());
    setText(el.masterTxt, on === true ? t('proxy.stateOn') : on === false ? t('proxy.stateOff') : t('proxy.stateUnknown'));
    setText(el.svcTxt, S.clash === 'ok' ? t('set.proxy.running') : TP.coreStopped() ? t('set.proxy.stopped') : t('set.proxy.unknown'));
  }

  /* ================= 更新: 版本 / 自动更新 ================= */
  function autoOn() { var st = S.prefs && S.prefs.settings; return !!(st && st.auto_update !== false); }
  async function setAuto(want) {
    var why = TP.why.helper(); if (why) { ui.toast(why, 'warn'); return; }
    var ok = await ui.confirmDialog({ title: t(want ? 'set.auto.onTitle' : 'set.auto.offTitle'), message: t(want ? 'set.auto.onMsg' : 'set.auto.offMsg'), detail: t('set.auto.detail'), confirmText: t(want ? 'set.auto.onGo' : 'set.auto.offGo'), kind: want ? 'success' : 'warning', rememberKey: 'autoupd' });
    if (!ok) return;
    await TP.helper('POST', '/api/settings', { form: { auto_update: want ? 1 : 0 } });
    if (S.prefs && S.prefs.settings) S.prefs.settings.auto_update = want;
    TP.emit('settings', S.prefs);
    ui.toast(t(want ? 'set.auto.onDone' : 'set.auto.offDone'), 'ok');
    TP.loadSettings();
  }
  function updatesCard() {
    var c = card('updates', 'update', L('set.updates.title'), null, 'settings.updates');
    el.verV = h('span', { class: 'set-ver' });
    el.chkBtn = ui.btn(L('upd.chk.ok'), { icon: 'refresh' });
    ui.act(el.chkBtn, function () { return TP.updates.check(true); });
    el.updBtn = ui.btn(L('set.upd.go'), { kind: 'primary', icon: 'update' });
    ui.act(el.updBtn, function () { return TP.updates.apply('app'); });
    el.chkNote = h('div', { class: 'muted sm', 'aria-live': 'polite' });
    el.notes = h('div');
    el.coreV = h('span');
    el.coreBtn = ui.btn(L('set.core.go'), { icon: 'update' });
    ui.act(el.coreBtn, function () { return TP.updates.apply('core'); });
    el.auto = h('input', { type: 'checkbox', role: 'switch', 'aria-label': L('set.auto.label') });
    ui.switchAct(el.auto, function () { return autoOn(); }, function (want) { return setAuto(want); });
    c.appendChild(row(L('set.about.version'), el.verV, h('span', { class: 'set-ctl' }, el.chkBtn, el.updBtn)));
    c.appendChild(el.chkNote); c.appendChild(el.notes);
    c.appendChild(row(L('set.core.label'), el.coreV, el.coreBtn, 'settings.core'));
    c.appendChild(h('div', { class: 'kv-row set-row' }, h('span', { class: 'kv-k' }, L('set.auto.title'), hl('settings.autoupdate')),
      h('span', { class: 'kv-v' }, h('div', null, h('b', null, L('set.auto.label'))), h('div', { class: 'muted sm' }, L('set.auto.note'))),
      h('label', { class: 'sw' }, el.auto, h('span', { class: 'sw-ui' }))));
    TP.bindBtn(el.chkBtn, function (b) {
      var st = TP.updates.checkLabel(), why = TP.why.helper();
      TP.paintBtn(b, { label: st.label, icon: st.icon, busy: S.update.checking, muted: !!st.ok, reason: why || st.reason || '' });
    });
    TP.bindBtn(el.updBtn, function (b) {
      var u = S.update, why = TP.why.helper();
      TP.paintBtn(b, u.available ? { label: t('set.upd.to', { v: u.latest }), icon: 'update', reason: why } : { label: t('set.upd.latest'), icon: 'success', muted: true, reason: t('set.upd.latestReason', { v: TP.updates.version() || '—' }) });
    });
    TP.bindBtn(el.coreBtn, function (b) {
      var c2 = S.update.core, why = TP.why.helper();
      if (c2 && c2.available) TP.paintBtn(b, { label: t('set.core.to', { v: c2.latest }), icon: 'update', reason: why });
      else TP.paintBtn(b, { label: t('set.core.latest'), icon: 'success', muted: true, reason: t('set.core.latestReason') });
    });
    return c;
  }
  function renderUpdates() {
    var u = S.update, v = TP.updates.version();
    setText(el.verV, 'enana ' + (v ? 'v' + v : '—'));
    setText(el.chkNote, u.error && !u.available ? t('set.upd.checkFailed', { reason: u.errCode === 'E_NETWORK' ? t('upd.chk.errNet') : u.error }) : (u.checked ? t('set.upd.checkedAt', { when: TP.fmt.dateTime(u.checked) }) : t('set.upd.neverChecked')));
    var notes = TP.updates.notes();
    ui.memo(el.notes, [u.available, u.latest, notes.length, u.loaded].join('|'), function () {
      if (u.available) return h('div', { class: 'set-notes' }, h('b', null, t('set.upd.notesTitle', { v: u.latest })), h('pre', { class: 'upd-notes' }, notes || t('upd.card.noNotes')), u.url && /^https:\/\//.test(u.url) ? xlink(u.url, t('set.upd.releasePage')) : null);
      return u.loaded ? h('p', { class: 'hint ok' }, ui.icon('success', 15, 'ci'), ' ' + t('set.upd.upToDate', { v: v || '—' })) : null;
    });
    var core = (S.core || '').replace(/^sing-box\s*/i, ''), c2 = S.update.core;
    setText(el.coreV, 'sing-box ' + (c2 && c2.current ? c2.current : core || '—') + (c2 && c2.available ? ' → ' + c2.latest : ''));
    el.auto.checked = autoOn();
    ui.avail(el.auto, TP.why.helper() || (!S.prefs ? t('set.auto.loading') : ''));
  }

  /* ================= 账号与设备 ================= */
  function accountCard() {
    el.accWho = h('span', { class: 'set-who' });
    el.accNote = h('div', { class: 'muted sm' });
    el.btnPw = ui.btn(L('set.acc.changePw'), { icon: 'password' }); ui.act(el.btnPw, function () { return TP.auth.changePassword(); });
    el.btnSwitch = ui.btn(L('set.acc.switch'), { icon: 'refresh' }); ui.act(el.btnSwitch, function () { return TP.auth.logout('switch'); });
    el.btnOut = ui.btn(L('set.acc.logout'), { icon: 'logout', kind: 'soft-bad' }); ui.act(el.btnOut, function () { return TP.auth.logout('logout'); });
    var c = card('account', 'account', L('set.acc.title'), L('set.acc.sub'), 'settings.account');
    c.appendChild(row(L('set.acc.signedIn'), el.accWho)); c.appendChild(el.accNote);
    c.appendChild(h('div', { class: 'row wrap set-btns' }, el.btnPw, el.btnSwitch, el.btnOut));
    c.appendChild(h('p', { class: 'hint sudo-hint' }, ui.icon('lock', 14, 'ci'), h('span', null, L('set.acc.sudoNote'), hl('settings.sudo'))));
    return c;
  }
  function renderAccount() {
    var A = TP.auth;
    setText(el.accWho, A.email() || t('set.acc.unknown'));
    setText(el.accNote, t('set.acc.note', { n: TP.CFG.AUTO_LOCK_MIN }));
    var why = TP.why.helper();
    ui.avail(el.btnSwitch, why); ui.avail(el.btnOut, why); ui.avail(el.btnPw, why);
  }

  /* ---- 我的设备: 同一账号、同一平台最多同时在线 2 台; 可以下线其它设备 (敏感操作: 先二次确认, 再要一次登录密码) ---- */
  var dev = { st: 'idle', data: null, err: null };
  function devicesCard() {
    el.devRefresh = ui.ibtn('refresh', L('set.dev.refresh'), { size: 16 });
    ui.act(el.devRefresh, function () { return loadDevices(true); });
    el.devSub = h('span', { class: 'muted sm' });
    el.devList = h('div', { class: 'devs' });
    el.devEmpty = ui.emptyBox();
    var c = h('section', { class: 'card set-card', id: 'set-devices' }, h('div', { class: 'card-h' }, ui.icon('monitor', 20, 'ci'), h('h2', null, L('set.dev.title'), hl('settings.devices')), el.devSub, el.devRefresh), el.devList, el.devEmpty.el);
    return c;
  }
  async function loadDevices(manual) {
    if (S.locked) return;
    var why = TP.why.helper();
    if (why) { dev.st = 'err'; dev.err = { reason: why, helper: true }; renderDevices(); if (manual) ui.toast(why, 'warn'); return; }
    dev.st = 'load'; renderDevices();
    try {
      dev.data = await TP.helper('GET', '/api/devices');
      dev.st = 'ok'; dev.err = null;
    } catch (e) {
      if (e && e.kind === 'auth') return;
      dev.st = 'err'; dev.err = { reason: e && e.code === 'E_ACCOUNT_UNREACHABLE' ? t('set.dev.offline') : TP.errMsg(e), cloud: !!(e && e.code === 'E_ACCOUNT_UNREACHABLE') };
    }
    renderDevices();
  }
  async function kickDevice(d) {
    var ok = await TP.auth.confirmKick(d, false);
    if (!ok) return;
    await TP.helper('POST', '/api/devices/kick', { form: { uid: d.uid }, sudoWhy: t('set.dev.sudoWhy', { name: d.name }) });
    ui.toast(t('set.dev.kicked', { name: d.name }), 'ok');
    await loadDevices(false);
  }
  function renderDevices() {
    var d = dev.data, list = (d && d.devices) || [], why = TP.why.helper();
    el.devRefresh.classList.toggle('is-busy', dev.st === 'load');
    ui.avail(el.devRefresh, dev.st === 'load' ? t('set.dev.loading') : why);
    setText(el.devSub, d && d.limit ? t('set.dev.sub', { n: d.limit }) : '');
    TP.clear(el.devList);
    if (dev.st === 'load' && !list.length) { el.devEmpty.hide(); el.devList.appendChild(ui.skeleton(4)); return; }
    if (dev.st === 'err') {
      el.devEmpty.show({ icon: dev.err && dev.err.cloud ? 'wifi-off' : 'warning', text: t('set.dev.error', { reason: dev.err ? dev.err.reason : '' }), hint: dev.err && dev.err.cloud ? t('set.dev.offlineHint') : '', action: { label: t('common.retry'), icon: 'refresh', fn: function () { return loadDevices(true); } } });
      return;
    }
    if (!list.length) { el.devEmpty.show({ icon: 'monitor', text: t('set.dev.empty') }); return; }
    el.devEmpty.hide();
    list.slice().sort(function (a, b) { return (b.current ? 1 : 0) - (a.current ? 1 : 0) || (b.online ? 1 : 0) - (a.online ? 1 : 0) || (+b.last_seen || 0) - (+a.last_seen || 0); }).forEach(function (x) {
      var b = TP.sudo.mark(ui.btn(L('set.dev.kick'), { sm: true, kind: 'danger', icon: 'logout' }));
      ui.act(b, function () { return kickDevice(x); });
      ui.avail(b, x.current ? t('set.dev.current') : why);
      el.devList.appendChild(TP.auth.deviceRow(x, b));
    });
  }

  /* ---- 导出配置备份 (含凭据, 敏感操作) ---- */
  function backupCard() {
    el.btnBackup = TP.sudo.mark(ui.btn(L('set.bk.btn'), { icon: 'download' }));
    ui.act(el.btnBackup, exportBackup);
    var c = card('backup', 'download', L('set.bk.title2'), null, 'settings.backup');
    c.appendChild(h('p', { class: 'muted' }, L('set.bk.note')));
    c.appendChild(h('div', { class: 'row wrap set-btns' }, el.btnBackup));
    return c;
  }
  function stamp() { var d = new Date(), p = function (n) { return String(n).length < 2 ? '0' + n : String(n); }; return d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate()) + '-' + p(d.getHours()) + p(d.getMinutes()); }
  function saveFile(text, name) {
    var blob = new Blob([text], { type: 'application/json' }), url = URL.createObjectURL(blob), a = h('a', { href: url, download: name, class: 'sr' });
    document.body.appendChild(a); a.click(); document.body.removeChild(a);
    setTimeout(function () { URL.revokeObjectURL(url); }, 4000);
  }
  async function exportBackup() {
    var why = TP.why.helper(); if (why) { ui.toast(why, 'warn'); return; }
    var ok = await ui.confirmDialog({ title: t('set.bk.title'), message: t('set.bk.msg'), detail: [t('set.bk.d1'), t('set.bk.d2'), t('set.bk.d3')], confirmText: t('set.bk.go'), kind: 'warning', confirmIcon: 'download' });
    if (!ok) return;
    var r = await TP.helper('GET', '/api/export', { text: true, timeout: 30000, sudoWhy: t('set.bk.sudoWhy') });
    var text = r && r.text != null ? r.text : '';
    if (!text) throw TP.mkErr('api', t('set.bk.empty'));
    saveFile(text, 'enana-backup-' + stamp() + '.json');
    ui.toast(t('set.bk.done'), 'ok', 8000);
  }

  /* ================= 会员 / 套餐 (目前所有功能免费; 界面只读 GET /api/plan) ================= */
  function planCard() {
    el.planBox = h('div', { class: 'plan' });
    el.planRefresh = ui.ibtn('refresh', L('plan.refresh'), { size: 16 });
    ui.act(el.planRefresh, function () { return TP.plan.load(true); });
    var c = h('section', { class: 'card set-card', id: 'set-plan' }, h('div', { class: 'card-h' }, ui.icon('pro', 20, 'ci'), h('h2', null, L('plan.title'), hl('settings.plan')), h('span', { class: 'muted sm' }, L('plan.sub')), el.planRefresh), el.planBox);
    return c;
  }
  function renderPlan() {
    if (!el.planBox) return;
    var d = TP.plan.get(), why = TP.why.helper();
    ui.avail(el.planRefresh, why);
    var sig = JSON.stringify(d || 0) + I.lang;
    if (el.planBox._sig === sig) return;
    el.planBox._sig = sig; TP.clear(el.planBox);
    if (!d) { el.planBox.appendChild(S.locked ? h('p', { class: 'muted' }, t('why.locked')) : ui.skeleton(5)); return; }
    var pro = TP.plan.isPro(), exp = d.expires_at ? +d.expires_at : 0, now = Math.floor(Date.now() / 1000), left = exp ? Math.ceil((exp - now) / 86400) : 0;
    var head = h('div', { class: 'plan-h' },
      h('span', { class: 'plan-ic' + (pro ? ' pro' : '') }, ui.icon(pro ? 'pro' : 'success', 22)),
      h('div', { class: 'plan-t' }, h('b', null, TP.plan.title() || t('plan.tier.free')), h('div', { class: 'muted sm' }, exp ? (left > 0 ? t('plan.expires', { date: TP.fmt.date(exp), n: left }) : t('plan.expired', { date: TP.fmt.date(exp) })) : t('plan.noExpiry'))),
      ui.badge(pro ? L('plan.pro') : L('plan.tier.free'), pro ? 'pro' : 'neutral', pro ? 'pro' : null));
    el.planBox.appendChild(head);
    var lim = d.limits || {}, rows = [];
    if (lim.devices_per_platform) rows.push(row(t('plan.limit.devices'), t('plan.limit.devicesVal', { n: lim.devices_per_platform })));
    if (d.checked) rows.push(row(t('plan.checked'), TP.fmt.rel(d.checked)));
    var of = d.official || {};
    rows.push(row(t('plan.official'), of.available ? t('plan.official.on', { n: of.nodes || 0 }) : t('plan.official.off')));
    rows.forEach(function (r) { el.planBox.appendChild(r); });
    /* 功能清单: 名称 / 套餐 / 现状; 点「了解」弹出说明 (没有死按钮) */
    var feats = d.features || {}, keys = Object.keys(feats), list = h('ul', { class: 'plan-feats' });
    keys.forEach(function (k) {
      var f = TP.plan.feature(k), st;
      if (f.enabled) st = ui.badge(L('plan.f.on'), 'ok', 'success');
      else if (f.comingSoon) st = ui.badge(L('plan.soon'), 'info', 'clock');
      else if (f.reason === 'expired') st = ui.badge(L('plan.f.expired'), 'warn', 'warning');
      else st = ui.badge(L('plan.f.upgrade'), 'warn', 'lock');
      var b = ui.btn(L('plan.f.more'), { sm: true, kind: 'ghost', icon: 'help-i' }); ui.act(b, function () { TP.plan.explain(k); });
      list.appendChild(h('li', { class: 'plan-f' }, h('span', { class: 'plan-fn' }, f.pro ? ui.icon('pro', 15, 'ci pro-ic') : ui.icon('check', 15, 'ci'), h('span', null, TP.plan.name(k))), h('span', { class: 'plan-fb' }, ui.badge(f.pro ? L('plan.pro') : L('plan.tier.free'), f.pro ? 'pro' : 'neutral'), st, b)));
    });
    if (keys.length) { el.planBox.appendChild(h('h3', { class: 'plan-fh' }, t('plan.features'), hl('plan.features'))); el.planBox.appendChild(list); }
    var up = ui.btn(L('plan.upgrade'), { kind: 'primary', icon: 'pro' });
    ui.avail(up, t('plan.upgradeSoon')); ui.act(up, function () { ui.toast(t('plan.upgradeSoon'), 'warn', 4200); });
    el.planBox.appendChild(h('div', { class: 'row wrap set-btns' }, up, h('span', { class: 'muted sm' }, t('plan.freeNow'))));
  }

  /* ================= 关于 ================= */
  function aboutCard() {
    var c = card('about', 'info', L('set.about.title'), null, 'settings.about');
    el.envBox = h('div');
    c.appendChild(el.envBox);
    c.appendChild(h('div', { class: 'muted sm set-credits' }, ui.icon('library', 14, 'ci'), h('span', { class: 'cr-t' })));
    c.appendChild(h('div', { class: 'row wrap set-links' }, xlink(TP.auth.url('account_url'), L('set.about.site')), xlink(REPO, L('set.about.repo')), xlink(NOTICES, 'THIRD_PARTY_NOTICES.md')));
    el.about = c;
    return c;
  }
  function renderAbout() {
    var p = (S.state && S.state.platform) || {}, e = (S.state && S.state.env) || {}, v = TP.updates.version();
    ui.memo(el.envBox, JSON.stringify([p, e.shortcut, TP.cfg.proxyPort, TP.cfg.uiPort, v]), function () {
      var f = document.createDocumentFragment();
      f.appendChild(row(t('set.about.version'), 'enana ' + (v ? 'v' + v : '—')));
      if (p.os) f.appendChild(row(t('set.about.system'), fmt0(p)));
      f.appendChild(row(t('set.about.command'), h('code', null, 'enana')));
      if (e.shortcut) f.appendChild(row(t('set.about.shortcut'), h('code', null, String(e.shortcut))));
      f.appendChild(row(t('set.about.ports'), t('set.about.portsVal', { proxy: TP.cfg.proxyPort, ui: TP.cfg.uiPort })));
      return f;
    });
    setText(el.about.querySelector('.cr-t'), t('set.about.credits'));
  }
  function fmt0(p) { return [TP.fmt.os(p.os), p.osver, p.arch].filter(Boolean).join(' · '); }
})();
