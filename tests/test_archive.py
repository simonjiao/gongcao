import copy
import json

import pytest
from _support.quality import items

from gongcao.archive import publish
from gongcao.github import command
from gongcao.quality import Quality
from gongcao.remote import Controlled, UncertainWrite
from gongcao.workflow import Workflow


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
