# Real progress and blocked-delivery acceptance (#55)

Authorized on 2026-10-31. Implementation: `78dbfe07fb6959011a857c52150d9e001edeedc1` (scenario v12).
Target repository: `simonjiao/gongcao`; fixed main/base: `fa0ab133d43c20cb0c2e9ac3ca824a3f6ae61a3e`.
The subsequent evidence-only commit changes documentation; `src/`, `qa/`, `tests/` and dependencies retain this tested implementation.

| Scenario | QA Run | Actual target commit | Expected terminal state | Result |
| --- | --- | --- | --- | --- |
| discovery | `9c3f971175de4ac682cc92d88481d498` | `0ad8aa63648bf85b5795d8b1d387c83b023c7028` | mergeable / completed; companion paused | PASS |
| delivery | `d805b26ab5f246d796e27a0ae111df56` | `1871add7f831597f0ae067f10b01c73377d13c02` | pending_review / waiting_environment; draft | PASS |

Both use real `gpt-6.1-sol / xhigh` sessions: SDK thread acknowledgements confirm 9 discovery and 3 delivery sessions; journals contain 32 and 7 actual command-start events. These are real CLI/model/GitHub Runs, with actual OS isolation, not protocol substitutes.
Discovery rejected the initial lower-bound defect, revised once, invalidated old-SHA evidence, passed the current plan and independent Reviewer/Validator, retained immutable claims and unique progress history, and preserved sessions/writes across a fresh serve. Captured comment histories contain 18/4 comments; later normal archive links also pass live verification.
Delivery preserved Developer Run `1716a2f1edee4b1d9cbaa0197520e8f7`, its blocked/true report and original base, and delivered one controller commit/checkpoint and one draft PR. No Reviewer/Validator executed; package acceptance remains **NOT_RUN**. Scenario PASS means this safe blockage and unique delivery were proved, not that missing acceptance passed. Repetition added no sessions, push or PR.
Both independent `verify --real` commands passed before cleanup. `verify-batch` passed before and after cleanup (jobs=1; no parallel/cancellation-isolation claim). Eight-value boundary probes passed; same-SHA live probes use fresh sandboxes.

Cleanup readback confirms 8 owned Issues closed; test PRs [#114](https://github.com/simonjiao/gongcao/pull/114), [#118](https://github.com/simonjiao/gongcao/pull/118) and [#120](https://github.com/simonjiao/gongcao/pull/120) closed **unmerged**; 6 tracked work/checkpoint refs absent (including one never-published ref); 4 discovery labels absent. Main remains at the fixed base. Shared append-only quality evidence is preserved.
Public [current-SHA quality archive](https://github.com/simonjiao/gongcao/tree/38ab63e4c87a9e0e3185a1aaaa287e6c188198ba/qa/acceptance/issue-115/0ad8aa63648bf85b5795d8b1d387c83b023c7028/check-d6ab49a3389a46e386652c8d889e872b) retains controller results without raw business/model output.

Initial e975e74 Runs remain FAIL: `4aacdd898e944bf9b1b218b4e3a6057b` exposed ready/false after the deliberate fault round; `b0a01d8e8133464ba545d78cad6c2dcc` exposed repeated-probe directory reuse. QA instructions and probe allocation were repaired; production gates were unchanged. Original reports/output, failing replay, red/green OS regression and cleanup evidence are retained; the failed Runs were not relabelled PASS.
Local final checks: Ruff, format, mypy and offline Agent/Quality OS probes PASS; **397 pytest instances passed in 410.59s**; all 220 functions and 397 collection identities/order/parameters retained. The seven QA evidence tests passed in 8.26s; Standards/Spec reviews have zero remaining findings.
Raw manifests, SQLite, SDK journals, commands, archive digests, live verification and cleanup records remain in private `.qa-runs/issue55-real/`; each Run uses `runs/QA_RUN_ID/`. Sanitized index: `sanitized-evidence.json`, SHA256 `f7cf2b34212e2383d31cedb103e50f4a56e38eeda425f37a319a206ffeaab3c7`.
No test PR was merged, no release or formal GitHub approval was performed, and Issue #55 was not edited/commented/closed. Feature-branch evidence does not replace future final-main integration acceptance.
