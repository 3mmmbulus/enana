#!/usr/bin/perl
# 配置快照 (导出备份 / 云端同步用): 把「可以跨电脑同步」的本机配置打成一个 JSON, 或把快照里的内容应用回本机。
#   snapshot.pl build <家目录> <应用版本> <设备名> [all]        -> stdout: 快照 JSON (默认只含「保存到云端」的服务器 / 订阅; all = 全部, 导出备份用)
#   snapshot.pl hash  <家目录>                                  -> stdout: 当前可同步内容的 SHA-256 (不含创建时间 / 设备名; 判断「本机有没有没上传的改动」用)
#   snapshot.pl hashfile <快照文件>                             -> stdout: 快照里可同步内容的 SHA-256 (和 hash 同一算法, 用于合并拉取之后记录「已同步」的内容)
#   snapshot.pl info  <快照文件>                                -> stdout: 摘要 JSON (各类数量 / 创建时间 / 设备名 …); 格式不对时退出码 2
#   snapshot.pl apply <家目录> <快照文件> <replace|merge>       -> 把快照写进家目录 (只写白名单里的文件, 每个文件原子替换); stdout: 摘要 JSON
# 快照里永远没有: 令牌 / 会话 / 设备编号 / 端口 / 代理总开关 / 开机自启 / SSH 密码或私钥 (这些只属于这台电脑, 或根本不会被保存)。
# 格式: {"format":1,"app":"enana","version":"2.1.0","created":1760000000,"device":"MacBook","files":{"servers.jsonl":"…",…},"certs":{"x.crt":"…"},"settings":{"LOG_DAYS":"30"}}
# 合并 (merge): servers.jsonl 按节点名、subs.tsv 按订阅名取并集 (本机已有的保留); 其它文件以快照为准。替换 (replace): 快照里没有的文件视为「空」, 删除本机的
# (但本机没有勾选「保存到云端」的服务器 / 订阅属于这台电脑, 替换时保留)。取回来的服务器 / 订阅会记入本机的 servers.sync / subs.sync, 之后继续同步。
use strict;
use warnings;
use JSON::PP;
use Encode ();

my @FILES = qw(servers.jsonl subs.tsv dns.conf overrides.tsv autosites.tsv rules.state custom-rulesets.tsv custom-apps.tsv site-domains.tsv hosts.tsv speedtest-custom.tsv prefs.json vps.jsonl);
my %SETTING_OK = (
    LANG_UI     => sub { $_[0] =~ /^[a-z]{2}(-[A-Za-z]{2,4})?$/ },
    LOG_DAYS    => sub { $_[0] =~ /^\d{1,3}$/ && $_[0] >= 1 && $_[0] <= 365 },   # 旧版本的设置 (天); 新版本改用 LOG_HOURS, 读取时自动换算
    LOG_HOURS   => sub { $_[0] =~ /^\d{2,3}$/ && $_[0] >= 12 && $_[0] <= 720 },
    AUTO_SITES  => sub { $_[0] =~ /^[01]$/ },
    ACCESS_LOG  => sub { $_[0] =~ /^[01]$/ },
    LOG_OPS     => sub { $_[0] =~ /^[01]$/ },
    LOG_CORE    => sub { $_[0] =~ /^[01]$/ },
    AUTO_UPDATE => sub { $_[0] =~ /^[01]$/ },
);
my %RESERVED = map { $_ => 1 } qw(direct AUTO PIN Global Final SPEEDTEST);
my $MAX_FILE = 900_000;          # 单个文件 (字节); 整个快照加密后云端限制 1 MiB
my $JSON = JSON::PP->new->utf8->canonical;

sub slurp {
    my ($f) = @_;
    open my $fh, '<:encoding(UTF-8)', $f or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub spit {    # 原子写 (权限 600)
    my ($f, $content) = @_;
    my $tmp = "$f.snap.new";
    open my $fh, '>:encoding(UTF-8)', $tmp or die "write $tmp: $!";
    print $fh $content;
    close $fh or die "close $tmp: $!";
    chmod 0600, $tmp;
    rename $tmp, $f or die "rename $tmp: $!";
}

sub lines { my ($t) = @_; return grep { length } split /\n/, ($t // ''); }

sub read_set {    # 一行一个名称的清单文件 (servers.sync / subs.sync) -> hash
    my ($f) = @_;
    my %s;
    if (open my $fh, '<:encoding(UTF-8)', $f) { while (<$fh>) { chomp; $s{$_} = 1 if length } close $fh }
    return %s;
}

sub server_sub {    # servers.jsonl 一行 -> 它所属的订阅名 (没有返回 undef)
    my ($l) = @_;
    my $d = eval { $JSON->decode(Encode::encode('UTF-8', $l)) };
    return (ref $d eq 'HASH' && defined $d->{sub} && !ref $d->{sub} && length $d->{sub}) ? $d->{sub} : undef;
}

sub server_tag {    # servers.jsonl 一行 -> 节点名 (不是合法的节点行返回 undef)
    my ($l) = @_;
    my $d = eval { $JSON->decode(Encode::encode('UTF-8', $l)) };
    return undef unless ref $d eq 'HASH' && ref $d->{outbound} eq 'HASH';
    my $o = $d->{outbound};
    return undef unless defined $o->{tag} && !ref $o->{tag} && length $o->{tag} && !$RESERVED{ $o->{tag} };
    return undef unless defined $o->{type} && $o->{type} =~ /^[a-z0-9_]+$/;
    return undef unless defined $d->{role} && $d->{role} =~ /^(pin|auto|dl|off)$/;
    return $o->{tag};
}

sub summary {
    my ($files, $certs, $meta) = @_;
    my %n;
    $n{servers}       = scalar(grep { defined server_tag($_) } lines($files->{'servers.jsonl'}));
    $n{subs}          = scalar lines($files->{'subs.tsv'});
    $n{hosts}         = scalar lines($files->{'hosts.tsv'});
    $n{site_domains}  = scalar lines($files->{'site-domains.tsv'});
    $n{custom_apps}   = scalar lines($files->{'custom-apps.tsv'});
    $n{speed_targets} = scalar lines($files->{'speedtest-custom.tsv'});
    $n{custom_rulesets} = scalar lines($files->{'custom-rulesets.tsv'});
    $n{vps}           = scalar lines($files->{'vps.jsonl'});
    $n{certs}         = scalar keys %{ $certs || {} };
    $n{prefs}         = (defined $files->{'prefs.json'} && length $files->{'prefs.json'}) ? JSON::PP::true : JSON::PP::false;
    return { %n, %{ $meta || {} } };
}

my ($cmd, @a) = @ARGV;
die "usage\n" unless $cmd;

sub collect {    # 读取家目录里可同步的内容 -> (文件 hash 引用, 证书 hash 引用, 设置 hash 引用); $all 为真时不按「保存到云端」清单过滤 (导出备份)
    my ($home, $all) = @_;
    my (%files, %certs, %settings);
    my %st = read_set("$home/servers.sync");
    my %sb = read_set("$home/subs.sync");
    for my $f (@FILES) {
        my $c = slurp("$home/$f");
        next unless defined $c && length $c;
        unless ($all) {
            if ($f eq 'servers.jsonl') {          # 只带「保存到云端」的节点 (节点名在清单里, 或它所属的订阅在清单里)
                my @keep = grep { my $t = server_tag($_); my $s = server_sub($_); defined $t && ($st{$t} || (defined $s && $sb{$s})) } lines($c);
                next unless @keep;
                $c = join("\n", @keep) . "\n";
            } elsif ($f eq 'subs.tsv') {
                my @keep = grep { $sb{ (split /\|/, $_, 2)[0] } } lines($c);
                next unless @keep;
                $c = join("\n", @keep) . "\n";
            }
        }
        die "file too large: $f\n" if length($c) > $MAX_FILE;
        $files{$f} = $c;
    }
    if (opendir my $dh, "$home/certs") {
        my $n = 0;
        for my $f (sort readdir $dh) {
            next unless $f =~ /^[A-Za-z0-9._-]{1,80}\.(crt|pem)$/ && -f "$home/certs/$f";
            my $c = slurp("$home/certs/$f");
            next unless defined $c && length $c <= 20000;
            $certs{$f} = $c;
            last if ++$n >= 50;
        }
        closedir $dh;
    }
    if (open my $fh, '<', "$home/settings.env") {
        while (<$fh>) {
            chomp;
            next unless /^([A-Z_]+)=(.*)$/ && $SETTING_OK{$1};
            my ($k, $v) = ($1, $2);
            $v =~ s/^'(.*)'$/$1/;
            $settings{$k} = "$v" if $SETTING_OK{$k}->($v);        # 复制成纯字符串 (校验里的数值比较会让原变量变成数字, JSON 里就不是字符串了)
        }
        close $fh;
    }
    return (\%files, \%certs, \%settings);
}

if ($cmd eq 'build') {
    my ($home, $ver, $dev, $all) = @a;
    $dev = Encode::decode('UTF-8', $dev // '');         # 命令行参数是 UTF-8 字节 (设备名可能有中文): 先解码成字符, 否则 JSON 里会被二次编码成乱码
    my ($files, $certs, $settings) = collect($home, ($all // '') eq 'all');
    my $total = 0; $total += length($_) for values %$files;
    die "snapshot too large\n" if $total > 1_000_000;
    print $JSON->encode({ format => 1, app => 'enana', version => $ver // '', created => time() + 0, device => $dev // '', files => $files, certs => $certs, settings => $settings });
    exit 0;
}

if ($cmd eq 'hash') {
    require Digest::SHA;
    my ($files, $certs, $settings) = collect($a[0]);
    print Digest::SHA::sha256_hex($JSON->encode({ files => $files, certs => $certs, settings => $settings }));
    exit 0;
}

if ($cmd eq 'info' || $cmd eq 'hashfile' || $cmd eq 'apply') {
    my ($home, $file, $mode);
    if ($cmd eq 'info' || $cmd eq 'hashfile') { ($file) = @a } else { ($home, $file, $mode) = @a; die "mode\n" unless ($mode // '') =~ /^(replace|merge)$/ }
    my $raw = slurp($file);
    my $d = defined $raw ? eval { JSON::PP->new->utf8(0)->decode($raw) } : undef;
    exit 2 unless ref $d eq 'HASH' && ($d->{format} // 0) == 1 && ref $d->{files} eq 'HASH';
    my %files = map { $_ => $d->{files}{$_} } grep { defined $d->{files}{$_} && !ref $d->{files}{$_} && length $d->{files}{$_} } @FILES;
    my %certs = ref $d->{certs} eq 'HASH' ? map { $_ => $d->{certs}{$_} } grep { /^[A-Za-z0-9._-]{1,80}\.(crt|pem)$/ && defined $d->{certs}{$_} && !ref $d->{certs}{$_} && length $d->{certs}{$_} <= 20000 } keys %{ $d->{certs} } : ();
    my %set = ref $d->{settings} eq 'HASH' ? map { $_ => "$d->{settings}{$_}" } grep { $SETTING_OK{$_} && defined $d->{settings}{$_} && !ref $d->{settings}{$_} && $SETTING_OK{$_}->($d->{settings}{$_}) } keys %{ $d->{settings} } : ();
    if ($cmd eq 'hashfile') {
        require Digest::SHA;
        print Digest::SHA::sha256_hex($JSON->encode({ files => \%files, certs => \%certs, settings => \%set }));
        exit 0;
    }
    my %meta = (created => ($d->{created} // 0) + 0, device => (!ref $d->{device} ? ($d->{device} // '') : ''), version => (!ref $d->{version} ? ($d->{version} // '') : ''));
    if ($cmd eq 'info') {
        print $JSON->encode(summary(\%files, \%certs, \%meta));
        exit 0;
    }

    my @changed;
    my %st = read_set("$home/servers.sync");
    my %sb = read_set("$home/subs.sync");
    my (%inTags, %inSubs);                                  # 快照里带来的节点名 / 订阅名: 之后继续同步
    for my $l (lines($files{'servers.jsonl'})) { my $t = server_tag($l); $inTags{$t} = 1 if defined $t }
    for my $l (lines($files{'subs.tsv'})) { my $k = (split /\|/, $l, 2)[0]; $inSubs{$k} = 1 if defined $k && length $k }
    for my $f (@FILES) {
        my $new = $files{$f};
        my $old = slurp("$home/$f");
        if ($mode eq 'replace' && ($f eq 'servers.jsonl' || $f eq 'subs.tsv') && defined $old && length $old) {    # 本机没有「保存到云端」的留下 (它们只属于这台电脑)
            my @mine = $f eq 'servers.jsonl'
                ? grep { my $t = server_tag($_); my $s = server_sub($_); defined $t && !$st{$t} && !(defined $s && $sb{$s}) && !$inTags{$t} } lines($old)
                : grep { my $k = (split /\|/, $_, 2)[0]; !$sb{$k} && !$inSubs{$k} } lines($old);
            if (@mine) { $new = join("\n", (defined $new ? lines($new) : ()), @mine) . "\n" }
        }
        if ($mode eq 'merge' && ($f eq 'servers.jsonl' || $f eq 'subs.tsv') && defined $old && length $old) {
            my %have;
            my @keep = lines($old);
            if ($f eq 'servers.jsonl') { $have{ server_tag($_) // '' } = 1 for @keep }
            else { $have{ (split /\|/, $_, 2)[0] } = 1 for @keep }
            for my $l (lines($new)) {
                my $k = $f eq 'servers.jsonl' ? server_tag($l) : (split /\|/, $l, 2)[0];
                next unless defined $k && length $k && !$have{$k}++;
                push @keep, $l;
            }
            $new = join("\n", @keep) . "\n" if @keep;
        } elsif ($f eq 'servers.jsonl' && defined $new) {    # 只留格式合法的节点行
            my @ok = grep { defined server_tag($_) } lines($new);
            $new = @ok ? join("\n", @ok) . "\n" : undef;
        }
        $new = undef if defined $new && !length $new;
        if (defined $new) {
            next if defined $old && $old eq $new;
            spit("$home/$f", $new);
            push @changed, $f;
        } elsif (-e "$home/$f" && $mode eq 'replace') {
            unlink "$home/$f";
            push @changed, $f;
        }
    }
    for my $pair ([ "$home/servers.sync", \%st, \%inTags ], [ "$home/subs.sync", \%sb, \%inSubs ]) {      # 记下取回来的名称 (之后它们继续同步)
        my ($file, $have, $inc) = @$pair;
        my @add = grep { !$have->{$_} } sort keys %$inc;
        next unless @add;
        spit($file, join("\n", (sort keys %$have), @add) . "\n");
    }
    if (%certs) {
        mkdir "$home/certs", 0700 unless -d "$home/certs";
        for my $f (sort keys %certs) {
            my $old = slurp("$home/certs/$f");
            next if defined $old && $old eq $certs{$f};
            spit("$home/certs/$f", $certs{$f});
        }
    }
    if (%set) {
        my @cur = -f "$home/settings.env" ? do { open my $fh, '<', "$home/settings.env"; <$fh> } : ();
        chomp @cur;
        for my $k (sort keys %set) {
            my $line = "$k=$set{$k}";
            my $hit = 0;
            for (@cur) { if (/^\Q$k\E=/) { $_ = $line; $hit = 1 } }
            push @cur, $line unless $hit;
        }
        spit("$home/settings.env", join("\n", @cur) . "\n");
        push @changed, 'settings.env';
    }
    print $JSON->encode({ %{ summary(\%files, \%certs, \%meta) }, changed => \@changed });
    exit 0;
}
die "unknown command: $cmd\n";
