# enana 本地辅助服务接口 (v2.1.1)

仪表盘 (浏览器) 与本地辅助服务 `lib/api.sh` 之间的契约。仪表盘页面由辅助服务自己在 `http://127.0.0.1:9091/enana/admin/` 提供 (端口被占用时安装器会换成别的空闲端口), 接口与页面同源 (不需要 CORS 预检)。
代理核心的 Clash API 监听 `http://127.0.0.1:9090` (`/proxies`、`/connections` …), 只允许仪表盘的来源跨域访问并要求令牌; 它的地址由 `env.json` 的 `clashBase` 给出。

> 本文件是前后端的唯一约定。改接口时先改这里。`tools/mock-server.js` 必须与本文件一致 (前端在没有后端时靠它开发)。

## 约定

| 项 | 说明 |
|---|---|
| 必带请求头 | `X-Enana: 1` (旧名 `X-TProxy: 1` 过渡期内也接受)。没有它一律 403。 |
| 二次验证头 | `X-Enana-Sudo: <令牌>`。只有「敏感操作」才需要 (见下面「敏感操作需要再次输入登录密码」); 缺失或过期 → HTTP 403 `E_SUDO_REQUIRED`。 |
| 语言头 | `X-Enana-Lang: zh` 或 `en`。后端据此翻译 `error`、任务进度文字 (`msg`、`steps[].label`)、更新说明。缺省取设置里的语言, 再缺省为 zh。 |
| 令牌头 | `X-Enana-Token: <token>`。除 `GET /api/auth/status` 与 `POST /api/login` 外都需要; 缺失或不对 → HTTP 401 + `{"ok":false,"code":"E_AUTH"}`。令牌就是核心 Clash API 的 secret (同一个), Clash API 请求用 `Authorization: Bearer <token>`。 |
| 请求体 | 表单接口用 `application/x-www-form-urlencoded` (**密码等敏感字段只放请求体, 绝不放 URL**); 导入/证书接口用纯文本。查询参数对除登录外的所有 POST 也有效。请求体 ≤ 4 MB。 |
| 响应 | 一律 JSON: `{"ok":true,...}` 或 `{"ok":false,"error":"已翻译的文字","code":"E_...", ...附加字段}`。HTTP 状态: 业务失败也是 200 (看 `ok`); 401 未登录; 403 来源/请求头不对; 404 接口不存在; 413 请求过大。 |
| 长任务 | 会改配置/要下载的操作返回 `{"ok":true,"job":"<id>"}`, 前端轮询 `GET /api/job?id=` (见下)。 |
| 错误码 | `E_AUTH` `E_BAD_CREDENTIALS` `E_DEVICE_LIMIT`(+`devices`) `E_LOCKED`(+`wait` 秒) `E_EMAIL_TAKEN` `E_WEAK_PASSWORD` `E_ACCOUNT_UNREACHABLE` `E_INVALID` `E_NOT_FOUND` `E_FORBIDDEN` `E_SUDO_REQUIRED` `E_NOT_RUNNING` `E_BUSY` `E_NETWORK` `E_NO_SERVERS` `E_RUNNING` `E_SSH_NO_CLIENT` `E_SSH_UNREACHABLE` `E_SSH_AUTH` `E_SSH_KEY` `E_SSH_HOSTKEY` `E_VPS_NO_PLAYBOOK` `E_VPS_PRIVILEGE` `E_VPS_UNSUPPORTED` `E_VPS_DEPS` `E_VPS_VERIFY` `E_VPS_NOT_DEPLOYED` `E_SYNC_KEY` `E_SYNC_CONFLICT` |

## 账号 / 登录 / 注册 / 代理总开关 (中心账号: enana.cc)

仪表盘的登录账号就是 **https://enana.cc** 的账号 (邮箱 + 密码); 本机不生成、不保存任何管理员密码。仪表盘里可以直接 **登录** 或 **注册** (注册由本地辅助服务代你向 enana.cc 提交, 用的是本机网络, 不用另开网站)。

- 任何有效的 enana.cc 账号都可以在这台电脑上登录 (没有「绑定」限制); 换账号 = 退出账号再登录另一个。
- **设备数量限制 (服务端强制)**: 同一账号、**同一平台 (macOS / Windows) 最多同时在线 2 台设备**。第 3 台登录时登录被拒绝 (`E_DEVICE_LIMIT`) 并返回该账号下的在线设备列表; 用户可以点某台设备「下线」, 成功后当前设备**自动完成登录**, 被下线的设备在下一次心跳 (≤ 2 分钟) 后**自动退出登录并关闭代理**。
- 在线时每次登录都向 enana.cc 校验; enana.cc 连不上时, **当前仍处于登录状态的账号** (比如换了浏览器/令牌丢了) 可用本机缓存的「加盐 PBKDF2 校验值」离线登录 (不保存明文密码); 其它账号, 以及已经退出账号的, 必须在线校验。离线连续超过 7 天 (心跳一直连不上) 本机会自动退出登录。
- **代理总开关**: 代理功能 (真正走代理服务器) 只有「已登录 + 用户在仪表盘里手动开启」时才工作。刚安装、刚登录、退出账号之后默认都是 **关闭** (所有流量直连, 不经过任何代理服务器; 本地 7890 端口和系统代理设置不变, 不会断网)。
  - **退出账号 (`POST /api/logout`) 会自动关闭代理**, 并让所有浏览器的令牌失效; 必须重新登录, 才能在仪表盘里再次开启代理。
  - 终端的 `enana on` 在没有登录时也会拒绝开启, 并提示先到仪表盘登录。
- 暂不支持找回密码 (以后再做): 仪表盘没有「忘记密码」入口。已登录用户可以在仪表盘里 **本地修改密码** (见 `POST /api/password`)。官网只有一个首页 (介绍 + 一键复制的安装命令), 没有注册 / 登录 / 账号页, 账号的注册、登录、改密码、设备管理都在仪表盘里完成。
- 服务器只保存账号 (邮箱 + 密码哈希); 服务器地址、订阅、规则、日志等一切代理数据都只在本机。

### `GET /api/auth/status` (公开)
```json
{"ok":true,"required":true,"account_hint":"e***@g***.com","offline_ok":true,"notice":"","account_url":"https://enana.cc","wait":0}
```
`account_hint`: 上一次在这台电脑上登录的账号 (掩码; 没有则 `""`); `offline_ok`: 能否用缓存离线登录该账号; `wait` > 0: 登录/注册被限流, 还需等待的秒数。前端可用 `localStorage` 记住上次输入的邮箱 (绝不记密码) 做预填。

### `POST /api/login` (公开) 表单 `user` (邮箱) `password` `kick` (可选: 要下线的设备 uid)
成功: `{"ok":true,"token":"…","account":"name@example.com","via":"online|offline"}`
设备已满 (本平台已有 2 台在线): `{"ok":false,"code":"E_DEVICE_LIMIT","error":"…","platform":"macos","limit":2,"devices":[{"uid":"…","name":"我的 MacBook Pro","platform":"macos","os":"14.5","last_seen":1760000000,"online":true,"ip_hint":"203.0.*.*"}]}` → 前端弹出「该账号下已有 2 台设备在线」对话框 (显示设备名 / 系统 / 最近活跃 / 大致位置, 每台一个「下线」按钮, 点击先二次确认), 确认后带着 `kick=<该设备 uid>` **重新提交同一次登录** (密码留在前端内存里, 不落盘), 成功即返回上面的令牌 (= 自动登录), 被下线的设备稍后自动退出。
其它失败: `E_BAD_CREDENTIALS` (账号或密码错误) · `E_LOCKED` (+`wait`: 连续失败 5 次后锁定 5 分钟, 或 enana.cc 限流) · `E_ACCOUNT_UNREACHABLE` (连不上 enana.cc, 且这个账号没有离线缓存) · `E_INVALID` (邮箱格式不对)。
请求最长约 15 秒 (要向 enana.cc 校验), 前端超时设 ≥ 20 秒。

### `POST /api/register` (公开) 表单 `user` (邮箱) `password` (8–128 位)
向 enana.cc 创建账号, 成功后自动登录: `{"ok":true,"registered":true,"token":"…","account":"name@example.com","via":"online"}`
失败: `E_EMAIL_TAKEN` (邮箱已注册 → 引导去登录) · `E_WEAK_PASSWORD` (密码至少 8 位) · `E_INVALID` (邮箱格式不对) · `E_LOCKED` (+`wait`: 本机注册过于频繁, 或 enana.cc 限流) · `E_ACCOUNT_UNREACHABLE` (连不上 enana.cc, 稍后重试)。无邮箱验证步骤。同样 ≥ 20 秒超时。

### `POST /api/logout` (需登录)
退出账号: **自动关闭代理** (全部直连) + 令牌立刻失效 (所有浏览器都要重新登录) + 立即释放这个设备的在线名额 (服务端会话撤销) → `{"ok":true}`。核心会在后台重启一次以换上新令牌 (约 2–3 秒, 期间仪表盘显示登录框即可)。「切换账号」= 先退出账号, 再用另一个账号登录 (同样会关闭代理)。

### `GET /api/devices` (需登录) → 我的设备
`{"ok":true,"platform":"macos","limit":2,"devices":[{"uid","name","platform","os","app","last_seen","online":true,"ip_hint","current":true}]}`。列出本账号全部设备 (所有平台), 当前设备 `current:true`; 用于「设置 → 我的设备」。连不上云端 → `E_ACCOUNT_UNREACHABLE` (前端给出原因, 不要做成死按钮)。
### `POST /api/devices/kick` (需登录) 表单 `uid` → `{"ok":true}` 下线另一台设备 (不能下线自己; 前端先二次确认)。被下线的设备在 ≤ 2 分钟内自动退出登录并关闭代理。

### `POST /api/proxy` (需登录) 表单 `on=0|1` 和/或 `mode=auto|global` (至少给一个)
代理总开关 + 代理模式 → `{"ok":true,"enabled":true,"mode":"auto"}`。`on=1` 时如果核心没在运行会先启动它 (最多等 10 秒, 失败 → `E_NOT_RUNNING`)。开启/关闭/切换模式都不重启核心 (热切换); `GET /api/state` 里的 `proxy.enabled` / `proxy.mode` 是当前状态。
三种状态 (前端做成「总开关 + 模式」):
- **关闭** (默认; 刚安装 / 刚登录 / 退出账号后): 全部直连, 不经过任何代理服务器。
- **自动模式** `auto` (开启后的默认模式): 智能分流 —— 国内网站直连, 海外与受限网站按策略走「自动线路」(自动选最快节点) 或「固定出口」(AI/账号类服务), 你对应用/网站的设置全部生效。
- **全局代理** `global`: 除本地网络、你手动指定的应用/网站、固定出口类服务 (Claude 等, 保证账号安全) 之外, 所有流量都走代理 (自动线路 / 你选的节点), 忽略「国内直连」规则。
模式设置会记住; 关闭总开关时模式保留, 再次开启沿用。

**系统代理 (2.3.8 起)**: `on=1` 且接管方式是 System Proxy (`proxy.network_mode=system`) 时, 响应多一个 `sysproxy` 字段, 让总开关和系统代理不再脱节 (以前必须去终端输入 `enana on` 并输入管理员密码):
- `{"sysproxy":{"state":"on"}}` 系统代理已经指向 enana, 没有改动。
- `{"sysproxy":{"state":"pending","job":"sysproxy-…"}}` 已在后台任务里开启 (macOS 可能弹出「输入 Mac 登录密码」的原生窗口, 要等用户输入, 所以不能卡住这个请求); 用 `GET /api/job?id=` 查进度。总开关本身已经生效, 授权被取消只会让这个任务失败 (消息说明原因), 不会撤销总开关。
- `{"sysproxy":{"state":"foreign"}}` 系统里正在使用其它代理设置 (可能是别的代理软件), **不擅自覆盖**; 由用户在界面上确认后调用 `POST /api/sysproxy`。
- Enhanced/TUN 模式没有 `sysproxy` 字段 (不使用系统代理, 也不改动用户现有的系统代理设置)。
`on=0` 不碰系统代理 (本地端口和系统代理设置不变, 核心仍在运行, 只是全部直连, 不会断网)。

### `POST /api/sysproxy` (需登录) 表单 `on=0|1` → `{"ok":true,"job":"sysproxy-…"}`
单独开启 / 关闭系统代理 (仪表盘概览 / 顶部提示条的「一键开启」)。**后台任务**, 步骤 `修改系统代理 → 确认结果`。授权方式依次是: ① 当前用户直接修改 (管理员账户多数不需要密码) ② 终端里用 sudo ③ 已有免密 sudo ④ 弹出 macOS 原生管理员密码框 (仪表盘的后台服务没有终端; 一次修改所有网络服务只弹一次框)。每次修改后回读确认。结果: `done` (`result.method` = `already|direct|sudo|sudo-nopass|dialog|user|tun`) 或 `error` (消息已翻译: 已取消授权 / 密码不正确 / 当前账户不是管理员 / 没有可弹窗的桌面会话 / macOS 未允许自动化 …)。成功与失败都会写进操作记录: 动作 `开启系统代理` / `关闭系统代理`, 详情 `method=… err=… port=… mode=…`。

### `POST /api/password` (需登录) 表单 `old` `new`
在本机修改 enana 账号的密码 (仪表盘里改, 官网没有账号页): 先在本机校验格式, 再向云端 `POST /api/enana/v1/account/password` 提交 (云端校验旧密码) → 成功后**当前设备保持登录** (云端返回新令牌 / 会话, 本机刷新离线校验值), **账号下其它设备全部被退出登录** (它们下次心跳收到 `session_revoked`, `notice:"password_changed"`, 代理自动关闭); 同时用新密码重新派生「云端同步」的密钥, 并把云端的同步快照用新密钥重新加密。
成功 `{"ok":true}`; 失败: `E_BAD_CREDENTIALS` (「当前密码不正确」, +`wait`) · `E_WEAK_PASSWORD` (新密码要 8-71 个字符, 且不能与旧密码相同) · `E_LOCKED` (+`wait`, 与登录共用失败计数) · `E_ACCOUNT_UNREACHABLE` (必须在线才能改; 离线登录时没有云端会话也不能改) · `E_AUTH` (HTTP 401: 云端会话已被撤销, 本机随后自动退出登录)。**不需要**额外的 sudo 令牌 (旧密码本身就是验证)。

## 敏感操作需要再次输入登录密码 (step-up) ★

部分敏感的「操作」和「显示」必须再校验一次**当前登录账号的密码**, 即使已经登录也一样 (防止别人趁你离开时点按钮/看到凭据):
- 需要再次验证的接口 (后端有一张白名单, 以后加功能只要往表里加一行): `POST /api/servers/delete` · `POST /api/sub/delete` · `GET /api/servers/secret` (显示某个节点的密码/UUID/密钥, 官方节点永远不显示) · `GET /api/sub/url` (显示订阅链接) · `POST /api/logs/clear` · `POST /api/devices/kick` · `POST /api/sync/clear` · `GET /api/export` (导出配置备份, 含凭据)。`POST /api/password` 本身就要输入旧密码, 不再额外要求 sudo。
- 令牌只存哈希 (`sudo.tokens`, 600), 5 分钟有效, 同时可以有多个 (多个浏览器标签), 退出账号 / 改密码立即全部失效; `POST /api/auth/verify` 的失败计数与登录共用。
- 流程: 调用需要验证的接口时, 没带有效的 `X-Enana-Sudo` 头 → HTTP 403 `{"ok":false,"code":"E_SUDO_REQUIRED","error":"此操作需要再次输入登录密码"}` → 前端弹出「请输入登录密码以继续」对话框 (说明为什么要验证、验证后 5 分钟内不再询问) → `POST /api/auth/verify` → 拿到 `sudo` 令牌 → 带着 `X-Enana-Sudo: <令牌>` 重试原请求。前端把 sudo 令牌只放内存 (到期/退出登录/锁屏即丢弃), 不落盘。
### `POST /api/auth/verify` (需登录) 表单 `password` → `{"ok":true,"sudo":"<令牌>","ttl":300}`
密码在本机用「加盐 PBKDF2 校验值」验证 (登录时在线校验过; 不需要联网); 连续错 5 次锁定 5 分钟 (`E_LOCKED` + `wait`, 和登录共用计数); 错误 `E_BAD_CREDENTIALS`。令牌 5 分钟有效 (`ttl` 秒), 退出账号立即失效。
### `GET /api/servers/secret?tag=` (需 sudo) → `{"ok":true,"tag":"…","fields":[{"name":"password","value":"…"},{"name":"uuid","value":"…"}]}`
`fields` 只含凭据类字段 (`username` `password` `uuid` `auth_str` `private_key` `pre_shared_key` `obfs_password`, 有哪个返回哪个); 找不到 → `E_NOT_FOUND`; 官方线路 (会员) 的节点 → `E_FORBIDDEN`。查看会写一条操作记录 (只记节点名, 不记凭据)。
### `GET /api/sub/url?name=` (需 sudo) → `{"ok":true,"name":"…","url":"https://…"}`
### `GET /api/export` (需 sudo) → 配置备份 (JSON 文件, `Content-Disposition: attachment; filename="enana-backup-YYYYMMDD.json"`), 前端提示「请妥善保管, 不要发给别人」
内容就是「配置快照」(也是云端同步用的格式, 见下面「云端同步」): `{"format":1,"app":"enana","version":"2.1.0","created":1760000000,"device":"MacBook","files":{"servers.jsonl":"…","subs.tsv":"…","dns.conf":"…","overrides.tsv":"…","rules.state":"…","custom-rulesets.tsv":"…","custom-apps.tsv":"…","site-domains.tsv":"…","hosts.tsv":"…","speedtest-custom.tsv":"…","prefs.json":"…","vps.jsonl":"…"},"certs":{"名称.crt":"PEM"},"settings":{"LANG_UI":"zh","LOG_DAYS":"30","ACCESS_LOG":"1","AUTO_UPDATE":"1"}}` (没有内容的文件不出现)。含服务器凭据与订阅链接。**永远没有**: 登录令牌 / 云端令牌 / 设备编号 / 端口 / 代理总开关 / 开机自启 / SSH 密码或私钥。官方节点 (会员) 不包含在内。
前端约定: 这些入口旁边显示一个小锁图标, 点开先弹密码框; 验证成功后 5 分钟内在同一浏览器会话里不再询问。

## 会员 / 套餐 (为以后收费预留) ★

目前所有功能免费, 但接口和界面按「以后部分功能按月订阅」设计:
- **套餐与权益** 在云端 (`plans` / `subscriptions`), 本机缓存一份 (登录时和每天维护时刷新); 本机只用于「界面提示」, **真正的限制在云端**: 受限内容 (如官方线路) 只有云端核对订阅后才会下发。
- `GET /api/plan` (需登录) →
```json
{"ok":true,"plan":{"code":"free","title":"免费版"},"expires_at":null,"checked":1760000000,
 "limits":{"devices_per_platform":2},
 "features":{"core":{"enabled":true,"tier":"free"},"sync":{"enabled":true,"tier":"free"},"vps_deploy":{"enabled":true,"tier":"free"},
             "official_proxy":{"enabled":false,"tier":"pro","reason":"upgrade","coming_soon":true}},
 "official":{"available":false,"nodes":0}}
```
`features.<key>`: `tier` = `free | pro`; `enabled` = 当前账号能否使用; `coming_soon:true` = 还没上线 (前端显示「即将推出」灰色卡片, 不可点); `reason`: `upgrade` (需要升级) · `expired` (订阅已过期) 。`official` 描述官方线路是否可用 (以后订阅用户登录后自动出现「enana 官方线路」节点, 凭据不可查看/不可导出, 订阅过期后下次同步自动消失, 本机缓存最多再保留 3 天宽限)。
- 本机缓存 1 小时 (`plan.json`): 缓存过期时先返回旧的并在后台刷新, 从没取过才同步等; 登录后和每天维护时也会刷新; 连不上云端就用缓存, 什么都没有就是内置的「免费版」。`plan.title` 免费版 / 专业版按请求语言翻译, 其它套餐用云端给的名字。
- 前端约定: 「设置 → 账号」里显示当前套餐卡片 (免费版 / 将来的 Pro: 到期日、设备上限、功能清单, 「升级」按钮暂时置灰并写明「即将开放」); 服务器页预留一张「enana 官方线路 (会员)」占位卡片 (`coming_soon`); 受限功能旁显示「Pro」小徽标 + 锁图标, 点击弹窗说明, 不做死按钮。所有功能开关都读 `GET /api/plan` 的 `features`, 不要在前端写死「免费 / 付费」。

## 设置 / 语言

### `GET /api/settings`
```json
{"ok":true,"lang":"zh","settings":{"log_hours":72,"log_hours_min":12,"log_hours_max":720,"log_ops":true,"access_log":true,"log_core":true,"auto_sites":false},
 "usage":{"ops":1234,"access":56789,"proxy":56789,"total":58023},
 "ports":{"proxy":7890,"ui":9090,"api":9091,"speed":7892},"account":{"email":"name@example.com"}}
```
### `POST /api/settings` 表单 (字段都可选)
`lang=zh|en` · `log_hours=12..720` (日志保留时长 ★ 2.1.1: 最短 12 小时, 最长 30 天, 默认 72 = 3 天; 旧版仪表盘提交的 `log_days=1..30` 仍然接受并换算成小时) · `log_ops=0|1` (操作记录, 立即生效) · `access_log=0|1` (网站访问) · `log_core=0|1` (代理核心日志) · `auto_sites=0|1` (自动识别无法访问的网站, 开启时必须已有服务器, 否则 `E_NO_SERVERS`) → `{"ok":true}`; 改 `access_log` / `log_core` 需要重新生成配置 (重启核心), 返回 `{"ok":true,"job":"…"}`。
三种日志各自的开关: 关闭只影响「之后」的记录, 已有的仍按保留时长清理。`access_log=0` → 核心只记警告和错误 (level warn); `access_log=0` 且 `log_core=0` → 核心完全不写日志 (`log.disabled`); `log_core=0` 但 `access_log=1` → 核心照常写 (连接记录要用), 只是把和连接无关的核心事件在切分时丢掉、读取时不显示。关闭操作记录时, 「关闭」这一条本身会先写下来。

### 恢复官方默认规则 (2.3.8 起, 设置 → 代理)

把「自己改过的规则」一次清掉, 回到官方默认。**以云端下发的官方内容 (签名校验) 为准**, 不会用「云端同步」里保存的那一份 (它可能已经带着错误的设置)。

`GET /api/settings/reset` (需登录, 只读; 确认框用):
```json
{"ok":true,"apps":3,"sites":1,"auto_sites":1,"services":2,"rulesets":1,"toggles":2,"custom_apps":1,"domains":1,"hosts":1,"dns":1,"auto_on":1,
 "total":14,"logged_in":true,"content":{"source":"cloud","seq":2026100401,"version":"2026.10.04.01","checked":1791000000,"error":""},
 "sync":{"enabled":false,"auto":false},"backup":{"name":"reset-1791000000.tgz","time":1791000000}}
```
- 每一项是「自己改过的」数量: `apps` 应用的代理设置 · `sites` 自己添加的网站 · `auto_sites` 自动识别添加的网站 · `services` 网站 / 服务的出口开关 (和默认不同的; 开关的选择由代理核心记住, 默认值取当前配置里每个开关的 `default`, 兜底出口 `Final` 也算) · `rulesets` 自定义规则集 · `toggles` 规则集开关 (和默认不同的) · `custom_apps` 自定义软件 · `domains` 网站域名改动 · `hosts` 自定义解析 · `dns` DNS 设置是否被改过 (0 / 1) · `auto_on` 自动识别是否开着 (0 / 1, 不计入 `total`)。
- `content.source`: `cloud` = 本机有云端下发的官方内容, `baseline` = 只有随程序自带的基线。`backup` = 最近一次重置的备份 (可撤销), 没有时是 `null`。

`POST /api/settings/reset` (需登录, 无参数) → `{"ok":true,"job":"rules-reset-…"}`。后台任务 (同一把配置锁、失败整体回滚): ① 把要清掉的文件打包到 `~/.enana/backups/reset-<时间>.tgz` (权限 600, 只留最近 3 份; 本来就是默认状态时不建备份) ② 清掉 `overrides.tsv autosites.tsv autosites.dismissed rules.state custom-rulesets.tsv custom-apps.tsv site-domains.tsv hosts.tsv dns.conf`, 关闭自动识别 ③ **强制重新下载云端官方内容** (就算序号没变也换一份; 离线 / 没登录就用本机已验证的官方内容, 一份都没有用基线) ④ 网站 / 服务的出口开关和兜底出口通过核心的 API 热切回默认 ⑤ 像第一次安装那样重新识别应用 (推荐值来自官方内容, 标记 `def`, 不会弹出一堆「新应用」) ⑥ 补下默认启用的规则集、生成并应用配置。不动: 服务器 / 订阅 / 账号 / 端口 / 语言 / 日志和更新设置 / 测速自定义目标 / 界面偏好 / 节点选择 (`PIN` `Global`)。任务结果: `{"content":"cloud|cached|baseline","seq":2026100401,"error":""}` —— `cached` = 没连上云端, 用了本机已有的官方内容 (`error` 是原因); `baseline` = 从没拿到过云端内容。失败 (配置没通过校验等) 时所有文件和开关原样恢复, 也不留下备份。

`POST /api/settings/reset/undo` (需登录, 无参数) → `{"ok":true,"job":"rules-reset-undo-…"}`: 把最近一次重置清掉的文件放回去 (包括自动识别开关、出口开关原来的选择; 自定义规则集按登记的链接重新下载), 备份用完即删; 没有备份 → `E_NOT_FOUND`。

操作记录: `恢复官方默认规则` (详情是重置前各类规则的数量, 如 `apps=3 sites=1 services=2 …`) · `撤销恢复默认`。

## 状态 / 应用 / 覆盖 / 服务器 / 订阅 (与 v2 相同, 新增字段见 ★)

`GET /enana/admin/…` (无需 `X-Enana` 头; 只读, 白名单扩展名, 只给 GET / HEAD): 仪表盘静态文件由辅助服务直接提供 (`/enana/admin/` = index.html, `/enana/admin/<页面>` 也给 index.html, 页面名 = overview apps sites rules dns servers conns traffic speed logs settings login register; 不带斜杠的 `/enana/admin` 与 `/` 跳转到 `/enana/admin/`)。核心控制接口 (Clash API) 在 `ports.ui` 上, 只允许这个来源跨域访问, 地址写在 `env.json` 的 `clashBase`, 接口同源 (`apiBase` 为空)。

**应用 / 覆盖的新字段 ★ 2.1.1**:
- `apps[]` 每项多了 `target` (状态是 pin 时: 空 = 默认固定出口, `PINAUTO` = 在固定出口里自动选, 其它 = 指定走这一个固定出口) 和 `target_ok` (指定的固定出口还在吗); `flag` 多了一种值 `def` (首次扫描按推荐给的默认值: 云端推荐更新后会自动刷新, 不算「新应用」)。
- `POST /api/override` 的 `target` 只对 `state=pin` 有意义 (其它状态忽略); 固定出口不到 2 个时只能留空; 取值必须是空 / `PINAUTO` / 现有的某个固定出口, 否则 `E_INVALID`。固定出口最多 16 个可以单独指定 (按配置里的顺序)。
- `state.overrides[]` (网站覆盖) 每项: `{kind:"site",value,state,target,target_ok,src:"user|auto",at,why,fails,app}` —— `src=auto` 是「自动识别」添加的 (`at` 添加时间 unix 秒, `why` 失败类型 timeout|reset|refused|eof, `fails` 失败次数, `app` 触发的应用)。
- `POST /api/override` 把自动识别添加的网站设成「跟随规则」= 删除它, 并且以后不再自动添加这个网站。
- 新应用 (`flag=new`): 浏览器 (声明能打开 http / https 链接的应用) 默认「跟随规则」, 其它新应用默认「关」(直连); 仪表盘打开「应用」页就算已知晓, 会 `POST /api/apps/ack?all=1` 把新标记确认掉, 导航上的数字随之消失。
- 应用扫描范围: `/Applications` (含子目录)、`/System/Applications` (含 Utilities, 终端等系统应用)、`/System/Cryptexes/App/System/Applications` (Safari)、`/System/Library/CoreServices/Applications`、`~/Applications`, 再加 Spotlight 能找到的其它位置 (只收录 /Applications、/System/Applications、`~/Applications`、/opt/homebrew、/usr/local 下的顶层 .app, 不含应用内嵌的辅助程序)。

`GET /api/state` → `{ok,version,prefs_version★,core,platform:{os,osver,arch},ports:{proxy,ui,api,speed★},env:{core,rules,service,sysproxy,shortcut (快捷命令的安装位置, 没装是 null),shortcut_cmd★ (在终端里直接可运行、打开控制台的完整命令: 装了快捷命令 = `enana`, 没装 = 脚本的完整路径),rules_updated,rules_missing[]},servers[],subs[],overrides[],first_run,`
`update★:{available,latest,checked},lang★,proxy★:{enabled,mode:"auto|global"},account★:{email}}`

`GET /api/apps` · `POST /api/apps/scan` · `POST /api/apps/adopt` (表单 `names` 可选: 换行分隔的应用名, 只处理这几个; 不带 = 所有 flag=new 的应用) · `POST /api/apps/ack?name=|all=1` · `POST /api/override?kind=&value=&state=[&target=]` ·
`POST /api/servers/import?sub=&mode=merge|replace&save=0|1` (正文=JSONL; **save★**: 1 = 「保存到云端」, 这些节点 (和订阅) 进入云端同步清单, 第一次用时自动打开云端同步; 0 = 只留在本机; 不带 = 不改动, 例如订阅自动刷新) · `POST /api/servers/delete?tag=` · `POST /api/servers/role?tag=&role=pin|auto|off|dl` ·
`POST /api/cert?name=` · `POST /api/sub/fetch` · `POST /api/sub/save?name=&save=0|1` · `POST /api/sub/delete?name=` · `POST /api/restart` — 形状不变。

### `GET /api/job?id=`
`{"ok":true,"id","name","state":"running|done|error","pct":0-100,"msg":"…","steps":[{"label":"…","state":"todo|run|done|error"}],"result":{}}`; `msg`/`label` 按 `X-Enana-Lang` 翻译。

## 策略切换 / 审计 / 自动识别 ★ (v2.1.1 新增)

### `POST /api/policy` 表单 `tag` `name`
由辅助服务代为切换一个策略开关 (网站 `svc-<id>` / 自定义规则集 `svc-rs-<id>` / 默认出口 `Final` / 自动线路 `Global` / 固定出口 `PIN`), 并写进操作记录 (原来 → 现在)。`name` 必须是这个选择器现有的选项 (`PIN` `Global` `direct`; 固定出口有 2 个以上时还有 `PINAUTO` 和每个固定出口的名字), 否则 `E_NOT_FOUND`; 核心没运行 → `E_NOT_RUNNING`。→ `{"ok":true,"from":"PIN","to":"Tokyo-Fix"}`。仪表盘不再直接对核心 `PUT /proxies/<tag>`。
### `POST /api/audit` 表单 `ev=kill` `scope=all|one|host` `n=数量` `host=域名` (可选)
仪表盘直接对核心做的「断开连接」事后补一条操作记录 (`断开连接`); 其它 `ev` → `E_INVALID`。
### `POST /api/sites/auto/clear` → `{"ok":true,"removed":N}`
撤销所有「自动识别」添加的网站 (并且以后不再自动添加它们); 你自己添加的不受影响。
### 自动识别无法访问的网站 (设置 `auto_sites=1`)
后台每分钟 (`enana tick`) 读一次核心日志的新增部分: 出口名为 `direct` 或 `direct-cn` 的连接失败 (超时 / 被重置 / 被拒绝 / EOF); 同一个网站 (一般取最后两段, `co.uk` 之类三段, 共享托管域名取完整主机名) 15 分钟内失败 ≥ 3 次且 ≥ 60% 的尝试失败, 就加入「网站」覆盖 (有自动线路用自动线路, 否则固定出口), 先用代理实际访问一次验证: 通了保留 (写进 `autosites.tsv`), 不通就撤销并 24 小时内不再试。不参与: 你明确设置的网站 / 应用直连 (出口 `direct-site` / `direct-app`)、局域网、目录里已有的服务、你已经有覆盖的网站、你删除过的、代理总开关关闭 / 全局模式、整个网络都在失败时 (断网)。每小时最多 5 个、一共最多 200 个; 每次添加 / 放弃都写进操作记录 (来源 `auto`)。

## 更新

### `GET /api/update/check[?force=1]`
```json
{"ok":true,"current":"2.1.0","latest":"2.2.0","available":true,"checked":1760000000,"notes":"按语言选好的更新说明","notes_zh":"…","notes_en":"…",
 "url":"https://github.com/3mmmbulus/enana/releases","error":"","code":"","core":{"current":"1.14.2","latest":"1.14.3","available":true}}
```
`error` 非空表示这次没查到 (`code:"E_NETWORK"`), 其余字段是上次缓存的结果。
### `POST /api/update/apply?what=app|core` → `{"ok":true,"job":"…"}`
`app`: 下载新版、校验、替换文件、重启辅助服务 (任务进行中辅助服务会短暂断开, 前端容忍); `core`: 先用新核心校验现有配置, 通过才替换, 否则回退。

## 流量统计 ★ (v2.1 新增)

### `GET /api/stats?range=today|3d|7d|30d|90d` (需登录)
```json
{"ok":true,"range":"7d","granularity":"day","from":"2026-09-26","to":"2026-10-02","since":"2026-09-30","retention_days":92,
 "total":{"up":123456,"down":9876543},
 "routes":{"direct":{"up":1,"down":2},"pin":{"up":1,"down":2},"auto":{"up":1,"down":2}},
 "series":[{"t":"2026-09-26","up":0,"down":0,"direct":0,"pin":0,"auto":0}],
 "nodes":[{"tag":"Tokyo","up":1234,"down":5678}]}
```
- 单位字节。`today` 按小时 (`granularity:"hour"`, `series` 恒为 24 项, `t` = `"00"`…`"23"`); 其它按天 (`granularity:"day"`, `series` 长度 = 3/7/30/90, 旧→新, `t` = 日期, 没有数据的日子是 0)。
- `series[].direct / pin / auto` = 该时段走 直连 / 固定出口 / 自动线路 的流量 (上传 + 下载); `routes` 是整个范围内三类的上传/下载; `nodes` 是各节点 (固定出口 + 自动线路里的节点) 的上传/下载, 按总量降序。
- **精度**: 总量来自核心的累计计数 (准确); 分类 (直连 / 固定出口 / 自动线路 / 节点) 由每分钟一次的采样得到, 采样间隔内已经结束的短连接按当时的比例分摊 (估算) —— 页面上注明「分类为估算」。**发往本机 / 局域网 (私有地址) 的流量不统计**。
- **本地存储, 自动清理**: 统计数据只在本机 (`~/.enana/stats/`), 不上传; 超过 3 个月 (92 天) 的数据每天自动清除, 前端页面注明「仅保留最近 3 个月」。`since` = 本机最早有数据的日期 (没有数据则 `""`, 前端显示「还没有统计数据, 开启代理并使用一会儿后这里会出现图表」)。
- 刚安装 / 核心刚重启 / 代理关闭期间的流量同样会统计 (直连流量也算)。

### `GET /api/stats/apps?range=today|3d|7d|30d|90d` (需登录, 2.3.8 起)
```json
{"ok":true,"range":"today","from":"2026-10-04","to":"2026-10-04","apps":[{"name":"Google Chrome","up":1234,"down":567890},{"name":"Slack","up":10,"down":2048}]}
```
每个应用在这个范围内的流量 (单位字节, 按总量从大到小); 应用页的「今日流量」列用它。归属来自每分钟一次的连接采样 (进程名 → 应用名), 同样是估算; 没有流量的应用不在列表里。数据在本机 `~/.enana/stats/apps.tsv`, 和其它统计一起保留 92 天。

> 2.3.8 修复: 之前从第二天起每天的统计会被重复累加成「最后一分钟」, 导致历史日期 (如 10 月 3 日) 的流量显示为 0 / 缺失。现在读取时会把重复的行合并 (历史自动恢复), 并且每天记录采样分钟数, 界面据此区分「没有流量」和「那天没有采集到数据」。

## 日志

- `GET /api/logs?type=ops|access|proxy&day=YYYY-MM-DD&q=关键字&limit=500&offset=0&f=筛选` → `{"ok":true,"days":["2026-10-02",…],"total":N,"rows":[…],"summary":{…}}` (新→旧; `total` 是筛选之后的条数)
  - 筛选 `f`: `ops`: `error` (失败) · `dashboard` · `terminal` · `auto` (按来源); `access`: `direct` · `proxy` · `error` (失败); `proxy`: `warn` (警告和错误) · `error`。
  - `ops` 行: `{ts,who:"dashboard|terminal|auto",action,detail,result:"ok|error"}`; `detail` 一律是 `key=value` (值里有空格时加引号, 例如 `kind=app name="Google Chrome" from=follow to=pin target_to=Tokyo-2`); 汇总 `{all,error}`
  - `access` 行 ★ 2.1.1: `{ts,id,net:"tcp|udp",host,port,app,user,path,route:"direct|pin|auto|other|none",node,reason,err,errmsg,dur,ips}` —— `node` 是实际出口名; 直连时 `node` 是 `direct-mode` (代理总开关关闭) / `direct-lan` (本机和局域网) / `direct-site` (你把该网站设为直连) / `direct-app` (你把该应用设为直连 (关)) / `direct-cn` (国内规则) / `direct` (策略选了直连), `reason` 是对应的 `mode|lan|site|app|cn|policy`; 连接失败时 `err` = `timeout|refused|reset|unreachable|dns|tls|eof|rejected|other`, `errmsg` 是核心给的原因, `dur` 是失败时已经过的时间, `ips` 是解析到的地址 (域名被污染时能直接看到); `route:"none"` = 没有转发 (没到选出口那一步就失败了)。汇总 `{all,direct,proxy,pin,auto,error,reasons:{cn:17,…},top_fail:[{host,n,err,app,node}]}` (搜索之后、筛选之前的数字)
  - `proxy` 行: `{ts,level,msg}`; 汇总 `{all,warn,error}`
- `GET /api/logs/bundle?hours=1..720|all&sections=ops,access,proxy,snapshot` → `text/plain` (诊断导出: 一个自描述的文件, 格式见 docs/DIAGNOSTICS.md; `snapshot` = 环境 / 脱敏后的配置与策略 / 服务器 / 应用 / 实时自检 / 当前连接的命中规则, 含一次最多约 8 秒的网络自检)。仪表盘「日志 → 导出」就是它; 终端: `enana diag [小时数]`。
- `GET /api/logs/export?type=&day=` → `text/plain` (旧接口: 单类日志, 仪表盘不再使用)
- `POST /api/logs/clear` 表单 `type=ops|access|proxy|all` `before=YYYY-MM-DD` (可选, 不填=全部) → `{"ok":true,"freed":字节数}` (需 sudo)
- 保留时长默认 72 小时 (3 天), 设置里可调 12 小时 – 30 天, 每小时自动清理一次 (整天过期的文件直接删, 截止时间所在那一天里更早的行逐行裁掉); 三种日志各有开关 (见「设置」)。

## 规则库 / DNS

- `GET /api/rules` → `{"ok":true,"sets":[{tag,name,desc,repo,present,bytes,updated,enabled,essential,custom,policy?}],"updated":ts}`
- `POST /api/rules/toggle` 表单 `tag` `on=0|1` → `{ok,job}` (启用时下载并应用; essential 的不可关 → `E_INVALID`)
- `POST /api/rules/custom/add` 表单 `name` `url` `policy=pin|auto|direct` → `{ok,job}` (url 必须是 http(s) 的 .srs 二进制规则集)
- `POST /api/rules/custom/delete` 表单 `tag` → `{ok,job}`
- `POST /api/update-rules` → `{ok,job}`
- `GET /api/dns` → `{"ok":true,"settings":{cn,cn_custom,global,global_custom,via:"Global|PIN",strategy,leak_guard,ads_block},"presets":{"cn":[{id,name,desc,url}],"global":[…]},"pipeline":[{id,match,server,via,detail}]}`
- `POST /api/dns` 表单 `cn` `cn_custom` `global` `global_custom` `via` `strategy` `leak_guard=0|1` `ads_block=0|1` (都可选) → `{ok,job}`
- `POST /api/dns/test` 表单 `name=example.com` → `{"ok":true,"name":"…","answers":["1.2.3.4",…],"ms":23}` (经核心的 DNS 解析, 看实际用的是哪套)

## 本机 IP 与测速 ★ (v2.1 新增)

### `GET /api/net/info`
读缓存 (10 分钟内有效); 从没查过时返回 `{"ok":true,"checked":0}`。
```json
{"ok":true,"checked":1760000000,"state":"normal|limited|blocked|unknown","reason":"可选: 文字说明 (已翻译)",
 "lan":{"ip":"192.168.1.23","iface":"en0"},
 "direct":{"ok":true,"ip":"1.2.3.4","country":"CN","country_name":"China","region":"Guangdong","city":"Shenzhen","isp":"China Telecom","asn":"AS4134","source":"ipwho.is"},
 "routes":[{"id":"PIN","name":"固定出口","ok":true,"ip":"5.6.7.8","country":"JP","country_name":"Japan","region":"Tokyo","city":"Tokyo","isp":"…","asn":"AS…"},
           {"id":"Global","name":"自动线路","ok":false,"reason":"timeout"}]}
```
失败的项带 `ok:false` 和 `reason` (`timeout|dns|reset|http_403|…`)。`state`: `normal` 一切正常 · `limited` 有目标拒绝/限制这个 IP (多个 HTTP 403/429/451) · `blocked` 几乎全部不通 (IP 被封或网络断开) · `unknown` 还没查。前端用 盾牌✓ / 盾牌! / 盾牌✗ 图标 + 文字提示。
没有添加服务器时 `routes` 为空数组 (前端显示「还没有节点」而不是失败)。

### `POST /api/net/refresh` → `{"ok":true,"job":"net-info-…"}`
后台重新查询 (约 3–8 秒); 完成后再 `GET /api/net/info`。

### `GET /api/speedtest/plan`
```json
{"ok":true,"direct_available":true,"node_available":true,
 "targets":[{"id":"google","group":"global|cn|carrier","name":"Google","url":"https://www.google.com/generate_204","icon":"google"}],
 "nodes":[{"tag":"tokyo-1","role":"pin|auto","delay":87}],
 "defaults":{"mode":"both","speed":true,"nodes":["tokyo-1","hk-2","sg-1","us-1"]},
 "est":{"seconds":60,"mb":40}}
```
`targets[].group`: `global` 海外 (Google/YouTube/GitHub/Cloudflare/Claude/ChatGPT/Gemini/TikTok/Wikipedia) · `cn` 国内 (Bing/163/京东/淘宝/百度/QQ) · `carrier` 三大运营商 (电信/联通/移动)。
`delay` 是最近一次核心测得的毫秒数 (没有则为 null)。`est` 按当前选择估算。

### `POST /api/speedtest/start` 表单 (都可选)
`mode=direct|node|both` (默认 both) · `speed=0|1` (是否测下载速度, 默认 1; 0 = 只测延迟, 不耗流量) · `nodes=tag1,tag2` (≤ 12; 缺省用 plan.defaults.nodes) · `targets=id1,id2` (缺省全部)
→ `{"ok":true,"id":"st-…"}`; 已有测速在运行 → `E_RUNNING`; 选了节点模式但没有服务器 → `E_NO_SERVERS`。一次测试通常约 1 分钟。

### `GET /api/speedtest/status?id=` 与 `GET /api/speedtest/last`
同一个形状 (`last` 返回最近一次已结束的结果; 没有则 `{"ok":true,"none":true}`)。运行中每秒轮询, 边测边出结果:
```json
{"ok":true,"id":"st-…","state":"running|done|stopped|error","pct":42,"phase":"ip|direct|nodes|speed","msg":"正在测试 tokyo-1 …","started":1760000000,"elapsed":25,
 "routes":[{"id":"direct","name":"本地直连","kind":"direct"},{"id":"tokyo-1","name":"tokyo-1","kind":"node","role":"pin"}],
 "targets":[{"id":"google","group":"global","name":"Google"}],
 "cells":[{"t":"google","r":"direct","st":"ok|slow|limited|fail|pending|skip","ms":123,"connect":45,"ttfb":120,"http":204,"err":""}],
 "speeds":[{"r":"direct","kind":"cn","kbps":18200},{"r":"tokyo-1","kind":"global","kbps":9300}],
 "ip":{"state":"normal","direct":{…同 net/info.direct…},"routes":[…]},
 "summary":{"best":"tokyo-1","avg_ms":{"direct":88,"tokyo-1":143},"ok":{"direct":9,"tokyo-1":8},"total":{"direct":9,"tokyo-1":8}}}
```
单元格状态: `ok` ≤ 800 ms · `slow` > 800 ms · `limited` 有响应但被限制 (HTTP 403/429/451/503, 疑似 IP 受限) · `fail` 超时/解析失败/连接被重置 (`err`: `timeout|dns|reset|refused|tls`) · `pending` 还没测到 · `skip` 不适用 (如直连测海外目标是正常需要的, 但「节点」测国内目标不测)。
`speeds[].kbps` 是该线路的下载速度 (KB/s); `kind=cn` 用国内测速文件, `kind=global` 用海外测速文件。
结果同时写入本机历史 (`last`), 前端可在页面上显示「上次测速: 时间」。

### `POST /api/speedtest/stop?id=` → `{"ok":true}` (已结束的任务 → `ok:true` 无操作)

> 判定 IP 状态是启发式的 (只作参考, 不是裁决)。测速只在用户点击时运行; 查询 IP 会把用户的出口 IP 发给公共 IP 查询服务 (ipwho.is / api.ip.sb / Cloudflare), 与访问任何网站时对方看到的信息相同。

## 添加自己的服务器 (SSH 一键部署) ★ (v2.1 新增)

用户在仪表盘里填「IP / 端口 / 用户名 + 密码」或「IP / 端口 / 用户名 + 私钥」, 本机通过 SSH 连上用户的服务器, **自动检测系统与依赖** → (弹窗确认) → **自动安装依赖和服务端** → 生成节点 → **识别服务器的所有出口 IP** → 验证每个节点真的能用 → 把节点添加到本机。
支持的服务器系统: **Debian 11 / 12 / 13** 与 **Ubuntu 20.04 / 22.04 / 24.04** (x86_64 与 arm64, 需要 systemd); Debian 10 / Ubuntu 18.04 (已停止维护, 软件源可能失效) 和更新的版本尽力支持 (`support:"best_effort"` + 说明); 其它系统 → `supported:false` + 原因。
**部署脚本在云端**: 在服务器上执行的脚本 (协议选择、依赖清单、服务端版本与校验值、配置生成) 是 enana 云端「签名内容」的一部分, 登录后随「云端内容」下发到本机 (`vps/lib.sh probe.sh provision.sh redetect.sh`), **公开仓库里没有**; 没有登录 / 内容还没同步完 → `E_VPS_NO_PLAYBOOK` (前端提示「请先登录并等云端内容同步完成」)。以后换协议 / 升级服务端版本只需要云端更新内容, 本机不用升级。
安全约定: SSH 密码 / 私钥 / 口令 / sudo 密码 **只在请求体里临时传给本地辅助服务, 辅助服务写进一个 600 权限的临时文件交给后台任务, 任务一开始就读走并删除; 任务期间只存在于一个 700 权限的临时目录 (`SSH_ASKPASS` 脚本读取, 不进命令行 / 环境变量), 任务结束立即删除; 绝不写日志、不上传、不同步、不进任务结果、不返回给前端**。表单字段每次请求都要重新带上 (前端在向导期间自己保存在内存里)。
主机指纹: 用 `ssh-keyscan` 取到服务器公开的主机密钥, 指纹 (`SHA256:…`) 展示给用户确认; 之后的请求带 `hostkey`, 本机只接受**指纹一致**的密钥并用 `StrictHostKeyChecking=yes` 连接 (指纹不一致 → `E_SSH_HOSTKEY`, 不会发送任何凭据)。远端脚本经 ssh 标准输入交给 `bash -c 'eval "$(cat)"'` 执行, 服务器上不留脚本文件; 远端输出只认协议行, 其它一律丢弃、不记录。

通用凭据字段 (表单): `host` (IPv4/IPv6/域名) · `port` (默认 22) · `user` (默认 root) · `mode=password|key` · `password` (mode=password; 非 root 且需要 sudo 密码时也用作 sudo 密码) · `key` (mode=key: PEM/OpenSSH 私钥全文) · `passphrase` (私钥口令, 可选) · `sudo_password` (可选; 非 root 且 sudo 要密码时) · `hostkey` (`SHA256:…`)。参数先校验, 不合法立刻返回 `E_INVALID` + 原因 (地址 / 端口 / 用户名 (不能以 `-` 开头) / 私钥格式 / 密码不能有换行 …)。

### `POST /api/vps/probe` (通用凭据 + 可选 `hostkey` + 可选 `confirm_hostkey=1`) → `{"ok":true,"job":"…"}`
只读检测, 不改动服务器。任务步骤: `连接服务器` → `检测系统与环境` → `整理结果`。
- 运行时 `job.result.connection` 为 `{"stage":"hostkey|ssh|inspect|retry","attempt":1,"max_attempts":3,"elapsed":2,"timeout":45}`。取得远端脚本输出后才显示 SSH 已连接; 进度不冒充连接成功。主机指纹阶段最多 20 秒, 每次 SSH 检测最多 45 秒, 临时连接失败最多 3 次尝试。认证、密钥、指纹或远端脚本错误不自动重试; 失败结果附 `attempt` / `max_attempts`。任务入口不可执行返回 `E_JOB_LAUNCH`, 不会永久停在准备中。
- **推荐流程 (先确认指纹再登录)**: 第一次带 `confirm_hostkey=1` 且不带 `hostkey` → 任务**只取指纹, 不用密码 / 私钥登录**, 完成时 `job.result = {"host","port","hostkey":"SHA256:…","need_confirm":true}`; 前端弹窗让用户确认指纹 (可以和服务器商面板 / `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` 对照), 确认后带着 `hostkey` 再调一次探测。
- 不带 `confirm_hostkey` 且不带 `hostkey` (首次信任): 以扫描到的密钥为准继续探测, 结果里返回看到的 `hostkey` 供之后固定; 如果本机已保存过这个 host:port 而指纹不同 → `hostkey_changed:true` (前端要醒目提示)。
任务完成时 `job.result` 为:
```json
{"host":"1.2.3.4","port":22,"user":"root","hostkey":"SHA256:abc…","hostkey_changed":false,
 "os":{"id":"debian","version":"12","codename":"bookworm","pretty":"Debian GNU/Linux 12 (bookworm)"},"arch":"amd64",
 "supported":true,"support":"full|best_effort|no","support_note":"…(已翻译)",
 "privilege":"root|sudo_nopass|sudo_password|none","init":"systemd",
 "deps":[{"name":"curl","installed":true,"version":"7.88.1-10"},{"name":"ca-certificates","installed":false}],
 "missing":["ca-certificates"],"all_missing":false,
 "singbox":{"installed":false,"version":""},"node":{"installed":false},"deployed":false,
 "firewall":"ufw_active|ufw_inactive|firewalld_active|none","listening":[22,80],
 "ips":[{"local":"10.0.0.5","public":"1.2.3.4","v":4,"dev":"eth0"}],"ipv6":["2001:db8::5"],
 "actions":[{"id":"deps","text":"安装依赖 (apt-get): ca-certificates"},{"id":"core","text":"下载并安装服务端 sing-box 1.14.2 (SHA-256 校验) …"},{"id":"config","text":"…"},{"id":"service","text":"…"},{"id":"firewall","text":"…"}]}
```
`deps` 固定检查 `curl ca-certificates tar iproute2 gzip`; `deployed:true` = 这台服务器上已经有 enana 的部署 (可以重新识别出口 IP); `ips` = 服务器上所有可用的公网 IPv4 出口 (云厂商的内网 IP + 一对一 NAT 的会绑定源地址问外部服务得到各自的公网 IP; 同一公网 IP 只算一次, 最多 16 个; `ipv6` 只列出, 不建节点); **`actions` = 将要执行的操作清单** (按服务器当前状态生成: 已经具备的不列), 前端的「确认安装」弹窗逐条列出让用户确认。不支持的系统探测照样成功, 但 `supported:false`、`actions:[]`。
失败 (`job.state=error`, 接口里的 `code` 在 `job.result.code`, `job.msg` 是已翻译的原因): `E_SSH_NO_CLIENT` (本机没有 ssh) · `E_SSH_UNREACHABLE` (连不上 / 超时 / 被拒 / 服务器没拿到主机密钥) · `E_SSH_AUTH` (用户名 / 密码 / 私钥不对) · `E_SSH_KEY` (私钥格式不对 / 口令不对) · `E_SSH_HOSTKEY` (指纹与固定的不一致) · `E_VPS_NO_PLAYBOOK` (云端还没有下发部署脚本; 这个错误在接口里就直接返回, 不进任务)。
前端流程: (确认指纹) → 探测成功 → 弹窗展示「系统 / 依赖 / 出口 IP / 指纹」; `missing` 非空 → 问用户是否安装依赖; 要安装依赖或服务端时 → **二次弹窗** 逐条列出 `actions` 再让用户确认 → 调 provision。

### `POST /api/vps/cancel` 表单 `id=vps-probe-…` → `{"ok":true,"requested":true}`
仅接受只读检测任务, 其它任务或非法编号返回 `E_INVALID`, 不存在返回 `E_NOT_FOUND`。请求成功表示取消已提交, 前端仍等待任务结束; worker 停止该任务创建的 SSH / keyscan 子进程并清除临时凭据, 最终结果为 `E_CANCELLED`。尚未启动或已失去 worker 的检测立即结束。已结束任务可重复调用, 不改动结果。部署 / 重新识别任务涉及远端变更, 不提供这个取消接口或自动重试。

### `POST /api/vps/provision` (通用凭据 + `hostkey` 必填 + `name` + `role=pin|auto` (默认 pin) + `install_deps=0|1` + `save=0|1`★ (同 `servers/import`)) → `{"ok":true,"job":"…"}`
任务步骤 (9 步): `连接服务器` → `检测系统与环境` → `安装依赖` (apt-get: curl, ca-certificates, tar, iproute2, gzip; 只在 `install_deps=1` 时, 否则缺依赖 → `E_VPS_DEPS`) → `安装服务端` (sing-box, 固定版本 + SHA-256 校验, 装到 `/usr/local/bin/enana-sing-box`, 不覆盖用户已有的 sing-box) → `生成配置与密钥` (VLESS + Reality, 无需域名; 每个公网出口 IP 一个入站, 出口 IP = 入站 IP; 密钥 / 端口 / 伪装域名保存在服务器 `/etc/enana/state.json`, **重复部署沿用它们, 已有节点不会失效**) → `开放端口并启动` (专用系统用户 + systemd 服务 `enana-singbox`, 开机自启; ufw 活跃时放行端口; 云厂商安全组需用户自己放行) → `验证连通` (本机起一个**临时核心**, 逐个节点真实访问一次, 对比出口 IP; 全部不通 → `E_VPS_VERIFY` + 提示放行 `端口/tcp`) → `识别出口 IP` → `保存到本机` (走和导入服务器一样的事务: 校验 → 应用 → 失败自动回滚)。
权限: root 直接执行; 非 root 用 `sudo -n` (免密) 或 `sudo -S` (密码经标准输入传递, 不进命令行), 没有 sudo → `E_VPS_PRIVILEGE` (sudo 密码不对也是)。系统 / 架构不支持 → `E_VPS_UNSUPPORTED` (不改动服务器); 没有 systemd / apt-get 同理。服务端启动失败 → `E_VPS_VERIFY` (带最近的日志片段)。
完成时 `job.result` (节点 tag 规则: `<name>-<出口公网 IP>`, `name` 默认 `my-vps-<host>`; 同一台服务器的多个出口 IP 各一个节点): `{"nodes":[{"tag":"My-VPS-1.2.3.4","server":"1.2.3.4","port":443,"type":"vless","egress":"1.2.3.4"}],"ips":["1.2.3.4"],"vps":"v-1a2b3c"}`; `egress` 是验证时从这个节点出去实际看到的 IP。节点已写入本机服务器列表并生效。同一 host:port 再部署 = 更新同一条记录 (`vps` 编号不变)。
### `GET /api/vps` → `{"ok":true,"vps":[{"id":"v-1a2b3c","name":"My-VPS","host":"1.2.3.4","ssh_port":22,"user":"root","os":"Debian GNU/Linux 12 (bookworm)","hostkey":"SHA256:…","ips":["1.2.3.4"],"nodes":["My-VPS-1.2.3.4"],"updated":1760000000}]}` (本机保存的服务器记录, **不含任何密码 / 私钥**)
### `POST /api/vps/forget` 表单 `id` → `{ok}` (只删除这条记录, 不删节点; 编号无效 → 被拒, 找不到 → `E_NOT_FOUND`)
### `POST /api/vps/redetect` (通用凭据 + `id`) → `{ok,job}`
重新识别服务器的出口 IP (比如云厂商给机器加了一个 IP): **主机 / 指纹以本机保存的记录为准** (固定校验, 指纹变了 → `E_SSH_HOSTKEY`), 前端只需要重新带上凭据。服务器上更新配置并重启服务 (IP 没变就不重启), 本机只补充「还没有的」节点 (沿用已有节点的角色), 验证通过后保存。`job.result` = `{"nodes":[…新增的],"ips":[…全部],"vps":"<id>","added":1}`; 没有新增时 `added:0` 且不改动核心配置。服务器上还没有部署 → `E_VPS_NOT_DEPLOYED`; 记录不存在 → `E_NOT_FOUND`。

## 云端同步 (端到端加密) ★ (v2.1 新增)

登录同一个 enana 账号的另一台电脑, 可以一键同步 (服务器 / 订阅 / 应用与网站策略 / DNS / 规则库选择 / 自定义解析 / 自定义测速目标 / 偏好 / 已保存的服务器记录与证书 / 语言等设置) —— 用户可以在「设置」里开关。
**端到端加密**: 数据在本机加密后才上传到 enana.cc, 服务器只存密文, 看不到服务器地址和密码。密钥 = PBKDF2-HMAC-SHA256(账号密码, 盐 `enana-sync-v1|<账号 id>`, 200000 次) 再拆成「加密口令」和「校验密钥」, **只在登录 (或改密码 / 第一次开启同步时输入密码) 时派生并保存在本机 (`sync.key`, 600), 退出账号即删除**。载荷 = base64(`ENSYNC1` ‖ AES-256-CBC(gzip(快照)) ‖ HMAC-SHA256) (先加密再 MAC, 解密先验 MAC; 加密用 `openssl enc`, 格式在 LibreSSL 与 OpenSSL 3 之间互通)。快照内容与 `GET /api/export` 相同 (白名单里的文件; **SSH 密码 / 私钥永远不同步**; 每台电脑独立的东西 —— 代理总开关、端口、开机自启、令牌 —— 也不同步)。
在网站上 / 别的电脑上改了密码之后, 新密码派生的密钥解不开旧密文: 拉取返回 `E_SYNC_KEY` → 前端让用户输入「旧密码」(`old_password`) 重试, 成功后会用现在的密钥重新加密上传, 以后就不需要旧密码了。云端被篡改 / 损坏的内容 MAC 校验不过, 同样返回 `E_SYNC_KEY` (无法区分「密钥不对」和「被改动」), 内容格式不对返回 `E_INVALID`。

### `GET /api/sync` →
`{"ok":true,"enabled":false,"auto":false,"has_key":true,"account":"name@example.com","remote":{"exists":true,"version":7,"updated":1760000000,"size":2048,"device":"MacBook-Pro"},"local":{"version":6,"dirty":true},"conflict":false,"last_pull":0,"last_push":1760000000,"online":true}`
`remote`: 云端快照信息 (连不上时是 `null`; 云端没有数据时是 `{"exists":false}`; 结果缓存 20 秒); `local.version` = 本机内容所基于的云端版本; `local.dirty`: 本机有还没上传的改动 (从没同步过且本机已经有自己的配置时也是 true); `has_key`: 本机有同步密钥 (没有 → 退出账号后重新登录一次, 或开启时输入密码); `conflict`: 自动同步发现两边都改了 (或这台电脑从没同步过但已经有自己的配置而云端有数据), 没有自动覆盖, 让用户选; `online=false`: 连不上 enana.cc (按钮要给出原因, 不要做成死按钮)。
### `POST /api/sync/settings` 表单 `enabled=0|1` `auto=0|1` (至少给一个) `password` (可选: 第一次开启时本机还没有同步密钥 → 用登录密码派生; 没给 → `E_SYNC_KEY`, 密码不对 → `E_BAD_CREDENTIALS`/`E_LOCKED`) → `{ok}` (关闭同步时自动同步一起关, 不会删除云端数据; 云端数据在「设置 → 同步」里清除)
### `POST /api/sync/push` 表单 `force=0|1` → `{ok,job}` 加密并上传 (任务步骤: 生成快照 / 加密 / 上传)
云端比本机新时 (版本不同) **立刻**返回 `E_SYNC_CONFLICT` + `remote:{version,updated,device}` (不进任务), 前端让用户选「用云端覆盖本机」(`pull` `mode=replace`) 或「用本机覆盖云端」(`push` `force=1`)。任务里发现冲突 (别处刚好上传) → 任务 `error`, `result:{"code":"E_SYNC_CONFLICT","version":N}`。没开启同步 → `E_INVALID`。
### `POST /api/sync/pull` 表单 `mode=replace|merge` (默认 replace) `old_password` (可选) → `{ok,job}`
`replace`: 快照里没有的文件视为「空」, 本机对应的文件被删除 (服务器 / 订阅 / 解析 … 以云端为准); `merge`: 服务器按节点名、订阅按名称取并集 (同名的保留本机的), 其它以云端为准。**下载 + 解密在接口里做完** (失败立刻返回: `E_SYNC_KEY` / `E_NOT_FOUND` 云端没有数据 / `E_ACCOUNT_UNREACHABLE` / `E_INVALID`), 通过后「应用」才进任务 (走事务: 备份 → 应用 → 生成配置 → 校验 → 重启, 失败自动回滚)。只应用白名单里的文件和合法内容 (坏的节点行、保留名、非法文件名 / 设置值都会丢弃)。偏好变了 → `state.prefs_version` 变化。
### `POST /api/sync/preview` 表单 `old_password` (可选) → `{"ok":true,"summary":{"servers":2,"subs":1,"hosts":0,"site_domains":0,"custom_apps":0,"speed_targets":0,"custom_rulesets":0,"vps":0,"certs":0,"prefs":true,"created":1760000000,"device":"MacBook","version":"2.1.0"},"remote":{"version":7}}`
下载并解密云端快照, **只返回摘要, 不改动本机** (云端没有数据 → `E_NOT_FOUND`; 其余错误同 `pull`)。新电脑第一次登录成功后, 如果 `GET /api/sync` 的 `remote.exists` 且本机没有任何服务器, 前端应弹窗「检测到云端配置 (N 台服务器, 更新于 …), 是否一键同步到这台电脑?」(N 来自 `preview`; 用户可以选「不同步」, 之后在设置里再开)。
### `POST /api/sync/clear` (需 sudo) → `{ok}` 删除云端的同步数据 (二次确认); 本机版本归零。
### 同步清单 (「保存到云端」) 与登录后自动取回
- **哪些服务器同步**: 只有添加时勾选「保存到云端」的 (`servers/import` / `sub/save` / `vps/provision` 的 `save=1`) 才进入本机的 `servers.sync` / `subs.sync` 清单 (一行一个名称, 只在本机, 不同步); 快照 / 同步只带清单里的服务器 (和它们所属的订阅), 老版本添加的、没勾选过的只在本机, 不会被连带上传。在设置里**明确打开**云端同步时, 现有的全部服务器和订阅都会加入清单 (和以前「全部同步」一致)。导出备份 (`GET /api/export`) 不受清单限制, 始终包含全部。
- **`GET /api/sync` 的 `decided`★**: 用户有没有做过选择 (`ENABLED` 有值)。没做过选择时, 第一次勾选「保存到云端」会自动打开同步 (`enabled` + `auto`) 并让下一次定时任务立刻上传; 明确关闭过 (`decided:true, enabled:false`) 的不会被自动打开, 前端把「保存到云端」默认设为不勾选并提示「勾选会重新开启」。
- **登录后自动取回**: 登录成功后 (在线) 辅助服务启动后台任务 `sync-login`: 云端有这个账号的快照就**合并**进本机 (本机已有的保留, 不覆盖; 取回的服务器记入清单继续同步); 在设置里明确关闭过同步的、连不上云端的、解不开的 (改过密码) 都静默跳过, 由设置里的同步卡片处理。
### 自动同步
`auto=1` 时, 本机每分钟的定时任务里每 10 分钟检查一次: 本机有改动且云端没变 → 自动上传; 云端有新版本且本机没改动 → 自动拉取 (替换); 两边都变了 → 只标记 `conflict:true`, 不动任何数据。

## 偏好设置 (界面习惯, 可跨设备同步) ★

仪表盘把用户的界面习惯 (表格每页条数、侧栏是否收起、主题、上次打开的设置标签页、测速选择、是否收起欢迎卡片、IP 是否隐藏 …) 存在本机的 `prefs.json`, 而不只是浏览器 localStorage: 这样换浏览器不丢, 并且在用户打开「云端同步」后, 会和其它配置一起 (端到端加密) 同步到其它电脑, 新电脑登录后自动沿用。
- `GET /api/prefs` → `{"ok":true,"prefs":{…任意 JSON 对象…},"version":7,"updated":1760000000}` (没有时 `prefs:{}`, `version:0`)
- `POST /api/prefs` 正文是 JSON 对象文本 (≤ 32 KB; 键名建议分命名空间如 `table.sites.pageSize`、`ui.sidebar.collapsed`) → `{"ok":true,"version":8}`。整体替换 (前端自己合并); 本机每次写入 `version` +1。
- 校验: 必须是 JSON 对象 (数组 / 标量 → `E_INVALID`), ≤ 32 KB (超过 → `E_INVALID`), 最多 12 层嵌套; 保存时按键排序规范化。
- `GET /api/state` 里带 `prefs_version`: 前端发现它变了 (同步拉取了别的设备的偏好) 就重新 `GET /api/prefs` 并应用。前端本地做缓存 (localStorage) 以便首屏不闪, 但以 `GET /api/prefs` 为准; 写入要做 500 ms 防抖。

## 网站规则: 查看 / 添加 / 修改域名, 一键重置 ★

「网站」页每个条目的域名列表 (系统自带的 + 用户自己改的) 用弹窗 (不是行内展开) 显示, 一行一个域名, 可添加 / 修改 / 删除, 并可一键「重置为系统默认」。用户的改动存在本机 (`site-domains.tsv`), 不会被云端内容更新覆盖; 重置 = 删除该条目的全部用户改动, 回到系统 (云端内容) 当前的列表。
- `GET /api/sites/domains?id=<条目 id>` → `{"ok":true,"id":"claude","name":"Claude","modified":true,"system":["claude.ai","anthropic.com"],"domains":[{"domain":"claude.ai","source":"system"},{"domain":"x.example","source":"added"}],"removed":["claude.com"],"rulesets":["geosite-openai"],"cidrs":0,"policy":"pin"}`
  - `domains` = 当前生效的列表 (一行一个, `source`: `system` 系统自带 / `added` 用户添加); `removed` = 用户从系统列表里删掉的; `rulesets` / `cidrs` 是社区规则集与 IP 段 (只读, 弹窗里单独一块说明「由社区规则集维护, 不能逐条编辑」)。
- `POST /api/sites/domains` 表单 `id` `action=add|remove|update|restore` + `domain` (+ `new` 仅 update 用: 把 `domain` 改成 `new`) → `{"ok":true,"job":"…"}` (重新生成配置, 热生效)。`remove` 系统域名 = 记为「已删除」(可 `restore` 恢复); `remove` 用户添加的域名 = 直接删除。域名校验: 小写字母/数字/连字符 + 点, 每段 ≤ 63、总长 ≤ 253, 不含通配符/空格/协议/路径; 非法 → `E_INVALID` + 原因; 重复 → `E_INVALID`。
- `POST /api/sites/domains/reset` 表单 `id` → `{"ok":true,"job":"…"}` 还原为系统默认 (前端先二次确认, 说明会丢掉这条目的所有自定义改动)。
- 目录条目 (`/enana/admin/catalog.json` 的 `entries[]`) 新增 `modified:true|false`, `domains` 为生效后的域名数组。

## 自定义软件 (应用页「添加自定义软件」) ★

自动识别不到的软件 (放在非标准位置的 .app、命令行工具、便携版程序 …) 可以手动添加, 添加前必须先**校验**它是不是对的, 并用**两步弹窗**让用户确认:
1. 第一个弹窗: 输入 **路径** (把 .app / 可执行文件拖进终端或在 Finder 里「拷贝为路径名」后粘贴) 或 **名称** (如 `Cursor`, 按名称在 /Applications、~/Applications、/opt/homebrew、/usr/local 里搜) → `POST /api/apps/inspect`。
2. 第二个弹窗: 展示校验结果 —— 图标、名称、类型 (应用 / 命令行工具)、版本、Bundle ID、路径、签名 (开发者 / Team ID / 未签名警告)、「已存在」提示 —— 让用户确认「就是这个」, 再选择策略 (跟随规则 / 固定出口 / 自动线路 / 直连, 每项一行说明), 点「添加」后再有最后一次确认。
### `POST /api/apps/inspect` 表单 `input` (路径或名称) → 
`{"ok":true,"candidates":[{"valid":true,"kind":"app|bin","name":"Cursor","bundle_id":"com.todesktop.230313mzl4w4u92","version":"0.45","path":"/Applications/Cursor.app","exec":"Cursor","signed":true,"authority":"Developer ID Application: Anysphere Inc.","team":"ABCDE12345","icon":"appicons/Cursor.png","exists":false,"matches_running":true}]}`
- 输入是路径 → 恰好一个候选; 是名称 → 最多 8 个候选让用户选。`valid:false` 时带 `reason` (已翻译): 路径不存在 / 不是应用或可执行文件 / 没有读权限 / 名称里有非法字符 / 找不到。`exists:true` = 已在应用列表里 (前端提示, 不允许重复添加)。路径只接受绝对路径, 且必须在用户可读的位置; 不会执行这个程序。
### `POST /api/apps/custom` 表单 `path` (用 inspect 返回的 path) `state=follow|pin|auto|direct` → `{ok,job}` (写入 `custom-apps.tsv` + 设置策略 + 重新生成配置, 热生效)
### `POST /api/apps/custom/delete` 表单 `name` → `{ok,job}` (只删自定义软件及其策略)
- `GET /api/apps` 的应用多两个字段: `custom:true|false`、`path` (自定义软件才有); 2.3.8 起还有 `installed` / `seen` (应用目录的创建时间 / enana 第一次识别到它的时间, epoch 秒, 0 = 不知道; 应用页的「安装时间 / 识别时间」列); 路由匹配: 应用按 `.app` 路径匹配 (`/名称.app/`), 命令行工具按可执行文件名匹配 (`process_name`)。

## 应用图标 ★

`GET /api/apps` 每个应用多一个 `icon` 字段: 本机已提取出该应用真实图标时是相对路径 (如 `"appicons/Slack-1234567.png"`, 由核心的静态目录提供, 直接 `<img src="appicons/Slack-1234567.png">`, 96×96 PNG), 提取不到时是 `""` —— 前端用现在的字母头像设计兜底 (图片加载失败 `onerror` 也回退)。图标在扫描应用后台提取 (macOS 用系统自带的 `NSWorkspace` + `sips`), 第一次扫描后几秒内陆续出现, 前端在应用页轮询到新图标后再刷新; 图标只存本机。

## 测速目标: 内置更多 + 用户可增删改 ★

内置目标扩充到 60+ 个 (海外 / 国内 / 运营商 / 开发者与云服务 …), 每个有 `default` (默认勾选)。用户可以修改、删除 (内置的是「隐藏」, 随时恢复) 和补充自己的目标, 一键还原。
- `GET /api/speedtest/targets` → `{"ok":true,"targets":[{"id":"google","group":"global","name":"Google","url":"https://www.google.com/generate_204","expect":"204","icon":"search","builtin":true,"modified":false,"hidden":false,"default":true}],"groups":["global","cn","carrier","dev","media"],"hidden":2,"custom":3}`; `hidden:true` 的内置目标也会返回 (供「已隐藏」列表里恢复); `GET /api/speedtest/plan` 的 `targets` 只含未隐藏的, 并带 `default`。
- `POST /api/speedtest/targets` 表单 `id` (空 = 新增, 自动生成) `name` `group` `url` `expect` (逗号分隔的可接受 HTTP 状态码, 默认 `200,204,301,302`) `icon` (可空) → `{"ok":true,"id":"u-ab12cd"}`。url 必须是 http/https (不含空格/引号, ≤ 300 字符); 名称 ≤ 40 字符; 修改内置目标 = 保存一份覆盖 (`modified:true`)。
- `POST /api/speedtest/targets/delete` 表单 `id` → `{ok}` (内置: 隐藏; 自定义: 直接删除; 前端先二次确认)
- `POST /api/speedtest/targets/restore` 表单 `id` → `{ok}` (取消隐藏并撤销对它的修改)
- `POST /api/speedtest/targets/reset` → `{ok}` 清除全部自定义 / 隐藏 / 修改, 回到内置默认 (二次确认)
- 内置目标 100 个, 其中 18 个 `default:true` (原来默认勾选的海外 / 国内 / 运营商); `POST /api/speedtest/start` 不给 `targets` 时测所有「未隐藏且 default」的目标。内置目标的 `id` 可以含 `_`; 自己添加的是 `u-` + 6 位十六进制。名称按字符数限制 (40 个字符, 汉字也算 1 个), 不能含 `|` `<` `>` 和控制字符; 修改只存本机 (`speedtest-custom.tsv`, 600), 升级 / 云端更新都不会覆盖。
- 用户的改动是同步快照的一部分 (`speedtest-custom.tsv`)。

## DNS 页新增 ★

在原有预设、泄漏防护、屏蔽广告、IP 策略之外, 增加几项经过验证的优化 (页面上每项都有「!」说明, 见下面的界面约定):
- **自定义解析 (hosts)**: `GET /api/dns` 的响应多一个 `hosts:[{"domain":"example.com","ip":"1.2.3.4"}]`; `POST /api/dns/hosts` 表单 `action=add|update|remove` `domain` `ip` (`new_domain` 仅 update 用; update 不给 `ip` = 沿用原来的) → `{ok,job}` (先在副本上校验, 不合法立刻 `E_INVALID` + 原因); `POST /api/dns/hosts/reset` → `{ok,job}` 清空 (二次确认)。IP 支持 IPv4 (点分十进制, 不带前导零) 和 IPv6; 域名规则同网站域名 (小写字母 / 数字 / 连字符 + 点, 不含通配符 / 协议 / 路径; 中文域名要用 `xn--`); 每个域名一条, 最多 200 条。**生效方式**: ① DNS 里多一个 `hosts` 服务器, 命中的域名直接返回你填的 IP (「测试解析」也能看到); ② 路由里对每个域名加一条 `route-options` (`override_address`), 所有连接 (直连 / 经代理, 任何代理模式) 都改连这个 IP —— 和系统 hosts 文件的效果一致。
- **DNS 服务器测速**: `POST /api/dns/bench` → `{ok,job}`, 任务结果 `job.result = {"cn":[{"id":"alidns","ms":23},{"id":"114","ms":null}],"global":[{"id":"cloudflare","ms":41}],"via":"direct|Global|PIN"}` (`ms:null` = 不通; 不含 `system` / `custom`)。逐个测 (并行会互相抢带宽): DoH = 同一条连接上第二次请求的耗时 (稳定状态下一次查询), UDP = `dig` 的 Query time, DoT = TCP 连接耗时 (≈ 网络往返)。国内预设直连测, 海外预设经「DNS 使用的线路」(`settings.via`: 自动线路 / 固定出口) 测, `via` 就是实际用的线路 (没有节点时是 `direct`)。前端在下拉里给每个预设标延迟并提示「最快: …」(可一键采用)。测速和测速页的「速度测试」共用线路选择器, 同时只能跑一个 (等不到 → 任务失败 + 提示稍后重试)。
- 预设更多: 国内 阿里 DNS (DoH / DoT) / 腾讯 DNSPod (DoH / DoT) / 114 (UDP) / 百度 (UDP); 海外 Cloudflare / Cloudflare 安全版 (拦截恶意软件) / Google / Quad9 / AdGuard / OpenDNS (全部 DoH)。预设一律用 IP 地址 (证书含 IP, 不需要先解析域名)。
- 默认就开启 (不用用户操心, 页面「!」里说明): **反向映射** (`reverse_mapping`: 日志 / 连接列表里直接用 IP 访问的连接也能显示域名)、**直连的网站用国内 DNS 解析** (直连出站的域名解析就用国内 DNS: 苹果 / 微软等在国内有 CDN 的域名会解析到离你最近的节点, 速度更快)、**经代理访问的网站由代理服务器解析** (防污染 / 防泄漏)。核心 1.14 起各 DNS 服务器的缓存互相独立, 不需要也不应该再写 `independent_cache` (已弃用)。
- `GET /api/dns` 的 `pipeline` 相应多出这些行 (`id`: `hosts` (有自定义解析时) · `ads` (开启屏蔽广告时) · `direct` · `cn` · `proxy` · `global`), 前端的「解析流程」图要体现。

## 界面约定 (v2.1 补充, 前端实现)
1. **设置页用标签页 (tabs)**: 常规 / 代理 / 同步 / 日志 / 更新 / 账号与设备 / 关于 …, 切换标签只显示该标签的功能; 记住上次打开的标签 (prefs)。
2. **「查看 / 详情」类功能一律用弹窗**, 不在页面里行内展开 (域名列表、连接详情、日志详情、节点详情 …); 弹窗里能编辑的要有「重置」二次确认。
3. **每个功能旁有一个常显的「!」说明图标** (圆圈里的感叹号, 中性蓝灰色, 不是警告色): 点击弹出小面板, 写清「这是什么 / 怎么用 / 注意事项」, 键盘可达、可关闭; 文案放 i18n。
4. **表格默认分页** (默认每页 10 / 20 / 50 可选), 页大小与当前页偏好记在 prefs 里, 换设备同步。
5. **欢迎 / 新手引导卡片**默认半隐藏 (只露出一个小标签/进度环), 用户点击才展开, 关闭状态记在 prefs 里。

## Enhanced/TUN (macOS / Windows)

`POST /api/network-mode` 表单 `mode=system|tun` → `{ok:true,job}`。设置是本机独有, 不进入跨设备同步; 升级缺省 `system`。`GET /api/state` 与 `/api/settings` 的 `proxy` 增加 `network_mode`、`tun_ready`。

TUN 使用管理员授权后的规则快照。此模式下 `/api/override`、`/api/apps/adopt`、`/api/apps/scan`、`/api/sites/auto/clear` 返回异步 `{ok:true,job}`, 前端必须等 job 完成再显示成功, 取消授权时事务撤销。System Proxy 下这些接口沿用立即响应/文件热加载。自动识别网站也必须先应用快照, 再验证实际连接; 不能把用户目录文件已更改当成 root 核心规则已生效。

访问记录新增 `capture:"mixed|tun"` (老记录可能为空)。

Windows 生命周期和安装验收见 [WINDOWS.md](WINDOWS.md)。`platform.os=windows`; 使用同一份 API 和仪表盘, 系统代理/TUN/应用 EXE 由平台适配器处理。
