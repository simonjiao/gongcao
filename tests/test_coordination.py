"""Advisory SDK protocol substitutes execute inside the real read-only OS sandbox."""

import asyncio
import json
import time
from dataclasses import replace
from pathlib import Path

import pytest
from _support.worker import install_worker

from gongcao.control import Controls
from gongcao.coordination import Coordinator, current
from gongcao.model import Role, Stage, State
from gongcao.processes import CleanupError, observer, stop


def seed_complex(store, task_id, sha, failed=False):
    store.transition(store.task(task_id), Stage.DEVELOPMENT, State.QUEUED, "analysis confirmed")
    for _ in range(3):
        store.halt(task_id, State.QUEUED, "retry")
        run = store.begin_run(task_id, Role.DEVELOPER)
        store.run_details(run, source={"sha": sha})
        store.finish(
            run,
            State.FAILED if failed else State.COMPLETED,
            Stage.DEVELOPMENT,
            State.HUMAN,
            "No progress",
            None
            if failed
            else json.dumps(
                {
                    "conclusion": "blocked",
                    "summary": "Repeated acceptance conflict",
                    "basis": ["evidence"],
                    "next_steps": ["resolve conflict"],
                    "target_sha": sha,
                }
            ),
        )
    return task_id


@pytest.fixture
def complex_task(store, task_id, sha):
    return seed_complex(store, task_id, sha)


ADVICE = """
import json,sys,pathlib
request=json.loads(sys.stdin.readline())
assert not request['writable'] and request['context']['role']=='coordinator'
try: pathlib.Path('/workspace/forbidden').write_text('forbidden')
except OSError: pass
else: raise AssertionError('workspace write escaped')
assert not pathlib.Path(HOST_STATE).exists()
print(json.dumps({'kind':'thread','data':{'thread_id':'advisory-session'}}))
print(json.dumps({'kind':'execution','data':{'model':request['model'],'reasoning_effort':request['reasoning_effort']}}))
print(json.dumps({'kind':'result','data':{
 'facts':['Run evidence: repeated blocked reports'], 'blockers':['Conflicting requirements'],
 'suggestions':[{'action':'Clarify requirements github_pat_secret123',
                 'owner':'task owner','inputs':['decision']}]
}}))
"""


async def test_coordination_isolated_advice_is_deduplicated_and_expires(
    store, task_id, complex_task, fixture_github, policy, monkeypatch, repo, sha, snapshot
):
    install_worker(
        monkeypatch, ADVICE.replace("HOST_STATE", repr(str(store.root / "gongcao.sqlite3")))
    )
    before = store.task(task_id), store.runs(task_id), list(fixture_github.writes)
    coordinator = Coordinator(store, policy, fixture_github)
    result = await coordinator.run(task_id)
    assert result["status"] == "completed", result
    assert "secret123" not in json.dumps(result)
    context = json.loads((Path(result["run_dir"]) / "context.json").read_text())["facts"]
    assert context["requirements"]["body"] == snapshot["body"]
    assert context["runs"][-1]["conclusion"] == "blocked"
    assert context["runs"][-1]["basis"] == ["evidence"]
    assert context["runs"][-1]["next_steps"] == ["resolve conflict"]
    assert before == (store.task(task_id), store.runs(task_id), fixture_github.writes)
    assert await coordinator.run(task_id) == result
    assert current(store, task_id) == result
    other = snapshot | {"number": 2, "url": snapshot["url"][:-1] + "2"}
    sibling = store.register(other["url"], repo, sha, other)
    seed_complex(store, sibling, sha, failed=True)
    assert (await coordinator.run())["binding"]["task"] == sibling
    store.sync(task_id, store.task(task_id)["snapshot"] | {"body": "Changed requirements"})
    assert current(store, task_id) is None
    assert (await coordinator.run(task_id))["fingerprint"] != result["fingerprint"]
    third = other | {"number": 3, "url": other["url"][:-1] + "3", "body": "Require API v2"}
    dependency = store.register(third["url"], repo, sha, third)
    store.sync(sibling, other | {"body": "Keep API v1 github_pat_secret123"})
    for tid in (sibling, dependency):
        store.halt(tid, State.HUMAN, "Owner must decide the API contract")
    store.depend(task_id, [sibling, dependency])
    store.halt(task_id, State.WAITING_DEPENDENCY, "Dependencies are not ready")
    result = await coordinator.run(task_id)  # Actual blocked dependencies, no conflict keyword.
    assert result["status"] == "completed"
    context = json.loads((Path(result["run_dir"]) / "context.json").read_text())["facts"]
    assert [d["requirements"]["body"] for d in context["dependencies"]] == [
        "Keep API v1 [REDACTED]",
        "Require API v2",
    ]
    assert "secret123" not in json.dumps(context)
    assert await coordinator.run(task_id) == result
    store.halt(dependency, State.COMPLETED, "Decision accepted")
    assert current(store, task_id) is None
    assert (await coordinator.run(task_id))["status"] == "no_complex_block"
    store.depend(task_id, [], clear=True)
    for feedback in ("Keep API v1", "Require API v2"):
        assert Controls(store).issue(task_id, "pause", feedback=feedback)
    store.halt(task_id, State.HUMAN, "需求与审查反馈冲突")
    result = await coordinator.run(task_id)
    assert result["status"] == "completed"
    context = json.loads((Path(result["run_dir"]) / "context.json").read_text())["facts"]
    assert [f["feedback"] for f in context["requirements"]["feedback"]] == [
        "Keep API v1",
        "Require API v2",
    ]


async def test_uncertain_advisory_cleanup_keeps_its_reservation_across_fact_changes(
    store, task_id, complex_task, fixture_github, policy, monkeypatch
):
    install_worker(
        monkeypatch, ADVICE.replace("HOST_STATE", repr(str(store.root / "gongcao.sqlite3")))
    )

    async def uncertain(process, readers):
        await stop(process, readers)
        observer.get().uncertain(process.pid)
        raise CleanupError("uncertain descendants")

    monkeypatch.setattr("gongcao.runner.stop", uncertain)
    coordinator = Coordinator(store, policy, fixture_github)
    assert (await coordinator.run(task_id))["status"] == "failed"
    assert (await coordinator.run(task_id))["status"] == "needs_reconciliation"
    store.sync(task_id, store.task(task_id)["snapshot"] | {"body": "changed request"})
    assert (await coordinator.run(task_id))["status"] == "needs_reconciliation"


@pytest.mark.parametrize("failure", ["timeout", "cancel"])
async def test_advisory_failure_or_cancellation_does_not_change_business_state(
    store, task_id, complex_task, fixture_github, policy, monkeypatch, failure
):
    install_worker(monkeypatch, "import sys,time;sys.stdin.readline();time.sleep(60)")
    before = store.task(task_id), store.runs(task_id)
    pending = asyncio.create_task(
        Coordinator(store, replace(policy, timeout_seconds=1), fixture_github).run(task_id)
    )
    if failure == "cancel":
        reservation = store.root / "coordination-process.json"
        for _ in range(500):
            if (
                reservation.exists()
                and json.loads(reservation.read_text()).get("state") == "running"
            ):
                break
            await asyncio.sleep(0.01)
        else:
            pytest.fail("Coordinator subprocess did not start")
        assert not store.db.execute(
            "SELECT 1 FROM artifacts WHERE kind='coordination'"
        ).fetchone()  # No cached 'running' result before the process settles.
        pending.cancel()
        with pytest.raises(asyncio.CancelledError):
            await pending
    else:
        assert (await pending)["status"] == "failed"
    assert before == (store.task(task_id), store.runs(task_id))
    failed = current(store, task_id)
    assert failed["status"] == ("failed" if failure == "timeout" else "cancelled")
    reservation = json.loads((store.root / "coordination-process.json").read_text())
    assert reservation["state"] == "stopped"
    coordinator = Coordinator(store, replace(policy, timeout_seconds=1), fixture_github)
    assert await coordinator.run(task_id) == failed  # Confirmed cleanup still observes backoff.
    monkeypatch.setattr("gongcao.coordination.time.time", lambda: failed["retry_at"] + 1)
    assert (await coordinator.run(task_id))["status"] == "failed"
    retried = current(store, task_id)
    assert retried["run_dir"] != failed["run_dir"] and retried["failures"] == 2
    assert retried["retry_at"] > time.time()
    monkeypatch.setattr("gongcao.coordination.time.time", lambda: retried["retry_at"] + 1)
    install_worker(
        monkeypatch, ADVICE.replace("HOST_STATE", repr(str(store.root / "gongcao.sqlite3")))
    )
    assert (await coordinator.run(task_id))["status"] == "completed"
    assert before == (store.task(task_id), store.runs(task_id))


async def test_simple_blocks_do_not_launch_advisory_models(
    store, task_id, complex_task, fixture_github, policy, monkeypatch, repo, sha, snapshot
):
    async def forbidden(*args, **kwargs):
        pytest.fail("A simple block must use deterministic feedback")

    monkeypatch.setattr("gongcao.runner.Runner.session", forbidden)
    dependencies = []
    for number in (2, 3):
        dependency = snapshot | {"url": snapshot["url"][:-1] + str(number), "number": number}
        dependencies.append(store.register(dependency["url"], repo, sha, dependency))
    store.depend(task_id, dependencies)
    for state, reason in [
        (State.HUMAN, "Missing package"),
        (State.WAITING_DEPENDENCY, "CI pending"),
        (State.WAITING_DEPENDENCY, "等待两个依赖完成"),
        (State.HUMAN, "冲突：缺少材料"),
        (State.RECONCILE, "Unknown write"),
        (State.RUNNING, "No event for 30 minutes"),
    ]:
        store.halt(task_id, state, reason)
        assert (await Coordinator(store, policy, fixture_github).run(task_id))[
            "status"
        ] == "no_complex_block"
    store.halt(task_id, State.WAITING_DEPENDENCY, "Waiting for merged dependencies")
    for tid in dependencies:
        store.sync(tid, store.task(tid)["snapshot"] | {"state": "closed"})
    assert (await Coordinator(store, policy, fixture_github).run(task_id))[
        "status"
    ] == "no_complex_block"  # Closed dependencies require deterministic lifecycle handling.
    for tid in dependencies:
        store.sync(tid, store.task(tid)["snapshot"] | {"state": "open"})
        store.halt(tid, State.QUEUED, "Retry environment check")
        run = store.begin_run(tid, Role.ANALYST)
        store.finish(run, State.FAILED, Stage.ANALYSIS, State.HUMAN, "Missing package")
        store.halt(tid, State.HUMAN, "Execution/environment failures; manual retry required")
    assert (await Coordinator(store, policy, fixture_github).run(task_id))[
        "status"
    ] == "no_complex_block"  # Run evidence retains the precise deterministic failure.
