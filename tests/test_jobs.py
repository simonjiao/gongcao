"""QA CLI configuration is exercised in an actual clean implementation checkout."""

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest
import yaml

from qa.__main__ import execute, parser


@pytest.mark.parametrize(
    "settings, options, expected",
    [
        (None, [], 2),
        (None, ["--jobs", "1"], 1),
        ({}, [], 2),
        ({"scheduler": {"jobs": 3}}, [], 2),
        ({"scheduler": {"jobs": 1}, "qa": {"jobs": 7}}, [], 7),
        ({"qa": {"jobs": 7}, "quality": "ignored-production-policy"}, ["--jobs", "3"], 3),
        ({"qa": {}}, ["--jobs", "1"], 1),
    ],
)
def test_qa_cli_jobs_precedence_without_using_production_policy(
    tmp_path, repo, settings, options, expected
):
    source = Path(__file__).resolve().parents[1]
    for name in ("src", "qa"):
        shutil.copytree(source / name, repo / name, ignore=shutil.ignore_patterns("__pycache__"))
    for name in ("pyproject.toml", "uv.lock", ".gitignore"):
        shutil.copyfile(source / name, repo / name)
    subprocess.run(["git", "add", "."], cwd=repo, check=True)
    subprocess.run(["git", "commit", "-qm", "QA configuration fixture"], cwd=repo, check=True)
    path = tmp_path / "gongcao.yaml"
    config_options = []
    if settings is not None:
        path.write_text(yaml.safe_dump(settings))
        config_options = ["--config", str(path)]
    process = subprocess.run(
        [
            sys.executable,
            "-m",
            "qa",
            "--data-dir",
            str(tmp_path / "qa-data"),
            "run",
            "smoke",
            *config_options,
            *options,
        ],
        cwd=repo,
        env={**os.environ, "PYTHONPATH": os.pathsep.join((str(repo / "src"), str(repo)))},
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert process.returncode == 0, process.stdout + process.stderr
    report = json.loads(process.stdout)
    assert report["passed"]
    assert report["jobs"] == expected


@pytest.mark.parametrize("value", ["0", "-1"])
async def test_qa_cli_rejects_nonpositive_jobs_before_creating_a_batch(tmp_path, value):
    data = tmp_path / "qa-data"
    args = parser().parse_args(["--data-dir", str(data), "run", "smoke", "--jobs", value])
    with pytest.raises(ValueError, match="--jobs must be a positive integer"):
        await execute(args)
    assert not data.exists()


@pytest.mark.parametrize("value", ["true", "1.5"])
def test_qa_cli_rejects_noninteger_jobs(value):
    with pytest.raises(SystemExit) as exc:
        parser().parse_args(["run", "smoke", "--jobs", value])
    assert exc.value.code == 2
