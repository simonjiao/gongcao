import asyncio
import json

import pytest
from _support.github import ReadOnlyGitHub
from _support.worker import SUCCESS, install_worker

from gongcao.config import Config
from gongcao.events import Journal
from gongcao.model import Stage, State
from gongcao.processes import CleanupError
from gongcao.runner import Runner
from gongcao.sandbox import IsolationError, Sandbox


async def test_complete_local_flow_uses_new_context_and_stops_at_pr_gate(
    store,
    task_id,
    snapshot,
    auth_file,
    repo,
    monkeypatch,
):
    install_worker(monkeypatch, SUCCESS)
    runner = Runner(store, Config(auth_file=auth_file), ReadOnlyGitHub(snapshot))
    analysis = await runner.run(task_id)
    assert store.task(task_id)["stage"] == Stage.DEVELOPMENT
    assert store.task(task_id)["state"] == State.QUEUED
    development = await runner.run(task_id)
    assert store.task(task_id)["state"] == State.WAITING_DEPENDENCY
    runs = store.runs(task_id)
    assert len({r["thread_id"] for r in runs}) == 2
    assert len({r["worktree"] for r in runs}) == 2
    assert (repo / "sample.txt").read_text() == "original\n"
    analyst = json.loads((store.root / "runs" / analysis / "context.json").read_text())
    developer = json.loads((store.root / "runs" / development / "context.json").read_text())
    assert analyst["confirmed_analysis"] is None
    assert developer["confirmed_analysis"]["basis"] == ["sample.txt was inspected"]
    assert "Only work on the registered task" in analyst["repository_instructions"]
    assert not (store.root / "logs" / f"{analysis}.jsonl").read_text().find("ended") == -1


@pytest.mark.parametrize(
    "source,expected",
    [
        ("import sys; sys.stdin.readline(); sys.exit(7)", State.FAILED),
        ("import sys,time; sys.stdin.readline(); time.sleep(60)", State.FAILED),
        (SUCCESS.replace("request['context']['target_sha']", "'0'*40"), State.RECONCILE),
    ],
)
async def test_exit_timeout_and_wrong_sha_are_recorded(
    store,
    task_id,
    snapshot,
    auth_file,
    monkeypatch,
    source,
    expected,
):
    install_worker(monkeypatch, source)
    runner = Runner(store, Config(auth_file=auth_file, timeout_seconds=1), ReadOnlyGitHub(snapshot))
    await runner.run(task_id)
    assert store.task(task_id)["state"] == expected
    assert store.task(task_id)["stage"] == Stage.ANALYSIS
    assert store.runs(task_id)[0]["ended"] is not None


async def test_cancel_silent_process_records_cancel_and_ends_process(
    store,
    task_id,
    snapshot,
    auth_file,
    monkeypatch,
):
    install_worker(monkeypatch, "import sys,time; sys.stdin.readline(); time.sleep(60)")
    ready = asyncio.Event()
    original = Sandbox.verify

    async def verify(self, repo):
        evidence = await original(self, repo)
        ready.set()
        return evidence

    monkeypatch.setattr(Sandbox, "verify", verify)
    future = asyncio.create_task(
        Runner(store, Config(auth_file=auth_file), ReadOnlyGitHub(snapshot)).run(task_id)
    )
    await asyncio.wait_for(ready.wait(), timeout=5)
    store.cancel(task_id)
    await asyncio.wait_for(future, timeout=5)
    assert store.task(task_id)["state"] == State.CANCELLED
    assert store.runs(task_id)[0]["state"] == State.CANCELLED


async def test_failed_isolation_never_starts_sdk(store, task_id, snapshot, auth_file, monkeypatch):
    async def reject(*_):
        raise IsolationError("negative test: permissions not verified")

    monkeypatch.setattr(Sandbox, "verify", reject)
    await Runner(store, Config(auth_file=auth_file), ReadOnlyGitHub(snapshot)).run(task_id)
    assert store.task(task_id)["state"] == State.WAITING_ENVIRONMENT
    assert store.runs(task_id)[0]["thread_id"] is None


async def test_remote_read_failure_after_execution_cannot_advance(
    store,
    task_id,
    snapshot,
    auth_file,
    monkeypatch,
):
    class FailingRead(ReadOnlyGitHub):
        calls = 0

        async def snapshot(self, target):
            self.calls += 1
            if self.calls > 1:
                raise RuntimeError("GitHub unavailable")
            return await super().snapshot(target)

    install_worker(monkeypatch, SUCCESS)
    await Runner(store, Config(auth_file=auth_file), FailingRead(snapshot)).run(task_id)
    assert store.task(task_id)["stage"] == Stage.ANALYSIS
    assert store.task(task_id)["state"] == State.FAILED


@pytest.mark.parametrize("failure", ["run_directory", "log_sink"])
async def test_initialization_failures_have_terminal_records(
    store,
    task_id,
    snapshot,
    auth_file,
    monkeypatch,
    failure,
):
    if failure == "run_directory":
        (store.root / "runs").write_text("blocking file")
    else:

        def broken_sink(self, kind, data, *, controller=False):
            raise PermissionError("log sink unavailable")

        monkeypatch.setattr(Journal, "emit", broken_sink)
    await Runner(store, Config(auth_file=auth_file), ReadOnlyGitHub(snapshot)).run(task_id)
    assert store.task(task_id)["state"] == State.WAITING_ENVIRONMENT
    assert store.runs(task_id)[0]["ended"] is not None
    if failure == "log_sink":
        assert "log sink unavailable" in store.task(task_id)["reason"]


async def test_closing_remote_object_during_execution_stops_advancement(
    store,
    task_id,
    snapshot,
    auth_file,
    monkeypatch,
):
    class ClosingObject(ReadOnlyGitHub):
        calls = 0

        async def snapshot(self, target):
            self.calls += 1
            return self.value | ({"state": "closed"} if self.calls > 1 else {})

    install_worker(monkeypatch, SUCCESS)
    await Runner(store, Config(auth_file=auth_file), ClosingObject(snapshot)).run(task_id)
    assert store.task(task_id)["stage"] == Stage.ANALYSIS
    assert store.task(task_id)["state"] == State.HUMAN


async def test_base_change_during_execution_rejects_old_analysis(
    store, task_id, snapshot, auth_file, sha, monkeypatch
):
    class MovingBase(ReadOnlyGitHub):
        calls = 0

        async def snapshot(self, target):
            self.calls += 1
            return self.value | ({"base_sha": "0" * 40} if self.calls > 1 else {})

    # The first base exists locally, so context creation needs no network fetch.
    github = MovingBase(snapshot | {"base_sha": sha})
    install_worker(monkeypatch, SUCCESS)
    await Runner(store, Config(auth_file=auth_file), github).run(task_id)
    assert store.task(task_id)["stage"] == Stage.ANALYSIS
    assert store.task(task_id)["state"] == State.RECONCILE
    assert not store.runs(task_id)[0]["evidence_valid"]


async def test_closed_remote_object_never_starts_a_worker(store, task_id, snapshot, auth_file):
    runner = Runner(
        store, Config(auth_file=auth_file), ReadOnlyGitHub(snapshot | {"state": "closed"})
    )
    with pytest.raises(ValueError):
        await runner.run(task_id)
    assert store.task(task_id)["state"] == State.HUMAN
    assert not store.runs(task_id)


@pytest.mark.parametrize("change", [{"base_sha": "0" * 40}, {"head_sha": "1" * 40}])
async def test_version_change_before_claim_cannot_accept_stale_context(
    store, task_id, snapshot, auth_file, monkeypatch, change
):
    original = store.begin_run

    def sync_before_claim(number, role, **kwargs):
        store.sync(number, snapshot | change)
        return original(number, role, **kwargs)

    monkeypatch.setattr(store, "begin_run", sync_before_claim)
    with pytest.raises(ValueError, match="snapshot changed before claim"):
        await Runner(store, Config(auth_file=auth_file), ReadOnlyGitHub(snapshot)).run(task_id)
    assert not store.runs(task_id)
    assert store.task(task_id)["stage"] == Stage.ANALYSIS


@pytest.mark.parametrize(
    "source",
    [
        "raise SystemExit(7)",
        "import sys; sys.stdin.readline(); print('invalid-json', flush=True); "
        "sys.stdout.write('x' * 4_194_304); sys.stdout.flush()",
    ],
)
async def test_worker_errors_release_all_pipes_before_returning(
    store, task_id, snapshot, auth_file, monkeypatch, source
):
    install_worker(monkeypatch, source)
    created = []
    spawn = asyncio.create_subprocess_exec

    async def capture(*args, **kwargs):
        process = await spawn(*args, **kwargs)
        created.append(process)
        return process

    monkeypatch.setattr(asyncio, "create_subprocess_exec", capture)
    try:
        await asyncio.wait_for(
            Runner(store, Config(auth_file=auth_file), ReadOnlyGitHub(snapshot)).run(task_id),
            timeout=6,
        )
        assert store.task(task_id)["state"] == State.FAILED
        for process in created:
            assert process.returncode is not None
            assert process.stdout.at_eof()
            assert process.stderr.at_eof()
    finally:
        for process in created:
            if process.returncode is None:
                process.kill()
            await process.communicate()


async def test_uncertain_cleanup_cannot_advance_or_leave_a_completed_run(
    store, task_id, snapshot, auth_file, monkeypatch
):
    from gongcao.processes import stop

    async def uncertain(process, readers):
        await stop(process, readers)
        raise CleanupError("Local pipes closed; descendant exit could not be confirmed")

    install_worker(monkeypatch, SUCCESS)
    monkeypatch.setattr("gongcao.runner.stop", uncertain)
    await Runner(store, Config(auth_file=auth_file), ReadOnlyGitHub(snapshot)).run(task_id)
    assert store.task(task_id)["stage"] == Stage.ANALYSIS
    assert store.task(task_id)["state"] == State.RECONCILE
    assert store.runs(task_id)[0]["state"] == State.RECONCILE
