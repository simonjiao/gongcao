#!/usr/bin/bash
set -euo pipefail

# 独立 Codex PR 评审循环（只读沙箱审查，不调用 agy，不直接调用 gh）
# 监听带 agy:in-review 标签的 PR，结合关联 Issue 要求与 PR diff 进行独立评审，
# 并通过 gh-state.sh 写回评审报告与状态流转（approved / changes-requested / blocked）。

SCRIPT_DIR="$(cd -- "$([[ "${BASH_SOURCE[0]}" == */* ]] && printf '%s' "${BASH_SOURCE[0]%/*}" || printf '.')" && pwd)"
GH_STATE_BIN="${SCRIPT_DIR}/gh-state.sh"

# 解析所需命令的绝对路径（包含 linuxbrew 路径以定位 codex）
SEARCH_PATH="${PATH}:/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin"
resolve_bin() {
  local resolved=""
  resolved="$(PATH="$SEARCH_PATH" type -P "$1" 2>/dev/null || true)"
  if [[ -z "$resolved" || ! -x "$resolved" ]]; then
    printf '错误：缺少必需命令 %s（已搜索：%s）\n' "$1" "$SEARCH_PATH" >&2
    exit 1
  fi
  printf '%s' "$resolved"
}

CODEX_BIN="$(resolve_bin codex)"
JQ_BIN="$(resolve_bin jq)"
GIT_BIN="$(resolve_bin git)"
GREP_BIN="$(resolve_bin grep)"
MKDIR_BIN="$(resolve_bin mkdir)"
TOUCH_BIN="$(resolve_bin touch)"
DATE_BIN="$(resolve_bin date)"
SLEEP_BIN="$(resolve_bin sleep)"
CAT_BIN="$(resolve_bin cat)"
HEAD_BIN="$(resolve_bin head)"

# ===== 主工作目录与可调配置 =====
GONGCAO_HOME="${GONGCAO_HOME:-${HOME}/.gongcao}"
REPOS_ROOT="${REPOS_ROOT:-${GONGCAO_HOME}/repos}"
STATE_BASE="${STATE_BASE:-${GONGCAO_HOME}/state}"

REPO="${REPO:-}"                         # 目标 GitHub 仓库 "owner/repo"
REPO_NAME="${REPO_NAME:-}"               # 可选：~/.gongcao/repos/<REPO_NAME>
REPO_DIR="${REPO_DIR:-}"                 # 可选：显式本地仓库路径
AUTO_CLONE="${AUTO_CLONE:-1}"            # 未克隆时自动只读克隆到 ~/.gongcao/repos/
LABEL_PREFIX="${LABEL_PREFIX:-agy:}"
REVIEW_LABEL="${REVIEW_LABEL:-${LABEL_PREFIX}in-review}"
REVIEW_COMMENT_MARKER="${REVIEW_COMMENT_MARKER:-<!-- codex-review-comment -->}"
CODEX_MODEL="${CODEX_MODEL:-gpt-6.2-sol}" # 默认使用 GPT-6.2-Sol
CODEX_REASONING_EFFORT="${CODEX_REASONING_EFFORT:-xhigh}" # 默认推理强度 xhigh
CODEX_SANDBOX="${CODEX_SANDBOX:-read-only}"
MAX_DIFF_BYTES="${MAX_DIFF_BYTES:-60000}" # 嵌入 prompt 的 diff 最大字节数（超长截断，Codex 可在 worktree 中查完整 diff）
MAX_REVIEW_ROUNDS="${MAX_REVIEW_ROUNDS:-3}" # 最大自动打回评审轮数，超过则切 blocked 交人工裁决
AUTO_REQUEUE_ISSUE="${AUTO_REQUEUE_ISSUE:-1}" # 评审不通过时是否同步将关联 Issue 切为 changes-requested（触发 agy 自动修复）
INIT_LABELS="${INIT_LABELS:-1}"
PR_LIMIT="${PR_LIMIT:-20}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
MAX_BACKOFF="${MAX_BACKOFF:-900}"
DRY_RUN="${DRY_RUN:-0}"

"$MKDIR_BIN" -p "$GONGCAO_HOME" "$REPOS_ROOT" "$STATE_BASE"

# 定位目标仓库目录（与 agy-issue-loop.sh 共用 ~/.gongcao/repos/）
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
REVIEWS_ROOT="${REVIEWS_ROOT:-${STATE_ROOT}/reviews}"

"$MKDIR_BIN" -p "$STATE_ROOT" "$WORKTREE_ROOT" "$REVIEWS_ROOT"

gh_state() {
  GONGCAO_HOME="$GONGCAO_HOME" \
  REPOS_ROOT="$REPOS_ROOT" \
  REPO_DIR="$REPO_ROOT" \
  REPO="$REPO" \
  LABEL_PREFIX="$LABEL_PREFIX" \
  DRY_RUN="$DRY_RUN" \
  "$GH_STATE_BIN" "$@"
}

printf '[%s] 启动 codex-review-loop\n' "$("$DATE_BIN" '+%F %T')"
printf '  Codex 命令 : %s (model=%s, effort=%s, sandbox=%s)\n' \
  "$CODEX_BIN" "${CODEX_MODEL:-(codex 默认)}" "${CODEX_REASONING_EFFORT:-(默认)}" "$CODEX_SANDBOX"
printf '  工作主目录 : %s\n' "$GONGCAO_HOME"
printf '  主仓库目录 : %s\n' "$REPO_ROOT"
printf '  评审档案根 : %s\n' "$REVIEWS_ROOT"
printf '  监听标签   : %s (MAX_REVIEW_ROUNDS=%s, AUTO_REQUEUE_ISSUE=%s, DRY_RUN=%s)\n' \
  "$REVIEW_LABEL" "$MAX_REVIEW_ROUNDS" "$AUTO_REQUEUE_ISSUE" "$DRY_RUN"

LABELS_READY=0
if [[ "$INIT_LABELS" == "1" ]]; then
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

write_review_schema() {
  local schema_file="$1"
  "$CAT_BIN" > "$schema_file" <<'EOF'
{
  "type": "object",
  "additionalProperties": false,
  "required": [
    "verdict",
    "summary",
    "requirements_coverage",
    "blocking_issues",
    "non_blocking_notes"
  ],
  "properties": {
    "verdict": {
      "type": "string",
      "enum": ["approve", "request_changes"]
    },
    "summary": {
      "type": "string"
    },
    "requirements_coverage": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["requirement", "status", "evidence"],
        "properties": {
          "requirement": { "type": "string" },
          "status": { "type": "string", "enum": ["met", "partial", "missing"] },
          "evidence": { "type": "string" }
        }
      }
    },
    "blocking_issues": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["severity", "location", "description", "suggestion"],
        "properties": {
          "severity": { "type": "string", "enum": ["critical", "major"] },
          "location": { "type": "string" },
          "description": { "type": "string" },
          "suggestion": { "type": "string" }
        }
      }
    },
    "non_blocking_notes": {
      "type": "array",
      "items": { "type": "string" }
    }
  }
}
EOF
}

# 从 PR 正文（Closes/Fixes/Resolves #N）或分支名（agy/issue-N）提取关联 Issue 编号
extract_linked_issue() {
  local pr_body="$1"
  local head_branch="$2"
  local num=""

  num="$(printf '%s\n' "$pr_body" | "$GREP_BIN" -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#[0-9]+' | "$HEAD_BIN" -n 1 | "$GREP_BIN" -oE '[0-9]+' || true)"
  if [[ -z "$num" ]]; then
    num="$(printf '%s\n' "$head_branch" | "$GREP_BIN" -oE 'issue-[0-9]+' | "$HEAD_BIN" -n 1 | "$GREP_BIN" -oE '[0-9]+' || true)"
  fi
  printf '%s' "$num"
}

prepare_review_worktree() {
  local pr_num="$1"
  local head_branch="$2"
  local head_sha="$3"
  local wt_dir="${WORKTREE_ROOT}/review-pr-${pr_num}"

  "$GIT_BIN" -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true

  # 拉取 PR 对应分支与远端最新提交
  "$GIT_BIN" -C "$REPO_ROOT" fetch --prune origin >&2 || true
  if ! "$GIT_BIN" -C "$REPO_ROOT" cat-file -e "${head_sha}^{commit}" 2>/dev/null; then
    "$GIT_BIN" -C "$REPO_ROOT" fetch origin "pull/${pr_num}/head" >&2 || \
      "$GIT_BIN" -C "$REPO_ROOT" fetch origin "$head_branch" >&2
  fi

  local target_commit="$head_sha"
  if ! "$GIT_BIN" -C "$REPO_ROOT" cat-file -e "${target_commit}^{commit}" 2>/dev/null; then
    target_commit="FETCH_HEAD"
  fi

  if [[ -e "${wt_dir}/.git" ]]; then
    "$GIT_BIN" -C "$wt_dir" checkout --detach --force "$target_commit" >&2
    "$GIT_BIN" -C "$wt_dir" clean -fd >/dev/null 2>&1 || true
  else
    "$GIT_BIN" -C "$REPO_ROOT" worktree add --detach "$wt_dir" "$target_commit" >&2
  fi

  printf '%s' "$wt_dir"
}

render_review_markdown() {
  local verdict_file="$1"
  local pr_num="$2"
  local issue_num="$3"
  local head_sha="$4"
  local round="$5"
  local final_state="$6"
  local now_ts
  now_ts="$("$DATE_BIN" --iso-8601=seconds)"

  "$JQ_BIN" -r \
    --arg pr "$pr_num" \
    --arg issue "${issue_num:-(未关联)}" \
    --arg sha "${head_sha:0:10}" \
    --arg round "$round" \
    --arg max_rounds "$MAX_REVIEW_ROUNDS" \
    --arg state "${LABEL_PREFIX}${final_state}" \
    --arg model "${CODEX_MODEL:-(codex 默认)}${CODEX_REASONING_EFFORT:+ (${CODEX_REASONING_EFFORT})}" \
    --arg now "$now_ts" \
    '
    def esc: tostring | gsub("\n"; " ") | gsub("\\|"; "\\|");
    "### Codex 独立评审报告\n\n"
    + "| 字段 | 值 |\n| --- | --- |\n"
    + "| 评审结论 | `" + .verdict + "` -> `" + $state + "` |\n"
    + "| 关联 Issue | #" + $issue + " |\n"
    + "| 评审 Commit | `" + $sha + "` |\n"
    + "| 评审轮次 | " + $round + " / " + $max_rounds + " |\n"
    + "| 评审模型 | `" + $model + "` |\n"
    + "| 评审时间 | " + $now + " |\n\n"
    + "#### 总结\n" + .summary + "\n\n"
    + "#### Issue 要求覆盖核查\n"
    + (if (.requirements_coverage | length) > 0 then
        "| 要求 | 状态 | 证据 |\n| --- | --- | --- |\n"
        + ([.requirements_coverage[] | "| " + (.requirement | esc) + " | `" + .status + "` | " + (.evidence | esc) + " |"] | join("\n"))
      else
        "- (无逐项记录)"
      end)
    + "\n\n#### 阻塞问题（Blocking Issues）\n"
    + (if (.blocking_issues | length) > 0 then
        ([.blocking_issues[] | "- **[" + .severity + "]** `" + .location + "`：" + .description + "\n  - 建议：" + .suggestion] | join("\n"))
      else
        "- 无阻塞问题"
      end)
    + "\n\n#### 非阻塞建议（Non-blocking Notes）\n"
    + (if (.non_blocking_notes | length) > 0 then
        ([.non_blocking_notes[] | "- " + .] | join("\n"))
      else
        "- 无"
      end)
    ' "$verdict_file"
}

consecutive_poll_errors=0

while true; do
  if [[ "$INIT_LABELS" == "1" && "$LABELS_READY" == "0" ]]; then
    if gh_state init-labels; then
      LABELS_READY=1
    fi
  fi

  prs_json=""
  if ! prs_json="$(gh_state list-prs open "$REVIEW_LABEL" "$PR_LIMIT")" \
    || ! "$JQ_BIN" -e 'type == "array"' >/dev/null 2>&1 <<<"$prs_json"; then
    consecutive_poll_errors=$((consecutive_poll_errors + 1))
    wait_sec="$(calc_backoff "$consecutive_poll_errors")"
    printf '[%s] 警告：拉取待评审 PR 列表失败（连续第 %d 次），%ss 后重试...\n' \
      "$("$DATE_BIN" '+%F %T')" "$consecutive_poll_errors" "$wait_sec" >&2
    "$SLEEP_BIN" "$wait_sec"
    continue
  fi
  consecutive_poll_errors=0

  # 找出第一条最新 head_sha 尚未评审过的 PR
  next_pr_json=""
  while IFS= read -r row; do
    pnum="$("$JQ_BIN" -r '.number' <<<"$row")"
    psha="$("$JQ_BIN" -r '.headRefOid // empty' <<<"$row")"
    sha_file="${REVIEWS_ROOT}/pr-${pnum}/reviewed_shas.txt"
    if [[ -n "$psha" && -f "$sha_file" ]] && "$GREP_BIN" -qx "$psha" "$sha_file"; then
      continue
    fi
    next_pr_json="$row"
    break
  done < <("$JQ_BIN" -c '.[]' <<<"$prs_json")

  if [[ -z "$next_pr_json" ]]; then
    printf '[%s] 没有待 Codex 评审的 PR，%ss 后重试...\n' "$("$DATE_BIN" '+%F %T')" "$POLL_INTERVAL"
    "$SLEEP_BIN" "$POLL_INTERVAL"
    continue
  fi

  pr_num="$("$JQ_BIN" -r '.number' <<<"$next_pr_json")"
  pr_title="$("$JQ_BIN" -r '.title' <<<"$next_pr_json")"
  pr_body="$("$JQ_BIN" -r '.body // ""' <<<"$next_pr_json")"
  pr_url="$("$JQ_BIN" -r '.url' <<<"$next_pr_json")"
  head_branch="$("$JQ_BIN" -r '.headRefName' <<<"$next_pr_json")"
  base_branch="$("$JQ_BIN" -r '.baseRefName' <<<"$next_pr_json")"
  head_sha="$("$JQ_BIN" -r '.headRefOid' <<<"$next_pr_json")"

  review_dir="${REVIEWS_ROOT}/pr-${pr_num}"
  "$MKDIR_BIN" -p "$review_dir"
  sha_file="${review_dir}/reviewed_shas.txt"
  "$TOUCH_BIN" "$sha_file"

  prev_rounds=0
  while IFS= read -r _line; do
    [[ -n "$_line" ]] && prev_rounds=$((prev_rounds + 1))
  done < "$sha_file"
  current_round=$((prev_rounds + 1))

  run_ts="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
  schema_file="${review_dir}/schema.json"
  prompt_file="${review_dir}/prompt-${run_ts}.md"
  events_file="${review_dir}/events-${run_ts}.jsonl"
  verdict_file="${review_dir}/verdict-${run_ts}.json"
  comment_file="${review_dir}/review-comment.md"
  meta_file="${review_dir}/meta.json"
  write_review_schema "$schema_file"

  # 查找关联 Issue 原文
  issue_num="$(extract_linked_issue "$pr_body" "$head_branch")"
  issue_section="（未识别到关联 Issue，请根据 PR 描述与代码变更进行评审）"
  if [[ -n "$issue_num" ]]; then
    if issue_json="$(gh_state get-issue "$issue_num" 2>/dev/null)"; then
      issue_title="$("$JQ_BIN" -r '.title // ""' <<<"$issue_json")"
      issue_body="$("$JQ_BIN" -r '.body // "(empty)"' <<<"$issue_json")"
      issue_labels="$("$JQ_BIN" -r '([.labels[]?.name] | join(", ")) // "(none)"' <<<"$issue_json")"
      issue_url="$("$JQ_BIN" -r '.url // ""' <<<"$issue_json")"
      issue_section="$("$CAT_BIN" <<EOF
- Issue: #${issue_num} (${issue_url})
- 标题: ${issue_title}
- 标签: ${issue_labels}

#### Issue 原始需求与验收标准
${issue_body}
EOF
)"
    fi
  fi

  printf '[%s] 开始 Codex 独立评审 PR #%s (Issue #%s, sha=%s, 第 %d/%d 轮)...\n' \
    "$("$DATE_BIN" '+%F %T')" "$pr_num" "${issue_num:-?}" "${head_sha:0:10}" "$current_round" "$MAX_REVIEW_ROUNDS"

  if ! review_wt="$(prepare_review_worktree "$pr_num" "$head_branch" "$head_sha")"; then
    printf '[%s] 警告：为 PR #%s 准备只读 worktree 失败，%ss 后重试...\n' \
      "$("$DATE_BIN" '+%F %T')" "$pr_num" "$POLL_INTERVAL" >&2
    "$SLEEP_BIN" "$POLL_INTERVAL"
    continue
  fi

  pr_diff_raw="$(gh_state get-pr-diff "$pr_num" 2>/dev/null || true)"
  pr_diff_snippet="$(printf '%s' "$pr_diff_raw" | "$HEAD_BIN" -c "$MAX_DIFF_BYTES")"
  if (( ${#pr_diff_raw} > MAX_DIFF_BYTES )); then
    pr_diff_snippet="${pr_diff_snippet}"$'\n\n'"... (diff 已截断，请在当前只读工作区使用 git diff origin/${base_branch}...HEAD 查看完整变更)"
  fi

  # 若为第 2 轮及以上复审，自动带入上一轮的阻塞问题清单以约束复审收敛
  prev_review_section=""
  if (( current_round >= 2 )); then
    prev_verdict_file="${review_dir}/last_verdict.json"
    if [[ ! -s "$prev_verdict_file" ]]; then
      prev_verdict_file=""
      for _vf in "${review_dir}"/verdict-*.json; do
        [[ -s "$_vf" ]] && prev_verdict_file="$_vf"
      done
    fi
    if [[ -n "$prev_verdict_file" && -s "$prev_verdict_file" ]]; then
      prev_blocking="$("$JQ_BIN" -r '
        if (.blocking_issues | length) > 0 then
          [.blocking_issues[] | "- [" + .severity + "] `" + .location + "`：" + .description + "（原建议：" + .suggestion + "）"] | join("\n")
        else
          "- (上一轮无阻塞项)"
        end
      ' "$prev_verdict_file" 2>/dev/null || true)"
      if [[ -n "$prev_blocking" ]]; then
        prev_review_section=$'\n\n'"## 上一轮阻塞问题清单（本轮重点核验收敛）"$'\n'"${prev_blocking}"
      fi
    fi
  fi

  "$CAT_BIN" > "$prompt_file" <<EOF
你是一名独立、严谨的代码评审者（Independent Reviewer）。请严格依据原始 Issue 要求，评审以下 Pull Request 的实际代码变更。

## PR 信息
- PR: #${pr_num} (${pr_url})
- 标题: ${pr_title}
- 分支: \`${head_branch}\` -> \`${base_branch}\`
- 最新 Commit: \`${head_sha}\`
- 评审轮次: 第 ${current_round} / ${MAX_REVIEW_ROUNDS} 轮

### PR 描述
${pr_body:-"(empty)"}

## 关联 Issue 要求
${issue_section}${prev_review_section}

## PR Diff 摘录
\`\`\`diff
${pr_diff_snippet:-"(空 diff)"}
\`\`\`

## 评审准则（务必遵守）
1. 当前工作目录是 PR 最新提交（\`${head_sha}\`）的只读检出，请按需阅读完整源文件、调用点与相关单元测试以核实证据，不要轻信 PR 描述中的自我声明。
2. 逐项核对原始 Issue 需求是否完整实现，重点检查：正确性、边界条件、方言/兼容性、安全与并发隐患、回归风险、以及是否补充了合理的内部单元测试。
3. **关于 E2E 验证**：本工作流明确约定开发阶段仅做内部验证（构建/类型检查/单元测试），**不要因为“未执行 E2E 测试”而给出 request_changes**；若需提示人工验收点，可写在 \`non_blocking_notes\` 中。
4. **严格区分阻塞项与范围外建议（禁止范围蔓延）**：
   - 仅将「违反原始 Issue 明确验收标准、或本次 PR 改动新引入的实质性正确性/安全/回归 bug、或缺少关键内部单测」列入 \`blocking_issues\` 并返回 \`request_changes\`。
   - **凡超出原始 Issue 范围的延伸需求、次要/极端边缘的 UI 展示优化、仓库历史既有问题或轻微风格建议**，如果认为有参考价值，**一律放入 \`non_blocking_notes\`（作为非阻塞项记录）**，不得借此阻塞通过。
5. **复审收敛规则（第 2 轮及以上）**：重点核验上一轮列出的阻塞问题是否已修复，以及本次修订是否引入新的实质性回归；不要在复审轮次不断追加与原始 Issue 无关的新要求。
6. 最终输出必须严格符合提供的 JSON Schema，使用简洁清晰的中文表述。
EOF

  codex_args=(
    exec
    -s "$CODEX_SANDBOX"
    -C "$review_wt"
    --output-schema "$schema_file"
    -o "$verdict_file"
    --json
    --color never
  )
  if [[ -n "$CODEX_MODEL" ]]; then
    codex_args+=(-m "$CODEX_MODEL")
  fi
  if [[ -n "$CODEX_REASONING_EFFORT" ]]; then
    codex_args+=(-c "model_reasoning_effort=\"${CODEX_REASONING_EFFORT}\"")
  fi
  codex_args+=(-)

  codex_ok=0
  if "$CODEX_BIN" "${codex_args[@]}" < "$prompt_file" > "$events_file"; then
    if [[ -s "$verdict_file" ]] && "$JQ_BIN" -e '.verdict == "approve" or .verdict == "request_changes"' "$verdict_file" >/dev/null 2>&1; then
      codex_ok=1
    fi
  fi

  if (( codex_ok == 0 )); then
    printf '[%s] 警告：Codex 评审 PR #%s 失败或输出不符合 Schema（未记录该 SHA，日志：%s），%ss 后重试...\n' \
      "$("$DATE_BIN" '+%F %T')" "$pr_num" "$events_file" "$POLL_INTERVAL" >&2
    "$SLEEP_BIN" "$POLL_INTERVAL"
    continue
  fi

  verdict="$("$JQ_BIN" -r '.verdict' "$verdict_file")"
  "$CAT_BIN" "$verdict_file" > "${review_dir}/last_verdict.json"
  final_pr_state=""
  extra_notice=""

  if [[ "$verdict" == "approve" ]]; then
    final_pr_state="approved"
  else
    if (( current_round >= MAX_REVIEW_ROUNDS )); then
      final_pr_state="blocked"
      extra_notice=$'\n\n'"> ⚠️ 已达到最大自动评审打回轮次（${MAX_REVIEW_ROUNDS} 轮），状态已切为 \`${LABEL_PREFIX}blocked\`，请人工介入裁决。"
    else
      final_pr_state="changes-requested"
    fi
  fi

  review_md="$(render_review_markdown "$verdict_file" "$pr_num" "$issue_num" "$head_sha" "$current_round" "$final_pr_state")${extra_notice}"
  printf '%s\n' "$review_md" > "$comment_file"

  # 写回 PR 评审评论与状态
  printf '%s\n' "$review_md" | gh_state comment pr "$pr_num" - "$REVIEW_COMMENT_MARKER" || true
  gh_state set-state pr "$pr_num" "$final_pr_state" || true

  # 同步关联 Issue 状态
  if [[ -n "$issue_num" ]]; then
    if [[ "$final_pr_state" == "approved" ]]; then
      gh_state set-state issue "$issue_num" approved || true
      printf '%s\n' "$review_md" | gh_state comment issue "$issue_num" - "$REVIEW_COMMENT_MARKER" || true
    elif [[ "$final_pr_state" == "blocked" ]]; then
      gh_state set-state issue "$issue_num" blocked || true
      printf '%s\n' "$review_md" | gh_state comment issue "$issue_num" - "$REVIEW_COMMENT_MARKER" || true
    elif [[ "$final_pr_state" == "changes-requested" && "$AUTO_REQUEUE_ISSUE" == "1" ]]; then
      gh_state set-state issue "$issue_num" changes-requested || true
      printf '%s\n' "$review_md" | gh_state comment issue "$issue_num" - "$REVIEW_COMMENT_MARKER" || true
    fi
  fi

  # 记录已评审的 head_sha（DRY_RUN=0 时记录，防止同 SHA 重复评审）
  if [[ "$DRY_RUN" != "1" ]]; then
    printf '%s\n' "$head_sha" >> "$sha_file"
  fi

  iso_now="$("$DATE_BIN" --iso-8601=seconds)"
  "$JQ_BIN" -n \
    --argjson pr_number "$pr_num" \
    --arg issue_number "$issue_num" \
    --arg pr_url "$pr_url" \
    --arg head_branch "$head_branch" \
    --arg base_branch "$base_branch" \
    --arg head_sha "$head_sha" \
    --arg model "$CODEX_MODEL" \
    --arg reasoning_effort "$CODEX_REASONING_EFFORT" \
    --argjson round "$current_round" \
    --arg verdict "$verdict" \
    --arg final_state "$final_pr_state" \
    --arg updated_at "$iso_now" \
    '{
      pr_number: $pr_number,
      issue_number: $issue_number,
      pr_url: $pr_url,
      head_branch: $head_branch,
      base_branch: $base_branch,
      head_sha: $head_sha,
      model: $model,
      reasoning_effort: $reasoning_effort,
      round: $round,
      verdict: $verdict,
      final_state: $final_state,
      updated_at: $updated_at
    }' > "$meta_file"

  printf '[%s] PR #%s 评审完成 -> verdict=%s, state=%s%s (报告：%s)\n' \
    "$("$DATE_BIN" '+%F %T')" "$pr_num" "$verdict" "$LABEL_PREFIX" "$final_pr_state" "$comment_file"

  "$SLEEP_BIN" 5
done
