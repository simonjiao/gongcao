"""Explicit, read-only GitHub clone acceptance in a fresh private directory."""

import argparse
import asyncio
import json
import sys
from pathlib import Path
from typing import Any

from gongcao.config import DiscoveryConfig
from gongcao.github import GitHub, command

from .evidence import require


async def exercise(directory: Path, repos: list[str]) -> dict[str, Any]:
    directory.mkdir(parents=True, exist_ok=False, mode=0o700)
    discovery_config = DiscoveryConfig.load(
        {
            "enabled": True,
            "repo_root": str(directory / "repos"),
            "sources": [{"repo": repo} for repo in repos],
        }
    )
    # Prepare only: do not discover/claim Issues, start Agents, or write to GitHub.
    import fcntl

    from gongcao.discovery import lock_path
    from gongcao.workspace import prepare_repository

    actor = (await GitHub().read("user"))["login"]
    rows = []
    for source in discovery_config.sources:
        with lock_path(source.repo).open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = await prepare_repository(source)
            head = (await command("git", "rev-parse", "HEAD", cwd=str(source.path))).strip()
            (source.path / ".qa-local-preserved").write_text("isolated clone probe\n")
            before = await command("git", "status", "--porcelain", cwd=str(source.path))
            reused = (
                await command(
                    sys.executable,
                    "-c",
                    "import asyncio,sys; from pathlib import Path; "
                    "from gongcao.config import Source; "
                    "from gongcao.workspace import prepare_repository; "
                    "print(asyncio.run(prepare_repository(Source(sys.argv[1],Path(sys.argv[2])))))",
                    source.repo,
                    str(source.path),
                )
            ).strip()
            require(result == "已克隆" and reused == "已复用", "Clone/reuse not confirmed")
            require(
                (await command("git", "rev-parse", "HEAD", cwd=str(source.path))).strip() == head,
                "HEAD changed",
            )
            require(
                await command("git", "status", "--porcelain", cwd=str(source.path)) == before,
                "Worktree changed",
            )
            rows.append(
                {
                    "repository": source.repo,
                    "head": head,
                    "clone": result,
                    "restart": reused,
                    "fresh_process_reuse": True,
                    "preserved_dirty_worktree": True,
                }
            )
    proof = {
        "implementation_sha": (
            await command("git", "rev-parse", "HEAD", cwd=str(Path(__file__).resolve().parents[1]))
        ).strip(),
        "actor": actor,
        "repositories": rows,
        "real": True,
        "remote_writes": [],
        "passed": True,
    }
    (directory / "evidence.json").write_text(json.dumps(proof, ensure_ascii=False, indent=2) + "\n")
    return proof


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--real", action="store_true", required=True)
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument("--repo", action="append", required=True)
    args = parser.parse_args()
    print(
        json.dumps(
            asyncio.run(exercise(args.directory.resolve(), args.repo)), ensure_ascii=False, indent=2
        )
    )


if __name__ == "__main__":
    main()
