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
from .quality import Quality, ci_gate
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
        self.store.sync(task_id, await self.github.task_snapshot(task))
        return self.store.task(task_id)

    async def confirm(self, expected: dict[str, Any]) -> dict[str, Any]:
        current = await self.sync(expected["id"])
        if not same_version(expected, current):
            raise UncertainWrite("Target changed; old evidence cannot authorize the new version")
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
        if task["state"] != State.QUEUED:
            self.store.transition(
                task, Stage(task["stage"]), State.QUEUED, "Agent dependencies satisfied"
            )
        await self.runner.run(task["id"], evidence, expected_task=task)
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
        if task["revision_count"] >= self.config.max_revisions:
            self.store.transition(
                task, Stage(task["stage"]), State.HUMAN, "Automatic revision limit reached"
            )
            return
        self.store.record(
            task, "revision", self.config.policy_hash, findings | {"target_sha": task["target_sha"]}
        )
        self.store.transition(
            task, Stage.REVISION, State.QUEUED, "Confirmed findings require revision", revision=True
        )

    async def step(self, task: dict[str, Any]) -> None:
        stage = Stage(task["stage"])
        checks: dict[str, Any] | None = None
        if stage == Stage.ANALYSIS:
            run = await self.agent(task, Role.ANALYST)
            current = self.store.task(task["id"])
            if run and current["pr_number"]:
                self.store.transition(
                    current,
                    Stage.REVIEW,
                    State.QUEUED,
                    "Existing PR is ready for independent review",
                )
            return
        if (
            not self.config.checks
            or not self.config.ci_workflows
            or (self.config.require_real_checks and not self.config.real_checks)
        ):
            self.store.transition(
                task,
                stage,
                State.WAITING_ENVIRONMENT,
                "Configure target-project checks, CI workflows and required real checks",
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
                current,
                Stage.REVIEW,
                State.QUEUED,
                "Controller commit and PR confirmed on GitHub",
                snapshot=snapshot,
                pr_number=number,
            )
            return
        if stage == Stage.REVIEW:
            checks = await self.quality.run(task, "checks")
            if not checks["passed"]:
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
                    current,
                    Stage.VALIDATION,
                    State.QUEUED,
                    "Independent review for current SHA recorded",
                )
            return
        if stage in {Stage.VALIDATION, Stage.MERGEABLE}:
            review = self.cached_run(task, Role.REVIEWER)
            checks = self.store.artifact(task["id"], "checks", self.config.policy_hash)
            if (
                review is None
                or json.loads(review["result"])["conclusion"] != "ready"
                or not checks
                or not checks["passed"]
            ):
                self.store.transition(
                    task,
                    Stage.REVIEW,
                    State.QUEUED,
                    "Current-version review/check evidence is missing",
                )
                return
            facts = await self.github.gates(task)
            state, reason = ci_gate(task, facts, self.config.ci_workflows)
            if state == State.FAILED:
                self.revision(task, {"conclusion": "revise", "summary": reason, "ci": facts})
                return
            if state != State.COMPLETED:
                self.store.transition(task, Stage.VALIDATION, state, reason)
                return
            evidence = {"checks": checks, "ci": facts}
            if self.config.real_checks:
                real = await self.quality.run(task, "real")
                if not real["passed"]:
                    self.revision(task, real)
                    return
                evidence["real"] = real
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
            state, reason = ci_gate(current, final, self.config.ci_workflows)
            if state == State.COMPLETED and (
                final["reviewDecision"] not in {"", "APPROVED"}
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
                {"target_sha": current["target_sha"], "result": result, "github": final},
            )
            self.store.transition(
                current,
                Stage.MERGEABLE if state == State.COMPLETED else Stage.VALIDATION,
                state,
                "Ready for human merge" if state == State.COMPLETED else reason,
            )

    async def run(self, task_id: int) -> list[str]:
        if self.watch_instructions:
            async with Controls(self.store).listen(self.config, self.github, task_id):
                await Controls(self.store).poll(task_id, self.config, self.github)
                return await self.execute(task_id)
        return await self.execute(task_id)

    async def execute(self, task_id: int) -> list[str]:
        if self.store.task(task_id)["state"] == State.WAITING_INSTRUCTION:
            return []
        async with Lease(self.store, task_id) as lease:
            self.lease = lease
            if not lease.acquired:
                return []
            before = {run["id"] for run in self.store.runs(task_id)}
            try:
                task = await self.sync(task_id)
                controls = Controls(self.store)
                await controls.poll(task_id, self.config, self.github)
                if not controls.revalidate(task_id, self.config):
                    return []
                task = self.store.task(task_id)
                if (
                    task["state"] in {State.RUNNING, State.HUMAN, State.RECONCILE, State.CANCELLED}
                    or task["stage"] == Stage.MERGED
                ):
                    return []
                blockers = [
                    d["id"] for d in self.store.dependencies(task_id) if d["stage"] != Stage.MERGED
                ]
                if blockers and task["stage"] != Stage.MERGED and not task["cancel_requested"]:
                    self.store.halt(
                        task_id,
                        State.WAITING_DEPENDENCY,
                        f"Waiting for merged dependencies: {blockers}",
                    )
                    return []
                for _ in range(2 * self.config.max_revisions + 8):
                    lease.bind_resource()
                    task = await self.sync(task_id)
                    controls = Controls(self.store)
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
                    policy = self.store.artifact(task_id, "policy", "")
                    if policy and policy["hash"] != self.config.policy_hash:
                        self.store.transition(
                            task,
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
