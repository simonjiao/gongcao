"""QA regression tests use local OS/git and explicit SDK/GitHub protocol substitutes."""

import asyncio
import copy
import hashlib
import json
import os
import sys

import pytest
from test_pr2 import fixture_github as fixture_github
from test_pr2 import policy as policy

from gongcao.github import GitHub, command
from gongcao.recovery import diagnose
from gongcao.store import Store
from gongcao.workflow import Workflow
from qa.evidence import evaluate, probe, verify_archived, verify_batch, verify_recovery
from qa.ledger import Run, digest, write_json
from qa.resources import Unconfirmed, action, cleanup
from qa.runner import batch, execute, model_activity, verify_implementation


def new_run(tmp_path, scenario="loop"):
    return Run.create(tmp_path, scenario, "a" * 40, repository="example/demo", github_login="qa")


def test_manifest_locks_paths_redaction_and_archive_tamper(tmp_path):
    run = new_run(tmp_path)
    with run.lock(), pytest.raises(ValueError, match="active"):
        with Run(tmp_path, run.id).lock():
            pass
    run.archive("verdict", {"passed": True, "at": 1, "password": "private"})
    assert "private" not in (run.root / "verdict.json").read_text()
    run.check_archives()
    (run.root / "verdict.json").write_text("{}")
    with pytest.raises(ValueError, match="changed"):
        run.check_archives()
    with pytest.raises(ValueError, match="Run ID"):
        Run(tmp_path, "../foreign")
    (tmp_path / "runs" / ("f" * 32)).symlink_to(run.root, target_is_directory=True)
    with pytest.raises(ValueError, match="symlink"):
        Run(tmp_path, "f" * 32)


async def test_unknown_write_is_not_replayed_even_after_restart(tmp_path, monkeypatch):
    run = new_run(tmp_path)
    calls = []

    async def command(*args, **kwargs):
        calls.append(args)
        raise ConnectionError("connection lost after request")

    async def absent():
        return None

    monkeypatch.setattr("qa.resources.command", command)
    with pytest.raises(Unconfirmed):
        await action(run, "create", "POST", "repos/example/demo/issues", {}, absent)
    reloaded = Run(tmp_path, run.id)
    with pytest.raises(Unconfirmed, match="refusing replay"):
        await action(reloaded, "create", "POST", "repos/example/demo/issues", {}, absent)
    assert len(calls) == 1

    async def observed():
        return {"number": 19}

    assert await action(reloaded, "create", "POST", "repos/example/demo/issues", {}, observed) == {
        "number": 19
    }
    assert len(calls) == 1


async def test_confirmed_cleanup_drift_is_not_replayed_or_reported_clean(tmp_path, monkeypatch):
    run = new_run(tmp_path)
    writes = []

    async def command(*args, **kwargs):
        writes.append(args)
        return ""

    async def closed():
        return {"state": "closed"}

    async def reopened():
        return None

    monkeypatch.setattr("qa.resources.command", command)
    await action(
        run, "close-issue", "PATCH", "repos/example/demo/issues/19", {"state": "closed"}, closed
    )
    with pytest.raises(Unconfirmed, match="refusing replay"):
        await action(
            run,
            "close-issue",
            "PATCH",
            "repos/example/demo/issues/19",
            {"state": "closed"},
            reopened,
        )
    assert not writes and run.value["actions"]["close-issue"]["state"] == "unknown"


@pytest.mark.parametrize("foreign", ["issue", "branch", "task", "unknown", "active"])
async def test_cleanup_rejects_foreign_or_unsettled_resources_before_writes(
    tmp_path, monkeypatch, foreign
):
    run = new_run(tmp_path)
    issue = {"url": "https://github.com/example/demo/issues/19", "number": 19}
    branch = "gongcao/work-" + hashlib.sha256(issue["url"].encode()).hexdigest()[:12]
    run.value.update(base_branch="main")
    run.value["resources"] = {"issue": issue, "branch": branch}
    task = {
        "url": issue["url"],
        "repo_path": str(run.root / "source"),
        "snapshot": {"repository": "example/demo"},
        "pr_number": None,
        "runtime": {"lease": None, "processes": []},
        "runs": [],
        "evidence": {"operations": []},
    }
    if foreign == "branch":
        run.value["resources"]["branch"] = "main"
    if foreign == "task":
        task["url"] = "https://github.com/example/demo/issues/20"
    if foreign == "unknown":
        task["evidence"]["operations"] = [{"state": "unknown"}]
    if foreign == "active":
        task["runtime"]["lease"] = {"pid": 999}
    mutations = []

    class Remote(GitHub):
        async def read(self, path):
            return {
                "body": "foreign" if foreign == "issue" else run.marker,
                "user": {"login": "qa"},
            }

    async def command(*args, **kwargs):
        mutations.append(args)
        return ""

    monkeypatch.setattr("qa.resources.command", command)
    with pytest.raises(Unconfirmed):
        await cleanup(run, task, Remote())
    assert not mutations


async def test_cleanup_is_owned_archived_idempotent_and_keeps_other_run(tmp_path, monkeypatch):
    run, other = new_run(tmp_path), new_run(tmp_path)
    other_file = other.root / "keep.txt"
    other_file.write_text("keep")
    issue = {"url": "https://github.com/example/demo/issues/19", "number": 19}
    run.value.update(base_branch="main")
    run.value["resources"] = {
        "issue": issue,
        "branch": "gongcao/work-" + hashlib.sha256(issue["url"].encode()).hexdigest()[:12],
    }
    (run.root / "source").mkdir()
    state = "open"
    mutations = []

    class Remote(GitHub):
        async def read(self, path):
            if "/git/ref/" in path:
                raise RuntimeError("HTTP 404")
            return {"number": 19, "body": run.marker, "user": {"login": "qa"}, "state": state}

        async def pages(self, path, field=None):
            return []

    async def command(*args, **kwargs):
        nonlocal state
        assert (run.root / "cleanup-remote.json").is_file()
        mutations.append(args)
        state = "closed"
        return "{}"

    monkeypatch.setattr("qa.resources.command", command)
    await cleanup(run, None, Remote())
    await cleanup(run, None, Remote())
    assert len(mutations) == 1
    assert not (run.root / "source").exists()
    assert other_file.read_text() == "keep"
    assert run.value["cleaned"]


async def test_verifier_uses_controller_and_ci_evidence_not_agent_ready(
    store,
    task_id,
    fixture_github,
    policy,
):
    await Workflow(store, policy, fixture_github).run(task_id)
    task = store.task(task_id) | {
        "runs": store.runs(task_id),
        "evidence": store.evidence(task_id),
        "runtime": diagnose(store, task_id),
    }
    facts = await fixture_github.gates(task)
    assert evaluate(task, policy, facts)["revision_count"] == 1
    for failure in ("stale", "old", "real", "ci", "pending", "ready", "argv"):
        changed, remote = copy.deepcopy(task), copy.deepcopy(facts)
        if failure == "stale":
            changed["target_sha"] = "0" * 40
        elif failure == "old":
            changed["runs"][2]["evidence_valid"] = 1
        elif failure == "real":
            for artifact in changed["evidence"]["artifacts"]:
                if artifact["kind"] == "real":
                    artifact["valid"] = 0
        elif failure == "ci":
            remote["workflows"][0]["target_proof"]["base_sha"] = "0" * 40
        elif failure == "pending":
            changed["evidence"]["operations"][0]["state"] = "pending"
        elif failure == "argv":
            for artifact in changed["evidence"]["artifacts"]:
                if artifact["kind"] == "checks" and artifact["valid"]:
                    artifact["data"]["commands"][0]["argv"] = ["true"]
        else:
            changed["stage"] = "pending_validation"
        with pytest.raises((ValueError, Unconfirmed)):
            evaluate(changed, policy, remote)


async def test_independent_boundary_probe_uses_actual_read_only_sandbox(tmp_path, repo):
    run = new_run(tmp_path)
    await command("git", "clone", "-q", str(repo), str(run.root / "source"))
    source = run.root / "source"
    module = f"qa_fixture_{run.id[:12]}"
    (source / f"{module}.py").write_text(
        "def clamp_score(value: int) -> int:\n    return min(value, 100)\n"
    )
    await command("git", "add", ".", cwd=str(source))
    await command(
        "git",
        "-c",
        "user.name=QA",
        "-c",
        "user.email=qa@example.invalid",
        "commit",
        "-qm",
        "known fault",
        cwd=str(source),
    )
    sha = (await command("git", "rev-parse", "HEAD", cwd=str(source))).strip()
    assert await probe(run, sha) == [-500, -1, 0, 1, 99, 100, 100, 100]


async def test_batch_queue_failure_isolation_and_durable_evidence(tmp_path, monkeypatch):
    active = set()
    peak = 0
    release = asyncio.Event()
    seen = []

    async def environment(**kwargs):
        return {}

    async def command(*args, **kwargs):
        return "a" * 40 if args[:3] == ("git", "rev-parse", "HEAD") else ""

    async def execute(run, **kwargs):
        nonlocal peak
        assert run.root.is_dir()
        active.add(run.id)
        peak = max(peak, len(active))
        seen.append(run.id)
        if len(seen) == 1:
            await release.wait()
        elif len(seen) == 2:
            release.set()
            await asyncio.sleep(0.01)
        try:
            if run.value["scenario"] == "recover":
                raise ValueError("one deliberately fails")
            run.archive("verdict", {"passed": True, "at": 1})
            run.value["status"] = "passed"
            run.save()
        finally:
            active.remove(run.id)

    monkeypatch.setattr("qa.runner.check", environment)
    monkeypatch.setattr("qa.runner.command", command)
    monkeypatch.setattr("qa.runner.execute", execute)
    report = await batch(
        tmp_path,
        ["smoke", "recover", "smoke"],
        jobs=2,
        real=True,
        repository="example/demo",
        model=None,
        clean=False,
    )
    assert peak == 2 and len(seen) == 3 and not report["passed"]
    assert [r["status"] for r in report["results"]] == ["passed", "interrupted", "passed"]
    events = report["events"]
    third = next(e for e in events if e["kind"] == "started" and e["run_id"] == seen[2])
    assert any(e["kind"] == "released" and e["at"] <= third["at"] for e in events)
    first = Run(tmp_path, seen[0])
    assert verify_archived(first)["passed"]
    with pytest.raises(ValueError):
        verify_batch(tmp_path, report["id"])


def test_partial_sdk_log_never_counts_thread_start_as_inference(tmp_path):
    run = new_run(tmp_path)
    directory = run.root / "state/logs"
    directory.mkdir(parents=True)
    path = directory / "example.jsonl"
    write_json(path, {"kind": "thread", "data": {"thread_id": "not-proof"}})
    # Journal uses one JSON object per line, unlike pretty-printed manifests.
    path.write_text(json.dumps({"kind": "thread", "data": {"thread_id": "not-proof"}}) + "\n{")
    assert not model_activity(run)


async def test_cleanup_partial_clone_before_remote_intent_and_symlink_refusal(tmp_path):
    run = new_run(tmp_path)
    source = run.root / "source"
    source.mkdir()
    (source / "partial.txt").write_text("partial clone")
    await cleanup(run, None, GitHub())
    assert run.value["cleaned"] and not source.exists()
    foreign = tmp_path / "foreign"
    foreign.mkdir()
    (foreign / "keep.txt").write_text("keep")
    source.symlink_to(foreign, target_is_directory=True)
    with pytest.raises(Unconfirmed, match="redirected"):
        await cleanup(run, None, GitHub())
    assert (foreign / "keep.txt").read_text() == "keep"


async def test_fault_kills_only_owned_controller_before_local_ack(tmp_path, repo, sha, snapshot):
    run = new_run(tmp_path, "recover")
    run.value["resources"]["issue"] = {"url": snapshot["url"]}
    run.save()
    store = Store(run.root / "state")
    try:
        task_id = store.register(snapshot["url"], repo, sha, snapshot)
        store.intent(store.task(task_id), "owned-op", "review", "{}")
    finally:
        store.close()

    script = """
from pathlib import Path
from gongcao.store import Store
import qa.fault as fault
import os
store = Store(Path(os.environ['QA_TEST_STATE']))
fault.gongcao_main = lambda: store.operation_result('owned-op', 'succeeded', {'id': 23})
fault.main()
"""
    process = await asyncio.create_subprocess_exec(
        sys.executable,
        "-c",
        script,
        env={
            **os.environ,
            "GONGCAO_QA_DATA": str(tmp_path),
            "GONGCAO_QA_RUN": run.id,
            "QA_TEST_STATE": str(run.root / "state"),
        },
    )
    assert await asyncio.wait_for(process.wait(), 10) == -9
    witness = json.loads((run.root / "fault.json").read_text())
    assert witness["operation"] == "owned-op" and witness["observed_response"] == {"id": 23}
    store = Store(run.root / "state")
    try:
        assert store.operation("owned-op")["state"] == "pending"
    finally:
        store.close()


async def test_cancel_scenario_must_not_pass_a_normal_loop(tmp_path, monkeypatch):
    run = new_run(tmp_path, "cancel")
    task = {"stage": "mergeable", "state": "completed", "evidence": {"operations": []}}

    async def prepare(run, github, model):
        run.value["task_id"] = 1

    async def drive(run, **kwargs):
        return 0

    monkeypatch.setattr("qa.runner.prepare", prepare)
    monkeypatch.setattr("qa.runner.drive", drive)
    monkeypatch.setattr("qa.runner.inspect", lambda run: task)
    await execute(run, model=None, clean=False)
    assert run.value["status"] == "failed"
    assert "never triggered" in run.value["failure"]


async def test_changed_implementation_cannot_start_or_pass(tmp_path, monkeypatch):
    run = new_run(tmp_path)

    async def command(*args, **kwargs):
        return "b" * 40 if args[:3] == ("git", "rev-parse", "HEAD") else ""

    monkeypatch.setattr("qa.runner.command", command)
    with pytest.raises(ValueError, match="Implementation changed"):
        await verify_implementation(run)


def test_recovery_verifier_requires_pending_to_confirmed_exact_comment(tmp_path):
    run = new_run(tmp_path, "recover")
    op = {
        "id": "review-1",
        "kind": "review",
        "state": "pending",
        "sha": "a" * 40,
        "payload": {"body": "owned marker", "commit_id": "a" * 40},
        "response": None,
    }
    before = {"evidence": {"operations": [op]}}
    witness = {
        "point": "COMMENT observed before local operation_result",
        "operation": "review-1",
        "target_sha": "a" * 40,
        "observed_response": {"id": 31},
    }
    confirmed = op | {"state": "succeeded", "response": {"id": 31}}
    final = {"evidence": {"operations": [confirmed]}}
    reviews = [{"id": 31, "body": "owned marker", "commit_id": "a" * 40, "state": "COMMENTED"}]
    with pytest.raises(FileNotFoundError):
        verify_recovery(run, final, reviews)
    run.archive("interrupted", {"task": before, "witness": witness})
    run.archive("recovered", final)
    verify_recovery(run, final, reviews)
    with pytest.raises(ValueError, match="duplicated"):
        verify_recovery(run, final, reviews * 2)


def test_cancel_archive_requires_real_command_evidence(tmp_path):
    run = new_run(tmp_path, "cancel")
    url = "https://github.com/example/demo/issues/19"
    run.value.update(status="passed", config_digest=digest({}))
    run.value["resources"]["issue"] = {"url": url}
    run.archive("configuration", {})
    run.archive(
        "task",
        {
            "url": url,
            "state": "cancelled",
            "runs": [],
            "runtime": {"lease": None, "processes": []},
            "evidence": {"operations": []},
        },
    )
    run.archive("verdict", {"passed": True, "at": 1})
    with pytest.raises(FileNotFoundError):
        verify_archived(run)
    run.archive("cancellation", {"commands": []})
    with pytest.raises(ValueError, match="real SDK command"):
        verify_archived(run)


@pytest.mark.parametrize("foreign_origin", [True, False])
async def test_branch_cleanup_validates_origin_and_ignores_foreign_pushurl(
    tmp_path, repo, sha, monkeypatch, foreign_origin
):
    run = new_run(tmp_path)
    source = run.root / "source"
    await command("git", "clone", "-q", str(repo), str(source))
    await command(
        "git",
        "remote",
        "set-url",
        "origin",
        "https://github.com/foreign/demo.git"
        if foreign_origin
        else "https://github.com/example/demo.git",
        cwd=str(source),
    )
    await command(
        "git",
        "remote",
        "set-url",
        "--push",
        "origin",
        "https://github.com/foreign/demo.git",
        cwd=str(source),
    )
    issue = {"url": "https://github.com/example/demo/issues/19", "number": 19}
    branch = "gongcao/work-" + hashlib.sha256(issue["url"].encode()).hexdigest()[:12]
    run.value.update(base_branch="main")
    run.value["resources"] = {"issue": issue, "branch": branch}
    task = {
        "url": issue["url"],
        "repo_path": str(source),
        "snapshot": {"repository": "example/demo"},
        "pr_number": None,
        "runtime": {"lease": None, "processes": []},
        "runs": [],
        "evidence": {
            "operations": [
                {"kind": "push", "state": "succeeded", "payload": {"branch": branch, "sha": sha}}
            ]
        },
    }
    ref_exists, state = True, "open"
    writes = []

    class Remote(GitHub):
        async def read(self, path):
            if "/git/ref/" in path:
                if not ref_exists:
                    raise RuntimeError("HTTP 404")
                return {"object": {"sha": sha}}
            return {"number": 19, "body": run.marker, "user": {"login": "qa"}, "state": state}

        async def pages(self, path, field=None):
            return []

    async def mutate(*args, **kwargs):
        nonlocal ref_exists, state
        writes.append(args)
        if args[:2] == ("git", "push"):
            assert "git@github.com:example/demo.git" in args
            assert f"--force-with-lease=refs/heads/{branch}:{sha}" in args
            ref_exists = False
        else:
            state = "closed"
        return ""

    monkeypatch.setattr("qa.resources.command", mutate)
    if foreign_origin:
        with pytest.raises(ValueError, match="origin"):
            await cleanup(run, task, Remote())
        assert not writes
    else:
        await cleanup(run, task, Remote())
        assert run.value["cleaned"] and not ref_exists and len(writes) == 2
