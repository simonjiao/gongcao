"""Actual CLI subprocesses and OS sandboxes; only external protocols are substituted."""

import json
import os
import subprocess
import sys
from pathlib import Path

from gongcao.model import Stage, State


def test_offline_cli_preserves_task_pr_sha_and_evidence_through_control_modes(
    tmp_path, repo, sha, snapshot, auth_file
):
    bare = tmp_path / "remote.git"
    subprocess.run(["git", "clone", "--bare", "-q", str(repo), str(bare)], check=True)
    fixture = tmp_path / "github.json"
    fixture.write_text(
        json.dumps(
            {
                "issue": snapshot,
                "sha": sha,
                "bare": str(bare),
                "reviews": [],
                "writes": [],
            }
        )
    )
    config = tmp_path / "config.yaml"
    config.write_text(
        f"auth_file: {auth_file}\ncopilot:\n  mode: step\nquality:\n"
        "  ci_workflows: [ci.yml]\n"
        "  checks: [['{python}', '-c', \"assert open('sample.txt').read() == 'complete\\\\n'\"]]\n"
    )
    root = Path(__file__).resolve().parents[1]
    env = {
        **os.environ,
        "GONGCAO_COPILOT_FIXTURE": str(fixture),
        "PYTHONPATH": os.pathsep.join((str(root / "src"), str(root))),
    }

    def cli(*args):
        result = subprocess.run(
            [
                sys.executable,
                "-m",
                "qa.copilot_fixture",
                "--state-dir",
                str(tmp_path / "state"),
                *args,
            ],
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert result.returncode == 0, result.stdout + result.stderr
        return json.loads(result.stdout)

    task = cli("register", snapshot["url"], "--repo", str(repo), "--config", str(config))
    number = str(task["id"])

    def drive(expected):
        cli("serve", "--once", "--config", str(config))
        task = cli("inspect", number)
        assert task["stage"] == expected, task["reason"]
        assert task["state"] == State.WAITING_INSTRUCTION
        assert task["runtime"]["lease"] is None
        return task

    drive(Stage.DEVELOPMENT)
    cli("control", number, "--step", "--config", str(config))
    published = drive(Stage.REVIEW)
    assert published["pr_number"] == 9 and published["target_sha"] != sha
    cli("control", number, "--until", "validation", "--config", str(config))
    reviewed = drive(Stage.VALIDATION)
    assert [r["role"] for r in reviewed["runs"]] == ["analyst", "developer", "reviewer"]
    cli("control", number, "--auto", "--config", str(config))
    cli("run", number, "--config", str(config))
    final = cli("inspect", number)
    assert (final["stage"], final["state"]) == (Stage.MERGEABLE, State.COMPLETED)
    assert final["id"] == published["id"] and final["pr_number"] == published["pr_number"]
    assert final["target_sha"] == published["target_sha"] == reviewed["target_sha"]
    assert all(op["state"] == "succeeded" for op in final["evidence"]["operations"])
    assert len(final["runs"]) == len({r["thread_id"] for r in final["runs"]}) == 4
    before = fixture.read_text(), [r["id"] for r in final["runs"]]
    cli("run", number, "--config", str(config))
    assert before == (fixture.read_text(), [r["id"] for r in cli("inspect", number)["runs"]])
