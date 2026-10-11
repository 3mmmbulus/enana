'use strict';
// 同步快照的版本规则 (纯函数, 不需要 PocketBase): 清除只清空内容、版本号不回退; 旧版本号的推送必须冲突, 不能静默覆盖新内容。
const test = require('node:test'), assert = require('node:assert/strict');
const lib = require('../server/pb_hooks/enana_lib.js');

const row = (version, payload) => ({ getInt: () => version, getString: () => payload });

test('没有快照: 从版本 0 推到 1; 基线不对就冲突', () => {
  assert.deepEqual(lib.snapshotPushDecision(null, 0), { next: 1 });
  assert.deepEqual(lib.snapshotPushDecision(null, 2), { conflict: 0 });
});

test('有内容的快照: 基线必须等于当前版本', () => {
  assert.deepEqual(lib.snapshotPushDecision(row(3, 'AAAA'), 3), { next: 4 });
  assert.deepEqual(lib.snapshotPushDecision(row(3, 'AAAA'), 2), { conflict: 3 });
});

test('清除后 (内容为空、版本号保留): 云端当作没有数据, 版本号继续往上走, 旧基线的推送冲突', () => {
  assert.equal(lib.snapshotExists(null), false);
  assert.equal(lib.snapshotExists(row(3, '')), false);
  assert.equal(lib.snapshotExists(row(3, 'AAAA')), true);
  assert.deepEqual(lib.snapshotPushDecision(row(3, ''), 0), { next: 4 });
  assert.deepEqual(lib.snapshotPushDecision(row(3, ''), 3), { conflict: 0 });
});

test('场景: A 推送了一份; B 清除后重新推送; A 手里的旧基线推送被拒绝 (不会静默覆盖)', () => {
  // 用一行模拟云端的记录, 每一步都走同一个判断函数 (与 syncPut / syncDelete 的写法一致)
  let stored = null;
  const push = (base, payload) => {
    const d = lib.snapshotPushDecision(stored, base);
    if (d.conflict === undefined) stored = row(d.next, payload);
    return d;
  };
  const clear = () => { if (stored) stored = row(stored.getInt(), ''); };

  assert.deepEqual(push(0, 'P1'), { next: 1 });      // A 第一次推送
  clear();                                            // B 清除: 内容没了, 版本号还是 1
  assert.deepEqual(push(0, 'P2'), { next: 2 });      // B 清除后重新推送: 版本号没有回退到 1
  assert.deepEqual(push(1, 'PA'), { conflict: 2 });  // A 手里的旧基线 (1) 被拒绝, 必须先拉取
});
