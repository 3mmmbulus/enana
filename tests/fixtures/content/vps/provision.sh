# 模拟 provision: 不改动任何东西; 输出的节点是指向本机测试用 socks 代理 (ctl 里的 hop=端口) 的 socks 节点, 这样本机的「验证连通」能真正走通。
NAME=node; DEPS=0
while [ $# -gt 0 ]; do case $1 in --name) NAME=${2:-node}; shift ;; --install-deps) DEPS=${2:-0}; shift ;; esac; shift; done
mock_os
step 1
[ "$SUP" != no ] || die E_VPS_UNSUPPORTED "$ZH" "$EN"
f=$(c fail); [ "$f" != E_VPS_PRIVILEGE ] || die E_VPS_PRIVILEGE "需要 root 权限" "Root privileges are required"
step 2
if [ "$(c missing)" = 1 ] && [ "$DEPS" != 1 ]; then die E_VPS_DEPS "缺少依赖: ca-certificates (没有获得安装许可)" "Missing dependencies: ca-certificates (installation was not approved)"; fi
[ "$f" != E_VPS_DEPS ] || die E_VPS_DEPS "安装依赖失败" "Failed to install dependencies"
sleep 0.3
step 3; sleep 0.2
step 4; sleep 0.2
step 5; sleep 0.2
hop=$(c hop); port=443
kv port "$port"; kv sni www.microsoft.com; kv public_key MOCKPUBLICKEY; kv short_id 0123456789abcdef; kv uuid 00000000-0000-4000-8000-000000000001
[ "$f" != E_VPS_VERIFY ] || die E_VPS_VERIFY "服务启动失败" "The service failed to start"
mock_ips | while read -r ip; do
  printf '##ip 10.0.0.%s %s eth0\n' "${ip##*.}" "$ip"
  printf '##node {"type":"socks","tag":"%s-%s","server":"127.0.0.1","server_port":%s,"version":"5"}\n' "$NAME" "$ip" "$hop"
done
exit 0
