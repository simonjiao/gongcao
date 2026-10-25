"""Explicit registration, read-only synchronization and foreground task execution."""

import argparse
import asyncio
import json
import os
import signal
import sys
from pathlib import Path
from typing import Any

from .config import Config
from .github import GitHub, Target, command
from .model import State
from .recovery import Recovery, diagnose
from .scheduler import Scheduler
from .store import Store
from .workflow import Workflow
from .workspace import repository


def output(value: Any) -> None:
    print(json.dumps(value, ensure_ascii=False, indent=2), flush=True)


async def logs(
    store: Store,
    task_id: int,
    follow: bool,
    *,
    run_id: str | None = None,
    kind: str | None = None,
    contains: str | None = None,
) -> None:
    runs = store.runs(task_id)
    if not runs:
        output({"task_id": task_id, "message": "No runs recorded"})
        return
    if run_id is not None and run_id not in {r["id"] for r in runs}:
        raise ValueError("Run does not belong to this task")
    run_id = run_id or runs[-1]["id"]
    path = store.root / "logs" / f"{run_id}.jsonl"
    seen: tuple[int, int] | None = None
    stream = None

    def emit(line: str) -> None:
        if (kind is None or json.loads(line)["kind"] == kind) and (
            contains is None or contains in line
        ):
            print(line, end="", flush=True)

    try:
        # Replay the retained rotated file, then tail the latest file, tracking inode changes.
        rotated = path.with_suffix(".jsonl.1")
        if rotated.exists():
            for line in rotated.read_text().splitlines(keepends=True):
                emit(line)
        while True:
            if path.exists():
                stat = path.stat()
                identity = stat.st_dev, stat.st_ino
                if seen != identity:
                    if stream:
                        stream.close()
                    stream = path.open()
                    seen = identity
                assert stream is not None
                while True:
                    position = stream.tell()
                    line = stream.readline()
                    if not line:
                        break
                    if not line.endswith("\n"):
                        stream.seek(position)
                        break
                    emit(line)
            active = any(
                r["id"] == run_id and r["state"] == State.RUNNING for r in store.runs(task_id)
            )
            if not follow or not active:
                return
            await asyncio.sleep(0.2)
    finally:
        if stream:
            stream.close()


async def execute(args: argparse.Namespace, store: Store) -> int:
    github = GitHub()
    if args.command == "register":
        target = Target.parse(args.url)
        repo, sha = await repository(args.repo, target)
        snapshot = await github.snapshot(target)
        if snapshot.get("head_sha"):
            sha = snapshot["head_sha"]
            # Explicit PR registration fetches this one head, never discovers other tasks.
            await command("git", "fetch", "origin", sha, cwd=str(repo))
        task_id = store.register(target.url, repo, sha, snapshot)
        output(store.task(task_id))
    elif args.command == "sync":
        selected = [store.task(args.task)] if args.task else store.tasks()
        for task in selected:
            snapshot = await github.task_snapshot(task)
            if snapshot.get("head_sha") != task["snapshot"].get("head_sha"):
                await command("git", "fetch", "origin", snapshot["head_sha"], cwd=task["repo_path"])
            store.sync(task["id"], snapshot)
        output(store.tasks() if args.task is None else store.task(args.task))
    elif args.command == "status":
        tasks = [store.task(args.task)] if args.task else store.tasks()
        output(
            [
                {
                    key: task[key]
                    for key in (
                        "id",
                        "url",
                        "stage",
                        "state",
                        "target_sha",
                        "reason",
                        "cancel_requested",
                    )
                }
                | {
                    "dependencies": store.dependencies(task["id"]),
                    "runtime": diagnose(store, task["id"]),
                }
                for task in tasks
            ]
        )
    elif args.command == "inspect":
        task = store.task(args.task)
        task["runs"] = store.runs(args.task)
        task["evidence"] = store.evidence(args.task)
        task["runtime"] = diagnose(store, args.task)
        output(task)
    elif args.command == "cancel":
        store.cancel(args.task)
        output(store.task(args.task))
    elif args.command == "logs":
        store.task(args.task)
        await logs(
            store,
            args.task,
            args.follow,
            run_id=args.run_id,
            kind=args.kind,
            contains=args.contains,
        )
    elif args.command == "depend":
        store.depend(args.task, args.on, clear=args.clear)
        output(store.dependencies(args.task))
    elif args.command == "diagnose":
        output(diagnose(store, args.task))
    elif args.command in {"recover", "retry"}:
        recovery = Recovery(store, github)
        result = (
            await recovery.retry(
                args.task, reset_revisions=args.reset_revisions, refresh_base=args.refresh_base
            )
            if args.command == "retry"
            else await recovery.recover(args.task)
        )
        output(result)
        return 0 if result["recovered"] else 1
    elif args.command in {"run", "serve"}:
        current = asyncio.current_task()
        assert current is not None
        loop = asyncio.get_running_loop()
        loop.add_signal_handler(signal.SIGTERM, current.cancel)
        try:
            if args.command == "serve":
                config = Config.load(args.config)
                jobs = args.jobs if args.jobs is not None else config.scheduler_jobs
                await Scheduler(store, config, github, jobs).serve(once=args.once, poll=args.poll)
                output(store.tasks())
                return 0
            run_ids = await Workflow(store, Config.load(args.config), github).run(args.task)
        except asyncio.CancelledError:
            output(store.tasks())
            return 130
        finally:
            loop.remove_signal_handler(signal.SIGTERM)
        task = store.task(args.task)
        output({"run_ids": run_ids, "task": task})
        return (
            0 if task["state"] in {State.QUEUED, State.WAITING_DEPENDENCY, State.COMPLETED} else 1
        )
    return 0


def parser() -> argparse.ArgumentParser:
    cli = argparse.ArgumentParser(prog="gongcao")
    cli.add_argument(
        "--state-dir",
        type=Path,
        default=Path(
            os.environ.get("GONGCAO_STATE_DIR", str(Path.home() / ".local/state/gongcao"))
        ),
    )
    commands = cli.add_subparsers(dest="command", required=True)
    register = commands.add_parser("register", help="Register exactly one GitHub Issue/PR")
    register.add_argument("url")
    register.add_argument("--repo", type=Path, default=Path.cwd())
    serve = commands.add_parser("serve", help="Poll registered tasks with bounded concurrency")
    serve.add_argument("--config", type=Path)
    serve.add_argument("--jobs", type=int, choices=(1, 2, 3), help="Parallel tasks (YAML or 1)")
    serve.add_argument("--poll", type=float, default=5.0)
    serve.add_argument("--once", action="store_true")
    for name in (
        "sync",
        "status",
        "inspect",
        "cancel",
        "logs",
        "run",
        "recover",
        "retry",
        "depend",
        "diagnose",
    ):
        sub = commands.add_parser(name)
        sub.add_argument("task", type=int, nargs="?" if name in {"sync", "status"} else None)
        if name == "logs":
            sub.add_argument("--follow", action="store_true")
            sub.add_argument("--run", dest="run_id")
            sub.add_argument("--kind")
            sub.add_argument("--contains")
        if name == "depend":
            sub.add_argument("--on", type=int, action="append", default=[])
            sub.add_argument("--clear", action="store_true")
        if name == "retry":
            sub.add_argument("--reset-revisions", action="store_true")
            sub.add_argument("--refresh-base", action="store_true")
        if name == "run":
            sub.add_argument("--config", type=Path)
    return cli


def main() -> None:
    args = parser().parse_args()
    store = Store(args.state_dir)
    try:
        code = asyncio.run(execute(args, store))
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"gongcao: {exc}", file=sys.stderr)
        code = 1
    except KeyboardInterrupt:
        code = 130
    finally:
        store.close()
    raise SystemExit(code)


if __name__ == "__main__":
    main()
