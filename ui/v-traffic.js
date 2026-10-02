/* enana · v-traffic.js — 流量统计页 (view id: traffic)
 *
 * GET /api/stats?range=today|3d|7d|30d|90d (需登录) -> {range, granularity:'hour'|'day', from, to, since, retention_days,
 *   total:{up,down}, routes:{direct|pin|auto:{up,down}}, series:[{t,up,down,direct,pin,auto}] (旧→新), nodes:[{tag,up,down}] (按总量降序)}
 * 页面: 范围标签 (今日 / 3 天 / 7 天 / 1 个月 / 3 个月) · 合计卡片 · 堆叠柱状图 (纯 CSS 柱子, 没有图表库; 按线路 / 按上传·下载)
 *       + 选中柱子的详情面板 · 线路占比 · 常用节点表 (分页, ui.pager('traffic.nodes', {def: 10})) · 两条说明。每 60 秒自动刷新 (只在本页可见时), 也可手动刷新。
 * 偏好 (TP.prefs): traffic.range (统计范围) · traffic.view (柱子的分法: route / dir); 常用节点表的每页条数 / 页码由 ui.pager 记在 table.traffic.nodes.*。
 * 约定:
 *   - 来自接口的字符串 (节点名) 只用 textContent / h() 渲染。
 *   - 每根柱子的数值同时出现在 悬停 / 键盘焦点提示、选中柱子的详情面板、柱子的 aria-label、一张看不见的数据表 (.sr) 里 —— 不靠悬停。
 *   - 柱子用 flex 排版, 每根的最小宽度由 CSS 决定 (触屏 44px); 放不下时只在图表自己的区域里横向滚动 (一开始滚到最新), 页面不会横向溢出。
 *   - 同一时间最多一个请求在途 (范围切换时只补最新的一次); 刷新时保留所选的柱子 / 分组方式 / 节点表的页码。 */
(function () {
  'use strict';
  var TP = window.TP, S = TP.S, h = TP.h, ui = TP.ui, fmt = TP.fmt, setText = TP.setText, I = window.I18N, t = I.t, L = I.L;
  var V = TP.V.traffic = { id: 'traffic' };

  var RANGES = ['today', '3d', '7d', '30d', '90d'], ROUTES = ['direct', 'pin', 'auto'];
  var POLL_MS = 60000, FRESH_MS = 45000, SLOW_MS = 150;                    // 自动刷新间隔 / 距上次成功多久内不再自动重读 / 多久还没回来才显示加载占位
  var PK = { range: 'traffic.range', view: 'traffic.view' };               // i18n-ignore (偏好键, 不是词典键)
  var HT = { page: 'traffic.page', range: 'traffic.range', view: 'traffic.view', routes: 'traffic.routes', nodes: 'traffic.nodes', est: 'traffic.estimate', keep: 'traffic.retention' };   // i18n-ignore (「!」说明的话题: 词典键是 help.<话题>.*)
  var UNITS = ['B', 'KB', 'MB', 'GB', 'TB'], YMD = /^\d{4}-\d{2}-\d{2}$/;
  var STEPS_H = [1, 2, 3, 4, 6, 8, 12], STEPS_D = [1, 2, 3, 4, 5, 7, 10, 14, 15, 30];     // x 轴标签的间隔 (小时必须能整除 24)

  var el = {}, built = false, tabs = null, seg = null, pg = null, pgTotal = -1;
  var cur = { range: rangeOf(TP.prefs.get(PK.range, 'today')), mode: viewOf(TP.prefs.get(PK.view, 'route')) };
  var view = { data: null, m: null, range: '', err: null, at: 0 };         // 最近一次成功的响应 (m = 整理后的模型) / 它对应的范围 / 最近一次失败
  var sel = { key: '', user: false };                                     // 选中的柱子 (user=false: 自动选最新有数据的那根)
  var ld = { busy: false, again: false, range: '', kind: '', slow: false, p: null, at: 0, timer: 0 };

  /* ================= 小工具 ================= */
  function active() { return TP.tab === 'traffic'; }
  function rangeOf(v) { return RANGES.indexOf(v) >= 0 ? v : 'today'; }
  function viewOf(v) { return v === 'dir' ? 'dir' : 'route'; }
  function withHelp(node, topic) { return h('span', { class: 'trf-hp' }, node, ui.help(topic)); }
  /* 常用节点表当前页的范围: 总数变了才更新分页条 (它每次更新都会重建按钮, 键盘焦点会丢) */
  function pageOf(total) {
    var size = pg.size(), page = pg.page(), pages = Math.max(1, Math.ceil(total / size));
    if (total !== pgTotal) { pgTotal = total; return pg.update(total); }
    if (page > pages) page = pages;
    return { start: (page - 1) * size, end: Math.min(total, page * size) };
  }
  function toTop(node) {                                                    // 翻页以后, 如果表格的开头已经滚出了屏幕, 滚回来
    var sc = TP.byId('scroll'), r, s;
    if (!sc || !node) return;
    r = node.getBoundingClientRect(); s = sc.getBoundingClientRect();
    if (r.top < s.top) sc.scrollTop += r.top - s.top - 8;
  }
  function n0(v) { v = +v; return v > 0 && isFinite(v) ? Math.round(v) : 0; }
  function sumOf(a, k) { var s = 0, i; for (i = 0; i < a.length; i++) s += a[i][k]; return s; }
  function bytes(n) { return fmt.bytes(n); }
  function exact(n) { return t('traffic.exact', { n: n, num: fmt.num(n) }); }
  function routeName(k) { return TP.name.route(k); }
  function pctText(x) {
    if (!(x > 0)) return fmt.num(0, { style: 'percent' });
    if (x < 0.001) return '<' + fmt.num(0.001, { style: 'percent', maximumFractionDigits: 1 });
    return fmt.num(x, { style: 'percent', maximumFractionDigits: x < 0.1 ? 1 : 0 });
  }
  function reduceMotion() { try { return !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches); } catch (e) { return false; } }
  /* 'YYYY-MM-DD' -> 「10月2日」 / "Oct 2" (没有星期, 给 x 轴用); 格式化器按语言缓存 */
  var shortFmt = { lang: '', f: null };
  function dayShort(ymd) {
    var m = YMD.test(ymd) ? ymd.split('-') : null;
    if (!m) return String(ymd);
    if (!shortFmt.f || shortFmt.lang !== I.lang) { shortFmt.lang = I.lang; try { shortFmt.f = new Intl.DateTimeFormat(I.lang, { month: 'short', day: 'numeric' }); } catch (e) { shortFmt.f = null; } }
    var d = new Date(+m[0], +m[1] - 1, +m[2]);
    return shortFmt.f ? shortFmt.f.format(d) : (+m[1]) + '/' + (+m[2]);
  }

  /* ================= 数据整理 ================= */
  /* 把一个整数上界取成「好看」的刻度: 单位按最大值选 (B / KB / MB / GB / TB), 步长取 {1, 2, 2.5, 5} × 10^k, 使刻度线不超过 4 条 */
  function niceAxis(max) {
    var u = 0, m = max, mul = [1, 2, 2.5, 5], base, step = 0, n, e, i, f, ticks = [];
    while (m >= 1024 && u < 4) { m /= 1024; u++; }
    base = Math.pow(10, Math.floor(Math.log10(m / 4)));
    for (e = 0; e < 4 && !step; e++) for (i = 0; i < 4 && !step; i++) if (Math.ceil(m / (mul[i] * base * Math.pow(10, e)) - 1e-9) <= 4) step = mul[i] * base * Math.pow(10, e);
    if (!step) step = m || 1;
    n = Math.max(1, Math.ceil(m / step - 1e-9)); f = Math.pow(1024, u);
    for (i = 1; i <= n; i++) ticks.push(i * step * f);
    return { u: u, step: step, n: n, max: Math.max(n * step * f, max), ticks: ticks };
  }
  function axisText(v, u) {
    if (!(v > 0)) return '0';
    var x = v / Math.pow(1024, u);
    return fmt.num(x, { maximumFractionDigits: x < 10 ? 2 : x < 100 ? 1 : 0 }) + ' ' + UNITS[u];
  }

  /* 响应 -> 模型; 格式不对就抛错 (按「读取失败」处理) */
  function buildModel(r, range) {
    if (!r || typeof r !== 'object' || !Array.isArray(r.series)) throw TP.mkErr('api', t('error.generic'));
    var hour = r.granularity === 'hour' || (r.granularity !== 'day' && range === 'today'), since = YMD.test(r.since || '') ? String(r.since) : '';
    var from = String(r.from || ''), to = String(r.to || ''), max = 1, peak = null, routes = {}, nodes, i, k, x;
    var buckets = r.series.map(function (s, idx) {
      s = s || {};
      var up = n0(s.up), down = n0(s.down), key = String(s.t == null ? idx : s.t), b = { i: idx, key: key, up: up, down: down, total: up + down, direct: n0(s.direct), pin: n0(s.pin), auto: n0(s.auto), pre: !hour && !!since && key < since };
      b.top = Math.max(b.total, b.direct + b.pin + b.auto);
      return b;
    });
    var total = r.total ? { up: n0(r.total.up), down: n0(r.total.down) } : { up: sumOf(buckets, 'up'), down: sumOf(buckets, 'down') };
    ROUTES.forEach(function (rk) { x = (r.routes && r.routes[rk]) || {}; routes[rk] = { up: n0(x.up), down: n0(x.down) }; routes[rk].total = routes[rk].up + routes[rk].down; });
    nodes = (Array.isArray(r.nodes) ? r.nodes : []).filter(function (n) { return n && n.tag != null; }).map(function (n) { var up = n0(n.up), down = n0(n.down); return { tag: String(n.tag), up: up, down: down, total: up + down }; })
      .filter(function (n) { return n.total > 0; }).sort(function (a, b) { return b.total - a.total; });
    for (i = 0; i < buckets.length; i++) { if (buckets[i].top > max) max = buckets[i].top; if (!peak || buckets[i].total > peak.total) peak = buckets[i]; }
    var covered = hour ? 1 : buckets.filter(function (b) { return !b.pre; }).length;
    var m = {
      range: range, hour: hour, from: from, to: to, since: since, retention: n0(r.retention_days) || 92, buckets: buckets, total: total, sum: total.up + total.down, routes: routes, routesSum: 0,
      nodes: nodes, nodesSum: sumOf(nodes, 'total'), axis: niceAxis(max), peak: peak && peak.total > 0 ? peak : null, covered: covered, cut: !hour && !!since && !!from && since > from
    };
    for (k = 0; k < ROUTES.length; k++) m.routesSum += routes[ROUTES[k]].total;
    m.sig = range + '#' + buckets.map(function (b) { return b.key + ',' + b.up + ',' + b.down + ',' + b.direct + ',' + b.pin + ',' + b.auto; }).join(';');
    return m;
  }
  function bucketOf(key) { var bs = view.m ? view.m.buckets : [], i; for (i = 0; i < bs.length; i++) if (bs[i].key === key) return bs[i]; return null; }
  function defaultKey(m) {
    var i;
    for (i = m.buckets.length - 1; i >= 0; i--) if (m.buckets[i].total > 0) return m.buckets[i].key;
    return m.buckets.length ? m.buckets[m.buckets.length - 1].key : '';
  }
  /* 当前这根柱子是不是「还在统计中」: 小时 = 本地当前小时; 天 = 最后一天 (to = 今天) */
  function isNow(m, b) { return !b.pre && (m.hour ? +b.key === new Date().getHours() : b.i === m.buckets.length - 1); }
  /* 完整的时段名 (详情标题 / aria): 天 = 「今天 · 10月2日 周五」, 小时 = 「今天 · 10月2日 周五 · 21:00–21:59」 */
  function whenLabel(m, b) { return m.hour ? t('traffic.hourLabel', { day: fmt.day(m.to), from: b.key + ':00', to: b.key + ':59' }) : fmt.day(b.key); }
  function barLabel(m, b) {
    var when = whenLabel(m, b);
    if (b.pre) return t('traffic.bar.pre', { when: when });
    if (!b.top) return t('traffic.bar.none', { when: when });
    return t('traffic.bar.aria', { when: when, total: bytes(b.total), down: bytes(b.down), up: bytes(b.up), routes: ROUTES.map(function (k) { return routeName(k) + ' ' + bytes(b[k]); }).join(', ') });
  }

  /* ================= 加载 ================= */
  function viewMode() {
    var d = view.data;
    if (d && d.since === '') return 'empty';                                 // 本机还没有任何统计数据
    if (d && (view.range === cur.range || (ld.busy && !view.err))) return 'data';     // 换范围时, 旧数据先留着 (变淡), 新数据回来再换
    if (view.err) return 'error';
    return 'loading';
  }
  /* kind: show | poll | switch | manual。同一时间只有一个请求; 加载期间范围变了就在它结束后补读最新的范围。 */
  function load(kind) {
    if (S.locked) return Promise.resolve();
    var want = cur.range;
    if (ld.busy) { ld.again = ld.range !== want; return ld.p; }
    ld.busy = true; ld.range = want; ld.kind = kind; ld.slow = false;
    clearTimeout(ld.timer);
    ld.timer = setTimeout(function () { ld.timer = 0; if (ld.busy) { ld.slow = true; render(); } }, SLOW_MS);       // 很快回来的请求不闪加载占位
    ld.p = (async function () {
      var r = null, err = null, m = null;
      try { r = await TP.helper('GET', '/api/stats', { q: { range: want }, timeout: 20000 }); m = buildModel(r, want); }
      catch (e) { err = e || new Error('stats'); }
      ld.busy = false; ld.slow = false; clearTimeout(ld.timer); ld.timer = 0;
      if (want === cur.range) {
        if (!err) { view.data = { since: m.since }; view.m = m; view.range = want; view.err = null; view.at = Date.now(); ld.at = view.at; }
        else if (err.kind !== 'auth') view.err = err;                       // 需要登录: 登录框会处理, 这里什么都不提示
      }
      render();
      if (ld.again) { ld.again = false; return load('switch'); }
    })();
    return ld.p;
  }
  function pollTick() {
    if (!active() || S.locked) return null;
    if (view.range === cur.range && !view.err && Date.now() - ld.at < FRESH_MS) return null;     // 刚读过 (切到本页时已经读了一次)
    return load('poll');
  }

  /* ================= 渲染 ================= */
  function render() {
    if (!built) return;
    var mode = viewMode(), m = view.m, hasData = mode === 'data' && !!m;
    el.panel.setAttribute('aria-labelledby', tabs.btn(cur.range).id);
    el.panel.setAttribute('aria-busy', ld.busy ? 'true' : 'false');
    tabs.set(cur.range);
    renderBar();
    el.skel.hidden = !(mode === 'loading' && ld.slow);
    setText(el.live, mode === 'loading' && ld.slow ? t('traffic.loading') : '');
    el.data.hidden = !hasData;
    el.data.classList.toggle('is-loading', hasData && ld.busy && ld.slow && view.range !== cur.range);
    renderState(mode);
    if (hasData) renderData(m);
    renderNotes();
  }
  function renderBar() {
    var busy = ld.busy && (ld.kind === 'manual' || ld.slow), why = TP.why.helper();
    el.refresh.classList.toggle('is-busy', busy);
    if (busy) el.refresh.setAttribute('aria-busy', 'true'); else el.refresh.removeAttribute('aria-busy');
    ui.avail(el.refresh, why);
    setText(el.updated, view.at ? t('traffic.updated', { time: fmt.clock(view.at) }) : '');
  }
  /* 整页空状态 / 读取失败 (其余状态不显示) */
  function renderState(mode) {
    if (mode === 'empty') {
      var off = TP.actions.proxyOn() === false;
      el.empty.show({ icon: 'chart-column', text: t(off ? 'traffic.empty.text' : 'traffic.empty.textOn'), hint: t('traffic.empty.hint'),
        action: off ? { label: t('traffic.empty.on'), icon: 'power', fn: function () { return TP.actions.setProxy(true); } } : null });
    } else if (mode === 'error') {
      var e = view.err;
      el.empty.show({ icon: e && e.kind === 'unreachable' ? 'wifi-off' : 'warning', text: t('traffic.err.title'), hint: e && e.kind === 'unreachable' ? (TP.why.helper() || TP.errMsg(e)) : TP.errMsg(e),
        action: { label: t('common.retry'), icon: 'refresh', fn: function () { return load('manual'); } } });
    } else el.empty.hide();
  }
  function renderNotes() {
    var months = Math.max(1, Math.round((view.m ? view.m.retention : 92) / 30));
    setText(el.noteKeep, t('traffic.note.keep', { n: months }));
  }

  function renderData(m) {
    var per = m.hour ? fmt.day(m.to) : fmt.day(m.from) + ' – ' + fmt.day(m.to), quiet = m.sum === 0, e = view.err;
    setText(el.periodTxt, t('traffic.period', { period: per }));
    el.since.hidden = !m.cut; if (m.cut) setText(el.sinceTxt, t('traffic.since', { date: fmt.day(m.since) }));
    el.stale.hidden = !e; if (e) setText(el.staleTxt, t('traffic.stale', { time: fmt.clock(view.at), reason: e.kind === 'unreachable' ? (TP.why.helper() || TP.errMsg(e)) : TP.errMsg(e) }));
    renderCards(m);
    el.chartBody.hidden = quiet; el.quiet.el.hidden = !quiet;
    if (quiet) el.quiet.show({ icon: 'chart-column', text: t('traffic.quiet.text'), hint: m.range === '90d' ? '' : t(m.hour ? 'traffic.quiet.hintToday' : 'traffic.quiet.hint') }); else el.quiet.hide();
    el.routesCard.hidden = quiet; el.nodesCard.hidden = quiet;
    if (!quiet) { renderChart(m); renderRoutes(m); renderNodes(m); }
  }

  /* ---- 合计卡片 ---- */
  function statCard(cls, icon, label, value, sub) {
    return h('div', { class: 'trf-stat ' + cls },
      h('div', { class: 'trf-stat-h' }, h('span', { class: 'trf-stat-ic' }, ui.icon(icon, 18)), h('span', { class: 'trf-stat-l' }, label)),
      h('div', { class: 'trf-stat-v' }, value), sub ? h('div', { class: 'trf-stat-s muted sm' }, sub) : null);
  }
  function renderCards(m) {
    ui.memo(el.cards, [m.range, m.total.up, m.total.down, m.covered, m.buckets.length].join('|'), function () {
      var sum = m.sum, avg = !m.hour && m.covered > 0 ? Math.round(sum / m.covered) : 0, f = document.createDocumentFragment();
      f.appendChild(statCard('is-down', 'download', t('traffic.card.down'), bytes(m.total.down), t('traffic.card.share', { pct: pctText(sum ? m.total.down / sum : 0) })));
      f.appendChild(statCard('is-up', 'upload', t('traffic.card.up'), bytes(m.total.up), t('traffic.card.share', { pct: pctText(sum ? m.total.up / sum : 0) })));
      f.appendChild(statCard('is-total', 'chart-column', t('traffic.card.total'), bytes(sum), avg ? t(m.covered < m.buckets.length ? 'traffic.card.avgDays' : 'traffic.card.avg', { size: bytes(avg), n: m.covered }) : null));
      return f;
    });
  }

  /* ---- 柱状图 ---- */
  function legendNode() {
    var items = cur.mode === 'dir' ? [['down', t('traffic.card.down')], ['up', t('traffic.card.up')]] : ROUTES.map(function (k) { return [k, routeName(k)]; });
    return h('ul', { class: 'trf-legend' }, items.map(function (it) { return h('li', null, h('i', { class: 'trf-sw trf-c-' + it[0], 'aria-hidden': 'true' }), h('span', null, it[1])); }));
  }
  function makeBar() {
    var segs = {}, stack = h('span', { class: 'trf-stack' }), lab = h('span', { class: 'trf-xl' }), b;
    ['direct', 'pin', 'auto', 'down', 'up'].forEach(function (k) { segs[k] = h('i', { class: 'trf-seg trf-c-' + k }); stack.appendChild(segs[k]); });
    b = h('button', { class: 'trf-bar', type: 'button', 'aria-pressed': 'false', tabindex: '-1' }, h('span', { class: 'trf-col' }, stack), lab);
    b._segs = segs; b._stack = stack; b._lab = lab; b._sig = ''; b._bk = null;
    return b;
  }
  function updateBar(b, bk) {
    var m = view.m, sig = [bk.up, bk.down, bk.direct, bk.pin, bk.auto, bk.pre ? 1 : 0, m.axis.max, m.hour ? 1 : 0, I.lang].join('|'), rs, ts;
    b._bk = bk;
    if (b._sig !== sig) {
      b._sig = sig;
      b._stack.style.height = bk.top > 0 ? (bk.top / m.axis.max * 100) + '%' : '0';
      rs = bk.direct + bk.pin + bk.auto || 1; ts = bk.total || 1;                         // 每一组的 flex-grow 之和为 1, 柱子正好填满
      ROUTES.forEach(function (k) { b._segs[k].style.flexGrow = bk[k] / rs; });
      b._segs.down.style.flexGrow = bk.down / ts; b._segs.up.style.flexGrow = bk.up / ts;
      setText(b._lab, m.hour ? bk.key + ':00' : dayShort(bk.key));
      b.classList.toggle('is-zero', !bk.top); b.classList.toggle('is-pre', bk.pre);
      b.setAttribute('aria-label', barLabel(m, bk));
    }
    b.classList.toggle('is-now', isNow(m, bk));
  }
  function renderChart(m) {
    var ax = m.axis, sig = I.lang + '|' + ax.u + '|' + ax.step + '|' + ax.n, hadFocus = el.bars.contains(document.activeElement), keep = el.scroll.scrollLeft, ok;
    el.chart.className = 'trf-chart m-' + cur.mode;
    el.inner.style.setProperty('--n', String(m.buckets.length));
    ui.memo(el.legend, cur.mode, legendNode);
    el.sub.textContent = t(m.hour ? 'traffic.chart.byHour' : 'traffic.chart.byDay');
    if (el.yaxis._sig !== sig) {                                                         // y 轴: 刻度线 + 标签 (0 在底部)
      el.yaxis._sig = sig; TP.clear(el.yaxis); TP.clear(el.grid);
      [0].concat(ax.ticks).forEach(function (v) {
        var pos = (v / ax.max * 100) + '%', yt = h('span', { class: 'trf-yt' }, axisText(v, ax.u)), gl = h('i', { class: 'trf-gl' + (v ? '' : ' is-base') });
        yt.style.bottom = pos; gl.style.bottom = pos; el.yaxis.appendChild(yt); el.grid.appendChild(gl);
      });
    }
    ok = sel.user && sel.key && !!bucketOf(sel.key);
    if (!ok) { sel.user = false; sel.key = defaultKey(m); }
    ui.syncList(el.bars, m.buckets, function (b) { return b.key; }, makeBar, updateBar);
    if (el.scroll._rk === view.range) el.scroll.scrollLeft = keep;
    else if (el.scroll.clientWidth) { el.scroll._rk = view.range; el.scroll.scrollLeft = el.scroll.scrollWidth; }       // 换了范围: 滚到最新的一端
    paintSel();
    layout();
    var peak = m.peak;
    el.chart.setAttribute('aria-label', t('traffic.chart.aria', { range: t('traffic.range.' + m.range), gran: t(m.hour ? 'traffic.chart.byHour' : 'traffic.chart.byDay'), total: bytes(m.sum),
      peak: peak ? bytes(peak.total) : bytes(0), at: peak ? (m.hour ? peak.key + ':00' : fmt.day(peak.key)) : '–' }));
    ui.memo(el.sr, m.sig, function () { return srTable(m); });
    renderDetail();
    if (hadFocus && !el.bars.contains(document.activeElement)) { var fb = barByKey(sel.key); if (fb) fb.focus({ preventScroll: true }); }
  }
  function barByKey(key) { var c = el.bars.children, i; for (i = 0; i < c.length; i++) if (c[i]._bk && c[i]._bk.key === key) return c[i]; return null; }
  function paintSel() {
    var c = el.bars.children, i, on;
    for (i = 0; i < c.length; i++) {
      on = !!c[i]._bk && c[i]._bk.key === sel.key;
      c[i].setAttribute('aria-pressed', on ? 'true' : 'false'); c[i].tabIndex = on ? 0 : -1; c[i].classList.toggle('is-sel', on);
    }
  }
  /* x 轴标签: 每根柱子里都有一个, 只留下够疏的几个 (小时: 从 00:00 起每 N 个; 天: 从最新的一天往回数); 顺便决定要不要显示「可以横向滑动」的提示 */
  function layout() {
    var m = view.m, c = el.bars.children, n = c.length, slot, fs, need, steps, step = 1, i;
    if (!built || !m || !n || !el.scroll.clientWidth) return;
    slot = el.bars.offsetWidth / n;
    fs = parseFloat(window.getComputedStyle(c[0]._lab).fontSize) || 12;
    need = fs * (m.hour ? 4.4 : 6.2); steps = m.hour ? STEPS_H : STEPS_D;
    for (i = 0; i < steps.length; i++) { step = steps[i]; if (step * slot >= need) break; }
    for (i = 0; i < n; i++) c[i].classList.toggle('has-l', (m.hour ? i : n - 1 - i) % step === 0);
    el.hint.hidden = !(el.scroll.scrollWidth > el.scroll.clientWidth + 1);
  }
  function ensureVisible(key) {
    var b = barByKey(key), sc = el.scroll, l, r, to = -1;
    if (!b) return;
    l = el.bars.offsetLeft + b.offsetLeft; r = l + b.offsetWidth;
    if (l - 10 < sc.scrollLeft) to = l - 10; else if (r + 10 > sc.scrollLeft + sc.clientWidth) to = r + 10 - sc.clientWidth;
    if (to < 0 && l - 10 >= 0) return;
    to = Math.max(0, to);
    try { sc.scrollTo({ left: to, behavior: reduceMotion() ? 'auto' : 'smooth' }); } catch (e) { sc.scrollLeft = to; }
  }

  /* 选中 (点 / 轻触 / 方向键 / 详情里的 ‹ ›): o.focus = 把焦点放到那根柱子上, o.scroll = 滚动到可见 */
  function select(key, o) {
    o = o || {};
    if (!bucketOf(key)) return;
    sel.key = key; sel.user = true;
    paintSel(); renderDetail();
    if (o.scroll) ensureVisible(key);
    if (o.focus) { var b = barByKey(key); if (b) b.focus({ preventScroll: true }); }
  }
  function stepSel(dir) {
    var m = view.m, b = bucketOf(sel.key), j;
    if (!m || !b) return;
    j = b.i + dir;
    if (j < 0 || j >= m.buckets.length) return;
    select(m.buckets[j].key, { scroll: true });
    setText(el.say, t('traffic.detail.said', { when: whenLabel(m, m.buckets[j]), total: bytes(m.buckets[j].total) }));
  }

  /* ---- 详情 / 悬停提示 (同一份内容) ---- */
  function dRow(cls, label, v, share) {
    return h('div', { class: 'trf-r' + (v ? '' : ' is-zero') },
      h('dt', { class: 'trf-r-k' }, cls ? h('i', { class: 'trf-sw trf-c-' + cls, 'aria-hidden': 'true' }) : null, label),
      h('dd', { class: 'trf-r-v' }, h('b', null, bytes(v)), share == null ? null : h('span', { class: 'trf-r-p muted' }, pctText(share)), h('span', { class: 'trf-r-x muted mono' }, exact(v))));
  }
  function detailBody(m, b, compact) {
    if (b.pre) return h('p', { class: 'muted trf-d-note' }, t('traffic.detail.pre'));
    var rs = b.direct + b.pin + b.auto || 1, ds = b.total || 1;
    var routes = h('dl', { class: 'trf-dl' }, ROUTES.map(function (k) { return dRow(k, routeName(k), b[k], compact ? null : b[k] / rs); }));
    var dirs = h('dl', { class: 'trf-dl' }, dRow('down', t('traffic.card.down'), b.down, compact ? null : b.down / ds), dRow('up', t('traffic.card.up'), b.up, compact ? null : b.up / ds));
    var total = h('dl', { class: 'trf-dl trf-d-total' }, dRow('', t('traffic.card.total'), b.total, null));
    if (compact) return h('div', { class: 'trf-d-body is-compact' }, total, routes, dirs);
    return h('div', { class: 'trf-d-body' }, total, h('div', { class: 'trf-d-cols' }, h('section', null, h('h4', null, t('traffic.stack.route')), routes), h('section', null, h('h4', null, t('traffic.stack.dir')), dirs)));
  }
  function renderDetail() {
    var m = view.m, b = bucketOf(sel.key);
    if (!m || !b) return;
    setText(el.dTitle, whenLabel(m, b));
    el.dNow.hidden = !isNow(m, b);
    ui.avail(el.dPrev, b.i > 0 ? '' : t('traffic.detail.first'));
    ui.avail(el.dNext, b.i < m.buckets.length - 1 ? '' : t('traffic.detail.last'));
    ui.memo(el.dBody, [m.range, b.key, b.up, b.down, b.direct, b.pin, b.auto, b.pre].join('|'), function () { return detailBody(m, b, false); });
  }
  function showTip(b) {
    var m = view.m, bk = b._bk, cr, br, sr, tw, left;
    if (!m || !bk) return;
    TP.clear(el.tip);
    el.tip.appendChild(h('div', { class: 'trf-tip-t' }, whenLabel(m, bk)));
    el.tip.appendChild(detailBody(m, bk, true));
    el.tip.hidden = false;
    cr = el.chart.getBoundingClientRect(); br = b.getBoundingClientRect(); sr = el.scroll.getBoundingClientRect(); tw = el.tip.offsetWidth;
    left = br.right - cr.left + 6;
    if (left + tw > cr.width) left = br.left - cr.left - tw - 6;
    el.tip.style.left = Math.round(Math.max(0, Math.min(left, cr.width - tw))) + 'px';
    el.tip.style.top = Math.round(sr.top - cr.top + 2) + 'px';
  }
  function hideTip() { el.tip.hidden = true; }
  function barOf(node) { return node && node.closest ? node.closest('.trf-bar') : null; }

  /* 看不见的数据表: 读屏用户 (和不用图表的人) 可以逐行读到每个时段的全部数值 */
  function srTable(m) {
    var th = function (k) { return h('th', { scope: 'col' }, t(k)); }, td = function (n) { return h('td', null, bytes(n)); };
    return h('table', null, h('caption', null, t('traffic.table.caption', { range: t('traffic.range.' + m.range) })),
      h('thead', null, h('tr', null, h('th', { scope: 'col' }, t(m.hour ? 'traffic.table.hour' : 'traffic.table.day')), ROUTES.map(function (k) { return h('th', { scope: 'col' }, routeName(k)); }), th('traffic.card.down'), th('traffic.card.up'), th('traffic.card.total'))),
      h('tbody', null, m.buckets.map(function (b) {
        return h('tr', null, h('th', { scope: 'row' }, whenLabel(m, b)), b.pre ? h('td', { colspan: 6 }, t('traffic.detail.pre')) : [td(b.direct), td(b.pin), td(b.auto), td(b.down), td(b.up), td(b.total)]);
      })));
  }

  /* ---- 线路占比 ---- */
  function renderRoutes(m) {
    ui.memo(el.routesBody, m.range + '|' + ROUTES.map(function (k) { return m.routes[k].up + ',' + m.routes[k].down; }).join('|'), function () {
      return h('div', { class: 'trf-rts' }, ROUTES.map(function (k) {
        var r = m.routes[k], share = m.routesSum ? r.total / m.routesSum : 0, bar = h('i');
        bar.style.width = (share * 100) + '%';
        return h('div', { class: 'trf-rt is-' + k },
          h('div', { class: 'trf-rt-n' }, h('span', { class: 'trf-rt-ic' }, ui.icon(TP.POLICY_ICON[k], 18)), h('b', null, routeName(k))),
          h('div', { class: 'trf-rt-b', 'aria-hidden': 'true' }, bar),
          h('div', { class: 'trf-rt-p num' }, pctText(share)), h('div', { class: 'trf-rt-t num' }, h('b', null, bytes(r.total))),
          h('div', { class: 'trf-rt-u muted' }, h('span', { class: 'trf-ud' }, ui.icon('download', 14, 'ci'), h('span', { class: 'sr' }, t('traffic.card.down') + ' '), bytes(r.down)),
            h('span', { class: 'trf-ud' }, ui.icon('upload', 14, 'ci'), h('span', { class: 'sr' }, t('traffic.card.up') + ' '), bytes(r.up))));
      }));
    });
  }

  /* ---- 常用节点 (分页) ---- */
  function renderNodes(m) {
    var all = m.nodes, has = !!(S.state && S.state.servers), map = Object.create(null), pr = pageOf(all.length), list = all.slice(pr.start, pr.end), sig;
    TP.servers().forEach(function (s) { map[s.tag] = s; });
    el.nodesNone.hidden = all.length > 0; el.tblWrap.hidden = !all.length;
    sig = m.range + '|' + pr.start + '|' + list.map(function (n) { return n.tag + ',' + n.up + ',' + n.down + ',' + (map[n.tag] ? map[n.tag].role : has ? '-' : '?'); }).join(';');
    ui.memo(el.tbody, sig, function () {
      var f = document.createDocumentFragment();
      list.forEach(function (n, i) {
        var sv = map[n.tag], share = m.nodesSum ? n.total / m.nodesSum : 0, bar = h('i'), chip = null, no = pr.start + i + 1;
        if (sv) chip = h('span', { class: 'badge ' + (sv.role === 'pin' ? 'pin' : sv.role === 'auto' ? 'auto' : '') }, TP.name.role(sv.role));
        else if (has) chip = h('span', { class: 'badge', title: t('traffic.nodes.goneTip') }, t('traffic.nodes.gone'));
        bar.style.width = (share * 100) + '%';
        f.appendChild(h('tr', null,
          h('td', { class: 'trf-rk num' }, String(no)),
          h('td', { class: 'c-name', 'data-l': '' }, h('div', { class: 'c-name-in' }, h('span', { class: 'trf-rk-in muted' }, no + '.'), h('span', { class: 'srv-n' }, n.tag), chip)),
          h('td', { class: 'num', 'data-l': L('traffic.card.down') }, bytes(n.down)),
          h('td', { class: 'num', 'data-l': L('traffic.card.up') }, bytes(n.up)),
          h('td', { class: 'num', 'data-l': L('traffic.card.total') }, h('b', null, bytes(n.total))),
          h('td', { class: 'trf-sh', 'data-l': L('traffic.col.share') }, h('div', { class: 'trf-share' }, h('span', { class: 'trf-pbar', 'aria-hidden': 'true' }, bar), h('span', { class: 'num trf-pct' }, pctText(share))))));
      });
      return f;
    });
  }

  /* ================= 交互 ================= */
  function pickRange(id) {
    if (RANGES.indexOf(id) < 0 || id === cur.range) return;
    cur.range = id; TP.prefs.set(PK.range, id === 'today' ? undefined : id);
    sel = { key: '', user: false }; view.err = null; hideTip();
    var p = load('switch'); render();                                      // 先发请求再画: 画的时候已经知道「正在加载」, 旧数据不会被当成错的清掉
    if (pg.page() !== 1) pg.setPage(1);                                    // 换了范围: 节点表从第 1 页看起
    return p;
  }
  function setMode(v) {
    if (v !== 'route' && v !== 'dir') return;
    cur.mode = v; seg.set(v); TP.prefs.set(PK.view, v === 'route' ? undefined : v);
    hideTip(); render();
  }

  /* ================= 页面 ================= */
  V.init = function (root) {
    pg = ui.pager('traffic.nodes', { def: 10 });                                                   // i18n-ignore (表格 id)
    pg.onChange(function () { render(); toTop(el.nodesCard); });
    tabs = ui.tabs(L('traffic.range.aria'), RANGES.map(function (r) { return { id: r, label: L('traffic.range.' + r) }; }), pickRange);
    tabs.set(cur.range);
    el.refresh = ui.btn(L('common.refresh'), { icon: 'refresh' }); ui.act(el.refresh, function () { return load('manual'); });
    el.updated = h('span', { class: 'muted sm trf-upd' });

    /* 状态: 屏幕阅读器的加载提示 / 加载占位 / 空状态与错误 */
    el.live = h('div', { class: 'sr', role: 'status' });
    el.skel = h('div', { class: 'trf-skel', 'aria-hidden': 'true', hidden: true },
      h('div', { class: 'trf-skel-row' }, h('i', { class: 'trf-sk' }), h('i', { class: 'trf-sk' }), h('i', { class: 'trf-sk' })), h('i', { class: 'trf-sk trf-sk-chart' }));
    el.empty = ui.emptyBox();

    /* 周期 / 提示 / 卡片 */
    el.periodTxt = h('span'); el.sinceTxt = h('span');
    el.period = h('p', { class: 'trf-period' }, ui.icon('clock', 14, 'ci'), el.periodTxt);
    el.since = h('p', { class: 'trf-since muted sm', hidden: true }, ui.icon('info', 14, 'ci'), el.sinceTxt);
    el.staleTxt = h('span', { class: 'trf-stale-t' });
    var retry = ui.btn(L('common.retry'), { sm: true, icon: 'refresh' }); ui.act(retry, function () { return load('manual'); });
    el.stale = h('div', { class: 'hint warn trf-stale', role: 'status', hidden: true }, ui.icon('warning', 15, 'ci'), el.staleTxt, retry);
    el.cards = h('div', { class: 'trf-stats' });

    /* 柱状图 */
    seg = ui.seg(L('traffic.stack.aria'), [{ v: 'route', label: L('traffic.stack.route') }, { v: 'dir', label: L('traffic.stack.dir') }], TP.safe(setMode), { onSame: function () { } });
    seg.set(cur.mode);
    el.sub = h('span', { class: 'muted sm' });
    el.legend = h('div', { class: 'trf-legend-box' });
    el.yaxis = h('div', { class: 'trf-y', 'aria-hidden': 'true' });
    el.grid = h('div', { class: 'trf-grid', 'aria-hidden': 'true' });
    el.bars = h('div', { class: 'trf-bars' });
    el.inner = h('div', { class: 'trf-inner' }, el.grid, el.bars);
    el.scroll = h('div', { class: 'trf-scroll' }, el.inner);
    el.tip = h('div', { class: 'trf-tip', 'aria-hidden': 'true', hidden: true });
    el.chart = h('div', { class: 'trf-chart m-route', role: 'group' }, el.yaxis, el.scroll, el.tip);
    el.hint = h('p', { class: 'trf-hint muted sm', hidden: true }, ui.icon('chevron-left', 14, 'ci'), h('span', null, L('traffic.scroll.hint')));
    el.dPrev = ui.ibtn('chevron-left', L('traffic.detail.prev')); ui.act(el.dPrev, function () { stepSel(-1); });
    el.dNext = ui.ibtn('chevron-right', L('traffic.detail.next')); ui.act(el.dNext, function () { stepSel(1); });
    el.dTitle = h('b', { class: 'trf-d-t' }); el.dNow = h('span', { class: 'chip info', hidden: true }, L('traffic.partial'));
    el.dBody = h('div', { class: 'trf-d-in' });
    el.detail = h('div', { class: 'trf-detail', role: 'group', 'aria-label': L('traffic.detail.aria') },
      h('div', { class: 'trf-d-head' }, el.dPrev, h('div', { class: 'trf-d-ttl' }, el.dTitle, el.dNow), el.dNext), el.dBody);
    el.sr = h('div', { class: 'sr' });
    el.say = h('div', { class: 'sr', role: 'status' });
    el.quiet = ui.emptyBox();
    el.chartBody = h('div', { class: 'trf-chart-body' }, el.legend, el.chart, el.hint, el.detail, el.say);
    el.chartCard = h('section', { class: 'card trf-card', 'aria-labelledby': 'trf-h-chart' },
      h('div', { class: 'trf-hd' }, h('div', { class: 'trf-hd-t' }, h('h3', { id: 'trf-h-chart' }, L('traffic.chart.title')), el.sub), withHelp(seg.el, HT.view)),
      el.chartBody, el.quiet.el, el.sr);

    /* 线路占比 */
    el.routesBody = h('div');
    el.routesCard = h('section', { class: 'card trf-card', 'aria-labelledby': 'trf-h-routes' },
      h('div', { class: 'trf-hd' }, h('div', { class: 'trf-hd-t' }, h('h3', { id: 'trf-h-routes' }, L('traffic.routes.title')), ui.help(HT.routes), h('span', { class: 'muted sm' }, L('traffic.routes.sub')))), el.routesBody);

    /* 常用节点 */
    el.tbody = h('tbody');
    el.nodesNone = h('p', { class: 'muted trf-none', hidden: true }, L('traffic.nodes.none'));
    el.tblWrap = h('div', { class: 'tbl-wrap' }, h('table', { class: 'tbl rt trf-tbl' },
      h('thead', null, h('tr', null, h('th', { scope: 'col', class: 'trf-rkc num' }, L('traffic.col.rank')), h('th', { scope: 'col' }, L('traffic.col.node')), h('th', { scope: 'col', class: 'num' }, L('traffic.card.down')),
        h('th', { scope: 'col', class: 'num' }, L('traffic.card.up')), h('th', { scope: 'col', class: 'num' }, L('traffic.card.total')), h('th', { scope: 'col' }, L('traffic.col.share')))), el.tbody));
    el.nodesCard = h('section', { class: 'card flush trf-card', 'aria-labelledby': 'trf-h-nodes' },
      h('div', { class: 'trf-hd' }, h('div', { class: 'trf-hd-t' }, h('h3', { id: 'trf-h-nodes' }, L('traffic.nodes.title')), ui.help(HT.nodes), h('span', { class: 'muted sm' }, L('traffic.nodes.sub')))), el.tblWrap, el.nodesNone, pg.el);

    el.data = h('div', { class: 'trf-data', hidden: true }, h('div', { class: 'trf-meta' }, el.period, el.since), el.stale, el.cards, el.chartCard, el.routesCard, el.nodesCard);
    el.panel = h('div', { class: 'trf-panel', role: 'tabpanel' }, el.live, el.skel, el.empty.el, el.data);

    el.noteKeep = h('span');
    el.notes = h('div', { class: 'trf-notes' },
      h('p', { class: 'trf-note muted sm' }, ui.icon('info', 14, 'ci'), el.noteKeep, ui.help(HT.keep, { size: 14 })),
      h('p', { class: 'trf-note muted sm' }, ui.icon('info', 14, 'ci'), h('span', null, L('traffic.note.est')), ui.help(HT.est, { size: 14 })));

    root.appendChild(h('div', { class: 'intro' }, h('p', { class: 'muted' }, L('traffic.intro'), ' ', ui.help(HT.page))));
    root.appendChild(h('div', { class: 'toolbar trf-tools' }, withHelp(tabs.el, HT.range), h('div', { class: 'trf-tools-r' }, el.updated, el.refresh)));
    root.appendChild(el.panel);
    root.appendChild(el.notes);
    built = true;

    /* 柱子: 点 / 轻触 / 焦点 = 选中; 方向键、Home、End 在柱子之间移动; 鼠标悬停和键盘焦点显示详细提示 (触屏不弹) */
    el.bars.addEventListener('click', function (e) { var b = barOf(e.target); if (b && b._bk) select(b._bk.key); });
    el.bars.addEventListener('focusin', function (e) {
      var b = barOf(e.target);
      if (!b || !b._bk) return;
      if (b._bk.key !== sel.key) select(b._bk.key);
      try { if (b.matches(':focus-visible')) showTip(b); } catch (x) { /* 不支持 :focus-visible 时不显示 */ }
    });
    el.bars.addEventListener('focusout', hideTip);
    el.bars.addEventListener('keydown', function (e) {
      var m = view.m, b = bucketOf(sel.key), j;
      if (!m || !b || e.altKey || e.ctrlKey || e.metaKey) return;
      if (e.key === 'ArrowLeft') j = b.i - 1; else if (e.key === 'ArrowRight') j = b.i + 1; else if (e.key === 'Home') j = 0; else if (e.key === 'End') j = m.buckets.length - 1; else return;
      e.preventDefault();
      j = Math.max(0, Math.min(m.buckets.length - 1, j));
      if (j !== b.i) select(m.buckets[j].key, { focus: true, scroll: true });
    });
    el.bars.addEventListener('pointerover', function (e) { if (e.pointerType === 'touch') return; var b = barOf(e.target); if (b) showTip(b); });
    el.bars.addEventListener('pointerleave', function () {
      var f = null;
      try { f = el.bars.querySelector(':focus-visible'); } catch (x) { /* 不支持 :focus-visible */ }
      if (f) showTip(f); else hideTip();
    });
    el.scroll.addEventListener('scroll', hideTip, { passive: true });
    if (window.ResizeObserver) new window.ResizeObserver(function () { layout(); }).observe(el.scroll); else window.addEventListener('resize', layout);
    try { window.matchMedia('(pointer:coarse)').addEventListener('change', layout); } catch (e) { /* 旧浏览器: 忽略 */ }

    ['lang', 'state', 'proxy'].forEach(function (ev) { TP.on(ev, function () { if (active()) render(); }); });
    TP.on('helper', function (up) { if (!active()) return; if (up && view.err && !ld.busy) load('manual'); else render(); });
    TP.on('auth', function (ok) { if (ok && active()) V.show(); });
    TP.on('prefs', function (d) {                                                              // 别的设备同步过来 / 登录后读到本机的偏好
      if (!d || !(d.all || d.key === PK.range || d.key === PK.view)) return;
      var r = rangeOf(TP.prefs.get(PK.range, 'today')), v = viewOf(TP.prefs.get(PK.view, 'route'));
      if (v !== cur.mode) setMode(v);
      if (r !== cur.range) pickRange(r);
    });
    TP.poll(pollTick, POLL_MS, { when: active });
    render();
  };

  V.show = function () {
    if (!built) return;
    render();
    load('show');
    layout();
  };
  V.render = render;
})();
