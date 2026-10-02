# 模拟 launchd 的 inetd 模式: 每个连接启动一次 `bash api.sh`, 套接字作为 stdin/stdout
import socket, subprocess, sys, os, signal
port = int(sys.argv[1]); script = sys.argv[2]
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1', port)); s.listen(16)
signal.signal(signal.SIGCHLD, signal.SIG_IGN)
err = open(os.environ.get('API_ERR', '/dev/null'), 'ab')
while True:
    c, _ = s.accept()
    subprocess.Popen(['/bin/bash', script], stdin=c.fileno(), stdout=c.fileno(), stderr=err, close_fds=True, start_new_session=True)
    c.close()
