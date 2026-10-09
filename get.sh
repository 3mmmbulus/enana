#!/bin/bash
# enana 一键安装 / 升级 (macOS)  ·  One-line installer / upgrader for macOS
#
#   安装 (在任意终端执行):   curl -fsSL https://install.enana.cc | bash
#                            没有 curl 时:  wget -qO- https://install.enana.cc | bash
#   升级:                    enana self-update        (或再执行一遍上面的命令)
#   选项 (curl … | bash -s -- <选项>):
#       --yes        不询问, 直接安装          --upgrade   升级模式 (沿用现有设置, 不弹菜单)
#       --allow-downgrade  允许安装比已见过的版本更旧的版本 (默认拒绝, 防回滚)
#       --lang zh|en 指定界面语言              --force     已是最新版本时也重新安装
#
# 它会: 查询最新的 enana 版本 → 下载安装包 → 校验 SHA-256 (清单与安装包来自不同线路时要求一致) → 运行安装器。
# 安装的是「最新版本」; 终端只安装环境, 其余设置都在安装完成后打开的仪表盘里完成。
if [ -z "${BASH_VERSION:-}" ]; then          # 被 zsh / dash 等当脚本跑: 能找到脚本文件就切回 bash, 管道进来 (curl … | zsh) 的没有文件可切, 给出提示
  if [ -f "$0" ] && [ -r "$0" ]; then exec bash "$0" "$@"; fi
  printf '%s\n' "enana: please run the installer with bash:  curl -fsSL https://install.enana.cc | bash   (请用 bash 运行, 不是 sh / zsh)" >&2; exit 1
fi
set -eu

INSTALL_BASE=${ENANA_INSTALL_BASE:-https://install.enana.cc}
GH_REPO=${ENANA_GH_REPO:-3mmmbulus/enana}
GH_BASE=${ENANA_GH_BASE:-https://github.com}      # 测试时指向本机模拟的 GitHub
# 发布清单的签名公钥 (发布私钥只在发布者手里, 见 tools/sign-release.sh; 与云端内容签名的密钥是分开的)。
# 测试时可以用 ENANA_RELEASE_PUBKEY_FILE 指向测试公钥; 正常安装不要设置它。
RELEASE_PUBKEY_PEM='-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE4dmCCdutTP+gEoaT413bGYJWib/0
olPxbogWv3Z5lftak+4Mndh9O5PWbWzDR3QyArxxFc0NQzqOBR8o20HsJQ==
-----END PUBLIC KEY-----'
HOME_DIR=${ENANA_HOME:-$HOME/.enana}
YES=0; UPGRADE=0; FORCE=0; LANG_OPT=''; ALLOW_DOWNGRADE=0

while [ $# -gt 0 ]; do
  case $1 in
    --yes|-y) YES=1 ;;
    --upgrade) UPGRADE=1; YES=1 ;;
    --force) FORCE=1 ;;
    --allow-downgrade) ALLOW_DOWNGRADE=1 ;;   # 确实要装比已见过的版本更旧的版本时才加
    --lang) shift; LANG_OPT=${1:-} ;;
    --lang=*) LANG_OPT=${1#--lang=} ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (use --help)" >&2; exit 2 ;;
  esac
  shift
done

# ---------- 语言 ----------
if [ -z "$LANG_OPT" ]; then LANG_OPT=${ENANA_LANG:-}; fi
if [ -z "$LANG_OPT" ] && [ -f "$HOME_DIR/settings.env" ]; then LANG_OPT=$(sed -n 's/^LANG_UI=//p' "$HOME_DIR/settings.env" | head -1); fi
if [ -z "$LANG_OPT" ]; then
  _l=$(defaults read -g AppleLanguages 2>/dev/null | awk 'NR==2 { gsub(/[ ",]/, ""); print; exit }'); [ -n "$_l" ] || _l=${LANG:-}
  case $_l in zh*|ZH*) LANG_OPT=zh ;; *) LANG_OPT=en ;; esac
fi
case $LANG_OPT in zh|en) ;; *) LANG_OPT=en ;; esac
T() { if [ "$LANG_OPT" = zh ]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }   # T "中文" "English"

if [ -t 1 ]; then B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; N=$'\033[0m'; else B=; D=; G=; Y=; R=; C=; N=; fi
step() { printf '\n%s▸ %s%s\n' "$B$C" "$(T "$1" "$2")" "$N"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$(T "$1" "$2")"; }
info() { printf '    %s%s%s\n' "$D" "$(T "$1" "$2")" "$N"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$(T "$1" "$2")"; }
die()  { printf '\n  %s✗ %s%s\n' "$R" "$(T "$1" "$2")" "$N" >&2; [ -z "${3:-}" ] || printf '    %s\n' "$(T "$3" "$4")" >&2; exit 1; }
progress() { [ "${ENANA_PROGRESS:-}" = 1 ] && printf '##job %s %s %s\n' "$1" "$2" "$3"; return 0; }    # 供仪表盘「更新」任务读取进度

# ---------- 环境检查 ----------
case "$(uname -s 2>/dev/null)" in
  Darwin) ;;
  Linux) die "Linux 版暂未提供 (规划中); 目前支持 macOS, Windows 请用 PowerShell 命令: irm https://install.enana.cc | iex" "The Linux edition is not available yet (planned). enana supports macOS today; on Windows use the PowerShell command: irm https://install.enana.cc | iex" ;;
  MINGW*|MSYS*|CYGWIN*) die "这里是 Windows 上的 bash (Git Bash / MSYS)。请改用 PowerShell: irm https://install.enana.cc | iex" "This is a bash on Windows (Git Bash / MSYS). Please use PowerShell instead: irm https://install.enana.cc | iex" ;;
  *) die "不支持的系统: $(uname -s); 目前只支持 macOS" "Unsupported system: $(uname -s); enana currently supports macOS only" ;;
esac
[ "$(id -u)" -ne 0 ] || die "请不要用 sudo 运行 (需要管理员权限的步骤会自己要密码)" "Do not run this with sudo (steps that need admin rights will ask for your password)"
# 下载工具: curl (macOS 自带) → wget; 校验工具: shasum → sha256sum → openssl。缺什么就说清楚怎么办, 而不是半路报错
DL=''
if [ -n "${ENANA_DL+x}" ]; then case $ENANA_DL in curl|wget) DL=$ENANA_DL ;; esac            # ENANA_DL 只给测试 / 排查用: 指定用哪个 (curl | wget), 写别的值 = 当作两个都没有
elif command -v curl >/dev/null 2>&1; then DL=curl; elif command -v wget >/dev/null 2>&1; then DL=wget; fi
[ -n "$DL" ] || die "找不到下载工具 (curl 或 wget)" "Neither curl nor wget was found" "macOS 自带 curl; 如果被卸载了, 请安装 Xcode 命令行工具 (xcode-select --install) 或 Homebrew 后重试" "macOS ships with curl; if it was removed, install the Xcode Command Line Tools (xcode-select --install) or Homebrew and try again"
command -v tar >/dev/null 2>&1 || die "缺少命令: tar" "Missing command: tar"
if command -v shasum >/dev/null 2>&1; then SUMCMD='shasum -a 256'; elif command -v sha256sum >/dev/null 2>&1; then SUMCMD=sha256sum; elif command -v openssl >/dev/null 2>&1; then SUMCMD='openssl dgst -sha256 -r'
else die "缺少校验工具 (shasum / sha256sum / openssl)" "No checksum tool found (shasum / sha256sum / openssl)"; fi
sha256_of() { $SUMCMD "$1" | cut -d' ' -f1; }

# ---------- 查询最新版本 ----------
fetch() { # fetch <url> [最长秒数] -> stdout
  if [ "$DL" = wget ]; then wget -qO- -T "${2:-20}" --tries=1 "$1" 2>/dev/null; else curl -fsSL --connect-timeout 8 --max-time "${2:-20}" "$1" 2>/dev/null; fi
}
get_to() { # get_to <url> <输出文件> (不显示进度, 失败返回非 0)
  if [ "$DL" = wget ]; then wget -q -O "$2" -T 15 --tries=1 "$1" 2>/dev/null; else curl -fsSL --connect-timeout 8 --max-time 15 -o "$2" "$1" 2>/dev/null; fi
}
OSSL=/usr/bin/openssl; [ -x "$OSSL" ] || OSSL=$(command -v openssl || true)
# verify_manifest_from <基址> <输出文件>: 0 = 签名通过 (清单写入输出文件); 1 = 取不到清单或签名; 2 = 签名无效; 3 = 没有 openssl
verify_manifest_from() {
  local base=$1 out=$2 m s p rc=1
  m=$(mktemp) s=$(mktemp) p=$(mktemp)
  if get_to "$base/manifest.json" "$m" && get_to "$base/manifest.json.sig" "$s"; then
    if [ -n "${ENANA_RELEASE_PUBKEY_FILE:-}" ]; then cp "$ENANA_RELEASE_PUBKEY_FILE" "$p"; else printf '%s\n' "$RELEASE_PUBKEY_PEM" > "$p"; fi
    if [ -z "$OSSL" ]; then rc=3
    elif "$OSSL" dgst -sha256 -verify "$p" -signature "$s" "$m" >/dev/null 2>&1; then cp "$m" "$out"; rc=0
    else rc=2; fi
  fi
  rm -f "$m" "$s" "$p"; return $rc
}
# verified_manifest <基址> <来源名 zh> <来源名 en>: 标准输出只放清单原文; 提示信息走标准错误
verified_manifest() {
  local out rc=0
  out=$(mktemp); verify_manifest_from "$1" "$out" || rc=$?
  case $rc in
    0) { ok "$2 的版本清单签名校验通过" "$3: version manifest signature verified"; } >&2; cat "$out" ;;
    1) { info "$2 取不到版本清单或签名, 跳过这条线路" "$3: could not fetch the manifest or its signature; skipping"; } >&2 ;;
    2) { warn "$2 的版本清单签名无效 (可能被篡改), 已拒绝这条线路" "$3: the manifest signature is invalid (possibly tampered); this source is rejected"; } >&2 ;;
    3) { warn "这台电脑没有 openssl, 无法校验版本清单签名 (请安装 openssl 后重试)" "This computer has no openssl, so the manifest signature cannot be checked (install openssl and retry)"; } >&2 ;;
  esac
  rm -f "$out"; return 0
}
fetch_file() { # fetch_file <url> <输出文件>  (显示进度)
  if [ "$DL" = wget ]; then wget -q --show-progress -T 30 --tries=1 -O "$2" "$1" 2>/dev/null || wget -q -T 30 --tries=1 -O "$2" "$1"; else curl -fL --connect-timeout 10 --max-time 600 --progress-bar -o "$2" "$1"; fi
}
mfield() { printf '%s' "$1" | sed -n "s/.*\"$2\":\"\\([^\"]*\\)\".*/\\1/p" | head -1; }
mnum()   { printf '%s' "$1" | sed -n "s/.*\"$2\":\\([0-9]*\\).*/\\1/p" | head -1; }

step "查询最新版本" "Looking up the latest version"
progress 0 10 "检查新版本"
M1=$(verified_manifest "$INSTALL_BASE/dl" "官方源" "official source")
M2=$(verified_manifest "$GH_BASE/$GH_REPO/releases/latest/download" "GitHub 源" "GitHub source")
[ -n "$M1$M2" ] || die "连不上下载服务, 或版本清单签名无效, 请检查网络后重试" "Cannot reach the download service, or the version manifest signature is invalid; check your network and retry" "离线安装: 在有网络的电脑下载 $INSTALL_BASE/dl/ 里的 enana-<版本>.tar.gz, 解压后运行 bash install.sh" "Offline: download enana-<version>.tar.gz from $INSTALL_BASE/dl/ on another machine, extract it and run bash install.sh"
MAN=${M1:-$M2}
VER=$(mfield "$MAN" version); SHA=$(mfield "$MAN" sha256); SIZE=$(mnum "$MAN" size); URL=$(mfield "$MAN" url)
[ -n "$VER" ] && [ ${#SHA} -eq 64 ] && [ -n "$SIZE" ] && [ -n "$URL" ] || die "版本清单格式不对, 已中止" "The version manifest is malformed; aborting"
case $VER in *[!0-9.]*|'') die "版本号不合法: $VER" "Invalid version number: $VER" ;; esac
if [ -n "$M1" ] && [ -n "$M2" ]; then      # 两条线路都能连上: 两份清单必须一致 (防单点被篡改)
  [ "$(mfield "$M2" sha256)" = "$SHA" ] && [ "$(mfield "$M2" version)" = "$VER" ] || die "两条线路的版本清单不一致, 已中止 (可能被篡改)" "The manifests from the two sources disagree; aborting (possible tampering)"
fi
# 防回滚 (T1): 清单带发布序号 seq 和过期时间 expires (都在签名范围内)。见过的最大 seq 存在 $HOME_DIR/.release-seq。
SEQ=$(mnum "$MAN" seq); EXP=$(mnum "$MAN" expires); SEQ_FILE="$HOME_DIR/.release-seq"; SEEN=''
[ -f "$SEQ_FILE" ] && IFS= read -r SEEN < "$SEQ_FILE" || true
case $SEEN in ''|*[!0-9]*) SEEN='' ;; esac
if [ -z "$SEQ" ]; then
  [ -z "$SEEN" ] || die "版本清单没有发布序号, 但这台电脑已经见过带序号的清单, 已中止 (可能是回滚攻击)" "The manifest has no sequence number, but this computer has seen one; aborting (possible rollback)"
  warn "版本清单没有发布序号, 无法检查回滚 (旧版清单)" "The manifest has no sequence number, so rollback cannot be checked (legacy manifest)"
else
  if [ -n "$EXP" ] && [ "$(date +%s)" -gt "$EXP" ]; then die "版本清单已过期, 已中止 (请确认系统时间正确)" "The version manifest has expired; aborting (check your clock)"; fi
  if [ -n "$SEEN" ] && [ "$SEQ" -lt "$SEEN" ]; then
    if [ "$ALLOW_DOWNGRADE" = 1 ]; then warn "按 --allow-downgrade 安装较旧的版本 (序号 $SEQ < 已见过的 $SEEN)" "Installing an older release because of --allow-downgrade (seq $SEQ < seen $SEEN)"
    else die "版本清单比已见过的版本旧 (序号 $SEQ < $SEEN), 可能是回滚攻击, 已中止。确需安装旧版本请加 --allow-downgrade" "The manifest is older than one already seen (seq $SEQ < $SEEN); possible rollback attack; aborting. To install an older release on purpose, add --allow-downgrade"; fi
  fi
fi
OLD=''; [ -f "$HOME_DIR/VERSION" ] && IFS= read -r OLD < "$HOME_DIR/VERSION" || true
ok "最新版本: v$VER${OLD:+ (已安装 v$OLD)}" "Latest version: v$VER${OLD:+ (installed: v$OLD)}"
if [ -n "$OLD" ] && [ "$OLD" = "$VER" ] && [ "$FORCE" = 0 ] && [ "$UPGRADE" = 1 ]; then ok "已经是最新版本, 无需升级" "Already up to date"; progress 3 100 "完成"; exit 0; fi

# ---------- 确认 ----------
if [ "$YES" = 0 ]; then
  printf '\n  %s%s%s\n' "$B" "$(T "即将安装 enana v$VER 到 $HOME_DIR (只写你的用户目录; 设置系统代理时才会要管理员密码)。" "About to install enana v$VER into $HOME_DIR (user directory only; the admin password is asked only to set the system proxy).")" "$N"
  if ! (exec </dev/tty) 2>/dev/null; then die "需要确认, 但当前没有可交互的终端: 请加 --yes (curl -fsSL $INSTALL_BASE | bash -s -- --yes)" "Confirmation needed but there is no interactive terminal: add --yes (curl -fsSL $INSTALL_BASE | bash -s -- --yes)"; fi
  printf '  %s [Y/n] ' "$(T "继续安装?" "Continue?")"; read -r ans < /dev/tty || die "读取确认失败: 请加 --yes" "Could not read the confirmation: add --yes"
  case $ans in ''|y|Y|yes|YES|是) ;; *) echo; info "已取消" "Cancelled"; exit 0 ;; esac
fi

# ---------- 下载 + 校验 ----------
step "下载并校验安装包" "Downloading and verifying the package"
progress 1 30 "下载并校验新版本"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/enana-get.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
FILE=$(basename "$URL"); case $FILE in enana-*.tar.gz) ;; *) die "安装包文件名不合法" "Invalid package name" ;; esac
got=0
for src in "$INSTALL_BASE/dl/$FILE" "$GH_BASE/$GH_REPO/releases/download/v$VER/$FILE"; do
  info "下载 $src" "Downloading $src"
  fetch_file "$src" "$TMP/pkg.tgz" || true
  if [ -s "$TMP/pkg.tgz" ] && [ "$(wc -c < "$TMP/pkg.tgz" | tr -d ' ')" = "$SIZE" ] && [ "$(sha256_of "$TMP/pkg.tgz")" = "$SHA" ]; then got=1; break; fi
  warn "这条线路的下载不完整或校验不通过, 换下一条" "This source failed (incomplete or checksum mismatch); trying the next one"; rm -f "$TMP/pkg.tgz"
done
[ "$got" = 1 ] || die "安装包下载或校验失败 (已尝试所有线路)" "Package download or verification failed (all sources tried)"
ok "SHA-256 校验通过" "SHA-256 verified"
if [ -n "$SEQ" ] && { [ -z "$SEEN" ] || [ "$SEQ" -gt "$SEEN" ]; }; then mkdir -p "$HOME_DIR" && printf '%s\n' "$SEQ" > "$SEQ_FILE.tmp" && mv -f "$SEQ_FILE.tmp" "$SEQ_FILE"; fi
if tar -tzf "$TMP/pkg.tgz" 2>/dev/null | sed 's#^\./##' | grep -Eq '^/|(^|/)\.\.(/|$)'; then die "安装包里有不安全的路径, 已中止" "The package contains unsafe paths; aborting"; fi
mkdir -p "$TMP/src"; tar -xzf "$TMP/pkg.tgz" -C "$TMP/src" || die "解压失败" "Extraction failed"
SRC=$(find "$TMP/src" -maxdepth 2 -name install.sh -print | head -1); [ -n "$SRC" ] || die "安装包里没有 install.sh" "install.sh is missing from the package"
SRC=$(dirname "$SRC")

# ---------- 运行安装器 ----------
step "运行安装器" "Running the installer"
progress 2 50 "安装并重新生成配置"
args=(--lang "$LANG_OPT"); [ "$YES" = 1 ] && args+=(--yes); [ "$UPGRADE" = 1 ] && args+=(--upgrade); [ "$FORCE" = 1 ] && args+=(--force)
if [ "$YES" = 0 ] && [ -r /dev/tty ]; then bash "$SRC/install.sh" "${args[@]}" < /dev/tty; else bash "$SRC/install.sh" "${args[@]}" < /dev/null; fi
progress 3 100 "完成"
