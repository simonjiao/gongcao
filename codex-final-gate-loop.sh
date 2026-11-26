#!/usr/bin/bash
set -euo pipefail

# 独立 Codex 终审合入门禁循环（Final Gate / Release Reviewer，默认 gpt-6.2-sol + xhigh，read-only）
# 监听带 agy:e2e-passed 或 agy:e2e-skipped 标签的 Open PR，进行「Issue 需求 + 最终代码 + 远端 QA 证据 + CI/合并状态」
# 四位一体终审对账：
#   - merge           -> 更新规范 PR 标题/正文 -> 发布终审签核评论 -> Draft 转 Ready -> 自动合并（AUTO_MERGE=1, MERGE_METHOD=merge）-> 标 agy:done
#   - require_e2e     -> 免测退回：无需回退开发，直接切 agy:approved 交由 E2E 循环执行实测
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
SHA256SUM_BIN="$(resolve_bin sha256sum)"

# ===== 主工作目录与可调配置 =====
GONGCAO_HOME="${GONGCAO_HOME:-${HOME}/.gongcao}"
REPOS_ROOT="${REPOS_ROOT:-${GONGCAO_HOME}/repos}"
STATE_BASE="${STATE_BASE:-${GONGCAO_HOME}/state}"

# shellcheck source=lib/codex-profile.sh
source "${SCRIPT_DIR}/lib/codex-profile.sh"
# shellcheck source=lib/git-worktree.sh
source "${SCRIPT_DIR}/lib/git-worktree.sh"
init_codex_review_profile "codex-final-gate-loop.sh" "${1:-run}"

REPO="${REPO:-}"                             # 目标 GitHub 仓库 "owner/repo"
REPO_NAME="${REPO_NAME:-}"                   # 可选：~/.gongcao/repos/<REPO_NAME>
REPO_DIR="${REPO_DIR:-}"                     # 可选：显式本地仓库路径
AUTO_CLONE="${AUTO_CLONE:-1}"
LABEL_PREFIX="${LABEL_PREFIX:-agy:}"
FINAL_GATE_LABEL="${FINAL_GATE_LABEL:-}"     # 兼容旧变量；留空时同时监听 e2e-passed 与 e2e-skipped
FINAL_GATE_LABELS="${FINAL_GATE_LABELS:-${FINAL_GATE_LABEL:-${LABEL_PREFIX}e2e-passed,${LABEL_PREFIX}e2e-skipped}}"
FINAL_GATE_COMMENT_MARKER="${FINAL_GATE_COMMENT_MARKER:-<!-- codex-final-gate-comment -->}"
E2E_COMMENT_MARKER="${E2E_COMMENT_MARKER:-<!-- codex-e2e-comment -->}"
REVIEW_COMMENT_MARKER="${REVIEW_COMMENT_MARKER:-<!-- codex-review-comment -->}"
E2E_EVIDENCE_BRANCH="${E2E_EVIDENCE_BRANCH:-qa/e2e-evidence}"
CODEX_MODEL="${CODEX_MODEL:-gpt-6.2-sol}"
CODEX_REASONING_EFFORT="${CODEX_REASONING_EFFORT:-xhigh}"
CODEX_SANDBOX="${CODEX_SANDBOX:-read-only}"
CODEX_TIMEOUT="${CODEX_TIMEOUT:-15m}"
AUTO_MERGE="${AUTO_MERGE:-1}"                # 1=终审通过后自动转 Ready 并合并；0=仅更新信息并标 agy:ready-to-merge
HOLD_MERGE_LABEL="${HOLD_MERGE_LABEL:-${LABEL_PREFIX}hold-merge}" # PR 或关联 Issue 带此标签时宿主机硬拦截转 Ready 与合并
REQUIRE_OWNER_MERGE_APPROVAL="${REQUIRE_OWNER_MERGE_APPROVAL:-0}" # 1=强制所有 PR 均需经身份校验的逐 SHA 评论放行（/approve-merge <sha>）
MERGE_APPROVERS="${MERGE_APPROVERS:-}"       # 可选：逗号分隔的授权放行 GitHub 登录名白名单（留空默认信任 OWNER/MEMBER/COLLABORATOR）
MERGE_METHOD="${MERGE_METHOD:-merge}"        # 首选默认合并方式: merge | squash | rebase（默认保留 merge commit）
FINAL_GATE_JUDGE_MERGE_METHOD="${FINAL_GATE_JUDGE_MERGE_METHOD:-1}" # 1=由终审结合仓库策略、提交拓扑与冲突演练裁定合并方式；0=强制使用 MERGE_METHOD
AUTO_RESOLVE_TRIVIAL_CONFLICT="${AUTO_RESOLVE_TRIVIAL_CONFLICT:-1}" # 1=终审先判断冲突性质，机械/简单冲突直接就地解决并推进合入，仅实质冲突退回开发；0=一律退回
CONFLICT_RESOLVE_TIMEOUT="${CONFLICT_RESOLVE_TIMEOUT:-10m}"
REQUIRE_EVIDENCE_SHA_MATCH="${REQUIRE_EVIDENCE_SHA_MATCH:-1}" # 1=硬校验远端证据 tested_sha == head_sha
REQUIRE_CI_PASS="${REQUIRE_CI_PASS:-1}"      # 1=硬校验 CI 无失败且无进行中检查
MAX_DIFF_BYTES="${MAX_DIFF_BYTES:-60000}"
MAX_FINAL_ROUNDS="${MAX_FINAL_ROUNDS:-3}"    # 终审最大连续打回轮次（merge 后清零，require_e2e/blocked 不计入），超过切 blocked
MAX_TOTAL_FINAL_ROUNDS="${MAX_TOTAL_FINAL_ROUNDS:-6}" # 单 PR 生命周期硬性总终审轮次上限，防止死循环
AUTO_REQUEUE_ISSUE="${AUTO_REQUEUE_ISSUE:-1}"
CREATE_FOLLOWUP_ISSUES="${CREATE_FOLLOWUP_ISSUES:-1}" # 1=合并成功后自动将必要非阻塞项创建为后续追踪 Issue；0=仅保留在评论
MAX_FOLLOWUP_ISSUES="${MAX_FOLLOWUP_ISSUES:-3}"       # 单次合入最多创建的后续追踪 Issue 数量上限（防刷单）
FOLLOWUP_ISSUE_LABELS="${FOLLOWUP_ISSUE_LABELS:-}"    # 可选逗号分隔标签（默认留空，严禁默认附带 agy:todo 以防自举循环）
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
printf '  Codex 配置 : %s\n' "$CODEX_PROFILE_DIR"
printf '  工作主目录 : %s\n' "$GONGCAO_HOME"
printf '  主仓库目录 : %s\n' "$REPO_ROOT"
printf '  终审档案根 : %s\n' "$FINAL_ROOT"
printf '  合入策略   : AUTO_MERGE=%s, HOLD_LABEL=%s, REQUIRE_OWNER_APPROVAL=%s, APPROVERS=%s, 默认MERGE_METHOD=%s, 终审裁定方式=%s, 直接解简单冲突=%s, REQUIRE_SHA=%s, REQUIRE_CI=%s, 后续建单=%s(max=%s), DRY_RUN=%s\n' \
  "$AUTO_MERGE" "$HOLD_MERGE_LABEL" "$REQUIRE_OWNER_MERGE_APPROVAL" "${MERGE_APPROVERS:-(OWNER/MEMBER/COLLABORATOR)}" "$MERGE_METHOD" "$FINAL_GATE_JUDGE_MERGE_METHOD" "$AUTO_RESOLVE_TRIVIAL_CONFLICT" "$REQUIRE_EVIDENCE_SHA_MATCH" "$REQUIRE_CI_PASS" "$CREATE_FOLLOWUP_ISSUES" "$MAX_FOLLOWUP_ISSUES" "$DRY_RUN"
printf '  监听标签   : %s (证据分支=%s, MAX_FINAL_ROUNDS=%s, MAX_TOTAL_FINAL_ROUNDS=%s)\n' \
  "$FINAL_GATE_LABELS" "$E2E_EVIDENCE_BRANCH" "$MAX_FINAL_ROUNDS" "$MAX_TOTAL_FINAL_ROUNDS"

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
    "non_blocking_notes",
    "follow_up_issues"
  ],
  "properties": {
    "verdict": {
      "type": "string",
      "enum": ["merge", "require_e2e", "request_changes", "blocked"]
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
    },
    "follow_up_issues": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["slug", "title", "priority", "reason", "body"],
        "properties": {
          "slug": { "type": "string" },
          "title": { "type": "string" },
          "priority": { "type": "string", "enum": ["P1", "P2", "P3"] },
          "reason": { "type": "string" },
          "body": { "type": "string" }
        }
      }
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
  checkout_exact_pr_worktree "${WORKTREE_ROOT}/final-pr-${pr_num}" "$pr_num" "$head_branch" "$head_sha"
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

write_conflict_triage_schema() {
  local schema_file="$1"
  "$CAT_BIN" > "$schema_file" <<'EOF'
{
  "type": "object",
  "additionalProperties": false,
  "required": ["action", "reason", "resolved_files", "verification_note"],
  "properties": {
    "action": {
      "type": "string",
      "enum": ["resolved", "requeue_dev", "blocked"]
    },
    "reason": { "type": "string" },
    "resolved_files": {
      "type": "array",
      "items": { "type": "string" }
    },
    "verification_note": { "type": "string" }
  }
}
EOF
}

# 终审冲突分诊与就地消解：
# 先在隔离 worktree 执行 git merge --no-commit --no-ff origin/<base_branch>，
# 由 Codex 判断冲突是否可直接处理（相邻新增/import/路由注册/文档/配置等机械冲突）：
#   - 可直接处理 -> 仅在冲突文件就地消解并由宿主机严格校验（无冲突标记、无无关改动、无未追踪文件）后提交并推送合并提交；
#   - 不可直接处理（核心逻辑/契约冲突或会影响 E2E 结论）-> 中止合并，返回 requeue_dev 才转交 agy:changes-requested。
# 输出 JSON: {outcome: "clean"|"resolved"|"dry_run_resolved"|"requeue_dev"|"blocked", new_head_sha, reason, conflict_files, verification_note}
triage_and_resolve_conflict() {
  local pr_num="$1"
  local head_branch="$2"
  local base_branch="$3"
  local head_sha="$4"
  local final_dir="$5"
  local run_ts="$6"
  local stage_tag="$7"

  local resolve_wt="${WORKTREE_ROOT}/final-resolve-pr-${pr_num}"
  local base_ref="origin/${base_branch}"

  emit_triage_json() {
    "$JQ_BIN" -n \
      --arg outcome "$1" \
      --arg new_head_sha "$2" \
      --arg reason "$3" \
      --arg conflict_files "$4" \
      --arg verification_note "$5" \
      '{
        outcome: $outcome,
        new_head_sha: $new_head_sha,
        reason: $reason,
        conflict_files: $conflict_files,
        verification_note: $verification_note
      }'
  }

  abort_resolve_wt() {
    (
      "$FLOCK_BIN" -x 9
      if [[ -e "${resolve_wt}/.git" ]]; then
        "$GIT_BIN" -C "$resolve_wt" merge --abort >/dev/null 2>&1 || true
        "$GIT_BIN" -C "$resolve_wt" reset --hard "$head_sha" >/dev/null 2>&1 || true
        "$GIT_BIN" -C "$resolve_wt" clean -fd >/dev/null 2>&1 || true
      fi
    ) 9>"$REPO_GIT_LOCK"
  }

  local merge_clean=0
  local orig_conflict_files=""
  local conflict_diff_raw=""
  local base_touch_log=""

  (
    "$FLOCK_BIN" -x 9
    "$GIT_BIN" -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true
    "$GIT_BIN" -C "$REPO_ROOT" fetch --prune origin "$base_branch" >&2 || true
    if ! "$GIT_BIN" -C "$REPO_ROOT" cat-file -e "${head_sha}^{commit}" 2>/dev/null; then
      "$GIT_BIN" -C "$REPO_ROOT" fetch origin "pull/${pr_num}/head" >&2 || \
        "$GIT_BIN" -C "$REPO_ROOT" fetch origin "$head_branch" >&2 || true
    fi

    if [[ -e "${resolve_wt}/.git" ]]; then
      "$GIT_BIN" -C "$resolve_wt" merge --abort >/dev/null 2>&1 || true
      "$GIT_BIN" -C "$resolve_wt" checkout --detach --force "$head_sha" >&2
      "$GIT_BIN" -C "$resolve_wt" clean -fd >/dev/null 2>&1 || true
    else
      "$GIT_BIN" -C "$REPO_ROOT" worktree add --detach "$resolve_wt" "$head_sha" >&2
    fi
  ) 9>"$REPO_GIT_LOCK"

  if "$GIT_BIN" -C "$resolve_wt" merge --no-commit --no-ff "$base_ref" >/dev/null 2>&1; then
    merge_clean=1
  fi

  if (( merge_clean == 1 )); then
    abort_resolve_wt
    emit_triage_json "clean" "$head_sha" "实时合并演练无冲突" "" ""
    return 0
  fi

  orig_conflict_files="$("$GIT_BIN" -C "$resolve_wt" diff --name-only --diff-filter=U 2>/dev/null | "$SORT_BIN" -u || true)"
  if [[ -z "$orig_conflict_files" ]]; then
    abort_resolve_wt
    emit_triage_json "requeue_dev" "" "git merge 未能自动合并且未列出明确冲突文件，需开发介入检查" "" ""
    return 0
  fi

  if [[ "$AUTO_RESOLVE_TRIVIAL_CONFLICT" != "1" ]]; then
    abort_resolve_wt
    emit_triage_json "requeue_dev" "" "已关闭终审自动解简单冲突（AUTO_RESOLVE_TRIVIAL_CONFLICT=0）" "$orig_conflict_files" ""
    return 0
  fi

  conflict_diff_raw="$("$GIT_BIN" -C "$resolve_wt" diff 2>/dev/null || true)"
  local conflict_diff_snippet="${conflict_diff_raw:0:30000}"
  base_touch_log="$("$GIT_BIN" -C "$resolve_wt" log --oneline -n 15 "${head_sha}..${base_ref}" 2>/dev/null || true)"

  local triage_schema="${final_dir}/conflict-schema.json"
  local triage_prompt="${final_dir}/conflict-prompt-${stage_tag}-${run_ts}.md"
  local triage_events="${final_dir}/conflict-events-${stage_tag}-${run_ts}.jsonl"
  local triage_decision="${final_dir}/conflict-decision-${stage_tag}-${run_ts}.json"
  write_conflict_triage_schema "$triage_schema"

  "$CAT_BIN" > "$triage_prompt" <<EOF
你是本流水线的 **终审冲突分诊与合并处理官（Final Gate Conflict Resolver）**。
PR #${pr_num}（\`${head_branch}\` @ \`${head_sha:0:10}\` -> \`${base_branch}\`）已通过代码评审与 E2E 验收，但当前与最新 \`${base_ref}\` 演练合并时出现以下冲突。

**核心原则：不要把可直接处理的机械冲突盲目转交 \`changes-requested\` 浪费整轮开发与 E2E 回归；但凡涉及实质逻辑/契约冲突或会使 E2E 结论失效，也绝不可强行凑合。**

## 冲突文件清单（仅限以下文件存在未合并冲突）
\`\`\`text
${orig_conflict_files}
\`\`\`

## 主干 \`${base_ref}\` 新增提交（\`${head_sha:0:10}..${base_ref}\`）
\`\`\`text
${base_touch_log:-"(无)"}
\`\`\`

## 当前冲突片段（git diff）
\`\`\`diff
${conflict_diff_snippet:-"(空)"}
\`\`\`

## 分诊与处理规则（务必严格遵守）
1. **先判断冲突是否属于「可直接处理的简单/机械冲突」**：
   - ✅ **可直接处理（\`action: "resolved"\`）**：
     - 相邻行各自独立新增（如 import/export、路由/菜单/模块注册、配置项、枚举、测试列表、文档/CHANGELOG、锁文件或并列独立代码块）；
     - 保留双方有效改动即可唯一确定结果，**不改变本 PR 的核心业务逻辑，也不影响既有 E2E 验收结论**；
     - 无需修改冲突文件清单以外的任何文件。
   - ❌ **必须转交开发（\`action: "requeue_dev"\`）**：
     - 双方修改了同一段核心业务逻辑、同一函数实现/签名、数据结构、状态机或 API 契约；
     - 消解冲突需要重新设计逻辑、修改非冲突文件、修改测试预期，或会导致既有 E2E 验收失效；
     - 二进制文件冲突或复杂的删改冲突无法明确裁定。
2. **若判定为可直接处理**：
   - 在当前工作区（\`${resolve_wt}\`）**仅编辑上述冲突文件清单中的文件**，彻底消解全部 \`<<<<<<<\` / \`=======\` / \`>>>>>>>\` 冲突标记，完整保留主干与 PR 双方的有效改动；
   - **禁止**修改非冲突文件，**禁止**遗留未追踪临时文件，**禁止**执行 \`git add\` / \`git commit\` / \`git push\`（由外层宿主机校验后统一提交并推送）；
   - 如改动涉及代码文件，可按需运行最小语法/类型检查或相关单测（无需运行 E2E），把检查结果写入 \`verification_note\`；
   - 输出 \`action: "resolved"\`。
3. **若判定为实质性冲突不可直接处理**：
   - 不要强行修改或提交；输出 \`action: "requeue_dev"\`，并在 \`reason\` 中写明具体冲突逻辑与开发处理建议。
4. 最终输出必须严格符合 JSON Schema。
EOF

  printf '[%s] PR #%s (%s) 检测到合并冲突，启动 Codex 终审冲突分诊（判断可直接解决还是退回开发）...\n' \
    "$("$DATE_BIN" '+%F %T')" "$pr_num" "$stage_tag" >&2

  local -a c_args=(
    exec
    -s workspace-write
    -C "$resolve_wt"
    --output-schema "$triage_schema"
    -o "$triage_decision"
    --json
    --color never
  )
  [[ -n "$CODEX_MODEL" ]] && c_args+=(-m "$CODEX_MODEL")
  [[ -n "$CODEX_REASONING_EFFORT" ]] && c_args+=(-c "model_reasoning_effort=\"${CODEX_REASONING_EFFORT}\"")
  c_args+=(-)

  local c_ok=0
  if "$TIMEOUT_BIN" --signal=TERM --kill-after=30s "$CONFLICT_RESOLVE_TIMEOUT" "${CODEX_CMD[@]}" "${c_args[@]}" < "$triage_prompt" > "$triage_events"; then
    if [[ -s "$triage_decision" ]] && "$JQ_BIN" -e '.action == "resolved" or .action == "requeue_dev" or .action == "blocked"' "$triage_decision" >/dev/null 2>&1; then
      c_ok=1
    fi
  fi

  if (( c_ok == 0 )); then
    abort_resolve_wt
    emit_triage_json "requeue_dev" "" "Codex 冲突分诊/消解超时或输出异常，为安全起见转交开发处理" "$orig_conflict_files" ""
    return 0
  fi

  local t_action t_reason t_verify
  t_action="$("$JQ_BIN" -r '.action' "$triage_decision")"
  t_reason="$("$JQ_BIN" -r '.reason // ""' "$triage_decision")"
  t_verify="$("$JQ_BIN" -r '.verification_note // ""' "$triage_decision")"

  if [[ "$t_action" != "resolved" ]]; then
    abort_resolve_wt
    emit_triage_json "$t_action" "" "$t_reason" "$orig_conflict_files" "$t_verify"
    return 0
  fi

  # 宿主机确定性安全校验：
  # 1. 不允许遗留未追踪文件
  local untracked=""
  untracked="$("$GIT_BIN" -C "$resolve_wt" ls-files --others --exclude-standard 2>/dev/null || true)"
  if [[ -n "$untracked" ]]; then
    abort_resolve_wt
    emit_triage_json "requeue_dev" "" "冲突消解校验失败：产生了未追踪文件（${untracked}），已中止并转交开发处理" "$orig_conflict_files" "$t_verify"
    return 0
  fi

  # 2. 不允许修改冲突清单之外的文件
  local wt_modified="" extra_touched=""
  wt_modified="$("$GIT_BIN" -C "$resolve_wt" diff --name-only 2>/dev/null | "$SORT_BIN" -u || true)"
  if [[ -n "$wt_modified" ]]; then
    extra_touched="$("$COMM_BIN" -23 <(printf '%s\n' "$wt_modified") <(printf '%s\n' "$orig_conflict_files") || true)"
    if [[ -n "$extra_touched" ]]; then
      abort_resolve_wt
      emit_triage_json "requeue_dev" "" "冲突消解校验失败：改动超出了冲突文件范围（额外修改：${extra_touched}），不属于机械冲突，已转交开发处理" "$orig_conflict_files" "$t_verify"
      return 0
    fi
  fi

  # 3. 确认每个冲突文件均无残留冲突标记
  local _cf=""
  while IFS= read -r _cf; do
    [[ -z "$_cf" ]] && continue
    if [[ -f "${resolve_wt}/${_cf}" ]]; then
      if "$GREP_BIN" -qE '^(<<<<<<< |=======$|>>>>>>> )' "${resolve_wt}/${_cf}"; then
        abort_resolve_wt
        emit_triage_json "requeue_dev" "" "冲突消解校验失败：文件 ${_cf} 仍残留 Git 冲突标记，已转交开发处理" "$orig_conflict_files" "$t_verify"
        return 0
      fi
    fi
  done <<<"$orig_conflict_files"

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[DRY_RUN] 终审已本地验证可安全消解简单冲突（不执行 commit/push）: %s\n' "$orig_conflict_files" >&2
    abort_resolve_wt
    emit_triage_json "dry_run_resolved" "$head_sha" "$t_reason" "$orig_conflict_files" "$t_verify"
    return 0
  fi

  # 4. 宿主机暂存、提交合并提交并推送到 PR 分支（加 flock）
  local new_sha=""
  local push_ok=0
  local commit_err=""
  (
    "$FLOCK_BIN" -x 9
    while IFS= read -r _cf; do
      [[ -z "$_cf" ]] && continue
      if [[ -e "${resolve_wt}/${_cf}" ]]; then
        "$GIT_BIN" -C "$resolve_wt" add -- "$_cf"
      else
        "$GIT_BIN" -C "$resolve_wt" rm -f -- "$_cf" >/dev/null 2>&1 || true
      fi
    done <<<"$orig_conflict_files"

    local still_unmerged=""
    still_unmerged="$("$GIT_BIN" -C "$resolve_wt" diff --name-only --diff-filter=U 2>/dev/null || true)"
    if [[ -n "$still_unmerged" ]]; then
      printf '仍存在未解决冲突文件: %s\n' "$still_unmerged" >&2
      exit 1
    fi

    "$GIT_BIN" -C "$resolve_wt" commit -m "Merge branch '${base_branch}' into ${head_branch} (final-gate trivial conflict resolution)" >&2
    local committed_sha=""
    committed_sha="$("$GIT_BIN" -C "$resolve_wt" rev-parse HEAD)"
    local parent1=""
    parent1="$("$GIT_BIN" -C "$resolve_wt" rev-parse "${committed_sha}^1")"
    if [[ "$parent1" != "$head_sha" ]]; then
      printf '合并提交父节点校验失败: parent1=%s expected=%s\n' "$parent1" "$head_sha" >&2
      exit 1
    fi

    "$GIT_BIN" -C "$resolve_wt" push origin "HEAD:refs/heads/${head_branch}" >&2
    printf '%s\n' "$committed_sha" > "${final_dir}/.resolved-sha-${stage_tag}-${run_ts}"
  ) 9>"$REPO_GIT_LOCK" && push_ok=1 || commit_err="提交或推送合并提交失败"

  if (( push_ok == 0 )) || [[ ! -s "${final_dir}/.resolved-sha-${stage_tag}-${run_ts}" ]]; then
    abort_resolve_wt
    emit_triage_json "requeue_dev" "" "终审直接消解冲突后${commit_err:-推送失败}（可能远端分支已有新提交），已转交开发处理" "$orig_conflict_files" "$t_verify"
    return 0
  fi

  IFS= read -r new_sha < "${final_dir}/.resolved-sha-${stage_tag}-${run_ts}"
  printf '[%s] PR #%s (%s) 终审已直接消解简单冲突并推送合并提交 %s（原 E2E 提交 %s）\n' \
    "$("$DATE_BIN" '+%F %T')" "$pr_num" "$stage_tag" "${new_sha:0:10}" "${head_sha:0:10}" >&2
  emit_triage_json "resolved" "$new_sha" "$t_reason" "$orig_conflict_files" "$t_verify"
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
    printf '%s\n' "$conflict_md" | gh_state comment issue "$issue_num" - "$FINAL_GATE_COMMENT_MARKER" || true
    gh_state set-state issue "$issue_num" changes-requested || true
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
  local cycle_round="${9:-$round}"
  local now_ts
  now_ts="$("$DATE_BIN" --iso-8601=seconds)"

  "$JQ_BIN" -r \
    --arg pr "$pr_num" \
    --arg issue "${issue_num:-(未关联)}" \
    --arg sha "${head_sha:0:10}" \
    --arg round "$round" \
    --arg cycle_round "$cycle_round" \
    --arg max_rounds "$MAX_FINAL_ROUNDS" \
    --arg max_total_rounds "$MAX_TOTAL_FINAL_ROUNDS" \
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
    + "| 终审轮次 | 本周期 " + $cycle_round + " / " + $max_rounds + "（累计 " + $round + " / " + $max_total_rounds + "） |\n"
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

read_review_handoff() {
  "$JQ_BIN" -eRsc -L "$SCRIPT_DIR" --arg sha "$1" --arg parent "${2:-}" '
    include "workflow-e2e";
    review_metadata | .e2e_checks = approved_e2e_checks($sha; $parent)
  '
}

record_resolved_conflict_sha() {
  local final_dir="$1"
  local new_sha="$2"
  local parent_sha="$3"
  [[ "$DRY_RUN" == "1" || -z "$new_sha" || -z "$parent_sha" || "$new_sha" == "$parent_sha" ]] && return 0
  "$MKDIR_BIN" -p "$final_dir"
  printf '%s\t%s\n' "$new_sha" "$parent_sha" >> "${final_dir}/resolved-conflicts.tsv"
}

lookup_resolved_from_sha() {
  local final_dir="$1"
  local cur_sha="$2"
  local map_file="${final_dir}/resolved-conflicts.tsv"
  [[ -n "$cur_sha" && -f "$map_file" ]] || return 0
  local origin_sha="" hops=0 mapped="" rec_new="" rec_parent="" actual_parent=""
  while (( hops < 5 )); do
    mapped=""
    while IFS=$'\t' read -r rec_new rec_parent; do
      if [[ "$rec_new" == "$cur_sha" && -n "$rec_parent" ]]; then
        mapped="$rec_parent"
      fi
    done < "$map_file"
    [[ -n "$mapped" ]] || break
    actual_parent="$("$GIT_BIN" -C "$REPO_ROOT" rev-parse "${cur_sha}^1" 2>/dev/null || true)"
    [[ "$actual_parent" == "$mapped" ]] || break
    origin_sha="$mapped"
    cur_sha="$mapped"
    hops=$((hops + 1))
  done
  printf '%s' "$origin_sha"
}

# 宿主机逐 PR 合入授权硬门禁：
# 在转 Ready 和执行 merge 前复读 PR 实时 head/labels、检查 HOLD 标签、识别 Issue 明示 Owner 合入保留，
# 并核验评论者身份与绑定当前 SHA（或经证实冲突消解父 SHA）的 /approve-merge <sha> 指令。
evaluate_merge_authorization() {
  local pr_num="$1"
  local expected_sha="$2"
  local resolved_parent_sha="$3"
  local fallback_pr_labels_json="$4"
  local issue_labels_json="$5"
  local issue_title="$6"
  local issue_body="$7"

  local live_pr_json="" pr_labels_json="$fallback_pr_labels_json"
  if live_pr_json="$(gh_state get-pr "$pr_num" 2>/dev/null)" \
    && "$JQ_BIN" -e 'type == "object"' >/dev/null 2>&1 <<<"$live_pr_json"; then
    local live_state="" live_head=""
    live_state="$("$JQ_BIN" -r '.state // ""' <<<"$live_pr_json")"
    live_head="$("$JQ_BIN" -r '.headRefOid // ""' <<<"$live_pr_json")"
    if [[ -n "$live_state" && "$live_state" != "OPEN" ]]; then
      "$JQ_BIN" -cn --arg st "$live_state" '{allowed: false, mode: "pr_not_open", reason: ("PR 当前状态为 " + $st + "，非 OPEN，停止合入。"), approver: ""}'
      return 0
    fi
    if [[ -n "$live_head" && "$live_head" != "$expected_sha" ]]; then
      "$JQ_BIN" -cn --arg live "${live_head:0:10}" --arg exp "${expected_sha:0:10}" \
        '{allowed: false, mode: "head_changed", reason: ("合入前复读发现 PR 最新提交已变为 " + $live + "（与终审提交 " + $exp + " 不一致），已取消合入。"), approver: ""}'
      return 0
    fi
    pr_labels_json="$("$JQ_BIN" -c '[.labels[]?.name // empty]' <<<"$live_pr_json")"
  fi

  # 1. 硬性 HOLD 标签拦截（PR 或关联 Issue 任一存在均阻止转 Ready 与合入）
  if "$JQ_BIN" -e --arg hold "$HOLD_MERGE_LABEL" --argjson ilbls "$issue_labels_json" \
    '((. + $ilbls) | index($hold)) != null' <<<"$pr_labels_json" >/dev/null 2>&1; then
    "$JQ_BIN" -cn --arg hold "$HOLD_MERGE_LABEL" \
      '{allowed: false, mode: "held", reason: ("检测到暂停合入标签 `" + $hold + "`，已保持当前状态并暂停自动转 Ready 与合入。"), approver: ""}'
    return 0
  fi

  # 2. 判断是否需要逐 PR 显式 Owner 授权
  local needs_owner=0 need_reason=""
  if [[ "$REQUIRE_OWNER_MERGE_APPROVAL" == "1" ]]; then
    needs_owner=1
    need_reason="仓库策略 REQUIRE_OWNER_MERGE_APPROVAL=1 要求逐 PR 显式合入授权"
  elif "$GREP_BIN" -iqE '保留给[[:space:]]*Owner|由[[:space:]]*Owner[[:space:]]*(决定|审批|确认).{0,10}(合入|合并)|Owner[[:space:]]+GO.{0,12}(合入|合并)|禁止自动合(入|并)|勿自动合(入|并)|暂不自动合(入|并)|require[sd]?[[:space:]]+owner[[:space:]]+(merge|approval)|hold[[:space:]]+merge' \
    <<<"${issue_title}"$'\n'"${issue_body}"; then
    needs_owner=1
    need_reason="关联 Issue 明确将合入决定保留给 Owner"
  fi

  if (( needs_owner == 0 )); then
    "$JQ_BIN" -cn '{allowed: true, mode: "auto", reason: "", approver: ""}'
    return 0
  fi

  # 3. 核验经身份校验的逐 SHA 放行评论（/approve-merge <sha> 或 OWNER_GO:<sha>）
  local comments_json="[]"
  if ! comments_json="$(gh_state get-pr-comments "$pr_num" 2>/dev/null)" \
    || ! "$JQ_BIN" -e 'type == "array"' >/dev/null 2>&1 <<<"$comments_json"; then
    comments_json="[]"
  fi

  local approver=""
  approver="$("$JQ_BIN" -r \
    --arg sha "$expected_sha" \
    --arg parent "$resolved_parent_sha" \
    --arg allowlist "$MERGE_APPROVERS" '
    def is_authorized($allowed_users):
      if ($allowed_users | length) > 0 then
        ((.author // "" | ascii_downcase) as $a | ($allowed_users | index($a)) != null)
      else
        ((.author_association // "" | ascii_upcase) as $assoc | (["OWNER", "ADMIN", "MAINTAIN", "MEMBER", "COLLABORATOR"] | index($assoc)) != null)
      end;
    def matches_sha($tok; $s; $p):
      ($tok | ascii_downcase) as $t
      | (($t | length) >= 7) and (($s | startswith($t)) or ($p != "" and ($p | startswith($t))));
    ($sha | ascii_downcase) as $s
    | ($parent | ascii_downcase) as $p
    | ($allowlist | split(",") | map(gsub("^\\s+|\\s+$"; "") | ascii_downcase) | map(select(length > 0))) as $allowed_users
    | [
        .[]
        | select(is_authorized($allowed_users))
        | . as $c
        | [($c.body // "") | scan("(?i)(?:^|\\s)(?:/approve-merge|OWNER_GO)[\\s:]+([0-9a-f]{7,40})(?:\\b|$)") | .[0]]
        | select(any(matches_sha(.; $s; $p)))
        | $c.author
      ] | last // empty
  ' <<<"$comments_json" 2>/dev/null || true)"

  if [[ -n "$approver" ]]; then
    "$JQ_BIN" -cn --arg approver "$approver" --arg reason "$need_reason" \
      '{allowed: true, mode: "owner_approved", reason: ($reason + "，已核验 @" + $approver + " 对当前提交的显式放行。"), approver: $approver}'
    return 0
  fi

  "$JQ_BIN" -cn --arg reason "$need_reason" --arg pr "$pr_num" --arg sha "$expected_sha" --arg lbl "${LABEL_PREFIX}e2e-passed" \
    '{allowed: false, mode: "awaiting_owner_approval", reason: ($reason + "，尚未检测到经身份校验且绑定提交 `" + $sha + "` 的放行指令。请由 Owner/维护者在 PR #" + $pr + " 评论 `/approve-merge " + $sha + "` 后切回 `" + $lbl + "` 放行。"), approver: ""}'
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

  prs_json="[]"
  poll_failed=0
  _prs_chunks=""
  IFS=',' read -r -a _fg_labels <<<"$FINAL_GATE_LABELS"
  for _fg_lbl in "${_fg_labels[@]}"; do
    _fg_lbl="${_fg_lbl#"${_fg_lbl%%[![:space:]]*}"}"
    _fg_lbl="${_fg_lbl%"${_fg_lbl##*[![:space:]]}"}"
    [[ -z "$_fg_lbl" ]] && continue
    _one_prs=""
    if ! _one_prs="$(gh_state list-prs open "$_fg_lbl" "$PR_LIMIT")" \
      || ! "$JQ_BIN" -e 'type == "array"' >/dev/null 2>&1 <<<"$_one_prs"; then
      poll_failed=1
      break
    fi
    _prs_chunks+="${_one_prs}"$'\n'
  done
  if (( poll_failed == 0 )) && [[ -n "$_prs_chunks" ]]; then
    if ! prs_json="$("$JQ_BIN" -s 'add | unique_by(.number)' <<<"$_prs_chunks" 2>/dev/null)"; then
      poll_failed=1
    fi
  fi

  if (( poll_failed == 1 )) || ! "$JQ_BIN" -e 'type == "array"' >/dev/null 2>&1 <<<"$prs_json"; then
    consecutive_poll_errors=$((consecutive_poll_errors + 1))
    wait_sec="$(calc_backoff "$consecutive_poll_errors")"
    printf '[%s] 警告：拉取待终审 PR 列表失败（连续第 %d 次），%ss 后重试...\n' \
      "$("$DATE_BIN" '+%F %T')" "$consecutive_poll_errors" "$wait_sec" >&2
    "$SLEEP_BIN" "$wait_sec"
    continue
  fi
  consecutive_poll_errors=0

  # 按 PR 编号选取尚未针对当前提交和必验场景终审的 PR。
  next_pr_json=""
  while IFS= read -r row; do
    pnum="$("$JQ_BIN" -r '.number' <<<"$row")"
    psha="$("$JQ_BIN" -r '.headRefOid // empty' <<<"$row")"
    sha_file="${FINAL_ROOT}/pr-${pnum}/checked_shas.txt"
    last_checked_key=""
    review_comment_loaded=0
    if [[ -n "$psha" && -f "$sha_file" ]]; then
      while IFS= read -r recorded_key; do
        if [[ "${recorded_key%%:*}" == "$psha" ]]; then
          last_checked_key="$recorded_key"
        fi
      done < "$sha_file"
    fi
    if [[ -n "$last_checked_key" ]] && prev_review_comment="$(gh_state get-comment pr "$pnum" "$REVIEW_COMMENT_MARKER")"; then
      review_comment_loaded=1
      poll_parent_sha="$(lookup_resolved_from_sha "${FINAL_ROOT}/pr-${pnum}" "$psha")"
      if handoff="$(read_review_handoff "$psha" "$poll_parent_sha" <<<"$prev_review_comment" 2>/dev/null)"; then
        checks="$("$JQ_BIN" -c '.e2e_checks' <<<"$handoff")"
        checked_key="$psha"
        if [[ "$checks" != "[]" ]]; then
          digest="$(printf '%s' "$checks" | "$SHA256SUM_BIN")"
          checked_key+=":${digest%% *}"
        fi
        if [[ "$checked_key" == "$last_checked_key" ]]; then
          continue
        fi
      fi
    fi
    next_pr_json="$row"
    break
  done < <("$JQ_BIN" -c 'sort_by(.number) | .[]' <<<"$prs_json")

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
  pr_is_e2e_skipped="$("$JQ_BIN" -r --arg skip_lbl "${LABEL_PREFIX}e2e-skipped" --arg pass_lbl "${LABEL_PREFIX}e2e-passed" \
    'if any(.labels[]?.name; . == $skip_lbl) and (any(.labels[]?.name; . == $pass_lbl) | not) then "1" else "0" end' <<<"$next_pr_json")"
  issue_num="$(extract_linked_issue "$pr_body" "$head_branch")"

  # 1. 前置检查 CI 状态（若仍有进行中的 Check，稍后重试，避免抢跑）
  # （注意：合并冲突不再盲目退回，待第 3 步本地演练与分诊判断可直接解决还是转交开发）
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

  consec_file="${final_dir}/consecutive_rejections.txt"
  prev_consecutive_rejections=0
  if [[ -f "$consec_file" ]]; then
    _raw_consec="$(<"$consec_file")"
    _raw_consec="${_raw_consec//$'\r'/}"
    _raw_consec="${_raw_consec//$'\n'/}"
    if [[ "$_raw_consec" =~ ^[0-9]+$ ]]; then
      prev_consecutive_rejections="$_raw_consec"
    fi
  else
    for _df in "${final_dir}"/decision-*.json; do
      [[ -s "$_df" ]] || continue
      _v="$("$JQ_BIN" -r '.verdict // empty' "$_df" 2>/dev/null || true)"
      if [[ "$_v" == "merge" ]]; then
        prev_consecutive_rejections=0
      elif [[ "$_v" == "request_changes" ]]; then
        prev_consecutive_rejections=$((prev_consecutive_rejections + 1))
      fi
    done
  fi
  cycle_round=$((prev_consecutive_rejections + 1))

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
  printf '[%s] 开始 Codex 终审合入核对 PR #%s (Issue #%s, sha=%s, 本周期第 %d/%d 轮, 累计第 %d/%d 轮)...\n' \
    "$("$DATE_BIN" '+%F %T')" "$pr_num" "${issue_num:-?}" "${head_sha:0:10}" "$cycle_round" "$MAX_FINAL_ROUNDS" "$current_round" "$MAX_TOTAL_FINAL_ROUNDS"

  if ! final_wt="$(prepare_final_worktree "$pr_num" "$head_branch" "$head_sha")"; then
    printf '[%s] 警告：为 PR #%s 准备终审 worktree 失败，%ss 后重试...\n' \
      "$("$DATE_BIN" '+%F %T')" "$pr_num" "$POLL_INTERVAL" >&2
    "$SLEEP_BIN" "$POLL_INTERVAL"
    continue
  fi

  # 3.1 本地确定性合并演练（git merge-tree）+ 冲突分诊（简单机械冲突就地消解，实质冲突才退回开发）
  resolved_from_sha="$(lookup_resolved_from_sha "$final_dir" "$head_sha")"
  resolved_conflict_note=""
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

  if [[ "$mt_status" == "conflict" || "$mergeable" == "CONFLICTING" || "$merge_state" == "DIRTY" ]]; then
    triage_json="$(triage_and_resolve_conflict "$pr_num" "$head_branch" "$base_branch" "$head_sha" "$final_dir" "$run_ts" "pre-review")"
    t_outcome="$("$JQ_BIN" -r '.outcome // "requeue_dev"' <<<"$triage_json")"
    t_new_sha="$("$JQ_BIN" -r '.new_head_sha // ""' <<<"$triage_json")"
    t_reason="$("$JQ_BIN" -r '.reason // ""' <<<"$triage_json")"
    t_cfiles="$("$JQ_BIN" -r '.conflict_files // ""' <<<"$triage_json")"
    t_vnote="$("$JQ_BIN" -r '.verification_note // ""' <<<"$triage_json")"

    if [[ "$t_outcome" == "resolved" && -n "$t_new_sha" ]]; then
      prev_conflict_sha="$head_sha"
      resolved_from_sha="${resolved_from_sha:-$prev_conflict_sha}"
      record_resolved_conflict_sha "$final_dir" "$t_new_sha" "$prev_conflict_sha"
      head_sha="$t_new_sha"
      resolved_conflict_note="终审前置合并演练检测到简单机械冲突，已由 final-gate 就地消解并推送合并提交 \`${head_sha:0:10}\`（第一父提交保留原 E2E 验收提交 \`${resolved_from_sha:0:10}\`）。冲突文件：\`${t_cfiles//$'\n'/, }\`；说明：${t_reason}${t_vnote:+；校验：${t_vnote}}"
      if ! final_wt="$(prepare_final_worktree "$pr_num" "$head_branch" "$head_sha")"; then
        printf '[%s] 警告：PR #%s 冲突消解后检出新提交 %s 失败，%ss 后重试...\n' \
          "$("$DATE_BIN" '+%F %T')" "$pr_num" "${head_sha:0:10}" "$POLL_INTERVAL" >&2
        "$SLEEP_BIN" "$POLL_INTERVAL"
        continue
      fi
      merge_sim_json="$(inspect_git_merge_state "$base_branch" "$head_sha" 0)"
      mt_status="$("$JQ_BIN" -r '.status // "unknown"' <<<"$merge_sim_json")"
      mt_behind="$("$JQ_BIN" -r '.behind_count // 0' <<<"$merge_sim_json")"
      mt_ahead="$("$JQ_BIN" -r '.ahead_count // 0' <<<"$merge_sim_json")"
      mt_merge_commits="$("$JQ_BIN" -r '.merge_commit_count // 0' <<<"$merge_sim_json")"
      mt_overlap_files="$("$JQ_BIN" -r '.overlap_files // ""' <<<"$merge_sim_json")"
      mt_base_commits="$("$JQ_BIN" -r '.base_commits // ""' <<<"$merge_sim_json")"
      mt_pr_commits="$("$JQ_BIN" -r '.pr_commits // ""' <<<"$merge_sim_json")"
    elif [[ "$t_outcome" == "dry_run_resolved" ]]; then
      resolved_conflict_note="[DRY_RUN] 终审判定前置冲突为简单机械冲突，可就地消解（原因：${t_reason}）。"
    elif [[ "$t_outcome" == "clean" ]]; then
      printf '[%s] PR #%s 实时本地合并演练无冲突（GitHub mergeable 状态滞后），继续终审...\n' \
        "$("$DATE_BIN" '+%F %T')" "$pr_num"
    elif [[ "$t_outcome" == "blocked" ]]; then
      block_md="$("$CAT_BIN" <<EOF
### Codex 终审门禁冲突分诊拦截：需人工处理

- PR #${pr_num}（\`${head_branch}\` -> \`${base_branch}\`）存在合并冲突，终审分诊判定需人工介入：${t_reason}
\`\`\`text
${t_cfiles:-$mt_conflict_files}
\`\`\`
EOF
)"
      printf '%s\n' "$block_md" | gh_state comment pr "$pr_num" - "$FINAL_GATE_COMMENT_MARKER" || true
      gh_state set-state pr "$pr_num" blocked || true
      if [[ -n "$issue_num" ]]; then
        gh_state set-state issue "$issue_num" blocked || true
        printf '%s\n' "$block_md" | gh_state comment issue "$issue_num" - "$FINAL_GATE_COMMENT_MARKER" || true
      fi
      end_ts="$("$DATE_BIN" '+%F %T')"
      printf '[%s] [codex-final-gate] PR #%s (Issue #%s) -> conflict-blocked\n' "$end_ts" "$pr_num" "${issue_num:-?}" >> "$ACTIVITY_LOG"
      "$SLEEP_BIN" 5
      continue
    else
      conflict_detail_md="- 终审冲突分诊结论：**不可直接机械合并，需开发介入处理并复验**。"$'\n'"- 分诊原因：${t_reason:-存在实质性代码冲突}"$'\n'"- 冲突文件："$'\n''```text'$'\n'"${t_cfiles:-${mt_conflict_files}${mt_conflict_detail}}"$'\n''```'
      requeue_for_conflict "$pr_num" "$issue_num" "$head_branch" "$base_branch" \
        "Codex 终审门禁冲突分诊：实质性冲突退回开发" \
        "$conflict_detail_md" \
        "substantive-conflict-requeued"
      "$SLEEP_BIN" 5
      continue
    fi
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

  # 评审签核同时用于复用证据定位、免测校验和必验场景覆盖核对。
  review_handoff_error=""
  if [[ "$review_comment_loaded" == "0" ]] && ! prev_review_comment="$(gh_state get-comment pr "$pr_num" "$REVIEW_COMMENT_MARKER")"; then
    review_handoff_error="读取评审评论失败。"
  fi
  prev_e2e_comment="$(gh_state get-comment pr "$pr_num" "$E2E_COMMENT_MARKER" 2>/dev/null || true)"
  if [[ -z "$prev_e2e_comment" && -n "$issue_num" ]]; then
    prev_e2e_comment="$(gh_state get-comment issue "$issue_num" "$E2E_COMMENT_MARKER" 2>/dev/null || true)"
  fi

  rm_e2e_decision=""
  rm_e2e_reused_sha=""
  review_skip_valid=0
  required_checks="[]"
  review_parent_sha=""
  if [[ -n "$resolved_from_sha" ]]; then
    if [[ "$("$GIT_BIN" -C "$REPO_ROOT" rev-parse "${head_sha}^1" 2>/dev/null || true)" == "$resolved_from_sha" ]] \
      || [[ "$(lookup_resolved_from_sha "$final_dir" "$head_sha")" == "$resolved_from_sha" ]]; then
      review_parent_sha="$resolved_from_sha"
    fi
  fi
  if [[ -z "$review_handoff_error" ]]; then
    if review_handoff="$(read_review_handoff "$head_sha" "$review_parent_sha" <<<"$prev_review_comment" 2>&1)"; then
      required_checks="$("$JQ_BIN" -c '.e2e_checks' <<<"$review_handoff")"
      rm_e2e_decision="$("$JQ_BIN" -r '.e2e_decision // ""' <<<"$review_handoff")"
      rm_e2e_reused_sha="$("$JQ_BIN" -r '.e2e_reused_sha // ""' <<<"$review_handoff")"
    else
      review_handoff_error="评审签核缺失、损坏或与当前提交不匹配。"
      printf '[%s] 警告：PR #%s 的评审交接读取失败：%s\n' "$("$DATE_BIN" '+%F %T')" "$pr_num" "$review_handoff" >&2
    fi
  fi
  if [[ -z "$review_handoff_error" && "$pr_is_e2e_skipped" == "1" && "$required_checks" == "[]" ]]; then
    if [[ "$rm_e2e_decision" == "skip_not_needed" || "$rm_e2e_decision" == "skip_already_passed" ]]; then
      review_skip_valid=1
    fi
  fi

  ev_wt=""
  ev_branch_sha=""
  ev_entry_dir=""
  ev_entry_rel=""
  ev_manifest_json=""
  ev_result_json=""
  ev_tested_sha=""
  ev_result_verdict=""
  ev_sha_matched=0
  ev_is_ancestor=0
  ev_delta_stat=""
  ev_sensitive_files=""
  ev_file_list=""
  ev_web_url=""
  repo_web_base="${pr_url%/pull/*}"

  if ev_out="$(prepare_evidence_checkout)" && [[ -n "$ev_out" ]]; then
    ev_wt="${ev_out%%$'\t'*}"
    ev_branch_sha="${ev_out#*$'\t'}"
    # 检索优先顺序：
    #   1) current head_sha
    #   2) resolved_from_sha（就地消解机械冲突前的原 commit）
    #   3) rm_e2e_reused_sha（评审认定可复用的同 PR 或同 Issue 先前通过 E2E 的 commit）
    #   4) pr-<N> 最新归档回退
    for _d in "${ev_wt}/pr-${pr_num}/"*"-${head_sha:0:10}"; do
      [[ -d "$_d" ]] && ev_entry_dir="$_d"
    done
    if [[ -z "$ev_entry_dir" && -n "$resolved_from_sha" ]]; then
      for _d in "${ev_wt}/pr-${pr_num}/"*"-${resolved_from_sha:0:10}"; do
        [[ -d "$_d" ]] && ev_entry_dir="$_d"
      done
    fi
    if [[ -z "$ev_entry_dir" && -n "$rm_e2e_reused_sha" ]]; then
      for _d in "${ev_wt}/pr-${pr_num}/"*"-${rm_e2e_reused_sha:0:10}"; do
        [[ -d "$_d" ]] && ev_entry_dir="$_d"
      done
      if [[ -z "$ev_entry_dir" ]]; then
        for _d in "${ev_wt}/pr-"*"/"*"-${rm_e2e_reused_sha:0:10}"; do
          [[ -d "$_d" ]] && ev_entry_dir="$_d"
        done
      fi
    fi
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
        if [[ "$ev_tested_sha" == "$head_sha" ]]; then
          ev_sha_matched=1
        elif [[ -n "$resolved_from_sha" && "$ev_tested_sha" == "$resolved_from_sha" ]]; then
          _p1="$("$GIT_BIN" -C "$REPO_ROOT" rev-parse "${head_sha}^1" 2>/dev/null || true)"
          if [[ "$_p1" == "$ev_tested_sha" ]] \
            || [[ "$(lookup_resolved_from_sha "$final_dir" "$head_sha")" == "$ev_tested_sha" ]]; then
            ev_sha_matched=1
          fi
        fi
        if [[ -n "$ev_tested_sha" ]] && "$GIT_BIN" -C "$REPO_ROOT" merge-base --is-ancestor "$ev_tested_sha" "$head_sha" 2>/dev/null; then
          ev_is_ancestor=1
          if [[ "$ev_tested_sha" != "$head_sha" ]]; then
            ev_delta_stat="$("$GIT_BIN" -C "$REPO_ROOT" diff --stat "${ev_tested_sha}..${head_sha}" 2>/dev/null || true)"
          fi
        fi
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

  required_checks_error="$review_handoff_error"
  required_checks_section=""
  checks_key_suffix=""
  if [[ "$required_checks" != "[]" ]]; then
    required_checks_section="$("$JQ_BIN" -r -L "$SCRIPT_DIR" '
      include "workflow-e2e"; numbered_e2e_checks[] | "- " + .id + " " + .description
    ' <<<"$required_checks")"
    checks_hash="$(printf '%s' "$required_checks" | "$SHA256SUM_BIN")"
    checks_key_suffix=":${checks_hash%% *}"
    archived_checks_hash="$("$JQ_BIN" -r '.review_checks_hash // ""' <<<"$ev_manifest_json" 2>/dev/null || true)"
    if [[ "$pr_is_e2e_skipped" == "1" ]]; then
      required_checks_error="当前评审包含必验场景，需要实测。"
    elif [[ "$ev_sha_matched" != "1" || "$archived_checks_hash" != "${checks_hash%% *}" ]]; then
      required_checks_error="缺少与当前评审必验场景和提交匹配的 QA 归档。"
    else
      artifact_files="$("$FIND_BIN" "${ev_entry_dir}/artifacts" -type f -printf '%P\0' 2>/dev/null \
        | "$JQ_BIN" -Rsc 'split("\u0000") | map(select(length > 0))' || printf '[]')"
      if ! missing_checks="$("$JQ_BIN" -ec -L "$SCRIPT_DIR" --argjson required "$required_checks" --argjson files "$artifact_files" '
        include "workflow-e2e";
        select(type == "object" and .verdict == "pass") | missing_e2e_checks($required; $files)
      ' <<<"$ev_result_json")"; then
        required_checks_error="QA 归档缺少有效的通过结论。"
      elif [[ "$missing_checks" != "[]" ]]; then
        required_checks_error="必验场景缺少通过记录、实测详情或归档证据：$("$JQ_BIN" -r 'join("、")' <<<"$missing_checks")。"
      fi
    fi
  fi

  # 4. 拉取关联 Issue 以及完整 PR diff
  issue_section="（未识别到关联 Issue）"
  issue_title=""
  issue_body=""
  issue_labels_json="[]"
  if [[ -n "$issue_num" ]]; then
    if issue_json="$(gh_state get-issue "$issue_num" 2>/dev/null)"; then
      issue_title="$("$JQ_BIN" -r '.title // ""' <<<"$issue_json")"
      issue_body="$("$JQ_BIN" -r '.body // "(empty)"' <<<"$issue_json")"
      issue_labels="$("$JQ_BIN" -r '([.labels[]?.name] | join(", ")) // "(none)"' <<<"$issue_json")"
      issue_labels_json="$("$JQ_BIN" -c '[.labels[]?.name // empty]' <<<"$issue_json")"
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

  pr_diff_raw="$(gh_state get-pr-diff "$pr_num" 2>/dev/null || true)"
  pr_diff_snippet="${pr_diff_raw:0:MAX_DIFF_BYTES}"
  if (( ${#pr_diff_raw} > MAX_DIFF_BYTES )); then
    pr_diff_snippet="${pr_diff_snippet}"$'\n\n'"... (diff 已截断，请在当前只读工作区使用 git diff origin/${base_branch}...HEAD 查看完整变更)"
  fi

  ev_delta_section=""
  if [[ -n "$ev_delta_stat" ]]; then
    ev_delta_section="- 自 \`${ev_tested_sha:0:10}\` 以来的增量改动统计:"$'\n''```text'$'\n'"${ev_delta_stat}"$'\n''```'
  fi

  open_issues_md="- (未获取到现有 Open Issues)"
  if _oi_json="$(gh_state list-issues open "" 50 2>/dev/null)" \
    && "$JQ_BIN" -e 'type == "array"' >/dev/null 2>&1 <<<"$_oi_json"; then
    open_issues_md="$("$JQ_BIN" -r '
      if length == 0 then
        "- (当前无 Open Issues)"
      else
        [.[] | "- #" + (.number | tostring) + ": " + .title] | join("\n")
      end
    ' <<<"$_oi_json")"
  fi

  if [[ "$pr_is_e2e_skipped" != "1" ]]; then
    e2e_entry_mode_desc="${LABEL_PREFIX}e2e-passed（已完成当前提交的独立 E2E 验收）"
  elif [[ "$rm_e2e_decision" == "skip_not_needed" ]]; then
    e2e_entry_mode_desc="${LABEL_PREFIX}e2e-skipped / skip_not_needed（独立评审确认纯非运行时改动免 E2E；评审签核匹配=${review_skip_valid}）"
  elif [[ "$rm_e2e_decision" == "skip_already_passed" ]]; then
    e2e_entry_mode_desc="${LABEL_PREFIX}e2e-skipped / skip_already_passed（独立评审确认复用先前已通过 E2E 提交 \`${rm_e2e_reused_sha:0:10}\`；评审签核匹配=${review_skip_valid}）"
  else
    e2e_entry_mode_desc="${LABEL_PREFIX}e2e-skipped（未检测到匹配的评审免测元数据）"
  fi

  "$CAT_BIN" > "$prompt_file" <<EOF
你是本流水线的**终审合入门禁官（Final Gate / Release Reviewer）**。本 PR 通过 \`${e2e_entry_mode_desc}\` 进入终审，请你从发布合入角度，对 **原始 Issue、最终代码、远端 QA 证据/免测依据、CI 状态与 PR 信息** 做最后一次全面对账，决定是否满足合入要求，并生成最终规范化的 PR 标题、PR 正文与 Issue 收口说明。

## PR 基本信息
- PR: #${pr_num} (${pr_url})
- 当前标题: ${pr_title}
- 分支: \`${head_branch}\` -> \`${base_branch}\`
- 最终 Commit SHA: \`${head_sha}\`
- E2E 入场模式: ${e2e_entry_mode_desc}
- Draft 状态: \`${is_draft}\`（注：自动化流水线默认先创建 Draft PR，技术审签通过后由宿主机门禁统一决定是否转为 Ready，\`isDraft=true\` 属于正常状态，不是阻塞项）
- 宿主机合入授权门禁: \`AUTO_MERGE=${AUTO_MERGE}\`, \`HOLD_LABEL=${HOLD_MERGE_LABEL}\`, \`REQUIRE_OWNER_MERGE_APPROVAL=${REQUIRE_OWNER_MERGE_APPROVAL}\`（逐 PR 暂停标签与 Owner 合入保留由宿主机在转 Ready/merge 前确定性校验；请专注评估代码、Issue 覆盖与 QA 证据，技术就绪时直接返回 \`merge\`）
- 可合并性: \`${mergeable:-UNKNOWN}\` / \`${merge_state:-UNKNOWN}\`
- 终审轮次: 本周期第 ${cycle_round} / ${MAX_FINAL_ROUNDS} 轮（累计第 ${current_round} / ${MAX_TOTAL_FINAL_ROUNDS} 轮）

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

## 当前仓库已有 Open Issues（用于后续追踪去重，严禁重复建单）
${open_issues_md}

## 远端 QA 证据核对结果（分支 \`${E2E_EVIDENCE_BRANCH}\` @ \`${ev_branch_sha:0:10}\`）
- 评审必验场景核对: ${required_checks_error:-通过}
${required_checks_section}
- 证据归档目录（本地只读检出）: \`${ev_entry_dir:-(未找到)}\`
- 证据 GitHub 永久直链: ${ev_web_url:-(无)}
- 证据 manifest.tested_sha: \`${ev_tested_sha:-(缺失)}\`（与 PR head_sha 或其第一父提交是否严格一致: \`${ev_sha_matched}\`，是否当前提交祖先: \`${ev_is_ancestor}\`）
${ev_delta_section:-- 自已通过 E2E 提交以来的增量改动: (无或未适用)}
${resolved_conflict_note:+- 终审机械冲突就地消解记录: ${resolved_conflict_note}}
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
0. **运行环境与数据源约束**：你当前运行在离线 \`read-only\` 沙箱中，网络与本地 \`gh\` CLI 权限已被有意禁用；所有实时 GitHub PR、Issue、CI Checks、标签与评论快照以及远端 QA 证据分支检出均已由外层宿主机脚本通过 \`gh-state.sh\` 完整注入本提示词及只读工作区。**禁止在沙箱内调用 \`gh\` 命令**，也不要在 \`non_blocking_notes\` 或总结中记录“沙箱拒绝 \`gh\` / 无网权限”等无效环境噪声。
1. **核对最终代码与 SHA**：当前工作目录是 PR 最新提交（\`${head_sha}\`）的只读检出；重点检查改动是否干净、无回归、无调试代码残留：
   - 当入场模式为 \`agy:e2e-passed\` 时：核对 \`manifest.tested_sha == ${head_sha}\`（或由本终审刚就地消解机械冲突生成了合并提交，允许 \`head_sha^1 == manifest.tested_sha\`）；若不一致，说明最新代码未经 E2E 复验，输出 \`require_e2e\` 或拒绝 \`merge\`。
   - 当入场模式为 \`agy:e2e-skipped\` 且评审签核匹配（\`${review_skip_valid} == 1\`）时：
     - 若为 \`skip_not_needed\`：复核整个 PR diff 确实全部为非运行时改动（文档、注释、纯单元测试、静态配置/元数据等）；若确认属实，**不要因为缺少 QA 证据归档而阻止合入**，可直接放行 \`merge\`；若发现包含影响运行时行为的代码改动，必须输出 \`verdict: "require_e2e"\`（将直接转 \`agy:approved\` 进入 E2E，无需打回开发）。
     - 若为 \`skip_already_passed\`：复核先前的 E2E 归档（\`${ev_tested_sha:-(缺失)}\`）结论为 \`pass\`、属于当前提交的祖先，且增量改动（\`${ev_tested_sha:0:10}..${head_sha:0:10}\`）确实不破坏既有 E2E 结论；若确认属实，可直接放行 \`merge\`；若增量改动影响了运行时行为需重新 E2E，必须输出 \`verdict: "require_e2e"\`。
2. **核对 Issue 与 QA 证据/免测闭环**：按需检查 \`${ev_entry_dir}\` 中的真实日志与报告（\`skip_not_needed\` 除外），确认 Issue 核心验收标准均有真实代码与验收闭环，且证据目录无敏感凭据泄漏、无未清理临时文件。
3. **核对合并冲突风险并裁定合并方式（\`merge_method\`）**：
   - 若 \`origin/${base_branch}\` 已有新提交（\`behind > 0\`）且与本 PR **修改了重叠文件或关联接口**，务必通过只读 \`git diff\` / \`git log\` 评估是否存在**语义冲突风险**（即便 Git 自动合并不报错，逻辑上也可能互相破坏）；若存在语义冲突风险或主干变更需要重新 E2E 回归，必须输出 \`request_changes\` 要求先同步主干再验证，不得盲目合入。
   - 请结合仓库允许的合并策略、PR 提交历史与冲突风险，裁定最终 \`merge_method\`（\`merge\` / \`squash\` / \`rebase\`）并在 \`merge_method_reason\` 中简明说明理由：
     - 仓库允许且无冲突时，**默认优先使用 \`${MERGE_METHOD}\`**（通常是 \`merge\`，保留分支历史与 merge commit）；
     - **严禁在包含 merge commit（\`merge_commits > 0\`）或存在多提交重放冲突风险的分支上选择 \`rebase\`**；
     - 必须选择仓库允许的合并方式（若 \`merge\` 被禁用则选 \`squash\` 或可用的方式）；若分支经历多轮修补包含大量零碎修复提交且仓库允许 \`squash\`，可在说明理由后选择 \`squash\` 或保持 \`merge\`。
4. **终审授权边界与务实原则（严禁流程性误拦截）**：
   - **严禁以 PR 为 Draft 状态阻止合入**：本流水线开发阶段固定创建 Draft PR，终审判定 \`merge\` 后由宿主机脚本自动解除 Draft 并执行合并。
   - **严禁以“缺少 Owner 人工二次确认/授权”阻止合入**：当 \`AUTO_MERGE=1\` 时，仓库 Owner 已将满足技术与验收标准后的最终合入决策权正式授权给本 \`final-gate\`。Issue 模板或完成标准中常见的常规措辞（如“保留 Owner 合入决定”、“由 Owner 决定是否合入”、“等待人工合并”等）均视为由本 \`final-gate\` 代行把关，**不得**因此输出 \`blocked\` 或 \`request_changes\`（仅在 PR/Issue 明确出现紧急暂停指令如 \`DO NOT MERGE\` / \`HOLD\` / \`暂勿合入\` 时才拦截）。
   - **严禁以未改动文件的既有缺陷或脱离 Issue 范围的极端假想反例阻塞已通过 Review+E2E 的 PR**：本 PR 已通过独立代码评审与真实引擎 E2E 验收；\`final-gate\` 只因「违反原始 Issue 明确验收标准、本次 PR 改动直接引入的真实回归/崩溃、SHA 未对齐、缺少真实 QA 证据、敏感信息泄漏、真实/高风险合并冲突、或 CI 失败」才拒绝 \`merge\`。对于 PR 未修改文件的既有历史行为、或未经实测复现的极罕见理论边界（例如奇异反斜杠表名、毫秒级 TOCTOU 竞态等），**一律归入 \`non_blocking_notes\` 作为后续独立跟进建议，绝不得列为 \`blocking_issues\` 打回 \`request_changes\`**。
   - 仅当存在上述明确阻塞项时拒绝 \`merge\`：
     - 本 PR 实际上仍需真实 E2E 验收/复验（例如 \`agy:e2e-skipped\` 误判或 SHA 未覆盖运行时变更） -> 输出 \`require_e2e\`（直接进 E2E 队列，不打回开发）；
     - 可通过修改代码/同步主干/补充测试解决的问题 -> 输出 \`request_changes\`；
     - 环境/CI 基础设施异常、证据泄漏需人工清理或需人工决策 -> 输出 \`blocked\`。
5. **生成规范化的最终 PR 信息与 Issue 说明**：
   - \`pr_title\`：简洁清晰、符合仓库提交/PR 风格。
   - \`pr_body\`：完整规范的中文 PR 正文（Markdown），必须包含：① 改动摘要与根因；② 验证范围与结果（区分内部单测与真实 E2E 验收）；③ 固定验收 Commit SHA（\`${head_sha}\`）与远端 QA 证据永久直链（${ev_web_url:-(无)}）；④ 已知限制或未验证项；⑤ 末尾保留 \`Closes #${issue_num:-N}\`（如有关联 Issue）。
   - \`issue_closing_note\`：简明的 Issue 最终收口评论（关联 PR、固定 SHA、QA 证据直链、已知未覆盖项）。
5.1 **必要时生成后续追踪 Issue（\`follow_up_issues\`）**：
   - 仅当 \`verdict == "merge"\` 时评估哪些非阻塞发现**确有必要**沉淀为独立的后续追踪 Issue（其他结论固定输出空数组 \`[]\`）。
   - **应建单**：终审发现的真实既有隐患（例如 PR 未修改文件中的历史缺陷）、明确延后的功能/安全/可靠性/测试覆盖缺口，且具备明确代码定位与验收标准，且**未在上方 Open Issues 列表中重复存在**。
   - **严禁建单**（仅保留在 \`non_blocking_notes\`）：过程性执行记录（重试、清理日志、手动 CI 工作流说明、单测数量来源说明）、已合入 PR 的历史分支命名等琐碎事项、或已有 Open Issue 追踪的问题。
   - 最多输出 ${MAX_FOLLOWUP_ISSUES} 条；每条需提供简短英文唯一标识 \`slug\`（如 \`pg-zero-column-snapshot\`）、清晰中文 \`title\`、\`priority\`（\`P1\` / \`P2\` / \`P3\`）、简明 \`reason\` 与完整可执行的 Markdown \`body\`（含问题证据、建议改动范围与验收标准）；无必要建单时必须输出 \`[]\`。
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
  if "$TIMEOUT_BIN" --signal=TERM --kill-after=30s "$CODEX_TIMEOUT" "${CODEX_CMD[@]}" "${codex_args[@]}" < "$prompt_file" > "$events_file"; then
    if [[ -s "$decision_file" ]] && "$JQ_BIN" -e '.verdict == "merge" or .verdict == "require_e2e" or .verdict == "request_changes" or .verdict == "blocked"' "$decision_file" >/dev/null 2>&1; then
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
    if [[ -n "$required_checks_error" ]]; then
      hard_gate_errors+="- 硬门禁拦截：${required_checks_error}"$'\n'
    fi
    if [[ "$REQUIRE_EVIDENCE_SHA_MATCH" == "1" ]]; then
      if [[ "$pr_is_e2e_skipped" == "1" ]]; then
        if [[ "$review_skip_valid" != "1" ]]; then
          hard_gate_errors+="- 硬门禁拦截：PR 带 \`${LABEL_PREFIX}e2e-skipped\` 标签，但缺少匹配当前 \`head_sha\`（\`${head_sha:0:10}\`）的有效评审免测签核（可能评审后有新提交）。"$'\n'
        elif [[ "$rm_e2e_decision" == "skip_already_passed" ]]; then
          if [[ -z "$ev_tested_sha" || "$ev_result_verdict" != "pass" || "$ev_is_ancestor" != "1" ]] \
            || [[ -n "$rm_e2e_reused_sha" && "$ev_tested_sha" != "$rm_e2e_reused_sha" ]]; then
            hard_gate_errors+="- 硬门禁拦截：\`skip_already_passed\` 复用的 QA 证据无效（\`verdict=${ev_result_verdict:-缺失}\`, \`tested_sha=${ev_tested_sha:-缺失}\`, \`reused_sha=${rm_e2e_reused_sha:-缺失}\`, \`is_ancestor=${ev_is_ancestor}\`）。"$'\n'
          fi
        elif [[ "$rm_e2e_decision" == "skip_not_needed" ]]; then
          : # 评审已针对当前 SHA 签核非运行时改动免测，无需 QA 证据归档
        else
          hard_gate_errors+="- 硬门禁拦截：\`${LABEL_PREFIX}e2e-skipped\` 的评审路由类型无效（\`${rm_e2e_decision:-缺失}\`）。"$'\n'
        fi
      else
        if [[ "$ev_sha_matched" != "1" ]]; then
          hard_gate_errors+="- 硬门禁拦截：远端 QA 证据 \`tested_sha\` (\`${ev_tested_sha:-缺失}\`) 与 PR 最新 \`head_sha\` (\`${head_sha}\`) 不一致。"$'\n'
        fi
        if [[ "$ev_result_verdict" != "pass" ]]; then
          hard_gate_errors+="- 硬门禁拦截：远端 QA 证据结论为 \`${ev_result_verdict:-缺失}\`，并非 \`pass\`。"$'\n'
        fi
      fi
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
  new_consecutive_rejections="$prev_consecutive_rejections"

  if [[ -n "$resolved_conflict_note" ]]; then
    extra_notice+=$'\n\n'"> ℹ️ 机械冲突就地消解：${resolved_conflict_note}"
  fi
  if [[ -n "$merge_method_adjust_note" && "$effective_merge_method" != "NONE" ]]; then
    extra_notice+=$'\n\n'"> ℹ️ 合并方式安全调整：${merge_method_adjust_note}"
  fi

  if [[ -n "$hard_gate_errors" ]]; then
    final_state="blocked"
    final_action="${LABEL_PREFIX}blocked (hard-gate)"
    extra_notice+=$'\n\n'"#### ⚠️ 确定性硬门禁拦截（未自动合并）"$'\n'"${hard_gate_errors}"
  elif [[ "$verdict" == "merge" ]]; then
    new_consecutive_rejections=0
    # 合并前最后一次实时拉取 origin/<base_branch> 并重跑 git merge-tree 冲突演练；
    # 若终审期间主干产生冲突，同样先分诊：简单机械冲突直接就地消解并推送后再合并，仅实质冲突才退回开发
    recheck_conflict=0
    recheck_block=0
    recheck_conflict_md=""
    if [[ "$AUTO_MERGE" == "1" ]]; then
      recheck_json="$(inspect_git_merge_state "$base_branch" "$head_sha" 1)"
      recheck_status="$("$JQ_BIN" -r '.status // "unknown"' <<<"$recheck_json")"
      if [[ "$recheck_status" == "conflict" ]]; then
        recheck_triage="$(triage_and_resolve_conflict "$pr_num" "$head_branch" "$base_branch" "$head_sha" "$final_dir" "$run_ts" "pre-merge")"
        rt_outcome="$("$JQ_BIN" -r '.outcome // "requeue_dev"' <<<"$recheck_triage")"
        rt_new_sha="$("$JQ_BIN" -r '.new_head_sha // ""' <<<"$recheck_triage")"
        rt_reason="$("$JQ_BIN" -r '.reason // ""' <<<"$recheck_triage")"
        rt_cfiles="$("$JQ_BIN" -r '.conflict_files // ""' <<<"$recheck_triage")"
        rt_vnote="$("$JQ_BIN" -r '.verification_note // ""' <<<"$recheck_triage")"

        if [[ "$rt_outcome" == "resolved" && -n "$rt_new_sha" ]]; then
          prev_conflict_sha="$head_sha"
          resolved_from_sha="${resolved_from_sha:-$prev_conflict_sha}"
          record_resolved_conflict_sha "$final_dir" "$rt_new_sha" "$prev_conflict_sha"
          head_sha="$rt_new_sha"
          mt_merge_commits=$((mt_merge_commits + 1))
          _mm_re="$(resolve_safe_merge_method "$effective_merge_method" "$allow_merge_commit" "$allow_squash_merge" "$allow_rebase_merge" "$mt_merge_commits")"
          effective_merge_method="${_mm_re%%$'\t'*}"
          _mm_re_note="${_mm_re#*$'\t'}"
          [[ -n "$_mm_re_note" && "$effective_merge_method" != "NONE" ]] && \
            extra_notice+=$'\n\n'"> ℹ️ 合并方式安全调整：${_mm_re_note}"
          extra_notice+=$'\n\n'"> ℹ️ 合并前实时复检发现简单机械冲突，已由 final-gate 就地消解并推送合并提交 \`${head_sha:0:10}\`（冲突文件：\`${rt_cfiles//$'\n'/, }\`；说明：${rt_reason}${rt_vnote:+；校验：${rt_vnote}}），随后直接完成自动合入。"
        elif [[ "$rt_outcome" == "clean" || "$rt_outcome" == "dry_run_resolved" ]]; then
          [[ "$rt_outcome" == "dry_run_resolved" ]] && \
            extra_notice+=$'\n\n'"> ℹ️ [DRY_RUN] 合并前实时冲突可由 final-gate 就地消解（原因：${rt_reason}）。"
        elif [[ "$rt_outcome" == "blocked" ]]; then
          recheck_block=1
          recheck_conflict_md="- 合并前冲突分诊判定需人工处理：${rt_reason}"$'\n''```text'$'\n'"${rt_cfiles}"$'\n''```'
        else
          recheck_conflict=1
          recheck_conflict_md="- 分诊原因：${rt_reason:-存在实质性冲突}"$'\n''```text'$'\n'"${rt_cfiles}"$'\n''```'
        fi
      fi
    fi

    if (( recheck_block == 1 )); then
      final_state="blocked"
      final_action="${LABEL_PREFIX}blocked (pre-merge-conflict-blocked)"
      extra_notice+=$'\n\n'"#### ⚠️ 合并前冲突分诊拦截（需人工处理）"$'\n'"${recheck_conflict_md}"
    elif (( recheck_conflict == 1 )); then
      final_state="changes-requested"
      final_action="${LABEL_PREFIX}changes-requested (pre-merge-substantive-conflict)"
      record_checked_sha=0
      extra_notice+=$'\n\n'"#### ⚠️ 合并前实时冲突分诊：实质性冲突退回开发（未合并）"$'\n'"${recheck_conflict_md}"$'\n'"- 已退回 \`${LABEL_PREFIX}changes-requested\`，交由开发循环合入主干解决冲突并重新验证。"
    elif [[ "$effective_merge_method" == "NONE" ]]; then
      final_state="blocked"
      final_action="${LABEL_PREFIX}blocked (no-usable-merge-method)"
      extra_notice+=$'\n\n'"#### ⚠️ 合并前校验拦截：无可用合并方式"
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

      if [[ "$AUTO_MERGE" == "1" ]]; then
        pr_labels_fallback_json="$("$JQ_BIN" -c '[.labels[]?.name // empty]' <<<"$next_pr_json")"
        merge_auth_json="$(evaluate_merge_authorization "$pr_num" "$head_sha" "$resolved_from_sha" "$pr_labels_fallback_json" "$issue_labels_json" "$issue_title" "$issue_body")"
        merge_auth_allowed="$("$JQ_BIN" -r '.allowed' <<<"$merge_auth_json")"
        merge_auth_mode="$("$JQ_BIN" -r '.mode // ""' <<<"$merge_auth_json")"
        merge_auth_reason="$("$JQ_BIN" -r '.reason // ""' <<<"$merge_auth_json")"

        if [[ "$merge_auth_allowed" != "true" ]]; then
          record_checked_sha=0
          if [[ "$merge_auth_mode" == "head_changed" ]]; then
            final_state="changes-requested"
            final_action="${LABEL_PREFIX}changes-requested (pre-merge-head-changed)"
            extra_notice+=$'\n\n'"#### ⚠️ 合入前实时复读拦截（未转 Ready / 未合并）"$'\n'"- ${merge_auth_reason}"
          else
            final_state="ready-to-merge"
            final_action="${LABEL_PREFIX}ready-to-merge (${merge_auth_mode})"
            extra_notice+=$'\n\n'"#### ⏸️ 宿主机合入授权门禁暂停（未转 Ready / 未合并）"$'\n'"- ${merge_auth_reason}"
          fi
        else
          [[ -n "$merge_auth_reason" ]] && extra_notice+=$'\n\n'"> ✅ 合入授权核验通过：${merge_auth_reason}"
          # 仅在确认执行自动合并且通过宿主机授权校验后，才将 Draft PR 转为 Ready for review
          if [[ "$is_draft" == "true" ]]; then
            gh_state mark-pr-ready "$pr_num" || true
          fi
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
        fi
      else
        final_state="ready-to-merge"
        final_action="${LABEL_PREFIX}ready-to-merge (method=${effective_merge_method}, awaiting manual merge)"
      fi
    fi
  elif [[ "$verdict" == "require_e2e" ]]; then
    final_state="approved"
    final_action="${LABEL_PREFIX}approved (require-e2e)"
    record_checked_sha=0
    extra_notice+=$'\n\n'"> ℹ️ 终审评估当前改动仍需执行真实 E2E 验收（无需打回开发），已直接切换为 \`${LABEL_PREFIX}approved\` 交由 E2E 循环处理。"
  elif [[ "$verdict" == "blocked" ]]; then
    final_state="blocked"
    final_action="${LABEL_PREFIX}blocked"
  else
    new_consecutive_rejections="$cycle_round"
    if (( cycle_round >= MAX_FINAL_ROUNDS )); then
      final_state="blocked"
      final_action="${LABEL_PREFIX}blocked (max-rounds)"
      extra_notice+=$'\n\n'"> ⚠️ 已达到终审最大连续打回轮次（连续 ${cycle_round} / ${MAX_FINAL_ROUNDS} 轮，累计第 ${current_round} / ${MAX_TOTAL_FINAL_ROUNDS} 轮），状态已切为 \`${LABEL_PREFIX}blocked\`，请人工介入裁决。"
    elif (( current_round >= MAX_TOTAL_FINAL_ROUNDS )); then
      final_state="blocked"
      final_action="${LABEL_PREFIX}blocked (max-total-rounds)"
      extra_notice+=$'\n\n'"> ⚠️ 已达到单 PR 最大总终审轮次上限（累计 ${current_round} / ${MAX_TOTAL_FINAL_ROUNDS} 轮），状态已切为 \`${LABEL_PREFIX}blocked\`，请人工介入裁决。"
    else
      final_state="changes-requested"
      final_action="${LABEL_PREFIX}changes-requested"
    fi
  fi

  # 仅在 PR 成功合并且开启后续建单时，为必要的非阻塞发现幂等创建追踪 Issue
  created_followups_md=""
  created_followups_json="[]"
  if [[ "$CREATE_FOLLOWUP_ISSUES" == "1" ]] && (( merged_ok == 1 )); then
    max_fu=0
    [[ "$MAX_FOLLOWUP_ISSUES" =~ ^[0-9]+$ ]] && max_fu="$MAX_FOLLOWUP_ISSUES"
    follow_up_count="$("$JQ_BIN" -r --argjson max "$max_fu" '(.follow_up_issues // []) | if length > $max then $max else length end' "$decision_file")"
    for (( idx = 0; idx < follow_up_count; idx++ )); do
      fu_slug="$("$JQ_BIN" -r --argjson i "$idx" '(.follow_up_issues[$i].slug // "")' "$decision_file")"
      fu_title="$("$JQ_BIN" -r --argjson i "$idx" '(.follow_up_issues[$i].title // "")' "$decision_file")"
      fu_priority="$("$JQ_BIN" -r --argjson i "$idx" '(.follow_up_issues[$i].priority // "P2")' "$decision_file")"
      fu_reason="$("$JQ_BIN" -r --argjson i "$idx" '(.follow_up_issues[$i].reason // "")' "$decision_file")"
      fu_body="$("$JQ_BIN" -r --argjson i "$idx" '(.follow_up_issues[$i].body // "")' "$decision_file")"
      [[ -z "$fu_title" || -z "$fu_body" ]] && continue

      safe_slug="${fu_slug//[^a-zA-Z0-9._-]/-}"
      [[ -z "$safe_slug" ]] && safe_slug="item-$((idx + 1))"
      fu_dedup_key="<!-- gongcao-followup-key:pr-${pr_num}:${safe_slug} -->"
      fu_body_file="${final_dir}/followup-${run_ts}-$((idx + 1)).md"

      "$CAT_BIN" > "$fu_body_file" <<EOF
### 来源与追踪上下文
- 来源 PR: #${pr_num} (${pr_url})
- 关联原 Issue: #${issue_num:-无}
- 合并提交: \`${head_sha:0:10}\`
- 优先级: \`${fu_priority}\`

### 追踪原因
${fu_reason:-"Final Gate 终审合入时沉淀的独立后续改进项。"}

### 问题描述与建议范围
${fu_body}

${fu_dedup_key}
EOF

      if fu_out="$(gh_state create-issue "$fu_title" "$fu_body_file" "$FOLLOWUP_ISSUE_LABELS" "$fu_dedup_key")" && [[ -n "$fu_out" ]]; then
        IFS=$'\t' read -r fu_num fu_url fu_status <<<"$fu_out"
        created_followups_md+="- [${fu_priority}] #${fu_num} ${fu_title} (${fu_url}) — \`${fu_status}\`"$'\n'
        created_followups_json="$("$JQ_BIN" -c \
          --arg num "$fu_num" \
          --arg title "$fu_title" \
          --arg priority "$fu_priority" \
          --arg url "$fu_url" \
          --arg status "$fu_status" \
          --arg slug "$safe_slug" \
          '. + [{number: ($num | tonumber? // $num), title: $title, priority: $priority, url: $url, status: $status, slug: $slug}]' \
          <<<"$created_followups_json")"
      fi
    done
    if [[ -n "$created_followups_md" ]]; then
      extra_notice+=$'\n\n'"#### 后续追踪 Issue（由 Final Gate 自动创建）"$'\n'"${created_followups_md%$'\n'}"
    fi
  fi

  final_md="$(render_final_gate_markdown "$decision_file" "$pr_num" "$issue_num" "$head_sha" "$current_round" "$final_action" "$ev_web_url" "$effective_merge_method" "$cycle_round")${extra_notice}"
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
    if [[ "$final_state" == "done" || "$final_state" == "ready-to-merge" || "$final_state" == "blocked" || "$final_state" == "approved" ]]; then
      printf '%s\n' "$issue_comment_md" | gh_state comment issue "$issue_num" - "$FINAL_GATE_COMMENT_MARKER" || true
      gh_state set-state issue "$issue_num" "$final_state" || true
    elif [[ "$final_state" == "changes-requested" && "$AUTO_REQUEUE_ISSUE" == "1" ]]; then
      # 先写评论再切标签，避免 agy-issue-loop 抢在评论落盘前就拉走任务
      printf '%s\n' "$issue_comment_md" | gh_state comment issue "$issue_num" - "$FINAL_GATE_COMMENT_MARKER" || true
      gh_state set-state issue "$issue_num" changes-requested || true
    fi
  fi

  if [[ "$final_state" == "blocked" && -n "$required_checks_error" ]]; then
    record_checked_sha=0
  fi
  if [[ "$DRY_RUN" != "1" && "$record_checked_sha" == "1" ]]; then
    printf '%s%s\n' "$head_sha" "$checks_key_suffix" >> "$sha_file"
    printf '%d\n' "$new_consecutive_rejections" > "$consec_file"
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
    --argjson cycle_round "$cycle_round" \
    --argjson consecutive_rejections "$new_consecutive_rejections" \
    --argjson max_total_rounds "$MAX_TOTAL_FINAL_ROUNDS" \
    --arg verdict "$verdict" \
    --arg merge_method "$effective_merge_method" \
    --arg merge_method_reason "$merge_method_reason" \
    --arg final_state "$final_state" \
    --argjson merged "$merged_ok" \
    --argjson follow_up_issues "$created_followups_json" \
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
      cycle_round: $cycle_round,
      consecutive_rejections: $consecutive_rejections,
      max_total_rounds: $max_total_rounds,
      verdict: $verdict,
      merge_method: $merge_method,
      merge_method_reason: $merge_method_reason,
      final_state: $final_state,
      merged: ($merged == 1),
      follow_up_issues: $follow_up_issues,
      updated_at: $updated_at
    }' > "$meta_file"

  total_elapsed=$((SECONDS - task_start_sec))
  end_ts="$("$DATE_BIN" '+%F %T')"
  printf '\n============================================================\n'
  printf '[%s] [DONE] PR #%s Codex 终审合入完成 (本周期第 %d/%d 轮, 累计第 %d/%d 轮, 耗时 %ds)\n' \
    "$end_ts" "$pr_num" "$cycle_round" "$MAX_FINAL_ROUNDS" "$current_round" "$MAX_TOTAL_FINAL_ROUNDS" "$total_elapsed"
  printf '  终审结果 : %s -> %s (merge_method=%s)\n' "$verdict" "$final_action" "$effective_merge_method"
  printf '  关联Issue: #%s | Commit: %s\n' "${issue_num:-?}" "${head_sha:0:10}"
  [[ -n "$ev_web_url" ]] && printf '  QA 证据  : %s\n' "$ev_web_url"
  printf '  终审报告 : %s\n' "$comment_file"
  printf '============================================================\n\n'
  printf '[%s] [codex-final-gate] PR #%s (Issue #%s, r%d) -> %s (%s, %ds)\n' \
    "$end_ts" "$pr_num" "${issue_num:-?}" "$current_round" "$verdict" "$final_action" "$total_elapsed" >> "$ACTIVITY_LOG"

  "$SLEEP_BIN" 5
done
