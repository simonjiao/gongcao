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

GH_BIN="$(resolve_bin gh)"
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

# ===== 可调配置 =====
REPO_DIR="${REPO_DIR:-$(pwd)}"         # 目标开发仓库路径（默认当前目录）
REPO="${REPO:-}"                       # 留空默认从 REPO_DIR 识别 GitHub 仓库，也可填 "owner/repo"
BASE_BRANCH="${BASE_BRANCH:-}"         # 创建 worktree/PR 的基准分支，留空自动探测 origin/HEAD 或当前 HEAD
BRANCH_PREFIX="${BRANCH_PREFIX:-agy/issue-}"
LABEL_PREFIX="${LABEL_PREFIX:-agy:}"
GIT_FETCH="${GIT_FETCH:-1}"            # 创建新 worktree 前是否尝试 git fetch origin（1=是，0=否）
GH_SYNC_ENABLED="${GH_SYNC_ENABLED:-1}" # 是否启用 GitHub 状态机与置顶评论（1=是，0=纯本地模式）
INIT_LABELS="${INIT_LABELS:-1}"        # 启动时是否幂等初始化 agy:* 标签（1=是，0=否）
AUTO_PUSH_PR="${AUTO_PUSH_PR:-1}"      # 有新 commit 时是否自动 push 分支并创建/更新 Draft PR（1=是，0=仅维护 Issue 状态）
DRY_RUN="${DRY_RUN:-0}"                # 1=演练模式（不修改远端 GitHub、不执行 git push）
ISSUE_STATE="${ISSUE_STATE:-open}"     # open | closed | all
# 启用 GitHub 状态机时默认只拉取人工放行的 agy:todo；显式传 FILTER_LABEL="" 可关闭标签过滤
if [[ "$GH_SYNC_ENABLED" == "1" ]]; then
  FILTER_LABEL="${FILTER_LABEL-${LABEL_PREFIX}todo}"
else
  FILTER_LABEL="${FILTER_LABEL-}"
fi
POLL_INTERVAL="${POLL_INTERVAL:-60}"   # 无新 issue 时的轮询间隔（秒）
PRINT_TIMEOUT="${PRINT_TIMEOUT:-15m}"
AGY_MODE="${AGY_MODE:-auto}"           # auto | accept-edits | plan

# 校验目标仓库目录并获取主仓库根目录
if ! REPO_ROOT="$("$GIT_BIN" -C "$REPO_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  printf '错误：REPO_DIR (%s) 不是一个有效的 Git 仓库。\n' "$REPO_DIR" >&2
  exit 1
fi

# 生成仓库标识，用于隔离不同仓库的状态、worktree 和会话记录
if [[ -n "$REPO" ]]; then
  REPO_SLUG="${REPO//\//__}"
else
  REPO_SLUG="${REPO_ROOT##*/}"
fi
REPO_SLUG="${REPO_SLUG//[^a-zA-Z0-9._-]/_}"

# 持久化目录布局（默认在 ~/.local/state/agy-issue-loop/<repo_slug>/）
STATE_ROOT="${STATE_ROOT:-${HOME}/.local/state/agy-issue-loop/${REPO_SLUG}}"
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
  REPO_DIR="$REPO_ROOT" \
  REPO="$REPO" \
  LABEL_PREFIX="$LABEL_PREFIX" \
  DRY_RUN="$DRY_RUN" \
  "$GH_STATE_BIN" "$@"
}

printf '[%s] 启动 agy-issue-loop\n' "$("$DATE_BIN" '+%F %T')"
printf '  主仓库目录 : %s\n' "$REPO_ROOT"
printf '  Worktree 根: %s\n' "$WORKTREE_ROOT"
printf '  会话记录根 : %s\n' "$SESSIONS_ROOT"
printf '  过滤标签   : %s\n' "${FILTER_LABEL:-(无)}"
printf '  GitHub同步 : %s (AUTO_PUSH_PR=%s, DRY_RUN=%s)\n' "$GH_SYNC_ENABLED" "$AUTO_PUSH_PR" "$DRY_RUN"

if [[ "$GH_SYNC_ENABLED" == "1" && "$INIT_LABELS" == "1" ]]; then
  gh_state init-labels
fi

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
      conversation_id: $conversation_id,
      pr_url: $pr_url,
      transcript_hint: $transcript_hint,
      resume_command: $resume_command,
      status: $status,
      updated_at: $updated_at
    }' > "$meta_file"
}

post_status_comment() {
  local issue_num="$1"
  local status_label="$2"
  local branch="$3"
  local conv_id="$4"
  local pr_url="$5"
  local detail="$6"
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
  printf '%s\n' "$comment_body" | gh_state comment issue "$issue_num" - || true
}

gh_args=(issue list --state "$ISSUE_STATE" --limit 20 --json number,title,body,labels,state,url)
[[ -n "$REPO" ]] && gh_args+=(--repo "$REPO")
[[ -n "$FILTER_LABEL" ]] && gh_args+=(--label "$FILTER_LABEL")

while true; do
  # 在主仓库目录下拉取 issue 列表
  issues_json="$(cd -- "$REPO_ROOT" && "$GH_BIN" "${gh_args[@]}")"

  # 找出第一个待处理的 issue
  next_issue_json=""
  while IFS= read -r row; do
    num="$("$JQ_BIN" -r '.number' <<<"$row")"
    if (( USE_LOCAL_DEDUP == 0 )) || ! "$GREP_BIN" -qx "$num" "$STATE_FILE"; then
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
  # 沙箱内 agy 默认可写 /tmp 与当前 worktree；写到 /tmp 避免污染 worktree 的 git status
  summary_tmp="/tmp/agy-summary-${REPO_SLUG}-${number}-${run_ts}.md"
  pr_body_file="${session_dir}/pr-body.md"
  events_file="${session_dir}/events.jsonl"
  run_events_file="${session_dir}/events-${run_ts}.jsonl"
  cli_log_file="${session_dir}/agy-cli-${run_ts}.log"
  conv_id_file="${session_dir}/conversation_id"
  meta_file="${session_dir}/meta.json"

  # 清空上一轮的 summary 缓存，避免误复用旧摘要
  : > "$summary_file"
  : > "$summary_tmp"

  base_ref="$(resolve_base_ref)"
  pr_base_branch="$(strip_origin_prefix "$base_ref")"

  printf '[%s] 准备 Issue #%s 的独立 worktree (base=%s)...\n' "$("$DATE_BIN" '+%F %T')" "$number" "$base_ref"
  wt_dir="$(ensure_worktree "$number" "$base_ref")"

  # 读取已有会话 ID（若存在则自动续接）
  existing_conv_id=""
  if [[ -s "$conv_id_file" ]]; then
    IFS= read -r existing_conv_id < "$conv_id_file" || true
  fi

  # 1. 认领 Issue：将远端状态切为 in-progress 并更新置顶评论
  if [[ "$GH_SYNC_ENABLED" == "1" ]]; then
    gh_state set-state issue "$number" in-progress
    post_status_comment "$number" "in-progress" "$branch" "$existing_conv_id" "" \
      "Agent 已认领该 Issue，正在独立 worktree 中分析与开发。"
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
${body}

### 处理要求
1. 你当前运行在专属 git worktree（分支 ${branch}）中，先阅读相关代码并分析问题根因或需求范围。
2. 给出并实施最小必要改动，运行相关测试验证。
3. 验证通过后，将本次修改提交到当前分支 ${branch}（使用清晰的 commit message，不要执行 git push，也不要修改 GitHub Issue/PR 状态，这些由外层脚本统一处理）。
4. 将本次改动的简明中文总结（改动文件、验证结果、风险或阻塞原因）写入 ${summary_tmp}（不要把总结文件提交到仓库）。
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

  # 3. 根据执行结果与 git 产出，推进 GitHub 状态（推送分支 + 创建/更新 Draft PR）
  pr_url=""
  final_status="blocked"
  status_detail=""

  if (( run_ok == 1 )); then
    commits_ahead="$("$GIT_BIN" -C "$wt_dir" rev-list --count "${base_ref}..HEAD" 2>/dev/null || printf '0')"
    dirty_files="$("$GIT_BIN" -C "$wt_dir" status --porcelain 2>/dev/null || true)"

    if (( commits_ahead > 0 )) && [[ -z "$dirty_files" ]]; then
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

Closes #${number}
EOF
          pr_title="fix(#${number}): ${title}"
          if pr_url="$(gh_state ensure-pr "$number" "$branch" "$pr_base_branch" "$pr_title" "$pr_body_file")"; then
            final_status="in-review"
            status_detail="已完成开发并创建/更新 Draft PR（${commits_ahead} 个提交），等待人工 Review。${summary_text:+$'\n\n'"### 摘要"$'\n'"${summary_text}"}"
          else
            final_status="blocked"
            status_detail="分支 \`${branch}\` 已推送，但创建/更新 Draft PR 失败，请人工检查。"
          fi
        else
          final_status="blocked"
          status_detail="本地已生成 ${commits_ahead} 个提交，但 \`git push origin ${branch}\` 失败，请人工检查权限或远端冲突。"
        fi
      else
        final_status="in-review"
        status_detail="本地 worktree 已生成 ${commits_ahead} 个提交（未启用自动推送/建 PR）。${summary_text:+$'\n\n'"### 摘要"$'\n'"${summary_text}"}"
      fi
    else
      final_status="blocked"
      if [[ -n "$dirty_files" ]]; then
        status_detail="Agent 执行结束但 worktree 存在未提交改动，未自动推送；请人工检查或补充说明后重新打上 \`${LABEL_PREFIX}todo\` 续接。${summary_text:+$'\n\n'"### 摘要"$'\n'"${summary_text}"}"
      else
        status_detail="Agent 执行结束但未在分支 \`${branch}\` 上产生新提交，未自动创建 PR；请人工确认后重新打上 \`${LABEL_PREFIX}todo\`。${summary_text:+$'\n\n'"### 摘要"$'\n'"${summary_text}"}"
      fi
    fi
  else
    final_status="blocked"
    status_detail="Agent 执行异常退出，已保留 worktree 与会话记录；排查或补充信息后将标签改回 \`${LABEL_PREFIX}todo\` 可自动续接原会话。${summary_text:+$'\n\n'"### 摘要"$'\n'"${summary_text}"}"
  fi

  finish_iso="$("$DATE_BIN" --iso-8601=seconds)"
  if [[ "$GH_SYNC_ENABLED" == "1" ]]; then
    gh_state set-state issue "$number" "$final_status" || true
    post_status_comment "$number" "$final_status" "$branch" "$final_conv_id" "$pr_url" "$status_detail"
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
