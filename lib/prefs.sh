# 偏好设置 (界面习惯, 可跨设备同步): 表格每页条数、侧栏是否收起、主题、上次打开的设置标签页、测速选择、欢迎卡片是否收起 …
# 依赖 common.sh。存在本机, 而不只是浏览器的 localStorage: 换浏览器不丢, 并且打开「云端同步」后会随其它配置一起 (端到端加密) 同步到其它电脑。
#
#   $H/prefs.json   一个 JSON 对象 (≤ 32 KB, 键名建议分命名空间如 table.sites.pageSize)     $H/prefs.meta   version= updated=
# 整体替换 (前端自己合并); 每次写入 version +1。同步拉取了别的电脑的偏好后 version 也会变, 前端据此重新读取 (GET /api/state 里的 prefs_version)。

PREFS_MAX=32768
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

# prefs_canon <JSON 对象文本文件>  -> 打印规范化后的紧凑 JSON (键排序); 不是 JSON 对象时返回 1
prefs_canon() {
  /usr/bin/perl -MJSON::PP -e 'local $/; my $j = <STDIN>; my $d = eval { JSON::PP->new->utf8->max_depth(12)->decode($j) }; exit 2 unless ref $d eq "HASH"; print JSON::PP->new->utf8->canonical->encode($d)' < "$1" 2>/dev/null
}

# prefs_set <文件>  校验 + 保存 (version +1); 失败返回 1, 原因在 PREFS_ERR (中文原文); 成功后新版本号在 PREFS_VERSION
prefs_set() {
  local f=$1 out
  PREFS_ERR=''
  [ "$(wc -c < "$f" | tr -d ' ')" -le "$PREFS_MAX" ] || { PREFS_ERR="偏好设置太大 (最多 32 KB)"; return 1; }
  out=$(prefs_canon "$f") || { PREFS_ERR="偏好设置必须是一个 JSON 对象"; return 1; }
  [ "${#out}" -le "$PREFS_MAX" ] || { PREFS_ERR="偏好设置太大 (最多 32 KB)"; return 1; }
  _prefs_lock || { PREFS_ERR="系统繁忙, 请重试"; return 1; }
  PREFS_VERSION=$(( $(prefs_version) + 1 ))
  printf '%s' "$out" > "$H/prefs.json.new" && chmod 600 "$H/prefs.json.new" && mv "$H/prefs.json.new" "$H/prefs.json"
  printf 'version=%s\nupdated=%s\n' "$PREFS_VERSION" "$(now)" > "$H/prefs.meta.new" && chmod 600 "$H/prefs.meta.new" && mv "$H/prefs.meta.new" "$H/prefs.meta"
  _prefs_unlock
}

# 同步 / 导入换了 prefs.json 之后调用: 版本号 +1, 前端会重新读取
prefs_touch() {
  _prefs_lock || return 1
  PREFS_VERSION=$(( $(prefs_version) + 1 ))
  printf 'version=%s\nupdated=%s\n' "$PREFS_VERSION" "$(now)" > "$H/prefs.meta.new" && chmod 600 "$H/prefs.meta.new" && mv "$H/prefs.meta.new" "$H/prefs.meta"
  _prefs_unlock
}
