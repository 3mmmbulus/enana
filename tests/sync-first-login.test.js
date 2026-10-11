#!/usr/bin/env node
// 第一次登录「是否同步到这台电脑」(ui/v-sync.js): 只有 GET /api/sync 的 ask=true 才问一次; 「不同步」不发任何请求;
// 「同步」= 开启同步 (不自动上传) + 合并拉取, 失败就把刚开的同步关回去。摘要来自 POST /api/sync/preview。
const assert = require('assert'), fs = require('fs'), path = require('path'), vm = require('vm');

function fixture(o) {
  const calls = [], cards = [], toasts = [], dialogs = [];
  const S = { locked: false, state: { servers: o.servers || [] } };
  const state = {
    ok: true, enabled: false, auto: false, decided: false, ask: !!o.ask, online: o.online !== false, account: 'name@example.com',
    remote: o.exists === false ? { exists: false } : { exists: true, version: 3, updated: 1000, size: 10, device: 'MacBook' },
    local: { version: 0, dirty: false }, last_pull: 0, last_push: 0
  };
  Object.assign(state, o.state || {});
  const summary = o.summary || { servers: 2, subs: 1, custom_rulesets: 0, prefs: true };
  const window = { I18N: { t: (k, p) => (p ? k + JSON.stringify(p) : k), L: k => k, has: () => false } };
  const TP = {
    S, h: () => null, setText() {}, fmt: { rel: v => 'rel' + v, num: v => String(v), dateTime: v => String(v), bytes: v => String(v) },
    on() {}, poll() {}, why: { helper: () => null }, safe: f => f, afterApply() {}, loadState() {}, loadSettings() {},
    ui: {
      confirmDialog: async opts => { dialogs.push(opts); return o.answer === true; },
      taskCard: title => {
        const card = { title, log: [], set(x) { this.log.push(['set', x && x.msg]); }, done(m) { this.log.push(['done', m]); }, fail(m) { this.log.push(['fail', m]); }, close() { this.log.push(['close']); } };
        cards.push(card); return card;
      },
      dock() {}, toast: (title, kind) => { toasts.push({ title, kind }); }, modal() { throw Error('not used'); }
    },
    jobs: { follow: async () => ({ state: 'done' }) },
    helper: async (method, url, options) => {
      const form = options && options.form;
      calls.push({ method, url, form });
      if (method === 'GET' && url === '/api/sync') return state;
      if (method === 'POST' && url === '/api/sync/preview') {
        if (o.previewFails) throw Object.assign(Error('no key'), { code: 'E_SYNC_KEY' });
        return { ok: true, summary, remote: { version: 3 } };
      }
      if (method === 'POST' && url === '/api/sync/settings') return { ok: true };
      if (method === 'POST' && url === '/api/sync/pull') {
        if (o.pullFails) throw Object.assign(Error('network'), { code: 'E_ACCOUNT_UNREACHABLE' });
        return { ok: true, job: 'job-1' };
      }
      throw Error('Unexpected request: ' + method + ' ' + url);
    }
  };
  const context = vm.createContext({ window, document: { contains: () => false }, console, setTimeout: () => 0, clearTimeout() {} });
  window.TP = TP; context.window = window;
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../ui/v-sync.js'), 'utf8'), context);
  return { SY: TP.sync, calls, cards, toasts, dialogs, S };
}

// 对象来自 vm 沙箱, 用 JSON 转成本 realm 的普通对象再比较
const plain = x => JSON.parse(JSON.stringify(x));
const settingsCalls = f => plain(f.calls.filter(c => c.url === '/api/sync/settings').map(c => c.form));
const pulls = f => f.calls.filter(c => c.url === '/api/sync/pull').map(c => ({ form: plain(c.form) }));

(async () => {
  // 1. 判断: 只在 ask=true、在线、云端有数据、还没做过选择时才问
  const probe = fixture({});
  assert.strictEqual(probe.SY.shouldAskFirst({ online: true, remote: { exists: true }, ask: true, decided: false }), true);
  assert.strictEqual(probe.SY.shouldAskFirst({ online: false, remote: { exists: true }, ask: true, decided: false }), false);
  assert.strictEqual(probe.SY.shouldAskFirst({ online: true, remote: { exists: false }, ask: true, decided: false }), false);
  assert.strictEqual(probe.SY.shouldAskFirst({ online: true, remote: { exists: true }, ask: false, decided: false }), false);
  assert.strictEqual(probe.SY.shouldAskFirst({ online: true, remote: { exists: true }, ask: true, decided: true }), false);
  assert.strictEqual(probe.SY.shouldAskFirst(null), false);

  // 2. 没有 ask (已经处理过 / 不是第一次登录): 只读状态, 不问, 不发别的请求
  let f = fixture({ ask: false });
  await f.SY.offerAfterLogin();
  assert.deepStrictEqual(f.calls.map(c => c.url), ['/api/sync']);
  assert.strictEqual(f.dialogs.length, 0);

  // 3. 第一次登录, 云端有数据: 先读摘要 (preview) 再问; 「不同步」不发任何请求 (设备保持原样)
  f = fixture({ ask: true, answer: false });
  await f.SY.offerAfterLogin();
  assert.deepStrictEqual(f.calls.map(c => c.url), ['/api/sync', '/api/sync/preview']);
  assert.strictEqual(f.dialogs.length, 1);
  assert.strictEqual(f.dialogs[0].confirmText, 'sync.offer.go');
  assert.strictEqual(f.dialogs[0].cancelText, 'sync.offer.no');
  const det3 = f.dialogs[0].detail.join('\n');
  assert(det3.includes('sync.first.n.servers{"n":"2"}') && det3.includes('sync.first.n.subs{"n":"1"}') && det3.includes('sync.first.prefs'), det3);
  assert(!det3.includes('sync.first.n.rules'), 'zero counts are left out');
  assert.strictEqual(f.toasts.length, 0);

  // 4. 「同步」: 和手动同步一样 = 开启同步 (不自动上传) + 合并拉取 (同一个 pull 任务); 完成后提示
  f = fixture({ ask: true, answer: true });
  await f.SY.offerAfterLogin();
  assert.deepStrictEqual(f.calls.slice(0, 4).map(c => c.url), ['/api/sync', '/api/sync/preview', '/api/sync/settings', '/api/sync/pull']);
  assert(f.calls.slice(4).every(c => c.url === '/api/sync'), 'after the pull only the state is re-read');
  assert.deepStrictEqual(settingsCalls(f), [{ enabled: 1, auto: 0 }]);
  assert.deepStrictEqual(pulls(f)[0].form, { mode: 'merge' });
  assert(f.cards[0].log.some(x => x[0] === 'done'), 'progress card reports success');
  assert.deepStrictEqual(f.toasts.map(x => x.kind), ['ok']);

  // 5. 「同步」但拉取失败: 把刚开的同步关回去 (自动同步一起关), 给出提示, 不留下半开的状态
  f = fixture({ ask: true, answer: true, pullFails: true });
  await f.SY.offerAfterLogin();
  assert.deepStrictEqual(settingsCalls(f), [{ enabled: 1, auto: 0 }, { enabled: 0, auto: 0 }]);
  assert(f.cards[0].log.some(x => x[0] === 'fail'), 'failure is shown on the progress card');
  assert.deepStrictEqual(f.toasts.map(x => x.kind), ['warn']);

  // 6. 读不了摘要 (旧密码 / 连不上): 这次不问, 也不做任何写操作
  f = fixture({ ask: true, answer: true, previewFails: true });
  await f.SY.offerAfterLogin();
  assert.strictEqual(f.dialogs.length, 0);
  assert.deepStrictEqual(f.calls.map(c => c.url), ['/api/sync', '/api/sync/preview']);

  // 7. 这台电脑已经有服务器: 说明里要提醒它们也会开始同步 (官方线路不算)
  f = fixture({ ask: true, answer: false, servers: [{ tag: 'mine' }, { tag: 'off', official: true }] });
  await f.SY.offerAfterLogin();
  assert(f.dialogs[0].detail.join('\n').includes('sync.first.localNote{"n":"1"}'), 'local servers are disclosed');

  console.log('PASS: first-login sync question only when asked; cancel makes no request; confirm runs enable + merge pull; failure reverts; summary from preview');
})().catch(error => { console.error(error); process.exitCode = 1; });
