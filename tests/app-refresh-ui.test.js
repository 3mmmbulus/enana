#!/usr/bin/env node
// Exercise the actual poller, visibility handler, job follower and data loaders.
const assert = require('assert'), fs = require('fs'), path = require('path'), vm = require('vm');
const storage = new Map(), clock = { now: 1000000 };
const tick = () => new Promise(resolve => setImmediate(resolve));
function deferred() { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; }
function fixture() {
  const calls = [], cards = [], toasts = [], warnings = [], events = {}, timers = new Map();
  let timer = 0, gate = null, fail = false, noJob = false, pending = null;
  const probes = [];
  const area = { getItem: key => storage.has(key) ? storage.get(key) : null,
    setItem: (key, value) => storage.set(key, value), removeItem: key => storage.delete(key) };
  const document = { hidden: false, addEventListener: (name, fn) => { events[name] = fn; } };
  const window = { localStorage: area, sessionStorage: area, I18N: { t: key => key, isL: () => false } };
  const context = vm.createContext({ window, document, console: { warn: (...s) => warnings.push(s), error: console.error },
    Date: class extends Date { static now() { return clock.now; } },
    setTimeout: (fn, ms) => { timers.set(++timer, { fn, ms }); return timer; }, clearTimeout: id => timers.delete(id) });
  for (const file of ['core.js', 'data.js']) vm.runInContext(fs.readFileSync(path.join(__dirname, '../ui', file), 'utf8'), context);
  const TP = window.TP; TP.S.locked = false; TP.S.helperUp = true;
  TP.helper = async (method, url, options) => {
    calls.push({ method, url, options });
    if (method === 'POST' && url === '/api/apps/scan') return noJob ? { ok: true, apps: [{ name: 'Gemini', state: 'direct' }], new_count: 0, pending } : { job: 'apps-scan-fixture' };
    if (method === 'POST' && url === '/api/override') return { job: 'override-fixture' };
    if (url === '/api/job') {
      if (gate) await gate.promise;
      return { state: fail ? 'error' : 'done', msg: fail ? 'scan failed' : 'unchanged; not restarted', pct: 100 };
    }
    if (method === 'GET' && url === '/api/apps') return { apps: [{ name: 'Gemini', state: 'pin' }], new_count: 0 };
    throw Error('Unexpected request: ' + method + ' ' + url);
  };
  TP.ui.taskCard = title => {
    const card = { title, set() {}, fromJob() {}, done(msg) { this.success = msg; }, fail(msg) { this.error = msg; }, close() {} };
    cards.push(card); return card;
  };
  TP.ui.dock = () => {}; TP.ui.toast = (title, kind) => toasts.push({ title, kind });
  TP.clash = async (method, path) => { probes.push(path); return {}; };      // 宽限期结束时的核心探测 (不走真的网络)
  const postScans = () => calls.filter(c => c.method === 'POST' && c.url === '/api/apps/scan').length;
  const graceTimers = () => [...timers.values()].filter(t => t.ms === 3000).length;
  const runGrace = () => { for (const [id, t] of [...timers]) if (t.ms === 3000) { timers.delete(id); t.fn(); } };
  return { TP, calls, cards, toasts, warnings, events, document, postScans, graceTimers, runGrace, probes,
    gate: value => { gate = value; }, fail: value => { fail = value; }, noJob: value => { noJob = value; }, pending: value => { pending = value; } };
}
(async () => {
  let f = fixture();
  const wait = deferred(); f.gate(wait);
  const a = f.TP.scanAppsBackground(), b = f.TP.loadApps(true);
  assert.strictEqual(a, b); await tick();
  assert.strictEqual(f.postScans(), 1); assert.strictEqual(f.TP.S.scanning, true);
  assert.strictEqual(f.cards.length, 0); assert.strictEqual(f.toasts.length, 0);
  wait.resolve(); await a; await tick();
  assert.strictEqual(f.TP.S.scanning, false); assert.strictEqual(f.TP.S.apps.apps[0].state, 'pin');
  assert.strictEqual(f.cards.length, 0); assert.strictEqual(f.toasts.length, 0);

  // Actual visibility kicks refresh cached data inside the one-minute cadence.
  clock.now += 4000;
  f.TP.pollers.apps = f.TP.poll(f.TP.scanAppsBackground, 60000);
  f.events.visibilitychange(); await tick();
  f.events.visibilitychange(); await tick();
  assert.strictEqual(f.postScans(), 1); assert.strictEqual(f.cards.length, 0);
  assert(f.calls.some(c => c.method === 'GET' && c.url === '/api/apps'));
  f.document.hidden = true; f.events.visibilitychange(); await tick(); assert.strictEqual(f.postScans(), 1);

  // A fresh page realm shares storage and must not start another scan on reload.
  f = fixture(); await f.TP.scanAppsBackground(); assert.strictEqual(f.postScans(), 0);
  clock.now += 60000;
  await f.TP.scanAppsBackground(); assert.strictEqual(f.postScans(), 1);
  assert.strictEqual(f.cards.length, 0); assert.strictEqual(f.toasts.length, 0);

  // Manual scans bypass the cadence and use their own progress title.
  const r = await f.TP.loadApps(true); assert(r); assert.strictEqual(f.postScans(), 2);
  assert.strictEqual(f.cards.length, 1); assert.strictEqual(f.cards[0].title, 'apps.scanJob');
  assert.strictEqual(f.toasts.length, 1); assert.strictEqual(f.toasts[0].kind, 'ok');
  await f.TP.override('app', 'Gemini', 'pin');
  assert.strictEqual(f.cards[1].title, 'job.override');
  assert(!f.calls.some(c => c.url === '/api/network-mode'));

  f.fail(true); const bad = await f.TP.loadApps(true);
  assert.strictEqual(bad, null); assert.strictEqual(f.TP.S.scanning, false);
  assert(f.cards[2].error); assert(!f.cards[2].success);
  f.fail(false); assert(await f.TP.loadApps(true)); // failure does not leave the scanner locked

  const quiet = fixture(); clock.now += 60000; quiet.fail(true);
  assert.strictEqual(await quiet.TP.scanAppsBackground(), null);
  assert.strictEqual(quiet.cards.length, 0); assert.strictEqual(quiet.toasts.length, 0);
  assert.strictEqual(quiet.TP.S.scanning, false); assert.strictEqual(quiet.warnings.length, 1);
  quiet.TP.S.helperUp = false; assert.strictEqual(quiet.TP.scanAppsBackground(), null);
  assert(!quiet.calls.some(c => c.url === '/api/network-mode'));
  // Top bar: a background scan with nothing to apply starts no job and never reports applying. A change that needs administrator approval
  // (untrusted helper) becomes a pending card and starts no job. A background job that really applies shows the label; manual jobs keep their dock and
  // re-arm one grace timer; a core still reporting "applying" after the grace window is probed once; a failed job leaves nothing applying.
  const seen = []; const g = fixture(); g.TP.on('applying', value => seen.push(value));
  const backgroundPosts = () => g.calls.filter(c => c.method === 'POST' && c.url === '/api/apps/scan' && c.options && c.options.q && c.options.q.background === 1).length;
  g.noJob(true); clock.now += 60000;
  await g.TP.scanAppsBackground(); await tick();
  assert.strictEqual(backgroundPosts(), 1); assert.deepStrictEqual(seen, []); assert.strictEqual(g.TP.isApplying(), false); assert.strictEqual(g.graceTimers(), 0);
  g.pending({ at: 1, count: 1, names: ['Gemini'] }); clock.now += 60000;
  const list = await g.TP.scanAppsBackground(); await tick();
  assert.strictEqual(list.apps[0].name, 'Gemini'); assert.strictEqual(g.TP.S.apps.apps[0].state, 'direct');
  assert.strictEqual(g.TP.S.apps.pending.count, 1); assert.deepStrictEqual(g.TP.S.apps.pending.names, ['Gemini']);
  assert.strictEqual(backgroundPosts(), 2); assert.deepStrictEqual(seen, []); assert.strictEqual(g.TP.isApplying(), false); assert.strictEqual(g.graceTimers(), 0);
  assert.strictEqual(g.cards.length, 0); assert.strictEqual(g.toasts.length, 0);
  g.pending(null); g.noJob(false); clock.now += 60000;
  await g.TP.scanAppsBackground(); await tick();
  assert.deepStrictEqual(seen, [true, false]); assert.strictEqual(g.TP.isApplying(), true); assert.strictEqual(g.graceTimers(), 1);
  clock.now += 3000; g.runGrace(); await tick();
  assert.deepStrictEqual(seen, [true, false, false]); assert.strictEqual(g.TP.isApplying(), false); assert.strictEqual(g.graceTimers(), 0);
  seen.length = 0;
  await g.TP.loadApps(true); await g.TP.loadApps(true); await tick();
  assert.deepStrictEqual(seen, [true, false, true, false]); assert.strictEqual(g.TP.isApplying(), true); assert.strictEqual(g.graceTimers(), 1);
  g.TP.S.clash = 'applying'; clock.now += 3000; g.runGrace(); await tick();
  assert.deepStrictEqual(seen, [true, false, true, false, false]); assert.strictEqual(g.TP.isApplying(), false); assert.strictEqual(g.graceTimers(), 0);
  assert.deepStrictEqual(g.probes, ['/version']);
  seen.length = 0; g.fail(true); clock.now += 60000;
  assert.strictEqual(await g.TP.scanAppsBackground(), null); await tick();
  assert.deepStrictEqual(seen, [true, false]); assert.strictEqual(g.warnings.length, 1); assert.strictEqual(g.TP.S.scanning, false);
  g.fail(false); seen.length = 0;
  assert(await g.TP.loadApps(true)); await tick();
  assert.deepStrictEqual(seen, [true, false]); assert.strictEqual(g.graceTimers(), 1);
  console.log('PASS: quiet automatic discovery, visibility/reload cadence, shared scan, accurate manual titles and failure recovery; top bar: no-change scans silent, pending card without a job, grace window re-armed once, core re-probed');
})().catch(error => { console.error(error); process.exitCode = 1; });
