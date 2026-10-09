/* enana · v-servers.js — 服务器页: 默认固定出口 / 出口分配 (exits.js) / 服务器表 / 测速全部 / 订阅列表 (含过期自动刷新)
 * 固定出口不是全局的一个开关: 不同的应用 / 网站 / 服务可以走不同的固定出口。这里的「默认固定出口」只是「跟随默认」的项目走的那一个 ——
 * 换默认 / 删除固定出口 / 把它改成别的角色之前, 都会先列出谁会换出口 IP, 让用户选择去向 (exits.js 的事前检查), 不会悄悄换 IP。
 * 添加·导入服务器是弹窗 (v-import.js, TP.imp.open); 每个会改变状态的操作都先 confirmDialog; 暂时不能用的按钮显示原因而不是失灵。
 * 服务器表: 列头 (名称 / 类型 / 地址 / 角色 / 延迟) 可以点击排序 (ui.sorter, 先排序再分页); 工具栏的排序下拉保留 (没点列头时照旧, 用下拉框会取消列头排序)。 */
(function () {
  'use strict';
  var TP = window.TP, S = TP.S, h = TP.h, ui = TP.ui, setText = TP.setText, I = window.I18N, t = I.t, L = I.L;
  var V = TP.V.servers = { id: 'servers' };
  var el = {}, sortKey = TP.prefs.get('servers.sort', 'default');
  var so = null;                                            // 列头排序 (ui.sorter, 记在 prefs sort.servers); 排序时它优先, 同值的行按下拉框 (sortKey) 的顺序排
  var pendingRole = {}, pendingDel = {};                    // 操作进行中的临时显示 (避免被 10 秒轮询的旧状态闪回)
  var test = { running: false, stop: false, i: 0, n: 0, done: false };
  var ROLES = ['pin', 'auto', 'dl', 'off'], ROLE_RANK = { pin: 0, auto: 1, dl: 2, off: 3 };
  var refreshing = {}, refreshedAt = {}, pickTab = function () { };
  TP.subs = {};

  function active() { return TP.tab === 'servers'; }
  function servers() { return TP.servers(); }
  function canDl(type) { return type === 'http' || type === 'socks'; }     // 下载专用只对 http/socks 有效 (curl 能直接使用)
  function addFix() { return { label: t('why.addServer'), fn: function () { TP.goAdd('manual'); } }; }
  function fmtMs(ms) { return ms > 0 ? ms + ' ms' : t('common.timeout'); }

  /* ================= 构建 ================= */
  V.init = function (root) {
    /* 当前出口 */
    el.pinSel = h('select', { class: 'sel', 'aria-label': L('servers.pin.aria') });
    ui.selectAct(el.pinSel, function () { return (S.proxies.PIN && S.proxies.PIN.now) || ''; }, function (want) { return switchTo('PIN', want); });
    el.pinInfo = h('div', { class: 'muted sm' });
    el.pinFollow = h('div', { class: 'muted sm srv-follow' });                       // 谁在跟随默认固定出口 (数据来自 GET /api/exits)
    el.pinView = h('button', { class: 'link-b sm', type: 'button' }, L('servers.pin.view')); el.pinView.addEventListener('click', function () { pickTab('exits'); });
    el.pinOrphan = h('div', { class: 'hint warn srv-orphan', hidden: true });         // 有项目指定的出口已经不是固定出口 (孤儿)
    el.autoSel = h('select', { class: 'sel', 'aria-label': L('servers.auto.aria') });
    ui.selectAct(el.autoSel, function () { return (S.proxies.Global && S.proxies.Global.now) || ''; }, function (want) { return switchTo('Global', want); });
    el.autoBack = ui.btn(L('servers.auto.back'), { sm: true, icon: 'auto' }); el.autoBack.hidden = true;
    ui.act(el.autoBack, function () { return switchTo('Global', 'AUTO'); });
    el.autoInfo = h('div', { class: 'muted sm' });
    root.appendChild(h('div', { class: 'grid cols2' },
      h('section', { class: 'card' }, h('div', { class: 'card-h' }, ui.icon('pin', 20, 'ci'), h('h3', null, L('servers.pin.title'), ui.help('servers.pin'))), h('div', { class: 'row wrap' }, el.pinSel), el.pinInfo, h('div', { class: 'row wrap srv-follow-r' }, el.pinFollow, el.pinView), el.pinOrphan),
      h('section', { class: 'card' }, h('div', { class: 'card-h' }, ui.icon('auto', 20, 'ci'), h('h3', null, L('servers.auto.title'), ui.help('servers.auto'))), h('div', { class: 'row wrap' }, el.autoSel, el.autoBack), el.autoInfo)));

    var panels = {}, names = ['nodes', 'exits', 'vps', 'subs', 'official'];
    var curTab = TP.prefs.get('servers.tab', 'nodes');
    if (names.indexOf(curTab) < 0) curTab = 'nodes';
    names.forEach(function (k) { panels[k] = h('div', { class: 'servers-pane', role: 'tabpanel', id: 'servers-panel-' + k }); panels[k].hidden = k !== curTab; });
    var tabs = ui.tabs(L('servers.tabs.aria'), names.map(function (k) { return { id: k, label: L('servers.tab.' + k), icon: k === 'vps' ? 'server' : k === 'subs' ? 'refresh' : k === 'official' ? 'pro' : k === 'exits' ? 'pin' : 'nav-servers' }; }), function (k) { pickTab(k); });
    pickTab = function (k) {
      tabs.set(k); names.forEach(function (n) { panels[n].hidden = n !== k; }); TP.prefs.set('servers.tab', k);
      if (k === 'exits') TP.exits.load();
    };
    names.forEach(function (k) { panels[k].setAttribute('aria-labelledby', tabs.btn(k).id); tabs.btn(k).setAttribute('aria-controls', panels[k].id); });
    tabs.set(curTab); root.appendChild(tabs.el); names.forEach(function (k) { root.appendChild(panels[k]); });
    /* 工具栏 */
    el.addBtn = ui.btn(L('servers.add'), { kind: 'primary', icon: 'plus' });
    ui.act(el.addBtn, function () { return TP.imp.open('import'); });
    el.testBtn = ui.btn(L('servers.test.all'), { icon: 'speed' });
    ui.act(el.testBtn, function () { if (!servers().length) { TP.imp.open('import'); return; } return testAll(); });
    el.stopBtn = ui.btn(L('servers.test.stop'), { sm: true, icon: 'stop' }); el.stopBtn.hidden = true;
    ui.act(el.stopBtn, function () { test.stop = true; });
    el.sort = h('select', { class: 'sel', 'aria-label': L('servers.sort.aria'), on: { change: function () {
      sortKey = el.sort.value; TP.prefs.set('servers.sort', sortKey);
      if (so && so.state()) so.set(''); else renderTable();              // 用了下拉框: 取消列头排序 (so.set 会同步下拉框并重画)
    } } },
      TP.opt('default', t('servers.sort.role')), TP.opt('delay', t('servers.sort.delay')), TP.opt('name', t('servers.sort.name')));
    el.count = h('span', { class: 'muted sm' });
    el.tBar = ui.bar(); el.tMsg = h('span', { class: 'muted sm', 'aria-live': 'polite' });
    el.tBox = h('div', { class: 'testbar', hidden: true }, el.tBar.el, el.tMsg);
    el.sort.value = sortKey;
    panels.nodes.appendChild(h('div', { class: 'toolbar' }, el.addBtn, el.testBtn, el.stopBtn, el.sort, el.count, ui.help('servers.nodes')));
    panels.nodes.appendChild(el.tBox);

    /* 服务器表 */
    el.tbody = h('tbody');
    el.empty = ui.emptyBox();
    el.pg = ui.pager('servers', { def: 10 }); el.pg.onChange(function () { renderTable(); });
    so = ui.sorter('servers', {
      name: { get: function (s) { return s.tag; } },
      type: { get: function (s) { return s.type; } },
      addr: { get: function (s) { return s.server ? s.server + ':' + s.port : null; } },
      role: { type: 'num', get: function (s) { return ROLE_RANK[s.role]; } },
      lat: { type: 'num', get: latOf }
    }, { onChange: function () { syncSort(); if (el.pg.page() !== 1) el.pg.setPage(1); else renderTable(); } });       // setPage 会触发分页的 onChange 重画
    var heads = [['name', 'servers.col.name'], ['type', 'servers.col.type'], ['addr', 'servers.col.addr'], ['role', 'servers.col.role'], ['lat', 'servers.col.lat']].map(function (c) {
      var th = h('th', { scope: 'col' });
      so.attach(th, c[0], function () { return t(c[1]); });
      if (c[0] === 'role') th.appendChild(ui.help('servers.roles'));      // 帮助按钮放在排序按钮外面
      return th;
    });
    panels.nodes.appendChild(h('section', { class: 'card flush' },
      h('div', { class: 'tbl-wrap' }, h('table', { class: 'tbl rt' },
        h('thead', null, h('tr', null, heads.concat(h('th', { scope: 'col', class: 'c-act' }, L('servers.col.act'))))),     // 「操作」列不排序
        el.tbody)),
      el.empty.el, el.pg.el));
    syncSort();

    /* 出口分配: 每个固定出口上有哪些应用 / 网站 / 服务, 跟随默认的, 指定的出口已不存在的 (exits.js) */
    panels.exits.appendChild(TP.exits.card());

    /* enana 官方线路 (会员): 以后订阅用户登录后自动出现; 现在是「即将推出」占位卡片 (读 GET /api/plan 的 features.official_proxy) */
    panels.official.appendChild(officialCard());
    panels.official.appendChild(h('section', { class: 'card srv-off' }, h('div', { class: 'card-h' }, ui.icon('pro', 20, 'ci'), h('h3', null, L('billing.dedicatedTitle')), ui.badge(L('billing.none'), 'neutral')), h('p', { class: 'muted' }, L('billing.dedicatedNote'))));

    /* 订阅 */
    el.subs = h('div', { class: 'rows' });
    el.subsEmpty = ui.emptyBox();
    panels.subs.appendChild(h('section', { class: 'card' },
      h('div', { class: 'card-h' }, h('h3', null, L('servers.subs.title'), ui.help('servers.subs')), h('span', { class: 'muted sm' }, L('servers.subs.sub'))), el.subs, el.subsEmpty.el));

    /* 我的服务器 (SSH 一键部署过的 VPS 记录, 不含任何密码 / 私钥) — 由 v-vps.js 提供, 缺失时整块省略 */
    if (TP.vps && TP.vps.listCard) { try { panels.vps.appendChild(TP.vps.listCard()); } catch (e) { console.error('[vps.listCard]', e); } }

    TP.on('state', function () { if (active()) { V.render(); TP.exits.load(20000); } autoCheck(); });
    TP.on('exits', function () { if (active()) renderStrip(); });
    TP.on('proxies', function () { if (active()) V.render(); });
    TP.on('helper', function () { if (active()) V.render(); });
    TP.on('clash', function () { if (active()) V.render(); });
    TP.on('lang', function () { el.pinSel._sig = null; el.autoSel._sig = null; V.render(); });
    TP.on('plan', function () { paintOfficial(); });
    TP.on('auth', function (ok) { if (ok && active()) V.render(); });
    setInterval(function () { if (active() && !document.hidden) paintTest(); }, 1000);
    V.render();
  };
  V.show = function () { V.render(); TP.plan.load(false); TP.exits.load(); };

  V.render = function () {
    renderStrip(); renderTable(); renderSubs(); paintTest(); paintOfficial();
    if (nodeDlg) nodeDlg.render();
  };

  /* ================= 当前出口 ================= */
  function fillSelect(sel, tags, labelOf) {
    var sig = I.lang + '|' + tags.join('\u0001');
    if (sel._sig !== sig) {
      sel._sig = sig; TP.clear(sel);
      tags.forEach(function (x) { sel.appendChild(TP.opt(x, labelOf(x))); });
    }
  }
  function renderStrip() {
    var P = S.proxies, pin = P.PIN, gl = P.Global, why = TP.why.clash();
    var pinAll = TP.pinAll();
    fillSelect(el.pinSel, pinAll, function (x) { return x; });
    if (pin && pinAll.indexOf(pin.now) >= 0 && el.pinSel.value !== pin.now) el.pinSel.value = pin.now;
    ui.avail(el.pinSel, why || (pinAll.length < 1 ? t('servers.pin.none') : ''), pinAll.length < 1 && !why ? addFix() : null);
    var pl = TP.leaf('PIN'), d = pl ? TP.delayOf(pl) : null;
    setText(el.pinInfo, !pinAll.length ? t('servers.pin.noneHint') : t('servers.pin.hint') + (d ? ' ' + t('servers.pin.delay', { ms: fmtMs(d.ms) }) : ''));
    var fl = pinAll.length ? TP.exits.followLine() : '';
    setText(el.pinFollow, fl); el.pinFollow.hidden = !fl; el.pinView.hidden = !pinAll.length || !S.exits;
    var oc = TP.exits.orphanCount();
    el.pinOrphan.hidden = !oc;
    if (oc) { TP.clear(el.pinOrphan); el.pinOrphan.appendChild(ui.icon('warning', 14, 'ci')); el.pinOrphan.appendChild(h('span', null, t('servers.pin.orphan', { n: oc }))); }
    var glAll = (gl && gl.all) || [];
    fillSelect(el.autoSel, glAll, function (x) { return x === 'AUTO' ? t('servers.auto.best') : x; });
    if (gl && gl.now && el.autoSel.value !== gl.now) el.autoSel.value = gl.now;
    ui.avail(el.autoSel, why || (glAll.length < 1 ? t('servers.auto.none') : ''), glAll.length < 1 && !why ? addFix() : null);
    var manual = TP.globalPinned();
    el.autoBack.hidden = !manual; ui.avail(el.autoBack, why);
    var leaf = TP.leaf('Global');
    setText(el.autoInfo, !glAll.length ? t('servers.auto.noneHint')
      : (manual ? t('servers.auto.manual', { tag: gl.now }) : (gl && gl.all && gl.all.indexOf('AUTO') >= 0 ? t('servers.auto.auto', { tag: leaf || '—' }) : t('servers.auto.using', { tag: leaf || '—' }))));
  }
  async function switchTo(group, tag) {
    if (!tag) return;
    var P = S.proxies, cur = P[group] && P[group].now, isPin = group === 'PIN';
    if (cur === tag) { ui.toast(t('servers.switch.same'), ''); return; }
    var tagLabel = tag === 'AUTO' ? t('servers.auto.best') : tag, curLabel = cur === 'AUTO' ? t('servers.auto.best') : (cur || '—');
    if (isPin) {                                                         // 默认固定出口: 先列出谁在跟随它 (换了它们的出口 IP 会变), 让用户选择「继续走原出口」还是「跟着换」
      var done = await TP.exits.switchDefault(curLabel, tag, function (pre) {
        return ui.confirmDialog({ title: t('servers.switch.titlePin'), message: t('servers.switch.msgPin', { from: curLabel, to: tagLabel }), detail: t(pre.none ? 'servers.switch.detailPinNone' : 'servers.switch.detailPin'), confirmText: t('servers.switch.go'), rememberKey: 'policy' });
      });
      if (done) ui.toast(t('servers.switch.done', { group: t('servers.pin.title'), to: tagLabel }), 'ok');
      return;
    }
    var ok = await ui.confirmDialog({
      title: t('servers.switch.titleAuto'),
      message: t('servers.switch.msgAuto', { from: curLabel, to: tagLabel }),
      detail: t(tag === 'AUTO' ? 'servers.switch.detailAuto' : 'servers.switch.detailAutoPin'),
      confirmText: t('servers.switch.go'), rememberKey: 'policy'
    });
    if (!ok) return;
    await TP.setPolicy(group, tag);
    ui.toast(t('servers.switch.done', { group: t('name.policy.Global'), to: tagLabel }), 'ok');
  }

  /* ================= 服务器表 ================= */
  function delayVal(tag) { var d = TP.delayOf(tag); return !d ? 1e9 : d.ms > 0 ? d.ms : 1e9 + 1; }
  function sorted() {
    var list = servers().map(function (s, i) { return { s: s, i: i }; });
    list.sort(function (a, b) {
      if (sortKey === 'delay') return delayVal(a.s.tag) - delayVal(b.s.tag) || a.i - b.i;
      if (sortKey === 'name') return a.s.tag.localeCompare(b.s.tag, I.lang) || a.i - b.i;
      return (ROLE_RANK[a.s.role] || 0) - (ROLE_RANK[b.s.role] || 0) || a.i - b.i;
    });
    list = list.map(function (x) { return x.s; });
    return so && so.state() ? so.apply(list) : list;                      // 列头排序 (整张表, 先排序再分页); 稳定, 同值的行保持下拉框的顺序
  }
  /* 延迟列的排序值 (和单元格显示的一致): 没测过 / 不在核心里 (显示 —) = null, 永远排最后; 超时排在所有有延迟的后面 (降序时最先) */
  function latOf(s) {
    var d = S.proxies[s.tag] ? TP.delayOf(s.tag) : null;
    return !d ? null : d.ms > 0 ? d.ms : 1e9;
  }
  /* 工具栏的排序下拉跟列头保持一致: 没有列头排序 = 下拉框自己的值; 列头排序刚好对应下拉框的某一项 (升序的 名称 / 延迟 / 角色) 就显示那一项, 其它列没有对应项 = 留空 */
  function syncSort() {
    if (!so || !el.sort) return;
    var s = so.state(), v = !s ? sortKey : s.dir === 'asc' ? { name: 'name', lat: 'delay', role: 'default' }[s.key] : null;
    if (v) el.sort.value = v; else el.sort.selectedIndex = -1;
  }
  function td(labelKey, cls) { var kids = Array.prototype.slice.call(arguments, 2); return h.apply(null, ['td', { 'data-l': labelKey ? L(labelKey) : '', class: cls || '' }].concat(kids)); }
  function renderTable() {
    var all = sorted(), why = TP.why.helper(), pr = el.pg.update(all.length), list = all.slice(pr.start, pr.end);
    el.sort.options[0].textContent = t('servers.sort.role'); el.sort.options[1].textContent = t('servers.sort.delay'); el.sort.options[2].textContent = t('servers.sort.name');
    ui.syncList(el.tbody, list, function (s) { return s.tag; }, makeRow, function (row, s) { updateRow(row, s, why); });
    var n = servers().length;
    setText(el.count, n ? t('servers.count', { n: n }) : '');
    if (!n) {
      if ((TP.noHelper() || S.state) && el.skel && el.skel.parentNode) el.skel.parentNode.removeChild(el.skel);
      if (TP.noHelper()) el.empty.show({ icon: 'wifi-off', text: t('servers.empty.noHelper'), hint: t('servers.empty.noHelperHint') });
      else if (!S.state) { el.empty.hide(); if (!el.skel) el.skel = ui.skeleton(6); if (!el.skel.parentNode && el.empty.el.parentNode) el.empty.el.parentNode.insertBefore(el.skel, el.empty.el); }
      else el.empty.show({ icon: 'nav-servers', text: t('servers.empty.none'), hint: t('servers.empty.noneHint'), action: { label: t('servers.add'), icon: 'plus', fn: function () { return TP.imp.open('import'); } } });
    } else { el.empty.hide(); if (el.skel && el.skel.parentNode) el.skel.parentNode.removeChild(el.skel); }
  }
  function makeRow() {
    var r = {}, tr;
    r.name = h('button', { class: 'srv-n link-b', type: 'button' }); r.badges = h('span', { class: 'badges' });
    r.type = h('span', { class: 'chip' }); r.addr = h('span', { class: 'mono sm' });
    r.role = h('select', { class: 'sel sm' }, ROLES.map(function (k) { return TP.opt(k, TP.name.role(k)); }));
    r.lat = h('span', { class: 'lat' });
    r.bInfo = ui.btn(t('servers.col.act'), { sm: true, icon: 'menu' });
    tr = h('tr', null,
      td('', 'c-name', h('div', { class: 'c-name-in' }, r.name, r.badges)),
      td('servers.col.type', 'c-type', r.type), td('servers.col.addr', 'c-addr', r.addr), td('servers.col.role', 'c-role', r.role), td('servers.col.lat', 'c-lat', r.lat),
      td('', 'c-act', r.bInfo));
    tr._r = r;
    r.name.addEventListener('click', function () { openNode(tr._s.tag); });
    ui.act(r.bInfo, function () { openNode(tr._s.tag); });
    ui.selectAct(r.role, function () { return pendingRole[tr._s.tag] || tr._s.role; }, function (want) { return askRole(tr._s, want); });
    return tr;
  }
  function setTip(b, text) { b._tip = text; b.setAttribute('aria-label', text); if (!b._un) b.title = text; }
  function updateRow(tr, s, why) {
    var r = tr._r, P = S.proxies, inP = !!P[s.tag], busy = !!pendingDel[s.tag], clashWhy = TP.why.clash();
    tr._s = s;
    setText(r.name, s.tag); r.name.title = s.tag;
    setText(r.type, s.type); setText(r.addr, s.server ? s.server + ':' + s.port : '—');
    var role = pendingRole[s.tag] || s.role;
    if (r.role.value !== role) r.role.value = role;
    Array.prototype.forEach.call(r.role.options, function (o) {
      var base = TP.name.role(o.value), txt = o.value === 'dl' && !canDl(s.type) ? t('servers.role.dlSuffix', { name: base }) : base;
      if (o.textContent !== txt) o.textContent = txt;
    });
    ui.avail(r.role, why || (s.official ? t('servers.row.officialRole') : '') || (s.derived ? t('servers.row.derived') : '') || (busy ? t('servers.row.busy') : ''));
    r.role.setAttribute('aria-label', t('servers.row.roleAria', { tag: s.tag }));
    // 徽章
    var b = [];
    if (P.PIN && P.PIN.now === s.tag) b.push([t('servers.badge.pin'), 'pin']);
    if (P.Global && P.Global.now === s.tag) b.push([TP.globalPinned() ? t('servers.badge.autoPinned') : t('servers.badge.autoUse'), 'auto']);
    else if (P.AUTO && P.AUTO.now === s.tag && P.Global && P.Global.now === 'AUTO') b.push([t('servers.badge.autoPicked'), 'auto']);
    if (s.official) b.push([t('servers.badge.official'), 'pro']);
    if (s.sub) b.push([t('servers.badge.sub', { name: s.sub }), '']);
    if (busy) b.push([t('servers.badge.deleting'), 'warn']);
    var bsig = I.lang + '|' + b.map(function (x) { return x.join(':'); }).join('|');
    if (r.badges._sig !== bsig) { r.badges._sig = bsig; TP.clear(r.badges); b.forEach(function (x) { r.badges.appendChild(h('span', { class: 'badge ' + x[1] }, x[0])); }); }
    // 延迟
    var d = TP.delayOf(s.tag);
    setText(r.lat, !inP ? '—' : !d ? '—' : d.ms > 0 ? d.ms + ' ms' : t('common.timeout'));
    TP.setCls(r.lat, 'lat ' + (!d || !inP ? '' : d.ms < 0 ? 'bad' : d.ms < 150 ? 'good' : d.ms < 400 ? 'mid' : 'bad'));
    // Keep the table compact; the dialog owns all node actions and their guards.
    ui.setBtn(r.bInfo, t('servers.col.act'), 'menu');
    setTip(r.bInfo, t('servers.row.actionsOf', { tag: s.tag }));
    tr.classList.toggle('is-off', role === 'off'); tr.classList.toggle('is-busy', busy);
  }

  async function askRole(s, role) {
    var cur = pendingRole[s.tag] || s.role;
    if (!role || role === cur) return;
    if (role === 'dl' && !canDl(s.type)) { ui.toast(t('servers.dlOnly'), 'warn'); return; }
    var q = { tag: s.tag, role: role }, pre = {};
    if (s.role === 'pin' && role !== 'pin') {                           // 固定出口改成别的角色 = 把它从固定出口里移除: 先看谁在用它 (指定了它的 / 跟随它作默认的), 让用户选择去向
      pre = await TP.exits.askRemove(s, role);
      if (!pre) return;
      Object.keys(pre).forEach(function (k) { q[k] = pre[k]; });
    }
    if (!Object.keys(pre).length) {                                     // 没有谁在用它: 普通确认 (已经走过事前检查对话框的不再重复确认)
      var tx = TP.txt.role(s.tag, s.role, role);
      var ok = await ui.confirmDialog({ title: t('servers.role.title'), message: tx.message, detail: tx.detail, confirmText: t('servers.role.go') });
      if (!ok) return;
    }
    pendingRole[s.tag] = role; renderTable();
    try {
      await TP.jobs.runInDock(t('servers.role.job', { tag: s.tag }), function () { return TP.helper('POST', '/api/servers/role', { q: q }); });
    } finally { delete pendingRole[s.tag]; await TP.loadState(); renderTable(); }
  }
  async function del(s) {
    var q = { tag: s.tag }, pre = {};
    if (s.role === 'pin') {                                             // 删除固定出口: 先看谁在用它 (指定了它的 / 跟随它作默认的), 让用户选择去向
      pre = await TP.exits.askRemove(s, '');
      if (!pre) return;
      Object.keys(pre).forEach(function (k) { q[k] = pre[k]; });
    }
    if (!Object.keys(pre).length) {                                     // 走过事前检查对话框的 (已经明确选择了去向并点了「删除」) 不再重复确认
      var ok = await ui.confirmDialog({ title: t('servers.del.title'), message: t('servers.del.msg', { tag: s.tag }), detail: [s.sub ? t('servers.del.sub', { name: s.sub }) : '', t('servers.del.d1')].filter(Boolean), confirmText: t('common.delete'), danger: true });
      if (!ok) return;
    }
    pendingDel[s.tag] = true; renderTable();
    try {
      await TP.jobs.runInDock(t('servers.del.job', { tag: s.tag }), function () { return TP.helper('POST', '/api/servers/delete', { q: q }); });
    } finally { delete pendingDel[s.tag]; await TP.loadState(); renderTable(); }
  }

  /* ================= 测速 ================= */
  async function testOne(tag) {
    var ms = await TP.testDelay(tag);
    renderTable(); renderStrip();
    ui.toast(t('servers.test.one', { tag: tag, ms: fmtMs(ms) }), ms > 0 ? 'ok' : 'warn', 2400);
  }
  /* 「测速全部」按钮的文字 / 状态 */
  function testState() {
    var list = servers(), n = list.length, why = TP.why.clash();
    if (!n) return { label: t('servers.test.addFirst'), icon: 'plus' };            // 没有服务器: 点击直接打开「添加服务器」
    if (test.running) return { label: t('servers.test.running', { i: test.i, n: test.n }), icon: 'refresh', busy: true, reason: t('servers.test.runningReason', { i: test.i, n: test.n }) };
    if (why) return { label: t('servers.test.all'), icon: 'speed', reason: why };
    var routable = list.filter(function (s) { return s.role !== 'off' && s.role !== 'dl' && S.proxies[s.tag]; }).length;
    if (!routable) return { label: t('servers.test.all'), icon: 'speed', reason: t('servers.test.noneRoutable') };
    return { label: t(test.done ? 'servers.test.again' : 'servers.test.all'), icon: 'speed' };
  }
  function paintTest() { TP.paintBtn(el.testBtn, testState()); el.stopBtn.hidden = !test.running; }

  /* 逐个测速, 带 n/N 进度条; tags 缺省 = 全部参与路由的服务器; onProgress(i, n, tag) 供导入弹窗同步显示 */
  async function testAll(tags, onProgress) {
    if (test.running) return null;
    var list = (tags || servers().filter(function (s) { return s.role !== 'off' && s.role !== 'dl'; }).map(function (s) { return s.tag; })).filter(function (x) { return S.proxies[x]; });
    if (!list.length) { ui.toast(t('servers.test.noneRoutable'), 'warn'); return null; }
    test.running = true; test.stop = false; test.i = 0; test.n = list.length; paintTest(); renderTable();
    el.tBox.hidden = false; el.tBar.set(0, '');
    var i, best = null, ok = 0;
    try {
      for (i = 0; i < list.length; i++) {
        if (test.stop) break;
        test.i = i + 1; paintTest();
        setText(el.tMsg, t('servers.test.progress', { i: i + 1, n: list.length, tag: list[i] }));
        el.tBar.set(i / list.length * 100);
        if (onProgress) onProgress(i, list.length, list[i]);
        var ms = await TP.testDelay(list[i]);
        if (ms > 0) { ok++; if (!best || ms < best.ms) best = { tag: list[i], ms: ms }; }
        renderTable();
      }
      var done = !test.stop;
      el.tBar.set(100, done ? 'ok' : 'err');
      setText(el.tMsg, t(done ? 'servers.test.done' : 'servers.test.stopped', { ok: ok, n: list.length }) + (best ? ' · ' + t('servers.test.best', { tag: best.tag, ms: best.ms }) : ''));
      if (done && !tags) { sortKey = 'delay'; syncSort(); test.done = true; }       // 列头排序开着时它优先 (sortKey 只决定同值行的顺序)
      if (onProgress) onProgress(list.length, list.length, '');
      if (done) ui.toast(t('servers.test.doneToast', { ok: ok, n: list.length }), 'ok');
      return { ok: ok, total: list.length, best: best };
    } finally {
      test.running = false; paintTest(); renderTable(); renderStrip();
      setTimeout(function () { if (!test.running) el.tBox.hidden = true; }, 6000);
    }
  }
  V.testTags = testAll;
  V.testing = function () { return test.running; };

  /* ================= 订阅 ================= */
  function findSub(name) { return ((S.state && S.state.subs) || []).filter(function (x) { return x.name === name; })[0]; }
  function renderSubs() {
    var subs = (S.state && S.state.subs) || [], why = TP.why.helper();
    ui.syncList(el.subs, subs, function (x) { return x.name; }, makeSub, function (row, x) { updateSub(row, x, why); });
    if (subs.length) el.subsEmpty.hide();
    else el.subsEmpty.show({ icon: 'link', text: t('servers.subs.empty'), hint: t('servers.subs.emptyHint'), action: TP.noHelper() ? null : { label: t('servers.subs.add'), icon: 'plus', fn: function () { return TP.imp.open('import'); } } });
  }
  function makeSub() {
    var r = {};
    r.name = h('b'); r.host = h('span', { class: 'muted sm' }); r.meta = h('div', { class: 'muted sm' });
    r.usage = h('div', { class: 'sm' }); r.bar = ui.bar(); r.bar.el.classList.add('thin');
    r.refresh = ui.btn(L('servers.subs.refresh'), { sm: true, icon: 'refresh' });
    r.del = TP.sudo.mark(ui.ibtn('delete', t('common.delete'), { cls: 'danger-t' }));
    r.url = TP.sudo.mark(ui.btn(L('servers.subs.url'), { sm: true, icon: 'eye' }));
    var row = h('div', { class: 'sub' }, h('div', { class: 'sub-main' }, h('div', { class: 'sub-t' }, r.name, r.host), r.meta, r.usage, r.bar.el), h('div', { class: 'acts' }, r.refresh, r.url, r.del));
    row._r = r;
    ui.act(r.url, function () { return showSubUrl(row._x); });
    ui.act(r.refresh, function () { return askRefresh(row._x); });
    ui.act(r.del, function () { return delSub(row._x); });
    return row;
  }
  function subLabel(name) {
    if (refreshing[name]) return { label: t('servers.subs.refreshing'), busy: true, reason: t('servers.subs.refreshingReason') };
    if (Date.now() - (refreshedAt[name] || 0) < 60000) return { label: t('servers.subs.justNow'), muted: true };
    return { label: t('servers.subs.refresh') };
  }
  function updateSub(row, x, why) {
    var r = row._r, iv = +x.interval || 12, due = !x.updated || (Date.now() / 1000 - x.updated) > iv * 3600, st = subLabel(x.name);
    row._x = x;
    setText(r.name, x.name); setText(r.host, x.host);
    setText(r.meta, t('servers.subs.meta', { when: TP.fmt.rel(x.updated), n: x.count || 0, h: iv }) + (due ? ' · ' + t('servers.subs.due') : ''));
    var u = x.usage, txt = TP.fmt.usage(u);
    setText(r.usage, txt); r.usage.hidden = !txt;
    var pct = u && +u.total > 0 ? Math.min(100, (+u.used) / (+u.total) * 100) : null;
    r.bar.el.hidden = pct == null; if (pct != null) r.bar.set(pct, pct > 90 ? 'err' : '');
    TP.paintBtn(r.refresh, { label: st.label, icon: 'refresh', busy: st.busy, muted: st.muted, reason: why || st.reason || '' });
    ui.avail(r.del, why || (refreshing[x.name] ? t('servers.subs.refreshingReason') : '')); ui.avail(r.url, why);
    setTip(r.del, t('servers.subs.delAria', { name: x.name }));
  }
  async function askRefresh(x) {
    var ok = await ui.confirmDialog({ title: t('servers.subs.refreshTitle'), message: t('servers.subs.refreshMsg', { name: x.name }), detail: [t('servers.subs.refreshD1'), t('servers.subs.refreshD2')], confirmText: t('servers.subs.refresh'), rememberKey: 'subrefresh' });
    if (!ok) return;
    await TP.subs.refresh(x.name, false);
  }
  async function delSub(x) {
    var n = x.count || 0, imp = await TP.exits.subImpact(x.name), q = { name: x.name }, detail = [t('servers.subs.delDetail', { n: n })];
    if (imp && (imp.n > 0 || !imp.known)) {                             // 订阅里有固定出口: 它们一起消失, 指定了它们的应用 / 网站 / 服务会退回默认固定出口 (没有固定出口时直连)
      detail.push(t(imp.known ? 'servers.subs.delPins' : 'servers.subs.delPinsUnknown', { pins: imp.pins.join(', '), n: imp.n }));
      q.accept_orphans = 1;
    }
    var ok = await ui.confirmDialog({ title: t('servers.subs.delTitle'), message: t('servers.subs.delMsg', { name: x.name }), detail: detail, confirmText: t('common.delete'), danger: true });
    if (!ok) return;
    await TP.jobs.runInDock(t('servers.subs.delJob', { name: x.name }), function () { return TP.helper('POST', '/api/sub/delete', { q: q }); });
    await TP.loadState();
    V.render();
  }

  /* 刷新订阅: 下载 -> 解析 -> 写入并应用 (mode=replace), 带总进度条。已有节点保留原来的角色。 */
  TP.subs.refresh = async function (name, auto) {
    if (refreshing[name]) return null;
    var x = findSub(name);
    refreshing[name] = true; TP.ls.set('subtry.' + name, Date.now()); V.render();
    var card = ui.taskCard(t(auto ? 'servers.subs.autoJob' : 'servers.subs.refreshJob', { name: name })), steps = [{ label: t('imp.step.download'), state: 'run' }, { label: t('imp.step.parse'), state: 'todo' }, { label: t('imp.step.write'), state: 'todo' }];
    ui.dock(card); card.set({ pct: null, msg: t('imp.msg.downloading'), steps: steps });
    try {
      var own = {}, others = [];
      servers().forEach(function (s) { if (s.sub === name) own[s.tag] = s.role; else others.push(s.tag); });
      var r = await TP.imp.fetchSub({ name: name, existingTags: others, onNote: function (m) { card.set({ msg: m }); } });
      // 带警告的节点 (如链接里没有账号密码) 不自动加入, 除非它本来就在这个订阅里
      r.servers = r.servers.filter(function (s) { return !s.warn || own[s.outbound.tag] !== undefined; });
      if (!r.servers.length) throw new Error(t('servers.subs.noNodes'));
      r.servers.forEach(function (s) { s.role = own[s.outbound.tag] || 'auto'; });
      steps[0].state = 'done'; steps[1].state = 'done'; steps[2].state = 'run';
      card.set({ pct: 40, msg: t('servers.subs.parsed', { n: r.servers.length }), steps: steps });
      var res = await TP.helper('POST', '/api/servers/import', { q: { sub: name, mode: 'replace' }, body: TPImporter.toJSONL(r.servers, name) });
      if (res.job) await TP.jobs.follow(res.job, { fromJob: function (jj) { card.set({ pct: 40 + (+jj.pct || 0) * 0.6, msg: jj.msg || t('job.applying'), steps: steps }); } });
      steps[2].state = 'done';
      var msg = t('servers.subs.result', { added: res.added || 0, replaced: res.replaced || 0, removed: res.removed || 0 });
      card.set({ steps: steps }); card.done(msg);
      setTimeout(card.close, 8000);
      ui.toast(t('servers.subs.doneToast', { name: name, msg: msg }), 'ok');
      refreshedAt[name] = Date.now();
      TP.afterApply();
      return { ok: true };
    } catch (e) {
      if (e && e.kind === 'auth') { card.close(); return { ok: false, error: e }; }
      steps.forEach(function (s) { if (s.state === 'run') s.state = 'error'; });
      card.set({ steps: steps }); card.fail(TP.errMsg(e));
      ui.toast(t(auto ? 'servers.subs.autoFail' : 'servers.subs.refreshFail', { name: name, reason: TP.errMsg(e) }), auto ? 'warn' : 'err');
      return { ok: false, error: e };
    } finally { delete refreshing[name]; if (x) TP.loadState(); V.render(); }
  };

  /* 打开仪表盘时, 超过更新间隔的订阅自动刷新; 同一订阅最多每小时尝试一次, 一次只处理一个 */
  var autoBusy = false;
  function autoCheck() {
    if (autoBusy || S.locked || !S.state || TP.noHelper() || S.clash !== 'ok' || document.hidden || TP.jobs.active() || (TP.imp && TP.imp.busy())) return;
    var now = Date.now() / 1000, subs = S.state.subs || [], i, x, iv, last;
    for (i = 0; i < subs.length; i++) {
      x = subs[i]; iv = (+x.interval || 12) * 3600; last = TP.ls.get('subtry.' + x.name, 0);
      if ((!x.updated || now - x.updated > iv) && Date.now() - last > 3600000 && !refreshing[x.name]) {
        autoBusy = true;
        TP.subs.refresh(x.name, true).then(function () { autoBusy = false; }, function () { autoBusy = false; });
        return;
      }
    }
  }

  /* ================= 服务器详情 (弹窗, 不在表格里行内展开) + 显示凭据 (敏感操作: 再次输入登录密码, 30 秒后自动隐藏, 只在内存里) ================= */
  var nodeDlg = null;
  function kvr(label, value) { return h('div', { class: 'kv-row' }, h('span', { class: 'kv-k' }, label), h('span', { class: 'kv-v' }, value)); }
  function openNode(tag) {
    if (nodeDlg) return;
    var box = h('div', { class: 'nd' }), secret = null, timer = 0, dm = null;
    function cur() { return servers().filter(function (x) { return x.tag === tag; })[0]; }
    function stopTimer() { clearInterval(timer); timer = 0; }
    function hideSecret() { secret = null; stopTimer(); render(); }
    function render() {
      var s = cur();
      if (!s) { if (dm) dm.close('gone'); return; }
      var P = S.proxies, isPin = !!(P.PIN && P.PIN.now === s.tag), isGl = !!(P.Global && P.Global.now === s.tag), d = TP.delayOf(s.tag), inP = !!P[s.tag];
      dm.setTitle(s.tag);
      TP.clear(box);
      var bd = h('div', { class: 'badges nd-badges' });
      bd.appendChild(h('span', { class: 'badge ' + (s.role === 'pin' ? 'pin' : s.role === 'auto' ? 'auto' : 'neutral') }, TP.name.role(s.role)));
      if (s.official) bd.appendChild(ui.badge(t('servers.badge.official'), 'pro', 'pro'));
      if (isPin) bd.appendChild(ui.badge(t('servers.badge.pin'), 'info'));
      if (isGl) bd.appendChild(ui.badge(TP.globalPinned() ? t('servers.badge.autoPinned') : t('servers.badge.autoUse'), 'ok'));
      if (s.sub) bd.appendChild(ui.badge(t('servers.badge.sub', { name: s.sub }), 'neutral', 'link'));
      box.appendChild(bd);
      box.appendChild(kvr(t('servers.col.type'), h('span', { class: 'chip' }, s.type)));
      box.appendChild(kvr(t('servers.col.addr'), h('span', { class: 'mono' }, s.server ? s.server + ':' + s.port : '—')));
      box.appendChild(kvr(t('servers.col.role'), TP.name.role(s.role)));
      var lat = h('span', { class: 'lat ' + (!d || !inP ? '' : d.ms < 0 ? 'bad' : d.ms < 150 ? 'good' : d.ms < 400 ? 'mid' : 'bad') }, !inP || !d ? '—' : d.ms > 0 ? d.ms + ' ms' : t('common.timeout'));
      box.appendChild(kvr(t('servers.col.lat'), lat));
      box.appendChild(h('div', { class: 'nd-sec' },
        h('div', { class: 'nd-sec-h' }, ui.icon('lock', 15, 'ci'), h('b', null, t('servers.nd.cred')), ui.help('servers.reveal')),
        secret ? secretView() : h('p', { class: 'muted sm' }, t(s.official ? 'servers.secret.official' : 'servers.nd.credHint'))));
      var why = TP.why.helper(), clashWhy = TP.why.clash(), busy = !!pendingDel[s.tag];
      var inPin = !!(P.PIN && P.PIN.all && P.PIN.all.indexOf(s.tag) >= 0);
      var inGl = !!(P.Global && P.Global.all && P.Global.all.indexOf(s.tag) >= 0);
      ui.avail(dm.getBtn('test'), clashWhy || (!inP ? t('servers.row.notRouted') : '') || (test.running ? t('servers.test.runningShort') : ''));
      ui.avail(dm.getBtn('pin'), clashWhy || (isPin ? t('servers.row.isPin') : !inPin ? t('servers.row.notInPin') : ''),
        !inPin && !clashWhy ? { label: t('servers.row.makePinRole'), fn: function () { return askRole(cur(), 'pin'); } } : null);
      ui.avail(dm.getBtn('auto'), clashWhy || (isGl ? t('servers.row.isAuto') : !inGl ? t('servers.row.notInAuto') : ''),
        !inGl && !clashWhy ? { label: t('servers.row.makeAutoRole'), fn: function () { return askRole(cur(), 'auto'); } } : null);
      ui.avail(dm.getBtn('rev'), why || (s.official ? t('servers.secret.official') : '') || (s.derived ? t('servers.row.derived') : ''));
      ui.avail(dm.getBtn('del'), why || (s.official ? t('servers.row.officialDel') : '') || (s.derived ? t('servers.row.derived') : '') || (busy ? t('servers.row.busy') : ''));
    }
    function secretView() {
      var left = Math.max(0, Math.ceil((secret.until - Date.now()) / 1000));
      var list = h('div', { class: 'nd-secret' }, secret.fields.map(function (f) {
        var nm = I.has('servers.secret.f.' + f.name) ? t('servers.secret.f.' + f.name) : String(f.name), val = String(f.value == null ? '' : f.value);
        var cp = ui.ibtn('copy', t('common.copy') + ': ' + nm, { size: 16 }); ui.act(cp, function () { ui.copy(val); });
        return h('div', { class: 'nd-f' }, h('span', { class: 'nd-fk' }, nm), h('code', { class: 'nd-fv' }, val), cp);
      }));
      if (!secret.fields.length) list.appendChild(h('p', { class: 'muted sm' }, t('servers.secret.empty')));
      var hide = ui.btn(L('servers.nd.hide'), { sm: true, icon: 'eye-off' }); ui.act(hide, hideSecret);
      return h('div', null, list, h('div', { class: 'nd-secret-f' }, h('span', { class: 'muted sm', 'aria-live': 'off' }, t('servers.nd.autoHide', { n: left })), hide), h('p', { class: 'hint warn' }, ui.icon('warning', 14, 'ci'), h('span', null, t('servers.nd.secretNote'))));
    }
    async function reveal() {
      var s = cur(); if (!s) return false;
      var r = await TP.helper('GET', '/api/servers/secret', { q: { tag: s.tag }, timeout: 15000, sudoWhy: t('servers.secret.why', { tag: s.tag }) });
      secret = { fields: Array.isArray(r && r.fields) ? r.fields : [], until: Date.now() + 30000 };
      stopTimer(); timer = setInterval(function () { if (!secret || Date.now() >= secret.until) hideSecret(); else render(); }, 1000);
      render();
      return false;
    }
    var s0 = cur(); if (!s0) return;
    dm = ui.modal({
      title: s0.tag, icon: 'server', size: 'md', cls: 'nddlg', body: box,
      onClose: function () { secret = null; stopTimer(); nodeDlg = null; },
      actions: [
        { label: t('servers.row.usePin'), icon: 'pin', id: 'pin', keep: true, onClick: async function () { await switchTo('PIN', tag); render(); return false; } },
        { label: t('servers.row.useAuto'), icon: 'auto', id: 'auto', keep: true, onClick: async function () { await switchTo('Global', tag); render(); return false; } },
        { label: t('servers.nd.test'), icon: 'speed', id: 'test', keep: true, onClick: function () { return testOne(tag).then(function () { render(); return false; }); } },
        { label: t('servers.nd.reveal'), icon: 'eye', id: 'rev', keep: true, onClick: reveal, unavail: s0.official ? { reason: t('servers.secret.official') } : null },
        { label: t('common.delete'), kind: 'danger', icon: 'delete', id: 'del', keep: true, unavail: s0.official ? { reason: t('servers.row.officialDel') } : null, onClick: function () { var s = cur(); dm.close('del'); return del(s).then(function () { return false; }); } },
        { label: t('common.close'), cancel: true, autofocus: true }
      ]
    });
    TP.sudo.mark(dm.getBtn('rev')); TP.sudo.mark(dm.getBtn('del'));
    nodeDlg = { render: render }; render();
  }

  /* 订阅链接 (相当于一把钥匙, 敏感操作) */
  async function showSubUrl(x) {
    var r = await TP.helper('GET', '/api/sub/url', { q: { name: x.name }, timeout: 15000, sudoWhy: t('servers.subs.urlWhy', { name: x.name }) });
    var url = String(r && r.url || ''), timer = 0, dm = null;
    var inp = h('input', { class: 'inp mono', type: 'text', readonly: true, value: url, 'aria-label': t('servers.subs.urlTitle', { name: x.name }) });
    var body = h('div', { class: 'nd' }, h('p', { class: 'cfm-m' }, t('servers.subs.urlNote')), inp, h('p', { class: 'muted sm' }, t('servers.subs.urlAuto')));
    dm = ui.modal({
      title: t('servers.subs.urlTitle', { name: x.name }), icon: 'link', size: 'md', body: body,
      onClose: function () { clearTimeout(timer); inp.value = ''; },
      actions: [{ label: t('common.copy'), icon: 'copy', keep: true, onClick: function () { ui.copy(url); return false; } }, { label: t('common.close'), cancel: true }]
    });
    timer = setTimeout(function () { dm.close('timeout'); }, 60000);
    setTimeout(function () { try { inp.select(); } catch (e) { /* 忽略 */ } }, 80);
  }

  /* ================= enana 官方线路 (会员) 占位卡片 ================= */
  function officialCard() {
    el.offBadge = h('span', { class: 'srv-off-b' }); el.offDesc = h('p', { class: 'muted' });
    el.offBtn = ui.btn(L('servers.off.more'), { sm: true, kind: 'ghost', icon: 'help-i' });
    ui.act(el.offBtn, function () { TP.plan.explain('official_proxy'); });
    el.off = h('section', { class: 'card srv-off is-soon' }, h('div', { class: 'card-h' }, ui.icon('pro', 20, 'ci pro-ic'), h('h3', null, L('servers.off.title'), ui.help('servers.official')), el.offBadge, el.offBtn), el.offDesc);
    return el.off;
  }
  function paintOfficial() {
    if (!el.off) return;
    var d = TP.plan.get(), f = TP.plan.feature('official_proxy');
    el.off.hidden = !!(d && !f.known);                                     // 云端没有这一项权益: 不显示占位卡片
    var on = !!(f.enabled && d && d.official && d.official.available);
    el.off.classList.toggle('is-soon', !on);
    TP.clear(el.offBadge);
    var soon = f.comingSoon || !d, synced = servers().some(function (s) { return s.official; });          // synced = 本机已经取回了官方节点 (登录后几分钟内会同步)
    el.offBadge.appendChild(on ? ui.badge(t('servers.off.on', { n: (d.official && d.official.nodes) || 0 }), 'ok', 'success') : soon ? ui.badge(L('plan.soon'), 'info', 'clock')
      : f.reason === 'expired' ? ui.badge(L('plan.f.expired'), 'warn', 'warning') : f.reason === 'verify' ? ui.badge(L('plan.f.verify'), 'warn', 'warning') : ui.badge(L('plan.f.upgrade'), 'warn', 'lock'));
    setText(el.offDesc, t(on ? (synced ? 'servers.off.descOn' : 'servers.off.descSync') : soon ? 'servers.off.desc' : f.reason === 'expired' ? 'servers.off.descExpired' : f.reason === 'verify' ? 'servers.off.descVerify' : 'servers.off.descUpgrade'));
  }
})();
