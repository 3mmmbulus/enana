# 诊断导出文件 (v2.3.0; 2.3.8 起带自动判定和连接健康记录)

「日志 → 导出」(仪表盘) 和 `enana diag` (终端) 生成的是**同一份**自描述文本文件, 目的是: 用户遇到「网站打不开 / 走错出口 / 应用没识别 / 代理时好时坏」时, 把这一个文件发给开发者 (或任何会读它的人 / 工具), 不需要再来回追问「你当时怎么设置的、哪个应用、哪个节点」。

- 编码 UTF-8, 纯文本, 一个文件包含全部内容; 格式版本 `format=1` (以后加列只会加在行尾, 不改已有列的含义)。
- 不含密码 / 令牌 / 服务器凭据; 服务器地址与系统用户名已打码。**包含**访问过的域名和应用名 —— 只发给你信任的人。
- 导出本身会写一条操作记录 (「导出诊断日志」), 不会改动任何设置。

## 怎么导出

| 入口 | 做法 |
|---|---|
| 仪表盘 | 「日志」页右上角「导出」→ 弹窗里勾选 **操作记录 / 网站访问 / 代理日志 / 环境与策略快照** (默认全部勾选) 和时间范围 (最近 6 小时 / 24 小时 / 全部保留的) → 下载 `enana-diagnostics-<日期-时间>.txt` |
| 终端 | `enana diag [小时数 1–720 \| all]` (默认 24)。直接在终端运行会把文件存到 `~/Downloads` 并打印路径; 接管道时输出到标准输出: `enana diag 6 \| pbcopy` |
| 接口 | `GET /api/logs/bundle?hours=24&sections=ops,access,proxy,snapshot` (见 [API.md](API.md)) |

「环境与策略快照」(`snapshot`) 对应 env / config / policy / servers / apps / probes / live 七个分区 —— 排查「为什么这样走」靠的就是它们, 建议保留勾选; `meta` 分区永远带上。

## 文件结构

`probes.via=proxy` 表示显式使用本机 HTTP 代理; `direct` 表示 System Proxy 下不显式使用代理; `tun` 表示 Enhanced 下不显式使用代理但仍受 TUN 接管。`curl --noproxy` 无法绕过 TUN, 不能把增强模式下的这组结果当作物理网卡直连结果。

```
#ENANA-DIAGNOSTICS format=1
#generated=2026-10-03 10:15:00 tz=+0800 app=enana version=2.1.1
#range since="2026-10-02 10:15:00" hours=24 days=2026-10-02,2026-10-03
#sections=meta,env,config,policy,servers,apps,probes,live,ops,access,proxy
#about=…  #privacy=…  #route-reasons=…          ← 以 # 开头的行是说明
@@SECTION meta format=kv rows=33
key=value
…
@@SECTION ops format=tsv rows=120
ts<TAB>who<TAB>action<TAB>detail<TAB>result      ← tsv 的第一行是列名, 制表符分隔
…
@@END
```

- 每个 `@@SECTION <名称> format=<kv|tsv|text|raw> rows=<行数>` 开始一个分区, 到下一个 `@@SECTION` 或 `@@END` 结束。
- `kv` = 每行 `键=值`; `tsv` = 第一行列名; `text` = 带说明的文本行; `raw` = 原始日志行。
- 分区缺失 (用户没勾选) 就不会出现; `rows=0` 表示导出时确实没有数据 (例如关闭了「记录网站访问」) —— **「没有记录」和「没有开记录」要区分: 看 `meta` 里的 `settings.*`**。

## 分区一览

| 分区 | 格式 | 内容 |
|---|---|---|
| `verdict` | kv | **自动判定 (2.3.8)**: `verdict.cause` (原因) / `verdict.blame` (归因: `client` 本机设置 · `node` 服务器 · `exit-ip` 出口 IP 被 OpenAI 等限制 · `network` 本机网络 · `none`) / `verdict.confidence` / `verdict.since` / 中英文摘要 `verdict.summary.zh|en`, 以及证据: 每个节点的可达率 (`verdict.node.<名称>`)、每个探测目标的成功率 (`verdict.canary.<名称>`)、故障时段 (`verdict.outage.N`)、ChatGPT / OpenAI 连接汇总 (`verdict.chatgpt*`)、当前状态 (`verdict.now.*`)、最近一次关闭总开关是谁 / 什么时候 (`verdict.last_proxy_off`)。`cause` 取值见下面「自动判定」。 |
| `meta` | kv | 版本 / 核心 / 系统 / 语言 / 时区 / 服务是否运行 / **代理总开关与模式** (`proxy.enabled`, `proxy.mode`, `clash.mode`) / 三个日志开关与保留时长 (`settings.log_ops`, `settings.access_log`, `settings.log_core`, `settings.log_hours`) / 自动识别 (`settings.auto_sites`) / 端口 / 服务器数量 (`servers.pin` 固定出口, `servers.auto` 自动线路) / 账号与云端内容版本 |
| `env` | kv | **系统代理是否指向 enana** (`sysproxy.points_to_enana`) 与原始系统代理设置 / 系统 DNS / 默认网卡与网关 / 是否检测到其它代理软件 / 四个端口被谁占用 (`listen.<端口>`) / 核心进程运行时长与内存 / 磁盘与日志占用 / `config.check` (配置是否通过 sing-box 校验) / 辅助服务日志里最近的错误 |
| `config` | text | 脱敏后的**运行配置**: `log` / `clash_api` / `inbound[i]` / **`rule[i]` 路由规则 (按顺序, 先匹配先生效)** / `ruleset` / `outbound` (选择器与 direct-* 出口) / `server` (服务器只保留类型、打码地址、端口、TLS/SNI/传输) / `dns.*` |
| `policy` | text | 此刻生效的策略: 每个选择器 (`selector tag=… now=…`) 当前选了谁 / 你对应用与网站的覆盖 (`overrides.tsv`: `类型\|名称\|状态\|标记\|出口`) / 自动识别添加的网站 (`autosites.tsv`) / 自定义规则集、域名、应用、hosts、DNS |
| `servers` | tsv | `tag type host(打码) port role sub` —— `role` 为 `pin` (固定出口) / `auto` (自动线路) |
| `apps` | tsv | `name state flag target known rec group path` —— 已识别的应用及其当前设置 (见下方「应用状态」) |
| `probes` | tsv | **实时自检** (最多 8 秒): 同一批网站分别「经过代理」和「直连」访问的 HTTP 状态 / 连接与总耗时 / 远端 IP; 以及系统 DNS 与核心 DNS 对 `www.google.com` 的解析对照 (污染一眼可见) |
| `live` | tsv | 此刻核心里还开着的连接 (最多 60 条, 按下载量): `start net host port app chain rule up down` —— `chain` 是实际走过的出口链, `rule` 是命中的规则 |
| `health` | tsv | **连接健康记录 (2.3.8)**: `ts kind target result ms detail`, 每分钟一批, 最多最近 6000 行; 见下面「连接健康记录」 |
| `health_summary` | tsv | 健康记录分桶统计: `bucket kind target n ok fail ms_avg ms_max errors` (范围 ≤ 24 小时 10 分钟一桶, ≤ 72 小时 30 分钟, 更长 1 小时) |
| `outages` | tsv | 连续失败的时段: `start end minutes kind target result samples` (服务器端口至少连续 2 分钟, 经代理探测至少连续 2 次) |
| `ops` | tsv | **操作记录**: `ts who action detail result` |
| `access` | tsv | **网站访问** (一条连接一行): `ts id net host port app user route node reason result err dur ips errmsg path` |
| `proxy` | raw | **代理日志** (核心原始日志, 去掉颜色码, 用户名打码) |

## 操作记录 (`ops`)

- `who`: `dashboard` (仪表盘里的操作) / `terminal` (终端命令) / `auto` (系统自动做的: 定时更新、自动识别、发现新应用 …)。
- `action` 是一句话 (中文, 导出文件里不翻译, 保持稳定); `detail` 是 **`键=值` 列表** —— 这才是机器可读的部分。会改变路由结果的动作及其 `detail`:

| `action` | `detail` 例子 | 说明 |
|---|---|---|
| `开启代理` / `关闭代理` / `切换代理模式` | `enabled=1 mode=auto was_enabled=0 was_mode=auto` | 代理总开关 / 自动 · 全局模式 |
| `修改应用/网站策略` | `kind=site name=chatgpt.com from=follow to=pin target_from= target_to=Fix-Pin src=` | **应用 / 网站的设置**: `kind=app\|site`; `from` `to` ∈ `follow direct pin auto`; `target_*` 是指定的固定出口 (`PINAUTO` = 在固定出口里自动选); `src=auto` 表示这个网站原本是自动识别添加的 |
| `切换策略` | `kind=selector tag=svc-chatgpt site=chatgpt.com from=Global to=PIN` | 在「网站」页直接切换某个服务的出口 (选择器 `tag` 从 `from` 改成 `to`) |
| `采用推荐设置` | `scope=selected count=3` | 「应用」页采用云端推荐 |
| `发现新应用` | `count=3 names=Foo,Bar,Baz default=direct×2,follow×1` | 扫描发现新装应用 (`auto`); `default` 是它们各自拿到的默认状态及个数 (新装应用默认 `direct`, 浏览器默认 `follow`) |
| `修复浏览器的默认设置` | `count=1 names="Google Chrome" from=direct to=follow why=…` | 升级时把 2.1.0 误设成直连 (标记 `new`, 你没处理过) 的浏览器改回跟随规则 |
| `识别已安装的应用` | `count=40 scan_v=2 browsers=2` | 首次 / 扫描范围变大后的识别 (这些不算「新应用」, 不弹提示); `browsers` 是默认跟随的浏览器数 |
| `自动识别: 添加网站到代理` | `domain=x.example state=pin fails=3 attempts=1 err=timeout app=Google Chrome was=follow verify=http=200 480ms` | 自动识别把一个打不开的网站加进了代理, `verify` 是加完后经过代理的验证结果 |
| `自动识别: 放弃网站` / `自动识别: 全部撤销` | `domain=… verify=no response through proxy` / `count=2` | 经过代理也打不开所以放弃 / 用户一键撤销 |
| `断开连接` | `scope=all\|one\|host count=12 host=` | 「连接」页手动断开 |
| `修改设置` | `setting=log_hours from=72 to=168` / `setting=ACCESS_LOG from=1 to=0` | 日志保留 / 三个日志开关 / 自动识别 / 自动更新 / 语言 |
| `导入服务器` `删除服务器` `修改服务器角色` `删除订阅` `订阅「…」刷新` | `tag=… role=…` `tag=… from=auto to=pin` | 服务器与订阅 |
| `启用/停用规则集` `添加规则集` `删除规则集` `修改 DNS 设置` `修改自定义解析` `修改网站域名` `添加自定义软件` … | `rule=… enabled=0` … | 规则库、DNS、网站域名、自定义软件 |
| `更新规则集` `升级核心` `更新 enana` `自动更新` `重启服务` `应用配置` `更新云端内容` | 版本 / 结果 | 更新与重启 |
| `登录` `登录失败` `退出账号` `下线设备` `二次验证` … | — | 账号 (不含密码或令牌) |
| `开启系统代理` / `关闭系统代理` | `method=direct port=7890 mode=system` / `err=user-canceled` | 系统代理的每一次修改 (2.3.8 起仪表盘也能开): `method` = `already direct sudo sudo-nopass dialog user`; 失败时 `err` = `user-canceled wrong-password not-admin no-gui-session not-authorized backup-failed no-network-service not-applied failed machine-policy`, 结果 `error` |
| `环境状态变化` | `item=sysproxy from=1 to=0 capture=system` | **来源 `auto`**, 由每分钟的健康检查发现: `item` = `core_running` `core_api` `proxy` (总开关) `sysproxy` `login` `tun_ready` `capture_mode` `net_if` `net_gw` (默认网络接口 / 网关变了) —— 回答「什么时候开始不对的」 |
| `核心进程已重启` | `old_pid=4001 new_pid=4002` | 核心进程 PID 变了 (崩溃后被 launchd 拉起 / 手动重启); 同时看 env 里的 `service.runs` / `service.last_exit_code` |
| `会话心跳失败` / `会话心跳恢复` | `http=000 note=…` / `down_s=612` | 本机连不上 enana 云端 (只在开始和恢复时各记一次; 离线超过 7 天会被自动退出登录) |
| `已被退出登录` | `reason=kicked http=401 proxy_was=1` | **来源 `auto`** (2.3.8 起; 以前误记为 terminal, 详情也不是 key=value): 云端撤销了会话 (`kicked` 被同账号其它设备下线 · `limit` 超过设备数 · `expired` · `logout`) 或离线超过 7 天 (`offline_expired`)。**本机会随之关闭代理 (全部直连)**, 重新登录后总开关仍是关闭的 |
| `开启代理` / `关闭代理` (来源 `terminal`) | `enabled=1 via=console` | 终端 / 控制台里改总开关 (以前不留记录) |
| `导出诊断日志` / `清除日志` | `hours=24 sections=ops,access,proxy,snapshot bytes=…` / `type=all before=… freed=…` | 日志本身的操作也会留痕 |
| `服务器检测重试` / `取消服务器检测` | `attempt=1 max=3 code=E_SSH_UNREACHABLE` / `id=vps-probe-…` | 只读检测的重试与取消; 实时阶段和耗时见任务接口 `result.connection`, 不包含 SSH 凭据 |

- 排查「为什么昨晚突然不走代理了」: 先看 `ops` 里的时间线 (**谁、什么时候、把什么从什么改成了什么**), 再对照 `access` 里同一时间之后的 `route` / `reason`。
- `result=error` 的操作, `detail` 里会带原因。

## 网站访问 (`access`)

核心日志里一条连接会拆成好几行 (进站 / 进程 / DNS / 出站 / 错误), 这里按连接编号合并成**一行**:

| 列 | 含义 |
|---|---|
| `ts` | 连接开始时间 `YYYY-MM-DD HH:MM:SS` |
| `id` | 核心里的连接编号 (同一时段内唯一) |
| `net` | `tcp` / `udp` |
| `host` `port` | 访问的域名 (没有域名时是 IP) 与端口 |
| `app` `user` `path` | 发起连接的应用名 / 系统用户 (打码) / 可执行文件路径 (用户名打码)。**浏览器的网页流量属于浏览器进程**, 所以看到的是 Google Chrome 而不是网站 |
| `route` | `direct` (直连) / `proxy` (经过代理) / `none` (连接在选出口前就结束了, 例如被拒绝) |
| `node` | 实际使用的出口名: `direct-*` 或服务器节点名 |
| `reason` | **直连的原因** (仅 `route=direct`), 见下表; 走代理时为空 |
| `result` | `ok` / `error` |
| `err` `errmsg` | 失败类型 (`timeout` `refused` `reset` `unreachable` `dns` `tls` `eof` `rejected` `other`) 与原始错误信息 |
| `dur` | 核心记录的耗时 (毫秒) |
| `ips` | 核心 DNS 解析出的地址 —— 对照 `probes` 里的系统 DNS 可以判断 **DNS 污染** |

### 直连原因 (`reason` ← 出口名)

| 出口名 | `reason` | 含义 | 常见处理 |
|---|---|---|---|
| `direct-mode` | `mode` | 代理总开关关闭, 或核心处于「直连」模式 | 在仪表盘打开代理总开关 |
| `direct-lan` | `lan` | 本机 / 局域网 / 私有地址 | 正常 |
| `direct-site` | `site` | 你把**这个网站**设成了直连 | 「网站」页改成代理 / 跟随 |
| `direct-app` | `app` | 你把**这个应用**设成了直连 (「关」), 包括新装应用的默认值 | 「应用」页改成「开」 |
| `direct-cn` | `cn` | 命中国内规则 (geosite-cn / geoip-cn), 自动模式下国内站直连 | 正常; 若该站其实需要代理, 在「网站」页指定 |
| `direct` | `policy` | 策略 (网站开关 / 默认出口 / 选择器) 选了直连 | 看 `policy` 里对应选择器的 `now=` |

> 规则按顺序匹配、先匹配先生效, 实际顺序见 `config` 分区的 `rule[i]`: 测速 → 自定义解析 → 直连模式 (`direct-mode`) → 本机 / 局域网 (`direct-lan`) → **网站直连** (`direct-site`) → **应用直连** (`direct-app`) → 指定的固定出口 (每个固定出口一条) → `PINAUTO` → 默认固定出口 `PIN` → 自动线路 `Global` → 广告拦截 → 服务目录里的各服务 (`svc-<id>` 选择器) → 全局模式 → 自定义规则集 → 国内规则 (`direct-cn`) → 非国内 → 解析后按 IP 再判国内 → 默认出口。

## 应用状态 (`apps` / `policy` 的 `overrides`)

| 列 | 含义 |
|---|---|
| `state` | `follow` 跟随规则 (= 界面里的「开」) / `direct` 直连 (= 「关」) / `pin` 全部走固定出口 / `auto` 全部走自动线路 |
| `flag` | `new` 新发现、用户还没处理 / `ack` 用户设置过或已知晓 / `def` 首次扫描时按云端推荐给的默认值 (用户没动过, 云端推荐更新后会刷新) |
| `target` | 只对 `pin` 有意义: 空 = 默认固定出口; `PINAUTO` = 在多个固定出口里自动选一个; 否则是指定的某一个固定出口 (固定出口 ≥ 2 个才可以指定; 被删除时回落到默认) |
| `known` `rec` `group` | 云端内容里是否认识这个应用 / 推荐设置 / 分组 (浏览器、终端、开发工具 …) |

## 自动给出判断: `tools/diag-summary.py`

```bash
python3 tools/diag-summary.py enana-diagnostics-20261003-101500.txt
python3 tools/diag-summary.py <文件> --app "Google Chrome" --host google.com
```

只用标准库、不联网。输出: 概览与设置 / 实时自检 / 选择器当前状态 / 你的覆盖 / 每个应用的走向 (直连 vs 代理 + 原因) / 失败最多的网站 / 疑似 DNS 污染 / 走向突变 (5 分钟一格: 直连占比突然从 <30% 变成 >70%) / 与路由有关的操作时间线 / 几条自动判断 (总开关关闭、系统代理没指向 enana、配置校验失败、应用被设为直连、直连连接失败 …)。

## 排查套路 (给读文件的人)

0. **先看 `verdict`** (2.3.8): `cause` / `blame` / 摘要 / 证据; 或 `python3 tools/diag-summary.py <文件>`。下面几步是它没覆盖时的手工排查。
1. 先看 `meta` 与 `env`: 代理总开关 `proxy.enabled`、`sysproxy.points_to_enana`、`config.check`、`other_proxy_software`。
2. 看 `probes`: 经过代理和直连都不通 → 节点 / 网络问题; 只有直连不通 → 需要代理而没走代理 (去看 `access` 的 `reason`); `dns_system` 与 `dns_core` 解析结果不同 → DNS 污染。
3. 看 `access`: 失败的连接 (`result=error`) 的 `app` `route` `node` `reason` `err`; `route=direct` 且 `reason=app/site` 说明是用户设置 (或默认) 造成的直连, 到 `ops` 找这条设置**是什么时候、谁改的**。
4. 看 `ops` 时间线: 故障开始时间附近有没有「发现新应用 / 切换策略 / 设置 / 更新」。
5. 看 `proxy` (核心原始日志) 里的 `WARN` / `ERROR` 行, 以及 `config` 里是否有预期的 `rule[i]`。

## 连接健康记录 (2.3.8) 与自动判定

「ChatGPT 连不上」这类问题以前只能靠导出那一刻的一次自检, 看不出是 **服务器不稳** 还是 **enana / 本机设置** 的问题。2.3.8 起 `enana tick` (每分钟一次) 会在本机记录下面这些东西 (文件 `~/.enana/logs/health-YYYY-MM-DD.log`, 只在本机, 和操作记录一起按保留时长清理 / 压缩; 设置里关闭「操作记录」会一并关闭):

| `kind` | 频率 | `target` | `result` | 说明 |
|---|---|---|---|---|
| `node` | 每分钟 | 固定出口 / 自动线路里的服务器名 (最多 8 个) | `ok` `timeout` `refused` `unreachable` `dns` `other` | **本机直接连服务器端口的 TCP 连接** (不经任何代理), `ms` = 连接耗时。服务器 / 机房线路是否稳定的客观证据; 只连用户自己的服务器端口, 不发应用数据 |
| `canary` | 约每 5 分钟 | `google_204` `chatgpt_web` `openai_api` (经本机代理, 仅在总开关开着且核心在运行时) · `cn_direct` (不经代理的苹果 `captive.apple.com`, 本机网络对照) | `ok` · `region-blocked` (`api.openai.com` 返回 403 = 出口 IP 所在地区被 OpenAI 限制) · `http-NNN` · `timeout` `refused` `tls` `reset` `dns` `proxy-handshake` `curl-N` | `detail` 带 `http=` `connect_ms=` `chain=svc-chatgpt>PIN>Tokyo-Fix` (这次实际用了哪个出口)。`chatgpt.com` 返回 403 是 Cloudflare 人机验证页, 算「连得上」 |
| `state` | 状态变化时 + 约每 9 分钟 | `capture` | `ok` | `core=1 pid=… api=1 proxy=1 mode=auto capture=system sysproxy=1 login=1 tun=- if=en0 gw=…`; `sysproxy` 取的是 `scutil --proxy` 里**当前生效**的系统代理 (应用实际用的那个) |
| `tick` | 相隔 > 3 分钟 | `gap` | `gap` | `ms` = 秒数: 电脑休眠 / 后台被暂停 |

状态变化 (`state` 行变了) 同时写一条操作记录 (见上面 `环境状态变化`), 所以「系统代理是什么时候被关掉的」「核心是不是崩溃重启过」可以直接在 `ops` 里读到。金丝雀的几条连接会出现在「网站访问」里 (应用 `curl`, 域名 `gstatic.com` / `chatgpt.com` / `api.openai.com` / `captive.apple.com`), 对照 `health` 里的同一时刻即可识别。仅 macOS; Windows 之后跟进 (导出里这几个分区为空)。

### 自动判定 (`verdict`) 怎么得出结论

`lib/health.pl verdict` 读 health + meta/env (当前状态) + 你选择导出的 ops / access, 按下面的顺序给出第一个成立的原因 (`verdict.cause`), 其余成立的列在 `verdict.also.N`:

| `cause` | `blame` | 判据 |
|---|---|---|
| `proxy-disabled` | client | `meta` 里 `proxy.enabled=0` (最近一次关闭是谁 / 为什么见 `verdict.last_proxy_off`; `reason=kicked` 等表示被云端退出登录) |
| `core-down` | client | `service.running=0` |
| `sysproxy-off` | client | 接管方式 `system`、总开关开着、核心在运行, 但生效的系统代理没有指向 enana (`since` 来自 state 行) |
| `tun-not-ready` | client | 接管方式 `tun` 但没有建立 utun 路由 |
| `local-network-down` | network | 最近 30 分钟服务器端口不通, 同时对照站点 `cn_direct` 也失败 |
| `node-down` | node | 最近 30 分钟某个服务器端口可达率 < 50% (且有对照数据正常; 没有对照数据时置信度降为 medium) |
| `proxy-path-failing` | node | 服务器端口是通的, 但经代理访问 `google_204` 最近 30 分钟失败过半 (服务端代理程序故障 / 配置被改 / 握手被干扰) |
| `node-unstable` | node | 整个范围内服务器端口失败 ≥ 3% 且 ≥ 5 次 (现在可能已恢复; 见 `outages`) |
| `openai-region-blocked` | exit-ip | 代理正常 (`google_204` ok), 但 `openai_api` 返回 403 过半 |
| `chatgpt-unreachable-via-proxy` | exit-ip | 代理正常, 但 `chatgpt_web` 连续失败 |
| `chatgpt-direct` | client | 访问记录里最近 30 分钟 ChatGPT / OpenAI 域名的连接过半是直连 (`verdict.chatgpt.recent30m` / `reasons`: `app` 应用被设成关 · `site` · `mode` · `cn` · `policy`) |
| `chatgpt-proxied-but-failing` | node | 这些连接走了代理却失败过半 |
| `no-issue-found` / `insufficient-data` | none | 都正常 / 健康记录太少 (刚升级, 等几分钟) |

`verdict.blame` 直接回答「是服务器不稳还是 enana 的问题」: `node` = 服务器 / 机房; `client` = 本机设置或 enana 的行为; `exit-ip` = 服务器 IP 被目标网站限制; `network` = 本机网络。判定只是依据本机记录的**证据汇总**, 摘要里会写明依据; 数据不足时不会乱下结论。

## 保留与隐私

- 三类日志各有独立开关 (设置 → 日志): **操作记录** / **网站访问** / **代理日志**; 关闭哪一类, 导出里对应分区就没有数据 (`meta` 的 `settings.*` 会如实标出)。
- 保留时长 12 小时 – 30 天 (默认 3 天), 按小时清理; 超出的日志在每小时的维护里自动压缩 / 删除。
- 日志只存在本机 (`~/.enana/logs`), 不会自动上传; 导出文件由用户自己决定发给谁。健康记录 (`health-*.log`) 只含服务器名 / 角色 / 端口连通结果和探测站点的状态码, 不含服务器地址、凭据或访问过的网站; 算在「操作记录」的占用和开关里。

## 接管与绕过代理的证据

`meta.capture.mode` 与 env 中的 `capture.mode` 区分 `system` 和 `tun`。
`capture.tun.configured/ready/service`、`capture.route.ipv4/ipv6/localhost` 描述当前状态; configured 不等于已建立 TUN。访问表尾新增 `capture` 列 (`mixed` 或 `tun`), 访问详情也显示入口。

环境快照附带当前用户的公网 TCP/UDP socket 表 (`pid/app/policy/network/destination/observation/process_path`):

- `captured`: OS 源地址/端口与 Clash API 活跃连接匹配。
- `bypass-system-proxy`: System Proxy 下观察到了公网 socket, 但没有核心连接与之匹配。可在复现时导出, 将 App 的直接请求与策略一起定位。短连接或采样竞争仍需连续复现核对。
- `core-api-unavailable`: 控制 API 不可读时无法对照, 不判定绕过代理。
- `tun-unobserved`: TUN 下没匹配到活跃连接, **不是已确认泄漏**; 检查服务、实际路由和入口日志。共享服务、进程归属与采样时机也可能影响匹配。

localhost 回调、局域网 socket 和核心自身出口不计入绕过系统代理。只读取当前用户的连接, 不要求 root; 目标 IP 脱敏。没有访问记录不能证明 App 没发请求或已被代理。旧版文件缺少 socket 快照时, 无法追溯证明某次 OAuth token 请求的接管情况。

## Windows 预览版

诊断与 Mac 使用同一导出入口与格式, 增加 Windows 版本/架构、用户任务和 TUN 任务、双栈与 localhost 接口归属、WinINet 代理状态和 PIN 主/辅助 EXE 的 TCP 连接快照。`possible_system_proxy_bypass` 仅为候选; `tun_os_socket_observed` 表示 TUN 模式下观察到 OS socket, 不单独证明出口。UDP 远端不可见时明确标记 `unavailable-on-Windows`。详见 [Windows 验收](WINDOWS.md)。
