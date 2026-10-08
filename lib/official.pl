#!/usr/bin/perl
# 官方线路: 把云端 GET /api/enana/v1/nodes 的响应整理成 $H/official.jsonl 的内容 (一行一个节点)。
#   perl official.pl ingest <云端响应文件> <输出文件> <保留前缀> <最多节点数> <1 = 本机核心太旧, 不要 anytls>
# 退出码: 0 = 有资格且至少一个节点合格 (已写出输出文件) · 3 = 云端明确说没有资格 · 4 = 有资格但没有可用节点 · 1 = 响应不符合约定
# 不信任云端的任何内容: 只留支持的协议、保留前缀的节点名、合法的地址和端口, 不要 detour / 本机证书占位符;
# 键的顺序固定为 type, tag, 其余按字母序 (安装端的 awk 依赖 type、tag 在最前; 同样的数据永远得到同样的字节, 所以「没有变化」可以用 cmp 判断)。
use strict;
use warnings;
use JSON::PP ();
use Encode ();

my ($cmd, $in, $out, $prefix, $max, $noanytls) = @ARGV;
exit 1 unless defined $cmd && $cmd eq 'ingest' && defined $in && defined $out && defined $prefix && length $prefix;
$max = 300 unless defined $max && $max =~ /^\d+$/ && $max > 0;

my $j = JSON::PP->new->utf8;
my $raw = do { local $/; open my $fh, '<', $in or exit 1; <$fh> };
exit 1 if !defined $raw || length($raw) > 4_000_000;
my $d = eval { $j->decode($raw) };
exit 1 unless ref $d eq 'HASH' && JSON::PP::is_bool($d->{entitled}) && ref $d->{nodes} eq 'ARRAY';
exit 3 unless $d->{entitled};

my $pb = $prefix;                            # @ARGV 里已经是 UTF-8 字节
my %types = map { $_ => 1 } qw(trojan http socks tuic hysteria2 vless vmess shadowsocks anytls);
delete $types{anytls} if $noanytls;
my $enc = JSON::PP->new->utf8->allow_nonref->canonical;

my (%seen, @rows);
for my $n (@{ $d->{nodes} }) {
    last if @rows >= $max;
    next unless ref $n eq 'HASH' && ref $n->{outbound} eq 'HASH';
    my %o = %{ $n->{outbound} };
    my ($type, $tag) = @o{qw(type tag)};
    next unless defined $type && !ref $type && $types{$type} && defined $tag && !ref $tag;
    my $tb = Encode::encode('UTF-8', $tag);
    next unless length($tb) > length($pb) && length($tb) <= 96 && substr($tb, 0, length($pb)) eq $pb;
    next if $tb =~ /["\\\x00-\x1f\x7f]/;
    next if $seen{$tag}++;
    next if exists $o{detour};
    my ($host, $port) = @o{qw(server server_port)};
    next unless defined $host && !ref $host && $host =~ /^[A-Za-z0-9._:-]{1,253}$/ && $host !~ /^(?:127\.|0\.0\.0\.0|localhost$|::1$)/i;
    next unless defined $port && !ref $port && $enc->encode($port) =~ /^\d{1,5}$/ && $port >= 1 && $port <= 65535;
    delete @o{qw(type tag)};
    my $rest = $enc->encode(\%o);
    next if $rest =~ /\@CERTS\@/;
    my $line = '{"role":"auto","official":true,"outbound":{"type":' . $enc->encode($type) . ',"tag":' . $enc->encode($tag)
        . ($rest eq '{}' ? '' : ',' . substr($rest, 1, length($rest) - 2)) . '}}';
    next if length($line) > 14000;
    push @rows, [$tb, $line];
}
exit 4 unless @rows;

@rows = sort { $a->[0] cmp $b->[0] } @rows;
open my $oh, '>', $out or exit 1;
binmode $oh;
print $oh map { $_->[1] . "\n" } @rows;
close $oh or exit 1;
exit 0;
