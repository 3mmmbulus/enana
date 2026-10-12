# Optional macOS TUN backend. No networksetup calls: selecting a capture mode
# never changes the user's HTTP/HTTPS/SOCKS settings. Privileged operations use
# sudo in a terminal, or the native macOS administrator dialog in the dashboard.
enhanced_paths() {
  TUN_UID=$(id -u)
  TUN_LABEL="$LABEL.tun.$TUN_UID"
  # Fixture overrides (test_env) apply only under ENANA_TEST and only to unprivileged lookups. The root helper
  # independently uses its fixed Library paths and never trusts these values.
  TUN_ROOT=$(test_env ENANA_TUN_ROOT "/Library/Application Support/enana-$TUN_UID")
  TUN_PLIST="$(test_env ENANA_TUN_PLIST_DIR /Library/LaunchDaemons)/$TUN_LABEL.plist"
}
enhanced_configured() { grep -q '"type":"tun"' "$H/config.json" 2>/dev/null; }
enhanced_loaded() { enhanced_paths; launchctl print "system/$TUN_LABEL" >/dev/null 2>&1; }
enhanced_supported() { sb_ver; [ "$SB_MAJOR" -gt 1 ] || { [ "$SB_MAJOR" -eq 1 ] && [ "$SB_MINOR" -ge 12 ]; }; }
# Shell quoting and AppleScript quoting are distinct. Never interpolate user
# paths into shell/AppleScript source without quoting both layers.
enhanced_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
enhanced_admin() { # <命令串>: 整条命令 (每个参数都已 enhanced_quote 过) 交给 /bin/sh 以管理员身份执行。超过 64 KB 或含换行 → 返回 6, 弹框之前就拒绝
  local cmd=${1:-} rc ef msg esc
  ENHANCED_ADMIN_ERR=''                                  # 管理员框的结果 (只在弹框时设置): cancelled 用户点了取消 · failed 其它失败; 见 enhanced_result
  if [ "${#cmd}" -gt 65536 ]; then ENHANCED_ADMIN_ERR=preflight-command-size; return 6; fi
  case $cmd in *"
"*) ENHANCED_ADMIN_ERR=preflight-command-newline; return 6 ;; esac
  if [ -t 0 ] && [ -t 1 ]; then sudo /bin/sh -c "$cmd"
  elif sudo -n true >/dev/null 2>&1; then sudo -n /bin/sh -c "$cmd"
  else
    esc=$(printf '%s' "$cmd" | sed 's/\\/\\\\/g; s/"/\\"/g')
    ef=$(mktemp 2>/dev/null) || ef=/dev/null        # 建不了临时文件也要弹框; 这时拿不到错误文字, 取消只能记成 error
    osascript -e "do shell script \"$esc\" with administrator privileges" >&2 2>"$ef"; rc=$?
    msg=$(cat "$ef"); cat "$ef" >&2; [ "$ef" = /dev/null ] || rm -f "$ef"      # 错误文字照原样输出; 只是多留一份来判断是不是取消
    if [ "$rc" != 0 ]; then
      case $msg in *"(-128)"*) ENHANCED_ADMIN_ERR=cancelled ;; *) ENHANCED_ADMIN_ERR=failed ;; esac      # osascript 的取消码是带括号的 (-128), 不能只按 -128 子串匹配 (-1280 · 路径里的 -128 都不是取消)
    fi
    return "$rc"
  fi
}
enhanced_result() { # <返回码> -> 操作记录的结果: ok | cancelled (管理员密码框被取消) | error (其它失败; 和别的操作一样写 error, 失败筛选才能找到)
  if [ "$1" = 0 ]; then printf 'ok'; elif [ "${ENHANCED_ADMIN_ERR:-}" = cancelled ]; then printf 'cancelled'; else printf 'error'; fi
}
# The fingerprint of everything the root core was installed from EXCEPT the app/site policy rule sets (rules/*/ovr-*.json): those are plain routing data
# that enhanced_sync_ovr can push into the root snapshot without a restart (see enhanced_ovr_fingerprint). A change to anything else needs a full,
# administrator-authorised install, so the fingerprint must only move when the root snapshot would really differ:
#   - config.json is hashed with the clash_api "default_mode" value blanked. proxy_apply_mode rewrites that value in place on every master-switch / mode
#     toggle, but it is only the mode the core starts in when it has no remembered one: the live mode is pushed through the API (PATCH /configs) and
#     the core keeps it in cache.db (sing-box restores it on start), and every restart enana makes is followed by proxy_sync_mode. The one thing left
#     is a core that restarts on its own with a stale seed, which apply_config covers (enhanced_mode_resync).
#   - hidden files (rules/.updated is rewritten by every `enana update` even when no rule changed, .DS_Store), *.new and *.tmp (downloads and writes in
#     progress) are bookkeeping, not rule data.
#   - rules/<name>.srs files left flat by 2.3.22: the core reads only rules/<name>/<name>.srs, and the upgrade removes the flat copies after a verified start.
#     Counting them would change the fingerprint at that moment and ask for an administrator password on the next apply.
enhanced_config_hash() { sed 's/"default_mode":"[A-Za-z]*"/"default_mode":"-"/' "$H/config.json" 2>/dev/null | shasum -a 256 | awk '{print $1}'; }
# 快照里要带到 root 的文件 (相对 $H, 每行一个, C 排序): 规则集只要 rules/<目录>/<文件> (深一层或浅一层的都不带), 证书只要 certs/<名字>.crt。
# 名字的格式和 root 脚本的清单检查一样 (见 lib/enhanced-root.sh MANIFEST_PL): 隐藏文件、*.new、*.tmp、旧版留下的 rules/*.srs 都不带。
enhanced_snapshot_files() {
  { ( cd "$H" 2>/dev/null && find rules -mindepth 2 -maxdepth 2 -type f; find certs -mindepth 1 -maxdepth 1 -type f ) 2>/dev/null; } \
    | LC_ALL=C grep -E '^(rules/[A-Za-z0-9_][A-Za-z0-9._-]*/[A-Za-z0-9_][A-Za-z0-9._-]*|certs/[A-Za-z0-9._-]{1,40}\.crt)$' \
    | LC_ALL=C grep -Ev '\.(new|tmp)$' | LC_ALL=C sort
}
enhanced_data_hashes() { enhanced_snapshot_files | LC_ALL=C grep -v '/ovr-[^/]*\.json$' | while IFS= read -r rel; do shasum -a 256 "$H/$rel"; done 2>/dev/null; }
enhanced_fingerprint() {
  {
    printf 'autostart=%s\n' "${AUTOSTART:-1}"; shasum -a 256 "$SB"; printf 'config:%s\n' "$(enhanced_config_hash)"
    # Source checkouts and the installed copy must fingerprint identically.
    local impl
    for impl in enhanced.sh enhanced-root.sh; do printf 'implementation:%s %s\n' "$impl" "$(shasum -a 256 "$LIB/$impl" | awk '{print $1}')"; done
    enhanced_data_hashes
  } | LC_ALL=C sort | shasum -a 256 | awk '{print $1}'
}
enhanced_record_install() { # after a successful root install: remember what it was built from (see apply_config)
  enhanced_fingerprint > "$H/.enhanced-fingerprint"; enhanced_ovr_fingerprint > "$H/.enhanced-ovr-fingerprint"
  rm -f "$H/.enhanced-stopped"
  if type proxy_clash_mode >/dev/null 2>&1; then proxy_clash_mode > "$H/.enhanced-mode"; fi
}
enhanced_mode_resync() { # the mode baked into the root snapshot is only a seed (see above): when the wanted one differs, push it to the live core and remember it once the core reports it
  local want got; want=$(proxy_clash_mode)
  [ "$(cat "$H/.enhanced-mode" 2>/dev/null)" != "$want" ] || return 0
  proxy_sync_mode
  got=$(clash GET /configs 2>/dev/null | sed -n 's/.*"mode":"\([A-Za-z]*\)".*/\1/p' | head -1)
  [ "$(printf '%s' "$got" | tr 'A-Z' 'a-z')" != "$(printf '%s' "$want" | tr 'A-Z' 'a-z')" ] || printf '%s\n' "$want" > "$H/.enhanced-mode"
  return 0
}
enhanced_ovr_fingerprint() { # the app/site policy rule sets (written by ovr_sync); empty directory => a fixed hash
  { find "$H/rules" -mindepth 2 -maxdepth 2 -type f -name 'ovr-*.json' -exec shasum -a 256 {} \; 2>/dev/null; echo ovr; } | LC_ALL=C sort | shasum -a 256 | awk '{print $1}'
}

# ---- root helper: change an app/site policy in TUN mode (`sync`), bounce the root core (`restart`) or remove leftover routes (`cleanup`) without an administrator prompt ----
# Version 2 added `restart`; version 3 writes each rule set into its own directory (rules/<名字>/<名字>.json, see lib/tunrules-helper.pl); version 4 added `cleanup`.
# A helper installed by an older enana reports 1, 2 or 3, so enhanced_helper_ok rejects it and the next full install (one administrator authorisation, the same one
# that already follows any upgrade of enhanced.sh / enhanced-root.sh) replaces it. Nothing silently calls a helper that lacks the action or the layout.
TUNRULES_HELPER_VERSION=4
# 读 (可信判断) 用的路径可以被测试换成沙箱; 以 root 运行的一律用 enhanced_helper_root 的写死路径 (不经过 test_env: 环境变量不能决定 root 运行什么)
enhanced_helper_path() { enhanced_paths; printf '%s/usr/local/libexec/enana/tunrules-%s' "$(test_env ENANA_ROOT_PREFIX)" "$TUN_UID"; }
enhanced_helper_root() { enhanced_paths; printf '/usr/local/libexec/enana/tunrules-%s' "$TUN_UID"; }
# 助手的可信判断只看字节 (不再运行它查版本): 安装到 root 目录的助手必须和 enana 此刻渲染出来的一模一样 (见 os_helper_trusted)
enhanced_helper_render() { # <根目录> <标签> <launchctl 路径> < 模板 -> 渲染结果: 取用 lib/enhanced-root.sh 里 helper_render 的原文 (同一段函数, 两边字节一致)
  local f; f=$(sed -n '/^helper_render() {/,/^}/p' "$LIB/enhanced-root.sh")
  eval "$f"
  helper_render "$1" 0 "$2" "$3" "$TUNRULES_HELPER_VERSION"
}
enhanced_helper_expected() { enhanced_paths; enhanced_helper_render "$TUN_ROOT" "$TUN_LABEL" "$(test_env ENANA_TUN_LAUNCHCTL /bin/launchctl)" < "$LIB/tunrules-helper.pl" | shasum -a 256 | awk '{print $1}'; }
enhanced_helper_ok() { os_helper_trusted "$(enhanced_helper_path)" "$(enhanced_helper_expected)"; }
enhanced_ovr_bundle() { # {"ovr-pin.json": {...}, ...} from $H/rules/*/ovr-*.json (the helper validates it again, strictly)
  perl -MJSON::PP -MFile::Glob=:bsd_glob -e '
    my %o; for my $f (bsd_glob("$ARGV[0]/rules/*/ovr-*.json")) { my ($n) = $f =~ m{([^/]+)$}; open my $fh, "<", $f or next; local $/; my $d = eval { JSON::PP->new->utf8->decode(scalar <$fh>) }; $o{$n} = $d if ref $d eq "HASH"; }
    print JSON::PP->new->utf8->canonical->encode(\%o);' "$H"
}
enhanced_sync_ovr() { # 0 = synced (the running root core hot-reloads the files); non-zero = no/untrusted helper or rejected data -> caller does the full install
  local h; h=$(enhanced_helper_root)
  enhanced_helper_ok || return 1
  enhanced_ovr_bundle | sudo -n "$h" sync >/dev/null 2>"$H/enhanced-sync.log" || return 1
  enhanced_ovr_fingerprint > "$H/.enhanced-ovr-fingerprint"
}
# Restart the running root core without an administrator prompt: the root helper's `restart` action only runs `launchctl kickstart -k` on this user's
# own TUN daemon (see lib/tunrules-helper.pl). It is the right tool when nothing about the root snapshot changed (fingerprint identical): a full install
# would copy the very same files again and ask for a password for nothing. Returns non-zero when it cannot be used or failed; the caller then does
# the full, authorised install. ENHANCED_FAST_WHY says why (for the operation log).
enhanced_restart_fast() {
  ENHANCED_FAST_WHY=''
  enhanced_paths
  enhanced_configured || { ENHANCED_FAST_WHY=not-tun; return 1; }
  enhanced_loaded || { ENHANCED_FAST_WHY=not-loaded; return 1; }
  [ "$(enhanced_fingerprint)" = "$(cat "$H/.enhanced-fingerprint" 2>/dev/null)" ] || { ENHANCED_FAST_WHY=changed; return 1; }
  enhanced_helper_ok || { ENHANCED_FAST_WHY=no-helper; return 1; }
  # A policy edit that is still pending must reach the root snapshot before the restart loads it.
  if [ "$(enhanced_ovr_fingerprint)" != "$(cat "$H/.enhanced-ovr-fingerprint" 2>/dev/null)" ]; then enhanced_sync_ovr || { ENHANCED_FAST_WHY=sync-failed; return 1; }; fi
  sudo -n "$(enhanced_helper_root)" restart >/dev/null 2>"$H/enhanced-restart.log" || { ENHANCED_FAST_WHY=rejected; return 1; }
}
# 助手版本低于 4 (没有 cleanup) 时 enhanced_helper_ok 为假, 什么也不做
tun_residual_clean() { enhanced_helper_ok || return 0; sudo -n "$(enhanced_helper_root)" cleanup >"$H/enhanced-cleanup.log" 2>&1 || true; }
enhanced_stage_config() {
  # Explicitly open the config: decode(<>) evaluates the diamond in list
  # context and consumes the home/root arguments as additional filenames.
  perl -MJSON::PP -e '
    my ($file,$h,$r)=@ARGV; open my $fh,"<",$file or die "$file: $!";
    local $/; my $j=JSON::PP->new->utf8->decode(scalar <$fh>);
    sub walk { my ($x)=@_; if(ref $x eq "HASH") { for my $k(keys %$x) { if(($k eq "path" || $k eq "output" || $k =~ /_path$/) && !ref($x->{$k}) && index($x->{$k}, "$h/")==0) { $x->{$k}=$r.substr($x->{$k},length($h)); } else { walk($x->{$k}); } } } elsif(ref $x eq "ARRAY") { walk($_) for @$x; } }
    walk($j); print JSON::PP->new->utf8->encode($j);
  ' "$1" "$2" "$3"
}
# ---- 安装 TUN (见 lib/enhanced-root.sh 的 4.x): 数据 → 暂存 (每个文件只读一次) → 预检 (弹框之前) → 一条命令交给管理员执行 ----
ENHANCED_WRAP='umask 077 && d=$(/usr/bin/mktemp -d /private/tmp/enana-root.XXXXXX) && [ -n "$d" ] && printf '\''%s'\'' "$1" > "$d/b64" && /usr/bin/base64 -D < "$d/b64" > "$d/root.sh" && rm -f "$d/b64" && shift && exec /bin/bash -p "$d/root.sh" "$@" || { rm -rf "$d"; exit 2; }'
enhanced_inband_line() { # <脚本 SHA-256> <脚本 base64> <参数…> -> 一行 root 命令: 清空环境; 包装命令把脚本写进只有 root 能进的临时目录, 核对 SHA 后再运行
  local line a sha=$1 b64=$2; shift 2
  line="/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/sh -c $(enhanced_quote "$ENHANCED_WRAP") enana-root $(enhanced_quote "$b64") inband $(enhanced_quote "$sha")"
  for a in "$@"; do line="$line $(enhanced_quote "$a")"; done
  printf '%s' "$line"
}
enhanced_root_line() { # <已装好的 root 副本> <动作> <uid> -> 一行命令: 只运行这份副本 (它自己核对是 root 写的、0700 的普通文件)
  printf '%s' "/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash -p $(enhanced_quote "$1") $(enhanced_quote root) $(enhanced_quote "$2") $(enhanced_quote "$3")"
}
enhanced_preflight_refuse() { # <原因代码> [给用户看的一句话]: 弹框之前的拒绝 (调用方返回 6): 原因写进 enhanced-check.log, 一句话追加到 check.log
  ENHANCED_REFUSED=1; ENHANCED_REFUSED_WHY=$1                  # 和 root 的拒绝一样: 调用方不再重试 TUN (config.sh 改回系统代理)
  printf 'enana-root: refused: %s\n' "$1" > "$H/enhanced-check.log"
  printf '%s\n' "${2:-$(_t "TUN 没有启动: $1")}" >> "$H/check.log"
}
enhanced_stage_payloads() { # <暂存目录>: 每个文件只读一次, 摘要和拷贝用的是同一份字节 (lib/enhanced-root.sh 的 4.4b); 结果放进 ENH_SHA_* / ENH_B64_*
  local st=$1 rel sha man='' files v
  set -o pipefail
  ENH_SHA_SB=$(cat "$SB" | tee "$st/sing-box" | shasum -a 256 | awk '{print $1}') || { set +o pipefail; return 1; }
  ENH_SHA_CFG=$(enhanced_stage_config "$H/config.json" "$H" "$TUN_ROOT" | tee "$st/config.json" | shasum -a 256 | awk '{print $1}') || { set +o pipefail; return 1; }
  files=$(enhanced_snapshot_files)
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    mkdir -p "$st/${rel%/*}" || { set +o pipefail; return 1; }
    sha=$(cat "$H/$rel" | tee "$st/$rel" | shasum -a 256 | awk '{print $1}') || { set +o pipefail; return 1; }
    man="$man$sha  $rel"$'\n'
  done <<EOF
$files
EOF
  ENH_SHA_MAN=$(printf '%s' "$man" | tee "$st/manifest" | shasum -a 256 | awk '{print $1}') || { set +o pipefail; return 1; }
  v=$(cat "$LIB/tunrules-helper.pl"; printf x); v=${v%x}
  ENH_SHA_TPL=$(printf '%s' "$v" | shasum -a 256 | awk '{print $1}') || { set +o pipefail; return 1; }
  ENH_B64_TPL=$(printf '%s' "$v" | base64 | tr -d '\n') || { set +o pipefail; return 1; }
  ENH_SHA_OUT=$(printf '%s' "$v" | enhanced_helper_render "$TUN_ROOT" "$TUN_LABEL" "$(test_env ENANA_TUN_LAUNCHCTL /bin/launchctl)" | shasum -a 256 | awk '{print $1}') || { set +o pipefail; return 1; }
  v=$(cat "$LIB/enhanced-root.sh"; printf x); v=${v%x}
  ENH_SHA_SCRIPT=$(printf '%s' "$v" | shasum -a 256 | awk '{print $1}') || { set +o pipefail; return 1; }
  ENH_B64_SCRIPT=$(printf '%s' "$v" | base64 | tr -d '\n') || { set +o pipefail; return 1; }
  set +o pipefail
}
enhanced_start() {
  local stage rc name choice prov got line ref why refused
  enhanced_paths
  enhanced_supported || { printf '%s\n' 'Enhanced/TUN requires sing-box >= 1.12 (enana upgrade).' > "$H/check.log"; return 1; }
  ENHANCED_REFUSED=0; ENHANCED_REFUSED_WHY=''
  # 6.1 核心必须是官方的、钉死版本号下载的 (core_install 记下的来源); 没有记录 = 来源不明, 同样不行
  prov=$(sed -n 1p "$H/core-provenance" 2>/dev/null || true)
  case $prov in
    'pinned '*) ;;
    *) enhanced_preflight_refuse preflight-core-unpinned "$(_t 'TUN 需要官方的、钉死版本号的核心: 请运行 enana upgrade, 或改用系统代理模式')"; return 6 ;;
  esac
  # 6.2 核心和上一次校验过的不一样: 不让 root 运行没有校验过的文件 (没有记录 = 状态未知, 允许; 安装成功之后再写)
  [ -f "$SB" ] || { enhanced_preflight_refuse preflight-sb-missing; return 6; }
  if [ -f "$H/core-binary.sha256" ]; then
    got=$(shasum -a 256 "$SB" | awk '{print $1}')
    [ "$got" = "$(cat "$H/core-binary.sha256")" ] || { enhanced_preflight_refuse preflight-core-changed "$(_t '核心在校验之后被改动过: 请运行 enana upgrade')"; return 6; }
  fi
  # 6.3 快照里不能有符号链接 (cat 会顺着链接读到别处的文件)
  if [ -n "$(find "$H/rules" "$H/certs" -type l 2>/dev/null)" ]; then enhanced_preflight_refuse preflight-stage-link; return 6; fi
  stage=$(mktemp -d) || return 1
  clash GET /proxies > "$stage/selectors.json" 2>/dev/null || true
  enhanced_stage_payloads "$stage" || { rm -rf "$stage"; return 1; }
  # 配置里的路径 (只检查配置, 不读文件) 和它引用的快照文件
  if ! /bin/bash "$LIB/enhanced-root.sh" check-config "$stage/config.json" "$TUN_ROOT" > "$stage/refs" 2>/dev/null; then rm -rf "$stage"; enhanced_preflight_refuse preflight-config-path; return 6; fi
  enhanced_snapshot_files > "$stage/list"
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    printf '%s\n' "$ref" | LC_ALL=C grep -Eq '^(rules/[A-Za-z0-9_][A-Za-z0-9._-]*/[A-Za-z0-9_][A-Za-z0-9._-]*|certs/[A-Za-z0-9._-]{1,40}\.crt)$' || { rm -rf "$stage"; enhanced_preflight_refuse preflight-stage-name; return 6; }
    grep -qxF "$ref" "$stage/list" || { rm -rf "$stage"; enhanced_preflight_refuse preflight-ref-missing; return 6; }
  done < "$stage/refs"
  # refs / list 是 enana 自己用的清单: 留在暂存目录里就会被 root 当成多余文件拒绝 (stage-extra), 所以 root 看到的暂存目录只有它认的文件
  rm -f "$stage/refs" "$stage/list"
  # 一条命令 (每个参数都做了引用); 超过 64 KB 或含换行 → enhanced_admin 在弹框前返回 6
  line=$(enhanced_inband_line "$ENH_SHA_SCRIPT" "$ENH_B64_SCRIPT" install "$TUN_UID" "$stage" "$LABEL" "${AUTOSTART:-1}" "$(id -un)" "$TUNRULES_HELPER_VERSION" "$ENH_SHA_SB" "$ENH_SHA_CFG" "$ENH_SHA_MAN" "$ENH_SHA_TPL" "$ENH_SHA_OUT" "$ENH_B64_TPL")
  enhanced_admin "$line" > "$H/enhanced-check.log" 2>&1; rc=$?
  if [ "$rc" != 0 ]; then
    rm -rf "$stage"; cat "$H/enhanced-check.log" >> "$H/check.log"
    # 拒绝的判断看 root 自己写的那一行, 不能只看退出码: 弹框分支里 osascript 把 root 的退出码包成 1 (2/3/4/6 只有 sudo 分支原样返回)
    why=$(sed -n 's/.*enana-root: refused: //p' "$H/enhanced-check.log" | tail -1 | sed 's/ ([0-9]*)$//')
    refused=0
    case $rc in 2|3|4|6) refused=1 ;; esac
    [ -z "$why" ] || refused=1
    if [ "$refused" = 1 ]; then                      # 拒绝 (什么都没改): 不再重试 TUN; config.sh 决定怎么办 (不弹第二次框)
      ENHANCED_REFUSED=1
      ENHANCED_REFUSED_WHY=${why:-${ENHANCED_ADMIN_ERR:-refused}}
      type oplog >/dev/null 2>&1 && oplog "${OP_WHO:-auto}" "启动 TUN" "$(kv reason "$ENHANCED_REFUSED_WHY" state 'nothing changed')" error
    fi
    return "$rc"
  fi
  logs_rotate
  [ ! -f "$H/sing-box.log" ] || [ -L "$H/sing-box.log" ] || mv "$H/sing-box.log" "$H/sing-box.system.log"
  ln -sfn "$TUN_ROOT/sing-box.log" "$H/sing-box.log"
  # Switching from the user core to the root core uses a separate cache.
  # Restore selector choices through the authenticated API, never copy a live DB.
  enhanced_restore_selectors "$stage/selectors.json"
  rm -rf "$stage"
  enhanced_record_install
  printf '%s\n' "$ENH_SHA_SB" > "$H/core-binary.sha256"          # 之后启动时核对核心是不是还是这一份
}
enhanced_restore_selectors() {
  local name choice
  while IFS="$(printf '\t')" read -r name choice; do
    [ -n "$name" ] || continue
    clash PUT "/proxies/$name" "$choice" >/dev/null 2>&1 || true
  done < <(perl -MJSON::PP -e '
    local $/; my $j=eval { decode_json(<>) }; exit unless ref $j eq "HASH";
    my $p=$j->{proxies} || {}; for my $n(sort keys %$p) {
      next unless ($p->{$n}{type} // "") eq "Selector" && $n ne "SPEEDTEST" && defined $p->{$n}{now};
      my $url=$n; utf8::encode($url); $url =~ s/([^A-Za-z0-9_.~-])/sprintf("%%%02X",ord($1))/ge;
      print $url,"\t",JSON::PP->new->utf8->encode({name=>$p->{$n}{now}}),"\n";
    }' "$1")
}
# 0 = there is nothing for `stop` to do: the root daemon is not loaded AND cannot come back on its own. `stop` (enhanced-root.sh) unloads the job and also
# disables it, so it does not return at the next boot next to the user's own core; that state outlives the process. We know it holds when launchd lists
# the job as disabled (no root needed to ask) or when our own earlier `stop` succeeded and nothing has loaded the job since (the marker is dropped the
# moment a loaded daemon is seen and by every install). Unloaded but still enabled (someone booted it out by hand) is NOT idle: `stop` runs and disables it.
enhanced_idle() {
  enhanced_paths
  if enhanced_loaded; then rm -f "$H/.enhanced-stopped"; return 1; fi
  [ -f "$H/.enhanced-stopped" ] && return 0
  launchctl print-disabled system 2>/dev/null | grep -F "\"$TUN_LABEL\"" | grep -Eq '=> (true|disabled)'
}
# The plist stays after a stop (only `remove` deletes it), so "plist exists" alone does not mean a daemon is running: asking for administrator rights to
# stop an already-stopped daemon made every System Proxy start / stop prompt once the user had tried TUN.
enhanced_root_sys() { printf '/Library/Application Support/enana-%s' "$(id -u)"; }   # 以 root 运行的副本只在这个写死的目录里找 (ENANA_TUN_ROOT 只用于读, 不能让环境变量决定 root 运行哪个文件)
enhanced_root_action() { # stop|remove: 已装好的 root 副本 (ROOT/bin/enhanced-root.sh) 存在就只运行它; 没有, 或者它不可信 (root-copy-untrusted) 时, 用旧的 inband 形式再试一次 (每次都是一次授权)
  local act=$1 v sha b64 rc
  enhanced_paths
  if [ -f "$TUN_ROOT/bin/enhanced-root.sh" ]; then
    enhanced_admin "$(enhanced_root_line "$(enhanced_root_sys)/bin/enhanced-root.sh" "$act" "$TUN_UID")" > "$H/enhanced-root.log" 2>&1; rc=$?
    grep -q 'refused: root-copy-untrusted' "$H/enhanced-root.log" 2>/dev/null || { cat "$H/enhanced-root.log" >&2; return $rc; }
  fi
  v=$(cat "$LIB/enhanced-root.sh"; printf x); v=${v%x}
  sha=$(printf '%s' "$v" | shasum -a 256 | awk '{print $1}')
  b64=$(printf '%s' "$v" | base64 | tr -d '\n')
  enhanced_admin "$(enhanced_inband_line "$sha" "$b64" "$act" "$TUN_UID")" > "$H/enhanced-root.log" 2>&1; rc=$?
  cat "$H/enhanced-root.log" >&2
  return $rc
}
enhanced_stop() {
  local rc; enhanced_paths; [ -e "$TUN_PLIST" ] || return 0
  enhanced_idle && return 0
  enhanced_root_action stop; rc=$?
  [ "$rc" != 0 ] || : > "$H/.enhanced-stopped"
  return "$rc"
}
enhanced_remove() {
  enhanced_paths; [ -e "$TUN_PLIST" ] || [ -e "$TUN_ROOT" ] || return 0
  enhanced_root_action remove || return $?
  rm -f "$H/.enhanced-stopped"
}
enhanced_system_log() {
  if [ -L "$H/sing-box.log" ] && [ "$(readlink "$H/sing-box.log")" = "$TUN_ROOT/sing-box.log" ]; then
    logs_rotate; rm -f "$H/sing-box.log"; : > "$H/sing-box.log"
  fi
}
enhanced_ready() {
  enhanced_configured || return 0
  enhanced_loaded || return 1
  # Port readiness alone may refer to a leftover mixed-only core. Verify that
  # both address families actually route public traffic into a utun interface.
  local v4 v6
  v4=$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/ {print $2}')
  v6=$(route -n get -inet6 2606:4700:4700::1111 2>/dev/null | awk '/interface:/ {print $2}')
  case $v4:$v6 in utun*:utun*) [ "$v4" = "$v6" ] && ifconfig "$v4" 2>/dev/null | grep -q 'inet 172.19.0.1 ' ;; *) return 1 ;; esac
}
network_mode_set() {
  case ${1:-} in system|tun) ;; *) warn 'network-mode: system | tun'; return 1 ;; esac
  op_txn '切换流量接管模式' txn_settings "NETWORK_MODE=$1"
}

network_socket_diagnostics() {
  local tmp; tmp=$(mktemp -d)
  lsof -nP -a -u "$(id -un)" -iTCP -iUDP -FpcfnPT > "$tmp/sockets" 2>/dev/null || true
  ps -axo pid=,comm= > "$tmp/processes" 2>/dev/null || true
  clash GET /connections > "$tmp/connections" 2>/dev/null || true
  perl "$LIB/network-diagnostics.pl" "$tmp/sockets" "$tmp/processes" "$tmp/connections" "$H/overrides.tsv" "${NETWORK_MODE:-system}"
  rm -rf "$tmp"
}
network_diagnostics() {
  enhanced_paths
  printf 'capture.mode=%s\ncapture.system_proxy_scope=opt-in-apps-only\n' "${NETWORK_MODE:-system}"
  printf 'capture.tun.configured=%s\ncapture.tun.ready=%s\ncapture.tun.service=%s\n' "$(enhanced_configured && echo yes || echo no)" "$(enhanced_configured && enhanced_ready && echo yes || echo no)" "$TUN_LABEL"
  launchctl print "system/$TUN_LABEL" 2>/dev/null | awk '/^[[:space:]]*(state|pid|last exit code) = / {k=$0; sub(/^[[:space:]]*/,"",k); print "capture.tun." k}'
  printf 'capture.priority=master-off,lan,app-pin/nonbrowser,website,browser-fallback,global,cn,final\n'
  printf 'capture.note=No sing-box log does not prove an App had no traffic; inspect OS sockets.\n'
  route -n get 1.1.1.1 2>/dev/null | awk '/interface:/ {print "capture.route.ipv4=" $2}'
  route -n get -inet6 2606:4700:4700::1111 2>/dev/null | awk '/interface:/ {print "capture.route.ipv6=" $2}'
  route -n get 127.0.0.1 2>/dev/null | awk '/interface:/ {print "capture.route.localhost=" $2}'
  network_socket_diagnostics
}
