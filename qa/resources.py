"""Run-owned GitHub resources: persist intent, observe, and never replay an unknown write."""

import hashlib
import json
import shutil
from collections.abc import Awaitable, Callable
from typing import Any
from urllib.parse import urlencode

from gongcao.github import GitHub, command

from .ledger import Run


class Unconfirmed(RuntimeError):
    pass


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
    if previous and previous["state"] == "confirmed":
        return previous["result"]
    observed = await observe()
    if observed is not None:
        actions[key] = {"intent": intent, "state": "confirmed", "result": observed}
        run.save()
        return observed
    if previous:
        raise Unconfirmed(f"Unconfirmed QA action {key}; refusing replay")
    actions[key] = {"intent": intent, "state": "pending"}
    run.save()
    try:
        if key == "delete-branch":
            branch = run.value["resources"]["branch"]
            await command(
                "git",
                "push",
                f"--force-with-lease=refs/heads/{branch}:{payload['expected_sha']}",
                "origin",
                f":refs/heads/{branch}",
                cwd=str(run.root / "source"),
            )
        else:
            await command(
                "gh",
                "api",
                "--method",
                method,
                path,
                "--input",
                "-",
                input_data=json.dumps(payload),
            )
    except (OSError, RuntimeError, TimeoutError):
        # The request might have reached GitHub. Only a read can confirm its result.
        pass
    try:
        observed = await observe()
    except (OSError, RuntimeError, TimeoutError):
        observed = None
    if observed is None:
        actions[key]["state"] = "unknown"
        run.save()
        raise Unconfirmed(f"QA action {key} needs reconciliation; do not retry the write")
    actions[key].update(state="confirmed", result=observed)
    run.save()
    return observed


async def create_issue(run: Run, requirement: str, github: GitHub) -> dict[str, Any]:
    repository = run.value["repository"]
    payload = {
        "title": f"[QA {run.id[:12]}] clamp_score ({run.value['scenario']})",
        "body": f"{run.marker}\n\n{requirement}",
    }

    async def observe() -> Any:
        query = urlencode({"state": "all", "creator": run.value["github_login"], "per_page": 100})
        rows = await github.pages(f"repos/{repository}/issues?{query}")
        matches = [
            r for r in rows if r.get("body") == payload["body"] and r["title"] == payload["title"]
        ]
        if len(matches) > 1:
            raise Unconfirmed("Duplicate QA issue markers; manual reconciliation required")
        if not matches:
            return None
        row = matches[0]
        return {"number": row["number"], "url": row["html_url"]}

    issue = await action(
        run, "create-issue", "POST", f"repos/{repository}/issues", payload, observe
    )
    run.value["resources"]["issue"] = issue
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


async def cleanup(run: Run, task: dict[str, Any] | None, github: GitHub) -> None:
    """Caller owns Run.lock; archive first, then verify all ownership before any mutation."""
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
        return
    repo = run.value["repository"]
    if task and (
        task["url"] != resources["issue"]["url"]
        or task["repo_path"] != str(run.root / "source")
        or task["snapshot"]["repository"] != repo
    ):
        raise Unconfirmed("Task is outside this QA Run")
    prefix = f"repos/{repo}"
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
    pull = pulls[0] if pulls else None
    if pull and (
        not task
        or pull["number"] != task["pr_number"]
        or pull["merged_at"]
        or pull["head"]["repo"]["full_name"].lower() != repo
        or pull["user"]["login"] != run.value["github_login"]
        or f"Implements {resources['issue']['url']}" not in (pull.get("body") or "")
    ):
        raise Unconfirmed("PR ownership is unconfirmed or the test PR was merged")
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
    if not (run.root / "cleanup-remote.json").exists():
        run.archive("cleanup-remote", {"issue": issue, "pull": pull, "ref": ref})

    async def closed(path: str) -> Any:
        row = await github.read(path)
        return {"state": "closed"} if row["state"] == "closed" else None

    if pull:
        path = f"{prefix}/pulls/{pull['number']}"
        await action(run, "close-pull", "PATCH", path, {"state": "closed"}, lambda: closed(path))
    issue_path = f"{prefix}/issues/{issue['number']}"
    await action(
        run, "close-issue", "PATCH", issue_path, {"state": "closed"}, lambda: closed(issue_path)
    )
    if ref:

        async def deleted() -> Any:
            return {"deleted": True} if await optional(github, ref_path) is None else None

        await action(
            run,
            "delete-branch",
            "DELETE",
            f"{prefix}/git/refs/heads/{branch}",
            {"expected_sha": ref["object"]["sha"]},
            deleted,
        )
    # Keep logs, contexts, SQLite and manifests; remove only this Run's clone/worktrees
    # and production's dedicated model-auth copies after their processes have stopped.
    for local_path in (run.root / "source", run.root / "state/worktrees"):
        if local_path.is_symlink() or local_path.resolve() != local_path:
            raise Unconfirmed("Local cleanup path has been redirected")
        if local_path.exists():
            shutil.rmtree(local_path)
    for auth_path in (run.root / "state").glob("*/**/home/.codex/auth.json"):
        if auth_path.resolve().is_relative_to(run.root):
            auth_path.unlink()
    run.value["cleaned"] = True
    run.event("cleaned")


async def reconcile(run: Run, github: GitHub) -> None:
    """An explicit read-only reconciliation never resends a pending write."""
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
            if key == "delete-branch":
                path = intent["path"].replace("/git/refs/heads/", "/git/ref/heads/")
                return {"deleted": True} if await optional(github, path) is None else None
            if key in {"close-issue", "close-pull"}:
                row = await github.read(intent["path"])
                return {"state": "closed"} if row["state"] == "closed" else None
            raise Unconfirmed("Unknown QA action; manual inspection required")

        await action(run, key, intent["method"], intent["path"], intent["payload"], observe)
