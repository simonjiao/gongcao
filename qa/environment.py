"""Check capabilities without importing host credentials into a sandbox or a report."""

import asyncio
import importlib.metadata
import os
import shutil
import sys
import tempfile
import tomllib
from pathlib import Path
from typing import Any

from gongcao.config import Config
from gongcao.github import GitHub, command
from gongcao.model import Role
from gongcao.processes import stop
from gongcao.sandbox import Sandbox


async def check(*, real: bool = False, repository: str | None = None) -> dict[str, Any]:
    if sys.platform != "linux" or sys.version_info < (3, 12):
        raise ValueError("QA requires Linux/WSL and Python >=3.12")
    versions = {"python": sys.version.split()[0]}
    for name in ("uv", "git", "gh", "bwrap"):
        if shutil.which(name) is None:
            raise ValueError(f"Missing {name}; see qa/README.md")
        versions[name] = (await command(name, "--version")).strip().splitlines()[0]
    lock = tomllib.loads((Path(__file__).resolve().parents[1] / "uv.lock").read_text())
    for name in ("openai-codex", "PyYAML", "uv"):
        expected = next(p["version"] for p in lock["package"] if p["name"] == name.lower())
        installed = importlib.metadata.version(name)
        if installed != expected:
            raise ValueError(f"{name} {installed} != uv.lock {expected}; run uv sync --locked")
        versions[name] = installed
    with tempfile.TemporaryDirectory(prefix="gongcao-qa-probe-") as temporary:
        root = Path(temporary)
        workspace, private, host = root / "workspace", root / "private", root / "host"
        for path in (workspace, private, host / ".git"):
            path.mkdir(parents=True)
        (workspace / ".git").touch()
        (host / ".git/config").write_text("private host canary")
        sandbox = Sandbox(workspace, private, Role.REVIEWER)
        sandbox.prepare(Config(), authentication=False)
        isolation = await sandbox.verify(host)
    result: dict[str, Any] = {"versions": versions, "isolation": isolation, "real": real}
    if real:
        if repository is None:
            raise ValueError("--repo OWNER/REPO is required for real QA")
        github = GitHub()
        metadata = await github.read(f"repos/{repository}")
        if not metadata.get("permissions", {}).get("push") or metadata.get("archived"):
            raise ValueError("Target must be a writable, non-archived test repository")
        result["repository"] = {
            "full_name": metadata["full_name"].lower(),
            "default_branch": metadata["default_branch"],
            "ssh_url": metadata["ssh_url"],
        }
        result["github_login"] = (await github.read("user"))["login"]
        result["model_authorized"] = await model_authorized()
        if not result["model_authorized"]:
            raise ValueError("Codex account is unavailable; log in before real QA")
    return result


async def model_authorized() -> bool:
    # The SDK merges its environment with os.environ. Probe in a separate process
    # with a whitelist so GitHub/SSH credentials never reach the SDK app-server.
    script = """
import asyncio
from openai_codex import AsyncCodex, CodexConfig
async def probe():
    async with AsyncCodex(CodexConfig()) as codex:
        account = await codex.account(refresh_token=True)
        print('authorized' if account.account is not None else 'missing')
asyncio.run(probe())
"""
    names = (
        "HOME",
        "PATH",
        "CODEX_HOME",
        "LANG",
        "OPENAI_API_KEY",
        "HTTPS_PROXY",
        "HTTP_PROXY",
        "NO_PROXY",
        "SSL_CERT_FILE",
        "SSL_CERT_DIR",
    )
    process = await asyncio.create_subprocess_exec(
        sys.executable,
        "-c",
        script,
        env={name: os.environ[name] for name in names if name in os.environ},
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        start_new_session=True,
    )
    try:
        stdout, _ = await asyncio.wait_for(process.communicate(), 40)
        return process.returncode == 0 and stdout.strip() == b"authorized"
    finally:
        await stop(process)
