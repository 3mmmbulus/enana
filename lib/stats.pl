#!/usr/bin/perl
# 流量统计 (仪表盘「流量」页): 周期性采样核心的 /connections, 累加到 按小时 / 按天 / 按节点 的本地桶里; 只保留 3 个月。
# 用法:
#   curl …/connections | perl stats.pl collect <统计目录> <roles 文件> <默认类别 direct|auto>   (每分钟一次, 由 `enana tick` 调用)
#   perl stats.pl report  <统计目录> <today|3d|7d|30d|90d>                                       打印 JSON (GET /api/stats)
#   perl stats.pl purge   <统计目录>                                                              清理过期数据
# 文件 (都在统计目录里, 纯本机数据, 不上传):
#   daily.tsv   日期 up down direct_up direct_down pin_up pin_down auto_up auto_down      (保留 92 天)
#   hourly.tsv  日期 小时 up down direct pin auto                                         (保留 72 小时, 供「今日」按小时画图)
#   nodes.tsv   日期 节点 up down                                                         (保留 92 天)
#   state.json  上一次采样的累计值与每条连接的字节数 (用来算增量)
# 精度说明: 总量来自核心的累计计数 (准确); 分类 (直连 / 固定出口 / 自动线路 / 各节点) 来自采样时仍在的连接, 两次采样之间已经结束的短连接
# 按当时的分类比例分摊 (估算)。核心重启后计数会清零, 脚本自动识别并从新计数开始。
use strict; use warnings;
use JSON::PP; use POSIX qw(strftime);
my ($cmd, $dir, @rest) = @ARGV;
die "usage: stats.pl collect|report|purge <dir> ...\n" unless $cmd && $dir;
my $KEEP_DAYS = 92; my $KEEP_HOURS = 72;
my $now = $ENV{ENANA_NOW} || time;
mkdir $dir unless -d $dir;

sub read_tsv { my ($f) = @_; my @r; if (open my $h, '<', $f) { while (<$h>) { chomp; push @r, [split /\t/, $_, -1] if length; } close $h; } return @r; }
sub write_tsv { my ($f, @r) = @_; open my $h, '>', "$f.new" or die; print $h join("\t", @$_), "\n" for @r; close $h; rename "$f.new", $f; }
sub day_of { strftime('%Y-%m-%d', localtime($_[0])) }
sub purge_old {
    my $cut_day = day_of($now - $KEEP_DAYS * 86400); my $cut_hour = strftime('%Y-%m-%d %H', localtime($now - $KEEP_HOURS * 3600));
    my @d = grep { $_->[0] ge $cut_day } read_tsv("$dir/daily.tsv"); write_tsv("$dir/daily.tsv", @d) if -e "$dir/daily.tsv";
    my @n = grep { $_->[0] ge $cut_day } read_tsv("$dir/nodes.tsv"); write_tsv("$dir/nodes.tsv", @n) if -e "$dir/nodes.tsv";
    my @h = grep { "$_->[0] $_->[1]" ge $cut_hour } read_tsv("$dir/hourly.tsv"); write_tsv("$dir/hourly.tsv", @h) if -e "$dir/hourly.tsv";
}

if ($cmd eq 'purge') { purge_old(); exit 0; }

if ($cmd eq 'collect') {
    my ($rolesf, $defclass) = @rest; $defclass ||= 'auto';
    my %role; if ($rolesf && open my $rh, '<', $rolesf) { while (<$rh>) { chomp; my ($t, $r) = split /\t/; $role{$t} = $r if defined $r; } close $rh; }
    local $/; my $raw = <STDIN>; my $j = eval { decode_json($raw) } or exit 1;
    my $ut = $j->{uploadTotal} || 0; my $dt = $j->{downloadTotal} || 0;
    my $state = {}; if (open my $sh, '<', "$dir/state.json") { local $/; my $t = <$sh>; close $sh; $state = eval { decode_json($t) } || {}; }
    my %cur; my (%cu, %cd, %nu, %nd); my ($au, $ad) = (0, 0);
    for my $c (@{ $j->{connections} || [] }) {
        my $id = $c->{id} or next; my $up = $c->{upload} || 0; my $down = $c->{download} || 0;
        my $chain = $c->{chains} || []; my $node = $chain->[0] // 'direct';
        my $class = $node =~ /^direct(?:-[a-z]+)?$/ ? 'direct' : (($role{$node} // '') eq 'pin' ? 'pin' : 'auto');      # direct-mode / direct-lan / direct-site / direct-app / direct-cn 也是直连
        my $p = $state->{conns}{$id} || [0, 0];
        my $du = $up - $p->[0]; $du = $up if $du < 0; my $dd = $down - $p->[1]; $dd = $down if $dd < 0;
        $cur{$id} = [$up + 0, $down + 0];
        $cu{$class} += $du; $cd{$class} += $dd; $au += $du; $ad += $dd;
        if ($class ne 'direct') { $nu{$node} += $du; $nd{$node} += $dd; }
    }
    my $first = !exists $state->{ut};                                     # 第一次采样: 只建立基线, 不记录 (否则会把核心启动以来的累计都算成「这一分钟」)
    my ($tu, $td) = (0, 0);
    unless ($first) { $tu = $ut - $state->{ut}; $tu = $ut if $tu < 0; $td = $dt - $state->{dt}; $td = $dt if $td < 0; }
    # 总量与已归类量的差 (两次采样之间结束的连接) 按已归类的比例分摊; 一个都没归类时算给默认类别
    my ($ru, $rd) = ($tu - $au, $td - $ad); $ru = 0 if $ru < 0; $rd = 0 if $rd < 0;
    if (!$first && ($ru > 0 || $rd > 0)) {
        my $sum = 0; $sum += ($cu{$_} || 0) + ($cd{$_} || 0) for qw(direct pin auto);
        if ($sum > 0) { for my $k (qw(direct pin auto)) { my $w = (($cu{$k} || 0) + ($cd{$k} || 0)) / $sum; $cu{$k} += int($ru * $w); $cd{$k} += int($rd * $w); } }
        else { $cu{$defclass} += $ru; $cd{$defclass} += $rd; }
    }
    $state = { ut => $ut + 0, dt => $dt + 0, conns => \%cur };
    open my $oh, '>', "$dir/state.json.new" or die; print $oh encode_json($state); close $oh; rename "$dir/state.json.new", "$dir/state.json";
    if (!$first && ($tu > 0 || $td > 0)) {
        my $day = day_of($now); my $hour = strftime('%H', localtime($now));
        my @d = read_tsv("$dir/daily.tsv"); my ($row) = grep { $_->[0] eq $day } @d;
        unless ($row) { $row = [$day, (0) x 8]; push @d, $row; }
        $row->[1] += $tu; $row->[2] += $td;
        my $i = 3; for my $k (qw(direct pin auto)) { $row->[$i++] += $cu{$k} || 0; $row->[$i++] += $cd{$k} || 0; }
        @d = sort { $a->[0] cmp $b->[0] } @d; write_tsv("$dir/daily.tsv", @d);
        my @h = read_tsv("$dir/hourly.tsv"); my ($hr) = grep { $_->[0] eq $day && $_->[1] eq $hour } @h;
        unless ($hr) { $hr = [$day, $hour, (0) x 5]; push @h, $hr; }
        $hr->[2] += $tu; $hr->[3] += $td; my $k2 = 4; for my $k (qw(direct pin auto)) { $hr->[$k2++] += ($cu{$k} || 0) + ($cd{$k} || 0); }
        @h = sort { "$a->[0] $a->[1]" cmp "$b->[0] $b->[1]" } @h; write_tsv("$dir/hourly.tsv", @h);
        if (%nu || %nd) {
            my @n = read_tsv("$dir/nodes.tsv");
            for my $node (keys %{{ %nu, %nd }}) {
                my ($nr) = grep { $_->[0] eq $day && $_->[1] eq $node } @n;
                unless ($nr) { $nr = [$day, $node, 0, 0]; push @n, $nr; }
                $nr->[2] += $nu{$node} || 0; $nr->[3] += $nd{$node} || 0;
            }
            write_tsv("$dir/nodes.tsv", @n);
        }
    }
    purge_old() if (localtime($now))[2] == 3 && (localtime($now))[1] < 2;     # 每天凌晨顺手清一次
    exit 0;
}

if ($cmd eq 'report') {
    my ($range) = @rest; $range ||= 'today';
    my %days = ('today' => 1, '3d' => 3, '7d' => 7, '30d' => 30, '90d' => 90); my $n = $days{$range} || 1;
    my $from = day_of($now - ($n - 1) * 86400); my $to = day_of($now);
    my @d = grep { $_->[0] ge $from && $_->[0] le $to } read_tsv("$dir/daily.tsv"); my %dm = map { $_->[0] => $_ } @d;
    my @all = read_tsv("$dir/daily.tsv"); my $since = @all ? $all[0][0] : '';
    my (%rt, @series); my ($tu, $td) = (0, 0);
    my %r = (direct => [0, 0], pin => [0, 0], auto => [0, 0]);
    for my $row (@d) { $tu += $row->[1]; $td += $row->[2]; my $i = 3; for my $k (qw(direct pin auto)) { $r{$k}[0] += $row->[$i++]; $r{$k}[1] += $row->[$i++]; } }
    my $gran = 'day';
    if ($range eq 'today') {
        $gran = 'hour'; my %hm = map { $_->[1] => $_ } grep { $_->[0] eq $to } read_tsv("$dir/hourly.tsv");
        for my $h (0 .. 23) { my $k = sprintf('%02d', $h); my $row = $hm{$k} || [$to, $k, 0, 0, 0, 0, 0];
            push @series, { t => $k, up => $row->[2] + 0, down => $row->[3] + 0, direct => $row->[4] + 0, pin => $row->[5] + 0, auto => $row->[6] + 0 }; }
    } else {
        for my $i (reverse 0 .. $n - 1) { my $day = day_of($now - $i * 86400); my $row = $dm{$day} || [$day, (0) x 8];
            push @series, { t => $day, up => $row->[1] + 0, down => $row->[2] + 0, direct => $row->[3] + $row->[4], pin => $row->[5] + $row->[6], auto => $row->[7] + $row->[8] }; }
    }
    my %nt; for my $row (grep { $_->[0] ge $from && $_->[0] le $to } read_tsv("$dir/nodes.tsv")) { $nt{$row->[1]}[0] += $row->[2]; $nt{$row->[1]}[1] += $row->[3]; }
    my @nodes = map { { tag => $_, up => $nt{$_}[0] + 0, down => $nt{$_}[1] + 0 } } sort { ($nt{$b}[0] + $nt{$b}[1]) <=> ($nt{$a}[0] + $nt{$a}[1]) } keys %nt;
    my $out = { range => $range, granularity => $gran, from => $from, to => $to, since => $since, retention_days => $KEEP_DAYS,
                total => { up => $tu + 0, down => $td + 0 },
                routes => { map { $_ => { up => $r{$_}[0] + 0, down => $r{$_}[1] + 0 } } qw(direct pin auto) },
                series => \@series, nodes => \@nodes };
    print JSON::PP->new->canonical->encode($out);
    exit 0;
}
die "unknown command $cmd\n";
