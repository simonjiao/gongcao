import asyncio
import contextlib
import json
import os
import signal
import sys
import time
from pathlib import Path

import pytest
from test_pr2 import WORKER
from test_pr2 import fixture_github as fixture_github
from test_pr2 import policy as policy
from test_runner import SUCCESS, install_worker

from gongcao.cli import logs
from gongcao.config import Config
from gongcao.github import GitHub
from gongcao.github import command as git_command
from gongcao.leases import Lease, identity, session_alive
from gongcao.model import AgentResult, Role, Stage, State
from gongcao.processes import CleanupError, launch, stop
from gongcao.quality import Quality
from gongcao.recovery import Recovery, diagnose
from gongcao.remote import Controlled
from gongcao.runner import Runner
from gongcao.scheduler import Scheduler
from gongcao.store import Store
from gongcao.workflow import Workflow


class RegisteredGitHub(GitHub):
    def __init__(self, store):
        self.store = store
        self.review_rows = []
        self.writes = 0

    async def snapshot(self, target):
        return next(dict(t["snapshot"]) for t in self.store.tasks() if t["url"] == target.url)

    async def pages(self, path, field=None):
        return self.review_rows

    async def mutate(self, path, payload):
        self.writes += 1
        raise AssertionError("Recovery must never write remotely")


def register_more(store, repo, sha, snapshot, count):
    return [
        store.register(
            snapshot["url"].rsplit("/", 1)[0] + f"/{i}",
            repo,
            sha,
            snapshot | {"number": i, "url": snapshot["url"].rsplit("/", 1)[0] + f"/{i}"},
        )
        for i in range(2, count + 2)
    ]


def analysis_ready(store, task_id, sha):
    run = store.begin_run(task_id, Role.ANALYST)
    result = AgentResult(
        conclusion="ready",
        summary="Confirmed plan",
        basis=["Inspect sample.txt"],
        target_sha=sha,
        next_steps=["Implement in an isolated worktree"],
    )
    store.finish(
        run, State.COMPLETED, Stage.DEVELOPMENT, State.QUEUED, "planned", result.model_dump_json()
    )


async def wait_for(predicate):
    async with asyncio.timeout(15):
        while not predicate():  # noqa: ASYNC110 -- observing SQLite/OS state across processes
            await asyncio.sleep(0.02)


async def test_leases_exclude_duplicate_tasks_and_limit_all_controllers(
    store, task_id, repo, sha, snapshot
):
    ids = [task_id, *register_more(store, repo, sha, snapshot, 3)]
    other = Store(store.root)
    try:
        async with contextlib.AsyncExitStack() as stack:
            for tid in ids[:3]:
                assert (await stack.enter_async_context(Lease(store, tid))).acquired
            async with Lease(other, task_id) as duplicate:
                assert not duplicate.acquired
            async with Lease(other, ids[3]) as fourth:
                assert not fourth.acquired
            assert store.db.execute("SELECT count(*) FROM leases").fetchone()[0] == 3
        assert store.db.execute("SELECT count(*) FROM leases").fetchone()[0] == 0
    finally:
        other.close()


async def test_two_registered_objects_cannot_own_the_same_pr(store, task_id, repo, sha, snapshot):
    second = register_more(store, repo, sha, snapshot, 1)[0]
    with store.db:
        store.db.execute("UPDATE tasks SET pr_number=9")
    async with Lease(store, task_id) as first:
        async with Lease(store, second) as duplicate:
            assert first.acquired and not duplicate.acquired
        assert store.db.execute("SELECT owner FROM leases").fetchone()[0] == first.owner


async def test_heartbeat_renews_and_late_results_require_the_original_owner(store, task_id, sha):
    async with Lease(store, task_id, ttl=0.15):
        await asyncio.sleep(0.25)
        assert store.db.execute("SELECT expires FROM leases").fetchone()[0] > time.time()
        run = store.begin_run(task_id, Role.ANALYST)
        with store.db:
            store.db.execute("UPDATE leases SET owner='replacement'")
        with pytest.raises(ValueError, match="lease lost"):
            store.record(store.task(task_id), "checks", "policy", {"passed": True})
        store.finish(run, State.COMPLETED, Stage.DEVELOPMENT, State.QUEUED, "late", "{}")
        assert store.task(task_id)["state"] == State.RECONCILE
        assert not store.runs(task_id)[0]["evidence_valid"]
    assert store.db.execute("SELECT owner FROM leases").fetchone()[0] == "replacement"


async def test_pending_spawn_blocks_fresh_execution_but_failed_exec_is_settled(store, task_id):
    async with Lease(store, task_id) as lease:
        with pytest.raises(FileNotFoundError):
            await launch("/does-not-exist-gongcao")
        assert store.db.execute("SELECT state FROM processes").fetchone()[0] == "stopped"
        lease.intent("bwrap")
    async with Lease(store, task_id) as again:
        assert not again.acquired
    result = await Recovery(store, RegisteredGitHub(store)).recover(task_id)
    assert not result["recovered"] and "unknown spawn" in result["reason"]


CONTROLLER = r"""
import asyncio,json,sys
from pathlib import Path
from gongcao.config import Config
from gongcao.github import GitHub
from gongcao.leases import Lease
from gongcao.runner import Runner
from gongcao.sandbox import Sandbox
from gongcao.store import Store
store=Store(Path(sys.argv[1]));tid=int(sys.argv[2])
class Local(GitHub):
    async def snapshot(self,target):return dict(store.task(tid)['snapshot'])
original=Sandbox.argv
worker=("import json,sys,time,subprocess;from pathlib import Path;"
        "subprocess.Popen([sys.executable,'-c','import time;time.sleep(60)',"
        +repr(sys.argv[4])+"],start_new_session=True);"
        "sys.stdin.readline();Path('/workspace/sample.txt').write_text('partial');"
        "print(json.dumps({'kind':'thread','data':"
        "{'thread_id':'interrupted-thread'}}),flush=True);time.sleep(60)")
def argv(self,*payload):
    if payload[1:3]==('-m','gongcao.worker'):payload=(sys.executable,'-c',worker)
    return original(self,*payload)
Sandbox.argv=argv
async def main():
    async with Lease(store,tid):
        await Runner(store,Config(auth_file=Path(sys.argv[3])),Local()).run(tid)
try:asyncio.run(main())
finally:store.close()
"""


async def test_sigkill_restart_preserves_partial_work_and_uses_a_fresh_thread(
    store, task_id, repo, sha, auth_file, monkeypatch
):
    analysis_ready(store, task_id, sha)
    marker = f"gongcao-contained-{time.time_ns()}"
    parent = await asyncio.create_subprocess_exec(
        sys.executable,
        "-c",
        CONTROLLER,
        str(store.root),
        str(task_id),
        str(auth_file),
        marker,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        start_new_session=True,
    )
    contained_pid = None
    contained_identity = None
    try:
        await wait_for(
            lambda: any(r["thread_id"] == "interrupted-thread" for r in store.runs(task_id))
        )
        interrupted = store.runs(task_id)[-1]
        assert interrupted["owner_token"]
        for entry in Path("/proc").glob("[0-9]*"):
            try:
                if int(entry.name) != parent.pid and marker.encode() in (
                    entry / "cmdline"
                ).read_bytes().split(b"\0"):
                    contained_pid = int(entry.name)
                    contained_identity = identity(contained_pid)
                    break
            except (FileNotFoundError, ProcessLookupError, PermissionError):
                continue
        assert contained_pid and contained_identity
        parent.kill()
        await asyncio.wait_for(parent.communicate(), 10)
        records = store.db.execute("SELECT pid FROM processes WHERE state='running'").fetchall()
        await wait_for(lambda: all(not session_alive(r[0]) for r in records))
        await wait_for(lambda: identity(contained_pid) is None)
        restarted = Store(store.root)
        try:
            recovered = await Recovery(restarted, RegisteredGitHub(restarted)).recover(task_id)
            assert recovered["recovered"], recovered
            assert restarted.task(task_id)["state"] == State.QUEUED
            assert restarted.runs(task_id)[-1]["state"] == State.FAILED
            assert not restarted.runs(task_id)[-1]["evidence_valid"]
            assert (Path(interrupted["worktree"]) / "sample.txt").read_text() == "partial"
            install_worker(monkeypatch, SUCCESS)
            async with Lease(restarted, task_id):
                await Runner(
                    restarted, Config(auth_file=auth_file), RegisteredGitHub(restarted)
                ).run(task_id)
            fresh = restarted.runs(task_id)[-1]
            assert fresh["thread_id"] == "developer-thread"
            assert fresh["worktree"] != interrupted["worktree"]
            assert fresh["state"] == State.COMPLETED
            assert (Path(interrupted["worktree"]) / "sample.txt").read_text() == "partial"
            assert (repo / "sample.txt").read_text() == "original\n"
        finally:
            restarted.close()
    finally:
        if parent.returncode is None:
            parent.kill()
            await asyncio.wait_for(parent.communicate(), 10)
        if contained_pid and identity(contained_pid) == contained_identity:
            os.kill(contained_pid, signal.SIGKILL)


async def test_recovery_does_not_kill_a_live_old_session(store, task_id):
    process = await asyncio.create_subprocess_exec(
        sys.executable,
        "-c",
        "import time;time.sleep(60)",
        start_new_session=True,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        with store.db:
            store.db.execute(
                "INSERT INTO processes VALUES(?,?,?,?,?,?,?)",
                (
                    "old",
                    task_id,
                    "old-owner",
                    "bwrap",
                    process.pid,
                    identity(process.pid),
                    "running",
                ),
            )
        result = await Recovery(store, RegisteredGitHub(store)).recover(task_id)
        assert not result["recovered"]
        assert process.returncode is None
        assert store.task(task_id)["state"] == State.RECONCILE
    finally:
        os.killpg(process.pid, signal.SIGKILL)
        await process.communicate()


@pytest.mark.parametrize("match", ["yes", "absent", "different_sha", "duplicate", "cancel"])
async def test_unknown_review_is_queried_and_never_replayed(
    store, task_id, sha, monkeypatch, match
):
    with store.db:
        store.db.execute("UPDATE tasks SET pr_number=9 WHERE id=?", (task_id,))
    payload = {"body": "stable review marker", "commit_id": sha, "event": "COMMENT"}
    store.intent(store.task(task_id), "review-key", "review", json.dumps(payload))
    store.operation_result("review-key", "unknown", None)
    store.halt(task_id, State.RECONCILE, "write interrupted")
    github = RegisteredGitHub(store)
    if match != "absent":
        github.review_rows = [
            payload
            | {
                "id": 17,
                "state": "COMMENTED",
                "commit_id": sha if match != "different_sha" else "f" * 40,
            }
        ]
    if match == "duplicate":
        github.review_rows *= 2

    # This fixture has an already-linked issue; avoid fetching a fictitious remote PR.
    async def snapshot(task):
        if match == "cancel":
            store.cancel(task_id)
        return dict(task["snapshot"])

    monkeypatch.setattr(github, "task_snapshot", snapshot)
    result = await Recovery(store, github).recover(task_id)
    assert github.writes == 0
    if match in {"yes", "cancel"}:
        assert result["recovered"]
        assert store.operation("review-key")["state"] == "succeeded"
        assert store.task(task_id)["state"] == (
            State.CANCELLED if match == "cancel" else State.QUEUED
        )
    else:
        assert not result["recovered"]
        assert store.operation("review-key")["state"] == "unknown"
        assert store.task(task_id)["state"] == State.RECONCILE


async def test_dependency_cycle_rolls_back_and_a_blocked_task_cannot_launch(
    store, task_id, repo, sha, snapshot
):
    second = register_more(store, repo, sha, snapshot, 1)[0]
    store.depend(task_id, [second])
    with pytest.raises(ValueError, match="cycle"):
        store.depend(second, [task_id])
    assert store.dependencies(second) == []
    assert await Workflow(store, Config(), RegisteredGitHub(store)).run(task_id) == []
    assert not store.runs(task_id)
    assert store.task(task_id)["state"] == State.WAITING_DEPENDENCY
    store.halt(task_id, State.HUMAN, "manual gate")
    await Workflow(store, Config(), RegisteredGitHub(store)).run(task_id)
    assert store.task(task_id)["state"] == State.HUMAN


async def test_parallel_developers_write_distinct_worktrees_and_leave_source_unchanged(
    store, task_id, repo, sha, snapshot, auth_file, monkeypatch
):
    second = register_more(store, repo, sha, snapshot, 1)[0]
    for tid in (task_id, second):
        analysis_ready(store, tid, sha)
    worker = SUCCESS.replace("'changed in worktree\\n'", "str(request['context']['task_id'])")
    install_worker(monkeypatch, worker)
    at_publish = []
    release = asyncio.Event()

    async def publish(self, task, run):
        at_publish.append((task["id"], Path(run["worktree"])))
        await release.wait()
        raise OSError("Fixture stops before remote writes")

    monkeypatch.setattr(Controlled, "publish", publish)
    config = Config(auth_file=auth_file, checks=[["true"]], ci_workflows=["ci.yml"])
    scheduler = Scheduler(store, config, RegisteredGitHub(store), 2)
    running = asyncio.create_task(scheduler.serve(once=True))
    try:
        await wait_for(lambda: len(at_publish) == 2)
        assert store.db.execute("SELECT count(*) FROM leases").fetchone()[0] == 2
        assert len({p for _, p in at_publish}) == 2
        for tid, path in at_publish:
            assert (path / "sample.txt").read_text() == str(tid)
        assert (repo / "sample.txt").read_text() == "original\n"
    finally:
        release.set()
        await running


async def test_scheduler_stops_after_three_failures_and_manual_retry_preserves_history(
    store, task_id, auth_file, monkeypatch
):
    install_worker(monkeypatch, "import sys;sys.stdin.readline();raise SystemExit(7)")
    github = RegisteredGitHub(store)
    scheduler = Scheduler(store, Config(auth_file=auth_file), github)
    for _ in range(3):
        await scheduler.serve(once=True)
        with store.db:
            store.db.execute("UPDATE retries SET next_at=0")
    assert len(store.runs(task_id)) == 3
    assert store.task(task_id)["state"] == State.HUMAN
    await scheduler.serve(once=True)
    assert len(store.runs(task_id)) == 3
    assert "no_progress_after_bounded_attempts" in diagnose(store, task_id)["issues"]
    assert (await Recovery(store, github).retry(task_id))["recovered"]
    assert store.task(task_id)["state"] == State.QUEUED
    assert len(store.runs(task_id)) == 3
    assert not any(r["evidence_valid"] for r in store.runs(task_id))


async def test_logs_filter_a_selected_run_without_exposing_other_runs(store, task_id, sha, capsys):
    from gongcao.events import Journal, Redactor

    analysis_ready(store, task_id, sha)
    run = store.runs(task_id)[0]["id"]
    journal = Journal(store, run, 2048, Redactor())
    journal.emit("progress", {"message": "ignored"})
    journal.emit("error", {"message": "key github_pat_PRIVATEvalue"})
    await logs(store, task_id, False, run_id=run, kind="error", contains="REDACTED")
    output = capsys.readouterr().out
    assert "PRIVATEvalue" not in output and "ignored" not in output
    assert json.loads(output)["kind"] == "error"
    with pytest.raises(ValueError, match="belong"):
        await logs(store, task_id, False, run_id="../outside")


def test_schema_one_upgrade_keeps_unknown_intents_and_history(store, task_id, sha):
    analysis_ready(store, task_id, sha)
    store.intent(store.task(task_id), "pending", "push", "{}")
    with store.db:
        store.db.execute("DROP TRIGGER status_dirty")
        store.db.execute("DROP TABLE claims")
        store.db.execute("DROP TABLE controller")
        for table in ("leases", "processes", "dependencies", "retries", "instructions"):
            store.db.execute(f"DROP TABLE {table}")
        store.db.execute("DROP INDEX events_run_kind")
        store.db.execute("ALTER TABLE runs DROP COLUMN owner_token")
        store.db.execute("ALTER TABLE tasks DROP COLUMN control")
        store.db.execute("PRAGMA user_version=1")
    for _ in range(2):
        restarted = Store(store.root)
        try:
            assert restarted.db.execute("PRAGMA user_version").fetchone()[0] == 4
            assert len(restarted.runs(task_id)) == 1
            assert restarted.operation("pending")["state"] == "pending"
            assert restarted.runs(task_id)[0]["owner_token"] is None
        finally:
            restarted.close()


@pytest.mark.parametrize("role", [Role.REVIEWER, Role.VALIDATOR])
async def test_recovery_cannot_revive_legacy_ready_evidence_for_the_wrong_sha(
    store, task_id, sha, role
):
    analysis_ready(store, task_id, sha)
    run = store.runs(task_id)[0]["id"]
    bad = AgentResult(
        conclusion="ready",
        summary="Wrong version",
        basis=["old target"],
        target_sha="0" * 40,
        next_steps=["Must not advance"],
    )
    with store.db:
        store.db.execute(
            "UPDATE runs SET role=?,result=?,evidence_valid=1 WHERE id=?",
            (role, bad.model_dump_json(), run),
        )
        store.db.execute(
            "UPDATE tasks SET stage=?,state=? WHERE id=?",
            (Stage.REVIEW if role == Role.REVIEWER else Stage.VALIDATION, State.RECONCILE, task_id),
        )
    workflow = Workflow(store, Config(), RegisteredGitHub(store))
    assert workflow.cached_run(store.task(task_id), role) is None
    assert (await Recovery(store, RegisteredGitHub(store)).recover(task_id))["recovered"]
    assert not store.runs(task_id)[0]["evidence_valid"]
    assert workflow.cached_run(store.task(task_id), role) is None
    assert (await Recovery(store, RegisteredGitHub(store)).retry(task_id))["recovered"]
    assert not store.runs(task_id)[0]["evidence_valid"]


async def test_unsettled_process_retains_the_branch_resource_across_task_aliases(
    store, task_id, repo, sha, snapshot
):
    second = register_more(store, repo, sha, snapshot, 1)[0]
    with store.db:
        store.db.execute(
            "UPDATE tasks SET pr_number=9,snapshot=?",
            (json.dumps(snapshot | {"head_ref": "feature", "head_repository": "Example/Demo"}),),
        )
    process = None
    try:
        async with Lease(store, task_id):
            process = await launch(sys.executable, "-c", "import time;time.sleep(60)")
        assert store.db.execute("SELECT expires FROM leases").fetchone()[0] == 0
        async with Lease(store, second) as blocked:
            assert not blocked.acquired
        assert "occupied" in store.task(second)["reason"]
        assert process.returncode is None
    finally:
        if process is not None:
            await stop(process)


async def test_unconfirmed_new_pr_reserves_its_branch_before_local_association(
    store, task_id, repo, sha, snapshot
):
    from gongcao.leases import resource

    branch = resource(store.task(task_id)).split(":branch:", 1)[1]
    pull = snapshot | {
        "url": "https://github.com/EXAMPLE/DEMO/pull/9",
        "kind": "pull",
        "number": 9,
        "repository": "EXAMPLE/DEMO",
        "head_repository": "EXAMPLE/DEMO",
        "head_ref": branch,
    }
    second = store.register(pull["url"], repo, sha, pull)
    async with Lease(store, task_id):
        store.intent(store.task(task_id), "pending-pr", "pull", "{}")
        store.halt(task_id, State.RECONCILE, "API result unconfirmed")
    async with Lease(store, second) as blocked:
        assert not blocked.acquired
    assert store.db.execute("SELECT task_id FROM leases").fetchone()[0] == task_id


def test_registration_canonicalizes_github_case_aliases(store, task_id, repo, sha, snapshot):
    from gongcao.github import Target

    alias = snapshot["url"].replace("example/demo", "Example/Demo")
    assert Target.parse(alias).url == snapshot["url"]
    assert store.register(alias, repo, sha, snapshot) == task_id
    assert len(store.tasks()) == 1


ESCAPED = """
import subprocess,sys
from pathlib import Path
child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(60)'],start_new_session=True)
Path(sys.argv[1]).write_text(str(child.pid))
"""


async def test_setsided_descendant_cannot_be_cleared_by_recovery(store, task_id, tmp_path):
    path = tmp_path / "escaped-pid"
    child_pid = None
    child_identity = None
    process = None
    try:
        async with Lease(store, task_id):
            process = await launch(sys.executable, "-c", ESCAPED, str(path))
            await wait_for(path.exists)
            child_pid = int(path.read_text())
            child_identity = identity(child_pid)
            with pytest.raises(CleanupError):
                await stop(process)
            store.halt(task_id, State.RECONCILE, "Descendant exit could not be confirmed")
        assert not session_alive(process.pid)
        assert identity(child_pid) == child_identity
        assert store.db.execute("SELECT state FROM processes").fetchone()[0] == "uncertain"
        result = await Recovery(store, RegisteredGitHub(store)).recover(task_id)
        assert not result["recovered"] and "same-boot" in result["reason"]
        assert identity(child_pid) == child_identity
        assert store.task(task_id)["state"] == State.RECONCILE
    finally:
        if child_pid and child_identity and identity(child_pid) == child_identity:
            os.kill(child_pid, signal.SIGKILL)
        if process is not None:
            await stop(process)


async def test_occupied_capacity_does_not_spend_retry_budget(store, task_id, repo, sha, snapshot):
    ids = register_more(store, repo, sha, snapshot, 3)
    store.halt(task_id, State.WAITING_ENVIRONMENT, "one actual failure")
    with store.db:
        store.db.execute("INSERT INTO retries VALUES(?,?,?,?)", (task_id, 1, "old", 0))
    scheduler = Scheduler(store, Config(), RegisteredGitHub(store))
    async with contextlib.AsyncExitStack() as stack:
        for tid in ids:
            assert (await stack.enter_async_context(Lease(store, tid))).acquired
        for _ in range(3):
            await scheduler.advance(task_id)
        assert (
            store.db.execute("SELECT failures FROM retries WHERE task_id=?", (task_id,)).fetchone()[
                0
            ]
            == 1
        )
        assert not store.runs(task_id)
        assert store.task(task_id)["state"] == State.WAITING_DEPENDENCY


async def test_manual_retry_runs_failed_quality_checks_again(store, task_id):
    config = Config(checks=[["{python}", "-c", "assert 1+1==2"]])
    store.record(store.task(task_id), "checks", config.policy_hash, {"passed": False})
    store.record(store.task(task_id), "real", config.policy_hash, {"passed": False})
    store.halt(task_id, State.HUMAN, "Environment fixed by operator")
    assert (await Recovery(store, RegisteredGitHub(store)).retry(task_id))["recovered"]
    assert store.artifact(task_id, "real", config.policy_hash) is None
    async with Lease(store, task_id):
        result = await Quality(store, config).run(store.task(task_id), "checks")
    assert result["passed"] and result["commands"][0]["exit_code"] == 0


async def test_service_shutdown_leaves_interrupted_work_recoverable(
    store, task_id, auth_file, monkeypatch
):
    install_worker(
        monkeypatch,
        "import json,sys,time;sys.stdin.readline();"
        "print(json.dumps({'kind':'thread','data':{'thread_id':'silent-live'}}),flush=True);"
        "time.sleep(60)",
    )
    scheduler = Scheduler(store, Config(auth_file=auth_file), RegisteredGitHub(store))
    serving = asyncio.create_task(scheduler.serve(once=True))
    await wait_for(lambda: any(r["thread_id"] == "silent-live" for r in store.runs(task_id)))
    assert "no_progress_after_bounded_attempts" not in diagnose(store, task_id)["issues"]
    serving.cancel()
    with pytest.raises(asyncio.CancelledError):
        await serving
    task = store.task(task_id)
    assert task["state"] == State.RECONCILE and not task["cancel_requested"]
    assert not store.runs(task_id)[-1]["evidence_valid"]
    assert (await Recovery(store, RegisteredGitHub(store)).recover(task_id))["recovered"]
    assert store.task(task_id)["state"] == State.QUEUED


async def test_manual_baseline_refresh_replans_an_unpublished_issue(store, task_id, repo, sha):
    analysis_ready(store, task_id, sha)
    (repo / "new.txt").write_text("dependency merged")
    await git_command("git", "add", "new.txt", cwd=str(repo))
    await git_command("git", "commit", "-qm", "dependency", cwd=str(repo))
    new = (await git_command("git", "rev-parse", "HEAD", cwd=str(repo))).strip()
    github = RegisteredGitHub(store)

    async def read(path):
        return {"object": {"sha": new}} if "/git/ref/" in path else {"default_branch": "main"}

    github.read = read
    result = await Recovery(store, github).retry(task_id, refresh_base=True)
    assert result["recovered"]
    task = store.task(task_id)
    assert task["stage"] == Stage.ANALYSIS and task["target_sha"] == new
    assert not store.runs(task_id)[0]["evidence_valid"]
    assert (await git_command("git", "status", "--porcelain", cwd=str(repo))).strip() == ""


async def test_completed_wrong_sha_validator_cannot_pass_after_recovery(
    store, task_id, fixture_github, policy, monkeypatch
):
    wrong = WORKER.replace(
        "'target_sha':data['target_sha']",
        "'target_sha':('0'*40 if role=='validator' else data['target_sha'])",
    )
    assert wrong != WORKER
    install_worker(monkeypatch, wrong)
    await Workflow(store, policy, fixture_github).run(task_id)
    assert store.task(task_id)["state"] == State.RECONCILE
    old = store.runs(task_id)[-1]
    assert old["role"] == "validator" and json.loads(old["result"])["target_sha"] == "0" * 40

    async def route(*args, **kwargs):
        if args[:2] == ("git", "fetch"):
            args = (*args[:2], str(fixture_github.bare), *args[3:])
        return await git_command(*args, **kwargs)

    monkeypatch.setattr("gongcao.recovery.command", route)
    assert (await Recovery(store, fixture_github).recover(task_id))["recovered"]
    assert not next(r for r in store.runs(task_id) if r["id"] == old["id"])["evidence_valid"]
    install_worker(monkeypatch, WORKER)
    await Workflow(store, policy, fixture_github).run(task_id)
    assert store.task(task_id)["stage"] == Stage.MERGEABLE
    assert store.runs(task_id)[-1]["thread_id"] != old["thread_id"]


async def test_successful_pr_creation_lost_before_local_commit_is_reconciled_without_replay(
    store, task_id, fixture_github, policy, monkeypatch
):
    class Crash(BaseException):
        pass

    original_pages = fixture_github.pages

    async def pages(path, field=None):
        rows = await original_pages(path, field)
        if "/pulls?" in path:
            rows = [row | {"title": fixture_github.pull["title"]} for row in rows]
        return rows

    monkeypatch.setattr(fixture_github, "pages", pages)
    saved = store.operation_result

    def interrupt(key, state, response):
        if state == "succeeded" and store.operation(key)["kind"] == "pull":
            raise Crash()
        saved(key, state, response)

    monkeypatch.setattr(store, "operation_result", interrupt)
    with pytest.raises(Crash):
        await Workflow(store, policy, fixture_github).run(task_id)
    assert fixture_github.pull and store.task(task_id)["pr_number"] is None
    assert [o["state"] for o in store.evidence(task_id)["operations"]] == ["succeeded", "pending"]
    monkeypatch.setattr(store, "operation_result", saved)

    async def route(*args, **kwargs):
        if args[:2] == ("git", "fetch"):
            args = (*args[:2], str(fixture_github.bare), *args[3:])
        return await git_command(*args, **kwargs)

    monkeypatch.setattr("gongcao.recovery.command", route)
    writes = len(fixture_github.writes)
    assert (await Recovery(store, fixture_github).recover(task_id))["recovered"]
    assert store.task(task_id)["pr_number"] == 9
    assert store.task(task_id)["stage"] == Stage.ANALYSIS
    assert all(o["state"] == "succeeded" for o in store.evidence(task_id)["operations"])
    assert (await Recovery(store, fixture_github).recover(task_id))["recovered"]
    assert len(fixture_github.writes) == writes
