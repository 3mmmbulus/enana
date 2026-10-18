#!/usr/bin/env node
// 2.3.27 起没有「无操作自动锁定」: 仪表盘不需要任何密码就能打开 (enana 账号是可选的), 锁定没有意义 (业主决定)。
// 以前这个文件检查空闲锁定时间的默认值和范围 (TP.lockIdleMin: 默认 3 天, 1 分钟 ~ 30 天); 功能删掉之后改为检查它真的没有了, 也没有留下死代码 / 死设置 / 死文案:
// 1. 真实的 ui/core.js 加载后没有 TP.lockIdleMin, TP.CFG 里没有 LOCK_IDLE_* (其它常量还在)
// 2. 真实的 ui/core.js + ui/ui.js + ui/auth.js 加载后: 不往 document 上挂空闲检测的监听 (以前是捕获阶段的 pointerdown / keydown / wheel / touchstart),
//    不开任何定时器 (以前每 15 秒检查一次是否空闲), TP.auth 上没有 lock / expire / touch / idleLabel
// 3. 源码里没有 lock.idleMin 偏好、空闲锁定的下拉和文案; 词典里 set.lock.* / dur.* / auth.autoLock / auth.expired 两边都没有了
'use strict';
const assert = require('assert'), fs = require('fs'), path = require('path'), vm = require('vm');
const { makeBrowser, fakeI18n } = require('./ui-dom.js');
const read = f => fs.readFileSync(path.join(__dirname, '..', f), 'utf8');

// 1. core.js
const b = makeBrowser();
b.win.I18N = fakeI18n();
const intervals = [], timeouts = [];
b.win.setInterval = (fn, ms) => { intervals.push(ms); return intervals.length; };
b.win.setTimeout = (fn, ms) => { timeouts.push(ms); return timeouts.length; };
b.load('ui/core.js');
const TP = b.win.TP;
assert.equal(TP.lockIdleMin, undefined, 'TP.lockIdleMin is gone');
assert.deepEqual(Object.keys(TP.CFG).filter(k => /^LOCK_IDLE/.test(k)), [], 'no LOCK_IDLE_* constants');
assert.equal(TP.CFG.UPDATE_CHECK_HOURS, 6, 'the other constants are still there'); assert.equal(TP.CFG.ALLOW_SKIP_CONFIRM, true);

// 2. auth.js: no idle watching at all
b.load('ui/ui.js');
const before = { iv: intervals.length };
b.load('ui/auth.js');
for (const ev of ['pointerdown', 'keydown', 'wheel', 'touchstart']) assert.equal(b.doc.listenerCount(ev, true), 0, 'no capture listener for ' + ev + ' (idle detection)');
assert.equal(intervals.length, before.iv, 'auth.js starts no interval timer (the old idle check ran every 15 s)');
assert.equal(timeouts.filter(ms => ms === 15000).length, 0);
for (const k of ['lock', 'expire', 'touch', 'idleLabel']) assert.equal(TP.auth[k], undefined, 'TP.auth.' + k + ' is gone');
assert.equal(typeof TP.auth.openLogin, 'function', 'sign-in is a dialog now (TP.auth.openLogin)');

// 3. sources and dictionaries
const ui = fs.readdirSync(path.join(__dirname, '..', 'ui')).filter(f => /\.js$/.test(f)).map(f => read('ui/' + f)).join('\n');
for (const s of ['lock.idleMin', 'lockIdleMin', 'LOCK_IDLE_', 'idleLabel', "'set.lock.", "'dur.", 'auth.autoLock']) assert(ui.indexOf(s) < 0, 'no code mentions ' + s);
const dict = f => { const d = {}; vm.runInNewContext(read(f), { window: { I18N: { register: (c, o) => Object.assign(d, o) } } }); return d; };
for (const f of ['ui/i18n/zh.js', 'ui/i18n/en.js']) {
  const d = dict(f);
  assert.deepEqual(Object.keys(d).filter(k => /^set\.lock\.|^dur\.|^auth\.autoLock$|^auth\.expired$/.test(k)), [], f + ': the idle-lock texts are gone');
}
console.log('ok auto-lock: the idle auto-lock is gone (no timer, no listeners, no setting, no texts) — the dashboard opens without a password since 2.3.27');
