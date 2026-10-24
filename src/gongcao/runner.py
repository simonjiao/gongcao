"""One explicitly selected task per invocation. Remote writes are absent from PR1."""

import asyncio
import json
import os
import signal
import sqlite3
import sys
import time
from pathlib import Path
from typing import Any

from .config import Config
from .events import Journal, Redactor
from .github import GitHub, Target
from .model import AgentResult, Role, Stage, State, after_run
from .sandbox import IsolationError, Sandbox
from .store import Store
from .workspace import context, worktree


async def stop(process: asyncio.subprocess.Process) -> None:
    if process.returncode is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        await asyncio.wait_for(process.wait(), timeout=3)
    except TimeoutError:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        await process.wait()


class Runner:
    def __init__(self, store: Store, config: Config, github: GitHub):
        self.store, self.config, self.github = store, config, github

    async def run(self, task_id: int) -> str:
        task = self.store.task(task_id)
        self.store.sync(task_id, await self.github.snapshot(Target.parse(task["url"])))
        task = self.store.task(task_id)
        role = {Stage.ANALYSIS: Role.ANALYST, Stage.DEVELOPMENT: Role.DEVELOPER}.get(
            Stage(task["stage"])
        )
        if role is None:
            raise ValueError("This stage is not executable in PR1")
        run_id = self.store.begin_run(task_id, role, expected_snapshot=task["snapshot"])
        run_dir = self.store.root / "runs" / run_id
        journal: Journal | None = None
        process: asyncio.subprocess.Process | None = None
        consumers: list[asyncio.Task[Any]] = []
        started = time.monotonic()
        stage = Stage(task["stage"])
        try:
            run_dir.mkdir(parents=True, mode=0o700)
            journal = Journal(self.store, run_id, self.config.max_log_bytes, Redactor())
            journal.emit(
                "started", {"task_id": task_id, "role": role, "target_sha": task["target_sha"]}
            )
            if task["snapshot"]["state"] != "open":
                self.store.finish(
                    run_id,
                    State.HUMAN,
                    stage,
                    State.HUMAN,
                    "GitHub object is closed; manual handling required",
                )
                return run_id
            repo = Path(task["repo_path"])
            workspace = self.store.root / "worktrees" / run_id
            await worktree(repo, workspace, task["target_sha"], role, run_id)
            self.store.run_metadata(run_id, worktree=str(workspace))
            analysis = None
            if role == Role.DEVELOPER:
                candidates = [
                    r
                    for r in self.store.runs(task_id)
                    if r["role"] == Role.ANALYST
                    and r["state"] == State.COMPLETED
                    and r["evidence_valid"]
                    and r["target_sha"] == task["target_sha"]
                ]
                if not candidates:
                    raise ValueError("No confirmed analysis for the target revision")
                analysis = json.loads(candidates[-1]["result"])
            data, digest = await context(repo, task, role, self.config, analysis)
            (run_dir / "context.json").write_text(json.dumps(data, ensure_ascii=False, indent=2))
            self.store.run_metadata(run_id, context_hash=digest)
            sandbox = Sandbox(workspace, run_dir, role)
            journal.redactor = Redactor(sandbox.prepare(self.config))
            journal.emit("isolation_verified", await sandbox.verify(repo))
            process = await asyncio.create_subprocess_exec(
                *sandbox.argv(sys.executable, "-m", "gongcao.worker"),
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                start_new_session=True,
                limit=1_048_576,
            )
            assert process.stdin is not None
            process.stdin.write(
                json.dumps(
                    {
                        "context": data,
                        "model": self.config.model,
                        "writable": role.writable,
                    }
                ).encode()
                + b"\n"
            )
            await process.stdin.drain()
            process.stdin.close()
            receiver = asyncio.create_task(self.receive(process, run_id, journal))
            stderr_reader = asyncio.create_task(self.stderr(process, journal))
            consumers = [receiver, stderr_reader]
            deadline = time.monotonic() + self.config.timeout_seconds
            while not receiver.done():
                if self.store.task(task_id)["cancel_requested"]:
                    raise asyncio.CancelledError
                if time.monotonic() >= deadline:
                    raise TimeoutError("Agent exceeded the configured execution deadline")
                await asyncio.wait({receiver}, timeout=0.2)
            result = receiver.result()
            await asyncio.wait_for(process.wait(), timeout=5)
            await stderr_reader
            if process.returncode != 0 or result is None:
                raise RuntimeError(
                    f"Agent exited without a valid result (exit={process.returncode})"
                )
            # A fresh remote read is required before accepting any version-bound artifact.
            latest = await self.github.snapshot(Target.parse(task["url"]))
            self.store.sync(task_id, latest)
            next_stage, state, reason = after_run(stage, role, result, task["target_sha"])
            if latest["state"] != "open":
                next_stage, state, reason = (
                    stage,
                    State.HUMAN,
                    "GitHub object closed during execution",
                )
            self.store.finish(
                run_id,
                State.COMPLETED,
                next_stage,
                state,
                reason,
                journal.redactor.text(result.model_dump_json()),
            )
        except asyncio.CancelledError:
            self.store.cancel(task_id)
            self.store.finish(run_id, State.CANCELLED, stage, State.CANCELLED, "Cancelled by user")
        except Exception as exc:
            state = (
                State.WAITING_ENVIRONMENT
                if isinstance(exc, (IsolationError, OSError)) and not isinstance(exc, TimeoutError)
                else State.FAILED
            )
            redactor = journal.redactor if journal is not None else Redactor()
            message = redactor.text(f"{type(exc).__name__}: {exc}")
            if journal is not None:
                try:
                    journal.emit("error", message)
                except (OSError, sqlite3.Error):
                    pass  # The SQLite execution record must survive a failed log sink.
            self.store.finish(run_id, state, stage, state, message)
        finally:
            if process is not None:
                await stop(process)
            for consumer in consumers:
                if not consumer.done():
                    consumer.cancel()
            if consumers:
                await asyncio.gather(*consumers, return_exceptions=True)
            if journal is not None:
                try:
                    journal.emit(
                        "ended",
                        {
                            "task_id": task_id,
                            "duration_seconds": round(time.monotonic() - started, 3),
                            "state": self.store.runs(task_id)[-1]["state"],
                        },
                    )
                except (OSError, sqlite3.Error):
                    pass
        return run_id

    async def receive(
        self,
        process: asyncio.subprocess.Process,
        run_id: str,
        journal: Journal,
    ) -> AgentResult | None:
        assert process.stdout is not None
        result = None
        async for line in process.stdout:
            message = json.loads(line)
            kind, data = message["kind"], message["data"]
            journal.emit(kind, data)
            if kind == "thread":
                self.store.run_metadata(run_id, thread_id=str(data["thread_id"]))
            elif kind == "result":
                if result is not None:
                    raise ValueError("Duplicate worker result")
                result = AgentResult.model_validate(data)
            elif kind == "error":
                raise RuntimeError(str(data))
        return result

    async def stderr(self, process: asyncio.subprocess.Process, journal: Journal) -> None:
        assert process.stderr is not None
        async for line in process.stderr:
            journal.emit("worker_stderr", line.decode(errors="replace"))
