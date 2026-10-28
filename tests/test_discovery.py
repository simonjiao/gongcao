"""Intake risks at existing GitHub/SQLite seams; workflow/OS behavior lives in CLI tests."""

import asyncio
import hashlib
import json
import subprocess
from copy import deepcopy
from dataclasses import replace

import pytest

from gongcao.config import Config, DiscoveryConfig, Source
from gongcao.control import Controls, InstructionChanged
from gongcao.discovery import Discovery
from gongcao.github import GitHub, command
from gongcao.leases import Lease
from gongcao.model import Stage, State
from gongcao.recovery import Recovery
from gongcao.store import Store


@pytest.fixture
def intake(store, repo, sha, snapshot):
    name = "example/discovery-" + hashlib.sha256(str(store.root).encode()).hexdigest()[:12]
    snapshot.update(repository=name, url=f"https://github.com/{name}/issues/1")
    subprocess.run(
        ["git", "remote", "set-url", "origin", f"https://github.com/{name}.git"],
        cwd=repo,
        check=True,
    )

    class API(GitHub):
        def __init__(self):
            self.rows = {
                n: snapshot
                | {
                    "number": n,
                    "url": snapshot["url"][:-1] + str(n),
                    "labels": [{"name": "agent-ready"}],
                    "assignees": [],
                }
                for n in range(1, 7)
            }
            self.rows[2]["pull_request"] = {}
            self.rows[3]["labels"] = [{"name": "agent-ready-extra"}]
            self.comments, self.writes, self.failure = [], [], ""
            self.sha = sha

        async def read(self, path):
            if path == "user":
                return {"login": "owner"}
            if "/comments/" in path:
                item = deepcopy(
                    next(c for c in self.comments if c["id"] == int(path.rsplit("/", 1)[1]))
                )
                # Real GitHub list/detail payloads use different avatar URL variants.
                item["user"]["avatar_url"] = "https://avatars.example/variant"
                return item
            if "/issues/" in path:
                return deepcopy(self.rows[int(path.rsplit("/", 1)[1])])
            return (
                {"object": {"sha": self.sha}} if "/git/ref/" in path else {"default_branch": "main"}
            )

        async def snapshot(self, target):
            return deepcopy(self.rows[target.number])

        async def pages(self, path, field=None):
            if self.failure in {"403", "429"}:
                raise PermissionError("HTTP " + self.failure)
            if "/labels" in path:
                return self.rows[int(path.split("/issues/")[1].split("/")[0])]["labels"]
            if "/timeline" in path:
                return (
                    [{"source": {"issue": {"pull_request": {"url": "handled"}}}}]
                    if "/4/" in path
                    else []
                )
            if "/comments" in path:
                return deepcopy(self.comments)
            return list(reversed(list(self.rows.values())))

        async def mutate(self, path, payload, *, method="POST"):
            self.writes.append(method)
            if self.failure == "absent":
                raise ConnectionError("POST result unknown")
            if method == "POST":
                self.comments.append(
                    {"id": len(self.comments) + 1, "user": {"login": "owner"}, **payload}
                )
            else:
                self.comments[0].update(payload)
            if self.failure == "lost":
                raise ConnectionError("Reply lost after remote write")
            if self.failure == "interrupted":
                raise asyncio.CancelledError
            return deepcopy(self.comments[0])

    config = replace(Config(), discovery=DiscoveryConfig(True, 60, 1, (Source(name, repo),)))
    return Discovery(store, config, API())


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
        assert intake.github.writes == ["POST", "PATCH"]
        other = Store(tmp_path / "other-state")
        try:
            with pytest.raises(ValueError, match="already owns"):
                async with Discovery(other, intake.config, intake.github).active(once=True):
                    pytest.fail("Another state directory acquired the same repository")
        finally:
            other.close()
        await intake.scan()
        assert len(store.tasks()) == 2 and len(intake.github.comments) == 1
    reopened = Store(store.root)
    try:
        disabled = Discovery(reopened, Config(), intake.github)
        async with disabled.active(once=True):
            assert len(reopened.tasks()) == 2 and len(intake.github.writes) == 2
        assert reopened.db.execute("PRAGMA user_version").fetchone()[0] == 4
    finally:
        reopened.close()


@pytest.mark.parametrize("failure", ["lost", "absent", "interrupted"])
async def test_unknown_claim_never_reposts_or_runs_before_confirmation(intake, store, failure):
    intake.github.failure = failure
    if failure == "interrupted":
        with pytest.raises(asyncio.CancelledError):
            await intake.scan()
    else:
        await intake.scan()
    assert bool(store.tasks()) == (failure == "lost")
    intake.github.failure = ""
    restarted = Discovery(store, Config(), intake.github)
    async with restarted.active(once=True):
        assert bool(store.tasks()) == (failure != "absent")
    assert intake.github.writes.count("POST") == 1
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
    assert not intake.records()[0]["dirty"]
    assert "waiting_instruction" in intake.github.comments[0]["body"]


async def test_progress_failure_is_durable_without_stopping_work_and_preserves_owner(intake, store):
    await intake.scan()
    task = store.tasks()[0]
    intake.github.failure = "absent"
    Controls(store).issue(task["id"], "pause")
    await intake.cycle(discover=False)
    row = intake.records()[0]
    assert row["dirty"] and row["intent"] and row["reason"]
    assert store.task(task["id"])["state"] == State.WAITING_INSTRUCTION
    writes = len(intake.github.writes)
    intake.github.failure = ""
    restarted = Discovery(store, Config(), intake.github)
    await restarted.cycle(discover=False)
    assert len(intake.github.writes) == writes  # Unobserved PATCH is never blindly replayed.
    intake.github.comments[0]["body"] = row["intent"]
    restarted.retry.clear()
    await restarted.cycle(discover=False)
    assert not restarted.records()[0]["intent"] and not restarted.records()[0]["dirty"]
    intake.github.comments[0]["user"]["login"] = "other"
    with pytest.raises(ValueError, match="author"):
        await restarted.publish(restarted.records()[0])


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
    with store.db:
        store.db.execute(
            "UPDATE tasks SET pr_number=9,stage=?,state=? WHERE id=?",
            (Stage.MERGEABLE, State.WAITING_INSTRUCTION, task["id"]),
        )
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
    assert "`merged`" in intake.github.comments[0]["body"] and not current["status_sync"]["dirty"]
    assert not store.runs(task["id"])


def test_discovery_configuration_defaults_and_rejections(tmp_path):
    assert not Config.load(None).discovery.enabled
    for raw in (
        {"enabled": True},
        {"interval_seconds": 0},
        {"max_new_per_scan": True},
        {"sources": [{"repo": "example/demo", "path": "relative"}]},
        {"unexpected": 1},
    ):
        with pytest.raises(ValueError):
            DiscoveryConfig.load(raw)
    path = tmp_path / "config.yaml"
    path.write_text(
        "discovery:\n  enabled: true\n  sources:\n    - repo: EXAMPLE/Demo\n"
        f"      path: {tmp_path}\n"
    )
    assert Config.load(path).discovery.sources[0].repo == "example/demo"


def test_discovery_qa_evidence_rejects_unknown_writes_and_false_control_claims():
    from qa.discovery import verify

    data = {
        "records": [
            {
                "url": f"issue:{number}",
                "task_id": 1,
                "intent": "",
                "dirty": 0,
                "comment_id": number,
                "confirmed": "claim",
                "data": json.dumps({"marker": "claim", "mode": mode}),
            }
            for number, mode in ((10, "step"), (11, "auto"))
        ],
        "comments": [
            {"id": number, "user": {"login": "owner"}, "body": "claim"} for number in (10, 11)
        ],
        "excluded": {"url": "issue:12"},
        "step": {
            "state": "waiting_instruction",
            "stage": "pending_development",
            "evidence": {
                "instructions": [
                    {
                        "id": "github:1",
                        "status": "consumed",
                        "data": {"actor": "owner", "fingerprint": "proof"},
                    }
                ]
            },
        },
        "pause_id": "github:1",
        "before": {},
        "after": {},
    }
    verify(data, "owner")
    for change in (
        lambda d: d["records"][0].update(intent="unknown"),
        lambda d: d["comments"][0]["user"].update(login="other"),
        lambda d: d["step"]["evidence"]["instructions"][0].update(status="pending"),
        lambda d: d.update(after={"runs": ["new"]}),
    ):
        invalid = deepcopy(data)
        change(invalid)
        with pytest.raises(ValueError):
            verify(invalid, "owner")
