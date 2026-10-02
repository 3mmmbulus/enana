#!/usr/bin/env python3
"""生成 ui/icons.js 与 THIRD_PARTY_NOTICES.md (图标来自 Lucide, ISC 许可证, 允许商用)。

用法:  python3 tools/make-icons.py                 # 从 GitHub 下载 SVG (需要网络)
       python3 tools/make-icons.py --from DIR      # 使用本地已下载的 SVG 目录 (含 LICENSE)
       python3 tools/make-icons.py --offline       # 没有网络: 沿用 ui/icons.js 里已有的形状, 新增的图标用下面的 LOCAL (不改许可证文件)
想换/加图标: 改下面的 NAMES / ALIAS 后重新运行。仪表盘只通过「别名」引用图标。
"""
import glob, json, os, sys, urllib.request
import xml.etree.ElementTree as ET

BASE = 'https://raw.githubusercontent.com/lucide-icons/lucide/main'
NAMES = """layout-dashboard app-window globe library network server activity scroll-text settings panel-left-close
panel-left-open refresh-cw power download upload trash plus check x search copy external-link eye eye-off play pause unplug zap
gauge shield-check shield-alert lock key-round log-out user info triangle-alert circle-check circle-x bell sun moon clock funnel
sliders-horizontal file-down link cloud-download circle-arrow-up sparkles bot rocket wifi wifi-off plug database hard-drive terminal
list-checks badge-check route menu chevron-down chevron-up chevron-right chevron-left ellipsis pencil save shuffle book-open
circle-question-mark square-pen monitor message-square-warning toggle-right toggle-left rotate-ccw arrow-right waypoints scan-search
ban brush-cleaning folder-open file-text
shield shield-x square minus mail map-pin chart-bar chart-column circle-alert crown inbox chevrons-left chevrons-right""".split()
ALIAS = {
  'nav-overview': 'layout-dashboard', 'nav-apps': 'app-window', 'nav-sites': 'globe', 'nav-rules': 'library', 'nav-dns': 'network',
  'nav-servers': 'server', 'nav-connections': 'activity', 'nav-logs': 'scroll-text', 'nav-settings': 'settings',
  'collapse': 'panel-left-close', 'expand': 'panel-left-open', 'history': 'clock', 'delete': 'trash', 'filter': 'funnel', 'help': 'circle-question-mark',
  'speed': 'zap', 'disconnect': 'unplug', 'restart': 'rotate-ccw', 'refresh': 'refresh-cw', 'update': 'circle-arrow-up', 'download-cloud': 'cloud-download',
  'success': 'circle-check', 'error': 'circle-x', 'warning': 'triangle-alert', 'secure': 'shield-check', 'risk': 'shield-alert', 'password': 'key-round', 'logout': 'log-out',
  'ai': 'sparkles', 'pin': 'shield-check', 'auto': 'shuffle', 'direct': 'route', 'more': 'ellipsis', 'edit': 'pencil', 'dark': 'moon', 'light': 'sun',
  'nav-speed': 'gauge', 'nav-traffic': 'chart-bar', 'help-i': 'circle-alert', 'pro': 'crown', 'stop': 'square', 'skip': 'minus', 'email': 'mail', 'location': 'map-pin', 'account': 'user', 'unbind': 'unplug',
  'ip-normal': 'shield-check', 'ip-limited': 'shield-alert', 'ip-blocked': 'shield-x', 'ip-unknown': 'shield',
}
# 离线备用: 上面新增图标的形状 (按 Lucide 的几何数据抄录, ISC 许可证)。有网络时一律以官方 SVG 为准, 这里只在 --offline 时使用。
_OUTLINE = 'M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z'
LOCAL = {
  'shield': [['path', {'d': _OUTLINE}]],
  'shield-x': [['path', {'d': _OUTLINE}], ['path', {'d': 'm14.5 9.5-5 5'}], ['path', {'d': 'm9.5 9.5 5 5'}]],
  'square': [['rect', {'width': '18', 'height': '18', 'x': '3', 'y': '3', 'rx': '2'}]],
  'minus': [['path', {'d': 'M5 12h14'}]],
  'mail': [['path', {'d': 'm22 7-8.991 5.727a2 2 0 0 1-2.009 0L2 7'}], ['rect', {'x': '2', 'y': '4', 'width': '20', 'height': '16', 'rx': '2'}]],
  'chevrons-left': [['path', {'d': 'm11 17-5-5 5-5'}], ['path', {'d': 'm18 17-5-5 5-5'}]],
  'chevrons-right': [['path', {'d': 'm6 17 5-5-5-5'}], ['path', {'d': 'm13 17 5-5-5-5'}]],
  'circle-alert': [['circle', {'cx': '12', 'cy': '12', 'r': '10'}], ['path', {'d': 'M12 8v4'}], ['path', {'d': 'M12 16h.01'}]],
  'crown': [['path', {'d': 'M11.562 3.266a.5.5 0 0 1 .876 0L15.39 8.87a1 1 0 0 0 1.516.294L21.183 5.5a.5.5 0 0 1 .798.519l-2.834 10.246a1 1 0 0 1-.956.734H5.81a1 1 0 0 1-.957-.734L2.02 6.02a.5.5 0 0 1 .798-.519l4.276 3.664a1 1 0 0 0 1.516-.294z'}], ['path', {'d': 'M5 21h14'}]],
  'inbox': [['path', {'d': 'M22 12h-6l-2 3h-4l-2-3H2'}], ['path', {'d': 'M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z'}]],
  'chart-bar': [['path', {'d': 'M3 3v16a2 2 0 0 0 2 2h16'}], ['path', {'d': 'M7 16h8'}], ['path', {'d': 'M7 11h12'}], ['path', {'d': 'M7 6h3'}]],
  'chart-column': [['path', {'d': 'M3 3v16a2 2 0 0 0 2 2h16'}], ['path', {'d': 'M18 17V9'}], ['path', {'d': 'M13 17V5'}], ['path', {'d': 'M8 17v-3'}]],
  'map-pin': [['path', {'d': 'M20 10c0 4.993-5.539 10.193-7.399 11.799a1 1 0 0 1-1.202 0C9.539 20.193 4 14.993 4 10a8 8 0 0 1 16 0'}], ['circle', {'cx': '12', 'cy': '10', 'r': '3'}]],
}
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def get(name, src):
    if src:
        return open(os.path.join(src, name), 'rb').read()
    return urllib.request.urlopen(f'{BASE}/{name}', timeout=30).read()

def existing():
    """读取 ui/icons.js 里已有的形状 (离线模式用)"""
    s = open(os.path.join(ROOT, 'ui', 'icons.js'), encoding='utf-8').read()
    i = s.index('var SHAPES = ') + len('var SHAPES = ')
    return json.loads(s[i:s.index(';\n', i)])

def main():
    src = sys.argv[sys.argv.index('--from') + 1] if '--from' in sys.argv else None
    offline = '--offline' in sys.argv
    old = existing() if offline else {}
    icons = {}
    for n in NAMES:
        if offline:
            if n in old: icons[n] = old[n]
            elif n in LOCAL: icons[n] = LOCAL[n]
            else: sys.exit(f'offline: no local shape for {n}')
            continue
        root = ET.fromstring(get(src and f'{n}.svg' or f'icons/{n}.svg', src))
        shapes = []
        for ch in root:
            tag = ch.tag.split('}')[-1]
            if tag not in ('path', 'rect', 'circle', 'line', 'ellipse', 'polyline', 'polygon'):
                sys.exit(f'unexpected <{tag}> in {n}')           # 只接受纯形状, 拒绝脚本/外链
            shapes.append([tag, dict(ch.attrib)])
        icons[n] = shapes
    for k, v in ALIAS.items():
        if v not in icons: sys.exit(f'alias target missing: {k} -> {v}')
    template = open(os.path.join(ROOT, 'tools', 'icons.js.tpl'), encoding='utf-8').read()
    out = template.replace('__SHAPES__', json.dumps(icons, ensure_ascii=False, separators=(',', ':'))).replace('__ALIAS__', json.dumps(ALIAS, ensure_ascii=False, separators=(',', ':')))
    open(os.path.join(ROOT, 'ui', 'icons.js'), 'w', encoding='utf-8').write(out)
    if offline:
        print(f'icons.js: {len(icons)} icons, {len(ALIAS)} aliases (offline; THIRD_PARTY_NOTICES.md unchanged)')
        return
    lic = get('LICENSE', src).decode('utf-8').rstrip()
    notice = ('# 第三方声明 (Third-party notices)\n\n## 图标 — Lucide\n\n'
              '仪表盘使用的图标来自 [Lucide](https://lucide.dev) (<https://github.com/lucide-icons/lucide>),\n'
              '采用 **ISC 许可证**,允许个人与**商业**使用、复制、修改与分发,只要求在副本中保留下面的版权与许可声明。\n'
              '其中部分图标源自 Feather 项目 (MIT 许可证),其声明也包含在下面。\n\n'
              '`ui/icons.js` 只包含这些图标的形状数据 (SVG 路径),由 `tools/make-icons.py` 生成。\n\n```\n' + lic + '\n```\n')
    open(os.path.join(ROOT, 'THIRD_PARTY_NOTICES.md'), 'w', encoding='utf-8').write(notice)
    print(f'icons.js: {len(icons)} icons, {len(ALIAS)} aliases; THIRD_PARTY_NOTICES.md written')

main()
