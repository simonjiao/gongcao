#!/usr/bin/bash
set -euo pipefail

# 纯确定性 GitHub Issue / PR 状态管理工具（不调用 agy）
# 一律使用全路径调用外部命令，所有写操作支持 DRY_RUN=1

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/release-handoff.sh"

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
SLEEP_BIN="$(resolve_bin sleep)"

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
  "changes-requested|e99695|Reviewer, E2E, or Final Gate requested changes; awaiting follow-up fixes"
  "approved|2ea44f|Independent code review passed; ready for E2E verification"
  "e2e-passed|006b75|Independent E2E verification passed; ready for final gate sign-off"
  "e2e-skipped|0075ca|Code review confirmed E2E is unnecessary or prior E2E remains valid; routed directly to final gate"
  "release-pending|1d76db|Release candidate preparation or acceptance pending"
  "ready-to-merge|0e8a16|Final gate passed; ready for merge"
  "blocked|d93f0b|Blocked or failed during automation; needs human attention"
  "done|5319e7|Completed"
)

usage() {
  "$CAT_BIN" <<'EOF' >&2
用法:
  gh-state.sh clone-repo <owner/repo> [dest_dir]
  gh-state.sh init-labels
  gh-state.sh list-issues [state] [label] [limit]
  gh-state.sh get-issue <number>
  gh-state.sh list-prs [state] [label] [limit]
  gh-state.sh get-pr-diff <number>
  gh-state.sh find-pr <head_branch>
  gh-state.sh set-state <issue|pr> <number> <todo|in-progress|in-review|changes-requested|approved|e2e-passed|e2e-skipped|ready-to-merge|release-pending|blocked|done>
  gh-state.sh comment <issue|pr> <number> <body | -> [marker]
  gh-state.sh get-comment <issue|pr> <number> [marker]
  gh-state.sh ensure-pr <issue_number> <head_branch> <base_branch> <title> [body_file]
  gh-state.sh update-pr <pr_number> <title> <body_file>
  gh-state.sh mark-pr-ready <pr_number>
  gh-state.sh merge-pr <pr_number> [merge|squash|rebase] [expected_head_sha]
  gh-state.sh get-repo-merge-settings
  gh-state.sh create-issue <title> <body_file> [labels_csv] [dedup_key]

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

GH_MAX_RETRIES="${GH_MAX_RETRIES:-3}"

run_gh() {
  local attempt=1
  local rc=0
  local wait_sec=2
  while true; do
    if (cd -- "$REPO_DIR" && "$GH_BIN" "$@"); then
      return 0
    else
      rc=$?
    fi
    if (( attempt >= GH_MAX_RETRIES )); then
      return "$rc"
    fi
    printf '[gh-state] 警告：gh 调用失败 (exit=%d, 第 %d/%d 次)，%ss 后重试...\n' \
      "$rc" "$attempt" "$GH_MAX_RETRIES" "$wait_sec" >&2
    "$SLEEP_BIN" "$wait_sec"
    attempt=$((attempt + 1))
    wait_sec=$((wait_sec * 2))
  done
}

run_gh_stdin() {
  local stdin_data="$1"
  shift
  local attempt=1
  local rc=0
  local wait_sec=2
  while true; do
    if (cd -- "$REPO_DIR" && printf '%s\n' "$stdin_data" | "$GH_BIN" "$@"); then
      return 0
    else
      rc=$?
    fi
    if (( attempt >= GH_MAX_RETRIES )); then
      return "$rc"
    fi
    printf '[gh-state] 警告：gh stdin 调用失败 (exit=%d, 第 %d/%d 次)，%ss 后重试...\n' \
      "$rc" "$attempt" "$GH_MAX_RETRIES" "$wait_sec" >&2
    "$SLEEP_BIN" "$wait_sec"
    attempt=$((attempt + 1))
    wait_sec=$((wait_sec * 2))
  done
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

cmd_get_issue() {
  local number="${1:-}"
  if [[ ! "$number" =~ ^[0-9]+$ ]]; then
    printf '错误：get-issue 需要有效的 <number>\n' >&2
    exit 2
  fi
  local -a extra_args=()
  [[ -n "$REPO" ]] && extra_args+=(--repo "$REPO")
  run_gh issue view "$number" --json number,title,body,state,url,labels "${extra_args[@]}"
}

cmd_list_prs() {
  local pr_state="${1:-open}"
  local filter_label="${2:-}"
  local limit="${3:-20}"

  if [[ "$pr_state" != "open" && "$pr_state" != "closed" && "$pr_state" != "merged" && "$pr_state" != "all" ]]; then
    printf '错误：list-prs 的 state 无效 (%q)，应为 open|closed|merged|all\n' "$pr_state" >&2
    exit 2
  fi
  if [[ ! "$limit" =~ ^[0-9]+$ ]] || (( limit <= 0 )); then
    printf '错误：list-prs 的 limit 必须是正整数 (%q)\n' "$limit" >&2
    exit 2
  fi

  local -a args=(
    pr list
    --state "$pr_state"
    --limit "$limit"
    --json number,title,body,url,state,isDraft,headRefName,baseRefName,headRefOid,mergeable,mergeStateStatus,mergedAt,mergeCommit,statusCheckRollup,labels,updatedAt
  )
  [[ -n "$REPO" ]] && args+=(--repo "$REPO")
  [[ -n "$filter_label" ]] && args+=(--label "$filter_label")

  run_gh "${args[@]}"
}

cmd_get_pr_diff() {
  local number="${1:-}"
  if [[ ! "$number" =~ ^[0-9]+$ ]]; then
    printf '错误：get-pr-diff 需要有效的 <number>\n' >&2
    exit 2
  fi
  local -a extra_args=()
  [[ -n "$REPO" ]] && extra_args+=(--repo "$REPO")
  run_gh pr diff "$number" "${extra_args[@]}"
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
  local repo_slug
  repo_slug="$(resolve_repo_slug)"

  # 使用稳定的 REST API（Issue 与 PR 共用 /issues/{number}/labels），
  # 避免旧版 gh (如 2.45.0) 的 gh pr edit 因 GraphQL Projects (classic) 废弃字段报错
  local labels_json=""
  labels_json="$(run_gh api "repos/${repo_slug}/issues/${number}/labels?per_page=100")"

  local has_target=0
  local has_other_state=0
  local lbl
  while IFS= read -r lbl; do
    [[ -z "$lbl" ]] && continue
    if [[ "$lbl" == "$target_label" ]]; then
      has_target=1
    elif [[ "$lbl" == "${LABEL_PREFIX}"* ]]; then
      has_other_state=1
    fi
  done < <("$JQ_BIN" -r '.[]?.name // empty' <<<"$labels_json")

  if (( has_target == 1 && has_other_state == 0 )); then
    printf '%s #%s 已处于状态 %s，跳过更新\n' "$kind" "$number" "$target_label" >&2
    return 0
  fi

  local payload=""
  payload="$("$JQ_BIN" -c \
    --arg prefix "$LABEL_PREFIX" \
    --arg target "$target_label" \
    '{labels: (([.[]?.name | select(startswith($prefix) | not)] + [$target]) | unique)}' \
    <<<"$labels_json")"

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[DRY_RUN] PUT repos/%s/issues/%s/labels %s\n' "$repo_slug" "$number" "$payload" >&2
  else
    run_gh_stdin "$payload" api -X PUT "repos/${repo_slug}/issues/${number}/labels" --input - >/dev/null
    printf '已切换 %s #%s 状态 -> %s\n' "$kind" "$number" "$target_label" >&2
  fi
}

cmd_comment() {
  local kind="${1:-}"
  local number="${2:-}"
  local body_arg="${3:-}"
  local marker="${4:-$COMMENT_MARKER}"

  if [[ "$kind" != "issue" && "$kind" != "pr" ]] || [[ ! "$number" =~ ^[0-9]+$ ]] || [[ -z "$body_arg" ]]; then
    printf '错误：comment 参数无效（需要 <issue|pr> <number> <body | -> [marker]）\n' >&2
    exit 2
  fi

  local body=""
  if [[ "$body_arg" == "-" ]]; then
    body="$("$CAT_BIN")"
  else
    body="$body_arg"
  fi

  # 确保顶部包含隐藏标记，便于下次原地覆盖更新
  if [[ "$body" != *"$marker"* ]]; then
    body="${marker}"$'\n'"${body}"
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
    done < <("$JQ_BIN" -r --arg marker "$marker" \
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

cmd_get_comment() {
  local kind="${1:-}"
  local number="${2:-}"
  local marker="${3:-$COMMENT_MARKER}"

  if [[ "$kind" != "issue" && "$kind" != "pr" ]] || [[ ! "$number" =~ ^[0-9]+$ ]]; then
    printf '错误：get-comment 参数无效（需要 <issue|pr> <number> [marker]）\n' >&2
    exit 2
  fi

  local repo_slug
  repo_slug="$(resolve_repo_slug)"

  local comments_json=""
  comments_json="$(run_gh api --paginate "repos/${repo_slug}/issues/${number}/comments?per_page=100" --jq '.[]')"
  if [[ -z "$comments_json" ]]; then
    return 0
  fi

  "$JQ_BIN" -rs --arg marker "$marker" \
    '[.[] | select((.body // "") | contains($marker))] | last | .body // empty' \
    <<<"$comments_json"
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
  if [[ "$(release_issue_from_pr "$pr_body")" != "$issue_num" && "$pr_body" != *"Closes #${issue_num}"* ]]; then
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
    local repo_slug
    repo_slug="$(resolve_repo_slug)"
    if [[ "$DRY_RUN" == "1" ]]; then
      printf '[DRY_RUN] PATCH repos/%s/pulls/%s (title=%q)\n' "$repo_slug" "$existing_num" "$pr_title" >&2
    else
      local patch_payload=""
      patch_payload="$("$JQ_BIN" -c -n --arg title "$pr_title" --arg body "$pr_body" '{title: $title, body: $body}')"
      run_gh_stdin "$patch_payload" api -X PATCH "repos/${repo_slug}/pulls/${existing_num}" --input - >/dev/null
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

cmd_update_pr() {
  local pr_num="${1:-}"
  local pr_title="${2:-}"
  local body_file="${3:-}"

  if [[ ! "$pr_num" =~ ^[0-9]+$ ]] || [[ -z "$pr_title" ]] || [[ -z "$body_file" || ! -f "$body_file" ]]; then
    printf '错误：update-pr 参数无效（需要 <pr_number> <title> <body_file>）\n' >&2
    exit 2
  fi

  local pr_body
  pr_body="$("$CAT_BIN" "$body_file")"
  local repo_slug
  repo_slug="$(resolve_repo_slug)"

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[DRY_RUN] PATCH repos/%s/pulls/%s (title=%q)\n' "$repo_slug" "$pr_num" "$pr_title" >&2
    return 0
  fi

  local patch_payload=""
  patch_payload="$("$JQ_BIN" -c -n --arg title "$pr_title" --arg body "$pr_body" '{title: $title, body: $body}')"
  run_gh_stdin "$patch_payload" api -X PATCH "repos/${repo_slug}/pulls/${pr_num}" --input - >/dev/null
  printf '已更新 PR #%s 标题与正文\n' "$pr_num" >&2
}

cmd_mark_pr_ready() {
  local pr_num="${1:-}"
  if [[ ! "$pr_num" =~ ^[0-9]+$ ]]; then
    printf '错误：mark-pr-ready 需要有效的 <pr_number>\n' >&2
    exit 2
  fi

  local -a extra_args=()
  [[ -n "$REPO" ]] && extra_args+=(--repo "$REPO")

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[DRY_RUN] %s pr ready %s\n' "$GH_BIN" "$pr_num" >&2
    return 0
  fi

  run_gh pr ready "$pr_num" "${extra_args[@]}" >/dev/null
  printf '已将 PR #%s 转为 Ready for review\n' "$pr_num" >&2
}

cmd_merge_pr() {
  local pr_num="${1:-}"
  local method="${2:-merge}"
  local expected_sha="${3:-}"

  if [[ ! "$pr_num" =~ ^[0-9]+$ ]]; then
    printf '错误：merge-pr 需要有效的 <pr_number>\n' >&2
    exit 2
  fi
  if [[ "$method" != "merge" && "$method" != "squash" && "$method" != "rebase" ]]; then
    printf '错误：merge-pr 的合并方式无效 (%q)，应为 merge|squash|rebase\n' "$method" >&2
    exit 2
  fi

  local repo_slug
  repo_slug="$(resolve_repo_slug)"

  local payload=""
  if [[ -n "$expected_sha" ]]; then
    payload="$("$JQ_BIN" -c -n --arg method "$method" --arg sha "$expected_sha" '{merge_method: $method, sha: $sha}')"
  else
    payload="$("$JQ_BIN" -c -n --arg method "$method" '{merge_method: $method}')"
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[DRY_RUN] PUT repos/%s/pulls/%s/merge %s\n' "$repo_slug" "$pr_num" "$payload" >&2
    return 0
  fi

  run_gh_stdin "$payload" api -X PUT "repos/${repo_slug}/pulls/${pr_num}/merge" --input - >/dev/null
  printf '已合并 PR #%s (method=%s, sha=%s)\n' "$pr_num" "$method" "${expected_sha:0:10}" >&2
}

cmd_get_repo_merge_settings() {
  local repo_slug
  repo_slug="$(resolve_repo_slug)"
  run_gh api "repos/${repo_slug}" --jq '{allow_merge_commit: (if .allow_merge_commit == null then true else .allow_merge_commit end), allow_squash_merge: (if .allow_squash_merge == null then true else .allow_squash_merge end), allow_rebase_merge: (if .allow_rebase_merge == null then true else .allow_rebase_merge end)}'
}

cmd_create_issue() {
  local title="${1:-}"
  local body_file="${2:-}"
  local labels_csv="${3:-}"
  local dedup_key="${4:-}"

  if [[ -z "$title" || -z "$body_file" || ! -f "$body_file" ]]; then
    printf '错误：create-issue 参数无效（需要 <title> <body_file> [labels_csv] [dedup_key]）\n' >&2
    exit 2
  fi

  local body=""
  body="$("$CAT_BIN" "$body_file")"
  if [[ -n "$dedup_key" && "$body" != *"$dedup_key"* ]]; then
    body="${body}"$'\n\n'"${dedup_key}"
  fi

  local repo_slug
  repo_slug="$(resolve_repo_slug)"

  # 幂等去重：若已有含相同追踪标记的 Open Issue，直接返回既有记录
  if [[ -n "$dedup_key" && "$DRY_RUN" != "1" ]]; then
    local existing_json=""
    existing_json="$(run_gh api --paginate "repos/${repo_slug}/issues?state=open&per_page=100" --jq '.[] | select(.pull_request == null)' 2>/dev/null || true)"
    if [[ -n "$existing_json" ]]; then
      local match_json="" existing_num="" existing_url=""
      match_json="$("$JQ_BIN" -rs --arg key "$dedup_key" \
        '[.[] | select((.body // "") | contains($key))] | first // empty' \
        <<<"$existing_json")"
      if [[ -n "$match_json" ]]; then
        existing_num="$("$JQ_BIN" -r '.number // empty' <<<"$match_json")"
        existing_url="$("$JQ_BIN" -r '.html_url // .url // empty' <<<"$match_json")"
        if [[ -n "$existing_num" ]]; then
          printf '已存在同追踪键的 Open Issue #%s: %s，跳过重复创建\n' "$existing_num" "$existing_url" >&2
          printf '%s\t%s\texisting\n' "$existing_num" "$existing_url"
          return 0
        fi
      fi
    fi
  fi

  local payload=""
  if [[ -n "$labels_csv" ]]; then
    payload="$("$JQ_BIN" -c -n \
      --arg title "$title" \
      --arg body "$body" \
      --arg labels_csv "$labels_csv" \
      '($labels_csv | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) | unique) as $lbls |
       if ($lbls | length) > 0 then {title: $title, body: $body, labels: $lbls} else {title: $title, body: $body} end')"
  else
    payload="$("$JQ_BIN" -c -n --arg title "$title" --arg body "$body" '{title: $title, body: $body}')"
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[DRY_RUN] POST repos/%s/issues (title=%q, labels=%q, dedup_key=%q)\n' \
      "$repo_slug" "$title" "$labels_csv" "$dedup_key" >&2
    printf '0\t(dry-run-issue)\tdry-run\n'
    return 0
  fi

  local created_json="" created_num="" created_url=""
  created_json="$(run_gh_stdin "$payload" api -X POST "repos/${repo_slug}/issues" --input -)"
  created_num="$("$JQ_BIN" -r '.number // empty' <<<"$created_json")"
  created_url="$("$JQ_BIN" -r '.html_url // .url // empty' <<<"$created_json")"
  printf '已创建后续追踪 Issue #%s: %s\n' "$created_num" "$created_url" >&2
  printf '%s\t%s\tcreated\n' "$created_num" "$created_url"
}

main() {
  local subcmd="${1:-}"
  shift || true
  case "$subcmd" in
    clone-repo)    cmd_clone_repo "$@" ;;
    init-labels)   cmd_init_labels "$@" ;;
    list-issues)   cmd_list_issues "$@" ;;
    get-issue)     cmd_get_issue "$@" ;;
    list-prs)      cmd_list_prs "$@" ;;
    get-pr-diff)   cmd_get_pr_diff "$@" ;;
    find-pr)       cmd_find_pr "$@" ;;
    set-state)     cmd_set_state "$@" ;;
    comment)       cmd_comment "$@" ;;
    get-comment)   cmd_get_comment "$@" ;;
    ensure-pr)     cmd_ensure_pr "$@" ;;
    update-pr)               cmd_update_pr "$@" ;;
    mark-pr-ready)           cmd_mark_pr_ready "$@" ;;
    merge-pr)                cmd_merge_pr "$@" ;;
    get-repo-merge-settings) cmd_get_repo_merge_settings "$@" ;;
    create-issue)            cmd_create_issue "$@" ;;
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
