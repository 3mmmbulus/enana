#!/bin/bash
# enana 系统代理助手 (版本 @VERSION@)。root 所有, 当前用户可以免密调用 (sudoers 里只开放了这一个文件), 只做一件事:
#   on   把所有已启用网络服务的系统代理指向 127.0.0.1:@PORT@
#   off  把「正指向 127.0.0.1:@PORT@」的网络服务的系统代理关掉 (别的软件设置的代理一概不碰)
# 端口、networksetup 路径都在安装时写死在这个文件里, 不接受参数 / 环境变量里的任何别的值: 即使有别的程序滥用它, 最多也只能把系统代理指向 enana 自己的端口。
# 由 enana 在一次管理员授权里安装 (lib/os-darwin.sh 的 os_sysproxy_helper_install_cmds), 卸载时一并删除。
PATH=/usr/sbin:/usr/bin:/bin:/sbin; export PATH
unset IFS ENV BASH_ENV
NS=@NETWORKSETUP@; PORT=@PORT@; VERSION=@VERSION@
[ "$#" -eq 1 ] || { echo "usage: $0 on|off|version" >&2; exit 2; }
case $1 in
  version) printf '%s\n' "$VERSION"; exit 0 ;;
  on|off) ;;
  *) echo "usage: $0 on|off|version" >&2; exit 2 ;;
esac
want=$1; r=0
while IFS= read -r s; do
  [ -n "$s" ] || continue
  if [ "$want" = on ]; then
    "$NS" -setwebproxy "$s" 127.0.0.1 "$PORT" || r=1
    "$NS" -setsecurewebproxy "$s" 127.0.0.1 "$PORT" || r=1
    "$NS" -setsocksfirewallproxy "$s" 127.0.0.1 "$PORT" || r=1
    "$NS" -setproxybypassdomains "$s" localhost 127.0.0.1 '*.local' 169.254/16 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 || r=1
  else
    for k in webproxy securewebproxy socksfirewallproxy; do
      out=$("$NS" -get$k "$s" 2>/dev/null) || continue
      if printf '%s\n' "$out" | grep -q '^Enabled: Yes' && printf '%s\n' "$out" | grep -q "^Port: $PORT\$" && printf '%s\n' "$out" | grep -q '^Server: 127.0.0.1'; then
        "$NS" -set${k}state "$s" off || r=1
      fi
    done
  fi
done <<EOF
$("$NS" -listallnetworkservices 2>/dev/null | tail -n +2 | grep -v '^\*')
EOF
exit $r
