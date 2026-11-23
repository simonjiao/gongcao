#!/usr/bin/bash
set -euo pipefail

# 合并后收尾与本地 worktree 清理工具（不调用 agy/codex，不直接调用 gh）
# 扫描近期已合并（merged）的 PR：
#   1. 若 PR 或关联 Issue 仍带有非 done 的 agy:* 标签，将其切换为 agy:done；
#   2. 在 flock 锁保护下安全清理本地对应的 issue-<N> / review-pr-<P> / e2e-pr-<P> / final-pr-<P> worktree
#      及已合并的本地 agy/issue-<N> 分支（绝不强删未合并分支）。

SCRIPT_DIR="$(cd -- "$([[ "${BASH_SOURCE[0]}" == */* ]] && printf '%s' "${BASH_SOURCE[0]%/*}" || printf '.')" && pwd)"
GH_STATE_BIN="${SCRIPT_DIR}/gh-state.sh"

SEARCH_PATH="${PATH}:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin"
resolve_bin() {
  local resolved=""
  resolved="$(PATH="$SEARCH_PATH" type -P "$1" 2>/dev/null || true)"
  if [[ -z "$resolved" || ! -x "$resolved" ]]; then
    printf '错误：缺少必需命令 %s\n' "$1" >&2
    exit 1
  fi
  printf '%s' "$resolved"
}

JQ_BIN="$(resolve_bin jq)"
GIT_BIN="$(resolve_bin git)"
GREP_BIN="$(resolve_bin grep)"
HEAD_BIN="$(resolve_bin head)"
MKDIR_BIN="$(resolve_bin mkdir)"
TOUCH_BIN="$(resolve_bin touch)"
DATE_BIN="$(resolve_bin date)"
SLEEP_BIN="$(resolve_bin sleep)"
FLOCK_BIN="$(resolve_bin flock)"

# ===== 可调配置 =====
GONGCAO_HOME="${GONGCAO_HOME:-${HOME}/.gongcao}"
REPOS_ROOT="${REPOS_ROOT:-${GONGCAO_HOME}/repos}"
STATE_BASE="${STATE_BASE:-${GONGCAO_HOME}/state}"

REPO="${REPO:-}"
REPO_NAME="${REPO_NAME:-}"
REPO_DIR="${REPO_DIR:-}"
LABEL_PREFIX="${LABEL_PREFIX:-agy:}"
BRANCH_PREFIX="${BRANCH_PREFIX:-agy/issue-}"
PR_LIMIT="${PR_LIMIT:-30}"
POLL_INTERVAL="${POLL_INTERVAL:-300}"
DRY_RUN="${DRY_RUN:-0}"
ONCE=0

for arg in "$@"; do
  case "$arg" in
    --once) ONCE=1 ;;
    -h|--help)
      printf '用法: REPO=owner/repo cleanup-merged.sh [--once]\n' >&2
      exit 0
      ;;
  esac
done

"$MKDIR_BIN" -p "$GONGCAO_HOME" "$REPOS_ROOT" "$STATE_BASE"

if [[ -z "$REPO_DIR" ]]; then
  if [[ -n "$REPO" ]]; then
    _slug="${REPO//\//__}"
    _slug="${_slug//[^a-zA-Z0-9._-]/_}"
    _short="${REPO##*/}"
    _short="${_short//[^a-zA-Z0-9._-]/_}"
    if [[ -e "${REPOS_ROOT}/${_slug}/.git" ]]; then
      REPO_DIR="${REPOS_ROOT}/${_slug}"
    elif [[ -e "${REPOS_ROOT}/${_short}/.git" ]]; then
      REPO_DIR="${REPOS_ROOT}/${_short}"
    else
      REPO_DIR="$(pwd)"
    fi
  elif [[ -n "$REPO_NAME" ]]; then
    REPO_DIR="${REPOS_ROOT}/${REPO_NAME}"
  else
    REPO_DIR="$(pwd)"
  fi
fi

if ! REPO_ROOT="$("$GIT_BIN" -C "$REPO_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  printf '错误：REPO_DIR (%s) 不是一个有效的 Git 仓库。\n' "$REPO_DIR" >&2
  exit 1
fi

if [[ -n "$REPO" ]]; then
  REPO_SLUG="${REPO//\//__}"
else
  REPO_SLUG="${REPO_ROOT##*/}"
fi
REPO_SLUG="${REPO_SLUG//[^a-zA-Z0-9._-]/_}"

STATE_ROOT="${STATE_ROOT:-${STATE_BASE}/${REPO_SLUG}}"
WORKTREE_ROOT="${WORKTREE_ROOT:-${STATE_ROOT}/worktrees}"
REPO_GIT_LOCK="${STATE_ROOT}/repo-git.lock"
ACTIVITY_LOG="${STATE_ROOT}/activity.log"

"$MKDIR_BIN" -p "$STATE_ROOT" "$WORKTREE_ROOT"
"$TOUCH_BIN" "$REPO_GIT_LOCK"

gh_state() {
  GONGCAO_HOME="$GONGCAO_HOME" \
  REPOS_ROOT="$REPOS_ROOT" \
  REPO_DIR="$REPO_ROOT" \
  REPO="$REPO" \
  LABEL_PREFIX="$LABEL_PREFIX" \
  DRY_RUN="$DRY_RUN" \
  "$GH_STATE_BIN" "$@"
}

extract_linked_issue() {
  local pr_body="$1"
  local head_branch="$2"
  local match="" num=""

  match="$("$GREP_BIN" -oiE -m 1 '(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#[0-9]+' <<<"$pr_body" || true)"
  [[ -n "$match" ]] && num="${match##*#}"
  if [[ -z "$num" ]]; then
    match="$("$GREP_BIN" -oE -m 1 'issue-[0-9]+' <<<"$head_branch" || true)"
    [[ -n "$match" ]] && num="${match#issue-}"
  fi
  printf '%s' "$num"
}

remove_worktree_safe() {
  local wt_dir="$1"
  [[ -d "$wt_dir" ]] || return 1
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[DRY_RUN] %s -C %q worktree remove --force %q\n' "$GIT_BIN" "$REPO_ROOT" "$wt_dir" >&2
    return 0
  fi
  (
    "$FLOCK_BIN" -x 9
    "$GIT_BIN" -C "$REPO_ROOT" worktree remove --force "$wt_dir" >&2 || true
    "$GIT_BIN" -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true
  ) 9>"$REPO_GIT_LOCK"
  return 0
}

run_cleanup_pass() {
  local prs_json=""
  if ! prs_json="$(gh_state list-prs merged "" "$PR_LIMIT")" \
    || ! "$JQ_BIN" -e 'type == "array"' >/dev/null 2>&1 <<<"$prs_json"; then
    printf '[%s] 警告：拉取已合并 PR 列表失败\n' "$("$DATE_BIN" '+%F %T')" >&2
    return 1
  fi

  local cleaned_count=0
  local row
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    local pr_num pr_body head_branch issue_num has_agy_non_done
    pr_num="$("$JQ_BIN" -r '.number' <<<"$row")"
    pr_body="$("$JQ_BIN" -r '.body // ""' <<<"$row")"
    head_branch="$("$JQ_BIN" -r '.headRefName // ""' <<<"$row")"
    issue_num="$(extract_linked_issue "$pr_body" "$head_branch")"

    has_agy_non_done="$("$JQ_BIN" -r --arg prefix "$LABEL_PREFIX" --arg done_lbl "${LABEL_PREFIX}done" \
      'if any(.labels[]?.name; startswith($prefix) and . != $done_lbl) then "1" else "0" end' <<<"$row")"

    local wt_issue="" wt_review wt_e2e wt_final wt_final_resolve has_local_wt=0
    wt_review="${WORKTREE_ROOT}/review-pr-${pr_num}"
    wt_e2e="${WORKTREE_ROOT}/e2e-pr-${pr_num}"
    wt_final="${WORKTREE_ROOT}/final-pr-${pr_num}"
    wt_final_resolve="${WORKTREE_ROOT}/final-resolve-pr-${pr_num}"
    [[ -n "$issue_num" ]] && wt_issue="${WORKTREE_ROOT}/issue-${issue_num}"

    if [[ -d "$wt_review" || -d "$wt_e2e" || -d "$wt_final" || -d "$wt_final_resolve" ]] || [[ -n "$wt_issue" && -d "$wt_issue" ]]; then
      has_local_wt=1
    fi

    # 只处理属于本自动化流（带 agy:* 标签或本地存在对应 worktree）的已合并 PR
    if [[ "$has_agy_non_done" != "1" && "$has_local_wt" != "1" ]]; then
      continue
    fi

    if [[ "$has_agy_non_done" == "1" ]]; then
      gh_state set-state pr "$pr_num" done || true
      if [[ -n "$issue_num" ]]; then
        gh_state set-state issue "$issue_num" done || true
      fi
    fi

    local removed_items=""
    if [[ -n "$wt_issue" && -d "$wt_issue" ]]; then
      remove_worktree_safe "$wt_issue" && removed_items+=" issue-${issue_num}"
    fi
    if [[ -d "$wt_review" ]]; then
      remove_worktree_safe "$wt_review" && removed_items+=" review-pr-${pr_num}"
    fi
    if [[ -d "$wt_e2e" ]]; then
      remove_worktree_safe "$wt_e2e" && removed_items+=" e2e-pr-${pr_num}"
    fi
    if [[ -d "$wt_final" ]]; then
      remove_worktree_safe "$wt_final" && removed_items+=" final-pr-${pr_num}"
    fi
    if [[ -d "$wt_final_resolve" ]]; then
      remove_worktree_safe "$wt_final_resolve" && removed_items+=" final-resolve-pr-${pr_num}"
    fi

    # 仅在本地分支存在且以 BRANCH_PREFIX 开头时安全删除（用 -d 而非 -D，仅删已合并分支）
    if [[ "$head_branch" == "${BRANCH_PREFIX}"* ]] && "$GIT_BIN" -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/${head_branch}"; then
      if [[ "$DRY_RUN" == "1" ]]; then
        printf '[DRY_RUN] %s -C %q branch -d %q\n' "$GIT_BIN" "$REPO_ROOT" "$head_branch" >&2
      else
        (
          "$FLOCK_BIN" -x 9
          "$GIT_BIN" -C "$REPO_ROOT" branch -d "$head_branch" >/dev/null 2>&1 || true
        ) 9>"$REPO_GIT_LOCK"
      fi
    fi

    local now_ts
    now_ts="$("$DATE_BIN" '+%F %T')"
    printf '[%s] 已收尾合并 PR #%s (Issue #%s): 标记 %sdone, 清理 worktree:%s\n' \
      "$now_ts" "$pr_num" "${issue_num:-?}" "$LABEL_PREFIX" "${removed_items:- (无)}"
    printf '[%s] [cleanup] PR #%s (Issue #%s) merged -> %sdone, removed:%s\n' \
      "$now_ts" "$pr_num" "${issue_num:-?}" "$LABEL_PREFIX" "${removed_items:-none}" >> "$ACTIVITY_LOG"
    cleaned_count=$((cleaned_count + 1))
  done < <("$JQ_BIN" -c '.[]' <<<"$prs_json")

  return 0
}

printf '[%s] 启动 cleanup-merged (repo=%s, interval=%ss, once=%s, DRY_RUN=%s)\n' \
  "$("$DATE_BIN" '+%F %T')" "${REPO:-$REPO_SLUG}" "$POLL_INTERVAL" "$ONCE" "$DRY_RUN"

while true; do
  run_cleanup_pass || true
  if (( ONCE == 1 )); then
    break
  fi
  "$SLEEP_BIN" "$POLL_INTERVAL"
done
