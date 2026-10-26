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
from gongcao.leases import Lease
from gongcao.model import Role, Stage, State
from gongcao.processes import observer
from gongcao.remote import Controlled
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


@pytest.mark.parametrize(
    "state,merged", [(State.COMPLETED, True), (State.HUMAN, False), (State.CANCELLED, False)]
)
def test_rejected_policy_change_cannot_reopen_terminal_or_blocked_work(
    store, task_id, snapshot, state, merged
):
    controls = Controls(store)
    controls.issue(task_id, "auto", policy=Config().policy_hash)
    if merged:
        store.sync(task_id, snapshot | {"merged": True})
    else:
        store.halt(task_id, state, "blocked")
    before = store.task(task_id)
    assert not controls.issue(task_id, "auto", policy=Config(model="changed").policy_hash)
    assert not controls.revalidate(task_id, Config(model="changed"))
    assert store.task(task_id) == before


@pytest.mark.parametrize("replacement", [False, True])
async def test_lost_lease_cannot_accept_feedback(store, task_id, replacement):
    async with Lease(store, task_id) as lease:
        with store.db:
            store.db.execute(
                "UPDATE leases SET expires=0,owner=? WHERE task_id=?",
                ("other" if replacement else lease.owner, task_id),
            )
        before = store.task(task_id), store.evidence(task_id)
        with pytest.raises(ValueError, match="lease lost"):
            Controls(store).issue(task_id, "step", feedback="Changed requirements", safe=True)
        assert before == (store.task(task_id), store.evidence(task_id))
        with store.db:
            store.db.execute(
                "UPDATE leases SET expires=9999999999,owner=? WHERE task_id=?",
                (lease.owner, task_id),
            )


async def test_journaled_operation_settles_before_pause(store, task_id, fixture_github, policy):
    store.transition(store.task(task_id), Stage.DEVELOPMENT, State.QUEUED, "fixture")
    remote = Controlled(store, policy, fixture_github)
    written = False

    async def observe():
        if written:
            return {"confirmed": True}
        Controls(store).issue(task_id, "pause")
        return None

    async def write():
        nonlocal written
        written = True
        return {}

    async with Lease(store, task_id):
        assert await remote.perform(store.task(task_id), "push", "fixture", {}, observe, write)
        assert not Controls(store).checkpoint(task_id)
    assert written and store.task(task_id)["state"] == State.WAITING_INSTRUCTION
    assert store.evidence(task_id)["operations"][0]["state"] == "succeeded"
    assert not store.db.execute("SELECT 1 FROM leases").fetchone()


async def test_remote_pause_is_read_after_agent_before_publication(
    store, task_id, fixture_github, policy, monkeypatch
):
    config = replace(policy, copilot_operators=["owner"])
    comments = []

    async def instructions(task):
        return comments

    monkeypatch.setattr(fixture_github, "instructions", instructions)
    Controls(store).issue(task_id, "until", "development", policy=config.policy_hash)
    await Workflow(store, config, fixture_github).run(task_id)
    original = Runner.receive

    async def receive(self, *args):
        result = await original(self, *args)
        stamp = datetime.now(UTC).isoformat()
        comments.append(
            {
                "id": 100,
                "body": "/gongcao pause",
                "user": {"login": "owner"},
                "created_at": stamp,
                "updated_at": stamp,
            }
        )
        return result

    monkeypatch.setattr(Runner, "receive", receive)
    Controls(store).issue(task_id, "auto", policy=config.policy_hash)
    await Workflow(store, config, fixture_github).run(task_id)
    assert store.task(task_id)["state"] == State.WAITING_INSTRUCTION
    assert store.task(task_id)["stage"] == Stage.DEVELOPMENT
    assert not fixture_github.writes


def test_unreachable_until_and_revoked_operator_cannot_authorize_work(store, task_id):
    with store.db:
        store.db.execute("UPDATE tasks SET pr_number=9 WHERE id=?", (task_id,))
    assert not Controls(store).issue(task_id, "until", "development")
    config = Config(copilot_operators=["owner"])
    assert Controls(store).issue(
        task_id, "auto", command_id="github:1", actor="owner", policy=config.policy_hash
    )
    assert not Controls(store).revalidate(task_id, replace(config, copilot_operators=[]))
    assert store.task(task_id)["state"] == State.WAITING_INSTRUCTION


def test_until_validates_the_stage_after_policy_rebuild(store, task_id):
    config = Config()
    Controls(store).issue(task_id, "auto", policy=config.policy_hash)
    store.transition(store.task(task_id), Stage.DEVELOPMENT, State.QUEUED, "fixture", pr_number=9)
    assert not Controls(store).issue(
        task_id, "until", "development", policy=Config(model="changed").policy_hash
    )
    assert store.task(task_id)["stage"] == Stage.REVIEW
    assert store.task(task_id)["state"] == State.WAITING_INSTRUCTION


async def test_paused_poll_failure_preserves_sibling_execution(
    store, task_id, repo, sha, snapshot, monkeypatch
):
    Controls(store).issue(task_id, "pause")
    other = store.register(snapshot["url"].replace("/1", "/2"), repo, sha, snapshot)
    completed = []

    class API(GitHub):
        async def task_snapshot(self, task):
            raise PermissionError("offline denial")

        async def instructions(self, task):
            return []

    async def run(self, number):
        await asyncio.sleep(0)
        completed.append(number)

    monkeypatch.setattr(Workflow, "run", run)
    await Scheduler(store, Config(copilot_operators=["owner"]), API()).serve(once=True)
    assert completed == [other]
    assert store.task(task_id)["state"] == State.WAITING_INSTRUCTION


async def test_background_commands_are_recorded_without_agent_lease_and_survive_restart(
    store, task_id
):
    config = Config(copilot_operators=["owner"])
    received = asyncio.Event()

    class API(GitHub):
        async def instructions(self, task):
            assert observer.get() is None
            stamp = datetime.now(UTC).isoformat()
            received.set()
            return [
                {
                    "id": 1,
                    "body": "/gongcao step",
                    "user": {"login": "owner"},
                    "created_at": stamp,
                    "updated_at": stamp,
                }
            ]

    async with Controls(store).listen(config, API(), task_id):
        async with Lease(store, task_id):
            run = store.begin_run(task_id, Role.ANALYST)
            await asyncio.wait_for(received.wait(), 2)
            assert store.task(task_id)["control"]["mode"] == "auto"
            assert store.evidence(task_id)["instructions"][0]["status"] == "pending"
            Controls(store).apply_pending(task_id, config)
            store.finish(run, State.COMPLETED, Stage.DEVELOPMENT, State.QUEUED, "ready")
    restarted = Store(store.root)
    try:
        assert restarted.task(task_id)["state"] == State.WAITING_INSTRUCTION
        row = restarted.evidence(task_id)["instructions"][0]
        assert row["status"] == "consumed" and len(row["data"]["fingerprint"]) == 64
    finally:
        restarted.close()


async def test_edited_and_conflicting_commands_pause_without_replay(store, task_id):
    config = Config(copilot_operators=["owner"])
    stamp = datetime.now(UTC).isoformat()
    comments = [
        {
            "id": 1,
            "body": "/gongcao auto",
            "user": {"login": "owner"},
            "created_at": stamp,
            "updated_at": stamp,
        }
    ]

    class API(GitHub):
        async def instructions(self, task):
            return comments

    controls = Controls(store)
    await controls.poll(task_id, config, API())
    comments[0]["body"] = "/gongcao step"
    await controls.poll(task_id, config, API())
    assert store.task(task_id)["state"] == State.WAITING_INSTRUCTION
    assert store.evidence(task_id)["instructions"][0]["status"] == "stale"
    stamp = datetime.now(UTC).isoformat()
    comments.extend(
        [
            {
                "id": number,
                "body": body,
                "user": {"login": "owner"},
                "created_at": stamp,
                "updated_at": stamp,
            }
            for number, body in ((2, "/gongcao auto"), (3, "/gongcao step"))
        ]
    )
    await controls.poll(task_id, config, API())
    assert "Conflicting" in store.task(task_id)["reason"]
    assert all(
        row["status"] == "rejected"
        for row in store.evidence(task_id)["instructions"]
        if row["id"] in {"github:2", "github:3"}
    )
