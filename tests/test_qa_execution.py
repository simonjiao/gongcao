import asyncio
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest
from _support.cli import QA, cli_env, events, run_cli
from _support.qa import new_run

from gongcao.config import Config
from gongcao.github import GitHub, command
from gongcao.model import Stage, State
from gongcao.quality import Quality
from gongcao.store import Store
from qa.__main__ import execute as cli_execute
from qa.__main__ import parser
from qa.copilot import wake
from qa.evidence import verify_archived, verify_batch
from qa.ledger import Run, RunCancelled
from qa.runner import batch, core, execute, verify_implementation
from qa.scenarios import pytest_snapshot_script


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


async def test_batch_queue_failure_isolation_and_durable_evidence(tmp_path, monkeypatch):
    active = set()
    peak = 0
    release = asyncio.Event()
    seen = []

    async def environment(**kwargs):
        return {}

    async def command(*args, **kwargs):
        return "a" * 40 if args[:3] == ("git", "rev-parse", "HEAD") else ""

    async def execute(run, **kwargs):
        nonlocal peak
        assert run.root.is_dir()
        active.add(run.id)
        peak = max(peak, len(active))
        seen.append(run.id)
        if len(seen) == 1:
            await release.wait()
        elif len(seen) == 2:
            release.set()
            await asyncio.sleep(0.01)
        try:
            if run.value["scenario"] == "recover":
                raise ValueError("one deliberately fails")
            run.archive("verdict", {"passed": True, "at": 1})
            run.value["status"] = "passed"
            run.save()
        finally:
            active.remove(run.id)

    monkeypatch.setattr("qa.runner.check", environment)
    monkeypatch.setattr("qa.runner.command", command)
    monkeypatch.setattr("qa.runner.execute", execute)
    report = await batch(
        tmp_path,
        ["smoke", "recover", "smoke"],
        jobs=2,
        real=True,
        repository="example/demo",
        model=None,
        clean=False,
    )
    assert peak == 2 and len(seen) == 3 and not report["passed"]
    assert [r["status"] for r in report["results"]] == ["passed", "interrupted", "passed"]
    events = report["events"]
    third = next(e for e in events if e["kind"] == "started" and e["run_id"] == seen[2])
    assert any(e["kind"] == "released" and e["at"] <= third["at"] for e in events)
    first = Run(tmp_path, seen[0])
    assert verify_archived(first)["passed"]
    with pytest.raises(ValueError):
        verify_batch(tmp_path, report["id"])


async def test_fault_kills_only_owned_controller_before_local_ack(tmp_path, repo, sha, snapshot):
    run = new_run(tmp_path, "recover")
    run.value["resources"]["issue"] = {"url": snapshot["url"]}
    run.save()
    store = Store(run.root / "state")
    try:
        task_id = store.register(snapshot["url"], repo, sha, snapshot)
        store.intent(store.task(task_id), "owned-op", "review", "{}")
    finally:
        store.close()

    script = """
from pathlib import Path
from gongcao.store import Store
import qa.fault as fault
import os
store = Store(Path(os.environ['QA_TEST_STATE']))
fault.gongcao_main = lambda: store.operation_result('owned-op', 'succeeded', {'id': 23})
fault.main()
"""
    process = await asyncio.create_subprocess_exec(
        sys.executable,
        "-c",
        script,
        env={
            **os.environ,
            "GONGCAO_QA_DATA": str(tmp_path),
            "GONGCAO_QA_RUN": run.id,
            "QA_TEST_STATE": str(run.root / "state"),
        },
    )
    assert await asyncio.wait_for(process.wait(), 10) == -9
    witness = json.loads((run.root / "fault.json").read_text())
    assert witness["operation"] == "owned-op" and witness["observed_response"] == {"id": 23}
    store = Store(run.root / "state")
    try:
        assert store.operation("owned-op")["state"] == "pending"
    finally:
        store.close()


async def test_cancel_scenario_must_not_pass_a_normal_loop(tmp_path, monkeypatch):
    run = new_run(tmp_path, "cancel")
    task = {"stage": "mergeable", "state": "completed", "evidence": {"operations": []}}

    async def prepare(run, github, model):
        run.value["task_id"] = 1

    async def drive(run, **kwargs):
        return 0

    monkeypatch.setattr("qa.runner.prepare", prepare)
    monkeypatch.setattr("qa.runner.drive", drive)
    monkeypatch.setattr("qa.runner.inspect", lambda run: task)
    await execute(run, model=None, clean=False)
    assert run.value["status"] == "failed"
    assert "never triggered" in run.value["failure"]


async def test_changed_implementation_cannot_start_or_pass(tmp_path, monkeypatch):
    run = new_run(tmp_path)

    async def command(*args, **kwargs):
        return "b" * 40 if args[:3] == ("git", "rev-parse", "HEAD") else ""

    monkeypatch.setattr("qa.runner.command", command)
    with pytest.raises(ValueError, match="Implementation changed"):
        await verify_implementation(run)


async def test_qa_launches_actual_native_cli_without_remote_credentials(tmp_path, monkeypatch):
    run = new_run(tmp_path)

    async def fixed(run):
        pass  # The protocol fixture has no implementation checkout; test the real CLI launch.

    monkeypatch.setattr("qa.runner.verify_implementation", fixed)
    assert await core(run, "status") == 0
    records = list(run.root.glob("command-*.json"))
    assert len(records) == 1
    record = json.loads(records[0].read_text())
    assert json.loads(record["stdout"]) == [] and not record["stderr"]


async def test_copilot_wakeup_waits_for_lease_release_before_stopping_serve(tmp_path, monkeypatch):
    run = new_run(tmp_path)
    observed = asyncio.Event()
    released = False
    state = "waiting_instruction"

    async def serving(run, *args, stop_event):
        nonlocal released, state
        await observed.wait()
        try:
            await asyncio.wait_for(stop_event.wait(), 0.05)
        except TimeoutError:
            released = True
            await stop_event.wait()
        else:
            state = "needs_reconciliation"  # Shutdown interrupted occupied work.
        return 130

    def inspect(run):
        observed.set()
        return {
            "stage": "pending_development",
            "state": state,
            "reason": "",
            "runtime": {"lease": None if released else {"owner": "live"}},
        }

    async def post(text):
        return "github:1"

    monkeypatch.setattr("qa.copilot.core", serving)
    monkeypatch.setattr("qa.copilot.inspect", inspect)
    assert await wake(run, run.root / "config.yaml", post) == "github:1"
    assert released and state == "waiting_instruction"


async def test_qa_pytest_snapshot_supports_git_clones_inside_real_quality_sandbox(
    store, repo, snapshot
):
    from shutil import copyfile, copytree, ignore_patterns

    # This fixture owns its pytest dependencies at the target SHA. Quality no longer
    # exposes the host controller's virtualenv, and this regression stays offline.
    for name in ("pytest", "_pytest", "pluggy", "packaging", "iniconfig", "pygments"):
        package = Path(__import__(name).__file__).parent
        copytree(package, repo / name, ignore=ignore_patterns("__pycache__"))
    copyfile(__import__("py").__file__, repo / "py.py")
    (repo / "test_checkout.py").write_text(
        "import subprocess\nfrom pathlib import Path\n"
        "def test_clone(tmp_path):\n"
        "    subprocess.run(['git','clone','-q','--local',str(Path.cwd()),"
        "str(tmp_path/'copy')],check=True)\n"
        "def test_nested_home_isolation(tmp_path):\n"
        "    host_secret = Path.home() / '.codex/auth.json'\n"
        "    host_secret.parent.mkdir(parents=True)\n"
        "    host_secret.write_text('DUMMY_OUTER_SECRET')\n"
        "    inner_home = tmp_path / 'inner-home'\n"
        "    inner_home.mkdir(); (inner_home/'.codex').mkdir()\n"
        "    (inner_home/'.codex/auth.json').write_text('{}')\n"
        "    subprocess.run(['bwrap','--ro-bind','/usr','/usr','--ro-bind','/lib','/lib',\n"
        "        '--ro-bind','/lib64','/lib64','--bind',str(inner_home),'/home/agent',\n"
        "        '--unshare-user','--unshare-pid','--proc','/proc','/usr/bin/python3.12','-c',\n"
        "        'from pathlib import Path; assert not Path('"
        "+repr(str(host_secret))+').exists()'],\n"
        "        check=True)\n"
    )
    await command("git", "add", ".", cwd=str(repo))
    await command("git", "commit", "-qm", "clone-dependent project check", cwd=str(repo))
    sha = (await command("git", "rev-parse", "HEAD", cwd=str(repo))).strip()
    task_id = store.register(snapshot["url"], repo, sha, snapshot)
    store.transition(store.task(task_id), Stage.REVIEW, State.QUEUED, "fixture")
    quality = Quality(store, Config())
    quality.confirm(
        store.task(task_id),
        [
            {
                "category": category,
                "entry": ["{python}", "-c", pytest_snapshot_script()]
                if category == "internal"
                else [],
                "scope": ["tests"],
                "required": category == "internal",
                "reason": "Source snapshot probe",
                "environment": "sandbox",
            }
            for category in ("build", "internal", "e2e")
        ],
    )
    data = await quality.run(store.task(task_id))
    assert data["passed"], data["items"]
    tree = (await command("git", "rev-parse", "HEAD^{tree}", cwd=str(repo))).strip()
    assert "QA_SOURCE_TREE=" + tree in data["items"][1]["stdout"]["tail"]


@pytest.mark.parametrize("scene", ["loop", "smoke"])
async def test_cancel_third_queued_run_never_prepares_or_starts_sdk(tmp_path, monkeypatch, scene):
    first_two = asyncio.Event()
    release = asyncio.Event()
    prepared = []
    checks = []

    async def check(**kwargs):
        checks.append(kwargs)
        return {}

    async def git(*args, **kwargs):
        return "a" * 40 if args[:3] == ("git", "rev-parse", "HEAD") else ""

    async def prepare(run, github, model):
        prepared.append(run.id)
        if len(prepared) == 2:
            first_two.set()
        await release.wait()
        raise ValueError("Protocol fixture stops before creating resources")

    async def unexpected(*args, **kwargs):
        raise AssertionError("Cancelled queued Run must not create an issue or start SDK work")

    monkeypatch.setattr("qa.runner.check", check)
    monkeypatch.setattr("qa.runner.command", git)
    monkeypatch.setattr("qa.runner.prepare", prepare)
    monkeypatch.setattr("qa.runner.core", unexpected)
    monkeypatch.setattr("qa.resources.create_issue", unexpected)
    pending = asyncio.create_task(
        batch(
            tmp_path,
            ["loop", "loop", scene],
            jobs=2,
            real=True,
            repository="example/demo",
            model=None,
            clean=True,
        )
    )
    try:
        await asyncio.wait_for(first_two.wait(), 5)
        queued = next(
            Run(tmp_path, p.parent.name)
            for p in (tmp_path / "runs").glob("*/manifest.json")
            if json.loads(p.read_text())["status"] == "queued"
        )
        result = await cli_execute(
            parser().parse_args(["--data-dir", str(tmp_path), "cancel", queued.id])
        )
        assert result["cancel_requested"] and result["status"] == "queued"
        assert len(prepared) == 2
    finally:
        release.set()
    report = await asyncio.wait_for(pending, 5)
    cancelled = Run(tmp_path, queued.id)
    assert cancelled.value["status"] == "cancelled" and cancelled.value["cleaned"]
    assert not cancelled.value["resources"] and not cancelled.value.get("task_id")
    assert not (cancelled.root / "state").exists() and not list(cancelled.root.glob("command-*"))
    assert len(prepared) == 2 and len(checks) == 1 and not report["passed"]


@pytest.mark.parametrize(
    "status", ["passed", "failed", "cancelled", "interrupted", "needs_reconciliation"]
)
async def test_cancel_finished_run_does_not_report_accepted(tmp_path, status):
    stale = new_run(tmp_path)
    finished = Run(tmp_path, stale.id)
    finished.value["status"] = status
    finished.save()
    args = parser().parse_args(["--data-dir", str(tmp_path), "cancel", stale.id])
    result = await cli_execute(args)
    assert result == {"run_id": stale.id, "cancel_requested": False, "status": status}
    assert not stale.request_cancel()["cancel_requested"]
    assert not (stale.root / "cancel-requested").exists()


@pytest.mark.parametrize("point", ["after_clone", "before_issue_write", "after_issue"])
async def test_preparation_cancel_stops_new_work_and_cleans_owned_resources(
    tmp_path, monkeypatch, point
):
    run = new_run(tmp_path)
    issue = None
    writes = []
    core_calls = []

    class Remote(GitHub):
        async def read(self, path):
            if path == "repos/example/demo":
                return {"default_branch": "main", "ssh_url": "git@github.com:example/demo.git"}
            if path.endswith("/git/ref/heads/main"):
                return {"object": {"sha": "a" * 40}}
            if "/git/ref/" in path:
                raise RuntimeError("HTTP 404")
            assert issue is not None
            if point == "after_issue" and issue["state"] == "open":
                run.request_cancel()
            return dict(issue)

        async def pages(self, path, field=None):
            if "/issues?" in path and point == "before_issue_write":
                run.request_cancel()
            return []

    async def clone(*args, **kwargs):
        if args[:2] == ("git", "clone"):
            for name in (
                "pyproject.toml",
                "uv.lock",
                ".github/workflows/ci.yml",
                "src/gongcao/cli.py",
            ):
                path = run.root / "source" / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()
            if point == "after_clone":
                run.request_cancel()
        return ""

    async def mutate(*args, **kwargs):
        nonlocal issue
        writes.append(args[3])
        if args[3] == "POST":
            issue = json.loads(kwargs["input_data"]) | {
                "number": 41,
                "state": "open",
                "html_url": "https://github.com/example/demo/issues/41",
                "user": {"login": "qa"},
            }
            return json.dumps({"number": 41})
        assert args[3] == "PATCH" and issue is not None
        issue["state"] = "closed"
        return "{}"

    async def native(*args, **kwargs):
        core_calls.append(args)
        raise AssertionError("Preparation cancellation must prevent registration/model launch")

    monkeypatch.setattr("qa.runner.GitHub", Remote)
    monkeypatch.setattr("qa.runner.command", clone)
    monkeypatch.setattr("qa.runner.core", native)
    monkeypatch.setattr("qa.resources.command", mutate)
    await execute(run, model=None, clean=True)
    assert run.value["status"] == "cancelled" and run.value["cleaned"]
    assert not core_calls and not (run.root / "source").exists()
    assert writes == (["POST", "PATCH"] if point == "after_issue" else [])
    if issue:
        assert issue["state"] == "closed"


async def test_user_cancel_reaches_native_execution_during_preparation(
    tmp_path, repo, sha, snapshot, monkeypatch
):
    run = new_run(tmp_path)
    store = Store(run.root / "state")
    try:
        run.value["task_id"] = store.register(snapshot["url"], repo, sha, snapshot)
    finally:
        store.close()
    entered = run.root / "native-entered"
    original = asyncio.create_subprocess_exec
    commands = []
    script = """
import sys,time
from pathlib import Path
from gongcao.store import Store
store=Store(Path(sys.argv[1]))
Path(sys.argv[2]).touch()
while not store.task(1)['cancel_requested']:
    time.sleep(0.02)
store.close()
print('cancelled')
"""

    async def launch(*args, **kwargs):
        operation = args[5]
        commands.append(operation)
        if operation == "run":
            # Substitute long native execution; cancel uses the real CLI and public Store.
            return await original(
                sys.executable, "-c", script, str(run.root / "state"), str(entered), **kwargs
            )
        return await original(*args, **kwargs)

    async def fixed(run):
        pass

    monkeypatch.setattr("qa.runner.verify_implementation", fixed)
    monkeypatch.setattr("qa.runner.asyncio.create_subprocess_exec", launch)
    pending = asyncio.create_task(core(run, "run", "1", "--config", "missing-gate.yaml"))
    try:
        async with asyncio.timeout(5):
            while not entered.exists():
                await asyncio.wait({pending}, timeout=0.02)
        assert run.request_cancel()["cancel_requested"]
        assert await asyncio.wait_for(pending, 5) == 0
    finally:
        if not pending.done():
            pending.cancel()
        await asyncio.gather(pending, return_exceptions=True)
    assert commands == ["run", "cancel"]
    store = Store(run.root / "state")
    try:
        assert store.task(1)["state"] == "cancelled"
    finally:
        store.close()


async def test_cancellation_during_implementation_check_prevents_native_spawn(
    tmp_path, monkeypatch
):
    run = new_run(tmp_path)

    async def verify(run):
        run.request_cancel()

    async def forbidden(*args, **kwargs):
        raise AssertionError("Known cancellation must prevent native process creation")

    monkeypatch.setattr("qa.runner.verify_implementation", verify)
    monkeypatch.setattr("qa.runner.asyncio.create_subprocess_exec", forbidden)
    with pytest.raises(RunCancelled):
        await core(run, "run", "1")
