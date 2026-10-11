'use strict';
// 偏好设置的云端写入规则 (纯函数, 不需要 PocketBase): 改动时间 (stamp) 新的获胜; 旧的写入得 409, 设备先拉取再写。
const test = require('node:test'), assert = require('node:assert/strict');
const lib = require('../server/pb_hooks/enana_lib.js');

const row = (version, stamp) => ({ getInt: (k) => (k === 'version' ? version : stamp) });

test('没有云端偏好: 版本号从 1 开始, 任何改动时间都接受', () => {
  assert.deepEqual(lib.prefsPutDecision(null, 0), { next: 1 });
  assert.deepEqual(lib.prefsPutDecision(null, 1700000000), { next: 1 });
});

test('改动时间不比云端旧 (相同也接受): 版本号 +1', () => {
  assert.deepEqual(lib.prefsPutDecision(row(3, 100), 100), { next: 4 });
  assert.deepEqual(lib.prefsPutDecision(row(3, 100), 150), { next: 4 });
});

test('改动时间比云端旧: 拒绝, 返回云端的版本和时间 (设备据此先拉取)', () => {
  assert.deepEqual(lib.prefsPutDecision(row(3, 100), 99), { stale: true, version: 3, stamp: 100 });
});

test('场景: A 在 100 写入; B 较早的改动 (90) 晚到被拒绝; B 拉取后再写 (110) 被接受', () => {
  let stored = null;
  const put = (stamp) => {
    const d = lib.prefsPutDecision(stored, stamp);
    if (d.next !== undefined) stored = row(d.next, stamp);
    return d;
  };
  assert.deepEqual(put(100), { next: 1 });
  assert.deepEqual(put(90), { stale: true, version: 1, stamp: 100 });
  assert.deepEqual(put(110), { next: 2 });
});
