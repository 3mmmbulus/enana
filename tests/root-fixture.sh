#!/bin/bash
# 测试夹具 (由 tests/tun-service.sh 与 tests/enhanced-root-integrity.sh 引用, 不单独运行):
#   · lib/enhanced-root.sh 复制一份到临时目录, 固定路径 / 命令换成临时目录里的替身 (ROOT、plist、sudoers、助手目录 $W/Library/PrivilegedHelperTools/com.enana.proxy
#     和旧位置 $W/usr/local/libexec/enana、launchctl、install、chown、route、ifconfig、sleep、networksetup); $W/Library 是沙箱里的 /Library (755, 没有 ACL; root 脚本从来不建它)
#   · 假 networksetup 管着一组假的网络服务 ($W/ns.tsv, 每个用例前 rf_ns_reset 还原): 自动 DNS 的 Wi-Fi · 手动 IPv4 + IPv6 的有线网卡 · 名字带空格和中文的网桥 ·
#     硬件端口带括号的网卡 · 名字里有 shell 代码的服务 ($NS_ODD, 被执行就会建出 $W/ns-canary) · 停用的服务 · 没有网卡的 VPN; 副本里还留着真的
#     /usr/sbin/networksetup 就拒绝运行 (以 root 身份改的是这台电脑的系统 DNS)
#   · enana 一侧的函数直接用 lib/enhanced.sh 的原文 (LIB 指向夹具里的副本), 所以两边的摘要、渲染、暂存都是真实代码
#   · 假 sudo 只做两件事: `sudo -n true` 成功; `sudo -n /bin/sh -c CMD` 在本机以当前用户运行 CMD (root 脚本自己的 id 检查已替换成 printf 0)
#   · 绝不运行真实的 launchctl / sudo / osascript / networksetup; 解析到真实命令的 PATH 由调用方检查
# 用法: rf_setup <临时目录>; rf_reset (每个用例前清空, 网络服务的 DNS 也还原); rf_enana_start (调用 enhanced_start, 返回其退出码);
#       系统 DNS: rf_dns <服务名> · rf_dns_user <服务名> <Empty|地址…> (模拟用户自己改) · rf_rec (root 的记录) · rf_ns_original / rf_ns_taken / rf_ns_untouched · rf_ns_sets

RF_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
rf_setup() {
  W=$1; ME=$(id -u); LIBT=$W/lib; H=$W/home/.enana; ROOTB=$W/support; ROOT=$ROOTB/enana-$ME
  mkdir -p "$W/bin" "$W/fakebin" "$W/daemons" "$W/sudoers.d" "$W/usr/local" "$LIBT" "$H/rules/geo" "$ROOTB"
  mkdir -m 755 "$W/Library"
  cp "$RF_REPO/lib/tunrules-helper.pl" "$LIBT/"
  cp "$RF_REPO/lib/enhanced.sh" "$LIBT/"
  cat > "$W/root.sed" <<SED
s|^root_base=.*|root_base="$ROOTB"|
s|^library=.*|library="$W/Library"; helper_tools="\$library/PrivilegedHelperTools"; helper_dir="\$helper_tools/com.enana.proxy"|
s|^usr_local=.*|usr_local="$W/usr/local"; legacy_dir="\$usr_local/libexec/enana"; sudoers_dir="$W/sudoers.d"|
s|^launchctl_bin=.*|launchctl_bin="$W/bin/launchctl"|
s|^root_owner=0|root_owner=$ME|
s|/usr/bin/id -u|printf 0|
s|plist="/Library/LaunchDaemons/|plist="$W/daemons/|
s|/usr/sbin/chown|$W/bin/chown|g
s|/usr/bin/install|$W/bin/install|g
s|/sbin/route|$W/bin/route|g
s|/sbin/ifconfig|$W/bin/ifconfig|g
s|/bin/sleep|$W/bin/sleep|g
s|/usr/sbin/networksetup|$W/bin/networksetup|g
SED
  sed -f "$W/root.sed" "$RF_REPO/lib/enhanced-root.sh" > "$LIBT/enhanced-root.sh"
  if grep -q '/usr/sbin/networksetup' "$LIBT/enhanced-root.sh" || ! grep -q "^networksetup_bin=\"$W/bin/networksetup\"" "$LIBT/enhanced-root.sh"; then
    echo 'REFUSING: the fixture copy of lib/enhanced-root.sh would run the real networksetup (it changes the system DNS of this computer)' >&2; exit 1
  fi
  NS_ODD="Lab \$(touch $W/ns-canary) 'q' \`touch $W/ns-canary\`"
  cat > "$W/bin/networksetup" <<'MOCK'
#!/usr/bin/perl
# 假 networksetup (见 tests/root-fixture.sh): 只认 root 脚本用到的三个命令, 输出的格式和真的一样。
#   网络服务在 $RF_W/ns.tsv, 每行「序号 (停用的是 *)<TAB>设备 (VPN 是空的)<TAB>硬件端口<TAB>DNS (Empty 或空格分隔的地址)<TAB>名字」
#   每次调用记一行到 $RF_W/ns.log (参数之间是 TAB); RF_NS_QUIET=1 时不记 (测试自己查看, 或者模拟用户在系统设置里改动)
#   $RF_W/ns-fail 的每一行让对应的调用失败: list · get · set (全部), 或「get 名字」「set 名字」(只对这个服务)
use strict; use warnings;
my $w = $ENV{RF_W} // die "RF_W not set\n";
my @a = @ARGV;
if (!$ENV{RF_NS_QUIET}) { open my $l, ">>", "$w/ns.log" or die "$!\n"; print $l join("\t", @a), "\n"; close $l }
my %fail; if (open my $f, "<", "$w/ns-fail") { while (my $x = <$f>) { chomp $x; $fail{$x} = 1 } close $f }
open my $db, "<", "$w/ns.tsv" or die "$!\n"; my @s = map { chomp; [split /\t/, $_, 5] } <$db>; close $db;
my $cmd = shift(@a) // ""; my $name = $a[0] // "";
my ($svc) = grep { $_->[4] eq $name } @s;
if ($cmd eq "-listnetworkserviceorder") {
  exit 1 if $fail{list};
  print "An asterisk (*) denotes that a network service is disabled.\n";
  print "($_->[0]) $_->[4]\n(Hardware Port: $_->[2], Device: $_->[1])\n\n" for @s;
  exit 0;
}
if ($cmd eq "-getdnsservers") {
  if (!$svc || $fail{get} || $fail{"get $name"}) { print "$name is not a recognized network service.\n** Error: The parameters were not valid.\n"; exit 4 }
  if ($svc->[3] eq "Empty") { print "There aren't any DNS Servers set on $name.\n" } else { print "$_\n" for split / /, $svc->[3] }
  exit 0;
}
if ($cmd eq "-setdnsservers") {
  shift @a;
  if (!$svc || !@a || $fail{set} || $fail{"set $name"}) { print "** Error: The parameters were not valid.\n"; exit 4 }
  if (@a == 1 && $a[0] eq "Empty") { $svc->[3] = "Empty" }
  else { for (@a) { /\A[0-9A-Fa-f.:]+(?:%[A-Za-z0-9]+)?\z/ or do { print "$_ is not a valid IP address.\n"; exit 4 } } $svc->[3] = join " ", @a }
  open my $o, ">", "$w/ns.tsv.new" or die "$!\n"; print $o join("\t", @$_), "\n" for @s; close $o; rename "$w/ns.tsv.new", "$w/ns.tsv" or die "$!\n";
  exit 0;
}
print "** Error: unknown command $cmd\n"; exit 1;
MOCK
  printf '#!/bin/sh\nexit 0\n' > "$W/bin/chown"; printf '#!/bin/sh\nexit 0\n' > "$W/bin/sleep"
  printf '#!/bin/sh\necho "interface: utun42"\n' > "$W/bin/route"
  printf '#!/bin/sh\necho "inet 172.19.0.1 netmask 0xfffffffc"\n' > "$W/bin/ifconfig"
  cat > "$W/bin/install" <<'MOCK'
#!/bin/bash
# 假 install: 忽略 -o/-g, 支持 -d / -m; 只许写进夹具 (ENANA_ROOT_PREFIX 之下)
# 和真的 install 一样先删掉已有的目标 (不带 -S 时 install 先 unlink): 否则重装时 cp 写不进上一次装好的 440 免密规则
mode=''; dirs=0; args=(); while [ $# -gt 0 ]; do case $1 in -d) dirs=1; shift ;; -m) mode=$2; shift 2 ;; -o|-g) shift 2 ;; -*) shift ;; *) args+=("$1"); shift ;; esac; done
if [ "$dirs" = 1 ]; then for d in "${args[@]}"; do mkdir -p "$d" && { [ -z "$mode" ] || chmod "$mode" "$d"; } || exit 1; done; exit 0; fi
[ "${#args[@]}" -eq 2 ] || exit 1
rm -f "${args[1]}" && cp "${args[0]}" "${args[1]}" && { [ -z "$mode" ] || chmod "$mode" "${args[1]}"; }
MOCK
  cat > "$W/bin/launchctl" <<'MOCK'
#!/bin/sh
# 假 launchctl: 记录每一次调用; "loaded" 标记表示系统守护进程已加载; fail-bootstrap 标记让下一次 bootstrap 失败
echo "$*" >> "$RF_W/calls"
case $1 in
  print) case ${2:-} in gui/*) exit 1 ;; esac; [ -f "$RF_W/loaded" ] && { echo 'pid = 100'; exit 0; }; exit 1 ;;
  bootstrap) if [ -f "$RF_W/fail-bootstrap" ]; then rm -f "$RF_W/fail-bootstrap"; exit 1; fi; : > "$RF_W/loaded"; exit 0 ;;
  bootout) rm -f "$RF_W/loaded"; exit 0 ;;
  asuser) exit 0 ;;
esac
exit 0
MOCK
  cat > "$W/fakebin/sudo" <<'MOCK'
#!/bin/sh
# 假 sudo (见 tests/root-fixture.sh): 记录调用; -n true 成功; -n /bin/sh -c CMD 在本机运行 CMD
[ "$1" = -n ] && shift
[ "$1" = true ] && exit 0
[ "$1" = -l ] && exit 0                  # sudo -n -l PATH: 只查规则 (测试里总是有免密规则), 不运行 PATH
echo "$*" >> "$RF_W/sudo.log"
[ -z "${RF_HOOK:-}" ] || eval "$RF_HOOK" # 用例可以在管理员命令运行之前改动暂存目录 (见 tests/enhanced-root-integrity.sh)
# 以 root 运行的固定路径改写成夹具里的路径: TUN 副本的目录 (/Library/Application Support/enana-UID)、助手目录 (/Library/PrivilegedHelperTools) 和旧位置 (/usr/local)
args=(); for a in "$@"; do args+=("$(printf '%s' "$a" | sed -e "s|/Library/Application Support/enana-$(id -u)|$RF_ROOT|g" -e "s|/Library/PrivilegedHelperTools|$RF_W/Library/PrivilegedHelperTools|g" -e "s|/usr/local|$RF_W/usr/local|g" -e "s|/usr/bin/env -i PATH=|/usr/bin/env -i RF_W=$RF_W RF_ROOT=$RF_ROOT ENANA_TEST=1 ENANA_TUN_ROOT=$RF_ROOT ENANA_ROOT_PREFIX=$RF_W ENANA_TUN_LAUNCHCTL=$RF_W/bin/launchctl ENANA_TUN_PLIST_DIR=$RF_W/daemons PATH=|g")"); done
set -- "${args[@]}"
exec "$@"
MOCK
  printf '#!/bin/sh\n[ "$1" = check ]\n' > "$W/sing-box"
  chmod +x "$W/bin/"* "$W/fakebin/sudo" "$W/sing-box"
  printf '%s\n' '{"log":{"level":"info","output":"'"$H"'/sing-box.log"},"inbounds":[{"type":"tun","tag":"tun-in"}],"route":{"rule_set":[{"type":"local","tag":"geo","path":"'"$H"'/rules/geo/geo.srs"}],"final":"direct"},"experimental":{"cache_file":{"enabled":true,"path":"'"$H"'/cache.db"}}}' > "$H/config.json"
  printf 'SRS' > "$H/rules/geo/geo.srs"
  cp "$W/sing-box" "$H/sing-box"
  # 核心来源 / 摘要记录 (6.1 / 6.2): 夹具里的核心是"官方钉死版本"的
  printf 'pinned 1.12.0 %s\n' "$(shasum -a 256 "$H/sing-box" | awk '{print $1}')" > "$H/core-provenance"
  shasum -a 256 "$H/sing-box" | awk '{print $1}' > "$H/core-binary.sha256"
  export RF_W=$W RF_ROOT=$ROOT ENANA_TEST=1 ENANA_TUN_ROOT="$ROOT" ENANA_TUN_PLIST_DIR="$W/daemons" ENANA_ROOT_PREFIX="$W" ENANA_TUN_LAUNCHCTL="$W/bin/launchctl"
  export PATH="$W/fakebin:$PATH"
  rf_ns_reset
  rf_load_enana
}
# ---- 假的网络服务 (系统 DNS 的接管 / 还原, 见 lib/enhanced-root.sh 的 DNS_PL) ----
rf_ns_reset() { # 回到初始状态: 每行 序号 (停用的是 *) · 设备 (VPN 没有) · 硬件端口 · 原来的 DNS · 名字
  printf '%s\t%s\t%s\t%s\t%s\n' \
    1 en0 Wi-Fi Empty Wi-Fi \
    2 en7 'USB 10/100/1000 LAN' '192.168.1.1 fe80::1%en0' 'USB 10/100/1000 LAN' \
    3 bridge0 'Thunderbolt Bridge' Empty 'Thunderbolt 网桥 ✓' \
    4 en8 'Ethernet Adapter (en8)' 9.9.9.9 'Ethernet Adapter (en8)' \
    5 en9 Ethernet Empty "$NS_ODD" \
    '*' en5 'Bluetooth PAN' 8.8.4.4 'Bluetooth PAN' \
    6 '' com.wireguard.macos Empty 'Corp VPN' > "$W/ns.tsv"
  rm -f "$W/ns-fail" "$W/ns-canary" "$W/ns.tsv.new"; : > "$W/ns.log"
}
rf_dns() { # <服务名> -> 它现在的 DNS (Empty 或空格分隔的地址; 没有这个服务: 空)
  /usr/bin/perl -e 'open my $f, "<", $ARGV[0] or exit 1; while (my $l = <$f>) { chomp $l; my @c = split /\t/, $l, 5; if (defined $c[4] && $c[4] eq $ARGV[1]) { print $c[3]; exit 0 } } exit 1' "$W/ns.tsv" "$1"
}
rf_dns_user() { # <服务名> <Empty | 地址…>: 模拟用户自己在系统设置里改了这个服务的 DNS (不记进 ns.log)
  local s=$1; shift; RF_NS_QUIET=1 "$W/bin/networksetup" -setdnsservers "$s" "$@" >/dev/null
}
rf_rec() { # root 的 DNS 记录 ($ROOT/dns-original), 每行「名字=原来的设置」(名字从十六进制还原; 没有记录: 空)
  [ -f "$ROOT/dns-original" ] || return 0
  /usr/bin/perl -ne 'chomp; my ($h, $v) = split / /, $_, 2; print pack("H*", $h), "=", $v, "\n"' "$ROOT/dns-original"
}
rf_ns_original() { # 0 = 每个服务都是初始的 DNS (接管之前的样子; 手动的地址按原来的顺序)
  [ "$(rf_dns Wi-Fi)" = Empty ] && [ "$(rf_dns 'USB 10/100/1000 LAN')" = '192.168.1.1 fe80::1%en0' ] && [ "$(rf_dns 'Thunderbolt 网桥 ✓')" = Empty ] \
    && [ "$(rf_dns 'Ethernet Adapter (en8)')" = 9.9.9.9 ] && [ "$(rf_dns "$NS_ODD")" = Empty ] && [ "$(rf_dns 'Bluetooth PAN')" = 8.8.4.4 ] && [ "$(rf_dns 'Corp VPN')" = Empty ]
}
rf_ns_taken() { # 0 = 启用的、有网卡的五个服务都是 223.5.5.5, 停用的和 VPN 原样
  local s
  for s in Wi-Fi 'USB 10/100/1000 LAN' 'Thunderbolt 网桥 ✓' 'Ethernet Adapter (en8)' "$NS_ODD"; do [ "$(rf_dns "$s")" = 223.5.5.5 ] || return 1; done
  [ "$(rf_dns 'Bluetooth PAN')" = 8.8.4.4 ] && [ "$(rf_dns 'Corp VPN')" = Empty ]
}
rf_ns_untouched() { ! grep -qE "$(printf '\t')(Bluetooth PAN|Corp VPN)($(printf '\t')|\$)" "$W/ns.log"; }   # 停用的和 VPN 从没出现在任何一次调用里 (连查询都没有)
rf_ns_sets() { grep -c '^-setdnsservers' "$W/ns.log"; }                                                         # -setdnsservers 调用的次数
rf_load_enana() { # 只加载 enana 这一侧的函数 (不跑 install.sh / common.sh 的初始化)
  test_env() { local v=''; [ -n "${ENANA_TEST:-}" ] && v=${!1:-}; printf '%s' "${v:-${2:-}}"; }
  _t() { printf '%s' "$1"; }
  clash() { printf '{"proxies":{}}'; }
  logs_rotate() { :; }
  enhanced_supported() { return 0; }
  enhanced_restore_selectors() { :; }
  LABEL=com.enana.proxy; AUTOSTART=1; LIB=$LIBT; SB=$H/sing-box; PORT=37890
  . "$LIBT/enhanced.sh"
  sb_ver() { SB_MAJOR=1; SB_MINOR=14; }         # 核心版本检查在 lib/config.sh; 这里假定核心够新
  . "$RF_REPO/lib/os-darwin.sh"                 # os_helper_trusted: 只定义函数, 没有副作用
}
rf_reset() { # 每个用例前: 回到"已经装过"之前的干净状态 (沙箱里的 /Library 重新建成 755、没有 ACL, 里面什么都没有)
  rm -rf "$ROOTB"/* "$W/daemons"/* "$W/sudoers.d"/* "$W/usr" "$W/Library" "$W/calls" "$W/sudo.log" "$W/loaded" "$W/fail-bootstrap" "$W/stage.path" "$W/last.cmd" 2>/dev/null
  mkdir -p "$W/usr/local" "$ROOT"; mkdir -m 755 "$W/Library"; : > "$W/calls"; : > "$W/sudo.log"
  unset RF_HOOK
  rf_ns_reset                                      # 网络服务的 DNS 也回到接管之前 (否则上一个用例的 223.5.5.5 会被当成「原来的设置」记下来)
}
# enana 的 TUN 启动 (和 os_service_start 调的是同一个函数); stage 路径记在 $W/stage.path, 用例可以在管理员调用之前改动它 (HOOK)
mktemp() { if [ "${1:-}" = -d ]; then local d; d=$(command mktemp -d "$W/stg.XXXXXX") && printf '%s\n' "$d" > "$W/stage.path" && printf '%s\n' "$d"; else command mktemp "$@"; fi; }
rf_enana_start() {
  ( enhanced_start ) >"$W/start.out" 2>&1; local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "  (enhanced_start 退出码 $rc, 输出:)"; sed 's/^/    | /' "$W/start.out" | tail -60
    for f in "$H/enhanced-check.log" "$H/check.log"; do [ -f "$f" ] && { echo "  ($f:)"; sed 's/^/    | /' "$f" | tail -20; }; done
    echo "  (诊断) TUN_ROOT=$ROOT H=$H"
    echo "  (诊断) 原始配置:"; sed 's/^/    cfg| /' "$H/config.json" 2>&1 | head -c 1500; echo
    enhanced_stage_config "$H/config.json" "$H" "$ROOT" > "$W/diag-staged.json" 2>"$W/diag-staged.err"
    echo "  (诊断) 改写后 (rc=$?, err=$(head -c 300 "$W/diag-staged.err")):"; sed 's/^/    st| /' "$W/diag-staged.json" | head -c 1500; echo
    echo "  (诊断) 检查器对改写结果:"; /bin/bash "$LIBT/enhanced-root.sh" check-config "$W/diag-staged.json" "$ROOT" 2>&1 | sed 's/^/    chk| /'
  fi
  return "$rc"
}
rf_admin_calls() { wc -l < "$W/sudo.log" 2>/dev/null | tr -d ' '; }
