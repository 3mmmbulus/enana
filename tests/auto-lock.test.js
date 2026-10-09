// 空闲锁定时间 (设置 → 账号与设备 → 无操作多久后需要重新输入密码): 默认 3 天, 1 分钟 ~ 30 天, 非法值取默认 / 边界值。
const assert = require('node:assert/strict'), fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const src = fs.readFileSync(path.join(__dirname, '..', 'ui', 'core.js'), 'utf8');
function load(stored) {
  const win = {};
  win.window = win; win.location = { pathname: '/' }; win.document = { addEventListener() {}, hidden: false };
  win.I18N = { t: (k) => k, L: (k) => k, has: () => false, pick: (o, k) => o[k] };   // core.js 只在加载时取 I18N.t / L
  vm.createContext(win); vm.runInContext(src, win);
  win.TP.prefs = { get: (k, d) => (k === 'lock.idleMin' && stored !== undefined ? stored : d) };
  return win.TP;
}
const DEFAULT = 4320;
assert.equal(load(undefined).lockIdleMin(), DEFAULT, '没有设置时默认 3 天');
assert.equal(load(0).lockIdleMin(), 1, '0 夹到最短 1 分钟');
assert.equal(load(-5).lockIdleMin(), 1, '负数夹到最短 1 分钟');
assert.equal(load(1).lockIdleMin(), 1, '1 分钟');
assert.equal(load(99999).lockIdleMin(), 43200, '超过 30 天夹到 30 天');
assert.equal(load(43200).lockIdleMin(), 43200, '30 天');
assert.equal(load('abc').lockIdleMin(), DEFAULT, '非数字取默认值');
assert.equal(load(20.6).lockIdleMin(), 21, '小数四舍五入');
for (const m of load(undefined).CFG.LOCK_IDLE_PRESETS) assert.ok(m >= 1 && m <= 43200, '预设值都在范围内: ' + m);
assert.ok(load(undefined).CFG.LOCK_IDLE_PRESETS.includes(DEFAULT), '默认值在预设列表里');
console.log('ok auto-lock: 默认 3 天, 范围 1 分钟 ~ 30 天');
