/* enana · v-sites.js — 网站页: 目录 (schema 3) 里的每一项一个三段开关 (固定出口 | 自动线路 | 直连) + 搜索/分组筛选 + 折叠分组 + 自定义网站
 * 每次改策略都先经过 confirmDialog; 当前没有固定出口 / 自动线路时, 对应选项显示为「暂不可用」, 点击会说明原因并提供「添加服务器」。
 * 每一项的域名列表用弹窗查看 / 添加 / 修改 / 删除 / 恢复, 并可一键重置为系统默认 (GET|POST /api/sites/domains, POST /api/sites/domains/reset; 写操作是后台任务)。
 * 页面里没有行内展开: 说明用「!」(ui.help), 长列表用 ui.pager, 折叠的分组记在 prefs (sites.collapsed)。 */
(function () {
  'use strict';
  var TP = window.TP, S = TP.S, h = TP.h, ui = TP.ui, setText = TP.setText, I = window.I18N, t = I.t, L = I.L;
  var V = TP.V.sites = { id: 'sites' };
  var el = {}, boxes = {}, flt = { q: '', g: '' }, chips = {}, pgC = null, pgD = null, dm = null, uid = 0;
  var OPTS = [
    { v: 'PIN', label: L('name.policy.PIN'), icon: 'pin' },
    { v: 'Global', label: L('name.policy.Global'), icon: 'auto' },
    { v: 'direct', label: L('name.policy.direct'), icon: 'direct' }
  ];
  var DEF = { pin: 'PIN', auto: 'Global', direct: 'direct' };
  var GICON = { ai: 'ai', account: 'user', exchange: 'badge-check', social: 'message-square-warning', video: 'play', search: 'search', news: 'book-open', dev: 'terminal', shop: 'plug', tools: 'sliders-horizontal', direct: 'direct' };
  var ROUTE = { pin: 'pin', PIN: 'pin', auto: 'auto', Global: 'auto', direct: 'direct', Direct: 'direct' };     // 后端的策略名 / Clash 选择器名 -> 路由类别
  var PREF_COLLAPSED = 'sites.collapsed';       // i18n-ignore
  var PG_CUSTOM = 'sites.custom';               // i18n-ignore
  var PG_DOMAINS = 'sites.domains';             // i18n-ignore

  function active() { return TP.tab === 'sites'; }
  function catalog() { return S.catalog || { groups: {}, groups_en: {}, order: [], entries: [], failed: false }; }
  function eName(e) { return e.id === 'final' ? t('sites.final.name') : (I.pick(e, 'name') || e.id); }
  function addFix() { return { label: t('why.addServer'), fn: function () { TP.goAdd('manual'); } }; }
  function help(name) { return ui.help('sites.' + name); }                           // 「!」说明: 词典键 help.sites.<name>.*
  function isTouch() { try { return !!(window.matchMedia && window.matchMedia('(pointer:coarse)').matches); } catch (e) { return false; } }

  /* 折叠的分组: prefs 里存「被折叠的分组 id 数组」; 还没存过时, 前两个分组展开、其余折叠 (和以前一样) */
  function collapsedList() { var c = TP.prefs.get(PREF_COLLAPSED, null); return Array.isArray(c) ? c : catalog().order.slice(2); }
  function isOpen(g) { return !!(flt.q || flt.g) || collapsedList().indexOf(g) < 0; }
  function toggleGroup(g) {
    var c = collapsedList().slice(), i = c.indexOf(g);
    if (i >= 0) c.splice(i, 1); else c.push(g);
    TP.prefs.set(PREF_COLLAPSED, c);                                                // 触发 'prefs' 事件 -> 重新渲染
  }

  /* ================= 构建 ================= */
  V.init = function (root) {
    /* 规则如何生效: 一行标题 + 「!」, 4 步流程在说明弹窗里 */
    var how = h('div', { class: 'sx-how' }, h('b', null, L('sites.how.title')), h('span', { class: 'muted sm' }, L('sites.how.sub')), help('how'));

    /* 工具栏 + 筛选条 */
    el.q = h('input', { class: 'inp', type: 'search', placeholder: L('sites.search'), 'aria-label': L('sites.search'), autocomplete: 'off', on: { input: function () { flt.q = el.q.value.trim().toLowerCase(); V.render(); } } });
    el.addBtn = ui.btn(L('sites.add'), { kind: 'primary', icon: 'plus' });
    ui.act(el.addBtn, function () { return openAddSite(); });
    el.count = h('span', { class: 'muted sm' });
    el.chips = h('div', { class: 'chips', role: 'group', 'aria-label': L('sites.groups') });

    /* 出口类型图例: 三种策略各一个「!」 */
    function lg(v, icon, nameKey) { return h('span', { class: 'sx-lg sx-lg-' + v }, ui.icon(icon, 15, 'ci'), h('span', null, L(nameKey)), help(v)); }
    el.legend = h('div', { class: 'sx-legend', role: 'group', 'aria-label': L('sites.legend') },
      h('span', { class: 'muted sm' }, L('sites.legend')), lg('pin', 'pin', 'name.policy.PIN'), lg('auto', 'auto', 'name.policy.Global'), lg('direct', 'direct', 'name.policy.direct'));

    /* 自定义网站 (你的覆盖) */
    el.cList = h('div', { class: 'rows' });
    el.cEmpty = ui.emptyBox();
    el.cCnt = h('span', { class: 'muted sm' });
    pgC = ui.pager(PG_CUSTOM, { def: 10 });
    pgC.onChange(renderCustom);
    var customCard = h('section', { class: 'card sx-pgcard' },
      h('div', { class: 'card-h' }, h('h3', null, L('sites.custom.title'), help('custom')), el.cCnt, h('span', { class: 'muted sm' }, L('sites.custom.sub'))),
      el.cList, el.cEmpty.el, pgC.el);

    /* 默认出口 */
    el.final = h('div', { class: 'rows' });
    var finalCard = h('section', { class: 'card' }, h('div', { class: 'card-h' }, h('h3', null, L('sites.final.title'), help('final')), h('span', { class: 'muted sm' }, L('sites.final.sub'))), el.final);

    el.groups = h('div', { class: 'grps' });
    el.empty = ui.emptyBox();

    root.appendChild(h('div', { class: 'intro' }, h('p', { class: 'muted' }, L('sites.intro'), help('page'))));
    root.appendChild(TP.proxyNote());
    root.appendChild(how);
    root.appendChild(h('div', { class: 'toolbar' }, el.q, el.addBtn, el.count));
    root.appendChild(el.chips);
    root.appendChild(el.legend);
    root.appendChild(customCard);
    root.appendChild(finalCard);
    root.appendChild(el.groups);
    root.appendChild(el.empty.el);

    TP.on('catalog', function () { buildGroups(); if (active()) V.render(); });
    TP.on('proxies', function () { if (active()) renderRows(); });
    TP.on('state', function () { if (active()) renderCustom(); });
    TP.on('helper', function () { if (active()) V.render(); if (dm) dm.paint(); });
    TP.on('lang', function () { V.render(); if (dm) dm.paint(); });
    TP.on('prefs', function (d) { if (active() && d && (d.all || d.key === PREF_COLLAPSED)) renderRows(); });
    buildFinal(); buildGroups(); V.render();
  };
  V.show = function () { V.render(); };
  V.render = function () { renderChips(); renderRows(); renderCustom(); };

  /* ---------- 分组 ---------- */
  function buildGroups() {
    var cat = catalog(), sig = cat.order.join('|');
    if (el.groups._sig === sig && Object.keys(boxes).length) return;                 // 分组没变: 复用现有 DOM (保住焦点和滚动位置)
    el.groups._sig = sig;
    TP.clear(el.groups); boxes = {};
    cat.order.forEach(function (g) {
      var rows = h('div', { class: 'rows grp-rows' }), name = h('span', { class: 'grp-n' }), cnt = h('span', { class: 'chip' });
      var head = h('button', { class: 'grp-h', type: 'button', 'aria-expanded': 'true' }, ui.icon(GICON[g] || 'globe', 18, 'grp-ic'), name, cnt);
      /* 「!」不能放进按钮里 (按钮里不能再嵌按钮): 标题按钮 + 「!」+ 一个把整行撑满的展开按钮 (只给鼠标 / 触屏用, 键盘用标题按钮) */
      var more = h('button', { class: 'sx-gx', type: 'button', tabindex: '-1', 'aria-hidden': 'true' }, ui.icon('chevron-down', 18, 'grp-chev'));
      var sec = h('section', { class: 'card grp' }, h('div', { class: 'sx-gh' }, head, I.has('help.sites.g.' + g + '.title') ? help('g.' + g) : null, more), rows);
      head.addEventListener('click', function () { toggleGroup(g); });
      more.addEventListener('click', function () { toggleGroup(g); });
      sec._name = name; sec._cnt = cnt; sec._rows = rows; sec._head = head; sec._g = g;
      boxes[g] = sec; el.groups.appendChild(sec);
    });
  }
  function entryBlob(e) {
    if (!e._blob || e._blobLang !== I.lang) {
      e._blobLang = I.lang;
      e._blob = [e.id, e.name, e.name_en, e.desc, e.desc_en, (e.domains || []).join(' '), (e.rulesets || []).join(' ')].filter(Boolean).join(' ').toLowerCase();
    }
    return e._blob;
  }
  function matches(e) { return (!flt.g || e.group === flt.g) && (!flt.q || entryBlob(e).indexOf(flt.q) >= 0); }

  function renderChips() {
    var cat = catalog(), items = [{ g: '', n: cat.entries.length }].concat(cat.order.map(function (g) { return { g: g, n: cat.entries.filter(function (e) { return e.group === g; }).length }; }));
    var sig = I.lang + '|' + items.map(function (x) { return x.g + x.n; }).join(',');
    if (el.chips._sig !== sig) {
      el.chips._sig = sig; TP.clear(el.chips); chips = {};
      items.forEach(function (x) {
        var b = h('button', { class: 'fchip', type: 'button', 'aria-pressed': 'false' }, x.g ? ui.icon(GICON[x.g] || 'globe', 14, 'ci') : null, h('span', null, x.g ? TP.groupName(x.g) : t('sites.all')), h('span', { class: 'fchip-n' }, String(x.n)));
        b.addEventListener('click', function () { flt.g = flt.g === x.g ? '' : x.g; V.render(); });
        chips[x.g] = b; el.chips.appendChild(b);
      });
    }
    Object.keys(chips).forEach(function (g) { chips[g].setAttribute('aria-pressed', (flt.g === g) ? 'true' : 'false'); });
    el.chips.hidden = !cat.entries.length;
  }

  function renderRows() {
    var cat = catalog(), shown = 0, total = cat.entries.length;
    Object.keys(boxes).forEach(function (g) {
      var sec = boxes[g], all = cat.entries.filter(function (e) { return e.group === g; }), items = all.filter(matches), open = isOpen(g);
      setText(sec._name, TP.groupName(g));
      setText(sec._cnt, flt.q || flt.g ? t('sites.group.countOf', { n: items.length, total: all.length }) : t('sites.group.count', { n: all.length }));
      sec.hidden = !items.length;
      sec._head.setAttribute('aria-expanded', open ? 'true' : 'false'); sec.classList.toggle('is-open', open);
      sec._rows.hidden = !open;
      if (open) ui.syncList(sec._rows, items, function (e) { return e.id; }, makeEntry, function (row, e) { updateEntry(row, e); });
      shown += items.length;
    });
    if (el.final._fin) updateEntry(el.final._fin, el.final._fin._e);
    setText(el.count, total ? (flt.q || flt.g ? t('sites.countOf', { n: shown, total: total }) : t('sites.count', { n: total })) : '');
    if (cat.failed) el.empty.show({ icon: 'warning', text: t('sites.empty.failed'), hint: t('sites.empty.failedHint', { cmd: 'enana' }) });
    else if (!total) el.empty.show({ icon: 'refresh', text: t('sites.empty.loading') });
    else if (!shown) el.empty.show({ icon: 'search', text: t('sites.empty.noMatch'), hint: t('sites.empty.noMatchHint') });
    else el.empty.hide();
  }

  /* ---------- 一个目录条目 ---------- */
  function makeEntry(e) {
    var r = {}, row;
    r.name = h('b', { class: 'site-n' });
    r.cnt = h('span', { class: 'chip' });
    r.mod = ui.badge(L('sites.dm.modified'), 'warn'); I.attr(r.mod, 'title', L('sites.dm.modifiedTip')); r.mod.hidden = true;
    r.rs = h('span', { class: 'badges' });
    r.view = ui.btn(L('sites.dm.open'), { sm: true, kind: 'ghost', icon: 'list-checks', cls: 'sx-view' });
    r.desc = h('div', { class: 'muted sm site-d' });
    r.warn = h('div', { class: 'warn-t', hidden: true }, ui.icon('warning', 14, 'ci'), h('span', null, L('sites.warnIp')));
    r.miss = h('span', { class: 'muted sm', hidden: true }, L('sites.pending'));
    r.seg = ui.seg(t('sites.seg.aria', { name: '' }), OPTS, TP.safe(function (v) { return pick(row, v); }));
    r.seg.mark(DEF[e.default]);
    row = h('div', { class: 'site', role: 'group' },
      h('div', { class: 'site-main' }, h('div', { class: 'site-t' }, r.name, r.cnt, r.mod, r.rs), r.desc, r.miss, r.warn),
      r.view, r.seg.el);
    row._r = r; row._e = e;
    ui.act(r.view, function () { openDomains(row._e); });
    return row;
  }
  function rsShort(tag) { return String(tag).replace(/^geosite-/, '').replace(/^geoip-/, ''); }
  function updateEntry(row, e) {
    var r = row._r, p = S.proxies[e.tag || ('svc-' + e.id)], now = p && p.now, ds = (e.domains || []).length, name = eName(e), isFinal = e.id === 'final';
    row._e = e;
    setText(r.name, name);
    var d = isFinal ? t('sites.final.desc') : I.pick(e, 'desc');
    setText(r.desc, d); r.desc.hidden = !d;
    r.cnt.hidden = isFinal; r.view.hidden = isFinal; r.rs.hidden = isFinal; r.mod.hidden = isFinal || !e.modified;
    if (!isFinal) {
      setText(r.cnt, t('sites.domainCount', { n: ds }));
      r.view.setAttribute('aria-label', t('sites.dm.openAria', { name: name }));
      var rss = (e.rulesets || []), sig = rss.join(',') + '|' + I.lang;
      if (r.rs._sig !== sig) {
        r.rs._sig = sig; TP.clear(r.rs);
        rss.slice(0, 3).forEach(function (tag) { r.rs.appendChild(h('span', { class: 'badge', title: tag }, ui.icon('library', 12, 'ci'), t('sites.ruleset', { name: rsShort(tag) }))); });
        if (rss.length > 3) r.rs.appendChild(h('span', { class: 'badge', title: rss.slice(3).join(', ') }, '+' + (rss.length - 3)));
      }
    }
    r.seg.set(now || '');
    r.seg.el.setAttribute('aria-label', t('sites.seg.aria', { name: name })); row.setAttribute('aria-label', name);
    var ready = !!p, all = (p && p.all) || [];
    ['PIN', 'Global', 'direct'].forEach(function (v) {
      var why = '', fix = null;
      if (!ready) why = S.locked ? t('why.locked') : t('sites.notReady');
      else if (v === 'PIN' && (!TP.hasPinPool() || all.indexOf('PIN') < 0)) { why = TP.why.pin(); fix = addFix(); }
      else if (v === 'Global' && (!TP.hasAutoPool() || all.indexOf('Global') < 0)) { why = TP.why.auto(); fix = addFix(); }
      else if (S.clash === 'down') why = TP.why.clash();
      r.seg.avail(v, why, fix);
    });
    r.miss.hidden = ready;
    r.warn.hidden = !(TP.riskGroup(e.group) && now && now !== 'PIN');
    row.classList.toggle('is-pending', !ready);
  }
  async function pick(row, v) {
    var e = row._e, tag = e.tag || ('svc-' + e.id), p = S.proxies[tag], name = eName(e);
    if (!p) { ui.toast(t('sites.notReady'), 'warn'); return; }
    var prev = p.now;
    row._r.seg.set(prev || '');
    if (prev === v) return;
    var tx = TP.txt.policy(name, prev, v, e.group), risk = TP.riskGroup(e.group) && v !== 'PIN';
    var ok = await ui.confirmDialog({ title: t('sites.change.title'), message: tx.message, detail: tx.detail, confirmText: t('sites.change.go'), danger: risk, rememberKey: 'policy' });
    if (!ok) return;
    p.now = v; updateEntry(row, e);
    try { await TP.setPolicy(tag, v); }
    catch (err) { p.now = prev; updateEntry(row, e); throw err; }
    ui.toast(t('sites.changed', { name: name, state: TP.name.policy(v) }), 'ok', 2400);
  }

  /* 其他海外网站 = Final 选择器 (Global / PIN / direct) */
  function buildFinal() {
    var e = { id: 'final', tag: 'Final', group: 'final', default: '', domains: [], rulesets: [], cidrs: 0 };
    var row = makeEntry(e);
    el.final.appendChild(row); el.final._fin = row; row._e = e;
    updateEntry(row, e);
  }

  /* ================= 自定义网站 (覆盖层: kind=site) ================= */
  var SITE_ST = ['direct', 'pin', 'auto'];
  function parseHost(s) {
    s = String(s || '').trim();
    if (!s) return { err: t('sites.err.empty') };
    s = s.replace(/^[a-z][a-z0-9+.-]*:\/\//i, '').split(/[\/?#\s]/)[0].replace(/^[^@]*@/, '').replace(/:\d+$/, '').replace(/^\*\./, '').replace(/^\.+|\.+$/g, '');
    if (!s) return { err: t('sites.err.noHost') };
    var host;
    try { host = new URL('http://' + s).hostname.toLowerCase(); } catch (e) { return { err: t('sites.err.invalid') }; }
    if (/^\d{1,3}(\.\d{1,3}){3}$/.test(host) || host.indexOf(':') >= 0 || host.charAt(0) === '[') return { err: t('sites.err.ip') };
    if (host.length > 253 || !/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(host)) return { err: t('sites.err.format') };
    return { host: host };
  }
  V.parseHost = parseHost;

  function openAddSite(prefill) {
    var inp = h('input', { class: 'inp', type: 'text', placeholder: t('sites.add.ph'), 'aria-label': t('sites.add.field'), autocomplete: 'off', spellcheck: 'false', value: prefill || '' });
    var sel = h('select', { class: 'sel', 'aria-label': t('sites.add.state') }, SITE_ST.map(function (v) { return TP.opt(v, TP.name.app(v)); }));
    sel.value = TP.hasPinPool() ? 'pin' : 'direct';
    var msg = h('div', { class: 'fld-h', 'aria-live': 'polite' });
    function live(force) {
      var r = parseHost(inp.value);
      if (!inp.value.trim() && !force) { msg.className = 'fld-h'; setText(msg, ''); return r; }
      msg.className = 'fld-h ' + (r.err ? 'bad-t' : 'ok-t'); setText(msg, r.err || t('sites.add.will', { host: r.host }));
      return r;
    }
    inp.addEventListener('input', function () { live(false); });
    var form = h('form', { novalidate: true, class: 'mform' }, ui.field(t('sites.add.field'), inp, t('sites.add.fieldHint')), msg, ui.field(t('sites.add.state'), sel), h('p', { class: 'muted sm' }, t('sites.add.note')));
    var api = ui.modal({
      title: t('sites.add.title'), icon: 'plus', iconKind: 'pri', size: 'sm', body: form,
      dirty: function () { return !!inp.value.trim(); },
      actions: [
        { label: t('common.cancel'), cancel: true },
        { label: t('sites.add.go'), kind: 'primary', icon: 'check', id: 'go', onClick: async function () {
          var r = live(true);
          if (r.err || !r.host) { inp.focus(); return false; }
          var why = TP.why.helper(); if (why) { ui.toast(why, 'warn'); return false; }
          await TP.override('site', r.host, sel.value);
          ui.toast(t('sites.add.done', { host: r.host, state: TP.name.app(sel.value) }), 'ok');
          TP.loadState();
        } }
      ]
    });
    form.addEventListener('submit', function (ev) { ev.preventDefault(); var b = api.getBtn('go'); if (b) b.click(); });
    return api;
  }
  V.openAdd = openAddSite;

  function renderCustom() {
    var noH = TP.noHelper(), why = TP.why.helper(), all = ((S.state && S.state.overrides) || []).filter(function (o) { return o.kind === 'site'; });
    var pr = pgC.update(all.length), items = all.slice(pr.start, pr.end);
    ui.syncList(el.cList, items, function (o) { return o.value; }, makeCustom, function (row, o) {
      row._o = o; setText(row._host, o.value);
      if (row._sel.value !== o.state) row._sel.value = o.state;
      Array.prototype.forEach.call(row._sel.options, function (op) { var s = TP.name.app(op.value); if (op.textContent !== s) op.textContent = s; });
      ui.avail(row._sel, why); ui.avail(row._del, why);
      row._sel.setAttribute('aria-label', t('sites.custom.stateAria', { host: o.value }));
      row._del.setAttribute('aria-label', t('sites.custom.delAria', { host: o.value })); row._del.title = t('sites.custom.delAria', { host: o.value }); row._del._tip = row._del.title;
    });
    setText(el.cCnt, all.length ? t('sites.custom.count', { n: all.length }) : '');
    if (!all.length) el.cEmpty.show({ icon: 'nav-sites', text: t(noH ? 'sites.custom.noHelper' : 'sites.custom.empty'), hint: noH ? '' : t('sites.custom.emptyHint'), action: noH ? null : { label: t('sites.add'), icon: 'plus', fn: function () { return openAddSite(); } } });
    else el.cEmpty.hide();
  }
  function makeCustom() {
    var host = h('span', { class: 'mono site-n' }), sel = h('select', { class: 'sel sm' }, SITE_ST.map(function (x) { return TP.opt(x, TP.name.app(x)); }));
    var del = ui.ibtn('delete', t('common.delete'), { cls: 'danger-t' });
    var row = h('div', { class: 'site custom' }, h('div', { class: 'site-main' }, host), sel, del);
    row._host = host; row._sel = sel; row._del = del;
    ui.selectAct(sel, function () { return row._o.state; }, async function (want) {
      var o = row._o, prev = o.state, tx = TP.txt.app(o.value, prev, want);
      var ok = await ui.confirmDialog({ title: t('sites.change.title'), message: tx.message, detail: tx.detail, confirmText: t('sites.change.go'), rememberKey: 'policy' });
      if (!ok) return;
      o.state = want; sel.value = want;
      try { await TP.override('site', o.value, want); } catch (e) { o.state = prev; sel.value = prev; throw e; }
      ui.toast(t('sites.changed', { name: o.value, state: TP.name.app(want) }), 'ok', 2400);
    });
    ui.act(del, async function () {
      var v = row._o.value;
      var ok = await ui.confirmDialog({ title: t('sites.custom.delTitle'), message: t('sites.custom.delMsg', { host: v }), detail: t('sites.custom.delDetail'), confirmText: t('common.delete'), danger: true });
      if (!ok) return;
      await TP.override('site', v, 'follow');
      ui.toast(t('sites.custom.deleted', { host: v }), 'ok'); await TP.loadState();
    });
    return row;
  }

  /* ================= 域名弹窗: 查看 / 添加 / 修改 / 删除 / 恢复 / 重置 =================
   * GET  /api/sites/domains?id=            -> {id,name,modified,system[],domains[{domain,source:'system'|'added'}],removed[],rulesets[],cidrs,policy}
   * POST /api/sites/domains  id action=add|remove|update|restore domain (new)   -> {ok, job}
   * POST /api/sites/domains/reset  id      -> {ok, job}
   * 写操作都是后台任务 (重新生成配置, 热生效): 弹窗里用 ui.taskCard + TP.jobs.follow 显示进度, 期间所有按钮暂不可用; 完成后重新读取列表并刷新目录 (条目上的个数和「已修改」)。
   * 列表 = 当前生效的域名 (domains) + 被你删掉的系统域名 (removed, 划掉显示, 可恢复), 按域名排序, 删除 / 恢复 / 修改都不会让行乱跳。 */
  var LBL_RE = /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/;

  /* 整理并校验输入: -> {host, fixes:[…]} | {empty:true} | {err:'码', vars}; fixes = 整理时改动的地方 (界面会告诉用户, 不悄悄改) */
  function checkDomain(raw) {
    var s = String(raw == null ? '' : raw).trim(), fx = [], m, lo, u, labels;
    if (!s) return { empty: true };
    if ((m = /^[a-z][a-z0-9+.-]*:\/\//i.exec(s))) { s = s.slice(m[0].length); fx.push('proto'); }
    if ((m = /[\/?#]/.exec(s))) { s = s.slice(0, m.index); fx.push('path'); }
    if (s.indexOf('@') >= 0) { s = s.slice(s.lastIndexOf('@') + 1); fx.push('user'); }
    if ((m = /:\d{1,5}$/.exec(s))) { s = s.slice(0, m.index); fx.push('port'); }
    if (/^(?:\*?\.)+/.test(s)) { s = s.replace(/^(?:\*?\.)+/, ''); fx.push('wild'); }
    if (/\.+$/.test(s)) { s = s.replace(/\.+$/, ''); fx.push('dot'); }
    if ((lo = s.toLowerCase()) !== s) { s = lo; fx.push('lower'); }
    if (/[^\x00-\x7f]/.test(s)) { try { u = new URL('http://' + s).hostname; if (u && u !== s) { s = u; fx.push('idn'); } } catch (e) { /* 交给下面的格式检查 */ } }
    if (!s) return { err: 'noHost' };
    if (/\s/.test(s)) return { err: 'space' };
    if (s.indexOf('*') >= 0) return { err: 'wild' };
    if (/^\d{1,3}(?:\.\d{1,3}){3}$/.test(s) || s.charAt(0) === '[' || s.split(':').length > 2) return { err: 'ip' };
    if (/[^a-z0-9.-]/.test(s)) return { err: 'chars' };
    if (s.length > 253) return { err: 'total', vars: { n: 253 } };
    labels = s.split('.');
    if (labels.some(function (x) { return !x; })) return { err: 'dots' };
    if (labels.length < 2) return { err: 'one' };
    if (labels.some(function (x) { return x.length > 63; })) return { err: 'label', vars: { n: 63 } };
    if (labels.some(function (x) { return !LBL_RE.test(x); })) return { err: 'hyphen' };
    return { host: s, fixes: fx };
  }
  /* 后端的 E_INVALID 带具体原因 (已按语言头本地化), 通用的 error.E_INVALID 太笼统 */
  function reasonOf(e) { return e && e.code === 'E_INVALID' && e.message ? e.message : TP.errMsg(e); }
  function domPager() {                                                             // 分页器全局只建一个 (TP.on 不能取消订阅), 每次打开弹窗重新挂载
    if (!pgD) { pgD = ui.pager(PG_DOMAINS, { def: 10 }); pgD.onChange(function () { if (dm) dm.onPage(); }); }
    return pgD;
  }

  function openDomains(entry) {
    if (dm) return;
    var eid = entry.id, tag = entry.tag || ('svc-' + eid), n = ++uid, name = eName(entry), pg = domPager();
    var st = { data: null, rows: [], have: {}, gone: {}, nA: 0, nR: 0, modified: !!entry.modified, q: '', edit: null, busy: false, loading: true, err: '', offline: false, goto: 0, flash: '', focus: null };
    var seq = 0, card = null, rowBtns = [], editInp = null, api = null, ctl = null, rendering = false, ro = !!(entry.custom || entry.group === 'custom');       // ro: 自定义规则集条目没有可编辑的域名
    pg.setPage(1); pg.update(0);

    /* ---- 标题: 名称 + 当前出口 + 「已修改」 ---- */
    var tName = h('span', { class: 'sdm-name' }, name), tPol = h('span', { class: 'chip sdm-p', hidden: true }), tMod = ui.badge(L('sites.dm.modified'), 'warn');
    tMod.hidden = true;
    var title = h('span', { class: 'sdm-title' }, tName, tPol, tMod);

    /* ---- 工具: 搜索 + 添加 ---- */
    var qIn = h('input', { class: 'inp sdm-q', type: 'search', placeholder: L('sites.dm.search'), 'aria-label': L('sites.dm.search'), autocomplete: 'off', spellcheck: 'false' });
    var addIn = h('input', { class: 'inp mono sdm-in', id: 'sdm-add' + n, type: 'text', placeholder: L('sites.dm.addPh'), autocomplete: 'off', autocapitalize: 'none', spellcheck: 'false', 'aria-describedby': 'sdm-addm' + n });
    var addMsg = h('div', { class: 'fld-h sdm-msg', id: 'sdm-addm' + n, 'aria-live': 'polite' });
    var addBtn = ui.btn(L('sites.dm.add'), { kind: 'primary', icon: 'plus', type: 'submit' });
    var addForm = h('form', { class: 'sdm-add', novalidate: true }, h('label', { class: 'fld-l', for: 'sdm-add' + n }, L('sites.dm.addLabel')), h('div', { class: 'sdm-add-r' }, addIn, addBtn), addMsg);
    var taskBox = h('div', { class: 'sdm-task' });
    var noteTxt = h('span', { class: 'sdm-note-t' }), noteBtn = ui.btn(L('common.retry'), { sm: true, icon: 'refresh' });
    var note = h('div', { class: 'hint sdm-note', hidden: true, role: 'status' }, noteTxt, noteBtn);
    ui.act(noteBtn, function () { return load(false); });

    /* ---- 列表 ---- */
    var sum = h('span', { class: 'muted sm', 'aria-live': 'polite' });
    var lh = h('div', { class: 'sdm-lh' }, h('b', null, L('sites.dm.listTitle'), help('src')), sum);
    var ul = h('ul', { class: 'sdm-list', 'aria-label': L('sites.dm.listTitle') }), box = ui.emptyBox();
    var roBox = h('section', { class: 'sdm-ro', hidden: true });
    var body = h('div', { class: 'sdm' }, h('div', { class: 'sdm-tools' }, qIn, addForm), taskBox, note, h('div', { class: 'sdm-listbox' }, lh, ul, box.el, pg.el), roBox);

    /* ---- 状态相关的小函数 ---- */
    function lockWhy() {                                                            // 现在为什么不能改 ('' = 可以)
      var w = TP.why.helper(); if (w) return w;
      if (st.busy) return t('sites.dm.busy');
      if (st.offline) return t('sites.dm.offline');
      if (ro) return t('sites.dm.roEntry');
      if (!st.data) return st.err ? t('sites.dm.loadFail') : t('sites.dm.loading');
      return '';
    }
    function matchRow(x) { return !st.q || x.domain.indexOf(st.q) >= 0; }
    function indexIn(list, d) { for (var i = 0; i < list.length; i++) if (list[i].domain === d) return i; return -1; }
    function checkAdd(raw) {
      var r = checkDomain(raw);
      if (!r.host) return r;
      if (st.have[r.host]) return { err: 'dup', vars: { host: r.host } };
      return st.gone[r.host] ? { host: r.host, fixes: r.fixes, restore: true } : r;       // 添加一个被你删掉的系统域名 = 恢复它
    }
    function checkEdit(raw, x) {
      var r = checkDomain(raw);
      if (!r.host) return r;
      if (r.host === x.domain) return { err: 'same' };
      if (st.have[r.host]) return { err: 'dup', vars: { host: r.host } };
      if (st.gone[r.host]) return { err: 'gone', vars: { host: r.host } };
      return r;
    }
    function showMsg(b, r, mode) {                                                  // 输入框下面的提示: 图标 + 文字 (不只靠颜色)
      TP.clear(b);
      var soft = !!r && r.err === 'same', bad = !!r && !!r.err && !soft, info = !!r && (!!r.restore || soft);
      b.className = 'fld-h sdm-msg' + (!r || r.empty ? '' : bad ? ' is-bad' : info ? ' is-info' : ' is-ok');
      if (!r || r.empty) return;
      b.appendChild(ui.icon(bad ? 'error' : info ? 'info' : 'success', 14, 'ci'));
      b.appendChild(h('span', { class: 'sdm-msg-t' }, r.err ? (r.text || t('sites.dm.err.' + r.err, r.vars)) : t(r.restore ? 'sites.dm.willRestore' : mode === 'edit' ? 'sites.dm.willEdit' : 'sites.dm.will', { host: r.host })));
      if (!r.err && r.fixes && r.fixes.length) b.appendChild(h('span', { class: 'sdm-msg-n' }, t('sites.dm.fixed', { list: r.fixes.map(function (k) { return t('sites.dm.fix.' + k); }).join(t('sites.dm.sep')) })));
    }

    /* ---- 数据 ---- */
    function applyData(r) {
      var rows = [], seen = {};
      function add(dom, src, removed) { dom = String(dom || '').toLowerCase(); if (!dom || seen[dom]) return; seen[dom] = 1; rows.push({ domain: dom, src: src, removed: removed }); }
      (r.domains || []).forEach(function (d) { var o = typeof d === 'string' ? { domain: d } : (d || {}); add(o.domain, o.source === 'added' ? 'added' : o.source === 'system' ? 'system' : '', false); });
      (r.removed || []).forEach(function (d) { add(typeof d === 'string' ? d : (d && d.domain), 'system', true); });
      rows.sort(function (a, b) { return a.domain < b.domain ? -1 : a.domain > b.domain ? 1 : 0; });
      st.data = r; st.rows = rows; st.have = {}; st.gone = {}; st.nA = 0; st.nR = 0;
      rows.forEach(function (x) { if (x.removed) { st.gone[x.domain] = 1; st.nR++; } else { st.have[x.domain] = 1; if (x.src === 'added') st.nA++; } });
      st.modified = !!r.modified || st.nA > 0 || st.nR > 0;
      var ent = !st.offline && S.catalog && S.catalog.entries.filter(function (x) { return x.id === eid; })[0];
      if (ent) {                                                                    // 页面上的条目 (域名个数 / 「已修改」) 不用等目录重新加载
        ent.domains = rows.filter(function (x) { return !x.removed; }).map(function (x) { return x.domain; }); ent.modified = st.modified; ent._blob = null;
        if (active()) renderRows();
      }
    }
    function fallback() {                                                           // 辅助服务连不上: 用目录里当前生效的域名只读显示
      st.offline = true;
      applyData({ id: eid, name: name, modified: !!entry.modified, domains: (entry.domains || []).map(function (d) { return { domain: d, source: '' }; }), removed: [], rulesets: entry.rulesets || [], cidrs: +entry.cidrs || 0, policy: '' });
    }
    async function load(quiet) {                                                    // quiet: 不改 loading 状态也不重画 (调用者负责)
      var my = ++seq, ok = false;
      if (!quiet) { st.loading = true; st.err = ''; render(); }
      try {
        var r = await TP.helper('GET', '/api/sites/domains', { q: { id: eid } });
        if (my !== seq) return false;
        st.offline = false; st.err = ''; applyData(r); ok = true;
      } catch (e) {
        if (my !== seq) return false;
        if (e && (e.kind === 'auth' || e.kind === 'cancel')) { /* 登录框已经弹出 / 用户取消: 不报错 */ }
        else if (e && e.kind === 'unreachable' && !st.data) fallback();
        else st.err = reasonOf(e);
      }
      if (!quiet) { st.loading = false; render(); }
      return ok;
    }

    /* ---- 画面 ---- */
    function paintHead() {
      var d = st.data, route = ROUTE[(d && d.policy) || ''] || ROUTE[(S.proxies[tag] && S.proxies[tag].now) || ''] || '';
      setText(tName, eName(entry));
      tPol.hidden = !route;
      if (route) { TP.clear(tPol); tPol.className = 'chip sdm-p sdm-p-' + route; tPol.appendChild(ui.icon(route, 13, 'ci')); tPol.appendChild(document.createTextNode(TP.name.route(route))); }
      tMod.hidden = !(d ? st.modified : entry.modified);
    }
    function paintRo() {                                                            // 社区规则集 / IP 段: 只读说明
      var d = st.data || {}, rs = d.rulesets || [], c = +d.cidrs || 0;
      TP.clear(roBox); roBox.hidden = !(rs.length || c > 0);
      if (roBox.hidden) return;
      var line = h('div', { class: 'sdm-ro-l' });
      rs.forEach(function (rt) { var b = ui.badge(rt, 'neutral', 'library'); b.classList.add('mono'); line.appendChild(b); });
      if (c > 0) line.appendChild(h('span', { class: 'muted sm' }, t('sites.cidrs', { n: c })));
      roBox.appendChild(h('h4', null, ui.icon('library', 15, 'ci'), L('sites.dm.ro.title'), help('ro')));
      roBox.appendChild(h('p', { class: 'muted sm' }, L('sites.dm.ro.sub')));
      roBox.appendChild(line);
    }
    function paintLock() {                                                          // 操作期间: 按钮「暂不可用」(点击说明原因), 不重建行 (保住焦点)
      var why = lockWhy(), rb = api && api.getBtn('reset');
      ui.avail(addBtn, why);
      if (rb) ui.avail(rb, why || (!st.modified ? t('sites.dm.resetNone') : ''));
      rowBtns.forEach(function (b) { ui.avail(b, why); });
      if (editInp) editInp.readOnly = st.busy;
      ul.setAttribute('aria-busy', st.busy ? 'true' : 'false');
    }
    function focusTarget(f) {
      var node = null, c, i, li;
      if (f.k === 'add') { if (isTouch()) return; node = addIn; }                   // 触屏上不自动弹出键盘
      else if (f.d) { c = ul.querySelectorAll('[data-k]'); for (i = 0; i < c.length; i++) if (c[i].getAttribute('data-d') === f.d && c[i].getAttribute('data-k') === f.k) { node = c[i]; break; } }
      else if (typeof f.i === 'number') { li = ul.children[Math.min(f.i, ul.children.length - 1)]; node = li && li.querySelector('button,input'); }
      if (!node) node = ul.querySelector('button,input') || addIn;
      try { node.focus(); } catch (e) { /* 忽略 */ }
      if (f.k === 'input' && node.select) node.select();
    }
    function render() {
      paintHead(); paintRo();
      var d = st.data, list = st.rows.filter(matchRow), shown = false, parts = [], r = { start: 0, end: 0 }, fl = st.flash;
      st.flash = '';
      /* 提示条: 读取失败 / 辅助服务未运行 */
      var nt = st.err ? t('sites.dm.loadFail') + ': ' + st.err : st.offline ? t('sites.dm.offline') : ro ? t('sites.dm.roEntry') : '';
      note.hidden = !nt; note.className = 'hint sdm-note ' + (st.err ? 'bad' : st.offline ? 'warn' : ''); setText(noteTxt, nt); noteBtn.hidden = !(st.err || st.offline);
      /* 摘要 */
      if (d) {
        parts.push(st.q ? t('sites.dm.cntOf', { n: list.length, total: st.rows.length }) : t('sites.domainCount', { n: st.rows.length - st.nR }));
        if (st.nA) parts.push(t('sites.dm.cntAdded', { n: st.nA }));
        if (st.nR) parts.push(t('sites.dm.cntRemoved', { n: st.nR }));
      }
      setText(sum, parts.join(' · '));
      /* 列表区: 读取中 / 空 / 没有匹配 / 列表 */
      if (!d) { if (st.err) box.hide(); else box.show({ icon: 'refresh', text: t('sites.dm.loading') }); }
      else if (!st.rows.length) box.show({ icon: 'globe', text: t('sites.dm.empty'), hint: ro ? '' : t((d.rulesets || []).length ? 'sites.dm.emptyRs' : 'sites.dm.emptyHint'), action: st.offline || ro ? null : { label: t('sites.dm.addLabel'), icon: 'plus', fn: function () { addIn.focus(); } } });
      else if (!list.length) box.show({ icon: 'search', text: t('sites.dm.noMatch'), hint: t('sites.dm.noMatchHint'), action: { label: t('sites.dm.clearSearch'), icon: 'x', fn: function () { qIn.value = ''; st.q = ''; render(); } } });
      else {
        box.hide(); shown = true; r = pg.update(list.length);
        if (st.goto) { var g = st.goto; st.goto = 0; if (g !== r.page) { rendering = true; pg.setPage(g); rendering = false; r = pg.update(list.length); } }
      }
      if (!shown) pg.update(0);
      st.goto = 0;
      var page = list.slice(r.start, r.end);
      if (st.edit && indexIn(page, st.edit.domain) < 0) st.edit = null;
      /* 行 */
      TP.clear(ul); rowBtns = []; editInp = null; ul.hidden = !shown;
      page.forEach(function (x) { ul.appendChild(rowEl(x, x.domain === fl)); });
      paintLock();
      if (st.focus) { var f = st.focus; st.focus = null; focusTarget(f); }
    }
    function rowEl(x, fresh) {
      if (st.edit && st.edit.domain === x.domain) return editRow(x);
      var dom = x.domain, why = lockWhy();
      function dk(b, k) { b.setAttribute('data-d', dom); b.setAttribute('data-k', k); rowBtns.push(b); ui.avail(b, why); return b; }
      var li = h('li', { class: 'sdm-row' + (x.removed ? ' is-removed' : '') + (fresh ? ' is-new' : '') });
      var main = h('div', { class: 'sdm-main' }, h('span', { class: 'sdm-dom mono' }, dom));
      var act = h('div', { class: 'sdm-act' });
      if (x.removed) {
        main.appendChild(ui.badge(L('sites.dm.src.removed'), 'warn'));
        var rs = dk(h('button', { class: 'sdm-link', type: 'button', 'aria-label': t('sites.dm.restoreAria', { domain: dom }) }, ui.icon('history', 14, 'ci'), L('sites.dm.restore')), 'restore');
        ui.act(rs, function () { return run({ kind: 'restore', domain: dom }); });
        act.appendChild(rs);
      } else {
        if (x.src === 'added') main.appendChild(ui.badge(L('sites.dm.src.added'), 'ok'));
        else if (x.src === 'system') main.appendChild(ui.badge(L('sites.dm.src.system'), 'info'));
        var ed = dk(ui.btn(L('sites.dm.edit'), { sm: true, kind: 'ghost', icon: 'edit', aria: t('sites.dm.editAria', { domain: dom }) }), 'edit');
        var del = dk(ui.btn(L('sites.dm.del'), { sm: true, kind: 'ghost', cls: 'danger-t', icon: 'delete', aria: t('sites.dm.delAria', { domain: dom }) }), 'del');
        ui.act(ed, function () { st.edit = { domain: dom, value: dom, err: '', saving: false }; st.focus = { d: dom, k: 'input' }; render(); });
        ui.act(del, async function () {
          var ok = await ui.confirmDialog({ kind: 'warning', title: t('sites.dm.del.title'), message: t('sites.dm.del.msg', { domain: dom, name: name }), detail: t(x.src === 'added' ? 'sites.dm.del.added' : 'sites.dm.del.sys'), confirmText: t('common.delete'), confirmIcon: 'delete', rememberKey: 'site-domain-remove' });
          if (!ok) return;
          await run({ kind: 'remove', domain: dom, src: x.src, idx: Array.prototype.indexOf.call(ul.children, li) });
        });
        if (!st.offline && !ro) { act.appendChild(ed); act.appendChild(del); }
      }
      li.appendChild(main); if (act.firstChild) li.appendChild(act);
      return li;
    }
    function cancelEdit(dom) { st.edit = null; st.focus = { d: dom, k: 'edit' }; render(); }
    function editRow(x) {
      var ed = st.edit, dom = x.domain, why = lockWhy();
      var inp = h('input', { class: 'inp mono sdm-in', type: 'text', value: ed.value, 'aria-label': t('sites.dm.editField', { domain: dom }), autocomplete: 'off', autocapitalize: 'none', spellcheck: 'false', 'data-d': dom, 'data-k': 'input' });
      var msg = h('div', { class: 'fld-h sdm-msg', 'aria-live': 'polite' });
      var save = ui.btn(L('common.save'), { sm: true, kind: 'primary', icon: 'check', type: 'submit', aria: t('sites.dm.saveAria', { domain: dom }) });
      var cancel = ui.btn(L('common.cancel'), { sm: true, icon: 'x' });
      editInp = inp; rowBtns.push(save); rowBtns.push(cancel); ui.avail(save, why); ui.avail(cancel, why);
      if (ed.err) showMsg(msg, { err: true, text: ed.err }, 'edit');
      else if (ed.value !== dom) showMsg(msg, checkEdit(ed.value, x), 'edit');
      inp.addEventListener('input', function () { ed.value = inp.value; ed.err = ''; showMsg(msg, ed.value === dom || !ed.value.trim() ? null : checkEdit(ed.value, x), 'edit'); });
      inp.addEventListener('keydown', function (ev) { if (ev.key === 'Escape') { ev.preventDefault(); ev.stopPropagation(); if (!st.busy) cancelEdit(dom); } });     // Esc 只取消这一行的编辑, 不关闭弹窗
      cancel.addEventListener('click', function () { if (cancel._un) { ui.unavailable(cancel); return; } cancelEdit(dom); });
      var f = h('form', { class: 'sdm-ed', novalidate: true }, inp, h('div', { class: 'sdm-act' }, save, cancel), msg, x.src === 'system' ? h('div', { class: 'sdm-hint' }, L('sites.dm.sysHint')) : null);
      f.addEventListener('submit', function (ev) {
        ev.preventDefault();
        var w = lockWhy(); if (w) { ui.toast(w, 'warn', 3000); return; }
        var r = checkEdit(inp.value, x);
        if (r.empty) r = { err: 'noHost' };
        showMsg(msg, r, 'edit');
        if (r.err) { inp.focus(); return; }
        run({ kind: 'update', domain: dom, to: r.host });
      });
      return h('li', { class: 'sdm-row is-edit' }, f);
    }

    /* ---- 操作: 提交 -> 跟随任务 -> 重新读取 -> 刷新目录 ---- */
    function dismissCard() { if (card) { card.close(); card = null; } }
    function reveal(d) {                                                            // 让新添加 / 修改的行出现在当前页, 并短暂高亮
      st.flash = d;
      var list = st.rows.filter(matchRow), i = indexIn(list, d);
      if (i < 0 && st.q) { st.q = ''; qIn.value = ''; i = indexIn(st.rows, d); }
      if (i >= 0) st.goto = Math.floor(i / pg.size()) + 1;
    }
    function doneKey(op) { return op.kind === 'remove' && op.src === 'system' ? 'removeSys' : op.kind; }
    async function run(op) {
      var why = lockWhy(); if (why) { ui.toast(why, 'warn', 3000); return; }
      var vars = { domain: op.domain, to: op.to, name: name }, c, res, started = false, form = { id: eid };
      st.busy = true; dismissCard();
      c = card = ui.taskCard(t('sites.dm.job.' + op.kind, vars), { horizontal: true });
      taskBox.appendChild(c.el);
      c.set({ pct: null, msg: t('sites.dm.applying') });
      if (st.edit && op.kind === 'update') st.edit.saving = true;
      paintLock();
      if (op.kind !== 'reset') { form.action = op.kind; form.domain = op.domain; if (op.kind === 'update') form['new'] = op.to; }
      try {
        res = await TP.helper('POST', op.kind === 'reset' ? '/api/sites/domains/reset' : '/api/sites/domains', { form: form });
        if (res && res.job) { started = true; await TP.jobs.follow(res.job, c); }
      } catch (e) {
        st.busy = false; if (st.edit) st.edit.saving = false;
        if (started) TP.afterApply();
        if (e && (e.kind === 'auth' || e.kind === 'cancel')) { dismissCard(); paintLock(); return; }
        if (e && e.kind === 'api' && e.code === 'E_INVALID' && (op.kind === 'add' || op.kind === 'update')) {        // 校验没通过 (任务没有开始): 原因显示在输入框下面
          dismissCard();
          if (op.kind === 'add') { showMsg(addMsg, { err: true, text: reasonOf(e) }, 'add'); addIn.focus(); }
          else if (st.edit) { st.edit.err = reasonOf(e); st.focus = { d: op.domain, k: 'input' }; }
          render(); return;
        }
        c.fail(reasonOf(e));                                                        // 失败: 列表保持原样, 原因显示在任务卡片里 + 重试
        var rb = ui.btn(L('common.retry'), { sm: true, icon: 'refresh' });
        ui.act(rb, function () { return run(op); });
        c.el.appendChild(rb);
        await load(true); render();                                                 // 重新读取一次, 保证显示的是真实状态
        return;
      }
      c.done(t('sites.dm.done.' + doneKey(op), vars));
      TP.afterApply(); TP.loadCatalog();
      await load(true);
      st.busy = false; st.edit = null;
      if (op.kind === 'add' || op.kind === 'update' || op.kind === 'restore') reveal(op.kind === 'update' ? op.to : op.domain);
      if (op.kind === 'add' || op.from === 'add') { addIn.value = ''; showMsg(addMsg, null, 'add'); st.focus = { k: 'add' }; }
      else if (op.kind === 'remove') st.focus = st.gone[op.domain] ? { d: op.domain, k: 'restore' } : { i: op.idx || 0 };
      else if (op.kind === 'reset') st.focus = { k: 'add' };
      else st.focus = { d: op.kind === 'update' ? op.to : op.domain, k: 'edit' };
      render();
      ui.toast(t('sites.dm.done.' + doneKey(op), vars), 'ok', 2600);
      setTimeout(function () { if (card === c) { c.close(); card = null; } }, 1800);
    }
    async function doReset() {
      var why = lockWhy(); if (why) { ui.toast(why, 'warn'); return false; }
      var det = [];
      if (st.nA) det.push(t('sites.dm.reset.added', { n: st.nA }));
      if (st.nR) det.push(t('sites.dm.reset.removed', { n: st.nR }));
      det.push(t('sites.dm.reset.final'));
      var ok = await ui.confirmDialog({ danger: true, title: t('sites.dm.reset.title'), message: t('sites.dm.reset.msg', { name: name }), detail: det, confirmText: t('sites.dm.reset.go'), confirmIcon: 'rotate-ccw' });
      if (!ok) return false;
      await run({ kind: 'reset' });
      return false;
    }

    /* ---- 事件 ---- */
    qIn.addEventListener('input', function () { st.q = qIn.value.trim().toLowerCase(); st.edit = null; pg.setPage(1); render(); });
    qIn.addEventListener('keydown', function (ev) { if (ev.key === 'Escape' && qIn.value) { ev.preventDefault(); ev.stopPropagation(); qIn.value = ''; st.q = ''; st.edit = null; pg.setPage(1); render(); } });      // 先清空搜索, 再按一次才关闭弹窗
    addIn.addEventListener('input', function () { showMsg(addMsg, checkAdd(addIn.value), 'add'); });
    addForm.addEventListener('submit', function (ev) {
      ev.preventDefault();
      var w = lockWhy(); if (w) { ui.toast(w, 'warn', 3000); return; }
      var r = checkAdd(addIn.value);
      if (r.empty) r = { err: 'empty' };
      showMsg(addMsg, r, 'add');
      if (r.err) { addIn.focus(); return; }
      run(r.restore ? { kind: 'restore', domain: r.host, from: 'add' } : { kind: 'add', domain: r.host });
    });

    ctl = dm = { paint: function () { render(); }, onPage: function () { if (rendering) return; st.edit = null; render(); } };
    api = ui.modal({
      title: title, icon: 'globe', iconKind: 'pri', size: 'lg', cls: 'sdm-dlg', body: body,
      dirty: function () { return !st.busy && (!!addIn.value.trim() || !!(st.edit && st.edit.value !== st.edit.domain)); },       // 正在提交时输入框里的字已经交出去了, 关闭不算丢失
      onClose: function () { if (dm === ctl) dm = null; },
      actions: [
        { label: L('sites.dm.reset'), kind: 'ghost', cls: 'sdm-reset', icon: 'rotate-ccw', id: 'reset', keep: true, onClick: doReset },
        { label: L('common.close'), cancel: true, cls: 'sdm-close', id: 'close', autofocus: isTouch() }
      ]
    });
    var rb0 = api.getBtn('reset');
    if (rb0) rb0.parentNode.insertBefore(help('reset'), rb0.nextSibling);
    render();
    load(false);
  }
})();
