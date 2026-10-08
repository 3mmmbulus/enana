// 「部署完成但验证没通过」的界面流程 (真实加载 ui/v-vps.js, 隔离的假 TP / ui / 辅助服务, 不碰浏览器、凭据或真实服务器):
//  1. 探测结果: 端口以云端探测给的「将要使用的端口」为准; 没有时不假设任何固定端口; 已有一次待验证的部署时, 不再显示「尚未部署」而是「已部署, 待验证」
//  2. 部署: 远端成功但本机验证失败 → 失败页是「部署已完成, 但还没通过验证」, 原因 / 端口都来自任务结果; 主操作是「重新验证」(只在本机), 「重新部署」要单独点
//  3. 「重新验证」只调用 /api/vps/verify (带待验证编号), 不再调用 /api/vps/provision; 成功后进入完成页并清掉凭据
//  4. 验证又失败: 仍在失败页, 原因更新; 远端脚本自己报告的失败 (没有待验证记录) 仍然是普通「重试」
//  5. 整个界面文字里不出现写死的 443
const assert = require('assert'), fs = require('fs'), vm = require('vm'), path = require('path');
const tick = () => new Promise(resolve => setImmediate(resolve));
class El {
  constructor(tag) { this.tag = tag; this.children = []; this.isConnected = true; this.handlers = {}; }
  appendChild(x) { this.children.push(x); return x; }
  addEventListener(type, fn) { (this.handlers[type] = this.handlers[type] || []).push(fn); }
  focus() {} closest() { return null; } getClientRects() { return [1]; } querySelector() { return null; } scrollIntoView() {}
  setAttribute() {} removeAttribute() {}
  get textContent() { return text(this); }
  set textContent(v) { this.children = [String(v)]; }
}
function text(n) { if (n == null) return ''; if (typeof n === 'string' || typeof n === 'number') return String(n); if (Array.isArray(n)) return n.map(text).join(' '); return [n.label, n.text, ...n.children.map(text)].filter(Boolean).join(' '); }
function walk(n, fn) { if (!n || typeof n === 'string') return; fn(n); (n.children || []).forEach(c => walk(c, fn)); }

const PROBE = (extra = {}) => Object.assign({
  host: 'fixture.invalid', port: 22, user: 'root', hostkey: 'SHA256:' + 'A'.repeat(43), hostkey_changed: false, os: { pretty: 'Debian 12' }, arch: 'amd64', supported: true, support: 'full',
  privilege: 'root', init: 'systemd', deps: [], missing: [], all_missing: false, singbox: { installed: true, version: '1.14.2' }, node: { installed: false }, deployed: false,
  firewall: 'ufw_inactive', listening: [22, 80, 443, 2019], ips: [{ local: '10.0.0.5', public: '203.0.113.9', v: 4 }], ipv6: [], actions: [], pending: null, plan: null }, extra);
const PENDING = { id: 'p-0a1b2c', name: 'My-VPS', host: 'fixture.invalid', ssh_port: 22, ports: [2053], ips: ['203.0.113.9'], nodes: 2, reason: 'blocked_cloud', tries: 1 };
const FAIL_RESULT = (reason, extra = {}) => Object.assign({ code: 'E_VPS_VERIFY', pending: 'p-0a1b2c', reason, port: 2053, ports: [2053], host: 'fixture.invalid', tcp: 'timeout',
  remote: { checked: true, listening: true, firewall: 'ufw_inactive' }, nodes: 2, failed: 2 }, extra);
const failure = (result, msg = 'deployment finished but verification failed') => Object.assign(new Error(msg), { data: { result, steps: [
  { label: 'connect', state: 'done' }, { label: 'verify', state: 'error' }] } });

function fixture(script) {
  let actions = [], busy = false, wipes = 0; const posts = [], dialogs = [], toasts = [];
  const h = (tag, attrs, ...kids) => { const el = new El(tag); Object.assign(el, attrs); kids.flat().filter(x => x != null).forEach(x => el.appendChild(x)); return el; };
  const rich = (k, v) => { const el = new El('rich'); el.appendChild(k + ' ' + JSON.stringify(Object.fromEntries(Object.entries(v || {}).map(([a, b]) => [a, b && b.children ? text(b) : b])))); return el; };
  const I = { t: (k, v) => k + (v ? ' ' + JSON.stringify(v) : ''), L: k => k, node: k => { const e = new El('n'); e.appendChild(k); return e; }, rich };
  const jobs = new Map(); let seq = 0;
  const TP = { S: {}, h, setText: (e, s) => { e.children = [s]; }, clear: e => { e.children = []; }, on() {}, why: { helper: () => '' }, errMsg: e => e.message, mkErr: (_, m) => new Error(m),
    name: { role: r => r }, hasRole: () => true, afterApply() {}, loadState: async () => {}, fmt: { rel: x => String(x) }, sync: null,
    helper: async (method, url, o) => { posts.push({ method, url, form: o && o.form }); const id = 'job-' + (++seq); jobs.set(id, script(url, o && o.form)); return { job: id }; },
    jobs: { follow: async (id, opts) => { const r = jobs.get(id); if (opts && opts.fromJob) opts.fromJob({ pct: 50, msg: 'x', steps: [] }); if (r.reject) throw r.reject; return { result: r.result }; } },
    ui: { help() {}, icon: n => { const e = new El('icon'); e.label = ''; return e; }, toast(m) { toasts.push(m); }, taskCard: () => ({ el: new El('card'), set() {}, done() {}, setTitle() {} }),
      chip: (label) => h('chip', null, label), btn: (label, o) => h('button', Object.assign({ label }, o)), ibtn: () => h('ibtn'), act: (el, fn) => { el._act = fn; },
      sorter: () => ({ apply: rows => rows, th: () => new El('th') }), confirmDialog: async (o) => { dialogs.push(o); return true; }, renderSteps() {}, detailsBtn: (a) => h('details', null, a), avail() {}, topHost: () => new El('top') } };
  let source = fs.readFileSync(path.join(__dirname, '../ui/v-vps.js'), 'utf8');
  const a = source.indexOf('  function credForm(o) {'), b = source.indexOf('  /* 同一个弹窗里的', a);
  assert(a >= 0 && b > a);
  source = source.slice(0, a) + `function credForm() { return window.formFixture; }\n` + source.slice(b);
  const formFixture = { el: new El('form'), check: () => ({ host: 'fixture.invalid', port: 22, user: 'root', mode: 'password', password: 'fixture', role: 'pin', name: 'My-VPS', save: 1 }),
    wipeSecrets: () => wipes++, snapshot: () => ({}), firstInput: () => null, apply() {}, refreshDefaults() {}, reset() {} };
  vm.runInNewContext(source, { window: { TP, I18N: I, formFixture }, setTimeout() {}, WeakMap, URL, console });
  const host = { setActions: x => { actions = x; }, setBusy: x => { busy = x; }, setTabsHidden() {}, close() {}, goServers() {} };
  const pane = TP.vps.pane('password', host); pane.start();
  const root = pane.el;
  return { pane, posts, dialogs, toasts, get actions() { return actions; }, get wipes() { return wipes; }, root,
    act: id => { const x = actions.find(y => y.id === id); assert(x, 'no action ' + id + ' in ' + actions.map(y => y.id)); return x.onClick(); },
    has: id => actions.some(y => y.id === id), label: id => (actions.find(y => y.id === id) || {}).label, all: () => text(root),
    tickFingerprint: () => { walk(root, n => { if (n.tag === 'input' && n.type === 'checkbox') { n.checked = true; (n.handlers.change || []).forEach(f => f()); } }); } };
}

(async () => {
  // ---------- 1+2. 探测 → 部署 (远端成功, 本机验证失败) ----------
  let f = fixture((url) => {
    if (url === '/api/vps/probe') return { result: PROBE({ node: { installed: true }, pending: PENDING }) };
    if (url === '/api/vps/provision') return { reject: failure(FAIL_RESULT('blocked_cloud')) };
    if (url === '/api/vps/verify') return { reject: failure(FAIL_RESULT('handshake', { tcp: 'ok' })) };
    throw new Error('unexpected ' + url);
  });
  await f.act('go'); await tick();
  let all = f.all();
  assert(all.includes('vps.pend.title') && all.includes('vps.node.pending'), 'a pending deployment is shown instead of "not deployed"');
  assert(!all.includes('vps.node.none'), 'the server is not shown as "not deployed" when a deployment is pending');
  assert(all.includes('vps.cloud.noteAuto') && !all.includes('"port":443'), 'without a planned port the cloud-firewall note assumes no port');
  f.tickFingerprint(); await f.act('go'); await tick();                       // 继续 → 确认 → 部署
  const plan = (f.dialogs.pop() || {}).detail || [];
  const planText = plan.join('\n');
  assert(planText.includes('vps.cf2.configAuto') && planText.includes('vps.cf2.cloudAuto') && planText.includes('vps.cf2.keep'), 'plan: no fixed port, existing services are protected: ' + planText);
  assert(!/\b443\b/.test(planText), 'plan must not mention a fixed port');
  assert.equal(f.posts.filter(p => p.url === '/api/vps/provision').length, 1);
  all = f.all();
  assert(all.includes('vps.err.pendTitle') && !all.includes('vps.err.provTitle'), 'finished-but-unverified is its own state');
  assert(all.includes('vps.vf.r.blocked_cloud.msg {"port":"2053"}'), 'the reason uses the actual port: ' + all.slice(0, 400));
  assert(all.includes('vps.vf.tcp.timeout {"port":"2053"}') && all.includes('vps.vf.listen {"port":"2053"}') && all.includes('vps.vf.fw.ufwOff') && all.includes('vps.vf.cloud'), 'status lines');
  assert(all.includes('"ufw":"ufw allow 2053/tcp"') || all.includes('vps.vf.r.blocked_cloud.steps {"port":"2053"'), 'steps carry the actual port');
  assert(!all.includes('vps.err.partial'), 'the generic "may be partially applied" note is replaced by precise status');
  assert(!/\b443\b/.test(all), 'no hard-coded 443 anywhere on the failure page');
  assert.deepEqual(f.actions.map(x => x.id), ['back', 'redeploy', 'retry'], 'verify is primary, redeploy is a separate explicit choice');
  assert.equal(f.label('retry'), 'vps.vf.go'); assert.equal(f.label('redeploy'), 'vps.vf.redeploy');

  // ---------- 3/4. 重新验证: 只调用 verify; 再失败仍在失败页并更新原因 ----------
  const provisions = f.posts.filter(p => p.url === '/api/vps/provision').length;
  await f.act('retry'); await tick();
  const vposts = f.posts.filter(p => p.url === '/api/vps/verify');
  assert.equal(vposts.length, 1); assert.equal(vposts[0].form.id, 'p-0a1b2c'); assert.deepEqual(Object.keys(vposts[0].form), ['id'], 'no credentials are sent for a local verification');
  assert.equal(f.posts.filter(p => p.url === '/api/vps/provision').length, provisions, 'verify must never redeploy');
  all = f.all();
  assert(all.includes('vps.vf.r.handshake.msg') && all.includes('vps.vf.tcp.ok'), 'the reason is updated from the new result (port reachable → not a firewall problem)');
  assert(f.has('retry') && f.has('back'), 'still recoverable');

  // ---------- 3. 验证通过 → 完成, 凭据清除 ----------
  const wipesBefore = f.wipes;
  f = Object.assign(f, {});
  const g = fixture((url) => {
    if (url === '/api/vps/probe') return { result: PROBE({ pending: PENDING }) };
    if (url === '/api/vps/verify') return { result: { nodes: [{ tag: 'My-VPS-203.0.113.9', server: '203.0.113.9', port: 2053, type: 'vless', egress: '203.0.113.9', verified: true }, { tag: 'My-VPS-203.0.113.10', server: '203.0.113.10', port: 2053, type: 'vless', egress: '', verified: false }], ips: ['203.0.113.9'], vps: 'v-aaaaaa' } };
    throw new Error('unexpected ' + url);
  });
  await g.act('go'); await tick();
  // 探测结果页上的「重新验证」按钮 (不经过部署)
  let pendBtn = null; walk(g.root, n => { if (n.tag === 'button' && n.label === 'vps.pend.verify') pendBtn = n; });
  assert(pendBtn && pendBtn._act, 'result page offers verify-without-redeploy'); await pendBtn._act(); await tick();
  assert.equal(g.posts.filter(p => p.url === '/api/vps/verify').length, 1); assert(!g.posts.some(p => p.url === '/api/vps/provision'));
  all = g.all();
  assert(all.includes('vps.done.title'), 'done page after a successful verification');
  assert(all.includes('vps.done.unverified'), 'a node that did not verify is flagged, not silently shown as fine');
  assert(g.has('again') && g.has('close'), 'done footer'); assert(g.wipes >= 2, 'credentials cleared after success');

  // ---------- 4. 远端脚本自己报告的失败 (没有待验证记录): 普通「重试」, 提示不假设防火墙 ----------
  const k = fixture((url) => {
    if (url === '/api/vps/probe') return { result: PROBE() };
    if (url === '/api/vps/provision') return { reject: failure({ code: 'E_VPS_VERIFY' }, 'The service failed to start') };
    throw new Error('unexpected ' + url);
  });
  await k.act('go'); await tick(); k.tickFingerprint(); await k.act('go'); await tick();
  all = k.all();
  assert(all.includes('The service failed to start') && all.includes('vps.hint.verifyRemote'), 'remote failures show the remote message, not a firewall guess');
  assert(!all.includes('vps.vf.'), 'no firewall guidance without evidence'); assert(k.label('retry') === 'common.retry' && !k.has('redeploy'));
  console.log('PASS: finished-but-unverified state, actual-port guidance, verify-only retry (no redeploy, no credentials), remote failures stay generic');
})().catch(e => { console.error(e); process.exitCode = 1; });
