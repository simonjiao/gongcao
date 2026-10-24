import json

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


def test_result_requires_version_and_evidence(sha):
    with pytest.raises(ValueError):
        AgentResult.model_validate(json.loads(result(sha).model_dump_json()) | {"basis": []})
