"""Advisory SDK protocol substitutes execute inside the real read-only OS sandbox."""

import asyncio
import json
from dataclasses import replace

import pytest
from _support.worker import install_worker

from gongcao.coordination import Coordinator, current
from gongcao.model import Role, Stage, State


@pytest.fixture
def complex_task(store, task_id, sha):
    store.transition(store.task(task_id), Stage.DEVELOPMENT, State.QUEUED, "analysis confirmed")
    for _ in range(3):
        store.halt(task_id, State.QUEUED, "retry")
        run = store.begin_run(task_id, Role.DEVELOPER)
        store.run_details(run, source={"sha": sha})
        store.finish(
            run,
            State.COMPLETED,
            Stage.DEVELOPMENT,
            State.HUMAN,
            "No progress",
            json.dumps(
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
    store, task_id, complex_task, fixture_github, policy, monkeypatch
):
    install_worker(
        monkeypatch, ADVICE.replace("HOST_STATE", repr(str(store.root / "gongcao.sqlite3")))
    )
    before = store.task(task_id), store.runs(task_id), list(fixture_github.writes)
    coordinator = Coordinator(store, policy, fixture_github)
    result = await coordinator.run(task_id)
    assert result["status"] == "completed", result
    assert "secret123" not in json.dumps(result)
    assert before == (store.task(task_id), store.runs(task_id), fixture_github.writes)
    assert await coordinator.run(task_id) == result
    assert current(store, task_id) == result
    store.sync(task_id, store.task(task_id)["snapshot"] | {"body": "Changed requirements"})
    assert current(store, task_id) is None
    assert (await coordinator.run(task_id))["fingerprint"] != result["fingerprint"]


@pytest.mark.parametrize("failure", ["invalid", "timeout", "cancel"])
async def test_advisory_failure_or_cancellation_does_not_change_business_state(
    store, task_id, complex_task, fixture_github, policy, monkeypatch, failure
):
    source = "import sys,time;sys.stdin.readline();" + (
        "print('invalid')" if failure == "invalid" else "time.sleep(60)"
    )
    install_worker(monkeypatch, source)
    before = store.task(task_id), store.runs(task_id)
    pending = asyncio.create_task(
        Coordinator(store, replace(policy, timeout_seconds=1), fixture_github).run(task_id)
    )
    if failure == "cancel":
        for _ in range(100):
            if store.db.execute("SELECT 1 FROM artifacts WHERE kind='coordination'").fetchone():
                break
            await asyncio.sleep(0.01)
        pending.cancel()
        with pytest.raises(asyncio.CancelledError):
            await pending
    else:
        assert (await pending)["status"] == "failed"
    assert before == (store.task(task_id), store.runs(task_id))
    assert current(store, task_id)["status"] in {"failed", "cancelled"}
    assert (await Coordinator(store, policy, fixture_github).run(task_id))["status"] in {
        "failed",
        "cancelled",
    }


async def test_simple_blocks_do_not_launch_advisory_models(
    store, task_id, fixture_github, policy, monkeypatch
):
    async def forbidden(*args, **kwargs):
        pytest.fail("A simple block must use deterministic feedback")

    monkeypatch.setattr("gongcao.runner.Runner.session", forbidden)
    for state, reason in [
        (State.HUMAN, "Missing package"),
        (State.WAITING_DEPENDENCY, "CI pending"),
        (State.RECONCILE, "Unknown write"),
        (State.RUNNING, "No event for 30 minutes"),
    ]:
        store.halt(task_id, state, reason)
        assert (await Coordinator(store, policy, fixture_github).run(task_id))[
            "status"
        ] == "no_complex_block"
