"""Foreground PR2 controller. GitHub facts and exact-version evidence own every gate."""

import asyncio
import json
from typing import Any

from .config import Config
from .control import Controls, InstructionChanged, Paused, baseline
from .events import Redactor
from .github import GitHub
from .leases import Lease
from .model import Role, Stage, State, same_version
from .quality import Quality, verdict
from .recovery import Recovery
from .remote import Controlled, UncertainWrite
from .runner import Runner
from .sandbox import IsolationError
from .store import Store


class Workflow:
    def __init__(self, store: Store, config: Config, github: GitHub):
        self.store, self.config, self.github = store, config, github
        self.runner = Runner(store, config, github)
        self.quality = Quality(store, config)
        self.remote = Controlled(store, config, github)
        self.lease: Lease | None = None
        self.watch_instructions = True

    async def sync(self, task_id: int) -> dict[str, Any]:
        task = self.store.task(task_id)
        await Recovery(self.store, self.github).sync(task)
        return self.store.task(task_id)

    async def confirm(self, expected: dict[str, Any]) -> dict[str, Any]:
        current = await self.sync(expected["id"])
        if not same_version(expected, current):
            raise UncertainWrite("Target changed; old evidence cannot authorize the new version")
        return self.store.guard(current)

    def safe(self, expected: dict[str, Any], *, complete: bool = False) -> dict[str, Any]:
        Controls(self.store).apply_pending(expected["id"], self.config, defer_checkpoint=complete)
        current = self.store.task(expected["id"])
        if baseline(current) != baseline(expected) or current["stage"] != expected["stage"]:
            raise InstructionChanged("New requirements must be evaluated before advancing")
        return self.store.guard(current)

    def cached_run(self, task: dict[str, Any], role: Role) -> dict[str, Any] | None:
        rows = [
            run
            for run in self.store.runs(task["id"])
            if run["role"] == role
            and run["state"] == State.COMPLETED
            and run["evidence_valid"]
            and run["target_sha"] == task["target_sha"]
            and run["result"] is not None
            and json.loads(run["result"]).get("target_sha") == task["target_sha"]
            and json.loads(run["result"]).get("conclusion") in {"ready", "revise"}
        ]
        return rows[-1] if rows else None

    async def agent(
        self, task: dict[str, Any], role: Role, evidence: dict[str, Any] | None = None
    ) -> dict[str, Any] | None:
        controls = Controls(self.store)
        await controls.poll(task["id"], self.config, self.github)
        if not controls.revalidate(task["id"], self.config):
            return None
        current = self.store.task(task["id"])
        if baseline(current) != baseline(task) or current["stage"] != task["stage"]:
            return None
        task = self.store.guard(task)
        cached = self.cached_run(task, role)
        if cached is not None:
            return cached
        if role == Role.DEVELOPER:
            prior = self.store.runs(task["id"])
            if (
                prior
                and prior[-1]["role"] == Role.DEVELOPER
                and prior[-1]["target_sha"] == task["target_sha"]
                and prior[-1]["details"].get("save", {}).get("state")
                not in {"confirmed", "unchanged"}
            ):
                await self.remote.checkpoint(task, prior[-1])
        if task["state"] != State.QUEUED:
            self.store.transition(
                self.safe(task), Stage(task["stage"]), State.QUEUED, "Agent dependencies satisfied"
            )
        run_id = await self.runner.run(task["id"], evidence, expected_task=task)
        if role == Role.DEVELOPER:
            settled = next(r for r in self.store.runs(task["id"]) if r["id"] == run_id)
            current = self.store.task(task["id"])
            if current["state"] != State.RECONCILE and (
                not settled["result"]
                or json.loads(settled["result"])["conclusion"] != "ready"
                or current["state"] == State.WAITING_INSTRUCTION
            ):
                try:
                    await self.remote.checkpoint(current, settled)
                except Exception as exc:
                    self.store.run_details(run_id, save_error=Redactor().text(str(exc)))
                    raise
        await controls.poll(task["id"], self.config, self.github)
        controls.revalidate(task["id"], self.config)
        current = self.store.task(task["id"])
        if current["state"] in {
            State.HUMAN,
            State.RECONCILE,
            State.FAILED,
            State.CANCELLED,
            State.WAITING_ENVIRONMENT,
            State.WAITING_INSTRUCTION,
        }:
            return None
        return self.cached_run(current, role)

    def revision(self, task: dict[str, Any], findings: dict[str, Any]) -> None:
        task = self.safe(task, complete=True)
        if task["revision_count"] >= self.config.max_revisions:
            self.store.transition(
                self.safe(task),
                Stage(task["stage"]),
                State.HUMAN,
                "Automatic revision limit reached",
            )
            return
        self.store.record(
            task, "revision", self.config.policy_hash, findings | {"target_sha": task["target_sha"]}
        )
        self.store.transition(
            self.safe(task),
            Stage.REVISION,
            State.QUEUED,
            "Confirmed findings require revision",
            revision=True,
        )

    async def step(self, task: dict[str, Any]) -> None:
        stage = Stage(task["stage"])
        checks: dict[str, Any] | None = None
        if stage == Stage.ANALYSIS:
            run = await self.agent(task, Role.ANALYST)
            current = self.store.task(task["id"])
            if run and current["pr_number"]:
                self.store.transition(
                    self.safe(current, complete=True),
                    Stage.REVIEW,
                    State.QUEUED,
                    "Existing PR is ready for independent review",
                )
            return
        if stage in {Stage.DEVELOPMENT, Stage.REVISION}:
            findings = (
                self.store.artifact(task["id"], "revision", self.config.policy_hash)
                if stage == Stage.REVISION
                else None
            )
            run = await self.agent(task, Role.DEVELOPER, findings)
            if run is None:
                return
            current = self.store.task(task["id"])
            snapshot, number = await self.remote.publish(current, run)
            if snapshot.get("head_sha") is None or snapshot["state"] != "open":
                raise UncertainWrite("Published PR is not open at a confirmed head")
            self.store.transition(
                self.safe(current, complete=True),
                Stage.REVIEW,
                State.QUEUED,
                "Controller commit and PR confirmed on GitHub",
                snapshot=snapshot,
                pr_number=number,
            )
            return
        if stage == Stage.REVIEW:
            if self.cached_run(task, Role.ANALYST) is None:
                self.store.transition(
                    self.safe(task),
                    Stage.ANALYSIS,
                    State.QUEUED,
                    "Reassess current Issue and repository requirements at PR head",
                )
                return
            checks = await self.quality.run(task)
            if verdict(checks, include_e2e=False) == "blocked":
                self.store.halt(
                    task["id"], State.WAITING_ENVIRONMENT, "Required plan checks are blocked"
                )
                return
            if verdict(checks, include_e2e=False) == "failed":
                self.revision(task, checks)
                return
            run = await self.agent(task, Role.REVIEWER, checks)
            if run is None:
                return
            current = await self.confirm(task)
            result = json.loads(run["result"])
            await self.remote.review(current, result, run["id"])
            current = await self.confirm(task)
            if self.cached_run(current, Role.REVIEWER) is None:
                raise UncertainWrite("Review evidence became invalid during publication")
            if result["conclusion"] == "revise":
                self.revision(current, result)
            elif result["conclusion"] == "ready":
                self.store.transition(
                    self.safe(current, complete=True),
                    Stage.VALIDATION,
                    State.QUEUED,
                    "Independent review for current SHA recorded",
                )
            return
        if stage in {Stage.VALIDATION, Stage.MERGEABLE}:
            review = self.cached_run(task, Role.REVIEWER)
            plan = await self.quality.plan(task)
            current = self.store.task(task["id"])
            if current["stage"] != stage:
                return
            checks = self.store.artifact(task["id"], "quality-results", plan["plan_hash"])
            review = self.cached_run(task, Role.REVIEWER)
            if (
                review is None
                or json.loads(review["result"])["conclusion"] != "ready"
                or not checks
                or verdict(checks, include_e2e=False) != "passed"
            ):
                self.store.transition(
                    self.safe(task),
                    Stage.REVIEW,
                    State.QUEUED,
                    "Current-version review/check evidence is missing",
                )
                return
            evidence = await self.quality.run(task, include_e2e=True)
            status = verdict(evidence)
            if status == "failed":
                self.revision(task, evidence)
                return
            if status == "blocked":
                self.store.halt(
                    task["id"],
                    State.WAITING_ENVIRONMENT,
                    "Required E2E/environment evidence is blocked",
                )
                return
            run = await self.agent(task, Role.VALIDATOR, evidence)
            if run is None:
                return
            current = await self.confirm(task)
            result = json.loads(run["result"])
            if result["conclusion"] == "revise":
                self.revision(current, result)
                return
            if result["conclusion"] != "ready":
                return
            await self.remote.ready(current)
            current = await self.confirm(task)
            if self.cached_run(current, Role.VALIDATOR) is None:
                raise UncertainWrite("Validation evidence became invalid during readiness update")
            final = await self.github.gates(current)
            current = await self.confirm(task)
            state, reason = State.COMPLETED, "Current plan passed; ready for human merge"
            if (
                final["headRefOid"] != current["target_sha"]
                or final["reviewDecision"] not in {"", "APPROVED"}
                or final["mergeable"] != "MERGEABLE"
                or final["mergeStateStatus"] != "CLEAN"
                or final["isDraft"]
            ):
                state, reason = (
                    State.WAITING_DEPENDENCY,
                    "GitHub review/merge protection gates are not satisfied",
                )
            self.store.record(
                current,
                "validation",
                self.config.policy_hash,
                {
                    "target_sha": current["target_sha"],
                    "plan_hash": evidence["plan_hash"],
                    "result": result,
                    "github": final,
                },
            )
            self.store.transition(
                self.safe(current, complete=True),
                Stage.MERGEABLE if state == State.COMPLETED else Stage.VALIDATION,
                state,
                "Ready for human merge" if state == State.COMPLETED else reason,
            )

    async def run(self, task_id: int) -> list[str]:
        try:
            if self.watch_instructions:
                async with Controls(self.store).listen(self.config, self.github, task_id):
                    if self.store.task(task_id)["state"] == State.WAITING_INSTRUCTION:
                        await Controls(self.store).poll(task_id, self.config, self.github)
                    return await self.execute(task_id)
            return await self.execute(task_id)
        finally:
            from .discovery import Discovery

            await Discovery(self.store, self.config, self.github).handoff(task_id)

    async def execute(self, task_id: int) -> list[str]:
        if self.store.task(task_id)["state"] == State.WAITING_INSTRUCTION:
            return []
        async with Lease(self.store, task_id) as lease:
            self.lease = lease
            if not lease.acquired:
                return []
            before = {run["id"] for run in self.store.runs(task_id)}
            try:
                controls = Controls(self.store)
                for _ in range(4 * self.config.max_revisions + 10):
                    task = await self.sync(task_id)
                    await controls.poll(task_id, self.config, self.github)
                    if not controls.revalidate(task_id, self.config):
                        break
                    task = self.store.task(task_id)
                    if (
                        task["state"]
                        in {State.RUNNING, State.HUMAN, State.RECONCILE, State.CANCELLED}
                        or task["stage"] == Stage.MERGED
                    ):
                        break
                    blockers = [
                        d["id"]
                        for d in self.store.dependencies(task_id)
                        if d["stage"] != Stage.MERGED
                    ]
                    if blockers and not task["cancel_requested"]:
                        self.store.halt(
                            task_id,
                            State.WAITING_DEPENDENCY,
                            f"Waiting for merged dependencies: {blockers}",
                        )
                        break
                    lease.bind_resource()
                    policy = self.store.artifact(task_id, "policy", "")
                    if policy and policy["hash"] != self.config.policy_hash:
                        self.store.transition(
                            self.safe(task),
                            Stage.REVIEW if task["pr_number"] else Stage.ANALYSIS,
                            State.QUEUED,
                            "Quality policy changed; evidence must be rebuilt",
                            invalidate=True,
                        )
                        task = self.store.task(task_id)
                    if not policy or policy["hash"] != self.config.policy_hash:
                        self.store.record(task, "policy", "", {"hash": self.config.policy_hash})
                    await self.step(task)
                    await controls.poll(task_id, self.config, self.github)
                    controls.checkpoint(task_id)
                    if self.store.task(task_id)["state"] != State.QUEUED:
                        break
                else:
                    self.store.halt(
                        task_id,
                        State.HUMAN,
                        "No bounded workflow progress; manual handling required",
                    )
            except asyncio.CancelledError:
                if lease.lost:
                    self.store.halt(task_id, State.RECONCILE, "Execution lease lost")
                else:
                    self.store.cancel(task_id)
                    self.store.halt(task_id, State.CANCELLED, "Cancelled by user")
            except (Paused, InstructionChanged):
                Controls(self.store).checkpoint(task_id)
            except Exception as exc:
                if self.store.task(task_id)["stage"] == Stage.MERGED:
                    return [
                        run["id"] for run in self.store.runs(task_id) if run["id"] not in before
                    ]
                state = (
                    State.RECONCILE
                    if isinstance(exc, UncertainWrite)
                    else (
                        State.WAITING_ENVIRONMENT
                        if isinstance(exc, (IsolationError, OSError))
                        else State.HUMAN
                    )
                )
                self.store.halt(task_id, state, Redactor().text(f"{type(exc).__name__}: {exc}"))
            return [run["id"] for run in self.store.runs(task_id) if run["id"] not in before]
