"""Intake risks at existing GitHub/SQLite seams; workflow/OS behavior lives in CLI tests."""

import asyncio
import json
from contextlib import closing
from copy import deepcopy

import pytest
from _support.worker import install_worker

from gongcao.config import Config
from gongcao.control import Controls, InstructionChanged, baseline
from gongcao.coordination import Coordinator
from gongcao.discovery import Discovery
from gongcao.github import Deferred, command
from gongcao.leases import Lease
from gongcao.model import Role, Stage, State
from gongcao.recovery import Recovery
from gongcao.runner import Runner
from gongcao.scheduler import Scheduler
from gongcao.store import Store


async def test_long_handoff_requires_confirmed_readback_and_reaches_isolated_workers(
    intake, store, repo, sha, policy, monkeypatch
):
    await intake.scan()
    task = store.tasks()[0]
    task_id = task["id"]
    store.halt(task_id, State.QUEUED, "Analyze current request")
    Controls(store).issue(task_id, "auto", policy=policy.policy_hash)
    run = store.begin_run(task_id, Role.ANALYST)
    store.run_details(run, source={"sha": sha, "baseline": baseline(task)})
    publisher = Discovery(store, policy, intake.github)
    await publisher.publish(publisher.records()[0])
    report = {
        "conclusion": "ready",
        "target_sha": sha,
        "summary": "Evidence and acceptance detail. " * 180,
        "basis": ["Owner chose return zero; github_pat_secret123"],
        "next_steps": ["Preserve the final necessary decision: return zero."],
    }
    store.finish(
        run,
        State.COMPLETED,
        Stage.DEVELOPMENT,
        State.QUEUED,
        "Analysis ready",
        json.dumps(report),
    )
    mutate = intake.github.mutate

    async def unavailable(*args, **kwargs):
        raise ConnectionError("Publication unavailable before first POST")

    async def forbidden(*args, **kwargs):
        pytest.fail("An unconfirmed handoff cannot start the next Agent")

    count = len(store.runs(task_id))
    writes = len(intake.github.writes)
    with monkeypatch.context() as pending:
        pending.setattr(Discovery, "owned", unavailable)
        pending.setattr(Runner, "session", forbidden)
        scheduler = Scheduler(store, policy, intake.github)
        for _ in range(3):
            await scheduler.advance(task_id)
        assert len(store.runs(task_id)) == count
        assert not (store.root / "worktrees").exists()
        assert not store.db.execute("SELECT 1 FROM retries WHERE task_id=?", (task_id,)).fetchone()
        assert store.task(task_id)["state"] == State.QUEUED
        assert len(intake.github.writes) == writes

    async def lost_response(*args, **kwargs):
        await mutate(*args, **kwargs)
        intake.github.failure = "403"  # POST applied, but confirmation cannot be read.
        raise ConnectionError("Reply lost")

    monkeypatch.setattr(intake.github, "mutate", lost_response)
    with pytest.raises(PermissionError):
        await publisher.publish(publisher.records()[0])
    run_dir = store.root / "runs" / "pending-handoff"
    with pytest.raises(Deferred, match="handoff"):
        await publisher.report_context(task, report, run_dir)
    assert not run_dir.exists()  # An unknown POST is never a confirmed handoff.
    writes = len(intake.github.writes)
    intake.github.failure = ""
    monkeypatch.setattr(intake.github, "mutate", mutate)
    await publisher.publish(publisher.records()[0])
    assert len(intake.github.writes) == writes
    published = deepcopy(intake.github.comments[-1])
    assert report["next_steps"][0] in published["body"]
    assert "secret123" not in published["body"]

    store.halt(task_id, State.WAITING_INSTRUCTION, "Next milestone, same report")
    await publisher.publish(publisher.records()[0])
    assert report["summary"] not in intake.github.comments[-1]["body"]
    assert f"#issuecomment-{published['id']}" in intake.github.comments[-1]["body"]
    with closing(Store(store.root)) as restarted:
        reader = Discovery(restarted, policy, intake.github)
        current = restarted.task(task_id)
        bound = await reader.report_context(current, report, run_dir)
        assert bound["reference"]["comment_id"] == published["id"]
        assert bound["reference"]["request"] == baseline(current)
        assert report["summary"] not in json.dumps(bound)
        for changed in (
            current | {"target_sha": "0" * 40},
            current | {"snapshot": current["snapshot"] | {"body": "New requirements"}},
        ):
            assert await reader.report_context(changed, report, run_dir) == report
        for change in (
            {"user": {"login": "someone-else"}},
            {"body": published["body"] + "edited"},
            {"updated_at": "edited-later"},
        ):
            intake.github.comments[published["id"] - 1].update(change)
            with pytest.raises(ValueError, match="handoff"):
                await reader.report_context(current, report, run_dir)
            intake.github.comments[published["id"] - 1] = deepcopy(published)
        before = deepcopy(intake.github.comments)
        await reader.publish(reader.records()[0])
        assert intake.github.comments == before

    # Both existing SDK paths consume the actual file inside their existing OS sandbox.
    Controls(store).issue(task_id, "auto", policy=policy.policy_hash)
    read, denied = intake.github.read, 0

    async def unauthorized(path):
        nonlocal denied
        if path.endswith(f"/comments/{published['id']}"):
            denied += 1
            raise PermissionError("HTTP 403: handoff read access denied")
        return await read(path)

    with monkeypatch.context() as pending:
        pending.setattr(intake.github, "read", unauthorized)
        pending.setattr(Runner, "session", forbidden)
        scheduler = Scheduler(store, policy, intake.github)
        for _ in range(3):
            await scheduler.advance(task_id)
        assert denied == 1  # Persisted sync backoff also applies across Runner instances.
        assert len(store.runs(task_id)) == count
        assert not (store.root / "worktrees").exists()
        assert not store.db.execute("SELECT 1 FROM retries WHERE task_id=?", (task_id,)).fetchone()
        assert store.task(task_id)["state"] == State.QUEUED
    await publisher.publish(publisher.records()[0])

    install_worker(
        monkeypatch,
        """
import json, pathlib, sys
request = json.loads(sys.stdin.readline())
data = request['context']
coordinator = data['role'] == 'coordinator'
handoff = (next(r['handoff'] for r in data['facts']['runs'] if 'handoff' in r)
    if coordinator else data['confirmed_analysis'])
assert handoff['source'] == 'confirmed_github_comment'
body = pathlib.Path(handoff['details_file']).read_text()
assert 'Preserve the final necessary decision: return zero.' in body
assert 'secret123' not in body
assert len(handoff['summary']) <= 600
print(json.dumps({'kind':'thread','data':{'thread_id':data['role']}}))
print(json.dumps({'kind':'execution','data':{'model':request['model'],
    'reasoning_effort':request['reasoning_effort']}}))
result = {'facts':['Verified GitHub handoff'], 'blockers':['Owner input'],
    'suggestions':[{'action':'Request input','owner':'owner','inputs':['decision']}]}
if not coordinator:
    result = {'conclusion':'ready','target_sha':data['target_sha'], 'summary':'Read handoff',
        'basis':['Version-matched decision retained'],'next_steps':['Controller checks']}
print(json.dumps({'kind':'result','data':result}))
""",
    )
    Controls(store).issue(task_id, "auto", policy=policy.policy_hash)
    developer = await Runner(store, policy, intake.github).run(task_id)
    assert store.runs(task_id)[-1]["state"] == State.COMPLETED
    developer_data = json.loads((store.root / "runs" / developer / "context.json").read_text())
    assert developer_data["confirmed_analysis"]["reference"]["comment_id"] == published["id"]
    # In an uninterrupted auto flow, the original publisher confirms the report before use.
    store.transition(store.task(task_id), Stage.ANALYSIS, State.QUEUED, "New analysis")
    analysis = store.begin_run(task_id, Role.ANALYST)
    store.run_details(analysis, source={"sha": sha, "baseline": baseline(store.task(task_id))})
    updated = report | {"summary": report["summary"] + "Updated conclusion."}
    store.finish(
        analysis,
        State.COMPLETED,
        Stage.DEVELOPMENT,
        State.QUEUED,
        "Updated analysis",
        json.dumps(updated),
    )
    developer = await Runner(store, policy, intake.github).run(task_id)
    assert store.runs(task_id)[-1]["state"] == State.COMPLETED
    developer_data = json.loads((store.root / "runs" / developer / "context.json").read_text())
    reference = developer_data["confirmed_analysis"]["reference"]
    assert reference["comment_id"] != published["id"]
    assert "Updated conclusion." in intake.github.comments[reference["comment_id"] - 1]["body"]
    original_context = await publisher.report_context(
        store.task(task_id), report, store.root / "runs" / "original-handoff"
    )
    assert original_context["reference"]["comment_id"] == published["id"]
    dependencies = []
    for number in (3, 5):
        item = intake.github.rows[number] | {"labels": []}
        dependency = store.register(item["url"], repo, sha, item)
        store.halt(dependency, State.HUMAN, "Owner input")
        dependencies.append(dependency)
    store.depend(task_id, dependencies)
    store.halt(task_id, State.HUMAN, "Owner input")
    await publisher.publish(publisher.records()[0])
    before = (
        store.task(task_id) | {"status_sync": None},
        store.runs(task_id),
        deepcopy(intake.github.comments),
    )
    advice = await Coordinator(store, policy, intake.github).run(task_id)
    assert advice["status"] == "completed", advice
    assert before == (
        store.task(task_id) | {"status_sync": None},
        store.runs(task_id),
        intake.github.comments,
    )


@pytest.mark.parametrize("kind", ["issues", "pull"])
async def test_manual_status_anchor_and_progress_are_append_only_without_discovery(
    intake, store, repo, sha, snapshot, kind, monkeypatch
):
    item = snapshot | {"kind": kind, "url": snapshot["url"].replace("/issues/", f"/{kind}/")}
    task_id = store.register(item["url"], repo, sha, item)
    publisher = Discovery(store, Config(), intake.github)
    publisher.manual(task_id)
    read = intake.github.read

    async def with_concurrent_progress(path):
        if path == "user":
            with closing(Store(store.root)) as writer:
                writer.halt(task_id, State.HUMAN, "并发到达的变化")
        return await read(path)

    monkeypatch.setattr(intake.github, "read", with_concurrent_progress)
    await publisher.refresh(task_id)
    assert any("并发到达的变化" in c["body"] for c in intake.github.comments)
    row = publisher.records()[0]
    assert json.loads(row["data"])["kind"] == "manual" and row["confirmed"]
    original = deepcopy(intake.github.comments)
    store.halt(task_id, State.HUMAN, "缺少验收材料，NOT_RUN")
    await publisher.refresh(task_id)
    assert intake.github.comments[: len(original)] == original
    assert "NOT_RUN" in intake.github.comments[-1]["body"]
    count = len(intake.github.writes)
    with closing(Store(store.root)) as restarted:
        await Discovery(restarted, Config(), intake.github).refresh(task_id)
    assert len(intake.github.writes) == count


async def test_filter_dedupe_backlog_status_and_cross_state_lock(
    intake, store, repo, sha, snapshot, tmp_path
):
    # Manual completed/cancelled tasks are never rediscovered; all pages are filtered locally too.
    store.register(snapshot["url"], repo, sha, snapshot)
    await command("git", "commit", "--allow-empty", "-qm", "user local HEAD", cwd=str(repo))
    head = await command("git", "rev-parse", "HEAD", cwd=str(repo))
    intake.github.rows[5]["assignees"] = [{"login": "human"}]
    async with intake.active(once=True):
        assert [t["snapshot"]["number"] for t in store.tasks()] == [1, 6]
        task = store.tasks()[-1]
        assert task["control"]["mode"] == "step"
        assert task["target_sha"] == sha
        assert await command("git", "rev-parse", "HEAD", cwd=str(repo)) == head
        assert intake.github.writes == ["POST"]
        other = Store(tmp_path / "other-state")
        try:
            with pytest.raises(ValueError, match="already owns"):
                async with Discovery(other, intake.config, intake.github).active(once=True):
                    pytest.fail("Another state directory acquired the same repository")
        finally:
            other.close()
        await intake.scan()
        assert len(store.tasks()) == 2 and len(intake.github.comments) == 1
    claim = deepcopy(intake.github.comments[0])
    store.cancel(task["id"])
    reopened = Store(store.root)
    try:
        disabled = Discovery(reopened, Config(), intake.github)
        async with disabled.active(once=True):
            assert len(reopened.tasks()) == 2 and intake.github.writes == ["POST"] * 2
            assert "State: `cancelled`" in intake.github.comments[-1]["body"]
        reopened.sync(task["id"], task["snapshot"])
        reopened.cancel(task["id"])
        await Discovery(reopened, Config(), intake.github).refresh(task["id"])
        assert intake.github.writes == ["POST"] * 2
        reopened.halt(task["id"], State.CANCELLED, "Stopped before execution", correction=True)
        await disabled.refresh(task["id"])
        assert "Correction of event" in intake.github.comments[-1]["body"]
        reopened.halt(task["id"], State.CANCELLED, "Stopped before execution", correction=True)
        await disabled.refresh(task["id"])
        assert intake.github.writes == ["POST"] * 3
        assert intake.github.comments[0] == claim
        assert reopened.db.execute("PRAGMA user_version").fetchone()[0] == 5
    finally:
        reopened.close()


@pytest.mark.parametrize("failure", ["lost", "absent", "interrupted", "limited"])
async def test_unknown_claim_never_reposts_or_runs_before_confirmation(intake, store, failure):
    intake.github.failure = failure
    if failure == "interrupted":
        with pytest.raises(asyncio.CancelledError):
            await intake.scan()
    else:
        await intake.scan()
    assert bool(store.tasks()) == (failure == "lost")
    intake.github.failure = ""
    restarted = Discovery(store, intake.config if failure == "limited" else Config(), intake.github)
    async with restarted.active(once=True):
        assert bool(store.tasks()) == (failure != "absent")
    # A confirmed lost response may publish the newly registered stage, never another anchor.
    assert intake.github.writes.count("POST") == 1 + (failure in {"limited", "lost"})
    assert sum(
        c["body"].startswith("<!-- gongcao:controller=") for c in intake.github.comments
    ) == (failure != "absent")
    assert not store.db.execute("SELECT 1 FROM runs").fetchone()
    if failure == "absent":
        assert "refusing replay" in restarted.records()[0]["reason"]


async def test_refresh_only_current_status_without_scanning_and_respects_owner_lock(
    intake, store, monkeypatch
):
    import fcntl

    from gongcao.discovery import lock_path

    await intake.scan()
    task = store.tasks()[0]
    assert len(store.tasks()) == 1
    intake.github.calls.clear()
    writes = len(intake.github.writes)
    await intake.publish(intake.records()[0])
    assert intake.github.calls == {"read": 1} and len(intake.github.writes) == writes

    async def forbidden():
        pytest.fail("A status refresh must not scan for other issues")

    monkeypatch.setattr(intake, "scan", forbidden)
    Controls(store).issue(task["id"], "pause")
    writes = len(intake.github.writes)
    with lock_path(task["snapshot"]["repository"]).open("a") as owner:
        fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
        await intake.refresh(task["id"])
        assert intake.records()[0]["dirty"]
        assert len(intake.github.writes) == writes
    await intake.refresh(task["id"])
    assert len(store.tasks()) == 1 and len(intake.github.writes) == writes + 1
    assert intake.github.calls == {"read": 2, "pages": 2} and not intake.records()[0]["dirty"]
    assert "waiting_instruction" in intake.github.comments[-1]["body"]
    claim = deepcopy(intake.github.comments[0])
    mutate = intake.github.mutate

    async def completed(*args, **kwargs):
        result = await mutate(*args, **kwargs)
        # A separate controller connection enqueues while the first POST awaits confirmation.
        other = Store(store.root)
        try:
            other.halt(task["id"], State.HUMAN, "Missing acceptance package")
        finally:
            other.close()
        return result

    monkeypatch.setattr(intake.github, "mutate", completed)
    Controls(store).issue(task["id"], "auto", policy=intake.config.policy_hash)
    await intake.refresh(task["id"])
    assert intake.github.comments[0] == claim and intake.github.writes == ["POST"] * 4
    assert len({c["body"].splitlines()[0] for c in intake.github.comments[1:]}) == 3
    history = deepcopy(intake.github.comments)
    assert all("Correction of event" not in c["body"] for c in history)
    previous = history[-1]
    event_id = previous["body"].splitlines()[0].split(":")[1].split()[0]
    monkeypatch.setattr(intake.github, "mutate", mutate)
    store.halt(task["id"], State.HUMAN, "Package exists; authorization missing", correction=True)
    await Discovery(store, Config(), intake.github).refresh(task["id"])
    correction = intake.github.comments[-1]["body"]
    assert f"Correction of event `{event_id}`" in correction
    assert f"{task['url']}#issuecomment-{previous['id']}" in correction
    assert intake.github.comments[:-1] == history and intake.github.writes == ["POST"] * 5
    assert intake.github.rows[task["snapshot"]["number"]]["body"] == task["snapshot"]["body"]


@pytest.mark.parametrize("failure", ["absent", "limited"])
async def test_progress_failure_is_durable_without_stopping_work_and_preserves_owner(
    intake, store, monkeypatch, failure
):
    await intake.scan()
    task = store.tasks()[0]
    intake.github.failure = failure
    Controls(store).issue(task["id"], "pause")
    await intake.cycle(discover=False)
    row = intake.records()[0]
    event = json.loads(row["data"])["progress"][0]
    assert row["dirty"] and event["attempted"] == (failure == "absent") and row["reason"]
    assert store.task(task["id"])["state"] == State.WAITING_INSTRUCTION
    writes = len(intake.github.writes)
    intake.github.failure = ""
    restarted = Discovery(store, Config(), intake.github)
    await restarted.cycle(discover=False)
    assert len(intake.github.writes) == writes
    if failure == "absent":
        store.halt(task["id"], State.HUMAN, "New milestone behind unknown POST")
        with pytest.raises(ValueError, match="refusing replay"):
            await restarted.publish(restarted.records()[0])
        assert len(intake.github.writes) == writes
        intake.github.comments.append({"id": 2, "user": {"login": "owner"}, "body": event["body"]})
    restarted.retry.clear()
    import time

    future = time.time() + 1000
    monkeypatch.setattr("gongcao.discovery.time.time", lambda: future)
    await restarted.cycle(discover=False)
    assert not json.loads(restarted.records()[0]["data"])["progress"]
    assert not restarted.records()[0]["dirty"]
    assert len(intake.github.writes) == writes + 1
    intake.github.comments[0]["user"]["login"] = "other"
    with pytest.raises(ValueError, match="author"):
        await restarted.publish(restarted.records()[0])


@pytest.mark.parametrize("lost_response", [False, True])
async def test_status_recovers_after_repeated_failures_and_restart_without_replaying_post(
    intake, store, monkeypatch, lost_response
):
    import time

    await intake.scan()
    task_id = store.tasks()[0]["id"]
    Controls(store).issue(task_id, "pause")
    now = time.time()
    monkeypatch.setattr("gongcao.discovery.time.time", lambda: now)
    original_owned, original_mutate = intake.owned, intake.github.mutate
    original_instructions = intake.github.instructions
    offline = not lost_response
    reads = 0

    async def owned(self, row):
        nonlocal reads
        reads += 1
        if offline:
            raise ConnectionError("Status read unavailable")
        return await original_owned(row)

    async def mutate(*args, **kwargs):
        nonlocal offline
        result = await original_mutate(*args, **kwargs)
        if lost_response:
            offline = True
            raise ConnectionError("POST applied, response lost")
        return result

    async def instructions(task):
        if offline:
            raise ConnectionError("Comment pages unavailable")
        return await original_instructions(task)

    monkeypatch.setattr(Discovery, "owned", owned)
    monkeypatch.setattr(intake.github, "mutate", mutate)
    monkeypatch.setattr(intake.github, "instructions", instructions)
    posts = intake.github.writes.count("POST")
    # Exceed the old three-attempt cutoff and reach the capped delay.
    for failures in range(1, 8):
        await intake.handoff(task_id)
        row = intake.records()[0]
        retry = json.loads(row["data"])["status_retry"]
        assert retry["failures"] == failures
        assert retry["next_at"] - now == min(300, 5 * 2**failures)
        attempted_reads = reads
        await Discovery(store, intake.config, intake.github).handoff(task_id)
        assert reads == attempted_reads  # No busy retry, including after publisher recreation.
        now = retry["next_at"]

    reopened = Store(store.root)
    try:
        restarted = Discovery(reopened, intake.config, intake.github)
        offline = False
        await restarted.handoff(task_id)
        row = restarted.records()[0]
        assert not row["dirty"] and not row["intent"] and not row["reason"]
        assert "status_retry" not in json.loads(row["data"])
        assert row["confirmed"] == intake.github.comments[0]["body"]
        assert json.loads(row["data"])["progress_last"]["comment_id"] == 2
        assert intake.github.writes.count("POST") == posts + 1
        await restarted.handoff(task_id)
        assert intake.github.writes.count("POST") == posts + 1
    finally:
        reopened.close()


@pytest.mark.parametrize("applied", [False, True])
async def test_legacy_status_intent_is_read_only(intake, store, applied):
    await intake.scan()
    row = intake.records()[0]
    intended = row["confirmed"] + "\nHistorical status update"
    intake.save(row["url"], intent=intended)
    if applied:
        intake.github.comments[0]["body"] = intended
        await intake.publish(intake.records()[0])
        assert intake.records()[0]["confirmed"] == intended and not intake.records()[0]["intent"]
    else:
        with pytest.raises(ValueError, match="refusing replay"):
            await intake.publish(intake.records()[0])
        assert intake.records()[0]["intent"] == intended
    assert intake.github.writes == ["POST"]


@pytest.mark.parametrize("unsafe", [False, True])
async def test_default_branch_refresh_invalidates_or_holds_remote_intents(
    intake, store, repo, unsafe
):
    await intake.scan()
    task = store.tasks()[0]
    store.record(task, "analysis", "", {"proof": "old"})
    if unsafe:
        store.intent(task, "unknown", "push", "{}")
    await command("git", "commit", "--allow-empty", "-qm", "new default", cwd=str(repo))
    intake.github.sha = (await command("git", "rev-parse", "HEAD", cwd=str(repo))).strip()
    intake.github.branch = "release"  # Old main still exists: cached branch names are unsafe here.
    async with Lease(store, task["id"]):
        with pytest.raises(InstructionChanged):
            await Recovery(store, intake.github).sync(task)
    current = store.task(task["id"])
    assert current["state"] == (State.RECONCILE if unsafe else State.WAITING_INSTRUCTION)
    assert current["target_sha"] == (task["target_sha"] if unsafe else intake.github.sha)
    assert bool(store.artifact(task["id"], "analysis", "")) == unsafe
    assert current["stage"] == Stage.ANALYSIS


@pytest.mark.parametrize("status", ["403", "429"])
async def test_scan_errors_back_off_without_changing_registered_tasks(
    intake, store, task_id, status
):
    before = store.task(task_id)
    intake.github.failure = status
    await intake.scan()
    assert not intake.due(intake.config.discovery.sources[0].repo) and store.task(task_id) == before
    assert not intake.github.writes


@pytest.mark.parametrize("entry", ["workflow", "publisher"])
async def test_merged_fact_wins_over_new_default_base_without_operators(intake, store, entry):
    await intake.scan()
    task = store.tasks()[0]
    state = State.COMPLETED if entry == "publisher" else State.WAITING_INSTRUCTION
    with store.db:
        store.db.execute(
            "UPDATE tasks SET pr_number=9,stage=?,state=? WHERE id=?",
            (Stage.MERGEABLE, state, task["id"]),
        )
    # Validation and the final stage must retain the actual current-SHA check results.
    with store.db:
        store.db.execute(
            "UPDATE tasks SET stage=?,state=? WHERE id=?",
            (Stage.VALIDATION, State.WAITING_DEPENDENCY, task["id"]),
        )
    store.record(
        store.task(task["id"]),
        "quality-results",
        "test",
        {"items": [{"category": "internal", "status": "passed"}]},
    )
    store.record(store.task(task["id"]), "validation", "test", {})
    store.transition(store.task(task["id"]), Stage.MERGEABLE, State.COMPLETED, "Await human merge")
    await intake.handoff(task["id"])
    assert "`mergeable`" in intake.github.comments[-1]["body"]
    assert "Controller checks: internal: PASS" in intake.github.comments[-1]["body"]
    with store.db:
        store.db.execute("UPDATE tasks SET state=? WHERE id=?", (state, task["id"]))
    intake.github.rows[9] = intake.github.rows[1] | {
        "merged": True,
        "state": "closed",
        "head_sha": task["target_sha"],
        "base_sha": "b" * 40,
    }
    intake.github.sha = "0" * 40  # A terminal read must not fetch or replace this baseline.
    assert not intake.config.copilot_operators
    if entry == "workflow":
        async with Lease(store, task["id"]):
            await Recovery(store, intake.github).sync(store.task(task["id"]))
    await intake.cycle(discover=False)
    current = store.task(task["id"])
    assert (current["stage"], current["state"]) == (Stage.MERGED, State.COMPLETED)
    assert "`merged`" in intake.github.comments[-1]["body"] and not current["status_sync"]["dirty"]
    assert not store.runs(task["id"])
