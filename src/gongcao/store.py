"""Transactional local task and execution records. GitHub facts remain snapshots."""

import json
import os
import sqlite3
import time
import uuid
from pathlib import Path
from typing import Any

from .model import Role, Stage, State


class Store:
    def __init__(self, root: Path):
        self.root = root.resolve()
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.db = sqlite3.connect(self.root / "gongcao.sqlite3", timeout=10)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA foreign_keys=ON")
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
            self.db.execute(
                "INSERT OR IGNORE INTO tasks "
                "(url,repo_path,stage,state,target_sha,snapshot,reason,updated) "
                "VALUES (?,?,?,?,?,?,?,?)",
                (
                    url,
                    str(repo_path.resolve()),
                    Stage.ANALYSIS,
                    State.QUEUED if is_open else State.HUMAN,
                    sha,
                    json.dumps(snapshot),
                    "" if is_open else "GitHub object is closed; manual handling required",
                    time.time(),
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
                snapshot.get(key) != task["snapshot"].get(key)
                for key in (
                    "title",
                    "body",
                    "base_sha",
                    "base_ref",
                    "base_repository",
                    "head_repository",
                )
            )
            lifecycle_changed = snapshot.get("state") != task["snapshot"].get("state")
            stage, state, reason = task["stage"], task["state"], task["reason"]
            if version_changed or lifecycle_changed:
                self.db.execute("UPDATE runs SET evidence_valid=0 WHERE task_id=?", (task_id,))
            if version_changed:
                stage = Stage.ANALYSIS
                active = self.db.execute(
                    "SELECT 1 FROM runs WHERE task_id=? AND state=?", (task_id, State.RUNNING)
                ).fetchone()
                # Human intervention cannot be cleared by a later remote content edit.
                if state != State.HUMAN:
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
            if expected_snapshot is not None and task["snapshot"] != expected_snapshot:
                raise ValueError("GitHub snapshot changed before claim; sync and retry")
            if task["snapshot"].get("state") != "open" or task["cancel_requested"]:
                raise ValueError("Closed or cancelled tasks cannot run")
            if task["state"] not in {State.QUEUED, State.FAILED, State.WAITING_ENVIRONMENT}:
                raise ValueError(f"Task cannot run in state {task['state']}")
            expected = {Stage.ANALYSIS: Role.ANALYST, Stage.DEVELOPMENT: Role.DEVELOPER}
            if expected.get(Stage(task["stage"])) != role:
                raise ValueError("The requested role does not match the current PR1 stage")
            run_id = uuid.uuid4().hex
            self.db.execute(
                "INSERT INTO runs (id,task_id,role,state,target_sha,owner_pid,started) "
                "VALUES (?,?,?,?,?,?,?)",
                (
                    run_id,
                    task_id,
                    role,
                    State.RUNNING,
                    task["target_sha"],
                    os.getpid(),
                    time.time(),
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
            if task["cancel_requested"]:
                run_state = task_state = State.CANCELLED
                stage = Stage(task["stage"])
                reason = "Cancelled by user"
            elif task["snapshot"].get("state") != "open" or task["state"] == State.HUMAN:
                stage, task_state = Stage(task["stage"]), State.HUMAN
                reason = task["reason"] or "GitHub object is closed; manual handling required"
            elif task["target_sha"] != run["target_sha"] or not run["evidence_valid"]:
                stage = Stage(task["stage"])
                task_state = State.RECONCILE
                reason = "Target changed during execution; result cannot advance the stage"
            self.db.execute(
                "UPDATE runs SET state=?,result=?,error=?,ended=? WHERE id=? AND state=?",
                (run_state, result, reason, time.time(), run_id, State.RUNNING),
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
