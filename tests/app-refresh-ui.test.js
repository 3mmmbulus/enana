#!/usr/bin/env node
// Exercise the actual poller, visibility handler, job follower and data loaders.
const assert = require('assert'), fs = require('fs'), path = require('path'), vm = require('vm');
const storage = new Map(), clock = { now: 1000000 };
const tick = () => new Promise(resolve => setImmediate(resolve));
function deferred() { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; }
function fixture() {
  const calls = [], cards = [], toasts = [], warnings = [], events = {}, timers = new Map();
  let timer = 0, gate = null, fail = false;
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
    if (method === 'POST' && url === '/api/apps/scan') return { job: 'apps-scan-fixture' };
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
  const postScans = () => calls.filter(c => c.method === 'POST' && c.url === '/api/apps/scan').length;
  return { TP, calls, cards, toasts, warnings, events, document, postScans,
    gate: value => { gate = value; }, fail: value => { fail = value; } };
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
  console.log('PASS: quiet automatic discovery, visibility/reload cadence, shared scan, accurate manual titles and failure recovery');
})().catch(error => { console.error(error); process.exitCode = 1; });
