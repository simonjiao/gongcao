"""Independent per-Run processes with a single-process, bounded batch queue."""

import asyncio
import json
import os
import sys
import time
import uuid
from pathlib import Path
from typing import Any

import yaml

from gongcao.config import Config
from gongcao.events import Redactor
from gongcao.github import GitHub, command
from gongcao.processes import stop
from gongcao.recovery import diagnose
from gongcao.store import Store

from .environment import check
from .evidence import require, verify_live
from .ledger import Run, digest, write_json
from .resources import cleanup, create_issue, settled
from .scenarios import VERSION, fixture, version_digest


def inspect(run: Run) -> dict[str, Any]:
    store = Store(run.root / "state")
    try:
        task = store.task(run.value["task_id"])
        return task | {
            "runs": store.runs(task["id"]),
            "evidence": store.evidence(task["id"]),
            "runtime": diagnose(store, task["id"]),
        }
    finally:
        store.close()


async def core(run: Run, *args: str, fault: bool = False) -> int:
    name = uuid.uuid4().hex
    argv = [
        sys.executable,
        "-m",
        "qa.fault" if fault else "gongcao",
        "--state-dir",
        str(run.root / "state"),
        *args,
    ]
    env = os.environ.copy()
    if fault:
        env.update(GONGCAO_QA_DATA=str(run.root.parent.parent), GONGCAO_QA_RUN=run.id)
    process = await asyncio.create_subprocess_exec(
        *argv,
        env=env,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        start_new_session=True,
    )
    started = time.time()
    try:
        stdout, stderr = await asyncio.wait_for(process.communicate(), 1800)
    finally:
        await stop(process)
    write_json(
        run.root / f"command-{name}.json",
        {
            "argv": argv,
            "started": started,
            "ended": time.time(),
            "exit_code": process.returncode,
            "stdout": Redactor().text(stdout.decode(errors="replace")),
            "stderr": Redactor().text(stderr.decode(errors="replace")),
        },
    )
    return int(process.returncode or 0)


def signature(task: dict[str, Any]) -> dict[str, Any]:
    return {
        "runs": [r["id"] for r in task["runs"]],
        "operations": [
            (o["id"], o["state"], o["response"]) for o in task["evidence"]["operations"]
        ],
    }


def model_activity(run: Run) -> bool:
    for path in (run.root / "state/logs").glob("*.jsonl*"):
        try:
            contents = path.read_text()
        except FileNotFoundError:
            continue  # Concurrent rotation; the next poll sees the retained file.
        for line in contents.splitlines(keepends=True):
            if not line.endswith("\n"):
                continue
            event = json.loads(line)
            if event["kind"] == "sdk_event":
                data = event["data"]
                if (
                    data["method"] == "item/started"
                    and data.get("payload", {}).get("item", {}).get("type") == "commandExecution"
                ):
                    return True
    return False


async def drive(
    run: Run, *, fault: bool = False, cancel_probe: bool = False, peers: list[Run] | None = None
) -> int:
    task_id = str(run.value["task_id"])
    pending = asyncio.create_task(
        core(run, "run", task_id, "--config", str(run.root / "config.yaml"), fault=fault)
    )
    last = None
    cancelled = False
    try:
        while not pending.done():
            task = inspect(run)
            state = (task["stage"], task["state"], task["target_sha"])
            if state != last:
                run.event("controller-state", stage=state[0], state=state[1], target_sha=state[2])
                last = state
            peer_active = not peers or any(
                peer.value.get("task_id")
                and inspect(peer)["state"] == "running"
                and model_activity(peer)
                for peer in peers
            )
            if not cancelled and (
                (run.root / "cancel-requested").exists()
                or (cancel_probe and model_activity(run) and peer_active)
            ):
                require(await core(run, "cancel", task_id) == 0, "Native cancel failed")
                run.event("cancel-requested", real_model_command_seen=model_activity(run))
                cancelled = True
            await asyncio.wait({pending}, timeout=0.5)
        return pending.result()
    finally:
        if not pending.done():
            pending.cancel()
        await asyncio.gather(pending, return_exceptions=True)


async def prepare(run: Run, github: GitHub, model: str | None) -> None:
    requirement, config = fixture(run.id, model)
    config_path = run.root / "config.yaml"
    config_path.write_text(yaml.safe_dump(config, sort_keys=True))
    config_path.chmod(0o600)
    run.value["config_digest"] = digest(config)
    run.archive("configuration", config)
    metadata = await github.read(f"repos/{run.value['repository']}")
    branch = metadata["default_branch"]
    base = await github.read(f"repos/{run.value['repository']}/git/ref/heads/{branch}")
    run.value.update(base_branch=branch, base_sha=base["object"]["sha"])
    run.save()
    source = run.root / "source"
    await command(
        "git",
        "clone",
        "--quiet",
        "--single-branch",
        "--branch",
        branch,
        metadata["ssh_url"],
        str(source),
    )
    await command("git", "checkout", "--detach", run.value["base_sha"], cwd=str(source))
    for path in ("pyproject.toml", "uv.lock", ".github/workflows/ci.yml", "src/gongcao/cli.py"):
        require(
            (source / path).is_file(), "This fixture requires a Gongcao-compatible test repository"
        )
    issue = await create_issue(run, requirement, github)
    require(
        await core(run, "register", issue["url"], "--repo", str(source)) == 0, "Registration failed"
    )
    store = Store(run.root / "state")
    try:
        tasks = store.tasks()
        require(len(tasks) == 1 and tasks[0]["url"] == issue["url"], "Unexpected registration")
        run.value["task_id"] = tasks[0]["id"]
    finally:
        store.close()
    run.save()


async def missing_gate(run: Run) -> None:
    config = yaml.safe_load((run.root / "config.yaml").read_text())
    config["quality"] = {}
    path = run.root / "missing-gate.yaml"
    path.write_text(yaml.safe_dump(config))
    await core(run, "run", str(run.value["task_id"]), "--config", str(path))
    task = inspect(run)
    require(
        task["state"] == "waiting_environment"
        and not task["evidence"]["operations"]
        and not task["pr_number"],
        "Missing gate did not block remote writes",
    )
    before = signature(task)
    await core(run, "run", str(run.value["task_id"]), "--config", str(path))
    require(signature(inspect(run)) == before, "Blocked repeat created new effects")
    run.archive("missing-gate", task)
    run.event("missing-gate-blocked", repeat_unchanged=True)


async def execute(
    run: Run, *, model: str | None, clean: bool, peers: list[Run] | None = None
) -> None:
    with run.lock():
        run.value["status"] = "running"
        run.event("started")
        github = GitHub()
        try:
            if run.value["scenario"] == "smoke":
                run.archive("environment", await check())
                verdict: dict[str, Any] = {
                    "passed": True,
                    "at": time.time(),
                    "kind": "offline-capability-probe",
                }
            else:
                await prepare(run, github, model)
                if run.value["scenario"] != "cancel":
                    await missing_gate(run)
                injected = False
                deadline = time.monotonic() + 3600
                for _ in range(120):
                    require(time.monotonic() < deadline, "QA workflow deadline exceeded")
                    fault = run.value["scenario"] == "recover" and not injected
                    code = await drive(
                        run,
                        fault=fault,
                        cancel_probe=run.value["scenario"] == "cancel",
                        peers=peers,
                    )
                    task = inspect(run)
                    if fault and code == -9:
                        witness = json.loads((run.root / "fault.json").read_text())
                        op = next(
                            o
                            for o in task["evidence"]["operations"]
                            if o["id"] == witness["operation"]
                        )
                        require(
                            op["state"] == "pending",
                            "Fault missed the pre-acknowledgement checkpoint",
                        )
                        run.archive("interrupted", {"task": task, "witness": witness})
                        await core(
                            run, "serve", "--once", "--config", str(run.root / "config.yaml")
                        )
                        recovered = inspect(run)
                        confirmed = next(
                            o
                            for o in recovered["evidence"]["operations"]
                            if o["id"] == witness["operation"]
                        )
                        require(
                            confirmed["state"] == "succeeded"
                            and confirmed["response"] == witness["observed_response"],
                            "serve did not reconcile the actual COMMENT",
                        )
                        run.archive("recovered", recovered)
                        run.event("remote-write-recovered", operation=witness["operation"])
                        injected = True
                        task = recovered
                    if task["state"] == "cancelled":
                        require(
                            run.value["scenario"] == "cancel" and model_activity(run),
                            "Unexpected cancellation",
                        )
                        settled(task)
                        require(
                            not task["evidence"]["operations"],
                            "Cancellation probe reached a remote write",
                        )
                        verdict = {
                            "passed": True,
                            "at": time.time(),
                            "kind": "expected-real-model-cancellation",
                        }
                        break
                    if task["stage"] == "mergeable" and task["state"] == "completed":
                        if run.value["scenario"] == "recover":
                            require(injected, "Recovery checkpoint was not triggered")
                        config = Config.load(run.root / "config.yaml")
                        result = await verify_live(run, task, config, github)
                        before = signature(task)
                        reviews = result["review_ids"]
                        await core(
                            run,
                            "run",
                            str(run.value["task_id"]),
                            "--config",
                            str(run.root / "config.yaml"),
                        )
                        after = inspect(run)
                        require(
                            signature(after) == before,
                            "Completed repeat created new sessions or operations",
                        )
                        rows = await github.pages(
                            f"repos/{run.value['repository']}/pulls/{task['pr_number']}/reviews?per_page=100"
                        )
                        require(
                            [r["id"] for r in rows] == reviews, "Completed repeat added a review"
                        )
                        run.archive(
                            "repeat",
                            {
                                "before": before,
                                "after": signature(after),
                                "review_ids_before": reviews,
                                "review_ids_after": [r["id"] for r in rows],
                            },
                        )
                        verdict = {
                            "passed": True,
                            "at": time.time(),
                            "kind": "real-loop",
                            **result,
                            "repeat_unchanged": True,
                        }
                        break
                    require(
                        task["state"] in {"queued", "waiting_dependency"},
                        f"Workflow stopped: {task['state']}: {task['reason']}",
                    )
                    await asyncio.sleep(5)
                else:
                    raise ValueError("QA workflow exceeded bounded iterations")
                run.value["resources"]["pr_number"] = task["pr_number"]
                run.archive("task", inspect(run))
            run.archive("verdict", verdict)
            run.value["status"] = "passed"
        except (OSError, RuntimeError, ValueError, TimeoutError) as exc:
            run.value.update(
                status="failed", failure=Redactor().text(f"{type(exc).__name__}: {exc}")
            )
            if run.value.get("task_id"):
                run.archive("failed-task", inspect(run))
        finally:
            run.event("finished", status=run.value["status"])
        if clean and run.value["scenario"] != "smoke":
            try:
                await cleanup(run, inspect(run) if run.value.get("task_id") else None, github)
            except (OSError, RuntimeError, ValueError) as exc:
                run.value.update(status="failed", cleanup_failure=Redactor().text(str(exc)))
                run.save()


async def batch(
    data: Path,
    scenarios: list[str],
    *,
    jobs: int,
    real: bool,
    repository: str | None,
    model: str | None,
    clean: bool,
) -> dict[str, Any]:
    require(jobs >= 1, "--jobs must be positive")
    require(
        real or all(s == "smoke" for s in scenarios),
        "Real scenarios require explicit --real and --repo",
    )
    environment = await check(real=real, repository=repository)
    implementation_root = Path(__file__).resolve().parents[1]
    implementation = (
        await command("git", "rev-parse", "HEAD", cwd=str(implementation_root))
    ).strip()
    require(
        not (await command("git", "status", "--porcelain", cwd=str(implementation_root))).strip(),
        "Commit QA changes before recording a fixed implementation SHA",
    )
    data = data.resolve()
    data.mkdir(parents=True, exist_ok=True, mode=0o700)
    runs = [
        Run.create(
            data,
            scene,
            implementation,
            scenario_version=VERSION,
            scenario_digest=version_digest(),
            repository=repository,
            github_login=environment.get("github_login"),
            environment=environment,
        )
        for scene in scenarios
    ]
    semaphore = asyncio.Semaphore(jobs)
    batch_id = runs[0].id
    report: dict[str, Any] = {
        "schema": 1,
        "id": batch_id,
        "jobs": jobs,
        "runs": [r.id for r in runs],
        "events": [],
    }
    path = data / f"batch-{batch_id}.json"
    write_json(path, report)

    async def one(run: Run) -> None:
        async with semaphore:
            report["events"].append({"at": time.time(), "kind": "started", "run_id": run.id})
            write_json(path, report)
            try:
                await execute(
                    run,
                    model=model,
                    clean=clean,
                    peers=[other for other in runs if other is not run] if jobs > 1 else None,
                )
            finally:
                report["events"].append({"at": time.time(), "kind": "released", "run_id": run.id})
                write_json(path, report)

    # Exceptions are isolated; gather(return_exceptions) keeps siblings running.
    results = await asyncio.gather(*(one(run) for run in runs), return_exceptions=True)
    for run, result in zip(runs, results, strict=True):
        if isinstance(result, BaseException):
            run.value.update(status="interrupted", failure=Redactor().text(type(result).__name__))
            run.save()
    report["results"] = [
        {
            "run_id": r.id,
            "scenario": r.value["scenario"],
            "status": r.value["status"],
            "cleaned": r.value.get("cleaned", False),
            "failure": r.value.get("failure"),
            "cleanup_failure": r.value.get("cleanup_failure"),
        }
        for r in runs
    ]
    report["passed"] = all(r.value["status"] == "passed" for r in runs)
    write_json(path, report)
    return report
