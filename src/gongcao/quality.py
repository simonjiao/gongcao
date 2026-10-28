"""Project-supplied checks execute in disposable, credential-free OS sandboxes."""

import asyncio
import json
import sys
import time
import uuid
from pathlib import Path
from typing import Any

from .config import Config
from .control import Controls
from .events import Redactor
from .model import Role, Stage, State
from .plan import Check, binding, digest, propose
from .processes import launch, stop
from .sandbox import Sandbox
from .store import Store
from .workspace import context, worktree


class Quality:
    def __init__(self, store: Store, config: Config):
        self.store, self.config = store, config

    def confirm(self, task: dict[str, Any], items: list[dict[str, Any]]) -> dict[str, Any]:
        checks = [Check.model_validate(item).model_dump() for item in items]
        if {item["category"] for item in checks} != {"build", "internal", "e2e"}:
            raise ValueError("Plan must explicitly cover build, internal and e2e")
        data = binding(task) | {"items": checks, "policy": self.config.policy_hash}
        data["plan_hash"] = digest(data)
        previous = self.store.artifact(task["id"], "quality-plan", self.config.policy_hash)
        if previous == data:
            return data
        with self.store.db:
            self.store.db.execute("BEGIN IMMEDIATE")
            Controls(self.store).fence(task["id"])
            self.store.guard(task)
            self.store.db.execute(
                "UPDATE artifacts SET valid=0 WHERE task_id=? AND kind IN "
                "('quality-plan','quality-results','validation')",
                (task["id"],),
            )
            self.store.db.execute(
                "UPDATE runs SET evidence_valid=0 WHERE task_id=? "
                "AND role IN ('reviewer','validator')",
                (task["id"],),
            )
            self.store.db.execute(
                "INSERT INTO artifacts(task_id,sha,kind,policy,data) VALUES(?,?,?,?,?)",
                (
                    task["id"],
                    task["target_sha"],
                    "quality-plan",
                    self.config.policy_hash,
                    json.dumps(data),
                ),
            )
        return data

    async def plan(self, task: dict[str, Any]) -> dict[str, Any]:
        current = self.store.artifact(task["id"], "quality-plan", self.config.policy_hash)
        if current and all(current.get(k) == v for k, v in binding(task).items()):
            return current
        data, _ = await context(Path(task["repo_path"]), task, Role.REVIEWER, self.config, None)
        items = propose(data)
        analyses = [
            json.loads(r["result"])
            for r in self.store.runs(task["id"])
            if r["role"] == Role.ANALYST and r["state"] == State.COMPLETED and r["result"]
        ]
        for candidate in analyses[-1].get("validation_plan", []) if analyses else []:
            item = Check.model_validate(candidate).model_dump()
            if item["required"] and item["entry"]:
                items = [i for i in items if i["entry"] or i["category"] != item["category"]]
                if item not in items:
                    items.append(item)
        return self.confirm(task, items)

    async def run(
        self,
        task: dict[str, Any],
        *,
        include_e2e: bool = False,
        real_check: int | None = None,
        approved_plan: str | None = None,
    ) -> dict[str, Any]:
        plan = await self.plan(task)
        if real_check is not None and approved_plan != plan["plan_hash"]:
            raise ValueError("Explicit real QA authorization must name the current plan hash")
        cached = self.store.artifact(task["id"], "quality-results", plan["plan_hash"])
        if cached and verdict(cached, include_e2e=include_e2e) == "passed":
            return cached
        commands = plan["items"]
        self.store.transition(
            task, Stage(task["stage"]), State.RUNNING, "Executing validation plan"
        )
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
        for index, item in enumerate(commands):
            if not item["required"]:
                results.append(item | {"status": "not_applicable"})
                continue
            if cached and cached["items"][index]["status"] == "passed":
                results.append(cached["items"][index])
                continue
            if (
                not item["entry"]
                or (item["environment"] == "controlled" and index != real_check)
                or (item["category"] == "e2e" and not include_e2e)
            ):
                results.append(
                    item
                    | {
                        "status": "blocked",
                        "detail": "Entry/environment or explicit real authorization required",
                    }
                )
                continue
            argv = item["entry"]
            command_started = time.time()
            expanded = [
                arg.replace("{python}", str(Path(sys.base_prefix) / "bin/python3")).replace(
                    "{sha}", task["target_sha"]
                )
                for arg in argv
            ]
            if item["environment"] == "controlled":
                entry = next((arg for arg in argv[:2] if arg.startswith("qa/")), "")
                script = (workspace / entry).resolve()
                if not entry or not script.is_file() or not script.is_relative_to(workspace / "qa"):
                    raise ValueError("Real checks must invoke an existing repository qa/ entry")
                process = await launch(*expanded, cwd=str(workspace))
            else:
                process = await launch(*sandbox.argv("/usr/bin/env", "-u", "PYTHONPATH", *expanded))

            async def output(
                stream: asyncio.StreamReader | None, name: str, index: int = index
            ) -> dict[str, Any]:
                assert stream is not None
                tail = b""
                line = b""
                size = 0
                dropping = False
                omitted = False
                raw = directory / f"{index}-{name}.raw"
                raw.touch(mode=0o600)
                while chunk := await stream.read(65536):
                    with raw.open("ab") as log:
                        log.write(chunk)
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
                asyncio.create_task(output(process.stdout, "stdout")),
                asyncio.create_task(output(process.stderr, "stderr")),
            ]
            pending = asyncio.gather(*readers, process.wait())
            try:
                async with asyncio.timeout(self.config.timeout_seconds):
                    while not pending.done():
                        if self.store.task(task["id"])["cancel_requested"]:
                            raise asyncio.CancelledError
                        await asyncio.wait({pending}, timeout=0.2)
                    stdout, stderr, code = pending.result()
            except TimeoutError:
                stdout, stderr, code = {}, {"tail": "Check timed out"}, 124
            finally:
                pending.cancel()
                await asyncio.gather(pending, return_exceptions=True)
                await stop(process, readers)
            results.append(
                item
                | {
                    "status": "passed" if code == 0 else "blocked" if code == 127 else "failed",
                    "argv": [Redactor().text(arg) for arg in expanded],
                    "exit_code": code,
                    "stdout": stdout,
                    "stderr": stderr,
                    "started": command_started,
                    "ended": time.time(),
                }
            )
        data = plan | {
            "run_id": key,
            "items": results,
            "isolation": isolation,
            "directory": str(directory),
            "started": started,
            "ended": time.time(),
        }
        data["passed"] = verdict(data, include_e2e=include_e2e) == "passed"
        self.store.record(task, "quality-results", plan["plan_hash"], data)
        return data


def verdict(data: dict[str, Any], *, include_e2e: bool = True) -> str:
    required = [
        item
        for item in data["items"]
        if item["required"] and (include_e2e or item["category"] != "e2e")
    ]
    if any(item["status"] == "failed" for item in required):
        return "failed"
    return "passed" if all(item["status"] == "passed" for item in required) else "blocked"
