# Issue tracker

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

Current feature work: Copilot advancement permissions and trusted instructions,
https://github.com/simonjiao/gongcao/issues/57. Local acceptance and authorized real-QA
attempts are recorded in `docs/acceptance-copilot.md`; concentrated simplification, Python 3.12/3.13 checks and fixed-SHA CI are complete.
Real Copilot acceptance passed at `6472646` in Run `3f562f499836476783620e0e2b6db079`;
all test resources were safely cleaned. Formal review and final-main integration remain.
Issue #56 owns discovery/claiming and the single GitHub status publisher separately.

Keep the parent issue open until QA is accepted and final-main integration evidence is recorded.
The product
workflow never merges or releases automatically. The user may explicitly authorize a
maintenance merge in this conversation, as for GitHub PR #2 and #4.
