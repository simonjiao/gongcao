#!/usr/bin/bash
set -euo pipefail

# 独立 Codex E2E 端到端验收循环（默认使用 gpt-6.2-sol + xhigh，不调用 agy，不直接调用 gh）
# 监听带 agy:approved（代码评审已通过）标签的 PR，在独立 worktree 中结合原始 Issue 要求
# 执行真实端到端验收，并通过 gh-state.sh 写回 E2E 验收报告与状态流转：
#   - pass             -> agy:e2e-passed（进入终审合入门禁）
#   - fail             -> agy:changes-requested（代码缺陷，未超轮次时触发 Dev 自动修复；超限切 agy:blocked）
#   - return_to_dev    -> agy:changes-requested（仓库 QA 脚本/准备步骤缺失，交回 Dev 在同一 PR 补齐；超限切 agy:blocked）
#   - return_to_review -> agy:in-review（必验项依赖候选版本尚未支持的能力，交回 Review 核对范围与前置条件）
#   - blocked          -> agy:blocked（外部权限、产品授权或外部环境故障时写清需要谁做什么并暂停）

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
HEAD_BIN="$(resolve_bin head)"
CP_BIN="$(resolve_bin cp)"
MV_BIN="$(resolve_bin mv)"
RM_BIN="$(resolve_bin rm)"
FIND_BIN="$(resolve_bin find)"
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
init_codex_review_profile "codex-e2e-loop.sh" "${1:-run}"

REPO="${REPO:-}"                             # 目标 GitHub 仓库 "owner/repo"
REPO_NAME="${REPO_NAME:-}"                   # 可选：~/.gongcao/repos/<REPO_NAME>
REPO_DIR="${REPO_DIR:-}"                     # 可选：显式本地仓库路径
AUTO_CLONE="${AUTO_CLONE:-1}"                # 未克隆时自动只读克隆到 ~/.gongcao/repos/
LABEL_PREFIX="${LABEL_PREFIX:-agy:}"
E2E_TARGET_LABEL="${E2E_TARGET_LABEL:-${LABEL_PREFIX}approved}" # 默认接收代码评审通过（agy:approved）的 PR
E2E_COMMENT_MARKER="${E2E_COMMENT_MARKER:-<!-- codex-e2e-comment -->}"
REVIEW_COMMENT_MARKER="${REVIEW_COMMENT_MARKER:-<!-- codex-review-comment -->}"
E2E_ENV_FILE="${E2E_ENV_FILE:-}"             # 可选：项目私有 E2E 环境说明文件（留空自动探测 ~/.gongcao/e2e/<repo_slug>.md）
PUBLISH_EVIDENCE="${PUBLISH_EVIDENCE:-1}"    # 是否将 QA 证据归档推送到独立远端分支并在 PR/Issue 关联直链（1=是，0=否）
E2E_EVIDENCE_BRANCH="${E2E_EVIDENCE_BRANCH:-qa/e2e-evidence}" # 独立孤立证据分支（不混入生产代码历史）
MAX_EVIDENCE_FILE_MB="${MAX_EVIDENCE_FILE_MB:-20}" # 单个证据文件最大体积（MB），超出跳过推送避免触发远端限制
CODEX_MODEL="${CODEX_MODEL:-gpt-6.2-sol}"    # 默认使用 GPT-6.2-Sol
CODEX_REASONING_EFFORT="${CODEX_REASONING_EFFORT:-xhigh}" # 默认推理强度 xhigh
# E2E 需要启服务、访问本地数据库/端口/浏览器等；默认使用 danger-full-access 且免交互确认
CODEX_E2E_SANDBOX="${CODEX_E2E_SANDBOX:-danger-full-access}"
CODEX_E2E_BYPASS_APPROVALS="${CODEX_E2E_BYPASS_APPROVALS:-1}" # 1=传 --dangerously-bypass-approvals-and-sandbox；0=仅传 -s "$CODEX_E2E_SANDBOX"
CODEX_TIMEOUT="${CODEX_TIMEOUT:-30m}"        # 单次 E2E 验收超时上限，防止环境挂死
MAX_DIFF_BYTES="${MAX_DIFF_BYTES:-40000}"    # 嵌入 prompt 的 diff 最大字节数
MAX_E2E_ROUNDS="${MAX_E2E_ROUNDS:-3}"        # 最大连续 E2E fail 打回轮数（pass 后清零，blocked 环境受阻不计入），超过则切 blocked
MAX_REPEAT_E2E_STAGE="${MAX_REPEAT_E2E_STAGE:-2}" # 同一 failure_stage 连续 return_to_dev 达到此次数时直接短路切 blocked（防离线 Dev 盲猜）
MAX_TOTAL_E2E_ROUNDS="${MAX_TOTAL_E2E_ROUNDS:-6}" # 单 PR 生命周期硬性总 E2E 轮次上限，防止死循环
MAX_E2E_CRASH_RETRIES="${MAX_E2E_CRASH_RETRIES:-2}" # 同 PR+SHA 连续异常退出/超时重试上限，超过则切 blocked 防止无限叠实例
E2E_PREFLIGHT_CMD="${E2E_PREFLIGHT_CMD:-}" # 可选：拉起 Codex 前执行的宿主机轻量预检命令（0=通过, 10=return_to_dev, 11=return_to_review, 其他=blocked）
E2E_ON_CRASH_CLEANUP_CMD="${E2E_ON_CRASH_CLEANUP_CMD:-}" # 历史兼容：同 E2E_CLEANUP_CMD
E2E_CLEANUP_CMD="${E2E_CLEANUP_CMD:-$E2E_ON_CRASH_CLEANUP_CMD}" # 可选：宿主机幂等资源清理命令（正常结束、崩溃超时、重启恢复与 stop 时触发）
AUTO_REQUEUE_ISSUE="${AUTO_REQUEUE_ISSUE:-1}" # E2E 代码缺陷 fail 时是否将关联 Issue 切为 changes-requested
INIT_LABELS="${INIT_LABELS:-1}"
PR_LIMIT="${PR_LIMIT:-20}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
MAX_BACKOFF="${MAX_BACKOFF:-900}"
DRY_RUN="${DRY_RUN:-0}"

"$MKDIR_BIN" -p "$GONGCAO_HOME" "$REPOS_ROOT" "$STATE_BASE"

# 定位目标仓库目录（与 agy-issue-loop.sh / codex-review-loop.sh 共用 ~/.gongcao/repos/）
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
E2E_ROOT="${E2E_ROOT:-${STATE_ROOT}/e2e}"
LEASES_ROOT="${E2E_ROOT}/active-leases"
REPO_GIT_LOCK="${STATE_ROOT}/repo-git.lock"
if [[ -z "$E2E_ENV_FILE" && -f "${GONGCAO_HOME}/e2e/${REPO_SLUG}.md" ]]; then
  E2E_ENV_FILE="${GONGCAO_HOME}/e2e/${REPO_SLUG}.md"
fi
if [[ -z "$E2E_PREFLIGHT_CMD" && -x "${GONGCAO_HOME}/e2e/${REPO_SLUG}.preflight.sh" ]]; then
  E2E_PREFLIGHT_CMD="${GONGCAO_HOME}/e2e/${REPO_SLUG}.preflight.sh"
fi
if [[ -z "$E2E_CLEANUP_CMD" && -x "${GONGCAO_HOME}/e2e/${REPO_SLUG}.cleanup.sh" ]]; then
  E2E_CLEANUP_CMD="${GONGCAO_HOME}/e2e/${REPO_SLUG}.cleanup.sh"
fi

"$MKDIR_BIN" -p "$STATE_ROOT" "$WORKTREE_ROOT" "$E2E_ROOT" "$LEASES_ROOT"
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

printf '[%s] 启动 codex-e2e-loop\n' "$("$DATE_BIN" '+%F %T')"
printf '  Codex 命令 : %s (model=%s, effort=%s, bypass=%s, sandbox=%s)\n' \
  "$CODEX_BIN" "${CODEX_MODEL:-(codex 默认)}" "${CODEX_REASONING_EFFORT:-(默认)}" \
  "$CODEX_E2E_BYPASS_APPROVALS" "$CODEX_E2E_SANDBOX"
printf '  Codex 配置 : %s\n' "$CODEX_PROFILE_DIR"
printf '  工作主目录 : %s\n' "$GONGCAO_HOME"
printf '  主仓库目录 : %s\n' "$REPO_ROOT"
printf '  E2E 档案根 : %s\n' "$E2E_ROOT"
printf '  E2E 环境档 : %s\n' "${E2E_ENV_FILE:-(按仓库自身文档)}"
printf '  宿主机钩子 : preflight=%s | cleanup=%s\n' "${E2E_PREFLIGHT_CMD:-(无)}" "${E2E_CLEANUP_CMD:-(无)}"
printf '  证据归档   : %s (branch=%s, max=%sMB)\n' "$PUBLISH_EVIDENCE" "$E2E_EVIDENCE_BRANCH" "$MAX_EVIDENCE_FILE_MB"
printf '  监听标签   : %s (MAX_E2E_ROUNDS=%s, MAX_REPEAT_E2E_STAGE=%s, MAX_TOTAL_E2E_ROUNDS=%s, MAX_E2E_CRASH_RETRIES=%s, AUTO_REQUEUE_ISSUE=%s, DRY_RUN=%s)\n' \
  "$E2E_TARGET_LABEL" "$MAX_E2E_ROUNDS" "$MAX_REPEAT_E2E_STAGE" "$MAX_TOTAL_E2E_ROUNDS" "$MAX_E2E_CRASH_RETRIES" "$AUTO_REQUEUE_ISSUE" "$DRY_RUN"

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

write_e2e_schema() {
  local schema_file="$1"
  local req_checks="${2:-[]}"
  local req_plan="${3:-[]}"
  local allowed_ids_json="[]"
  allowed_ids_json="$("$JQ_BIN" -c -L "$SCRIPT_DIR" --argjson checks "$req_checks" --argjson plan "$req_plan" '
    include "workflow-e2e";
    required_e2e_items($checks; $plan) | [.[].id]
  ' <<<"null" 2>/dev/null || printf '[]')"
  "$CAT_BIN" > "$schema_file" <<'EOF'
{
  "type": "object",
  "additionalProperties": false,
  "required": [
    "verdict",
    "summary",
    "environment",
    "failure_stage",
    "reproducible_in_dev_sandbox",
    "scenarios",
    "failure_details",
    "evidence_paths",
    "remaining_risks"
  ],
  "properties": {
    "verdict": {
      "type": "string",
      "enum": ["pass", "fail", "return_to_dev", "return_to_review", "blocked"]
    },
    "summary": {
      "type": "string"
    },
    "environment": {
      "type": "string"
    },
    "failure_stage": {
      "type": "string"
    },
    "reproducible_in_dev_sandbox": {
      "type": "boolean"
    },
    "scenarios": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["id", "name", "status", "details", "evidence_paths"],
        "properties": {
          "id": { "type": "string" },
          "name": { "type": "string" },
          "status": { "type": "string", "enum": ["passed", "failed", "blocked", "skipped"] },
          "details": { "type": "string" },
          "evidence_paths": { "type": "array", "items": { "type": "string" } }
        }
      }
    },
    "failure_details": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["id", "title", "reproduction", "observed", "expected", "closure_criteria"],
        "properties": {
          "id": { "type": "string" },
          "title": { "type": "string" },
          "reproduction": { "type": "string" },
          "observed": { "type": "string" },
          "expected": { "type": "string" },
          "closure_criteria": { "type": "string" }
        }
      }
    },
    "evidence_paths": {
      "type": "array",
      "items": { "type": "string" }
    },
    "remaining_risks": {
      "type": "array",
      "items": { "type": "string" }
    }
  }
}
EOF
  if [[ "$allowed_ids_json" != "[]" ]]; then
    "$JQ_BIN" --argjson ids "$allowed_ids_json" '
      .properties.scenarios.items.properties.id = { "type": "string", "enum": ($ids + [""]) }
    ' "$schema_file" > "${schema_file}.tmp" && "$MV_BIN" "${schema_file}.tmp" "$schema_file"
  fi
}

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

review_e2e_handoff() {
  local pr_num="$1"
  local head_sha="$2"
  local comment
  comment="$(gh_state get-comment pr "$pr_num" "$REVIEW_COMMENT_MARKER")" || return 1
  "$JQ_BIN" -eRsc -L "$SCRIPT_DIR" --arg sha "$head_sha" '
    include "workflow-e2e";
    review_metadata
    | {checks: approved_e2e_checks($sha; ""), plan: approved_e2e_plan($sha; "")}
  ' <<<"$comment"
}

ACTIVE_LEASE_PR=""
ACTIVE_LEASE_ISSUE=""
ACTIVE_LEASE_SHA=""
ACTIVE_LEASE_WT=""
ACTIVE_LEASE_TS=""

write_e2e_lease() {
  local pr_num="$1"
  local issue_num="$2"
  local head_sha="$3"
  local run_ts="$4"
  local wt_dir="$5"
  local lease_file="${LEASES_ROOT}/pr-${pr_num}.json"
  local iso_now
  iso_now="$("$DATE_BIN" --iso-8601=seconds)"
  "$MKDIR_BIN" -p "$LEASES_ROOT"
  "$JQ_BIN" -n \
    --argjson pr_number "$pr_num" \
    --arg issue_number "$issue_num" \
    --arg head_sha "$head_sha" \
    --arg instance_id "gongcao-pr-${pr_num}" \
    --arg worktree "$wt_dir" \
    --arg run_ts "$run_ts" \
    --arg started_at "$iso_now" \
    '{pr_number:$pr_number, issue_number:$issue_number, head_sha:$head_sha, instance_id:$instance_id, worktree:$worktree, run_ts:$run_ts, status:"active", started_at:$started_at, last_error:""}' \
    > "${lease_file}.tmp"
  "$MV_BIN" "${lease_file}.tmp" "$lease_file"
  ACTIVE_LEASE_PR="$pr_num"
  ACTIVE_LEASE_ISSUE="$issue_num"
  ACTIVE_LEASE_SHA="$head_sha"
  ACTIVE_LEASE_WT="$wt_dir"
  ACTIVE_LEASE_TS="$run_ts"
}

run_host_e2e_cleanup() {
  local pr_num="$1"
  local issue_num="$2"
  local head_sha="$3"
  local wt_dir="$4"
  local run_ts="$5"
  local reason="${6:-normal}"
  local lease_file="${LEASES_ROOT}/pr-${pr_num}.json"
  local log_dir="${E2E_ROOT}/pr-${pr_num}"
  "$MKDIR_BIN" -p "$log_dir"
  local cleanup_log="${log_dir}/cleanup-${reason}-${run_ts}.log"

  if [[ -z "$E2E_CLEANUP_CMD" ]]; then
    "$RM_BIN" -f -- "$lease_file" 2>/dev/null || true
    [[ "$ACTIVE_LEASE_PR" == "$pr_num" ]] && ACTIVE_LEASE_PR=""
    return 0
  fi

  local rc=0
  PR_NUM="$pr_num" ISSUE_NUM="$issue_num" HEAD_SHA="$head_sha" \
    E2E_INSTANCE_ID="gongcao-pr-${pr_num}" E2E_WT="$wt_dir" \
    E2E_LEASE_FILE="$lease_file" CLEANUP_REASON="$reason" \
    bash -lc "$E2E_CLEANUP_CMD" >"$cleanup_log" 2>&1 || rc=$?

  if (( rc == 0 )); then
    "$RM_BIN" -f -- "$lease_file" 2>/dev/null || true
    [[ "$ACTIVE_LEASE_PR" == "$pr_num" ]] && ACTIVE_LEASE_PR=""
    return 0
  fi

  local err_snippet="" iso_now=""
  err_snippet="$("$HEAD_BIN" -c 500 "$cleanup_log" 2>/dev/null || true)"
  iso_now="$("$DATE_BIN" --iso-8601=seconds)"
  "$MKDIR_BIN" -p "$LEASES_ROOT"
  "$JQ_BIN" -n \
    --argjson pr_number "$pr_num" \
    --arg issue_number "$issue_num" \
    --arg head_sha "$head_sha" \
    --arg instance_id "gongcao-pr-${pr_num}" \
    --arg worktree "$wt_dir" \
    --arg run_ts "$run_ts" \
    --arg reason "$reason" \
    --arg failed_at "$iso_now" \
    --arg last_error "$err_snippet" \
    --arg log_file "$cleanup_log" \
    '{pr_number:$pr_number, issue_number:$issue_number, head_sha:$head_sha, instance_id:$instance_id, worktree:$worktree, run_ts:$run_ts, status:"cleanup_failed", reason:$reason, failed_at:$failed_at, last_error:$last_error, log_file:$log_file}' \
    > "${lease_file}.tmp"
  "$MV_BIN" "${lease_file}.tmp" "$lease_file"
  [[ "$ACTIVE_LEASE_PR" == "$pr_num" ]] && ACTIVE_LEASE_PR=""
  printf '[%s] 警告：PR #%s 宿主机资源清理失败（reason=%s, exit=%d, log=%s），已保留 cleanup_failed 租约以防资源叠加。\n' \
    "$("$DATE_BIN" '+%F %T')" "$pr_num" "$reason" "$rc" "$cleanup_log" >&2
  return 1
}

recover_stale_e2e_leases() {
  local lf="" l_pr="" l_issue="" l_sha="" l_wt="" l_ts=""
  for lf in "${LEASES_ROOT}"/pr-*.json; do
    [[ -f "$lf" ]] || continue
    l_pr="$("$JQ_BIN" -r '.pr_number // empty' "$lf" 2>/dev/null || true)"
    [[ "$l_pr" =~ ^[0-9]+$ ]] || continue
    l_issue="$("$JQ_BIN" -r '.issue_number // ""' "$lf" 2>/dev/null || true)"
    l_sha="$("$JQ_BIN" -r '.head_sha // ""' "$lf" 2>/dev/null || true)"
    l_wt="$("$JQ_BIN" -r '.worktree // ""' "$lf" 2>/dev/null || true)"
    l_ts="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
    printf '[%s] 检测到未回收的 E2E 资源租约（PR #%s, instance=gongcao-pr-%s），执行启动补偿清理...\n' \
      "$("$DATE_BIN" '+%F %T')" "$l_pr" "$l_pr"
    run_host_e2e_cleanup "$l_pr" "$l_issue" "$l_sha" "$l_wt" "$l_ts" "startup-recovery" || true
  done
}

on_e2e_loop_signal() {
  if [[ -n "$ACTIVE_LEASE_PR" ]]; then
    printf '[%s] 收到停止信号，正在回收 PR #%s 的活跃 E2E 资源租约...\n' \
      "$("$DATE_BIN" '+%F %T')" "$ACTIVE_LEASE_PR" >&2
    run_host_e2e_cleanup "$ACTIVE_LEASE_PR" "$ACTIVE_LEASE_ISSUE" "$ACTIVE_LEASE_SHA" "$ACTIVE_LEASE_WT" "${ACTIVE_LEASE_TS:-shutdown}" "shutdown" || true
  fi
  exit 130
}
trap on_e2e_loop_signal TERM INT

prepare_e2e_worktree() {
  local pr_num="$1"
  local head_branch="$2"
  local head_sha="$3"
  checkout_exact_pr_worktree "${WORKTREE_ROOT}/e2e-pr-${pr_num}" "$pr_num" "$head_branch" "$head_sha"
}

cleanup_e2e_worktree() {
  local wt_dir="$1"
  if [[ -e "${wt_dir}/.git" ]]; then
    "$GIT_BIN" -C "$wt_dir" checkout -- . >/dev/null 2>&1 || true
    "$GIT_BIN" -C "$wt_dir" clean -fd >/dev/null 2>&1 || true
  fi
}

# 将本轮 QA 证据归档到独立的孤立远程分支（绝不污染业务 PR 分支），
# 成功后在 stdout 输出：<evidence_sha>\t<rel_dir>
publish_e2e_evidence() {
  local pr_num="$1"
  local issue_num="$2"
  local head_sha="$3"
  local run_ts="$4"
  local verdict="$5"
  local final_state="$6"
  local result_file="$7"
  local report_file="$8"
  local artifacts_dir="$9"
  local archived_list_file="${10}"
  local review_checks_hash="${11}"

  : > "$archived_list_file"
  local rel_dir="pr-${pr_num}/${run_ts}-${head_sha:0:10}"

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[DRY_RUN] 归档 QA 证据到远端分支 %s:%s\n' "$E2E_EVIDENCE_BRANCH" "$rel_dir" >&2
    printf '(dry-run)\t%s\n' "$rel_dir"
    return 0
  fi

  local ev_wt="${WORKTREE_ROOT}/evidence-branch"
  (
    "$FLOCK_BIN" -x 9
    "$GIT_BIN" -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true
    "$GIT_BIN" -C "$REPO_ROOT" fetch origin "$E2E_EVIDENCE_BRANCH" >/dev/null 2>&1 || true

    if [[ -e "${ev_wt}/.git" ]]; then
      if "$GIT_BIN" -C "$REPO_ROOT" show-ref --verify --quiet "refs/remotes/origin/${E2E_EVIDENCE_BRANCH}"; then
        "$GIT_BIN" -C "$ev_wt" checkout -B "$E2E_EVIDENCE_BRANCH" "origin/${E2E_EVIDENCE_BRANCH}" >/dev/null 2>&1
      else
        "$GIT_BIN" -C "$ev_wt" checkout "$E2E_EVIDENCE_BRANCH" >/dev/null 2>&1 || true
      fi
      "$GIT_BIN" -C "$ev_wt" clean -fd >/dev/null 2>&1 || true
    else
      if "$GIT_BIN" -C "$REPO_ROOT" show-ref --verify --quiet "refs/remotes/origin/${E2E_EVIDENCE_BRANCH}"; then
        "$GIT_BIN" -C "$REPO_ROOT" worktree add --track -b "$E2E_EVIDENCE_BRANCH" "$ev_wt" "origin/${E2E_EVIDENCE_BRANCH}" >&2
      elif "$GIT_BIN" -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/${E2E_EVIDENCE_BRANCH}"; then
        "$GIT_BIN" -C "$REPO_ROOT" worktree add "$ev_wt" "$E2E_EVIDENCE_BRANCH" >&2
      else
        "$GIT_BIN" -C "$REPO_ROOT" worktree add --orphan -b "$E2E_EVIDENCE_BRANCH" "$ev_wt" >&2
      fi
    fi
  ) 9>"$REPO_GIT_LOCK"

  local dest_dir="${ev_wt}/${rel_dir}"
  "$MKDIR_BIN" -p "$dest_dir"
  "$CP_BIN" "$result_file" "${dest_dir}/result.json"
  "$CP_BIN" "$report_file" "${dest_dir}/e2e-report.md"
  printf '%s\n' "result.json" "e2e-report.md" >> "$archived_list_file"

  # 按单文件体积上限拷贝 artifacts_dir 中的证据文件（保留子目录结构）
  local max_bytes=$(( MAX_EVIDENCE_FILE_MB * 1024 * 1024 ))
  if [[ -d "$artifacts_dir" ]]; then
    local f rel_f parent_d
    while IFS= read -r -d '' f; do
      rel_f="${f#${artifacts_dir}/}"
      parent_d="${dest_dir}/artifacts/${rel_f%/*}"
      if [[ "$rel_f" == */* ]]; then
        "$MKDIR_BIN" -p "$parent_d"
      else
        "$MKDIR_BIN" -p "${dest_dir}/artifacts"
      fi
      "$CP_BIN" "$f" "${dest_dir}/artifacts/${rel_f}"
      printf 'artifacts/%s\n' "$rel_f" >> "$archived_list_file"
    done < <("$FIND_BIN" "$artifacts_dir" -type f -size "-${max_bytes}c" -print0 2>/dev/null)
  fi

  local iso_now
  iso_now="$("$DATE_BIN" --iso-8601=seconds)"
  local files_json file_hashes_json
  files_json="$("$JQ_BIN" -R . "$archived_list_file" | "$JQ_BIN" -s '.')"
  file_hashes_json="$({
    while IFS= read -r _af; do
      [[ "$_af" == artifacts/* && -f "${dest_dir}/${_af}" ]] || continue
      _sha="$("$SHA256SUM_BIN" "${dest_dir}/${_af}" 2>/dev/null | awk '{print $1}')"
      _sz="$(wc -c < "${dest_dir}/${_af}" 2>/dev/null | tr -d '[:space:]' || printf '0')"
      [[ "$_sz" =~ ^[0-9]+$ ]] || _sz=0
      "$JQ_BIN" -nc --arg k "$_af" --arg s "$_sha" --argjson sz "$_sz" '{key:$k, value:{sha256:$s, size:$sz}}'
    done < "$archived_list_file"
  } | "$JQ_BIN" -s 'from_entries')"
  "$JQ_BIN" -n \
    --argjson pr_number "$pr_num" \
    --arg issue_number "$issue_num" \
    --arg tested_sha "$head_sha" \
    --arg verdict "$verdict" \
    --arg final_state "$final_state" \
    --arg review_checks_hash "$review_checks_hash" \
    --arg model "${CODEX_MODEL}" \
    --arg reasoning_effort "${CODEX_REASONING_EFFORT}" \
    --arg archived_at "$iso_now" \
    --argjson files "$files_json" \
    --argjson file_hashes "$file_hashes_json" \
    '{
      pr_number: $pr_number,
      issue_number: $issue_number,
      tested_sha: $tested_sha,
      verdict: $verdict,
      final_state: $final_state,
      review_checks_hash: $review_checks_hash,
      model: $model,
      reasoning_effort: $reasoning_effort,
      archived_at: $archived_at,
      files: $files,
      file_hashes: $file_hashes
    }' > "${dest_dir}/manifest.json"
  printf 'manifest.json\n' >> "$archived_list_file"

  "$GIT_BIN" -C "$ev_wt" add -- "$rel_dir" >&2 || return 1
  "$GIT_BIN" -C "$ev_wt" commit -m "qa(e2e): archive evidence for PR #${pr_num} (${head_sha:0:10}, ${verdict})" >&2 || return 1

  if ! "$GIT_BIN" -C "$ev_wt" push -u origin "$E2E_EVIDENCE_BRANCH" >&2; then
    "$GIT_BIN" -C "$ev_wt" pull --rebase origin "$E2E_EVIDENCE_BRANCH" >&2 || return 1
    "$GIT_BIN" -C "$ev_wt" push -u origin "$E2E_EVIDENCE_BRANCH" >&2 || return 1
  fi

  local ev_sha
  ev_sha="$("$GIT_BIN" -C "$ev_wt" rev-parse HEAD)"
  printf '已归档 QA 证据至远端分支 %s (%s): %s\n' "$E2E_EVIDENCE_BRANCH" "${ev_sha:0:10}" "$rel_dir" >&2
  printf '%s\t%s\n' "$ev_sha" "$rel_dir"
}

render_e2e_markdown() {
  local result_file="$1"
  local pr_num="$2"
  local issue_num="$3"
  local head_sha="$4"
  local round="$5"
  local final_state="$6"
  local artifacts_dir="$7"
  local evidence_url="${8:-}"
  local evidence_branch="${9:-}"
  local evidence_sha="${10:-}"
  local evidence_files_md="${11:-}"
  local cycle_round="${12:-$round}"
  local handoff_token="${13:-}"
  local now_ts
  now_ts="$("$DATE_BIN" --iso-8601=seconds)"

  local evidence_cell="\`${artifacts_dir}\` (仅本地)"
  if [[ -n "$evidence_url" ]]; then
    evidence_cell="[查看归档目录](${evidence_url}) (\`${evidence_branch}\` @ \`${evidence_sha:0:10}\`)"
  fi

  local handoff_marker=""
  if [[ -n "$handoff_token" ]]; then
    handoff_marker="<!-- codex-e2e-handoff:${head_sha}:${handoff_token} -->"
  fi

  local e2e_meta_json=""
  e2e_meta_json="$("$JQ_BIN" -c \
    --arg head_sha "$head_sha" \
    --arg final_state "$final_state" \
    '{
      head_sha: $head_sha,
      verdict: .verdict,
      final_state: $final_state,
      failure_stage: (.failure_stage // ""),
      action_items: (
        if (.verdict == "fail" or .verdict == "return_to_dev") then
          [(.failure_details // []) | to_entries[] | {
            id: (if ((.value.id // "") | test("\\S")) then .value.id else ("e2e-item-" + ((.key + 1) | tostring)) end),
            title: (.value.title // ""),
            closure_criteria: (if ((.value.closure_criteria // "") | test("\\S")) then .value.closure_criteria else (.value.expected // .value.title // "") end)
          }]
        else [] end
      )
    }' "$result_file")"

  "$JQ_BIN" -r \
    --arg pr "$pr_num" \
    --arg issue "${issue_num:-(未关联)}" \
    --arg sha "${head_sha:0:10}" \
    --arg round "$round" \
    --arg cycle_round "$cycle_round" \
    --arg max_rounds "$MAX_E2E_ROUNDS" \
    --arg max_total_rounds "$MAX_TOTAL_E2E_ROUNDS" \
    --arg state "${LABEL_PREFIX}${final_state}" \
    --arg model "${CODEX_MODEL:-(codex 默认)}${CODEX_REASONING_EFFORT:+ (${CODEX_REASONING_EFFORT})}" \
    --arg evidence_cell "$evidence_cell" \
    --arg evidence_files_md "$evidence_files_md" \
    --arg handoff_marker "$handoff_marker" \
    --arg e2e_meta_json "$e2e_meta_json" \
    --arg now "$now_ts" \
    '
    def esc: tostring | gsub("\n"; " ") | gsub("\\|"; "\\|");
    "### Codex 独立 E2E 验收报告\n\n"
    + "| 字段 | 值 |\n| --- | --- |\n"
    + "| E2E 结论 | `" + .verdict + "` -> `" + $state + "` |\n"
    + "| 关联 Issue | #" + $issue + " |\n"
    + "| 验收 Commit | `" + $sha + "` |\n"
    + "| E2E 轮次 | 本周期 " + $cycle_round + " / " + $max_rounds + "（累计 " + $round + " / " + $max_total_rounds + "） |\n"
    + "| 验收模型 | `" + $model + "` |\n"
    + "| 验收环境 | " + (.environment | esc) + " |\n"
    + (if .verdict != "pass" and ((.failure_stage // "") | length) > 0 then
        "| 失败检查点 | `" + (.failure_stage | esc) + "`（Dev sandbox 可复现: `" + (if .reproducible_in_dev_sandbox == false then "false" else "true" end) + "`） |\n"
      elif .verdict != "pass" and .reproducible_in_dev_sandbox == false then
        "| Dev sandbox 可复现 | `false` |\n"
      else "" end)
    + "| QA 证据 | " + $evidence_cell + " |\n"
    + "| 验收时间 | " + $now + " |\n\n"
    + "#### 总结\n" + .summary + "\n\n"
    + "#### 端到端场景结果\n"
    + (if (.scenarios | length) > 0 then
        "| 场景 | 结果 | 详情 |\n| --- | --- | --- |\n"
        + ([.scenarios[] | "| " + ((if (.id // "") != "" then .id + " " else "" end) + .name | esc)
          + " | `" + .status + "` | " + (.details | esc)
          + (if (.evidence_paths | length) > 0 then "（证据：" + (.evidence_paths | join("、") | esc) + "）" else "" end)
          + " |"] | join("\n"))
      else
        "- (无场景明细)"
      end)
    + "\n\n#### 失败 / 阻塞详情\n"
    + (if (.failure_details | length) > 0 then
        ([.failure_details[] |
          "- " + (if ((.id // "") | length) > 0 then "`" + .id + "` · " else "" end) + "**" + .title + "**\n"
          + "  - 复现步骤：" + .reproduction + "\n"
          + "  - 实际结果：" + .observed + "\n"
          + "  - 期望结果：" + .expected
          + (if ((.closure_criteria // "") | length) > 0 then "\n  - 关闭条件：" + .closure_criteria else "" end)
        ] | join("\n"))
      else
        "- 无失败项"
      end)
    + "\n\n#### 归档证据与残留风险\n"
    + (if ($evidence_files_md | length) > 0 then
        $evidence_files_md
      elif (.evidence_paths | length) > 0 then
        ([.evidence_paths[] | "- 本地证据: `" + . + "`"] | join("\n"))
      else
        "- 证据: (无额外文件)"
      end)
    + "\n"
    + (if (.remaining_risks | length) > 0 then
        ([.remaining_risks[] | "- 风险: " + .] | join("\n"))
      else
        "- 风险: 无"
      end)
    + (if ($handoff_marker | length) > 0 then "\n\n" + $handoff_marker else "" end)
    + "\n\n<!-- codex-e2e-meta:" + ($e2e_meta_json | gsub("<"; "\\u003c") | gsub(">"; "\\u003e")) + " -->"
    ' "$result_file"
}

classify_e2e_route_category() {
  local verdict="$1"
  local preflight_mode="${2:-0}"
  case "$verdict" in
    pass) printf 'pass' ;;
    fail) printf 'product_fail' ;;
    return_to_dev)
      if [[ "$preflight_mode" == "1" ]]; then printf 'preflight_return_to_dev'; else printf 'qa_return_to_dev'; fi
      ;;
    return_to_review)
      if [[ "$preflight_mode" == "1" ]]; then printf 'preflight_return_to_review'; else printf 'capability_return_to_review'; fi
      ;;
    crash-blocked) printf 'crash_blocked' ;;
    *)
      if [[ "$preflight_mode" == "1" ]]; then printf 'preflight_blocked'; else printf 'env_blocked'; fi
      ;;
  esac
}

record_e2e_attempt() {
  local e2e_dir="$1"
  local attempt_id="$2"
  local pr_num="$3"
  local issue_num="$4"
  local head_sha="$5"
  local round="$6"
  local verdict="$7"
  local final_state="$8"
  local route_category="$9"
  local failure_stage="${10:-}"
  local reproducible="${11:-true}"
  local host_route_override="${12:-}"
  local cleanup_ok="${13:-true}"
  local duration_sec="${14:-0}"
  local ts="${15:-}"

  [[ "$DRY_RUN" == "1" ]] && return 0
  local attempts_file="${e2e_dir}/attempts.jsonl"
  if [[ -f "$attempts_file" ]] && "$JQ_BIN" -e -s --arg id "$attempt_id" 'any(.[]; type == "object" and .attempt_id == $id)' "$attempts_file" >/dev/null 2>&1; then
    return 0
  fi
  [[ -z "$ts" ]] && ts="$("$DATE_BIN" --iso-8601=seconds)"
  "$JQ_BIN" -cn \
    --arg attempt_id "$attempt_id" \
    --argjson pr_number "$pr_num" \
    --arg issue_number "$issue_num" \
    --arg head_sha "$head_sha" \
    --argjson round "$round" \
    --arg verdict "$verdict" \
    --arg final_state "$final_state" \
    --arg route_category "$route_category" \
    --arg failure_stage "$failure_stage" \
    --arg reproducible "$reproducible" \
    --arg host_route_override "$host_route_override" \
    --arg cleanup_ok "$cleanup_ok" \
    --argjson duration_sec "$duration_sec" \
    --arg ts "$ts" \
    '{
      attempt_id: $attempt_id,
      pr_number: $pr_number,
      issue_number: $issue_number,
      head_sha: $head_sha,
      round: $round,
      verdict: $verdict,
      final_state: $final_state,
      route_category: $route_category,
      failure_stage: $failure_stage,
      reproducible_in_dev_sandbox: ($reproducible == "true"),
      host_route_override: $host_route_override,
      cleanup_ok: ($cleanup_ok == "true"),
      duration_sec: $duration_sec,
      ts: $ts
    }' >> "$attempts_file"
}

publish_e2e_handoff() {
  local pending_file="$1"
  local e2e_dir="${pending_file%/*}"
  local pr_num issue_num head_sha verification_key verdict final_state run_ts round cycle_round
  local result_file comment_file artifacts_dir archived_list_file checks_hash pr_url handoff_token extra_notice
  local raw_failure_stage reproducible_in_dev_sandbox host_route_override new_consecutive_failures
  local route_category cleanup_ok elapsed attempt_id end_ts iso_now
  local evidence_sha evidence_rel_dir evidence_url evidence_files_md

  pr_num="$("$JQ_BIN" -r '.meta.pr_number' "$pending_file")" || return 1
  issue_num="$("$JQ_BIN" -r '.meta.issue_number // ""' "$pending_file")" || return 1
  head_sha="$("$JQ_BIN" -r '.meta.head_sha' "$pending_file")" || return 1
  verification_key="$("$JQ_BIN" -r '.verification_key' "$pending_file")" || return 1
  verdict="$("$JQ_BIN" -r '.meta.verdict' "$pending_file")" || return 1
  final_state="$("$JQ_BIN" -r '.meta.final_state' "$pending_file")" || return 1
  run_ts="$("$JQ_BIN" -r '.run_ts' "$pending_file")" || return 1
  round="$("$JQ_BIN" -r '.meta.round' "$pending_file")" || return 1
  cycle_round="$("$JQ_BIN" -r '.meta.cycle_round' "$pending_file")" || return 1
  result_file="$("$JQ_BIN" -r '.result_file' "$pending_file")" || return 1
  comment_file="$("$JQ_BIN" -r '.comment_file' "$pending_file")" || return 1
  artifacts_dir="$("$JQ_BIN" -r '.artifacts_dir' "$pending_file")" || return 1
  archived_list_file="$("$JQ_BIN" -r '.archived_list_file' "$pending_file")" || return 1
  checks_hash="$("$JQ_BIN" -r '.checks_hash // ""' "$pending_file")" || return 1
  pr_url="$("$JQ_BIN" -r '.meta.pr_url // ""' "$pending_file")" || return 1
  handoff_token="$("$JQ_BIN" -r '.handoff_token // ""' "$pending_file")" || return 1
  extra_notice="$("$JQ_BIN" -r '.extra_notice // ""' "$pending_file")" || return 1
  raw_failure_stage="$("$JQ_BIN" -r '.meta.failure_stage // ""' "$pending_file")" || return 1
  reproducible_in_dev_sandbox="$("$JQ_BIN" -r 'if .meta.reproducible_in_dev_sandbox == false then "false" else "true" end' "$pending_file")" || return 1
  host_route_override="$("$JQ_BIN" -r '.meta.host_route_override // ""' "$pending_file")" || return 1
  new_consecutive_failures="$("$JQ_BIN" -r '.meta.consecutive_failures // 0' "$pending_file")" || return 1
  route_category="$("$JQ_BIN" -r '.route_category // ""' "$pending_file")" || return 1
  cleanup_ok="$("$JQ_BIN" -r 'if .cleanup_ok == false then "false" else "true" end' "$pending_file")" || return 1
  elapsed="$("$JQ_BIN" -r '.elapsed // 0' "$pending_file")" || return 1
  attempt_id="$("$JQ_BIN" -r '.attempt_id' "$pending_file")" || return 1

  # 若 PR 尚未切标且远端已推送新提交，作废旧 SHA 的待交接结果，避免覆盖新提交状态
  if ! "$JQ_BIN" -e '.pr_state_written // false' "$pending_file" >/dev/null; then
    local live_pr_json="" live_sha=""
    if live_pr_json="$(gh_state get-pr "$pr_num" 2>/dev/null)" && "$JQ_BIN" -e 'type == "object"' >/dev/null 2>&1 <<<"$live_pr_json"; then
      live_sha="$("$JQ_BIN" -r '.headRefOid // ""' <<<"$live_pr_json")"
      if [[ -n "$live_sha" && "$live_sha" != "$head_sha" ]]; then
        printf '[%s] 警告：PR #%s 最新提交已变为 %s（原待交接提交 %s），作废过期 E2E 待交接记录。\n' \
          "$("$DATE_BIN" '+%F %T')" "$pr_num" "${live_sha:0:10}" "${head_sha:0:10}" >&2
        "$RM_BIN" -f -- "$pending_file" || true
        return 0
      fi
    fi
  fi

  # 1. 远端 QA 证据归档（PUBLISH_EVIDENCE=1 时必须成功，瞬断失败则下轮重试，绝不无归档推进状态）
  evidence_sha="$("$JQ_BIN" -r '.meta.evidence_commit // ""' "$pending_file")"
  evidence_rel_dir="$("$JQ_BIN" -r '.evidence_rel_dir // ""' "$pending_file")"
  evidence_url="$("$JQ_BIN" -r '.meta.evidence_url // ""' "$pending_file")"
  evidence_files_md="$("$JQ_BIN" -r '.evidence_files_md // ""' "$pending_file")"
  if [[ "$PUBLISH_EVIDENCE" == "1" ]] && ! "$JQ_BIN" -e '.evidence_published // false' "$pending_file" >/dev/null; then
    local base_e2e_md="" pub_out="" repo_web_base="" local_lines="" af="" e2e_md=""
    base_e2e_md="$(render_e2e_markdown "$result_file" "$pr_num" "$issue_num" "$head_sha" "$round" "$final_state" "$artifacts_dir" "" "" "" "" "$cycle_round" "$handoff_token")${extra_notice}"
    printf '%s\n' "$base_e2e_md" > "$comment_file"
    if ! pub_out="$(publish_e2e_evidence "$pr_num" "$issue_num" "$head_sha" "$run_ts" "$verdict" "$final_state" "$result_file" "$comment_file" "$artifacts_dir" "$archived_list_file" "$checks_hash")"; then
      printf '[%s] 警告：归档 PR #%s QA 证据到远端分支 %s 失败，将保留待交接记录并重试。\n' \
        "$("$DATE_BIN" '+%F %T')" "$pr_num" "$E2E_EVIDENCE_BRANCH" >&2
      return 1
    fi
    evidence_sha="${pub_out%%$'\t'*}"
    evidence_rel_dir="${pub_out#*$'\t'}"
    evidence_url=""
    evidence_files_md=""
    repo_web_base="${pr_url%/pull/*}"
    if [[ -n "$repo_web_base" && "$repo_web_base" != "$pr_url" && -n "$evidence_sha" && "$evidence_sha" != "(dry-run)" ]]; then
      evidence_url="${repo_web_base}/tree/${evidence_sha}/${evidence_rel_dir}"
      local_lines=""
      while IFS= read -r af; do
        [[ -z "$af" ]] && continue
        local_lines+="- [\`${af}\`](${repo_web_base}/blob/${evidence_sha}/${evidence_rel_dir}/${af})"$'\n'
      done < "$archived_list_file"
      evidence_files_md="${local_lines%$'\n'}"
    fi
    e2e_md="$(render_e2e_markdown "$result_file" "$pr_num" "$issue_num" "$head_sha" "$round" "$final_state" "$artifacts_dir" "$evidence_url" "$E2E_EVIDENCE_BRANCH" "$evidence_sha" "$evidence_files_md" "$cycle_round" "$handoff_token")${extra_notice}"
    printf '%s\n' "$e2e_md" > "$comment_file"
    "$JQ_BIN" \
      --arg comment "$e2e_md" \
      --arg ev_sha "$evidence_sha" \
      --arg ev_rel "$evidence_rel_dir" \
      --arg ev_url "$evidence_url" \
      --arg ev_md "$evidence_files_md" \
      '.evidence_published = true
       | .comment = $comment
       | .evidence_rel_dir = $ev_rel
       | .evidence_files_md = $ev_md
       | .meta.evidence_commit = $ev_sha
       | .meta.evidence_url = $ev_url' \
      "$pending_file" > "${pending_file}.tmp" || return 1
    "$MV_BIN" "${pending_file}.tmp" "$pending_file" || return 1
  fi

  # 2. 写回 PR E2E 评论
  if ! "$JQ_BIN" -e '.pr_comment_written // false' "$pending_file" >/dev/null; then
    "$JQ_BIN" -r '.comment' "$pending_file" | gh_state comment pr "$pr_num" - "$E2E_COMMENT_MARKER" || return 1
    "$JQ_BIN" '.pr_comment_written = true' "$pending_file" > "${pending_file}.tmp" || return 1
    "$MV_BIN" "${pending_file}.tmp" "$pending_file" || return 1
  fi

  # 3. 切 PR 标签前幂等记录本地状态（避免重启重复计轮）
  if ! "$JQ_BIN" -e '.local_recorded // false' "$pending_file" >/dev/null; then
    iso_now="$("$DATE_BIN" --iso-8601=seconds)"
    if [[ "$DRY_RUN" != "1" ]]; then
      local fh_file="${e2e_dir}/e2e-failure-history.jsonl"
      local vsha_file="${e2e_dir}/verified_shas.txt"
      local c_file="${e2e_dir}/consecutive_failures.txt"
      record_e2e_attempt "$e2e_dir" "$attempt_id" "$pr_num" "$issue_num" "$head_sha" "$round" \
        "$verdict" "$final_state" "$route_category" "$raw_failure_stage" "$reproducible_in_dev_sandbox" \
        "$host_route_override" "$cleanup_ok" "$elapsed" "$iso_now"
      if [[ "$verdict" == "pass" || -n "$host_route_override" ]]; then
        : > "$fh_file"
      elif [[ "$verdict" != "blocked" && "$final_state" != "blocked" ]]; then
        "$JQ_BIN" -cn \
          --argjson round "$round" \
          --arg head_sha "$head_sha" \
          --arg verdict "$verdict" \
          --arg failure_stage "$raw_failure_stage" \
          --arg reproducible "$reproducible_in_dev_sandbox" \
          --arg final_state "$final_state" \
          --arg updated_at "$iso_now" \
          '{round:$round, head_sha:$head_sha, verdict:$verdict, failure_stage:$failure_stage, reproducible_in_dev_sandbox:($reproducible == "true"), final_state:$final_state, updated_at:$updated_at}' \
          >> "$fh_file"
      fi
      if [[ "$verdict" != "blocked" && -z "$host_route_override" ]]; then
        "$TOUCH_BIN" "$vsha_file"
        if ! "$GREP_BIN" -Fqx -- "$verification_key" "$vsha_file"; then
          printf '%s\n' "$verification_key" >> "$vsha_file"
        fi
        printf '%d\n' "$new_consecutive_failures" > "$c_file"
      fi
    fi
    "$JQ_BIN" '.meta' "$pending_file" > "${e2e_dir}/meta.json" || return 1
    "$JQ_BIN" '.local_recorded = true' "$pending_file" > "${pending_file}.tmp" || return 1
    "$MV_BIN" "${pending_file}.tmp" "$pending_file" || return 1
  fi

  # 4. 切换 PR 标签
  if ! "$JQ_BIN" -e '.pr_state_written // false' "$pending_file" >/dev/null; then
    gh_state set-state pr "$pr_num" "$final_state" || return 1
    "$JQ_BIN" '.pr_state_written = true' "$pending_file" > "${pending_file}.tmp" || return 1
    "$MV_BIN" "${pending_file}.tmp" "$pending_file" || return 1
  fi

  # 5. 同步关联 Issue 评论与状态
  if [[ -n "$issue_num" ]] && { [[ "$final_state" == "e2e-passed" || "$final_state" == "blocked" || "$final_state" == "in-review" ]] || [[ "$final_state" == "changes-requested" && "$AUTO_REQUEUE_ISSUE" == "1" ]]; }; then
    if ! "$JQ_BIN" -e '.issue_comment_written // false' "$pending_file" >/dev/null; then
      "$JQ_BIN" -r '.comment' "$pending_file" | gh_state comment issue "$issue_num" - "$E2E_COMMENT_MARKER" || return 1
      "$JQ_BIN" '.issue_comment_written = true' "$pending_file" > "${pending_file}.tmp" || return 1
      "$MV_BIN" "${pending_file}.tmp" "$pending_file" || return 1
    fi
    gh_state set-state issue "$issue_num" "$final_state" || return 1
  fi

  # 退回复审/开发或阻塞时清理本 PR 的评审交接缓存，确保下次轮询立即读取最新评审必验场景
  if [[ "$verdict" != "pass" ]]; then
    unset "review_cache_keys[$pr_num]" "review_cache_times[$pr_num]" "review_cache_checks[$pr_num]" "review_cache_plans[$pr_num]" 2>/dev/null || true
  fi

  "$RM_BIN" -- "$pending_file" || return 1
  end_ts="$("$DATE_BIN" '+%F %T')"
  printf '\n============================================================\n'
  printf '[%s] [DONE] PR #%s Codex E2E 验收完成 (本周期第 %d/%d 轮, 累计第 %d/%d 轮, 耗时 %ds)\n' \
    "$end_ts" "$pr_num" "$cycle_round" "$MAX_E2E_ROUNDS" "$round" "$MAX_TOTAL_E2E_ROUNDS" "$elapsed"
  printf '  E2E 结论 : %s -> %s%s\n' "$verdict" "$LABEL_PREFIX" "$final_state"
  printf '  证据目录 : %s\n' "$artifacts_dir"
  [[ -n "$evidence_url" ]] && printf '  远端归档 : %s\n' "$evidence_url"
  printf '============================================================\n\n'
  printf '[%s] [codex-e2e] PR #%s (Issue #%s, r%d) -> %s (%s%s, %ds) %s\n' \
    "$end_ts" "$pr_num" "${issue_num:-?}" "$round" "$verdict" "$LABEL_PREFIX" "$final_state" "$elapsed" "${evidence_url:-$artifacts_dir}" >> "$ACTIVITY_LOG"
}

retry_e2e_handoff() {
  local pending_file="$1"
  local pending_pr=""
  pending_pr="$("$JQ_BIN" -r '.meta.pr_number // empty' "$pending_file" 2>/dev/null || true)"
  if publish_e2e_handoff "$pending_file"; then
    "$SLEEP_BIN" 5
  else
    printf '[%s] 警告：PR #%s E2E 交接失败，%ss 后重试已保存的验收结果。\n' \
      "$("$DATE_BIN" '+%F %T')" "${pending_pr:-${pr_num:-?}}" "$POLL_INTERVAL" >&2
    "$SLEEP_BIN" "$POLL_INTERVAL"
  fi
}

consecutive_poll_errors=0
idle_announced=0
ACTIVITY_LOG="${STATE_ROOT}/activity.log"
declare -A review_cache_keys=() review_cache_times=() review_cache_checks=() review_cache_plans=()

if [[ "$DRY_RUN" != "1" ]]; then
  recover_stale_e2e_leases
fi

while true; do
  if [[ "$INIT_LABELS" == "1" && "$LABELS_READY" == "0" ]]; then
    if gh_state init-labels; then
      LABELS_READY=1
    fi
  fi

  # 若某 PR 已切离 E2E 标签但关联 Issue 交接尚未完成，先续完残余交接。
  if [[ "$DRY_RUN" != "1" ]]; then
    pending_issue_handoff=""
    for _pf in "${E2E_ROOT}"/pr-*/pending-e2e.json; do
      [[ -f "$_pf" ]] || continue
      if "$JQ_BIN" -e '.pr_state_written == true' "$_pf" >/dev/null 2>&1; then
        pending_issue_handoff="$_pf"
        break
      fi
    done
    if [[ -n "$pending_issue_handoff" ]]; then
      idle_announced=0
      retry_e2e_handoff "$pending_issue_handoff"
      continue
    fi
  fi

  prs_json=""
  if ! prs_json="$(gh_state list-prs open "$E2E_TARGET_LABEL" "$PR_LIMIT")" \
    || ! "$JQ_BIN" -e 'type == "array"' >/dev/null 2>&1 <<<"$prs_json"; then
    consecutive_poll_errors=$((consecutive_poll_errors + 1))
    wait_sec="$(calc_backoff "$consecutive_poll_errors")"
    printf '[%s] 警告：拉取待 E2E 验收 PR 列表失败（连续第 %d 次），%ss 后重试...\n' \
      "$("$DATE_BIN" '+%F %T')" "$consecutive_poll_errors" "$wait_sec" >&2
    "$SLEEP_BIN" "$wait_sec"
    continue
  fi
  consecutive_poll_errors=0

  # 按编号顺序选取尚未实测的提交与必验场景（或有待续完交接的 PR）。
  next_pr_json=""
  required_plan="[]"
  while IFS= read -r row; do
    pnum="$("$JQ_BIN" -r '.number' <<<"$row")"
    psha="$("$JQ_BIN" -r '.headRefOid // empty' <<<"$row")"
    if "$JQ_BIN" -e '.mergeable == "CONFLICTING" or .mergeStateStatus == "DIRTY"' >/dev/null <<<"$row"; then
      next_pr_json="$row"
      break
    fi
    cache_key="$psha:$("$JQ_BIN" -r '.updatedAt // ""' <<<"$row")"
    if [[ "${review_cache_keys[$pnum]-}" == "$cache_key" ]] \
      && (( SECONDS - review_cache_times[$pnum] < 300 )); then
      required_checks="${review_cache_checks[$pnum]}"
      required_plan="${review_cache_plans[$pnum]}"
    elif handoff_json="$(review_e2e_handoff "$pnum" "$psha")"; then
      # PR 更新立即失效，定期重读以发现单独编辑过的评审评论。
      required_checks="$("$JQ_BIN" -c '.checks' <<<"$handoff_json")"
      required_plan="$("$JQ_BIN" -c '.plan // []' <<<"$handoff_json")"
      review_cache_keys[$pnum]="$cache_key"
      review_cache_times[$pnum]="$SECONDS"
      review_cache_checks[$pnum]="$required_checks"
      review_cache_plans[$pnum]="$required_plan"
    else
      printf '[%s] 警告：无法读取 PR #%s（%s）的评审验收交接，将在后续轮询重试。\n' \
        "$("$DATE_BIN" '+%F %T')" "$pnum" "${psha:0:10}" >&2
      continue
    fi
    verification_key="$psha"
    checks_hash=""
    if [[ "$required_checks" != "[]" ]]; then
      checks_hash="$(printf '%s' "$required_checks" | "$SHA256SUM_BIN")"
      checks_hash="${checks_hash%% *}"
      verification_key+=":${checks_hash}"
    fi
    pending_file="${E2E_ROOT}/pr-${pnum}/pending-e2e.json"
    if [[ "$DRY_RUN" != "1" && -f "$pending_file" ]] \
      && "$JQ_BIN" -e --arg key "$verification_key" '.verification_key == $key' "$pending_file" >/dev/null 2>&1; then
      next_pr_json="$row"
      break
    fi
    sha_file="${E2E_ROOT}/pr-${pnum}/verified_shas.txt"
    last_verification_key=""
    if [[ -n "$psha" && -f "$sha_file" ]]; then
      while IFS= read -r recorded_key; do
        if [[ "${recorded_key%%:*}" == "$psha" ]]; then
          last_verification_key="$recorded_key"
        fi
      done < "$sha_file"
    fi
    if [[ -n "$last_verification_key" && "$verification_key" == "$last_verification_key" ]]; then
      continue
    fi
    next_pr_json="$row"
    break
  done < <("$JQ_BIN" -c 'sort_by(.number) | .[]' <<<"$prs_json")

  if [[ -z "$next_pr_json" ]]; then
    if (( idle_announced == 0 )); then
      printf '[%s] 空闲等待中：暂无待 Codex E2E 验收的 PR（每 %ss 后台轮询一次）...\n' "$("$DATE_BIN" '+%F %T')" "$POLL_INTERVAL"
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

  # 前置冲突拦截：存在合并冲突的 PR 不做 E2E，直接退回开发循环解冲突
  if [[ "$mergeable" == "CONFLICTING" || "$merge_state" == "DIRTY" ]]; then
    issue_num="$(extract_linked_issue "$pr_body" "$head_branch")"
    conflict_md="$("$CAT_BIN" <<EOF
### Codex E2E 验收前置拦截：存在合并冲突

- PR #${pr_num}（\`${head_branch}\` -> \`${base_branch}\`）当前合并状态为 \`${mergeable:-CONFLICTING}\` / \`${merge_state:-DIRTY}\`。
- 已将状态切为 \`${LABEL_PREFIX}changes-requested\`，请先同步最新 \`${base_branch}\` 并解决合并冲突后再进入 E2E 验收（本次不消耗 E2E 轮次）。
EOF
)"
    printf '%s\n' "$conflict_md" | gh_state comment pr "$pr_num" - "$E2E_COMMENT_MARKER" || true
    gh_state set-state pr "$pr_num" changes-requested || true
    if [[ -n "$issue_num" && "$AUTO_REQUEUE_ISSUE" == "1" ]]; then
      gh_state set-state issue "$issue_num" changes-requested || true
      printf '%s\n' "$conflict_md" | gh_state comment issue "$issue_num" - "$E2E_COMMENT_MARKER" || true
    fi
    end_ts="$("$DATE_BIN" '+%F %T')"
    printf '[%s] PR #%s 存在合并冲突 (%s/%s)，已直接退回 %schanges-requested\n' \
      "$end_ts" "$pr_num" "$mergeable" "$merge_state" "$LABEL_PREFIX"
    printf '[%s] [codex-e2e] PR #%s (Issue #%s) -> conflict-requeued (%schanges-requested)\n' \
      "$end_ts" "$pr_num" "${issue_num:-?}" "$LABEL_PREFIX" >> "$ACTIVITY_LOG"
    "$SLEEP_BIN" 5
    continue
  fi

  e2e_dir="${E2E_ROOT}/pr-${pr_num}"
  "$MKDIR_BIN" -p "$e2e_dir"
  sha_file="${e2e_dir}/verified_shas.txt"
  "$TOUCH_BIN" "$sha_file"
  pending_file="${e2e_dir}/pending-e2e.json"
  if [[ "$DRY_RUN" == "1" ]]; then
    pending_file="${e2e_dir}/pending-e2e-dry-run.json"
  elif [[ -f "$pending_file" ]] \
    && "$JQ_BIN" -e --arg key "$verification_key" '.verification_key == $key' "$pending_file" >/dev/null 2>&1; then
    retry_e2e_handoff "$pending_file"
    continue
  fi

  prev_rounds=0
  while IFS= read -r _line; do
    [[ -n "$_line" ]] && prev_rounds=$((prev_rounds + 1))
  done < "$sha_file"
  current_round=$((prev_rounds + 1))

  consec_file="${e2e_dir}/consecutive_failures.txt"
  prev_consecutive_failures=0
  if [[ -f "$consec_file" ]]; then
    _raw_consec="$(<"$consec_file")"
    _raw_consec="${_raw_consec//$'\r'/}"
    _raw_consec="${_raw_consec//$'\n'/}"
    if [[ "$_raw_consec" =~ ^[0-9]+$ ]]; then
      prev_consecutive_failures="$_raw_consec"
    fi
  else
    for _rf in "${e2e_dir}"/result-*.json; do
      [[ -s "$_rf" ]] || continue
      _v="$("$JQ_BIN" -r '.verdict // empty' "$_rf" 2>/dev/null || true)"
      if [[ "$_v" == "pass" ]]; then
        prev_consecutive_failures=0
      elif [[ "$_v" == "fail" ]]; then
        prev_consecutive_failures=$((prev_consecutive_failures + 1))
      fi
    done
  fi
  cycle_round=$((prev_consecutive_failures + 1))

  run_ts="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
  artifacts_dir="${e2e_dir}/artifacts-${run_ts}"
  "$MKDIR_BIN" -p "$artifacts_dir"
  schema_file="${e2e_dir}/schema.json"
  prompt_file="${e2e_dir}/prompt-${run_ts}.md"
  events_file="${e2e_dir}/events-${run_ts}.jsonl"
  result_file="${e2e_dir}/result-${run_ts}.json"
  comment_file="${e2e_dir}/e2e-comment.md"
  meta_file="${e2e_dir}/meta.json"
  write_e2e_schema "$schema_file" "$required_checks" "$required_plan"

  issue_num="$(extract_linked_issue "$pr_body" "$head_branch")"
  issue_section="（未识别到关联 Issue，请依据 PR 描述与变更内容设计并执行端到端验证）"
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

  required_checks_section=""
  if [[ "$required_checks" != "[]" ]]; then
    if "$JQ_BIN" -e -L "$SCRIPT_DIR" 'include "workflow-e2e"; valid_e2e_plan' <<<"$required_plan" >/dev/null 2>&1; then
      required_checks_section=$'\n\n'"## 当前提交的 E2E 必验场景（权威 ID 与前置计划，\`scenarios[].id\` 必须严格使用下列 ID）"$'\n'
      required_checks_section+="$("$JQ_BIN" -r '
        .[] | "- `" + (.id // "") + "` " + (.scenario // "") + " · 入口 `" + (.entrypoint // "") + "` · 能力依据：" + (.capability_basis // "")
          + " · 轻量预检：" + (.preflight_hint // "")
          + (if .preserve_first_run == true then " · **必须保留首跑产物于 `attempt-1/` 目录不被覆盖**" else "" end)
      ' <<<"$required_plan" 2>/dev/null || true)"
      required_checks_section+=$'\n\n'"### 评审补充细则（e2e_checks 原文，不重新编号）"$'\n'
      required_checks_section+="$("$JQ_BIN" -r '.[] | "- " + .' <<<"$required_checks")"
    else
      required_checks_section=$'\n\n'"## 当前提交的 E2E 必验场景"$'\n'
      required_checks_section+="$("$JQ_BIN" -r -L "$SCRIPT_DIR" '
        include "workflow-e2e"; numbered_e2e_checks[] | "- " + .id + " " + .description
      ' <<<"$required_checks")"
    fi
  fi
  plan_file="${e2e_dir}/plan-${run_ts}.json"
  printf '%s\n' "$required_plan" > "$plan_file"

  # 启动前先核对是否存在未回收或 cleanup_failed 的旧资源租约，阻止叠加实例
  preflight_short_circuited=0
  cleanup_ok="true"
  existing_lease="${LEASES_ROOT}/pr-${pr_num}.json"
  if [[ "$DRY_RUN" != "1" && -f "$existing_lease" ]]; then
    if ! run_host_e2e_cleanup "$pr_num" "$issue_num" "$head_sha" "${WORKTREE_ROOT}/e2e-pr-${pr_num}" "$run_ts" "pre-run-recovery"; then
      lease_err="$("$JQ_BIN" -r '.last_error // "宿主机清理命令返回非零"' "$existing_lease" 2>/dev/null || printf '宿主机清理命令返回非零')"
      "$JQ_BIN" -n \
        --arg env "宿主机资源租约门禁" \
        --arg err "$lease_err" \
        --arg inst "gongcao-pr-${pr_num}" \
        '{
          verdict: "blocked",
          summary: ("PR 实例 " + $inst + " 上次宿主机资源清理失败，补偿清理仍未通过，已暂停启动新实例以防环境叠加。"),
          environment: $env,
          failure_stage: "cleanup-gate",
          reproducible_in_dev_sandbox: false,
          scenarios: [],
          failure_details: [{
            id: "host-cleanup-failed",
            title: ("实例 " + $inst + " 残留资源未清理完成"),
            reproduction: ("宿主机执行 E2E_CLEANUP_CMD 回收 " + $inst),
            observed: $err,
            expected: "幂等清理返回 0 并移除租约后方可再次启动",
            closure_criteria: ("人工确认 " + $inst + " 容器/浏览器/profile 已清理后清除租约并重跑")
          }],
          evidence_paths: [],
          remaining_risks: [("清理失败详情：" + $err)]
        }' > "$result_file"
      preflight_short_circuited=1
      cleanup_ok="false"
    fi
  fi

  printf '[%s] 开始 Codex E2E 验收 PR #%s (Issue #%s, sha=%s, 本周期第 %d/%d 轮, 累计第 %d/%d 轮)...\n' \
    "$("$DATE_BIN" '+%F %T')" "$pr_num" "${issue_num:-?}" "${head_sha:0:10}" "$cycle_round" "$MAX_E2E_ROUNDS" "$current_round" "$MAX_TOTAL_E2E_ROUNDS"

  preflight_short_circuited="${preflight_short_circuited:-0}"
  cleanup_ok="${cleanup_ok:-true}"
  preflight_section=""
  e2e_wt=""
  if (( preflight_short_circuited == 0 )); then
    if ! e2e_wt="$(prepare_e2e_worktree "$pr_num" "$head_branch" "$head_sha")"; then
      printf '[%s] 警告：为 PR #%s 准备 E2E worktree 失败，%ss 后重试...\n' \
        "$("$DATE_BIN" '+%F %T')" "$pr_num" "$POLL_INTERVAL" >&2
      "$SLEEP_BIN" "$POLL_INTERVAL"
      continue
    fi

    # 若配置了宿主机轻量预检适配器，在启动重型 Codex E2E 前先执行零 Token 预检
    if [[ -n "$E2E_PREFLIGHT_CMD" ]]; then
      preflight_out="${artifacts_dir}/preflight.log"
      : > "$preflight_out"
      preflight_rc=0
      PR_NUM="$pr_num" ISSUE_NUM="$issue_num" HEAD_SHA="$head_sha" \
        E2E_INSTANCE_ID="gongcao-pr-${pr_num}" E2E_WT="$e2e_wt" \
        E2E_PLAN_FILE="$plan_file" PREFLIGHT_OUT="$preflight_out" \
        ARTIFACTS_DIR="$artifacts_dir" \
        bash -lc "$E2E_PREFLIGHT_CMD" >>"$preflight_out" 2>&1 || preflight_rc=$?
      preflight_snippet="$("$HEAD_BIN" -c 4000 "$preflight_out" 2>/dev/null || true)"
      if (( preflight_rc == 0 )); then
        if [[ -n "$preflight_snippet" ]]; then
          preflight_section=$'\n\n'"## 宿主机轻量预检结果（已通过）"$'\n''```text'$'\n'"${preflight_snippet}"$'\n''```'
        fi
      else
        preflight_verdict="blocked"
        preflight_title="宿主机轻量预检失败（外部环境/依赖未就绪）"
        preflight_repro="宿主机执行轻量预检 E2E_PREFLIGHT_CMD（exit=${preflight_rc}）"
        preflight_expected="预检通过（exit=0）后进入完整真实 E2E 验收"
        preflight_reproducible="false"
        if (( preflight_rc == 10 )); then
          preflight_verdict="return_to_dev"
          preflight_title="宿主机预检发现仓库 QA 入口或准备步骤缺失"
          preflight_expected="在当前 PR 补齐维护 QA 入口注册、预检或准备步骤并使轻量预检返回 0"
          preflight_reproducible="true"
        elif (( preflight_rc == 11 )); then
          preflight_verdict="return_to_review"
          preflight_title="宿主机预检发现必验项依赖候选版本尚未支持的能力"
          preflight_expected="由评审核对 Issue 范围、候选能力与已有单测覆盖，收敛 e2e_checks 或提供可用准备路径"
          preflight_reproducible="false"
        fi
        "$JQ_BIN" -n \
          --arg verdict "$preflight_verdict" \
          --arg title "$preflight_title" \
          --arg repro "$preflight_repro" \
          --arg obs "${preflight_snippet:-(无预检输出)}" \
          --arg exp "$preflight_expected" \
          --arg rep "$preflight_reproducible" \
          '{
            verdict: $verdict,
            summary: ($title + "（宿主机轻量预检零 Token 短路，未启动完整浏览器/引擎会话）。"),
            environment: "宿主机轻量预检适配器",
            failure_stage: "preflight",
            reproducible_in_dev_sandbox: ($rep == "true"),
            scenarios: [],
            failure_details: [{
              id: ("preflight-" + $verdict),
              title: $title,
              reproduction: $repro,
              observed: $obs,
              expected: $exp,
              closure_criteria: $exp
            }],
            evidence_paths: ["preflight.log"],
            remaining_risks: []
          }' > "$result_file"
        preflight_short_circuited=1
      fi
    fi
  fi

  pr_diff_raw="$(gh_state get-pr-diff "$pr_num" 2>/dev/null || true)"
  # 使用纯 Bash 切片截断，避免 set -o pipefail 下 printf | head 触发 SIGPIPE (141) 退出
  pr_diff_snippet="${pr_diff_raw:0:MAX_DIFF_BYTES}"
  if (( ${#pr_diff_raw} > MAX_DIFF_BYTES )); then
    pr_diff_snippet="${pr_diff_snippet}"$'\n\n'"... (diff 已截断，可在当前工作区用 git diff origin/${base_branch}...HEAD 查看)"
  fi

  env_file_section=""
  if [[ -n "$E2E_ENV_FILE" && -f "$E2E_ENV_FILE" ]]; then
    env_file_content="$("$CAT_BIN" "$E2E_ENV_FILE")"
    env_file_section=$'\n\n'"## 外部 E2E 环境说明（来自 ${E2E_ENV_FILE}）"$'\n'"${env_file_content}"
  fi

  failure_history_file="${e2e_dir}/e2e-failure-history.jsonl"
  failure_history_section=""
  if [[ -s "$failure_history_file" ]]; then
    _fh_md="$("$JQ_BIN" -rs '
      map(select(type == "object"))
      | if length == 0 then ""
        else
          map("- r" + ((.round // "?") | tostring) + " (`" + ((.head_sha // "")[0:10]) + "`): verdict=`" + (.verdict // "") + "`, failure_stage=`" + ((.failure_stage // "(未标注)")) + "`, reproducible_in_dev_sandbox=`" + (if .reproducible_in_dev_sandbox == false then "false" else "true" end) + "`")
          | join("\n")
        end
    ' "$failure_history_file" 2>/dev/null || true)"
    if [[ -n "$_fh_md" ]]; then
      failure_history_section=$'\n\n'"## 本周期历史 E2E 失败检查点（沿用一致的 failure_stage 标识，避免反复盲猜）"$'\n'"${_fh_md}"
    fi
  fi

  "$CAT_BIN" > "$prompt_file" <<EOF
你是一名独立的 E2E（端到端）验收测试工程师。请严格按照目标仓库的验收规范，在目标验收环境中对以下已通过代码评审的 Pull Request 执行端到端验收，核实 Issue 要求的功能在真实链路下是否真正可用。

## PR 信息
- PR: #${pr_num} (${pr_url})
- 标题: ${pr_title}
- 分支: \`${head_branch}\` -> \`${base_branch}\`
- 验收 Commit: \`${head_sha}\`
- E2E 轮次: 本周期第 ${cycle_round} / ${MAX_E2E_ROUNDS} 轮（累计第 ${current_round} / ${MAX_TOTAL_E2E_ROUNDS} 轮）
- 建议隔离实例 ID: \`gongcao-pr-${pr_num}\`（同一 PR 固定复用此确定性 ID，启动前先销毁同名残留，禁止叠加多套带时间戳的运行实例）

### PR 描述
${pr_body:-"(empty)"}

## 关联 Issue 要求
${issue_section}${env_file_section}${required_checks_section}${preflight_section}${failure_history_section}

## PR Diff 摘录
\`\`\`diff
${pr_diff_snippet:-"(空 diff)"}
\`\`\`

## E2E 执行规则（务必遵守）
1. 当前工作目录是 PR 最新提交（\`${head_sha}\`）的独立检出（\`${e2e_wt}\`）。**不要预设 E2E 必须在当前本机启动服务**；先阅读目标仓库的规范与验收入口文档（如 \`AGENTS.md\`、\`qa/README.md\`、\`docs/\`、\`README.md\` 等）以及上方外部环境说明，优先直接调用仓库既有或本 PR 已最小扩展好的维护中 QA action/spec；仅在确实无维护入口时才编写外部临时驱动，一次性核齐前置 fixture（如 \`fixture_mysql\`）与核心必测场景，核心场景全部通过后若确需补测个别边界，**只运行独立轻量增量脚本，禁止把已通过的全量流程从头重跑**；向远端或隔离目录同步/解包候选源码时**保持 Git 原始文件权限（勿使用 \`umask 077\`）**，避免容器内非 root 进程无法读取挂载的初始化脚本。
2. **严禁修改仓库业务代码或提交 commit**，也不要执行 git push 或直接操作 GitHub Issue/PR；你只负责验收与输出客观证据。
3. 将本次验收产生的关键原始证据（日志、命令输出、报告或截图等，**注意脱敏，勿写入明文密码/Token/私钥**）保存到专用目录 \`${artifacts_dir}\`，**不同场景或同轮多次子运行必须分目录保存到 \`${artifacts_dir}/runs/<scenario_id>/attempt-<N>/\`，严禁复跑覆盖 \`attempt-1\` 首跑产物**；外层脚本会自动计算所有归档文件 SHA256 并推送到独立的远程证据分支 \`${E2E_EVIDENCE_BRANCH}\` 并在 PR/Issue 中关联链接；同时在 \`evidence_paths\` 中列出相对于 \`${artifacts_dir}\` 的关键文件路径。验收结束后按仓库规范清理你本次创建的临时资源、测试数据或临时进程，不要在仓库工作区残留脏文件；清理本机或远端临时目录/文件（含 \`trap\` 回调）时**不要使用 \`rm -f\` 或 \`rm -rf\`**（会被 Codex 工具路由器安全策略拦截），请优先调用仓库自带清理入口或改用 Python \`shutil.rmtree\` / \`Path.unlink(missing_ok=True)\` 等安全方式。
4. **严禁使用字节码反编译或调试器/断点注入手段**：禁止运行 \`javap\` 字节码反编译、挂载 JDWP 调试器（\`-agentlib:jdwp\`）或编写断点注入探针（如 \`ReplayProbe\` / \`jdb\`），此类操作会触发安全风控并导致远端环境泄漏。使用标准服务启停、公开接口、数据库状态与真实浏览器 UI 实测评审列出的场景，包括使用已有状态的跨版本续读等。
5. 严格按原因接续，区分五种结论（\`verdict\`）：
   - **能就地补齐的隔离环境依赖先补齐**：若缺失的是当前隔离环境可自行准备的临时依赖/数据，补齐后**只重测缺项**，不重跑已通过的全量流程。
   - \`pass\`：按仓库规范在目标验收环境中完成了针对 Issue 核心场景及所有必验项的真实端到端验证且全部通过，证据充分。
   - \`fail\`：目标验收环境正常，但实测暴露了**代码功能缺陷、回归或未满足 Issue 验收标准**；必须在 \`failure_details\` 中给出可复现步骤、实际结果与期望结果，外层脚本会自动退回 Dev 修复（\`agy:changes-requested\`）。
   - \`return_to_dev\`：仓库系统允许准备账号/权限/数据，且**缺陷或 QA 脚本缺口可在离线 Dev sandbox 通过单测/静态检查确定性复现与验证**（E2E 不修改仓库代码）；**尤其当某条必验场景只能靠临时/手工准备步骤才能跑通（已有可用准备方式，但当前仓库维护 QA 入口跑不起来）时，必须通过 \`return_to_dev\` 交由 Dev 在同一 PR 将该可复用准备步骤固化到项目维护 QA 入口，不要以一次性临场步骤代替维护入口放行**。必须在 \`failure_details\` 中写清：**缺少哪个维护入口/准备步骤、临时准备步骤如何执行、如何验证与清理，以及明确的关闭条件（\`closure_criteria\`）**，外层脚本会自动归档本轮已拿到的有效证据并退回 Dev 在同一个 PR 补齐脚本（\`agy:changes-requested\`），避免误落入 \`blocked\`（仅用于诊断的一次性探针可随报告保留，无需强求固化）。**若根因属于离线 Dev sandbox 无法复现与验证的外部 OS/桌面/RDP 前台锁或宿主机环境约束（如 Windows Terminal 持有前台导致 \`SetForegroundWindow\` 失败），必须将 \`reproducible_in_dev_sandbox\` 设为 \`false\`（宿主机将直接拦截盲目退回 Dev 并切为 \`blocked\`）或直接输出 \`blocked\` / \`return_to_review\`。**
   - \`return_to_review\`：**某条评审必验项依赖候选版本尚未支持的能力**（例如候选后端仅接受单组登录凭据，而必验项要求实测双账号登录切换）；必须在 \`failure_details\` 中写清涉及的必验项编号、候选版本实际能力限制以及已有单测/组件测试的覆盖事实，外层脚本会自动退回 Review 核对 Issue 范围（重新裁定必验项，或明确可用的 QA 身份/数据准备路径后再交 Dev）。
   - \`blocked\`：**仅当确实缺少外部权限、产品/Owner 授权或外部验收环境/OS 桌面约束无法自行恢复时**才使用 \`blocked\`；必须在 \`failure_details\` 或 \`remaining_risks\` 中写清**需要谁做什么**才能解除阻塞，不要把 QA 脚本缺失或必验项前提不成立笼统判为 \`blocked\`，也不要用本机单测冒充真实 E2E 通过。
6. 最终输出必须严格符合提供的 JSON Schema，使用简洁清晰的中文表述。
   - 填写 \`failure_stage\`（\`pass\` 时填 \`""\`；非 \`pass\` 时填写简短稳定的英文 kebab-case 检查点标识，如 \`login-main\`、\`preflight\`、\`focus-handoff\`、\`cleanup-gate\`，若与上轮相同检查点复发则沿用原标识）与 \`reproducible_in_dev_sandbox\`（\`pass\` 时填 \`true\`；非 \`pass\` 时如实判断离线 Dev sandbox 能否确定性复现并验证修复，外部 OS/桌面/RDP/宿主机环境约束必须填 \`false\`）；在 \`failure_details\` 中为每条失败/退回项填写稳定的 kebab-case \`id\` 与可验证的 \`closure_criteria\`（前置状态 → 操作 → 预期结果），供下游 Dev 逐项提交关闭证据。
   - 每个评审必验场景用一个 \`scenarios\` 条目记录，原样填写上方必验清单中的权威 \`id\`（优先以 \`e2e_plan\` 中的 \`id\` 如 \`E0\`、\`REQ-VIEWER-E2E\` 为准，禁止自行改名或顺延重编；无 \`e2e_plan\` 时按 \`E1\`、\`E2\` 填写），用 \`name\` 和 \`details\` 描述实测。逐项填写相对于 \`${artifacts_dir}\` 的 \`scenarios[].evidence_paths\`（若评审 \`e2e_plan\` 要求保留首跑，须包含 \`attempt-1/\` 下的独立首跑证据路径），并把这些路径也列在顶层 \`evidence_paths\` 中。其他额外场景的 \`id\` 留空 \`""\`。**所有必验场景必须真实执行并全部为 \`passed\` 且留存证据后才允许输出 \`pass\`**；若任一必验场景未执行（\`NOT_RUN\`）或仅靠单测替代，禁止标为 \`passed\` 或输出 \`pass\`，应按原因选择 \`return_to_dev\` / \`return_to_review\` / \`blocked\`。
EOF

  codex_ok=0
  codex_rc=0
  if (( preflight_short_circuited == 1 )); then
    codex_ok=1
  else
    codex_args=(
      exec
      -C "$e2e_wt"
      --output-schema "$schema_file"
      -o "$result_file"
      --json
      --color never
    )
    if [[ "$CODEX_E2E_BYPASS_APPROVALS" == "1" ]]; then
      codex_args+=(--dangerously-bypass-approvals-and-sandbox)
    else
      codex_args+=(-s "$CODEX_E2E_SANDBOX")
    fi
    if [[ -n "$CODEX_MODEL" ]]; then
      codex_args+=(-m "$CODEX_MODEL")
    fi
    if [[ -n "$CODEX_REASONING_EFFORT" ]]; then
      codex_args+=(-c "model_reasoning_effort=\"${CODEX_REASONING_EFFORT}\"")
    fi
    codex_args+=(-)

    if [[ "$DRY_RUN" != "1" ]]; then
      write_e2e_lease "$pr_num" "$issue_num" "$head_sha" "$run_ts" "$e2e_wt"
    fi
    if "$TIMEOUT_BIN" --signal=TERM --kill-after=30s "$CODEX_TIMEOUT" "${CODEX_CMD[@]}" "${codex_args[@]}" < "$prompt_file" > "$events_file"; then
      if [[ -s "$result_file" ]] && "$JQ_BIN" -e '
        (.verdict == "pass" or .verdict == "fail" or .verdict == "return_to_dev" or .verdict == "return_to_review" or .verdict == "blocked")
        and (.reproducible_in_dev_sandbox == null or (.reproducible_in_dev_sandbox | type == "boolean"))
        and (.failure_stage == null or (.failure_stage | type == "string"))
        and ((.verdict != "return_to_dev" and .verdict != "return_to_review") or ((.failure_details | type == "array") and (.failure_details | length > 0)))
      ' "$result_file" >/dev/null 2>&1; then
        codex_ok=1
      fi
    else
      codex_rc=$?
    fi

    # 清理 E2E 过程中可能在 worktree 产生的未跟踪文件，保持 worktree 干净
    cleanup_e2e_worktree "$e2e_wt"
  fi

  crash_file="${e2e_dir}/crash_count.txt"
  if (( codex_ok == 0 )); then
    cleanup_ok="true"
    if [[ "$DRY_RUN" != "1" ]]; then
      if ! run_host_e2e_cleanup "$pr_num" "$issue_num" "$head_sha" "$e2e_wt" "$run_ts" "crash"; then
        cleanup_ok="false"
      fi
    fi

    crash_fatal_reason=""
    if [[ -s "$events_file" ]] && "$GREP_BIN" -iqE 'flagged for possible cybersecurity risk|policy violation' "$events_file" 2>/dev/null; then
      crash_fatal_reason="Codex 会话被安全风控中断（cybersecurity risk）"
    fi

    prev_crash_sha=""
    prev_crash_count=0
    if [[ -f "$crash_file" ]]; then
      _raw_crash="$(<"$crash_file")"
      _raw_crash="${_raw_crash//$'\r'/}"
      _raw_crash="${_raw_crash//$'\n'/}"
      if [[ "$_raw_crash" == *:* ]]; then
        prev_crash_sha="${_raw_crash%%:*}"
        _cnt="${_raw_crash#*:}"
        [[ "$_cnt" =~ ^[0-9]+$ ]] && prev_crash_count="$_cnt"
      fi
    fi

    if [[ "$prev_crash_sha" == "$head_sha" ]]; then
      crash_count=$((prev_crash_count + 1))
    else
      crash_count=1
    fi
    if [[ "$DRY_RUN" != "1" ]]; then
      printf '%s:%d\n' "$head_sha" "$crash_count" > "$crash_file"
    fi

    if [[ -n "$crash_fatal_reason" ]] || (( crash_count >= MAX_E2E_CRASH_RETRIES )); then
      crash_reason_desc="${crash_fatal_reason:-Codex 连续异常退出或超时（exit=${codex_rc}，第 ${crash_count}/${MAX_E2E_CRASH_RETRIES} 次）}"
      crash_notice_md="$("$CAT_BIN" <<EOF
### Codex E2E 验收中止（\`${LABEL_PREFIX}blocked\`）

- **关联 Issue**: #${issue_num:-"(未关联)"}
- **验收 Commit**: \`${head_sha:0:10}\`
- **中止原因**: ${crash_reason_desc}
- **宿主机清理状态**: cleanup_ok=\`${cleanup_ok}\`
- **原始日志**: \`${events_file}\`

> ⚠️ E2E 执行过程中发生异常中断（已拦截无休止重试，防止远端容器重复堆叠）。请先确认远端验收环境残余容器已清理，再将 PR/Issue 标签改回 \`${E2E_TARGET_LABEL}\` 重跑。
EOF
)"
      printf '%s\n' "$crash_notice_md" > "$comment_file"
      printf '%s\n' "$crash_notice_md" | gh_state comment pr "$pr_num" - "$E2E_COMMENT_MARKER" || true
      gh_state set-state pr "$pr_num" blocked || true
      if [[ -n "$issue_num" ]]; then
        printf '%s\n' "$crash_notice_md" | gh_state comment issue "$issue_num" - "$E2E_COMMENT_MARKER" || true
        gh_state set-state issue "$issue_num" blocked || true
      fi
      if [[ "$DRY_RUN" != "1" ]]; then
        : > "$crash_file"
      fi
      total_elapsed=$((SECONDS - task_start_sec))
      end_ts="$("$DATE_BIN" '+%F %T')"
      record_e2e_attempt "$e2e_dir" "${run_ts}-${head_sha:0:10}" "$pr_num" "$issue_num" "$head_sha" "$current_round" \
        "crash-blocked" "blocked" "crash_blocked" "crash" "false" "crash" "$cleanup_ok" "$total_elapsed" "$("$DATE_BIN" --iso-8601=seconds)"
      printf '[%s] 错误：Codex E2E 验收 PR #%s %s，已切为 %sblocked（日志：%s）\n' \
        "$end_ts" "$pr_num" "$crash_reason_desc" "$LABEL_PREFIX" "$events_file" >&2
      printf '[%s] [codex-e2e] PR #%s (Issue #%s, r%d) -> crash-blocked (%sblocked, %ds) %s\n' \
        "$end_ts" "$pr_num" "${issue_num:-?}" "$current_round" "$LABEL_PREFIX" "$total_elapsed" "$events_file" >> "$ACTIVITY_LOG"
      "$SLEEP_BIN" 5
      continue
    fi

    if (( codex_rc == 124 )); then
      printf '[%s] 警告：Codex E2E 验收 PR #%s 超时（上限 %s，异常重试 %d/%d，日志：%s），%ss 后重试...\n' \
        "$("$DATE_BIN" '+%F %T')" "$pr_num" "$CODEX_TIMEOUT" "$crash_count" "$MAX_E2E_CRASH_RETRIES" "$events_file" "$POLL_INTERVAL" >&2
    else
      printf '[%s] 警告：Codex E2E 验收 PR #%s 执行异常或输出不符合 Schema（exit=%d，异常重试 %d/%d，日志：%s），%ss 后重试...\n' \
        "$("$DATE_BIN" '+%F %T')" "$pr_num" "$codex_rc" "$crash_count" "$MAX_E2E_CRASH_RETRIES" "$events_file" "$POLL_INTERVAL" >&2
    fi
    "$SLEEP_BIN" "$POLL_INTERVAL"
    continue
  fi

  if (( preflight_short_circuited == 0 )) && [[ "$DRY_RUN" != "1" ]]; then
    if ! run_host_e2e_cleanup "$pr_num" "$issue_num" "$head_sha" "$e2e_wt" "$run_ts" "normal"; then
      cleanup_ok="false"
      "$JQ_BIN" '.remaining_risks = ((.remaining_risks // []) + ["宿主机资源清理命令返回非零，已保留 cleanup_failed 租约并阻断同实例叠加启动。"])' \
        "$result_file" > "${result_file}.tmp" && "$MV_BIN" "${result_file}.tmp" "$result_file"
    fi
  fi

  if [[ "$DRY_RUN" != "1" ]]; then
    : > "$crash_file"
  fi

  verdict="$("$JQ_BIN" -r '.verdict' "$result_file")"
  missing_checks="[]"
  if [[ "$verdict" == "pass" && "$required_checks" != "[]" ]]; then
    artifact_files="$("$FIND_BIN" "$artifacts_dir" -type f -size "-$(( MAX_EVIDENCE_FILE_MB * 1024 * 1024 ))c" -printf '%P\0' \
      | "$JQ_BIN" -Rsc 'split("\u0000") | map(select(length > 0))')"
    missing_checks="$("$JQ_BIN" -c -L "$SCRIPT_DIR" --argjson required "$required_checks" --argjson files "$artifact_files" --arg root "$artifacts_dir" --argjson plan "$required_plan" '
      include "workflow-e2e";
      missing_e2e_checks($required; $files; $root; $plan)
    ' "$result_file")"
    if [[ "$missing_checks" != "[]" ]]; then
      "$CP_BIN" "$result_file" "${e2e_dir}/codex-output-${run_ts}.json"
      "$JQ_BIN" --argjson missing "$missing_checks" '
        .verdict = "blocked"
        | .summary += "\n\n本轮必验场景缺少通过记录或证据（含首跑留存要求），验收结论转为 blocked。"
        | .remaining_risks = ((.remaining_risks // []) + ($missing | map(. + " 缺少唯一的通过记录、实测详情或可归档证据。")))
      ' "$result_file" > "${result_file}.tmp"
      "$MV_BIN" "${result_file}.tmp" "$result_file"
      verdict="blocked"
    fi
  fi
  final_state=""
  extra_notice=""
  handoff_token=""
  host_route_override=""
  raw_failure_stage="$("$JQ_BIN" -r '(.failure_stage // "") | gsub("^\\s+|\\s+$"; "") | ascii_downcase' "$result_file")"
  reproducible_in_dev_sandbox="$("$JQ_BIN" -r 'if .reproducible_in_dev_sandbox == false then "false" else "true" end' "$result_file")"
  prior_same_stage_count=0
  if [[ -n "$raw_failure_stage" && -s "$failure_history_file" ]]; then
    prior_same_stage_count="$("$JQ_BIN" -rs --arg st "$raw_failure_stage" '
      [map(select(type == "object"))[] | select(.verdict == "return_to_dev" and ((.failure_stage // "") | ascii_downcase) == $st)] | length
    ' "$failure_history_file" 2>/dev/null || printf '0')"
  fi

  new_consecutive_failures="$prev_consecutive_failures"
  if [[ "$verdict" == "pass" ]]; then
    new_consecutive_failures=0
    final_state="e2e-passed"
  elif [[ "$verdict" == "blocked" ]]; then
    final_state="blocked"
    extra_notice=$'\n\n'"> ⚠️ E2E 验收受阻（外部权限、产品授权或环境故障），按报告中明确的操作项解除阻塞后，将 PR 标签改回 \`${E2E_TARGET_LABEL}\` 可重跑 E2E。"
  elif [[ "$verdict" == "return_to_review" ]]; then
    if (( current_round >= MAX_TOTAL_E2E_ROUNDS )); then
      final_state="blocked"
      extra_notice=$'\n\n'"> ⚠️ 已达到单 PR 最大总 E2E 轮次上限（累计 ${current_round} / ${MAX_TOTAL_E2E_ROUNDS} 轮），无法继续退回复审，状态已切为 \`${LABEL_PREFIX}blocked\`，请人工介入排查。"
    else
      final_state="in-review"
      handoff_token="$run_ts"
      extra_notice=$'\n\n'"> ↩️ E2E 发现必验项依赖候选版本尚未支持的能力，已自动退回 \`${LABEL_PREFIX}in-review\` 交由独立评审核对 Issue 范围、前置条件与已有回归覆盖（评审调整必验项或给出可用 QA 准备路径后自动接续）。"
    fi
  elif [[ "$verdict" == "return_to_dev" && "$reproducible_in_dev_sandbox" == "false" ]]; then
    host_route_override="non_reproducible_in_dev_sandbox"
    final_state="blocked"
    extra_notice=$'\n\n'"> 🛑 宿主机硬路由拦截：本轮失败标记为 \`reproducible_in_dev_sandbox=false\`（离线 Dev sandbox 无法复现或验证的外部 OS/桌面/环境约束，检查点=\`${raw_failure_stage:-(未标注)}\`），已阻止盲目退回 Dev 猜修并直接切为 \`${LABEL_PREFIX}blocked\`，请人工核查验收环境或调整必验前提。"
  elif [[ "$verdict" == "return_to_dev" && -n "$raw_failure_stage" ]] && (( prior_same_stage_count + 1 >= MAX_REPEAT_E2E_STAGE )); then
    host_route_override="repeat_failure_stage"
    final_state="blocked"
    extra_notice=$'\n\n'"> 🛑 宿主机防盲猜短路：连续 $((prior_same_stage_count + 1)) / ${MAX_REPEAT_E2E_STAGE} 轮 E2E 在同一检查点（\`${raw_failure_stage}\`）失败并尝试 \`return_to_dev\`，已短路切为 \`${LABEL_PREFIX}blocked\` 交人工排查，避免离线 Dev 反复猜修。"
  else
    new_consecutive_failures="$cycle_round"
    if (( cycle_round >= MAX_E2E_ROUNDS )); then
      final_state="blocked"
      extra_notice=$'\n\n'"> ⚠️ 已达到最大连续 E2E 失败/退回轮次（连续 ${cycle_round} / ${MAX_E2E_ROUNDS} 轮，累计第 ${current_round} / ${MAX_TOTAL_E2E_ROUNDS} 轮），状态已切为 \`${LABEL_PREFIX}blocked\`，请人工介入排查。"
    elif (( current_round >= MAX_TOTAL_E2E_ROUNDS )); then
      final_state="blocked"
      extra_notice=$'\n\n'"> ⚠️ 已达到单 PR 最大总 E2E 轮次上限（累计 ${current_round} / ${MAX_TOTAL_E2E_ROUNDS} 轮），状态已切为 \`${LABEL_PREFIX}blocked\`，请人工介入排查。"
    else
      final_state="changes-requested"
      if [[ "$verdict" == "return_to_dev" ]]; then
        extra_notice=$'\n\n'"> ↩️ 检测到仓库 QA 脚本或可复用准备步骤缺口，已自动退回 \`${LABEL_PREFIX}changes-requested\` 交由 Dev 在同一 PR 补齐维护入口（含预检、运行与清理）后重新流转。"
      fi
    fi
  fi

  # 渲染初始评论报告并原子落盘待交接记录，由 publish_e2e_handoff 幂等完成归档、评论、状态与去重键写入
  base_e2e_md="$(render_e2e_markdown "$result_file" "$pr_num" "$issue_num" "$head_sha" "$current_round" "$final_state" "$artifacts_dir" "" "" "" "" "$cycle_round" "$handoff_token")${extra_notice}"
  printf '%s\n' "$base_e2e_md" > "$comment_file"
  archived_list_file="${e2e_dir}/archived-files-${run_ts}.txt"
  : > "$archived_list_file"

  route_category="$(classify_e2e_route_category "$verdict" "$preflight_short_circuited")"
  iso_now="$("$DATE_BIN" --iso-8601=seconds)"
  "$JQ_BIN" -n \
    --arg verification_key "$verification_key" \
    --arg attempt_id "${run_ts}-${head_sha:0:10}" \
    --arg run_ts "$run_ts" \
    --arg result_file "$result_file" \
    --arg comment_file "$comment_file" \
    --arg artifacts_dir "$artifacts_dir" \
    --arg archived_list_file "$archived_list_file" \
    --arg checks_hash "$checks_hash" \
    --arg handoff_token "$handoff_token" \
    --arg extra_notice "$extra_notice" \
    --arg route_category "$route_category" \
    --arg cleanup_ok "$cleanup_ok" \
    --rawfile comment "$comment_file" \
    --argjson elapsed "$((SECONDS - task_start_sec))" \
    --argjson pr_number "$pr_num" \
    --arg issue_number "$issue_num" \
    --arg pr_url "$pr_url" \
    --arg head_branch "$head_branch" \
    --arg base_branch "$base_branch" \
    --arg head_sha "$head_sha" \
    --arg model "$CODEX_MODEL" \
    --arg reasoning_effort "$CODEX_REASONING_EFFORT" \
    --arg evidence_branch "$E2E_EVIDENCE_BRANCH" \
    --argjson round "$current_round" \
    --argjson cycle_round "$cycle_round" \
    --argjson consecutive_failures "$new_consecutive_failures" \
    --argjson max_total_rounds "$MAX_TOTAL_E2E_ROUNDS" \
    --arg verdict "$verdict" \
    --arg failure_stage "$raw_failure_stage" \
    --arg reproducible "$reproducible_in_dev_sandbox" \
    --arg host_route_override "$host_route_override" \
    --arg final_state "$final_state" \
    --arg updated_at "$iso_now" \
    '{
      verification_key: $verification_key,
      attempt_id: $attempt_id,
      run_ts: $run_ts,
      result_file: $result_file,
      comment_file: $comment_file,
      artifacts_dir: $artifacts_dir,
      archived_list_file: $archived_list_file,
      checks_hash: $checks_hash,
      handoff_token: $handoff_token,
      extra_notice: $extra_notice,
      route_category: $route_category,
      cleanup_ok: ($cleanup_ok == "true"),
      comment: $comment,
      elapsed: $elapsed,
      evidence_published: false,
      evidence_rel_dir: "",
      evidence_files_md: "",
      pr_comment_written: false,
      local_recorded: false,
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
        artifacts_dir: $artifacts_dir,
        evidence_branch: $evidence_branch,
        evidence_commit: "",
        evidence_url: "",
        round: $round,
        cycle_round: $cycle_round,
        consecutive_failures: $consecutive_failures,
        max_total_rounds: $max_total_rounds,
        verdict: $verdict,
        failure_stage: $failure_stage,
        reproducible_in_dev_sandbox: ($reproducible == "true"),
        host_route_override: $host_route_override,
        final_state: $final_state,
        updated_at: $updated_at
      }
    }' > "${pending_file}.tmp"
  "$MV_BIN" "${pending_file}.tmp" "$pending_file"
  retry_e2e_handoff "$pending_file"
done
