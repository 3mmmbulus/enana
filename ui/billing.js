/* Shared Mac/Windows membership UI. The cloud is the only authority for prices,
 * receipt status and balances. Requests are idempotent; losing a response never
 * creates a second invoice or a second wallet charge on retry. */
(function () {
  'use strict';
  var TP = window.TP, S = TP.S, h = TP.h, ui = TP.ui, t = window.I18N.t, L = window.I18N.L;
  var B = TP.billing = {}, data = null, error = null, pending = null, loadedAt = 0, epoch = 0;
  var mutation = false, keys = {}, mounts = [], emailMounts = [], dialogs = [], resendUntil = 0;
  var labels = { m1: 'billing.term.m1', m3: 'billing.term.m3', m6: 'billing.term.m6', y1: 'billing.term.y1', y2: 'billing.term.y2', y3: 'billing.term.y3', y5: 'billing.term.y5' };
  function micro(v) { if (typeof v !== 'string' || !/^\d{1,7}\.\d{6}$/.test(v)) return NaN; return Number(v.replace('.', '')); }
  function money(v) { return typeof v === 'string' && /^\d+\.\d{6}$/.test(v) ? v.replace(/\.0+$/, '').replace(/(\.\d*?[1-9])0+$/, '$1') : '—'; }
  function term(sku) { return labels[sku] ? t(labels[sku]) : String(sku || ''); }
  function msg(e) { return e && e.code && window.I18N.has('billing.err.' + e.code) ? t('billing.err.' + e.code) : TP.errMsg(e); }
  function canUse() { return !S.locked && !TP.why.helper(); }
  function activeOrder() { return data && (data.orders || []).filter(function (o) { return o.status === 'pending' && o.expires_at * 1000 > Date.now(); })[0]; }
  function why(payments) {
    if (!canUse()) return TP.why.helper() || t('why.locked');
    if (!data) return error ? msg(error) : t('common.loading');
    if (!data.email.verified) return t('billing.verifyFirst');
    if (mutation) return t('common.loading');
    if (payments && !data.payments_available) return t('billing.unavailable');
    if (payments && activeOrder()) return t('billing.pendingFirst');
    return '';
  }
  function button(label, fn, reason, primary) {
    var b = ui.btn(label, { kind: primary ? 'primary' : undefined, sm: true });
    ui.avail(b, reason || ''); ui.act(b, fn);
    if (mutation || reason === t('common.loading')) ui.actionBusy(b, true);
    return b;
  }
  function redraw() { mounts.forEach(render); emailMounts.forEach(renderEmail); TP.emit('billing', data); }
  B.load = function (force) {
    if (!canUse()) return Promise.resolve(null);
    if (pending) return pending;
    if (!force && data && Date.now() - loadedAt < 60000) return Promise.resolve(data);
    var mine = epoch;
    pending = TP.helper('GET', '/api/billing', { timeout: 15000 }).then(function (r) {
      if (mine !== epoch) return null;
      if (!r || !r.email || !r.wallet || !Array.isArray(r.catalog) || !Array.isArray(r.orders) || !Array.isArray(r.ledger)) throw TP.mkErr('api', t('error.generic'));
      data = r; error = null; loadedAt = Date.now(); redraw(); return r;
    }).catch(function (e) { if (mine === epoch) { error = e; redraw(); } return null; }).finally(function () { if (mine === epoch) { pending = null; } });
    return pending;
  };
  async function write(op, body, scope) {
    if (mutation) return null;
    var mine = epoch;
    if (scope) { if (!keys[scope]) keys[scope] = window.crypto.randomUUID(); body.request_key = keys[scope]; }
    mutation = true; redraw();
    try {
      var r = await TP.helper('POST', '/api/' + op, { body: JSON.stringify(body), timeout: 18000 });
      if (mine !== epoch) return null;
      if (scope) delete keys[scope];
      if (pending) await pending;
      if (mine !== epoch) return null;
      await B.load(true); TP.plan.load(true); return r;
    } catch (e) {
      if (mine === epoch) { if (e.code === 'E_ORDER_PENDING') await B.load(true); ui.toast(msg(e), 'err'); }
      return null;
    } finally { if (mine === epoch) { mutation = false; redraw(); } }
  }
  async function checkout(kind, sku, amount) {
    if (why(true)) return;
    var body = kind === 'plan' ? { kind: kind, sku: sku } : { kind: kind, amount: amount };
    var r = await write('billing/checkout', body, 'invoice:' + JSON.stringify(body));
    if (r && r.order) B.openOrder(r.order);
  }
  async function purchase(item) {
    if (why(false) || !Number.isFinite(micro(item.price)) || micro(data.wallet.balance) < micro(item.price)) return;
    var ok = await ui.confirmDialog({ title: t('billing.balancePay'), message: t('billing.purchaseConfirm', { amount: money(item.price), term: term(item.id) }), confirmText: t('billing.confirmPurchase') });
    if (ok && !why(false)) await write('billing/purchase', { sku: item.id }, 'wallet:' + item.id);
  }
  async function autoRenew() {
    if (why(false)) return;
    var enabled = !data.wallet.auto_renew;
    var ok = await ui.confirmDialog({ title: t('billing.renew'), message: t(enabled ? 'billing.renewConfirm' : 'billing.renewDisableConfirm'), confirmText: t(enabled ? 'billing.enableRenew' : 'billing.disableRenew') });
    if (ok && !why(false)) await write('billing/auto-renew', { enabled: enabled });
  }
  function topup() {
    if (why(true)) return;
    var amount = h('input', { type: 'text', inputmode: 'decimal', autocomplete: 'off', 'aria-label': t('billing.topupAmount'), value: '4' });
    ui.modal({ title: t('billing.topup'), icon: 'pro', size: 'sm', body: h('div', null, h('label', null, L('billing.topupAmount'), amount), h('p', { class: 'muted sm' }, L('billing.topupRange'))), actions: [
      { label: t('common.cancel'), cancel: true },
      { label: t('billing.createInvoice'), kind: 'primary', onClick: async function (dlg) {
        var v = amount.value.trim();
        if (!/^\d{1,4}(\.\d{1,6})?$/.test(v) || Number(v) < 4 || Number(v) > 1000) { ui.toast(t('billing.topupRange'), 'warn'); return false; }
        if (why(true)) { ui.toast(why(true), 'warn'); return false; }
        var r = await write('billing/checkout', { kind: 'topup', amount: v }, 'topup:' + v);
        if (!r || !r.order) return false;
        dlg.close(); B.openOrder(r.order); return false;
      } }
    ] });
  }
  function render(root) {
    TP.clear(root);
    if (!data) {
      root.appendChild(h('p', { class: 'muted' }, error ? msg(error) : t('common.loading')));
      root.appendChild(button(L('common.retry'), function () { return B.load(true); }, !canUse() ? TP.why.helper() || t('why.locked') : '')); return;
    }
    if (error) root.appendChild(h('p', { class: 'hint warn' }, msg(error)));
    root.appendChild(h('p', { class: 'hint' + (data.payments_available ? '' : ' warn') }, L(data.payments_available ? 'billing.networkNote' : 'billing.unavailable')));
    var email = h('div'); renderEmail(email); root.appendChild(email);
    root.appendChild(h('div', { class: 'billing-wallet row wrap' }, h('strong', null, t('billing.balance', { amount: money(data.wallet.balance) })), button(L('billing.topup'), topup, why(true)), button(L(data.wallet.auto_renew ? 'billing.disableRenew' : 'billing.enableRenew'), autoRenew, why(false)), button(L('common.refresh'), function () { return B.load(true); }, mutation ? t('common.loading') : '')));
    root.appendChild(h('p', { class: 'muted sm' }, L('billing.renewNote')));
    var grid = h('div', { class: 'billing-catalog' });
    data.catalog.forEach(function (item) {
      if (!labels[item.id] || !Number.isFinite(micro(item.price))) return;
      var balanceWhy = why(false) || (micro(data.wallet.balance) >= micro(item.price) ? '' : t('billing.insufficient'));
      grid.appendChild(h('article', { class: 'billing-price' }, h('h3', null, term(item.id)), h('strong', null, money(item.price) + ' USDT'), h('span', { class: 'muted sm' }, L('billing.totalPrice')), button(L('billing.payUSDT'), function () { return checkout('plan', item.id); }, why(true), true), button(L('billing.balancePay'), function () { return purchase(item); }, balanceWhy)));
    }); root.appendChild(grid);
    root.appendChild(h('h3', null, L('billing.orders')));
    var orders = h('div', { class: 'billing-orders' });
    (data.orders || []).forEach(function (o) {
      orders.appendChild(h('div', { class: 'billing-history' }, h('span', null, o.kind === 'plan' ? term(o.sku) : t('billing.topup')), h('span', null, o.amount + ' USDT'), h('span', null, t('billing.status.' + o.status)), button(L('billing.details'), function () { B.openOrder(o); }, mutation ? t('common.loading') : '')));
    }); root.appendChild(data.orders.length ? orders : h('p', { class: 'muted' }, L('billing.noOrders')));
    root.appendChild(h('h3', null, L('billing.ledger')));
    (data.ledger || []).forEach(function (r) { root.appendChild(h('div', { class: 'billing-history' }, h('span', null, t('billing.ledger.' + r.kind)), h('span', null, r.delta + ' USDT'), h('span', { class: 'muted sm' }, TP.fmt.dateTime(r.created_at)))); });
    if (!data.ledger.length) root.appendChild(h('p', { class: 'muted' }, L('billing.noLedger')));
  }
  function renderEmail(root) {
    TP.clear(root);
    if (!data) { root.appendChild(h('span', { class: 'muted sm' }, error ? msg(error) : t('common.loading'))); return; }
    root.appendChild(h('p', null, ui.badge(L(data.email.verified ? 'billing.emailVerified' : 'billing.emailUnverified'), data.email.verified ? 'ok' : 'warn'), ' ' + data.email.address));
    if (data.email.verified) return;
    var cooldown = resendUntil > Date.now();
    var reason = !canUse() ? TP.why.helper() || t('why.locked') : mutation ? t('common.loading') : !data.email.mail_available ? t('billing.mailUnavailable') : cooldown ? t('billing.resendWait') : '';
    root.appendChild(button(L('billing.sendVerification'), async function () {
      if (reason) return;
      var r = await write('email/send', {});
      if (r && r.sent) { resendUntil = Date.now() + (r.retry_after || 60) * 1000; redraw(); ui.toast(t('billing.mailSent'), 'ok'); }
    }, reason));
    root.appendChild(button(L('billing.checkVerification'), function () { return B.load(true); }, mutation ? t('common.loading') : ''));
    root.appendChild(h('p', { class: 'muted sm' }, L(data.email.mail_available ? 'billing.verifyNote' : 'billing.mailUnavailable')));
  }
  B.mount = function () { var root = h('div', { class: 'billing' }); mounts.push(root); render(root); return root; };
  B.mountEmail = function () { var root = h('div', { class: 'billing-email' }); emailMounts.push(root); renderEmail(root); return root; };
  B.openOrder = function (order) {
    if (!order || !/^[a-z0-9]{15}$/.test(order.id) || typeof order.amount !== 'string' || !/^\d+\.\d{6}$/.test(order.amount) || !/^T[1-9A-HJ-NP-Za-km-z]{33}$/.test(order.address)) return;
    var mine = epoch, timer, closed = false, busy = false, failures = 0, current = order, revision = 0;
    var body = h('div', { class: 'billing-invoice' }), dlg;
    function schedule() { clearTimeout(timer); if (!closed && current.status === 'pending') timer = setTimeout(refresh, document.hidden ? 15000 : Math.min(30000, failures ? 5000 * failures : 3000)); }
    function paint(note) {
      TP.clear(body);
      var payable = current.status === 'pending' && current.expires_at * 1000 > Date.now();
      body.appendChild(h('p', { class: 'hint warn' }, L(payable ? 'billing.exactNote' : 'billing.invoiceClosed')));
      var copyReason = payable ? '' : t('billing.invoiceClosed');
      var copyAmount = button(L('billing.copyAmount'), function () { return ui.copy(current.amount); }, copyReason), copyAddress = button(L('billing.copyAddress'), function () { return ui.copy(current.address); }, copyReason);
      body.appendChild(h('div', { class: 'billing-exact' }, h('label', null, L('billing.exactAmount'), h('code', null, current.amount + ' USDT')), copyAmount));
      body.appendChild(h('div', { class: 'billing-exact' }, h('label', null, L('billing.address'), h('code', null, current.address)), copyAddress));
      body.appendChild(h('p', { class: 'muted sm' }, t('billing.expires', { date: TP.fmt.dateTime(current.expires_at) })));
      body.appendChild(h('p', { role: 'status', 'aria-live': 'polite' }, t('billing.status.' + current.status), note ? ' · ' + note : ''));
      if (current.status === 'credited_late') body.appendChild(h('p', { class: 'hint warn' }, L('billing.lateNote')));
      dlg.setActions([{ label: t('common.close'), cancel: true }, { label: t('common.refresh'), keep: true, disabled: busy, onClick: function () { return refresh(true); } }, { label: t('billing.cancelInvoice'), keep: true, kind: 'soft-bad', disabled: current.status !== 'pending' || busy, onClick: async function () {
        var yes = await ui.confirmDialog({ title: t('billing.cancelInvoice'), message: t('billing.cancelNote'), confirmText: t('billing.cancelInvoice'), danger: true });
        if (yes && !closed && mine === epoch) { revision++; var r = await write('billing/cancel', { id: current.id }); if (r && !closed) { current = r.order; paint(); schedule(); } }
      } }]);
    }
    async function refresh(manual) {
      if (closed || busy || mine !== epoch || S.locked || mutation) { schedule(); return; }
      if (document.hidden && !manual) { schedule(); return; }
      busy = true;
      var version = revision;
      try {
        var r = await TP.helper('GET', '/api/billing/order', { q: { id: current.id }, timeout: 12000 });
        if (closed || mine !== epoch || version !== revision) return;
        if (!r.order || r.order.id !== current.id || r.order.amount !== current.amount || r.order.address !== current.address) throw TP.mkErr('api', t('error.generic'));
        var previous = current.status; current = r.order; failures = 0;
        if (previous === 'pending' && current.status !== 'pending') { await B.load(true); TP.plan.load(true); }
        busy = false; paint();
      } catch (e) { failures++; if (!closed && mine === epoch) { busy = false; paint(msg(e)); } }
      finally { busy = false; schedule(); }
    }
    dlg = ui.modal({ title: t('billing.invoice'), icon: 'pro', body: body, size: 'md', onClose: function () { closed = true; clearTimeout(timer); dialogs = dialogs.filter(function (d) { return d !== dlg; }); } });
    dialogs.push(dlg); paint(); schedule();
  };
  TP.on('auth', function () { epoch++; data = null; error = null; pending = null; loadedAt = 0; mutation = false; keys = {}; resendUntil = 0; dialogs.slice().forEach(function (d) { d.close(); }); redraw(); });
  TP.on('lang', redraw);
  TP.on('helper', function () { redraw(); });
  setInterval(function () { if (resendUntil && Date.now() >= resendUntil) { resendUntil = 0; redraw(); } }, 1000);
})();
