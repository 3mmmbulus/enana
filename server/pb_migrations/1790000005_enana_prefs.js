/// <reference path="../pb_data/types.d.ts" />
// 偏好设置的云端副本: user_prefs (每个账号一行)。明文 JSON 对象 (界面习惯, 不含密码 / 令牌 / 网站 / 服务器地址), 独立于端到端加密的配置快照 (sync_snapshots)。
//   stamp    这份偏好最近一次改动的时间 (客户端给的秒数); 写入时比云端的新就拒绝 (409), 设备先拉取。
//   prefs    偏好 JSON 对象的文本, 服务器不解析, 原样保存。
// API 规则全是 null = 只有管理员能读; 客户端只通过 /api/enana/v1/prefs 读写, 那里按「当前登录的会话」限定到自己的账号。
migrate((app) => {
  const users = app.findCollectionByNameOrId("users")
  const created = { name: "created", type: "autodate", onCreate: true }
  const updated = { name: "updated", type: "autodate", onCreate: true, onUpdate: true }
  const prefs = new Collection({
    type: "base",
    name: "user_prefs",
    fields: [
      { name: "user", type: "relation", required: true, collectionId: users.id, cascadeDelete: true, maxSelect: 1 },
      { name: "version", type: "number", onlyInt: true, min: 0 },
      { name: "stamp", type: "number", onlyInt: true, min: 0 },
      { name: "prefs", type: "text", max: 16384 },
      { name: "device", type: "text", max: 100 },
      created, updated,
    ],
  })
  prefs.addIndex("idx_user_prefs_user", true, "`user`", "")
  app.save(prefs)
}, (app) => {
  try { app.delete(app.findCollectionByNameOrId("user_prefs")) } catch (_) { /* 已经没有 */ }
})
