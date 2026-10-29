"""Bounded polling of explicitly registered tasks, with dependencies and finite retries."""

import asyncio
import hashlib
import math
import time
from pathlib import Path

from .config import Config
from .control import Controls
from .discovery import Discovery
from .events import LOG, Redactor, progress, task_event
from .github import Deferred, GitHub, background
from .model import Stage, State
from .recovery import Recovery
from .store import Store
from .workflow import Workflow


class Scheduler:
    def __init__(self, store: Store, config: Config, github: GitHub, concurrency: int = 1):
        if not 1 <= concurrency <= 3:
            raise ValueError("Concurrency must be between 1 and 3")
        self.store, self.config, self.github = store, config, github
        github.traffic.restore(store)
        self.semaphore = asyncio.Semaphore(concurrency)
        self.workflows: list[Workflow] = []
        self.concurrency = concurrency
        self.config_path: Path | None = None
        self.next_check: dict[int, float] = {}

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
        task_event(
            self.store,
            task_id,
            "异常重试已暂停，等待人工处理"
            if failures >= 3
            else f"异常待重试：第 {failures} 次，已记录退避",
        )

    async def advance(self, task_id: int, *, immediate: bool = True) -> None:
        try:
            await self._advance(task_id, immediate=immediate)
        except Deferred as exc:
            self.github.traffic.defer(self.store, task_id, exc)

    async def _advance(self, task_id: int, *, immediate: bool) -> None:
        if time.time() < self.github.traffic.cooldown:
            return
        task = self.store.task(task_id)
        cooldown = self.store.artifact(task_id, "github-cooldown", "")
        if cooldown and cooldown.get("recovery"):
            result = await Recovery(self.store, self.github).recover(task_id)
            if time.time() < self.github.traffic.cooldown:
                return
            with self.store.db:
                self.store.db.execute(
                    "UPDATE artifacts SET valid=0 WHERE task_id=? AND kind='github-cooldown'",
                    (task_id,),
                )
            if not result["recovered"]:
                return
            task = self.store.task(task_id)
        wake = bool(
            self.store.db.execute(
                "SELECT 1 FROM instructions WHERE task_id=? AND status='pending' AND reason=''",
                (task_id,),
            ).fetchone()
        )
        if wake:
            immediate = True  # A newly collected permission gets a fresh safety check now.
        if not immediate and task["state"] in {State.HUMAN, State.RECONCILE}:
            await Controls(self.store).collect(task_id, self.config, self.github, force=False)
            return  # Only a newly verified recovery permission can advance blocked work.
        if not immediate and task["state"] not in {State.QUEUED, State.WAITING_INSTRUCTION}:
            if time.monotonic() < self.next_check.get(task_id, 0):
                return
            self.next_check[task_id] = time.monotonic() + 60
        if self.store.task(task_id)["state"] == State.WAITING_INSTRUCTION:
            if self.config.copilot_operators:
                controls = Controls(self.store)
                if not immediate:
                    await controls.collect(task_id, self.config, self.github, force=False)
                    if not self.store.db.execute(
                        "SELECT 1 FROM instructions WHERE task_id=? "
                        "AND status='pending' AND reason=''",
                        (task_id,),
                    ).fetchone():
                        return
                    immediate = True
                task = self.store.task(task_id)
                if self.store.db.execute(
                    "SELECT 1 FROM leases WHERE task_id=?", (task_id,)
                ).fetchone():
                    return
                token = background.set(not immediate)
                try:
                    self.store.sync(task_id, await self.github.task_snapshot(task))
                    await controls.poll(task_id, self.config, self.github, force=immediate)
                except Deferred as exc:
                    self.github.traffic.defer(self.store, task_id, exc)
                    return
                except Exception as exc:
                    if self.store.task(task_id)["state"] == State.WAITING_INSTRUCTION:
                        self.store.halt(
                            task_id,
                            State.WAITING_INSTRUCTION,
                            Redactor().text(f"Instruction poll failed: {exc}"),
                        )
                    return
                finally:
                    background.reset(token)
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
            if (
                workflow.lease is None
                or not workflow.lease.acquired
                or time.time() < self.github.traffic.cooldown
            ):
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
                try:
                    result = await recovery.recover(task["id"])
                except (OSError, RuntimeError, ValueError) as exc:
                    # Lease acquisition can fail before Recovery's internal catch. Preserve
                    # existing leases/intents; never substitute a newly configured path.
                    self.store.halt(
                        task["id"],
                        State.RECONCILE,
                        Redactor().text(f"Recovery pending: {type(exc).__name__}: {exc}"),
                    )
                    result = {"recovered": False}
                task_event(
                    self.store,
                    task["id"],
                    "恢复完成" if result["recovered"] else "恢复待核对，保留原任务路径及现场",
                )
                progress(self.store, task["id"])
        discovery = Discovery(self.store, self.config, self.github)
        async with discovery.active(once=once):
            discovery.overview(once=once, config_path=self.config_path, jobs=self.concurrency)
            await self.schedule(once=once, poll=poll)

    async def schedule(self, *, once: bool, poll: float) -> None:
        pending: dict[int, asyncio.Task[None]] = {}
        group = None
        try:
            while True:
                for task_id, task_run in list(pending.items()):
                    if task_run.done():
                        task_run.result()
                        del pending[task_id]
                for task in self.store.tasks():
                    progress(self.store, task["id"])
                    if task["id"] not in pending:
                        pending[task["id"]] = asyncio.create_task(
                            self.advance(task["id"], immediate=once)
                        )
                if once:
                    group = asyncio.gather(*pending.values())
                    await asyncio.shield(group)
                    self.github.report()
                    return
                self.github.report()
                if not self.workflows and time.monotonic() - self.store.last_activity >= 300:
                    LOG.info(
                        "空闲心跳：已登记任务 %s，等待任务或 GitHub 指令", len(self.store.tasks())
                    )
                    self.store.last_activity = time.monotonic()
                await asyncio.sleep(poll)
        except BaseException:
            for workflow in self.workflows:
                if workflow.lease:
                    workflow.lease.lost = True
            for task_run in pending.values():
                task_run.cancel()
            closing = asyncio.gather(*pending.values(), return_exceptions=True)
            while not closing.done():
                try:
                    await asyncio.shield(closing)
                except asyncio.CancelledError:
                    continue
            closing.result()
            if group is not None:
                await asyncio.gather(group, return_exceptions=True)
            raise
