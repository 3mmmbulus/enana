# enana 云端接口 (客户端 ↔ api.enana.cc)

本地辅助服务 (`lib/*.sh`) 与 enana 云端之间的契约。账号服务的通用实现见 `server/`; 数据库、邮件和支付凭据仍是服务器私有配置。本文描述客户端用到的接口, 方便审计「客户端到底向云端发送了什么」。
**客户端从不向云端发送服务器地址、订阅链接、代理密码、SSH 凭据、访问记录。** 云端只知道: 账号 (邮箱 + 密码哈希)、设备信息 (见下)、登录会话、(用户自己打开同步时) 一份在本机加密后的配置密文。

基地址 `https://api.enana.cc` (官网提供静态首页与邮箱验证页, 验证页调用受限的邮箱确认接口)。JSON, UTF-8。除登录 / 注册 / 邮箱确认外都要带:
`Authorization: Bearer <token>` 与 `X-Enana-Session: <session id>`。时间一律是 Unix 秒 (整数)。平台 `platform` 取值 `macos | windows | linux`。

## 数据表 (PocketBase 集合, 命名按领域, 方便以后扩展)
| 集合 | 用途 |
|---|---|
| `users` | 账号 (PocketBase 内置认证集合: 邮箱 + 密码哈希) |
| `plans` | 套餐定义: `code`(free…) · `title` · `max_devices_per_platform`(默认 2) · `features`(json) · `active` |
| `subscriptions` | 账号与套餐的关系: `user` · `plan` · `status`(active/expired/cancelled) · `expires_at` · `source` |
| `devices` | 登录过的设备: `user` · `device_uid`(客户端生成的随机 UUID) · `name` · `platform` · `os_version` · `arch` · `app_version` · `last_seen_at` · `last_ip_masked` |
| `device_sessions` | 登录会话: `user` · `device` · `last_heartbeat_at` · `expires_at` · `revoked_at` · `revoked_reason`(logout/kicked/limit/expired/admin) · `revoked_by_device` |
| `sync_snapshots` | 端到端加密的配置快照: `user` · `version` · `payload`(密文, 云端看不到明文) · `size` · `source_device` |
| `audit_events` | 安全审计: `user` · `device` · `type`(register/login/login_failed/logout/kick/limit_blocked/sync_push/sync_pull …) · `detail` · `ip_masked` |
所有集合只允许通过上面的接口访问 (规则: 只能访问自己的记录), 管理员通过 SSH 隧道进入后台。

Pro 订单、余额、到账记录与验证接口见 [BILLING_API.md](BILLING_API.md)。共享 Mac/Windows 客户端已提供套餐购买界面与官方线路下发；正式收款关闭，仍须真实邮件及到账验收。节点权限和主动共享见 [OFFICIAL_NODES.md](OFFICIAL_NODES.md)。

## 设备数量限制 (服务端强制)
同一个账号, **同一平台最多同时在线 2 台设备** (macOS 2 台 + Windows 2 台; 上限来自账号套餐 `plans.max_devices_per_platform`)。
「在线」= 会话未被撤销、未过期, 且 10 分钟内有过心跳。第 3 台登录时被拒绝并返回在线设备列表, 用户可以在登录界面点某台设备「下线」: 被下线的设备在下一次心跳 (≤ 2 分钟) 收到 `session_revoked` 后自动退出登录并关闭代理; 当前设备随即自动完成登录。

## 接口
### `POST /api/enana/v1/auth/login` (公开)
```json
{"email":"a@b.com","password":"…","device":{"uid":"6f1c…","name":"我的 MacBook Pro","platform":"macos","os":"14.5","arch":"arm64","app":"2.1.0"},"kick_device_uid":""}
```
- 200: `{"token":"<jwt>","user":{"id":"…","email":"a@b.com"},"session":{"id":"…","expires_at":1763000000},"plan":{"code":"free","max_devices_per_platform":2},"heartbeat_secs":120}`
- 409 设备已满: `{"code":"device_limit","platform":"macos","limit":2,"devices":[{"uid":"…","name":"…","platform":"macos","os":"14.5","last_seen":1760000000,"online":true,"ip_hint":"203.0.*.*"}]}`
- 400 `{"code":"bad_credentials"}` · 403 `{"code":"account_disabled"}` · 429 限流
- `kick_device_uid` 非空: 先撤销该设备 (必须是同账号、同平台) 的会话再登录; 仍然超限 → 再次 409。
### `POST /api/collections/users/records` 注册 (PocketBase 原生接口, `{"email","password","passwordConfirm"}`); 服务端自动给新账号创建 free 套餐。
### `POST /api/enana/v1/session/heartbeat` → `{"ok":true,"token":"<刷新后的 jwt>","expires_at":…}`; 会话被撤销/过期 → 401 `{"code":"session_revoked","reason":"kicked|logout|limit|expired"}`。客户端每 ~120 秒一次 (launchd 定时任务), 连续联网失败超过宽限期 (默认 7 天) 后本机自动退出登录。
### `POST /api/enana/v1/session/logout` → `{"ok":true}` 立即释放这个设备名额。
### `GET /api/enana/v1/devices` → `{"limit":2,"platform":"macos","devices":[{…同上, 另有 "app":"2.1.0","current":true}]}` (列出本账号全部设备, 用于「设置 → 我的设备」)
### `POST /api/enana/v1/devices/kick` `{"device_uid":"…"}` → `{"ok":true}` (不能下线自己; 自己用 logout)
### `GET /api/enana/v1/session/check` → 204 / 401 (供网关 auth_request 校验 `/v1/` 下的签名内容)
### `POST /api/enana/v1/account/password` `{"old_password":"…","new_password":"…"}`
→ 200 `{"ok":true,"token":"<新 jwt>","session":{"id":"…","expires_at":…}}` (当前设备保持登录, 旧令牌立即作废; 账号下**其它所有会话**被撤销, `reason=password_changed`) · 400 `bad_credentials` (旧密码不对) / `weak_password` (新密码不是 8–71 个字符 / 超过 72 字节 / 与旧密码相同) · 429 (与登录共用失败计数)。密码只在请求体里 (经 TLS), 本机从不落盘。
### `GET /api/enana/v1/plan` → `{"plan":{"code":"free","title":"…","max_devices_per_platform":2,"features":[]},"expires_at":null}`
### 同步 (端到端加密; 云端只存密文)
- `GET /api/enana/v1/sync/snapshot[?payload=1]` → `{"exists":true,"version":7,"updated":1760000000,"size":2048,"device":"MacBook","payload":"<base64, 仅 payload=1>"}`
- `PUT /api/enana/v1/sync/snapshot` `{"base_version":6,"payload":"<base64>","size":2048}` → `{"version":7}` 或 409 `{"code":"conflict","version":8}`
- `DELETE /api/enana/v1/sync/snapshot` → `{"ok":true}`
### 签名内容 (登录后下发的精选数据与服务器部署脚本)
`GET /v1/manifest.json` → `{"channel":"stable","bundles":{"content":{"version":"2026.10.02.1","url":"/v1/content-2026.10.02.1.tar.gz","sha256":"…","sig":"/v1/content-2026.10.02.1.sig","size":123456,"min_client":"2.1.0"}}}`
每个包用 ECDSA P-256 / SHA-256 签名, 客户端用内置公钥 (`data/cloud-pub.pem`) 验签后才使用; 验签失败 → 丢弃并保留旧版本。
内容包 (`content-<seq>.tar.gz`) 里只允许白名单里的文件: `services.conf groups.conf rulesets.conf apps.conf SEQ VERSION i18n/<语言>-data.tsv` 与 **`vps/{lib,probe,provision,redetect}.sh`** (SSH 一键部署在服务器上执行的脚本: 协议选择、依赖清单、服务端版本与校验值、配置生成)。客户端的检查顺序: 验证清单签名 → 序号不能比本机已有的小 (防回滚) → sha256 / 大小 → 解包前检查全部文件名 → 逐个文件的格式 → 原子替换。部署脚本只在本机从云端取到并验签之后才会使用, 公开仓库里没有。
