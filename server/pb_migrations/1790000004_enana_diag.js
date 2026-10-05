/// <reference path="../pb_data/types.d.ts" />
// 诊断上传: diag_reports (账号 → 设备 → 若干份诊断; 见 docs/DIAGNOSTICS.md)。
//   summary  客户端自动上传的「诊断摘要」: 只有结构化的状态 / 判定 / 操作记录 / 健康汇总, 不含网站、应用名、IP、服务器地址、密码或令牌 (客户端按白名单生成)。
//   full     用户在后台点「发送完整诊断给开发者」才上传的压缩包 (含访问过的域名和应用名), 单独存成文件。
// 保留 7 天 (pb_hooks/enana_diag.pb.js 每天 03:27 清理); 每台设备最多保留最近 200 份摘要 / 5 份完整诊断; 账号 / 设备删除时级联删除。
// API 规则全是 null = 只有管理员能读; 客户端只通过 /api/enana/v1/diag 写入, 那里按「当前登录的会话」限定到自己的设备。
migrate((app) => {
  const users = app.findCollectionByNameOrId("users")
  const devices = app.findCollectionByNameOrId("devices")
  const diag = new Collection({
    type: "base",
    name: "diag_reports",
    fields: [
      { name: "user", type: "relation", required: true, collectionId: users.id, cascadeDelete: true, maxSelect: 1 },
      { name: "device", type: "relation", required: true, collectionId: devices.id, cascadeDelete: true, maxSelect: 1 },
      { name: "kind", type: "select", required: true, maxSelect: 1, values: ["summary", "full"] },
      { name: "trigger", type: "text", max: 40 },            // login | register | event:<类型> | manual
      { name: "cause", type: "text", max: 40 },              // 摘要里 verdict.cause 的副本, 方便按原因筛选
      { name: "app_version", type: "text", max: 32 },
      { name: "payload", type: "json", maxSize: 131072 },    // 摘要 JSON (summary)
      { name: "bundle", type: "file", maxSelect: 1, maxSize: 8388608, mimeTypes: ["application/gzip", "application/x-gzip", "application/octet-stream"] },   // 完整诊断 (full)
      { name: "created", type: "autodate", onCreate: true },
    ],
  })
  diag.addIndex("idx_diag_reports_device_kind_created", false, "`device`, `kind`, `created`", "")
  diag.addIndex("idx_diag_reports_created", false, "`created`", "")
  app.save(diag)
}, (app) => {
  try { app.delete(app.findCollectionByNameOrId("diag_reports")) } catch (_) { /* 已经没有 */ }
})
