# 套餐与权益 (为以后收费预留): 云端 plans / subscriptions 是唯一真相, 本机只缓存一份用于界面提示 (「Pro」徽标、即将推出的卡片);
# 真正的限制在云端 —— 受限内容 (如官方线路) 只有云端核对订阅后才会下发。依赖 common.sh session.sh。
#   $H/plan.json     云端返回的原样 JSON (一行)       $H/plan.checked   上次成功刷新的时间
PLAN_TTL=3600

plan_checked() { local c; [ -s "$H/plan.checked" ] && IFS= read -r c < "$H/plan.checked"; printf '%s' "${c:-0}"; }

plan_refresh() { # 从云端取最新套餐 (短超时); 0 = 已刷新; 没有云端会话 / 连不上返回 1
  local out code rc=1
  [ -n "$(session_id)" ] || return 1
  out=$(mktemp); code=$(CLOUD_MAXTIME=8 CLOUD_CONNECT=4 session_call "$out" GET /api/enana/v1/plan)
  if [ "$code" = 200 ] && grep -q '"plan":{' "$out"; then
    tr -d '\000-\037' < "$out" | cut -c1-8000 > "$H/plan.json.new" && chmod 600 "$H/plan.json.new" && mv "$H/plan.json.new" "$H/plan.json" && now > "$H/plan.checked" && rc=0
  fi
  rm -f "$out"; return $rc
}

plan_json() { # GET /api/plan 的主体 (不含最外层 ok); 没有缓存时是内置的「免费版」
  local f=$H/plan.json; [ -s "$f" ] || f=/dev/null
  /usr/bin/perl -CA -MJSON::PP -e '
    my ($f, $checked, $t_free, $t_pro) = @ARGV; local $/; my $raw = ""; if (open my $fh, "<", $f) { $raw = <$fh> // "" }
    my $d = eval { JSON::PP->new->utf8->decode($raw) }; $d = {} unless ref $d eq "HASH";
    my $p = ref $d->{plan} eq "HASH" ? $d->{plan} : { code => "free" }; my $code = $p->{code} // "free";
    my %T = (free => $t_free, pro => $t_pro);
    my $title = $T{$code} // $p->{title} // $code;
    my ($t, $f_) = (JSON::PP::true, JSON::PP::false);
    my $lim  = ref $d->{limits} eq "HASH" ? $d->{limits} : { devices_per_platform => ($p->{max_devices_per_platform} // 2) + 0 };
    my $feat = ref $d->{features} eq "HASH" ? $d->{features} : { core => { enabled => $t, tier => "free" }, sync => { enabled => $t, tier => "free" }, vps_deploy => { enabled => $t, tier => "free" }, official_proxy => { enabled => $f_, tier => "pro", reason => "upgrade", coming_soon => $t } };
    my $off  = ref $d->{official} eq "HASH" ? $d->{official} : { available => $f_, nodes => 0 };
    my $j = JSON::PP->new->utf8->canonical->encode({ plan => { code => $code, title => $title }, expires_at => $d->{expires_at}, checked => $checked + 0, limits => $lim, features => $feat, official => $off });
    $j =~ s/^\{//; $j =~ s/\}$//; print $j;' "$f" "$(plan_checked)" "$(_t "免费版")" "$(_t "专业版")"
}
