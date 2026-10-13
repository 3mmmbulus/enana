"""Static checks for the public website (website/, served at https://enana.cc). Reads files only: no network, no browser.

Covers the wording the site must never use, the hooks site.js and the deploy scripts depend on, the four install
commands byte for byte, SEO metadata and JSON-LD (FAQPage = the visible FAQ), and markup that stays inside the site's
CSP (no inline styles or handlers, no external assets). tools/deploy-website.sh repeats the essential checks on the
host before it publishes anything."""
import datetime
import html.parser
import json
import pathlib
import re
import unittest
import xml.etree.ElementTree as ET

repo = pathlib.Path(__file__).resolve().parents[1]
site = repo / 'website'

# Every file tools/deploy-website.sh publishes. nginx serves / and a fixed list of static names, so no new paths.
PUBLISHED = ['index.html', 'site.css', 'site.js', 'robots.txt', 'sitemap.xml', 'favicon.svg', '404.html']
COMMANDS = {
    'cmd-unix': 'curl -fsSL https://install.enana.cc | bash',
    'cmd-unix2': 'wget -qO- https://install.enana.cc | bash',
    'cmd-win': 'irm https://install.enana.cc/get.ps1 | iex',
    'cmd-win2': 'powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://install.enana.cc/get.ps1 | iex"',
}
# Never on the public site, in either language: visible copy, metadata, JSON-LD, alt text and scripts alike.
# The exact PowerShell install command is the only exception ("Bypass" is part of it).
A = r'(?<![a-z0-9])'   # ASCII word edges (\b would treat CJK as word characters)
Z = r'(?![a-z0-9])'
FORBIDDEN = [
    r'vpn', r'翻墙', r'墙', r'科学上网', r'梯子', r'机场', r'代理', r'prox(?:y|ies)', r'sing[\s-]?box', r'clash',
    r'v2ray', A + r'xray' + Z, r'vless', r'reality', r'trojan', r'vmess', r'shadowsocks', A + r'ssr?' + Z,
    r'hysteria', A + r'tuic' + Z, r'wireguard', A + r'socks5?' + Z, r'订阅', r'subscription', r'节点', r'出口',
    r'egress', r'exit ip', r'风控', r'封锁', r'blocked', r'unblock', r'censor', r'gfw', r'防火墙', r'firewall',
    r'circumvent', r'bypass', r'tunnel', r'分流', r'国内', r'国外', r'海外', r'境外', r'外网', r'domestic',
    r'overseas', r'abroad', r'foreign', r'google', r'youtube',
]
JS_ONLY_KEYS = {'title', 'desc', 'copied', 'copy.ok', 'copy.fail'}   # read by site.js, not by a data-i18n element
GITHUB = 'https://github.com/3mmmbulus/enana'
LOCAL_ASSETS = {'/site.css', '/site.js', '/favicon.svg'}
VOID = {'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'source', 'track', 'wbr'}
CJK = re.compile(r'[　-〿㐀-鿿＀-￯]')


def read(name):
    return (site / name).read_text(encoding='utf-8')


class Node:
    def __init__(self, tag, attrs, parent):
        self.tag, self.attrs, self.parent, self.children = tag, dict(attrs), parent, []

    def walk(self):
        yield self
        for c in self.children:
            if isinstance(c, Node):
                yield from c.walk()

    def kids(self):
        return [c for c in self.children if isinstance(c, Node)]

    def text(self):
        return ''.join(c if isinstance(c, str) else c.text() for c in self.children)


class Page(html.parser.HTMLParser):
    """A small DOM: enough to compare text, attributes and structure exactly."""

    def __init__(self, source):
        super().__init__(convert_charrefs=True)
        self.root = self.cur = Node('#document', [], None)
        self.problems = []
        self.feed(source)
        self.close()
        if self.cur is not self.root:
            self.problems.append('unclosed <%s>' % self.cur.tag)

    def handle_starttag(self, tag, attrs):
        node = Node(tag, attrs, self.cur)
        self.cur.children.append(node)
        if tag not in VOID:
            self.cur = node

    def handle_startendtag(self, tag, attrs):
        self.cur.children.append(Node(tag, attrs, self.cur))

    def handle_endtag(self, tag):
        if tag in VOID:
            return
        if self.cur.tag != tag:
            self.problems.append('</%s> closes <%s>' % (tag, self.cur.tag))
            n = self.cur
            while n is not self.root and n.tag != tag:
                n = n.parent
            if n is self.root:
                return
            self.cur = n
        self.cur = self.cur.parent

    def handle_data(self, data):
        self.cur.children.append(data)

    def elements(self):
        return [n for n in self.root.walk() if n is not self.root]

    def find(self, pred):
        return [n for n in self.elements() if pred(n)]

    def tags(self, tag):
        return self.find(lambda n: n.tag == tag)


ENTRY = re.compile(r"^      (?:'([a-z0-9.]+)'|([A-Za-z][A-Za-z0-9]*)): '((?:[^'\\]|\\['\\])*)',?$")


def dictionary():
    """DICT.zh / DICT.en from site.js (one entry per line, single-quoted strings)."""
    js = read('site.js')
    out = {}
    for lang in ('zh', 'en'):
        m = re.search(r'^    %s: \{\n(.*?)\n    \},?$' % lang, js, re.S | re.M)
        if not m:
            raise AssertionError('DICT.%s not found in site.js' % lang)
        entries = {}
        for line in m.group(1).split('\n'):
            e = ENTRY.match(line)
            if not e:
                raise AssertionError('unexpected DICT.%s line: %r' % (lang, line))
            key = e.group(1) or e.group(2)
            if key in entries:
                raise AssertionError('duplicate DICT.%s key %s' % (lang, key))
            entries[key] = re.sub(r"\\(['\\])", r'\1', e.group(3))
        out[lang] = entries
    return out


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for v in value.values():
            yield from strings(v)
    elif isinstance(value, list):
        for v in value:
            yield from strings(v)


class Website(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.raw = (site / 'index.html').read_bytes()
        cls.page = Page(cls.raw.decode('utf-8'))
        cls.js = read('site.js')
        cls.css = read('site.css')
        cls.ids = {}
        for n in cls.page.find(lambda n: 'id' in n.attrs):
            cls.ids.setdefault(n.attrs['id'], []).append(n)

    def meta(self, attr, value):
        found = [n.attrs.get('content') for n in self.page.tags('meta') if n.attrs.get(attr) == value]
        self.assertEqual(len(found), 1, 'expected one <meta %s="%s">' % (attr, value))
        return found[0]

    def test_markup_is_well_formed(self):
        for name in ('index.html', '404.html'):
            self.assertEqual(Page(read(name)).problems, [], name)

    def test_published_files_match_the_deploy_script_and_nginx_allowlist(self):
        for name in PUBLISHED:
            self.assertTrue((site / name).is_file(), name)
        deploy = (repo / 'tools' / 'deploy-website.sh').read_text(encoding='utf-8')
        m = re.search(r'^files=\(([^)]*)\)$', deploy, re.M)
        self.assertIsNotNone(m, 'tools/deploy-website.sh must define files=(...)')
        self.assertEqual(m.group(1).split(), PUBLISHED)
        nginx = (repo / 'server' / 'update-nginx.py').read_text(encoding='utf-8')
        allow = re.search(r"new=r'([^']*)'", nginx).group(1)
        for name in PUBLISHED:
            if not name.endswith('.html'):          # / serves index.html; the rest must already be static routes
                self.assertIn(re.escape(name), allow, name)

    def test_no_forbidden_wording(self):
        for name in PUBLISHED:
            text = read(name).replace(COMMANDS['cmd-win2'], '')
            for pattern in FORBIDDEN:
                m = re.search(pattern, text, re.I)
                self.assertIsNone(m, '%s: forbidden wording %r in %r' % (
                    name, m and m.group(0), m and text[max(0, m.start() - 30):m.end() + 30]))

    def test_install_commands_are_byte_exact(self):
        for id_, command in COMMANDS.items():
            self.assertIn(command.encode(), self.raw, id_)
            nodes = self.ids.get(id_, [])
            self.assertEqual(len(nodes), 1, id_)
            self.assertEqual(nodes[0].tag, 'code', id_)
            self.assertEqual(nodes[0].text(), command, id_)
            buttons = self.page.find(lambda n: n.attrs.get('data-copy') == id_)
            self.assertEqual([b.tag for b in buttons], ['button'], id_)
        # tools/deploy-windows-release.sh asserts exactly these two strings
        self.assertIn(b'https://install.enana.cc/get.ps1', self.raw)
        self.assertIn(b'windows-manifest.json', (site / 'site.js').read_bytes())

    def test_hooks_used_by_site_js(self):
        for id_ in ('cmd-unix', 'cmd-unix2', 'cmd-win', 'cmd-win2', 'copy-status', 'release-manifest', 'os-switch'):
            self.assertEqual(len(self.ids.get(id_, [])), 1, id_)
        self.assertEqual([k for k, v in self.ids.items() if len(v) > 1], [], 'duplicate ids')

        def values(attr):
            return sorted(n.attrs[attr] for n in self.page.find(lambda n: attr in n.attrs))
        self.assertEqual(values('data-cmd'), ['unix', 'win'])
        self.assertEqual(values('data-os'), ['unix', 'win'])
        self.assertEqual(values('data-lang'), ['en', 'zh'])
        for n in self.page.find(lambda n: 'data-os' in n.attrs or 'data-lang' in n.attrs):
            self.assertEqual(n.tag, 'button')
            self.assertIn(n.attrs.get('aria-pressed'), ('true', 'false'))
        self.assertIn('hidden', self.ids['os-switch'][0].attrs)        # shown by site.js; without JS both commands stay
        self.assertEqual(self.ids['release-manifest'][0].text(), 'https://install.enana.cc/dl/manifest.json')
        self.assertEqual(self.ids['copy-status'][0].attrs.get('aria-live'), 'polite')
        self.meta('name', 'description')
        self.assertEqual([n.attrs['src'] for n in self.page.tags('script') if 'src' in n.attrs], ['/site.js'])
        for hook in ("getElementById('release-manifest')", "getElementById('copy-status')", "getElementById('os-switch')",
                     "'[data-cmd]'", "'[data-os]'", "'[data-copy]'", "'[data-lang]'", "'[data-i18n]'",
                     "'[data-i18n-aria]'", 'meta[name="description"]', "'copy-buf'",
                     'd.title', 'd.desc', 'd.copied', "d['copy.ok']", "d['copy.fail']"):
            self.assertIn(hook, self.js)

    def test_static_chinese_matches_the_dictionary(self):
        d = dictionary()
        zh, en = d['zh'], d['en']
        self.assertEqual(sorted(zh), sorted(en), 'DICT.zh and DICT.en must have the same keys')
        used = set()
        for n in self.page.find(lambda n: 'data-i18n' in n.attrs):
            key = n.attrs['data-i18n']
            used.add(key)
            self.assertIn(key, zh)
            self.assertEqual(n.kids(), [], '%s: setLang replaces textContent, so no child elements' % key)
            self.assertEqual(n.text(), zh[key], key)
        for n in self.page.find(lambda n: 'data-i18n-aria' in n.attrs):
            key = n.attrs['data-i18n-aria']
            used.add(key)
            self.assertIn(key, zh)
            self.assertEqual(n.attrs.get('aria-label'), zh[key], key)
        self.assertEqual(sorted(set(zh) - used), sorted(JS_ONLY_KEYS), 'unused or missing dictionary keys')
        for key in zh:
            self.assertTrue(zh[key].strip(), 'empty DICT.zh.' + key)
            self.assertTrue(en[key].strip(), 'empty DICT.en.' + key)
            self.assertIsNone(CJK.search(en[key]), 'untranslated DICT.en.' + key)
        titles = self.page.tags('title')
        self.assertEqual([t.text() for t in titles], [zh['title']])
        self.assertEqual(self.meta('name', 'description'), zh['desc'])
        self.assertEqual(self.meta('property', 'og:title'), zh['title'])
        self.assertEqual(self.meta('name', 'twitter:title'), zh['title'])
        self.assertEqual(self.meta('property', 'og:description'), zh['desc'])
        self.assertEqual(self.meta('name', 'twitter:description'), zh['desc'])

    def test_title_and_description_lengths(self):
        d = dictionary()
        zh, en = d['zh'], d['en']
        self.assertLessEqual(len(zh['title']), 32, zh['title'])
        self.assertGreaterEqual(len(zh['desc']), 70, zh['desc'])
        self.assertLessEqual(len(zh['desc']), 80, zh['desc'])
        self.assertLessEqual(len(en['title']), 60, en['title'])
        self.assertLessEqual(len(en['desc']), 155, en['desc'])
        for value in (zh['title'], zh['desc'], en['title'], en['desc']):
            self.assertIn('enana', value)

    def test_head_metadata(self):
        self.assertEqual(self.page.tags('html')[0].attrs.get('lang'), 'zh-CN')
        links = [(n.attrs.get('rel'), n.attrs.get('hreflang'), n.attrs.get('href')) for n in self.page.tags('link')]
        self.assertIn(('canonical', None, 'https://enana.cc/'), links)
        self.assertIn(('alternate', 'zh-CN', 'https://enana.cc/'), links)
        self.assertIn(('alternate', 'x-default', 'https://enana.cc/'), links)
        for n in self.page.tags('meta'):
            for attr in ('property', 'name'):
                self.assertFalse((n.attrs.get(attr) or '').startswith(('og:image', 'twitter:image')),
                                 'no og:image / twitter:image until a real image is published')
        self.assertNotIn(b'og.jpg', self.raw)
        self.assertEqual(self.meta('name', 'twitter:card'), 'summary')
        self.assertEqual(self.meta('property', 'og:url'), 'https://enana.cc/')
        self.assertTrue(self.meta('name', 'keywords').startswith('enana,'))
        self.assertTrue(self.meta('name', 'robots').startswith('index,follow'))
        self.assertIn('noindex', read('404.html'))

    def test_headings(self):
        levels = [int(n.tag[1]) for n in self.page.elements() if re.fullmatch(r'h[1-6]', n.tag)]
        self.assertEqual(levels.count(1), 1, 'exactly one h1')
        self.assertEqual(levels[0], 1, 'the h1 comes first')
        for a, b in zip(levels, levels[1:]):
            self.assertLessEqual(b - a, 1, 'heading level skipped: %s' % levels)

    def test_navigation_and_calls_to_action(self):
        nav = [n for n in self.page.tags('nav') if 'nav' in (n.attrs.get('class') or '').split()]
        self.assertEqual(len(nav), 1)
        self.assertEqual([a.attrs['href'] for a in nav[0].walk() if a.tag == 'a'], ['#features', '#pricing', '#install', '#faq'])
        ctas = {(a.attrs.get('href'), a.attrs.get('data-i18n')) for a in self.page.tags('a')}
        self.assertIn(('#install', 'cta.install'), ctas)
        self.assertIn(('#features', 'cta.features'), ctas)
        for id_ in ('features', 'pricing', 'install', 'faq'):
            self.assertEqual(self.ids[id_][0].tag, 'section', id_)

    def test_json_ld(self):
        blocks = [n for n in self.page.tags('script') if n.attrs.get('type') == 'application/ld+json']
        data = [json.loads(n.text()) for n in blocks]
        self.assertEqual(sorted(x['@type'] for x in data), ['FAQPage', 'Organization', 'SoftwareApplication', 'WebSite'])
        by = {x['@type']: x for x in data}
        for x in data:
            self.assertEqual(x['@context'], 'https://schema.org')
        for s in strings(data):
            if re.match(r'(?i)https?:', s):
                self.assertTrue(s == 'https://schema.org' or s.startswith('https://enana.cc/') or s == GITHUB, s)
        org = by['Organization']
        self.assertEqual((org['name'], org['url'], org['logo']), ('enana', 'https://enana.cc/', 'https://enana.cc/favicon.svg'))
        self.assertEqual(by['WebSite']['url'], 'https://enana.cc/')
        app = by['SoftwareApplication']
        self.assertIn('macOS', app['operatingSystem'])
        self.assertIn('Windows', app['operatingSystem'])
        self.assertTrue(app['applicationCategory'])
        self.assertEqual(app['offers']['@type'], 'Offer')
        self.assertEqual(str(app['offers']['price']), '0')
        self.assertEqual(app['description'], self.meta('name', 'description'))
        features = [n.text() for n in self.ids['features'][0].walk() if n.tag == 'h3']
        self.assertEqual(app['featureList'], features)
        faq = by['FAQPage']['mainEntity']
        details = [n for n in self.ids['faq'][0].walk() if n.tag == 'details']
        self.assertEqual(len(faq), len(details), 'FAQPage must list exactly the visible questions')
        for q, dn in zip(faq, details):
            summary = [k for k in dn.kids() if k.tag == 'summary']
            answer = [k for k in dn.kids() if k.tag == 'p']
            self.assertEqual((len(summary), len(answer)), (1, 1))
            self.assertEqual(q['@type'], 'Question')
            self.assertEqual(q['name'], summary[0].text())
            self.assertEqual(q['acceptedAnswer']['@type'], 'Answer')
            self.assertEqual(q['acceptedAnswer']['text'], answer[0].text())

    def test_markup_is_csp_safe(self):
        for name in ('index.html', '404.html'):
            for n in Page(read(name)).elements():
                where = '%s <%s>' % (name, n.tag)
                self.assertNotEqual(n.tag, 'style', where)
                self.assertNotIn('style', n.attrs, where)
                self.assertEqual([a for a in n.attrs if a.startswith('on')], [], where)
                for value in n.attrs.values():
                    self.assertFalse((value or '').strip().lower().startswith('javascript:'), where)
                if n.tag == 'script':
                    if 'src' in n.attrs:
                        self.assertEqual(n.text(), '', where)
                    else:
                        self.assertEqual(n.attrs.get('type'), 'application/ld+json', where)

    def test_no_external_assets(self):
        for name in ('index.html', '404.html'):
            page = Page(read(name))
            ids = {n.attrs['id'] for n in page.elements() if 'id' in n.attrs}
            for n in page.elements():
                for attr, value in n.attrs.items():
                    v = (value or '').strip()
                    where = '%s <%s %s="%s">' % (name, n.tag, attr, v)
                    if attr == 'src' or (n.tag == 'link' and attr == 'href' and n.attrs.get('rel') in ('stylesheet', 'icon')):
                        self.assertIn(v, LOCAL_ASSETS, where)
                    elif n.tag == 'a' and attr == 'href':
                        if v.startswith('#'):
                            self.assertIn(v[1:], ids, where)
                        else:
                            self.assertIn(v, ('/', GITHUB), where)
                        if n.attrs.get('target') == '_blank':
                            self.assertIn('noopener', n.attrs.get('rel') or '', where)
                    elif re.match(r'(?i)(?:[a-z][a-z0-9+.-]*:)?//|(?:https?|data|ftp):', v):
                        ok = v == 'https://enana.cc/' and (
                            (n.tag == 'link' and attr == 'href' and n.attrs.get('rel') in ('canonical', 'alternate'))
                            or (n.tag == 'meta' and attr == 'content' and n.attrs.get('property') == 'og:url'))
                        self.assertTrue(ok, where)
        for token in ('url(', '@import', '@font-face'):
            self.assertNotIn(token, self.css)
        self.assertEqual(sorted(set(re.findall(r'https?://[^\s\'"]*', self.js))), ['https://install.enana.cc/dl/'])

    def test_site_js_makes_no_requests_and_writes_no_html(self):
        for api in ('fetch(', 'XMLHttpRequest', 'sendBeacon', 'WebSocket', 'EventSource', 'import(', 'innerHTML',
                    'outerHTML', 'insertAdjacentHTML', 'document.write', 'eval(', 'new Function', 'new Image'):
            self.assertNotIn(api, self.js)

    def test_shared_styles_for_the_other_pages(self):
        for selector in ('.copy-buf', '[hidden]', '.nf', '.verify-page', '.wrap', '.muted', '.skip'):
            self.assertIn(selector, self.css)
        for token in ('--bg', '--surface', '--text', '--muted', '--line', '--pri', '--pri-fg', '--code-bg', '--ok', '--err'):
            self.assertIn(token + ':', self.css)
        self.assertIn('@media (prefers-color-scheme:dark)', self.css)
        self.assertIn('prefers-reduced-motion', self.css)
        for name in ('index.html', '404.html', 'verify.html'):
            for n in Page(read(name)).elements():
                for cls in (n.attrs.get('class') or '').split():
                    self.assertRegex(self.css, r'\.%s(?![\w-])' % re.escape(cls), '%s uses .%s' % (name, cls))

    def test_sitemap_and_robots(self):
        ns = {'s': 'http://www.sitemaps.org/schemas/sitemap/0.9'}
        urls = ET.fromstring((site / 'sitemap.xml').read_bytes()).findall('s:url', ns)
        self.assertEqual(len(urls), 1)
        self.assertEqual(urls[0].findtext('s:loc', namespaces=ns), 'https://enana.cc/')
        lastmod = urls[0].findtext('s:lastmod', namespaces=ns) or ''
        self.assertRegex(lastmod, r'^\d{4}-\d{2}-\d{2}$')
        datetime.date(*map(int, lastmod.split('-')))
        robots = read('robots.txt').splitlines()
        self.assertIn('Allow: /', robots)
        self.assertIn('Sitemap: https://enana.cc/sitemap.xml', robots)
        self.assertNotIn('Disallow: /', robots)


if __name__ == '__main__':
    unittest.main(verbosity=2)
