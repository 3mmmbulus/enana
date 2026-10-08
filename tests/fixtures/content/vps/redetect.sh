# 模拟 redetect: 和 provision 一样输出全部出口 IP 的节点 (ctl 里 ips=N 控制数量)
NAME=node
while [ $# -gt 0 ]; do case $1 in --name) NAME=${2:-node}; shift ;; esac; shift; done
mock_os
step 1; step 2; sleep 0.2; step 5
hop=$(c hop)
port=443; [ "$(c busy)" = 1 ] && port=2053
kv port "$port"; kv sni www.microsoft.com; kv public_key MOCKPUBLICKEY; kv short_id 0123456789abcdef; kv uuid 00000000-0000-4000-8000-000000000001
mock_ips | while read -r ip; do
  printf '##ip 10.0.0.%s %s eth0\n' "${ip##*.}" "$ip"
  printf '##node {"type":"socks","tag":"%s-%s","server":"127.0.0.1","server_port":%s,"version":"5"}\n' "$NAME" "$ip" "$hop"
done
exit 0
