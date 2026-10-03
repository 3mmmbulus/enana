/* enana · ui.js — 界面组件
 * 图标 / 按钮 / 提示 / 「暂不可用」状态 / 弹窗 (焦点锁定, ESC, 放弃确认) / confirmDialog / 菜单 / 分段开关 / 进度卡片 / 空状态
 * 原则: 受限控件用 aria-disabled + title; 进行中的操作使用 disabled + aria-busy, 禁止重复提交。受限操作点击说明原因和解决办法。
 * 文案全部来自词典 (I18N.t); 在 init 里一次性创建的静态文字用 I18N.L(键), 切换语言后会自动更新。 */
(function () {
  'use strict';
  var TP = window.TP, ui = TP.ui, h = TP.h, S = TP.S, I = window.I18N, t = I.t, L = I.L;

  /* ================= 图标 (Lucide, 见 icons.js) ================= */
  ui.icon = function (name, size, cls) {
    if (!window.Icons) return document.createTextNode('');
    return window.Icons.el(name, { size: size || 18, cls: 'icon' + (cls ? ' ' + cls : '') });
  };
  function setTitle(el, v) { if (I.isL(v)) I.attr(el, 'title', v); else if (v) el.title = v; else el.removeAttribute('title'); }

  /* ================= 按钮 / 芯片 ================= */
  /* ui.btn(文字|L(键), {icon, kind:'primary|danger|ghost', sm, type, title, aria, cls}) -> <button> (b._label 是文字节点) */
  ui.btn = function (label, o) {
    o = o || {};
    var b = h('button', { class: 'btn' + (o.kind ? ' ' + o.kind : '') + (o.sm ? ' sm' : '') + (o.cls ? ' ' + o.cls : ''), type: o.type || 'button' });
    if (o.title) { b._tip = o.title; setTitle(b, o.title); }
    if (o.aria) { if (I.isL(o.aria)) I.attr(b, 'aria-label', o.aria); else b.setAttribute('aria-label', o.aria); }
    b._label = h('span', { class: 'bl' }, label);
    b.appendChild(b._label);
    if (o.icon) ui.setBtnIcon(b, o.icon, o.sm ? 16 : 18);
    return b;
  };
  ui.setBtnIcon = function (b, name, size) {
    if (b._iconName === name) return;
    b._iconName = name;
    var ic = ui.icon(name, size || 18, 'bi');
    if (b._iconEl && b._iconEl.parentNode === b) b.replaceChild(ic, b._iconEl); else b.insertBefore(ic, b.firstChild);
    b._iconEl = ic;
  };
  ui.setBtn = function (b, label, icon) {
    TP.setText(b._label, label);
    if (icon) ui.setBtnIcon(b, icon, b.classList.contains('sm') ? 16 : 18);
  };
  /* 只有图标的按钮: label 同时是 aria-label 和 title (字符串或 L(键)) */
  ui.ibtn = function (icon, label, o) {
    o = o || {};
    var b = h('button', { class: 'btn ghost sm ibtn' + (o.cls ? ' ' + o.cls : ''), type: 'button', 'aria-label': label, title: label });
    b._tip = label; b._iconName = icon; b._iconEl = ui.icon(icon, o.size || 16, 'bi'); b.appendChild(b._iconEl);
    return b;
  };
  /* 状态芯片: ui.chip(文字, 'ok', 'success') */
  ui.chip = function (text, kind, icon) {
    return h('span', { class: 'chip' + (kind ? ' ' + kind : '') }, icon ? ui.icon(icon, 13, 'ci') : null, text);
  };
  ui.field = function (label, ctl, hint) {
    return h('label', { class: 'fld' }, h('span', { class: 'fld-l' }, label), ctl, hint ? h('span', { class: 'fld-h' }, hint) : null);
  };

  /* ================= 提示 (toast) ================= */
  var toastSeen = {}, TOAST_ICON = { ok: 'success', err: 'error', warn: 'warning' };
  /* 弹窗 (顶层) 会盖住普通元素: 有弹窗打开时, 把提示容器挪到最上面那个弹窗里, 这样提示不会被遮住 */
  ui.topHost = function () { var dl = document.querySelectorAll('dialog[open]'); return dl.length ? dl[dl.length - 1] : document.body; };
  ui.hostFloaters = function () {
    var f = TP.byId('floaters');
    if (!f) return;
    var top = ui.topHost();
    if (f.parentNode !== top) top.appendChild(f);
  };
  /* ui.toast(文字, 'ok'|'err'|'warn'|'', 毫秒, {action:{label, fn}}) */
  ui.toast = function (msg, kind, ms, opt) {
    var box = TP.byId('toasts');
    if (!box) return;
    var key = kind + '|' + msg, now = Date.now();
    if (toastSeen[key] && now - toastSeen[key] < 2500) return;     // 防刷屏
    toastSeen[key] = now;
    var act = opt && opt.action, el;
    function rm() { if (el.parentNode) el.parentNode.removeChild(el); }
    el = h('div', { class: 'toast ' + (kind || 'info') }, ui.icon(TOAST_ICON[kind] || 'info', 18, 'ti'), h('span', { class: 'toast-m' }, msg),
      act ? h('button', { class: 'toast-a', type: 'button', on: { click: function () { rm(); try { act.fn(); } catch (e) { console.error(e); } } } }, act.label || t('common.fix')) : null);
    ui.hostFloaters();
    box.appendChild(el);
    while (box.children.length > 4) box.removeChild(box.firstChild);
    setTimeout(rm, ms || (kind === 'err' ? 7000 : act ? 7000 : 3800));
  };

  /* ================= 「暂不可用」: aria-disabled + title, 点击说明原因 ================= */
  /* reason 为空 = 可用; fix = {label, fn} 可选, 提示里会带一个「去处理」按钮 */
  ui.avail = function (el, reason, fix) {
    if (reason) {
      el.setAttribute('aria-disabled', 'true'); el.classList.add('unavail');
      el._un = { reason: reason, fix: fix || null };
      el.title = reason;
    } else if (el._un) {
      el.removeAttribute('aria-disabled'); el.classList.remove('unavail'); el._un = null;
      setTitle(el, el._tip);
    }
  };
  ui.unavailable = function (el) {
    var u = el._un; if (!u) return;
    ui.toast(u.reason, 'warn', 5200, u.fix ? { action: u.fix } : null);
  };
  function fail(e) { if (!(e && (e.kind === 'auth' || e.kind === 'cancel'))) ui.toast(TP.errMsg(e), 'err'); }
  /* 点击处理: 不可用 -> 提示原因; 否则执行 (异步期间忽略重复点击; 错误变成 toast) */
  ui.actionBusy = function (el, busy) {
    if (busy) {
      el._busyLabel = el._label && el._label.textContent; el._busyIcon = el._iconName;
      el._wasDisabled = el.disabled;
      if (el._label) ui.setBtn(el, t('common.loading'), 'refresh');
    }
    el._busy = !!busy; el.disabled = busy || !!el._wasDisabled || !!el._renderBusy;
    el.classList.toggle('is-busy', busy || !!el._renderBusy);
    if (busy || el._renderBusy) el.setAttribute('aria-busy', 'true'); else el.removeAttribute('aria-busy');
    if (!busy && el._label && el._label.textContent === t('common.loading')) ui.setBtn(el, el._busyLabel, el._busyIcon);
  };
  ui.act = function (el, handler) {
    el.addEventListener('click', function (ev) {
      if (el._busy || el.disabled) { ev.preventDefault(); return; }
      if (el._un) { ev.preventDefault(); ui.unavailable(el); return; }
      ui.actionBusy(el, true);
      Promise.resolve().then(function () { return handler(ev); }).catch(fail).then(function () { ui.actionBusy(el, false); });
    });
  };
  /* <select>: 先把显示恢复成当前值, 再把用户想要的值交给 handler (它负责确认并真正应用) */
  ui.selectAct = function (sel, getCurrent, handler) {
    sel.addEventListener('change', function () {
      if (sel._busy) return;
      var want = sel.value;
      sel.value = getCurrent();
      if (sel._un) { ui.unavailable(sel); return; }
      if (want === getCurrent()) return;
      ui.actionBusy(sel, true);
      Promise.resolve().then(function () { return handler(want); }).catch(fail).then(function () { ui.actionBusy(sel, false); sel.value = getCurrent(); });
    });
  };
  /* 开关 <input type=checkbox>: 同上 */
  ui.switchAct = function (inp, getCurrent, handler) {
    inp.addEventListener('change', function () {
      if (inp._busy) return;
      var want = inp.checked;
      inp.checked = getCurrent();
      if (inp._un) { ui.unavailable(inp); return; }
      if (want === getCurrent()) return;
      ui.actionBusy(inp, true);
      Promise.resolve().then(function () { return handler(want); }).catch(fail).then(function () { ui.actionBusy(inp, false); inp.checked = getCurrent(); });
    });
  };

  /* ================= 弹窗 =================
   * ui.modal({title, icon, iconKind, size:'sm|md|lg', body:Node|function(api), actions:[{label,kind,icon,id,value,cancel,keep,autofocus,onClick(api)}],
   *           dirty:()=>bool (关闭前询问是否放弃), lock:()=>bool (为真时不能关闭), static:true (没有关闭按钮/ESC), onClose(v), cls})
   * -> api {el, body, foot, closed:Promise, setTitle, setActions, setBusy, getBtn, request(), close(v)}
   * 基于原生 <dialog>.showModal(): 背景不可操作; 另外自己处理 Tab 循环、ESC、点遮罩。 */
  var modalSeq = 0, FOCUSABLE = 'a[href],button:not([disabled]),input:not([disabled]):not([type=hidden]),select:not([disabled]),textarea:not([disabled]),summary,[tabindex]:not([tabindex="-1"])';
  ui.modal = function (o) {
    var id = 'dlg' + (++modalSeq), opener = document.activeElement, closing = false, resolveClosed, state = { busy: false, actionPending: 0 }, downOnBackdrop = false;
    var closed = new Promise(function (r) { resolveClosed = r; });
    var dlg = h('dialog', { class: 'dlg ' + (o.size || 'md') + (o.cls ? ' ' + o.cls : ''), 'aria-labelledby': id + 't' });
    var titleEl = h('h2', { class: 'dlg-t', id: id + 't' }, o.title || '');
    var xBtn = o.static ? null : ui.ibtn('x', L('common.close'), { cls: 'dlg-x', size: 18 });
    var head = h('div', { class: 'dlg-h' }, o.icon ? h('span', { class: 'dlg-ic ' + (o.iconKind || '') }, ui.icon(o.icon, 20)) : null, titleEl, xBtn);
    var body = h('div', { class: 'dlg-b' }), foot = h('div', { class: 'dlg-a' });
    dlg.appendChild(h('div', { class: 'dlg-in' }, head, body, foot));

    var api = {
      el: dlg, body: body, foot: foot, closed: closed,
      setTitle: function (v) { TP.setText(titleEl, v); },
      setBusy: function (b) { state.busy = !!b; syncBusy(); },
      getBtn: function (bid) { return foot.querySelector('[data-id="' + bid + '"]'); },
      /* 用户想关闭 (✕ / ESC / 点遮罩 / 取消): 忙碌时拒绝; 有未保存输入时先确认 */
      request: async function () {
        if (closing) return;
        if (state.busy || state.actionPending || (o.lock && o.lock())) { ui.toast(t('modal.busy'), 'warn', 2500); return; }
        if (o.dirty && o.dirty()) {
          var ok = await ui.confirmDialog({ title: t('confirm.discard.title'), message: t('confirm.discard.msg'), confirmText: t('confirm.discard.yes'), cancelText: t('confirm.discard.no'), danger: true });
          if (!ok) return;
        }
        api.close('cancel');
      },
      close: function (v) {
        if (closing) return;
        closing = true;
        try { if (dlg.open) dlg.close(); } catch (e) { /* 忽略 */ }
        var f = TP.byId('floaters');
        if (f && dlg.contains(f)) document.body.appendChild(f);              // 先把提示容器挪回来, 再删除弹窗
        if (dlg.parentNode) dlg.parentNode.removeChild(dlg);
        ui.hostFloaters();
        try { if (opener && opener.focus && document.contains(opener)) opener.focus(); } catch (e) { /* 忽略 */ }
        resolveClosed(v);
        if (o.onClose) { try { o.onClose(v); } catch (e) { console.error(e); } }
      }
    };

    function syncBusy() {
      var busy = state.busy || state.actionPending;
      dlg.classList.toggle('is-busy', busy); dlg.setAttribute('aria-busy', busy ? 'true' : 'false');
      if (xBtn) xBtn.disabled = busy;
      Array.prototype.forEach.call(foot.querySelectorAll('button'), function (b) { b.disabled = !!b._busy || (busy && !b._allowBusy) || !!b._actionDisabled; });
    }
    function renderActions(list) {
      TP.clear(foot);
      (list || []).forEach(function (a) {
        var b = ui.btn(a.label, { kind: a.kind, icon: a.icon, cls: a.cls });
        b._actionDisabled = !!a.disabled;
        b._allowBusy = !!a.allowBusy;
        if (a.id) b.setAttribute('data-id', a.id);
        if (a.autofocus) b.setAttribute('data-autofocus', '');
        if (a.unavail) ui.avail(b, a.unavail.reason, a.unavail.fix);
        b.addEventListener('click', async function () {
          if (b._busy || ((state.busy || state.actionPending) && !a.allowBusy) || b.disabled) return;
          if (b._un) { ui.unavailable(b); return; }
          if (a.cancel) { api.request(); return; }
          state.actionPending++; ui.actionBusy(b, true); syncBusy();
          var r;
          try { r = a.onClick ? await a.onClick(api, b) : undefined; }
          catch (e) { fail(e); r = false; }
          state.actionPending--; ui.actionBusy(b, false); syncBusy();
          if (r === false || a.keep) return;
          api.close(a.value !== undefined ? a.value : true);
        });
        foot.appendChild(b);
      });
      foot.hidden = !list || !list.length; syncBusy();
    }
    api.setActions = renderActions;

    if (xBtn) xBtn.addEventListener('click', function () { api.request(); });
    dlg.addEventListener('cancel', function (e) { e.preventDefault(); if (!o.static) api.request(); });
    dlg.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); if (!o.static) api.request(); return; }
      if (e.key !== 'Tab') return;
      var f = Array.prototype.filter.call(dlg.querySelectorAll(FOCUSABLE), function (el) { return el.offsetParent !== null || el === document.activeElement; });
      if (!f.length) { e.preventDefault(); return; }
      var first = f[0], last = f[f.length - 1], act = document.activeElement;
      if (e.shiftKey && (act === first || !dlg.contains(act))) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && (act === last || !dlg.contains(act))) { e.preventDefault(); first.focus(); }
    });
    dlg.addEventListener('mousedown', function (e) { downOnBackdrop = e.target === dlg; });
    dlg.addEventListener('click', function (e) { if (e.target === dlg && downOnBackdrop && !o.static) api.request(); downOnBackdrop = false; });
    dlg.addEventListener('close', function () { if (!closing) api.close(dlg.returnValue || 'cancel'); });   // 浏览器自己关掉了 (例如连按两次 ESC)

    var content = typeof o.body === 'function' ? o.body(api) : o.body;
    if (content) body.appendChild(content);
    renderActions(o.actions);
    document.body.appendChild(dlg);
    if (dlg.showModal) dlg.showModal(); else dlg.setAttribute('open', '');
    ui.hostFloaters();
    var af = dlg.querySelector('[data-autofocus]') || body.querySelector('input:not([type=checkbox]):not([type=radio]):not([type=hidden]),textarea,select') || foot.querySelector('.btn.primary,.btn.danger') || foot.querySelector('.btn') || xBtn;
    if (af && af.focus) { try { af.focus({ preventScroll: true }); } catch (e) { /* 忽略 */ } }
    return api;
  };

  /* ================= 确认框 =================
   * ui.confirmDialog({title, message, detail:字符串|数组|Node, confirmText, cancelText, danger, kind:'primary|success|warning', confirmIcon, rememberKey})   (kind 决定确认按钮颜色: 绿 = 开启 / 确认安全, 琥珀 = 谨慎, 红 = danger) -> Promise<boolean>
   * 低风险开关 (rememberKey 且不是 danger 且 ALLOW_SKIP_CONFIRM) 才提供「本次登录期间不再询问此类操作」(只存在 sessionStorage); 危险操作永远不提供。 */
  ui.confirmDialog = function (o) {
    o = o || {};
    var key = o.rememberKey, canSkip = !!(TP.CFG.ALLOW_SKIP_CONFIRM && key && !o.danger);
    if (canSkip && TP.ss.get('skip.' + key, false)) return Promise.resolve(true);
    return new Promise(function (resolve) {
      var chk = canSkip ? h('input', { type: 'checkbox' }) : null, detail = o.detail, dn = null;
      if (Array.isArray(detail)) dn = h('ul', { class: 'cfm-list' }, detail.filter(Boolean).map(function (x) { return h('li', null, x); }));
      else if (detail && detail.nodeType) dn = detail;
      else if (detail) dn = h('p', { class: 'cfm-d' }, detail);
      ui.modal({
        title: o.title || t('confirm.title'), size: 'sm', icon: o.danger ? 'risk' : o.kind === 'warning' ? 'warning' : 'help', iconKind: o.danger ? 'bad' : o.kind === 'warning' ? 'warn' : o.kind === 'success' ? 'ok' : 'pri',
        body: h('div', { class: 'cfm' }, h('p', { class: 'cfm-m' }, o.message || ''), dn,
          chk ? h('label', { class: 'chk-inline cfm-skip' }, chk, h('span', null, t('confirm.skip'))) : null),
        actions: [
          { label: o.cancelText || t('common.cancel'), cancel: true, autofocus: !!o.danger },
          { label: o.confirmText || t('common.ok'), kind: o.danger ? 'danger' : o.kind === 'success' ? 'success' : o.kind === 'warning' ? 'warning' : 'primary', icon: o.confirmIcon || (o.danger ? 'delete' : 'check'), value: true, autofocus: !o.danger }
        ],
        onClose: function (v) {
          var yes = v === true;
          if (yes && chk && chk.checked) TP.ss.set('skip.' + key, true);
          resolve(yes);
        }
      });
    });
  };
  ui.clearSkipFlags = function () { TP.ss.keys('skip.').forEach(function (k) { TP.ss.del(k); }); };

  /* ================= 弹出菜单 (用户菜单 / 语言菜单) =================
   * ui.menu(锚点按钮, getItems(), {label, place:'top|bottom-end|right'}) -> {open, close}
   * items: [{label, desc (第二行小字), icon, check, danger, sep, note (不可点的说明文字), onClick}]; o.cls 给菜单加样式类; 打开时才取 items (文字跟随当前语言); ESC / 点外面 / Tab 关闭; 上下键移动。 */
  ui.menu = function (anchor, getItems, o) {
    o = o || {};
    var menu = null;
    function onDoc(e) { if (menu && !menu.contains(e.target) && !anchor.contains(e.target)) close(false); }
    function onKey(e) {
      if (!menu) return;
      if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); close(true); return; }
      if (e.key === 'Tab') { close(false); return; }
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
        e.preventDefault();
        var its = Array.prototype.slice.call(menu.querySelectorAll('.menu-i')), i = its.indexOf(document.activeElement);
        its[(i + (e.key === 'ArrowDown' ? 1 : its.length - 1)) % its.length].focus();
      }
    }
    function close(back) {
      if (!menu) return;
      document.removeEventListener('mousedown', onDoc, true); document.removeEventListener('keydown', onKey, true);
      if (menu.parentNode) menu.parentNode.removeChild(menu);
      menu = null; anchor.setAttribute('aria-expanded', 'false');
      if (back) { try { anchor.focus(); } catch (e) { /* 忽略 */ } }
    }
    function open() {
      if (menu) { close(true); return; }
      var items = getItems();
      menu = h('div', { class: 'menu' + (o.cls ? ' ' + o.cls : ''), role: 'menu', 'aria-label': o.label || null }, items.map(function (it) {
        if (it.sep) return h('div', { class: 'menu-sep', role: 'separator' });
        if (it.note) return h('p', { class: 'menu-note' }, it.note);                       // 说明文字 (不可点)
        var b = h('button', { class: 'menu-i' + (it.danger ? ' bad' : ''), type: 'button', role: it.check === undefined ? 'menuitem' : 'menuitemradio', 'aria-checked': it.check === undefined ? null : String(!!it.check) },
          it.icon ? ui.icon(it.icon, 16, 'mi') : h('span', { class: 'mi-sp' }), h('span', { class: 'ml' }, it.desc ? h('span', { class: 'mt' }, it.label) : it.label, it.desc ? h('span', { class: 'md' }, it.desc) : null), it.check ? ui.icon('check', 16, 'mc') : null);
        b.addEventListener('click', function () { close(true); if (it.onClick) Promise.resolve().then(it.onClick).catch(fail); });
        return b;
      }));
      ui.topHost().appendChild(menu);                                   // 在弹窗里打开时, 菜单也要放进弹窗 (顶层) 才看得见
      var r = anchor.getBoundingClientRect(), mw = menu.offsetWidth, mh = menu.offsetHeight, vw = window.innerWidth, vh = window.innerHeight, x, y;
      if (o.place === 'right') { x = r.right + 8; y = r.bottom - mh; }
      else if (o.place === 'bottom-end') { x = r.right - mw; y = r.bottom + 6; }
      else { x = r.left; y = r.top - mh - 6; }                        // top
      x = Math.max(8, Math.min(x, vw - mw - 8)); y = Math.max(8, Math.min(y, vh - mh - 8));
      menu.style.left = x + 'px'; menu.style.top = y + 'px';
      anchor.setAttribute('aria-expanded', 'true');
      document.addEventListener('mousedown', onDoc, true); document.addEventListener('keydown', onKey, true);
      var first = menu.querySelector('.menu-i[aria-checked="true"]') || menu.querySelector('.menu-i');
      if (first) first.focus();
    }
    anchor.setAttribute('aria-haspopup', 'menu'); anchor.setAttribute('aria-expanded', 'false');
    anchor.addEventListener('click', open);
    return { open: open, close: function () { close(false); } };
  };

  /* ================= 分段开关 =================
   * ui.seg(标签, [{v,label,icon,title}], onPick(v), {onSame(v)}) -> {el, set(v), cur(), avail(v, reason, fix), mark(v)}
   * 原生 radio: 键盘方向键可用。当前选项再点一次 -> 「已经是…」; 不可用的选项点击 -> 说明原因 (仍可聚焦, 不用 disabled)。
   * 注意: onPick 里要先 set(原值) 把显示恢复, 确认之后再 set(新值)。 label/title 可以是字符串或 L(键)。 */
  var segUid = 0;
  ui.seg = function (label, opts, onPick, o) {
    o = o || {};
    var name = 'seg' + (++segUid), inputs = {}, cur = '', un = {};
    var node = h('div', { class: 'seg', role: 'radiogroup', 'aria-label': label }, opts.map(function (op) {
      var inp = h('input', { type: 'radio', name: name, value: op.v });
      inputs[op.v] = inp;
      inp.addEventListener('click', function (ev) {
        if (inp._busy || inp.disabled) { ev.preventDefault(); return; }
        if (un[op.v]) { ev.preventDefault(); ui.toast(un[op.v].reason, 'warn', 5200, un[op.v].fix ? { action: un[op.v].fix } : null); return; }
        if (cur === op.v) { if (o.onSame) o.onSame(op.v); else ui.toast(t('seg.same', { name: I.isL(op.label) ? I.text(op.label) : op.label }), '', 2200); }
      });
      inp.addEventListener('change', function () {
        if (inp._busy || !inp.checked || cur === op.v) return;
        Object.keys(inputs).forEach(function (k) { ui.actionBusy(inputs[k], true); });
        node.setAttribute('aria-busy', 'true'); node.classList.add('is-busy');
        Promise.resolve().then(function () { return onPick(op.v); }).catch(fail).then(function () {
          Object.keys(inputs).forEach(function (k) { ui.actionBusy(inputs[k], false); });
          node.removeAttribute('aria-busy'); node.classList.remove('is-busy');
        });
      });
      var lab = h('label', { 'data-v': op.v, title: op.title || null }, inp, h('span', null, op.icon ? ui.icon(op.icon, 15, 'si') : null, h('span', { class: 'sl' }, op.label)));
      lab._title0 = op.title || null;
      return lab;
    }));
    return {
      el: node, inputs: inputs,
      set: function (v) { cur = v; Object.keys(inputs).forEach(function (k) { var c = k === v; if (inputs[k].checked !== c) inputs[k].checked = c; }); },
      cur: function () { return cur; },
      avail: function (v, reason, fix) {
        var lab = inputs[v] && inputs[v].parentNode; if (!lab) return;
        if (reason) { un[v] = { reason: reason, fix: fix }; inputs[v].setAttribute('aria-disabled', 'true'); lab.classList.add('unavail'); lab.title = reason; }
        else if (un[v]) { delete un[v]; inputs[v].removeAttribute('aria-disabled'); lab.classList.remove('unavail'); setTitle(lab, lab._title0); }
      },
      mark: function (v) { Object.keys(inputs).forEach(function (k) { inputs[k].parentNode.classList.toggle('is-def', k === v); }); }
    };
  };

  /* ================= 页内标签 (操作记录 | 网站访问 | 代理日志 / 导入 | 手动添加 / 网站页的左侧二级导航) =================
   * ui.tabs(label, [{id, label, icon, count}], onPick, {vertical}) -> {el, set(id), cur(), btn(id), avail(id, reason, fix), count(id, n), text(id, label)}
   * role=tablist, 方向键 / Home / End 切换 (横向: ← →; 竖向: ↑ ↓); 切换面板由调用方负责 (用 btn(id).id 作为面板的 aria-labelledby)。
   * 竖向 (vertical) 是同一套标签样式摆成一列 (选中 = 实心主色, 悬停 = 浅色), 窄屏自动变成可横向滚动的一行 —— 整个界面只有这一种标签长相。count = 标签右边的小数字。 */
  var tabUid = 0;
  ui.tabs = function (label, items, onPick, o) {
    o = o || {};
    var uid = 'tb' + (++tabUid), cur = '', btns = {}, cnts = {}, labs = {}, vert = !!o.vertical;
    var el = h('div', { class: 'subtabs' + (vert ? ' is-v' : ''), role: 'tablist', 'aria-label': label, 'aria-orientation': vert ? 'vertical' : 'horizontal' });
    items.forEach(function (it) {
      var lab = h('span', { class: 'subtab-l' }, it.label), cn = h('span', { class: 'subtab-n', hidden: it.count == null }, it.count == null ? '' : String(it.count));
      var b = h('button', { class: 'subtab', type: 'button', role: 'tab', id: uid + '-' + it.id, 'aria-selected': 'false', tabindex: '-1' }, it.icon ? ui.icon(it.icon, 16, 'ci') : null, lab, cn);
      b.addEventListener('click', function () { if (b._un) { ui.unavailable(b); return; } if (cur !== it.id) onPick(it.id); });
      btns[it.id] = b; cnts[it.id] = cn; labs[it.id] = lab; el.appendChild(b);
    });
    el.addEventListener('keydown', function (e) {
      var ids = items.map(function (x) { return x.id; }), i = ids.indexOf(cur), j, next = vert ? 'ArrowDown' : 'ArrowRight', prev = vert ? 'ArrowUp' : 'ArrowLeft';
      if (e.key === next) j = (i + 1) % ids.length; else if (e.key === prev) j = (i + ids.length - 1) % ids.length;
      else if (e.key === 'Home') j = 0; else if (e.key === 'End') j = ids.length - 1; else return;
      e.preventDefault(); btns[ids[j]].focus(); if (!btns[ids[j]]._un) onPick(ids[j]);
    });
    return {
      el: el,
      cur: function () { return cur; },
      btn: function (id) { return btns[id]; },
      set: function (id) {
        cur = id;
        Object.keys(btns).forEach(function (k) { var on = k === id; btns[k].setAttribute('aria-selected', on ? 'true' : 'false'); btns[k].tabIndex = on ? 0 : -1; btns[k].classList.toggle('on', on); });
      },
      count: function (id, n) { var c = cnts[id]; if (!c) return; c.hidden = n == null; if (n != null && c.textContent !== String(n)) c.textContent = String(n); },
      text: function (id, text) { var l = labs[id]; if (l && l.textContent !== text) l.textContent = text; },
      avail: function (id, reason, fix) { ui.avail(btns[id], reason, fix); }
    };
  };

  /* ================= 进度条 / 步骤 / 任务卡片 ================= */
  ui.bar = function () {
    var i = h('i'), el = h('div', { class: 'bar', role: 'progressbar', 'aria-valuemin': 0, 'aria-valuemax': 100 }, i);
    return {
      el: el,
      set: function (pct, cls) {
        if (pct == null) { el.classList.add('ind'); el.removeAttribute('aria-valuenow'); i.style.width = ''; }
        else {
          pct = Math.max(0, Math.min(100, +pct || 0));
          el.classList.remove('ind'); i.style.width = pct + '%'; el.setAttribute('aria-valuenow', String(Math.round(pct)));
        }
        el.classList.toggle('ok', cls === 'ok'); el.classList.toggle('err', cls === 'err');
      }
    };
  };
  /* 步骤列表: steps = [{label, state:'todo|run|done|error|skip', note}] */
  ui.renderSteps = function (ol, steps) {
    while (ol.children.length > steps.length) ol.removeChild(ol.lastChild);
    steps.forEach(function (s, i) {
      var li = ol.children[i];
      if (!li) { li = h('li', null, h('span', { class: 'ic' }), h('span', { class: 'lb' }), h('span', { class: 'nt' })); ol.appendChild(li); }
      TP.setCls(li, s.state || 'todo');
      TP.setText(li.firstChild, s.state === 'done' ? '✓' : s.state === 'error' ? '✕' : s.state === 'skip' ? '–' : s.state === 'run' ? '' : String(i + 1));
      TP.setText(li.children[1], s.label);
      TP.setText(li.children[2], s.note || '');
      li.setAttribute('aria-current', s.state === 'run' ? 'step' : 'false');
    });
  };
  /* 任务卡片: 标题 + 进度条 + 当前信息 + 步骤。可放在右下角 dock, 也可嵌入弹窗。
   * card.set({pct,msg,steps,cls}) / fromJob(job) / done(msg) / fail(msg) / close() / setTitle() */
  ui.taskCard = function (title, o) {
    o = o || {};
    var bar = ui.bar(), pctEl = h('span', { class: 'task-pct muted sm' }), msg = h('div', { class: 'task-msg' }), steps = h('ol', { class: 'steps' + (o.horizontal ? ' h' : '') });
    var x = ui.ibtn('x', L('common.close')); x.classList.add('task-x'); x.hidden = true; x.addEventListener('click', function () { api.close(); });
    var tt = h('b', null, title);
    var el = h('div', { class: 'task' }, h('div', { class: 'task-h' }, tt, pctEl, x), bar.el, msg, steps);
    var api = {
      el: el,
      setTitle: function (v) { TP.setText(tt, v); },
      set: function (p) {
        bar.set(p.pct == null ? null : p.pct, p.cls);
        TP.setText(pctEl, p.pct == null ? '' : Math.round(p.pct) + '%');
        if (p.msg != null) TP.setText(msg, p.msg);
        if (p.steps) { steps.hidden = !p.steps.length; ui.renderSteps(steps, p.steps); }
      },
      fromJob: function (j) { api.set({ pct: j.pct, msg: j.msg || t('job.applying'), steps: j.steps || [] }); },
      done: function (m) { api.set({ pct: 100, msg: m || t('common.done'), cls: 'ok' }); x.hidden = false; el.classList.add('is-done'); },
      fail: function (m) { api.set({ pct: 100, msg: m || t('common.failed'), cls: 'err' }); x.hidden = false; el.classList.add('is-err'); },
      close: function () { if (el.parentNode) el.parentNode.removeChild(el); }
    };
    steps.hidden = true;
    return api;
  };
  ui.dock = function (card, autoCloseMs) {
    var d = TP.byId('dock');
    if (d) d.appendChild(card.el);
    if (autoCloseMs) setTimeout(card.close, autoCloseMs);
  };

  /* ================= 空状态: 一个大的淡色图标 + 一句话 + (可选) 主要操作 ================= */
  /* ui.emptyBox() -> {el, show({icon,text,hint,action:{label,icon,fn}}), hide()} — 文字用 t() 传入, 切换语言后由页面重新 render */
  ui.emptyBox = function () {
    var el = h('div', { class: 'empty-s', hidden: true });
    return {
      el: el,
      hide: function () { el.hidden = true; },
      show: function (o) {
        var sig = [I.lang, o.icon, o.text, o.hint, o.action && o.action.label].join('|');
        el.hidden = false;
        if (el._sig === sig) return;
        el._sig = sig; TP.clear(el);
        el.appendChild(ui.icon(o.icon || 'info', 44, 'empty-ic'));
        el.appendChild(h('p', { class: 'empty-t' }, o.text || ''));
        if (o.hint) el.appendChild(h('p', { class: 'muted sm' }, o.hint));
        if (o.action) { var b = ui.btn(o.action.label, { kind: 'primary', icon: o.action.icon }); ui.act(b, o.action.fn); el.appendChild(b); }
      }
    };
  };

  /* ================= 「查看 / 详情」按钮: 点击打开弹窗 (不在页面里行内展开) =================
   * ui.detailsBtn(按钮文字, 弹窗标题, build() -> Node, {icon, size}) -> <button class="btn sm ghost"> */
  ui.detailsBtn = function (label, title, build, o) {
    o = o || {};
    var b = ui.btn(label, { sm: true, kind: 'ghost', icon: o.icon || 'list-checks', cls: 'details-b' });
    b.addEventListener('click', function () { ui.modal({ title: title, icon: 'info', iconKind: 'info', size: o.size || 'md', body: build(), actions: [{ label: t('common.close'), kind: 'primary', cancel: true }] }); });
    return b;
  };

  /* ================= 骨架屏: ui.skeleton(行数) -> <div class="skel"> (读取数据时的占位, aria-busy; 数据来了就整块替换掉) ================= */
  ui.skeleton = function (n) {
    var d = h('div', { class: 'skel', 'aria-busy': 'true', 'aria-label': t('common.loading') });
    for (var i = 0; i < (n || 3); i++) d.appendChild(h('i'));
    return d;
  };

  /* ================= 复制到剪贴板 (没有 clipboard API / 非安全上下文时退回 execCommand); 成功 / 失败都有提示 ================= */
  ui.copy = function (text, okMsg) {
    var ok = function () { ui.toast(okMsg || t('common.copied'), 'ok', 1800); }, no = function () { ui.toast(t('common.copyFail'), 'warn'); };
    function legacy() {
      var ta = h('textarea', { class: 'sr', readonly: true, 'aria-hidden': 'true', tabindex: '-1' });
      ta.value = text; ui.topHost().appendChild(ta); ta.select();
      var done = false; try { done = document.execCommand('copy'); } catch (e) { done = false; }
      if (ta.parentNode) ta.parentNode.removeChild(ta);
      if (done) ok(); else no();
    }
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(ok, legacy); else legacy();
  };

  /* ================= 徽标 (语义颜色: 绿 = 可用 / 成功 / 在线, 琥珀 = 需要注意 / 谨慎, 红 = 危险, 蓝灰 = 说明 / 中性, pro = 会员功能) =================
   * ui.badge(文字 | L(键), 'ok|warn|bad|info|pro|neutral|new', 图标名?) -> <span class="badge ..."> */
  ui.badge = function (text, kind, icon) {
    return h('span', { class: 'badge' + (kind ? ' ' + kind : '') }, icon ? ui.icon(icon, 12, 'ci') : null, text);
  };

  /* ================= 「!」说明图标 =================
   * ui.help(话题, {size, cls}) -> <button class="help-i"> (圆圈里的感叹号, 中性蓝灰色, 不是警告色; 放在功能 / 设置 / 区块标题旁边)
   * 点击打开一个小弹窗 (键盘可达, Esc / 「知道了」关闭): 标题 help.<话题>.title · 这是什么 .what · 怎么用 .how · 注意事项 .note · 了解更多 .more (https 链接, 可省略)。
   * 词典里只写需要的段落; 一段里多行 = 多个段落, 以「• 」「- 」或「1. 」开头的行是列表。 */
  var helps = [];
  function helpTitle(topic) { return I.has('help.' + topic + '.title') ? t('help.' + topic + '.title') : t('help.untitled'); }
  function helpParas(text) {
    var f = document.createDocumentFragment(), ul = null;
    String(text).split('\n').forEach(function (ln) {
      if (!ln.trim()) { ul = null; return; }
      var m = /^\s*(?:[\u2022\-*]|\d+[.)])\s+(.*)$/.exec(ln);
      if (m) { if (!ul) { ul = h('ul', { class: 'help-ul' }); f.appendChild(ul); } ul.appendChild(h('li', null, m[1])); }
      else { ul = null; f.appendChild(h('p', { class: 'help-p' }, ln)); }
    });
    return f;
  }
  ui.helpOpen = function (topic) {
    var kids = [], more = I.has('help.' + topic + '.more') ? t('help.' + topic + '.more') : '';
    [['what', 'help.sec.what'], ['how', 'help.sec.how'], ['note', 'help.sec.note']].forEach(function (sx) {
      var k = 'help.' + topic + '.' + sx[0];
      if (I.has(k)) kids.push(h('section', { class: 'help-sec help-' + sx[0] }, h('h4', null, t(sx[1])), helpParas(t(k))));
    });
    if (!kids.length) kids.push(h('p', { class: 'muted' }, t('help.none')));
    if (/^https:\/\//i.test(more)) kids.push(h('p', { class: 'help-more' }, h('a', { class: 'xlink', href: more, target: '_blank', rel: 'noopener noreferrer' }, t('help.more'), ui.icon('external-link', 13, 'ci'))));
    return ui.modal({ title: helpTitle(topic), icon: 'help-i', iconKind: 'info', size: 'sm', cls: 'helpdlg', body: h('div', { class: 'help' }, kids), actions: [{ label: t('help.gotIt'), kind: 'primary', icon: 'check', autofocus: true }] });
  };
  ui.help = function (topic, o) {
    o = o || {};
    var b = h('button', { class: 'help-i' + (o.cls ? ' ' + o.cls : ''), type: 'button', 'aria-haspopup': 'dialog' }, ui.icon('help-i', o.size || 16, 'hi'));
    function lab() { var sx = t('help.aria', { name: helpTitle(topic) }); b.setAttribute('aria-label', sx); b.title = sx; }
    lab(); helps.push({ b: b, lab: lab });
    b.addEventListener('click', function (ev) { ev.preventDefault(); ev.stopPropagation(); ui.helpOpen(topic); });
    return b;
  };
  TP.on('lang', function () { helps = helps.filter(function (x) { if (document.contains(x.b)) x.b._seen = true; else if (x.b._seen) return false; x.lab(); return true; }); });

  /* ================= 分页 (表格默认分页: 每页 10 / 20 / 50, 页大小和当前页记在 prefs 里) =================
   * var pg = ui.pager('sites.domains', {sizes:[10,20,50], def:10});  parent.appendChild(pg.el);
   * pg.onChange(function () { render(); });                  // 用户翻页 / 改每页条数
   * 每次渲染: var r = pg.update(list.length); list.slice(r.start, r.end).forEach(...)      // 总数不超过最小页大小时自己隐藏
   * 其它: pg.size() pg.page() pg.setPage(n) */
  ui.pager = function (id, o) {
    o = o || {};
    var sizes = o.sizes || [10, 20, 50], key = 'table.' + id, cbs = [], total = 0;
    var size = +TP.prefs.get(key + '.pageSize', o.def || sizes[0]); if (sizes.indexOf(size) < 0) size = o.def || sizes[0];
    var page = Math.max(1, +TP.prefs.get(key + '.page', 1) || 1);
    var info = h('span', { class: 'pg-info muted sm', 'aria-live': 'polite' }), nav = h('span', { class: 'pg-nav' });
    var sel = h('select', { class: 'sel sm pg-size', 'aria-label': L('pager.size') }, sizes.map(function (n) { return h('option', { value: String(n) }, L('pager.sizeOpt', { n: n })); }));
    var el = h('nav', { class: 'pager', 'aria-label': L('pager.aria'), hidden: true }, info, nav, h('label', { class: 'pg-sz' }, h('span', { class: 'sm muted' }, L('pager.size')), sel));
    function pages() { return Math.max(1, Math.ceil(total / size)); }
    function go(n) { n = Math.max(1, Math.min(pages(), n)); if (n === page) return; page = n; TP.prefs.set(key + '.page', page); draw(); cbs.forEach(function (f) { f(); }); }
    function pbtn(label, icon, n, disabled, cur) {
      var b = h('button', { class: 'pg-b' + (cur ? ' on' : '') + (icon ? ' ib' : ''), type: 'button', 'aria-label': label, title: icon ? label : null, 'aria-current': cur ? 'page' : null }, icon ? ui.icon(icon, 16) : String(n));
      if (disabled) b.setAttribute('aria-disabled', 'true');
      b.addEventListener('click', function () { if (disabled) return; go(typeof n === 'number' ? n : n === 'prev' ? page - 1 : n === 'next' ? page + 1 : n === 'first' ? 1 : pages()); });
      return b;
    }
    function draw() {
      var pc = pages(), from = total ? (page - 1) * size + 1 : 0, to = Math.min(total, page * size);
      el.hidden = total <= sizes[0];
      TP.setText(info, t('pager.summary', { from: from, to: to, total: total }));
      TP.clear(nav);
      nav.appendChild(pbtn(t('pager.first'), 'chevrons-left', 'first', page <= 1));
      nav.appendChild(pbtn(t('pager.prev'), 'chevron-left', 'prev', page <= 1));
      var list = [], i;
      for (i = 1; i <= pc; i++) if (i === 1 || i === pc || Math.abs(i - page) <= 1 || (page <= 3 && i <= 4) || (page >= pc - 2 && i >= pc - 3)) list.push(i);
      var last = 0;
      list.forEach(function (n) {
        if (last && n - last > 1) nav.appendChild(h('span', { class: 'pg-gap', 'aria-hidden': 'true' }, '…'));
        nav.appendChild(pbtn(t(n === page ? 'pager.pageCur' : 'pager.page', { n: n }), null, n, false, n === page)); last = n;
      });
      nav.appendChild(pbtn(t('pager.next'), 'chevron-right', 'next', page >= pc));
      nav.appendChild(pbtn(t('pager.last'), 'chevrons-right', 'last', page >= pc));
      sel.value = String(size);
    }
    sel.addEventListener('change', function () {
      var n = +sel.value; if (n === size) return;
      var first = (page - 1) * size; size = n; page = Math.floor(first / size) + 1;            // 改每页条数时尽量留在同一批数据附近
      TP.prefs.set(key + '.pageSize', size); TP.prefs.set(key + '.page', page); draw(); cbs.forEach(function (f) { f(); });
    });
    TP.on('lang', function () { if (document.contains(el)) draw(); });
    TP.on('prefs', function (d) {
      if (!document.contains(el) || !d) return;
      var ns = +TP.prefs.get(key + '.pageSize', size); if (sizes.indexOf(ns) < 0) ns = size;
      var np = Math.max(1, +TP.prefs.get(key + '.page', page) || 1);
      if (d.all && (ns !== size || np !== page)) { size = ns; page = np; draw(); cbs.forEach(function (f) { f(); }); }
    });
    draw();
    return {
      el: el, size: function () { return size; }, page: function () { return page; },
      onChange: function (f) { cbs.push(f); },
      setPage: go,
      update: function (n) {
        total = Math.max(0, +n || 0);
        if (page > pages()) { page = pages(); TP.prefs.set(key + '.page', page); }
        draw();
        return { start: (page - 1) * size, end: Math.min(total, page * size), page: page, pages: pages(), size: size, total: total };
      }
    };
  };
})();
