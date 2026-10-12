#!/bin/bash
# enana 的 root 脚本 (TUN 的安装 / 停止 / 删除)。只在管理员授权之后运行; 所有参数都是数据, 不是代码:
#   · 不读 settings.env, 不 eval, 不运行用户目录里的任何文件, 不接受路径 / 标签 / 程序名字 (路径全部写死在下面)。
#   · 入口 (第一个参数):
#       inband SHA ACTION…   安装, 以及还没装过 root 副本时的停止 / 删除。脚本本身由 enana 以 base64 放进参数,
#                            由包装命令写进只有 root 能进的临时目录, 这里先核对 SHA 再继续。
#       root ACTION UID      停止 / 删除: 只运行已经装好的 ROOT/bin/enhanced-root.sh (root 写的、0700), 不运行 enana 目录里的副本。
#       check-config FILE ROOT  不需要 root: enana 预检用, 和安装时用的是同一段检查代码。
#   · 拒绝时只向标准错误输出一行 'enana-root: refused: 原因': 2 用法 / 参数 / 不是 root / root 副本不可信, 3 完整性校验不通过,
#     4 配置或 sing-box check 不通过。拒绝都发生在改动任何正在运行的东西之前; 1 = 启动失败, 已回滚。
# 由 enana 在一次管理员授权里安装 (lib/enhanced.sh), 卸载时一并删除。
# 下面几行的值是测试替换的 (tests/enhanced-root-integrity.sh 复制一份再替换); 生产里就是这些值。
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 077
unset ENV BASH_ENV PERL5OPT PERL5LIB PERLLIB PERL5DB
root_base="/Library/Application Support"
usr_local="/usr/local"; libexec="$usr_local/libexec/enana"; sudoers_dir="/etc/sudoers.d"
launchctl_bin="/bin/launchctl"        # 助手 restart 动作里写死的 launchctl
root_owner=0

refuse() { printf 'enana-root: refused: %s\n' "$2" >&2; exit "$1"; }
sha_of() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
is_sha() { case $1 in *[!0-9a-f]*) return 1 ;; esac; [ "${#1}" = 64 ]; }
is_num() { case $1 in ''|*[!0-9]*) return 1 ;; esac; }
# 字节只通过一个描述符读取, 写出去的就是被校验的那份 (O_NOFOLLOW 拒绝链接; O_NONBLOCK 让 FIFO 立刻失败, 不会卡住 root)
COPY_PL='my ($src,$dst,$want)=@ARGV;
sysopen(my $in,$src,O_RDONLY|O_NOFOLLOW|O_NONBLOCK) or exit 3; -f $in or exit 3;
sysopen(my $out,$dst,O_WRONLY|O_CREAT|O_EXCL,0600) or exit 3;
my $d=Digest::SHA->new(256); my $buf;
while (my $n=sysread($in,$buf,65536)) { $d->add($buf); my $o=0; while ($o<$n) { my $w=syswrite($out,$buf,$n-$o,$o); exit 3 unless $w; $o+=$w } }
close $out or exit 3;
if ($d->hexdigest ne $want) { unlink $dst; exit 3 }
exit 0'
verify_copy() { /usr/bin/perl -MFcntl=O_RDONLY,O_WRONLY,O_CREAT,O_EXCL,O_NOFOLLOW,O_NONBLOCK -MDigest::SHA -e "$COPY_PL" "$1" "$2" "$3"; }
b64_to_file() { printf '%s' "$1" > "$2.b64" && /usr/bin/base64 -D < "$2.b64" > "$2" && /bin/rm -f "$2.b64"; }
# 规则助手的渲染: enana 的 enhanced_helper_render 直接取用这段函数的原文 (见 lib/enhanced.sh), 两边的字节必须一样
helper_render() {
  R=$1 RU=$2 L=$3 C=$4 V=$5 /usr/bin/perl -pe 's/\@ROOT\@/$ENV{R}/g; s/\@ROOTUID\@/$ENV{RU}/g; s/\@LABEL\@/$ENV{L}/g; s/\@LAUNCHCTL\@/$ENV{C}/g; s/\@VERSION\@/$ENV{V}/g'
}
# 配置里的路径检查 (安装和 enana 预检共用): 文件类的键 (名字以 _path / _file / _dir / _directory 结尾, 以及 output、data_directory,
# 还有 local / hosts 类型对象里的 path) 的值必须在 $root 之下 (每一段都是安全的文件名); 证书 (certificate_path) 还要在 certs/ 里并列出引用;
# 禁止 experimental.clash_api.external_ui 和 shadowsocks 的 plugin (那是要运行的程序); 任何字符串值不能以 / 开头又含 ..
# 不靠列出的键名: 新的文件类键会被默认拒绝。输出配置引用到的快照文件 (rules/X/Y、certs/NAME), 每行一个; 不通过: 退出 4
CONFIG_PL='use strict; use warnings; use JSON::PP;
my ($file,$root)=@ARGV;
sub bad { print STDERR "enana-root: refused: config-path: $_[0]\n"; exit 4 }
bad("root") unless defined $root && $root =~ m{^/[^\0]+$} && $root !~ m{(?:^|/)\.\.?(?:/|$)};
open(my $fh,"<",$file) or bad("unreadable");
my $raw = do { local $/; <$fh> };
my $doc = eval { JSON::PP->new->utf8->decode($raw) };
bad("invalid-json") unless ref $doc eq "HASH";
my %refs;
sub comp_ok { my $c=shift; return defined $c && $c =~ /\A[A-Za-z0-9._-]+\z/ && $c ne "." && $c ne ".." }
sub under_root {
  my ($v)=@_;
  return 0 if ref $v || !defined $v || index($v,"$root/") != 0;
  my $rest = substr($v, length($root)+1);
  return 0 unless length $rest;
  for my $c (split m{/}, $rest, -1) { return 0 unless comp_ok($c) }
  return 1;
}
my $log = $doc->{log};
bad("/log/output") if ref $log eq "HASH" && exists $log->{output} && !under_root($log->{output});
my $exp = $doc->{experimental};
if (ref $exp eq "HASH") {
  my $cf = $exp->{cache_file};
  bad("/experimental/cache_file/path") if ref $cf eq "HASH" && exists $cf->{path} && !under_root($cf->{path});
  my $api = $exp->{clash_api};
  bad("/experimental/clash_api/external_ui") if ref $api eq "HASH" && exists $api->{external_ui};
}
my $route = $doc->{route};
if (ref $route eq "HASH" && ref $route->{rule_set} eq "ARRAY") {
  my $i = 0;
  for my $e (@{ $route->{rule_set} }) {
    my $p = "/route/rule_set/$i"; $i++;
    next unless ref $e eq "HASH" && defined $e->{type} && !ref $e->{type} && $e->{type} eq "local";
    my $v = $e->{path};
    bad("$p/path") if ref $v || !defined $v || index($v,"$root/rules/") != 0;
    my @c = split m{/}, substr($v, length("$root/rules/")), -1;
    bad("$p/path") unless @c == 2 && comp_ok($c[0]) && comp_ok($c[1]);
    $refs{"rules/$c[0]/$c[1]"} = 1;
  }
}
sub tls_check {
  my ($t,$p)=@_;
  if (exists $t->{certificate_path}) {
    my $v = $t->{certificate_path};
    bad("$p/certificate_path") if ref $v || !defined $v || index($v,"$root/certs/") != 0;
    my $name = substr($v, length("$root/certs/"));
    bad("$p/certificate_path") unless $name =~ /\A[A-Za-z0-9._-]{1,40}\.crt\z/;
    $refs{"certs/$name"} = 1;
  }
  bad("$p/key_path") if exists $t->{key_path} && !under_root($t->{key_path});
  if (ref $t->{ech} eq "HASH" && exists $t->{ech}{key_path}) { bad("$p/ech/key_path") unless under_root($t->{ech}{key_path}) }
}
# 文件类的键 (见上面的注释): 本身的值在 $root 之下; local / hosts 类型对象里的 path 同样是文件 (transport、dns 的 path 是 URL 路径, 不查)
sub file_key {
  my ($k,$parent)=@_;
  return 1 if $k =~ /_(?:path|file|dir|directory)\z/ || $k eq "output" || $k eq "data_directory";
  return 1 if $k eq "path" && defined $parent->{type} && !ref $parent->{type} && $parent->{type} =~ /\A(?:local|hosts)\z/;
  return 0;
}
sub walk {
  my ($n,$p)=@_;
  if (ref $n eq "HASH") {
    for my $k (sort keys %$n) {
      my $v = $n->{$k}; my $q = "$p/$k";
      tls_check($v,$q) if $k eq "tls" && ref $v eq "HASH";
      bad($q) if $k eq "external_ui";
      bad($q) if $k eq "plugin" && (ref($v) || (defined $v && $v ne ""));
      bad($q) if !ref($v) && file_key($k,$n) && !under_root($v);
      walk($v,$q);
    }
  } elsif (ref $n eq "ARRAY") {
    for my $i (0 .. $#$n) { walk($n->[$i], "$p/$i") }
  } elsif (defined $n && !ref $n) {
    bad($p) if substr($n,0,1) eq "/" && grep { $_ eq ".." } split m{/}, $n;
  }
}
walk($doc,"");
print "$_\n" for sort keys %refs;
exit 0'
config_check() { /usr/bin/perl -MJSON::PP -e "$CONFIG_PL" "$1" "$2"; }
# 清单: 每行 "摘要两个空格路径", 路径只能是 rules/目录/文件 或 certs/名字.crt (3.4 的格式); 有错就拒绝, 原样输出合格的行
MANIFEST_PL='use strict; use warnings;
open(my $fh,"<",$ARGV[0]) or exit 3;
my %seen;
while (my $line = <$fh>) {
  chomp $line;
  unless ($line =~ m{\A([0-9a-f]{64})  ((?:rules/[A-Za-z0-9_][A-Za-z0-9._-]*/[A-Za-z0-9_][A-Za-z0-9._-]*)|(?:certs/[A-Za-z0-9._-]{1,40}\.crt))\z}) { print STDERR "enana-root: refused: entry-name\n"; exit 3 }
  my ($sha,$rel) = ($1,$2);
  if ($rel =~ /\.(?:new|tmp)\z/ || $seen{$rel}++) { print STDERR "enana-root: refused: entry-name\n"; exit 3 }
  print "$sha  $rel\n";
}
exit 0'
# 把配置里的 ROOT 换成临时目录, 只用来让 sing-box check 读到校验过的文件 (和旧版一样)
REPLACE_PL='local $/; open(my $fh,"<",$ARGV[0]) or exit 4; my $s=<$fh>; my ($r,$w)=@ARGV[1,2]; $s =~ s/\Q$r\E/$w/g; print $s'

# 目录链 /usr/local、/usr/local/libexec、$libexec 都必须是真目录、不是链接、归 root、组 / 其他人不可写; 缺的 libexec 和 enana 在这里建 (755), 已有的不改属主
libexec_ok() {
  local d p
  for d in "$usr_local/libexec" "$libexec"; do
    if [ ! -e "$d" ] && [ ! -L "$d" ]; then /bin/mkdir -m 755 "$d" && /usr/sbin/chown root:wheel "$d" || return 1; fi
  done
  for d in "$usr_local" "$usr_local/libexec" "$libexec"; do
    [ -d "$d" ] && [ ! -L "$d" ] && [ "$(/usr/bin/stat -f %u "$d")" = "$root_owner" ] || return 1
    p=$(/usr/bin/stat -f %Sp "$d") && [ "${p:5:1}" != w ] && [ "${p:8:1}" != w ] || return 1
  done
}
helper_remove() { /bin/rm -f "$libexec/tunrules-$uid" "$sudoers_dir/enana-tunrules-$uid"; }

root=''; plist=''; label=''; uid=''; agent=''; work=''; backup=''; self_dir=''; self_sha=''
changed=0; committed=0; helper_state=0; had_root=0; had_gui=0; gui_plist=''
cleanup() {
  local rc=$?
  if [ "$changed" = 1 ] && [ "$committed" = 0 ]; then
    "$launchctl_bin" bootout "system/$label" 2>/dev/null || true
    for name in sing-box config.json rules certs bin; do
      /bin/rm -rf "$root/$name"
      [ ! -e "$backup/$name" ] || /bin/mv "$backup/$name" "$root/$name"
    done
    /bin/rm -f "$plist"
    if [ -e "$backup/daemon.plist" ]; then
      /bin/mv "$backup/daemon.plist" "$plist"
      if [ "$had_root" = 1 ]; then
        "$launchctl_bin" enable "system/$label" || true
        "$launchctl_bin" bootstrap system "$plist" || true
        "$launchctl_bin" kickstart "system/$label" || true
      else "$launchctl_bin" disable "system/$label" || true; fi
    fi
    if [ "$helper_state" = 1 ]; then
      helper_remove
      [ ! -e "$backup/helper" ] || /bin/mv "$backup/helper" "$libexec/tunrules-$uid"
      [ ! -e "$backup/sudoers" ] || /bin/mv "$backup/sudoers" "$sudoers_dir/enana-tunrules-$uid"
    fi
    if [ "$had_gui" = 1 ]; then
      "$launchctl_bin" asuser "$uid" "$launchctl_bin" enable "gui/$uid/$agent" || true
      "$launchctl_bin" asuser "$uid" "$launchctl_bin" bootstrap "gui/$uid" "$gui_plist" || true
      "$launchctl_bin" asuser "$uid" "$launchctl_bin" kickstart "gui/$uid/$agent" || true
    fi
  fi
  [ -z "$work" ] || /bin/rm -rf "$work"
  [ -z "$backup" ] || /bin/rm -rf "$backup"
  [ -z "$self_dir" ] || /bin/rm -rf "$self_dir"
  exit "$rc"
}
trap cleanup EXIT

mode=${1:-}
case $mode in
  check-config) config_check "${2:-}" "${3:-}"; exit $? ;;
  inband|root) ;;
  *) refuse 2 usage ;;
esac
[ "$(/usr/bin/id -u)" = 0 ] || refuse 2 not-root
if [ "$mode" = inband ]; then
  [ "$#" -ge 2 ] || refuse 2 bad-args
  self_sha=$2
  is_sha "$self_sha" || refuse 2 bad-args
  [ "$(sha_of "$0")" = "$self_sha" ] || refuse 3 script-digest
  self_dir=$(/usr/bin/dirname "$0")
  case ${self_dir##*/} in enana-root.*) ;; *) self_dir='' ;; esac          # 只删 enana 自己建的临时目录
  shift 2
else
  shift
fi
act=${1:-}; uid=${2:-}
shift "$(( $# < 2 ? $# : 2 ))"
is_num "$uid" || refuse 2 bad-args
root="$root_base/enana-$uid"; label="com.enana.proxy.tun.$uid"; plist="/Library/LaunchDaemons/$label.plist"
if [ "$mode" = root ]; then
  case $act in stop|remove) ;; *) refuse 2 bad-action ;; esac
  [ "$0" = "$root/bin/enhanced-root.sh" ] && [ -f "$0" ] && [ ! -L "$0" ] && [ "$(/usr/bin/stat -f '%u %Lp' "$0")" = "$root_owner 700" ] || refuse 2 root-copy-untrusted
  [ ! -L "$root" ] && [ -d "$root/bin" ] && [ ! -L "$root/bin" ] && [ "$(/usr/bin/stat -f %u "$root")" = "$root_owner" ] && [ "$(/usr/bin/stat -f %u "$root/bin")" = "$root_owner" ] || refuse 2 root-copy-untrusted
fi
case $act in
  stop)
    "$launchctl_bin" disable "system/$label"
    "$launchctl_bin" bootout "system/$label" 2>/dev/null || true
    exit 0 ;;
  remove)
    # 删除要碰文件系统: 目录必须是真目录、归 root (和 root 模式的检查一样), 否则拒绝, 不顺着符号链接删到别处
    if [ -e "$root" ] || [ -L "$root" ]; then
      [ ! -L "$root" ] && [ -d "$root" ] && [ "$(/usr/bin/stat -f %u "$root")" = "$root_owner" ] || refuse 3 root-untrusted
    fi
    "$launchctl_bin" bootout "system/$label" 2>/dev/null || true
    "$launchctl_bin" enable "system/$label" 2>/dev/null || true
    /bin/rm -f "$plist"
    helper_remove
    /bin/rmdir "$libexec" 2>/dev/null || true
    if [ -d "$root" ]; then
      /usr/bin/find "$root" -mindepth 1 -maxdepth 1 ! -name bin -exec /bin/rm -rf {} +
      /bin/rm -rf "$root/bin"                                 # 正在运行的就是这个文件: 最后才删
      /bin/rm -rf "$root"
    fi
    exit 0 ;;
  install) [ "$mode" = inband ] || refuse 2 bad-action ;;
  *) refuse 2 bad-action ;;
esac

# ---- 安装 (4.1 参数, 4.2 暂存目录清点, 4.4 a-f) ----
stage=${1:-}; agent=${2:-}; autostart=${3:-}; username=${4:-}; hv=${5:-}
sha_sb=${6:-}; sha_cfg=${7:-}; sha_man=${8:-}; sha_tpl=${9:-}
[ "$#" -ge 11 ] || refuse 2 bad-args
shift 9
sha_out=${1:-}; b64_tpl=${2:-}
[ "$agent" = com.enana.proxy ] || refuse 2 bad-args
case $autostart in 0|1) ;; *) refuse 2 bad-args ;; esac
case $username in ''|*[!A-Za-z0-9._-]*) [ -z "$username" ] || refuse 2 bad-args ;; esac
is_num "$hv" || refuse 2 bad-args
for s in "$sha_sb" "$sha_cfg" "$sha_man" "$sha_tpl" "$sha_out"; do is_sha "$s" || refuse 2 bad-args; done
case $stage in /*) ;; *) refuse 2 bad-args ;; esac
case $stage in *[!A-Za-z0-9_./-]*) refuse 2 bad-args ;; esac
[ -d "$stage" ] && [ ! -L "$stage" ] || refuse 2 bad-args
[ -n "$b64_tpl" ] || refuse 2 bad-args
[ -z "$(/usr/bin/find "$stage" -type l -print)" ] || refuse 3 stage-link
[ -z "$(/usr/bin/find "$stage" ! -type d ! -type f -print)" ] || refuse 3 stage-extra

[ ! -L "$root" ] || refuse 3 root-link
[ ! -L "$plist" ] || refuse 3 plist-link
if [ -e "$root" ]; then
  [ "$(/usr/bin/stat -f %u "$root")" = "$root_owner" ] && [ -z "$(/usr/bin/find "$root" -type l -print)" ] || refuse 3 root-untrusted
fi
/bin/mkdir -p "$root"; /usr/sbin/chown root:wheel "$root"; /bin/chmod 711 "$root"
work=$(/usr/bin/mktemp -d "$root/.prepare.XXXXXX")
backup=$(/usr/bin/mktemp -d "$root/.rollback.XXXXXX")
"$launchctl_bin" print "system/$label" >/dev/null 2>&1 && had_root=1
if gui_info=$("$launchctl_bin" print "gui/$uid/$agent" 2>/dev/null); then
  had_gui=1
  gui_plist=$(printf '%s\n' "$gui_info" | /usr/bin/sed -n 's/^[[:space:]]*path = //p' | /usr/bin/head -1)
  [ -n "$gui_plist" ] && [ -f "$gui_plist" ] || refuse 2 gui-plist
fi

# b. 校验 (提交之前): 助手模板 -> 渲染 -> 配置 -> 清单 -> 快照文件 -> sing-box -> 脚本副本 -> sing-box check
b64_to_file "$b64_tpl" "$work/tpl" || refuse 3 helper-template-decode
[ "$(sha_of "$work/tpl")" = "$sha_tpl" ] || refuse 3 helper-template-digest
helper_render "$root" 0 "$label" "$launchctl_bin" "$hv" < "$work/tpl" > "$work/tunrules-helper" || refuse 3 helper-render
[ "$(sha_of "$work/tunrules-helper")" = "$sha_out" ] || refuse 3 helper-digest
/usr/bin/perl -c "$work/tunrules-helper" >/dev/null 2>&1 || /bin/rm -f "$work/tunrules-helper"      # 编译不过只是不装助手 (非致命)
verify_copy "$stage/config.json" "$work/config.json" "$sha_cfg" || refuse 3 config-digest
config_check "$work/config.json" "$root" > "$work/refs" || exit 4
verify_copy "$stage/manifest" "$work/manifest" "$sha_man" || refuse 3 manifest-digest
/usr/bin/perl -e "$MANIFEST_PL" "$work/manifest" > "$work/entries" || exit 3
present=$(cd "$stage" && /usr/bin/find . -type f | /usr/bin/sed 's|^\./||' | LC_ALL=C /usr/bin/grep -Ev '^(sing-box|config\.json|manifest|selectors\.json)$' | LC_ALL=C /usr/bin/sort)
listed=$(/usr/bin/awk '{print $2}' "$work/entries" | LC_ALL=C /usr/bin/sort)
[ "$present" = "$listed" ] || refuse 3 stage-extra
/bin/mkdir -p "$work/rules" "$work/certs"
while read -r sha rel; do
  [ -n "$rel" ] || continue
  /bin/mkdir -p "$work/${rel%/*}"
  verify_copy "$stage/$rel" "$work/$rel" "$sha" || refuse 3 entry-digest
done < "$work/entries"
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  /usr/bin/awk -v r="$ref" '$2 == r {found=1} END {exit !found}' "$work/entries" || refuse 4 ref-missing
done < "$work/refs"
verify_copy "$stage/sing-box" "$work/sing-box" "$sha_sb" || refuse 3 sing-box-digest
/bin/chmod 755 "$work/sing-box"
/bin/mkdir -m 711 "$work/bin"
verify_copy "$0" "$work/bin/enhanced-root.sh" "$self_sha" || refuse 3 script-digest
/bin/chmod 700 "$work/bin/enhanced-root.sh"
/usr/bin/perl -e "$REPLACE_PL" "$work/config.json" "$root" "$work" > "$work/check.json" || exit 4
"$work/sing-box" check -c "$work/check.json" || refuse 4 sing-box-check
/bin/rm -f "$work/check.json"

# c. 提交: 先备份现有的东西 (备份失败时还没有改动任何东西, 清理时不动现有的文件), 再停掉旧守护进程, 换入新文件
for name in sing-box config.json rules certs bin; do
  [ ! -e "$root/$name" ] || /bin/cp -Rp "$root/$name" "$backup/$name"
done
[ ! -e "$plist" ] || /bin/cp -p "$plist" "$backup/daemon.plist"
changed=1
"$launchctl_bin" bootout "system/$label" 2>/dev/null || true
"$launchctl_bin" asuser "$uid" "$launchctl_bin" disable "gui/$uid/$agent" 2>/dev/null || true
# 禁用一个已加载的 KeepAlive 任务不会卸载它; 直接 bootout 掉, 让 launchd 按新配置重新拉起
if [ "$had_gui" = 1 ]; then "$launchctl_bin" asuser "$uid" "$launchctl_bin" bootout "gui/$uid/$agent"; fi
for name in sing-box config.json rules certs; do
  /bin/rm -rf "$root/$name"; /bin/mv "$work/$name" "$root/$name"
done
/bin/rm -rf "$root/bin"; /bin/mv "$work/bin" "$root/bin"
# 日志文件归用户所有 (用户可以轮转它), 但目录归 root: 用户无法把它换成符号链接让 root 去写
[ ! -L "$root/sing-box.log" ] || exit 2
[ -e "$root/sing-box.log" ] || /usr/bin/touch "$root/sing-box.log"
/usr/sbin/chown "$uid" "$root/sing-box.log"; /bin/chmod 600 "$root/sing-box.log"

# d. 规则助手和免密规则 (提交之后, 不影响 TUN 本身): 目录链不合格或助手不能用时, 两个文件都删掉 (旧的也不留)
if [ -n "$username" ]; then
  helper_state=1
  [ ! -e "$libexec/tunrules-$uid" ] || /bin/cp -p "$libexec/tunrules-$uid" "$backup/helper"
  [ ! -e "$sudoers_dir/enana-tunrules-$uid" ] || /bin/cp -p "$sudoers_dir/enana-tunrules-$uid" "$backup/sudoers"
  if [ -f "$work/tunrules-helper" ] && libexec_ok && /bin/mkdir -p "$sudoers_dir" \
     && printf '%s ALL=(root) NOPASSWD: %s\n' "$username" "$libexec/tunrules-$uid" > "$work/sudoers" \
     && /usr/bin/install -m 755 -o root -g wheel "$work/tunrules-helper" "$libexec/tunrules-$uid" \
     && /usr/sbin/visudo -cf "$work/sudoers" >/dev/null 2>&1 \
     && /usr/bin/install -m 440 -o root -g wheel "$work/sudoers" "$sudoers_dir/enana-tunrules-$uid"; then :
  else helper_remove; echo 'enana-root: note: rule helper not installed' >&2; fi
fi

# e. 守护进程: plist 写死的路径, 装上并启动; 确认 IPv4 / IPv6 默认路由都进了我们的 utun 才算成功
run='<false/>'; [ "$autostart" = 1 ] && run='<true/>'
/bin/cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array><string>$root/sing-box</string><string>run</string><string>-c</string><string>$root/config.json</string><string>-D</string><string>$root</string></array>
<key>RunAtLoad</key>$run
<key>KeepAlive</key>$run
<key>StandardOutPath</key><string>$root/service.log</string>
<key>StandardErrorPath</key><string>$root/service.log</string>
</dict></plist>
PLIST
/usr/sbin/chown root:wheel "$plist"; /bin/chmod 600 "$plist"
"$launchctl_bin" enable "system/$label"
"$launchctl_bin" bootstrap system "$plist"
"$launchctl_bin" kickstart "system/$label"
n=0
while [ "$n" -lt 15 ]; do
  v4=$(/sbin/route -n get 1.1.1.1 2>/dev/null | /usr/bin/awk '/interface:/ {print $2}')
  v6=$(/sbin/route -n get -inet6 2606:4700:4700::1111 2>/dev/null | /usr/bin/awk '/interface:/ {print $2}')
  case $v4 in utun*)
    if [ "$v4" = "$v6" ] && /sbin/ifconfig "$v4" | /usr/bin/grep -q 'inet 172.19.0.1 ' && "$launchctl_bin" print "system/$label" | /usr/bin/grep -q 'pid = '; then
      committed=1; exit 0
    fi ;;
  esac
  n=$((n + 1)); /bin/sleep 1
done
echo 'TUN did not take ownership of IPv4/IPv6 routes; restored previous core' >&2
exit 1
