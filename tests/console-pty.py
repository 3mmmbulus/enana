"""Drive the actual shared console through a real terminal, with safe actions."""
import os
import pathlib
import pty
import select
import shlex
import subprocess
import tempfile
import time

repo = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='enana-console-') as directory:
    root = pathlib.Path(directory)
    script = root / 'console.sh'
    script.write_text(f'''
set -u
LIB={shlex.quote(str(repo / 'lib'))}; DATA={shlex.quote(str(repo / 'data'))}; H={shlex.quote(directory)}
. "$LIB/common.sh"
. "$LIB/i18n.sh"
LANG_UI=zh; i18n_init
. "$LIB/console.sh"
VERSION=test; PORT=17890; UI_URL=http://127.0.0.1:17891/
console_gather() {{ CS_svc=0;CS_pid=;CS_up=;CS_ver=test;CS_sp=0;CS_srv=0;CS_new=0;CS_acc=;CS_upd=;CS_mode=Direct; }}
os_open() {{ printf opened >> "$H/action"; }}
console_main
''')
    master, slave = pty.openpty()
    process = subprocess.Popen(['/bin/bash', str(script)], stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    captured = bytearray()

    def until(token, timeout=5):
        deadline = time.monotonic() + timeout
        while token not in captured:
            if time.monotonic() > deadline:
                raise AssertionError(f'terminal did not show {token!r}: {captured!r}')
            if select.select([master], [], [], 0.1)[0]:
                captured.extend(os.read(master, 65536))

    try:
        until('输入选项后按 Enter'.encode())
        text = captured.decode()
        lines = [line for line in text.splitlines() if '[' in line and ']' in line]
        options = [line for line in lines if any(f'[{key}]' in line for key in '123456789slrq')]
        assert len(options) == 13 and all(line.count('[') == 1 or '[9]' in line for line in options)
        assert '\x1b[31m  [9] 卸载\x1b[0m' in text
        assert 'status | restart' not in text and '命令行:' not in text
        os.write(master, b'1')
        time.sleep(0.3)
        assert not (root / 'action').exists(), 'single key executed before Enter'
        os.write(master, b'\n')
        deadline = time.monotonic() + 3
        while not (root / 'action').exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        assert (root / 'action').read_text() == 'opened'
        os.write(master, b'12\n')
        time.sleep(0.2)
        assert (root / 'action').read_text() == 'opened', 'multi-character input triggered a partial option'
        os.write(master, b'q')
        time.sleep(0.2)
        assert process.poll() is None, 'quit executed without Enter'
        os.write(master, b'\n')
        deadline = time.monotonic() + 3
        while process.poll() is None and time.monotonic() < deadline:
            if select.select([master], [], [], 0.1)[0]:
                try:
                    captured.extend(os.read(master, 65536))
                except OSError:
                    break
        assert process.wait(timeout=3) == 0
        print('PASS: 13 separate actions, red uninstall, no command footer, Enter required, whole-line dispatch and clean quit')
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
    # Real translations must preserve the menu layout and color placeholders.
    script.write_text(script.read_text().replace('LANG_UI=zh;', 'LANG_UI=en;').replace('console_main\n', 'console_gather; console_draw\n'))
    english = subprocess.check_output(['/bin/bash', str(script)], text=True)
    assert '[9] Uninstall' in english and '[1] Open dashboard' in english
    assert not any('\u4e00' <= c <= '\u9fff' for c in english)
    print('PASS: English terminal menu uses the same separate actions without untranslated Chinese')
