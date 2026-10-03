# Current sockets are independent evidence; a missing sing-box log is not.
# Inputs: lsof -FpcnT, ps -axo pid=,comm=, Clash /connections, overrides.tsv.
use strict; use warnings; use JSON::PP;
my ($sockets,$processes,$connections,$overrides,$mode)=@ARGV;
open my $ps,'<',$processes or die $!;
my %paths; while(<$ps>) { $paths{$1}=$2 if /^\s*(\d+)\s+(.+?)\s*$/; }
open my $cf,'<',$connections; local $/; my $raw=<$cf> // '{}'; close $cf;
my $live=eval { decode_json($raw) };
my $api_ok=ref $live eq 'HASH' && ref $live->{connections} eq 'ARRAY';
$live={} unless $api_ok;
my %captured;
for my $c (@{$live->{connections} || []}) {
  my $m=$c->{metadata} || {}; my $ip=$m->{sourceIP} // ''; $ip =~ s/^::ffff://;
  $captured{lc($m->{network} // 'tcp')."|$ip|".($m->{sourcePort} // '')}=1;
}
my %pol; { local $/="\n"; if(open my $ov,'<',$overrides) { while(<$ov>) { chomp; my @a=split /\|/; $pol{$a[1]}=$a[2] if $a[0] eq 'app'; } } }
sub private {
  my ($ip)=@_; $ip =~ s/%.*//; $ip =~ s/^::ffff://;
  return 1 if $ip =~ /^(?:localhost|::|::1|f[cd][0-9a-f]*:|fe[89ab][0-9a-f]*:|ff[0-9a-f]*:)/i;
  return 1 if $ip =~ /^(?:0|10|127)\./ || $ip =~ /^169\.254\./ || $ip =~ /^192\.168\./;
  return 1 if $ip =~ /^172\.(\d+)\./ && $1 >= 16 && $1 <= 31;
  return 1 if $ip =~ /^100\.(\d+)\./ && $1 >= 64 && $1 <= 127;
  return 1 if $ip =~ /^(\d+)\./ && $1 >= 224;
  return 0;
}
sub endpoint {
  my ($s)=@_; return ($1,$2) if $s =~ /^\[([^]]+)\]:(\d+)$/;
  return ($1,$2) if $s =~ /^(.*):(\d+)$/; return ('','');
}
my ($pid,$cmd,$name,$state,$net) = ('','','','','');
my %seen; my $count=0;
print "pid\tapp\tpolicy\tnetwork\tdestination\tobservation\tprocess_path\n";
sub emit {
  return unless $pid && $name =~ /->/ && $cmd ne 'sing-box';
  return if $state && $state !~ /ESTABLISHED|SYN_SENT/;
  my ($from,$to)=split /->/,$name,2; my ($sip,$sp)=endpoint($from); my ($dip,$dp)=endpoint($to);
  return unless $dp && !private($dip);
  my $path=$paths{$pid} // $cmd; my ($app)=$path =~ m{/([^/]+)\.app/}; $app //= $cmd;
  my $n=$net || ($state ? 'tcp' : 'udp'); $sip =~ s/^::ffff://;
  my $status=!$api_ok ? 'core-api-unavailable' : $captured{"$n|$sip|$sp"} ? 'captured' : $mode eq 'system' ? 'bypass-system-proxy' : 'tun-unobserved';
  # TUN unobserved is deliberately inconclusive: short sockets and polling
  # races can disappear between the OS and API snapshots.
  my $key="$pid|$n|$name"; return if $seen{$key}++;
  my $dest="$dip:$dp"; $dest =~ s/^(\d+\.\d+)\.\d+\.\d+/$1.*.*/;
  $dest =~ s/^([0-9a-f]+:[0-9a-f]*):[0-9a-f:]+:([0-9]+)$/$1:*:$2/i if $dip =~ /:/;
  print join("\t",$pid,$app,$pol{$app} // 'follow',$n,$dest,$status,$path),"\n"; $count++;
}
{ local $/="\n"; open my $sf,'<',$sockets or die $!; while(<$sf>) {
  chomp;
  if(/^p(\d+)/) { emit(); ($pid,$cmd,$name,$state,$net)=($1,'','','',''); }
  elsif(/^c(.*)/) { $cmd=$1; }
  elsif(/^f/) { emit(); ($name,$state,$net)=('','',''); }
  elsif(/^n(.*)/) { $name=$1; }
  elsif(/^TST=(.*)/) { $state=$1; }
  elsif(/^P(.*)/) { $net=lc $1; }
} emit(); }
print "# core_api_available=",($api_ok ? "yes" : "no"),"; sockets_observed=$count; scope=current-user; missing-log-is-not-evidence; tun-unobserved-is-inconclusive\n";
