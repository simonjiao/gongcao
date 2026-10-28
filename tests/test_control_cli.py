"""Actual CLI subprocesses and OS sandboxes; only external protocols are substituted."""

import json
import os
import subprocess
import sys
import time
from datetime import UTC, datetime
from pathlib import Path

from gongcao.model import Stage, State
from qa.ledger import write_json


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
    config.write_text(f"auth_file: {auth_file}\ncopilot:\n  mode: step\n  operators: [owner]\n")
    root = Path(__file__).resolve().parents[1]
    env = {
        **os.environ,
        "GONGCAO_COPILOT_FIXTURE": str(fixture),
        "PYTHONPATH": os.pathsep.join((str(root / "src"), str(root))),
    }

    command = [sys.executable, "-m", "qa.copilot_fixture", "--state-dir", str(tmp_path / "state")]

    def cli(*args):
        result = subprocess.run(
            [*command, *args],
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

    cli("control", number, "--step", "--config", str(config))
    waiting = drive(Stage.DEVELOPMENT)
    serving = subprocess.Popen(
        [*command, "serve", "--poll", "1", "--config", str(config)],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        data = json.loads(fixture.read_text())
        stamp = datetime.fromtimestamp(int(waiting["control"]["since"]), UTC).isoformat()
        data["comments"] = [
            {
                "id": 1,
                "body": "/gongcao step",
                "user": {"login": "owner"},
                "created_at": stamp,
                "updated_at": stamp,
            }
        ]
        write_json(fixture, data)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            published = cli("inspect", number)
            if (
                published["stage"] == Stage.REVIEW
                and published["state"] == State.WAITING_INSTRUCTION
                and published["runtime"]["lease"] is None
            ):
                break
            assert serving.poll() is None
            time.sleep(0.1)
        else:
            raise AssertionError(published)
    finally:
        if serving.poll() is None:
            serving.terminate()
        stdout, stderr = serving.communicate(timeout=15)
    assert serving.returncode in {0, 130}, stdout + stderr
    assert any(
        row["id"] == "github:1" and row["status"] == "consumed"
        for row in published["evidence"]["instructions"]
    )
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
