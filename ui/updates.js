/* enana · updates.js — 检查更新 / 更新提示卡片 / 更新流程
 * GET /api/update/check[?force=1] -> {ok,current,latest,available,checked,notes,url,core:{current,latest,available},error?}
 * POST /api/update/apply?what=app|core -> {ok, job}
 * 检查时机: 登录后、每 TP.CFG.UPDATE_CHECK_HOURS 小时、用户点「检查更新」(force=1)。
 * 「暂不更新」只记住被忽略的那个版本 (localStorage); 更新的版本出现时会再次提示, 顶栏/侧栏指示器和「设置」页始终显示。
 * 点侧栏 / 账号菜单里的「有新版本」: 在当前页面直接弹出更新窗口 (U.openDialog), 不跳转到「设置」; 没有新版本时才去「设置」。 */
(function () {
  'use strict';
  var TP = window.TP, S = TP.S, h = TP.h, ui = TP.ui, I = window.I18N, t = I.t;
  var U = TP.updates = {};
  S.update = { checking: false, loaded: false, available: false, current: '', latest: '', checked: 0, notes: '', notesZh: '', notesEn: '', url: '', core: null, error: '', errCode: '' };
  var applying = false, notesOpen = false, inds = [];

  U.version = function () { return S.update.current || (S.state && S.state.version) || TP.cfg.version || ''; };
  U.applying = function () { return applying; };
  /* 更新说明: 后端按 X-Enana-Lang 给 notes, 同时可能带 notes_zh / notes_en; 优先用当前语言的 */
  U.notes = function () {
    var u = S.update, own = I.lang === 'zh' ? u.notesZh : I.lang === 'en' ? u.notesEn : '';
    return own || u.notes || u.notesEn || u.notesZh || '';
  };

  /* /api/state 里带的简要信息 (available/latest/checked): 完整检查没做过之前先用它 */
  TP.on('state', function (st) {
    var u = st && st.update;
    if (!u || applying) return;
    var changed = false;
    if (!S.update.loaded) { S.update.available = !!u.available; S.update.latest = u.latest || S.update.latest; S.update.checked = +u.checked || S.update.checked; changed = true; }
    else if (u.available && u.latest && u.latest !== S.update.latest) { U.check(false); }       // 后台发现了更新的版本
    if (changed) { TP.emit('update'); renderCard(); }
  });

  /* ---------- 检查 ---------- */
  U.check = async function (force) {
    if (S.locked || S.update.checking) return;
    S.update.checking = true; TP.emit('update');
    try {
      var r = await TP.helper('GET', '/api/update/check', { q: { force: force ? 1 : '' }, timeout: force ? 45000 : 25000 });
      var u = S.update;
      u.current = r.current || u.current; u.latest = r.latest || r.current || u.latest; u.available = !!r.available;
      u.checked = +r.checked || Math.floor(Date.now() / 1000); u.notes = r.notes ? String(r.notes) : ''; u.notesZh = r.notes_zh ? String(r.notes_zh) : ''; u.notesEn = r.notes_en ? String(r.notes_en) : ''; u.url = r.url ? String(r.url) : '';
      u.core = r.core || null; u.error = typeof r.error === 'string' ? r.error : (r.error ? t('upd.err.generic') : ''); u.errCode = r.code ? String(r.code) : ''; u.loaded = true;
      if (force) {
        if (u.error) ui.toast(t('upd.toast.partial', { reason: u.error }), 'warn');
        else ui.toast(r.available ? t('upd.toast.found', { v: u.latest }) : t('upd.toast.latest', { v: u.current || U.version() }), 'ok');
      }
    } catch (e) {
      if (e && e.kind === 'auth') { S.update.checking = false; TP.emit('update'); return; }
      S.update.error = e.kind === 'unreachable' ? t('upd.err.helperDown') : TP.errMsg(e);
      S.update.errCode = e.code || (e.kind === 'unreachable' ? 'E_NETWORK' : '');
      if (force) ui.toast(t('upd.toast.failed', { reason: S.update.error }), 'warn');
    } finally { S.update.checking = false; TP.emit('update'); renderCard(); }
  };
  U.start = function () {
    U.check(false);
    setInterval(function () { if (!S.locked) U.check(false); }, TP.CFG.UPDATE_CHECK_HOURS * 3600 * 1000);
  };

  /* 「检查更新」按钮的文字与状态 (设置页用) */
  U.checkLabel = function () {
    var u = S.update;
    if (u.checking) return { label: t('upd.chk.checking'), reason: t('upd.chk.reason'), icon: 'refresh' };
    if (u.error && !u.available) return { label: t('upd.chk.err', { why: u.errCode === 'E_NETWORK' || /network|timeout/i.test(u.error) ? t('upd.chk.errNet') : u.error.slice(0, 14) }), icon: 'refresh', err: true };
    if (u.available) return { label: t('upd.chk.new', { v: u.latest }), icon: 'update', fresh: true };
    return { label: u.checked ? t('upd.chk.okAt', { time: TP.fmt.clock(u.checked) }) : t('upd.chk.ok'), icon: 'success', ok: true };
  };

  /* ---------- 指示器 (顶栏 / 侧栏): 「v2.1.0 ✓ 最新」或闪动的「有新版本 v2.2.0」 ---------- */
  function paintInd(it) {
    var el = it.el, u = S.update, v = U.version(), kind, text, icon, tip;
    if (u.available) { kind = 'new'; text = t('upd.ind.new', { v: u.latest }); icon = 'update'; tip = t('upd.ind.newTip', { v: u.latest }); }
    else if (u.checking && !u.loaded) { kind = 'checking'; text = t('upd.ind.checking'); icon = 'refresh'; tip = t('upd.ind.checkingTip'); }
    else if (u.error && !u.loaded) { kind = 'err'; text = v ? 'v' + v : t('upd.ind.unknown'); icon = 'warning'; tip = t('upd.ind.errTip', { reason: u.error }); }
    else { kind = 'ok'; text = v ? t('upd.ind.ok', { v: v }) : t('upd.ind.okNoV'); icon = 'success'; tip = u.checked ? t('upd.ind.okTipAt', { time: TP.fmt.clock(u.checked) }) : t('upd.ind.okTip'); }
    var cls = 'upd-ind ' + kind + (it.cls ? ' ' + it.cls : '');
    if (el.className !== cls) el.className = cls;
    if (el._k !== icon) { el._k = icon; var ic = ui.icon(icon, it.size || 16, 'ui-ic'); if (el._ic && el._ic.parentNode === el) el.replaceChild(ic, el._ic); else el.insertBefore(ic, el.firstChild); el._ic = ic; }
    if (!el._lb) { el._lb = h('span', { class: 'ui-lb' }); el.appendChild(el._lb); }
    TP.setText(el._lb, text); el.title = tip; el.setAttribute('aria-label', text);
  }
  U.bindIndicator = function (el, opt) {
    var it = { el: el, cls: (opt && opt.cls) || '', size: (opt && opt.size) || 16 };
    inds.push(it); paintInd(it);
    el.addEventListener('click', function () { U.openDialog(); });
  };
  TP.on('update', function () { inds.forEach(paintInd); });
  TP.on('lang', function () { inds.forEach(paintInd); renderCard(); });

  /* ---------- 更新窗口: 点「有新版本」时在当前页面直接弹出 (版本变化 / 更新内容 / 注意事项 / 更新 · 暂不更新) ---------- */
  var dlg = null;
  U.openDialog = function () {
    var u = S.update;
    if (!u.available || !u.latest) {                      // 没有新版本: 在「设置」页上点它 = 重新检查一次 (有提示), 在别的页面 = 去「设置」
      if (TP.tab === 'settings') U.check(true); else TP.go('settings');
      return;
    }
    if (dlg) return;
    if (applying) { ui.toast(t('upd.apply.busy'), 'warn'); return; }
    var latest = u.latest, cur = u.current || U.version();
    dlg = ui.modal({
      title: t('upd.card.title', { v: latest }), icon: 'update', iconKind: 'pri', size: 'md',
      body: h('div', { class: 'upd-dlg' },
        h('p', { class: 'cfm-m' }, t('upd.apply.msgApp', { from: cur, to: latest })),
        h('b', { class: 'sm' }, t('upd.dlg.notes')),
        h('pre', { class: 'upd-notes' }, U.notes() || t('upd.card.noNotes')),
        h('ul', { class: 'cfm-list' }, h('li', null, t('upd.apply.dApp1')), h('li', null, t('upd.apply.dApp2')))),
      actions: [
        { label: t('upd.card.later'), onClick: function () { TP.ls.set('update.dismissed', latest); notesOpen = false; renderCard(); ui.toast(t('upd.card.dismissed', { v: latest }), '', 4500); } },
        { label: t('upd.card.update'), kind: 'primary', icon: 'update', autofocus: true, onClick: function (api) { api.close(true); return U.apply('app', true); } }
      ],
      onClose: function () { dlg = null; }
    });
  };

  /* ---------- 右下角「发现新版本」卡片 ---------- */
  function renderCard() {
    var box = TP.byId('updcard');
    if (!box) return;
    var u = S.update, dismissed = TP.ls.get('update.dismissed', ''), show = !!(u.available && u.latest && dismissed !== u.latest && !applying && !S.locked);
    ui.memo(box, show ? [u.latest, u.current, notesOpen, U.notes().length].join('|') : 'hide', function () {
      if (!show) return null;
      var bUp = ui.btn(t('upd.card.update'), { kind: 'primary', sm: true, icon: 'update' }), bLater = ui.btn(t('upd.card.later'), { sm: true });
      ui.act(bUp, function () { return U.apply('app'); });
      bLater.addEventListener('click', function () { TP.ls.set('update.dismissed', u.latest); notesOpen = false; renderCard(); ui.toast(t('upd.card.dismissed', { v: u.latest }), '', 4500); });
      var notesLink = h('button', { class: 'upd-link', type: 'button', 'aria-expanded': notesOpen ? 'true' : 'false', on: { click: function () { notesOpen = !notesOpen; renderCard(); } } }, ui.icon(notesOpen ? 'chevron-up' : 'chevron-down', 14, 'ci'), t(notesOpen ? 'upd.card.hideNotes' : 'upd.card.notes'));
      return h('div', { class: 'upd-card', role: 'status' },
        h('div', { class: 'upd-h' }, h('span', { class: 'upd-ic' }, ui.icon('update', 20)), h('div', null, h('b', null, t('upd.card.title', { v: u.latest })), h('div', { class: 'muted sm' }, t('upd.card.sub', { cur: u.current || U.version() })))),
        notesLink, notesOpen ? h('pre', { class: 'upd-notes' }, U.notes() || t('upd.card.noNotes')) : null,
        h('div', { class: 'upd-a' }, bUp, bLater));
    });
  }
  TP.on('auth', function () { renderCard(); });

  /* ---------- 更新 (app = 仪表盘 + 辅助服务, core = sing-box 核心) ---------- */
  U.apply = async function (what, confirmed) {          // confirmed: 调用方已经弹过确认窗口 (更新窗口里的「更新」按钮), 不再重复确认
    var isCore = what === 'core', u = S.update, tgt = isCore ? (u.core && u.core.latest) : u.latest, from = isCore ? (u.core && u.core.current) : U.version();
    var why = TP.why.helper();
    if (why) { ui.toast(why, 'warn'); return; }
    if (applying) { ui.toast(t('upd.apply.busy'), 'warn'); return; }
    if (!tgt || !(isCore ? (u.core && u.core.available) : u.available)) { ui.toast(t('upd.apply.latest'), ''); return; }
    var ok = confirmed || await ui.confirmDialog({
      title: t(isCore ? 'upd.apply.titleCore' : 'upd.apply.titleApp'),
      message: t(isCore ? 'upd.apply.msgCore' : 'upd.apply.msgApp', { from: from, to: tgt }),
      detail: isCore ? [t('upd.apply.dCore1'), t('upd.apply.dCore2')] : [t('upd.apply.dApp1'), t('upd.apply.dApp2')],
      confirmText: t('upd.apply.go')
    });
    if (!ok) return;
    applying = true; TP.emit('update'); renderCard();
    var card = ui.taskCard(t('upd.apply.cardTitle', { to: tgt })), modal = ui.modal({
      title: t(isCore ? 'upd.apply.runCore' : 'upd.apply.runApp'), icon: 'update', iconKind: 'pri', size: 'md', static: true, lock: function () { return applying; },
      body: h('div', null, h('p', { class: 'muted sm' }, t('upd.apply.keepOpen')), card.el), actions: []
    });
    modal.setBusy(true); card.set({ pct: null, msg: t('job.submitting') });
    var failed = '';
    try {
      var r = await TP.helper('POST', '/api/update/apply', { q: { what: isCore ? 'core' : 'app' }, timeout: 30000 });
      if (r && r.job) {
        try { await TP.jobs.follow(r.job, card, { maxFails: 180 }); }
        catch (e) { if (!(e && e.kind === 'unreachable') || isCore) throw e; card.set({ pct: 95, msg: t('upd.apply.helperRestart') }); }
      }
      if (isCore) {
        card.done(t('upd.apply.coreDone', { to: tgt }));
        TP.loadVersion(); await U.check(true);
      } else {
        card.set({ pct: 98, msg: t('upd.apply.waiting') });
        var back = false, i;
        for (i = 0; i < 90 && !back; i++) {
          try { await TP.helper('GET', '/api/auth/status', { noAuth: true, timeout: 3000 }); back = true; } catch (e) { await TP.sleep(1000); }
        }
        if (!back) throw new Error(t('upd.apply.noBack'));
        card.done(t('upd.apply.doneReload', { to: tgt }));
        TP.ss.set('updated', tgt);
        await TP.sleep(700);
        location.reload();
        return;
      }
    } catch (e) {
      failed = e && e.kind === 'auth' ? t('upd.apply.authLost') : TP.errMsg(e);
      card.fail(failed); ui.toast(t('upd.apply.failToast', { reason: failed }), 'err');
    }
    applying = false; modal.setBusy(false); TP.emit('update'); renderCard();
    modal.setActions([{ label: t('common.close'), kind: 'primary', cancel: true }]);
    if (!failed) ui.toast(isCore ? t('upd.apply.coreDone', { to: tgt }) : t('upd.apply.okToast'), 'ok');
  };
})();
