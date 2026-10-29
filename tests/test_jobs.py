"""Jobs boundaries and offline CLI paths; no real GitHub/SDK acceptance is claimed."""

import fcntl
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

import pytest
import yaml

from gongcao.cli import parser as serve_parser
from gongcao.config import Config
from gongcao.store import Store
from qa.__main__ import execute, parser

GONGCAO = str(Path(sys.executable).with_name("gongcao"))
QA = (sys.executable, "-m", "qa")


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


@pytest.fixture(scope="module")
def checkout(tmp_path_factory):
    root = tmp_path_factory.mktemp("jobs-offline")
    path = root / "checkout"
    subprocess.run(
        ["git", "clone", "-q", "--local", str(Path(__file__).resolve().parents[1]), str(path)],
        check=True,
    )
    # Only the external gh boundary is substituted. API reads wait on an observable
    # barrier, then report closed targets so the real CLI cannot start an Agent.
    binary = root / "bin"
    binary.mkdir()
    gh = binary / "gh"
    gh.write_text(
        f"#!{sys.executable}\n"
        "import fcntl,json,os,pathlib,sys,time\n"
        "if sys.argv[1:]==['--version']:\n"
        "    print('gh offline protocol fixture');sys.exit(0)\n"
        "gate=pathlib.Path(os.environ['JOBS_TEST_GATE'])\n"
        "def event(kind):\n"
        "    with (gate/'calls.jsonl').open('a') as out:\n"
        "        fcntl.flock(out,fcntl.LOCK_EX)\n"
        "        out.write(json.dumps({'kind':kind,'argv':sys.argv[1:]})+'\\n')\n"
        "event('started')\n"
        "assert len(sys.argv)==4 and sys.argv[1]=='api' and sys.argv[3]=='--include'\n"
        "assert sys.argv[2].startswith('repos/example/demo/issues/')\n"
        "deadline=time.monotonic()+30\n"
        "while not (gate/'release').exists() and time.monotonic()<deadline: time.sleep(.01)\n"
        "assert (gate/'release').exists(),'offline barrier timed out'\n"
        "event('released')\n"
        "print(json.dumps({'title':'offline','body':'','state':'closed',"
        "'updated_at':'2026-10-25T00:00:00Z'}))\n"
    )
    gh.chmod(0o700)
    return path


def cli_env(checkout, gate):
    gate.mkdir(exist_ok=True)
    (gate / "calls.jsonl").touch()
    return {
        **os.environ,
        "PATH": str(checkout.parent / "bin") + os.pathsep + os.environ["PATH"],
        "PYTHONPATH": os.pathsep.join((str(checkout / "src"), str(checkout))),
        "JOBS_TEST_GATE": str(gate),
    }


def events(gate):
    with (gate / "calls.jsonl").open() as stream:
        fcntl.flock(stream, fcntl.LOCK_SH)
        return [json.loads(line) for line in stream]


def run_cli(checkout, env, *argv):
    result = subprocess.run(argv, cwd=checkout, env=env, capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stdout + result.stderr
    return json.loads(result.stdout)


def test_offline_qa_defaults_yaml_override_and_batch_evidence(checkout, tmp_path):
    env = cli_env(checkout, tmp_path / "gate")
    sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=checkout, text=True).strip()
    path = tmp_path / "jobs.yaml"
    path.write_text("scheduler:\n  jobs: 3\nqa:\n  jobs: 1\nmodel: ignored-production-policy\n")
    for name, options, expected in (
        ("default", [], 2),
        ("yaml", ["--config", str(path)], 1),
        ("override", ["--config", str(path), "--jobs", "2"], 2),
    ):
        data = tmp_path / name
        argv = (*QA, "--data-dir", str(data))
        report = run_cli(checkout, env, *argv, "run", "smoke", "--repeat", "3", *options)
        assert report["passed"] and report["jobs"] == expected
        assert [row["status"] for row in report["results"]] == ["passed"] * 3
        verified = run_cli(checkout, env, *argv, "verify-batch", report["id"])
        assert verified["passed"] and verified["peak_runs"] == expected and verified["queued"]
        assert verified["runs"] == report["runs"] and len(set(report["runs"])) == 3
        for run_id in report["runs"]:
            manifest = json.loads((data / "runs" / run_id / "manifest.json").read_text())
            assert manifest["implementation_sha"] == sha
            assert not manifest["resources"] and not manifest["actions"]
        # A real verification command must reject changed archived evidence.
        if name == "override":
            (data / "runs" / report["id"] / "verdict.json").write_text("{}")
            rejected = subprocess.run(
                [*argv, "verify-batch", report["id"]],
                cwd=checkout,
                env=env,
                capture_output=True,
                text=True,
                timeout=30,
            )
            assert rejected.returncode == 1
            assert "Evidence changed" in json.loads(rejected.stdout)["failure"]
    assert not events(tmp_path / "gate")


def test_offline_serve_cli_enforces_1_to_3_slots_and_queues(checkout, tmp_path):
    path = tmp_path / "jobs.yaml"
    path.write_text("scheduler:\n  jobs: 2\nqa:\n  jobs: 7\n")
    sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=checkout, text=True).strip()
    for jobs, options in (
        (1, []),
        (2, ["--config", str(path)]),
        (3, ["--config", str(path), "--jobs", "3"]),
    ):
        state, gate = tmp_path / f"state-{jobs}", tmp_path / f"gate-{jobs}"
        store = Store(state)
        try:
            for number in range(1, 5):
                url = f"https://github.com/example/demo/issues/{number}"
                store.register(
                    url,
                    checkout,
                    sha,
                    {
                        "url": url,
                        "repository": "example/demo",
                        "kind": "issues",
                        "number": number,
                        "title": "offline",
                        "body": "",
                        "state": "open",
                        "updated_at": "2026-10-25T00:00:00Z",
                    },
                )
        finally:
            store.close()
        env = cli_env(checkout, gate)
        with subprocess.Popen(
            [GONGCAO, "--state-dir", str(state), "serve", "--once", *options],
            cwd=checkout,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        ) as process:
            try:
                deadline = time.monotonic() + 20
                while (
                    len(events(gate)) < jobs
                    and process.poll() is None
                    and time.monotonic() < deadline
                ):
                    time.sleep(0.01)
                assert len(events(gate)) == jobs  # Others cannot read until a slot releases.
                status = run_cli(checkout, env, GONGCAO, "--state-dir", str(state), "status")
                occupied = [t for t in status if t["runtime"]["lease"] is not None]
                assert len(status) == 4 and len(occupied) == jobs
                assert all(t["runtime"]["lease"]["pid"] == process.pid for t in occupied)
            finally:
                (gate / "release").touch()
                try:
                    stdout, stderr = process.communicate(timeout=20)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.communicate()
                    raise
            assert process.returncode == 0, stdout + stderr
        tasks = json.loads(stdout)
        assert len(tasks) == 4 and all(t["state"] == "needs_human" for t in tasks)
        store = Store(state)
        try:
            for task in tasks:
                assert not store.runs(task["id"])
                assert not store.evidence(task["id"])["operations"]
        finally:
            store.close()
        active, peak = 0, 0
        rows = events(gate)
        assert len(rows) == 8 and rows[jobs]["kind"] == "released"
        for row in rows:
            active += 1 if row["kind"] == "started" else -1
            peak = max(peak, active)
            assert 0 <= active <= jobs
        assert active == 0 and peak == jobs


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
