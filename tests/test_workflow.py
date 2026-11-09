import json
from dataclasses import replace
from unittest.mock import AsyncMock

import pytest
from _support.worker import WORKER, install_worker

from gongcao.control import Controls
from gongcao.github import Deferred, command
from gongcao.model import Stage, State
from gongcao.quality import Quality
from gongcao.scheduler import Scheduler
from gongcao.workflow import Workflow


@pytest.mark.parametrize(
    "acceptance", ["documentation", "required_entry", "required_e2e", "conflict"]
)
async def test_documentation_workflow_preserves_acceptance_and_waits_without_retries(
    store, task_id, repo, fixture_github, policy, monkeypatch, acceptance
):
    instructions = (
        "Run pytest before every change, including documentation."
        if acceptance == "conflict"
        else "Documentation-only edits need independent document review."
    )
    (repo / "AGENTS.md").write_text(instructions + "\n")
    (repo / "pyproject.toml").write_text("[tool.ruff]\n[tool.mypy]\n[tool.pytest.ini_options]\n")
    await command("git", "add", ".", cwd=str(repo))
    await command("git", "commit", "-qm", "Document task baseline", cwd=str(repo))
    fixture_github.sha = (await command("git", "rev-parse", "HEAD", cwd=str(repo))).strip()
    fixture_github.issue.update(
        head_sha=fixture_github.sha,
        body="Update only AGENTS.md; inspect the document diff; do not run code tests.",
        labels=[{"name": "agent-ready"}],
    )
    if acceptance in {"required_entry", "required_e2e"}:
        fixture_github.issue["body"] += " A separate real acceptance entry is mandatory."
    store.sync(task_id, fixture_github.issue)
    worker = WORKER.replace(
        "sample.write_text('complete\\n' if data['confirmed_findings'] else 'incomplete\\n')",
        "p = pathlib.Path('/workspace/AGENTS.md'); p.write_text(p.read_text()+'Minimum tests.\\n')",
    )
    worker = worker.replace(
        "print(json.dumps({'kind':'thread'",
        f"""
if data.get('diff', {{}}).get('changed_files'):
    assert data['diff']['changed_files'] == ['AGENTS.md']
    assert all(i['required'] and not i['entry'] for i in data['validation_candidates'])
    for item in plan:
        item.update(required=False, entry=[], scope=['Issue', 'AGENTS.md'],
                    reason='Issue limits edits to docs; AGENTS requires document review')
    if {acceptance == "required_e2e"!r}:
        plan = [i for i in plan if i['category'] != 'e2e']  # Missing assessment cannot waive QA.
if role == 'analyst' and {acceptance == "required_entry"!r}:
    for item in plan:
        if item['category']=='internal':
            item.update(required=True, entry=[], reason='Issue requires a separate entry')
if role in ('reviewer','validator'):
    assert 'do not run code tests' in data['github']['body']
    assert {instructions!r} in data['repository_instructions']
    assert ({acceptance == "required_entry"!r} or
            not any(i.get('argv') for i in data['quality_evidence']['items']))
    if {acceptance == "conflict"!r}:
        conclusion = 'blocked'
print(json.dumps({{'kind':'thread'""",
    )
    install_worker(monkeypatch, worker)
    Controls(store).issue(task_id, "auto", policy=policy.policy_hash)
    scheduler = Scheduler(store, policy, fixture_github)
    await scheduler.advance(task_id)
    task = store.task(task_id)
    assert not list((store.root / "worktrees").glob("check-*"))
    if acceptance == "conflict":
        assert task["stage"] == Stage.REVIEW and task["state"] == State.HUMAN
        assert not any(r["role"] == "validator" for r in store.runs(task_id))
    elif acceptance in {"required_entry", "required_e2e"}:
        assert task["stage"] == (
            Stage.REVIEW if acceptance == "required_entry" else Stage.VALIDATION
        )
        assert task["state"] == State.WAITING_ENVIRONMENT
        quality = Quality(store, policy)
        plan = await quality.plan(task)
        result = store.artifact(task_id, "quality-results", plan["plan_hash"])
        runs = store.runs(task_id)
        for _ in range(4):
            await scheduler.advance(task_id)
            assert store.task(task_id)["state"] == State.WAITING_ENVIRONMENT
        assert store.runs(task_id) == runs
        assert (
            store.artifact(task_id, "quality-results", plan["plan_hash"])["run_id"]
            == result["run_id"]
        )
        assert store.db.execute("SELECT count(*) FROM retries").fetchone()[0] == 0
        if acceptance == "required_e2e":
            e2e = next(i for i in result["items"] if i["category"] == "e2e")
            assert e2e["required"] and e2e["status"] == "blocked"
            assert not any(r["role"] == "validator" for r in runs)
            return
        for item in plan["items"]:
            if item["category"] == "internal":
                item["entry"] = ["test", "-f", "AGENTS.md"]
        quality.confirm(store.task(task_id), plan["items"])
        await scheduler.advance(task_id)
    if acceptance != "conflict":
        assert store.task(task_id)["stage"] == Stage.MERGEABLE
        assert store.task(task_id)["state"] == State.COMPLETED
    assert store.db.execute("SELECT count(*) FROM retries").fetchone()[0] == 0


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
