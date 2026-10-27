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

Copilot controls and trusted instructions (#57) merged through PR #66 at
`221ff3f4afeb153e09d3096d08ef63f1f25e1b5e`. Real Copilot acceptance passed at
`6472646` in Run `3f562f499836476783620e0e2b6db079`; resources were safely cleaned.
See `docs/acceptance-copilot.md` for the historical feature-branch evidence.

Current feature work: configured discovery, confirmed claiming and the single GitHub
status publisher, https://github.com/simonjiao/gongcao/issues/56.
Implementation `22da0d4` passes Python 3.12/3.13 CI (266 tests each) and both review axes.
See `docs/issue56-discovery.md`. Real GitHub/Codex acceptance requires explicit
authorization and remains pending; keep the implementation PR draft and #56 open.

Keep the parent issue open until QA is accepted and final-main integration evidence is recorded.
The product
workflow never merges or releases automatically. The user may explicitly authorize a
maintenance merge in this conversation, as for GitHub PR #2 and #4.
