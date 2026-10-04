# Official credentials live in a separate account/session-bound private cache.
# They never enter user imports, subscription URLs, cloud backups or public UI.
official_cache() { perl "$LIB/official-cache.pl" "$1" "$H" "$(session_id)" "${2:-}" "${3:-}" "${4:-}"; }
official_tag() { case $1 in enana-official-*) return 0 ;; *) return 1 ;; esac; }
official_fetch() { # validated private candidate; no credentials on stdout/logs
  local sid out code tmp; sid=$(session_id); [ -n "$sid" ] || return 1
  out=$(mktemp); tmp=$(mktemp); code=$(CLOUD_MAXTIME=12 CLOUD_CONNECT=4 session_call "$out" GET /api/enana/v1/nodes)
  if [ "$code" != 200 ] || ! perl "$LIB/official-cache.pl" validate "$H" "$sid" "$out" > "$tmp" 2>/dev/null || [ "$sid" != "$(session_id)" ]; then rm -f "$out" "$tmp"; return 1; fi
  chmod 600 "$tmp"; mv "$tmp" "$H/official.pending.json"; rm -f "$out"
}
txn_official() {
  official_fetch || { TXN_ERR="官方线路暂时无法刷新，请稍后重试"; return 1; }
  mv "$H/official.pending.json" "$H/official.json"; plan_refresh >/dev/null 2>&1 || true; now > "$H/official.checked"; chmod 600 "$H/official.checked"
}
official_blocked() { grep -q '"tag":"enana-official-' "$H/config.json" 2>/dev/null && [ -z "$(official_cache emit)" ]; }

official_pause_expired() {
  # TUN config changes need interactive authorization. Block current proxy use
  # until the user applies the new catalog; never prompt from a timer/GET page.
  if grep -q '"tag":"enana-official-' "$H/config.json" 2>/dev/null && [ "${PROXY_ENABLED:-0}" = 1 ]; then
    proxy_set_enabled 0; clash DELETE /connections >/dev/null 2>&1 || true
    oplog maintenance "官方线路授权已失效，已暂停代理" "请刷新官方线路后重新开启；自建节点和设置已保留" ok
  fi
}
official_tick() {
  local last=0 old new; [ -n "$(session_id)" ] || return 0
  [ -f "$H/official.checked" ] && IFS= read -r last < "$H/official.checked"
  if [ $(( $(now) - ${last:-0} )) -lt 600 ]; then
    [ -n "$(official_cache emit)" ] || official_pause_expired; return 0
  fi
  if ! official_fetch; then
    if [ -s "$H/official.json" ] && [ -z "$(official_cache emit)" ]; then official_pause_expired; fi
    return 0
  fi
  old=$(official_cache digest); new=$(official_cache digest "$H/official.pending.json")
  if [ "$old" = "$new" ] || { [ ! -s "$H/official.json" ] && [ -z "$(official_cache emit "$H/official.pending.json")" ]; }; then
    mv "$H/official.pending.json" "$H/official.json"; now > "$H/official.checked"
  elif [ "${NETWORK_MODE:-system}" = tun ]; then
    now > "$H/official.checked"; [ -n "$(official_cache emit)" ] && [ -n "$(official_cache emit "$H/official.pending.json")" ] || official_pause_expired
  else
    [ -n "$(official_cache emit "$H/official.pending.json")" ] || official_pause_expired
    op_txn "刷新官方线路" txn_official >/dev/null 2>&1 || true
    [ -n "$(official_cache emit)" ] || official_pause_expired
  fi
}
sharing_request() { # Local bridge; select ONE user-owned outbound, never SSH data.
  local op=$1 file=${2:-} body out code result
  body=''
  if [ "$op" = write ]; then
    body=$(perl -MJSON::PP -MDigest::SHA=sha256_hex -e '
      my($file,$nodes)=@ARGV;local $/;open my $f,"<",$file or exit 1;my $b=eval{decode_json(<$f>)};exit 1 unless ref $b eq "HASH" && defined $b->{tag} && !ref $b->{tag} && JSON::PP::is_bool($b->{consent});my $tag=$b->{tag};exit 1 if $tag=~/^enana-official-/;
      my $r={key=>substr(sha256_hex($tag),0,32),consent=>$b->{consent}};
      if($b->{consent}){exit 1 unless ($b->{revision}//"") eq "server-sharing-v1";open my $n,"<",$nodes or exit 1;local $/="\n";my $found;while(<$n>){my $d=eval{decode_json($_)};next unless ref $d eq "HASH" && ref $d->{outbound} eq "HASH" && ($d->{outbound}{tag}//"") eq $tag;exit 1 if $d->{sub} || $d->{official};$r->{outbound}=$d->{outbound};$r->{label}=$tag;$r->{revision}=$b->{revision};$found=1;last}exit 1 unless $found}
      print encode_json($r);
    ' "$file" "$H/servers.jsonl") || { SHARING_CODE=E_SHARE_INVALID; return 1; }
  fi
  out=$(mktemp)
  if [ "$op" = write ]; then code=$(session_call "$out" POST /api/enana/v1/servers/share "$body"); else code=$(session_call "$out" GET /api/enana/v1/servers/shares); fi
  result=$(perl -MJSON::PP -e 'local $/;my $d=eval{decode_json(<>)};exit 1 unless ref $d eq "HASH" && JSON::PP::is_bool($d->{ok});my $r={ok=>$d->{ok}};if(!$d->{ok}){exit 1 unless ($d->{code}//"")=~/\AE_[A-Z_]+\z/;$r->{code}=$d->{code}}elsif(exists $d->{shares}){$r->{revision}="server-sharing-v1";$r->{shares}=[map {{key=>$_->{key},label=>$_->{label},status=>$_->{status},expires_at=>$_->{expires_at}}} @{$d->{shares}}]}else{$r->{status}=$d->{status}}print encode_json($r)' "$out" 2>/dev/null)
  rm -f "$out"; [ -n "$result" ] && { case $code in 200|400|403|409) printf '%s' "$result"; return 0 ;; esac; }
  SHARING_CODE=E_ACCOUNT_UNREACHABLE; return 1
}

sharing_mark() { # successful explicit mutation only; independent of cloud backup
  local tag=$1 on=$2
  local owner; owner=$(auth_acc_get id); [ -n "$owner" ] || return 0
  if [ "$(cat "$H/servers.shared.owner" 2>/dev/null)" != "$owner" ]; then : > "$H/servers.shared"; fi
  printf '%s\n' "$owner" > "$H/servers.shared.owner"; chmod 600 "$H/servers.shared.owner"
  touch "$H/servers.shared"; chmod 600 "$H/servers.shared"
  { grep -vxF -- "$tag" "$H/servers.shared" || true; [ "$on" = 1 ] && printf '%s\n' "$tag"; } > "$H/servers.shared.new"
  chmod 600 "$H/servers.shared.new"; mv "$H/servers.shared.new" "$H/servers.shared"
}
sharing_revoke_on_delete() {
  [ "$(cat "$H/servers.shared.owner" 2>/dev/null)" = "$(auth_acc_get id)" ] || return 0
  grep -qxF -- "$1" "$H/servers.shared" 2>/dev/null || return 0
  local body result; body=$(mktemp)
  perl -MJSON::PP -e 'print encode_json({tag=>$ARGV[0],consent=>JSON::PP::false})' "$1" > "$body"
  result=$(sharing_request write "$body"); rm -f "$body"
  printf '%s' "$result" | grep -q '"ok":true' || { TXN_ERR="请先联网撤销该服务器的共享授权，再删除服务器"; return 1; }
  sharing_mark "$1" 0
}
