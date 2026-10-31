# Internal regression and real QA audit (#55)

Baseline: `main@fa0ab133d43c20cb0c2e9ac3ca824a3f6ae61a3e`, 30 files / 220 functions / 397 collected instances.
Issue body SHA256: `1ee81ba4c9318cd3db355b3e02604da34be492bd70843c654312dfc4b068f4db`.
All 220 identities match the [per-function appendix](https://github.com/simonjiao/gongcao/issues/55#issuecomment-6541190977).
This implementation rechecked assertions, rejection paths, fixtures, entry points and all parameter instances; the appendix alone is not acceptance evidence.
No same-risk, same-boundary redundant function/parameter was established after #80: remove/merge **0**, retain **220 / 397**. No new internal test function or parameter is needed.
The table summarizes retained functions; real QA names identify related external contracts, not replacement coverage. “Local” includes actual SQLite/Git/Bubblewrap/processes, with external SDK/GitHub protocols substituted.

| Test file (`test_*.py`) | Functions / instances | Internal assertions and distinct execution boundary | Related real QA / decision |
| --- | ---: | --- | --- |
| archive | 1 / 1 | Local append-only Git archive, redaction, readback, unknown push | loop/archive; retain |
| checkpoints | 13 / 29 | Inherited commits, six retry refusals, save/cancel timing, lost writes, source/permission transactions | recover only tests COMMENT; retain |
| cli | 2 / 2 | Local status/cancel and explicit-target sync entry | loop/cancel CLI; retain |
| config | 11 / 31 | YAML types/shapes/bounds, role permissions, model sources, parser and subprocess rejection | batch uses valid config; retain refusals |
| control | 23 / 49 | Receipt identity/order, edits/revocation, eight recovery cases, OS/transaction races, stage permissions | copilot successful controls; retain negative windows |
| control_cli | 1 / 2 | Actual CLI/bare Git/OS chain, changed request and blocked delivery, consumed permissions | copilot/delivery real SDK/GitHub; retain |
| delivery | 5 / 17 | Metadata/request windows, provenance/base/branch refusals, unknown push, explicit complete/incomplete reports | delivery; retain and extend verifier refusals |
| discovery | 9 / 18 | Intake filters/locks, unknown POST, persistent backoff, legacy PATCH read-only, cancel/corrections and queue concurrency | discovery real history; retain |
| discovery_cli | 1 / 2 | Actual once/continuous CLI, clone and restart, queue/slot limits and no duplicate writes | discovery external counterpart; retain |
| events | 5 / 5 | Token/ref distinction, usage counts, rotation bounds, oversized JSON and selected-run ownership | logs used by all scenes; retain |
| github_api | 7 / 12 | URL identity, pagination, cache generations, permission/rate-limit versus transient read retries | real adapters used by scenes; retain deterministic refusals |
| processes | 3 / 6 | Real pipes and orphan descendants, ignored signals, setsid and repeated cancellation | cancel stops owned work; retain independent OS cases |
| progress | 3 / 3 | Terminal redaction, elapsed idle/traffic accounting, state-change deduplication | discovery consumes milestones; retain local terminal boundary |
| qa_evidence | 7 / 7 | QA digest/ownership/version rejection, read-only probe, COMMENT recovery and SDK command evidence | verifies scenes themselves; retain and strengthen history refusal |
| qa_execution | 13 / 20 | QA batch/CLI, failure isolation, fault ownership, queued/preparation cancellation, source snapshot | QA driver regression, distinct from production serve; retain |
| qa_resources | 8 / 19 | QA action unknown response, response hints, ownership/CAS cleanup, unmerged/fixed-base races | all scene cleanup; retain and extend checkpoint safety |
| quality_execution | 8 / 13 | Real sandbox imports/auth/network, command status/cancel, exact plan consent, immutable source | loop successful checks; retain security negatives |
| quality_plan | 11 / 13 | Repo-specific tools, SHA/policy/runtime invalidation, leases, offline E2E rejection, independent acceptance | loop plan acceptance; retain distinct plan boundaries |
| recovery | 11 / 16 | Actual SIGKILL/descendants, fresh sessions, unknown review/PR, stale SHA, baseline/retry/shutdown | recover proves COMMENT only; retain other faults locally |
| remote_writes | 4 / 9 | Isolation gate, six ambiguous transport cases, durable intent/payload and remote changes | recover COMMENT; retain PR/push protocol refusal coverage |
| repository_preparation | 15 / 34 | Path/name/symlink/origin/clone ownership, cleanup races, backoff and dirty reuse | repo_root optional real clone; retain local negative races |
| runner | 12 / 17 | Fresh contexts, process failure/timeout/cancel, initial failures, source/version/cleanup refusal | loop/cancel real sessions; retain deterministic error windows |
| sandbox | 6 / 9 | Actual role mounts, host secrets/symlinks, auth whitelist, missing bwrap/proxy refusal | smoke/loop; retain real OS checks for each role |
| scheduler | 5 / 5 | Production dependencies/leases/retry caps, concurrent worktrees and actual CLI slots | QA batch is a different scheduler; retain |
| schema | 5 / 7 | SQLite v0/v1/v2/v3/v4 upgrades and restart/history, future-version refusal | no external counterpart; retain every version |
| store | 21 / 30 | Transactions, aliases/leases/heartbeat, cancellation races, lifecycle/base/head/result invalidation | no identical external boundary; retain |
| tui | 2 / 5 | Local bounded/redacted rendering, TTY selection and restoration after error | no external counterpart; retain |
| worker | 3 / 7 | SDK arguments/ack/model reroute and pagination refusal | real sessions cover service behavior, not these failures; retain |
| workflow | 4 / 8 | Actual local revision chain, missing formal approval, changed policy/remote target | loop real counterpart; retain local gate counterexamples |
| workspace | 1 / 1 | Exact base-to-head patch and content digest | loop uses context indirectly; retain |

Similar-looking cases remain independent: Store base/head invalidation versus Runner pre-claim/in-flight checks; process pipe cleanup versus lease recovery of unknown descendants; policy invalidation versus same-SHA plan changes; exact registration versus case aliases; cancellation followed by head change versus close/reopen. Normal real QA cannot replace these assertions.

Changed assertions (no removed function/parameter):
- `delivery::test_delivery_write_boundary_and_restart_preserve_completed_developer[acceptance_blocked]` also checks the new QA verifier against actual controller records; synthetic SDK facts are labelled offline. Ready/incomplete reports, non-draft/stale/duplicate PR facts, absent command evidence or missing controller checks are rejected.
- `qa_evidence::test_discovery_qa_evidence_rejects_unknown_writes_and_false_control_claims` now rejects overwritten claims, missing/repeated history, duplicate event/comment identities and foreign authors; both observation windows are corrupted when testing intrinsic uniqueness. Normal later archive comments remain allowed, while a repeated step Agent is rejected.
- `qa_resources::test_branch_cleanup_validates_origin_and_ignores_foreign_pushurl` also checks checkpoint ownership, a moved checkpoint blocking all writes, exact-SHA deletion and repeat cleanup without replay.
- The 33-line checkpoint helper and 239-line CLI helper move to `tests/_support/` with their existing callers/CLI entry updated; no old wrappers remain. These are offline protocols, never real QA.

External additions: discovery reads claim/progress history before and after a fresh serve, binds marker/actor/comment IDs, retains Review/Validation milestones and rechecks live history during `verify --real`. Delivery uses the existing Run/CLI/Agent/GitHub/boundary probe and accepts only `pending_review / waiting_environment` with one original blocked-complete Developer Run, one controller commit/checkpoint and one draft PR; missing package acceptance remains NOT_RUN. Repetition must preserve sessions/operations/PRs. Cleanup includes the Run-owned checkpoint branch, with ownership checks and CAS; no third E2E fault matrix is added.

Evidence: baseline full pytest **397 passed in 456.77s**. Final collection, timings, targeted/static/offline results and fixed implementation SHA are recorded in the PR. Both new real acceptance runs are **NOT_RUN**, pending separate authorization; neither this audit nor offline regressions close #55. Local raw collection/assertion inventory and logs are retained under `.qa-runs/issue55/`; publish only sanitized summaries.

Authorized real QA exposed an ambiguous initial-round instruction: the Developer wrote the deliberately faulty fixture but returned `ready` with `delivery_complete=false`, correctly blocking delivery. Scenario v12 explicitly requests `delivery_complete=true` once the authorized round is written, while independent review and acceptance remain pending. The failed report/output is preserved; fresh Runs recheck the actual model/controller contract without changing production gates.
