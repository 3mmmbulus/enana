#!/usr/bin/perl
# 连接健康: 探测 + 统计 + 自动判定。由 lib/health.sh 和诊断导出 (lib/logs.sh) 调用, 只用 perl 自带模块, 不联网 (probe 除外: 只连用户自己的服务器端口)。
#
#   health.pl probe [超时秒数]                      标准输入每行  标签<TAB>主机<TAB>端口  → 每行  标签<TAB>结果<TAB>毫秒<TAB>说明  (并行, 每个目标一个子进程)
#   health.pl summary <分钟数/桶> < health.tsv      → 分桶统计 (时间 种类 目标 次数 成功 失败 平均ms 最大ms 错误分布)
#   health.pl outages < health.tsv                  → 连续失败的时段 (开始 结束 分钟 种类 目标 结果)
#   health.pl verdict <现在 epoch> <health> <ops> <access> <meta> <env> <节点标签:角色,…>   → 自动判定 (kv 行)
#
# 健康记录一行 (lib/health.sh 写入, 制表符分隔):  时间  种类  目标  结果  毫秒  说明(键=值)
#   node    <服务器标签>  ok|timeout|refused|unreachable|dns|other   本机直接连服务器端口的 TCP 连接耗时 (每分钟)
#   canary  google_204|chatgpt_web|openai_api|cn_direct  ok|region-blocked|http-NNN|timeout|dns|refused|tls|reset|curl-N   经本机代理访问关键站点 (每 5 分钟); cn_direct 是不经代理的对照
#   state   capture  ok  0  core=… proxy=… sysproxy=… …   接管相关状态 (变化时 + 每 10 分钟)
#   tick    gap      gap  秒  …   两次定时任务之间隔了很久 (休眠 / 后台被暂停)
use strict;
use warnings;
use POSIX qw(strftime mktime floor _exit);
use Time::HiRes qw(time);

my $cmd = shift @ARGV // '';
if    ($cmd eq 'probe')   { cmd_probe(); }
elsif ($cmd eq 'summary') { cmd_summary(); }
elsif ($cmd eq 'outages') { cmd_outages(); }
elsif ($cmd eq 'verdict') { cmd_verdict(); }
else { print STDERR "usage: health.pl probe|summary|outages|verdict\n"; exit 2; }
exit 0;

# ------------------------------------------------------------------ 公共
sub epoch_of { my ($s) = @_; return undef unless defined $s && $s =~ /^(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)/; return mktime($6, $5, $4, $3, $2 - 1, $1 - 1900); }
sub ts_of    { my ($e) = @_; return strftime('%Y-%m-%d %H:%M:%S', localtime($e)); }
sub clean    { my ($s) = @_; $s //= ''; $s =~ s/[\t\r\n]/ /g; return $s; }
sub read_tsv { # 文件 -> [[列…], …]; 缺失文件 / 空文件 → []
  my ($f) = @_; my @r; return \@r unless defined $f && length $f && -r $f;
  open my $fh, '<', $f or return \@r; binmode $fh, ':raw';
  while (my $l = <$fh>) { chomp $l; $l =~ s/\r$//; push @r, [split /\t/, $l, -1]; } close $fh; return \@r;
}
sub read_kv { # kv 分区 -> {键 => 值}
  my ($f) = @_; my %h; return \%h unless defined $f && length $f && -r $f;
  open my $fh, '<', $f or return \%h; while (my $l = <$fh>) { chomp $l; $l =~ s/\r$//; $h{$1} = $2 if $l =~ /^([^=\s]+)=(.*)$/; } close $fh; return \%h;
}
sub detail_kv { my ($s) = @_; my %h; return \%h unless defined $s; while ($s =~ /([A-Za-z0-9_.]+)=("(?:[^"\\]|\\.)*"|\S*)/g) { my ($k, $v) = ($1, $2); if ($v =~ /^"(.*)"$/s) { $v = $1; $v =~ s/\\(["\\])/$1/g; } $h{$k} = $v; } return \%h; }
sub dur { my ($s) = @_; $s = int($s + .5); return $s < 90 ? "${s}s" : $s < 5400 ? sprintf('%dm', int($s / 60 + .5)) : $s < 129600 ? sprintf('%.1fh', $s / 3600) : sprintf('%.1fd', $s / 86400); }
sub pct { my ($a, $b) = @_; return $b ? sprintf('%.1f%%', 100 * $a / $b) : '-'; }

# ------------------------------------------------------------------ probe
sub tcp_probe {
  my ($host, $port, $to) = @_;
  require IO::Socket::IP; require Socket;
  my $t0 = time; my ($sock, $err);
  eval {
    local $SIG{ALRM} = sub { die "timeout\n" }; alarm($to + 1);
    $sock = IO::Socket::IP->new(PeerHost => $host, PeerPort => $port, Type => Socket::SOCK_STREAM(), Timeout => $to);
    $err = "$@ $!" unless $sock;
    alarm 0; 1;
  } or do { alarm 0; $err = $@ || 'timeout'; };
  my $ms = int((time - $t0) * 1000 + .5);
  if ($sock) { close $sock; return ('ok', $ms, ''); }
  $err = lc($err // '');
  my $c = $err =~ /timed out|timeout/ ? 'timeout' : $err =~ /refused/ ? 'refused' : $err =~ /unreachable|no route/ ? 'unreachable' : $err =~ /name or service|nodename|not known|no address|resolv|getaddrinfo/ ? 'dns' : 'other';
  return ($c, $ms, '');
}
sub cmd_probe {
  my $to = shift @ARGV; $to = 4 unless defined $to && $to =~ /^\d+$/ && $to > 0 && $to <= 20;
  my @t;
  while (my $l = <STDIN>) { chomp $l; my ($tag, $host, $port) = split /\t/, $l; next unless defined $port && $port =~ /^\d+$/ && defined $host && length $host; push @t, [clean($tag), $host, $port]; }
  my @kids;
  for my $x (@t) {
    pipe(my $r, my $w) or die "pipe: $!"; my $pid = fork();
    die "fork: $!" unless defined $pid;
    if (!$pid) { close $r; my @res = tcp_probe($x->[1], $x->[2], $to); print $w join("\t", @res), "\n"; close $w; _exit(0); }
    close $w; push @kids, [$pid, $r];
  }
  for my $i (0 .. $#kids) {
    my ($pid, $r) = @{ $kids[$i] }; my $line = <$r>; close $r; waitpid($pid, 0); $line //= ''; chomp $line;
    my @f = split /\t/, $line, 3; $f[0] = 'other' unless defined $f[0] && length $f[0]; $f[1] //= 0; $f[2] //= '';
    print join("\t", $t[$i][0], $f[0], $f[1], $f[2]), "\n";
  }
}

# ------------------------------------------------------------------ 读健康记录
sub load_health { # 标准输入 → [{e, ts, kind, target, result, ms, detail, ok}]  (按时间排序)
  my @r;
  while (my $l = <STDIN>) {
    chomp $l; $l =~ s/\r$//; my ($ts, $kind, $target, $result, $ms, $detail) = split /\t/, $l, 6;
    next unless defined $result; my $e = epoch_of($ts); next unless defined $e;
    push @r, { e => $e, ts => $ts, kind => $kind, target => $target, result => $result, ms => ($ms // 0) + 0, detail => $detail // '', ok => ($result eq 'ok' ? 1 : 0) };
  }
  @r = sort { $a->{e} <=> $b->{e} } @r; return \@r;
}
sub load_health_file { my ($f) = @_; return [] unless defined $f && length $f && -r $f; local *STDIN; open STDIN, '<', $f or return []; return load_health(); }
sub is_sample { my ($r) = @_; return $r->{kind} eq 'node' || $r->{kind} eq 'canary'; }
sub errclass { my ($r) = @_; return $r->{ok} ? '' : $r->{result}; }

sub cmd_summary {
  my $bm = shift @ARGV; $bm = 10 unless defined $bm && $bm =~ /^\d+$/ && $bm >= 1; my $bs = $bm * 60;
  my $rows = load_health(); my (%b, @order);
  for my $r (@$rows) {
    next unless is_sample($r);
    my $bk = floor($r->{e} / $bs) * $bs; my $key = join("\t", $bk, $r->{kind}, $r->{target});
    push @order, $key unless exists $b{$key};
    my $x = $b{$key} //= { n => 0, ok => 0, sum => 0, max => 0, errs => {} };
    $x->{n}++; if ($r->{ok}) { $x->{ok}++; $x->{sum} += $r->{ms}; $x->{max} = $r->{ms} if $r->{ms} > $x->{max}; } else { $x->{errs}{ $r->{result} }++; }
  }
  print "bucket\tkind\ttarget\tn\tok\tfail\tms_avg\tms_max\terrors\n";
  for my $key (sort { my @a = split /\t/, $a; my @c = split /\t/, $b; $a[0] <=> $c[0] || $a[1] cmp $c[1] || $a[2] cmp $c[2] } @order) {
    my ($bk, $kind, $target) = split /\t/, $key; my $x = $b{$key};
    my $errs = join(',', map { "$_×$x->{errs}{$_}" } sort { $x->{errs}{$b} <=> $x->{errs}{$a} || $a cmp $b } keys %{ $x->{errs} });
    printf "%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%s\n", substr(ts_of($bk), 0, 16), $kind, clean($target), $x->{n}, $x->{ok}, $x->{n} - $x->{ok}, ($x->{ok} ? int($x->{sum} / $x->{ok} + .5) : 0), $x->{max}, $errs;
  }
}

# 连续失败的时段: 每个 (种类, 目标) 单独算; 节点每分钟一次 (至少连续 2 次失败才算), 金丝雀每 5 分钟一次 (至少连续 2 次)
sub find_outages {
  my ($rows, $now) = @_; my %by; my @out;
  for my $r (@$rows) { next unless is_sample($r); push @{ $by{ $r->{kind} . "\t" . $r->{target} } }, $r; }
  for my $key (sort keys %by) {
    my ($kind, $target) = split /\t/, $key; my $step = $kind eq 'node' ? 60 : 300; my $run;
    my $flush = sub { my ($ongoing) = @_; return unless $run; if ($run->{n} >= 2) { my %c; $c{$_}++ for @{ $run->{res} }; my ($top) = sort { $c{$b} <=> $c{$a} || $a cmp $b } keys %c;
        push @out, { start => $run->{start}, end => $run->{last}, minutes => ($run->{last} - $run->{start} + $step) / 60, kind => $kind, target => $target, result => $top, n => $run->{n}, ongoing => $ongoing }; } $run = undef; };
    for my $r (@{ $by{$key} }) {
      if (!$r->{ok}) { if ($run && $r->{e} - $run->{last} <= $step * 3) { $run->{last} = $r->{e}; $run->{n}++; push @{ $run->{res} }, $r->{result}; } else { $flush->(0); $run = { start => $r->{e}, last => $r->{e}, n => 1, res => [$r->{result}] }; } }
      else { $flush->(0); }
    }
    $flush->(defined $now && $run && $now - $run->{last} <= $step * 3 ? 1 : 0);
  }
  return [sort { $a->{start} <=> $b->{start} } @out];
}
sub cmd_outages {
  my $rows = load_health(); my $o = find_outages($rows, undef);
  print "start\tend\tminutes\tkind\ttarget\tresult\tsamples\n";
  printf "%s\t%s\t%.0f\t%s\t%s\t%s\t%d\n", ts_of($_->{start}), ts_of($_->{end}), $_->{minutes}, $_->{kind}, clean($_->{target}), $_->{result}, $_->{n} for @$o;
}

# ------------------------------------------------------------------ verdict
sub cmd_verdict {
  my ($now, $hf, $of, $af, $mf, $ef, $nodes) = @ARGV;
  $now = time unless defined $now && $now =~ /^\d+$/;
  my $H = load_health_file($hf); my $ops = read_tsv($of); my $acc = read_tsv($af); my $meta = read_kv($mf); my $env = read_kv($ef);
  my %role; for my $p (split /,/, $nodes // '') { my ($t, $r) = split /:/, $p, 2; $role{$t} = $r // '' if length($t // ''); }
  my @L; my $add = sub { push @L, join('=', @_); };
  my $RECENT = 1800; my $recent_from = $now - $RECENT;

  # ---- 现状 (导出时刻)
  my $proxy_on = ($meta->{'proxy.enabled'} // '') eq '1';
  my $core_run = ($meta->{'service.running'} // '') eq '1';
  my $cap = $meta->{'capture.mode'} // 'system';
  my $port = $meta->{'ports.proxy'} // '';
  # 生效的系统代理是否指向 enana: macOS 导出里是 scutil 的 sysproxy.HTTP*; Windows 导出里是 sysproxy.enabled / sysproxy.server; 都没有 (旧版导出) → 未知, 不做这一项判断
  my $sp_known = (exists $env->{'sysproxy.HTTPEnable'} || exists $env->{'sysproxy.enabled'} || exists $env->{'sysproxy.points_to_enana'}) ? 1 : 0;
  my $sp_eff = 0;
  if (exists $env->{'sysproxy.HTTPEnable'}) { $sp_eff = (($env->{'sysproxy.HTTPEnable'} // '') =~ /1/ && ($env->{'sysproxy.HTTPProxy'} // '') =~ /127\.0\.0\.1|localhost/ && (!length $port || ($env->{'sysproxy.HTTPPort'} // '') =~ /\b\Q$port\E\b/)) ? 1 : 0; }
  elsif (exists $env->{'sysproxy.enabled'}) { $sp_eff = (($env->{'sysproxy.enabled'} // '') eq '1' && ($env->{'sysproxy.server'} // '') =~ /127\.0\.0\.1|localhost/ && (!length $port || ($env->{'sysproxy.server'} // '') =~ /:\Q$port\E\b/)) ? 1 : 0; }
  elsif (exists $env->{'sysproxy.points_to_enana'}) { $sp_eff = (($env->{'sysproxy.points_to_enana'} // '') eq 'yes') ? 1 : 0; }
  my $sp_all = ($env->{'sysproxy.points_to_enana'} // '') eq 'yes';
  my $tun_ready = ($env->{'capture.tun.ready'} // '') eq 'yes';
  my $logged = ($meta->{'account.logged_in'} // '') eq 'yes';
  my $have_state = scalar(grep { $_->{kind} eq 'state' } @$H);
  my $have_samples = scalar(grep { is_sample($_) } @$H);

  # ---- 状态开始的时间: 从健康记录里的 state 行往回找 (没有就从操作记录里找)
  my $state_since = sub { my ($key, $want) = @_; my $since; for my $r (reverse grep { $_->{kind} eq 'state' } @$H) { my $d = detail_kv($r->{detail}); last unless defined $d->{$key}; if ($d->{$key} eq $want) { $since = $r->{ts}; } else { last; } } return $since; };

  # ---- 操作记录里和「为什么代理没在工作」有关的事件
  my @events; for my $o (@$ops) { next if @$o < 5; my ($ts, $who, $act, $det, $res) = @$o; next if $ts eq 'ts';
    push @events, { ts => $ts, e => epoch_of($ts) // 0, who => $who, act => $act, det => $det, res => $res, d => detail_kv($det) }; }
  my $last_off; for my $ev (reverse @events) { if ($ev->{act} =~ /^(关闭代理|退出账号|已被退出登录)$/ || ($ev->{act} eq '环境状态变化' && ($ev->{d}{item} // '') eq 'proxy' && ($ev->{d}{to} // '') eq '0')) { $last_off = $ev; last; } }
  my $last_on; for my $ev (reverse @events) { if ($ev->{act} eq '开启代理' || ($ev->{act} eq '环境状态变化' && ($ev->{d}{item} // '') eq 'proxy' && ($ev->{d}{to} // '') eq '1')) { $last_on = $ev; last; } }

  # ---- 节点 / 金丝雀统计
  my (%n_all, %n_rec, %c_rec, %c_all);
  for my $r (@$H) { next unless is_sample($r);
    if ($r->{kind} eq 'node') { my $x = $n_all{ $r->{target} } //= { n => 0, ok => 0 }; $x->{n}++; $x->{ok}++ if $r->{ok};
      if ($r->{e} >= $recent_from) { my $y = $n_rec{ $r->{target} } //= { n => 0, ok => 0, ms => 0 }; $y->{n}++; if ($r->{ok}) { $y->{ok}++; $y->{ms} += $r->{ms}; } } }
    else { my $x = $c_all{ $r->{target} } //= { n => 0, ok => 0 }; $x->{n}++; $x->{ok}++ if $r->{ok};
      if ($r->{e} >= $recent_from) { my $y = $c_rec{ $r->{target} } //= { n => 0, ok => 0, res => {} }; $y->{n}++; $y->{ok}++ if $r->{ok}; $y->{res}{ $r->{result} }++ unless $r->{ok}; } } }
  my $outs = find_outages($H, $now);
  my $first_ts = @$H ? $H->[0]{e} : undef; my $span = defined $first_ts ? $now - $first_ts : 0;

  # ---- 访问记录里 ChatGPT / OpenAI 的连接
  my $re_gpt = qr/(^|\.)(chatgpt\.com|openai\.com|oaistatic\.com|oaiusercontent\.com|chat\.com|sora\.com|openai\.org)$/i;
  my %g = (n => 0, direct => 0, proxy => 0, err => 0, rn => 0, rdirect => 0, rproxy => 0, rerr => 0); my (%g_reason, %g_app, %g_node, %g_err, %g_rreason, %g_rapp);
  my ($g_last_ok, $g_last_err);
  for my $a (@$acc) { next if @$a < 12 || $a->[0] eq 'ts'; my ($ts, undef, undef, $host, undef, $app, undef, $route, $node, $reason, $result, $err) = @$a;
    next unless $host =~ $re_gpt; my $e = epoch_of($ts) // 0; my $rec = $e >= $recent_from;
    $g{n}++; $g_app{$app}++; $g{rn}++ if $rec;
    if ($route eq 'direct') { $g{direct}++; $g_reason{ $reason || 'policy' }++; if ($rec) { $g{rdirect}++; $g_rreason{ $reason || 'policy' }++; } } elsif ($route ne 'none') { $g{proxy}++; $g_node{$node}++; $g{rproxy}++ if $rec; }
    if ($result eq 'error') { $g{err}++; $g_err{ $err || 'other' }++; $g{rerr}++ if $rec; $g_last_err = $ts; } else { $g_last_ok = $ts; }
    $g_rapp{$app}++ if $rec; }
  my $list = sub { my ($h, $n) = @_; $n ||= 5; my @k = sort { $h->{$b} <=> $h->{$a} || $a cmp $b } keys %$h; @k = @k[0 .. $n - 1] if @k > $n; return join(',', map { "$_×$h->{$_}" } @k); };

  # ================= 判定 =================
  my @C;   # [code, blame, confidence, since, zh, en, evidence…]
  my $push = sub { push @C, [@_]; };
  my $why_off = $last_off ? "$last_off->{ts} $last_off->{who} $last_off->{act}" . ($last_off->{d}{reason} ? " (reason=$last_off->{d}{reason})" : '') : '';

  if (($meta->{'proxy.enabled'} // '') eq '0') {
    my $since = $state_since->('proxy', '0') // ($last_off ? $last_off->{ts} : '');
    $push->('proxy-disabled', 'client', 'high', $since,
      "代理总开关是关闭的, 所有流量都直连" . ($since ? " (自 $since 起)" : '') . ($why_off ? "; 最近一次关闭: $why_off" : '') . "。ChatGPT 等需要代理才能访问的网站在这个状态下一定打不开 —— 这不是节点问题。",
      "The master switch is off, so all traffic goes direct" . ($since ? " (since $since)" : '') . ($why_off ? "; last switched off: $why_off" : '') . ". Sites such as ChatGPT cannot work in this state — it is not a node problem.",
      ($last_off && ($last_off->{act} eq '已被退出登录') ? "the session was ended by the cloud ($last_off->{d}{reason}) or the offline grace period" : ()));
  }
  if (($meta->{'service.running'} // '') eq '0') {
    my $since = $state_since->('core', '0') // '';
    $push->('core-down', 'client', 'high', $since, "代理核心没有运行" . ($since ? " (自 $since 起)" : '') . ", 流量没有进入 enana。可在仪表盘点「启动 / 重启服务」, 或终端运行 enana doctor。", "The proxy core is not running" . ($since ? " (since $since)" : '') . ", so no traffic reaches enana. Start it from the dashboard or run enana doctor.");
  }
  if ($cap eq 'system' && $sp_known && $proxy_on && $core_run && !$sp_eff) {
    my $since = $state_since->('sysproxy', '0') // '';
    $push->('sysproxy-off', 'client', 'high', $since,
      "系统代理没有指向 enana" . ($since ? " (自 $since 起)" : '') . ", 浏览器和 ChatGPT 等 App 的流量没有进入代理 (仍是直连)。在仪表盘概览 / 顶部提示条点「开启系统代理」即可 (2.3.8 起不需要终端)。",
      "The system proxy does not point to enana" . ($since ? " (since $since)" : '') . ", so browsers and apps such as ChatGPT connect directly. Use “Turn system proxy on” in the dashboard (no terminal needed from 2.3.8).");
  } elsif ($cap eq 'system' && $sp_known && exists $env->{'sysproxy.points_to_enana'} && $proxy_on && $core_run && $sp_eff && !$sp_all) {
    push @L, "note.sysproxy_partial=主要网络服务已指向 enana, 但还有其它网络服务没有 (不影响当前上网的那一个)";
  }
  if ($cap eq 'tun' && $proxy_on && !$tun_ready) {
    $push->('tun-not-ready', 'client', 'high', '', "已选择 Enhanced/TUN, 但 TUN 服务还没有就绪 (没有建立 utun 路由), 流量没有被接管。", "Enhanced/TUN is selected but the TUN service is not ready (no utun route), so traffic is not captured.");
  }
  # 本机网络 / 节点
  my $ctl = $c_rec{cn_direct}; my $ctl_down = $ctl && $ctl->{n} >= 2 && $ctl->{ok} / $ctl->{n} < .5;
  my @node_down; my @node_flaky;
  for my $t (sort keys %n_rec) { my $y = $n_rec{$t}; my $a = $n_all{$t};
    if ($y->{n} >= 3 && $y->{ok} / $y->{n} < .5) { push @node_down, $t; }
    elsif ($a->{n} >= 20 && ($a->{n} - $a->{ok}) >= 5 && ($a->{n} - $a->{ok}) / $a->{n} >= .03) { push @node_flaky, $t; } }
  if (@node_down && $ctl_down) {
    $push->('local-network-down', 'network', 'medium', '', "最近 30 分钟本机网络本身不通 (连苹果的对照站点都访问失败, 同时所有服务器端口也不通), 先检查 Wi-Fi / 网线 / 路由器 —— 不是服务器或 enana 的问题。", "In the last 30 minutes the local network itself was down (even Apple's control site failed along with every server port). Check Wi-Fi / cable / router — not the server or enana.");
  } elsif (@node_down) {
    my $d = join(', ', map { my $y = $n_rec{$_}; "$_ (" . pct($y->{ok}, $y->{n}) . ")" } @node_down);
    $push->('node-down', 'node', ($ctl ? 'high' : 'medium'), '', "服务器端口当前不可达 (最近 30 分钟可达率): $d。" . ($ctl ? "本机网络正常 (对照站点可访问), 说明是这台服务器 / 机房线路的问题" : "(没有本机网络的对照数据, 无法排除是本机断网; 看 health 分区里 cn_direct 是否同时失败)") . " —— 不是 enana 代码。", "Server port(s) currently unreachable (reachability over the last 30 minutes): $d. " . ($ctl ? "The local network is fine (the control site works), so the server or its network is at fault" : "There is no local-network control data, so a local outage cannot be ruled out — check whether cn_direct fails at the same time in the health section") . " — not enana.", map { "node=$_ recent=$n_rec{$_}{ok}/$n_rec{$_}{n}" } @node_down);
  }
  if (!@node_down) {
    my $g = $c_rec{google_204};
    if ($g && $g->{n} >= 2 && $g->{ok} / $g->{n} < .5 && !$ctl_down) {
      my $res = join(',', map { "$_×$g->{res}{$_}" } sort keys %{ $g->{res} });
      $push->('proxy-path-failing', 'node', 'medium', '', "服务器端口是通的, 但经过代理访问 Google 的探测连续失败 ($res): 服务器上的代理程序可能故障 / 配置被改 / 握手被干扰。到服务器上检查代理服务是否在运行。", "The server port is reachable but probes through the proxy keep failing ($res): the proxy program on the server may be down, reconfigured or interfered with. Check the service on the server.");
    }
  }
  if (@node_flaky && !@node_down) {
    my $d = join(', ', map { my $a = $n_all{$_}; "$_ (" . pct($a->{ok}, $a->{n}) . ", " . ($a->{n} - $a->{ok}) . " failures)" } @node_flaky);
    $push->('node-unstable', 'node', 'medium', '', "服务器端口间歇性不可达 (可达率, 失败次数): $d。见 health 分区的故障时段; 现在可能已恢复。", "Server port intermittently unreachable (reachability, failures): $d. See the outage windows in the health section; it may have recovered.");
  }
  # OpenAI
  my $oa = $c_rec{openai_api}; my $cw = $c_rec{chatgpt_web}; my $g204 = $c_rec{google_204};
  my $proxy_ok = $g204 && $g204->{n} >= 1 && $g204->{ok} / $g204->{n} >= .5;
  if ($oa && $oa->{n} >= 2 && ($oa->{res}{'region-blocked'} // 0) / $oa->{n} >= .5 && $proxy_ok) {
    $push->('openai-region-blocked', 'exit-ip', 'high', '', "OpenAI 对当前出口 IP 返回 403 (不支持的地区 / IP 被限制): 代理本身是通的 (Google 探测正常), 但 OpenAI 拒绝了这台服务器的出口 IP。换一个出口 IP / 线路, 或让服务器换 IP —— 不是 enana 代码问题。", "OpenAI answers 403 for the current exit IP (unsupported region / restricted IP): the proxy works (Google probe OK) but OpenAI refuses this server's exit IP. Change the exit IP or route — not an enana defect.");
  } elsif ($proxy_ok && $cw && $cw->{n} >= 2 && $cw->{ok} / $cw->{n} < .5) {
    my $res = join(',', map { "$_×$cw->{res}{$_}" } sort keys %{ $cw->{res} });
    $push->('chatgpt-unreachable-via-proxy', 'exit-ip', 'medium', '', "经过代理访问 Google 正常, 但访问 chatgpt.com 连续失败 ($res): 多半是这个出口 IP 被 OpenAI / Cloudflare 限制或线路到 OpenAI 的质量差。", "Google through the proxy works but chatgpt.com keeps failing ($res): most likely this exit IP is restricted by OpenAI / Cloudflare, or the path to OpenAI is poor.");
  }
  # 访问记录: ChatGPT 的流量走了哪里
  if ($g{rn} >= 3 && $g{rdirect} / $g{rn} >= .5) {
    $push->('chatgpt-direct', 'client', 'high', '', "最近 30 分钟里 ChatGPT / OpenAI 的 $g{rn} 条连接有 $g{rdirect} 条是直连 (原因: " . $list->(\%g_rreason) . "; 应用: " . $list->(\%g_rapp) . "): 流量根本没有走代理, 所以连不上。直连原因 app=应用被设成了「关」, site=网站被设成直连, mode=总开关关闭, cn=命中国内规则。", "In the last 30 minutes $g{rdirect} of $g{rn} ChatGPT/OpenAI connections went direct (reasons: " . $list->(\%g_rreason) . "; apps: " . $list->(\%g_rapp) . "): traffic is not using the proxy at all. Reasons: app=the app is set to off, site=the site is set to direct, mode=the master switch is off, cn=matched the China rules.");
  } elsif ($g{rn} >= 3 && $g{rproxy} > 0 && $g{rerr} / $g{rn} >= .5) {
    $push->('chatgpt-proxied-but-failing', 'node', 'medium', '', "最近 30 分钟里 ChatGPT / OpenAI 的 $g{rn} 条连接有 $g{rerr} 条失败, 它们走了代理 (出口: " . $list->(\%g_node) . "; 失败类型: " . $list->(\%g_err) . ")。对照 health 分区: 节点是否可达 / 经代理的探测是否正常。", "In the last 30 minutes $g{rerr} of $g{rn} ChatGPT/OpenAI connections failed although they used the proxy (exits: " . $list->(\%g_node) . "; errors: " . $list->(\%g_err) . "). Compare with the health section.");
  }

  # ---- 输出
  $add->('verdict.version', 1); $add->('verdict.generated_epoch', $now); $add->('verdict.generated', ts_of($now));
  $add->('verdict.data', ($have_samples ? "health_samples=$have_samples" : 'health_samples=0') . " state_lines=$have_state span=" . dur($span) . " access_rows=" . scalar(@$acc) . " ops_rows=" . scalar(@$ops));
  if (@C) {
    my $p = $C[0];
    $add->('verdict.cause', $p->[0]); $add->('verdict.blame', $p->[1]); $add->('verdict.confidence', $p->[2]); $add->('verdict.since', $p->[3]) if length $p->[3];
    $add->('verdict.summary.zh', $p->[4]); $add->('verdict.summary.en', $p->[5]);
    for my $i (6 .. $#$p) { $add->('verdict.evidence.' . ($i - 5), $p->[$i]); }
    for my $i (1 .. $#C) { $add->("verdict.also.$i", "$C[$i][0] ($C[$i][1]): $C[$i][4]"); }
  } else {
    my $enough = $have_samples >= 10;
    $add->('verdict.cause', $enough || @$acc ? 'no-issue-found' : 'insufficient-data'); $add->('verdict.blame', 'none'); $add->('verdict.confidence', $enough ? 'medium' : 'low');
    if ($enough) {
      $add->('verdict.summary.zh', '没有发现明确的故障: 代理总开关 / 核心 / 系统代理 / 服务器端口 / 经代理的探测当前都正常。如果某个 App 仍然连不上, 请在它连不上的那一刻重新导出日志, 并在 access 分区里查它的记录 (verdict.chatgpt.* 是 ChatGPT 相关的汇总)。');
      $add->('verdict.summary.en', 'No definite fault found: master switch, core, system proxy, server ports and probes through the proxy all look healthy right now. If an app still cannot connect, export again at that moment and look at its rows in the access section (verdict.chatgpt.* summarises ChatGPT).');
    } else {
      $add->('verdict.summary.zh', '数据不足: 健康记录还不够多 (2.3.8 起每分钟记录一次, 刚升级或刚开机时需要等几分钟)。先看 env / meta / policy 分区里的当前状态。');
      $add->('verdict.summary.en', 'Not enough data yet: health records are written every minute from 2.3.8; wait a few minutes after upgrading. Look at the current state in the env / meta / policy sections.');
    }
  }
  $add->('verdict.now.proxy_enabled', $proxy_on ? 'yes' : (defined $meta->{'proxy.enabled'} ? 'no' : 'unknown'));
  $add->('verdict.now.core_running', $core_run ? 'yes' : (defined $meta->{'service.running'} ? 'no' : 'unknown'));
  $add->('verdict.now.capture', $cap . ($cap eq 'system' ? (!$sp_known ? ' (system proxy state unknown)' : $sp_eff ? ' (system proxy -> enana)' : ' (system proxy NOT pointing to enana)') : ($tun_ready ? ' (tun ready)' : ' (tun not ready)')));
  $add->('verdict.now.logged_in', $logged ? 'yes' : (defined $meta->{'account.logged_in'} ? 'no' : 'unknown'));
  $add->('verdict.last_proxy_off', $last_off ? "$last_off->{ts} $last_off->{who} $last_off->{act} $last_off->{det}" : 'none-in-range');
  $add->('verdict.last_proxy_on', $last_on ? "$last_on->{ts} $last_on->{who} $last_on->{act}" : 'none-in-range');
  for my $t (sort keys %n_all) { my $a = $n_all{$t}; my $y = $n_rec{$t};
    $add->("verdict.node.$t", ($role{$t} ? "role=$role{$t} " : '') . "reachable=" . pct($a->{ok}, $a->{n}) . " ($a->{ok}/$a->{n})" . ($y ? " recent30m=" . pct($y->{ok}, $y->{n}) . ($y->{ok} ? " avg_ms=" . int($y->{ms} / $y->{ok} + .5) : '') : ' recent30m=no-data')); }
  for my $t (sort keys %c_all) { my $a = $c_all{$t}; my $y = $c_rec{$t};
    $add->("verdict.canary.$t", "ok=" . pct($a->{ok}, $a->{n}) . " ($a->{ok}/$a->{n})" . ($y ? " recent30m=" . pct($y->{ok}, $y->{n}) . ($y->{ok} == $y->{n} ? '' : ' errors=' . join(',', map { "$_×$y->{res}{$_}" } sort keys %{ $y->{res} })) : ' recent30m=no-data')); }
  my $i = 0; for my $o (@$outs) { last if ++$i > 12; $add->("verdict.outage.$i", ts_of($o->{start}) . ' ~ ' . ts_of($o->{end}) . sprintf(' %.0fmin %s/%s %s%s', $o->{minutes}, $o->{kind}, $o->{target}, $o->{result}, $o->{ongoing} ? ' ONGOING' : '')); }
  $add->('verdict.chatgpt', "conns=$g{n} direct=$g{direct} proxy=$g{proxy} errors=$g{err}" . ($g{n} ? " reasons=[" . $list->(\%g_reason) . "] apps=[" . $list->(\%g_app) . "] nodes=[" . $list->(\%g_node) . "] error_types=[" . $list->(\%g_err) . "]" : '') . ($g_last_ok ? " last_ok=$g_last_ok" : '') . ($g_last_err ? " last_error=$g_last_err" : ''));
  $add->('verdict.chatgpt.recent30m', "conns=$g{rn} direct=$g{rdirect} proxy=$g{rproxy} errors=$g{rerr}");
  print join("\n", @L), "\n";
}
