/// <reference path="../pb_data/types.d.ts" />
// enana.cc 账号集合: users = 邮箱 + 密码 (+ 可选 name)。
// PocketBase 首次启动时已自带一个 users 集合, 这里把它改成我们要的样子 (声明式, 在全新数据目录上得到同样的结果)。
// 注意: 迁移只会执行一次 (记录在 _migrations 表)。以后要改配置, 新增一个时间戳更大的迁移文件, 不要改已执行过的这个。
migrate((app) => {
  let users
  try {
    users = app.findCollectionByNameOrId("users")
  } catch (_) {
    users = new Collection({ type: "auth", name: "users", id: "_pb_users_auth_" })
  }

  // ---- 访问规则: 任何人可注册 (网页和本机仪表盘都走这个接口); 其余操作只能针对自己的记录 ----
  users.createRule = "@request.body.disabled:isset = false"                              // 公开注册 (网页和本机仪表盘都走这个接口; 频率由 settings 里的限流控制); 不能自己指定 disabled
  users.listRule   = "id = @request.auth.id"
  users.viewRule   = "id = @request.auth.id"
  users.updateRule = "id = @request.auth.id && @request.body.disabled:isset = false"     // 改密码必须带 oldPassword (PocketBase 内置); verified / email / disabled 不能自己改
  users.deleteRule = "id = @request.auth.id"
  users.manageRule = null                    // 没有「管理员式」代改别人账号的规则
  users.authRule   = "disabled = false"      // 登录不要求邮箱已验证 (目前没有邮件服务); 被管理员停用 (disabled) 的账号不能登录

  // ---- 登录方式: 只开邮箱 + 密码 ----
  users.passwordAuth.enabled = true
  users.passwordAuth.identityFields = ["email"]
  users.oauth2.enabled = false
  users.otp.enabled = false
  users.mfa.enabled = false
  users.authAlert.enabled = false            // 不发「新设备登录」邮件 (本机辅助服务每次登录都会校验一次, 也没有邮件服务)

  // ---- 令牌: 3 天有效 (云端接口的心跳每次都会换发新令牌, 见 pb_hooks/enana_v1.pb.js) ----
  users.authToken.duration = 259200

  // ---- 字段: 去掉头像 (不接收任何文件), 密码 8~71 位, 加一个只有管理员能改的 disabled (账号停用) ----
  users.fields.removeByName("avatar")
  const pw = users.fields.getByName("password")
  pw.min = 8
  pw.max = 71                                // bcrypt 上限, PocketBase 默认也是 71
  let name = users.fields.getByName("name")
  if (!name) {
    name = new TextField({ name: "name" })
    users.fields.add(name)
  }
  name.max = 100
  if (!users.fields.getByName("disabled")) users.fields.add(new BoolField({ name: "disabled" }))   // 停用账号: 管理后台勾选后, 登录和所有云端接口都会拒绝

  // ---- 邮箱大小写不敏感且唯一: Foo@x.com 与 foo@x.com 是同一个账号 ----
  // PocketBase 只有在唯一索引带 COLLATE NOCASE 时才按不区分大小写去重 / 查找 (默认没有, 会产生两个「相同」的账号)。
  users.addIndex("idx_email__pb_users_auth_", true, "`email` COLLATE NOCASE", "`email` != ''")

  app.save(users)
}, (app) => {
  // 回滚: users 里是用户数据, 不做任何破坏性操作。
})
