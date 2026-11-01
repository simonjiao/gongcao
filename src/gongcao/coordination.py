"""Bounded, read-only advice for registered tasks; suggestions never authorize work."""

import asyncio
import fcntl
import hashlib
import json
import time
import uuid
from pathlib import Path
from typing import Any

from .config import Config
from .control import Controls, baseline
from .events import Journal, Redactor
from .github import GitHub
from .model import CoordinationReport, Role, State
from .processes import observer
from .runner import Runner
from .sandbox import Sandbox
from .store import Store


def facts(store: Store, task_id: int) -> dict[str, Any]:
    task = store.task(task_id)
    runs = store.runs(task_id)[-3:]
    dependencies = [
        d | {"sha": store.task(d["id"])["target_sha"], "request": baseline(store.task(d["id"]))}
        for d in store.dependencies(task_id)
    ]
    return {
        "task": task_id,
        "stage": task["stage"],
        "state": task["state"],
        "sha": task["target_sha"],
        "request": baseline(task),
        "policy": task["control"].get("policy"),
        "reason": task["reason"][:2000],
        "dependencies": [d | {"reason": d["reason"][:500]} for d in dependencies[:24]],
        "dependency_version": fingerprint({"dependencies": dependencies}),
        "more_dependencies": max(0, len(dependencies) - 24),
        "runs": [
            {
                "id": r["id"],
                "role": r["role"],
                "state": r["state"],
                "source": r["details"].get("source", {}).get("sha"),
                "summary": (json.loads(r["result"] or "{}").get("summary") or r["error"] or "")[
                    :1200
                ],
            }
            for r in runs
        ],
        "event": store.db.execute(
            "SELECT COALESCE(MAX(e.id),0) FROM events e "
            "JOIN runs r ON r.id=e.run_id WHERE r.task_id=?",
            (task_id,),
        ).fetchone()[0],
        "evidence": [
            {"kind": a["kind"], "sha": a["sha"], "id": a["id"]}
            for a in store.evidence(task_id)["artifacts"]
            if a["valid"] and a["kind"] in {"quality-results", "validation"}
        ],
    }


def fingerprint(data: dict[str, Any]) -> str:
    return hashlib.sha256(json.dumps(data, sort_keys=True).encode()).hexdigest()


def current(store: Store, task_id: int) -> dict[str, Any] | None:
    row = store.db.execute(
        "SELECT data FROM artifacts WHERE task_id=? AND kind='coordination' "
        "AND valid=1 ORDER BY id DESC LIMIT 1",
        (task_id,),
    ).fetchone()
    result: dict[str, Any] | None = json.loads(row[0]) if row else None
    if result and result["fingerprint"] == fingerprint(facts(store, task_id)):
        return result  # All other versions remain historical advice, never current evidence.
    return None


def complex_block(store: Store, task_id: int) -> bool:
    task = store.task(task_id)
    if task["state"] not in {
        State.HUMAN,
        State.FAILED,
        State.WAITING_ENVIRONMENT,
        State.WAITING_DEPENDENCY,
    }:
        return False
    if task["cancel_requested"] or task["snapshot"].get("state") != "open":
        return False
    if store.db.execute("SELECT 1 FROM leases WHERE task_id=?", (task_id,)).fetchone():
        return False
    dependencies = store.dependencies(task_id)
    conflict = any(word in task["reason"].casefold() for word in ("conflict", "冲突"))
    if conflict and (len(dependencies) > 1 or len(task["control"].get("feedback", [])) > 1):
        return True
    runs = store.runs(task_id)[-3:]
    return (
        len(runs) == 3
        and len({r["details"].get("source", {}).get("sha") for r in runs}) == 1
        and all(
            r["target_sha"] == task["target_sha"]
            and json.loads(r["result"] or "{}").get("conclusion") in {"blocked", "failed"}
            for r in runs
        )
    )


class Coordinator:
    def __init__(self, store: Store, config: Config, github: GitHub):
        self.store, self.config, self.github = store, config, github

    async def run(self, task_id: int | None = None) -> dict[str, Any]:
        selected = [self.store.task(task_id)] if task_id is not None else self.store.tasks()
        candidates = [t for t in selected if complex_block(self.store, t["id"])]
        if not candidates:
            return {
                "source": "controller",
                "status": "no_complex_block",
                "tasks": [t["id"] for t in selected],
                "suggestion": "补齐所列材料或等待依赖/检查，随后发新的 /gongcao step。",
            }
        task = candidates[0]  # At most one advisory session per invocation/event.
        raw = facts(self.store, task["id"])
        data = Redactor().clean(raw)
        key = fingerprint(raw)
        with (self.store.root / "coordination.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return {"source": "controller", "status": "busy"}
            previous = current(self.store, task["id"])
            if previous:
                return previous  # Failed/interrupted analyses also do not loop on the same facts.
            run_dir = self.store.root / "coordination" / uuid.uuid4().hex
            workspace = run_dir / "workspace"
            workspace.mkdir(parents=True, mode=0o700)
            (workspace / ".git").touch()  # Same masked .git mount as other read-only workers.
            result: dict[str, Any] = {
                "source": "coordinator",
                "fingerprint": key,
                "binding": {k: raw[k] for k in ("task", "stage", "sha", "request")},
                "status": "running",
                "run_dir": str(run_dir),
                "requested_execution": self.config.execution,
            }

            def save() -> None:
                with Controls(self.store).transaction():
                    if fingerprint(facts(self.store, task["id"])) != key:
                        result["status"] = "stale"
                        return
                    self.store.db.execute(
                        "UPDATE artifacts SET valid=0 WHERE task_id=? AND kind='coordination'",
                        (task["id"],),
                    )
                    self.store.db.execute(
                        "INSERT INTO artifacts(task_id,sha,kind,policy,data) VALUES(?,?,?,?,?)",
                        (task["id"], task["target_sha"], "coordination", key, json.dumps(result)),
                    )
                    if result["status"] != "running":
                        self.store.progress(task["id"])

            save()
            journal = Journal(
                self.store, run_dir.name, self.config.max_log_bytes, Redactor(), local=True
            )
            token = observer.set(None)  # Never attach advice subprocesses to another task's lease.
            started = time.monotonic()
            try:
                sandbox = Sandbox(workspace, run_dir, Role.REVIEWER)
                journal.redactor = Redactor(sandbox.prepare(self.config))
                journal.emit("isolation_verified", await sandbox.verify(Path(task["repo_path"])))
                context = {"role": "coordinator", "facts": data, "fingerprint": key}
                (run_dir / "context.json").write_text(json.dumps(context, ensure_ascii=False))
                report = await Runner(self.store, self.config, self.github).session(
                    sandbox, context, journal
                )
                if not isinstance(report, CoordinationReport):
                    raise ValueError("Coordination requires an advisory report")
                if journal.execution is None or journal.thread_id is None:
                    raise ValueError(
                        "Coordination requires actual SDK session/model acknowledgement"
                    )
                result.update(
                    status="completed",
                    report=journal.redactor.clean(report.model_dump()),
                    execution=journal.execution,
                    thread_id=journal.thread_id,
                )
            except asyncio.CancelledError:
                result.update(status="cancelled", reason="协调分析已取消，业务任务保持原状")
                raise
            except Exception as exc:
                result.update(
                    status="failed", reason=journal.redactor.text(f"{type(exc).__name__}: {exc}")
                )
            finally:
                observer.reset(token)
                result["duration_seconds"] = round(time.monotonic() - started, 3)
                save()
                (run_dir / "result.json").write_text(
                    json.dumps(result, ensure_ascii=False, indent=2)
                )
            return result
