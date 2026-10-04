#!/usr/bin/perl
use strict; use warnings; use JSON::PP; use Digest::SHA qw(sha256_hex);
my ($op,$home,$sid,$input,$tag,$role)=@ARGV; my $J=JSON::PP->new->utf8->canonical;
sub read_doc { my($f)=@_;open my $fh,'<',$f or return {};local $/;my $s=<$fh>;return {} if length($s)>1048576;my $d=eval{$J->decode($s)};return ref $d eq 'HASH'?$d:{} }
my $d=read_doc($input||"$home/official.json");
my $valid=($sid&&($d->{session_id}//'') eq $sid&&($d->{expires_at}//0)>time&&$d->{entitled}&&$d->{email_verified}&&ref $d->{nodes} eq 'ARRAY');
my $roles=read_doc("$home/official.roles.json");
sub nodes { return $valid?@{$d->{nodes}}:() }
sub bad { die "Invalid official node response\n" }
if($op eq 'validate'){
 bad() unless ($d->{session_id}//'') eq $sid && ($d->{user_id}//'')=~/\A[a-z0-9]{15}\z/ && JSON::PP::is_bool($d->{entitled}) && JSON::PP::is_bool($d->{email_verified}) && ($d->{expires_at}//'')=~/\A[0-9]{10}\z/ && $d->{expires_at}>time && $d->{expires_at}<=time+3605 && ref $d->{nodes} eq 'ARRAY' && @{$d->{nodes}}<=300;
 bad() if (!$d->{entitled}||!$d->{email_verified})&&@{$d->{nodes}};
 my %seen;
 for my $n(@{$d->{nodes}}){my $o=$n->{outbound};bad() unless ref $n eq 'HASH' && ref $o eq 'HASH' && ($o->{tag}//'')=~/\Aenana-official-[a-z0-9]{15} [^"\\\x00-\x1f\x7f]{1,64}\z/ && !$seen{$o->{tag}}++ && ($o->{type}//'')=~/\A(?:http|socks|trojan|shadowsocks|vless|vmess|tuic|hysteria2|anytls)\z/ && ($o->{server_port}//0)>0 && $o->{server_port}<=65535 && ($o->{server}//'')=~/\A[a-zA-Z0-9.-]{1,253}\z/;
  bad() if $J->encode($o)=~/"(?:detour|.*_path|bind_interface|routing_mark|private_key|certificate)":/;
 }
 print $J->encode($d);
}elsif($op eq 'digest'){
 print sha256_hex($J->encode({nodes=>$d->{nodes}||[],entitled=>$d->{entitled},email_verified=>$d->{email_verified},session_id=>$d->{session_id}}));
}elsif($op eq 'meta'){
 my @n=nodes();my $pending=-f "$home/official.pending.json";my $reason=($d->{reason}//'');$reason='expired_cache' if $d->{entitled}&&$d->{email_verified}&&!$valid;
 print $J->encode({ok=>JSON::PP::true,nodes=>scalar @n,pending=>$pending?JSON::PP::true:JSON::PP::false,expires_at=>$d->{expires_at}||0,reason=>$reason,dedicated=>{claude_clean=>scalar(grep {($_->{capability}//'') eq 'claude_clean'} @n)}});
}elsif($op eq 'emit'||$op eq 'list'){
 my $index=0;for my $n(nodes()){my $o=$n->{outbound};my $r=$roles->{$o->{tag}}// ($index==0?'pin':'auto');$index++;$r='auto' unless $r=~/\A(?:pin|auto|off)\z/;
  if($op eq 'emit'){# type and tag order is part of servers.sh's format contract.
   my %tail=%$o;delete @tail{qw(type tag)};my $tail=$J->encode(\%tail);$tail=~s/^\{//;$tail=~s/\}$//;
   print join("\t",$r,$o->{tag},'{"type":'.$J->encode($o->{type}).',"tag":'.$J->encode($o->{tag}).','.$tail.'}'),"\n";
  }else{print join("\t",@$o{qw(tag type server server_port)},$r,'',1),"\n"}
 }
}elsif($op eq 'role'){
 die "Invalid official role\n" unless ($role//'')=~/\A(?:pin|auto|off)\z/ && grep {$_->{outbound}{tag} eq $tag} nodes();
 $roles->{$tag}=$role;open my $f,'>',"$home/official.roles.json.new" or die;print $f $J->encode($roles);close $f;chmod 0600,"$home/official.roles.json.new";rename "$home/official.roles.json.new","$home/official.roles.json" or die;
}else{die "Unknown official operation\n"}
