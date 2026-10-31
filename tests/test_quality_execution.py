import asyncio
import json

import pytest
from _support.quality import authorized_fixture, items

from gongcao.config import Config
from gongcao.github import command
from gongcao.model import State
from gongcao.quality import Quality, verdict
from gongcao.workflow import Workflow


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
