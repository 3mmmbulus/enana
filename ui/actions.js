/* enana · actions.js — 全局操作 (更新规则 / 重启·启动服务 / 断开连接 / 监控 / 代理模式)
 * 每个操作都: 先 confirmDialog 说明「什么会变」→ 执行 → toast 结果。
 * 每个按钮的文字和「是否可用」由 xxxState() 统一计算; TP.bindBtn 把按钮绑上去, 状态变化时自动刷新 (所以不会有「点了没反应」的死按钮)。 */
(function () {
  'use strict';
  var TP = window.TP, S = TP.S, h = TP.h, ui = TP.ui, setText = TP.setText, I = window.I18N, t = I.t, L = I.L;
  function pt(k) { return TP.pt ? TP.pt(k) : k; }   // 平台专用文案 (见 core.js 的 TP.pt)
  var A = TP.actions = {};
  var rules = { running: false, pct: 0, doneAt: 0 }, restarting = false, killing = false;
  var changingCapture = false;
  A.setNetworkMode = async function (mode, confirmed) {
    if (changingCapture) return false;
    var why = TP.why.helper();
    if (why) { ui.toast(why, 'warn'); return false; }
    if (!confirmed && !await ui.confirmDialog({ title: t('set.network.title'), message: t('set.network.confirm'), detail: t(pt('set.network.note')), confirmText: t(mode === 'tun' ? 'apps.capture.enable' : 'common.apply') })) return false;
    changingCapture = true;
    try {
      await TP.jobs.runInDock(t('set.network.title'), function () { return TP.helper('POST', '/api/network-mode', { form: { mode: mode } }); });
      await TP.loadState(); await TP.loadSettings();
      if (mode === 'tun' && !(S.state && S.state.proxy && S.state.proxy.tun_ready)) throw new Error(t('set.network.notReady'));
      return true;
    } finally { changingCapture = false; }
  };
  A.offerAppCapture = async function (name) {
    var choice = await ui.modal({ title: t('apps.capture.title'), size: 'md', icon: 'warning', iconKind: 'warn',
      body: h('div', null, h('p', null, t(pt('apps.capture.choose'), { name: name })), h('p', { class: 'muted sm' }, t(pt('set.network.note')))),
      actions: [
        { label: t('common.cancel'), cancel: true },
        { label: t('apps.capture.limited'), value: 'system' },
        { label: t('apps.capture.enable'), kind: 'primary', value: 'tun', autofocus: true }
      ] }).closed;
    if (choice === 'tun') return A.setNetworkMode('tun', true);
    return choice === 'system';
  };

  /* ---------- 按钮状态绑定 ---------- */
  var bound = [];
  TP.bindBtn = function (el, fn) { bound.push({ el: el, fn: fn }); fn(el); return el; };
  TP.syncBtns = function () {
    bound = bound.filter(function (b) { return document.contains(b.el) || !b.el._seen; });    // 弹窗里的按钮关闭后自动解除
    bound.forEach(function (b) { b.el._seen = b.el._seen || document.contains(b.el); try { b.fn(b.el); } catch (e) { console.error(e); } });
  };
  ['state', 'clash', 'helper', 'conns', 'monitor', 'applying', 'auth', 'mode', 'update', 'testing', 'proxies', 'apps', 'lang', 'proxy'].forEach(function (ev) { TP.on(ev, TP.syncBtns); });
  setInterval(function () { if (!document.hidden) TP.syncBtns(); }, 1000);          // 「刚刚更新」这类带倒计时的文字

  /* st: {label, icon, reason, fix:{label,fn}, muted, busy} -> 刷新按钮的文字 / 图标 / 「暂不可用」状态 */
  function apply(b, st) {
    ui.setBtn(b, st.label, st.icon);
    ui.avail(b, st.reason || '', st.fix || null);
    b._renderBusy = !!st.busy; b.disabled = !!st.busy || !!b._busy;
    b.classList.toggle('is-muted', !!st.muted); b.classList.toggle('is-busy', !!st.busy || !!b._busy);
    if (st.busy || b._busy) b.setAttribute('aria-busy', 'true'); else b.removeAttribute('aria-busy');
    if (b.classList.contains('rowbtn') && !st.reason) { b._tip = st.label; b.title = st.label; }      // 顶栏上窄屏只显示图标时, 用提示补上文字
  }
  TP.paintBtn = apply;

  /* ================= 更新规则 ================= */
  A.rulesState = function (o) {
    var env = (S.state && S.state.env) || {}, upd = +env.rules_updated || 0, missing = env.rules_missing || [];
    var recent = Date.now() - rules.doneAt < 60000 || (upd > 0 && Date.now() / 1000 - upd < 60);
    var base = { label: t(missing.length ? 'act.rules.missing' : ((o && o.labelKey) || 'act.rules.update')), icon: 'download-cloud' }, why;
    if (rules.running) return { label: t('act.rules.running', { pct: Math.round(rules.pct) }), icon: 'refresh', busy: true, reason: t('act.rules.runningReason') };
    why = TP.why.helper();
    if (why) { base.reason = why; return base; }
    if (missing.length) return base;
    if (recent) return { label: t('act.rules.recent'), icon: 'success', muted: true, reason: t('act.rules.recentReason') };
    return base;
  };
  A.rulesRunning = function () { return rules.running; };
  A.updateRules = async function () {
    var st = A.rulesState();
    if (st.reason) { ui.toast(st.reason, 'warn'); return; }
    var env = (S.state && S.state.env) || {}, missing = env.rules_missing || [], title = t(missing.length ? 'act.rules.jobMissing' : 'act.rules.job');
    var ok = await ui.confirmDialog({
      title: t(missing.length ? 'act.rules.confirmMissingTitle' : 'act.rules.confirmTitle'),
      message: missing.length ? t('act.rules.msgMissing', { n: missing.length, list: missing.slice(0, 4).join(', ') + (missing.length > 4 ? ' …' : '') }) : t('act.rules.msgAll'),
      detail: [t('act.rules.d1'), t('act.rules.d2')], confirmText: t(missing.length ? 'act.rules.goMissing' : 'act.rules.go')
    });
    if (!ok) return;
    rules.running = true; rules.pct = 0; TP.syncBtns();
    var r = await TP.jobs.runInDock(title, function () { return TP.helper('POST', '/api/update-rules'); }, {
      mapCard: function (card) { return { fromJob: function (j) { rules.pct = +j.pct || 0; card.fromJob(j); TP.syncBtns(); } }; }
    });
    rules.running = false; if (r.ok) rules.doneAt = Date.now();
    TP.syncBtns(); TP.emit('rules-updated');
  };
  TP.bindRulesBtn = function (btn, o) {
    TP.bindBtn(btn, function (b) { apply(b, A.rulesState(o)); });
    ui.act(btn, A.updateRules);
    return btn;
  };

  /* ================= 重启 / 启动服务 ================= */
  A.restartState = function () {
    var stopped = TP.coreStopped() || (S.state && S.state.env && S.state.env.service === false && S.clash === 'down');
    var st = { label: t(stopped ? 'act.restart.start' : 'act.restart.label'), icon: stopped ? 'power' : 'restart' }, why = TP.why.helper();
    if (restarting) return { label: t(stopped ? 'act.restart.startBusy' : 'act.restart.busy'), icon: st.icon, busy: true, reason: t(stopped ? 'act.restart.startBusyReason' : 'act.restart.busyReason') };
    if (why) st.reason = why;
    st.stopped = !!stopped;
    return st;
  };
  A.restart = async function () {
    var st = A.restartState();
    if (st.reason) { ui.toast(st.reason, 'warn'); return; }
    var ok = await ui.confirmDialog(st.stopped
      ? { title: t('act.restart.startTitle'), message: t('act.restart.startMsg'), detail: [t('act.restart.startD1'), t('act.restart.startD2')], confirmText: t('act.restart.start'), kind: 'success', confirmIcon: 'power' }
      : { title: t('act.restart.title'), message: t('act.restart.msg'), detail: [t('act.restart.d1'), t('act.restart.d2')], confirmText: t('act.restart.label'), kind: 'warning', confirmIcon: 'restart' });
    if (!ok) return;
    restarting = true; TP.syncBtns();
    try { await TP.jobs.runInDock(t(st.stopped ? 'act.restart.startJob' : 'act.restart.job'), function () { return TP.helper('POST', '/api/restart'); }); }
    finally { restarting = false; TP.syncBtns(); }
  };
  TP.bindRestartBtn = function (btn) {
    TP.bindBtn(btn, function (b) { apply(b, A.restartState()); });
    ui.act(btn, A.restart);
    return btn;
  };

  /* ================= 断开连接 ================= */
  A.killState = function () {
    var n = S.monitor ? S.conns.length : null, why = TP.why.clash();
    if (killing) return { label: t('act.kill.busy'), icon: 'disconnect', busy: true, reason: t('act.kill.busyReason') };
    if (n === null) return { label: t('act.kill.label'), icon: 'disconnect', reason: why };
    if (n === 0) return { label: t('act.kill.none'), icon: 'disconnect', muted: true, reason: why || t('act.kill.noneReason') };
    return { label: t('act.kill.count', { n: n }), icon: 'disconnect', reason: why };
  };
  A.disconnectAll = async function () {
    var n;
    if (S.monitor) n = S.conns.length;
    else { var r = await TP.clash('GET', '/connections'); n = ((r && r.connections) || []).length; }     // 监控暂停时, 只在点击时读取一次
    if (!n) { ui.toast(t('act.kill.noneReason'), 'warn'); return; }
    var ok = await ui.confirmDialog({ title: t('act.kill.title'), message: t('act.kill.msg', { n: n }), detail: [t('act.kill.d1'), t('act.kill.d2')], confirmText: t('act.kill.go', { n: n }), danger: true });
    if (!ok) return;
    killing = true; TP.syncBtns();
    try { await TP.clash('DELETE', '/connections'); TP.audit('kill', { scope: 'all', n: n }); ui.toast(t('act.kill.done', { n: n }), 'ok'); }
    finally { killing = false; TP.syncBtns(); if (TP.pollers.conns) setTimeout(TP.pollers.conns.kick, 300); }
  };
  TP.bindKillBtn = function (btn) {
    TP.bindBtn(btn, function (b) { apply(b, A.killState()); });
    ui.act(btn, A.disconnectAll);
    return btn;
  };

  /* ================= 监控 (只影响显示, 不碰代理) ================= */
  A.setMonitor = async function (on) {
    if (on === S.monitor) { ui.toast(t(on ? 'act.mon.alreadyOn' : 'act.mon.alreadyOff'), ''); return; }
    var ok = await ui.confirmDialog({
      title: t(on ? 'act.mon.resumeTitle' : 'act.mon.pauseTitle'), message: t(on ? 'act.mon.resumeMsg' : 'act.mon.pauseMsg'),
      detail: t('act.mon.detail'), confirmText: t(on ? 'act.mon.resumeGo' : 'act.mon.pauseGo'), rememberKey: 'monitor'
    });
    if (!ok) return;
    TP.setMonitor(on);
    ui.toast(t(on ? 'act.mon.resumed' : 'act.mon.paused'), 'ok', 2400);
  };

  /* ================= 代理总开关 + 代理模式 (POST /api/proxy on=0|1 和/或 mode=auto|global; 热切换, 不重启核心) =================
   * 三种状态: 关闭 (默认: 刚安装 / 刚登录 / 退出账号之后 —— 全部直连, 不经过任何代理服务器) · 自动模式 (智能分流) · 全局代理 (除本地网络 / 你手动指定的应用与网站 / 固定出口类服务外都走代理)。
   * 总开关和模式是两个独立的设置: 关闭时模式也能先选好 (会保存, 开启后生效)。同一时间只允许一个请求在进行, 期间控件显示原因而不是失灵。 */
  var proxyBusy = null, pendingMode = '';                            // proxyBusy: null | 'on' | 'off' | 'mode' (请求进行中)
  A.proxyOn = function () { var p = S.state && S.state.proxy; return p && typeof p.enabled === 'boolean' ? p.enabled : null; };
  A.proxyMode = function () { var p = S.state && S.state.proxy; return p ? (p.mode === 'global' ? 'global' : 'auto') : null; };       // 旧版辅助服务没有 mode 字段: 当作自动模式
  A.proxyModeShown = function () { return proxyBusy === 'mode' && pendingMode ? pendingMode : A.proxyMode(); };                       // 请求进行中先显示用户选的
  A.proxyBusy = function () { return proxyBusy; };
  A.proxyState = function () {
    var on = A.proxyOn(), why = TP.why.helper();
    if (proxyBusy === 'on' || proxyBusy === 'off') return { on: on, busy: true, icon: 'power', label: t(proxyBusy === 'on' ? 'proxy.turningOn' : 'proxy.turningOff'), reason: t('proxy.busyReason') };
    return { on: on, icon: 'power', label: on === true ? t('proxy.stateOn') : on === false ? t('proxy.stateOff') : t('proxy.stateUnknown'), reason: proxyBusy ? t('proxy.busyReason') : why };
  };
  /* 为什么现在不能改模式 / 开关 ('' = 可以) */
  A.proxyWhy = function () { return proxyBusy ? t('proxy.busyReason') : TP.why.helper() || (S.state ? '' : t('proxy.loading')); };
  function keepState(r, on) {
    var en = r && typeof r.enabled === 'boolean' ? r.enabled : on, mode = r && (r.mode === 'global' || r.mode === 'auto') ? r.mode : A.proxyMode() || 'auto';
    if (S.state) S.state.proxy = { enabled: en, mode: mode };
    return { enabled: en, mode: mode };
  }
  function proxyDone() { proxyBusy = null; pendingMode = ''; TP.emit('proxy', A.proxyOn()); TP.syncBtns(); TP.loadState(); setTimeout(TP.loadProxies, 400); }
  /* ---------- 系统代理 ----------
   * 浏览器和多数 App 只有走「系统代理」才会进入 enana (System Proxy 接管方式)。以前总开关打开后系统代理仍然没开, 必须去终端输入 enana on (还要输密码) ——
   * 现在: 打开总开关会一并开启系统代理 (后台任务, macOS 可能弹出「输入 Mac 登录密码」的原生窗口); 没开成功 / 被其它软件占用时, 顶部提示条和概览里都有「一键开启」按钮。 */
  var sysproxyBusy = false;
  A.sysproxyBusy = function () { return sysproxyBusy; };
  A.sysproxyNeeded = function () {        // 总开关开着、用的是 System Proxy 接管方式、核心在运行, 但系统代理没有指向 enana
    var st = S.state;
    return !!(st && st.proxy && st.env && st.proxy.enabled === true && st.proxy.network_mode !== 'tun' && st.env.sysproxy === false && st.env.service !== false);
  };
  async function runSysproxyJob(start) {
    sysproxyBusy = true; TP.emit('proxy', A.proxyOn()); TP.syncBtns();
    try { return await TP.jobs.runInDock(t('sysproxy.job'), start); }
    finally { sysproxyBusy = false; try { await TP.loadState(); } catch (e) { /* 状态稍后会自己刷新 */ } TP.emit('proxy', A.proxyOn()); TP.syncBtns(); }
  }
  A.fixSysproxy = async function (confirmed) {
    if (sysproxyBusy) { ui.toast(t(pt('sysproxy.busy')), 'warn'); return; }
    var why = TP.why.helper(); if (why) { ui.toast(why, 'warn'); return; }
    if (!confirmed && !await ui.confirmDialog({ title: t('sysproxy.fix.title'), message: t(pt('sysproxy.fix.msg')), detail: [t(pt('sysproxy.fix.d1')), t('sysproxy.fix.d2'), t('sysproxy.fix.d3')], confirmText: t('sysproxy.fix.go'), kind: 'success', confirmIcon: 'power' })) return;
    await runSysproxyJob(function () { return TP.helper('POST', '/api/sysproxy', { form: { on: 1 } }); });
  };
  /* POST /api/proxy 的 sysproxy 字段: on = 已经指向 enana · foreign = 系统里正用着别的代理设置 (不擅自覆盖) · pending = 已在后台开启 (job) */
  A.followSysproxy = async function (sp) {
    if (!sp) return;
    if (sp.state === 'foreign') { ui.toast(t('sysproxy.foreign'), 'warn', 14000, { action: { label: t('sysproxy.takeover'), fn: TP.safe(function () { return A.fixSysproxy(false); }) } }); return; }
    if (sp.state === 'pending' && sp.job) await runSysproxyJob(function () { return Promise.resolve({ job: sp.job }); });
  };
  A.setProxy = async function (on) {
    if (proxyBusy) { ui.toast(t('proxy.busyReason'), 'warn'); return; }
    var why = TP.why.helper(); if (why) { ui.toast(why, 'warn'); return; }
    var cur = A.proxyOn();
    if (cur === on) { ui.toast(t(on ? 'proxy.alreadyOn' : 'proxy.alreadyOff'), ''); return; }
    var onDetail = [t('proxy.on.d1'), t('proxy.on.d2')];
    if (on && S.state && S.state.proxy && S.state.proxy.network_mode !== 'tun' && S.state.env && S.state.env.sysproxy === false) onDetail.push(t(pt('proxy.on.d3')));      // 系统代理还没指向 enana: 说明会一并开启, 以及 macOS 可能弹出密码窗口
    var ok = await ui.confirmDialog(on
      ? { title: t('proxy.on.title'), message: t('proxy.on.msg'), detail: onDetail, confirmText: t('proxy.on.go'), kind: 'success', confirmIcon: 'power' }
      : { title: t('proxy.off.title'), message: t('proxy.off.msg'), detail: [t('proxy.off.d1'), t('proxy.off.d2'), t('proxy.off.d3')], confirmText: t('proxy.off.go'), danger: true, confirmIcon: 'power' });
    if (!ok) return;
    proxyBusy = on ? 'on' : 'off'; TP.emit('proxy', cur); TP.syncBtns();
    var sp = null;
    try {
      var r = await TP.helper('POST', '/api/proxy', { form: { on: on ? 1 : 0 }, timeout: 25000 }), st = keepState(r, on);
      sp = r && r.sysproxy || null;
      ui.toast(t(st.enabled ? 'proxy.onDone' : 'proxy.offDone'), 'ok', 4200);
    } catch (e) {
      if (e && e.code === 'E_NOT_RUNNING') ui.toast(t('proxy.err.notRunning'), 'warn', 8000, { action: { label: t('act.restart.start'), fn: TP.safe(A.restart) } });
      else throw e;
    } finally { proxyDone(); }
    if (sp) await A.followSysproxy(sp);       // 总开关已经打开了; 系统代理这一步失败不会撤销它, 只是提示 + 留下一键重试
  };
  /* 切换代理模式 (自动模式 <-> 全局代理): 先确认, 说明两种模式的区别; 代理关闭时也允许先选好 (保存, 开启后生效) */
  A.setProxyMode = async function (m) {
    m = m === 'global' ? 'global' : 'auto';
    if (proxyBusy) { ui.toast(t('proxy.busyReason'), 'warn'); return; }
    var why = TP.why.helper(); if (why) { ui.toast(why, 'warn'); return; }
    var cur = A.proxyMode(), on = A.proxyOn();
    if (cur === m) { ui.toast(t('pmode.same', { name: t('pmode.' + m) }), ''); return; }
    var detail = ['auto', 'global'].map(function (k) { return h('span', null, h('b', null, t('pmode.' + k)), ' — ', t('pmode.' + k + '.sub')); });      // 两种模式的区别, 各一行
    if (m === 'global') detail.push(h('span', { class: 'warn-t' }, t('pmode.global.warn')));                                                         // 全局代理: 国内网站也会走代理, 可能变慢
    if (on === false) detail.push(t('pmode.offLine'));
    var ok = await ui.confirmDialog({ title: t('pmode.' + m + '.title'), message: t('pmode.' + m + '.msg'), detail: detail, confirmText: t('pmode.' + m + '.go'), kind: m === 'global' ? 'warning' : 'primary', confirmIcon: m === 'global' ? 'globe' : 'auto' });
    if (!ok) return;
    proxyBusy = 'mode'; pendingMode = m; TP.emit('proxy', on); TP.syncBtns();
    try {
      var st = keepState(await TP.helper('POST', '/api/proxy', { form: { mode: m }, timeout: 25000 }), on);
      ui.toast(t((st.enabled === false ? 'pmode.saved.' : 'pmode.done.') + st.mode), 'ok', 4600);
    } finally { proxyDone(); }
  };

  /* 「监控」开关: 放在概览的曲线卡片和「连接」页工具栏里 (只影响页面上的数据显示, 代理照常工作) */
  TP.monitorSwitch = function () {
    var inp = h('input', { type: 'checkbox', role: 'switch' }); inp.checked = S.monitor;
    ui.switchAct(inp, function () { return S.monitor; }, function (want) { return A.setMonitor(want); });
    TP.on('monitor', function (on) { inp.checked = on; });
    return h('label', { class: 'tgl', title: L('mon.title') }, h('span', { class: 'sw' }, inp, h('span', { class: 'sw-ui' })), h('span', null, L('mon.label')));
  };

  /* 应用 / 网站页顶部的小提示: 代理总开关关闭时提醒「这些设置在代理开启后才生效」; 开启后说明当前模式下这些设置怎么起作用 (自己随状态显示 / 隐藏) */
  TP.proxyNote = function () {
    var off = h('p', { class: 'hint warn proxy-note', hidden: true }, ui.icon('power', 15, 'ci'), h('span', null, L('proxy.pageNote')));
    var mi = ui.icon('auto', 15, 'ci'), mt = h('span'), mode = h('p', { class: 'hint proxy-note pmode-hint', hidden: true }, mi, mt);
    var box = h('div', { class: 'proxy-notes' }, off, mode), icon = 'auto';
    var upd = function () {
      var m = A.proxyMode(), o = A.proxyOn();
      off.hidden = o !== false; mode.hidden = !m || o === false;
      if (m) {
        setText(mt, t('pmode.hint.' + m));
        var want = m === 'global' ? 'globe' : 'auto';
        if (want !== icon) { icon = want; var n = ui.icon(want, 15, 'ci'); mode.replaceChild(n, mode.firstChild); }
      }
    };
    TP.on('proxy', upd); TP.on('state', upd); TP.on('lang', upd); upd();
    return box;
  };

  /* 代理模式控件 (概览 / 设置里共用): 分段开关 + 当前模式的说明 + 代理关闭时的提示 */
  TP.modeControl = function () {
    var seg = ui.seg(L('pmode.aria'), [{ v: 'mode-auto', label: L('pmode.auto'), icon: 'auto' }, { v: 'mode-global', label: L('pmode.global'), icon: 'globe' }],
      function (v) { paint(); return TP.safe(function () { return A.setProxyMode(v === 'mode-global' ? 'global' : 'auto'); })(); });   // 先恢复显示, 确认之后才真正改变
    var desc = h('p', { class: 'muted sm pmode-d' });
    var off = h('p', { class: 'hint warn pmode-off', hidden: true }, ui.icon('power', 15, 'ci'), h('span', null, L('pmode.offHint')));
    var el = h('div', { class: 'pmode' }, seg.el, desc, off);
    function paint() {
      var m = A.proxyModeShown(), why = A.proxyWhy();
      seg.set(m ? 'mode-' + m : '');
      seg.avail('mode-auto', why); seg.avail('mode-global', why);
      setText(desc, m ? t('pmode.' + m + '.desc') : '');
      off.hidden = !(m && A.proxyOn() === false);
    }
    ['state', 'proxy', 'helper', 'lang'].forEach(function (ev) { TP.on(ev, paint); });
    paint();
    return { el: el, paint: paint };
  };

  /* ================= 代理模式: 规则 / 全局直连 ================= */
  function modeOf(v) { var l = String(v || '').toLowerCase(); return l === 'direct' ? 'Direct' : l ? 'Rule' : ''; }
  A.modeOf = modeOf;
  A.setMode = async function (v) {
    var why = TP.why.clash();
    if (why) { ui.toast(why, 'warn'); return; }
    if (modeOf(S.mode) === v) { ui.toast(t('act.mode.same', { name: t(v === 'Direct' ? 'act.mode.direct' : 'act.mode.rule') }), ''); return; }
    var ok = await ui.confirmDialog(v === 'Direct'
      ? { title: t('act.mode.toDirectTitle'), message: t('act.mode.toDirectMsg'), detail: [t('act.mode.toDirectD1'), t('act.mode.toDirectD2')], confirmText: t('act.mode.toDirectGo') }
      : { title: t('act.mode.toRuleTitle'), message: t('act.mode.toRuleMsg'), detail: t('act.mode.toRuleD'), confirmText: t('act.mode.toRuleGo') });
    if (!ok) return;
    var want = (S.modes || []).filter(function (m) { return String(m).toLowerCase() === v.toLowerCase(); })[0] || v, prev = S.mode;
    S.mode = want; TP.emit('mode');
    try { await TP.clash('PATCH', '/configs', { mode: want }); }
    catch (e) { S.mode = prev; TP.emit('mode'); throw e; }
    ui.toast(t(v === 'Direct' ? 'act.mode.toDirectDone' : 'act.mode.toRuleDone'), 'ok');
  };
})();
