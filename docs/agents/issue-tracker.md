# Issue tracker

## Issue/PR review rules (Agent-ready)

- Read **live GitHub** Issue/PR title, body and state; for a PR also read the current
  head/base SHA, actual diff, checks, and relevant reviews/comments. Never treat
  old summaries or this tracker as current GitHub status.
- The current Issue body defines requirements; the PR body describes delivery.
  Check history for **unresolved defects** and explicit changes of scope. Rewriting
  a body does not by itself fix a defect; explicitly superseded proposals are not
  requirements. If prior text is unavailable or a decision is ambiguous, say so.
- Bind assessments to the Issue body digest and PR head/base SHA. Recheck before
  posting a verdict; after changes, reassess affected code and evidence. CI/real
  QA must be tied to its actual implementation and target SHA.
- Give concise, actionable remaining blockers, separate nonblockers, and an
  explicit review/merge/close decision; never infer completion from a rewritten
  description or a green CI alone. No merge without user authorization.

GitHub Issues in `simonjiao/gongcao` are authoritative. Read issues and comments with
the connected GitHub tools, or `gh issue view NUMBER --repo simonjiao/gongcao`.
The originating spec is https://github.com/simonjiao/gongcao/issues/1.
PR1 (https://github.com/simonjiao/gongcao/pull/2) was merged at
`36aab6cffbc64999bf3af21e853b7165bb4634c0` following the user's explicit merge instruction.
The second stage was merged in https://github.com/simonjiao/gongcao/pull/4 at
`82eafb9a00f8fc06556539b73314791ecb76dfb9`, following explicit user authorization.
The third stage was merged in https://github.com/simonjiao/gongcao/pull/14 at
`35ca3609a5c84bd15ed37729a3ecb6563584c455`, following explicit user authorization.
The native QA sub-issue is https://github.com/simonjiao/gongcao/issues/13.
QA implementation PR: https://github.com/simonjiao/gongcao/pull/17.
Feature-branch acceptance: `docs/acceptance-qa.md` (implementation `3c3357c`).
Stage numbers are independent of GitHub's PR numbers.

Copilot controls and trusted instructions (#57) merged through PR #66 at
`221ff3f4afeb153e09d3096d08ef63f1f25e1b5e`. Real Copilot acceptance passed at
`6472646` in Run `3f562f499836476783620e0e2b6db079`; resources were safely cleaned.
See `docs/acceptance-copilot.md` for the historical feature-branch evidence.

Configured discovery, confirmed claiming and GitHub status publishing (#56) merged
via PR #68 at `e8d1fc007c0f2ef9b371a856f314c9f3514c4b52`. Implementation `af363b8`
passed Python 3.12/3.13 CI (266 tests each) and authorized real GitHub/Codex QA
Run `25d018afb9d04bf9886a1a105a2f8d95`; test resources were safely cleaned.
See `docs/issue56-discovery.md` and `docs/evidence/discovery-af363b8.json`.
Keep #56 open only pending final-main integration evidence; no automated merge or release.

Keep the parent issue open until QA is accepted and final-main integration evidence is recorded.
The product
workflow never merges or releases automatically. The user may explicitly authorize a
maintenance merge in this conversation, as for GitHub PR #2 and #4.
