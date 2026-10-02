# 流量统计: 每分钟采样一次核心的 /connections, 累加到本机的 按小时 / 按天 / 按节点 的桶里 (只保留 3 个月)。依赖 config.sh(clash) servers.sh。
# 细节与精度说明见 lib/stats.pl。数据只在本机 ($H/stats/), 不上传。

STATS_DIR="$H/stats"
stats_collect() { # 由定时任务 `enana tick` 每分钟调用一次; 核心没运行时什么也不做
  nc -z 127.0.0.1 "$UI_PORT" 2>/dev/null || return 0
  local roles; roles=$(mktemp)
  srv_list | awk -F'\t' '{print $1 "\t" $5}' > "$roles"
  clash GET /connections 2>/dev/null | ENANA_NOW=$(now) perl "$LIB/stats.pl" collect "$STATS_DIR" "$roles" "$([ "${PROXY_ENABLED:-0}" = 1 ] && echo auto || echo direct)" || true
  rm -f "$roles"
}
stats_json() { perl "$LIB/stats.pl" report "$STATS_DIR" "$1"; }      # today | 3d | 7d | 30d | 90d
stats_purge() { [ -d "$STATS_DIR" ] && perl "$LIB/stats.pl" purge "$STATS_DIR"; return 0; }
