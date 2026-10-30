"""Actual CLI and sandbox processes with only GitHub/model protocols substituted."""

import hashlib
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import pytest
import yaml


@pytest.mark.parametrize("continuous", [False, True])
def test_discovery_cli_claims_pauses_and_restarts_without_duplicates(
    tmp_path, repo, sha, snapshot, auth_file, continuous
):
    fixture = tmp_path / "github.json"
    name = "example/discovery-" + hashlib.sha256(str(tmp_path).encode()).hexdigest()[:12]
    snapshot = snapshot | {"repository": name, "url": f"https://github.com/{name}/issues/1"}
    subprocess.run(
        ["git", "remote", "set-url", "origin", f"https://github.com/{name}.git"],
        cwd=repo,
        check=True,
    )
    issues = [
        snapshot
        | {
            "number": number,
            "url": snapshot["url"][:-1] + str(number),
            "labels": [{"name": "agent-ready"}],
            "assignees": [],
        }
        for number in range(1, 4 if continuous else 2)
    ]
    fixture.write_text(
        json.dumps(
            {
                "issue": snapshot,
                "issues": issues,
                "sha": sha,
                "writes": [],
                "reviews": [],
                "slow": continuous,
                "clone_from": str(repo),
            }
        )
    )
    config = tmp_path / "config.yaml"
    settings = {
        "auth_file": str(auth_file),
        "scheduler": {"jobs": 2},
        "discovery": {
            "enabled": True,
            "interval_seconds": 1,
            "sources": [{"repo": name, "path": str(repo)}],
        },
    }
    if not continuous:
        settings["discovery"]["repo_root"] = str(tmp_path / "clones")
        del settings["discovery"]["sources"][0]["path"]
    config.write_text(yaml.safe_dump(settings))
    root = Path(__file__).resolve().parents[1]
    env = {
        **os.environ,
        "GONGCAO_COPILOT_FIXTURE": str(fixture),
        "PYTHONPATH": os.pathsep.join((str(root / "src"), str(root))),
    }
    argv = [sys.executable, "-m", "qa.copilot_fixture", "--state-dir", str(tmp_path / "state")]

    def cli(*args):
        result = subprocess.run([*argv, *args], env=env, capture_output=True, text=True, timeout=60)
        assert result.returncode == 0, result.stdout + result.stderr
        if args[0] == "serve":
            assert result.stderr.count("启动概览：") == 1
            assert "单次运行（--once）" in result.stderr and "持续运行" not in result.stderr
            assert "jobs=2" in result.stderr and "已登记任务=" in result.stderr
        return json.loads(result.stdout)

    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True)
    if continuous:
        process = subprocess.Popen(
            [*argv, "serve", "--poll", "1", "--config", str(config)],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            deadline, peak = time.monotonic() + 40, False
            while time.monotonic() < deadline and process.poll() is None:
                tasks = cli("status")
                states = [task["state"] for task in tasks]
                if states.count("running") == 2:
                    assert states.count("queued") == 1
                    peak = True
                if len(tasks) == 3 and states.count("waiting_instruction") == 3:
                    break
                time.sleep(0.1)
            assert peak and states.count("waiting_instruction") == 3
        finally:
            process.terminate()
            stdout, stderr = process.communicate(timeout=15)
            assert process.returncode == 130, stdout + stderr
            assert stderr.count("启动概览：持续运行") == 1
            assert "仓库已复用" in stderr and "领取已远端确认" in stderr
            assert "阶段：分析" in stderr and "阶段：开发" in stderr
            assert "暂停等待指令" in stderr
    else:
        tasks = cli("serve", "--once", "--config", str(config))
        assert tasks[0]["repo_path"] == str(tmp_path / "clones" / name)
        assert len(tasks) == 1 and tasks[0]["stage"] == "pending_development"
        assert tasks[0]["state"] == "waiting_instruction"
    before = [cli("inspect", str(task["id"])) for task in cli("status")]
    writes = json.loads(fixture.read_text())["writes"]
    for enabled in (True, False):
        settings["discovery"]["enabled"] = enabled
        config.write_text(yaml.safe_dump(settings))
        cli("serve", "--once", "--config", str(config))
        after = [cli("inspect", str(task["id"])) for task in cli("status")]
        assert [t["runs"] for t in after] == [t["runs"] for t in before]
        assert json.loads(fixture.read_text())["writes"] == writes
    data = json.loads(fixture.read_text())
    assert data.get("clones", 0) == (0 if continuous else 1)
    claims = [c for c in data["status_comments"] if "<!-- gongcao:" in c["body"]]
    progress = [c for c in data["status_comments"] if "<!-- gongcao-progress:" in c["body"]]
    assert len(claims) == len(progress) == len(issues) and not data.get("pull")
    assert all("claim pending confirmation" in c["body"] for c in claims)
    assert all(w["method"] == "POST" for w in data["writes"])
    assert all(t["control"]["source"] == "discovery" and not t["runtime"]["lease"] for t in after)
    assert subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True) == head
