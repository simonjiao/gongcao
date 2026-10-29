import json
from copy import deepcopy
from dataclasses import replace
from datetime import UTC, datetime
from pathlib import Path

import pytest
from test_pr2 import fixture_github as fixture_github
from test_pr2 import policy as policy
from test_runner import install_worker

from gongcao.control import Controls
from gongcao.github import command
from gongcao.model import Stage, State
from gongcao.store import Store
from gongcao.workflow import Workflow
from qa.checkpoint_fixture import WORKER


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
        if method == "PATCH":
            item = next(c for c in comments if c["id"] == int(path.rsplit("/", 1)[1]))
            item.update(payload)
            return deepcopy(item)
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
    return config, fixture_github, post, status, step


async def test_offline_step_block_save_handoff_retry_inherits_commit_and_pauses_at_review(
    store, task_id, blocked
):
    config, github, post, status, step = blocked
    first = store.runs(task_id)[-1]
    saved = first["details"]["save"]
    assert saved["state"] == "confirmed"
    assert github.pull is None
    assert store.task(task_id)["target_sha"] == first["target_sha"]
    assert not store.task(task_id)["control"]["spent"]
    assert store.evidence(task_id)["instructions"][-1]["status"] == "accepted"
    assert saved["sha"] in status["body"] and "NOT_RUN" in status["body"]
    assert "/gongcao retry" in status["body"] and "original/r1" in status["body"]
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
        assert "Remote checkpoint: unchanged" in status["body"]
    elif save["state"] == "pending":
        assert store.task(task_id)["state"] == State.RECONCILE
        assert not (await Recovery(store, github).recover(task_id))["recovered"]
        assert len(store.evidence(task_id)["operations"]) == 1
        assert "Saved WIP:" not in status["body"]
    else:
        assert save["state"] == "confirmed" and len(operations) == 1
        async with Lease(store, task_id) as lease:
            assert lease.acquired
            await Controlled(store, config, github).checkpoint(store.task(task_id), run)
        assert store.runs(task_id)[-1]["details"]["save"]["sha"] == save["sha"]
        assert len(store.evidence(task_id)["operations"]) == 1


def test_v4_upgrade_preserves_history_without_inventing_execution_defaults(store, task_id):
    from gongcao.model import Role

    run = store.begin_run(task_id, Role.ANALYST)
    with store.db:
        store.db.execute("ALTER TABLE runs DROP COLUMN details")
        store.db.execute("PRAGMA user_version=4")
    for _ in range(2):
        reopened = Store(store.root)
        try:
            assert reopened.db.execute("PRAGMA user_version").fetchone()[0] == 5
            assert reopened.runs(task_id)[0]["details"] == {}
            assert reopened.runs(task_id)[0]["id"] == run
        finally:
            reopened.close()
