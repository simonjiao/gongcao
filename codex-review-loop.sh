#!/usr/bin/bash
set -euo pipefail

# 独立 Codex PR 评审循环（只读沙箱审查，不调用 agy，不直接调用 gh）
# 监听带 agy:in-review 标签的 PR，结合关联 Issue 要求与 PR diff 进行独立评审，
# 并通过 gh-state.sh 写回评审报告与状态流转（approved / changes-requested / blocked）。

SCRIPT_DIR="$(cd -- "$([[ "${BASH_SOURCE[0]}" == */* ]] && printf '%s' "${BASH_SOURCE[0]%/*}" || printf '.')" && pwd)"
GH_STATE_BIN="${SCRIPT_DIR}/gh-state.sh"
source "$SCRIPT_DIR/lib/release-handoff.sh"

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
MV_BIN="$(resolve_bin mv)"
RM_BIN="$(resolve_bin rm)"
HEAD_BIN="$(resolve_bin head)"
FIND_BIN="$(resolve_bin find)"
SORT_BIN="$(resolve_bin sort)"
FLOCK_BIN="$(resolve_bin flock)"
TIMEOUT_BIN="$(resolve_bin timeout)"
SHA256SUM_BIN="$(resolve_bin sha256sum)"

# ===== 主工作目录与可调配置 =====
GONGCAO_HOME="${GONGCAO_HOME:-${HOME}/.gongcao}"
REPOS_ROOT="${REPOS_ROOT:-${GONGCAO_HOME}/repos}"
STATE_BASE="${STATE_BASE:-${GONGCAO_HOME}/state}"

# shellcheck source=lib/codex-profile.sh
source "${SCRIPT_DIR}/lib/codex-profile.sh"
# shellcheck source=lib/git-worktree.sh
source "${SCRIPT_DIR}/lib/git-worktree.sh"
init_codex_review_profile "codex-review-loop.sh" "${1:-run}"

REPO="${REPO:-}"                         # 目标 GitHub 仓库 "owner/repo"
REPO_NAME="${REPO_NAME:-}"               # 可选：~/.gongcao/repos/<REPO_NAME>
REPO_DIR="${REPO_DIR:-}"                 # 可选：显式本地仓库路径
AUTO_CLONE="${AUTO_CLONE:-1}"            # 未克隆时自动只读克隆到 ~/.gongcao/repos/
LABEL_PREFIX="${LABEL_PREFIX:-agy:}"
REVIEW_LABEL="${REVIEW_LABEL:-${LABEL_PREFIX}in-review}"
REVIEW_COMMENT_MARKER="${REVIEW_COMMENT_MARKER:-<!-- codex-review-comment -->}"
E2E_COMMENT_MARKER="${E2E_COMMENT_MARKER:-<!-- codex-e2e-comment -->}"
E2E_EVIDENCE_BRANCH="${E2E_EVIDENCE_BRANCH:-qa/e2e-evidence}"
ALLOW_SKIP_E2E="${ALLOW_SKIP_E2E:-1}"     # 1=评审确认免 E2E 或已有祖先提交 E2E 通过时直接转 agy:e2e-skipped -> final-gate；0=一律转 agy:approved
CODEX_MODEL="${CODEX_MODEL:-gpt-6.2-sol}" # 默认使用 GPT-6.2-Sol
CODEX_REASONING_EFFORT="${CODEX_REASONING_EFFORT:-xhigh}" # 默认推理强度 xhigh
CODEX_REREVIEW_REASONING_EFFORT="${CODEX_REREVIEW_REASONING_EFFORT:-medium}" # 第 2 轮及以上复审推理强度（避免 xhigh 过度深挖次生边界）
CODEX_SANDBOX="${CODEX_SANDBOX:-read-only}"
CODEX_TIMEOUT="${CODEX_TIMEOUT:-15m}"    # 单次 codex 评审超时上限，防止进程卡死
MAX_DIFF_BYTES="${MAX_DIFF_BYTES:-60000}" # 嵌入 prompt 的 diff 最大字节数（超长截断，Codex 可在 worktree 中查完整 diff）
MAX_REVIEW_ROUNDS="${MAX_REVIEW_ROUNDS:-3}" # 最大连续打回评审轮数（approve 后清零），超过则切 blocked 交人工裁决
MAX_TOTAL_REVIEW_ROUNDS="${MAX_TOTAL_REVIEW_ROUNDS:-12}" # 单 PR 生命周期硬性总评审轮次上限，防止死循环
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
REPO_GIT_LOCK="${STATE_ROOT}/repo-git.lock"

"$MKDIR_BIN" -p "$STATE_ROOT" "$WORKTREE_ROOT" "$REVIEWS_ROOT"
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

printf '[%s] 启动 codex-review-loop\n' "$("$DATE_BIN" '+%F %T')"
printf '  Codex 命令 : %s (model=%s, effort=%s, rereview_effort=%s, sandbox=%s)\n' \
  "$CODEX_BIN" "${CODEX_MODEL:-(codex 默认)}" "${CODEX_REASONING_EFFORT:-(默认)}" "${CODEX_REREVIEW_REASONING_EFFORT:-(同默认)}" "$CODEX_SANDBOX"
printf '  Codex 配置 : %s\n' "$CODEX_PROFILE_DIR"
printf '  工作主目录 : %s\n' "$GONGCAO_HOME"
printf '  主仓库目录 : %s\n' "$REPO_ROOT"
printf '  评审档案根 : %s\n' "$REVIEWS_ROOT"
printf '  监听标签   : %s (MAX_REVIEW_ROUNDS=%s, MAX_TOTAL_REVIEW_ROUNDS=%s, ALLOW_SKIP_E2E=%s, AUTO_REQUEUE_ISSUE=%s, DRY_RUN=%s)\n' \
  "$REVIEW_LABEL" "$MAX_REVIEW_ROUNDS" "$MAX_TOTAL_REVIEW_ROUNDS" "$ALLOW_SKIP_E2E" "$AUTO_REQUEUE_ISSUE" "$DRY_RUN"

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

# 生成“提交 SHA + PR 正文内容摘要”去重键：
# 既能防止 set-state 失败导致死循环，又允许“同 SHA 仅补齐 PR 验证证据/更新正文后重新进入 in-review”被正常复审
compute_review_key() {
  local sha="$1"
  local body="$2"
  local body_hash=""
  body_hash="$(printf '%s' "$body" | "$SHA256SUM_BIN")"
  body_hash="${body_hash%% *}"
  printf '%s:%s' "$sha" "${body_hash:0:16}"
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
    "e2e_decision",
    "e2e_decision_reason",
    "e2e_checks",
    "requires_human_decision",
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
    "e2e_decision": {
      "type": "string",
      "enum": ["run_e2e", "skip_not_needed", "skip_already_passed"]
    },
    "e2e_decision_reason": {
      "type": "string"
    },
    "e2e_checks": {
      "type": "array",
      "items": { "type": "string" }
    },
    "requires_human_decision": { "type": "boolean" },
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
        "required": ["id", "severity", "location", "description", "suggestion", "verification"],
        "properties": {
          "id": { "type": "string" },
          "severity": { "type": "string", "enum": ["critical", "major"] },
          "location": { "type": "string" },
          "description": { "type": "string" },
          "suggestion": { "type": "string" },
          "verification": { "type": "string" }
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
  local match="" num=""
  num="$(release_issue_from_pr "$pr_body")"
  if [[ -n "$num" ]]; then
    printf '%s' "$num"
    return
  fi

  match="$("$GREP_BIN" -oiE -m 1 '(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#[0-9]+' <<<"$pr_body" || true)"
  [[ -n "$match" ]] && num="${match##*#}"
  if [[ -z "$num" ]]; then
    match="$("$GREP_BIN" -oE -m 1 'issue-[0-9]+' <<<"$head_branch" || true)"
    [[ -n "$match" ]] && num="${match#issue-}"
  fi
  printf '%s' "$num"
}

prepare_review_worktree() {
  local pr_num="$1"
  local head_branch="$2"
  local head_sha="$3"
  checkout_exact_pr_worktree "${WORKTREE_ROOT}/review-pr-${pr_num}" "$pr_num" "$head_branch" "$head_sha"
}

# 检查远端 QA 证据分支是否已有本 PR 或关联 Issue 的 E2E 通过记录，并计算与当前 head_sha 的祖先/增量关系
inspect_prior_e2e_evidence() {
  local pr_num="$1"
  local issue_num="$2"
  local head_sha="$3"
  local ev_wt="${WORKTREE_ROOT}/review-evidence"

  (
    "$FLOCK_BIN" -x 9
    "$GIT_BIN" -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true
    "$GIT_BIN" -C "$REPO_ROOT" fetch origin "$E2E_EVIDENCE_BRANCH" >/dev/null 2>&1 || true

    if "$GIT_BIN" -C "$REPO_ROOT" show-ref --verify --quiet "refs/remotes/origin/${E2E_EVIDENCE_BRANCH}"; then
      if [[ -e "${ev_wt}/.git" ]]; then
        "$GIT_BIN" -C "$ev_wt" checkout --detach --force "origin/${E2E_EVIDENCE_BRANCH}" >/dev/null 2>&1 || true
        "$GIT_BIN" -C "$ev_wt" clean -fd >/dev/null 2>&1 || true
      else
        "$GIT_BIN" -C "$REPO_ROOT" worktree add --detach "$ev_wt" "origin/${E2E_EVIDENCE_BRANCH}" >/dev/null 2>&1 || true
      fi
    fi
  ) 9>"$REPO_GIT_LOCK"

  local has_pass=0
  local tested_sha=""
  local is_ancestor=0
  local rel_dir=""
  local branch_sha=""
  local delta_stat=""
  local delta_commits=""
  local best_dir=""

  if [[ -e "${ev_wt}/.git" ]]; then
    branch_sha="$("$GIT_BIN" -C "$ev_wt" rev-parse HEAD 2>/dev/null || true)"
    local mf entry_dir entry_verdict rj_verdict best_ts="" entry_ts=""

    if [[ -d "${ev_wt}/pr-${pr_num}" ]]; then
      while IFS= read -r mf; do
        [[ -f "$mf" ]] || continue
        entry_dir="${mf%/manifest.json}"
        entry_verdict="$("$JQ_BIN" -r '.verdict // ""' "$mf" 2>/dev/null || true)"
        if [[ -f "${entry_dir}/result.json" ]]; then
          rj_verdict="$("$JQ_BIN" -r '.verdict // ""' "${entry_dir}/result.json" 2>/dev/null || true)"
          [[ -n "$rj_verdict" ]] && entry_verdict="$rj_verdict"
        fi
        if [[ "$entry_verdict" == "pass" ]]; then
          has_pass=1
          best_dir="$entry_dir"
        fi
      done < <("$FIND_BIN" "${ev_wt}/pr-${pr_num}" -mindepth 2 -maxdepth 2 -name manifest.json 2>/dev/null | "$SORT_BIN")
    fi

    # 若当前 PR 目录下尚未找到，则回退按 issue_number 检索（适配相同 Issue 先前 PR 已跑过 E2E 的情况）
    if (( has_pass == 0 )) && [[ -n "$issue_num" ]]; then
      while IFS= read -r mf; do
        [[ -f "$mf" ]] || continue
        if ! "$JQ_BIN" -e --arg inum "$issue_num" '((.issue_number // "") | tostring) == $inum' "$mf" >/dev/null 2>&1; then
          continue
        fi
        entry_dir="${mf%/manifest.json}"
        entry_verdict="$("$JQ_BIN" -r '.verdict // ""' "$mf" 2>/dev/null || true)"
        if [[ -f "${entry_dir}/result.json" ]]; then
          rj_verdict="$("$JQ_BIN" -r '.verdict // ""' "${entry_dir}/result.json" 2>/dev/null || true)"
          [[ -n "$rj_verdict" ]] && entry_verdict="$rj_verdict"
        fi
        if [[ "$entry_verdict" == "pass" ]]; then
          entry_ts="${entry_dir##*/}"
          if [[ -z "$best_ts" || "$entry_ts" > "$best_ts" || "$entry_ts" == "$best_ts" ]]; then
            has_pass=1
            best_dir="$entry_dir"
            best_ts="$entry_ts"
          fi
        fi
      done < <("$FIND_BIN" "$ev_wt" -mindepth 3 -maxdepth 3 -name manifest.json 2>/dev/null | "$SORT_BIN")
    fi

    if (( has_pass == 1 )) && [[ -n "$best_dir" ]]; then
      rel_dir="${best_dir#${ev_wt}/}"
      tested_sha="$("$JQ_BIN" -r '.tested_sha // ""' "${best_dir}/manifest.json" 2>/dev/null || true)"
      if [[ -n "$tested_sha" ]] && "$GIT_BIN" -C "$REPO_ROOT" merge-base --is-ancestor "$tested_sha" "$head_sha" 2>/dev/null; then
        is_ancestor=1
        if [[ "$tested_sha" == "$head_sha" ]]; then
          delta_stat="(无新增改动，与已通过 E2E 的提交完全一致)"
          delta_commits="(无)"
        else
          delta_stat="$("$GIT_BIN" -C "$REPO_ROOT" diff --stat "${tested_sha}..${head_sha}" 2>/dev/null || true)"
          delta_commits="$("$GIT_BIN" -C "$REPO_ROOT" log --oneline -n 20 "${tested_sha}..${head_sha}" 2>/dev/null || true)"
        fi
      fi
    fi
  fi

  "$JQ_BIN" -n \
    --arg has_pass "$has_pass" \
    --arg tested_sha "$tested_sha" \
    --arg is_ancestor "$is_ancestor" \
    --arg rel_dir "$rel_dir" \
    --arg branch_sha "$branch_sha" \
    --arg delta_stat "$delta_stat" \
    --arg delta_commits "$delta_commits" \
    '{
      has_pass: ($has_pass == "1"),
      tested_sha: $tested_sha,
      is_ancestor: ($is_ancestor == "1"),
      rel_dir: $rel_dir,
      branch_sha: $branch_sha,
      delta_stat: $delta_stat,
      delta_commits: $delta_commits
    }'
}

render_review_markdown() {
  local verdict_file="$1"
  local pr_num="$2"
  local issue_num="$3"
  local head_sha="$4"
  local round="$5"
  local final_state="$6"
  local eff_e2e_decision="$7"
  local e2e_reused_sha="$8"
  local e2e_downgrade_note="$9"
  local eff_effort="${10:-$CODEX_REASONING_EFFORT}"
  local cycle_round="${11:-$round}"
  local now_ts
  now_ts="$("$DATE_BIN" --iso-8601=seconds)"

  local meta_json
  meta_json="$("$JQ_BIN" -c \
    --arg head_sha "$head_sha" \
    --arg e2e_decision "$eff_e2e_decision" \
    --arg e2e_reused_sha "$e2e_reused_sha" \
    '{head_sha: $head_sha, verdict, e2e_decision: $e2e_decision, e2e_reused_sha: $e2e_reused_sha, e2e_checks: (.e2e_checks | sort)}' "$verdict_file")"

  "$JQ_BIN" -r -L "$SCRIPT_DIR" \
    --arg pr "$pr_num" \
    --arg issue "${issue_num:-(未关联)}" \
    --arg sha "${head_sha:0:10}" \
    --arg round "$round" \
    --arg cycle_round "$cycle_round" \
    --arg max_rounds "$MAX_REVIEW_ROUNDS" \
    --arg max_total_rounds "$MAX_TOTAL_REVIEW_ROUNDS" \
    --arg state "${LABEL_PREFIX}${final_state}" \
    --arg eff_e2e "$eff_e2e_decision" \
    --arg e2e_note "$e2e_downgrade_note" \
    --arg meta_json "$meta_json" \
    --arg model "${CODEX_MODEL:-(codex 默认)}${eff_effort:+ (${eff_effort})}" \
    --arg now "$now_ts" \
    '
    include "workflow-e2e";
    def esc: tostring | gsub("\n"; " ") | gsub("\\|"; "\\|");
    "### Codex 独立评审报告\n\n"
    + "| 字段 | 值 |\n| --- | --- |\n"
    + "| 评审结论 | `" + .verdict + "` -> `" + $state + "` |\n"
    + (if .verdict == "approve" then
        "| E2E 路由 | `" + $eff_e2e + "`（" + (((.e2e_decision_reason // "") + $e2e_note) | esc) + "） |\n"
      else
        ""
      end)
    + "| 关联 Issue | #" + $issue + " |\n"
    + "| 评审 Commit | `" + $sha + "` |\n"
    + "| 评审轮次 | 本周期 " + $cycle_round + " / " + $max_rounds + "（累计 " + $round + " / " + $max_total_rounds + "） |\n"
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
        ([.blocking_issues[] | "- **[" + .severity + "]** `" + .id + "` · `" + .location + "`\n  " + .description
          + "\n  - 修复建议。" + .suggestion + "\n  - 关闭条件。" + .verification] | join("\n"))
      else
        "- 无阻塞问题"
      end)
    + (if .e2e_checks | length > 0 then
        "\n\n#### E2E 必验场景\n"
        + (.e2e_checks | sort | numbered_e2e_checks | map("- " + .id + " " + .description) | join("\n"))
      else
        ""
      end)
    + "\n\n#### 非阻塞建议（Non-blocking Notes）\n"
    + (if (.non_blocking_notes | length) > 0 then
        ([.non_blocking_notes[] | "- " + .] | join("\n"))
      else
        "- 无"
      end)
    + "\n\n<!-- codex-review-meta:" + ($meta_json | gsub("<"; "\\u003c") | gsub(">"; "\\u003e")) + " -->"
    ' "$verdict_file"
}

publish_review() {
  local pending_file="$1" review_dir="${1%/*}"
  local pr_num issue_num final_state review_key round cycle_round verdict elapsed end_ts history_file history_json
  pr_num="$("$JQ_BIN" -r '.meta.pr_number' "$pending_file")" || return 1
  issue_num="$("$JQ_BIN" -r '.meta.issue_number' "$pending_file")" || return 1
  final_state="$("$JQ_BIN" -r '.meta.final_state' "$pending_file")" || return 1
  review_key="$("$JQ_BIN" -r '.review_key' "$pending_file")" || return 1

  if ! "$JQ_BIN" -e '.pr_comment_written' "$pending_file" >/dev/null; then
    "$JQ_BIN" -r '.comment' "$pending_file" | gh_state comment pr "$pr_num" - "$REVIEW_COMMENT_MARKER" || return 1
    "$JQ_BIN" '.pr_comment_written = true' "$pending_file" > "${pending_file}.tmp" || return 1
    "$MV_BIN" "${pending_file}.tmp" "$pending_file" || return 1
  fi

  # PR 标签切换后，下个循环就能接手。先保存本轮记录，使标签重试或进程重启不增加轮次。
  if [[ "$DRY_RUN" != "1" ]]; then
    if ! "$GREP_BIN" -Fqx -- "$review_key" "${review_dir}/reviewed_shas.txt"; then
      history_file="${review_dir}/blocker-history.json"
      history_json='{}'
      if [[ -f "$history_file" ]]; then
        history_json="$(<"$history_file")" || return 1
      fi
      "$JQ_BIN" --arg key "$review_key" --slurpfile pending "$pending_file" '
        reduce $pending[0].review.blocking_issues[] as $blocker (.;
          .[$blocker.id] |= {
            description: $blocker.description,
            location: $blocker.location,
            verification: $blocker.verification,
            review_keys: ((.review_keys // []) + [$key] | unique)
          })
      ' <<<"$history_json" > "${history_file}.tmp" || return 1
      "$MV_BIN" "${history_file}.tmp" "$history_file" || return 1
      "$JQ_BIN" '.review' "$pending_file" > "${review_dir}/last_verdict.json" || return 1
      "$JQ_BIN" -r '.meta.consecutive_rejections' "$pending_file" > "${review_dir}/consecutive_rejections.txt" || return 1
      "$JQ_BIN" '.meta' "$pending_file" > "${review_dir}/meta.json" || return 1
      printf '%s\n' "$review_key" >> "${review_dir}/reviewed_shas.txt" || return 1
    fi
  else
    "$JQ_BIN" '.meta' "$pending_file" > "${review_dir}/meta.json" || return 1
  fi

  if ! "$JQ_BIN" -e '.pr_state_written // false' "$pending_file" >/dev/null; then
    gh_state set-state pr "$pr_num" "$final_state" || return 1
    "$JQ_BIN" '.pr_state_written = true' "$pending_file" > "${pending_file}.tmp" || return 1
    "$MV_BIN" "${pending_file}.tmp" "$pending_file" || return 1
  fi

  # 开发循环按 Issue 标签接手，关联 Issue 同步纳入交接重试，避免 PR 切标后 Issue 遗漏回队列。
  if [[ -n "$issue_num" ]] && [[ "$final_state" != "changes-requested" || "$AUTO_REQUEUE_ISSUE" == "1" ]]; then
    if ! "$JQ_BIN" -e '.issue_comment_written // false' "$pending_file" >/dev/null; then
      "$JQ_BIN" -r '.comment' "$pending_file" | gh_state comment issue "$issue_num" - "$REVIEW_COMMENT_MARKER" || return 1
      "$JQ_BIN" '.issue_comment_written = true' "$pending_file" > "${pending_file}.tmp" || return 1
      "$MV_BIN" "${pending_file}.tmp" "$pending_file" || return 1
    fi
    gh_state set-state issue "$issue_num" "$final_state" || return 1
  fi

  round="$("$JQ_BIN" -r '.meta.round' "$pending_file")" || return 1
  cycle_round="$("$JQ_BIN" -r '.meta.cycle_round' "$pending_file")" || return 1
  verdict="$("$JQ_BIN" -r '.meta.verdict' "$pending_file")" || return 1
  elapsed="$("$JQ_BIN" -r '.elapsed' "$pending_file")" || return 1
  "$RM_BIN" -- "$pending_file" || return 1
  end_ts="$("$DATE_BIN" '+%F %T')"
  printf '\n============================================================\n'
  printf '[%s] [DONE] PR #%s Codex 评审完成 (本周期第 %d/%d 轮, 累计第 %d/%d 轮, 耗时 %ds)\n' \
    "$end_ts" "$pr_num" "$cycle_round" "$MAX_REVIEW_ROUNDS" "$round" "$MAX_TOTAL_REVIEW_ROUNDS" "$elapsed"
  printf '  评审结论 : %s -> %s%s\n' "$verdict" "$LABEL_PREFIX" "$final_state"
  printf '  评审报告 : %s\n' "${review_dir}/review-comment.md"
  printf '============================================================\n\n'
  printf '[%s] [codex-review] PR #%s (Issue #%s, r%d) -> %s (%s%s, %ds)\n' \
    "$end_ts" "$pr_num" "${issue_num:-?}" "$round" "$verdict" "$LABEL_PREFIX" "$final_state" "$elapsed" >> "$ACTIVITY_LOG"
}

retry_review_handoff() {
  local pending_file="$1"
  local pending_pr=""
  pending_pr="$("$JQ_BIN" -r '.meta.pr_number // empty' "$pending_file" 2>/dev/null || true)"
  if publish_review "$pending_file"; then
    "$SLEEP_BIN" 5
  else
    printf '[%s] 警告：PR #%s 评审交接失败，%ss 后重试已保存的报告。\n' \
      "$("$DATE_BIN" '+%F %T')" "${pending_pr:-${pr_num:-?}}" "$POLL_INTERVAL" >&2
    "$SLEEP_BIN" "$POLL_INTERVAL"
  fi
}

consecutive_poll_errors=0
idle_announced=0
ACTIVITY_LOG="${STATE_ROOT}/activity.log"

while true; do
  if [[ "$INIT_LABELS" == "1" && "$LABELS_READY" == "0" ]]; then
    if gh_state init-labels; then
      LABELS_READY=1
    fi
  fi

  # 若某 PR 已切离评审标签但关联 Issue 交接尚未完成，先续完残余交接。
  if [[ "$DRY_RUN" != "1" ]]; then
    pending_issue_handoff=""
    for _pf in "${REVIEWS_ROOT}"/pr-*/pending-review.json; do
      [[ -f "$_pf" ]] || continue
      if "$JQ_BIN" -e '.pr_state_written == true' "$_pf" >/dev/null 2>&1; then
        pending_issue_handoff="$_pf"
        break
      fi
    done
    if [[ -n "$pending_issue_handoff" ]]; then
      idle_announced=0
      retry_review_handoff "$pending_issue_handoff"
      continue
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

  # 按 PR 编号升序（FIFO）找出第一条当前 (head_sha, body) 尚未评审过的 PR
  next_pr_json=""
  while IFS= read -r row; do
    pnum="$("$JQ_BIN" -r '.number' <<<"$row")"
    psha="$("$JQ_BIN" -r '.headRefOid // empty' <<<"$row")"
    pbody="$("$JQ_BIN" -r '.body // ""' <<<"$row")"
    pkey=""
    [[ -n "$psha" ]] && pkey="$(compute_review_key "$psha" "$pbody")"
    sha_file="${REVIEWS_ROOT}/pr-${pnum}/reviewed_shas.txt"
    pending_file="${sha_file%/*}/pending-review.json"
    if [[ "$DRY_RUN" != "1" && -f "$pending_file" ]] \
      && "$JQ_BIN" -e --arg key "$pkey" '.review_key == $key' "$pending_file" >/dev/null; then
      next_pr_json="$row"
      break
    fi
    if [[ -n "$pkey" && -f "$sha_file" ]] && "$GREP_BIN" -Fqx -- "$pkey" "$sha_file"; then
      continue
    fi
    next_pr_json="$row"
    break
  done < <("$JQ_BIN" -c 'sort_by(.number) | .[]' <<<"$prs_json")

  if [[ -z "$next_pr_json" ]]; then
    if (( idle_announced == 0 )); then
      printf '[%s] 空闲等待中：暂无待 Codex 评审的 PR（每 %ss 后台轮询一次）...\n' "$("$DATE_BIN" '+%F %T')" "$POLL_INTERVAL"
      idle_announced=1
    fi
    "$SLEEP_BIN" "$POLL_INTERVAL"
    continue
  fi
  idle_announced=0
  task_start_sec=$SECONDS

  pr_num="$("$JQ_BIN" -r '.number' <<<"$next_pr_json")"
  pr_title="$("$JQ_BIN" -r '.title' <<<"$next_pr_json")"
  pr_body="$("$JQ_BIN" -r '.body // ""' <<<"$next_pr_json")"
  pr_url="$("$JQ_BIN" -r '.url' <<<"$next_pr_json")"
  head_branch="$("$JQ_BIN" -r '.headRefName' <<<"$next_pr_json")"
  base_branch="$("$JQ_BIN" -r '.baseRefName' <<<"$next_pr_json")"
  head_sha="$("$JQ_BIN" -r '.headRefOid' <<<"$next_pr_json")"
  mergeable="$("$JQ_BIN" -r '.mergeable // ""' <<<"$next_pr_json")"
  merge_state="$("$JQ_BIN" -r '.mergeStateStatus // ""' <<<"$next_pr_json")"

  # 前置冲突拦截：若 PR 与目标分支存在合并冲突，直接退回开发循环解决，避免浪费评审 Token
  if [[ "$mergeable" == "CONFLICTING" || "$merge_state" == "DIRTY" ]]; then
    issue_num="$(extract_linked_issue "$pr_body" "$head_branch")"
    conflict_md="$("$CAT_BIN" <<EOF
### Codex 独立评审前置拦截：存在合并冲突

- PR #${pr_num}（\`${head_branch}\` -> \`${base_branch}\`）当前合并状态为 \`${mergeable:-CONFLICTING}\` / \`${merge_state:-DIRTY}\`。
- 已将状态切为 \`${LABEL_PREFIX}changes-requested\`，请先同步最新 \`${base_branch}\` 并解决合并冲突后再进入评审（本次不消耗评审轮次）。
EOF
)"
    printf '%s\n' "$conflict_md" | gh_state comment pr "$pr_num" - "$REVIEW_COMMENT_MARKER" || true
    gh_state set-state pr "$pr_num" changes-requested || true
    if [[ -n "$issue_num" && "$AUTO_REQUEUE_ISSUE" == "1" ]]; then
      gh_state set-state issue "$issue_num" changes-requested || true
      printf '%s\n' "$conflict_md" | gh_state comment issue "$issue_num" - "$REVIEW_COMMENT_MARKER" || true
    fi
    end_ts="$("$DATE_BIN" '+%F %T')"
    printf '[%s] PR #%s 存在合并冲突 (%s/%s)，已直接退回 %schanges-requested\n' \
      "$end_ts" "$pr_num" "$mergeable" "$merge_state" "$LABEL_PREFIX"
    printf '[%s] [codex-review] PR #%s (Issue #%s) -> conflict-requeued (%schanges-requested)\n' \
      "$end_ts" "$pr_num" "${issue_num:-?}" "$LABEL_PREFIX" >> "$ACTIVITY_LOG"
    "$SLEEP_BIN" 5
    continue
  fi

  review_dir="${REVIEWS_ROOT}/pr-${pr_num}"
  "$MKDIR_BIN" -p "$review_dir"
  sha_file="${review_dir}/reviewed_shas.txt"
  "$TOUCH_BIN" "$sha_file"
  review_key="$(compute_review_key "$head_sha" "$pr_body")"
  pending_file="${review_dir}/pending-review.json"
  if [[ "$DRY_RUN" == "1" ]]; then
    pending_file="${review_dir}/pending-review-dry-run.json"
  elif [[ -f "$pending_file" ]] \
    && "$JQ_BIN" -e --arg key "$review_key" '.review_key == $key' "$pending_file" >/dev/null; then
    retry_review_handoff "$pending_file"
    continue
  fi

  prev_rounds=0
  prev_reviewed_sha=""
  while IFS= read -r _line; do
    if [[ -n "$_line" ]]; then
      prev_rounds=$((prev_rounds + 1))
      prev_reviewed_sha="${_line%%:*}"
    fi
  done < "$sha_file"
  current_round=$((prev_rounds + 1))

  consec_file="${review_dir}/consecutive_rejections.txt"
  prev_consecutive_rejections=0
  if [[ -f "$consec_file" ]]; then
    _raw_consec="$(<"$consec_file")"
    _raw_consec="${_raw_consec//$'\r'/}"
    _raw_consec="${_raw_consec//$'\n'/}"
    if [[ "$_raw_consec" =~ ^[0-9]+$ ]]; then
      prev_consecutive_rejections="$_raw_consec"
    fi
  else
    for _vf in "${review_dir}"/verdict-*.json; do
      [[ -s "$_vf" ]] || continue
      _v="$("$JQ_BIN" -r '.verdict // empty' "$_vf" 2>/dev/null || true)"
      if [[ "$_v" == "approve" ]]; then
        prev_consecutive_rejections=0
      elif [[ "$_v" == "request_changes" ]]; then
        prev_consecutive_rejections=$((prev_consecutive_rejections + 1))
      fi
    done
  fi
  cycle_round=$((prev_consecutive_rejections + 1))

  run_ts="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
  schema_file="${review_dir}/schema.json"
  prompt_file="${review_dir}/prompt-${run_ts}.md"
  events_file="${review_dir}/events-${run_ts}.jsonl"
  verdict_file="${review_dir}/verdict-${run_ts}.json"
  comment_file="${review_dir}/review-comment.md"
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

  printf '[%s] 开始 Codex 独立评审 PR #%s (Issue #%s, sha=%s, 本周期第 %d/%d 轮, 累计第 %d/%d 轮)...\n' \
    "$("$DATE_BIN" '+%F %T')" "$pr_num" "${issue_num:-?}" "${head_sha:0:10}" "$cycle_round" "$MAX_REVIEW_ROUNDS" "$current_round" "$MAX_TOTAL_REVIEW_ROUNDS"

  if ! review_wt="$(prepare_review_worktree "$pr_num" "$head_branch" "$head_sha")"; then
    printf '[%s] 警告：为 PR #%s 准备只读 worktree 失败，%ss 后重试...\n' \
      "$("$DATE_BIN" '+%F %T')" "$pr_num" "$POLL_INTERVAL" >&2
    "$SLEEP_BIN" "$POLL_INTERVAL"
    continue
  fi

  # 检查本 PR 或关联 Issue 是否已有通过 E2E 的远端归档证据及增量改动
  prior_e2e_json="$(inspect_prior_e2e_evidence "$pr_num" "$issue_num" "$head_sha")"
  prior_e2e_has_pass="$("$JQ_BIN" -r '.has_pass' <<<"$prior_e2e_json")"
  prior_e2e_sha="$("$JQ_BIN" -r '.tested_sha // ""' <<<"$prior_e2e_json")"
  prior_e2e_is_ancestor="$("$JQ_BIN" -r '.is_ancestor' <<<"$prior_e2e_json")"
  prior_e2e_rel="$("$JQ_BIN" -r '.rel_dir // ""' <<<"$prior_e2e_json")"
  prior_e2e_branch_sha="$("$JQ_BIN" -r '.branch_sha // ""' <<<"$prior_e2e_json")"
  prior_e2e_delta_stat="$("$JQ_BIN" -r '.delta_stat // ""' <<<"$prior_e2e_json")"
  prior_e2e_delta_commits="$("$JQ_BIN" -r '.delta_commits // ""' <<<"$prior_e2e_json")"

  prev_e2e_comment="$(gh_state get-comment pr "$pr_num" "$E2E_COMMENT_MARKER" 2>/dev/null || true)"
  if [[ -z "$prev_e2e_comment" && -n "$issue_num" ]]; then
    prev_e2e_comment="$(gh_state get-comment issue "$issue_num" "$E2E_COMMENT_MARKER" 2>/dev/null || true)"
  fi
  prev_e2e_snippet="${prev_e2e_comment:0:8000}"

  pr_diff_raw="$(gh_state get-pr-diff "$pr_num" 2>/dev/null || true)"
  # 使用纯 Bash 切片截断，避免 set -o pipefail 下 printf | head 触发 SIGPIPE (141) 退出
  pr_diff_snippet="${pr_diff_raw:0:MAX_DIFF_BYTES}"
  if (( ${#pr_diff_raw} > MAX_DIFF_BYTES )); then
    pr_diff_snippet="${pr_diff_snippet}"$'\n\n'"... (diff 已截断，请在当前只读工作区使用 git diff origin/${base_branch}...HEAD 查看完整变更)"
  fi

  # 若为第 2 轮及以上复审，自动带入上一轮的阻塞问题清单与本轮增量 diff 以约束复审收敛
  prev_review_section=""
  blocker_history='{}'
  blocker_history_section=""
  rereview_delta_section=""
  if [[ -f "${review_dir}/blocker-history.json" ]]; then
    blocker_history="$(<"${review_dir}/blocker-history.json")"
    if [[ "$blocker_history" != '{}' ]]; then
      blocker_history_section=$'\n\n'"## 本 PR 历次评审的阻塞根因"$'\n'
      blocker_history_section+="$("$JQ_BIN" -r '
        to_entries[] | "- " + .key + "（已出现 " + (.value.review_keys | length | tostring)
          + " 轮） · " + .value.location + "：" + .value.description
          + "\n  - 关闭条件。" + .value.verification
      ' <<<"$blocker_history")"
    fi
  fi
  if (( current_round >= 2 )); then
    if (( cycle_round >= 2 )); then
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
            [.blocking_issues[] | "- " + (.id // "未编号") + " · [" + .severity + "] `" + .location + "`\n  " + .description
              + "\n  - 修复建议。" + .suggestion + (if .verification then "\n  - 关闭条件。" + .verification else "" end)] | join("\n")
          else
            "- (上一轮无阻塞项)"
          end
        ' "$prev_verdict_file" 2>/dev/null || true)"
        if [[ -n "$prev_blocking" ]]; then
          prev_review_section=$'\n\n'"## 上一轮阻塞问题清单（本轮重点核验收敛）"$'\n'"${prev_blocking}"
        fi
      fi
    fi

    if [[ -n "$prev_reviewed_sha" ]]; then
      if [[ "$prev_reviewed_sha" == "$head_sha" ]]; then
        rereview_delta_section=$'\n\n'"## 本轮增量变更（复审主要核对范围）"$'\n'"- 本轮未新增代码提交（仍为 \`${head_sha:0:10}\`），仅更新了 PR 描述或验证证据；请重点核验新补充的证据是否已关闭上一轮阻塞项。"
      elif "$GIT_BIN" -C "$REPO_ROOT" cat-file -e "${prev_reviewed_sha}^{commit}" 2>/dev/null \
        && "$GIT_BIN" -C "$REPO_ROOT" cat-file -e "${head_sha}^{commit}" 2>/dev/null; then
        delta_commits_text="$("$GIT_BIN" -C "$REPO_ROOT" log --oneline "${prev_reviewed_sha}..${head_sha}" 2>/dev/null || true)"
        delta_diff_raw="$("$GIT_BIN" -C "$REPO_ROOT" diff "${prev_reviewed_sha}..${head_sha}" 2>/dev/null || true)"
        delta_diff_snippet="${delta_diff_raw:0:MAX_DIFF_BYTES}"
        if (( ${#delta_diff_raw} > MAX_DIFF_BYTES )); then
          delta_diff_snippet="${delta_diff_snippet}"$'\n\n'"... (增量 diff 已截断，请在当前只读工作区使用 git diff ${prev_reviewed_sha:0:10}..HEAD 查看完整增量)"
        fi
        rereview_delta_section=$'\n\n'"## 本轮增量变更（\`${prev_reviewed_sha:0:10}..${head_sha:0:10}\`，复审主要核对范围）"$'\n'"\`\`\`text"$'\n'"${delta_commits_text:-"(无提交记录)"}"$'\n'"\`\`\`"$'\n'"\`\`\`diff"$'\n'"${delta_diff_snippet:-"(空增量 diff)"}"$'\n'"\`\`\`"
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
- 评审轮次: 本轮周期第 ${cycle_round} / ${MAX_REVIEW_ROUNDS} 轮（累计第 ${current_round} / ${MAX_TOTAL_REVIEW_ROUNDS} 轮）

### PR 描述
${pr_body:-"(empty)"}

## 关联 Issue 要求
${issue_section}${prev_review_section}${blocker_history_section}${rereview_delta_section}

## 既有 E2E 验收状态与免测判断依据
- 是否存在通过的远端 QA 证据（\`${E2E_EVIDENCE_BRANCH}\`）: \`${prior_e2e_has_pass}\`
- 已通过 E2E 的提交 SHA: \`${prior_e2e_sha:-(无)}\`（是否当前 PR 提交 \`${head_sha:0:10}\` 的祖先: \`${prior_e2e_is_ancestor}\`）
- 证据归档目录: \`${prior_e2e_rel:-(无)}\`（分支快照 \`${prior_e2e_branch_sha:0:10}\`）
- 自已通过 E2E 提交以来的增量提交（\`${prior_e2e_sha:0:10}..${head_sha:0:10}\`）:
\`\`\`text
${prior_e2e_delta_commits:-"(无或未关联)"}
\`\`\`
- 自已通过 E2E 提交以来的增量 diff 统计:
\`\`\`text
${prior_e2e_delta_stat:-"(无或未关联)"}
\`\`\`
- 最近一次 E2E 验收评论摘录:
${prev_e2e_snippet:-"(无 E2E 验收评论)"}

## PR Diff 摘录
\`\`\`diff
${pr_diff_snippet:-"(空 diff)"}
\`\`\`

## 评审准则（务必遵守）
1. 当前工作目录是 PR 最新提交（\`${head_sha}\`）的只读检出，请按需阅读完整源文件、调用点与相关单元测试以核实证据，不要轻信 PR 描述中的自我声明。你当前运行在离线 \`read-only\` 沙箱中，网络与 \`gh\` CLI 访问已被有意禁用；所有 GitHub PR/Issue/E2E 快照已由宿主机脚本通过 \`gh-state.sh\` 注入本提示词，**禁止在沙箱内执行 \`gh\` 命令**，也不要在 \`non_blocking_notes\` 中抱怨或记录沙箱禁止 \`gh\` 访问。
2. 逐项核对原始 Issue 需求是否完整实现，重点检查：正确性、边界条件、方言/兼容性、安全与并发隐患、回归风险、以及是否补充了合理的内部单元测试。
   - 若改动扩展了兼容行为或改变共享模块、持久化数据、状态机等现有契约，请核对 Issue 中的具体要求或已有授权。将当前 PR 引入的未授权扩展列为阻塞项，指出需要收回的改动或待确认的范围。
   - 修复建议也须遵守相同的授权范围。发现读取或展示口径不一致时，优先建议在读取或展示层处理，并核查是否能保留现有写入、摘要和重放行为。证据无法确认根因时注明证据缺口。若满足 Issue 必须变更持久化或共享契约且缺少授权，输出 \`request_changes\`，将 \`requires_human_decision\` 设为 \`true\`，并在修复建议中写明待授权的契约和影响。其余情况该字段为 \`false\`。
3. **关于 E2E 验证**：本工作流明确约定开发阶段仅做内部验证（构建/类型检查/单元测试），**不要因为“未执行 E2E 测试”而给出 request_changes**；若需提示人工验收点，可写在 \`non_blocking_notes\` 中。若目标仓库维护了可复用 QA/E2E 入口，且本 PR 为新增页面流程按仓库 \`REUSE / EXTEND\` 规范对既有入口/驱动做了最小扩展（并通过静态/路由/入口守卫检查），视为合理的测试资产沉淀，**不要将其误判为范围蔓延或要求开发期实跑真实 E2E**。
3.1 **E2E 路由裁定（\`e2e_decision\` 与 \`e2e_decision_reason\`）**（当 \`verdict == "request_changes"\` 时固定输出 \`run_e2e\`；当 \`verdict == "approve"\` 且开启 \`ALLOW_SKIP_E2E=1\` 时决定是否跳过 E2E 直达终审）：
   - \`run_e2e\`（默认保守选项）：涉及运行时代码/接口/数据库/前端交互/运行配置改动，且尚未针对当前运行时行为完成 E2E 验收（或上次 E2E 通过后的新改动影响了运行时行为）。
   - \`skip_not_needed\`：本次整个 PR 仅改动文档（\`docs/\`、\`*.md\`）、注释、纯单元测试、静态检查/格式化或构建元数据，完全不改变运行时行为，或原始 Issue 明确说明无需 E2E。
   - \`skip_already_passed\`：本 PR 或关联 Issue **已经通过过 E2E 验收**（\`has_pass=true\` 且 \`is_ancestor=true\`），且自已通过 E2E 的提交（\`${prior_e2e_sha:-(无)}\`）之后无新增改动或增量改动全部为非运行时改动（文档、单测、命名整理、注释等），不破坏既有 E2E 结论，可直接进入 \`final-gate\` 避免重复 E2E。
4. **严格区分阻塞项与范围外建议（务实分级，禁止范围蔓延）**：
   - 仅将「违反原始 Issue 明确验收标准、真实运行崩溃（如空指针 / \`TypeError\`）、或本次改动引入的真实数据正确性/安全回归、或缺少关键内部单测」列入 \`blocking_issues\` 并返回 \`request_changes\`。
   - **以下情况若认为有参考价值，一律放入 \`non_blocking_notes\`（作为非阻塞项记录），不得阻塞通过**：
     - 超出原始 Issue 范围的延伸需求、次要/极端边缘的 UI 展示优化、仓库历史既有问题或轻微风格建议；
     - 仅在人工伪造非法内部 JSON 结构（例如后端内部契约字段被篡改为非预期类型）或极罕见理论标识符构造下才触发的额外防御；
     - 原始 Issue 未要求的次生状态机改造、非关键 UI 列表刷新优化、既有共用模块历史去重行为调整，以及仅在多重异常/并发叠加（如权限失败 + 定时扫描重叠 + 特定 SQLSTATE 细分）下才触发的极端边缘场景（可留待终审合入后沉淀为独立 Follow-up Issue）。
5. **复审硬性收敛门禁（第 2 轮及以上，务必严格执行）**：
   - **限定复审范围**：第 2 轮及以后复审只核验两件事：① 上一轮列出的阻塞问题是否已实质修复；② 本轮增量变更是否引入新的运行崩溃、明显逻辑错误或对原始 Issue 核心验收标准的回归。
   - **严禁“防御套娃”与移动球门**：当上一轮阻塞项已实质关闭、且原始 Issue 核心验收标准已满足时，**禁止针对开发按上一轮意见新增的降级/错误/防御代码继续深挖二阶、三阶极端边界并追加新的 \`blocking_issues\`**。此类有价值的次生发现一律写入 \`non_blocking_notes\`（终审合入时可自动建后续追踪 Issue）并给出 \`verdict: "approve"\`，让 PR 进入真实 E2E 验收。
   - **终轮务实放行**：若已处于最后一轮自动复审（\`cycle_round >= MAX_REVIEW_ROUNDS\` 或 \`current_round >= MAX_TOTAL_REVIEW_ROUNDS\`），且 Issue 核心验收已满足、契约授权已确认、无真实崩溃或核心数据损坏，应果断 \`approve\` 放行进入 E2E。
6. 最终输出必须严格符合提供的 JSON Schema，使用简洁清晰的中文表述。
   - 按根因归并阻塞项，填写唯一且稳定的 \`id\`（小写字母、数字和连字符），并用 \`verification\` 写出覆盖该根因的可验证关闭条件。先与本 PR 历次评审的根因对照。同一根因跨评审周期沿用原 ID，新出现的类型、测试输入、调用方或文件位置作为该项的证据。
   - 通过评审时，用 \`e2e_checks\` 列出本次按 Issue 和现有契约必须实测的场景。每项用一行写清前置条件、操作和预期结果。例如，涉及延续已有数据或运行进度的改动，应说明如何基于真实的已有状态验收。存在必验场景时使用 \`run_e2e\`。无额外必验场景或要求修改时填写空数组。
EOF

  round_effort="$CODEX_REASONING_EFFORT"
  if (( current_round >= 2 )) && [[ -n "$CODEX_REREVIEW_REASONING_EFFORT" ]]; then
    round_effort="$CODEX_REREVIEW_REASONING_EFFORT"
  fi

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
  if [[ -n "$round_effort" ]]; then
    codex_args+=(-c "model_reasoning_effort=\"${round_effort}\"")
  fi
  codex_args+=(-)

  codex_ok=0
  codex_rc=0
  if "$TIMEOUT_BIN" --signal=TERM --kill-after=30s "$CODEX_TIMEOUT" "${CODEX_CMD[@]}" "${codex_args[@]}" < "$prompt_file" > "$events_file"; then
    if [[ -s "$verdict_file" ]] && "$JQ_BIN" -e -L "$SCRIPT_DIR" '
      include "workflow-e2e";
      (.blocking_issues | type == "array")
      and (.e2e_checks | valid_e2e_checks)
      and (.requires_human_decision | type == "boolean")
      and ([.blocking_issues[].id] | all(type == "string" and test("^[a-z0-9][a-z0-9-]*$")) and length == (unique | length))
      and (.blocking_issues | all(.verification | nonblank))
      and ((.verdict == "approve" and (.requires_human_decision | not) and (.blocking_issues | length == 0))
        or (.verdict == "request_changes" and (.blocking_issues | length > 0) and (.e2e_checks | length == 0)))
    ' "$verdict_file" >/dev/null 2>&1; then
      codex_ok=1
    fi
  else
    codex_rc=$?
  fi

  if (( codex_ok == 0 )); then
    if (( codex_rc == 124 )); then
      printf '[%s] 警告：Codex 评审 PR #%s 超时（上限 %s，日志：%s），%ss 后重试...\n' \
        "$("$DATE_BIN" '+%F %T')" "$pr_num" "$CODEX_TIMEOUT" "$events_file" "$POLL_INTERVAL" >&2
    else
      printf '[%s] 警告：Codex 评审 PR #%s 失败或输出不符合 Schema（exit=%d，未记录该 SHA，日志：%s），%ss 后重试...\n' \
        "$("$DATE_BIN" '+%F %T')" "$pr_num" "$codex_rc" "$events_file" "$POLL_INTERVAL" >&2
    fi
    "$SLEEP_BIN" "$POLL_INTERVAL"
    continue
  fi

  verdict="$("$JQ_BIN" -r '.verdict' "$verdict_file")"
  raw_e2e_decision="$("$JQ_BIN" -r '.e2e_decision // "run_e2e"' "$verdict_file")"
  e2e_decision_reason="$("$JQ_BIN" -r '.e2e_decision_reason // ""' "$verdict_file")"
  final_pr_state=""
  extra_notice=""
  effective_e2e_decision="run_e2e"
  e2e_reused_sha=""
  e2e_downgrade_note=""
  repeat_blockers="$("$JQ_BIN" -r --argjson history "$blocker_history" '
    [.blocking_issues[].id | select(. as $id | ($history[$id].review_keys // [] | length) >= 2)] | join(", ")
  ' "$verdict_file")"

  new_consecutive_rejections=0
  if [[ "$verdict" == "approve" ]]; then
    new_consecutive_rejections=0
    effective_e2e_decision="$raw_e2e_decision"
    if "$JQ_BIN" -e '.e2e_checks | length > 0' "$verdict_file" >/dev/null; then
      effective_e2e_decision="run_e2e"
      e2e_downgrade_note="（本轮评审列出必验场景）"
    elif [[ "$ALLOW_SKIP_E2E" != "1" ]]; then
      effective_e2e_decision="run_e2e"
    elif [[ "$effective_e2e_decision" == "skip_already_passed" ]]; then
      if [[ "$prior_e2e_has_pass" == "true" && "$prior_e2e_is_ancestor" == "true" && -n "$prior_e2e_sha" ]]; then
        e2e_reused_sha="$prior_e2e_sha"
      else
        effective_e2e_decision="run_e2e"
        e2e_downgrade_note="（安全回退：未查到作为当前提交祖先的已通过 E2E 证据，仍需执行 E2E）"
      fi
    fi

    if [[ "$effective_e2e_decision" == "skip_not_needed" || "$effective_e2e_decision" == "skip_already_passed" ]]; then
      final_pr_state="e2e-skipped"
    else
      final_pr_state="approved"
    fi
  else
    new_consecutive_rejections="$cycle_round"
    if "$JQ_BIN" -e '.requires_human_decision' "$verdict_file" >/dev/null; then
      final_pr_state="blocked"
      extra_notice=$'\n\n'"> 本轮有变更现有契约的事项待人工授权。暂停自动返工。"
    elif [[ -n "$repeat_blockers" ]]; then
      final_pr_state="blocked"
      extra_notice=$'\n\n'"> 同一阻塞根因已在本 PR 的至少三轮评审中出现（${repeat_blockers}）。暂停自动返工，等待确认范围、修法或关闭条件。"
    elif (( cycle_round >= MAX_REVIEW_ROUNDS )); then
      final_pr_state="blocked"
      extra_notice=$'\n\n'"> ⚠️ 已达到最大连续评审打回轮次（连续 ${cycle_round} / ${MAX_REVIEW_ROUNDS} 轮，累计第 ${current_round} / ${MAX_TOTAL_REVIEW_ROUNDS} 轮），状态已切为 \`${LABEL_PREFIX}blocked\`，请人工介入裁决。"
    elif (( current_round >= MAX_TOTAL_REVIEW_ROUNDS )); then
      final_pr_state="blocked"
      extra_notice=$'\n\n'"> ⚠️ 已达到单 PR 最大总评审轮次上限（累计 ${current_round} / ${MAX_TOTAL_REVIEW_ROUNDS} 轮），状态已切为 \`${LABEL_PREFIX}blocked\`，请人工介入裁决。"
    else
      final_pr_state="changes-requested"
    fi
  fi

  review_md="$(render_review_markdown "$verdict_file" "$pr_num" "$issue_num" "$head_sha" "$current_round" "$final_pr_state" "$effective_e2e_decision" "$e2e_reused_sha" "$e2e_downgrade_note" "$round_effort" "$cycle_round")${extra_notice}"
  printf '%s\n' "$review_md" > "$comment_file"

  iso_now="$("$DATE_BIN" --iso-8601=seconds)"
  "$JQ_BIN" -n \
    --arg review_key "$review_key" \
    --rawfile comment "$comment_file" \
    --slurpfile review "$verdict_file" \
    --argjson elapsed "$((SECONDS - task_start_sec))" \
    --argjson pr_number "$pr_num" \
    --arg issue_number "$issue_num" \
    --arg pr_url "$pr_url" \
    --arg head_branch "$head_branch" \
    --arg base_branch "$base_branch" \
    --arg head_sha "$head_sha" \
    --arg model "$CODEX_MODEL" \
    --arg reasoning_effort "$round_effort" \
    --argjson round "$current_round" \
    --argjson cycle_round "$cycle_round" \
    --argjson consecutive_rejections "$new_consecutive_rejections" \
    --argjson max_total_rounds "$MAX_TOTAL_REVIEW_ROUNDS" \
    --arg verdict "$verdict" \
    --arg e2e_decision "$effective_e2e_decision" \
    --arg e2e_decision_reason "${e2e_decision_reason}${e2e_downgrade_note}" \
    --arg e2e_reused_sha "$e2e_reused_sha" \
    --arg final_state "$final_pr_state" \
    --arg updated_at "$iso_now" \
    '{
      review_key: $review_key,
      comment: $comment,
      review: $review[0],
      elapsed: $elapsed,
      pr_comment_written: false,
      pr_state_written: false,
      issue_comment_written: false,
      meta: {
        pr_number: $pr_number,
        issue_number: $issue_number,
        pr_url: $pr_url,
        head_branch: $head_branch,
        base_branch: $base_branch,
        head_sha: $head_sha,
        model: $model,
        reasoning_effort: $reasoning_effort,
        round: $round,
        cycle_round: $cycle_round,
        consecutive_rejections: $consecutive_rejections,
        max_total_rounds: $max_total_rounds,
        verdict: $verdict,
        e2e_decision: $e2e_decision,
        e2e_decision_reason: $e2e_decision_reason,
        e2e_reused_sha: $e2e_reused_sha,
        final_state: $final_state,
        updated_at: $updated_at
      }
    }' > "${pending_file}.tmp"
  "$MV_BIN" "${pending_file}.tmp" "$pending_file"
  retry_review_handoff "$pending_file"
done
