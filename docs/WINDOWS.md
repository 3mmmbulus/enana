# Windows 预览版 (2.3.2)

Windows 与 macOS 共用本机仪表盘、账号/设备 API、服务器管理、应用/网站分流、PIN/Global/direct、DNS、测速、日志和事务回滚。系统适配不另写一份分流引擎。

## 安装与升级

支持 Windows 10 2004 (build 19041)+ / Windows 11、x64 和 ARM64, 使用 64 位 PowerShell 5.1 或更高版本。无需 WSL 或预装 Git/Node。

```powershell
irm https://install.enana.cc/get.ps1 | iex
```

普通 PowerShell 窗口即可安装。默认目录 `%LocalAppData%\enana`, 下载可重试 3 次, 清单/包大小/SHA-256 与 ZIP 路径全部检查通过后才执行安装。安装会自动选择空闲端口并打开本机后台, 不会打开代理总开关。登录、添加服务器后再由用户开启代理。

2.3.1 修复了官网无参数命令的 `Lang` 默认值校验错误: 默认 `auto` 按系统语言选择中文或英文。无需通过执行策略 Bypass 解决该参数错误。2.3.2 进一步清理重复安装产生的分离任务, 避免升级 / 卸载时 Bash 占用私有运行时。

新终端输入 `enana` 打开仪表盘; `enana doctor` 查看状态, `enana diag` 导出同一格式的诊断日志。`enana self-update` 或再次执行安装命令升级, 保留端口、账号、服务器和模式。已有安装失败会恢复程序/配置并重新启动原服务。快捷命令写入当前用户 PATH, 不改机器 PATH。

安装包清单是 `https://install.enana.cc/dl/windows-manifest.json`, 包为 `enana-<version>-windows.zip`。与 macOS 的 `manifest.json` / tar.gz 分开, 防止旧客户端误下载另一平台的包。Windows 清单明确标记 `channel=preview`。

## 两种接管模式

| 模式 | 接管范围 | 权限 |
|---|---|---|
| System Proxy (默认) | 当前用户遵守 WinINet HTTP/HTTPS 代理的连接; mixed 仅监听 127.0.0.1 | 普通用户 |
| Enhanced/TUN (可选) | sing-box TUN 接管公网 TCP/UDP, 包括自行连接的应用 | UAC 管理员授权 |

在「设置 → 代理 → 流量接管方式」选择模式, 或使用 `enana network-mode tun` / `enana network-mode system`。切换有确认、进度、就绪验证和失败恢复。取消 UAC 保留原服务; 选择 TUN 不代表代理总开关已打开。自动/全局仍是路由策略, 与流量接管方式分别设置。

System Proxy 开启前备份 WinINet 手动/PAC/连接设置; 关闭时只恢复仍属于 enana 的设置。用户或其它代理修改后保留外部设置, 不强行覆盖。不会设置机器 WinHTTP 代理或劫持其它用户会话。

TUN 包含 IPv4/IPv6, 排除 localhost/127.0.0.0/8/::1、局域网/私网/链路本地和自身地址; 核心出口通过默认物理接口发出, 防止循环。就绪检查同时验证拥有的核心、适配器地址、公网双栈路由和 localhost 仍直连。与 VPN、虚拟网卡共用需要实机验收。

原生应用明确 PIN 高于网站; 浏览器策略作为网站规则后的兜底。EXE 所在应用目录中的辅助进程匹配同一规则, Squirrel `app-<version>` 更新不会丢失匹配。Windows/Program Files/WindowsApps 等共享目录只匹配选定 EXE, 防止将其它应用误设为 PIN。

只有被接管且能归属到应用的公网 TCP/UDP 可以继承应用 PIN。localhost/LAN、共享系统进程和无法归属的请求不能声明为该应用「全部流量」。这里没有 Gemini OAuth 域名补丁。

## 本机服务与管理员快照

- `windows/install.ps1` 下载 `runtime-pins.json` 中固定 SHA-256 的官方 PortableGit、Node 和 sing-box, 保留上游许可证, 放在私有目录。
- 当前用户的 `Enana Dashboard <SID>` 计划任务以 Limited 权限运行 `worker.js`, 只监听 127.0.0.1。HTTP 请求通过管道交给现有 `lib/api.sh`, 保留 Host/Origin/X-Enana/登录校验, 增加头/体大小、并发和超时边界。
- 普通 worker 管理自己的 System Proxy 核心、tick/维护任务, 不作为 SYSTEM 执行用户脚本。停止或升级只关闭当前安装拥有的进程。
- Enhanced 的 `Enana Enhanced <SID>` SYSTEM 任务仅运行 `%ProgramData%\enana\<SID>` 中管理员拥有、用户只读的核心/脚本/配置/规则快照。ZIP 复制到受保护目录后重新验证固定哈希并解压, 不直接提升用户可写的 sing-box.exe。快照只允许本机监听和受保护的文件路径。
- 更新 TUN 规则/节点或切回轻量模式需要 UAC, 失败恢复原快照和任务。没有密码落盘、sudoers 或永久任意命令提权接口。

固定核心版本改变时必须同时审核 `runtime-pins.json` 与 `tun.ps1` 的授权哈希。Windows 不接受任意核心版本提升为 SYSTEM; 先升级 enana 到审核过该核心的版本。

## 自动测试与实机验收

`tests/windows-helper.test.js` 与 `tests/windows-routing.sh` 覆盖原规则生成器、Windows 路径与辅助 EXE、PIN/网站/浏览器优先级、双栈排除、HTTP 字节边界和实际 UDP DNS 往返。Mac 回归继续验证共享逻辑。

`.github/workflows/windows.yml` 在原生 Windows / PowerShell 5.1 上执行 `tests/windows-native.ps1`: 安装真实运行时和核心、启动后台、调用真实 Bash API、鉴权拒绝、两种模式配置校验、二次安装、WinINet 恢复/外部修改保留、安全 ZIP、诊断、干净停止和完整卸载。它不代替交互 UAC、TUN 接管或应用 OAuth。

`.github/workflows/windows-download.yml` 从官网获取发布清单、脚本与 ZIP, 在新建的 Restricted 与 Bypass 子进程中原样执行 `irm https://install.enana.cc/get.ps1 | iex`, 验证默认语言、安装、重复安装、后台、核心配置及卸载。该验收不传入 `-Lang` 或 `-NoOpen`, 以覆盖用户实际入口以及浏览器打开后触发的后台任务。版本号或 Windows 运行时变化也会触发它。分离任务清理只针对本安装私有目录下且属于当前用户 SID 的进程, 清理前复核进程路径和创建时间, 保留其它程序。

2.3.0 预览的 [Windows 原生 CI](https://github.com/3mmmbulus/enana/actions/runs/37122396091) 已在 Windows Server 2025 x64 / PowerShell 5.1 上通过; 共享 macOS 回归 791 项通过。Windows 10/11 客户端、ARM64、交互 UAC/TUN 和原生应用登录仍保留下面的实机验收。

Windows 实机请验收:

1. 安装、登录、导入节点并打开代理; Chrome/Edge 自动线路和指定网站 PIN 按规则生效。
2. 切换 Enhanced/TUN, 接受 UAC; 检查就绪、非显式代理 TCP/UDP/IPv6、localhost OAuth 回调、局域网和实际出口。
3. 将已安装的 Gemini/Claude/ChatGPT 设为 PIN, 确认主程序及辅助进程出口、OAuth token 交换和已登录界面。浏览器显示授权完成并不等于 App 登录成功。
4. 拒绝 UAC/故意使用失败配置、切回 System Proxy、停止/重启 Windows; 验证恢复与网络可用, 并检查已有 VPN 共存。
5. 导出仪表盘诊断或运行 `enana diag`; 错误时附诊断、Windows 版本和重现步骤。

Windows 诊断包含模式、任务/接口归属、代理状态和 PIN 主程序/辅助进程的公网 TCP socket。`possible_system_proxy_bypass` 是绕过候选, 不是证明; Windows 普通 TCP 快照无法得知 UDP 远端, 日志明确写 `udp_remote_visibility=unavailable-on-Windows`, 不将没有采样到连接宣称为没有泄漏。

## 下载站发布

`tools/build-release.sh OUTPUT_DIR` 从明确允许的程序文件构建包, 不包含本机账号、节点、缓存、SSH 密钥或服务器项目。Windows ZIP、清单和更新日志独立发布; macOS 稳定渠道继续保留 2.2.2, 避免 Windows 预览触发 Mac 自动升级。

现有下载主机使用 `tools/deploy-windows-release.sh RELEASE_DIR WEBSITE_DIR 2.3.2`: 先验证包的大小、哈希、版本和入口, 只替换 Windows 下载文件及官网 `index.html` / `site.js`, 清单最后发布。脚本保存回滚备份, 对比稳定 macOS 文件、全部运行服务的 PID/启动时间及 nginx/systemd 配置, 发生变化则撤回本次发布。无需重载 nginx 或修改其它项目。
