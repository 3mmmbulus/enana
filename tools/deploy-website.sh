#!/bin/bash
# Publish only the public website (https://enana.cc) on the existing download host.
# Installs the fixed list of files nginx already serves; never touches verify.html / verify.js, nginx,
# systemd, downloads or any running service. Any check failure or unexpected change rolls everything back.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo 'Run as root on the download host.' >&2; exit 2; }
site_source=${1:?Usage: deploy-website.sh WEBSITE_DIR}
site=/opt/enana-cc/site
dl=/var/www/enana-dl
# Exact allowlist: nginx serves / (index.html) and a fixed set of static names, so no new paths.
files=(index.html site.css site.js robots.txt sitemap.xml favicon.svg 404.html)
for dir in "$site_source" "$site" "$dl"; do
  [ -d "$dir" ] && [ ! -L "$dir" ] || { echo "Not a directory: $dir" >&2; exit 2; }
done
for name in "${files[@]}"; do
  [ -f "$site_source/$name" ] && [ ! -L "$site_source/$name" ] || { echo "Missing $site_source/$name; refusing to publish." >&2; exit 2; }
  if [ -e "$site/$name" ] || [ -L "$site/$name" ]; then
    [ -f "$site/$name" ] && [ ! -L "$site/$name" ] || { echo "$site/$name is not a regular file; refusing." >&2; exit 2; }
  fi
done
mkdir -p /var/backups/enana/releases
exec 9>/var/backups/enana/website-publish.lock
flock -n 9 || { echo 'Another website publication is running.' >&2; exit 2; }
# deploy-windows-release.sh rewrites index.html / site.js as well: never run both at once.
exec 8>/var/backups/enana/windows-publish.lock
flock -n 8 || { echo 'A Windows publication is running; try again when it has finished.' >&2; exit 2; }
backup="/var/backups/enana/releases/website-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -m 700 "$backup"
mkdir "$backup/source" "$backup/site"
# Check and publish the same bytes: copy the staged files once, verify that copy, install from it.
for name in "${files[@]}"; do cp "$site_source/$name" "$backup/source/$name"; done
# Same rules as tests/website-check.py (CI): wording, install commands, hooks, metadata, JSON-LD, CSP-safe markup.
if ! python3 -I - "$backup/source" "${files[@]}" <<'PY'
import html.parser, json, pathlib, re, sys
d = pathlib.Path(sys.argv[1]); names = sys.argv[2:]
def check(ok, why):
    if not ok: raise SystemExit('Website check failed: ' + why)
for n in names:
    check((d / n).is_file() and 0 < (d / n).stat().st_size <= 524288, n + ': missing, empty or larger than 512 KiB')
text = {n: (d / n).read_text(encoding='utf-8') for n in names}
cmds = {'cmd-unix': 'curl -fsSL https://install.enana.cc | bash',
        'cmd-unix2': 'wget -qO- https://install.enana.cc | bash',
        'cmd-win': 'irm https://install.enana.cc/get.ps1 | iex',
        'cmd-win2': 'powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://install.enana.cc/get.ps1 | iex"'}
A, Z = r'(?<![a-z0-9])', r'(?![a-z0-9])'
bad = re.compile('|'.join([r'vpn', r'翻墙', r'墙', r'科学上网', r'梯子', r'机场', r'代理', r'prox(?:y|ies)', r'sing[\s-]?box',
    r'clash', r'v2ray', A + r'xray' + Z, r'vless', r'reality', r'trojan', r'vmess', r'shadowsocks', A + r'ssr?' + Z,
    r'hysteria', A + r'tuic' + Z, r'wireguard', A + r'socks5?' + Z, r'订阅', r'subscription', r'节点', r'出口', r'egress',
    r'exit ip', r'风控', r'封锁', r'blocked', r'unblock', r'censor', r'gfw', r'防火墙', r'firewall', r'circumvent',
    r'bypass', r'tunnel', r'分流', r'国内', r'国外', r'海外', r'境外', r'外网', r'domestic', r'overseas', r'abroad',
    r'foreign', r'google', r'youtube']), re.I)
for n, t in text.items():
    m = bad.search(t.replace(cmds['cmd-win2'], ''))
    check(not m, '%s: forbidden wording %r' % (n, m and m.group(0)))
VOID = {'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'source', 'track', 'wbr'}
class N:
    def __init__(s, tag, attrs, up): s.tag, s.a, s.up, s.kids = tag, dict(attrs), up, []
    def walk(s):
        yield s
        for k in s.kids:
            if isinstance(k, N): yield from k.walk()
    def text(s): return ''.join(k if isinstance(k, str) else k.text() for k in s.kids)
    def child(s, tag): return [k for k in s.kids if isinstance(k, N) and k.tag == tag]
class P(html.parser.HTMLParser):
    def __init__(s, src):
        super().__init__(convert_charrefs=True); s.root = s.cur = N('#', [], None); s.feed(src); s.close()
        check(s.cur is s.root, 'unclosed <%s>' % s.cur.tag)
    def handle_starttag(s, tag, attrs):
        n = N(tag, attrs, s.cur); s.cur.kids.append(n)
        if tag not in VOID: s.cur = n
    def handle_startendtag(s, tag, attrs): s.cur.kids.append(N(tag, attrs, s.cur))
    def handle_endtag(s, tag):
        if tag in VOID: return
        check(s.cur.tag == tag, '</%s> closes <%s>' % (tag, s.cur.tag)); s.cur = s.cur.up
    def handle_data(s, data): s.cur.kids.append(data)
    def els(s): return [n for n in s.root.walk() if n is not s.root]
raw = (d / 'index.html').read_bytes(); page = P(text['index.html']); els = page.els(); js = text['site.js']; css = text['site.css']
ids = {}
for n in els:
    if 'id' in n.a: ids.setdefault(n.a['id'], []).append(n)
check(all(len(v) == 1 for v in ids.values()), 'duplicate ids')
for i, c in cmds.items():
    check(c.encode() in raw and i in ids and ids[i][0].tag == 'code' and ids[i][0].text() == c, 'install command %s changed' % i)
    check(sum(1 for n in els if n.a.get('data-copy') == i) == 1, 'copy button for %s' % i)
for i in ('copy-status', 'release-manifest', 'os-switch'): check(i in ids, 'missing #' + i)
check('hidden' in ids['os-switch'][0].a, '#os-switch must start hidden')
for attr, want in (('data-cmd', ['unix', 'win']), ('data-os', ['unix', 'win']), ('data-lang', ['en', 'zh'])):
    check(sorted(n.a[attr] for n in els if attr in n.a) == want, attr)
check(b'https://install.enana.cc/get.ps1' in raw and 'windows-manifest.json' in js, 'strings deploy-windows-release.sh asserts')
for hook in ("'[data-i18n]'", "'[data-i18n-aria]'", "'[data-copy]'", "'[data-cmd]'", "'[data-os]'", "'[data-lang]'",
             'meta[name="description"]', "'release-manifest'", "'copy-status'", "'os-switch'", "'copy-buf'"):
    check(hook in js, 'site.js lost ' + hook)
check([n.tag for n in els].count('h1') == 1, 'exactly one h1')
title = [n.text() for n in els if n.tag == 'title']
desc = [n.a.get('content') or '' for n in els if n.tag == 'meta' and n.a.get('name') == 'description']
check(len(title) == 1 and len(title[0]) <= 32 and len(desc) == 1 and 70 <= len(desc[0]) <= 80, 'Chinese title / description length')
def entry(lang, key):
    block = re.search(r'^    %s: \{\n(.*?)\n    \},?$' % lang, js, re.S | re.M)
    value = block and re.search(r"^      %s: '((?:[^'\\]|\\.)*)',?$" % key, block.group(1), re.M)
    check(bool(value), 'DICT.%s.%s missing' % (lang, key)); return value.group(1)
check(entry('zh', 'title') == title[0] and entry('zh', 'desc') == desc[0], 'site.js zh title / description differ from index.html')
check(len(entry('en', 'title')) <= 60 and len(entry('en', 'desc')) <= 155, 'English title / description length')
check(not any(n.tag == 'meta' and (n.a.get('property') or n.a.get('name') or '').startswith(('og:image', 'twitter:image')) for n in els), 'og:image without a published image')
ld = [json.loads(n.text()) for n in els if n.tag == 'script' and n.a.get('type') == 'application/ld+json']
check(sorted(x.get('@type', '') for x in ld) == ['FAQPage', 'Organization', 'SoftwareApplication', 'WebSite'], 'JSON-LD blocks')
faq = [x for x in ld if x['@type'] == 'FAQPage'][0]['mainEntity']
details = [n for n in ids['faq'][0].walk() if n.tag == 'details'] if 'faq' in ids else []
check(len(faq) == len(details) and all(q['name'] == dn.child('summary')[0].text() and q['acceptedAnswer']['text'] == dn.child('p')[0].text() for q, dn in zip(faq, details)), 'FAQPage differs from the visible FAQ')
for name in ('index.html', '404.html'):
    for n in P(text[name]).els():
        check(n.tag != 'style' and 'style' not in n.a and not any(k.startswith('on') for k in n.a), '%s: inline style or handler on <%s>' % (name, n.tag))
        if n.tag == 'script': check(n.a.get('src') == '/site.js' or n.a.get('type') == 'application/ld+json', name + ': inline script')
        for k, v in n.a.items():
            v = (v or '').strip()
            if k == 'src' or (n.tag == 'link' and k == 'href' and n.a.get('rel') in ('stylesheet', 'icon')):
                check(v in ('/site.css', '/site.js', '/favicon.svg'), '%s: asset %s' % (name, v))
            elif n.tag == 'a' and k == 'href':
                check(v == '/' or v.startswith('#') or v == 'https://github.com/3mmmbulus/enana', '%s: link %s' % (name, v))
            elif re.match(r'(?i)(?:[a-z][a-z0-9+.-]*:)?//|(?:https?|data|ftp|javascript):', v):
                check(v == 'https://enana.cc/' and ((n.tag == 'link' and n.a.get('rel') in ('canonical', 'alternate')) or (n.tag == 'meta' and n.a.get('property') == 'og:url')), '%s: external reference %s' % (name, v))
for sel in ('.copy-buf', '[hidden]', '.nf', '.verify-page', '.wrap', '.muted'): check(sel in css, 'site.css lost ' + sel)
check('url(' not in css and '@import' not in css and '@font-face' not in css, 'site.css loads external resources')
for api in ('fetch(', 'XMLHttpRequest', 'sendBeacon', 'WebSocket', 'EventSource', 'import(', 'innerHTML', 'document.write'):
    check(api not in js, 'site.js uses ' + api)
print('Website checks passed: wording, install commands, hooks, metadata, JSON-LD and CSP-safe markup.')
PY
then
  rm -rf -- "$backup"
  echo 'Nothing was published.' >&2
  exit 2
fi
(cd "$backup/source" && sha256sum "${files[@]}") > "$backup/published.sha256"
snapshot_services() {
  systemctl list-units --type=service --state=running --no-pager --plain --no-legend | awk '{print $1}' | sort | while read -r service; do
    systemctl show "$service" --property=Id,MainPID,ActiveEnterTimestamp
  done
}
snapshot_config() { find /etc/nginx /etc/systemd/system -type f -exec sha256sum {} + | sort; }
snapshot_downloads() { find "$dl" -printf '%P\t%y\t%s\t%T@\t%m\t%u:%g\n' | LC_ALL=C sort; }
others=()
for name in "${files[@]}"; do others+=(! -path "$site/$name"); done
# Everything else in the site root (verify.html, verify.js, ...): listing plus content hashes.
snapshot_site_others() {
  find "$site" -mindepth 1 "${others[@]}" ! -name '.enana-website-*' -printf '%P\t%y\t%s\t%T@\t%m\t%u:%g\n' | LC_ALL=C sort
  find "$site" -mindepth 1 -type f "${others[@]}" ! -name '.enana-website-*' -exec sha256sum {} + | LC_ALL=C sort
}
snapshot_services > "$backup/services.before"
snapshot_config > "$backup/config.before"
snapshot_downloads > "$backup/downloads.before"
snapshot_site_others > "$backup/site-others.before"
for name in "${files[@]}"; do
  [ ! -e "$site/$name" ] || cp -p "$site/$name" "$backup/site/$name"
done
committed=0
rollback() {
  rc=$?
  set +e
  if [ "$committed" = 0 ]; then
    failed=0
    for name in "${files[@]}"; do
      if [ -e "$backup/site/$name" ]; then
        { cp -p "$backup/site/$name" "$site/.enana-website-restore-$$" && mv -f "$site/.enana-website-restore-$$" "$site/$name"; } || failed=1
      else
        rm -f "$site/$name" || failed=1
      fi
    done
    if [ "$failed" = 0 ]; then
      echo "Website publication rolled back. Backup: $backup" >&2
    else
      echo "Rollback incomplete: restore $site by hand from $backup/site" >&2
    fi
    [ "$rc" != 0 ] || rc=1
  fi
  rm -f "$site/.enana-website-publish-$$" "$site/.enana-website-restore-$$"
  exit "$rc"
}
trap rollback EXIT
trap 'exit 1' HUP INT TERM
for name in "${files[@]}"; do
  install -m 644 -o root -g root "$backup/source/$name" "$site/.enana-website-publish-$$"
  mv -f "$site/.enana-website-publish-$$" "$site/$name"
done
for name in "${files[@]}"; do
  cmp -s "$backup/source/$name" "$site/$name" || { echo "Installed $name does not match the checked copy." >&2; exit 1; }
done
snapshot_services > "$backup/services.after"
snapshot_config > "$backup/config.after"
snapshot_downloads > "$backup/downloads.after"
snapshot_site_others > "$backup/site-others.after"
cmp -s "$backup/services.before" "$backup/services.after" || { echo 'Running services changed during publication.' >&2; exit 1; }
cmp -s "$backup/config.before" "$backup/config.after" || { echo 'nginx or systemd configuration changed during publication.' >&2; exit 1; }
cmp -s "$backup/downloads.before" "$backup/downloads.after" || { echo "$dl changed during publication." >&2; exit 1; }
cmp -s "$backup/site-others.before" "$backup/site-others.after" || { echo "Other files in $site changed during publication." >&2; exit 1; }
committed=1
printf 'Published website (%s). verify.html/verify.js, downloads, nginx/systemd configs and service PIDs unchanged. Backup: %s\n' "${files[*]}" "$backup"
