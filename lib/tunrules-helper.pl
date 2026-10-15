#!/usr/bin/perl
# enana TUN 规则同步助手 (版本 @VERSION@)。root 所有, 当前用户可以免密调用 (sudoers 里只开放了这一个文件), 只做一件事:
#   sync   从标准输入读一个 JSON 数据包 {"ovr-pin.json": {"version":3,"rules":[…]}, …}, 逐项严格校验, 全部通过才写进 root 快照里的 rules/<名字>/ 目录 (原地覆盖,
#          核心监视这些文件、自己热加载), 所以 TUN 下改「应用 / 网站的代理策略」不用重启核心, 也就不用再输入管理员密码。
#   restart  重启这个用户自己的 TUN 守护进程: 只执行 `launchctl kickstart -k system/@LABEL@`。标签和 launchctl 路径都是安装时由 root 脚本写死的, 不读任何参数 / 输入 /
#          环境变量, 所以不能用它去重启别的服务, 更不能运行别的东西。(核心和配置没有变化时用它代替完整安装, 重启核心不再弹管理员密码框。)
#   version
# 只认两类文件:
#   · 「应用 / 网站策略」那几个固定名字的规则集文件 (ovr-*.json), 4 种匹配键 (domain / domain_suffix / process_path_regex / process_name), 值只能是不含控制字符的字符串。
#   · 网站的域名列表 site-<id>.json (id: 1–63 位小写字母 / 数字 / 连字符, 不以连字符开头; lib/catalog.awk 生成): 只有一条规则, 匹配键只能是 domain / domain_suffix,
#     每个值都必须是合法的域名 (小写字母 / 数字 / 连字符组成的标签, 每段 ≤ 63, 总长 ≤ 253; domain_suffix 可以以一个点开头), 没有正则、路径或别的键。
#     而且只覆盖 root 快照里已经有的文件 (完整安装时 root 核对过、配置引用到的那些): 不新建目录或文件, 所以名字再多也写不满磁盘。
# 不接受路径、命令、环境变量、可执行文件或核心配置 (这些仍然只能走需要管理员授权的完整安装)。它处理的只是「路由规则数据」: 最坏的结果是这个用户自己的流量路由被改, 得不到 root 权限。
# restart 的最坏结果: 这个用户自己的 root 守护进程被重启一次 (流量中断几秒), 同样得不到 root 权限, 也改不了任何文件。
# 由 enana 在一次管理员授权里安装 (lib/enhanced-root.sh), 卸载时一并删除。版本 2 增加了 restart, 版本 3 改为每个规则集文件一个目录, 版本 4 增加了 cleanup, 版本 5 增加了网站的域名列表;
# 旧版本 (版本 1–4) 的助手会被 enana 判为「不可用」, 下一次完整安装 (一次管理员授权) 时替换。
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
my $MAX_FILES = 160;          # 一次最多同步多少个策略规则集文件 (必须 >= 12 + 3 * lib/apps.sh 的 OVR_PIN_MAX; 升级前安装的旧助手上限是 60, 固定出口超过 16 个时它会拒绝, 退回完整安装)
my $MAX_SITE_FILES = 400;     # 另外最多多少个网站的域名列表 (目录里每个网站一个; 超过就拒绝, enana 退回完整安装)

my $cmd = shift(@ARGV) // '';
die "usage: tunrules sync|restart|cleanup|version\n" if @ARGV || $cmd !~ /^(?:sync|restart|cleanup|version)$/;
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

sub run_out { my @cmd = @_; open(my $p, '-|', @cmd) or return ''; local $/; my $o = <$p>; close $p; return defined $o ? $o : ''; }
sub route_args {
  my ($fam, $dst) = @_;
  my ($addr, $len) = split m{/}, $dst, 2;
  if ($fam eq 'inet') {
    my @o = split /\./, $addr;
    return unless $addr =~ /^[0-9]{1,3}(?:\.[0-9]{1,3}){0,3}$/ && !grep { $_ > 255 } @o;
    return ('-net', join('.', @o, (0) x (4 - @o)) . "/$len") if defined $len && $len =~ /^[0-9]{1,2}$/ && $len <= 32;
    return ('-host', $addr) if !defined $len && @o == 4;
    return;
  }
  return unless $addr =~ /^[0-9a-fA-F]*:[0-9a-fA-F:]*$/;
  return ('-inet6', "$addr/$len") if defined $len && $len =~ /^[0-9]{1,3}$/ && $len <= 128;
  return ('-inet6', '-host', $addr) if !defined $len;
  return;
}
if ($cmd eq 'cleanup') {
  # 只删 TUN 留下的残留路由: 网关必须是 enana 的 TUN 地址, 接口必须是 utunN 且没有 IPv4 地址 (还在用的 utun 一定有 172.19.0.x),
  # 并且这个用户的守护进程和它的核心都不在运行。任何一项不满足就什么都不删。
  die "bad label\n" unless $LABEL =~ /^com\.enana\.proxy\.tun\.[0-9]+$/;
  die "bad launchctl\n" unless $LAUNCHCTL =~ m{^/[A-Za-z0-9._/-]+$};
  die "daemon running\n" if run_out($LAUNCHCTL, 'print', "system/$LABEL") =~ /\bpid = [0-9]+/;
  die "core running\n" if run_out('/bin/ps', '-axww', '-o', 'command=') =~ m{^\s*\Q$ROOT\E/sing-box(?:\s|$)}m;
  my %gw = map { $_ => 1 } qw(172.19.0.1 172.19.0.2 fdfe:dcba:9876::1 fdfe:dcba:9876::2);
  my (%seen, %v4, @routes);
  for my $fam (qw(inet inet6)) {
    for my $line (split /\n/, run_out('/usr/sbin/netstat', '-rn', '-f', $fam)) {
      my @f = split ' ', $line;
      next unless @f >= 4 && $gw{$f[1]} && $f[3] =~ /^utun[0-9]+$/;
      next if $seen{join "\0", $fam, @f[0, 1, 3]}++;
      push @routes, [$fam, @f[0, 1, 3]];
    }
  }
  my ($done, $fail, $kept) = (0, 0, 0);
  for my $r (@routes) {
    my ($fam, $dst, $via, $if) = @$r;
    $v4{$if} //= run_out('/sbin/ifconfig', $if) =~ /^\s+inet\s/m ? 1 : 0;
    if ($v4{$if}) { $kept++; next }
    my @a = route_args($fam, $dst) or do { $fail++; next };
    my $rc = system { '/sbin/route' } 'route', '-n', 'delete', @a, $via;
    $rc == 0 ? $done++ : $fail++;
  }
  print "removed $done, kept $kept, failed $fail\n";
  exit($fail ? 1 : 0);
}

my $NAME_RE = qr/\Aovr-(?:direct|appdirect|browserdirect|browserauto|browserpin|browserpinauto|pin|pinauto|apppin|apppinauto|appauto|auto)(?:-[0-9]{1,2})?\.json\z/;
my $SITE_RE = qr/\Asite-[a-z0-9][a-z0-9-]{0,62}\.json\z/;    # 网站的域名列表 (rules/site-<id>/site-<id>.json)
my %KEY_OK = map { $_ => 1 } qw(domain domain_suffix process_path_regex process_name);
my %SITE_KEY_OK = map { $_ => 1 } qw(domain domain_suffix);
# 合法的域名: 标签由小写字母 / 数字 / 连字符组成 (不以连字符开头或结尾), 每段 1–63, 总长 ≤ 253; domain_suffix 可以以一个点开头 (只匹配子域名)。和 lib/catalog.awk 的 okname 一致
sub name_ok { my ($v, $sfx) = @_; $v =~ s/\A\.// if $sfx; return length($v) <= 253 && $v =~ /\A(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/; }

binmode STDIN;
my $in = ''; my $n = read(STDIN, $in, $MAX_BYTES + 1);
die "empty input\n" unless $n;
die "input too large\n" if length($in) > $MAX_BYTES;
my $doc = eval { JSON::PP->new->utf8->max_depth(8)->decode($in) };
die "invalid JSON\n" unless ref $doc eq 'HASH' && keys %$doc;
# 12 个固定名字 + 每个固定出口 3 个 (网站 / 应用 / 浏览器): OVR_PIN_MAX=32 个出口 = 108 个, 上限 160 留出余量; 网站的域名列表另算 (名字以 site- 开头的都算这一类)
my $n_site = grep { /\Asite-/ } keys %$doc;
die "too many files\n" if keys(%$doc) - $n_site > $MAX_FILES || $n_site > $MAX_SITE_FILES;

sub bad { die "rejected: $_[0]\n" }
# JSON 里的数字和字符串在 Perl 里只能靠内部标志区分, 而且任何字符串操作 (length / 正则) 都会让数字也带上字符串标志: 所以类型检查必须先做。
sub is_str { my $f = svref_2object(\$_[0])->FLAGS; return ($f & SVp_POK) && !($f & (SVp_IOK | SVp_NOK)); }
sub is_num { my $f = svref_2object(\$_[0])->FLAGS; return ($f & (SVp_IOK | SVp_NOK)) && !($f & SVp_POK); }
my %out;
for my $name (sort keys %$doc) {
  my $site = $name =~ $SITE_RE ? 1 : 0;
  bad("file name") unless $site || $name =~ $NAME_RE;
  my $rs = $doc->{$name};
  bad("rule set shape") unless ref $rs eq 'HASH' && keys(%$rs) == 2 && exists $rs->{version} && exists $rs->{rules};
  bad("version") unless !ref $rs->{version} && defined $rs->{version} && is_num($rs->{version}) && $rs->{version} == 3;
  my $rules = $rs->{rules};
  bad("rules") unless ref $rules eq 'ARRAY' && @$rules >= 1 && @$rules <= ($site ? 1 : 8);
  my $total = 0;
  for my $r (@$rules) {
    bad("rule shape") unless ref $r eq 'HASH' && keys(%$r) == 1;
    my ($k) = keys %$r;
    bad("rule key") unless $site ? $SITE_KEY_OK{$k} : $KEY_OK{$k};
    my $vals = $r->{$k};
    bad("rule values") unless ref $vals eq 'ARRAY' && @$vals >= 1 && @$vals <= 5000;
    for my $v (@$vals) {
      bad("value type") if ref $v || !defined $v || !is_str($v);
      bad("value") if length($v) < 1 || length($v) > 400 || $v =~ /[\x00-\x1f\x7f]/;
      bad("domain name") if $site && !name_ok($v, $k eq 'domain_suffix');
    }
    $total += @$vals;
  }
  bad("too many entries") if $total > 20000;
  $out{$name} = JSON::PP->new->utf8->canonical->encode($rs) . "\n";
}

# 先检查全部目标 (子目录和文件都不能是符号链接, 子目录必须归 root), 全部通过才开始写: 任何一项不合格, 一个文件都不会动。rules 必须是 root 自己的真实目录。
# 网站的域名列表只覆盖快照里已经有的文件 (目录和文件都必须已经在): 完整安装放进去的就是配置引用到的那些, 助手不新建
my $dir = "$ROOT/rules";
my @st = lstat($dir);
die "no rules directory\n" unless @st && -d _ && !-l $dir && $st[4] == $ROOT_UID;
my %target;
for my $name (sort keys %out) {
  (my $stem = $name) =~ s/\.json\z//;
  my $sub = "$dir/$stem";
  if (my @s = lstat($sub)) { die "refusing $stem (not a directory)\n" if -l _ || !-d _ || $s[4] != $ROOT_UID; }
  elsif ($name =~ $SITE_RE) { die "refusing $name (not in the snapshot)\n"; }
  my $path = "$sub/$name";
  if (lstat($path)) { die "refusing $name (not a regular file)\n" if -l _ || !-f _; }
  elsif ($name =~ $SITE_RE) { die "refusing $name (not in the snapshot)\n"; }
  $target{$name} = [$sub, $path];
}
for my $name (sort keys %out) {
  my ($sub, $path) = @{$target{$name}};
  unless (lstat($sub)) { mkdir($sub, 0755) or die "cannot create a directory for $name: $!\n"; }
  sysopen(my $fh, $path, O_WRONLY | O_CREAT | O_NOFOLLOW, 0600) or die "cannot open $name: $!\n";
  seek($fh, 0, 0);
  print {$fh} $out{$name} or die "cannot write $name\n";
  truncate($fh, length $out{$name}) or die "cannot truncate $name\n";     # 原地覆盖 (inode 不变), 核心的文件监视继续有效
  close($fh) or die "cannot close $name\n";
}
print scalar(keys %out), " files synced\n";
