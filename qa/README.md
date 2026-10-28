# Gongcao QA

`qa/` is the versioned acceptance project for Issues #1 and #13. It uses the
production CLI/interfaces, actual Linux sandboxes and independent GitHub facts.
It does not implement another workflow engine. Maintain these scenarios when
production workflow, isolation, recovery or quality gates change.

## Rebuild and check

Use a fresh Linux/WSL checkout, Python 3.12+, Git, GitHub CLI, Bubblewrap and uv:

```bash
git clone git@github.com:simonjiao/gongcao.git gongcao-qa
cd gongcao-qa
sudo apt-get install git gh bubblewrap
uv sync --locked
uv run python -m qa check --offline
uv run pytest -q tests/test_qa.py
uv run python -m qa run smoke --repeat 3 --jobs 2
# Read qa.jobs from the shared YAML (an explicit --jobs still takes precedence):
uv run python -m qa run smoke --config gongcao.example.yaml
```

Run a reviewed, committed checkout: every batch records its fixed implementation
SHA and refuses a dirty implementation checkout. `check` works during development.
Every native CLI launch and the final verdict recheck that implementation and its
imported source location; do not edit or switch the checkout while a batch runs.
Ruff, strict mypy, pytest and beartype include `qa`. Default CI only runs offline
checks and tests, without model authorization or GitHub writes. The SDK/GitHub
protocol substitutes in regression tests are **not** real end-to-end evidence.

Offline checks compare installed dependencies to `uv.lock`, record tool versions
and exercise actual Bubblewrap mounts, credential isolation and read-only access.
No pre-existing temporary directory is required. All temporary probe data is
created and removed by the check.

The real scene's pytest command tests a complete source copy inside the same
quality sandbox, with newly initialized credential-free Git metadata. This lets
clone-dependent project tests run while production isolation continues to mask
the controller's `.git`. The command records `QA_SOURCE_TREE` for comparison with
the target commit tree; no tests are excluded. Ruff/mypy and independent boundary
probes continue to inspect the target worktree.

## Explicit real acceptance

Real scenarios create issues, unmerged PRs, review COMMENTs and dedicated branches
in the selected **Gongcao-compatible** test repository. Its default branch must
contain the project's `pyproject.toml`, `uv.lock`, tests and `ci.yml`. Review the
target before running. The fixture's quality policy is for this project, not a
generic policy for arbitrary repositories.

Prepare GitHub CLI/SSH access and Codex model authorization through their normal
login tools. QA neither copies keys nor writes them to manifests. The production
sandbox owns its existing isolated model-auth lifecycle. `check --real` probes the
account metadata using the installed SDK on the trusted controller. Its environment
allowlist removes GitHub/SSH variables, while HOME/CODEX_HOME retain host filesystem
access for normal authorization. This account read has no Agent tools/turns and is
not a filesystem-isolation proof. Agent isolation is verified separately by the
production Sandbox; actual inference is demonstrated by the real scenario.
Do not place secrets in arguments.

```bash
uv run python -m qa check --real --repo simonjiao/gongcao
uv run python -m qa run cancel loop recover --jobs 2 --real \
  --repo simonjiao/gongcao --config gongcao.example.yaml --model gpt-6.1-sol --cleanup
# Copy the batch_id / Run IDs from the JSON result:
uv run python -m qa verify-batch BATCH_ID --require-isolation
uv run python -m qa verify RUN_ID
```

The default data directory is `.qa-runs/` (ignored by Git). To retain evidence
elsewhere, put `--data-dir /chosen/private/directory` **before** the command.
Directories and JSON files are private. Each Run gets a UUID, independent clone,
SQLite, logs, configuration, dynamic fixture filenames, issue, controller branch,
PR and resource inventory. Same-process batches default to two slots; excess
Runs queue. `--repeat N` repeats each listed scenario with new owned resources;
`--jobs N` changes the bound. The effective limit is the explicit CLI `--jobs`,
then `qa.jobs` in the optional `--config PATH` YAML, then the default 2; it must be
a positive integer. For example, `qa: {jobs: 3}` selects three QA slots.
`scheduler.jobs` configures production `serve` separately (1–3, default 1).
QA reads only the QA parallel setting: model/roles/quality for each scene retain
their existing generated policies; production `quality` is never used as a scene gate.
This does not provide cross-process/global scheduling.

- `smoke`: offline capability checks with an archived verdict; no model or remote writes.
- `loop`: native missing-gate block and unchanged blocked repeat, then real analysis,
  deliberate initial lower-bound defect, draft PR, independent reviewer rejection,
  revision, old-SHA invalidation, all four project checks, real boundary checks,
  exact-SHA CI, validator and human-merge readiness. Repeating the completed native
  task must create no sessions, operations or review comments.
  Technical-only corrections preserve the staged algorithm until the independent
  reviewer rejects it; a format-only revision cannot satisfy the review exercise.
- `recover`: the same loop, with a scoped SIGKILL after a real successful review
  COMMENT is observed but before its local acknowledgement. Native `serve --once`
  reconciles the pending intent and completes using fresh evidence as required.
  This is a controller/remote-write recovery test. It does **not** claim that a
  real SDK developer session was interrupted. Quality-stage interruptions and
  detached-child cleanup also have separately labelled OS/protocol regressions
  in `tests/test_stability.py`.
- `cancel`: waits for a real model command (and an active peer when running in a
  parallel batch), invokes native `cancel`, confirms stopped descendants and no
  remote controller writes, then archives and cleans its own issue. Expected
  cancellation counts as this scenario's success; unexpected stops fail a Run.
- `copilot`: requires `--real --repo`. Posts actual Issue comments from the API account,
  first excluded from operators (rejected), then explicitly allowed. Uses step for
  analysis and development/publication, until-validation for review/revision, then
  auto for the existing exact-SHA gates. Initially edited comments are rejected;
  deleting a pending comment must preserve a verification warning and prevent execution.
  A continuously running native serve must wake an already-paused task from an
  authorized comment; the test does not restart serve to cause that first wakeup.
  Each permission is consumed once across
  fresh native CLI processes; repeated polling preserves sessions and writes.
  Archives command IDs, true actors, waiting checkpoints and the final evidence.
  Uses the existing owned-resource cleanup; it never merges the test PR.
- `discovery`: requires explicit real-QA authorization. Native continuous serve discovers
  an auto issue and a step issue through two run-owned labels, excludes an unlabelled issue,
  confirms unique controller status comments, and consumes a trusted pause on the step issue.
  The auto issue uses the existing six-role loop and exact-SHA CI acceptance. A repeated scan
  must preserve sessions/PRs; cleanup additionally validates and closes the companion issues
  and removes only the run-owned labels. Run with
  `uv run python -m qa run discovery --real --repo OWNER/REPO --cleanup`.

The #57 offline CLI regression is `uv run pytest -q tests/test_control_cli.py`.
It runs the actual CLI in separate processes, real Git worktrees/pushes to a local
bare repository and production OS sandboxes. `qa.copilot_fixture` substitutes only
the GitHub/model protocols. Its persistent serve receives an authorized comment,
wakes the paused task, publishes once, and stops at review with no lease held.
This is offline evidence, not real model/GitHub acceptance.
The optional real run is `uv run python -m qa run copilot --real --repo OWNER/REPO --cleanup`;
execute it only with explicit authorization for real QA.
The deleted pending comment must be superseded by the next verified comment; the
scene does not issue a local pause to bypass an unverified receipt (scenario v8).

`verify-batch --require-isolation` checks slot events, independent resource IDs,
overlapping real SDK session intervals, a queued third Run, and cancellation
cleanup during another successful Run. A failed Run does not cancel its siblings.
The batch returns nonzero if any Run or its requested cleanup failed.

## Independent evidence and interruptions

`verify` checks archive digests and re-evaluates controller, policy/SHA and CI
evidence. Before cleanup, `verify RUN_ID --real` additionally checks current GitHub
facts and reruns credential-free boundary probes. Initial and final fixture code
is inspected in a separate read-only OS sandbox. Missing, stale, unconfirmed or
changed evidence fails; model prose cannot authorize a pass. After cleanup the
verdict is historical, with its observation time, rather than current mergeability.

The manifest includes implementation/base/target SHAs, scene version and digest,
configuration digest, tool/environment versions, remote resources and actions,
state transitions, verdicts and failures. Raw SDK logs and core SQLite/context
records stay in the chosen private data directory. Publish only sanitized
summaries/necessary evidence under `docs/evidence/`; never commit the data directory.

An interruption preserves the manifest, partial work and unknown intents. Run:

```bash
uv run python -m qa cancel RUN_ID
# Wait for the active QA command to stop; another command cannot acquire its lock.
uv run python -m qa reconcile RUN_ID
uv run python -m qa cleanup RUN_ID
```

Cancellation is checked before starting a queued scene, creating its remote issue,
or launching native execution, and is forwarded to native `cancel` during preparation
checks as well as the main loop. A user-cancelled Run ends as `cancelled`; it cannot
count as a passing loop/smoke scenario. With `--cleanup`, existing resources are
cleaned through the same controlled path; otherwise retain them for explicit
`cleanup RUN_ID`. Cancelling an already finished Run returns `cancel_requested=false`.

`reconcile` performs read-only observation/adoption and invokes native `recover`
for the recorded task. It never resends an uncertain write or clears an uncertain
process reservation. If observation cannot establish what happened, it fails for
manual inspection; preserve the inventory and inspect GitHub/`gongcao diagnose`.
Do not edit SQLite. Use a fresh Run after a failed/interrupted scenario; there is
no generic automatic restart of QA steps. Native task recovery is demonstrated by
the `recover` scenario itself.

Cleanup archives evidence before writes, checks marker/author/task/branch/head
ownership, closes only the owned issue and unmerged PR, and deletes only the
owned controller branch with an exact-SHA compare-and-delete. It validates the
source repository and uses the canonical target URL rather than an unchecked
push URL. Reopened/recreated resources invalidate the old cleanup confirmation.
Close confirmations reject merged PRs. Cleanup rechecks the fixed default branch
name/SHA, closed/unmerged PR and resource state before removing local work and
reporting completion. A conflicting observation preserves evidence and ends as
`needs_reconciliation`; it never retries an uncertain write.
It preserves manifests, SQLite, logs and contexts while
removing that Run's clone/worktrees and isolated model-auth copies. It refuses an
active Run, unknown write, foreign commit or uncertain descendant cleanup. It
never merges a test PR, changes the default branch, or removes another Run.

For Issue #1 closure, repeat real integrated acceptance at the fixed final `main`
SHA **after** all functional and QA changes have merged, and record that SHA,
CI/Run/Thread IDs, failure boundaries and cleanup results in the acceptance record.
Feature-branch evidence does not replace this final integration requirement.
