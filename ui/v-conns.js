/* enana · v-conns.js — 连接页: 实时连接表 (按 主机+应用+线路 合并) · 筛选 / 排序 / 搜索 (记在 prefs) · 分页 (ui.pager) · 「详情」弹窗 (实时更新) · 「改走…」弹窗 (二次确认) · 断开
 *
 * 数据: S.conns (data.js 每秒从 Clash API 读取一次, 事件 'conns'); 一行 = 主机 + 应用 + 线路 + 出口 + 服务 相同的若干条连接合并起来。
 * 详情弹窗 (行内按钮 / 点整行): 一行里合并了多条连接时用 ‹ › 逐条查看; 弹窗打开期间每秒跟着 S.conns 更新 (只改变化的文字, 不重建 DOM, 选中的文字不会丢);
 *   连接消失后显示「已结束」并冻结数值, 「断开」按钮变成「不可用 + 原因」。
 * 分页: 实时数据只保持「页码」不变 (不会自己跳页); 分页条只在总数变化时重画, 鼠标 / 键盘正在分页条上时不重画 (否则会丢焦点)。
 * 列头排序 (ui.sorter 'conns'): 主机 / 应用 / 线路 / 服务 / 下载速度 / 累计下载 / 连接数 都能点列头排序 (升序 → 降序 → 恢复), 排的是整张表 (先排序再分页);
 *   排序和上面的「行顺序」共用同一套稳定机制 (最多每 3 秒重排一次, 鼠标 / 焦点在表格里时不重排), 所以按「速度」这类每秒在变的列排序时行也不会乱跳。
 *   列头排序生效时它优先于工具栏的排序下拉 (下拉显示同一列; 线路 / 服务在下拉里没有对应项, 临时显示列名); 在下拉里手选一项会取消列头排序。没点列头时一切照旧。
 * 偏好 (TP.prefs): conns.route (线路筛选) · conns.sort (排序下拉) · sort.conns (列头排序, ui.sorter); 表格每页条数 / 页码由 ui.pager 记在 table.conns.*。 */
(function () {
  'use strict';
  var TP = window.TP, S = TP.S, h = TP.h, ui = TP.ui, fmt = TP.fmt, setText = TP.setText, enc = TP.enc, I = window.I18N, t = I.t, L = I.L;
  var V = TP.V.conns = { id: 'conns' };
  var PK = { route: 'conns.route', sort: 'conns.sort' };                                                                     // i18n-ignore (偏好键, 不是词典键)
  var HT = { page: 'conns.page', monitor: 'conns.monitor', kill: 'conns.kill', route: 'conns.route', svc: 'conns.svc' };     // i18n-ignore (「!」说明的话题: 词典键是 help.<话题>.*)
  var el = {}, flt = { cls: '', q: '', sort: 'speed' }, pg = null;
  var rank = {}, rankAt = 0, hold = false, pgHold = false, force = true, pgTotal = -1;   // 行顺序: 最多每 3 秒重排一次; 鼠标 / 焦点在表格里时完全不重排, 避免点击时行跳走
  var CLS_NAME = { pin: 'conns.cls.pin', auto: 'conns.cls.auto', direct: 'conns.cls.direct' };
  var CLS = ['', 'pin', 'auto', 'direct'];
  var col = null, colLang = '';
  var so = null, soQuiet = false;                                          // 列头排序 (ui.sorter); soQuiet: 代码里取消列头排序时不要触发重画
  var SEL_OF = { host: 'host', app: 'app', speed: 'speed', total: 'total', n: 'count' };       // 列头 -> 排序下拉里的同一项
  var COL_NAME = { route: 'conns.col.route', svc: 'conns.col.svc' };                          // 下拉里没有的列: 临时显示列名

  function active() { return TP.tab === 'conns'; }
  function clsText(g) { return g.cls === 'direct' ? t('name.policy.direct') : TP.name.route(g.cls) + ' · ' + g.node; }
  function pickCls(v) { return CLS.indexOf(v) >= 0 ? v : ''; }
  function cmpText(a, b) {
    if (!col || colLang !== I.lang) { colLang = I.lang; try { col = new Intl.Collator(I.lang, { numeric: true, sensitivity: 'base' }); } catch (e) { col = { compare: function (x, y) { return x < y ? -1 : x > y ? 1 : 0; } }; } }
    return col.compare(String(a || ''), String(b || ''));
  }
  /* 排序: 速度 / 累计下载 / 连接数 / 主机名 / 应用 (没有应用信息的排在后面) */
  var SORT = {
    speed: function (a, b) { return b.sd - a.sd || b.dn - a.dn; },
    total: function (a, b) { return b.dn - a.dn || b.sd - a.sd; },
    count: function (a, b) { return b.n - a.n || b.sd - a.sd; },
    host: function (a, b) { return cmpText(a.host, b.host) || b.sd - a.sd; },
    app: function (a, b) { return (a.app ? 0 : 1) - (b.app ? 0 : 1) || cmpText(a.app, b.app) || cmpText(a.host, b.host); }
  };
  var SORTS = Object.keys(SORT);
  function pickSort(v) { return SORT[v] ? v : 'speed'; }
  function withHelp(node, topic) { return h('span', { class: 'cn-hp' }, node, ui.help(topic)); }
  function toTop(node) {                                                  // 翻页以后, 如果工具栏已经滚出了屏幕, 滚回来, 这样新的一页是从头开始看的
    var sc = TP.byId('scroll'), r, s;
    if (!sc || !node) return;
    r = node.getBoundingClientRect(); s = sc.getBoundingClientRect();
    if (r.top < s.top) sc.scrollTop += r.top - s.top - 8;
  }

  V.init = function (root) {
    flt.cls = pickCls(TP.prefs.get(PK.route, '')); flt.sort = pickSort(TP.prefs.get(PK.sort, 'speed'));
    pg = ui.pager('conns', { def: 20 });
    pg.onChange(function () { force = true; V.render(); toTop(el.bar); });
    so = ui.sorter('conns', {
      host: { get: function (g) { return g.host; } },
      app: { get: function (g) { return g.app; } },                                        // 没有应用信息的永远排在后面
      route: { get: function (g) { return clsText(g); } },
      svc: { get: function (g) { return g.svc ? TP.svcName(g.svc) : null; } },
      speed: { type: 'num', get: function (g) { return g.sd; } },
      total: { type: 'num', get: function (g) { return g.dn; } },
      n: { type: 'num', get: function (g) { return g.n; } }
    }, { onChange: function () { if (soQuiet) return; syncSort(); firstPage(); } });
    el.seg = ui.seg(L('conns.filter.aria'), [
      { v: '', label: L('conns.filter.all') }, { v: 'pin', label: L(CLS_NAME.pin), icon: 'pin' }, { v: 'auto', label: L(CLS_NAME.auto), icon: 'auto' }, { v: 'direct', label: L(CLS_NAME.direct), icon: 'direct' }],
      function (v) { setRoute(v, true); });
    el.seg.set(flt.cls);
    el.q = h('input', { class: 'inp', type: 'search', placeholder: L('conns.search'), 'aria-label': L('conns.search'), autocomplete: 'off', on: { input: function () { flt.q = el.q.value.trim().toLowerCase(); firstPage(); } } });
    el.sortX = h('option', { value: '~', hidden: true });                                  // 列头排序在「线路 / 服务」上时, 下拉临时显示它 (不出现在下拉列表里)
    el.sort = h('select', { class: 'sel cn-sort', 'aria-label': L('conns.sort.aria') }, SORTS.map(function (k) { return h('option', { value: k }, L('conns.sort.' + k)); }).concat([el.sortX]));
    syncSort();
    el.sort.addEventListener('change', function () { setSort(el.sort.value, true); });
    el.kill = TP.bindKillBtn(ui.btn(L('act.kill.label'), { icon: 'disconnect', cls: 'soft-bad' }));
    el.sum = h('div', { class: 'muted sm conn-sum', 'aria-live': 'off' });
    var resume = ui.btn(L('ov.resume'), { kind: 'primary', icon: 'play' }); ui.act(resume, function () { return TP.actions.setMonitor(true); });
    el.paused = h('section', { class: 'card paused-card', hidden: true },
      ui.icon('pause', 44, 'empty-ic'), h('h3', null, L('ov.paused.title')), h('p', { class: 'muted' }, L('conns.paused.text')), resume);
    el.tbody = h('tbody');
    el.empty = ui.emptyBox();
    el.card = h('section', { class: 'card flush' },
      h('div', { class: 'tbl-wrap' }, h('table', { class: 'tbl rt conn-tbl' },
        h('thead', null, h('tr', null, [['host', 'conns.col.host'], ['app', 'conns.col.app'], ['route', 'conns.col.route'], ['svc', 'conns.col.svc'], ['speed', 'conns.col.speed'], ['total', 'conns.col.total'], ['n', 'conns.col.n']].map(function (c) {
          var th = so.th(c[0], function () { return t(c[1]); });                         // 数据列: 点列头排序
          if (c[0] === 'svc') th.appendChild(ui.help(HT.svc, { size: 14 }));
          return th;
        }).concat([h('th', { scope: 'col', class: 'c-act' }, L('conns.col.act'))]))),   // 操作列不排序
        el.tbody)),
      el.empty.el, pg.el);
    el.bar = h('div', { class: 'toolbar cn-bar' }, withHelp(el.seg.el, HT.route), el.q, el.sort, withHelp(el.kill, HT.kill), withHelp(TP.monitorSwitch(), HT.monitor));
    el.main = h('div', null, el.bar, el.sum, el.card);
    root.appendChild(h('div', { class: 'intro' }, h('p', { class: 'muted' }, L('conns.intro'), ' ', ui.help(HT.page))));
    root.appendChild(el.paused); root.appendChild(el.main);
    var setHold = function (b) { hold = b; if (!b) V.render(); };
    el.tbody.addEventListener('mouseenter', function () { setHold(true); });
    el.tbody.addEventListener('mouseleave', function () { setHold(false); });
    el.tbody.addEventListener('focusin', function () { hold = true; });
    el.tbody.addEventListener('focusout', function () { setHold(false); });
    var pgOn = function (b, ev) { if (!b && ev && ev.relatedTarget && pg.el.contains(ev.relatedTarget)) return; pgHold = b; if (!b) V.render(); };       // 分页条在被使用时不重画
    pg.el.addEventListener('mouseenter', function (ev) { pgOn(true, ev); }); pg.el.addEventListener('mouseleave', function (ev) { pgOn(false, ev); });
    pg.el.addEventListener('focusin', function (ev) { pgOn(true, ev); }); pg.el.addEventListener('focusout', function (ev) { pgOn(false, ev); });
    /* 点整行 = 打开详情 (按钮 / 链接 / 输入框自己处理; 正在选中文字时不打开) */
    el.tbody.addEventListener('click', function (ev) {
      var tr = ev.target.closest ? ev.target.closest('tr') : null, sel = window.getSelection ? window.getSelection() : null;
      if (!tr || !tr._g || ev.target.closest('button,a,input,select,textarea,label')) return;
      if (sel && !sel.isCollapsed && String(sel).length && tr.contains(sel.anchorNode)) return;
      openDetails(tr._g);
    });
    TP.on('conns', function () { if (active()) V.render(); if (dt) dt.sync(); });
    TP.on('monitor', function () { if (active()) V.render(); if (dt) dt.sync(); });
    TP.on('helper', function () { if (active()) V.render(); });
    TP.on('clash', function () { if (active()) V.render(); if (dt) dt.sync(); });
    TP.on('lang', function () { force = true; syncSort(); V.render(); if (dt) dt.paint(); });
    TP.on('prefs', function (d) {                                                              // 别的设备同步过来 / 登录后读到本机的偏好
      if (!d || !(d.all || d.key === PK.route || d.key === PK.sort)) return;
      var r = pickCls(TP.prefs.get(PK.route, '')), s = pickSort(TP.prefs.get(PK.sort, 'speed'));
      if (r === flt.cls && s === flt.sort) return;
      flt.cls = r; flt.sort = s; el.seg.set(r); syncSort(); force = true; V.render();
    });
    V.render();
  };
  V.show = function () { V.render(); };

  function firstPage() { force = true; if (pg.page() !== 1) pg.setPage(1); else V.render(); }       // 用户改了筛选 / 排序 / 搜索: 回到第 1 页 (实时刷新时绝不自己翻页)
  function setRoute(v, save) { flt.cls = pickCls(v); el.seg.set(flt.cls); if (save) TP.prefs.set(PK.route, flt.cls || undefined); firstPage(); }
  function setSort(v, save) {
    flt.sort = pickSort(v);
    if (save) TP.prefs.set(PK.sort, flt.sort === 'speed' ? undefined : flt.sort);
    if (so.state()) { soQuiet = true; try { so.set('', 'asc'); } finally { soQuiet = false; } }       // 手选了排序下拉: 列头排序让位 (回到按下拉排序)
    syncSort(); firstPage();
  }
  /* 排序下拉跟列头的状态保持一致: 列头排序生效时显示同一列 (下拉里没有的列用临时的隐藏项显示列名), 否则显示下拉自己的排序 */
  function syncSort() {
    if (!so || !el.sort) return;
    var s = so.state(), v = flt.sort;
    if (s) { v = SEL_OF[s.key] || '~'; if (v === '~') setText(el.sortX, t(COL_NAME[s.key] || 'conns.col.host')); }
    el.sort.value = v;
  }
  /* 当前页的范围: 数据已经读到 (ready) 并且总数变了才更新分页条 (每次更新它都会重建按钮, 键盘焦点会丢; 数据还没读到时更新会把记住的页码钳制成第 1 页);
   * 分页条正在被使用 (鼠标在上面 / 焦点在里面) 时只在本地钳制页码, 等用完再同步 */
  function pageOf(total, ready) {
    var size = pg.size(), page = pg.page(), pages = Math.max(1, Math.ceil(total / size));
    if (pgHold && !pg.el.matches(':hover') && !pg.el.contains(document.activeElement)) pgHold = false;        // 防止「占用」状态卡住 (焦点所在的按钮被移除时不一定有 focusout)
    if (ready && !pgHold && total !== pgTotal) { pgTotal = total; return pg.update(total); }
    if (page > pages) page = pages;
    return { start: (page - 1) * size, end: Math.min(total, page * size) };
  }

  function aggregate(rows) {
    var map = new Map(), out = [];
    rows.forEach(function (r) {
      var m = r.c.metadata || {}, host = m.host || m.destinationIP || '?', app = TP.appName(m.processPath);
      var key = host + '\u0000' + app + '\u0000' + r.rt.cls + '\u0000' + r.rt.node + '\u0000' + r.rt.svc;
      var g = map.get(key);
      if (!g) { g = { key: key, host: host, app: app, cls: r.rt.cls, node: r.rt.node, svc: r.rt.svc, sd: 0, su: 0, dn: 0, up: 0, n: 0, ids: [], port: m.destinationPort, net: m.network, rule: r.c.rule || '' }; map.set(key, g); out.push(g); }
      g.sd += r.sd; g.su += r.su; g.dn += r.dn; g.up += r.up; g.n++; g.ids.push(r.c.id);
    });
    return out;
  }

  V.render = function () {
    var on = S.monitor;
    el.paused.hidden = on; el.main.hidden = !on;
    if (!on) return;
    var groups = aggregate(S.conns), total = groups.length, q = flt.q, cmp = SORT[flt.sort];
    var all = S.conns.length, sd = 0, su = 0, pr, rows;
    S.conns.forEach(function (r) { sd += r.sd; su += r.su; });
    var list = groups.filter(function (g) {
      if (flt.cls && g.cls !== flt.cls) return false;
      if (!q) return true;
      return g.host.toLowerCase().indexOf(q) >= 0 || g.app.toLowerCase().indexOf(q) >= 0 || g.node.toLowerCase().indexOf(q) >= 0 || (g.svc && TP.svcName(g.svc).toLowerCase().indexOf(q) >= 0);
    });
    var now = Date.now();
    if (hold && !el.tbody.matches(':hover') && !el.tbody.contains(document.activeElement)) hold = false;     // 防止「占用」状态卡住
    if (!hold && (force || now - rankAt >= 3000)) {
      list.sort(cmp);                                                     // 先按下拉的排序排好 (也是列头排序里相同值的先后顺序), 再按列头排 (稳定); 排的是整张表, 分页在后面
      if (so.state()) list = so.apply(list);
      rank = {}; list.forEach(function (g, i) { rank[g.key] = i; }); rankAt = now; force = false;
    } else {
      list.sort(function (a, b) { var ra = rank[a.key], rb = rank[b.key]; return (ra == null ? 1e9 : ra) - (rb == null ? 1e9 : rb) || cmp(a, b); });
    }
    pr = pageOf(list.length, S.speedAt > 0); rows = list.slice(pr.start, pr.end);
    ui.syncList(el.tbody, rows, function (g) { return g.key; }, make, update);
    setText(el.sum, S.speedAt ? t('conns.sum', { all: all, n: total, down: fmt.rate(sd), up: fmt.rate(su) }) + (S.connTotals ? ' · ' + t('conns.sumTotal', { down: fmt.bytes(S.connTotals.down), up: fmt.bytes(S.connTotals.up) }) : '') : t('conns.reading'));
    if (!S.speedAt && !all) {
      if (S.clash === 'down') el.empty.show({ icon: 'plug', text: t('conns.empty.down'), hint: TP.why.clash() });
      else el.empty.show({ icon: 'refresh', text: t('conns.reading') });
    } else if (!list.length) el.empty.show(all ? { icon: 'search', text: t('conns.empty.noMatch'), hint: t('conns.empty.noMatchHint') } : { icon: 'activity', text: t('conns.empty.none'), hint: t('conns.empty.noneHint') });
    else el.empty.hide();
  };

  function td(labelKey, cls) { var kids = Array.prototype.slice.call(arguments, 2); return h.apply(null, ['td', { 'data-l': labelKey ? L(labelKey) : '', class: cls || '' }].concat(kids)); }
  function make() {
    var r = {};
    r.host = h('span', { class: 'conn-h' }); r.app = h('span'); r.route = h('span', { class: 'badge' }); r.svc = h('span', { class: 'chip' });
    r.sd = h('span', { class: 'mono' }); r.dn = h('span', { class: 'mono' }); r.n = h('span');
    r.det = ui.ibtn('eye', t('conns.dt.open')); r.btn = ui.ibtn('edit', t('conns.reroute'));
    var tr = h('tr', { class: 'cn-row' }, td('', 'c-host', r.host), td('conns.col.app', '', r.app), td('conns.col.route', '', r.route), td('conns.col.svc', '', r.svc),
      td('conns.col.speed', 'num', r.sd), td('conns.col.total', 'num', r.dn), td('conns.col.n', 'num', r.n), td('', 'c-act', h('div', { class: 'acts' }, r.det, r.btn)));
    tr._r = r;
    ui.act(r.det, function () { return openDetails(tr._g); });
    ui.act(r.btn, function () { return reroute(tr._g); });
    return tr;
  }
  function update(tr, g) {
    var r = tr._r; tr._g = g;
    setText(r.host, g.host); r.host.title = g.host + (g.port ? ':' + g.port : '') + (g.net ? ' (' + g.net + ')' : '') + (g.rule ? '\n' + t('conns.rule', { rule: g.rule }) : '');
    setText(r.app, g.app || '—');
    TP.clear(r.route); r.route.appendChild(ui.icon(TP.POLICY_ICON[g.cls] || 'direct', 12, 'ci')); r.route.appendChild(document.createTextNode(' ' + clsText(g))); TP.setCls(r.route, 'badge r-' + g.cls);
    setText(r.svc, g.svc ? TP.svcName(g.svc) : ''); r.svc.hidden = !g.svc; r.svc.title = r.svc.textContent;
    setText(r.sd, g.sd > 0 ? fmt.rate(g.sd) : '—'); setText(r.dn, fmt.bytes(g.dn)); setText(r.n, g.n);
    var lab = t('conns.rerouteAria', { host: g.host }), lab2 = t('conns.dt.openAria', { host: g.host });
    r.btn.setAttribute('aria-label', lab); r.btn._tip = lab; if (!r.btn._un) r.btn.title = lab;
    r.det.setAttribute('aria-label', lab2); r.det._tip = lab2; if (!r.det._un) r.det.title = lab2;
  }

  /* ================= 详情弹窗 =================
   * 一行可能合并了多条连接: 弹窗里一次显示一条, 多条时用 ‹ › (或方向键) 切换。每条连接在弹窗里保留「最后一次看到的数据」: 消失后标记「已结束」, 数值和持续时间不再变化。 */
  var dt = null;                                                       // 当前打开的详情弹窗 {sync, paint} (同一时间最多一个)
  function chainLabel(tag) {
    if (tag === 'direct') return t('name.policy.direct');
    if (tag === 'PIN') return t('name.policy.PIN');
    if (tag === 'Global') return t('name.policy.Global');
    if (tag === 'Final') return t('conns.dt.final');
    if (/^svc-/.test(tag)) return TP.svcName(tag);
    return tag;
  }
  function addr(ip, port) {
    ip = String(ip || ''); if (!ip) return '';
    if (ip.indexOf(':') >= 0 && ip.charAt(0) !== '[') ip = '[' + ip + ']';                  // IPv6
    return port ? ip + ':' + port : ip;
  }
  function pad2(n) { return n < 10 ? '0' + n : String(n); }
  function dur(ms) {
    var s = Math.max(0, Math.floor(ms / 1000)), d = Math.floor(s / 86400), tm = pad2(Math.floor(s % 86400 / 3600)) + ':' + pad2(Math.floor(s % 3600 / 60)) + ':' + pad2(s % 60);
    return d ? t('conns.dt.durD', { d: d, time: tm }) : tm;
  }

  function openDetails(g) {
    var byId = {}, last = {}, endedAt = {}, killed = {}, ids = [], idx = 0, key = g.key, f = {}, api, body;
    S.conns.forEach(function (r) { byId[r.c.id] = r; });
    g.ids.forEach(function (id) { if (byId[id]) { ids.push(id); last[id] = byId[id]; } });
    if (!ids.length) { ui.toast(t('conns.dt.endedWhy'), 'warn'); return; }
    function row(labelKey, node, cls) { return h('div', { class: 'cn-r' + (cls ? ' ' + cls : '') }, h('dt', null, L(labelKey)), h('dd', null, node)); }
    function val(cls) { return h('span', { class: 'cn-v' + (cls ? ' ' + cls : '') }); }
    f.stOk = ui.badge(L('conns.dt.active'), 'ok', 'success'); f.stEnd = ui.badge(L('conns.dt.ended'), 'neutral', 'stop'); f.stEnd.hidden = true;
    f.pos = h('span', { class: 'cn-pos sm', 'aria-live': 'polite' });
    f.prev = ui.ibtn('chevron-left', L('conns.dt.prev')); f.next = ui.ibtn('chevron-right', L('conns.dt.next'));
    f.prev.addEventListener('click', function () { if (f.prev._un) ui.unavailable(f.prev); else step(-1); });
    f.next.addEventListener('click', function () { if (f.next._un) ui.unavailable(f.next); else step(1); });
    f.nav = h('span', { class: 'cn-nav' }, f.prev, f.pos, f.next);
    f.note = h('p', { class: 'hint warn cn-note', role: 'status', hidden: true });
    f.host = val('mono cn-host'); f.dest = val('mono'); f.src = val('mono'); f.net = val('mono'); f.app = val(); f.path = val('mono');
    f.route = h('span', { class: 'badge' }); f.chain = h('div', { class: 'cn-chain' });
    f.rule = val('mono'); f.payload = val('mono'); f.start = val(); f.dur = val('mono');
    f.down = h('b', { class: 'cn-b' }); f.downX = h('span', { class: 'muted sm cn-x' }); f.up = h('b', { class: 'cn-b' }); f.upX = h('span', { class: 'muted sm cn-x' });
    body = h('div', { class: 'cn-dt' },
      h('div', { class: 'cn-top' }, f.stOk, f.stEnd, f.nav), f.note,
      h('dl', { class: 'cn-kv' },
        row('conns.dt.f.host', f.host), row('conns.dt.f.dest', f.dest), row('conns.dt.f.src', f.src), row('conns.dt.f.net', f.net),
        row('conns.dt.f.app', f.app), row('conns.dt.f.path', f.path),
        row('conns.dt.f.route', f.route), row('conns.dt.f.chain', f.chain), row('conns.dt.f.rule', f.rule), row('conns.dt.f.payload', f.payload),
        row('conns.dt.f.start', f.start), row('conns.dt.f.dur', f.dur),
        row('conns.dt.f.down', h('span', { class: 'cn-bv' }, f.down, f.downX)), row('conns.dt.f.up', h('span', { class: 'cn-bv' }, f.up, f.upX))));

    function cur() { return ids[idx]; }
    function aliveIds() { return ids.filter(function (id) { return !endedAt[id]; }); }
    function step(d) { idx = Math.max(0, Math.min(ids.length - 1, idx + d)); paint(); }
    function exact(n) { return t('conns.dt.exact', { n: n, num: fmt.num(n) }); }
    function paint() {
      var id = cur(), r = last[id], c = r.c, m = c.metadata || {}, gone = !!endedAt[id], start = Date.parse(c.start), end = gone ? endedAt[id] : Date.now(), chain = (c.chains || []).slice();
      var host = m.host || '', app = TP.appName(m.processPath), net = [m.network ? String(m.network).toUpperCase() : '', m.type ? String(m.type) : ''].filter(Boolean).join(' · ');
      api.setTitle(t('conns.dt.title'));
      f.stOk.hidden = gone; f.stEnd.hidden = !gone;
      setText(f.pos, t('conns.dt.pos', { i: idx + 1, n: ids.length })); f.nav.hidden = ids.length < 2;
      ui.avail(f.prev, idx > 0 ? '' : t('conns.dt.first')); ui.avail(f.next, idx < ids.length - 1 ? '' : t('conns.dt.last'));
      f.note.hidden = S.monitor && S.clash !== 'down'; setText(f.note, !S.monitor ? t('conns.dt.pausedNote') : S.clash === 'down' ? t('conns.dt.downNote') : '');
      setText(f.host, host || '—'); setText(f.dest, addr(m.destinationIP, m.destinationPort) || '—'); setText(f.src, addr(m.sourceIP, m.sourcePort) || '—'); setText(f.net, net || '—');
      setText(f.app, app || '—'); setText(f.path, m.processPath || '—');
      ui.memo(f.route, rt2sig(r.rt), function () {
        var fr = document.createDocumentFragment(); fr.appendChild(ui.icon(TP.POLICY_ICON[r.rt.cls] || 'direct', 12, 'ci')); fr.appendChild(document.createTextNode(' ' + clsText({ cls: r.rt.cls, node: r.rt.node })));
        TP.setCls(f.route, 'badge r-' + r.rt.cls); return fr;
      });
      ui.memo(f.chain, chain.join('\u0001'), function () {
        var fr = document.createDocumentFragment();
        if (!chain.length) { fr.appendChild(document.createTextNode('—')); return fr; }
        chain.forEach(function (tag, i) {
          if (i) fr.appendChild(ui.icon('arrow-right', 12, 'cn-ar'));
          fr.appendChild(h('span', { class: 'chip cn-ch', title: tag }, chainLabel(tag)));
        });
        return fr;
      });
      setText(f.rule, c.rule || '—'); setText(f.payload, c.rulePayload || '—');
      setText(f.start, isNaN(start) ? '—' : fmt.dateTime(start)); setText(f.dur, isNaN(start) ? '—' : dur(end - start));
      setText(f.down, fmt.bytes(r.dn)); setText(f.downX, exact(r.dn) + (gone || !(r.sd > 0) ? '' : ' · ' + t('conns.dt.now', { speed: fmt.rate(r.sd) })));
      setText(f.up, fmt.bytes(r.up)); setText(f.upX, exact(r.up) + (gone || !(r.su > 0) ? '' : ' · ' + t('conns.dt.now', { speed: fmt.rate(r.su) })));
      /* 按钮 */
      var kb = api.getBtn('kill'), ka = api.getBtn('killall'), cb = api.getBtn('copy'), n = aliveIds().length;
      ui.setBtn(cb, t('conns.dt.copyHost')); ui.setBtn(kb, t('conns.dt.kill')); ui.avail(kb, gone ? t('conns.dt.endedWhy') : '');
      ka.hidden = n < 2; ui.setBtn(ka, t('conns.dt.killAll', { n: n }));
    }
    function rt2sig(rt) { return rt.cls + '|' + rt.node; }
    /* 跟着 S.conns 更新: 新连接 (同一行) 加进来; 消失的标记「已结束」。监控暂停 / 核心不可用时 S.conns 不再更新, 不能据此判断「已结束」 */
    function sync() {
      var map = {}, now = Date.now();
      if (S.monitor && S.clash !== 'down') {
        S.conns.forEach(function (r) { map[r.c.id] = r; });
        aggregate(S.conns).some(function (x) { if (x.key !== key) return false; x.ids.forEach(function (id) { if (ids.indexOf(id) < 0) ids.push(id); }); return true; });
        ids.forEach(function (id) { if (map[id] && !killed[id]) { last[id] = map[id]; delete endedAt[id]; } else if (!endedAt[id] && last[id]) endedAt[id] = now; });
      }
      paint();
    }
    /* 断开 (一条或这一行里还活着的全部): 确认 -> DELETE /connections/<id> */
    async function kill(list) {
      list = list.filter(function (id) { return !endedAt[id]; });
      if (!list.length) { ui.toast(t('conns.dt.endedWhy'), 'warn'); return false; }
      var n = list.length, host = last[list[0]].c.metadata && last[list[0]].c.metadata.host || g.host;
      var ok = await ui.confirmDialog({
        title: t(n > 1 ? 'conns.dt.killAllTitle' : 'conns.dt.killTitle'), message: t(n > 1 ? 'conns.dt.killAllMsg' : 'conns.dt.killMsg', { host: host, n: n }),
        detail: [t('conns.dt.killD1'), t('conns.dt.killD2')], confirmText: t(n > 1 ? 'conns.dt.killAllGo' : 'conns.dt.killGo', { n: n }), kind: 'warning', confirmIcon: 'disconnect'
      });
      if (!ok) return false;
      await Promise.all(list.map(function (id) { return TP.clash('DELETE', '/connections/' + enc(id)); }));
      TP.audit('kill', { scope: n > 1 ? 'host' : 'one', n: n, host: host });
      var now = Date.now(); list.forEach(function (id) { endedAt[id] = now; killed[id] = true; });                  // 已经断开的不再因为核心还没清掉它而「复活」
      ui.toast(t('conns.dt.killed', { n: n }), 'ok'); paint();
      if (TP.pollers.conns) setTimeout(TP.pollers.conns.kick, 300);
      return false;
    }
    api = ui.modal({
      title: t('conns.dt.title'), icon: 'activity', iconKind: 'info', size: 'md', body: body,
      actions: [
        { label: t('conns.dt.copyHost'), icon: 'copy', id: 'copy', keep: true, onClick: function () {
          var r = last[cur()], m = r.c.metadata || {}; ui.copy(m.host || m.destinationIP || g.host);
          return false;
        } },
        { label: t('conns.dt.kill'), icon: 'disconnect', cls: 'soft-warn', id: 'kill', keep: true, onClick: function () { return kill([cur()]); } },
        { label: t('conns.dt.killAll', { n: ids.length }), icon: 'disconnect', cls: 'soft-warn', id: 'killall', keep: true, onClick: function () { return kill(ids); } },
        { label: t('common.close'), kind: 'primary', cancel: true }
      ],
      onClose: function () { dt = null; }
    });
    api.el.addEventListener('keydown', function (ev) {                    // ← → 切换同一行里的连接 (在输入框 / 下拉框里不抢方向键)
      if ((ev.key !== 'ArrowLeft' && ev.key !== 'ArrowRight') || ids.length < 2 || /^(INPUT|TEXTAREA|SELECT)$/.test(ev.target.tagName)) return;
      ev.preventDefault(); step(ev.key === 'ArrowLeft' ? -1 : 1);
    });
    dt = { sync: sync, paint: paint };
    paint();
  }

  /* ---------- 改走… (弹窗; 确定前再确认一次) ---------- */
  function reroute(g) {
    var host = TP.V.sites.parseHost(g.host), hasSite = !!host.host, hasApp = !!g.app;
    var target = hasSite ? 'site' : 'app';
    if (!hasSite && !hasApp) { ui.toast(t('conns.rr.noTarget'), 'warn'); return; }
    var tgtBox = h('div', { class: 'radios', role: 'radiogroup', 'aria-label': t('conns.rr.targetAria') }), stBox = h('div', { class: 'radios', role: 'radiogroup', 'aria-label': t('conns.rr.toAria') });
    var kill = h('input', { type: 'checkbox' }); kill.checked = true;
    var state = g.cls === 'direct' ? 'pin' : 'direct';
    function radio(box, name, val, label, checked, dis, hint) {
      var inp = h('input', { type: 'radio', name: name, value: val });
      inp.checked = checked;
      if (dis) { inp.setAttribute('aria-disabled', 'true'); inp.addEventListener('click', function (ev) { ev.preventDefault(); ui.toast(hint || label, 'warn'); }); }
      box.appendChild(h('label', { class: 'radio' + (dis ? ' off' : ''), title: dis && hint ? hint : null }, inp, h('span', null, label, hint && !dis ? h('span', { class: 'muted sm' }, ' ' + hint) : null, dis && hint ? h('span', { class: 'muted sm' }, ' (' + hint + ')') : null)));
      return inp;
    }
    var stInputs = {};
    function drawStates() {
      TP.clear(stBox); stInputs = {};
      var opts = ['pin', 'auto', 'direct'];
      if (target === 'app') opts.push('follow');
      if (opts.indexOf(state) < 0) state = 'direct';
      opts.forEach(function (o) {
        var i = radio(stBox, 'st', o, TP.name.app(o), o === state, false);
        i.addEventListener('change', function () { state = o; });
        stInputs[o] = i;
      });
    }
    var rSite = radio(tgtBox, 'tg', 'site', t('conns.rr.site', { host: host.host || g.host }), target === 'site', !hasSite, hasSite ? '' : t('conns.rr.ipNoSite'));
    var rApp = radio(tgtBox, 'tg', 'app', t('conns.rr.app', { app: g.app || '—' }), target === 'app', !hasApp, hasApp ? t('conns.rr.appHint') : t('conns.rr.noApp'));
    rSite.addEventListener('change', function () { target = 'site'; drawStates(); });
    rApp.addEventListener('change', function () { target = 'app'; drawStates(); });
    drawStates();
    var body = h('div', { class: 'reroute' },
      h('p', { class: 'dlg-p' }, t('conns.rr.current', { now: clsText(g) })),
      h('div', { class: 'fld-l' }, t('conns.rr.target')), tgtBox,
      h('div', { class: 'fld-l' }, t('conns.rr.to')), stBox,
      h('label', { class: 'chk-inline' }, kill, h('span', null, t('conns.rr.kill', { n: g.n }))),
      h('p', { class: 'muted sm' }, t('conns.rr.note')));
    var why = TP.why.helper();
    ui.modal({
      title: t('conns.rr.title'), icon: 'edit', iconKind: 'pri', size: 'sm', body: body,
      actions: [
        { label: t('common.cancel'), cancel: true },
        { label: t('conns.rr.killOnly'), icon: 'disconnect', cls: 'soft-warn', keep: true, onClick: async function (api) {
          var okk = await ui.confirmDialog({ title: t('conns.dt.killAllTitle'), message: t('conns.rr.killOnlyMsg', { host: g.host, n: g.n }), detail: t('conns.dt.killD1'), confirmText: t('conns.rr.killOnly'), kind: 'warning', confirmIcon: 'disconnect' });
          if (!okk) return false;
          await killIds(g.ids, g.host); ui.toast(t('conns.rr.killed', { n: g.n }), 'ok'); api.close('kill'); return false;
        } },
        { label: t('common.ok'), kind: 'primary', icon: 'check', keep: true, unavail: why ? { reason: why } : null, onClick: async function (api) {
          var value = target === 'site' ? host.host : g.app, what = target === 'site' ? value : t('conns.rr.appName', { app: value });
          var tx = TP.txt.app(what, null, state);
          var okc = await ui.confirmDialog({
            title: t('conns.rr.confirmTitle'), message: t('conns.rr.confirmMsg', { what: what, state: TP.name.app(state) }),
            detail: [tx.detail, kill.checked ? t('conns.rr.confirmKill', { n: g.n }) : ''].filter(Boolean), confirmText: t('conns.rr.confirmGo'), rememberKey: 'policy'
          });
          if (!okc) return false;
          await TP.override(target, value, state);
          if (kill.checked) await killIds(g.ids, g.host);
          api.close('ok');
          ui.toast(t('conns.rr.done', { what: what, state: TP.name.app(state) }), 'ok');
          if (target === 'site') TP.loadState(); else TP.loadApps(false);
          return false;
        } }
      ]
    });
  }
  function killIds(ids, host) {
    return Promise.all(ids.map(function (id) { return TP.clash('DELETE', '/connections/' + enc(id)).catch(function () { }); })).then(function (r) { TP.audit('kill', { scope: 'host', n: ids.length, host: host }); return r; });
  }
})();
