/* enana · v-rules.js — 规则库页: 社区规则集 (.srs) 的启用 / 更新 / 自定义链接
 *
 *   GET  /api/rules -> {sets:[{tag,name,desc,repo,present,bytes,updated,enabled,essential,custom,policy?, name_en?, desc_en?}], updated}
 *   POST /api/rules/toggle 表单 tag,on=0|1 -> {ok,job}            (启用 = 下载并应用; 停用 = 不再使用; essential 的不可停用)
 *   POST /api/rules/custom/add 表单 name,url,policy -> {ok,job}    (url 必须是 http(s) 的 .srs 二进制规则集)
 *   POST /api/rules/custom/delete 表单 tag -> {ok,job}
 *   「全部更新」按钮由 actions.js 的 TP.bindRulesBtn 统一管理 (确认 / 进度卡片 / 「刚刚更新」), 完成后触发 'rules-updated' 事件 -> 本页重新加载。
 *
 * 每个会改变状态的操作: confirmDialog (说清楚会下载什么、应用什么、哪些网站受影响; 启用 = 绿色确认, 停用 = 琥珀色, 删除 = 红色) -> 任务 (dock 或弹窗内进度卡片) -> 重新加载列表。
 * 不能用的控件不用 disabled: ui.avail(控件, 原因) + 点击时 toast 原因。
 * 分页: ui.pager('rules', {def: 20}) (筛选 / 搜索之后再分页; 改了筛选回到第 1 页); 偏好 (TP.prefs): rules.filter (上次选的筛选)。
 * 列头排序 (ui.sorter('rules'), 记在 prefs sort.rules): 启用 / 规则集 / 标签 / 来源 / 状态 都可以点列头排序 (「操作」列不是数据); 顺序: 筛选 → 排序 (整张表) → 分页;
 *   没有选排序时保持原来的顺序 (必选 → 自定义 → 其余按名称)。 */
(function () {
  'use strict';
  var TP = window.TP, S = TP.S, h = TP.h, ui = TP.ui, fmt = TP.fmt, setText = TP.setText, I = window.I18N, t = I.t, L = I.L;
  var V = TP.V.rules = { id: 'rules' };

  var NAME_RE = /^[A-Za-z0-9._ -]{1,40}$/;               // 名称: 字母 数字 空格 . _ -  (最多 40 个字符)
  var FILTERS = ['all', 'enabled', 'missing', 'custom'];
  var PRED = {
    all: function () { return true; },
    enabled: function (s) { return !!s.enabled; },
    missing: function (s) { return !s.present; },
    custom: function (s) { return !!s.custom; }
  };
  var POL_ICON = { pin: 'pin', auto: 'auto', direct: 'direct' };
  var PK = { filter: 'rules.filter' };                                                                                         // i18n-ignore (偏好键, 不是词典键)
  var HT = { page: 'rules.page', update: 'rules.update', custom: 'rules.custom', essential: 'rules.essential', policy: 'rules.policy' };     // i18n-ignore (「!」说明的话题: 词典键是 help.<话题>.*)

  var el = {}, chips = {}, pg = null, so = null, pgTotal = -1;
  var data = null, err = null, seq = 0;                   // data = {sets, updated}; err 只在还没有数据时显示
  var flt = { q: '', f: pickFilter(TP.prefs.get(PK.filter, 'all')) };
  var pending = {};                                        // tag -> 'on' | 'off' | 'del': 任务进行中

  function active() { return TP.tab === 'rules'; }
  function nameOf(s) { return I.pick(s, 'name') || s.tag; }
  function descOf(s) { return s.custom ? t('rules.custom.desc') : I.pick(s, 'desc'); }      // 自定义规则集的说明: 后端给的是固定中文, 这里用词典
  function blobOf(s) {                                       // 搜索用 (中英文名称/说明都能搜到)
    if (!s._blob) s._blob = [s.name, s.name_en, s.desc, s.desc_en, s.tag, s.repo].filter(Boolean).join(' ').toLowerCase();
    return s._blob;
  }
  function rank(s) { return s.essential ? 0 : s.custom ? 1 : 2; }
  /* 列头排序用的值 (数字用原始数据, 不是格式化后的「12 MB」) */
  function srcOf(s) { return s.custom ? t('rules.src.custom') : s.repo; }                  // 来源列显示的就是这个; 内置的没有仓库 = 空, 排在最后
  function stOf(s) { return (s.present ? 0 : s.enabled ? 1 : 2) * 1e13 + (s.present ? s.bytes : 0); }       // 状态: 已下载 (再按大小) → 已启用但没下载 → 未下载; 用后端的状态, 任务进行中不会让行跳来跳去
  function own(o, k) { return Object.prototype.hasOwnProperty.call(o, k); }
  function pickFilter(v) { return FILTERS.indexOf(v) >= 0 ? v : 'all'; }
  function withHelp(node, topic) { return h('span', { class: 'rl-hp' }, node, ui.help(topic)); }
  /* 当前页的范围: 总数变了才更新分页条 (它每次更新都会重建按钮, 键盘焦点会丢) */
  function pageOf(total) {
    var size = pg.size(), page = pg.page(), pages = Math.max(1, Math.ceil(total / size));
    if (total !== pgTotal) { pgTotal = total; return pg.update(total); }
    if (page > pages) page = pages;
    return { start: (page - 1) * size, end: Math.min(total, page * size) };
  }
  /* 用户改了筛选 / 搜索: 回到第 1 页 */
  function firstPage() { if (pg.page() !== 1) pg.setPage(1); else render(); }
  /* 翻页以后, 如果列表的开头已经滚出了屏幕, 滚回来 */
  function toTop(node) {
    var sc = TP.byId('scroll'), r, s;
    if (!sc || !node) return;
    r = node.getBoundingClientRect(); s = sc.getBoundingClientRect();
    if (r.top < s.top) sc.scrollTop += r.top - s.top - 8;
  }

  /* 当前显示的启用状态: 任务进行中显示「目标状态」 */
  function shownOn(s) { var p = pending[s.tag]; return p === 'on' ? true : p === 'off' ? false : !!s.enabled; }

  /* essential 排最前, 然后自定义, 然后其余按名称排序 */
  function visible() {
    var q = flt.q, pred = PRED[flt.f] || PRED.all, col;
    try { col = new Intl.Collator(I.lang, { numeric: true, sensitivity: 'base' }); } catch (e) { col = { compare: function (a, b) { return a < b ? -1 : a > b ? 1 : 0; } }; }
    return data.sets.filter(function (s) { return pred(s) && (!q || blobOf(s).indexOf(q) >= 0); }).sort(function (a, b) {
      return rank(a) - rank(b) || col.compare(nameOf(a), nameOf(b)) || (a.tag < b.tag ? -1 : a.tag > b.tag ? 1 : 0);
    });
  }

  /* ================= 加载 ================= */
  async function load() {
    var my, r, sets;
    if (S.locked) return;
    my = ++seq;
    try {
      r = await TP.helper('GET', '/api/rules', { timeout: 20000 });
    } catch (e) {
      if (my !== seq) return;
      if (e && e.kind === 'auth') return;
      if (data) ui.toast(TP.errMsg(e), 'err'); else err = e;                   // 已有数据时保留, 只提示
      render();
      return;
    }
    if (my !== seq) return;
    var seen = {};
    sets = (Array.isArray(r && r.sets) ? r.sets : []).filter(function (s) { if (!s || typeof s !== 'object' || s.tag == null || s.tag === '' || seen[s.tag]) return false; seen[s.tag] = 1; return true; }).map(function (s) {
      s.tag = String(s.tag); s.present = !!s.present; s.enabled = !!s.enabled; s.essential = !!s.essential; s.custom = !!s.custom;
      s.bytes = +s.bytes || 0; s.updated = +s.updated || 0; s.repo = s.repo == null ? '' : String(s.repo); s.policy = s.policy ? String(s.policy).toLowerCase() : '';
      return s;
    });
    data = { sets: sets, updated: +(r && r.updated) || 0 }; err = null;
    render();
  }

  /* ================= 渲染 ================= */
  function render() {
    if (!el.tbody || !active()) return;
    renderHead(); renderChips(); renderRows();
  }
  V.render = render;

  function renderHead() {
    var ts = data && data.updated ? data.updated : +(S.state && S.state.env && S.state.env.rules_updated) || 0;
    el.upd.hidden = !data && !ts;
    setText(el.upd, ts ? t('rules.updated', { when: fmt.rel(ts) }) : t('rules.neverUpdated'));
    ui.avail(el.addBtn, TP.why.helper());
  }

  function renderChips() {
    var sets = data ? data.sets : [], n = { all: sets.length, enabled: 0, missing: 0, custom: 0 };
    sets.forEach(function (s) { if (s.enabled) n.enabled++; if (!s.present) n.missing++; if (s.custom) n.custom++; });
    FILTERS.forEach(function (f) { setText(chips[f]._n, n[f]); chips[f].setAttribute('aria-pressed', flt.f === f ? 'true' : 'false'); });
    el.chips.hidden = !data;
  }

  function resetFilters() { flt.q = ''; flt.f = 'all'; el.q.value = ''; TP.prefs.set(PK.filter, undefined); firstPage(); }

  function renderRows() {
    var items, text, pr;
    if (!data) {                                           // 还没有数据: 加载中 / 失败
      el.wrap.hidden = true; setText(el.count, '');
      if (err) el.empty.show({ icon: 'warning', text: err.kind === 'unreachable' ? (TP.why.helper() || TP.errMsg(err)) : TP.errMsg(err), action: { label: t('common.retry'), icon: 'refresh', fn: function () { return load(); } } });
      else el.empty.show({ icon: 'refresh', text: t('rules.loading') });
      return;
    }
    items = so.apply(visible());                           // 筛选 → 排序 (整张表, 不只是当前页) → 分页; 没有选排序时 apply 原样返回
    el.wrap.hidden = !items.length;
    pr = pageOf(items.length);
    ui.syncList(el.tbody, items.slice(pr.start, pr.end), function (s) { return s.tag; }, makeRow, updateRow);
    text = flt.q || flt.f !== 'all' ? t('rules.countOf', { shown: fmt.num(items.length), total: fmt.num(data.sets.length) }) : t('rules.count', { n: data.sets.length, num: fmt.num(data.sets.length) });
    setText(el.count, data.sets.length ? text : '');
    if (items.length) { el.empty.hide(); return; }
    if (!data.sets.length) el.empty.show({ icon: 'library', text: t('rules.empty.none'), hint: t('rules.empty.noneHint') });
    else if (flt.f === 'custom' && !flt.q) el.empty.show({ icon: 'plus', text: t('rules.empty.custom'), hint: t('rules.empty.customHint'), action: { label: t('rules.add'), icon: 'plus', fn: function () { return openAdd(); } } });
    else el.empty.show({ icon: 'search', text: t('rules.empty.noMatch'), hint: t('rules.empty.noMatchHint'), action: { label: t('rules.empty.reset'), icon: 'x', fn: resetFilters } });
  }

  /* ---------- 一行 ---------- */
  function polBadge(p) {
    var v = String(p).toLowerCase();
    return h('span', { class: 'badge rl-pol r-' + (own(POL_ICON, v) ? v : 'x'), title: t('rules.pol.title') }, own(POL_ICON, v) ? ui.icon(POL_ICON[v], 13, 'ci') : null, TP.name.route(v));
  }

  function makeRow() {
    var r = {}, row;
    r.sw = h('input', { type: 'checkbox', role: 'switch' });
    r.name = h('b', { class: 'rl-n' });
    r.badges = h('span', { class: 'rl-badges' });
    r.help = ui.help(HT.essential, { size: 14 }); r.help.hidden = true;
    r.desc = h('div', { class: 'muted sm rl-d' });
    r.tag = h('span', { class: 'rl-tag' });
    r.src = h('div', { class: 'rl-src' });
    r.st = h('div', { class: 'rl-st' });
    r.del = ui.ibtn('delete', t('rules.del.btn'), { cls: 'danger-t' });
    r.tdTag = h('td', { class: 'rl-c-tag' }, r.tag);
    r.tdSrc = h('td', { class: 'rl-c-src' }, r.src);
    r.tdSt = h('td', { class: 'rl-c-st' }, r.st);
    row = h('tr', { class: 'rl-row' },
      h('td', { class: 'rl-c-sw' }, h('label', { class: 'sw' }, r.sw, h('span', { class: 'sw-ui' }))),
      h('td', { class: 'rl-c-name' }, h('div', { class: 'rl-name-row' }, r.name, r.badges, r.help), r.desc),
      r.tdTag, r.tdSrc, r.tdSt,
      h('td', { class: 'rl-c-act' }, r.del));
    row._r = r;
    ui.switchAct(r.sw, function () { return shownOn(row._s); }, function (want) { return toggle(row._s, want); });
    ui.act(r.del, function () { return remove(row._s); });
    return row;
  }

  function updateRow(row, s) {
    var r = row._r, name = nameOf(s), busy = pending[s.tag] || '', why = TP.why.helper(), on = shownOn(s), swWhy, st, dl;
    row._s = s;
    var sig = [I.lang, name, descOf(s), s.repo, s.present, s.bytes, s.updated, s.enabled, s.essential, s.custom, s.policy, busy, why, Math.floor(Date.now() / 60000)].join('|');
    if (row._sig === sig) return;
    row._sig = sig;
    setText(r.name, name);
    TP.clear(r.badges);
    if (s.essential) r.badges.appendChild(ui.chip(t('rules.badge.essential'), 'info', 'lock'));
    if (s.custom) r.badges.appendChild(ui.chip(t('rules.badge.custom')));
    r.help.hidden = !s.essential;
    setText(r.desc, descOf(s)); r.desc.hidden = !r.desc.textContent;
    setText(r.tag, s.tag);
    r.tdTag.setAttribute('data-l', t('rules.col.tag')); r.tdSrc.setAttribute('data-l', t('rules.col.src')); r.tdSt.setAttribute('data-l', t('rules.col.st'));

    TP.clear(r.src);                                         // 来源: 内置 = 仓库; 自定义 = 「自定义链接」 + 路由策略
    if (s.custom) r.src.appendChild(h('span', { class: 'rl-repo' }, t('rules.src.custom')));
    else r.src.appendChild(h('span', { class: 'rl-repo' }, s.repo || '—'));
    if (s.policy) r.src.appendChild(polBadge(s.policy));

    TP.clear(r.st);                                          // 状态
    if (busy) st = ['', 'refresh', t('rules.st.pending'), ''];
    else if (s.present) st = ['ok', 'success', t('rules.st.have', { size: fmt.bytes(s.bytes) }), s.updated > 0 ? t('rules.updated', { when: fmt.rel(s.updated) }) : ''];
    else if (s.enabled) st = ['warn', 'warning', t('rules.st.missingOn'), ''];
    else st = ['muted', 'download-cloud', t('rules.st.missing'), ''];
    r.st.className = 'rl-st ' + st[0];
    r.st.appendChild(ui.icon(st[1], 14, 'ci' + (busy ? ' rl-spin' : '')));
    r.st.appendChild(h('div', { class: 'rl-st-t' }, h('span', null, st[2]), st[3] ? h('div', { class: 'muted sm' }, st[3]) : null));

    r.sw.setAttribute('aria-label', t('rules.sw.aria', { name: name }));
    if (r.sw.checked !== on) r.sw.checked = on;
    swWhy = s.essential ? t('rules.essential.why') : s.custom ? t('rules.custom.alwaysOn') : (why || (busy ? t('rules.busy') : ''));
    ui.avail(r.sw, swWhy);
    row.classList.toggle('is-pending', !!busy);

    r.del.hidden = !s.custom;                                // 只有自定义规则集可以删除
    dl = t('rules.del.aria', { name: name });
    r.del.setAttribute('aria-label', dl); r.del._tip = dl;
    ui.avail(r.del, s.custom ? (why || (busy ? t('rules.busy') : '')) : '');
    if (!r.del._un) r.del.title = dl;
  }

  /* ================= 启用 / 停用 ================= */
  async function toggle(s, want) {
    var why = TP.why.helper(), name = nameOf(s), ok;
    if (why) { ui.toast(why, 'warn'); return; }
    if (pending[s.tag]) { ui.toast(t('rules.busy'), 'warn'); return; }
    ok = await ui.confirmDialog(want
      ? { title: t('rules.on.title'), message: t('rules.on.msg', { name: name }), detail: [t('rules.on.d1', { tag: s.tag }), t('rules.on.d2')], confirmText: t('rules.on.go'), kind: 'success' }
      : { title: t('rules.off.title'), message: t('rules.off.msg', { name: name }), detail: [t('rules.off.d1'), t('rules.off.d2')], confirmText: t('rules.off.go'), kind: 'warning' });
    if (!ok) return;
    pending[s.tag] = want ? 'on' : 'off'; render();
    try {
      await TP.jobs.runInDock(t(want ? 'rules.on.job' : 'rules.off.job', { name: name }), function () { return TP.helper('POST', '/api/rules/toggle', { form: { tag: s.tag, on: want ? 1 : 0 } }); });
      await load();                                          // 成功或失败都以后端的实际状态为准
    } finally { delete pending[s.tag]; render(); }
  }

  /* ================= 删除自定义规则集 ================= */
  async function remove(s) {
    var why = TP.why.helper(), name = nameOf(s), ok;
    if (why) { ui.toast(why, 'warn'); return; }
    if (!s.custom) return;
    if (pending[s.tag]) { ui.toast(t('rules.busy'), 'warn'); return; }
    ok = await ui.confirmDialog({ title: t('rules.del.title'), message: t('rules.del.msg', { name: name }), detail: [t('rules.del.d1'), t('rules.del.d2')], confirmText: t('common.delete'), danger: true });
    if (!ok) return;
    pending[s.tag] = 'del'; render();
    try {
      await TP.jobs.runInDock(t('rules.del.job', { name: name }), function () { return TP.helper('POST', '/api/rules/custom/delete', { form: { tag: s.tag } }); });
      await load();
    } finally { delete pending[s.tag]; render(); }
  }

  /* ================= 添加规则集链接 ================= */
  function openAdd() {
    var why = TP.why.helper();
    if (why) { ui.toast(why, 'warn'); return Promise.resolve(); }
    var name, url, nameMsg, urlMsg, polMsg, pol, form, box, api, working = false, lastCard = null;
    name = h('input', { class: 'inp', type: 'text', maxlength: '40', autocomplete: 'off', spellcheck: 'false', placeholder: t('rules.add.namePh'), 'aria-label': t('rules.add.name') });
    url = h('input', { class: 'inp', type: 'text', inputmode: 'url', autocomplete: 'off', spellcheck: 'false', placeholder: t('rules.add.urlPh'), 'aria-label': t('rules.add.url') });
    nameMsg = h('div', { class: 'fld-h', 'aria-live': 'polite' }); urlMsg = h('div', { class: 'fld-h', 'aria-live': 'polite' });
    polMsg = h('div', { class: 'fld-h' });

    function dup(v) { var lv = v.toLowerCase(); return data && data.sets.some(function (s) { return s.custom && (nameOf(s).toLowerCase() === lv || s.tag.toLowerCase() === lv); }); }
    function paint(box2, cls, text) { TP.setCls(box2, 'fld-h' + (cls ? ' ' + cls : '')); setText(box2, text || ''); }
    function vName(force) {
      var v = name.value.trim(), e = '';
      if (!v) e = force ? t('rules.add.err.nameEmpty') : '';
      else if (!NAME_RE.test(v)) e = t('rules.add.err.nameFormat');
      else if (dup(v)) e = t('rules.add.err.nameDup');
      paint(nameMsg, e ? 'bad-t' : '', e);
      return !e && !!v;
    }
    function parseUrl(v) { try { return new URL(v); } catch (e) { return null; } }
    function vUrl(force) {
      var v = url.value.trim(), u = v ? parseUrl(v) : null, e = '', w = [];
      if (!v) e = force ? t('rules.add.err.urlEmpty') : '';
      else if (!u || !u.hostname) e = t('rules.add.err.urlInvalid');
      else if (u.protocol !== 'http:' && u.protocol !== 'https:') e = t('rules.add.err.urlScheme');
      else {                                                 // 只是提醒, 不拦截: 后端会检查下载到的文件是不是有效的 .srs
        if (u.protocol === 'http:') w.push(t('rules.add.warn.http'));
        if (!/\.srs$/i.test(u.pathname)) w.push(t('rules.add.warn.ext'));
      }
      paint(urlMsg, e ? 'bad-t' : w.length ? 'warn-t' : '', e || w.join(' '));
      return !e && !!v;
    }
    /* 路由策略: 没有固定出口 / 自动线路 时对应选项「暂不可用」(点击说明原因) */
    pol = ui.seg(t('rules.add.policy'), [
      { v: 'pin', label: L('name.policy.PIN'), icon: 'pin' }, { v: 'auto', label: L('name.policy.Global'), icon: 'auto' }, { v: 'direct', label: L('name.policy.direct'), icon: 'direct' }
    ], function (v) { pol.set(v); polText(); });
    function polText() { setText(polMsg, t('rules.add.pol.' + (pol.cur() || 'direct'))); }
    function polAvail() { pol.avail('pin', TP.hasPinPool() ? '' : TP.why.pin()); pol.avail('auto', TP.hasAutoPool() ? '' : TP.why.auto()); }
    polAvail();
    pol.set(TP.hasPinPool() ? 'pin' : TP.hasAutoPool() ? 'auto' : 'direct'); polText();
    name.addEventListener('input', function () { vName(false); });
    url.addEventListener('input', function () { vUrl(false); });

    box = h('div', { class: 'rl-jobbox' });
    form = h('form', { class: 'mform rl-form', novalidate: true },
      h('p', { class: 'muted' }, t('rules.add.intro'), ' ', ui.help(HT.custom)),
      ui.field(t('rules.add.name'), name, t('rules.add.nameHint')), nameMsg,
      ui.field(t('rules.add.url'), url, t('rules.add.urlHint')), urlMsg,
      h('div', { class: 'fld' }, h('span', { class: 'fld-l' }, t('rules.add.policy'), ui.help(HT.policy, { size: 14 })), pol.el, polMsg));
    api = ui.modal({
      title: t('rules.add.title'), icon: 'plus', iconKind: 'pri', size: 'md', body: h('div', null, box, form),
      dirty: function () { return !working && !!(name.value.trim() || url.value.trim()); },
      lock: function () { return working; },
      actions: [
        { label: t('common.cancel'), cancel: true },
        { label: t('rules.add.go'), kind: 'primary', icon: 'check', id: 'go', onClick: async function (a) {
          var okN = vName(true), okU = vUrl(true), why2 = TP.why.helper(), nm, u, pv, pw, ok, card, r;
          if (!okN) { name.focus(); return false; }
          if (!okU) { url.focus(); return false; }
          if (why2) { ui.toast(why2, 'warn'); return false; }
          polAvail(); pv = pol.cur(); pw = pv === 'pin' ? TP.why.pin() : pv === 'auto' ? TP.why.auto() : '';
          if (pw) { ui.toast(pw, 'warn'); return false; }
          nm = name.value.trim(); u = url.value.trim();
          ok = await ui.confirmDialog({
            title: t('rules.add.confirmTitle'), message: t('rules.add.confirmMsg', { name: nm, host: parseUrl(u).host }),
            detail: [t('rules.add.confirmD1', { policy: TP.name.route(pv) }), t('rules.add.confirmD2'), t('rules.add.confirmD3')], confirmText: t('rules.add.confirmGo')
          });
          if (!ok) return false;
          if (lastCard) lastCard.close();
          card = lastCard = ui.taskCard(t('rules.add.jobTitle', { name: nm }));
          box.appendChild(card.el); card.set({ pct: null, msg: t('rules.add.submitting') });
          form.hidden = true; working = true; a.setBusy(true);
          try {
            r = await TP.helper('POST', '/api/rules/custom/add', { form: { name: nm, url: u, policy: pv }, timeout: 30000 });
            if (r && r.job) await TP.jobs.follow(r.job, card);
            card.done(t('rules.add.done'));
          } catch (e) {
            working = false; a.setBusy(false); form.hidden = false;
            if (e && e.kind === 'auth') { card.close(); return false; }
            card.fail(TP.errMsg(e));                          // 进度卡片保留在表单上方, 修改后可再次提交
            return false;
          }
          working = false; a.setBusy(false);
          ui.toast(t('rules.add.toast', { name: nm }), 'ok');
          if (TP.afterApply) TP.afterApply();
          load();
        } }
      ]
    });
    function go(ev) { ev.preventDefault(); var b = api.getBtn('go'); if (b) b.click(); }
    form.addEventListener('submit', go);
    [name, url].forEach(function (inp) { inp.addEventListener('keydown', function (ev) { if (ev.key === 'Enter') go(ev); }); });     // 两个文本框且没有提交按钮: 浏览器不会自动提交
    return api.closed;
  }

  /* ================= 页面 ================= */
  V.init = function (root) {
    pg = ui.pager('rules', { def: 20 });
    pg.onChange(function () { render(); toTop(el.bar); });
    el.upd = h('span', { class: 'muted sm rl-upd', hidden: true });
    el.updBtn = TP.bindRulesBtn(ui.btn(L('rules.updateAll'), { icon: 'download-cloud' }), { labelKey: 'rules.updateAll' });
    el.addBtn = ui.btn(L('rules.add'), { kind: 'primary', icon: 'plus' }); ui.act(el.addBtn, function () { return openAdd(); });

    el.q = h('input', { class: 'inp', type: 'search', placeholder: L('rules.search'), 'aria-label': L('rules.search'), autocomplete: 'off', spellcheck: 'false', on: {
      input: function () { flt.q = el.q.value.trim().toLowerCase(); firstPage(); }
    } });
    el.chips = h('div', { class: 'chips rl-chips', role: 'group', 'aria-label': L('rules.filters.aria'), hidden: true });
    FILTERS.forEach(function (f) {
      var n = h('span', { class: 'fchip-n' }), b = h('button', { class: 'fchip', type: 'button', 'aria-pressed': 'false' }, h('span', null, L('rules.f.' + f)), n);
      b._n = n;
      b.addEventListener('click', function () { flt.f = flt.f === f && f !== 'all' ? 'all' : f; TP.prefs.set(PK.filter, flt.f === 'all' ? undefined : flt.f); firstPage(); });
      chips[f] = b; el.chips.appendChild(b);
    });
    el.count = h('span', { class: 'muted sm rl-count' });

    so = ui.sorter('rules', {
      on: { type: 'num', get: function (s) { return s.enabled ? 0 : 1; } },              // 升序 = 已启用的在前
      name: { get: nameOf }, tag: { get: function (s) { return s.tag; } }, src: { get: srcOf },
      st: { type: 'num', get: stOf }
    }, { onChange: firstPage });
    var thOn = so.th('on', function () { return t('rules.col.on'); }, { class: 'rl-c-sw' });
    thOn.querySelector('.th-t').classList.add('sr');                                       // 开关列很窄: 只显示排序箭头, 列名给读屏 (和原来的 sr 文字一样)
    var thSrc = so.th('src', function () { return t('rules.col.src'); });
    thSrc.appendChild(ui.help(HT.policy, { size: 14 }));
    el.tbody = h('tbody');
    el.wrap = h('div', { class: 'rl-wrap', hidden: true }, h('table', { class: 'rl-tbl' },
      h('thead', null, h('tr', null,
        thOn,
        so.th('name', function () { return t('rules.col.name'); }), so.th('tag', function () { return t('rules.col.tag'); }), thSrc, so.th('st', function () { return t('rules.col.st'); }),
        h('th', { scope: 'col', class: 'rl-c-act' }, h('span', { class: 'sr' }, L('rules.col.act'))))),
      el.tbody));
    el.empty = ui.emptyBox();

    el.bar = h('div', { class: 'toolbar rl-bar' }, el.q, el.chips, el.count);
    root.appendChild(h('div', { class: 'intro' }, h('p', { class: 'muted' }, L('rules.intro'), ' ', ui.help(HT.page))));
    root.appendChild(h('div', { class: 'rl-head' }, el.upd, withHelp(el.updBtn, HT.update), withHelp(el.addBtn, HT.custom)));
    root.appendChild(el.bar);
    root.appendChild(h('section', { class: 'card flush rl-card' }, el.wrap, el.empty.el, pg.el));

    TP.on('lang', function () { render(); });
    TP.on('helper', function (up) { if (!active()) return; if (up && err && !data) load(); else render(); });
    TP.on('state', function () { if (active()) renderHead(); });
    TP.on('rules-updated', function () { if (active()) load(); });                              // 「全部更新」完成: 重新读取 (不在本页时, 下次进入 show() 会重新加载)
    TP.on('auth', function (ok) { if (ok && active()) V.show(); });
    TP.on('prefs', function (d) {                                                              // 别的设备同步过来 / 登录后读到本机的偏好
      if (!d || !(d.all || d.key === PK.filter)) return;
      var f = pickFilter(TP.prefs.get(PK.filter, 'all'));
      if (f !== flt.f) { flt.f = f; render(); }
    });
    setInterval(function () { if (active() && !document.hidden && data) render(); }, 60000);   // 「3 分钟前」之类的相对时间
  };

  V.show = function () {
    render();
    load();
  };
})();
