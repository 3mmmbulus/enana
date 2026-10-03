"""Stop real detached installation jobs; preserve a foreign shell process."""
import os
import pathlib
import subprocess
import tempfile
import time

repo = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='enana-jobs-') as folder:
    root = pathlib.Path(folder)
    home = root / 'installation with spaces'
    (home / 'lib').mkdir(parents=True)
    owned_script = home / 'lib/api.sh'
    foreign_script = root / 'foreign.sh'
    for script in (owned_script, foreign_script):
        script.write_text('while :; do sleep 30; done\n')
    owned = subprocess.Popen(['/bin/bash', str(owned_script)])
    foreign = subprocess.Popen(['/bin/bash', str(foreign_script)])
    try:
        time.sleep(0.2)
        subprocess.run(['perl', str(repo / 'lib/stop-jobs.pl'), str(home), str(os.getpid())], check=True)
        assert owned.wait(timeout=3) < 0
        assert foreign.poll() is None
        print('PASS: owned API shell and descendants stop; unrelated shell survives')
    finally:
        for process in (owned, foreign):
            if process.poll() is None:
                subprocess.run(['pkill', '-TERM', '-P', str(process.pid)], check=False)
                process.terminate()
                process.wait()
