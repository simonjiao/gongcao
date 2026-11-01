"""Run-owned GitHub resources: persist intent, observe, and never replay an unknown write."""

import asyncio
import fcntl
import hashlib
import json
import shutil
from collections.abc import Awaitable, Callable
from typing import Any
from urllib.parse import urlencode

from gongcao.coordination import AdvisoryProcesses
from gongcao.events import Redactor
from gongcao.github import GitHub, Target, command
from gongcao.workspace import repository as validate_repository

from .ledger import Run


class Unconfirmed(RuntimeError):
    pass


def require_unmerged(pull: dict[str, Any]) -> None:
    if pull.get("merged") or pull.get("merged_at"):
        raise Unconfirmed("Test PR was merged during cleanup; manual reconciliation required")


async def optional(github: GitHub, path: str) -> Any:
    try:
        return await github.read(path)
    except RuntimeError as exc:
        if "HTTP 404" in str(exc):
            return None
        raise


async def action(
    run: Run,
    key: str,
    method: str,
    path: str,
    payload: dict[str, Any],
    observe: Callable[[], Awaitable[Any]],
) -> Any:
    actions = run.value["actions"]
    intent = {"method": method, "path": path, "payload": payload}
    previous = actions.get(key)
    if previous and previous["intent"] != intent:
        raise ValueError("QA action identity changed")
    observed = await observe()
    if observed is not None:
        actions[key] = {"intent": intent, "state": "confirmed", "result": observed}
        run.save()
        return observed
    if previous:
        previous["state"] = "unknown"
        run.save()
        raise Unconfirmed(f"Unconfirmed QA action {key}; refusing replay")
    if method == "POST" and path.endswith("/issues"):
        run.check_cancelled()
    actions[key] = {"intent": intent, "state": "pending"}
    run.save()
    try:
        if key == "delete-branch" or key.startswith("delete-branch-"):
            branch = path.split("/git/refs/heads/", 1)[1]
            await command(
                "git",
                "push",
                f"--force-with-lease=refs/heads/{branch}:{payload['expected_sha']}",
                f"git@github.com:{run.value['repository']}.git",
                f":refs/heads/{branch}",
                cwd=str(run.root / "source"),
            )
        else:
            response = await command(
                "gh",
                "api",
                "--method",
                method,
                path,
                "--input",
                "-",
                input_data=json.dumps(payload),
            )
            if method == "POST" and path.endswith("/issues"):
                row = json.loads(response)
                actions[key]["response_hint"] = {"number": row["number"]}
                run.save()
    except (OSError, RuntimeError, TimeoutError) as exc:
        # The request might have reached GitHub. Only a read can confirm its result.
        actions[key]["write_error"] = Redactor().text(f"{type(exc).__name__}: {exc}")
        run.save()
    # GitHub list endpoints may lag a successful creation. Retry only observations,
    # never the write, and keep a returned issue number as an untrusted lookup hint.
    observed = None
    for delay in (0, 0.5, 1, 2):
        if delay:
            await asyncio.sleep(delay)
        try:
            observed = await observe()
        except Unconfirmed as exc:
            actions[key].update(state="unknown", observation_error=str(exc))
            run.save()
            raise
        except (OSError, RuntimeError, TimeoutError) as exc:
            actions[key]["observation_error"] = Redactor().text(str(exc))
        if observed is not None:
            break
    if observed is None:
        actions[key]["state"] = "unknown"
        run.save()
        raise Unconfirmed(f"QA action {key} needs reconciliation; do not retry the write")
    actions[key].update(state="confirmed", result=observed)
    run.save()
    return observed


async def create_issue(
    run: Run, requirement: str, github: GitHub, *, name: str = "issue"
) -> dict[str, Any]:
    repository = run.value["repository"]
    payload = {
        "title": f"[QA {run.id[:12]}] clamp_score ({run.value['scenario']}/{name})",
        "body": f"{run.marker}\n\n{requirement}",
    }

    async def observe() -> Any:
        hint = run.value["actions"].get("create-" + name, {}).get("response_hint")
        if hint:
            row = await optional(github, f"repos/{repository}/issues/{int(hint['number'])}")
            rows = [row] if row else []
        else:
            query = urlencode(
                {"state": "all", "creator": run.value["github_login"], "per_page": 100}
            )
            rows = await github.pages(f"repos/{repository}/issues?{query}")
        matches = [
            r
            for r in rows
            if r.get("body") == payload["body"]
            and r["title"] == payload["title"]
            and r.get("user", {}).get("login") == run.value["github_login"]
            and "pull_request" not in r
        ]
        if len(matches) > 1:
            raise Unconfirmed("Duplicate QA issue markers; manual reconciliation required")
        if not matches:
            return None
        row = matches[0]
        return {"number": row["number"], "url": row["html_url"]}

    issue = await action(
        run, "create-" + name, "POST", f"repos/{repository}/issues", payload, observe
    )
    run.value["resources"][name] = issue
    if name == "issue":
        run.value["resources"]["branch"] = (
            "gongcao/work-" + hashlib.sha256(issue["url"].encode()).hexdigest()[:12]
        )
    run.save()
    return issue  # type: ignore[no-any-return]


def settled(task: dict[str, Any]) -> None:
    if (
        task["runtime"]["lease"]
        or any(p["state"] != "stopped" for p in task["runtime"]["processes"])
        or any(r["state"] == "running" for r in task["runs"])
    ):
        raise Unconfirmed("Production execution/descendant cleanup is not confirmed")
    if any(o["state"] != "succeeded" for o in task["evidence"]["operations"]):
        raise Unconfirmed("Production remote writes need reconciliation before cleanup")


def cleanup_local(run: Run) -> None:
    paths = (run.root / "source", run.root / "state/worktrees")
    if any(path.is_symlink() or path.resolve() != path for path in paths):
        raise Unconfirmed("Local cleanup path has been redirected")
    for path in paths:
        if path.exists():
            shutil.rmtree(path)
    for auth_path in (run.root / "state").glob("*/**/home/.codex/auth.json"):
        if auth_path.resolve().is_relative_to(run.root):
            auth_path.unlink()
    run.value["cleaned"] = True
    run.event("cleaned")


async def cleanup(run: Run, task: dict[str, Any] | None, github: GitHub) -> None:
    try:
        state = run.root / "state"
        if state.is_symlink() or state.resolve() != state:
            raise Unconfirmed("QA state path has been redirected")
        state.mkdir(exist_ok=True, mode=0o700)
        with (state / "coordination.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise Unconfirmed("Coordination is still active; retain QA resources") from None
            if AdvisoryProcesses.unresolved(state / "coordination-process.json") is not None:
                raise Unconfirmed("Coordination cleanup is unconfirmed; retain QA resources")
            await _cleanup(run, task, github)
    except (Unconfirmed, OSError) as exc:
        run.value.update(status="needs_reconciliation", cleaned=False, cleanup_failure=str(exc))
        run.event("cleanup-blocked", reason=str(exc))
        if not isinstance(exc, Unconfirmed):
            raise Unconfirmed("Cleanup access cannot be confirmed; retain QA resources") from exc
        raise


async def _cleanup(run: Run, task: dict[str, Any] | None, github: GitHub) -> None:
    """Caller owns Run.lock; archive first, then verify all ownership before any mutation."""
    run.value["cleaned"] = False
    run.save()
    if (run.root / "state/gongcao.sqlite3").exists():
        from gongcao.recovery import diagnose
        from gongcao.store import Store

        state = Store(run.root / "state")
        try:
            if state.db.execute(
                "SELECT 1 FROM claims WHERE intent!='' OR confirmed='' "
                "OR COALESCE(json_array_length(data,'$.progress'),0)>0"
            ).fetchone():
                raise Unconfirmed("Controller feedback needs reconciliation before cleanup")
            for peer in state.tasks():
                settled(
                    peer
                    | {
                        "runs": state.runs(peer["id"]),
                        "evidence": state.evidence(peer["id"]),
                        "runtime": diagnose(state, peer["id"]),
                    }
                )
        finally:
            state.close()
    if task:
        settled(task)
        if not (run.root / "cleanup-task.json").exists():
            run.archive("cleanup-task", task)
    else:
        run.archive("cleanup-inventory", run.value["resources"])
    if any(a["state"] != "confirmed" for a in run.value["actions"].values()):
        raise Unconfirmed("QA inventory contains an unconfirmed remote write")
    resources = run.value["resources"]
    if "issue" not in resources:
        # A crash after POST but before recording the resource must be reconciled first.
        if "create-issue" in run.value["actions"]:
            raise Unconfirmed("QA issue has not been adopted into the inventory")
        cleanup_local(run)
        return
    repo = run.value["repository"]
    if task and (
        task["url"] != resources["issue"]["url"]
        or task["repo_path"] != str(run.root / "source")
        or task["snapshot"]["repository"] != repo
    ):
        raise Unconfirmed("Task is outside this QA Run")
    prefix = f"repos/{repo}"

    async def unchanged_base() -> dict[str, Any]:
        metadata = await github.read(prefix)
        if metadata.get("default_branch") != run.value["base_branch"]:
            raise Unconfirmed("Default branch changed during cleanup; reconcile before continuing")
        current = await github.read(f"{prefix}/git/ref/heads/{run.value['base_branch']}")
        if current["object"]["sha"] != run.value["base_sha"]:
            raise Unconfirmed(
                "Default branch SHA changed during cleanup; reconcile before continuing"
            )
        return {"branch": run.value["base_branch"], "sha": current["object"]["sha"]}

    await unchanged_base()
    issue = await github.read(f"{prefix}/issues/{resources['issue']['number']}")
    if (
        run.marker not in (issue.get("body") or "")
        or issue["user"]["login"] != run.value["github_login"]
    ):
        raise Unconfirmed("QA issue ownership changed")
    branch = resources["branch"]
    expected_branch = (
        "gongcao/work-" + hashlib.sha256(resources["issue"]["url"].encode()).hexdigest()[:12]
    )
    if branch != expected_branch or branch == run.value["base_branch"]:
        raise Unconfirmed("Branch identity is outside this QA Run")
    query = urlencode({"state": "all", "head": f"{repo.split('/')[0]}:{branch}", "per_page": 100})
    pulls = await github.pages(f"{prefix}/pulls?{query}")
    if len(pulls) > 1:
        raise Unconfirmed("More than one PR uses the QA branch")
    number = task.get("pr_number") if task else resources.get("pr_number")
    if task and any(
        op["kind"] == "pull" and (not number or (op.get("response") or {}).get("number") != number)
        for op in task["evidence"]["operations"]
    ):
        raise Unconfirmed("Published PR needs task reconciliation before cleanup")
    if number:
        if any(p["number"] != number for p in pulls):
            raise Unconfirmed("QA branch PR differs from the registered PR")
        pull = await optional(github, f"{prefix}/pulls/{number}")
        if pull is None:
            raise Unconfirmed("Registered test PR is unavailable; manual reconciliation required")
    else:
        pull = pulls[0] if pulls else None
    if pull and (
        not task
        or pull["number"] != task["pr_number"]
        or pull["head"]["repo"]["full_name"].lower() != repo
        or pull["head"]["ref"] != branch
        or pull["user"]["login"] != run.value["github_login"]
        or f"Implements {resources['issue']['url']}" not in (pull.get("body") or "")
    ):
        raise Unconfirmed("PR ownership is unconfirmed")
    if pull:
        require_unmerged(pull)
    ref_path = f"{prefix}/git/ref/heads/{branch}"
    ref = await optional(github, ref_path)
    owned_shas = (
        {
            op["payload"]["sha"]
            for op in task["evidence"]["operations"]
            if op["kind"] == "push"
            and op["state"] == "succeeded"
            and op["payload"]["branch"] == branch
        }
        if task
        else set()
    )
    if ref and ref["object"]["sha"] not in owned_shas:
        raise Unconfirmed("Branch contains an unconfirmed or foreign commit")
    checkpoints = {}
    checkpoint_present = False
    if task:
        for op in task["evidence"]["operations"]:
            if op["kind"] != "checkpoint":
                continue
            saved = op["payload"]
            role = next((r for r in task["runs"] if r["id"] == saved["run_id"]), None)
            expected = (
                expected_branch.replace("gongcao/work-", "gongcao/save-") + "-" + saved["run_id"]
            )
            if (
                saved["branch"] != expected
                or not role
                or role["role"] != "developer"
                or role["details"]["save"].get("state") != "confirmed"
                or role["details"]["save"].get("sha") != saved["sha"]
            ):
                raise Unconfirmed("Checkpoint branch ownership is unconfirmed")
            checkpoint = await optional(github, f"{prefix}/git/ref/heads/{expected}")
            checkpoint_present |= checkpoint is not None
            if checkpoint and checkpoint["object"]["sha"] != saved["sha"]:
                raise Unconfirmed("Checkpoint branch contains a foreign commit")
            query = urlencode(
                {"state": "all", "head": f"{repo.split('/')[0]}:{expected}", "per_page": 100}
            )
            if await github.pages(f"{prefix}/pulls?{query}"):
                raise Unconfirmed("Checkpoint branch unexpectedly has a PR")
            checkpoints[expected] = saved["sha"]
    if ref or checkpoint_present:
        source = run.root / "source"
        if source.is_symlink() or source.resolve() != source:
            raise Unconfirmed("Source clone has been redirected")
        actual_root, _ = await validate_repository(source, Target.parse(resources["issue"]["url"]))
        if actual_root != source:
            raise Unconfirmed("Source clone is outside this QA Run")
    if not (run.root / "cleanup-remote.json").exists():
        run.archive(
            "cleanup-remote", {"issue": issue, "pull": pull, "ref": ref, "checkpoints": checkpoints}
        )

    if run.value["scenario"] == "discovery":
        from .discovery import cleanup_extras

        await cleanup_extras(run, github)

    async def closed(path: str) -> Any:
        row = await github.read(path)
        if path == pull_path:
            require_unmerged(row)
        await unchanged_base()
        return {"state": "closed"} if row["state"] == "closed" else None

    pull_path = f"{prefix}/pulls/{pull['number']}" if pull else None
    if pull:
        assert pull_path is not None
        await action(
            run, "close-pull", "PATCH", pull_path, {"state": "closed"}, lambda: closed(pull_path)
        )
    issue_path = f"{prefix}/issues/{issue['number']}"
    await action(
        run, "close-issue", "PATCH", issue_path, {"state": "closed"}, lambda: closed(issue_path)
    )
    branches = checkpoints | ({branch: ref["object"]["sha"]} if ref else {})
    for owned_branch, expected_sha in branches.items():
        if pull_path:
            if await closed(pull_path) is None:
                raise Unconfirmed("Test PR reopened during cleanup")
        await unchanged_base()

        async def deleted(owned_branch: str = owned_branch) -> Any:
            return (
                {"deleted": True}
                if await optional(github, f"{prefix}/git/ref/heads/{owned_branch}") is None
                else None
            )

        await action(
            run,
            "delete-branch"
            if owned_branch == branch
            else "delete-branch-" + owned_branch.rsplit("-", 1)[1],
            "DELETE",
            f"{prefix}/git/refs/heads/{owned_branch}",
            {"expected_sha": expected_sha},
            deleted,
        )
    if pull_path and await closed(pull_path) is None:
        raise Unconfirmed("Test PR reopened during cleanup")
    if await closed(issue_path) is None or await optional(github, ref_path) is not None:
        raise Unconfirmed("Owned remote resources changed during cleanup")
    for owned_branch in checkpoints:
        if await optional(github, f"{prefix}/git/ref/heads/{owned_branch}") is not None:
            raise Unconfirmed("Checkpoint branch reappeared during cleanup")
    base = await unchanged_base()
    run.archive(
        "cleanup-confirmed",
        {
            "base": base,
            "pull": {"number": pull["number"], "state": "closed", "merged": False}
            if pull
            else None,
            "issue_closed": True,
            "branch_deleted": True,
            "checkpoints_deleted": list(checkpoints),
        },
    )
    # Keep logs, contexts, SQLite and manifests; remove only this Run's clone/worktrees
    # and production's dedicated model-auth copies after their processes have stopped.
    cleanup_local(run)


async def reconcile(run: Run, github: GitHub) -> None:
    """An explicit read-only reconciliation never resends a pending write."""
    if (run.root / "state/gongcao.sqlite3").exists():
        from gongcao.config import Config
        from gongcao.discovery import Discovery
        from gongcao.store import Store

        state = Store(run.root / "state")
        try:
            publisher = Discovery(state, Config(), github)
            for task in state.tasks():
                await publisher.reconcile_status(task["id"])
        finally:
            state.close()
    for key, record in list(run.value["actions"].items()):
        intent = record["intent"]
        if key == "create-issue":
            body = intent["payload"]["body"]
            requirement = body.removeprefix(f"{run.marker}\n\n")
            await create_issue(run, requirement, github)
            continue
        if record["state"] == "confirmed":
            continue

        async def observe(key: str = key, intent: dict[str, Any] = intent) -> Any:
            if key == "delete-branch" or key.startswith("delete-branch-"):
                path = intent["path"].replace("/git/refs/heads/", "/git/ref/heads/")
                return {"deleted": True} if await optional(github, path) is None else None
            if key in {"close-issue", "close-pull"}:
                row = await github.read(intent["path"])
                if key == "close-pull":
                    require_unmerged(row)
                return {"state": "closed"} if row["state"] == "closed" else None
            raise Unconfirmed("Unknown QA action; manual inspection required")

        await action(run, key, intent["method"], intent["path"], intent["payload"], observe)

    if run.value["scenario"] == "discovery":
        from .discovery import reconcile_claims

        await reconcile_claims(run, github)
