"""Linux mount/PID/user namespaces. A failed probe always prevents agent execution."""

import json
import os
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

import uv

from .config import Config
from .github import command
from .model import Role


class IsolationError(RuntimeError):
    pass


@dataclass
class Sandbox:
    workspace: Path
    run_dir: Path
    role: Role
    controller_runtime: bool = True

    def prepare(self, config: Config, *, authentication: bool = True) -> list[str]:
        if sys.platform != "linux" or shutil.which("bwrap") is None:
            raise IsolationError("Linux and Bubblewrap are required; no unsandboxed fallback")
        for name in ("HTTPS_PROXY", "HTTP_PROXY"):
            if proxy := os.environ.get(name):
                parsed = urlsplit(proxy)
                if (
                    parsed.username
                    or parsed.password
                    or parsed.scheme
                    not in {
                        "http",
                        "https",
                        "socks5",
                        "socks5h",
                    }
                ):
                    raise IsolationError(
                        "Only unauthenticated HTTP(S)/SOCKS egress proxies supported"
                    )
        home = self.run_dir / "home"
        codex_home = home / ".codex"
        codex_home.mkdir(parents=True, mode=0o700)
        # A dedicated copy of *model* authentication, never host configuration/skills/MCP or gh.
        auth: dict[str, Any]
        if not authentication:
            auth = {}
        elif config.auth_file.is_file():
            raw = json.loads(config.auth_file.read_text())
            auth = {
                key: raw[key]
                for key in ("auth_mode", "OPENAI_API_KEY", "tokens", "last_refresh")
                if key in raw
            }
        elif os.environ.get("OPENAI_API_KEY"):
            auth = {"OPENAI_API_KEY": os.environ["OPENAI_API_KEY"]}
        else:
            raise IsolationError("Codex authentication missing; set auth_file or OPENAI_API_KEY")
        auth_path = codex_home / "auth.json"
        auth_path.write_text(json.dumps(auth))
        auth_path.chmod(0o600)
        # No user config is imported. Disable discovery beyond this isolated runtime.
        (codex_home / "config.toml").write_text('cli_auth_credentials_store = "file"\n')
        (self.run_dir / "empty").touch(mode=0o600)
        secrets: list[str] = []

        def collect(value: Any) -> None:
            if isinstance(value, dict):
                for item in value.values():
                    collect(item)
            elif isinstance(value, str):
                secrets.append(value)

        collect(auth)
        return secrets

    def argv(self, *payload: str) -> list[str]:
        args = [
            "bwrap",
            "--die-with-parent",
            "--new-session",
            "--unshare-user",
            "--unshare-pid",
            "--unshare-ipc",
            "--unshare-uts",
            "--unshare-cgroup-try",
            "--cap-drop",
            "ALL",
            "--clearenv",
            "--proc",
            "/proc",
            "--dev",
            "/dev",
            "--tmpfs",
            "/tmp",
        ]
        # Construct a new root, rather than binding / and trying to hide selected secrets.
        for mount in ("/usr", "/bin", "/sbin", "/lib", "/lib64"):
            if Path(mount).exists():
                args += ["--ro-bind", mount, mount]
        for mount in (
            "/etc/ssl",
            "/etc/resolv.conf",
            "/etc/hosts",
            "/etc/nsswitch.conf",
            "/etc/passwd",
            "/etc/group",
        ):
            if Path(mount).exists():
                args += ["--ro-bind", mount, mount]
        # uv-managed Python and CI interpreters may live outside /usr; include only their roots.
        prefixes = {Path(sys.base_prefix).resolve()}
        if self.controller_runtime:
            prefixes.add(Path(sys.prefix).resolve())
        for prefix in prefixes:
            if not prefix.is_relative_to("/usr"):
                args += ["--ro-bind", str(prefix), str(prefix)]
        # Only SDK workers need the controller implementation and its dependencies.
        # Project checks must resolve code from their fixed-SHA workspace/environment.
        if self.controller_runtime:
            args += [
                "--ro-bind",
                str(Path(__file__).resolve().parent.parent),
                "/app",
                "--setenv",
                "PYTHONPATH",
                "/app",
            ]
        args += [
            "--ro-bind",
            uv.find_uv_bin(),
            "/tools/uv",
            "--bind",
            str(self.run_dir / "home"),
            "/home/agent",
            "--bind" if self.role.writable else "--ro-bind",
            str(self.workspace),
            "/workspace",
            "--ro-bind",
            str(self.run_dir / "empty"),
            "/workspace/.git",
            "--setenv",
            "HOME",
            "/home/agent",
            "--setenv",
            "CODEX_HOME",
            "/home/agent/.codex",
            "--setenv",
            "PATH",
            "/tools:/usr/bin:/bin",
            "--setenv",
            "LANG",
            "C.UTF-8",
            "--setenv",
            "GIT_CONFIG_NOSYSTEM",
            "1",
            "--setenv",
            "GIT_CONFIG_GLOBAL",
            "/dev/null",
            "--remount-ro",
            "/",
            "--chdir",
            "/workspace",
        ]
        # Preserve only credential-free transport configuration needed for model connectivity.
        for name in ("HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY"):
            if value := os.environ.get(name):
                args += ["--setenv", name, value]
        return args + ["--", *payload]

    async def verify(self, host_repo: Path) -> dict[str, Any]:
        """Use the identical mounts and environment to check actual access, before starting SDK."""
        script = r"""
import json, os, pathlib, uuid, subprocess
blocked = json.loads(__import__('sys').argv[1])
for name in blocked:
    try:
        pathlib.Path(name).read_bytes()
    except (FileNotFoundError, PermissionError, IsADirectoryError):
        pass
    else:
        raise RuntimeError('host path is readable: ' + name)
assert not any(k in os.environ for k in (
    'GH_TOKEN','GITHUB_TOKEN','GH_ENTERPRISE_TOKEN','SSH_AUTH_SOCK','AWS_SECRET_ACCESS_KEY'
))
assert len(pathlib.Path('/workspace/.git').read_bytes()) == 0
for name in ['/etc/gongcao-probe', '/app/gongcao/.gongcao-probe']:
    try:
        pathlib.Path(name).write_text('outside workspace')
    except OSError:
        pass
    else:
        raise RuntimeError('outside workspace writable')
probe = pathlib.Path('/workspace') / ('.gongcao-probe-' + uuid.uuid4().hex)
try:
    probe.write_text('probe')
except OSError:
    writable = False
else:
    writable = True
    probe.unlink()
assert writable == (__import__('sys').argv[2] == 'write')
uv_version = subprocess.check_output(['uv', '--version'], text=True).strip()
print(json.dumps({'host_credentials': 'blocked', 'host_repository': 'blocked',
                  'workspace_writable': writable, 'external_writes': 'blocked',
                  'uv': uv_version}))
"""
        blocked = [
            str(Path.home() / ".config/gh/hosts.yml"),
            str(Path.home() / ".git-credentials"),
            str(Path.home() / ".codex/auth.json"),
            str(host_repo / ".git/config"),
            "/proc/1/root/home/simon/.config/gh/hosts.yml",
        ]
        try:
            output = await command(
                *self.argv(
                    sys.executable
                    if self.controller_runtime
                    else str(Path(sys.base_prefix) / "bin/python3"),
                    "-c",
                    script,
                    json.dumps(blocked),
                    "write" if self.role.writable else "read",
                )
            )
            return json.loads(output)  # type: ignore[no-any-return]
        except (RuntimeError, OSError, ValueError) as exc:
            raise IsolationError(f"Sandbox verification failed: {exc}") from exc
