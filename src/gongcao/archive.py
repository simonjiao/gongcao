"""Append sanitized evidence to an isolated branch through controlled write intents."""

import hashlib
import json
from typing import Any

from .events import Redactor
from .github import GitHub, command
from .plan import binding
from .remote import Controlled, UncertainWrite


async def observe(
    task: dict[str, Any], payload: dict[str, Any], github: GitHub
) -> dict[str, Any] | None:
    repo = task["repo_path"]
    refs = (
        await command("git", "ls-remote", "origin", f"refs/heads/{payload['branch']}", cwd=repo)
    ).split()
    if not refs:
        return None
    await command("git", "fetch", "origin", refs[0], cwd=repo)
    try:
        await command("git", "merge-base", "--is-ancestor", payload["sha"], refs[0], cwd=repo)
    except RuntimeError:
        return None
    for name, expected in payload["hashes"].items():
        actual = await command(
            "git", "show", f"{payload['sha']}:{payload['path']}/{name}", cwd=repo
        )
        if hashlib.sha256(actual.encode()).hexdigest() != expected:
            raise UncertainWrite("Archived evidence readback hash mismatch")
    return {"sha": payload["sha"], "url": payload["url"], "path": payload["path"]}


async def observe_link(payload: dict[str, Any], github: GitHub) -> dict[str, Any] | None:
    rows = [
        r
        for r in await github.pages(payload["endpoint"] + "?per_page=100")
        if r.get("body") == payload["body"]
    ]
    if len(rows) > 1:
        raise UncertainWrite("Duplicate archive links require reconciliation")
    return {"id": rows[0]["id"]} if rows else None


async def publish(
    remote: Controlled, task: dict[str, Any], result: dict[str, Any]
) -> dict[str, Any]:
    if task["snapshot"]["kind"] != "issues":
        raise ValueError("Archive requires a registered Issue identity")
    if any(result.get(k) != v for k, v in binding(task).items()):
        raise ValueError("Evidence does not match the current task version")
    plan = remote.store.artifact(task["id"], "quality-plan", remote.config.policy_hash)
    if not plan or plan["plan_hash"] != result["plan_hash"]:
        raise ValueError("Evidence plan is no longer current")
    task = await remote.before(task, "archive")
    key = result["run_id"]
    cached = remote.store.artifact(task["id"], "archive-prepared", key)
    if cached:
        payload = cached
    else:
        number = task["snapshot"]["number"]
        branch = f"qa/issue-{number}-evidence"
        prefix = f"qa/acceptance/issue-{number}/{task['target_sha']}/{key}"
        root = remote.store.root / "archives" / key
        root.mkdir(parents=True, mode=0o700, exist_ok=True)
        # Only this schema leaves the private state directory; no SQLite, sessions or raw logs.
        manifest = {
            k: result[k]
            for k in (*binding(task), "plan_hash", "run_id", "runtime", "items", "started", "ended")
        }
        clean = Redactor().text(json.dumps(manifest, ensure_ascii=False, indent=2)) + "\n"
        statuses = [f"- {i['category']}: {i['status']} ({i['reason']})" for i in manifest["items"]]
        files = {
            "manifest.json": clean,
            "README.md": Redactor().text(
                f"# Issue {number} evidence\n\nTarget: `{task['target_sha']}`\n\n"
                + "\n".join(statuses)
                + "\n"
            ),
        }
        files["SHA256SUMS"] = "".join(
            f"{hashlib.sha256(value.encode()).hexdigest()}  {name}\n"
            for name, value in files.items()
        )
        repo = task["repo_path"]
        refs = (
            await command("git", "ls-remote", "origin", f"refs/heads/{branch}", cwd=repo)
        ).split()
        parent = refs[0] if refs else None
        index = root / "index"
        index.unlink(missing_ok=True)

        async def git(*args: str, input_data: str | None = None) -> str:
            return (
                await command(
                    "env", f"GIT_INDEX_FILE={index}", "git", *args, cwd=repo, input_data=input_data
                )
            ).strip()

        if parent:
            await command("git", "fetch", "origin", parent, cwd=repo)
            if await git("ls-tree", parent, "--", prefix):
                raise ValueError("Archive path already exists; refusing to overwrite history")
        await git("read-tree", parent or "--empty")
        for name, value in files.items():
            (root / name).write_text(value)
            blob = await git("hash-object", "-w", "--stdin", input_data=value)
            await git("update-index", "--add", "--cacheinfo", f"100644,{blob},{prefix}/{name}")
        tree = await git("write-tree")
        sha = await git(
            "-c",
            "user.name=Gongcao",
            "-c",
            "user.email=gongcao@localhost",
            "-c",
            "commit.gpgSign=false",
            "commit-tree",
            tree,
            *(["-p", parent] if parent else []),
            "-m",
            f"Evidence {key}",
        )
        payload = {
            "sha": sha,
            "branch": branch,
            "path": prefix,
            "url": f"https://github.com/{task['snapshot']['repository']}/tree/{sha}/{prefix}",
            "hashes": {
                name: hashlib.sha256(value.encode()).hexdigest() for name, value in files.items()
            },
        }
        remote.store.record(task, "archive-prepared", key, payload)

    async def readback() -> dict[str, Any] | None:
        return await observe(task, payload, remote.github)

    async def write() -> dict[str, Any]:
        await command(
            "git",
            "push",
            "origin",
            f"{payload['sha']}:refs/heads/{payload['branch']}",
            cwd=task["repo_path"],
        )
        return payload

    confirmed = await remote.perform(task, "archive", key, payload, readback, write)
    remote.store.record(task, "archive", result["plan_hash"], confirmed)
    for number in {task["snapshot"]["number"], task["pr_number"]} - {None}:
        endpoint = f"repos/{task['snapshot']['repository']}/issues/{number}/comments"
        body = f"Gongcao evidence ({key}): {confirmed['url']}"

        async def linked(endpoint: str = endpoint, body: str = body) -> dict[str, Any] | None:
            return await observe_link({"endpoint": endpoint, "body": body}, remote.github)

        async def link(endpoint: str = endpoint, body: str = body) -> dict[str, Any]:
            return await remote.github.mutate(endpoint, {"body": body})

        await remote.perform(
            task,
            "archive-link",
            f"{key}:{number}",
            {"endpoint": endpoint, "body": body},
            linked,
            link,
        )
    return confirmed
