import json
from dataclasses import replace
from unittest.mock import AsyncMock

import pytest

from gongcao.github import Deferred
from gongcao.model import Stage, State
from gongcao.quality import Quality
from gongcao.scheduler import Scheduler
from gongcao.workflow import Workflow


async def test_worktrees_review_revision_and_quality_reach_human_merge(
    store, task_id, repo, fixture_github, policy, caplog, monkeypatch
):
    caplog.set_level("INFO", logger="gongcao")
    original, limited = Quality.run, []

    async def quality(self, task, **kwargs):
        checks = await original(self, task, **kwargs)
        if task["stage"] == Stage.REVIEW and task["revision_count"] and not limited:
            limited.append(checks["run_id"])
            fixture_github.traffic.cooldown = 2_000_000_000
            raise Deferred("after quality")
        return checks

    monkeypatch.setattr(Quality, "run", quality)
    await Workflow(store, policy, fixture_github).run(task_id)
    assert limited and store.task(task_id)["state"] == State.QUEUED
    fixture_github.traffic.cooldown = 0
    scheduler = Scheduler(store, policy, fixture_github)  # Reload persisted cooldown.
    await scheduler.advance(task_id)
    assert fixture_github.traffic.cooldown == 2_000_000_000
    assert store.task(task_id)["state"] == State.QUEUED
    monkeypatch.setattr("gongcao.github.time.time", lambda: 2_000_000_001.0)
    await scheduler.advance(task_id)
    assert store.db.execute("SELECT COUNT(*) FROM retries").fetchone()[0] == 0
    task = store.task(task_id)
    assert task["stage"] == Stage.MERGEABLE, task["reason"]
    assert task["state"] == State.COMPLETED
    assert task["revision_count"] == 1
    assert task["pr_number"] == 9
    # One Workflow call crosses every stage; polling only at its end would miss these.
    for stage in ("分析", "开发", "修订", "审查", "验证", "等待人工合并"):
        assert f"阶段：{stage}" in caplog.text
    assert "质量结果：通过" in caplog.text and "Agent developer 结束" in caplog.text
    assert "PR 已远端确认：https://github.com/example/demo/pull/9" in caplog.text
    assert "Inspected the exact worktree" not in caplog.text  # Raw reports stay private.
    assert (repo / "sample.txt").read_text() == "original\n"
    runs = store.runs(task_id)
    assert [r["role"] for r in runs] == [
        "analyst",
        "developer",
        "analyst",
        "reviewer",
        "developer",
        "analyst",
        "reviewer",
        "validator",
    ]
    assert len({r["thread_id"] for r in runs}) == 8
    assert len({r["worktree"] for r in runs}) == 8
    assert not [r for r in runs if r["target_sha"] != task["target_sha"] and r["evidence_valid"]]
    assert all(
        payload["event"] == "COMMENT"
        for path, payload in fixture_github.writes
        if path.endswith("/reviews")
    )
    assert len(fixture_github.reviews) == 2 and len(fixture_github.writes) == 3
    assert (
        store.db.execute('SELECT count(*) FROM operations WHERE state="succeeded"').fetchone()[0]
        == 6
    )
    context = json.loads((store.root / "runs" / runs[3]["id"] / "context.json").read_text())
    assert context["confirmed_analysis"] is None
    assert context["quality_evidence"]["passed"]
    assert context["diff"]["head_sha"] == runs[3]["target_sha"]
    checks = await Quality(store, policy).run(task, include_e2e=True)
    assert checks["passed"] and checks["run_id"] == limited[0]
    # Repeating the command neither calls a new agent nor duplicates any remote mutation.
    writes = len(fixture_github.writes)
    assert await Workflow(store, policy, fixture_github).run(task_id) == []
    assert len(fixture_github.writes) == writes
    run = AsyncMock()
    monkeypatch.setattr(Workflow, "run", run)
    for _ in range(3):
        await scheduler.advance(task_id, immediate=False)
    run.assert_not_awaited()


@pytest.mark.parametrize("blocker", ["formal_approval", "revision_limit"])
async def test_missing_external_evidence_cannot_be_replaced_by_agent_claims(
    store, task_id, fixture_github, policy, blocker
):
    if blocker == "formal_approval":
        fixture_github.decision = "REVIEW_REQUIRED"
    if blocker == "revision_limit":
        policy = replace(policy, max_revisions=0)
    await Workflow(store, policy, fixture_github).run(task_id)
    task = store.task(task_id)
    assert task["stage"] != Stage.MERGEABLE
    assert task["state"] == (
        State.HUMAN if blocker == "revision_limit" else State.WAITING_DEPENDENCY
    ), task["reason"]
    assert not fixture_github.reviews or all(
        r["event"] == "COMMENT" for r in fixture_github.reviews
    )


async def test_policy_change_rebuilds_review_and_validation_at_same_sha(
    store, task_id, fixture_github, policy
):
    await Workflow(store, policy, fixture_github).run(task_id)
    old = [r["id"] for r in store.runs(task_id) if r["role"] == "reviewer" and r["evidence_valid"]]
    sha = store.task(task_id)["target_sha"]
    changed = replace(
        policy,
        model="changed-policy",
        max_revisions=0,
    )
    await Workflow(store, changed, fixture_github).run(task_id)
    assert (store.task(task_id)["stage"], store.task(task_id)["state"]) == (
        Stage.MERGEABLE,
        State.COMPLETED,
    )
    assert store.task(task_id)["target_sha"] == sha
    assert len(fixture_github.reviews) == 3
    assert not [r for r in store.runs(task_id) if r["id"] in old and r["evidence_valid"]]
    assert store.artifact(task_id, "validation", policy.policy_hash) is None


@pytest.mark.parametrize(
    "change", ["head_after_ready", "base_after_ready", "head_after_review", "merged"]
)
async def test_refresh_never_relabels_old_evidence_or_overwrites_merged(
    store, task_id, fixture_github, policy, change, monkeypatch
):
    workflow = Workflow(store, policy, fixture_github)
    operation = "review" if change == "head_after_review" else "ready"
    original = getattr(workflow.remote, operation)

    async def changed(*args, **kwargs):
        await original(*args, **kwargs)
        if change == "merged":
            fixture_github.pull.update(merged=True, state="closed")
        elif change == "base_after_ready":
            fixture_github.pull["base_sha"] = "b" * 40
        else:
            fixture_github.head_override = "f" * 40

    monkeypatch.setattr(workflow.remote, operation, changed)
    await workflow.run(task_id)
    task = store.task(task_id)
    assert task["stage"] == (Stage.MERGED if change == "merged" else Stage.ANALYSIS), task["reason"]
    assert task["state"] == (State.COMPLETED if change == "merged" else State.RECONCILE), task[
        "reason"
    ]
    assert store.artifact(task_id, "validation", policy.policy_hash) is None
    assert store.artifact(task_id, "revision", policy.policy_hash) is None
