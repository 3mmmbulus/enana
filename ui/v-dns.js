/* enana · v-dns.js — DNS 页 (视图 id: dns)
 * 卡片 (自上而下): 当前设置 (+ DNS 服务器测速) · 一次解析是怎么完成的 (流程) · 默认已开启的优化 · 自定义解析 (hosts) · 测试解析
 *  - 「修改 DNS 设置」弹窗: 国内 / 海外 DNS (选择器 = 弹层列表, 按协议分组, 带延迟徽标)、海外解析的线路、IP 策略、防泄漏、屏蔽广告。
 *    只提交改动的字段; 先 confirmDialog (旧 → 新), 再 POST /api/dns, 并在弹窗里用 taskCard 跟踪任务
 *  - 测速: POST /api/dns/bench (任务), job.result = {cn:[{id,ms}], global:[{id,ms}]}, ms:null = 不通。结果 (带时间) 记在本页状态里 (sessionStorage),
 *    给每个预设标延迟, 并提示最快的一个; 「采用」只是选中它, 仍然走保存流程 (确认 + 任务进度)
 *  - 自定义解析: GET /api/dns 里的 hosts; POST /api/dns/hosts (action=add|update|remove, 任务) 与 POST /api/dns/hosts/reset (清空)
 *  - 解析测试: POST /api/dns/test; 答案来自自定义解析时标出徽标
 * 列头排序 (ui.sorter, 记在 prefs sort.dns-pl / sort.dns-hosts): 自定义解析表 (域名 / IP) 和解析流程表 (匹配的网站 / 回答的 DNS / 路径) 的列头都可以点。
 *   自定义解析: 筛选 → 排序 (整张表) → 分页, 不排序时按域名; 流程是「从上往下检查, 第一个匹配的负责回答」, 不排序时一定是评估顺序, 排序只是换个看法 (步骤编号仍是评估顺序里的第几步)。
 * 范围: 这些设置只影响代理核心自己发起的解析, 页面上有明文说明 (不是藏在提示里)。
 * 流程图对后端字段保持宽容: id / match / via 是已知代码就用本地化文案, 否则原样显示后端给的字符串 (detail 也一样)。 */
(function () {
  'use strict';
  var TP = window.TP, S = TP.S, h = TP.h, ui = TP.ui, fmt = TP.fmt, setText = TP.setText, I = window.I18N, t = I.t, L = I.L;
  var V = TP.V.dns = { id: 'dns' };
  var el = {};
  var D = null;                         // GET /api/dns 整理后的结果; null = 还没读到
  var loadErr = null, inflight = 0, loadSeq = 0;
  var hist = [], lastRes = null, testing = false;
  var modalSync = null;                 // 设置弹窗打开期间: 重新计算提示和可用状态 (语言 / 线路池变化时)
  var uid = 0;
  var HOST_MAX = 200;                   // 自定义解析最多多少条 (docs/API.md)
  var hs = { edit: null, busy: false, filter: '', flash: '', focus: null, btns: [], forms: [], pg: null, add: null };      // 自定义解析的界面状态
  var plSo = null, hsSo = null;                                                                                 // 列头排序 (ui.sorter): 解析流程表 / 自定义解析表
  var bn = { running: false, res: null, at: 0, views: [], cards: [] };                                         // 测速: 最近一次结果 {cn:{id:ms|null}, global:{…}} + 时间; views = 正在显示的测速条

  /* ---------- 词典键表 (键写成字面量, 方便 tools/i18n-check.js 检查) ---------- */
  var STRATS = ['prefer_ipv4', 'ipv4_only', 'prefer_ipv6', 'ipv6_only'];
  var STRAT = {
    prefer_ipv4: { name: 'dns.strategy.prefer_ipv4', desc: 'dns.strategy.prefer_ipv4.d' },
    ipv4_only: { name: 'dns.strategy.ipv4_only', desc: 'dns.strategy.ipv4_only.d' },
    prefer_ipv6: { name: 'dns.strategy.prefer_ipv6', desc: 'dns.strategy.prefer_ipv6.d' },
    ipv6_only: { name: 'dns.strategy.ipv6_only', desc: 'dns.strategy.ipv6_only.d' }
  };
  var SCOPE = {
    cn: { label: 'dns.f.cn', hint: 'dns.f.cn.h', ph: 'dns.custom.ph.cn', help: 'dns.custom.help.cn', pick: 'dns.pk.title.cn' },
    global: { label: 'dns.f.global', hint: 'dns.f.global.h', ph: 'dns.custom.ph.global', help: 'dns.custom.help.global', pick: 'dns.pk.title.global' }
  };
  var GROUP_KEY = { doh: 'dns.pk.g.doh', dot: 'dns.pk.g.dot', udp: 'dns.pk.g.udp', other: 'dns.pk.g.other' };
  var GROUP_ORDER = ['doh', 'dot', 'udp', 'other'];
  var OPTS = [
    { icon: 'database', t: 'dns.opt.cache.t', d: 'dns.opt.cache.d', help: 'opt.cache' },
    { icon: 'scan-search', t: 'dns.opt.reverse.t', d: 'dns.opt.reverse.d', help: 'opt.reverse' },
    { icon: 'map-pin', t: 'dns.opt.direct.t', d: 'dns.opt.direct.d', help: 'opt.direct' },
    { icon: 'shield-check', t: 'dns.opt.proxied.t', d: 'dns.opt.proxied.d', help: 'opt.proxied' }
  ];
  /* 流程里的步骤: 后端的 id (或 match) 是已知代码时用这里的文案和图标 */
  var STEPS = {
    hosts: { icon: 'list-checks', t: 'dns.pl.hosts.t', d: 'dns.pl.hosts.d' },
    ads: { icon: 'ban', t: 'dns.match.ads', d: 'dns.pipe.ads.d' },
    direct: { icon: 'direct', t: 'dns.pl.direct.t', d: 'dns.pl.direct.d' },
    cn: { icon: 'map-pin', t: 'dns.match.cn', d: 'dns.pipe.cn.d' },
    proxy: { icon: 'shield-check', t: 'dns.pl.proxy.t', d: 'dns.pl.proxy.d' },
    global: { icon: 'globe', t: 'dns.match.all', d: '' }
  };
  var STEP_BY_MATCH = { hosts: 'hosts', 'geosite-ads': 'ads', 'geosite-cn': 'cn', all: 'global', direct: 'direct', proxy: 'proxy', fallback: 'global', final: 'global' };
  var VIA_ICON = { direct: 'direct', auto: 'auto', pin: 'pin' };

  /* ---------- 小工具 ---------- */
  function active() { return TP.tab === 'dns'; }
  function bool(v, d) { return v == null || v === '' ? d : (v === true || v === 1 || v === '1' || v === 'true'); }
  function str(v) { return v == null ? '' : String(v); }
  function onOff(b) { return t(b ? 'common.on' : 'common.off'); }
  function addFix() { return { label: t('why.addServer'), fn: function () { TP.goAdd('manual'); } }; }
  function strategyName(v) { return STRAT[v] ? t(STRAT[v].name) : str(v); }
  /* 辅助服务返回 ok:false 时, 它按当前语言给的说明 (「查询超时」「地址格式不正确」) 比 error.<code> 的通用文字 (「网络请求失败」) 更有用 */
  function errText(e) { return e && e.kind === 'api' && e.message ? e.message : TP.errMsg(e); }
  /* 「!」说明图标: 话题写成 H('cn') -> help.dns.cn.* */
  function H(name) { return ui.help('dns.' + name); }
  function reduceMotion() { try { return window.matchMedia('(prefers-reduced-motion: reduce)').matches; } catch (e) { return false; } }
  function coarse() { try { return window.matchMedia('(pointer: coarse)').matches; } catch (e) { return false; } }

  /* 预设的名称 / 说明: 后端给了当前语言的字段 (name_en ...) 就用它; 只有默认 (中文) 字段时, 已知预设用词典里的译文 */
  function pTxt(p, f) {
    var k = 'dns.preset.' + p.id + '.' + f, v = I.pick(p, f);
    if (I.lang !== 'zh' && !p[f + '_' + I.lang] && I.has(k)) return t(k);
    if (!v && I.has(k)) return t(k);
    return v;
  }
  function presetOf(scope, id) {
    var a = (D && D.presets[scope]) || [], i;
    for (i = 0; i < a.length; i++) if (str(a[i].id) === str(id)) return a[i];
    return null;
  }
  /* https://dns.example:853/x -> dns.example:853 */
  function urlHost(u) { u = str(u).trim(); return u === 'system' ? u : u.replace(/^[a-z][a-z0-9+.-]*:\/\//i, '').split('/')[0]; }
  /* 一个 DNS 选择的显示名: 预设名, 或「自定义 (主机)」 */
  function srvName(scope, id, custom) {
    var p = presetOf(scope, id), host;
    if (id === 'custom') {
      host = urlHost(custom);
      return host ? t('dns.custom.named', { host: host }) : (p ? pTxt(p, 'name') : t('dns.preset.custom.name'));
    }
    return p ? pTxt(p, 'name') : str(id);
  }
  /* 按地址的协议给预设分组: DoH (https://) / DoT (tls://) / UDP (udp://) / 其它 (系统默认、自定义) */
  function groupOf(p) {
    var u = str(p.url).trim().toLowerCase();
    if (u.indexOf('https://') === 0) return 'doh';
    if (u.indexOf('tls://') === 0) return 'dot';
    if (u.indexOf('udp://') === 0) return 'udp';
    return 'other';
  }

  /* GET /api/dns -> 补全默认值; 形状不对就报错 (走错误状态) */
  function norm(r) {
    var s = r && r.settings, p = r && r.presets;
    if (!s || typeof s !== 'object' || !p || typeof p !== 'object') throw TP.mkErr('http', t('dns.state.badData'));
    function list(a) { return Array.isArray(a) ? a.filter(function (x) { return x && x.id != null; }) : []; }
    var ads = bool(s.ads_block, false);
    return {
      settings: {
        cn: str(s.cn), cn_custom: str(s.cn_custom), global: str(s.global), global_custom: str(s.global_custom),
        via: s.via === 'PIN' ? 'PIN' : 'Global', strategy: str(s.strategy) || 'prefer_ipv4',
        leak_guard: bool(s.leak_guard, true), ads_block: ads
      },
      presets: { cn: list(p.cn), global: list(p.global) },
      pipeline: Array.isArray(r.pipeline) ? r.pipeline.filter(function (x) { return x && typeof x === 'object' && (ads || x.id !== 'ads'); }) : [],      // 「广告」这一步只在开启屏蔽广告时出现
      hosts: Array.isArray(r.hosts) ? r.hosts.filter(function (x) { return x && x.domain != null; }).map(function (x) { return { domain: str(x.domain), ip: str(x.ip) }; }) : []
    };
  }

  /* ---------- 校验: 域名 (同「网站」页的域名规则) 与 IP (IPv4 / IPv6) ---------- */
  /* 返回 {v: 规范化后的域名} 或 {err: 说明}。小写由我们代劳 (域名不分大小写); 末尾的一个点去掉 */
  function checkDomain(raw) {
    var s = str(raw).trim().toLowerCase(), labels, i;
    if (!s) return { err: t('dns.hs.err.domain.empty') };
    if (/\s/.test(s)) return { err: t('dns.hs.err.domain.space') };
    if (s.indexOf('*') >= 0) return { err: t('dns.hs.err.domain.wild') };
    if (/[\/\\?#@:]/.test(s)) return { err: t('dns.hs.err.domain.proto') };            // 协议 / 路径 / 端口 / 账号
    s = s.replace(/\.$/, '');
    if (!s) return { err: t('dns.hs.err.domain.empty') };
    if (s.length > 253) return { err: t('dns.hs.err.domain.long') };
    if (!/^[a-z0-9.-]+$/.test(s)) return { err: t('dns.hs.err.domain.chars') };
    if (/^\d{1,3}(\.\d{1,3}){3}$/.test(s)) return { err: t('dns.hs.err.domain.isip') };
    labels = s.split('.');
    for (i = 0; i < labels.length; i++) if (!/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(labels[i])) return { err: t('dns.hs.err.domain.label') };
    return { v: s };
  }
  /* IPv4 / IPv6 -> {v:4|6, key: 规范形式 (比较用)}, 不合法返回 null。方括号 ([::1]) 去掉; IPv4 的段不能有前导 0 (有歧义) */
  function parseIp(raw) {
    var s = str(raw).trim(), p, i, m, v4, q, dbl, head, rest, all, groups;
    if (/^\[.*\]$/.test(s)) s = s.slice(1, -1);
    if (/^\d{1,3}(\.\d{1,3}){3}$/.test(s)) {
      p = s.split('.');
      for (i = 0; i < 4; i++) if ((p[i].length > 1 && p[i].charAt(0) === '0') || +p[i] > 255) return null;
      return { v: 4, key: p.map(Number).join('.'), text: s };
    }
    if (s.indexOf(':') < 0 || !/^[0-9a-fA-F:.]+$/.test(s)) return null;
    m = /^(.*:)(\d{1,3}(?:\.\d{1,3}){3})$/.exec(s);                                     // ::ffff:1.2.3.4
    if (m) {
      v4 = parseIp(m[2]);
      if (!v4 || v4.v !== 4) return null;
      q = v4.key.split('.').map(Number);
      s = m[1] + (q[0] * 256 + q[1]).toString(16) + ':' + (q[2] * 256 + q[3]).toString(16);
    }
    dbl = s.split('::');
    if (dbl.length > 2) return null;
    head = dbl[0] ? dbl[0].split(':') : [];
    rest = dbl.length === 2 ? (dbl[1] ? dbl[1].split(':') : []) : null;
    all = rest === null ? head : head.concat(rest);
    for (i = 0; i < all.length; i++) if (!/^[0-9a-fA-F]{1,4}$/.test(all[i])) return null;
    if (rest === null) { if (all.length !== 8) return null; groups = all; }
    else { if (all.length > 7) return null; groups = head.concat(new Array(8 - all.length).fill('0'), rest); }
    return { v: 6, key: groups.map(function (g) { return parseInt(g, 16).toString(16); }).join(':'), text: str(raw).trim().replace(/^\[|\]$/g, '') };
  }
  function checkIp(raw) {
    var s = str(raw).trim(), r;
    if (!s) return { err: t('dns.hs.err.ip.empty') };
    r = parseIp(s);
    if (r) return { v: r.text, key: r.key };
    if (/^\d{1,3}(\.\d{1,3}){3}$/.test(s) && s.split('.').some(function (x) { return x.length > 1 && x.charAt(0) === '0'; })) return { err: t('dns.hs.err.ip.zero') };      // 01.2.3.4: 有歧义 (有的系统当八进制), 要说清楚怎么改
    return { err: t('dns.hs.err.ip.bad') };
  }
  function hostEntry(domain) {
    var a = (D && D.hosts) || [], i;
    for (i = 0; i < a.length; i++) if (a[i].domain === domain) return a[i];
    return null;
  }

  /* ================= 测速的数据 ================= */
  /* job.result -> {cn:{id:ms|null}, global:{…}}; ms 缺失 / 非数字 / 负数 = 不通 (null) */
  function cleanBench(r) {
    var out = { cn: {}, global: {}, via: r && (r.via === 'direct' || r.via === 'Global' || r.via === 'PIN') ? r.via : '' };            // via = 海外预设实际经过的线路 (direct = 没有可用的服务器, 海外预设全部测不通)
    ['cn', 'global'].forEach(function (sc) {
      var m = r && r[sc];
      if (!m || typeof m !== 'object') return;
      Object.keys(m).forEach(function (id) { var v = m[id]; out[sc][id] = typeof v === 'number' && isFinite(v) && v >= 0 ? Math.max(1, Math.round(v)) : null; });
    });
    return out;
  }
  function parseBench(result) {
    var map = { cn: {}, global: {}, via: result && result.via };
    ['cn', 'global'].forEach(function (sc) {
      (result && Array.isArray(result[sc]) ? result[sc] : []).forEach(function (x) {
        var ms;
        if (!x || x.id == null) return;
        ms = x.ms == null || x.ms === '' ? NaN : +x.ms;
        map[sc][str(x.id)] = isFinite(ms) ? ms : null;
      });
    });
    return cleanBench(map);
  }
  function hasBench(r) { return !!r && (Object.keys(r.cn).length + Object.keys(r.global).length) > 0; }
  (function restoreBench() {                                                          // 同一个标签页里刷新页面后还在 (sessionStorage 随标签页消失)
    var o = TP.ss.get('dns.bench', null), r;
    if (!o || typeof o !== 'object' || !o.res || !(+o.at > 0)) return;
    r = cleanBench(o.res);
    if (hasBench(r)) { bn.res = r; bn.at = +o.at; }
  })();
  /* undefined = 没测过这个预设; null = 不通; 数字 = 毫秒 */
  function benchOf(scope, id) { var m = bn.res && bn.res[scope]; return m && Object.prototype.hasOwnProperty.call(m, id) ? m[id] : undefined; }
  function measuredCount(scope) { var m = bn.res && bn.res[scope]; return m ? Object.keys(m).length : 0; }
  /* 最快的预设 (「自定义」不参与: 它没有名字可以推荐) */
  function fastest(scope) {
    var best = null;
    ((D && D.presets[scope]) || []).forEach(function (p) {
      var id = str(p.id), v = benchOf(scope, id);
      if (id === 'custom' || typeof v !== 'number') return;
      if (!best || v < best.ms) best = { p: p, id: id, ms: v };
    });
    return best;
  }
  /* 延迟徽标: 绿 < 40 ms · 琥珀 40–150 ms · 红 > 150 ms 或不通; 文字 + 图标 + 读屏文字, 不只靠颜色 */
  function benchBadge(scope, id) {
    var v, b, kind, icon, text, sr;
    if (!bn.res) return null;
    v = benchOf(scope, id);
    if (v === undefined) return h('span', { class: 'badge neutral dns-lat', title: L('dns.bn.na.t') }, t('dns.bn.na'));
    if (v === null) { kind = 'bad'; icon = 'wifi-off'; text = t('dns.bn.unreach'); sr = ''; }
    else if (v < 40) { kind = 'ok'; icon = 'zap'; text = t('dns.bn.ms', { n: fmt.num(v) }); sr = t('dns.bn.fast'); }
    else if (v <= 150) { kind = 'warn'; icon = 'clock'; text = t('dns.bn.ms', { n: fmt.num(v) }); sr = t('dns.bn.mid'); }
    else { kind = 'bad'; icon = 'warning'; text = t('dns.bn.ms', { n: fmt.num(v) }); sr = t('dns.bn.slow'); }
    b = ui.badge(text, kind, icon);
    b.classList.add('dns-lat');
    if (sr) b.appendChild(h('span', { class: 'sr' }, ' (' + sr + ')'));
    return b;
  }
  /* 「最快: 阿里 DNS (23 ms) — 采用」一行; use(id) 由调用方决定 (选中 / 打开设置并选中)。withLabel: 前面带「国内 DNS:」 */
  function suggestionNode(scope, curId, use, withLabel) {
    var best, label, name, b, why, noRoute, fix;
    if (!bn.res || !D) return null;
    best = fastest(scope);
    label = withLabel ? h('b', { class: 'dns-sg-l' }, t(SCOPE[scope].label)) : null;
    if (!best) {
      if (!measuredCount(scope)) return null;
      noRoute = scope === 'global' && bn.res.via === 'direct';                      // 没有服务器: 海外预设没有线路可测, 全部不通
      why = noRoute ? t('dns.bn.noRoute') : (scope === 'global' ? TP.why.auto() : '');
      b = null;
      if (noRoute) { fix = addFix(); b = ui.btn(fix.label, { sm: true, icon: 'plus' }); ui.act(b, fix.fn); }
      return h('div', { class: 'dns-sg warn', role: 'status' }, ui.icon('warning', 16, 'ci'), h('span', null, label, ' ', t('dns.bn.none'), why ? ' ' + why : ''), b);
    }
    name = pTxt(best.p, 'name');
    if (best.id === str(curId)) return h('div', { class: 'dns-sg ok', role: 'status' }, ui.icon('success', 16, 'ci'), h('span', null, label, ' ', t('dns.bn.already', { name: name }), ' ', benchBadge(scope, best.id)));
    b = ui.btn(t('dns.bn.use'), { sm: true, icon: 'check' });
    ui.act(b, function () { return use(best.id); });
    return h('div', { class: 'dns-sg', role: 'status' }, ui.icon('zap', 16, 'ci'), h('span', null, label, ' ', t('dns.bn.fastest', { name: name }), ' ', benchBadge(scope, best.id)), b);
  }

  /* ================= 测速条 (页面里一个、设置弹窗里一个、选择弹层里一个): 按钮 + 「!」 + 「测于 hh:mm」+ 进度卡片 ================= */
  function benchBar(o) {
    var v = { onSync: o && o.onSync, card: null };
    v.btn = ui.btn(t('dns.bn.btn'), { icon: 'speed' });
    ui.act(v.btn, function () { return runBench(); });
    v.st = h('span', { class: 'muted sm dns-bn-st', 'aria-live': 'polite' });
    v.prog = h('div', { class: 'dns-prog', hidden: true });
    v.el = h('div', { class: 'dns-bn' }, h('div', { class: 'dns-bn-row' }, v.btn, H('bench'), v.st), v.prog);
    v.sync = function () {
      var run = bn.running, sig = [run, bn.at, I.lang, TP.why.auto()].join('|');
      ui.setBtn(v.btn, t(run ? 'dns.bn.running' : 'dns.bn.btn'), run ? 'refresh' : 'speed');
      ui.avail(v.btn, run ? t('dns.bn.busyReason') : TP.why.helper());
      v.btn.classList.toggle('is-busy', run);
      setText(v.st, run ? '' : bn.at ? t('dns.bn.at', { time: fmt.clock(bn.at) }) : t('dns.bn.never'));
      if (v.onSync && v.sig !== sig) { v.sig = sig; v.onSync(); }               // 只在结果 / 语言 / 状态真的变了才通知使用方重画 (轮询触发的刷新不能打断焦点)
    };
    v.dispose = function () { bn.views = bn.views.filter(function (x) { return x !== v; }); if (v.card) { var i = bn.cards.indexOf(v.card); if (i >= 0) bn.cards.splice(i, 1); } };
    bn.views.push(v);
    if (bn.running) mountCard(v);
    v.sync();
    return v;
  }
  function syncBench() { bn.views.slice().forEach(function (v) { v.sync(); }); }
  function mountCard(v) {
    var c = ui.taskCard(t('dns.bn.title')), close = c.close;
    c.close = function () { close(); v.prog.hidden = true; var i = bn.cards.indexOf(c); if (i >= 0) bn.cards.splice(i, 1); };
    TP.clear(v.prog); v.prog.appendChild(c.el); v.prog.hidden = false;
    c.set({ pct: null, msg: t('dns.bn.sending') });
    bn.cards.push(c); v.card = c;
    return c;
  }
  async function runBench() {
    var why = TP.why.helper(), fan, cards, res, r, j, msg = '', ok = false;
    if (why) { ui.toast(why, 'warn'); return; }
    if (bn.running) { ui.toast(t('dns.bn.busyReason'), 'warn'); return; }
    bn.running = true;
    bn.views.slice().forEach(mountCard);
    syncBench();
    fan = { fromJob: function (job) { bn.cards.slice().forEach(function (c) { c.fromJob(job); }); } };      // 同一个任务同时喂给所有正在显示的进度卡片
    try {
      r = await TP.helper('POST', '/api/dns/bench', { timeout: 20000 });
      j = r && r.job ? await TP.jobs.follow(r.job, fan, { quiet: true }) : r;                              // quiet: 只读任务, 不让顶栏变成「正在应用配置」
      res = parseBench(j && j.result);
      if (!hasBench(res)) throw TP.mkErr('http', t('dns.bn.empty'));
      bn.res = res; bn.at = Date.now();
      TP.ss.set('dns.bench', { at: bn.at, res: bn.res });
      ok = true;
    } catch (e) {
      msg = e && (e.kind === 'auth' || e.kind === 'cancel') ? null : errText(e);
    }
    bn.running = false;
    cards = bn.cards.slice();
    if (ok) cards.forEach(function (c) { c.done(t('dns.bn.done')); setTimeout(c.close, 2500); });
    else if (msg === null) cards.forEach(function (c) { c.close(); });
    else cards.forEach(function (c) { c.fail(msg); });
    syncBench();
  }

  /* ================= 构建 ================= */
  V.init = function (root) {
    el.state = ui.emptyBox();

    /* 当前设置 + 测速 */
    el.change = ui.btn(L('dns.change'), { kind: 'primary', icon: 'sliders-horizontal' });
    ui.act(el.change, function () { return openSettings(); });
    el.sum = h('ul', { class: 'dns-sum' });
    el.adsBtn = TP.bindRulesBtn(ui.btn('', { sm: true, icon: 'download-cloud' }));          // 文字和状态由 actions.js 统一管理
    el.adsNote = h('div', { class: 'hint warn dns-warn', role: 'status', hidden: true }, ui.icon('warning', 16, 'ci'), h('span', null, L('dns.ads.missing')), el.adsBtn);
    el.bnSug = h('div', { class: 'dns-sgs' });
    el.bar = benchBar({ onSync: function () { if (D) { renderSummary(); renderBenchSug(); } } });
    /* 流程图 */
    plSo = ui.sorter('dns-pl', {
      match: { get: function (it) { return stepTitle(it); } },
      server: { get: function (it) { return serverText(it, viaCode(it.via)); } },
      path: { get: function (it) { return viaText(it); } }
    }, { onChange: function () { if (D) renderPipeline(); } });
    el.plBody = h('tbody');
    el.plBox = h('div', { class: 'dns-pl-box' }, h('div', { class: 'tbl-wrap' }, h('table', { class: 'tbl rt dns-pl', 'aria-label': L('dns.pipe.aria') },
      h('thead', null, h('tr', null, plSo.th('match', function () { return t('dns.pl.col.match'); }), plSo.th('server', function () { return t('dns.pl.col.server'); }), plSo.th('path', function () { return t('dns.pl.col.path'); }))),
      el.plBody)));
    el.pipeEmpty = ui.emptyBox();

    /* 默认已开启的优化 (不用设置, 只说明) */
    el.opts = h('ul', { class: 'dns-opts' }, OPTS.map(function (o) {
      return h('li', { class: 'dns-opt' },
        h('span', { class: 'dns-opt-ic', 'aria-hidden': 'true' }, ui.icon(o.icon, 20)),
        h('div', { class: 'dns-opt-b' }, h('div', { class: 'dns-opt-t' }, h('b', null, L(o.t)), H(o.help)), h('p', { class: 'dns-opt-d' }, L(o.d))),
        ui.badge(L('dns.opt.on'), 'ok', 'check'));
    }));

    /* 自定义解析 */
    buildHosts();

    el.body = h('div', { class: 'dns-body', hidden: true },
      h('section', { class: 'card' },
        h('div', { class: 'card-h' }, h('h3', null, L('dns.sum.title')), el.change),
        el.sum, el.adsNote, el.bar.el, el.bnSug),
      h('section', { class: 'card' },
        h('div', { class: 'card-h' }, h('h3', null, L('dns.pipe.title'), H('pipe')), h('span', { class: 'muted sm' }, L('dns.pipe.sub'))),
        el.plBox, el.pipeEmpty.el),
      h('section', { class: 'card' },
        h('div', { class: 'card-h' }, h('h3', null, L('dns.opt.title')), h('span', { class: 'muted sm' }, L('dns.opt.sub'))),
        el.opts),
      el.hsCard);

    /* 解析测试 */
    el.inp = h('input', {
      class: 'inp mono', id: 'dns-test-in', type: 'text', placeholder: L('dns.test.ph'), 'aria-label': L('dns.test.field'),
      autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off', on: { input: function () { hintName(false); } }
    });
    el.go = ui.btn(t('dns.test.go'), { kind: 'primary', icon: 'search', cls: 'dns-go' });
    ui.act(el.go, function () { return runTest(); });
    el.nameHint = h('div', { class: 'fld-h dns-m', 'aria-live': 'polite' });
    el.hist = h('div', { class: 'dns-hist-l' });
    el.histBox = h('div', { class: 'dns-hist', hidden: true }, h('span', { class: 'muted sm' }, L('dns.test.recent')), el.hist);
    el.res = h('div', { class: 'dns-res', 'aria-live': 'polite' });
    var form = h('form', { class: 'dns-test-row', novalidate: true, on: { submit: function (ev) { ev.preventDefault(); el.go.click(); } } }, el.inp, el.go);
    el.testCard = h('section', { class: 'card', id: 'dns-test' },
      h('div', { class: 'card-h' }, h('h3', null, L('dns.test.title'), H('test')), h('span', { class: 'muted sm' }, L('dns.test.sub'))),
      h('label', { class: 'fld-l', for: 'dns-test-in' }, L('dns.test.field')), form, el.nameHint, el.histBox, el.res);

    root.appendChild(h('div', { class: 'intro' }, h('p', { class: 'muted' }, L('dns.intro'), H('page'))));
    root.appendChild(h('div', { class: 'dns-scope', role: 'note' }, ui.icon('info', 18, 'ci'), h('div', null, h('b', null, L('dns.scope.title')), h('p', null, L('dns.scope.text')))));
    root.appendChild(el.state.el);
    root.appendChild(el.body);
    root.appendChild(el.testCard);

    TP.on('auth', function (ok) { if (ok && active()) load(); syncBench(); syncHs(); });
    TP.on('helper', function (up) { if (up && active() && !D && !inflight) load(); syncBench(); syncHs(); });       // 辅助服务恢复了: 自动重试
    TP.on('state', function () { if (active() && D) renderAds(); });
    TP.on('proxies', function () { if (modalSync) modalSync(); syncBench(); });
    TP.on('lang', function () { render(); renderGo(); renderResult(); renderHist(); if (el.inp.value) hintName(false); if (hs.add) hs.add.recheck(); syncBench(); if (modalSync) modalSync(); });
    render(); renderGo();
  };
  V.show = function () { load(); };

  /* ================= 读取 ================= */
  function load() {
    if (S.locked) return Promise.resolve();
    var seq = ++loadSeq;
    inflight++;
    if (!D) { loadErr = null; render(); }
    return TP.helper('GET', '/api/dns', { timeout: 10000 }).then(norm).then(function (d) {
      if (seq !== loadSeq) return;
      D = d; loadErr = null; render();
    }).catch(function (e) {
      if (seq !== loadSeq || (e && e.kind === 'auth')) return;
      if (D) { ui.toast(errText(e), 'err'); return; }            // 保留上一次读到的内容, 只提示失败
      loadErr = e; render();
    }).finally(function () { inflight--; });
  }

  function render() {
    el.body.hidden = !D;
    if (D) { el.state.hide(); renderSummary(); renderBenchSug(); renderPipeline(); renderAds(); renderHosts(); return; }
    if (loadErr) showFail(loadErr);
    else el.state.show({ icon: 'refresh', text: t('dns.state.loading') });
  }
  function showFail(e) {
    var retry = { label: t('common.retry'), icon: 'refresh', fn: function () { return load(); } };
    if (e && e.kind === 'unreachable') el.state.show({ icon: 'wifi-off', text: TP.why.helper() || t('dns.state.noHelper'), hint: t('dns.state.noHelperHint'), action: retry });
    else el.state.show({ icon: 'warning', text: t('dns.state.failed'), hint: errText(e), action: retry });
  }

  /* ================= 当前设置摘要 (+ 测速结果) ================= */
  function renderSummary() {
    var s = D.settings, on = s.leak_guard;
    var items = [
      { k: 'dns.f.cn', v: srvName('cn', s.cn, s.cn_custom), sc: 'cn', id: s.cn },
      { k: 'dns.f.global', v: on ? srvName('global', s.global, s.global_custom) : t('dns.notUsed'), c: on ? '' : 'dim', sc: on ? 'global' : '', id: s.global },
      { k: 'dns.f.strategy', v: strategyName(s.strategy) },
      { k: 'dns.f.leak', v: onOff(on), c: on ? 'ok' : 'warn' },
      { k: 'dns.f.ads', v: onOff(s.ads_block), c: s.ads_block ? 'ok' : 'dim' }
    ];
    var sig = JSON.stringify(items.map(function (it) { return [it.k, it.v, it.c, it.sc ? String(benchOf(it.sc, it.id)) : '']; })) + '|' + bn.at;
    ui.memo(el.sum, sig, function () {
      var f = document.createDocumentFragment();
      items.forEach(function (it) {
        var lat = it.sc ? benchBadge(it.sc, it.id) : null;
        f.appendChild(h('li', { class: 'dns-li' + (it.c ? ' ' + it.c : '') }, h('span', { class: 'dns-k' }, t(it.k)), h('b', { class: 'dns-v' }, it.v), lat));
      });
      return f;
    });
  }
  /* 页面里的测速建议: 相对于「已保存的」设置; 「采用」打开设置弹窗并选中它 (还要点保存) */
  function renderBenchSug() {
    var sig = !D || !bn.res ? '' : [bn.at, D.settings.cn, D.settings.global, D.settings.leak_guard, TP.why.auto()].join('|');
    ui.memo(el.bnSug, sig, function () {
      var f = document.createDocumentFragment();
      if (!sig) return null;
      ['cn', 'global'].forEach(function (sc) {
        var n;
        if (sc === 'global' && !D.settings.leak_guard) return;                      // 防泄漏关闭时海外 DNS 用不到, 不必建议
        n = suggestionNode(sc, D.settings[sc], function (id) { return openSettings({ scope: sc, id: id }); }, true);
        if (n) f.appendChild(n);
      });
      return f;
    });
  }
  /* 屏蔽广告开着, 但广告规则集 (geosite-ads) 还没下载 (state.env.rules_missing 里有它): 实际不会屏蔽任何东西, 要说出来 */
  function adsMissing() {
    var env = (S.state && S.state.env) || {};
    return !!(D && D.settings.ads_block && (env.rules_missing || []).indexOf('geosite-ads') >= 0);
  }
  function renderAds() { el.adsNote.hidden = !adsMissing(); }

  /* ================= 流程图: 一张「从上往下检查, 第一个匹配的负责回答」的表 ================= */
  function viaCode(v) {
    v = str(v).trim();
    return (v === 'direct' || v === 'auto' || v === 'pin' || v === 'none') ? v : (v === '-' ? 'none' : '');
  }
  function stepKey(it) {
    var id = str(it.id);
    return STEPS[id] ? id : (STEP_BY_MATCH[str(it.match)] || '');
  }
  /* DNS 服务器显示名: 特殊代码 (hosts / proxy / reject) -> server_name(_en) -> 预设 id -> custom -> 原样 */
  function serverText(it, vcode) {
    var n = I.pick(it, 'server_name'), s = str(it.server), scope, other, p;
    if (s === 'reject') return t('dns.server.reject');
    if (s === 'hosts' || str(it.id) === 'hosts') return t('dns.pl.srv.hosts', { n: D.hosts.length });
    if (s === 'proxy' || s === 'remote') return t('dns.pl.srv.proxy');
    if (n) return n;
    scope = (it.id === 'global' && vcode !== 'direct') ? 'global' : 'cn';       // 防泄漏关闭时, 海外这一步实际用的是国内 DNS
    other = scope === 'cn' ? 'global' : 'cn';
    if (s === 'custom') return srvName(scope, 'custom', D.settings[scope + '_custom']);
    p = presetOf(scope, s) || presetOf(other, s);
    return p ? pTxt(p, 'name') : s;
  }
  function globalDetail(it, vcode) {
    if (vcode === 'direct') return t('dns.pipe.global.direct');
    if (vcode === 'auto' || vcode === 'pin') return t('dns.pipe.global.via', { route: TP.name.route(vcode) });
    return str(it.detail);
  }
  function pathNode(it) {
    var vcode = viaCode(it.via), rawVia = str(it.via).trim();
    if (VIA_ICON[vcode]) return h('span', { class: 'dns-via ' + vcode }, ui.icon(VIA_ICON[vcode], 14, 'ci'), TP.name.route(vcode));
    if (vcode === 'none') return h('span', { class: 'dns-via none' }, t('dns.via.none'));
    return rawVia ? h('span', { class: 'dns-via' }, rawVia) : null;
  }
  function td(labelKey, cls) { var kids = Array.prototype.slice.call(arguments, 2); return h.apply(null, ['td', { 'data-l': labelKey ? L(labelKey) : '', class: cls || '' }].concat(kids)); }
  /* 「匹配的网站」列显示的名称 / 「路径」列显示的文字 (排序用的也是它们) */
  function stepTitle(it) {
    var st = STEPS[stepKey(it)];
    return st ? t(st.t) : (I.pick(it, 'title') || I.pick(it, 'match_name') || str(it.match) || str(it.id));
  }
  function viaText(it) {
    var vcode = viaCode(it.via);
    return VIA_ICON[vcode] ? TP.name.route(vcode) : vcode === 'none' ? t('dns.via.none') : str(it.via).trim();
  }
  function pipeRow(it, i) {
    var k = stepKey(it), st = STEPS[k], vcode = viaCode(it.via), title, detail, cls;
    title = stepTitle(it);
    detail = k === 'global' ? globalDetail(it, vcode) : (st && st.d ? t(st.d) : str(it.detail));
    cls = 'dns-pl-r' + (VIA_ICON[vcode] ? ' v-' + vcode : ' v-none') + (k ? ' is-' + k : '');
    return h('tr', { class: cls },
      td('', 'c-name', h('div', { class: 'dns-st' },
        h('div', { class: 'dns-st-h' },
          h('span', { class: 'dns-st-n', 'aria-hidden': 'true' }, String(i + 1)),
          h('span', { class: 'dns-st-ic', 'aria-hidden': 'true' }, ui.icon(st ? st.icon : 'server', 18)),
          h('b', { class: 'dns-st-t' }, h('span', { class: 'sr' }, t('dns.pl.step', { n: i + 1 }) + ': '), title)),
        detail ? h('p', { class: 'dns-st-d' }, detail) : null)),
      td('dns.pl.col.server', 'c-srv', h('span', { class: 'dns-st-s' }, serverText(it, vcode))),
      td('dns.pl.col.path', 'c-path', pathNode(it)));
  }
  function renderPipeline() {
    var pl = D.pipeline;
    /* 不排序: 评估顺序 (第一个匹配的负责回答); 点了列头: 只是换个看法, 步骤编号还是评估顺序里的第几步。表头一直在 (排序按钮不会因为重画丢掉键盘焦点), 只重画 tbody */
    ui.memo(el.plBody, JSON.stringify([pl, D.presets, D.settings, D.hosts.length, plSo.state()]), function () {
      var f = document.createDocumentFragment();
      plSo.apply(pl).forEach(function (it) { f.appendChild(pipeRow(it, pl.indexOf(it))); });
      return f;
    });
    el.plBox.hidden = !pl.length;
    if (pl.length) el.pipeEmpty.hide(); else el.pipeEmpty.show({ icon: 'info', text: t('dns.pipe.empty') });
  }

  /* ================= 自定义解析 (hosts) ================= */
  function buildHosts() {
    el.hsCount = h('span', { class: 'chip dns-hs-n' });
    el.hsClear = ui.btn(L('dns.hs.clear'), { sm: true, cls: 'soft-bad', icon: 'delete' });
    ui.act(el.hsClear, function () { return clearHosts(); });
    el.hsProg = h('div', { class: 'dns-prog', hidden: true });
    hs.add = hostForm({ mode: 'add', onSubmit: addHost });
    el.hsFilter = h('input', {
      class: 'inp', type: 'search', placeholder: L('dns.hs.filter.ph'), 'aria-label': L('dns.hs.filter.aria'), autocomplete: 'off', spellcheck: 'false',
      on: { input: function () { hs.filter = el.hsFilter.value; if (hs.pg.page() !== 1) hs.pg.setPage(1); renderHosts(); } }
    });
    el.hsTools = h('div', { class: 'dns-hs-tools', hidden: true }, el.hsFilter);
    el.hsBody = h('tbody');
    el.hsEmpty = ui.emptyBox();
    hs.pg = ui.pager('dns.hosts', { def: 10 });                      // i18n-ignore (翻页器的 id, 不是词典键)
    hs.pg.onChange(function () { renderHosts(); });
    hsSo = ui.sorter('dns-hosts', {
      domain: { get: function (x) { return x.domain; } },
      ip: { get: function (x) { return ipKey(x.ip); } }
    }, { onChange: function () {                                      // 排序变了回到第 1 页 (setPage 会重画); 正在编辑的那一行跟着排序换了位置, 就翻到它所在的那一页 (不要让编辑框消失)
      if (hs.edit) hs.flash = hs.edit.orig;
      else if (hs.pg.page() !== 1) { hs.pg.setPage(1); return; }
      renderHosts();
    } });
    el.hsTbl = h('div', { class: 'tbl-wrap' }, h('table', { class: 'tbl rt dns-hs-tbl' },
      h('thead', null, h('tr', null, hsSo.th('domain', function () { return t('dns.hs.col.domain'); }), hsSo.th('ip', function () { return t('dns.hs.col.ip'); }), h('th', { scope: 'col', class: 'c-act' }, L('dns.hs.col.act')))),
      el.hsBody));
    el.hsList = h('div', { class: 'dns-hs-list' }, el.hsTbl, el.hsEmpty.el, hs.pg.el);
    var go = h('button', { class: 'dns-link', type: 'button', on: { click: function () { goTest('', false); } } }, ui.icon('search', 14, 'ci'), L('dns.hs.tip.go'));
    el.hsCard = h('section', { class: 'card dns-hs' },
      h('div', { class: 'card-h' }, h('h3', null, L('dns.hs.title'), H('hosts')), el.hsCount, el.hsClear),
      h('p', { class: 'muted sm dns-hs-sub' }, L('dns.hs.intro')),
      hs.add.el, el.hsProg, el.hsTools, el.hsList,
      h('p', { class: 'dns-hs-tip muted sm' }, L('dns.hs.tip'), ' ', go));
  }

  /* 一行输入 (域名 + IP) + 提交 / 取消: 顶部的「添加」和表格里的「行内编辑」共用。o: {mode:'add'|'edit', domain, ip, orig, onSubmit(vals)->Promise<{ok,msg}>, onCancel(), onInput(vals)} */
  function hostForm(o) {
    var edit = o.mode === 'edit', n = ++uid, f = { touched: { d: false, i: false }, orig: o.orig || '' };
    f.d = h('input', { class: 'inp mono', type: 'text', id: 'dns-hd' + n, placeholder: L('dns.hs.ph.domain'), autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off', 'aria-describedby': 'dns-hdm' + n, value: o.domain || '' });
    f.i = h('input', { class: 'inp mono', type: 'text', id: 'dns-hi' + n, placeholder: L('dns.hs.ph.ip'), autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off', 'aria-describedby': 'dns-him' + n, value: o.ip || '' });
    f.dm = h('div', { class: 'fld-h dns-hs-m dns-m', id: 'dns-hdm' + n, 'aria-live': 'polite' });
    f.im = h('div', { class: 'fld-h dns-hs-m dns-m', id: 'dns-him' + n, 'aria-live': 'polite' });
    f.fm = h('div', { class: 'fld-h dns-hs-fm dns-m', role: 'alert', hidden: true });
    f.ok = ui.btn(edit ? L('common.save') : L('dns.hs.add'), { kind: 'primary', icon: edit ? 'check' : 'plus', cls: 'dns-hs-ok' });
    f.cancel = edit ? ui.btn(L('common.cancel'), { cls: 'dns-hs-cancel' }) : null;
    f.el = h('div', { class: 'dns-hs-form' + (edit ? ' is-edit' : ''), role: 'group', 'aria-label': L(edit ? 'dns.hs.edit.form' : 'dns.hs.add.form') },
      h('div', { class: 'dns-hs-f' }, h('label', { class: 'fld-l', for: 'dns-hd' + n }, L('dns.hs.f.domain')), f.d, f.dm),
      h('div', { class: 'dns-hs-f' }, h('label', { class: 'fld-l', for: 'dns-hi' + n }, L('dns.hs.f.ip')), f.i, f.im),
      h('div', { class: 'dns-hs-b' }, h('div', { class: 'dns-hs-bb' }, f.ok, f.cancel)),
      f.fm);
    function say(msg) { f.fm.hidden = !msg; setText(f.fm, msg || ''); f.fm.classList.toggle('bad-t', !!msg); }
    /* 随输入校验; show = 强制显示 (提交时), 否则只在用户碰过这个输入框后才显示。返回第一个不合法的输入框 (没有则 null) */
    function check(show) {
      var dv = checkDomain(f.d.value), iv = checkIp(f.i.value), dm = dv.err || '', im = iv.err || '', bad = null, sd, si;
      if (!dm && hostEntry(dv.v) && dv.v !== f.orig) dm = t('dns.hs.err.domain.dup');
      sd = !!dm && (show || f.touched.d); si = !!im && (show || f.touched.i);
      TP.setCls(f.dm, 'fld-h dns-hs-m dns-m' + (sd ? ' bad-t' : '')); setText(f.dm, sd ? dm : '');
      TP.setCls(f.im, 'fld-h dns-hs-m dns-m' + (si ? ' bad-t' : '')); setText(f.im, si ? im : '');
      f.d.setAttribute('aria-invalid', sd ? 'true' : 'false'); f.i.setAttribute('aria-invalid', si ? 'true' : 'false');
      if (dm) bad = f.d; else if (im) bad = f.i;
      return { bad: bad, domain: dv.v || '', ip: iv.v || '' };
    }
    function changed() { return f.d.value.trim() !== str(o.domain) || f.i.value.trim() !== str(o.ip); }
    f.dirty = changed;
    f.recheck = function () { check(false); };
    f.reset = function () {
      f.d.value = ''; f.i.value = ''; f.touched.d = false; f.touched.i = false; say('');
      check(false); if (!coarse()) f.d.focus();
    };
    f.say = say;
    [f.d, f.i].forEach(function (inp) {
      inp.addEventListener('input', function () {
        f.touched[inp === f.d ? 'd' : 'i'] = true; say(''); check(false);
        if (o.onInput) o.onInput({ domain: f.d.value, ip: f.i.value });
      });
      inp.addEventListener('keydown', function (e) {
        if (e.key === 'Enter' && !e.isComposing && e.keyCode !== 229) { e.preventDefault(); f.ok.click(); }
        else if (e.key === 'Escape' && o.onCancel) { e.preventDefault(); e.stopPropagation(); o.onCancel(); }
      });
    });
    ui.act(f.ok, async function () {
      var c = check(true), r;
      if (c.bad) { c.bad.focus(); return; }
      if (edit && !f.dirty()) { say(t('dns.hs.noChange')); return; }
      say('');
      r = await o.onSubmit({ domain: c.domain, ip: c.ip });
      if (r && r.msg) say(r.msg);
    });
    if (f.cancel) ui.act(f.cancel, function () { if (o.onCancel) o.onCancel(); });
    hs.forms.push(f);
    check(false);
    return f;
  }

  /* 新增 / 修改 / 删除 / 清空 都是任务: 在卡片里用 taskCard 跟踪, 完成后重新读取 GET /api/dns。
   * 提交被后端拒绝 (E_INVALID 等, 还没有任务) 时返回 {msg} 让表单把原因显示在输入框旁边; 其它错误用 toast / 进度卡片。 */
  async function hostsJob(form, o) {
    var why = TP.why.helper(), card, r, name = o.flash || '';
    if (why) { ui.toast(why, 'warn'); return { ok: false }; }
    if (hs.busy) { ui.toast(t('dns.hs.busy'), 'warn'); return { ok: false }; }
    hs.busy = true; syncHs();
    try {
      r = await TP.helper('POST', o.path || '/api/dns/hosts', { form: form, timeout: 20000 });
    } catch (e) {
      hs.busy = false; syncHs();
      if (e && (e.kind === 'auth' || e.kind === 'cancel')) return { ok: false };
      if (e && e.kind === 'api') { if (e.code === 'E_NOT_FOUND') load(); return { ok: false, msg: errText(e) }; }
      ui.toast(errText(e), 'err');
      return { ok: false };
    }
    card = ui.taskCard(t(o.title));
    TP.clear(el.hsProg); el.hsProg.appendChild(card.el); el.hsProg.hidden = false;
    card.set({ pct: null, msg: t('dns.hs.sending') });
    try {
      if (r && r.job) await TP.jobs.follow(r.job, card);
      card.done(t(o.done, o.vars));
      ui.toast(t(o.done, o.vars), 'ok');
      setTimeout(function () { card.close(); el.hsProg.hidden = true; }, 3500);
      if (o.ok) o.ok();
      hs.flash = name;
      if (TP.afterApply) TP.afterApply();
      await load();
      return { ok: true };
    } catch (e) {
      if (e && (e.kind === 'auth' || e.kind === 'cancel')) { card.close(); el.hsProg.hidden = true; return { ok: false }; }
      card.fail(errText(e));                                         // 失败: 进度卡片里留着原因 (后端会撤销本次更改)
      load();
      return { ok: false };
    } finally { hs.busy = false; syncHs(); }
  }
  async function addHost(v) {
    var r;
    if (D && D.hosts.length >= HOST_MAX) return { ok: false, msg: t('dns.hs.err.max', { max: HOST_MAX }) };
    r = await hostsJob({ action: 'add', domain: v.domain, ip: v.ip }, { title: 'dns.hs.job.add', done: 'dns.hs.done.add', vars: { domain: v.domain }, flash: v.domain });
    if (r.ok) hs.add.reset();
    return r;
  }
  async function saveHost(v) {
    var e = hs.edit, form;
    if (!e) return { ok: false };
    form = { action: 'update', domain: e.orig, ip: v.ip };
    if (v.domain !== e.orig) form.new_domain = v.domain;
    return hostsJob(form, { title: 'dns.hs.job.update', done: 'dns.hs.done.update', vars: { domain: v.domain }, flash: v.domain, ok: function () { hs.edit = null; hs.focus = { domain: v.domain }; } });
  }
  async function delHost(x) {
    var ok = await ui.confirmDialog({
      title: t('dns.hs.del.title'), message: t('dns.hs.del.msg', { domain: x.domain, ip: x.ip }),
      detail: [t('dns.hs.del.d1', { domain: x.domain }), t('dns.hs.del.d2')], confirmText: t('dns.hs.del.go'), danger: true
    });
    if (!ok) return;
    var at = Array.prototype.findIndex.call(el.hsBody.children, function (tr) { return tr.getAttribute('data-d') === x.domain; });
    await hostsJob({ action: 'remove', domain: x.domain, ip: x.ip }, { title: 'dns.hs.job.remove', done: 'dns.hs.done.remove', vars: { domain: x.domain }, ok: function () { if (hs.edit && hs.edit.orig === x.domain) hs.edit = null; hs.focus = { index: at }; } });
  }
  async function clearHosts() {
    var n = D ? D.hosts.length : 0, ok;
    if (!n) { ui.toast(t('dns.hs.clear.none'), 'warn'); return; }
    ok = await ui.confirmDialog({
      title: t('dns.hs.clr.title'), message: t('dns.hs.clr.msg', { n: n }), detail: [t('dns.hs.clr.d1'), t('dns.hs.clr.d2')],
      confirmText: t('dns.hs.clr.go', { n: n }), danger: true
    });
    if (!ok) return;
    await hostsJob({}, { path: '/api/dns/hosts/reset', title: 'dns.hs.job.reset', done: 'dns.hs.done.reset', ok: function () { hs.edit = null; } });
  }
  function startEdit(x) {
    var cur = hs.edit;
    if (cur && cur.orig !== x.domain && cur.form && cur.form.dirty()) { ui.toast(t('dns.hs.finishEdit'), 'warn'); cur.form.d.focus(); return; }
    hs.edit = { orig: x.domain, origIp: x.ip, domain: x.domain, ip: x.ip, form: null };
    renderHosts();
    if (hs.edit && hs.edit.form) hs.edit.form.d.focus();
  }
  function stopEdit() { var d = hs.edit && hs.edit.orig; hs.edit = null; hs.focus = { domain: d }; renderHosts(); }

  /* 添加 / 行内按钮的可用状态: 忙碌 (上一项修改还在应用) / 辅助服务不可用 / 已到上限 */
  function syncHs() {
    var why = TP.why.helper() || (hs.busy ? t('dns.hs.busy') : ''), full = !!D && D.hosts.length >= HOST_MAX;
    hs.forms.forEach(function (f) {
      if (!document.contains(f.el) && f !== hs.add) return;
      ui.avail(f.ok, why || (f === hs.add && full ? t('dns.hs.err.max', { max: HOST_MAX }) : ''));
      if (f.cancel) ui.avail(f.cancel, hs.busy ? t('dns.hs.busy') : '');
    });
    hs.btns.forEach(function (b) { ui.avail(b, why); });
    if (el.hsClear) ui.avail(el.hsClear, why || (D && !D.hosts.length ? t('dns.hs.clear.none') : ''));
  }
  function byDomain(a, b) { return a.domain < b.domain ? -1 : a.domain > b.domain ? 1 : 0; }
  /* 「IP 地址」列排序用的键: IPv4 在前, 然后 IPv6, 每一段补零到固定宽度 (192.0.2.9 排在 192.0.2.10 前面, IPv6 的十六进制也按数值比较); 不是合法 IP 就用原文 */
  function ipKey(raw) {
    var p = parseIp(raw), w;
    if (!p) return str(raw);
    w = p.v === 4 ? 3 : 5;
    return p.v + ':' + p.key.split(p.v === 4 ? '.' : ':').map(function (g) { return ('00000' + (p.v === 4 ? +g : parseInt(g, 16))).slice(-w); }).join('.');
  }
  function viewRow(x) {
    var bT = ui.ibtn('search', t('dns.hs.test.aria', { domain: x.domain })), bE = ui.ibtn('edit', t('dns.hs.edit.aria', { domain: x.domain })), bD = ui.ibtn('delete', t('dns.hs.del.aria', { domain: x.domain }), { cls: 'danger-t' });
    ui.act(bT, function () { goTest(x.domain, true); });
    ui.act(bE, function () { startEdit(x); });
    ui.act(bD, function () { return delHost(x); });
    hs.btns.push(bE, bD);                                               // 「测试」只读, 不受忙碌状态影响
    return h('tr', { class: 'dns-hs-r' + (hs.flash === x.domain ? ' is-flash' : ''), 'data-d': x.domain },
      td('dns.hs.col.domain', 'c-name', h('b', { class: 'mono dns-hs-d' }, x.domain)),
      td('dns.hs.col.ip', 'c-ip', h('span', { class: 'mono dns-hs-ip' }, x.ip)),
      td('', 'c-act', h('div', { class: 'acts' }, bT, bE, bD)));
  }
  function editRow(x) {
    var e = hs.edit, f = hostForm({
      mode: 'edit', domain: e.domain, ip: e.ip, orig: x.domain, onSubmit: saveHost, onCancel: stopEdit,
      onInput: function (v) { e.domain = v.domain; e.ip = v.ip; }
    });
    f.dirty = function () { return e.domain.trim() !== e.orig || e.ip.trim() !== e.origIp; };
    e.form = f;
    return h('tr', { class: 'dns-hs-edit', 'data-d': x.domain }, h('td', { class: 'c-name', colspan: '3', 'data-l': '' }, f.el));
  }
  function renderHosts() {
    var all, list, q, r, rows, target, n;
    if (!D) return;
    all = D.hosts.slice().sort(byDomain);
    q = hs.filter.trim().toLowerCase();
    list = q ? all.filter(function (x) { return x.domain.indexOf(q) >= 0 || x.ip.toLowerCase().indexOf(q) >= 0; }) : all;
    list = hsSo.apply(list);                                             // 筛选 → 排序 (整张表, 不只是当前页) → 分页; 没有选排序时原样返回 (按域名)
    r = hs.pg.update(list.length);
    if (hs.flash) {                                                      // 刚添加 / 修改的那一条: 翻到它所在的那一页
      n = list.findIndex(function (x) { return x.domain === hs.flash; });
      target = n >= 0 ? Math.floor(n / r.size) + 1 : 0;
      if (target && target !== r.page) { hs.pg.setPage(target); return; }          // setPage 会再次调用本函数
    }
    hs.forms = hs.forms.filter(function (f) { return f === hs.add; });
    hs.btns = [];
    if (hs.edit && !hostEntry(hs.edit.orig)) hs.edit = null;             // 这一条已经不存在了 (别处改动 / 清空)
    if (hs.edit) hs.edit.form = null;
    rows = list.slice(r.start, r.end);
    TP.clear(el.hsBody);
    rows.forEach(function (x) { el.hsBody.appendChild(hs.edit && hs.edit.orig === x.domain ? editRow(x) : viewRow(x)); });
    el.hsTools.hidden = all.length <= 10;
    el.hsTbl.hidden = !rows.length;
    if (!all.length) el.hsEmpty.show({ icon: 'list-checks', text: t('dns.hs.empty'), hint: t('dns.hs.empty.hint') });
    else if (!list.length) el.hsEmpty.show({ icon: 'search', text: t('dns.hs.filter.none') });
    else el.hsEmpty.hide();
    TP.setCls(el.hsCount, 'chip dns-hs-n' + (all.length >= HOST_MAX ? ' bad' : all.length >= HOST_MAX * 0.9 ? ' warn' : ''));
    setText(el.hsCount, t('dns.hs.count', { n: all.length, max: HOST_MAX }));
    syncHs();
    if (hs.flash) {
      n = hs.flash; hs.flash = '';
      Array.prototype.forEach.call(el.hsBody.children, function (tr) {
        if (tr.getAttribute('data-d') === n && !reduceMotion()) { try { tr.scrollIntoView({ block: 'nearest' }); } catch (e) { /* 忽略 */ } }
      });
    }
    if (hs.focus) {                                                      // 行被重建 / 删除之后, 把焦点放回这一行的「修改」按钮 (没有这一行了就放到邻近的一行, 再没有就放到添加框)
      var fx = hs.focus, rowsEl = el.hsBody.children, hit = null, b, i;
      hs.focus = null;
      for (i = 0; i < rowsEl.length; i++) if (fx.domain && rowsEl[i].getAttribute('data-d') === fx.domain) hit = rowsEl[i];
      if (!hit && fx.index != null && rowsEl.length) hit = rowsEl[Math.max(0, Math.min(fx.index, rowsEl.length - 1))];
      b = hit && hit.querySelector('.acts .btn:nth-child(2)');
      if (b) b.focus(); else if (!coarse()) hs.add.d.focus();
    }
  }

  /* ================= 设置弹窗 ================= */
  var URL_RE = /^(udp|tls|https):\/\/(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9.-]+)(:[0-9]{1,5})?(\/[A-Za-z0-9._~\/%-]*)?$/;
  /* 与后端 dns_valid_url 同一条规则: system, 或 udp:// tls:// https:// + 主机 (域名 / IPv4 / [IPv6]) + 可选 :端口 + 可选路径, ≤ 200 个字符; 海外不能是 system */
  function checkUrl(scope, v) {
    var m, port;
    v = v.trim();
    if (!v) return t('dns.err.required');
    if (v.length > 200) return t('dns.err.long', { max: 200 });
    if (v === 'system') return scope === 'cn' ? '' : t('dns.err.systemGlobal');
    m = URL_RE.exec(v);
    if (!m) return t('dns.err.format');
    if (m[3]) { port = +m[3].slice(1); if (port < 1 || port > 65535) return t('dns.err.port'); }
    return '';
  }

  /* 选择 DNS 服务器的弹层 (手机上是底部弹层): 按协议分组的列表, 每项 = 名称 + 说明 + 延迟徽标; 点一项就选中并关闭。返回 Promise<id | null> */
  function openPicker(scope, cur) {
    var K = SCOPE[scope], seq = ++uid, items = [], lb, sug, bar, api, body;
    lb = h('div', { class: 'dns-lb', role: 'listbox', 'aria-label': L('dns.pk.listAria') });
    sug = h('div', { class: 'dns-sgs' });
    function entries() {
      var arr = D.presets[scope].slice();
      if (!arr.some(function (p) { return str(p.id) === cur; })) arr.push({ id: cur, name: cur, desc: '', url: '' });          // 当前值不在预设里也要能显示
      return arr;
    }
    function option(p) {
      var id = str(p.id), sel = id === cur, name = id === 'custom' ? srvName(scope, 'custom', '') : pTxt(p, 'name'), desc = pTxt(p, 'desc'), lat = benchBadge(scope, id);
      var o = h('div', { class: 'dns-pk-o', role: 'option', 'aria-selected': sel ? 'true' : 'false', tabindex: sel ? '0' : '-1', 'data-id': id },
        h('span', { class: 'dns-pk-ck', 'aria-hidden': 'true' }, sel ? ui.icon('check', 16) : null),
        h('span', { class: 'dns-pk-b' }, h('b', { class: 'dns-pk-n' }, name), desc ? h('span', { class: 'dns-pk-d' }, desc) : null),
        lat);
      if (sel) o.setAttribute('data-autofocus', '');
      return o;
    }
    function build() {
      var groups = {}, order, multi, fid = lb.contains(document.activeElement) ? document.activeElement.getAttribute('data-id') : null;
      entries().forEach(function (p) { var g = groupOf(p); (groups[g] = groups[g] || []).push(p); });
      order = GROUP_ORDER.filter(function (g) { return groups[g]; });
      multi = order.length > 1;
      TP.clear(lb); items = [];
      order.forEach(function (g) {
        var hid = 'dns-lbh' + seq + g, box = h('div', { class: 'dns-lb-g', role: 'group', 'aria-labelledby': multi ? hid : null });
        if (multi) box.appendChild(h('div', { class: 'dns-lb-h', id: hid }, t(GROUP_KEY[g])));
        groups[g].forEach(function (p) { var o = option(p); items.push(o); box.appendChild(o); });
        lb.appendChild(box);
      });
      TP.clear(sug);
      var n = suggestionNode(scope, cur, function (id) { api.close({ id: id }); }, false);
      if (n) sug.appendChild(n);
      if (fid != null) items.forEach(function (x) { if (x.getAttribute('data-id') === fid) x.focus(); });
    }
    lb.addEventListener('click', function (e) { var o = e.target.closest ? e.target.closest('.dns-pk-o') : null; if (o) api.close({ id: o.getAttribute('data-id') }); });
    lb.addEventListener('focusin', function (e) { items.forEach(function (x) { x.tabIndex = x === e.target ? 0 : -1; }); });
    lb.addEventListener('keydown', function (e) {
      var i = items.indexOf(document.activeElement), j = -1;
      if (i < 0) return;
      if (e.key === 'ArrowDown') j = Math.min(items.length - 1, i + 1);
      else if (e.key === 'ArrowUp') j = Math.max(0, i - 1);
      else if (e.key === 'Home') j = 0;
      else if (e.key === 'End') j = items.length - 1;
      else if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); api.close({ id: items[i].getAttribute('data-id') }); return; }
      if (j >= 0) { e.preventDefault(); items[j].focus(); }
    });
    bar = benchBar({ onSync: function () { if (api) build(); } });
    body = h('div', { class: 'dns-pk' }, h('p', { class: 'muted sm dns-pk-hint' }, L('dns.pk.hint')), bar.el, sug, lb);
    build();                                                          // 先建好列表, 弹窗打开时才能把焦点放在当前选中的那一项 (data-autofocus)
    api = ui.modal({
      title: t(K.pick), icon: 'list-checks', iconKind: 'pri', size: 'md', cls: 'dns-pkdlg', body: body,
      actions: [{ label: L('common.close'), cancel: true }],
      onClose: function () { bar.dispose(); }
    });
    return api.closed.then(function (v) { return v && v.id != null ? String(v.id) : null; });
  }

  /* pre = {scope, id}: 从页面里的测速建议点「采用」进来时, 先把这个预设选中 (仍要点保存才生效) */
  function openSettings(pre) {
    if (!D) { ui.toast(t('dns.notLoaded'), 'warn'); return null; }
    var base = Object.assign({}, D.settings), f = {}, api = null, saving = false;

    /* ---- 服务器选择 (一个按钮显示当前选择, 点开弹层) + 测速建议 + 自定义地址 ---- */
    function pickerField(scope) {
      var K = SCOPE[scope], c = { scope: scope, id: base[scope], touched: false }, lid = 'dns-fl-' + scope;
      c.name = h('b', { class: 'dns-pick-name' }); c.lat = h('span', { class: 'dns-pick-lat' }); c.desc = h('span', { class: 'dns-pick-desc' });
      c.btn = h('button', { class: 'dns-pick', type: 'button', 'aria-haspopup': 'dialog', 'aria-describedby': lid + 'h' },
        h('span', { class: 'dns-pick-main' }, h('span', { class: 'dns-pick-top' }, c.name, c.lat), c.desc), ui.icon('chevron-down', 18, 'dns-pick-chev'));
      c.sg = h('div', { class: 'dns-sgs' });
      c.url = h('input', { class: 'inp mono', type: 'text', id: 'dns-cu-' + scope, placeholder: L(K.ph), autocomplete: 'off', spellcheck: 'false', value: base[scope + '_custom'] });
      c.msg = h('div', { class: 'fld-h dns-m', 'aria-live': 'polite' });
      c.row = h('div', { class: 'dns-custom' },
        h('div', { class: 'dns-fld-h' }, h('label', { class: 'fld-l', for: 'dns-cu-' + scope }, L('dns.f.custom')), H('custom')), c.url, h('div', { class: 'fld-h' }, L(K.help)), c.msg);
      c.paint = function () {
        var p = presetOf(scope, c.id), nm = c.id === 'custom' ? srvName(scope, 'custom', c.url.value) : (p ? pTxt(p, 'name') : str(c.id)), d = p ? pTxt(p, 'desc') : '';
        setText(c.name, nm); setText(c.desc, d); c.desc.hidden = !d;
        ui.memo(c.lat, bn.at + '|' + c.id + '|' + String(benchOf(scope, c.id)), function () { return benchBadge(scope, c.id); });
        c.btn.setAttribute('aria-label', t('dns.pk.aria', { label: t(K.label), name: nm }));
        c.row.hidden = c.id !== 'custom';
        ui.memo(c.sg, bn.at + '|' + c.id + '|' + TP.why.auto(), function () { return suggestionNode(scope, c.id, function (id) { c.set(id); }, false); });
      };
      c.set = function (id) { c.id = id; sync(); if (id === 'custom') c.url.focus(); };
      c.btn.addEventListener('click', function () {
        openPicker(scope, c.id).then(function (id) { if (id != null && id !== c.id) c.set(id); });
      });
      c.url.addEventListener('input', function () { c.touched = true; sync(); });
      c.el = h('div', { class: 'dns-fld', role: 'group', 'aria-labelledby': lid },
        h('div', { class: 'dns-fld-h' }, h('span', { class: 'fld-l', id: lid }, L(K.label)), H(scope)),
        c.btn, h('div', { class: 'fld-h', id: lid + 'h' }, L(K.hint)), c.sg, c.row);
      return c;
    }
    f.cn = pickerField('cn'); f.global = pickerField('global');
    f.globalOff = h('div', { class: 'hint warn dns-warn', hidden: true }, ui.icon('warning', 16, 'ci'), h('span', null, L('dns.global.off')));
    f.bar = benchBar({ onSync: function () { if (f.cn && f.cn.paint) { f.cn.paint(); f.global.paint(); } } });

    /* ---- 海外解析走哪条线路 ---- */
    f.via = ui.seg(t('dns.f.via'), [
      { v: 'Global', label: L('name.policy.Global'), icon: 'auto' },
      { v: 'PIN', label: L('name.policy.PIN'), icon: 'pin' }
    ], function (v) { f.via.set(v); sync(); });
    f.via.set(base.via);
    f.viaDesc = h('div', { class: 'fld-h dns-m' });

    /* ---- IP 策略 ---- */
    f.strat = h('select', { class: 'sel', id: 'dns-strat', value: base.strategy }, (STRATS.indexOf(base.strategy) < 0 ? STRATS.concat([base.strategy]) : STRATS).map(function (v) { return TP.opt(v, strategyName(v)); }));
    f.strat.addEventListener('change', sync);
    f.stratDesc = h('div', { class: 'fld-h' });

    /* ---- 两个开关 ---- */
    function sw(key, topic, on) {
      var id = 'dns-sw' + (++uid), inp = h('input', { type: 'checkbox', role: 'switch', checked: !!on, 'aria-labelledby': id });
      inp.addEventListener('change', sync);
      return { inp: inp, title: h('div', { class: 'dns-sw-t' }, h('b', { id: id }, L(key)), H(topic)), el: h('label', { class: 'sw' }, inp, h('span', { class: 'sw-ui' })) };
    }
    f.leak = sw('dns.f.leak', 'leak', base.leak_guard); f.ads = sw('dns.f.ads', 'ads', base.ads_block);
    f.lgOn = h('div', { class: 'dns-on' }, L('dns.leak.on'));
    f.lgOff = h('div', { class: 'dns-off' }, L('dns.leak.off'));

    f.prog = h('div', { class: 'dns-prog', hidden: true });
    f.fields = h('div', { class: 'dns-fields' },
      h('div', { class: 'dns-bnbox' }, f.bar.el),
      f.cn.el,
      h('div', { class: 'dns-grp' }, f.globalOff, f.global.el,
        h('div', { class: 'dns-fld' }, h('div', { class: 'dns-fld-h' }, h('span', { class: 'fld-l' }, L('dns.f.via')), H('via')), f.via.el, f.viaDesc)),
      h('div', { class: 'dns-fld dns-sep' }, h('div', { class: 'dns-fld-h' }, h('label', { class: 'fld-l', for: 'dns-strat' }, L('dns.f.strategy')), H('strategy')), f.strat, f.stratDesc),
      h('div', { class: 'dns-sw' }, h('div', { class: 'dns-sw-b' }, f.leak.title, f.lgOn, f.lgOff), f.leak.el),
      h('div', { class: 'dns-sw' }, h('div', { class: 'dns-sw-b' }, f.ads.title, h('div', { class: 'fld-h' }, L('dns.ads.d'))), f.ads.el));
    var root = h('div', { class: 'dns-form' }, h('p', { class: 'muted sm dns-form-n' }, L('dns.modal.scope')), f.prog, f.fields);

    /* ---- 读取 / 校验 / 差异 ---- */
    function read() {
      return {
        cn: f.cn.id, cn_custom: f.cn.url.value.trim(), global: f.global.id, global_custom: f.global.url.value.trim(),
        via: f.via.cur() || base.via, strategy: f.strat.value, leak_guard: f.leak.inp.checked, ads_block: f.ads.inp.checked
      };
    }
    /* 选了「自定义」才校验地址; 返回要聚焦的输入框 (无问题则 null)。show=false 时, 用户还没碰过这个输入框就不显示错误 */
    function checkScope(sc, show) {
      var c = f[sc], m = c.id === 'custom' ? checkUrl(sc, c.url.value) : '', shown = !!m && (show || c.touched);
      TP.setCls(c.msg, 'fld-h dns-m' + (shown ? ' bad-t' : ''));
      setText(c.msg, shown ? m : '');
      c.url.setAttribute('aria-invalid', shown ? 'true' : 'false');
      return m ? c.url : null;
    }
    /* 只收集改动的字段; 「自定义」地址只在选了自定义时才有意义 */
    function changes() {
      var c = read(), form = {}, lines = [], n = 0;
      function line(key, from, to) { n++; lines.push(t('dns.chg.line', { item: t(key), from: from, to: to })); }
      ['cn', 'global'].forEach(function (sc) {
        var cu = sc + '_custom', urlChg = c[sc] === 'custom' && c[cu] !== base[cu];       // 地址只在选了「自定义」时才有意义
        if (c[sc] === base[sc] && !urlChg) return;
        if (c[sc] !== base[sc]) form[sc] = c[sc];
        if (urlChg) form[cu] = c[cu];
        line(SCOPE[sc].label, srvName(sc, base[sc], base[cu]), srvName(sc, c[sc], c[cu]));
      });
      if (c.via !== base.via) { form.via = c.via; line('dns.f.via', TP.name.policy(base.via), TP.name.policy(c.via)); }
      if (c.strategy !== base.strategy) { form.strategy = c.strategy; line('dns.f.strategy', strategyName(base.strategy), strategyName(c.strategy)); }
      if (c.leak_guard !== base.leak_guard) { form.leak_guard = c.leak_guard ? '1' : '0'; line('dns.f.leak', onOff(base.leak_guard), onOff(c.leak_guard)); }
      if (c.ads_block !== base.ads_block) { form.ads_block = c.ads_block ? '1' : '0'; line('dns.f.ads', onOff(base.ads_block), onOff(c.ads_block)); }
      return { form: form, lines: lines, n: n, cur: c };
    }

    /* ---- 随输入刷新: 说明文字 / 自定义行 / 线路可用性 / 保存按钮 ---- */
    function sync() {
      var c = read(), noPin = TP.why.pin(), sd = STRAT[c.strategy], sb = api && api.getBtn('save');
      ['cn', 'global'].forEach(function (sc) { f[sc].paint(); checkScope(sc, false); });
      f.globalOff.hidden = c.leak_guard;
      f.via.el.setAttribute('aria-label', t('dns.f.via'));
      f.via.avail('PIN', noPin, noPin ? addFix() : null);
      TP.setCls(f.viaDesc, 'fld-h dns-m' + (c.via === 'PIN' && noPin ? ' warn-t' : ''));
      setText(f.viaDesc, c.via === 'PIN' && noPin ? noPin : t(c.via === 'PIN' ? 'dns.via.pin.d' : 'dns.via.auto.d'));
      Array.prototype.forEach.call(f.strat.options, function (o) { var s = strategyName(o.value); if (o.textContent !== s) o.textContent = s; });
      setText(f.stratDesc, sd ? t(sd.desc) : ''); f.stratDesc.hidden = !sd;
      f.lgOn.classList.toggle('is-cur', c.leak_guard); f.lgOff.classList.toggle('is-cur', !c.leak_guard);
      if (sb && !saving) ui.avail(sb, changes().n ? '' : t('dns.noChanges'));
    }
    [f.cn.url, f.global.url].forEach(function (inp) {
      inp.addEventListener('keydown', function (e) { if (e.key === 'Enter' && !e.isComposing && e.keyCode !== 229) { e.preventDefault(); var b = api && api.getBtn('save'); if (b) b.click(); } });
    });

    /* ---- 保存: 校验 -> 确认 (旧 → 新) -> 提交 -> 在弹窗里跟踪任务 ---- */
    async function save() {
      var why = TP.why.helper();
      if (why) { ui.toast(why, 'warn'); return false; }
      var b1 = checkScope('cn', true), b2 = checkScope('global', true), bad = b1 || b2;
      if (bad) { bad.focus(); return false; }
      var ch = changes();
      if (!ch.n) { ui.toast(t('dns.noChanges'), 'warn'); return false; }
      var leakOff = base.leak_guard && !ch.cur.leak_guard, adsOn = !base.ads_block && ch.cur.ads_block, detail = ch.lines.slice();
      if (leakOff) detail.push(t('dns.cfm.leakOff'));
      if (adsOn) detail.push(t('dns.cfm.adsOn'));
      var ok = await ui.confirmDialog({ title: t('dns.cfm.title'), message: t('dns.cfm.msg', { n: ch.n }), detail: detail, confirmText: t('dns.cfm.go'), kind: leakOff || adsOn ? 'warning' : 'primary' });      // 琥珀 = 谨慎 (关防泄漏 / 开屏蔽广告)
      if (!ok) return false;
      return apply(ch.form);
    }
    async function apply(form) {
      var card = ui.taskCard(t('dns.apply.title'));
      TP.clear(f.prog); f.prog.appendChild(card.el); f.prog.hidden = false; f.fields.hidden = true;
      card.set({ pct: null, msg: t('dns.apply.sending') });
      saving = true; api.setBusy(true);
      try {
        var r = await TP.helper('POST', '/api/dns', { form: form, timeout: 20000 });
        if (r && r.job) await TP.jobs.follow(r.job, card);
        card.done(t('dns.apply.done'));
        ui.toast(t('dns.apply.done'), 'ok');
        if (TP.afterApply) TP.afterApply();
        await load();
        return true;
      } catch (e) {
        f.fields.hidden = false;                                    // 失败: 回到表单, 进度卡片里留着原因 (后端会撤销本次更改)
        if (e && e.kind === 'auth') { f.prog.hidden = true; return false; }
        card.fail(errText(e));
        return false;
      } finally { saving = false; api.setBusy(false); }
    }

    api = ui.modal({
      title: t('dns.modal.title'), icon: 'sliders-horizontal', iconKind: 'pri', size: 'md', body: root,
      dirty: function () { return changes().n > 0; },
      onClose: function () { modalSync = null; f.bar.dispose(); },
      actions: [
        { label: L('common.cancel'), cancel: true },
        { label: L('common.save'), kind: 'primary', icon: 'check', id: 'save', onClick: function () { return save(); } }
      ]
    });
    modalSync = function () { api.setTitle(t('dns.modal.title')); sync(); };
    if (pre && f[pre.scope] && pre.id != null) f[pre.scope].id = String(pre.id);
    sync();
    return api;
  }

  /* ================= 解析测试 ================= */
  /* 用户可能粘贴整个网址: 去掉协议、路径、账号、端口, 只留主机名; 与「网站」页同一套主机名规则, 但允许单段名称 (如 localhost) */
  function parseName(raw) {
    var s = str(raw).trim(), host;
    if (!s) return { err: t('dns.test.err.empty') };
    if (/\s/.test(s)) return { err: t('dns.test.err.format') };
    s = s.replace(/^[a-z][a-z0-9+.-]*:\/\//i, '').split(/[\/?#]/)[0].replace(/^[^@]*@/, '');
    if (s.charAt(0) === '[' || s.split(':').length > 2) return { err: t('dns.test.err.ip') };           // IPv6 地址
    s = s.replace(/:\d+$/, '').replace(/^\*\./, '').replace(/^\.+|\.+$/g, '');
    if (!s) return { err: t('dns.test.err.empty') };
    try { host = new URL('http://' + s).hostname.toLowerCase(); } catch (e) { return { err: t('dns.test.err.format') }; }
    if (/^\d{1,3}(\.\d{1,3}){3}$/.test(host) || host.indexOf(':') >= 0 || host.charAt(0) === '[') return { err: t('dns.test.err.ip') };
    if (host.length > 253 || !/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(host)) return { err: t('dns.test.err.format') };
    return { host: host };
  }
  /* 输入时的即时提示: 不合法 -> 红字; 粘贴了网址 -> 「将解析 xxx」。force=true (点了「解析」) 时空输入也报错 */
  function hintName(force) {
    var raw = el.inp.value.trim(), r = parseName(raw), msg = '', bad = false;
    if (!raw) { if (force) { msg = r.err; bad = true; } }
    else if (r.err) { msg = r.err; bad = true; }
    else if (r.host !== raw) msg = t('dns.test.will', { host: r.host });
    el.inp.setAttribute('aria-invalid', bad ? 'true' : 'false');
    TP.setCls(el.nameHint, 'fld-h dns-m' + (bad ? ' bad-t' : ''));
    setText(el.nameHint, msg);
    return r;
  }
  function renderGo() {
    ui.setBtn(el.go, t(testing ? 'dns.test.busy' : 'dns.test.go'), testing ? 'refresh' : 'search');
    ui.avail(el.go, testing ? t('dns.test.busyReason') : '');
    el.go.classList.toggle('is-busy', testing);
    if (testing) el.go.setAttribute('aria-busy', 'true'); else el.go.removeAttribute('aria-busy');
  }
  /* 这次答案是不是自定义解析给的: 后端明说了 (source / from / via = hosts | custom) 就信它; 否则看「所有答案都等于这个域名在自定义解析里的 IP」 */
  function fromHosts(j, name, answers) {
    var tag = str(j.source || j.from || j.via || j.by || j.resolver || j.origin).toLowerCase(), x, k;
    if (/^(hosts?|custom|custom[-_ ]?hosts?)$/.test(tag) || j.hosts === true || j.custom === true || j.from_hosts === true) return true;
    x = hostEntry(name); k = x ? parseIp(x.ip) : null;
    return !!(k && answers.length && answers.every(function (a) { var p = parseIp(a); return !!p && p.key === k.key; }));
  }
  /* 滚动到「测试解析」卡片并聚焦输入框; domain 非空时填进去, run 为真时直接解析 */
  function goTest(domain, run) {
    el.testCard.scrollIntoView({ block: 'start', behavior: reduceMotion() ? 'auto' : 'smooth' });
    if (domain) { el.inp.value = domain; hintName(false); }
    try { el.inp.focus({ preventScroll: true }); } catch (e) { el.inp.focus(); }
    if (run) el.go.click();
  }
  async function runTest() {
    var r = hintName(true), j, ms, res, answers;
    if (r.err) { el.inp.focus(); return; }
    el.inp.value = r.host; hintName(false);                          // 输入框里显示的就是实际发送的名称
    testing = true; lastRes = null; renderGo(); renderResult(); renderHist();
    try {
      j = await TP.helper('POST', '/api/dns/test', { form: { name: r.host }, timeout: 15000 });
      ms = j.ms == null || j.ms === '' ? NaN : +j.ms;
      answers = Array.isArray(j.answers) ? j.answers.map(String) : [];
      res = { name: r.host, ms: isFinite(ms) ? Math.max(0, Math.round(ms)) : null, answers: answers, hosts: fromHosts(j, r.host, answers) };
    } catch (e) {
      if (e && e.kind === 'auth') { testing = false; renderGo(); renderHist(); return; }
      res = { name: r.host, e: e };                                  // 保存错误本身: 切换语言后重新生成文字
      if (e && (e.kind === 'unreachable' || e.kind === 'http')) ui.toast(TP.errMsg(e), 'err');      // 辅助服务连不上: 原因 + 提示
    }
    hist = [r.host].concat(hist.filter(function (x) { return x !== r.host; })).slice(0, 5);
    testing = false; lastRes = res;
    renderGo(); renderResult(); renderHist();
  }
  function latCls(ms) { return ms <= 150 ? 'good' : ms <= 800 ? 'mid' : 'bad'; }
  function copy(txt) {
    var p = null;
    try { p = navigator.clipboard.writeText(txt); } catch (e) { p = null; }
    if (!p) { ui.toast(t('dns.test.copyFail'), 'warn'); return; }
    p.then(function () { ui.toast(t('dns.test.copied'), 'ok', 1800); }, function () { ui.toast(t('dns.test.copyFail'), 'warn'); });
  }
  function renderResult() {
    var r = lastRes, box = el.res, head, ul, b;
    TP.clear(box);
    if (!r) return;
    head = h('div', { class: 'dns-res-h' }, h('b', { class: 'mono' }, r.name));
    box.appendChild(head);
    if (r.e) {
      box.appendChild(h('div', { class: 'hint bad dns-warn' }, ui.icon('error', 16, 'ci'), h('span', null, h('b', null, t('dns.test.failed')), ' ', errText(r.e))));
      return;
    }
    if (r.ms != null) head.appendChild(h('span', { class: 'lat ' + latCls(r.ms) }, t('dns.test.ms', { n: fmt.num(r.ms) })));
    if (r.hosts) head.appendChild(ui.badge(t('dns.hs.fromHosts'), 'info', 'list-checks'));        // 答案来自「自定义解析」, 没有问任何 DNS 服务器
    if (!r.answers.length) box.appendChild(h('div', { class: 'hint warn dns-warn' }, ui.icon('warning', 16, 'ci'), h('span', null, t('dns.test.none'))));
    else {
      ul = h('ul', { class: 'dns-ans', 'aria-label': t('dns.test.answers', { name: r.name }) });
      r.answers.forEach(function (ip) {
        var cb = ui.ibtn('copy', t('dns.test.copy', { ip: ip }));
        ui.act(cb, function () { copy(ip); });
        ul.appendChild(h('li', null, h('span', { class: 'mono dns-ip' }, ip), cb));
      });
      box.appendChild(ul);
    }
    if (r.ms != null && r.ms > 800 && !r.hosts) {                      // 慢: 琥珀色提示 + 直达设置
      b = ui.btn(t('dns.change'), { sm: true });
      ui.act(b, function () { return openSettings(); });
      box.appendChild(h('div', { class: 'hint warn dns-warn' }, ui.icon('clock', 16, 'ci'), h('span', null, t('dns.test.slow', { n: fmt.num(r.ms) })), b));
    }
  }
  function renderHist() {
    TP.clear(el.hist);
    el.histBox.hidden = !hist.length;
    hist.forEach(function (name) {
      var lab = t('dns.test.again', { name: name }), b = h('button', { class: 'chip mono', type: 'button', title: lab, 'aria-label': lab }, name);
      b._tip = lab;
      ui.act(b, function () { el.inp.value = name; return runTest(); });
      if (testing) ui.avail(b, t('dns.test.busyReason'));
      el.hist.appendChild(b);
    });
  }
})();
