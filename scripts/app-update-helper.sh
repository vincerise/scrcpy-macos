#!/bin/bash
# ScrcpyMac 自更新助手。
#
# App 已经在自己的进程里完成了 bundle 的原子交换，本脚本只做收尾：
#   等旧进程退出 → 重新打开目标 → 等新版本确认 → 清理旧包，失败则回滚。
#
# 所有路径都通过参数传入，脚本里不拼任何外部字符串。
# 用法：app-update-helper.sh <target> <displaced> <old-pid> <expected-version> \
#                            <ack-file> <result-file> <log-file>
set -u

TARGET="${1:-}"
DISPLACED="${2:-}"
OLD_PID="${3:-0}"
EXPECTED_VERSION="${4:-}"
ACK_FILE="${5:-}"
RESULT_FILE="${6:-}"
LOG_FILE="${7:-}"

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export LC_ALL=C
umask 077

log() {
  if [[ -n "$LOG_FILE" ]]; then
    printf '%s %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE" 2>/dev/null || true
  fi
}

write_result() {
  if [[ -n "$RESULT_FILE" ]]; then
    printf '%s\n' "$*" >"$RESULT_FILE" 2>/dev/null || true
  fi
}

rollback() {
  local reason="$1"
  log "回滚：$reason"
  local failed="$TARGET.failed.$$"
  /bin/rm -rf "$failed"
  if [[ -d "$TARGET" ]]; then
    /bin/mv "$TARGET" "$failed" 2>/dev/null || true
  fi
  if /bin/mv "$DISPLACED" "$TARGET" 2>/dev/null; then
    /bin/rm -rf "$failed"
    write_result "更新没有完成：${reason}。已恢复原来的版本。详见 app-update/update.log。"
    /usr/bin/open -n "$TARGET" >/dev/null 2>&1 || true
  else
    write_result "更新没有完成，且自动恢复失败。原版本在 ${DISPLACED}，请手动移回。"
  fi
  exit 1
}

[[ -n "$TARGET" && -n "$DISPLACED" && -n "$EXPECTED_VERSION" && -n "$ACK_FILE" ]] || {
  log "参数不完整"
  exit 1
}

log "开始：target=$TARGET displaced=$DISPLACED old-pid=$OLD_PID expected=$EXPECTED_VERSION"

# 目标路径必须是完整的 App。正常情况下交换已经完成；如果交换留下了一个
# 不完整的目录，用 displaced 里的旧版本顶回去。
if [[ ! -d "$TARGET" ]]; then
  if [[ -d "$DISPLACED" ]]; then
    log "目标路径不存在，放回旧版本"
    /bin/mv "$DISPLACED" "$TARGET" 2>/dev/null || true
    write_result "更新没有完成：目标路径上的 App 不见了，已恢复原来的版本。"
    /usr/bin/open -n "$TARGET" >/dev/null 2>&1 || true
  fi
  exit 1
fi

EXECUTABLE="$TARGET/Contents/MacOS/ScrcpyMac"

running_target() {
  # 锚定整条命令行：只认可执行文件本身就是目标的进程。不锚定的话，
  # 任何参数里恰好带着这个路径的进程（启动阶段的 xpcproxy 等）都会被算进来。
  /usr/bin/pgrep -f "^${EXECUTABLE}$" >/dev/null 2>&1
}

target_pids() {
  /usr/bin/pgrep -f "^${EXECUTABLE}$" | /usr/bin/tr '\n' ' '
}

# 等旧进程退出。用启动时间而不是 kill -0 判断：pid 会在退出后被系统复用，
# 只看「这个号还有没有进程」会把别人当成我们的旧进程，于是白等到超时。
OLD_START="$(/bin/ps -p "$OLD_PID" -o lstart= 2>/dev/null | /usr/bin/sed 's/^ *//;s/ *$//')"
if [[ -n "$OLD_START" ]]; then
  for _ in $(/usr/bin/seq 1 150); do
    NOW_START="$(/bin/ps -p "$OLD_PID" -o lstart= 2>/dev/null | /usr/bin/sed 's/^ *//;s/ *$//')"
    if [[ -z "$NOW_START" || "$NOW_START" != "$OLD_START" ]]; then
      break
    fi
    /bin/sleep 0.2
  done
  NOW_START="$(/bin/ps -p "$OLD_PID" -o lstart= 2>/dev/null | /usr/bin/sed 's/^ *//;s/ *$//')"
  if [[ -n "$NOW_START" && "$NOW_START" == "$OLD_START" ]]; then
    rollback "等待旧进程退出超时"
  fi
fi
log "旧进程已退出"

# 用户可能已经手动重新打开；有目标进程就不再 open，避免开成两个实例。
LAUNCH_TRIES=0
launch_target() {
  LAUNCH_TRIES=$((LAUNCH_TRIES + 1))
  log "打开 $TARGET（第 ${LAUNCH_TRIES} 次）"
  /usr/bin/open -n "$TARGET" >/dev/null 2>&1 || log "open 返回失败"
}

# 旧进程刚退出时 LaunchServices 可能还没把旧实例摘干净，这时立刻 open
# 会把新实例当成重复实例，启动后马上退出。等一拍再拉。
/bin/sleep 1
if ! running_target; then
  launch_target
fi

# 等新版本给出明确信号。ack 是首选；没有 ack 的旧版本（这套机制之前发布
# 的 App）要求进程稳定存活 5 秒——只活几百毫秒不算成功，那正是「换完包但
# 新版本起不来」的样子，不能因此删掉旧包。进程中途消失则重试拉起，最多 3 次。
ACK_OK=0
STABLE=0
MISSING=0
for _ in $(/usr/bin/seq 1 150); do
  if [[ -f "$ACK_FILE" ]]; then
    VALUE="$(/bin/cat "$ACK_FILE" 2>/dev/null || true)"
    if [[ "$VALUE" == "$EXPECTED_VERSION" ]]; then
      ACK_OK=1
      log "收到新版本确认：$VALUE"
      break
    fi
  fi
  if running_target; then
    if [[ "$STABLE" -eq 0 ]]; then
      log "看到目标进程：$(target_pids)"
    fi
    STABLE=$((STABLE + 1))
    MISSING=0
    if [[ "$STABLE" -ge 25 ]]; then
      ACK_OK=1
      log "目标进程已稳定运行 5 秒（无 ack），按成功处理：$(target_pids)"
      break
    fi
  else
    if [[ "$STABLE" -gt 0 ]]; then
      log "目标进程消失（之前连续看到 ${STABLE} 次）"
    fi
    STABLE=0
    MISSING=$((MISSING + 1))
    if [[ "$MISSING" -ge 15 && "$LAUNCH_TRIES" -lt 3 ]]; then
      log "目标进程不在，重试打开"
      launch_target
      MISSING=0
    fi
  fi
  /bin/sleep 0.2
done

# 循环和 ack 写入可能擦肩而过。回滚会把正在运行的新版本挪走，
# 代价很高，所以最后再确认一次。
if [[ "$ACK_OK" != "1" && -f "$ACK_FILE" ]]; then
  VALUE="$(/bin/cat "$ACK_FILE" 2>/dev/null || true)"
  if [[ "$VALUE" == "$EXPECTED_VERSION" ]]; then
    ACK_OK=1
    log "循环结束后才收到确认：$VALUE"
  fi
fi

if [[ "$ACK_OK" == "1" ]]; then
  /bin/rm -rf "$DISPLACED"
  /bin/rm -f "$ACK_FILE"
  log "更新完成，已清理旧版本"
  exit 0
fi

rollback "新版本没有确认启动"
