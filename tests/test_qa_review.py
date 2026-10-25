"""Review regressions: cancellation boundaries and remote cleanup races, offline only."""

import asyncio
import hashlib
import json
import sys

import pytest
from test_qa import new_run

from gongcao.github import GitHub, command
from gongcao.store import Store
from qa.__main__ import execute as cli_execute
from qa.__main__ import parser
from qa.ledger import Run, RunCancelled
from qa.resources import Unconfirmed, cleanup
from qa.runner import batch, core, execute


@pytest.mark.parametrize("scene", ["loop", "smoke"])
async def test_cancel_third_queued_run_never_prepares_or_starts_sdk(tmp_path, monkeypatch, scene):
    first_two = asyncio.Event()
    release = asyncio.Event()
    prepared = []
    checks = []

    async def check(**kwargs):
        checks.append(kwargs)
        return {}

    async def git(*args, **kwargs):
        return "a" * 40 if args[:3] == ("git", "rev-parse", "HEAD") else ""

    async def prepare(run, github, model):
        prepared.append(run.id)
        if len(prepared) == 2:
            first_two.set()
        await release.wait()
        raise ValueError("Protocol fixture stops before creating resources")

    async def unexpected(*args, **kwargs):
        raise AssertionError("Cancelled queued Run must not create an issue or start SDK work")

    monkeypatch.setattr("qa.runner.check", check)
    monkeypatch.setattr("qa.runner.command", git)
    monkeypatch.setattr("qa.runner.prepare", prepare)
    monkeypatch.setattr("qa.runner.core", unexpected)
    monkeypatch.setattr("qa.resources.create_issue", unexpected)
    pending = asyncio.create_task(
        batch(
            tmp_path,
            ["loop", "loop", scene],
            jobs=2,
            real=True,
            repository="example/demo",
            model=None,
            clean=True,
        )
    )
    try:
        await asyncio.wait_for(first_two.wait(), 5)
        queued = next(
            Run(tmp_path, p.parent.name)
            for p in (tmp_path / "runs").glob("*/manifest.json")
            if json.loads(p.read_text())["status"] == "queued"
        )
        result = await cli_execute(
            parser().parse_args(["--data-dir", str(tmp_path), "cancel", queued.id])
        )
        assert result["cancel_requested"] and result["status"] == "queued"
        assert len(prepared) == 2
    finally:
        release.set()
    report = await asyncio.wait_for(pending, 5)
    cancelled = Run(tmp_path, queued.id)
    assert cancelled.value["status"] == "cancelled" and cancelled.value["cleaned"]
    assert not cancelled.value["resources"] and not cancelled.value.get("task_id")
    assert not (cancelled.root / "state").exists() and not list(cancelled.root.glob("command-*"))
    assert len(prepared) == 2 and len(checks) == 1 and not report["passed"]


@pytest.mark.parametrize(
    "status", ["passed", "failed", "cancelled", "interrupted", "needs_reconciliation"]
)
async def test_cancel_finished_run_does_not_report_accepted(tmp_path, status):
    stale = new_run(tmp_path)
    finished = Run(tmp_path, stale.id)
    finished.value["status"] = status
    finished.save()
    args = parser().parse_args(["--data-dir", str(tmp_path), "cancel", stale.id])
    result = await cli_execute(args)
    assert result == {"run_id": stale.id, "cancel_requested": False, "status": status}
    assert not stale.request_cancel()["cancel_requested"]
    assert not (stale.root / "cancel-requested").exists()


@pytest.mark.parametrize("point", ["after_clone", "before_issue_write", "after_issue"])
async def test_preparation_cancel_stops_new_work_and_cleans_owned_resources(
    tmp_path, monkeypatch, point
):
    run = new_run(tmp_path)
    issue = None
    writes = []
    core_calls = []

    class Remote(GitHub):
        async def read(self, path):
            if path == "repos/example/demo":
                return {"default_branch": "main", "ssh_url": "git@github.com:example/demo.git"}
            if path.endswith("/git/ref/heads/main"):
                return {"object": {"sha": "a" * 40}}
            if "/git/ref/" in path:
                raise RuntimeError("HTTP 404")
            assert issue is not None
            if point == "after_issue" and issue["state"] == "open":
                run.request_cancel()
            return dict(issue)

        async def pages(self, path, field=None):
            if "/issues?" in path and point == "before_issue_write":
                run.request_cancel()
            return []

    async def clone(*args, **kwargs):
        if args[:2] == ("git", "clone"):
            for name in (
                "pyproject.toml",
                "uv.lock",
                ".github/workflows/ci.yml",
                "src/gongcao/cli.py",
            ):
                path = run.root / "source" / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()
            if point == "after_clone":
                run.request_cancel()
        return ""

    async def mutate(*args, **kwargs):
        nonlocal issue
        writes.append(args[3])
        if args[3] == "POST":
            issue = json.loads(kwargs["input_data"]) | {
                "number": 41,
                "state": "open",
                "html_url": "https://github.com/example/demo/issues/41",
                "user": {"login": "qa"},
            }
            return json.dumps({"number": 41})
        assert args[3] == "PATCH" and issue is not None
        issue["state"] = "closed"
        return "{}"

    async def native(*args, **kwargs):
        core_calls.append(args)
        raise AssertionError("Preparation cancellation must prevent registration/model launch")

    monkeypatch.setattr("qa.runner.GitHub", Remote)
    monkeypatch.setattr("qa.runner.command", clone)
    monkeypatch.setattr("qa.runner.core", native)
    monkeypatch.setattr("qa.resources.command", mutate)
    await execute(run, model=None, clean=True)
    assert run.value["status"] == "cancelled" and run.value["cleaned"]
    assert not core_calls and not (run.root / "source").exists()
    assert writes == (["POST", "PATCH"] if point == "after_issue" else [])
    if issue:
        assert issue["state"] == "closed"


async def test_user_cancel_reaches_native_execution_during_preparation(
    tmp_path, repo, sha, snapshot, monkeypatch
):
    run = new_run(tmp_path)
    store = Store(run.root / "state")
    try:
        run.value["task_id"] = store.register(snapshot["url"], repo, sha, snapshot)
    finally:
        store.close()
    entered = run.root / "native-entered"
    original = asyncio.create_subprocess_exec
    commands = []
    script = """
import sys,time
from pathlib import Path
from gongcao.store import Store
store=Store(Path(sys.argv[1]))
Path(sys.argv[2]).touch()
while not store.task(1)['cancel_requested']:
    time.sleep(0.02)
store.close()
print('cancelled')
"""

    async def launch(*args, **kwargs):
        operation = args[5]
        commands.append(operation)
        if operation == "run":
            # Substitute long native execution; cancel uses the real CLI and public Store.
            return await original(
                sys.executable, "-c", script, str(run.root / "state"), str(entered), **kwargs
            )
        return await original(*args, **kwargs)

    async def fixed(run):
        pass

    monkeypatch.setattr("qa.runner.verify_implementation", fixed)
    monkeypatch.setattr("qa.runner.asyncio.create_subprocess_exec", launch)
    pending = asyncio.create_task(core(run, "run", "1", "--config", "missing-gate.yaml"))
    try:
        async with asyncio.timeout(5):
            while not entered.exists():
                await asyncio.wait({pending}, timeout=0.02)
        assert run.request_cancel()["cancel_requested"]
        assert await asyncio.wait_for(pending, 5) == 0
    finally:
        if not pending.done():
            pending.cancel()
        await asyncio.gather(pending, return_exceptions=True)
    assert commands == ["run", "cancel"]
    store = Store(run.root / "state")
    try:
        assert store.task(1)["state"] == "cancelled"
    finally:
        store.close()


async def test_cancellation_during_implementation_check_prevents_native_spawn(
    tmp_path, monkeypatch
):
    run = new_run(tmp_path)

    async def verify(run):
        run.request_cancel()

    async def forbidden(*args, **kwargs):
        raise AssertionError("Known cancellation must prevent native process creation")

    monkeypatch.setattr("qa.runner.verify_implementation", verify)
    monkeypatch.setattr("qa.runner.asyncio.create_subprocess_exec", forbidden)
    with pytest.raises(RunCancelled):
        await core(run, "run", "1")


@pytest.mark.parametrize(
    "race",
    [
        "merge_on_confirmation",
        "merge_at_finish",
        "base_at_start",
        "base_at_finish",
        "merged_pr_missing_from_listing",
        "registered_pr_404",
        "published_pr_not_associated",
    ],
)
async def test_cleanup_rechecks_unmerged_pr_and_fixed_base_before_reporting_cleaned(
    tmp_path, repo, sha, monkeypatch, race
):
    run = new_run(tmp_path)
    source = run.root / "source"
    await command("git", "clone", "-q", str(repo), str(source))
    await command(
        "git", "remote", "set-url", "origin", "https://github.com/example/demo.git", cwd=str(source)
    )
    issue_url = "https://github.com/example/demo/issues/19"
    branch = "gongcao/work-" + hashlib.sha256(issue_url.encode()).hexdigest()[:12]
    run.value["resources"] = {"issue": {"number": 19, "url": issue_url}, "branch": branch}
    task = {
        "url": issue_url,
        "repo_path": str(source),
        "snapshot": {"repository": "example/demo"},
        "pr_number": 23,
        "runtime": {"lease": None, "processes": []},
        "runs": [],
        "evidence": {
            "operations": [
                {"kind": "push", "state": "succeeded", "payload": {"branch": branch, "sha": sha}}
            ]
        },
    }
    if race == "published_pr_not_associated":
        task["pr_number"] = None
        task["evidence"]["operations"].append(
            {"kind": "pull", "state": "succeeded", "response": {"number": 23}}
        )
    pull = {
        "number": 23,
        "state": "open",
        "merged": False,
        "merged_at": None,
        "body": f"Implements {issue_url}",
        "user": {"login": "qa"},
        "head": {"repo": {"full_name": "example/demo"}, "ref": branch},
    }
    branch_exists = True
    issue_state = "open"
    base_sha = "b" * 40 if race == "base_at_start" else run.value["base_sha"]
    writes = []

    class Remote(GitHub):
        async def read(self, path):
            if path == "repos/example/demo":
                return {"default_branch": "main"}
            if path.endswith("/git/ref/heads/main"):
                return {"object": {"sha": base_sha}}
            if "/git/ref/" in path:
                if not branch_exists:
                    raise RuntimeError("HTTP 404")
                return {"object": {"sha": sha}}
            if "/pulls/" in path:
                if race == "registered_pr_404":
                    raise RuntimeError("HTTP 404")
                if race == "merged_pr_missing_from_listing":
                    return pull | {
                        "state": "closed",
                        "merged": True,
                        "merged_at": "2026-10-25T00:00:00Z",
                    }
                return dict(pull)
            return {"number": 19, "body": run.marker, "state": issue_state, "user": {"login": "qa"}}

        async def pages(self, path, field=None):
            if race in {
                "merged_pr_missing_from_listing",
                "registered_pr_404",
                "published_pr_not_associated",
            }:
                return []
            return [dict(pull)]

    async def mutate(*args, **kwargs):
        nonlocal branch_exists, issue_state, base_sha
        writes.append(args)
        if args[:2] == ("git", "push"):
            branch_exists = False
            if race == "merge_at_finish":
                pull.update(merged=True, merged_at="2026-10-25T00:00:00Z")
            if race == "base_at_finish":
                base_sha = "b" * 40
        elif "/pulls/" in args[4]:
            pull["state"] = "closed"
            if race == "merge_on_confirmation":
                pull.update(merged=True, merged_at="2026-10-25T00:00:00Z")
        else:
            issue_state = "closed"
        return "{}"

    monkeypatch.setattr("qa.resources.command", mutate)
    with pytest.raises(Unconfirmed):
        await cleanup(run, task, Remote())
    assert not run.value["cleaned"] and run.value["status"] == "needs_reconciliation"
    assert source.exists() and not (run.root / "cleanup-confirmed.json").exists()
    if race == "merge_on_confirmation":
        assert branch_exists and len(writes) == 1
        assert run.value["actions"]["close-pull"]["state"] == "unknown"
    elif race in {
        "base_at_start",
        "merged_pr_missing_from_listing",
        "registered_pr_404",
        "published_pr_not_associated",
    }:
        assert not writes and branch_exists
