# 偏好设置 (界面习惯): 表格每页条数、侧栏是否收起、主题、上次打开的设置标签页、测速选择、欢迎卡片是否收起 …
# 依赖 common.sh auth.sh session.sh。存在本机, 而不只是浏览器的 localStorage: 换浏览器不丢。登录账号后独立同步到官方云端 (明文 JSON,
# 不需要开启「云端同步」, 也不进入配置快照): 换一台电脑登录同一账号就能拿到; 两台电脑都改过, 以改动时间新的为准。
#
#   $H/prefs.json   一个 JSON 对象 (≤ 16 KB, 键名建议分命名空间如 table.sites.pageSize)
#   $H/prefs.meta   version= (本机每次变化 +1, 前端据此重新读取)  updated= (最近一次改动的时间, 秒: 两台电脑之间以它决定谁新)  synced= (上次和云端对上时的 version)
# 整体替换 (前端自己合并)。version > synced 就是还没上传的改动 (用版本号而不是秒: 同一秒内的两次改动也能分清); 从云端拉取时 updated 记成云端的时间, 所以不会反复拉取。

PREFS_MAX=16384
PREFS_CLOUD_EVERY=300              # 没有改动时, 每隔这么久向云端对一次 (秒)
PREFS_ERR=''; PREFS_VERSION=0

prefs_meta() { sed -n "s/^$1=//p" "$H/prefs.meta" 2>/dev/null | head -1; }
prefs_version() { local v; v=$(prefs_meta version); printf '%s' "${v:-0}"; }
prefs_json() { # GET /api/prefs 的主体 (不含最外层 ok)
  local p='{}' u; [ -s "$H/prefs.json" ] && p=$(cat "$H/prefs.json"); u=$(prefs_meta updated)
  printf '"prefs":%s,"version":%s,"updated":%s' "$p" "$(prefs_version)" "${u:-0}"
}

_prefs_lock() { local i=0; while ! mkdir "$H/.prefs.lock" 2>/dev/null; do
    if [ -n "$(find "$H/.prefs.lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rmdir "$H/.prefs.lock" 2>/dev/null || true; continue; fi
    i=$((i + 1)); [ "$i" -gt 25 ] && return 1; sleep 0.2; done; }
_prefs_unlock() { rmdir "$H/.prefs.lock" 2>/dev/null || true; }

# 写 prefs.meta: <version> <updated> [synced]  (synced 不给就保留原来的)
_prefs_write_meta() {
  local s=${3:-$(prefs_meta synced)}
  printf 'version=%s\nupdated=%s\nsynced=%s\n' "$1" "$2" "${s:-0}" > "$H/prefs.meta.new" && chmod 600 "$H/prefs.meta.new" && mv "$H/prefs.meta.new" "$H/prefs.meta"
}

# prefs_canon <JSON 对象文本文件>  -> 打印规范化后的紧凑 JSON (键排序); 不是 JSON 对象时返回 1
prefs_canon() {
  /usr/bin/perl -MJSON::PP -e 'local $/; my $j = <STDIN>; my $d = eval { JSON::PP->new->utf8->max_depth(12)->decode($j) }; exit 2 unless ref $d eq "HASH"; print JSON::PP->new->utf8->canonical->encode($d)' < "$1" 2>/dev/null
}

# prefs_set <文件>  校验 + 保存 (version +1, updated = 现在); 失败返回 1, 原因在 PREFS_ERR (中文原文); 成功后新版本号在 PREFS_VERSION
prefs_set() {
  local f=$1 out
  PREFS_ERR=''
  [ "$(wc -c < "$f" | tr -d ' ')" -le "$PREFS_MAX" ] || { PREFS_ERR="偏好设置太大 (最多 16 KB)"; return 1; }
  out=$(prefs_canon "$f") || { PREFS_ERR="偏好设置必须是一个 JSON 对象"; return 1; }
  [ "${#out}" -le "$PREFS_MAX" ] || { PREFS_ERR="偏好设置太大 (最多 16 KB)"; return 1; }
  _prefs_lock || { PREFS_ERR="系统繁忙, 请重试"; return 1; }
  PREFS_VERSION=$(( $(prefs_version) + 1 ))
  printf '%s' "$out" > "$H/prefs.json.new" && chmod 600 "$H/prefs.json.new" && mv "$H/prefs.json.new" "$H/prefs.json"
  _prefs_write_meta "$PREFS_VERSION" "$(now)"
  _prefs_unlock
}

# 换了 prefs.json 之后调用 (例如导入备份): 版本号 +1, 前端会重新读取; 这算一次本机的改动, 下次会上传
prefs_touch() {
  _prefs_lock || return 1
  PREFS_VERSION=$(( $(prefs_version) + 1 ))
  _prefs_write_meta "$PREFS_VERSION" "$(now)"
  _prefs_unlock
}

# ---------- 云端 (独立于配置快照; 没有开启「云端同步」也会同步) ----------
# prefs_cloud_sync: 登录后、本机改动后 (后台)、以及每隔 PREFS_CLOUD_EVERY 秒 (prefs_tick) 调用。
#   1. 本机有没上传的改动 (updated > synced): 推送。云端的改动时间更新 (409) 时, 下一步拉取。
#   2. 云端的改动时间比本机新: 拉取并应用 (版本号 +1, 前端据 prefs_version 重新读取)。
prefs_cloud_sync() {
  local lk="$H/.prefs-cloud.lock" out body pf upd ver syn loc code r cst
  auth_logged_in && [ -n "$(session_id)" ] || return 0
  _prefs_cloud_lock "$lk" || return 0
  out=$(mktemp); body="$out.body"; pf="$out.prefs"
  # 偏好内容和它的改动时间要一起读 (中间不能被写入)
  if _prefs_lock; then
    cp "$H/prefs.json" "$pf" 2>/dev/null || printf '{}' > "$pf"
    upd=$(prefs_meta updated); ver=$(prefs_version); _prefs_unlock
  else
    rm -f "$out" "$pf"; rmdir "$lk" 2>/dev/null; return 0
  fi
  upd=${upd:-0}; ver=${ver:-0}; syn=$(prefs_meta synced); syn=${syn:-0}
  if [ "$upd" -gt 0 ] && [ "$ver" -gt "$syn" ]; then                       # 1. 推送 (版本号比已同步的大 = 有没上传的改动)
    printf '{"stamp":%s,"prefs":' "$upd" > "$body"; cat "$pf" >> "$body"; printf '}' >> "$body"
    code=$(session_call "$out" PUT /api/enana/v1/prefs "$(cat "$body")")
    [ "$code" = 200 ] && _prefs_write_meta "$(prefs_version)" "$(prefs_meta updated)" "$ver"
  fi
  rm -f "$body"
  code=$(session_call "$out" GET /api/enana/v1/prefs)                        # 2. 拉取: 云端的改动时间比本机新
  if [ "$code" = 200 ] && grep -q '"exists":true' "$out"; then
    r=$(/usr/bin/perl -MJSON::PP -e 'local $/; my $j = <STDIN>; my $d = eval { JSON::PP->new->utf8->decode($j) }; exit 2 unless ref $d eq "HASH" && $d->{exists} && ref $d->{prefs} eq "HASH"; open my $o, ">", $ARGV[0] or exit 3; print $o JSON::PP->new->utf8->canonical->encode($d->{prefs}); close $o; print int($d->{stamp} || 0), "\n"' "$pf.cloud" < "$out") && cst=$r
    loc=$(prefs_meta updated); loc=${loc:-0}
    if [ -n "$cst" ] && [ "$cst" -gt "$loc" ] && [ "$(wc -c < "$pf.cloud" | tr -d ' ')" -le "$PREFS_MAX" ]; then
      _prefs_apply_cloud "$pf.cloud" "$cst"
    fi
  fi
  rm -f "$out" "$pf" "$pf.cloud"
  rmdir "$lk" 2>/dev/null || true
}

# 同时只允许一个同步在跑: 最多等 10 秒; 超过 2 分钟的旧锁视为残留
_prefs_cloud_lock() { # <锁目录>
  local i=0
  while ! mkdir "$1" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -gt 20 ] && return 1
    if [ -n "$(find "$1" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then rmdir "$1" 2>/dev/null; continue; fi
    sleep 0.5
  done
}

# 应用云端的偏好: <文件> <云端的改动时间>; updated 和 synced 都记成云端的时间 (不会因此又被当成本机的改动)
_prefs_apply_cloud() {
  local nv
  _prefs_lock || return 1
  cp "$1" "$H/prefs.json.new" && chmod 600 "$H/prefs.json.new" && mv "$H/prefs.json.new" "$H/prefs.json"
  nv=$(( $(prefs_version) + 1 ))
  _prefs_write_meta "$nv" "$2" "$nv"                    # 版本号 +1 (前端重新读取), 也记成「已同步」: 不会因此又被当成本机的改动
  _prefs_unlock
}

# 每分钟 (cmd_tick) 调用: 每 PREFS_CLOUD_EVERY 秒对一次云端 (别的电脑的改动在这里拉取; 离线时没上传的改动也在这里补传)
prefs_tick() {
  local last=0
  [ -f "$H/prefs.checked" ] && IFS= read -r last < "$H/prefs.checked"
  [ $(( $(now) - ${last:-0} )) -ge "$PREFS_CLOUD_EVERY" ] || return 0
  now > "$H/prefs.checked"
  prefs_cloud_sync
}
