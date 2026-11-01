"""Bounded, read-only advice for registered tasks; suggestions never authorize work."""

import asyncio
import fcntl
import hashlib
import json
import os
import time
import uuid
from pathlib import Path
from typing import Any

from .config import Config
from .control import Controls, baseline
from .events import Journal, Redactor
from .github import GitHub
from .leases import identity
from .model import CoordinationReport, Role, State
from .processes import observer
from .runner import Runner
from .sandbox import Sandbox
from .store import Store


class AdvisoryProcesses:
    """One durable reservation for the existing subprocess observer protocol."""

    lost = False

    def __init__(self, path: Path):
        self.path = path
        self.data: dict[str, Any] = {}

    @staticmethod
    def unresolved(path: Path) -> dict[str, Any] | None:
        if not path.exists():
            return None
        try:
            data = json.loads(path.read_text())
        except (ValueError, OSError):
            data = {"state": "unknown"}
        if isinstance(data, dict) and data.get("state") == "stopped":
            return None
        return (data or {"state": "unknown"}) if isinstance(data, dict) else {"state": "unknown"}

    def save(self, **values: Any) -> None:
        self.data.update(values)
        temporary = self.path.with_suffix(".tmp")
        temporary.write_text(json.dumps(self.data))
        temporary.replace(self.path)

    def intent(self, label: str) -> str:
        self.save(
            label=label,
            pid=None,
            owner_pid=os.getpid(),
            owner_identity=identity(os.getpid()),
            state="pending",
        )
        return label

    def attached(self, key: str, pid: int) -> None:
        self.save(pid=pid, identity=identity(pid), state="running")

    def aborted(self, key: str) -> None:
        self.save(state="stopped")

    def stopped(self, pid: int) -> None:
        self.save(state="stopped")

    def uncertain(self, pid: int) -> None:
        self.save(state="uncertain")


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
                "target_sha": r["target_sha"],
                "evidence_valid": bool(r["evidence_valid"]),
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
            {
                "kind": a["kind"],
                "sha": a["sha"],
                "id": a["id"],
                "checks": [
                    {
                        "category": item.get("category"),
                        "status": item.get("status"),
                        "reason": item.get("reason", "")[:200],
                    }
                    for item in a["data"].get("items", [])[:6]
                ],
            }
            for a in store.evidence(task_id)["artifacts"]
            if a["valid"]
            and a["sha"] == task["target_sha"]
            and a["kind"] in {"quality-results", "validation"}
        ][-4:],
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
        return result  # Only settled advice at current facts is reusable.
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
    if store.db.execute(
        "SELECT 1 FROM processes WHERE task_id=? AND state!='stopped' "
        "UNION SELECT 1 FROM operations WHERE task_id=? AND state!='succeeded'",
        (task_id, task_id),
    ).fetchone():
        return False
    dependencies = store.dependencies(task_id)
    conflict = any(word in task["reason"].casefold() for word in ("conflict", "冲突"))
    if conflict and (len(dependencies) > 1 or len(task["control"].get("feedback", [])) > 1):
        return True
    if task["state"] == State.WAITING_DEPENDENCY:
        return False
    runs = store.runs(task_id)[-3:]
    simple = any(
        word in (task["reason"] + " ".join(r["error"] or "" for r in runs)).casefold()
        for word in (
            "missing package",
            "missing acceptance",
            "authentication missing",
            "cleanup",
            "unconfirmed",
            "缺少制品",
            "缺少材料",
        )
    )
    return (
        not simple
        and len(runs) == 3
        and len({r["details"].get("source", {}).get("sha") for r in runs}) == 1
        and all(
            r["target_sha"] == task["target_sha"]
            and (
                r["state"] == State.FAILED
                or json.loads(r["result"] or "{}").get("conclusion") in {"blocked", "failed"}
            )
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
                "report": {
                    "facts": [
                        f"任务 {t['id']}：{t['stage']}/{t['state']}，SHA {t['target_sha']}"
                        for t in selected[:8]
                    ],
                    "blockers": [t["reason"][:1000] for t in selected[:8]],
                    "suggestions": [
                        {
                            "action": "人工核对合并/关闭结果"
                            if t["stage"] in {"mergeable", "merged"}
                            or t["snapshot"].get("state") != "open"
                            else "按所列原因补齐条件后发新 Step",
                            "owner": "任务所有者",
                            "inputs": [t["reason"][:1000]],
                        }
                        for t in selected[:8]
                    ],
                },
            }
        uncached = [t for t in candidates if current(self.store, t["id"]) is None]
        task = (uncached or candidates)[0]  # One session; changed sibling tasks do not starve.
        raw = facts(self.store, task["id"])
        data = Redactor().clean(raw)
        key = fingerprint(raw)
        with (self.store.root / "coordination.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return {"source": "controller", "status": "busy"}
            reservation = self.store.root / "coordination-process.json"
            if process := AdvisoryProcesses.unresolved(reservation):
                return {
                    "source": "controller",
                    "status": "needs_reconciliation",
                    "process": process,
                    "suggestion": "协调子进程清理不明，需人工核对；保留占用。",
                }
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
                "run_dir": str(run_dir),
                "requested_execution": self.config.execution,
            }

            journal = Journal(
                self.store, run_dir.name, self.config.max_log_bytes, Redactor(), local=True
            )
            token = observer.set(AdvisoryProcesses(reservation))
            started = time.monotonic()
            try:
                sandbox = Sandbox(workspace, run_dir, Role.REVIEWER)
                journal.redactor = Redactor(sandbox.prepare(self.config))
                journal.emit("isolation_verified", await sandbox.verify(Path(task["repo_path"])))
                if fingerprint(facts(self.store, task["id"])) != key:
                    result["status"] = "stale"
                    return result
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
                with Controls(self.store).transaction():
                    if fingerprint(facts(self.store, task["id"])) != key:
                        result["status"] = "stale"
                    else:
                        self.store.db.execute(
                            "UPDATE artifacts SET valid=0 WHERE task_id=? AND kind='coordination'",
                            (task["id"],),
                        )
                        self.store.db.execute(
                            "INSERT INTO artifacts(task_id,sha,kind,policy,data) VALUES(?,?,?,?,?)",
                            (
                                task["id"],
                                task["target_sha"],
                                "coordination",
                                key,
                                json.dumps(result),
                            ),
                        )
                        self.store.progress(task["id"])
                (run_dir / "result.json").write_text(
                    json.dumps(result, ensure_ascii=False, indent=2)
                )
            return result
