#!/usr/bin/bash
set -euo pipefail

# 获取脚本所在目录并执行前置依赖检查
SCRIPT_DIR="$(cd -- "$([[ "${BASH_SOURCE[0]}" == */* ]] && printf '%s' "${BASH_SOURCE[0]%/*}" || printf '.')" && pwd)"
"${SCRIPT_DIR}/check-deps.sh"
GH_STATE_BIN="${SCRIPT_DIR}/gh-state.sh"

# 解析所需命令的绝对路径（一律全路径调用）
SEARCH_PATH="${PATH}:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin"
resolve_bin() {
  PATH="$SEARCH_PATH" type -P "$1"
}

JQ_BIN="$(resolve_bin jq)"
AGY_BIN="$(resolve_bin agy)"
GIT_BIN="$(resolve_bin git)"
GREP_BIN="$(resolve_bin grep)"
MKDIR_BIN="$(resolve_bin mkdir)"
TOUCH_BIN="$(resolve_bin touch)"
DATE_BIN="$(resolve_bin date)"
SLEEP_BIN="$(resolve_bin sleep)"
TEE_BIN="$(resolve_bin tee)"
CAT_BIN="$(resolve_bin cat)"

# ===== 主工作目录与可调配置 =====
GONGCAO_HOME="${GONGCAO_HOME:-${HOME}/.gongcao}"
REPOS_ROOT="${REPOS_ROOT:-${GONGCAO_HOME}/repos}"
STATE_BASE="${STATE_BASE:-${GONGCAO_HOME}/state}"

REPO="${REPO:-}"                       # 目标 GitHub 仓库 "owner/repo"（留空默认从本地仓库识别）
REPO_NAME="${REPO_NAME:-}"             # 可选：直接指定 ~/.gongcao/repos/<REPO_NAME>
REPO_DIR="${REPO_DIR:-}"               # 可选：显式指定本地仓库路径；留空时按 REPO/REPO_NAME 定位到 ~/.gongcao/repos/
AUTO_CLONE="${AUTO_CLONE:-1}"          # 指定 REPO 且本地尚未克隆时，是否自动 clone 到 ~/.gongcao/repos/（1=是，0=否）
BASE_BRANCH="${BASE_BRANCH:-}"         # 创建 worktree/PR 的基准分支，留空自动探测 origin/HEAD 或当前 HEAD
BRANCH_PREFIX="${BRANCH_PREFIX:-agy/issue-}"
LABEL_PREFIX="${LABEL_PREFIX:-agy:}"
GIT_FETCH="${GIT_FETCH:-1}"            # 创建新 worktree 前是否尝试 git fetch origin（1=是，0=否）
GH_SYNC_ENABLED="${GH_SYNC_ENABLED:-1}" # 是否启用 GitHub 状态机与置顶评论（1=是，0=纯本地模式）
INIT_LABELS="${INIT_LABELS:-1}"        # 启动时是否幂等初始化 agy:* 标签（1=是，0=否）
AUTO_PUSH_PR="${AUTO_PUSH_PR:-1}"      # 有新 commit 时是否自动 push 分支并创建/更新 Draft PR（1=是，0=仅维护 Issue 状态）
DRY_RUN="${DRY_RUN:-0}"                # 1=演练模式（不修改远端 GitHub、不执行 git push）
ISSUE_STATE="${ISSUE_STATE:-open}"     # open | closed | all
ISSUE_LIMIT="${ISSUE_LIMIT:-20}"       # 每次拉取的最大 issue 数量
# 启用 GitHub 状态机时默认只拉取人工放行的 agy:todo；显式传 FILTER_LABEL="" 可关闭标签过滤
if [[ "$GH_SYNC_ENABLED" == "1" ]]; then
  FILTER_LABEL="${FILTER_LABEL-${LABEL_PREFIX}todo}"
else
  FILTER_LABEL="${FILTER_LABEL-}"
fi
HANDLE_CHANGES_REQUESTED="${HANDLE_CHANGES_REQUESTED:-1}" # 是否自动接回评审打回的 agy:changes-requested（1=是，0=否）
REVIEW_COMMENT_MARKER="${REVIEW_COMMENT_MARKER:-<!-- codex-review-comment -->}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"   # 无新 issue 时的轮询间隔（秒）
MAX_BACKOFF="${MAX_BACKOFF:-900}"      # 连续拉取失败时的最大退避上限（秒，默认 15 分钟）
PRINT_TIMEOUT="${PRINT_TIMEOUT:-15m}"
AGY_MODE="${AGY_MODE:-accept-edits}"   # accept-edits | auto | plan（默认 accept-edits 避免账号无 auto 权限告警）
AGY_SKIP_PERMISSIONS="${AGY_SKIP_PERMISSIONS:-1}" # 在 --sandbox 内免本地交互确认自动推进（1=启用，0=关闭）
AGY_MODEL="${AGY_MODEL:-gemini-4-hydrogen-high}"  # 默认使用 Gemini 4 Hydrogen (High)

"$MKDIR_BIN" -p "$GONGCAO_HOME" "$REPOS_ROOT" "$STATE_BASE"

# 解析目标仓库目录（优先使用 ~/.gongcao/repos/）
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
      REPO_DIR="${REPOS_ROOT}/${_slug}"
      if [[ "$AUTO_CLONE" == "1" ]]; then
        # clone 属于只读远端操作，即使在 DRY_RUN=1 演练模式下也需要本地仓库副本才能继续
        if [[ "$DRY_RUN" == "1" ]]; then
          printf '提示：DRY_RUN=1 仅跳过远端写操作，将先只读克隆 %s 到 %s 用于本地演练。\n' "$REPO" "$REPO_DIR" >&2
        fi
        GONGCAO_HOME="$GONGCAO_HOME" REPOS_ROOT="$REPOS_ROOT" REPO="$REPO" DRY_RUN=0 \
          "$GH_STATE_BIN" clone-repo "$REPO" "$REPO_DIR" >/dev/null
      fi
    fi
  elif [[ -n "$REPO_NAME" ]]; then
    REPO_DIR="${REPOS_ROOT}/${REPO_NAME}"
  else
    REPO_DIR="$(pwd)"
  fi
fi

# 校验目标仓库目录并获取主仓库根目录
if ! REPO_ROOT="$("$GIT_BIN" -C "$REPO_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  printf '错误：REPO_DIR (%s) 不是一个有效的 Git 仓库。\n' "$REPO_DIR" >&2
  printf '提示：可先克隆到 %s/<repo> 或传入 REPO=owner/repo 自动克隆。\n' "$REPOS_ROOT" >&2
  exit 1
fi

# 生成仓库标识，用于隔离不同仓库的状态、worktree 和会话记录
if [[ -n "$REPO" ]]; then
  REPO_SLUG="${REPO//\//__}"
else
  REPO_SLUG="${REPO_ROOT##*/}"
fi
REPO_SLUG="${REPO_SLUG//[^a-zA-Z0-9._-]/_}"

# 持久化目录布局（统一位于 ~/.gongcao/state/<repo_slug>/）
STATE_ROOT="${STATE_ROOT:-${STATE_BASE}/${REPO_SLUG}}"
WORKTREE_ROOT="${WORKTREE_ROOT:-${STATE_ROOT}/worktrees}"
SESSIONS_ROOT="${SESSIONS_ROOT:-${STATE_ROOT}/sessions}"
STATE_FILE="${STATE_FILE:-${STATE_ROOT}/processed_issues.txt}"

"$MKDIR_BIN" -p "$STATE_ROOT" "$WORKTREE_ROOT" "$SESSIONS_ROOT"
"$TOUCH_BIN" "$STATE_FILE"

# 判断是否完全以 GitHub 状态标签作为队列真相源（人工把标签改回 agy:todo 时可自动续接）
USE_LOCAL_DEDUP=1
if [[ "$GH_SYNC_ENABLED" == "1" && "$DRY_RUN" != "1" && "$FILTER_LABEL" == "${LABEL_PREFIX}todo" ]]; then
  USE_LOCAL_DEDUP=0
fi

gh_state() {
  GONGCAO_HOME="$GONGCAO_HOME" \
  REPOS_ROOT="$REPOS_ROOT" \
  REPO_DIR="$REPO_ROOT" \
  REPO="$REPO" \
  LABEL_PREFIX="$LABEL_PREFIX" \
  DRY_RUN="$DRY_RUN" \
  "$GH_STATE_BIN" "$@"
}

printf '[%s] 启动 agy-issue-loop\n' "$("$DATE_BIN" '+%F %T')"
printf '  工作主目录 : %s\n' "$GONGCAO_HOME"
printf '  主仓库目录 : %s\n' "$REPO_ROOT"
printf '  状态根目录 : %s\n' "$STATE_ROOT"
printf '  Worktree 根: %s\n' "$WORKTREE_ROOT"
printf '  会话记录根 : %s\n' "$SESSIONS_ROOT"
printf '  过滤标签   : %s\n' "${FILTER_LABEL:-(无)}"
printf '  运行模型   : %s (mode=%s, skip_permissions=%s)\n' "${AGY_MODEL:-(agy 默认)}" "$AGY_MODE" "$AGY_SKIP_PERMISSIONS"
printf '  GitHub同步 : %s (AUTO_PUSH_PR=%s, DRY_RUN=%s)\n' "$GH_SYNC_ENABLED" "$AUTO_PUSH_PR" "$DRY_RUN"

LABELS_READY=0
if [[ "$GH_SYNC_ENABLED" == "1" && "$INIT_LABELS" == "1" ]]; then
  if gh_state init-labels; then
    LABELS_READY=1
  else
    printf '[%s] 警告：初始化状态标签失败（将在后续轮询中自动重试）\n' "$("$DATE_BIN" '+%F %T')" >&2
  fi
fi

calc_backoff() {
  local errors="$1"
  local shift=$(( errors > 0 ? errors - 1 : 0 ))
  (( shift > 4 )) && shift=4
  local wait_sec=$(( POLL_INTERVAL * (1 << shift) ))
  (( wait_sec > MAX_BACKOFF )) && wait_sec="$MAX_BACKOFF"
  printf '%s' "$wait_sec"
}

resolve_base_ref() {
  if [[ -n "$BASE_BRANCH" ]]; then
    printf '%s' "$BASE_BRANCH"
    return 0
  fi
  local origin_head=""
  if origin_head="$("$GIT_BIN" -C "$REPO_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"; then
    printf '%s' "$origin_head"
    return 0
  fi
  "$GIT_BIN" -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD
}

# 将 origin/main 转成 PR 使用的裸分支名 main
strip_origin_prefix() {
  local ref="$1"
  printf '%s' "${ref#origin/}"
}

ensure_worktree() {
  local issue_num="$1"
  local base_ref="$2"
  local branch="${BRANCH_PREFIX}${issue_num}"
  local wt_dir="${WORKTREE_ROOT}/issue-${issue_num}"

  # 若 worktree 目录已存在且有效，直接复用（保留已有修改与上下文）
  if [[ -e "${wt_dir}/.git" ]]; then
    printf '%s' "$wt_dir"
    return 0
  fi

  # 清理可能失效的历史 worktree 元数据
  "$GIT_BIN" -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true

  if [[ "$GIT_FETCH" == "1" ]] && "$GIT_BIN" -C "$REPO_ROOT" remote get-url origin >/dev/null 2>&1; then
    "$GIT_BIN" -C "$REPO_ROOT" fetch --prune origin >&2 || true
  fi

  if "$GIT_BIN" -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/${branch}"; then
    "$GIT_BIN" -C "$REPO_ROOT" worktree add "$wt_dir" "$branch" >&2
  elif "$GIT_BIN" -C "$REPO_ROOT" show-ref --verify --quiet "refs/remotes/origin/${branch}"; then
    "$GIT_BIN" -C "$REPO_ROOT" worktree add --track -b "$branch" "$wt_dir" "origin/${branch}" >&2
  else
    "$GIT_BIN" -C "$REPO_ROOT" worktree add -b "$branch" "$wt_dir" "$base_ref" >&2
  fi

  printf '%s' "$wt_dir"
}

extract_conversation_id() {
  local events_file="$1"
  local id=""
  while IFS= read -r line; do
    [[ -n "$line" ]] && id="$line"
  done < <("$JQ_BIN" -R -r 'fromjson? | (.conversation_id // .conversationId // .session_id // .sessionId // empty)' "$events_file" 2>/dev/null || true)
  printf '%s' "$id"
}

write_session_meta() {
  local meta_file="$1"
  local issue_num="$2"
  local title="$3"
  local url="$4"
  local issue_state="$5"
  local labels="$6"
  local branch="$7"
  local wt_dir="$8"
  local conv_id="$9"
  local pr_url="${10}"
  local run_status="${11}"
  local updated_at="${12}"

  local transcript_hint=""
  local resume_cmd=""
  if [[ -n "$conv_id" ]]; then
    transcript_hint="${HOME}/.gemini/antigravity-cli/brain/${conv_id}/.system_generated/logs/transcript.jsonl"
    resume_cmd="cd '${wt_dir}' && '${AGY_BIN}' --conversation '${conv_id}'"
  fi

  "$JQ_BIN" -n \
    --argjson number "$issue_num" \
    --arg title "$title" \
    --arg url "$url" \
    --arg state "$issue_state" \
    --arg labels "$labels" \
    --arg repo_root "$REPO_ROOT" \
    --arg branch "$branch" \
    --arg worktree "$wt_dir" \
    --arg model "$AGY_MODEL" \
    --arg conversation_id "$conv_id" \
    --arg pr_url "$pr_url" \
    --arg transcript_hint "$transcript_hint" \
    --arg resume_command "$resume_cmd" \
    --arg status "$run_status" \
    --arg updated_at "$updated_at" \
    '{
      issue_number: $number,
      title: $title,
      url: $url,
      issue_state: $state,
      labels: $labels,
      repo_root: $repo_root,
      branch: $branch,
      worktree: $worktree,
      model: $model,
      conversation_id: $conversation_id,
      pr_url: $pr_url,
      transcript_hint: $transcript_hint,
      resume_command: $resume_command,
      status: $status,
      updated_at: $updated_at
    }' > "$meta_file"
}

post_status_comment() {
  local kind="$1"
  local target_num="$2"
  local status_label="$3"
  local branch="$4"
  local conv_id="$5"
  local pr_url="$6"
  local detail="$7"
  local now_ts
  now_ts="$("$DATE_BIN" --iso-8601=seconds)"

  [[ "$GH_SYNC_ENABLED" == "1" ]] || return 0

  local comment_body
  comment_body="$("$CAT_BIN" <<EOF
### agy 自动开发状态

| 字段 | 值 |
| --- | --- |
| 状态 | \`${LABEL_PREFIX}${status_label}\` |
| 分支 | \`${branch}\` |
| PR | ${pr_url:-"(暂未创建)"} |
| 会话 ID | \`${conv_id:-"(待生成)"}\` |
| 更新时间 | ${now_ts} |

${detail}
EOF
)"
  printf '%s\n' "$comment_body" | gh_state comment "$kind" "$target_num" - || true
}

consecutive_poll_errors=0

while true; do
  # 若启动时初始化标签失败，在网络恢复后补初始化一次
  if [[ "$GH_SYNC_ENABLED" == "1" && "$INIT_LABELS" == "1" && "$LABELS_READY" == "0" ]]; then
    if gh_state init-labels; then
      LABELS_READY=1
    fi
  fi

  # 通过 gh-state.sh 拉取待处理 issue 列表（优先接回评审打回的 changes-requested，再拉取 todo）
  issues_json="[]"
  picked_from_changes_requested=0
  poll_failed=0

  if [[ "$GH_SYNC_ENABLED" == "1" && "$HANDLE_CHANGES_REQUESTED" == "1" ]]; then
    cr_json=""
    if cr_json="$(gh_state list-issues "$ISSUE_STATE" "${LABEL_PREFIX}changes-requested" "$ISSUE_LIMIT")" \
      && "$JQ_BIN" -e 'type == "array"' >/dev/null 2>&1 <<<"$cr_json"; then
      if "$JQ_BIN" -e 'length > 0' >/dev/null 2>&1 <<<"$cr_json"; then
        issues_json="$cr_json"
        picked_from_changes_requested=1
      fi
    else
      poll_failed=1
    fi
  fi

  if (( poll_failed == 0 && picked_from_changes_requested == 0 )); then
    if ! issues_json="$(gh_state list-issues "$ISSUE_STATE" "$FILTER_LABEL" "$ISSUE_LIMIT")" \
      || ! "$JQ_BIN" -e 'type == "array"' >/dev/null 2>&1 <<<"$issues_json"; then
      poll_failed=1
    fi
  fi

  if (( poll_failed == 1 )); then
    consecutive_poll_errors=$((consecutive_poll_errors + 1))
    wait_sec="$(calc_backoff "$consecutive_poll_errors")"
    printf '[%s] 警告：拉取 issue 列表失败（连续第 %d 次），%ss 后重试...\n' \
      "$("$DATE_BIN" '+%F %T')" "$consecutive_poll_errors" "$wait_sec" >&2
    "$SLEEP_BIN" "$wait_sec"
    continue
  fi
  consecutive_poll_errors=0

  # 找出第一个待处理的 issue
  next_issue_json=""
  while IFS= read -r row; do
    num="$("$JQ_BIN" -r '.number' <<<"$row")"
    if (( picked_from_changes_requested == 1 || USE_LOCAL_DEDUP == 0 )) || ! "$GREP_BIN" -qx "$num" "$STATE_FILE"; then
      next_issue_json="$row"
      break
    fi
  done < <("$JQ_BIN" -c '.[]' <<<"$issues_json")

  if [[ -z "$next_issue_json" ]]; then
    printf '[%s] 没有待处理的 issue，%ss 后重试...\n' "$("$DATE_BIN" '+%F %T')" "$POLL_INTERVAL"
    "$SLEEP_BIN" "$POLL_INTERVAL"
    continue
  fi

  # 提取 issue 字段
  number="$("$JQ_BIN" -r '.number' <<<"$next_issue_json")"
  state="$("$JQ_BIN" -r '.state' <<<"$next_issue_json")"
  title="$("$JQ_BIN" -r '.title' <<<"$next_issue_json")"
  url="$("$JQ_BIN" -r '.url' <<<"$next_issue_json")"
  labels="$("$JQ_BIN" -r '([.labels[].name] | join(", ")) // "(none)"' <<<"$next_issue_json")"
  body="$("$JQ_BIN" -r '.body // "(empty)"' <<<"$next_issue_json")"

  branch="${BRANCH_PREFIX}${number}"
  session_dir="${SESSIONS_ROOT}/issue-${number}"
  "$MKDIR_BIN" -p "$session_dir"

  run_ts="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
  iso_now="$("$DATE_BIN" --iso-8601=seconds)"
  prompt_file="${session_dir}/prompt.md"
  run_prompt_file="${session_dir}/prompt-${run_ts}.md"
  summary_file="${session_dir}/summary.md"
  blocked_file="${session_dir}/blocked.md"
  commit_msg_file="${session_dir}/commit-message.txt"
  # 沙箱内 agy 默认可写 /tmp 与当前 worktree；元信息文件写到 /tmp 避免污染 worktree 的 git status
  summary_tmp="/tmp/agy-summary-${REPO_SLUG}-${number}-${run_ts}.md"
  blocked_tmp="/tmp/agy-blocked-${REPO_SLUG}-${number}-${run_ts}.md"
  commit_msg_tmp="/tmp/agy-commit-msg-${REPO_SLUG}-${number}-${run_ts}.txt"
  pr_body_file="${session_dir}/pr-body.md"
  events_file="${session_dir}/events.jsonl"
  run_events_file="${session_dir}/events-${run_ts}.jsonl"
  cli_log_file="${session_dir}/agy-cli-${run_ts}.log"
  conv_id_file="${session_dir}/conversation_id"
  meta_file="${session_dir}/meta.json"

  # 清空上一轮的缓存，避免误复用旧状态
  : > "$summary_file"
  : > "$blocked_file"
  : > "$commit_msg_file"
  : > "$summary_tmp"
  : > "$blocked_tmp"
  : > "$commit_msg_tmp"

  base_ref="$(resolve_base_ref)"
  pr_base_branch="$(strip_origin_prefix "$base_ref")"

  printf '[%s] 准备 Issue #%s 的独立 worktree (base=%s)...\n' "$("$DATE_BIN" '+%F %T')" "$number" "$base_ref"
  if ! wt_dir="$(ensure_worktree "$number" "$base_ref")"; then
    printf '[%s] 警告：为 Issue #%s 准备 worktree 失败，%ss 后重试...\n' \
      "$("$DATE_BIN" '+%F %T')" "$number" "$POLL_INTERVAL" >&2
    "$SLEEP_BIN" "$POLL_INTERVAL"
    continue
  fi

  # 读取已有会话 ID（若存在则自动续接）
  existing_conv_id=""
  if [[ -s "$conv_id_file" ]]; then
    IFS= read -r existing_conv_id < "$conv_id_file" || true
  fi

  # 1. 认领 Issue：将远端状态切为 in-progress 并更新置顶评论
  if [[ "$GH_SYNC_ENABLED" == "1" ]]; then
    if ! gh_state set-state issue "$number" in-progress; then
      printf '[%s] 警告：认领 Issue #%s（切换 in-progress）失败，%ss 后重试...\n' \
        "$("$DATE_BIN" '+%F %T')" "$number" "$POLL_INTERVAL" >&2
      "$SLEEP_BIN" "$POLL_INTERVAL"
      continue
    fi
    post_status_comment issue "$number" "in-progress" "$branch" "$existing_conv_id" "" \
      "Agent 已认领该 Issue，正在独立 worktree 中分析与开发。"
  fi

  # 若本轮是评审打回（changes-requested），拉取最新 Codex 评审意见注入 prompt
  review_feedback_section=""
  if (( picked_from_changes_requested == 1 )) && [[ "$GH_SYNC_ENABLED" == "1" ]]; then
    review_feedback="$(gh_state get-comment issue "$number" "$REVIEW_COMMENT_MARKER" 2>/dev/null || true)"
    if [[ -n "$review_feedback" ]]; then
      review_feedback_section=$'\n\n'"### 独立评审反馈（请优先逐项修复以下阻塞问题）"$'\n'"${review_feedback}"
    fi
  fi

  prompt="$("$CAT_BIN" <<EOF
请处理以下 GitHub Issue：

- 编号: #${number}
- 链接: ${url}
- 状态: ${state}
- 标签: ${labels}
- 标题: ${title}
- 工作分支: ${branch}
- Worktree 目录: ${wt_dir}

### Issue 内容
${body}${review_feedback_section}

### 处理要求
1. 你当前运行在专属 git worktree（分支 ${branch}）的沙箱中，先阅读相关代码并分析问题根因或需求范围。
2. 仅完成开发实现和相关内部验证（如类型检查、构建检查、改动相关的单元测试或模块级测试）。
3. **不需要执行 E2E（端到端）验证**（例如浏览器自动化 E2E、启动完整外部依赖服务或全链路集成环境测试）；不要在 E2E 环境准备上耗费时间。
4. **不要执行 git add / git commit / git push，也不要修改 GitHub Issue/PR 状态**：沙箱内 .git 为只读，代码提交、推送与 PR 创建全部由外层宿主机脚本自动完成。
5. 正常完成开发与内部验证后：
   - 将本次改动的简明中文总结（改动文件、已执行的内部验证结果、显式标注 E2E 未执行，以及潜在风险）写入 ${summary_tmp}；
   - 可选：将一行简明的英文/中文 commit message 写入 ${commit_msg_tmp}。
6. **如果工作遇到阻塞无法继续**（例如需求不明确、缺少必要凭证/依赖、内部验证无法通过且无法在当前范围内修复）：
   - 立即停止修改，不要强行凑合；
   - 将具体的阻塞原因与需要人工提供的信息写入 ${blocked_tmp}（外层脚本会据此停止推进并自动更新 Issue/PR 为 blocked 状态）。
7. 不要把 /tmp 下的总结或状态文件复制到仓库目录中。
EOF
)"

  printf '%s\n' "$prompt" > "$prompt_file"
  printf '%s\n' "$prompt" > "$run_prompt_file"

  write_session_meta "$meta_file" "$number" "$title" "$url" "$state" "$labels" \
    "$branch" "$wt_dir" "$existing_conv_id" "" "in-progress" "$iso_now"

  agy_args=(
    -p "$prompt"
    --mode "$AGY_MODE"
    --sandbox
    --print-timeout "$PRINT_TIMEOUT"
    --output-format stream-json
    --log-file "$cli_log_file"
  )
  if [[ "$AGY_SKIP_PERMISSIONS" == "1" ]]; then
    agy_args+=(--dangerously-skip-permissions)
  fi
  if [[ -n "$AGY_MODEL" ]]; then
    agy_args+=(--model "$AGY_MODEL")
  fi
  if [[ -n "$existing_conv_id" ]]; then
    agy_args=(--conversation "$existing_conv_id" "${agy_args[@]}")
    printf '[%s] 续接 Issue #%s 历史会话 (%s)，worktree: %s\n' \
      "$("$DATE_BIN" '+%F %T')" "$number" "$existing_conv_id" "$wt_dir"
  else
    printf '[%s] 启动 Issue #%s 新会话，worktree: %s\n' \
      "$("$DATE_BIN" '+%F %T')" "$number" "$wt_dir"
  fi

  # 2. 在独立 worktree 内执行 agy，保留完整会话事件流
  run_ok=0
  if (cd -- "$wt_dir" && "$AGY_BIN" "${agy_args[@]}") | "$TEE_BIN" "$run_events_file" >> "$events_file"; then
    run_ok=1
  fi

  # 提取并持久化 conversation_id
  new_conv_id="$(extract_conversation_id "$run_events_file")"
  final_conv_id="${new_conv_id:-$existing_conv_id}"
  if [[ -n "$final_conv_id" ]]; then
    printf '%s\n' "$final_conv_id" > "$conv_id_file"
  fi

  summary_text=""
  if [[ -s "$summary_tmp" ]]; then
    "$CAT_BIN" "$summary_tmp" > "$summary_file"
    summary_text="$("$CAT_BIN" "$summary_file")"
  fi

  blocked_reason=""
  if [[ -s "$blocked_tmp" ]]; then
    "$CAT_BIN" "$blocked_tmp" > "$blocked_file"
    blocked_reason="$("$CAT_BIN" "$blocked_file")"
  fi

  commit_msg=""
  if [[ -s "$commit_msg_tmp" ]]; then
    "$CAT_BIN" "$commit_msg_tmp" > "$commit_msg_file"
    IFS= read -r commit_msg < "$commit_msg_file" || true
  fi
  [[ -z "$commit_msg" ]] && commit_msg="fix(#${number}): ${title}"

  # 3. 根据执行结果：阻塞则立即停止并更新 Issue/PR；正常则由宿主机自动 commit -> push -> Draft PR
  pr_url=""
  existing_pr_num=""
  existing_pr_url=""
  if [[ "$GH_SYNC_ENABLED" == "1" ]]; then
    pr_lookup="$(gh_state find-pr "$branch" 2>/dev/null || true)"
    if [[ -n "$pr_lookup" ]]; then
      existing_pr_num="${pr_lookup%%$'\t'*}"
      existing_pr_url="${pr_lookup#*$'\t'}"
      pr_url="$existing_pr_url"
    fi
  fi

  final_status="blocked"
  status_detail=""

  if (( run_ok == 0 )); then
    final_status="blocked"
    status_detail="Agent 执行异常退出，已停止推进并保留 worktree 与会话记录；排查或补充信息后将标签改回 \`${LABEL_PREFIX}todo\` 可自动续接原会话。${blocked_reason:+$'\n\n'"### 阻塞原因"$'\n'"${blocked_reason}"}${summary_text:+$'\n\n'"### 摘要"$'\n'"${summary_text}"}"
  elif [[ -n "$blocked_reason" ]]; then
    final_status="blocked"
    status_detail="Agent 报告工作阻塞并已主动停止，未自动提交或推送。补充信息后将标签改回 \`${LABEL_PREFIX}todo\` 可自动续接原会话。"$'\n\n'"### 阻塞原因"$'\n'"${blocked_reason}${summary_text:+$'\n\n'"### 摘要"$'\n'"${summary_text}"}"
  else
    # 正常完成：若 worktree 有文件改动，由宿主机自动暂存并提交到当前分支
    dirty_files="$("$GIT_BIN" -C "$wt_dir" status --porcelain 2>/dev/null || true)"
    commit_ok=1
    if [[ -n "$dirty_files" ]]; then
      if ! "$GIT_BIN" -C "$wt_dir" add -A >&2 || ! "$GIT_BIN" -C "$wt_dir" commit -m "$commit_msg" >&2; then
        commit_ok=0
      fi
    fi

    if (( commit_ok == 0 )); then
      final_status="blocked"
      status_detail="Agent 已修改代码，但宿主机自动 \`git commit\` 失败（请检查 git user.name/email 或 pre-commit hook），已停止推送。${summary_text:+$'\n\n'"### 摘要"$'\n'"${summary_text}"}"
    else
      commits_ahead="$("$GIT_BIN" -C "$wt_dir" rev-list --count "${base_ref}..HEAD" 2>/dev/null || printf '0')"
      if (( commits_ahead > 0 )); then
        if [[ "$GH_SYNC_ENABLED" == "1" && "$AUTO_PUSH_PR" == "1" ]]; then
          push_ok=0
          if [[ "$DRY_RUN" == "1" ]]; then
            printf '[DRY_RUN] %s -C %q push -u origin %q\n' "$GIT_BIN" "$wt_dir" "$branch" >&2
            push_ok=1
          elif "$GIT_BIN" -C "$wt_dir" push -u origin "$branch" >&2; then
            push_ok=1
          fi

          if (( push_ok == 1 )); then
            "$CAT_BIN" > "$pr_body_file" <<EOF
## Summary

${summary_text:-"Automated changes for issue #${number}."}

## Metadata
- Issue: #${number}
- Branch: \`${branch}\`
- Conversation ID: \`${final_conv_id:-"(none)"}\`
- Verification Scope: 仅完成开发实现与内部验证（未执行 E2E 验证）

Closes #${number}
EOF
            pr_title="fix(#${number}): ${title}"
            if pr_url="$(gh_state ensure-pr "$number" "$branch" "$pr_base_branch" "$pr_title" "$pr_body_file")"; then
              final_status="in-review"
              status_detail="已完成开发实现与内部验证，并自动提交推送、创建/更新 Draft PR（${commits_ahead} 个提交），等待人工 Review。${summary_text:+$'\n\n'"### 摘要"$'\n'"${summary_text}"}"
            else
              final_status="blocked"
              status_detail="分支 \`${branch}\` 已推送，但创建/更新 Draft PR 失败，请人工检查。"
            fi
          else
            final_status="blocked"
            status_detail="本地已自动生成 ${commits_ahead} 个提交，但 \`git push origin ${branch}\` 失败，请人工检查权限或远端冲突。"
          fi
        else
          final_status="in-review"
          status_detail="本地 worktree 已自动生成 ${commits_ahead} 个提交（未启用自动推送/建 PR）。${summary_text:+$'\n\n'"### 摘要"$'\n'"${summary_text}"}"
        fi
      else
        final_status="blocked"
        status_detail="Agent 执行结束但未产生任何代码改动或新提交，已停止建 PR；请人工确认后将标签改回 \`${LABEL_PREFIX}todo\`。${summary_text:+$'\n\n'"### 摘要"$'\n'"${summary_text}"}"
      fi
    fi
  fi

  finish_iso="$("$DATE_BIN" --iso-8601=seconds)"
  if [[ "$GH_SYNC_ENABLED" == "1" ]]; then
    gh_state set-state issue "$number" "$final_status" || true
    post_status_comment issue "$number" "$final_status" "$branch" "$final_conv_id" "$pr_url" "$status_detail"
    # 若阻塞且该分支已有对应 open PR，同步将 PR 标记为 blocked 并更新 PR 评论
    if [[ "$final_status" == "blocked" && -n "$existing_pr_num" ]]; then
      gh_state set-state pr "$existing_pr_num" blocked || true
      post_status_comment pr "$existing_pr_num" blocked "$branch" "$final_conv_id" "$existing_pr_url" "$status_detail"
    fi
  fi

  if [[ "$final_status" == "in-review" ]]; then
    if ! "$GREP_BIN" -qx "$number" "$STATE_FILE"; then
      printf '%s\n' "$number" >> "$STATE_FILE"
    fi
  fi

  write_session_meta "$meta_file" "$number" "$title" "$url" "$state" "$labels" \
    "$branch" "$wt_dir" "$final_conv_id" "$pr_url" "$final_status" "$finish_iso"

  printf '[%s] Issue #%s 本轮结束 -> 状态: %s\n' "$("$DATE_BIN" '+%F %T')" "$number" "$final_status"
  printf '  Worktree : %s (分支 %s)\n' "$wt_dir" "$branch"
  [[ -n "$pr_url" ]] && printf '  Draft PR : %s\n' "$pr_url"
  printf '  会话记录 : %s\n' "$session_dir"
  if [[ -n "$final_conv_id" ]]; then
    printf '  人工接管 : cd %q && %q --conversation %q\n' "$wt_dir" "$AGY_BIN" "$final_conv_id"
  fi

  "$SLEEP_BIN" 5
done
