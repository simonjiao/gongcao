import argparse
import asyncio
import json
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
from beartype.roar import BeartypeCallHintParamViolation

from gongcao.cli import execute, parser
from gongcao.config import Config
from gongcao.github import Deferred, GitHub, Target, Traffic, background, command
from gongcao.model import Role


def test_runtime_type_checks_are_enabled(store):
    with pytest.raises(BeartypeCallHintParamViolation):
        Target.parse(123)
    with pytest.raises(BeartypeCallHintParamViolation):
        store.task("wrong-type")


@pytest.mark.parametrize(
    "url",
    [
        "https://evil.invalid/a/b/issues/1",
        "https://github.com/a/b/issues/0",
        "https://github.com/a/b/issues/1?token=secret",
        "a/b#1",
    ],
)
def test_invalid_target_rejected(url):
    with pytest.raises(ValueError):
        Target.parse(url)


def test_canonical_target():
    assert Target.parse("https://github.com/a/b/pull/12/").url == "https://github.com/a/b/pull/12"


def test_config_does_not_allow_granting_write_permissions(tmp_path):
    config = tmp_path / "config.yaml"
    config.write_text("roles:\n  reviewer:\n    writable: true\n")
    with pytest.raises(ValueError):
        Config.load(config)
    config.write_text("timeout_seconds: -1\n")
    with pytest.raises(ValueError):
        Config.load(config)
    assert not Role.REVIEWER.writable


async def test_github_adapter_calls_get_only_and_redacts(monkeypatch):
    calls, release = [], asyncio.Event()

    async def read(*args):
        calls.append(args)
        if background.get() and args[-1] != "user":
            await release.wait()
        return json.dumps(
            {
                "title": "Test",
                "body": "old" if background.get() else "github_pat_sensitivevalue",
                "data": {"repository": {"pullRequest": {"reviewDecision": None}}},
                "state": "open",
                "updated_at": "now",
            }
        )

    monkeypatch.setattr("gongcao.github.command", read)
    api = GitHub()
    snapshot = await api.snapshot(Target.parse("https://github.com/a/b/issues/1"))
    assert calls == [("gh", "api", "repos/a/b/issues/1")]
    assert snapshot["body"] == "[REDACTED]"

    task = {"url": "https://github.com/a/b/issues/1"}
    token = background.set(True)
    old = asyncio.gather(api.task_snapshot(task), api.task_snapshot(task))
    await asyncio.sleep(0)
    background.reset(token)
    assert (await api.task_snapshot(task))["body"] == "[REDACTED]"
    release.set()
    assert all(row["body"] == "old" for row in await old)
    token = background.set(True)
    assert (await api.task_snapshot(task))["body"] == "[REDACTED]"
    background.reset(token)
    assert len(calls) == 3 and api.traffic.counts["saved"] >= 1
    assert (await api.gates({"snapshot": {"repository": "a/b"}, "pr_number": 1}))[
        "reviewDecision"
    ] == ""


async def test_transient_github_read_retries_but_a_write_never_replays(monkeypatch):
    calls = []

    async def transport(*args, **kwargs):
        calls.append(args)
        if len(calls) == 1:
            raise RuntimeError('Get "https://api.github.com/repos/a/b/pulls/1": EOF')
        return '{"ok": true}'

    monkeypatch.setattr("gongcao.github.command", transport)
    assert await GitHub().read("repos/a/b/pulls/1") == {"ok": True}
    assert len(calls) == 2
    calls.clear()
    with pytest.raises(RuntimeError, match="EOF"):
        await GitHub().mutate("repos/a/b/issues", {"title": "test"})
    assert len(calls) == 1


@pytest.mark.parametrize("permission", [False, 401, 403])
async def test_github_read_retry_is_bounded_and_never_retries_denied_access(
    monkeypatch, permission, store
):
    calls = 0

    async def transport(*args, **kwargs):
        nonlocal calls
        calls += 1
        if permission:
            raise PermissionError(f"HTTP {permission}")
        raise RuntimeError("Get https://api.github.com/user: EOF")

    monkeypatch.setattr("gongcao.github.command", transport)
    with pytest.raises(PermissionError if permission else ConnectionError):
        await GitHub().read("user")
    assert calls == (1 if permission else 3)
    if permission != 403:
        return
    usage = Traffic(budget=1, remaining=999, limit=5000, reset=2000.0)
    usage.restore(store)
    monkeypatch.setattr("gongcao.github.time.time", lambda: 1000.0)
    token = background.set(True)
    with pytest.raises(Deferred):
        usage.start(False)
    usage.remaining = 4000
    usage.start(False)
    with pytest.raises(Deferred):
        usage.start(False)
    background.reset(token)
    process = SimpleNamespace(communicate=AsyncMock(), returncode=1)
    monkeypatch.setattr("gongcao.github.command", command)
    monkeypatch.setattr("gongcao.github.launch", AsyncMock(return_value=process))
    monkeypatch.setattr("gongcao.github.completed", lambda process: None)
    for error, headers, until in (
        ("HTTP 401", "", 0),
        ("HTTP 403", "", 0),
        ("rate limit HTTP 403", "", 1030),
        ("rate limit HTTP 429", "", 1030),
        ("HTTP 403", "Retry-After: 45\n", 1045),
        ("HTTP 429", "Retry-After: 45\n", 1045),
        ("HTTP 403", "X-RateLimit-Remaining: 0\nX-RateLimit-Reset: 9000\n", 9000),
    ):
        api = GitHub()
        api.traffic.reset = 2000.0
        raw = f"HTTP/2.0 {error[-3:]} Error\n{headers}\n{{}}" if headers else ""
        process.communicate.return_value = (raw.encode(), error.encode())
        with pytest.raises(Deferred if until else PermissionError):
            await api.read("user")
        assert api.traffic.cooldown == until and api.traffic.counts["checks"] == 1
    usage = api.traffic
    usage.restore(store)
    restored = Traffic()
    restored.restore(store)
    assert restored.cooldown == usage.cooldown
    with pytest.raises(Deferred):
        usage.start(True)
    assert not usage.counts["writes"]
    monkeypatch.setattr("gongcao.github.time.time", lambda: 9500.0)
    usage.start(False)
    usage.cooldown = 10000.0
    with pytest.raises(Deferred):
        usage.observe("HTTP/2.0 429 Error\nRetry-After: 1\n\n{}", True)
    assert usage.cooldown == 10000.0


async def test_pr_snapshot_keeps_base_branch_identity(monkeypatch):
    async def read(*args):
        return json.dumps(
            {
                "title": "Test PR",
                "body": "",
                "state": "open",
                "updated_at": "now",
                "merged": False,
                "head": {
                    "sha": "1" * 40,
                    "ref": "gongcao/task-277cd634480e",
                    "repo": {"full_name": "fork/demo"},
                },
                "base": {
                    "sha": "2" * 40,
                    "ref": "release",
                    "repo": {"full_name": "example/demo"},
                },
            }
        )

    monkeypatch.setattr("gongcao.github.command", read)
    snapshot = await GitHub().snapshot(Target.parse("https://github.com/example/demo/pull/1"))
    assert snapshot["base_sha"] == "2" * 40
    assert snapshot["base_ref"] == "release"
    assert snapshot["base_repository"] == "example/demo"
    assert snapshot["head_ref"] == "gongcao/task-277cd634480e"


async def test_status_inspect_and_cancel_are_local(store, task_id, capsys):
    for name in ("status", "inspect", "cancel"):
        args = parser().parse_args([name, str(task_id)])
        assert await execute(args, store) == 0
        assert json.loads(capsys.readouterr().out)


async def test_sync_queries_only_explicitly_registered_targets(
    store, task_id, snapshot, monkeypatch
):
    urls = []

    async def read(self, target):
        urls.append(target.url)
        return snapshot

    monkeypatch.setattr(GitHub, "snapshot", read)
    await execute(argparse.Namespace(command="sync", task=None), store)
    assert urls == [snapshot["url"]]
