# 模拟 probe: 只读检测 (按 $ENANA_MOCK_CTL: os=debian12|ubuntu2404|debian10|centos  priv=root|sudo_nopass|sudo_password|none  missing=1  ips=N  deployed=1)
mock_os
kv os_id "$OS_ID"; kv os_version "$OS_VER"; kv os_codename "$OS_CN"; kv os_pretty "$OS_PRETTY"; kv arch amd64
kv supported "$([ "$SUP" = no ] && echo 0 || echo 1)"; kv support "$SUP"; kv support_note_zh "$ZH"; kv support_note_en "$EN"
p=$(c priv); kv privilege "${p:-root}"; kv init systemd
if [ "$(c missing)" = 1 ]; then kv dep_curl 1:7.88.1; kv dep_ca-certificates 0; kv dep_tar 1:1.34; kv dep_iproute2 1:6.1.0; kv dep_gzip 1:1.12; kv missing ca-certificates; kv all_missing 0
else kv dep_curl 1:7.88.1; kv dep_ca-certificates 1:20230311; kv dep_tar 1:1.34; kv dep_iproute2 1:6.1.0; kv dep_gzip 1:1.12; kv missing ""; kv all_missing 0; fi
kv node_installed 0; kv singbox_installed 0; kv singbox_version ""; kv deployed "$([ "$(c deployed)" = 1 ] && echo 1 || echo 0)"
kv firewall ufw_inactive; kv listening "22 80"; kv ipv6 "2001:db8::5"
mock_ips | while read -r ip; do printf '##ip 10.0.0.%s %s eth0\n' "${ip##*.}" "$ip"; done
if [ "$SUP" != no ]; then
  [ "$(c missing)" = 1 ] && printf '##action deps|安装依赖 (apt-get): ca-certificates|Install dependencies (apt-get): ca-certificates\n'
  printf '##action core|下载并安装服务端 (SHA-256 校验)|Download and install the server (SHA-256 verified)\n'
  printf '##action config|生成配置与密钥|Generate the configuration and keys\n'
  printf '##action service|创建并启动 systemd 服务|Create and start the systemd service\n'
fi
exit 0
