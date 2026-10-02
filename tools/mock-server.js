#!/usr/bin/env node
/* enana 开发用模拟服务器 (无依赖, 仅监听 127.0.0.1) —— 仪表盘 (ui/) 开发时的假后端。
 * 严格对照 docs/API.md: 本地辅助服务 API (/api/*) + 代理核心的 Clash API (同源) + 静态仪表盘 (/ui/)。
 *
 *   node tools/mock-server.js [--port 18090] [--split] [--first-run] [--unbound] [--stale-sub] [--fast [N]] [--selftest] [--help]
 *
 * 打开  http://127.0.0.1:18090/ui/
 *   --split       辅助服务 API 放在另一个端口 (端口+1, 默认 18091), 带 CORS (只放行仪表盘自己的来源), 用来验证跨域与自定义请求头
 *   --first-run   「全新安装」: 没有服务器 / 订阅 (首次向导会出现); 与 --unbound 搭配就是完全没用过的电脑
 *   --unbound     这台电脑上还没有人登录过 (account_hint 为空, enana.cc 连不上时没有离线缓存可用)
 *   --stale-sub   让已保存的订阅过期, 以验证「打开仪表盘时自动刷新订阅」
 *   --fast [N]    模拟时间加速 N 倍 (默认 20): 任务进度 / 测速 / 核心重启中断 / 登录耗时都按它缩短 (自测用)
 *   --selftest    在 18090-18099 里找一个空闲端口启动, 跑内置检查 (HTTP), 打印 ok / FAIL, 失败则退出码非 0
 *
 * 账号模型 (docs/API.md): 没有「绑定」, 任何有效的 enana.cc 账号都能在这台电脑上登录; 注册也在这里 (POST /api/register);
 * 在线时向 enana.cc (模拟) 校验, 连不上时只有「当前仍处于登录状态」的账号 (令牌丢了 / 换了浏览器) 能用本机缓存离线登录。代理总开关初始为关, 退出账号会关闭它。
 * 设备限制: 同一账号、同一平台 (macOS / Windows) 最多同时 2 台设备在线 (这台电脑登录后算 1 台); 超出时登录得到 E_DEVICE_LIMIT + 在线设备列表, 带 kick=<uid> 重新提交即可下线其中一台并完成登录。
 * 测试账号 (只存在于这个模拟服务器): demo@example.com / demo1234 (登录框里提示的「上一次登录的账号」, 带 3 台设备), other@example.com / other1234 (1 台设备)。
 * 令牌 = Clash API 的 secret (服务器随机生成); 辅助服务请求头 X-Enana: 1 (旧名 X-TProxy), X-Enana-Token, X-Enana-Lang, X-Enana-Sudo (步骤验证令牌, 见下)。
 * 所有数据都是占位数据: 地址取自 RFC 5737 (192.0.2.x / 198.51.100.x / 203.0.113.x), 域名取自 example.com/.org/.net, ASN 取自 AS64496-64511。
 * 目录 (12 个分组 / 56 个条目) / 规则库 (26 个, 3 个必选) / DNS 预设 / 测速目标 (63 个) / 应用 (30 个) 全部是内置的合成数据, 不读取 ../data/*.conf (那里现在只有很小的基线; 真实的精选内容由云端内容包下发)。
 *
 * 运行时控制 (无需令牌, GET 或 POST 都行, 返回当前开关的 JSON):
 *   /mock/ctl?helper=down|up      辅助服务不可达 (连接被掐断) / 恢复          clash=down|up   核心 (Clash API) 不可达 / 恢复
 *   conns=N                       模拟的连接数 (0-2000)                      os=windows|darwin   平台 (Windows: 路径带反斜杠 / .exe)
 *   net=normal|limited|blocked|unknown|unreachable|none|noservers            本机 IP 检测的场景 (GET /api/net/info?mock=<场景> 可单次覆盖)
 *   central=up|down               enana.cc 是否可达                          lastacct=none|demo|other   谁算「上一次登录的账号」(登录框提示 + 本机离线校验缓存; 离线登录还要求该账号当前处于登录状态)
 *   proxy=on|off                  代理总开关 (关: 所有连接直连)               lock=reset      清除登录 / 注册限流        locksec=N   锁定时长 (秒, 默认 300)
 *   expire=1                      令牌全部失效 (下一个请求 401)               update=on|off|fail   更新场景: 有新版本(默认) / 已是最新 / 检查失败
 *   failnext=/api/路径前缀         该路径的下一个请求失败一次 (E_NETWORK); failnext=1 = 下一个后台任务失败并回滚 (旧用法)
 *   speedlast=seed|none           预置一条昨天的测速结果 / 清空                 env=bad|ok      环境异常 (规则缺失 / 无系统代理) / 恢复
 *   stale=1                       让第一个订阅过期                            tick=N          立刻生成 N 条「实时」访问 / 代理日志
 *   newapp=名称                   下一次「扫描应用」会发现这个新应用           reset=1|first-run   恢复初始数据 (令牌不变)
 *   stats=normal|short|empty      流量统计 (GET /api/stats?range=today|3d|7d|30d|90d): normal (默认) = 最早的数据在 41 天前 (90d 只有一部分有数据); short = 2 天前开始; empty = 没有任何数据 (since:"", 全是 0, nodes:[])
 *   statsfail=1                   下一个 /api/stats 请求失败一次 (E_NETWORK; 与 failnext=/api/stats 相同)
 *   devices=free|full|reset       设备限制: free (默认) = demo 账号只有一台 macOS 设备在线, 正常登录; full = 两台 macOS 设备都在线, 这台电脑下一次登录得到 E_DEVICE_LIMIT; reset = 恢复种子数据
 *   kickme=1|password             模拟「被账号下的另一台设备下线」(password = 因为另一台设备改了密码): 令牌全部失效 (下一个请求 401), 代理关闭, auth/status.notice 提示直到下一次登录成功; auth/status.notice_code = kicked | password_changed
 *   notice=文字                    直接设置 auth/status.notice (如「离线时间过长, 已自动退出登录」); notice= 清除
 *   vps=reset                     清空「我的服务器」记录 (已添加的节点不动)
 *   sync=reset                    云端同步恢复初始状态: 未开启, 云端有数据 (版本 7), 本机版本 6 且有未上传的改动 (--first-run 时本机版本 0)
 *   syncremote=none|exists|newer  云端没有数据 / 有且不比本机新 / 比本机新 (推送会冲突)     synckey=ok|bad   密钥场景: bad = 拉取时 E_SYNC_KEY, 要带 old_password=oldpass1234
 *   syncoffline=0|1               同步时 enana.cc 不可达 (GET /api/sync 的 online=false; 推送 / 拉取 / 清除 -> E_ACCOUNT_UNREACHABLE)
 *   plan=soon|free|pro|expired    套餐 (GET /api/plan): soon (默认) = 免费版, 官方线路「即将推出」; free = 免费版, Pro 功能已上线但需要升级; pro = 专业版 (30 天后到期, 设备上限 5, 服务器列表多出 2 个 official:true 的官方节点); expired = 订阅已过期 (reason "expired", 官方节点消失)
 *   prefs=reset|bump              偏好设置 (GET / POST /api/prefs): reset = 清空 (version 0); bump = 模拟「另一台设备同步来了改动」: version +1, 并写入 "ui.fromOtherDevice": true (state.prefs_version 随之变化)
 *   sudottl=N                     步骤验证令牌 (X-Enana-Sudo) 的有效期, 真实秒数 (默认 300; 设成 1-2 来测「过期后重新弹出密码框」)       sudo=clear   让所有步骤验证令牌立刻失效
 *   icons=progressive|all|none    应用图标: progressive (默认) = 启动 / 重置时的应用 0-6 秒内陆续出现, 新扫描到的应用 2-6 秒后出现 (按 --fast 缩短); all = 立刻都有; none = 都没有 (图片也 404)
 *   vpsport=open|closed           203.0.113.70 的部署: closed (默认) = 「验证连通」失败 E_VPS_VERIFY, open = 成功 (测「放行端口后重新验证」)
 * 步骤验证 (sudo): 8 个敏感接口 (POST /api/servers/delete | sub/delete | logs/clear | devices/kick | sync/clear, GET /api/servers/secret | sub/url | export) 没带有效的 X-Enana-Sudo 头 -> HTTP 403
 *   {ok:false, code:"E_SUDO_REQUIRED", error} (检查顺序: 401 令牌 -> 403 sudo -> 接口自己的校验; 白名单是 SUDO_ROUTES 这张表)。POST /api/auth/verify (表单 password = 当前账号的密码, 和登录 / 注册共用失败计数) -> {sudo, ttl:300};
 *   退出 / 登录 / 注册 / 改密码 / expire=1 / kickme / sudo=clear 都会让所有 sudo 令牌失效。GET /api/servers/secret?tag= 返回按节点类型生成的确定性占位凭据 (官方节点 -> E_INVALID); GET /api/sub/url?name= 返回保存订阅时的链接;
 *   GET /api/export 返回文本 (JSON) 备份 (含占位凭据, 不含官方节点; 带 Content-Disposition 文件名 enana-backup-YYYYMMDD.json)。POST /api/password (表单 old / new, 不需要 sudo) 修改这个模拟服务器里的账号密码 (reset=1 恢复种子密码):
 *   校验顺序同 lib/auth.sh (旧密码为空 -> E_INVALID; 新密码 < 8 / > 71 位或与旧密码相同 -> E_WEAK_PASSWORD; 被锁定 -> E_LOCKED; enana.cc 连不上 -> E_ACCOUNT_UNREACHABLE; 旧密码不对 -> E_BAD_CREDENTIALS (+wait)); 成功后本机令牌保持有效, 账号下的其它设备全部下线, sudo 令牌清空。
 *   偏好 (POST /api/prefs) 保存的是规范化的 JSON (键排序, 最多 12 层嵌套, 同 lib/prefs.sh)。官方节点的凭据不能查看: GET /api/servers/secret -> E_INVALID (lib/api.sh 用的是文档里没有的 E_FORBIDDEN)。
 * 应用图标: GET /api/apps 的每个应用有 icon ("appicons/<slug>.png" 或 ""; slug = 名称里不是 A-Za-z0-9._- 的字节换成 _ (最多 40 个) + "-" + cksum(名称), 同 lib/apps.sh 的 app_icon_slug, 如 appicons/Slack-4138898108.png),
 *   图片由本服务按需生成 (GET /ui/appicons/<slug>.png, 96x96 的 PNG: 彩色圆角方块 + 由名称哈希出的白色图形), 提取出来之前是 404。zoom.us / ClashX Pro / WPS Office 永远没有图标 (icon:""); Steam 宣称有图标但图片 404 (测 onerror 兜底)。
 *   每个应用另有 custom (自定义软件)、kind (app | bin) 与 path (所有应用都有 path, 同 lib/apps.sh; docs/API.md 写的是「自定义软件才有」)。
 * 「添加自定义软件」(POST /api/apps/inspect, 表单 input) 的魔法输入 (绝不执行任何程序; 路径只接受绝对路径, 名称最多 8 个候选; 检查过的图标即时可用; 无效的输入也是 ok:true + 一个 {valid:false, path, reason}, 文案同 lib/apps.sh):
 *   /Applications/Cursor.app  有效的应用 (还不在列表里, 正在运行, 已签名或未签名由名称决定)        /Applications/Slack.app  有效, exists:true (已在应用列表里)
 *   /usr/local/bin/mytool  命令行工具 (kind bin), 未签名 (signed:false)                          /opt/homebrew/bin/node  命令行工具, 已签名 (authority + team)
 *   /etc/hosts  valid:false, 不是应用 / 可执行文件                                              /private/var/root/secret.app  valid:false, 没有读取权限
 *   名称: cursor -> 1 个候选, code -> 5 个, zzz -> 没有 (valid:false + 原因), a -> 最多 8 个, slack -> 精确匹配排最前 (exists:true)
 *   其它: 路径名里含 missing / nonexistent / nope -> 路径不存在; /Applications 下的 *.app 和常见 bin 目录下的文件 -> 有效; /etc/ 下的文件 -> 不是应用; 带斜杠的相对路径 / ~/… -> 请输入绝对路径; 路径里有 | " \ 或控制字符 -> 路径里有不支持的字符;
 *   名称里有 [ ] * ? | " \ 或控制字符 -> 名称里有不支持的字符; 空输入 -> 请输入软件的路径或名称; 超过 300 个字符的输入会被截断。输入两端的引号、末尾的 / 和拖进终端得到的「\ 」转义都会被理解。
 *   POST /api/apps/custom (表单 path = inspect 返回的路径, state 必填): 无效的路径 (原因就是错误文案) / 已在列表里 / 状态无效 -> E_INVALID; POST /api/apps/custom/delete: 内置应用或不存在 -> E_NOT_FOUND「找不到这个自定义软件」。
 * 测速目标: 内置 63 个 (global 15 / cn 12 / carrier 6 / dev 16 / media 14), 其中 20 个默认勾选; 用户自己添加的目标默认也是勾选的 (default:true, 同 lib/speed.sh); speedtest/start 不带 targets 时测所有 default:true 且未隐藏的目标。
 *   保存目标 (POST /api/speedtest/targets) 是整份替换: name / group / url 必填, expect 缺省 200,204,301,302 (最多 10 个), icon 最多 30 个字符; 编辑内置目标 = 保存一份覆盖 (一直是 modified:true, 直到 restore; 名称的中英文都变成填的名称);
 *   未知的 id: 保存 -> E_INVALID, delete / restore -> E_NOT_FOUND (restore 只认内置目标)。自定义目标的主机名里含 slow / dead (或 fail) / block (或 limit, ban) 时, 对所有线路都偏慢 / 失败 / 受限 (便于测试界面);
 *   其余按分组, 和内置目标一样 (国内 / 运营商目标只测直连, 节点那一格是 skip)。
 * 网站域名 (GET / POST /api/sites/domains): 输入先规范化 (去首尾空白 / 转小写 / 去结尾的点) 再校验, 每种不合法的写法有各自的译文原因; POST 的所有失败都是 E_INVALID (含未知条目 / 域名不在列表里), 只有 GET / reset 的未知条目是 E_NOT_FOUND;
 *   每个条目最多 300 个自己添加的域名, 合计最多 2000 条改动; policy = 条目的默认策略; update = 删除旧的再添加新的。DNS 自定义解析 (POST /api/dns/hosts) 同样先规范化; 同名 add -> E_INVALID; 最多 200 条; update 什么都不改也算成功。
 *   GET /api/dns 的 pipeline 行: id = hosts (有自定义解析时) | ads (屏蔽广告时) | direct | cn | proxy | global, match = hosts | geosite-ads | direct | geosite-cn | proxy | all, 文案同 lib/dns.sh。
 *   DNS 服务器测速 (POST /api/dns/bench): 海外的 adguard 永远不通 (ms:null), 没有节点时海外预设全部不通。
 * 订阅地址约定 (在导入框里粘贴即可测试):
 *   https://sub.example.com/sub/demo        正常: 33 个节点 (24 个 HTTPS, 4 TUIC, 4 Hysteria2, 1 VLESS) + 订阅提示节点 + 不支持的节点
 *   https://sub.example.com/sub/stubborn    auto 返回无法解析的网页, clash 才返回 YAML (测试自动换格式重试)
 *   https://sub.example.com/sub/stubborn2   auto / clash 都不行, v2ray 才行          .../sub/singbox   auto 返回 sing-box JSON
 *   https://sub.example.com/sub/slow        延迟 4 秒才响应                          .../sub/fail      下载失败 (E_NETWORK)
 *   https://sub.example.com/sub/empty       下载成功但没有任何节点
 * 其它: 规则集链接里含 "fail" 的主机 (如 https://fail.example.com/x.srs) 会让「添加规则集」任务失败。
 * 「添加自己的服务器」(POST /api/vps/probe | provision | redetect) 的魔法主机 (任务 4-14 秒, 凭据永远不被记录 / 保存 / 返回); 指纹 = "SHA256:" + 由主机名哈希出的 base64:
 *   其它任何主机 / 203.0.113.10  Debian 12 amd64, root, curl 已装但缺 ca-certificates + iproute2, 没有 sing-box, ufw 已启用, 一个公网 IP = 主机本身
 *   .20  Ubuntu 22.04 arm64 极简版: 依赖全缺 (all_missing), ufw 未启用        .30  全都装好了, sing-box 和 node 也已安装
 *   .31  两个公网 IPv4 (198.51.100.31 / .32, 内网地址是 NAT 式的) + 一个 IPv6 (2001:db8::31): 部署时每个出口 IP 一个节点; 记录第一次「重新识别」会多出 198.51.100.33
 *   .40  hostkey_changed:true      .50  CentOS 7: supported:false, support:"no"      .51  Debian 10: support:"best_effort"
 *   .60  E_SSH_UNREACHABLE (约 3 秒后)   .61 E_SSH_AUTH   .62 E_SSH_KEY   .63 E_SSH_NO_CLIENT   .64 E_VPS_PRIVILEGE (非 root 且没有 sudo)
 *   .65  privilege:"sudo_password": 表单里 sudo_password 非空才成功, 否则 E_VPS_PRIVILEGE        .70  部署时在「验证连通」失败 (E_VPS_VERIFY: 云安全组没放行 443; ctl vpsport=open 之后再部署就成功)
 *   密码 wrong-pass -> 任何主机都 E_SSH_AUTH; 带了 hostkey 但与主机的指纹不一致 -> E_SSH_HOSTKEY; 部署时 install_deps=0 而依赖有缺失 -> E_VPS_DEPS; 不支持的系统 -> E_VPS_UNSUPPORTED。
 *   失败的任务: state:"error", msg 已翻译, 失败的那一步标 error, 顶层 code 与 result.code 都是错误码 (E_VPS_VERIFY 的 result 另带 port)。
 *   节点 tag = <服务器名>-<出口 IP>, 部署时不给 name 则服务器名 = my-vps-<host> (太长 / 含冒号的 IPv6 时是 my-vps); GET /api/vps 的记录带 hostkey; redetect 的 job.result = {nodes, ips, vps, added}。
 * 操作记录的动作码 (GET /api/logs?type=ops, 详情是 logfmt): login login.fail logout proxy.on proxy.off proxy.mode override.set override.delete apps.scan apps.adopt apps.ack servers.import servers.delete servers.role sub.save sub.delete sub.refresh
 *   rules.update rules.toggle rules.custom.add rules.custom.delete dns.set dns.test settings.set logs.clear update.apply restart install upgrade uninstall start stop net.refresh speedtest.start speedtest.stop vps.probe vps.provision vps.forget
 *   vps.redetect sync.settings sync.push sync.pull sync.clear devices.kick, 以及新增的 (界面要给每个码一条译文): auth.verify (失败: code=E_BAD_CREDENTIALS) · secret.view (kind=server tag=… | kind=sub name=…) · backup.export (servers= subs=) ·
 *   password.change (失败: code=…) · sites.domain (id= action=add|remove|update|restore domain= [new=]) · sites.reset (id=) · apps.custom.add (name= kind=app|bin state=) · apps.custom.delete (name=) · speed.target (action=add|edit|delete|restore id= [group=]) ·
 *   speed.targets.reset · dns.hosts (action=add|update|remove domain= [new=]) · dns.hosts.reset (count=) · dns.bench。偏好 (prefs) 的写入不记录; 任何密码 / 令牌 / 凭据都不会出现在详情里。
 */
'use strict';
const http = require('http'), fs = require('fs'), path = require('path'), crypto = require('crypto'), zlib = require('zlib'), net = require('net');

const ROOT = path.resolve(__dirname, '..'), UI = path.join(ROOT, 'ui');                        // 数据 (目录 / 规则库 / DNS 预设 / 测速目标 / 应用) 全部内置, 不读 data/*.conf
const args = process.argv.slice(2);
const flag = (n) => args.indexOf('--' + n) >= 0;
const opt = (n, d) => { const i = args.indexOf('--' + n); return i >= 0 && args[i + 1] && args[i + 1][0] !== '-' ? args[i + 1] : d; };
const HELP = [
  'enana mock server (zero dependencies, listens on 127.0.0.1 only)', '',
  'Usage: node tools/mock-server.js [options]',
  '  --port N       listen port (default 18090; ports below 1024 are refused)',
  '  --split        serve the helper API (/api/*) on a second port (default PORT+1 = 18091) with CORS, like production',
  '  --first-run    start as a fresh install: no servers, no subscriptions (add --unbound for a pristine computer)',
  '  --unbound      start with nobody having logged in on this computer before (empty account_hint, no offline login)',
  '  --stale-sub    make the saved subscription overdue for auto refresh',
  '  --fast [N]     run simulated time N times faster (default 20): jobs, speed test, outages, login latency',
  '  --selftest     boot on a free port in 18090-18099, run the built-in checks, print ok/FAIL, exit non-zero on failure',
  '  --help         show this text', '',
  'Open http://127.0.0.1:18090/ui/   Test accounts: demo@example.com / demo1234, other@example.com / other1234 (mock only)',
  'Runtime switches: GET or POST /mock/ctl?helper=down&clash=down&conns=N&os=windows&net=limited&central=down&lastacct=other&proxy=on',
  '  &lock=reset&locksec=N&expire=1&update=on|off|fail&failnext=/api/x&speedlast=seed&env=bad&tick=N&newapp=Name&reset=1',
  '  &vps=reset&sync=reset&syncremote=none|exists|newer&synckey=ok|bad&syncoffline=0|1&devices=free|full|reset&kickme=1&notice=text',
  '  &stats=normal|short|empty (traffic statistics history: 41 days / 2 days / none)&statsfail=1 (next /api/stats fails once)',
  '  &plan=soon|free|pro|expired&prefs=reset|bump&sudottl=N (seconds)&sudo=clear&icons=progressive|all|none&vpsport=open|closed&kickme=1|password',
  'Sudo (step-up password): POST /api/auth/verify -> X-Enana-Sudo for servers/delete, sub/delete, servers/secret, sub/url, logs/clear, devices/kick, sync/clear, export (403 E_SUDO_REQUIRED without it)',
  'Magic VPS hosts (probe/provision): 203.0.113.10 20 30 31 40 50 51 60-65 70 (70 fails with E_VPS_VERIFY until vpsport=open; see the file header)',
  'Magic app inspect inputs: /Applications/Cursor.app /Applications/Slack.app (exists) /usr/local/bin/mytool (unsigned bin) /opt/homebrew/bin/node /etc/hosts /private/var/root/secret.app; names: cursor (1 hit) code (5) zzz (none)',
  '(full list and the subscription URL conventions are in the header of tools/mock-server.js)'].join('\n');
if (flag('help') || args.indexOf('-h') >= 0) { console.log(HELP); process.exit(0); }

const HOST = '127.0.0.1', SELFTEST = flag('selftest');
let PORT = +opt('port', 18090), SPLIT = flag('split'), HPORT = SPLIT ? +opt('helper-port', PORT + 1) : PORT;
let FAST = flag('fast') ? Math.max(1, +opt('fast', 20) || 20) : (SELFTEST ? 40 : 1);
if (!SELFTEST && !(PORT >= 1024 && PORT <= 65534 && HPORT >= 1024 && HPORT <= 65535)) { console.error('mock-server: the port must be between 1024 and 65534 (well-known ports are refused)'); process.exit(2); }
const MAX_BODY = 4 * 1024 * 1024, LATEST_APP = '2.2.0', LATEST_CORE = '1.14.3', BASE_APP = '2.1.0', BASE_CORE = '1.14.2';
const CENTRAL = 'https://enana.cc';
/* 只存在于模拟服务器里的测试账号 */
const ACCOUNTS = { 'demo@example.com': { id: 'acc_demo0001', pw: 'demo1234' }, 'other@example.com': { id: 'acc_other002', pw: 'other1234' } };

/* ===================== 1. 工具 ===================== */
const now = () => Date.now(), sec = () => Math.floor(Date.now() / 1000);
const rnd = (a, b) => a + Math.random() * (b - a);
const hash = (s) => { let n = 0; for (let i = 0; i < s.length; i++) n = (n * 31 + s.charCodeAt(i)) >>> 0; return n; };
const mulberry = (seed) => { let a = seed >>> 0; return () => { a = (a + 0x6D2B79F5) >>> 0; let t = a; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; };
const pick = (r, a) => a[Math.floor(r() * a.length) % a.length];
const D = (ms) => ms / FAST;                                        // 模拟时间 -> 真实毫秒
const sleep = (ms) => new Promise((ok) => setTimeout(ok, D(ms)));
const pad = (n) => String(n).padStart(2, '0');
const dayOf = (ms) => { const d = new Date(ms); return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()); };
const tsOf = (ms) => { const d = new Date(ms); return dayOf(ms) + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds()); };
const startOfDay = (ms) => { const d = new Date(ms); d.setHours(0, 0, 0, 0); return d.getTime(); };
const addDays = (ms, n) => { const d = new Date(ms); d.setDate(d.getDate() + n); return d.getTime(); };
const randHex = (n) => crypto.randomBytes(n).toString('hex');
const uuid = () => { const h = randHex(16); return [h.slice(0, 8), h.slice(8, 12), h.slice(12, 16), h.slice(16, 20), h.slice(20)].join('-'); };
const clone = (o) => JSON.parse(JSON.stringify(o));
const num = (v, d) => { const n = parseInt(v, 10); return isNaN(n) ? d : n; };
const verCmp = (a, b) => { const x = String(a).split('.'), y = String(b).split('.'); for (let i = 0; i < 4; i++) { const d = (+x[i] || 0) - (+y[i] || 0); if (d) return d; } return 0; };
/* 操作记录的详情用 logfmt: key=value 以空格分隔, 值里有空格 / 引号时用双引号括起来 */
/* 异常只打印名字和调用栈, 不打印 message (有的 message 会带上输入内容): 请求体 / 密码 / 令牌绝不进日志 */
const safeErr = (e) => String((e && e.name) || 'Error') + ' @ ' + String((e && e.stack) || '').split('\n').filter((l) => /^\s+at /.test(l)).slice(0, 3).map((l) => l.trim()).join(' | ');
const kv = (o) => Object.keys(o).map((k) => { let v = String(o[k]); if (/[\s"]/.test(v) || v === '') v = '"' + v.replace(/\\/g, '\\\\').replace(/"/g, '\\"').slice(0, 80) + '"'; return k + '=' + v; }).join(' ');
const maskEmail = (e) => { const i = e.indexOf('@'); if (i < 0) return '***'; const u = e.slice(0, i), d = e.slice(i + 1), j = d.indexOf('.'); return j < 0 ? u[0] + '***@' + d[0] + '***' : u[0] + '***@' + d[0] + '***.' + d.slice(j + 1); };

/* ===================== 2. 文案 (中文, English) —— 错误 / 任务步骤 / 更新说明 / 测速提示 ===================== */
const S = {
  'err.E_AUTH': ['未登录或登录已失效, 请重新登录', 'Not signed in, or the session has expired. Please sign in again.'],
  'err.E_BAD_CREDENTIALS': ['账号或密码错误', 'Wrong account or password.'],
  'err.E_LOCKED': ['尝试次数过多, 登录和注册已暂时锁定, 请 {wait} 秒后再试', 'Too many attempts. Sign-in and sign-up are locked temporarily; try again in {wait} s.'],
  'err.E_DEVICE_LIMIT': ['这个账号在本平台已有 {limit} 台设备在线, 请先下线其中一台再登录', 'This account already has {limit} devices online on this platform. Sign one of them out first, then log in.'],
  'err.E_EMAIL_TAKEN': ['这个邮箱已经注册过了, 请直接登录', 'This email is already registered. Please sign in instead.'],
  'err.E_WEAK_PASSWORD': ['密码太弱: 至少需要 8 位', 'The password is too weak: at least 8 characters are required.'],
  'err.E_ACCOUNT_UNREACHABLE': ['连不上 enana.cc, 而且这个账号没有离线缓存, 暂时无法完成, 请稍后重试', 'Cannot reach enana.cc, and this account has no offline cache, so it cannot be completed right now. Please try again later.'],
  'err.E_CENTRAL': ['密码已改为在 enana.cc 管理, 请到网站的账号页修改', 'Passwords are managed on enana.cc now. Please change it on the website account page.'],
  'err.E_NOT_RUNNING': ['代理核心没有在运行, 无法开启代理', 'The proxy core is not running, so the proxy cannot be switched on.'],
  'err.E_INVALID': ['参数不正确', 'Invalid parameters.'], 'err.E_NOT_FOUND': ['找不到', 'Not found.'],
  'err.E_BUSY': ['系统繁忙, 请稍后重试', 'The system is busy. Please try again later.'], 'err.E_NETWORK': ['网络请求失败', 'The network request failed.'],
  'err.E_NO_SERVERS': ['还没有可用的服务器', 'There are no servers yet.'], 'err.E_RUNNING': ['已有测速正在运行', 'A speed test is already running.'],
  'err.E_SSH_NO_CLIENT': ['本机没有找到 ssh 命令, 无法连接服务器', 'No ssh client was found on this computer, so the server cannot be reached.'],
  'err.E_SSH_UNREACHABLE': ['连不上这台服务器: 地址或端口不对, 或者超时 / 被防火墙拒绝', 'Cannot reach this server: wrong address or port, a timeout, or the connection was refused by a firewall.'],
  'err.E_SSH_AUTH': ['登录失败: 用户名、密码或私钥不对', 'Login failed: wrong user name, password or private key.'],
  'err.E_SSH_KEY': ['私钥无法使用: 格式不对, 或者私钥口令不对', 'The private key cannot be used: wrong format or wrong passphrase.'],
  'err.E_SSH_HOSTKEY': ['服务器的主机指纹与确认过的不一致, 为防止中间人攻击已中止', 'The server host key does not match the one you confirmed. Aborted to protect you from a man-in-the-middle attack.'],
  'err.E_VPS_PRIVILEGE': ['这个用户既不是 root 也没有 sudo 权限 (或需要 sudo 密码), 无法安装', 'This user is neither root nor allowed to use sudo (or a sudo password is required), so nothing can be installed.'],
  'err.E_VPS_UNSUPPORTED': ['这台服务器的系统或架构暂不支持 (支持 Debian 11 / 12 / 13 与 Ubuntu 20.04 / 22.04 / 24.04, x86_64 与 arm64)', 'This server system or architecture is not supported (Debian 11 / 12 / 13 and Ubuntu 20.04 / 22.04 / 24.04 on x86_64 and arm64 are).'],
  'err.E_VPS_DEPS': ['服务器缺少必要的软件, 而你选择了不安装依赖', 'The server is missing required packages and you chose not to install dependencies.'],
  'err.E_SYNC_KEY': ['无法解密云端数据: 账号密码在网站上改过, 请输入旧密码后重试', 'The cloud data cannot be decrypted: the account password was changed on the website. Enter the old password and retry.'],
  'err.E_SYNC_CONFLICT': ['云端的数据比本机新, 请选择「用云端覆盖本机」或「用本机覆盖云端」', 'The cloud data is newer than this computer. Choose to overwrite this computer with the cloud, or the cloud with this computer.'],
  'dev.this': ['这台电脑', 'This computer'], 'notice.kicked': ['这台设备已被你账号下的另一台设备下线, 代理已关闭', 'This device was signed out from another device on your account, and the proxy was turned off'],
  'e.devUid': ['缺少设备 uid', 'The device uid is missing.'], 'e.devSelf': ['不能下线当前这台设备 (请用「退出登录」)', 'You cannot sign out this device itself (use log out instead).'],
  'e.noDevice': ['找不到这台设备', 'Device not found.'], 'e.devKick': ['这台设备不在可下线的在线设备名单里', 'That device is not one of the online devices that can be signed out.'],
  'e.devOffline': ['连不上 enana.cc, 暂时无法读取或管理设备, 请稍后重试', 'Cannot reach enana.cc, so devices cannot be listed or managed right now. Please try again later.'],
  'e.header': ['缺少 X-Enana 请求头', 'Missing the X-Enana request header.'], 'e.tooLarge': ['请求内容过大 (最大 4 MB)', 'The request body is too large (4 MB max).'],
  'e.noRoute': ['接口不存在', 'Unknown endpoint.'], 'e.badReq': ['请求格式不正确', 'Malformed request.'], 'e.internal': ['模拟服务器处理出错 (请求参数不合法?)', 'The mock server failed to handle the request (invalid input?).'],
  'e.loginFormat': ['邮箱或密码格式不正确', 'The email or password format is not valid.'],
  'e.noJob': ['找不到该任务', 'Task not found.'], 'e.badJobId': ['任务编号无效', 'Invalid task id.'],
  'e.noServer': ['找不到这台服务器', 'Server not found.'], 'e.badRole': ['角色无效', 'Invalid role.'],
  'e.dlOnly': ['下载专用只能用于 HTTP / SOCKS5 服务器', 'Download-only can only be used with HTTP / SOCKS5 servers.'],
  'e.noSub': ['找不到这个订阅', 'Subscription not found.'],
  'e.badSubName': ['订阅名称只能包含字母、数字、. _ - 和空格 (最多 40 个字符)', 'A subscription name may only contain letters, digits, . _ - and spaces (up to 40 characters).'],
  'e.badSubUrl': ['订阅链接不合法 (只允许公网的 http/https 地址)', 'Invalid subscription link (only public http/https addresses are allowed).'],
  'e.subFetch': ['下载订阅失败: 连接超时 (已依次尝试 直连 / 本地代理)', 'Failed to download the subscription: connection timed out (direct and the local proxy were both tried).'],
  'e.noImport': ['没有可导入的服务器', 'There are no servers to import.'], 'e.noBody': ['没有收到服务器数据', 'No server data was received.'],
  'e.badLine': ['第 {n} 行格式不符合要求, 已忽略', 'Line {n} is not in the expected format and was ignored.'],
  'e.badCertName': ['证书名称不合法', 'Invalid certificate name.'], 'e.badCert': ['这不是有效的 PEM 证书', 'This is not a valid PEM certificate.'], 'e.certSize': ['证书内容为空或过大', 'The certificate is empty or too large.'],
  'e.badState': ['状态无效', 'Invalid state.'], 'e.badName': ['名称格式不正确', 'The name is not in a valid format.'], 'e.badKind': ['类型只能是 app 或 site', 'The kind must be app or site.'],
  'e.noApp': ['找不到这个应用', 'App not found.'], 'e.needApp': ['缺少应用名', 'The app name is missing.'],
  'e.badLang': ['语言只能是 zh 或 en', 'The language must be zh or en.'], 'e.badLogDays': ['保留天数必须是 1–365 之间的整数', 'Retention must be a whole number between 1 and 365.'],
  'e.badRange': ['统计范围无效', 'Invalid statistics range.'],
  'e.badBool': ['取值必须是 0 或 1', 'The value must be 0 or 1.'], 'e.logType': ['日志类型无效', 'Invalid log type.'], 'e.logDay': ['日期格式应为 YYYY-MM-DD', 'The date must be in YYYY-MM-DD format.'],
  'e.ruleEssential': ['这个规则集是必需的, 不能停用', 'This rule set is required and cannot be disabled.'], 'e.noRule': ['找不到这个规则集', 'Rule set not found.'],
  'e.ruleCustom': ['自定义规则集只能删除, 不能这样设置', 'Custom rule sets can only be deleted, not toggled.'], 'e.ruleNotCustom': ['只能删除自定义规则集', 'Only custom rule sets can be deleted.'],
  'e.badRuleName': ['名称只能包含字母、数字、. _ - (最多 30 个字符)', 'The name may only contain letters, digits, . _ - (up to 30 characters).'],
  'e.badRuleUrl': ['链接必须是公网 http(s) 地址, 且以 .srs 结尾', 'The link must be a public http(s) address ending in .srs.'],
  'e.badPolicy': ['策略只能是 pin / auto / direct', 'The policy must be pin, auto or direct.'], 'e.ruleDup': ['已经有同名的规则集', 'A rule set with this name already exists.'],
  'e.ruleDl': ['下载规则集失败: 连接超时', 'Failed to download the rule set: connection timed out.'],
  'e.badDnsCn': ['未知的国内 DNS 预设', 'Unknown China DNS preset.'], 'e.badDnsGlobal': ['未知的海外 DNS 预设', 'Unknown overseas DNS preset.'],
  'e.badDnsUrlCn': ['国内自定义 DNS 地址格式不正确', 'The custom China DNS address is not valid.'], 'e.badDnsUrlGlobal': ['海外自定义 DNS 地址格式不正确', 'The custom overseas DNS address is not valid.'],
  'e.needDnsCn': ['选择了自定义国内 DNS, 请填写地址', 'Custom China DNS is selected; please enter an address.'], 'e.needDnsGlobal': ['选择了自定义海外 DNS, 请填写地址', 'Custom overseas DNS is selected; please enter an address.'],
  'e.badVia': ['线路只能是 Global 或 PIN', 'The route must be Global or PIN.'], 'e.badStrategy': ['IP 策略无效', 'Invalid IP strategy.'],
  'e.badHost': ['域名格式不正确', 'The host name is not valid.'], 'e.dnsFail': ['解析失败: 查询超时', 'Resolution failed: the query timed out.'],
  'e.speedMode': ['测速模式无效', 'Invalid speed test mode.'], 'e.speedNodes': ['节点选择无效 (最多 12 个, 且必须是已有的固定出口 / 自动线路服务器)', 'Invalid node selection (up to 12, and they must be existing pinned / auto servers).'],
  'e.speedTargets': ['测速目标无效', 'Invalid speed test targets.'], 'e.noSpeed': ['找不到该测速任务', 'Speed test not found.'],
  'e.updWhat': ['what 只能是 app 或 core', '"what" must be app or core.'], 'e.updLatest': ['已经是最新版本', 'Already up to date.'], 'e.updBusy': ['已有更新任务正在运行', 'An update task is already running.'],
  'e.updCheck': ['检查更新失败: 连不上更新服务器', 'Update check failed: the update server could not be reached.'],
  'e.vpsHost': ['服务器地址不正确 (IPv4 / IPv6 / 域名)', 'The server address is not valid (IPv4, IPv6 or a domain name).'], 'e.vpsPort': ['SSH 端口必须是 1-65535', 'The SSH port must be 1-65535.'],
  'e.vpsUser': ['用户名不正确', 'The user name is not valid.'], 'e.vpsMode': ['登录方式只能是 password 或 key', 'The login mode must be password or key.'], 'e.vpsPassword': ['请填写 SSH 密码', 'Enter the SSH password.'],
  'e.vpsKey': ['请粘贴私钥全文 (以 -----BEGIN 开头)', 'Paste the full private key (starting with -----BEGIN).'], 'e.vpsHostkey': ['缺少主机指纹: 请先探测并确认指纹', 'The host key fingerprint is missing: probe the server and confirm it first.'],
  'e.vpsName': ['节点名称只能包含字母、数字、. _ - (最多 40 个字符)', 'The name may only contain letters, digits, . _ - (up to 40 characters).'], 'e.vpsRole': ['角色只能是 pin 或 auto', 'The role must be pin or auto.'],
  'e.noVps': ['找不到这条服务器记录', 'Server record not found.'], 'e.vpsId': ['缺少服务器记录的 id', 'The server record id is missing.'],
  'vps.noteFull': ['{os} 受支持', '{os} is supported'], 'vps.noteBest': ['{os} 已停止维护, 软件源可能失效, 将尽力安装; 失败时请先升级系统。', '{os} is end-of-life and its package sources may be broken. Installation is best-effort; upgrade the system first if it fails.'],
  'vps.noteNo': ['不支持的系统: {os}。目前支持 Debian 11 / 12 / 13 与 Ubuntu 20.04 / 22.04 / 24.04。', 'Unsupported system: {os}. Debian 11 / 12 / 13 and Ubuntu 20.04 / 22.04 / 24.04 are supported.'],
  'e.syncOffline': ['连不上 enana.cc, 暂时无法同步, 请稍后重试', 'Cannot reach enana.cc, so sync is not possible right now. Please try again later.'],
  'e.syncOff': ['云端同步还没有开启', 'Cloud sync is not turned on.'], 'e.syncAuto': ['要先开启同步, 才能开启自动同步', 'Turn on sync before turning on auto sync.'],
  'e.syncNoRemote': ['云端还没有数据', 'There is no data in the cloud yet.'], 'e.badMode': ['mode 只能是 replace 或 merge', '"mode" must be replace or merge.'],
  'e.netBusy': ['测速任务正在使用线路, 请稍后重试', 'A speed test is using the routes. Please try again shortly.'], 'e.badNet': ['未知的 IP 检测场景', 'Unknown IP check scenario.'],
  /* 新增: 步骤验证 (sudo) / 密码修改 / 偏好 / 凭据显示 / 套餐 (文案与 lib/*.sh + data/i18n/en.tsv 里真实辅助服务的保持一致) */
  'err.E_SUDO_REQUIRED': ['此操作需要再次输入登录密码', 'This action needs your sign-in password again'],
  'err.E_VPS_VERIFY': ['部署完成了, 但从这台电脑连不上新节点: 多半是云服务商的安全组 / 防火墙没有放行端口 {port}/tcp, 放行后点「重新验证」', 'The deployment finished, but this computer cannot reach the new node: most likely the cloud provider\'s security group / firewall does not allow port {port}/tcp. Open it, then click "Verify again".'],
  'e.pwEmpty': ['请输入登录密码', 'Enter your sign-in password'], 'e.pwWrong': ['密码不正确', 'Incorrect password'], 'e.pwWrongCur': ['当前密码不正确', 'The current password is incorrect'],
  'e.pwWeakNew': ['新密码至少 8 位, 并且不能和旧密码相同', 'The new password must be at least 8 characters and different from the old one'],
  'e.pwOffline': ['连不上 enana.cc, 修改密码必须在线 (离线登录时不能修改)。请检查网络后重试', 'Cannot reach enana.cc; changing the password requires being online (not possible after an offline sign-in). Check your network and retry'],
  'e.prefsJson': ['偏好设置必须是一个 JSON 对象', 'The preferences must be a JSON object'], 'e.prefsSize': ['偏好设置太大 (最多 32 KB)', 'The preferences are too large (32 KB at most)'],
  'e.officialSecret': ['官方线路的凭据不能查看', 'Credentials of the official route cannot be viewed'], 'e.officialDel': ['官方线路节点由会员权益提供, 不能删除', 'Official route nodes come with the membership and cannot be deleted.'],
  'plan.free': ['免费版', 'Free'], 'plan.pro': ['专业版', 'Pro'],
  'notice.pwChanged': ['你的登录密码已在另一台设备上修改, 请用新密码重新登录, 代理已关闭', 'Your password was changed on another device. Sign in again with the new password; the proxy was turned off.'],
  /* 新增: 网站域名 (也用于 DNS 自定义解析) */
  'e.noEntry': ['找不到这个网站条目', 'That site entry was not found'], 'e.entryId': ['条目编号无效', 'Invalid entry ID'], 'e.entryRs': ['自定义规则集条目没有可编辑的域名', 'Custom rule set entries have no editable domains.'], 'e.badAction': ['操作无效', 'Invalid action'],
  'e.domEmpty': ['请输入域名', 'Enter a domain name.'], 'e.domSpace': ['域名不能包含空格', 'A domain cannot contain spaces.'],
  'e.domProto': ['域名不要带协议 (去掉 http:// 或 https://)', 'Leave out the protocol (remove http:// or https://).'],
  'e.domWild': ['不支持通配符 * (子域名会自动一起匹配)', 'Wildcards (*) are not supported; subdomains are matched automatically.'],
  'e.domPath': ['域名不要带路径、端口、账号或参数', 'Leave out paths, ports, user names and query strings.'],
  'e.domChars': ['域名只能包含小写字母、数字、连字符和点 (中文域名请写成 xn-- 形式)', 'A domain may only contain lowercase letters, digits, hyphens and dots (write internationalized names in xn-- form).'],
  'e.domLen': ['域名太长 (最多 253 个字符)', 'The domain is too long (253 characters max).'], 'e.domLabel': ['每一段都不能为空, 也不能以连字符开头或结尾', 'No label may be empty or start or end with a hyphen.'],
  'e.domLabelLen': ['每一段最多 63 个字符', 'Each label may have 63 characters at most.'], 'e.domNoDot': ['请填写完整域名 (至少包含一个点, 例如 example.com)', 'Enter a full domain name (at least one dot, for example example.com).'],
  'e.domIp': ['这是 IP 地址, 不是域名', 'This is an IP address, not a domain name.'], 'e.domDup': ['已经有这个域名了', 'This domain is already in the list'], 'e.domNone': ['没有这个域名', 'That domain is not in the list'],
  'e.domGone': ['这个域名已经删除了', 'This domain has already been removed'], 'e.domNotRemoved': ['这个域名没有被删除过', 'This domain was not removed'], 'e.domSame': ['新旧域名一样, 没有修改', 'The old and new domains are the same; nothing changed'],
  'e.domMaxEntry': ['这个条目自定义的域名太多了 (最多 300 条)', 'Too many custom domains for this entry (at most 300)'], 'e.domMaxTotal': ['自定义的域名太多了 (最多 2000 条)', 'Too many custom domains (at most 2000)'],
  /* 新增: 自定义软件 */
  'e.appInput': ['请输入软件的路径或名称', "Enter the app's path or name"], 'e.appRelative': ['请输入绝对路径 (以 / 开头), 或者输入软件名称', 'Enter an absolute path (starting with /), or the app name'],
  'e.appCharsPath': ['路径里有不支持的字符', 'The path contains unsupported characters'], 'e.appCharsName': ['名称里有不支持的字符', 'The name contains unsupported characters'], 'e.appNotFound': ['路径不存在', 'The path does not exist'],
  'e.appNotExec': ['不是应用 (.app) 或可执行文件', 'Not an application (.app) or an executable file'], 'e.appPerm': ['没有读取权限', 'No permission to read it'],
  'e.appNoName': ['没有找到这个软件: 请检查名称, 或者直接输入它的完整路径', 'App not found: check the name, or enter its full path'], 'e.appExists': ['这个软件已经在列表里了', 'This app is already in the list'], 'e.noCustomApp': ['找不到这个自定义软件', 'That custom app was not found'],
  /* 新增: 测速目标 */
  'e.tgtName': ['名称不能为空, 最多 40 个字符', 'The name cannot be empty and can be at most 40 characters'], 'e.tgtNameChars': ['名称里不能有 | < > 这些字符', 'The name cannot contain | < > characters'], 'e.tgtNameCtl': ['名称里不能有控制字符', 'The name cannot contain control characters'],
  'e.tgtNewline': ['内容里不能有换行', 'Line breaks are not allowed here'], 'e.tgtGroup': ['分组无效', 'Invalid group'], 'e.tgtUrl': ['网址必须以 http:// 或 https:// 开头, 不能有空格和引号, 最长 300 个字符', 'The URL must start with http:// or https://, contain no spaces or quotes, and be at most 300 characters'],
  'e.tgtExpect': ['状态码格式不对: 用逗号分隔, 如 200,204,301', 'Invalid status codes: separate them with commas, e.g. 200,204,301'], 'e.tgtIcon': ['图标名无效', 'Invalid icon name'], 'e.tgtId': ['目标编号无效', 'Invalid target ID'],
  'e.noTarget': ['找不到这个测速目标', 'That speed test target was not found'], 'e.noBuiltinTarget': ['找不到这个内置测速目标', 'That built-in speed test target was not found'], 'e.tgtMax': ['自己添加的测速目标太多了 (最多 100 个)', 'Too many custom speed test targets (at most 100)'],
  /* 新增: DNS 自定义解析 / 测速 */
  'e.hostIp': ['IP 地址格式不正确 (支持 IPv4 和 IPv6)', 'The IP address is not valid (IPv4 and IPv6 are supported)'], 'e.hostDup': ['这个域名已经有解析记录了, 请直接修改它', 'This domain already has a DNS record; edit that one instead'],
  'e.hostMax': ['自定义解析太多了 (最多 200 条)', 'Too many custom DNS records (at most 200 entries)'], 'e.hostNone': ['没有这条解析记录', 'That DNS record does not exist'], 'e.hostNewDup': ['新的域名已经有解析记录了', 'The new domain already has a DNS record'],
  'dns.hosts': ['命中的域名直接用你填的 IP, 不再询问任何 DNS; 访问时也会直接连到这个 IP', 'Matching names use the IP you entered without asking any DNS server; connections go straight to that IP too'],
  'dns.direct': ['直连的网站一律用国内 DNS 解析: 苹果、微软等在国内有 CDN 的域名会解析到离你最近的节点, 速度更快', "Direct sites are always resolved with domestic DNS: names such as Apple's or Microsoft's that have CDNs in China resolve to the nearest node, so they load faster"],
  'dns.proxy': ['域名直接交给代理服务器解析, 本机不会向任何 DNS 询问, 不会被污染或泄漏', 'The name is handed to the proxy server to resolve; this computer asks no DNS server, so nothing is polluted or leaked'],
  'dns.hostsName': ['本地对照表', 'Local table'], 'dns.proxyName': ['代理服务器', 'Proxy server'],
  /* 新增: 任务步骤 / 完成消息 */
  'js.saveChg': ['保存你的改动', 'Save your changes'], 'js.regen': ['重新生成配置', 'Regenerate the config'], 'js.hot': ['应用', 'Apply'], 'js.saveApp': ['保存自定义软件', 'Save the custom app'], 'js.setPolicy': ['设置策略', 'Set the policy'],
  'js.dnsBenchCn': ['测试国内 DNS 服务器 (直连)', 'Test the China DNS servers (direct)'], 'js.dnsBenchGlobal': ['测试海外 DNS 服务器 (经自动线路)', 'Test the overseas DNS servers (via the auto route)'],
  'jd.siteDom': ['网站域名已更新, 配置已应用', 'Site domains updated, config applied'], 'jd.siteReset': ['已还原为系统默认, 配置已应用', 'Restored to the system default; config applied'],
  'jd.appAdd': ['自定义软件已添加, 配置已应用', 'Custom app added, config applied'], 'jd.appDel': ['自定义软件已删除, 配置已应用', 'Custom app removed, config applied'],
  'jd.hosts': ['自定义解析已更新, 配置已应用', 'Custom DNS entries updated, config applied'], 'jd.dnsBench': ['DNS 服务器测速完成', 'DNS server benchmark finished'],
  /* 任务: 步骤名 / 完成消息 */
  'js.gen': ['生成配置', 'Generate config'], 'js.check': ['校验配置', 'Validate config'], 'js.apply': ['应用并重启', 'Apply and restart'], 'js.ready': ['等待就绪', 'Wait until ready'],
  'js.restart': ['重启服务', 'Restart service'], 'js.waitSvc': ['等待服务就绪', 'Wait for the service to be ready'],
  'js.prep': ['准备', 'Prepare'], 'js.dlRules': ['下载规则集', 'Download rule sets'], 'js.applyRules': ['应用规则集', 'Apply rule sets'], 'js.finish': ['完成', 'Finish'],
  'js.dlCustom': ['下载规则集文件', 'Download the rule set file'], 'js.validateSrs': ['校验规则集格式', 'Validate the rule set format'],
  'js.netDirect': ['查询本机直连出口 IP', 'Look up the direct exit IP'], 'js.netPin': ['查询固定出口 IP', 'Look up the pinned exit IP'], 'js.netAuto': ['查询自动线路出口 IP', 'Look up the auto route exit IP'],
  'js.updDl': ['下载新版本', 'Download the new version'], 'js.updVerify': ['校验文件', 'Verify the files'], 'js.updReplace': ['替换文件', 'Replace the files'], 'js.updHelper': ['重启辅助服务', 'Restart the helper service'],
  'js.coreDl': ['下载新核心', 'Download the new core'], 'js.coreSha': ['校验 SHA-256', 'Verify SHA-256'], 'js.coreCheck': ['用新核心校验现有配置', 'Validate the current config with the new core'], 'js.coreSwap': ['替换核心', 'Replace the core'],
  'jd.import': ['导入服务器 完成, 配置已应用', 'Import servers done, config applied'], 'jd.delete': ['删除服务器 完成, 配置已应用', 'Delete server done, config applied'],
  'jd.role': ['修改服务器角色 完成, 配置已应用', 'Change server role done, config applied'], 'jd.subdel': ['删除订阅 完成, 配置已应用', 'Delete subscription done, config applied'],
  'jd.settings': ['应用设置 完成, 配置已应用', 'Apply settings done, config applied'], 'jd.dns': ['应用 DNS 设置 完成, 配置已应用', 'Apply DNS settings done, config applied'],
  'jd.toggle': ['规则集设置已应用', 'Rule set setting applied'], 'jd.customAdd': ['自定义规则集已添加', 'Custom rule set added'], 'jd.customDel': ['自定义规则集已删除', 'Custom rule set removed'],
  'js.sshConnect': ['连接服务器', 'Connect to the server'], 'js.sshDetect': ['检测系统与环境', 'Detect the system and environment'], 'js.sshEnv': ['检测依赖与防火墙', 'Check dependencies and firewall'],
  'js.sshDeps': ['安装依赖', 'Install dependencies'], 'js.sshServer': ['安装服务端', 'Install the server software'], 'js.sshConfig': ['生成配置与密钥', 'Generate the config and keys'],
  'js.sshStart': ['开放端口并启动', 'Open the port and start'], 'js.sshVerify': ['验证连通', 'Verify the connection'], 'js.sshIps': ['识别出口 IP', 'Detect the exit IPs'], 'js.sshSave': ['保存到本机', 'Save to this computer'],
  'js.syncCollect': ['收集本机配置', 'Collect the local settings'], 'js.syncEncrypt': ['加密', 'Encrypt'], 'js.syncUpload': ['上传到 enana.cc', 'Upload to enana.cc'],
  'js.syncDownload': ['下载云端数据', 'Download the cloud data'], 'js.syncDecrypt': ['解密', 'Decrypt'], 'js.syncValidate': ['校验', 'Validate'], 'js.syncApply': ['应用到本机', 'Apply to this computer'],
  'jd.vpsProbe': ['检测完成', 'Detection finished'], 'jd.vpsProvision': ['服务器已部署, 已添加 {n} 个节点', 'The server is deployed and {n} node(s) were added'],
  'jd.vpsRedetect': ['已重新识别出口 IP (新增 {n} 个节点)', 'Exit IPs re-detected ({n} new node(s))'], 'jd.syncPush': ['已上传到云端 (版本 {v})', 'Uploaded to the cloud (version {v})'],
  'jd.syncPull': ['已从云端同步 (版本 {v})', 'Synced from the cloud (version {v})'],
  'jd.restart': ['服务已重启', 'Service restarted'], 'jd.rules': ['规则集已更新 ({n} 个有变化, 0 个失败)', 'Rule sets updated ({n} changed, 0 failed)'], 'jd.net': ['已更新', 'Updated'],
  'jd.updApp': ['已更新到 {v}, 辅助服务已重启', 'Updated to {v}; the helper service was restarted.'], 'jd.updCore': ['核心已更新到 {v}', 'Core updated to {v}.'],
  'jd.fail': ['配置未通过校验, 已撤销本次更改: sing-box check 报错 (模拟的失败)', 'The config did not pass validation and the change was rolled back: sing-box check reported an error (simulated failure).'],
  /* 测速 / 本机 IP */
  'sp.ip': ['正在查询本机与各线路的出口 IP', 'Looking up the exit IPs of this computer and each route'], 'sp.direct': ['正在测试本地直连', 'Testing the local direct connection'],
  'sp.node': ['正在测试 {n}', 'Testing {n}'], 'sp.speed': ['正在测试下载速度: {n}', 'Testing download speed: {n}'], 'sp.done': ['测速完成', 'Speed test finished'], 'sp.stopped': ['已停止', 'Stopped'],
  'sp.directName': ['本地直连', 'Local direct'], 'net.pin': ['固定出口', 'Pinned exit'], 'net.auto': ['自动线路', 'Auto route'],
  'net.limited': ['部分线路查询失败: 对应节点可能不可用或出口 IP 被限制', 'Some routes failed to answer: the node may be unavailable or its exit IP may be restricted'],
  'net.blocked': ['查询不到任何出口 IP: 网络不通, 或这个 IP 被限制访问', 'No exit IP could be looked up: the network is down, or this IP is blocked'],
  'net.unknown': ['已查到出口 IP, 但信息不足, 暂时无法判断是否受限', 'Exit IPs were found, but there is not enough information to tell whether they are restricted'],
  /* DNS 流程说明 / 规则集 */
  'dns.ads': ['直接返回空结果, 相关连接也会被拒绝', 'Returns an empty answer; matching connections are rejected too'], 'dns.cn': ['国内域名用国内 DNS 解析, 速度快、结果准确', 'Mainland China domains use the China DNS: fast and accurate'],
  'dns.global': ['海外域名通过代理解析, 避免本地 DNS 污染与泄漏', 'Overseas domains are resolved through the proxy to avoid local DNS pollution and leaks'],
  'dns.noleak': ['防泄漏已关闭: 所有解析都用国内 DNS (可能被污染)', 'Leak protection is off: every lookup uses the China DNS (may be polluted)'],
  'dns.reject': ['拒绝解析', 'Reject'], 'dns.custom': ['自定义 ({host})', 'Custom ({host})'],
  'rs.customDesc': ['自定义规则集', 'Custom rule set'], 'rs.customRepo': ['自定义链接', 'Custom link'], 'grp.custom': ['自定义规则集', 'Custom rule sets']
};
const NOTES = {
  zh: ['新增: 使用 enana.cc 账号登录仪表盘 (本机不再保存管理员密码)', '新增: 一键测速, 对比本地直连与各节点的延迟和下载速度', '改进: 日志页支持按关键字搜索与导出', '修复: 订阅刷新偶尔卡住的问题'].join('\n'),
  en: ['New: sign in to the dashboard with your enana.cc account (no admin password is stored on this computer)', 'New: one-click speed test comparing latency and download speed of local direct vs. each node',
    'Improved: the logs page can search and export', 'Fixed: subscription refresh occasionally getting stuck'].join('\n')
};
function tr(lang, key, v) {
  const p = S[key]; let s = p ? p[lang === 'en' ? 1 : 0] : key;
  return v ? s.replace(/\{(\w+)\}/g, (m, k) => (k in v ? v[k] : m)) : s;
}

/* ===================== 3. 数据: 目录 / 规则库 / DNS 预设 / 测速目标 / 应用 / 服务器 =====================
 * 这里全部是内置的合成数据 (example.* 域名 / RFC 5737 地址 / AS64496+ 号段), 不读取 ../data/*.conf:
 * 真实的精选目录 / 规则库 / 应用推荐由云端内容包下发, 仓库里的 data/*.conf 只是很小的基线, 模拟服务器不依赖它们。 */
const csv = (s) => (s ? s.split(',').filter(Boolean) : []);
const CJK = /[\u3400-\u9fff]/;

/* ---- 网站目录: 12 个分组 / 56 个条目 (中英文名称与说明); 域名只用 example.com / .net / .org ---- */
const GROUPS = [['ai', 'AI · 固定出口', 'AI · Pinned exit'], ['account', '账号类 App · 固定出口', 'Account apps · Pinned exit'], ['exchange', '交易所 / 支付 · 固定出口', 'Exchanges / payments · Pinned exit'],
  ['social', '社交与通讯', 'Social & messaging'], ['video', '视频 · 音乐 · 直播', 'Video · music · live streaming'], ['search', '搜索 · 邮箱 · 云盘', 'Search · mail · cloud storage'],
  ['news', '新闻 · 百科 · 社区', 'News · reference · communities'], ['dev', '开发者与云服务', 'Developer & cloud services'], ['shop', '购物与其它受限网站', 'Shopping & other restricted sites'],
  ['game', '游戏', 'Gaming'], ['tools', '工具', 'Tools'], ['direct', '直连', 'Direct']];
const DOM_SUF = ['', '-cdn', '-api', '-static', '-img', '-auth', '-app', '-edge', '-media', '-update', '-push', '-files', '-assets', '-stream', '-sso', '-mail', '-docs', '-help', '-live', '-wiki'], DOM_TLD = ['example.com', 'example.net', 'example.org'];
function genDomains(id, n) {                                               // 一个条目的系统域名: <id>[-后缀][序号].example.<com|net|org>, 互不重复
  const out = []; for (let i = 0; i < n; i++) { const k = Math.floor(i / DOM_SUF.length); out.push(id + DOM_SUF[i % DOM_SUF.length] + (k ? String(k + 1) : '') + '.' + DOM_TLD[i % 3]); }
  return out;
}
/* [id, 中文名, English, 分组, 默认策略, 中文说明, English description, 域名 (个数 = 自动生成 / 逗号串 = 指定), 社区规则集, IP 段个数] */
const CAT_ROWS = [
  ['claude', 'Claude', 'Claude', 'ai', 'pin', 'Claude 网页与桌面应用', 'Claude web and desktop apps', 'claude.example.com,claude.example.net,claude-api.example.org,claude-cdn.example.com,claude-static.example.net,claude-auth.example.org', [], 0],
  ['chatgpt', 'ChatGPT / OpenAI', 'ChatGPT / OpenAI', 'ai', 'pin', 'ChatGPT、Sora、OpenAI API', 'ChatGPT, Sora and the OpenAI API', 'chat.example.com,chat.example.net,chat-cdn.example.org,chat-api.example.com,sora.example.net,openai-api.example.org,chat-static.example.com', [], 0],
  ['gemini', 'Gemini', 'Gemini', 'ai', 'pin', 'Gemini、AI Studio、NotebookLM; 含 Google 登录域名', 'Gemini, AI Studio and NotebookLM; includes Google sign-in domains', 'gemini.example.com,gemini-studio.example.net,notebook.example.org,gemini-api.example.com,gemini-login.example.net', [], 0],
  ['ai-common', 'AI 共用依赖', 'AI shared dependencies', 'ai', 'pin', 'AI 产品共用的统计、客服与登录服务', 'Analytics, support and sign-in services shared by AI products', 'ai-stats.example.com,ai-support.example.net,ai-login.example.org,ai-metrics.example.com,ai-feedback.example.net', [], 0],
  ['ai-other', '其它 AI 服务', 'Other AI services', 'ai', 'pin', '社区维护的「境外 AI」规则集, 另含 Perplexity、Grok、Cursor、Hugging Face 等', 'Community "overseas AI" rule set plus Perplexity, Grok, Cursor, Hugging Face and more', 12, ['geosite-ai'], 0],
  ['telegram', 'Telegram', 'Telegram', 'account', 'pin', 'Telegram 及其服务器 IP 段 (按 IP 直连的应用也能匹配)', 'Telegram and its server IP ranges (also matches apps that connect by IP)', 'telegram.example.org,telegram.example.net,t-me.example.com,telegram-cdn.example.org,telegram-api.example.net', ['geosite-telegram'], 14],
  ['line', 'LINE', 'LINE', 'account', 'pin', 'LINE 即时通讯', 'LINE messaging', 3, [], 0],
  ['signal', 'Signal', 'Signal', 'account', 'pin', 'Signal 加密通讯', 'Signal encrypted messaging', 4, [], 0],
  ['meta', 'Meta (Facebook / Instagram / WhatsApp)', 'Meta (Facebook / Instagram / WhatsApp)', 'account', 'pin', 'Facebook、Instagram、Threads 与 WhatsApp', 'Facebook, Instagram, Threads and WhatsApp', 10, [], 8],
  ['x', 'X (Twitter)', 'X (formerly Twitter)', 'account', 'pin', 'X (原 Twitter)', 'X (formerly Twitter)', 6, ['geosite-twitter'], 0],
  ['tiktok', 'TikTok', 'TikTok', 'account', 'pin', 'TikTok 国际版; 对 IP 与地区敏感', 'TikTok international; sensitive to IP and region', 7, ['geosite-tiktok'], 0],
  ['exchange', '交易所 / 支付', 'Exchanges / payments', 'exchange', 'pin', '加密货币交易所与支付; 频繁换 IP 可能触发风控', 'Crypto exchanges and payments; frequent IP changes can trigger risk controls', 'exchange.example.com,exchange.example.net,exchange-api.example.org,exchange-ws.example.com,exchange-cdn.example.net,wallet.example.org', ['geosite-binance', 'geosite-crypto'], 0],
  ['payments', '海外支付', 'Overseas payments', 'exchange', 'pin', '海外在线支付与收款服务', 'Overseas online payment and payout services', 'pay.example.com,pay-secure.example.net,checkout.example.org,pay-api.example.com', [], 0],
  ['reddit', 'Reddit', 'Reddit', 'social', 'auto', 'Reddit 社区', 'Reddit communities', 6, [], 0],
  ['discord', 'Discord', 'Discord', 'social', 'auto', 'Discord 语音与社区', 'Discord voice and communities', 'chat.example.org,chat-media.example.net,chat-gateway.example.com,chat-cdn.example.net,chat-voice.example.org', [], 0],
  ['slack', 'Slack', 'Slack', 'social', 'auto', 'Slack 工作聊天', 'Slack workplace chat', 4, [], 0],
  ['zoom', 'Zoom', 'Zoom', 'social', 'auto', 'Zoom 视频会议', 'Zoom video meetings', 5, [], 6],
  ['linkedin', 'LinkedIn', 'LinkedIn', 'social', 'auto', '领英职场社交', 'LinkedIn professional network', 4, [], 0],
  ['pinterest', 'Pinterest', 'Pinterest', 'social', 'auto', 'Pinterest 图片灵感', 'Pinterest image inspiration', 3, [], 0],
  ['youtube', 'YouTube', 'YouTube', 'video', 'auto', 'YouTube 视频', 'YouTube videos', 'video.example.net,video.example.com,video-cdn.example.org,video-thumb.example.net,video-api.example.com,video-live.example.org,video-ads.example.net', ['geosite-youtube'], 0],
  ['netflix', 'Netflix', 'Netflix', 'video', 'auto', 'Netflix (可用性取决于所选节点)', 'Netflix (availability depends on the chosen node)', 6, ['geosite-netflix'], 6],
  ['disney', 'Disney+', 'Disney+', 'video', 'auto', 'Disney+', 'Disney+', 4, ['geosite-disney'], 0],
  ['hbo', 'HBO Max', 'HBO Max', 'video', 'auto', 'HBO Max', 'HBO Max', 3, [], 0],
  ['twitch', 'Twitch', 'Twitch', 'video', 'auto', 'Twitch 直播', 'Twitch live streaming', 4, [], 0],
  ['spotify', 'Spotify', 'Spotify', 'video', 'auto', 'Spotify 音乐', 'Spotify music', 'music.example.com,music.example.net,music-cdn.example.org,music-api.example.com', [], 0],
  ['soundcloud', 'SoundCloud', 'SoundCloud', 'video', 'auto', 'SoundCloud 音乐', 'SoundCloud music', 3, [], 0],
  ['google', 'Google (搜索 / Gmail / 地图 / 云端硬盘)', 'Google (Search / Gmail / Maps / Drive)', 'search', 'auto', 'Google 全家桶 (不含 Gemini, 它在「AI」里固定出口)', 'The Google suite (excluding Gemini, which is pinned under "AI")', 'search.example.com,search.example.net,search-static.example.org,mail-search.example.com,maps.example.net,drive.example.org,search-api.example.com,search-cdn.example.net', [], 0],
  ['search-other', '其它搜索引擎', 'Other search engines', 'search', 'auto', '其它搜索引擎', 'Other search engines', 4, [], 0],
  ['dropbox', 'Dropbox', 'Dropbox', 'search', 'auto', '云盘', 'Cloud storage', 4, [], 0],
  ['archive', '网页存档', 'Web archive', 'search', 'auto', '网页存档与历史快照', 'Web archive and history snapshots', 3, [], 0],
  ['proton', '加密邮箱', 'Encrypted mail', 'search', 'auto', '端到端加密邮箱', 'End-to-end encrypted mail', 4, [], 0],
  ['wikipedia', '维基百科', 'Wikipedia', 'news', 'auto', '维基百科及其姊妹项目', 'Wikipedia and its sister projects', 8, ['geosite-wikimedia'], 0],
  ['news-us', '美国新闻媒体', 'US news media', 'news', 'auto', '纽约时报、华尔街日报、彭博、CNN、福布斯 (域名很多, 用来测试分页)', 'The New York Times, WSJ, Bloomberg, CNN and Forbes (many domains, handy for testing pagination)', 61, ['geosite-nytimes', 'geosite-wsj', 'geosite-bloomberg', 'geosite-forbes'], 0],
  ['news-intl', '国际新闻媒体', 'International news media', 'news', 'auto', 'BBC、路透社、卫报、经济学人、金融时报、德国之声', 'BBC, Reuters, The Guardian, The Economist, Financial Times and Deutsche Welle', 18, ['geosite-reuters', 'geosite-guardian', 'geosite-economist', 'geosite-ft', 'geosite-dw'], 0],
  ['ted', 'TED', 'TED', 'news', 'auto', 'TED 演讲', 'TED talks', 3, [], 0],
  ['medium', 'Medium', 'Medium', 'news', 'auto', 'Medium 博客平台', 'Medium blogging platform', 3, [], 0],
  ['github', 'GitHub', 'GitHub', 'dev', 'auto', '代码托管', 'Code hosting', 'repo.example.com,repo.example.net,repo-api.example.org,repo-raw.example.com,repo-pages.example.net,repo-cdn.example.org', [], 0],
  ['stackexchange', 'Stack Exchange', 'Stack Exchange', 'dev', 'auto', '程序员问答', 'Programmer Q&A', 4, [], 0],
  ['containers', 'Docker / 容器镜像', 'Docker / Containers', 'dev', 'auto', 'Docker Hub 与镜像仓库', 'Docker Hub and image registries', 'registry.example.com,registry.example.net,registry-auth.example.org,registry-blobs.example.com,registry-cdn.example.net,registry-index.example.org', [], 0],
  ['pkg', '语言包仓库', 'Language package registries', 'dev', 'auto', 'npm / PyPI / crates 等语言包仓库', 'Language package registries such as npm, PyPI and crates', 10, [], 0],
  ['dev-platforms', '托管与云平台', 'Hosting and cloud platforms', 'dev', 'auto', '托管与云平台', 'Hosting and cloud platforms', 14, [], 0],
  ['cloudflare', 'Cloudflare', 'Cloudflare', 'dev', 'auto', 'Cloudflare 服务', 'Cloudflare services', 5, [], 22],
  ['dev-misc', '开发者工具与数据科学', 'Developer tools and data science', 'dev', 'auto', '开发者工具与数据科学; 含社区「开发者」规则集 (域名很多, 用来测试分页)', 'Developer tools and data science; includes the community "developer" rule set (many domains, handy for testing pagination)', 72, ['geosite-dev'], 0],
  ['amazon', '海外购物', 'Overseas shopping', 'shop', 'auto', '海外购物网站', 'Overseas shopping', 8, [], 0],
  ['blogs', '博客平台', 'Blogging platforms', 'shop', 'auto', '博客平台', 'Blogging platforms', 5, [], 0],
  ['ao3', '同人创作站', 'Fan fiction site', 'shop', 'auto', '同人创作网站', 'Fan fiction site', 3, [], 0],
  ['misc-global', '其它常用海外网站', 'Other popular overseas sites', 'shop', 'auto', '短链接及类似服务 (域名很多, 用来测试分页)', 'Short links and similar (many domains, handy for testing pagination)', 88, [], 0],
  ['steam', 'Steam', 'Steam', 'game', 'direct', 'Steam 商店与社区 (下载有国内 CDN, 直连更快)', 'Steam store and community (it has a CDN in China, so direct is faster)', 6, ['geosite-steam'], 0],
  ['epic', 'Epic Games', 'Epic Games', 'game', 'auto', 'Epic 游戏商店', 'Epic Games store', 4, [], 0],
  ['ipcheck-pin', '出口 IP 检测 (固定出口)', 'Exit IP check (pinned exit)', 'tools', 'pin', '仪表盘用它显示固定出口的 IP', 'Used by the dashboard to show the pinned exit IP', 3, [], 0],
  ['ipcheck-auto', '出口 IP 检测 (自动线路)', 'Exit IP check (auto route)', 'tools', 'auto', '仪表盘用它显示自动线路的 IP', 'Used by the dashboard to show the auto route IP', 3, [], 0],
  ['speedtest', '测速网站', 'Speed test sites', 'tools', 'auto', 'Speedtest、Cloudflare 与 Fast.com 测速', 'Speedtest, Cloudflare and Fast.com speed tests', 5, ['geosite-speedtest'], 0],
  ['workspace', '协作与设计工具', 'Collaboration and design tools', 'tools', 'auto', 'Notion、Figma 等协作与设计工具', 'Collaboration and design tools such as Notion and Figma', 8, [], 0],
  ['apple', 'Apple / iCloud', 'Apple / iCloud', 'direct', 'direct', 'Apple 服务在国内有 CDN, 直连更快', 'Apple services have CDNs in China, so direct is faster', 'apple.example.com,apple.example.net,apple-cdn.example.org,icloud.example.com,apple-update.example.net', [], 0],
  ['microsoft-cn', '微软 / Office 更新', 'Microsoft / Office updates', 'direct', 'direct', '微软更新与 Office (国内有 CDN)', 'Microsoft updates and Office (CDN in China)', 6, [], 0],
  ['cn-mirrors', '国内镜像站', 'China mirrors', 'direct', 'direct', '国内常用的开源镜像站', 'Popular open-source mirrors in China', 9, [], 0]];
function buildCatalog() {
  const groups = {}, groups_en = {}, order = GROUPS.map((g) => { groups[g[0]] = g[1]; groups_en[g[0]] = g[2]; return g[0]; });
  const entries = CAT_ROWS.map((r) => ({ id: r[0], tag: 'svc-' + r[0], name: r[1], name_en: r[2], group: r[3], default: r[4], desc: r[5], desc_en: r[6], domains: typeof r[7] === 'number' ? genDomains(r[0], r[7]) : csv(r[7]), rulesets: r[8], cidrs: r[9] }));
  return { groups, groups_en, order, entries };
}
const CAT = buildCatalog();
const POL = { pin: 'PIN', auto: 'Global', direct: 'direct' };

/* ---- 规则库: 26 个社区规则集 (3 个必选) ---- */
/* [tag, 中文名, English, 中文说明 (空 = 自动), English description (空 = 自动), essential, 默认启用] */
const RS_ROWS = [
  ['geosite-cn', '国内网站', 'Mainland China sites', '中国大陆网站域名 → 直连', 'Mainland China website domains → direct', 1, 1],
  ['geosite-notcn', '海外网站', 'Overseas sites', '非中国大陆网站域名 → 兜底策略 (默认自动线路)', 'Non-mainland-China website domains → fallback policy (default: auto route)', 1, 1],
  ['geoip-cn', '国内 IP 段', 'Mainland China IP ranges', '中国大陆 IP → 直连 (其余域名解析后按 IP 判断)', 'Mainland China IPs → direct (other domains are resolved first, then judged by IP)', 1, 1],
  ['geosite-ai', '境外 AI 服务', 'Overseas AI services', '社区维护的境外 AI 产品域名 → 固定出口', 'Community-maintained overseas AI product domains → pinned exit', 0, 1],
  ['geosite-ads', '广告与追踪', 'Ads and trackers', '广告 / 追踪域名 → 拒绝连接 (仅在 DNS 页打开「屏蔽广告」时下载)', 'Ad and tracker domains → rejected (downloaded only when "Block ads" is on in the DNS page)', 0, 0],
  ['geosite-binance', '币安', 'Binance', '', '', 0, 1], ['geosite-crypto', '加密货币', 'Cryptocurrency', '', '', 0, 1], ['geosite-speedtest', '测速网站', 'Speed test sites', '', '', 0, 1],
  ['geosite-wikimedia', '维基媒体', 'Wikimedia', '', '', 0, 1], ['geosite-nytimes', '纽约时报', 'The New York Times', '', '', 0, 0], ['geosite-wsj', '华尔街日报', 'The Wall Street Journal', '', '', 0, 0],
  ['geosite-bloomberg', '彭博', 'Bloomberg', '', '', 0, 0], ['geosite-forbes', '福布斯', 'Forbes', '', '', 0, 0], ['geosite-reuters', '路透社', 'Reuters', '', '', 0, 0],
  ['geosite-guardian', '卫报', 'The Guardian', '', '', 0, 0], ['geosite-economist', '经济学人', 'The Economist', '', '', 0, 0], ['geosite-ft', '金融时报', 'Financial Times', '', '', 0, 0],
  ['geosite-dw', '德国之声', 'Deutsche Welle', '', '', 0, 0], ['geosite-netflix', '奈飞', 'Netflix', '', '', 0, 0], ['geosite-disney', 'Disney+', 'Disney+', '', '', 0, 0],
  ['geosite-twitter', 'X (Twitter)', 'X (Twitter)', '', '', 0, 1], ['geosite-tiktok', 'TikTok', 'TikTok', '', '', 0, 1], ['geosite-telegram', 'Telegram', 'Telegram', '', '', 0, 1],
  ['geosite-youtube', 'YouTube', 'YouTube', '', '', 0, 1], ['geosite-dev', '开发者网站', 'Developer sites', '', '', 0, 1], ['geosite-steam', 'Steam', 'Steam', '', '', 0, 0]];
const RULESETS = RS_ROWS.map((r) => ({ tag: r[0], repo: r[0].indexOf('geoip-') === 0 ? 'example/sing-geoip' : 'example/sing-geosite', name: r[1], desc: r[3] || (r[1] + ' 域名 (社区规则集)'), essential: !!r[5], def: !!r[6], name_en: r[2], desc_en: r[4] || (r[2] + ' domains (community rule set)') }));
const ruleSize = (tag) => (tag === 'geosite-cn' ? 172340 : tag === 'geoip-cn' ? 133516 : tag === 'geosite-notcn' ? 538220 : 3000 + hash(tag) % 62000);

/* ---- DNS 预设: 国内 8 个 (含自定义) / 海外 7 个 (含自定义); 地址全是 RFC 5737 占位 IP ---- */
const dnsP = (id, name, desc, nameEn, descEn, url) => ({ id, name, desc, url, name_en: nameEn, desc_en: descEn });
const DNS_PRESETS = {
  cn: [dnsP('system', '系统默认', '使用系统设置里的 DNS, 不额外加密', 'System default', 'Uses the DNS from the system settings, no extra encryption', 'system'),
    dnsP('alidns', '阿里 DNS (DoH)', '198.51.100.5, 国内最常用, 稳定、延迟低', 'AliDNS (DoH)', '198.51.100.5, the most used in China: stable and low latency', 'https://198.51.100.5/dns-query'),
    dnsP('dnspod', '腾讯 DNSPod (DoH)', '198.51.100.12, 腾讯公共 DNS (HTTPS 加密)', 'Tencent DNSPod (DoH)', '198.51.100.12, Tencent public DNS over HTTPS', 'https://198.51.100.12/dns-query'),
    dnsP('dnspod-dot', '腾讯 DNSPod (DoT)', '198.51.100.12, 腾讯公共 DNS (TLS 加密, 853 端口)', 'Tencent DNSPod (DoT)', '198.51.100.12, Tencent public DNS over TLS (port 853)', 'tls://198.51.100.12'),
    dnsP('114', '114DNS (UDP)', '传统 UDP, 无加密, 兼容性最好', '114DNS (UDP)', 'Traditional UDP, unencrypted, best compatibility', 'udp://198.51.100.114'),
    dnsP('baidu', '百度 DNS (UDP)', '198.51.100.180, 传统 UDP, 无加密', 'Baidu DNS (UDP)', '198.51.100.180, traditional UDP, unencrypted', 'udp://198.51.100.180'),
    dnsP('cnnic', 'CNNIC DNS (UDP)', '198.51.100.8, 中国互联网络信息中心, 无加密', 'CNNIC DNS (UDP)', '198.51.100.8, run by the China Internet Network Information Center, unencrypted', 'udp://198.51.100.8'),
    dnsP('custom', '自定义', '', 'Custom', '', '')],
  global: [dnsP('cloudflare', 'Cloudflare (DoH)', '203.0.113.1, 速度快, 隐私友好', 'Cloudflare (DoH)', '203.0.113.1, fast and privacy-friendly', 'https://203.0.113.1/dns-query'),
    dnsP('cloudflare-security', 'Cloudflare 安全版 (DoH)', '203.0.113.2, 自带恶意软件拦截', 'Cloudflare Security (DoH)', '203.0.113.2, with built-in malware blocking', 'https://203.0.113.2/dns-query'),
    dnsP('google', 'Google (DoH)', '203.0.113.8, 全球覆盖广', 'Google (DoH)', '203.0.113.8, wide global coverage', 'https://203.0.113.8/dns-query'),
    dnsP('quad9', 'Quad9 (DoH)', '203.0.113.9, 自带恶意域名拦截', 'Quad9 (DoH)', '203.0.113.9, with built-in malicious-domain blocking', 'https://203.0.113.9/dns-query'),
    dnsP('adguard', 'AdGuard (DoH)', '203.0.113.53, 自带广告与追踪拦截', 'AdGuard (DoH)', '203.0.113.53, with built-in ad and tracker blocking', 'https://203.0.113.53/dns-query'),
    dnsP('opendns', 'OpenDNS (DoH)', '203.0.113.67, 可选内容过滤', 'OpenDNS (DoH)', '203.0.113.67, optional content filtering', 'https://203.0.113.67/dns-query'),
    dnsP('custom', '自定义', '', 'Custom', '', '')] };
const dnsPreset = (scope, id) => DNS_PRESETS[scope].filter((p) => p.id === id)[0] || null;
/* 与 lib/dns.sh 的 dns_valid_url 同一个正则: system / udp:// / tls:// / https:// */
const dnsUrlOk = (u) => u === 'system' || (u.length <= 200 && /^(udp|tls|https):\/\/(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9.-]+)(:[0-9]{1,5})?(\/[A-Za-z0-9._~\/%-]*)?$/.test(u));

/* ---- 测速目标: 63 个内置目标 (global 15 / cn 12 / carrier 6 / dev 16 / media 14), 其中 20 个默认勾选; 对外只暴露 *.example.com 的占位地址 ---- */
/* [id, 分组, 中文名, English, 路径, 可接受的状态码, 图标 (Lucide), 默认勾选] */
const TGT_GROUPS = ['global', 'cn', 'carrier', 'dev', 'media'];
const TGT_ROWS = [
  ['google', 'global', 'Google', 'Google', '/generate_204', '204', 'search', 1], ['youtube', 'global', 'YouTube', 'YouTube', '/generate_204', '204', 'youtube', 1], ['github', 'global', 'GitHub', 'GitHub', '/', '200,301,302', 'github', 1],
  ['cloudflare', 'global', 'Cloudflare', 'Cloudflare', '/cdn-cgi/trace', '200', 'cloud', 1], ['claude', 'global', 'Claude', 'Claude', '/', '200,301,302,307,403', 'sparkles', 1], ['chatgpt', 'global', 'ChatGPT', 'ChatGPT', '/', '200,301,302,307,403', 'message-square', 1],
  ['gemini', 'global', 'Gemini', 'Gemini', '/', '200,301,302,303,307', 'sparkles', 1], ['tiktok', 'global', 'TikTok', 'TikTok', '/', '200,301,302,307', 'music', 1], ['wikipedia', 'global', '维基百科', 'Wikipedia', '/', '200', 'book-open', 1],
  ['facebook', 'global', 'Facebook', 'Facebook', '/', '200,301,302', 'users', 0], ['instagram', 'global', 'Instagram', 'Instagram', '/', '200,301,302', 'image', 0], ['x', 'global', 'X (Twitter)', 'X (Twitter)', '/', '200,301,302', 'at-sign', 0],
  ['reddit', 'global', 'Reddit', 'Reddit', '/', '200,301,302', 'message-circle', 0], ['telegram', 'global', 'Telegram', 'Telegram', '/', '200,301,302', 'send', 0], ['whatsapp', 'global', 'WhatsApp', 'WhatsApp', '/', '200,301,302', 'phone', 0],
  ['bing', 'cn', '必应 Bing', 'Bing', '/', '200,301,302', 'search', 1], ['baidu', 'cn', '百度', 'Baidu', '/', '200,302', 'search', 1], ['163', 'cn', '网易 163', 'NetEase 163', '/', '200,301,302', 'mail', 1],
  ['jd', 'cn', '京东', 'JD.com', '/', '200,301,302', 'shopping-cart', 1], ['taobao', 'cn', '淘宝', 'Taobao', '/', '200,301,302', 'shopping-bag', 1], ['qq', 'cn', '腾讯 QQ', 'Tencent QQ', '/', '200,301,302', 'message-circle', 1],
  ['bilibili', 'cn', '哔哩哔哩', 'Bilibili', '/', '200,301,302', 'tv', 0], ['weibo', 'cn', '微博', 'Weibo', '/', '200,301,302', 'rss', 0], ['zhihu', 'cn', '知乎', 'Zhihu', '/', '200,301,302', 'help-circle', 0],
  ['douyin', 'cn', '抖音', 'Douyin', '/', '200,301,302', 'video', 0], ['alipay', 'cn', '支付宝', 'Alipay', '/', '200,301,302', 'wallet', 0], ['wechat', 'cn', '微信', 'WeChat', '/', '200,301,302', 'message-square', 0],
  ['ct', 'carrier', '中国电信', 'China Telecom', '/', '200,301,302,412', 'signal', 1], ['cu', 'carrier', '中国联通', 'China Unicom', '/', '200,301,302', 'signal', 1], ['cm', 'carrier', '中国移动', 'China Mobile', '/', '200,206,301,302', 'signal', 1],
  ['cbn', 'carrier', '中国广电', 'China Broadnet', '/', '200,301,302', 'radio', 0], ['cernet', 'carrier', '教育网 CERNET', 'CERNET (education)', '/', '200,301,302', 'graduation-cap', 0], ['cstnet', 'carrier', '科技网 CSTNET', 'CSTNET (science)', '/', '200,301,302', 'flask-conical', 0],
  ['npm', 'dev', 'npm', 'npm', '/', '200,301,302', 'package', 1], ['pypi', 'dev', 'PyPI', 'PyPI', '/simple/', '200,301,302', 'package', 0], ['docker', 'dev', 'Docker Hub', 'Docker Hub', '/v2/', '200,401', 'container', 0],
  ['ghcr', 'dev', 'GitHub Packages', 'GitHub Packages', '/v2/', '200,401', 'container', 0], ['gitlab', 'dev', 'GitLab', 'GitLab', '/', '200,301,302', 'git-branch', 0], ['stackoverflow', 'dev', 'Stack Overflow', 'Stack Overflow', '/', '200,301,302', 'code', 0],
  ['crates', 'dev', 'crates.io', 'crates.io', '/', '200,301,302', 'package', 0], ['go-proxy', 'dev', 'Go 模块代理', 'Go module proxy', '/', '200,301,302', 'terminal', 0], ['maven', 'dev', 'Maven Central', 'Maven Central', '/', '200,301,302', 'package', 0],
  ['homebrew', 'dev', 'Homebrew', 'Homebrew', '/', '200,301,302', 'beer', 0], ['vscode-market', 'dev', 'VS Code 扩展市场', 'VS Code Marketplace', '/', '200,301,302', 'puzzle', 0], ['huggingface', 'dev', 'Hugging Face', 'Hugging Face', '/', '200,301,302', 'brain', 0],
  ['aws', 'dev', 'AWS 控制台', 'AWS Console', '/', '200,301,302,403', 'server', 0], ['azure', 'dev', 'Azure 门户', 'Azure Portal', '/', '200,301,302,403', 'cloud', 0], ['gcp', 'dev', 'Google Cloud', 'Google Cloud', '/', '200,301,302', 'cloud', 0],
  ['vercel', 'dev', 'Vercel', 'Vercel', '/', '200,301,302', 'triangle', 0],
  ['netflix', 'media', 'Netflix', 'Netflix', '/', '200,301,302,403', 'film', 1], ['disney', 'media', 'Disney+', 'Disney+', '/', '200,301,302', 'tv', 0], ['hbo', 'media', 'HBO Max', 'HBO Max', '/', '200,301,302', 'tv', 0],
  ['hulu', 'media', 'Hulu', 'Hulu', '/', '200,301,302', 'play', 0], ['spotify', 'media', 'Spotify', 'Spotify', '/', '200,301,302', 'headphones', 0], ['soundcloud', 'media', 'SoundCloud', 'SoundCloud', '/', '200,301,302', 'headphones', 0],
  ['twitch', 'media', 'Twitch', 'Twitch', '/', '200,301,302', 'gamepad-2', 0], ['vimeo', 'media', 'Vimeo', 'Vimeo', '/', '200,301,302', 'video', 0], ['apple-music', 'media', 'Apple Music', 'Apple Music', '/', '200,301,302', 'music', 0],
  ['youtube-music', 'media', 'YouTube Music', 'YouTube Music', '/', '200,301,302', 'music', 0], ['prime-video', 'media', 'Prime Video', 'Prime Video', '/', '200,301,302', 'film', 0], ['steam', 'media', 'Steam', 'Steam', '/', '200,301,302', 'gamepad-2', 0],
  ['pixiv', 'media', 'Pixiv', 'Pixiv', '/', '200,301,302', 'image', 0], ['imgur', 'media', 'Imgur', 'Imgur', '/', '200,301,302', 'image', 0]];
const BUILTIN_TGT = TGT_ROWS.map((r) => ({ id: r[0], group: r[1], zh: r[2], en: r[3], url: 'https://' + r[0] + '.example.com' + r[4], expect: csv(r[5]).map(Number), icon: r[6], def: !!r[7] }));

/* ---- 应用: 30 个已安装 (3 个是刚装的) + 推荐的初始设置 (名称结尾 * 为通配, 不分大小写) ---- */
const REC = [['Claude', 'pin', 'AI'], ['ChatGPT', 'pin', 'AI'], ['Perplexity', 'pin', 'AI'], ['Codex', 'pin', 'AI'], ['Gemini', 'pin', 'AI'], ['Cursor', 'pin', 'AI'], ['Telegram*', 'pin', '社交'], ['WhatsApp', 'auto', '社交'], ['Discord', 'auto', '社交'],
  ['Slack', 'auto', '社交'], ['zoom.us', 'auto', '社交'], ['WeChat', 'direct', '国内'], ['QQ', 'direct', '国内'], ['NeteaseMusic', 'direct', '国内'], ['WPS Office', 'direct', '国内'], ['Visual Studio Code', 'auto', '开发'], ['Docker Desktop', 'auto', '开发'],
  ['Postman', 'auto', '开发'], ['iTerm', 'follow', '开发'], ['Google Chrome', 'follow', '浏览器'], ['Safari', 'follow', '浏览器'], ['Arc', 'follow', '浏览器'], ['Firefox', 'follow', '浏览器'], ['Obsidian', 'follow', '效率'], ['Notion', 'auto', '效率'],
  ['Figma', 'auto', '效率'], ['Linear', 'auto', '效率'], ['Raycast', 'follow', '效率'], ['1Password', 'direct', '效率'], ['Spotify', 'auto', '媒体'], ['Steam', 'direct', '游戏'], ['ClashX Pro', 'direct', '代理工具'], ['Preview', 'follow', '系统']]
  .map((a) => ({ pat: a[0].toLowerCase(), rec: a[1], group: a[2] }));
function recOf(name) {
  const n = name.toLowerCase();
  for (const r of REC) { if (r.pat.endsWith('*') ? n.startsWith(r.pat.slice(0, -1)) : n === r.pat) return r; }
  return null;
}
const INSTALLED = ['Claude', 'ChatGPT', 'Google Chrome', 'Safari', 'Arc', 'Firefox', 'Telegram', 'WeChat', 'Discord', 'WhatsApp', 'Slack', 'zoom.us', 'Visual Studio Code', 'Docker Desktop', 'Postman', 'Notion', 'Figma', 'Linear', 'Spotify', 'Steam', 'QQ',
  'NeteaseMusic', 'WPS Office', 'ClashX Pro', '1Password', 'iTerm', 'Preview', /* 新装: */ 'Perplexity', 'Obsidian', 'Raycast'];
const NEW_APPS = ['Perplexity', 'Obsidian', 'Raycast'];
const NO_ICON = ['zoom.us', 'ClashX Pro', 'WPS Office'], BROKEN_ICON = ['Steam'];                 // 取不到图标的应用 (icon:"") / 宣称有图标但图片 404 的应用 (测试 onerror 兜底)
const appPath = (name) => (M.os === 'windows' ? (name === 'Google Chrome' ? 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe' : 'C:\\Program Files\\' + name + '\\' + name + '.exe') : '/Applications/' + name + '.app');
const shortcutText = () => (M.os === 'windows' ? 'enana' : '/usr/local/bin/enana');

/* ---- 服务器 (27 台: 2 固定出口 + 2 下载专用 + 20 自动池 + 3 停用) ---- */
const TYPE_NAME = { trojan: 'Trojan', hysteria2: 'Hysteria2', tuic: 'TUIC', vless: 'VLESS', shadowsocks: 'Shadowsocks', http: 'HTTP', socks: 'SOCKS' };
function seedServers() {
  const s = [];
  s.push({ tag: '东京 专线 A', type: 'trojan', server: '203.0.113.10', port: 443, role: 'pin', sub: '' });
  s.push({ tag: '大阪 专线 B', type: 'trojan', server: '203.0.113.11', port: 443, role: 'pin', sub: '' });
  s.push({ tag: '下载备用 HTTP', type: 'http', server: '203.0.113.20', port: 8080, role: 'dl', sub: '' });
  s.push({ tag: '下载备用 SOCKS5', type: 'socks', server: '203.0.113.21', port: 1080, role: 'dl', sub: '' });
  const regions = ['香港', '日本', '新加坡', '美国', '台湾', '韩国', '英国', '德国'], types = ['trojan', 'hysteria2', 'tuic', 'vless', 'shadowsocks'];
  for (let i = 0; i < 20; i++) s.push({ tag: regions[i % regions.length] + ' ' + String(Math.floor(i / regions.length) + 1).padStart(2, '0'), type: types[i % types.length], server: '203.0.113.' + (30 + i), port: [443, 8443, 10086][i % 3], role: 'auto', sub: 'demo-sub' });
  s.push({ tag: '备用 手动 1', type: 'trojan', server: 'node1.example.com', port: 443, role: 'off', sub: '' });
  s.push({ tag: '备用 手动 2', type: 'shadowsocks', server: '198.51.100.7', port: 8388, role: 'off', sub: '' });
  s.push({ tag: '备用 手动 3', type: 'vless', server: '198.51.100.8', port: 443, role: 'off', sub: '' });
  return s;
}
const SEED = seedServers(), SEED_PIN = SEED.filter((s) => s.role === 'pin').map((s) => s.tag), SEED_AUTO = SEED.filter((s) => s.role === 'auto').map((s) => s.tag), SEED_DL = SEED.filter((s) => s.role === 'dl').map((s) => s.tag);
const typeOfTag = (tag) => { const s = SEED.filter((x) => x.tag === tag)[0]; return s ? s.type : 'trojan'; };

/* ---- 订阅内容 (全部是占位数据) ---- */
function subLinks(variant) {
  const L = [], e = encodeURIComponent;
  for (let i = 0; i < 24; i++) {
    const nm = ['香港', '日本', '新加坡', '美国', '台湾', '韩国'][i % 6] + ' HTTPS ' + String(Math.floor(i / 6) + 1).padStart(2, '0');
    if (i % 8 === 7) L.push('https://203.0.113.' + (60 + i) + ':8443#' + e(nm));                       // 没有账号密码 -> 带 ⚠, 默认不勾选
    else L.push('https://user' + i + ':pass-example-' + i + '@203.0.113.' + (60 + i) + ':8443?sni=example.com#' + e(nm));
  }
  for (let i = 0; i < 4; i++) L.push('tuic://11111111-2222-3333-4444-55555555550' + i + ':tuic-pass-' + i + '@203.0.113.' + (100 + i) + ':443?sni=example.com&congestion_control=bbr#' + e('TUIC 美国 0' + (i + 1)));
  for (let i = 0; i < 4; i++) L.push('hysteria2://hy2-pass-' + i + '@203.0.113.' + (110 + i) + ':8443?sni=example.com#' + e('Hysteria2 日本 0' + (i + 1)));
  L.push('vless://11111111-2222-3333-4444-555555555599@203.0.113.120:443?security=tls&sni=example.com&type=ws&path=%2Fws#' + e('VLESS 新加坡 01'));
  L.push('trojan://x@127.0.0.1:1#' + e('剩余流量: 100 GB'));
  L.push('trojan://x@127.0.0.1:1#' + e('套餐到期: 2026-12-31'));
  L.push('socks5://u:p@203.0.113.130:1080?tls=1#' + e('SOCKS5 over TLS'));
  if (variant === 'refresh') { L.splice(2, 1); L.push('hysteria2://hy2-pass-new@203.0.113.140:8443?sni=example.com#' + e('Hysteria2 新节点')); }
  return L;
}
function clashYaml() {
  return ['port: 7890', 'proxies:', '  - {name: "YAML 香港 01", type: trojan, server: 203.0.113.150, port: 443, password: yaml-pass-1, sni: example.com}',
    '  - name: "YAML 日本 02"', '    type: hysteria2', '    server: 203.0.113.151', '    port: 8443', '    password: yaml-pass-2', '    sni: example.com', '    skip-cert-verify: true',
    '  - name: "YAML 美国 03"', '    type: ss', '    server: 203.0.113.152', '    port: 8388', '    cipher: aes-256-gcm', '    password: yaml-pass-3', 'proxy-groups:', '  - name: x', '    type: select', '    proxies: [a]'].join('\n');
}
function singboxJson() {
  const ob = []; for (let i = 0; i < 5; i++) ob.push({ type: 'http', tag: 'SB HTTPS 0' + (i + 1), server: '203.0.113.' + (170 + i), server_port: 8443, username: 'u' + i, password: 'p' + i, tls: { enabled: true, server_name: 'example.com' } });
  ob.push({ type: 'tuic', tag: 'SB TUIC 01', server: '203.0.113.180', server_port: 443, uuid: '11111111-2222-3333-4444-555555555577', password: 'tp', tls: { enabled: true, server_name: 'example.com' } });
  return JSON.stringify({ outbounds: ob.concat([{ type: 'selector', tag: 'x', outbounds: ['a'] }, { type: 'direct', tag: 'direct' }]) });
}
function subBody(url, ua, name) {
  const b64 = (t) => Buffer.from(t, 'utf8').toString('base64'), html = '<html><body>请使用客户端打开</body></html>';
  if (name) return b64(subLinks('refresh').join('\n'));
  if (/\/empty/.test(url)) return b64('# no nodes\n');
  if (/\/stubborn2/.test(url)) return ua === 'v2ray' ? b64(subLinks().slice(0, 6).join('\n')) : html;
  if (/\/stubborn/.test(url)) return ua === 'clash' ? clashYaml() : html;
  if (/\/singbox/.test(url) && ua === 'auto') return singboxJson();
  return b64(subLinks().join('\n'));
}

/* ===================== 4. 状态 (reset 会重建全部; 令牌保持不变) ===================== */
const M = {};
const pbk = (pw, salt) => crypto.pbkdf2Sync(pw, salt, 2000, 32, 'sha256').toString('hex');          // 离线校验用的「加盐 PBKDF2」(迭代次数调低, 只为演示)
/* 本机缓存的「上一次登录的账号」: 只有邮箱 + 加盐校验值, 没有明文密码 */
function cacheRec(email, pw) { const salt = randHex(8); return { email, salt, hash: pbk(pw, salt) }; }
function reset(mode) {
  const first = mode === 'first-run', t = sec(), secret = M.secret || randHex(16), account = M.account || null, keepAcc = account && !ACCOUNTS[account] && M.dir && M.dir[account] ? M.dir[account] : null;
  Object.keys(M).forEach((k) => { delete M[k]; });
  Object.assign(M, { secret, firstRun: first, os: 'darwin', helperDown: false, helperWin: null, clashDown: false, clashWins: [], central: 'up', failNext: [], failJob: false, jobs: {}, jobSeq: 0,
    mode: 'Rule', connTarget: 45, conns: [], delayHist: {}, fails: [], regs: [], lockUntil: 0, locksec: 300, langSet: null, logHours: 72, logOps: true, accessLog: true, logCore: true, autoSites: false, autoSimAt: 0, autoSimIdx: 0, dismissed: [], net: 'normal', netChecked: t - 60, stats: 'normal',
    upd: { cur: BASE_APP, coreCur: BASE_CORE, on: true, fail: false, checked: t - 2 * 3600 }, speed: { running: null, last: null, seq: 0, byId: {} }, custom: [], pendingNames: {}, pendingApps: [], apps: [], appsScanned: 0,
    prefs: { obj: {}, version: 0, updated: 0 }, sudo: Object.create(null), sudoTtl: 300, plan: 'soon', siteMods: {}, tgt: { custom: [], over: {}, hidden: {} }, hosts: [], subUrls: Object.create(null), inspected: Object.create(null), icons: 'progressive', vpsOpen: false });
  M.dir = clone(ACCOUNTS);                                                // 模拟的 enana.cc 账号库 (注册会往里加); 重置会让种子账号的密码回到 demo1234 / other1234
  if (keepAcc) M.dir[account] = keepAcc;                                  // 但不会让已登录的 (注册来的) 账号消失
  M.lastAcct = flag('unbound') ? null : cacheRec('demo@example.com', ACCOUNTS['demo@example.com'].pw); M.account = account; M.proxyOn = false; M.proxyMode = 'auto';   // 令牌与「当前账号」不随重置变化
  M.servers = first ? [] : seedServers(); M.applied = clone(M.servers);
  M.subs = first ? [] : [{ name: 'demo-sub', host: 'sub.example.com', updated: t - 5 * 3600, count: 20, interval: 12, usage: { used: 32.5e9, total: 200e9, expire: t + 45 * 86400 } }];
  if (!first && flag('stale-sub')) M.subs[0].updated = t - 30 * 3600;
  if (!first) M.subUrls['demo-sub'] = 'https://sub.example.com/sub/demo?token=example-token-0001';          // 订阅链接 (带占位令牌): 只有 GET /api/sub/url (需 sudo) 会返回它
  M.overrides = first ? [] : [{ kind: 'site', value: 'example.org', state: 'direct', target: '', src: 'user', at: 0 }, { kind: 'site', value: 'intranet.example.com', state: 'pin', target: '', src: 'user', at: 0 },
    { kind: 'site', value: 'blocked.example.net', state: 'auto', target: '', src: 'auto', at: t - 1500, why: 'timeout', fails: 4, app: 'Google Chrome' }];
  M.pin = first ? '' : SEED_PIN[0]; M.global = 'AUTO'; M.final = 'Global';
  M.svc = {}; CAT.entries.forEach((e) => { M.svc[e.id] = POL[e.default] || 'direct'; });
  if (!first) { M.svc.chatgpt = 'Global'; M.svc.spotify = 'Global'; }      // 让「⚠ 不是固定出口」提示出现
  if (!first) scanApps(true);
  M.env = { core: true, service: true, sysproxy: !first, shortcut: !first };
  M.rulesUpdated = first ? 0 : t - 2 * 86400;
  M.rs = RULESETS.map((r) => { const present = (r.essential || r.def) && !(first && (r.tag === 'geosite-cn' || r.tag === 'geosite-ai')); return { tag: r.tag, enabled: r.essential || r.def, present, bytes: present ? ruleSize(r.tag) : 0, updated: present ? (M.rulesUpdated || t - 3 * 86400) - hash(r.tag) % 3600 : 0 }; });
  M.dns = { cn: 'alidns', cn_custom: '', global: 'cloudflare', global_custom: '', via: 'Global', strategy: 'prefer_ipv4', leak_guard: true, ads_block: false };
  M.vps = []; M.sync = syncInit(first); M.autoUpdate = true;
  M.devices = seedDevices(); M.notice = null; if (account) setThisOnline(account, true);                // 重置不会把已登录的浏览器踢下线
  M.L = genLogs();
}
function scanApps(initial) {                                              // initial: 启动 / 重置时的第一次扫描 (图标 0-6 秒后陆续出现); 之后新扫到的应用要 2-6 秒后才有图标 (按 --fast 缩短)
  const have = {}, pend = M.pendingApps.slice(), t = now(); M.apps.forEach((a) => { have[a.name] = 1; }); M.pendingApps = []; let added = 0;
  INSTALLED.concat(pend).forEach((name) => {
    if (have[name]) return; have[name] = 1;
    const r = recOf(name), isNew = NEW_APPS.indexOf(name) >= 0 || pend.indexOf(name) >= 0, rr = mulberry(hash('appicon|' + name));
    M.apps.push({ name, state: isNew ? 'direct' : (r ? r.rec : 'follow'), flag: isNew ? 'new' : 'ack', known: !!r, rec: r ? r.rec : '', group: r ? r.group : '其他', custom: false, kind: 'app', _iconAt: t + D(initial ? rr() * 6000 : 2000 + rr() * 4000) });
    if (isNew) added++;
  });
  M.appsScanned = sec(); return added;
}
/* 应用图标: 图片由 /ui/appicons/<名称>.png 提供 (运行时生成的 64x64 PNG); 扫描后陆续出现 (M.icons=progressive), 少数应用永远没有 (NO_ICON), 一个应用宣称有图标但图片 404 (BROKEN_ICON) */
/* 文件名 = 和 lib/apps.sh 的 app_icon_slug 一样: 名称里不是 A-Za-z0-9._- 的字节换成 _ (最多 40 个), 加上 "-" 和 cksum(名称) (POSIX cksum 的第一列), 例如 appicons/Slack-2316498247.png */
const CK_T = (() => { const t = []; for (let i = 0; i < 256; i++) { let c = i << 24; for (let k = 0; k < 8; k++) c = ((c & 0x80000000) ? ((c << 1) ^ 0x04C11DB7) : (c << 1)) >>> 0; t.push(c >>> 0); } return t; })();
function cksum(buf) {
  let c = 0; for (let i = 0; i < buf.length; i++) c = ((c << 8) ^ CK_T[((c >>> 24) ^ buf[i]) & 255]) >>> 0;
  for (let n = buf.length; n > 0; n = Math.floor(n / 256)) c = ((c << 8) ^ CK_T[((c >>> 24) ^ (n & 255)) & 255]) >>> 0;
  return (~c) >>> 0;
}
function iconSlug(name) {
  const b = Buffer.from(String(name), 'utf8'); let s = '';
  for (let i = 0; i < b.length; i++) { const ch = b[i]; s += (ch >= 48 && ch <= 57) || (ch >= 65 && ch <= 90) || (ch >= 97 && ch <= 122) || ch === 46 || ch === 95 || ch === 45 ? String.fromCharCode(ch) : '_'; }
  return s.slice(0, 40) + '-' + cksum(b);
}
const iconUrl = (name) => 'appicons/' + iconSlug(name) + '.png';
const appIconOk = (a) => !!a && !a._noIcon && M.icons !== 'none' && NO_ICON.indexOf(a.name) < 0 && (M.icons === 'all' || now() >= a._iconAt);
function iconNameFor(slug) {                                               // 这个图片文件属于哪个应用 (没提取出来 / 取不到 / 宣称有但 404 的应用返回 '')
  if (M.icons === 'none') return '';
  const a = M.apps.filter((x) => iconSlug(x.name) === slug)[0], name = a ? a.name : (M.inspected[slug] || '');
  if (!name || BROKEN_ICON.indexOf(name) >= 0 || NO_ICON.indexOf(name) >= 0) return '';
  return a && !M.inspected[slug] && !appIconOk(a) ? '' : name;               // 应用列表里的应用要到时间才有; 检查过 (inspect) 的候选是即时提取的
}
const appsPayload = () => ({ ok: true, apps: M.apps.map((a) => ({ name: a.name, state: a.state, flag: a.flag, target: a.target || '', target_ok: targetOk(a.target || ''), known: a.known, rec: a.rec, group: a.group, custom: !!a.custom, kind: a.kind || 'app', path: a.custom ? a.path : appPath(a.name), icon: appIconOk(a) ? iconUrl(a.name) : '' })),
  new_count: M.apps.filter((a) => a.flag === 'new').length, scanned_at: M.appsScanned });
const nodesOf = (list) => list.filter((s) => s.role === 'pin' || s.role === 'auto');          // 只有 pin / auto 会写进核心配置
const applyNow = () => { M.applied = clone(M.servers); };
const snapshot = () => { const s = clone(M.servers), b = clone(M.subs); return () => { M.servers = s; M.subs = b; }; };
const curLang = () => M.langSet || 'zh';

/* ---- 设备 (每个账号、每个平台最多 2 台同时在线; 「这台电脑」登录后算 1 台) ---- */
const DEVICE_LIMIT = 2;
function seedDevices() {                                                  // 默认 = devices=free: 只有一台 macOS 在线, 正常登录不会被拦
  const t = sec();
  return { 'demo@example.com': [
    { uid: 'd-mbp', name: '我的 MacBook Pro', name_en: "My MacBook Pro", platform: 'macos', os: '14.5', app: '2.1.0', last_seen: t - 90, online: true, ip_hint: '203.0.*.*' },
    { uid: 'd-air', name: 'MacBook Air', name_en: 'MacBook Air', platform: 'macos', os: '15.0', app: '2.0.0', last_seen: t - 5 * 3600, online: false, ip_hint: '198.51.*.*' },
    { uid: 'd-win', name: 'Office PC', name_en: 'Office PC', platform: 'windows', os: '11', app: '2.1.0', last_seen: t - 3 * 86400, online: false, ip_hint: '192.0.*.*' }],
  'other@example.com': [{ uid: 'o-imac', name: 'iMac', name_en: 'iMac', platform: 'macos', os: '14.2', app: '2.1.0', last_seen: t - 600, online: true, ip_hint: '203.0.*.*' }] };
}
const platformOf = () => (M.os === 'windows' ? 'windows' : 'macos'), devicesOf = (email) => (M.devices[email] = M.devices[email] || []);
const devName = (d, lang) => (lang === 'en' && d.name_en ? d.name_en : d.name);
const devView = (d, lang) => ({ uid: d.uid, name: devName(d, lang), platform: d.platform, os: d.os, last_seen: d.last_seen, online: d.online, ip_hint: d.ip_hint });
/* 这台电脑登录到 email (或退出: email = null): 先从所有账号的名单里拿掉, 再加到新账号的名单里 */
function setThisOnline(email, on) {
  Object.keys(M.devices).forEach((e) => { M.devices[e] = M.devices[e].filter((d) => d.uid !== 'this-mock'); });
  if (on && email) devicesOf(email).push({ uid: 'this-mock', name: '', platform: platformOf(), os: M.os === 'windows' ? '11' : '15.1', app: M.upd.cur, last_seen: sec(), online: true, ip_hint: '192.0.*.*' });
}
const noticeText = (lang) => (!M.notice ? '' : M.notice.key ? tr(lang, M.notice.key) : M.notice.text);

/* ===================== 5. 日志 (近 14 天的确定性数据: 操作记录 / 网站访问 / 代理日志) ===================== */
/* [应用, 域名, 走向, 权重]: 走向 pin|auto|direct|other */
const TRAFFIC = [['Claude', 'api.claude.example.com', 'pin', 6], ['Claude', 'claude.example.com', 'pin', 3], ['Claude', 'statsig.claude.example.net', 'pin', 1], ['ChatGPT', 'chat.example.com', 'pin', 5], ['ChatGPT', 'cdn.chat.example.net', 'pin', 2],
  ['Cursor', 'api.cursor.example.com', 'pin', 3], ['Telegram', 'web.telegram.example.org', 'pin', 2], ['Telegram', 'api.telegram.example.org', 'pin', 2], ['Spotify', 'api.music.example.com', 'pin', 2],
  ['Google Chrome', 'exchange.example.com', 'pin', 1], ['Google Chrome', 'video.example.net', 'auto', 5], ['Google Chrome', 'i.video.example.net', 'auto', 4], ['Google Chrome', 'www.search.example.com', 'auto', 4],
  ['Safari', 'maps.example.org', 'auto', 2], ['Safari', 'static.example.net', 'auto', 3], ['Visual Studio Code', 'repo.example.com', 'auto', 4], ['Visual Studio Code', 'api.repo.example.com', 'auto', 3],
  ['Docker Desktop', 'registry.example.com', 'auto', 2], ['Docker Desktop', 'blobs.registry.example.net', 'auto', 3], ['Discord', 'gateway.chat.example.org', 'auto', 2], ['Slack', 'app.slack.example.com', 'auto', 2],
  ['Firefox', 'news.example.org', 'auto', 2], ['Arc', 'docs.example.org', 'auto', 2], ['WeChat', 'res.wx.example.net', 'direct', 5], ['NeteaseMusic', 'music.cn.example.net', 'direct', 3], ['WPS Office', 'office.cn.example.com', 'direct', 2],
  ['QQ', 'im.qq.example.net', 'direct', 2], ['Steam', 'store.steam.example.org', 'direct', 2], ['Google Chrome', 'www.cn-site.example.com', 'direct', 4], ['Google Chrome', 'cdn.cn-site.example.net', 'direct', 3],
  ['Safari', 'www.example.org', 'direct', 3], ['Safari', 'intranet.example.com', 'direct', 1], ['', 'time.example.org', 'direct', 2], ['', 'update.example.net', 'direct', 2], ['', 'ocsp.example.com', 'direct', 2],
  ['Docker Desktop', 'dl.mirror.example.net', 'other', 1]];
const TRAFFIC_W = []; TRAFFIC.forEach((t) => { for (let i = 0; i < t[3]; i++) TRAFFIC_W.push(t); });
const APP_DIRECT = { WeChat: 1, NeteaseMusic: 1, 'WPS Office': 1, QQ: 1, Steam: 1 };
function directReason(t) {                                               // 直连的原因 (和真实后端的出口名 direct-xxx 一一对应)
  if (t[1] === 'intranet.example.com') return 'lan';
  if (APP_DIRECT[t[0]]) return 'app';
  if (/(^|\.)example\.org$/.test(t[1]) && t[1] === 'www.example.org') return 'site';
  if (/cn-site|\.cn\.example|^res\.wx|^music\.cn|^office\.cn|^im\.qq|steam/.test(t[1]) || t[1] === 'blocked.example.net') return 'cn';
  return 'policy';
}
const procOf = (app) => (app ? '/Applications/' + app + '.app/Contents/MacOS/' + app : '/usr/libexec/trustd');
function accessRow(r, ms) {
  const t = pick(r, TRAFFIC_W); let node = 'direct', reason = '';
  if (t[2] === 'pin') node = r() < 0.75 ? SEED_PIN[0] : SEED_PIN[1]; else if (t[2] === 'auto') node = pick(r, SEED_AUTO); else if (t[2] === 'other') node = pick(r, SEED_DL);
  else if (t[2] === 'direct') { reason = directReason(t); node = reason === 'policy' ? 'direct' : 'direct-' + reason; }
  const row = { ts: tsOf(ms), id: String(Math.floor(r() * 4e9)), net: 'tcp', host: t[1], port: r() < 0.82 ? 443 : pick(r, [80, 8443, 993, 5222]), app: t[0], user: 'user', path: procOf(t[0]), route: t[2] === 'other' ? 'auto' : t[2], node, reason, err: '', errmsg: '', dur: '', ips: '' };
  const fail = t[2] === 'direct' ? (reason === 'cn' || reason === 'policy') && (r() < 0.05 || t[1] === 'blocked.example.net') : r() < 0.015;
  if (fail) { row.err = t[2] === 'direct' ? 'timeout' : 'reset'; row.dur = t[2] === 'direct' ? '5.0s' : '120ms'; row.errmsg = t[2] === 'direct' ? 'dial tcp 31.13.92.37:443: i/o timeout' : 'read tcp 127.0.0.1: connection reset by peer'; if (t[2] === 'direct') row.ips = '31.13.92.37 104.244.42.197'; }
  return row;
}
function proxyRow(r, ms, minLevel) {
  const roll = r(); let level = roll < 0.015 ? 'ERROR' : roll < 0.075 ? 'WARN' : 'INFO';
  if (minLevel === 'WARN' && level === 'INFO') level = r() < 0.7 ? 'WARN' : 'ERROR';
  const tag = pick(r, SEED_AUTO.concat(SEED_PIN)), ty = typeOfTag(tag), t = pick(r, TRAFFIC_W), sp = 50000 + Math.floor(r() * 9000); let msg;
  if (level === 'ERROR') msg = pick(r, ['outbound/' + ty + '[' + tag + ']: connection reset by peer', 'dns: exchange failed: i/o timeout', 'inbound/mixed[in]: process connection from 127.0.0.1:' + sp + ': broken pipe']);
  else if (level === 'WARN') msg = pick(r, ['dns: lookup ' + t[1] + ' timeout, retry', 'outbound/' + ty + '[' + tag + ']: handshake took ' + (800 + Math.floor(r() * 900)) + 'ms', 'router: rule-set geosite-cn reload took ' + (200 + Math.floor(r() * 400)) + 'ms']);
  else msg = pick(r, ['inbound/mixed[in]: inbound connection from 127.0.0.1:' + sp, 'outbound/' + ty + '[' + tag + ']: outbound connection to ' + t[1] + ':443', 'router: match[' + Math.floor(r() * 9) + '] rule_set=svc-claude => PIN', 'urltest: AUTO -> ' + tag + ' (' + (30 + Math.floor(r() * 250)) + 'ms)']);
  return { ts: tsOf(ms), level, msg };
}
const OV_SITES = ['example.com', 'news.example.net', 'intranet.example.com', 'video.example.org', 'shop.example.com', 'git.example.net', 'mail.example.org', 'docs.example.org'];
const OV_APPS = ['Claude', 'Cursor', 'Telegram', 'Spotify', 'Obsidian', 'Raycast', 'Perplexity', 'Discord', 'Steam'];
const POLS = ['pin', 'auto', 'direct'], ALL_NODES = SEED_AUTO.concat(SEED_PIN);
/* [权重, 生成器 -> [动作, 详情, 结果]] —— 动作码固定, 详情与语言无关 (logfmt) */
const OPS_MENU = [
  [20, (r) => ['override.set', kv({ kind: 'site', value: pick(r, OV_SITES), state: pick(r, POLS) })]], [7, (r) => ['override.set', kv({ kind: 'app', value: pick(r, OV_APPS), state: pick(r, ['follow', 'direct', 'pin', 'auto']) })]],
  [7, (r) => ['override.delete', kv({ kind: 'site', value: pick(r, OV_SITES) })]], [6, (r) => ['servers.role', kv({ tag: pick(r, ALL_NODES), role: pick(r, ['pin', 'auto', 'off']) })]],
  [3, (r) => ['servers.import', kv({ sub: pick(r, ['', 'demo-sub']), count: 1 + Math.floor(r() * 12), mode: 'merge' })]], [3, (r) => ['servers.delete', kv({ tag: pick(r, ALL_NODES) })]],
  [6, (r) => (r() < 0.12 ? ['sub.refresh', kv({ sub: 'demo-sub', code: 'E_NETWORK' }), 'error'] : ['sub.refresh', kv({ sub: 'demo-sub', count: 20 })])],
  [1, () => ['sub.save', kv({ name: 'demo-sub', host: 'sub.example.com' })]], [5, (r) => ['apps.scan', kv({ new: Math.floor(r() * 4) })]], [2, (r) => ['apps.adopt', kv({ count: 1 + Math.floor(r() * 3) })]],
  [3, (r) => (r() < 0.4 ? ['apps.ack', kv({ all: 1 })] : ['apps.ack', kv({ name: pick(r, OV_APPS) })])],
  [5, (r) => (r() < 0.06 ? ['rules.update', kv({ changed: 0, failed: 3 }), 'error'] : ['rules.update', kv({ changed: Math.floor(r() * 9), failed: 0 })])],
  [4, (r) => ['rules.toggle', kv({ tag: pick(r, ['geosite-netflix', 'geosite-disney', 'geosite-ads', 'geosite-twitter', 'geosite-tiktok']), on: pick(r, [0, 1]) })]],
  [1, (r) => ['rules.custom.add', kv({ name: 'my-list', policy: pick(r, POLS) })]], [1, () => ['rules.custom.delete', kv({ tag: 'my-list' })]],
  [3, (r) => ['dns.set', kv({ cn: pick(r, ['alidns', 'dnspod', '114']), global: pick(r, ['cloudflare', 'google', 'quad9']), via: pick(r, ['Global', 'PIN']), leak_guard: 1, ads_block: pick(r, [0, 1]) })]],
  [4, (r) => ['dns.test', kv({ name: pick(r, ['example.com', 'www.example.org', 'api.claude.example.com']), ms: 8 + Math.floor(r() * 60) })]],
  [4, (r) => ['settings.set', pick(r, [kv({ setting: 'log_hours', from: 72, to: pick(r, [24, 72, 168]) }), kv({ lang: pick(r, ['zh', 'en']) }), kv({ access_log: 1 })])]], [5, () => ['net.refresh', '']],
  [2, () => ['proxy.off', '']], [2, () => ['proxy.on', '']],
  [2, (r) => (r() < 0.25 ? ['vps.probe', kv({ host: '203.0.113.60', port: 22, mode: 'password', code: 'E_SSH_UNREACHABLE' }), 'error'] : ['vps.probe', kv({ host: '203.0.113.' + pick(r, [10, 20, 30]), port: 22, mode: pick(r, ['password', 'key']) })])],
  [1, (r) => ['vps.provision', kv({ host: '203.0.113.10', name: 'my-vps', role: pick(r, ['pin', 'auto']), nodes: 1 })]], [1, () => ['vps.redetect', kv({ id: 'vps_1a2b3c4d', host: '203.0.113.31' })]], [1, () => ['vps.forget', kv({ id: 'vps_1a2b3c4d', host: '203.0.113.31' })]],
  [1, () => ['devices.kick', kv({ uid: 'd-win', name: 'Office PC' })]],
  [2, (r) => ['sync.settings', kv({ enabled: 1, auto: pick(r, [0, 1]) })]], [2, (r) => ['sync.push', kv({ version: 3 + Math.floor(r() * 4), force: 0 })]], [2, (r) => ['sync.pull', kv({ mode: pick(r, ['merge', 'replace']), version: 4 + Math.floor(r() * 4) })]], [1, () => ['sync.clear', '']],
  [4, (r) => ['speedtest.start', kv({ mode: 'both', nodes: 4, speed: pick(r, [0, 1, 1]) })]], [2, () => ['restart', '']], [1, (r) => ['logs.clear', kv({ type: pick(r, ['access', 'proxy']), before: dayOf(addDays(now(), -20)) })]],
  [2, (r) => (r() < 0.2 ? ['auth.verify', kv({ code: 'E_BAD_CREDENTIALS' }), 'error'] : ['auth.verify', ''])], [2, (r) => ['secret.view', r() < 0.7 ? kv({ kind: 'server', tag: pick(r, ALL_NODES) }) : kv({ kind: 'sub', name: 'demo-sub' })]],
  [1, () => ['backup.export', kv({ servers: 24, subs: 1 })]], [1, (r) => (r() < 0.25 ? ['password.change', kv({ code: 'E_BAD_CREDENTIALS' }), 'error'] : ['password.change', ''])],
  [3, (r) => ['sites.domain', kv({ id: pick(r, ['claude', 'telegram', 'github', 'google', 'netflix']), action: pick(r, ['add', 'remove', 'update', 'restore']), domain: pick(r, ['docs.example.com', 'my-site.example.org', 'cdn.example.net']) })]],
  [1, (r) => ['sites.reset', kv({ id: pick(r, ['claude', 'telegram', 'github']) })]], [1, (r) => ['apps.custom.add', kv({ name: pick(r, ['Cursor', 'mytool', 'Bear']), kind: pick(r, ['app', 'bin']), state: pick(r, ['follow', 'pin', 'auto', 'direct']) })]],
  [1, (r) => ['apps.custom.delete', kv({ name: pick(r, ['Cursor', 'mytool', 'Bear']) })]], [2, (r) => ['speed.target', kv({ action: pick(r, ['add', 'edit', 'delete', 'restore']), id: pick(r, ['u-3fa9c1', 'u-b07e55', 'npm', 'bing', 'pypi']) })]],
  [3, (r) => ['policy.switch', kv({ kind: 'selector', tag: 'svc-' + pick(r, ['claude', 'chatgpt', 'github']), site: pick(r, ['Claude', 'ChatGPT', 'GitHub']), from: pick(r, ['PIN', 'Global']), to: pick(r, ['Global', 'PIN', 'direct', SEED_PIN[0]]) })]],
  [1, (r) => ['conns.kill', kv({ scope: pick(r, ['all', 'host', 'one']), count: 1 + Math.floor(r() * 9) })]], [1, () => ['logs.bundle', kv({ hours: 24, sections: 'ops,access,proxy,snapshot', bytes: 48210 })]],
  [1, () => ['autosite.add', kv({ domain: 'video-cdn.example.net', state: 'auto', fails: 4, attempts: 4, err: 'timeout', app: 'Google Chrome', was: 'direct-cn', verify: 'http=200 310ms' })]],
  [1, () => ['apps.found', kv({ count: 2, names: 'Zed,Arc', default: 'follow×1,direct×1' })]],
  [1, () => ['speed.targets.reset', '']], [2, (r) => ['dns.hosts', kv({ action: pick(r, ['add', 'update', 'remove']), domain: pick(r, ['nas.example.com', 'router.example.net', 'dev.example.org']) })]],
  [1, (r) => ['dns.hosts.reset', kv({ count: 1 + Math.floor(r() * 5) })]], [2, () => ['dns.bench', '']]];
const OPS_W = []; OPS_MENU.forEach((m, i) => { for (let k = 0; k < m[0]; k++) OPS_W.push(i); });
const OPS_SPECIAL = { 13: [['terminal', 'install', kv({ version: '2.0.0' })]], 12: [['terminal', 'uninstall', kv({ keep_data: 1 })], ['terminal', 'install', kv({ version: '2.0.0' })]], 7: [['terminal', 'upgrade', kv({ version: '2.1.0' })]],
  6: [['dashboard', 'update.apply', kv({ what: 'core', version: '1.14.2' })]], 5: [['terminal', 'stop', ''], ['terminal', 'start', '']] };
const times = (r, n, lo, hi) => { const a = []; for (let i = 0; i < n; i++) a.push(Math.floor((lo + r() * (hi - lo)) / 1000) * 1000); return a.sort((x, y) => x - y); };
function genOps(r, back, lo, hi) {
  const today = back === 0; let n = 5 + Math.floor(r() * 36); if (today) n = Math.max(5, Math.round(n * 0.5));
  const seq = [], sp = OPS_SPECIAL[back] || [], wantStop = !today && r() < 0.2;
  if (!today && r() < 0.2) seq.push(['terminal', 'start', '']);
  sp.forEach((x) => seq.push(x));
  while (seq.length < n) {
    if (r() < 0.12) seq.push(['dashboard', 'login.fail', kv({ code: 'E_BAD_CREDENTIALS' }), 'error']);
    seq.push(['dashboard', 'login', r() < 0.06 ? kv({ via: 'online', kick: 'd-air' }) : kv({ via: r() < 0.9 ? 'online' : 'offline' })]);
    let px = r() < 0.85; if (px) seq.push(['dashboard', 'proxy.on', '']);                 // 登录后代理默认是关的, 多数人会马上打开
    const k = 2 + Math.floor(r() * 9);
    for (let i = 0; i < k; i++) {
      const g = OPS_MENU[pick(r, OPS_W)][1](r);
      if (g[0].indexOf('proxy.') === 0) { g[0] = px ? 'proxy.off' : 'proxy.on'; px = !px; }                // 开关交替出现
      seq.push(['dashboard', g[0], g[1], g[2] || 'ok']);
      if (g[0] === 'speedtest.start' && r() < 0.3) seq.push(['dashboard', 'speedtest.stop', kv({ id: 'st-' + Math.floor(lo / 1000) + '-' + (100 + Math.floor(r() * 900)) }), 'ok']);
    }
    if (r() < 0.7) seq.push(['dashboard', 'logout', '']);
  }
  seq.length = Math.max(Math.min(seq.length, n - (wantStop ? 1 : 0)), sp.length);
  if (wantStop) seq.push(['terminal', 'stop', '']);
  const ts = times(r, seq.length, lo, hi);
  return seq.map((x, i) => ({ ts: tsOf(ts[i]), who: x[0], action: x[1], detail: x[2], result: x[3] || 'ok' }));
}
function genLogs() {
  const L = { ops: {}, access: {}, proxy: {}, ver: 0 }, t = now(), t0 = startOfDay(t);
  for (let back = 13; back >= 0; back--) {
    const dayMs = addDays(t0, -back), day = dayOf(dayMs), r = mulberry(hash('enana-log|' + day)), today = back === 0;
    const lo = today ? dayMs + 60e3 : dayMs + 8 * 3600e3, hi = today ? Math.max(lo + 60e3, t - 5e3) : dayMs + 23.5 * 3600e3;
    L.ops[day] = genOps(r, back, lo, hi);
    L.access[day] = times(r, 200 + Math.floor(r() * 1301), lo, hi).map((ms) => accessRow(r, ms));
    L.proxy[day] = times(r, 120 + Math.floor(r() * 380), lo, hi).map((ms) => proxyRow(r, ms, ''));
  }
  return L;
}
/* 会改动「同步内容」的操作码: 记录后本机的 sync.local.dirty = true */
const DIRTY = { 'servers.import': 1, 'servers.delete': 1, 'servers.role': 1, 'sub.save': 1, 'sub.delete': 1, 'sub.refresh': 1, 'override.set': 1, 'override.delete': 1, 'apps.adopt': 1, 'apps.ack': 1, 'dns.set': 1, 'rules.toggle': 1,
  'rules.custom.add': 1, 'rules.custom.delete': 1, 'settings.set': 1, 'vps.provision': 1, 'vps.forget': 1, 'vps.redetect': 1, 'sites.domain': 1, 'sites.reset': 1, 'apps.custom.add': 1, 'apps.custom.delete': 1, 'dns.hosts': 1, 'dns.hosts.reset': 1 };
function oplog(who, action, detail, result) {
  if (!M.logOps) return;
  oplogForce(who, action, detail, result);
}
function oplogForce(who, action, detail, result) {
  const d = dayOf(now()); (M.L.ops[d] = M.L.ops[d] || []).push({ ts: tsOf(now()), who, action, detail: detail || '', result: result || 'ok' }); M.L.ver++;
  if (DIRTY[action] && result !== 'error' && M.sync) M.sync.local.dirty = true;
}
/* 实时日志: 开着「记录网站访问」时每次产生 1 条访问 + 1 条代理日志; 关掉后只有偶尔的警告 / 错误 */
const AUTO_CAND = ['video-cdn.example.net', 'api.newsite.example.org', 'static.blocked.example.com'];
function autoSim() {                                                     // 演示: 打开「自动识别」后, 每隔一会儿 (按 --fast 缩短) 自动加进一个打不开的网站
  if (!M.autoSites || !M.proxyOn || !M.servers.length || M.autoSimIdx >= AUTO_CAND.length || now() - M.autoSimAt < D(25000)) return;
  const dom = AUTO_CAND[M.autoSimIdx++]; M.autoSimAt = now();
  if (M.overrides.some((o) => o.kind === 'site' && o.value === dom) || M.dismissed.indexOf(dom) >= 0) return;
  M.overrides.push({ kind: 'site', value: dom, state: M.servers.some((x) => x.role === 'auto') ? 'auto' : 'pin', target: '', src: 'auto', at: sec(), why: 'timeout', fails: 3 + (M.autoSimIdx % 3), app: 'Google Chrome' });
  oplog('auto', 'autosite.add', kv({ domain: dom, state: 'auto', fails: 4, attempts: 4, err: 'timeout', app: 'Google Chrome', was: 'direct-cn', verify: 'http=200 ' + (180 + M.autoSimIdx * 40) + 'ms' }));
}
function liveTick(n) {
  autoSim();
  const d = dayOf(now()), L = M.L, r = Math.random;
  if (n === 1 && (L.access[d] || []).length > 4000) return;                // 后台自动产生的实时行有上限
  for (let i = 0; i < n; i++) {
    if (M.accessLog) { (L.access[d] = L.access[d] || []).push(accessRow(r, now())); (L.proxy[d] = L.proxy[d] || []).push(proxyRow(r, now(), '')); }
    else if (r() < 0.3) (L.proxy[d] = L.proxy[d] || []).push(proxyRow(r, now(), 'WARN'));
  }
  L.ver++;
}
const cutTs = () => tsOf(now() - M.logHours * 3600e3);                                    // 保留期的起点 (本机时间 YYYY-MM-DD HH:MM:SS); 精确到小时
const inRetention = (day) => day >= cutTs().slice(0, 10);
const keepRow = (r) => r.ts >= cutTs();
function logDays() {
  const set = {};
  ['ops', 'access', 'proxy'].forEach((t) => Object.keys(M.L[t]).forEach((d) => { if (inRetention(d) && M.L[t][d].some(keepRow)) set[d] = 1; }));
  return Object.keys(set).sort().reverse();
}
const rowText = { ops: (r) => [r.ts, r.who, r.action, r.detail, r.result].join(' '), access: (r) => [r.ts, r.host, r.port, r.app, r.route, r.node, r.reason, r.err, r.ips].join(' '), proxy: (r) => [r.ts, r.level, r.msg].join(' ') };
function logQuery(type, day, q, limit, offset, f) {
  const rows = inRetention(day) ? (M.L[type][day] || []).filter(keepRow) : [], nd = q.toLowerCase(), base = nd ? rows.filter((r) => rowText[type](r).toLowerCase().indexOf(nd) >= 0) : rows, out = [];
  let hit = base, summary;
  if (type === 'access') {
    const reasons = {}, fails = {}; let direct = 0, proxy = 0, pinN = 0, autoN = 0, error = 0;
    base.forEach((r) => { if (r.route === 'direct') { direct++; if (r.reason) reasons[r.reason] = (reasons[r.reason] || 0) + 1; } else proxy++; if (r.route === 'pin') pinN++; if (r.route === 'auto') autoN++; if (r.err) { error++; const k = r.host; fails[k] = fails[k] || { host: k, n: 0, err: r.err, app: r.app, node: r.node }; fails[k].n++; } });
    summary = { all: base.length, direct, proxy, pin: pinN, auto: autoN, error, reasons, top_fail: Object.keys(fails).map((k) => fails[k]).sort((a, b) => b.n - a.n).slice(0, 5) };
    if (f === 'direct') hit = base.filter((r) => r.route === 'direct'); else if (f === 'proxy') hit = base.filter((r) => r.route !== 'direct'); else if (f === 'error') hit = base.filter((r) => r.err);
  } else if (type === 'ops') {
    summary = { all: base.length, error: base.filter((r) => r.result === 'error').length };
    if (f === 'error') hit = base.filter((r) => r.result === 'error'); else if (f === 'dashboard' || f === 'terminal' || f === 'auto') hit = base.filter((r) => r.who === f);
  } else {
    const e = base.filter((r) => r.level === 'ERROR').length, w = base.filter((r) => r.level === 'WARN').length; summary = { all: base.length, warn: w, error: e };
    if (f === 'error') hit = base.filter((r) => r.level === 'ERROR'); else if (f === 'warn') hit = base.filter((r) => r.level === 'ERROR' || r.level === 'WARN');
  }
  for (let i = hit.length - 1 - offset; i >= 0 && out.length < limit; i--) out.push(hit[i]);
  return { total: hit.length, rows: out, summary };
}
const lineBytes = { ops: (r) => r.ts.length + r.who.length + r.action.length + r.detail.length + r.result.length + 5, proxy: (r) => r.ts.length + r.level.length + r.msg.length + 8, access: (r) => 360 + r.host.length + r.node.length + r.app.length };
/* 访问记录是从代理日志里归并出来的 (真实后端同样如此): access 与 proxy 的占用相同, 清除其中任何一个都会同时清掉两者 */
function logUsage() {
  let o = 0, p = 0;
  Object.keys(M.L.ops).forEach((d) => { if (inRetention(d)) M.L.ops[d].filter(keepRow).forEach((r) => { o += lineBytes.ops(r); }); });
  ['proxy', 'access'].forEach((t) => Object.keys(M.L[t]).forEach((d) => { if (inRetention(d)) M.L[t][d].filter(keepRow).forEach((r) => { p += lineBytes[t](r); }); }));
  return { ops: o, access: p, proxy: p, total: o + p };
}
function logClear(type, before) {
  let freed = 0; const types = type === 'all' ? ['ops', 'access', 'proxy'] : type === 'ops' ? ['ops'] : ['access', 'proxy'];
  types.forEach((t) => Object.keys(M.L[t]).forEach((d) => { if (!before || d < before) { M.L[t][d].forEach((r) => { freed += lineBytes[t](r); }); delete M.L[t][d]; } }));
  M.L.ver++; return freed;
}
function logExport(type, day) {
  const rows = inRetention(day) ? (M.L[type][day] || []).filter(keepRow) : [], f = { ops: (r) => [r.ts, r.who, r.action, r.detail, r.result].join('\t'), access: (r) => [r.ts, r.host, r.port, r.app, r.route, r.node].join('\t'), proxy: (r) => r.ts + ' ' + r.level + ' ' + r.msg };
  return rows.map(f[type]).join('\n') + (rows.length ? '\n' : '');
}

/* ===================== 6. 后台任务 (进度由时间推算; 会改配置的任务让 Clash API 中断 2 秒) ===================== */
const APPLY = ['js.gen', 'js.check', 'js.apply', 'js.ready'];
/* o: {done(): 完成时的副作用, 可返回 {vars, result}; rollback(): 失败时回滚; msg: 完成消息的 key; outage: false = 不重启核心; outFrac: 核心中断从多少比例开始;
 *     noFail: 不受 failnext=1 影响; fail: 一定失败; failMsg: 失败消息的 key; failAt: 失败发生在多少比例 (默认 0.62)} */
function newJob(name, steps, ms, o) {
  o = o || {}; const t = now(), id = name + '-' + sec() + '-' + (++M.jobSeq), dur = D(ms);
  M.jobs[id] = { id, name, steps, start: t, dur, o, state: 'running', fail: !!o.fail || (!!M.failJob && !o.noFail), vars: null, result: null };
  if (!o.noFail) M.failJob = false;
  if (o.outage !== false) { const f = t + dur * (o.outFrac || 0.55); M.clashWins.push([f, f + D(2000)]); }
  Object.keys(M.jobs).forEach((k) => { if (t - M.jobs[k].start > 3600e3) delete M.jobs[k]; });
  return id;
}
function settle() {
  const t = now();
  Object.keys(M.jobs).forEach((id) => {
    const j = M.jobs[id]; if (j.state !== 'running') return;
    const pct = (t - j.start) / j.dur * 100;
    try {
      if (j.fail && pct >= (j.o.failAt || 0.62) * 100) { j.state = 'error'; if (j.o.code) { j.code = j.o.code; j.result = Object.assign({ code: j.o.code }, j.o.failResult); } if (j.o.rollback) j.o.rollback(); }
      else if (pct >= 100) { j.state = 'done'; const r = j.o.done ? j.o.done() : null; if (r) { j.vars = r.vars || null; j.result = r.result || null; j.resultFn = r.resultFn || null; } }
    } catch (e) { console.error('mock-server: job ' + j.name + ' hook failed: ' + safeErr(e)); }
  });
  M.clashWins = M.clashWins.filter((w) => w[1] > t);
  try { speedSettle(); } catch (e) { console.error('mock-server: speed test settle failed: ' + safeErr(e)); }
}
const clashIsDown = () => { if (M.clashDown) return true; const t = now(); return M.clashWins.some((w) => t >= w[0] && t < w[1]); };
const helperIsDown = () => { if (M.helperDown) return true; const w = M.helperWin, t = now(); return !!(w && t >= w[0] && t < w[1]); };
function jobView(j, lang) {
  const n = j.steps.length, pct = j.state === 'running' ? Math.min(99, Math.floor((now() - j.start) / j.dur * 100)) : 100;
  const idx = j.state === 'done' ? n : Math.min(n - 1, Math.floor((j.state === 'error' ? (j.o.failAt || 0.62) : pct / 100) * n));
  return Object.assign({ ok: true, id: j.id, name: j.name, state: j.state, pct,
    msg: j.state === 'done' ? tr(lang, j.o.msg || 'js.finish', j.vars) : j.state === 'error' ? tr(lang, j.o.failMsg || 'jd.fail', j.o.failVars) : tr(lang, j.steps[idx]) + '…',
    steps: j.steps.map((k, i) => ({ label: tr(lang, k), state: j.state === 'done' || i < idx ? 'done' : i === idx ? (j.state === 'error' ? 'error' : 'run') : 'todo' })), result: j.resultFn ? j.resultFn(lang) : (j.result || {}) }, j.code ? { code: j.code } : null);     // 失败任务: 顶层也带 code, 前端的错误处理直接可用
}

/* ===================== 7. 辅助服务 API (docs/API.md) ===================== */
class ApiErr extends Error { constructor(code, key, vars, extra, status) { super(code); this.code = code; this.key = key; this.vars = vars; this.extra = extra; this.status = status || 200; } }
const E = (code, key, vars, extra, status) => new ApiErr(code, key, vars, extra, status);
class Raw { constructor(body, type, headers, status) { this.body = body; this.type = type || 'text/plain; charset=utf-8'; this.headers = headers || {}; this.status = status || 200; } }
const R = {};
const route = (m, p, fn, o) => { R[m + ' ' + p] = Object.assign({ fn }, o); };
const ports = () => ({ proxy: 7890, ui: PORT, api: HPORT, speed: 7892 });
const platform = () => (M.os === 'windows' ? { os: 'windows', osver: '11 23H2', arch: 'amd64' } : { os: 'darwin', osver: '15.1', arch: 'arm64' });
const latestApp = () => (M.upd.on ? LATEST_APP : M.upd.cur), latestCore = () => (M.upd.on ? LATEST_CORE : M.upd.coreCur);
const appAvail = () => verCmp(latestApp(), M.upd.cur) > 0, coreAvail = () => verCmp(latestCore(), M.upd.coreCur) > 0;
const envOut = () => { const miss = M.rs.filter((s) => s.enabled && !s.present).map((s) => s.tag); return { core: M.env.core, rules: miss.length === 0, service: M.env.service, sysproxy: M.env.sysproxy, shortcut: M.env.shortcut ? shortcutText() : null, shortcut_cmd: M.env.shortcut ? 'enana' : '~/.enana/enana', rules_updated: M.rulesUpdated, rules_missing: miss }; };

/* ---- 账号: 登录 / 注册 / 退出 / 代理总开关 (中心账号库是内存里的假 enana.cc) ---- */
const EMAIL_RE = /^[A-Za-z0-9._%+'-]{1,64}@[A-Za-z0-9.-]{1,190}\.[A-Za-z]{2,24}$/;
const validEmail = (e) => e.length <= 254 && EMAIL_RE.test(e);
/* 登录失败 5 次 / 注册尝试 5 次 (5 分钟内) -> 锁定 locksec 秒; 登录与注册共用同一把锁, 这样 auth/status 的 wait 对两个表单都成立 */
function lockWait() {
  const t = now(); if (M.lockUntil > t) return Math.ceil((M.lockUntil - t) / 1000);
  if (M.lockUntil) { M.lockUntil = 0; M.fails = []; M.regs = []; }
  return 0;
}
function lockCheck() { const w = lockWait(); if (w > 0) throw E('E_LOCKED', null, null, { wait: w }); }
function noteAttempt(list) { const t = now(); M[list] = M[list].filter((x) => t - x < 300000); M[list].push(t); if (M[list].length >= 5) M.lockUntil = t + M.locksec * 1000; }
const acctPwOk = (acc, pw) => (acc.hash ? pbk(pw, acc.salt) === acc.hash : acc.pw === pw);
const cred = (c) => ({ email: String(c.form.user || '').trim().toLowerCase(), pw: String(c.form.password || '') });     // 密码只读请求体, 绝不看 URL
route('GET', '/api/auth/status', (c) => ({ ok: true, required: true, account_hint: M.lastAcct ? maskEmail(M.lastAcct.email) : '', offline_ok: !!(M.account && M.lastAcct && M.lastAcct.email === M.account), notice: noticeText(c.lang), notice_code: M.notice ? (M.notice.code || '') : '',
  account_url: CENTRAL, register_url: CENTRAL + '/register', manage_url: CENTRAL + '/account', wait: lockWait() }), { pub: true });
route('POST', '/api/login', async (c) => {
  const a = cred(c), kick = String(c.form.kick || ''); await sleep(rnd(600, 1200));      // 向 enana.cc 校验的往返
  if (!validEmail(a.email) || a.pw.length < 1 || a.pw.length > 128) throw E('E_INVALID', 'e.loginFormat');
  lockCheck();
  const bad = (code, count) => { if (count) noteAttempt('fails'); oplog('dashboard', 'login.fail', kv({ code }), 'error'); throw E(code); };
  let via = 'online';
  if (M.central === 'up') {
    const acc = M.dir[a.email]; if (!acc || !acctPwOk(acc, a.pw)) bad('E_BAD_CREDENTIALS', true);
    const plat = platformOf(), others = devicesOf(a.email).filter((d) => d.uid !== 'this-mock' && d.platform === plat && d.online);          // 设备数量限制 (服务端强制): 本平台最多 2 台同时在线
    if (others.length >= devLimit()) {
      if (!kick) { oplog('dashboard', 'login.fail', kv({ code: 'E_DEVICE_LIMIT' }), 'error'); throw E('E_DEVICE_LIMIT', null, null, { platform: plat, limit: devLimit(), devices: others.map((d) => devView(d, c.lang)) }); }     // 不算密码错误, 不计入限流
      const target = others.filter((d) => d.uid === kick)[0]; if (!target) throw E('E_INVALID', 'e.devKick');
      target.online = false; target.revoked = true;                         // 被下线的设备稍后 (<= 2 分钟) 自动退出登录并关闭代理
    }
    M.lastAcct = cacheRec(a.email, a.pw);                                  // 在线成功: 刷新本机的离线校验值
  } else {                                                                 // enana.cc 连不上: 只有「当前仍处于登录状态」的账号能用本机缓存离线登录; 退出过的 / 其它账号必须在线校验
    if (!(M.account === a.email && M.lastAcct && M.lastAcct.email === a.email)) bad('E_ACCOUNT_UNREACHABLE', false);
    if (pbk(a.pw, M.lastAcct.salt) !== M.lastAcct.hash) bad('E_BAD_CREDENTIALS', true);
    via = 'offline';
  }
  M.account = a.email; M.fails = []; M.notice = null; sudoClear(); setThisOnline(a.email, true); oplog('dashboard', 'login', kv(kick && via === 'online' ? { via, kick } : { via }));
  return { ok: true, token: M.secret, account: a.email, via };
}, { pub: true });
route('POST', '/api/register', async (c) => {
  const a = cred(c); await sleep(rnd(600, 1200));
  if (!validEmail(a.email) || a.pw.length > 128) throw E('E_INVALID', 'e.loginFormat');
  if (a.pw.length < 8) throw E('E_WEAK_PASSWORD');
  lockCheck(); noteAttempt('regs');
  if (M.central !== 'up') throw E('E_ACCOUNT_UNREACHABLE');
  if (M.dir[a.email]) throw E('E_EMAIL_TAKEN');
  const salt = randHex(8); M.dir[a.email] = { id: 'acc_' + randHex(4), salt, hash: pbk(a.pw, salt) };       // 假的 enana.cc 只存加盐哈希
  M.lastAcct = cacheRec(a.email, a.pw); M.account = a.email; M.fails = []; M.notice = null; sudoClear(); setThisOnline(a.email, true);
  oplog('dashboard', 'login', kv({ via: 'online', registered: 1 }));      // API.md 没有「注册」操作码: 注册后的自动登录记为 login
  return { ok: true, registered: true, token: M.secret, account: a.email, via: 'online' };
}, { pub: true });
route('POST', '/api/logout', () => {
  oplog('dashboard', 'logout', '');
  M.proxyOn = false; M.account = null; M.secret = randHex(16); sudoClear(); setThisOnline(null, false);       // 代理关闭 + 令牌立刻失效 (所有浏览器) + 释放这台电脑的在线名额
  const t = now(); M.clashWins.push([t + D(150), t + D(150 + 2500)]);      // 核心在后台重启一次, 换上新令牌 (约 2.5 秒)
  return { ok: true };
});
route('POST', '/api/proxy', async (c) => {
  const on = c.p('on'), mode = c.p('mode');                                // 总开关 on=0|1 和 / 或 代理模式 mode=auto|global (至少给一个)
  if ((on === undefined || on === '') && (mode === undefined || mode === '')) throw E('E_INVALID', 'e.badBool');
  if (on !== undefined && on !== '' && on !== '0' && on !== '1') throw E('E_INVALID', 'e.badBool');
  if (mode !== undefined && mode !== '' && mode !== 'auto' && mode !== 'global') throw E('E_INVALID', 'e.badBool');
  const hasOn = on === '0' || on === '1', hasMode = mode === 'auto' || mode === 'global';
  if (hasOn && on === '1' && clashIsDown()) {                              // 核心没在运行: 先等它起来 (模拟里最多 1.5 秒), 起不来就失败
    const end = now() + D(1500); while (clashIsDown() && now() < end) await new Promise((ok) => setTimeout(ok, 30));
    if (clashIsDown()) { oplog('dashboard', 'proxy.on', kv({ code: 'E_NOT_RUNNING' }), 'error'); throw E('E_NOT_RUNNING'); }
  } else await sleep(rnd(400, 800));                                       // 让界面的忙碌状态看得见
  const wasOn = M.proxyOn, wasMode = M.proxyMode;
  if (hasMode) M.proxyMode = mode;                                         // 模式会记住: 关闭总开关时保留, 再次开启沿用
  if (hasOn) M.proxyOn = on === '1';
  if (M.proxyOn !== wasOn || (M.proxyOn && M.proxyMode !== wasMode)) M.conns = [];     // 切换后现有连接会断开重连 (走新的路由)
  if (hasMode && M.proxyMode !== wasMode) oplog('dashboard', 'proxy.mode', kv({ mode: M.proxyMode, enabled: M.proxyOn ? 1 : 0 }));
  if (hasOn && M.proxyOn !== wasOn) oplog('dashboard', M.proxyOn ? 'proxy.on' : 'proxy.off', '');
  return { ok: true, enabled: M.proxyOn, mode: M.proxyMode };
});
route('POST', '/api/password', async (c) => {                            // 本机修改密码 (不需要 sudo: 旧密码就是验证); 成功后这台设备保持登录, 账号下的其它设备全部被退出
  const oldPw = String(c.form.old || ''), nw = String(c.form.new || '');   // 密码只读请求体, 绝不看 URL, 也不写进日志
  await sleep(rnd(500, 900));
  if (oldPw.length < 1 || oldPw.length > 128) throw E('E_INVALID', 'e.pwEmpty');                           // 校验顺序同 lib/auth.sh 的 auth_change_password
  if (nw.length < 8 || nw.length > 71 || nw === oldPw) throw E('E_WEAK_PASSWORD', 'e.pwWeakNew');
  lockCheck();                                                             // 和登录 / 注册 / 步骤验证共用失败计数
  if (M.central !== 'up') { oplog('dashboard', 'password.change', kv({ code: 'E_ACCOUNT_UNREACHABLE' }), 'error'); throw E('E_ACCOUNT_UNREACHABLE', 'e.pwOffline'); }          // 必须在线才能改 (旧密码由云端校验, 所以离线时连「旧密码不对」都看不到)
  if (!verifyPw(oldPw)) { noteAttempt('fails'); oplog('dashboard', 'password.change', kv({ code: 'E_BAD_CREDENTIALS' }), 'error'); throw E('E_BAD_CREDENTIALS', 'e.pwWrongCur', null, { wait: lockWait() }); }
  const acc = M.dir[M.account] || {}, salt = randHex(8); M.dir[M.account] = { id: acc.id || 'acc_' + randHex(4), salt, hash: pbk(nw, salt) };         // 假的 enana.cc 只存加盐哈希 (种子账号的明文密码随之作废)
  M.lastAcct = cacheRec(M.account, nw); M.fails = []; sudoClear();         // 本机刷新离线校验值; 令牌 (= Clash secret) 不变, 这台设备保持登录
  devicesOf(M.account).forEach((d) => { if (d.uid !== 'this-mock') { d.online = false; d.revoked = true; d.revoked_reason = 'password_changed'; } });   // 其它设备: 下次心跳 / auth/status 收到 notice password_changed, 自动退出并关闭代理
  oplog('dashboard', 'password.change', ''); return { ok: true };
});
route('GET', '/api/devices', (c) => {
  if (M.central !== 'up') throw E('E_ACCOUNT_UNREACHABLE', 'e.devOffline');
  const full = (d, cur) => ({ uid: d.uid, name: cur ? tr(c.lang, 'dev.this') : devName(d, c.lang), platform: cur ? platformOf() : d.platform, os: cur ? (M.os === 'windows' ? '11' : '15.1') : d.os, app: cur ? M.upd.cur : d.app, last_seen: cur ? sec() : d.last_seen, online: cur ? true : d.online, ip_hint: d.ip_hint, current: !!cur });
  const mine = devicesOf(M.account || ''), me = mine.filter((d) => d.uid === 'this-mock')[0] || { uid: 'this-mock', ip_hint: '192.0.*.*' };
  return { ok: true, platform: platformOf(), limit: devLimit(), devices: [full(me, true)].concat(mine.filter((d) => d.uid !== 'this-mock').map((d) => full(d, false))) };
});
route('POST', '/api/devices/kick', (c) => {
  const uid = c.p('uid'); if (!uid) throw E('E_INVALID', 'e.devUid'); if (uid === 'this-mock') throw E('E_INVALID', 'e.devSelf');
  if (M.central !== 'up') throw E('E_ACCOUNT_UNREACHABLE', 'e.devOffline');
  const d = devicesOf(M.account || '').filter((x) => x.uid === uid)[0]; if (!d) throw E('E_NOT_FOUND', 'e.noDevice');
  d.online = false; d.revoked = true; oplog('dashboard', 'devices.kick', kv({ uid, name: d.name_en || d.name })); return { ok: true };       // 被下线的设备在 <= 2 分钟内自动退出登录 (这里只标记)
});

/* ---- 步骤验证 (sudo): 敏感的操作 / 显示要再输一次「当前登录账号」的密码 (docs/API.md「敏感操作需要再次输入登录密码」) ----
 * POST /api/auth/verify -> {sudo, ttl}; 之后带 X-Enana-Sudo 头重试。白名单就是下面这张表 (以后加功能往表里加一行)。
 * 检查顺序同 lib/api.sh: 请求头 (403) -> 请求体 (413) -> 路由 (404) -> 令牌 (401) -> sudo (403 E_SUDO_REQUIRED) -> 接口自己的校验。
 * sudo 令牌只存在这个进程的内存里 (M.sudo: 令牌 -> 到期时间, 真实秒数, 不随 --fast 缩短); 退出账号 / 登录 / 注册 / 改密码 / expire=1 / kickme=1 都会让它们全部失效。 */
const SUDO_ROUTES = { 'POST /api/servers/delete': 1, 'POST /api/sub/delete': 1, 'GET /api/servers/secret': 1, 'GET /api/sub/url': 1, 'POST /api/logs/clear': 1, 'POST /api/devices/kick': 1, 'POST /api/sync/clear': 1, 'GET /api/export': 1 };
const sudoClear = () => { M.sudo = Object.create(null); };
function sudoOk(req) {
  const t = String(req.headers['x-enana-sudo'] || ''), exp = t ? M.sudo[t] : 0;
  if (exp && exp > now()) return true;
  if (exp) delete M.sudo[t];
  return false;
}
/* 当前账号的密码校验: 在本机用「加盐 PBKDF2 校验值」(登录时在线校验过, 不需要联网); 缓存不是这个账号时用假的 enana.cc 账号库 */
function verifyPw(pw) {
  const email = M.account; if (!email) return false;
  if (M.lastAcct && M.lastAcct.email === email) return pbk(pw, M.lastAcct.salt) === M.lastAcct.hash;
  const acc = M.dir[email]; return !!acc && acctPwOk(acc, pw);
}
route('POST', '/api/auth/verify', async (c) => {
  const pw = String(c.form.password || '');                                // 密码只读请求体, 绝不看 URL, 也不写进日志
  await sleep(rnd(150, 350));
  if (pw.length < 1 || pw.length > 128) throw E('E_INVALID', 'e.pwEmpty');
  lockCheck();                                                             // 和登录 / 注册共用失败计数: 连续错 5 次 -> E_LOCKED + wait
  if (!verifyPw(pw)) { noteAttempt('fails'); oplog('dashboard', 'auth.verify', kv({ code: 'E_BAD_CREDENTIALS' }), 'error'); throw E('E_BAD_CREDENTIALS', 'e.pwWrong', null, { wait: lockWait() }); }
  M.fails = []; const tok = randHex(16), ttl = M.sudoTtl; M.sudo[tok] = now() + ttl * 1000; oplog('dashboard', 'auth.verify', '');
  return { ok: true, sudo: tok, ttl };
});
/* 节点凭据: 按节点类型生成的确定性占位值 (同一个节点每次一样; 官方节点没有) —— 只有 GET /api/servers/secret 与 GET /api/export (都要 sudo) 会返回它们 */
function secretFields(s) {
  const h = (k, n) => crypto.createHash('sha1').update('enana-mock-secret|' + s.tag + '|' + k).digest('hex').slice(0, n), pw = () => ({ name: 'password', value: 'pw-example-' + h('password', 12) });
  const id = () => { const x = crypto.createHash('sha1').update('enana-mock-secret|' + s.tag + '|uuid').digest('hex'); return { name: 'uuid', value: [x.slice(0, 8), x.slice(8, 12), '4' + x.slice(13, 16), '8' + x.slice(17, 20), x.slice(20, 32)].join('-') }; };
  if (s.type === 'vless' || s.type === 'vmess') return [id()];
  if (s.type === 'tuic') return [id(), pw()];
  if (s.type === 'shadowsocks' || s.type === 'ss') return [{ name: 'method', value: 'aes-256-gcm' }, pw()];
  if (s.type === 'http' || s.type === 'socks') return [{ name: 'username', value: 'user-' + h('user', 6) }, pw()];
  return [pw()];                                                           // trojan / hysteria2 / anytls
}
route('GET', '/api/servers/secret', (c) => {
  const tag = c.p('tag'), s = M.servers.filter((x) => x.tag === tag)[0]; if (!tag || !s) throw E('E_NOT_FOUND', 'e.noServer');
  if (s.official) throw E('E_INVALID', 'e.officialSecret');                // 官方节点的凭据永远不显示
  oplog('dashboard', 'secret.view', kv({ kind: 'server', tag })); return { ok: true, tag, fields: secretFields(s) };
});
route('GET', '/api/sub/url', (c) => {
  const name = c.p('name'), url = hasOwn(M.subUrls, name) ? M.subUrls[name] : '';
  if (!url || !M.subs.some((x) => x.name === name)) throw E('E_NOT_FOUND', 'e.noSub');                    // 没有这个订阅, 或它没有保存链接 (手动导入的): lib/api.sh 同样是「找不到这个订阅」
  oplog('dashboard', 'secret.view', kv({ kind: 'sub', name })); return { ok: true, name, url };
});
/* 配置备份 (text/plain 的 JSON): 服务器 (含占位凭据) / 订阅 / 策略 / DNS / 规则选择; 官方节点 (会员) 不包含 */
route('GET', '/api/export', () => {
  const own = M.servers.filter((s) => !s.official);
  const doc = { app: 'enana', kind: 'backup', schema: 1, version: M.upd.cur, exported_at: sec(),
    servers: own.map((s) => ({ tag: s.tag, type: s.type, server: s.server, port: s.port, role: s.role, sub: s.sub, credentials: secretFields(s).reduce((o, f) => { o[f.name] = f.value; return o; }, {}) })),
    subs: M.subs.map((b) => ({ name: b.name, host: b.host, interval: b.interval, url: hasOwn(M.subUrls, b.name) ? M.subUrls[b.name] : '' })),
    policies: { services: Object.assign({}, M.svc), sites: M.overrides.map((o) => ({ value: o.value, state: o.state })), apps: M.apps.filter((a) => !a.custom).map((a) => ({ name: a.name, state: a.state })),
      custom_apps: M.apps.filter((a) => a.custom).map((a) => ({ name: a.name, path: a.path, state: a.state })), site_domains: clone(M.siteMods) },
    dns: Object.assign({}, M.dns, { hosts: clone(M.hosts) }), rules: { enabled: M.rs.filter((x) => x.enabled).map((x) => x.tag), custom: M.custom.map((x) => ({ name: x.name, url: x.url, policy: x.policy })) } };
  oplog('dashboard', 'backup.export', kv({ servers: own.length, subs: M.subs.length }));
  return new Raw(JSON.stringify(doc, null, 2) + '\n', 'text/plain; charset=utf-8', { 'Content-Disposition': 'attachment; filename="enana-backup-' + dayOf(now()).replace(/-/g, '') + '.json"' });
});

/* ---- 偏好设置 (界面习惯; 整体替换, 每次写入 version + 1; 不记操作日志) ---- */
function canonJson(v, depth) {                                             // 同 lib/prefs.sh 的 prefs_canon: 键排序, 最多 12 层嵌套 (超过返回 undefined)
  if (v === null || typeof v !== 'object') return v;
  if (depth > 12) return undefined;
  if (Array.isArray(v)) { const a = []; for (let i = 0; i < v.length; i++) { const y = canonJson(v[i], depth + 1); if (y === undefined) return undefined; a.push(y); } return a; }
  const o = Object.create(null); const ks = Object.keys(v).sort();
  for (let i = 0; i < ks.length; i++) { const y = canonJson(v[ks[i]], depth + 1); if (y === undefined) return undefined; o[ks[i]] = y; }
  return o;
}
route('GET', '/api/prefs', () => ({ ok: true, prefs: M.prefs.obj, version: M.prefs.version, updated: M.prefs.updated }));
route('POST', '/api/prefs', (c) => {
  if (Buffer.byteLength(c.body) > 32768) throw E('E_INVALID', 'e.prefsSize');
  let o; try { o = JSON.parse(c.body); } catch (e) { o = undefined; }       // 解析错误的 message 里可能带有内容: 不打印
  if (!o || typeof o !== 'object' || Array.isArray(o)) throw E('E_INVALID', 'e.prefsJson');
  const canon = canonJson(o, 1); if (canon === undefined) throw E('E_INVALID', 'e.prefsJson');                // 嵌套超过 12 层
  if (Buffer.byteLength(JSON.stringify(canon)) > 32768) throw E('E_INVALID', 'e.prefsSize');
  M.prefs = { obj: canon, version: M.prefs.version + 1, updated: sec() }; if (M.sync) M.sync.local.dirty = true;       // 偏好会随「云端同步」一起同步; 保存的是规范化的 JSON (键排序)
  return { ok: true, version: M.prefs.version };
});

/* ---- 会员 / 套餐 (GET /api/plan; ctl plan=soon (默认) | free | pro | expired) ---- */
const OFFICIAL_NODES = [{ tag: 'enana-official-tokyo', type: 'vless', server: 'official-jp.example.net', port: 443, role: 'auto', sub: '', official: true }, { tag: 'enana-official-singapore', type: 'vless', server: 'official-sg.example.net', port: 443, role: 'auto', sub: '', official: true }];
function applyPlan() {                                                     // 套餐 -> 官方线路: pro 时服务器列表多出 2 个 official:true 的节点 (进核心配置), 其它套餐 (含过期) 没有
  M.servers = M.servers.filter((s) => !s.official); M.applied = M.applied.filter((s) => !s.official);
  if (M.plan === 'pro') OFFICIAL_NODES.forEach((n) => { M.servers.push(Object.assign({}, n)); M.applied.push(Object.assign({}, n)); });
}
const devLimit = () => (M.plan === 'pro' ? 5 : DEVICE_LIMIT);
route('GET', '/api/plan', (c) => {
  const p = M.plan, pro = p === 'pro', exp = p === 'expired', t = sec(), free = { enabled: true, tier: 'free' };
  const gated = () => (pro ? { enabled: true, tier: 'pro' } : { enabled: false, tier: 'pro', reason: exp ? 'expired' : 'upgrade', coming_soon: p === 'soon' });
  return { ok: true, plan: { code: pro ? 'pro' : 'free', title: tr(c.lang, pro ? 'plan.pro' : 'plan.free') }, expires_at: pro ? t + 30 * 86400 : exp ? t - 2 * 86400 : null, checked: t - 120, limits: { devices_per_platform: devLimit() },
    features: { core: free, sync: free, vps_deploy: free, custom_dns: free, official_proxy: gated(), unlimited_devices: gated(), priority_support: gated() }, official: { available: pro, nodes: pro ? OFFICIAL_NODES.length : 0 } };
});

/* ---- 状态 / 设置 ---- */
const ovOut = () => M.overrides.map((o) => Object.assign({ target: '', src: 'user', at: 0, why: '', fails: 0, app: '' }, o, { target_ok: targetOk(o.target || '') }));
route('GET', '/api/state', (c) => ({ ok: true, version: M.upd.cur, prefs_version: M.prefs.version, core: M.upd.coreCur, platform: platform(), ports: ports(), env: envOut(), servers: M.servers, subs: M.subs, overrides: ovOut(),
  first_run: M.servers.filter((s) => !s.official).length === 0, update: { available: appAvail(), latest: latestApp(), checked: M.upd.checked }, lang: M.langSet || c.hdrLang || 'zh', proxy: { enabled: M.proxyOn, mode: M.proxyMode }, account: { email: M.account || '' } }));
route('GET', '/api/settings', (c) => ({ ok: true, lang: M.langSet || c.hdrLang || 'zh', settings: { log_hours: M.logHours, log_hours_min: 12, log_hours_max: 720, log_ops: M.logOps, access_log: M.accessLog, log_core: M.logCore, auto_sites: M.autoSites, auto_update: M.autoUpdate }, usage: logUsage(), ports: ports(), account: { email: M.account || '' } }));
route('POST', '/api/settings', (c) => {
  let lh = c.p('log_hours'); const lang = c.p('lang'), ld = c.p('log_days'), al = c.p('access_log'), au = c.p('auto_update'), lo = c.p('log_ops'), lc = c.p('log_core'), as = c.p('auto_sites'), detail = {}; let job = null;
  if (lh === '' && /^\d{1,3}$/.test(ld) && +ld >= 1) lh = String(+ld * 24);                          // 旧版仪表盘按天提交
  if (lang !== '' && lang !== 'zh' && lang !== 'en') throw E('E_INVALID', 'e.badLang');
  if (lh !== '' && !(/^\d{2,3}$/.test(lh) && +lh >= 12 && +lh <= 720)) throw E('E_INVALID', 'e.badLogDays');
  if ([al, au, lo, lc, as].some((v) => v !== '' && v !== '0' && v !== '1')) throw E('E_INVALID', 'e.badBool');
  if (as === '1' && !M.servers.length) throw E('E_NO_SERVERS', 'e.autoNoServers');
  if (lang) { M.langSet = lang; detail.lang = lang; }
  if (au !== '') { M.autoUpdate = au === '1'; detail.auto_update = au; }                        // 「代理 → 自动更新」开关 (API.md 里没有, 提议新增)
  if (lh) { detail.setting = 'log_hours'; detail.from = M.logHours; detail.to = +lh; M.logHours = +lh; }
  if (lo !== '' && (lo === '1') !== M.logOps) { oplogForce('dashboard', 'settings.set', kv({ setting: 'log_ops', from: M.logOps ? 1 : 0, to: lo })); M.logOps = lo === '1'; }
  if (as !== '' && (as === '1') !== M.autoSites) { M.autoSites = as === '1'; M.autoSimAt = now(); oplog('dashboard', 'settings.set', kv({ setting: 'auto_sites', from: as === '1' ? 0 : 1, to: as })); }
  if (al !== '' && (al === '1') !== M.accessLog) { M.accessLog = al === '1'; oplog('dashboard', 'settings.set', kv({ setting: 'access_log', from: al === '1' ? 0 : 1, to: al })); job = newJob('settings-apply', APPLY, 3600, { done: applyNow, msg: 'jd.settings' }); }   // 改 access_log 要重新生成配置
  if (lc !== '' && (lc === '1') !== M.logCore) { M.logCore = lc === '1'; oplog('dashboard', 'settings.set', kv({ setting: 'log_core', from: lc === '1' ? 0 : 1, to: lc })); job = job || newJob('settings-apply', APPLY, 3600, { done: applyNow, msg: 'jd.settings' }); }
  if (Object.keys(detail).length) oplog('dashboard', 'settings.set', kv(detail));
  return job ? { ok: true, job } : { ok: true };
});

/* ---- 应用 / 覆盖 ---- */
route('GET', '/api/apps', () => appsPayload());
route('POST', '/api/apps/scan', async () => { await sleep(300); const n = scanApps(); oplog('dashboard', 'apps.scan', kv({ new: n })); return appsPayload(); });
route('POST', '/api/apps/adopt', (c) => {
  const names = c.p('names') ? c.p('names').split('\n').filter(Boolean) : null; let n = 0;
  M.apps.forEach((a) => { if (((!names && a.flag === 'new') || (names && names.indexOf(a.name) >= 0)) && a.rec) { a.state = a.rec; a.flag = 'ack'; a.target = ''; n++; } });
  oplog('dashboard', 'apps.adopt', kv({ count: n })); return { ok: true };
});
route('POST', '/api/apps/ack', (c) => {
  const all = c.p('all') === '1', name = c.p('name'); if (!all && !name) throw E('E_INVALID', 'e.needApp');
  M.apps.forEach((a) => { if (all || a.name === name) a.flag = 'ack'; });
  oplog('dashboard', 'apps.ack', all ? kv({ all: 1 }) : kv({ name })); return { ok: true };
});
const pinTags = () => M.applied.filter((x) => x.role === 'pin').map((x) => x.tag).slice(0, 16);
const targetOk = (tg) => !tg || (pinTags().length >= 2 && (tg === 'PINAUTO' || pinTags().indexOf(tg) >= 0));
route('POST', '/api/override', (c) => {
  const kind = c.p('kind'), value = c.p('value'), state = c.p('state'); let target = c.p('target');
  if (['follow', 'direct', 'pin', 'auto'].indexOf(state) < 0) throw E('E_INVALID', 'e.badState');
  if (state !== 'pin') target = '';
  if (!targetOk(target)) throw E('E_INVALID', 'e.badTarget');
  if (kind === 'app') {
    if (!value || value.length > 80 || /[|"\\\/\x00-\x1f]/.test(value)) throw E('E_INVALID', 'e.badName');
    const a = M.apps.filter((x) => x.name === value)[0]; if (!a) throw E('E_NOT_FOUND', 'e.noApp');
    oplog('dashboard', 'override.set', kv({ kind, name: value, from: a.state, to: state, target_from: a.target || '', target_to: target }));
    a.state = state; a.target = target; return { ok: true };
  }
  if (kind === 'site') {
    if (!value || value.length > 80 || !/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/.test(value)) throw E('E_INVALID', 'e.badName');
    const old = M.overrides.filter((o) => o.kind === 'site' && o.value === value)[0], src = old && old.src === 'auto' ? 'auto' : '';
    M.overrides = M.overrides.filter((o) => !(o.kind === 'site' && o.value === value));
    if (state !== 'follow') { M.overrides.push(Object.assign({ kind: 'site', value, state, target, src: old ? old.src : 'user', at: old ? old.at : 0 }, old && old.src === 'auto' ? { why: old.why, fails: old.fails, app: old.app } : {})); oplog('dashboard', 'override.set', kv({ kind, name: value, from: old ? old.state : 'follow', to: state, target_from: old ? old.target : '', target_to: target, src })); }
    else { if (M.dismissed.indexOf(value) < 0) M.dismissed.push(value); oplog('dashboard', 'override.delete', kv({ kind, name: value, from: old ? old.state : 'follow', to: 'follow', src })); }
    return { ok: true };
  }
  throw E('E_INVALID', 'e.badKind');
});
/* 切换一个策略开关: 由辅助服务代为切换 (每次切换都有操作记录); 和 Clash 的 PUT /proxies/<tag> 同一个效果 */
route('POST', '/api/policy', (c) => {
  const tag = c.p('tag'), name = c.p('name');
  if (!/^(svc-[a-z0-9-]+|Final|Global|PIN)$/.test(tag) || !name || name.length > 120) throw E('E_INVALID', 'e.badName');
  const P = buildProxies(), g = P[tag];
  if (!g || !g.all || g.all.indexOf(name) < 0) throw E('E_NOT_FOUND', 'e.noOption');
  const from = g.now; if (from !== name) applySelector(tag, name);
  const e = svcList().filter((x) => x.tag === tag)[0];
  oplog('dashboard', 'policy.switch', kv({ kind: 'selector', tag, site: e ? (e.name || '') : '', from, to: name }));
  return { ok: true, from, to: name };
});
route('POST', '/api/audit', (c) => {
  const ev = c.p('ev'); if (ev !== 'kill') throw E('E_INVALID', 'e.badKind');
  const scope = ['all', 'one', 'host'].indexOf(c.p('scope')) >= 0 ? c.p('scope') : 'all', host = /^[A-Za-z0-9._:-]{0,120}$/.test(c.p('host')) ? c.p('host') : '';
  oplog('dashboard', 'conns.kill', kv({ scope, count: +c.p('n') || 0, host })); return { ok: true };
});
route('POST', '/api/sites/auto/clear', () => {
  const autos = M.overrides.filter((o) => o.kind === 'site' && o.src === 'auto');
  autos.forEach((o) => { if (M.dismissed.indexOf(o.value) < 0) M.dismissed.push(o.value); });
  M.overrides = M.overrides.filter((o) => !(o.kind === 'site' && o.src === 'auto'));
  oplog('dashboard', 'autosite.clear', kv({ count: autos.length })); return { ok: true, removed: autos.length };
});

/* ---- 自定义软件: 先校验 (POST /api/apps/inspect, 不会执行任何程序), 再添加 (POST /api/apps/custom) / 删除 (POST /api/apps/custom/delete); 行为对照 lib/apps.sh ----
 * 魔法输入见文件头。路径只接受绝对路径; 名称按 /Applications、~/Applications、/opt/homebrew、/usr/local 搜索, 最多 8 个候选; 无效的输入也是 ok:true + 一个 {valid:false, path, reason} 候选。 */
const RUNNING = ['Cursor', 'Slack', 'Google Chrome', 'Visual Studio Code', 'Claude', 'Telegram', 'Docker Desktop', 'Safari', 'Postman', 'node'];            // 「正在运行」的进程 (matches_running)
const APP_EXTRA = [['Cursor', 'app', '/Applications/Cursor.app'], ['Visual Studio Code - Insiders', 'app', '/Applications/Visual Studio Code - Insiders.app'], ['CodeRunner', 'app', '/Applications/CodeRunner.app'], ['Xcode', 'app', '/Applications/Xcode.app'],
  ['Codex', 'app', '/Applications/Codex.app'], ['Bear', 'app', '/Applications/Bear.app'], ['Sketch', 'app', '/Applications/Sketch.app'], ['node', 'bin', '/opt/homebrew/bin/node'], ['mytool', 'bin', '/usr/local/bin/mytool'], ['python3', 'bin', '/usr/bin/python3'], ['ffmpeg', 'bin', '/opt/homebrew/bin/ffmpeg']];
const SIGNED_BINS = ['node', 'python3'];
function candidate(kind, name, p) {                                        // 一个「校验通过」的候选: 内容由名称哈希决定 (同一个名称每次一样)
  const h = hash('cand|' + kind + '|' + name), r = mulberry(h), CH = 'ABCDEFGHJKLMNPQRSTUVWXYZ0123456789', signed = kind === 'app' ? h % 6 !== 0 : SIGNED_BINS.indexOf(name) >= 0, app = kind === 'app';
  const slug = name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'app', team = signed ? Array.from({ length: 10 }, () => CH[Math.floor(r() * CH.length)]).join('') : '';
  const icon = app && M.icons !== 'none' && NO_ICON.indexOf(name) < 0 ? iconUrl(name) : ''; if (icon) { if (Object.keys(M.inspected).length > 500) M.inspected = Object.create(null); M.inspected[iconSlug(name)] = name; }      // 检查时即时提取图标: 马上就能显示
  return { valid: true, kind, name, bundle_id: app ? 'com.example.' + slug : '', version: app ? (1 + h % 9) + '.' + ((h >>> 4) % 20) + '.' + ((h >>> 9) % 10) : '', path: p, exec: app ? name : p.split(/[\\\/]/).pop(), signed,
    authority: signed ? (app ? 'Developer ID Application: ' + name + ' Software Inc.' : 'Developer ID Application: Example Foundation') : '', team, icon,
    exists: M.apps.some((a) => a.name === name || (a.custom && a.path === p)), matches_running: RUNNING.indexOf(name) >= 0 || h % 5 === 0 };
}
const badCand = (p, k) => ({ valid: false, path: p, _k: k });                                                 // 内部用: 失败原因存成文案 key, 输出时再翻译
const outCand = (c, lang) => (c.valid ? c : { valid: false, path: c.path, reason: tr(lang, c._k) });
const isWinPath = (s) => M.os === 'windows' && /^[A-Za-z]:[\\\/]/.test(s);
function inspectPath(s) {                                                  // s 是绝对路径 (已去掉引号 / 转义 / 非法字符)
  const win = isWinPath(s);
  if (!win && (M.os === 'windows' || s[0] !== '/')) return badCand(s, 'e.appRelative');                       // 只接受当前平台的绝对路径
  const p = win ? s.replace(/\//g, '\\').replace(/\\+$/, '') : (path.posix.normalize(s).replace(/\/+$/, '') || '/'), base = p.split(win ? '\\' : '/').pop();
  if (/(missing|nonexistent|not-?found|nope)/i.test(base)) return badCand(p, 'e.appNotFound');
  if (win) {
    if (/\.exe$/i.test(base)) return /^C:\\(Program Files|Users)/i.test(p) ? candidate(/^C:\\Program Files/i.test(p) ? 'app' : 'bin', base.replace(/\.exe$/i, ''), p) : badCand(p, 'e.appNotFound');
    return /\.(txt|md|dll|ini|log|json|xml|cfg|conf)$/i.test(base) ? badCand(p, 'e.appNotExec') : badCand(p, 'e.appNotFound');
  }
  if (/^\/(private\/)?var\/root(\/|$)/.test(p) || /^\/root(\/|$)/.test(p) || p === '/etc/sudoers' || p === '/etc/master.passwd') return badCand(p, 'e.appPerm');
  const m = M.apps.filter((a) => (a.custom ? a.path : appPath(a.name)) === p)[0];                // 已在应用列表里的软件 (exists:true)
  if (m) return candidate(m.custom && !/\.app$/.test(m.path) ? 'bin' : 'app', m.name, p);
  if (/\.app$/.test(p)) return /^\/(System\/)?Applications(\/|$)/.test(p) || /^\/Users\/[^\/]+\/Applications\//.test(p) || /^\/opt\/homebrew\/Caskroom\//.test(p) ? candidate('app', base.replace(/\.app$/, ''), p) : badCand(p, 'e.appNotFound');
  if (/^\/(usr\/local\/bin|opt\/homebrew\/bin|usr\/bin|bin|usr\/sbin|sbin|opt\/local\/bin)\/[^\/]+$/.test(p) || /^\/Users\/[^\/]+\/(bin|\.local\/bin|\.cargo\/bin)\/[^\/]+$/.test(p)) return candidate('bin', base, p);
  if (/^\/(etc|var\/log|var\/db|usr\/share|Library\/Preferences)(\/|$)/.test(p) || /\.(txt|md|conf|plist|json|log|png|jpg|pdf|zip|dmg|sh|py)$/i.test(base) || /^\/Applications\/[^\/]+$/.test(p)) return badCand(p, 'e.appNotExec');
  return badCand(p, 'e.appNotFound');
}
function inspectName(s) {
  const q = s.toLowerCase(), pool = [], seen = Object.create(null), rank = (x) => (x[0].toLowerCase() === q ? 0 : x[0].toLowerCase().indexOf(q) === 0 ? 1 : 2);
  const add = (name, kind, p) => { if (!seen[name.toLowerCase()]) { seen[name.toLowerCase()] = 1; pool.push([name, kind, p]); } };
  M.apps.forEach((a) => add(a.name, a.custom && !/\.app$/.test(a.path) ? 'bin' : 'app', a.custom ? a.path : appPath(a.name)));
  APP_EXTRA.forEach((x) => add(x[0], x[1], M.os === 'windows' ? 'C:\\Program Files\\' + x[0] + '\\' + x[0] + '.exe' : x[2]));
  const hits = pool.filter((x) => x[0].toLowerCase().indexOf(q) >= 0).sort((a, b) => rank(a) - rank(b) || (a[0] < b[0] ? -1 : 1)).slice(0, 8);
  return hits.length ? hits.map((x) => candidate(x[1], x[0], x[2])) : [badCand('', 'e.appNoName')];
}
function inspectInput(raw) {                                               // -> 候选数组 (内部格式, 输出前要 outCand)
  let s = String(raw).replace(/[\r\n]/g, '').trim().slice(0, 300); s = s.replace(/^(['"])([\s\S]*)\1$/, '$2').trim();        // 去掉两端的空白和引号, 最多 300 个字符
  if (!isWinPath(s)) s = s.replace(/\\ /g, ' ');                           // 把「拖进终端」得到的「\ 」还原成空格
  if (!s) return [badCand('', 'e.appInput')];
  if (s[0] === '/' || isWinPath(s)) return /[|"\x00-\x1f\x7f]/.test(s) || (!isWinPath(s) && s.indexOf('\\') >= 0) ? [badCand(s, 'e.appCharsPath')] : [inspectPath(s)];
  if (s.indexOf('/') >= 0) return [badCand('', 'e.appRelative')];          // 带斜杠但不是绝对路径 (相对路径、~/ 开头的)
  if (/[\[\]*?|"\\\x00-\x1f]/.test(s)) return [badCand('', 'e.appCharsName')];
  return inspectName(s);
}
route('POST', '/api/apps/inspect', (c) => ({ ok: true, candidates: inspectInput(c.p('input')).map((x) => outCand(x, c.lang)) }));
route('POST', '/api/apps/custom', (c) => {
  const p = c.p('path').trim(), state = c.p('state');
  if (['follow', 'direct', 'pin', 'auto'].indexOf(state) < 0) throw E('E_INVALID', 'e.badState');
  if (!(p[0] === '/' || isWinPath(p))) throw E('E_INVALID', 'e.appRelative');                              // 只收 inspect 返回的绝对路径 (名称要先 inspect)
  const cand = inspectInput(p)[0];
  if (!cand.valid) throw E('E_INVALID', cand._k);
  if (cand.exists) throw E('E_INVALID', 'e.appExists');
  const a = { name: cand.name, state, kind: cand.kind, flag: 'ack', known: false, rec: '', group: '自定义', custom: true, path: cand.path, _noIcon: cand.kind !== 'app', _iconAt: now() + D(2000 + mulberry(hash('appicon|' + cand.name))() * 4000) };
  M.apps.push(a); oplog('dashboard', 'apps.custom.add', kv({ name: a.name, kind: cand.kind, state }));
  return { ok: true, job: newJob('apps-custom-add', ['js.saveApp', 'js.setPolicy', 'js.regen', 'js.hot'], 3000, { outage: false, msg: 'jd.appAdd', rollback: () => { M.apps = M.apps.filter((x) => x !== a); } }) };
});
route('POST', '/api/apps/custom/delete', (c) => {
  const name = c.p('name'); if (!name || name.length > 80 || /[|"\\\/\x00-\x1f]/.test(name)) throw E('E_INVALID', 'e.badName');
  const a = M.apps.filter((x) => x.name === name && x.custom)[0]; if (!a) throw E('E_NOT_FOUND', 'e.noCustomApp');           // 内置应用同样是「找不到这个自定义软件」
  const idx = M.apps.indexOf(a); M.apps.splice(idx, 1); oplog('dashboard', 'apps.custom.delete', kv({ name }));
  return { ok: true, job: newJob('apps-custom-delete', SITE_STEPS, 2600, { outage: false, msg: 'jd.appDel', rollback: () => { M.apps.splice(idx, 0, a); } }) };
});

/* ---- 网站规则: 查看 / 添加 / 修改域名, 一键重置 (docs/API.md「网站规则」; 行为对照 lib/sites.sh) ----
 * 用户的改动 M.siteMods[条目 id] = {added:[…], removed:[…]} 只存在内存里 (真实后端存在 site-domains.tsv, 云端内容更新不会覆盖它); 目录里的 domains 是「系统域名 - 已删除 + 已添加」。
 * 输入先规范化 (去首尾空白 / 转小写 / 去结尾的点) 再校验; 每个条目最多 300 个自己添加的域名, 全部条目合计最多 2000 条改动。 */
const hasOwn = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
const siteMod = (id) => { const m = hasOwn(M.siteMods, id) ? M.siteMods[id] : null; return m && (m.added.length || m.removed.length) ? m : null; };
const effDomains = (e) => { const m = siteMod(e.id); return m ? e.domains.filter((d) => m.removed.indexOf(d) < 0).concat(m.added) : e.domains.slice(); };
const svcList = () => CAT.entries.concat(M.custom.map((c) => ({ id: 'rs-' + c.tag, tag: 'svc-rs-' + c.tag })));       // 每个条目一个策略选择器 svc-<id> (含用户添加的规则集)
/* 目录 + 用户添加的自定义规则集 (lib/config.sh 同样把它们并进 catalog, group=custom); 条目带 modified 与「生效后」的 domains; policy = default = 条目的默认策略 */
function catalogNow() {
  const cu = M.custom.map((c) => ({ id: 'rs-' + c.tag, tag: 'svc-rs-' + c.tag, name: c.name, name_en: c.name, group: 'custom', default: c.policy, policy: c.policy, desc: S['rs.customDesc'][0], desc_en: S['rs.customDesc'][1], domains: [], rulesets: ['custom-' + c.tag], cidrs: 0, modified: false, custom: true }));
  const has = cu.length > 0;
  return { schema: 3, groups: has ? Object.assign({}, CAT.groups, { custom: S['grp.custom'][0] }) : CAT.groups, groups_en: has ? Object.assign({}, CAT.groups_en, { custom: S['grp.custom'][1] }) : CAT.groups_en,
    order: has ? CAT.order.concat(['custom']) : CAT.order,
    entries: CAT.entries.map((e) => ({ id: e.id, tag: e.tag, name: e.name, name_en: e.name_en, group: e.group, default: e.default, policy: e.default, desc: e.desc, desc_en: e.desc_en, domains: effDomains(e), rulesets: e.rulesets, cidrs: e.cidrs, modified: !!siteMod(e.id) })).concat(cu) };
}
/* 域名规范化 + 校验 (网站域名规则; DNS 自定义解析 hosts 也用它): 小写字母 / 数字 / 连字符 + 点, 每段 <= 63, 总长 <= 253, 至少两段, 不含通配符 / 空格 / 协议 / 路径; domainErr 返回错误文案的 key (空串 = 合法) */
const domNorm = (d) => String(d).trim().toLowerCase().replace(/\.$/, '');
function domainErr(d) {
  if (!d) return 'e.domEmpty';
  if (/\s/.test(d)) return 'e.domSpace';
  if (d.indexOf('://') >= 0) return 'e.domProto';
  if (d.indexOf('*') >= 0) return 'e.domWild';
  if (/[\/?#:@\\]/.test(d)) return 'e.domPath';
  if (!/^[a-z0-9.-]+$/.test(d)) return 'e.domChars';
  if (d.length > 253) return 'e.domLen';
  const lb = d.split('.');
  if (lb.some((x) => !x || x[0] === '-' || x[x.length - 1] === '-')) return 'e.domLabel';
  if (lb.some((x) => x.length > 63)) return 'e.domLabelLen';
  if (lb.length < 2) return 'e.domNoDot';
  if (/^\d+$/.test(lb[lb.length - 1])) return 'e.domIp';
  return '';
}
const SITE_STEPS = ['js.saveChg', 'js.regen', 'js.hot'], SITE_MAX_ADDED = 300, SITE_MAX_TOTAL = 2000;
const snapSites = () => { const s = clone(M.siteMods); return () => { M.siteMods = s; }; };
const siteEditCount = () => Object.keys(M.siteMods).reduce((n, k) => n + M.siteMods[k].added.length + M.siteMods[k].removed.length, 0);
function siteEntryOf(id) {                                                 // 目录条目; 用户添加的规则集条目 (rs-*) 没有可编辑的域名 (custom:true)
  const e = CAT.entries.filter((x) => x.id === id)[0]; if (e) return e;
  const cs = M.custom.filter((x) => 'rs-' + x.tag === id)[0];
  return cs ? { id, name: cs.name, name_en: cs.name, domains: [], rulesets: ['custom-' + cs.tag], cidrs: 0, default: cs.policy, custom: true } : null;
}
function siteIdArg(c) { const id = c.p('id').trim(); if (!/^[a-z0-9-]+$/.test(id)) throw E('E_INVALID', 'e.entryId'); return id; }
/* 在副本上执行一次编辑 (add | remove | restore | update), 失败抛 E_INVALID, 成功返回新的 {added, removed}; update = 删除旧的再添加新的 (新的排在最后) */
function siteEdit(e, cur, action, d, nw) {
  const bad = (k) => { throw E('E_INVALID', k); }, eff = () => e.domains.filter((x) => cur.removed.indexOf(x) < 0).concat(cur.added);
  const add = (x) => {
    if (eff().indexOf(x) >= 0) bad('e.domDup');
    if (e.domains.indexOf(x) >= 0) cur.removed = cur.removed.filter((y) => y !== x);                 // 把之前删掉的系统域名再添加 = 恢复
    else { if (cur.added.length >= SITE_MAX_ADDED) bad('e.domMaxEntry'); cur.added.push(x); }
  };
  const remove = (x) => {
    if (cur.added.indexOf(x) >= 0) cur.added = cur.added.filter((y) => y !== x);                       // 用户添加的域名: 直接删除
    else if (e.domains.indexOf(x) >= 0) { if (cur.removed.indexOf(x) >= 0) bad('e.domGone'); cur.removed.push(x); }       // 系统域名: 记为「已删除」(可以 restore)
    else bad('e.domNone');
  };
  if (action === 'add') add(d);
  else if (action === 'remove') remove(d);
  else if (action === 'restore') { if (cur.removed.indexOf(d) < 0) bad('e.domNotRemoved'); cur.removed = cur.removed.filter((y) => y !== d); }
  else { const k = domainErr(nw); if (k) bad(k); if (nw === d) bad('e.domSame'); remove(d); add(nw); }
  return cur;
}
route('GET', '/api/sites/domains', (c) => {
  const e = siteEntryOf(siteIdArg(c)); if (!e) throw E('E_NOT_FOUND', 'e.noEntry');
  const m = siteMod(e.id);
  return { ok: true, id: e.id, name: c.lang === 'en' ? e.name_en : e.name, modified: !!m, system: e.domains.slice(),
    domains: e.domains.filter((d) => !m || m.removed.indexOf(d) < 0).map((d) => ({ domain: d, source: 'system' })).concat(m ? m.added.map((d) => ({ domain: d, source: 'added' })) : []),
    removed: m ? m.removed.slice() : [], rulesets: e.rulesets.slice(), cidrs: e.cidrs, policy: e.default };
});
route('POST', '/api/sites/domains', (c) => {
  const id = siteIdArg(c), action = c.p('action'), d = domNorm(c.p('domain')), nw = domNorm(c.p('new'));
  if (['add', 'remove', 'update', 'restore'].indexOf(action) < 0) throw E('E_INVALID', 'e.badAction');
  const e = siteEntryOf(id); if (!e) throw E('E_INVALID', 'e.noEntry');                                    // lib/sites.sh: 所有失败都是 E_INVALID (只有 GET / reset 的未知条目是 E_NOT_FOUND)
  if (e.custom) throw E('E_INVALID', 'e.entryRs');
  const k = domainErr(d); if (k) throw E('E_INVALID', k);
  if ((action === 'add' || action === 'update') && siteEditCount() >= SITE_MAX_TOTAL) throw E('E_INVALID', 'e.domMaxTotal');
  const undo = snapSites(), cur = siteEdit(e, clone(hasOwn(M.siteMods, id) ? M.siteMods[id] : { added: [], removed: [] }), action, d, nw);
  if (cur.added.length || cur.removed.length) M.siteMods[id] = cur; else delete M.siteMods[id];
  oplog('dashboard', 'sites.domain', kv(Object.assign({ id, action, domain: d }, action === 'update' ? { new: nw } : {})));
  return { ok: true, job: newJob('sites-domains', SITE_STEPS, 2600, { outage: false, rollback: undo, msg: 'jd.siteDom' }) };         // 重新生成配置, 热生效 (核心不重启)
});
route('POST', '/api/sites/domains/reset', (c) => {
  const id = siteIdArg(c), e = siteEntryOf(id); if (!e) throw E('E_NOT_FOUND', 'e.noEntry');
  if (e.custom) throw E('E_INVALID', 'e.entryRs');
  const undo = snapSites(); delete M.siteMods[id];
  oplog('dashboard', 'sites.reset', kv({ id }));
  return { ok: true, job: newJob('sites-reset', SITE_STEPS, 2600, { outage: false, rollback: undo, msg: 'jd.siteReset' }) };
});

/* ---- 服务器 / 订阅 / 证书 / 重启 / 任务 ---- */
const subNameOk = (n) => /^[A-Za-z0-9._ -]{1,40}$/.test(n);
const SRV_TYPES = ['trojan', 'http', 'socks', 'tuic', 'hysteria2', 'vless', 'vmess', 'shadowsocks', 'anytls'], RESERVED = ['direct', 'AUTO', 'PIN', 'Global', 'Final'];
/* 与 lib/servers.sh 的 srv_check_line 同样的闸门; 先对副本「干跑」, 有可导入的才提交 */
function importJsonl(lang, sub, mode, body) {
  const out = { added: 0, replaced: 0, removed: 0, errors: [] }; let work = clone(M.servers);
  if (mode === 'replace' && sub) { const n = work.length; work = work.filter((s) => s.sub !== sub); out.removed = n - work.length; }
  body.split('\n').forEach((line, i) => {
    if (!line.trim()) return;
    const bad = () => { out.errors.push(tr(lang, 'e.badLine', { n: i + 1 })); };
    let j; try { j = JSON.parse(line); } catch (e) { return bad(); }
    const ob = j && typeof j === 'object' ? j.outbound : null;
    if (!ob || typeof ob !== 'object' || ['pin', 'auto', 'dl', 'off'].indexOf(j.role) < 0 || (j.sub && !subNameOk(String(j.sub))) || SRV_TYPES.indexOf(ob.type) < 0 || typeof ob.tag !== 'string' || !/^[^"\\\x00-\x1f]{1,64}$/.test(ob.tag)
      || !ob.server || !ob.server_port || RESERVED.indexOf(ob.tag) >= 0 || /^svc-/.test(ob.tag) || /^enana-official-/.test(ob.tag) || 'detour' in ob) return bad();
    const rec = { tag: ob.tag, type: ob.type, server: String(ob.server), port: +ob.server_port, role: j.role, sub: sub || j.sub || '' }, k = work.findIndex((s) => s.tag === ob.tag);
    if (k >= 0) { work[k] = rec; out.replaced++; } else { work.push(rec); out.added++; }
  });
  if (out.added + out.replaced === 0) throw E('E_INVALID', 'e.noImport', null, { errors: out.errors });
  M.servers = work; return out;
}
route('POST', '/api/servers/import', (c) => {
  const sub = c.p('sub'), mode = c.p('mode') === 'replace' ? 'replace' : 'merge';
  if (sub && !subNameOk(sub)) throw E('E_INVALID', 'e.badSubName');
  if (!c.body.trim()) throw E('E_INVALID', 'e.noBody');
  const undo = snapshot(), sb = M.subs.filter((x) => x.name === sub)[0], refresh = !!(sb && mode === 'replace' && (sb.updated > 0 || sb.count > 0)), out = importJsonl(c.lang, sub, mode, c.body);
  if (sb) {
    sb.count = M.servers.filter((s) => s.sub === sub).length; sb.updated = sec();
    const iv = num(c.p('interval'), 0), us = num(c.p('used'), -1), to = num(c.p('total'), 0), ex = num(c.p('expire'), 0);
    if (iv > 0) sb.interval = iv; if (to > 0) sb.usage = { used: Math.max(0, us), total: to, expire: ex };
  }
  if (refresh) oplog('dashboard', 'sub.refresh', kv({ sub, count: sb.count })); else oplog('dashboard', 'servers.import', kv({ sub, count: out.added + out.replaced, mode }));
  out.job = newJob('servers-import', APPLY, 4200, { done: applyNow, rollback: undo, msg: 'jd.import' });
  return Object.assign({ ok: true }, out);
});
route('POST', '/api/servers/delete', (c) => {
  const tag = c.p('tag'), cur = M.servers.filter((s) => s.tag === tag)[0]; if (!cur) throw E('E_NOT_FOUND', 'e.noServer');
  if (cur.official) throw E('E_INVALID', 'e.officialDel');
  const undo = snapshot(); M.servers = M.servers.filter((s) => s.tag !== tag); oplog('dashboard', 'servers.delete', kv({ tag }));
  return { ok: true, job: newJob('servers-delete', APPLY, 3600, { done: applyNow, rollback: undo, msg: 'jd.delete' }) };
});
route('POST', '/api/servers/role', (c) => {
  const tag = c.p('tag'), role = c.p('role'), s = M.servers.filter((x) => x.tag === tag)[0];
  if (!s) throw E('E_NOT_FOUND', 'e.noServer');
  if (['pin', 'auto', 'off', 'dl'].indexOf(role) < 0) throw E('E_INVALID', 'e.badRole');
  if (role === 'dl' && s.type !== 'http' && s.type !== 'socks') throw E('E_INVALID', 'e.dlOnly');
  const undo = snapshot(); s.role = role; oplog('dashboard', 'servers.role', kv({ tag, role }));
  return { ok: true, job: newJob('servers-role', APPLY, 3600, { done: applyNow, rollback: undo, msg: 'jd.role' }) };
});
route('POST', '/api/cert', (c) => {
  const name = c.p('name');
  if (!/^[A-Za-z0-9._-]{1,40}$/.test(name)) throw E('E_INVALID', 'e.badCertName');
  if (!c.body.trim() || Buffer.byteLength(c.body) > 16384) throw E('E_INVALID', 'e.certSize');
  if (!/-----BEGIN CERTIFICATE-----[\s\S]+-----END CERTIFICATE-----/.test(c.body)) throw E('E_INVALID', 'e.badCert');
  return { ok: true, ref: '@CERTS@/' + name + '.crt' };
});
/* 与 lib/servers.sh 的 sub_url_ok 一致: 只允许公网的 http(s) */
function subUrlOk(u) {
  if (!/^https?:\/\//i.test(u)) return false;
  const h = u.replace(/^[a-z]+:\/\//i, '').split('/')[0].split('?')[0].split('@').pop().split(':')[0].toLowerCase();
  return h.indexOf('.') > 0 && !(/\.local$/.test(h) || /^(127|10|0)\./.test(h) || /^192\.168\./.test(h) || /^169\.254\./.test(h) || /^172\.(1[6-9]|2\d|3[01])\./.test(h) || u.indexOf('//[') >= 0);
}
route('POST', '/api/sub/fetch', async (c) => {
  const ua = c.p('ua') || 'auto', name = c.p('name'), url = name ? 'https://sub.example.com/sub/' + name : c.body.trim();
  if (name && !M.subs.some((x) => x.name === name)) throw E('E_NOT_FOUND', 'e.noSub');
  if (!subUrlOk(url)) throw E('E_INVALID', 'e.badSubUrl');
  if (/\/fail/.test(url)) { await sleep(500); throw E('E_NETWORK', 'e.subFetch'); }
  await sleep(/\/slow/.test(url) ? 4000 : 700);
  return new Raw(subBody(url, ua, name), 'text/plain; charset=utf-8', { 'X-Subscription-Userinfo': 'upload=0; download=1239144755; total=322122547200; expire=' + (sec() + 45 * 86400), 'X-Profile-Update-Interval': '12' });
});
route('POST', '/api/sub/save', (c) => {
  const name = c.p('name'), url = c.body.replace(/[\r\n ]/g, '');
  if (!subNameOk(name)) throw E('E_INVALID', 'e.badSubName');
  if (!subUrlOk(url)) throw E('E_INVALID', 'e.badSubUrl');
  const host = url.replace(/^[a-z]+:\/\//i, '').split(/[\/?]/)[0].split('@').pop().split(':')[0].toLowerCase(), ex = M.subs.filter((x) => x.name === name)[0];
  if (!ex) M.subs.push({ name, host, updated: 0, count: 0, interval: 12, usage: null }); else ex.host = host;
  M.subUrls[name] = url;                                                   // 订阅链接 (可能带令牌): 只有 GET /api/sub/url (需 sudo) 和 GET /api/export (需 sudo) 会返回
  oplog('dashboard', 'sub.save', kv({ name, host })); return { ok: true };
});
route('POST', '/api/sub/delete', (c) => {
  const name = c.p('name'); if (!subNameOk(name)) throw E('E_INVALID', 'e.badSubName');
  if (!M.subs.some((x) => x.name === name)) throw E('E_NOT_FOUND', 'e.noSub');
  const undo = snapshot(); M.subs = M.subs.filter((x) => x.name !== name); M.servers = M.servers.filter((s) => s.sub !== name); delete M.subUrls[name]; oplog('dashboard', 'sub.delete', kv({ name }));
  return { ok: true, job: newJob('sub-delete', APPLY, 3600, { done: applyNow, rollback: undo, msg: 'jd.subdel' }) };
});
route('POST', '/api/restart', () => {
  oplog('dashboard', 'restart', '');
  return { ok: true, job: newJob('restart', ['js.restart', 'js.waitSvc'], 3500, { done: () => { applyNow(); M.clashDown = false; M.env.service = true; }, msg: 'jd.restart' }) };   // 重启也会把「已停止」的核心拉起来
});
route('GET', '/api/job', (c) => {
  const id = c.p('id'); if (!id || /[^A-Za-z0-9_-]/.test(id)) throw E('E_INVALID', 'e.badJobId');
  const j = M.jobs[id]; if (!j) throw E('E_NOT_FOUND', 'e.noJob');
  return jobView(j, c.lang);
});
/* 旧接口 (docs/API.md 里没有, 当前 ui/app.js 的「日志」弹窗还在用): 最近 n 行代理日志的纯文本 */
route('GET', '/api/log', (c) => new Raw((M.L.proxy[dayOf(now())] || []).slice(-Math.min(num(c.p('n'), 200), 2000)).map((r) => r.ts + ' ' + r.level + ' ' + r.msg).join('\n') + '\n'));

/* ---- 规则库 ---- */
const DL_STEPS = ['js.prep', 'js.dlRules', 'js.applyRules', 'js.finish'];
route('GET', '/api/rules', () => {
  const sets = RULESETS.map((r) => { const s = M.rs.filter((x) => x.tag === r.tag)[0];
    return { tag: r.tag, name: r.name, name_en: r.name_en, desc: r.desc, desc_en: r.desc_en, repo: r.repo, present: s.present, bytes: s.bytes, updated: s.updated, enabled: s.enabled, essential: r.essential, custom: false }; });
  M.custom.forEach((c) => sets.push({ tag: c.tag, name: c.name, name_en: c.name, desc: S['rs.customDesc'][0], desc_en: S['rs.customDesc'][1], repo: S['rs.customRepo'][0], present: true, bytes: c.bytes, updated: c.updated,
    enabled: true, essential: false, custom: true, policy: c.policy }));
  return { ok: true, sets, updated: M.rulesUpdated };
});
route('POST', '/api/rules/toggle', (c) => {
  const tag = c.p('tag'), on = c.p('on'), def = RULESETS.filter((r) => r.tag === tag)[0];
  if (on !== '0' && on !== '1') throw E('E_INVALID', 'e.badBool');
  if (!def) { if (M.custom.some((x) => x.tag === tag)) throw E('E_INVALID', 'e.ruleCustom'); throw E('E_NOT_FOUND', 'e.noRule'); }
  if (def.essential && on === '0') throw E('E_INVALID', 'e.ruleEssential');
  const s = M.rs.filter((x) => x.tag === tag)[0], need = on === '1' && !s.present; s.enabled = on === '1';
  oplog('dashboard', 'rules.toggle', kv({ tag, on }));
  return { ok: true, job: newJob('rules-toggle', need ? DL_STEPS : APPLY, need ? 3800 : 3000, { msg: 'jd.toggle', done: () => { if (s.enabled && !s.present) { s.present = true; s.bytes = ruleSize(tag); s.updated = sec(); } } }) };
});
route('POST', '/api/rules/custom/add', (c) => {
  const name = c.p('name'), url = c.p('url'), policy = c.p('policy') || 'auto', tag = name.toLowerCase();
  if (!/^[A-Za-z0-9._-]{1,30}$/.test(name)) throw E('E_INVALID', 'e.badRuleName');
  if (!subUrlOk(url) || !/\.srs$/i.test(url.split('#')[0].split('?')[0])) throw E('E_INVALID', 'e.badRuleUrl');
  if (['pin', 'auto', 'direct'].indexOf(policy) < 0) throw E('E_INVALID', 'e.badPolicy');
  if (M.custom.some((x) => x.tag === tag) || M.pendingNames[tag] || RULESETS.some((r) => r.tag === 'geosite-' + tag || r.tag === 'geoip-' + tag)) throw E('E_INVALID', 'e.ruleDup');
  const bad = /fail/i.test(url.replace(/^https?:\/\//i, '').split('/')[0]);                  // 主机名里带 fail: 模拟下载失败
  M.pendingNames[tag] = 1; oplog('dashboard', 'rules.custom.add', kv({ name, policy }));
  return { ok: true, job: newJob('rules-custom-add', ['js.dlCustom', 'js.validateSrs', 'js.apply', 'js.ready'], 4000, { msg: 'jd.customAdd', fail: bad, failAt: 0.2, failMsg: 'e.ruleDl', noFail: bad,
    rollback: () => { delete M.pendingNames[tag]; oplog('dashboard', 'rules.custom.add', kv({ name, code: 'E_NETWORK' }), 'error'); },
    done: () => { delete M.pendingNames[tag]; M.custom.push({ tag, name, policy, url, bytes: 4200 + hash(tag) % 30000, updated: sec() }); M.svc['rs-' + tag] = POL[policy]; } }) };
});
route('POST', '/api/rules/custom/delete', (c) => {
  const tag = c.p('tag'); if (!tag) throw E('E_INVALID', 'e.noRule');
  if (RULESETS.some((r) => r.tag === tag)) throw E('E_INVALID', 'e.ruleNotCustom');
  const cs = M.custom.filter((x) => x.tag === tag)[0]; if (!cs) throw E('E_NOT_FOUND', 'e.noRule');
  M.custom = M.custom.filter((x) => x !== cs); delete M.svc['rs-' + tag]; oplog('dashboard', 'rules.custom.delete', kv({ tag }));
  return { ok: true, job: newJob('rules-custom-delete', APPLY, 3000, { msg: 'jd.customDel' }) };
});
route('POST', '/api/update-rules', () => ({ ok: true, job: newJob('update-rules', DL_STEPS, 4500, { msg: 'jd.rules',
  rollback: () => oplog('dashboard', 'rules.update', kv({ changed: 0, failed: 3 }), 'error'),
  done: () => {
    const t = sec(); let changed = 0;
    M.rs.forEach((s) => { if (s.enabled) { if (!s.present || hash(s.tag + t) % 5 === 0) changed++; s.present = true; s.bytes = ruleSize(s.tag) + hash(s.tag + t) % 400; s.updated = t; } });
    M.custom.forEach((x) => { x.updated = t; }); M.rulesUpdated = t; oplog('dashboard', 'rules.update', kv({ changed, failed: 0 }));
    return { vars: { n: changed }, result: { changed, failed: 0 } };
  } }) }));

/* ---- DNS ---- */
function dnsName(scope, id, custom, lang) {
  if (id === 'custom') return tr(lang, 'dns.custom', { host: custom.replace(/^[a-z]+:\/\//i, '').split('/')[0] });
  const p = dnsPreset(scope, id); return p ? (lang === 'en' ? p.name_en : p.name) : id;
}
/* 结构化的流程 (按生效顺序): id = hosts | ads | direct | cn | proxy | global; match = hosts | geosite-ads | direct | geosite-cn | proxy | all; server = 预设 id | custom | reject | hosts | proxy; via = direct | auto | pin | none; detail 按语言翻译 (文案同真实辅助服务)。
 * hosts 行只在有自定义解析时出现 (另带 count); ads 行只在开着「屏蔽广告」时出现; 其余几行总是有。 */
function dnsPipeline(lang) {
  const d = M.dns, out = [], both = (scope, id, cu) => ({ server_name: dnsName(scope, id, cu, 'zh'), server_name_en: dnsName(scope, id, cu, 'en') }), named = (k) => ({ server_name: tr('zh', k), server_name_en: tr('en', k) });
  if (M.hosts.length) out.push(Object.assign({ id: 'hosts', match: 'hosts', server: 'hosts' }, named('dns.hostsName'), { via: 'none', detail: tr(lang, 'dns.hosts'), count: M.hosts.length }));
  if (d.ads_block) out.push(Object.assign({ id: 'ads', match: 'geosite-ads', server: 'reject' }, named('dns.reject'), { via: 'none', detail: tr(lang, 'dns.ads') }));
  out.push(Object.assign({ id: 'direct', match: 'direct', server: d.cn }, both('cn', d.cn, d.cn_custom), { via: 'direct', detail: tr(lang, 'dns.direct') }));         // 直连的网站用国内 DNS 解析
  out.push(Object.assign({ id: 'cn', match: 'geosite-cn', server: d.cn }, both('cn', d.cn, d.cn_custom), { via: 'direct', detail: tr(lang, 'dns.cn') }));
  out.push(Object.assign({ id: 'proxy', match: 'proxy', server: 'proxy' }, named('dns.proxyName'), { via: d.via === 'PIN' ? 'pin' : 'auto', detail: tr(lang, 'dns.proxy') }));   // 经代理访问的网站: 域名直接交给代理服务器解析 (远端 DNS)
  if (d.leak_guard) out.push(Object.assign({ id: 'global', match: 'all', server: d.global }, both('global', d.global, d.global_custom), { via: d.via === 'PIN' ? 'pin' : 'auto', detail: tr(lang, 'dns.global') }));
  else out.push(Object.assign({ id: 'global', match: 'all', server: d.cn }, both('cn', d.cn, d.cn_custom), { via: 'direct', detail: tr(lang, 'dns.noleak') }));
  return out;
}
route('GET', '/api/dns', (c) => ({ ok: true, settings: clone(M.dns), hosts: clone(M.hosts), presets: DNS_PRESETS, pipeline: dnsPipeline(c.lang) }));
route('POST', '/api/dns', (c) => {
  const d = clone(M.dns), v = (n) => c.p(n);
  if (c.has('cn')) { if (!dnsPreset('cn', v('cn'))) throw E('E_INVALID', 'e.badDnsCn'); d.cn = v('cn'); }
  if (c.has('global')) { if (!dnsPreset('global', v('global'))) throw E('E_INVALID', 'e.badDnsGlobal'); d.global = v('global'); }
  if (c.has('cn_custom')) { if (v('cn_custom') && !dnsUrlOk(v('cn_custom'))) throw E('E_INVALID', 'e.badDnsUrlCn'); d.cn_custom = v('cn_custom'); }
  if (c.has('global_custom')) { if (v('global_custom') && !(dnsUrlOk(v('global_custom')) && v('global_custom') !== 'system')) throw E('E_INVALID', 'e.badDnsUrlGlobal'); d.global_custom = v('global_custom'); }
  if (c.has('via')) { if (['Global', 'PIN'].indexOf(v('via')) < 0) throw E('E_INVALID', 'e.badVia'); d.via = v('via'); }
  if (c.has('strategy')) { if (['prefer_ipv4', 'ipv4_only', 'prefer_ipv6', 'ipv6_only'].indexOf(v('strategy')) < 0) throw E('E_INVALID', 'e.badStrategy'); d.strategy = v('strategy'); }
  ['leak_guard', 'ads_block'].forEach((k) => { if (c.has(k)) { if (v(k) !== '0' && v(k) !== '1') throw E('E_INVALID', 'e.badBool'); d[k] = v(k) === '1'; } });
  if (d.cn === 'custom' && !dnsUrlOk(d.cn_custom)) throw E('E_INVALID', 'e.needDnsCn');
  if (d.global === 'custom' && !(dnsUrlOk(d.global_custom) && d.global_custom !== 'system')) throw E('E_INVALID', 'e.needDnsGlobal');
  M.dns = d;
  const ads = M.rs.filter((s) => s.tag === 'geosite-ads')[0], need = !!ads && d.ads_block && !ads.present;                  // 开启「屏蔽广告」才下载广告规则集
  if (ads) ads.enabled = d.ads_block;
  oplog('dashboard', 'dns.set', kv({ cn: d.cn, global: d.global, via: d.via, strategy: d.strategy, leak_guard: d.leak_guard ? 1 : 0, ads_block: d.ads_block ? 1 : 0 }));
  return { ok: true, job: newJob('dns-set', need ? ['js.prep', 'js.dlRules', 'js.apply', 'js.ready'] : APPLY, need ? 4200 : 3600, { msg: 'jd.dns', done: () => { if (need && ads.enabled && !ads.present) { ads.present = true; ads.bytes = ruleSize(ads.tag); ads.updated = sec(); } } }) };
});
/* 自定义解析 (hosts): 域名同网站域名规则 (规范化后校验), IP 支持 IPv4 (不带前导零) / IPv6 (小写), 最多 200 条; 写入后重新生成配置 (任务); 行为对照 lib/dns.sh 的 dns_hosts_edit */
const HOSTS_MAX = 200, IP4_RE = /^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$/;
const hostIpOk = (ip) => ip.length <= 45 && /^[0-9a-f:.]+$/.test(ip) && (ip.indexOf(':') >= 0 ? net.isIPv6(ip) : IP4_RE.test(ip) && net.isIPv4(ip));
const snapHosts = () => { const h = clone(M.hosts); return () => { M.hosts = h; }; };
route('POST', '/api/dns/hosts', (c) => {
  const action = c.p('action'), d = domNorm(c.p('domain')), ip = c.p('ip').trim().toLowerCase(), nd = domNorm(c.p('new_domain'));
  if (['add', 'update', 'remove'].indexOf(action) < 0) throw E('E_INVALID', 'e.badAction');
  const k = domainErr(d); if (k) throw E('E_INVALID', k);
  const undo = snapHosts(), has = M.hosts.filter((h) => h.domain === d)[0];
  if (action === 'add') {
    if (has) throw E('E_INVALID', 'e.hostDup');
    if (!hostIpOk(ip)) throw E('E_INVALID', 'e.hostIp');
    if (M.hosts.length >= HOSTS_MAX) throw E('E_INVALID', 'e.hostMax');
    M.hosts.push({ domain: d, ip });
  } else if (!has) throw E('E_INVALID', 'e.hostNone');
  else if (action === 'remove') M.hosts = M.hosts.filter((h) => h !== has);
  else {                                                                   // update: 改 IP 和 / 或把 domain 改名成 new_domain (只改域名时沿用原来的 IP; 什么都不改也算成功)
    const newd = nd || d, newip = ip || has.ip, k2 = domainErr(newd); if (k2) throw E('E_INVALID', k2);
    if (!hostIpOk(newip)) throw E('E_INVALID', 'e.hostIp');
    if (newd !== d && M.hosts.some((h) => h.domain === newd)) throw E('E_INVALID', 'e.hostNewDup');
    has.domain = newd; has.ip = newip;
  }
  oplog('dashboard', 'dns.hosts', kv(Object.assign({ action, domain: d }, action === 'update' && nd && nd !== d ? { new: nd } : {})));
  return { ok: true, job: newJob('dns-hosts', APPLY, 3200, { msg: 'jd.hosts', rollback: undo }) };
});
route('POST', '/api/dns/hosts/reset', () => {
  const n = M.hosts.length, undo = snapHosts(); M.hosts = []; oplog('dashboard', 'dns.hosts.reset', kv({ count: n }));
  return { ok: true, job: newJob('dns-hosts-reset', APPLY, 3000, { msg: 'jd.hosts', rollback: undo }) };
});
/* DNS 服务器测速: 每个非自定义预设一条 {id, ms}; 国内预设直连测 (8-60 ms), 海外预设经自动线路测 (40-300 ms); 海外的 adguard 永远不通 (ms:null); 没有节点时海外预设全部不通。同一个预设每次的结果相近 (±3 ms) */
function benchResult() {
  const hasN = nodesOf(M.servers).length > 0, seq = (M.benchSeq = (M.benchSeq || 0) + 1), jit = (id) => hash(id + '#' + seq) % 7 - 3, one = (sc, p) => ({ id: p.id, ms: sc === 'cn' ? Math.min(60, Math.max(8, 8 + hash('bench|' + p.id) % 53 + jit(p.id))) : (!hasN || p.id === 'adguard' ? null : Math.min(300, Math.max(40, 40 + hash('bench|' + p.id) % 261 + jit(p.id)))) });
  return { cn: DNS_PRESETS.cn.filter((p) => p.id !== 'custom').map((p) => one('cn', p)), global: DNS_PRESETS.global.filter((p) => p.id !== 'custom').map((p) => one('global', p)), via: hasN ? (M.dns.via === 'PIN' ? 'PIN' : 'Global') : 'direct' };       // via = 海外预设实际经过的线路 (lib/dns.sh 同样带这个字段; 没有节点时是 direct)
}
route('POST', '/api/dns/bench', () => {
  oplog('dashboard', 'dns.bench', '');
  return { ok: true, job: newJob('dns-bench', ['js.dnsBenchCn', 'js.dnsBenchGlobal', 'js.finish'], 6500, { outage: false, msg: 'jd.dnsBench', done: () => ({ result: benchResult() }) }) };
});
route('POST', '/api/dns/test', async (c) => {
  const name = c.p('name').trim().replace(/\.$/, '').toLowerCase();
  if (!name || name.length > 253 || !/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$/.test(name)) throw E('E_INVALID', 'e.badHost');
  const hh = M.hosts.filter((h) => h.domain === name)[0];                  // 自定义解析 (hosts) 优先: 直接返回你写的 IP, 不问任何 DNS 服务器
  if (hh) { const ms = 1 + hash(name) % 3; await sleep(ms); oplog('dashboard', 'dns.test', kv({ name, ms })); return { ok: true, name, answers: [hh.ip], ms, source: 'hosts' }; }
  if (name === 'fail.example.com') { await sleep(1200); oplog('dashboard', 'dns.test', kv({ name, code: 'E_NETWORK' }), 'error'); throw E('E_NETWORK', 'e.dnsFail'); }
  const ms = name === 'slow.example.com' ? 880 + hash(name) % 40 : 8 + hash(name) % 52, answers = fakeAnswers(name, false);
  await sleep(ms); oplog('dashboard', 'dns.test', kv({ name, ms })); return { ok: true, name, answers, ms, source: 'dns' };
});

/* ---- 日志 ---- */
const logArgs = (c) => {
  const type = c.p('type') || 'ops', day = c.p('day') || dayOf(now());
  if (['ops', 'access', 'proxy'].indexOf(type) < 0) throw E('E_INVALID', 'e.logType');
  if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) throw E('E_INVALID', 'e.logDay');
  return { type, day };
};
route('GET', '/api/logs', (c) => {
  const a = logArgs(c), f = c.p('f'), r = logQuery(a.type, a.day, c.p('q'), Math.min(Math.max(num(c.p('limit'), 500), 1), 2000), Math.max(num(c.p('offset'), 0), 0), ['', 'error', 'warn', 'direct', 'proxy', 'dashboard', 'terminal', 'auto'].indexOf(f) >= 0 ? f : '');
  return { ok: true, days: logDays(), total: r.total, rows: r.rows, summary: r.summary };
});
/* 诊断导出: 和真实后端 (lib/logs.sh logs_bundle) 同一个格式 —— 自描述的文本, @@SECTION 分区, 见 docs/DIAGNOSTICS.md */
route('GET', '/api/logs/bundle', (c) => {
  const hours = c.p('hours') || '24', secs = (c.p('sections') || 'ops,access,proxy,snapshot').split(',');
  if (hours !== 'all' && !/^\d{1,3}$/.test(hours)) throw E('E_INVALID', 'e.logDay');
  if (secs.some((x) => ['ops', 'access', 'proxy', 'snapshot'].indexOf(x) < 0)) throw E('E_INVALID', 'e.logType');
  const since = hours === 'all' ? '' : tsOf(now() - Math.min(+hours, 720) * 3600e3), days = logDays().slice().reverse().filter((d) => !since || d >= since.slice(0, 10)), out = [];
  const sec = (name, fmt, lines) => { out.push('@@SECTION ' + name + ' format=' + fmt + ' rows=' + lines.length); lines.forEach((l) => out.push(l)); };
  const rowsOf = (t) => { const a = []; days.forEach((d) => (M.L[t][d] || []).filter(keepRow).forEach((r) => { if (!since || r.ts >= since) a.push(r); })); return a; };
  out.push('#ENANA-DIAGNOSTICS format=1', '#generated=' + tsOf(now()) + ' tz=+0800 app=enana version=' + M.upd.cur, '#range since="' + (since || 'beginning') + '" hours=' + hours + ' days=' + days.join(','),
    '#sections=meta' + (secs.indexOf('snapshot') >= 0 ? ',env,config,policy,servers,apps,probes,live' : '') + secs.filter((x) => x !== 'snapshot').map((x) => ',' + x).join(''), '#privacy=不含任何密码 / 令牌 / 服务器凭据; 服务器地址和系统用户名已打码 (演示数据)。');
  sec('meta', 'kv', ['app=enana', 'version=' + M.upd.cur, 'core=' + M.upd.coreCur, 'os=macOS 15.0', 'arch=arm64', 'proxy.enabled=' + (M.proxyOn ? 1 : 0), 'proxy.mode=' + M.proxyMode, 'settings.log_hours=' + M.logHours, 'settings.auto_sites=' + (M.autoSites ? 1 : 0), 'servers.total=' + M.servers.length]);
  if (secs.indexOf('snapshot') >= 0) {
    sec('env', 'kv', ['sysproxy.points_to_enana=' + (M.env.sysproxy ? 'yes' : 'no'), 'config.check=ok']);
    sec('config', 'text', ['(演示数据: 真实后端在这里给出脱敏后的路由规则 / 出站 / DNS)']);
    sec('policy', 'text', M.overrides.map((o) => 'site|' + o.value + '|' + o.state + '|' + (o.src || 'user')));
    sec('servers', 'tsv', ['tag\ttype\thost\tport\trole\tsub'].concat(M.servers.map((x) => [x.tag, x.type, 's***.example.com', x.port, x.role, x.sub || ''].join('\t'))));
    sec('apps', 'tsv', ['name\tstate\tflag\ttarget\tknown\trec\tgroup\tpath'].concat(M.apps.map((a) => [a.name, a.state, a.flag, a.target || '', a.known ? 'yes' : 'no', a.rec || '', a.group || '', '/Applications/' + a.name + '.app'].join('\t'))));
    sec('probes', 'tsv', ['probe\tvia\turl\thttp\tconnect_ms\ttotal_ms\tremote_ip\tnote', 'google_204\tproxy\thttp://www.gstatic.com/generate_204\t204\t12\t210\t203.0.113.7\tok']);
    sec('live', 'tsv', ['start\tnet\thost\tport\tapp\tchain\trule\tup\tdown']);
  }
  if (secs.indexOf('ops') >= 0) sec('ops', 'tsv', ['ts\twho\taction\tdetail\tresult'].concat(rowsOf('ops').map((r) => [r.ts, r.who, r.action, r.detail, r.result].join('\t'))));
  if (secs.indexOf('access') >= 0) sec('access', 'tsv', ['ts\tid\tnet\thost\tport\tapp\tuser\troute\tnode\treason\tresult\terr\tdur\tips\terrmsg\tpath'].concat(rowsOf('access').map((r) => [r.ts, r.id, r.net, r.host, r.port, r.app, '<user>', r.route, r.node, r.reason, r.err ? 'error' : 'ok', r.err, r.dur, r.ips, r.errmsg, r.path].join('\t'))));
  if (secs.indexOf('proxy') >= 0) sec('proxy', 'raw', rowsOf('proxy').map((r) => '+0800 ' + r.ts + ' ' + r.level + ' ' + r.msg));
  out.push('@@END');
  oplog('dashboard', 'logs.bundle', kv({ hours, sections: secs.join(','), bytes: out.join('\n').length }));
  return new Raw(out.join('\n') + '\n', 'text/plain; charset=utf-8', { 'Content-Disposition': 'attachment; filename="enana-diagnostics.txt"' });
});
route('GET', '/api/logs/export', (c) => { const a = logArgs(c); return new Raw(logExport(a.type, a.day)); });
route('POST', '/api/logs/clear', (c) => {
  const type = c.p('type'), before = c.p('before');
  if (['ops', 'access', 'proxy', 'all'].indexOf(type) < 0) throw E('E_INVALID', 'e.logType');
  if (before && !/^\d{4}-\d{2}-\d{2}$/.test(before)) throw E('E_INVALID', 'e.logDay');
  const freed = logClear(type, before); oplog('dashboard', 'logs.clear', kv(before ? { type, before } : { type }));
  return { ok: true, freed };
});

/* ---- 流量统计 (GET /api/stats?range=today|3d|7d|30d|90d): 以日期为种子的确定性数据 ----
 * 一天先生成 6 个整数分量 [直连↑ 直连↓ 固定出口↑ 固定出口↓ 自动线路↑ 自动线路↓], 再按「夜里安静、晚上最忙」的曲线分到 24 个小时, 固定出口 / 自动线路的分量再按节点分摊。
 * 全部用「累计取整」分摊, 所以 小时之和 = 当天, 天之和 = total, 节点之和 = 固定出口 + 自动线路, 各个范围 (today ⊂ 3d ⊂ 7d ...) 互相一致。
 * 今天只统计到当前这一小时 (这一小时按已过去的分钟数折算, 所以会慢慢变大); since 之前的日子全是 0。没有固定出口 / 自动线路的服务器时, 流量全部直连。 */
const STAT_DAYS = { today: 1, '3d': 3, '7d': 7, '30d': 30, '90d': 90 };
const STAT_HOUR = [0.30, 0.16, 0.09, 0.05, 0.04, 0.05, 0.10, 0.28, 0.62, 0.85, 1.0, 0.95, 0.78, 0.88, 1.0, 1.05, 1.1, 1.25, 1.55, 1.95, 2.3, 2.4, 1.95, 1.1];
const statSince = () => (M.stats === 'empty' ? '' : dayOf(addDays(now(), M.stats === 'short' ? -2 : -41)));
function apportion(total, w) {                                           // 把整数 total 按权重分成若干份: 累计取整, 总和一定等于 total
  const s = w.reduce((a, b) => a + b, 0) || 1; let acc = 0, prev = 0;
  return w.map((x, i) => { acc += x; const cum = i === w.length - 1 ? total : Math.round(total * acc / s), part = cum - prev; prev = cum; return part; });
}
function statDay(day, hasPin, hasAuto, cut, frac) {                      // cut >= 0: 今天, 只到 cut 这一小时 (该小时乘 frac)
  const r = mulberry(hash('stat|' + day)), wd = new Date(day + 'T12:00:00').getDay();
  let v = 0.35e9 + r() * r() * 7.5e9;                                    // 多数日子 0.4–3 GB, 偶尔很多
  if (wd === 0 || wd === 6) v *= 1.25;
  if (r() < 0.07) v *= 0.12;                                             // 偶尔很安静的一天
  if (r() < 0.04) v += 5e9 + r() * 8e9;                                  // 偶尔一次大下载
  const a = r(), b = r(), c = r(), sh = [0.40 + a * 0.14, hasPin ? 0.08 + b * 0.14 : 0, hasAuto ? 0.30 + c * 0.16 : 0], ss = sh[0] + sh[1] + sh[2];
  const dn = [0.90 + r() * 0.05, 0.74 + r() * 0.10, 0.92 + r() * 0.04];  // 各类里下载占的比例 (固定出口里 AI 的上传更多)
  const T = [], EXP = [0.6, 0.9, 1.3];                                   // 直连比较平, 固定出口 (工作 / AI) 偏白天, 自动线路 (视频 / 浏览) 偏晚上
  for (let k = 0; k < 3; k++) { const tot = v * sh[k] / ss; T.push(Math.round(tot * (1 - dn[k])), Math.round(tot * dn[k])); }
  const hours = Array.from({ length: 24 }, () => [0, 0, 0, 0, 0, 0]), c6 = [0, 0, 0, 0, 0, 0];
  for (let k = 0; k < 6; k++) {
    const e = EXP[k >> 1], w = STAT_HOUR.map((x, h) => Math.pow(x, e) * ((k >> 1) === 1 && h >= 9 && h <= 18 ? 1.6 : 1) * (0.55 + r()));
    apportion(T[k], w).forEach((x, h) => { hours[h][k] = cut < 0 || h < cut ? x : h === cut ? Math.floor(x * frac) : 0; });
  }
  hours.forEach((hh) => hh.forEach((x, k) => { c6[k] += x; }));
  return { c: c6, hours };
}
function statNodes(day, c, pin, auto) {                                  // 一天里固定出口 / 自动线路的流量按节点分摊: 固定出口基本走第一台, 自动线路里少数几台占大头, 还有几台几乎没用
  const out = [];
  const split = (tags, up, down, wt) => {
    if (!tags.length || !(up + down)) return;
    const w = tags.map((tag, i) => wt(i, tag, mulberry(hash('statn|' + day + '|' + tag))));
    if (!w.some((x) => x > 0)) w[0] = 1;
    const U = apportion(up, w), Dn = apportion(down, w);
    tags.forEach((tag, i) => { if (U[i] + Dn[i] > 0) out.push([tag, U[i], Dn[i]]); });
  };
  split(pin, c[2], c[3], (i, tag, r) => ([0.74, 0.2, 0.06][i] || 0.02) * (0.6 + r() * 0.8));
  split(auto, c[4], c[5], (i, tag, r) => { const idle = r() < 0.2, f = 0.2 + 1.6 * r(); return idle ? 0 : Math.pow(mulberry(hash(tag + '#statw'))(), 3) * f; });
  return out;
}
function statsPayload(range) {
  const n = STAT_DAYS[range], t = now(), d = new Date(t), since = statSince(), today = dayOf(t), tot = [0, 0, 0, 0, 0, 0], nm = {}, series = [], days = [];
  const pin = M.servers.filter((s) => s.role === 'pin').map((s) => s.tag), auto = M.servers.filter((s) => s.role === 'auto').map((s) => s.tag);
  const row = (id, c) => ({ t: id, up: c[0] + c[2] + c[4], down: c[1] + c[3] + c[5], direct: c[0] + c[1], pin: c[2] + c[3], auto: c[4] + c[5] });
  for (let i = n - 1; i >= 0; i--) days.push(dayOf(addDays(t, -i)));
  days.forEach((day) => {
    const has = !!since && day >= since, m = has ? statDay(day, pin.length > 0, auto.length > 0, day === today ? d.getHours() : -1, (d.getMinutes() + 1) / 60) : { c: [0, 0, 0, 0, 0, 0], hours: Array.from({ length: 24 }, () => [0, 0, 0, 0, 0, 0]) };
    m.c.forEach((x, k) => { tot[k] += x; });
    if (range === 'today') m.hours.forEach((hh, i) => series.push(row(pad(i), hh))); else series.push(row(day, m.c));
    if (has) statNodes(day, m.c, pin, auto).forEach((x) => { const o = nm[x[0]] || (nm[x[0]] = [0, 0]); o[0] += x[1]; o[1] += x[2]; });
  });
  return { ok: true, range, granularity: range === 'today' ? 'hour' : 'day', from: days[0], to: today, since, retention_days: 92,
    total: { up: tot[0] + tot[2] + tot[4], down: tot[1] + tot[3] + tot[5] },
    routes: { direct: { up: tot[0], down: tot[1] }, pin: { up: tot[2], down: tot[3] }, auto: { up: tot[4], down: tot[5] } }, series,
    nodes: Object.keys(nm).map((tag) => ({ tag, up: nm[tag][0], down: nm[tag][1] })).sort((x, y) => (y.up + y.down) - (x.up + x.down) || (x.tag < y.tag ? -1 : 1)) };
}
route('GET', '/api/stats', (c) => {
  const range = c.p('range') || 'today';                                 // 缺省 = today (与 lib/api.sh 的 ep_stats 一致)
  if (!Object.prototype.hasOwnProperty.call(STAT_DAYS, range)) throw E('E_INVALID', 'e.badRange');
  return statsPayload(range);
});

/* ---- 更新 ---- */
function updPayload(lang, err) {
  const on = appAvail(), nz = on ? NOTES.zh : '', ne = on ? NOTES.en : '';
  return { ok: true, current: M.upd.cur, latest: latestApp(), available: on, checked: M.upd.checked, notes: lang === 'en' ? ne : nz, notes_zh: nz, notes_en: ne, url: 'https://example.com/enana/releases',
    error: err ? tr(lang, 'e.updCheck') : '', code: err ? 'E_NETWORK' : '', core: { current: M.upd.coreCur, latest: latestCore(), available: coreAvail() } };
}
route('GET', '/api/update/check', async (c) => {
  const force = c.p('force') === '1', stale = sec() - M.upd.checked >= 6 * 3600;
  if (force) await sleep(rnd(1000, 2000));
  if (M.upd.fail || c.failOnce) return updPayload(c.lang, true);           // 这次没查到: 其余字段是上次缓存的结果
  if (force || stale) M.upd.checked = sec();
  return updPayload(c.lang, false);
});
route('POST', '/api/update/apply', (c) => {
  const what = c.p('what'); if (what !== 'app' && what !== 'core') throw E('E_INVALID', 'e.updWhat');
  if (Object.keys(M.jobs).some((k) => /^update-(app|core)/.test(M.jobs[k].name) && M.jobs[k].state === 'running')) throw E('E_BUSY', 'e.updBusy');
  if (what === 'app' ? !appAvail() : !coreAvail()) throw E('E_INVALID', 'e.updLatest');
  if (what === 'app') {
    const v = latestApp(), id = newJob('update-app', ['js.updDl', 'js.updVerify', 'js.updReplace', 'js.updHelper'], 8600, { outage: false, msg: 'jd.updApp', rollback: () => { M.helperWin = null; },
      done: () => { M.upd.cur = v; M.helperWin = null; return { vars: { v } }; } }), j = M.jobs[id];
    M.helperWin = [j.start + j.dur * 0.65, j.start + j.dur];               // 辅助服务重启: 在任务最后约 3 秒里连不上 (新进程就绪时任务也结束, 版本号同时变)
    oplog('dashboard', 'update.apply', kv({ what, version: v })); return { ok: true, job: id };
  }
  const v = latestCore();
  oplog('dashboard', 'update.apply', kv({ what, version: v }));
  return { ok: true, job: newJob('update-core', ['js.coreDl', 'js.coreSha', 'js.coreCheck', 'js.coreSwap', 'js.apply', 'js.ready'], 7000, { outFrac: 5 / 7, msg: 'jd.updCore', done: () => { M.upd.coreCur = v; return { vars: { v } }; } }) };
});

/* ---- 本机 IP ---- */
const NETIP = {
  direct: { ok: true, ip: '198.51.100.42', country: 'CN', country_name: 'China', region: 'Guangdong', city: 'Shenzhen', isp: 'Example Net Broadband', asn: 'AS64496', source: 'ipwho.is' },
  pin: { ok: true, ip: '203.0.113.55', country: 'JP', country_name: 'Japan', region: 'Tokyo', city: 'Tokyo', isp: 'Example Net Hosting', asn: 'AS64497', source: 'ipwho.is' },
  global: { ok: true, ip: '203.0.113.77', country: 'SG', country_name: 'Singapore', region: 'Singapore', city: 'Singapore', isp: 'Example Net Cloud', asn: 'AS64498', source: 'ipwho.is' },
  pinLite: { ok: true, ip: '203.0.113.55', country: 'JP', country_name: 'Japan', region: '', city: '', isp: '', asn: '', source: 'cloudflare' },     // 只拿到 IP 与国家 (备用查询源)
  globalLite: { ok: true, ip: '203.0.113.91', country: 'US', country_name: 'United States', region: '', city: '', isp: '', asn: '', source: 'cloudflare' } };
const NET_STATES = ['normal', 'limited', 'blocked', 'unknown', 'unreachable', 'none', 'noservers'];
/* 场景 -> /api/net/info 与测速 ip 块里共用的内容 (不含 ok / checked) */
function netBody(st, lang) {
  const lan = { ip: '192.168.1.23', iface: M.os === 'windows' ? 'Ethernet' : 'en0' }, hasN = nodesOf(M.servers).length > 0, no = (v) => ({ ok: false, reason: v });
  const rt = (id, v) => Object.assign({ id, name: tr(lang, id === 'PIN' ? 'net.pin' : 'net.auto') }, v);
  if (!hasN && (st === 'normal' || st === 'limited' || st === 'unknown')) st = 'noservers';
  if (st === 'noservers') return { state: 'normal', reason: '', lan, direct: NETIP.direct, routes: [] };
  if (st === 'limited') return { state: 'limited', reason: tr(lang, 'net.limited'), lan, direct: NETIP.direct, routes: [rt('PIN', NETIP.pin), rt('Global', no('http_403'))] };
  if (st === 'blocked') return { state: 'blocked', reason: tr(lang, 'net.blocked'), lan, direct: no('timeout'), routes: hasN ? [rt('PIN', no('timeout')), rt('Global', no('reset'))] : [] };
  if (st === 'unreachable') return { state: 'blocked', reason: tr(lang, 'net.blocked'), lan: { ip: '', iface: lan.iface }, direct: no('dns'), routes: hasN ? [rt('PIN', no('dns')), rt('Global', no('timeout'))] : [] };
  if (st === 'unknown') return { state: 'unknown', reason: tr(lang, 'net.unknown'), lan, direct: NETIP.direct, routes: [rt('PIN', NETIP.pinLite), rt('Global', NETIP.globalLite)] };
  return { state: 'normal', reason: '', lan, direct: NETIP.direct, routes: [rt('PIN', NETIP.pin), rt('Global', NETIP.global)] };
}
route('GET', '/api/net/info', (c) => {
  const st = c.p('mock') || M.net; if (NET_STATES.indexOf(st) < 0) throw E('E_INVALID', 'e.badNet');
  if (st === 'none') return { ok: true, checked: 0 };
  return Object.assign({ ok: true, checked: M.netChecked || sec() - 60 }, netBody(st, c.lang));
});
route('POST', '/api/net/refresh', () => {
  if (M.speed.running) throw E('E_BUSY', 'e.netBusy');
  oplog('dashboard', 'net.refresh', '');
  return { ok: true, job: newJob('net-info', ['js.netDirect'].concat(nodesOf(M.servers).length ? ['js.netPin', 'js.netAuto'] : []), rnd(3000, 5000), { outage: false, msg: 'jd.net', done: () => { M.netChecked = sec(); if (M.net === 'none') M.net = 'normal'; } }) };
});

/* ===================== 8. 测速 (约 20 秒: ip 2s -> direct 4.5s -> nodes 7.5s -> speed 5.5s; 单元格由 (线路, 目标) 的哈希决定, 同一个节点每次结果一样) ===================== */
const IP_MS = 2000, DIRECT_MS = 4500, NODES_MS = 7500, SPEED_MS = 5500, TAIL_MS = 500, SPEED_MAX_NODES = 12;
/* 国内直连访问海外目标的典型结果 (这正是测速要展示的对比) */
const DIRECT_GLOBAL = { google: ['fail', 'timeout'], youtube: ['fail', 'timeout'], github: ['slow', 1180], cloudflare: ['ok', 195], claude: ['limited', 451], chatgpt: ['limited', 429], gemini: ['fail', 'dns'], tiktok: ['fail', 'reset'], wikipedia: ['fail', 'timeout'] };
/* 节点的「性格」: 三分之一的节点有点小毛病 (部分目标受限 / 超时 / 偏慢); 默认选中的 4 个节点里一定能看到各种状态 */
const NODE_PERS = ['limited', 'failgemini', 'slow', 'failtiktok', 'clean', 'clean', 'clean', 'clean', 'clean', 'clean', 'clean', 'clean'];
const personality = (tag) => (tag === SEED_PIN[0] ? 'clean' : tag === SEED_PIN[1] ? 'limited' : NODE_PERS[hash(tag + '#9') % 12]);
const isOverseas = (g) => g.group === 'global' || g.group === 'dev' || g.group === 'media';           // 海外目标: 直连和每个节点都测; 国内 / 运营商目标只测直连 (节点那一格是 skip)
const hostOf = (u) => { try { return new URL(u).hostname.toLowerCase(); } catch (e) { return ''; } };
const customKw = (tg) => { const h = hostOf(tg.url) || tg.id; return /fail|dead|unreach/.test(h) ? 'fail' : /slow/.test(h) ? 'slow' : /block|limit|ban/.test(h) ? 'limited' : ''; };
function dgFallback(id) {                                                  // 国内直连访问「没有专门设定」的海外目标: 一半以上不通, 其余有的偏慢 / 受限; 由 id 决定, 同一目标每次一样
  const h = hash('dg|' + id) % 10;
  if (h < 5) return ['fail', ['timeout', 'reset', 'dns', 'timeout', 'reset'][h]];
  if (h === 5) return ['limited', 429];
  return ['ok', h < 8 ? 820 + hash(id) % 700 : 150 + hash(id) % 300];
}
function cellFor(route, tg, net) {
  const rr = mulberry(hash(route.id + '|' + tg.id)), okc = tg.expect.length ? tg.expect[0] : 200, lim = [403, 429, 451, 503].filter((x) => tg.expect.indexOf(x) < 0)[0] || 429;
  const failC = (err) => ({ st: 'fail', ms: 0, connect: 0, ttfb: 0, http: 0, err });
  const okC = (ms) => ({ st: ms > 800 ? 'slow' : 'ok', ms, connect: Math.round(ms * (0.22 + rr() * 0.2)), ttfb: ms, http: okc, err: '' });
  const limC = (code, ms) => ({ st: 'limited', ms, connect: Math.round(ms * 0.3), ttfb: ms, http: code, err: '' });
  if (net === 'blocked' || net === 'unreachable') return failC(net === 'unreachable' ? (rr() < 0.5 ? 'dns' : 'timeout') : (rr() < 0.5 ? 'timeout' : 'reset'));
  const kw = tg.custom ? customKw(tg) : '';                                // 自定义目标: 主机名含 fail / slow / block 时对所有线路都失败 / 偏慢 / 受限 (便于测试界面); 其余和内置目标一样按分组
  if (kw === 'fail') return failC(['timeout', 'dns', 'reset'][hash(tg.id) % 3]);
  if (kw === 'limited') return limC(lim, Math.round(90 + rr() * 200));
  if (kw === 'slow') return okC(850 + Math.round(rr() * 600));
  if (route.kind === 'direct') {
    if (!isOverseas(tg)) return okC(Math.round(10 + rr() * 110));
    const d = DIRECT_GLOBAL[tg.id] || dgFallback(tg.id);
    return d[0] === 'fail' ? failC(d[1]) : d[0] === 'limited' ? limC(d[1], Math.round(120 + rr() * 150)) : okC(d[1] + Math.round(rr() * 60));
  }
  const base = baseDelay(route.id), p = personality(route.id);
  if (!base) return failC('timeout');                                      // 核心里延迟超时的节点: 什么都连不上
  if ((p === 'limited' || net === 'limited') && (tg.id === 'chatgpt' || tg.id === 'tiktok')) return limC(lim, Math.round(90 + rr() * 200));
  if (p === 'failgemini' && tg.id === 'gemini') return failC('timeout');
  if (p === 'failtiktok' && tg.id === 'tiktok') return failC('reset');
  if (p === 'slow' && (tg.id === 'github' || tg.id === 'wikipedia')) return okC(820 + Math.round(rr() * 700));
  const ms = Math.round(40 + base / 325 * 180 + rr() * 160);
  return okC(rr() < 0.04 ? 820 + Math.round(rr() * 900) : ms);
}
function speedKbps(rid, kind, net) {
  if (net === 'blocked' || net === 'unreachable') return 0;
  const h = hash(rid + '|' + kind);
  return rid === 'direct' ? (kind === 'cn' ? 6000 + h % 38000 : 380 + h % 2200) : (baseDelay(rid) ? 2200 + h % 26000 : 0);
}
function buildTest(o, startMs) {
  const t = { id: 'st-' + Math.floor(startMs / 1000) + '-' + (++M.speed.seq), mode: o.mode, speed: o.speed, startMs, state: 'running', finalEl: 0, endMs: 0, net: M.net, ipDone: false,
    routes: [], targets: o.targets, tmap: {}, ev: {}, speedItems: [], ph: [], nodeSpans: [], total: 0, speedStart: 0, speedStep: 1 };
  o.targets.forEach((g) => { t.tmap[g.id] = g; });
  if (o.mode !== 'node') t.routes.push({ id: 'direct', kind: 'direct' });
  if (o.mode !== 'direct') o.nodes.forEach((n) => t.routes.push({ id: n.tag, kind: 'node', role: n.role }));
  let cur = IP_MS; t.ph.push(['ip', 0, cur]);
  if (o.mode !== 'node') { const step = DIRECT_MS / o.targets.length; o.targets.forEach((g, i) => { t.ev[g.id + '|direct'] = cur + step * (i + 1); }); t.ph.push(['direct', cur, cur + DIRECT_MS]); cur += DIRECT_MS; }
  if (o.mode !== 'direct' && o.nodes.length) {                              // 每个节点一列, 逐个目标填满 (节点不测国内 / 运营商目标: skip)
    const gl = o.targets.filter(isOverseas), per = NODES_MS / o.nodes.length;
    o.nodes.forEach((n, ni) => { gl.forEach((g, k) => { t.ev[g.id + '|' + n.tag] = cur + per * ni + per * (k + 1) / gl.length; }); t.nodeSpans.push([n.tag, cur + per * ni, cur + per * (ni + 1)]); });
    t.ph.push(['nodes', cur, cur + NODES_MS]); cur += NODES_MS;
  }
  if (o.speed) {
    if (o.mode !== 'node') t.speedItems.push({ r: 'direct', kind: 'cn' }, { r: 'direct', kind: 'global' });
    if (o.mode !== 'direct') o.nodes.forEach((n) => t.speedItems.push({ r: n.tag, kind: 'global' }));
    const step = SPEED_MS / Math.max(1, t.speedItems.length); t.speedItems.forEach((it, i) => { it.at = cur + step * (i + 1); });
    t.ph.push(['speed', cur, cur + SPEED_MS]); t.speedStart = cur; t.speedStep = step; cur += SPEED_MS;
  }
  t.total = cur + TAIL_MS; return t;
}
/* 用探测结果修正 IP 状态 (同 lib/speed.sh 的 speed_ip_refine, 只看「与线路相关」的目标: 直连看国内 / 运营商, 节点看海外): 失败 / 受限占比高 -> limited / blocked */
function refineState(t, cells) {
  let any = false, allBad = true, worst = 'normal';
  t.routes.forEach((r) => {
    const rel = cells.filter((c) => c.r === r.id && ['ok', 'slow', 'limited', 'fail'].indexOf(c.st) >= 0 && (isOverseas(t.tmap[c.t]) === (r.kind !== 'direct')));
    if (!rel.length) return; any = true;
    const ratio = rel.filter((c) => c.st === 'fail' || c.st === 'limited').length / rel.length;
    if (ratio < 0.8) allBad = false; if (ratio >= 0.4) worst = 'limited';
  });
  return any && allBad ? 'blocked' : worst;
}
function speedRender(t, lang) {
  const running = t.state === 'running', el = running ? Math.min((now() - t.startMs) * FAST, t.total) : t.finalEl, cells = [], st = {};
  t.routes.forEach((r) => { st[r.id] = { n: 0, ok: 0, sum: 0, lim: 0 }; });
  t.routes.forEach((r) => t.targets.forEach((g) => {
    const at = t.ev[g.id + '|' + r.id];
    if (r.kind === 'node' && !isOverseas(g)) { cells.push({ t: g.id, r: r.id, st: 'skip' }); return; }
    if (at === undefined || at > el) { cells.push({ t: g.id, r: r.id, st: 'pending' }); return; }
    const c = cellFor(r, g, t.net), s = st[r.id]; s.n++; if (c.st === 'ok' || c.st === 'slow') { s.ok++; s.sum += c.ms; } if (c.st === 'limited') s.lim++;
    cells.push(Object.assign({ t: g.id, r: r.id }, c));
  }));
  const speeds = t.speedItems.filter((it) => it.at <= el).map((it) => ({ r: it.r, kind: it.kind, kbps: speedKbps(it.r, it.kind, t.net) }));
  const ph = t.ph.filter((p) => el < p[2])[0] || t.ph[t.ph.length - 1], phase = ph[0]; let msg;
  if (t.state === 'done') msg = tr(lang, 'sp.done'); else if (t.state === 'stopped') msg = tr(lang, 'sp.stopped');
  else if (phase === 'ip') msg = tr(lang, 'sp.ip'); else if (phase === 'direct') msg = tr(lang, 'sp.direct');
  else if (phase === 'nodes') msg = tr(lang, 'sp.node', { n: (t.nodeSpans.filter((s) => el < s[2])[0] || t.nodeSpans[t.nodeSpans.length - 1])[0] });
  else { const it = t.speedItems[Math.min(t.speedItems.length - 1, Math.max(0, Math.floor((el - t.speedStart) / t.speedStep)))]; msg = tr(lang, 'sp.speed', { n: it.r === 'direct' ? tr(lang, 'sp.directName') : it.r }); }
  const sum = { best: '', avg_ms: {}, ok: {}, total: {}, limited: {} }; let best = null;
  t.routes.forEach((r) => {
    const s = st[r.id]; sum.avg_ms[r.id] = s.ok ? Math.round(s.sum / s.ok) : 0; sum.ok[r.id] = s.ok; sum.total[r.id] = s.n; sum.limited[r.id] = s.lim;
    if (r.kind === 'node' && s.n > 0 && (!best || s.ok > st[best].ok || (s.ok === st[best].ok && s.ok > 0 && s.sum / s.ok < st[best].sum / st[best].ok))) best = r.id;
  });
  if (!best) { const f = t.routes.filter((r) => st[r.id].n > 0)[0]; best = f ? f.id : ''; }
  sum.best = best;
  let ip = { state: 'unknown' };                                           // 查完 IP (约 2 秒) 才有内容
  if (el >= IP_MS) {
    ip = Object.assign({ checked: Math.floor(t.startMs / 1000) + 2 }, netBody(t.net, lang));
    if (t.state === 'done') { const rs = refineState(t, cells); if (ip.state !== 'blocked' && rs === 'blocked') { ip.state = 'blocked'; ip.reason = tr(lang, 'net.blocked'); } else if (ip.state === 'normal' && rs === 'limited') { ip.state = 'limited'; ip.reason = tr(lang, 'net.limited'); } }
  }
  return { ok: true, id: t.id, state: t.state, pct: running ? Math.min(99, Math.floor(el / t.total * 100)) : 100, phase, msg, started: Math.floor(t.startMs / 1000), elapsed: Math.floor(el / 1000), mode: t.mode, speed: t.speed,
    routes: t.routes.map((r) => Object.assign({ id: r.id, name: r.kind === 'direct' ? tr(lang, 'sp.directName') : r.id, kind: r.kind }, r.role ? { role: r.role } : {})),
    targets: t.targets.map((g) => ({ id: g.id, group: g.group, name: lang === 'en' ? g.en : g.zh })), cells, speeds, ip, summary: sum };
}
function speedSettle() {
  const t = M.speed.running; if (!t) return;
  const el = (now() - t.startMs) * FAST;
  if (el >= IP_MS && !t.ipDone) { t.ipDone = true; M.netChecked = sec(); if (M.net === 'none') M.net = 'normal'; }   // 测速开头会顺便更新本机 IP 缓存
  if (el >= t.total) { t.state = 'done'; t.finalEl = t.total; t.endMs = now(); M.speed.running = null; M.speed.last = t; }
}
const speedNodes = () => nodesOf(M.servers).map((s) => ({ tag: s.tag, role: s.role }));
const planNodes = () => speedNodes().map((n) => { const b = baseDelay(n.tag); return { tag: n.tag, role: n.role, delay: b > 0 ? b : null }; });
/* 默认选择: 固定出口 (最多 2 个) + 延迟最低的自动节点, 合计最多 4 个 */
function defaultNodes(nodes) {
  const pins = nodes.filter((n) => n.role === 'pin').slice(0, 2).map((n) => n.tag), autos = nodes.filter((n) => n.role === 'auto');
  return pins.concat(autos.filter((n) => n.delay).sort((a, b) => a.delay - b.delay).concat(autos.filter((n) => !n.delay)).map((n) => n.tag)).slice(0, 4);
}
function seedSpeedLast() {
  const all = planNodes(), nodes = defaultNodes(all).map((tag) => ({ tag, role: all.filter((n) => n.tag === tag)[0].role })), y = addDays(startOfDay(now()), -1) + (14 * 3600 + 3 * 60 + 11) * 1000;
  const t = buildTest({ mode: nodes.length ? 'both' : 'direct', speed: true, nodes, targets: defaultTargets() }, y);
  t.state = 'done'; t.finalEl = t.total; t.endMs = y + t.total / FAST; M.speed.byId[t.id] = t; M.speed.last = t;
}
const SPEED_ID = /^st-[0-9]+-[0-9]+$/;
route('GET', '/api/speedtest/plan', (c) => {
  const nodes = planNodes(), defs = defaultNodes(nodes), n = defs.length;
  return { ok: true, direct_available: true, node_available: nodes.length > 0, targets: liveTargets().map((g) => ({ id: g.id, group: g.group, name: c.lang === 'en' ? g.en : g.zh, url: g.url, icon: g.icon, default: g.def })),
    nodes, defaults: { mode: nodes.length ? 'both' : 'direct', speed: true, nodes: defs }, est: { seconds: 27 + 8 * n, mb: 16 + 6 * n } };
});
route('POST', '/api/speedtest/start', (c) => {
  const mode = c.p('mode') || 'both', spd = c.p('speed') === '' ? '1' : c.p('speed'), all = speedNodes(), byTag = {}; all.forEach((n) => { byTag[n.tag] = n; });
  if (['direct', 'node', 'both'].indexOf(mode) < 0) throw E('E_INVALID', 'e.speedMode');
  if (spd !== '0' && spd !== '1') throw E('E_INVALID', 'e.badBool');
  if (M.speed.running) throw E('E_RUNNING');
  let eff = mode, chosen = [];
  if (mode !== 'direct') {
    if (!all.length) { if (mode === 'node') throw E('E_NO_SERVERS'); eff = 'direct'; }                // 「both」没有服务器时退化成只测直连
    else if (c.p('nodes')) {
      const l = c.p('nodes').split(',').map((x) => x.trim()).filter(Boolean).filter((x, i, a) => a.indexOf(x) === i);
      if (!l.length || l.length > SPEED_MAX_NODES || l.some((x) => !byTag[x])) throw E('E_INVALID', 'e.speedNodes');
      chosen = l.map((x) => byTag[x]);
    } else chosen = defaultNodes(planNodes()).map((x) => byTag[x]);
  }
  let targets = defaultTargets();                                          // 缺省 = 默认勾选的目标 (plan.targets[].default); API.md 写的是「缺省全部」, 内置目标有 60+ 个, 所以这里取默认集合
  if (c.p('targets')) {
    const l = c.p('targets').split(',').map((x) => x.trim()).filter(Boolean), live = liveTargets();
    targets = l.map((x) => live.filter((g) => g.id === x)[0]);              // 只能选未隐藏的目标 (内置的 + 自定义的)
    if (!l.length || l.length > 120 || targets.some((g) => !g)) throw E('E_INVALID', 'e.speedTargets');
    targets = targets.filter((g, i, a) => a.indexOf(g) === i);
  }
  if (!targets.length) throw E('E_INVALID', 'e.speedTargets');
  const t = buildTest({ mode: eff, speed: spd === '1', nodes: chosen, targets }, now());
  M.speed.running = t; M.speed.byId[t.id] = t; Object.keys(M.speed.byId).slice(0, -20).forEach((k) => { if (M.speed.byId[k] !== M.speed.last) delete M.speed.byId[k]; });
  oplog('dashboard', 'speedtest.start', kv({ mode: eff, nodes: chosen.length, speed: spd }));
  return { ok: true, id: t.id };
});
route('GET', '/api/speedtest/status', (c) => {
  const id = c.p('id'); let t;
  if (id) { t = SPEED_ID.test(id) ? M.speed.byId[id] : null; if (!t) throw E('E_NOT_FOUND', 'e.noSpeed'); } else t = M.speed.running || M.speed.last;   // 不带 id: 正在跑的, 否则最近一次结束的
  return t ? speedRender(t, c.lang) : { ok: true, none: true };
});
route('GET', '/api/speedtest/last', (c) => (M.speed.last ? speedRender(M.speed.last, c.lang) : { ok: true, none: true }));
route('POST', '/api/speedtest/stop', (c) => {
  const id = c.p('id'), run = M.speed.running;
  if (id && !(SPEED_ID.test(id) && M.speed.byId[id])) throw E('E_NOT_FOUND', 'e.noSpeed');
  if (run && (!id || run.id === id)) {
    run.finalEl = Math.min((now() - run.startMs) * FAST, run.total); run.state = 'stopped'; run.endMs = now(); M.speed.running = null; M.speed.last = run;
    if (run.finalEl >= IP_MS && !run.ipDone) { run.ipDone = true; M.netChecked = sec(); }
    oplog('dashboard', 'speedtest.stop', kv({ id: run.id }));
  }
  return { ok: true };
});

/* ===================== 8a. 测速目标: 内置 63 个 + 用户的增 / 删 / 改 (docs/API.md「测速目标」; 行为对照 lib/speed.sh) =====================
 * 内置目标可以「修改」(保存一份覆盖, modified:true; 名称的中英文都变成填的名称)、「删除」(其实是隐藏, 随时恢复); 用户自己添加的目标 id 形如 u-ab12cd, 默认勾选 (default:true)。
 * 保存时 name / group / url 必填, expect 缺省 200,204,301,302, icon 可空 —— 编辑也是整份替换 (没给的字段不会保留旧值)。 */
function allTargets() {
  const out = BUILTIN_TGT.map((b) => { const o = M.tgt.over[b.id] || null; return Object.assign({}, b, o || {}, { builtin: true, custom: false, modified: !!o, hidden: !!M.tgt.hidden[b.id] }); });
  return out.concat(M.tgt.custom.map((c) => Object.assign({}, c, { builtin: false, custom: true, modified: false, hidden: false })));
}
const liveTargets = () => allTargets().filter((t) => !t.hidden);
function defaultTargets() { const l = liveTargets(), d = l.filter((t) => t.def); return d.length ? d : l; }
const TGT_MAX_CUSTOM = 100, TGT_ID = /^[a-z0-9_-]*$/;
function tgtForm(c) {                                                      // 校验顺序同 lib/speed.sh 的 speed_target_check
  const raw = [c.p('name'), c.p('group'), c.p('url'), c.p('expect'), c.p('icon')];
  if (raw.some((x) => /[\r\n]/.test(x))) throw E('E_INVALID', 'e.tgtNewline');
  const name = raw[0].replace(/^\s+|\s+$/g, ''), group = raw[1], url = raw[2], exp = raw[3] || '200,204,301,302', icon = raw[4], nch = Array.from(name).length;
  if (nch < 1 || nch > 40) throw E('E_INVALID', 'e.tgtName');
  if (/[|<>]/.test(name)) throw E('E_INVALID', 'e.tgtNameChars');
  if (/[\x00-\x1f\x7f]/.test(name)) throw E('E_INVALID', 'e.tgtNameCtl');
  if (TGT_GROUPS.indexOf(group) < 0) throw E('E_INVALID', 'e.tgtGroup');
  if (url.length > 300 || !/^https?:\/\/[A-Za-z0-9._~:\/?#@!$&()*+,;=%-]+$/.test(url)) throw E('E_INVALID', 'e.tgtUrl');
  if (!/^[1-5][0-9][0-9](,[1-5][0-9][0-9]){0,9}$/.test(exp)) throw E('E_INVALID', 'e.tgtExpect');
  if (!/^[a-z0-9-]{0,30}$/.test(icon)) throw E('E_INVALID', 'e.tgtIcon');
  return { name, group, url, expect: exp.split(',').map(Number), icon };
}
route('GET', '/api/speedtest/targets', (c) => {
  const all = allTargets();
  return { ok: true, targets: all.map((t) => ({ id: t.id, group: t.group, name: c.lang === 'en' ? t.en : t.zh, url: t.url, expect: t.expect.join(','), icon: t.icon, builtin: t.builtin, modified: t.modified, hidden: t.hidden, default: t.def })),
    groups: TGT_GROUPS.slice(), hidden: all.filter((t) => t.hidden).length, custom: all.filter((t) => t.custom).length };
});
route('POST', '/api/speedtest/targets', (c) => {
  const id = c.p('id'); if (!TGT_ID.test(id)) throw E('E_INVALID', 'e.tgtId');
  const f = tgtForm(c);
  if (!id) {                                                               // 新增: id 自动生成
    if (M.tgt.custom.length >= TGT_MAX_CUSTOM) throw E('E_INVALID', 'e.tgtMax');
    let nid; do { nid = 'u-' + randHex(3); } while (allTargets().some((t) => t.id === nid));
    M.tgt.custom.push({ id: nid, group: f.group, zh: f.name, en: f.name, url: f.url, expect: f.expect, icon: f.icon, def: true });
    oplog('dashboard', 'speed.target', kv({ action: 'add', id: nid, group: f.group })); return { ok: true, id: nid };
  }
  const cur = allTargets().filter((t) => t.id === id)[0]; if (!cur) throw E('E_INVALID', 'e.noTarget');
  const rec = { group: f.group, zh: f.name, en: f.name, url: f.url, expect: f.expect, icon: f.icon };
  if (cur.custom) Object.assign(M.tgt.custom.filter((t) => t.id === id)[0], rec); else M.tgt.over[id] = rec;       // 内置目标: 保存一份覆盖 (modified:true)
  oplog('dashboard', 'speed.target', kv({ action: 'edit', id, group: f.group })); return { ok: true, id };
});
route('POST', '/api/speedtest/targets/delete', (c) => {
  const id = c.p('id'); if (!TGT_ID.test(id)) throw E('E_INVALID', 'e.tgtId');
  const cur = allTargets().filter((t) => t.id === id)[0]; if (!cur) throw E('E_NOT_FOUND', 'e.noTarget');
  if (cur.builtin) M.tgt.hidden[id] = 1; else M.tgt.custom = M.tgt.custom.filter((t) => t.id !== id);           // 内置: 隐藏 (可恢复); 自定义: 直接删除
  oplog('dashboard', 'speed.target', kv({ action: 'delete', id })); return { ok: true };
});
route('POST', '/api/speedtest/targets/restore', (c) => {
  const id = c.p('id'); if (!TGT_ID.test(id)) throw E('E_INVALID', 'e.tgtId');
  if (!BUILTIN_TGT.some((t) => t.id === id)) throw E('E_NOT_FOUND', 'e.noBuiltinTarget');
  delete M.tgt.hidden[id]; delete M.tgt.over[id];                          // 取消隐藏并撤销对它的修改
  oplog('dashboard', 'speed.target', kv({ action: 'restore', id })); return { ok: true };
});
route('POST', '/api/speedtest/targets/reset', () => { M.tgt = { custom: [], over: {}, hidden: {} }; oplog('dashboard', 'speed.targets.reset', ''); return { ok: true }; });

/* ===================== 8b. 添加自己的服务器 (SSH 一键部署) =====================
 * 场景由主机名决定 (见文件头的「魔法主机」); 凭据 (密码 / 私钥 / 口令 / sudo 密码) 只在请求里用来算出「结果」, 之后立刻丢弃:
 * 不写日志、不保存、不出现在任何响应里; 任务只持有算好的结果 (任务函数在独立的函数里创建, 不会捕获请求对象)。 */
const VPS_DEPS = [['curl', '7.88.1'], ['ca-certificates', '20230311'], ['iproute2', '6.1.0']];
const OS_DEB12 = { id: 'debian', version: '12', codename: 'bookworm', pretty: 'Debian GNU/Linux 12 (bookworm)' };
const fingerprint = (host) => 'SHA256:' + crypto.createHash('sha256').update('enana-mock-hostkey|' + host).digest('base64').replace(/=+$/, '');
const isIp4 = (h) => /^\d{1,3}(\.\d{1,3}){3}$/.test(h) && h.split('.').every((x) => +x <= 255);
const validHost = (h) => h.length > 0 && h.length <= 253 && (isIp4(h) || (h.indexOf(':') >= 0 && /^[0-9A-Fa-f:]{2,45}$/.test(h)) || (/^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$/.test(h) && !/^[0-9.]+$/.test(h)));
const pubIp = (host) => (isIp4(host) ? host : '203.0.113.' + (1 + hash(host) % 254)), localIp = (ip) => '10.0.0.' + (2 + hash(ip) % 250);
const vpsId = (host, port) => 'vps_' + crypto.createHash('sha1').update(host + ':' + port).digest('hex').slice(0, 8);
/* 表单 -> 只留「派生信息」(是否有 sudo 密码 / 是不是 wrong-pass ...), 原始的密码 / 私钥不会离开这个函数; 敏感字段只读请求体, 不读 URL */
function vpsCreds(c, needHostkey) {
  const host = String(c.p('host')).trim(), port = c.p('port') === '' ? 22 : num(c.p('port'), -1), user = String(c.p('user')).trim(), mode = c.p('mode') || 'password', hostkey = c.p('hostkey');
  const pw = String(c.form.password || ''), key = String(c.form.key || ''), m = /^203\.0\.113\.(\d{1,3})$/.exec(host);
  if (!validHost(host)) throw E('E_INVALID', 'e.vpsHost');
  if (!(port >= 1 && port <= 65535)) throw E('E_INVALID', 'e.vpsPort');
  if (!/^[A-Za-z_][A-Za-z0-9_.-]{0,31}$/.test(user)) throw E('E_INVALID', 'e.vpsUser');
  if (mode !== 'password' && mode !== 'key') throw E('E_INVALID', 'e.vpsMode');
  if (mode === 'password' && !pw) throw E('E_INVALID', 'e.vpsPassword');
  if (mode === 'key' && !/-----BEGIN [A-Z ]*PRIVATE KEY-----/.test(key)) throw E('E_INVALID', 'e.vpsKey');
  if (needHostkey && !hostkey) throw E('E_INVALID', 'e.vpsHostkey');
  return { host, port, user, mode, hostkey, wrongPass: mode === 'password' && pw === 'wrong-pass', hasSudo: String(c.form.sudo_password || '').length > 0, last: m ? +m[1] : -1 };
}
/* 探测的结果 (语言无关的部分); support_note 在每次查询任务时按 X-Enana-Lang 翻译 */
function vpsData(cr) {
  const host = cr.host, last = cr.last, pub = pubIp(host);
  let os = OS_DEB12, arch = 'amd64', support = 'full', have = [true, false, false], fw = 'ufw_active', listening = [22], sb = { installed: false, version: '' }, node = { installed: false };
  if (last === 20) { os = { id: 'ubuntu', version: '22.04', codename: 'jammy', pretty: 'Ubuntu 22.04.4 LTS' }; arch = 'arm64'; have = [false, false, false]; fw = 'ufw_inactive'; }
  else if (last === 30) { have = [true, true, true]; sb = { installed: true, version: BASE_CORE }; node = { installed: true }; listening = [22, 80, 443]; }
  else if (last === 50) { os = { id: 'centos', version: '7', codename: '', pretty: 'CentOS Linux 7 (Core)' }; support = 'no'; have = [true, true, true]; fw = 'none'; }
  else if (last === 51) { os = { id: 'debian', version: '10', codename: 'buster', pretty: 'Debian GNU/Linux 10 (buster)' }; support = 'best_effort'; have = [true, true, false]; fw = 'ufw_inactive'; }
  const deps = VPS_DEPS.map((d, i) => (have[i] ? { name: d[0], installed: true, version: d[1] } : { name: d[0], installed: false })), missing = deps.filter((d) => !d.installed).map((d) => d.name);
  let ips = [{ local: localIp(pub), public: pub, v: 4 }], ipv6 = [];
  if (last === 31) { ips = [{ local: '10.0.0.31', public: '198.51.100.31', v: 4 }, { local: '10.0.0.32', public: '198.51.100.32', v: 4 }]; ipv6 = ['2001:db8::31']; }     // 两个公网 IPv4 (NAT 式内网地址) + 一个 IPv6
  return { host, port: cr.port, user: cr.user, hostkey: fingerprint(host), hostkey_changed: last === 40, os, arch, supported: support !== 'no', support, privilege: last === 65 ? 'sudo_password' : (cr.user === 'root' ? 'root' : 'sudo_nopass'),
    init: 'systemd', deps, missing, all_missing: missing.length === deps.length, singbox: sb, node, firewall: fw, listening, ips, ipv6 };
}
const probeResult = (r, lang) => ({ host: r.host, port: r.port, user: r.user, hostkey: r.hostkey, hostkey_changed: r.hostkey_changed, os: r.os, arch: r.arch, supported: r.supported, support: r.support,
  support_note: tr(lang, r.support === 'full' ? 'vps.noteFull' : r.support === 'best_effort' ? 'vps.noteBest' : 'vps.noteNo', { os: r.os.pretty }), privilege: r.privilege, init: r.init, deps: r.deps, missing: r.missing,
  all_missing: r.all_missing, singbox: r.singbox, node: r.node, firewall: r.firewall, listening: r.listening, ips: r.ips, ipv6: r.ipv6 });
/* 先判「连不上 / 认证 / 指纹 / 权限」这些会让任务失败的场景: {err:{code, ms (多久后失败), step (失败在第几步)}}, 否则 {res: 探测结果} */
function vpsPlan(cr) {
  const last = cr.last, err = (code, ms, step) => ({ err: { code, ms, step } });
  if (last === 63) return err('E_SSH_NO_CLIENT', 700, 0);
  if (last === 60) return err('E_SSH_UNREACHABLE', 3000, 0);
  if (cr.wrongPass || last === 61) return err('E_SSH_AUTH', 2000, 0);
  if (last === 62) return err('E_SSH_KEY', 1500, 0);
  if (cr.hostkey && cr.hostkey !== fingerprint(cr.host)) return err('E_SSH_HOSTKEY', 1800, 0);
  if (last === 64 || (last === 65 && !cr.hasSudo)) return err('E_VPS_PRIVILEGE', 4000, 1);
  return { res: vpsData(cr) };
}
const PROBE_STEPS = ['js.sshConnect', 'js.sshDetect', 'js.sshEnv', 'js.sshIps'], REDETECT_STEPS = ['js.sshConnect', 'js.sshDetect', 'js.sshIps', 'js.sshSave'];
const PROV_STEPS = ['js.sshConnect', 'js.sshDetect', 'js.sshDeps', 'js.sshServer', 'js.sshConfig', 'js.sshStart', 'js.sshVerify', 'js.sshIps', 'js.sshSave'];
/* 失败的任务: state=error, msg 已翻译, 失败的那一步标 error, result:{code} 且顶层也带 code */
function vpsErrJob(name, steps, e, action, detail) {
  const at = (e.step + 0.5) / steps.length;
  return newJob(name, steps, e.ms / at, { outage: false, fail: true, failAt: at, code: e.code, failMsg: e.msg || ('err.' + e.code), failVars: e.vars, failResult: e.result, rollback: () => oplog('dashboard', action, kv(Object.assign({}, detail, { code: e.code })), 'error') });
}
function vpsProbeJob(plan, detail) {
  if (plan.err) return { ok: true, job: vpsErrJob('vps-probe', PROBE_STEPS, plan.err, 'vps.probe', detail) };
  const res = plan.res;
  return { ok: true, job: newJob('vps-probe', PROBE_STEPS, rnd(4000, 6000), { outage: false, msg: 'jd.vpsProbe', rollback: () => oplog('dashboard', 'vps.probe', kv(detail), 'error'),
    done: () => { oplog('dashboard', 'vps.probe', kv(detail)); return { resultFn: (lang) => probeResult(res, lang) }; } }) };
}
function vpsProvisionJob(plan, o) {
  const detail = { host: o.host, name: o.name, role: o.role }; let e = plan.err;
  if (!e) {
    if (!plan.res.supported) e = { code: 'E_VPS_UNSUPPORTED', ms: 3500, step: 1 };
    else if (!o.installDeps && plan.res.missing.length) e = { code: 'E_VPS_DEPS', ms: 4500, step: 2 };
    else if (o.last === 70 && !M.vpsOpen) e = { code: 'E_VPS_VERIFY', ms: 9000, step: 6, vars: { port: 443 }, result: { port: 443 } };       // 云厂商安全组没放行 443: 失败在「验证连通」; ctl vpsport=open 之后同一台就能成功 (测「放行端口后重新验证」)
  }
  if (e) return { ok: true, job: vpsErrJob('vps-provision', PROV_STEPS, e, 'vps.provision', detail) };
  const res = plan.res, ips = res.ips.map((x) => x.public), id = vpsId(o.host, o.port);       // 每个公网 IPv4 出口一个节点 (VLESS + Reality)
  return { ok: true, job: newJob('vps-provision', PROV_STEPS, rnd(10000, 14000), { outFrac: 0.88, msg: 'jd.vpsProvision', rollback: () => oplog('dashboard', 'vps.provision', kv(detail), 'error'),
    done: () => {
      const nodes = ips.map((ip) => ({ tag: o.name + '-' + ip, server: ip, port: 443, type: 'vless', egress: ip }));
      nodes.forEach((n) => { M.servers = M.servers.filter((x) => x.tag !== n.tag); M.servers.push({ tag: n.tag, type: 'vless', server: n.server, port: 443, role: o.role, sub: '' }); });
      applyNow();
      const row = { id, name: o.name, host: o.host, ssh_port: o.port, user: o.user, os: res.os.pretty, hostkey: fingerprint(o.host), ips: ips.slice(), nodes: nodes.map((n) => n.tag), updated: sec() }, old = M.vps.filter((v) => v.id === id)[0];
      if (old) Object.assign(old, row); else M.vps.push(Object.assign(row, { extra: false }));
      oplog('dashboard', 'vps.provision', kv(Object.assign({}, detail, { nodes: nodes.length })));
      return { vars: { n: nodes.length }, result: { nodes, ips, vps: id } };
    } }) };
}
function vpsRedetectJob(plan, rec, detail) {
  if (plan.err) return { ok: true, job: vpsErrJob('vps-redetect', REDETECT_STEPS, plan.err, 'vps.redetect', detail) };
  const adds = !rec.extra && rec.host === '203.0.113.31';                                    // 这条记录第一次重新识别时多出一个 IP (+ 节点)
  return { ok: true, job: newJob('vps-redetect', REDETECT_STEPS, rnd(4000, 6000), { outage: adds, outFrac: 0.8, msg: 'jd.vpsRedetect', rollback: () => oplog('dashboard', 'vps.redetect', kv(detail), 'error'),
    done: () => {
      const added = [];
      if (adds) {
        const ip = '198.51.100.33', first = M.servers.filter((s) => rec.nodes.indexOf(s.tag) >= 0)[0], role = first ? first.role : 'auto', tag = rec.name + '-' + ip;
        rec.extra = true; rec.ips.push(ip); rec.nodes.push(tag); M.servers = M.servers.filter((x) => x.tag !== tag); M.servers.push({ tag, type: 'vless', server: ip, port: 443, role, sub: '' });
        added.push({ tag, server: ip, port: 443, type: 'vless', egress: ip }); applyNow();
      }
      rec.updated = sec(); oplog('dashboard', 'vps.redetect', kv(Object.assign({}, detail, { added: added.length })));
      return { vars: { n: added.length }, result: { nodes: added, ips: rec.ips.slice(), vps: rec.id, added: added.length } };
    } }) };
}
route('POST', '/api/vps/probe', (c) => { const cr = vpsCreds(c, false); return vpsProbeJob(vpsPlan(cr), { host: cr.host, port: cr.port, mode: cr.mode }); });
route('POST', '/api/vps/provision', (c) => {
  const cr = vpsCreds(c, true), given = c.p('name'), name = given || (/^[A-Za-z0-9._-]{1,40}$/.test('my-vps-' + cr.host) ? 'my-vps-' + cr.host : 'my-vps'), role = c.p('role') || 'auto', deps = c.p('install_deps') === '' ? '1' : c.p('install_deps');   // 节点 tag = <服务器名>-<出口 IP>, 服务器名缺省 my-vps-<host> (host 太长 / 含冒号的 IPv6 时是 my-vps, 同 lib/vps.sh)
  if (given && !/^[A-Za-z0-9._-]{1,40}$/.test(given)) throw E('E_INVALID', 'e.vpsName');
  if (role !== 'pin' && role !== 'auto') throw E('E_INVALID', 'e.vpsRole');
  if (deps !== '0' && deps !== '1') throw E('E_INVALID', 'e.badBool');
  return vpsProvisionJob(vpsPlan(cr), { host: cr.host, port: cr.port, user: cr.user, name, role, installDeps: deps === '1', last: cr.last });
});
route('GET', '/api/vps', () => ({ ok: true, vps: M.vps.map((v) => ({ id: v.id, name: v.name, host: v.host, ssh_port: v.ssh_port, user: v.user, os: v.os, hostkey: v.hostkey, ips: v.ips, nodes: v.nodes, updated: v.updated })) }));
route('POST', '/api/vps/forget', (c) => {
  const id = c.p('id'); if (!id) throw E('E_INVALID', 'e.vpsId');
  const v = M.vps.filter((x) => x.id === id)[0]; if (!v) throw E('E_NOT_FOUND', 'e.noVps');
  M.vps = M.vps.filter((x) => x !== v); oplog('dashboard', 'vps.forget', kv({ id, host: v.host })); return { ok: true };                 // 只删记录, 不删节点
});
route('POST', '/api/vps/redetect', (c) => {
  const id = c.p('id'); if (!id) throw E('E_INVALID', 'e.vpsId');
  const rec = M.vps.filter((x) => x.id === id)[0]; if (!rec) throw E('E_NOT_FOUND', 'e.noVps');
  const cr = vpsCreds(c, false); return vpsRedetectJob(vpsPlan(cr), rec, { id: rec.id, host: rec.host });
});

/* ===================== 8c. 云端同步 (端到端加密: 这里只模拟状态与流程) ===================== */
function syncInit(first) {
  const t = sec();
  return { enabled: false, auto: false, remote: { exists: true, version: 7, updated: t - 86400, size: 2048, device: 'MacBook-Pro' }, local: first ? { version: 0, dirty: false } : { version: 6, dirty: true },
    lastPull: 0, lastPush: first ? 0 : t - 3 * 86400, keyBad: false, offline: false };
}
const syncOnline = () => M.central === 'up' && !M.sync.offline, deviceName = () => (M.os === 'windows' ? 'Windows-PC' : 'This-Mac');
const syncSize = () => 1200 + 90 * M.servers.length + 60 * M.subs.length + 40 * M.overrides.length;
const NO_REMOTE = { exists: false, version: 0, updated: 0, size: 0, device: '' };
/* 「云端数据」长什么样: 基线数据集 + 另一台电脑上多出来的两台服务器 */
function remoteSnapshot() {
  const t = sec(), servers = seedServers().concat([{ tag: 'synced-1', type: 'trojan', server: '203.0.113.201', port: 443, role: 'pin', sub: '' }, { tag: 'synced-2', type: 'vless', server: '203.0.113.202', port: 443, role: 'auto', sub: '' }]);
  return { servers, subs: [{ name: 'demo-sub', host: 'sub.example.com', updated: t - 6 * 3600, count: 20, interval: 12, usage: { used: 32.5e9, total: 200e9, expire: t + 45 * 86400 } }],
    overrides: [{ kind: 'site', value: 'example.org', state: 'direct' }, { kind: 'site', value: 'intranet.example.com', state: 'pin' }] };
}
const syncNeedOnline = () => { if (!syncOnline()) throw E('E_ACCOUNT_UNREACHABLE', 'e.syncOffline'); };
const syncNeedOn = () => { if (!M.sync.enabled) throw E('E_INVALID', 'e.syncOff'); };
route('GET', '/api/sync', () => { const s = M.sync, r = s.remote.exists ? s.remote : NO_REMOTE;
  return { ok: true, enabled: s.enabled, auto: s.auto, account: M.account || '', remote: { exists: r.exists, version: r.version, updated: r.updated, size: r.size, device: r.device }, local: { version: s.local.version, dirty: s.local.dirty },
    last_pull: s.lastPull, last_push: s.lastPush, online: syncOnline() }; });
route('POST', '/api/sync/settings', (c) => {
  const s = M.sync, en = c.p('enabled'), au = c.p('auto');
  if ((en !== '' && en !== '0' && en !== '1') || (au !== '' && au !== '0' && au !== '1')) throw E('E_INVALID', 'e.badBool');
  const enabled = en === '' ? s.enabled : en === '1', auto = au === '' ? (enabled && s.auto) : au === '1';
  if (auto && !enabled) throw E('E_INVALID', 'e.syncAuto');
  if (en !== '' || au !== '') { s.enabled = enabled; s.auto = auto; oplog('dashboard', 'sync.settings', kv({ enabled: enabled ? 1 : 0, auto: auto ? 1 : 0 })); }
  return { ok: true };
});
route('POST', '/api/sync/push', (c) => {
  const s = M.sync, force = c.p('force') === '1';                         // force=1: 用本机覆盖更新的云端数据 (API.md 里没有, 提议新增)
  syncNeedOn(); syncNeedOnline();
  if (s.remote.exists && s.remote.version > s.local.version && !force) throw E('E_SYNC_CONFLICT');
  const v = Math.max(s.remote.exists ? s.remote.version : 0, s.local.version) + 1;
  return { ok: true, job: newJob('sync-push', ['js.syncCollect', 'js.syncEncrypt', 'js.syncUpload'], 3000, { outage: false, msg: 'jd.syncPush', rollback: () => oplog('dashboard', 'sync.push', kv({ version: v, force: force ? 1 : 0 }), 'error'),
    done: () => { s.remote = { exists: true, version: v, updated: sec(), size: syncSize(), device: deviceName() }; s.local = { version: v, dirty: false }; s.lastPush = sec(); oplog('dashboard', 'sync.push', kv({ version: v, force: force ? 1 : 0 })); return { vars: { v } }; } }) };
});
route('POST', '/api/sync/pull', (c) => {
  const s = M.sync, mode = c.p('mode') || 'replace', old = String(c.form.old_password || '');      // 旧密码只读请求体, 不记录不保存
  if (mode !== 'replace' && mode !== 'merge') throw E('E_INVALID', 'e.badMode');
  syncNeedOn(); syncNeedOnline();
  if (!s.remote.exists) throw E('E_NOT_FOUND', 'e.syncNoRemote');
  return syncPullJob(s, mode, s.keyBad, !s.keyBad || old === 'oldpass1234');
});
function syncPullJob(s, mode, keyWasBad, keyOk) {                                                       // 解密发生在任务里: 旧密码不对 -> 任务失败 E_SYNC_KEY (job.code)
  return { ok: true, job: newJob('sync-pull', ['js.syncDownload', 'js.syncDecrypt', 'js.syncValidate', 'js.syncApply'], 4000, { outFrac: 0.7, msg: 'jd.syncPull', fail: !keyOk, failAt: 0.3, code: 'E_SYNC_KEY', failMsg: 'err.E_SYNC_KEY',
    rollback: () => oplog('dashboard', 'sync.pull', kv({ mode, code: keyOk ? 'E_NETWORK' : 'E_SYNC_KEY' }), 'error'),
    done: () => {
      const snap = remoteSnapshot();
      if (mode === 'replace') { M.servers = snap.servers; M.subs = snap.subs; M.overrides = snap.overrides; }
      else {                                                                                            // merge: 服务器 / 订阅 / 覆盖按名称合并, 本机独有的保留
        snap.servers.forEach((x) => { if (!M.servers.some((y) => y.tag === x.tag)) M.servers.push(x); });
        snap.subs.forEach((x) => { if (!M.subs.some((y) => y.name === x.name)) M.subs.push(x); });
        snap.overrides.forEach((x) => { if (!M.overrides.some((y) => y.kind === x.kind && y.value === x.value)) M.overrides.push(x); });
      }
      applyPlan(); applyNow(); s.local = { version: s.remote.version, dirty: false }; s.lastPull = sec();
      if (keyWasBad) { s.keyBad = false; s.remote.version += 1; s.remote.updated = sec(); s.local.version = s.remote.version; s.lastPush = sec(); }   // 用新密钥重新加密并上传
      oplog('dashboard', 'sync.pull', kv({ mode, version: s.local.version }));
      return { vars: { v: s.local.version }, result: { mode, servers: M.servers.length } };
    } }) };
}
route('POST', '/api/sync/clear', () => { syncNeedOnline(); M.sync.remote = Object.assign({}, NO_REMOTE); oplog('dashboard', 'sync.clear', ''); return { ok: true }; });

/* ===================== 9. Clash API (与页面同源, 需要 Authorization: Bearer <令牌>) ===================== */
const baseDelay = (tag) => { const h = hash(tag); return h % 11 === 0 ? 0 : 35 + (h % 290); };     // 0 = 超时 (核心里测不通的节点)
function histOf(tag) {
  const b = baseDelay(tag), out = [];
  for (let i = 0; i < 3; i++) out.push({ time: new Date(now() - (3 - i) * 60000).toISOString(), delay: b ? Math.round(b + rnd(-8, 12)) : 0 });
  return (M.delayHist[tag] || []).concat(out).slice(-5);
}
function buildProxies() {
  const P = {}, ap = M.applied, pins = ap.filter((s) => s.role === 'pin'), autos = ap.filter((s) => s.role === 'auto');
  P.direct = { name: 'direct', type: 'Direct', history: [{ time: new Date().toISOString(), delay: 12 }] };
  pins.concat(autos).forEach((s) => { P[s.tag] = { name: s.tag, type: TYPE_NAME[s.type] || s.type, udp: true, history: histOf(s.tag) }; });
  let best = null; autos.forEach((s) => { const d = baseDelay(s.tag); if (d && (!best || d < baseDelay(best))) best = s.tag; });
  if (autos.length) P.AUTO = { name: 'AUTO', type: 'URLTest', now: best || autos[0].tag, all: autos.map((s) => s.tag), history: [] };
  if (pins.length) P.PIN = { name: 'PIN', type: 'Selector', now: pins.some((s) => s.tag === M.pin) ? M.pin : pins[0].tag, all: pins.map((s) => s.tag), history: [] };
  if (P.PIN || P.AUTO) {
    const all = (P.AUTO ? ['AUTO'] : []).concat(autos.map((s) => s.tag), pins.map((s) => s.tag));
    P.Global = { name: 'Global', type: 'Selector', now: all.indexOf(M.global) >= 0 ? M.global : all[0], all, history: [] };
  }
  const pol = ['PIN', 'Global', 'direct'].filter((t) => P[t]);
  P.Final = { name: 'Final', type: 'Selector', now: pol.indexOf(M.final) >= 0 ? M.final : 'direct', all: ['Global', 'PIN', 'direct'].filter((t) => P[t]), history: [] };
  const pinx = pins.length >= 2 ? ['PINAUTO'].concat(pins.slice(0, 16).map((x) => x.tag)) : [];
  if (pinx.length) P.PINAUTO = { name: 'PINAUTO', type: 'URLTest', now: pins[0].tag, all: pins.slice(0, 16).map((x) => x.tag), history: [] };
  svcList().forEach((e) => { const opts = pol.concat(pinx); P[e.tag] = { name: e.tag, type: 'Selector', now: opts.indexOf(M.svc[e.id]) >= 0 ? M.svc[e.id] : 'direct', all: opts, history: [] }; });
  return P;
}
function applySelector(tag, name) {
  if (tag === 'PIN') M.pin = name; else if (tag === 'Global') M.global = name; else if (tag === 'Final') M.final = name;
  else { const e = svcList().filter((x) => x.tag === tag)[0]; if (!e) return false; M.svc[e.id] = name; }
  return true;
}
function leafOf(P, tag) { let n = 0; while (P[tag] && P[tag].all && P[tag].now && n++ < 8) tag = P[tag].now; return tag; }
/* [域名, 应用, 服务 id, 重流量 (1-3), 强制直连] —— 全是 example.* 的占位域名 */
const SITES = [['api.claude.example.com', 'Claude', 'claude'], ['claude.example.com', 'Claude', 'claude'], ['statsig.claude.example.net', 'Claude', 'claude'], ['chat.example.com', 'ChatGPT', 'chatgpt'], ['cdn.chat.example.net', 'ChatGPT', 'chatgpt'],
  ['www.video.example.net', 'Google Chrome', 'youtube', 1], ['rr3.video.example.net', 'Google Chrome', 'youtube', 3], ['i.video.example.net', 'Google Chrome', 'youtube'], ['repo.example.com', 'Visual Studio Code', 'github'],
  ['api.repo.example.com', 'Visual Studio Code', 'github'], ['objects.repo.example.net', 'Docker Desktop', 'github', 2], ['www.search.example.com', 'Safari', 'google'], ['fonts.search.example.net', 'Safari', 'google'],
  ['web.telegram.example.org', 'Telegram', 'telegram'], ['api.telegram.example.org', 'Telegram', 'telegram'], ['gateway.chat.example.org', 'Discord', 'discord'], ['www.example.com', 'Safari', ''], ['example.org', 'Safari', ''],
  ['cdn.example.net', 'Google Chrome', ''], ['cloud.apple.example.com', 'Safari', 'apple'], ['sync.apple.example.net', '', 'apple'], ['www.cn-site.example.com', 'Google Chrome', '', 0, 1], ['res.wx.example.net', 'WeChat', '', 0, 1],
  ['music.cn.example.net', 'NeteaseMusic', '', 1, 1], ['intranet.example.com', 'Safari', ''], ['api.music.example.com', 'Spotify', 'spotify', 1], ['api.exchange.example.com', 'Google Chrome', 'exchange']];
const procPath = (app) => {
  if (!app) return '';
  const ca = M.apps.filter((a) => a.custom && a.name === app)[0];            // 自定义软件: 进程路径就是它的路径 (.app 要加上 Contents/MacOS/<名称>)
  if (ca) return /\.app$/.test(ca.path) ? ca.path + '/Contents/MacOS/' + app : ca.path;
  if (M.os === 'windows') return app === 'Google Chrome' ? 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe' : 'C:\\Program Files\\' + app + '\\' + app + '.exe';
  return app === 'Google Chrome' ? (Math.random() < 0.5 ? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' : '/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/130.0.0.0/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper')
    : '/Applications/' + app + '.app/Contents/MacOS/' + app;
};
function pickRoute(site) {
  if (!M.proxyOn) return { chains: ['direct-mode'], pol: 'direct', svc: '' };            // 代理总开关关闭: 全部直连 (出口名 direct-mode)
  const host = site[0], app = site[1], svc = M.svc[site[2]] !== undefined ? site[2] : '', P = buildProxies();
  let pol = svc ? M.svc[svc] : M.final, why = site[4] ? 'direct-cn' : (svc ? 'direct' : 'direct'), tg = '';
  if (host === 'intranet.example.com') why = 'direct-lan';
  if (site[4]) pol = 'direct';
  if (M.proxyMode === 'global' && host !== 'intranet.example.com') { if (pol === 'direct' && !svc) pol = P.Global ? 'Global' : (P.PIN ? 'PIN' : 'direct'); }      // 全局代理: 忽略「国内直连 / 最终直连」, 其余仍按你的设置 (固定出口服务 / 应用 / 网站的明确选择)
  if (pol !== 'PIN' && pol !== 'Global' && pol !== 'direct') { tg = pol; pol = 'PIN'; }                                  // 网站开关选了「指定的固定出口 / 固定出口里自动选」
  const ov = M.overrides.filter((o) => o.kind === 'site' && (host === o.value || host.endsWith('.' + o.value)))[0]; if (ov) { pol = POL[ov.state]; tg = ov.state === 'pin' ? (ov.target || '') : ''; why = 'direct-site'; }
  const ap = M.apps.filter((a) => a.name === app)[0];
  if (ap && ap.state === 'direct') { pol = 'direct'; why = 'direct-app'; } else if (ap && (ap.state === 'pin' || ap.state === 'auto')) { pol = POL[ap.state]; tg = ap.state === 'pin' ? (ap.target || '') : ''; }
  const grp = svc ? 'svc-' + svc : 'Final';
  if (pol === 'PIN' && P.PIN) {
    if (tg === 'PINAUTO' && P.PINAUTO) return { chains: [P.PINAUTO.now, 'PINAUTO', grp], pol, svc };
    if (tg && P[tg] && !P[tg].all) return { chains: [tg, grp], pol, svc };
    return { chains: [P.PIN.now, 'PIN', grp], pol, svc };
  }
  if (pol === 'Global' && P.Global) { const lf = leafOf(P, 'Global'); return { chains: P.Global.now === 'AUTO' ? [lf, 'AUTO', 'Global', grp] : [lf, 'Global', grp], pol, svc }; }
  return { chains: svc && !site[4] && why === 'direct' ? ['direct', grp] : [why === 'direct' && !svc && !site[4] ? 'direct' : why], pol: 'direct', svc };
}
function spawnConn(forced) {                                              // forced: 指定站点 (自测用, 不靠随机抽样)
  const cu = M.apps.filter((a) => a.custom), ca = cu.length && Math.random() < 0.1 ? cu[Math.floor(Math.random() * cu.length)] : null;       // 添加了自定义软件之后, 连接里偶尔会出现它 (按它自己的策略走)
  const site = forced || (ca ? ['api.' + (ca.name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'app') + '.example.com', ca.name, ''] : SITES[Math.floor(Math.random() * SITES.length)]), r = pickRoute(site), heavy = site[3] || 0;
  return { id: uuid(), host: site[0], app: site[1], rd: heavy ? rnd(0.3e6, 2.5e6) * (heavy === 3 ? 2 : 1) : rnd(0, 60e3) * (Math.random() < 0.3 ? 0 : 1), ru: rnd(0, 15e3), up: 0, down: 0, start: now(), chains: r.chains,
    ip: '198.51.100.' + (1 + Math.floor(rnd(0, 250))), sport: 50000 + Math.floor(rnd(0, 9000)), rule: r.svc ? 'rule_set=svc-' + r.svc : 'final' };
}
let lastConn = now();
function connections() {
  const dt = (now() - lastConn) / 1000; lastConn = now();
  M.conns.forEach((c) => { const k = rnd(0.2, 1.8); c.down += Math.round(c.rd * k * dt); c.up += Math.round(c.ru * k * dt); });
  M.conns = M.conns.filter(() => Math.random() > 0.04);
  let guard = 0; while (M.conns.length < M.connTarget && guard++ < 500) M.conns.push(spawnConn());
  while (M.conns.length > M.connTarget) M.conns.pop();
  let dT = 0, uT = 0;
  const list = M.conns.map((c) => { dT += c.down; uT += c.up; return { id: c.id, metadata: { network: 'tcp', type: 'mixed', sourceIP: '127.0.0.1', destinationIP: c.ip, sourcePort: String(c.sport), destinationPort: '443', host: c.host, processPath: procPath(c.app) },
    upload: c.up, download: c.down, start: new Date(c.start).toISOString(), chains: c.chains, rule: c.rule, rulePayload: '' }; });
  return { downloadTotal: 8.2e9 + dT, uploadTotal: 0.9e9 + uT, memory: 31e6, connections: list };
}
function fakeAnswers(name, v6) {
  const hh = M.hosts.filter((h) => h.domain === name)[0];                  // 自定义解析优先 (IP 的类型和查询类型不一致时没有答案)
  if (hh) return (hh.ip.indexOf(':') >= 0) === v6 ? [hh.ip] : [];
  const out = []; if (name === 'nxdomain.example.com') return out;
  for (let i = 0, n = 1 + hash(name + 'n') % 3; i < n; i++) { const a = v6 ? '2001:db8::' + (1 + hash(name + i) % 250).toString(16) : '203.0.113.' + (1 + hash(name + i) % 254); if (out.indexOf(a) < 0) out.push(a); }
  return out;
}
async function clashApi(req, res, u, body) {
  const p = u.pathname, q = u.searchParams, J = (o, c) => jsonRes(req, res, c || 200, o), seg = p.split('/').filter(Boolean).map((x) => { try { return decodeURIComponent(x); } catch (e) { return x; } }), P = buildProxies();
  const nocontent = () => { res.writeHead(204, Object.assign({ 'Cache-Control': 'no-store' }, corsHeaders(req))); res.end(); };
  if (p === '/version') return J({ version: 'sing-box ' + M.upd.coreCur, premium: true, meta: true });
  if (p === '/configs') {
    if (req.method === 'PATCH') { let j = {}; try { j = JSON.parse(body); } catch (e) { /* 忽略 */ } if (j && ['Rule', 'Direct'].indexOf(j.mode) >= 0) M.mode = j.mode; return nocontent(); }
    return J({ mode: M.mode, 'mode-list': ['Rule', 'Direct'], port: 0, 'mixed-port': 7890 });
  }
  if (p === '/proxies' && req.method === 'GET') return J({ proxies: P });
  if (seg[0] === 'proxies' && seg.length === 2 && req.method === 'PUT') {
    let j = {}; try { j = JSON.parse(body); } catch (e) { /* 忽略 */ }
    const g = P[seg[1]]; if (!g || !g.all || !j || g.all.indexOf(j.name) < 0) return J({ message: 'Selector not found' }, 400);
    if (!applySelector(seg[1], j.name)) return J({ message: 'Selector not found' }, 400);
    return nocontent();
  }
  if (seg[0] === 'proxies' && seg[2] === 'delay') {
    if (!P[seg[1]]) return J({ message: 'Resource not found' }, 404);
    const tag = leafOf(P, seg[1]), b = tag === 'direct' ? 14 : baseDelay(tag);
    await sleep(b ? rnd(60, 220) : 500);
    if (!b) return J({ message: 'Timeout' }, 504);
    const d = Math.round(b + rnd(-6, 10)); (M.delayHist[tag] = M.delayHist[tag] || []).push({ time: new Date().toISOString(), delay: d }); M.delayHist[tag] = M.delayHist[tag].slice(-3);
    return J({ delay: d });
  }
  if (seg[0] === 'group' && seg[2] === 'delay') { const g = P[seg[1]]; if (!g || !g.all) return J({ message: 'Resource not found' }, 404); const o = {}; g.all.forEach((t) => { const b = baseDelay(t); if (b) o[t] = b; }); return J(o); }
  if (p === '/connections') { if (req.method === 'DELETE') { M.conns = []; return nocontent(); } return J(connections()); }
  if (seg[0] === 'connections' && seg.length === 2 && req.method === 'DELETE') { M.conns = M.conns.filter((c) => c.id !== seg[1]); return nocontent(); }
  if (p === '/dns/query') {                                                // 经核心解析 (Google DoH 风格的 JSON); 这里是确定性的假答案
    const name = (q.get('name') || '').toLowerCase().replace(/\.$/, ''), v6 = /^(AAAA|28)$/i.test(q.get('type') || 'A'), nx = name === 'nxdomain.example.com';
    if (!/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$/.test(name)) return J({ message: 'invalid name' }, 400);
    const ans = fakeAnswers(name, v6).map((a) => ({ name: name + '.', type: v6 ? 28 : 1, TTL: 600, data: a }));
    return J({ Status: nx ? 3 : 0, TC: false, RD: true, RA: true, AD: false, CD: false, Question: [{ name: name + '.', type: v6 ? 28 : 1 }], Answer: ans });
  }
  return J({ ok: false, code: 'E_NOT_FOUND', error: tr(curLang(), 'e.noRoute'), message: 'Not found' }, 404);
}

/* ===================== 10. HTTP 外壳: CORS / 静态文件 / 探测 / 运行时控制 ===================== */
const allowedOrigins = () => ['http://127.0.0.1:' + PORT, 'http://localhost:' + PORT];
function corsHeaders(req) {                                                // 只放行仪表盘自己的来源 (--split 时辅助服务在另一个端口)
  const o = req.headers.origin; if (!SPLIT || !o || allowedOrigins().indexOf(o) < 0) return {};
  return { 'Access-Control-Allow-Origin': o, 'Access-Control-Allow-Headers': 'X-Enana, X-TProxy, X-Enana-Token, X-Enana-Lang, X-Enana-Sudo, Content-Type', 'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Expose-Headers': 'X-Subscription-Userinfo, X-Profile-Update-Interval', 'Access-Control-Max-Age': '600', Vary: 'Origin' };
}
function send(req, res, code, type, body, extra) { res.writeHead(code, Object.assign({ 'Content-Type': type, 'Cache-Control': 'no-store' }, corsHeaders(req), extra)); res.end(body); }
const jsonRes = (req, res, code, obj, extra) => send(req, res, code, 'application/json; charset=utf-8', JSON.stringify(obj), extra);
function readBody(req) {                                                   // 超过 4 MB 的内容丢弃 (照常读完, 由调用方回 413)
  return new Promise((ok) => { const b = []; let n = 0, over = false; req.on('data', (c) => { n += c.length; if (n > MAX_BODY) { over = true; b.length = 0; } else if (!over) b.push(c); }); req.on('end', () => ok({ text: Buffer.concat(b).toString('utf8'), over })); req.on('error', () => ok({ text: '', over })); });
}
/* ---- 应用图标: 运行时生成的 64x64 PNG (只用 node 自带的 zlib + 手写的 PNG 数据块, 没有依赖): 彩色圆角方块 + 由名称哈希决定的白色图形 (不是字母) ---- */
const CRC_T = (() => { const t = []; for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1); t.push(c >>> 0); } return t; })();
const crc32 = (buf) => { let c = 0xFFFFFFFF; for (let i = 0; i < buf.length; i++) c = CRC_T[(c ^ buf[i]) & 255] ^ (c >>> 8); return (c ^ 0xFFFFFFFF) >>> 0; };
function pngChunk(type, data) {
  const len = Buffer.alloc(4), crc = Buffer.alloc(4), body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  len.writeUInt32BE(data.length, 0); crc.writeUInt32BE(crc32(body), 0); return Buffer.concat([len, body, crc]);
}
const GLYPHS = [                                                           // 坐标 x / y 在 [-1, 1] (y 向下), 返回 true = 白色
  (x, y) => { const r = Math.sqrt(x * x + y * y); return r > 0.4 && r < 0.62; },                                   // 圆环
  (x, y) => x * x + y * y < 0.25,                                                                                  // 实心圆
  (x, y) => (Math.abs(x) < 0.15 && Math.abs(y) < 0.56) || (Math.abs(y) < 0.15 && Math.abs(x) < 0.56),              // 加号
  (x, y) => Math.abs(x) + Math.abs(y) < 0.6,                                                                       // 菱形
  (x, y) => y > -0.5 && y < 0.5 && Math.abs(x) < (y + 0.5) * 0.52,                                                 // 三角
  (x, y) => Math.abs(y) < 0.52 && (Math.abs(x + 0.24) < 0.1 || Math.abs(x - 0.24) < 0.1),                          // 两竖
  (x, y) => { const a = Math.abs(x) - 0.27, b = Math.abs(y) - 0.27; return a * a + b * b < 0.03; },                // 四个点
  (x, y) => Math.abs(y) < 0.56 && Math.abs(x - (0.3 - Math.abs(y))) < 0.11,                                         // 箭头 >
  (x, y) => { const r = Math.sqrt(x * x + y * y); return r < 0.14 || (r > 0.38 && r < 0.56); },                    // 靶心
  (x, y) => { const m = Math.max(Math.abs(x), Math.abs(y)); return m > 0.34 && m < 0.54; },                        // 方框
  (x, y) => y > 0 && x * x + y * y < 0.26,                                                                         // 半圆
  (x, y) => Math.abs(x) < 0.52 && (Math.abs(y) < 0.07 || Math.abs(y - 0.3) < 0.07 || Math.abs(y + 0.3) < 0.07),   // 三条横线
  (x, y) => Math.abs(x + y) < 0.2 && Math.abs(x - y) < 0.7];                                                       // 斜杠
function hsl(h, s, l) { h = (h % 360) / 360; const a = s * Math.min(l, 1 - l), f = (n) => { const k = (n + h * 12) % 12; return l - a * Math.max(-1, Math.min(k - 3, 9 - k, 1)); }; return [f(0), f(8), f(4)].map((v) => Math.round(v * 255)); }
const ICON_CACHE = Object.create(null);
function iconPng(name) {                                                   // 96x96 (和 lib/appicon.js 的输出一样大)
  if (ICON_CACHE[name]) return ICON_CACHE[name];
  const W = 96, SS = 4, C = W / 2, HALF = C - 3, R = 21, GS = HALF - 3, rn = mulberry(hash('appicon-png|' + name)), glyph = GLYPHS[Math.floor(rn() * GLYPHS.length)], hue = Math.floor(rn() * 360), sat = 0.55 + rn() * 0.2, lit = 0.42 + rn() * 0.08;
  const top = hsl(hue, sat, Math.min(0.62, lit + 0.1)), bot = hsl(hue, sat, Math.max(0.28, lit - 0.08)), stride = W * 4 + 1, raw = Buffer.alloc(stride * W);
  for (let py = 0; py < W; py++) {                                         // 每个像素 4x4 超采样 (圆角和图形的边缘都是抗锯齿的); 每行开头一个滤镜字节 0 = None
    for (let px = 0; px < W; px++) {
      let n = 0, rr = 0, gg = 0, bb = 0;
      for (let sy = 0; sy < SS; sy++) for (let sx = 0; sx < SS; sx++) {
        const X = px + (sx + 0.5) / SS, Y = py + (sy + 0.5) / SS, dx = Math.abs(X - C) - (HALF - R), dy = Math.abs(Y - C) - (HALF - R), ex = Math.max(dx, 0), ey = Math.max(dy, 0);
        if (Math.sqrt(ex * ex + ey * ey) + Math.min(Math.max(dx, dy), 0) > R) continue;      // 圆角方块之外 (透明)
        const f = (Y - 3) / (W - 6), white = glyph((X - C) / GS, (Y - C) / GS); n++;
        rr += white ? 255 : top[0] + (bot[0] - top[0]) * f; gg += white ? 255 : top[1] + (bot[1] - top[1]) * f; bb += white ? 255 : top[2] + (bot[2] - top[2]) * f;
      }
      if (n) { const o = py * stride + 1 + px * 4; raw[o] = Math.round(rr / n); raw[o + 1] = Math.round(gg / n); raw[o + 2] = Math.round(bb / n); raw[o + 3] = Math.round(n * 255 / (SS * SS)); }
    }
  }
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(W, 0); ihdr.writeUInt32BE(W, 4); ihdr[8] = 8; ihdr[9] = 6;          // 96x96, 8 位 RGBA, 无交错
  const png = Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), pngChunk('IHDR', ihdr), pngChunk('IDAT', zlib.deflateSync(raw)), pngChunk('IEND', Buffer.alloc(0))]);
  if (Object.keys(ICON_CACHE).length > 400) Object.keys(ICON_CACHE).forEach((k) => { delete ICON_CACHE[k]; });
  ICON_CACHE[name] = png; return png;
}
function serveIcon(req, res, slug) {                                       // GET /ui/appicons/<slug>.png: 只给「已经提取出来」的图标 (没到时间 / 取不到 / 宣称有但 404 的应用都是 404)
  const name = iconNameFor(slug); if (!name) return notFound(req, res);
  return send(req, res, 200, 'image/png', iconPng(name));
}
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.json': 'application/json; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg',
  '.ico': 'image/x-icon', '.woff2': 'font/woff2', '.txt': 'text/plain; charset=utf-8', '.map': 'application/json; charset=utf-8', '.webmanifest': 'application/manifest+json' };
const envJson = () => ({ apiBase: SPLIT ? 'http://' + HOST + ':' + HPORT : '', apiPort: HPORT, proxyPort: 7890, uiPort: PORT, version: M.upd.cur,
  probe: { speedUrl: '/mock/down?bytes=10000000', delayUrl: '/mock/gen204' } });
const notFound = (req, res, lang) => jsonRes(req, res, 404, { ok: false, code: 'E_NOT_FOUND', error: tr(lang || 'zh', 'e.noRoute'), message: 'Not found' });
const PAGES = ['overview', 'apps', 'sites', 'rules', 'dns', 'servers', 'conns', 'traffic', 'speed', 'logs', 'settings', 'login', 'register'];     // 页面路由: /ui/apps 等直接给 index.html (和真机的 /enana/admin/apps 一样)
function serveUi(req, res, u) {
  let rel; try { rel = decodeURIComponent(u.pathname.replace(/^\/(?:ui|enana\/admin)\/?/, '')) || 'index.html'; } catch (e) { return jsonRes(req, res, 400, { ok: false, code: 'E_INVALID', error: tr('zh', 'e.badReq') }); }
  if (rel.indexOf('\0') >= 0) return jsonRes(req, res, 400, { ok: false, code: 'E_INVALID', error: tr('zh', 'e.badReq') });
  if (PAGES.indexOf(rel) >= 0) rel = 'index.html';
  if (rel === 'env.json') return jsonRes(req, res, 200, envJson());
  if (rel === 'catalog.json') return jsonRes(req, res, 200, catalogNow());
  if (rel.indexOf('appicons/') === 0 && /\.png$/i.test(rel)) return serveIcon(req, res, rel.slice(9, -4));       // 运行时生成的应用图标 (不读磁盘)
  const file = path.resolve(UI, rel);
  if (file !== UI && file.indexOf(UI + path.sep) !== 0) return jsonRes(req, res, 403, { ok: false, code: 'E_NOT_FOUND', error: 'forbidden' });
  fs.readFile(file, (err, buf) => {
    if (err) return notFound(req, res);
    send(req, res, 200, MIME[path.extname(file).toLowerCase()] || 'application/octet-stream', buf);
  });
}
async function mockCtl(req, res, u) {
  const body = req.method === 'POST' ? (await readBody(req)).text : '', q = new URLSearchParams(u.search), warn = [], g = (k) => q.get(k);
  if (body && body.indexOf('=') >= 0) new URLSearchParams(body).forEach((v, k) => { q.set(k, v); });
  const sw = (k, vals, fn) => { if (q.has(k)) { if (vals.indexOf(g(k)) >= 0) fn(g(k)); else warn.push(k + '=' + g(k)); } };
  if (q.has('reset')) reset(g('reset') === 'first-run' ? 'first-run' : 'full');           // 先重置, 同一个请求里的其它开关再生效
  settle();
  sw('helper', ['down', 'up'], (v) => { M.helperDown = v === 'down'; if (v === 'up') M.helperWin = null; });
  sw('clash', ['down', 'up'], (v) => { M.clashDown = v === 'down'; M.env.service = v !== 'down'; });
  if (q.has('conns')) M.connTarget = Math.max(0, Math.min(2000, num(g('conns'), 0)));
  sw('os', ['windows', 'darwin'], (v) => { M.os = v; M.conns = []; });
  sw('net', NET_STATES, (v) => { M.net = v; M.netChecked = v === 'none' ? 0 : (M.netChecked || sec() - 60); });
  sw('central', ['up', 'down'], (v) => { M.central = v; });
  sw('lastacct', ['none', 'demo', 'other'], (v) => { M.lastAcct = v === 'none' ? null : cacheRec(v + '@example.com', ACCOUNTS[v + '@example.com'].pw); });
  sw('proxy', ['on', 'off'], (v) => { if (M.proxyOn !== (v === 'on')) { M.proxyOn = v === 'on'; M.conns = []; } });
  sw('proxymode', ['auto', 'global'], (v) => { if (M.proxyMode !== v) { M.proxyMode = v; if (M.proxyOn) M.conns = []; } });
  if (g('lock') === 'reset') { M.fails = []; M.regs = []; M.lockUntil = 0; }
  if (q.has('locksec')) M.locksec = Math.max(1, num(g('locksec'), 300));
  if (g('expire') === '1') { M.secret = randHex(16); sudoClear(); }
  sw('update', ['on', 'off', 'fail'], (v) => { if (v === 'on') { M.upd.cur = BASE_APP; M.upd.coreCur = BASE_CORE; M.upd.on = true; M.upd.fail = false; } else if (v === 'off') { M.upd.on = false; M.upd.fail = false; } else M.upd.fail = true; });
  if (q.has('failnext')) { const v = g('failnext'); if (v[0] === '/') M.failNext.push(v); else if (v === '1') M.failJob = true; else warn.push('failnext=' + v); }
  sw('stats', ['normal', 'short', 'empty'], (v) => { M.stats = v; });
  if (g('statsfail') === '1') M.failNext.push('/api/stats');              // 和 failnext=/api/stats 一样: 下一个 /api/stats 请求失败一次 (E_NETWORK)
  sw('speedlast', ['seed', 'none'], (v) => { if (v === 'seed') seedSpeedLast(); else { M.speed.last = null; Object.keys(M.speed.byId).forEach((k) => { if (!M.speed.running || M.speed.running.id !== k) delete M.speed.byId[k]; }); } });
  sw('env', ['bad', 'ok'], (v) => {
    M.rs.forEach((s) => { if (v === 'ok' ? s.enabled : (s.tag === 'geosite-cn' || s.tag === 'geoip-cn')) { s.present = v === 'ok'; s.bytes = v === 'ok' ? ruleSize(s.tag) : 0; } });
    M.env.sysproxy = v === 'ok'; M.env.shortcut = v === 'ok';
  });
  if (g('stale') && M.subs[0]) M.subs[0].updated = sec() - 30 * 3600;
  sw('devices', ['free', 'full', 'reset'], (v) => {
    if (v === 'reset') { M.devices = seedDevices(); if (M.account) setThisOnline(M.account, true); return; }
    const air = devicesOf('demo@example.com').filter((d) => d.uid === 'd-air')[0]; if (air) { air.online = v === 'full'; air.revoked = false; air.last_seen = sec() - (v === 'full' ? 20 : 5 * 3600); }
    const mbp = devicesOf('demo@example.com').filter((d) => d.uid === 'd-mbp')[0]; if (mbp) { mbp.online = true; mbp.revoked = false; mbp.last_seen = sec() - 90; }
  });
  if (g('kickme') === '1' || g('kickme') === 'password') {               // 模拟「这台电脑被账号下的另一台设备下线了」(kickme=password: 因为另一台设备改了密码): 令牌全部失效, 代理关闭, 登录框上显示提示 (notice + notice_code)
    const pwc = g('kickme') === 'password';
    M.secret = randHex(16); sudoClear(); M.proxyOn = false; M.account = null; M.conns = []; setThisOnline(null, false); M.notice = pwc ? { key: 'notice.pwChanged', code: 'password_changed' } : { key: 'notice.kicked', code: 'kicked' };
    const t = now(); M.clashWins.push([t + D(150), t + D(150 + 2500)]);
  }
  if (q.has('notice')) M.notice = g('notice') ? { text: g('notice').slice(0, 300) } : null;
  sw('vps', ['reset'], () => { M.vps = []; });
  sw('vpsport', ['open', 'closed'], (v) => { M.vpsOpen = v === 'open'; });                     // 203.0.113.70 部署: closed (默认) = 验证连通失败 E_VPS_VERIFY, open = 成功
  sw('plan', ['soon', 'free', 'pro', 'expired'], (v) => { M.plan = v; applyPlan(); });          // 套餐: soon (默认, 官方线路即将推出) / free / pro (多出 2 个官方节点) / expired
  if (q.has('prefs')) {                                                    // prefs=reset: 清空 (version 0); prefs=bump: 模拟另一台设备同步来的改动 (version + 1, 并写入 "ui.fromOtherDevice": true)
    const v = g('prefs');
    if (v === 'reset') M.prefs = { obj: {}, version: 0, updated: 0 };
    else if (v === 'bump') { M.prefs.obj['ui.fromOtherDevice'] = true; M.prefs = { obj: M.prefs.obj, version: M.prefs.version + 1, updated: sec() }; }
    else warn.push('prefs=' + v);
  }
  if (q.has('sudottl')) M.sudoTtl = Math.max(1, Math.min(86400, num(g('sudottl'), 300)));      // 步骤验证令牌的有效期 (真实秒数, 默认 300)
  sw('sudo', ['clear'], () => { sudoClear(); });                                                // 让所有步骤验证令牌立刻失效
  sw('icons', ['progressive', 'all', 'none'], (v) => { M.icons = v; });                         // 应用图标: 陆续出现 (默认) / 全部立刻有 / 全部没有
  sw('sync', ['reset'], () => { M.sync = syncInit(M.servers.length === 0); });
  sw('syncremote', ['none', 'exists', 'newer'], (v) => {
    const s = M.sync, base = Math.max(1, s.local.version);
    s.remote = v === 'none' ? Object.assign({}, NO_REMOTE) : { exists: true, version: v === 'newer' ? s.local.version + 1 : base, updated: sec() - (v === 'newer' ? 86400 : 3600), size: 2048, device: 'MacBook-Pro' };
  });
  sw('synckey', ['ok', 'bad'], (v) => { M.sync.keyBad = v === 'bad'; });
  sw('syncoffline', ['0', '1'], (v) => { M.sync.offline = v === '1'; });
  if (q.has('tick')) liveTick(Math.max(0, Math.min(500, num(g('tick'), 1))));
  if (g('newapp')) M.pendingApps.push(g('newapp').slice(0, 80));
  jsonRes(req, res, 200, { ok: true, helper: helperIsDown() ? 'down' : 'up', clash: clashIsDown() ? 'down' : 'up', helperDown: M.helperDown, clashDown: M.clashDown, conns: M.connTarget, os: M.os, net: M.net, central: M.central,
    lastacct: M.lastAcct ? (M.lastAcct.email === 'demo@example.com' ? 'demo' : M.lastAcct.email === 'other@example.com' ? 'other' : 'custom') : 'none', proxy: M.proxyOn ? 'on' : 'off', proxymode: M.proxyMode, account: M.account ? maskEmail(M.account) : '', locked: lockWait(), locksec: M.locksec,
    devices: Object.keys(M.devices).reduce((o, e) => { o[maskEmail(e)] = M.devices[e].filter((d) => d.online).map((d) => d.uid); return o; }, {}), notice: M.notice ? noticeText('en') : '',
    vps: M.vps.length, sync: { enabled: M.sync.enabled, remote: M.sync.remote.exists ? (M.sync.remote.version > M.sync.local.version ? 'newer' : 'exists') : 'none', key: M.sync.keyBad ? 'bad' : 'ok', offline: M.sync.offline, dirty: M.sync.local.dirty }, autoUpdate: M.autoUpdate,
    update: M.upd.fail ? 'fail' : M.upd.on ? 'on' : 'off', failnext: M.failNext.concat(M.failJob ? ['1'] : []), failNext: M.failJob, speedlast: M.speed.last ? M.speed.last.id : 'none', servers: M.servers.length, firstRun: M.servers.length === 0,
    stats: M.stats, version: M.upd.cur, core: M.upd.coreCur, lang: M.langSet || 'zh', fast: FAST, split: SPLIT, plan: M.plan, prefs: { version: M.prefs.version, keys: Object.keys(M.prefs.obj).length }, sudo: { tokens: Object.keys(M.sudo).length, ttl: M.sudoTtl },
    icons: M.icons, vpsport: M.vpsOpen ? 'open' : 'closed', warnings: warn });
}
async function mockEntry(req, res, u) {
  const p = u.pathname;
  if (p === '/mock/ctl') return mockCtl(req, res, u);
  if (p === '/mock/gen204') { res.writeHead(204, { 'Cache-Control': 'no-store' }); return res.end(); }
  if (p === '/mock/down') {
    const total = Math.min(num(u.searchParams.get('bytes'), 1e7), 5e7), chunk = Buffer.alloc(100000, 97); let sent = 0;
    res.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Length': total, 'Cache-Control': 'no-store' });
    const t = setInterval(() => { const n = Math.min(chunk.length, total - sent); res.write(n === chunk.length ? chunk : chunk.subarray(0, n)); sent += n; if (sent >= total) { clearInterval(t); res.end(); } }, 25);
    res.on('close', () => clearInterval(t)); return;
  }
  return notFound(req, res);
}
/* 辅助服务入口. 检查顺序同 lib/api.sh: 请求头 (403) -> 请求体大小 (413) -> 路由 (404) -> 令牌 (401) -> sudo (403, 仅白名单里的接口) -> 处理 */
async function helperEntry(req, res, u) {
  if (req.method === 'OPTIONS') { res.writeHead(204, corsHeaders(req)); return res.end(); }
  settle();
  if (helperIsDown()) return req.socket.destroy();                         // 模拟「辅助服务没在运行」: 直接断开连接
  const hdrLang = ['zh', 'en'].indexOf(req.headers['x-enana-lang']) >= 0 ? req.headers['x-enana-lang'] : '', lang = hdrLang || M.langSet || 'zh';
  const fail = (e) => jsonRes(req, res, e.status, Object.assign({ ok: false, error: tr(lang, e.key || ('err.' + e.code), Object.assign({}, e.extra, e.vars)), code: e.code }, e.extra));
  if (req.headers['x-enana'] !== '1' && req.headers['x-tproxy'] !== '1') return fail(E('E_INVALID', 'e.header', null, null, 403));
  const body = await readBody(req);
  if (body.over) return fail(E('E_INVALID', 'e.tooLarge', null, null, 413));
  const key = req.method + ' ' + u.pathname, r = R[key];
  if (!r) return fail(E('E_NOT_FOUND', 'e.noRoute', null, null, 404));
  if (!r.pub && req.headers['x-enana-token'] !== M.secret) return fail(E('E_AUTH', null, null, null, 401));
  if (SUDO_ROUTES[key] && !sudoOk(req)) return fail(E('E_SUDO_REQUIRED', null, null, null, 403));       // 401 之后、接口自己的校验之前
  const ct = String(req.headers['content-type'] || ''), form = Object.create(null);
  if (/x-www-form-urlencoded/i.test(ct) || (!ct && body.text.indexOf('=') >= 0 && !/^\s*[\[{<-]/.test(body.text))) new URLSearchParams(body.text).forEach((v, k) => { form[k] = v; });
  const has = (n) => Object.prototype.hasOwnProperty.call(form, n) || u.searchParams.has(n);
  const c = { req, q: u.searchParams, body: body.text, form, lang, hdrLang, failOnce: false, has, p: (n) => (Object.prototype.hasOwnProperty.call(form, n) ? form[n] : (u.searchParams.has(n) ? u.searchParams.get(n) : '')) };
  const fk = M.failNext.findIndex((x) => u.pathname.indexOf(x) === 0);     // failnext=/api/路径: 该路径的下一个请求失败一次
  if (fk >= 0) { M.failNext.splice(fk, 1); if (u.pathname === '/api/update/check') c.failOnce = true; else return fail(E('E_NETWORK')); }
  try {
    const out = await r.fn(c);
    if (out instanceof Raw) { res.writeHead(out.status, Object.assign({ 'Content-Type': out.type, 'Cache-Control': 'no-store' }, corsHeaders(req), out.headers)); return res.end(out.body); }
    return jsonRes(req, res, 200, out);
  } catch (e) {
    if (e instanceof ApiErr) return fail(e);
    console.error('mock-server: handler error on ' + key + ': ' + safeErr(e));                                  // 不打印请求体 / 密码 / 令牌
    return jsonRes(req, res, 200, { ok: false, code: 'E_INVALID', error: tr(lang, 'e.internal') });
  }
}
async function clashEntry(req, res, u) {
  settle();
  if (clashIsDown()) return req.socket.destroy();                          // 核心没在运行 / 正在重启
  const l = req.headers['x-enana-lang'] === 'en' ? 'en' : (M.langSet || 'zh');
  if ((req.headers.authorization || '') !== 'Bearer ' + M.secret) return jsonRes(req, res, 401, { ok: false, code: 'E_AUTH', error: tr(l, 'err.E_AUTH'), message: 'Unauthorized' });
  const fk = M.failNext.findIndex((x) => u.pathname.indexOf(x) === 0);     // failnext=/proxies ... 也适用于 Clash API (HTTP 502)
  if (fk >= 0) { M.failNext.splice(fk, 1); return jsonRes(req, res, 502, { ok: false, code: 'E_NETWORK', error: tr(l, 'err.E_NETWORK'), message: 'Bad Gateway' }); }
  return clashApi(req, res, u, (await readBody(req)).text);
}
async function mainHandler(req, res) {
  let u; try { u = new URL(req.url, 'http://x'); } catch (e) { return jsonRes(req, res, 400, { ok: false, code: 'E_INVALID', error: tr('zh', 'e.badReq') }); }
  const p = u.pathname;
  if (req.method === 'OPTIONS') { res.writeHead(204, corsHeaders(req)); return res.end(); }
  if (p === '/') { res.writeHead(302, { Location: '/ui/' }); return res.end(); }
  if (p === '/ui') { res.writeHead(302, { Location: '/ui/' }); return res.end(); }
  if (p === '/enana/admin') { res.writeHead(302, { Location: '/enana/admin/' }); return res.end(); }
  if (p === '/favicon.ico') { try { const b = fs.readFileSync(path.join(UI, 'favicon.png')); res.writeHead(200, { 'Content-Type': 'image/png', 'Content-Length': b.length }); return res.end(b); } catch (e) { res.writeHead(204); return res.end(); } }
  if (p.indexOf('/mock/') === 0) return mockEntry(req, res, u);
  if (p.indexOf('/ui/') === 0 || p.indexOf('/enana/admin/') === 0) return serveUi(req, res, u);
  if (p.indexOf('/api/') === 0) { if (SPLIT) return jsonRes(req, res, 404, { ok: false, code: 'E_NOT_FOUND', error: 'The helper API is on port ' + HPORT + ' in --split mode', message: 'Not found' }); return helperEntry(req, res, u); }
  return clashEntry(req, res, u);
}
const guard = (fn) => (req, res) => { fn(req, res).catch((e) => { console.error('mock-server: ' + safeErr(e)); try { res.writeHead(500); res.end(); } catch (x) { /* 忽略 */ } }); };
const makeMain = () => http.createServer(guard(mainHandler));
const makeHelper = () => http.createServer(guard(async (req, res) => {
  let u; try { u = new URL(req.url, 'http://x'); } catch (e) { return jsonRes(req, res, 400, { ok: false, code: 'E_INVALID', error: tr('zh', 'e.badReq') }); }
  if (u.pathname.indexOf('/api/') !== 0 && req.method !== 'OPTIONS') return notFound(req, res);
  return helperEntry(req, res, u);
}));
const listenOn = (srv, port) => new Promise((ok, bad) => { const onErr = (e) => bad(e); srv.once('error', onErr); srv.listen(port, HOST, () => { srv.removeListener('error', onErr); ok(port); }); });

/* ===================== 11. 自测: node tools/mock-server.js --selftest (在 18090-18099 里找空闲端口, 时间加速, 失败则退出码非 0) ===================== */
const OPS_CODES = ['policy.switch', 'conns.kill', 'logs.bundle', 'autosite.add', 'autosite.clear', 'apps.found', 'login', 'login.fail', 'logout', 'proxy.on', 'proxy.off', 'proxy.mode', 'override.set', 'override.delete', 'apps.scan', 'apps.adopt', 'apps.ack', 'servers.import', 'servers.delete', 'servers.role', 'sub.save', 'sub.delete',
  'sub.refresh', 'rules.update', 'rules.toggle', 'rules.custom.add', 'rules.custom.delete', 'dns.set', 'dns.test', 'settings.set', 'logs.clear', 'update.apply', 'restart', 'install', 'upgrade', 'uninstall', 'start', 'stop',
  'net.refresh', 'speedtest.start', 'speedtest.stop', 'vps.probe', 'vps.provision', 'vps.forget', 'vps.redetect', 'sync.settings', 'sync.push', 'sync.pull', 'sync.clear', 'devices.kick',
  'auth.verify', 'secret.view', 'backup.export', 'password.change', 'sites.domain', 'sites.reset', 'apps.custom.add', 'apps.custom.delete', 'speed.target', 'speed.targets.reset', 'dns.hosts', 'dns.hosts.reset', 'dns.bench'];
async function selftest() {
  let srv = null, helperSrv = null;
  for (let p = 18090; p <= 18099 && !srv; p++) { const s = makeMain(); try { await listenOn(s, p); srv = s; PORT = p; HPORT = p; } catch (e) { if (e.code !== 'EADDRINUSE') throw e; } }
  if (!srv) { console.log('FAIL  no free port in 18090-18099'); return 1; }
  reset('full'); setInterval(settle, 150).unref();
  let pass = 0, bad = 0, T = ''; const tStart = tsOf(now()), F0 = FAST;            // 对时间敏感的片段 (测速 / 更新) 临时放慢到 8 倍, 机器忙的时候也不会漏掉中间状态
  const ck = (name, cond, info) => { if (cond) { pass++; console.log('ok    ' + name); } else { bad++; console.log('FAIL  ' + name + (info === undefined ? '' : '  -> ' + String(typeof info === 'string' ? info : JSON.stringify(info)).slice(0, 220))); } };
  const nap = (ms) => new Promise((ok) => setTimeout(ok, ms));
  const rq = (method, p, o) => new Promise((ok) => {
    o = o || {}; const headers = Object.assign({}, o.noHdr ? {} : { 'X-Enana': '1' }, o.token ? { 'X-Enana-Token': o.token } : {}, o.lang ? { 'X-Enana-Lang': o.lang } : {}, o.headers || {});
    let body = o.body; if (o.form) { body = new URLSearchParams(o.form).toString(); headers['Content-Type'] = 'application/x-www-form-urlencoded'; } else if (body != null) headers['Content-Type'] = 'text/plain;charset=UTF-8';
    if (body != null) headers['Content-Length'] = Buffer.byteLength(body);
    if (o.q) p += (p.indexOf('?') < 0 ? '?' : '&') + new URLSearchParams(o.q).toString();
    const r = http.request({ host: HOST, port: o.port || PORT, method, path: p, headers, agent: false }, (rs) => {
      const b = []; rs.on('data', (d) => b.push(d)); rs.on('end', () => { const buf = Buffer.concat(b), text = buf.toString('utf8'); let json = null; if (/^\s*[{\[]/.test(text)) { try { json = JSON.parse(text); } catch (e) { /* 纯文本 */ } } ok({ status: rs.statusCode, headers: rs.headers, text, json, buf }); });
    });
    r.on('error', (e) => ok({ status: 0, error: e.code || String(e.message), headers: {}, text: '', json: null })); r.end(body);
  });
  let CURPW = 'demo1234';                                                  // 当前登录账号的密码 (步骤验证用)
  const api = async (method, p, o) => {                                    // 白名单里的接口自动带上新的 sudo 令牌; 想测 403 的传 {sudo:false}
    o = Object.assign({ token: T }, o);
    if (o.sudo !== false && SUDO_ROUTES[method + ' ' + p.split('?')[0]] && !(o.headers && o.headers['X-Enana-Sudo'])) { const v = await rq('POST', '/api/auth/verify', { token: o.token, form: { password: CURPW } }); if (v.json && v.json.sudo) o.headers = Object.assign({ 'X-Enana-Sudo': v.json.sudo }, o.headers); }
    return rq(method, p, o);
  };
  const jx = (r) => r.json || {};
  const ctl = (qs) => rq('GET', '/mock/ctl?' + qs, { noHdr: true });
  const login = (user, password) => rq('POST', '/api/login', { form: { user, password } });
  const waitJob = async (id, lang) => { for (let i = 0; i < 600; i++) { const r = await api('GET', '/api/job', { q: { id }, lang }); if (r.json && r.json.state && r.json.state !== 'running') return r.json; await nap(15); } return { state: 'timeout' }; };
  const run = async (r) => (r.json && r.json.job ? waitJob(r.json.job) : { state: 'nojob' });
  const logs = (q) => api('GET', '/api/logs', { q });
  const clash = (method, p, body) => rq(method, p, { noHdr: true, headers: { Authorization: 'Bearer ' + T }, body: body == null ? undefined : JSON.stringify(body) });
  const clashR = async (method, p, body) => { let x; for (let i = 0; i < 150; i++) { x = await clash(method, p, body); if (x.status) break; await nap(20); } return x; };      // 配置刚应用完时核心还在重启: 等它回来
  const D1 = 'demo@example.com', P1 = 'demo1234', D2 = 'other@example.com', P2 = 'other1234';

  /* ---- 请求头 / 令牌 / 登录 / 注册 / 退出 / 代理总开关 ---- */
  let r2, r = await rq('GET', '/api/auth/status', { noHdr: true });
  ck('403 without X-Enana, JSON error with code', r.status === 403 && jx(r).ok === false && !!jx(r).code && !!jx(r).error, r.text);
  r = await rq('GET', '/api/auth/status', { noHdr: true, headers: { 'X-TProxy': '1' } });
  ck('legacy X-TProxy header still accepted', r.status === 200 && jx(r).ok === true);
  r = await rq('GET', '/api/auth/status');
  ck('auth/status shape: hint of the last account, offline_ok false until someone is logged in on this machine, empty notice, no binding fields', jx(r).required === true && jx(r).account_hint === 'd***@e***.com' && jx(r).offline_ok === false && jx(r).notice === '' && jx(r).account_url === 'https://enana.cc'
    && jx(r).register_url === 'https://enana.cc/register' && jx(r).manage_url === 'https://enana.cc/account' && jx(r).wait === 0 && !('bound' in jx(r)) && !('forgot_url' in jx(r)), r.text);
  r = await rq('GET', '/api/state'); ck('state without token -> 401 E_AUTH', r.status === 401 && jx(r).code === 'E_AUTH' && jx(r).ok === false);
  r = await rq('GET', '/api/state', { token: 'wrong' }); ck('state with a wrong token -> 401', r.status === 401);
  r = await login('no-at-sign', ''); ck('login: invalid format -> E_INVALID', jx(r).code === 'E_INVALID' && r.status === 200);
  r = await login(D1, 'nope'); ck('login: wrong password -> E_BAD_CREDENTIALS', jx(r).code === 'E_BAD_CREDENTIALS' && !!jx(r).error);
  r = await login(D2, P2); T = jx(r).token;
  ck('login: any valid account works (no binding), token + via online', jx(r).ok === true && /^[0-9a-f]{32}$/.test(T) && jx(r).account === D2 && jx(r).via === 'online' && !('bound_now' in jx(r)), r.text.replace(T, '<token>'));
  r = await rq('GET', '/api/auth/status'); ck('auth/status hint follows the last account that logged in', jx(r).account_hint === 'o***@e***.com');
  await ctl('locksec=2'); let last;
  for (let i = 0; i < 5; i++) last = await login(D1, 'x' + i);
  r = await login(D1, P1); ck('login: 5 failures lock the next attempt (E_LOCKED + wait)', jx(last).code === 'E_BAD_CREDENTIALS' && jx(r).code === 'E_LOCKED' && jx(r).wait >= 1, r.text);
  r = await rq('GET', '/api/auth/status'); ck('auth/status wait > 0 while locked', jx(r).wait >= 1);
  r = await rq('POST', '/api/register', { form: { user: 'late@example.com', password: 'longenough1' } }); ck('register is locked too (shared limiter)', jx(r).code === 'E_LOCKED' && jx(r).wait >= 1);
  await ctl('lock=reset'); r = await login(D1, P1); T = jx(r).token; ck('lock=reset clears the lockout; success resets the counter', jx(r).ok === true);
  await ctl('lastacct=demo&central=down');
  r = await login(D1, P1); ck('central down: last account logs in offline (via=offline)', jx(r).ok === true && jx(r).via === 'offline' && /^[0-9a-f]{32}$/.test(jx(r).token));
  r = await login(D1, 'wrong-pass'); ck('central down: last account + wrong password -> E_BAD_CREDENTIALS', jx(r).code === 'E_BAD_CREDENTIALS');
  r = await login(D2, P2); ck('central down: another account -> E_ACCOUNT_UNREACHABLE', jx(r).code === 'E_ACCOUNT_UNREACHABLE');
  r = await rq('POST', '/api/register', { form: { user: 'new1@example.com', password: 'longenough1' } }); ck('central down: register -> E_ACCOUNT_UNREACHABLE', jx(r).code === 'E_ACCOUNT_UNREACHABLE');
  await ctl('lastacct=none&lock=reset'); r = await login(D1, P1); ck('central down + nobody logged in before -> E_ACCOUNT_UNREACHABLE', jx(r).code === 'E_ACCOUNT_UNREACHABLE');
  await ctl('central=up&lastacct=demo&lock=reset');
  r = await rq('POST', '/api/register', { form: { user: 'bad-email', password: 'longenough1' } }); ck('register: bad email -> E_INVALID', jx(r).code === 'E_INVALID');
  r = await rq('POST', '/api/register', { form: { user: 'new1@example.com', password: 'short' } }); ck('register: password < 8 -> E_WEAK_PASSWORD', jx(r).code === 'E_WEAK_PASSWORD');
  r = await rq('POST', '/api/register', { form: { user: D1, password: 'longenough1' } }); ck('register: existing email -> E_EMAIL_TAKEN', jx(r).code === 'E_EMAIL_TAKEN');
  r = await rq('POST', '/api/register', { form: { user: 'New1@Example.com', password: 'longenough1' } }); T = jx(r).token;
  ck('register: new email creates the account and logs in', jx(r).ok === true && jx(r).registered === true && jx(r).account === 'new1@example.com' && jx(r).via === 'online' && /^[0-9a-f]{32}$/.test(T));
  r = await login('new1@example.com', 'longenough1'); ck('the registered account can log in again', jx(r).ok === true);
  await ctl('lock=reset&locksec=2'); for (let i = 0; i < 5; i++) last = await rq('POST', '/api/register', { form: { user: D1, password: 'longenough1' } });
  r = await rq('POST', '/api/register', { form: { user: 'new2@example.com', password: 'longenough1' } }); ck('register: 5 attempts in 5 minutes -> E_LOCKED + wait', jx(last).code === 'E_EMAIL_TAKEN' && jx(r).code === 'E_LOCKED' && jx(r).wait >= 1);
  await ctl('lock=reset&locksec=300'); r = await login(D1, P1); T = jx(r).token;
  /* (密码修改 / 步骤验证 / 偏好 / 套餐 的检查在文件靠后的「新增接口」一节) */
  r = await rq('POST', '/api/proxy', { form: { on: '1' } }); ck('proxy switch needs a token (401)', r.status === 401);
  r = await api('POST', '/api/proxy', { form: { on: '2' } }); ck('proxy: invalid value -> E_INVALID', jx(r).code === 'E_INVALID');
  r = await api('GET', '/api/state'); ck('state: proxy OFF at start, account email, update summary, lang, ports.speed', jx(r).proxy && jx(r).proxy.enabled === false && jx(r).account.email === D1 && jx(r).update.available === true
    && jx(r).update.latest === '2.2.0' && typeof jx(r).lang === 'string' && jx(r).ports.speed === 7892 && jx(r).version === '2.1.0' && jx(r).core === '1.14.2' && jx(r).servers.length === 27 && jx(r).first_run === false, r.text.slice(0, 160));
  r = await clash('GET', '/connections'); ck('proxy OFF: every connection is direct', r.status === 200 && jx(r).connections.length > 0 && jx(r).connections.every((c) => c.chains.length === 1 && c.chains[0] === 'direct-mode'));        // 总开关关闭: 出口名 direct-mode (说明为什么直连)
  r = await api('POST', '/api/proxy', { form: { on: '1' } }); ck('proxy on -> {ok, enabled:true}', jx(r).ok === true && jx(r).enabled === true, r.text);
  r = await clash('GET', '/connections'); ck('proxy ON: connections use proxy chains again', jx(r).connections.some((c) => c.chains.length > 1));
  r = await api('GET', '/api/state'); ck('state.proxy.enabled follows the switch', jx(r).proxy.enabled === true);
  await ctl('clash=down'); r = await api('POST', '/api/proxy', { form: { on: '1' } }); ck('proxy on while the core is down -> E_NOT_RUNNING', jx(r).code === 'E_NOT_RUNNING');
  r = await api('POST', '/api/proxy', { form: { on: '0' } }); ck('proxy off works even with the core down', jx(r).ok === true && jx(r).enabled === false);
  await ctl('clash=up'); await api('POST', '/api/proxy', { form: { on: '1' } });
  /* ---- 代理模式: 自动模式 auto (默认) / 全局代理 global; 总开关和模式是两个独立的设置, 热切换 ---- */
  r = await api('GET', '/api/state'); ck('state.proxy.mode defaults to auto', jx(r).proxy.mode === 'auto');
  r = await api('POST', '/api/proxy', { form: { mode: 'global' } }); ck('proxy mode=global (without on) -> {ok, enabled, mode}; the master switch stays as it was', jx(r).ok === true && jx(r).mode === 'global' && jx(r).enabled === true, r.text);
  r = await api('GET', '/api/state'); ck('state.proxy.mode follows the change', jx(r).proxy.mode === 'global' && jx(r).proxy.enabled === true);
  await ctl('conns=12'); const SITE_CN = SITES.filter((x) => x[0] === 'www.cn-site.example.com')[0], SITE_WX = SITES.filter((x) => x[0] === 'res.wx.example.net')[0]; M.conns = [];
  for (let i = 0; i < 6; i++) { M.conns.push(spawnConn(SITE_CN)); M.conns.push(spawnConn(SITE_WX)); }          // 直接生成要断言的两个站点 (不靠随机抽样; 6 份是为了挡住每次 4% 的随机断开)
  r = await clash('GET', '/connections'); const cnSite = jx(r).connections.filter((c) => c.metadata.host === 'www.cn-site.example.com'), wx = jx(r).connections.filter((c) => c.metadata.host === 'res.wx.example.net');
  ck('global mode: a domestic site that was forced direct now goes through the proxy; an explicit per-app choice (WeChat = direct) is kept', cnSite.length > 0 && cnSite.every((c) => c.chains.length > 1) && wx.length > 0 && wx.every((c) => c.chains.length === 1)); await ctl('conns=45');
  r = await api('POST', '/api/proxy', { form: { mode: 'sideways' } }); ck('proxy: invalid mode -> E_INVALID', jx(r).code === 'E_INVALID');
  r = await api('POST', '/api/proxy', { form: {} }); ck('proxy: neither on nor mode -> E_INVALID', jx(r).code === 'E_INVALID');
  r = await api('POST', '/api/proxy', { form: { on: '0', mode: 'auto' } }); ck('on and mode together work in one request', jx(r).ok === true && jx(r).enabled === false && jx(r).mode === 'auto');
  r = await api('POST', '/api/proxy', { form: { mode: 'global' } }); ck('mode can be changed while the proxy is OFF (kept, takes effect later)', jx(r).ok === true && jx(r).enabled === false && jx(r).mode === 'global');
  r = await api('POST', '/api/proxy', { form: { on: '1' } }); ck('turning on keeps the saved mode', jx(r).enabled === true && jx(r).mode === 'global');
  await api('POST', '/api/proxy', { form: { mode: 'auto' } });
  r = await api('POST', '/api/logout'); const old = T; ck('logout -> {ok:true}', jx(r).ok === true && r.status === 200, r.text);
  r = await api('GET', '/api/state', { token: old }); ck('logout: old token is dead (401)', r.status === 401);
  r = await login(D1, P1); T = jx(r).token; r = await api('GET', '/api/state'); ck('logout switched the proxy OFF; a new token works', jx(r).proxy.enabled === false && T !== old);
  await ctl('expire=1'); r = await api('GET', '/api/state'); ck('expire=1 invalidates every token', r.status === 401); r = await login(D1, P1); T = jx(r).token;

  /* ---- 设备数量限制 (同账号同平台最多 2 台在线) / 下线 / 我的设备 / 被下线的提示 / 离线登录规则 ---- */
  {
    let dv2, dw;
    await ctl('devices=full&expire=1'); const lim = await login(D1, P1), limEn = await rq('POST', '/api/login', { form: { user: D1, password: P1 }, lang: 'en' });
    for (let i = 0; i < 6; i++) await login(D1, P1);
    const st = await rq('GET', '/api/auth/status');
    ck('login: a 3rd macOS device -> E_DEVICE_LIMIT (HTTP 200): platform, limit 2, the 2 online devices (not this computer), translated error, no token', lim.status === 200 && jx(lim).ok === false && jx(lim).code === 'E_DEVICE_LIMIT' && jx(lim).platform === 'macos' && jx(lim).limit === 2 && jx(lim).devices.length === 2 && !('token' in jx(lim))
      && jx(lim).devices.every((d) => d.online === true && d.platform === 'macos' && ['uid', 'name', 'os', 'last_seen', 'ip_hint'].every((k) => k in d) && d.uid !== 'this-mock') && jx(lim).devices.map((d) => d.uid).sort().join() === 'd-air,d-mbp'
      && !!jx(lim).error && /2/.test(jx(limEn).error) && jx(lim).error !== jx(limEn).error, lim.text);
    ck('device names are translated per language (我的 MacBook Pro / My MacBook Pro)', jx(lim).devices.filter((d) => d.uid === 'd-mbp')[0].name === '我的 MacBook Pro' && jx(limEn).devices.filter((d) => d.uid === 'd-mbp')[0].name === "My MacBook Pro");
    ck('E_DEVICE_LIMIT is not a bad-credentials failure: 8 refusals do not lock the login (wait 0), a wrong password is still E_BAD_CREDENTIALS', st.json.wait === 0 && jx(await login(D1, 'wrong')).code === 'E_BAD_CREDENTIALS');
    r = await rq('POST', '/api/login', { form: { user: D1, password: P1, kick: 'no-such-device' } }); ck('login with an unknown kick uid -> E_INVALID', jx(r).code === 'E_INVALID');
    r = await rq('POST', '/api/login', { form: { user: D1, password: P1, kick: 'd-mbp' } }); T = jx(r).token;
    ck('login with kick=<uid of an online device>: it is signed out and the login succeeds (token, via online)', jx(r).ok === true && /^[0-9a-f]{32}$/.test(T) && jx(r).via === 'online');
    r = await api('GET', '/api/devices'); const dv = jx(r), me = dv.devices[0];
    ck('GET /api/devices: platform, limit, current device first (this computer, current:true, app = running version), kicked device offline, all platforms, documented fields', dv.ok === true && dv.platform === 'macos' && dv.limit === 2 && me.current === true && me.uid === 'this-mock' && me.name === '这台电脑' && me.platform === 'macos' && me.online === true && me.app === '2.1.0'
      && dv.devices.length === 4 && dv.devices.every((d) => ['uid', 'name', 'platform', 'os', 'app', 'last_seen', 'online', 'ip_hint', 'current'].every((k) => k in d)) && dv.devices.filter((d) => d.uid === 'd-mbp')[0].online === false
      && dv.devices.filter((d) => d.uid === 'd-win')[0].platform === 'windows' && dv.devices.filter((d) => d.uid === 'd-air')[0].online === true && jx(await api('GET', '/api/devices', { lang: 'en' })).devices[0].name === 'This computer', r.text);
    r = await api('POST', '/api/devices/kick', { form: { uid: 'this-mock' } }); r2 = await api('POST', '/api/devices/kick', { form: { uid: 'nope' } }); const r3 = await api('POST', '/api/devices/kick');
    ck('devices/kick: own uid -> E_INVALID, unknown uid -> E_NOT_FOUND, missing uid -> E_INVALID; needs a token', jx(r).code === 'E_INVALID' && jx(r2).code === 'E_NOT_FOUND' && jx(r3).code === 'E_INVALID' && (await rq('POST', '/api/devices/kick', { form: { uid: 'd-air' } })).status === 401);
    await ctl('central=down'); r = await api('GET', '/api/devices'); r2 = await api('POST', '/api/devices/kick', { form: { uid: 'd-air' } }); await ctl('central=up');
    ck('devices: central=down -> E_ACCOUNT_UNREACHABLE for the list and for kick', jx(r).code === 'E_ACCOUNT_UNREACHABLE' && jx(r2).code === 'E_ACCOUNT_UNREACHABLE');
    r = await api('POST', '/api/devices/kick', { form: { uid: 'd-air' } }); dv2 = jx(await api('GET', '/api/devices'));
    ck('devices/kick: a known device goes offline ({ok:true}); kicking it again is harmless', jx(r).ok === true && dv2.devices.filter((d) => d.uid === 'd-air')[0].online === false && jx(await api('POST', '/api/devices/kick', { form: { uid: 'd-air' } })).ok === true);
    await ctl('os=windows&devices=full&expire=1'); r = await login(D1, P1); T = jx(r).token; dw = jx(await api('GET', '/api/devices')); await ctl('os=darwin');
    ck('the limit is per platform: on Windows the two online macOS devices do not block the login; platform follows os=windows', jx(r).ok === true && dw.platform === 'windows' && dw.devices[0].platform === 'windows' && dw.devices[0].current === true);
    await ctl('devices=reset&expire=1'); r = await login(D1, P1); T = jx(r).token; await api('POST', '/api/proxy', { form: { on: '1' } });
    await ctl('kickme=1'); r = await api('GET', '/api/state'); const ns = await rq('GET', '/api/auth/status'), nsEn = await rq('GET', '/api/auth/status', { lang: 'en' });
    ck('kickme=1 (signed out from another device): every token dies (401) and auth/status.notice explains it, in zh and en', r.status === 401 && jx(ns).notice === '这台设备已被你账号下的另一台设备下线, 代理已关闭' && /signed out from another device/.test(jx(nsEn).notice) && jx(ns).offline_ok === false);
    r = await login(D1, P1); T = jx(r).token; const ns2 = await rq('GET', '/api/auth/status'), stt = jx(await api('GET', '/api/state'));
    ck('the next successful login clears the notice; the proxy was turned off by the kick and stays off', jx(ns2).notice === '' && stt.proxy.enabled === false);
    await ctl('notice=' + encodeURIComponent('离线时间过长, 已自动退出登录')); const ns3 = await rq('GET', '/api/auth/status'); await ctl('notice='); const ns4 = await rq('GET', '/api/auth/status');
    ck('/mock/ctl notice=<text> sets any notice, notice= clears it', jx(ns3).notice === '离线时间过长, 已自动退出登录' && jx(ns4).notice === '');
    ck('offline_ok is true while this machine is logged in', jx(await rq('GET', '/api/auth/status')).offline_ok === true);
    await api('POST', '/api/logout'); await ctl('central=down'); r = await login(D1, P1); const so = await rq('GET', '/api/auth/status'); await ctl('central=up');
    ck('after logout the account must be verified online: central=down -> E_ACCOUNT_UNREACHABLE, offline_ok false, the hint is still shown', jx(r).code === 'E_ACCOUNT_UNREACHABLE' && jx(so).offline_ok === false && jx(so).account_hint === 'd***@e***.com');
    r = await login(D1, P1); T = jx(r).token;
  }

  /* ---- 语言 / 应用 / 覆盖 / 服务器 / 订阅 / 证书 / 任务 ---- */
  r = await api('GET', '/api/apps'); ck('apps: 30 apps, 3 new, shape (incl. custom, kind + icon)', jx(r).apps.length === 30 && jx(r).new_count === 3 && jx(r).apps.every((a) => 'name' in a && 'state' in a && 'flag' in a && 'known' in a && 'rec' in a && 'group' in a && 'path' in a && a.custom === false && a.kind === 'app' && typeof a.icon === 'string') && jx(r).scanned_at > 0);
  await ctl('newapp=Zed'); r = await api('POST', '/api/apps/scan'); ck('apps/scan picks up a newly installed app', jx(r).apps.length === 31 && jx(r).new_count === 4);
  r = await api('POST', '/api/apps/adopt'); r2 = await api('POST', '/api/apps/ack', { q: { all: 1 } }); r = await api('GET', '/api/apps'); ck('apps adopt + ack all -> no new apps', jx(r2).ok === true && jx(r).new_count === 0 && jx(r).apps.filter((a) => a.name === 'Perplexity')[0].state === 'pin');
  r = await api('POST', '/api/override', { q: { kind: 'app', value: 'NoSuchApp', state: 'pin' } }); ck('override: unknown app -> E_NOT_FOUND', jx(r).code === 'E_NOT_FOUND');
  r = await api('POST', '/api/override', { q: { kind: 'site', value: 'Bad Host!', state: 'pin' } }); ck('override: invalid host -> E_INVALID', jx(r).code === 'E_INVALID');
  await api('POST', '/api/override', { q: { kind: 'site', value: 'shop.example.com', state: 'pin' } }); r = await api('GET', '/api/state');
  ck('override set shows in state.overrides', jx(r).overrides.some((o) => o.value === 'shop.example.com' && o.state === 'pin'));
  await api('POST', '/api/override', { form: { kind: 'site', value: 'shop.example.com', state: 'follow' } }); r = await api('GET', '/api/state'); ck('override follow removes it (form body works too)', !jx(r).overrides.some((o) => o.value === 'shop.example.com'));
  const line = (tag, role, extra) => JSON.stringify(Object.assign({ role, outbound: { type: 'trojan', tag, server: '203.0.113.200', server_port: 443, password: 'pw' } }, extra));
  r = await api('POST', '/api/servers/import', { q: { sub: 'demo-sub', mode: 'merge' }, body: [line('Selftest A', 'auto'), line('Selftest B', 'pin'), '{"role":"bogus"}', line('PIN', 'auto')].join('\n') });
  ck('servers/import response: added/replaced/removed counts, per-line errors (bad line + reserved tag), job id', jx(r).ok === true && jx(r).added === 2 && jx(r).replaced === 0 && jx(r).removed === 0 && jx(r).errors.length === 2 && /^servers-import-/.test(jx(r).job), r.text);
  let jb = await run(r); r = await api('GET', '/api/state');
  ck('servers/import: job done and the servers show up in state (+2 -> 29)', jx(r).servers.length === 29 && jb.state === 'done');
  r = await api('POST', '/api/servers/import', { q: { mode: 'merge' }, body: 'not json\n{"x":1}' }); ck('servers/import: nothing importable -> E_INVALID + errors[]', jx(r).code === 'E_INVALID' && Array.isArray(jx(r).errors) && jx(r).errors.length === 2);
  r = await api('POST', '/api/servers/delete', { q: { tag: 'no-such-server' } }); ck('servers/delete: unknown tag -> E_NOT_FOUND', jx(r).code === 'E_NOT_FOUND');
  r = await api('POST', '/api/servers/role', { q: { tag: 'Selftest A', role: 'bogus' } }); ck('servers/role: invalid role -> E_INVALID', jx(r).code === 'E_INVALID');
  r = await api('POST', '/api/servers/role', { q: { tag: 'Selftest A', role: 'off' }, lang: 'en' }); let jv = await api('GET', '/api/job', { q: { id: jx(r).job }, lang: 'en' });
  ck('job view (en): translated msg + step labels, steps with states', jv.json.ok === true && /…$/.test(jv.json.msg) && jv.json.steps.length === 4 && jv.json.steps[0].label === 'Generate config' && ['todo', 'run', 'done'].indexOf(jv.json.steps[0].state) >= 0 && typeof jv.json.pct === 'number', jv.text);
  jb = await waitJob(jx(r).job, 'zh'); ck('job done: pct 100, all steps done, zh msg', jb.state === 'done' && jb.pct === 100 && jb.steps.every((s) => s.state === 'done') && /完成/.test(jb.msg), jb);
  await ctl('failnext=1'); r = await api('POST', '/api/servers/role', { q: { tag: 'Selftest B', role: 'off' } }); jb = await waitJob(jx(r).job);
  r = await api('GET', '/api/state'); ck('failnext=1: the next job fails and the change is rolled back', jb.state === 'error' && jb.pct === 100 && jx(r).servers.filter((s) => s.tag === 'Selftest B')[0].role === 'pin', jb);
  await ctl('failnext=/api/servers/delete'); r = await api('POST', '/api/servers/delete', { q: { tag: 'Selftest B' } }); ck('failnext=/path: that path fails once with E_NETWORK', jx(r).code === 'E_NETWORK' && jx(r).ok === false);
  r = await api('POST', '/api/servers/delete', { q: { tag: 'Selftest B' } }); jb = await run(r); ck('...and then works again', jb.state === 'done');
  r = await api('POST', '/api/sub/save', { q: { name: 'selftest-sub' }, body: 'https://sub.example.com/sub/demo\n' }); ck('sub/save ok', jx(r).ok === true);
  r = await api('POST', '/api/sub/fetch', { q: { ua: 'auto' }, body: 'https://sub.example.com/sub/demo' }); ck('sub/fetch: base64 list + X-Subscription-Userinfo header', r.status === 200 && /^text\/plain/.test(r.headers['content-type']) && /total=/.test(r.headers['x-subscription-userinfo'] || '')
    && Buffer.from(r.text, 'base64').toString().indexOf('203.0.113.') > 0);
  r = await api('POST', '/api/sub/fetch', { body: 'https://sub.example.com/sub/fail' }); ck('sub/fetch /fail -> E_NETWORK', jx(r).code === 'E_NETWORK');
  r = await api('POST', '/api/sub/fetch', { body: 'http://127.0.0.1/sub' }); ck('sub/fetch: private address -> E_INVALID', jx(r).code === 'E_INVALID');
  r = await api('POST', '/api/sub/delete', { q: { name: 'nope' } }); ck('sub/delete unknown -> E_NOT_FOUND', jx(r).code === 'E_NOT_FOUND');
  r = await api('POST', '/api/sub/delete', { q: { name: 'selftest-sub' } }); jb = await run(r); ck('sub/delete -> job done', jb.state === 'done');
  r = await api('POST', '/api/cert', { q: { name: 'ca1' }, body: '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n' }); ck('cert: PEM accepted -> ref', jx(r).ref === '@CERTS@/ca1.crt');
  r = await api('POST', '/api/cert', { q: { name: 'ca1' }, body: 'hello' }); ck('cert: not a PEM -> E_INVALID', jx(r).code === 'E_INVALID');
  r = await api('GET', '/api/job', { q: { id: 'job-0-0' } }); ck('job: unknown id -> E_NOT_FOUND', jx(r).code === 'E_NOT_FOUND');
  r = await api('POST', '/api/restart'); jb = await run(r); ck('restart -> job done', jb.state === 'done' && /重启/.test(jb.msg));
  r = await api('POST', '/api/nope'); ck('unknown route -> 404 E_NOT_FOUND', r.status === 404 && jx(r).code === 'E_NOT_FOUND');
  r = await api('POST', '/api/override', { body: 'x'.repeat(4 * 1024 * 1024 + 100) }); ck('request body over 4 MB -> 413', r.status === 413, r.status + ' ' + (r.error || ''));

  /* ---- 设置 / 日志 ---- */
  r = await api('GET', '/api/settings'); ck('settings shape (account.email, usage access==proxy, ports)', jx(r).settings.log_hours === 72 && jx(r).settings.log_hours_min === 12 && jx(r).settings.log_hours_max === 720 && jx(r).settings.log_ops === true && jx(r).settings.log_core === true && jx(r).settings.auto_sites === false && jx(r).settings.access_log === true && jx(r).settings.auto_update === true && jx(r).usage.access === jx(r).usage.proxy
    && jx(r).usage.total === jx(r).usage.ops + jx(r).usage.proxy && jx(r).account.email === D1 && jx(r).ports.api === PORT && !('bound' in jx(r).account));
  r = await api('POST', '/api/settings', { form: { auto_update: '2' } }); ck('settings: auto_update must be 0|1 -> E_INVALID', jx(r).code === 'E_INVALID');
  r = await api('POST', '/api/settings', { form: { auto_update: '0' } }); r2 = await api('GET', '/api/settings');
  ck('settings: auto_update=0 sticks (no job) and is logged as settings.set', jx(r).ok === true && !('job' in jx(r)) && jx(r2).settings.auto_update === false && jx(await logs({ type: 'ops', q: 'auto_update=0' })).total >= 1);
  await api('POST', '/api/settings', { form: { auto_update: '1' } });
  r = await api('POST', '/api/settings', { form: { log_hours: '11' } }); ck('settings: log_hours 11 (< 12 hours) -> E_INVALID', jx(r).code === 'E_INVALID');
  r = await api('POST', '/api/settings', { form: { log_hours: '721' } }); ck('settings: log_hours 721 (> 30 days) -> E_INVALID', jx(r).code === 'E_INVALID');
  r = await api('POST', '/api/settings', { form: { log_hours: 'abc' } }); ck('settings: log_hours not a number -> E_INVALID', jx(r).code === 'E_INVALID');
  r = await api('POST', '/api/settings', { form: { log_hours: '24', lang: 'en' } }); const dd = await logs({ type: 'ops' }); r2 = await api('GET', '/api/settings', { lang: 'zh' });
  ck('settings: log_hours=24 limits the days (today + yesterday); lang=en sticks', jx(r).ok === true && !('job' in jx(r)) && jx(dd).days.length <= 2 && jx(r2).lang === 'en' && jx(r2).settings.log_hours === 24);
  r = await api('POST', '/api/settings', { form: { log_hours: '12' } }); const d12 = await logs({ type: 'access', limit: '2000' });
  ck('settings: log_hours=12 is the minimum and cuts rows older than 12 hours (hour granularity)', jx(r).ok === true && jx(d12).rows.every((x) => x.ts >= tsOf(now() - 12 * 3600e3 - 5000)));
  r = await api('POST', '/api/settings', { form: { log_days: '2' } }); r2 = await api('GET', '/api/settings'); ck('settings: the legacy log_days=2 is still accepted and converted to 48 hours', jx(r).ok === true && jx(r2).settings.log_hours === 48);
  await api('POST', '/api/settings', { form: { log_hours: '720', lang: 'zh' } });                           // 后面的历史检查要看 14 天
  r = await logs({ type: 'access' }); const a0 = jx(r).total;
  r = await api('POST', '/api/settings', { form: { access_log: '0' } }); jb = await run(r); await ctl('tick=3'); r = await logs({ type: 'access' }); const a1 = jx(r).total;
  ck('access_log=0 returns a job and stops new access rows', jb.state === 'done' && a1 === a0, [a0, a1]);
  await api('POST', '/api/settings', { form: { access_log: '1' } }).then(run); await ctl('tick=3'); r = await logs({ type: 'access' }); ck('access_log=1 -> live access rows appear again', jx(r).total === a0 + 3, [a0, jx(r).total]);
  const hist = {}; let dayOk = true;
  for (let k = 1; k < 14; k++) { const d = dayOf(addDays(now(), -k)), o = jx(await logs({ type: 'ops', day: d, limit: '2000' })), a = jx(await logs({ type: 'access', day: d, limit: '1' })); o.rows.forEach((x) => { hist[x.action] = 1; }); if (!(o.total >= 5 && o.total <= 40 && a.total >= 200 && a.total <= 1500)) dayOk = false; }
  ck('logs history: 5-40 ops rows and 200-1500 access rows per past day; the history uses the documented vocabulary only (install/upgrade/uninstall/start/stop included)', dayOk && Object.keys(hist).length >= 20 && Object.keys(hist).every((c) => OPS_CODES.indexOf(c) >= 0)
    && ['install', 'upgrade', 'uninstall', 'start', 'stop', 'update.apply', 'login', 'logout'].every((c) => hist[c]), Object.keys(hist));
  r = await logs({ type: 'ops', day: dayOf(now()), limit: '5' }); const o1 = jx(r).rows, tot = jx(r).total;
  ck('logs: newest first, limit, days list, ops row shape', o1.length === 5 && o1.every((x, i) => i === 0 || o1[i - 1].ts >= x.ts) && jx(r).days.length === 14 && jx(r).days[0] === dayOf(now()) && ['dashboard', 'terminal'].indexOf(o1[0].who) >= 0
    && 'action' in o1[0] && 'detail' in o1[0] && ['ok', 'error'].indexOf(o1[0].result) >= 0 && tot >= 5);
  r = await logs({ type: 'ops', limit: '5', offset: '5' }); ck('logs: offset pages to older rows', jx(r).rows.length === 5 && jx(r).rows[0].ts <= o1[4].ts && jx(r).rows[0].ts !== undefined && JSON.stringify(jx(r).rows) !== JSON.stringify(o1));
  r = await logs({ type: 'ops', q: o1[0].action.toUpperCase() }); ck('logs: q is a case-insensitive substring search', jx(r).total >= 1 && jx(r).rows.every((x) => (x.ts + x.who + x.action + x.detail + x.result).toLowerCase().indexOf(o1[0].action.toLowerCase()) >= 0));
  r = await logs({ type: 'access', limit: '3' }); const ac = jx(r).rows[0]; ck('logs: access rows (host/port/app/route/node), 200-1500 rows per day', 'host' in ac && typeof ac.port === 'number' && 'app' in ac && ['direct', 'pin', 'auto', 'other'].indexOf(ac.route) >= 0 && 'node' in ac && jx(r).total >= 200 && /example\.(com|org|net)$/.test(ac.host));
  r = await logs({ type: 'proxy', limit: '3' }); ck('logs: proxy rows (ts/level/msg)', jx(r).rows.length === 3 && ['INFO', 'WARN', 'ERROR'].indexOf(jx(r).rows[0].level) >= 0 && typeof jx(r).rows[0].msg === 'string');
  r = await logs({ type: 'bogus' }); ck('logs: invalid type -> E_INVALID', jx(r).code === 'E_INVALID');
  /* ---- 日志 (2.1.1): 访问记录的新字段 / 筛选 / 汇总; 诊断导出; 三个日志开关; 策略切换 / 审计 / 指定固定出口 / 自动识别 ---- */
  {
    const clashJ = async (m, pth) => jx(await clash(m, pth));
    const acc = jx(await logs({ type: 'access', day: dayOf(now()), limit: '400' }));
    ck('logs/access rows: id net host port app user path route node reason err errmsg dur ips; summary {all direct proxy pin auto error reasons top_fail}', acc.rows.length > 0 && acc.rows.every((x) => ['id', 'net', 'host', 'port', 'app', 'user', 'path', 'route', 'node', 'reason', 'err', 'errmsg', 'dur', 'ips'].every((k) => k in x))
      && acc.summary && ['all', 'direct', 'proxy', 'pin', 'auto', 'error'].every((k) => typeof acc.summary[k] === 'number') && acc.summary.direct + acc.summary.proxy === acc.summary.all && typeof acc.summary.reasons === 'object' && Array.isArray(acc.summary.top_fail));
    ck('logs/access: a direct row names why (reason mode|lan|site|app|cn|policy) and its exit is direct-<reason> (plain direct = policy); proxied rows have no reason', acc.rows.every((x) => x.route === 'direct' ? (['mode', 'lan', 'site', 'app', 'cn', 'policy'].indexOf(x.reason) >= 0 && x.node === (x.reason === 'policy' ? 'direct' : 'direct-' + x.reason)) : (!x.reason && x.node !== 'direct')));
    const fe = jx(await logs({ type: 'access', day: dayOf(now()), limit: '400', f: 'error' })), fd = jx(await logs({ type: 'access', day: dayOf(now()), limit: '400', f: 'direct' })), fp = jx(await logs({ type: 'access', day: dayOf(now()), limit: '400', f: 'proxy' }));
    ck('logs/access filters: f=error -> only failed rows (err set); f=direct -> only direct; f=proxy -> none direct; the summary does not change with the filter', fe.rows.every((x) => x.err) && fe.total === acc.summary.error && fd.rows.every((x) => x.route === 'direct') && fd.total === acc.summary.direct && fp.rows.every((x) => x.route !== 'direct') && fp.total === acc.summary.proxy && fe.summary.all === acc.summary.all);
    const po = jx(await logs({ type: 'proxy', day: dayOf(now()), limit: '2000' })), pw = jx(await logs({ type: 'proxy', day: dayOf(now()), limit: '2000', f: 'warn' })), oe = jx(await logs({ type: 'ops', day: dayOf(now()), limit: '2000', f: 'error' }));
    ck('logs filters: proxy f=warn -> WARN + ERROR rows, summary {all warn error}; ops f=error -> only failed operations, summary {all error}', pw.rows.every((x) => x.level === 'WARN' || x.level === 'ERROR') && pw.total === po.summary.warn + po.summary.error && ['all', 'warn', 'error'].every((k) => typeof po.summary[k] === 'number') && oe.rows.every((x) => x.result === 'error') && oe.total === oe.summary.error);
    r = await api('GET', '/api/logs/bundle', { q: { hours: '24', sections: 'ops,access,proxy,snapshot' } }); const bl = (r.text || '').split('\n');
    ck('logs/bundle: a self-describing text file — #ENANA-DIAGNOSTICS format=1 header, @@SECTION name format= rows= blocks (meta env config policy servers apps probes live ops access proxy), @@END', r.status === 200 && /^text\/plain/.test(r.headers['content-type']) && bl[0] === '#ENANA-DIAGNOSTICS format=1' && /^#range since="/.test(bl[2])
      && ['meta', 'env', 'config', 'policy', 'servers', 'apps', 'probes', 'live', 'ops', 'access', 'proxy'].every((n) => bl.some((l) => new RegExp('^@@SECTION ' + n + ' format=(kv|tsv|text|raw) rows=\\d+$').test(l))) && bl.filter(Boolean).pop() === '@@END');
    ck('logs/bundle: the access section is a TSV with a header (ts id net host ...) and every row has 16 columns; hours + sections are validated', (() => { const i = bl.findIndex((l) => l.indexOf('@@SECTION access') === 0), hdr = (bl[i + 1] || '').split('\t'); return hdr[0] === 'ts' && hdr.length === 16 && bl.slice(i + 2).filter((l) => l && l.indexOf('@@') !== 0 && l.indexOf('+0800') !== 0).slice(0, 20).every((l) => l.split('\t').length === 16); })()
      && jx(await api('GET', '/api/logs/bundle', { q: { hours: 'x' } })).code === 'E_INVALID' && jx(await api('GET', '/api/logs/bundle', { q: { sections: 'ops,nope' } })).code === 'E_INVALID');
    r = await api('GET', '/api/logs/bundle', { q: { hours: '12', sections: 'ops' } }); const b2 = r.text.split('\n');
    ck('logs/bundle: only the chosen sections (ops) + meta are present; the export itself is recorded (logs.bundle)', b2.some((l) => l.indexOf('@@SECTION ops') === 0) && !b2.some((l) => l.indexOf('@@SECTION access') === 0) && !b2.some((l) => l.indexOf('@@SECTION env') === 0) && b2.some((l) => l.indexOf('@@SECTION meta') === 0)
      && jx(await logs({ type: 'ops', day: dayOf(now()), limit: '5' })).rows.some((x) => x.action === 'logs.bundle'));
    // 三个日志开关
    r = await api('POST', '/api/settings', { form: { log_ops: '0' } }); const n0 = jx(await logs({ type: 'ops', day: dayOf(now()), limit: '1' })).total; await api('POST', '/api/override', { q: { kind: 'site', value: 'quiet.example.com', state: 'direct' } });
    const n1 = jx(await logs({ type: 'ops', day: dayOf(now()), limit: '1' })).total; await api('POST', '/api/override', { q: { kind: 'site', value: 'quiet.example.com', state: 'follow' } });
    ck('settings: log_ops=0 stops operation records (the switch itself is recorded first); log_ops=1 resumes', jx(r).ok === true && n1 === n0 && jx(await api('GET', '/api/settings')).settings.log_ops === false);
    await api('POST', '/api/settings', { form: { log_ops: '1' } }); const n2 = jx(await logs({ type: 'ops', day: dayOf(now()), limit: '1' })).total; await api('POST', '/api/override', { q: { kind: 'site', value: 'quiet.example.com', state: 'direct' } });
    ck('settings: log_ops=1 resumes recording', jx(await logs({ type: 'ops', day: dayOf(now()), limit: '1' })).total > n2); await api('POST', '/api/override', { q: { kind: 'site', value: 'quiet.example.com', state: 'follow' } });
    r = await api('POST', '/api/settings', { form: { log_core: '0' } }); ck('settings: log_core=0 returns a job (core restart) and shows in /api/settings', jx(r).ok === true && !!jx(r).job && jx(await api('GET', '/api/settings')).settings.log_core === false); await nap(4500);
    await api('POST', '/api/settings', { form: { log_core: '1' } }); await nap(4500);
    // 策略切换 (辅助服务代为切换并记录) / 审计 / 指定固定出口
    const px = (await clashJ('GET', '/proxies')).proxies, svcTag = Object.keys(px).filter((k) => /^svc-/.test(k))[0], pinTags = px.PIN ? px.PIN.all : [];
    ck('clash proxies: with >= 2 fixed exits each site switch also offers PINAUTO + every fixed exit (and PINAUTO is a group over the fixed exits)', pinTags.length >= 2 && px[svcTag].all.indexOf('PINAUTO') >= 0 && pinTags.every((t) => px[svcTag].all.indexOf(t) >= 0) && px.PINAUTO && px.PINAUTO.all.join() === pinTags.join());
    r = await api('POST', '/api/policy', { form: { tag: svcTag, name: pinTags[1] } }); const px2 = (await clashJ('GET', '/proxies')).proxies;
    ck('policy: POST /api/policy switches a site selector to ONE fixed exit; answers {from, to}; the switch is recorded (policy.switch, kind=selector tag from to)', jx(r).ok === true && jx(r).to === pinTags[1] && px2[svcTag].now === pinTags[1] && jx(await logs({ type: 'ops', day: dayOf(now()), limit: '5' })).rows.some((x) => x.action === 'policy.switch' && x.detail.indexOf('tag=' + svcTag) >= 0 && x.detail.indexOf('to=') >= 0));
    r = await api('POST', '/api/policy', { form: { tag: svcTag, name: 'No Such Node' } }); r2 = await api('POST', '/api/policy', { form: { tag: 'evil tag', name: 'PIN' } });
    ck('policy: an option that does not exist -> E_NOT_FOUND; a malformed tag -> E_INVALID', jx(r).code === 'E_NOT_FOUND' && jx(r2).code === 'E_INVALID');
    r = await api('POST', '/api/policy', { form: { tag: svcTag, name: 'PINAUTO' } }); ck('policy: PINAUTO (auto-pick among the fixed exits) can be chosen too', jx(r).ok === true && (await clashJ('GET', '/proxies')).proxies[svcTag].now === 'PINAUTO');
    await api('POST', '/api/policy', { form: { tag: svcTag, name: 'PIN' } });
    r = await api('POST', '/api/audit', { form: { ev: 'kill', scope: 'host', n: '3', host: 'www.example.org' } }); r2 = await api('POST', '/api/audit', { form: { ev: 'nope' } });
    ck('audit: POST /api/audit ev=kill is recorded (conns.kill scope count host); other events -> E_INVALID', jx(r).ok === true && jx(r2).code === 'E_INVALID' && jx(await logs({ type: 'ops', day: dayOf(now()), limit: '5' })).rows.some((x) => x.action === 'conns.kill' && /scope=host count=3 host=www.example.org/.test(x.detail)));
    const appN = jx(await api('GET', '/api/apps')).apps.filter((a) => !a.custom)[0].name;
    r = await api('POST', '/api/override', { q: { kind: 'app', value: appN, state: 'pin', target: pinTags[1] } }); const aT = jx(await api('GET', '/api/apps')).apps.filter((a) => a.name === appN)[0];
    ck('override: an app on "pin" can be pinned to one fixed exit (target) — apps carry target + target_ok; the record has from/to/target_to', jx(r).ok === true && aT.state === 'pin' && aT.target === pinTags[1] && aT.target_ok === true && jx(await logs({ type: 'ops', day: dayOf(now()), limit: '3' })).rows.some((x) => x.action === 'override.set' && x.detail.indexOf('to=pin') >= 0 && x.detail.indexOf('target_to=') >= 0));
    r = await api('POST', '/api/override', { q: { kind: 'app', value: appN, state: 'pin', target: 'PINAUTO' } }); r2 = await api('POST', '/api/override', { q: { kind: 'app', value: appN, state: 'pin', target: 'No Such Server' } });
    ck('override: target PINAUTO is accepted; an unknown fixed exit -> E_INVALID', jx(r).ok === true && jx(r2).code === 'E_INVALID');
    r = await api('POST', '/api/override', { q: { kind: 'app', value: appN, state: 'direct', target: pinTags[1] } }); ck('override: the target is dropped when the state is not "pin"', jx(r).ok === true && jx(await api('GET', '/api/apps')).apps.filter((a) => a.name === appN)[0].target === '');
    await api('POST', '/api/override', { q: { kind: 'app', value: appN, state: 'follow' } });
    r = await api('POST', '/api/override', { q: { kind: 'site', value: 'pinned.example.com', state: 'pin', target: pinTags[0] } }); const sv = jx(await api('GET', '/api/state')).overrides.filter((o) => o.value === 'pinned.example.com')[0];
    ck('state.overrides carry target, target_ok, src (user|auto), at, why, fails, app; a user site has src "user"', jx(r).ok === true && sv && sv.target === pinTags[0] && sv.target_ok === true && sv.src === 'user' && ['at', 'why', 'fails', 'app'].every((k) => k in sv));
    await api('POST', '/api/override', { q: { kind: 'site', value: 'pinned.example.com', state: 'follow' } });
    // 自动识别
    const st0 = jx(await api('GET', '/api/state')).overrides, au0 = st0.filter((o) => o.src === 'auto');
    ck('auto-detect: the seed has one auto-added site (src auto, why, fails, app, at)', au0.length === 1 && au0[0].value === 'blocked.example.net' && au0[0].why === 'timeout' && au0[0].fails > 0 && au0[0].app === 'Google Chrome' && au0[0].at > 0);
    r = await api('POST', '/api/settings', { form: { auto_sites: '2' } }); ck('settings: auto_sites must be 0|1', jx(r).code === 'E_INVALID');
    r = await api('POST', '/api/sites/auto/clear'); const st1 = jx(await api('GET', '/api/state')).overrides;
    ck('sites/auto/clear: undoes every auto-added site (answers {removed}), user sites are untouched; recorded (autosite.clear count)', jx(r).ok === true && jx(r).removed === 1 && !st1.some((o) => o.src === 'auto') && st1.some((o) => o.value === 'example.org') && jx(await logs({ type: 'ops', day: dayOf(now()), limit: '3' })).rows.some((x) => x.action === 'autosite.clear' && x.detail === 'count=1'));
  }
  r = await api('GET', '/api/logs/export', { q: { type: 'ops', day: dayOf(now()) } }); const full = jx(await logs({ type: 'ops', day: dayOf(now()), limit: '2000' }));
  ck('logs/export: text/plain lines, one per row', r.status === 200 && /^text\/plain; charset=utf-8/.test(r.headers['content-type']) && r.text.split('\n').filter(Boolean).length === full.total && r.text.split('\n')[0].split('\t').length === 5);
  const y = dayOf(addDays(now(), -3)); r = await api('POST', '/api/logs/clear', { form: { type: 'ops', before: dayOf(now()) } }); const afterOps = jx(await logs({ type: 'ops', day: y })), cleared = await logs({ type: 'ops', day: dayOf(now()) });
  ck('logs/clear before=today removes older ops rows, returns freed bytes, logs a logs.clear row', jx(r).ok === true && jx(r).freed > 0 && afterOps.total === 0 && jx(cleared).rows.some((x) => x.action === 'logs.clear'));
  r = await api('POST', '/api/logs/clear', { form: { type: 'bogus' } }); ck('logs/clear: invalid type -> E_INVALID', jx(r).code === 'E_INVALID');
  r = await api('POST', '/api/logs/clear', { q: { type: 'access' } }); const after = jx(await api('GET', '/api/settings')).usage; r2 = await logs({ type: 'proxy' });
  ck('logs/clear access (query params work): access and proxy go together, usage shrinks', jx(r).freed > 0 && jx(r2).total === 0 && after.access === after.proxy);

  /* ---- 流量统计 (GET /api/stats) ---- */
  {
    const st = async (rg, lang) => jx(await api('GET', '/api/stats', { q: rg === undefined ? {} : { range: rg }, lang })), RG = ['today', '3d', '7d', '30d', '90d'], sm = (a, k) => a.reduce((s, x) => s + x[k], 0);
    const all = async () => { let o; for (let k = 0; k < 3; k++) { const m0 = Math.floor(now() / 60000); o = {}; for (const g of RG) o[g] = await st(g); if (Math.floor(now() / 60000) === m0) break; } return o; };   // 今天这一小时按分钟折算: 整批请求在同一分钟内才能互相比较
    const S0 = await all(), H = S0.today, hn = new Date().getHours(), hv = (i) => H.series[i].up + H.series[i].down, D90 = S0['90d'], sn = dayOf(addDays(now(), -41)), dN = { '3d': 3, '7d': 7, '30d': 30, '90d': 90 };
    r = await rq('GET', '/api/stats?range=7d'); r2 = await api('GET', '/api/stats', { q: { range: 'week' } });
    ck('stats: needs a token (401 E_AUTH); an unknown range -> E_INVALID; no range = today', r.status === 401 && jx(r).code === 'E_AUTH' && jx(r2).code === 'E_INVALID' && jx(r2).ok === false && (await st()).range === 'today');
    ck('stats today: hourly, 24 items t=00..23, from = to = today, nothing after the current hour, quiet nights and busy evenings', H.granularity === 'hour' && H.series.length === 24 && H.series.every((x, i) => x.t === pad(i)) && H.from === dayOf(now()) && H.to === H.from
      && H.series.every((x, i) => i <= hn || x.up + x.down === 0) && (hn < 22 || hv(3) < hv(21)), H.series);
    ck('stats 3d/7d/30d/90d: daily, 3/7/30/90 items oldest first, t = consecutive local dates ending today, from/to match', Object.keys(dN).every((g) => { const d = S0[g], n = dN[g]; return d.granularity === 'day' && d.series.length === n && d.series.every((x, i) => x.t === dayOf(addDays(now(), i - n + 1))) && d.from === d.series[0].t && d.to === dayOf(now()); }));
    ck('stats: total = sum(series), per bucket direct+pin+auto = up+down, routes add up to total (every range, integers)', RG.every((g) => { const d = S0[g]; return d.series.every((x) => x.direct + x.pin + x.auto === x.up + x.down && ['up', 'down', 'direct', 'pin', 'auto'].every((k) => Number.isInteger(x[k]) && x[k] >= 0))
      && d.total.up === sm(d.series, 'up') && d.total.down === sm(d.series, 'down') && ['up', 'down'].every((k) => d.routes.direct[k] + d.routes.pin[k] + d.routes.auto[k] === d.total[k]); }));
    const sv = jx(await api('GET', '/api/state')).servers.filter((x) => x.role === 'pin' || x.role === 'auto').map((x) => x.tag), nt = (n) => n.up + n.down, last = D90.nodes[D90.nodes.length - 1];
    ck('stats nodes: pin/auto servers only, sorted by total desc, sum = routes.pin + routes.auto (every range); a few dominate, some are tiny', D90.nodes.length >= 8 && nt(D90.nodes[0]) > 20 * nt(last)
      && RG.every((g) => { const d = S0[g]; return d.nodes.every((n, i) => sv.indexOf(n.tag) >= 0 && (i === 0 || nt(d.nodes[i - 1]) >= nt(n))) && sm(d.nodes, 'up') + sm(d.nodes, 'down') === ['pin', 'auto'].reduce((s, k) => s + d.routes[k].up + d.routes[k].down, 0); }));
    const tl = (g, n) => JSON.stringify(S0[g].series.slice(-n));
    ck('stats: ranges agree (today = last day of 3d; 3d / 7d / 30d are the tails of 7d / 30d / 90d)', S0['3d'].series[2].up === H.total.up && S0['3d'].series[2].down === H.total.down && tl('7d', 3) === tl('3d', 3) && tl('30d', 7) === tl('7d', 7) && tl('90d', 30) === tl('30d', 30));
    ck('stats: since = 41 days ago by default, older days are 0 (90d is partial), retention_days 92', RG.every((g) => S0[g].since === sn && S0[g].retention_days === 92) && D90.series.every((x) => (x.t < sn) === (x.up + x.down === 0)) && D90.series.filter((x) => x.t >= sn).length === 42);
    const again = await st('30d'); ck('stats: deterministic per date (past days are identical on every request)', JSON.stringify(again.series.slice(0, 29)) === JSON.stringify(S0['30d'].series.slice(0, 29)));
    await ctl('stats=empty'); const E9 = await st('90d'), E0 = await st('today');
    ck('stats=empty: since "", every range all zeros with the full series length, nodes []', E9.since === '' && E9.series.length === 90 && E0.series.length === 24 && [E9, E0].every((d) => d.total.up + d.total.down === 0 && d.nodes.length === 0 && d.series.every((x) => x.up + x.down + x.direct + x.pin + x.auto === 0)));
    await ctl('stats=short'); const SH = await st('30d'); await ctl('stats=normal'); const NO = await st('30d');
    ck('stats=short: history starts 2 days ago (older days are 0); stats=normal restores 41 days', SH.since === dayOf(addDays(now(), -2)) && SH.series.filter((x) => x.up + x.down > 0).length === 3 && NO.since === sn);
    await ctl('statsfail=1'); r = await api('GET', '/api/stats', { q: { range: '7d' } }); r2 = await api('GET', '/api/stats', { q: { range: '7d' } });
    ck('statsfail=1: the next /api/stats request fails once with E_NETWORK, then it recovers', jx(r).code === 'E_NETWORK' && jx(r).ok === false && jx(r2).ok === true);
    r = await api('GET', '/api/stats', { q: { range: 'x' }, lang: 'en' }); ck('stats: the error text follows X-Enana-Lang', jx(r).error === 'Invalid statistics range.' && jx(await api('GET', '/api/stats', { q: { range: 'x' }, lang: 'zh' })).error === '统计范围无效');
  }

  /* ---- 规则库 / DNS ---- */
  r = await api('GET', '/api/rules'); const sets = jx(r).sets;
  ck('rules: 26 embedded sets (3 essential) with bilingual fields', sets.length === 26 && sets.filter((s) => s.essential).length === 3 && sets.every((s) => 'tag' in s && 'name' in s && s.name_en && s.desc_en && 'repo' in s && 'present' in s && 'bytes' in s && 'updated' in s && 'enabled' in s && 'essential' in s && s.custom === false)
    && sets.filter((s) => s.tag === 'geosite-cn')[0].essential === true && typeof jx(r).updated === 'number');
  r = await api('POST', '/api/rules/toggle', { form: { tag: 'geosite-cn', on: '0' } }); ck('rules/toggle: essential cannot be disabled -> E_INVALID', jx(r).code === 'E_INVALID');
  r = await api('POST', '/api/rules/toggle', { form: { tag: 'nope', on: '1' } }); ck('rules/toggle: unknown tag -> E_NOT_FOUND', jx(r).code === 'E_NOT_FOUND');
  r = await api('POST', '/api/rules/toggle', { form: { tag: 'geosite-ads', on: '1' } }); jb = await run(r); r = await api('GET', '/api/rules');
  ck('rules/toggle on: job downloads it (present + enabled)', jb.state === 'done' && jx(r).sets.filter((s) => s.tag === 'geosite-ads')[0].present === true && jx(r).sets.filter((s) => s.tag === 'geosite-ads')[0].enabled === true);
  const add = (name, url, policy) => api('POST', '/api/rules/custom/add', { form: { name, url, policy } });
  r = await add('lst1', 'https://lists.example.com/a.txt', 'pin'); ck('custom/add: url must end in .srs -> E_INVALID', jx(r).code === 'E_INVALID');
  r = await add('lst1', 'ftp://lists.example.com/a.srs', 'pin'); ck('custom/add: url must be http(s) -> E_INVALID', jx(r).code === 'E_INVALID');
  r = await add('lst1', 'https://lists.example.com/a.srs', 'maybe'); ck('custom/add: bad policy -> E_INVALID', jx(r).code === 'E_INVALID');
  r = await add('my-list', 'https://lists.example.com/a.srs', 'pin'); const dup = await add('MY-LIST', 'https://lists.example.com/b.srs', 'auto'); jb = await run(r); r = await api('GET', '/api/rules');
  const cs = jx(r).sets.filter((s) => s.custom)[0]; const cat = await rq('GET', '/ui/catalog.json', { noHdr: true });
  ck('custom/add: job -> custom:true set with policy; duplicate name -> E_INVALID; catalog gets svc-rs-<tag>', jb.state === 'done' && cs && cs.tag === 'my-list' && cs.policy === 'pin' && cs.essential === false && jx(dup).code === 'E_INVALID' && jx(cat).entries.some((e) => e.tag === 'svc-rs-my-list'));
  r = await add('lst2', 'https://fail.example.com/x.srs', 'auto'); jb = await run(r); ck('custom/add: a failing download makes the job fail and nothing is added', jb.state === 'error' && !jx(await api('GET', '/api/rules')).sets.some((s) => s.tag === 'lst2'));
  r = await api('POST', '/api/rules/custom/delete', { form: { tag: 'geosite-cn' } }); ck('custom/delete: built-in set -> E_INVALID', jx(r).code === 'E_INVALID');
  r = await api('POST', '/api/rules/custom/delete', { form: { tag: 'my-list' } }); jb = await run(r); ck('custom/delete -> job, set gone', jb.state === 'done' && !jx(await api('GET', '/api/rules')).sets.some((s) => s.custom));
  const upBefore = jx(await api('GET', '/api/rules')).updated; r = await api('POST', '/api/update-rules'); jb = await run(r);
  ck('update-rules: job result {changed, failed}, updated refreshed', jb.state === 'done' && typeof jb.result.changed === 'number' && jb.result.failed === 0 && jx(await api('GET', '/api/rules')).updated > upBefore, jb);
  r = await api('GET', '/api/dns'); const dns = jx(r);
  ck('dns: settings, hosts [], bilingual presets (8 cn / 7 global), structured pipeline', dns.settings.cn === 'alidns' && dns.settings.leak_guard === true && dns.presets.cn.length === 8 && dns.presets.global.length === 7 && Array.isArray(dns.hosts) && dns.hosts.length === 0 && dns.presets.cn.every((p) => 'id' in p && 'name' in p && 'desc' in p && 'url' in p && 'name_en' in p && 'desc_en' in p)
    && dns.pipeline.map((x) => x.id).join() === 'direct,cn,proxy,global' && dns.pipeline[0].match === 'direct' && dns.pipeline[0].via === 'direct' && dns.pipeline[1].match === 'geosite-cn' && dns.pipeline[1].via === 'direct' && dns.pipeline[2].match === 'proxy' && dns.pipeline[2].server === 'proxy'
    && dns.pipeline[3].match === 'all' && dns.pipeline[3].via === 'auto' && dns.pipeline[3].server === 'cloudflare' && dns.pipeline.every((x) => !!x.server_name && !!x.server_name_en && !!x.detail));
  r = await api('POST', '/api/dns', { form: { cn: 'bogus' } }); ck('dns: unknown preset -> E_INVALID', jx(r).code === 'E_INVALID');
  r = await api('POST', '/api/dns', { form: { cn: 'custom', cn_custom: '' } }); ck('dns: custom selected without an address -> E_INVALID', jx(r).code === 'E_INVALID');
  r = await api('POST', '/api/dns', { form: { global_custom: 'ftp://dns.example.com' } }); ck('dns: custom url must be udp:// tls:// https:// (lib/dns.sh regex) -> E_INVALID', jx(r).code === 'E_INVALID');
  r = await api('POST', '/api/dns', { form: { cn: 'custom', cn_custom: 'tls://dns.example.com:853', ads_block: '1', leak_guard: '1', via: 'PIN' } }); jb = await run(r); const d2 = jx(await api('GET', '/api/dns'));
  ck('dns: valid change -> job; ads item appears first; custom name shows the host', jb.state === 'done' && d2.settings.cn === 'custom' && d2.settings.ads_block === true && d2.pipeline[0].id === 'ads' && d2.pipeline[0].server === 'reject' && d2.pipeline[0].via === 'none'
    && d2.pipeline[1].server === 'custom' && /dns\.example\.com:853/.test(d2.pipeline[1].server_name) && d2.pipeline.filter((x) => x.id === 'global')[0].via === 'pin' && d2.pipeline.filter((x) => x.id === 'proxy')[0].via === 'pin');
  r = await api('POST', '/api/dns', { form: { leak_guard: '0', ads_block: '0', cn: 'alidns' } }); await run(r); const d3 = jx(await api('GET', '/api/dns'));
  ck('dns: leak_guard off -> the global step uses the cn server, direct (the proxy row stays)', d3.pipeline.map((x) => x.id).join() === 'direct,cn,proxy,global' && d3.pipeline[3].server === 'alidns' && d3.pipeline[3].via === 'direct');
  r = await api('POST', '/api/dns/test', { form: { name: 'example.com' } }); ck('dns/test: answers inside 203.0.113.0/24 + ms (deterministic)', jx(r).ok === true && jx(r).name === 'example.com' && jx(r).answers.length >= 1 && jx(r).answers.every((a) => /^203\.0\.113\.\d+$/.test(a)) && jx(r).ms > 0);
  r2 = await api('POST', '/api/dns/test', { form: { name: 'example.com' } }); ck('dns/test: same name -> same answers', JSON.stringify(jx(r).answers) === JSON.stringify(jx(r2).answers));
  r = await api('POST', '/api/dns/test', { form: { name: 'nxdomain.example.com' } }); ck('dns/test: nxdomain.example.com -> empty answers', jx(r).ok === true && jx(r).answers.length === 0);
  r = await api('POST', '/api/dns/test', { form: { name: 'slow.example.com' } }); ck('dns/test: slow.example.com -> ms about 900', jx(r).ms >= 850 && jx(r).ms <= 950, jx(r));
  r = await api('POST', '/api/dns/test', { form: { name: 'fail.example.com' } }); ck('dns/test: fail.example.com -> E_NETWORK', jx(r).ok === false && jx(r).code === 'E_NETWORK');
  r = await api('POST', '/api/dns/test', { form: { name: 'not a host' } }); ck('dns/test: invalid hostname -> E_INVALID', jx(r).code === 'E_INVALID');
  r = await clashR('GET', '/dns/query?name=example.com&type=A'); ck('Clash /dns/query answers', r.status === 200 && jx(r).Status === 0 && jx(r).Answer.length >= 1);

  /* ---- 本机 IP / 测速 ---- */
  const net = async (m) => jx(await api('GET', '/api/net/info', { q: { mock: m } }));
  let n = await net('normal'); ck('net/info normal: direct CN + PIN/Global ok with different 203.0.113.x IPs, lan, checked', n.state === 'normal' && n.direct.ok && n.direct.country === 'CN' && n.routes.length === 2 && n.routes.every((x) => x.ok && /^203\.0\.113\./.test(x.ip)) && n.routes[0].ip !== n.routes[1].ip
    && n.lan.ip === '192.168.1.23' && n.lan.iface === 'en0' && n.checked > 0 && /^AS64\d{3}$/.test(n.direct.asn) && /Example Net/.test(n.direct.isp));
  n = await net('limited'); ck('net/info limited: reason + one route ok, the other http_403', n.state === 'limited' && !!n.reason && n.routes.filter((x) => x.ok).length === 1 && n.routes.filter((x) => !x.ok)[0].reason === 'http_403');
  n = await net('blocked'); ck('net/info blocked: direct timeout, routes failed', n.state === 'blocked' && n.direct.ok === false && n.direct.reason === 'timeout' && n.routes.every((x) => !x.ok && ['timeout', 'reset'].indexOf(x.reason) >= 0) && !!n.reason);
  n = await net('unknown'); ck('net/info unknown: checked > 0', n.state === 'unknown' && n.checked > 0);
  n = await net('unreachable'); ck('net/info unreachable: everything fails with dns/timeout', n.direct.ok === false && n.direct.reason === 'dns' && n.routes.every((x) => !x.ok && ['dns', 'timeout'].indexOf(x.reason) >= 0));
  n = await net('none'); ck('net/info none: {ok:true, checked:0}', JSON.stringify(n) === '{"ok":true,"checked":0}');
  n = await net('noservers'); ck('net/info noservers: routes []', n.routes.length === 0 && n.direct.ok === true);
  r = await api('GET', '/api/net/info', { q: { mock: 'bogus' } }); ck('net/info: unknown ?mock= -> E_INVALID', jx(r).code === 'E_INVALID');
  await ctl('net=none'); r = await api('GET', '/api/net/info'); const nb = jx(r).checked; r = await api('POST', '/api/net/refresh'); jb = await run(r); n = jx(await api('GET', '/api/net/info'));
  ck('net/refresh: job net-info-*, then data exists with checked updated (net=none -> normal)', /^net-info-/.test(jx(r).job) && jb.state === 'done' && nb === 0 && n.checked > 0 && n.state === 'normal');
  r = await api('GET', '/api/speedtest/plan'); const pl = jx(r), tg = pl.targets;
  ck('speedtest/plan: 63 targets (15 global / 12 cn / 6 carrier / 16 dev / 14 media, 20 default) under *.example.com, nodes with delay, defaults (pins first), est', tg.length === 63 && tg.filter((x) => x.group === 'global').length === 15 && tg.filter((x) => x.group === 'cn').length === 12 && tg.filter((x) => x.group === 'carrier').length === 6
    && tg.filter((x) => x.group === 'dev').length === 16 && tg.filter((x) => x.group === 'media').length === 14 && tg.filter((x) => x.default === true).length === 20
    && tg.every((x) => /^https:\/\/[a-z0-9-]+\.example\.com\//.test(x.url) && x.id === x.id.toLowerCase() && x.name && x.icon && typeof x.default === 'boolean') && pl.nodes.length === 22 && pl.nodes.some((x) => x.delay === null) && pl.nodes.some((x) => x.delay > 0)
    && pl.defaults.mode === 'both' && pl.defaults.speed === true && pl.defaults.nodes.length === 4 && pl.defaults.nodes[0] === SEED_PIN[0] && pl.defaults.nodes[1] === SEED_PIN[1] && pl.est.seconds >= 55 && pl.est.seconds <= 65 && pl.est.mb >= 35 && pl.est.mb <= 45 && pl.node_available && pl.direct_available, pl);
  r = await api('POST', '/api/speedtest/start', { form: { mode: 'bogus' } }); ck('speedtest/start: bad mode -> E_INVALID', jx(r).code === 'E_INVALID');
  r = await api('POST', '/api/speedtest/start', { form: { mode: 'node', nodes: pl.nodes.slice(0, 13).map((x) => x.tag).join(',') } }); ck('speedtest/start: more than 12 nodes -> E_INVALID', jx(r).code === 'E_INVALID');
  r = await api('POST', '/api/speedtest/start', { form: { nodes: 'no-such-node' } }); ck('speedtest/start: unknown node -> E_INVALID', jx(r).code === 'E_INVALID');
  r = await api('POST', '/api/speedtest/start', { form: { targets: 'google,nope' } }); ck('speedtest/start: unknown target -> E_INVALID', jx(r).code === 'E_INVALID');
  FAST = 8; r = await api('POST', '/api/speedtest/start', { form: { mode: 'both' } }); const sid = jx(r).id; r2 = await api('POST', '/api/speedtest/start');
  ck('speedtest/start -> {ok, id:st-*}; a second start -> E_RUNNING', /^st-\d+-\d+$/.test(sid) && jx(r2).code === 'E_RUNNING');
  r = await api('POST', '/api/net/refresh'); ck('net/refresh while a speed test runs -> E_BUSY', jx(r).code === 'E_BUSY');
  const seen = {}; let st, midOk = false;
  for (let i = 0; i < 2000; i++) { st = jx(await api('GET', '/api/speedtest/status', { q: { id: sid } })); seen[st.phase] = 1; if (st.state === 'running' && st.pct > 20 && st.pct < 90 && st.cells.some((c) => c.st === 'pending') && st.cells.some((c) => c.st === 'ok') && st.msg) midOk = true; if (st.state !== 'running') break; await nap(8); }
  ck('speedtest/status: phases ip, direct, nodes, speed; progress mid-run with pending + ok cells and a message', !!(seen.ip && seen.direct && seen.nodes && seen.speed) && midOk, Object.keys(seen));
  const nodesT = pl.defaults.nodes, cellOf = (a, b) => st.cells.filter((c) => c.t === a && c.r === b)[0];
  ck('speedtest finished: done, pct 100, routes x targets cells, node x cn/carrier are skip', st.state === 'done' && st.pct === 100 && st.routes.length === 5 && st.targets.length === 20 && st.cells.length === 100 && st.cells.filter((c) => c.st === 'skip').length === 36
    && st.cells.every((c) => c.st !== 'pending') && st.routes[0].kind === 'direct' && st.routes[1].role === 'pin' && st.started > 0 && st.elapsed >= 15 && st.elapsed <= 25, [st.state, st.cells.filter((c) => c.st === 'pending').length]);
  ck('speedtest cells: ok / slow / limited / fail all occur, values consistent with the status rules', st.cells.some((c) => c.st === 'ok' && c.ms >= 10 && c.ms <= 800 && c.http > 0) && st.cells.some((c) => c.st === 'slow' && c.ms > 800) && st.cells.some((c) => c.st === 'limited' && [403, 429, 451, 503].indexOf(c.http) >= 0)
    && st.cells.some((c) => c.st === 'fail' && ['timeout', 'dns', 'reset', 'refused', 'tls'].indexOf(c.err) >= 0 && c.ms === 0), st.cells.map((c) => c.st).join('').length);
  ck('speedtest speeds + summary (best node, avg_ms/ok/total per route)', st.speeds.length === 6 && st.speeds.filter((s) => s.r === 'direct').length === 2 && st.speeds.every((s) => ['cn', 'global'].indexOf(s.kind) >= 0 && s.kbps >= 0) && nodesT.indexOf(st.summary.best) >= 0
    && st.summary.total.direct === 20 && st.summary.total[nodesT[0]] === 11 && st.summary.ok.direct >= 9 && st.summary.avg_ms.direct > 0 && cellOf('google', 'direct').st === 'fail' && cellOf('bing', 'direct').st === 'ok' && st.ip.state && st.ip.direct && Array.isArray(st.ip.routes), st.summary);
  r = await api('GET', '/api/speedtest/last'); r2 = await api('GET', '/api/speedtest/status'); ck('speedtest/last + status without id return the finished test', jx(r).id === sid && jx(r2).id === sid && jx(r).state === 'done');
  r = await api('POST', '/api/speedtest/stop', { q: { id: sid } }); ck('speedtest/stop on a finished test is a no-op ok', jx(r).ok === true && jx(await api('GET', '/api/speedtest/last')).state === 'done');
  r = await api('POST', '/api/speedtest/start', { form: { mode: 'direct', speed: '0', targets: 'google,bing' } }); const sid2 = jx(r).id; await nap(120); r = await api('POST', '/api/speedtest/stop', { q: { id: sid2 } }); const stp = jx(await api('GET', '/api/speedtest/status'));
  ck('speedtest/stop on a running test -> stopped immediately, no speeds when speed=0', jx(r).ok === true && stp.id === sid2 && stp.state === 'stopped' && stp.speeds.length === 0 && stp.cells.length === 2 && stp.msg.length > 0, [sid2, jx(r), stp.id, stp.state, stp.cells && stp.cells.length, stp.speeds && stp.speeds.length]);
  FAST = F0; r = await api('GET', '/api/speedtest/status', { q: { id: 'st-1-1' } }); ck('speedtest/status: unknown id -> E_NOT_FOUND', jx(r).code === 'E_NOT_FOUND');
  await ctl('speedlast=none'); r = await api('GET', '/api/speedtest/last'); ck('speedlast=none -> {"ok":true,"none":true}', JSON.stringify(jx(r)) === '{"ok":true,"none":true}');
  await ctl('speedlast=seed'); r = await api('GET', '/api/speedtest/last'); ck('speedlast=seed -> a finished test dated yesterday', jx(r).state === 'done' && jx(r).started < startOfDay(now()) / 1000 && jx(r).started > startOfDay(now()) / 1000 - 86400 && jx(r).pct === 100);

  /* ---- 更新 ---- */
  r = await api('GET', '/api/update/check', { lang: 'en' }); const up = jx(r);
  ck('update/check: current/latest/available, bilingual notes (en selected), core, url, empty error', up.current === '2.1.0' && up.latest === '2.2.0' && up.available === true && up.notes === up.notes_en && up.notes_zh.length > 0 && up.notes_en !== up.notes_zh && up.core.current === '1.14.2' && up.core.latest === '1.14.3'
    && up.core.available === true && up.error === '' && up.code === '' && /^https:\/\//.test(up.url) && up.checked > 0);
  r = await api('GET', '/api/update/check', { q: { force: '1' } }); ck('update/check?force=1 refreshes `checked`', jx(r).checked >= up.checked && jx(r).ok === true);
  await ctl('update=fail'); r = await api('GET', '/api/update/check'); ck('update=fail -> ok:true with error + E_NETWORK and the cached fields', jx(r).ok === true && !!jx(r).error && jx(r).code === 'E_NETWORK' && jx(r).latest === '2.2.0');
  await ctl('update=on&failnext=/api/update/check'); r = await api('GET', '/api/update/check'); r2 = await api('GET', '/api/update/check'); ck('failnext=/api/update/check fails once', jx(r).code === 'E_NETWORK' && jx(r2).code === '');
  r = await api('POST', '/api/update/apply', { q: { what: 'bogus' } }); ck('update/apply: bad what -> E_INVALID', jx(r).code === 'E_INVALID');
  r = await api('POST', '/api/update/apply', { q: { what: 'core' } }); jb = await run(r); r2 = await clash('GET', '/version'); await nap(150); const r3 = await clash('GET', '/version');
  ck('update/apply core: job done, Clash /version becomes 1.14.3', jb.state === 'done' && /1\.14\.3$/.test(jx(r3).version) && jx(await api('GET', '/api/state')).core === '1.14.3', [jb.state, r3.text]);
  FAST = 8; r = await api('POST', '/api/update/apply', { q: { what: 'app' } }); const jid = jx(r).job; let down = 0, back = false;
  for (let i = 0; i < 600; i++) { const s = await rq('GET', '/api/auth/status'); if (s.status === 0) down++; else if (down > 0) { back = true; break; } await nap(5); }
  jb = await waitJob(jid); r = await rq('GET', '/ui/env.json', { noHdr: true }); const st2 = jx(await api('GET', '/api/state')), up2 = jx(await api('GET', '/api/update/check'));
  ck('update/apply app: helper unreachable for a while (ui + ctl keep working), then version 2.2.0 everywhere, nothing left to update', down > 0 && back && jb.state === 'done' && st2.version === '2.2.0' && jx(r).version === '2.2.0' && up2.available === false && up2.core.available === false && st2.update.available === false, [down, back, jb.state]);
  FAST = F0; r = await api('POST', '/api/update/apply', { q: { what: 'app' } }); ck('update/apply when up to date -> E_INVALID', jx(r).code === 'E_INVALID');

  /* ---- 静态文件 / 目录 / 探测 / Clash / 平台 ---- */
  r = await rq('GET', '/', { noHdr: true }); ck('/ redirects to /ui/', r.status === 302 && r.headers.location === '/ui/');
  r = await rq('GET', '/ui/env.json', { noHdr: true }); const env = jx(r);
  ck('ui/env.json: apiBase "" (single origin), ports, probes', env.apiBase === '' && env.apiPort === PORT && env.uiPort === PORT && env.proxyPort === 7890 && env.probe.speedUrl === '/mock/down?bytes=10000000' && env.probe.delayUrl === '/mock/gen204');
  const cj = jx(await rq('GET', '/ui/catalog.json', { noHdr: true })), gids = GROUPS.map((g) => g[0]);
  ck('ui/catalog.json schema 3: 12 groups + groups_en + order + 56 entries with name_en/desc_en/policy/modified', cj.schema === 3 && JSON.stringify(cj.order) === JSON.stringify(gids) && gids.length === 12 && gids.every((g) => cj.groups[g] && cj.groups_en[g]) && cj.entries.length === 56
    && cj.entries.every((e) => e.tag === 'svc-' + e.id && e.name && e.name_en && !CJK.test(e.name_en) && e.desc_en && ['pin', 'auto', 'direct'].indexOf(e.default) >= 0 && Array.isArray(e.domains) && Array.isArray(e.rulesets) && typeof e.cidrs === 'number' && e.group in cj.groups && e.policy === e.default && e.modified === false && e.domains.length >= 3 && e.domains.every((d) => /\.example\.(com|net|org)$/.test(d))));
  if (fs.existsSync(path.join(UI, 'index.html'))) { r = await rq('GET', '/ui/', { noHdr: true }); ck('ui/ serves index.html as text/html', r.status === 200 && /^text\/html/.test(r.headers['content-type'])); }
  r = await rq('GET', '/ui/..%2ftools%2fmock-server.js', { noHdr: true }); r2 = await rq('GET', '/ui/../tools/mock-server.js', { noHdr: true }); ck('no directory traversal out of ui/', r.status !== 200 && r2.status !== 200 && r.text.indexOf('use strict') < 0 && r2.text.indexOf('use strict') < 0);
  r = await rq('GET', '/mock/gen204', { noHdr: true }); ck('probes: /mock/gen204 204 (the exit IPs now come from /api/net/info, not from third-party sites)', r.status === 204);
  r = await rq('GET', '/proxies', { noHdr: true }); ck('Clash API needs Authorization: Bearer (401 otherwise)', r.status === 401);
  r = await clash('GET', '/proxies'); const P = jx(r).proxies, sv = jx(await api('GET', '/api/state')).servers, nAuto = sv.filter((x) => x.role === 'auto').length, nPin = sv.filter((x) => x.role === 'pin').length;
  ck('Clash /proxies: PIN selector, AUTO urltest, Global, Final, svc-<id> per catalog entry, nodes with histories', P.PIN.type === 'Selector' && P.AUTO.type === 'URLTest' && P.Global.type === 'Selector' && P.Final.type === 'Selector' && P['svc-claude'].type === 'Selector'
    && Array.isArray(P[SEED_AUTO[0]].history) && P.AUTO.all.length === nAuto && P.PIN.all.length === nPin);
  r = await clash('PUT', '/proxies/PIN', { name: SEED_PIN[1] }); r2 = await clash('PUT', '/proxies/PIN', { name: 'nope' }); ck('Clash PUT /proxies/PIN: 204, unknown member -> 400', r.status === 204 && r2.status === 400 && jx(await clash('GET', '/proxies')).proxies.PIN.now === SEED_PIN[1]);
  r = await clash('GET', '/proxies/' + encodeURIComponent(SEED_PIN[0]) + '/delay?url=x&timeout=5000'); ck('Clash /proxies/<tag>/delay -> {delay}', r.status === 200 && jx(r).delay > 0, r.text);
  r = await clash('GET', '/configs'); r2 = await clash('PATCH', '/configs', { mode: 'Direct' }); ck('Clash /configs GET + PATCH', jx(r).mode === 'Rule' && r2.status === 204 && jx(await clash('GET', '/configs')).mode === 'Direct'); await clash('PATCH', '/configs', { mode: 'Rule' });
  await ctl('conns=7'); r = await clash('GET', '/connections'); const c0 = jx(r).connections[0];
  ck('Clash /connections honours conns=N; realistic metadata + chains', jx(r).connections.length === 7 && c0.metadata.host && (!c0.metadata.processPath || c0.metadata.processPath.indexOf('/') === 0) && /example\.(com|org|net)$/.test(c0.metadata.host) && Array.isArray(c0.chains) && 'upload' in c0 && 'download' in c0 && jx(r).downloadTotal > 0);
  r = await clash('DELETE', '/connections/' + c0.id); r2 = await clash('DELETE', '/connections'); ck('Clash DELETE /connections/<id> and DELETE /connections -> 204', r.status === 204 && r2.status === 204);
  await ctl('os=windows'); r = await clash('GET', '/connections'); n = jx(await api('GET', '/api/state')); const ap = jx(await api('GET', '/api/apps')).apps[0]; const nw = await net('normal');
  ck('os=windows: platform, backslash .exe paths in apps and connections, shortcut `enana`, lan iface Ethernet', n.platform.os === 'windows' && n.env.shortcut === 'enana' && /^[A-Z]:\\.*\.exe$/.test(ap.path) && jx(r).connections.every((c) => !c.metadata.processPath || /^[A-Z]:\\.*\.exe$/.test(c.metadata.processPath)) && nw.lan.iface === 'Ethernet');
  await ctl('os=darwin'); r = await ctl('helper=down'); r2 = await rq('GET', '/api/auth/status'); const r4 = await rq('GET', '/ui/env.json', { noHdr: true }); await ctl('helper=up'); r = await rq('GET', '/api/auth/status');
  ck('helper=down drops /api/* connections but keeps /ui/ and /mock/ctl up; helper=up restores', r2.status === 0 && r4.status === 200 && r.status === 200);
  await ctl('clash=down'); r = await clash('GET', '/proxies'); r2 = await api('GET', '/api/state'); await ctl('clash=up'); ck('clash=down drops Clash connections only; the helper still answers (env.service=false)', r.status === 0 && r2.status === 200 && jx(r2).env.service === false && jx(await api('GET', '/api/state')).env.service === true);

  /* ---- 添加自己的服务器 (SSH 一键部署): 魔法主机 / 失败码 / 部署 / 记录 / 重新识别 / 凭据不外泄 ---- */
  {
  FAST = 80; const SECRET = 'S3cretPw-xyz', KEYBODY = 'KEYBODY-abc123', SUDO = 'SudoSecret-777', vseen = [];
  const KEYTXT = '-----BEGIN OPENSSH PRIVATE KEY-----\n' + KEYBODY + '\n-----END OPENSSH PRIVATE KEY-----';
  const vcred = (host, extra) => Object.assign({ host, port: '22', user: 'root', mode: 'password', password: SECRET }, extra);
  const vjob = async (p, form, lang) => { const x = await api('POST', p, { form, lang }); vseen.push(x.text); if (!jx(x).job) return { start: jx(x), job: null }; const j = await waitJob(jx(x).job, lang); vseen.push(JSON.stringify(j)); return { start: jx(x), job: j }; };
  const probe = (host, extra, lang) => vjob('/api/vps/probe', vcred(host, extra), lang);
  r = await Promise.all([{ host: 'bad host!' }, { port: '0' }, { user: '' }, { mode: 'telnet' }, { password: '' }, { mode: 'key', password: '' }, { mode: 'key', key: 'not a key' }].map((x) => api('POST', '/api/vps/probe', { form: vcred('203.0.113.10', x) })));
  ck('vps/probe: invalid host / port / user / mode / missing password / key without -----BEGIN -> synchronous E_INVALID', r.every((x) => jx(x).code === 'E_INVALID' && !jx(x).job));
  let pr = await probe('203.0.113.10', {}, 'en'), res = pr.job.result;
  ck('vps/probe default host: job done with EXACTLY the documented result keys (Debian 12 amd64, root, ca-certificates + iproute2 missing, ufw_active, one public IP = the host)', pr.job.state === 'done' && pr.job.steps.length >= 3 && pr.job.steps[0].label === 'Connect to the server'
    && Object.keys(res).sort().join() === ['all_missing', 'arch', 'deps', 'firewall', 'host', 'hostkey', 'hostkey_changed', 'init', 'ips', 'ipv6', 'listening', 'missing', 'node', 'os', 'port', 'privilege', 'singbox', 'support', 'support_note', 'supported', 'user'].join()
    && res.os.id === 'debian' && res.os.version === '12' && res.os.codename === 'bookworm' && res.arch === 'amd64' && res.supported === true && res.support === 'full' && res.privilege === 'root' && res.init === 'systemd' && res.deps[0].installed === true && !!res.deps[0].version
    && res.missing.join() === 'ca-certificates,iproute2' && res.all_missing === false && res.singbox.installed === false && res.node.installed === false && res.firewall === 'ufw_active' && res.ips.length === 1 && res.ips[0].public === '203.0.113.10' && res.ips[0].v === 4 && res.ipv6.length === 0
    && /^SHA256:[A-Za-z0-9+\/]{43}$/.test(res.hostkey) && res.hostkey_changed === false, pr.job);
  const zhNote = jx(await api('GET', '/api/job', { q: { id: pr.job.id }, lang: 'zh' })).result.support_note;
  ck('vps/probe: support_note follows X-Enana-Lang at poll time; fingerprint is stable per host', zhNote !== res.support_note && /受支持/.test(zhNote) && (await probe('203.0.113.10', {})).job.result.hostkey === res.hostkey && (await probe('198.51.100.5', {})).job.result.hostkey !== res.hostkey);
  const sc = {}; for (const h of [20, 30, 31, 40, 50, 51]) sc[h] = (await probe('203.0.113.' + h, {}, 'en')).job.result;
  ck('vps/probe scenarios: .20 minimal Ubuntu arm64 (all_missing, ufw_inactive), .30 everything installed incl. sing-box + node', sc[20].os.id === 'ubuntu' && sc[20].arch === 'arm64' && sc[20].all_missing === true && sc[20].missing.length === 3 && sc[20].firewall === 'ufw_inactive'
    && sc[30].missing.length === 0 && sc[30].singbox.installed === true && !!sc[30].singbox.version && sc[30].node.installed === true);
  ck('vps/probe scenarios: .31 two public IPv4 behind NAT-style local IPs + IPv6, .40 hostkey_changed, .50 CentOS 7 unsupported, .51 Debian 10 best_effort (translated notes)', sc[31].ips.length === 2 && sc[31].ips.map((x) => x.public).join() === '198.51.100.31,198.51.100.32' && sc[31].ips.every((x) => /^10\./.test(x.local) && x.v === 4) && sc[31].ipv6.join() === '2001:db8::31'
    && sc[40].hostkey_changed === true && sc[50].supported === false && sc[50].support === 'no' && /Unsupported/.test(sc[50].support_note) && sc[51].supported === true && sc[51].support === 'best_effort' && /end-of-life/.test(sc[51].support_note));
  const bads = {}; for (const h of [60, 61, 62, 63, 64, 65]) bads[h] = (await probe('203.0.113.' + h, {}, 'zh')).job;
  ck('vps/probe failures: .60 E_SSH_UNREACHABLE .61 E_SSH_AUTH .62 E_SSH_KEY .63 E_SSH_NO_CLIENT .64 / .65 E_VPS_PRIVILEGE — state error, translated msg, code on the job AND in result.code, failing step marked', [[60, 'E_SSH_UNREACHABLE'], [61, 'E_SSH_AUTH'], [62, 'E_SSH_KEY'], [63, 'E_SSH_NO_CLIENT'], [64, 'E_VPS_PRIVILEGE'], [65, 'E_VPS_PRIVILEGE']]
    .every((x) => bads[x[0]].state === 'error' && bads[x[0]].code === x[1] && bads[x[0]].result.code === x[1] && bads[x[0]].msg.length > 4 && bads[x[0]].steps.filter((st) => st.state === 'error').length === 1 && bads[x[0]].pct === 100), Object.keys(bads).map((h) => bads[h].code));
  const pe = (await probe('203.0.113.61', {}, 'en')).job; pr = await probe('203.0.113.65', { sudo_password: SUDO }); const pw = (await probe('203.0.113.10', { password: 'wrong-pass' })).job, hk = (await probe('203.0.113.10', { hostkey: 'SHA256:wrong' })).job;
  ck('vps/probe: error msg translated to English; .65 succeeds only with sudo_password (privilege sudo_password); password wrong-pass -> E_SSH_AUTH; a hostkey that differs from the host fingerprint -> E_SSH_HOSTKEY', /Login failed/.test(pe.msg) && pr.job.state === 'done' && pr.job.result.privilege === 'sudo_password'
    && pw.state === 'error' && pw.code === 'E_SSH_AUTH' && hk.state === 'error' && hk.code === 'E_SSH_HOSTKEY');
  const pk = await probe('203.0.113.10', { mode: 'key', password: undefined, key: KEYTXT, passphrase: 'pp-secret-1' }); const pn = (await probe('203.0.113.10', { user: 'ubuntu' })).job.result;
  ck('vps/probe: key mode with a pasted private key works; a non-root user gets privilege sudo_nopass', pk.job.state === 'done' && pn.privilege === 'sudo_nopass' && pn.user === 'ubuntu');
  const fp10 = res.hostkey, prov = (host, extra, lang) => vjob('/api/vps/provision', vcred(host, Object.assign({ hostkey: fingerprint(host), name: 'my-vps', role: 'pin', install_deps: '1' }, extra)), lang);
  r = await api('POST', '/api/vps/provision', { form: vcred('203.0.113.10', { name: 'my-vps', role: 'pin' }) }); ck('vps/provision: hostkey is required -> E_INVALID', jx(r).code === 'E_INVALID');
  r = await api('POST', '/api/vps/provision', { form: vcred('203.0.113.10', { hostkey: fp10, role: 'boss' }) }); ck('vps/provision: role must be pin|auto -> E_INVALID', jx(r).code === 'E_INVALID');
  const e1 = (await prov('203.0.113.10', { install_deps: '0' })).job, e2 = (await prov('203.0.113.50', {})).job, e3 = (await prov('203.0.113.70', {}, 'en')).job, e4 = (await prov('203.0.113.10', { hostkey: 'SHA256:other' })).job;
  ck('vps/provision failures: install_deps=0 with missing deps -> E_VPS_DEPS; unsupported OS -> E_VPS_UNSUPPORTED; .70 fails at 验证连通 (E_VPS_VERIFY, security-group hint, 9 steps, step 7 error); wrong hostkey -> E_SSH_HOSTKEY', e1.state === 'error' && e1.code === 'E_VPS_DEPS'
    && e2.state === 'error' && e2.code === 'E_VPS_UNSUPPORTED' && e3.state === 'error' && e3.code === 'E_VPS_VERIFY' && e3.result.code === 'E_VPS_VERIFY' && e3.result.port === 443 && /does not allow port 443\/tcp/.test(e3.msg) && e3.steps.length === 9 && e3.steps[6].state === 'error' && e3.steps.slice(0, 6).every((x) => x.state === 'done') && e3.steps.slice(7).every((x) => x.state === 'todo')
    && e3.steps[6].label === 'Verify the connection' && e4.code === 'E_SSH_HOSTKEY', [e1.code, e2.code, e3.code, e4.code]);
  r = await api('GET', '/api/vps'); ck('vps: nothing is recorded by probes or failed provisioning', jx(r).ok === true && jx(r).vps.length === 0);
  const nBefore = jx(await api('GET', '/api/state')).servers.length; let pv = await prov('203.0.113.10', {}, 'en'); const pj = pv.job, st1 = jx(await api('GET', '/api/state')), vl = jx(await api('GET', '/api/vps')).vps;
  ck('vps/provision happy path: 9 translated steps, result {nodes[{tag,server,port:443,type:vless,egress}], ips, vps}, VLESS node added with the chosen role', pj.state === 'done' && pj.steps.length === 9 && pj.steps.every((x) => x.state === 'done') && pj.result.nodes.length === 1
    && JSON.stringify(pj.result.nodes[0]) === JSON.stringify({ tag: 'my-vps-203.0.113.10', server: '203.0.113.10', port: 443, type: 'vless', egress: '203.0.113.10' }) && pj.result.ips.join() === '203.0.113.10' && /^vps_[0-9a-f]{8}$/.test(pj.result.vps)
    && st1.servers.length === nBefore + 1 && st1.servers.filter((x) => x.tag === 'my-vps-203.0.113.10')[0].type === 'vless' && st1.servers.filter((x) => x.tag === 'my-vps-203.0.113.10')[0].role === 'pin', pj);
  ck('vps: GET /api/vps lists the record (id, name, host, ssh_port, user, os, hostkey, ips, nodes, updated) and nothing secret', vl.length === 1 && Object.keys(vl[0]).sort().join() === ['host', 'hostkey', 'id', 'ips', 'name', 'nodes', 'os', 'ssh_port', 'updated', 'user'].join() && vl[0].hostkey === fingerprint('203.0.113.10') && vl[0].id === pj.result.vps && vl[0].ssh_port === 22 && vl[0].user === 'root'
    && /Debian/.test(vl[0].os) && vl[0].nodes.join() === 'my-vps-203.0.113.10' && vl[0].ips.join() === '203.0.113.10' && vl[0].updated > 0);
  r = await clashR('GET', '/proxies'); ck('vps/provision: the new node is live in the core (PIN selector member)', jx(r).proxies.PIN.all.indexOf('my-vps-203.0.113.10') >= 0 && jx(r).proxies['my-vps-203.0.113.10'].type === 'VLESS');
  pv = await prov('203.0.113.31', { name: 'dual', role: 'auto' }); const dj = pv.job, dl = jx(await api('GET', '/api/vps')).vps.filter((x) => x.host === '203.0.113.31')[0];
  ck('vps/provision on the 2-IP host: one node per egress IP (egress == server), both in the record', dj.state === 'done' && dj.result.nodes.map((x) => x.tag).join() === 'dual-198.51.100.31,dual-198.51.100.32' && dj.result.nodes.every((x) => x.egress === x.server && x.type === 'vless' && x.port === 443) && dj.result.ips.length === 2 && dl.nodes.length === 2 && dl.ips.length === 2);
  const rd = (id, host, extra, lang) => vjob('/api/vps/redetect', vcred(host, Object.assign({ id }, extra)), lang);
  const r1 = (await rd(dl.id, '203.0.113.31', {}, 'en')).job, dl2 = jx(await api('GET', '/api/vps')).vps.filter((x) => x.host === '203.0.113.31')[0], r2n = (await rd(dl.id, '203.0.113.31', {})).job;
  ck('vps/redetect: the first time it finds one extra IP and adds its node (record updated); later runs add nothing', r1.state === 'done' && r1.result.added === 1 && r1.result.nodes[0].tag === 'dual-198.51.100.33' && r1.result.ips.length === 3 && dl2.ips.length === 3 && dl2.nodes.length === 3
    && jx(await api('GET', '/api/state')).servers.some((x) => x.tag === 'dual-198.51.100.33' && x.role === 'auto') && r2n.state === 'done' && r2n.result.added === 0, [r1.result, r2n.result]);
  r = await api('POST', '/api/vps/redetect', { form: vcred('203.0.113.31', { id: 'vps_nope' }) }); const rbad = (await rd(dl.id, '203.0.113.31', { password: 'wrong-pass' })).job;
  ck('vps/redetect: unknown id -> E_NOT_FOUND; SSH failures surface as job errors (E_SSH_AUTH)', jx(r).code === 'E_NOT_FOUND' && rbad.state === 'error' && rbad.code === 'E_SSH_AUTH');
  r = await api('POST', '/api/vps/forget', { form: { id: 'vps_nope' } }); r2 = await api('POST', '/api/vps/forget', { form: { id: dl.id } }); const vl3 = jx(await api('GET', '/api/vps')).vps;
  ck('vps/forget: unknown id -> E_NOT_FOUND; known id removes only the record (nodes stay)', jx(r).code === 'E_NOT_FOUND' && jx(r2).ok === true && vl3.length === 1 && jx(await api('GET', '/api/state')).servers.some((x) => x.tag === 'dual-198.51.100.31'));
  await ctl('vps=reset'); ck('/mock/ctl vps=reset clears the records', jx(await api('GET', '/api/vps')).vps.length === 0);
  const leak = vseen.join('\n') + '\n' + JSON.stringify(jx(await api('GET', '/api/vps'))) + JSON.stringify(jx(await api('GET', '/api/state'))) + (await api('GET', '/api/logs/export', { q: { type: 'ops', day: dayOf(now()) } })).text + JSON.stringify(jx(await logs({ type: 'ops', limit: '2000' })).rows);
  ck('vps: credentials (password, private key, passphrase, sudo password) appear in no response, job, record or log row', [SECRET, KEYBODY, 'pp-secret-1', SUDO, 'wrong-pass'].every((x) => leak.indexOf(x) < 0) && leak.indexOf('vps.probe') > 0);
  FAST = F0;
  }
  r = await api('POST', '/api/servers/import', { q: { sub: 'demo-sub', mode: 'replace' }, body: line('Selftest R', 'auto') }); jb = await run(r);          // 已填充的订阅 + replace = 刷新订阅 (sub.refresh)
  ck('servers/import mode=replace on a populated subscription: removed counted, logged as sub.refresh', jx(r).added === 1 && jx(r).removed === 21 && jb.state === 'done');
  /* ---- 云端同步: 状态 / 设置 / 推送冲突 / 强制推送 / 脏标记 / 拉取 (replace + merge) / 旧密码 / 离线 / 清除 ---- */
  {
  FAST = 80; let r3;
  await ctl('sync=reset'); r = await api('GET', '/api/sync'); const sy = jx(r);
  ck('sync: GET shape — disabled, remote exists (v7, MacBook-Pro, 2048 B, yesterday), local v6 dirty, account = login email, online', Object.keys(sy).sort().join() === ['account', 'auto', 'enabled', 'last_pull', 'last_push', 'local', 'ok', 'online', 'remote'].join() && sy.enabled === false && sy.auto === false && sy.account === D1
    && sy.remote.exists === true && sy.remote.version === 7 && sy.remote.device === 'MacBook-Pro' && sy.remote.size === 2048 && sy.remote.updated > now() / 1000 - 90000 && sy.remote.updated < now() / 1000 - 80000 && sy.local.version === 6 && sy.local.dirty === true && sy.last_pull === 0 && sy.last_push > 0 && sy.online === true, r.text);
  r = await rq('GET', '/api/sync'); ck('sync: needs a token (401)', r.status === 401);
  r = await api('POST', '/api/sync/push'); r2 = await api('POST', '/api/sync/pull', { form: { mode: 'replace' } }); ck('sync disabled: push and pull -> E_INVALID', jx(r).code === 'E_INVALID' && jx(r2).code === 'E_INVALID');
  r = await api('POST', '/api/sync/settings', { form: { auto: '1' } }); r2 = await api('POST', '/api/sync/settings', { form: { enabled: 'yes' } }); ck('sync/settings: auto=1 while disabled -> E_INVALID; bad value -> E_INVALID', jx(r).code === 'E_INVALID' && jx(r2).code === 'E_INVALID');
  r = await api('POST', '/api/sync/settings', { form: { enabled: '1', auto: '1' } }); const on = jx(await api('GET', '/api/sync')); await api('POST', '/api/sync/settings', { q: { enabled: '0' } }); const off = jx(await api('GET', '/api/sync'));
  ck('sync/settings: enabled + auto work (query params too); disabling turns auto off', jx(r).ok === true && on.enabled === true && on.auto === true && off.enabled === false && off.auto === false);
  await api('POST', '/api/sync/settings', { form: { enabled: '1', auto: '0' } });
  r = await api('POST', '/api/sync/push'); ck('sync/push: remote newer than local (7 > 6) -> E_SYNC_CONFLICT', jx(r).code === 'E_SYNC_CONFLICT' && jx(r).ok === false && !!jx(r).error);
  r = await api('POST', '/api/sync/push', { q: { force: '1' } }); jb = await run(r); const pf = jx(await api('GET', '/api/sync'));
  ck('sync/push force=1: job (3 steps), local.version = remote.version + 1, dirty false, last_push set, remote updated by this device', jb.state === 'done' && jb.steps.length === 3 && pf.local.version === 8 && pf.remote.version === 8 && pf.local.dirty === false && pf.last_push >= sy.last_push && pf.remote.device === 'This-Mac' && pf.remote.size > 2048);
  await api('POST', '/api/override', { q: { kind: 'site', value: 'sync.example.com', state: 'pin' } }); const dirty = jx(await api('GET', '/api/sync')).local.dirty;
  r = await api('POST', '/api/sync/push'); jb = await run(r); const p2 = jx(await api('GET', '/api/sync'));
  ck('local changes set dirty:true; a push without conflict bumps the version (9) and clears it', dirty === true && jb.state === 'done' && p2.local.version === 9 && p2.local.dirty === false);
  await ctl('syncremote=newer'); r = await api('POST', '/api/sync/push'); await ctl('syncremote=exists'); r2 = await api('POST', '/api/sync/push'); jb = await run(r2); await ctl('syncremote=none'); const none = jx(await api('GET', '/api/sync')).remote; r3 = await api('POST', '/api/sync/pull', { form: { mode: 'merge' } });
  ck('ctl syncremote: newer -> conflict, exists -> push ok, none -> remote.exists:false and pull -> E_NOT_FOUND', jx(r).code === 'E_SYNC_CONFLICT' && jb.state === 'done' && none.exists === false && none.version === 0 && jx(r3).code === 'E_NOT_FOUND');
  r = await api('POST', '/api/sync/push'); jb = await run(r); ck('push with no remote data creates it', jb.state === 'done' && jx(await api('GET', '/api/sync')).remote.exists === true);
  await ctl('syncremote=newer'); await api('POST', '/api/servers/import', { q: { mode: 'merge' }, body: line('Local Only', 'auto') }).then(run); await ctl('synckey=bad');
  r = await api('POST', '/api/sync/pull', { form: { mode: 'replace' }, lang: 'en' }); let k1 = await waitJob(jx(r).job, 'en'); r = await api('POST', '/api/sync/pull', { form: { mode: 'replace', old_password: 'not-it' } }); const k2 = await waitJob(jx(r).job, 'zh');
  ck('sync/pull while the key is bad: job error E_SYNC_KEY (job.code + result.code, translated) — also with a wrong old_password', k1.state === 'error' && k1.code === 'E_SYNC_KEY' && k1.result.code === 'E_SYNC_KEY' && /old password/.test(k1.msg) && k2.state === 'error' && k2.code === 'E_SYNC_KEY' && /旧密码/.test(k2.msg) && k1.steps[1].state === 'error');
  const sBefore = jx(await api('GET', '/api/sync')); r = await api('POST', '/api/sync/pull', { form: { mode: 'replace', old_password: 'oldpass1234' } }); jb = await waitJob(jx(r).job); const sAfter = jx(await api('GET', '/api/sync')), svr = jx(await api('GET', '/api/state')).servers.map((x) => x.tag);
  ck('sync/pull replace + old_password=oldpass1234: key fixed, re-encrypted upload, local.version == remote.version, 2 extra servers synced-1/synced-2, local-only server gone', jb.state === 'done' && jb.steps.length === 4 && sAfter.local.version === sAfter.remote.version && sAfter.remote.version === sBefore.remote.version + 1 && sAfter.local.dirty === false && sAfter.last_pull > 0
    && svr.indexOf('synced-1') >= 0 && svr.indexOf('synced-2') >= 0 && svr.indexOf('Local Only') < 0 && svr.length === 29, [svr.length, sAfter]);
  await ctl('syncremote=newer'); await api('POST', '/api/servers/import', { q: { mode: 'merge' }, body: line('Local Only', 'auto') }).then(run); await api('POST', '/api/servers/delete', { q: { tag: 'synced-2' } }).then(run);
  r = await api('POST', '/api/sync/pull', { form: { mode: 'merge' } }); jb = await run(r); const mg = jx(await api('GET', '/api/state')).servers.map((x) => x.tag);
  ck('sync/pull merge: local servers kept, missing remote ones added back; no old_password needed once the key is ok', jb.state === 'done' && mg.indexOf('Local Only') >= 0 && mg.indexOf('synced-2') >= 0 && mg.indexOf('synced-1') >= 0);
  r = await api('POST', '/api/sync/pull', { form: { mode: 'sideways' } }); ck('sync/pull: invalid mode -> E_INVALID', jx(r).code === 'E_INVALID');
  await ctl('syncoffline=1'); const offl = jx(await api('GET', '/api/sync')); r = await api('POST', '/api/sync/push'); r2 = await api('POST', '/api/sync/pull', { form: { mode: 'merge' } }); r3 = await api('POST', '/api/sync/clear'); await ctl('syncoffline=0&central=down'); const off2 = jx(await api('GET', '/api/sync')).online; await ctl('central=up');
  ck('sync offline (syncoffline=1 or central=down): online:false, push/pull/clear -> E_ACCOUNT_UNREACHABLE', offl.online === false && jx(r).code === 'E_ACCOUNT_UNREACHABLE' && jx(r2).code === 'E_ACCOUNT_UNREACHABLE' && jx(r3).code === 'E_ACCOUNT_UNREACHABLE' && off2 === false && jx(await api('GET', '/api/sync')).online === true);
  r = await api('POST', '/api/sync/clear'); ck('sync/clear: remote data deleted', jx(r).ok === true && jx(await api('GET', '/api/sync')).remote.exists === false);
  FAST = F0;
  }

  /* ---- 新增接口: 偏好 / 套餐 / 步骤验证 (sudo) / 密码修改 ---- */
  {
    const big = (n) => JSON.stringify({ k: 'x'.repeat(n) });
    r = await api('GET', '/api/prefs'); r2 = await rq('GET', '/api/prefs');
    ck('prefs: starts empty ({prefs:{}, version:0, updated:0}); needs a token (401)', jx(r).ok === true && JSON.stringify(jx(r).prefs) === '{}' && jx(r).version === 0 && jx(r).updated === 0 && r2.status === 401);
    r = await api('POST', '/api/prefs', { body: JSON.stringify({ 'table.sites.pageSize': 20, 'ui.sidebar.collapsed': true }) }); r2 = await api('GET', '/api/prefs'); const pst = jx(await api('GET', '/api/state'));
    ck('prefs: POST (JSON text body) -> {ok, version:1}; GET returns the object + version + updated; state.prefs_version follows', jx(r).ok === true && jx(r).version === 1 && jx(r2).version === 1 && jx(r2).prefs['table.sites.pageSize'] === 20 && jx(r2).prefs['ui.sidebar.collapsed'] === true && jx(r2).updated > 0 && pst.prefs_version === 1, r.text);
    r = await api('POST', '/api/prefs', { body: '{"a":1}' }); r2 = await api('GET', '/api/prefs');
    ck('prefs: every write replaces the whole object (no merge) and bumps the version', jx(r).version === 2 && JSON.stringify(jx(r2).prefs) === '{"a":1}' && jx(r2).version === 2);
    const deep = (n) => { let o = { x: 1 }; for (let i = 1; i < n; i++) o = { d: o }; return JSON.stringify(o); };
    r = await api('POST', '/api/prefs', { body: '{"b":1,"a":{"d":1,"c":2}}' }); r2 = await api('GET', '/api/prefs'); const rdeep = await api('POST', '/api/prefs', { body: deep(12) }), rtoo = await api('POST', '/api/prefs', { body: deep(13) });
    ck('prefs: the stored JSON is canonical (keys sorted, like lib/prefs.sh); up to 12 levels of nesting are accepted, 13 -> E_INVALID', jx(r).ok === true && JSON.stringify(jx(r2).prefs) === '{"a":{"c":2,"d":1},"b":1}' && jx(rdeep).ok === true && jx(rtoo).code === 'E_INVALID');
    await api('POST', '/api/prefs', { body: '{"a":1}' });
    const badP = []; for (const b of ['not json', '[1,2]', 'null', '"str"', '42', '', big(32761)]) badP.push(await api('POST', '/api/prefs', { body: b }));
    ck('prefs: invalid JSON / array / null / string / number / empty body / over 32 KB -> E_INVALID, nothing changes', badP.every((x) => jx(x).code === 'E_INVALID' && jx(x).ok === false && !!jx(x).error) && jx(await api('GET', '/api/prefs')).version === 5, badP.map((x) => jx(x).code));
    r = await api('POST', '/api/prefs', { body: big(32760) }); ck('prefs: exactly 32 KB (32768 bytes) is accepted', jx(r).ok === true && jx(r).version === 6 && Buffer.byteLength(big(32760)) === 32768, r.text.slice(0, 100));
    await api('POST', '/api/prefs', { body: '{}' }); await ctl('prefs=bump'); r = jx(await api('GET', '/api/prefs')); const pst2 = jx(await api('GET', '/api/state'));
    ck('ctl prefs=bump simulates a change synced from another device: version +1, "ui.fromOtherDevice": true, state.prefs_version follows', r.version === 8 && r.prefs['ui.fromOtherDevice'] === true && pst2.prefs_version === 8, r);
    await ctl('prefs=reset'); r = jx(await api('GET', '/api/prefs')); ck('ctl prefs=reset -> {} / version 0 / updated 0', JSON.stringify(r.prefs) === '{}' && r.version === 0 && r.updated === 0);
    ck('prefs writes are not written to the operations log', jx(await logs({ type: 'ops', q: 'prefs', limit: '50' })).total === 0);

    /* 套餐 */
    r = await api('GET', '/api/plan'); const pf0 = jx(r), pfEn = jx(await api('GET', '/api/plan', { lang: 'en' }));
    ck('plan (default = soon): free / 免费版 (Free), no expiry, 2 devices, official_proxy coming_soon, free features enabled, extra feature keys (custom_dns / unlimited_devices / priority_support), no official nodes; needs a token', pf0.ok === true && pf0.plan.code === 'free' && pf0.plan.title === '免费版' && pfEn.plan.title === 'Free'
      && pf0.expires_at === null && pf0.checked > 0 && pf0.limits.devices_per_platform === 2 && JSON.stringify(pf0.features.official_proxy) === '{"enabled":false,"tier":"pro","reason":"upgrade","coming_soon":true}' && ['core', 'sync', 'vps_deploy', 'custom_dns'].every((k) => JSON.stringify(pf0.features[k]) === '{"enabled":true,"tier":"free"}')
      && ['unlimited_devices', 'priority_support'].every((k) => pf0.features[k].tier === 'pro' && pf0.features[k].enabled === false && pf0.features[k].coming_soon === true) && pf0.official.available === false && pf0.official.nodes === 0 && (await rq('GET', '/api/plan')).status === 401, r.text);
    await ctl('plan=free'); const pf1 = jx(await api('GET', '/api/plan'));
    ck('plan=free: the same plan but the Pro features are live and need an upgrade (reason upgrade, coming_soon:false)', pf1.plan.code === 'free' && JSON.stringify(pf1.features.official_proxy) === '{"enabled":false,"tier":"pro","reason":"upgrade","coming_soon":false}' && pf1.features.unlimited_devices.coming_soon === false && pf1.official.available === false);
    const n0 = jx(await api('GET', '/api/state')).servers.length;                // 这一步之前自测已经增删过服务器, 所以用「现在有几台」做基准
    await ctl('plan=pro'); const pf2 = jx(await api('GET', '/api/plan')), pf2en = jx(await api('GET', '/api/plan', { lang: 'en' })), sv2 = jx(await api('GET', '/api/state')).servers, px2 = jx(await clashR('GET', '/proxies')).proxies;
    ck('plan=pro: 专业版 / Pro, expires in 30 days, Pro features enabled, official {available:true, nodes:2}, device limit 5', pf2.plan.code === 'pro' && pf2.plan.title === '专业版' && pf2en.plan.title === 'Pro' && Math.abs(pf2.expires_at - (sec() + 30 * 86400)) <= 5 && JSON.stringify(pf2.features.official_proxy) === '{"enabled":true,"tier":"pro"}'
      && pf2.features.unlimited_devices.enabled === true && pf2.official.available === true && pf2.official.nodes === 2 && pf2.limits.devices_per_platform === 5 && jx(await api('GET', '/api/devices')).limit === 5, pf2);
    ck('plan=pro: state.servers gains 2 servers flagged official:true (the others carry no such flag) and they are live in the core (AUTO pool)', sv2.length === n0 + 2 && sv2.filter((x) => x.official === true).length === 2 && sv2.filter((x) => !('official' in x)).length === n0 && px2.AUTO.all.indexOf('enana-official-tokyo') >= 0 && jx(await api('GET', '/api/state')).first_run === false);
    r = await api('GET', '/api/servers/secret', { q: { tag: 'enana-official-tokyo' } }); r2 = await api('POST', '/api/servers/delete', { q: { tag: 'enana-official-tokyo' } }); const ex0 = await api('GET', '/api/export');
    ck('official nodes: secret -> E_INVALID (translated), delete -> E_INVALID, and they are excluded from the export', jx(r).code === 'E_INVALID' && !!jx(r).error && jx(r2).code === 'E_INVALID' && !!jx(r2).error && ex0.status === 200 && ex0.text.indexOf('official') < 0 && JSON.parse(ex0.text).servers.length === n0);
    await ctl('plan=expired'); const pf3 = jx(await api('GET', '/api/plan')), sv3 = jx(await api('GET', '/api/state')).servers;
    ck('plan=expired: free again, official_proxy {enabled:false, reason:expired, coming_soon:false}, expires_at in the past, the official nodes are gone', pf3.plan.code === 'free' && JSON.stringify(pf3.features.official_proxy) === '{"enabled":false,"tier":"pro","reason":"expired","coming_soon":false}' && pf3.expires_at < sec() && pf3.official.nodes === 0 && sv3.length === n0 && pf3.limits.devices_per_platform === 2);
    await ctl('plan=soon'); ck('plan=soon restores the default', jx(await api('GET', '/api/plan')).features.official_proxy.coming_soon === true);

    /* 步骤验证 (sudo) */
    const WL = [['POST', '/api/servers/delete', { form: { tag: 'no-such' } }], ['POST', '/api/sub/delete', { form: { name: 'no-such' } }], ['GET', '/api/servers/secret', {}], ['GET', '/api/sub/url', {}], ['POST', '/api/logs/clear', { form: { type: 'bogus' } }],
      ['POST', '/api/devices/kick', {}], ['POST', '/api/sync/clear', {}], ['GET', '/api/export', {}]], w403 = [];
    for (const x of WL) w403.push(await api(x[0], x[1], Object.assign({ sudo: false }, x[2])));
    ck('sudo: all 8 whitelisted endpoints answer HTTP 403 {ok:false, code:E_SUDO_REQUIRED, error} without X-Enana-Sudo — before their own validation (bogus arguments never reach it)', w403.every((x) => x.status === 403 && jx(x).code === 'E_SUDO_REQUIRED' && jx(x).ok === false && jx(x).error === '此操作需要再次输入登录密码'), w403.map((x) => x.status + ' ' + jx(x).code));
    r = await api('GET', '/api/export', { sudo: false, headers: { 'X-Enana-Sudo': 'deadbeef' }, lang: 'en' }); r2 = await rq('GET', '/api/export', { headers: { 'X-Enana-Sudo': 'deadbeef' } });
    ck('sudo: an unknown token is the same 403 (message follows X-Enana-Lang); the login token is checked first (no token -> 401 E_AUTH)', r.status === 403 && jx(r).error === 'This action needs your sign-in password again' && r2.status === 401 && jx(r2).code === 'E_AUTH');
    r = await rq('POST', '/api/auth/verify', { form: { password: P1 } }); r2 = await api('POST', '/api/auth/verify', { form: { password: 'wrong-one' } }); const vEmpty = await api('POST', '/api/auth/verify', { form: {} }), vUrl = await api('POST', '/api/auth/verify', { q: { password: P1 } });
    ck('auth/verify: needs a token (401); a wrong password -> E_BAD_CREDENTIALS (+wait); an empty one, or one put in the URL instead of the body -> E_INVALID', r.status === 401 && jx(r2).code === 'E_BAD_CREDENTIALS' && jx(r2).wait === 0 && jx(r2).error === '密码不正确' && jx(vEmpty).code === 'E_INVALID' && jx(vUrl).code === 'E_INVALID');
    r = await api('POST', '/api/auth/verify', { form: { password: P1 } }); const SU = jx(r).sudo;
    ck('auth/verify: the right password -> {ok, sudo (32 hex), ttl:300}', jx(r).ok === true && /^[0-9a-f]{32}$/.test(SU) && jx(r).ttl === 300, r.text);
    const svr = jx(await api('GET', '/api/state')).servers, byType = (t) => svr.filter((x) => x.type === t)[0].tag, secret = async (tag) => jx(await api('GET', '/api/servers/secret', { q: { tag } }));
    const sec1 = {}; for (const t of ['trojan', 'hysteria2', 'vless', 'tuic', 'shadowsocks', 'http', 'socks']) sec1[t] = await secret(byType(t));
    const fn = (o) => (o.fields || []).map((f) => f.name).join(), UUIDR = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-8[0-9a-f]{3}-[0-9a-f]{12}$/, again = await secret(byType('tuic'));
    ck('servers/secret (with sudo): {ok, tag, fields:[{name,value}]} by node type — trojan / hysteria2: password; vless: uuid; tuic: uuid+password; shadowsocks: method+password; http / socks: username+password', sec1.trojan.ok === true && sec1.trojan.tag === byType('trojan') && fn(sec1.trojan) === 'password' && fn(sec1.hysteria2) === 'password' && fn(sec1.vless) === 'uuid' && UUIDR.test(sec1.vless.fields[0].value)
      && fn(sec1.tuic) === 'uuid,password' && fn(sec1.shadowsocks) === 'method,password' && fn(sec1.http) === 'username,password' && fn(sec1.socks) === 'username,password' && Object.keys(sec1).every((t) => sec1[t].fields.every((f) => f.value.length > 3)), sec1.tuic);
    ck('servers/secret: deterministic placeholder values (same node -> same values, other nodes differ); unknown or missing tag -> E_NOT_FOUND', JSON.stringify(again) === JSON.stringify(sec1.tuic) && sec1.trojan.fields[0].value !== (await secret(svr.filter((x) => x.type === 'trojan')[1].tag)).fields[0].value && (await secret('no-such-node')).code === 'E_NOT_FOUND' && jx(await api('GET', '/api/servers/secret')).code === 'E_NOT_FOUND');
    r = await api('GET', '/api/sub/url', { q: { name: 'demo-sub' } }); r2 = await api('GET', '/api/sub/url', { q: { name: 'nope' } }); const su3 = await api('GET', '/api/sub/url', { q: { name: 'bad/name' } });
    ck('sub/url (with sudo): {ok, name, url}; an unknown subscription (or a malformed name) -> E_NOT_FOUND', jx(r).ok === true && jx(r).name === 'demo-sub' && /^https:\/\/sub\.example\.com\/sub\/demo/.test(jx(r).url) && jx(r2).code === 'E_NOT_FOUND' && jx(su3).code === 'E_NOT_FOUND', r.text);
    await api('POST', '/api/sub/save', { q: { name: 'sudo-sub' }, body: 'https://sub.example.com/sub/demo?token=abc123\n' }); r = await api('GET', '/api/sub/url', { q: { name: 'sudo-sub' } });
    const keepUrl = M.subUrls['demo-sub']; delete M.subUrls['demo-sub']; r2 = await api('GET', '/api/sub/url', { q: { name: 'demo-sub' }, lang: 'en' }); M.subUrls['demo-sub'] = keepUrl;
    await api('POST', '/api/sub/delete', { q: { name: 'sudo-sub' } }).then(run); const r3x = await api('GET', '/api/sub/url', { q: { name: 'sudo-sub' } });
    ck('sub/url: a saved subscription returns exactly the saved link; a subscription without a stored link -> E_NOT_FOUND "subscription not found" (as lib/api.sh); deleting the subscription forgets the link', jx(r).url === 'https://sub.example.com/sub/demo?token=abc123' && jx(r2).code === 'E_NOT_FOUND' && /Subscription not found/.test(jx(r2).error) && jx(r3x).code === 'E_NOT_FOUND');
    r = await api('GET', '/api/export'); let bk = {}; try { bk = JSON.parse(r.text); } catch (e) { bk = {}; }
    ck('export (with sudo): text/plain JSON (download name enana-backup-YYYYMMDD.json) — servers (with placeholder credentials), subs (with link), policies, dns (+ hosts), rule selection', r.status === 200 && /^text\/plain/.test(r.headers['content-type']) && /^attachment; filename="enana-backup-\d{8}\.json"$/.test(r.headers['content-disposition'] || '') && bk.kind === 'backup' && bk.servers.length === svr.length && bk.servers.every((x) => x.tag && x.credentials && Object.keys(x.credentials).length >= 1) && bk.subs[0].name === 'demo-sub' && /^https:/.test(bk.subs[0].url)
      && bk.dns.cn === 'alidns' && Array.isArray(bk.dns.hosts) && Array.isArray(bk.rules.enabled) && bk.rules.enabled.indexOf('geosite-cn') >= 0 && bk.policies && Array.isArray(bk.policies.sites) && Array.isArray(bk.policies.apps) && !!bk.policies.services, r.text.slice(0, 120));
    await ctl('sudottl=1'); r = await api('POST', '/api/auth/verify', { form: { password: P1 } }); const sh = jx(r).sudo; r2 = await api('GET', '/api/export', { sudo: false, headers: { 'X-Enana-Sudo': sh } }); await nap(1300); const sx = await api('GET', '/api/export', { sudo: false, headers: { 'X-Enana-Sudo': sh } });
    ck('sudottl=1: verify answers ttl 1; the token works at first and is dead after 1 s (403 E_SUDO_REQUIRED)', jx(r).ttl === 1 && r2.status === 200 && sx.status === 403 && jx(sx).code === 'E_SUDO_REQUIRED'); await ctl('sudottl=300');
    let tk = jx(await api('POST', '/api/auth/verify', { form: { password: P1 } })).sudo; await ctl('sudo=clear'); const sc = await api('GET', '/api/export', { sudo: false, headers: { 'X-Enana-Sudo': tk } });
    tk = jx(await api('POST', '/api/auth/verify', { form: { password: P1 } })).sudo; await api('POST', '/api/logout'); T = jx(await login(D1, P1)).token; const sl = await api('GET', '/api/export', { sudo: false, headers: { 'X-Enana-Sudo': tk } });
    tk = jx(await api('POST', '/api/auth/verify', { form: { password: P1 } })).sudo; await ctl('expire=1'); T = jx(await login(D1, P1)).token; const se = await api('GET', '/api/export', { sudo: false, headers: { 'X-Enana-Sudo': tk } });
    tk = jx(await api('POST', '/api/auth/verify', { form: { password: P1 } })).sudo; T = jx(await login(D1, P1)).token; const sl2 = await api('GET', '/api/export', { sudo: false, headers: { 'X-Enana-Sudo': tk } });
    ck('sudo tokens die on ctl sudo=clear, on logout + login, on expire=1 + login, and on every login (a token from before is a 403 even with a valid login token)', [sc, sl, se, sl2].every((x) => x.status === 403 && jx(x).code === 'E_SUDO_REQUIRED'));
    await ctl('lock=reset&locksec=2'); for (let i = 0; i < 3; i++) await api('POST', '/api/auth/verify', { form: { password: 'nope' + i } }); await login(D1, 'bad1'); await login(D1, 'bad2');
    r = await api('POST', '/api/auth/verify', { form: { password: P1 } }); r2 = await login(D1, P1);
    ck('verify shares the login / register failure counter: 3 wrong verifies + 2 wrong logins -> both verify and login answer E_LOCKED + wait', jx(r).code === 'E_LOCKED' && jx(r).wait >= 1 && jx(r2).code === 'E_LOCKED');
    await ctl('lock=reset&locksec=300'); T = jx(await login(D1, P1)).token;

    /* 密码修改 */
    r = await rq('POST', '/api/password', { form: { old: P1, new: 'newpass99' } }); r2 = await api('POST', '/api/password', { form: { old: 'wrong-old', new: 'newpass99' } });
    ck('password: needs a token (401); a wrong old password -> E_BAD_CREDENTIALS', r.status === 401 && jx(r2).code === 'E_BAD_CREDENTIALS');
    r = await api('POST', '/api/password', { form: { old: P1, new: 'short' } }); r2 = await api('POST', '/api/password', { form: { old: P1, new: P1 } }); let pw3 = await api('POST', '/api/password', { form: { old: P1 } }); const pw4 = await api('POST', '/api/password', { q: { old: P1, new: 'newpass99' } });
    const pw5 = await api('POST', '/api/password', { form: { new: 'newpass99' } }), pw6 = await api('POST', '/api/password', { form: { old: P1, new: 'x'.repeat(72) } });
    ck('password: a new password under 8 / over 71 characters, missing or equal to the old one -> E_WEAK_PASSWORD (translated); a missing old password, or fields in the URL instead of the body -> E_INVALID', jx(r).code === 'E_WEAK_PASSWORD' && jx(r).error === '新密码至少 8 位, 并且不能和旧密码相同' && jx(r2).code === 'E_WEAK_PASSWORD' && jx(pw3).code === 'E_WEAK_PASSWORD' && jx(pw6).code === 'E_WEAK_PASSWORD' && jx(pw5).code === 'E_INVALID' && jx(pw4).code === 'E_INVALID');
    await ctl('central=down'); r = await api('POST', '/api/password', { form: { old: P1, new: 'newpass99' } }); r2 = await api('POST', '/api/password', { form: { old: 'wrong-old', new: 'newpass99' } }); await ctl('central=up');
    ck('password: central=down -> E_ACCOUNT_UNREACHABLE — even with a wrong old password, because the cloud is what verifies it', jx(r).code === 'E_ACCOUNT_UNREACHABLE' && jx(r2).code === 'E_ACCOUNT_UNREACHABLE');
    await ctl('lock=reset&locksec=2'); for (let i = 0; i < 5; i++) pw3 = await api('POST', '/api/password', { form: { old: 'wrong' + i, new: 'newpass99' } }); r = await api('POST', '/api/password', { form: { old: P1, new: 'newpass99' } });
    ck('password: 5 wrong old passwords -> E_LOCKED + wait (the same counter as login); the 5th wrong answer already carries the wait', jx(pw3).code === 'E_BAD_CREDENTIALS' && jx(pw3).wait >= 1 && jx(r).code === 'E_LOCKED' && jx(r).wait >= 1); await ctl('lock=reset&locksec=300');
    await ctl('devices=full'); const dvB = jx(await api('GET', '/api/devices')).devices.filter((d) => d.uid !== 'this-mock' && d.online).length, SU2 = jx(await api('POST', '/api/auth/verify', { form: { password: P1 } })).sudo;
    r = await api('POST', '/api/password', { form: { old: P1, new: 'newpass99' } }); CURPW = 'newpass99'; const dvA = jx(await api('GET', '/api/devices')), stOk = await api('GET', '/api/state'), exAfter = await api('GET', '/api/export', { sudo: false, headers: { 'X-Enana-Sudo': SU2 } });
    ck('password change: {ok}; this token stays valid; every OTHER device is now offline; the sudo tokens are dropped', jx(r).ok === true && stOk.status === 200 && dvB === 2 && dvA.devices[0].current === true && dvA.devices[0].online === true && dvA.devices.filter((d) => d.uid !== 'this-mock').length === 3
      && dvA.devices.filter((d) => d.uid !== 'this-mock').every((d) => d.online === false) && exAfter.status === 403, r.text);
    r = await login(D1, P1); r2 = await login(D1, 'newpass99'); T = jx(r2).token; const vNew = await api('POST', '/api/auth/verify', { form: { password: 'newpass99' } }), vOld = await api('POST', '/api/auth/verify', { form: { password: P1 } });
    ck('after the change the old password no longer logs in or verifies, the new one does (login + verify)', jx(r).code === 'E_BAD_CREDENTIALS' && jx(r2).ok === true && jx(vNew).ok === true && jx(vOld).code === 'E_BAD_CREDENTIALS');
    await ctl('central=down'); r = await login(D1, 'newpass99'); r2 = await login(D1, P1); await ctl('central=up');
    ck('...and the offline login cache follows the new password (central=down: new password -> via offline, the old one is refused)', jx(r).ok === true && jx(r).via === 'offline' && jx(r2).code === 'E_BAD_CREDENTIALS');
    T = jx(await login(D1, 'newpass99')).token; r = await api('POST', '/api/password', { form: { old: 'newpass99', new: P1 } }); CURPW = P1; T = jx(await login(D1, P1)).token; await ctl('devices=reset'); T = jx(await login(D1, P1)).token;
    ck('password changed back to the seed password (demo1234 works again)', jx(r).ok === true && T.length === 32);
    const pwLog = jx(await logs({ type: 'ops', q: 'password.change', limit: '50' })).rows;
    ck('ops log: password.change rows (ok and error), never containing a password', pwLog.some((x) => x.result === 'ok') && pwLog.some((x) => x.result === 'error' && /E_BAD_CREDENTIALS/.test(x.detail)) && pwLog.every((x) => !/newpass99|wrong-old|demo1234/.test(JSON.stringify(x))));
    await ctl('kickme=password'); r = await api('GET', '/api/state'); const nk = jx(await rq('GET', '/api/auth/status')), nkEn = jx(await rq('GET', '/api/auth/status', { lang: 'en' }));
    ck('kickme=password (password changed on another device): tokens die, notice (zh / en) + notice_code "password_changed"', r.status === 401 && /密码已在另一台设备上修改/.test(nk.notice) && /password was changed on another device/.test(nkEn.notice) && nk.notice_code === 'password_changed');
    T = jx(await login(D1, P1)).token; await ctl('kickme=1'); const nk2 = jx(await rq('GET', '/api/auth/status')); T = jx(await login(D1, P1)).token; await ctl('notice=' + encodeURIComponent('hello')); const nk3 = jx(await rq('GET', '/api/auth/status')); await ctl('notice='); const nk4 = jx(await rq('GET', '/api/auth/status'));
    ck('notice_code: kickme=1 -> "kicked", a free-text notice -> "", no notice -> ""; a successful login clears it', nk2.notice_code === 'kicked' && nk3.notice === 'hello' && nk3.notice_code === '' && nk4.notice === '' && nk4.notice_code === '');
  }
  /* ---- 网站规则: 域名的查看 / 添加 / 修改 / 删除 / 恢复 / 重置 ---- */
  {
    const sd = async (id, lang) => jx(await api('GET', '/api/sites/domains', { q: { id }, lang })), post = (form, lang) => api('POST', '/api/sites/domains', { form, lang }), cat = async () => jx(await rq('GET', '/ui/catalog.json', { noHdr: true })), ent = (c, id) => c.entries.filter((e) => e.id === id)[0];
    let d0 = await sd('claude'); const dEn = await sd('claude', 'en');
    ck('sites/domains GET: {id, name (zh / en), modified:false, system, domains[{domain, source:system}], removed:[], rulesets, cidrs, policy}', d0.ok === true && d0.id === 'claude' && d0.name === 'Claude' && dEn.name === 'Claude' && d0.modified === false && d0.system.length === 6 && d0.domains.length === 6 && d0.domains.every((x, i) => x.domain === d0.system[i] && x.source === 'system')
      && Array.isArray(d0.removed) && d0.removed.length === 0 && Array.isArray(d0.rulesets) && d0.cidrs === 0 && d0.policy === 'pin' && (await sd('exchange', 'en')).name === 'Exchanges / payments' && (await sd('exchange')).name === '交易所 / 支付', d0);
    const dTg = await sd('telegram'), dUs = await sd('news-us'), dDm = await sd('dev-misc'), dMg = await sd('misc-global'), dSp = await sd('spotify');
    ck('sites: entries with rulesets + cidrs (telegram 1 + 14) and with 60+ domains (news-us 61, dev-misc 72, misc-global 88) exist; policy = the entry\'s default policy (as lib/sites.sh)', dTg.rulesets.length === 1 && dTg.cidrs === 14 && dUs.domains.length === 61 && dDm.domains.length === 72 && dMg.domains.length === 88 && dSp.policy === 'auto');
    r = await api('GET', '/api/sites/domains', { q: { id: 'nope' } }); r2 = await api('GET', '/api/sites/domains'); const sg3 = await api('GET', '/api/sites/domains', { q: { id: 'Bad_ID!' } });
    ck('sites/domains GET: unknown id -> E_NOT_FOUND, missing or malformed id (not [a-z0-9-]) -> E_INVALID', jx(r).code === 'E_NOT_FOUND' && jx(r2).code === 'E_INVALID' && jx(sg3).code === 'E_INVALID' && (await rq('GET', '/api/sites/domains?id=claude')).status === 401);
    r = await post({ id: 'claude', action: 'add', domain: 'x-new.example.com' }, 'en'); jb = await waitJob(jx(r).job, 'en'); d0 = await sd('claude'); let cj2 = await cat();
    ck('sites/domains add: a job with the 3 steps (save / regenerate / apply); then the domain is last with source "added", modified:true; catalog.json shows the effective domains + modified:true (the other entries stay false)', jx(r).ok === true && jb.state === 'done' && jb.steps.map((x) => x.label).join() === 'Save your changes,Regenerate the config,Apply'
      && d0.domains.length === 7 && d0.domains[6].domain === 'x-new.example.com' && d0.domains[6].source === 'added' && d0.modified === true && d0.system.length === 6 && ent(cj2, 'claude').modified === true && ent(cj2, 'claude').domains.length === 7 && ent(cj2, 'claude').domains[6] === 'x-new.example.com'
      && cj2.entries.filter((e) => e.modified).length === 1, [jb.state, jb.steps]);
    r = await post({ id: 'claude', action: 'add', domain: 'x-new.example.com' }); r2 = await post({ id: 'claude', action: 'add', domain: 'claude.example.com' });
    ck('sites/domains add: a duplicate (user-added or system) -> E_INVALID with a reason', jx(r).code === 'E_INVALID' && jx(r2).code === 'E_INVALID' && !!jx(r).error && !!jx(r2).error);
    const BAD = ['', '*.example.com', 'https://a.example.com', 'a.example.com/path', 'a b.example.com', 'a_b.example.com', 'localhost', '1.2.3.4', '-a.example.com', 'a..example.com', 'a'.repeat(64) + '.example.com', ('a'.repeat(60) + '.').repeat(5) + 'com', 'a.example.com:8080', 'user@example.com', '\u952e.example.com'], badR = [];
    for (const dm of BAD) badR.push(await post({ id: 'claude', action: 'add', domain: dm }));
    ck('sites/domains add: every invalid shape (empty, wildcard, protocol, path, space, bad character, no dot, IP, hyphen label, empty label, 64-char label, over 253, port, @, non-ASCII) -> E_INVALID with its own translated reason', badR.every((x) => jx(x).code === 'E_INVALID' && !!jx(x).error) && new Set(badR.map((x) => jx(x).error)).size >= 11 && (await sd('claude')).domains.length === 7, new Set(badR.map((x) => jx(x).error)).size);
    r = await post({ id: 'claude', action: 'add', domain: '  X-Upper.Example.COM. ' }); await run(r); d0 = await sd('claude'); const rmU = await post({ id: 'claude', action: 'remove', domain: 'X-UPPER.example.com' }); await run(rmU); const d0b = await sd('claude');
    ck('sites/domains: input is normalized first (trimmed, lower-cased, one trailing dot dropped, as lib/sites.sh) — so uppercase is fine and is stored in lower case; remove normalizes too', jx(r).ok === true && d0.domains[7].domain === 'x-upper.example.com' && d0.domains[7].source === 'added' && jx(rmU).ok === true && d0b.domains.length === 7);
    r = await post({ id: 'claude', action: 'add', domain: '*.example.com' }, 'en'); ck('...and the reasons are translated (en)', /Wildcards/.test(jx(r).error));
    r = await post({ id: 'claude', action: 'update', domain: 'x-new.example.com', new: 'x-renamed.example.com' }); await run(r); d0 = await sd('claude');
    ck('sites/domains update a user-added domain: renamed in place (still "added")', d0.domains.length === 7 && d0.domains[6].domain === 'x-renamed.example.com' && d0.domains[6].source === 'added' && d0.removed.length === 0);
    r = await post({ id: 'claude', action: 'update', domain: 'claude.example.net', new: 'claude-moved.example.net' }); await run(r); d0 = await sd('claude');
    ck('sites/domains update a system domain: the old one is recorded as removed, the new one is added', d0.removed.join() === 'claude.example.net' && d0.domains.length === 7 && d0.domains.some((x) => x.domain === 'claude-moved.example.net' && x.source === 'added') && !d0.domains.some((x) => x.domain === 'claude.example.net') && d0.system.length === 6);
    r = await post({ id: 'claude', action: 'restore', domain: 'claude.example.net' }); await run(r); r = await post({ id: 'claude', action: 'remove', domain: 'claude-moved.example.net' }); await run(r); d0 = await sd('claude');
    ck('sites/domains restore brings a removed system domain back (source system); remove of a user-added domain deletes it for good', d0.removed.length === 0 && d0.domains.length === 7 && d0.domains.some((x) => x.domain === 'claude.example.net' && x.source === 'system') && !d0.domains.some((x) => x.domain === 'claude-moved.example.net'));
    r = await post({ id: 'claude', action: 'remove', domain: 'claude-api.example.org' }); await run(r); d0 = await sd('claude'); cj2 = await cat();
    ck('sites/domains remove a system domain: recorded as removed (restorable), gone from domains, system list unchanged', d0.removed.join() === 'claude-api.example.org' && !d0.domains.some((x) => x.domain === 'claude-api.example.org') && d0.system.length === 6 && ent(cj2, 'claude').domains.indexOf('claude-api.example.org') < 0);
    r = await post({ id: 'claude', action: 'add', domain: 'claude-api.example.org' }); await run(r); d0 = await sd('claude');
    ck('sites/domains add of a domain that was removed = restore (not a duplicate)', d0.removed.length === 0 && d0.domains.some((x) => x.domain === 'claude-api.example.org' && x.source === 'system'));
    r = await post({ id: 'claude', action: 'restore', domain: 'claude-api.example.org' }); r2 = await post({ id: 'claude', action: 'remove', domain: 'nothing.example.org' }); let sx3 = await post({ id: 'claude', action: 'update', domain: 'nothing.example.org', new: 'other.example.org' });
    const sx4 = await post({ id: 'claude', action: 'update', domain: 'x-renamed.example.com', new: 'claude.example.com' }), sx5 = await post({ id: 'claude', action: 'update', domain: 'x-renamed.example.com', new: 'bad domain' }), sx8 = await post({ id: 'claude', action: 'update', domain: 'x-renamed.example.com', new: 'X-Renamed.example.com' }), sx6 = await post({ id: 'claude', action: 'frobnicate', domain: 'a.example.com' }), sx7 = await post({ id: 'nope', action: 'add', domain: 'a.example.com' });
    ck('sites/domains: restore of a domain that was not removed, remove / update of a domain that is not in the list, update to an existing / invalid / identical name, an unknown action, an unknown entry -> all E_INVALID with a reason (POST never answers E_NOT_FOUND, as lib/api.sh)', [r, r2, sx3, sx4, sx5, sx6, sx7, sx8].every((x) => jx(x).code === 'E_INVALID' && !!jx(x).error) && jx(sx7).error === '找不到这个网站条目');
    const rm0 = await post({ id: 'claude', action: 'remove', domain: 'claude-cdn.example.com' }); await run(rm0); const rm1 = await post({ id: 'claude', action: 'remove', domain: 'claude-cdn.example.com' }); await post({ id: 'claude', action: 'restore', domain: 'claude-cdn.example.com' }).then(run);
    ck('sites/domains: removing a system domain that is already removed -> E_INVALID "already removed"', jx(rm1).code === 'E_INVALID' && jx(rm1).error === '这个域名已经删除了');
    for (let i = 0; i < 300; i++) await post({ id: 'ted', action: 'add', domain: 'many-' + i + '.example.com' }); const mx1 = await post({ id: 'ted', action: 'add', domain: 'many-300.example.com' }, 'en'), td1 = await sd('ted');
    ck('sites/domains: at most 300 added domains per entry (the 301st -> E_INVALID); a reset clears them all', td1.domains.length === 303 && jx(mx1).code === 'E_INVALID' && /at most 300/.test(jx(mx1).error) && (await api('POST', '/api/sites/domains/reset', { form: { id: 'ted' } }).then(run)).state === 'done' && (await sd('ted')).domains.length === 3);
    r = await api('POST', '/api/sites/domains/reset', { form: { id: 'claude' } }); jb = await run(r); d0 = await sd('claude'); cj2 = await cat(); r2 = await api('POST', '/api/sites/domains/reset', { form: { id: 'nope' } }); const rs3 = await api('POST', '/api/sites/domains/reset');
    ck('sites/domains/reset: a job; the entry is back to the system list (modified:false everywhere); unknown entry -> E_NOT_FOUND, missing id -> E_INVALID', jb.state === 'done' && d0.modified === false && d0.domains.length === 6 && d0.domains.every((x) => x.source === 'system') && cj2.entries.every((e) => e.modified === false) && jx(r2).code === 'E_NOT_FOUND' && jx(rs3).code === 'E_INVALID');
    await ctl('failnext=1'); r = await post({ id: 'github', action: 'add', domain: 'rollback.example.com' }); jb = await run(r); d0 = await sd('github');
    ck('sites/domains: a failing job (failnext=1) rolls the change back', jb.state === 'error' && d0.modified === false && !d0.domains.some((x) => x.domain === 'rollback.example.com'));
    await api('POST', '/api/sync/push', { q: { force: '1' } }).then(run); const syncD0 = jx(await api('GET', '/api/sync')).local.dirty; await post({ id: 'github', action: 'add', domain: 'keep.example.com' }); await post({ id: 'telegram', action: 'remove', domain: 'telegram-cdn.example.org' }); const sync1 = jx(await api('GET', '/api/sync')).local.dirty;
    cj2 = await cat(); ck('catalog.json: modified is per entry (github + telegram); the changes persist across other edits', cj2.entries.filter((e) => e.modified).map((e) => e.id).sort().join() === 'github,telegram' && ent(cj2, 'telegram').domains.length === 4 && ent(cj2, 'github').domains.length === 7); ck('sites changes mark the local sync data dirty (after a push cleared it)', syncD0 === false && sync1 === true);
    await api('POST', '/api/sites/domains/reset', { form: { id: 'github' } }); await api('POST', '/api/sites/domains/reset', { form: { id: 'telegram' } });
    await api('POST', '/api/override', { q: { kind: 'site', value: 'shop.example.com', state: 'auto' } }); const sto = jx(await api('GET', '/api/state')); await api('POST', '/api/override', { q: { kind: 'site', value: 'shop.example.com', state: 'follow' } });
    ck('the overrides / state endpoints keep working next to the domain edits', sto.ok === true && sto.overrides.some((o) => o.value === 'shop.example.com' && o.state === 'auto'));
  }

  /* ---- 应用: 图标 (运行时生成的 PNG, 陆续出现) / 校验 (inspect) / 自定义软件 ---- */
  {
    const pngInfo = (buf) => {
      let o = 8, crcOk = true; const types = [], idat = [];
      while (o + 12 <= buf.length) { const len = buf.readUInt32BE(o), type = buf.slice(o + 4, o + 8).toString('ascii'), data = buf.slice(o + 8, o + 8 + len); if (crc32(Buffer.concat([buf.slice(o + 4, o + 8), data])) !== buf.readUInt32BE(o + 8 + len)) crcOk = false; types.push(type); if (type === 'IDAT') idat.push(data); o += 12 + len; }
      let raw = null; try { raw = zlib.inflateSync(Buffer.concat(idat)); } catch (e) { raw = null; }
      return { sig: buf.slice(0, 8).toString('hex') === '89504e470d0a1a0a', crcOk, types: types.join(), w: buf.readUInt32BE(16), h: buf.readUInt32BE(20), depth: buf[24], color: buf[25], raw };
    };
    const icon = (name) => rq('GET', '/ui/' + iconUrl(name), { noHdr: true }), apps = async () => jx(await api('GET', '/api/apps')).apps, byName = (l, n) => l.filter((a) => a.name === n)[0];
    let al = await apps(); const NEVER = ['zoom.us', 'ClashX Pro', 'WPS Office'];
    ck('apps: icons — "appicons/<slug>.png" (slug = the name with every byte outside A-Za-z0-9._- turned into _, max 40, + "-" + cksum, as lib/apps.sh app_icon_slug) for apps whose icon was extracted, "" for the few that never get one (zoom.us, ClashX Pro, WPS Office); one app (Steam) advertises an icon',
      al.filter((a) => NEVER.indexOf(a.name) < 0).every((a) => a.icon === iconUrl(a.name) && /^appicons\/[A-Za-z0-9._-]+-\d{1,10}\.png$/.test(a.icon)) && NEVER.every((n) => byName(al, n).icon === '') && byName(al, 'Steam').icon === iconUrl('Steam') && byName(al, 'Google Chrome').icon === 'appicons/Google_Chrome-1212711553.png' && byName(al, 'Slack').icon === 'appicons/Slack-4138898108.png', al.filter((a) => !a.icon).map((a) => a.name));
    const ic1 = await icon('Slack'), ic2 = await icon('Google Chrome'), ic3 = await icon('Slack'), ic4 = await icon('Telegram'), pi = pngInfo(ic1.buf);
    ck('apps: GET /ui/appicons/<slug>.png serves a real 96x96 RGBA PNG (signature, valid CRCs, IHDR / IDAT / IEND, inflates to 96 rows of 1 + 384 bytes), transparent rounded corners, a white glyph; deterministic per name, different per name', ic1.status === 200 && /^image\/png/.test(ic1.headers['content-type']) && pi.sig && pi.crcOk && pi.types === 'IHDR,IDAT,IEND' && pi.w === 96 && pi.h === 96 && pi.depth === 8 && pi.color === 6
      && pi.raw && pi.raw.length === 96 * 385 && pi.raw[4] === 0 && pi.raw[48 * 385 + 1 + 48 * 4 + 3] === 255 && pi.raw.indexOf(Buffer.from([255, 255, 255, 255])) > 0 && ic1.buf.equals(ic3.buf) && !ic1.buf.equals(ic2.buf) && !ic1.buf.equals(ic4.buf) && ic2.status === 200 && pngInfo(ic2.buf).crcOk, [ic1.status, pi.types, pi.raw && pi.raw.length]);
    r = await icon('Steam'); r2 = await icon('zoom.us'); const r3i = await icon('NoSuchApp'), r4i = await rq('GET', '/ui/appicons/Slack.png', { noHdr: true });
    ck('apps: the broken icon (Steam) advertises a path that answers 404, as do the never-have apps, unknown names and a name without its cksum suffix', r.status === 404 && r2.status === 404 && r3i.status === 404 && r4i.status === 404);
    FAST = 8; await ctl('newapp=Ghostty'); r = await api('POST', '/api/apps/scan'); const g0 = byName(jx(r).apps, 'Ghostty'), g0f = await icon('Ghostty'); await nap(950); const g1 = byName(await apps(), 'Ghostty'), g1f = await icon('Ghostty'); FAST = F0;
    ck('apps: icons appear progressively — a newly scanned app has icon "" (and a 404 file) right after the scan and its icon a few simulated seconds later', g0.icon === '' && g0f.status === 404 && g1.icon === iconUrl('Ghostty') && g1f.status === 200 && /^image\/png/.test(g1f.headers['content-type']));
    FAST = 8; await ctl('newapp=Warp'); await api('POST', '/api/apps/scan'); await ctl('icons=all'); const wAll = byName(await apps(), 'Warp'), nAll = (await apps()).filter((a) => a.icon).length; await ctl('icons=none'); const none = await apps(), noneF = await icon('Slack'); await ctl('icons=progressive'); FAST = F0;
    ck('ctl icons=all: every app except the never-have ones has its icon at once; icons=none: all "" and the files 404; icons=progressive restores the default', wAll.icon === iconUrl('Warp') && nAll === al.length + 2 - NEVER.length && none.every((a) => a.icon === '') && noneF.status === 404 && (await icon('Slack')).status === 200);
    const insp = async (input, lang) => api('POST', '/api/apps/inspect', { form: { input }, lang }), cands = async (input, lang) => jx(await insp(input, lang)).candidates;
    r = await insp('/Applications/Cursor.app'); const cu = jx(r).candidates;
    ck('apps/inspect: /Applications/Cursor.app -> exactly one valid app candidate with every documented field (not in the list yet, currently running)', jx(r).ok === true && cu.length === 1 && cu[0].valid === true && cu[0].kind === 'app' && cu[0].name === 'Cursor' && /^com\.example\./.test(cu[0].bundle_id) && /^\d+\.\d+\.\d+$/.test(cu[0].version) && cu[0].path === '/Applications/Cursor.app' && cu[0].exec === 'Cursor'
      && typeof cu[0].signed === 'boolean' && (cu[0].signed ? /^Developer ID Application: /.test(cu[0].authority) && /^[A-Z0-9]{10}$/.test(cu[0].team) : cu[0].authority === '' && cu[0].team === '') && cu[0].icon === iconUrl('Cursor') && cu[0].exists === false && cu[0].matches_running === true, r.text);
    const cic = await icon('Cursor'); ck('apps/inspect: the candidate icon is served at once (extracted on the fly)', cic.status === 200 && pngInfo(cic.buf).crcOk);
    const sl = (await cands('/Applications/Slack.app'))[0], tool = (await cands('/usr/local/bin/mytool'))[0], nd = (await cands('/opt/homebrew/bin/node'))[0], eh = (await cands('/etc/hosts', 'en'))[0], pm = (await cands('/private/var/root/secret.app', 'en'))[0], nf = (await cands('/Applications/Missing.app', 'en'))[0];
    ck('apps/inspect: Slack.app -> valid, exists:true; /usr/local/bin/mytool -> kind bin, unsigned (signed:false, empty authority / team), exec mytool, no icon; /opt/homebrew/bin/node -> kind bin, signed', sl.valid === true && sl.exists === true && sl.name === 'Slack' && tool.valid === true && tool.kind === 'bin' && tool.name === 'mytool' && tool.signed === false && tool.authority === '' && tool.team === '' && tool.exec === 'mytool' && tool.icon === '' && tool.bundle_id === ''
      && nd.valid === true && nd.kind === 'bin' && nd.name === 'node' && nd.signed === true && /^[A-Z0-9]{10}$/.test(nd.team) && nd.matches_running === true);
    ck('apps/inspect: /etc/hosts -> valid:false (not an app or executable); /private/var/root/secret.app -> valid:false (no permission); a missing path -> valid:false (does not exist); each is {valid:false, path, reason} with its own translated reason (the texts of lib/apps.sh)', JSON.stringify(Object.keys(eh).sort()) === '["path","reason","valid"]' && eh.valid === false && pm.valid === false && nf.valid === false && eh.reason === 'Not an application (.app) or an executable file' && pm.reason === 'No permission to read it' && nf.reason === 'The path does not exist'
      && eh.path === '/etc/hosts' && nf.path === '/Applications/Missing.app' && (await cands('/etc/hosts'))[0].reason === '不是应用 (.app) 或可执行文件');
    const nm1 = await cands('cursor'), nm2 = await cands('code'), nm3 = await cands('zzz', 'en'), nm4 = await cands('a'), nm5 = await cands('slack');
    ck('apps/inspect by name: "cursor" -> 1 hit, "code" -> 5 hits (all valid; the one already in the list is exists:true), "zzz" -> one valid:false candidate, a broad name -> at most 8, an exact match comes first', nm1.length === 1 && nm1[0].name === 'Cursor' && nm1[0].valid === true && nm2.length === 5 && nm2.every((x) => x.valid === true) && nm2.some((x) => x.name === 'Visual Studio Code' && x.exists === true) && nm2.some((x) => x.name === 'Xcode' && x.exists === false)
      && nm3.length === 1 && nm3[0].valid === false && nm3[0].reason === 'App not found: check the name, or enter its full path' && nm3[0].path === '' && nm4.length === 8 && nm5[0].name === 'Slack' && nm5[0].exists === true, [nm2.map((x) => x.name), nm4.length]);
    const rel = ['Applications/Foo.app', './tool', '~/Applications/Cursor.app'], nmBad = ['a|b', 'a*b', 'a?b', 'a[b', 'a"b', 'C:\\Program Files\\Foo\\foo.exe'], pathBad = ['/Applications/a|b.app', '/Applications/a"b.app', '/Applications/a\\b.app'], rl = [], nb = [], pb = [];
    for (const x of rel) rl.push((await cands(x, 'en'))[0]); for (const x of nmBad) nb.push((await cands(x, 'en'))[0]); for (const x of pathBad) pb.push((await cands(x, 'en'))[0]);
    ck('apps/inspect: a relative path (also ~/…) -> valid:false "enter an absolute path"; a name with [ ] * ? | " \\ -> "name contains unsupported characters"; a path with | " \\ -> "path contains unsupported characters" (everything else, like ; $ `, is allowed)', rl.every((x) => x.valid === false && x.reason === 'Enter an absolute path (starting with /), or the app name' && x.path === '') && nb.every((x) => x.valid === false && x.reason === 'The name contains unsupported characters')
      && pb.every((x) => x.valid === false && x.reason === 'The path contains unsupported characters') && (await cands('/Applications/a;b$c.app'))[0].valid === true, [rl.length, nb.map((x) => x.reason)]);
    const reasons = new Set([eh, pm, nf, nm3[0], rl[0], nb[0], pb[0]].map((x) => x.reason)); ck('apps/inspect: the 7 failure kinds (not found, not exec, no permission, no such name, relative, illegal name, illegal path) have 7 distinct reasons', reasons.size === 7);
    const q1 = (await cands('"/Applications/Cursor.app"'))[0], q2 = (await cands('/Applications/Cursor.app/'))[0], q3 = (await cands('/Applications/Visual\\ Studio\\ Code.app'))[0];
    ck('apps/inspect: quotes, a trailing slash and the "\\ " escapes of a path dragged into the terminal are understood', q1.valid && q1.name === 'Cursor' && q2.valid && q2.path === '/Applications/Cursor.app' && q3.valid && q3.name === 'Visual Studio Code' && q3.exists === true && q3.path === '/Applications/Visual Studio Code.app');
    r = await insp(''); r2 = await insp('x'.repeat(1100)); const e0 = jx(r).candidates[0];
    ck('apps/inspect: an empty input is still {ok:true, candidates:[{valid:false, reason}]}; an over-long input is cut at 300 characters and treated as a name; needs a token', jx(r).ok === true && e0.valid === false && e0.reason === '请输入软件的路径或名称' && jx(r2).ok === true && jx(r2).candidates[0].valid === false && (await rq('POST', '/api/apps/inspect', { form: { input: 'x' } })).status === 401);
    await ctl('os=windows'); const wc = await cands('C:\\Program Files\\Foo\\foo.exe'), wp = await cands('/Applications/Cursor.app', 'en'); await ctl('os=darwin');
    ck('apps/inspect on Windows (os=windows): C:\\Program Files\\…\\*.exe is a valid app, a POSIX path is not absolute there', wc[0].valid === true && wc[0].kind === 'app' && wc[0].name === 'foo' && wp[0].valid === false);
    /* 添加 / 删除自定义软件 */
    const nBase = (await apps()).length; r = await api('POST', '/api/apps/custom', { form: { path: '/Applications/Cursor.app', state: 'pin' }, lang: 'en' }); jb = await waitJob(jx(r).job, 'en'); al = await apps(); const cua = byName(al, 'Cursor');
    ck('apps/custom: a job (save / policy / regenerate / apply); the app is listed with custom:true, kind app, its path, group 自定义, state pin, flag ack, known:false', jx(r).ok === true && jb.state === 'done' && jb.steps.length === 4 && jb.steps[0].label === 'Save the custom app' && !!cua && cua.custom === true && cua.kind === 'app' && cua.path === '/Applications/Cursor.app' && cua.group === '自定义' && cua.state === 'pin' && cua.flag === 'ack' && cua.known === false && cua.rec === ''
      && al.filter((a) => a.custom).length === 1 && al.length === nBase + 1, [jb.state, cua]);
    await nap(300); const cua2 = byName(await apps(), 'Cursor');
    ck('apps/custom: the new app gets its icon a few seconds later; inspect now reports it as exists:true', cua2.icon === iconUrl('Cursor') && (await cands('/Applications/Cursor.app'))[0].exists === true);
    await ctl('conns=300'); const cc = jx(await clashR('GET', '/connections')).connections.filter((c) => c.metadata.host === 'api.cursor.example.com'); await ctl('conns=45');
    ck('apps/custom: the custom app shows up in the connections (process path = its path inside the bundle)', cc.length > 0 && cc.every((c) => c.metadata.processPath === '/Applications/Cursor.app/Contents/MacOS/Cursor'), cc.length);
    r = await api('POST', '/api/apps/custom', { form: { path: '/Applications/Cursor.app', state: 'pin' } }); r2 = await api('POST', '/api/apps/custom', { form: { path: '/Applications/Slack.app', state: 'pin' }, lang: 'en' });
    ck('apps/custom: a duplicate (custom or already listed) -> E_INVALID "already in the list"', jx(r).code === 'E_INVALID' && jx(r2).code === 'E_INVALID' && jx(r2).error === 'This app is already in the list');
    const cbad = []; for (const f of [{ path: '/etc/hosts', state: 'pin' }, { path: '/Applications/Missing.app', state: 'pin' }, { path: 'relative/Foo.app', state: 'pin' }, { path: 'cursor', state: 'pin' }, { path: '', state: 'pin' }, { path: '/Applications/Bear.app', state: 'bogus' }, { path: '/Applications/Bear.app' }, { path: '/Applications/a|b.app', state: 'pin' }]) cbad.push(await api('POST', '/api/apps/custom', { form: f, lang: 'en' }));
    ck('apps/custom: an invalid path (not executable, missing, relative, a name instead of a path, empty, illegal characters), a bad or missing state -> E_INVALID, the inspect reason as the error text', cbad.every((x) => jx(x).code === 'E_INVALID' && !!jx(x).error) && jx(cbad[0]).error === 'Not an application (.app) or an executable file' && jx(cbad[1]).error === 'The path does not exist' && /absolute path/.test(jx(cbad[2]).error) && /Invalid state/.test(jx(cbad[5]).error) && /Invalid state/.test(jx(cbad[6]).error) && /unsupported characters/.test(jx(cbad[7]).error) && (await apps()).length === nBase + 1);
    r = await api('POST', '/api/apps/custom', { form: { path: '/usr/local/bin/mytool', state: 'direct' } }); await run(r); const mt = byName(await apps(), 'mytool'); await nap(300); const mt2 = byName(await apps(), 'mytool');
    ck('apps/custom: a command-line tool (kind bin) is added the same way; it never gets an icon', !!mt && mt.custom === true && mt.kind === 'bin' && mt.path === '/usr/local/bin/mytool' && mt.state === 'direct' && mt2.icon === '');
    await ctl('failnext=1'); r = await api('POST', '/api/apps/custom', { form: { path: '/Applications/Bear.app', state: 'auto' } }); jb = await run(r);
    ck('apps/custom: a failing job rolls the app back', jb.state === 'error' && !byName(await apps(), 'Bear'));
    r = await api('POST', '/api/apps/custom/delete', { form: { name: 'Cursor' } }); jb = await run(r); r2 = await api('POST', '/api/apps/custom/delete', { form: { name: 'Slack' } }); const d3 = await api('POST', '/api/apps/custom/delete', { form: { name: 'Nope' } }), d4 = await api('POST', '/api/apps/custom/delete'), d5 = await api('POST', '/api/apps/custom/delete', { form: { name: 'a/b' } });
    ck('apps/custom/delete: a job removes the custom app; a built-in or unknown app -> E_NOT_FOUND "custom app not found", a missing or malformed name -> E_INVALID', jb.state === 'done' && !byName(await apps(), 'Cursor') && jx(r2).code === 'E_NOT_FOUND' && jx(d3).code === 'E_NOT_FOUND' && jx(d4).code === 'E_INVALID' && jx(d5).code === 'E_INVALID' && !!byName(await apps(), 'Slack'));
    await api('POST', '/api/apps/custom/delete', { form: { name: 'mytool' } }).then(run);
  }

  /* ---- 测速目标: 内置 63 个 + 增 / 删 / 改 / 恢复 / 重置 ---- */
  {
    const tg = async (lang) => jx(await api('GET', '/api/speedtest/targets', { lang })), add = (form, lang) => api('POST', '/api/speedtest/targets', { form, lang }), one = (l, id) => l.targets.filter((x) => x.id === id)[0], plan = async () => jx(await api('GET', '/api/speedtest/plan'));
    const defCount = (l) => l.targets.filter((x) => x.default && !x.hidden).length;
    let l0 = await tg(); const lEn = await tg('en');
    ck('speedtest/targets GET: 63 built-in targets (global 15 / cn 12 / carrier 6 / dev 16 / media 14), the groups list, hidden 0, custom 0; every target has id / group / name / url / expect (string) / icon / builtin / modified / hidden / default; names follow X-Enana-Lang', l0.ok === true && l0.targets.length === 63 && JSON.stringify(l0.groups) === '["global","cn","carrier","dev","media"]' && l0.hidden === 0 && l0.custom === 0
      && l0.targets.every((x) => ['id', 'group', 'name', 'url', 'expect', 'icon', 'builtin', 'modified', 'hidden', 'default'].every((k) => k in x) && typeof x.expect === 'string' && x.builtin === true && x.modified === false && x.hidden === false && x.icon) && l0.targets.filter((x) => x.default).length === 20 && one(l0, 'wikipedia').name === '维基百科' && one(lEn, 'wikipedia').name === 'Wikipedia' && one(l0, 'google').expect === '204', l0.targets.length);
    r = await add({ name: 'My API', group: 'dev', url: 'https://api.example.com/health', expect: '200,204', icon: 'server' }); const uid = jx(r).id; l0 = await tg(); let pl = await plan();
    ck('speedtest/targets add: {ok, id:u-xxxxxx}; the target is listed (custom, not built-in, default:true like lib/speed.sh, expect / icon as given), counted in custom, and part of the plan', jx(r).ok === true && /^u-[0-9a-f]{6}$/.test(uid) && l0.custom === 1 && one(l0, uid).builtin === false && one(l0, uid).default === true && one(l0, uid).name === 'My API' && one(l0, uid).group === 'dev' && one(l0, uid).expect === '200,204' && one(l0, uid).icon === 'server' && one(l0, uid).url === 'https://api.example.com/health'
      && pl.targets.length === 64 && pl.targets.filter((x) => x.id === uid)[0].url === 'https://api.example.com/health' && pl.targets.filter((x) => x.default).length === 21, r.text);
    const bad = [{ group: 'dev', url: 'https://a.example.com/' }, { name: 'x'.repeat(41), group: 'dev', url: 'https://a.example.com/' }, { name: 'a|b', group: 'dev', url: 'https://a.example.com/' }, { name: 'a<b>', group: 'dev', url: 'https://a.example.com/' }, { name: 'ok', group: 'nope', url: 'https://a.example.com/' }, { name: 'ok', group: 'dev', url: 'ftp://a.example.com/' }, { name: 'ok', group: 'dev', url: 'https://a.example.com/a b' },
      { name: 'ok', group: 'dev', url: 'https://a.example.com/' + 'x'.repeat(300) }, { name: 'ok', group: 'dev', url: 'https://a.example.com/"q"' }, { name: 'ok', group: 'dev' }, { name: 'ok', group: 'dev', url: 'https://a.example.com/', expect: '99,200' }, { name: 'ok', group: 'dev', url: 'https://a.example.com/', expect: 'abc' },
      { name: 'ok', group: 'dev', url: 'https://a.example.com/', expect: '200,201,202,203,204,205,206,207,208,226,300' }, { name: 'ok', group: 'dev', url: 'https://a.example.com/', icon: 'Bad Icon!' }, { name: 'ok', group: 'dev', url: 'https://a.example.com/', icon: 'x'.repeat(31) }, { name: 'a\nb', group: 'dev', url: 'https://a.example.com/' }, { name: 'ok', group: 'dev', url: 'https://a.example.com/', id: 'BAD ID' }], br = [];
    for (const f of bad) br.push(await add(f, 'en'));
    ck('speedtest/targets add: no name, a name over 40 characters or with | < > or a line break, a bad group, a non-http(s) / spaced / over-300 / quoted URL, no URL, bad status codes (below 100, not a number, more than 10), a bad or over-long icon, a malformed id -> E_INVALID with a reason (the texts of lib/speed.sh); nothing is added', br.every((x) => jx(x).code === 'E_INVALID' && !!jx(x).error) && new Set(br.map((x) => jx(x).error)).size >= 8 && jx(br[0]).error === 'The name cannot be empty and can be at most 40 characters' && jx(br[2]).error === 'The name cannot contain | < > characters'
      && jx(br[4]).error === 'Invalid group' && jx(br[16]).error === 'Invalid target ID' && (await tg()).custom === 1, br.map((x) => jx(x).code));
    r = await add({ name: 'Cred', group: 'dev', url: 'https://user:pw@a.example.com/x', expect: '200,200', icon: '' }); const idCred = jx(r).id; await api('POST', '/api/speedtest/targets/delete', { form: { id: idCred } });
    ck('speedtest/targets: like lib/speed.sh a URL with user:pass@ and duplicate status codes are accepted (only the characters / length / shape are checked)', jx(r).ok === true && /^u-/.test(idCred));
    r = await add({ id: uid, name: 'My API v2', group: 'media', url: 'https://api2.example.com/ping', expect: '200', icon: 'film' }); l0 = await tg(); r2 = await add({ id: 'u-nonexist', name: 'x', group: 'dev', url: 'https://a.example.com/' }); const e3 = await add({ id: 'bad id!', name: 'x', group: 'dev', url: 'https://a.example.com/' }), e4 = await add({ id: uid, name: 'x', group: 'dev', url: 'nope' });
    ck('speedtest/targets edit a custom target: the whole record is replaced; an unknown id (E_INVALID, like lib/api.sh), a malformed id or invalid values -> E_INVALID', jx(r).ok === true && jx(r).id === uid && one(l0, uid).name === 'My API v2' && one(l0, uid).group === 'media' && one(l0, uid).url === 'https://api2.example.com/ping' && one(l0, uid).expect === '200' && one(l0, uid).icon === 'film' && l0.targets.length === 64 && jx(r2).code === 'E_INVALID' && jx(r2).error === '找不到这个测速目标' && jx(e3).code === 'E_INVALID' && jx(e4).code === 'E_INVALID');
    r = await add({ id: uid, name: 'Only required', group: 'dev', url: 'https://api3.example.com/' }); l0 = await tg();
    ck('speedtest/targets edit: fields that are not sent are reset (expect -> 200,204,301,302, icon -> empty), as in lib/speed.sh', one(l0, uid).expect === '200,204,301,302' && one(l0, uid).icon === '' && one(l0, uid).name === 'Only required');
    r = await add({ id: 'bing', name: 'Bing CN', group: 'cn', url: 'https://cn-bing.example.com/', expect: '200', icon: 'search' }); l0 = await tg(); pl = await plan(); const bEn = (await tg('en')).targets.filter((x) => x.id === 'bing')[0];
    ck('speedtest/targets edit a built-in target: saved as an override (modified:true, builtin:true; the name replaces both languages), reflected in the plan', jx(r).ok === true && one(l0, 'bing').modified === true && one(l0, 'bing').builtin === true && one(l0, 'bing').name === 'Bing CN' && bEn.name === 'Bing CN' && one(l0, 'bing').url === 'https://cn-bing.example.com/' && one(l0, 'bing').expect === '200' && pl.targets.filter((x) => x.id === 'bing')[0].name === 'Bing CN');
    r = await add({ id: 'bing', name: '必应 Bing', group: 'cn', url: 'https://bing.example.com/', expect: '200,301,302', icon: 'search' }); l0 = await tg();
    ck('speedtest/targets edit a built-in target back to its original values: it stays modified:true (as lib/speed.sh) until it is restored', one(l0, 'bing').modified === true && one(l0, 'bing').name === '必应 Bing');
    r = await api('POST', '/api/speedtest/targets/delete', { form: { id: 'pypi' } }); await add({ id: 'npm', name: 'npm', group: 'dev', url: 'https://npm2.example.com/' }); await api('POST', '/api/speedtest/targets/delete', { form: { id: 'npm' } }); l0 = await tg(); pl = await plan();
    ck('speedtest/targets/delete a built-in target: it is only hidden (still listed with hidden:true, counted in hidden) and missing from the plan', jx(r).ok === true && one(l0, 'pypi').hidden === true && one(l0, 'npm').hidden === true && one(l0, 'npm').modified === true && l0.hidden === 2 && pl.targets.length === 62 && !pl.targets.some((x) => x.id === 'pypi') && pl.targets.filter((x) => x.default).length === defCount(l0));
    r = await api('POST', '/api/speedtest/start', { form: { mode: 'direct', speed: '0', targets: 'google,pypi' } }); ck('speedtest/start: a hidden target cannot be tested -> E_INVALID', jx(r).code === 'E_INVALID');
    r = await api('POST', '/api/speedtest/targets/restore', { form: { id: 'npm' } }); l0 = await tg(); r2 = await api('POST', '/api/speedtest/targets/restore', { form: { id: uid } }); const rs4 = await api('POST', '/api/speedtest/targets/restore', { form: { id: 'nope' } }), rs5 = await api('POST', '/api/speedtest/targets/restore', { form: { id: 'Bad Id' } });
    ck('speedtest/targets/restore: a hidden built-in target comes back and its modifications are undone; a custom or unknown id -> E_NOT_FOUND, a malformed id -> E_INVALID', jx(r).ok === true && one(l0, 'npm').hidden === false && one(l0, 'npm').modified === false && one(l0, 'npm').url === 'https://npm.example.com/' && l0.hidden === 1 && jx(r2).code === 'E_NOT_FOUND' && jx(rs4).code === 'E_NOT_FOUND' && jx(rs5).code === 'E_INVALID');
    r = await api('POST', '/api/speedtest/targets/delete', { form: { id: uid } }); l0 = await tg(); r2 = await api('POST', '/api/speedtest/targets/delete', { form: { id: 'nope' } }); const r5 = await api('POST', '/api/speedtest/targets/delete');
    ck('speedtest/targets/delete a custom target removes it for good; unknown / missing id -> E_NOT_FOUND', jx(r).ok === true && l0.custom === 0 && !one(l0, uid) && l0.targets.length === 63 && jx(r2).code === 'E_NOT_FOUND' && jx(r5).code === 'E_NOT_FOUND');
    r = await add({ name: 'Slow API', group: 'dev', url: 'https://slow.example.com/x' }); const idSlow = jx(r).id; r = await add({ name: 'Dead API', group: 'global', url: 'https://dead.example.com/x' }); const idDead = jx(r).id; r = await add({ name: 'Blocked API', group: 'media', url: 'https://blocked.example.com/x' }); const idBlk = jx(r).id;
    r = await add({ name: 'CN Mirror', group: 'cn', url: 'https://mirror.example.com/x', expect: '200' }); const idCn = jx(r).id; r = await add({ name: 'Plain API', group: 'dev', url: 'https://plain.example.com/x' }); const idPl = jx(r).id;
    FAST = 80; r = await api('POST', '/api/speedtest/start', { form: { mode: 'both', speed: '0', nodes: SEED_PIN[0], targets: [idSlow, idDead, idBlk, idCn, idPl, 'google'].join(',') } }); const sidc = jx(r).id; let stc = {};
    for (let i = 0; i < 1500; i++) { stc = jx(await api('GET', '/api/speedtest/status', { q: { id: sidc } })); if (stc.state !== 'running') break; await nap(10); } FAST = F0;
    const cl = (t, rt) => stc.cells.filter((c) => c.t === t && c.r === rt)[0];
    ck('speedtest/start honours custom ids: the test runs them; hosts with slow / dead / blocked in the name behave that way on every route; a cn custom target is tested directly only (the node cell is skip); the others get a plausible, deterministic result; names are the given ones', stc.state === 'done' && stc.targets.length === 6 && stc.targets.filter((x) => x.id === idSlow)[0].name === 'Slow API' && cl(idSlow, 'direct').st === 'slow' && cl(idSlow, SEED_PIN[0]).st === 'slow' && cl(idDead, 'direct').st === 'fail' && cl(idDead, SEED_PIN[0]).st === 'fail'
      && cl(idBlk, 'direct').st === 'limited' && cl(idCn, 'direct').st === 'ok' && cl(idCn, SEED_PIN[0]).st === 'skip' && ['ok', 'slow', 'limited', 'fail'].indexOf(cl(idPl, 'direct').st) >= 0 && ['ok', 'slow', 'limited', 'fail'].indexOf(cl(idPl, SEED_PIN[0]).st) >= 0 && stc.cells.length === 12 && stc.cells.every((c) => c.st !== 'pending'), stc.cells.map((c) => c.t + ':' + c.r + ':' + c.st).join(' '));
    pl = await plan(); FAST = 80; r = await api('POST', '/api/speedtest/start', { form: { mode: 'direct', speed: '0' } }); const sidd = jx(r).id; for (let i = 0; i < 1500; i++) { stc = jx(await api('GET', '/api/speedtest/status', { q: { id: sidd } })); if (stc.state !== 'running') break; await nap(10); } FAST = F0;
    ck('speedtest/start without targets= tests the default targets (the plan\'s default:true ones — the 20 built-in ones plus the custom ones, as lib/speed.sh)', stc.state === 'done' && stc.targets.length === 25 && stc.targets.length === pl.targets.filter((x) => x.default).length && stc.targets.some((x) => x.id === idSlow) && stc.targets.every((x) => pl.targets.filter((y) => y.id === x.id)[0].default === true));
    r = await api('POST', '/api/speedtest/targets/delete', { form: { id: 'google' } }); await api('POST', '/api/speedtest/targets/reset'); l0 = await tg(); pl = await plan();
    ck('speedtest/targets/reset: custom targets, hidden targets and modifications are all cleared (63 built-in, hidden 0, custom 0, 20 default)', l0.targets.length === 63 && l0.hidden === 0 && l0.custom === 0 && l0.targets.every((x) => x.builtin && !x.modified && !x.hidden) && pl.targets.length === 63 && pl.targets.filter((x) => x.default).length === 20);
  }

  /* ---- DNS: 更多预设 / 自定义解析 (hosts) / 服务器测速 ---- */
  {
    const dget = async (lang) => jx(await api('GET', '/api/dns', { lang })), hpost = (form, lang) => api('POST', '/api/dns/hosts', { form, lang });
    await api('POST', '/api/dns', { form: { cn: 'alidns', global: 'cloudflare', via: 'Global', leak_guard: '1', ads_block: '0' } }).then(run);        // 前面的检查把防泄漏关掉了
    let dd = await dget();
    ck('dns presets: cn = system, alidns, dnspod, dnspod-dot, 114, baidu, cnnic, custom; global = cloudflare, cloudflare-security, google, quad9, adguard, opendns, custom; every one has bilingual name / desc and a url (custom: empty); only placeholder addresses', dd.presets.cn.map((p) => p.id).join() === 'system,alidns,dnspod,dnspod-dot,114,baidu,cnnic,custom'
      && dd.presets.global.map((p) => p.id).join() === 'cloudflare,cloudflare-security,google,quad9,adguard,opendns,custom' && ['cn', 'global'].every((sc) => dd.presets[sc].every((p) => p.name && p.name_en && 'desc' in p && 'desc_en' in p && 'url' in p && (p.id === 'custom' ? p.url === '' : p.url.length > 0 && p.desc && p.desc_en)))
      && !/(^|[^0-9])(223\.5\.5\.5|1\.12\.12\.12|114\.114\.114\.114|1\.1\.1\.1|8\.8\.8\.8|9\.9\.9\.9)([^0-9]|$)/.test(JSON.stringify(dd.presets)), dd.presets.cn.map((p) => p.id));
    r = await api('POST', '/api/dns', { form: { cn: 'dnspod-dot', global: 'cloudflare-security' } }); jb = await run(r); dd = await dget();
    ck('dns: the new presets can be selected (dnspod-dot, cloudflare-security)', jb.state === 'done' && dd.settings.cn === 'dnspod-dot' && dd.settings.global === 'cloudflare-security' && dd.pipeline.filter((x) => x.id === 'global')[0].server === 'cloudflare-security'); await api('POST', '/api/dns', { form: { cn: 'alidns', global: 'cloudflare' } }).then(run);
    r = await hpost({ action: 'add', domain: 'nas.example.com', ip: '192.0.2.10' }, 'en'); jb = await waitJob(jx(r).job, 'en'); dd = await dget('en');
    ck('dns/hosts add: a job; GET /api/dns lists hosts [{domain, ip}]; the pipeline gets a first "hosts" row (server hosts, via none, count, translated detail) before the other rows', jx(r).ok === true && jb.state === 'done' && dd.hosts.length === 1 && JSON.stringify(dd.hosts[0]) === '{"domain":"nas.example.com","ip":"192.0.2.10"}' && dd.pipeline[0].id === 'hosts' && dd.pipeline[0].match === 'hosts' && dd.pipeline[0].server === 'hosts'
      && dd.pipeline[0].via === 'none' && dd.pipeline[0].count === 1 && /Matching names use the IP you entered/.test(dd.pipeline[0].detail) && dd.pipeline[0].server_name === '本地对照表' && dd.pipeline[0].server_name_en === 'Local table' && dd.pipeline.map((x) => x.id).join() === 'hosts,direct,cn,proxy,global', dd.pipeline.map((x) => x.id));
    const rowOf = (id) => dd.pipeline.filter((x) => x.id === id)[0];
    ck('dns pipeline: rows hosts | ads | direct | cn | proxy | global (ids and match as ui/v-dns.js expects); "direct sites use the domestic DNS" (server = the cn preset, via direct) and "proxied sites are resolved by the proxy" (server proxy, via = the proxy route, always present); texts as lib/dns.sh', rowOf('direct').match === 'direct' && rowOf('direct').server === 'alidns' && rowOf('direct').via === 'direct' && /always resolved with domestic DNS/.test(rowOf('direct').detail)
      && rowOf('cn').match === 'geosite-cn' && rowOf('proxy').match === 'proxy' && rowOf('proxy').server === 'proxy' && rowOf('proxy').via === 'auto' && /handed to the proxy server/.test(rowOf('proxy').detail) && rowOf('proxy').server_name_en === 'Proxy server' && rowOf('global').match === 'all');
    r = await api('POST', '/api/dns/test', { form: { name: 'nas.example.com' } }); await hpost({ action: 'add', domain: 'v6.example.com', ip: '2001:DB8::5' }).then(run);
    const t6 = await api('POST', '/api/dns/test', { form: { name: 'v6.example.com' } }), t7 = await api('POST', '/api/dns/test', { form: { name: 'example.com' } }), cq4 = await clashR('GET', '/dns/query?name=nas.example.com&type=A'), cq6 = await clashR('GET', '/dns/query?name=nas.example.com&type=AAAA'), cq66 = await clashR('GET', '/dns/query?name=v6.example.com&type=AAAA');       // 配置刚应用完核心会重启一下: 等它回来
    ck('dns/test honours the custom hosts: answers come from them first ({answers:[ip], source:"hosts", ms <= 3}; an IPv6 is stored in lower case); other names still go to the DNS (source "dns"); Clash /dns/query too (A vs AAAA by IP family)', jx(r).answers.join() === '192.0.2.10' && jx(r).source === 'hosts' && jx(r).ms <= 3 && jx(t6).answers.join() === '2001:db8::5' && jx(t6).source === 'hosts' && jx(t7).source === 'dns'
      && jx(cq4).Answer.length === 1 && jx(cq4).Answer[0].data === '192.0.2.10' && (jx(cq6).Answer || []).length === 0 && jx(cq66).Answer[0].data === '2001:db8::5');
    const hbad = {}; for (const [k, f] of [['wild', { domain: '*.example.com', ip: '192.0.2.1' }], ['local', { domain: 'localhost', ip: '192.0.2.1' }], ['nodom', { domain: '', ip: '192.0.2.1' }], ['noip', { domain: 'a.example.com', ip: '' }], ['ip999', { domain: 'a.example.com', ip: '999.1.1.1' }], ['ip3', { domain: 'a.example.com', ip: '1.2.3' }], ['ipabc', { domain: 'a.example.com', ip: 'abc' }],
      ['ip6bad', { domain: 'a.example.com', ip: '2001:db8:::1' }], ['zone', { domain: 'a.example.com', ip: 'fe80::1%eth0' }], ['lead0', { domain: 'a.example.com', ip: '01.2.3.4' }], ['dup', { domain: 'NAS.example.com.', ip: '192.0.2.99' }]]) hbad[k] = await hpost(Object.assign({ action: 'add' }, f), 'en');
    ck('dns/hosts add: an invalid domain (the site-domain rules) or IP (IPv4 without leading zeros / IPv6, no zone id) or a duplicate domain (compared after normalizing) -> E_INVALID with a reason (the texts of lib/dns.sh); nothing is added', Object.keys(hbad).every((k) => jx(hbad[k]).code === 'E_INVALID' && !!jx(hbad[k]).error) && jx(hbad.dup).error === 'This domain already has a DNS record; edit that one instead' && jx(hbad.ip999).error === 'The IP address is not valid (IPv4 and IPv6 are supported)' && (await dget()).hosts.length === 2, Object.keys(hbad).map((k) => k + ':' + jx(hbad[k]).code));
    r = await hpost({ action: 'update', domain: 'nas.example.com', ip: '192.0.2.11' }); await run(r); r = await hpost({ action: 'update', domain: 'nas.example.com', new_domain: 'nas2.example.com' }); await run(r); r = await hpost({ action: 'update', domain: 'nas2.example.com', new_domain: 'nas3.example.com', ip: '198.51.100.7' }); await run(r); dd = await dget();
    ck('dns/hosts update: change the IP, rename the domain (new_domain; the IP stays), or both; the entry keeps its position', dd.hosts.map((h) => h.domain + '=' + h.ip).join() === 'nas3.example.com=198.51.100.7,v6.example.com=2001:db8::5', dd.hosts);
    const hu = [await hpost({ action: 'update', domain: 'nope.example.com', ip: '192.0.2.1' }), await hpost({ action: 'remove', domain: 'nope.example.com' }), await hpost({ action: 'update', domain: 'nas3.example.com', new_domain: 'v6.example.com' }), await hpost({ action: 'update', domain: 'nas3.example.com', ip: 'bogus' }), await hpost({ action: 'frob', domain: 'x.example.com', ip: '192.0.2.1' }), await hpost({ action: 'update', domain: 'nas3.example.com', new_domain: 'bad domain' })];
    const huNop = await hpost({ action: 'update', domain: 'nas3.example.com' }); await run(huNop);
    ck('dns/hosts: update / remove of an unknown domain, update to an existing name / a bad IP / a bad new name, an unknown action -> E_INVALID (lib/api.sh answers E_INVALID for all of them); an update with nothing to change is fine', hu.every((x) => jx(x).code === 'E_INVALID' && !!jx(x).error) && jx(hu[0]).error === '没有这条解析记录' && jx(hu[2]).error === '新的域名已经有解析记录了' && jx(huNop).ok === true && (await dget()).hosts.length === 2);
    r = await hpost({ action: 'remove', domain: 'nas3.example.com' }); await run(r); dd = await dget(); ck('dns/hosts remove', dd.hosts.length === 1 && dd.hosts[0].domain === 'v6.example.com');
    for (let i = dd.hosts.length; i < 200; i++) await hpost({ action: 'add', domain: 'h' + i + '.example.com', ip: '192.0.2.' + (i % 250 + 1) }); const hmax = await hpost({ action: 'add', domain: 'one-more.example.com', ip: '192.0.2.1' }, 'en'); dd = await dget();
    ck('dns/hosts: at most 200 entries (the 201st -> E_INVALID)', dd.hosts.length === 200 && jx(hmax).code === 'E_INVALID' && /at most 200/.test(jx(hmax).error));
    r = await api('POST', '/api/dns/hosts/reset'); jb = await run(r); dd = await dget(); ck('dns/hosts/reset: a job clears every entry; the "hosts" pipeline row disappears', jb.state === 'done' && dd.hosts.length === 0 && dd.pipeline[0].id === 'direct');
    await ctl('failnext=1'); r = await hpost({ action: 'add', domain: 'rb.example.com', ip: '192.0.2.5' }); jb = await run(r); dd = await dget(); ck('dns/hosts: a failing job rolls the change back', jb.state === 'error' && dd.hosts.length === 0);
    r = await api('POST', '/api/dns/bench'); jb = await run(r); const bn = jb.result; jb = await run(await api('POST', '/api/dns/bench')); const bn2 = jb.result;
    const cnIds = dd.presets.cn.filter((p) => p.id !== 'custom').map((p) => p.id), glIds = dd.presets.global.filter((p) => p.id !== 'custom').map((p) => p.id);
    ck('dns/bench: a job whose result {cn:[{id,ms}], global:[{id,ms}]} covers EVERY non-custom preset (and never "custom"); cn 8-60 ms, global 40-300 ms, exactly one preset is unreachable (ms:null)', /^dns-bench-/.test(jx(r).job) && jb.state === 'done' && JSON.stringify(bn.cn.map((x) => x.id)) === JSON.stringify(cnIds) && JSON.stringify(bn.global.map((x) => x.id)) === JSON.stringify(glIds) && bn.cn.length === 7 && bn.global.length === 6
      && bn.cn.every((x) => x.ms >= 8 && x.ms <= 60) && bn.global.filter((x) => x.ms !== null).every((x) => x.ms >= 40 && x.ms <= 300) && bn.global.filter((x) => x.ms === null).length === 1 && bn.global.filter((x) => x.ms === null)[0].id === 'adguard' && JSON.stringify(bn).indexOf('custom') < 0, bn);
    ck('dns/bench: result.via names the route the overseas presets were tested through (Global = the auto route; direct without nodes)', bn.via === 'Global' && bn2.via === 'Global');
    ck('dns/bench: deterministic-ish (a second run differs by only a few ms per preset; the unreachable one stays unreachable)', bn.cn.every((x, i) => Math.abs(x.ms - bn2.cn[i].ms) <= 6) && bn.global.every((x, i) => (x.ms === null) === (bn2.global[i].ms === null) && (x.ms === null || Math.abs(x.ms - bn2.global[i].ms) <= 6)));
  }

  /* ---- 添加自己的服务器: E_VPS_VERIFY (放行端口后重新验证) / 默认服务器名 my-vps-<host> / redetect 结果 ---- */
  {
    FAST = 80; const vc = (host, extra) => Object.assign({ host, port: '22', user: 'root', mode: 'password', password: 'S3cretPw-xyz', hostkey: fingerprint(host) }, extra);
    const vprov = async (form, lang) => { const x = await api('POST', '/api/vps/provision', { form, lang }); return jx(x).job ? waitJob(jx(x).job, lang) : { state: 'nojob', start: jx(x) }; };
    let v1 = await vprov(vc('203.0.113.70'), 'en');
    ck('vps: the magic host .70 fails at the verify step with E_VPS_VERIFY (job code + result.code + result.port, translated hint to allow the port, step 7 marked)', v1.state === 'error' && v1.code === 'E_VPS_VERIFY' && v1.result.code === 'E_VPS_VERIFY' && v1.result.port === 443 && /does not allow port 443\/tcp/.test(v1.msg) && v1.steps[6].state === 'error' && v1.steps.length === 9, v1);
    await ctl('vpsport=open'); v1 = await vprov(vc('203.0.113.70')); const vl = jx(await api('GET', '/api/vps')).vps.filter((x) => x.host === '203.0.113.70')[0];
    ck('ctl vpsport=open: provisioning .70 again succeeds; without a name the server name is my-vps-<host> and the node tag <name>-<egress ip>; the record has name + hostkey', v1.state === 'done' && v1.result.nodes[0].tag === 'my-vps-203.0.113.70-203.0.113.70' && v1.result.nodes[0].egress === '203.0.113.70' && !!vl && vl.name === 'my-vps-203.0.113.70' && vl.hostkey === fingerprint('203.0.113.70') && Object.keys(v1.result).sort().join() === 'ips,nodes,vps', v1.result);
    const rdx = await api('POST', '/api/vps/redetect', { form: vc('203.0.113.70', { id: vl.id }) }), rdj = await waitJob(jx(rdx).job);
    ck('vps/redetect result keys: {nodes, ips, vps, added}', rdj.state === 'done' && Object.keys(rdj.result).sort().join() === 'added,ips,nodes,vps' && rdj.result.added === 0 && rdj.result.vps === vl.id);
    await ctl('vpsport=closed'); v1 = await vprov(vc('203.0.113.70')); ck('ctl vpsport=closed brings the failure back', v1.state === 'error' && v1.code === 'E_VPS_VERIFY');
    const dom = 'vps.example.com'; v1 = await vprov(vc(dom)); ck('vps: a domain host gets the default name my-vps-<domain> (node tag my-vps-<domain>-<egress ip>)', v1.state === 'done' && v1.result.nodes[0].tag === 'my-vps-vps.example.com-' + pubIp(dom), v1.result);
    v1 = await vprov(vc('203.0.113.80', { name: 'my-own' })); ck('vps: an explicit name wins (tag <name>-<egress ip>)', v1.state === 'done' && v1.result.nodes[0].tag === 'my-own-203.0.113.80'); FAST = F0;
  }

  /* ---- 模糊测试: 新接口收到畸形的参数 / 请求体时不能 5xx、不能断开连接、不能让处理函数抛异常 ---- */
  {
    const rg = mulberry(hash('fuzz-selftest')), nasty = ['', ' ', 'a', '../../etc/passwd', '%00', '\u0000', '<script>', '{"a":', '[]', 'null', '__proto__', 'constructor', 'x'.repeat(300), '😀', '\n', '=&=', '999999999999999999999', '-1', '1e309', 'NaN', "'", '"', '\\', '*', '%', '?', '#', 'true', 'toString', 'hasOwnProperty', '/Applications/', 'add', 'update', 'remove'];
    const eps = [['POST', '/api/prefs'], ['POST', '/api/auth/verify'], ['POST', '/api/password'], ['GET', '/api/servers/secret'], ['GET', '/api/sub/url'], ['GET', '/api/export'], ['GET', '/api/sites/domains'], ['POST', '/api/sites/domains'], ['POST', '/api/sites/domains/reset'], ['POST', '/api/apps/inspect'], ['POST', '/api/apps/custom'], ['POST', '/api/apps/custom/delete'],
      ['POST', '/api/speedtest/targets'], ['POST', '/api/speedtest/targets/delete'], ['POST', '/api/speedtest/targets/restore'], ['POST', '/api/dns/hosts'], ['POST', '/api/dns/test'], ['POST', '/api/vps/provision'], ['POST', '/api/vps/redetect'], ['GET', '/ui/appicons/x'], ['GET', '/api/speedtest/targets']];
    const keys = ['id', 'tag', 'name', 'domain', 'new', 'new_domain', 'action', 'ip', 'input', 'path', 'state', 'url', 'group', 'expect', 'icon', 'old', 'password', 'host', 'hostkey', 'mode', 'role'];
    let bad5 = 0, badShape = 0, handlerErrs = 0; const oldErr = console.error; console.error = () => { handlerErrs++; };
    for (let i = 0; i < 200; i++) {
      const e = pick(rg, eps), form = {}, nk = Math.floor(rg() * 5); for (let k = 0; k < nk; k++) form[pick(rg, keys)] = pick(rg, nasty);
      const body = e[0] === 'POST' && rg() < 0.3 ? pick(rg, nasty) : null; let x;
      if (e[0] === 'GET') x = e[1].indexOf('/ui/') === 0 ? await rq('GET', e[1] + encodeURIComponent(pick(rg, nasty)), { noHdr: true }) : await api('GET', e[1], { q: form, sudo: rg() < 0.5 ? undefined : false });
      else x = await api('POST', e[1], body === null ? { form } : { body, q: form });
      if (x.status >= 500 || x.status === 0) bad5++; if (e[1].indexOf('/ui/') !== 0 && (!x.json || typeof x.json.ok !== 'boolean') && !(e[1] === '/api/export' && x.status === 200)) badShape++;
    }
    console.error = oldErr; await ctl('lock=reset');
    ck('fuzz: 200 malformed requests (random keys / nasty values / bodies) against the new endpoints -> no 5xx, no dropped connection, always a JSON {ok}, no handler exception', bad5 === 0 && badShape === 0 && handlerErrs === 0, [bad5, badShape, handlerErrs]);
    T = jx(await login(D1, P1)).token;
  }
  /* 操作记录: 这次自测里真实产生的动作码 (ts >= 自测开始时间) 都要出现, 并且全部在文档约定的集合里 (reset 会重建日志, 所以先检查) */
  const live = jx(await logs({ type: 'ops', day: dayOf(now()), limit: '2000' })).rows.filter((x) => x.ts >= tStart), liveCodes = {}; live.forEach((x) => { liveCodes[x.action] = 1; });
  const want = OPS_CODES.filter((c) => ['install', 'upgrade', 'uninstall', 'start', 'stop', 'autosite.add', 'apps.found'].indexOf(c) < 0);          // autosite.add / apps.found 是后台自动记的 (who = auto), 不由某个接口触发
  ck('ops log: every state-changing endpoint wrote its stable action code, nothing outside the documented set', want.every((c) => liveCodes[c]) && Object.keys(liveCodes).every((c) => OPS_CODES.indexOf(c) >= 0), want.filter((c) => !liveCodes[c]).concat(Object.keys(liveCodes).filter((c) => OPS_CODES.indexOf(c) < 0)));
  ck('ops log: details are logfmt (tags with spaces are quoted), result ok|error, who dashboard', live.some((x) => x.action === 'servers.role' && /^tag="Selftest [AB]" role=\w+$/.test(x.detail)) && live.every((x) => ['ok', 'error'].indexOf(x.result) >= 0 && x.who === 'dashboard') && live.some((x) => x.result === 'error'));
  /* ---- reset=1: 启动时的应用图标陆续出现 / 种子密码恢复 / 套餐与偏好回到初始 (放在操作记录检查之后: reset 会重建日志) ---- */
  {
    FAST = 4; await ctl('plan=pro&prefs=bump'); await api('POST', '/api/password', { form: { old: P1, new: 'resetme-99' } }); CURPW = 'resetme-99';
    await ctl('reset=1'); const early = jx(await api('GET', '/api/apps')).apps, elig = (l) => l.filter((a) => ['zoom.us', 'ClashX Pro', 'WPS Office'].indexOf(a.name) < 0); await nap(1700); const late = jx(await api('GET', '/api/apps')).apps; FAST = F0; CURPW = P1;
    ck('startup apps get their icons progressively (0-6 simulated seconds after the start, scaled by --fast): right after reset=1 some are still missing, 6.8 simulated seconds later all are there', elig(early).some((a) => a.icon === '') && elig(late).every((a) => a.icon !== '') && late.filter((a) => !a.icon).length === 3, [early.filter((a) => !a.icon).length, late.filter((a) => !a.icon).length]);
    const rp = await login(D1, P1), rp2 = await login(D1, 'resetme-99'); T = jx(rp).token; const pfr = jx(await api('GET', '/api/plan')), svr0 = jx(await api('GET', '/api/state')), prr = jx(await api('GET', '/api/prefs'));
    ck('reset=1 restores the seed password (demo1234 logs in, the changed one does not), the free plan with no official nodes (27 servers), empty prefs (version 0), no custom apps / site domains / host entries / target edits', jx(rp).ok === true && jx(rp2).code === 'E_BAD_CREDENTIALS' && pfr.features.official_proxy.coming_soon === true && svr0.servers.length === 27 && svr0.servers.every((x) => !x.official) && prr.version === 0 && svr0.prefs_version === 0
      && jx(await api('GET', '/api/apps')).apps.every((a) => !a.custom) && (await rq('GET', '/ui/catalog.json', { noHdr: true })).json.entries.every((e) => !e.modified) && jx(await api('GET', '/api/dns')).hosts.length === 0 && jx(await api('GET', '/api/speedtest/targets')).custom === 0);
  }
  r = await ctl('reset=first-run'); const fr = jx(await api('GET', '/api/state')), pf = jx(await api('GET', '/api/speedtest/plan'));
  ck('reset=first-run: no servers/subs, first_run, token kept, rules missing', fr.ok === true && fr.servers.length === 0 && fr.subs.length === 0 && fr.first_run === true && fr.env.rules === false && fr.env.rules_missing.length === 2 && pf.node_available === false && pf.defaults.mode === 'direct');
  const fs0 = jx(await api('GET', '/api/sync'));
  ck('first-run: a fresh computer still sees the cloud data (remote.exists) so the UI can offer a one-click sync; local version 0, not dirty, sync off', fs0.remote.exists === true && fs0.remote.version === 7 && fs0.local.version === 0 && fs0.local.dirty === false && fs0.enabled === false && fs0.online === true);
  await api('POST', '/api/sync/settings', { form: { enabled: '1' } }); r = await api('POST', '/api/sync/pull', { form: { mode: 'replace' } }); jb = await run(r); const fs1 = jx(await api('GET', '/api/state'));
  ck('first-run: one-click pull fills the empty computer (29 servers, first_run false, local.version = remote.version)', jb.state === 'done' && fs1.servers.length === 29 && fs1.first_run === false && jx(await api('GET', '/api/sync')).local.version === 7);
  r = await ctl('reset=first-run');
  r = await api('POST', '/api/speedtest/start', { form: { mode: 'node' } }); r2 = await api('POST', '/api/speedtest/start', { form: { mode: 'both', speed: '0' } }); await api('POST', '/api/speedtest/stop');
  ck('speedtest/start without servers: node mode -> E_NO_SERVERS; both degrades to direct', jx(r).code === 'E_NO_SERVERS' && jx(r2).ok === true && jx(await api('GET', '/api/speedtest/status')).mode === 'direct');
  n = jx(await api('GET', '/api/net/info')); ck('net/info without servers: routes [] automatically', n.routes.length === 0 && n.direct.ok === true);
  jb = await run(await api('POST', '/api/dns/bench')); ck('dns/bench without servers: the overseas presets are all unreachable (ms:null) — there is no route to test them through — while the domestic ones still answer', jb.state === 'done' && jb.result.global.length === 6 && jb.result.global.every((x) => x.ms === null) && jb.result.cn.every((x) => x.ms >= 8 && x.ms <= 60) && jb.result.via === 'direct');
  n = jx(await api('GET', '/api/stats', { q: { range: '30d' } })); ck('stats without servers: everything is direct (pin = auto = 0), nodes []', n.nodes.length === 0 && n.routes.direct.down > 0 && n.routes.pin.up + n.routes.pin.down + n.routes.auto.up + n.routes.auto.down === 0);
  await ctl('reset=1'); r = await api('GET', '/api/state'); ck('reset=1 restores the initial dataset (27 servers) and keeps the token', jx(r).servers.length === 27 && jx(r).update.available === true);

  /* ---- --split: 辅助服务在另一个端口, CORS 只放行仪表盘自己的来源 ---- */
  SPLIT = true; helperSrv = null;
  for (let p = 18090; p <= 18099 && !helperSrv; p++) { if (p === PORT) continue; const h = makeHelper(); try { await listenOn(h, p); helperSrv = h; HPORT = p; } catch (e) { if (e.code !== 'EADDRINUSE') throw e; } }
  if (!helperSrv) console.log('skip  split checks: no second free port in 18090-18099');
  else {
    const origin = 'http://127.0.0.1:' + PORT;
    r = await rq('OPTIONS', '/api/state', { port: HPORT, noHdr: true, headers: { Origin: origin, 'Access-Control-Request-Method': 'GET' } });
    ck('split: preflight allows X-Enana, X-TProxy, X-Enana-Token, X-Enana-Lang, X-Enana-Sudo, Content-Type for the dashboard origin', r.status === 204 && r.headers['access-control-allow-origin'] === origin
      && ['x-enana', 'x-tproxy', 'x-enana-token', 'x-enana-lang', 'x-enana-sudo', 'content-type'].every((h) => (r.headers['access-control-allow-headers'] || '').toLowerCase().indexOf(h) >= 0));
    r = await rq('POST', '/api/sub/fetch', { port: HPORT, token: T, headers: { Origin: origin }, body: 'https://sub.example.com/sub/demo' }); r2 = await rq('GET', '/api/auth/status', { port: HPORT, headers: { Origin: 'http://evil.example' } });
    ck('split: responses expose X-Subscription-Userinfo; a foreign origin gets no CORS header; env.json points at the helper port', (r.headers['access-control-expose-headers'] || '').indexOf('X-Subscription-Userinfo') >= 0 && !r2.headers['access-control-allow-origin'] && jx(await rq('GET', '/ui/env.json', { noHdr: true })).apiBase === 'http://127.0.0.1:' + HPORT);
    r = await rq('GET', '/api/auth/status', { noHdr: true }); ck('split: /api/* on the UI port is not served', r.status === 404);
    helperSrv.close();
  }
  SPLIT = false; HPORT = PORT; srv.close();
  console.log('selftest: ' + pass + ' ok, ' + bad + ' FAIL');
  return bad ? 1 : 0;
}

/* ===================== 12. 启动 ===================== */
async function startServers() {
  reset(flag('first-run') ? 'first-run' : 'full');
  setInterval(settle, 150).unref();
  const main = makeMain(); await listenOn(main, PORT);
  let helper = null; if (SPLIT) { helper = makeHelper(); await listenOn(helper, HPORT); }
  return { main, helper };
}
function banner() {
  console.log('enana mock: http://' + HOST + ':' + PORT + '/ui/' + (SPLIT ? '   (helper API with CORS: http://' + HOST + ':' + HPORT + ')' : '') + (FAST > 1 ? '   [time x' + FAST + ']' : ''));
  console.log('  test accounts (mock only): demo@example.com / demo1234, other@example.com / other1234     --help lists the options, /mock/ctl?... the runtime switches');
}
process.on('SIGTERM', () => process.exit(0));
process.on('SIGINT', () => process.exit(0));
process.on('uncaughtException', (e) => { console.error('mock-server: uncaught exception (kept running): ' + safeErr(e)); if (SELFTEST) process.exitCode = 1; });
if (SELFTEST) selftest().then((code) => process.exit(code || process.exitCode || 0), (e) => { console.error('selftest crashed: ' + (e && e.stack ? e.stack : e)); process.exit(1); });
else {
  startServers().then(() => { banner(); setInterval(() => liveTick(1), 5000).unref(); }, (e) => { console.error('mock-server: cannot start: ' + e.message); process.exit(1); });
}
