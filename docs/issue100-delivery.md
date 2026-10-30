# Issue #100: deliver completed development when the request changes

The controller distinguishes development delivery from acceptance of the current
Issue. A Developer run records its original request, policy, baseline and source
commit in `runs.details.source`; the existing context retains the full input.
Only title/body changes can use this delivery authority. Target/base/PR metadata,
operator feedback and policy remain bound to the recorded baseline.

Request changes invalidate analysis, review, validation and quality evidence.
An already started Developer may finish and deliver its original output through
the existing controller commit, branch and draft PR path. The task then pauses at
Review with an explicit requirements-changed reason, including in automatic mode.
A new instruction is required before reassessing the latest request at PR head.
The Review transition and mandatory pause commit atomically. Recovery adopting
an already created PR retains the pause, including for implicit automatic mode.
Changes before Developer startup still invalidate the original authorization.

Delivery still requires an open task, current lease, verified OS isolation,
confirmed process cleanup and controller commit provenance. Pause/cancellation
and branch conflicts stop publication. Stale WIP stays local when the original
checkpoint authority no longer matches; existing unknown writes remain reserved.
There is no schema migration, new workflow engine or compatibility layer.

Read-only preflight completes before marking a write as dispatched. A newly
created, provably unsent intent is removed on failure. An existing intent is never
removed this way. After dispatch, failed acknowledgement/readback retains an
unknown intent until a read-only observation confirms the result; retries cannot
replay an unconfirmed write. A rate limiter's explicit rejection remains unsent.

Offline regression uses `test_pr2.py` for both metadata refresh windows, three
request-edit windows, delivery safety and write/restart boundaries. Existing
checkpoint/control tests distinguish cancellation/pause before and after send.
`test_control_cli.py` runs native CLI processes and persistent `serve`, real bare
Git and production OS sandboxes; only GitHub/model protocols are substituted.
The QA comment fixture now also changes the Issue timestamp on status updates.

Real GitHub/Copilot acceptance is **NOT_RUN** without explicit `--real`
authorization. Offline protocol tests do not constitute real model/remote QA.
This change does not reconcile or retry the historical airdb#307 unknown intent.
