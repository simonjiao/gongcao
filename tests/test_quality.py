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
from gongcao.model import Role, Stage, State
from gongcao.plan import propose
from gongcao.quality import Quality, verdict
from gongcao.remote import Controlled, UncertainWrite
from gongcao.workflow import Workflow
from gongcao.workspace import context


async def authorized_fixture() -> None:
    # Explicit execution is restricted to temporary, test-owned QA scripts.
    pass


def items(entry, environment="sandbox"):
    return [
        {
            "category": category,
            "entry": entry
            if category == ("e2e" if environment == "controlled" else "internal")
            else ["true"]
            if category != "e2e"
            else [],
            "scope": ["."],
            "required": category != "e2e" or environment == "controlled",
            "reason": "Execution probe; no real E2E claimed"
            if environment == "sandbox"
            else "Acceptance contract",
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
    assert any(not i["entry"] and "assessment" in i["reason"] for i in plan["items"])
    quality.confirm(task, propose(data))
    result = await quality.run(task)
    assert verdict(result, include_e2e=False) == "passed" and verdict(result) == "blocked"


async def test_same_sha_plan_change_invalidates_review_and_results(
    store, task_id, fixture_github, policy
):
    await Workflow(store, policy, fixture_github).run(task_id)
    task = store.task(task_id)
    quality = Quality(store, policy)
    previous = await quality.plan(task)
    store.db.execute(
        "INSERT INTO claims(url,data,task_id,dirty) VALUES(?,?,?,0)",
        (task["url"], json.dumps({"marker": "status-probe"}), task_id),
    )
    store.db.commit()
    changed = copy.deepcopy(previous["items"])
    changed[0]["reason"] = "Additional requirement confirmed at the same SHA"
    plan = quality.confirm(task, changed)
    assert store.task(task_id)["stage"] == Stage.REVIEW
    assert store.task(task_id)["state"] == State.QUEUED
    from gongcao.discovery import Discovery

    claim = Discovery(store, policy, fixture_github).records()[0]
    assert claim["dirty"] == 1
    assert "Await human merge" not in Discovery(store, policy, fixture_github).render(claim)
    assert (
        plan["target_sha"] == previous["target_sha"] and plan["plan_hash"] != previous["plan_hash"]
    )
    assert not [
        r
        for r in store.runs(task_id)
        if r["role"] in {"reviewer", "validator"} and r["evidence_valid"]
    ]
    assert store.artifact(task_id, "quality-results", previous["plan_hash"]) is None
    store.db.execute("DELETE FROM claims WHERE task_id=?", (task_id,))
    store.db.commit()
    await Workflow(store, policy, fixture_github).run(task_id)
    assert store.task(task_id)["state"] == State.COMPLETED
    assert len(fixture_github.reviews) == 3
    store.transition(store.task(task_id), Stage.MERGED, State.COMPLETED, "Merged externally")
    with pytest.raises(ValueError, match="Merged tasks are terminal"):
        quality.confirm(store.task(task_id), previous["items"])


def test_offline_cli_regressions_do_not_supply_real_e2e():
    plan = propose(
        {
            "repository_files": ["pyproject.toml", "tests/test_control_cli.py"],
            "build_files": {"pyproject.toml": "pytest ruff mypy"},
        }
    )
    e2e = [i for i in plan if i["category"] == "e2e"]
    assert len(e2e) == 1 and not e2e[0]["entry"] and e2e[0]["required"]


async def test_analyst_cannot_relabel_offline_tests_as_real_e2e(store, task_id):
    checks = items(["true"])
    checks[-1].update(required=True, entry=["pytest", "tests/test_control_cli.py"])
    with pytest.raises(ValueError, match="real E2E.*controlled"):
        Quality(store, Config()).confirm(store.task(task_id), checks)


async def test_new_head_cannot_drop_unconfirmed_issue_acceptance(store, task_id, repo):
    quality = Quality(store, Config())
    task = store.task(task_id)
    store.sync(task_id, task["snapshot"] | {"body": "Require actual browser and engine acceptance"})
    task = store.task(task_id)
    checks = items([], "controlled")
    checks[-1]["reason"] = "Actual browser and engine entry is unavailable"
    quality.confirm(task, checks)
    (repo / "sample.txt").write_text("complete\n")
    await command("git", "add", "sample.txt", cwd=str(repo))
    await command("git", "commit", "-qm", "new PR head", cwd=str(repo))
    sha = (await command("git", "rev-parse", "HEAD", cwd=str(repo))).strip()
    store.sync(task_id, task["snapshot"] | {"head_sha": sha})
    task = store.task(task_id)
    plan = await quality.plan(task)
    assert any(not i["entry"] and "assessment" in i["reason"] for i in plan["items"])
    result = await quality.run(task, include_e2e=True)
    assert verdict(result) == "blocked"
    data, _ = await context(repo, store.task(task_id), Role.ANALYST, Config(), None)
    assert "actual browser" in data["github"]["body"] and data["target_sha"] == sha
    assert data["repository_instructions"] == (repo / "AGENTS.md").read_text()


@pytest.mark.parametrize("role", [Role.REVIEWER, Role.VALIDATOR])
async def test_not_applicable_plan_still_needs_independent_acceptance(
    store, task_id, repo, fixture_github, policy, monkeypatch, role
):
    from test_runner import install_worker

    requirement = "Require real browser and engine acceptance; missing evidence blocks readiness."
    (repo / "AGENTS.md").write_text(requirement)
    (repo / "Makefile").unlink()
    await command("git", "add", ".", cwd=str(repo))
    await command("git", "commit", "-qm", "Explicit integration acceptance", cwd=str(repo))
    sha = (await command("git", "rev-parse", "HEAD", cwd=str(repo))).strip()
    fixture_github.issue.update(body=requirement, head_sha=sha)
    fixture_github.sha = sha
    store.sync(task_id, fixture_github.issue)
    proposal = items([])
    for item in proposal:
        item.update(required=False, entry=[], reason="Mistaken analyst: all checks inapplicable")
    run = store.begin_run(task_id, Role.ANALYST)
    store.finish(
        run,
        State.COMPLETED,
        Stage.REVIEW,
        State.QUEUED,
        "Injected incorrect assessment",
        json.dumps({"target_sha": sha, "conclusion": "ready", "validation_plan": proposal}),
    )
    quality = Quality(store, policy)
    evidence = await quality.run(store.task(task_id), include_e2e=True)
    assert verdict(evidence) == "passed"  # Only the declared plan, not acceptance/readiness.
    assert not any(item["required"] for item in evidence["items"])
    store.transition(store.task(task_id), Stage.REVIEW, State.QUEUED, "Plan execution complete")
    if role == Role.VALIDATOR:
        run = store.begin_run(task_id, Role.REVIEWER)
        store.finish(
            run,
            State.COMPLETED,
            Stage.VALIDATION,
            State.QUEUED,
            "Injected review approval",
            json.dumps({"target_sha": sha, "conclusion": "ready"}),
        )
    # This is a protocol regression. Real-model judgement is checked separately.
    install_worker(
        monkeypatch,
        """
import json
data = json.loads(input())['context']
assert 'real browser and engine' in data['github']['body']
assert 'real browser and engine' in data['repository_instructions']
assert data['quality_evidence']['passed']
assert not any(i['required'] for i in data['quality_evidence']['items'])
print(json.dumps({'kind':'thread','data':{'thread_id':'independent-acceptance-review'}}))
print(json.dumps({'kind':'result','data':{
    'conclusion':'blocked','summary':'Required real browser/engine evidence is absent',
    'basis':['Issue and AGENTS contradict the not-applicable assessment'],
    'target_sha':data['target_sha'],'next_steps':['Supply required real acceptance'],
    'validation_plan':[]}}))
""",
    )
    await Workflow(store, policy, fixture_github).step(store.task(task_id))
    task = store.task(task_id)
    assert task["state"] == State.HUMAN
    assert task["stage"] == (Stage.REVIEW if role == Role.REVIEWER else Stage.VALIDATION)
    assert not fixture_github.writes
    assert store.artifact(task_id, "validation", policy.policy_hash) is None
    assert store.runs(task_id)[-1]["role"] == role


@pytest.mark.parametrize(
    "entry,status",
    [(["sh", "-c", "exit 1"], "failed"), (["missing-executable-79"], "blocked"), ([], "blocked")],
)
async def test_failure_and_missing_environment_are_distinct(store, task_id, entry, status, caplog):
    caplog.set_level("INFO", logger="gongcao")
    quality = Quality(store, Config())
    quality.confirm(store.task(task_id), items(entry))
    result = await quality.run(store.task(task_id), include_e2e=True)
    assert verdict(result) == status
    assert result["items"][1]["status"] == status
    assert ("失败 1" if status == "failed" else "未执行/缺环境 1") in caplog.text


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

    async def paused():
        from gongcao.control import Paused

        raise Paused("Controller pause before host QA")

    from gongcao.control import Paused

    with pytest.raises(Paused):
        await quality.run(
            store.task(task_id),
            include_e2e=True,
            real_check=2,
            approved_plan=plan["plan_hash"],
            before_real=paused,
        )
    for index in (2, 3):
        result = await quality.run(
            store.task(task_id),
            include_e2e=True,
            real_check=index,
            approved_plan=plan["plan_hash"],
            before_real=authorized_fixture,
        )
    assert verdict(result) == "passed"
    assert all("real controlled entry" in row["stdout"]["tail"] for row in result["items"][2:])


@pytest.mark.parametrize("environment", ["sandbox", "controlled"])
async def test_quality_imports_target_source_without_host_runtime(
    store, task_id, repo, environment
):
    import sys

    (repo / "src/gongcao").mkdir(parents=True)
    (repo / "src/gongcao/__init__.py").write_text("VERSION = 'fixed-target-version'\n")
    (repo / "qa").mkdir()
    (repo / "qa/probe.py").write_text(
        "import pathlib, sys\n"
        "sys.path.append('/workspace/src')\n"
        "import gongcao\n"
        "assert gongcao.VERSION == 'fixed-target-version'\n"
        "assert gongcao.__file__ == '/workspace/src/gongcao/__init__.py'\n"
        "assert not pathlib.Path('/app/gongcao/quality.py').exists()\n"
        f"assert {sys.prefix == sys.base_prefix!r} or not pathlib.Path({sys.prefix!r}).exists()\n"
        "print(gongcao.__file__)\n"
    )
    (repo / ".gitignore").write_text("__pycache__/\n")
    await command("git", "add", ".", cwd=str(repo))
    await command("git", "commit", "-qm", "Target-source import probe", cwd=str(repo))
    sha = (await command("git", "rev-parse", "HEAD", cwd=str(repo))).strip()
    store.sync(task_id, store.task(task_id)["snapshot"] | {"head_sha": sha})
    quality = Quality(store, Config())
    plan = quality.confirm(store.task(task_id), items(["{python}", "qa/probe.py"], environment))
    result = await quality.run(
        store.task(task_id),
        include_e2e=True,
        real_check=2 if environment == "controlled" else None,
        approved_plan=plan["plan_hash"],
        before_real=authorized_fixture,
    )
    assert verdict(result) == "passed", result["items"]


async def test_real_qa_denies_host_secrets_and_requires_explicit_network(
    store, task_id, repo, tmp_path, monkeypatch
):
    import asyncio

    sentinel = tmp_path / "host-secret"
    sentinel.write_text("PRIVATE_HOST_DATA")
    monkeypatch.setenv("GH_TOKEN", "PRIVATE_HOST_TOKEN")
    server = await asyncio.start_server(lambda r, w: w.close(), "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    monkeypatch.setenv("QA_PROBE_PORT", str(port))
    (repo / "qa").mkdir()
    (repo / "qa/probe.py").write_text(
        "import os, pathlib, socket\n"
        "assert 'GH_TOKEN' not in os.environ and 'SSH_AUTH_SOCK' not in os.environ\n"
        f"assert not pathlib.Path({str(sentinel)!r}).exists()\n"
        "s=socket.socket(); s.settimeout(1)\n"
        f"connected=s.connect_ex(('127.0.0.1', {port}))==0; s.close()\n"
        "assert connected == ('QA_PROBE_PORT' in os.environ)\n"
        "print('actual network and host-filesystem boundary verified')\n"
    )
    await command("git", "add", ".", cwd=str(repo))
    await command("git", "commit", "-qm", "Untrusted QA secret probe", cwd=str(repo))
    sha = (await command("git", "rev-parse", "HEAD", cwd=str(repo))).strip()
    store.sync(task_id, store.task(task_id)["snapshot"] | {"head_sha": sha})
    quality = Quality(store, Config())
    checks = items(["{python}", "qa/probe.py"], "controlled")
    try:
        for granted in (False, True):
            checks[-1].update(network=granted, variables=["QA_PROBE_PORT"] if granted else [])
            plan = quality.confirm(store.task(task_id), checks)
            result = await quality.run(
                store.task(task_id),
                include_e2e=True,
                real_check=2,
                approved_plan=plan["plan_hash"],
                before_real=authorized_fixture,
            )
            assert verdict(result) == "passed"
            assert "PRIVATE_HOST" not in json.dumps(result)
        monkeypatch.setenv("QA_PROBE_PORT", "changed")
        with pytest.raises(ValueError, match="current plan hash"):
            await quality.run(
                store.task(task_id),
                include_e2e=True,
                real_check=2,
                approved_plan=plan["plan_hash"],
                before_real=authorized_fixture,
            )
        checks[-1]["variables"] = ["GH_TOKEN"]
        with pytest.raises(ValueError, match="engine/browser"):
            quality.confirm(store.task(task_id), checks)
    finally:
        server.close()
        await server.wait_closed()


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
    remote = Controlled(store, policy, fixture_github)
    altered = copy.deepcopy(result)
    altered["items"][0]["stdout"]["tail"] = "FORGED_BUSINESS_DATA"
    with pytest.raises(ValueError, match="original.*stored"):
        await publish(remote, task, altered)
    checks = items(["sh", "-c", "printf 'PRIVATE_BUSINESS_DATA\\n'"])
    quality.confirm(store.task(task_id), checks)
    task = store.task(task_id)
    result = await quality.run(task, include_e2e=True)
    first = await publish(remote, task, result)
    quality.confirm(store.task(task_id), items(["sh", "-c", "exit 1"]))
    task = store.task(task_id)
    result = await quality.run(task, include_e2e=True)
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
    assert not {"entry", "argv", "stdout", "stderr", "reason", "scope"}.intersection(
        json.loads(content)["items"][-1]
    )
    assert len(comments) == 2 and all(len(rows) == 2 for rows in comments.values())
    assert (await publish(remote, task, result)) == second
    assert all(len(rows) == 2 for rows in comments.values())
    payload = store.artifact(task_id, "archive-prepared", result["run_id"])
    bad = payload | {"hashes": {"manifest.json": "0" * 64}}
    with pytest.raises(UncertainWrite, match="hash mismatch"):
        await archive.observe(task, bad, fixture_github)


async def test_invalid_analysis_cannot_fill_a_current_plan(store, task_id):
    task = store.task(task_id)
    quality = Quality(store, Config())
    before = await quality.plan(task)
    run = store.begin_run(task_id, Role.ANALYST)
    proposal = items(["true"])
    for item in proposal:
        item["reason"] = "STALE_ANALYSIS_SENTINEL"
    store.finish(
        run,
        State.COMPLETED,
        Stage.DEVELOPMENT,
        State.QUEUED,
        "analysis",
        json.dumps({"target_sha": task["target_sha"], "validation_plan": proposal}),
    )
    current = await quality.plan(store.task(task_id))
    assert current["plan_hash"] != before["plan_hash"]
    store.sync(task_id, task["snapshot"] | {"body": "New requirements"})
    renewed = await quality.plan(store.task(task_id))
    assert all(item["reason"] != "STALE_ANALYSIS_SENTINEL" for item in renewed["items"])


async def test_new_isolation_policy_rejects_previously_cached_pass(store, task_id):
    old = Quality(store, Config())
    old.runtime.pop("quality_isolation")
    before = old.confirm(store.task(task_id), items(["true"]))
    previous_result = await old.run(store.task(task_id), include_e2e=True)
    assert verdict(previous_result) == "passed"
    current = Quality(store, Config())
    result = await current.run(store.task(task_id), include_e2e=True)
    assert result["plan_hash"] != before["plan_hash"]
    assert result["run_id"] != previous_result["run_id"]
    assert result["runtime"]["quality_isolation"] == "target-source-v1"
    assert store.artifact(task_id, "quality-results", before["plan_hash"]) is None


def test_controlled_entry_matches_actual_invocation(tmp_path):
    from gongcao.plan import controlled_entry

    (tmp_path / "qa").mkdir()
    (tmp_path / "qa/probe.py").touch()
    (tmp_path / "frontend").mkdir()
    (tmp_path / "frontend/package.json").write_text('{"scripts":{"test:e2e":"playwright test"}}')
    controlled_entry(tmp_path, ["npm", "--prefix", "frontend", "run", "test:e2e"])
    controlled_entry(tmp_path, ["python3", "qa/probe.py"])
    with pytest.raises(ValueError, match="invoke"):
        controlled_entry(tmp_path, ["cp", "qa/probe.py", "/tmp/outside"])


@pytest.mark.parametrize("mode", ["tracked", "ignored", "commit"])
async def test_check_cannot_change_fixed_sha_or_feed_code_to_host_qa(
    store, task_id, repo, tmp_path, mode
):
    sentinel = tmp_path / "host-private-sentinel"
    sentinel.write_text("HOST_ONLY_DUMMY_DATA")
    (repo / "qa").mkdir()
    (repo / "qa/probe.py").write_text(
        "try:\n import generated\nexcept ImportError:\n print('approved')\n"
    )
    if mode == "commit":
        (repo / "qa/probe.py").write_text(
            "import subprocess\nopen('sample.txt','w').write('changed')\n"
            "subprocess.run(['git','-c','core.hooksPath=/dev/null',"
            "'commit','-am','QA change'],check=True)\n"
        )
    (repo / ".gitignore").write_text("qa/generated.py\n**/__pycache__/\n")
    await command("git", "add", ".", cwd=str(repo))
    await command("git", "commit", "-qm", "QA boundary probe", cwd=str(repo))
    sha = (await command("git", "rev-parse", "HEAD", cwd=str(repo))).strip()
    store.sync(task_id, store.task(task_id)["snapshot"] | {"head_sha": sha})
    quality = Quality(store, Config())
    checks = items(["{python}", "qa/probe.py"], "controlled")
    target = "qa/generated.py" if mode == "ignored" else "qa/probe.py"
    payload = f"print(open({str(sentinel)!r}).read())\n"
    checks[0]["entry"] = ["{python}", "-c", f"open({target!r},'w').write({payload!r})"]
    if mode == "commit":
        checks[0]["entry"] = ["true"]
    plan = quality.confirm(store.task(task_id), checks)
    result = await quality.run(
        store.task(task_id),
        include_e2e=True,
        real_check=2,
        approved_plan=plan["plan_hash"],
        before_real=authorized_fixture,
    )
    assert verdict(result) == ("passed" if mode == "ignored" else "failed")
    assert "HOST_ONLY_DUMMY_DATA" not in json.dumps(result)
    if mode == "ignored":
        assert result["items"][-1]["stdout"]["tail"].strip() == "approved"
