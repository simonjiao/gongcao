"""Plans and evidence use real execution; remote transport is an explicit offline fixture."""

import copy
import json

import pytest
from test_pr2 import fixture_github as fixture_github
from test_pr2 import policy as policy

from gongcao.archive import publish
from gongcao.config import Config
from gongcao.github import command
from gongcao.leases import Lease
from gongcao.model import Role, State
from gongcao.plan import propose
from gongcao.quality import Quality, verdict
from gongcao.remote import Controlled, UncertainWrite
from gongcao.workflow import Workflow
from gongcao.workspace import context


def items(entry, environment="sandbox"):
    return [
        {
            "category": category,
            "entry": entry if category == "e2e" else ["true"],
            "scope": ["."],
            "required": True,
            "reason": "Acceptance contract",
            "environment": environment if category == "e2e" else "sandbox",
        }
        for category in ("build", "internal", "e2e")
    ]


@pytest.mark.parametrize(
    "changed,expected", [("backend/src/X.java", "mvn"), ("frontend/src/X.ts", "npm")]
)
def test_repository_and_diff_choose_entries(changed, expected):
    data = {
        "repository_files": ["backend/pom.xml", "frontend/package.json"],
        "build_files": {
            "backend/pom.xml": "<project/>",
            "frontend/package.json": json.dumps(
                {
                    "scripts": {
                        "build": "vite build",
                        "test": "vitest",
                        "test:e2e": "playwright test",
                    }
                }
            ),
        },
        "diff": {"patch": f"diff --git a/{changed} b/{changed}"},
    }
    plan = propose(data)
    assert {i["entry"][0] for i in plan if i["entry"]} == {expected}
    assert {i["category"] for i in plan} == {"build", "internal", "e2e"}
    assert all(i["environment"] == "controlled" for i in plan if i["category"] == "e2e")


async def test_plan_context_and_analysis_suggestions_are_not_results(store, task_id, repo):
    task = store.task(task_id)
    data, _ = await context(repo, task, Role.ANALYST, Config(), None)
    assert "Makefile" in data["build_files"] and data["repository_instructions"]
    quality = Quality(store, Config())
    plan = await quality.plan(task)
    assert plan["base_sha"] == plan["target_sha"] == task["target_sha"]
    assert store.artifact(task_id, "quality-results", plan["plan_hash"]) is None
    result = await quality.run(task)
    assert verdict(result, include_e2e=False) == "passed" and verdict(result) == "blocked"


async def test_same_sha_plan_change_invalidates_review_and_results(
    store, task_id, fixture_github, policy
):
    await Workflow(store, policy, fixture_github).run(task_id)
    task = store.task(task_id)
    quality = Quality(store, policy)
    previous = await quality.plan(task)
    changed = copy.deepcopy(previous["items"])
    changed[0]["reason"] = "Additional requirement confirmed at the same SHA"
    plan = quality.confirm(task, changed)
    assert (
        plan["target_sha"] == previous["target_sha"] and plan["plan_hash"] != previous["plan_hash"]
    )
    assert not [
        r
        for r in store.runs(task_id)
        if r["role"] in {"reviewer", "validator"} and r["evidence_valid"]
    ]
    assert store.artifact(task_id, "quality-results", previous["plan_hash"]) is None
    await Workflow(store, policy, fixture_github).run(task_id)
    assert store.task(task_id)["state"] == State.COMPLETED
    assert len(fixture_github.reviews) == 3


@pytest.mark.parametrize(
    "entry,status",
    [(["sh", "-c", "exit 1"], "failed"), (["missing-executable-79"], "blocked"), ([], "blocked")],
)
async def test_failure_and_missing_environment_are_distinct(store, task_id, entry, status):
    quality = Quality(store, Config())
    quality.confirm(store.task(task_id), items(entry))
    result = await quality.run(store.task(task_id), include_e2e=True)
    assert verdict(result) == status
    assert result["items"][-1]["status"] == status


async def test_real_qa_requires_exact_plan_and_preserves_multiple_results(store, task_id, repo):
    (repo / "qa").mkdir()
    (repo / "qa/probe.py").write_text("print('real controlled entry executed')\n")
    await command("git", "add", ".", cwd=str(repo))
    await command("git", "commit", "-qm", "QA entry", cwd=str(repo))
    sha = (await command("git", "rev-parse", "HEAD", cwd=str(repo))).strip()
    store.sync(task_id, store.task(task_id)["snapshot"] | {"head_sha": sha})
    quality = Quality(store, Config())
    checks = items(["{python}", "qa/probe.py"], "controlled")
    checks.append(checks[-1] | {"reason": "Second environment probe"})
    plan = quality.confirm(store.task(task_id), checks)
    blocked = await quality.run(store.task(task_id), include_e2e=True)
    assert verdict(blocked) == "blocked"
    with pytest.raises(ValueError, match="authorization"):
        await quality.run(
            store.task(task_id), include_e2e=True, real_check=2, approved_plan="stale"
        )
    for index in (2, 3):
        result = await quality.run(
            store.task(task_id), include_e2e=True, real_check=index, approved_plan=plan["plan_hash"]
        )
    assert verdict(result) == "passed"
    assert all("real controlled entry" in row["stdout"]["tail"] for row in result["items"][2:])


async def test_plan_cannot_change_under_another_lease(store, task_id):
    from contextlib import closing

    from gongcao.store import Store

    async with Lease(store, task_id):
        with closing(Store(store.root)) as other:
            with pytest.raises(ValueError, match="lease"):
                Quality(other, Config()).confirm(other.task(task_id), items(["true"]))


async def test_archive_append_redaction_readback_and_unknown_write(
    store, task_id, fixture_github, policy, monkeypatch
):
    import gongcao.archive as archive

    await Workflow(store, policy, fixture_github).run(task_id)
    task = store.task(task_id)
    quality = Quality(store, policy)
    result = await quality.run(task, include_e2e=True)
    original = command
    uncertain = False

    async def local(*args, **kwargs):
        if (
            args[:2] in {("git", "push"), ("git", "ls-remote"), ("git", "fetch")}
            and args[2] == "origin"
        ):
            args = (*args[:2], str(fixture_github.bare), *args[3:])
        value = await original(*args, **kwargs)
        if uncertain and args[:2] == ("git", "push"):
            raise RuntimeError("Response lost after successful push")
        return value

    monkeypatch.setattr(archive, "command", local)
    comments = {}

    async def pages(endpoint, field=None):
        return comments.get(endpoint.split("?")[0], [])

    async def mutate(endpoint, payload):
        row = payload | {"id": sum(map(len, comments.values())) + 1}
        comments.setdefault(endpoint, []).append(row)
        return row

    monkeypatch.setattr(fixture_github, "pages", pages)
    monkeypatch.setattr(fixture_github, "mutate", mutate)
    result["items"][0]["stdout"]["tail"] = "github_pat_" + "PRIVATE" * 12
    remote = Controlled(store, policy, fixture_github)
    first = await publish(remote, task, result)
    result = copy.deepcopy(result)
    result["run_id"] += "-failed"
    result["items"][-1]["status"] = "failed"
    result["items"][-1]["exit_code"] = 1
    uncertain = True
    second = await publish(remote, task, result)
    assert first["sha"] != second["sha"] and first["sha"] in first["url"]
    await original(
        "git", "merge-base", "--is-ancestor", first["sha"], second["sha"], cwd=task["repo_path"]
    )
    content = await original(
        "git", "show", f"{first['sha']}:{first['path']}/manifest.json", cwd=task["repo_path"]
    )
    assert "PRIVATE" not in content and "directory" not in content
    assert len(comments) == 2 and all(len(rows) == 2 for rows in comments.values())
    assert (await publish(remote, task, result)) == second
    assert all(len(rows) == 2 for rows in comments.values())
    payload = store.artifact(task_id, "archive-prepared", result["run_id"])
    bad = payload | {"hashes": {"manifest.json": "0" * 64}}
    with pytest.raises(UncertainWrite, match="hash mismatch"):
        await archive.observe(task, bad, fixture_github)
