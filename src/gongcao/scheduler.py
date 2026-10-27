"""Bounded polling of explicitly registered tasks, with dependencies and finite retries."""

import asyncio
import hashlib
import math
import time

from .config import Config
from .control import Controls
from .events import Redactor
from .github import GitHub
from .model import Stage, State
from .recovery import Recovery
from .store import Store
from .workflow import Workflow


class Scheduler:
    def __init__(self, store: Store, config: Config, github: GitHub, concurrency: int = 1):
        if not 1 <= concurrency <= 3:
            raise ValueError("Concurrency must be between 1 and 3")
        self.store, self.config, self.github = store, config, github
        self.semaphore = asyncio.Semaphore(concurrency)
        self.workflows: list[Workflow] = []

    def failed(self, task_id: int) -> None:
        task = self.store.task(task_id)
        if task["state"] not in {State.FAILED, State.WAITING_ENVIRONMENT}:
            return
        previous = self.store.db.execute(
            "SELECT * FROM retries WHERE task_id=?", (task_id,)
        ).fetchone()
        failures = previous["failures"] + 1 if previous else 1
        fingerprint = hashlib.sha256(
            f"{task['stage']}:{task['target_sha']}:{task['reason']}".encode()
        ).hexdigest()
        with self.store.db:
            self.store.db.execute("BEGIN IMMEDIATE")
            if self.store.db.execute("SELECT 1 FROM leases WHERE task_id=?", (task_id,)).fetchone():
                return
            self.store.db.execute(
                "INSERT OR REPLACE INTO retries VALUES(?,?,?,?)",
                (
                    task_id,
                    failures,
                    fingerprint,
                    0 if failures >= 3 else time.time() + 5 * 2**failures,
                ),
            )
            if failures >= 3:
                self.store.db.execute(
                    "UPDATE tasks SET state=?,reason=?,updated=? WHERE id=? AND state=? "
                    "AND updated=? AND cancel_requested=0",
                    (
                        State.HUMAN,
                        "Three execution/environment failures; manual retry required",
                        time.time(),
                        task_id,
                        task["state"],
                        task["updated"],
                    ),
                )

    async def advance(self, task_id: int) -> None:
        if self.store.task(task_id)["state"] == State.WAITING_INSTRUCTION:
            if self.config.copilot_operators:
                task = self.store.task(task_id)
                if self.store.db.execute(
                    "SELECT 1 FROM leases WHERE task_id=?", (task_id,)
                ).fetchone():
                    return
                try:
                    self.store.sync(task_id, await self.github.task_snapshot(task))
                    await Controls(self.store).poll(task_id, self.config, self.github)
                except Exception as exc:
                    if self.store.task(task_id)["state"] == State.WAITING_INSTRUCTION:
                        self.store.halt(
                            task_id,
                            State.WAITING_INSTRUCTION,
                            Redactor().text(f"Instruction poll failed: {exc}"),
                        )
                    return
            if self.store.task(task_id)["state"] == State.WAITING_INSTRUCTION:
                return
        async with self.semaphore:
            task = self.store.task(task_id)
            if (
                task["stage"] == Stage.MERGED
                or task["cancel_requested"]
                or task["state"] == State.WAITING_INSTRUCTION
            ):
                return
            due = self.store.db.execute(
                "SELECT next_at FROM retries WHERE task_id=?", (task_id,)
            ).fetchone()
            if due and due[0] > time.time():
                return
            workflow = Workflow(self.store, self.config, self.github)
            workflow.watch_instructions = False
            self.workflows.append(workflow)
            try:
                await workflow.run(task_id)
            finally:
                self.workflows.remove(workflow)
            if workflow.lease is None or not workflow.lease.acquired:
                return
            self.failed(task_id)
            if self.store.task(task_id)["state"] in {
                State.QUEUED,
                State.COMPLETED,
                State.WAITING_DEPENDENCY,
            }:
                with self.store.db:
                    self.store.db.execute("DELETE FROM retries WHERE task_id=?", (task_id,))

    async def serve(self, *, once: bool = False, poll: float = 5.0) -> None:
        async with Controls(self.store).listen(self.config, self.github):
            await self.execute(once=once, poll=poll)

    async def execute(self, *, once: bool, poll: float) -> None:
        if not math.isfinite(poll) or poll < 1:
            raise ValueError("Poll interval must be at least one second")
        recovery = Recovery(self.store, self.github)
        for task in self.store.tasks():
            if (
                task["state"] in {State.RUNNING, State.RECONCILE}
                or self.store.db.execute(
                    "SELECT 1 FROM leases WHERE task_id=?", (task["id"],)
                ).fetchone()
            ):
                await recovery.recover(task["id"])
        while True:
            pending = [asyncio.create_task(self.advance(t["id"])) for t in self.store.tasks()]
            group = asyncio.gather(*pending)
            try:
                await asyncio.shield(group)
            except BaseException:
                for workflow in self.workflows:
                    if workflow.lease:
                        workflow.lease.lost = True
                for task_run in pending:
                    task_run.cancel()
                closing = asyncio.gather(*pending, return_exceptions=True)
                while not closing.done():
                    try:
                        await asyncio.shield(closing)
                    except asyncio.CancelledError:
                        continue
                closing.result()
                # Retrieve the original group's cancellation/exception too.
                await asyncio.gather(group, return_exceptions=True)
                raise
            if once:
                return
            await asyncio.sleep(poll)
