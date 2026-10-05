#!/usr/bin/perl
# 诊断摘要: 把本机的诊断导出 (lib/logs.sh logs_bundle) 按「白名单」缩成一份 JSON, 供上传给官方云端 (见 docs/DIAGNOSTICS.md)。
#   用法: logs_bundle 24 snapshot,ops | perl diag.pl summary       → 标准输出一行 JSON (v=1)
#
# 原则: 默认丢弃。只有明确列出的键才会出现在摘要里; 凡是用户起的名字 (服务器标签 / 订阅名 / 应用名 / 网站) 要么丢掉、要么换成别名 (node1 …),
#       IP 地址一律换成 <ip> (127.0.0.1 除外), 用户名和邮箱本来就已经在导出里打码。摘要里不会有: 访问记录、核心原始日志、配置规则、已安装应用、
#       服务器地址 / 端口 / 凭据、网站域名、应用名、密码、令牌。
# 服务端 (pb_hooks/enana_diag.js) 还会再做一次形状检查: 只认 v / generated / meta / verdict / env / ops / health / outages 这几个顶层键。
use strict;
use warnings;
use utf8;
use JSON::PP;
use POSIX qw(strftime);
binmode STDIN, ':encoding(UTF-8)';

# 动作的详情只保留这些键 (都是数字 / 状态码 / 函数调用链 / 开关名之类, 没有用户起的名字); 其余全部丢弃 (必须在调用 summary 之前初始化)
my %DETAIL_OK = map { $_ => 1 } qw(
  reason http proxy_was since_ok_s session via raw_reason resp_code key from to pid item old_pid new_pid method helper err port mode
  enabled was_enabled was_mode count scan_v browsers down_s current setting trigger bytes hours sections id pin_servers dependents
  note proxy sysproxy capture seq_before src
);

# 值的白名单: from / to 在不同动作里可能是「策略」「节点名」「接口名」…… 节点名 / 域名 / 应用名绝不能出现 (就算那台服务器已经被删掉、别名表里没有它),
# 所以只放行固定词表、数字、网络接口名和节点别名; 其余的键也只放行没有空格 / 引号 / 中文的短字符串 (名字多半带这些)。不符合的整个键丢弃。
my $VOCAB = qr/^(?:\d{1,12}|ok|empty|-|follow|pin|pinauto|auto|direct|off|def|global|system|tun|Rule|Direct|Global|AUTO|PIN|Final|(?:en|utun|bridge|awdl|lo|llw|gif|stf|ap|anpi)\d{1,3}|<ip6?>|node\d{1,4})$/;
my %VALUE_RE = (
  from => $VOCAB, to => $VOCAB, was_mode => $VOCAB, mode => qr/^[A-Za-z_-]{1,20}$/,
  note => qr/^[A-Za-z0-9 ;,.()_-]{1,120}$/,
);
my $VALUE_DEFAULT = qr/^[A-Za-z0-9_.:,<>=\/-]{1,60}$/;

my $cmd = shift @ARGV // '';
if ($cmd eq 'summary') { summary(); } else { print STDERR "usage: diag.pl summary < bundle\n"; exit 2; }
exit 0;

sub summary {
  no warnings 'numeric';
  my (%S, $cur);
  while (my $l = <STDIN>) {
    chomp $l; $l =~ s/\r$//;
    if ($l =~ /^\@\@SECTION (\S+) /) { $cur = $1; $S{$cur} = []; next }
    if ($l =~ /^\@\@END/) { undef $cur; next }
    push @{ $S{$cur} }, $l if defined $cur;
  }
  my $kv = sub { my ($n) = @_; my %h; for my $l (@{ $S{$n} || [] }) { $h{$1} = $2 if $l =~ /^([^=\s]+)=(.*)$/ } return \%h };
  my $tsv = sub { my ($n) = @_; my @r; my $first = 1; for my $l (@{ $S{$n} || [] }) { next if $l =~ /^#/; if ($first) { $first = 0; next } my @c = split /\t/, $l, -1; push @c, '' while @c < 9; push @r, \@c } return \@r };
  my ($meta, $env, $verdict) = ($kv->('meta'), $kv->('env'), $kv->('verdict'));

  # ---- 服务器标签 → 别名 (标签是用户起的, 常常带着主机名 / IP)
  my %tag;
  for my $r (@{ $tsv->('servers') }) { $tag{ $r->[0] } = 1 if length($r->[0] // '') }
  for my $k (keys %$verdict) { $tag{$1} = 1 if $k =~ /^verdict\.node\.(.+)$/ }
  for my $r (@{ $tsv->('health_summary') }) { $tag{ $r->[2] } = 1 if ($r->[1] // '') eq 'node' && length($r->[2] // '') }
  for my $r (@{ $tsv->('outages') }) { $tag{ $r->[4] } = 1 if ($r->[3] // '') eq 'node' && length($r->[4] // '') }
  my @tags = sort { length($b) <=> length($a) || $a cmp $b } keys %tag;
  my %alias; my $i = 0; $alias{$_} = 'node' . (++$i) for sort keys %tag;
  my $alt = @tags ? join('|', map { quotemeta } @tags) : '';

  my $scrub = sub {
    my ($s) = @_; return '' unless defined $s;
    $s =~ s/($alt)/$alias{$1}/g if length $alt;
    $s =~ s/\b(?!127\.0\.0\.1\b)\d{1,3}(?:\.\d{1,3}){3}\b/<ip>/g;
    $s =~ s/\b[0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{0,4}){3,7}\b/<ip6>/g;
    $s =~ s/\b[0-9a-fA-F]{1,4}::[0-9a-fA-F:]*\b/<ip6>/g;
    $s =~ s/[\x00-\x08\x0b-\x1f\x7f]//g;
    return length($s) > 400 ? substr($s, 0, 400) : $s;
  };

  # ---- meta
  my %out_meta;
  for my $k (sort keys %$meta) {
    next unless $k =~ /^(?:app|version|core|os|arch|lang|timezone|now|epoch)$/ || $k =~ /^(?:service|capture|proxy|clash|settings|ports|servers|account|content|rules)\./;
    $out_meta{$k} = $scrub->($meta->{$k});
  }

  # ---- env
  my %out_env;
  for my $k (sort keys %$env) {
    my $v = $env->{$k};
    if ($k =~ /^(?:capture\.(?:mode|system_proxy_scope|priority|tun\.\w+|route\.\w+)|sysproxy\.(?:points_to_enana|HTTPEnable|HTTPSEnable|SOCKSEnable|HTTPPort|HTTPSPort|SOCKSPort)|net\.interface|other_proxy_software|disk\.free_kb|logs\.size_kb)$/) { $out_env{$k} = $scrub->($v) }
    elsif ($k =~ /^(?:listen\.\d+|core\.\w+|service\.\w+|stats\.\w+|session\.\w+|stats\.day\.[\d-]+)$/) { $out_env{$k} = $scrub->($v) }
    elsif ($k =~ /^pin\.(?:servers|app_policies|selectors_on_pin)$/) { $out_env{$k} = $scrub->($v) }          # 只要数量; 名字 (*_names) 和 group_members 一律不要
    elsif ($k =~ /^sysproxy\.(?:HTTP|HTTPS|SOCKS)Proxy$/) { $out_env{$k} = ($v =~ /^(?:127\.0\.0\.1|localhost)$/ ? 'local' : 'other') }
    elsif ($k eq 'dns.system') { my ($f) = $v =~ /^(\d+\.\d+\.\d+\.\d+)/; $out_env{'dns.system_kind'} = !defined $f ? 'none' : ($f =~ /^(?:10\.|192\.168\.|169\.254\.|172\.(?:1[6-9]|2\d|3[01])\.)/ ? 'private' : 'public') }
    elsif ($k eq 'config.check') { $out_env{$k} = ($v eq 'ok' ? 'ok' : 'error') }
  }

  # ---- verdict (摘要文字 summary.* 里可能有节点名 / IP, 不要; 原因代码 + 数字证据足够)
  my %out_v;
  for my $k (sort keys %$verdict) {
    my $v = $verdict->{$k}; (my $short = $k) =~ s/^verdict\.//;
    if ($short =~ /^(?:version|generated_epoch|generated|data|cause|blame|confidence|since)$/) { $out_v{$short} = $scrub->($v) }
    elsif ($short =~ /^now\./) { $out_v{$short} = $scrub->($v) }
    elsif ($short =~ /^(?:pin|session)$/) { $out_v{$short} = $scrub->($v) }
    elsif ($short =~ /^canary\./) { $out_v{$short} = $scrub->($v) }
    elsif ($short =~ /^node\.(.+)$/) { $out_v{'node.' . ($alias{$1} // 'node?')} = $scrub->($v) }
    elsif ($short =~ /^outage\.\d+$/) { $out_v{$short} = $scrub->($v) }
    elsif ($short =~ /^evidence\.\d+$/) { $out_v{$short} = $scrub->($v) }
    elsif ($short =~ /^also\.\d+$/) { my ($code) = $v =~ /^([a-z0-9-]+ \([a-z-]+\))/; $out_v{$short} = $code if defined $code }
    elsif ($short =~ /^last_proxy_(?:on|off)$/) {      # 「时间 来源 动作 详情」: 详情按 ops 的白名单过滤
      if ($v =~ /^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) (\S+) (\S+)(?: (.*))?$/) { my ($t, $w, $a, $d) = ($1, $2, $3, $4); $a =~ s/「[^」]*」/「…」/g; $out_v{$short} = join(' ', grep { length } ($t, $scrub->($w), $scrub->($a), ops_detail_line($d, $scrub))) } else { $out_v{$short} = 'none' }
    }
    elsif ($short =~ /^chatgpt(?:\.recent30m)?$/) {      # 只留数字 + 原因 / 错误类型的计数, 不要应用名 / 节点名
      my @p; for my $f (qw(conns direct proxy errors)) { push @p, "$f=$1" if $v =~ /\b$f=(\d+)/ }
      for my $f (qw(reasons error_types)) { push @p, "$f=[$1]" if $v =~ /\b$f=\[([^\]]*)\]/ }
      $out_v{$short} = $scrub->(join(' ', @p));
    }
  }

  # ---- health / outages (节点目标换成别名)
  my @health;
  for my $r (@{ $tsv->('health_summary') }) { next if @$r < 9; push @health, { bucket => $r->[0], kind => $r->[1], target => ($r->[1] eq 'node' ? ($alias{ $r->[2] } // 'node?') : $scrub->($r->[2])), n => $r->[3] + 0, ok => $r->[4] + 0, fail => $r->[5] + 0, ms_avg => $r->[6] + 0, ms_max => $r->[7] + 0, errors => $scrub->($r->[8]) } }
  @health = @health[-300 .. -1] if @health > 300;
  my @outages;
  for my $r (@{ $tsv->('outages') }) { next if @$r < 7; push @outages, { start => $r->[0], end => $r->[1], minutes => $r->[2] + 0, kind => $r->[3], target => ($r->[3] eq 'node' ? ($alias{ $r->[4] } // 'node?') : $scrub->($r->[4])), result => $scrub->($r->[5]), samples => $r->[6] + 0 } }
  @outages = @outages[-100 .. -1] if @outages > 100;

  # ---- ops: 动作名 + 白名单里的详情键 (其余的键, 例如 sub= / user= / tag=, 一律丢弃)
  my @ops;
  for my $r (@{ $tsv->('ops') }) {
    next if @$r < 5;
    my ($ts, $who, $act, $det, $res) = @$r;
    # 动作名只取「头部」: 第一个空格 / 冒号 / 括号 / 「 之前, 而且必须是纯汉字 (含 /)。后面的部分可能拼进了用户的东西 (订阅名 / 域名 / 测速目标 …), 一律丢掉;
    # 头部不符合的整条丢弃 (宁可少一条, 不让名字漏出去)。例: 「订阅「机场A」刷新」→「订阅」, 「添加网站 example.com」→「添加网站」, 「云端同步: 拉取 (merge)」→「云端同步」。
    my ($head) = $act =~ /^([\x{4e00}-\x{9fff}\/]{2,20})(?:[\s:：「（(].*)?$/s;
    next unless defined $head;
    push @ops, { ts => $ts, who => $who, action => $head, detail => ops_detail_line($det, $scrub), result => $res };
  }
  @ops = @ops[-300 .. -1] if @ops > 300;

  my %doc = (v => 1, generated => strftime('%Y-%m-%d %H:%M:%S', localtime), meta => \%out_meta, verdict => \%out_v, env => \%out_env, health => \@health, outages => \@outages, ops => \@ops);
  my $json = JSON::PP->new->utf8->canonical;
  my $text = $json->encode(\%doc);
  # 超过上限 (服务端 98304 字符): 依次丢掉最旧的 ops / health, 直到放得下
  while (length($text) > 90000 && (@ops > 20 || @health > 50)) {
    splice @ops, 0, int(@ops / 4) + 1 if @ops > 20;
    splice @health, 0, int(@health / 4) + 1 if @health > 50;
    $doc{ops} = \@ops; $doc{health} = \@health; $text = $json->encode(\%doc);
  }
  print $text, "\n";
}

sub ops_detail_line {
  my ($s, $scrub) = @_; return '' unless defined $s && length $s;
  my @out;
  while ($s =~ /([A-Za-z0-9_.]+)=("(?:[^"\\]|\\.)*"|\S*)/g) {
    my ($k, $v) = ($1, $2);
    next unless $DETAIL_OK{$k};
    $v =~ s/^"(.*)"$/$1/s;
    next if $k eq 'via' && $v !~ /^[A-Za-z0-9_<]+$/;       # 调用链只能是函数名
    $v = $scrub->(length($v) > 80 ? substr($v, 0, 80) : $v);
    next unless length $v && $v =~ ($VALUE_RE{$k} // $VALUE_DEFAULT);
    push @out, "$k=$v";
  }
  return join(' ', @out);
}
