# Changelog / 更新日志

## 2.1.2 (2026-10-03)

### 中文
- **修复: 「服务器 → 添加 / 导入服务器 → 密码 / 密钥」(SSH 一键部署) 面板打不开** —— 浏览器控制台报 `b[k].setErr is not a function`, 面板里只剩一个输入框; 2.1.0 / 2.1.1 都有这个问题, 现在整条部署流程 (检测 → 确认指纹 → 安装依赖 → 部署 → 完成) 在浏览器里走通了。
- 修复: 每次打开后台控制台里都有的两条红色报错 —— `favicon.ico` 403 (现在有标签页图标, 后台也不再对 `/favicon.ico` 返回 403) 和 `api.ipify.org` 连接被重置 (概述页的出口 IP 改由本机辅助服务查询, 浏览器不再自己去访问第三方网站; 手动刷新会让辅助服务重新查一次)。
- 包含 2.1.1 的全部更新: 浏览器默认「开」(并修好升级前被误设成「关」的浏览器)、日志系统重做 (三类日志独立开关 / 一个导出入口 / `enana diag`)、应用识别更完整、固定出口可指定、可选的「自动识别打不开的网站」、界面改进 —— 详见下面 2.1.1 一节。

### English
- **Fix: the “Servers → Add / import servers → Password / Key” (one-click SSH deployment) panel would not open** — the browser console showed `b[k].setErr is not a function` and only one input was left in the panel; 2.1.0 and 2.1.1 were affected. The whole deployment flow (probe → confirm fingerprint → install dependencies → deploy → done) now works in the browser.
- Fix: two red errors in the browser console every time the dashboard opened — `favicon.ico` 403 (the dashboard now has a tab icon and no longer answers `/favicon.ico` with 403) and `api.ipify.org` connection reset (the Overview exit IPs are now looked up by the local helper; the browser no longer contacts third-party sites on its own, and a manual refresh makes the helper query again).
- Includes everything from 2.1.1: browsers default to “on” (and browsers wrongly set to “off” before the upgrade are restored), rebuilt logging (three independent log switches / one export entry / `enana diag`), more complete app detection, selectable fixed exits, optional auto-detect of unreachable sites, UI improvements — see the 2.1.1 section below.

## 2.1.1 (2026-10-03)

### 中文
- **修复: 新装的浏览器会被默认设成「关」(直连)**, 导致浏览器里的网站全都不走代理、打不开 —— 现在浏览器 (能打开网页链接的应用) 默认「开」(跟随规则), 升级时会自动把之前被误设成「关」、而你还没处理过的浏览器改回来。
- 应用识别更完整: 扫描系统自带应用 (含「终端」等 Utilities 子目录)、应用目录里的子文件夹、Spotlight 能找到的应用; 升级后第一次扫描不会把已有的应用当成「新应用」; 「应用」导航上的新应用提示, 打开该页面后即消失。
- 日志系统重做: 操作记录 / 网站访问 / 代理日志三类, 各有独立开关 (设置 → 日志); 保留时长 12 小时 – 30 天 (默认 3 天), 按小时清理。
- 网站访问记录: 一条连接一行, 看得到应用、出口、**为什么直连** (总开关关闭 / 局域网 / 你设为直连的网站 / 你设为「关」的应用 / 国内规则 / 策略)、失败类型和 DNS 解析结果; 支持筛选 / 概览 / 搜索 / 实时; 代理总开关关闭时同样记录。
- 所有会改变路由的操作都有操作记录 (谁、什么时候、从什么改成什么), 包括网站页直接切换出口和断开连接。
- 导出只有一个入口: 日志页「导出」→ 勾选操作记录 / 网站访问 / 代理日志 / 环境快照 + 时间范围, 得到一份自描述的诊断文件 (环境、脱敏后的配置与策略、实时自检、日志); 终端里用 `enana diag`; 格式见 docs/DIAGNOSTICS.md。
- 固定出口有 2 个以上时, 每个应用 / 网站可以指定走哪一个固定出口, 或「在固定出口里自动选」。
- 新功能 (设置 → 自动识别, 默认关闭): 打不开的网站自动加入代理 (先经代理验证), 在「网站」页标记为「自动识别」, 可一键撤销。
- 界面: 「网站」页改为顶部标签 + 左侧分组导航; 测速节点改成表格; 概述里的下载测速保留最近 3 次; 「连接」页显示实时数据 (核心停止后不再保留旧数据); 日志页的按钮不再被截断。

### English
- **Fix: newly installed browsers were set to “off” (direct) by default**, so every site in the browser bypassed the proxy and failed to load — browsers (apps that can open web links) now default to “on” (follow the rules), and the upgrade restores browsers that were wrongly set to “off” and that you have not touched yet.
- More complete app detection: system apps (including the “Terminal” in Utilities), sub-folders of the Applications folders and apps Spotlight knows about; the first scan after an upgrade no longer treats existing apps as “new”; the new-app badge on the Apps entry disappears once you open the page.
- Logging rebuilt: operations / site access / proxy log, each with its own switch (Settings → Logs); retention 12 hours – 30 days (3 days by default), cleaned up by the hour.
- Site-access records: one line per connection with the app, the exit, **why it went direct** (master switch off / LAN / a site you set to direct / an app you set to “off” / China rules / policy), the failure type and the DNS answer; filters, summary, search and live view; recorded while the master switch is off, too.
- Every action that changes routing is recorded (who, when, from what to what), including switching a site’s exit on the Sites page and disconnecting connections.
- A single export entry: Logs → Export → tick operations / site access / proxy log / environment snapshot and a time range to get one self-describing diagnostics file (environment, redacted config and policy, live probes, logs); `enana diag` in the terminal; format in docs/DIAGNOSTICS.md.
- With two or more fixed exits, each app / site can use a specific fixed exit, or “pick one of the fixed exits automatically”.
- New (Settings → Auto-detect, off by default): sites that fail to load are added to the proxy automatically (verified through the proxy first), marked “auto-detected” on the Sites page and undoable in one click.
- UI: the Sites page now has top tabs plus a left group navigation; speed-test nodes are a table; the Overview keeps the last 3 download speed tests; the Connections page shows live data (no stale data after the core stops); buttons on the Logs page are no longer clipped.

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
- 后台地址固定为 `http://127.0.0.1:<端口>/enana/admin/` (页面路由 `/enana/admin/apps` 等), 由本地辅助服务直接提供; 默认端口被占用时安装器自动换一个随机的空闲端口并在安装结束时打印后台地址。
- 登录 / 注册是两个独立的整页 (`…/login`、`…/register`), 语言切换在右上角; 页面底部有 enana 官网链接和版权, 仪表盘底部固定一条同样的链接栏; 刷新时不再闪一下仪表盘。
- 添加服务器 (手动 / 导入 / SSH 部署) 有「保存到云端」勾选 (默认勾选), 勾选的才进入端到端加密同步, 登录同一账号后自动取回。
- 快捷命令 `enana` 装完马上可用 (优先放进 PATH 里的可写目录); 安装命令支持没有 curl 的系统 (wget), 并给出更清楚的系统 / 工具缺失提示。
- 应用页有表头 (软件名 / 路径 / 状态 / 模式 / 操作), 标签选中色更深, 测速的节点可以全选 / 全不选, 点「有新版本」直接弹出更新窗口。

### English
- New brand **enana**: one-command install; the terminal only sets up the environment, everything else lives in the browser dashboard.
- Dashboard sign-in with an enana account (email + password), with in-dashboard sign-up; at most 2 devices online per platform per account, with device kick-off at sign-in and in Settings → Account.
- Signing out turns the proxy off; master proxy switch plus two modes (Auto / Global proxy), off by default and turned on manually after sign-in.
- Per-app and per-site routing: new apps default to off, detected automatically with icons; custom software (validated before adding); site domains viewable / editable in a dialog with one-click reset.
- Rule library, DNS (presets / custom hosts / benchmark), speed tests (direct and multi-node, custom targets), traffic statistics (today / 3 d / 7 d / 1 mo / 3 mo, kept locally for 3 months).
- Add your own server: SSH by password or key, dependencies detected and installed (Debian / Ubuntu), egress IPs detected; subscriptions / share links / Clash / sing-box configs recognised automatically.
- End-to-end encrypted cloud sync, password re-entry for sensitive actions, log retention 1–365 days, Chinese / English UI, responsive layout, update checks with in-app notice.
- Curated content (service catalog, rule-library list, app recommendations) is delivered from the cloud after sign-in, signature-verified and cached.
- The dashboard lives at `http://127.0.0.1:<port>/enana/admin/` (page routes such as `/enana/admin/apps`), served directly by the local helper; if the default port is taken the installer picks a free random one and prints the dashboard address when it finishes.
- Sign-in and registration are two separate full pages (`…/login`, `…/register`) with the language switch at the top right; the pages carry a link to the enana website and a copyright line, the dashboard has the same link in a bar fixed at the bottom, and a refresh no longer flashes the dashboard.
- Adding a server (manual / import / SSH deployment) has a “Save to the cloud” checkbox (on by default); only checked servers join the end-to-end encrypted sync, and they are restored automatically after signing in to the same account.
- The `enana` shortcut works right after install (placed in a writable directory that is already on PATH); the install command works on systems without curl (wget) with clearer messages for a missing system or tool.
- The Apps list has column headers, selected tabs are clearer, speed-test nodes can be selected / cleared all at once, and “new version” opens the update dialog directly.
