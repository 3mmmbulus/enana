/* Test the actual onboarding actions without changing routes or asking for admin. */
const assert = require('assert');
const fs = require('fs');
const vm = require('vm');
const path = require('path');
let choice = 'cancel', jobs = 0, failure = false, ready = true;
const S = { state: { proxy: { network_mode: 'system', tun_ready: false } } };
const TP = { S, on() {}, why: { helper: () => '' }, h: (...args) => args, setText() {},
  ui: { modal: () => ({ closed: Promise.resolve(choice) }), confirmDialog: async () => true, toast() {} },
  jobs: { async runInDock(_, fn) { jobs++; if (failure) throw Error('authorization cancelled'); await fn(); } },
  helper: async (_, __, opts) => { assert.strictEqual(opts.form.mode, 'tun'); return { job: 'mode-job' }; },
  loadState: async () => { S.state.proxy = { network_mode: 'tun', tun_ready: ready }; }, loadSettings: async () => {}
};
const I18N = { t: k => k, L: k => k };
vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../ui/actions.js'), 'utf8'),
  { window: { TP, I18N }, document: {}, console, setInterval() {} });
(async () => {
  assert.strictEqual(await TP.actions.offerAppCapture('Gemini'), false); assert.strictEqual(jobs, 0);
  choice = 'system'; assert.strictEqual(await TP.actions.offerAppCapture('Gemini'), true); assert.strictEqual(jobs, 0);
  choice = 'tun'; failure = true;
  await assert.rejects(TP.actions.offerAppCapture('Gemini'), /authorization cancelled/);
  assert.strictEqual(S.state.proxy.network_mode, 'system');
  failure = false; ready = false;
  await assert.rejects(TP.actions.offerAppCapture('Gemini'), /set.network.notReady/);
  ready = true; assert.strictEqual(await TP.actions.offerAppCapture('Gemini'), true);
  assert.strictEqual(S.state.proxy.tun_ready, true);
  console.log('PASS: app capture choice, explicit limited mode, cancellation, readiness and retry');
})().catch(e => { console.error(e); process.exitCode = 1; });
