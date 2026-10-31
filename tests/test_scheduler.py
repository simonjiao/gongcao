import asyncio
import contextlib
import json
import os
import signal
import subprocess
import time
from pathlib import Path

import pytest
from _support.cli import GONGCAO, cli_env, events, run_cli
from _support.github import RegisteredGitHub
from _support.tasks import analysis_ready, register_more, wait_for
from _support.worker import SUCCESS, install_worker

from gongcao.config import Config
from gongcao.github import Deferred
from gongcao.leases import Lease
from gongcao.model import State
from gongcao.recovery import Recovery, diagnose
from gongcao.remote import Controlled
from gongcao.scheduler import Scheduler
from gongcao.store import Store
from gongcao.workflow import Workflow


async def test_dependency_cycle_rolls_back_and_a_blocked_task_cannot_launch(
    store, task_id, repo, sha, snapshot
):
    second = register_more(store, repo, sha, snapshot, 1)[0]
    store.depend(task_id, [second])
    with pytest.raises(ValueError, match="cycle"):
        store.depend(second, [task_id])
    assert store.dependencies(second) == []
    assert await Workflow(store, Config(), RegisteredGitHub(store)).run(task_id) == []
    assert not store.runs(task_id)
    assert store.task(task_id)["state"] == State.WAITING_DEPENDENCY
    store.halt(task_id, State.HUMAN, "manual gate")
    await Workflow(store, Config(), RegisteredGitHub(store)).run(task_id)
    assert store.task(task_id)["state"] == State.HUMAN


async def test_parallel_developers_write_distinct_worktrees_and_leave_source_unchanged(
    store, task_id, repo, sha, snapshot, auth_file, monkeypatch
):
    second = register_more(store, repo, sha, snapshot, 1)[0]
    for tid in (task_id, second):
        analysis_ready(store, tid, sha)
    worker = SUCCESS.replace("'changed in worktree\\n'", "str(request['context']['task_id'])")
    install_worker(monkeypatch, worker)
    at_publish = []
    release = asyncio.Event()

    async def publish(self, task, run):
        at_publish.append((task["id"], Path(run["worktree"])))
        await release.wait()
        raise OSError("Fixture stops before remote writes")

    monkeypatch.setattr(Controlled, "publish", publish)
    config = Config(auth_file=auth_file)
    scheduler = Scheduler(store, config, RegisteredGitHub(store), 2)
    running = asyncio.create_task(scheduler.serve(once=True))
    try:
        await wait_for(lambda: len(at_publish) == 2)
        assert store.db.execute("SELECT count(*) FROM leases").fetchone()[0] == 2
        assert len({p for _, p in at_publish}) == 2
        for tid, path in at_publish:
            assert (path / "sample.txt").read_text() == str(tid)
        assert (repo / "sample.txt").read_text() == "original\n"
    finally:
        release.set()
        await running


async def test_scheduler_stops_after_three_failures_and_manual_retry_preserves_history(
    store, task_id, auth_file, monkeypatch
):
    install_worker(monkeypatch, "import sys;sys.stdin.readline();raise SystemExit(7)")
    github = RegisteredGitHub(store)
    scheduler = Scheduler(store, Config(auth_file=auth_file), github)
    for _ in range(3):
        await scheduler.serve(once=True)
        with store.db:
            store.db.execute("UPDATE retries SET next_at=0")
    assert len(store.runs(task_id)) == 3
    assert store.task(task_id)["state"] == State.HUMAN
    await scheduler.serve(once=True)
    assert len(store.runs(task_id)) == 3
    assert "no_progress_after_bounded_attempts" in diagnose(store, task_id)["issues"]
    assert (await Recovery(store, github).retry(task_id))["recovered"]
    assert store.task(task_id)["state"] == State.QUEUED
    assert len(store.runs(task_id)) == 3
    assert not any(r["evidence_valid"] for r in store.runs(task_id))


async def test_occupied_capacity_does_not_spend_retry_budget(store, task_id, repo, sha, snapshot):
    ids = register_more(store, repo, sha, snapshot, 3)
    store.halt(task_id, State.WAITING_ENVIRONMENT, "one actual failure")
    with store.db:
        store.db.execute("INSERT INTO retries VALUES(?,?,?,?)", (task_id, 1, "old", 0))
    scheduler = Scheduler(store, Config(), RegisteredGitHub(store))
    scheduler.github.traffic.defer(store, task_id, Deferred("readback limited"), recovery=True)
    async with contextlib.AsyncExitStack() as stack:
        for tid in ids:
            assert (await stack.enter_async_context(Lease(store, tid))).acquired
        for _ in range(3):
            await scheduler.advance(task_id)
        assert (
            store.db.execute("SELECT failures FROM retries WHERE task_id=?", (task_id,)).fetchone()[
                0
            ]
            == 1
        )
        assert not store.runs(task_id)
        assert store.artifact(task_id, "github-cooldown", "")["recovery"]
        assert store.task(task_id)["state"] == State.WAITING_DEPENDENCY


def test_offline_serve_cli_enforces_1_to_3_slots_and_queues(checkout, tmp_path):
    path = tmp_path / "jobs.yaml"
    path.write_text("scheduler:\n  jobs: 2\nqa:\n  jobs: 7\n")
    sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=checkout, text=True).strip()
    for jobs, options in (
        (1, []),
        (2, ["--config", str(path)]),
        (3, ["--config", str(path), "--jobs", "3"]),
    ):
        state, gate = tmp_path / f"state-{jobs}", tmp_path / f"gate-{jobs}"
        store = Store(state)
        try:
            for number in range(1, 5):
                url = f"https://github.com/example/demo/issues/{number}"
                store.register(
                    url,
                    checkout,
                    sha,
                    {
                        "url": url,
                        "repository": "example/demo",
                        "kind": "issues",
                        "number": number,
                        "title": "offline",
                        "body": "",
                        "state": "open",
                        "updated_at": "2026-10-25T00:00:00Z",
                    },
                )
        finally:
            store.close()
        env = cli_env(checkout, gate)
        with subprocess.Popen(
            [GONGCAO, "--state-dir", str(state), "serve", "--once", *options],
            cwd=checkout,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        ) as process:
            try:
                deadline = time.monotonic() + 20
                while (
                    len(events(gate)) < jobs
                    and process.poll() is None
                    and time.monotonic() < deadline
                ):
                    time.sleep(0.01)
                assert len(events(gate)) == jobs  # Others cannot read until a slot releases.
                status = run_cli(checkout, env, GONGCAO, "--state-dir", str(state), "status")
                occupied = [t for t in status if t["runtime"]["lease"] is not None]
                assert len(status) == 4 and len(occupied) == jobs
                assert all(t["runtime"]["lease"]["pid"] == process.pid for t in occupied)
            finally:
                (gate / "release").touch()
                try:
                    stdout, stderr = process.communicate(timeout=20)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.communicate()
                    raise
            assert process.returncode == 0, stdout + stderr
        tasks = json.loads(stdout)
        assert len(tasks) == 4 and all(t["state"] == "needs_human" for t in tasks)
        store = Store(state)
        try:
            for task in tasks:
                assert not store.runs(task["id"])
                assert not store.evidence(task["id"])["operations"]
        finally:
            store.close()
        active, peak = 0, 0
        rows = events(gate)
        assert len(rows) == 8 and rows[jobs]["kind"] == "released"
        for row in rows:
            active += 1 if row["kind"] == "started" else -1
            peak = max(peak, active)
            assert 0 <= active <= jobs
        assert active == 0 and peak == jobs
