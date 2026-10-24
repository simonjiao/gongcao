"""Project-supplied checks execute in disposable, credential-free OS sandboxes."""

import asyncio
import sys
import time
import uuid
from pathlib import Path
from typing import Any

from .config import Config
from .events import Redactor
from .model import Role, Stage, State
from .processes import stop
from .sandbox import Sandbox
from .store import Store
from .workspace import worktree


class Quality:
    def __init__(self, store: Store, config: Config):
        self.store, self.config = store, config

    async def run(self, task: dict[str, Any], kind: str) -> dict[str, Any]:
        cached = self.store.artifact(task["id"], kind, self.config.policy_hash)
        if cached is not None:
            return cached
        commands = self.config.checks if kind == "checks" else self.config.real_checks
        if not commands:
            raise ValueError(f"No target-project commands configured for {kind}")
        self.store.transition(task, Stage(task["stage"]), State.RUNNING, f"Running {kind}")
        key = f"check-{uuid.uuid4().hex}"
        directory = self.store.root / "checks" / key
        directory.mkdir(parents=True, mode=0o700)
        workspace = self.store.root / "worktrees" / key
        repo = Path(task["repo_path"])
        await worktree(repo, workspace, task["target_sha"], Role.DEVELOPER, key)
        sandbox = Sandbox(workspace, directory, Role.DEVELOPER)
        sandbox.prepare(self.config, authentication=False)
        isolation = await sandbox.verify(repo)
        started = time.time()
        results = []
        for argv in commands:
            command_started = time.time()
            expanded = [
                arg.replace("{python}", str(Path(sys.base_prefix) / "bin/python3")).replace(
                    "{sha}", task["target_sha"]
                )
                for arg in argv
            ]
            process = await asyncio.create_subprocess_exec(
                *sandbox.argv("/usr/bin/env", "-u", "PYTHONPATH", *expanded),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                start_new_session=True,
            )

            async def output(stream: asyncio.StreamReader | None) -> dict[str, Any]:
                assert stream is not None
                tail = b""
                line = b""
                size = 0
                dropping = False
                omitted = False
                while chunk := await stream.read(65536):
                    size += len(chunk)
                    for part in chunk.splitlines(keepends=True):
                        if not dropping:
                            line += part
                            if len(line) > 1_048_576:
                                line, dropping, omitted = b"", True, True
                        if part.endswith((b"\n", b"\r")):
                            clean = (
                                b"[oversized output line omitted]\n"
                                if dropping
                                else (Redactor().text(line.decode(errors="replace")).encode())
                            )
                            tail = (tail + clean)[-20000:]
                            line, dropping = b"", False
                if line or dropping:
                    clean = (
                        b"[oversized output line omitted]"
                        if dropping
                        else (Redactor().text(line.decode(errors="replace")).encode())
                    )
                    tail = (tail + clean)[-20000:]
                return {
                    "tail": tail.decode(errors="replace"),
                    "truncated": size > 20000 or omitted,
                    "bytes": size,
                }

            readers = [
                asyncio.create_task(output(process.stdout)),
                asyncio.create_task(output(process.stderr)),
            ]
            pending = asyncio.gather(*readers, process.wait())
            try:
                async with asyncio.timeout(self.config.timeout_seconds):
                    while not pending.done():
                        if self.store.task(task["id"])["cancel_requested"]:
                            raise asyncio.CancelledError
                        await asyncio.wait({pending}, timeout=0.2)
                    stdout, stderr, code = pending.result()
            finally:
                pending.cancel()
                await asyncio.gather(pending, return_exceptions=True)
                await stop(process, readers)
            results.append(
                {
                    "argv": [Redactor().text(arg) for arg in expanded],
                    "exit_code": code,
                    "stdout": stdout,
                    "stderr": stderr,
                    "started": command_started,
                    "ended": time.time(),
                }
            )
            if code:
                break
        data = {
            "target_sha": task["target_sha"],
            "policy": self.config.policy_hash,
            "passed": all(row["exit_code"] == 0 for row in results),
            "commands": results,
            "isolation": isolation,
            "directory": str(directory),
            "started": started,
            "ended": time.time(),
        }
        self.store.record(task, kind, self.config.policy_hash, data)
        return data


def ci_gate(task: dict[str, Any], facts: dict[str, Any], workflows: list[str]) -> tuple[State, str]:
    if facts.get("headRefOid") != task["target_sha"]:
        return State.RECONCILE, "GitHub CI facts refer to a different head"
    if not workflows:
        return State.WAITING_ENVIRONMENT, "Configure required target-repository CI workflows"
    for name in workflows:
        candidates = [
            run
            for run in facts["workflows"]
            if run["head_sha"] == task["target_sha"]
            and run["event"] == "pull_request"
            and run["head_branch"] == task["snapshot"]["head_ref"]
            and run["path"].split("@", 1)[0] == f".github/workflows/{name}"
        ]
        if not candidates:
            return State.WAITING_DEPENDENCY, f"No CI run for {name} at the target SHA"
        latest = max(candidates, key=lambda run: (run["id"], run.get("run_attempt", 1)))
        if latest["status"] != "completed":
            return State.WAITING_DEPENDENCY, f"CI {name} is {latest['status']}"
        if latest["conclusion"] not in {"success", "failure", "timed_out"}:
            return State.WAITING_DEPENDENCY, f"CI {name} concluded {latest['conclusion']}"
        proof = latest.get("target_proof") or {}
        if any(
            proof.get(key) != value
            for key, value in {
                "repository": task["snapshot"]["repository"],
                "pr_number": task["pr_number"],
                "head_sha": task["target_sha"],
                "base_sha": task["snapshot"]["base_sha"],
                "base_ref": task["snapshot"]["base_ref"],
                "run_id": latest["id"],
                "attempt": latest.get("run_attempt", 1),
            }.items()
        ):
            return State.WAITING_DEPENDENCY, f"CI {name} has no verified current PR/base checkout"
        if latest["conclusion"] != "success":
            if not proof.get("failure_tail"):
                return State.WAITING_DEPENDENCY, f"CI {name} has no bound failure diagnostics"
            return State.FAILED, f"CI {name} concluded {latest['conclusion']}"
    return State.COMPLETED, "Required CI workflows passed at the target SHA"
