#!/usr/bin/bash
set -euo pipefail

# 纯确定性 GitHub Issue / PR 状态管理工具（不调用 agy）
# 一律使用全路径调用外部命令，所有写操作支持 DRY_RUN=1

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

GH_BIN="$(resolve_bin gh)"
JQ_BIN="$(resolve_bin jq)"
CAT_BIN="$(resolve_bin cat)"
MKDIR_BIN="$(resolve_bin mkdir)"

# ===== 可调配置 =====
GONGCAO_HOME="${GONGCAO_HOME:-${HOME}/.gongcao}"
REPOS_ROOT="${REPOS_ROOT:-${GONGCAO_HOME}/repos}"
REPO="${REPO:-}"
if [[ -z "${REPO_DIR:-}" ]]; then
  if [[ -n "$REPO" ]]; then
    _repo_slug="${REPO//\//__}"
    _repo_short="${REPO##*/}"
    if [[ -e "${REPOS_ROOT}/${_repo_slug}/.git" ]]; then
      REPO_DIR="${REPOS_ROOT}/${_repo_slug}"
    elif [[ -e "${REPOS_ROOT}/${_repo_short}/.git" ]]; then
      REPO_DIR="${REPOS_ROOT}/${_repo_short}"
    else
      REPO_DIR="$(pwd)"
    fi
  else
    REPO_DIR="$(pwd)"
  fi
fi
LABEL_PREFIX="${LABEL_PREFIX:-agy:}"
COMMENT_MARKER="${COMMENT_MARKER:-<!-- agy-status-comment -->}"
DRY_RUN="${DRY_RUN:-0}"

# 互斥状态定义：name|color|description
STATES=(
  "todo|0e8a16|Ready for agy to pick up"
  "in-progress|fbca04|Currently being processed by agy"
  "in-review|1d76db|Draft PR created or updated by agy, awaiting review"
  "blocked|d93f0b|Blocked or failed during agy execution; needs human attention"
  "done|5319e7|Completed"
)

usage() {
  "$CAT_BIN" <<'EOF' >&2
用法:
  gh-state.sh clone-repo <owner/repo> [dest_dir]
  gh-state.sh init-labels
  gh-state.sh list-issues [state] [label] [limit]
  gh-state.sh find-pr <head_branch>
  gh-state.sh set-state <issue|pr> <number> <todo|in-progress|in-review|blocked|done>
  gh-state.sh comment <issue|pr> <number> <body | ->
  gh-state.sh ensure-pr <issue_number> <head_branch> <base_branch> <title> [body_file]

环境变量:
  GONGCAO_HOME    主工作目录（默认 ~/.gongcao）
  REPOS_ROOT      托管仓库根目录（默认 ~/.gongcao/repos）
  REPO_DIR        仓库目录（留空时若指定 REPO 则优先查找 REPOS_ROOT，否则为当前目录）
  REPO            GitHub 仓库 owner/repo（留空自动从 REPO_DIR 探测）
  LABEL_PREFIX    状态标签前缀（默认 agy:）
  COMMENT_MARKER  置顶覆盖评论标记（默认 <!-- agy-status-comment -->）
  DRY_RUN         设为 1 时仅打印写操作，不修改远端 GitHub
EOF
}

run_gh() {
  (cd -- "$REPO_DIR" && "$GH_BIN" "$@")
}

RESOLVED_REPO=""
resolve_repo_slug() {
  if [[ -n "$RESOLVED_REPO" ]]; then
    printf '%s' "$RESOLVED_REPO"
    return 0
  fi
  if [[ -n "$REPO" ]]; then
    RESOLVED_REPO="$REPO"
  else
    RESOLVED_REPO="$(run_gh repo view --json nameWithOwner -q .nameWithOwner)"
  fi
  if [[ -z "$RESOLVED_REPO" ]]; then
    printf '错误：无法解析 GitHub 仓库 owner/repo，请设置 REPO 环境变量。\n' >&2
    exit 1
  fi
  printf '%s' "$RESOLVED_REPO"
}

is_valid_state() {
  local target="$1"
  local item name
  for item in "${STATES[@]}"; do
    name="${item%%|*}"
    [[ "$name" == "$target" ]] && return 0
  done
  return 1
}

cmd_clone_repo() {
  local target_repo="${1:-$REPO}"
  local dest_dir="${2:-}"

  if [[ -z "$target_repo" ]]; then
    printf '错误：clone-repo 需要 <owner/repo> 参数或设置 REPO 环境变量\n' >&2
    exit 2
  fi

  if [[ -z "$dest_dir" ]]; then
    local slug="${target_repo//\//__}"
    slug="${slug//[^a-zA-Z0-9._-]/_}"
    dest_dir="${REPOS_ROOT}/${slug}"
  fi

  if [[ -e "${dest_dir}/.git" ]]; then
    printf '仓库已存在于 %s，跳过 clone\n' "$dest_dir" >&2
    printf '%s\n' "$dest_dir"
    return 0
  fi

  local parent_dir="${dest_dir%/*}"
  if [[ "$parent_dir" != "$dest_dir" && -n "$parent_dir" ]]; then
    "$MKDIR_BIN" -p "$parent_dir"
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[DRY_RUN] %s repo clone %q %q\n' "$GH_BIN" "$target_repo" "$dest_dir" >&2
    printf '%s\n' "$dest_dir"
    return 0
  fi

  "$GH_BIN" repo clone "$target_repo" "$dest_dir" >&2
  printf '已克隆仓库 %s -> %s\n' "$target_repo" "$dest_dir" >&2
  printf '%s\n' "$dest_dir"
}

cmd_list_issues() {
  local issue_state="${1:-open}"
  local filter_label="${2:-}"
  local limit="${3:-20}"

  if [[ "$issue_state" != "open" && "$issue_state" != "closed" && "$issue_state" != "all" ]]; then
    printf '错误：list-issues 的 state 无效 (%q)，应为 open|closed|all\n' "$issue_state" >&2
    exit 2
  fi
  if [[ ! "$limit" =~ ^[0-9]+$ ]] || (( limit <= 0 )); then
    printf '错误：list-issues 的 limit 必须是正整数 (%q)\n' "$limit" >&2
    exit 2
  fi

  local -a args=(
    issue list
    --state "$issue_state"
    --limit "$limit"
    --json number,title,body,labels,state,url
  )
  [[ -n "$REPO" ]] && args+=(--repo "$REPO")
  [[ -n "$filter_label" ]] && args+=(--label "$filter_label")

  run_gh "${args[@]}"
}

cmd_init_labels() {
  local item name rest color desc full_label
  local -a extra_args=()
  [[ -n "$REPO" ]] && extra_args+=(--repo "$REPO")

  for item in "${STATES[@]}"; do
    name="${item%%|*}"
    rest="${item#*|}"
    color="${rest%%|*}"
    desc="${rest#*|}"
    full_label="${LABEL_PREFIX}${name}"

    if [[ "$DRY_RUN" == "1" ]]; then
      printf '[DRY_RUN] %s label create %q --color %q --description %q --force\n' \
        "$GH_BIN" "$full_label" "$color" "$desc" >&2
    else
      run_gh label create "$full_label" \
        --color "$color" \
        --description "$desc" \
        --force \
        "${extra_args[@]}" >/dev/null
    fi
  done
  printf '已确保状态标签存在（前缀：%s）\n' "$LABEL_PREFIX" >&2
}

cmd_set_state() {
  local kind="${1:-}"
  local number="${2:-}"
  local state="${3:-}"

  if [[ "$kind" != "issue" && "$kind" != "pr" ]] || [[ ! "$number" =~ ^[0-9]+$ ]]; then
    printf '错误：set-state 参数无效（需要 <issue|pr> <number> <state>）\n' >&2
    exit 2
  fi
  if ! is_valid_state "$state"; then
    printf '错误：未知状态 %q\n' "$state" >&2
    exit 2
  fi

  local target_label="${LABEL_PREFIX}${state}"
  local -a extra_args=()
  [[ -n "$REPO" ]] && extra_args+=(--repo "$REPO")

  # 读取现有标签，实现严格互斥切换
  local labels_json=""
  labels_json="$(run_gh "$kind" view "$number" --json labels "${extra_args[@]}")"

  local -a to_remove=()
  local has_target=0
  local lbl
  while IFS= read -r lbl; do
    [[ -z "$lbl" ]] && continue
    if [[ "$lbl" == "$target_label" ]]; then
      has_target=1
    elif [[ "$lbl" == "${LABEL_PREFIX}"* ]]; then
      to_remove+=("$lbl")
    fi
  done < <("$JQ_BIN" -r '.labels[]?.name // empty' <<<"$labels_json")

  local -a edit_args=("$kind" edit "$number" "${extra_args[@]}")
  local need_edit=0
  for lbl in "${to_remove[@]}"; do
    edit_args+=(--remove-label "$lbl")
    need_edit=1
  done
  if (( has_target == 0 )); then
    edit_args+=(--add-label "$target_label")
    need_edit=1
  fi

  if (( need_edit == 0 )); then
    printf '%s #%s 已处于状态 %s，跳过更新\n' "$kind" "$number" "$target_label" >&2
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[DRY_RUN] %s' "$GH_BIN" >&2
    printf ' %q' "${edit_args[@]}" >&2
    printf '\n' >&2
  else
    run_gh "${edit_args[@]}" >/dev/null
    printf '已切换 %s #%s 状态 -> %s\n' "$kind" "$number" "$target_label" >&2
  fi
}

cmd_comment() {
  local kind="${1:-}"
  local number="${2:-}"
  local body_arg="${3:-}"

  if [[ "$kind" != "issue" && "$kind" != "pr" ]] || [[ ! "$number" =~ ^[0-9]+$ ]] || [[ -z "$body_arg" ]]; then
    printf '错误：comment 参数无效（需要 <issue|pr> <number> <body | ->）\n' >&2
    exit 2
  fi

  local body=""
  if [[ "$body_arg" == "-" ]]; then
    body="$("$CAT_BIN")"
  else
    body="$body_arg"
  fi

  # 确保顶部包含隐藏标记，便于下次原地覆盖更新
  if [[ "$body" != *"$COMMENT_MARKER"* ]]; then
    body="${COMMENT_MARKER}"$'\n'"${body}"
  fi

  local repo_slug
  repo_slug="$(resolve_repo_slug)"

  # 查找是否已有带标记的评论（Issue 与 PR 普通评论均走 /issues/{number}/comments）
  local existing_id=""
  local comments_json=""
  comments_json="$(run_gh api --paginate "repos/${repo_slug}/issues/${number}/comments?per_page=100" --jq '.[]')"
  if [[ -n "$comments_json" ]]; then
    while IFS= read -r cid; do
      [[ -n "$cid" ]] && existing_id="$cid"
    done < <("$JQ_BIN" -r --arg marker "$COMMENT_MARKER" \
      'select((.body // "") | contains($marker)) | .id' <<<"$comments_json")
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    if [[ -n "$existing_id" ]]; then
      printf '[DRY_RUN] PATCH repos/%s/issues/comments/%s (%s #%s)\n' "$repo_slug" "$existing_id" "$kind" "$number" >&2
    else
      printf '[DRY_RUN] POST repos/%s/issues/%s/comments (%s #%s)\n' "$repo_slug" "$number" "$kind" "$number" >&2
    fi
    return 0
  fi

  if [[ -n "$existing_id" ]]; then
    run_gh api -X PATCH "repos/${repo_slug}/issues/comments/${existing_id}" \
      -f body="$body" >/dev/null
    printf '已更新 %s #%s 置顶状态评论 (id=%s)\n' "$kind" "$number" "$existing_id" >&2
  else
    run_gh api -X POST "repos/${repo_slug}/issues/${number}/comments" \
      -f body="$body" >/dev/null
    printf '已创建 %s #%s 置顶状态评论\n' "$kind" "$number" >&2
  fi
}

cmd_find_pr() {
  local head_branch="${1:-}"
  if [[ -z "$head_branch" ]]; then
    printf '错误：find-pr 需要 <head_branch> 参数\n' >&2
    exit 2
  fi

  local -a extra_args=()
  [[ -n "$REPO" ]] && extra_args+=(--repo "$REPO")

  local pr_json=""
  pr_json="$(run_gh pr list --head "$head_branch" --state open --limit 1 --json number,url "${extra_args[@]}")"
  "$JQ_BIN" -r 'if length > 0 then "\(.[0].number)\t\(.[0].url)" else empty end' <<<"$pr_json"
}

cmd_ensure_pr() {
  local issue_num="${1:-}"
  local head_branch="${2:-}"
  local base_branch="${3:-}"
  local pr_title="${4:-}"
  local body_file="${5:-}"

  if [[ ! "$issue_num" =~ ^[0-9]+$ ]] || [[ -z "$head_branch" ]] || [[ -z "$base_branch" ]] || [[ -z "$pr_title" ]]; then
    printf '错误：ensure-pr 参数无效（需要 <issue_number> <head_branch> <base_branch> <title> [body_file]）\n' >&2
    exit 2
  fi

  local pr_body=""
  if [[ -n "$body_file" && -f "$body_file" ]]; then
    pr_body="$("$CAT_BIN" "$body_file")"
  fi
  if [[ -z "$pr_body" ]]; then
    pr_body="Automated draft PR for issue #${issue_num}."
  fi
  if [[ "$pr_body" != *"Closes #${issue_num}"* ]]; then
    pr_body="${pr_body}"$'\n\n'"Closes #${issue_num}"
  fi

  local -a extra_args=()
  [[ -n "$REPO" ]] && extra_args+=(--repo "$REPO")

  # 检查该分支是否已有 open PR
  local existing_json=""
  existing_json="$(run_gh pr list --head "$head_branch" --state open --limit 1 --json number,url "${extra_args[@]}")"
  local existing_num="" existing_url=""
  existing_num="$("$JQ_BIN" -r '.[0].number // empty' <<<"$existing_json")"
  existing_url="$("$JQ_BIN" -r '.[0].url // empty' <<<"$existing_json")"

  if [[ -n "$existing_num" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      printf '[DRY_RUN] %s pr edit %s --title %q --body <...>\n' "$GH_BIN" "$existing_num" "$pr_title" >&2
    else
      run_gh pr edit "$existing_num" --title "$pr_title" --body "$pr_body" "${extra_args[@]}" >/dev/null
      printf '已更新现有 PR #%s: %s\n' "$existing_num" "$existing_url" >&2
    fi
    cmd_set_state pr "$existing_num" in-review
    printf '%s\n' "$existing_url"
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[DRY_RUN] %s pr create --draft --head %q --base %q --title %q --body <...>\n' \
      "$GH_BIN" "$head_branch" "$base_branch" "$pr_title" >&2
    printf '(dry-run-pr)\n'
    return 0
  fi

  local created_url=""
  created_url="$(run_gh pr create \
    --draft \
    --head "$head_branch" \
    --base "$base_branch" \
    --title "$pr_title" \
    --body "$pr_body" \
    "${extra_args[@]}")"

  # 提取新建 PR 编号并打上 in-review 状态标签
  local created_num=""
  created_num="${created_url##*/}"
  if [[ "$created_num" =~ ^[0-9]+$ ]]; then
    cmd_set_state pr "$created_num" in-review
  fi
  printf '已创建 Draft PR: %s\n' "$created_url" >&2
  printf '%s\n' "$created_url"
}

main() {
  local subcmd="${1:-}"
  shift || true
  case "$subcmd" in
    clone-repo)  cmd_clone_repo "$@" ;;
    init-labels) cmd_init_labels "$@" ;;
    list-issues) cmd_list_issues "$@" ;;
    find-pr)     cmd_find_pr "$@" ;;
    set-state)   cmd_set_state "$@" ;;
    comment)     cmd_comment "$@" ;;
    ensure-pr)   cmd_ensure_pr "$@" ;;
    -h|--help|"")
      usage
      [[ -n "$subcmd" ]] && exit 0 || exit 2
      ;;
    *)
      printf '错误：未知子命令 %q\n' "$subcmd" >&2
      usage
      exit 2
      ;;
  esac
}

main "$@"
