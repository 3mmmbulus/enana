# Authenticated bridge to the fixed cloud billing routes. No provider secrets,
# addresses or prices are supplied by the client, and nothing is cached on disk.
# Offline login remains usable, but purchases require a live device session.
billing_body() {
  perl -MJSON::PP -e '
    my ($op,$file)=@ARGV; local $/; open my $f,"<",$file or exit 1;
    my $raw=<$f>; exit 1 if length($raw)>16384;
    my $d=eval{decode_json($raw)}; exit 1 unless ref $d eq "HASH";
    my %v;
    if($op eq "checkout" || $op eq "purchase") {
      exit 1 unless defined $d->{request_key} && !ref($d->{request_key}) && $d->{request_key}=~/\A[A-Za-z0-9_-]{16,80}\z/;
      $v{request_key}=$d->{request_key};
      if($op eq "purchase" || ($d->{kind}//"") eq "plan") {
        exit 1 unless ($d->{sku}//"")=~/\A(?:m1|m3|m6|y1|y2|y3|y5)\z/;
        $v{sku}=$d->{sku}; $v{kind}="plan" if $op eq "checkout";
      } elsif(($d->{kind}//"") eq "topup") {
        exit 1 unless defined $d->{amount} && !ref($d->{amount}) && $d->{amount}=~/\A[0-9]{1,4}(?:\.[0-9]{1,6})?\z/;
        $v{amount}="$d->{amount}"; $v{kind}="topup";
      } else {exit 1}
    } elsif($op eq "cancel") {
      exit 1 unless ($d->{id}//"")=~/\A[a-z0-9]{15}\z/; $v{id}=$d->{id};
    } elsif($op eq "auto-renew") {
      exit 1 unless JSON::PP::is_bool($d->{enabled}); $v{enabled}=$d->{enabled};
    } elsif($op ne "email-send") {exit 1}
    print JSON::PP->new->canonical->encode(\%v);
  ' "$1" "$2"
}

billing_request() { # method, fixed route, optional validated JSON
  local out code result
  [ -n "$(session_id)" ] && [ -n "$(session_token)" ] || { BILLING_CODE=E_ACCOUNT_UNREACHABLE; return 1; }
  out=$(mktemp)
  code=$(CLOUD_MAXTIME=12 CLOUD_CONNECT=4 session_call "$out" "$1" "/api/enana/v1/$2" "${3:-}")
  # Never relay an upstream HTML error page or an unexpected/token-bearing body.
  result=$(perl -MJSON::PP -e '
    local $/; my $s=<>; exit 1 if length($s)>131072;
    my $d=eval{decode_json($s)}; exit 1 unless ref $d eq "HASH" && JSON::PP::is_bool($d->{ok});
    if(!$d->{ok}) {my $c=$d->{code}//""; exit 1 unless $c=~/\AE_[A-Z_]+\z/;print encode_json({ok=>JSON::PP::false,code=>$c})}
    else {exit 1 if exists $d->{token} || exists $d->{provider_key} || exists $d->{scanner_secret};print encode_json($d)}
  ' "$out")
  rm -f "$out"
  case $code in 200|400|403|404|409|429|503) ;; *) BILLING_CODE=E_ACCOUNT_UNREACHABLE; return 1 ;; esac
  [ -n "$result" ] || { BILLING_CODE=E_ACCOUNT_UNREACHABLE; return 1; }
  printf '%s' "$result"
}
