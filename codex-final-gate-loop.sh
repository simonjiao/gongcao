#!/usr/bin/bash
set -euo pipefail

# 独立 Codex 终审合入门禁循环（Final Gate / Release Reviewer，默认 gpt-6.2-sol + xhigh，read-only）
# 监听带 agy:e2e-passed 标签的 Open PR，进行「Issue 需求 + 最终代码 + 远端 QA 证据 + CI/合并状态」
# 四位一体终审对账：
#   - merge           -> 更新规范 PR 标题/正文 -> 发布终审签核评论 -> Draft 转 Ready -> 自动合并（AUTO_MERGE=1, MERGE_METHOD=merge）-> 标 agy:done
#   - request_changes -> 发布终审问题清单 -> PR 与关联 Issue 切 agy:changes-requested（超限切 blocked）
#   - blocked         -> 切 agy:blocked 交人工裁决

SCRIPT_DIR="$(cd -- "$([[ "${BASH_SOURCE[0]}" == */* ]] && printf '%s' "${BASH_SOURCE[0]%/*}" || printf '.')" && pwd)"
GH_STATE_BIN="${SCRIPT_DIR}/gh-state.sh"

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
FIND_BIN="$(resolve_bin find)"
SORT_BIN="$(resolve_bin sort)"
COMM_BIN="$(resolve_bin comm)"
FLOCK_BIN="$(resolve_bin flock)"
TIMEOUT_BIN="$(resolve_bin timeout)"

# ===== 主工作目录与可调配置 =====
GONGCAO_HOME="${GONGCAO_HOME:-${HOME}/.gongcao}"
REPOS_ROOT="${REPOS_ROOT:-${GONGCAO_HOME}/repos}"
STATE_BASE="${STATE_BASE:-${GONGCAO_HOME}/state}"

REPO="${REPO:-}"                             # 目标 GitHub 仓库 "owner/repo"
REPO_NAME="${REPO_NAME:-}"                   # 可选：~/.gongcao/repos/<REPO_NAME>
REPO_DIR="${REPO_DIR:-}"                     # 可选：显式本地仓库路径
AUTO_CLONE="${AUTO_CLONE:-1}"
LABEL_PREFIX="${LABEL_PREFIX:-agy:}"
FINAL_GATE_LABEL="${FINAL_GATE_LABEL:-${LABEL_PREFIX}e2e-passed}" # 默认监听 E2E 通过的 PR
FINAL_GATE_COMMENT_MARKER="${FINAL_GATE_COMMENT_MARKER:-<!-- codex-final-gate-comment -->}"
E2E_COMMENT_MARKER="${E2E_COMMENT_MARKER:-<!-- codex-e2e-comment -->}"
REVIEW_COMMENT_MARKER="${REVIEW_COMMENT_MARKER:-<!-- codex-review-comment -->}"
E2E_EVIDENCE_BRANCH="${E2E_EVIDENCE_BRANCH:-qa/e2e-evidence}"
CODEX_MODEL="${CODEX_MODEL:-gpt-6.2-sol}"
CODEX_REASONING_EFFORT="${CODEX_REASONING_EFFORT:-xhigh}"
CODEX_SANDBOX="${CODEX_SANDBOX:-read-only}"
CODEX_TIMEOUT="${CODEX_TIMEOUT:-15m}"
AUTO_MERGE="${AUTO_MERGE:-1}"                # 1=终审通过后自动转 Ready 并合并；0=仅更新信息并标 agy:ready-to-merge
MERGE_METHOD="${MERGE_METHOD:-merge}"        # 首选默认合并方式: merge | squash | rebase（默认保留 merge commit）
FINAL_GATE_JUDGE_MERGE_METHOD="${FINAL_GATE_JUDGE_MERGE_METHOD:-1}" # 1=由终审结合仓库策略、提交拓扑与冲突演练裁定合并方式；0=强制使用 MERGE_METHOD
REQUIRE_EVIDENCE_SHA_MATCH="${REQUIRE_EVIDENCE_SHA_MATCH:-1}" # 1=硬校验远端证据 tested_sha == head_sha
REQUIRE_CI_PASS="${REQUIRE_CI_PASS:-1}"      # 1=硬校验 CI 无失败且无进行中检查
MAX_DIFF_BYTES="${MAX_DIFF_BYTES:-60000}"
MAX_FINAL_ROUNDS="${MAX_FINAL_ROUNDS:-2}"    # 终审最大打回轮次，超过切 blocked
AUTO_REQUEUE_ISSUE="${AUTO_REQUEUE_ISSUE:-1}"
INIT_LABELS="${INIT_LABELS:-1}"
PR_LIMIT="${PR_LIMIT:-20}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
MAX_BACKOFF="${MAX_BACKOFF:-900}"
DRY_RUN="${DRY_RUN:-0}"

"$MKDIR_BIN" -p "$GONGCAO_HOME" "$REPOS_ROOT" "$STATE_BASE"

# 定位目标仓库目录
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
FINAL_ROOT="${FINAL_ROOT:-${STATE_ROOT}/final-gate}"
REPO_GIT_LOCK="${STATE_ROOT}/repo-git.lock"

"$MKDIR_BIN" -p "$STATE_ROOT" "$WORKTREE_ROOT" "$FINAL_ROOT"
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

printf '[%s] 启动 codex-final-gate-loop\n' "$("$DATE_BIN" '+%F %T')"
printf '  Codex 命令 : %s (model=%s, effort=%s, sandbox=%s, timeout=%s)\n' \
  "$CODEX_BIN" "${CODEX_MODEL:-(codex 默认)}" "${CODEX_REASONING_EFFORT:-(默认)}" "$CODEX_SANDBOX" "$CODEX_TIMEOUT"
printf '  工作主目录 : %s\n' "$GONGCAO_HOME"
printf '  主仓库目录 : %s\n' "$REPO_ROOT"
printf '  终审档案根 : %s\n' "$FINAL_ROOT"
printf '  合入策略   : AUTO_MERGE=%s, 默认MERGE_METHOD=%s, 终审裁定方式=%s, REQUIRE_SHA=%s, REQUIRE_CI=%s, DRY_RUN=%s\n' \
  "$AUTO_MERGE" "$MERGE_METHOD" "$FINAL_GATE_JUDGE_MERGE_METHOD" "$REQUIRE_EVIDENCE_SHA_MATCH" "$REQUIRE_CI_PASS" "$DRY_RUN"
printf '  监听标签   : %s (证据分支=%s, MAX_FINAL_ROUNDS=%s)\n' \
  "$FINAL_GATE_LABEL" "$E2E_EVIDENCE_BRANCH" "$MAX_FINAL_ROUNDS"

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

write_final_gate_schema() {
  local schema_file="$1"
  "$CAT_BIN" > "$schema_file" <<'EOF'
{
  "type": "object",
  "additionalProperties": false,
  "required": [
    "verdict",
    "summary",
    "merge_method",
    "merge_method_reason",
    "audit_checks",
    "pr_title",
    "pr_body",
    "issue_closing_note",
    "blocking_issues",
    "non_blocking_notes"
  ],
  "properties": {
    "verdict": {
      "type": "string",
      "enum": ["merge", "request_changes", "blocked"]
    },
    "summary": { "type": "string" },
    "merge_method": {
      "type": "string",
      "enum": ["merge", "squash", "rebase"]
    },
    "merge_method_reason": { "type": "string" },
    "audit_checks": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["check", "status", "evidence"],
        "properties": {
          "check": { "type": "string" },
          "status": { "type": "string", "enum": ["pass", "fail", "warn"] },
          "evidence": { "type": "string" }
        }
      }
    },
    "pr_title": { "type": "string" },
    "pr_body": { "type": "string" },
    "issue_closing_note": { "type": "string" },
    "blocking_issues": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["severity", "category", "location", "description", "suggestion"],
        "properties": {
          "severity": { "type": "string", "enum": ["critical", "major"] },
          "category": { "type": "string", "enum": ["code", "qa_evidence", "issue_gap", "security_redaction", "ci_or_merge"] },
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

prepare_final_worktree() {
  local pr_num="$1"
  local head_branch="$2"
  local head_sha="$3"
  local wt_dir="${WORKTREE_ROOT}/final-pr-${pr_num}"

  (
    "$FLOCK_BIN" -x 9
    "$GIT_BIN" -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true
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
  ) 9>"$REPO_GIT_LOCK"

  printf '%s' "$wt_dir"
}

# 只读检出远端 QA 证据分支最新快照，返回 <ev_wt>\t<ev_branch_sha>
prepare_evidence_checkout() {
  local ev_wt="${WORKTREE_ROOT}/final-evidence"
  local ev_sha=""

  (
    "$FLOCK_BIN" -x 9
    "$GIT_BIN" -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true
    "$GIT_BIN" -C "$REPO_ROOT" fetch origin "$E2E_EVIDENCE_BRANCH" >/dev/null 2>&1 || true

    if "$GIT_BIN" -C "$REPO_ROOT" show-ref --verify --quiet "refs/remotes/origin/${E2E_EVIDENCE_BRANCH}"; then
      if [[ -e "${ev_wt}/.git" ]]; then
        "$GIT_BIN" -C "$ev_wt" checkout --detach --force "origin/${E2E_EVIDENCE_BRANCH}" >/dev/null 2>&1
        "$GIT_BIN" -C "$ev_wt" clean -fd >/dev/null 2>&1 || true
      else
        "$GIT_BIN" -C "$REPO_ROOT" worktree add --detach "$ev_wt" "origin/${E2E_EVIDENCE_BRANCH}" >/dev/null 2>&1
      fi
    fi
  ) 9>"$REPO_GIT_LOCK"

  if [[ -e "${ev_wt}/.git" ]]; then
    ev_sha="$("$GIT_BIN" -C "$ev_wt" rev-parse HEAD 2>/dev/null || true)"
    printf '%s\t%s\n' "$ev_wt" "$ev_sha"
  fi
}

# 确定性本地 Git 合并演练与拓扑检查（无副作用，不修改工作区）
# 参数: <base_branch> <head_sha> [do_fetch=0|1]
# 输出 JSON: {status, behind_count, ahead_count, merge_commit_count, conflict_files, conflict_detail, overlap_files, base_commits, pr_commits}
inspect_git_merge_state() {
  local base_branch="$1"
  local head_sha="$2"
  local do_fetch="${3:-0}"
  local base_ref="origin/${base_branch}"

  local mt_status="unknown"
  local behind_count=0
  local ahead_count=0
  local merge_commit_count=0
  local conflict_files=""
  local conflict_detail=""
  local overlap_files=""
  local base_commits=""
  local pr_commits=""

  (
    "$FLOCK_BIN" -x 9
    if [[ "$do_fetch" == "1" ]]; then
      "$GIT_BIN" -C "$REPO_ROOT" fetch --prune origin "$base_branch" >/dev/null 2>&1 || true
    fi

    if "$GIT_BIN" -C "$REPO_ROOT" rev-parse --verify --quiet "${base_ref}^{commit}" >/dev/null \
      && "$GIT_BIN" -C "$REPO_ROOT" rev-parse --verify --quiet "${head_sha}^{commit}" >/dev/null; then
      behind_count="$("$GIT_BIN" -C "$REPO_ROOT" rev-list --count "${head_sha}..${base_ref}" 2>/dev/null || printf '0')"
      ahead_count="$("$GIT_BIN" -C "$REPO_ROOT" rev-list --count "${base_ref}..${head_sha}" 2>/dev/null || printf '0')"
      merge_commit_count="$("$GIT_BIN" -C "$REPO_ROOT" rev-list --merges --count "${base_ref}..${head_sha}" 2>/dev/null || printf '0')"

      local mt_out="" mt_rc=0
      if mt_out="$("$GIT_BIN" -C "$REPO_ROOT" merge-tree --write-tree --name-only "$base_ref" "$head_sha" 2>&1)"; then
        mt_status="clean"
      else
        mt_rc=$?
        if (( mt_rc == 1 )); then
          mt_status="conflict"
          local _seen_tree=0 _in_files=1 _line=""
          while IFS= read -r _line; do
            if (( _seen_tree == 0 )); then
              _seen_tree=1
              continue
            fi
            if (( _in_files == 1 )); then
              if [[ -z "$_line" ]]; then
                _in_files=0
              else
                conflict_files+="${_line}"$'\n'
              fi
            else
              conflict_detail+="${_line}"$'\n'
            fi
          done <<<"$mt_out"
        else
          mt_status="unknown"
          conflict_detail="$mt_out"
        fi
      fi

      local mb=""
      mb="$("$GIT_BIN" -C "$REPO_ROOT" merge-base "$base_ref" "$head_sha" 2>/dev/null || true)"
      if [[ -n "$mb" && "$behind_count" =~ ^[0-9]+$ ]] && (( behind_count > 0 )); then
        local base_files="" pr_files=""
        base_files="$("$GIT_BIN" -C "$REPO_ROOT" diff --name-only "${mb}..${base_ref}" 2>/dev/null | "$SORT_BIN" -u || true)"
        pr_files="$("$GIT_BIN" -C "$REPO_ROOT" diff --name-only "${mb}..${head_sha}" 2>/dev/null | "$SORT_BIN" -u || true)"
        if [[ -n "$base_files" && -n "$pr_files" ]]; then
          overlap_files="$("$COMM_BIN" -12 <(printf '%s\n' "$base_files") <(printf '%s\n' "$pr_files") || true)"
        fi
        base_commits="$("$GIT_BIN" -C "$REPO_ROOT" log --oneline -n 15 "${head_sha}..${base_ref}" 2>/dev/null || true)"
      fi
      pr_commits="$("$GIT_BIN" -C "$REPO_ROOT" log --oneline -n 20 "${base_ref}..${head_sha}" 2>/dev/null || true)"
    fi

    "$JQ_BIN" -n \
      --arg status "$mt_status" \
      --argjson behind_count "${behind_count:-0}" \
      --argjson ahead_count "${ahead_count:-0}" \
      --argjson merge_commit_count "${merge_commit_count:-0}" \
      --arg conflict_files "$conflict_files" \
      --arg conflict_detail "$conflict_detail" \
      --arg overlap_files "$overlap_files" \
      --arg base_commits "$base_commits" \
      --arg pr_commits "$pr_commits" \
      '{
        status: $status,
        behind_count: $behind_count,
        ahead_count: $ahead_count,
        merge_commit_count: $merge_commit_count,
        conflict_files: $conflict_files,
        conflict_detail: $conflict_detail,
        overlap_files: $overlap_files,
        base_commits: $base_commits,
        pr_commits: $pr_commits
      }'
  ) 9>"$REPO_GIT_LOCK"
}

# 校验并修正合并方式：遵守仓库允许的合并策略，且禁止在含 merge commit 的分支上使用 rebase
# 输出: <effective_method>\t<adjustment_note>
resolve_safe_merge_method() {
  local requested="$1"
  local allow_merge="$2"
  local allow_squash="$3"
  local allow_rebase="$4"
  local merge_commit_count="$5"

  local chosen="$requested"
  local note=""

  if [[ "$FINAL_GATE_JUDGE_MERGE_METHOD" != "1" ]]; then
    chosen="$MERGE_METHOD"
  fi

  is_method_usable() {
    case "$1" in
      merge)  [[ "$allow_merge" == "true" ]] ;;
      squash) [[ "$allow_squash" == "true" ]] ;;
      rebase) [[ "$allow_rebase" == "true" ]] && (( merge_commit_count == 0 )) ;;
      *)      return 1 ;;
    esac
  }

  if is_method_usable "$chosen"; then
    printf '%s\t%s\n' "$chosen" ""
    return 0
  fi

  local fallback=""
  local cand
  for cand in "$MERGE_METHOD" merge squash rebase; do
    if is_method_usable "$cand"; then
      fallback="$cand"
      break
    fi
  done

  if [[ -z "$fallback" ]]; then
    printf 'NONE\t仓库设置不允许任何可用的合并方式（allow_merge=%s, allow_squash=%s, allow_rebase=%s, merge_commits=%s）\n' \
      "$allow_merge" "$allow_squash" "$allow_rebase" "$merge_commit_count"
    return 0
  fi

  if [[ "$chosen" == "rebase" ]] && (( merge_commit_count > 0 )); then
    note="分支包含 ${merge_commit_count} 个 merge commit，rebase 不可用，已自动回退为 \`${fallback}\`"
  else
    note="仓库策略不允许 \`${chosen}\`，已自动回退为 \`${fallback}\`"
  fi
  printf '%s\t%s\n' "$fallback" "$note"
}

requeue_for_conflict() {
  local pr_num="$1"
  local issue_num="$2"
  local head_branch="$3"
  local base_branch="$4"
  local title="$5"
  local detail_md="$6"
  local tag="$7"

  local conflict_md
  conflict_md="$("$CAT_BIN" <<EOF
### ${title}

- PR #${pr_num}（\`${head_branch}\` -> \`${base_branch}\`）与目标主干存在合并冲突，无法直接合入。
${detail_md}
- 已将状态退回 \`${LABEL_PREFIX}changes-requested\`，开发循环将自动合入最新 \`${base_branch}\` 解决冲突，并重新走评审与 E2E 验收。
EOF
)"
  printf '%s\n' "$conflict_md" | gh_state comment pr "$pr_num" - "$FINAL_GATE_COMMENT_MARKER" || true
  gh_state set-state pr "$pr_num" changes-requested || true
  if [[ -n "$issue_num" && "$AUTO_REQUEUE_ISSUE" == "1" ]]; then
    gh_state set-state issue "$issue_num" changes-requested || true
    printf '%s\n' "$conflict_md" | gh_state comment issue "$issue_num" - "$FINAL_GATE_COMMENT_MARKER" || true
  fi
  local end_ts
  end_ts="$("$DATE_BIN" '+%F %T')"
  printf '[%s] PR #%s 存在合并冲突（%s），终审已退回 %schanges-requested\n' "$end_ts" "$pr_num" "$tag" "$LABEL_PREFIX"
  printf '[%s] [codex-final-gate] PR #%s (Issue #%s) -> %s\n' \
    "$end_ts" "$pr_num" "${issue_num:-?}" "$tag" >> "$ACTIVITY_LOG"
}

render_final_gate_markdown() {
  local decision_file="$1"
  local pr_num="$2"
  local issue_num="$3"
  local head_sha="$4"
  local round="$5"
  local final_action="$6"
  local evidence_url="$7"
  local eff_method="$8"
  local now_ts
  now_ts="$("$DATE_BIN" --iso-8601=seconds)"

  "$JQ_BIN" -r \
    --arg pr "$pr_num" \
    --arg issue "${issue_num:-(未关联)}" \
    --arg sha "${head_sha:0:10}" \
    --arg round "$round" \
    --arg max_rounds "$MAX_FINAL_ROUNDS" \
    --arg action "$final_action" \
    --arg ev_url "${evidence_url:-(无远端证据直链)}" \
    --arg eff_method "$eff_method" \
    --arg model "${CODEX_MODEL:-(codex 默认)}${CODEX_REASONING_EFFORT:+ (${CODEX_REASONING_EFFORT})}" \
    --arg now "$now_ts" \
    '
    def esc: tostring | gsub("\n"; " ") | gsub("\\|"; "\\|");
    "### Codex 终审合入门禁报告（Final Gate）\n\n"
    + "| 字段 | 值 |\n| --- | --- |\n"
    + "| 终审结论 | `" + .verdict + "` -> `" + $action + "` |\n"
    + "| 合并方式 | `" + $eff_method + "`（" + ((.merge_method_reason // "默认策略") | esc) + "） |\n"
    + "| 关联 Issue | #" + $issue + " |\n"
    + "| 终审 Commit | `" + $sha + "` |\n"
    + "| 终审轮次 | " + $round + " / " + $max_rounds + " |\n"
    + "| 终审模型 | `" + $model + "` |\n"
    + "| QA 证据归档 | " + $ev_url + " |\n"
    + "| 终审时间 | " + $now + " |\n\n"
    + "#### 终审总结\n" + .summary + "\n\n"
    + "#### 终审核对项（Issue / 代码 / QA 证据 / CI）\n"
    + (if (.audit_checks | length) > 0 then
        "| 核对项 | 状态 | 依据 |\n| --- | --- | --- |\n"
        + ([.audit_checks[] | "| " + (.check | esc) + " | `" + .status + "` | " + (.evidence | esc) + " |"] | join("\n"))
      else
        "- (无逐项记录)"
      end)
    + "\n\n#### 阻塞项\n"
    + (if (.blocking_issues | length) > 0 then
        ([.blocking_issues[] | "- **[" + .severity + "/" + .category + "]** `" + .location + "`：" + .description + "\n  - 建议：" + .suggestion] | join("\n"))
      else
        "- 无阻塞项"
      end)
    + "\n\n#### 非阻塞说明\n"
    + (if (.non_blocking_notes | length) > 0 then
        ([.non_blocking_notes[] | "- " + .] | join("\n"))
      else
        "- 无"
      end)
    ' "$decision_file"
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

  prs_json=""
  if ! prs_json="$(gh_state list-prs open "$FINAL_GATE_LABEL" "$PR_LIMIT")" \
    || ! "$JQ_BIN" -e 'type == "array"' >/dev/null 2>&1 <<<"$prs_json"; then
    consecutive_poll_errors=$((consecutive_poll_errors + 1))
    wait_sec="$(calc_backoff "$consecutive_poll_errors")"
    printf '[%s] 警告：拉取待终审 PR 列表失败（连续第 %d 次），%ss 后重试...\n' \
      "$("$DATE_BIN" '+%F %T')" "$consecutive_poll_errors" "$wait_sec" >&2
    "$SLEEP_BIN" "$wait_sec"
    continue
  fi
  consecutive_poll_errors=0

  # 找出第一条最新 head_sha 尚未终审过的 PR
  next_pr_json=""
  while IFS= read -r row; do
    pnum="$("$JQ_BIN" -r '.number' <<<"$row")"
    psha="$("$JQ_BIN" -r '.headRefOid // empty' <<<"$row")"
    sha_file="${FINAL_ROOT}/pr-${pnum}/checked_shas.txt"
    if [[ -n "$psha" && -f "$sha_file" ]] && "$GREP_BIN" -qx "$psha" "$sha_file"; then
      continue
    fi
    next_pr_json="$row"
    break
  done < <("$JQ_BIN" -c '.[]' <<<"$prs_json")

  if [[ -z "$next_pr_json" ]]; then
    if (( idle_announced == 0 )); then
      printf '[%s] 空闲等待中：暂无待终审合入的 PR（每 %ss 后台轮询一次）...\n' "$("$DATE_BIN" '+%F %T')" "$POLL_INTERVAL"
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
  is_draft="$("$JQ_BIN" -r '.isDraft // false' <<<"$next_pr_json")"
  head_branch="$("$JQ_BIN" -r '.headRefName' <<<"$next_pr_json")"
  base_branch="$("$JQ_BIN" -r '.baseRefName' <<<"$next_pr_json")"
  head_sha="$("$JQ_BIN" -r '.headRefOid' <<<"$next_pr_json")"
  mergeable="$("$JQ_BIN" -r '.mergeable // ""' <<<"$next_pr_json")"
  merge_state="$("$JQ_BIN" -r '.mergeStateStatus // ""' <<<"$next_pr_json")"
  issue_num="$(extract_linked_issue "$pr_body" "$head_branch")"

  # 1. 前置冲突拦截（GitHub 侧状态）
  if [[ "$mergeable" == "CONFLICTING" || "$merge_state" == "DIRTY" ]]; then
    requeue_for_conflict "$pr_num" "$issue_num" "$head_branch" "$base_branch" \
      "Codex 终审门禁前置拦截：存在合并冲突" \
      "- GitHub 合并状态为 \`${mergeable:-CONFLICTING}\` / \`${merge_state:-DIRTY}\`。" \
      "conflict-requeued"
    "$SLEEP_BIN" 5
    continue
  fi

  # 2. 前置检查 CI 状态（若仍有进行中的 Check，稍后重试，避免抢跑）
  ci_pending_count="$("$JQ_BIN" -r '
    [(.statusCheckRollup // [])[] |
      ((.status // .state // "") | ascii_upcase) |
      select(. == "IN_PROGRESS" or . == "QUEUED" or . == "PENDING" or . == "WAITING" or . == "EXPECTED")
    ] | length
  ' <<<"$next_pr_json")"
  ci_failed_list="$("$JQ_BIN" -r '
    [(.statusCheckRollup // [])[] |
      select(
        ((.conclusion // .state // "") | ascii_upcase) as $c |
        ($c == "FAILURE" or $c == "ERROR" or $c == "TIMED_OUT" or $c == "CANCELLED" or $c == "ACTION_REQUIRED" or $c == "STARTUP_FAILURE")
      ) |
      "- " + (.name // .context // "unknown-check") + " (" + (.conclusion // .state // "FAILED") + ")"
    ] | join("\n")
  ' <<<"$next_pr_json")"
  ci_summary_md="$("$JQ_BIN" -r '
    if ((.statusCheckRollup // []) | length) == 0 then
      "- (无 GitHub CI Check 记录)"
    else
      [(.statusCheckRollup // [])[] |
        "- `" + (.name // .context // "check") + "`: status=`" + (.status // .state // "?") + "` conclusion=`" + (.conclusion // .state // "?") + "`"
      ] | join("\n")
    end
  ' <<<"$next_pr_json")"

  if [[ "$REQUIRE_CI_PASS" == "1" ]] && (( ci_pending_count > 0 )); then
    printf '[%s] PR #%s 仍有 %d 个 CI Check 运行中，%ss 后再终审...\n' \
      "$("$DATE_BIN" '+%F %T')" "$pr_num" "$ci_pending_count" "$POLL_INTERVAL"
    "$SLEEP_BIN" "$POLL_INTERVAL"
    continue
  fi

  final_dir="${FINAL_ROOT}/pr-${pr_num}"
  "$MKDIR_BIN" -p "$final_dir"
  sha_file="${final_dir}/checked_shas.txt"
  "$TOUCH_BIN" "$sha_file"

  prev_rounds=0
  while IFS= read -r _line; do
    [[ -n "$_line" ]] && prev_rounds=$((prev_rounds + 1))
  done < "$sha_file"
  current_round=$((prev_rounds + 1))

  run_ts="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
  schema_file="${final_dir}/schema.json"
  prompt_file="${final_dir}/prompt-${run_ts}.md"
  events_file="${final_dir}/events-${run_ts}.jsonl"
  decision_file="${final_dir}/decision-${run_ts}.json"
  comment_file="${final_dir}/final-gate-comment.md"
  updated_pr_body_file="${final_dir}/updated-pr-body-${run_ts}.md"
  meta_file="${final_dir}/meta.json"
  write_final_gate_schema "$schema_file"

  # 3. 准备 PR 代码只读 worktree + 远端 QA 证据分支只读检出
  printf '[%s] 开始 Codex 终审合入核对 PR #%s (Issue #%s, sha=%s, 第 %d/%d 轮)...\n' \
    "$("$DATE_BIN" '+%F %T')" "$pr_num" "${issue_num:-?}" "${head_sha:0:10}" "$current_round" "$MAX_FINAL_ROUNDS"

  if ! final_wt="$(prepare_final_worktree "$pr_num" "$head_branch" "$head_sha")"; then
    printf '[%s] 警告：为 PR #%s 准备终审 worktree 失败，%ss 后重试...\n' \
      "$("$DATE_BIN" '+%F %T')" "$pr_num" "$POLL_INTERVAL" >&2
    "$SLEEP_BIN" "$POLL_INTERVAL"
    continue
  fi

  # 3.1 本地确定性合并演练（git merge-tree）：即便 GitHub mergeable 为 UNKNOWN 也能提前捕获真实冲突
  merge_sim_json="$(inspect_git_merge_state "$base_branch" "$head_sha" 0)"
  mt_status="$("$JQ_BIN" -r '.status // "unknown"' <<<"$merge_sim_json")"
  mt_behind="$("$JQ_BIN" -r '.behind_count // 0' <<<"$merge_sim_json")"
  mt_ahead="$("$JQ_BIN" -r '.ahead_count // 0' <<<"$merge_sim_json")"
  mt_merge_commits="$("$JQ_BIN" -r '.merge_commit_count // 0' <<<"$merge_sim_json")"
  mt_conflict_files="$("$JQ_BIN" -r '.conflict_files // ""' <<<"$merge_sim_json")"
  mt_conflict_detail="$("$JQ_BIN" -r '.conflict_detail // ""' <<<"$merge_sim_json")"
  mt_overlap_files="$("$JQ_BIN" -r '.overlap_files // ""' <<<"$merge_sim_json")"
  mt_base_commits="$("$JQ_BIN" -r '.base_commits // ""' <<<"$merge_sim_json")"
  mt_pr_commits="$("$JQ_BIN" -r '.pr_commits // ""' <<<"$merge_sim_json")"

  if [[ "$mt_status" == "conflict" ]]; then
    conflict_detail_md="- 本地 \`git merge-tree\` 演练发现 PR 最新提交（\`${head_sha:0:10}\`）与 \`origin/${base_branch}\` 存在真实合并冲突："$'\n''```text'$'\n'"${mt_conflict_files}${mt_conflict_detail}"$'\n''```'
    requeue_for_conflict "$pr_num" "$issue_num" "$head_branch" "$base_branch" \
      "Codex 终审门禁前置拦截：本地合并演练检测到冲突" \
      "$conflict_detail_md" \
      "git-merge-tree-conflict"
    "$SLEEP_BIN" 5
    continue
  fi

  # 拉取仓库允许的合并方式配置（失败时默认三者均允许）
  repo_merge_json=""
  if ! repo_merge_json="$(gh_state get-repo-merge-settings 2>/dev/null)" \
    || ! "$JQ_BIN" -e 'type == "object"' >/dev/null 2>&1 <<<"$repo_merge_json"; then
    repo_merge_json='{"allow_merge_commit":true,"allow_squash_merge":true,"allow_rebase_merge":true}'
  fi
  allow_merge_commit="$("$JQ_BIN" -r '.allow_merge_commit' <<<"$repo_merge_json")"
  allow_squash_merge="$("$JQ_BIN" -r '.allow_squash_merge' <<<"$repo_merge_json")"
  allow_rebase_merge="$("$JQ_BIN" -r '.allow_rebase_merge' <<<"$repo_merge_json")"

  ev_wt=""
  ev_branch_sha=""
  ev_entry_dir=""
  ev_entry_rel=""
  ev_manifest_json=""
  ev_result_json=""
  ev_tested_sha=""
  ev_result_verdict=""
  ev_sha_matched=0
  ev_sensitive_files=""
  ev_file_list=""
  ev_web_url=""
  repo_web_base="${pr_url%/pull/*}"

  if ev_out="$(prepare_evidence_checkout)" && [[ -n "$ev_out" ]]; then
    ev_wt="${ev_out%%$'\t'*}"
    ev_branch_sha="${ev_out#*$'\t'}"
    # 优先精确匹配当前 head_sha 的归档目录，否则回退取最新一条归档记录供比对
    for _d in "${ev_wt}/pr-${pr_num}/"*"-${head_sha:0:10}"; do
      [[ -d "$_d" ]] && ev_entry_dir="$_d"
    done
    if [[ -z "$ev_entry_dir" ]]; then
      for _d in "${ev_wt}/pr-${pr_num}/"*; do
        [[ -d "$_d" ]] && ev_entry_dir="$_d"
      done
    fi
    if [[ -n "$ev_entry_dir" && -d "$ev_entry_dir" ]]; then
      ev_entry_rel="${ev_entry_dir#${ev_wt}/}"
      [[ -n "$repo_web_base" && "$repo_web_base" != "$pr_url" && -n "$ev_branch_sha" ]] && \
        ev_web_url="${repo_web_base}/tree/${ev_branch_sha}/${ev_entry_rel}"
      if [[ -f "${ev_entry_dir}/manifest.json" ]]; then
        ev_manifest_json="$("$CAT_BIN" "${ev_entry_dir}/manifest.json")"
        ev_tested_sha="$("$JQ_BIN" -r '.tested_sha // ""' "${ev_entry_dir}/manifest.json" 2>/dev/null || true)"
        ev_result_verdict="$("$JQ_BIN" -r '.verdict // ""' "${ev_entry_dir}/manifest.json" 2>/dev/null || true)"
        [[ "$ev_tested_sha" == "$head_sha" ]] && ev_sha_matched=1
      fi
      if [[ -f "${ev_entry_dir}/result.json" ]]; then
        ev_result_json="$("$CAT_BIN" "${ev_entry_dir}/result.json")"
        _rv="$("$JQ_BIN" -r '.verdict // ""' "${ev_entry_dir}/result.json" 2>/dev/null || true)"
        [[ -n "$_rv" ]] && ev_result_verdict="$_rv"
      fi
      ev_file_list="$("$FIND_BIN" "$ev_entry_dir" -type f | while IFS= read -r _f; do printf '%s\n' "${_f#${ev_entry_dir}/}"; done)"
      ev_sensitive_files="$(printf '%s\n' "$ev_file_list" | "$GREP_BIN" -iE '(^|/)(\.env|secrets\.json|.*\.pem|.*\.key|id_rsa)' || true)"
    fi
  fi

  # 4. 拉取关联 Issue、历史评审与 E2E 评论、以及完整 PR diff
  issue_section="（未识别到关联 Issue）"
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

  prev_review_comment="$(gh_state get-comment pr "$pr_num" "$REVIEW_COMMENT_MARKER" 2>/dev/null || true)"
  prev_e2e_comment="$(gh_state get-comment pr "$pr_num" "$E2E_COMMENT_MARKER" 2>/dev/null || true)"

  pr_diff_raw="$(gh_state get-pr-diff "$pr_num" 2>/dev/null || true)"
  pr_diff_snippet="${pr_diff_raw:0:MAX_DIFF_BYTES}"
  if (( ${#pr_diff_raw} > MAX_DIFF_BYTES )); then
    pr_diff_snippet="${pr_diff_snippet}"$'\n\n'"... (diff 已截断，请在当前只读工作区使用 git diff origin/${base_branch}...HEAD 查看完整变更)"
  fi

  "$CAT_BIN" > "$prompt_file" <<EOF
你是本流水线的**终审合入门禁官（Final Gate / Release Reviewer）**。本 PR 已通过 E2E 验收，请你从发布合入角度，对 **原始 Issue、最终代码、远端 QA 证据、CI 状态与 PR 信息** 做最后一次全面对账，决定是否满足合入要求，并生成最终规范化的 PR 标题、PR 正文与 Issue 收口说明。

## PR 基本信息
- PR: #${pr_num} (${pr_url})
- 当前标题: ${pr_title}
- 分支: \`${head_branch}\` -> \`${base_branch}\`
- 最终 Commit SHA: \`${head_sha}\`
- Draft 状态: \`${is_draft}\`
- 可合并性: \`${mergeable:-UNKNOWN}\` / \`${merge_state:-UNKNOWN}\`
- 终审轮次: 第 ${current_round} / ${MAX_FINAL_ROUNDS} 轮

### 当前 PR 正文
${pr_body:-"(empty)"}

## GitHub CI 状态汇总
${ci_summary_md}
${ci_failed_list:+$'\n'"⚠️ 失败的 CI Checks:"$'\n'"${ci_failed_list}"}

## Git 合并演练与分支拓扑分析
- 默认首选合并方式: \`${MERGE_METHOD}\`（终审裁定开关: \`${FINAL_GATE_JUDGE_MERGE_METHOD}\`）
- 仓库允许的合并方式: \`merge=${allow_merge_commit}\`, \`squash=${allow_squash_merge}\`, \`rebase=${allow_rebase_merge}\`
- 本地 \`git merge-tree\` 合并演练结果: \`${mt_status}\`
- 分支拓扑: 领先 \`origin/${base_branch}\` **${mt_ahead}** 个提交，落后 **${mt_behind}** 个提交，包含 **${mt_merge_commits}** 个 merge commit
- 与 \`origin/${base_branch}\` 同时修改的重叠文件（语义冲突风险提示）:
\`\`\`text
${mt_overlap_files:-"(无重叠文件)"}
\`\`\`
- PR 分支提交列表（\`origin/${base_branch}..HEAD\`）:
\`\`\`text
${mt_pr_commits:-"(空)"}
\`\`\`
${mt_base_commits:+$'\n'"- 目标分支 \`origin/${base_branch}\` 自公共祖先以来的新提交（最多 15 条）:"$'\n''```text'$'\n'"${mt_base_commits}"$'\n''```'}

## 关联 Issue 要求
${issue_section}

## 远端 QA 证据核对结果（分支 \`${E2E_EVIDENCE_BRANCH}\` @ \`${ev_branch_sha:0:10}\`）
- 证据归档目录（本地只读检出）: \`${ev_entry_dir:-(未找到)}\`
- 证据 GitHub 永久直链: ${ev_web_url:-(无)}
- 证据 manifest.tested_sha: \`${ev_tested_sha:-(缺失)}\`（与 PR head_sha 是否严格一致: \`${ev_sha_matched}\`）
- 敏感文件名预检: ${ev_sensitive_files:-"(未发现 secrets.json/.env/.key/.pem 等敏感文件名)"}

### manifest.json
\`\`\`json
${ev_manifest_json:-"{}"}
\`\`\`

### E2E result.json
\`\`\`json
${ev_result_json:-"{}"}
\`\`\`

### 归档文件清单
\`\`\`text
${ev_file_list:-"(空)"}
\`\`\`

## 既有代码评审与 E2E 评论摘录
${prev_review_comment:-"(无代码评审评论)"}

---
${prev_e2e_comment:-"(无 E2E 评论)"}

## 最终 PR Diff 摘录
\`\`\`diff
${pr_diff_snippet:-"(空 diff)"}
\`\`\`

## 终审准则（务必严格遵守）
1. **核对最终代码与 SHA**：当前工作目录是 PR 最新提交（\`${head_sha}\`）的只读检出；尤其重点检查 E2E 打回后新增的修改提交是否干净、无回归、无调试代码残留。同时核对 \`manifest.tested_sha == ${head_sha}\`（若不一致，说明最新代码未经 E2E 复验，不得放行 \`merge\`）。
2. **核对 Issue 与 QA 证据闭环**：按需检查 \`${ev_entry_dir}\` 中的真实日志与报告，确认 Issue 核心验收标准均有真实代码与 QA 证据闭环，且证据目录无敏感凭据泄漏、无未清理临时文件。
3. **核对合并冲突风险并裁定合并方式（\`merge_method\`）**：
   - 若 \`origin/${base_branch}\` 已有新提交（\`behind > 0\`）且与本 PR **修改了重叠文件或关联接口**，务必通过只读 \`git diff\` / \`git log\` 评估是否存在**语义冲突风险**（即便 Git 自动合并不报错，逻辑上也可能互相破坏）；若存在语义冲突风险或主干变更需要重新 E2E 回归，必须输出 \`request_changes\` 要求先同步主干再验证，不得盲目合入。
   - 请结合仓库允许的合并策略、PR 提交历史与冲突风险，裁定最终 \`merge_method\`（\`merge\` / \`squash\` / \`rebase\`）并在 \`merge_method_reason\` 中简明说明理由：
     - 仓库允许且无冲突时，**默认优先使用 \`${MERGE_METHOD}\`**（通常是 \`merge\`，保留分支历史与 merge commit）；
     - **严禁在包含 merge commit（\`merge_commits > 0\`）或存在多提交重放冲突风险的分支上选择 \`rebase\`**；
     - 必须选择仓库允许的合并方式（若 \`merge\` 被禁用则选 \`squash\` 或可用的方式）；若分支经历多轮修补包含大量零碎修复提交且仓库允许 \`squash\`，可在说明理由后选择 \`squash\` 或保持 \`merge\`。
4. **务实终审，拒绝吹毛求疵**：不要为超出 Issue 范围的次要风格或理论边缘输入阻止合入（可写入 \`non_blocking_notes\`）；但凡存在**真实功能缺陷、SHA 未对齐、缺少真实 QA 证据、敏感信息泄漏、语义/合并冲突风险、或 CI 失败**，必须拒绝 \`merge\`：
   - 可通过修改代码/同步主干/补充测试解决的问题 -> 输出 \`request_changes\`；
   - 环境/CI 基础设施异常、证据泄漏需人工清理或需人工决策 -> 输出 \`blocked\`。
5. **生成规范化的最终 PR 信息与 Issue 说明**：
   - \`pr_title\`：简洁清晰、符合仓库提交/PR 风格。
   - \`pr_body\`：完整规范的中文 PR 正文（Markdown），必须包含：① 改动摘要与根因；② 验证范围与结果（区分内部单测与真实 E2E 验收）；③ 固定验收 Commit SHA（\`${head_sha}\`）与远端 QA 证据永久直链（${ev_web_url:-(无)}）；④ 已知限制或未验证项；⑤ 末尾保留 \`Closes #${issue_num:-N}\`（如有关联 Issue）。
   - \`issue_closing_note\`：简明的 Issue 最终收口评论（关联 PR、固定 SHA、QA 证据直链、已知未覆盖项）。
6. 最终输出必须严格符合 JSON Schema。
EOF

  codex_args=(
    exec
    -s "$CODEX_SANDBOX"
    -C "$final_wt"
    --output-schema "$schema_file"
    -o "$decision_file"
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
  codex_rc=0
  if "$TIMEOUT_BIN" --signal=TERM --kill-after=30s "$CODEX_TIMEOUT" "$CODEX_BIN" "${codex_args[@]}" < "$prompt_file" > "$events_file"; then
    if [[ -s "$decision_file" ]] && "$JQ_BIN" -e '.verdict == "merge" or .verdict == "request_changes" or .verdict == "blocked"' "$decision_file" >/dev/null 2>&1; then
      codex_ok=1
    fi
  else
    codex_rc=$?
  fi

  if (( codex_ok == 0 )); then
    if (( codex_rc == 124 )); then
      printf '[%s] 警告：Codex 终审 PR #%s 超时（上限 %s，日志：%s），%ss 后重试...\n' \
        "$("$DATE_BIN" '+%F %T')" "$pr_num" "$CODEX_TIMEOUT" "$events_file" "$POLL_INTERVAL" >&2
    else
      printf '[%s] 警告：Codex 终审 PR #%s 执行异常或输出不符合 Schema（exit=%d，日志：%s），%ss 后重试...\n' \
        "$("$DATE_BIN" '+%F %T')" "$pr_num" "$codex_rc" "$events_file" "$POLL_INTERVAL" >&2
    fi
    "$SLEEP_BIN" "$POLL_INTERVAL"
    continue
  fi

  verdict="$("$JQ_BIN" -r '.verdict' "$decision_file")"
  codex_merge_method="$("$JQ_BIN" -r '.merge_method // ""' "$decision_file")"
  merge_method_reason="$("$JQ_BIN" -r '.merge_method_reason // ""' "$decision_file")"
  new_pr_title="$("$JQ_BIN" -r '.pr_title // ""' "$decision_file")"
  new_pr_body="$("$JQ_BIN" -r '.pr_body // ""' "$decision_file")"
  issue_closing_note="$("$JQ_BIN" -r '.issue_closing_note // ""' "$decision_file")"

  # 4.1 确定性裁定与安全校验最终合并方式（遵守仓库允许策略，禁止对含 merge commit 分支做 rebase）
  resolved_mm_out="$(resolve_safe_merge_method "${codex_merge_method:-$MERGE_METHOD}" "$allow_merge_commit" "$allow_squash_merge" "$allow_rebase_merge" "$mt_merge_commits")"
  effective_merge_method="${resolved_mm_out%%$'\t'*}"
  merge_method_adjust_note="${resolved_mm_out#*$'\t'}"

  # 5. 确定性硬门禁兜底（防止 LLM 误放行）
  hard_gate_errors=""
  if [[ "$verdict" == "merge" ]]; then
    if [[ "$REQUIRE_EVIDENCE_SHA_MATCH" == "1" && "$ev_sha_matched" != "1" ]]; then
      hard_gate_errors+="- 硬门禁拦截：远端 QA 证据 \`tested_sha\` (\`${ev_tested_sha:-缺失}\`) 与 PR 最新 \`head_sha\` (\`${head_sha}\`) 不一致。"$'\n'
    fi
    if [[ "$REQUIRE_EVIDENCE_SHA_MATCH" == "1" && "$ev_result_verdict" != "pass" ]]; then
      hard_gate_errors+="- 硬门禁拦截：远端 QA 证据结论为 \`${ev_result_verdict:-缺失}\`，并非 \`pass\`。"$'\n'
    fi
    if [[ -n "$ev_sensitive_files" ]]; then
      hard_gate_errors+="- 硬门禁拦截：QA 证据目录中检测到疑似敏感文件（\`${ev_sensitive_files}\`），请清理后再合入。"$'\n'
    fi
    if [[ "$REQUIRE_CI_PASS" == "1" && -n "$ci_failed_list" ]]; then
      hard_gate_errors+="- 硬门禁拦截：存在失败的 GitHub CI Checks："$'\n'"${ci_failed_list}"$'\n'
    fi
    if [[ "$effective_merge_method" == "NONE" ]]; then
      hard_gate_errors+="- 硬门禁拦截：${merge_method_adjust_note}"$'\n'
    fi
  fi

  final_action=""
  final_state=""
  extra_notice=""
  merged_ok=0
  record_checked_sha=1

  if [[ -n "$merge_method_adjust_note" && "$effective_merge_method" != "NONE" ]]; then
    extra_notice+=$'\n\n'"> ℹ️ 合并方式安全调整：${merge_method_adjust_note}"
  fi

  if [[ -n "$hard_gate_errors" ]]; then
    final_state="blocked"
    final_action="${LABEL_PREFIX}blocked (hard-gate)"
    extra_notice+=$'\n\n'"#### ⚠️ 确定性硬门禁拦截（未自动合并）"$'\n'"${hard_gate_errors}"
  elif [[ "$verdict" == "merge" ]]; then
    # 合并前最后一次实时拉取 origin/<base_branch> 并重跑 git merge-tree 冲突演练，防止终审期间主干新提交引发冲突
    recheck_conflict=0
    recheck_conflict_md=""
    if [[ "$AUTO_MERGE" == "1" ]]; then
      recheck_json="$(inspect_git_merge_state "$base_branch" "$head_sha" 1)"
      recheck_status="$("$JQ_BIN" -r '.status // "unknown"' <<<"$recheck_json")"
      if [[ "$recheck_status" == "conflict" ]]; then
        recheck_conflict=1
        recheck_files="$("$JQ_BIN" -r '.conflict_files // ""' <<<"$recheck_json")"
        recheck_detail="$("$JQ_BIN" -r '.conflict_detail // ""' <<<"$recheck_json")"
        recheck_conflict_md=$'\n''```text'$'\n'"${recheck_files}${recheck_detail}"$'\n''```'
      fi
    fi

    if (( recheck_conflict == 1 )); then
      final_state="changes-requested"
      final_action="${LABEL_PREFIX}changes-requested (pre-merge-conflict)"
      record_checked_sha=0
      extra_notice+=$'\n\n'"#### ⚠️ 合并前实时冲突复检拦截（未合并）"$'\n'"- 终审期间 \`origin/${base_branch}\` 产生新提交，实时 \`git merge-tree\` 演练发现以下冲突：${recheck_conflict_md}"$'\n'"- 已退回 \`${LABEL_PREFIX}changes-requested\`，交由开发循环自动合入主干解决冲突并复验。"
    else
      # 先更新规范化 PR 标题与最终正文
      [[ -z "$new_pr_title" ]] && new_pr_title="$pr_title"
      if [[ -n "$new_pr_body" ]]; then
        if [[ -n "$issue_num" && "$new_pr_body" != *"Closes #${issue_num}"* ]]; then
          new_pr_body="${new_pr_body}"$'\n\n'"Closes #${issue_num}"
        fi
        printf '%s\n' "$new_pr_body" > "$updated_pr_body_file"
        gh_state update-pr "$pr_num" "$new_pr_title" "$updated_pr_body_file" || true
      fi

      # 若 PR 仍为 Draft，转为 Ready for review
      if [[ "$is_draft" == "true" ]]; then
        gh_state mark-pr-ready "$pr_num" || true
      fi

      if [[ "$AUTO_MERGE" == "1" ]]; then
        merge_err_file="${final_dir}/merge-error-${run_ts}.log"
        if gh_state merge-pr "$pr_num" "$effective_merge_method" "$head_sha" 2>"$merge_err_file"; then
          merged_ok=1
          final_state="done"
          final_action="MERGED (${effective_merge_method}) -> ${LABEL_PREFIX}done"
        else
          merge_err_text="$("$CAT_BIN" "$merge_err_file" 2>/dev/null || true)"
          if "$GREP_BIN" -iqE '(merge conflict|not mergeable|cannot be rebased|head branch was modified|HTTP 405|HTTP 409)' <<<"$merge_err_text"; then
            final_state="changes-requested"
            final_action="${LABEL_PREFIX}changes-requested (merge-api-conflict)"
            record_checked_sha=0
            extra_notice+=$'\n\n'"#### ⚠️ GitHub 合并接口返回冲突/分支已变动（未合并）"$'\n''```text'$'\n'"${merge_err_text:0:2000}"$'\n''```'$'\n'"- 已退回 \`${LABEL_PREFIX}changes-requested\`，请先同步最新主干解决冲突并重新验证。"
          else
            final_state="blocked"
            final_action="${LABEL_PREFIX}blocked (merge-failed)"
            extra_notice+=$'\n\n'"> ⚠️ 终审已通过且 PR 信息已更新，但自动合并（\`${effective_merge_method}\`）失败（可能因分支保护、审批策略或权限限制），已切为 \`${LABEL_PREFIX}blocked\`，请人工检查合并。"$'\n''```text'$'\n'"${merge_err_text:0:2000}"$'\n''```'
          fi
        fi
      else
        final_state="ready-to-merge"
        final_action="${LABEL_PREFIX}ready-to-merge (method=${effective_merge_method}, awaiting manual merge)"
      fi
    fi
  elif [[ "$verdict" == "blocked" ]]; then
    final_state="blocked"
    final_action="${LABEL_PREFIX}blocked"
  else
    if (( current_round >= MAX_FINAL_ROUNDS )); then
      final_state="blocked"
      final_action="${LABEL_PREFIX}blocked (max-rounds)"
      extra_notice+=$'\n\n'"> ⚠️ 已达到终审最大打回轮次（${MAX_FINAL_ROUNDS} 轮），状态已切为 \`${LABEL_PREFIX}blocked\`，请人工介入裁决。"
    else
      final_state="changes-requested"
      final_action="${LABEL_PREFIX}changes-requested"
    fi
  fi

  final_md="$(render_final_gate_markdown "$decision_file" "$pr_num" "$issue_num" "$head_sha" "$current_round" "$final_action" "$ev_web_url" "$effective_merge_method")${extra_notice}"
  printf '%s\n' "$final_md" > "$comment_file"

  # 写回 PR 终审评论与状态
  printf '%s\n' "$final_md" | gh_state comment pr "$pr_num" - "$FINAL_GATE_COMMENT_MARKER" || true
  gh_state set-state pr "$pr_num" "$final_state" || true

  # 同步关联 Issue 评论与状态
  if [[ -n "$issue_num" ]]; then
    issue_comment_md="$final_md"
    if [[ "$final_state" == "done" || "$final_state" == "ready-to-merge" ]] && [[ -n "$issue_closing_note" ]]; then
      issue_comment_md="${final_md}"$'\n\n'"#### Issue 验收收口说明"$'\n'"${issue_closing_note}"
    fi
    if [[ "$final_state" == "done" || "$final_state" == "ready-to-merge" || "$final_state" == "blocked" ]]; then
      gh_state set-state issue "$issue_num" "$final_state" || true
      printf '%s\n' "$issue_comment_md" | gh_state comment issue "$issue_num" - "$FINAL_GATE_COMMENT_MARKER" || true
    elif [[ "$final_state" == "changes-requested" && "$AUTO_REQUEUE_ISSUE" == "1" ]]; then
      gh_state set-state issue "$issue_num" changes-requested || true
      printf '%s\n' "$issue_comment_md" | gh_state comment issue "$issue_num" - "$FINAL_GATE_COMMENT_MARKER" || true
    fi
  fi

  if [[ "$DRY_RUN" != "1" && "$record_checked_sha" == "1" ]]; then
    printf '%s\n' "$head_sha" >> "$sha_file"
  fi

  iso_now="$("$DATE_BIN" --iso-8601=seconds)"
  "$JQ_BIN" -n \
    --argjson pr_number "$pr_num" \
    --arg issue_number "$issue_num" \
    --arg pr_url "$pr_url" \
    --arg head_sha "$head_sha" \
    --arg evidence_url "$ev_web_url" \
    --arg evidence_tested_sha "$ev_tested_sha" \
    --arg model "$CODEX_MODEL" \
    --arg reasoning_effort "$CODEX_REASONING_EFFORT" \
    --argjson round "$current_round" \
    --arg verdict "$verdict" \
    --arg merge_method "$effective_merge_method" \
    --arg merge_method_reason "$merge_method_reason" \
    --arg final_state "$final_state" \
    --argjson merged "$merged_ok" \
    --arg updated_at "$iso_now" \
    '{
      pr_number: $pr_number,
      issue_number: $issue_number,
      pr_url: $pr_url,
      head_sha: $head_sha,
      evidence_url: $evidence_url,
      evidence_tested_sha: $evidence_tested_sha,
      model: $model,
      reasoning_effort: $reasoning_effort,
      round: $round,
      verdict: $verdict,
      merge_method: $merge_method,
      merge_method_reason: $merge_method_reason,
      final_state: $final_state,
      merged: ($merged == 1),
      updated_at: $updated_at
    }' > "$meta_file"

  total_elapsed=$((SECONDS - task_start_sec))
  end_ts="$("$DATE_BIN" '+%F %T')"
  printf '\n============================================================\n'
  printf '[%s] [DONE] PR #%s Codex 终审合入完成 (第 %d/%d 轮, 耗时 %ds)\n' \
    "$end_ts" "$pr_num" "$current_round" "$MAX_FINAL_ROUNDS" "$total_elapsed"
  printf '  终审结果 : %s -> %s (merge_method=%s)\n' "$verdict" "$final_action" "$effective_merge_method"
  printf '  关联Issue: #%s | Commit: %s\n' "${issue_num:-?}" "${head_sha:0:10}"
  [[ -n "$ev_web_url" ]] && printf '  QA 证据  : %s\n' "$ev_web_url"
  printf '  终审报告 : %s\n' "$comment_file"
  printf '============================================================\n\n'
  printf '[%s] [codex-final-gate] PR #%s (Issue #%s, r%d) -> %s (%s, %ds)\n' \
    "$end_ts" "$pr_num" "${issue_num:-?}" "$current_round" "$verdict" "$final_action" "$total_elapsed" >> "$ACTIVITY_LOG"

  "$SLEEP_BIN" 5
done
