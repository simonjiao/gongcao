import argparse
import json

import pytest
from beartype.roar import BeartypeCallHintParamViolation

from gongcao.cli import execute, parser
from gongcao.config import Config
from gongcao.github import GitHub, Target
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
    snapshot = await GitHub().snapshot(Target.parse("https://github.com/a/b/issues/1"))
    assert calls == [("gh", "api", "repos/a/b/issues/1")]
    assert snapshot["body"] == "[REDACTED]"


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
