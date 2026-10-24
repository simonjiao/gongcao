"""GitHub facts and low-level transport. Only the controller authorizes mutations."""

import asyncio
import hashlib
import json
import re
from dataclasses import dataclass
from datetime import datetime
from typing import Any

from .events import Redactor
from .processes import stop


@dataclass(frozen=True)
class Target:
    repository: str
    kind: str
    number: int

    @classmethod
    def parse(cls, url: str) -> "Target":
        match = re.fullmatch(
            r"https://github\.com/([\w.-]+/[\w.-]+)/(issues|pull)/([1-9][0-9]*)/?", url
        )
        if not match:
            raise ValueError("Expected https://github.com/OWNER/REPO/issues/N or /pull/N")
        return cls(match[1], match[2], int(match[3]))

    @property
    def url(self) -> str:
        return f"https://github.com/{self.repository}/{self.kind}/{self.number}"


async def command(*args: str, cwd: str | None = None, input_data: str | None = None) -> str:
    process = await asyncio.create_subprocess_exec(
        *args,
        cwd=cwd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        start_new_session=True,
        stdin=asyncio.subprocess.PIPE if input_data is not None else None,
    )
    try:
        stdout, stderr = await asyncio.wait_for(
            process.communicate(input_data.encode() if input_data is not None else None), timeout=60
        )
    except BaseException:
        await stop(process)
        raise
    if process.returncode:
        message = Redactor().text(stderr.decode(errors="replace")[-2000:])
        if args[0] == "gh" and ("HTTP 403" in message or "HTTP 401" in message):
            raise PermissionError(message)
        raise RuntimeError(message)
    return stdout.decode()


class GitHub:
    async def read(self, path: str) -> Any:
        return json.loads(await command("gh", "api", path))

    async def pages(self, path: str, field: str | None = None) -> list[dict[str, Any]]:
        raw = (await command("gh", "api", "--paginate", path)).lstrip()
        pages = []
        decoder = json.JSONDecoder()
        while raw:
            page, end = decoder.raw_decode(raw)
            pages.append(page)
            raw = raw[end:].lstrip()
        return [item for page in pages for item in (page[field] if field else page)]

    async def mutate(self, path: str, payload: dict[str, Any]) -> dict[str, Any]:
        response: dict[str, Any] = json.loads(
            await command(
                "gh",
                "api",
                "--method",
                "POST",
                path,
                "--input",
                "-",
                input_data=json.dumps(payload),
            )
        )
        return response

    async def snapshot(self, target: Target) -> dict[str, Any]:
        resource = "issues" if target.kind == "issues" else "pulls"
        data = json.loads(
            await command("gh", "api", f"repos/{target.repository}/{resource}/{target.number}")
        )
        if target.kind == "issues" and "pull_request" in data:
            raise ValueError("This is a pull request; register its /pull/N URL")
        snapshot = {
            "url": target.url,
            "repository": target.repository,
            "kind": target.kind,
            "number": target.number,
            "title": data["title"],
            "body": data.get("body") or "",
            "state": data["state"],
            "updated_at": data["updated_at"],
        }
        if target.kind == "pull":
            snapshot.update(
                {
                    "head_sha": data["head"]["sha"],
                    "base_sha": data["base"]["sha"],
                    "base_ref": data["base"]["ref"],
                    "base_repository": data["base"]["repo"]["full_name"],
                    "merged": data["merged"],
                    "head_repository": data["head"]["repo"]["full_name"],
                    "head_ref": data["head"].get("ref", ""),
                    "draft": data.get("draft", False),
                    "author": data.get("user", {}).get("login", ""),
                }
            )
        return Redactor().clean(snapshot)  # type: ignore[no-any-return]

    async def task_snapshot(self, task: dict[str, Any]) -> dict[str, Any]:
        target = Target.parse(task["url"])
        snapshot = await self.snapshot(target)
        if task.get("pr_number") and target.kind == "issues":
            pull = await self.snapshot(Target(target.repository, "pull", task["pr_number"]))
            snapshot.update(
                {
                    key: value
                    for key, value in pull.items()
                    if key not in {"url", "kind", "number", "title", "body", "state", "updated_at"}
                }
            )
            snapshot.update(pull_url=pull["url"], pull_title=pull["title"], pull_body=pull["body"])
            if pull["state"] != "open":
                snapshot["state"] = "closed"
        return snapshot

    async def gates(self, task: dict[str, Any]) -> dict[str, Any]:
        repository = task["snapshot"]["repository"]
        number = task["pr_number"]
        data = json.loads(
            await command(
                "gh",
                "pr",
                "view",
                str(number),
                "--repo",
                repository,
                "--json",
                "headRefOid,isDraft,reviewDecision,mergeStateStatus,mergeable,author",
            )
        )
        data["workflows"] = await self.pages(
            f"repos/{repository}/actions/runs?head_sha={task['target_sha']}&event=pull_request&per_page=100",
            "workflow_runs",
        )
        # Some workflow-run payloads omit pull_requests. Prove the actual checkout
        # belongs to this PR and has exactly the current base/head merge parents.
        for run in data["workflows"]:
            if run["status"] == "completed":
                try:
                    run["target_proof"] = await self.checkout_proof(task, run)
                except (RuntimeError, OSError, ValueError) as exc:
                    run["target_proof"] = None
                    run["proof_error"] = Redactor().text(f"{type(exc).__name__}: {exc}")
        return data  # type: ignore[no-any-return]

    async def checkout_proof(
        self, task: dict[str, Any], run: dict[str, Any]
    ) -> dict[str, Any] | None:
        repository = task["snapshot"]["repository"]
        attempt = run.get("run_attempt", 1)
        timeline = await self.pages(
            f"repos/{repository}/issues/{task['pr_number']}/timeline?per_page=100"
        )
        base_changes = [
            event
            for event in timeline
            if event.get("event") in {"base_ref_changed", "automatic_base_change_succeeded"}
        ]
        created = datetime.fromisoformat(run["created_at"].replace("Z", "+00:00"))
        if any(
            created <= datetime.fromisoformat(event["created_at"].replace("Z", "+00:00"))
            for event in base_changes
        ):
            return None
        jobs = await self.pages(
            f"repos/{repository}/actions/runs/{run['id']}/attempts/{attempt}/jobs?per_page=100",
            "jobs",
        )
        for job in sorted(jobs, key=lambda item: item["conclusion"] != "failure"):
            if not any(
                "actions/checkout@" in step["name"] and step["conclusion"] == "success"
                for step in (job.get("steps") or [])
            ):
                continue
            log = await command("gh", "api", f"repos/{repository}/actions/jobs/{job['id']}/logs")
            sha = checkout_sha(log, task["pr_number"])
            if sha is None:
                continue
            commit = await self.read(f"repos/{repository}/git/commits/{sha}")
            parents = [parent["sha"] for parent in commit["parents"]]
            if parents != [task["snapshot"]["base_sha"], task["target_sha"]]:
                continue
            proof = {
                "pr_number": task["pr_number"],
                "repository": repository,
                "base_sha": parents[0],
                "head_sha": parents[1],
                "base_ref": task["snapshot"]["base_ref"],
                "base_ref_basis": "current ref + complete retarget history before run creation",
                "run_created_at": run["created_at"],
                "last_base_change": max((e["created_at"] for e in base_changes), default=None),
                "timeline_sha256": hashlib.sha256(
                    json.dumps(timeline, sort_keys=True).encode()
                ).hexdigest(),
                "checkout_sha": sha,
                "run_id": run["id"],
                "attempt": attempt,
                "job_id": job["id"],
                "source": "actions/checkout job log + GitHub commit parents",
                "log_sha256": hashlib.sha256(log.encode()).hexdigest(),
            }
            if run.get("conclusion") != "success" and job["conclusion"] == "failure":
                proof["failure_tail"] = Redactor().text(
                    log.encode()[-20000:].decode(errors="replace")
                )
                proof["failure_tail_truncated"] = len(log.encode()) > 20000
            return proof
        return None


def checkout_sha(log: str, number: int) -> str | None:
    """Only accept checkout's own PR merge ref and following full git-log SHA."""
    block = False
    ref = False
    expect_sha = False
    for line in log.splitlines():
        if "##[group]Run actions/checkout@" in line:
            block, ref, expect_sha = True, False, False
        elif block and "##[group]Run " in line:
            block = False
        if not block:
            continue
        if re.search(rf"\[command\].*git checkout .* refs/remotes/pull/{number}/merge$", line):
            ref = True
        if ref and re.search(r"\[command\].*git log -1 --format=%H$", line):
            expect_sha = True
            continue
        if expect_sha:
            match = re.fullmatch(r"\S+Z ([0-9a-f]{40})", line)
            return match[1] if match else None
    return None
