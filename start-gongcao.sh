#!/usr/bin/bash
set -euo pipefail

# 一键启动 / 管理 gongcao 全链路 tmux 流水线（5 窗口：dev / review / e2e / final-gate / monitor+cleanup）
# 用法:
#   ./start-gongcao.sh <owner/repo> [start|attach|status|stop]

SCRIPT_DIR="$(cd -- "$([[ "${BASH_SOURCE[0]}" == */* ]] && printf '%s' "${BASH_SOURCE[0]%/*}" || printf '.')" && pwd)"

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
MKDIR_BIN="$(resolve_bin mkdir)"
TOUCH_BIN="$(resolve_bin touch)"
TAIL_BIN="$(resolve_bin tail)"

REPO_ARG="${1:-${REPO:-}}"
ACTION="${2:-start}"

if [[ -z "$REPO_ARG" || "$REPO_ARG" == "-h" || "$REPO_ARG" == "--help" ]]; then
  cat >&2 <<'EOF'
用法:
  start-gongcao.sh <owner/repo> [start|attach|status|stop]

示例:
  ./start-gongcao.sh simonjiao/airdb          # 启动 5 窗口 tmux 流水线（若已运行则直接提示）
  ./start-gongcao.sh simonjiao/airdb attach   # 进入 tmux 面板查看
  ./start-gongcao.sh simonjiao/airdb status   # 查看会话与窗口状态
  ./start-gongcao.sh simonjiao/airdb stop     # 停止整个 tmux 会话

可选透传环境变量:
  GONGCAO_HOME       默认 ~/.gongcao
  CODEX_REVIEW_HOME  评审/E2E/终审专用 Codex 目录，默认 ~/.gongcao/codex-review
  DRY_RUN            默认 0（设为 1 可全链路演练）
  POLL_INTERVAL      默认 60
  BASE_BRANCH        可选基准分支
  DEV_ENGINE         开发执行器 agy 或 codex，默认 agy

首次启动前，请分别初始化开发与评审专用目录（不共用个人默认 ~/.codex）:
  ./agy-issue-loop.sh login      # 使用 agy 开发时
  ./codex-issue-loop.sh login    # 使用 Codex 开发时（~/.gongcao/codex）
  ./codex-review-loop.sh login   # 评审/E2E/终审共用（~/.gongcao/codex-review）

使用 Codex 处理 Issue:
  DEV_ENGINE=codex ./start-gongcao.sh simonjiao/airdb
EOF
  exit 2
fi

GONGCAO_HOME="${GONGCAO_HOME:-${HOME}/.gongcao}"
DRY_RUN="${DRY_RUN:-0}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
BASE_BRANCH="${BASE_BRANCH:-}"

REPO_SLUG="${REPO_ARG//\//__}"
REPO_SLUG="${REPO_SLUG//[^a-zA-Z0-9._-]/_}"
SESSION_NAME="gongcao-${REPO_SLUG}"
STATE_ROOT="${GONGCAO_HOME}/state/${REPO_SLUG}"
ACTIVITY_LOG="${STATE_ROOT}/activity.log"

case "$ACTION" in
  status)
    if "$TMUX_BIN" has-session -t "$SESSION_NAME" 2>/dev/null; then
      printf 'tmux 会话运行中: %s\n' "$SESSION_NAME"
      "$TMUX_BIN" list-windows -t "$SESSION_NAME" -F '  [#{window_index}] #{window_name} (#{window_panes} pane) - #{pane_current_command}'
    else
      printf 'tmux 会话未运行: %s\n' "$SESSION_NAME"
      exit 1
    fi
    ;;

  stop)
    if "$TMUX_BIN" has-session -t "$SESSION_NAME" 2>/dev/null; then
      "$TMUX_BIN" kill-session -t "$SESSION_NAME"
      printf '已停止 tmux 会话: %s\n' "$SESSION_NAME"
    else
      printf 'tmux 会话本来未运行: %s\n' "$SESSION_NAME"
    fi
    ;;

  attach)
    if ! "$TMUX_BIN" has-session -t "$SESSION_NAME" 2>/dev/null; then
      printf '错误：tmux 会话 %s 未运行，请先执行 start\n' "$SESSION_NAME" >&2
      exit 1
    fi
    exec "$TMUX_BIN" attach-session -t "$SESSION_NAME"
    ;;

  start)
    dev_engine="${DEV_ENGINE:-agy}"
    case "$dev_engine" in
      agy|codex) ;;
      *)
        printf '错误：DEV_ENGINE=%q 无效，支持 agy 和 codex。\n' "$dev_engine" >&2
        exit 2
        ;;
    esac

    if "$TMUX_BIN" has-session -t "$SESSION_NAME" 2>/dev/null; then
      printf 'tmux 会话 %s 已在运行！使用下面命令进入查看：\n' "$SESSION_NAME"
      printf '  %s attach-session -t %s\n' "$TMUX_BIN" "$SESSION_NAME"
      exit 0
    fi

    if [[ ! -d "${GONGCAO_HOME}/${dev_engine}" ]]; then
      printf '错误：请先运行 %q login 初始化 %s/%s。\n' \
        "${SCRIPT_DIR}/${dev_engine}-issue-loop.sh" "$GONGCAO_HOME" "$dev_engine" >&2
      exit 1
    fi

    codex_review_home="${CODEX_REVIEW_HOME:-${GONGCAO_HOME}/codex-review}"
    if [[ ! -d "$codex_review_home" ]]; then
      printf '错误：请先运行 %q login 初始化评审/E2E/终审专用 Codex 目录 %s（避免使用个人默认 ~/.codex）。\n' \
        "${SCRIPT_DIR}/codex-review-loop.sh" "$codex_review_home" >&2
      exit 1
    fi

    "$MKDIR_BIN" -p "$STATE_ROOT"
    "$TOUCH_BIN" "$ACTIVITY_LOG"

    # 拼装共享环境前缀
    env_prefix="REPO=$(printf '%q' "$REPO_ARG") GONGCAO_HOME=$(printf '%q' "$GONGCAO_HOME") DRY_RUN=$(printf '%q' "$DRY_RUN") POLL_INTERVAL=$(printf '%q' "$POLL_INTERVAL")"
    [[ -n "$BASE_BRANCH" ]] && env_prefix+=" BASE_BRANCH=$(printf '%q' "$BASE_BRANCH")"
    [[ -n "${CODEX_REVIEW_HOME:-}" ]] && env_prefix+=" CODEX_REVIEW_HOME=$(printf '%q' "$CODEX_REVIEW_HOME")"

    # 窗口 0：dev
    dev_env_prefix="$env_prefix"
    if [[ "$dev_engine" == "codex" ]]; then
      for name in CODEX_MODEL CODEX_REASONING_EFFORT CODEX_DEV_TIMEOUT; do
        if [[ -n "${!name:-}" ]]; then
          dev_env_prefix+=" ${name}=$(printf '%q' "${!name}")"
        fi
      done
    fi
    "$TMUX_BIN" new-session -d -s "$SESSION_NAME" -n "dev" \
      "${dev_env_prefix} $(printf '%q' "${SCRIPT_DIR}/${dev_engine}-issue-loop.sh")"
    # 防止任何窗口进程意外退出时窗口直接消失，保留最后报错现场
    "$TMUX_BIN" set-option -t "$SESSION_NAME" remain-on-exit on

    # 窗口 1：review (codex-review-loop.sh)
    "$TMUX_BIN" new-window -t "$SESSION_NAME:" -n "review" \
      "${env_prefix} $(printf '%q' "${SCRIPT_DIR}/codex-review-loop.sh")"

    # 窗口 2：e2e (codex-e2e-loop.sh)
    "$TMUX_BIN" new-window -t "$SESSION_NAME:" -n "e2e" \
      "${env_prefix} $(printf '%q' "${SCRIPT_DIR}/codex-e2e-loop.sh")"

    # 窗口 3：final-gate (codex-final-gate-loop.sh: 终审对账 + 更新信息 + 自动合并)
    "$TMUX_BIN" new-window -t "$SESSION_NAME:" -n "final-gate" \
      "${env_prefix} $(printf '%q' "${SCRIPT_DIR}/codex-final-gate-loop.sh")"

    # 窗口 4：monitor（上 pane 实时总览 activity.log，下 pane 运行 cleanup-merged.sh）
    "$TMUX_BIN" new-window -t "$SESSION_NAME:" -n "monitor" \
      "$(printf '%q' "$TAIL_BIN") -n 40 -F $(printf '%q' "$ACTIVITY_LOG")"
    "$TMUX_BIN" split-window -v -t "${SESSION_NAME}:monitor" \
      "${env_prefix} $(printf '%q' "${SCRIPT_DIR}/cleanup-merged.sh")"

    "$TMUX_BIN" select-window -t "${SESSION_NAME}:monitor"

    printf '已启动全链路 tmux 会话: %s\n' "$SESSION_NAME"
    printf '  窗口列表 : [0] dev | [1] review | [2] e2e | [3] final-gate | [4] monitor (activity.log + cleanup-merged)\n'
    printf '  进入看板 : %s attach-session -t %s\n' "$TMUX_BIN" "$SESSION_NAME"
    printf '  切换窗口 : Ctrl+b 然后按 0/1/2/3/4（或 w 列表选择）\n'
    printf '  停止全部 : %s %s stop\n' "$0" "$REPO_ARG"
    ;;

  *)
    printf '错误：未知操作 %q（支持 start|attach|status|stop）\n' "$ACTION" >&2
    exit 2
    ;;
esac
