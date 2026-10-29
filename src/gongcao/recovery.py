"""Read-only reconciliation of interrupted work. Unconfirmed effects are never replayed."""

import hashlib
import json
import time
from pathlib import Path
from typing import Any
from urllib.parse import urlencode

from .control import Controls, InstructionChanged
from .events import Redactor
from .github import GitHub, Target, command
from .leases import Lease, identity, session_alive
from .model import AgentResult, Stage, State
from .store import Store
from .workspace import repository


class Recovery:
    def __init__(self, store: Store, github: GitHub):
        self.store, self.github = store, github

    async def default_base(self, task: dict[str, Any]) -> str:
        await repository(Path(task["repo_path"]), Target.parse(task["url"]))
        repo = task["snapshot"]["repository"]
        metadata = await self.github.read(f"repos/{repo}")
        ref = await self.github.read(f"repos/{repo}/git/ref/heads/{metadata['default_branch']}")
        sha: str = ref["object"]["sha"]
        try:
            await command("git", "cat-file", "-e", f"{sha}^{{commit}}", cwd=task["repo_path"])
        except RuntimeError:
            await command("git", "fetch", "origin", sha, cwd=task["repo_path"])
        return sha

    async def sync(self, task: dict[str, Any]) -> dict[str, Any]:
        """Discovery baselines are remote facts, including immediately before writes."""
        snapshot = await self.github.task_snapshot(task)
        self.store.sync(task["id"], snapshot)
        if snapshot.get("state") != "open" or snapshot.get("merged"):
            return snapshot
        row = self.store.db.execute(
            "SELECT data FROM claims WHERE task_id=?", (task["id"],)
        ).fetchone()
        if row:
            data = json.loads(row["data"])
            sha = await self.default_base(task)
            if sha != data["base_sha"]:
                if task["pr_number"] or self.store.evidence(task["id"])["operations"]:
                    self.store.halt(
                        task["id"],
                        State.RECONCILE,
                        "Default branch changed after remote intent/publication; "
                        "manual reconciliation required",
                    )
                else:
                    with self.store.db:
                        self.store.db.execute("BEGIN IMMEDIATE")
                        self.store.refresh_base(task["id"], sha)
                raise InstructionChanged("Default branch changed; previous evidence cannot advance")
        return snapshot

    async def observe(self, task: dict[str, Any], op: dict[str, Any]) -> dict[str, Any] | None:
        payload = op["payload"]
        repo = task["snapshot"]["repository"]
        if op["kind"] == "archive-link":
            from .archive import observe_link

            return await observe_link(payload, self.github)
        if op["kind"] == "archive":
            from .archive import observe

            return await observe(task, payload, self.github)
        if op["kind"] in {"push", "checkpoint"}:
            refs = (
                await command(
                    "git",
                    "ls-remote",
                    "origin",
                    f"refs/heads/{payload['branch']}",
                    cwd=task["repo_path"],
                )
            ).split()
            return payload if refs and refs[0] == payload["sha"] else None
        if op["kind"] == "pull":
            query = urlencode(
                {"state": "all", "head": f"{repo.split('/')[0]}:{payload['head']}", "per_page": 100}
            )
            rows = await self.github.pages(f"repos/{repo}/pulls?{query}")
            rows = [
                r
                for r in rows
                if r.get("body") == payload["body"]
                and r.get("title") == payload["title"]
                and r["base"]["ref"] == payload["base"]
            ]
            pushes = [
                o
                for o in self.store.evidence(task["id"])["operations"]
                if o["kind"] == "push"
                and o["state"] == "succeeded"
                and o["payload"]["branch"] == payload["head"]
            ]
            if (
                len(rows) != 1
                or not pushes
                or rows[0]["head"]["sha"] != pushes[-1]["payload"]["sha"]
            ):
                return None
            return {"number": rows[0]["number"]}
        if not task["pr_number"]:
            return None
        if op["kind"] == "review":
            rows = await self.github.pages(
                f"repos/{repo}/pulls/{task['pr_number']}/reviews?per_page=100"
            )
            rows = [
                r
                for r in rows
                if r.get("body") == payload["body"]
                and r["commit_id"] == payload["commit_id"]
                and r["state"] == "COMMENTED"
            ]
            return {"id": rows[0]["id"]} if len(rows) == 1 else None
        if op["kind"] == "ready":
            snapshot = await self.github.task_snapshot(task)
            if snapshot.get("head_sha") == payload["sha"] and not snapshot["draft"]:
                return {"ready": True}
        return None

    async def recover(self, task_id: int) -> dict[str, Any]:
        async with Lease(self.store, task_id, recovery=True) as lease:
            if not lease.acquired:
                return {
                    "task_id": task_id,
                    "recovered": False,
                    "reason": "Task or resource is occupied",
                }
            try:
                return await self.reconcile(task_id, lease.owner)
            except (OSError, RuntimeError, ValueError) as exc:
                message = Redactor().text(f"{type(exc).__name__}: {exc}")
                self.store.halt(task_id, State.RECONCILE, message)
                return {"task_id": task_id, "recovered": False, "reason": message}

    async def reconcile(self, task_id: int, owner: str) -> dict[str, Any]:
        task = self.store.task(task_id)
        records = self.store.db.execute(
            "SELECT * FROM processes WHERE task_id=? AND owner!=? AND state!='stopped'",
            (task_id, owner),
        ).fetchall()
        boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
        for row in records:
            if row["identity"] and row["identity"].split(":")[0] != boot:
                continue
            if row["state"] == "uncertain":
                raise ValueError(
                    "Descendant cleanup is unconfirmed; same-boot recovery is disabled"
                )
            if row["label"] != "pid-sandbox" or row["pid"] is None or session_alive(row["pid"]):
                raise ValueError(
                    "Old process or unknown spawn remains; manual reconciliation required"
                )
        await repository(Path(task["repo_path"]), Target.parse(task["url"]))
        runs = self.store.runs(task_id)
        for run in runs:
            if run["state"] == State.COMPLETED and run["evidence_valid"]:
                try:
                    report = AgentResult.model_validate_json(run["result"] or "{}")
                    valid = report.target_sha == run["target_sha"] and report.conclusion in {
                        "ready",
                        "revise",
                    }
                except ValueError:
                    valid = False
                if not valid:
                    with self.store.db:
                        self.store.db.execute(
                            "UPDATE runs SET evidence_valid=0 WHERE id=?", (run["id"],)
                        )
                    run["evidence_valid"] = 0
            if run["state"] == State.RUNNING and run["owner_token"] is None:
                raise ValueError(
                    "Legacy active run has no process identity; cannot confirm cleanup"
                )
            workspace = run["worktree"]
            if workspace and not Path(workspace).resolve().is_relative_to(
                self.store.root / "worktrees"
            ):
                raise ValueError("Run workspace is outside the allocated root")
            if workspace and run["evidence_valid"] and not Path(workspace).is_dir():
                raise ValueError("Allocated run workspace is missing; manual inspection required")
            if workspace and run["evidence_valid"]:
                head = (await command("git", "rev-parse", "HEAD", cwd=workspace)).strip()
                parent = run["details"].get("source", {}).get("sha", run["target_sha"])
                if head != parent:
                    commit = (
                        await command("git", "show", "-s", "--format=%P%n%B", head, cwd=workspace)
                    ).splitlines()
                    if (
                        run["role"] != "developer"
                        or commit[0] != parent
                        or f"Gongcao-Run: {run['id']}" not in commit
                    ):
                        raise ValueError(
                            "Worktree HEAD is not the recorded target or controller commit"
                        )
            if run["context_hash"] and run["evidence_valid"]:
                path = self.store.root / "runs" / run["id"] / "context.json"
                digest = hashlib.sha256(
                    json.dumps(json.loads(path.read_text()), sort_keys=True).encode()
                ).hexdigest()
                if digest != run["context_hash"]:
                    raise ValueError("Stored session context does not match its recorded hash")
        evidence = self.store.evidence(task_id)
        for op in evidence["operations"]:
            if op["state"] != "succeeded":
                result = await self.observe(task, op)
                if result is None:
                    raise ValueError(f"Unconfirmed {op['kind']} intent; refusing replay")
                self.store.operation_result(op["id"], "succeeded", result)
            else:
                result = op["response"]
            if op["kind"] == "checkpoint":
                self.store.run_details(
                    op["payload"]["run_id"], save=op["payload"] | {"state": "confirmed"}
                )
            if op["kind"] == "pull" and not task["pr_number"]:
                with self.store.db:
                    self.store.db.execute(
                        "UPDATE tasks SET pr_number=? WHERE id=?", (result["number"], task_id)
                    )
                task = self.store.task(task_id)
        snapshot = await self.github.task_snapshot(task)
        if snapshot.get("head_sha"):
            await command("git", "fetch", "origin", snapshot["head_sha"], cwd=task["repo_path"])
        self.store.sync(task_id, snapshot)
        with self.store.db:
            self.store.db.execute("BEGIN IMMEDIATE")
            current = self.store.task(task_id)
            self.store.db.execute(
                "UPDATE processes SET state='stopped' WHERE task_id=? AND owner!=?",
                (task_id, owner),
            )
            self.store.db.execute(
                "UPDATE runs SET state=?,evidence_valid=0,ended=?,error=? "
                "WHERE task_id=? AND state=?",
                (
                    State.CANCELLED if current["cancel_requested"] else State.FAILED,
                    time.time(),
                    "Controller interrupted; session retained, never resumed",
                    task_id,
                    State.RUNNING,
                ),
            )
            if (
                current["state"] in {State.RUNNING, State.RECONCILE}
                and not current["cancel_requested"]
                and current["stage"] != Stage.MERGED
            ):
                self.store.db.execute(
                    "UPDATE tasks SET state=?,reason=?,updated=? WHERE id=?",
                    (
                        State.QUEUED,
                        "Interrupted work reconciled; fresh execution required",
                        time.time(),
                        task_id,
                    ),
                )
            Controls(self.store).checkpoint(task_id)
        return {
            "task_id": task_id,
            "recovered": True,
            "task": self.store.task(task_id),
            "sessions": [
                {"run_id": r["id"], "thread_id": r["thread_id"], "worktree": r["worktree"]}
                for r in runs
            ],
        }

    async def retry(
        self,
        task_id: int,
        *,
        reset_revisions: bool = False,
        refresh_base: bool = False,
    ) -> dict[str, Any]:
        result = await self.recover(task_id)
        if not result["recovered"]:
            return result
        async with Lease(self.store, task_id) as lease:
            if not lease.acquired:
                return {"task_id": task_id, "recovered": False, "reason": "Task is occupied"}
            task = self.store.task(task_id)
            refreshed_sha = task["target_sha"]
            if refresh_base:
                if task["pr_number"] or self.store.evidence(task_id)["operations"]:
                    raise ValueError(
                        "Only unpublished issues without remote intents can refresh their baseline"
                    )
                refreshed_sha = await self.default_base(task)
                self.store.sync(task_id, await self.github.task_snapshot(task))
                task = self.store.task(task_id)
            if (
                task["cancel_requested"]
                or task["snapshot"]["state"] != "open"
                or task["stage"] == Stage.MERGED
            ):
                raise ValueError("Closed, cancelled or merged tasks cannot be retried")
            self.reset_retry(task_id, refreshed_sha, reset_revisions=reset_revisions)
            return {"task_id": task_id, "recovered": True, "task": self.store.task(task_id)}

    def reset_retry(
        self, task_id: int, refreshed_sha: str, *, reset_revisions: bool = False
    ) -> None:
        """Caller holds the same lease throughout reconciliation and authorization."""
        task = self.store.task(task_id)
        with Controls(self.store).transaction():
            if refreshed_sha != task["target_sha"]:
                self.store.refresh_base(task_id, refreshed_sha)
            self.store.db.execute(
                "UPDATE runs SET evidence_valid=0 WHERE task_id=? AND "
                "(state!='completed' OR json_extract(result,'$.conclusion')!='ready' "
                "OR json_extract(result,'$.target_sha')!=target_sha "
                "OR role IN ('reviewer','validator'))",
                (task_id,),
            )
            self.store.db.execute(
                "UPDATE artifacts SET valid=0 WHERE task_id=? "
                "AND kind IN ('quality-results','validation')",
                (task_id,),
            )
            self.store.db.execute("DELETE FROM retries WHERE task_id=?", (task_id,))
            self.store.db.execute(
                "UPDATE tasks SET state=?,reason=?,revision_count=CASE WHEN ? THEN 0 "
                "ELSE revision_count END,updated=? WHERE id=? AND cancel_requested=0",
                (State.QUEUED, "Manual retry requested", reset_revisions, time.time(), task_id),
            )
            Controls(self.store).checkpoint(task_id)


def diagnose(store: Store, task_id: int) -> dict[str, Any]:
    task = store.task(task_id)
    lease = store.db.execute("SELECT * FROM leases WHERE task_id=?", (task_id,)).fetchone()
    runs = store.runs(task_id)
    retry = store.db.execute("SELECT * FROM retries WHERE task_id=?", (task_id,)).fetchone()
    issues = []
    if lease and identity(lease["pid"]) != lease["identity"]:
        issues.append("interrupted_controller")
    if any(o["state"] != "succeeded" for o in store.evidence(task_id)["operations"]):
        issues.append("unconfirmed_remote_write")
    if task["state"] == State.WAITING_ENVIRONMENT:
        issues.append("environment_unavailable")
    if runs and runs[-1]["state"] == State.RUNNING and not lease:
        issues.append("unowned_active_run")
    failures = [r for r in runs[-3:] if r["state"] == State.FAILED]
    if len(failures) >= 2 and len({r["error"] for r in failures}) == 1:
        issues.append("repeated_failure")
    if task["revision_count"]:
        issues.append("revision_budget_in_use")
    if lease and lease["expires"] < time.time():
        issues.append("lease_expired")
    if runs and "TimeoutError" in (runs[-1]["error"] or ""):
        issues.append("execution_deadline_exceeded")
    if "Three execution" in task["reason"] or "No bounded" in task["reason"]:
        issues.append("no_progress_after_bounded_attempts")
    if "no changes" in task["reason"].lower():
        issues.append("no_substantive_progress")
    if "Automatic revision limit" in task["reason"]:
        issues.append("revision_budget_exhausted")
    return {
        "task_id": task_id,
        "stage": task["stage"],
        "state": task["state"],
        "reason": task["reason"],
        "lease": dict(lease) if lease else None,
        "retry": dict(retry) if retry else None,
        "dependencies": store.dependencies(task_id),
        "processes": [
            dict(r)
            for r in store.db.execute(
                "SELECT * FROM processes WHERE task_id=? ORDER BY rowid DESC LIMIT 100", (task_id,)
            )
        ],
        "issues": issues,
        "note": "Log silence alone does not diagnose a stalled process",
    }
