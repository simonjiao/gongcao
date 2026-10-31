import json
import sqlite3

import pytest
from _support.tasks import analysis_ready

from gongcao.control import Controls
from gongcao.model import Role
from gongcao.store import Store


@pytest.mark.parametrize("run_state", ["completed", "running"])
def test_schema_zero_upgrade_preserves_history_and_restarts(
    tmp_path, repo, sha, snapshot, run_state
):
    root = tmp_path / "old"
    root.mkdir()
    db = sqlite3.connect(root / "gongcao.sqlite3")
    db.executescript("""
    CREATE TABLE tasks(id INTEGER PRIMARY KEY,url TEXT UNIQUE NOT NULL,repo_path TEXT NOT NULL,
      stage TEXT NOT NULL,state TEXT NOT NULL,target_sha TEXT NOT NULL,snapshot TEXT NOT NULL,
      reason TEXT NOT NULL DEFAULT '',cancel_requested INTEGER NOT NULL DEFAULT 0,
      updated REAL NOT NULL);
    CREATE TABLE runs(id TEXT PRIMARY KEY,task_id INTEGER NOT NULL REFERENCES tasks(id),
      role TEXT NOT NULL,state TEXT NOT NULL,target_sha TEXT NOT NULL,thread_id TEXT,
      worktree TEXT,context_hash TEXT,result TEXT,error TEXT,owner_pid INTEGER NOT NULL,
      started REAL NOT NULL,ended REAL,evidence_valid INTEGER NOT NULL DEFAULT 1);
    CREATE TABLE events(id INTEGER PRIMARY KEY,run_id TEXT NOT NULL REFERENCES runs(id),
      at REAL NOT NULL,
      kind TEXT NOT NULL,summary TEXT NOT NULL);
    """)
    db.execute(
        "INSERT INTO tasks VALUES(1,?,?,?,?,?,?,?,0,1)",
        (
            snapshot["url"],
            str(repo),
            "pending_analysis",
            "running" if run_state == "running" else "queued",
            sha,
            json.dumps(snapshot),
            "history",
        ),
    )
    db.execute(
        "INSERT INTO runs(id,task_id,role,state,target_sha,thread_id,owner_pid,started) "
        "VALUES(?,1,?,?,?,?,1,1)",
        ("old-run", "analyst", run_state, sha, "old-thread"),
    )
    db.execute("INSERT INTO events VALUES(1,?,1,?,?)", ("old-run", "started", "history"))
    db.commit()
    db.close()
    for _ in range(2):
        upgraded = Store(root)
        assert upgraded.db.execute("PRAGMA user_version").fetchone()[0] == 5
        assert upgraded.task(1)["reason"] == "history"
        assert upgraded.runs(1)[0]["thread_id"] == "old-thread"
        assert upgraded.runs(1)[0]["state"] == run_state
        assert upgraded.db.execute("SELECT summary FROM events").fetchone()[0] == "history"
        if run_state == "running":
            with pytest.raises(ValueError):
                upgraded.begin_run(1, Role.ANALYST)
        upgraded.close()


def test_future_schema_is_rejected_without_rewriting(tmp_path):
    db = sqlite3.connect(tmp_path / "gongcao.sqlite3")
    db.execute("PRAGMA user_version=99")
    db.close()
    with pytest.raises(ValueError, match="newer"):
        Store(tmp_path)
    db = sqlite3.connect(tmp_path / "gongcao.sqlite3")
    assert db.execute("PRAGMA user_version").fetchone()[0] == 99
    assert db.execute("SELECT name FROM sqlite_master").fetchall() == []
    db.close()


def test_schema_one_upgrade_keeps_unknown_intents_and_history(store, task_id, sha):
    analysis_ready(store, task_id, sha)
    store.intent(store.task(task_id), "pending", "push", "{}")
    with store.db:
        store.db.execute("ALTER TABLE runs DROP COLUMN details")
        store.db.execute("DROP TRIGGER status_dirty")
        store.db.execute("DROP TABLE claims")
        store.db.execute("DROP TABLE controller")
        for table in ("leases", "processes", "dependencies", "retries", "instructions"):
            store.db.execute(f"DROP TABLE {table}")
        store.db.execute("DROP INDEX events_run_kind")
        store.db.execute("ALTER TABLE runs DROP COLUMN owner_token")
        store.db.execute("ALTER TABLE tasks DROP COLUMN control")
        store.db.execute("PRAGMA user_version=1")
    for _ in range(2):
        restarted = Store(store.root)
        try:
            assert restarted.db.execute("PRAGMA user_version").fetchone()[0] == 5
            assert len(restarted.runs(task_id)) == 1
            assert restarted.operation("pending")["state"] == "pending"
            assert restarted.runs(task_id)[0]["owner_token"] is None
        finally:
            restarted.close()


@pytest.mark.parametrize("version", [2, 3])
def test_schema_upgrade_preserves_intents_and_legacy_auto(store, task_id, version):
    store.intent(store.task(task_id), "unknown", "push", "{}")
    expected = {} if version == 2 else store.task(task_id)["control"]
    with store.db:
        store.db.execute("ALTER TABLE runs DROP COLUMN details")
        store.db.execute("DROP TRIGGER status_dirty")
        store.db.execute("DROP TABLE claims")
        store.db.execute("DROP TABLE controller")
        if version == 2:
            store.db.execute("DROP TABLE instructions")
            store.db.execute("ALTER TABLE tasks DROP COLUMN control")
        store.db.execute(f"PRAGMA user_version={version}")
    for _ in range(2):
        restarted = Store(store.root)
        try:
            assert restarted.task(task_id)["control"] == expected
            assert restarted.operation("unknown")["state"] == "pending"
            assert Controls(restarted).checkpoint(task_id)
        finally:
            restarted.close()


def test_v4_upgrade_preserves_history_without_inventing_execution_defaults(store, task_id):
    from gongcao.model import Role

    run = store.begin_run(task_id, Role.ANALYST)
    with store.db:
        store.db.execute("ALTER TABLE runs DROP COLUMN details")
        store.db.execute("PRAGMA user_version=4")
    for _ in range(2):
        reopened = Store(store.root)
        try:
            assert reopened.db.execute("PRAGMA user_version").fetchone()[0] == 5
            assert reopened.runs(task_id)[0]["details"] == {}
            assert reopened.runs(task_id)[0]["id"] == run
        finally:
            reopened.close()
