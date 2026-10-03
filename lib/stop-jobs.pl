use strict;
use warnings;
use POSIX qw(getuid);
my ($home, $caller) = @ARGV;
die "Unsafe installation path\n" unless defined($home) && $home =~ m{^/} && $home ne '/';
sub snapshot {
    my %out;
    open my $ps, '-|', '/bin/ps', '-axo', 'uid=,pid=,ppid=,lstart=,command=' or die "Cannot inspect owned jobs\n";
    while (<$ps>) {
        if (/^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\w{3}\s+\w{3}\s+\d+\s+\d\d:\d\d:\d\d\s+\d{4})\s+(.*)$/) {
            $out{$2} = {uid=>$1, parent=>$3, start=>$4, command=>$5};
        }
    }
    close $ps or die "Cannot inspect owned jobs\n";
    return \%out;
}
my $all = snapshot(); my %keep; my $p = $caller;
while ($p && !$keep{$p}++) { $p = $all->{$p} ? $all->{$p}{parent} : 0; }
$keep{$$}=1;
my %owned;
for my $pid (keys %$all) {
    my $proc=$all->{$pid}; next if $keep{$pid} || $proc->{uid} != getuid();
    # Match the interpreter's script argument, never an arbitrary occurrence
    # of HomeDir in a URL, shell command, working directory or executable name.
    if ($proc->{command} =~ m{^(?:/[^ ]*/)?bash\s+\Q$home\E/(?:lib/api\.sh(?:\s|$)|enana\s+(?:_job|tick|maintain)(?:\s|$))}) { $owned{$pid}=1; }
}
my $added=1;
while ($added) {
    $added=0;
    for my $pid (keys %$all) {
        next if $keep{$pid} || $owned{$pid} || $all->{$pid}{uid} != getuid();
        if ($owned{$all->{$pid}{parent}}) { $owned{$pid}=1; $added=1; }
    }
}
for my $signal ('TERM','KILL') {
    my $fresh=snapshot();
    for my $pid (keys %owned) {
        my ($old,$now)=($all->{$pid},$fresh->{$pid});
        next unless $now && $old->{uid}==$now->{uid} && $old->{start} eq $now->{start} && $old->{command} eq $now->{command};
        kill $signal, $pid or die "Cannot stop owned background job\n" if $signal eq 'KILL';
        kill $signal, $pid if $signal eq 'TERM';
    }
    select undef,undef,undef,0.2;
}
