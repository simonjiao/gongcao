import asyncio
from contextvars import Context
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


class Comments(GitHub):
    def __init__(self):
        self.comments = []
        self.direct_reads = []

    def post(self, body, *, actor="owner", at=None):
        stamp = (datetime.now(UTC) if at is None else datetime.fromtimestamp(at, UTC)).isoformat()
        comment = {
            "id": len(self.comments) + 1,
            "body": body,
            "user": {"login": actor},
            "created_at": stamp,
            "updated_at": stamp,
        }
        self.comments.append(comment)
        return comment

    async def instructions(self, task):
        assert observer.get() is None
        return self.comments

    async def read(self, path):
        self.direct_reads.append(path)
        for comment in self.comments:
            if comment["id"] == int(path.rsplit("/", 1)[1]):
                return comment
        raise RuntimeError("HTTP 404: Not Found (deletion or visibility unknown)")


@pytest.fixture
def comments():
    return Comments()


@pytest.fixture
def copilot(fixture_github, policy, comments, monkeypatch):
    monkeypatch.setattr(fixture_github, "instructions", comments.instructions)
    return replace(policy, copilot_operators=["owner"])


@pytest.fixture
async def reviewing(store, task_id, fixture_github, copilot):
    controls = Controls(store)
    controls.issue(task_id, "until", "review", policy=copilot.policy_hash)
    await Workflow(store, copilot, fixture_github).run(task_id)
    controls.issue(task_id, "auto", policy=copilot.policy_hash)
    return Workflow(store, copilot, fixture_github)


@pytest.mark.parametrize("age", [0, 100])
async def test_unseen_comment_ids_use_current_facts_even_in_checkpoint_second(
    store, task_id, comments, age
):
    controls = Controls(store)
    controls.issue(task_id, "pause")
    since = store.task(task_id)["control"]["since"]
    comments.post("/gongcao step", at=int(since) - age)
    config = Config(copilot_operators=["owner"])
    await controls.poll(task_id, config, comments)
    assert store.task(task_id)["state"] == State.QUEUED
    run = store.begin_run(task_id, Role.ANALYST)
    store.finish(run, State.COMPLETED, Stage.DEVELOPMENT, State.QUEUED, "ready")
    restarted = Store(store.root)
    try:
        await Controls(restarted).poll(task_id, config, comments)
        assert restarted.task(task_id)["state"] == State.WAITING_INSTRUCTION
        assert restarted.evidence(task_id)["instructions"][-1]["status"] == "consumed"
        assert len(restarted.runs(task_id)) == 1
    finally:
        restarted.close()


@pytest.mark.parametrize("pending", [False, True])
@pytest.mark.parametrize("change", ["body", "edited", "actor", "deleted", "partial", "hidden"])
async def test_comment_reverification_blocks_changed_or_unavailable_permissions(
    store, task_id, comments, monkeypatch, pending, change
):
    controls, config = Controls(store), Config(copilot_operators=["owner"])
    controls.issue(task_id, "pause")
    comment = comments.post("/gongcao auto")
    await controls.collect(task_id, config, comments)
    if not pending:
        controls.apply_pending(task_id, config)
    if change == "body":
        comment["body"] = "/gongcao step"  # A same-second edit retains the timestamps.
    elif change == "edited":
        comment["updated_at"] = "2099-01-01T00:00:00Z"
    elif change == "actor":
        comment["user"] = {"login": "stranger"}
    elif change == "deleted":
        comments.comments.clear()
    else:

        async def listing(task):
            if change == "partial":
                raise PermissionError("HTTP 403 on page two")
            return []

        monkeypatch.setattr(comments, "instructions", listing)
    await controls.poll(task_id, config, comments)
    row = next(row for row in store.evidence(task_id)["instructions"] if row["id"] == "github:1")
    if change == "hidden":
        assert store.task(task_id)["state"] == State.QUEUED
        assert row["status"] == "accepted" and not row["reason"]
    else:
        assert store.task(task_id)["state"] == State.WAITING_INSTRUCTION
        expected = (
            ("pending" if pending else "accepted") if change in {"deleted", "partial"} else "stale"
        )
        assert row["status"] == expected
        if change in {"deleted", "partial"}:
            assert "verification pending" in row["reason"]
        controls.apply_pending(task_id, config)
        assert store.task(task_id)["state"] == State.WAITING_INSTRUCTION
    assert len(comments.direct_reads) == (change in {"deleted", "hidden"})
    assert not store.runs(task_id) and not store.evidence(task_id)["operations"]


@pytest.mark.parametrize("change", ["edited", "deleted", "unavailable"])
async def test_completed_comment_permissions_cannot_reactivate_work(
    store, task_id, comments, monkeypatch, change
):
    config, controls = Config(copilot_operators=["owner"]), Controls(store)
    comment = comments.post("/gongcao auto")
    await controls.poll(task_id, config, comments)
    store.transition(store.task(task_id), Stage.MERGEABLE, State.COMPLETED, "done")
    before = store.task(task_id), store.evidence(task_id)
    comment["body"] = "withdrawn"
    if change == "deleted":
        comments.comments.clear()
    elif change == "unavailable":

        async def unavailable(task):
            raise ConnectionError("unavailable")

        monkeypatch.setattr(comments, "instructions", unavailable)
    await controls.poll(task_id, config, comments)
    assert before == (store.task(task_id), store.evidence(task_id))
    assert not controls.issue(task_id, "auto")


async def test_initial_edit_is_rejected_and_changed_active_step_stays_stale(
    store, task_id, comments
):
    config, controls = Config(copilot_operators=["owner"]), Controls(store)
    comment = comments.post("/gongcao step")
    comment["updated_at"] = "2099-01-01T00:00:00Z"
    await controls.poll(task_id, config, comments)
    assert store.evidence(task_id)["instructions"][0]["status"] == "rejected"
    grant = comments.post("/gongcao step")
    await controls.poll(task_id, config, comments)
    run = store.begin_run(task_id, Role.ANALYST)
    grant["body"] = "withdrawn"
    await controls.collect(task_id, config, comments)
    store.finish(run, State.COMPLETED, Stage.DEVELOPMENT, State.QUEUED, "ready")
    assert store.evidence(task_id)["instructions"][1]["status"] == "stale"
    assert store.task(task_id)["state"] == State.WAITING_INSTRUCTION


@pytest.mark.parametrize("override", [False, True])
async def test_unverified_pending_comment_survives_restart_and_explicit_local_override(
    store, task_id, comments, monkeypatch, override
):
    config, controls = Config(copilot_operators=["owner"]), Controls(store)
    controls.issue(task_id, "pause")
    comments.post("/gongcao auto")
    await controls.collect(task_id, config, comments)

    async def unavailable(task):
        raise TimeoutError("incomplete pagination")

    with monkeypatch.context() as offline:
        offline.setattr(comments, "instructions", unavailable)
        await controls.poll(task_id, config, comments)
    restarted = Store(store.root)
    try:
        controls = Controls(restarted)
        controls.apply_pending(task_id, config)
        assert restarted.task(task_id)["state"] == State.WAITING_INSTRUCTION
        if override:
            controls.issue(task_id, "until", "review", policy=config.policy_hash)
        await controls.poll(task_id, config, comments)
        assert restarted.task(task_id)["control"]["mode"] == ("until" if override else "auto")
        assert restarted.task(task_id)["state"] == State.QUEUED
        row = next(r for r in restarted.evidence(task_id)["instructions"] if r["id"] == "github:1")
        assert row["status"] == ("superseded" if override else "accepted")
    finally:
        restarted.close()


@pytest.mark.parametrize(
    "stage,target,pr,accepted,paused",
    [
        (Stage.ANALYSIS, "development", None, True, False),
        (Stage.REVIEW, "review", None, True, True),
        (Stage.VALIDATION, "review", None, False, False),
        (Stage.REVISION, "development", None, False, False),
        (Stage.REVISION, "review", None, True, False),
        (Stage.ANALYSIS, "revision", None, False, False),
        (Stage.ANALYSIS, "development", 9, False, False),
    ],
)
def test_until_is_a_forward_entry_checkpoint(store, task_id, stage, target, pr, accepted, paused):
    store.transition(store.task(task_id), stage, State.QUEUED, "fixture", pr_number=pr)
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
    store, sha, snapshot, repo, monkeypatch, comments
):
    clock = [100.0]
    monkeypatch.setattr("gongcao.control.time", SimpleNamespace(time=lambda: clock[0]))
    task_id = store.register(snapshot["url"], repo, sha, snapshot)
    controls = Controls(store)
    controls.issue(task_id, "pause")
    config = Config(copilot_operators=["owner"])

    comments.post("/gongcao auto", actor="stranger", at=101)
    comments.post("ordinary comment", at=101)
    await controls.poll(task_id, config, comments)
    assert store.task(task_id)["state"] == State.WAITING_INSTRUCTION
    comments.post("/gongcao step\nAlso check the upper bound.", at=101)
    clock[0] = 102
    await controls.poll(task_id, config, comments)
    run = store.begin_run(task_id, Role.ANALYST)
    store.finish(run, State.COMPLETED, Stage.DEVELOPMENT, State.QUEUED, "ready")
    restarted = Store(store.root)
    try:
        await Controls(restarted).poll(task_id, config, comments)
        assert restarted.task(task_id)["state"] == State.WAITING_INSTRUCTION
        assert restarted.evidence(task_id)["instructions"][-1]["status"] == "consumed"
    finally:
        restarted.close()
    data, _ = await context(repo, store.task(task_id), Role.DEVELOPER, config, None)
    assert data["operator_feedback"][0]["feedback"] == "Also check the upper bound."
    clock[0] = 104
    comments.post("/gongcao step", at=103)
    await controls.collect(task_id, config, comments)
    store.sync(task_id, snapshot | {"head_sha": "0" * 40})
    await controls.poll(task_id, config, comments)
    assert store.task(task_id)["state"] == State.WAITING_INSTRUCTION
    assert store.evidence(task_id)["instructions"][-1]["status"] == "rejected"
    store.halt(task_id, State.RECONCILE, "Unknown write")
    controls.issue(task_id, "pause")
    assert store.task(task_id)["state"] == State.RECONCILE


@pytest.mark.parametrize(
    "labels,source,mode,paused",
    [
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


@pytest.mark.parametrize("version", [2, 3])
def test_schema_upgrade_preserves_intents_and_legacy_auto(store, task_id, version):
    store.intent(store.task(task_id), "unknown", "push", "{}")
    expected = {} if version == 2 else store.task(task_id)["control"]
    with store.db:
        store.db.execute("DROP TRIGGER status_dirty")
        store.db.execute("DROP TABLE claims")
        store.db.execute("DROP TABLE controller")
        if version == 2:
            store.db.execute("DROP TABLE instructions")
            store.db.execute("ALTER TABLE tasks DROP COLUMN control")
        store.db.execute(f"PRAGMA user_version={version}")
    for _ in range(2):
        restarted = Store(store.root)
        try:
            assert restarted.task(task_id)["control"] == expected
            assert restarted.operation("unknown")["state"] == "pending"
            assert Controls(restarted).checkpoint(task_id)
        finally:
            restarted.close()


def test_execution_policy_changes_require_new_permission(store, task_id):
    config = Config()
    Controls(store).issue(task_id, "auto", policy=config.policy_hash)
    assert not Controls(store).revalidate(task_id, replace(config, model="new-model"))
    assert store.task(task_id)["state"] == State.WAITING_INSTRUCTION


def test_comment_only_updates_keep_version_evidence(store, task_id, snapshot):
    expected = store.task(task_id)
    store.record(expected, "analysis", "", {"summary": "confirmed"})
    store.sync(task_id, snapshot | {"updated_at": "2026-10-27T02:04:00Z"})
    assert Workflow(store, Config(), GitHub()).safe(expected)["state"] == State.QUEUED
    assert store.artifact(task_id, "analysis", "") == {"summary": "confirmed"}
    store.sync(task_id, snapshot | {"body": "Changed requirement"})
    assert store.artifact(task_id, "analysis", "") is None


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


@pytest.mark.parametrize("change", ["pause", "edited", "deleted", "unavailable"])
async def test_remote_revocation_is_read_after_agent_before_publication(
    store, task_id, fixture_github, copilot, comments, monkeypatch, change
):
    config = copilot
    Controls(store).issue(task_id, "until", "development", policy=config.policy_hash)
    await Workflow(store, config, fixture_github).run(task_id)
    original = Runner.receive

    async def receive(self, *args):
        result = await original(self, *args)
        if change == "pause":
            comments.post("/gongcao pause")
        elif change == "edited":
            grant["body"] = "withdrawn"
        elif change == "deleted":
            comments.comments.clear()
        else:

            async def unavailable(task):
                raise ConnectionError("offline")

            monkeypatch.setattr(fixture_github, "instructions", unavailable)
        return result

    monkeypatch.setattr(Runner, "receive", receive)
    grant = comments.post("/gongcao auto")
    await Controls(store).poll(task_id, config, comments)
    monkeypatch.setattr(fixture_github, "read", comments.read)
    await Workflow(store, config, fixture_github).run(task_id)
    assert store.task(task_id)["state"] == State.WAITING_INSTRUCTION
    assert store.task(task_id)["stage"] == Stage.DEVELOPMENT
    assert not fixture_github.writes


def test_operator_revocation_cannot_authorize_work(store, task_id):
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
    store, task_id, comments, monkeypatch
):
    config = Config(copilot_operators=["owner"])
    received = asyncio.Event()

    async def instructions(task):
        assert observer.get() is None
        received.set()
        return comments.comments

    comments.post("/gongcao step")
    monkeypatch.setattr(comments, "instructions", instructions)
    async with Controls(store).listen(config, comments, task_id):
        async with Lease(store, task_id):
            run = store.begin_run(task_id, Role.ANALYST)
            await asyncio.wait_for(received.wait(), 2)
            assert store.task(task_id)["control"]["mode"] == "auto"
            assert store.evidence(task_id)["instructions"][0]["status"] == "pending"
            Controls(store).apply_pending(task_id, config)
            before = store.task(task_id), store.runs(task_id), store.evidence(task_id)

            def fail_consumption(*args):
                raise OSError("crash")

            with monkeypatch.context() as crash:
                crash.setattr(Controls, "mark", fail_consumption)
                with pytest.raises(OSError, match="crash"):
                    store.finish(run, State.COMPLETED, Stage.DEVELOPMENT, State.QUEUED, "ready")
            assert before == (store.task(task_id), store.runs(task_id), store.evidence(task_id))
            store.finish(run, State.COMPLETED, Stage.DEVELOPMENT, State.QUEUED, "ready")
    restarted = Store(store.root)
    try:
        assert restarted.task(task_id)["state"] == State.WAITING_INSTRUCTION
        row = restarted.evidence(task_id)["instructions"][0]
        assert row["status"] == "consumed" and len(row["data"]["fingerprint"]) == 64
    finally:
        restarted.close()


@pytest.mark.parametrize("split_poll", [False, True])
async def test_edited_and_conflicting_commands_pause_without_replay(
    store, task_id, comments, split_poll
):
    config = Config(copilot_operators=["owner"])
    controls = Controls(store)
    original = comments.post("/gongcao auto")
    await controls.poll(task_id, config, comments)
    original["body"] = "Withdrawn"
    await controls.poll(task_id, config, comments)
    assert store.task(task_id)["state"] == State.WAITING_INSTRUCTION
    assert store.evidence(task_id)["instructions"][0]["status"] == "stale"
    stamp = datetime.now(UTC).timestamp()
    comments.post("/gongcao auto", at=stamp)
    if split_poll:
        await controls.poll(task_id, config, comments)
    comments.post("/gongcao step", at=stamp + 1)
    await controls.poll(task_id, config, comments)
    assert store.task(task_id)["state"] == State.WAITING_INSTRUCTION
    assert "Conflicting" in store.task(task_id)["reason"]
    rows = {row["id"]: row for row in store.evidence(task_id)["instructions"]}
    assert rows["github:3"]["status"] == "rejected"
    assert rows["github:2"]["status"] == ("superseded" if split_poll else "rejected")


async def test_until_current_review_pauses_after_review_write_without_advancing(
    store, task_id, fixture_github, reviewing, comments, monkeypatch
):
    workflow = reviewing
    original = workflow.remote.review

    async def reviewed(task, result, run_id):
        await original(task, result, run_id)
        comments.post("/gongcao until review")
        await asyncio.create_task(
            Controls(store).collect(task_id, workflow.config, fixture_github), context=Context()
        )

    monkeypatch.setattr(workflow.remote, "review", reviewed)
    await workflow.run(task_id)
    assert (store.task(task_id)["stage"], store.task(task_id)["state"]) == (
        Stage.REVIEW,
        State.WAITING_INSTRUCTION,
    )
    assert len(fixture_github.reviews) == 1


async def test_step_received_during_failed_checks_stops_at_revision(
    store, task_id, fixture_github, reviewing, comments, monkeypatch
):
    workflow = reviewing

    async def failed_checks(task, kind):
        comments.post("/gongcao step")
        await asyncio.create_task(
            Controls(store).collect(task_id, workflow.config, fixture_github), context=Context()
        )
        return {"passed": False, "target_sha": task["target_sha"]}

    monkeypatch.setattr(workflow.quality, "run", failed_checks)
    await workflow.run(task_id)
    assert store.task(task_id)["stage"] == Stage.REVISION
    assert store.task(task_id)["state"] == State.WAITING_INSTRUCTION
    assert len(store.runs(task_id)) == 2


@pytest.mark.parametrize("conflict", [False, True])
async def test_remote_pause_after_publish_keeps_confirmed_pr_and_sha(
    store, task_id, fixture_github, copilot, comments, monkeypatch, conflict
):
    workflow = Workflow(store, copilot, fixture_github)
    original = workflow.remote.publish

    async def publish(task, run):
        result = await original(task, run)
        stamp = datetime.now(UTC).timestamp()
        comments.post("/gongcao pause", at=stamp)
        if conflict:
            comments.post("/gongcao step", at=stamp)
        await asyncio.create_task(
            Controls(store).collect(task_id, workflow.config, fixture_github), context=Context()
        )
        return result

    monkeypatch.setattr(workflow.remote, "publish", publish)
    await workflow.run(task_id)
    task = store.task(task_id)
    assert (task["stage"], task["state"]) == (Stage.REVIEW, State.WAITING_INSTRUCTION)
    assert task["pr_number"] == 9 and task["target_sha"] == fixture_github.head()
    assert all(row["state"] == "succeeded" for row in store.evidence(task_id)["operations"])
    store.sync(task_id, await fixture_github.task_snapshot(task))
    assert store.task(task_id)["stage"] == Stage.REVIEW
    assert len(store.runs(task_id)) == 2 and len(fixture_github.writes) == 1
