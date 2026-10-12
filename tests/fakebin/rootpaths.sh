# 测试替身 (由假 sudo 与假 osascript 引用, 不单独运行): 以 root 运行的命令里写死的绝对路径 (生产里就是这些值),
# 在沙箱里换成假命令和沙箱目录。生产代码不做这件事: 环境变量不能决定 root 运行什么, 只有测试的假提权命令会改写。
#   /usr/bin/install、/usr/bin/osascript、/usr/sbin/networksetup、/bin/launchctl -> tests/fakebin 里的假命令
#   /usr/local、/etc/sudoers.d -> $ENANA_ROOT_PREFIX 之下 (沙箱)
#   OWN='0' (根目录的属主检查) -> 当前用户 (沙箱里的目录是当前用户建的)
# 沙箱里的普通文件参数 (以 root 运行的助手) 先复制一份、改写后再运行, 这样助手里写死的 networksetup 也是假的。
rootpaths_rewrite() { # 标准输入 -> 标准输出: 文本改写
  local fb pfx=${ENANA_ROOT_PREFIX:-}
  fb=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
  if [ -n "$pfx" ]; then
    sed -e "s|/usr/bin/install|$fb/install|g" -e "s|/usr/bin/osascript|$fb/osascript|g" -e "s|/usr/sbin/networksetup|$fb/networksetup|g" \
      -e "s|/bin/launchctl|$fb/launchctl|g" -e "s|OWN='0'|OWN='$(id -u)'|g" -e "s|/usr/local|$pfx/usr/local|g" -e "s|/etc/sudoers.d|$pfx/etc/sudoers.d|g"
  else
    sed -e "s|/usr/bin/install|$fb/install|g" -e "s|/usr/bin/osascript|$fb/osascript|g" -e "s|/usr/sbin/networksetup|$fb/networksetup|g" \
      -e "s|/bin/launchctl|$fb/launchctl|g" -e "s|OWN='0'|OWN='$(id -u)'|g"
  fi
}
rootpaths_arg() { # 一个参数 -> 改写后的参数 (沙箱里的普通文件 = 以 root 运行的助手: 改写内容, 放进临时副本运行)
  local a=$1 t pfx=${ENANA_ROOT_PREFIX:-}
  if [ -n "$pfx" ] && [ -f "$a" ] && [ ! -L "$a" ]; then
    case $a in "$pfx"/*)
      t=$(mktemp "${FAKE_STATE:-/tmp}/rootcopy.XXXXXX") && rootpaths_rewrite < "$a" > "$t" && chmod 755 "$t" && { printf '%s' "$t"; return 0; }
      ;;
    esac
  fi
  printf '%s' "$a" | rootpaths_rewrite
}
