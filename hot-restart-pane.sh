#!/usr/bin/bash
set -euo pipefail

# 安全热重启监控脚本：等待指定 tmux 面板完全进入安全空闲边界后，再执行 respawn-pane -k。
# 用法：hot-restart-pane.sh <tmux-pane-target> [max_wait_sec]

SEARCH_PATH="${PATH}:/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin"
resolve_bin() {
  local resolved=""
  resolved="$(PATH="$SEARCH_PATH" type -P "$1" 2>/dev/null || true)"
  if [[ -z "$resolved" || ! -x "$resolved" ]]; then
    printf '错误：缺少必需命令 %s\n' "$1" >&2
    exit 1
  fi
  printf '%s' "$resolved"
}

TMUX_BIN="$(resolve_bin tmux)"
PS_BIN="$(resolve_bin ps)"
SLEEP_BIN="$(resolve_bin sleep)"
DATE_BIN="$(resolve_bin date)"

TARGET="${1:-}"
MAX_WAIT_SEC="${2:-2700}"
POLL_SEC="${HOT_RESTART_POLL_SEC:-2}"

if [[ -z "$TARGET" || ! "$MAX_WAIT_SEC" =~ ^[0-9]+$ ]] || (( MAX_WAIT_SEC <= 0 )); then
  printf '用法：%s <tmux-pane-target> [max_wait_sec]\n' "$0" >&2
  exit 2
fi

if ! orig_pid="$("$TMUX_BIN" display-message -p -t "$TARGET" '#{pane_pid}' 2>/dev/null)" || [[ -z "$orig_pid" ]]; then
  printf '[%s] 错误：无法访问 tmux 面板 %s（面板不存在或无权访问）\n' "$("$DATE_BIN" '+%F %T')" "$TARGET" >&2
  exit 1
fi

orig_dead="$("$TMUX_BIN" display-message -p -t "$TARGET" '#{pane_dead}' 2>/dev/null || printf '1')"
if [[ "$orig_dead" != "0" ]]; then
  printf '[%s] 错误：目标面板 %s 当前已退出 (dead=%s)\n' "$("$DATE_BIN" '+%F %T')" "$TARGET" "$orig_dead" >&2
  exit 1
fi

# 判定面板当前是否处于安全可重启边界（空闲等待或刚结束本轮任务进入收尾 sleep）
is_pane_safe_to_restart() {
  local pane_pid="$1"
  local child_comms="" line=""

  # 1. 子进程检查：仅允许无子进程或仅有收尾/轮询 sleep
  child_comms="$("$PS_BIN" -o comm= --ppid "$pane_pid" 2>/dev/null || true)"
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    [[ "$line" == "sleep" ]] || return 1
  done <<<"$child_comms"

  # 2. 面板尾部输出检查：避免在配额冷却或超时重试等待期间误重启
  local pane_text=""
  pane_text="$("$TMUX_BIN" capture-pane -t "$TARGET" -p -S -25 2>/dev/null || true)"

  local -a non_empty=()
  while IFS= read -r line; do
    line="${line%$'\r'}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] && non_empty+=("$line")
  done <<<"$pane_text"

  local count="${#non_empty[@]}"
  (( count == 0 )) && return 1

  local last_line="${non_empty[$((count - 1))]}"
  if [[ "$last_line" == *"空闲等待中"* ]]; then
    return 0
  fi

  local start_idx=$(( count > 15 ? count - 15 : 0 ))
  local done_idx=-1
  local i=0
  for (( i = start_idx; i < count; i++ )); do
    if [[ "${non_empty[$i]}" == *"[DONE]"* ]]; then
      done_idx="$i"
    fi
  done

  if (( done_idx >= 0 )); then
    for (( i = done_idx + 1; i < count; i++ )); do
      case "${non_empty[$i]}" in
        *"准备 Issue"*|*"启动 Issue"*|*"续接 Issue"*|*"开始 Codex"*|*"警告："*|*"已切换"*)
          return 1
          ;;
      esac
    done
    return 0
  fi

  return 1
}

printf '[%s] 开始监控面板 %s (orig_pid=%s, max_wait=%ss, poll=%ss)...\n' \
  "$("$DATE_BIN" '+%F %T')" "$TARGET" "$orig_pid" "$MAX_WAIT_SEC" "$POLL_SEC"

start_sec=$SECONDS
while true; do
  cur_pid="$("$TMUX_BIN" display-message -p -t "$TARGET" '#{pane_pid}' 2>/dev/null || true)"
  cur_dead="$("$TMUX_BIN" display-message -p -t "$TARGET" '#{pane_dead}' 2>/dev/null || printf '1')"
  if [[ -z "$cur_pid" || "$cur_dead" != "0" ]]; then
    printf '[%s] 错误：监控期间目标面板 %s 异常退出 (dead=%s)\n' "$("$DATE_BIN" '+%F %T')" "$TARGET" "$cur_dead" >&2
    exit 1
  fi

  if is_pane_safe_to_restart "$cur_pid"; then
    printf '[%s] 检测到 %s 处于安全空闲边界，触发热重启 (old_pid=%s)...\n' \
      "$("$DATE_BIN" '+%F %T')" "$TARGET" "$cur_pid"
    "$TMUX_BIN" respawn-pane -k -t "$TARGET"
    "$SLEEP_BIN" 5

    new_pid="$("$TMUX_BIN" display-message -p -t "$TARGET" '#{pane_pid}' 2>/dev/null || true)"
    new_dead="$("$TMUX_BIN" display-message -p -t "$TARGET" '#{pane_dead}' 2>/dev/null || printf '1')"
    if [[ "$new_dead" != "0" || -z "$new_pid" || "$new_pid" == "$orig_pid" ]]; then
      printf '[%s] 错误：面板 %s 热重启后状态异常 (new_pid=%s, dead=%s)\n' \
        "$("$DATE_BIN" '+%F %T')" "$TARGET" "$new_pid" "$new_dead" >&2
      exit 1
    fi

    printf '[%s] 面板 %s 热重启成功 (old_pid=%s -> new_pid=%s, dead=%s)\n' \
      "$("$DATE_BIN" '+%F %T')" "$TARGET" "$orig_pid" "$new_pid" "$new_dead"
    "$TMUX_BIN" capture-pane -t "$TARGET" -p -S -15
    exit 0
  fi

  elapsed=$((SECONDS - start_sec))
  if (( elapsed >= MAX_WAIT_SEC )); then
    printf '[%s] 超时：等待 %ss 后 %s 仍未空闲，放弃自动重启\n' \
      "$("$DATE_BIN" '+%F %T')" "$MAX_WAIT_SEC" "$TARGET" >&2
    exit 124
  fi

  "$SLEEP_BIN" "$POLL_SEC"
done
