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
FIND_BIN="$(resolve_bin find)"
FLOCK_BIN="$(resolve_bin flock)"
TIMEOUT_BIN="$(resolve_bin timeout)"

# ===== 主工作目录与可调配置 =====
GONGCAO_HOME="${GONGCAO_HOME:-${HOME}/.gongcao}"
REPOS_ROOT="${REPOS_ROOT:-${GONGCAO_HOME}/repos}"
STATE_BASE="${STATE_BASE:-${GONGCAO_HOME}/state}"

REPO="${REPO:-}"                             # 目标 GitHub 仓库 "owner/repo"
REPO_NAME="${REPO_NAME:-}"                   # 可选：~/.gongcao/repos/<REPO_NAME>
REPO_DIR="${REPO_DIR:-}"                     # 可选：显式本地仓库路径
AUTO_CLONE="${AUTO_CLONE:-1}"                # 未克隆时自动只读克隆到 ~/.gongcao/repos/
LABEL_PREFIX="${LABEL_PREFIX:-agy:}"
E2E_TARGET_LABEL="${E2E_TARGET_LABEL:-${LABEL_PREFIX}approved}" # 默认接收代码评审通过（agy:approved）的 PR
E2E_COMMENT_MARKER="${E2E_COMMENT_MARKER:-<!-- codex-e2e-comment -->}"
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
MAX_E2E_ROUNDS="${MAX_E2E_ROUNDS:-2}"        # 最大自动 E2E 失败打回轮数，超过则切 blocked
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
printf '  工作主目录 : %s\n' "$GONGCAO_HOME"
printf '  主仓库目录 : %s\n' "$REPO_ROOT"
printf '  E2E 档案根 : %s\n' "$E2E_ROOT"
printf '  E2E 环境档 : %s\n' "${E2E_ENV_FILE:-(按仓库自身文档)}"
printf '  证据归档   : %s (branch=%s, max=%sMB)\n' "$PUBLISH_EVIDENCE" "$E2E_EVIDENCE_BRANCH" "$MAX_EVIDENCE_FILE_MB"
printf '  监听标签   : %s (MAX_E2E_ROUNDS=%s, AUTO_REQUEUE_ISSUE=%s, DRY_RUN=%s)\n' \
  "$E2E_TARGET_LABEL" "$MAX_E2E_ROUNDS" "$AUTO_REQUEUE_ISSUE" "$DRY_RUN"

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
        "required": ["name", "status", "details"],
        "properties": {
          "name": { "type": "string" },
          "status": { "type": "string", "enum": ["passed", "failed", "blocked", "skipped"] },
          "details": { "type": "string" }
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
  local num=""

  num="$(printf '%s\n' "$pr_body" | "$GREP_BIN" -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#[0-9]+' | "$HEAD_BIN" -n 1 | "$GREP_BIN" -oE '[0-9]+' || true)"
  if [[ -z "$num" ]]; then
    num="$(printf '%s\n' "$head_branch" | "$GREP_BIN" -oE 'issue-[0-9]+' | "$HEAD_BIN" -n 1 | "$GREP_BIN" -oE '[0-9]+' || true)"
  fi
  printf '%s' "$num"
}

prepare_e2e_worktree() {
  local pr_num="$1"
  local head_branch="$2"
  local head_sha="$3"
  local wt_dir="${WORKTREE_ROOT}/e2e-pr-${pr_num}"

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
    --arg max_rounds "$MAX_E2E_ROUNDS" \
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
    + "| E2E 轮次 | " + $round + " / " + $max_rounds + " |\n"
    + "| 验收模型 | `" + $model + "` |\n"
    + "| 验收环境 | " + (.environment | esc) + " |\n"
    + "| QA 证据 | " + $evidence_cell + " |\n"
    + "| 验收时间 | " + $now + " |\n\n"
    + "#### 总结\n" + .summary + "\n\n"
    + "#### 端到端场景结果\n"
    + (if (.scenarios | length) > 0 then
        "| 场景 | 结果 | 详情 |\n| --- | --- | --- |\n"
        + ([.scenarios[] | "| " + (.name | esc) + " | `" + .status + "` | " + (.details | esc) + " |"] | join("\n"))
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

  # 找出第一条最新 head_sha 尚未做过 E2E 的 PR
  next_pr_json=""
  while IFS= read -r row; do
    pnum="$("$JQ_BIN" -r '.number' <<<"$row")"
    psha="$("$JQ_BIN" -r '.headRefOid // empty' <<<"$row")"
    sha_file="${E2E_ROOT}/pr-${pnum}/verified_shas.txt"
    if [[ -n "$psha" && -f "$sha_file" ]] && "$GREP_BIN" -qx "$psha" "$sha_file"; then
      continue
    fi
    next_pr_json="$row"
    break
  done < <("$JQ_BIN" -c '.[]' <<<"$prs_json")

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

  printf '[%s] 开始 Codex E2E 验收 PR #%s (Issue #%s, sha=%s, 第 %d/%d 轮)...\n' \
    "$("$DATE_BIN" '+%F %T')" "$pr_num" "${issue_num:-?}" "${head_sha:0:10}" "$current_round" "$MAX_E2E_ROUNDS"

  if ! e2e_wt="$(prepare_e2e_worktree "$pr_num" "$head_branch" "$head_sha")"; then
    printf '[%s] 警告：为 PR #%s 准备 E2E worktree 失败，%ss 后重试...\n' \
      "$("$DATE_BIN" '+%F %T')" "$pr_num" "$POLL_INTERVAL" >&2
    "$SLEEP_BIN" "$POLL_INTERVAL"
    continue
  fi

  pr_diff_raw="$(gh_state get-pr-diff "$pr_num" 2>/dev/null || true)"
  pr_diff_snippet="$(printf '%s' "$pr_diff_raw" | "$HEAD_BIN" -c "$MAX_DIFF_BYTES")"
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
- E2E 轮次: 第 ${current_round} 轮

### PR 描述
${pr_body:-"(empty)"}

## 关联 Issue 要求
${issue_section}${env_file_section}

## PR Diff 摘录
\`\`\`diff
${pr_diff_snippet:-"(空 diff)"}
\`\`\`

## E2E 执行规则（务必遵守）
1. 当前工作目录是 PR 最新提交（\`${head_sha}\`）的独立检出（\`${e2e_wt}\`）。**不要预设 E2E 必须在当前本机启动服务**；先阅读目标仓库的规范与验收入口文档（如 \`AGENTS.md\`、\`qa/README.md\`、\`docs/\`、\`README.md\` 等）以及上方外部环境说明，严格按仓库既有流程与指定目标环境（无论是远端测试主机、容器/DinD、CI 还是跨端浏览器）复用既有工具执行端到端验收。
2. **严禁修改仓库业务代码或提交 commit**，也不要执行 git push 或直接操作 GitHub Issue/PR；你只负责验收与输出客观证据。
3. 将本次验收产生的关键原始证据（日志、命令输出、报告或截图等，**注意脱敏，勿写入明文密码/Token/私钥**）保存到专用目录 \`${artifacts_dir}\`，外层脚本会自动将其归档推送到独立的远程证据分支 \`${E2E_EVIDENCE_BRANCH}\` 并在 PR/Issue 中关联链接；同时在 \`evidence_paths\` 中列出关键文件路径。验收结束后按仓库规范清理你本次创建的临时资源、测试数据或临时进程，不要在仓库工作区残留脏文件。
4. 严格区分三种结论（\`verdict\`）：
   - \`pass\`：按仓库规范在目标验收环境中完成了针对 Issue 核心场景的真实端到端验证且全部通过，证据充分。
   - \`fail\`：目标验收环境正常，但实测暴露了**代码功能缺陷、回归或未满足 Issue 验收标准**；必须在 \`failure_details\` 中给出可复现步骤、实际结果与期望结果。
   - \`blocked\`：**无法完成仓库要求的真实 E2E 验收**（例如目标远端环境/容器/数据库/浏览器/凭证不可用或环境故障），不要把环境问题误判为 \`fail\`，也不要用本机单测或替代方案冒充真实 E2E 通过。
5. 最终输出必须严格符合提供的 JSON Schema，使用简洁清晰的中文表述。
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
  if "$TIMEOUT_BIN" --signal=TERM --kill-after=30s "$CODEX_TIMEOUT" "$CODEX_BIN" "${codex_args[@]}" < "$prompt_file" > "$events_file"; then
    if [[ -s "$result_file" ]] && "$JQ_BIN" -e '.verdict == "pass" or .verdict == "fail" or .verdict == "blocked"' "$result_file" >/dev/null 2>&1; then
      codex_ok=1
    fi
  else
    codex_rc=$?
  fi

  # 清理 E2E 过程中可能在 worktree 产生的未跟踪文件，保持 worktree 干净
  cleanup_e2e_worktree "$e2e_wt"

  if (( codex_ok == 0 )); then
    if (( codex_rc == 124 )); then
      printf '[%s] 警告：Codex E2E 验收 PR #%s 超时（上限 %s，日志：%s），%ss 后重试...\n' \
        "$("$DATE_BIN" '+%F %T')" "$pr_num" "$CODEX_TIMEOUT" "$events_file" "$POLL_INTERVAL" >&2
    else
      printf '[%s] 警告：Codex E2E 验收 PR #%s 执行异常或输出不符合 Schema（exit=%d，日志：%s），%ss 后重试...\n' \
        "$("$DATE_BIN" '+%F %T')" "$pr_num" "$codex_rc" "$events_file" "$POLL_INTERVAL" >&2
    fi
    "$SLEEP_BIN" "$POLL_INTERVAL"
    continue
  fi

  verdict="$("$JQ_BIN" -r '.verdict' "$result_file")"
  final_state=""
  extra_notice=""

  if [[ "$verdict" == "pass" ]]; then
    final_state="e2e-passed"
  elif [[ "$verdict" == "blocked" ]]; then
    final_state="blocked"
    extra_notice=$'\n\n'"> ⚠️ E2E 验收因环境或外部依赖条件受阻，状态已切为 \`${LABEL_PREFIX}blocked\`；环境就绪后将 PR 标签改回 \`${E2E_TARGET_LABEL}\` 即可重跑 E2E。"
  else
    if (( current_round >= MAX_E2E_ROUNDS )); then
      final_state="blocked"
      extra_notice=$'\n\n'"> ⚠️ 已达到最大自动 E2E 失败打回轮次（${MAX_E2E_ROUNDS} 轮），状态已切为 \`${LABEL_PREFIX}blocked\`，请人工介入排查。"
    else
      final_state="changes-requested"
    fi
  fi

  # 先渲染基础验收报告，供归档分支留存
  base_e2e_md="$(render_e2e_markdown "$result_file" "$pr_num" "$issue_num" "$head_sha" "$current_round" "$final_state" "$artifacts_dir")${extra_notice}"
  printf '%s\n' "$base_e2e_md" > "$comment_file"

  # 将 QA 证据归档推送到独立远程分支（不污染生产分支），生成可点击的 GitHub 直链
  evidence_sha=""
  evidence_rel_dir=""
  evidence_url=""
  evidence_files_md=""
  archived_list_file="${e2e_dir}/archived-files-${run_ts}.txt"
  : > "$archived_list_file"

  if [[ "$PUBLISH_EVIDENCE" == "1" ]]; then
    if pub_out="$(publish_e2e_evidence "$pr_num" "$issue_num" "$head_sha" "$run_ts" "$verdict" "$final_state" "$result_file" "$comment_file" "$artifacts_dir" "$archived_list_file")"; then
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
  e2e_md="$(render_e2e_markdown "$result_file" "$pr_num" "$issue_num" "$head_sha" "$current_round" "$final_state" "$artifacts_dir" "$evidence_url" "$E2E_EVIDENCE_BRANCH" "$evidence_sha" "$evidence_files_md")${extra_notice}"
  printf '%s\n' "$e2e_md" > "$comment_file"

  # 写回 PR E2E 验收报告与状态
  printf '%s\n' "$e2e_md" | gh_state comment pr "$pr_num" - "$E2E_COMMENT_MARKER" || true
  gh_state set-state pr "$pr_num" "$final_state" || true

  # 同步关联 Issue 状态
  if [[ -n "$issue_num" ]]; then
    if [[ "$final_state" == "e2e-passed" || "$final_state" == "blocked" ]]; then
      gh_state set-state issue "$issue_num" "$final_state" || true
      printf '%s\n' "$e2e_md" | gh_state comment issue "$issue_num" - "$E2E_COMMENT_MARKER" || true
    elif [[ "$final_state" == "changes-requested" && "$AUTO_REQUEUE_ISSUE" == "1" ]]; then
      gh_state set-state issue "$issue_num" changes-requested || true
      printf '%s\n' "$e2e_md" | gh_state comment issue "$issue_num" - "$E2E_COMMENT_MARKER" || true
    fi
  fi

  # 仅在 pass 或 fail（且非 DRY_RUN）时记录已验证 SHA；blocked 环境阻塞时不锁定该 SHA，方便人工修好环境后直接重跑
  if [[ "$DRY_RUN" != "1" && "$verdict" != "blocked" ]]; then
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
    --arg artifacts_dir "$artifacts_dir" \
    --arg evidence_branch "$E2E_EVIDENCE_BRANCH" \
    --arg evidence_commit "$evidence_sha" \
    --arg evidence_url "$evidence_url" \
    --argjson round "$current_round" \
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
      verdict: $verdict,
      final_state: $final_state,
      updated_at: $updated_at
    }' > "$meta_file"

  total_elapsed=$((SECONDS - task_start_sec))
  end_ts="$("$DATE_BIN" '+%F %T')"
  printf '\n============================================================\n'
  printf '[%s] [DONE] PR #%s Codex E2E 验收完成 (第 %d/%d 轮, 耗时 %ds)\n' \
    "$end_ts" "$pr_num" "$current_round" "$MAX_E2E_ROUNDS" "$total_elapsed"
  printf '  E2E 结论 : %s -> %s%s\n' "$verdict" "$LABEL_PREFIX" "$final_state"
  printf '  关联Issue: #%s | Commit: %s\n' "${issue_num:-?}" "${head_sha:0:10}"
  printf '  QA 证据  : %s\n' "${evidence_url:-$comment_file}"
  printf '============================================================\n\n'
  printf '[%s] [codex-e2e] PR #%s (Issue #%s, r%d) -> %s (%s%s, %ds) %s\n' \
    "$end_ts" "$pr_num" "${issue_num:-?}" "$current_round" "$verdict" "$LABEL_PREFIX" "$final_state" "$total_elapsed" "${evidence_url:-$comment_file}" >> "$ACTIVITY_LOG"

  "$SLEEP_BIN" 5
done
