import json
import threading
from concurrent.futures import ThreadPoolExecutor

import pytest

from gongcao.model import AgentResult, Role, Stage, State, after_run
from gongcao.store import Store


def result(sha, conclusion="ready"):
    return AgentResult(
        conclusion=conclusion,
        summary="Inspected sample.txt",
        basis=["sample.txt exists at target revision"],
        target_sha=sha,
        next_steps=["Add a test"],
    )


def test_analysis_can_queue_development_but_code_alone_cannot_pass_pr_gate(sha):
    assert after_run(Stage.ANALYSIS, Role.ANALYST, result(sha), sha)[:2] == (
        Stage.DEVELOPMENT,
        State.QUEUED,
    )
    assert after_run(Stage.DEVELOPMENT, Role.DEVELOPER, result(sha), sha)[:2] == (
        Stage.DEVELOPMENT,
        State.WAITING_DEPENDENCY,
    )


def test_wrong_sha_and_blocked_result_never_advance(sha):
    assert after_run(Stage.ANALYSIS, Role.ANALYST, result("0" * 40), sha)[:2] == (
        Stage.ANALYSIS,
        State.RECONCILE,
    )
    assert after_run(Stage.ANALYSIS, Role.ANALYST, result(sha, "blocked"), sha)[:2] == (
        Stage.ANALYSIS,
        State.HUMAN,
    )


def test_only_one_controller_can_claim_a_task(store, task_id):
    store.begin_run(task_id, Role.ANALYST)
    second = Store(store.root)
    try:
        with pytest.raises(ValueError, match="running"):
            second.begin_run(task_id, Role.ANALYST)
    finally:
        second.close()


def test_registration_is_idempotent(store, task_id, repo, sha, snapshot):
    assert store.register(snapshot["url"], repo, sha, snapshot) == task_id
    assert len(store.tasks()) == 1
    assert store.db.execute("PRAGMA journal_mode").fetchone()[0] == "wal"


def test_cancellation_wins_over_late_success(store, task_id, sha):
    run_id = store.begin_run(task_id, Role.ANALYST)
    store.cancel(task_id)
    store.finish(
        run_id,
        State.COMPLETED,
        Stage.DEVELOPMENT,
        State.QUEUED,
        "ok",
        result(sha).model_dump_json(),
    )
    assert store.task(task_id)["state"] == State.CANCELLED
    assert store.task(task_id)["stage"] == Stage.ANALYSIS
    assert store.runs(task_id)[0]["state"] == State.CANCELLED


@pytest.mark.parametrize("change", [{"head_sha": "0" * 40}, {"body": "New requirements"}])
def test_remote_change_invalidates_inflight_evidence(store, task_id, snapshot, sha, change):
    run_id = store.begin_run(task_id, Role.ANALYST)
    store.sync(task_id, snapshot | change)
    store.finish(
        run_id,
        State.COMPLETED,
        Stage.DEVELOPMENT,
        State.QUEUED,
        "ok",
        result(sha).model_dump_json(),
    )
    assert store.task(task_id)["stage"] == Stage.ANALYSIS
    assert store.task(task_id)["state"] == State.RECONCILE
    assert not store.runs(task_id)[0]["evidence_valid"]


def test_remote_change_does_not_resume_cancelled_task(store, task_id, snapshot):
    store.cancel(task_id)
    store.sync(task_id, snapshot | {"head_sha": "0" * 40})
    assert store.task(task_id)["state"] == State.CANCELLED


@pytest.mark.parametrize("field", ["base_sha", "base_ref", "base_repository"])
@pytest.mark.parametrize("inflight", [False, True])
def test_pr_base_change_invalidates_evidence_with_unchanged_head(
    store, task_id, snapshot, sha, field, inflight
):
    original = snapshot | {
        "head_sha": sha,
        "base_sha": "1" * 40,
        "base_ref": "main",
        "base_repository": "example/demo",
    }
    store.sync(task_id, original)
    run_id = store.begin_run(task_id, Role.ANALYST)
    if not inflight:
        store.finish(run_id, State.COMPLETED, Stage.DEVELOPMENT, State.QUEUED, "ok")
    changed = "2" * 40 if field == "base_sha" else "different-target"
    store.sync(task_id, original | {field: changed})
    if inflight:
        store.finish(run_id, State.COMPLETED, Stage.DEVELOPMENT, State.QUEUED, "late result")
    task = store.task(task_id)
    assert task["target_sha"] == sha
    assert task["stage"] == Stage.ANALYSIS
    assert task["state"] == (State.RECONCILE if inflight else State.QUEUED)
    assert not store.runs(task_id)[0]["evidence_valid"]


@pytest.mark.parametrize("phase", ["queued", "running", "waiting_dependency"])
def test_closed_object_stops_progress_and_invalidates_evidence(store, task_id, snapshot, phase):
    if phase != "queued":
        run_id = store.begin_run(task_id, Role.ANALYST)
        if phase == "waiting_dependency":
            store.finish(run_id, State.COMPLETED, Stage.DEVELOPMENT, State.WAITING_DEPENDENCY, "ok")
    store.sync(task_id, snapshot | {"state": "closed"})
    assert store.task(task_id)["state"] == State.HUMAN
    assert all(not run["evidence_valid"] for run in store.runs(task_id))
    if phase == "running":
        store.finish(run_id, State.COMPLETED, Stage.DEVELOPMENT, State.QUEUED, "late result")
        assert store.task(task_id)["state"] == State.HUMAN
        assert store.task(task_id)["stage"] == Stage.ANALYSIS
    with pytest.raises(ValueError):
        store.begin_run(task_id, Role.ANALYST)


@pytest.mark.parametrize("inflight", [False, True])
def test_reopened_object_needs_manual_handling_and_cannot_reuse_old_result(
    store, task_id, snapshot, inflight
):
    run_id = store.begin_run(task_id, Role.ANALYST)
    if not inflight:
        store.finish(run_id, State.COMPLETED, Stage.DEVELOPMENT, State.QUEUED, "ok")
    store.sync(task_id, snapshot | {"state": "closed"})
    store.sync(task_id, snapshot | {"title": "Reopened request"})
    # A later content update must not implicitly clear the manual handling state either.
    store.sync(task_id, snapshot | {"title": "Updated reopened request"})
    if inflight:
        store.finish(run_id, State.COMPLETED, Stage.DEVELOPMENT, State.QUEUED, "late result")
    assert store.task(task_id)["state"] == State.HUMAN
    assert store.task(task_id)["stage"] == Stage.ANALYSIS
    assert not store.runs(task_id)[0]["evidence_valid"]


def test_registering_closed_object_never_queues_it(store, repo, sha, snapshot):
    task_id = store.register(snapshot["url"], repo, sha, snapshot | {"state": "closed"})
    assert store.task(task_id)["state"] == State.HUMAN
    with pytest.raises(ValueError):
        store.begin_run(task_id, Role.ANALYST)
    assert not store.runs(task_id)


def test_cancelled_object_stays_cancelled_across_close_and_reopen(store, task_id, snapshot):
    store.cancel(task_id)
    store.sync(task_id, snapshot | {"state": "closed"})
    store.sync(task_id, snapshot | {"body": "Changed after reopening"})
    assert store.task(task_id)["state"] == State.CANCELLED


def test_result_requires_version_and_evidence(sha):
    with pytest.raises(ValueError):
        AgentResult.model_validate(json.loads(result(sha).model_dump_json()) | {"basis": []})


def test_concurrent_cancel_cannot_be_overwritten_by_finish(store, task_id, monkeypatch):
    run_id = store.begin_run(task_id, Role.ANALYST)
    read = threading.Event()
    attempted = threading.Event()
    cancelled = threading.Event()
    connected = threading.Event()
    original = store.task

    def pause_after_read(number):
        task = original(number)
        read.set()
        assert attempted.wait(2)
        cancelled.wait(0.2)  # Cancellation must wait for finish's SQLite write transaction.
        return task

    def cancel_in_other_connection():
        other = Store(store.root)
        connected.set()
        assert read.wait(2)
        attempted.set()
        try:
            other.cancel(task_id)
            cancelled.set()
        finally:
            other.close()

    with ThreadPoolExecutor(max_workers=1) as pool:
        future = pool.submit(cancel_in_other_connection)
        assert connected.wait(2)
        monkeypatch.setattr(store, "task", pause_after_read)
        store.finish(run_id, State.COMPLETED, Stage.DEVELOPMENT, State.QUEUED, "ok")
        monkeypatch.setattr(store, "task", original)
        future.result(timeout=5)
    assert store.task(task_id)["state"] == State.CANCELLED
