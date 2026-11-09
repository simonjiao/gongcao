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
from _support.github import RegisteredGitHub, StatusGitHub
from _support.quality import items
from _support.tasks import analysis_ready, register_more, wait_for
from _support.worker import SUCCESS, install_worker

from gongcao.config import Config
from gongcao.control import Controls
from gongcao.github import Deferred
from gongcao.leases import Lease
from gongcao.model import Stage, State
from gongcao.quality import Quality
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
    scheduler = Scheduler(store, config, StatusGitHub(store), 2)
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


@pytest.mark.parametrize("failure", ["agent", "environment", "requirements"])
async def test_scheduler_distinguishes_requirement_waits_and_bounded_failures(
    store, task_id, sha, auth_file, monkeypatch, failure
):
    install_worker(monkeypatch, "import sys;sys.stdin.readline();raise SystemExit(7)")
    github = StatusGitHub(store)
    scheduler = Scheduler(store, Config(auth_file=auth_file), github)
    if failure != "agent":
        analysis_ready(store, task_id, sha)
        store.transition(store.task(task_id), Stage.REVIEW, State.QUEUED, "Ready for checks")
        quality = Quality(store, scheduler.config)
        plan = quality.confirm(
            store.task(task_id), items([] if failure == "requirements" else ["missing-check-entry"])
        )
    if failure == "requirements":
        run_ids = []
        for _ in range(4):
            await scheduler.serve(once=True)
            assert store.task(task_id)["state"] == State.WAITING_ENVIRONMENT
            run_ids.append(store.artifact(task_id, "quality-results", plan["plan_hash"])["run_id"])
            assert dict(
                store.db.execute(
                    "SELECT kind,count(*) FROM artifacts "
                    "WHERE kind IN ('quality-wait','quality-results') "
                    "GROUP BY kind"
                )
            ) == {"quality-wait": 1, "quality-results": 1}
            assert store.db.execute("SELECT count(*) FROM retries").fetchone()[0] == 0
        assert len(set(run_ids)) == 1
        plan["items"][1]["entry"] = ["true"]
        quality.confirm(store.task(task_id), plan["items"])
        resumed = await quality.run(store.task(task_id), include_e2e=True)
        assert resumed["passed"] and resumed["run_id"] != run_ids[0]
        assert store.task(task_id)["state"] == State.QUEUED
        return
    expected_runs = 1 if failure == "environment" else 3
    for attempt in range(1, 4):
        await scheduler.serve(once=True)
        retry = store.db.execute("SELECT * FROM retries WHERE task_id=?", (task_id,)).fetchone()
        assert retry["failures"] == attempt
        assert (retry["next_at"] > time.time()) == (attempt < 3)
        with store.db:
            store.db.execute("UPDATE retries SET next_at=0")
    assert len(store.runs(task_id)) == expected_runs
    if failure == "environment":
        results = [
            a["data"]
            for a in store.evidence(task_id)["artifacts"]
            if a["kind"] == "quality-results"
        ]
        assert len({r["run_id"] for r in results}) == 3
        assert all(r["items"][1]["exit_code"] == 127 for r in results)
    assert store.task(task_id)["state"] == State.HUMAN
    await scheduler.serve(once=True)
    assert len(store.runs(task_id)) == expected_runs
    assert "no_progress_after_bounded_attempts" in diagnose(store, task_id)["issues"]
    assert (await Recovery(store, github).retry(task_id))["recovered"]
    assert store.task(task_id)["state"] == State.QUEUED
    assert len(store.runs(task_id)) == expected_runs
    assert all(r["evidence_valid"] == (failure == "environment") for r in store.runs(task_id))


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
        assert Controls(store).issue(task_id, "step")
        await Workflow(store, scheduler.config, scheduler.github).run(task_id)
        assert store.task(task_id)["control"]["spent"]
        assert store.evidence(task_id)["instructions"][-1]["status"] == "blocked"
    await Workflow(store, scheduler.config, scheduler.github).run(task_id)
    assert not store.runs(task_id)  # Free capacity does not revive that spent Step.


@pytest.mark.parametrize("advisory", ["slow", "failed", "cancelled"])
async def test_step_advice_does_not_hold_a_business_slot_or_cancel_other_tasks(
    store, task_id, repo, sha, snapshot, monkeypatch, advisory
):
    second = register_more(store, repo, sha, snapshot, 1)[0]
    entered, release = asyncio.Event(), asyncio.Event()
    completed = []

    async def execute(self, task_id):
        async with Lease(store, task_id) as lease:
            self.lease = lease
            self.advice_pending = task_id != second
            completed.append(task_id)

    async def analyze(*args):
        entered.set()
        if advisory == "failed":
            raise OSError("advisory directory unavailable")
        await release.wait()
        return {"status": "completed"}

    monkeypatch.setattr(Workflow, "run", execute)
    monkeypatch.setattr("gongcao.coordination.Coordinator.run", analyze)
    scheduler = Scheduler(store, Config(), RegisteredGitHub(store), 1)
    try:
        await scheduler.advance(task_id)
        await asyncio.wait_for(entered.wait(), 1)
        if advisory == "cancelled":
            scheduler.advisory.cancel()
        await asyncio.wait_for(scheduler.advance(second), 1)
        assert completed == [task_id, second] and not store.runs(second)
        assert all(t["state"] == State.QUEUED for t in store.tasks())
    finally:
        release.set()
        await asyncio.gather(scheduler.advisory, return_exceptions=True)


def test_offline_serve_cli_enforces_1_to_3_slots_and_queues(offline_checkout, tmp_path):
    path = tmp_path / "jobs.yaml"
    path.write_text("scheduler:\n  jobs: 2\nqa:\n  jobs: 7\n")
    sha = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=offline_checkout, text=True
    ).strip()
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
                    offline_checkout,
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
        env = cli_env(offline_checkout, gate)
        with subprocess.Popen(
            [GONGCAO, "--state-dir", str(state), "serve", "--once", *options],
            cwd=offline_checkout,
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
                status = run_cli(
                    offline_checkout, env, GONGCAO, "--state-dir", str(state), "status"
                )
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
