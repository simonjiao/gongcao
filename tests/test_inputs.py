import argparse
import asyncio
import json

import pytest
import yaml
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


def test_parallel_jobs_config_defaults_and_independent_values(tmp_path):
    assert Config.load(None).scheduler_jobs == 1
    assert Config.load(None).qa_jobs == 2
    path = tmp_path / "gongcao.yaml"
    path.write_text("scheduler:\n  jobs: 3\nqa:\n  jobs: 7\n")
    config = Config.load(path)
    assert config.scheduler_jobs == 3
    assert config.qa_jobs == 7
    assert config.policy_hash == Config().policy_hash


@pytest.mark.parametrize(
    "settings, options, expected",
    [
        (None, [], 1),
        ({}, [], 1),
        ({"qa": {"jobs": 7}}, [], 1),
        ({"scheduler": {"jobs": 3}, "qa": {"jobs": 7}}, [], 3),
        ({"scheduler": {"jobs": 3}, "qa": {"jobs": 7}}, ["--jobs", "2"], 2),
        ({"scheduler": {"jobs": 1}}, ["--jobs", "3"], 3),
    ],
)
async def test_serve_cli_jobs_precedence_and_active_task_limit(
    store, repo, sha, snapshot, tmp_path, monkeypatch, settings, options, expected
):
    path = tmp_path / "gongcao.yaml"
    config_options = []
    if settings is not None:
        path.write_text(yaml.safe_dump(settings))
        config_options = ["--config", str(path)]
    for number in range(1, 5):
        url = f"https://github.com/example/demo/issues/{number}"
        store.register(url, repo, sha, snapshot | {"number": number, "url": url})
    active, peak = 0, 0
    started, release = asyncio.Event(), asyncio.Event()

    async def read(self, target):
        nonlocal active, peak
        active += 1
        peak = max(peak, active)
        if active == expected:
            started.set()
        try:
            await release.wait()
            raise OSError("Test GitHub endpoint unavailable; no Agent or remote writes")
        finally:
            active -= 1

    monkeypatch.setattr(GitHub, "snapshot", read)
    args = parser().parse_args(["serve", "--once", *config_options, *options])
    running = asyncio.create_task(execute(args, store))
    try:
        await asyncio.wait_for(started.wait(), 15)
        assert peak == expected
    finally:
        release.set()
        assert await running == 0
    assert peak == expected
    assert all(task["state"] == "waiting_environment" for task in store.tasks())


@pytest.mark.parametrize("section", ["scheduler", "qa"])
@pytest.mark.parametrize("value", [True, False, 1.5, 0, -1, "2", None, [], {}])
def test_jobs_yaml_rejects_invalid_values(tmp_path, section, value):
    path = tmp_path / "gongcao.yaml"
    path.write_text(yaml.safe_dump({section: {"jobs": value}}))
    with pytest.raises(ValueError, match=rf"{section}\.jobs"):
        Config.load(path)
    if section == "qa":
        with pytest.raises(ValueError, match=r"qa\.jobs"):
            Config.load_qa_jobs(path)


@pytest.mark.parametrize("settings", [None, 2, [], {"job": 2}, {"jobs": 2, "extra": 1}])
@pytest.mark.parametrize("section", ["scheduler", "qa"])
def test_jobs_yaml_rejects_invalid_sections(tmp_path, section, settings):
    path = tmp_path / "gongcao.yaml"
    path.write_text(yaml.safe_dump({section: settings}))
    with pytest.raises(ValueError, match=section):
        Config.load(path)
    if section == "qa":
        with pytest.raises(ValueError, match=section):
            Config.load_qa_jobs(path)


def test_scheduler_jobs_has_an_upper_bound(tmp_path):
    path = tmp_path / "gongcao.yaml"
    path.write_text("scheduler:\n  jobs: 4\n")
    with pytest.raises(ValueError, match=r"scheduler.jobs.*between 1 and 3"):
        Config.load(path)


@pytest.mark.parametrize(
    "options", [["--concurrency", "2"], *[["--jobs", v] for v in ("0", "-1", "4", "1.5", "true")]]
)
def test_serve_cli_rejects_deprecated_and_invalid_jobs(options):
    with pytest.raises(SystemExit) as exc:
        parser().parse_args(["serve", *options])
    assert exc.value.code == 2


def test_qa_jobs_loader_ignores_production_settings(tmp_path):
    path = tmp_path / "gongcao.yaml"
    path.write_text("scheduler:\n  jobs: 99\nroles: ignored\nquality: ignored\nqa:\n  jobs: 5\n")
    assert Config.load_qa_jobs(path) == 5


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
