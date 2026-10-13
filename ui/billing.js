/* Shared Mac/Windows membership UI. The cloud is the only authority for prices,
 * receipt status and balances. Requests are idempotent; losing a response never
 * creates a second invoice or a second wallet charge on retry.
 * 设置 → 会员 (套餐状态在 v-settings.js 的 renderPlan, 功能清单在这块之后): 常驻说明 → 一行操作 (购买会员 / 续费会员 · 充值余额)
 * → 钱包行 (余额 + 按月自动续费开关) → 最近订单 (表格, 每页 10 条, 服务端分页 orders_page / orders_per_page) → 余额明细 (先显示 10 条)。
 * 「购买会员」只打开一个弹窗: 选期限 (单选卡片, 12 个月推荐) + 付款方式 (USDT 付款 | 余额支付)。
 * 订单还能不能付款只看 pay_by (1 小时付款时间), 从不看 expires_at (24 小时的收款金额保留期)。 */
(function () {
  'use strict';
  var TP = window.TP, S = TP.S, h = TP.h, ui = TP.ui, I = window.I18N, t = I.t, L = I.L;
  var B = TP.billing = {}, data = null, error = null, pending = null, loadedAt = 0, epoch = 0;
  var busyKeys = {}, ordering = false, keys = {}, mounts = [], emailMounts = [], dialogs = [], resendUntil = 0;   // busyKeys: 按操作区分 (只转圈被点的那个按钮), 不再是全局标志
  var PER_PAGE = 10, LEDGER_FIRST = 10, RECOMMENDED = 'y1', PRESETS = [10, 20, 50, 100], TOPUP_MIN = 4, TOPUP_MAX = 1000;
  var ordersPage = 1, firstOrders = [], ledgerAll = false, payWatch = 0, seq = 0;   // firstOrders: 最近一次读到的第 1 页订单 (待付款的订单只可能在这一页: 24 小时内最多 5 个订单)
  var labels = { m1: 'billing.term.m1', m3: 'billing.term.m3', m6: 'billing.term.m6', y1: 'billing.term.y1', y2: 'billing.term.y2', y3: 'billing.term.y3', y5: 'billing.term.y5' };
  var ST_KIND = { pending: 'info', overdue: 'warn', paid: 'ok', activated: 'ok', manual: 'warn', credited_late: 'warn', expired: 'neutral', cancelled: 'neutral' };
  function micro(v) { if (typeof v !== 'string' || !/^\d{1,7}\.\d{6}$/.test(v)) return NaN; return Number(v.replace('.', '')); }
  function money(v) { return typeof v === 'string' && /^\d+\.\d{6}$/.test(v) ? v.replace(/\.0+$/, '').replace(/(\.\d*?[1-9])0+$/, '$1') : '—'; }
  /* 余额明细的变动: "-4.000000" -> "-4", "35.100000" -> "+35.1" */
  function signed(v) { if (typeof v !== 'string' || !/^-?\d+\.\d{6}$/.test(v)) return '—'; var neg = v.charAt(0) === '-'; return (neg ? '-' : '+') + money(neg ? v.slice(1) : v); }
  /* micro-USDT -> 最多两位小数的文字 (每月价格): 2916666.67 -> "2.92", 2000000 -> "2" */
  function usd2(n) { var c = Math.round(n / 10000), f = c % 100; return Math.floor(c / 100) + (f ? '.' + (f < 10 ? '0' + f : String(f)).replace(/0$/, '') : ''); }
  function fmtLeft(ms) { var s = Math.max(0, Math.floor(ms / 1000)), hh = Math.floor(s / 3600), mm = Math.floor(s % 3600 / 60), ss = s % 60; return (hh ? hh + ':' : '') + (hh && mm < 10 ? '0' : '') + mm + ':' + (ss < 10 ? '0' : '') + ss; }
  function term(sku) { return labels[sku] ? t(labels[sku]) : String(sku || ''); }
  /* 某个时刻 (秒): 今天只显示时:分, 否则带日期 */
  function whenText(sec) { var d = new Date(sec * 1000), n = new Date(); return d.toDateString() === n.toDateString() ? TP.fmt.clock(sec) : TP.fmt.date(sec) + ' ' + TP.fmt.clock(sec); }
  function msg(e) {
    if (e && e.code === 'E_ORDER_LIMIT') {                          // 24 小时内最多 N 个订单: 用 retry_after 算出什么时候可以再下单 (向上取整到分钟, 不会早于真正放行的时间)
      var d = e.data || {}, n = Number.isInteger(d.limit) && d.limit > 0 && d.limit <= 1000 ? d.limit : 5, ra = d.retry_after;
      return Number.isInteger(ra) && ra >= 1 && ra <= 86400 ? t('billing.err.E_ORDER_LIMIT', { n: n, time: whenText(Math.ceil((Date.now() / 1000 + ra) / 60) * 60) }) : t('billing.orderLimitLater', { n: n });
    }
    return e && e.code && I.has('billing.err.' + e.code) ? t('billing.err.' + e.code) : TP.errMsg(e);
  }
  function canUse() { return !S.locked && !TP.why.helper(); }
  // 收款地址二维码 (vendor/qrcode.js, 内联 SVG; 不用 data: 图片, 因为生产环境的 CSP 是 img-src 'self'). 只编码地址本身, 金额仍以文字显示.
  function qrBlock(text) {
    if (typeof window.qrcode !== 'function') return null;
    var q = window.qrcode(0, 'M'); q.addData(text); q.make();
    var box = h('div', { class: 'billing-qr' });
    box.innerHTML = q.createSvgTag(4, 4, t('billing.qrLabel'), '');   // 内容只来自已校验的 TRON 地址 (见 openOrder 的正则)
    return box;
  }
  /* 幂等键: 优先 crypto.randomUUID; 没有 (旧浏览器 / 非安全上下文) 就退回 getRandomValues, 再退回 Math.random。只用来让「重试不会重复下单」, 不是密钥, 不能让它抛错。 */
  function newKey() {
    try { if (window.crypto && typeof window.crypto.randomUUID === 'function') return window.crypto.randomUUID(); } catch (e) { /* 退回 */ }
    var a = [], i, s = '';
    try { var u = new Uint8Array(16); window.crypto.getRandomValues(u); for (i = 0; i < 16; i++) a.push(u[i]); } catch (e) { a = []; }
    for (i = a.length; i < 16; i++) a.push(Math.floor(Math.random() * 256));
    for (i = 0; i < 16; i++) s += ('0' + a[i].toString(16)).slice(-2);
    return s.slice(0, 8) + '-' + s.slice(8, 12) + '-4' + s.slice(13, 16) + '-a' + s.slice(17, 20) + '-' + s.slice(20, 32);
  }
  /* 还能付款 = 等待付款且还在 1 小时付款时间内 (pay_by); 过了 pay_by 服务器就允许新订单, 这里也不再挡 */
  function payable(o) { return !!o && o.status === 'pending' && +o.pay_by * 1000 > Date.now(); }
  function activeOrder() { return data ? firstOrders.filter(payable)[0] : undefined; }
  function why(payments) {
    if (!canUse()) return TP.why.helper() || t('why.locked');
    if (!data) return error ? msg(error) : t('common.loading');
    if (!data.email.verified) return t('billing.verifyFirst');
    if (payments && !data.payments_available) return t('billing.unavailable');
    if (payments && activeOrder()) return t('billing.pendingFirst');
    return '';
  }
  /* 「去处理」: 有未完成的订单时直接打开它 */
  function usdtFix() { var o = activeOrder(); return o ? { label: t('billing.viewPending'), fn: function () { B.openOrder(o); } } : null; }
  function monthlyStr() {
    var v = data && data.wallet && data.wallet.monthly_price;
    if (micro(v) > 0) return v;
    var m1 = data ? data.catalog.filter(function (c) { return c && c.months === 1 && micro(c.price) > 0; })[0] : null;
    return m1 ? m1.price : '4.000000';
  }
  function balance() { var b = data ? micro(data.wallet.balance) : NaN; return Number.isFinite(b) ? b : 0; }
  function affordable(item) { return !!data && Number.isFinite(micro(item.price)) && balance() >= micro(item.price); }
  function shortfall(price) { return Math.max(TOPUP_MIN, Math.min(TOPUP_MAX, Math.ceil((price - balance()) / 1000000))); }
  /* kind: true = primary, 或 'ghost' 等; o: {icon, fix (不可用时提示里的「去处理」), focus (重画后要找回焦点的标记)} */
  function button(label, fn, reason, kind, bk, o) {
    o = o || {};
    var b = ui.btn(label, { kind: kind === true ? 'primary' : kind || undefined, sm: true, icon: o.icon });
    ui.avail(b, reason || '', reason ? o.fix || null : null); ui.act(b, fn);
    if (bk) b._busyKey = bk;
    if (o.focus) b._focusKey = o.focus;
    if ((bk && busyKeys[bk]) || reason === t('common.loading')) ui.actionBusy(b, true);
    return b;
  }
  function anyBusy() { return Object.keys(busyKeys).length > 0; }
  function walk(fn) { function w(n) { if (!n) return; fn(n); Array.prototype.forEach.call(n.children || [], w); } mounts.concat(emailMounts).forEach(w); }
  /* 只更新带这个 key 的按钮的转圈状态, 不重建列表 (重建会让同一卡片上所有按钮一起闪) */
  function setBusy(bk, on) { walk(function (n) { if (n._busyKey === bk) ui.actionBusy(n, on); }); }
  /* 重画后把焦点放回刚才点的那个按钮 (翻页时键盘用户不会丢失位置) */
  function refocus(key) { var hit = null; walk(function (n) { if (!hit && n._focusKey === key) hit = n; }); if (hit && typeof hit.focus === 'function') { try { hit.focus({ preventScroll: true }); } catch (e) { /* 忽略 */ } } }
  function redraw() { mounts.forEach(render); emailMounts.forEach(renderEmail); dialogs.forEach(function (d) { if (d._sync) d._sync(); }); TP.emit('billing', data); }
  function paged(r) { return !!r && Number.isInteger(r.orders_total) && r.orders_total >= 0 && Number.isInteger(r.orders_page) && r.orders_page >= 1; }
  B.load = function (force) {
    if (!canUse()) return Promise.resolve(null);
    if (pending) return pending;
    if (!force && data && Date.now() - loadedAt < 60000) return Promise.resolve(data);
    var mine = epoch, page = ordersPage;
    pending = TP.helper('GET', '/api/billing', { q: { orders_page: page, orders_per_page: PER_PAGE }, timeout: 15000 }).then(function (r) {
      if (mine !== epoch) return null;
      if (!r || !r.email || !r.wallet || !Array.isArray(r.catalog) || !Array.isArray(r.orders) || !Array.isArray(r.ledger)) throw TP.mkErr('api', t('error.generic'));
      var justVerified = !!(data && data.email && data.email.verified === false && r.email.verified === true);
      /* 旧的云端不认分页参数 (没有 orders_total): 返回最近 30 个订单, 在本机分页 */
      if (!paged(r)) firstOrders = r.orders;
      else { if (page === ordersPage) ordersPage = r.orders_page; if (r.orders_page === 1) firstOrders = r.orders; }
      data = r; error = null; loadedAt = Date.now(); redraw();
      if (justVerified) TP.plan.load(true);                                   // 刚验证完邮箱: 套餐里「官方线路」的原因从 verify 变成可用, 不用等缓存过期
      return r;
    }).catch(function (e) { if (mine === epoch) { error = e; redraw(); } return null; }).finally(function () { if (mine === epoch) { pending = null; } });
    return pending;
  };
  /* 写操作成功后刷新数据 (回到订单第 1 页, 新订单在最前面), 不阻塞调用方 (下单弹窗要马上打开) */
  function refresh() { ordersPage = 1; (pending || Promise.resolve()).then(function () { B.load(true); TP.plan.load(true); }); }
  async function write(op, body, scope, bk) {
    var key = bk || op;
    if (busyKeys[key]) return null;
    var mine = epoch;
    if (scope) { if (!keys[scope]) keys[scope] = newKey(); body.request_key = keys[scope]; }
    busyKeys[key] = true; setBusy(key, true);
    try {
      var r = await TP.helper('POST', '/api/' + op, { body: JSON.stringify(body), timeout: 18000 });
      if (mine !== epoch) return null;
      if (scope) delete keys[scope];
      refresh();
      return r;
    } catch (e) {
      if (mine === epoch) { if (e.code === 'E_ORDER_PENDING') { ordersPage = 1; await B.load(true); } ui.toast(msg(e), 'err'); }
      return null;
    } finally { if (mine === epoch) { delete busyKeys[key]; setBusy(key, false); } }
  }
  /* 创建 USDT 付款订单, 成功返回订单 (由调用方关掉自己的弹窗再打开付款订单), 失败返回 null (原因已经是一条提示) */
  async function checkout(kind, sku, amount) {
    if (ordering || why(true)) return null;
    ordering = true;
    try {
      var body = kind === 'plan' ? { kind: kind, sku: sku } : { kind: kind, amount: amount };
      var r = await write('billing/checkout', body, 'invoice:' + JSON.stringify(body), kind === 'plan' ? 'plan:' + sku : 'topup');
      return r && r.order ? r.order : null;
    } finally { ordering = false; }
  }
  /* 余额支付: 购买弹窗里已经写明扣多少、买什么, 「确认支付」就是确认 */
  async function purchase(item) {
    if (why(false) || !affordable(item)) return false;
    var r = await write('billing/purchase', { sku: item.id }, 'wallet:' + item.id, 'wallet:' + item.id);
    if (!r) return false;
    ui.toast(Number.isInteger(r.expires_at) && r.expires_at > 0 ? t('billing.purchasedUntil', { term: term(item.id), date: TP.fmt.date(r.expires_at) }) : t('billing.purchased', { term: term(item.id) }), 'ok');
    return true;
  }

  /* ================= 购买会员: 一个弹窗 (期限 + 付款方式) ================= */
  function openPicker() {
    if (!data || why(false)) return;
    var items = data.catalog.filter(function (c) { return c && labels[c.id] && micro(c.price) > 0 && Number.isInteger(c.months) && c.months > 0; });
    if (!items.length) { ui.toast(t('error.generic'), 'warn'); return; }
    var sel = items.filter(function (c) { return c.id === RECOMMENDED; })[0] || items[0], method = why(true) && affordable(sel) ? 'wallet' : 'usdt', dlg = null;
    var name = 'bt' + (++seq), month = micro(monthlyStr());
    var cards = items.map(function (it) {
      var p = micro(it.price), per = p / it.months, full = month * it.months, save = month > 0 ? Math.floor((full - p) * 100 / full) : 0;   // 省多少: 和按月买 (wallet.monthly_price) 比, 向下取整, 不夸大
      var inp = h('input', { type: 'radio', name: name, value: it.id, checked: it.id === sel.id, on: { change: function () { sel = it; sync(); } } });
      var lab = h('label', { class: 'billing-term' + (it.id === sel.id ? ' on' : '') }, inp,
        h('span', { class: 'bt-main' }, h('span', { class: 'bt-name' }, h('b', null, term(it.id)), it.id === RECOMMENDED ? ui.badge(L('billing.recommended'), 'pro') : null),
          h('span', { class: 'muted sm' }, t(per % 10000 === 0 ? 'billing.perMonthExact' : 'billing.perMonth', { amount: usd2(per) }))),
        h('span', { class: 'bt-side' }, h('strong', null, money(it.price) + ' USDT'), save > 0 ? ui.badge(t('billing.save', { pct: save }), 'ok') : null));
      lab._item = it; lab._inp = inp;
      return lab;
    });
    var seg = ui.seg(L('billing.method'), [{ v: 'usdt', label: L('billing.method.usdt') }, { v: 'wallet', label: L('billing.method.wallet') }], function (v) { method = v; sync(); }, { onSame: function () { /* 已选中: 什么都不用做 */ } });
    var note = h('p', { class: 'muted sm', 'aria-live': 'polite' });
    function walletWhy() { return why(false) || (affordable(sel) ? '' : t('billing.insufficientFor', { balance: money(data.wallet.balance), price: money(sel.price) })); }
    function walletFix() { return !why(false) && !why(true) && !affordable(sel) ? { label: t('billing.topup'), fn: function () { var need = shortfall(micro(sel.price)); if (dlg) dlg.close(); topup(need); } } : null; }
    function sync() {
      if (!data || !dlg) return;
      cards.forEach(function (lab) { lab.className = 'billing-term' + (lab._item === sel ? ' on' : ''); });
      var uw = why(true), ww = walletWhy(), reason = method === 'usdt' ? uw : ww;
      seg.avail('usdt', uw, uw ? usdtFix() : null); seg.avail('wallet', ww, ww ? walletFix() : null); seg.set(method);
      note.className = reason ? 'hint warn' : 'muted sm';
      TP.setText(note, reason || (method === 'usdt' ? t('billing.usdtNote') : t('billing.purchaseConfirm', { amount: money(sel.price), term: term(sel.id), balance: money(data.wallet.balance) })));
      dlg.setActions([{ label: t('common.cancel'), cancel: true }, { label: t(method === 'usdt' ? 'common.next' : 'billing.confirmPay'), kind: 'primary', unavail: reason ? { reason: reason, fix: method === 'usdt' ? usdtFix() : walletFix() } : null, onClick: go }]);
    }
    async function go(api) {
      if (!data) return false;
      if (method === 'usdt') {
        if (why(true)) { ui.toast(why(true), 'warn'); return false; }
        var o = await checkout('plan', sel.id);
        if (!o) return false;                                                   // 失败: 弹窗留着, 原因已是提示; 再点会用同一个幂等键, 不会多下单
        api.close(true); B.openOrder(o); return false;
      }
      if (walletWhy()) { ui.toast(walletWhy(), 'warn'); return false; }
      return purchase(sel);                                                     // true = 关闭弹窗; false = 留着 (原因已是提示)
    }
    var body = h('div', { class: 'billing-pick' },
      h('div', { class: 'billing-terms', role: 'radiogroup', 'aria-label': L('billing.chooseTerm') }, cards),
      h('div', { class: 'billing-pay' }, h('span', { class: 'billing-pay-l' }, L('billing.method')), seg.el, note));
    dlg = ui.modal({ title: t(data.plan && data.plan.code === 'pro' ? 'billing.renewPlan' : 'billing.buy'), icon: 'pro', size: 'sm', body: body, onClose: function () { dialogs = dialogs.filter(function (d) { return d !== dlg; }); } });
    dlg._sync = sync; dialogs.push(dlg); sync();
    var cur = cards.filter(function (lab) { return lab._item === sel; })[0];
    if (cur && typeof cur._inp.focus === 'function') { try { cur._inp.focus({ preventScroll: true }); } catch (e) { /* 忽略 */ } }
    return dlg;
  }

  /* ================= 按月自动续费 ================= */
  function renewToast(r, enabled) {
    if (!enabled) return [t('billing.renewOff'), 'ok'];
    var price = money(micro(r.monthly_price) > 0 ? r.monthly_price : monthlyStr());
    if (r.charged === true) return r.needs_topup === true ? [t('billing.renewChargedLow', { price: price }), 'warn'] : [t('billing.renewCharged', { price: price }), 'ok'];
    if (r.needs_topup === true) return [t('billing.renewWaiting', { price: price }), 'warn'];
    return [t('billing.renewOn'), 'ok'];
  }
  /* 余额不够一个月时开启: 说明现在不会扣款, 让用户选「先充值 / 仍然开启 / 取消」-> 'topup' | 'enable' | null */
  function lowBalanceDialog(price) {
    return new Promise(function (resolve) {
      var d = ui.modal({ title: t('billing.renew'), icon: 'warning', iconKind: 'warn', size: 'sm',
        body: h('div', { class: 'cfm' }, h('p', { class: 'cfm-m' }, t('billing.renewLow', { balance: money(data.wallet.balance), price: price })), h('p', { class: 'muted sm' }, t('billing.renewLowNote'))),
        actions: [{ label: t('common.cancel'), cancel: true }, { label: t('billing.renewAnyway'), value: 'enable' }, { label: t('billing.topupFirst'), kind: 'primary', value: 'topup', unavail: why(true) ? { reason: why(true), fix: usdtFix() } : null }],
        onClose: function (v) { dialogs = dialogs.filter(function (x) { return x !== d; }); resolve(v === 'enable' || v === 'topup' ? v : null); } });
      dialogs.push(d);
    });
  }
  async function autoRenew() {
    if (why(false)) return;
    var enabled = !data.wallet.auto_renew, price = money(monthlyStr());
    if (enabled && balance() < micro(monthlyStr())) {
      var choice = await lowBalanceDialog(price);
      if (choice === 'topup') { topup(shortfall(micro(monthlyStr()))); return; }
      if (choice !== 'enable') return;
    } else {
      var ok = await ui.confirmDialog({ title: t('billing.renew'), message: t(enabled ? 'billing.renewConfirm' : 'billing.renewDisableConfirm', { price: price }), confirmText: t(enabled ? 'billing.enableRenew' : 'billing.disableRenew') });
      if (!ok) return;
    }
    if (why(false)) return;
    var r = await write('billing/auto-renew', { enabled: enabled }, undefined, 'renew');
    if (r) { var m = renewToast(r, enabled); ui.toast(m[0], m[1]); }
  }
  /* 开关样式的按钮 (role=switch): 状态一眼可见; 点击先确认再请求 */
  function renewSwitch() {
    var on = !!data.wallet.auto_renew;
    var b = h('button', { class: 'billing-sw', type: 'button', role: 'switch', 'aria-checked': on ? 'true' : 'false' }, h('span', { class: 'sw', 'aria-hidden': 'true' }, h('span', { class: 'sw-ui' })), h('span', null, L('billing.autoRenew')), h('span', { class: 'muted sm' }, L(on ? 'billing.renewOnState' : 'billing.renewOffState')));
    ui.avail(b, why(false)); ui.act(b, autoRenew); b._busyKey = 'renew';
    if (busyKeys.renew) ui.actionBusy(b, true);
    return b;
  }

  /* ================= 充值余额: 4–1000 的整数 USDT ================= */
  function topup(prefill) {
    if (why(true)) return;
    var dlg = null, hid = 'btu' + (++seq), msgEl = h('span', { class: 'billing-tu-msg', id: hid }, t('billing.topupRange'));
    var input = h('input', { class: 'inp', type: 'text', inputmode: 'numeric', autocomplete: 'off', maxlength: '7', placeholder: t('billing.topupPh'), 'aria-describedby': hid, value: prefill ? String(prefill) : '', on: {
      input: function () { check(false); },
      keydown: function (e) { if (e.key === 'Enter') { e.preventDefault(); var b = dlg && dlg.foot && dlg.foot.querySelector('.btn.primary'); if (b) b.click(); } } } });
    var chips = h('div', { class: 'billing-chips', role: 'group', 'aria-label': t('billing.topupPresets') }, PRESETS.map(function (n) {
      var c = h('button', { class: 'chip billing-chip', type: 'button', on: { click: function () { input.value = String(n); check(false); try { input.focus(); } catch (e) { /* 忽略 */ } } } }, n + ' USDT');
      c._v = String(n); return c;
    }));
    /* 返回规范化的金额 ("020" -> "20"), 不合格时返回 '' 并在输入框下面说明原因 */
    function check(final) {
      var v = String(input.value || '').trim().replace(/[\uFF10-\uFF19]/g, function (c) { return String.fromCharCode(c.charCodeAt(0) - 0xFEE0); }), err = '';   // 全角数字也认
      if (!v) err = final ? t('billing.topupEmpty') : '';
      else if (!/^[0-9]+$/.test(v)) err = t('billing.topupWhole');
      else if (+v < TOPUP_MIN || +v > TOPUP_MAX) err = t('billing.topupOut');
      msgEl.className = 'billing-tu-msg' + (err ? ' bad' : '');
      TP.setText(msgEl, err || t('billing.topupRange'));
      input.setAttribute('aria-invalid', err ? 'true' : 'false');
      Array.prototype.forEach.call(chips.children, function (c) { c.className = 'chip billing-chip' + (!err && v && c._v === String(+v) ? ' on' : ''); });
      return err || !v ? '' : String(+v);
    }
    dlg = ui.modal({ title: t('billing.topup'), icon: 'pro', size: 'sm', body: h('div', { class: 'billing-topup' }, ui.field(L('billing.topupAmount'), input, msgEl), chips), actions: [
      { label: t('common.cancel'), cancel: true },
      { label: t('billing.createInvoice'), kind: 'primary', onClick: async function (api) {
        var v = check(true);
        if (!v) return false;
        if (why(true)) { ui.toast(why(true), 'warn'); return false; }
        var o = await checkout('topup', '', v);
        if (!o) return false;
        api.close(true); B.openOrder(o); return false;
      } }
    ], onClose: function () { dialogs = dialogs.filter(function (d) { return d !== dlg; }); } });
    dialogs.push(dlg);
    if (prefill) check(false);
    return dlg;
  }

  /* 为什么现在不能付款 / 为什么按钮是灰的: 常驻的行内说明 (不再只靠灰色按钮 + 点击后 5 秒的提示)。每一条都说明原因, 能自己解决的还带一个动作。 */
  function signInAgain() { return TP.auth && TP.auth.logout ? TP.auth.logout('switch') : null; }
  function notices() {
    var list = [], o;
    if (!canUse()) return [{ kind: 'warn', text: TP.why.helper() || t('why.locked') }];
    if (error) {
      list.push(error.code === 'E_AUTH' && TP.auth && TP.auth.logout
        ? { kind: 'bad', text: msg(error), action: { label: L('billing.signInAgain'), fn: signInAgain } }
        : { kind: 'warn', text: msg(error), action: { label: L('common.retry'), fn: function () { return B.load(true); } } });
    }
    if (!data) return list;
    /* 邮箱验证在「账号与设备」里 (这里不再重复那一块): 能发邮件就带「去验证邮箱」, 发不了就带「再检查一次」 */
    if (!data.email.verified) list.push(data.email.mail_available
      ? { kind: 'warn', text: t('billing.notice.verify'), action: TP.settingsTab ? { label: L('plan.verifyGo'), fn: function () { TP.settingsTab('account'); } } : null }
      : { kind: 'warn', text: t('billing.notice.verifyNoMail'), action: { label: L('billing.checkAgain'), fn: function () { return B.load(true); } } });
    if ((o = activeOrder())) list.push({ kind: 'info', text: t('billing.notice.pending', { amount: money(o.amount), time: TP.fmt.clock(o.pay_by) }), action: { label: L('billing.viewPending'), fn: function () { B.openOrder(o); } } });
    if (!data.payments_available) list.push({ kind: 'info', text: t('billing.notice.closed') });
    return list;
  }
  function renderNotices(box) {
    TP.clear(box);
    notices().forEach(function (n) {
      var row = h('div', { class: 'hint billing-notice ' + n.kind, role: 'status' }, h('p', null, n.text));
      if (n.action) row.appendChild(button(n.action.label, n.action.fn, ''));
      box.appendChild(row);
    });
  }

  /* ================= 最近订单 (表格 + 上一页 / 下一页) / 余额明细 ================= */
  function stKey(o) { return o.status === 'pending' && !payable(o) ? 'overdue' : String(o.status || ''); }
  function statusBadge(o) { var k = stKey(o); return ui.badge(I.has('billing.st.' + k) ? t('billing.st.' + k) : k, ST_KIND[k] || 'neutral'); }
  function orderWhat(o) { return o.kind === 'plan' ? t('billing.what.plan', { term: term(o.sku) }) : o.kind === 'topup' ? t('billing.what.topup') : String(o.kind || ''); }
  function ordersTotal() { return paged(data) ? data.orders_total : data.orders.length; }
  function curPage() { return paged(data) ? data.orders_page : Math.max(1, Math.min(ordersPage, Math.ceil(data.orders.length / PER_PAGE) || 1)); }
  function pageRows() { if (paged(data)) return data.orders; var p = curPage(); return data.orders.slice((p - 1) * PER_PAGE, p * PER_PAGE); }
  function goPage(n, focus) {
    if (!data) return null;
    ordersPage = Math.max(1, Math.min(1000, n));
    if (!paged(data)) { redraw(); refocus(focus); return null; }
    return (pending || Promise.resolve()).then(function () { return B.load(true); }).then(function () { refocus(focus); });
  }
  function th(key, cls) { return h('th', { scope: 'col', class: cls || null }, L(key)); }
  function section(titleKey) { return h('section', { class: 'billing-sec' }, h('h3', { class: 'billing-h' }, L(titleKey))); }
  function ordersBlock() {
    var box = section('billing.orders'), total = ordersTotal(), page = curPage(), pages = Math.max(1, Math.ceil(total / PER_PAGE)), rows = pageRows();
    if (!rows.length && page === 1) { box.appendChild(h('p', { class: 'muted sm' }, L('billing.noOrders'))); return box; }
    var tb = h('tbody');
    rows.forEach(function (o) {
      tb.appendChild(h('tr', null,
        h('td', { class: 'c-name', 'data-l': t('billing.col.item') }, orderWhat(o)),
        h('td', { class: 'num', 'data-l': t('billing.col.amount') }, money(o.amount) + ' USDT'),
        h('td', { 'data-l': t('billing.col.status') }, statusBadge(o)),
        h('td', { class: 'muted', 'data-l': t('billing.col.time') }, TP.fmt.dateTime(o.created_at)),
        h('td', { class: 'c-act' }, button(L('billing.view'), function () { B.openOrder(o); }, '', 'ghost'))));
    });
    box.appendChild(h('div', { class: 'tbl-wrap' }, h('table', { class: 'tbl rt billing-tbl' }, h('thead', null, h('tr', null, th('billing.col.item'), th('billing.col.amount', 'num'), th('billing.col.status'), th('billing.col.time'), th('billing.col.view', 'c-act'))), tb)));
    if (pages > 1 || page > 1) {
      box.appendChild(h('nav', { class: 'billing-pg', 'aria-label': L('pager.aria') },
        button(L('pager.prev'), function () { return goPage(Math.min(page - 1, pages), 'pg-prev'); }, page <= 1 ? t('billing.pageFirst') : '', 'ghost', null, { icon: 'chevron-left', focus: 'pg-prev' }),     // 停在已经不存在的页 (订单变少了): 直接回到最后一页
        h('span', { class: 'muted sm' }, t('billing.pageOf', { page: page, pages: Math.max(pages, page) })),
        button(L('pager.next'), function () { return goPage(page + 1, 'pg-next'); }, page >= pages ? t('billing.pageLast') : '', 'ghost', null, { icon: 'chevron-right', focus: 'pg-next' })));
    }
    return box;
  }
  function ledgerBlock() {
    var box = section('billing.ledger'), list = data.ledger || [];
    if (!list.length) { box.appendChild(h('p', { class: 'muted sm' }, L('billing.noLedger'))); return box; }
    var tb = h('tbody');
    (ledgerAll ? list : list.slice(0, LEDGER_FIRST)).forEach(function (r) {
      var d = signed(r.delta);
      tb.appendChild(h('tr', null,
        h('td', { class: 'c-name', 'data-l': t('billing.col.item') }, I.has('billing.ledger.' + r.kind) ? t('billing.ledger.' + r.kind) : String(r.kind || '')),
        h('td', { class: 'num' + (d.charAt(0) === '+' ? ' plus' : ''), 'data-l': t('billing.col.amount') }, d + ' USDT'),
        h('td', { class: 'muted', 'data-l': t('billing.col.time') }, TP.fmt.dateTime(r.created_at))));
    });
    box.appendChild(h('div', { class: 'tbl-wrap' }, h('table', { class: 'tbl rt billing-tbl' }, h('thead', null, h('tr', null, th('billing.col.item'), th('billing.col.amount', 'num'), th('billing.col.time'))), tb)));
    if (!ledgerAll && list.length > LEDGER_FIRST) box.appendChild(h('div', { class: 'billing-more' }, button(L('billing.showMore'), function () { ledgerAll = true; redraw(); }, '', 'ghost')));
    return box;
  }

  function render(root) {
    TP.clear(root);
    if (!data) {
      var nb0 = h('div', { class: 'billing-notices' });
      if (error || !canUse()) { renderNotices(nb0); root.appendChild(nb0); } else root.appendChild(h('p', { class: 'muted' }, t('common.loading')));
      root.appendChild(button(L('common.retry'), function () { return B.load(true); }, !canUse() ? TP.why.helper() || t('why.locked') : ''));
      return;
    }
    var nb = h('div', { class: 'billing-notices' }); renderNotices(nb); root.appendChild(nb);
    var pro = !!(data.plan && data.plan.code === 'pro');
    root.appendChild(h('div', { class: 'billing-acts' },
      button(L(pro ? 'billing.renewPlan' : 'billing.buy'), openPicker, why(false), true, null, { icon: 'pro' }),
      button(L('billing.topup'), function () { topup(); }, why(true), false, 'topup', { fix: usdtFix() })));
    root.appendChild(h('div', { class: 'billing-wallet' }, h('strong', null, t('billing.balance', { amount: money(data.wallet.balance) })), renewSwitch(), h('span', { class: 'muted sm' }, t('billing.renewPrice', { price: money(monthlyStr()) }))));
    root.appendChild(ordersBlock());
    root.appendChild(ledgerBlock());
    var o = activeOrder(); payWatch = o ? +o.pay_by * 1000 : 0;               // 付款时间一到就重画 (提示消失, 按钮恢复), 不用等下一次读取
  }
  function renderEmail(root) {
    TP.clear(root);
    if (!data) { root.appendChild(h('span', { class: 'muted sm' }, error ? msg(error) : t('common.loading'))); return; }
    root.appendChild(h('p', null, ui.badge(L(data.email.verified ? 'billing.emailVerified' : 'billing.emailUnverified'), data.email.verified ? 'ok' : 'warn'), ' ' + data.email.address));
    if (data.email.verified) return;
    var cooldown = resendUntil > Date.now();
    var reason = !canUse() ? TP.why.helper() || t('why.locked') : busyKeys.email ? t('common.loading') : !data.email.mail_available ? t('billing.mailUnavailable') : cooldown ? t('billing.resendWait') : '';
    root.appendChild(button(L('billing.sendVerification'), async function () {
      if (reason) return;
      var r = await write('email/send', {}, undefined, 'email');
      if (r && r.sent) { resendUntil = Date.now() + (r.retry_after || 60) * 1000; redraw(); ui.toast(t('billing.mailSent'), 'ok'); }
    }, reason, false, 'email'));
    root.appendChild(button(L(data.email.mail_available ? 'billing.checkVerification' : 'billing.checkAgain'), function () { return B.load(true); }, ''));
    root.appendChild(h('p', { class: 'muted sm' }, L(data.email.mail_available ? 'billing.verifyNote' : 'billing.mailOffNote')));
  }
  B.mount = function () { var root = h('div', { class: 'billing' }); mounts.push(root); render(root); return root; };
  B.mountEmail = function () { var root = h('div', { class: 'billing-email' }); emailMounts.push(root); renderEmail(root); return root; };

  /* ================= 付款订单: 买什么 → 二维码 → 完整金额 (小数尾数标红) → 收款地址 (首尾各 6 位标红) → 倒计时 → 状态 ================= */
  B.openOrder = function (order) {
    if (!order || !/^[a-z0-9]{15}$/.test(order.id) || typeof order.amount !== 'string' || !/^\d+\.\d{6}$/.test(order.amount) || !/^T[1-9A-HJ-NP-Za-km-z]{33}$/.test(order.address)) return;
    var mine = epoch, timer = 0, tick = 0, closed = false, busy = false, failures = 0, current = order, revision = 0, recheckUntil = 0, note = '', sig = '', cdEl = null;
    var body = h('div', { class: 'billing-invoice' }), dlg;
    function live() { return current.status === 'pending' || current.status === 'manual'; }
    function schedule() { clearTimeout(timer); timer = 0; if (!closed && live()) timer = setTimeout(refresh, document.hidden ? 15000 : Math.min(30000, failures ? 5000 * failures : 3000)); }
    /* 每秒一次: 只更新倒计时文字; 付款时间到了 / 再次核实冷却结束 / 换了语言时才整块重画 (不打断焦点) */
    function arm() { if (!closed && live()) { if (!tick) tick = setInterval(onTick, 1000); } else if (tick) { clearInterval(tick); tick = 0; } }
    function stop() { closed = true; clearTimeout(timer); timer = 0; if (tick) { clearInterval(tick); tick = 0; } }
    function onTick() { if (closed || mine !== epoch) { stop(); return; } if (state() !== sig) paint(note); else if (cdEl) TP.setText(cdEl, countdown()); }
    function canRecheck() { return live() && +current.expires_at * 1000 > Date.now(); }       // 服务器在收款金额保留期内都接受「再次核实」
    function state() { return JSON.stringify([I.lang, current.status, payable(current), canRecheck(), recheckUntil > Date.now(), busy, note]); }
    function countdown() { return t('billing.countdown', { time: fmtLeft(+current.pay_by * 1000 - Date.now()), at: TP.fmt.clock(current.pay_by) }); }
    function statusText() { var k = stKey(current) === 'overdue' ? 'overdue' : current.status; return I.has('billing.status.' + k) ? t('billing.status.' + k) : String(k || ''); }
    function paint(n) {
      note = n || ''; TP.clear(body); sig = state(); cdEl = null;
      var pay = payable(current), st = current.status, a = current.address, shown = money(current.amount), dot = shown.indexOf('.');
      body.appendChild(h('div', { class: 'billing-inv-what' }, h('b', null, current.kind === 'plan' ? t('billing.inv.plan', { term: term(current.sku) }) : t('billing.inv.topup', { amount: money(current.price) })),
        h('span', { class: 'muted sm' }, t('billing.orderMeta', { id: current.id, time: TP.fmt.dateTime(current.created_at) }))));
      if (st === 'paid' || st === 'activated') body.appendChild(h('p', { class: 'hint ok' }, L(current.kind === 'plan' ? 'billing.paidNote.plan' : 'billing.paidNote.topup')));
      else if (!pay) body.appendChild(h('p', { class: 'hint warn' }, L(st === 'pending' ? 'billing.overdueNote' : 'billing.invoiceClosed')));
      if (pay) {
        var qr = qrBlock(a); if (qr) body.appendChild(qr);
        body.appendChild(h('p', { class: 'hint warn' }, L('billing.exactNote')));
      }
      /* 复制的就是显示的那串数字 (去掉多余的 0), 和钱包里要填的一致 */
      var copyReason = pay ? '' : t('billing.invoiceClosed');
      var copyAmount = button(L('billing.copyAmount'), function () { return ui.copy(shown, t('billing.amountCopied', { amount: shown })); }, copyReason, false, null, { icon: 'copy' });
      var copyAddress = button(L('billing.copyAddress'), function () { return ui.copy(a, t('billing.addrCopied', { head: a.slice(0, 6), tail: a.slice(-6) })); }, copyReason, false, null, { icon: 'copy' });
      body.appendChild(h('div', { class: 'billing-exact' }, h('div', { class: 'billing-exact-v' }, h('span', { class: 'billing-exact-l' }, L('billing.exactAmount')),
        h('span', { class: 'billing-amt' }, h('code', null, dot < 0 ? shown : [shown.slice(0, dot), h('span', { class: 'amt-tail' }, shown.slice(dot))]), ' USDT')), copyAmount));
      body.appendChild(h('div', { class: 'billing-exact' }, h('div', { class: 'billing-exact-v' }, h('span', { class: 'billing-exact-l' }, L('billing.address')),
        h('code', { class: 'billing-addr' }, h('b', { class: 'addr-hl' }, a.slice(0, 6)), a.slice(6, -6), h('b', { class: 'addr-hl' }, a.slice(-6)))), copyAddress));
      if (pay) { cdEl = h('p', { class: 'billing-cd' }, countdown()); body.appendChild(cdEl); }
      var stRow = h('div', { class: 'billing-inv-st' }, h('p', { role: 'status', 'aria-live': 'polite' }, statusText(), note ? ' · ' + note : ''));
      if (canRecheck()) stRow.appendChild(button(L('billing.recheck'), function () { return recheck(); }, busy ? t('common.loading') : recheckUntil > Date.now() ? t('billing.recheckWait') : '', false, null, { icon: 'refresh' }));
      body.appendChild(stRow);
      if (st === 'manual') body.appendChild(h('p', { class: 'hint warn' }, L('billing.manualNote')));
      if (st === 'credited_late') body.appendChild(h('p', { class: 'hint warn' }, L('billing.lateNote')));
      if (typeof current.tx_hash === 'string' && /^[a-f0-9]{64}$/.test(current.tx_hash)) body.appendChild(h('p', { class: 'muted sm' }, h('a', { class: 'xlink', href: 'https://tronscan.org/#/transaction/' + current.tx_hash, target: '_blank', rel: 'noopener noreferrer' }, L('billing.txLink'), ui.icon('external-link', 13, 'ci'))));
      /* 底部只有「取消订单」(靠左, 先确认) 和「关闭」; 弹窗本身每 3 秒自动刷新, 不需要「刷新」按钮 */
      var acts = [];
      if (st === 'pending') acts.push({ label: t('billing.cancelInvoice'), keep: true, kind: 'soft-bad', cls: 'billing-cancel', disabled: busy, onClick: cancelOrder });
      acts.push({ label: t('common.close'), cancel: true });
      dlg.setActions(acts);
      arm();
    }
    async function cancelOrder() {
      var yes = await ui.confirmDialog({ title: t('billing.cancelInvoice'), message: t('billing.cancelNote'), confirmText: t('billing.cancelInvoice'), danger: true });
      if (!yes || closed || mine !== epoch) return;
      revision++;
      var r = await write('billing/cancel', { id: current.id }, undefined, 'cancel:' + current.id);
      if (r && r.order && r.order.id === current.id && !closed) { current = r.order; paint(); schedule(); }
    }
    /* 再次核实: 服务端让扫链器下一轮优先查这个地址; 同一笔订单 30 秒内只能点一次 */
    async function recheck() {
      if (closed || busy || mine !== epoch || recheckUntil > Date.now()) return;
      busy = true; paint(note);
      try {
        var r = await TP.helper('POST', '/api/billing/order/recheck', { body: JSON.stringify({ id: current.id }), timeout: 12000 });
        if (closed || mine !== epoch) return;
        if (r && r.order && r.order.id === current.id && r.order.amount === current.amount && r.order.address === current.address) current = r.order;
        recheckUntil = Date.now() + 30000;
        ui.toast(t('billing.recheckDone'), 'ok');
      } catch (e) { if (!closed && mine === epoch) { if (e && e.code === 'E_RATE_LIMITED') recheckUntil = Date.now() + 30000; ui.toast(msg(e), 'err'); } }
      finally { busy = false; if (!closed && mine === epoch) { paint(); schedule(); } }
    }
    async function refresh() {
      if (closed || busy || mine !== epoch || S.locked || anyBusy()) { schedule(); return; }
      if (document.hidden) { schedule(); return; }
      busy = true;
      var version = revision;
      try {
        var r = await TP.helper('GET', '/api/billing/order', { q: { id: current.id }, timeout: 12000 });
        if (closed || mine !== epoch || version !== revision) return;
        if (!r.order || r.order.id !== current.id || r.order.amount !== current.amount || r.order.address !== current.address) throw TP.mkErr('api', t('error.generic'));
        var previous = current.status; current = r.order; failures = 0;
        if (previous === 'pending' && current.status !== 'pending') { ordersPage = 1; await B.load(true); TP.plan.load(true); }
        busy = false; if (note || state() !== sig) paint();                      // 没有变化就不重建 (每 3 秒重建会让键盘焦点从底部按钮上丢掉, 读屏也会反复播报状态)
      } catch (e) { failures++; if (!closed && mine === epoch) { busy = false; paint(msg(e)); } }
      finally { busy = false; schedule(); }
    }
    dlg = ui.modal({ title: t('billing.invoice'), icon: 'pro', body: body, size: 'md', onClose: function () { stop(); dialogs = dialogs.filter(function (d) { return d !== dlg; }); } });
    dialogs.push(dlg); paint(); schedule();
    return dlg;
  };
  TP.on('auth', function () { epoch++; data = null; error = null; pending = null; loadedAt = 0; busyKeys = {}; ordering = false; keys = {}; resendUntil = 0; ordersPage = 1; firstOrders = []; ledgerAll = false; payWatch = 0; dialogs.slice().forEach(function (d) { d.close(); }); redraw(); });
  TP.on('lang', redraw);
  TP.on('helper', function () { redraw(); });
  /* 每秒: 重发验证邮件的冷却结束 / 未完成订单的付款时间到了 -> 重画 */
  setInterval(function () {
    var now = Date.now();
    if (resendUntil && now >= resendUntil) { resendUntil = 0; redraw(); return; }
    if (payWatch && now >= payWatch) { payWatch = 0; redraw(); }
  }, 1000);
})();
