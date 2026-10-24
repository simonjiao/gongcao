import asyncio
import json
import sys

import pytest

from gongcao.config import Config
from gongcao.events import Journal
from gongcao.github import GitHub
from gongcao.model import Stage, State
from gongcao.runner import Runner
from gongcao.sandbox import IsolationError, Sandbox


class ReadOnlyGitHub(GitHub):
    def __init__(self, snapshot):
        self.value = snapshot

    async def snapshot(self, target):
        return dict(self.value)


def install_worker(monkeypatch, source):
    original = Sandbox.argv

    def argv(self, *payload):
        if payload[1:3] == ("-m", "gongcao.worker"):
            payload = (sys.executable, "-c", source)
        return original(self, *payload)

    monkeypatch.setattr(Sandbox, "argv", argv)


SUCCESS = """
import json,sys,pathlib
request = json.loads(sys.stdin.readline())
if request['writable']:
    pathlib.Path('/workspace/sample.txt').write_text('changed in worktree\\n')
print(json.dumps({'kind':'thread','data':{'thread_id':request['context']['role']+'-thread'}}))
print(json.dumps({'kind':'result','data':{
    'conclusion':'ready','summary':'Inspected the assigned revision',
    'basis':['sample.txt was inspected'],'target_sha':request['context']['target_sha'],
    'next_steps':['Run validation']}}))
"""


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

        def broken_sink(*_):
            raise PermissionError("log sink unavailable")

        monkeypatch.setattr(Journal, "emit", broken_sink)
    await Runner(store, Config(auth_file=auth_file), ReadOnlyGitHub(snapshot)).run(task_id)
    assert store.task(task_id)["state"] == State.WAITING_ENVIRONMENT
    assert store.runs(task_id)[0]["ended"] is not None


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
