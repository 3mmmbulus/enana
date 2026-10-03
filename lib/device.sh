# 设备标识: 安装时生成的随机 UUID (不含任何硬件信息) + 电脑名称 / 平台 / 系统版本 / 架构。
# 云端只用它们显示「我的设备」并限制同时在线的设备数 (同一账号同一平台最多 2 台)。依赖 common.sh auth.sh(auth_rand_hex)。

device_uid() { # 生成并缓存; 重装系统/删除数据目录后会得到新的 uid (被视为新设备)
  local f="$H/device.id" u
  if [ ! -s "$f" ]; then
    u=$(uuidgen 2>/dev/null | tr 'A-Z' 'a-z')
    [ -n "$u" ] || u=$(auth_rand_hex 16)
    mkdir -p "$H"; printf '%s\n' "$u" > "$f.new" && chmod 600 "$f.new" && mv "$f.new" "$f"
  fi
  IFS= read -r u < "$f"; printf '%s' "$u"
}
device_name() {
  if [ "${ENANA_PLATFORM:-darwin}" = windows ]; then printf '%s' "${COMPUTERNAME:-Windows}"; return; fi
  local n; n=$(scutil --get ComputerName 2>/dev/null || hostname -s 2>/dev/null || true)
  n=$(printf '%s' "$n" | tr -d '"\\' | tr '\t\r\n' '   ' | cut -c1-60)
  printf '%s' "${n:-Mac}"
}
device_platform() { if [ "${ENANA_PLATFORM:-darwin}" = windows ]; then printf windows; else printf macos; fi; }
device_os()   { if type os_version >/dev/null 2>&1; then os_version 2>/dev/null || true; else sw_vers -productVersion 2>/dev/null || true; fi; }
device_arch() { if type os_arch >/dev/null 2>&1; then os_arch; else uname -m; fi; }
device_json() { # 登录时发给云端的设备信息 (不含序列号 / MAC 地址等硬件标识)
  printf '{"uid":"%s","name":"%s","platform":"%s","os":"%s","arch":"%s","app":"%s"}' \
    "$(device_uid)" "$(jesc "$(device_name)")" "$(device_platform)" "$(jesc "$(device_os)")" "$(device_arch)" "$VERSION"
}
