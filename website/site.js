/* enana.cc 首页脚本: 中英文切换、按访问者的系统先显示对应的安装命令、复制按钮。
 * 不发任何网络请求; 文字只通过 textContent / setAttribute 写进页面 (从不把字符串当 HTML 解析)。
 * DICT.zh 必须和 index.html 里的静态中文逐字一致 (tests/website-check.py 会检查)。 */
(function () {
  'use strict'

  var DICT = {
    zh: {
      title: 'enana：AI 与开发者网络加速（macOS/Windows）',
      desc: 'enana 是 AI 与开发者的网络加速工具（macOS / Windows）：按应用和网站设置规则，监测连接质量，加密同步多台设备，一键部署自己的服务器。',
      skip: '跳到主要内容',
      'nav.label': '主导航',
      'nav.features': '功能',
      'nav.pricing': '价格',
      'nav.install': '安装',
      'nav.faq': '常见问题',
      'lang.label': '语言',
      'cta.install': '免费安装',
      'cta.features': '了解功能',
      eyebrow: 'macOS · Windows 桌面网络管理工具',
      h1: 'AI 与开发者的网络加速工具',
      lead: '按应用、按网站设置联网规则，实时查看连接质量，让 AI 服务和开发工具保持稳定、快速。',
      'chip.local': '本机运行',
      'chip.sync': '加密同步',
      'hero.art': 'enana 本机控制台示意图：应用规则、连接质量曲线和同步状态',
      'feat.h': '主要功能',
      'feat.lead': '一条命令安装，之后所有设置都在本机浏览器控制台里完成。',
      'f1.t': '按应用、按网站的规则',
      'f1.d': '为每个应用和网站选择直连、自动选择最快线路，或固定使用指定线路；自动选择只在明显更快时才切换，不会来回跳动。',
      'f2.t': '本机控制台',
      'f2.d': '安装后自动在浏览器中打开，中英文界面，手机和窄屏也能用；每次修改先校验再生效，出错自动回滚。',
      'f3.t': '连接质量监测',
      'f3.d': '实时速度与延迟、100 个内置测速目标、DNS 测速，以及最近 3 个月的流量统计；这些记录只保存在本机。',
      'f4.t': '多设备加密同步',
      'f4.d': '规则、服务器和偏好在本机端到端加密后再同步，enana.cc 只保存密文；在另一台电脑登录同一账号即可取回。',
      'f5.t': '一键部署自己的服务器',
      'f5.d': '填入 Debian 或 Ubuntu 服务器的地址和 SSH 登录方式，自动安装并在本机验证后加入列表；密码和私钥只在任务期间使用，不会保存。',
      'f6.t': '安全与隐私',
      'f6.d': '本机服务只接受本机访问；安装包和云端下发的内容都经过签名或哈希校验；删除服务器、查看凭据等敏感操作需要再次输入密码。',
      'who.h': '适合谁',
      'who1.t': 'AI 用户',
      'who1.d': '让常用的 AI 对话、写作和编程助手保持稳定连接，也可以让它们固定使用同一条线路。',
      'who2.t': '开发者',
      'who2.d': '代码托管、软件包与容器镜像下载、API 调用各自按规则选择线路；终端里的命令行工具也能使用同一套规则。',
      'who3.t': '远程团队',
      'who3.d': '每位成员在自己的电脑上安装，可以连接团队自己部署的服务器，异地开会和协作更顺畅。',
      'price.h': '价格',
      'price.lead': '核心功能免费使用；需要官方加速线路和更多设备时，再升级专业版。',
      'free.name': '免费版',
      'free.price': '免费',
      'free.sub': '安装即可使用全部核心功能',
      'free.l1': '按应用、按网站的规则',
      'free.l2': '本机控制台与连接质量监测',
      'free.l3': '多设备加密同步',
      'free.l4': '一键部署自己的服务器',
      'free.l5': '每个平台 2 台设备同时在线',
      'pro.name': '专业版',
      'pro.price': '4 USDT / 月起',
      'pro.sub': '12 个月 35 USDT，约 2.92 USDT / 月',
      'pro.l1': '包含免费版全部功能',
      'pro.l2': '官方加速线路',
      'pro.l3': '更多设备同时在线',
      'pro.l4': '可选：用余额按月自动续费',
      'pro.terms': '另有 3 个月、6 个月和 2 年、3 年、5 年可选，使用 USDT（TRC20）付款。',
      'pro.note': '安装后在本机控制台「设置 → 会员」开通，具体权益以控制台显示为准。',
      'pro.cta': '安装后开通',
      'how.h': '如何开始',
      'how1.t': '复制安装命令',
      'how1.d': '在「安装」一节选择你的系统，复制一行命令，粘贴到终端运行。',
      'how2.t': '打开本机控制台',
      'how2.d': '安装完成后控制台会自动在浏览器中打开，不注册也能直接使用；需要多设备同步或专业版时，再用邮箱注册或登录 enana 账号。',
      'how3.t': '设置规则，开始使用',
      'how3.d': '添加或导入自己的服务器，或开通专业版；为常用的应用和网站选好规则，打开总开关。',
      'inst.h': '安装 enana',
      'os.label': '选择系统',
      'os.unix': 'macOS · 在「终端」中运行',
      'os.win': 'Windows 10 / 11 · 在 64 位 PowerShell 中运行（预览版）',
      'alt.wget': '没有 curl？用 wget：',
      'alt.cmd': '在命令提示符（cmd）中运行：',
      copy: '复制',
      copied: '已复制',
      'copy.ok': '命令已复制，粘贴到终端里按回车即可。',
      'copy.fail': '没能自动复制，请选中上面的命令手动复制。',
      'inst.hint': '安装完成后，本机控制台会自动在浏览器中打开。重复运行安装命令是安全的，已装好的部分会自动跳过。',
      'latest.a': '每次都安装最新版本：安装脚本会先读取',
      'latest.b': '，核对版本号和校验值。',
      'inst.old': '如果你安装的是 2.3.16 之前的版本，请重新运行一次安装命令，之后的升级才会校验签名。',
      'faq.h': '常见问题',
      q1: 'enana 是什么？',
      a1: 'enana 是运行在 macOS 和 Windows 上的桌面网络管理工具：一条命令安装，之后在本机浏览器控制台里为应用和网站设置规则、查看连接质量，让 AI 服务和开发工具保持稳定、快速。',
      q2: '支持哪些系统？',
      a2: 'macOS（Apple 芯片和 Intel），以及 Windows 10 2004 及以上版本和 Windows 11（x64、ARM64）；Windows 版目前为预览版。两个系统使用同一个控制台。',
      q3: '怎么安装和升级？',
      a3: '在「安装」一节复制对应系统的命令，粘贴到终端运行即可。升级时再运行一遍安装命令，或在终端输入 enana self-update。',
      q4: '免费版和专业版有什么区别？',
      a4: '免费版包含联网规则、本机控制台、连接质量监测、加密同步和一键部署自己的服务器。专业版在此基础上提供官方加速线路和更多同时在线设备，4 USDT / 月起，安装后在本机控制台开通。',
      q5: '我的数据会上传吗？',
      a5: '流量记录和连接日志只保存在你的电脑上。服务器和规则在同步前会先在本机端到端加密，enana.cc 只保存密文，看不到服务器地址和密码；SSH 登录密码和私钥从不同步，同步也可以在设置里关闭。',
      q6: '怎么卸载？',
      a6: '在终端输入 enana uninstall。卸载会删除全部本机数据，需要保留的内容请先在控制台导出备份。',
      'foot.tag': 'AI 与开发者的网络加速工具',
      'foot.nav': '页脚导航'
    },
    en: {
      title: 'enana · Network acceleration for AI and developers',
      desc: 'enana: network acceleration for AI and developers on macOS and Windows, with per-app and per-site rules, connection monitoring and encrypted sync.',
      skip: 'Skip to main content',
      'nav.label': 'Main navigation',
      'nav.features': 'Features',
      'nav.pricing': 'Pricing',
      'nav.install': 'Install',
      'nav.faq': 'FAQ',
      'lang.label': 'Language',
      'cta.install': 'Install free',
      'cta.features': 'See features',
      eyebrow: 'Desktop network manager for macOS and Windows',
      h1: 'Network acceleration for AI and developers',
      lead: 'Set network rules per app and per site, watch connection quality live, and keep AI services and developer tools fast and stable.',
      'chip.local': 'Runs locally',
      'chip.sync': 'Encrypted sync',
      'hero.art': 'Illustration of the enana local dashboard: app rules, a connection-quality chart and sync status',
      'feat.h': 'Features',
      'feat.lead': 'Install with one command, then set everything up in a local dashboard in your browser.',
      'f1.t': 'Per-app and per-site rules',
      'f1.d': 'Choose direct, the fastest line or a fixed line for each app and site. The automatic choice only switches when another line is clearly faster, so it does not jump back and forth.',
      'f2.t': 'A local dashboard',
      'f2.d': 'Opens in your browser after installation, in Chinese or English, and works on phones and narrow screens. Every change is validated first and rolled back automatically if it fails.',
      'f3.t': 'Connection quality monitoring',
      'f3.d': 'Live speed and latency, 100 built-in speed-test targets, DNS speed tests and up to three months of traffic statistics, all kept on your computer.',
      'f4.t': 'Encrypted multi-device sync',
      'f4.d': 'Rules, servers and preferences are end-to-end encrypted on your computer before they sync, so enana.cc only stores ciphertext. Sign in on another computer to get them back.',
      'f5.t': 'Deploy your own server in one click',
      'f5.d': 'Enter the address and SSH login of a Debian or Ubuntu server: enana installs everything, verifies it from your computer and adds it to your list. Passwords and keys are used only for the task and never stored.',
      'f6.t': 'Security and privacy',
      'f6.d': 'The local service only accepts requests from your own computer, installers and cloud content are checked by signature or checksum, and sensitive actions ask for your password again.',
      'who.h': 'Who it is for',
      'who1.t': 'AI users',
      'who1.d': 'Keep the AI chat, writing and coding assistants you rely on connected, and keep them on the same line if you like.',
      'who2.t': 'Developers',
      'who2.d': 'Code hosting, package and container image downloads and API calls each follow your rules, and command-line tools in the terminal can use the same rules.',
      'who3.t': 'Remote teams',
      'who3.d': 'Each member installs enana on their own computer and can connect to servers the team deploys itself, for smoother meetings and collaboration across locations.',
      'price.h': 'Pricing',
      'price.lead': 'The core features are free. Upgrade to Pro when you want the official acceleration lines and more devices.',
      'free.name': 'Free plan',
      'free.price': 'Free',
      'free.sub': 'All core features as soon as you install',
      'free.l1': 'Per-app and per-site rules',
      'free.l2': 'Local dashboard and connection monitoring',
      'free.l3': 'Encrypted multi-device sync',
      'free.l4': 'Deploy your own server in one click',
      'free.l5': 'Two devices online per platform',
      'pro.name': 'Pro',
      'pro.price': 'From 4 USDT / month',
      'pro.sub': '35 USDT for 12 months, about 2.92 USDT / month',
      'pro.l1': 'Everything in the free plan',
      'pro.l2': 'Official acceleration lines',
      'pro.l3': 'More devices online at once',
      'pro.l4': 'Optional: monthly auto-renewal from your balance',
      'pro.terms': 'Also available for 3 or 6 months and 2, 3 or 5 years, paid in USDT (TRC20).',
      'pro.note': 'Activate it after installation in the local dashboard under Settings → Plan. The dashboard shows exactly what your plan includes.',
      'pro.cta': 'Install, then upgrade',
      'how.h': 'How to get started',
      'how1.t': 'Copy the install command',
      'how1.d': 'Pick your system in the Install section, copy the one-line command and run it in a terminal.',
      'how2.t': 'Open the local dashboard',
      'how2.d': 'When installation finishes, the dashboard opens in your browser and works right away, no account needed. Register or sign in with your email only when you want sync across devices or Pro.',
      'how3.t': 'Set your rules and go',
      'how3.d': 'Add or import your own server, or upgrade to Pro. Choose rules for the apps and sites you use and turn on the main switch.',
      'inst.h': 'Install enana',
      'os.label': 'Choose your system',
      'os.unix': 'macOS · run in Terminal',
      'os.win': 'Windows 10 / 11 · run in 64-bit PowerShell (preview)',
      'alt.wget': 'No curl? Use wget:',
      'alt.cmd': 'In Command Prompt (cmd):',
      copy: 'Copy',
      copied: 'Copied',
      'copy.ok': 'Command copied. Paste it into your terminal and press Enter.',
      'copy.fail': 'Could not copy automatically. Please select the command above and copy it.',
      'inst.hint': 'When installation finishes, the local dashboard opens in your browser. Running the command again is safe: finished steps are skipped.',
      'latest.a': 'It always installs the latest release: the script first reads',
      'latest.b': ' and checks the version and checksums.',
      'inst.old': 'If you installed a version before 2.3.16, run the install command once more so that later upgrades verify signatures.',
      'faq.h': 'FAQ',
      q1: 'What is enana?',
      a1: 'enana is a desktop network manager for macOS and Windows. Install it with one command, then use the local dashboard in your browser to set rules for apps and sites and watch connection quality, so AI services and developer tools stay fast and stable.',
      q2: 'Which systems are supported?',
      a2: 'macOS on Apple silicon and Intel, plus Windows 10 2004 or later and Windows 11 on x64 and ARM64. The Windows version is a preview. Both use the same dashboard.',
      q3: 'How do I install and upgrade?',
      a3: 'Copy the command for your system in the Install section and run it in a terminal. To upgrade, run the install command again or type enana self-update.',
      q4: 'What is the difference between Free and Pro?',
      a4: 'The free plan includes the rules, the local dashboard, connection monitoring, encrypted sync and deploying your own server. Pro adds the official acceleration lines and more devices online at once, from 4 USDT per month, activated in the local dashboard after installation.',
      q5: 'Is my data uploaded?',
      a5: 'Traffic records and connection logs stay on your computer. Servers and rules are end-to-end encrypted on your computer before they sync, so enana.cc only stores ciphertext and cannot see server addresses or passwords. SSH passwords and private keys are never synced, and you can turn sync off in Settings.',
      q6: 'How do I uninstall it?',
      a6: 'Type enana uninstall in a terminal. Uninstalling removes all local data, so export a backup from the dashboard first if you want to keep anything.',
      'foot.tag': 'Network acceleration for AI and developers',
      'foot.nav': 'Footer'
    }
  }

  var LANG_KEY = 'enana.lang'
  var statusTimer = null
  var copyTimers = {}       // 每个复制按钮各自的「已复制 -> 复制」计时 (按 data-copy 区分): 几个按钮先后点, 每个都会恢复

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
    var key = btn.getAttribute('data-copy')
    clearTimeout(copyTimers[key])
    delete copyTimers[key]
    clearTimeout(statusTimer)               // 状态行只跟最近一次复制计时: 之前那次的计时不会提前抹掉新的结果 (包括复制失败的提示)
    statusTimer = null
    if (ok) {
      btn.textContent = d.copied
      copyTimers[key] = setTimeout(function () {
        delete copyTimers[key]
        btn.textContent = DICT[currentLang()].copy
      }, 2200)
      statusTimer = setTimeout(function () {
        statusTimer = null
        if (status) { status.textContent = ''; status.className = 'status' }
      }, 2200)
    } else {
      btn.textContent = d.copy                // 这次没复制成功: 不要还显示上一次的「已复制」
      if (codeEl) selectNode(codeEl)
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
