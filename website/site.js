/* enana.cc 首页脚本: 中英文切换、按访问者的系统先显示对应的安装命令、复制按钮。
 * 不发任何网络请求; 文字只通过 textContent / setAttribute 写进页面 (没有 innerHTML)。 */
(function () {
  'use strict'

  var DICT = {
    zh: {
      title: 'enana · 一条命令安装 sing-box 代理环境 | macOS / Windows 分应用分流',
      desc: 'enana 一条命令在 macOS / Windows 上装好 sing-box 代理环境, 自带本机浏览器仪表盘: 按应用、按网站分流, DNS 测速与解析策略, 订阅和分享链接一键导入, SSH 一键部署自己的服务器。数据只保存在你的电脑上。',
      skip: '跳到主要内容',
      'lang.label': '语言',
      'os.label': '选择系统',
      eyebrow: 'macOS / Windows 预览版 · sing-box · 本机浏览器仪表盘',
      h1: '一条命令安装 sing-box 代理环境',
      lead: 'enana 在 macOS / Windows 上一条命令装好 sing-box 代理环境 (含规则集、开机自启、系统代理和 enana 命令)。之后所有设置都在浏览器里的本机仪表盘完成: 导入订阅和分享链接、按应用和网站分流、DNS 测速、SSH 一键部署自己的服务器。你的服务器、订阅、规则和流量只保存在自己的电脑上。',
      'inst.h': '安装 enana',
      'os.unix': 'macOS (终端)',
      'os.win': 'Windows (64 位 PowerShell) · 预览版',
      'alt.wget': '没有 curl? 用 wget:',
      'alt.cmd': '在命令提示符 (cmd) 里用:',
      copy: '复制',
      copied: '已复制',
      'copy.ok': '命令已复制, 粘贴到终端里回车即可。',
      'copy.fail': '没能自动复制, 请选中上面的命令手动复制。',
      'inst.hint': '在任意终端执行即可安装。',
      'latest.a': '每次安装的都是 enana 的最新版本: 安装脚本会先读取',
      'latest.b': ' 获知最新版本号和校验值。',
      'dash.a': '安装完成后会自动打开本机后台',
      'dash.b': ' (端口被占用时会自动换一个, 安装结束时会打印实际地址); 在后台里注册或登录 enana 账号即可开始使用。',
      'feat.h': '功能特点',
      'f1.t': '一条命令安装, 自动检查环境',
      'f1.d': '安装脚本先识别系统版本、芯片、管理员权限和网络, 缺什么补什么; 端口被占用会自动换一个; 下载的安装包经过 SHA-256 校验; 重复运行是安全的, 已就绪的部分会自动跳过。',
      'f2.t': '本机浏览器仪表盘',
      'f2.d': '安装完成后自动打开本机后台, 中英文界面, 手机和窄屏也能正常使用; 所有设置都先确认再生效, 配置出错会自动回滚。',
      'f3.t': '按应用、按网站分流',
      'f3.d': '给每个应用和网站选择: 跟随规则、固定出口、自动线路或直连。System Proxy 处理遵守代理的连接, Enhanced/TUN 可接管其它公网 TCP/UDP (需管理员授权), 本机回调与局域网保持直连。AI 和账号类服务可以固定出口, 避免因为 IP 变化触发风控; Google、YouTube 等走自动线路, 国内网站直连。',
      'f4.t': '订阅、分享链接、Clash 配置一键导入',
      'f4.d': '粘贴订阅链接、trojan / hysteria2 / tuic / vless / vmess / ss 分享链接, 或 Clash、sing-box 配置, 自动识别格式并先预览再导入。',
      'f5.t': 'SSH 一键部署自己的服务器',
      'f5.d': '输入 IP 和密码或密钥, 在 Debian / Ubuntu 服务器上自动安装并生成 VLESS + Reality 节点, 识别全部出口 IP 并在本机验证; SSH 密码和私钥只在任务期间使用, 不会保存。',
      'f6.t': 'DNS、测速和流量统计',
      'f6.d': 'DoH / DoT 预设和自定义解析、DNS 测速与解析策略、100 个内置测速目标 (可自定义)、按线路和节点统计流量, 数据只保存在本机。',
      'f7.t': '隐私与安全',
      'f7.d': '服务器、订阅和流量只在你的电脑上; 可选的云端同步先在本机端到端加密, enana.cc 只看到密文; 删除服务器、查看凭据等敏感操作需要再次输入密码。',
      'how.h': '三步开始使用',
      how1: '在终端运行上面的安装命令, 等它装好环境并打开后台。',
      how2: '在后台注册或登录 enana 账号 (只需要邮箱和密码)。',
      how3: '添加或导入服务器, 选择自动模式或全局代理, 打开代理总开关。',
      'faq.h': '常见问题',
      q1: 'enana 是什么?',
      a1: 'enana 是基于 sing-box 的代理环境一键安装器和本机浏览器仪表盘: 终端只负责安装环境, 服务器、订阅、应用和网站分流、DNS、测速等设置都在仪表盘里完成。',
      q2: '支持哪些系统?',
      a2: '支持 macOS (Apple 芯片和 Intel); Windows 10 2004+ / Windows 11 (x64、ARM64) 提供预览版。两种系统共用仪表盘, 保留 System Proxy 和可选 Enhanced/TUN; Windows TUN 与原生应用登录仍需实机验收。',
      q3: '怎么安装和升级?',
      a3: '在终端运行上面的一行安装命令即可; 升级时再运行一遍, 或在终端输入 enana self-update。没有 curl 时用 wget 的那条命令。',
      q4: '我的服务器和订阅会上传到云端吗?',
      a4: '不会。它们只保存在你的电脑上。如果你打开云端同步, 数据会先在本机端到端加密再上传, enana.cc 只保存密文, 看不到服务器地址和密码。',
      q5: '和直接使用 sing-box 或 Clash 有什么区别?',
      a5: 'enana 帮你装好并管理 sing-box, 不需要手写配置: 导入订阅、按应用和网站分流、DNS 和测速都在图形界面里完成, 改动先校验再应用, 失败自动回滚。',
      q6: '怎么卸载?',
      a6: '在终端输入 enana uninstall (加 --keep-data 可以保留你的数据)。'
    },
    en: {
      title: 'enana · One-command sing-box proxy setup for macOS / Windows | per-app routing',
      desc: 'One-command sing-box proxy setup for macOS / Windows with a local browser dashboard: per-app and per-site routing, DNS tools and resolver policies, one-click subscription import and SSH server deployment. Your data stays on your computer.',
      skip: 'Skip to main content',
      'lang.label': 'Language',
      'os.label': 'Choose your system',
      eyebrow: 'macOS / Windows 预览版 · sing-box · local browser dashboard',
      h1: 'Set up a sing-box proxy environment with one command',
      lead: 'enana sets up a sing-box proxy environment on macOS / Windows with a single command (rule sets, auto-start, system proxy and the enana command included). After that, everything is configured in a local dashboard in your browser: import subscriptions and share links, route per app and per site, test DNS, and deploy your own server over SSH. Your servers, subscriptions, rules and traffic stay on your own computer.',
      'inst.h': 'Install enana',
      'os.unix': 'macOS (Terminal)',
      'os.win': 'Windows (64-bit PowerShell) · preview',
      'alt.wget': 'No curl? Use wget:',
      'alt.cmd': 'In Command Prompt (cmd):',
      copy: 'Copy',
      copied: 'Copied',
      'copy.ok': 'Command copied. Paste it into your terminal and press Enter.',
      'copy.fail': 'Could not copy automatically. Please select the command above and copy it.',
      'inst.hint': 'Run it in any terminal to install.',
      'latest.a': 'It always installs the latest enana release: the script first reads',
      'latest.b': ' to learn the latest version and its checksum.',
      'dash.a': 'When it finishes, the local dashboard opens at',
      'dash.b': ' (a free port is picked automatically if the default is taken, and the final address is printed). Register or sign in there with an enana account to get started.',
      'feat.h': 'Features',
      'f1.t': 'One-command install with automatic checks',
      'f1.d': 'The installer detects your OS version, chip, admin rights and network, fills in what is missing, picks a free port automatically if one is taken, verifies every download with SHA-256, and is safe to run again.',
      'f2.t': 'A local browser dashboard',
      'f2.d': 'The local dashboard opens automatically after installation, in Chinese or English, and works on narrow screens too. Every change is confirmed before it applies, and a bad configuration is rolled back automatically.',
      'f3.t': 'Per-app and per-site routing',
      'f3.d': 'Choose for each app and site: follow the rules, a fixed exit, an automatic route, or direct. System Proxy captures proxy-aware connections; optional administrator-authorized Enhanced/TUN captures other public TCP/UDP, keeping local callbacks and LAN direct. Keep AI and account services on a fixed exit to avoid risk checks caused by IP changes, send sites like Google and YouTube through the automatic route, and keep local sites direct.',
      'f4.t': 'Import subscriptions, share links and Clash configs',
      'f4.d': 'Paste a subscription URL, trojan / hysteria2 / tuic / vless / vmess / ss share links, or a Clash / sing-box config. The format is detected automatically and previewed before anything is imported.',
      'f5.t': 'Deploy your own server over SSH',
      'f5.d': 'Enter an IP and a password or key to install a VLESS + Reality node on a Debian / Ubuntu server, detect every egress IP and verify it from your computer. SSH passwords and keys are used only for the task and are never stored.',
      'f6.t': 'DNS, speed tests and traffic statistics',
      'f6.d': 'DoH / DoT presets and custom records, DNS benchmarking and leak protection, 100 built-in speed-test targets you can edit, and traffic statistics by route and node, all kept on your computer.',
      'f7.t': 'Privacy and security',
      'f7.d': 'Your servers, subscriptions and traffic stay on your computer. Optional cloud sync is end-to-end encrypted on your machine, so enana.cc only sees ciphertext, and sensitive actions ask for your password again.',
      'how.h': 'Get started in three steps',
      how1: 'Run the install command above in a terminal and wait for it to set up the environment and open the dashboard.',
      how2: 'Register or sign in with an enana account in the dashboard (just an email and a password).',
      how3: 'Add or import servers, choose Auto or Global mode, and turn the proxy switch on.',
      'faq.h': 'FAQ',
      q1: 'What is enana?',
      a1: 'enana is a one-command installer for a sing-box based proxy environment, plus a local browser dashboard. The terminal only installs the environment; servers, subscriptions, per-app and per-site routing, DNS and speed tests are all managed in the dashboard.',
      q2: 'Which systems are supported?',
      a2: 'macOS (Apple silicon and Intel) is supported; Windows 10 2004+ / Windows 11 (x64 and ARM64) is a preview. Both use the same dashboard with System Proxy and optional Enhanced/TUN. Windows TUN and native-app login still require on-device acceptance.',
      q3: 'How do I install and upgrade?',
      a3: 'Run the one-line command above in a terminal. To upgrade, run it again or type enana self-update. If curl is missing, use the wget command.',
      q4: 'Are my servers and subscriptions uploaded?',
      a4: 'No. They stay on your computer. If you turn on cloud sync, the data is end-to-end encrypted locally before it is uploaded, so enana.cc only stores ciphertext and cannot see server addresses or passwords.',
      q5: 'How is it different from using sing-box or Clash directly?',
      a5: 'enana installs and manages sing-box for you, so there is no hand-written config: importing subscriptions, per-app and per-site routing, DNS and speed tests all happen in a graphical dashboard, and every change is validated before it is applied and rolled back if it fails.',
      q6: 'How do I uninstall it?',
      a6: 'Type enana uninstall in a terminal (add --keep-data to keep your data).'
    }
  }

  var LANG_KEY = 'enana.lang'
  var statusTimer = null

  // localStorage 在隐私模式 / 被禁用时会抛异常: 读写都包起来, 页面不依赖它也能正常工作
  function store(key, value) {
    try {
      if (value === undefined) return window.localStorage.getItem(key)
      window.localStorage.setItem(key, value)
    } catch (e) { /* 忽略 */ }
    return null
  }

  function all(sel) { return Array.prototype.slice.call(document.querySelectorAll(sel)) }

  function pickLang() {
    var saved = store(LANG_KEY)
    if (saved === 'zh' || saved === 'en') return saved
    return /^zh/i.test(navigator.language || '') ? 'zh' : 'en'
  }

  function setLang(lang) {
    var d = DICT[lang]
    document.documentElement.lang = lang === 'zh' ? 'zh-CN' : 'en'
    all('[data-i18n]').forEach(function (el) {
      var v = d[el.getAttribute('data-i18n')]
      if (v !== undefined) el.textContent = v
    })
    all('[data-i18n-aria]').forEach(function (el) {
      var v = d[el.getAttribute('data-i18n-aria')]
      if (v !== undefined) el.setAttribute('aria-label', v)
    })
    document.title = d.title
    var meta = document.querySelector('meta[name="description"]')
    if (meta) meta.setAttribute('content', d.desc)
    all('[data-lang]').forEach(function (b) { b.setAttribute('aria-pressed', String(b.getAttribute('data-lang') === lang)) })
    var status = document.getElementById('copy-status')
    if (status) status.textContent = ''
    store(LANG_KEY, lang)
  }

  function currentLang() { return document.documentElement.lang === 'en' ? 'en' : 'zh' }

  // ---- 按访问者的系统先显示对应的命令 (另一个用小开关切换) ----
  function detectOS() {
    var plat = (navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || ''
    var ua = navigator.userAgent || ''
    return (/win/i.test(plat) || /windows/i.test(ua)) ? 'win' : 'unix'
  }

  function showOS(os) {
    var manifest = document.getElementById('release-manifest')
    if (manifest) manifest.textContent = 'https://install.enana.cc/dl/' + (os === 'win' ? 'windows-manifest.json' : 'manifest.json')
    all('[data-cmd]').forEach(function (el) { el.hidden = el.getAttribute('data-cmd') !== os })
    all('[data-os]').forEach(function (b) { b.setAttribute('aria-pressed', String(b.getAttribute('data-os') === os)) })
    var status = document.getElementById('copy-status')
    if (status) status.textContent = ''
  }

  // ---- 复制: 优先 navigator.clipboard, 不行就用隐藏文本框 + execCommand ----
  function legacyCopy(text) {
    var ta = document.createElement('textarea')
    ta.value = text
    ta.className = 'copy-buf'
    ta.setAttribute('readonly', '')
    document.body.appendChild(ta)
    ta.select()
    var ok = false
    try { ok = document.execCommand('copy') } catch (e) { ok = false }
    document.body.removeChild(ta)
    return ok
  }

  function copyText(text) {
    return new Promise(function (resolve, reject) {
      if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(text).then(resolve, function () { legacyCopy(text) ? resolve() : reject() })
      } else {
        legacyCopy(text) ? resolve() : reject()
      }
    })
  }

  function selectNode(node) {
    var sel = window.getSelection && window.getSelection()
    if (!sel) return
    var r = document.createRange()
    r.selectNodeContents(node)
    sel.removeAllRanges()
    sel.addRange(r)
  }

  function flash(btn, ok, codeEl) {
    var d = DICT[currentLang()]
    var status = document.getElementById('copy-status')
    if (status) {
      status.textContent = ok ? d['copy.ok'] : d['copy.fail']
      status.className = ok ? 'status' : 'status bad'
    }
    if (ok) {
      btn.textContent = d.copied
      clearTimeout(statusTimer)
      statusTimer = setTimeout(function () {
        btn.textContent = DICT[currentLang()].copy
        if (status) { status.textContent = ''; status.className = 'status' }
      }, 2200)
    } else if (codeEl) {
      selectNode(codeEl)
    }
  }

  function init() {
    setLang(pickLang())
    all('[data-lang]').forEach(function (b) {
      b.addEventListener('click', function () { setLang(b.getAttribute('data-lang')) })
    })

    var sw = document.getElementById('os-switch')
    if (sw) sw.hidden = false                       // 没有 JS 时两个命令都显示、开关不显示
    showOS(detectOS())
    all('[data-os]').forEach(function (b) {
      b.addEventListener('click', function () { showOS(b.getAttribute('data-os')) })
    })

    all('[data-copy]').forEach(function (btn) {
      btn.addEventListener('click', function () {
        var codeEl = document.getElementById(btn.getAttribute('data-copy'))
        if (!codeEl) return
        copyText(codeEl.textContent.trim()).then(
          function () { flash(btn, true, codeEl) },
          function () { flash(btn, false, codeEl) })
      })
    })
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init)
  else init()
})()
