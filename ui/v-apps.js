/* enana · v-apps.js — 应用页
 * · 每个应用的覆盖开关 (跟随规则 / 直连 / 固定出口 / 自动线路) + 新应用提示条; 所有状态变化都先经过 confirmDialog, 不可用的控件用 aria-disabled + 提示原因
 * · 真实应用图标: GET /api/apps 的 icon (相对路径 "appicons/X.png" 或 ""); 没有图标 / 加载失败时用字母头像; 后台提取图标期间轮询新图标
 * · 添加自定义软件: 两步弹窗 (输入路径或名称 -> POST /api/apps/inspect -> 确认结果并选路由方式 -> 最后确认 -> POST /api/apps/custom -> 任务); 自定义软件可删除
 * · 新应用: 打开「应用」页就算已知晓 —— 导航上的数字立刻消失 (后端的新标记同时确认掉), 但这一次访问里这些应用仍然高亮, 方便处理; 下次进来就不再是新的了
 * · 固定出口有 2 个以上时, 状态是「固定出口」的应用可以再选: 默认固定出口 / 在固定出口里自动选 / 指定某一个固定出口 (POST /api/override 的 target)
 * · 列表分页 (ui.pager) + 分组标题; 分类筛选 / 搜索记在 TP.prefs (apps.group / apps.q) */
(function () {
  'use strict';
  var TP = window.TP, S = TP.S, h = TP.h, ui = TP.ui, setText = TP.setText, I = window.I18N, t = I.t, L = I.L;
  var V = TP.V.apps = { id: 'apps' };
  var el = {}, flt = { q: '', g: '' }, pg = null, cuSeq = 0;
  var NEWG = ' new';                                                       // 「新应用」伪分组 (标题键里带空格, 不会和真实分组 / 应用名冲突)
  var POL = ['follow', 'pin', 'auto', 'direct'], POL_IC = { follow: 'list-checks', pin: 'pin', auto: 'auto', direct: 'direct' };
  var IC = { since: {}, timer: 0, userScan: false };                       // 图标轮询: since[应用名] = 第一次发现它还没有图标的时间
  var badIc = {};                                                          // 加载失败的图标地址: 本次页面会话里不再重试
  var VN = {};                                                             // 这一次访问里「新」的应用 (名称 -> true): 进来时已经是新的 + 页面开着期间新发现的; 离开再进来就清空
  var ackTimer = 0;
  function isNew(a) { return a.flag === 'new' || !!VN[a.name]; }

  function list() { return (S.apps && S.apps.apps) || []; }
  function active() { return TP.tab === 'apps'; }
  function hue(s) { var n = 0, i; for (i = 0; i < s.length; i++) n = (n * 31 + s.charCodeAt(i)) % 360; return n; }
  function hl(topic, o) { return ui.help(topic, o); }                      // 「!」说明图标; 话题 id 对应词典 help.<话题>.*
  /* 分组名来自后端 (中文原名); 显示用词典里的译名, 没有就原样显示。顺序也来自词典 (apps.groupOrder) */
  function groupName(g) { var k = 'apps.group.' + g; return I.has(k) ? t(k) : g; }
  function groupOf(a) { return a.group || t('apps.groupOtherRaw'); }
  function groupRank(g) { if (g === t('apps.groupCustomRaw')) return -1; var o = t('apps.groupOrder').split(','), i = o.indexOf(g); return i < 0 ? o.length : i; }       // 后端给自定义软件的分组排在最前 (新应用之后)
  function gkey(a) { return isNew(a) ? NEWG : groupOf(a); }
  function isWin() { var p = S.state && S.state.platform; return !!p && p.os === 'windows'; }
  function addFix() { return { label: t('why.addServer'), fn: function () { TP.goAdd('manual'); } }; }
  /* 固定出口 / 自动线路 要有对应的服务器才有意义 (核心没连上时不判断, 免得误报) */
  function polWhy(p) { return S.clash !== 'ok' ? '' : p === 'pin' ? TP.why.pin() : p === 'auto' ? TP.why.auto() : ''; }
  function setAttr(n, k, v) { if (n.getAttribute(k) !== v) n.setAttribute(k, v); }

  /* ================= 图标 =================
   * 头像和图片共用同一个固定大小的盒子 (--ic), 不会产生版面跳动; 图片加载成功后才盖住头像,
   * 加载失败 (error 事件) 就一直用头像, 同一个地址不再重试。icon 按后端给的相对路径原样使用 (绝对地址 / 带 .. 的一律不用, 不向外发请求)。 */
  function safeIcon(s) {
    s = String(s || '');
    return s && !badIc[s] && !/^([a-z][a-z0-9+.\-]*:|\/\/)/i.test(s) && !/(^|\/)\.\.(\/|$)/.test(s) ? s : '';
  }
  function mkIc(px) {
    var av = h('span', { class: 'apps-av' }), box = h('span', { class: 'apps-ic', 'aria-hidden': 'true' }, av);
    box.style.setProperty('--ic', px + 'px');
    box._px = px; box._av = av; box._img = null; box._src = '';
    return box;
  }
  function dropImg(box) {
    if (box._img && box._img.parentNode === box) box.removeChild(box._img);
    box._img = null; box.classList.remove('is-img');
  }
  function paintIc(box, name, icon) {
    var nm = String(name || ''), src = safeIcon(icon);
    setText(box._av, nm ? String.fromCodePoint(nm.codePointAt(0)).toUpperCase() : '?');
    box.style.setProperty('--hue', hue(nm));
    if (src === box._src) return;
    box._src = src; dropImg(box);
    if (!src) return;
    var img = document.createElement('img');
    img.addEventListener('load', function () { if (box._img === img) box.classList.add('is-img'); });
    img.addEventListener('error', function () { badIc[src] = true; if (box._img === img) { dropImg(box); box._src = ''; } });
    img.setAttribute('alt', ''); img.setAttribute('width', String(box._px)); img.setAttribute('height', String(box._px));
    img.setAttribute('loading', 'lazy'); img.setAttribute('decoding', 'async'); img.setAttribute('draggable', 'false');
    box._img = img; box.appendChild(img);
    img.setAttribute('src', src);                                           // 监听器先挂好再设置地址
  }

  TP.appIc = { mk: mkIc, paint: paintIc };                                 // 其它页面 (日志 / 网站) 也要显示应用图标: 复用同一个图标盒子

  /* ---------- 轮询新图标: 图标在扫描后由辅助服务在后台提取, 几秒内陆续出现 ----------
   * 只在「应用」页可见时, 每 3 秒读一次 GET /api/apps, 直到没有「刚出现 (60 秒内) 还没有图标」的应用; 只更新受影响行的图片 / 头像。 */
  function pendingIcons() {
    var now = Date.now();
    return list().filter(function (a) { return typeof a.icon === 'string' && !a.icon && a.kind !== 'bin' && IC.since[a.name] && now - IC.since[a.name] < 60000; });
  }
  function noteIcons() {
    var now = Date.now(), keep = {};
    list().forEach(function (a) {
      if (typeof a.icon !== 'string' || a.icon || a.kind === 'bin') return;                   // 命令行工具没有图标, 不用等
      keep[a.name] = IC.since[a.name] || now;
    });
    IC.since = keep;
  }
  function kickIcons() {
    if (IC.timer || !active() || document.hidden || !pendingIcons().length) return;
    IC.timer = setTimeout(tickIcons, 3000);
  }
  async function tickIcons() {
    IC.timer = 0;
    if (!active() || document.hidden || !pendingIcons().length) return;
    if (!S.scanning && !S.locked && !TP.noHelper()) await TP.loadApps(false);
    kickIcons();
  }

  /* ================= 筛选 / 搜索 (记在 TP.prefs) ================= */
  function readPrefs() {
    flt.q = String(TP.prefs.get('apps.q', '') || '');
    flt.g = String(TP.prefs.get('apps.group', '') || '');
  }
  function toFirstPage() { if (pg && pg.page() !== 1) pg.setPage(1); }
  function setQ(v) {
    flt.q = String(v || '').trim(); TP.prefs.set('apps.q', flt.q || undefined);      // prefs 自己会防抖上传; 本地缓存立即写入
    toFirstPage(); V.render();
  }
  function setGroup(g) {
    flt.g = g || ''; TP.prefs.set('apps.group', flt.g || undefined);
    toFirstPage(); V.render();
  }
  /* 在列表里找到某个应用: 清掉分类筛选, 搜索它的名字 */
  function focusApp(name) {
    el.q.value = name; flt.g = ''; el.g.value = ''; TP.prefs.set('apps.group', undefined); setQ(name);
    try { el.q.scrollIntoView({ block: 'center' }); } catch (e) { /* 忽略 */ }
  }
  function rescan() { IC.userScan = true; return TP.loadApps(true).then(function (r) { if (r) ui.toast(t('apps.scanned'), 'ok'); }); }

  /* ================= 构建 ================= */
  V.init = function (root) {
    readPrefs();
    /* 新应用提示条 (一直显示: 没有新应用时按钮是「没有新应用」状态) */
    el.barT = h('b'); el.barD = h('div', { class: 'sm' });
    el.adopt = ui.btn(L('apps.adopt'), { kind: 'primary', icon: 'check' }); ui.act(el.adopt, adopt);
    el.keep = ui.btn(L('apps.keepOff'), { icon: 'ban' }); ui.act(el.keep, keepAll);
    el.bar = h('section', { class: 'banner info newbar' }, h('span', { class: 'banner-ic' }, ui.icon('ai', 22)),
      h('div', { class: 'banner-b' }, h('div', { class: 'apps-bart' }, el.barT, hl('apps.new')), el.barD),
      h('div', { class: 'banner-a' }, el.adopt, el.keep));

    el.q = h('input', { class: 'inp', type: 'search', value: flt.q, placeholder: L('apps.search'), 'aria-label': L('apps.search'), autocomplete: 'off', on: { input: function () { setQ(el.q.value); } } });
    el.g = h('select', { class: 'sel', 'aria-label': L('apps.groupFilter'), on: { change: function () { setGroup(el.g.value); } } }, TP.opt('', t('apps.allGroups')));
    el.scan = ui.btn(L('apps.scan'), { icon: 'refresh' }); ui.act(el.scan, rescan);
    el.addBtn = ui.btn(L('apps.cu.add'), { kind: 'primary', icon: 'plus' }); ui.act(el.addBtn, function () { openAdd(''); });
    el.count = h('span', { class: 'muted sm' });
    el.list = h('div', { class: 'apps-list' });
    pg = ui.pager('apps.list', { sizes: [10, 20, 50], def: 20 });          // i18n-ignore
    pg.onChange(function () { V.render(); });
    el.colh = h('div', { class: 'apps-colh', 'aria-hidden': 'true' }, h('span', null, L('apps.col.name')), h('span', null, L('apps.col.path')), h('span', null, L('apps.col.state')), h('span', null, L('apps.col.mode')), h('span', null, L('apps.col.act')));   // 列头: 列表够宽时才显示 (css/apps.css)
    el.box = h('div', { class: 'apps-box' }, el.colh, el.list, pg.el);
    el.empty = ui.emptyBox();

    root.appendChild(h('div', { class: 'intro' }, h('p', { class: 'muted' }, L('apps.intro'), hl('apps.page'))));
    root.appendChild(TP.proxyNote());
    el.captureText = h('span');
    el.captureBtn = ui.btn(L('apps.capture.enable'), { kind: 'primary', icon: 'check' });
    ui.act(el.captureBtn, function () {
      if (S.state && S.state.proxy && S.state.proxy.network_mode === 'tun') { TP.settingsTab('proxy'); return; }
      return TP.actions.setNetworkMode('tun');
    });
    el.capture = h('section', { class: 'hint warn', hidden: true }, el.captureText, el.captureBtn);
    root.appendChild(el.capture);
    root.appendChild(el.bar);
    root.appendChild(h('div', { class: 'toolbar apps-tb' }, el.q, el.g, el.scan, el.addBtn,
      h('span', { class: 'apps-tb-r' }, h('span', { class: 'apps-opts muted sm' }, L('apps.opts'), hl('apps.policy')), el.count)));
    root.appendChild(el.box);
    root.appendChild(el.empty.el);

    TP.on('apps', function () { noteIcons(); if (active()) seeNew(); renderBar(); if (active()) { V.render(); kickIcons(); } });
    TP.on('helper', function () { renderBar(); if (active()) V.render(); });
    TP.on('state', function () { if (active()) V.render(); });
    TP.on('lang', function () { renderBar(); el._gsig = null; V.render(); });
    TP.on('scanning', function (on) {
      if (active()) renderTools();
      if (!on && IC.userScan) {                                              // 手动重新扫描结束: 图标会重新提取, 重新开始等待
        IC.userScan = false;
        var now = Date.now(); Object.keys(IC.since).forEach(function (k) { IC.since[k] = now; });
        if (active()) kickIcons();
      }
    });
    TP.on('auth', function (ok) { if (ok && active()) TP.loadApps(false); });
    TP.on('prefs', function (d) {                                            // 登录后读到本机偏好 / 别的设备同步过来
      if (!d || !(d.all || /^apps\./.test(String(d.key || '')))) return;
      var q = String(TP.prefs.get('apps.q', '') || ''), g = String(TP.prefs.get('apps.group', '') || '');
      if (q === flt.q && g === flt.g) return;
      flt.q = q; flt.g = g; el.q.value = q;
      if (active()) V.render();
    });
    document.addEventListener('visibilitychange', function () { if (!document.hidden) kickIcons(); });
    renderBar(); renderTools();
  };
  V.show = function () {
    VN = {};
    seeNew();
    V.render(); kickIcons();
  };
  /* 页面开着时出现的新应用 (进来时就有的 / 之后扫描到的) 都算已经看到了: 记进 VN (本次访问里继续高亮), 导航上的数字消失, 后台把新标记确认掉 (防抖, 一次请求) */
  function seeNew() {
    var any = false;
    list().forEach(function (a) { if (a.flag === 'new' && !VN[a.name]) { VN[a.name] = true; any = true; } });
    if (!any && !(S.apps && +S.apps.new_count > 0)) return;
    if (S.apps) S.apps.new_count = 0;
    TP.emit('badges');
    clearTimeout(ackTimer);
    ackTimer = setTimeout(function () {
      if (TP.noHelper() || TP.why.helper()) return;
      TP.helper('POST', '/api/apps/ack', { q: { all: 1 } }).catch(function () { /* 失败了就下次进来再确认 */ });
    }, 400);
  }

  function renderTools() {
    var why = TP.why.helper();
    ui.setBtn(el.scan, t(S.scanning ? 'apps.scanning' : 'apps.scan'));
    ui.avail(el.scan, S.scanning ? t('apps.scanningReason') : why);
    ui.avail(el.addBtn, why);
  }

  /* ---------- 新应用提示条 ---------- */
  function renderBar() {
    var news = list().filter(isNew), n = news.length, recN = news.filter(function (a) { return a.rec; }).length, why = TP.why.helper();
    setText(el.barT, t(n ? 'apps.new.title' : 'apps.new.none', { n: n })); setText(el.barD, t(n ? 'apps.new.text' : 'apps.new.noneSub'));
    el.bar.classList.toggle('has-new', n > 0);
    if (!n) { ui.setBtn(el.adopt, t('apps.noNew')); ui.avail(el.adopt, t('apps.noNewReason')); ui.setBtn(el.keep, t('apps.noNew')); ui.avail(el.keep, t('apps.noNewReason')); return; }
    if (!recN) { ui.setBtn(el.adopt, t('apps.noRec')); ui.avail(el.adopt, t('apps.noRecReason')); } else { ui.setBtn(el.adopt, t('apps.adopt')); ui.avail(el.adopt, why); }
    ui.setBtn(el.keep, t('apps.keepOff')); ui.avail(el.keep, why);
  }
  async function adopt() {
    var news = list().filter(isNew), rec = news.filter(function (a) { return a.rec; }), rest = news.length - rec.length;
    var lines = rec.slice(0, 6).map(function (a) { return t('apps.adopt.line', { name: a.name, state: TP.name.app(a.rec) }); });
    if (rec.length > 6) lines.push(t('apps.adopt.more', { n: rec.length - 6 }));
    if (rest > 0) lines.push(t('apps.adopt.rest', { n: rest }));
    var ok = await ui.confirmDialog({ title: t('apps.adopt.title'), message: t('apps.adopt.msg', { n: rec.length }), detail: lines, confirmText: t('apps.adopt.go') });
    if (!ok) return;
    var adopted = await TP.helper('POST', '/api/apps/adopt', { form: { names: rec.map(function (a) { return a.name; }).join('\n') } });
    if (adopted.job) await TP.jobs.runInDock(t('apps.adopt'), function () { return Promise.resolve(adopted); });          // 只处理这几个: 进页面时新标记已经确认掉了
    rec.forEach(function (a) { delete VN[a.name]; });
    ui.toast(t('apps.adopt.done'), 'ok'); await TP.loadApps(false);
  }
  async function keepAll() {
    var n = list().filter(isNew).length;
    var ok = await ui.confirmDialog({ title: t('apps.ack.title'), message: t('apps.ack.msg', { n: n }), detail: t('apps.ack.detail'), confirmText: t('apps.ack.go') });
    if (!ok) return;
    await TP.helper('POST', '/api/apps/ack', { q: { all: 1 } }); VN = {}; ui.toast(t('apps.ack.done'), 'ok'); await TP.loadApps(false);
  }

  /* ================= 列表 ================= */
  V.render = function () {
    var apps = list(), why = TP.why.helper(), qq = flt.q.toLowerCase();
    var capture = S.state && S.state.proxy || {}, pins = apps.some(function (a) { return a.state === 'pin'; });
    el.capture.hidden = !pins || (capture.network_mode === 'tun' && capture.tun_ready);
    setText(el.captureText, t(capture.network_mode === 'tun' ? 'set.network.notReady' : 'apps.capture.warning'));
    ui.setBtn(el.captureBtn, t(capture.network_mode === 'tun' ? 'apps.capture.check' : 'apps.capture.enable'), 'check');
    ui.avail(el.captureBtn, why);
    // 分类下拉 (按词典顺序; 语言或分类集合变了才重建)
    var gs = {}; apps.forEach(function (a) { gs[groupOf(a)] = 1; });
    var names = Object.keys(gs).sort(function (a, b) { return groupRank(a) - groupRank(b) || a.localeCompare(b); });
    var gsig = I.lang + '|' + names.join('|');
    if (el._gsig !== gsig) {
      el._gsig = gsig;
      TP.clear(el.g); el.g.appendChild(TP.opt('', t('apps.allGroups')));
      names.forEach(function (g) { el.g.appendChild(TP.opt(g, groupName(g))); });
    }
    if (apps.length && flt.g && names.indexOf(flt.g) < 0) flt.g = '';        // 这个分类已经没有应用了
    var want = names.indexOf(flt.g) >= 0 ? flt.g : '';
    if (el.g.value !== want) el.g.value = want;

    // 新应用在最前, 然后按分类 (词典顺序) / 分类名 / 应用名; 同一个分类一定连在一起 (分组标题不会重复)
    var shown = apps.filter(function (a) {
      return (!flt.g || groupOf(a) === flt.g) && (!qq || a.name.toLowerCase().indexOf(qq) >= 0);
    }).sort(function (a, b) {
      var ga = groupOf(a), gb = groupOf(b);
      return isNew(b) - isNew(a) || groupRank(ga) - groupRank(gb) || ga.localeCompare(gb) || a.name.localeCompare(b.name);
    });
    // 分页: 总数没变时不要重画分页条 (重画会丢掉键盘焦点)
    var total = shown.length, rg;
    if (total !== el._total) { el._total = total; rg = pg.update(total); }
    else rg = { start: (pg.page() - 1) * pg.size(), end: Math.min(total, pg.page() * pg.size()) };
    var cnt = {}; shown.forEach(function (a) { var k = gkey(a); cnt[k] = (cnt[k] || 0) + 1; });
    var items = [], last = null;
    shown.slice(rg.start, rg.end).forEach(function (a) {
      var k = gkey(a);
      if (k !== last) { last = k; items.push({ head: k, n: cnt[k] }); }
      items.push({ app: a });
    });
    ui.syncList(el.list, items, function (x) { return x.app ? x.app.name : '/' + x.head; },
      function (x) { return x.app ? makeRow() : makeHead(); },
      function (row, x) { if (x.app) update(row, x.app, why); else paintHead(row, x); });

    var off = apps.filter(function (a) { return a.state === 'direct'; }).length;
    setText(el.count, apps.length ? t(shown.length !== apps.length ? 'apps.countFiltered' : 'apps.count', { n: apps.length, off: off, shown: shown.length }) : '');
    el.box.hidden = !shown.length;
    renderTools();
    if (!apps.length) {
      if (TP.noHelper()) el.empty.show({ icon: 'wifi-off', text: t('apps.empty.noHelper'), hint: t('apps.empty.noHelperHint') });
      else if (S.apps) el.empty.show({ icon: 'nav-apps', text: t('apps.empty.none'), hint: t('apps.empty.noneHint'), action: { label: t('apps.scan'), icon: 'refresh', fn: rescan } });
      else el.empty.show({ icon: 'refresh', text: t('apps.empty.loading') });
    } else if (!shown.length) el.empty.show({ icon: 'search', text: t('apps.empty.noMatch'), hint: t('apps.empty.noMatchHint') });
    else el.empty.hide();
  };

  function makeHead() {
    var r = { t: h('span', { class: 'apps-gh-t' }), n: h('span', { class: 'apps-gh-n' }) }, e = h('h3', { class: 'apps-gh' }, r.t, r.n);
    e._r = r;
    return e;
  }
  function paintHead(e, x) {
    var isNew = x.head === NEWG;
    setText(e._r.t, isNew ? t('apps.gh.new') : groupName(x.head)); setText(e._r.n, String(x.n));
    e.classList.toggle('is-new', isNew);
  }

  function makeRow() {
    var r = {};
    r.ic = mkIc(40);
    r.name = h('b', { class: 'apps-n' });
    r.badge = h('span', { class: 'badge new', hidden: true }, L('apps.badge.new'));
    r.cus = ui.badge(L('apps.cu.badge'), 'info'); r.cus.hidden = true;
    r.cusHelp = hl('apps.customBadge'); r.cusHelp.hidden = true;
    r.kind = ui.badge(L('apps.cu.kind.bin'), 'neutral', 'terminal'); r.kind.hidden = true;
    r.rec = h('button', { class: 'chip rec', type: 'button', hidden: true });
    r.grp = h('span', { class: 'chip', hidden: true });
    r.path = h('div', { class: 'muted sm apps-p' });
    r.sw = h('input', { type: 'checkbox', role: 'switch' });
    r.stT = h('span', { class: 'apps-stt' });                              // 「状态」列的文字 (已开启 / 已关闭); 窄屏的堆叠样式里不显示
    r.sel = h('select', { class: 'sel sm apps-sel' }, TP.opt('follow', t('name.app.follow')), TP.opt('pin', t('apps.opt.pin')), TP.opt('auto', t('apps.opt.auto')), TP.opt('direct', t('apps.opt.direct')));
    r.tg = h('select', { class: 'sel sm apps-tg', hidden: true });                       // 固定出口有 2 个以上、状态是「固定出口」时: 指定走哪一个
    r.tgGone = h('span', { class: 'chip warn', hidden: true }, L('apps.tg.gone'));
    r.tHelp = hl('apps.terminal'); r.tHelp.hidden = true;
    r.ack = ui.btn(L('apps.keepOffOne'), { sm: true, kind: 'ghost' }); r.ack.hidden = true;
    r.del = ui.btn(L('common.delete'), { sm: true, cls: 'soft-bad', icon: 'delete' }); r.del.hidden = true;
    var row = h('div', { class: 'apps-row', role: 'group' },
      r.ic,
      h('div', { class: 'apps-main' }, h('div', { class: 'apps-t' }, r.name, r.badge, r.cus, r.cusHelp, r.kind, r.tHelp, r.rec, r.grp), r.path),
      h('div', { class: 'apps-c' }, h('div', { class: 'apps-st' }, h('label', { class: 'sw' }, r.sw, h('span', { class: 'sw-ui' })), r.stT), h('div', { class: 'apps-md' }, r.sel, r.tg, r.tgGone), h('div', { class: 'apps-act' }, r.ack, r.del)));
    row._r = r;
    ui.switchAct(r.sw, function () { return (row._a.state || 'follow') !== 'direct'; }, function (want) { return askState(row, want ? 'follow' : 'direct'); });
    ui.selectAct(r.sel, function () { return row._a.state || 'follow'; }, function (want) { return askState(row, want); });
    ui.selectAct(r.tg, function () { return tgOf(row._a); }, function (want) { return askTarget(row, want); });
    ui.act(r.rec, function () { return askState(row, row._a.rec); });
    ui.act(r.ack, function () { return ack(row); });
    ui.act(r.del, function () { return delCustom(row); });
    return row;
  }
  function update(row, a, why) {
    var r = row._r, st = a.state || 'follow', on = st !== 'direct', nw = isNew(a), cus = !!a.custom;
    row._a = a;
    paintIc(r.ic, a.name, a.icon);
    var optLabels = { follow: t('name.app.follow'), pin: t('apps.opt.pin'), auto: t('apps.opt.auto'), direct: t('apps.opt.direct') };
    Array.prototype.forEach.call(r.sel.options, function (o) { var s = optLabels[o.value]; if (o.textContent !== s) o.textContent = s; });
    setText(r.name, a.name); setAttr(row, 'aria-label', a.name);
    r.badge.hidden = !nw; r.ack.hidden = !nw;
    r.grp.hidden = !nw; if (nw) setText(r.grp, groupName(groupOf(a)));
    r.cus.hidden = !cus; r.cusHelp.hidden = !cus; r.del.hidden = !cus; r.kind.hidden = a.kind !== 'bin';
    setText(r.path, a.path || ''); r.path.hidden = !a.path; r.path.classList.toggle('is-wrap', cus);   // 自定义软件的路径整行显示出来 (不靠提示框)
    if (cus || !a.path) r.path.removeAttribute('title'); else r.path.title = a.path;
    if (r.sw.checked !== on) r.sw.checked = on;
    setText(r.stT, t(on ? 'apps.st.on' : 'apps.st.off'));
    if (r.sel.value !== st) r.sel.value = st;
    paintTarget(r, a, st, why);
    r.tHelp.hidden = !isTerm(a);
    setAttr(row, 'data-st', st);
    ui.avail(r.sw, why); ui.avail(r.sel, why); ui.avail(r.ack, why); ui.avail(r.rec, why); ui.avail(r.del, why);
    setAttr(r.sw, 'aria-label', t('apps.row.sw', { name: a.name, state: TP.name.app(st) }));
    setAttr(r.sel, 'aria-label', t('apps.row.sel', { name: a.name }));
    setAttr(r.del, 'aria-label', t('apps.cu.delAria', { name: a.name }));
    var showRec = a.rec && a.rec !== st;
    r.rec.hidden = !showRec;
    if (showRec) { setText(r.rec, t('apps.rec', { state: TP.name.app(a.rec) })); if (!r.rec._un) r.rec.title = t('apps.recTitle'); }
    row.classList.toggle('is-new', nw); row.classList.toggle('is-off', !on);
  }

  /* ---------- 固定出口: 默认 / 在固定出口里自动选 / 指定某一个 ---------- */
  var TERM_RE = /^(terminal|iterm2?|warp|ghostty|kitty|alacritty|wezterm|hyper|tabby|termius)$/i;
  function isTerm(a) { return a.group === t('apps.groupTermRaw') || TERM_RE.test(a.name || ''); }       // 后端给的分组原名是中文
  function tgOf(a) { return a.target_ok === false || !a.target ? 'PIN' : a.target; }                     // select 的值: PIN = 默认固定出口
  function tgSig(a) { return TP.pinServers().join('|') + '#' + I.lang; }
  function paintTarget(r, a, st, why) {
    var show = st === 'pin' && TP.canPickPin();
    r.tg.hidden = !show; r.tgGone.hidden = !(show && a.target && a.target_ok === false);
    if (!show) return;
    if (r.tg._sig !== tgSig(a)) {
      r.tg._sig = tgSig(a); TP.clear(r.tg);
      r.tg.appendChild(TP.opt('PIN', t('apps.tg.default'))); r.tg.appendChild(TP.opt('PINAUTO', t('apps.tg.auto')));
      TP.pinServers().forEach(function (tag) { r.tg.appendChild(TP.opt(tag, tag)); });
    }
    if (r.tg.value !== tgOf(a)) r.tg.value = tgOf(a);
    ui.avail(r.tg, why);
    setAttr(r.tg, 'aria-label', t('apps.tg.aria', { name: a.name }));
  }
  function tgName(v) { return v === 'PIN' || !v ? t('apps.tg.default') : v === 'PINAUTO' ? t('apps.tg.auto') : v; }
  async function askTarget(row, to) {
    var a = row._a, prev = tgOf(a);
    if (!to || to === prev) return;
    var ok = await ui.confirmDialog({ title: t('apps.tg.title'), message: t('apps.tg.msg', { name: a.name, from: tgName(prev), to: tgName(to) }), detail: [t(to === 'PIN' ? 'apps.tg.dDefault' : to === 'PINAUTO' ? 'apps.tg.dAuto' : 'apps.tg.dOne', { tag: to })], confirmText: t('apps.tg.go'), rememberKey: 'appstate' });
    if (!ok) return;
    var old = { t: a.target, ok: a.target_ok };
    a.target = to === 'PIN' ? '' : to; a.target_ok = true; V.render();
    try { await TP.override('app', a.name, 'pin', a.target); }
    catch (e) { a.target = old.t; a.target_ok = old.ok; V.render(); throw e; }
    ui.toast(t('apps.tg.done', { name: a.name, to: tgName(to) }), 'ok', 2400);
  }

  function recount() { if (S.apps) S.apps.new_count = list().filter(function (a) { return a.flag === 'new'; }).length; }       // 页面开着时都已确认掉, 这里只是和后端的数字保持一致
  async function askState(row, to) {
    var a = row._a, prev = a.state || 'follow', wasNew = isNew(a);
    if (!to || to === prev) return;
    var pw = polWhy(to);                                                // 没有对应的服务器: 说明原因并给出「添加服务器」
    if (pw) { ui.toast(pw, 'warn', 5200, { action: addFix() }); return; }
    var tx = TP.txt.app(a.name, prev, to);
    var p = S.state && S.state.proxy || {}, browser = /^(Google Chrome|Safari|Firefox|Microsoft Edge|Brave Browser|Arc|Opera)$/.test(a.name) || a.group === t('apps.groupBrowserRaw');
    var ok = to === 'pin' && !browser && p.network_mode !== 'tun'
      ? await TP.actions.offerAppCapture(a.name)
      : await ui.confirmDialog({ title: t('apps.change.title'), message: tx.message, detail: tx.detail, confirmText: t('apps.change.go'), rememberKey: 'appstate' });
    if (!ok) return;
    a.state = to; if (to !== 'pin') a.target = ''; V.render();         // 立即显示新状态; 失败时恢复 (离开「固定出口」时后端会清掉指定的出口)
    try { await TP.override('app', a.name, to); }
    catch (e) { a.state = prev; V.render(); throw e; }
    if (wasNew) {                       // 用户已经处理过这个新应用: 确认它, 让「新」标记消失
      a.flag = 'ack'; delete VN[a.name]; recount();
      TP.helper('POST', '/api/apps/ack', { q: { name: a.name } }).catch(function () { });
      TP.emit('apps');
    }
    ui.toast(t('apps.changed', { name: a.name, state: TP.name.app(to) }), 'ok', 2400);
  }
  async function ack(row) {
    var a = row._a;
    var ok = await ui.confirmDialog({ title: t('apps.ack1.title'), message: t('apps.ack1.msg', { name: a.name }), detail: t('apps.ack1.detail'), confirmText: t('apps.ack1.go'), rememberKey: 'appstate' });
    if (!ok) return;
    await TP.helper('POST', '/api/apps/ack', { q: { name: a.name } });
    a.flag = 'ack'; delete VN[a.name]; recount(); TP.emit('apps');
  }

  /* ================= 删除自定义软件 (只删这条自定义记录和它的策略) ================= */
  async function delCustom(row) {
    var a = row._a;
    var ok = await ui.confirmDialog({
      title: t('apps.cu.del.title'), message: t('apps.cu.del.msg', { name: a.name }),
      detail: [a.path ? h('span', { class: 'mono apps-wrap' }, a.path) : null, t('apps.cu.del.d1'), t('apps.cu.del.d2')],
      confirmText: t('apps.cu.del.go'), danger: true
    });
    if (!ok) return;
    await TP.jobs.runInDock(t('apps.cu.del.job', { name: a.name }), function () { return TP.helper('POST', '/api/apps/custom/delete', { form: { name: a.name } }); });
  }

  /* ================= 添加自定义软件: 两步弹窗 =================
   * 第 1 步: 输入路径 (或名称) -> POST /api/apps/inspect (只校验, 不运行这个程序)。无效的输入在原处说明原因并给出怎么改, 输入框保持可编辑。
   * 第 2 步: 校验结果卡片 (图标 / 名称 / 类型 / 版本 / Bundle ID / 路径 / 签名 / 已存在) + (按名称查到多个时) 候选单选 + 路由方式单选
   *          -> 「添加」-> 最后一次确认 -> POST /api/apps/custom (path 用候选的 path) -> 任务 (弹窗里显示进度) -> 关闭, 刷新列表。 */
  function pathLike(s) { return /[\/\\]/.test(s) || /^~/.test(s); }
  function absPath(s) { return /^(\/|[A-Za-z]:[\\\/]|\\\\)/.test(s); }
  /* 粘贴进来的路径常常带着引号 (Windows 的「复制为路径」) 或反斜杠转义 (从终端复制的 /Applications/My\ App.app), 只取第一行并先整理 */
  function cleanInput(raw) {
    var s = String(raw == null ? '' : raw).split(/\r?\n/).map(function (x) { return x.trim(); }).filter(Boolean)[0] || '';
    var m = /^(["'])(.*)\1$/.exec(s);
    if (m) s = m[2].trim();
    if (s.charAt(0) === '/') s = s.replace(/\\(.)/g, '$1');
    return s;
  }
  function preCheck(s) {                                                  // 在发请求之前就能判断的问题 -> 词典键
    if (!s) return 'apps.cu.err.empty';
    if (pathLike(s)) return s.charAt(0) !== '~' && !absPath(s) ? 'apps.cu.err.relative' : '';
    return /[|"\x00-\x1f]/.test(s) ? 'apps.cu.err.chars' : '';
  }
  function reasonOf(e) { return e && e.kind === 'api' && e.data && e.data.error ? String(e.data.error) : TP.errMsg(e); }
  function kindBadge(c) {
    return c.kind === 'app' ? ui.badge(L('apps.cu.kind.app'), 'info', 'app-window') : c.kind === 'bin' ? ui.badge(L('apps.cu.kind.bin'), 'info', 'terminal') : null;
  }
  function kv(label, node) { return h('div', { class: 'apps-kv-r' }, h('dt', null, label), h('dd', null, node)); }

  function openAdd(prefill) {
    var id = 'apps-cu' + (++cuSeq), st = { step: 1, checking: false, busy: false, dead: false, seq: 0, q: '', cands: [], sel: 0, pol: 'follow', candBox: null, polIn: {} };
    var api, helpBtn = null, cardBox = null, jobBox = null;

    /* ---- 第 1 步 ---- */
    var inp = h('input', {
      class: 'inp apps-in', id: id + '-in', name: 'apps-path', type: 'text', value: prefill || '', placeholder: L(isWin() ? 'apps.cu.in.phWin' : 'apps.cu.in.ph'),
      autocomplete: 'off', autocapitalize: 'off', autocorrect: 'off', spellcheck: 'false', 'aria-describedby': id + '-hint ' + id + '-err'
    });
    var errBox = h('div', { class: 'hint bad apps-err', id: id + '-err', role: 'alert', hidden: true });
    var how = [h('li', null, L('apps.cu.how.mac1')), h('li', null, L('apps.cu.how.mac2')), h('li', null, L('apps.cu.how.win'))];
    if (isWin()) how.unshift(how.pop());                                  // 当前系统的做法放在最前面
    var stepLbl = h('p', { class: 'apps-step muted sm' });
    var s1 = h('div', { class: 'apps-s1' },
      h('p', { class: 'apps-lead' }, L('apps.cu.lead')),
      h('div', { class: 'fld' }, h('label', { class: 'fld-l', for: id + '-in' }, L('apps.cu.in.label')), inp, h('span', { class: 'fld-h', id: id + '-hint' }, L('apps.cu.in.hint'))),
      errBox,
      h('div', { class: 'apps-how' }, h('h4', null, L('apps.cu.how.title')), h('ul', null, how), h('p', { class: 'muted sm apps-nopick' }, L('apps.cu.how.nopicker'))));
    var s2 = h('div', { class: 'apps-s2', hidden: true });

    function hideErr() { errBox.hidden = true; inp.removeAttribute('aria-invalid'); }
    /* hints: 0 = 不给提示 (网络问题 / 还没输入) · 1 = 路径的提示 · 2 = 名称的提示; found: 按名称找到、但不能用的那个路径 */
    function showErr(msg, hints, found) {
      TP.clear(errBox);
      errBox.appendChild(h('div', { class: 'apps-err-m' }, ui.icon('error', 16, 'ci'), h('b', null, msg)));
      if (found) errBox.appendChild(h('div', { class: 'apps-err-p mono' }, found));
      if (hints) {
        errBox.appendChild(h('div', { class: 'apps-err-h' }, L('apps.cu.fix.title')));
        errBox.appendChild(h('ul', null, (hints === 1 ? ['apps.cu.fix.p1', 'apps.cu.fix.p2', 'apps.cu.fix.p3'] : ['apps.cu.fix.n1', 'apps.cu.fix.n2']).map(function (k) { return h('li', null, t(k)); })));
      }
      errBox.hidden = false; inp.setAttribute('aria-invalid', 'true');
      try { inp.focus(); } catch (e) { /* 忽略 */ }
    }
    function paintCheck(on) {
      var b = api && api.getBtn('check'); if (!b) return;
      ui.setBtn(b, t(on ? 'apps.cu.checking' : 'apps.cu.check'));
      b.classList.toggle('is-busy', on);
      if (on) b.setAttribute('aria-busy', 'true'); else b.removeAttribute('aria-busy');
    }
    async function check() {
      if (st.checking || st.busy) return false;
      var s = cleanInput(inp.value); inp.value = s; hideErr();
      var pre = preCheck(s);
      if (pre) { showErr(t(pre), pre === 'apps.cu.err.empty' ? 0 : pathLike(s) ? 1 : 2); return false; }
      var why = TP.why.helper();
      if (why) { showErr(why, 0); return false; }
      st.checking = true; paintCheck(true);
      var seq = ++st.seq, r = null, err = null;
      try { r = await TP.helper('POST', '/api/apps/inspect', { form: { input: s }, timeout: 20000 }); }
      catch (e) { err = e; }
      st.checking = false; paintCheck(false);
      if (st.dead || seq !== st.seq || cleanInput(inp.value) !== s) return false;       // 弹窗已关 / 检查期间又改了输入: 这个结果不要了
      if (err) {
        if (err.kind === 'auth' || err.kind === 'cancel') return false;
        if (err.kind === 'api') showErr(reasonOf(err), pathLike(s) ? 1 : 2);
        else showErr(t('apps.cu.err.failed', { reason: TP.errMsg(err) }), 0);
        return false;
      }
      var cs = r && Array.isArray(r.candidates) ? r.candidates : [];
      var good = cs.filter(function (c) { return c && c.valid !== false && c.path; });
      if (!good.length) {
        var bad = cs.filter(function (c) { return c && c.reason; })[0], isPath = pathLike(s);
        showErr((bad && String(bad.reason)) || (r && r.reason ? String(r.reason) : '') || t('apps.cu.err.nomatch'), isPath ? 1 : 2, !isPath && bad && bad.path ? String(bad.path) : '');
        return false;
      }
      st.q = s; st.cands = good.slice(0, 8); st.sel = 0;
      toStep(2);
      return false;
    }
    inp.addEventListener('input', hideErr);
    inp.addEventListener('keydown', function (e) {
      if (e.key !== 'Enter' || e.isComposing || e.keyCode === 229) return;                // 输入法选字时的回车不算提交
      e.preventDefault(); TP.safe(check)();
    });

    /* ---- 第 2 步 ---- */
    function sigRow(c) {
      var box = h('div', { class: 'apps-sig' });
      if (c.signed && (c.authority || c.team)) {
        box.appendChild(ui.badge(L('apps.cu.signed'), 'ok', 'shield-check'));                // 有开发者的签名 = 绿色
        if (c.authority) box.appendChild(h('span', { class: 'apps-sig-a' }, c.authority));
        if (c.team) box.appendChild(h('span', { class: 'chip ok mono' }, L('apps.cu.team', { team: c.team })));
      } else if (c.signed) {
        box.appendChild(ui.badge(L('apps.cu.signedLocal'), 'info', 'shield-check'));          // 只有本地 (ad-hoc) 签名, 没有开发者信息: 蓝灰, 不当作「可信」
      } else {
        box.appendChild(ui.badge(L('apps.cu.unsigned'), 'warn', 'shield-alert'));            // 未签名 = 琥珀色警告 + 一句话说明
        box.appendChild(h('p', { class: 'apps-warn' }, ui.icon('warning', 15, 'ci'), h('span', null, L('apps.cu.unsigned.why'))));
      }
      return h('div', { class: 'apps-kv-r' }, h('dt', null, L('apps.cu.f.sig'), hl('apps.signature')), h('dd', null, box));
    }
    function resultCard(c) {
      var ic = mkIc(56); paintIc(ic, c.name, c.icon);
      var rows = [];
      if (c.version) rows.push(kv(L('apps.cu.f.version'), String(c.version)));
      if (c.bundle_id) rows.push(kv(L('apps.cu.f.bundle'), h('span', { class: 'mono apps-v' }, String(c.bundle_id))));
      if (c.kind === 'bin' && c.exec) rows.push(kv(L('apps.cu.f.exec'), h('span', { class: 'mono apps-v' }, String(c.exec))));
      rows.push(kv(L('apps.cu.f.path'), h('span', { class: 'mono apps-v' }, c.path)));
      rows.push(sigRow(c));
      var f = document.createDocumentFragment();
      f.appendChild(h('section', { class: 'apps-card' },
        h('div', { class: 'apps-card-h' }, ic, h('div', { class: 'apps-card-t' }, h('div', { class: 'apps-card-n' }, c.name), h('div', { class: 'apps-card-b' }, kindBadge(c), c.matches_running ? ui.badge(L('apps.cu.running'), 'ok') : null))),
        h('dl', { class: 'apps-kv' }, rows)));
      if (c.exists) {                                                                     // 已存在 = 琥珀色提示, 不能再添加
        var show = ui.btn(L('apps.cu.show'), { sm: true, icon: 'search' }); ui.act(show, function () { showInList(c.name); });
        f.appendChild(h('div', { class: 'hint warn apps-exists', role: 'status' }, ui.icon('info', 16, 'ci'),
          h('div', null, h('b', null, L('apps.cu.exists')), h('p', null, t('apps.cu.exists.why', { name: c.name })), show)));
      }
      return f;
    }
    function paintCard() { TP.clear(cardBox); cardBox.appendChild(resultCard(st.cands[st.sel])); }
    function selectCand(i) {
      st.sel = i;
      Array.prototype.forEach.call(st.candBox.children, function (lab, k) { lab.classList.toggle('is-on', k === i); });
      paintCard(); refreshAdd();
    }
    function pickList() {                                                                 // 按名称查到多个: 单选「就是这个」
      var gid = id + '-pick', name = gid + 'n', box = h('div', { class: 'apps-cands', role: 'radiogroup', 'aria-labelledby': gid });
      st.cands.forEach(function (c, i) {
        var rb = h('input', { type: 'radio', name: name, value: String(i), checked: i === st.sel }), ic = mkIc(32);
        paintIc(ic, c.name, c.icon);
        var lab = h('label', { class: 'apps-cand' + (i === st.sel ? ' is-on' : '') }, rb, ic,
          h('span', { class: 'apps-cand-b' }, h('span', { class: 'apps-cand-t' }, h('b', null, c.name), kindBadge(c), c.exists ? ui.badge(L('apps.cu.exists'), 'warn') : null), h('span', { class: 'mono apps-cand-p' }, c.path)),
          h('span', { class: 'apps-cand-pick' }, ui.icon('check', 14, 'ci'), L('apps.cu.pick.this')));
        rb.addEventListener('change', function () { if (rb.checked) selectCand(i); });
        box.appendChild(lab);
      });
      st.candBox = box;
      return h('div', { class: 'apps-pick' }, h('p', { class: 'apps-pick-t', id: gid }, t('apps.cu.pick.title', { n: st.cands.length, q: st.q })), box);
    }
    function policyBox() {                                                                // 路由方式单选: 保持路由颜色 (跟随=蓝灰 / 固定出口=蓝 / 自动=绿 / 直连=灰), 每项一行说明
      var gid = id + '-pol', name = gid + 'n', box = h('div', { class: 'apps-pol', role: 'radiogroup', 'aria-labelledby': gid + 't' });
      st.polIn = {};
      POL.forEach(function (p) {
        var why = polWhy(p), rb = h('input', { type: 'radio', name: name, value: p, checked: p === st.pol });
        var lab = h('label', { class: 'apps-opt' + (p === st.pol ? ' is-on' : ''), 'data-v': p }, rb, ui.icon(POL_IC[p], 18, 'apps-opt-i'),
          h('span', { class: 'apps-opt-b' }, h('b', null, L('name.app.' + p)), h('span', { class: 'apps-opt-d' }, L('apps.cu.pol.' + p))));
        if (why) { rb.setAttribute('aria-disabled', 'true'); lab.classList.add('unavail'); lab.title = why; }
        rb.addEventListener('click', function (ev) { if (why) { ev.preventDefault(); ui.toast(why, 'warn', 5200, { action: addFix() }); } });
        rb.addEventListener('change', function () {
          if (!rb.checked || why) return;
          st.pol = p;
          Object.keys(st.polIn).forEach(function (k) { st.polIn[k].parentNode.classList.toggle('is-on', k === p); });
        });
        st.polIn[p] = rb; box.appendChild(lab);
      });
      return h('div', { class: 'apps-polw' }, h('div', { class: 'apps-pol-h' }, h('span', { id: gid + 't' }, L('apps.cu.polTitle')), hl('apps.policy')), box);
    }
    function renderStep2() {
      TP.clear(s2);
      cardBox = h('div', { class: 'apps-card-box' }); jobBox = h('div', { class: 'apps-job' });
      st.candBox = null;
      if (st.cands.length > 1) s2.appendChild(pickList());
      s2.appendChild(cardBox); paintCard();
      s2.appendChild(policyBox()); s2.appendChild(jobBox);
    }
    function refreshAdd() {                                                               // 「添加」: 已存在 / 辅助服务不可用时不可用, 并说明原因
      var b = api && api.getBtn('add'); if (!b) return;
      var c = st.cands[st.sel], why = TP.why.helper(), fix = null;
      if (c && c.exists) { why = t('apps.cu.exists.why', { name: c.name }); fix = { label: t('apps.cu.show'), fn: function () { showInList(c.name); } }; }
      ui.avail(b, why, fix);
    }
    function showInList(name) { api.close('list'); focusApp(name); }                    // 已经在列表里: 关掉弹窗, 在列表里搜到它
    function setBusy(b) {
      st.busy = b; api.setBusy(b);
      var back = api.getBtn('back'); if (back) ui.avail(back, b ? t('modal.busy') : '');
      var ad = api.getBtn('add'); if (ad) ad.classList.toggle('is-busy', b);
      Array.prototype.forEach.call(s2.querySelectorAll('input'), function (x) { x.disabled = b; });
    }
    async function add() {
      var c = st.cands[st.sel];
      if (!c || st.busy) return false;
      var why = TP.why.helper(); if (why) { ui.toast(why, 'warn'); return false; }
      var pw = polWhy(st.pol); if (pw) { ui.toast(pw, 'warn', 5200, { action: addFix() }); return false; }
      var pn = TP.name.app(st.pol);
      var ok = await ui.confirmDialog({                                                   // 最后一次确认: 名称 / 路径 / 路由方式
        title: t('apps.cu.confirm.title'), message: t('apps.cu.confirm.msg', { name: c.name, policy: pn }),
        detail: [h('span', null, t('apps.cu.f.path') + ': ', h('span', { class: 'mono apps-wrap' }, c.path)), t('apps.cu.confirm.pol', { policy: pn }) + ' — ' + t('apps.cu.pol.' + st.pol)],
        confirmText: t('apps.cu.confirm.go'), confirmIcon: 'plus'
      });
      if (!ok || st.dead) return false;
      TP.clear(jobBox);
      setBusy(true);
      var card = ui.taskCard(t('apps.cu.job', { name: c.name }));
      card.set({ pct: null, msg: t('job.submitting') }); jobBox.appendChild(card.el);
      try { card.el.scrollIntoView({ block: 'nearest' }); } catch (e) { /* 忽略 */ }
      try {
        var res = await TP.helper('POST', '/api/apps/custom', { form: { path: c.path, state: st.pol }, timeout: 20000 }), j = null;
        if (res && res.job) j = await TP.jobs.follow(res.job, card);
        card.done((j && j.msg) || t('apps.cu.done'));
      } catch (e) {
        if (e && (e.kind === 'auth' || e.kind === 'cancel')) { card.close(); setBusy(false); return false; }
        card.fail(reasonOf(e)); setBusy(false);                                           // 失败: 留在这一步, 可以返回修改或再试一次
        return false;
      }
      setBusy(false);
      api.close(true);
      ui.toast(t('apps.cu.added', { name: c.name, policy: pn }), 'ok', 6000, { action: { label: t('apps.cu.show'), fn: function () { focusApp(c.name); } } });
      TP.afterApply(); kickIcons();
      return false;
    }

    /* ---- 步骤切换 ---- */
    function setHelp() {                                                                  // 标题旁的「!」: 两步各有自己的说明
      if (helpBtn && helpBtn.parentNode) helpBtn.parentNode.removeChild(helpBtn);
      helpBtn = st.step === 1 ? hl('apps.custom') : hl('apps.custom2');
      var head = api.el.querySelector('.dlg-h');
      head.insertBefore(helpBtn, head.querySelector('.dlg-x'));
    }
    function toStep(n) {
      st.step = n; s1.hidden = n !== 1; s2.hidden = n !== 2;
      setText(stepLbl, t('apps.cu.step', { n: n }) + ' · ' + t(n === 1 ? 'apps.cu.step1' : 'apps.cu.step2'));
      setHelp();
      api.setActions(n === 1
        ? [{ label: t('common.cancel'), cancel: true }, { label: t('apps.cu.check'), kind: 'primary', icon: 'search', id: 'check', keep: true, onClick: check }]
        : [{ label: t('apps.cu.back'), icon: 'chevron-left', id: 'back', keep: true, onClick: function () { if (!st.busy) toStep(1); return false; } },
          { label: t('apps.cu.go'), kind: 'primary', icon: 'plus', id: 'add', keep: true, onClick: add }]);
      var f;
      if (n === 2) {
        renderStep2(); refreshAdd();
        f = s2.querySelector('input[type=radio]:checked') || s2.querySelector('input');
      } else f = inp;
      if (f) { try { f.focus(); if (n === 1) inp.select(); } catch (e) { /* 忽略 */ } }
    }

    api = ui.modal({
      title: t('apps.cu.add'), icon: 'plus', iconKind: 'pri', size: 'md', cls: 'apps-dlg',
      body: h('div', { class: 'apps-cu' }, stepLbl, s1, s2),
      actions: [{ label: t('common.cancel'), cancel: true }, { label: t('apps.cu.check'), kind: 'primary', icon: 'search', id: 'check', keep: true, onClick: check }],
      dirty: function () { return !st.busy && !!inp.value.trim(); },
      lock: function () { return st.busy; },
      onClose: function () { st.dead = true; }
    });
    setText(stepLbl, t('apps.cu.step', { n: 1 }) + ' · ' + t('apps.cu.step1'));
    setHelp();
    return api;
  }
})();
