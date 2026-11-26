#!/usr/bin/bash
set -euo pipefail

repo_dir="$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/home/codex-review" "$fixture/state/sessions/issue-10" \
  "$fixture/state/sessions/issue-20" "$fixture/state/reviews/pr-100" "$fixture/state/reviews/pr-200" \
  "$fixture/state/e2e/pr-100" "$fixture/state/final-gate/pr-100" "$fixture/state/final-gate/pr-200"

fail() {
  printf 'FAIL %s\n' "$*" >&2
  exit 1
}

cat > "$fixture/state/activity.log" <<'EOF'
[2026-11-25 10:00:00] [agy-dev] Issue #10 -> agy:in-review (300s) https://github.com/example/app/pull/100
[2026-11-25 10:05:00] [codex-review] PR #100 (Issue #10, r1) -> request_changes (agy:changes-requested, 120s)
[2026-11-25 10:10:00] [agy-dev] Issue #10 -> agy:blocked (40s) https://github.com/example/app/pull/100
[2026-11-25 10:20:00] [agy-dev] Issue #10 -> agy:in-review (200s) https://github.com/example/app/pull/100
[2026-11-25 10:23:00] [codex-review] PR #100 (Issue #10, r2) -> approve (agy:approved, 90s)
[2026-11-25 10:35:00] [codex-e2e] PR #100 (Issue #10, r1) -> fail (agy:changes-requested, 600s) https://example/ev1
[2026-11-25 10:50:00] [codex-e2e] PR #100 (Issue #10, r2) -> pass (agy:e2e-passed, 400s) https://example/ev2
[2026-11-25 10:55:00] [codex-final-gate] PR #100 (Issue #10, r1) -> merge (MERGED (merge) -> agy:done, 180s)
[2026-11-26 11:00:00] [codex-dev] Issue #20 -> agy:in-review (250s) https://github.com/example/app/pull/200
[2026-11-26 11:03:00] [codex-review] PR #200 (Issue #20, r1) -> approve (agy:e2e-skipped, 100s)
[2026-11-26 11:06:00] [codex-final-gate] PR #200 (Issue #20, r1) -> merge (MERGED (merge) -> agy:done, 150s)
EOF

printf '{"issue_number":10,"title":"修复问题10","pr_url":"https://github.com/example/app/pull/100","status":"in-review"}\n' \
  > "$fixture/state/sessions/issue-10/meta.json"
printf 'HTTP 429 RESOURCE_EXHAUSTED\n' > "$fixture/state/sessions/issue-10/stderr-1.log"
printf '{"issue_number":20,"title":"文档更新20","pr_url":"https://github.com/example/app/pull/200","status":"in-review"}\n' \
  > "$fixture/state/sessions/issue-20/meta.json"

printf '{"issue_number":"10"}\n' > "$fixture/state/reviews/pr-100/meta.json"
printf '{"verdict":"request_changes","summary":"缺少边界处理","blocking_issues":[{"id":"edge-case","severity":"major","location":"a.ts:10","description":"空值未处理"}]}\n' \
  > "$fixture/state/reviews/pr-100/verdict-1.json"
printf '{"issue_number":"20"}\n' > "$fixture/state/reviews/pr-200/meta.json"
printf '{"verdict":"approve","e2e_decision":"skip_not_needed","summary":"纯文档通过","blocking_issues":[]}\n' \
  > "$fixture/state/reviews/pr-200/verdict-1.json"

printf '{"issue_number":"10"}\n' > "$fixture/state/e2e/pr-100/meta.json"
: > "$fixture/state/e2e/pr-100/result-0-crash.json"
printf '{"verdict":"fail","summary":"首轮失败","failure_details":[{"title":"页面报错"}]}\n' \
  > "$fixture/state/e2e/pr-100/result-1.json"
printf '{"verdict":"pass","summary":"复验通过","failure_details":[]}\n' \
  > "$fixture/state/e2e/pr-100/result-2.json"

printf '{"issue_number":"10","verdict":"merge","final_state":"done"}\n' > "$fixture/state/final-gate/pr-100/meta.json"
printf '{"verdict":"merge","summary":"合入","blocking_issues":[],"follow_up_issues":[]}\n' \
  > "$fixture/state/final-gate/pr-100/decision-1.json"
printf '{"issue_number":"20","verdict":"merge","final_state":"done"}\n' > "$fixture/state/final-gate/pr-200/meta.json"
printf '{"verdict":"merge","summary":"合入","blocking_issues":[],"follow_up_issues":[]}\n' \
  > "$fixture/state/final-gate/pr-200/decision-1.json"

# 1. --metrics-only 全量统计校验
GONGCAO_HOME="$fixture/home" REPO=example/app \
  bash "$repo_dir/evaluate-workflow.sh" --state-dir "$fixture/state" --metrics-only --output "$fixture/out-metrics.md" \
  > "$fixture/metrics.log" 2>&1 || { cat "$fixture/metrics.log" >&2; fail 'metrics-only 失败'; }

metrics_json="$(ls "$fixture/state/evaluations"/metrics-*.json | tail -n 1)"
jq -e '
  .summary.total_prs == 2
  and .summary.merged_prs == 2
  and .summary.stage_totals.e2e_crashes == 1
  and .summary.first_pass_rates_pct.review_r1 == 50
  and .summary.first_pass_rates_pct.e2e_r1 == 0
  and .summary.first_pass_rates_pct.final_r1 == 100
  and .summary.engine_comparison.agy_dev.runs == 3
  and .summary.engine_comparison.agy_dev.blocked == 1
  and .summary.engine_comparison.codex_dev.runs == 1
  and .summary.anomalies.quota_hits == 1
' "$metrics_json" >/dev/null || { cat "$metrics_json" >&2; fail '指标汇总不符合预期'; }
grep -Fq 'PR #100 / #10' "$fixture/out-metrics.md" || fail 'Markdown 报告缺少 PR #100'
grep -Fq 'PR #200 / #20' "$fixture/out-metrics.md" || fail 'Markdown 报告缺少 PR #200'

# 2. --since 与 --pr 过滤同时约束引擎统计口径（不混入其他 PR 事件）
GONGCAO_HOME="$fixture/home" REPO=example/app EVAL_ROOT="$fixture/eval-since" \
  bash "$repo_dir/evaluate-workflow.sh" --state-dir "$fixture/state" --since 2026-11-26 --metrics-only \
  >/dev/null 2>&1
since_json="$(ls "$fixture/eval-since"/metrics-*.json | tail -n 1)"
jq -e '.summary.total_prs == 1 and .prs[0].pr_number == 200' "$since_json" >/dev/null \
  || { cat "$since_json" >&2; fail '--since 过滤失败'; }

GONGCAO_HOME="$fixture/home" REPO=example/app EVAL_ROOT="$fixture/eval-pr" \
  bash "$repo_dir/evaluate-workflow.sh" --state-dir "$fixture/state" --pr 200 --metrics-only \
  >/dev/null 2>&1
pr_json="$(ls "$fixture/eval-pr"/metrics-*.json | tail -n 1)"
jq -e '.summary.total_prs == 1 and .summary.engine_comparison.agy_dev.runs == 0 and .summary.engine_comparison.codex_dev.runs == 1' "$pr_json" >/dev/null \
  || { cat "$pr_json" >&2; fail '--pr 过滤后引擎统计混入了其他 PR'; }

# 3. 完整 Codex 评估模式（校验使用隔离 CODEX_HOME 且正确渲染优化建议）
cat > "$fixture/bin/codex" <<'EOF'
#!/usr/bin/bash
set -euo pipefail
expected_home="$(cd -- "$GONGCAO_HOME/codex-review" && pwd -P)"
if [[ "${CODEX_HOME:-}" != "$expected_home" ]]; then
  printf 'Unexpected CODEX_HOME=%q\n' "${CODEX_HOME:-}" >&2
  exit 97
fi
out_file=""
while (( $# > 0 )); do
  if [[ "$1" == "-o" ]]; then
    out_file="$2"
    shift 2
  else
    shift
  fi
done
cat >/dev/null
cat > "$out_file" <<'JSON'
{
  "executive_summary": "整体流水线可闭环，E2E 耗时与空结果异常是主要瓶颈。",
  "workflow_health_score": 78,
  "health_rationale": "首轮通过率偏低但均成功合入。",
  "bottlenecks": [
    {"stage": "e2e", "severity": "high", "evidence": "PR #100 E2E 耗时 1000s 且出现 1 次空结果", "impact": "拉长交付周期"}
  ],
  "root_cause_clusters": [
    {"cluster": "E2E 进程异常退出", "affected_prs": ["PR #100"], "frequency": "1 次", "mechanism": "环境或进程崩溃产生空 result.json", "status_in_current_gongcao": "partially_mitigated", "residual_gap": "缺少异常摘要归档"}
  ],
  "engine_comparison_notes": "codex-dev 单次耗时低于 agy-dev 且无阻塞。",
  "gongcao_optimizations": [
    {
      "priority": "P1",
      "target_files": ["codex-e2e-loop.sh"],
      "title": "记录 E2E 崩溃尾日志到评论",
      "problem": "空 result.json 缺少直接定位信息",
      "proposal": "异常退出时自动摘取 events 末尾 20 行",
      "expected_impact": "缩短人工排查时间",
      "verification": "单测模拟崩溃退出并校验日志摘录"
    }
  ]
}
JSON
EOF
chmod +x "$fixture/bin/codex"

PATH="$fixture/bin:$PATH" GONGCAO_HOME="$fixture/home" REPO=example/app EVAL_ROOT="$fixture/eval-full" \
  bash "$repo_dir/evaluate-workflow.sh" --state-dir "$fixture/state" --output "$fixture/out-full.md" \
  > "$fixture/full.log" 2>&1 || { cat "$fixture/full.log" >&2; fail '完整评估模式失败'; }
grep -Fq '健康度 78 / 100' "$fixture/out-full.md" || fail '完整报告缺少健康度'
grep -Fq '### [P1] 记录 E2E 崩溃尾日志到评论' "$fixture/out-full.md" || fail '完整报告缺少优化建议'

# 4. 未初始化 codex-review 目录时完整模式应报错而非回退 ~/.codex
if PATH="$fixture/bin:$PATH" GONGCAO_HOME="$fixture/home" CODEX_REVIEW_HOME="$fixture/missing-dir" REPO=example/app \
  bash "$repo_dir/evaluate-workflow.sh" --state-dir "$fixture/state" > "$fixture/missing.log" 2>&1; then
  fail '未初始化评审目录时不应启动完整模式'
fi
grep -Fq 'evaluate-workflow.sh login' "$fixture/missing.log" || fail '缺少 login 初始化提示'

printf 'evaluate workflow tests passed\n'
