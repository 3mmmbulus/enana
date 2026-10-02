# 测试用的「模拟部署脚本」: 什么都不改动, 只按 $ENANA_MOCK_CTL 里的设置输出和真实脚本相同的协议 (协议说明见云端内容里的 vps/lib.sh)。
# 真实的部署脚本 (协议选择 / 依赖 / 服务端版本与校验值 / 配置生成) 属于 enana 云端的签名内容, 不在这个公开仓库里。
set -u
CTL=${ENANA_MOCK_CTL:-/dev/null}
c() { sed -n "s/^$1=//p" "$CTL" 2>/dev/null | head -1; }
step() { printf '##step %s\n' "$1"; }
kv()   { printf '##kv %s=%s\n' "$1" "$2"; }
die()  { printf '##err %s %s||%s\n' "$1" "$2" "${3:-$2}"; exit 3; }
mock_os() {
  case $(c os) in
    ubuntu2404) OS_ID=ubuntu; OS_VER=24.04; OS_CN=noble; OS_PRETTY="Ubuntu 24.04.1 LTS"; SUP=full; ZH="Ubuntu 24.04: 完整支持"; EN="Ubuntu 24.04: fully supported" ;;
    debian10)   OS_ID=debian; OS_VER=10; OS_CN=buster; OS_PRETTY="Debian GNU/Linux 10 (buster)"; SUP=best_effort; ZH="Debian 10 已停止维护: 尽力安装"; EN="Debian 10 is end-of-life: best effort" ;;
    centos)     OS_ID=centos; OS_VER=9; OS_CN=''; OS_PRETTY="CentOS Stream 9"; SUP=no; ZH="目前只支持 Debian 和 Ubuntu (当前系统: CentOS Stream 9)"; EN="Only Debian and Ubuntu are supported right now (this system: CentOS Stream 9)" ;;
    *)          OS_ID=debian; OS_VER=12; OS_CN=bookworm; OS_PRETTY="Debian GNU/Linux 12 (bookworm)"; SUP=full; ZH="Debian 12: 完整支持"; EN="Debian 12: fully supported" ;;
  esac
}
mock_ips() { local n i; n=$(c ips); n=${n:-1}; i=1; while [ "$i" -le "$n" ]; do printf '203.0.113.%s\n' $((8 + i)); i=$((i + 1)); done; }
