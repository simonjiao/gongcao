"""GitHub facts and low-level transport. Only the controller authorizes mutations."""

import asyncio
import json
import re
from dataclasses import dataclass
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
        raise RuntimeError(Redactor().text(stderr.decode(errors="replace")[-2000:]))
    return stdout.decode()


class GitHub:
    async def read(self, path: str) -> Any:
        return json.loads(await command("gh", "api", path))

    async def pages(self, path: str, field: str | None = None) -> list[dict[str, Any]]:
        pages = json.loads(await command("gh", "api", "--paginate", "--slurp", path))
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
        return data  # type: ignore[no-any-return]
