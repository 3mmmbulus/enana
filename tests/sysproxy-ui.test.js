/* 仪表盘「系统代理」: 总开关打开时一并开启 · 被其它软件占用时不擅自覆盖 · 一键开启 · 取消 / 失败不留下卡住的状态。
 * 直接加载真实的 ui/actions.js (不改任何设置, 不弹任何系统窗口)。 */
const assert = require('assert');
const fs = require('fs');
const vm = require('vm');
const path = require('path');

const same = (a, b) => assert.strictEqual(JSON.stringify(a), JSON.stringify(b));      // vm 里创建的对象和这里不是同一个 realm, 不能用 deepStrictEqual

function setup(over) {
  const log = { helper: [], dock: [], toasts: [], confirm: [], loadState: 0, emits: [] };
  const S = { state: { proxy: { enabled: false, mode: 'auto', network_mode: 'system' }, env: { sysproxy: false, service: true } } };
  const cfg = Object.assign({ proxyResponse: { ok: true, enabled: true, mode: 'auto' }, confirm: true, dockFail: false }, over);
  const TP = {
    S, on() {}, h: (...a) => a, setText() {}, why: { helper: () => '' }, safe: fn => fn,
    emit: (...a) => log.emits.push(a), syncBtns() {},
    loadState: async () => { log.loadState++; },
    ui: {
      confirmDialog: async o => { log.confirm.push(o); return cfg.confirm; },
      toast: (...a) => log.toasts.push(a), modal: () => ({ closed: Promise.resolve('cancel') })
    },
    jobs: {
      async runInDock(title, start) {
        log.dock.push(title);
        const res = await start();
        if (cfg.dockFail) return { ok: false, error: Error('cancelled') };
        return { ok: true, res };
      }
    },
    helper: async (method, p, opts) => {
      log.helper.push([method, p, opts && opts.form]);
      if (p === '/api/proxy') return cfg.proxyResponse;
      if (p === '/api/sysproxy') return { ok: true, job: 'sysproxy-job' };
      throw Error('unexpected ' + p);
    }
  };
  const I18N = { t: k => k, L: k => k };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../ui/actions.js'), 'utf8'),
    { window: { TP, I18N }, document: { contains: () => true }, console, setInterval() {}, setTimeout() { return 0; } });
  return { TP, S, log };
}

(async () => {
  /* 1. 什么时候算「系统代理需要修」 */
  let { TP, S } = setup();
  const needed = (proxy, env) => { S.state = { proxy, env }; return TP.actions.sysproxyNeeded(); };
  assert.strictEqual(needed({ enabled: true, network_mode: 'system' }, { sysproxy: false, service: true }), true);
  assert.strictEqual(needed({ enabled: false, network_mode: 'system' }, { sysproxy: false, service: true }), false, '总开关关闭时由「代理已关闭」提示条处理');
  assert.strictEqual(needed({ enabled: true, network_mode: 'tun' }, { sysproxy: false, service: true }), false, 'Enhanced/TUN 不使用系统代理');
  assert.strictEqual(needed({ enabled: true, network_mode: 'system' }, { sysproxy: true, service: true }), false);
  assert.strictEqual(needed({ enabled: true, network_mode: 'system' }, { sysproxy: false, service: false }), false, '核心没运行时先处理核心');
  S.state = null; assert.strictEqual(TP.actions.sysproxyNeeded(), false);

  /* 2. 总开关打开 → 后台任务开启系统代理, 用户不需要去终端 */
  let L;
  ({ TP, S, log: L } = setup({ proxyResponse: { ok: true, enabled: true, mode: 'auto', sysproxy: { state: 'pending', job: 'sysproxy-1' } } }));
  await TP.actions.setProxy(true);
  same(L.helper[0], ['POST', '/api/proxy', { on: 1 }]);
  assert.strictEqual(L.dock.length, 1, '系统代理的后台任务显示在 dock 里');
  assert.strictEqual(TP.actions.sysproxyBusy(), false, '任务结束后不再忙碌');
  assert.ok(L.loadState >= 1, '任务结束后刷新状态 (概览 / 提示条立刻更新)');
  assert.ok(L.confirm[0].detail.some(d => d === 'proxy.on.d3'), '系统代理未开启时, 确认框说明会一并开启以及可能弹出 macOS 密码窗口');

  /* 3. 系统代理已经指向 enana → 不再起任务; 确认框也不啰嗦 */
  ({ TP, S, log: L } = setup({ proxyResponse: { ok: true, enabled: true, mode: 'auto', sysproxy: { state: 'on' } } }));
  S.state.env.sysproxy = true; await TP.actions.setProxy(true);
  assert.strictEqual(L.dock.length, 0);
  assert.ok(!L.confirm[0].detail.some(d => d === 'proxy.on.d3'));

  /* 4. 别的软件在用系统代理: 不擅自覆盖, 给「让 enana 接管」按钮, 点了才会确认并开启 */
  ({ TP, S, log: L } = setup({ proxyResponse: { ok: true, enabled: true, mode: 'auto', sysproxy: { state: 'foreign' } } }));
  await TP.actions.setProxy(true);
  assert.strictEqual(L.dock.length, 0, '没有自动覆盖');
  const warn = L.toasts.find(t => t[0] === 'sysproxy.foreign');
  assert.ok(warn && warn[3] && warn[3].action && warn[3].action.label === 'sysproxy.takeover', '有接管按钮');
  await warn[3].action.fn();
  assert.strictEqual(L.confirm.length, 2, '接管前要再确认一次 (会替换其它代理设置)');
  same(L.helper[L.helper.length - 1], ['POST', '/api/sysproxy', { on: 1 }]);
  assert.strictEqual(L.dock.length, 1);

  /* 5. 一键开启: 取消确认不做任何事; 授权被取消 (任务失败) 不会让界面卡在忙碌状态 */
  ({ TP, S, log: L } = setup({ confirm: false }));
  await TP.actions.fixSysproxy(false);
  assert.strictEqual(L.helper.length, 0); assert.strictEqual(L.dock.length, 0);
  ({ TP, S, log: L } = setup({ dockFail: true }));
  await TP.actions.fixSysproxy(false);
  assert.strictEqual(L.dock.length, 1); assert.strictEqual(TP.actions.sysproxyBusy(), false, '失败后可以再点');
  await TP.actions.fixSysproxy(true);
  assert.strictEqual(L.dock.length, 2, '已经确认过 (比如从接管提示点进来) 就不再弹确认框'); assert.strictEqual(L.confirm.length, 1);

  /* 6. 关闭代理不会碰系统代理 (关闭时本地端口和系统代理设置不变, 不会断网) */
  ({ TP, S, log: L } = setup({ proxyResponse: { ok: true, enabled: false, mode: 'auto' } }));
  S.state.proxy.enabled = true; await TP.actions.setProxy(false);
  assert.strictEqual(L.dock.length, 0);
  assert.ok(!L.helper.some(h => h[1] === '/api/sysproxy'));

  console.log('PASS: system proxy follows the master switch, respects other proxies, one-click fix, cancellation recovers');
})().catch(e => { console.error(e); process.exitCode = 1; });
