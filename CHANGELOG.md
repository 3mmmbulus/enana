# Changelog / 更新日志

## 2.3.4 (2026-10-04)

### 中文
- 修复普通 Windows PowerShell 安装/升级时 `Set-Acl` 请求 `SeSecurityPrivilege` 并失败的问题。目录权限通过 .NET 只保存已修改的访问控制和所有者部分, 不触碰审计权限; 保留当前用户、SYSTEM、管理员的私有目录权限与 TUN 的管理员所有权。
- 增加真实 Windows 令牌测试: 删除审计特权后创建并再次加固目录, 检查当前用户可读写、无公共访问权限。管理员 CI 不再掩盖普通用户安装的这类失败。

### English
- Fix regular-user Windows installation failing because PowerShell Set-Acl reapplies audit security sections requiring SeSecurityPrivilege. Persist only modified directory access/owner sections through .NET, preserving private access rules and administrator ownership for TUN snapshots.
- Test real Windows directory hardening under a token with the audit privilege removed, including repeated calls, file access and absence of public access rules.

## 2.3.3 (2026-10-04)

### 中文
- 修复 Windows 无参数 `enana` 直接打开浏览器、无法通过终端查看或恢复服务的问题。现在复用终端控制台, 按 `1` 打开仪表盘; 重定向输入时输出状态。
- 修复 Windows 代理核心启动失败会带着后台一起退出的问题。后台保留用于诊断和恢复, 核心失败记录明确错误并有限频率重试; 恢复成功清除错误状态。
- 计划任务启动错误写入有大小上限、脱敏的 `worker.log`; `enana doctor` 增加原生 Windows 启动任务、退出码、运行时和日志检查, 不依赖后台正常运行。增加真实 Windows 核心故障恢复和 CLI 回归测试。
- 以上修复不表示所有 Windows 11 ARM64 故障已定位: Parallels 来宾现场日志和交互验收仍需检查。

### English
- Restore the shared terminal console for bare `enana` on Windows, so a stopped dashboard can be diagnosed and restarted without first opening an unavailable browser page.
- Keep the Windows dashboard alive when the proxy core fails to start. Record the failure, retry at a bounded rate, and clear the error after recovery.
- Persist redacted, bounded scheduled-task startup logs and add native Windows diagnostics. Cover real failed-core recovery and CLI dispatch in regression tests. Windows 11 ARM64 on-device diagnosis remains separate from x64 CI.

## 2.3.2 (2026-10-03)

### 中文
- 修复 Windows 重复安装后卸载时, 后台分离的 Bash 任务仍占用私有运行时的问题。关闭命令等待核心管理进程真正退出, 升级与卸载按安装目录和用户 SID 清理残留运行时进程; 不按进程名关闭其它项目。
- 补充真实进程关闭等待、分离进程清理和其它进程保留验收。完整官网命令验收开启了浏览器自动访问, 暴露出之前 `-NoOpen` 安装测试没有覆盖的后台任务生命周期。

### English
- Fix detached Bash jobs retaining private runtime executables after Windows reinstall. Shutdown waits for the acknowledged supervisor to exit; upgrade/uninstall clean up remaining processes by installation path and owner SID, retaining unrelated programs.
- Verify real process-exit waiting and native detached-process cleanup with an unrelated-process preservation check. Published-command acceptance opens the dashboard, exercising a job lifecycle omitted by earlier `-NoOpen` installs.

## 2.3.1 (2026-10-03)

### 中文
- 修复 Windows 官网 `irm https://install.enana.cc/get.ps1 | iex` 安装入口的 `Lang` 默认值校验错误。语言默认值改为合法的 `auto`, 自动使用系统语言; 保留显式中文 / 英文选项。
- 补测无参数 `Invoke-Expression`、中文 / 英文 / 其它系统语言与重复执行; 官网下载验收改为在 Windows PowerShell 5.1 的 Restricted 和 Bypass 进程中执行原样安装命令, 防止传入 `-Lang en` 掩盖默认入口故障。

### English
- Fix the Windows website's `irm https://install.enana.cc/get.ps1 | iex` failing before download because an empty default `Lang` was outside its validation set. Use a valid `auto` default and resolve the system culture, retaining explicit Chinese and English options.
- Cover no-argument Invoke-Expression, multiple cultures and retries. Published-download acceptance now executes the documented command unchanged in Windows PowerShell 5.1 Restricted and Bypass processes; an explicit `-Lang en` must not hide a broken default entry point.

## 2.3.0 (2026-10-03)

### 中文
- 增加 Windows 10 2004+ / Windows 11 x64、ARM64 预览版: PowerShell 安装、SHA-256 下载校验、私有 PortableGit/Node 运行时、计划任务、快捷命令、升级失败恢复和本机后台。
- 复用现有仪表盘、API、事务和分流规则, 避免两套平台实现行为分叉。默认保留 System Proxy, 可选择 UAC Enhanced/TUN; localhost/局域网排除与出口网卡绑定保持一致。
- Windows 应用通过原生 EXE 路径匹配, 覆盖应用目录中的辅助进程与版本更新; 普通共享目录仅匹配该 EXE。PIN、网站优先于浏览器兜底的规则体系复用现有实现。
- 增加 WinINet 原配置备份/恢复与外部修改保留, 管理员保护的 TUN 快照和固定官方核心验证, 防止普通用户可写程序作为 SYSTEM 常驻。
- 增加 Windows 原生 CI 和规则、HTTP 请求边界、DNS、ZIP 安全测试。Windows 交互 UAC/TUN、原生应用 OAuth 与 VPN 共存仍需实机验收; 预览标记不声明已完成这些测试。
- 官网 Windows 命令改为可执行 PowerShell 安装入口, 独立 Windows 发布清单与 ZIP; 官网源代码纳入仓库, 便于审计安装说明与产品声明。

### English
- Add the Windows 10 2004+ / Windows 11 x64 and ARM64 preview with PowerShell installation, SHA-256 pinned private PortableGit/Node runtimes, scheduled tasks, native commands, upgrade recovery and the local dashboard.
- Share the existing dashboard, Bash API, transactions and routing generator to prevent platform drift. Keep System Proxy as the default and offer UAC-authorized Enhanced/TUN with local/LAN exclusions and physical-interface egress.
- Match Windows applications by executable paths, including app-directory helpers and version updates; shared directories match only the selected executable. Reuse PIN and website-before-browser routing precedence.
- Restore owned WinINet settings while retaining foreign edits, and run TUN from an administrator-protected snapshot with a reverified official core rather than mutable user code.
- Add native Windows CI and routing, request framing, DNS and safe ZIP regressions. Interactive UAC/TUN, native-app OAuth and VPN coexistence still require Windows device acceptance; this release remains a preview.
- Replace the website's placeholder with the PowerShell bootstrap and independent Windows ZIP/manifest; track website source with the client for reviewable installation claims.

## 2.2.2 (2026-10-03)

### 中文
- 修复刷新页面 / 切回浏览器时自动扫描应用弹出「流量接管方式」进度与完成通知: 自动扫描改为安静跟踪任务, 手动扫描与修改应用 / 网站策略使用各自正确的标题。扫描并未切换接管模式。
- 自动扫描的 60 秒间隔跨页面刷新保留, 回到前台优先读取列表; 并发扫描复用当前任务, 手动重新扫描可立即执行。失败不再显示扫描成功提示。
- 增加实际数据加载、轮询、可见性事件与任务跟踪回归, 覆盖刷新、切回前台、手动操作和失败恢复。

### English
- Fix automatic app discovery showing Capture mode progress and completion notices on reload / return to the browser. Follow automatic scans silently and give manual scans and app/site overrides their own titles; discovery does not switch capture modes.
- Preserve the 60-second automatic scan cadence across page reloads, refresh cached data on foreground kicks, and share concurrent scans. Manual rescans bypass the cadence; failed scans no longer report success.
- Add regressions using the actual data loaders, poller, visibility handler and job tracker for reloads, foreground changes, manual actions and failure recovery.

## 2.2.1 (2026-10-03)

### 中文
- 修复 Enhanced/TUN 配置快照的路径转换: 显式读取配置文件, 防止 Perl 的列表上下文耗尽路径参数, 使 root 核心使用独立的缓存、日志与规则快照。
- 切换到 TUN 时完整卸载旧用户态 KeepAlive 服务, 防止被 launchd 反复拉起; 启动失败时重新注册原用户服务。实现文件变更也会触发快照更新。
- 增强模式升级正确识别 root 核心占用的端口, 保留现有端口和系统代理配置; doctor 显示实际工作的核心服务。
- 旧版核心使用 gVisor TCP/UDP 修复 macOS 内核 TCP 接管的 IPv4 握手失败; 1.15+ 使用上游自有栈。辅助安装脚本放在临时目录, 避免后台进程无法读取 Desktop / Downloads 的 macOS 权限限制。
- 诊断将增强模式下的非显式代理探测标为 tun, 防止误当作物理直连。
- 补充真实配置转换、KeepAlive 卸载 / 失败恢复和 TUN 升级端口保留回归。隔离测试不再读取本机的真实 TUN plist。
- 本机 Gemini 已完成增强接管后的 OAuth token 交换并进入已登录界面; 观察到主程序与辅助程序使用 PIN Tokyo。其它原生应用登录与网络场景仍需各自验收。

### English
- Fix privileged Enhanced/TUN snapshot path rewriting by explicitly reading the config file; Perl list context previously consumed the path arguments, leaving the root core on user cache/log/rule paths.
- Unload the old user KeepAlive job when switching to TUN and re-register it on failed startup, preventing launchd respawns. Changes to snapshot implementation now trigger redeployment.
- Preserve ports owned by the root TUN core during upgrades and retain System Proxy settings; doctor reports the active backend.
- Use gVisor TCP/UDP on legacy cores to resolve macOS IPv4 handshake failures; use the upstream native stack on 1.15+. Stage the installation helper in a temporary directory to avoid protected Desktop / Downloads access failures.
- Label no-explicit-proxy probes as tun during enhanced capture, avoiding false physical-direct interpretations.
- Add actual snapshot conversion, KeepAlive unload/recovery and TUN upgrade port regressions. Isolated tests no longer inspect the host's real TUN plist.
- Verify Gemini OAuth token exchange and signed-in UI on this Mac after enhanced capture; observed main/helper connections use PIN Tokyo. Other native-app logins and network scenarios require separate acceptance checks.

## 2.2.0 (2026-10-03)

### 中文
- 仪表盘无操作自动锁定从 30 分钟延长到 5 小时; 页面锁定保留本机账号与代理运行, 主动退出账号行为不变。
- 新增 macOS 可选增强接管 (Enhanced/TUN): 接管绕过系统代理的公网 TCP/UDP, 复用应用与网站分流; localhost、局域网与核心出口正确排除。升级保留 System Proxy, 开启增强接管需要管理员授权。
- 修复浏览器 Direct/Auto 抢先覆盖网站策略; 原生应用 PIN 优先于网站指定出口, 不回落到自动池。应用页提供增强接管引导, 明确轻量模式的覆盖范围。
- 修复添加服务器、日志导出与其它异步控件重复提交; 显示忙碌状态, 禁用进行中的按钮。
- 添加服务器的只读检测支持取消, 分阶段显示主机指纹 / SSH 登录 / 系统读取、尝试次数及超时; 临时连接失败最多尝试 3 次, 密码、密钥或指纹错误不自动重试。任务无法启动时立即报错, 不再一直显示准备中。
- 节点表格的操作列合并为一个「操作」按钮, 在弹窗集中展示固定出口、自动出口、测速、凭据与删除操作。
- 调整服务器、网站与测速的二级导航; 我的服务器使用表格, 测速操作栏置顶、合并全选/取消全选, 进度在弹窗展示。
- 诊断加入接管模式、路由归属、入站来源及系统 socket/核心连接对照。缺少核心日志不再被当作没有请求的证据。
- 核心配置校验、授权取消/服务启动失败回滚、进程路由和异步组件均增加自动化回归。真实原生 App 登录需要增强接管后的端到端验收。

### English
- Extend the dashboard idle lock from 30 minutes to 5 hours; locking the page keeps the device account and proxy active. Explicit sign-out behavior is unchanged.
- Add optional macOS Enhanced/TUN capture for public TCP/UDP bypassing System Proxy, reusing app/site routing with localhost, LAN and core egress exclusions. Upgrades keep System Proxy; enhanced capture requires administrator authorization.
- Fix browser Direct/Auto overriding site policies; native app PIN takes precedence over site-specific exits and does not fall back to Auto. Guide users to enhanced capture from the Apps page and explain lightweight coverage.
- Prevent duplicate submissions during server setup, log export and other asynchronous actions, with disabled buttons and visible progress.
- Make read-only server detection cancellable, with host-key / SSH login / inspection stages, attempt counts and time limits. Retry transient connection failures at most three times, never rejected credentials or host keys; report launch failures immediately instead of remaining stuck in preparation.
- Replace the node table's action icons with one Actions button opening a dialog for PIN, Auto, tests, credentials and deletion.
- Restructure server, site and speed-test navigation; use a table for owned servers, a top action bar and combined selection toggle for tests, and a progress dialog.
- Include capture mode, route ownership, inbound source and OS socket/core connection comparison in diagnostics. Missing core logs alone do not prove absence of traffic.
- Add schema, cancellation/startup rollback, real process routing and async UI regressions. Native app login still needs end-to-end validation with enhanced capture enabled.

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
