"""Explicit offline checks, authorized real batches, evidence verification and cleanup."""

import argparse
import asyncio
import json
import re
from pathlib import Path
from typing import Any

from gongcao.config import Config
from gongcao.github import GitHub

from .environment import check
from .evidence import verify_archived, verify_batch, verify_live
from .ledger import Run
from .resources import cleanup, reconcile
from .runner import batch, core, inspect
from .scenarios import SCENARIOS


def parser() -> argparse.ArgumentParser:
    cli = argparse.ArgumentParser(prog="python -m qa")
    cli.add_argument("--data-dir", type=Path, default=Path(".qa-runs"))
    commands = cli.add_subparsers(dest="command", required=True)
    environment = commands.add_parser("check")
    environment.add_argument("--real", action="store_true")
    environment.add_argument("--offline", action="store_true")
    environment.add_argument("--repo")
    run = commands.add_parser("run")
    run.add_argument("scenarios", nargs="+", choices=SCENARIOS)
    run.add_argument("--repeat", type=int, default=1)
    run.add_argument("--jobs", type=int, default=2)
    run.add_argument("--real", action="store_true")
    run.add_argument("--repo")
    run.add_argument("--model")
    run.add_argument("--cleanup", action="store_true")
    for name in ("verify", "verify-batch", "cleanup", "cancel", "reconcile"):
        sub = commands.add_parser(name)
        sub.add_argument("run_id")
        if name == "verify":
            sub.add_argument("--real", action="store_true")
        if name == "verify-batch":
            sub.add_argument("--require-isolation", action="store_true")
    return cli


async def execute(args: argparse.Namespace) -> dict[str, Any]:
    if getattr(args, "repo", None) and not re.fullmatch(r"[\w.-]+/[\w.-]+", args.repo):
        raise ValueError("--repo must be OWNER/REPO")
    if args.command == "check":
        if args.real and args.offline:
            raise ValueError("Choose --real or --offline")
        return await check(real=args.real, repository=args.repo)
    if args.command == "run":
        if args.repeat < 1:
            raise ValueError("--repeat must be positive")
        return await batch(
            args.data_dir,
            args.scenarios * args.repeat,
            jobs=args.jobs,
            real=args.real,
            repository=args.repo.lower() if args.repo else None,
            model=args.model,
            clean=args.cleanup,
        )
    run = Run(args.data_dir, args.run_id)
    if args.command == "verify-batch":
        return verify_batch(args.data_dir, args.run_id, require_isolation=args.require_isolation)
    if args.command == "cancel":
        (run.root / "cancel-requested").touch(mode=0o600)
        return {"run_id": run.id, "cancel_requested": True}
    with run.lock():
        if args.command == "verify":
            archived = verify_archived(run)
            if args.real:
                if run.value.get("cleaned"):
                    raise ValueError("Resources were cleaned; use archived verification")
                archived["live"] = await verify_live(
                    run, inspect(run), Config.load(run.root / "config.yaml"), GitHub()
                )
            return archived
        if args.command == "reconcile":
            await reconcile(run, GitHub())
            if run.value.get("task_id"):
                if await core(run, "recover", str(run.value["task_id"])):
                    raise ValueError("Production recovery is blocked; inspect its command log")
            return {"run_id": run.id, "reconciled": True}
        await cleanup(run, inspect(run) if run.value.get("task_id") else None, GitHub())
        return {"run_id": run.id, "cleaned": run.value.get("cleaned", False)}


def main() -> None:
    args = parser().parse_args()
    try:
        result = asyncio.run(execute(args))
        print(json.dumps(result, indent=2, ensure_ascii=False))
        code = 1 if result.get("passed") is False else 0
    except (OSError, RuntimeError, ValueError) as exc:
        print(json.dumps({"passed": False, "failure": str(exc)}))
        code = 1
    except KeyboardInterrupt:
        code = 130
    raise SystemExit(code)


if __name__ == "__main__":
    main()
