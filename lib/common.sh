# 公共初始化: 路径、端口、版本、设置、终端输出。被 install.sh / api.sh 共用 (bash 3.2 兼容)。
# 约定: 先 source 本文件, 再 init_paths, 再 source 其它 lib, 最后 load_settings。不含任何服务器/密码信息。

CORE_PIN=1.14.2          # 经过测试的 sing-box 版本; 升级用 `enana upgrade`
ADMIN_PATH=/enana/admin     # 仪表盘 (后台) 的访问路径: http://127.0.0.1:<辅助服务端口>/enana/admin/
LABEL=com.enana.proxy
LABEL_API=com.enana.proxy.api
LABEL_UPD=com.enana.proxy.update
LABEL_TICK=com.enana.proxy.tick      # 每分钟一次: 流量统计采样 + 每 ~2 分钟一次登录会话心跳
LEGACY_HOME_NAME=.tokyo-proxy   # 品牌更名前 (v1/v2 早期) 的安装目录名, 安装时自动迁移到 ~/.enana

# 旧版环境变量名兼容: TPROXY_* -> ENANA_*
for _v in HOME YES SKIP_PROBE MENU_FORCE PLIST_DIR SHORTCUT_DIR ADMIN_USER ADMIN_PASSWORD LOG_LEVEL LANG; do
  eval "[ -z \"\${ENANA_$_v:-}\" ] && [ -n \"\${TPROXY_$_v:-}\" ] && export ENANA_$_v=\"\$TPROXY_$_v\""
done
unset _v

_t() { printf '%s' "$1"; }   # 翻译函数的占位, lib/i18n.sh 会覆盖它

jesc() { # JSON 字符串转义 (只处理 \ " 和控制字符)
  local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/ }; s=${s//$'\n'/ }; s=${s//$'\r'/ }; printf '%s' "$s"
}

content_file() { # <文件名> -> 路径: 登录后云端下发的最新已验证内容里的文件; 没有就用随程序自带的基线 (见 lib/cloud.sh, docs/ARCHITECTURE.md)
  local f="$H/cloud/content/$1"
  if [ -s "$f" ]; then printf '%s' "$f"; else printf '%s/%s' "$DATA" "$1"; fi
}

resolve_path() { # 解析符号链接 (macOS 12.3 以前没有 readlink -f)
  local p=$1 l
  while [ -L "$p" ]; do
    l=$(readlink "$p")
    case $l in /*) p=$l ;; *) p=$(dirname "$p")/$l ;; esac
  done
  printf '%s\n' "$(cd "$(dirname "$p")" && pwd -P)/$(basename "$p")"
}

# init_paths <入口脚本路径>: 设置 SELF SRC LIB DATA H VERSION
init_paths() {
  SELF=$(resolve_path "$1"); SRC=$(dirname "$SELF")
  case $SRC in */lib) SRC=$(dirname "$SRC") ;; esac
  LIB="$SRC/lib"; DATA="$SRC/data"
  if [ -f "$SRC/.enana-home" ]; then H=$SRC          # 已安装的副本: 目录就是它所在位置
  else H="${ENANA_HOME:-$HOME/.enana}"; fi          # 源码目录: 安装到 $H
  # Installer environment paths and the installed entry point must agree.
  # macOS aliases /tmp to /private/tmp; otherwise rollback regenerates an
  # identical configuration with different paths and restarts the old core.
  if [ -d "$H" ]; then H=$(cd "$H" && pwd -P)
  elif [ -d "$(dirname "$H")" ]; then H=$(resolve_path "$H"); fi
  VERSION=2.2.0; [ -s "$SRC/VERSION" ] && IFS= read -r VERSION < "$SRC/VERSION"
}

set_ui_url() { UI_URL="http://127.0.0.1:$API_PORT$ADMIN_PATH/"; }     # 后台地址: 由本地辅助服务直接提供, 路径固定为 /enana/admin/ (端口变了要重新调用)

settings_set() { # settings_set KEY VALUE   (调用方负责校验值; 写入 $H/settings.env)
  local k=$1 v=$2 f="$H/settings.env"
  mkdir -p "$H"; touch "$f"
  { grep -v "^$k=" "$f" || true; printf '%s=%s\n' "$k" "$v"; } > "$f.new" && mv "$f.new" "$f"; chmod 600 "$f" 2>/dev/null || true
}

load_settings() { # 可调项: 环境变量 > $H/settings.env > 默认值
  local p=${PORT:-} u=${UI_PORT:-} a=${API_PORT:-} s=${SPEED_PORT:-}
  PORT=7890; UI_PORT=9090; API_PORT=9091; SPEED_PORT=''; LOG_HOURS=''; LOG_DAYS=''; LOG_OPS=1; ACCESS_LOG=1; LOG_CORE=1; AUTO_SITES=0; AUTO_UPDATE=1; AUTOSTART=1; PROXY_ENABLED=0; PROXY_MODE=auto; NETWORK_MODE=system; LANG_UI=''
  ACCOUNT_URL=https://api.enana.cc; ACCOUNT_SITE=https://enana.cc     # 云端接口 / 官网 (官网只有一个首页: 账号的注册、登录、改密码都在仪表盘里)
  [ -f "$H/settings.env" ] && . "$H/settings.env"
  case $NETWORK_MODE in system|tun) ;; *) NETWORK_MODE=system ;; esac
  # 日志保留时长 (小时): 默认 3 天, 最短 12 小时, 最长 30 天; 旧版本的 LOG_DAYS (天) 自动换算
  [ -n "$LOG_HOURS" ] || { case $LOG_DAYS in ''|*[!0-9]*) LOG_HOURS=72 ;; *) LOG_HOURS=$((LOG_DAYS * 24)) ;; esac; }
  case $LOG_HOURS in ''|*[!0-9]*) LOG_HOURS=72 ;; esac; [ "$LOG_HOURS" -lt 12 ] && LOG_HOURS=12; [ "$LOG_HOURS" -gt 720 ] && LOG_HOURS=720
  [ -n "$p" ] && PORT=$p; [ -n "$u" ] && UI_PORT=$u; [ -n "$a" ] && API_PORT=$a; [ -n "$s" ] && SPEED_PORT=$s
  [ -n "${ENANA_ACCOUNT_URL:-}" ] && { ACCOUNT_URL=$ENANA_ACCOUNT_URL; ACCOUNT_SITE=${ENANA_ACCOUNT_SITE:-$ENANA_ACCOUNT_URL}; }     # 测试 / 自建
  [ -n "$SPEED_PORT" ] || SPEED_PORT=$((PORT + 2))
  set_ui_url                                          # 仪表盘 (后台) 地址; UI_PORT 现在只是代理核心的控制端口
  SB="$H/sing-box"
  case "$(uname -s)" in MINGW*|MSYS*) SB="$H/sing-box.exe" ;; esac
  GUI="gui/$(id -u)"
  PLIST_DIR="${ENANA_PLIST_DIR:-$HOME/Library/LaunchAgents}"
  PLIST="$PLIST_DIR/$LABEL.plist"
  PLIST_API="$PLIST_DIR/$LABEL_API.plist"
  PLIST_UPD="$PLIST_DIR/$LABEL_UPD.plist"
  PLIST_TICK="$PLIST_DIR/$LABEL_TICK.plist"
  LOGS="$H/logs"
  type i18n_init >/dev/null 2>&1 && i18n_init
  return 0
}

# ---------- 终端输出 (颜色仅在终端里启用; 文案自动翻译) ----------
if [ -t 1 ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; N=$'\033[0m'
else B=; DIM=; G=; Y=; R=; C=; N=; fi
STEPS=${STEPS:-0}; STEP_N=0
step() { STEP_N=$((STEP_N+1)); printf '\n%s[%d/%d] %s%s\n' "$B$C" "$STEP_N" "$STEPS" "$(_t "$1")" "$N"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$(_t "$1")"; }
info() { printf '    %s%s%s\n' "$DIM" "$(_t "$1")" "$N"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$(_t "$1")"; }
die()  { printf '\n  %s✗ %s%s\n' "$R" "$(_t "$1")" "$N" >&2; if [ -n "${2:-}" ]; then printf '    %s\n' "$(_t "$2")" >&2; fi; exit 1; }

confirm() { # confirm "问题" [默认 y|n]  非交互时取默认值 (--yes 视为确认)
  local def=${2:-n} a
  if [ -n "${ENANA_YES:-}" ]; then return 0; fi
  if [ ! -t 0 ]; then [ "$def" = y ]; return; fi                      # 非交互且没有 --yes: 取默认值 (危险操作默认 n)
  read -r -p "  $(_t "$1") [$( [ "$def" = y ] && echo Y/n || echo y/N )] " a || return 1
  case $a in y|Y|yes|是) return 0 ;; n|N|no|否) return 1 ;; *) [ "$def" = y ] ;; esac
}

now() { date +%s; }
human_age() { # 秒 -> "N 秒/分钟/小时/天" (经 _t 翻译)
  local s=$1
  if [ "$s" -lt 90 ]; then _t "${s} 秒"; elif [ "$s" -lt 5400 ]; then _t "$((s/60)) 分钟"
  elif [ "$s" -lt 129600 ]; then _t "$((s/3600)) 小时"; else _t "$((s/86400)) 天"; fi
}

pf() { # printf, 但格式串先翻译 (译文里的 %s 个数必须与原文一致; 用于带变量的整行输出)
  local f; f=$(_t "$1"); shift; printf "$f" "$@"
}

os_version() { if [ "${ENANA_PLATFORM:-darwin}" = windows ]; then win_bridge version; else sw_vers -productVersion; fi; }
os_arch() { if [ "${ENANA_PLATFORM:-darwin}" = windows ]; then printf '%s' "${ENANA_WINDOWS_ARCH:-amd64}"; else uname -m; fi; }
os_name() { if [ "${ENANA_PLATFORM:-darwin}" = windows ]; then printf Windows; else printf macOS; fi; }
os_api_loaded() { if [ "${ENANA_PLATFORM:-darwin}" = windows ]; then windows_worker_alive; else launchctl print "$GUI/$LABEL_API" >/dev/null 2>&1; fi; }
os_maintenance_loaded() { if [ "${ENANA_PLATFORM:-darwin}" = windows ]; then windows_worker_alive; else launchctl print "$GUI/$LABEL_UPD" >/dev/null 2>&1; fi; }
os_label_loaded() { if [ "${ENANA_PLATFORM:-darwin}" = windows ]; then windows_worker_alive; else launchctl print "$GUI/$1" >/dev/null 2>&1; fi; }
os_import_subscription() {
  if [ "${ENANA_PLATFORM:-darwin}" = windows ]; then windows_node import "$SRC/ui/importer.js" "$1" "${2:-auto}" "${3:-}"
  else osascript -l JavaScript "$LIB/importer-cli.js" "$SRC/ui/importer.js" "$1" "${2:-auto}" "${3:-}"; fi
}
