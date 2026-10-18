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

System Proxy 默认不变。Enhanced/TUN 是显式选择, 包含双栈捕获、DNS hijack、进程匹配、系统路由私网排除、默认接口出口绑定。root launchdaemon 使用 root 拥有的核心/规则快照; 用户授权后安装。enana 在弹出管理员框之前只接受记录为官方 SHA-256 钉死版本的核心 (`core-provenance`, 来源不明的直接拒绝, 不弹框; 升级前装的核心用 `enana upgrade` 重新下载这一版即可记下来源)。root 脚本本身没有内置允许的核心摘要列表: 它只核对 enana 交给它的核心字节与摘要一致, 所以「只装钉死版本」这条保证的执行点是 enana 这一侧。每个文件由 root 只读一次、按字节核对摘要, 核对不过就整体拒绝 (什么都不改)。被拒绝 (S2: 预检拒绝或 root 拒绝) 时一律保留流量接管方式, 放回原来的配置, 撤销本次更改并报告原因, 不再重试 TUN: 从 System Proxy 切到 TUN 被拒绝, 撤销之后仍是 System Proxy 并显示原因; 本来就是 TUN 的操作 (规则开关、DNS、策略、退出账号、更新规则等) 保持 TUN。以前根守护进程没有在运行时会悄悄改回系统代理模式还报告成功, 用户不知道 TUN 被拒绝了, 现在不再这样。后台流程从不弹管理员框 (`APPS_BG_JOB=1`): 界面的自动扫描、每分钟的 tick (自动识别网站、云端自动同步、心跳被下线后换令牌、官方线路) 和每日维护里, 要动根守护进程的变化都被撤销; 只重启用户自己的核心 (系统代理模式) 照常进行。应用扫描的变化记成「待应用」; 自动识别没加上的网站 24 小时内不再试; 云端自动拉取没应用成功的同一个版本 24 小时内不再重试 (仪表盘里手动拉取不受限); 官方线路记成待应用; 换令牌留给下一次经过授权的应用。启动检查实际 utun 地址与 IPv4/IPv6 路由。失败在 root helper 内恢复快照, 上层事务恢复设置。切换时通过控制 API 保存并恢复 Selector 选项, 避免丢失已选 PIN 出口。应用 PIN 使用独立进程规则集, 优先于网站指定的其他 PIN 出口; 浏览器 Direct/Auto/PIN 则作为网站策略之后的兜底。

打开代理总开关 (`POST /api/proxy`) 时如果核心没在运行要先启动它; 启动要管理员授权 (TUN, 或者根守护进程还加载着) 时不在请求里等密码框 (仪表盘 25 秒就会报告失败), 而是交给后台任务 `proxy`, 仪表盘和切换流量接管方式一样在 dock 里跟着它走; 其它情况 (启动用户自己的核心、核心已经在运行) 仍是即时的热切换。

固定出口分配 (`POST /api/exits/move|freeze`) 在 TUN 下同 `/api/override` 一样是后台任务: 只改 `rules/*/ovr-*.json` (纯路由数据), 经免密规则同步助手 (`lib/tunrules-helper.pl`) 同步到 root 快照, 核心热加载, 不重启、不要管理员密码; 助手一次最多同步 160 个规则集文件 (32 个固定出口 = 107 个), 旧助手上限 60 (16 个固定出口), 超过时退回完整安装并把助手换成新版。默认固定出口的选择存在 `$H/pin-default`, 核心 (重新) 启动后由 `proxy_sync_mode` 校正, 不改 `config.json`, 所以换默认出口不会触发 TUN 的完整重装。

自动化测试不修改真实系统路由, 不触发管理员授权:

- `tests/exits.sh`: 固定出口分配 (归属表 / 默认出口 / 批量移动与钉住 / 删除与改角色的保护 / 孤儿事件 / 上限 / HTTP 接口 / TUN 任务及回滚), 用假 Clash API。
- `tests/enhanced.sh`: 默认与已有设置保留、生成配置的真实 sing-box 校验、双栈排除、共享 PIN、浏览器与网站优先级、OS socket 证据。
- `tests/tun-service.sh`: 临时副本与假系统命令执行真实 helper 逻辑, 校验 bootstrap 失败/外部 VPN 路由冲突回滚、GUI 恢复及 symlink 拒绝, 以及系统 DNS 的接管与还原 (假 networksetup, 见下面「增强模式接管系统 DNS」)。
- `tests/ui-busy.test.js`: 实际组件回调的重复提交、忙碌状态、错误恢复、切换控件、弹窗按钮重建。
- `tests/network-mode-ui.test.js`: 原生 App 的接管引导、明确选择有限 System 模式、取消管理员授权、TUN 未就绪及重试。
- `tests/sysproxy-ui.test.js`: 总开关要先启动核心、而启动要管理员授权时, 跟着后台任务走 (成功 / 失败 / 切换模式)。
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

## 不必要的管理员密码框 (重启 / 自动更新订阅 / 停止)

TUN 的核心是 root 守护进程: 改核心、配置、规则库 (`.srs`)、证书都要管理员授权 (`lib/enhanced.sh` 的 `enhanced_admin`)。授权只应该在 root 快照真的会不同的时候出现, 下面几种情形以前会白白弹框:

| 现象 | 原因 | 现在 |
| --- | --- | --- |
| 「重启 enana」每次都弹 | `os_service_restart` → `enhanced_start` 一律走完整安装 | 核心 / 配置 / 规则库指纹没变、且 root 助手可信时, 用助手的 `restart` 动作 (`launchctl kickstart -k`) 重启, 不弹; 否则走原来的完整安装。操作记录里的 `重启核心方式` 写明走了哪条路: `via=helper`, 或 `via=admin why=no-helper|changed|rejected|not-loaded|sync-failed` |
| `enana update` / 每日维护 (订阅「自动更新」) 弹 | 指纹把每次都会重写的 `rules/.updated` 算进去了; 总开关 / 模式切换会改写磁盘配置里的 `default_mode`, 也让指纹对不上 | 指纹忽略隐藏文件 / `*.new` / `*.tmp`, 并把 `default_mode` 的值抹平后再算; 真的变了的 `.srs` / 配置 / 证书仍然触发完整安装 |
| 订阅内容没变也重启核心 | 订阅刷新「删光再追加」, 有两个以上订阅或订阅后面有手动服务器时文件顺序变了, 生成的配置 (默认固定出口、自动线路顺序) 随之不同 | 刷新是就地合并 (见 `docs/API.md` 的 `servers/import`), 内容相同的刷新不改动 `servers.jsonl`; 多个订阅一次事务、一次应用; 订阅里用户固定的角色保留 |
| 切到系统代理模式后, 每次启动 / 停止都弹 | 停止动作只看 plist 在不在 (停止后 plist 还在), 对已经停掉的守护进程也要授权 | 守护进程没加载、且不会自己回来 (launchd 里已禁用, 或本机记下了上一次成功的停止) 时直接跳过; 「已停止」的记录只在 root 停止成功、而且守护进程确实不在 launchd 里之后才写。反过来, 设置已经是系统代理、配置也没变, 但根守护进程还加载着 (切回没有完成) 时, `apply_config` 不再直接返回, 而是重启一次把它停掉; 用户核心的 plist 按系统代理写 (开机自启 / 崩溃重启), 即使这时设置里还是 TUN (失败事务的回滚中) |
| 点了取消, 同一次点击又连着弹 (最多四次) | op_txn 回滚后的重新应用、apply_config 自己的回滚重启、root-copy-untrusted 的 inband 重试、升级核心失败后的重启都会再要授权 | 取消记在进程里 (`ENHANCED_PROMPT_CANCELLED`, 不导出): 同一个操作里 `enhanced_admin` / `os_admin_dialog` 不再弹框, 直接返回 7 (不是拒绝); 结果报告为「已取消管理员授权, 已撤销本次更改」, 操作记录写 `cancelled` |
| 取消了一次规则集开关, 之后每次 TUN 应用都弹 | 下载下来的 `rules/<x>/<x>.srs` 留在磁盘上, 指纹把 `rules/*/*` 全部算进去 | 指纹只算配置里 `route.rule_set` 引用到的本地规则文件 (和 root 安装时 `check-config` 列出的是同一份); 证书照旧全部算, 策略规则集 (`ovr-*.json`) 照旧有自己的指纹 |

**默认模式不会走错**: `default_mode` 只是核心「没有记住模式」时的起始模式。运行时的模式通过控制接口 (`PATCH /configs`) 推送, sing-box 把它存在 `cache.db` 里并在重启时恢复; enana 自己做的每一次重启 (应用配置、重启、升级核心、启动) 之后都会再 `proxy_sync_mode`。剩下的缺口是「推送时核心没在运行 + 缓存里也没有」, 所以完整安装会记下写进快照的模式 (`$H/.enhanced-mode`), 之后每次无变化的 `apply_config` 发现设置里的模式和它不一致就补同步一次, 核心确认之后才记下。

**root 助手 (`/Library/PrivilegedHelperTools/com.enana.proxy/tunrules-<uid>`, 版本 5; 2.3.23 及更早版本在 `/usr/local/libexec/enana/`)** 的动作都只作用于这个用户自己的守护进程:

- `sync`: 校验后写入 `rules/*/ovr-*.json` (应用 / 网站策略) 和 `rules/site-<id>/site-<id>.json` (网站的域名列表, 见下面), 核心热加载。
- `restart`: 只执行 `launchctl kickstart -k system/com.enana.proxy.tun.<uid>`。标签和 `launchctl` 路径是安装时由 root 脚本写死进助手的 (不是调用者给的), 助手不读任何参数 / 输入 / 环境变量; 有多余参数、标签不合规都会拒绝。威胁模型: 同一用户下的任何进程最多能让自己的 root 守护进程重启一次 (流量中断几秒), 得不到 root 权限, 也改不了任何文件; 助手文件归 root、别人不可写、不是符号链接、sudoers 规则经 `visudo -cf` 校验, 这些检查一条没放松。
- 助手的可信判断只看字节 (`os_helper_trusted`): 安装到 root 目录的助手必须和 enana 此刻渲染出来的一模一样 (`enhanced_helper_render`, 与 root 脚本里的 `helper_render` 是同一段函数), 不再为了查版本而运行它。字节对不上、目录链 (助手所在的目录和上面两级: `…/com.enana.proxy`、`/Library/PrivilegedHelperTools`、`/Library`) 有组 / 其他人可写或者有 ACL, 或者 sudoers 规则不在, 都判为不可用; 下一次完整安装 (一次管理员授权) 换上新的。
- 位置 (2.3.23 之后): 助手从 `/usr/local/libexec/enana/` 搬到 `/Library/PrivilegedHelperTools/com.enana.proxy/` (只有 root 能写, 包管理器从来不碰它; 老的 Homebrew 会把 `/usr/local` 改成用户可写, 那样的 Mac 上以前根本装不上助手, 早先装好的免密规则还指向一个用户能写的目录)。完整安装 (root 脚本的 d 步) 把助手装到新位置, 免密规则 `/etc/sudoers.d/enana-tunrules-<uid>` (文件名不变) 在同一步改写成新路径, 然后删掉旧位置的那一份 (旧目录是真目录才删; 空了连目录一起删)。缺的 `PrivilegedHelperTools` 和 `com.enana.proxy` 由 root 建成 `755` root:wheel, `/Library` 从来不建。还没完整安装过的 Mac 上, 旧位置的助手只要通过同样严格的检查 (旧位置的目录链 `/usr/local`、`/usr/local/libexec`、`/usr/local/libexec/enana`) 就照常用, `sync` / `restart` / `cleanup` 的 `sudo -n` 调用的都是判为可信的那一份 (先看新位置)。迁移的那次安装如果失败回滚, 指向旧位置的规则不放回去 (旧位置的助手已经删了)。删除 TUN 时两个位置的助手都删, 空了的 `com.enana.proxy` 也删, `PrivilegedHelperTools` 本身不删。
- 停止 / 删除 TUN 只运行安装后留在 root 目录里的副本 `ROOT/bin/enhanced-root.sh` (root 所有、0700); 旧版本没有这个副本时, 才用一次性的 inband 形式 (脚本随命令带进去)。
- 管理员命令全部是一行、以 `/usr/bin/env -i` 清空环境运行, 所有命令都用绝对路径; 每个传给 root 的数据文件 (脚本、配置、快照、助手模板) 都由 enana 只读一次、算摘要, root 按摘要核对后才写入。

Windows 的 TUN 没有免密助手 (每次完整安装都是 UAC), 指纹的两个问题同样存在, 已用同一套规则修复; 策略规则集 (`ovr-*.json`) 在 Windows 上仍计入指纹。Windows 的 `stop` 本来就会跳过没有运行的任务。

### 网站的域名不写进核心配置 (2.3.26)

2.3.25 把每个网站 (目录条目) 的生效域名直接写在 `config.json` 的路由规则里, 所以「修改网站域名」(例如 `ai-common` 删掉 `intercom.io` / `auth0.com`) 会改配置, TUN 下就要完整安装、弹管理员框; 取消授权就撤销。现在:

- 每个目录条目一个本地规则集 `rules/site-<id>/site-<id>.json` (tag `site-<id>`, `lib/catalog.awk` 生成, `lib/sites.sh` 的 `sites_rules_write` 内容有变才原地覆盖)。配置里只有 `{"rule_set":["site-<id>"],"action":"route","outbound":"svc-<id>"}`, 规则的位置和以前的域名规则一样; 没有域名的条目用占位 (`enana-placeholder.invalid`), 配置照样引用, 所以以后加域名也不改配置。域名一律小写, 只留合法的名字 (和 root 助手的检查一致)。
- 改域名、重置一个网站的域名、「恢复网站默认」、添加 / 删除自己的网站 (`ovr-*.json`)、改线路 (网站的出口开关本来就是核心里的选择器热切换, 自己的网站改线路只换 `ovr-*.json`) 都只改规则数据: 配置一个字节不变。`enhanced_fingerprint` 不算 `site-*.json`; 配置引用到的 `site-*.json` 算进 `enhanced_ovr_fingerprint`, 和策略规则集一起由 `enhanced_sync_ovr` 免密同步到 root 快照, root 的核心热加载。后台任务 (`APPS_BG_JOB=1`) 改的也一样能同步, 不再被撤销。云端内容只改了已有网站的域名时同理; 新增 / 删除目录条目会改配置 (多了 / 少了一个选择器), 仍然要完整安装。
- 助手 (版本 5) 对 `site-<id>.json` 的检查: 名字是 `site-` 加 1–63 位小写字母 / 数字 / 连字符 (不以连字符开头); 只能有一条规则, 匹配键只能是 `domain` / `domain_suffix`, 值必须是合法的域名 (标签 1–63 位、总长 ≤ 253, `domain_suffix` 可以以一个点开头), 没有正则、路径或别的键; 只覆盖快照里已经有的文件 (完整安装时 root 核对过、配置引用到的那些), 不新建目录或文件; 最多 400 个 (策略规则集仍是 160 个, 分开算); 其它检查 (符号链接、目录归属、总大小 2 MB、全部通过才写) 和 `ovr-*.json` 一样。文件名的正则改成 `\A…\z` (以前的 `$` 会放过结尾的换行)。
- 系统代理模式: 用户自己的核心读同一个文件, 改域名热加载, 不重启。
- 迁移: 2.3.25 的 TUN 快照 (域名在配置里, 助手是第 4 版) 照常工作, 直到下一次授权的安装; 2.3.26 第一次需要新配置的应用 (通常就是升级时的那一次) 完整安装一次, 同时装上第 5 版助手, 之后改域名就免密了。助手没有 / 不可信 / 拒绝时照旧退回完整安装 (操作记录 `同步策略规则 … err=no-helper|rejected`)。
- 测试: `tests/tunrules.sh` T3d (助手对 `site-*.json` 的接受 / 拒绝)、T5c (两个指纹各算什么)、T10 (真实的 `gen_config` / `apply_config` / `op_txn`: 改域名、自己的网站增删和改线路、恢复网站默认、后台任务都只经助手同步, 服务器变了走完整安装, 2.3.25 快照迁移, 系统代理模式热加载); `tests/enhanced.sh` (每个条目一个规则集、改域名配置不变)、`tests/tun-service.sh` 第 13 节 (完整安装带上 `site-*.json`, enana 的数据包通过 root 助手的检查)、`tests/enhanced-root-integrity.sh` (快照清单与 check-config)。

测试: `tests/tunrules.sh` (T3b 助手 `restart` 的接受 / 拒绝, T4b 记账内容与模式切换不重启, T5b 指纹, T6 重启走助手还是完整安装)、`tests/tun-service.sh` (安装后的助手写死标签 / launchctl 路径并真实执行)、`tests/enhanced.sh` (停止已停掉的守护进程不弹框)、`tests/units.sh` U8 (订阅就地刷新、一次应用)、`tests/sysproxy.sh` S6c2 (系统代理助手写死的端口与当前端口不一致时不信任)。

## 增强模式接管系统 DNS (2.3.27)

本机只读核对: LINE 不走系统代理, 经 TUN 连的是被污染的地址 (243.185.187.39 在 240/4 里, 还有 59.24.3.173、31.13.75.5、104.244.43.208 等), 自动和固定出口模式下二维码都加载不出来。系统 DNS 是路由器 (192.168.10.1 + fe80::10%en0): 私网和链路本地地址在 TUN 的 `route_exclude_address` 里, macOS 也优先用更具体的局域网路由, 查询根本不进 TUN, hijack-dns 一个包都没看到 (当天 24154 条 TUN 连接全是直接连 IP)。sing-box 1.14 的 TUN `dns_mode: hijack` 在苹果平台上只设置网卡自己的 DNS, 没有平台级的劫持 (那只有 Linux / Windows 有)。Windows 的 TUN 用 `strict_route` (WFP 挡住 TUN 之外的 53 端口), 不需要改, 也没有改。

现在 (只在 macOS 的 TUN, `lib/enhanced-root.sh` 的 `DNS_PL`):

- 接管: root 安装成功之后 (守护进程起来、已经提交), 每个启用的、有硬件网卡的网络服务 (`networksetup -listnetworkserviceorder`; 跳过 `(*)` 停用的、没有网卡的 VPN 服务, 以及设备是 utun / ipsec / ppp 一类隧道的) 的 DNS 设成 `223.5.5.5`。它是公网地址: 本机程序的查询走进 TUN, 由已有的 hijack-dns 规则交给核心 (海外域名经代理解析, 国内域名用国内 DNS), 不走系统代理的应用也拿到干净的结果。核心停了 / 崩了, TUN 的路由跟着没了, `223.5.5.5` 照样能直接用, 网络不会断。
- 记录: 改之前先把每个服务原来的设置 (`-getdnsservers`; 「There aren't any DNS Servers」= 自动, 记成 `Empty`) 写进 root 的目录 (`/Library/Application Support/enana-<uid>/dns-original`, root 所有、`0600`, 服务名存十六进制, 整份重写); 记录写成功了才改 DNS。重装时已经是 `223.5.5.5`、又记过的服务不重记, 原来的设置不会被 `223.5.5.5` 盖掉; TUN 开着时用户自己改过的, 下一次安装记下用户改的 (还原的总是 enana 最后一次改动之前的样子)。设置之后再读一遍, 读到的正是要的才算成功 (不靠 networksetup 的退出码)。
- 还原: 停止、删除 (卸载走的就是它)、安装失败回滚到「没有 TUN」时, 只还原现在正好是 `223.5.5.5` 的服务 (用户之后改过的不碰), `Empty` 还原成自动; 还原好的从记录里去掉, 读不出来 / 设置失败的留着下次再试, 记录空了就删掉。删除时先还原, 再删根目录。重装失败、旧的 TUN 被重新拉起来时照旧接管, 不还原; 第一次安装就失败时没有记录, networksetup 一次都不运行。
- 尽力而为: networksetup 失败、列不出服务, 只多一行 `enana-root: note: dns: …` (安装时在 `enhanced-check.log` 里, 停止 / 删除时在 `enhanced-root.log` 里), TUN 照常安装 / 停止, 不回滚。每次 networksetup 最多等 30 秒, root 不会卡住。
- 安全: 只有要管理员授权的安装 / 停止 / 删除会改系统 DNS; 没有新的管理员命令或免密规则, 免密的规则助手不碰它。networksetup 只用写死的 `/usr/sbin/networksetup`, 以列表形式直接 exec (不经过 shell), 服务名 (空格、中文、引号、`$(…)` 都可以) 只当数据。记录只认 root 自己的普通文件 (不跟符号链接, 组 / 其他人不可写), 根目录也必须是 root 的真目录; 不可信就不读、不还原, 只记一行。已有的检查一条没放松。
- 配置 (`lib/dns.sh` 的 `dns_tun_takeover`): TUN 下核心里没有 `local` DNS 服务器 —— 系统解析器现在指向 TUN, 再用它解析会绕回核心自己。用域名写的 DNS 服务器 (自定义的 DoH / DoT / UDP) 由直连的 UDP `223.5.5.5` (`dns-boot`) 引导解析; 国内 DNS 选「系统默认」时也是它 (就是接管之后的系统 DNS), 所以 `route.default_domain_resolver` (`dns-cn`) 也不会是 local。核心自己的连接绑在物理网卡上 (`auto_detect_interface`), 不进 TUN。系统代理模式和 Windows 的配置一个字节都不变。
- 升级: 2.3.27 改了 root 脚本和 TUN 配置 (指纹变了), 升级时本来就有的那一次授权安装顺带完成接管, 不多弹框。

已知的取舍:

- 只有路由器的 DNS 才解析得了的局域网名字 (例如 `nas.lan`、公司内网域名) 在 TUN 开着时解析不了 (查询交给了核心); 关掉 TUN 就恢复。
- 要网页登录的公共 Wi-Fi (酒店 / 机场) 在登录之前可能弹不出登录页 (手动的 223.5.5.5 和核心的 DNS 都出不去): 先关掉 TUN 登录, 再打开。
- 核心异常退出、系统又留下了指向已经不在的 utun 的残留路由时 (`tunrules-helper.pl` 的 `cleanup` 处理的就是这种), 公网流量本来就全断了, 223.5.5.5 也一样; 清掉残留路由就恢复。
- 接管之后才出现的网络服务 (新插的 USB 网卡) 要等下一次授权安装才接管; 切换「网络位置」只影响当前位置的服务。
- 退回 2.3.26 或更早版本时, 旧的 root 副本不认识记录: 系统 DNS 留在 `223.5.5.5` (照样能用, 只是不是原来的设置), 在系统设置里改回即可。

测试 (都在 CI 里跑, 假 networksetup 管一组假的网络服务, 绝不运行真的; 夹具里还留着 `/usr/sbin/networksetup` 就拒绝运行): `tests/tun-service.sh` 第 14 节 —— 安装时记下原来的再设置 (自动的 Wi-Fi、手动的 IPv4 + IPv6、名字带空格和中文、硬件端口带括号、名字里有 shell 代码), 停用的和 VPN 连查询都没有; 重装不盖掉记录; 停止 / 删除 / inband 停止还原; 用户之后改过的不还原; 重装时记下用户的改动; 回滚到没有 TUN 时还原、旧的 TUN 回来时不还原、第一次安装失败时不运行 networksetup; 设置全部失败 / 部分失败 / 列不出服务时 TUN 照常、只多一行说明; 还原失败的留着、之后删除时还原; 记录是符号链接或可写时不用。`tests/enhanced-root-integrity.sh` —— 拒绝时不改 DNS, networksetup 只有写死的绝对路径 (没有裸的命令名), 免密助手不碰 DNS, `check-config` 接受 `dns-boot`。`tests/enhanced.sh` —— TUN 配置没有 local 服务器、域名写的 DNS 服务器由 `dns-boot` 引导、「系统默认」的国内 DNS 是直连的 UDP 223.5.5.5, 系统代理模式和 Windows TUN 的 DNS 配置和以前一样。

本机验收: 开启 TUN 后 `networksetup -getdnsservers Wi-Fi` 显示 `223.5.5.5` (`scutil --dns` 的 resolver #1 也是它); LINE 的二维码能加载, 日志里 LINE 的连接带域名 (查询被 hijack-dns 接住了); 切回系统代理后 `networksetup -getdnsservers Wi-Fi` 回到原来的设置 (原来是自动的会显示 There aren't any DNS Servers)。
