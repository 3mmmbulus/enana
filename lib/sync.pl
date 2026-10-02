#!/usr/bin/perl
# 云端同步的加密 / 解密 (端到端: 密钥由账号密码在本机派生, 云端只看到密文)。用法见 lib/sync.sh。
#   sync.pl kdf  <账号 id> <迭代次数>                  (密码从 stdin)  -> stdout 两行: 加密口令 (hex) / 校验密钥 (hex)  → 写进 sync.key
#   sync.pl seal <sync.key> <明文 JSON 文件> <输出 base64 文件>
#   sync.pl open <sync.key> <base64 文件> <输出 JSON 文件>             退出码: 0 成功  2 格式不对  3 校验失败 (密钥不对 / 被篡改)  4 解压失败
#
# 方案 (encrypt-then-MAC):
#   K    = PBKDF2-HMAC-SHA256(密码, "enana-sync-v1|" + 账号 id, 200000 次, 32 字节)       盐里带账号 id: 同一账号的每台电脑派生出同一把密钥
#   Kenc = HMAC-SHA256(K, "enana-sync-enc") (作为 openssl enc 的口令, 256 位随机)        Kmac = HMAC-SHA256(K, "enana-sync-mac")
#   载荷 = base64( "ENSYNC1" || openssl enc -aes-256-cbc -salt -md sha256 (gzip(快照 JSON)) || HMAC-SHA256(Kmac, "ENSYNC1" || 密文) )
# 解密先验 MAC (常数时间比较) 再解密, 篡改或密钥不对一律拒绝; 解压有 16 MB 上限 (防压缩炸弹)。
# openssl enc 的 "Salted__" 格式在 LibreSSL (macOS) 与 OpenSSL 3 之间可互相解开 (已实测), 以后 Windows 版沿用同一格式。
use strict;
use warnings;
use Digest::SHA qw(hmac_sha256);
use MIME::Base64 qw(encode_base64 decode_base64);
use IO::Compress::Gzip qw(gzip $GzipError);
use IO::Uncompress::Gunzip qw($GunzipError);
use File::Temp ();

my $OPENSSL = $ENV{ENANA_OPENSSL} || '/usr/bin/openssl';
my $MAGIC = 'ENSYNC1';
my $MAX_PLAIN = 16 * 1024 * 1024;

sub slurp_raw { my ($f) = @_; open my $fh, '<:raw', $f or die "read $f: $!\n"; local $/; my $c = <$fh>; close $fh; return $c; }
sub spit_raw { my ($f, $c) = @_; open my $fh, '>:raw', $f or die "write $f: $!\n"; print $fh $c; close $fh or die "close $f: $!\n"; chmod 0600, $f; }

sub read_key {
    my ($f) = @_;
    open my $fh, '<', $f or die "no key\n";
    my @l = <$fh>;
    close $fh;
    chomp @l;
    die "bad key\n" unless @l >= 2 && $l[0] =~ /^[0-9a-f]{64}$/ && $l[1] =~ /^[0-9a-f]{64}$/;
    return ($l[0], pack('H*', $l[1]));
}

sub openssl_enc {    # 参数列表 (不经过 shell); 成功返回 1
    my @args = @_;
    open my $olderr, '>&', \*STDERR;
    open STDERR, '>', '/dev/null';
    my $rc = system($OPENSSL, 'enc', @args);
    open STDERR, '>&', $olderr;
    return $rc == 0;
}

sub ct_equal {    # 常数时间比较
    my ($a, $b) = @_;
    return 0 unless length $a == length $b;
    my $d = 0;
    $d |= ord(substr($a, $_, 1)) ^ ord(substr($b, $_, 1)) for 0 .. length($a) - 1;
    return $d == 0;
}

my ($cmd, @a) = @ARGV;
die "usage\n" unless $cmd;

if ($cmd eq 'kdf') {
    my ($acct, $iter) = @a;
    die "args\n" unless defined $acct && $acct =~ /^[A-Za-z0-9_-]{1,64}$/ && ($iter // '') =~ /^\d{1,7}$/ && $iter >= 1;
    local $/;
    my $pw = <STDIN>;
    $pw = '' unless defined $pw;
    my $u = hmac_sha256("enana-sync-v1|$acct" . pack('N', 1), $pw);
    my $t = $u;
    for (my $i = 2; $i <= $iter; $i++) { $u = hmac_sha256($u, $pw); $t ^= $u; }
    print unpack('H*', hmac_sha256('enana-sync-enc', $t)), "\n", unpack('H*', hmac_sha256('enana-sync-mac', $t)), "\n";
    exit 0;
}

if ($cmd eq 'seal') {
    my ($keyf, $in, $out) = @a;
    my ($enc, $mac) = read_key($keyf);
    my $plain = slurp_raw($in);
    my $gz;
    gzip(\$plain => \$gz) or die "gzip: $GzipError\n";
    my $tmp = File::Temp->new(UNLINK => 1);
    my $cf = File::Temp->new(UNLINK => 1);
    binmode $tmp; print $tmp $gz; close $tmp;
    openssl_enc('-aes-256-cbc', '-salt', '-md', 'sha256', '-pass', "file:$keyf", '-in', $tmp->filename, '-out', $cf->filename) or exit 5;
    my $blob = $MAGIC . slurp_raw($cf->filename);
    spit_raw($out, encode_base64($blob . hmac_sha256($blob, $mac), ''));
    exit 0;
}

if ($cmd eq 'open') {
    my ($keyf, $in, $out) = @a;
    my ($enc, $mac) = read_key($keyf);
    my $raw = decode_base64(slurp_raw($in));
    exit 2 if length($raw) < length($MAGIC) + 16 + 32 || substr($raw, 0, length $MAGIC) ne $MAGIC;
    my $tag = substr($raw, -32);
    my $blob = substr($raw, 0, length($raw) - 32);
    exit 3 unless ct_equal($tag, hmac_sha256($blob, $mac));
    my $cf = File::Temp->new(UNLINK => 1);
    my $pf = File::Temp->new(UNLINK => 1);
    binmode $cf; print $cf substr($blob, length $MAGIC); close $cf;
    openssl_enc('-d', '-aes-256-cbc', '-md', 'sha256', '-pass', "file:$keyf", '-in', $cf->filename, '-out', $pf->filename) or exit 3;
    my $gz = slurp_raw($pf->filename);
    my $plain = '';
    my $z = IO::Uncompress::Gunzip->new(\$gz) or exit 4;
    my ($buf, $n);
    while (($n = $z->read($buf, 65536)) > 0) {
        $plain .= $buf;
        exit 4 if length($plain) > $MAX_PLAIN;
    }
    exit 4 if $n < 0;
    spit_raw($out, $plain);
    exit 0;
}
die "unknown command: $cmd\n";
