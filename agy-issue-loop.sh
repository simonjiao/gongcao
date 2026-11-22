#!/usr/bin/bash
set -euo pipefail

# 获取脚本所在目录并执行前置依赖检查
SCRIPT_DIR="$(cd -- "$([[ "${BASH_SOURCE[0]}" == */* ]] && printf '%s' "${BASH_SOURCE[0]%/*}" || printf '.')" && pwd)"
"${SCRIPT_DIR}/check-deps.sh"

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
BASE_BRANCH="${BASE_BRANCH:-}"         # 创建 worktree 的基准分支，留空自动探测 origin/HEAD 或当前 HEAD
BRANCH_PREFIX="${BRANCH_PREFIX:-agy/issue-}"
GIT_FETCH="${GIT_FETCH:-1}"            # 创建新 worktree 前是否尝试 git fetch origin（1=是，0=否）
ISSUE_STATE="${ISSUE_STATE:-open}"     # open | closed | all
FILTER_LABEL="${FILTER_LABEL:-}"       # 可选：只拉取带指定标签的 issue，如 "ready"
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

printf '[%s] 启动 agy-issue-loop\n' "$("$DATE_BIN" '+%F %T')"
printf '  主仓库目录 : %s\n' "$REPO_ROOT"
printf '  Worktree 根: %s\n' "$WORKTREE_ROOT"
printf '  会话记录根 : %s\n' "$SESSIONS_ROOT"
printf '  状态文件   : %s\n' "$STATE_FILE"

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

ensure_worktree() {
  local issue_num="$1"
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
    local base_ref
    base_ref="$(resolve_base_ref)"
    "$GIT_BIN" -C "$REPO_ROOT" worktree add -b "$branch" "$wt_dir" "$base_ref" >&2
  fi

  printf '%s' "$wt_dir"
}

extract_conversation_id() {
  local events_file="$1"
  local id=""
  # 从 NDJSON 事件流中提取最后一个非空 conversation_id / session_id
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
  local run_status="${10}"
  local updated_at="${11}"

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
      transcript_hint: $transcript_hint,
      resume_command: $resume_command,
      status: $status,
      updated_at: $updated_at
    }' > "$meta_file"
}

gh_args=(issue list --state "$ISSUE_STATE" --limit 20 --json number,title,body,labels,state,url)
[[ -n "$REPO" ]] && gh_args+=(--repo "$REPO")
[[ -n "$FILTER_LABEL" ]] && gh_args+=(--label "$FILTER_LABEL")

while true; do
  # 在主仓库目录下拉取 issue 列表（确保未指定 REPO 时 gh 能识别正确仓库）
  issues_json="$(cd -- "$REPO_ROOT" && "$GH_BIN" "${gh_args[@]}")"

  # 找出第一个尚未处理过的 issue 编号
  next_issue_json=""
  while IFS= read -r row; do
    num="$("$JQ_BIN" -r '.number' <<<"$row")"
    if ! "$GREP_BIN" -qx "$num" "$STATE_FILE"; then
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
  events_file="${session_dir}/events.jsonl"
  run_events_file="${session_dir}/events-${run_ts}.jsonl"
  cli_log_file="${session_dir}/agy-cli-${run_ts}.log"
  conv_id_file="${session_dir}/conversation_id"
  meta_file="${session_dir}/meta.json"

  printf '[%s] 准备 Issue #%s 的独立 worktree...\n' "$("$DATE_BIN" '+%F %T')" "$number"
  wt_dir="$(ensure_worktree "$number")"

  # 如果该 issue 已有历史 conversation_id，自动续接原会话
  existing_conv_id=""
  if [[ -s "$conv_id_file" ]]; then
    IFS= read -r existing_conv_id < "$conv_id_file" || true
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
3. 最后总结改动文件、验证结果与未覆盖风险；如果被阻塞，明确说明原因。
EOF
)"

  printf '%s\n' "$prompt" > "$prompt_file"
  printf '%s\n' "$prompt" > "$run_prompt_file"

  write_session_meta "$meta_file" "$number" "$title" "$url" "$state" "$labels" \
    "$branch" "$wt_dir" "$existing_conv_id" "running" "$iso_now"

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

  # 在独立 worktree 内执行 agy，同时保存单次事件流并追加到总会话记录 events.jsonl
  run_ok=0
  if (cd -- "$wt_dir" && "$AGY_BIN" "${agy_args[@]}") | "$TEE_BIN" "$run_events_file" >> "$events_file"; then
    run_ok=1
  fi

  # 提取并持久化 conversation_id（供下次自动续跑或人工接管）
  new_conv_id="$(extract_conversation_id "$run_events_file")"
  final_conv_id="${new_conv_id:-$existing_conv_id}"
  if [[ -n "$final_conv_id" ]]; then
    printf '%s\n' "$final_conv_id" > "$conv_id_file"
  fi

  finish_iso="$("$DATE_BIN" --iso-8601=seconds)"
  if (( run_ok == 1 )); then
    printf '%s\n' "$number" >> "$STATE_FILE"
    write_session_meta "$meta_file" "$number" "$title" "$url" "$state" "$labels" \
      "$branch" "$wt_dir" "$final_conv_id" "completed" "$finish_iso"
    printf '[%s] Issue #%s 处理完成\n' "$("$DATE_BIN" '+%F %T')" "$number"
    printf '  Worktree : %s (分支 %s)\n' "$wt_dir" "$branch"
    printf '  会话记录 : %s\n' "$session_dir"
    if [[ -n "$final_conv_id" ]]; then
      printf '  人工接管 : cd %q && %q --conversation %q\n' "$wt_dir" "$AGY_BIN" "$final_conv_id"
    fi

    # 可选：如果需要自动在 GitHub 上标记已处理，取消下面注释
    # (cd -- "$REPO_ROOT" && "$GH_BIN" issue edit "$number" ${REPO:+--repo "$REPO"} --add-label "agy-done")
  else
    write_session_meta "$meta_file" "$number" "$title" "$url" "$state" "$labels" \
      "$branch" "$wt_dir" "$final_conv_id" "failed" "$finish_iso"
    printf '[%s] Issue #%s 执行失败（未标记完成，下次可自动续接），会话记录：%s\n' \
      "$("$DATE_BIN" '+%F %T')" "$number" "$session_dir"
  fi

  "$SLEEP_BIN" 5
done
