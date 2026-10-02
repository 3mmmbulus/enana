# Changelog / 更新日志

## 2.1.0 (2026-10-02)

### 中文
- 新品牌 **enana**: 一条命令安装, 终端只装环境, 其余全部在浏览器仪表盘里完成。
- 仪表盘登录: 使用 enana 账号 (邮箱 + 密码), 可在仪表盘里直接注册; 同一账号同一平台最多同时在线 2 台设备, 可在登录时或「设置 → 账号」里下线其它设备。
- 退出账号会自动关闭代理; 代理总开关 + 两种模式 (自动模式 / 全局代理), 默认关闭, 登录后手动开启。
- 应用与网站按需分流: 新装应用默认关闭, 自动识别并显示图标; 支持添加自定义软件 (先校验再确认); 网站域名可在弹窗里查看 / 添加 / 修改, 并一键重置。
- 规则库、DNS (预设 / 自定义解析 / 测速)、测速 (本地直连与多节点, 可自定义目标)、流量统计 (今日 / 3 天 / 7 天 / 1 个月 / 3 个月, 本地保留 3 个月)。
- 添加自己的服务器: 密码或密钥 SSH 登录, 自动检测并安装依赖 (Debian / Ubuntu), 识别出口 IP; 订阅 / 分享链接 / Clash / sing-box 配置自动识别。
- 云端同步 (端到端加密)、敏感操作需再次输入密码、日志保留可设 1–365 天、中英文界面、自适应布局、检查更新与新版本提示。
- 精选内容 (服务目录、规则库清单、应用推荐) 登录后由云端下发并验签缓存。

### English
- New brand **enana**: one-command install; the terminal only sets up the environment, everything else lives in the browser dashboard.
- Dashboard sign-in with an enana account (email + password), with in-dashboard sign-up; at most 2 devices online per platform per account, with device kick-off at sign-in and in Settings → Account.
- Signing out turns the proxy off; master proxy switch plus two modes (Auto / Global proxy), off by default and turned on manually after sign-in.
- Per-app and per-site routing: new apps default to off, detected automatically with icons; custom software (validated before adding); site domains viewable / editable in a dialog with one-click reset.
- Rule library, DNS (presets / custom hosts / benchmark), speed tests (direct and multi-node, custom targets), traffic statistics (today / 3 d / 7 d / 1 mo / 3 mo, kept locally for 3 months).
- Add your own server: SSH by password or key, dependencies detected and installed (Debian / Ubuntu), egress IPs detected; subscriptions / share links / Clash / sing-box configs recognised automatically.
- End-to-end encrypted cloud sync, password re-entry for sensitive actions, log retention 1–365 days, Chinese / English UI, responsive layout, update checks with in-app notice.
- Curated content (service catalog, rule-library list, app recommendations) is delivered from the cloud after sign-in, signature-verified and cached.
