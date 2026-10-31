# Repository conventions

- Use Python 3.12+ and `uv`. Manage metadata, dependencies and tool configuration in
  `pyproject.toml`; commit `uv.lock` and keep CI on `uv sync --locked`.
- Keep this repository's GitHub Actions workflows manual-only with `workflow_dispatch`,
  including newly added workflows. Add automatic triggers only when the user explicitly requests them.
- Run `uv run ruff check .`, `uv run ruff format --check .`, `uv run mypy`, and
  `uv run pytest -q` before proposing a change. pytest enables beartype for `gongcao` and `qa`.
- Keep stages separate from execution states. Only the controller changes either;
  an agent's report cannot satisfy GitHub review, test, CI, or merge gates.
- Prove sandbox boundaries with real OS access checks. Do not replace these tests
  with prompt assertions or environment-variable-only checks.
- The first two stages (GitHub PR #2 and #4) are merged, including controlled remote
  writes and exact-SHA quality gates. Agents
  never receive GitHub credentials; only the controller publishes commits/PRs/review comments.
  A same-account Agent COMMENT is never a formal GitHub approval. Never auto-merge or publish.
- Derive version-bound validation plans from the target repository and task; do not hard-code
  Gongcao's tools for other projects or require GitHub CI. Schema changes require versioned upgrade/restart tests.
- The third stage uses shared-state leases and OS locks. Never clear unknown writes,
  uncertain descendant cleanup or another owner's resource reservation to force progress.
  Recovery preserves interrupted work and creates fresh sessions; see docs/runtime.md.
- Issue tracker: GitHub `simonjiao/gongcao`; see `docs/agents/issue-tracker.md`.
- Maintain `qa/` scenarios when changing workflow, security or quality gates. Default CI
  uses offline QA only; remote/model acceptance requires an explicit authorized `--real` run.
- Name long-lived modules, tests and current documentation by responsibility, not PR
  numbers or implementation stages. Shared pytest fixtures live in `tests/conftest.py`;
  import pure helpers from `tests/_support/`, never from another test module.
- Keep a sufficient minimal test set: merge or remove tests only when retained assertions
  cover the same risk at the same execution boundary. Preserve independent negative,
  version, cancellation, recovery and real OS/Git checks; test counts are not a goal.
- Current contracts start at `docs/runtime.md` and `docs/validation-evidence.md`.
  `docs/pr1.md`, `docs/pr2.md`, `docs/stage3.md`, `docs/acceptance-*.md` and
  `docs/evidence/` retain historical implementation and fixed-SHA evidence.

## PowerShell 使用规则

- 执行 Windows PowerShell 命令时，优先使用已安装的 PowerShell 7（pwsh.exe），包括通过 WSL 或 SSH 调用 Windows 命令的场景。
- 仅在 PowerShell 7 不可用，或已确认所需模块不兼容时，回退到 Windows PowerShell 5.1（powershell.exe），并说明原因。
