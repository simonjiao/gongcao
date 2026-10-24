"""Read-only GitHub adapter; there are deliberately no mutation methods in PR1."""

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


async def command(*args: str, cwd: str | None = None) -> str:
    process = await asyncio.create_subprocess_exec(
        *args,
        cwd=cwd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        start_new_session=True,
    )
    try:
        stdout, stderr = await asyncio.wait_for(process.communicate(), timeout=60)
    except BaseException:
        await stop(process)
        raise
    if process.returncode:
        raise RuntimeError(Redactor().text(stderr.decode(errors="replace")[-2000:]))
    return stdout.decode()


class GitHub:
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
                }
            )
        return Redactor().clean(snapshot)  # type: ignore[no-any-return]
