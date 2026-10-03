/// <reference path="../pb_data/types.d.ts" />
// enana.cc 应用设置: 名称/地址、限流、受信任代理头、超级用户来源限制、日志保留。
// 邮件 (SMTP) 暂不配置: 目前没有任何接口会发邮件 (找回密码 / 邮箱验证都没有开放)。以后要开, 管理员在后台 Settings → Mail 填写真实 SMTP。
migrate((app) => {
  const s = app.settings()

  // ---- 基本信息 ----
  s.meta.appName = "enana"
  s.meta.appURL = "https://enana.cc"
  s.meta.senderName = "enana"
  s.meta.senderAddress = "noreply@enana.cc"

  // ---- 受信任代理头 ----
  // nginx 会把真实客户端 IP 写进 X-Real-IP (并覆盖客户端自带的同名头)。
  // 不设置的话所有访客都是 127.0.0.1, 限流会把所有人一起锁住。
  s.trustedProxy.headers = ["X-Real-IP"]
  s.trustedProxy.useLeftmostIP = false

  // ---- 限流 (按 IP 计数; 每条规则、每个接口各自独立计数) ----
  // 规则按「标签」匹配: users:create = 注册; *:auth = 所有登录类接口; 其余走 /api/ 兜底 (后面的迁移会在兜底之前插入更具体的路径规则)。
  // 没有放 PocketBase 默认的 *:create (20 次/5 秒): 它会抢在路径前缀规则之前匹配, 让其它集合的限流规则对「创建」不生效。
  // 注意: 失败的请求 (校验不通过、密码错误) 也计数。
  s.rateLimits.enabled = true
  s.rateLimits.excludedIPs = []
  s.rateLimits.rules = [
    { label: "*:auth",       audience: "", maxRequests: 5,   duration: 10  },   // 登录: 每 IP 10 秒最多 5 次
    { label: "users:create", audience: "", maxRequests: 5,   duration: 600 },   // 注册: 每 IP 10 分钟最多 5 次
    { label: "/api/batch",   audience: "", maxRequests: 3,   duration: 1   },   // PocketBase 默认值 (批量接口本来就是关闭的)
    { label: "/api/",        audience: "", maxRequests: 300, duration: 10  },   // 其余所有接口的兜底 (PocketBase 默认值)
  ]

  // ---- 超级用户 (管理后台) 只接受来自本机的请求 ----
  // 管理员通过 SSH 隧道访问 127.0.0.1:8090; 即使 nginx 的屏蔽规则被绕过, 来自公网的超级用户登录 / 令牌也会被拒绝。
  // 以后要换/加来源: ./pocketbase superuser ips <ip或网段> ... (见 server/README.md)
  s.superuserIPs = ["127.0.0.1", "::1"]

  // ---- 日志: 只保留 7 天 (含访问 IP) ----
  s.logs.maxDays = 7
  s.logs.logIP = true
  s.logs.logAuthId = false

  s.batch.enabled = false                      // 不需要批量接口

  // ---- 备份: PocketBase 自带的定时备份 (每天 03:00, 本机保留 7 份, 存在数据目录的 backups/ 下) ----
  // 只能防「误操作 / 数据库损坏」, 不能防整块磁盘丢失: 想要异地备份, 把 backups/ 里的文件定期拷走 (见 README)。
  s.backups.cron = "0 3 * * *"
  s.backups.cronMaxKeep = 7

  app.save(s)
}, (app) => {
  // 回滚: 不还原设置 (没有安全的「上一个值」可恢复)。
})
