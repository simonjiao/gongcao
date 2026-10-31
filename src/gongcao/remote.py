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
from .github import Deferred, GitHub, Target, command
from .model import VERSION_FIELDS, Role, Stage, State, development_complete
from .processes import NotStarted
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
        self,
        expected: dict[str, Any],
        kind: str,
        *,
        finish_operation: bool = False,
        verified: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        target = Target.parse(expected["url"])
        recovery = Recovery(self.store, self.github)
        latest = verified if verified is not None else await recovery.sync(expected)
        expected = self.delivery_version(expected, kind)
        current = self.store.task(expected["id"])
        if latest.get("head_sha", expected["target_sha"]) != expected["target_sha"] or any(
            latest.get(key) != expected["snapshot"].get(key) for key in VERSION_FIELDS
        ):
            raise UncertainWrite("Remote target changed before a controlled write")
        if kind != "checkpoint" and not finish_operation:
            current = await self.instruction_checkpoint(expected)
        guard = self.store.save_guard if kind == "checkpoint" else self.store.guard
        guard(current)
        if any(run["state"] == "running" for run in self.store.runs(current["id"])):
            raise ValueError("An active agent cannot authorize a remote mutation")
        allowed = {
            "qa": set(Stage) - {Stage.MERGED},
            "archive": set(Stage) - {Stage.MERGED},
            "archive-link": set(Stage) - {Stage.MERGED},
            "push": {Stage.DEVELOPMENT, Stage.REVISION},
            "checkpoint": {Stage.DEVELOPMENT, Stage.REVISION},
            "pull": {Stage.DEVELOPMENT, Stage.REVISION},
            "review": {Stage.REVIEW},
            "ready": {Stage.VALIDATION, Stage.MERGEABLE},
        }
        if current["stage"] not in allowed[kind] or latest["state"] != "open":
            raise ValueError("This stage does not authorize the requested GitHub mutation")
        if kind in {"checkpoint", "push", "pull"} and not current["pr_number"]:
            if (recovery.base_sha or await recovery.default_base(current)) != current["target_sha"]:
                raise UncertainWrite("Issue baseline changed before saving output")
        repo = recovery.repo
        if repo is None:
            repo, _ = await repository(Path(current["repo_path"]), target)
        if current["target_sha"] not in self.verified:
            key = "control-" + uuid.uuid4().hex
            workspace = self.store.root / "worktrees" / key
            await worktree(repo, workspace, current["target_sha"], Role.DEVELOPER, key)
            sandbox = Sandbox(workspace, self.store.root / "checks" / key, Role.DEVELOPER)
            sandbox.prepare(self.config, authentication=False)
            evidence = await sandbox.verify(repo)
            if kind != "checkpoint":
                self.store.record(current, "write-isolation", "", evidence)
            self.verified.add(current["target_sha"])
        if kind != "checkpoint" and not finish_operation:
            current = await self.instruction_checkpoint(expected)
        return guard(current)

    def identity(self, task: dict[str, Any], kind: str, object_id: str) -> str:
        return hashlib.sha256(
            f"{task['url']}:{kind}:{task['target_sha']}:{object_id}".encode()
        ).hexdigest()

    def delivery_version(self, expected: dict[str, Any], kind: str) -> dict[str, Any]:
        current = self.store.task(expected["id"])
        if (
            kind in {"push", "pull"}
            and self.store.development_output(expected)
            and self.store.development_output(current)
        ):
            return current
        return expected

    def write_guard(self, expected: dict[str, Any], kind: str) -> dict[str, Any]:
        if kind == "checkpoint":
            return self.store.save_guard(expected)
        controls = Controls(self.store)
        controls.apply_pending(expected["id"], self.config)
        if not controls.revalidate(expected["id"], self.config):
            raise Paused("Paused before sending a controlled write")
        return self.store.guard(self.delivery_version(expected, kind))

    async def perform(
        self,
        task: dict[str, Any],
        kind: str,
        object_id: str,
        payload: dict[str, Any],
        observe: Callable[[], Awaitable[dict[str, Any] | None]],
        write: Callable[[], Awaitable[dict[str, Any]]],
        *,
        verified: dict[str, Any] | None = None,
        preflight: Callable[[dict[str, Any]], Awaitable[None]] | None = None,
    ) -> dict[str, Any]:
        task = await self.before(task, kind, verified=verified)
        key = self.identity(task, kind, object_id)
        created = self.store.intent(task, key, kind, json.dumps(payload, sort_keys=True))
        writing = False
        try:
            found = await observe()
            if found is not None:
                self.store.operation_result(key, "succeeded", found)
                return found
            if not created:
                raise UncertainWrite(
                    "Existing write intent is not confirmed remotely; refusing replay"
                )
            task = await self.before(task, kind, finish_operation=True)
            if preflight is not None:
                await preflight(task)
            task = self.write_guard(task, kind)
            writing = True
            try:
                await write()
            except (Deferred, NotStarted):
                writing = False  # Explicit rejection or OS-confirmed failure to start.
                raise
            found = await observe()
            if found is None:
                raise UncertainWrite("Write returned but remote state did not confirm its result")
        except Deferred:
            # This newly created intent has no accepted write. Older ambiguous
            # intents never reach here: they must reconcile above, without replay.
            if writing:
                self.store.operation_result(key, "unknown", None)
            elif created:
                with self.store.db:
                    self.store.db.execute(
                        "DELETE FROM operations WHERE id=? AND state='pending'", (key,)
                    )
            raise
        except BaseException as exc:
            if not writing:
                if created:
                    with self.store.db:
                        self.store.db.execute(
                            "DELETE FROM operations WHERE id=? AND state='pending'", (key,)
                        )
                raise
            self.store.operation_result(
                key, "unknown", {"error": Redactor().text(f"{type(exc).__name__}: {exc}")}
            )
            try:
                found = await observe()
            except Deferred:
                if isinstance(exc, asyncio.CancelledError):
                    raise exc from None
                raise
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
        self.store.operation_result(key, "succeeded", found)
        return found

    async def remote_head(self, task: dict[str, Any], branch: str) -> str | None:
        rows = (
            await command(
                "git", "ls-remote", "origin", f"refs/heads/{branch}", cwd=task["repo_path"]
            )
        ).split()
        return rows[0] if rows else None

    async def push(
        self,
        task: dict[str, Any],
        kind: str,
        branch: str,
        head: str,
        expected_parent: str | None,
        **metadata: Any,
    ) -> dict[str, Any]:
        payload = {"sha": head, "branch": branch} | metadata

        async def observed() -> dict[str, Any] | None:
            remote = await self.remote_head(task, branch)
            if remote == head:
                return payload
            if remote is not None and remote != expected_parent:
                raise UncertainWrite("Remote branch contains an unexpected commit")
            return None

        expected: str | None = None

        async def preflight(current: dict[str, Any]) -> None:
            nonlocal expected
            expected = await self.remote_head(current, branch)
            if expected is not None and expected != expected_parent:
                raise UncertainWrite("Remote branch moved before push")
            if expected:
                ancestor = (
                    await command("git", "merge-base", expected, head, cwd=current["repo_path"])
                ).strip()
                if ancestor != expected:
                    raise UncertainWrite("Publication must fast-forward the confirmed remote head")

        async def write() -> dict[str, Any]:
            await command(
                "git",
                "push",
                "origin",
                f"--force-with-lease=refs/heads/{branch}:{expected or ''}",
                f"{head}:refs/heads/{branch}",
                cwd=task["repo_path"],
            )
            return payload

        return await self.perform(task, kind, branch, payload, observed, write, preflight=preflight)

    async def commit(self, task: dict[str, Any], run: dict[str, Any]) -> str:
        workspace = Path(run["worktree"]).resolve()
        if not workspace.is_relative_to(self.store.root / "worktrees"):
            raise ValueError("Development output is outside the allocated Worktree root")
        source = run["details"].get("source", {})
        parent = source.get("sha", task["target_sha"])
        head = (await command("git", "rev-parse", "HEAD", cwd=str(workspace))).strip()
        marker = f"Gongcao-Run: {run['id']}"
        if head != parent:
            lines = (
                await command("git", "show", "-s", "--format=%P%n%B", head, cwd=str(workspace))
            ).splitlines()
            if lines[0] != parent or marker not in lines:
                raise UncertainWrite("Worktree HEAD is not a confirmed controller commit")
            if (await command("git", "status", "--porcelain", cwd=str(workspace))).strip():
                raise UncertainWrite("Output changed after the controller commit")
            return head
        self.store.save_guard(task)
        await command(
            "git", "-c", "core.hooksPath=/dev/null", "add", "--all", "--", ".", cwd=str(workspace)
        )
        if not (
            await command("git", "diff", "--cached", "--name-only", cwd=str(workspace))
        ).strip():
            return head
        self.store.save_guard(task)
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
            f"Task output (controller checkpoint)\n\n{marker}\nGongcao-Task: {task['url']}"
            f"\nGongcao-Base: {task['target_sha']}",
            cwd=str(workspace),
        )
        return (await command("git", "rev-parse", "HEAD", cwd=str(workspace))).strip()

    async def checkpoint(self, task: dict[str, Any], run: dict[str, Any]) -> None:
        if not run["worktree"]:
            return
        task = await self.before(task, "checkpoint")
        source = run["details"].get("source", {})
        delivery = self.store.development_output(task)
        if (
            source.get("baseline") != baseline(task)
            and not (delivery and delivery["id"] == run["id"] and run["state"] == State.COMPLETED)
        ) or run["target_sha"] != task["target_sha"]:
            raise UncertainWrite("Run source no longer matches the task; preserving local output")
        if run["role"] != Role.DEVELOPER or run["state"] in {State.RUNNING, State.RECONCILE}:
            raise ValueError("Only settled Developer output can be saved")
        pending = [
            op
            for op in self.store.evidence(task["id"])["operations"]
            if op["state"] != "succeeded" and op["payload"].get("run_id") != run["id"]
        ]
        if pending:
            raise UncertainWrite("Unconfirmed remote writes must be reconciled before saving")
        head = await self.commit(task, run)
        if head == source["sha"]:
            self.store.run_details(run["id"], save={"state": "unchanged"})
            return
        slug = hashlib.sha256(task["url"].encode()).hexdigest()[:12]
        branch = f"gongcao/save-{slug}-{run['id']}"
        summary = await command("git", "diff", "--stat", source["sha"], head, cwd=task["repo_path"])
        saved = {
            "sha": head,
            "branch": branch,
            "run_id": run["id"],
            "parent": source["sha"],
            "target_sha": task["target_sha"],
            "baseline": source["baseline"],
            "summary": summary.strip(),
        }
        self.store.run_details(run["id"], save=saved | {"state": "pending"})
        await self.push(
            task,
            "checkpoint",
            branch,
            head,
            None,
            **{k: v for k, v in saved.items() if k not in {"sha", "branch"}},
        )
        self.store.run_details(run["id"], save=saved | {"state": "confirmed"})

    async def source(self, task: dict[str, Any]) -> dict[str, Any]:
        """Resolve preserved output without changing the task's reviewed target SHA."""
        source: dict[str, Any] = {"sha": task["target_sha"], "baseline": baseline(task)}
        for op in self.store.evidence(task["id"])["operations"]:
            if op["kind"] != "checkpoint" or op["sha"] != task["target_sha"]:
                continue
            payload = op["payload"]
            if payload["baseline"] != baseline(task):
                raise UncertainWrite(
                    "Saved output belongs to different requirements; reconcile first"
                )
            if op["state"] != "succeeded":
                raise UncertainWrite("Saved output has not been confirmed remotely")
            if payload["parent"] != source["sha"]:
                raise UncertainWrite("Checkpoint history is not a continuous controller chain")
            if await self.remote_head(task, payload["branch"]) != payload["sha"]:
                raise UncertainWrite("Saved branch moved or disappeared; reconcile first")
            lines = (
                await command(
                    "git", "show", "-s", "--format=%P%n%B", payload["sha"], cwd=task["repo_path"]
                )
            ).splitlines()
            if lines[0] != source["sha"] or f"Gongcao-Run: {payload['run_id']}" not in lines:
                raise UncertainWrite("Checkpoint commit provenance does not match its intent")
            source |= {
                "sha": payload["sha"],
                "run_id": payload["run_id"],
                "branch": payload["branch"],
            }
        return source

    async def publish(
        self, task: dict[str, Any], run: dict[str, Any]
    ) -> tuple[dict[str, Any], int]:
        valid = [
            row
            for row in self.store.runs(task["id"])
            if row["id"] == run["id"]
            and row["role"] == Role.DEVELOPER
            and row["state"] == "completed"
            and self.store.development_output(task)
            and row["target_sha"] == task["target_sha"]
        ]
        if not valid or (
            not development_complete(json.loads(valid[0]["result"]))
            or json.loads(valid[0]["result"]).get("target_sha") != task["target_sha"]
        ):
            raise ValueError("Publishing requires a confirmed developer result for this target")
        run = valid[0]
        task = await self.before(task, "push")
        original = task | {
            "snapshot": run["details"].get("source", {}).get("request", task["snapshot"])
        }
        report = json.loads(run["result"])
        if report["conclusion"] == "blocked":
            await self.checkpoint(task, run)
            run = next(row for row in self.store.runs(task["id"]) if row["id"] == run["id"])
        source = await self.source(original)
        expected = run["details"].get("source", {}).get("sha", task["target_sha"])
        saved = run["details"].get("save", {})
        if source["sha"] != expected and not (
            saved.get("state") == "confirmed" and saved.get("sha") == source["sha"]
        ):
            raise UncertainWrite(
                "Developer output does not continue the confirmed checkpoint chain"
            )
        snapshot = task["snapshot"]
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
        head = await self.commit(task, run)
        if head == task["target_sha"]:
            raise ValueError("Developer produced no changes; no PR can be published")
        await self.push(task, "push", branch, head, task["target_sha"])
        if task["pr_number"]:
            updated = await self.github.task_snapshot(task)
            if updated["head_sha"] != head or any(
                updated.get(key) != snapshot.get(key)
                for key in VERSION_FIELDS
                if key not in {"title", "body"}
            ):
                raise UncertainWrite("Published PR head moved before confirmation")
            self.store.sync(
                task["id"],
                self.store.task(task["id"])["snapshot"]
                | {key: updated.get(key) for key in ("title", "body", "state")},
            )
            return updated, task["pr_number"]
        repository_name = snapshot["repository"]
        key = self.identity(task, "pull", branch)
        tag = f"<!-- gongcao:{key} -->"
        payload = {
            "head": branch,
            "base": base_ref,
            "draft": True,
            "title": original["snapshot"]["title"],
            "body": Redactor().text(
                f"Implements {task['url']}\n\n{tag}\n\n"
                f"Delivered output: Run `{run['id']}`, controller commit `{head}`, "
                f"source `{expected}`, original target `{run['target_sha']}`.\n"
                f"Checkpoint: {saved.get('state', 'not recorded')}.\n"
                f"Agent report (self-reported, not controller acceptance): "
                f"`{report['conclusion']}`; delivery_complete={report.get('delivery_complete')}.\n"
                f"{report['summary']}\nReported checks/basis: {'; '.join(report['basis'])[:6000]}\n"
                f"Remaining / missing inputs: {'; '.join(report['next_steps'])[:6000]}\n"
                "Report excerpts only; full report retained locally.\n"
                "Controller checks at this PR head: NOT_RUN. Review / quality / real acceptance "
                "remain pending; missing inputs do not satisfy their gates. No merge or release."
            ),
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

        async def preflight(current: dict[str, Any]) -> None:
            if await self.remote_head(current, branch) != head:
                raise UncertainWrite("Remote branch moved before PR creation")

        async def create() -> dict[str, Any]:
            return await self.github.mutate(f"repos/{repository_name}/pulls", payload)

        result = await self.perform(
            task, "pull", branch, payload, existing, create, preflight=preflight
        )
        temporary = task | {"pr_number": result["number"]}
        updated = await self.github.task_snapshot(temporary)
        if (
            updated["head_sha"] != head
            or updated["base_sha"] != task["target_sha"]
            or updated["base_ref"] != base_ref
            or updated["head_ref"] != branch
            or updated["base_repository"] != repository_name
            or updated["head_repository"] != repository_name
            or not updated["draft"]
        ):
            raise UncertainWrite("PR head moved before confirmation")
        self.store.sync(
            task["id"],
            self.store.task(task["id"])["snapshot"]
            | {key: updated.get(key) for key in ("title", "body", "state")},
        )
        return updated, result["number"]

    async def review(
        self,
        task: dict[str, Any],
        result: dict[str, Any],
        run_id: str,
        *,
        verified: dict[str, Any] | None = None,
    ) -> None:
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

        await self.perform(task, "review", object_id, payload, existing, create, verified=verified)

    async def ready(self, task: dict[str, Any], *, verified: dict[str, Any] | None = None) -> None:
        async def observed() -> dict[str, Any] | None:
            snapshot = await self.github.task_snapshot(task)
            if snapshot["head_sha"] != task["target_sha"] or any(
                snapshot.get(key) != task["snapshot"].get(key) for key in VERSION_FIELDS
            ):
                raise UncertainWrite("PR changed while confirming readiness")
            return {"ready": True} if not snapshot["draft"] else None

        async def write() -> dict[str, Any]:
            await self.github.mutate(
                "graphql",
                {
                    "query": "mutation($id:ID!){markPullRequestReadyForReview("
                    "input:{pullRequestId:$id}){clientMutationId}}",
                    "variables": {"id": task["snapshot"]["node_id"]},
                },
            )
            return {"ready": True}

        await self.perform(
            task,
            "ready",
            str(task["pr_number"]),
            {"sha": task["target_sha"]},
            observed,
            write,
            verified=verified,
        )
