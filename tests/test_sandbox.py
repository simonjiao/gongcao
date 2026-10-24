import json
import os
import shutil
import sys

import pytest

from gongcao.config import Config
from gongcao.github import command
from gongcao.model import Role
from gongcao.sandbox import IsolationError, Sandbox
from gongcao.workspace import worktree

pytestmark = pytest.mark.skipif(
    sys.platform != "linux" or not shutil.which("bwrap"),
    reason="Requires Linux Bubblewrap; no fallback is exercised",
)


@pytest.mark.parametrize("role", list(Role))
async def test_actual_namespace_permissions(tmp_path, repo, sha, auth_file, role, monkeypatch):
    workspace = tmp_path / "worktree"
    await worktree(repo, workspace, sha, role, f"sandbox-{role}")
    run_dir = tmp_path / "run"
    run_dir.mkdir()
    sandbox = Sandbox(workspace, run_dir, role)
    sandbox.prepare(Config(auth_file=auth_file))
    monkeypatch.setenv("GH_TOKEN", "github_pat_host_secret_not_for_agents")
    evidence = await sandbox.verify(repo)
    assert evidence["workspace_writable"] == role.writable
    assert evidence["host_credentials"] == "blocked"
    assert evidence["uv"].startswith("uv ")
    # Verify a real, preexisting host secret, not only absent default paths.
    secret = tmp_path / "host-secret"
    secret.write_text("host-authorization-store")
    script = "from pathlib import Path; import sys; assert not Path(sys.argv[1]).exists()"
    await command(*sandbox.argv(sys.executable, "-c", script, str(secret)))
    assert (repo / "sample.txt").read_text() == "original\n"
    assert auth_file.read_text() == '{"OPENAI_API_KEY":"sk-test-credential-not-real-1234567890"}'


async def test_symlink_cannot_escape_workspace(tmp_path, repo, sha, auth_file):
    workspace = tmp_path / "worktree"
    await worktree(repo, workspace, sha, Role.DEVELOPER, "symlink")
    secret = tmp_path / "secret"
    secret.write_text("host")
    (workspace / "escape").symlink_to(secret)
    sandbox = Sandbox(workspace, tmp_path / "run", Role.DEVELOPER)
    sandbox.prepare(Config(auth_file=auth_file))
    await command(
        *sandbox.argv(
            sys.executable,
            "-c",
            """
from pathlib import Path
try:
    Path('/workspace/escape').write_text('changed')
except OSError:
    pass
else:
    raise AssertionError('escaped the namespace')
""",
        )
    )
    assert secret.read_text() == "host"


def test_missing_bwrap_fails_closed(tmp_path, monkeypatch):
    monkeypatch.setattr(shutil, "which", lambda _: None)
    with pytest.raises(IsolationError, match="no unsandboxed fallback"):
        Sandbox(tmp_path, tmp_path, Role.DEVELOPER).prepare(Config())


def test_auth_copy_whitelists_only_model_auth(tmp_path, auth_file):
    auth_file.write_text(json.dumps({"OPENAI_API_KEY": "model-key", "GH_TOKEN": "host-gh-secret"}))
    sandbox = Sandbox(tmp_path, tmp_path / "run", Role.ANALYST)
    sandbox.prepare(Config(auth_file=auth_file))
    copied = sandbox.run_dir / "home/.codex/auth.json"
    assert json.loads(copied.read_text()) == {"OPENAI_API_KEY": "model-key"}
    assert os.stat(copied).st_mode & 0o777 == 0o600


async def test_developer_can_run_uv_project_checks(tmp_path, repo, sha, auth_file):
    workspace = tmp_path / "worktree"
    await worktree(repo, workspace, sha, Role.DEVELOPER, "uv-check")
    (workspace / "pyproject.toml").write_text(
        '[project]\nname="sandbox-check"\nversion="0.0.1"\nrequires-python=">=3.12"\n'
    )
    sandbox = Sandbox(workspace, tmp_path / "run", Role.DEVELOPER)
    sandbox.prepare(Config(auth_file=auth_file))
    await command(
        *sandbox.argv(
            "/tools/uv",
            "run",
            "--offline",
            "--python",
            "/usr/bin/python3.12",
            "python",
            "-c",
            "from pathlib import Path; assert Path('sample.txt').read_text() == 'original\\n'",
        )
    )
    assert not (repo / ".venv").exists()


def test_authenticated_proxy_is_not_passed_to_agent(tmp_path, auth_file, monkeypatch):
    monkeypatch.setenv("HTTPS_PROXY", "http://user:private@proxy.invalid:80")
    with pytest.raises(IsolationError, match="unauthenticated"):
        Sandbox(tmp_path, tmp_path / "run", Role.DEVELOPER).prepare(Config(auth_file=auth_file))
