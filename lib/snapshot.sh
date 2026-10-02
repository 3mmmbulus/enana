# 配置快照 (导出备份 / 云端同步): 把「可以跨电脑同步」的本机配置打成一个 JSON, 或把快照应用回本机。实现在 lib/snapshot.pl (perl + JSON::PP, macOS 自带)。
# 依赖 common.sh device.sh。快照里永远没有令牌 / 会话 / 设备编号 / 端口 / 代理总开关 / SSH 凭据; 格式见 snapshot.pl 开头。
snap_build() { /usr/bin/perl "$LIB/snapshot.pl" build "$H" "$VERSION" "$(device_name)" "${1:-}"; }    # [all] -> 快照 JSON (stdout); 默认只含「保存到云端」的服务器 / 订阅, all = 全部 (导出备份)
snap_info()  { /usr/bin/perl "$LIB/snapshot.pl" info "$1"; }                                          # <快照文件> -> 摘要 JSON; 格式不对返回 2
snap_apply() { /usr/bin/perl "$LIB/snapshot.pl" apply "$H" "$1" "$2"; }                               # <快照文件> <replace|merge> -> 摘要 JSON (changed: [...])
