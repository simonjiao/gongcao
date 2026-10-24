# Repository conventions

- Use Python 3.12+ and `uv`. Manage metadata, dependencies and tool configuration in
  `pyproject.toml`; commit `uv.lock` and keep CI on `uv sync --locked`.
- Run `uv run ruff check .`, `uv run ruff format --check .`, `uv run mypy`, and
  `uv run pytest -q` before proposing a change. pytest enables beartype for `gongcao`.
- Keep stages separate from execution states. Only the controller changes either;
  an agent's report cannot satisfy GitHub review, test, CI, or merge gates.
- Prove sandbox boundaries with real OS access checks. Do not replace these tests
  with prompt assertions or environment-variable-only checks.
- PR1 has read-only GitHub access. Review/validation gates and controlled remote writes
  belong to PR2; leases, concurrency, recovery and automatic diagnosis belong to PR3.
- Issue tracker: GitHub `simonjiao/gongcao`; see `docs/agents/issue-tracker.md`.

## PowerShell 使用规则

- 执行 Windows PowerShell 命令时，优先使用已安装的 PowerShell 7（pwsh.exe），包括通过 WSL 或 SSH 调用 Windows 命令的场景。
- 仅在 PowerShell 7 不可用，或已确认所需模块不兼容时，回退到 Windows PowerShell 5.1（powershell.exe），并说明原因。
