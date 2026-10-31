import pytest

from gongcao.github import Deferred, GitHub
from gongcao.model import State
from gongcao.remote import Controlled, UncertainWrite
from gongcao.store import Store
from gongcao.workflow import Workflow


async def test_writes_require_verified_os_isolation(
    store, task_id, fixture_github, policy, monkeypatch
):
    from gongcao.sandbox import IsolationError

    async def reject(*args):
        raise IsolationError("Cannot verify isolation")

    monkeypatch.setattr("gongcao.remote.Sandbox.verify", reject)
    await Workflow(store, policy, fixture_github).run(task_id)
    assert store.task(task_id)["state"] == State.WAITING_ENVIRONMENT
    assert fixture_github.writes == []


@pytest.mark.parametrize(
    "result", ["observed", "unknown", "query", "gate", "rejected", "readback_limit"]
)
async def test_ambiguous_write_queries_remote_and_never_replays(
    store, task_id, policy, monkeypatch, result
):
    controlled = Controlled(store, policy, GitHub())

    async def before(task, kind, *, finish_operation=False, verified=None):
        if result == "gate" and finish_operation and calls == 0:
            raise Deferred("limited before write")
        return task

    monkeypatch.setattr(controlled, "before", before)
    observed = None
    calls = 0

    async def query():
        if result == "readback_limit" and calls:
            raise Deferred("Readback limited after write")
        if result == "query" and calls == 0:
            raise Deferred("limited before intent")
        return observed

    async def write():
        nonlocal observed, calls
        calls += 1
        if result == "rejected" and calls == 1:
            raise Deferred("HTTP 429: write rejected")
        if result == "observed":
            observed = {"id": 7}
        if result == "readback_limit":
            return {}
        raise RuntimeError("lost response")

    task = store.task(task_id)
    if result == "readback_limit":
        with pytest.raises(Deferred):
            await controlled.perform(task, "review", "9", {}, query, write)
        assert store.evidence(task_id)["operations"][0]["state"] == "unknown"
        result = "unknown"  # Read transport recovers; the write still must not replay.
    if result in {"query", "gate", "rejected"}:
        with pytest.raises(Deferred):
            await controlled.perform(task, "review", "9", {}, query, write)
        assert store.evidence(task_id)["operations"] == []
        result, calls = "observed", 0  # Fresh checks authorize the first write after cooling.
    if result == "observed":
        assert await controlled.perform(task, "review", "9", {}, query, write) == {"id": 7}
        assert await controlled.perform(task, "review", "9", {}, query, write) == {"id": 7}
    else:
        with pytest.raises(UncertainWrite):
            await controlled.perform(task, "review", "9", {}, query, write)
        with pytest.raises(UncertainWrite, match="refusing replay"):
            await controlled.perform(task, "review", "9", {}, query, write)
    assert calls == 1


def test_write_intent_survives_restart_and_rejects_changed_payload(store, task_id):
    task = store.task(task_id)
    assert store.intent(task, "key", "push", "payload")
    reopened = Store(store.root)
    try:
        assert not reopened.intent(task, "key", "push", "payload")
        with pytest.raises(ValueError, match="conflicts"):
            reopened.intent(task, "key", "push", "different")
        reopened.operation_result("key", "unknown", None)
    finally:
        reopened.close()
    assert store.operation("key")["state"] == "unknown"


def test_remote_change_does_not_resume_an_unconfirmed_write(store, task_id, snapshot):
    task = store.task(task_id)
    store.intent(task, "unknown-key", "push", "{}")
    store.operation_result("unknown-key", "unknown", None)
    store.halt(task_id, State.RECONCILE, "Write needs reconciliation")
    store.sync(task_id, snapshot | {"head_sha": "f" * 40})
    assert store.task(task_id)["state"] == State.RECONCILE
    assert store.operation("unknown-key")["state"] == "unknown"
