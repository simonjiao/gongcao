import json
import subprocess

import pytest
import yaml
from _support.cli import GONGCAO, QA, cli_env, events, run_cli

from gongcao.cli import parser as serve_parser
from gongcao.config import Config, DiscoveryConfig
from gongcao.model import Role
from qa.__main__ import execute, parser


@pytest.mark.parametrize(
    "policy_text",
    [
        'quality: {checks: ["pytest"]}',
        'quality: {ci_workflows: ["../ci.yml"]}',
        "quality: {require_real_checks: yesplease}",
        "max_revisions: -1",
    ],
)
def test_invalid_quality_policy_is_rejected(tmp_path, policy_text):
    path = tmp_path / "config.yaml"
    path.write_text(policy_text)
    with pytest.raises(ValueError):
        Config.load(path)


def test_config_does_not_allow_granting_write_permissions(tmp_path):
    config = tmp_path / "config.yaml"
    config.write_text("roles:\n  reviewer:\n    writable: true\n")
    with pytest.raises(ValueError):
        Config.load(config)
    config.write_text("timeout_seconds: -1\n")
    with pytest.raises(ValueError):
        Config.load(config)
    assert not Role.REVIEWER.writable


def test_jobs_defaults_independence_and_policy_hash(tmp_path):
    assert (Config.load(None).scheduler_jobs, Config.load_qa_jobs(None)) == (1, 2)
    path = tmp_path / "jobs.yaml"
    path.write_text("scheduler:\n  jobs: 3\nqa:\n  jobs: 7\n")
    config = Config.load(path)
    assert (config.scheduler_jobs, config.qa_jobs) == (3, 7)
    assert config.policy_hash == Config().policy_hash
    path.write_text("{}")
    assert (Config.load(path).scheduler_jobs, Config.load_qa_jobs(path)) == (1, 2)


@pytest.mark.parametrize("value", [True, False, 1.5, 0, -1, "2", None, [], {}])
def test_jobs_rejects_each_invalid_value_category(tmp_path, value):
    # Both sections share one validator; retain every negative without a Cartesian product.
    path = tmp_path / "jobs.yaml"
    for section in ("scheduler", "qa"):
        path.write_text(yaml.safe_dump({section: {"jobs": value}}))
        with pytest.raises(ValueError, match=rf"{section}\.jobs"):
            Config.load(path)
        if section == "qa":
            with pytest.raises(ValueError, match=r"qa\.jobs"):
                Config.load_qa_jobs(path)


@pytest.mark.parametrize("settings", [None, 2, [], {"job": 2}, {"jobs": 2, "extra": 1}])
def test_jobs_rejects_invalid_section_shapes_and_fields(tmp_path, settings):
    path = tmp_path / "jobs.yaml"
    for section in ("scheduler", "qa"):
        path.write_text(yaml.safe_dump({section: settings}))
        with pytest.raises(ValueError, match=section):
            Config.load(path)
        if section == "qa":
            with pytest.raises(ValueError, match=section):
                Config.load_qa_jobs(path)


def test_scheduler_upper_bound_and_qa_policy_independence(tmp_path):
    path = tmp_path / "jobs.yaml"
    path.write_text("scheduler:\n  jobs: 4\nroles: ignored\nmodel: ignored\nqa:\n  jobs: 5\n")
    assert Config.load_qa_jobs(path) == 5
    path.write_text("scheduler:\n  jobs: 4\n")
    with pytest.raises(ValueError, match=r"scheduler.jobs.*between 1 and 3"):
        Config.load(path)


@pytest.mark.parametrize("value", ["0", "-1", "4", "1.5", "true"])
async def test_cli_jobs_boundaries(tmp_path, value):
    with pytest.raises(SystemExit) as exc:
        serve_parser().parse_args(["serve", "--jobs", value])
    assert exc.value.code == 2
    if value in {"0", "-1"}:
        data = tmp_path / "qa-data"
        args = parser().parse_args(["--data-dir", str(data), "run", "smoke", "--jobs", value])
        with pytest.raises(ValueError, match="--jobs must be a positive integer"):
            await execute(args)
        assert not data.exists()
    elif value == "4":
        assert parser().parse_args(["run", "smoke", "--jobs", value]).jobs == 4
    else:
        with pytest.raises(SystemExit) as exc:
            parser().parse_args(["run", "smoke", "--jobs", value])
        assert exc.value.code == 2


def test_serve_rejects_old_concurrency_option():
    with pytest.raises(SystemExit) as exc:
        serve_parser().parse_args(["serve", "--concurrency", "2"])
    assert exc.value.code == 2


def test_offline_invalid_configuration_fails_before_execution(checkout, tmp_path):
    gate = tmp_path / "gate"
    env = cli_env(checkout, gate)
    path, state, data = tmp_path / "jobs.yaml", tmp_path / "state", tmp_path / "data"
    path.write_text("scheduler:\n  jobs: true\n")
    rejected = subprocess.run(
        [GONGCAO, "--state-dir", str(state), "serve", "--once", "--config", str(path)],
        cwd=checkout,
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert rejected.returncode == 1 and "scheduler.jobs" in rejected.stderr
    assert run_cli(checkout, env, GONGCAO, "--state-dir", str(state), "status") == []
    path.write_text("qa:\n  jobs: 0\n")
    rejected = subprocess.run(
        [*QA, "--data-dir", str(data), "run", "smoke", "--config", str(path)],
        cwd=checkout,
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert rejected.returncode == 1 and "qa.jobs" in json.loads(rejected.stdout)["failure"]
    assert not data.exists() and not events(gate)


def test_discovery_configuration_defaults_and_rejections(tmp_path):
    assert not Config.load(None).discovery.enabled
    for raw in (
        {"enabled": True},
        {"interval_seconds": 0},
        {"max_new_per_scan": True},
        {"sources": [{"repo": "example/demo", "path": "relative"}]},
        {"unexpected": 1},
    ):
        with pytest.raises(ValueError):
            DiscoveryConfig.load(raw)
    path = tmp_path / "config.yaml"
    path.write_text(
        "discovery:\n  enabled: true\n  sources:\n    - repo: EXAMPLE/Demo\n"
        f"      path: {tmp_path}\n"
    )
    assert Config.load(path).discovery.sources[0].repo == "example/demo"


def test_config_defaults_overrides_sources_and_policy(tmp_path):
    default = Config.load(None)
    assert default.model == "gpt-6.1-sol" and default.reasoning_effort == "xhigh"
    assert set(default.execution["source"].values()) == {"project-default"}
    path = tmp_path / "config.yaml"
    path.write_text("model: gpt-6.1-sol\nreasoning_effort: xhigh\n")
    assert set(Config.load(path).execution["source"].values()) == {"configuration"}
    path.write_text("reasoning_effort: high\n")
    assert Config.load(path).policy_hash != default.policy_hash
    assert Config.load(path).execution["source"]["model"] == "project-default"


@pytest.mark.parametrize(
    "text",
    [
        "model: null",
        'model: ""',
        "reasoning_effort: turbo",
        "reasoning_effort: null",
        "reasoning_effort: []",
    ],
)
def test_invalid_model_configuration_fails_before_session(tmp_path, text):
    path = tmp_path / "config.yaml"
    path.write_text(text)
    with pytest.raises(ValueError):
        Config.load(path)
