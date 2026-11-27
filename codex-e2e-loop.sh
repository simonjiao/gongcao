#!/usr/bin/bash
set -euo pipefail

# 独立 Codex E2E 端到端验收循环（默认使用 gpt-6.2-sol + xhigh，不调用 agy，不直接调用 gh）
# 监听带 agy:approved（代码评审已通过）标签的 PR，在独立 worktree 中结合原始 Issue 要求
# 执行真实端到端验收，并通过 gh-state.sh 写回 E2E 验收报告与状态流转：
#   - pass    -> agy:e2e-passed（等待人工最终合并）
#   - fail    -> agy:changes-requested（未超最大轮次时触发 agy 自动修复；超限切 agy:blocked）
#   - blocked -> agy:blocked（环境/外部依赖不可用时直接交人工处理，不盲目打回改代码）

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
MAX_TOTAL_E2E_ROUNDS="${MAX_TOTAL_E2E_ROUNDS:-6}" # 单 PR 生命周期硬性总 E2E 轮次上限，防止死循环
MAX_E2E_CRASH_RETRIES="${MAX_E2E_CRASH_RETRIES:-2}" # 同 PR+SHA 连续异常退出/超时重试上限，超过则切 blocked 防止无限叠实例
E2E_ON_CRASH_CLEANUP_CMD="${E2E_ON_CRASH_CLEANUP_CMD:-}" # 可选：Codex E2E 异常退出时触发的宿主机兜底清理命令
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
REPO_GIT_LOCK="${STATE_ROOT}/repo-git.lock"
if [[ -z "$E2E_ENV_FILE" && -f "${GONGCAO_HOME}/e2e/${REPO_SLUG}.md" ]]; then
  E2E_ENV_FILE="${GONGCAO_HOME}/e2e/${REPO_SLUG}.md"
fi

"$MKDIR_BIN" -p "$STATE_ROOT" "$WORKTREE_ROOT" "$E2E_ROOT"
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
printf '  证据归档   : %s (branch=%s, max=%sMB)\n' "$PUBLISH_EVIDENCE" "$E2E_EVIDENCE_BRANCH" "$MAX_EVIDENCE_FILE_MB"
printf '  监听标签   : %s (MAX_E2E_ROUNDS=%s, MAX_TOTAL_E2E_ROUNDS=%s, MAX_E2E_CRASH_RETRIES=%s, AUTO_REQUEUE_ISSUE=%s, DRY_RUN=%s)\n' \
  "$E2E_TARGET_LABEL" "$MAX_E2E_ROUNDS" "$MAX_TOTAL_E2E_ROUNDS" "$MAX_E2E_CRASH_RETRIES" "$AUTO_REQUEUE_ISSUE" "$DRY_RUN"

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
  "$CAT_BIN" > "$schema_file" <<'EOF'
{
  "type": "object",
  "additionalProperties": false,
  "required": [
    "verdict",
    "summary",
    "environment",
    "scenarios",
    "failure_details",
    "evidence_paths",
    "remaining_risks"
  ],
  "properties": {
    "verdict": {
      "type": "string",
      "enum": ["pass", "fail", "blocked"]
    },
    "summary": {
      "type": "string"
    },
    "environment": {
      "type": "string"
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
        "required": ["title", "reproduction", "observed", "expected"],
        "properties": {
          "title": { "type": "string" },
          "reproduction": { "type": "string" },
          "observed": { "type": "string" },
          "expected": { "type": "string" }
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

review_e2e_checks() {
  local pr_num="$1"
  local head_sha="$2"
  local comment
  comment="$(gh_state get-comment pr "$pr_num" "$REVIEW_COMMENT_MARKER")" || return 1
  "$JQ_BIN" -eRsc -L "$SCRIPT_DIR" --arg sha "$head_sha" '
    include "workflow-e2e";
    review_metadata | approved_e2e_checks($sha; "")
  ' <<<"$comment"
}

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
  local files_json
  files_json="$("$JQ_BIN" -R . "$archived_list_file" | "$JQ_BIN" -s '.')"
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
      files: $files
    }' > "${dest_dir}/manifest.json"
  printf 'manifest.json\n' >> "$archived_list_file"

  "$GIT_BIN" -C "$ev_wt" add -- "$rel_dir" >&2
  "$GIT_BIN" -C "$ev_wt" commit -m "qa(e2e): archive evidence for PR #${pr_num} (${head_sha:0:10}, ${verdict})" >&2

  if ! "$GIT_BIN" -C "$ev_wt" push -u origin "$E2E_EVIDENCE_BRANCH" >&2; then
    "$GIT_BIN" -C "$ev_wt" pull --rebase origin "$E2E_EVIDENCE_BRANCH" >&2
    "$GIT_BIN" -C "$ev_wt" push -u origin "$E2E_EVIDENCE_BRANCH" >&2
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
  local now_ts
  now_ts="$("$DATE_BIN" --iso-8601=seconds)"

  local evidence_cell="\`${artifacts_dir}\` (仅本地)"
  if [[ -n "$evidence_url" ]]; then
    evidence_cell="[查看归档目录](${evidence_url}) (\`${evidence_branch}\` @ \`${evidence_sha:0:10}\`)"
  fi

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
          "- **" + .title + "**\n"
          + "  - 复现步骤：" + .reproduction + "\n"
          + "  - 实际结果：" + .observed + "\n"
          + "  - 期望结果：" + .expected
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
    ' "$result_file"
}

consecutive_poll_errors=0
idle_announced=0
ACTIVITY_LOG="${STATE_ROOT}/activity.log"
declare -A review_cache_keys=() review_cache_times=() review_cache_checks=()

while true; do
  if [[ "$INIT_LABELS" == "1" && "$LABELS_READY" == "0" ]]; then
    if gh_state init-labels; then
      LABELS_READY=1
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

  # 按编号顺序选取尚未实测的提交与必验场景。
  next_pr_json=""
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
    elif required_checks="$(review_e2e_checks "$pnum" "$psha")"; then
      # PR 更新立即失效，定期重读以发现单独编辑过的评审评论。
      review_cache_keys[$pnum]="$cache_key"
      review_cache_times[$pnum]="$SECONDS"
      review_cache_checks[$pnum]="$required_checks"
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
  write_e2e_schema "$schema_file"

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
    required_checks_section=$'\n\n'"## 当前提交的 E2E 必验场景"$'\n'
    required_checks_section+="$("$JQ_BIN" -r -L "$SCRIPT_DIR" '
      include "workflow-e2e"; numbered_e2e_checks[] | "- " + .id + " " + .description
    ' <<<"$required_checks")"
  fi

  printf '[%s] 开始 Codex E2E 验收 PR #%s (Issue #%s, sha=%s, 本周期第 %d/%d 轮, 累计第 %d/%d 轮)...\n' \
    "$("$DATE_BIN" '+%F %T')" "$pr_num" "${issue_num:-?}" "${head_sha:0:10}" "$cycle_round" "$MAX_E2E_ROUNDS" "$current_round" "$MAX_TOTAL_E2E_ROUNDS"

  if ! e2e_wt="$(prepare_e2e_worktree "$pr_num" "$head_branch" "$head_sha")"; then
    printf '[%s] 警告：为 PR #%s 准备 E2E worktree 失败，%ss 后重试...\n' \
      "$("$DATE_BIN" '+%F %T')" "$pr_num" "$POLL_INTERVAL" >&2
    "$SLEEP_BIN" "$POLL_INTERVAL"
    continue
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
${issue_section}${env_file_section}${required_checks_section}

## PR Diff 摘录
\`\`\`diff
${pr_diff_snippet:-"(空 diff)"}
\`\`\`

## E2E 执行规则（务必遵守）
1. 当前工作目录是 PR 最新提交（\`${head_sha}\`）的独立检出（\`${e2e_wt}\`）。**不要预设 E2E 必须在当前本机启动服务**；先阅读目标仓库的规范与验收入口文档（如 \`AGENTS.md\`、\`qa/README.md\`、\`docs/\`、\`README.md\` 等）以及上方外部环境说明，优先直接调用仓库既有或本 PR 已最小扩展好的维护中 QA action/spec；仅在确实无维护入口时才编写外部临时驱动，一次性核齐前置 fixture（如 \`fixture_mysql\`）与核心必测场景，核心场景全部通过后若确需补测个别边界，**只运行独立轻量增量脚本，禁止把已通过的全量流程从头重跑**；向远端或隔离目录同步/解包候选源码时**保持 Git 原始文件权限（勿使用 \`umask 077\`）**，避免容器内非 root 进程无法读取挂载的初始化脚本。
2. **严禁修改仓库业务代码或提交 commit**，也不要执行 git push 或直接操作 GitHub Issue/PR；你只负责验收与输出客观证据。
3. 将本次验收产生的关键原始证据（日志、命令输出、报告或截图等，**注意脱敏，勿写入明文密码/Token/私钥**）保存到专用目录 \`${artifacts_dir}\`，外层脚本会自动将其归档推送到独立的远程证据分支 \`${E2E_EVIDENCE_BRANCH}\` 并在 PR/Issue 中关联链接；同时在 \`evidence_paths\` 中列出相对于 \`${artifacts_dir}\` 的关键文件路径。验收结束后按仓库规范清理你本次创建的临时资源、测试数据或临时进程，不要在仓库工作区残留脏文件；清理本机或远端临时目录/文件（含 \`trap\` 回调）时**不要使用 \`rm -f\` 或 \`rm -rf\`**（会被 Codex 工具路由器安全策略拦截），请优先调用仓库自带清理入口或改用 Python \`shutil.rmtree\` / \`Path.unlink(missing_ok=True)\` 等安全方式。
4. **严禁使用字节码反编译或调试器/断点注入手段**：禁止运行 \`javap\` 字节码反编译、挂载 JDWP 调试器（\`-agentlib:jdwp\`）或编写断点注入探针（如 \`ReplayProbe\` / \`jdb\`），此类操作会触发安全风控并导致远端环境泄漏。使用标准服务启停、公开接口、数据库状态与真实浏览器 UI 实测评审列出的场景，包括使用已有状态的跨版本续读等。
5. 严格区分三种结论（\`verdict\`）：
   - \`pass\`：按仓库规范在目标验收环境中完成了针对 Issue 核心场景的真实端到端验证且全部通过，证据充分。
   - \`fail\`：目标验收环境正常，但实测暴露了**代码功能缺陷、回归或未满足 Issue 验收标准**；必须在 \`failure_details\` 中给出可复现步骤、实际结果与期望结果。
   - \`blocked\`：**无法完成仓库要求的真实 E2E 验收**（例如目标远端环境/容器/数据库/浏览器/凭证不可用或环境故障），不要把环境问题误判为 \`fail\`，也不要用本机单测或替代方案冒充真实 E2E 通过。
6. 最终输出必须严格符合提供的 JSON Schema，使用简洁清晰的中文表述。
   - 每个评审必验场景用一个 \`scenarios\` 条目记录，原样填写 \`id\`（如 \`E1\`），用 \`name\` 和 \`details\` 描述实测。逐项填写相对于 \`${artifacts_dir}\` 的 \`scenarios[].evidence_paths\`，并把这些路径也列在顶层 \`evidence_paths\` 中。其他场景的 \`id\` 留空。所有必验场景通过并留存证据后才输出 \`pass\`。
EOF

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

  codex_ok=0
  codex_rc=0
  if "$TIMEOUT_BIN" --signal=TERM --kill-after=30s "$CODEX_TIMEOUT" "${CODEX_CMD[@]}" "${codex_args[@]}" < "$prompt_file" > "$events_file"; then
    if [[ -s "$result_file" ]] && "$JQ_BIN" -e '.verdict == "pass" or .verdict == "fail" or .verdict == "blocked"' "$result_file" >/dev/null 2>&1; then
      codex_ok=1
    fi
  else
    codex_rc=$?
  fi

  # 清理 E2E 过程中可能在 worktree 产生的未跟踪文件，保持 worktree 干净
  cleanup_e2e_worktree "$e2e_wt"

  crash_file="${e2e_dir}/crash_count.txt"
  if (( codex_ok == 0 )); then
    if [[ -n "$E2E_ON_CRASH_CLEANUP_CMD" ]]; then
      PR_NUM="$pr_num" ISSUE_NUM="$issue_num" HEAD_SHA="$head_sha" E2E_INSTANCE_ID="gongcao-pr-${pr_num}" \
        bash -lc "$E2E_ON_CRASH_CLEANUP_CMD" || true
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

  if [[ "$DRY_RUN" != "1" ]]; then
    : > "$crash_file"
  fi

  verdict="$("$JQ_BIN" -r '.verdict' "$result_file")"
  missing_checks="[]"
  if [[ "$verdict" == "pass" && "$required_checks" != "[]" ]]; then
    artifact_files="$("$FIND_BIN" "$artifacts_dir" -type f -size "-$(( MAX_EVIDENCE_FILE_MB * 1024 * 1024 ))c" -printf '%P\0' \
      | "$JQ_BIN" -Rsc 'split("\u0000") | map(select(length > 0))')"
    missing_checks="$("$JQ_BIN" -c -L "$SCRIPT_DIR" --argjson required "$required_checks" --argjson files "$artifact_files" --arg root "$artifacts_dir" '
      include "workflow-e2e";
      missing_e2e_checks($required; $files; $root)
    ' "$result_file")"
    if [[ "$missing_checks" != "[]" ]]; then
      "$CP_BIN" "$result_file" "${e2e_dir}/codex-output-${run_ts}.json"
      "$JQ_BIN" --argjson missing "$missing_checks" '
        .verdict = "blocked"
        | .summary += "\n\n本轮必验场景缺少通过记录或证据，验收结论转为 blocked。"
        | .remaining_risks = ((.remaining_risks // []) + ($missing | map(. + " 缺少唯一的通过记录、实测详情或可归档证据。")))
      ' "$result_file" > "${result_file}.tmp"
      "$MV_BIN" "${result_file}.tmp" "$result_file"
      verdict="blocked"
    fi
  fi
  final_state=""
  extra_notice=""

  new_consecutive_failures="$prev_consecutive_failures"
  if [[ "$verdict" == "pass" ]]; then
    new_consecutive_failures=0
    final_state="e2e-passed"
  elif [[ "$verdict" == "blocked" ]]; then
    final_state="blocked"
    extra_notice=$'\n\n'"> ⚠️ E2E 验收受阻，排除报告中的阻塞原因后将 PR 标签改回 \`${E2E_TARGET_LABEL}\` 可重跑 E2E。"
  else
    new_consecutive_failures="$cycle_round"
    if (( cycle_round >= MAX_E2E_ROUNDS )); then
      final_state="blocked"
      extra_notice=$'\n\n'"> ⚠️ 已达到最大连续 E2E 失败打回轮次（连续 ${cycle_round} / ${MAX_E2E_ROUNDS} 轮，累计第 ${current_round} / ${MAX_TOTAL_E2E_ROUNDS} 轮），状态已切为 \`${LABEL_PREFIX}blocked\`，请人工介入排查。"
    elif (( current_round >= MAX_TOTAL_E2E_ROUNDS )); then
      final_state="blocked"
      extra_notice=$'\n\n'"> ⚠️ 已达到单 PR 最大总 E2E 轮次上限（累计 ${current_round} / ${MAX_TOTAL_E2E_ROUNDS} 轮），状态已切为 \`${LABEL_PREFIX}blocked\`，请人工介入排查。"
    else
      final_state="changes-requested"
    fi
  fi

  # 先渲染基础验收报告，供归档分支留存
  base_e2e_md="$(render_e2e_markdown "$result_file" "$pr_num" "$issue_num" "$head_sha" "$current_round" "$final_state" "$artifacts_dir" "" "" "" "" "$cycle_round")${extra_notice}"
  printf '%s\n' "$base_e2e_md" > "$comment_file"

  # 将 QA 证据归档推送到独立远程分支（不污染生产分支），生成可点击的 GitHub 直链
  evidence_sha=""
  evidence_rel_dir=""
  evidence_url=""
  evidence_files_md=""
  archived_list_file="${e2e_dir}/archived-files-${run_ts}.txt"
  : > "$archived_list_file"

  if [[ "$PUBLISH_EVIDENCE" == "1" ]]; then
    if pub_out="$(publish_e2e_evidence "$pr_num" "$issue_num" "$head_sha" "$run_ts" "$verdict" "$final_state" "$result_file" "$comment_file" "$artifacts_dir" "$archived_list_file" "$checks_hash")"; then
      evidence_sha="${pub_out%%$'\t'*}"
      evidence_rel_dir="${pub_out#*$'\t'}"
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
    else
      printf '[%s] 警告：归档 QA 证据到远端分支 %s 失败，将继续仅写回本地路径\n' \
        "$("$DATE_BIN" '+%F %T')" "$E2E_EVIDENCE_BRANCH" >&2
    fi
  fi

  # 带上远端证据直链重新渲染最终评论报告
  e2e_md="$(render_e2e_markdown "$result_file" "$pr_num" "$issue_num" "$head_sha" "$current_round" "$final_state" "$artifacts_dir" "$evidence_url" "$E2E_EVIDENCE_BRANCH" "$evidence_sha" "$evidence_files_md" "$cycle_round")${extra_notice}"
  printf '%s\n' "$e2e_md" > "$comment_file"

  # 写回 PR E2E 验收报告与状态
  printf '%s\n' "$e2e_md" | gh_state comment pr "$pr_num" - "$E2E_COMMENT_MARKER" || true
  gh_state set-state pr "$pr_num" "$final_state" || true

  # 同步关联 Issue 状态（先写评论再切标签，避免开发循环在评论写入前就拉取到 changes-requested）
  if [[ -n "$issue_num" ]]; then
    if [[ "$final_state" == "e2e-passed" || "$final_state" == "blocked" ]]; then
      printf '%s\n' "$e2e_md" | gh_state comment issue "$issue_num" - "$E2E_COMMENT_MARKER" || true
      gh_state set-state issue "$issue_num" "$final_state" || true
    elif [[ "$final_state" == "changes-requested" && "$AUTO_REQUEUE_ISSUE" == "1" ]]; then
      printf '%s\n' "$e2e_md" | gh_state comment issue "$issue_num" - "$E2E_COMMENT_MARKER" || true
      gh_state set-state issue "$issue_num" changes-requested || true
    fi
  fi

  # pass 或 fail 时记录已验证提交、场景与连续失败计数。blocked 可在排除阻塞后重跑。
  if [[ "$DRY_RUN" != "1" && "$verdict" != "blocked" ]]; then
    printf '%s\n' "$verification_key" >> "$sha_file"
    printf '%d\n' "$new_consecutive_failures" > "$consec_file"
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
    --arg artifacts_dir "$artifacts_dir" \
    --arg evidence_branch "$E2E_EVIDENCE_BRANCH" \
    --arg evidence_commit "$evidence_sha" \
    --arg evidence_url "$evidence_url" \
    --argjson round "$current_round" \
    --argjson cycle_round "$cycle_round" \
    --argjson consecutive_failures "$new_consecutive_failures" \
    --argjson max_total_rounds "$MAX_TOTAL_E2E_ROUNDS" \
    --arg verdict "$verdict" \
    --arg final_state "$final_state" \
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
      artifacts_dir: $artifacts_dir,
      evidence_branch: $evidence_branch,
      evidence_commit: $evidence_commit,
      evidence_url: $evidence_url,
      round: $round,
      cycle_round: $cycle_round,
      consecutive_failures: $consecutive_failures,
      max_total_rounds: $max_total_rounds,
      verdict: $verdict,
      final_state: $final_state,
      updated_at: $updated_at
    }' > "$meta_file"

  total_elapsed=$((SECONDS - task_start_sec))
  end_ts="$("$DATE_BIN" '+%F %T')"
  printf '\n============================================================\n'
  printf '[%s] [DONE] PR #%s Codex E2E 验收完成 (本周期第 %d/%d 轮, 累计第 %d/%d 轮, 耗时 %ds)\n' \
    "$end_ts" "$pr_num" "$cycle_round" "$MAX_E2E_ROUNDS" "$current_round" "$MAX_TOTAL_E2E_ROUNDS" "$total_elapsed"
  printf '  E2E 结论 : %s -> %s%s\n' "$verdict" "$LABEL_PREFIX" "$final_state"
  printf '  关联Issue: #%s | Commit: %s\n' "${issue_num:-?}" "${head_sha:0:10}"
  printf '  QA 证据  : %s\n' "${evidence_url:-$comment_file}"
  printf '============================================================\n\n'
  printf '[%s] [codex-e2e] PR #%s (Issue #%s, r%d) -> %s (%s%s, %ds) %s\n' \
    "$end_ts" "$pr_num" "${issue_num:-?}" "$current_round" "$verdict" "$LABEL_PREFIX" "$final_state" "$total_elapsed" "${evidence_url:-$comment_file}" >> "$ACTIVITY_LOG"

  "$SLEEP_BIN" 5
done
