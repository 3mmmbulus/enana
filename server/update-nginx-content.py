#!/usr/bin/env python3
"""Make the signed cloud content under api.enana.cc/v1/ downloadable without an enana account (2.3.27).

In the one `location /v1/ {` block of the configuration it removes the two lines that require an account session,
    auth_request /_enana_auth;
    error_page 401 = @enana_unauthorized;
and puts one comment where the first of them was. Every other byte stays: in the block GET only (limit_except), the rate
limit (limit_req zone=enana_apihost), error_page 403, root and expires; elsewhere location = /_enana_auth,
@enana_unauthorized and the route to session/check (other tooling may still use them).
Public is safe there: /var/www/enana-cloud/v1/ holds only manifest.json, manifest.sig, content-<seq>.tar.gz and ping.json,
and a client uses nothing it has not verified (manifest signature with the built-in key, no older sequence, the bundle's
sha256 and size, the file-name allow-list).
It refuses, writing nothing, when the block is missing or duplicated, is public already, does not hold exactly those two
lines (and no other auth directive), or when an enclosing block sets auth_request (/v1/ would inherit it).
The file is read the way nginx reads it: braces inside quotes, comments and ${variable} names are not structure.
Usage: update-nginx-content.py <current enana.cc.conf> <output file>   (then nginx -t, then a graceful reload)
Exit: 0 = output written, 2 = refused (or usage), 3 = public already (nothing to do).
"""
import pathlib
import re
import sys

AUTH = 'auth_request /_enana_auth;'
UNAUTHORIZED = 'error_page 401 = @enana_unauthorized;'
COMMENT = ('# 公开内容 (2.3.27 起不需要账号): 清单有签名, 内容包由签名清单里的 sha256 和大小锁定, 客户端验签通过才使用; '
           '只读 (上面的 limit_except), 按来源地址限流 (上面的 limit_req)。')
OPEN = re.compile(r'location\s+/v1/\s*\{')
ANY_AUTH = re.compile(r'(?:^|[\s;{}])auth_request(?:_set)?(?=[\s;]|$)')


class Refused(Exception):
    pass


class AlreadyPublic(Exception):
    pass


def split_lines(text):
    """Lines with their '\n' (only '\n' separates lines, as for nginx); ''.join() gives the text back."""
    parts = text.split('\n')
    return [p + '\n' for p in parts[:-1]] + ([parts[-1]] if parts[-1] else [])


def scan(lines):
    """Read the configuration like nginx's tokenizer. Per line: the line that opened the block it starts in (None = file
    level), its text without the comment, and only the part that lies on its own level (nested one-line blocks left out);
    per block opener: the line that closes it. '{' and '}' are structure only outside quotes and comments ('#' at the start
    of a word), a '}' inside a word is a character, '${' is a variable name."""
    parents, codes, flats, closes, stack = [], [], [], {}, []
    quote, word, esc, prev = None, False, False, ''
    for n, line in enumerate(lines):
        parents.append(stack[-1] if stack else None)
        level, code, flat, comment = len(stack), [], [], False
        for c in line:
            if comment:
                break
            at_level, structural = len(stack) == level, False
            if esc:
                esc = False
            elif quote:
                if c == '\\':
                    esc = True
                elif c == quote:
                    quote, word = None, False
            elif c == '\\':
                esc = word = True
            elif c in ' \t\r\n;':
                word = False
            elif c == '{' and not (word and prev == '$'):
                stack.append(n)
                word, structural = False, True
            elif c == '}' and not word:
                if not stack:
                    raise Refused('unbalanced braces: the "}" on line %d closes nothing' % (n + 1))
                closes[stack.pop()] = n
                structural = True
            elif c == '#' and not word:
                comment = True
                continue
            elif c in '"\'' and not word:
                quote, word = c, True
            else:
                word = True
            prev = c
            code.append(c)
            if at_level and not structural:
                flat.append(c)
        if comment:
            word = False                      # the line end ends the comment and the word
        codes.append(''.join(code))
        flats.append(''.join(flat))
    if stack or quote:
        raise Refused('unbalanced braces or an unterminated quote')
    return parents, codes, flats, closes


def norm(code):
    return ' '.join(code.split())


def lines_of(numbers):
    return ', '.join(str(n + 1) for n in numbers)


def update(text):
    lines = split_lines(text)
    parents, codes, flats, closes = scan(lines)
    opens = [n for n, code in enumerate(codes) if OPEN.fullmatch(code.strip())]
    if not opens:
        raise Refused('no "location /v1/ {" block; is this the enana.cc configuration?')
    if len(opens) > 1:
        raise Refused('%d "location /v1/ {" blocks (lines %s); expected exactly one' % (len(opens), lines_of(opens)))
    start = opens[0]
    end = closes[start]
    inside = range(start + 1, end + 1)        # the closing line could hold a directive before its "}"
    found = [n for n in inside if ANY_AUTH.search(codes[n])]
    if not found:
        raise AlreadyPublic('the location /v1/ block (line %d) has no auth_request: the content is public already' % (start + 1))
    auth = [n for n in inside if parents[n] == start and norm(codes[n]) == AUTH]
    page = [n for n in inside if parents[n] == start and norm(codes[n]) == UNAUTHORIZED]
    if len(auth) != 1 or found != auth:
        raise Refused('the location /v1/ block (line %d) should require the session with exactly one line "%s" and no other '
                      'auth directive; auth directives found on line(s) %s' % (start + 1, AUTH, lines_of(found)))
    if len(page) != 1:
        raise Refused('the location /v1/ block (line %d) should hold exactly one line "%s"; found %d'
                      % (start + 1, UNAUTHORIZED, len(page)))
    # The blocks around /v1/ (its server, the file level = http): an auth_request there would still apply to /v1/.
    chain, p = {None}, parents[start]
    while p is not None:
        chain.add(p)
        p = parents[p]
    inherited = [n for n, flat in enumerate(flats) if parents[n] in chain and not start <= n <= end and ANY_AUTH.search(flat)]
    if inherited:
        raise Refused('an enclosing block sets auth_request (line(s) %s), which location /v1/ would inherit: removing its own '
                      'line would not make the content public; review instead of editing' % lines_of(inherited))
    a = auth[0]
    eol = '\r\n' if lines[a].endswith('\r\n') else '\n'
    indent = lines[a][:len(lines[a]) - len(lines[a].lstrip(' \t'))]
    lines[a] = indent + COMMENT + eol
    lines[page[0]] = ''
    return ''.join(lines)


def main(argv):
    if len(argv) != 3:
        print('Usage: update-nginx-content.py <current enana.cc.conf> <output file>', file=sys.stderr)
        return 2
    source, target = map(pathlib.Path, argv[1:])
    try:
        # surrogateescape: bytes that are not UTF-8 pass through unchanged
        new = update(source.read_bytes().decode('utf-8', 'surrogateescape'))
    except AlreadyPublic as e:
        print('update-nginx-content: %s; nothing written.' % e, file=sys.stderr)
        return 3
    except (Refused, OSError) as e:
        print('update-nginx-content: %s; nothing written.' % e, file=sys.stderr)
        return 2
    try:
        target.write_bytes(new.encode('utf-8', 'surrogateescape'))
    except OSError as e:
        print('update-nginx-content: cannot write %s: %s' % (target, e), file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
