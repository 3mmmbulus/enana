/* enana · exits.js — 出口分配 (Exit assignment)
 * 「固定出口」不是一个全局开关: 不同的应用 / 网站 / 服务可以走不同的固定出口 (一个应用走出口 1, 另一个走出口 2)。这个文件负责三件事:
 *   1. 总览 (服务器页「出口分配」): 每个固定出口上有哪些应用 / 网站 / 服务, 哪些在「跟随默认」, 哪些指定的出口已经不存在 (孤儿); 批量改派 / 钉住。
 *   2. 事前检查: 换默认固定出口 / 删除固定出口 / 把它改成别的角色之前, 先列出谁会换出口 IP, 让用户明确选择去向 —— 不再悄悄换 IP。
 *   3. 公共的出口选择器 (应用页 / 网站页每一项的「走哪个出口」): 显示「默认 (当前是哪一个)」。
 * 数据来自 GET /api/exits 与 GET /api/exits/impact (lib/exits.sh); 改动走 POST /api/exits/move|freeze 和 /api/servers/delete|role 的 reassign 参数 (docs/API.md)。
 * 约定同其它视图: 来自网络的字符串一律 textContent; 兼容 ES2018; 纯逻辑 (model / plan* / params*) 不碰 DOM, 方便单测 (tests/exits-ui.test.js)。 */
(function () {
  'use strict';
  var TP = window.TP, S = TP.S, h = TP.h, ui = TP.ui, setText = TP.setText, I = window.I18N, t = I.t, L = I.L;
  var X = TP.exits = {};
  S.exits = null;                                           // GET /api/exits 的最近一次结果
  var inflight = null, loadedAt = 0, LIM = 8, LIM_DLG = 30, open = {}, paint = null;

  /* ================= 数据 ================= */
  X.load = function (maxAgeMs) {                            // 同时有多个调用者时共用一次请求; maxAgeMs: 这么久之内读过就不再请求
    if (maxAgeMs && S.exits && Date.now() - loadedAt < maxAgeMs) return Promise.resolve(S.exits);
    if (inflight) return inflight;
    inflight = TP.helper('GET', '/api/exits').then(function (r) { S.exits = r; loadedAt = Date.now(); TP.emit('exits', r); return r; })
      .catch(function (e) { if (e && e.kind !== 'unreachable' && e.kind !== 'auth') console.warn('exits:', e.message); return null; })
      .then(function (r) { inflight = null; return r; });
    return inflight;
  };
  X.impact = function (op, tag) { return TP.helper('GET', '/api/exits/impact', { q: { op: op, tag: tag } }); };

  function lists(o) { return { app: (o && o.apps) || [], site: (o && o.sites) || [], svc: (o && o.services) || [] }; }
  function total(l) { return l.app.length + l.site.length + l.svc.length; }
  X.total = total;
  X.lists = lists;

  /* 总览的数据模型 (纯函数): 每个固定出口一组, 再加 跟随默认 / 自动选 / 孤儿 */
  X.model = function (d) {
    d = d || {};
    var def = (d.default && d.default.tag) || '', pins = (d.pins || []).map(function (p) {
      var l = lists(p);
      return { id: 'pin:' + p.tag, type: 'pin', tag: p.tag, isDefault: !!p.default || (!!def && p.tag === def), targetable: p.targetable !== false, lists: l, n: total(l) };
    });
    var fl = lists(d.follow), au = lists(d.auto), dns = !!(d.follow && d.follow.dns);
    var orphans = (d.orphans || []).map(function (o) { return { kind: o.kind === 'site' ? 'site' : 'app', name: o.name, target: o.target, reason: o.reason || 'deleted' }; });
    var sum = pins.reduce(function (n, p) { return n + p.n; }, 0) + total(fl) + total(au) + orphans.length;
    return {
      def: def, pins: pins, max: +d.max || 32, known: d.services_known !== false,
      follow: { id: 'follow', type: 'follow', lists: fl, dns: dns, n: total(fl) + (dns ? 1 : 0) },
      auto: { id: 'auto', type: 'auto', lists: au, n: total(au) },
      orphans: orphans, total: sum
    };
  };

  /* 当前的默认固定出口: 核心里 PIN 选择器选中的 > 后端告诉我们的 > 第一个固定出口 */
  X.defaultTag = function () {
    var pins = TP.pinServers(), now = S.proxies && S.proxies.PIN && S.proxies.PIN.now;
    if (now && pins.indexOf(now) >= 0) return now;
    var d = S.exits && S.exits.default && S.exits.default.tag;
    if (d && pins.indexOf(d) >= 0) return d;
    return pins[0] || '';
  };
  /* 一个项目 (应用 / 网站 / 服务) 显示的名字 */
  X.itemName = function (kind, name) { return kind === 'svc' ? TP.svcName(name) : name; };
  /* 其中有多少个对出口 IP 变化敏感 (AI / 账号 / 交易所类服务): 换出口可能触发风控 */
  X.riskCount = function (l) { return (l.svc || []).filter(function (tag) { var e = S.svcByTag && S.svcByTag[tag]; return !!(e && TP.riskGroup(e.group)); }).length; };

  /* ================= 公共的出口选择器 (应用页 / 网站页) =================
   * 取值: 'PIN' = 跟随默认固定出口 · 'PINAUTO' = 在固定出口里自动选 · 其它 = 指定的固定出口 (服务器名) */
  X.targetName = function (v) {
    if (v === 'PINAUTO') return t('apps.tg.auto');
    if (v === 'PIN' || !v) { var d = X.defaultTag(); return d ? t('apps.tg.defaultNow', { tag: d }) : t('apps.tg.default'); }
    return v;
  };
  X.targetDetail = function (to) {
    return t(to === 'PIN' ? 'apps.tg.dDefault' : to === 'PINAUTO' ? 'apps.tg.dAuto' : 'apps.tg.dOne', { tag: to, def: X.defaultTag() || '—' });
  };
  X.targetSig = function () { return TP.pinServers().join('\u0001') + '|' + X.defaultTag() + '|' + I.lang; };
  X.fillTargets = function (sel) {                           // 一个固定出口时只有「默认 (它)」一项: 不能选, 但看得见走的是谁
    var sig = X.targetSig();
    if (sel._sig === sig) return;
    sel._sig = sig; TP.clear(sel);
    sel.appendChild(TP.opt('PIN', X.targetName('PIN')));
    if (TP.canPickPin()) {
      sel.appendChild(TP.opt('PINAUTO', t('apps.tg.auto')));
      TP.pinServers().forEach(function (tag) { sel.appendChild(TP.opt(tag, tag)); });
    }
  };
  X.targetAvail = function (sel, why) {                      // 为什么不能改: 先是通用原因 (核心没运行等), 再是「只有一个固定出口」
    ui.avail(sel, why || (TP.canPickPin() ? '' : t('apps.tg.single')));
  };
  /* 指定的出口已经不是固定出口 (被删除 / 改了角色 / 超过上限): 原因从服务器列表就能判断 */
  X.orphanWhy = function (tag) {
    var s = TP.servers().filter(function (x) { return x.tag === tag; })[0];
    return !s ? 'deleted' : s.role !== 'pin' ? 'role' : 'cap';
  };
  X.orphanText = function (tag) { return t('apps.tg.gone', { tag: tag, def: X.defaultTag() || '—', why: t('exits.why.' + X.orphanWhy(tag)) }); };

  /* ================= 改派 / 钉住 ================= */
  /* 非 TUN: 同步完成 (规则集热加载, 不重启核心); TUN: 后台任务 (经免密助手同步, 不重启) */
  async function post(path, q, title) {
    var r = await TP.helper('POST', path, { q: q }), d;
    if (r && r.job) {
      d = await TP.jobs.runInDock(title, function () { return Promise.resolve(r); });
      if (!d.ok) throw (d.error || new Error('failed'));
    }
    if (TP.afterApply) TP.afterApply();
    X.load();
    return r;
  }
  X.move = function (from, to, kind, title) {
    var q = { from: from, to: to };
    if (kind) q.kind = kind;
    return post('/api/exits/move', q, title || t('exits.job.move'));
  };
  X.freeze = function (title, kind) { return post('/api/exits/freeze', kind ? { kind: kind } : {}, title || t('exits.job.freeze')); };
  X.movedText = function (r) {
    var m = (r && r.moved) || {};
    return t('exits.moved', { apps: m.apps || 0, sites: m.sites || 0, svc: m.services || 0 });
  };

  /* ================= 公共的界面零件 ================= */
  var KINDS = ['app', 'site', 'svc'];
  /* 一行名字芯片; 总览里超过 LIM 个可以展开 (展开状态记在 open), 对话框里一次性显示到 LIM_DLG 个 */
  function toggleChip(key, isOpen, n) {
    var b = h('button', { class: 'chip exg-more', type: 'button', 'aria-expanded': isOpen ? 'true' : 'false' }, isOpen ? t('exits.less') : t('exits.more', { n: n }));
    b.addEventListener('click', function () { open[key] = !isOpen; if (paint) paint(true); });
    return b;
  }
  function chipsLine(kind, names, key, dlg) {
    if (!names.length) return null;
    var lim = dlg ? LIM_DLG : LIM, expanded = !dlg && !!open[key], show = expanded ? names : names.slice(0, lim);
    var chips = show.map(function (n) { return h('span', { class: 'chip exg-c' }, X.itemName(kind, n)); });
    if (names.length > show.length) chips.push(dlg ? h('span', { class: 'chip exg-c muted' }, t('exits.more', { n: names.length - show.length })) : toggleChip(key, false, names.length - show.length));
    else if (expanded && names.length > lim) chips.push(toggleChip(key, true, 0));
    return h('div', { class: 'exg-k' }, h('span', { class: 'exg-kl muted' }, t('exits.kind.' + kind) + ' · ' + names.length), h('div', { class: 'exg-cs' }, chips));
  }
  function dnsLine() { return h('div', { class: 'exg-k' }, h('span', { class: 'exg-kl muted' }, t('exits.kind.dns')), h('div', { class: 'exg-cs' }, h('span', { class: 'chip exg-c' }, t('exits.dns')))); }
  /* 影响明细 (确认框里用): 每种项目一行 */
  function impactBlock(title, l, dns) {
    var rows = KINDS.map(function (k) { return chipsLine(k, l[k], '', true); }).filter(Boolean);
    if (dns) rows.push(dnsLine());
    if (!rows.length) return null;
    return h('div', { class: 'exg-imp' }, h('div', { class: 'exg-imp-t' }, title), rows);
  }
  function radio(box, name, val, label, hint, checked, onPick) {
    var inp = h('input', { type: 'radio', name: name, value: val });
    inp.checked = !!checked;
    inp.addEventListener('change', function () { if (inp.checked) onPick(val); });
    box.appendChild(h('label', { class: 'radio' }, inp, h('span', null, label, hint ? h('span', { class: 'muted sm exg-rh' }, ' ' + hint) : null)));
    return inp;
  }
  function riskNote(n) { return n ? h('p', { class: 'hint warn' }, ui.icon('warning', 14, 'ci'), h('span', null, t('exits.risk', { n: n }))) : null; }

  /* ================= 事前检查 1: 换默认固定出口 =================
   * askDefault 返回 null = 用户取消 · {none:true} = 没有谁跟随默认 (调用方走普通确认) · {legacy:true} = 读不到影响明细 (旧版辅助服务; 调用方走普通确认) · {freeze:boolean} */
  X.planDefault = function (imp, from, to) {
    var f = lists(imp && imp.follow), dns = !!(imp && imp.follow && imp.follow.dns), n = total(f) + (dns ? 1 : 0);
    return { from: from, to: to, follow: f, dns: dns, n: n, risk: X.riskCount(f) };
  };
  X.askDefault = async function (from, to) {
    var imp;
    try { imp = await X.impact('default', to); }
    catch (e) { if (e && (e.kind === 'auth' || e.kind === 'cancel')) throw e; return { legacy: true }; }
    var pl = X.planDefault(imp, from, to);
    if (!pl.n) return { none: true };
    var keep = true, box = h('div', { class: 'radios', role: 'radiogroup', 'aria-label': t('exits.def.choose') });
    radio(box, 'dflt', 'keep', t('exits.def.keep', { from: from }), t('exits.def.keepHint'), true, function () { keep = true; });
    radio(box, 'dflt', 'follow', t('exits.def.follow', { to: to }), t('exits.def.followHint'), false, function () { keep = false; });
    var body = h('div', { class: 'exg-dlg' },
      h('p', { class: 'cfm-m' }, t('exits.def.msg', { from: from, to: to })),
      impactBlock(t('exits.def.followers'), pl.follow, pl.dns),
      riskNote(pl.risk),
      box);
    var dm = ui.modal({
      title: t('exits.def.title'), icon: 'pin', iconKind: 'warn', size: 'md', body: body,
      actions: [{ label: t('common.cancel'), cancel: true, autofocus: true }, { label: t('exits.def.go'), kind: 'primary', icon: 'check', id: 'go', value: 'go' }]
    });
    var v = await dm.closed;
    return v === 'go' ? { freeze: keep } : null;
  };
  /* 换默认固定出口的完整流程: 事前检查 → (选了「继续走原出口」) 先把跟随默认的钉在原出口上 → 再切换。返回 true = 已切换。
   * plainConfirm(pre): 没有谁跟随默认 / 读不到明细时的普通确认框 (返回 boolean) */
  X.switchDefault = async function (from, to, plainConfirm) {
    var pre = await X.askDefault(from, to);
    if (!pre) return false;
    if (pre.none || pre.legacy) { if (plainConfirm && !(await plainConfirm(pre))) return false; }
    else if (pre.freeze) await X.freeze(t('exits.job.freezeAt', { tag: from }));
    await TP.setPolicy('PIN', to);
    X.load();
    return true;
  };

  /* ================= 事前检查 2: 删除 / 改角色 (固定出口被移除) =================
   * askRemove 返回 null = 取消 · {} = 没有谁用它, 照常继续 (调用方走自己的普通确认) · {reassign[, freeze]} · {accept_orphans:1} (明确接受后果) */
  X.planRemove = function (imp, def) {
    var b = lists(imp && imp.bound), f = lists(imp && imp.follow), dns = !!(imp && imp.follow && imp.follow.dns);
    var cands = ((imp && imp.candidates) || []).filter(function (c) { return c.targetable !== false; }).map(function (c) { return c.tag; });
    var dc = !!(imp && imp.default_changes), remaining = +(imp && imp.remaining) || 0;
    var dests = cands.map(function (tag) { return { value: tag, label: tag }; });
    if (!dc) dests.push({ value: 'DEFAULT', label: t('exits.rm.toDefault', { tag: def || '—' }) });
    if (!dc && remaining >= 2) dests.push({ value: 'PINAUTO', label: t('apps.tg.auto') });
    return { bound: b, follow: f, dns: dns, defaultChanges: dc, n: +(imp && imp.affected) || 0, dests: dests, sole: remaining === 0, risk: X.riskCount(b) + X.riskCount(f) };
  };
  X.paramsRemove = function (pl, st) {                      // 对话框的选择 → 请求参数
    if (!st.dest) return { accept_orphans: 1 };
    var q = { reassign: st.dest };
    if (st.freeze && pl.defaultChanges) q.freeze = 1;
    return q;
  };
  X.askRemove = async function (s, newRole) {
    var imp;
    try { imp = await X.impact('remove', s.tag); }
    catch (e) { if (e && (e.kind === 'auth' || e.kind === 'cancel')) throw e; return {}; }          // 读不到明细 (旧版辅助服务): 后端的保护会在需要时拒绝
    if (!imp || imp.is_pin === false || !imp.affected) return {};
    var pl = X.planRemove(imp, imp.default), del = !newRole;
    var st = { dest: pl.sole || !pl.dests.length ? '' : pl.dests[0].value, freeze: false, ack: false };
    var sel = h('select', { class: 'sel', 'aria-label': t('exits.rm.destAria') });
    if (!pl.sole) {
      pl.dests.forEach(function (d) { sel.appendChild(TP.opt(d.value, d.label)); });
      sel.appendChild(TP.opt('', t('exits.rm.leave')));
      sel.value = st.dest;
    }
    var freezeChk = h('input', { type: 'checkbox' }), ack = h('input', { type: 'checkbox' });
    freezeChk.addEventListener('change', function () { st.freeze = freezeChk.checked; });
    ack.addEventListener('change', function () { st.ack = ack.checked; });
    var freezeRow = h('label', { class: 'chk-inline' }, freezeChk, h('span', null, t('exits.rm.freeze')));
    var ackRow = h('label', { class: 'chk-inline exg-ack' }, ack, h('span', null, t('exits.rm.ack')));
    function sync() {                                       // 选了「不改派」要明确勾选「我知道后果」
      var leave = !st.dest;
      ackRow.hidden = !leave; freezeRow.hidden = leave || !pl.defaultChanges || !(total(pl.follow) + (pl.dns ? 1 : 0));        // 钉住「跟随默认的」: 只有默认出口被移除、而且真的有项目在跟随它时才有意义
      if (!leave) { st.ack = false; ack.checked = false; }
    }
    sel.addEventListener('change', function () { st.dest = sel.value; sync(); });
    sync();
    var body = h('div', { class: 'exg-dlg' },
      h('p', { class: 'cfm-m' }, t(del ? 'exits.rm.msgDel' : 'exits.rm.msgRole', { tag: s.tag, role: newRole ? TP.name.role(newRole) : '', n: pl.n })),
      impactBlock(t('exits.rm.bound'), pl.bound, false),
      impactBlock(t('exits.rm.follow', { tag: s.tag }), pl.follow, pl.dns),
      riskNote(pl.risk),
      pl.sole ? h('p', { class: 'hint bad' }, ui.icon('risk', 14, 'ci'), h('span', null, t('exits.rm.sole'))) : h('label', { class: 'fld' }, h('span', { class: 'fld-l' }, t('exits.rm.dest')), sel),
      freezeRow, ackRow,
      !pl.sole && pl.defaultChanges ? h('p', { class: 'muted sm' }, t('exits.rm.defNote')) : null);
    var dm = ui.modal({
      title: t('exits.rm.title'), icon: 'risk', iconKind: 'bad', size: 'md', body: body,
      actions: [
        { label: t('common.cancel'), cancel: true, autofocus: true },
        { label: t(del ? 'exits.rm.goDel' : 'exits.rm.goRole'), kind: 'danger', icon: del ? 'delete' : 'check', id: 'go', keep: true,
          onClick: function (api) {
            if (!st.dest && !st.ack) { ui.toast(t('exits.rm.needAck'), 'warn'); return false; }
            api.close('go'); return false;
          } }
      ]
    });
    var v = await dm.closed;
    return v === 'go' ? X.paramsRemove(pl, st) : null;
  };
  /* 订阅里有固定出口时删除订阅: 这些服务器一起消失, 指定了它们的应用 / 网站 / 服务会退回默认 (或直连)。这里只算影响, 由调用方在确认框里写明, 确认后带 accept_orphans=1 */
  X.subImpact = async function (subName) {
    var pins = TP.servers().filter(function (s) { return s.sub === subName && s.role === 'pin'; }).map(function (s) { return s.tag; });
    if (!pins.length) return null;
    var d = await X.load();
    if (!d) return { pins: pins, n: 0, known: false };
    var m = X.model(d), n = 0, defHit = pins.indexOf(m.def) >= 0;
    m.pins.forEach(function (p) { if (pins.indexOf(p.tag) >= 0) n += p.n; });
    if (defHit) n += m.follow.n;
    return { pins: pins, n: n, known: true, defHit: defHit };
  };

  /* ================= 改派对话框 ("全部改派…") ================= */
  X.moveDests = function (m, from) {
    var out = [], can = m.pins.filter(function (p) { return p.targetable; }).length >= 2;
    if (can) m.pins.filter(function (p) { return p.targetable && p.tag !== from; }).forEach(function (p) { out.push({ value: p.tag, label: p.tag + (p.isDefault ? ' · ' + t('exits.badge.default') : '') }); });
    if (from !== 'DEFAULT') out.push({ value: 'DEFAULT', label: t('exits.move.toDefault', { tag: m.def || '—' }) });
    if (can && from !== 'PINAUTO') out.push({ value: 'PINAUTO', label: t('apps.tg.auto') });
    return out;
  };
  X.moveKindOf = function (v) { return v === 'app' || v === 'site' ? v : v === 'svc' ? 'service' : ''; };
  X.askMove = async function (m, g) {                         // g: 一组 (model 里的 pin / follow / auto, 或孤儿 {type:'orphan', items})
    var from = g.type === 'pin' ? g.tag : g.type === 'follow' ? 'DEFAULT' : g.type === 'auto' ? 'PINAUTO' : 'ORPHAN';
    var fromLabel = g.type === 'pin' ? g.tag : g.type === 'follow' ? t('exits.group.follow') : g.type === 'auto' ? t('exits.group.auto') : t('exits.group.orphan');
    var dests = X.moveDests(m, g.type === 'orphan' ? '' : from);
    if (!dests.length) { ui.toast(t('exits.move.noDest'), 'warn'); return false; }
    var l = g.type === 'orphan' ? { app: g.items.filter(function (o) { return o.kind === 'app'; }), site: g.items.filter(function (o) { return o.kind === 'site'; }), svc: [] } : g.lists;
    var st = { to: dests[0].value, kind: '' };
    var sel = h('select', { class: 'sel', 'aria-label': t('exits.move.destAria') }, dests.map(function (d) { return TP.opt(d.value, d.label); }));
    sel.value = st.to; sel.addEventListener('change', function () { st.to = sel.value; });
    var kinds = KINDS.filter(function (k) { return l[k].length; });
    var ksel = h('select', { class: 'sel', 'aria-label': t('exits.move.kindAria') }, TP.opt('', t('exits.move.kindAll', { n: total(l) })));
    if (kinds.length > 1) kinds.forEach(function (k) { ksel.appendChild(TP.opt(k, t('exits.move.kindOnly.' + k, { n: l[k].length }))); });
    ksel.addEventListener('change', function () { st.kind = ksel.value; });
    var body = h('div', { class: 'exg-dlg' },
      h('p', { class: 'cfm-m' }, t('exits.move.msg', { from: fromLabel, n: total(l) })),
      h('label', { class: 'fld' }, h('span', { class: 'fld-l' }, t('exits.move.dest')), sel),
      kinds.length > 1 ? h('label', { class: 'fld' }, h('span', { class: 'fld-l' }, t('exits.move.kind')), ksel) : null,
      riskNote(X.riskCount(l)),
      h('p', { class: 'muted sm' }, t('exits.move.note')));
    var dm = ui.modal({
      title: t('exits.move.title'), icon: 'pin', iconKind: 'pri', size: 'md', body: body,
      actions: [{ label: t('common.cancel'), cancel: true }, { label: t('exits.move.go'), kind: 'primary', icon: 'check', id: 'go', value: 'go' }]
    });
    if ((await dm.closed) !== 'go') return false;
    var toLabel = st.to === 'DEFAULT' ? t('exits.group.follow') : st.to === 'PINAUTO' ? t('apps.tg.auto') : st.to;
    var r = await X.move(from, st.to, X.moveKindOf(st.kind), t('exits.job.moveFromTo', { from: fromLabel, to: toLabel }));
    ui.toast(X.movedText(r), 'ok', 3200);
    return true;
  };

  /* ================= 总览卡片 (服务器页「出口分配」) ================= */
  X.card = function () {
    var el = {}, lastSig = '';
    el.def = h('p', { class: 'exits-def' });
    el.banner = h('div', { class: 'hint warn exits-banner', hidden: true });
    el.list = h('div', { class: 'exits-list' });
    el.empty = h('p', { class: 'muted exits-empty', hidden: true });
    var root = h('section', { class: 'card exits-card' },
      h('div', { class: 'card-h' }, ui.icon('pin', 20, 'ci'), h('h3', null, L('exits.title'), ui.help('exits')), h('span', { class: 'muted sm' }, L('exits.sub'))),
      el.def, el.banner, el.list, el.empty, h('p', { class: 'muted sm exits-note' }, L('exits.note')));

    async function freezeNow() {
      var m = X.model(S.exits), tag = m.def;
      if (!tag || !m.follow.n) return;
      var ok = await ui.confirmDialog({ title: t('exits.freeze.title'), message: t('exits.freeze.msg', { tag: tag, n: m.follow.n }), detail: [t('exits.freeze.d1', { tag: tag }), t('exits.freeze.d2')], confirmText: t('exits.freeze.go') });
      if (!ok) return;
      var r = await X.freeze(t('exits.job.freezeAt', { tag: tag }));
      ui.toast(X.movedText(r), 'ok', 3200);
    }
    function groupRow(g, m) {
      var title, badges = [], acts = [], body = [], n = g.type === 'orphan' ? g.items.length : g.n;
      if (g.type === 'pin') {
        title = h('b', { class: 'exg-t' }, g.tag);
        if (g.isDefault) badges.push(ui.badge(t('exits.badge.default'), 'pin'));
        if (!g.targetable) badges.push(ui.badge(t('exits.badge.cap', { max: m.max }), 'warn'));
      } else if (g.type === 'follow') {
        title = h('b', { class: 'exg-t' }, m.def ? t('exits.group.followTo', { tag: m.def }) : t('exits.group.follow'));
        if (!m.pins.length) badges.push(ui.badge(t('exits.badge.direct'), 'bad'));
      } else if (g.type === 'auto') title = h('b', { class: 'exg-t' }, t('exits.group.auto'));
      else { title = h('b', { class: 'exg-t' }, t('exits.group.orphan')); badges.push(ui.badge(t('exits.badge.gone'), 'warn')); }
      var cnt = h('span', { class: 'muted sm exg-n' }, g.type === 'orphan' ? t('exits.n.items', { n: n }) : t('exits.n.counts', { apps: g.lists.app.length, sites: g.lists.site.length, svc: g.lists.svc.length }));
      if (g.type === 'orphan') {
        var byTarget = {};
        g.items.forEach(function (o) { (byTarget[o.target] = byTarget[o.target] || []).push(o); });
        Object.keys(byTarget).forEach(function (tg) {
          var items = byTarget[tg];
          body.push(h('div', { class: 'exg-k' }, h('span', { class: 'exg-kl muted' }, t('exits.orphan.was', { tag: tg, why: t('exits.why.' + items[0].reason) })),
            h('div', { class: 'exg-cs' }, items.map(function (o) { return h('span', { class: 'chip exg-c' }, o.name); }))));
        });
      } else {
        KINDS.forEach(function (k) { var c = chipsLine(k, g.lists[k], g.id + ':' + k, false); if (c) body.push(c); });
        if (g.type === 'follow' && g.dns) body.push(dnsLine());
        if (!body.length) body.push(h('p', { class: 'muted sm exg-none' }, t(g.type === 'pin' ? 'exits.pin.none' : 'exits.group.none')));
      }
      if (n > 0) {
        var mv = ui.btn(t('exits.act.move'), { sm: true, kind: 'ghost', icon: 'pin' });
        ui.act(mv, function () { return X.askMove(m, g); });
        acts.push(mv);
      }
      if (g.type === 'follow' && g.n > 0 && m.def && m.pins.length >= 2) {
        var fz = ui.btn(t('exits.act.freezeAt', { tag: m.def }), { sm: true, kind: 'ghost', icon: 'lock' });
        ui.act(fz, freezeNow); acts.push(fz);
      }
      return h('div', { class: 'exg' + (g.type === 'orphan' ? ' is-warn' : '') + (g.isDefault ? ' is-def' : ''), 'data-g': g.id },
        h('div', { class: 'exg-h' }, h('div', { class: 'exg-hl' }, title, h('span', { class: 'badges' }, badges), cnt), h('div', { class: 'exg-act' }, acts)),
        h('div', { class: 'exg-b' }, body));
    }
    function render(force) {
      var m = X.model(S.exits), noData = !S.exits, ors = m.orphans.length ? { id: 'orphan', type: 'orphan', items: m.orphans } : null;
      var sig = I.lang + '|' + (noData ? 0 : 1) + '|' + JSON.stringify(m) + JSON.stringify(open);
      el.empty.hidden = !noData && (m.pins.length > 0 || m.total > 0);
      setText(el.empty, noData ? t('exits.loading') : t('exits.noPins'));
      if (!noData && m.pins.length) { setText(el.def, m.def ? t('exits.default', { tag: m.def }) : t('exits.defaultNone')); el.def.hidden = false; } else el.def.hidden = true;
      if (ors) { setText(el.banner, t('exits.orphan.banner', { n: m.orphans.length, tag: m.def || '—' })); el.banner.hidden = false; } else el.banner.hidden = true;
      if (!force && sig === lastSig) return;
      lastSig = sig;
      TP.clear(el.list);
      if (noData) return;
      m.pins.forEach(function (g) { el.list.appendChild(groupRow(g, m)); });
      if (m.follow.n > 0 || m.pins.length) el.list.appendChild(groupRow(m.follow, m));
      if (m.auto.n > 0) el.list.appendChild(groupRow(m.auto, m));
      if (ors) el.list.appendChild(groupRow(ors, m));
    }
    paint = render;
    TP.on('exits', function () { render(); });
    TP.on('lang', function () { render(true); });
    TP.on('catalog', function () { render(true); });                       // 服务的显示名来自网站目录, 它比出口分配的数据晚一点到
    TP.on('state', function () { render(); });
    render(true);
    root._render = render;
    return root;
  };

  /* 服务器页「默认固定出口」卡片里的一行: 谁在跟随它 (没有数据时返回空串) */
  X.followLine = function () {
    if (!S.exits) return '';
    var m = X.model(S.exits), l = m.follow.lists;
    if (!m.follow.n) return t('servers.pin.followNone');
    return t('servers.pin.follow', { n: m.follow.n, apps: l.app.length, sites: l.site.length, svc: l.svc.length });
  };
  X.orphanCount = function () { return S.exits ? (+S.exits.orphan_count || 0) : 0; };

  TP.on('auth', function (ok) { if (!ok) { S.exits = null; loadedAt = 0; } });
})();
