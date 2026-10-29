import argparse
import asyncio
import json
from types import SimpleNamespace

import pytest
from beartype.roar import BeartypeCallHintParamViolation

from gongcao.cli import execute, parser
from gongcao.config import Config
from gongcao.github import Deferred, GitHub, Target, Traffic, background
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


async def test_github_adapter_calls_get_only_and_redacts(monkeypatch, caplog):
    calls = []

    async def read(*args):
        calls.append(args)
        return json.dumps(
            {
                "title": "Test",
                "body": "github_pat_sensitivevalue",
                "state": "open",
                "updated_at": "now",
            }
        )

    monkeypatch.setattr("gongcao.github.command", read)
    api = GitHub()
    snapshot = await api.snapshot(Target.parse("https://github.com/a/b/issues/1"))
    assert calls == [("gh", "api", "repos/a/b/issues/1")]
    assert snapshot["body"] == "[REDACTED]"

    async def gates(*args):
        return json.dumps({"data": {"repository": {"pullRequest": {"reviewDecision": None}}}})

    monkeypatch.setattr("gongcao.github.read_command", gates)
    assert (await api.gates({"snapshot": {"repository": "a/b"}, "pr_number": 1}))[
        "reviewDecision"
    ] == ""
    monkeypatch.setattr("gongcao.github.read_command", read)
    calls.clear()
    token = background.set(True)
    try:
        await asyncio.gather(api.read("user"), api.read("user"))
        assert len(calls) == 1 and api.traffic.counts["saved"] == 1
        usage = Traffic(budget=1, remaining=999, limit=5000, reset=2000000000.0)
        with pytest.raises(Deferred):
            usage.start(False)
        usage.remaining = 4000
        usage.start(False)
        with pytest.raises(Deferred):
            usage.start(False)
    finally:
        background.reset(token)
    await asyncio.gather(api.read("user"), api.read("user"))
    assert len(calls) == 3  # Separate foreground checkpoints never share an older response.
    caplog.set_level("INFO", logger="gongcao")
    api.report()
    caplog.clear()
    clock = [1000.0]
    monkeypatch.setattr("gongcao.github.time.monotonic", lambda: clock[0])
    api.traffic.reported_at = clock[0]
    for _ in range(12):
        api.traffic.counts["saved"] += 1
        api.report()
        clock[0] += 5
    assert not caplog.records
    clock[0] += 300
    api.report()
    assert len(caplog.records) == 1 and "saved" in caplog.text
    api.traffic.start(False)
    api.report()
    assert len(caplog.records) == 2  # Actual requests are reported immediately.
    release = asyncio.Event()

    async def snapshot(target):
        if background.get():
            await release.wait()
        return {"body": "old" if background.get() else "new"}

    monkeypatch.setattr(api, "snapshot", snapshot)
    task = {"url": "https://github.com/a/b/issues/1"}
    token = background.set(True)
    old = asyncio.create_task(api.task_snapshot(task))
    await asyncio.sleep(0)
    background.reset(token)
    assert (await api.task_snapshot(task))["body"] == "new"
    release.set()
    await old
    token = background.set(True)
    assert (await api.task_snapshot(task))["body"] == "new"
    background.reset(token)


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


@pytest.mark.parametrize("permission", [False, True])
async def test_github_read_retry_is_bounded_and_never_retries_denied_access(
    monkeypatch, permission
):
    calls = 0

    async def transport(*args, **kwargs):
        nonlocal calls
        calls += 1
        if permission:
            raise PermissionError("HTTP 403")
        raise RuntimeError("Get https://api.github.com/user: EOF")

    monkeypatch.setattr("gongcao.github.command", transport)
    with pytest.raises(PermissionError if permission else ConnectionError):
        await GitHub().read("user")
    assert calls == (1 if permission else 3)


@pytest.mark.parametrize(
    "status,headers,limited",
    [
        (401, "", False),
        (403, "", False),
        (403, "X-RateLimit-Remaining: 0\n", True),
        (403, "Retry-After: 45\n", True),
        (429, "Retry-After: 45\n", True),
        (403, None, True),
        (429, None, True),
        (
            403,
            "X-RateLimit-Remaining: 0\nX-RateLimit-Reset: 9000\nX-RateLimit-Resource: graphql\n",
            True,
        ),
    ],
)
async def test_rate_limit_headers_count_and_cooldown(store, monkeypatch, status, headers, limited):
    now = [1000.0]
    monkeypatch.setattr("gongcao.github.time.time", lambda: now[0])

    async def launch(*args, **kwargs):
        async def communicate(data):
            return (
                f"HTTP/2.0 {status} Error\n{headers}\n{{}}".encode()
                if headers is not None
                else b"",
                f"HTTP {status}".encode()
                if headers is not None
                else f"API rate limit exceeded (HTTP {status})".encode(),
            )

        return SimpleNamespace(communicate=communicate, returncode=1)

    monkeypatch.setattr("gongcao.github.launch", launch)
    monkeypatch.setattr("gongcao.github.completed", lambda process: None)
    api = GitHub()
    api.traffic.restore(store)  # Also persists before Discovery has registered any task.
    api.traffic.reset = 2000.0  # A core reset must not replace a GraphQL reset.
    with pytest.raises(Deferred if limited else PermissionError):
        await api.read("user")
    assert api.traffic.counts["checks"] == 1
    if limited:
        restarted = Traffic()
        restarted.restore(store)
        assert restarted.cooldown == api.traffic.cooldown
        if headers and "9000" in headers:
            assert api.traffic.cooldown == 9000
        with pytest.raises(Deferred):
            await api.mutate("path", {})
        assert api.traffic.counts["writes"] == 0
        now[0] = api.traffic.cooldown + 1
        api.traffic.start(False)  # Recovery admits a fresh request, without busy waiting.
        api.traffic.cooldown = now[0] + 10000
        with pytest.raises(Deferred):
            api.traffic.observe(f"HTTP/2.0 {status} Error\nRetry-After: 1\n\n{{}}", True)
        assert api.traffic.cooldown == now[0] + 10000


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
