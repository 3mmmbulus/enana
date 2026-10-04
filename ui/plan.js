/* enana · plan.js — 会员 / 套餐 (为以后收费预留; 目前所有功能免费)
 * GET /api/plan -> {plan:{code,title}, expires_at, checked, limits:{devices_per_platform}, features:{<key>:{enabled,tier:'free|pro',reason?,coming_soon?}}, official:{available,nodes}}
 * 本机只用它做「界面提示」, 真正的限制在云端。界面里所有功能开关都读 features, 不要在前端写死「免费 / 付费」:
 *   TP.plan.get()            -> 最近一次读到的数据 (没读到时 null)
 *   TP.plan.feature(key)     -> {key, known, enabled, tier, comingSoon, reason, pro}  (没读到 / 没有这一项 = 默认可用, 不挡住用户)
 *   TP.plan.badge(key)       -> Pro 小徽标 (只有 tier=pro 的功能才有; 否则 null)
 *   TP.plan.explain(key)     -> 弹窗说明为什么这项功能现在不能用 (即将推出 / 需要升级 / 订阅已过期) 或它属于哪个套餐
 *   TP.plan.gate(el, key)    -> 把一个控件接到功能开关上: 不可用时点击改为弹出说明 (不是死按钮), 并带上锁图标 / Pro 徽标
 *   TP.plan.load(force)      -> 重新读取; TP.on('plan', fn) 在数据变化时通知 */
(function () {
  'use strict';
  var TP = window.TP, S = TP.S, h = TP.h, ui = TP.ui, I = window.I18N, t = I.t, L = I.L;
  var P = TP.plan = {}, data = null, loadedAt = 0, loading = null;

  P.get = function () { return data; };
  P.name = function (key) { return I.has('plan.f.' + key) ? t('plan.f.' + key) : String(key).replace(/[_-]+/g, ' '); };
  P.feature = function (key) {
    var f = data && data.features && data.features[key];
    if (!f) return { key: key, known: false, enabled: true, tier: 'free', comingSoon: false, reason: '', pro: false };
    return { key: key, known: true, enabled: f.enabled !== false, tier: f.tier === 'pro' ? 'pro' : 'free', comingSoon: !!f.coming_soon, reason: String(f.reason || ''), pro: f.tier === 'pro' };
  };
  P.title = function () { var p = data && data.plan; return p ? String(p.title || p.code || '') : ''; };
  P.isPro = function () { var p = data && data.plan; return !!(p && p.code && p.code !== 'free'); };
  P.badge = function (key) {
    var f = P.feature(key);
    return f.pro ? ui.badge(L('plan.pro'), 'pro', 'pro') : null;
  };

  /* 读取 (登录后 / 打开设置页 / 服务器页时; 5 分钟内不重复读) */
  P.load = function (force) {
    if (S.locked) return Promise.resolve(data);
    if (loading) return loading;
    if (!force && data && Date.now() - loadedAt < 300000) return Promise.resolve(data);
    loading = TP.helper('GET', '/api/plan', { timeout: 8000 }).then(function (r) {
      data = r && r.ok !== false ? r : data; loadedAt = Date.now(); TP.emit('plan', data); return data;
    }, function (e) { if (!(e && e.kind === 'auth')) TP.emit('plan', data); return data; }).then(function (x) { loading = null; return x; });
    return loading;
  };
  TP.on('auth', function (ok) { if (ok) { data = null; P.load(true); } else { data = null; } });
  TP.on('lang', function () { /* 套餐名 / 原因由后端按语言头翻译: 下次读取时更新 */ loadedAt = 0; });

  /* 为什么这项功能现在不能用 / 它属于什么 -> 弹窗 (不是死按钮) */
  P.explain = function (key) {
    var f = P.feature(key), name = P.name(key), why, kind = 'info';
    if (f.comingSoon) { why = t('plan.why.soon'); }
    else if (!f.enabled && f.reason === 'expired') { why = t('plan.why.expired'); kind = 'warn'; }
    else if (!f.enabled) { why = t('plan.why.upgrade'); }
    else if (f.pro) { why = t('plan.why.included'); kind = 'ok'; }
    else { why = t('plan.why.free'); kind = 'ok'; }
    var up = ui.btn(L('plan.upgrade'), { kind: 'primary', icon: 'pro' });
    ui.act(up, function () { if (TP.billing && TP.settingsTab) { TP.settingsTab('plan'); return; } ui.toast(t('plan.upgradeSoon'), 'warn', 4200); });
    var body = h('div', { class: 'plan-ex' },
      h('p', { class: 'cfm-m' }, why),
      h('p', { class: 'muted sm' }, t('plan.why.free.now')),
      h('div', { class: 'plan-ex-b' }, ui.badge(f.pro ? L('plan.pro') : L('plan.tier.free'), f.pro ? 'pro' : 'neutral', f.pro ? 'pro' : null), f.comingSoon ? ui.badge(L('plan.soon'), 'info', 'clock') : null),
      h('div', { class: 'plan-ex-a' }, up));
    return ui.modal({ title: t('plan.exTitle', { name: name }), icon: 'pro', iconKind: kind, size: 'sm', body: body, actions: [{ label: t('common.close'), cancel: true }] });
  };
  /* 把控件接到功能开关: 不可用时点击弹出说明; 可用但属于 Pro 时只显示小徽标 */
  P.gate = function (el, key) {
    function paint() {
      var f = P.feature(key), locked = !f.enabled;
      el.classList.toggle('is-gated', locked);
      if (locked) { el.setAttribute('aria-disabled', 'true'); el._gate = true; } else if (el._gate) { el.removeAttribute('aria-disabled'); el._gate = false; }
    }
    el.addEventListener('click', function (ev) { if (el._gate) { ev.preventDefault(); ev.stopImmediatePropagation(); P.explain(key); } }, true);
    TP.on('plan', paint); paint();
    return el;
  };
})();
