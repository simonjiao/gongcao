"""GitHub facts and low-level transport. Only the controller authorizes mutations."""

import asyncio
import json
import re
from dataclasses import dataclass
from typing import Any

from .events import Redactor
from .processes import completed, launch, stop


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
        return cls(match[1].lower(), match[2], int(match[3]))

    @property
    def url(self) -> str:
        return f"https://github.com/{self.repository}/{self.kind}/{self.number}"


async def command(*args: str, cwd: str | None = None, input_data: str | None = None) -> str:
    process = await launch(
        *args,
        cwd=cwd,
        stdin=asyncio.subprocess.PIPE if input_data is not None else None,
    )
    try:
        stdout, stderr = await asyncio.wait_for(
            process.communicate(input_data.encode() if input_data is not None else None), timeout=60
        )
    except BaseException:
        await stop(process)
        raise
    completed(process)
    if process.returncode:
        message = Redactor().text(stderr.decode(errors="replace"))[-2000:]
        if args[0] == "gh" and ("HTTP 403" in message or "HTTP 401" in message):
            raise PermissionError(message)
        if args[0] == "gh" and re.search(r"HTTP 5\d\d", message):
            raise ConnectionError(message)
        raise RuntimeError(message)
    return stdout.decode()


async def read_command(*args: str) -> str:
    """Retry only read transports; write ambiguity is owned by Controlled.perform."""
    attempts = 0
    while True:
        try:
            return await command(*args)
        except (RuntimeError, ConnectionError, TimeoutError) as exc:
            if not isinstance(exc, (ConnectionError, TimeoutError)) and not re.search(
                r"\bEOF\b|connection (reset|closed)|TLS handshake timeout|i/o timeout",
                str(exc),
                re.I,
            ):
                raise
            attempts += 1
            if attempts >= 3:
                raise ConnectionError(str(exc)) from exc
            await asyncio.sleep(0.25 * attempts)


class GitHub:
    async def read(self, path: str) -> Any:
        return json.loads(await read_command("gh", "api", path))

    async def pages(self, path: str, field: str | None = None) -> list[dict[str, Any]]:
        raw = (await read_command("gh", "api", "--paginate", path)).lstrip()
        pages = []
        decoder = json.JSONDecoder()
        while raw:
            page, end = decoder.raw_decode(raw)
            pages.append(page)
            raw = raw[end:].lstrip()
        return [item for page in pages for item in (page[field] if field else page)]

    async def mutate(
        self, path: str, payload: dict[str, Any], *, method: str = "POST"
    ) -> dict[str, Any]:
        response: dict[str, Any] = json.loads(
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
        )
        return response

    async def snapshot(self, target: Target) -> dict[str, Any]:
        resource = "issues" if target.kind == "issues" else "pulls"
        data = json.loads(
            await read_command("gh", "api", f"repos/{target.repository}/{resource}/{target.number}")
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

    async def instructions(self, task: dict[str, Any]) -> list[dict[str, Any]]:
        target = Target.parse(task["url"])
        if target.kind != "issues":
            return []
        return await self.pages(
            f"repos/{target.repository}/issues/{target.number}/comments?per_page=100"
        )

    async def labels(self, target: Target) -> list[str]:
        rows = await self.pages(
            f"repos/{target.repository}/issues/{target.number}/labels?per_page=100"
        )
        return [row["name"] for row in rows]

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
            await read_command(
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
        return data  # type: ignore[no-any-return]
