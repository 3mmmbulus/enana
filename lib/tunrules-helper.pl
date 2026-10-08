#!/usr/bin/perl
# enana TUN 规则同步助手 (版本 @VERSION@)。root 所有, 当前用户可以免密调用 (sudoers 里只开放了这一个文件), 只做一件事:
#   sync   从标准输入读一个 JSON 数据包 {"ovr-pin.json": {"version":3,"rules":[…]}, …}, 逐项严格校验, 全部通过才写进 root 快照里的规则集目录 (原地覆盖,
#          核心监视这些文件、自己热加载), 所以 TUN 下改「应用 / 网站的代理策略」不用重启核心, 也就不用再输入管理员密码。
#   restart  重启这个用户自己的 TUN 守护进程: 只执行 `launchctl kickstart -k system/@LABEL@`。标签和 launchctl 路径都是安装时由 root 脚本写死的, 不读任何参数 / 输入 /
#          环境变量, 所以不能用它去重启别的服务, 更不能运行别的东西。(核心和配置没有变化时用它代替完整安装, 重启核心不再弹管理员密码框。)
#   version
# 只认「应用 / 网站策略」那几个固定名字的规则集文件 (ovr-*.json) 和 4 种匹配键 (domain / domain_suffix / process_path_regex / process_name), 值只能是不含控制字符的字符串。
# 不接受路径、命令、环境变量、可执行文件或核心配置 (这些仍然只能走需要管理员授权的完整安装)。它处理的只是「路由规则数据」: 最坏的结果是这个用户自己的流量路由被改, 得不到 root 权限。
# restart 的最坏结果: 这个用户自己的 root 守护进程被重启一次 (流量中断几秒), 同样得不到 root 权限, 也改不了任何文件。
# 由 enana 在一次管理员授权里安装 (lib/enhanced-root.sh), 卸载时一并删除。版本 2 增加了 restart; 旧版本 (版本 1) 的助手会被 enana 判为「不可用」, 下一次完整安装 (一次管理员授权) 时替换。
use strict;
use warnings;
use JSON::PP;
use B qw(svref_2object SVp_IOK SVp_NOK SVp_POK);
use Fcntl qw(O_WRONLY O_CREAT O_NOFOLLOW);
$ENV{PATH} = '/usr/sbin:/usr/bin:/bin:/sbin';
delete @ENV{qw(ENV BASH_ENV PERL5LIB PERLLIB PERL5OPT)};

my $ROOT = '@ROOT@';          # 例: /Library/Application Support/enana-501 (安装时由 root 脚本写死)
my $ROOT_UID = @ROOTUID@;     # 目录必须归这个 uid (生产里是 0)
my $LABEL = '@LABEL@';        # 例: com.enana.proxy.tun.501 (这个用户的 TUN 守护进程; 安装时由 root 脚本写死)
my $LAUNCHCTL = '@LAUNCHCTL@'; # 生产里是 /bin/launchctl (安装时写死, 测试里换成假的)
my $VERSION = @VERSION@;
my $MAX_BYTES = 2_000_000;

my $cmd = shift(@ARGV) // '';
die "usage: tunrules sync|restart|version\n" if @ARGV || $cmd !~ /^(?:sync|restart|version)$/;
if ($cmd eq 'version') { print "$VERSION\n"; exit 0; }
die "root required\n" if $> != $ROOT_UID && $ROOT_UID == 0;

if ($cmd eq 'restart') {
  # 唯一的动作: kickstart -k 这一个写死的标签。没有 shell (列表形式 system), 没有参数、输入、环境变量可以改变它。
  die "bad label\n" unless $LABEL =~ /^com\.enana\.proxy\.tun\.[0-9]+$/;
  die "bad launchctl\n" unless $LAUNCHCTL =~ m{^/[A-Za-z0-9._/-]+$};
  my $rc = system { $LAUNCHCTL } 'launchctl', 'kickstart', '-k', "system/$LABEL";
  die "launchctl kickstart failed\n" if $rc != 0;
  print "restarted\n"; exit 0;
}

my $NAME_RE = qr/^ovr-(?:direct|appdirect|browserdirect|browserauto|browserpin|browserpinauto|pin|pinauto|apppin|apppinauto|auto)(?:-[0-9]{1,2})?\.json$/;
my %KEY_OK = map { $_ => 1 } qw(domain domain_suffix process_path_regex process_name);

binmode STDIN;
my $in = ''; my $n = read(STDIN, $in, $MAX_BYTES + 1);
die "empty input\n" unless $n;
die "input too large\n" if length($in) > $MAX_BYTES;
my $doc = eval { JSON::PP->new->utf8->max_depth(8)->decode($in) };
die "invalid JSON\n" unless ref $doc eq 'HASH' && keys %$doc && keys %$doc <= 60;

sub bad { die "rejected: $_[0]\n" }
# JSON 里的数字和字符串在 Perl 里只能靠内部标志区分, 而且任何字符串操作 (length / 正则) 都会让数字也带上字符串标志: 所以类型检查必须先做。
sub is_str { my $f = svref_2object(\$_[0])->FLAGS; return ($f & SVp_POK) && !($f & (SVp_IOK | SVp_NOK)); }
sub is_num { my $f = svref_2object(\$_[0])->FLAGS; return ($f & (SVp_IOK | SVp_NOK)) && !($f & SVp_POK); }
my %out;
for my $name (sort keys %$doc) {
  bad("file name") unless $name =~ $NAME_RE;
  my $rs = $doc->{$name};
  bad("rule set shape") unless ref $rs eq 'HASH' && keys(%$rs) == 2 && exists $rs->{version} && exists $rs->{rules};
  bad("version") unless !ref $rs->{version} && defined $rs->{version} && is_num($rs->{version}) && $rs->{version} == 3;
  my $rules = $rs->{rules};
  bad("rules") unless ref $rules eq 'ARRAY' && @$rules >= 1 && @$rules <= 8;
  my $total = 0;
  for my $r (@$rules) {
    bad("rule shape") unless ref $r eq 'HASH' && keys(%$r) == 1;
    my ($k) = keys %$r;
    bad("rule key") unless $KEY_OK{$k};
    my $vals = $r->{$k};
    bad("rule values") unless ref $vals eq 'ARRAY' && @$vals >= 1 && @$vals <= 5000;
    for my $v (@$vals) {
      bad("value type") if ref $v || !defined $v || !is_str($v);
      bad("value") if length($v) < 1 || length($v) > 400 || $v =~ /[\x00-\x1f\x7f]/;
    }
    $total += @$vals;
  }
  bad("too many entries") if $total > 20000;
  $out{$name} = JSON::PP->new->utf8->canonical->encode($rs) . "\n";
}

# 校验全部通过之后才开始写 (任何一项不合格, 一个文件都不会动)。目标目录必须是 root 自己的真实目录, 目标文件不能是符号链接。
my $dir = "$ROOT/rules";
my @st = lstat($dir);
die "no rules directory\n" unless @st && -d _ && !-l $dir && $st[4] == $ROOT_UID;
for my $name (sort keys %out) {
  my $path = "$dir/$name";
  if (lstat($path)) { die "refusing $name (not a regular file)\n" if -l _ || !-f _; }
  sysopen(my $fh, $path, O_WRONLY | O_CREAT | O_NOFOLLOW, 0600) or die "cannot open $name: $!\n";
  seek($fh, 0, 0);
  print {$fh} $out{$name} or die "cannot write $name\n";
  truncate($fh, length $out{$name}) or die "cannot truncate $name\n";     # 原地覆盖 (inode 不变), 核心的文件监视继续有效
  close($fh) or die "cannot close $name\n";
}
print scalar(keys %out), " files synced\n";
