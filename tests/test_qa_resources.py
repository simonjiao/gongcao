import hashlib
import json

import pytest
from _support.qa import base_response, new_run

from gongcao.github import GitHub, command
from qa.ledger import Run
from qa.resources import Unconfirmed, action, cleanup, create_issue


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


async def test_issue_confirmation_uses_verified_response_hint_when_list_lags(tmp_path, monkeypatch):
    run = new_run(tmp_path)
    posted = []
    reads = []

    class Remote(GitHub):
        async def pages(self, path, field=None):
            return []  # Cached/stale issue listing even after a successful POST.

        async def read(self, path):
            reads.append(path)
            if len(reads) == 1:
                raise RuntimeError("HTTP 404")
            return {
                **posted[0],
                "number": 41,
                "html_url": "https://github.com/example/demo/issues/41",
                "user": {"login": "qa"},
            }

    async def mutate(*args, **kwargs):
        posted.append(json.loads(kwargs["input_data"]))
        return json.dumps({"number": 41})

    monkeypatch.setattr("qa.resources.command", mutate)
    issue = await create_issue(run, "versioned requirement", Remote())
    assert issue["number"] == 41 and len(posted) == 1 and len(reads) == 2
    assert run.value["actions"]["create-issue"]["state"] == "confirmed"


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
            if row := base_response(run, path):
                return row
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
            if row := base_response(run, path):
                return row
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
    checkpoint = branch.replace("gongcao/work-", "gongcao/save-") + "-" + "a" * 32
    saved = {"run_id": "a" * 32, "branch": checkpoint, "sha": sha}
    task["runs"] = [
        {
            "id": saved["run_id"],
            "role": "developer",
            "state": "completed",
            "details": {"save": saved | {"state": "confirmed"}},
        }
    ]
    task["evidence"]["operations"].append(
        {"kind": "checkpoint", "state": "succeeded", "payload": saved}
    )
    refs, state = {branch: sha, checkpoint: sha}, "open"
    writes = []

    class Remote(GitHub):
        async def read(self, path):
            if row := base_response(run, path):
                return row
            if "/git/ref/" in path:
                name = path.split("/git/ref/heads/")[1]
                if name not in refs:
                    raise RuntimeError("HTTP 404")
                return {"object": {"sha": refs[name]}}
            return {"number": 19, "body": run.marker, "user": {"login": "qa"}, "state": state}

        async def pages(self, path, field=None):
            return []

    async def mutate(*args, **kwargs):
        nonlocal state
        writes.append(args)
        if args[:2] == ("git", "push"):
            assert "git@github.com:example/demo.git" in args
            name = args[-1].removeprefix(":refs/heads/")
            assert f"--force-with-lease=refs/heads/{name}:{sha}" in args
            del refs[name]
        else:
            state = "closed"
        return ""

    monkeypatch.setattr("qa.resources.command", mutate)
    if foreign_origin:
        with pytest.raises(ValueError, match="origin"):
            await cleanup(run, task, Remote())
        assert not writes
    else:
        refs[checkpoint] = "f" * 40
        with pytest.raises(Unconfirmed, match="foreign commit"):
            await cleanup(run, task, Remote())
        assert not writes and source.exists()
        refs[checkpoint] = sha
        await cleanup(run, task, Remote())
        assert run.value["cleaned"] and not refs and len(writes) == 3
        await cleanup(run, task, Remote())
        assert len(writes) == 3  # Already-removed checkpoint never replays deletion.


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
