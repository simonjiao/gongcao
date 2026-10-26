import asyncio
from dataclasses import replace
from datetime import UTC, datetime
from types import SimpleNamespace

import pytest
from test_pr2 import fixture_github as fixture_github
from test_pr2 import policy as policy

from gongcao.config import Config
from gongcao.control import Controls
from gongcao.github import GitHub
from gongcao.model import Role, Stage, State
from gongcao.runner import Runner
from gongcao.scheduler import Scheduler
from gongcao.store import Store
from gongcao.workflow import Workflow
from gongcao.workspace import context


@pytest.mark.parametrize(
    "stage,target,accepted,paused",
    [
        (Stage.ANALYSIS, "development", True, False),
        (Stage.REVIEW, "review", True, True),
        (Stage.VALIDATION, "review", False, False),
        (Stage.REVISION, "development", False, False),
        (Stage.REVISION, "review", True, False),
        (Stage.ANALYSIS, "revision", False, False),
    ],
)
def test_until_is_a_forward_entry_checkpoint(store, task_id, stage, target, accepted, paused):
    store.transition(store.task(task_id), stage, State.QUEUED, "fixture")
    assert Controls(store).issue(task_id, "until", target) == accepted
    assert (store.task(task_id)["state"] == State.WAITING_INSTRUCTION) == paused


async def test_steps_include_publication_revision_and_pending_ci(
    store, task_id, fixture_github, policy
):
    controls = Controls(store)
    for expected in (
        Stage.DEVELOPMENT,
        Stage.REVIEW,
        Stage.REVISION,
        Stage.REVIEW,
        Stage.VALIDATION,
    ):
        assert controls.issue(task_id, "step", policy=policy.policy_hash)
        await Workflow(store, policy, fixture_github).run(task_id)
        task = store.task(task_id)
        assert (task["stage"], task["state"]) == (expected, State.WAITING_INSTRUCTION)
        before = len(store.runs(task_id)), len(fixture_github.writes)
        assert await Workflow(store, policy, fixture_github).run(task_id) == []
        await Scheduler(store, policy, fixture_github).serve(once=True)
        assert before == (len(store.runs(task_id)), len(fixture_github.writes))
        assert not store.db.execute("SELECT 1 FROM leases").fetchone()
    fixture_github.ci = None
    assert controls.issue(task_id, "step", policy=policy.policy_hash)
    await Workflow(store, policy, fixture_github).run(task_id)
    assert store.task(task_id)["state"] == State.WAITING_DEPENDENCY
    assert not store.task(task_id)["control"]["spent"]
    fixture_github.ci = "success"
    await Workflow(store, policy, fixture_github).run(task_id)
    assert store.task(task_id)["stage"] == Stage.MERGEABLE
    assert store.task(task_id)["state"] == State.WAITING_INSTRUCTION
    assert len(fixture_github.reviews) == 2


async def test_pause_settles_agent_then_resumes_without_replaying(
    store, task_id, fixture_github, policy, monkeypatch
):
    started, release = asyncio.Event(), asyncio.Event()
    original = Runner.receive

    async def receive(self, *args):
        started.set()
        await release.wait()
        return await original(self, *args)

    monkeypatch.setattr(Runner, "receive", receive)
    running = asyncio.create_task(Workflow(store, policy, fixture_github).run(task_id))
    await asyncio.wait_for(started.wait(), 10)
    assert Controls(store).issue(task_id, "pause", policy=policy.policy_hash)
    assert store.task(task_id)["state"] == State.RUNNING
    release.set()
    await asyncio.wait_for(running, 15)
    assert store.task(task_id)["state"] == State.WAITING_INSTRUCTION
    assert not fixture_github.writes
    assert Controls(store).issue(task_id, "until", "review", policy=policy.policy_hash)
    await Workflow(store, policy, fixture_github).run(task_id)
    assert [r["role"] for r in store.runs(task_id)] == ["analyst", "developer"]


async def test_trusted_commands_bind_baseline_deduplicate_and_invalidate_feedback(
    store, sha, snapshot, repo, monkeypatch
):
    clock = [100.0]
    monkeypatch.setattr("gongcao.control.time", SimpleNamespace(time=lambda: clock[0]))
    task_id = store.register(snapshot["url"], repo, sha, snapshot)
    controls = Controls(store)
    controls.issue(task_id, "pause")
    config = Config(copilot_operators=["owner"])

    def comment(number, text, actor="owner", at=101):
        stamp = datetime.fromtimestamp(at, UTC).isoformat()
        return {
            "id": number,
            "body": text,
            "user": {"login": actor},
            "created_at": stamp,
            "updated_at": stamp,
        }

    comments = [comment(1, "/gongcao auto", "stranger"), comment(2, "ordinary comment")]

    class API(GitHub):
        async def instructions(self, task):
            return comments

    api = API()
    await controls.poll(task_id, config, api)
    assert store.task(task_id)["state"] == State.WAITING_INSTRUCTION
    comments.append(comment(3, "/gongcao step\nAlso check the upper bound."))
    clock[0] = 102
    await controls.poll(task_id, config, api)
    run = store.begin_run(task_id, Role.ANALYST)
    store.finish(run, State.COMPLETED, Stage.DEVELOPMENT, State.QUEUED, "ready")
    restarted = Store(store.root)
    try:
        await Controls(restarted).poll(task_id, config, api)
        assert restarted.task(task_id)["state"] == State.WAITING_INSTRUCTION
        assert restarted.evidence(task_id)["instructions"][-1]["status"] == "consumed"
    finally:
        restarted.close()
    data, _ = await context(repo, store.task(task_id), Role.DEVELOPER, config, None)
    assert data["operator_feedback"][0]["feedback"] == "Also check the upper bound."
    clock[0] = 104
    store.sync(task_id, snapshot | {"head_sha": "0" * 40})
    comments.append(comment(4, "/gongcao step", at=103))
    await controls.poll(task_id, config, api)
    assert store.task(task_id)["state"] == State.WAITING_INSTRUCTION
    assert store.evidence(task_id)["instructions"][-1]["status"] == "rejected"
    store.halt(task_id, State.RECONCILE, "Unknown write")
    controls.issue(task_id, "pause")
    assert store.task(task_id)["state"] == State.RECONCILE


@pytest.mark.parametrize(
    "labels,source,mode,paused",
    [
        ([], "manual", "auto", False),
        ([], "discovery", "step", False),
        (["gongcao:until-review"], "manual", "until", False),
        (["gongcao:step", "gongcao:auto"], "manual", "auto", True),
    ],
)
def test_initial_policy_is_consumed_once(store, repo, sha, snapshot, labels, source, mode, paused):
    number = store.register(
        snapshot["url"], repo, sha, snapshot | {"labels": labels}, source=source
    )
    assert store.task(number)["control"]["mode"] == mode
    assert (store.task(number)["state"] == State.WAITING_INSTRUCTION) == paused
    Controls(store).issue(number, "pause")
    assert (
        store.register(snapshot["url"], repo, sha, snapshot | {"labels": ["gongcao:auto"]})
        == number
    )
    assert store.task(number)["control"]["mode"] == "pause"


def test_schema_two_upgrade_preserves_intents_and_legacy_auto(store, task_id):
    store.intent(store.task(task_id), "unknown", "push", "{}")
    with store.db:
        store.db.execute("DROP TABLE instructions")
        store.db.execute("ALTER TABLE tasks DROP COLUMN control")
        store.db.execute("PRAGMA user_version=2")
    for _ in range(2):
        restarted = Store(store.root)
        try:
            assert restarted.task(task_id)["control"] == {}
            assert restarted.operation("unknown")["state"] == "pending"
            assert Controls(restarted).checkpoint(task_id)
        finally:
            restarted.close()


def test_execution_policy_changes_require_new_permission(store, task_id):
    config = Config()
    Controls(store).issue(task_id, "auto", policy=config.policy_hash)
    assert not Controls(store).revalidate(task_id, replace(config, model="new-model"))
    assert store.task(task_id)["state"] == State.WAITING_INSTRUCTION
