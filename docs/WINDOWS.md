# Windows 预览版 (2.3.3)

Windows 与 macOS 共用本机仪表盘、账号/设备 API、服务器管理、应用/网站分流、PIN/Global/direct、DNS、测速、日志和事务回滚。系统适配不另写一份分流引擎。

## 安装与升级

支持 Windows 10 2004 (build 19041)+ / Windows 11、x64 和 ARM64, 使用 64 位 PowerShell 5.1 或更高版本。无需 WSL 或预装 Git/Node。

```powershell
irm https://install.enana.cc/get.ps1 | iex
```

普通 PowerShell 窗口即可安装。默认目录 `%LocalAppData%\enana`, 下载可重试 3 次, 清单/包大小/SHA-256 与 ZIP 路径全部检查通过后才执行安装。安装会自动选择空闲端口并打开本机后台, 不会打开代理总开关。登录、添加服务器后再由用户开启代理。

2.3.1 修复了官网无参数命令的 `Lang` 默认值校验错误: 默认 `auto` 按系统语言选择中文或英文。无需通过执行策略 Bypass 解决该参数错误。2.3.2 进一步清理重复安装产生的分离任务, 避免升级 / 卸载时 Bash 占用私有运行时。

新终端输入 `enana` 打开终端控制台, 显示服务状态并提供启动、重启和诊断操作; 按 `1` 打开仪表盘。输入被重定向时仅输出状态。`enana doctor` 先读取 Windows 任务状态、上次退出码、运行时文件和启动日志, 再执行共享诊断; `enana diag` 导出同一格式的诊断日志。`enana self-update` 或再次执行安装命令升级, 保留端口、账号、服务器和模式。已有安装失败会恢复程序/配置并重新启动原服务。快捷命令写入当前用户 PATH, 不改机器 PATH。

安装包清单是 `https://install.enana.cc/dl/windows-manifest.json`, 包为 `enana-<version>-windows.zip`。与 macOS 的 `manifest.json` / tar.gz 分开, 防止旧客户端误下载另一平台的包。Windows 清单明确标记 `channel=preview`。

## 两种接管模式

| 模式 | 接管范围 | 权限 |
|---|---|---|
| System Proxy (默认) | 当前用户遵守 WinINet HTTP/HTTPS 代理的连接; mixed 仅监听 127.0.0.1 | 普通用户 |
| Enhanced/TUN (可选) | sing-box TUN 接管公网 TCP/UDP, 包括自行连接的应用 | UAC 管理员授权 |

在「设置 → 代理 → 流量接管方式」选择模式, 或使用 `enana network-mode tun` / `enana network-mode system`。切换有确认、进度、就绪验证和失败恢复。取消 UAC 保留原服务; 选择 TUN 不代表代理总开关已打开。自动/全局仍是路由策略, 与流量接管方式分别设置。

System Proxy 开启前备份 WinINet 手动/PAC/连接设置; 关闭时只恢复仍属于 enana 的设置。用户或其它代理修改后保留外部设置, 不强行覆盖。不会设置机器 WinHTTP 代理或劫持其它用户会话。

TUN 包含 IPv4/IPv6, 排除 localhost/127.0.0.0/8/::1、局域网/私网/链路本地和自身地址; 核心出口通过默认物理接口发出, 防止循环。就绪检查同时验证拥有的核心、适配器地址、公网双栈路由和 localhost 仍直连。与 VPN、虚拟网卡共用需要实机验收。

原生应用明确 PIN 高于网站; 浏览器策略作为网站规则后的兜底。EXE 所在应用目录中的辅助进程匹配同一规则, Squirrel `app-<version>` 更新不会丢失匹配。Windows/Program Files/WindowsApps 等共享目录只匹配选定 EXE, 防止将其它应用误设为 PIN。

只有被接管且能归属到应用的公网 TCP/UDP 可以继承应用 PIN。localhost/LAN、共享系统进程和无法归属的请求不能声明为该应用「全部流量」。这里没有 Gemini OAuth 域名补丁。

## 本机服务与管理员快照

- `windows/install.ps1` 下载 `runtime-pins.json` 中固定 SHA-256 的官方 PortableGit、Node 和 sing-box, 保留上游许可证, 放在私有目录。
- 当前用户的 `Enana Dashboard <SID>` 计划任务以 Limited 权限运行 `worker.js`, 只监听 127.0.0.1。HTTP 请求通过管道交给现有 `lib/api.sh`, 保留 Host/Origin/X-Enana/登录校验, 增加头/体大小、并发和超时边界。
- 普通 worker 管理自己的 System Proxy 核心、tick/维护任务, 不作为 SYSTEM 执行用户脚本。停止或升级只关闭当前安装拥有的进程。
- 代理核心启动失败时保留后台, 可继续查看诊断并重试启动。计划任务启动阶段的错误写入 `worke…8880 tokens truncated…up\tpath\n'
  apps_json | perl -MJSON::PP -e 'local $/; my $l = eval { decode_json(<STDIN>) } || []; for my $a (@$l) { my $p = $a->{path} // ""; $p =~ s{/Users/[^/]+}{/Users/<user>}; print join("\t", map { $_ // "" } @$a{qw(name state flag target)}, ($a->{known} ? "yes" : "no"), @$a{qw(rec group)}, $p), "\n" }'
}

_b_probe() { # <名称> <经过 proxy|direct> <地址> [curl 参数…]
  local n=$1 via=$2 url=$3 out rc; shift 3
  out=$(curl -s -o /dev/null -m 8 --connect-timeout 5 "$@" -w '%{http_code}\t%{time_connect}\t%{time_total}\t%{remote_ip}' "$url" 2>&1); rc=$?
  if [ "$rc" = 0 ]; then printf '%s\t%s\t%s\t%s\n' "$n" "$via" "$url" "$(printf '%s' "$out" | awk -F'\t' '{ printf "%s\t%d\t%d\t%s\tok", $1, $2*1000, $3*1000, $4 }')"
  else printf '%s\t%s\t%s\t000\t0\t0\t\tcurl-exit-%s\n' "$n" "$via" "$url" "$rc"; fi
}
_b_probes() { # --noproxy bypasses an explicit proxy, but never bypasses TUN.
  local d i n native=direct; [ "${NETWORK_MODE:-system}" != tun ] || native=tun
  d=$(mktemp -d); printf 'probe\tvia\turl\thttp\tconnect_ms\ttotal_ms\tremote_ip\tnote\n'
  if [ -n "${ENANA_SKIP_PROBE:-}" ]; then printf 'skipped\t-\t-\t000\t0\t0\t\tENANA_SKIP_PROBE\n'; rm -rf "$d"; return 0; fi        # 离线 / 测试: 不联网
  if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
    _b_probe google_204 proxy http://www.gstatic.com/generate_204 -x "http://127.0.0.1:$PORT" > "$d/1" &
    _b_probe google_page proxy https://www.google.com/ -x "http://127.0.0.1:$PORT" > "$d/2" &
    _b_probe github proxy https://github.com/ -x "http://127.0.0.1:$PORT" > "$d/3" &
    _b_probe baidu proxy https://www.baidu.com/ -x "http://127.0.0.1:$PORT" > "$d/4" &
  fi
  _b_probe google_204 "$native" http://www.gstatic.com/generate_204 --noproxy '*' > "$d/5" &
  _b_probe google_page "$native" https://www.google.com/ --noproxy '*' > "$d/6" &
  _b_probe baidu "$native" https://www.baidu.com/ --noproxy '*' > "$d/7" &
  wait
  for i in 1 2 3 4 5 6 7; do [ -f "$d/$i" ] && cat "$d/$i"; done
  local system_dns
  if [ "${ENANA_PLATFORM:-darwin}" = windows ]; then system_dns=$(win_bridge dns-system www.google.com 2>/dev/null)
  else system_dns=$(dscacheutil -q host -a name www.google.com 2>/dev/null | awk '/^(ip_address|ipv6_address):/ {print $2}' | head -4 | paste -sd' ' -); fi
  printf 'dns_system\tsystem\twww.google.com\t-\t-\t-\t%s\t\n' "$system_dns"
  n=$(clash GET "/dns/query?name=www.google.com&type=A" 2>/dev/null | perl -MJSON::PP -e 'local $/; my $j = eval { decode_json(<STDIN>) } or exit 0; print join(" ", map { $_->{data} // "" } @{ $j->{Answer} || [] })')
  printf 'dns_core\tcore\twww.google.com\t-\t-\t-\t%s\t%s\n' "$n" "$([ -n "$n" ] || echo no-answer)"
  rm -rf "$d"
}
_b_live() { # 此刻核心里还开着的连接 (最多 60 条, 按下载量): 含命中的规则 (rule) —— 能直接看出「为什么走了这个出口」
  printf 'start\tnet\thost\tport\tapp\tchain\trule\tup\tdown\n'
  clash GET /connections 2>/dev/null | perl -MJSON::PP -e '
    local $/; my $j = eval { decode_json(<STDIN>) } or exit 0; my @c = sort { ($b->{download} // 0) <=> ($a->{download} // 0) } @{ $j->{connections} || [] }; @c = @c[0 .. 59] if @c > 60;
    for my $c (@c) { my $m = $c->{metadata} || {}; my $pp = $m->{processPath} // ""; $pp =~ s{\\}{/}g; my $app = $pp =~ m{([^/]+)\.app/} ? $1 : ($pp =~ m{([^/]+)$} ? $1 : "");
      my $r = join(" ", grep { length } ($c->{rule} // "", $c->{rulePayload} // ""));
      print join("\t", ($c->{start} // ""), ($m->{network} // ""), ($m->{host} || $m->{destinationIP} || ""), ($m->{destinationPort} // ""), $app, join(">", reverse @{ $c->{chains} || [] }), $r, ($c->{upload} // 0), ($c->{download} // 0)), "\n" }'
}

_b_days() { # <小时数|all> -> 要读取的日期 (旧→新)
  local h=$1 first
  if [ "$h" = all ]; then logs_days | sort; return; fi
  first=$(os_date_minus_hours "$h"); first=${first%% *}
  logs_days | sort | awk -v f="$first" '$0 >= f'
}
_b_ops() { # <起始时间|空> <日期…>
  local since=$1 d; shift
  printf 'ts\twho\taction\tdetail\tresult\n'
  for d in "$@"; do _logs_stream ops "$d"; done | LC_ALL=C awk -v s="$since" 'BEGIN { FS = "\t" } { if (s == "" || substr($0, 1, 19) >= s) print }' | _b_mask_user
}
_b_access() { # <起始时间|空> <日期…>
  local since=$1; shift
  _logs_access_input "$@" | LC_ALL=C awk -f "$LIB/access.awk" -v mode=tsv -v q= -v lim=0 -v off=0 -v since="$since" -v mask=1
}
_b_proxy() { # <起始时间|空> <日期…>
  local since=$1 d; shift
  for d in "$@"; do _logs_stream proxy "$d"; done | sed $'s/\033\\[[0-9;]*m//g' | LC_ALL=C awk -v s="$since" '{ ch = substr($0, 1, 1); if ((ch == "+" || ch == "-") && $2 ~ /^[0-9][0-9][0-9][0-9]-/) keep = (s == "" || ($2 " " $3) >= s); if (keep) print }' | _b_mask_user
}

# logs_bundle <小时数|all> <分区 逗号分隔: ops access proxy snapshot>  -> 打印诊断导出文件 (UTF-8 文本)
logs_bundle() {
  local hours=${1:-24} secs=${2:-ops,access,proxy,snapshot} since='' days dlist BT declared=meta
  case $hours in all) ;; ''|*[!0-9]*) hours=24 ;; esac
  [ "$hours" = all ] || { [ "$hours" -lt 1 ] && hours=1; [ "$hours" -gt $LOG_HOURS_MAX ] && hours=$LOG_HOURS_MAX; since=$(os_date_minus_hours "$hours"); }
  days=$(_b_days "$hours"); dlist=$(printf '%s' "$days" | paste -sd, -)
  BT=$(mktemp -d)
  printf '#ENANA-DIAGNOSTICS format=%s\n' "$BUNDLE_FORMAT"
  printf '#generated=%s tz=%s app=enana version=%s\n' "$(date '+%F %T')" "$(date +%z)" "$VERSION"
  printf '#range since="%s" hours=%s days=%s\n' "${since:-beginning}" "$hours" "${dlist:-none}"
  # macOS bash 3.2 misparses unparenthesized case patterns inside quoted $().
  case ",$secs," in *,snapshot,*) declared="$declared,env,config,policy,servers,apps,probes,live" ;; esac
  case ",$secs," in *,ops,*) declared="$declared,ops" ;; esac
  case ",$secs," in *,access,*) declared="$declared,access" ;; esac
  case ",$secs," in *,proxy,*) declared="$declared,proxy" ;; esac
  printf '#sections=%s\n' "$declared"
  printf '%s\n' '#about=这是 enana 的诊断导出文件, 用来排查「网站打不开 / 走错出口 / 应用没识别」之类的问题。每个 "@@SECTION 名称 format=… rows=N" 开始一个分区, 到下一个 "@@SECTION" 或 "@@END" 结束; 以 "#" 开头的行是说明; format=kv 是 键=值, tsv 的第一行是列名 (制表符分隔), raw 是原始日志行。'
  printf '%s\n' '#privacy=不含任何密码 / 令牌 / 服务器凭据; 服务器地址和系统用户名已打码; 但包含访问过的域名和应用名, 请只发给你信任的人。'
  printf '%s\n' '#route-reasons=出口名 direct-mode(代理总开关关闭) direct-lan(本机/局域网) direct-site(你把该网站设为直连) direct-app(你把该应用设为直连/关) direct-cn(国内规则) direct(策略选了直连) 都是直连; 其它名字是代理服务器节点。'
  _b_sec meta kv _b_meta
  case ",$secs," in *,snapshot,*)
    _b_sec env kv _b_env
    _b_sec config text _b_config
    _b_sec policy text _b_policy
    _b_sec servers tsv _b_servers
    _b_sec apps tsv _b_apps
    _b_sec probes tsv _b_probes
    _b_sec live tsv _b_live ;; esac
  # shellcheck disable=SC2086
  case ",$secs," in *,ops,*) _b_sec ops tsv _b_ops "$since" $days ;; esac
  case ",$secs," in *,access,*) _b_sec access tsv _b_access "$since" $days ;; esac
  case ",$secs," in *,proxy,*) _b_sec proxy raw _b_proxy "$since" $days ;; esac
  printf '@@END\n'
  rm -rf "$BT"
}
