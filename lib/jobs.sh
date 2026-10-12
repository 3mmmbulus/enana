# 后台任务与进度: 仪表盘用 GET /api/job?id= 轮询 $H/jobs/<id>.json 来画进度条。
# 任务由主脚本的 `_job <name> <id>` 子命令在后台运行 (见 install.sh), 这里只负责状态文件。

# 排队序号: 改配置的任务按「请求到达的顺序」依次执行 (否则连续点两下时, 后启动的进程可能先拿到锁, 最终状态与用户的操作顺序相反)
job_ticket() { # 打印下一个序号 (全局单调递增; 用目录锁保护计数文件)
  local f="$H/.ticket" n=0 i=0
  while ! mkdir "$H/.ticket.lock" 2>/dev/null; do i=$((i+1)); [ "$i" -gt 100 ] && break; sleep 0.05; done
  [ -f "$f" ] && IFS= read -r n < "$f"; n=$((${n:-0}+1)); printf '%s\n' "$n" > "$f"
  rmdir "$H/.ticket.lock" 2>/dev/null || true
  printf '%s\n' "$n"
}

JOB_KEEP=200        # 最多保留多少个已结束的任务的文件 (仪表盘只看最近的); 进行中的任务不计入, 也从不删除
job_prune() { # 删掉已结束的任务的文件: 超过一天的, 以及最近 JOB_KEEP 个之外的; 进行中的不动; .cred / .body (密码、粘贴的数据) 超过一天就删, 不管记录还在不在
  local d="$H/jobs" f id k=0 busy old stale
  [ -d "$d" ] || return 0
  busy=$(grep -l '"state":"running"' "$d"/*.json 2>/dev/null || true)       # 顶层状态是 running (步骤的状态是 run / done, 不会误中)
  old=$(find "$d" -maxdepth 1 -name '*.json' -mtime +1 2>/dev/null || true)  # 超过一天的记录 (一次 find, 不逐个查)
  while IFS= read -r f; do
    case $busy in *"$d/$f"*) continue ;; esac
    k=$((k + 1)); stale=0; case $old in *"$d/$f"*) stale=1 ;; esac
    if [ "$k" -gt "${JOB_KEEP:-200}" ] || [ "$stale" = 1 ]; then id=${f%.json}; rm -f "$d/$id".*; fi
  done < <(ls -1t "$d" 2>/dev/null | grep '\.json$')
  find "$d" -maxdepth 1 -type f \( -name '*.cred' -o -name '*.body' \) -mtime +1 2>/dev/null | while IFS= read -r f; do
    id=${f##*/}; id=${id%.*}
    case $busy in *"$d/$id.json"*) continue ;; esac
    rm -f "$f"
  done
  find "$d" -maxdepth 1 -type f ! -name '*.json' -mtime +1 2>/dev/null | while IFS= read -r f; do
    id=${f##*/}; id=${id%%.*}
    [ -f "$d/$id.json" ] || rm -f "$f"
  done
  return 0
}

job_new() { # job_new 名称 "步骤1|步骤2|…"  -> 打印 id
  local name=$1 steps=$2 id
  mkdir -p "$H/jobs"
  job_prune
  id="$name-$(now)-$RANDOM"
  printf '%s' "$steps" > "$H/jobs/$id.steps"
  case $name in net-info|speedtest|self-update|core-upgrade|maintain|dns-bench|sync-push|sync-login|vps-probe|vps-provision|vps-redetect|vps-verify|sysproxy) ;; *) job_ticket > "$H/jobs/$id.ticket" ;; esac   # 长时间的只读/独立任务不排队
  JOB_NAME=$name; job_write "$id" "$name" running 0 0 "准备中" '{}'
  printf '%s\n' "$id"
}

job_write() { # id name state(running|done|error) 当前步骤序号 pct msg result_json
  local id=$1 name=$2 state=$3 idx=$4 pct=$5 msg=$6 res=${7:-'{}'} f="$H/jobs/$1.json" label i=0 st arr=''
  local steps; steps=$(cat "$H/jobs/$id.steps" 2>/dev/null || true)
  local oldifs=$IFS; IFS='|'
  for label in $steps; do
    if [ "$state" = done ]; then st=done
    elif [ "$i" -lt "$idx" ]; then st=done
    elif [ "$i" -eq "$idx" ]; then [ "$state" = error ] && st=error || st=run
    else st=todo; fi
    arr="$arr${arr:+,}{\"label\":\"$(jesc "$(_t "$label")")\",\"state\":\"$st\"}"
    i=$((i+1))
  done
  IFS=$oldifs
  msg=$(jesc "$(_t "$msg")")
  printf '{"ok":true,"id":"%s","name":"%s","state":"%s","pct":%s,"msg":"%s","steps":[%s],"result":%s}\n' \
    "$id" "$name" "$state" "$pct" "$msg" "$arr" "$res" > "$f.tmp" && mv "$f.tmp" "$f"
}

# 在任务进程里使用 (环境变量 JOB_ID/JOB_NAME 由 _job 设置); 非任务模式 (终端安装、enana update) 下把进度文字打印到终端
job_step() {
  if [ -z "${JOB_ID:-}" ]; then [ -t 1 ] && printf '    %s (%s%%)\n' "$(_t "$3")" "$2"; return 0; fi
  job_write "$JOB_ID" "$JOB_NAME" running "$1" "$2" "$3" '{}'
}
job_ok()   { [ -n "${JOB_ID:-}" ] || return 0; local r=${2:-}; [ -n "$r" ] || r='{}'; job_write "$JOB_ID" "$JOB_NAME" done 99 100 "${1:-完成}" "$r"; }
job_fail() { [ -n "${JOB_ID:-}" ] || return 0; job_write "$JOB_ID" "$JOB_NAME" error "${2:-0}" 100 "$1" '{}'; }

# 记录还写着「进行中」, 但干活的进程已经没了 (被结束、崩溃, 或 Windows 上整棵进程树被清掉: 这时任何 trap 都来不及写结果), 或者 JOB_STALL_MIN 分钟没有任何进度
# → 改成失败 (E_JOB_LOST)。否则进度条和「正在应用配置」状态会一直转下去, 界面永远等不到结束。进程编号由 job_dispatch 写进 jobs/<id>.pid
# ponytail: 15 分钟的静默上限对现有任务都够用 (最长的是 UAC 等待 + 服务重启); 真有更慢的任务时再按任务名放宽
JOB_STALL_MIN=15
job_reap() { # job_reap <id>
  local f="$H/jobs/$1.json" pid lost='' name idx
  grep -q '"state":"running"' "$f" 2>/dev/null || return 0
  pid=$(cat "$H/jobs/$1.pid" 2>/dev/null)
  case $pid in
    ''|*[!0-9]*) [ -n "$(find "$f" -mmin +2 2>/dev/null)" ] && lost=1 ;;     # 进程还没写下编号 (或者根本没有启动成功): 2 分钟后仍然没有
    *) kill -0 "$pid" 2>/dev/null || lost=1 ;;
  esac
  [ -n "$lost" ] || [ -z "$(find "$f" -mmin +$JOB_STALL_MIN 2>/dev/null)" ] || lost=1
  [ -n "$lost" ] || return 0
  # 先判断进程、再读记录: 正常结束的进程是先写完「完成」再退出的, 那时记录已经不是「进行中」了
  grep -q '"state":"running"' "$f" 2>/dev/null || return 0
  name=$(sed -n 's/.*"name":"\([^"]*\)".*/\1/p' "$f" | head -n 1)
  idx=$(grep -o '"state":"[a-z]*"' "$f" | awk 'NR > 1 && /"run"/ { print NR - 2; exit }')      # 停在哪一步 (第一个「进行中」的步骤)
  job_write "$1" "$name" error "${idx:-0}" 100 "后台任务意外中止, 没有完成, 请重试" '{"code":"E_JOB_LOST"}'
}

job_get() { # id -> JSON (找不到时返回错误 JSON)
  local id=$1
  case $id in *[!A-Za-z0-9_-]*|'') printf '{"ok":false,"code":"E_INVALID","error":"%s"}\n' "$(_t "任务编号无效")"; return ;; esac
  job_reap "$id"
  if [ -f "$H/jobs/$id.json" ]; then cat "$H/jobs/$id.json"; else printf '{"ok":false,"code":"E_NOT_FOUND","error":"%s"}\n' "$(_t "找不到该任务")"; fi
}

job_launch() { # job_launch 名称 id [参数…]  在后台启动 `<主脚本> _job 名称 id 参数…`
  local name=$1 id=$2; shift 2
  if [ ! -x "$H/enana" ]; then
    job_write "$id" "$name" error 0 100 "后台任务启动失败: enana 没有执行权限, 请重新安装" '{"code":"E_JOB_LAUNCH"}'
    rm -f "$H/jobs/$id.cred" "$H/jobs/$id.body"
    return 1
  fi
  ( ENANA_LANG="${I18N_LANG:-${LANG_UI:-}}" OP_WHO="${OP_WHO:-}" APPS_BG_JOB="${APPS_BG_JOB:-}" nohup "$H/enana" _job "$name" "$id" "$@" >>"$H/api.log" 2>&1 & ) >/dev/null 2>&1
}
job_spawn() { # job_spawn 名称 "步骤…" [参数…]  创建并启动, 打印 id
  local name=$1 steps=$2 id; shift 2
  id=$(job_new "$name" "$steps")
  job_launch "$name" "$id" "$@"
  printf '%s\n' "$id"
}
