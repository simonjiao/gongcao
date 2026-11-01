"""Advisory SDK protocol substitutes execute inside the real read-only OS sandbox."""

import asyncio
import json
from dataclasses import replace

import pytest
from _support.worker import install_worker

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
def complex_task(store, task_id, sha, request):
    return seed_complex(store, task_id, sha, getattr(request, "param", False))


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


@pytest.mark.parametrize("complex_task", [False, True], indirect=True)
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
    assert before == (store.task(task_id), store.runs(task_id), fixture_github.writes)
    assert await coordinator.run(task_id) == result
    assert current(store, task_id) == result
    row = store.db.execute(
        "SELECT id,data FROM artifacts WHERE task_id=? AND kind='coordination' AND valid=1",
        (task_id,),
    ).fetchone()
    with store.db:
        store.db.execute(
            "UPDATE artifacts SET data=? WHERE id=?",
            (json.dumps(result | {"status": "running"}), row["id"]),
        )
    assert current(store, task_id) is None  # Legacy pre-spawn result is not reusable.
    with store.db:
        store.db.execute("UPDATE artifacts SET data=? WHERE id=?", (row["data"], row["id"]))
    other = snapshot | {"number": 2, "url": snapshot["url"][:-1] + "2"}
    sibling = store.register(other["url"], repo, sha, other)
    seed_complex(store, sibling, sha)
    assert (await coordinator.run())["binding"]["task"] == sibling
    store.sync(task_id, store.task(task_id)["snapshot"] | {"body": "Changed requirements"})
    assert current(store, task_id) is None
    assert (await coordinator.run(task_id))["fingerprint"] != result["fingerprint"]


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
    store.sync(task_id, store.task(task_id)["snapshot"] | {"body": "changed request"})
    assert (await coordinator.run(task_id))["status"] == "needs_reconciliation"


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
        reservation = store.root / "coordination-process.json"
        for _ in range(500):
            if reservation.exists() and json.loads(reservation.read_text()).get("state") == "running":
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
    assert current(store, task_id)["status"] in {"failed", "cancelled"}
    reservation = json.loads((store.root / "coordination-process.json").read_text())
    expected = (
        current(store, task_id)["status"]
        if reservation["state"] == "stopped"
        else "needs_reconciliation"
    )
    assert (await Coordinator(store, policy, fixture_github).run(task_id))["status"] == expected


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
