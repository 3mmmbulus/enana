# 模拟 probe: 只读检测 (按 $ENANA_MOCK_CTL: os=debian12|ubuntu2404|debian10|centos  priv=root|sudo_nopass|sudo_password|none  missing=1  ips=N  deployed=1  busy=1 (默认端口被占用))
mock_os
kv os_id "$OS_ID"; kv os_version "$OS_VER"; kv os_codename "$OS_CN"; kv os_pretty "$OS_PRETTY"; kv arch amd64
kv supported "$([ "$SUP" = no ] && echo 0 || echo 1)"; kv support "$SUP"; kv support_note_zh "$ZH"; kv support_note_en "$EN"
p=$(c priv); kv privilege "${p:-root}"; kv init systemd
if [ "$(c missing)" = 1 ]; then kv dep_curl 1:7.88.1; kv dep_ca-certificates 0; kv dep_tar 1:1.34; kv dep_iproute2 1:6.1.0; kv dep_gzip 1:1.12; kv missing ca-certificates; kv all_missing 0
else kv dep_curl 1:7.88.1; kv dep_ca-certificates 1:20230311; kv dep_tar 1:1.34; kv dep_iproute2 1:6.1.0; kv dep_gzip 1:1.12; kv missing ""; kv all_missing 0; fi
kv node_installed 0; kv singbox_installed 0; kv singbox_version ""; kv deployed "$([ "$(c deployed)" = 1 ] && echo 1 || echo 0)"
kv firewall ufw_inactive; kv ipv6 "2001:db8::5"
if [ "$(c busy)" = 1 ]; then kv listening "22 80 443"; else kv listening "22 80"; fi
# (可选字段) 默认端口被别的服务占着: 云端脚本不去动它, 而是挑一个空闲端口, 并在部署之前就告诉本机「将要用哪个端口」(plan_port / plan_reason); 本机界面据此提示, 没有这两个字段就不假设任何端口
if [ "$(c busy)" = 1 ]; then kv plan_port 2053; kv plan_reason default_busy; fi
mock_ips | while read -r ip; do printf '##ip 10.0.0.%s %s eth0\n' "${ip##*.}" "$ip"; done
if [ "$SUP" != no ]; then
  [ "$(c missing)" = 1 ] && printf '##action deps|安装依赖 (apt-get): ca-certificates|Install dependencies (apt-get): ca-certificates\n'
  printf '##action core|下载并安装服务端 (SHA-256 校验)|Download and install the server (SHA-256 verified)\n'
  printf '##action config|生成配置与密钥|Generate the configuration and keys\n'
  printf '##action service|创建并启动 systemd 服务|Create and start the systemd service\n'
fi
exit 0
