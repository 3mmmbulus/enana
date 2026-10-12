# 测试替身 (由假 sudo 与假 osascript 引用, 不单独运行): 以 root 运行的命令里写死的绝对路径 (生产里就是这些值),
# 在沙箱里换成假命令和沙箱目录。生产代码不做这件事: 环境变量不能决定 root 运行什么, 只有测试的假提权命令会改写。
#   /usr/bin/install、/usr/bin/osascript、/usr/sbin/networksetup、/bin/launchctl -> tests/fakebin 里的假命令
#   /usr/sbin/visudo -> $FAKE_VISUDO (没设就是真的; S6e 用它模拟校验失败)
#   /usr/local、/etc/sudoers.d -> $ENANA_ROOT_PREFIX 之下 (沙箱)
#   OWN=0; (根目录的属主检查, 生产里是不加引号的数字) -> 当前用户 (沙箱里的目录是当前用户建的)
#   /usr/bin/env -i PATH=... (清空环境的 root 命令) -> 同时带上沙箱需要的变量 (否则假命令看不到 FAKE_STATE / 沙箱前缀 / 管理员状态)
# 已经在沙箱里的路径 (例如 os_helper_trusted 传给 sudo -n -l 的) 原样保留, 不再加一层前缀。
# 沙箱里的普通文件 (以 root 运行的助手) 执行前由 rootpaths_copy_exec 复制一份、改写内容再运行, 这样助手里写死的 networksetup 也是假的。
rootpaths_rewrite() { # 标准输入 -> 标准输出: 文本改写
  local fb pfx=${ENANA_ROOT_PREFIX:-}
  fb=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
  if [ -n "$pfx" ]; then
    sed -e "s|/usr/bin/install|$fb/install|g" -e "s|/usr/bin/osascript|$fb/osascript|g" -e "s|/usr/sbin/networksetup|$fb/networksetup|g" \
      -e "s|/bin/launchctl|$fb/launchctl|g" -e "s|OWN=0;|OWN=$(id -u);|g" -e "s|/usr/local|$pfx/usr/local|g" -e "s|/etc/sudoers.d|$pfx/etc/sudoers.d|g" \
      -e "s|/usr/sbin/visudo|${FAKE_VISUDO:-/usr/sbin/visudo}|g" \
      -e "s|/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin|& ENANA_ROOT_PREFIX=$pfx FAKE_STATE=${FAKE_STATE:-} FAKE_ADMIN=1|g"
  else
    sed -e "s|/usr/bin/install|$fb/install|g" -e "s|/usr/bin/osascript|$fb/osascript|g" -e "s|/usr/sbin/networksetup|$fb/networksetup|g" \
      -e "s|/bin/launchctl|$fb/launchctl|g" -e "s|OWN=0;|OWN=$(id -u);|g"
  fi
}
rootpaths_arg() { # 一个参数 -> 改写后的参数 (已经在沙箱里的路径原样保留, 否则会变成 沙箱/沙箱/...)
  local a=$1 pfx=${ENANA_ROOT_PREFIX:-}
  if [ -n "$pfx" ]; then case $a in "$pfx"/*) printf '%s' "$a"; return 0 ;; esac; fi
  printf '%s' "$a" | rootpaths_rewrite
}
rootpaths_copy_exec() { # 要执行的命令 -> 若是沙箱里的普通文件 (以 root 运行的助手): 输出「改写内容后的临时副本」路径; 否则返回非 0 (什么都不做)
  local a=$1 t pfx=${ENANA_ROOT_PREFIX:-}
  [ -n "$pfx" ] && [ -f "$a" ] && [ ! -L "$a" ] || return 1
  case $a in "$pfx"/*) ;; *) return 1 ;; esac
  t=$(mktemp "${FAKE_STATE:-/tmp}/rootcopy.XXXXXX") && rootpaths_rewrite < "$a" > "$t" && chmod 755 "$t" && printf '%s' "$t"
}
