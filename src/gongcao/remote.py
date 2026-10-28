"""Only this controller component holds authority to push or write GitHub objects."""

import asyncio
import hashlib
import json
import uuid
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import Any
from urllib.parse import urlencode

from .config import Config
from .control import Controls, InstructionChanged, Paused, baseline
from .events import Redactor
from .github import GitHub, Target, command
from .model import VERSION_FIELDS, Role, Stage
from .recovery import Recovery
from .sandbox import Sandbox
from .store import Store
from .workspace import repository, worktree


class UncertainWrite(RuntimeError):
    pass


class Controlled:
    def __init__(self, store: Store, config: Config, github: GitHub):
        self.store, self.config, self.github = store, config, github
        self.verified: set[str] = set()

    async def instruction_checkpoint(self, expected: dict[str, Any]) -> dict[str, Any]:
        controls = Controls(self.store)
        await controls.poll(expected["id"], self.config, self.github)
        if not controls.revalidate(expected["id"], self.config):
            raise Paused("Paused before the next controlled write")
        current = self.store.task(expected["id"])
        if baseline(current) != baseline(expected) or current["stage"] != expected["stage"]:
            raise InstructionChanged("New requirements must be evaluated before writing")
        return current

    async def before(
        self, expected: dict[str, Any], kind: str, *, finish_operation: bool = False
    ) -> dict[str, Any]:
        target = Target.parse(expected["url"])
        latest = await Recovery(self.store, self.github).sync(expected)
        if latest.get("head_sha", expected["target_sha"]) != expected["target_sha"] or any(
            latest.get(key) != expected["snapshot"].get(key) for key in VERSION_FIELDS
        ):
            raise UncertainWrite("Remote target changed before a controlled write")
        current = self.store.task(expected["id"])
        if not finish_operation:
            current = await self.instruction_checkpoint(expected)
        self.store.guard(current)
        if any(run["state"] == "running" for run in self.store.runs(current["id"])):
            raise ValueError("An active agent cannot authorize a remote mutation")
        allowed = {
            "archive": set(Stage) - {Stage.MERGED},
            "archive-link": set(Stage) - {Stage.MERGED},
            "push": {Stage.DEVELOPMENT, Stage.REVISION},
            "pull": {Stage.DEVELOPMENT, Stage.REVISION},
            "review": {Stage.REVIEW},
            "ready": {Stage.VALIDATION, Stage.MERGEABLE},
        }
        if current["stage"] not in allowed[kind] or latest["state"] != "open":
            raise ValueError("This stage does not authorize the requested GitHub mutation")
        repo, _ = await repository(Path(current["repo_path"]), target)
        if current["target_sha"] not in self.verified:
            key = "control-" + uuid.uuid4().hex
            workspace = self.store.root / "worktrees" / key
            await worktree(repo, workspace, current["target_sha"], Role.DEVELOPER, key)
            sandbox = Sandbox(workspace, self.store.root / "checks" / key, Role.DEVELOPER)
            sandbox.prepare(self.config, authentication=False)
            evidence = await sandbox.verify(repo)
            self.store.record(current, "write-isolation", "", evidence)
            self.verified.add(current["target_sha"])
        if not finish_operation:
            current = await self.instruction_checkpoint(expected)
        return self.store.guard(current)

    def identity(self, task: dict[str, Any], kind: str, object_id: str) -> str:
        return hashlib.sha256(
            f"{task['url']}:{kind}:{task['target_sha']}:{object_id}".encode()
        ).hexdigest()

    async def perform(
        self,
        task: dict[str, Any],
        kind: str,
        object_id: str,
        payload: dict[str, Any],
        observe: Callable[[], Awaitable[dict[str, Any] | None]],
        write: Callable[[], Awaitable[dict[str, Any]]],
    ) -> dict[str, Any]:
        task = await self.before(task, kind)
        key = self.identity(task, kind, object_id)
        created = self.store.intent(task, key, kind, json.dumps(payload, sort_keys=True))
        found = await observe()
        if found is not None:
            self.store.operation_result(key, "succeeded", found)
            return found
        if not created:
            raise UncertainWrite("Existing write intent is not confirmed remotely; refusing replay")
        await self.before(task, kind, finish_operation=True)
        try:
            await write()
        except BaseException as exc:
            self.store.operation_result(
                key, "unknown", {"error": Redactor().text(f"{type(exc).__name__}: {exc}")}
            )
            try:
                found = await observe()
            except Exception:
                found = None
            if found is None:
                if isinstance(exc, asyncio.CancelledError):
                    raise
                raise UncertainWrite(
                    f"Write result unconfirmed: {type(exc).__name__}: {exc}"
                ) from exc
            self.store.operation_result(key, "succeeded", found)
            current_task = asyncio.current_task()
            if current_task is not None and current_task.cancelling():
                raise asyncio.CancelledError from None
            return found
        found = await observe()
        if found is None:
            self.store.operation_result(key, "unknown", None)
            raise UncertainWrite("Write returned but remote state did not confirm its result")
        self.store.operation_result(key, "succeeded", found)
        return found

    async def publish(
        self, task: dict[str, Any], run: dict[str, Any]
    ) -> tuple[dict[str, Any], int]:
        valid = [
            row
            for row in self.store.runs(task["id"])
            if row["id"] == run["id"]
            and row["role"] == Role.DEVELOPER
            and row["state"] == "completed"
            and row["evidence_valid"]
            and row["target_sha"] == task["target_sha"]
        ]
        if not valid or json.loads(valid[0]["result"])["conclusion"] != "ready":
            raise ValueError("Publishing requires a confirmed developer result for this target")
        run = valid[0]
        task = await self.before(task, "push")
        snapshot = task["snapshot"]
        repo = Path(task["repo_path"])
        workspace = Path(run["worktree"]).resolve()
        if not workspace.is_relative_to(self.store.root / "worktrees"):
            raise ValueError("Development output is outside the allocated Worktree root")
        slug = hashlib.sha256(task["url"].encode()).hexdigest()[:12]
        branch = snapshot["head_ref"] if task["pr_number"] else f"gongcao/work-{slug}"
        if task["pr_number"]:
            if snapshot["head_repository"] != snapshot["repository"]:
                raise ValueError("Cross-repository PR pushes require manual handling")
            base_ref = snapshot["base_ref"]
        else:
            metadata = await self.github.read(f"repos/{snapshot['repository']}")
            base_ref = metadata["default_branch"]
            base = await self.github.read(
                f"repos/{snapshot['repository']}/git/ref/heads/{base_ref}"
            )
            if base["object"]["sha"] != task["target_sha"]:
                raise UncertainWrite("Issue baseline is no longer the remote default branch")
        marker = f"Gongcao-Run: {run['id']}"
        head = (await command("git", "rev-parse", "HEAD", cwd=str(workspace))).strip()
        if head == task["target_sha"]:
            await command(
                "git",
                "-c",
                "core.hooksPath=/dev/null",
                "add",
                "--all",
                "--",
                ".",
                cwd=str(workspace),
            )
            changed = await command("git", "diff", "--cached", "--name-only", cwd=str(workspace))
            if not changed.strip():
                raise ValueError("Developer produced no changes; no PR can be published")
            await command(
                "git",
                "-c",
                "core.hooksPath=/dev/null",
                "-c",
                "commit.gpgSign=false",
                "-c",
                "user.name=Gongcao",
                "-c",
                "user.email=gongcao@localhost",
                "commit",
                "-m",
                f"Implement registered task\n\n{marker}",
                cwd=str(workspace),
            )
            head = (await command("git", "rev-parse", "HEAD", cwd=str(workspace))).strip()
        else:
            parents = (
                await command("git", "show", "-s", "--format=%P%n%B", head, cwd=str(workspace))
            ).splitlines()
            if parents[0] != task["target_sha"] or marker not in parents:
                raise UncertainWrite("Worktree HEAD is not a confirmed controller commit")

        async def pushed() -> dict[str, Any] | None:
            rows = (
                await command("git", "ls-remote", "origin", f"refs/heads/{branch}", cwd=str(repo))
            ).split()
            if rows and rows[0] == head:
                return {"sha": head, "branch": branch}
            if rows and rows[0] != task["target_sha"]:
                raise UncertainWrite("Remote branch contains an unexpected commit")
            return None

        async def push() -> dict[str, Any]:
            await command("git", "push", "origin", f"{head}:refs/heads/{branch}", cwd=str(repo))
            return {"sha": head}

        await self.perform(task, "push", branch, {"sha": head, "branch": branch}, pushed, push)
        if task["pr_number"]:
            updated = await self.github.task_snapshot(task)
            if updated["head_sha"] != head or any(
                updated.get(key) != snapshot.get(key)
                for key in ("title", "body", "base_sha", "base_ref", "base_repository")
            ):
                raise UncertainWrite("Published PR head moved before confirmation")
            return updated, task["pr_number"]
        repository_name = snapshot["repository"]
        key = self.identity(task, "pull", branch)
        tag = f"<!-- gongcao:{key} -->"
        payload = {
            "head": branch,
            "base": base_ref,
            "draft": True,
            "title": snapshot["title"],
            "body": f"Implements {task['url']}\n\n{tag}",
        }

        async def existing() -> dict[str, Any] | None:
            query = urlencode(
                {
                    "state": "all",
                    "head": f"{repository_name.split('/')[0]}:{branch}",
                    "per_page": 100,
                }
            )
            pulls = await self.github.pages(f"repos/{repository_name}/pulls?{query}")
            if not pulls:
                return None
            if (
                len(pulls) != 1
                or tag not in (pulls[0].get("body") or "")
                or pulls[0]["state"] != "open"
            ):
                raise UncertainWrite("Existing PR cannot be matched safely to this task")
            if pulls[0]["head"]["sha"] != head or pulls[0]["base"]["ref"] != base_ref:
                raise UncertainWrite("Existing PR version differs from the publication intent")
            return {"number": pulls[0]["number"]}

        async def create() -> dict[str, Any]:
            if await pushed() is None:
                raise UncertainWrite("Remote branch moved before PR creation")
            return await self.github.mutate(f"repos/{repository_name}/pulls", payload)

        result = await self.perform(task, "pull", branch, payload, existing, create)
        temporary = task | {"pr_number": result["number"]}
        updated = await self.github.task_snapshot(temporary)
        if (
            updated["head_sha"] != head
            or updated["base_sha"] != task["target_sha"]
            or any(updated.get(key) != snapshot.get(key) for key in ("title", "body"))
        ):
            raise UncertainWrite("PR head moved before confirmation")
        return updated, result["number"]

    async def review(self, task: dict[str, Any], result: dict[str, Any], run_id: str) -> None:
        number = task["pr_number"]
        endpoint = f"repos/{task['snapshot']['repository']}/pulls/{number}/reviews"
        object_id = f"{number}:{run_id}"
        tag = f"<!-- gongcao:{self.identity(task, 'review', object_id)} -->"
        payload = {
            "event": "COMMENT",
            "commit_id": task["target_sha"],
            "body": (
                "Gongcao independent context review (not a formal approval)\n\n"
                f"{json.dumps(result, ensure_ascii=False)}\n\n{tag}"
            ),
        }

        async def existing() -> dict[str, Any] | None:
            rows = [
                r
                for r in await self.github.pages(endpoint + "?per_page=100")
                if tag in (r.get("body") or "") and r["commit_id"] == task["target_sha"]
            ]
            if len(rows) > 1:
                raise UncertainWrite("Multiple matching review requests need reconciliation")
            return {"id": rows[0]["id"]} if rows else None

        async def create() -> dict[str, Any]:
            return await self.github.mutate(endpoint, payload)

        await self.perform(task, "review", object_id, payload, existing, create)

    async def ready(self, task: dict[str, Any]) -> None:
        async def observed() -> dict[str, Any] | None:
            snapshot = await self.github.task_snapshot(task)
            if snapshot["head_sha"] != task["target_sha"] or any(
                snapshot.get(key) != task["snapshot"].get(key) for key in VERSION_FIELDS
            ):
                raise UncertainWrite("PR changed while confirming readiness")
            return {"ready": True} if not snapshot["draft"] else None

        async def write() -> dict[str, Any]:
            await command(
                "gh",
                "pr",
                "ready",
                str(task["pr_number"]),
                "--repo",
                task["snapshot"]["repository"],
            )
            return {"ready": True}

        await self.perform(
            task, "ready", str(task["pr_number"]), {"sha": task["target_sha"]}, observed, write
        )
