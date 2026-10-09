/* enana · v-overview.js — 概览页: 首次向导 / 三条线路卡片 (速度·延迟·出口 IP) / 90 秒曲线 / 下载测速 / 环境状态 */
(function () {
  'use strict';
  var TP = window.TP, S = TP.S, h = TP.h, ui = TP.ui, fmt = TP.fmt, setText = TP.setText, I = window.I18N, t = I.t, L = I.L;
  var V = TP.V.overview = { id: 'overview' };
  var HIST = 90, KEYS = ['pin', 'auto', 'direct'];
  var el = {}, RC = {};
  var lat = {}, ipInfo = {}, ipLast = {}, ipFor = {};

  var RT = {
    pin: { name: 'name.policy.PIN', icon: 'pin', desc: 'ov.route.pin.desc', help: 'servers.pin' },
    auto: { name: 'name.policy.Global', icon: 'auto', desc: 'ov.route.auto.desc', help: 'servers.auto' },
    direct: { name: 'name.policy.direct', icon: 'direct', desc: 'ov.route.direct.desc', help: 'overview.direct' }
  };

  function memo(box, sig, build) { return ui.memo(box, sig, build); }
  function active() { return TP.tab === 'overview'; }

  /* ================= 构建 ================= */
  V.init = function (root) {
    el.wiz = h('div', { id: 'wiz' });
    var grid = h('div', { class: 'grid cols3' });
    KEYS.forEach(function (k) { grid.appendChild(routeCard(k)); });

    el.cv = h('canvas', { class: 'chart', role: 'img', 'aria-label': L('ov.chart.aria') });
    var resume = ui.btn(L('ov.resume'), { sm: true, icon: 'play' }); ui.act(resume, function () { return TP.actions.setMonitor(true); });
    el.paused = h('div', { class: 'chart-note', hidden: true },
      ui.icon('pause', 30, 'empty-ic'),
      h('div', null, h('b', null, L('ov.paused.title')), h('div', { class: 'muted sm' }, L('ov.paused.sub'))), resume);
    el.wait = h('div', { class: 'chart-note soft', hidden: true }, ui.icon('activity', 30, 'empty-ic'), h('div', null, L('ov.wait.title'), h('div', { class: 'muted sm' }, L('ov.wait.sub'))));
    var legend = h('div', { class: 'legend' }, KEYS.map(function (k) {
      return h('span', { class: 'lg lg-' + k }, h('i'), L(RT[k].name));
    }));
    var chartCard = h('section', { class: 'card' },
      h('div', { class: 'card-h' }, h('h3', null, L('ov.chart.title'), ui.help('overview.speed')), h('span', { class: 'muted sm' }, L('ov.chart.sub')), TP.monitorSwitch(), legend),
      h('div', { class: 'chart-wrap' }, el.cv, el.paused, el.wait));

    /* 下载测速 */
    el.stBtn = ui.btn(L('ov.st.start'), { kind: 'primary', icon: 'speed' });
    ui.act(el.stBtn, speedTest);
    el.stBar = ui.bar(); el.stBar.set(0);
    el.stBarBox = h('div', { hidden: true }, el.stBar.el);
    el.stOut = h('div', { class: 'st-out' }, h('span', { class: 'muted' }, L('ov.st.hint')));
    el.stHist = h('div', { class: 'st-hist' });
    el.stClr = ui.btn(L('ov.st.hist.clear'), { sm: true, kind: 'ghost', icon: 'delete' }); ui.act(el.stClr, clearHist);
    var stCard = h('section', { class: 'card' },
      h('div', { class: 'card-h' }, h('h3', null, L('ov.st.title'), ui.help('overview.dltest'))),
      h('p', { class: 'muted sm' }, L('ov.st.desc')),
      el.stOut, el.stBarBox, h('div', { class: 'row' }, el.stBtn), el.stHist);
    TP.on('lang', renderHist); renderHist();

    el.env = h('div');
    el.rulesBtn = TP.bindRulesBtn(ui.btn(L('act.rules.update'), { sm: true, icon: 'download-cloud' }));
    el.restartBtn = TP.bindRestartBtn(ui.btn(L('act.restart.label'), { sm: true, icon: 'restart' }));
    var envCard = h('section', { class: 'card' }, h('div', { class: 'card-h' }, h('h3', null, L('ov.env.title'), ui.help('overview.env'))), el.env);

    /* 代理模式: 自动模式 / 全局代理 (和顶栏的小按钮、设置页里的是同一个控件) */
    el.pm = TP.modeControl();
    var modeCard = h('section', { class: 'card pmode-card' }, h('div', { class: 'card-h' }, ui.icon('auto', 20, 'ci'), h('h3', null, L('pmode.label'), ui.help('settings.mode'))), el.pm.el);
    root.appendChild(el.wiz);
    root.appendChild(modeCard);
    root.appendChild(grid);
    root.appendChild(chartCard);
    root.appendChild(h('div', { class: 'grid cols2' }, stCard, envCard));

    window.addEventListener('resize', function () { if (active()) draw(); });
    try {
      var mq = window.matchMedia('(prefers-color-scheme: dark)');
      var redraw = function () { if (active()) draw(); };
      if (mq.addEventListener) mq.addEventListener('change', redraw); else if (mq.addListener) mq.addListener(redraw);
    } catch (e) { /* 忽略 */ }
    TP.on('theme', function () { if (active()) draw(); });

    TP.on('conns', function () { if (active()) { updateSpeed(); draw(); } });
    TP.on('monitor', function () { updateSpeed(); draw(); });
    TP.on('proxies', function () { if (active()) { updateRoutes(); } maybeIp(); });
    TP.on('state', function () { if (active()) { renderEnv(); renderWizard(); updateRoutes(); } });
    TP.on('apps', function () { if (active()) renderWizard(); });
    TP.on('helper', function () { if (active()) { renderEnv(); renderWizard(); } });
    TP.on('clash', function () { if (active()) { updateRoutes(); updateSpeed(); } });
    TP.on('update', function () { if (active()) renderEnv(); });
    TP.on('lang', function () { V.render(); paintDescs(); });
    TP.on('proxy', paintDescs); TP.on('state', paintDescs); paintDescs();
    TP.on('proxy', function () { if (active()) { renderWizard(); renderEnv(); } });
    TP.on('prefs', function (d) { if (d && (d.all || /^ui\.welcome/.test(d.key)) && active()) renderWizard(); });
    setInterval(function () { if (active() && !document.hidden) updateSpeed(); }, 2000);
    TP.poll(testLatency, 10000, { delay: 1500 });
    V.render();
  };

  V.show = function () { V.render(); };
  V.render = function () { renderWizard(); updateRoutes(); updateSpeed(); renderLat(); renderIp(); renderEnv(); draw(); relabelIp(); };
  function relabelIp() {
    ['pin', 'auto'].forEach(function (k) { var b = RC[k] && RC[k].ipBtn; if (!b) return; var lab = t('ov.ip.refresh', { name: t(RT[k].name) }); b.setAttribute('aria-label', lab); b._tip = lab; if (!b._un) b.title = lab; });
  }

  function routeCard(k) {
    var c = RC[k] = {};
    c.down = h('b', { class: 'big' }, '—'); c.up = h('span', { class: 'mid' }, '—');
    c.node = h('div', { class: 'node-n' }); c.sub = h('div', { class: 'muted sm node-s' });
    c.lat = h('span', { class: 'lat' }, '—');
    c.ip = h('span', { class: 'ipv' }, '—'); c.ipx = h('div', { class: 'muted sm' });
    c.note = h('div', { class: 'note', hidden: true });
    c.extra = h('div', { class: 'extra' });
    c.desc = h('div', { class: 'muted sm' });
    var ipRow = null;
    if (k !== 'direct') {
      c.ipBtn = ui.ibtn('refresh', t('ov.ip.refresh', { name: t(RT[k].name) }));
      ui.act(c.ipBtn, function () { return fetchIp(true, true); });
      ipRow = h('div', { class: 'kv-row' }, h('span', { class: 'kv-k' }, L('ov.exitIp')), h('span', { class: 'kv-v' }, c.ip, c.ipx), c.ipBtn);
    }
    c.el = h('section', { class: 'card route r-' + k },
      h('div', { class: 'route-h' }, h('span', { class: 'route-ic' }, ui.icon(RT[k].icon, 20)), h('h3', null, L(RT[k].name), ui.help(RT[k].help))),
      c.desc,
      h('div', { class: 'speed' },
        h('div', null, h('span', { class: 'arrow' }, '↓'), c.down),
        h('div', null, h('span', { class: 'arrow' }, '↑'), c.up)),
      h('div', { class: 'kv-row' }, h('span', { class: 'kv-k' }, L(k === 'direct' ? 'ov.line' : 'ov.node')), h('span', { class: 'kv-v' }, c.node, c.sub), c.extra),
      h('div', { class: 'kv-row' }, h('span', { class: 'kv-k' }, L('ov.latency')), h('span', { class: 'kv-v' }, c.lat)),
      ipRow, c.note);
    return c.el;
  }

  /* 卡片上的一句话说明: 跟着代理开关和模式变 (关闭时一切直连; 全局代理时「直连」只剩本地网络和你手动指定的) */
  function paintDescs() {
    var on = TP.actions.proxyOn(), m = TP.actions.proxyMode();
    KEYS.forEach(function (k) {
      var key = RT[k].desc;
      if (k === 'direct' && on === false) key = 'ov.route.direct.off';
      else if (k === 'direct' && m === 'global') key = 'ov.route.direct.descG';
      else if (k === 'auto' && m === 'global' && on !== false) key = 'ov.route.auto.descG';
      setText(RC[k].desc, t(key));
    });
  }

  /* ================= 线路卡片: 节点 / 速度 ================= */
  function typeLine(tag) {
    var s = S.svMap[tag];
    return s ? (s.type + ' · ' + (s.server ? s.server + ':' + s.port : '')) : ((S.proxies[tag] && S.proxies[tag].type) || '');
  }
  function updateRoutes() {
    var P = S.proxies, pinLeaf = TP.leaf('PIN'), gl = P.Global, glLeaf = TP.leaf('Global');
    var c = RC.pin, ok;
    // 固定出口
    ok = pinLeaf && pinLeaf !== 'direct' && pinLeaf !== 'pin-none';   // pin-none = 没有固定出口 (fail-closed 黑洞), 不是节点
    setText(c.node, ok ? pinLeaf : t('ov.unset')); setText(c.sub, ok ? typeLine(pinLeaf) : '');
    c.note.hidden = !!ok || !S.state || !S.state.servers;
    if (!c.note.hidden && !c.note._b) {
      c.note._b = true;
      c.note.appendChild(h('span', null, L('ov.noPin.note'), ' '));
      var add = ui.btn(L('ov.addServer'), { sm: true, icon: 'plus' }); ui.act(add, function () { TP.goAdd('manual'); });
      c.note.appendChild(add);
    }
    // 自动线路
    c = RC.auto;
    ok = glLeaf && glLeaf !== 'direct';
    setText(c.node, ok ? glLeaf : t('ov.unset'));
    var manual = TP.globalPinned();
    setText(c.sub, ok ? (manual ? t('ov.sub.manual', { line: typeLine(glLeaf) }) : (gl && gl.all && gl.all.indexOf('AUTO') >= 0 ? t('ov.sub.auto', { line: typeLine(glLeaf) }) : typeLine(glLeaf))) : '');
    TP.clear(c.extra);
    if (manual) {
      var back = ui.btn(t('ov.restoreAuto'), { sm: true, icon: 'auto' });
      ui.act(back, async function () {
        var why = TP.why.clash(); if (why) { ui.toast(why, 'warn'); return; }
        var okc = await ui.confirmDialog({ title: t('ov.restore.title'), message: t('ov.restore.msg', { node: gl.now }), detail: t('ov.restore.detail'), confirmText: t('ov.restoreAuto'), rememberKey: 'policy' });
        if (!okc) return;
        await TP.setPolicy('Global', 'AUTO'); ui.toast(t('ov.restore.done'), 'ok');
      });
      c.extra.appendChild(back);
    }
    // 直连
    setText(RC.direct.node, t('ov.localNet')); setText(RC.direct.sub, t('ov.noProxy'));
    renderLat();
  }
  function updateSpeed() {
    var on = S.monitor && S.speedAt > 0 && S.clash !== 'down' && Date.now() - S.speedAt < 6000;      // 数据太旧 / 核心不可用时不显示旧数字
    KEYS.forEach(function (k) {
      var c = RC[k], v = S.speed[k];
      setText(c.down, on ? fmt.rate(v.d) : '—'); setText(c.up, on ? fmt.rate(v.u) : '—');
      c.el.classList.toggle('is-paused', !S.monitor);
    });
  }

  /* ================= 延迟 (每 10 秒, 经 Clash 测 gstatic generate_204) ================= */
  async function testLatency() {
    if (TP.isApplying() || S.clash === 'down') return;
    var jobs = [];
    KEYS.forEach(function (k) {
      var tag = k === 'direct' ? 'direct' : TP.leaf(k === 'pin' ? 'PIN' : 'Global'); if (tag === 'pin-none') tag = '';
      if (!tag || (k !== 'direct' && tag === 'direct')) { lat[k] = { tag: '' }; return; }
      jobs.push(TP.testDelay(tag).then(function (ms) { lat[k] = { tag: tag, ms: ms }; }));
    });
    await Promise.all(jobs);
    renderLat();
  }
  function renderLat() {
    KEYS.forEach(function (k) {
      var c = RC[k], l = lat[k], n = c.lat;
      if (!l || !l.tag || S.clash === 'down') { setText(n, '—'); TP.setCls(n, 'lat'); return; }
      if (l.ms == null) return;
      setText(n, fmt.delay(l.ms));
      TP.setCls(n, 'lat ' + (l.ms < 0 ? 'bad' : l.ms < 150 ? 'good' : l.ms < 400 ? 'mid' : 'bad'));
    });
  }

  /* ================= 出口 IP: 向本机辅助服务要 (它用每条线路各自的出口去查, 结果缓存 10 分钟); 浏览器自己不去访问任何第三方网站 =================
   * GET /api/net/info -> {checked, routes:[{id:'PIN'|'Global', ok, ip, country, region, city, isp, asn, reason}]}
   * 从没查过 / 手动刷新 / 节点换了 -> 先 POST /api/net/refresh (后台任务, 约 3–8 秒) 再读一次。两张卡片共用一次查询。 */
  var ipBusy = null;
  function netRoute(d, k) { var id = k === 'pin' ? 'PIN' : 'Global', rs = (d && d.routes) || [], i; for (i = 0; i < rs.length; i++) if (rs[i] && rs[i].id === id) return rs[i]; return null; }
  function setIpFrom(d) {
    ['pin', 'auto'].forEach(function (k) {
      var r = netRoute(d, k);
      if (!r) ipInfo[k] = { st: 'none' };
      else if (r.ok === false || !r.ip) ipInfo[k] = { st: 'err' };
      else { ipInfo[k] = { st: 'ok', ip: String(r.ip), loc: [r.city, r.region, r.country].filter(function (x, i, a) { return x && a.indexOf(x) === i; }).join(' · '), org: [r.isp, r.asn].filter(Boolean).join(' · ') }; ipFor[k] = TP.leaf(k === 'pin' ? 'PIN' : 'Global'); }
    });
  }
  async function waitNetJob(id) {
    var t0 = Date.now(), j, fails = 0;
    for (;;) {
      try { j = await TP.helper('GET', '/api/job', { q: { id: id }, timeout: 8000 }); fails = 0; }
      catch (e) { if (e.kind === 'api' || e.kind === 'auth' || ++fails > 8) throw e; await TP.sleep(600); continue; }
      if (j.state === 'done') return j;
      if (j.state === 'error') throw TP.mkErr('job', j.msg || '', j);
      if (Date.now() - t0 > 60000) throw TP.mkErr('job', '');
      await TP.sleep(700);
    }
  }
  function fetchIp(refresh, manual) {
    if (ipBusy) return ipBusy;
    if (manual && navigator.onLine === false) { ui.toast(t('ov.ip.offline'), 'warn'); return Promise.resolve(); }
    ipLast.all = Date.now(); ['pin', 'auto'].forEach(function (k) { ipInfo[k] = { st: 'load' }; }); renderIp();
    ipBusy = (async function () {
      try {
        var d = await TP.helper('GET', '/api/net/info'), r;
        if (refresh || !d || !(+d.checked > 0)) {
          r = await TP.helper('POST', '/api/net/refresh');
          if (r && r.job) await waitNetJob(r.job);
          d = await TP.helper('GET', '/api/net/info');
        }
        setIpFrom(d);
      } catch (e) {
        ['pin', 'auto'].forEach(function (k) { ipInfo[k] = { st: 'err' }; });
        if (manual && !(e && e.kind === 'auth')) ui.toast(t('ov.ip.failToast', { name: t(RT.pin.name) + ' / ' + t(RT.auto.name) }), 'warn');
      }
      ipBusy = null; renderIp();
    })();
    return ipBusy;
  }
  function maybeIp() {
    if (S.locked || (!S.proxies.PIN && !S.proxies.Global)) return;
    var first = false, changed = false;
    ['pin', 'auto'].forEach(function (k) {
      var leaf = TP.leaf(k === 'pin' ? 'PIN' : 'Global');
      if (!leaf || leaf === 'direct' || leaf === 'pin-none') return;
      if (!ipInfo[k]) first = true; else if (ipFor[k] && ipFor[k] !== leaf) changed = true;
    });
    if ((first || changed) && (!ipLast.all || Date.now() - ipLast.all > 30000)) fetchIp(changed, false);
  }
  function renderIp() {
    ['pin', 'auto'].forEach(function (k) {
      var c = RC[k], i = ipInfo[k];
      if (!i) { setText(c.ip, '—'); setText(c.ipx, ''); return; }
      if (i.st === 'load') { setText(c.ip, t('ov.ip.loading')); setText(c.ipx, ''); ui.avail(c.ipBtn, t('ov.ip.refreshing')); return; }
      ui.avail(c.ipBtn, '');
      if (i.st === 'none') { setText(c.ip, '—'); setText(c.ipx, ''); return; }
      if (i.st === 'err') { setText(c.ip, t('ov.ip.fail')); setText(c.ipx, t('ov.ip.retry')); return; }
      setText(c.ip, i.ip); setText(c.ipx, [i.loc, i.org].filter(Boolean).join(' · '));
    });
  }

  /* ================= 90 秒曲线 ================= */
  /* 纵轴上限: 先按 1024 进制选单位 (B/KB/MB…), 再在该单位里取 1/2/4/8/10 × 10^n, 4 等分后刻度都是整齐的数 */
  function niceMax(v) {
    var k = Math.max(0, Math.floor(Math.log(v) / Math.log(1024))), u = Math.pow(1024, k), n = v / u;
    var p = Math.pow(10, Math.floor(Math.log(n) / Math.LN10)), m = n / p;
    return (m <= 1 ? 1 : m <= 2 ? 2 : m <= 4 ? 4 : m <= 8 ? 8 : 10) * p * u;
  }
  function draw() {
    var cv = el.cv;
    if (!cv) return;
    el.paused.hidden = S.monitor;
    var anyData = KEYS.some(function (k) { return S.hist[k].length > 1; });
    el.wait.hidden = !S.monitor || anyData;
    var w = cv.clientWidth, hh = cv.clientHeight;
    if (!w || !hh) return;
    var dpr = window.devicePixelRatio || 1, W = Math.round(w * dpr), H = Math.round(hh * dpr);
    if (cv.width !== W || cv.height !== H) { cv.width = W; cv.height = H; }
    var ctx = cv.getContext('2d');
    if (!ctx) return;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0); ctx.clearRect(0, 0, w, hh);
    var cs = getComputedStyle(document.documentElement), font = getComputedStyle(document.body).fontFamily;
    var col = function (n) { return cs.getPropertyValue(n).trim(); };
    var fsz = parseFloat(col('--fs-11')) || 11, padL = fsz > 12 ? 78 : 62, padR = 12, padT = 10, padB = fsz > 12 ? 26 : 22, pw = w - padL - padR, ph = hh - padT - padB, i, y;
    var max = 1024;
    KEYS.forEach(function (k) { S.hist[k].forEach(function (v) { if (v > max) max = v; }); });
    max = niceMax(max);
    ctx.font = fsz + 'px ' + font; ctx.lineWidth = 1; ctx.strokeStyle = col('--line'); ctx.fillStyle = col('--muted');
    ctx.textAlign = 'right'; ctx.textBaseline = 'middle';
    for (i = 0; i <= 4; i++) {
      y = Math.round(padT + ph * i / 4) + 0.5;
      ctx.beginPath(); ctx.moveTo(padL, y); ctx.lineTo(w - padR, y); ctx.stroke();
      ctx.fillText(fmt.rate(max * (1 - i / 4)), padL - 8, y);
    }
    ctx.textBaseline = 'alphabetic'; ctx.textAlign = 'center';
    [[t('ov.chart.x90'), 0], ['-60', 1 / 3], ['-30', 2 / 3], [t('ov.chart.now'), 1]].forEach(function (tk) {
      ctx.textAlign = tk[1] === 0 ? 'left' : tk[1] === 1 ? 'right' : 'center';
      ctx.fillText(tk[0], padL + pw * tk[1], hh - 5);
    });
    if (!S.monitor) return;
    ctx.lineJoin = 'round'; ctx.lineWidth = 2;
    KEYS.forEach(function (k) {
      var a = S.hist[k];
      if (a.length < 2) return;
      ctx.strokeStyle = col('--' + k); ctx.setLineDash(k === 'direct' ? [5, 4] : []);
      ctx.beginPath();
      a.forEach(function (v, j) {
        var x = padL + pw * (HIST - a.length + j) / (HIST - 1), yy = padT + ph * (1 - v / max);
        if (j === 0) ctx.moveTo(x, yy); else ctx.lineTo(x, yy);
      });
      ctx.stroke();
    });
    ctx.setLineDash([]);
    cv.setAttribute('aria-label', t('ov.chart.ariaNow', { list: KEYS.map(function (k) { return t(RT[k].name) + ' ' + fmt.rate(S.speed[k].d + S.speed[k].u); }).join(', ') }));
  }

  /* ================= 下载测速 ================= */
  /* 最近 3 次测速记录: 只存在这台电脑的浏览器里 (本地存储, 不跨设备同步), 最多 3 条, 新的挤掉最旧的; 失败 / 中途停止的不记 */
  var HIST_KEY = 'ov.dl.hist', HIST_MAX = 3;                        // i18n-ignore (本地存储键)
  function readHist() {
    var a = TP.ls.get(HIST_KEY, []);
    return (Array.isArray(a) ? a : []).filter(function (r) { return r && +r.at > 0 && +r.bps > 0; }).slice(0, HIST_MAX);
  }
  function pushHist(rec) { TP.ls.set(HIST_KEY, [rec].concat(readHist()).slice(0, HIST_MAX)); renderHist(); }
  async function clearHist() {
    var ok = await ui.confirmDialog({ title: t('ov.st.hist.clearTitle'), message: t('ov.st.hist.clearMsg'), confirmText: t('ov.st.hist.clearGo'), danger: true });
    if (!ok) return;
    TP.ls.set(HIST_KEY, []); renderHist();
  }
  function renderHist() {
    var a = readHist(), box = el.stHist;
    if (!box) return;
    TP.clear(box);
    if (!a.length) { box.hidden = true; return; }
    box.hidden = false;
    box.appendChild(h('div', { class: 'st-hist-h' }, h('b', null, t('ov.st.hist.title', { n: a.length })), el.stClr));
    box.appendChild(h('ul', { class: 'st-hist-l' }, a.map(function (r, i) {
      var prev = a[i + 1], diff = prev && prev.bps > 0 ? Math.round((r.bps / prev.bps - 1) * 100) : null;
      return h('li', null,
        h('b', { class: 'st-hist-v' }, fmt.mbps(r.bps)),
        diff != null && Math.abs(diff) >= 1 ? h('span', { class: 'chip ' + (diff > 0 ? 'ok' : 'bad'), title: t('ov.st.hist.vsPrev') }, (diff > 0 ? '+' : '') + diff + '%') : null,
        h('span', { class: 'muted sm st-hist-m' }, fmt.dateTime(r.at) + ' · ' + t('ov.st.avg', { sec: fmt.num(r.sec, { minimumFractionDigits: 1, maximumFractionDigits: 1 }), size: fmt.bytes(r.bytes) })),
        h('span', { class: 'badge' }, t(r.on ? (r.mode === 'global' ? 'ov.st.hist.onGlobal' : 'ov.st.hist.onAuto') : 'ov.st.hist.off')));
    })));
  }
  var stCtl = null;
  async function speedTest() {
    if (stCtl) { stCtl.abort(); return; }
    if (navigator.onLine === false) { ui.toast(t('ov.st.offline'), 'warn'); return; }
    var url = (TP.cfg.probe && TP.cfg.probe.speedUrl) || 'https://speed.cloudflare.com/__down?bytes=10000000';
    var m = url.match(/[?&]bytes=(\d+)/), total = m ? +m[1] : 10000000;
    stCtl = new AbortController();
    var timer = setTimeout(function () { if (stCtl) stCtl.abort(); }, 60000), got = 0, t0 = performance.now(), lastUi = 0, stopped = false;
    ui.setBtn(el.stBtn, t('ov.st.stop'), 'pause'); el.stBarBox.hidden = false; el.stBar.set(0);
    TP.clear(el.stOut); el.stOut.appendChild(h('span', { class: 'muted' }, t('ov.st.connecting')));
    try {
      var res = await fetch(url, { cache: 'no-store', signal: stCtl.signal, credentials: 'omit' });
      if (!res.ok) throw new Error('HTTP ' + res.status);
      var len = +res.headers.get('content-length'); if (len > 0) total = len;
      if (res.body && res.body.getReader) {
        var rd = res.body.getReader(), r;
        for (;;) {
          r = await rd.read();
          if (r.done) break;
          got += r.value.length;
          var now = performance.now();
          if (now - lastUi > 120) {
            lastUi = now; el.stBar.set(Math.min(99, got / total * 100));
            TP.clear(el.stOut); el.stOut.appendChild(h('span', null, h('b', { class: 'big' }, fmt.mbps(got / ((now - t0) / 1000))), h('span', { class: 'muted sm' }, '  ' + fmt.bytes(got) + ' / ' + fmt.bytes(total))));
          }
        }
      } else { got = (await res.arrayBuffer()).byteLength; }
      var sec = (performance.now() - t0) / 1000;
      el.stBar.set(100, 'ok');
      TP.clear(el.stOut);
      el.stOut.appendChild(h('span', null, h('b', { class: 'big' }, fmt.mbps(got / sec)), h('span', { class: 'muted sm' }, '  ' + t('ov.st.avg', { sec: fmt.num(sec, { minimumFractionDigits: 1, maximumFractionDigits: 1 }), size: fmt.bytes(got) }))));
      pushHist({ at: Date.now(), bps: got / sec, sec: sec, bytes: got, on: !!(S.state && S.state.proxy && S.state.proxy.enabled), mode: S.state && S.state.proxy && S.state.proxy.mode === 'global' ? 'global' : 'auto' });
      ui.toast(t('ov.st.doneToast', { speed: fmt.mbps(got / sec) }), 'ok', 3000);
    } catch (e) {
      stopped = e && e.name === 'AbortError';
      el.stBar.set(Math.min(99, got / total * 100), 'err');
      TP.clear(el.stOut);
      el.stOut.appendChild(h('span', { class: 'bad-t' }, t(stopped ? 'ov.st.stopped' : 'ov.st.fail')));
      if (!stopped) ui.toast(t('ov.st.failToast'), 'warn');
    } finally {
      clearTimeout(timer); stCtl = null; ui.setBtn(el.stBtn, t('ov.st.again'), 'speed');
    }
  }

  /* ================= 环境状态 ================= */
  function copyBtn(text) { var b = ui.ibtn('copy', t('common.copy') + ': ' + text, { size: 15, cls: 'chk-cp' }); ui.act(b, function () { ui.copy(text); }); return b; }
  function renderEnv() {
    var st = S.state;
    if (!st) { memo(el.env, 'none' + TP.noHelper(), function () { return h('p', { class: 'muted' }, t(TP.noHelper() ? 'ov.env.noHelper' : 'ov.env.loading')); }); return; }
    var e = st.env || {}, p = st.platform || {}, u = S.update, tun = !!(st.proxy && st.proxy.network_mode === 'tun'), spBusy = TP.actions.sysproxyBusy();
    memo(el.env, JSON.stringify([e, Math.floor(Date.now() / 60000), st.version, S.core, p, u.available, u.latest, S.clash, tun, spBusy]), function () {
      var rows = [
        ['ov.env.core', !!e.core, S.core ? S.core.replace(/^sing-box\s*/i, '') : ''],
        ['ov.env.rules', !!e.rules, ''],
        ['ov.env.service', !!e.service, ''],
        ['ov.env.sysproxy', tun || !!e.sysproxy, tun ? t('ov.env.sysproxyTun') : e.sysproxy ? '' : t('ov.env.sysproxyOff')],       // Enhanced/TUN 不使用系统代理, 不算问题
        ['ov.env.shortcut', !!e.shortcut, e.shortcut_cmd || (e.shortcut ? 'enana' : ''), e.shortcut ? t('ov.env.shortcutTip', { path: e.shortcut }) : t('ov.env.shortcutMissing')]       // 值 = 在终端里直接可运行的完整命令 (不是文件路径)
      ];
      var bad = rows.some(function (r) { return !r[1]; }), miss = (e.missing || e.rules_missing || []);
      var upd = +e.rules_updated || 0, stale = upd > 0 && (Date.now() / 1000 - upd) > 14 * 86400;
      return h('div', null,
        h('ul', { class: 'chk' }, rows.map(function (r) {
          var spFix = null;      // 系统代理没指向 enana: 这一行直接给「一键开启」按钮 (不用去终端)
          if (r[0] === 'ov.env.sysproxy' && !r[1]) { spFix = ui.btn(t(spBusy ? 'sysproxy.row.busy' : 'sysproxy.row.go'), { sm: true, icon: 'power', kind: 'success' }); spFix.disabled = spBusy; ui.act(spFix, function () { return TP.actions.fixSysproxy(false); }); }
          return h('li', { class: r[1] ? 'ok' : 'bad' }, h('span', { class: 'ck', 'aria-label': t(r[1] ? 'ov.env.ok' : 'ov.env.problem') }, ui.icon(r[1] ? 'check' : 'x', 13)), h('span', { class: 'chk-n' }, t(r[0])), r[2] ? h('span', { class: 'muted sm mono chk-d', title: r[3] || null }, r[2]) : null, r[2] && r[3] ? copyBtn(r[2]) : null, spFix);
        })),
        h('div', { class: 'kv-row rules-row' },
          h('span', { class: 'kv-k' }, t('ov.env.rulesUpdated')),
          h('span', { class: 'kv-v' }, upd ? (stale ? t('ov.env.rulesStale', { when: fmt.rel(upd) }) : fmt.rel(upd)) : t('ov.env.never')),
          el.rulesBtn),
        h('div', { class: 'kv-row rules-row' },
          h('span', { class: 'kv-k' }, t('ov.env.svcRow')),
          h('span', { class: 'kv-v' }, S.clash === 'ok' ? t('set.proxy.running') : TP.coreStopped() ? t('set.proxy.stopped') : t('set.proxy.unknown')),
          el.restartBtn),
        miss.length ? h('p', { class: 'hint warn' }, t('ov.env.missing', { n: miss.length, list: miss.slice(0, 6).join(', ') + (miss.length > 6 ? ' …' : '') })) : null,
        bad ? h('p', { class: 'hint warn' }, t('ov.env.notReady')) : h('p', { class: 'hint ok' }, t('ov.env.allGood')),
        h('p', { class: 'muted sm' }, [p.os ? fmt.os(p.os) + ' ' + (p.osver || '') + ' · ' + (p.arch || '') : '', st.version ? t('ov.env.dash', { v: st.version }) : ''].filter(Boolean).join(' · '))
      );
    });
  }

  /* ================= 首次使用向导 =================
   * 出现条件: 首次运行 / 还没有服务器。一旦出现过 (started), 就一直显示到用户点「开始使用/稍后再说」,
   * 这样添加服务器后能看到完成度往上走; 页面加载时如果已经全部完成, 则静默收起。 */
  var sawIncomplete = false;
  /* 半隐藏状态: 一个小标签 (进度环 + 「欢迎使用 enana · 已完成 60%」), 不占版面也不挡内容; 点击展开 */
  function ring(pct) {
    var ns = 'http://www.w3.org/2000/svg', R = 9, C = 2 * Math.PI * R, svg = document.createElementNS(ns, 'svg'), a = document.createElementNS(ns, 'circle'), b = document.createElementNS(ns, 'circle');
    svg.setAttribute('viewBox', '0 0 24 24'); svg.setAttribute('width', '24'); svg.setAttribute('height', '24'); svg.setAttribute('class', 'wiz-ring'); svg.setAttribute('aria-hidden', 'true');
    [a, b].forEach(function (c) { c.setAttribute('cx', '12'); c.setAttribute('cy', '12'); c.setAttribute('r', String(R)); c.setAttribute('fill', 'none'); c.setAttribute('stroke-width', '3'); });
    a.setAttribute('class', 'wiz-ring-bg'); b.setAttribute('class', 'wiz-ring-fg');
    b.setAttribute('stroke-dasharray', (C * pct / 100).toFixed(2) + ' ' + C.toFixed(2)); b.setAttribute('transform', 'rotate(-90 12 12)'); b.setAttribute('stroke-linecap', 'round');
    svg.appendChild(a); svg.appendChild(b);
    return svg;
  }
  function peekPill(pct) {
    var b = h('button', { class: 'wiz-peek' + (pct === 100 ? ' is-done' : ''), type: 'button', 'aria-expanded': 'false', title: t('ov.wiz.expand') }, ring(pct), h('span', { class: 'wiz-peek-t' }, h('b', null, t('ov.wiz.title')), h('span', { class: 'muted' }, ' · ' + t('ov.wiz.pct', { pct: pct }))), ui.icon('chevron-down', 16, 'ci'));
    b.addEventListener('click', function () { TP.prefs.set('ui.welcome', 'open'); renderWizard(); });
    return b;
  }
  function renderWizard() {
    var st = S.state, box = el.wiz;
    if (!st) { memo(box, 'none', function () { return null; }); return; }
    if (!S.apps && !TP.noHelper()) return;                         // 应用列表还没读到: 先不判断, 避免误显示
    var servers = st.servers || [], env = st.env || {};
    var empty = !!st.first_run || servers.length === 0;
    var started = TP.prefs.get('ui.welcome.started', TP.ls.get('wiz.started', false));
    if (empty && !started) { started = true; TP.prefs.set('ui.welcome.started', true); }
    var hasPin = servers.some(function (s) { return s.role === 'pin'; }), hasAuto = servers.some(function (s) { return s.role === 'auto'; });
    var envOk = !!(env.core && env.rules && env.service);
    var apps = S.apps, appsScanned = !!(apps && +apps.scanned_at > 0), newN = apps ? (+apps.new_count || 0) : 0, appsOk = appsScanned && newN === 0;
    var proxyOn = TP.actions.proxyOn() === true, pct = [envOk, hasPin, hasAuto, appsOk, proxyOn].filter(Boolean).length * 20, noH = TP.noHelper();
    if (pct < 100) sawIncomplete = true;
    var dismissed = TP.prefs.get('ui.welcome.dismissed', TP.ls.get('wiz.dismissed', false));
    if (!dismissed && !empty && started && pct === 100 && !sawIncomplete) { TP.prefs.set('ui.welcome.dismissed', true); dismissed = true; }   // 早就完成了
    if (dismissed || !(empty || started)) { memo(box, 'hide', function () { return null; }); return; }
    var open = TP.prefs.get('ui.welcome', 'peek') === 'open';                    // 默认半隐藏: 只露出一个小标签 (进度环 + 百分比), 点击才展开
    memo(box, JSON.stringify([envOk, hasPin, hasAuto, appsOk, appsScanned, newN, noH, empty, proxyOn, open]), function () {
      if (!open) return peekPill(pct);
      var bar = ui.bar(); bar.set(pct, pct === 100 ? 'ok' : '');
      var steps = [
        { t: t('ov.wiz.s1'), d: t(envOk ? 'ov.wiz.s1ok' : 'ov.wiz.s1bad'), done: envOk },
        { t: t('ov.wiz.s2'), d: t('ov.wiz.s2d'), done: hasPin, btn: hasPin ? '' : t('ov.wiz.add'), icon: 'plus', go: function () { TP.goAdd('manual'); } },
        { t: t('ov.wiz.s3'), d: t('ov.wiz.s3d'), done: hasAuto, btn: hasAuto ? '' : t('ov.wiz.import'), icon: 'file-down', go: function () { TP.goAdd('import'); }, opt: true },
        { t: t('ov.wiz.s4'), d: appsScanned ? (newN ? t('ov.wiz.s4new', { n: newN }) : t('ov.wiz.s4ok')) : t('ov.wiz.s4scan'), done: appsOk, btn: newN ? t('ov.wiz.review') : '', icon: 'nav-apps', go: function () { TP.go('apps'); } },
        { t: t('ov.wiz.s5'), d: t(proxyOn ? 'ov.wiz.s5ok' : 'ov.wiz.s5todo'), done: proxyOn, btn: proxyOn ? '' : t('ov.wiz.turnOn'), icon: 'power', go: function () { return TP.actions.setProxy(true); } }
      ];
      var list = h('ol', { class: 'wiz-steps' }, steps.map(function (s, i) {
        var b = null;
        if (s.btn) { b = ui.btn(s.btn, { sm: true, icon: s.icon, kind: !s.done && !s.opt ? 'primary' : '' }); if (noH && i > 0 && i < 3) ui.avail(b, TP.why.helper()); ui.act(b, s.go); }
        return h('li', { class: s.done ? 'done' : '' },
          h('span', { class: 'ic' }, s.done ? ui.icon('check', 14) : String(i + 1)),
          h('div', { class: 'wiz-b' }, h('b', null, s.t, s.opt ? h('span', { class: 'muted sm' }, ' ' + t('ov.wiz.optional')) : null), h('div', { class: 'muted sm' }, s.d)), b);
      }));
      var close = ui.btn(t(pct === 100 ? 'ov.wiz.start' : 'ov.wiz.later'), { sm: true, kind: pct === 100 ? 'primary' : 'ghost', icon: pct === 100 ? 'rocket' : '' });
      close.addEventListener('click', function () { TP.prefs.set('ui.welcome.dismissed', true); renderWizard(); });
      var fold = ui.btn(t('ov.wiz.collapse'), { sm: true, kind: 'ghost', icon: 'chevron-up' }); fold.setAttribute('aria-expanded', 'true');
      fold.addEventListener('click', function () { TP.prefs.set('ui.welcome', 'peek'); renderWizard(); });
      return h('section', { class: 'card wiz' },
        h('div', { class: 'card-h' }, h('h2', null, t('ov.wiz.title'), ui.help('overview.welcome')), h('span', { class: 'muted sm' }, t('ov.wiz.pct', { pct: pct })), fold, close),
        h('p', { class: 'muted' }, t('ov.wiz.intro')),
        bar.el, list);
    });
  }
})();
