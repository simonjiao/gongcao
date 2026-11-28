# Gongcao 流水线全流程评估指标提取与报告渲染模块

def cap_num($re):
  (first(capture($re).n) // null) | if . != null then tonumber else null end;

def cap_str($re):
  first(capture($re).v) // null;

def parse_activity_line:
  capture("^\\[(?<ts>[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})\\] \\[(?<stage>[^\\]]+)\\] (?<rest>.*)$")
  | . as $base
  | ($base.rest | cap_num("PR #(?<n>[0-9]+)")) as $pr_from_text
  | ($base.rest | cap_num("/pull/(?<n>[0-9]+)")) as $pr_from_url
  | ($base.rest | cap_num("Issue #(?<n>[0-9]+)")) as $issue_num
  | ($base.rest | cap_num(", r(?<n>[0-9]+)\\)")) as $round_num
  | ($base.rest | cap_num("\\((?<n>[0-9]+)s\\)")) as $dur1
  | ($base.rest | cap_num(", (?<n>[0-9]+)s\\)")) as $dur2
  | ($base.rest | cap_str("-> (?<v>[^ (]+)")) as $outcome
  | ($base.rest | cap_str("(?<v>agy:[a-z-]+)")) as $target_state
  | {
      ts: $base.ts,
      date: ($base.ts | split(" ")[0]),
      stage: $base.stage,
      pr: ($pr_from_text // $pr_from_url),
      issue: $issue_num,
      round: $round_num,
      outcome: ($outcome // ""),
      target_state: ($target_state // ""),
      duration_sec: ($dur1 // $dur2),
      raw: $base.rest
    };

def safe_avg:
  if length == 0 then 0 else ((add / length) | round) end;

def safe_pct($num; $den):
  if $den == 0 then null else (($num * 1000 / $den) | round / 10) end;

def fmt_dur:
  if . == null or . == 0 then "0s"
  elif . < 60 then "\(.)s"
  elif . < 3600 then "\((. / 60) | floor)m\(. % 60)s"
  else "\((. / 3600) | floor)h\(((. % 3600) / 60) | floor)m"
  end;

def esc_md:
  tostring | gsub("\r"; "") | gsub("\n"; " ") | gsub("\\|"; "\\|");

def build_metrics($events; $sessions; $reviews; $e2es; $finals; $filter_prs; $since):
  # 1. 建立 Issue <-> PR 映射（合并 activity.log 与各类 meta.json）
  (
    reduce (
      ($events[] | select(.pr != null and .issue != null) | {pr, issue})
      , ($sessions[] | select(.pr_number != null and .issue_number != null) | {pr: .pr_number, issue: .issue_number})
      , ($reviews[] | select(.pr_number != null and .issue_number != null) | {pr: .pr_number, issue: .issue_number})
      , ($e2es[] | select(.pr_number != null and .issue_number != null) | {pr: .pr_number, issue: .issue_number})
      , ($finals[] | select(.pr_number != null and .issue_number != null) | {pr: .pr_number, issue: .issue_number})
    ) as $link ({pr_to_issue: {}, issue_to_pr: {}};
      .pr_to_issue[($link.pr | tostring)] = $link.issue
      | .issue_to_pr[($link.issue | tostring)] = $link.pr
    )
  ) as $links
  | ($events
      | map(
          . as $e
          | .pr = ($e.pr // (if $e.issue != null then $links.issue_to_pr[($e.issue | tostring)] else null end))
          | .issue = ($e.issue // (if .pr != null then $links.pr_to_issue[(.pr | tostring)] else null end))
        )
      | if $since != "" then map(select(.date >= $since)) else . end
    ) as $filtered_events
  | (
      [
        ($filtered_events[] | .pr | select(. != null)),
        ($reviews[] | .pr_number | select(. != null)),
        ($e2es[] | .pr_number | select(. != null)),
        ($finals[] | .pr_number | select(. != null)),
        ($sessions[] | .pr_number | select(. != null))
      ]
      | unique
      | if ($filter_prs | length) > 0 then map(select(. as $p | $filter_prs | index($p) != null))
        elif $since != "" then
          ($filtered_events | map(.pr | select(. != null)) | unique) as $active_prs
          | map(select(. as $p | $active_prs | index($p) != null))
        else .
        end
      | sort
    ) as $pr_ids
  | (
      $pr_ids | map(
        . as $pr
        | ($links.pr_to_issue[($pr | tostring)] // null) as $issue
        | ([$filtered_events[] | select(.pr == $pr or (.pr == null and $issue != null and .issue == $issue))]) as $pe
        | ([$sessions[] | select(.pr_number == $pr or ($issue != null and .issue_number == $issue))] | first // null) as $sess
        | ([$reviews[] | select(.pr_number == $pr)] | first // null) as $rev
        | ([$e2es[] | select(.pr_number == $pr)] | first // null) as $e2e
        | ([$finals[] | select(.pr_number == $pr)] | first // null) as $fin
        | ([$pe[] | select(.stage == "agy-dev" or .stage == "codex-dev")]) as $dev_ev
        | ([$pe[] | select(.stage == "codex-review")]) as $rev_ev
        | ([$pe[] | select(.stage == "codex-e2e")]) as $e2e_ev
        | ([$pe[] | select(.stage == "codex-final-gate")]) as $fin_ev
        | ([$pe[] | select(.stage == "cleanup")]) as $cln_ev
        | ([$dev_ev[] | .duration_sec | select(. != null)] | add // 0) as $dev_dur
        | ([$rev_ev[] | .duration_sec | select(. != null)] | add // 0) as $rev_dur
        | ([$e2e_ev[] | .duration_sec | select(. != null)] | add // 0) as $e2e_dur
        | ([$fin_ev[] | .duration_sec | select(. != null)] | add // 0) as $fin_dur
        | (
            if any($fin_ev[]; .outcome == "merge" and (.target_state == "agy:done" or (.raw | contains("MERGED")))) or ($cln_ev | length > 0) or (($fin.last_final_state // "") == "done") then "merged"
            elif ((($pe | last) // {}).target_state // "") == "agy:blocked" or (($sess.status // "") == "blocked") then "blocked"
            else "in-progress"
            end
          ) as $status
        | ($rev.verdicts // []) as $rev_verdicts
        | ($e2e.results // []) as $e2e_results
        | ($e2e.attempts // []) as $e2e_attempts_all
        | (if $since != "" then [$e2e_attempts_all[] | select(((.ts // "")[0:10]) >= $since or ((.ts // "") == ""))] else $e2e_attempts_all end) as $e2e_attempts
        | ($fin.decisions // []) as $fin_decisions
        | ([$rev_ev[] | select(.outcome == "approve" or .outcome == "request_changes")]) as $rev_verdict_ev
        | ([$e2e_ev[] | select(.outcome == "crash-blocked")] | length) as $e2e_crash_ev
        | ([$e2e_attempts[] | select(.route_category == "crash_blocked")] | length) as $e2e_crash_att
        | ([($e2e.empty_results // 0), $e2e_crash_ev, $e2e_crash_att] | max) as $e2e_crash_total
        | (if ($e2e_attempts | length) > 0 then
            ([$e2e_attempts[] | select(.route_category == "product_fail")] | length)
           else
            ([$e2e_ev[] | select(.outcome == "fail")] | length)
           end) as $e2e_product_fails
        | (if ($e2e_attempts | length) > 0 then
            ([$e2e_attempts[] | select(.route_category == "qa_return_to_dev" or .route_category == "preflight_return_to_dev")] | length)
           else
            ([$e2e_ev[] | select(.outcome == "return_to_dev")] | length)
           end) as $e2e_return_to_dev
        | (if ($e2e_attempts | length) > 0 then
            ([$e2e_attempts[] | select(.route_category == "capability_return_to_review" or .route_category == "preflight_return_to_review")] | length)
           else
            ([$e2e_ev[] | select(.outcome == "return_to_review")] | length)
           end) as $e2e_return_to_review
        | ([$e2e_attempts[] | select((.route_category // "") | startswith("preflight_"))] | length) as $e2e_preflight_sc
        | ([$e2e_attempts[] | select(.cleanup_ok == false)] | length) as $e2e_cleanup_fails
        | ([$e2e_ev[] | select(.outcome == "blocked" or .outcome == "crash-blocked")] | length) as $e2e_blocked_total
        | {
            pr_number: $pr,
            issue_number: $issue,
            title: ($sess.title // ""),
            status: $status,
            dev_engines: ([$dev_ev[].stage] | unique),
            first_ts: ((($pe | first) // {}).ts // ""),
            last_ts: ((($pe | last) // {}).ts // ""),
            merged_ts: (([$fin_ev[] | select(.outcome == "merge") | .ts] | last) // ([$cln_ev[].ts] | last) // ""),
            counts: {
              dev_runs: ($dev_ev | length),
              dev_agy_runs: ([$dev_ev[] | select(.stage == "agy-dev")] | length),
              dev_codex_runs: ([$dev_ev[] | select(.stage == "codex-dev")] | length),
              dev_blocked: ([$dev_ev[] | select(.target_state == "agy:blocked")] | length),
              review_runs: ([$rev_ev[] | select(.outcome == "approve" or .outcome == "request_changes")] | length),
              review_verdict_files: ($rev_verdicts | length),
              review_rejections: ([$rev_ev[] | select(.outcome == "request_changes")] | length),
              review_approvals: ([$rev_ev[] | select(.outcome == "approve")] | length),
              review_blocked: ([$rev_ev[] | select(.target_state == "agy:blocked")] | length),
              review_conflict_requeues: ([$rev_ev[] | select(.outcome == "conflict-requeued")] | length),
              e2e_runs: ($e2e_ev | length),
              e2e_passes: ([$e2e_ev[] | select(.outcome == "pass")] | length),
              e2e_fails: ($e2e_product_fails + $e2e_return_to_dev + $e2e_return_to_review),
              e2e_product_fails: $e2e_product_fails,
              e2e_return_to_dev: $e2e_return_to_dev,
              e2e_return_to_review: $e2e_return_to_review,
              e2e_preflight_short_circuits: $e2e_preflight_sc,
              e2e_cleanup_failures: $e2e_cleanup_fails,
              e2e_blocked: $e2e_blocked_total,
              e2e_crashes: $e2e_crash_total,
              e2e_skipped: (if any($rev_ev[]; .target_state == "agy:e2e-skipped") then 1 else 0 end),
              final_runs: ($fin_ev | length),
              final_merges: ([$fin_ev[] | select(.outcome == "merge")] | length),
              final_rejections: ([$fin_ev[] | select(.outcome == "request_changes")] | length),
              final_blocked: ([$fin_ev[] | select(.outcome == "blocked")] | length),
              final_crashes: ($fin.empty_decisions // 0),
              follow_up_issues: ([$fin_decisions[] | (.follow_up_issues // []) | length] | add // 0)
            },
            durations_sec: {
              dev: $dev_dur,
              review: $rev_dur,
              e2e: $e2e_dur,
              final_gate: $fin_dur,
              total_active: ($dev_dur + $rev_dur + $e2e_dur + $fin_dur)
            },
            first_pass: {
              review_r1_approve: (if ($rev_verdict_ev | length) == 0 then null else ($rev_verdict_ev[0].outcome == "approve") end),
              e2e_r1_pass: (if ($e2e_ev | length) == 0 then null else ($e2e_ev[0].outcome == "pass") end),
              final_r1_merge: (if ($fin_ev | length) == 0 then null else ($fin_ev[0].outcome == "merge") end)
            },
            dev_signals: {
              quota_hits: ($sess.quota_hits // 0),
              timeout_hits: ($sess.timeout_hits // 0),
              schema_errors: ($sess.schema_errors // 0),
              blocked_reason: ($sess.blocked_reason // "")
            },
            review_blockers: [
              $rev_verdicts[] | .file as $file | (.blocking_issues // [])[]
              | {file: $file, id: (.id // ""), severity: (.severity // ""), location: (.location // ""), description: ((.description // "")[0:220])}
            ],
            e2e_failures: [
              $e2e_results[] | select(.verdict == "fail" or .verdict == "return_to_dev" or .verdict == "return_to_review" or .verdict == "blocked")
              | {
                  file: .file,
                  verdict: .verdict,
                  summary: ((.summary // "")[0:220]),
                  titles: [(.failure_details // [])[] | .title // empty]
                }
            ],
            final_gate_issues: [
              $fin_decisions[] | select(.verdict != "merge")
              | {
                  file: .file,
                  verdict: .verdict,
                  summary: ((.summary // "")[0:220]),
                  blocking: [(.blocking_issues // [])[] | (if type == "object" then (.description // .title // tostring) else tostring end)[0:180]]
                }
            ]
          }
      )
    ) as $prs
  | (
      if ($filter_prs | length) > 0 then
        [$filtered_events[] | select(.pr != null and (.pr as $p | $filter_prs | index($p) != null))]
      else
        $filtered_events
      end
    ) as $scoped_events
  | ([$scoped_events[] | select(.stage == "agy-dev")]) as $all_agy_dev
  | ([$scoped_events[] | select(.stage == "codex-dev")]) as $all_codex_dev
  | ([$prs[] | select(.first_pass.review_r1_approve != null)]) as $fp_rev
  | ([$prs[] | select(.first_pass.e2e_r1_pass != null)]) as $fp_e2e
  | ([$prs[] | select(.first_pass.final_r1_merge != null)]) as $fp_fin
  | {
      generated_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      scope: {
        since: $since,
        filter_prs: $filter_prs,
        event_count: ($filtered_events | length)
      },
      summary: {
        total_prs: ($prs | length),
        merged_prs: ([$prs[] | select(.status == "merged")] | length),
        blocked_prs: ([$prs[] | select(.status == "blocked")] | length),
        in_progress_prs: ([$prs[] | select(.status == "in-progress")] | length),
        total_active_sec: ([$prs[].durations_sec.total_active] | add // 0),
        stage_totals: {
          dev_runs: ([$prs[].counts.dev_runs] | add // 0),
          dev_blocked: ([$prs[].counts.dev_blocked] | add // 0),
          dev_duration_sec: ([$prs[].durations_sec.dev] | add // 0),
          review_runs: ([$prs[].counts.review_runs] | add // 0),
          review_rejections: ([$prs[].counts.review_rejections] | add // 0),
          review_approvals: ([$prs[].counts.review_approvals] | add // 0),
          review_blocked: ([$prs[].counts.review_blocked] | add // 0),
          review_duration_sec: ([$prs[].durations_sec.review] | add // 0),
          e2e_runs: ([$prs[].counts.e2e_runs] | add // 0),
          e2e_passes: ([$prs[].counts.e2e_passes] | add // 0),
          e2e_fails: ([$prs[].counts.e2e_fails] | add // 0),
          e2e_product_fails: ([$prs[].counts.e2e_product_fails] | add // 0),
          e2e_return_to_dev: ([$prs[].counts.e2e_return_to_dev] | add // 0),
          e2e_return_to_review: ([$prs[].counts.e2e_return_to_review] | add // 0),
          e2e_preflight_short_circuits: ([$prs[].counts.e2e_preflight_short_circuits] | add // 0),
          e2e_cleanup_failures: ([$prs[].counts.e2e_cleanup_failures] | add // 0),
          e2e_blocked: ([$prs[].counts.e2e_blocked] | add // 0),
          e2e_crashes: ([$prs[].counts.e2e_crashes] | add // 0),
          e2e_skipped: ([$prs[].counts.e2e_skipped] | add // 0),
          e2e_duration_sec: ([$prs[].durations_sec.e2e] | add // 0),
          final_runs: ([$prs[].counts.final_runs] | add // 0),
          final_merges: ([$prs[].counts.final_merges] | add // 0),
          final_rejections: ([$prs[].counts.final_rejections] | add // 0),
          final_blocked: ([$prs[].counts.final_blocked] | add // 0),
          final_crashes: ([$prs[].counts.final_crashes] | add // 0),
          final_duration_sec: ([$prs[].durations_sec.final_gate] | add // 0)
        },
        first_pass_rates_pct: {
          review_r1: safe_pct([$fp_rev[] | select(.first_pass.review_r1_approve == true)] | length; $fp_rev | length),
          e2e_r1: safe_pct([$fp_e2e[] | select(.first_pass.e2e_r1_pass == true)] | length; $fp_e2e | length),
          final_r1: safe_pct([$fp_fin[] | select(.first_pass.final_r1_merge == true)] | length; $fp_fin | length)
        },
        engine_comparison: {
          agy_dev: {
            runs: ($all_agy_dev | length),
            blocked: ([$all_agy_dev[] | select(.target_state == "agy:blocked")] | length),
            avg_duration_sec: ([$all_agy_dev[].duration_sec | select(. != null)] | safe_avg),
            total_duration_sec: ([$all_agy_dev[].duration_sec | select(. != null)] | add // 0)
          },
          codex_dev: {
            runs: ($all_codex_dev | length),
            blocked: ([$all_codex_dev[] | select(.target_state == "agy:blocked")] | length),
            avg_duration_sec: ([$all_codex_dev[].duration_sec | select(. != null)] | safe_avg),
            total_duration_sec: ([$all_codex_dev[].duration_sec | select(. != null)] | add // 0)
          }
        },
        anomalies: {
          quota_hits: ([$prs[].dev_signals.quota_hits] | add // 0),
          timeout_hits: ([$prs[].dev_signals.timeout_hits] | add // 0),
          schema_errors: ([$prs[].dev_signals.schema_errors] | add // 0),
          conflict_requeues: ([$prs[].counts.review_conflict_requeues] | add // 0),
          e2e_crashes: ([$prs[].counts.e2e_crashes] | add // 0),
          e2e_cleanup_failures: ([$prs[].counts.e2e_cleanup_failures] | add // 0),
          final_crashes: ([$prs[].counts.final_crashes] | add // 0)
        }
      },
      prs: $prs
    };

def render_metrics_markdown($repo_label):
  .summary as $s
  | $s.stage_totals as $st
  | "# Gongcao 流水线全流程评估指标（" + $repo_label + "）\n\n"
  + "- 生成时间：" + .generated_at + "\n"
  + "- 统计范围：共 `" + ($s.total_prs | tostring) + "` 个 PR（已合入 `" + ($s.merged_prs | tostring)
  + "` / 进行中 `" + ($s.in_progress_prs | tostring) + "` / 阻塞 `" + ($s.blocked_prs | tostring)
  + "`），累计有效执行耗时 `" + ($s.total_active_sec | fmt_dur) + "`\n\n"
  + "## 1. 核心漏斗与阶段耗时\n\n"
  + "| 阶段 | 总次数 | 通过/合入 | 打回/失败 | 阻塞 | 异常/空结果 | 累计耗时 | 首轮通过率 |\n"
  + "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n"
  + "| 开发 (dev) | " + ($st.dev_runs | tostring) + " | - | - | " + ($st.dev_blocked | tostring)
  + " | 配额 " + ($s.anomalies.quota_hits | tostring) + " / 超时 " + ($s.anomalies.timeout_hits | tostring)
  + " | " + ($st.dev_duration_sec | fmt_dur) + " | - |\n"
  + "| 代码评审 (review) | " + ($st.review_runs | tostring) + " | " + ($st.review_approvals | tostring)
  + " | " + ($st.review_rejections | tostring) + " | " + ($st.review_blocked | tostring)
  + " | 冲突退回 " + ($s.anomalies.conflict_requeues | tostring)
  + " | " + ($st.review_duration_sec | fmt_dur) + " | "
  + (if $s.first_pass_rates_pct.review_r1 != null then "\($s.first_pass_rates_pct.review_r1)%" else "-" end) + " |\n"
  + "| E2E 验收 (e2e) | " + ($st.e2e_runs | tostring) + " | " + ($st.e2e_passes | tostring)
  + " | " + ($st.e2e_fails | tostring) + " (产品" + ($st.e2e_product_fails | tostring) + "/QA退Dev" + ($st.e2e_return_to_dev | tostring) + "/退Review" + ($st.e2e_return_to_review | tostring) + ")"
  + " | " + ($st.e2e_blocked | tostring)
  + " | 崩溃 " + ($st.e2e_crashes | tostring) + " / 预检短路 " + ($st.e2e_preflight_short_circuits | tostring) + " / 清理失败 " + ($st.e2e_cleanup_failures | tostring)
  + " | " + ($st.e2e_duration_sec | fmt_dur) + " | "
  + (if $s.first_pass_rates_pct.e2e_r1 != null then "\($s.first_pass_rates_pct.e2e_r1)%" else "-" end) + " |\n"
  + "| 终审合入 (final-gate) | " + ($st.final_runs | tostring) + " | " + ($st.final_merges | tostring)
  + " | " + ($st.final_rejections | tostring) + " | " + ($st.final_blocked | tostring)
  + " | 空结果/终止 " + ($st.final_crashes | tostring)
  + " | " + ($st.final_duration_sec | fmt_dur) + " | "
  + (if $s.first_pass_rates_pct.final_r1 != null then "\($s.first_pass_rates_pct.final_r1)%" else "-" end) + " |\n\n"
  + "## 2. 开发引擎对比（agy-dev vs codex-dev）\n\n"
  + "| 引擎 | 执行次数 | 转 blocked 次数 | 平均单次耗时 | 累计耗时 |\n"
  + "| --- | ---: | ---: | ---: | ---: |\n"
  + "| `agy-dev` | " + ($s.engine_comparison.agy_dev.runs | tostring)
  + " | " + ($s.engine_comparison.agy_dev.blocked | tostring)
  + " | " + ($s.engine_comparison.agy_dev.avg_duration_sec | fmt_dur)
  + " | " + ($s.engine_comparison.agy_dev.total_duration_sec | fmt_dur) + " |\n"
  + "| `codex-dev` | " + ($s.engine_comparison.codex_dev.runs | tostring)
  + " | " + ($s.engine_comparison.codex_dev.blocked | tostring)
  + " | " + ($s.engine_comparison.codex_dev.avg_duration_sec | fmt_dur)
  + " | " + ($s.engine_comparison.codex_dev.total_duration_sec | fmt_dur) + " |\n\n"
  + "## 3. 逐 PR 全流程明细\n\n"
  + "| PR / Issue | 状态 | 引擎 | Dev (阻) | Review (拒/阻) | E2E (败/阻/崩) | Final (拒/阻/崩) | 有效总耗时 |\n"
  + "| --- | --- | --- | --- | --- | --- | --- | ---: |\n"
  + (
      if (.prs | length) == 0 then "| (无记录) | - | - | - | - | - | - | - |\n"
      else
        [
          .prs[]
          | "| PR #" + (.pr_number | tostring) + " / #" + ((.issue_number // "?") | tostring)
            + " | `" + .status + "`"
            + " | " + (if (.dev_engines | length) > 0 then (.dev_engines | join(", ")) else "-" end)
            + " | " + (.counts.dev_runs | tostring) + " (" + (.counts.dev_blocked | tostring) + ")"
            + " | " + (.counts.review_runs | tostring) + " (" + (.counts.review_rejections | tostring) + "/" + (.counts.review_blocked | tostring) + ")"
            + " | " + (if .counts.e2e_skipped > 0 and .counts.e2e_runs == 0 then "skipped" else (.counts.e2e_runs | tostring) + " (" + (.counts.e2e_fails | tostring) + "/" + (.counts.e2e_blocked | tostring) + "/" + (.counts.e2e_crashes | tostring) + ")" end)
            + " | " + (.counts.final_runs | tostring) + " (" + (.counts.final_rejections | tostring) + "/" + (.counts.final_blocked | tostring) + "/" + (.counts.final_crashes | tostring) + ")"
            + " | " + (.durations_sec.total_active | fmt_dur) + " |"
        ] | join("\n")
      end
    ) + "\n";

def render_dossier_markdown:
  "# 各 PR 异常与返工证据摘录\n\n"
  + (
      [
        .prs[]
        | "## PR #" + (.pr_number | tostring) + "（Issue #" + ((.issue_number // "?") | tostring) + "，" + .status + "，" + (.durations_sec.total_active | fmt_dur) + "）"
          + (if .title != "" then "\n- 标题：" + (.title | esc_md) else "" end)
          + "\n- 轮次：dev=" + (.counts.dev_runs | tostring) + "(blocked=" + (.counts.dev_blocked | tostring) + "), review=" + (.counts.review_runs | tostring) + "(reject=" + (.counts.review_rejections | tostring) + "), e2e=" + (.counts.e2e_runs | tostring) + "(fail=" + (.counts.e2e_fails | tostring) + ", crash=" + (.counts.e2e_crashes | tostring) + "), final=" + (.counts.final_runs | tostring) + "(reject=" + (.counts.final_rejections | tostring) + ", crash=" + (.counts.final_crashes | tostring) + ")"
          + "\n- 开发异常信号：quota_hits=" + (.dev_signals.quota_hits | tostring) + ", timeout_hits=" + (.dev_signals.timeout_hits | tostring) + ", schema_errors=" + (.dev_signals.schema_errors | tostring)
          + (if .dev_signals.blocked_reason != "" then "\n- 最近开发阻塞：" + ((.dev_signals.blocked_reason | esc_md)[0:260]) else "" end)
          + (if (.review_blockers | length) > 0 then
              "\n- 评审阻塞摘录（共 " + (.review_blockers | length | tostring) + " 条）：\n"
              + ([.review_blockers[0:12][] | "  - [" + .file + "] " + (if .id != "" then "`" + .id + "` " else "" end) + "`" + (.location | esc_md) + "`：" + (.description | esc_md)] | join("\n"))
            else "" end)
          + (if (.e2e_failures | length) > 0 then
              "\n- E2E 失败/阻塞摘录：\n"
              + ([.e2e_failures[] | "  - [" + .file + " " + .verdict + "] " + (.summary | esc_md) + (if (.titles | length) > 0 then "（缺陷：" + (.titles | map(esc_md) | join("；")) + "）" else "" end)] | join("\n"))
            else "" end)
          + (if (.final_gate_issues | length) > 0 then
              "\n- 终审打回/阻塞摘录：\n"
              + ([.final_gate_issues[] | "  - [" + .file + " " + .verdict + "] " + (.summary | esc_md) + (if (.blocking | length) > 0 then "（阻塞：" + (.blocking | map(esc_md) | join("；")) + "）" else "" end)] | join("\n"))
            else "" end)
      ] | join("\n\n")
    ) + "\n";
