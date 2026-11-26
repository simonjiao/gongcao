#!/usr/bin/bash
set -euo pipefail

# Gongcao 全流程复盘与优化评估器（Evaluator）
# 1. 确定性提取 ~/.gongcao/state/<repo_slug> 中所有已处理 Issue/PR 的耗时、打回率、异常信号与证据档案；
# 2. 调用独立只读 Codex（使用隔离目录 ~/.gongcao/codex-review）对照 gongcao 仓库源码，
#    聚类返工根因并给出针对 gongcao 脚本/提示词的优先级优化建议。
#
# 用法:
#   REPO=owner/repo ./evaluate-workflow.sh [--pr N] [--since YYYY-MM-DD] [--metrics-only] [--output path]
#   ./evaluate-workflow.sh --state-dir ~/.gongcao/state/owner__repo [--metrics-only]
#   ./evaluate-workflow.sh login

SCRIPT_DIR="$(cd -- "$([[ "${BASH_SOURCE[0]}" == */* ]] && printf '%s' "${BASH_SOURCE[0]%/*}" || printf '.')" && pwd)"

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

JQ_BIN="$(resolve_bin jq)"
GREP_BIN="$(resolve_bin grep)"
MKDIR_BIN="$(resolve_bin mkdir)"
DATE_BIN="$(resolve_bin date)"
CAT_BIN="$(resolve_bin cat)"
CP_BIN="$(resolve_bin cp)"
TIMEOUT_BIN="$(resolve_bin timeout)"

GONGCAO_HOME="${GONGCAO_HOME:-${HOME}/.gongcao}"
STATE_BASE="${STATE_BASE:-${GONGCAO_HOME}/state}"
REPO="${REPO:-}"
STATE_ROOT="${STATE_ROOT:-}"
EVAL_ROOT="${EVAL_ROOT:-}"
CODEX_MODEL="${CODEX_MODEL:-gpt-6.2-sol}"
CODEX_REASONING_EFFORT="${CODEX_REASONING_EFFORT-high}"
CODEX_TIMEOUT="${CODEX_TIMEOUT:-15m}"
MAX_DOSSIER_BYTES="${MAX_DOSSIER_BYTES:-50000}"

METRICS_ONLY=0
SINCE_DATE=""
OUTPUT_FILE=""
FILTER_PRS=()

if [[ "${1:-}" == "login" ]]; then
  CODEX_BIN="$(resolve_bin codex)"
  # shellcheck source=lib/codex-profile.sh
  source "${SCRIPT_DIR}/lib/codex-profile.sh"
  init_codex_review_profile "evaluate-workflow.sh" login
fi

while (( $# > 0 )); do
  case "$1" in
    --state-dir)
      [[ $# -ge 2 ]] || { printf '错误：--state-dir 缺少参数\n' >&2; exit 2; }
      STATE_ROOT="$2"
      shift 2
      ;;
    --pr)
      [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || { printf '错误：--pr 需要正整数 PR 编号\n' >&2; exit 2; }
      FILTER_PRS+=("$2")
      shift 2
      ;;
    --since)
      [[ $# -ge 2 && "$2" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { printf '错误：--since 需要 YYYY-MM-DD 格式\n' >&2; exit 2; }
      SINCE_DATE="$2"
      shift 2
      ;;
    --metrics-only)
      METRICS_ONLY=1
      shift
      ;;
    --output)
      [[ $# -ge 2 ]] || { printf '错误：--output 缺少文件路径\n' >&2; exit 2; }
      OUTPUT_FILE="$2"
      shift 2
      ;;
    -h|--help)
      "$CAT_BIN" >&2 <<'EOF'
用法:
  REPO=owner/repo ./evaluate-workflow.sh [选项]
  ./evaluate-workflow.sh --state-dir <path> [选项]
  ./evaluate-workflow.sh login

选项:
  --state-dir <path>   显式指定状态目录（默认 ~/.gongcao/state/<repo_slug>）
  --pr <N>             仅评估指定 PR（可重复指定）
  --since <YYYY-MM-DD> 仅统计该日期（含）之后的活动日志
  --metrics-only       仅生成确定性指标与档案报告（离线秒级完成，不调用 Codex）
  --output <path>      额外复制最终 Markdown 报告到指定路径
  -h, --help           显示此帮助信息
EOF
      exit 0
      ;;
    *)
      printf '错误：未知参数 %q（使用 --help 查看用法）\n' "$1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$STATE_ROOT" ]]; then
  if [[ -n "$REPO" ]]; then
    _slug="${REPO//\//__}"
    _slug="${_slug//[^a-zA-Z0-9._-]/_}"
    STATE_ROOT="${STATE_BASE}/${_slug}"
  else
    printf '错误：请通过 REPO=owner/repo 或 --state-dir <path> 指定评估目标。\n' >&2
    exit 2
  fi
fi

if [[ ! -d "$STATE_ROOT" ]]; then
  printf '错误：状态目录不存在：%s\n' "$STATE_ROOT" >&2
  exit 1
fi

REPO_LABEL="${REPO:-${STATE_ROOT##*/}}"
EVAL_ROOT="${EVAL_ROOT:-${STATE_ROOT}/evaluations}"
"$MKDIR_BIN" -p "$EVAL_ROOT"

if (( METRICS_ONLY == 0 )); then
  CODEX_BIN="$(resolve_bin codex)"
  # shellcheck source=lib/codex-profile.sh
  source "${SCRIPT_DIR}/lib/codex-profile.sh"
  init_codex_review_profile "evaluate-workflow.sh" run
fi

run_ts="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
work_dir="${EVAL_ROOT}/run-${run_ts}"
"$MKDIR_BIN" -p "$work_dir"

events_json="${work_dir}/events.json"
sessions_json="${work_dir}/sessions.json"
reviews_json="${work_dir}/reviews.json"
e2es_json="${work_dir}/e2es.json"
finals_json="${work_dir}/finals.json"
metrics_file="${EVAL_ROOT}/metrics-${run_ts}.json"
dossier_file="${EVAL_ROOT}/dossier-${run_ts}.md"
report_file="${EVAL_ROOT}/report-${run_ts}.md"
latest_report="${EVAL_ROOT}/latest.md"

# 1. 解析 activity.log
if [[ -s "${STATE_ROOT}/activity.log" ]]; then
  "$JQ_BIN" -Rs -L "${SCRIPT_DIR}/lib" '
    include "eval-metrics";
    split("\n") | map(rtrimstr("\r") | select(length > 0) | parse_activity_line)
  ' "${STATE_ROOT}/activity.log" > "$events_json"
else
  printf '[]\n' > "$events_json"
fi

# 2. 收集 sessions/issue-*
{
  for d in "${STATE_ROOT}/sessions"/issue-*; do
    [[ -d "$d" ]] || continue
    inum="${d##*/issue-}"
    [[ "$inum" =~ ^[0-9]+$ ]] || continue
    meta="{}"
    if [[ -s "${d}/meta.json" ]] && "$JQ_BIN" -e 'type == "object"' "${d}/meta.json" >/dev/null 2>&1; then
      meta="$("$CAT_BIN" "${d}/meta.json")"
    fi
    blocked_text=""
    [[ -s "${d}/blocked.md" ]] && blocked_text="$("$CAT_BIN" "${d}/blocked.md")"
    q_hits=0
    t_hits=0
    s_errs=0
    for lf in "${d}"/*stderr-*.log "${d}"/agy-cli-*.log; do
      [[ -s "$lf" ]] || continue
      "$GREP_BIN" -qiE 'RESOURCE_EXHAUSTED|429|usage limit|rate limit|Individual quota reached' "$lf" 2>/dev/null && q_hits=$((q_hits + 1)) || true
      "$GREP_BIN" -qiE 'print_timeout|DEADLINE_EXCEEDED|print timeout after' "$lf" 2>/dev/null && t_hits=$((t_hits + 1)) || true
      "$GREP_BIN" -qF 'Codex 返回的开发结果缺失或无效' "$lf" 2>/dev/null && s_errs=$((s_errs + 1)) || true
    done
    "$JQ_BIN" -n \
      --argjson issue_number "$inum" \
      --argjson meta "$meta" \
      --arg blocked "$blocked_text" \
      --argjson quota_hits "$q_hits" \
      --argjson timeout_hits "$t_hits" \
      --argjson schema_errors "$s_errs" '
      (first($meta.pr_url // "" | capture("/pull/(?<n>[0-9]+)").n) // null | if . != null then tonumber else null end) as $pr_num
      | {
          issue_number: $issue_number,
          pr_number: $pr_num,
          title: ($meta.title // ""),
          status: ($meta.status // ""),
          branch: ($meta.branch // ""),
          model: ($meta.model // ""),
          quota_hits: $quota_hits,
          timeout_hits: $timeout_hits,
          schema_errors: $schema_errors,
          blocked_reason: $blocked
        }
    '
  done
} | "$JQ_BIN" -s '.' > "$sessions_json"

# 3. 收集 reviews/pr-*
{
  for d in "${STATE_ROOT}/reviews"/pr-*; do
    [[ -d "$d" ]] || continue
    pnum="${d##*/pr-}"
    [[ "$pnum" =~ ^[0-9]+$ ]] || continue
    meta="{}"
    if [[ -s "${d}/meta.json" ]] && "$JQ_BIN" -e 'type == "object"' "${d}/meta.json" >/dev/null 2>&1; then
      meta="$("$CAT_BIN" "${d}/meta.json")"
    fi
    verdicts_arr="[]"
    verdicts_arr="$({
      for vf in "${d}"/verdict-*.json; do
        [[ -s "$vf" ]] || continue
        "$JQ_BIN" -c --arg file "${vf##*/}" '
          if type == "object" then
            {
              file: $file,
              verdict: (.verdict // ""),
              e2e_decision: (.e2e_decision // ""),
              summary: (.summary // ""),
              blocking_issues: (.blocking_issues // [])
            }
          else empty end
        ' "$vf" 2>/dev/null || true
      done
    } | "$JQ_BIN" -s '.')"
    "$JQ_BIN" -n \
      --argjson pr_number "$pnum" \
      --argjson meta "$meta" \
      --argjson verdicts "$verdicts_arr" '
      ($meta.issue_number // "" | tostring | if test("^[0-9]+$") then tonumber else null end) as $inum
      | {
          pr_number: $pr_number,
          issue_number: $inum,
          verdicts: $verdicts
        }
    '
  done
} | "$JQ_BIN" -s '.' > "$reviews_json"

# 4. 收集 e2e/pr-*
{
  for d in "${STATE_ROOT}/e2e"/pr-*; do
    [[ -d "$d" ]] || continue
    pnum="${d##*/pr-}"
    [[ "$pnum" =~ ^[0-9]+$ ]] || continue
    meta="{}"
    if [[ -s "${d}/meta.json" ]] && "$JQ_BIN" -e 'type == "object"' "${d}/meta.json" >/dev/null 2>&1; then
      meta="$("$CAT_BIN" "${d}/meta.json")"
    fi
    empty_cnt=0
    results_arr="$({
      for rf in "${d}"/result-*.json; do
        [[ -e "$rf" ]] || continue
        if [[ ! -s "$rf" ]] || ! "$JQ_BIN" -e 'type == "object"' "$rf" >/dev/null 2>&1; then
          empty_cnt=$((empty_cnt + 1))
          continue
        fi
        "$JQ_BIN" -c --arg file "${rf##*/}" '
          {
            file: $file,
            verdict: (.verdict // ""),
            summary: (.summary // ""),
            failure_details: (.failure_details // []),
            remaining_risks: (.remaining_risks // [])
          }
        ' "$rf" 2>/dev/null || true
      done
    } | "$JQ_BIN" -s '.')"
    # 注意子 shell 中 empty_cnt 不会回传，单独统计空/无效结果文件
    empty_cnt=0
    for rf in "${d}"/result-*.json; do
      [[ -e "$rf" ]] || continue
      if [[ ! -s "$rf" ]] || ! "$JQ_BIN" -e 'type == "object"' "$rf" >/dev/null 2>&1; then
        empty_cnt=$((empty_cnt + 1))
      fi
    done
    "$JQ_BIN" -n \
      --argjson pr_number "$pnum" \
      --argjson meta "$meta" \
      --argjson empty_results "$empty_cnt" \
      --argjson results "$results_arr" '
      ($meta.issue_number // "" | tostring | if test("^[0-9]+$") then tonumber else null end) as $inum
      | {
          pr_number: $pr_number,
          issue_number: $inum,
          empty_results: $empty_results,
          results: $results
        }
    '
  done
} | "$JQ_BIN" -s '.' > "$e2es_json"

# 5. 收集 final-gate/pr-*
{
  for d in "${STATE_ROOT}/final-gate"/pr-*; do
    [[ -d "$d" ]] || continue
    pnum="${d##*/pr-}"
    [[ "$pnum" =~ ^[0-9]+$ ]] || continue
    meta="{}"
    if [[ -s "${d}/meta.json" ]] && "$JQ_BIN" -e 'type == "object"' "${d}/meta.json" >/dev/null 2>&1; then
      meta="$("$CAT_BIN" "${d}/meta.json")"
    fi
    decisions_arr="$({
      for df in "${d}"/decision-*.json; do
        [[ -s "$df" ]] || continue
        "$JQ_BIN" -c --arg file "${df##*/}" '
          if type == "object" then
            {
              file: $file,
              verdict: (.verdict // ""),
              summary: (.summary // ""),
              blocking_issues: (.blocking_issues // []),
              follow_up_issues: (.follow_up_issues // [])
            }
          else empty end
        ' "$df" 2>/dev/null || true
      done
    } | "$JQ_BIN" -s '.')"
    empty_cnt=0
    for df in "${d}"/decision-*.json; do
      [[ -e "$df" ]] || continue
      if [[ ! -s "$df" ]] || ! "$JQ_BIN" -e 'type == "object"' "$df" >/dev/null 2>&1; then
        empty_cnt=$((empty_cnt + 1))
      fi
    done
    "$JQ_BIN" -n \
      --argjson pr_number "$pnum" \
      --argjson meta "$meta" \
      --argjson empty_decisions "$empty_cnt" \
      --argjson decisions "$decisions_arr" '
      ($meta.issue_number // "" | tostring | if test("^[0-9]+$") then tonumber else null end) as $inum
      | {
          pr_number: $pr_number,
          issue_number: $inum,
          last_verdict: ($meta.verdict // ""),
          last_final_state: ($meta.final_state // ""),
          empty_decisions: $empty_decisions,
          decisions: $decisions
        }
    '
  done
} | "$JQ_BIN" -s '.' > "$finals_json"

# 6. 汇总确定性指标 JSON 与证据档案
filter_prs_json="[]"
if (( ${#FILTER_PRS[@]} > 0 )); then
  filter_prs_json="$(printf '%s\n' "${FILTER_PRS[@]}" | "$JQ_BIN" -s '.')"
fi

"$JQ_BIN" -n -L "${SCRIPT_DIR}/lib" \
  --slurpfile events "$events_json" \
  --slurpfile sessions "$sessions_json" \
  --slurpfile reviews "$reviews_json" \
  --slurpfile e2es "$e2es_json" \
  --slurpfile finals "$finals_json" \
  --argjson filter_prs "$filter_prs_json" \
  --arg since "$SINCE_DATE" '
  include "eval-metrics";
  build_metrics($events[0]; $sessions[0]; $reviews[0]; $e2es[0]; $finals[0]; $filter_prs; $since)
' > "$metrics_file"

metrics_md="$("$JQ_BIN" -r -L "${SCRIPT_DIR}/lib" --arg repo "$REPO_LABEL" '
  include "eval-metrics";
  render_metrics_markdown($repo)
' "$metrics_file")"

"$JQ_BIN" -r -L "${SCRIPT_DIR}/lib" '
  include "eval-metrics";
  render_dossier_markdown
' "$metrics_file" > "$dossier_file"

if (( METRICS_ONLY == 1 )); then
  {
    printf '%s\n' "$metrics_md"
    "$CAT_BIN" "$dossier_file"
  } > "$report_file"
  "$CP_BIN" "$report_file" "$latest_report"
  if [[ -n "$OUTPUT_FILE" ]]; then
    "$MKDIR_BIN" -p "$(dirname -- "$OUTPUT_FILE")"
    "$CP_BIN" "$report_file" "$OUTPUT_FILE"
  fi
  printf '[%s] 指标评估完成（--metrics-only）\n' "$("$DATE_BIN" '+%F %T')"
  printf '  指标 JSON : %s\n' "$metrics_file"
  printf '  评估报告  : %s\n' "$report_file"
  printf '  最新报告  : %s\n' "$latest_report"
  exit 0
fi

# 7. 调用只读 Codex 结合 gongcao 当前源码进行深度根因分析与优化建议
schema_file="${work_dir}/eval-schema.json"
prompt_file="${work_dir}/prompt.md"
events_out="${work_dir}/codex-events.jsonl"
eval_json="${EVAL_ROOT}/eval-${run_ts}.json"

"$CAT_BIN" > "$schema_file" <<'EOF'
{
  "type": "object",
  "additionalProperties": false,
  "required": [
    "executive_summary",
    "workflow_health_score",
    "health_rationale",
    "bottlenecks",
    "root_cause_clusters",
    "engine_comparison_notes",
    "gongcao_optimizations"
  ],
  "properties": {
    "executive_summary": { "type": "string" },
    "workflow_health_score": { "type": "integer", "minimum": 0, "maximum": 100 },
    "health_rationale": { "type": "string" },
    "bottlenecks": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["stage", "severity", "evidence", "impact"],
        "properties": {
          "stage": { "type": "string" },
          "severity": { "type": "string", "enum": ["high", "medium", "low"] },
          "evidence": { "type": "string" },
          "impact": { "type": "string" }
        }
      }
    },
    "root_cause_clusters": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["cluster", "affected_prs", "frequency", "mechanism", "status_in_current_gongcao", "residual_gap"],
        "properties": {
          "cluster": { "type": "string" },
          "affected_prs": { "type": "array", "items": { "type": "string" } },
          "frequency": { "type": "string" },
          "mechanism": { "type": "string" },
          "status_in_current_gongcao": { "type": "string", "enum": ["already_fixed", "partially_mitigated", "open"] },
          "residual_gap": { "type": "string" }
        }
      }
    },
    "engine_comparison_notes": { "type": "string" },
    "gongcao_optimizations": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["priority", "target_files", "title", "problem", "proposal", "expected_impact", "verification"],
        "properties": {
          "priority": { "type": "string", "enum": ["P0", "P1", "P2"] },
          "target_files": { "type": "array", "items": { "type": "string" } },
          "title": { "type": "string" },
          "problem": { "type": "string" },
          "proposal": { "type": "string" },
          "expected_impact": { "type": "string" },
          "verification": { "type": "string" }
        }
      }
    }
  }
}
EOF

dossier_raw="$("$CAT_BIN" "$dossier_file")"
dossier_snippet="${dossier_raw:0:MAX_DOSSIER_BYTES}"
if (( ${#dossier_raw} > MAX_DOSSIER_BYTES )); then
  dossier_snippet+=$'\n\n'"... (档案已截断，完整内容见 ${dossier_file})"
fi

"$CAT_BIN" > "$prompt_file" <<EOF
你是 Gongcao 自动化研发流水线的独立流程评估器（Workflow Evaluator）。
当前只读工作目录是 \`gongcao\` 仓库最新代码（\`${SCRIPT_DIR}\`）。请基于下面真实运行的历史指标与逐 PR 异常档案，结合你对 \`gongcao\` 当前脚本与提示词的直接源码核查，找出系统性瓶颈与反复返工根因，并给出**针对 \`gongcao\` 流水线本身（脚本、状态机、提示词、门禁、运维配置）**的可落地优化建议。

## 评估要求（务必遵守）
1. **必须核查当前 \`gongcao\` 源码**（如 \`lib/issue-loop.sh\`、\`codex-review-loop.sh\`、\`codex-e2e-loop.sh\`、\`codex-final-gate-loop.sh\`、\`cleanup-merged.sh\`、\`start-gongcao.sh\`），严格区分：
   - \`already_fixed\`：历史上出现过、但 \`gongcao\` 当前最新代码已经彻底修掉的问题（不要再重复提“已实现过”的建议）；
   - \`partially_mitigated\`：已做过缓解、但仍存在明显缺口的问题；
   - \`open\`：当前最新代码仍然存在的真实短板。
2. **证据优先**：所有瓶颈、根因聚类和优化建议都必须引用具体的 PR 编号、阶段数据和 \`gongcao\` 文件名/机制，避免空泛套话。
3. **优化建议聚焦可落地性**：按 \`P0\` / \`P1\` / \`P2\` 排序，每条给出精准的目标文件、改动方案、预期收益和验证方式。
4. 只在离线只读沙箱中分析，不要执行 \`gh\` 或网络命令。
5. 输出必须严格符合 JSON Schema，使用简洁清晰的中文。

## 一、确定性统计指标
${metrics_md}

## 二、逐 PR 异常与返工证据档案
${dossier_snippet}
EOF

codex_args=(
  exec
  -s read-only
  -C "$SCRIPT_DIR"
  --output-schema "$schema_file"
  -o "$eval_json"
  --json
  --color never
)
[[ -n "$CODEX_MODEL" ]] && codex_args+=(-m "$CODEX_MODEL")
[[ -n "$CODEX_REASONING_EFFORT" ]] && codex_args+=(-c "model_reasoning_effort=\"${CODEX_REASONING_EFFORT}\"")
codex_args+=(-)

printf '[%s] 开始 Codex 深度流程评估（repo=%s, model=%s, effort=%s, profile=%s）...\n' \
  "$("$DATE_BIN" '+%F %T')" "$REPO_LABEL" "$CODEX_MODEL" "${CODEX_REASONING_EFFORT:-(默认)}" "$CODEX_PROFILE_DIR"

if ! "$TIMEOUT_BIN" --signal=TERM --kill-after=30s "$CODEX_TIMEOUT" "${CODEX_CMD[@]}" "${codex_args[@]}" < "$prompt_file" > "$events_out" \
  || [[ ! -s "$eval_json" ]] \
  || ! "$JQ_BIN" -e 'type == "object" and (.executive_summary | type == "string") and (.gongcao_optimizations | type == "array")' "$eval_json" >/dev/null 2>&1; then
  printf '错误：Codex 评估执行失败或输出不符合 Schema（日志：%s）\n' "$events_out" >&2
  exit 1
fi

# 8. 合并渲染最终 Markdown 评估报告
ai_md="$("$JQ_BIN" -r '
  def esc: tostring | gsub("\r"; "") | gsub("\n"; " ") | gsub("\\|"; "\\|");
  "## 4. 综合诊断结论（健康度 " + (.workflow_health_score | tostring) + " / 100）\n\n"
  + .executive_summary + "\n\n"
  + "> **评分依据**：" + .health_rationale + "\n\n"
  + "### 引擎对比观察\n\n" + .engine_comparison_notes + "\n\n"
  + "## 5. 关键瓶颈定位\n\n"
  + (if (.bottlenecks | length) > 0 then
      "| 阶段 | 严重度 | 事实依据 | 影响 |\n| --- | --- | --- | --- |\n"
      + ([.bottlenecks[] | "| " + (.stage | esc) + " | `" + .severity + "` | " + (.evidence | esc) + " | " + (.impact | esc) + " |"] | join("\n"))
    else "- 无显著瓶颈" end)
  + "\n\n## 6. 返工与异常根因聚类（对照当前 gongcao 源码）\n\n"
  + (if (.root_cause_clusters | length) > 0 then
      "| 根因类别 | 涉及 PR | 频次 | 机制说明 | 当前代码状态 | 残余缺口 |\n| --- | --- | --- | --- | --- | --- |\n"
      + ([.root_cause_clusters[] | "| " + (.cluster | esc) + " | " + ((.affected_prs | join(", ")) | esc) + " | " + (.frequency | esc) + " | " + (.mechanism | esc) + " | `" + .status_in_current_gongcao + "` | " + (.residual_gap | esc) + " |"] | join("\n"))
    else "- 无" end)
  + "\n\n## 7. Gongcao 流水线优化建议（按优先级排序）\n\n"
  + (if (.gongcao_optimizations | length) > 0 then
      [
        .gongcao_optimizations[]
        | "### [" + .priority + "] " + .title + "\n"
          + "- **目标文件**：" + ([.target_files[] | "`" + . + "`"] | join("、")) + "\n"
          + "- **当前问题**：" + .problem + "\n"
          + "- **优化方案**：" + .proposal + "\n"
          + "- **预期收益**：" + .expected_impact + "\n"
          + "- **验证方式**：" + .verification
      ] | join("\n\n")
    else "- 暂无新增优化建议" end)
  + "\n"
' "$eval_json")"

{
  printf '%s\n' "$metrics_md"
  printf '%s\n' "$ai_md"
} > "$report_file"

"$CP_BIN" "$report_file" "$latest_report"
if [[ -n "$OUTPUT_FILE" ]]; then
  "$MKDIR_BIN" -p "$(dirname -- "$OUTPUT_FILE")"
  "$CP_BIN" "$report_file" "$OUTPUT_FILE"
fi

printf '[%s] 全流程评估完成\n' "$("$DATE_BIN" '+%F %T')"
printf '  指标 JSON : %s\n' "$metrics_file"
printf '  评估 JSON : %s\n' "$eval_json"
printf '  评估报告  : %s\n' "$report_file"
printf '  最新报告  : %s\n' "$latest_report"
