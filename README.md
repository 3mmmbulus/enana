# enana

**一条命令装好代理环境,其余全部在浏览器仪表盘里完成。** · *One command sets up the proxy environment; everything else happens in a browser dashboard.*

基于 [sing-box](https://github.com/SagerNet/sing-box)。终端只做一件事 —— 安装环境;服务器、订阅、应用和网站的分流、DNS、测速、同步……全部在本机的仪表盘里。
本仓库是**本地客户端**(安装器、控制台命令、本地辅助服务、仪表盘界面),不含任何服务器地址、密码、订阅链接或节点 —— 这些都由你在仪表盘里填写,只保存在你的电脑上。

## 安装

在任意终端执行(会安装**最新版本**):

```bash
curl -fsSL https://install.enana.cc | bash
```

没有 curl? 用 wget:`wget -qO- https://install.enana.cc | bash`。安装脚本会自己检测下载工具(curl → wget)和校验工具,缺什么说清楚怎么办。

> **macOS** 现已支持。**Windows** 正在适配中(PowerShell:`irm https://install.enana.cc | iex`,目前只会提示「即将支持」)。

安装器会先**识别你的系统和网络**(macOS 版本、芯片、管理员权限、能否直连 GitHub、是否已有其它代理软件),给出推荐,你用键盘改选项:

```
 ❯ [✓] sing-box 核心 · 来源  ‹GitHub 官方包(多线路+校验)›  推荐
   [✓] 社区规则集 (国内直连 / 海外分流 / AI)               推荐
   [✓] 仪表盘 + 本地辅助服务                              (必装)
   [✓] 开机自启 + 崩溃自动重启                            推荐
   [✓] 每 3 天自动更新规则集 / 订阅                       推荐
   [✓] 设置系统代理 (需管理员密码)                        推荐
   [✓] 快捷命令 enana                                推荐
   ↑↓ 移动 · 空格/←→ 切换 · r 恢复推荐 · Enter 开始安装 · q 退出
```

- **重复运行安全**:已装好的部分会跳过;配置没变就不重启服务,系统代理已设置就不再要密码。
- **下载超时自动换线路**:直连 → 本地代理 → 你配置的备用代理 → 镜像;核心安装包有固定的 SHA-256 校验,镜像也无法替换成恶意文件。
- 加 `--yes` 全部采用推荐值(无人值守),`--force` 强制重装环境。升级:`enana self-update`(或再执行一遍安装命令)。

装完会**打印并自动打开后台地址** `http://127.0.0.1:<端口>/enana/admin/`(默认端口 9091;默认端口被别的程序占用时会自动换一个随机的空闲端口,地址里就是实际端口;以后输入 `enana open` 也能打开)。以后在**任何终端**输入 `enana` 就能打开命令行控制台:快捷命令优先放进 PATH 里已有的可写目录(装完马上能用),否则写进 `~/.local/bin` 并在 shell 配置里加 PATH(重开终端生效)。

## 账号与代理开关

- 后台用 **enana 账号**(邮箱 + 密码)登录;登录页和注册页是两个独立的页面(`/enana/admin/login`、`/enana/admin/register`,页面里互相链接,语言切换在右上角),可以直接注册;账号只存邮箱和密码哈希,**代理数据一概只在本机**。
- 同一账号**同一平台最多同时在线 2 台设备**;第 3 台登录时会列出在线设备,可以下线其中一台后自动登录;被下线的设备会自动退出并关闭代理。
- **代理默认是关闭的**(所有流量直连,不经过任何代理服务器):登录后在仪表盘里手动打开「代理」总开关,再选 **自动模式**(国内直连、海外按策略分流)或 **全局代理**。**退出账号会自动关闭代理。**
- 删除服务器、查看凭据、导出备份、清日志、下线设备这类敏感操作,即使已登录也要**再输入一次账号密码**。

## 仪表盘能做什么

| 页面 | 功能 |
|---|---|
| 概览 | 本机 IP / 出口 IP(含是否被限制的提示)、实时速度与延迟、环境状态、代理总开关与模式 |
| 应用 | 自动识别已安装的应用(含系统自带的「终端」等)并显示真实图标;每个应用可设:跟随规则 / 直连 / 固定出口(有 2 个以上固定出口时可指定其中一个,或在其中自动选)/ 自动线路。新装应用默认「关」,浏览器默认「开」;支持添加自定义软件(先校验再确认) |
| 网站 | Claude / ChatGPT / Gemini / TikTok / YouTube …… 每项一个开关(固定出口可指定);顶部标签区分「全部 / 我添加的 / 自动识别」,左侧是分组导航;域名在弹窗里一行一个,可添加 / 修改 / 删除,并一键恢复系统默认;可选开启「自动识别打不开的网站并加入代理」(默认关闭) |
| 服务器 | 添加或批量导入服务器 —— 订阅链接、分享链接(trojan / hysteria2 / tuic / vless / vmess / ss / http / socks)、Clash / sing-box 配置自动识别;**用 SSH 一键部署你自己的服务器**(见下) |
| 规则库 / DNS | 社区规则集开关与自定义;DNS 预设(DoH / DoT / UDP)、自定义解析(hosts)、DNS 测速、泄漏防护、屏蔽广告 |
| 测速 | 本地直连与多个节点对 100 个内置目标测延迟和下载速度;目标可增删改并一键还原;结果标出「受限 / 失败」 |
| 流量 | 今日 / 3 天 / 7 天 / 1 个月 / 3 个月的用量,按 直连 / 固定出口 / 自动线路 / 节点 分类;只存在本机,超过 3 个月自动清除 |
| 连接与日志 | 实时连接列表(应用、走向、命中的规则);三类日志各有独立开关:操作记录(谁 / 什么时候 / 从什么改成什么)、网站访问(每条连接的应用、出口、**为什么直连**、失败原因,代理关闭时也记录)、代理日志;保留 12 小时 – 30 天(默认 3 天);筛选 / 概览 / 搜索 / 实时;**一个「导出」按钮**,勾选内容后生成一份自描述的诊断文件([格式](docs/DIAGNOSTICS.md)) |
| 设置 | 语言(中 / 英)、代理、云端同步、日志、更新、账号与设备、套餐 |

### 三条线路

- **固定出口**:AI(Claude / ChatGPT / Gemini …)、账号类 App(TikTok / Telegram …)走它。只含你指定的服务器,**故障时不会漂移到别的国家 IP**(避免账号风控)。
- **自动线路**:Google、YouTube、X 等被封锁的网站。在「自动池」里选最快的节点,**只有别的节点比当前节点快 50 ms 以上才会切换**,避免来回跳。
- **直连**:国内网站(社区规则集 `geosite-cn` / `geoip-cn`)、Apple、局域网。

没配置任何服务器时所有流量直连,不会因为空配置断网。

### 用 SSH 一键部署你自己的服务器

在「服务器」里填 **IP / 端口 / 用户名 + 密码或私钥**:enana 通过 SSH 连上你的服务器,检测系统与依赖(**Debian 11 / 12 / 13、Ubuntu 20.04 / 22.04 / 24.04**,x86_64 与 arm64),弹窗让你确认要安装什么,然后自动安装依赖和服务端、生成节点、**识别服务器的全部出口 IP(每个 IP 一个节点)**、在本机真实验证后加进列表。

- **SSH 密码 / 私钥只在本次任务期间存在于一个 600 权限的临时文件里,任务结束立即删除** —— 不进命令行、日志、同步,也不会保存。
- 主机指纹先给你确认,之后固定校验(指纹变了会拒绝连接)。
- 在服务器上执行的部署脚本由 enana 云端下发并验签(登录后可用),所以云端换协议或升级服务端版本时,本机不用升级。

### 云端同步(端到端加密)

添加服务器时有一个「**保存到云端**」勾选(默认勾选):勾选的服务器和订阅才会进入云端同步;登录同一账号的另一台电脑**登录后自动取回**(合并进本机,不覆盖已有的;在设置里明确关闭过同步的不会自动取回)。同步内容还包括应用 / 网站策略、DNS、偏好等(**SSH 凭据、端口、代理开关、令牌永不同步**;老版本添加的、没勾选过的服务器只在本机;导出备份仍包含全部)。数据在本机用「由账号密码派生的密钥」加密后才上传,**enana.cc 只看到密文**;密钥只在登录时派生并保存在本机,退出账号即删除。

## 命令行:`enana`

```
enana                打开控制台:运行状态、一键重启 / 开关代理 / 更新 / 日志 / 诊断 / 退出账号 / 卸载
enana status         查看状态          enana restart     重启服务
enana on | off       开启 / 关闭代理 (开启需要已登录)
enana update         更新规则集与订阅   enana upgrade     升级 sing-box (先校验现有配置)
enana self-update    升级 enana 本体    enana logout      退出账号 (自动关闭代理)
enana doctor         诊断信息(不含密码,反馈问题时贴出来)
enana diag [小时]     导出诊断文件(操作记录 + 网站访问 + 代理日志 + 当前状态,同仪表盘「导出」)
enana env            终端代理变量:eval "$(enana env)"   (命令行工具不读系统代理)
enana uninstall      卸载 (--keep-data 保留数据)
```

## 安全与隐私

- 仓库与脚本里**没有任何敏感信息**。服务器、订阅、SSH 凭据只在你的电脑上(`~/.enana/`,权限 600);云端从不收到它们(见 [docs/CLOUD_API.md](docs/CLOUD_API.md) 里「客户端向云端发送的全部内容」)。
- 本地辅助服务只监听 `127.0.0.1`,校验 `Host`、要求自定义请求头 `X-Enana` 和登录令牌、CORS 只放行仪表盘自己的来源,所有参数先白名单校验;敏感操作要二次验证密码。
- 配置**先校验再应用**:改服务器 / 订阅 / DNS 等时在同一把锁里「备份 → 修改 → 校验 → 重启 → 失败自动回滚」,坏配置不会留在磁盘上。
- 核心安装包按 `data/core-pins.conf` 校验 SHA-256;云端下发的内容(服务目录、规则库清单、部署脚本)先验 ECDSA 签名、防回滚、校验哈希与文件名白名单。
- 精选内容和部署脚本在云端,登录后下发;仓库里只有最小可用的基线。设计说明见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 开发

```bash
bash tests/run.sh                  # 约 700 条测试: 在隔离目录里完整跑一遍 (需要一个 sing-box 二进制: SINGBOX=/路径/sing-box)
bash tests/units.sh                # 几秒钟的单元测试: 日志解析 / 自动识别 / 保留期 / 应用扫描 / 规则集拆分 / 诊断导出 (不需要 sing-box; run.sh 末尾也会跑)
python3 tools/i18n-verify.py       # 检查英文译文覆盖了所有会显示给用户的中文提示
bash tests/get-test.sh [发布目录]    # 一行安装命令 (get.sh) 的整条链路: 首次安装 / 篡改拦截 / 两线路交叉校验 / 升级 / wget / 端口占用自动换 / 快捷命令; 全部用本机模拟的下载服务
```

测试全部使用占位数据,「互联网」「enana.cc 账号服务」「自己的服务器」都是本机的模拟服务(`tests/mock-*.py`、本机 sshd),不产生任何外部流量。

| 文档 | 内容 |
|---|---|
| [docs/API.md](docs/API.md) | 仪表盘 ↔ 本地辅助服务的接口契约(前后端的唯一约定) |
| [docs/CLOUD_API.md](docs/CLOUD_API.md) | 本地客户端 ↔ enana 云端的接口,以及客户端会向云端发送什么 |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 三部分架构、云端内容、配置快照与同步、账号与设备 |
| [docs/DIAGNOSTICS.md](docs/DIAGNOSTICS.md) | 诊断导出文件的格式、各分区与列的含义、直连原因表、排查套路 (`tools/diag-summary.py` 可自动解读) |
| [docs/ROADMAP.md](docs/ROADMAP.md) | 路线图 |
| [CHANGELOG.md](CHANGELOG.md) | 更新日志 |
| [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) | 第三方声明 |

---

## English summary

**enana** installs a [sing-box](https://github.com/SagerNet/sing-box) proxy environment with one command and gives you a local browser dashboard for everything else (per-app / per-site routing, DNS, speed tests, traffic statistics, sync, one-click SSH provisioning of your own VPS). Install (macOS now, Windows in progress):

```bash
curl -fsSL https://install.enana.cc | bash
```

- Sign in with an enana account (at most 2 devices per platform). The proxy is **off by default**; turn it on in the dashboard, choose Auto (rule-based) or Global mode. Signing out turns it off.
- Server addresses, passwords, subscription links and SSH credentials **never leave your computer**; optional cloud sync is end-to-end encrypted (the key is derived from your password locally), and SSH passwords / private keys are never stored or synced.
- Sensitive actions re-ask for your password. Configuration changes are validated and rolled back automatically if they fail.
- Logs: operations / site access / proxy log each have their own switch (12 hours – 30 days retention); every connection shows the app, the exit and *why* it went direct. One export button (or `enana diag`) produces a self-describing diagnostics file — see [docs/DIAGNOSTICS.md](docs/DIAGNOSTICS.md).
- This repository is the local client. The curated content (service catalog, rule-library list, server provisioning scripts) is delivered from the enana cloud after sign-in as signed bundles.

See `docs/` for the API contracts and architecture; run `bash tests/run.sh` for the test suite.
