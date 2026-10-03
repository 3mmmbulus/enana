/// <reference path="../pb_data/types.d.ts" />
// enana 云端数据模型 (见 server/README.md 的数据模型图)。集合名按领域命名, 方便以后扩展 (付费套餐、更多设备类型 ...)。
//
//   users ──< subscriptions >── plans          账号 → 套餐 (每个账号一条订阅, 决定「每个平台最多同时在线几台」)
//     │
//     ├──< devices ──< device_sessions         账号 → 设备 → 登录会话 (会话撤销 = 设备下线)
//     ├──── sync_snapshots                     账号 → 一份端到端加密的配置快照 (云端只有密文)
//     └──< audit_events                        安全审计 (登录失败 / 踢设备 / 改密码 / 同步 ... 的轻量记录)
//
// 所有集合的 API 规则都是 null = 只有管理员 (超级用户) 能用 REST 接口直接读写。
// 本机辅助服务只通过 pb_hooks/enana_v1.pb.js 注册的 /api/enana/v1/... 接口访问, 那里按「当前登录用户」限定数据范围。
// 因此任何普通用户都不可能通过 PocketBase 自带的接口读写别人的 (甚至自己的) 这些记录。
migrate((app) => {
  const users = app.findCollectionByNameOrId("users")
  const created = { name: "created", type: "autodate", onCreate: true }
  const updated = { name: "updated", type: "autodate", onCreate: true, onUpdate: true }

  // ---- plans: 套餐定义 ----
  const plans = new Collection({
    type: "base",
    name: "plans",
    fields: [
      { name: "code",  type: "text", required: true, min: 1, max: 40, pattern: "^[a-z0-9_-]+$" },
      { name: "title", type: "text", max: 100 },
      { name: "max_devices_per_platform", type: "number", onlyInt: true, min: 1, max: 100 },   // 没有填时程序按 2 处理
      { name: "features", type: "json", maxSize: 20000 },
      { name: "active", type: "bool" },
      { name: "sort",   type: "number", onlyInt: true },
      created, updated,
    ],
  })
  plans.addIndex("idx_plans_code", true, "`code`", "")
  app.save(plans)

  // ---- subscriptions: 账号 ↔ 套餐 (每个账号一条) ----
  const subscriptions = new Collection({
    type: "base",
    name: "subscriptions",
    fields: [
      { name: "user", type: "relation", required: true, collectionId: users.id, cascadeDelete: true, maxSelect: 1 },
      { name: "plan", type: "relation", required: true, collectionId: plans.id, cascadeDelete: false, maxSelect: 1 },
      { name: "status", type: "select", required: true, maxSelect: 1, values: ["active", "expired", "cancelled"] },
      { name: "expires_at", type: "date" },                                                    // 空 = 不过期
      { name: "source", type: "select", maxSelect: 1, values: ["default", "manual", "payment"] },
      created, updated,
    ],
  })
  subscriptions.addIndex("idx_subscriptions_user", true, "`user`", "")
  subscriptions.addIndex("idx_subscriptions_plan", false, "`plan`", "")
  app.save(subscriptions)

  // ---- devices: 登录过的设备 ----
  const devices = new Collection({
    type: "base",
    name: "devices",
    fields: [
      { name: "user", type: "relation", required: true, collectionId: users.id, cascadeDelete: true, maxSelect: 1 },
      { name: "device_uid", type: "text", required: true, min: 8, max: 64, pattern: "^[A-Za-z0-9._-]+$" },   // 客户端生成的随机 UUID
      { name: "name", type: "text", max: 100 },
      { name: "platform", type: "select", required: true, maxSelect: 1, values: ["macos", "windows", "linux"] },
      { name: "os_version", type: "text", max: 64 },
      { name: "arch", type: "text", max: 32 },
      { name: "app_version", type: "text", max: 32 },
      { name: "last_seen_at", type: "date" },
      { name: "last_ip_masked", type: "text", max: 64 },                                         // 只存打码后的 IP, 例如 203.0.*.*
      created, updated,
    ],
  })
  devices.addIndex("idx_devices_user_uid", true, "`user`, `device_uid`", "")
  app.save(devices)

  // ---- device_sessions: 登录会话 ----
  // 「在线」= revoked_at 为空 && expires_at 未到 && 10 分钟内有心跳。
  const sessions = new Collection({
    type: "base",
    name: "device_sessions",
    fields: [
      { name: "user", type: "relation", required: true, collectionId: users.id, cascadeDelete: true, maxSelect: 1 },
      { name: "device", type: "relation", required: true, collectionId: devices.id, cascadeDelete: true, maxSelect: 1 },
      { name: "last_heartbeat_at", type: "date" },
      { name: "expires_at", type: "date" },                                                     // 绝对有效期 (登录后 30 天)
      { name: "revoked_at", type: "date" },                                                     // 空 = 未撤销
      { name: "revoked_reason", type: "select", maxSelect: 1, values: ["logout", "kicked", "limit", "expired", "admin", "password_changed"] },
      { name: "revoked_by_device", type: "relation", collectionId: devices.id, cascadeDelete: false, maxSelect: 1 },   // 谁踢的 (设备被删除时这里自动置空)
      created, updated,
    ],
  })
  sessions.addIndex("idx_device_sessions_user_revoked", false, "`user`, `revoked_at`", "")
  sessions.addIndex("idx_device_sessions_device", false, "`device`, `revoked_at`", "")
  app.save(sessions)

  // ---- sync_snapshots: 端到端加密的配置快照 (每个账号一份) ----
  const snapshots = new Collection({
    type: "base",
    name: "sync_snapshots",
    fields: [
      { name: "user", type: "relation", required: true, collectionId: users.id, cascadeDelete: true, maxSelect: 1 },
      { name: "version", type: "number", onlyInt: true, min: 0 },
      { name: "payload", type: "text", max: 1048576 },                                          // base64 密文: 云端没有解密密钥
      { name: "size", type: "number", onlyInt: true, min: 0 },
      { name: "source_device", type: "text", max: 100 },
      created, updated,
    ],
  })
  snapshots.addIndex("idx_sync_snapshots_user", true, "`user`", "")
  app.save(snapshots)

  // ---- audit_events: 安全审计 (账号删除时一并删除; 登录失败 14 天、其余 180 天后由定时任务清理) ----
  const audit = new Collection({
    type: "base",
    name: "audit_events",
    fields: [
      { name: "user", type: "relation", collectionId: users.id, cascadeDelete: true, maxSelect: 1 },       // 可为空 (例如不存在的邮箱登录失败)
      { name: "device", type: "relation", collectionId: devices.id, cascadeDelete: true, maxSelect: 1 },
      { name: "type", type: "select", required: true, maxSelect: 1,
        values: ["register", "login", "login_failed", "logout", "kick", "limit_blocked", "session_revoked", "password_changed", "sync_push", "sync_pull", "sync_clear"] },
      { name: "detail", type: "json", maxSize: 2048 },                                           // 很小的补充信息 (平台、版本号 ...); 登录失败只放邮箱 / IP 的哈希前缀, 用于限流计数
      { name: "ip_masked", type: "text", max: 64 },
      created, updated,
    ],
  })
  audit.addIndex("idx_audit_events_user_created", false, "`user`, `created`", "")
  audit.addIndex("idx_audit_events_type_created", false, "`type`, `created`", "")
  app.save(audit)

  // ---- 种子数据 ----
  // features = 这个套餐包含的功能 (功能目录在 pb_hooks/enana_lib.js 的 FEATURES: 哪些功能、属于哪一档、是否已上线)。
  // free: 每个平台最多同时在线 2 台, 免费功能全开。
  // pro: 占位 (active=false: 订阅指向它也不会生效, 直到管理员在后台把 active 打开并调整 max_devices_per_platform / features);
  //      官方线路 (official_proxy) 还没上线, 即使包含也不会下发任何节点。
  const free = new Record(app.findCollectionByNameOrId("plans"))
  free.set("code", "free")
  free.set("title", "Free")
  free.set("max_devices_per_platform", 2)
  free.set("features", ["core", "sync", "vps_deploy"])
  free.set("active", true)
  free.set("sort", 0)
  app.save(free)
  const pro = new Record(app.findCollectionByNameOrId("plans"))
  pro.set("code", "pro")
  pro.set("title", "Pro")
  pro.set("max_devices_per_platform", 3)
  pro.set("features", ["core", "sync", "vps_deploy", "official_proxy"])
  pro.set("active", false)
  pro.set("sort", 10)
  app.save(pro)

  // ---- 限流 (PocketBase 自带的按 IP 计数): 登录接口和同步接口更严; 路径规则必须排在兜底的 /api/ 之前 ----
  const s = app.settings()
  const wanted = [
    { label: "POST /api/enana/v1/auth/login", audience: "", maxRequests: 5,  duration: 10  },   // 与 PocketBase 自己的登录接口一样: 每 IP 10 秒最多 5 次
    { label: "POST /api/enana/v1/account/password", audience: "", maxRequests: 5, duration: 600 },  // 改密码会验证旧密码: 每 IP 10 分钟最多 5 次 (另有按邮箱的失败计数)
    { label: "/api/enana/v1/sync/",           audience: "", maxRequests: 30, duration: 600 },   // 同步是低频操作: 每 IP 10 分钟最多 30 次
  ]
  const rules = s.rateLimits.rules.filter((r) => !wanted.some((w) => w.label === r.label))
  const at = rules.findIndex((r) => r.label === "/api/")
  rules.splice(at < 0 ? rules.length : at, 0, ...wanted)
  s.rateLimits.rules = rules
  app.save(s)
}, (app) => {
  // 回滚: 不删除任何集合 (里面是用户数据)。
})
