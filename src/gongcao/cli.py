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
from .runner import Runner
from .store import Store
from .workspace import repository


def output(value: Any) -> None:
    print(json.dumps(value, ensure_ascii=False, indent=2), flush=True)


async def logs(store: Store, task_id: int, follow: bool) -> None:
    runs = store.runs(task_id)
    if not runs:
        output({"task_id": task_id, "message": "No runs recorded"})
        return
    run_id = runs[-1]["id"]
    path = store.root / "logs" / f"{run_id}.jsonl"
    seen: tuple[int, int] | None = None
    stream = None
    try:
        # Replay the retained rotated file, then tail the latest file, tracking inode changes.
        rotated = path.with_suffix(".jsonl.1")
        if rotated.exists():
            print(rotated.read_text(), end="", flush=True)
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
                for line in stream:
                    print(line, end="", flush=True)
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
            snapshot = await github.snapshot(Target.parse(task["url"]))
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
                for task in tasks
            ]
        )
    elif args.command == "inspect":
        task = store.task(args.task)
        task["runs"] = store.runs(args.task)
        output(task)
    elif args.command == "cancel":
        store.cancel(args.task)
        output(store.task(args.task))
    elif args.command == "logs":
        store.task(args.task)
        await logs(store, args.task, args.follow)
    elif args.command == "run":
        current = asyncio.current_task()
        assert current is not None
        loop = asyncio.get_running_loop()
        loop.add_signal_handler(signal.SIGTERM, current.cancel)
        try:
            run_id = await Runner(store, Config.load(args.config), github).run(args.task)
        finally:
            loop.remove_signal_handler(signal.SIGTERM)
        task = store.task(args.task)
        output({"run_id": run_id, "task": task})
        return 0 if task["state"] in {State.QUEUED, State.WAITING_DEPENDENCY} else 1
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
    for name in ("sync", "status", "inspect", "cancel", "logs", "run"):
        sub = commands.add_parser(name)
        sub.add_argument("task", type=int, nargs="?" if name in {"sync", "status"} else None)
        if name == "logs":
            sub.add_argument("--follow", action="store_true")
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
