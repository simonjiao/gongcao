import json
from copy import deepcopy
from dataclasses import replace
from datetime import UTC, datetime
from pathlib import Path

import pytest
from _support.worker import install_worker

from gongcao.control import Controls
from gongcao.github import command
from gongcao.model import Stage, State
from gongcao.store import Store
from gongcao.workflow import Workflow
from qa.checkpoint_fixture import BLOCKED_AGAIN, WORKER


@pytest.fixture
async def blocked(store, task_id, fixture_github, policy, monkeypatch, request):
    config = replace(policy, copilot_operators=["owner"])
    comments = []

    def post(body, actor="owner"):
        stamp = datetime.now(UTC).isoformat()
        item = {
            "id": len(comments) + 1,
            "body": body,
            "user": {"login": actor},
            "created_at": stamp,
            "updated_at": stamp,
        }
        comments.append(item)
        return item

    async def instructions(task):
        return deepcopy(comments)

    old_read, old_mutate = fixture_github.read, fixture_github.mutate

    async def read(path):
        if "/comments/" in path:
            return deepcopy(next(c for c in comments if c["id"] == int(path.rsplit("/", 1)[1])))
        return await old_read(path)

    async def mutate(path, payload, *, method="POST"):
        if path.endswith("/comments"):
            assert method == "POST"
            return deepcopy(post(payload["body"]))
        return await old_mutate(path, payload)

    monkeypatch.setattr(fixture_github, "read", read)
    monkeypatch.setattr(fixture_github, "mutate", mutate)
    monkeypatch.setattr(fixture_github, "instructions", instructions)
    # Keep all Git operations real, redirect only the remote transport to a local bare repo.
    from gongcao.remote import command as routed

    monkeypatch.setattr("gongcao.recovery.command", routed)
    fault = getattr(request, "param", "")
    if fault in {"lost_push", "unknown_push"}:

        async def faulted(*args, **kwargs):
            if args[:2] == ("git", "push"):
                if fault == "lost_push":
                    await routed(*args, **kwargs)
                raise ConnectionError("lost push response")
            return await routed(*args, **kwargs)

        monkeypatch.setattr("gongcao.remote.command", faulted)
    source = WORKER
    if fault == "unchanged":
        source = source.replace("sample.write_text('partial work\\n')", "pass")
    if fault == "failed":
        source = source.replace(
            "conclusion = 'blocked'", "raise RuntimeError('worker failed after edit')"
        )
    install_worker(monkeypatch, source)
    controls = Controls(store)
    controls.issue(task_id, "step", policy=config.policy_hash)
    await Workflow(store, config, fixture_github).run(task_id)
    assert store.task(task_id)["stage"] == Stage.DEVELOPMENT
    assert store.task(task_id)["state"] == State.WAITING_INSTRUCTION
    marker = "<!-- gongcao:checkpoint-test -->"
    status = post(marker)
    task = store.task(task_id)
    with store.db:
        store.db.execute(
            "INSERT INTO claims(url,data,task_id,comment_id,confirmed) VALUES(?,?,?,?,?)",
            (
                task["url"],
                json.dumps(
                    {
                        "marker": marker,
                        "actor": "owner",
                        "repo": task["snapshot"]["repository"],
                        "base_sha": task["target_sha"],
                    }
                ),
                task_id,
                status["id"],
                marker,
            ),
        )
    step = post("/gongcao step")
    await controls.poll(task_id, config, fixture_github)
    await Workflow(store, config, fixture_github).run(task_id)
    assert store.task(task_id)["state"] in {State.HUMAN, State.FAILED, State.RECONCILE}, store.task(
        task_id
    )["reason"]
    return (
        config,
        fixture_github,
        post,
        lambda: next(
            (c for c in reversed(comments) if c["body"].startswith("<!-- gongcao-progress:")),
            status,
        ),
        step,
    )


async def test_offline_step_block_save_handoff_retry_inherits_commit_and_pauses_at_review(
    store, task_id, blocked, caplog
):
    caplog.set_level("INFO", logger="gongcao")
    config, github, post, status, step = blocked
    first = store.runs(task_id)[-1]
    saved = first["details"]["save"]
    assert saved["state"] == "confirmed"
    assert github.pull is None
    assert store.task(task_id)["target_sha"] == first["target_sha"]
    assert not store.task(task_id)["control"]["spent"]
    assert store.evidence(task_id)["instructions"][-1]["status"] == "accepted"
    assert saved["sha"] in status()["body"] and "NOT_RUN" in status()["body"]
    assert "/gongcao retry" in status()["body"] and "original/r1" in status()["body"]
    assert store.task(task_id)["status_sync"]["dirty"] == 0
    retry = post("/gongcao retry")
    restarted = Store(store.root)
    try:
        await Workflow(restarted, config, github).run(task_id)
        task = restarted.task(task_id)
        assert task["stage"] == Stage.REVIEW, task["reason"]
        assert task["state"] == State.WAITING_INSTRUCTION
        runs = restarted.runs(task_id)
        second = runs[-1]
        assert second["thread_id"] != first["thread_id"]
        assert "GitHub retry 已授权并完成恢复核验" in caplog.text
        assert second["details"]["source"]["sha"] == saved["sha"]
        assert (
            Path(second["worktree"], "sample.txt").read_text()
            == "partial work\ncompleted after retry\n"
        )
        parent = (
            await command("git", "rev-parse", task["target_sha"] + "^", cwd=task["repo_path"])
        ).strip()
        assert parent == saved["sha"]
        assert task["pr_number"] == 9 and task["control"]["spent"]
        receipts = {r["id"]: r for r in restarted.evidence(task_id)["instructions"]}
        assert receipts[f"github:{step['id']}"]["status"] == "superseded"
        assert receipts[f"github:{retry['id']}"]["status"] == "consumed"
        count = len(runs)
        await Workflow(restarted, config, github).run(task_id)
        assert len(restarted.runs(task_id)) == count
    finally:
        restarted.close()


@pytest.mark.parametrize("bad", ["unauthorized", "edited", "stale", "changed", "remote", "process"])
async def test_retry_rejects_unsafe_or_stale_permission(store, task_id, blocked, bad):
    config, github, post, status, step = blocked
    receipt = post("/gongcao retry", actor="stranger" if bad == "unauthorized" else "owner")
    if bad == "edited":
        receipt["updated_at"] = "2099-01-01T00:00:00Z"
    if bad == "stale":
        receipt["created_at"] = receipt["updated_at"] = "2020-01-01T00:00:00Z"
    if bad == "changed":
        github.issue["body"] += " changed requirements"
    if bad == "remote":
        saved = store.runs(task_id)[-1]["details"]["save"]
        await command(
            "git",
            "--git-dir",
            str(github.bare),
            "update-ref",
            "refs/heads/" + saved["branch"],
            store.task(task_id)["target_sha"],
        )
    if bad == "process":
        with store.db:
            store.db.execute(
                "INSERT INTO processes VALUES"
                "('unknown',?,'old','pid-sandbox',NULL,NULL,'uncertain')",
                (task_id,),
            )
    count = len(store.runs(task_id))
    await Workflow(store, config, github).run(task_id)
    assert len(store.runs(task_id)) == count
    assert github.pull is None


@pytest.mark.parametrize(
    "blocked", ["lost_push", "unknown_push", "unchanged", "failed"], indirect=True
)
async def test_save_failure_no_change_and_lost_response_do_not_duplicate_commits(
    store, task_id, blocked
):
    from gongcao.leases import Lease
    from gongcao.recovery import Recovery
    from gongcao.remote import Controlled

    config, github, post, status, step = blocked
    run = store.runs(task_id)[-1]
    save = run["details"]["save"]
    assert github.pull is None and not store.task(task_id)["control"]["spent"]
    operations = store.evidence(task_id)["operations"]
    if save["state"] == "unchanged":
        assert not operations
        assert "Remote checkpoint: unchanged" in status()["body"]
    elif save["state"] == "pending":
        assert store.task(task_id)["state"] == State.RECONCILE
        assert not (await Recovery(store, github).recover(task_id))["recovered"]
        assert len(store.evidence(task_id)["operations"]) == 1
        assert "Saved WIP:" not in status()["body"]
    else:
        assert save["state"] == "confirmed" and len(operations) == 1
        async with Lease(store, task_id) as lease:
            assert lease.acquired
            await Controlled(store, config, github).checkpoint(store.task(task_id), run)
        assert store.runs(task_id)[-1]["details"]["save"]["sha"] == save["sha"]
        assert len(store.evidence(task_id)["operations"]) == 1


@pytest.mark.parametrize("action", ["pause", "cancel"])
@pytest.mark.parametrize("arrival", ["after_run", "before_push", "before_commit"])
async def test_late_pause_saves_but_cancellation_preserves_local_output(
    store, task_id, fixture_github, policy, monkeypatch, arrival, action
):
    from gongcao.remote import Controlled
    from gongcao.runner import Runner

    controls = Controls(store)
    controls.issue(task_id, "until", "development", policy=policy.policy_hash)
    await Workflow(store, policy, fixture_github).run(task_id)
    controls.issue(task_id, "step", policy=policy.policy_hash)
    triggered = False

    def interrupt():
        if action == "cancel":
            store.cancel(task_id)
        else:
            controls.issue(task_id, "pause", safe=True)

    if arrival == "after_run":
        original = Runner.run

        async def late_pause(self, *args, **kwargs):
            result = await original(self, *args, **kwargs)
            interrupt()
            return result

        monkeypatch.setattr(Runner, "run", late_pause)
    elif arrival == "before_push":
        original = Controlled.before

        async def late_pause(self, task, kind, **kwargs):
            nonlocal triggered
            if kind == "push" and not triggered:
                triggered = True
                interrupt()
            return await original(self, task, kind, **kwargs)

        monkeypatch.setattr(Controlled, "before", late_pause)
    else:
        from gongcao.remote import command as routed

        async def late_interrupt(*args, **kwargs):
            nonlocal triggered
            result = await routed(*args, **kwargs)
            if args[:3] == ("git", "diff", "--cached") and not triggered:
                triggered = True
                interrupt()
            return result

        monkeypatch.setattr("gongcao.remote.command", late_interrupt)
    await Workflow(store, policy, fixture_github).run(task_id)
    assert fixture_github.pull is None
    run = store.runs(task_id)[-1]
    if action == "pause":
        assert store.task(task_id)["state"] == State.WAITING_INSTRUCTION
        assert run["details"]["save"]["state"] == "confirmed"
    else:
        assert store.task(task_id)["state"] == State.CANCELLED
        assert not store.evidence(task_id)["operations"]
        assert "save" not in run["details"]
        assert (await command("git", "rev-parse", "HEAD", cwd=run["worktree"])).strip() == run[
            "details"
        ]["source"]["sha"]
        assert (await command("git", "status", "--porcelain", cwd=run["worktree"])).strip()
        assert Path(run["worktree"], "sample.txt").read_text() == "incomplete\n"
        assert not await command(
            "git", "--git-dir", str(fixture_github.bare), "for-each-ref", "refs/heads/gongcao"
        )


@pytest.mark.parametrize("cancelled", ["cancel_requested=1", "state='cancelled'"])
async def test_checkpoint_guard_refuses_cancellation_even_with_stale_task(
    store, task_id, blocked, cancelled
):
    from gongcao.leases import Lease

    expected = store.task(task_id)
    with store.db:
        store.db.execute(f"UPDATE tasks SET {cancelled} WHERE id=?", (task_id,))
    async with Lease(store, task_id) as lease:
        assert lease.acquired
        with pytest.raises(ValueError, match="authorize saving"):
            store.save_guard(expected)


@pytest.mark.parametrize("arrival", ["before_write", "during_preflight"])
async def test_cancel_after_checkpoint_intent_retains_commit_without_pushing(
    store, task_id, fixture_github, policy, monkeypatch, arrival
):
    from gongcao.remote import Controlled

    install_worker(monkeypatch, WORKER)
    Controls(store).issue(task_id, "auto", policy=policy.policy_hash)
    original = Controlled.before
    remote_head = Controlled.remote_head
    writing = False

    async def cancel_before_write(self, task, kind, **kwargs):
        nonlocal writing
        if kind == "checkpoint" and kwargs.get("finish_operation"):
            if arrival == "before_write":
                store.cancel(task_id)
            else:
                writing = True
        return await original(self, task, kind, **kwargs)

    async def cancel_during_preflight(self, task, branch):
        nonlocal writing
        result = await remote_head(self, task, branch)
        if writing:
            writing = False
            store.cancel(task_id)
        return result

    monkeypatch.setattr(Controlled, "before", cancel_before_write)
    monkeypatch.setattr(Controlled, "remote_head", cancel_during_preflight)
    await Workflow(store, policy, fixture_github).run(task_id)
    assert store.task(task_id)["state"] == State.CANCELLED
    run = store.runs(task_id)[-1]
    saved = run["details"]["save"]
    assert saved["state"] == "pending"
    assert (await command("git", "rev-parse", "HEAD", cwd=run["worktree"])).strip() == saved["sha"]
    operations = store.evidence(task_id)["operations"]
    assert operations == []  # Both cancellations happen before the Git write transport.
    assert Path(run["worktree"], "sample.txt").read_text() == "partial work\n"
    assert fixture_github.pull is None
    assert not await command(
        "git", "--git-dir", str(fixture_github.bare), "for-each-ref", "refs/heads/gongcao"
    )


async def test_retry_without_changes_keeps_confirmed_checkpoint_link(
    store, task_id, blocked, monkeypatch
):
    from gongcao.discovery import Discovery

    config, github, post, status, step = blocked
    saved = store.runs(task_id)[-1]["details"]["save"]
    install_worker(monkeypatch, BLOCKED_AGAIN)
    post("/gongcao retry")
    await Workflow(store, config, github).run(task_id)
    current = store.runs(task_id)[-1]
    assert store.task(task_id)["state"] == State.HUMAN
    assert current["details"]["source"]["sha"] == saved["sha"]
    assert current["details"]["save"]["state"] == "unchanged"
    assert len(store.evidence(task_id)["operations"]) == 1
    assert "Remote checkpoint: unchanged" in status()["body"]
    assert f"/commit/{saved['sha']}" in status()["body"]
    assert f"/tree/{saved['branch']}" in status()["body"]
    assert saved["run_id"] in status()["body"] and "/gongcao retry" in status()["body"]

    # An unconfirmed new save must not be presented as remotely saved.
    store.run_details(current["id"], save={"state": "pending", "sha": "f" * 40})
    discovery = Discovery(store, config, github)
    await discovery.handoff(task_id)
    assert "Remote checkpoint: pending" in discovery.render(discovery.records()[0])
    assert f"/commit/{saved['sha']}" in status()["body"]
    assert "/commit/" + "f" * 40 not in status()["body"]

    # Changed requirements invalidate the old checkpoint's relevance to this task version.
    task = store.task(task_id)
    store.sync(task_id, task["snapshot"] | {"body": "Changed requirements"})
    await discovery.handoff(task_id)
    assert "Saved WIP:" not in status()["body"]


async def test_older_retry_cannot_clear_newer_unverified_pause(
    store, task_id, blocked, monkeypatch
):
    config, github, post, status, step = blocked
    older = post("/gongcao retry")
    newer = post("/gongcao pause")
    await Controls(store).collect(task_id, config, github)
    original = github.read

    async def instructions(task):
        return deepcopy([status(), step, older])

    async def read(path):
        if path.endswith("/" + str(newer["id"])):
            raise PermissionError("HTTP 403")
        return await original(path)

    monkeypatch.setattr(github, "instructions", instructions)
    monkeypatch.setattr(github, "read", read)
    count = len(store.runs(task_id))
    await Workflow(store, config, github).run(task_id)
    assert len(store.runs(task_id)) == count
    assert store.task(task_id)["control"]["pause_requested"]
    assert store.task(task_id)["state"] == State.HUMAN


async def test_transient_retry_read_failure_remains_recoverable(
    store, task_id, blocked, monkeypatch
):
    from gongcao.recovery import Recovery

    config, github, post, status, step = blocked
    post("/gongcao retry")
    original = Recovery.reconcile

    async def unavailable(*args):
        raise ConnectionError("read unavailable")

    monkeypatch.setattr(Recovery, "reconcile", unavailable)
    count = len(store.runs(task_id))
    await Workflow(store, config, github).run(task_id)
    assert len(store.runs(task_id)) == count
    assert store.task(task_id)["state"] == State.HUMAN
    assert store.evidence(task_id)["instructions"][-1]["status"] == "pending"
    monkeypatch.setattr(Recovery, "reconcile", original)
    with store.db:
        store.db.execute("UPDATE retries SET next_at=0 WHERE task_id=?", (task_id,))
    await Workflow(store, config, github).run(task_id)
    assert store.task(task_id)["stage"] == Stage.REVIEW, store.task(task_id)["reason"]


async def test_long_report_and_persistent_status_backoff(store, task_id, blocked, monkeypatch):
    from gongcao.discovery import Discovery

    config, github, post, status, step = blocked
    run = store.runs(task_id)[-1]
    result = json.loads(run["result"])
    result["basis"] = ["x" * 100_000]
    result["next_steps"] = ["Need original/r1 packages " + "x" * 100_000]
    with store.db:
        store.db.execute("UPDATE runs SET result=? WHERE id=?", (json.dumps(result), run["id"]))
        store.db.execute("UPDATE claims SET dirty=1 WHERE task_id=?", (task_id,))
    publisher = Discovery(store, config, github)
    body = publisher.render(publisher.records()[0])
    assert len(body) < 60_000
    assert "Saved WIP:" in body and "/gongcao retry" in body
    calls = 0

    async def unavailable(*args, **kwargs):
        nonlocal calls
        calls += 1
        raise ConnectionError("read unavailable")

    monkeypatch.setattr(github, "instructions", unavailable)
    store.owned_comments.clear()  # Exercise first-ownership reconciliation and persisted backoff.
    with store.db:
        store.db.execute("UPDATE claims SET dirty=1 WHERE task_id=?", (task_id,))
    await publisher.handoff(task_id)
    assert calls == 1
    for _ in range(3):
        await Discovery(store, config, github).handoff(task_id)
    assert calls == 1  # A fresh publisher must honor the persisted backoff.
    assert store.task(task_id)["status_sync"]["dirty"]


@pytest.mark.parametrize("change", ["execution", "roles"])
async def test_fresh_retry_adopts_execution_changes_but_preserves_history(
    store, task_id, blocked, change
):
    config, github, post, status, step = blocked
    old = store.runs(task_id)[-1]
    old_execution = dict(old["details"]["execution"])
    changed = replace(config, model="configured-model", reasoning_effort="high")
    if change == "roles":
        from gongcao.model import Role

        changed = replace(changed, prompts=changed.prompts | {Role.DEVELOPER: "different role"})
    post("/gongcao retry")
    await Workflow(store, changed, github).run(task_id)
    if change == "roles":
        assert len(store.runs(task_id)) == 2
        assert "Role policy" in store.evidence(task_id)["instructions"][-1]["reason"]
    else:
        assert store.task(task_id)["stage"] == Stage.REVIEW, store.task(task_id)["reason"]
        new = store.runs(task_id)[-1]
        assert new["details"]["execution"]["model"] == "configured-model"
        assert new["details"]["execution"]["reasoning_effort"] == "high"
        assert new["details"]["source"]["sha"] == old["details"]["save"]["sha"]
        assert "configured-model" in status()["body"]
    retained = next(r for r in store.runs(task_id) if r["id"] == old["id"])
    assert retained["details"]["execution"] == old_execution


async def test_retry_order_uses_comment_ids_not_collection_order(store, task_id, blocked):
    config, github, post, status, step = blocked
    newest = post("/gongcao retry")
    newest["id"] = 100
    older = post("/gongcao retry")
    older["id"] = 99  # Collected later; must not starve the actual newer authorization.
    await Workflow(store, config, github).run(task_id)
    assert store.task(task_id)["stage"] == Stage.REVIEW, store.task(task_id)["reason"]
    assert store.task(task_id)["control"]["command_id"] == "github:100"
    receipts = {r["id"]: r for r in store.evidence(task_id)["instructions"]}
    assert receipts["github:99"]["status"] == "superseded"


async def test_retry_rechecks_barrier_under_the_consumption_transaction(
    store, task_id, blocked, monkeypatch
):
    from contextlib import contextmanager

    from gongcao.control import bind

    config, github, post, status, step = blocked
    candidate = post("/gongcao retry")
    old_transaction = Controls.transaction
    armed = False
    barrier = Controls.retry_barrier

    def observe(self, *args):
        nonlocal armed
        result = barrier(self, *args)
        if not self.db.in_transaction:
            armed = True
        return result

    @contextmanager
    def transaction(self):
        nonlocal armed
        # Model another collector's commit immediately before the consumption write lock.
        if armed and not self.db.in_transaction:
            armed = False
            task = store.task(task_id)
            with store.db:
                self.record(
                    task_id,
                    "github:100",
                    bind(
                        task,
                        {
                            "mode": "pause",
                            "target": None,
                            "feedback": "",
                            "actor": "owner",
                            "created": task["updated"],
                        },
                    ),
                    "pending",
                    "Instruction verification pending: HTTP 403",
                )
        with old_transaction(self):
            yield

    monkeypatch.setattr(Controls, "retry_barrier", observe)
    monkeypatch.setattr(Controls, "transaction", transaction)
    await Workflow(store, config, github).run(task_id)
    assert len(store.runs(task_id)) == 2
    receipts = {r["id"]: r for r in store.evidence(task_id)["instructions"]}
    assert receipts["github:100"]["status"] == "pending"
    assert receipts["github:" + str(candidate["id"])]["status"] != "accepted"
