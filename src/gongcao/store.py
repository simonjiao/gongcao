"""Transactional local task and execution records. GitHub facts remain snapshots."""

import json
import os
import sqlite3
import time
import uuid
from pathlib import Path
from typing import Any

from .model import VERSION_FIELDS, Role, Stage, State


class Store:
    def __init__(self, root: Path):
        self.root = root.resolve()
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.db = sqlite3.connect(self.root / "gongcao.sqlite3", timeout=10)
        self.db.row_factory = sqlite3.Row
        self.owners: dict[int, str] = {}
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA foreign_keys=ON")
        if self.db.execute("PRAGMA user_version").fetchone()[0] > 2:
            self.db.close()
            raise ValueError("Database schema is newer than this Gongcao version")
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS tasks (
                id INTEGER PRIMARY KEY, url TEXT UNIQUE NOT NULL, repo_path TEXT NOT NULL,
                stage TEXT NOT NULL, state TEXT NOT NULL, target_sha TEXT NOT NULL,
                snapshot TEXT NOT NULL, reason TEXT NOT NULL DEFAULT '',
                cancel_requested INTEGER NOT NULL DEFAULT 0, updated REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS runs (
                id TEXT PRIMARY KEY, task_id INTEGER NOT NULL REFERENCES tasks(id),
                role TEXT NOT NULL, state TEXT NOT NULL, target_sha TEXT NOT NULL,
                thread_id TEXT, worktree TEXT, context_hash TEXT, result TEXT,
                error TEXT, owner_pid INTEGER NOT NULL, started REAL NOT NULL, ended REAL,
                evidence_valid INTEGER NOT NULL DEFAULT 1
            );
            CREATE UNIQUE INDEX IF NOT EXISTS one_active_run ON runs(task_id)
                WHERE state = 'running';
            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(id),
                at REAL NOT NULL, kind TEXT NOT NULL, summary TEXT NOT NULL
            );
        """)
        with self.db:
            self.db.execute("BEGIN IMMEDIATE")
            if self.db.execute("PRAGMA user_version").fetchone()[0] == 0:
                self.db.execute("ALTER TABLE tasks ADD COLUMN pr_number INTEGER")
                self.db.execute(
                    "ALTER TABLE tasks ADD COLUMN revision_count INTEGER NOT NULL DEFAULT 0"
                )
                self.db.execute(
                    "UPDATE tasks SET pr_number=json_extract(snapshot,'$.number') "
                    "WHERE json_extract(snapshot,'$.kind')='pull'"
                )
                self.db.execute(
                    "CREATE TABLE artifacts (id INTEGER PRIMARY KEY, task_id INTEGER "
                    "NOT NULL REFERENCES tasks(id), sha TEXT NOT NULL, kind TEXT NOT NULL, "
                    "policy TEXT NOT NULL, data TEXT NOT NULL, valid INTEGER NOT NULL DEFAULT 1)"
                )
                self.db.execute(
                    "CREATE TABLE operations (id TEXT PRIMARY KEY, task_id INTEGER NOT NULL "
                    "REFERENCES tasks(id), sha TEXT NOT NULL, kind TEXT NOT NULL, "
                    "payload TEXT NOT NULL, state TEXT NOT NULL, response TEXT)"
                )
                self.db.execute("PRAGMA user_version=1")
            if self.db.execute("PRAGMA user_version").fetchone()[0] == 1:
                self.db.execute("ALTER TABLE runs ADD COLUMN owner_token TEXT")
                for statement in (
                    "CREATE TABLE leases (task_id INTEGER PRIMARY KEY REFERENCES tasks(id), "
                    "owner TEXT NOT NULL, pid INTEGER NOT NULL, identity TEXT NOT NULL, "
                    "resource TEXT NOT NULL UNIQUE, object TEXT NOT NULL UNIQUE, "
                    "expires REAL NOT NULL)",
                    "CREATE TABLE processes (id TEXT PRIMARY KEY, task_id INTEGER NOT NULL "
                    "REFERENCES tasks(id), owner TEXT NOT NULL, label TEXT NOT NULL, "
                    "pid INTEGER, identity TEXT, state TEXT NOT NULL)",
                    "CREATE TABLE dependencies (task_id INTEGER REFERENCES tasks(id), "
                    "requires INTEGER REFERENCES tasks(id), PRIMARY KEY(task_id,requires))",
                    "CREATE TABLE retries (task_id INTEGER PRIMARY KEY REFERENCES tasks(id), "
                    "failures INTEGER NOT NULL DEFAULT 0, fingerprint TEXT NOT NULL DEFAULT '', "
                    "next_at REAL NOT NULL DEFAULT 0)",
                    "CREATE INDEX events_run_kind ON events(run_id,kind,id)",
                    "CREATE INDEX processes_task_state ON processes(task_id,state)",
                ):
                    self.db.execute(statement)
                self.db.execute("PRAGMA user_version=2")

    def close(self) -> None:
        self.db.close()

    def task(self, task_id: int) -> dict[str, Any]:
        row = self.db.execute("SELECT * FROM tasks WHERE id=?", (task_id,)).fetchone()
        if row is None:
            raise ValueError(f"Unknown task: {task_id}")
        task = dict(row)
        task["snapshot"] = json.loads(task["snapshot"])
        return task

    def tasks(self) -> list[dict[str, Any]]:
        return [self.task(row[0]) for row in self.db.execute("SELECT id FROM tasks ORDER BY id")]

    def dependencies(self, task_id: int) -> list[dict[str, Any]]:
        return [
            dict(row)
            for row in self.db.execute(
                "SELECT t.id,t.url,t.stage,t.state,t.reason FROM dependencies d "
                "JOIN tasks t ON t.id=d.requires WHERE d.task_id=? ORDER BY t.id",
                (task_id,),
            )
        ]

    def depend(self, task_id: int, requires: list[int], *, clear: bool = False) -> None:
        with self.db:
            self.db.execute("BEGIN IMMEDIATE")
            self.task(task_id)
            if self.db.execute("SELECT 1 FROM leases WHERE task_id=?", (task_id,)).fetchone():
                raise ValueError("Cannot edit dependencies of an occupied task")
            if clear:
                self.db.execute("DELETE FROM dependencies WHERE task_id=?", (task_id,))
            for other in requires:
                self.task(other)
                self.db.execute("INSERT OR IGNORE INTO dependencies VALUES(?,?)", (task_id, other))
            cycle = self.db.execute(
                "WITH RECURSIVE edges(id) AS (SELECT requires FROM dependencies WHERE task_id=? "
                "UNION SELECT d.requires FROM dependencies d JOIN edges e ON d.task_id=e.id) "
                "SELECT 1 FROM edges WHERE id=?",
                (task_id, task_id),
            ).fetchone()
            if cycle:
                raise ValueError("Task dependency cycle is not allowed")

    def runs(self, task_id: int) -> list[dict[str, Any]]:
        return [
            dict(row)
            for row in self.db.execute(
                "SELECT * FROM runs WHERE task_id=? ORDER BY started", (task_id,)
            )
        ]

    def register(self, url: str, repo_path: Path, sha: str, snapshot: dict[str, Any]) -> int:
        is_open = snapshot.get("state") == "open"
        with self.db:
            self.db.execute("BEGIN IMMEDIATE")
            existing = self.db.execute(
                "SELECT id,repo_path FROM tasks WHERE lower(url)=lower(?)", (url,)
            ).fetchone()
            if existing:
                if existing["repo_path"] != str(repo_path.resolve()):
                    raise ValueError(
                        "Task is already registered against a different local repository"
                    )
                return int(existing["id"])
            self.db.execute(
                "INSERT OR IGNORE INTO tasks "
                "(url,repo_path,stage,state,target_sha,snapshot,reason,updated,pr_number) "
                "VALUES (?,?,?,?,?,?,?,?,?)",
                (
                    url,
                    str(repo_path.resolve()),
                    Stage.ANALYSIS,
                    State.QUEUED if is_open else State.HUMAN,
                    sha,
                    json.dumps(snapshot),
                    "" if is_open else "GitHub object is closed; manual handling required",
                    time.time(),
                    snapshot["number"] if snapshot.get("kind") == "pull" else None,
                ),
            )
        row = self.db.execute("SELECT id,repo_path FROM tasks WHERE url=?", (url,)).fetchone()
        assert row is not None
        if row[1] != str(repo_path.resolve()):
            raise ValueError("Task is already registered against a different local repository")
        return int(row[0])

    def sync(self, task_id: int, snapshot: dict[str, Any]) -> None:
        with self.db:
            self.db.execute("BEGIN IMMEDIATE")
            task = self.task(task_id)
            sha = snapshot.get("head_sha") or task["target_sha"]
            version_changed = sha != task["target_sha"] or any(
                snapshot.get(key) != task["snapshot"].get(key) for key in VERSION_FIELDS
            )
            lifecycle_changed = snapshot.get("state") != task["snapshot"].get("state")
            stage, state, reason = task["stage"], task["state"], task["reason"]
            if version_changed or lifecycle_changed:
                self.db.execute("UPDATE runs SET evidence_valid=0 WHERE task_id=?", (task_id,))
                self.db.execute("UPDATE artifacts SET valid=0 WHERE task_id=?", (task_id,))
            if version_changed:
                stage = Stage.ANALYSIS
                active = self.db.execute(
                    "SELECT 1 FROM runs WHERE task_id=? AND state=?", (task_id, State.RUNNING)
                ).fetchone()
                # Human intervention cannot be cleared by a later remote content edit.
                if state not in {State.HUMAN, State.RECONCILE}:
                    state = State.RECONCILE if active else State.QUEUED
                    reason = "GitHub head, base or request changed; previous evidence is invalid"
            if snapshot.get("state") != "open":
                state = State.HUMAN
                reason = "GitHub object is closed; manual handling required"
            elif lifecycle_changed:
                stage, state = Stage.ANALYSIS, State.HUMAN
                reason = "GitHub object reopened; manual handling required before a new run"
            if task["cancel_requested"]:
                state, reason = State.CANCELLED, "Cancelled by user"
            elif snapshot.get("merged"):
                stage, state, reason = (
                    Stage.MERGED,
                    State.COMPLETED,
                    "GitHub confirms the PR was merged",
                )
            self.db.execute(
                "UPDATE tasks SET stage=?,state=?,reason=?,snapshot=?,target_sha=?,updated=? "
                "WHERE id=?",
                (stage, state, reason, json.dumps(snapshot), sha, time.time(), task_id),
            )

    def begin_run(
        self,
        task_id: int,
        role: Role,
        *,
        expected_snapshot: dict[str, Any] | None = None,
    ) -> str:
        try:
            self.db.execute("BEGIN IMMEDIATE")
            task = self.task(task_id)
            if task_id in self.owners:
                self.guard(task)
            if expected_snapshot is not None and task["snapshot"] != expected_snapshot:
                raise ValueError("GitHub snapshot changed before claim; sync and retry")
            if task["snapshot"].get("state") != "open" or task["cancel_requested"]:
                raise ValueError("Closed or cancelled tasks cannot run")
            if task["state"] not in {State.QUEUED, State.FAILED, State.WAITING_ENVIRONMENT}:
                raise ValueError(f"Task cannot run in state {task['state']}")
            expected = {
                Stage.ANALYSIS: Role.ANALYST,
                Stage.DEVELOPMENT: Role.DEVELOPER,
                Stage.REVISION: Role.DEVELOPER,
                Stage.REVIEW: Role.REVIEWER,
                Stage.VALIDATION: Role.VALIDATOR,
            }
            if expected.get(Stage(task["stage"])) != role:
                raise ValueError("The requested role does not match the current stage")
            run_id = uuid.uuid4().hex
            self.db.execute(
                "INSERT INTO runs (id,task_id,role,state,target_sha,owner_pid,started,owner_token) "
                "VALUES (?,?,?,?,?,?,?,?)",
                (
                    run_id,
                    task_id,
                    role,
                    State.RUNNING,
                    task["target_sha"],
                    os.getpid(),
                    time.time(),
                    self.owners.get(task_id),
                ),
            )
            self.db.execute(
                "UPDATE tasks SET state=?,cancel_requested=0,reason='',updated=? WHERE id=?",
                (State.RUNNING, time.time(), task_id),
            )
            self.db.commit()
            return run_id
        except BaseException:
            self.db.rollback()
            raise

    def run_metadata(self, run_id: str, **values: str) -> None:
        if values.keys() - {"thread_id", "worktree", "context_hash"}:
            raise ValueError("Invalid metadata field")
        with self.db:
            for key, value in values.items():
                self.db.execute(f"UPDATE runs SET {key}=? WHERE id=?", (value, run_id))

    def finish(
        self,
        run_id: str,
        run_state: State,
        stage: Stage,
        task_state: State,
        reason: str,
        result: str | None = None,
    ) -> None:
        with self.db:
            self.db.execute("BEGIN IMMEDIATE")
            run = self.db.execute("SELECT * FROM runs WHERE id=?", (run_id,)).fetchone()
            assert run is not None
            task = self.task(run["task_id"])
            lease_ok = (
                not run["owner_token"]
                or self.db.execute(
                    "SELECT 1 FROM leases WHERE task_id=? AND owner=? AND expires>=?",
                    (task["id"], run["owner_token"], time.time()),
                ).fetchone()
                is not None
            )
            if not lease_ok:
                run_state, result = State.RECONCILE, None
            if task["cancel_requested"]:
                run_state = task_state = State.CANCELLED
                stage = Stage(task["stage"])
                reason = "Cancelled by user"
            elif task["snapshot"].get("merged"):
                stage, task_state = Stage.MERGED, State.COMPLETED
                reason = "GitHub confirms the PR was merged"
            elif task["snapshot"].get("state") != "open" or task["state"] == State.HUMAN:
                stage, task_state = Stage(task["stage"]), State.HUMAN
                reason = task["reason"] or "GitHub object is closed; manual handling required"
            elif not lease_ok:
                stage, run_state, task_state = (
                    Stage(task["stage"]),
                    State.RECONCILE,
                    State.RECONCILE,
                )
                reason, result = "Execution lease lost; late result rejected", None
                self.db.execute("UPDATE runs SET evidence_valid=0 WHERE id=?", (run_id,))
            elif task["target_sha"] != run["target_sha"] or not run["evidence_valid"]:
                stage = Stage(task["stage"])
                task_state = State.RECONCILE
                reason = "Target changed during execution; result cannot advance the stage"
            self.db.execute(
                "UPDATE runs SET state=?,result=?,error=?,ended=?,"
                "evidence_valid=CASE WHEN ? THEN evidence_valid ELSE 0 END "
                "WHERE id=? AND state=?",
                (
                    run_state,
                    result,
                    reason,
                    time.time(),
                    run_state == State.COMPLETED and result is not None,
                    run_id,
                    State.RUNNING,
                ),
            )
            self.db.execute(
                "UPDATE tasks SET stage=?,state=?,reason=?,updated=? WHERE id=?",
                (stage, task_state, reason, time.time(), run["task_id"]),
            )

    def cancel(self, task_id: int) -> None:
        with self.db:
            self.db.execute("BEGIN IMMEDIATE")
            task = self.task(task_id)
            state = State.RUNNING if task["state"] == State.RUNNING else State.CANCELLED
            self.db.execute(
                "UPDATE tasks SET cancel_requested=1,state=?,reason=?,updated=? WHERE id=?",
                (state, "Cancellation requested", time.time(), task_id),
            )

    def event(self, run_id: str, kind: str, summary: str) -> None:
        with self.db:
            self.db.execute(
                "INSERT INTO events (run_id,at,kind,summary) VALUES (?,?,?,?)",
                (run_id, time.time(), kind, summary[:300]),
            )
            self.db.execute(
                "DELETE FROM events WHERE run_id=? AND id NOT IN "
                "(SELECT id FROM events WHERE run_id=? ORDER BY id DESC LIMIT 1000)",
                (run_id, run_id),
            )

    def guard(self, expected: dict[str, Any]) -> dict[str, Any]:
        task = self.task(expected["id"])
        if owner := self.owners.get(task["id"]):
            lease = self.db.execute(
                "SELECT 1 FROM leases WHERE task_id=? AND owner=? AND expires>=?",
                (task["id"], owner, time.time()),
            ).fetchone()
            if lease is None:
                raise ValueError("Execution lease lost; evidence cannot advance")
        if task["stage"] == Stage.MERGED:
            raise ValueError("Merged tasks are terminal")
        if task["cancel_requested"] or task["state"] in {
            State.CANCELLED,
            State.RECONCILE,
            State.HUMAN,
        }:
            raise ValueError("Task is cancelled or needs manual handling")
        if any(task[key] != expected[key] for key in ("target_sha", "snapshot", "stage")):
            raise ValueError("Task changed; evidence cannot be applied")
        return task

    def transition(
        self,
        expected: dict[str, Any],
        stage: Stage,
        state: State,
        reason: str,
        *,
        snapshot: dict[str, Any] | None = None,
        pr_number: int | None = None,
        revision: bool = False,
        invalidate: bool = False,
    ) -> None:
        with self.db:
            self.db.execute("BEGIN IMMEDIATE")
            task = self.guard(expected)
            if self.db.execute(
                "SELECT 1 FROM runs WHERE task_id=? AND state=?", (task["id"], State.RUNNING)
            ).fetchone():
                raise ValueError("Task still has an active agent")
            new = snapshot if snapshot is not None else task["snapshot"]
            sha = new.get("head_sha") or task["target_sha"]
            if sha != task["target_sha"] or invalidate:
                self.db.execute("UPDATE runs SET evidence_valid=0 WHERE task_id=?", (task["id"],))
                self.db.execute("UPDATE artifacts SET valid=0 WHERE task_id=?", (task["id"],))
            self.db.execute(
                "UPDATE tasks SET stage=?,state=?,reason=?,snapshot=?,target_sha=?,"
                "pr_number=COALESCE(?,pr_number),revision_count=revision_count+?,"
                "updated=? WHERE id=?",
                (
                    stage,
                    state,
                    reason,
                    json.dumps(new),
                    sha,
                    pr_number,
                    int(revision),
                    time.time(),
                    task["id"],
                ),
            )

    def artifact(self, task_id: int, kind: str, policy: str) -> dict[str, Any] | None:
        task = self.task(task_id)
        row = self.db.execute(
            "SELECT data FROM artifacts WHERE task_id=? AND sha=? AND kind=? "
            "AND policy=? AND valid=1 ORDER BY id DESC LIMIT 1",
            (task_id, task["target_sha"], kind, policy),
        ).fetchone()
        return json.loads(row[0]) if row else None

    def record(
        self, expected: dict[str, Any], kind: str, policy: str, data: dict[str, Any]
    ) -> None:
        with self.db:
            self.db.execute("BEGIN IMMEDIATE")
            self.guard(expected)
            self.db.execute(
                "INSERT INTO artifacts(task_id,sha,kind,policy,data) VALUES(?,?,?,?,?)",
                (expected["id"], expected["target_sha"], kind, policy, json.dumps(data)),
            )

    def operation(self, key: str) -> dict[str, Any] | None:
        row = self.db.execute("SELECT * FROM operations WHERE id=?", (key,)).fetchone()
        return dict(row) if row else None

    def intent(self, expected: dict[str, Any], key: str, kind: str, payload: str) -> bool:
        with self.db:
            self.db.execute("BEGIN IMMEDIATE")
            self.guard(expected)
            row = self.operation(key)
            if row:
                if row["payload"] != payload or row["sha"] != expected["target_sha"]:
                    raise ValueError("Operation identity conflicts with existing intent")
                return False
            self.db.execute(
                "INSERT INTO operations(id,task_id,sha,kind,payload,state) VALUES(?,?,?,?,?,?)",
                (key, expected["id"], expected["target_sha"], kind, payload, "pending"),
            )
            return True

    def operation_result(self, key: str, state: str, response: dict[str, Any] | None) -> None:
        with self.db:
            self.db.execute(
                "UPDATE operations SET state=?,response=? WHERE id=?",
                (state, json.dumps(response) if response is not None else None, key),
            )

    def halt(self, task_id: int, state: State, reason: str) -> None:
        with self.db:
            self.db.execute("BEGIN IMMEDIATE")
            task = self.task(task_id)
            if task["cancel_requested"]:
                state = State.CANCELLED
            self.db.execute(
                "UPDATE tasks SET state=?,reason=?,updated=? WHERE id=?",
                (state, reason, time.time(), task_id),
            )

    def evidence(self, task_id: int) -> dict[str, Any]:
        artifacts = [
            dict(row)
            for row in self.db.execute(
                "SELECT * FROM artifacts WHERE task_id=? ORDER BY id", (task_id,)
            )
        ]
        operations = [
            dict(row)
            for row in self.db.execute(
                "SELECT * FROM operations WHERE task_id=? ORDER BY rowid", (task_id,)
            )
        ]
        for artifact in artifacts:
            artifact["data"] = json.loads(artifact["data"])
        for operation in operations:
            operation["payload"] = json.loads(operation["payload"])
            operation["response"] = (
                json.loads(operation["response"]) if operation["response"] else None
            )
        return {"artifacts": artifacts, "operations": operations}
