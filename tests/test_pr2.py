import asyncio
import json
import sqlite3
import subprocess
from dataclasses import replace

import pytest
from test_runner import install_worker

from gongcao.config import Config
from gongcao.github import GitHub, command
from gongcao.model import Role, Stage, State
from gongcao.quality import Quality
from gongcao.remote import Controlled, UncertainWrite
from gongcao.store import Store
from gongcao.workflow import Workflow

WORKER = """
import json, pathlib, sys, uuid
from gongcao.plan import propose
data = json.loads(sys.stdin.readline())['context']
role = data['role']
sample = pathlib.Path('/workspace/sample.txt')
if role == 'developer':
    sample.write_text('complete\\n' if data['confirmed_findings'] else 'incomplete\\n')
conclusion = 'revise' if role == 'reviewer' and sample.read_text() == 'incomplete\\n' else 'ready'
plan = propose(data) if role=='analyst' else []
for item in plan:
    if item['category']=='e2e':
        item.update(required=False,reason='Offline protocol fixture; real E2E is not claimed')
print(json.dumps({'kind':'thread','data':{'thread_id':str(uuid.uuid4())}}))
print(json.dumps({'kind':'result','data':{
    'conclusion':conclusion,'summary':'Inspected the exact worktree',
    'basis':['sample.txt must be complete'],'target_sha':data['target_sha'],
    'next_steps':['Fix incomplete output' if conclusion=='revise' else 'Check controller gates'],
    'validation_plan':plan}}))
"""


class FixtureGitHub(GitHub):
    def __init__(self, snapshot, sha, bare):
        self.issue = dict(snapshot)
        self.sha, self.bare = sha, bare
        self.pull = None
        self.reviews = []
        self.ci = "success"
        self.decision = ""
        self.writes = []
        self.head_override = None

    def head(self):
        if self.head_override:
            return self.head_override
        if self.pull:
            return subprocess.check_output(
                [
                    "git",
                    "--git-dir",
                    str(self.bare),
                    "rev-parse",
                    f"refs/heads/{self.pull['head_ref']}",
                ],
                text=True,
            ).strip()
        return self.sha

    async def snapshot(self, target):
        if target.kind == "issues":
            return dict(self.issue)
        return self.pull | {"head_sha": self.head()}

    async def read(self, path):
        return {"object": {"sha": self.sha}} if "/git/ref/" in path else {"default_branch": "main"}

    async def pages(self, path, field=None):
        if "/reviews" in path:
            return list(self.reviews)
        if self.pull:
            return [
                {
                    "number": 9,
                    "state": self.pull["state"],
                    "body": self.pull["body"],
                    "head": {"sha": self.head()},
                    "base": {"ref": "main"},
                }
            ]
        return []

    async def mutate(self, path, payload):
        if path == "graphql":
            self.pull["draft"] = False
            return {"data": {}}
        self.writes.append((path, payload))
        if path.endswith("/reviews"):
            self.reviews.append(payload | {"id": len(self.reviews) + 1})
            return {"id": len(self.reviews)}
        self.pull = self.issue | {
            "url": "https://github.com/example/demo/pull/9",
            "kind": "pull",
            "number": 9,
            "node_id": "PR_fixture",
            "body": payload["body"],
            "base_ref": "main",
            "base_sha": self.sha,
            "base_repository": "example/demo",
            "head_repository": "example/demo",
            "head_ref": payload["head"],
            "draft": True,
            "merged": False,
            "author": "same-account",
        }
        return {"number": 9}

    async def gates(self, task):
        return {
            "headRefOid": self.head(),
            "isDraft": self.pull["draft"],
            "reviewDecision": self.decision,
            "mergeable": "MERGEABLE",
            "mergeStateStatus": "CLEAN" if not self.decision else "BLOCKED",
            "workflows": [
                {
                    "id": 1,
                    "run_attempt": 1,
                    "head_sha": self.head(),
                    "event": "pull_request",
                    "path": ".github/workflows/ci.yml",
                    "head_branch": self.pull["head_ref"],
                    "status": "completed" if self.ci else "in_progress",
                    "conclusion": self.ci,
                    "target_proof": {
                        "pr_number": 9,
                        "repository": "example/demo",
                        "head_sha": self.head(),
                        "base_sha": self.pull["base_sha"],
                        "base_ref": self.pull["base_ref"],
                        "run_id": 1,
                        "attempt": 1,
                    },
                }
            ],
        }


@pytest.fixture
def fixture_github(tmp_path, repo, sha, snapshot, monkeypatch):
    bare = tmp_path / "remote.git"
    subprocess.run(["git", "clone", "--bare", "--quiet", str(repo), str(bare)], check=True)
    github = FixtureGitHub(snapshot, sha, bare)

    async def routed(*args, **kwargs):
        if args[:2] in {("git", "push"), ("git", "ls-remote")}:
            args = (*args[:2], str(bare), *args[3:])
        if args[:3] == ("gh", "pr", "ready"):
            github.pull["draft"] = False
            return "ready"
        return await command(*args, **kwargs)

    monkeypatch.setattr("gongcao.remote.command", routed)
    install_worker(monkeypatch, WORKER)
    return github


@pytest.fixture
def policy(auth_file):
    return Config(auth_file=auth_file)


async def test_real_worktrees_review_revision_quality_and_ci_reach_human_merge(
    store, task_id, repo, fixture_github, policy, caplog
):
    caplog.set_level("INFO", logger="gongcao")
    await Workflow(store, policy, fixture_github).run(task_id)
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
    assert len(fixture_github.reviews) == 2
    assert (
        store.db.execute('SELECT count(*) FROM operations WHERE state="succeeded"').fetchone()[0]
        == 6
    )
    context = json.loads((store.root / "runs" / runs[3]["id"] / "context.json").read_text())
    assert context["confirmed_analysis"] is None
    assert context["quality_evidence"]["passed"]
    assert context["diff"]["head_sha"] == runs[3]["target_sha"]
    assert (await Quality(store, policy).run(task, include_e2e=True))["passed"]
    # Repeating the command neither calls a new agent nor duplicates any remote mutation.
    writes = len(fixture_github.writes)
    assert await Workflow(store, policy, fixture_github).run(task_id) == []
    assert len(fixture_github.writes) == writes


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


async def test_changed_quality_policy_invalidates_review_and_validation(
    store, task_id, fixture_github, policy
):
    await Workflow(store, policy, fixture_github).run(task_id)
    old = [r["id"] for r in store.runs(task_id) if r["role"] == "reviewer" and r["evidence_valid"]]
    changed = replace(
        policy,
        model="changed-policy",
        max_revisions=0,
    )
    await Workflow(store, changed, fixture_github).run(task_id)
    assert store.task(task_id)["state"] == State.COMPLETED
    assert not [r for r in store.runs(task_id) if r["id"] in old and r["evidence_valid"]]
    assert store.artifact(task_id, "validation", policy.policy_hash) is None


async def test_writes_require_verified_os_isolation(
    store, task_id, fixture_github, policy, monkeypatch
):
    from gongcao.sandbox import IsolationError

    async def reject(*args):
        raise IsolationError("Cannot verify isolation")

    monkeypatch.setattr("gongcao.remote.Sandbox.verify", reject)
    await Workflow(store, policy, fixture_github).run(task_id)
    assert store.task(task_id)["state"] == State.WAITING_ENVIRONMENT
    assert fixture_github.writes == []


@pytest.mark.parametrize("result", ["observed", "unknown"])
async def test_ambiguous_write_queries_remote_and_never_replays(
    store, task_id, policy, monkeypatch, result
):
    controlled = Controlled(store, policy, GitHub())

    async def before(task, kind, *, finish_operation=False, verified=None):
        return task

    monkeypatch.setattr(controlled, "before", before)
    observed = None
    calls = 0

    async def query():
        return observed

    async def write():
        nonlocal observed, calls
        calls += 1
        if result == "observed":
            observed = {"id": 7}
        raise RuntimeError("lost response")

    task = store.task(task_id)
    if result == "observed":
        assert await controlled.perform(task, "review", "9", {}, query, write) == {"id": 7}
        assert await controlled.perform(task, "review", "9", {}, query, write) == {"id": 7}
    else:
        with pytest.raises(UncertainWrite):
            await controlled.perform(task, "review", "9", {}, query, write)
        with pytest.raises(UncertainWrite, match="refusing replay"):
            await controlled.perform(task, "review", "9", {}, query, write)
    assert calls == 1


def test_target_change_invalidates_quality_artifacts(store, task_id, snapshot):
    task = store.task(task_id)
    store.record(task, "quality-results", "policy", {"passed": True})
    store.sync(task_id, snapshot | {"base_sha": "0" * 40})
    assert store.artifact(task_id, "quality-results", "policy") is None


@pytest.mark.parametrize("run_state", ["completed", "running"])
def test_pr1_schema_upgrade_preserves_history_and_restarts(
    tmp_path, repo, sha, snapshot, run_state
):
    root = tmp_path / "old"
    root.mkdir()
    db = sqlite3.connect(root / "gongcao.sqlite3")
    db.executescript("""
    CREATE TABLE tasks(id INTEGER PRIMARY KEY,url TEXT UNIQUE NOT NULL,repo_path TEXT NOT NULL,
      stage TEXT NOT NULL,state TEXT NOT NULL,target_sha TEXT NOT NULL,snapshot TEXT NOT NULL,
      reason TEXT NOT NULL DEFAULT '',cancel_requested INTEGER NOT NULL DEFAULT 0,
      updated REAL NOT NULL);
    CREATE TABLE runs(id TEXT PRIMARY KEY,task_id INTEGER NOT NULL REFERENCES tasks(id),
      role TEXT NOT NULL,state TEXT NOT NULL,target_sha TEXT NOT NULL,thread_id TEXT,
      worktree TEXT,context_hash TEXT,result TEXT,error TEXT,owner_pid INTEGER NOT NULL,
      started REAL NOT NULL,ended REAL,evidence_valid INTEGER NOT NULL DEFAULT 1);
    CREATE TABLE events(id INTEGER PRIMARY KEY,run_id TEXT NOT NULL REFERENCES runs(id),
      at REAL NOT NULL,
      kind TEXT NOT NULL,summary TEXT NOT NULL);
    """)
    db.execute(
        "INSERT INTO tasks VALUES(1,?,?,?,?,?,?,?,0,1)",
        (
            snapshot["url"],
            str(repo),
            "pending_analysis",
            "running" if run_state == "running" else "queued",
            sha,
            json.dumps(snapshot),
            "history",
        ),
    )
    db.execute(
        "INSERT INTO runs(id,task_id,role,state,target_sha,thread_id,owner_pid,started) "
        "VALUES(?,1,?,?,?,?,1,1)",
        ("old-run", "analyst", run_state, sha, "old-thread"),
    )
    db.execute("INSERT INTO events VALUES(1,?,1,?,?)", ("old-run", "started", "history"))
    db.commit()
    db.close()
    for _ in range(2):
        upgraded = Store(root)
        assert upgraded.db.execute("PRAGMA user_version").fetchone()[0] == 5
        assert upgraded.task(1)["reason"] == "history"
        assert upgraded.runs(1)[0]["thread_id"] == "old-thread"
        assert upgraded.runs(1)[0]["state"] == run_state
        assert upgraded.db.execute("SELECT summary FROM events").fetchone()[0] == "history"
        if run_state == "running":
            with pytest.raises(ValueError):
                upgraded.begin_run(1, Role.ANALYST)
        upgraded.close()


def test_future_schema_is_rejected_without_rewriting(tmp_path):
    db = sqlite3.connect(tmp_path / "gongcao.sqlite3")
    db.execute("PRAGMA user_version=99")
    db.close()
    with pytest.raises(ValueError, match="newer"):
        Store(tmp_path)
    db = sqlite3.connect(tmp_path / "gongcao.sqlite3")
    assert db.execute("PRAGMA user_version").fetchone()[0] == 99
    assert db.execute("SELECT name FROM sqlite_master").fetchall() == []
    db.close()


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


async def test_policy_change_can_publish_new_same_sha_review(
    store, task_id, fixture_github, policy
):
    await Workflow(store, policy, fixture_github).run(task_id)
    sha = store.task(task_id)["target_sha"]
    changed = replace(
        policy,
        model="changed-policy",
    )
    await Workflow(store, changed, fixture_github).run(task_id)
    assert store.task(task_id)["stage"] == Stage.MERGEABLE, store.task(task_id)["reason"]
    assert store.task(task_id)["target_sha"] == sha
    assert len(fixture_github.reviews) == 3


async def test_paginated_cli_json_is_read_without_newer_slurp_flag(monkeypatch):
    calls = []

    async def raw(*args):
        calls.append(args)
        return (
            'HTTP/2.0 200 OK\nLink: <next?after=AbC>; rel="next"\n\n{"items":[{"id":1}]}'
            if args[-1] == "path"
            else '{"items":[{"id":2}]}'
        )

    monkeypatch.setattr("gongcao.github.command", raw)
    assert await GitHub().pages("path", "items") == [{"id": 1}, {"id": 2}]
    assert "--slurp" not in calls[0]
    assert len(calls) == 2
    assert calls[-1][-1] == "next?after=AbC"


async def test_quality_redacts_before_tail_and_stream_boundaries(store, task_id, planned_quality):
    quality = planned_quality(
        ["{python}", "-c", "print('github_pat_'+'PRIVATESEGMENT'*100+' '+'x'*19850)"]
    )
    data = await quality.run(store.task(task_id))
    output = data["items"][0]["stdout"]
    assert output["truncated"] and data["passed"]
    assert "PRIVATESEGMENT" not in output["tail"]


async def test_quality_imports_target_code_and_has_no_model_auth(store, task_id, planned_quality):
    quality = planned_quality(
        [
            "{python}",
            "-c",
            "import importlib.util, os; from pathlib import Path; "
            "assert importlib.util.find_spec('gongcao') is None; "
            "assert 'PYTHONPATH' not in os.environ; "
            "assert (Path.home()/'.codex/auth.json').read_text() == '{}'",
        ]
    )
    data = await quality.run(store.task(task_id))
    assert data["passed"], data["items"]


async def test_cancelled_quality_command_has_terminal_cancel_state(
    store, task_id, fixture_github, policy, monkeypatch
):
    from gongcao.quality import Quality

    started = asyncio.Event()
    original = Quality.run

    async def check(self, task, **kwargs):
        started.set()
        return await original(self, task, **kwargs)

    monkeypatch.setattr(Quality, "run", check)
    future = asyncio.create_task(Workflow(store, policy, fixture_github).run(task_id))
    await asyncio.wait_for(started.wait(), timeout=10)
    store.cancel(task_id)
    await asyncio.wait_for(future, timeout=10)
    assert store.task(task_id)["state"] == State.CANCELLED
    assert not fixture_github.reviews


def test_write_intent_survives_restart_and_rejects_changed_payload(store, task_id):
    task = store.task(task_id)
    assert store.intent(task, "key", "push", "payload")
    reopened = Store(store.root)
    try:
        assert not reopened.intent(task, "key", "push", "payload")
        with pytest.raises(ValueError, match="conflicts"):
            reopened.intent(task, "key", "push", "different")
        reopened.operation_result("key", "unknown", None)
    finally:
        reopened.close()
    assert store.operation("key")["state"] == "unknown"


def test_remote_change_does_not_resume_an_unconfirmed_write(store, task_id, snapshot):
    task = store.task(task_id)
    store.intent(task, "unknown-key", "push", "{}")
    store.operation_result("unknown-key", "unknown", None)
    store.halt(task_id, State.RECONCILE, "Write needs reconciliation")
    store.sync(task_id, snapshot | {"head_sha": "f" * 40})
    assert store.task(task_id)["state"] == State.RECONCILE
    assert store.operation("unknown-key")["state"] == "unknown"


@pytest.mark.parametrize(
    "policy_text",
    [
        'quality: {checks: ["pytest"]}',
        'quality: {ci_workflows: ["../ci.yml"]}',
        "quality: {require_real_checks: yesplease}",
        "max_revisions: -1",
    ],
)
def test_invalid_quality_policy_is_rejected(tmp_path, policy_text):
    path = tmp_path / "config.yaml"
    path.write_text(policy_text)
    with pytest.raises(ValueError):
        Config.load(path)
