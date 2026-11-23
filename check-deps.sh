#!/usr/bin/bash
set -euo pipefail

# 检查 agy-issue-loop.sh 所需的全部命令，并一律使用绝对路径调用

# 补充常见用户目录与 linuxbrew 目录到搜索路径
SEARCH_PATH="${PATH}:/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin"

# 需要检查的必需命令清单
REQUIRED_CMDS=(
  bash
  gh
  jq
  agy
  git
  grep
  mkdir
  touch
  date
  sleep
  tee
  cat
  head
  cp
  find
  flock
  timeout
  tail
)

# 可选命令清单（如独立 PR 评审/E2E/tmux 看板脚本使用）
OPTIONAL_CMDS=(
  codex
  tmux
)

declare -A CMD_PATHS=()
missing_count=0

resolve_cmd() {
  local cmd="$1"
  local resolved=""
  resolved="$(PATH="$SEARCH_PATH" type -P "$cmd" 2>/dev/null || true)"
  if [[ -n "$resolved" && -x "$resolved" ]]; then
    printf '%s' "$resolved"
    return 0
  fi
  return 1
}

get_version() {
  local cmd="$1"
  local bin="$2"
  local out=""

  case "$cmd" in
    agy)
      # agy 无 --version 时回退校验 --help 可执行
      if out="$("$bin" --version 2>&1)"; then
        printf '%s' "${out%%$'\n'*}"
      elif "$bin" --help >/dev/null 2>&1; then
        printf '%s' "(executable, --help ok)"
      else
        return 1
      fi
      ;;
    *)
      if out="$("$bin" --version 2>&1)"; then
        printf '%s' "${out%%$'\n'*}"
      else
        return 1
      fi
      ;;
  esac
}

printf '=== 检查所需命令（全路径调用） ===\n'

for cmd in "${REQUIRED_CMDS[@]}"; do
  if bin_path="$(resolve_cmd "$cmd")"; then
    CMD_PATHS["$cmd"]="$bin_path"
    if ver="$(get_version "$cmd" "$bin_path")"; then
      printf '[OK]      %-8s -> %-32s | %s\n' "$cmd" "$bin_path" "$ver"
    else
      printf '[WARN]    %-8s -> %-32s | 无法获取版本\n' "$cmd" "$bin_path"
    fi
  else
    printf '[MISSING] %-8s -> 未找到可执行文件\n' "$cmd"
    missing_count=$((missing_count + 1))
  fi
done

for cmd in "${OPTIONAL_CMDS[@]}"; do
  if bin_path="$(resolve_cmd "$cmd")"; then
    CMD_PATHS["$cmd"]="$bin_path"
    if ver="$(get_version "$cmd" "$bin_path")"; then
      printf '[OPT-OK]  %-8s -> %-32s | %s\n' "$cmd" "$bin_path" "$ver"
    else
      printf '[OPT-WRN] %-8s -> %-32s | 无法获取版本\n' "$cmd" "$bin_path"
    fi
  else
    printf '[OPT-MIS] %-8s -> 未找到（仅 codex-review-loop.sh 需要）\n' "$cmd"
  fi
done

# 额外检查 GitHub CLI 登录状态（全路径调用 gh）
printf '\n=== 检查运行前置状态 ===\n'
auth_failed=0
if [[ -n "${CMD_PATHS[gh]:-}" ]]; then
  if "${CMD_PATHS[gh]}" auth status >/dev/null 2>&1; then
    printf '[OK]      %s auth status 已登录\n' "${CMD_PATHS[gh]}"
  else
    printf '[WARN]    %s auth status 未登录或无法验证（运行 %s auth login）\n' "${CMD_PATHS[gh]}" "${CMD_PATHS[gh]}"
    auth_failed=1
  fi
fi

printf '\n=== 检查结果汇总 ===\n'
if (( missing_count > 0 )); then
  printf '失败：缺少 %d 个必需命令。\n' "$missing_count"
  exit 1
fi

if (( auth_failed > 0 )); then
  printf '命令全部就绪，但 gh 登录状态未通过（如在离线/沙箱环境下可忽略）。\n'
else
  printf '全部 %d 个必需命令及前置状态检查通过。\n' "${#REQUIRED_CMDS[@]}"
fi
