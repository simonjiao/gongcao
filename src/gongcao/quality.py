"""Project-supplied checks execute in disposable, credential-free OS sandboxes."""

import asyncio
import json
import os
import platform
import re
import sys
import time
import uuid
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import Any

from .config import Config
from .control import Controls
from .events import Redactor
from .github import command
from .model import Role, Stage, State
from .plan import Check, binding, digest, propose
from .processes import launch, stop
from .sandbox import Sandbox
from .store import Store
from .workspace import context, worktree


class Quality:
    def __init__(self, store: Store, config: Config):
        self.store, self.config = store, config
        self.runtime = {
            "python": platform.python_version(),
            "platform": platform.platform(),
            "quality_isolation": "target-source-v1",
        }

    def confirm(
        self,
        task: dict[str, Any],
        items: list[dict[str, Any]],
        *,
        source: str = "operator",
        analysis_hash: str = "",
    ) -> dict[str, Any]:
        checks = [Check.model_validate(item).model_dump() for item in items]
        if {item["category"] for item in checks} != {"build", "internal", "e2e"}:
            raise ValueError("Plan must explicitly cover build, internal and e2e")
        if any(
            i["category"] == "e2e" and i["required"] and i["environment"] != "controlled"
            for i in checks
        ):
            raise ValueError("Required real E2E must use an explicitly authorized controlled entry")
        data = binding(task) | {
            "items": checks,
            "policy": self.config.policy_hash,
            "source": source,
            "analysis_hash": analysis_hash,
            "runtime": self.runtime,
            "environment_hash": self.environment_hash(checks),
        }
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
            if task["stage"] in {Stage.VALIDATION, Stage.MERGEABLE}:
                self.store.db.execute(
                    "UPDATE tasks SET stage=?,state=?,reason=?,updated=? WHERE id=?",
                    (
                        Stage.REVIEW,
                        State.QUEUED,
                        "Validation plan changed; review required",
                        time.time(),
                        task["id"],
                    ),
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

    @staticmethod
    def environment_hash(items: list[dict[str, Any]]) -> str:
        names = {name for item in items for name in item.get("variables", [])}
        if any(
            not re.fullmatch(r"(?:QA|PLAYWRIGHT|WORKSPACE|DORIS|FLINK|KAFKA)_[A-Z0-9_]+", n)
            for n in names
        ):
            raise ValueError("QA may only receive explicitly named engine/browser variables")
        return digest({name: os.environ.get(name) for name in sorted(names)})

    async def plan(self, task: dict[str, Any]) -> dict[str, Any]:
        analyses = [
            json.loads(r["result"])
            for r in self.store.runs(task["id"])
            if r["role"] == Role.ANALYST
            and r["state"] == State.COMPLETED
            and r["result"]
            and r["evidence_valid"]
            and r["target_sha"] == task["target_sha"]
            and json.loads(r["result"])["target_sha"] == task["target_sha"]
        ]
        proposal = analyses[-1].get("validation_plan", []) if analyses else []
        current = self.store.artifact(task["id"], "quality-plan", self.config.policy_hash)
        if (
            current
            and current["source"] == "operator"
            and all(current.get(k) == v for k, v in binding(task).items())
            and (
                current["runtime"] != self.runtime
                or current["environment_hash"] != self.environment_hash(current["items"])
            )
        ):
            return self.confirm(task, current["items"])
        if (
            current
            and current["runtime"] == self.runtime
            and current["environment_hash"] == self.environment_hash(current["items"])
            and all(current.get(k) == v for k, v in binding(task).items())
            and (current["source"] == "operator" or current["analysis_hash"] == digest(proposal))
        ):
            return current
        data, _ = await context(Path(task["repo_path"]), task, Role.REVIEWER, self.config, None)
        items = propose(data)
        covered = {i["category"] for i in proposal}
        items = [i for i in items if i["entry"] or i["category"] not in covered]
        for candidate in proposal:
            item = Check.model_validate(candidate).model_dump()
            same = next(
                (
                    i
                    for i in items
                    if all(
                        i[k] == item[k]
                        for k in ("category", "entry", "environment", "network", "variables")
                    )
                ),
                None,
            )
            if same is None:
                items.append(item)
            else:
                same["required"] |= item["required"]
                same["scope"] = list(dict.fromkeys([*same["scope"], *item["scope"]]))
                same["reason"] += "; " + item["reason"]
        if {i["category"] for i in proposal} != {"build", "internal", "e2e"}:
            items.append(
                Check(
                    category="internal",
                    entry=[],
                    scope=["Issue", "AGENTS.md"],
                    required=True,
                    reason="Current-SHA Issue and repository acceptance assessment required",
                ).model_dump()
            )
        return self.confirm(task, items, source="repository", analysis_hash=digest(proposal))

    async def run(
        self,
        task: dict[str, Any],
        *,
        include_e2e: bool = False,
        real_check: int | None = None,
        approved_plan: str | None = None,
        before_real: Callable[[], Awaitable[None]] | None = None,
    ) -> dict[str, Any]:
        self.store.guard(task)
        plan = await self.plan(task)
        task = self.store.task(task["id"])
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
        sandbox = Sandbox(workspace, directory, Role.DEVELOPER, controller_runtime=False)
        sandbox.prepare(self.config, authentication=False)
        isolation = await sandbox.verify(repo)
        started = time.time()
        results = []
        tainted = False
        for index, item in enumerate(commands):
            if not item["required"]:
                results.append(item | {"status": "not_applicable"})
                continue
            if cached and cached["items"][index]["status"] == "passed":
                results.append(cached["items"][index])
                continue
            if (
                tainted
                or not item["entry"]
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
                from .plan import controlled_entry

                real_workspace = self.store.root / "worktrees" / f"{key}-real-{index}"
                await worktree(
                    repo, real_workspace, task["target_sha"], Role.DEVELOPER, f"{key}-real-{index}"
                )
                controlled_entry(real_workspace, argv)
                if before_real is None:
                    raise ValueError("Real QA requires a controller authorization checkpoint")
                await before_real()
                real_sandbox = Sandbox(
                    real_workspace,
                    directory / f"real-{index}",
                    Role.DEVELOPER,
                    controller_runtime=False,
                )
                real_sandbox.prepare(self.config, authentication=False)
                await real_sandbox.verify(repo)
                isolated = real_sandbox.argv(*expanded)
                grant = [] if item["network"] else ["--unshare-net"]
                for name in item["variables"]:
                    if name in os.environ:
                        grant += ["--setenv", name, os.environ[name]]
                split = isolated.index("--")
                isolated[split:split] = grant
                process = await launch(*isolated)
            else:
                process = await launch(
                    *sandbox.argv(
                        "/usr/bin/env",
                        "-u",
                        "PYTHONPATH",
                        "UV_PROJECT_ENVIRONMENT=/tmp/quality-venv",
                        "UV_CACHE_DIR=/workspace/.venv/uv-cache",
                        "UV_LINK_MODE=copy",
                        *expanded,
                    )
                )

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
            checked_workspace = real_workspace if item["environment"] == "controlled" else workspace
            dirty = await command(
                "git",
                "status",
                "--porcelain",
                "--untracked-files=normal",
                cwd=str(checked_workspace),
            )
            head = (await command("git", "rev-parse", "HEAD", cwd=str(checked_workspace))).strip()
            if dirty or head != task["target_sha"]:
                tainted = True
                code, stderr = (
                    1,
                    {"tail": "Source changed or unignored files added; SHA evidence rejected"},
                )
            results.append(
                item
                | {
                    "status": "passed"
                    if code == 0
                    else "blocked"
                    if code in {77, 127}
                    else "failed",
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
        from .events import task_event

        counts = {
            status: sum(r["status"] == status for r in results)
            for status in ("passed", "failed", "blocked")
        }
        task_event(
            self.store,
            task["id"],
            f"质量结果：通过 {counts['passed']}；失败 {counts['failed']}；"
            f"未执行/缺环境 {counts['blocked']}",
        )
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
