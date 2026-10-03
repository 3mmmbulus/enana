# macOS 网络接管与导航修复

## 诊断结论

2.1.2 的 mixed 入站无法接管忽略系统代理的连接。PIN 的进程匹配规则只能在连接进入核心之后生效。OAuth 浏览器回调成功不能证明 App 的 token 请求进入核心; 旧导出没有独立 OS socket 证据, 无法据此确认具体失败请求。

所附日志存在 Google Chrome 的 `direct|ack` 策略和 `direct-app` 访问记录。旧配置把应用 Direct/Auto 放在网站目录规则之前, 因此 Chrome 的 Direct 可以拦截已开启的网站, Auto 可以拦截网站 PIN。Safari 与 Chrome 策略不同会产生不同结果。Claude 区域限制本身仍可能由节点地区引起, 不能只凭页面错误断言某个 IP。

本机后续记录: 12:57:28 Chrome 改为 Direct, Google/YouTube 仍按网站配置使用代理; 13:01:05 恢复跟随, 13:01:14 的 `claude.ai` 及随后资源域名使用 PIN Tokyo。这些记录确认了当时的路由选择, 不等于 HTTP 请求或账号登录成功。浏览器的任意应用策略现在都是兜底: 网站单独配置优先, 未配置的网站才使用浏览器 Direct/Auto/PIN; 原生 App 的明确 PIN 则保持进程优先。

Gemini 自身日志在 12:58:45 接受浏览器回调并开始交换 authorization code, 12:58:55 报 token 交换超时。浏览器的完成页面不能代表 App 已登录。该请求没有对应的核心记录, 当时仍是 System Proxy; 独立 socket 诊断补足绕过系统代理的证据, 单凭核心没有记录不能确定每个请求的去向。

## 后台登录与账号退出

仪表盘只将本机访问令牌放在标签页的 `sessionStorage`, 重新打开标签页需要登录; 2.2.0 按用户要求将无操作自动锁定从 30 分钟延长至 5 小时, 到时清除该页面令牌并锁定。页面锁定不清除本机云端会话、不关闭代理。主动退出账号才会清除本机登录信息、释放云端设备名额、关闭代理并轮换令牌, 使其它后台页面一起失效。被其它设备下线或连续 7 天无法向云端发送心跳也会退出本机账号。

本次只读核对: Mac 的本机登录状态、云端令牌与会话均存在, 心跳持续刷新, 没有退出原因或联网失败计时文件。当天 12:53 登录后的操作日志没有主动退出或被下线记录; Chrome 当前仍处于登录状态。用户反馈的放置后台后再次要求登录与原先 30 分钟页面锁定吻合, 不能据此判定云端反复撤销会话。延长的是页面无操作时长, 云端会话策略不变。

## 实现与验证范围

System Proxy 默认不变。Enhanced/TUN 是显式选择, 包含双栈捕获、DNS hijack、进程匹配、系统路由私网排除、默认接口出口绑定。root launchdaemon 使用 root 拥有的核心/规则快照; 用户授权后安装。启动检查实际 utun 地址与 IPv4/IPv6 路由。失败在 root helper 内恢复快照, 上层事务恢复设置。切换时通过控制 API 保存并恢复 Selector 选项, 避免丢失已选 PIN 出口。应用 PIN 使用独立进程规则集, 优先于网站指定的其他 PIN 出口; 浏览器 Direct/Auto/PIN 则作为网站策略之后的兜底。

自动化测试不修改真实系统路由, 不触发管理员授权:

- `tests/enhanced.sh`: 默认与已有设置保留、生成配置的真实 sing-box 校验、双栈排除、共享 PIN、浏览器与网站优先级、OS socket 证据。
- `tests/tun-service.sh`: 临时副本与假系统命令执行真实 helper 逻辑, 校验 bootstrap 失败/外部 VPN 路由冲突回滚、GUI 恢复及 symlink 拒绝。
- `tests/ui-busy.test.js`: 实际组件回调的重复提交、忙碌状态、错误恢复、切换控件、弹窗按钮重建。
- `tests/network-mode-ui.test.js`: 原生 App 的接管引导、明确选择有限 System 模式、取消管理员授权、TUN 未就绪及重试。
- `tests/vps-probe.sh`: 真实 SSH 编排使用假 SSH, 验证暂时失败后恢复、三次上限、认证不重试、取消 / 超时清理子进程与凭据、启动失败和取消接口。
- `tests/vps-ui.test.js`: 真实向导任务流程, 验证任务编号返回前取消、取消请求失败时已完成 / 未完成任务的恢复, 避免再次卡住。
- `tests/run.sh` / `tests/units.sh`: 原有隔离端到端与单元回归。

真实管理员授权、macOS TUN 路由与原生 App 登录需要用户选择 Enhanced 后分别验收。下文记录本机 Gemini 的实际登录结果; Claude/ChatGPT 登录、UDP/QUIC、断开 PIN 和切回轻量模式仍需各自验收。Schema 校验与假 launchd 回归不能替代真实流程。

## 本机验收步骤

1. 保存诊断, 在设置选择 Enhanced/TUN 并完成系统管理员授权。
2. `enana doctor`: `capture.mode=tun`, `capture.tun.ready=yes`, 双栈公网路由为同一 utun, localhost 为 lo0。使用局域网服务及 OAuth localhost 回调确认不受影响。
3. 把目标 App 设为 PIN, 退出并重新打开 App 以重新建立连接; 日志详情应显示 TUN 入口、正确进程路径和所选 PIN 节点。验证 UDP/QUIC 和 token 请求; 共享系统进程应单独核对。
4. Chrome 设为 Direct/Auto, 开启 Claude/Google/YouTube 网站策略; 已配置网站应按网站规则处理, 未配置网站使用浏览器兜底。原生应用明确 PIN 优先于网站; 浏览器 PIN 仍服从网站单独配置。
5. 断开所选 PIN 节点确认不会落到自动池; 检查核心出口不出现在重复捕获连接中。
6. 切回 System Proxy, 确认原系统代理设置、账号及 Selector 选项保留。失败或取消授权应保留原模式和服务。

## 导航设计依据

参考 [Ant Design 导航](https://ant.design/docs/spec/navigation/) / [Tabs](https://ant.design/components/tabs/) / [按钮 Loading](https://ant.design/components/button/) 与开源 [Tabler](https://github.com/tabler/tabler): 主导航用于独立任务, 二级 tabs 用于同一任务内的并列视图, 左侧导航用于较多的稳定分类。

服务器改为节点/我的服务器/订阅/官方的 tabs, 服务器记录使用可横向滚动的表格。网站保留来源 tabs, 桌面分类使用左侧导航, 小屏分类使用 tabs, 搜索跨分类。测速改为测速/IP/上次结果 tabs; 操作栏置顶, 全选/取消全选合并, 推荐节点独立; 当前任务在弹窗展示, 可退到后台继续。通用异步控件与弹窗 footer 在任务未完成前原生 disabled, 显示 loading 与 aria-busy。

节点行只保留一个「操作」入口, 打开原有详情弹窗并集中展示全部操作。这样小屏不会挤满含义不明的图标; 弹窗仍根据角色、当前选择器、官方 / 派生节点与任务状态解释可用性, 凭据和删除仍走原有二次验证。

## 添加服务器卡住的原因与处理

本机截图对应的检测任务一直处于准备中, 辅助服务日志出现 `nohup: …/enana: Permission denied`, 且没有 worker 启动标记。原因是本次手动同步客户端时入口文件没有执行权限, 并非已经连上服务器但读取很慢; 已恢复 755 权限。安装器原本会设置该权限。`job_launch` 现在先检查可执行性, 失败明确结束任务并删除临时凭据。

只读检测现在可以取消。取消并非只隐藏弹窗: 前端等待 POST 得到任务编号后发取消请求, 后端停止此任务创建的 SSH / keyscan 子进程, 清理凭据后结束。检测按钮与后续操作保持禁用, 只有专用取消按钮可在忙碌期间使用且自身不能重复提交。取消请求失败时继续展示真实任务结果, 防止完成结果被取消状态吞掉。

进度分别显示读取指纹、验证 SSH 登录、读取系统与网络信息、等待重试, 并带当前次数 / 最多 3 次、耗时 / 阶段上限。只重试临时连接失败, 不重试密码 / 密钥 / 指纹错误, 也不自动重试或中断正在修改服务器的部署任务。这样既解释等待状态, 又避免重复执行远端变更。

## 本次本机检查

最近一次完整隔离回归: 788 通过, 0 失败 (包含 94 项单元测试及实际 Node 组件测试); 后续 SSH 取消 / 重试与向导完成竞态回归单独执行。真实核心配置校验、进程路由测试与中英文文案检查通过。2.2.0 升级时本机仍使用 System Proxy; 之后按用户明确选择开启 Enhanced/TUN。升级前后核对了账号/令牌、服务器/订阅、应用策略、settings.env 及 macOS 三种系统代理的值, 均保持一致。代码与旧配置保留在 `~/.enana/backups/codex-macos-tun-20261003-064947` 和 `~/.enana/backups/codex-2.2.0-20261003-132044`。

更新前的独立 socket 采样发现 ChatGPT 安装包内 `codex-cli/CodexCLI.app` 的子进程有 4 条公网连接未匹配到核心连接; 当时控制 API 可读 (32 条活跃连接), 两个地址族的公网路由为 en0。该证据属于采样时刻的包内子进程, 不能替代 Gemini token 请求或 ChatGPT 主界面登录流程的复现。

## 2026-10-03 Gemini 真实登录与 2.2.1 修复

14:19 的 System Proxy 登录重试再次在 authorization code 交换阶段超时。开启 Enhanced 后, 14:31:18.742 开始交换, 14:31:19.327 收到 refresh token, 14:31:19.506 收到 access token, 14:31:19.508 状态变为 signedIn。App 展示账号、历史对话和新对话界面, 完成了浏览器回调之后的原生登录流程。以上只记录状态与时间, 不包含 code、token 或账号内容。

此时控制 API 确认 Gemini 主程序及 GeminiAppLauncher 的连接命中 `ovr-apppin`, 链路为 `PIN → Tokyo`; PIN 保留 Tokyo, Global 保留 AUTO。IPv4 与 IPv6 公网路由指向同一 utun, localhost 回调仍使用 lo0, 私网路由使用物理网卡。短暂的 token 请求没有保留控制 API 连接快照, 因此不能用后续活跃连接声称逐包记录了该请求; token 成功由 App 自身日志和实际界面确认。

验收发现两个此前假服务测试未覆盖的问题:

- `decode(<>)` 的列表上下文会把随后用于路径替换的 home/root 参数当作文件名读取, 耗尽 `@ARGV`。root 核心因此继续使用用户目录的缓存、日志和规则路径; 日志句柄随用户日志迁移后仍写入旧文件, 诊断导出缺失新的 TUN 连接。改为显式 open 配置文件并标量读取, 测试实际转换后的 log/cache/rules 路径以及出口保持。
- `disable` 加 `kill` 没有卸载已加载的 KeepAlive LaunchAgent, 旧核心仍反复启动并争抢缓存。改为 bootout 原任务, 保存其既有 plist 路径以在失败时重新 bootstrap 原用户服务; 固定 root daemon 的程序路径和权限策略不变。

升级前检查端口只看 GUI 服务, 把 root 核心监听当成外部程序并重新分配端口。现在识别实际后台服务; 回归模拟仅有 root 核心和本机辅助服务的状态, 要求四个现有端口全部保留。doctor 也改为报告实际工作的后台。快照指纹包含转换和 root helper 实现, 使配置内容相同时的实现修复也能部署。

完整回归启动时曾受本机已安装 TUN plist 影响, 在隔离夹具中误进入管理员停止分支, 使首装夹具失败。测试现在把非特权 TUN 路径查询限定到临时目录; privileged helper 独立使用固定 Library 路径, 不读取这些测试环境覆盖。该失败不能计入通过的测试结果, 修复后重新执行完整回归。

实际更新辅助脚本时, macOS 管理员授权成功后仍拒绝后台进程读取 Desktop 中的仓库脚本 (`Operation not permitted`, 126)。helper 现在和已经过审查的核心配置一起放入安装临时目录, 在原生授权后执行; 它不会作为 launchd 程序安装。新增测试执行真实 enhanced_start 编排并验证使用的是临时 helper 副本。

本机 1.14.2 在默认内核 TCP 实现下还出现了非显式代理 IPv4 请求握手超时, 尽管 route 检查显示 utun。2.2.1 在旧版核心使用 gVisor TCP/UDP, 保留全部私网排除; 1.15+ 按 [上游 TUN 文档](https://sing-box.sagernet.org/configuration/inbound/tun/) 使用自有栈, 不生成已弃用的 stack 选项。更新后 IPv4 `--noproxy '*'` 的 token 端点 HEAD 请求在约 0.3 秒完成 TLS 并收到 HTTP 404 (HEAD 不能交换 token, 这里仅验证连通性), 核心日志同时记录 TUN 入站。这修复的是网络层捕获, 没有添加 Gemini 专用域名规则。

2.2.1 本机更新完成, root 服务运行, 旧用户服务未加载, 四个端口保留。IPv4/IPv6 公网仍为 utun, localhost 为 lo0, 私网为 en0。账号、令牌、服务器、订阅、应用覆盖以及 settings.env 键值与更新前完全一致, PIN 为 Tokyo、Global 为 AUTO。Gemini 保持已登录; 其后续接口连接继续使用 Tokyo。

完整回归还暴露了原有 DNS 测速夹具对 AUTO 先前探测结果的依赖: AUTO 的公网探测地址在隔离环境不可用, 可能选中故意不可用的测试节点, 使全部海外 DNS 测速为 null。该测试现在明确选定已知可用的本机 Local-Hop, 通过真实 Global detour 测量, 结束后还原选择器; 不修改 DNS 产品逻辑, 不放宽原断言。

最终完整隔离回归: 790 通过, 0 失败 (含 94 项单元及实际 Node 组件回调回归)。新增 snapshot / helper 临时目录 / 端口保留 / 指纹目录无关性与诊断探测标签测试另行通过。IPv6 强制端点探测也进入 TUN 并使用配置的 Global 出口, 但此次该端点 TLS 失败; 不把路由归属等同于每个出口都可访问任意 IPv6 端点。Gemini 真实登录和持续接口访问是单独的验收结果。

实际发布的 2.2.1 安装包另通过 `tests/get-test.sh <发布目录>`: 55 通过, 0 失败, 覆盖首装、哈希不符拦截、下载线路回退、升级 / self-update 和用户数据保留。安装夹具也使用临时 TUN 路径, 不读取本机已加载服务的 plist。

## 2.2.2 自动扫描任务误标为流量接管

用户反馈刷新任意导航、切回 Chrome 时反复出现「流量接管方式」进度。15:34–15:37 的本机任务记录实际为 `apps-scan`, 完成消息为「识别已安装的应用 完成 (配置无变化, 未重启)」; 另有用户修改策略的 `override` 任务, 不应混为切换接管。

原因是应用轮询在页面初始化及 `visibilitychange` 时调用 `loadApps(true)`, Enhanced 模式将扫描作为事务任务运行, 数据层却对扫描和覆盖规则两种任务都使用了 `set.network.title` 并显示 dock 和成功通知。2.2.2 安静跟踪自动扫描, 仍等待后端完成后更新列表与状态; 手动扫描和覆盖规则各自使用正确标题。扫描间隔保存在浏览器本机存储, 页面刷新 / 回到前台在 60 秒内只读列表; 同一页面并发扫描共享 Promise, 手动操作不受时间间隔限制。

`tests/app-refresh-ui.test.js` 加载真实 core.js / data.js, 执行实际轮询与可见性事件, 验证自动扫描没有进度卡和成功通知、刷新后间隔保留、并发只有一次扫描、手动任务标题准确、失败没有假成功且可重试; 所有这些路径都不会请求 `/api/network-mode`。这不是关闭新应用发现功能, 也不修改现有接管方式和分流规则。

本次前端 4 套回归通过 (应用刷新、异步控件、接管引导、SSH 向导), 正式 2.2.2 发布包安装 / 升级测试 55 通过、0 失败。102 个本机程序文件与发布包一致, 账号、服务器、设置与所有 Selector 均保留。Chrome 实际验证设置页及服务器页刷新、切出 / 切回标签页没有自动任务卡; 手动重新扫描显示「扫描已安装的应用」并正常完成。接管仍为 Enhanced/TUN 且就绪, PIN Tokyo / Global AUTO 保持。
