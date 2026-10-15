#!/usr/bin/env node
// 网站页的表格 + 应用页 / 网站页的整行点击 (2.3.26): 真实的 ui/core.js, ui/data.js, ui/ui.js, ui/exits.js, ui/v-apps.js, ui/v-sites.js, 假的浏览器 (tests/ui-dom.js),
// 辅助服务用替身 (只记录请求), 不需要浏览器、不碰网络。
// 1. 网站页「系统目录」是一张表: 列头 (网站 | 域名数 | 线路 | 出口 | 操作), 分类标题行, 每一项一行, 最后是「默认出口」; 每一格的内容 (三段开关、出口下拉只在固定出口有 2 个以上时出现)。
// 2. 分类筛选下拉 (含个数, 搜索时跟着变)、默认出口、搜索 (名称 / 域名)、筛选 + 搜索没有结果时的空状态、记在偏好里 (别的设备同步来的、已经不存在的分类)。
// 3. 我添加的 / 自动识别: 同样的表格 (网站 | 线路 | 出口 | 操作), 按出口筛选, 自动识别的标记和原因。
// 4. 整行点击 (TP.rowOpen): 点行里不是控件的地方 = 「查看域名」/「详情」; 点三段开关 / 下拉 / 按钮不会顺带打开; 按钮自己只打开一次;
//    回车 (焦点在行上) 打开, 焦点在行里的控件上 / 输入法选字 / 空格不打开; 选中文字时不打开; 「默认出口」和自定义网站没有详情, 不能点开。
// 5. 样式: 整行变色的颜色在浅色 / 深色主题里都有定义; 新应用的高亮不会盖住它; 网站表格在宽的时候是列, 窄的时候是卡片。
'use strict';
const assert = require('assert'), fs = require('fs'), path = require('path'), vm = require('vm');
const { makeBrowser, fakeI18n, settle } = require('./ui-dom.js');
const read = f => fs.readFileSync(path.join(__dirname, '..', f), 'utf8');

const b = makeBrowser();
b.win.I18N = fakeI18n({ has: k => k.indexOf('help.sites.g.ai.') === 0 });
['ui/core.js', 'ui/data.js', 'ui/ui.js', 'ui/exits.js'].forEach(f => b.load(f));
const TP = b.win.TP, S = TP.S, h = TP.h;
const prefs = new Map();
TP.prefs = { get: (k, d) => (prefs.has(k) ? prefs.get(k) : d), set: (k, v) => { if (v === undefined) prefs.delete(k); else prefs.set(k, v); TP.emit('prefs', { key: k }); } };
TP.proxyNote = () => h('div', { class: 'proxy-note', hidden: true });
TP.tunNote = () => ''; TP.tunDetail = x => x;
TP.go = id => { TP.tab = id; }; TP.goAdd = () => {}; TP.settingsTab = () => {}; TP.loadSettings = () => Promise.resolve(null);
const toasts = []; TP.ui.toast = (m, k) => { toasts.push([m, k]); };
const reqs = [];
TP.helper = (method, url, o) => {
  reqs.push(method + ' ' + url + (o && o.q ? ' ' + JSON.stringify(o.q) : ''));
  if (url === '/api/sites/domains') {
    const e = S.catalog.entries.filter(x => x.id === o.q.id)[0];
    return Promise.resolve({ id: e.id, name: e.name, modified: !!e.modified, domains: e.domains.map(d => ({ domain: d, source: 'system' })), removed: [], rulesets: e.rulesets || [], cidrs: 0, policy: '' });
  }
  if (url === '/api/stats/apps') return Promise.resolve({ apps: [] });
  return Promise.resolve({ ok: true });
};
b.load('ui/v-apps.js'); b.load('ui/v-sites.js');
assert.equal(typeof TP.rowOpen, 'function', 'TP.rowOpen is shared by the apps and sites tables');

S.locked = false; S.helperUp = true; S.clash = 'ok';
const nowSec = Math.floor(Date.now() / 1000);
S.state = {
  servers: [{ tag: 'n1', role: 'pin' }, { tag: 'n2', role: 'pin' }, { tag: 'a1', role: 'auto' }],
  overrides: [{ kind: 'site', value: 'example.com', state: 'pin', src: '', target: '' },
    { kind: 'site', value: 'blocked.test', state: 'auto', src: 'auto', why: 'timeout', fails: 3, at: nowSec - 30 },
    { kind: 'app', value: 'Telegram', state: 'pin' }],
  proxy: { network_mode: 'tun', tun_ready: true }
};
const SEL = ['PIN', 'Global', 'direct'];
S.proxies = { PIN: { now: 'n1', all: ['n1', 'n2'] }, AUTO: { now: 'a1', all: ['a1'] }, 'svc-claude': { now: 'PIN', all: SEL.concat(['PINAUTO', 'n1', 'n2']) },
  'svc-gpt': { now: 'Global', all: SEL }, 'svc-github': { now: 'direct', all: SEL }, Final: { now: 'Global', all: SEL } };
S.catalog = { groups: { ai: 'AI', dev: 'Dev' }, groups_en: {}, order: ['ai', 'dev'], failed: false, entries: [
  { id: 'claude', tag: 'svc-claude', name: 'Claude', group: 'ai', default: 'pin', desc: 'Claude desc', domains: ['claude.ai', 'anthropic.com'], rulesets: [], cidrs: 0 },
  { id: 'gpt', tag: 'svc-gpt', name: 'ChatGPT', group: 'ai', default: 'pin', desc: '', domains: ['openai.com'], rulesets: [], modified: true },
  { id: 'github', tag: 'svc-github', name: 'GitHub', group: 'dev', default: 'auto', desc: 'Code', domains: ['github.com'], rulesets: ['geosite-github'] }] };

const dialogs = () => b.doc.body.children.filter(x => x.tagName === 'dialog' && x.open);
async function closeDialogs() {
  for (const d of dialogs()) {
    const c = d.querySelector('[data-id="close"]') || d.querySelector('.dlg-a').children.filter(x => x.textContent === 'common.close')[0];
    assert(c, 'a close button'); c.click();
  }
  await settle();
  assert.equal(dialogs().length, 0, 'dialogs closed');
}
const domainReqs = () => reqs.filter(r => r.indexOf('GET /api/sites/domains') === 0);

(async () => {
  /* ================= 网站页 ================= */
  const root = h('section', { id: 'v-sites' }); b.doc.body.appendChild(root);
  TP.tab = 'sites'; TP.V.sites.init(root); TP.V.sites.show();
  const panes = root.querySelectorAll('.sx-pane'), boxes = root.querySelectorAll('.sx-box'), lists = root.querySelectorAll('.sx-list');
  const flt = root.querySelector('select.sx-flt'), q = root.querySelector('input[type=search]'), count = root.querySelector('.sx-tb').lastChild;
  const empty = root.querySelector('.sx-main').lastChild;
  assert.equal(panes.length, 2); assert.equal(lists.length, 2);
  const shape = list => list.children.map(x => (x.classList.contains('sx-gh') ? '# ' + x.querySelector('.sx-gh-t').textContent + ' (' + x.querySelector('.sx-gh-n').textContent + ')' : x.getAttribute('aria-label')));
  const rowOf = name => lists[0].children.filter(x => x.getAttribute('aria-label') === name)[0];
  const pick = (sel, v) => { sel.value = v; sel.dispatch('change'); };
  const search = v => { q.value = v; q.dispatch('input'); };
  const optTexts = () => flt.options.map(o => o.value + '=' + o.textContent);

  // 1. 表格
  assert.equal(panes[0].hidden, false); assert.equal(panes[1].hidden, true);
  assert.deepEqual(root.querySelector('.sx-colh-k').children.map(c => c.className + ':' + c.textContent),
    ['sx-h-name:sites.col.site', 'sx-h-n:sites.col.domains', 'sx-h-route:sites.col.route', 'sx-h-exit:sites.col.exit', 'sx-h-act:sites.col.act']);
  assert.deepEqual(shape(lists[0]), ['# AI (2)', 'Claude', 'ChatGPT', '# Dev (1)', 'GitHub', '# sites.nav.final (1)', 'sites.final.name']);
  assert.equal(lists[0].children[0].querySelectorAll('.help-i').length, 1, 'a category head keeps its help button');
  const claude = rowOf('Claude'), gpt = rowOf('ChatGPT'), github = rowOf('GitHub'), fin = rowOf('sites.final.name');
  const cells = r => r.children.map(c => c.className.replace(/ is-none$/, ''));
  for (const r of [claude, gpt, github, fin]) {
    assert.deepEqual(cells(r), ['sx-c sx-c-name', 'sx-c sx-c-n', 'sx-c sx-c-route', 'sx-c sx-c-exit', 'sx-c sx-c-act'], 'cells of ' + r.getAttribute('aria-label'));
    assert(r.classList.contains('sx-row') && r.classList.contains('row-hov'), 'hover background on every row');
    assert.equal(r.getAttribute('role'), 'group');
  }
  for (const r of [claude, gpt, github]) { assert(r.classList.contains('row-open')); assert.equal(r.getAttribute('tabindex'), '0', 'rows are focusable'); }
  assert(!fin.classList.contains('row-open') && fin.getAttribute('tabindex') === null, 'the default exit has no domains dialog');
  const segv = r => r.querySelectorAll('input').filter(i => i.checked).map(i => i.value);
  const tg = r => r.querySelector('select.sx-tg'), exitCell = r => r.querySelector('.sx-c-exit');
  assert.deepEqual([segv(claude), segv(gpt), segv(github), segv(fin)], [['PIN'], ['Global'], ['direct'], ['Global']]);
  assert.equal(claude.querySelector('.sx-c-n').textContent, 'sites.domainCount {"n":2}');
  assert.equal(tg(claude).hidden, false, 'fixed exit with 2 pins: the exit column has the picker');
  assert.deepEqual(tg(claude).options.map(o => o.value), ['PIN', 'PINAUTO', 'n1', 'n2']); assert.equal(tg(claude).value, 'PIN');
  assert(!exitCell(claude).classList.contains('is-none'));
  assert.equal(tg(gpt).hidden, true); assert(exitCell(gpt).classList.contains('is-none'), 'no picker: the cell shows the placeholder (table) / is hidden (cards)');
  assert.equal(gpt.querySelector('.badge.warn').hidden, false, 'Modified badge');
  assert.equal(github.querySelector('.badges').textContent, 'sites.ruleset {"name":"github"}');
  assert(fin.querySelector('.sx-c-n').classList.contains('is-none') && fin.querySelector('.sx-c-act').classList.contains('is-none'));
  assert.equal(fin.querySelector('.sx-view').hidden, true);
  assert.equal(claude.querySelector('.sx-view').getAttribute('aria-label'), 'sites.dm.openAria {"name":"Claude"}');

  // 2. 筛选 / 搜索
  assert.equal(flt.getAttribute('aria-label'), 'sites.groups');
  assert.deepEqual(optTexts(), ['=sites.filter.opt {"name":"sites.filter.all","n":3}', 'ai=sites.filter.opt {"name":"AI","n":2}', 'dev=sites.filter.opt {"name":"Dev","n":1}', '@final=sites.nav.final']);
  assert.equal(count.textContent, 'sites.count {"n":3}');
  pick(flt, 'dev');
  assert.deepEqual(shape(lists[0]), ['# Dev (1)', 'GitHub']); assert.equal(prefs.get('sites.nav.catalog'), 'dev', 'the filter is remembered');
  assert.equal(count.textContent, 'sites.countOf {"n":1,"total":3}');
  assert(!claude.parentNode, 'rows of other categories leave the table');
  pick(flt, '@final');
  assert.deepEqual(shape(lists[0]), ['# sites.nav.final (1)', 'sites.final.name']);
  pick(flt, '');
  assert.equal(prefs.has('sites.nav.catalog'), false);
  assert.deepEqual(shape(lists[0]), ['# AI (2)', 'Claude', 'ChatGPT', '# Dev (1)', 'GitHub', '# sites.nav.final (1)', 'sites.final.name']);
  search('claude');
  assert.deepEqual(shape(lists[0]), ['# AI (1)', 'Claude'], 'search by name');
  assert.deepEqual(optTexts().slice(0, 3), ['=sites.filter.opt {"name":"sites.filter.all","n":1}', 'ai=sites.filter.opt {"name":"AI","n":1}', 'dev=sites.filter.opt {"name":"Dev","n":0}'], 'the counts follow the search');
  assert.equal(count.textContent, 'sites.countOf {"n":1,"total":3}');
  pick(flt, 'dev');
  assert.deepEqual(shape(lists[0]), []); assert.equal(boxes[0].hidden, true);
  assert.equal(empty.hidden, false); assert.equal(empty.querySelector('.empty-t').textContent, 'sites.empty.noMatch', 'filter + search without a match');
  pick(flt, ''); search('openai.com');
  assert.deepEqual(shape(lists[0]), ['# AI (1)', 'ChatGPT'], 'search by domain');
  search('');
  assert.equal(boxes[0].hidden, false); assert.equal(empty.hidden, true);
  TP.prefs.set('sites.nav.catalog', 'dev');                                       // 别的设备同步来的
  assert.deepEqual(shape(lists[0]), ['# Dev (1)', 'GitHub']); assert.equal(flt.value, 'dev');
  TP.prefs.set('sites.nav.catalog', 'gone');                                      // 目录里已经没有这个分类了
  assert.deepEqual(shape(lists[0]), ['# AI (2)', 'Claude', 'ChatGPT', '# Dev (1)', 'GitHub', '# sites.nav.final (1)', 'sites.final.name']); assert.equal(flt.value, '');
  TP.prefs.set('sites.nav.catalog', undefined);

  // 4. 整行点击 = 「查看域名」
  const rClaude = rowOf('Claude'), rGithub = rowOf('GitHub'), rFin = rowOf('sites.final.name');
  rGithub.querySelector('.site-n').click(); await settle();
  assert.equal(dialogs().length, 1); assert(dialogs()[0].classList.contains('sdm-dlg'), 'the domains dialog');
  assert.deepEqual(domainReqs(), ['GET /api/sites/domains {"id":"github"}']);
  await closeDialogs();
  rGithub.querySelector('.sx-c-n').click(); await settle();
  assert.equal(dialogs().length, 1, 'a click anywhere else on the row opens it too'); await closeDialogs();
  const before = domainReqs().length;
  rGithub.querySelector('.sl').click(); rGithub.querySelector('.seg').click(); rGithub.querySelector('.seg').querySelector('input').click();
  rClaude.querySelector('select.sx-tg').click(); rClaude.querySelector('.sx-tg').dispatch('mousedown');
  await settle();
  assert.equal(dialogs().length, 0, 'the segmented control and the exit picker keep their own behaviour'); assert.equal(domainReqs().length, before);
  rClaude.querySelector('.sx-view').click(); await settle();
  assert.equal(dialogs().length, 1, 'the View domains button opens exactly one dialog'); assert.equal(domainReqs().length, before + 1);
  assert.equal(domainReqs().slice(-1)[0], 'GET /api/sites/domains {"id":"claude"}');
  await closeDialogs();
  rGithub.dispatch('keydown', { key: 'Enter' }); await settle();
  assert.equal(dialogs().length, 1, 'Enter on the focused row'); await closeDialogs();
  rGithub.dispatch('keydown', { key: ' ' }); rGithub.dispatch('keydown', { key: 'Enter', isComposing: true });
  rGithub.querySelector('.sx-view').dispatch('keydown', { key: 'Enter' }); rGithub.querySelector('.seg').querySelector('input').dispatch('keydown', { key: 'Enter' });
  await settle();
  assert.equal(dialogs().length, 0, 'Space, IME Enter and Enter on a control inside the row do not open it');
  b.win.selection = { isCollapsed: false, anchorNode: rGithub.querySelector('.site-n'), toString: () => 'GitHub' };
  rGithub.querySelector('.site-n').click(); await settle();
  assert.equal(dialogs().length, 0, 'releasing the mouse after selecting text in the row is not a click');
  b.win.selection = { isCollapsed: false, anchorNode: root.querySelector('.sx-legend'), toString: () => 'elsewhere' };
  rGithub.querySelector('.site-n').click(); await settle();
  assert.equal(dialogs().length, 1, 'a selection somewhere else does not block it'); await closeDialogs();
  b.win.selection = { isCollapsed: true, anchorNode: null, toString: () => '' };
  const n0 = domainReqs().length;
  rFin.querySelector('.site-n').click(); rFin.dispatch('keydown', { key: 'Enter' }); await settle();
  assert.equal(dialogs().length, 0); assert.equal(domainReqs().length, n0, 'the default exit row does not open anything');

  // 3. 我添加的 / 自动识别
  const tabBtn = id => root.querySelectorAll('[role=tab]').filter(x => new RegExp('-' + id + '$').test(x.id))[0];
  tabBtn('mine').click();
  assert.equal(prefs.get('sites.tab'), 'mine'); assert.equal(panes[0].hidden, true); assert.equal(panes[1].hidden, false);
  assert.deepEqual(root.querySelector('.sx-colh-c').children.map(c => c.textContent), ['sites.col.site', 'sites.col.route', 'sites.col.exit', 'sites.col.act']);
  assert.equal(root.querySelector('.sx-sub').textContent, 'sites.custom.title · sites.custom.sub');
  assert.deepEqual(lists[1].children.map(x => x.getAttribute('aria-label')), ['example.com']);
  const ex = lists[1].children[0];
  assert.deepEqual(cells(ex), ['sx-c sx-c-name', 'sx-c sx-c-route', 'sx-c sx-c-exit', 'sx-c sx-c-act']);
  assert(ex.classList.contains('sx-row-c') && ex.classList.contains('row-hov') && !ex.classList.contains('row-open') && ex.getAttribute('tabindex') === null, 'custom rows: hover only, no details dialog');
  assert.equal(ex.querySelector('select.sx-st').value, 'pin');
  assert.equal(tg(ex).hidden, false); assert(!exitCell(ex).classList.contains('is-none'));
  assert.equal(flt.getAttribute('aria-label'), 'sites.nav.titleRoute');
  assert.deepEqual(flt.options.map(o => o.value), ['', 'pin', 'auto', 'direct', 'follow']);
  assert.equal(flt.options[1].textContent, 'sites.filter.opt {"name":"name.policy.PIN","n":1}');
  ex.querySelector('.site-n').click(); ex.dispatch('keydown', { key: 'Enter' }); await settle();
  assert.equal(dialogs().length, 0);
  pick(flt, 'auto');
  assert.deepEqual(lists[1].children, []); assert.equal(boxes[1].hidden, true); assert.equal(prefs.get('sites.nav.mine'), 'auto');
  const cEmpty = panes[1].lastChild;
  assert.equal(cEmpty.hidden, false); assert.equal(cEmpty.querySelector('.empty-t').textContent, 'sites.empty.noMatch');
  pick(flt, '');
  assert.equal(boxes[1].hidden, false); assert.equal(lists[1].children.length, 1);
  tabBtn('auto').click();
  assert.deepEqual(lists[1].children.map(x => x.getAttribute('aria-label')), ['blocked.test']);
  const au = lists[1].children[0];
  assert.equal(au.querySelector('.badge.info').hidden, false, 'auto-detected badge');
  assert.equal(au.querySelector('.site-d').textContent, 'timeout ×3 · sites.auto.ago.now');
  assert(exitCell(au).classList.contains('is-none'));
  assert.equal(root.querySelector('.sx-autobar').hidden, false);
  assert.equal(root.querySelector('.sx-sub').textContent, 'sites.auto.title · sites.auto.sub');
  tabBtn('catalog').click();
  assert.equal(panes[0].hidden, false);
  assert.deepEqual(shape(lists[0]), ['# AI (2)', 'Claude', 'ChatGPT', '# Dev (1)', 'GitHub', '# sites.nav.final (1)', 'sites.final.name']);

  /* ================= 应用页 ================= */
  S.apps = { apps: [{ name: 'Safari', state: 'follow', group: 'Browsers', path: '/Applications/Safari.app', kind: 'app' },
    { name: 'Telegram', state: 'pin', group: 'Social', path: '/Applications/Telegram.app', kind: 'app', flag: 'new' }], new_count: 1 };
  const root2 = h('section', { id: 'v-apps' }); b.doc.body.appendChild(root2);
  TP.tab = 'apps'; TP.V.apps.init(root2); TP.V.apps.show(); await settle();
  const rows = root2.querySelectorAll('.apps-row');
  assert.deepEqual(rows.map(r => r.getAttribute('aria-label')), ['Telegram', 'Safari']);
  for (const r of rows) {
    assert(r.classList.contains('row-hov') && r.classList.contains('row-open'), 'hover + clickable');
    assert.equal(r.getAttribute('tabindex'), '0'); assert.equal(r.getAttribute('role'), 'group');
  }
  assert(rows[0].classList.contains('is-new'), 'a new app keeps its highlight');
  const infoOpen = () => dialogs().filter(d => d.querySelector('.dlg-t').textContent === 'apps.info.title');
  const safari = rows[1];
  safari.querySelector('.apps-n').click(); await settle();
  assert.equal(infoOpen().length, 1, 'a click on the row opens the details'); assert.equal(dialogs().length, 1);
  assert(infoOpen()[0].textContent.indexOf('/Applications/Safari.app') >= 0, 'details of the clicked app');
  await closeDialogs();
  safari.querySelector('.apps-ic').click(); safari.querySelector('.apps-p').click(); await settle();
  assert.equal(dialogs().length, 2, 'icon and path are part of the row'); await closeDialogs();
  safari.querySelector('select.apps-sel').click(); safari.querySelector('select.apps-sel').dispatch('keydown', { key: 'Enter' });
  rows[0].querySelector('select.apps-tg').click(); rows[0].querySelector('.help-i') && rows[0].querySelector('.help-i').dispatch('keydown', { key: 'Enter' });
  await settle();
  assert.equal(dialogs().length, 0, 'the route and exit menus keep their own behaviour');
  safari.querySelector('.apps-act').children[0].click(); await settle();
  assert.equal(infoOpen().length, 1, 'the Details button opens it once'); assert.equal(dialogs().length, 1); await closeDialogs();
  safari.dispatch('keydown', { key: 'Enter' }); await settle();
  assert.equal(infoOpen().length, 1, 'Enter on the focused row'); await closeDialogs();
  assert.deepEqual(toasts.filter(x => x[1] === 'err'), [], 'no errors');

  /* ================= 样式 ================= */
  const style = read('ui/style.css'), apps = read('ui/css/apps.css'), sites = read('ui/css/sites.css');
  assert(/:root\{[^}]*--row-hover:rgba\(/.test(style), 'light theme hover colour');
  assert(/@media \(prefers-color-scheme:dark\)\{\s*:root:not\(\[data-theme=light\]\)\{[^}]*--row-hover:rgba\(/.test(style), 'dark theme (system) hover colour');
  assert(/:root\[data-theme=dark\]\{[^}]*--row-hover:rgba\(/.test(style), 'dark theme (forced) hover colour');
  assert(style.indexOf('.row-hov:hover{background-image:linear-gradient(var(--row-hover),var(--row-hover))}') >= 0, 'the hover colour is layered over the row background');
  assert(style.indexOf('.row-open{cursor:pointer}') >= 0 && /\.row-open:focus-visible\{outline:2px solid var\(--pri\)/.test(style), 'clickable rows: pointer and keyboard focus ring');
  assert(/\.apps-row\.is-new\{background-color:var\(--pri-bg\)\}/.test(apps) && !/\.apps-row\.is-new\{background:/.test(apps), 'the new-app highlight does not reset the hover layer');
  assert(!/\.sx-row[^{]*\{[^}]*\bbackground:/.test(sites), 'site rows never reset the hover layer');
  assert(/@container \(min-width:900px\)\{[\s\S]*?\.sx-colh\{display:grid/.test(sites), 'wide: a real table with column headers');
  assert(sites.indexOf('grid-template-areas:"name n route exit act"') >= 0 && sites.indexOf('grid-template-areas:"name route exit act"') >= 0);
  assert(/\.sx-colh\{display:none\}/.test(sites) && /\.sx-row\{display:grid;grid-template-columns:minmax\(0,1fr\) auto;grid-template-areas:"name n" "route route" "exit exit" "act act"/.test(sites), 'narrow: cards');

  /* ================= 词典 ================= */
  const dict = f => { const d = {}; vm.runInNewContext(read(f), { window: { I18N: { register: (c, o) => Object.assign(d, o) } } }); return d; };
  const zh = dict('ui/i18n/zh.js'), en = dict('ui/i18n/en.js');
  const ph = v => (typeof v === 'string' ? [v] : Object.values(v)).join(' ').match(/\{\w+\}/g) || [];
  for (const f of ['ui/v-sites.js', 'ui/v-apps.js']) {
    const src = read(f).replace(/\/\*[\s\S]*?\*\//g, '');
    for (const m of src.matchAll(/\b(?:t|L)\('([a-z]\w*(?:\.[\w-]+)+)'/g)) assert(m[1] in zh && m[1] in en, f + ' uses ' + m[1] + ', missing in a dictionary');
  }
  for (const k of ['sites.filter.all', 'sites.filter.opt', 'sites.col.site', 'sites.col.domains', 'sites.col.route', 'sites.col.exit', 'sites.col.act'])
    assert.deepEqual([...new Set(ph(zh[k]))].sort(), [...new Set(ph(en[k]))].sort(), 'same placeholders: ' + k);
  const gone = ['sites.nav.aria', 'sites.nav.title', 'sites.group.count', 'sites.group.countOf', 'sites.final.title', 'sites.final.sub'];
  const ui = fs.readdirSync(path.join(__dirname, '..', 'ui')).filter(f => /\.js$/.test(f)).map(f => read('ui/' + f)).join('\n');
  for (const k of gone) { assert(!(k in zh) && !(k in en), 'removed: ' + k); assert(ui.indexOf("'" + k + "'") < 0, 'no code uses ' + k); }

  console.log('PASS: the sites page is one table (filter, search, custom tabs), and apps / sites rows highlight on hover and open their details on click or Enter without stealing clicks from their controls');
})().catch(e => { console.error(e); process.exitCode = 1; });
