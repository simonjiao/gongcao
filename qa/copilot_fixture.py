"""Offline CLI protocol fixture. GitHub/model substitutes are NOT real QA evidence."""

import json
import os
import sys
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from gongcao import remote
from gongcao.cli import main as native_main
from gongcao.github import GitHub, Target, command
from gongcao.sandbox import Sandbox

WORKER = """
import json,pathlib,sys,uuid
data=json.loads(sys.stdin.readline())['context']
if data['role']=='developer': pathlib.Path('/workspace/sample.txt').write_text('complete\\n')
print(json.dumps({'kind':'thread','data':{'thread_id':str(uuid.uuid4())}}))
print(json.dumps({'kind':'result','data':{
    'conclusion':'ready','summary':'Offline protocol result',
    'basis':['Fixture only'],'target_sha':data['target_sha'],'next_steps':['Check gates']}}))
"""


class OfflineGitHub(GitHub):
    def __init__(self, path: Path):
        self.path = path
        self.data: dict[str, Any] = json.loads(path.read_text())

    def save(self) -> None:
        self.data["comments"] = json.loads(self.path.read_text()).get("comments", [])
        self.path.write_text(json.dumps(self.data))

    async def instructions(self, task: dict[str, Any]) -> list[dict[str, Any]]:
        number = Target.parse(task["url"]).number
        data = json.loads(self.path.read_text())
        return list(data.get("comments", [])) + [
            row for row in data.get("status_comments", []) if row["issue"] == number
        ]

    async def head(self) -> str:
        return (
            await command(
                "git",
                "--git-dir",
                self.data["bare"],
                "rev-parse",
                "refs/heads/" + self.data["pull"]["head_ref"],
            )
        ).strip()

    async def snapshot(self, target: Target) -> dict[str, Any]:
        if target.kind == "issues":
            rows = self.data.get("issues", [self.data["issue"]])
            return dict(next(row for row in rows if row["number"] == target.number))
        return dict(self.data["pull"]) | {"head_sha": await self.head()}

    async def read(self, path: str) -> Any:
        if path == "user":
            return {"login": "owner"}
        if "/issues/comments/" in path:
            return next(
                row
                for row in self.data["status_comments"]
                if row["id"] == int(path.rsplit("/", 1)[1])
            )
        if "/issues/" in path:
            return await self.snapshot(
                Target("example/demo", "issues", int(path.rsplit("/", 1)[1]))
            )
        return (
            {"object": {"sha": self.data["sha"]}}
            if "/git/ref/" in path
            else {"default_branch": "main"}
        )

    async def pages(self, path: str, field: str | None = None) -> list[dict[str, Any]]:
        route = urlparse(path).path
        if route.endswith("/timeline"):
            return []
        if route.endswith("/labels"):
            number = int(route.split("/issues/")[1].split("/")[0])
            return (await self.snapshot(Target("example/demo", "issues", number))).get("labels", [])  # type: ignore[no-any-return]
        if route.endswith("/issues"):
            return list(self.data.get("issues", []))
        if "/reviews" in path:
            return self.data["reviews"]  # type: ignore[no-any-return]
        if "/comments" in path:
            number = int(route.split("/issues/")[1].split("/")[0])
            return await self.instructions(
                {"url": f"https://github.com/example/demo/issues/{number}"}
            )
        if not self.data.get("pull"):
            return []
        pull = self.data["pull"]
        return [
            {
                "number": 9,
                "state": "open",
                "body": pull["body"],
                "head": {"sha": await self.head()},
                "base": {"ref": "main"},
            }
        ]

    async def mutate(
        self, path: str, payload: dict[str, Any], *, method: str = "POST"
    ) -> dict[str, Any]:
        self.data["writes"].append({"path": path, "payload": payload})
        if "/comments" in path:
            rows = self.data.setdefault("status_comments", [])
            if method == "POST":
                result = {
                    "id": 100 + len(rows),
                    "issue": int(path.split("/issues/")[1].split("/")[0]),
                    "user": {"login": "owner"},
                    **payload,
                }
                rows.append(result)
            else:
                result = next(row for row in rows if row["id"] == int(path.rsplit("/", 1)[1]))
                result.update(payload)
        elif path.endswith("/reviews"):
            result = payload | {"id": len(self.data["reviews"]) + 1, "state": "COMMENTED"}
            self.data["reviews"].append(result)
        else:
            self.data["pull"] = self.data["issue"] | {
                "url": "https://github.com/example/demo/pull/9",
                "kind": "pull",
                "number": 9,
                "body": payload["body"],
                "base_ref": "main",
                "base_sha": self.data["sha"],
                "base_repository": "example/demo",
                "head_repository": "example/demo",
                "head_ref": payload["head"],
                "draft": True,
                "merged": False,
                "author": "fixture",
            }
            result = {"number": 9}
        self.save()
        return result

    async def gates(self, task: dict[str, Any]) -> dict[str, Any]:
        sha = await self.head()
        return {
            "headRefOid": sha,
            "isDraft": self.data["pull"]["draft"],
            "reviewDecision": "",
            "mergeable": "MERGEABLE",
            "mergeStateStatus": "CLEAN",
            "workflows": [
                {
                    "id": 1,
                    "run_attempt": 1,
                    "head_sha": sha,
                    "event": "pull_request",
                    "head_branch": self.data["pull"]["head_ref"],
                    "path": ".github/workflows/ci.yml",
                    "status": "completed",
                    "conclusion": "success",
                    "target_proof": {
                        "pr_number": 9,
                        "repository": "example/demo",
                        "head_sha": sha,
                        "base_sha": self.data["sha"],
                        "base_ref": "main",
                        "run_id": 1,
                        "attempt": 1,
                    },
                }
            ],
        }


def main() -> None:
    import gongcao.cli as cli

    fixture = OfflineGitHub(Path(os.environ["GONGCAO_COPILOT_FIXTURE"]))
    original_argv = Sandbox.argv

    def argv(self: Sandbox, *payload: str) -> list[str]:
        if payload[1:3] == ("-m", "gongcao.worker"):
            worker = ("import time; time.sleep(3)\n" if fixture.data.get("slow") else "") + WORKER
            payload = (sys.executable, "-c", worker)
        return original_argv(self, *payload)

    async def routed(*args: str, **kwargs: Any) -> str:
        if args[:2] in {("git", "push"), ("git", "ls-remote")}:
            args = (*args[:2], fixture.data["bare"], *args[3:])
        if args[:3] == ("gh", "pr", "ready"):
            fixture.data["pull"]["draft"] = False
            fixture.data["writes"].append({"path": "ready"})
            fixture.save()
            return "ready"
        if args[0] == "gh":
            raise ValueError("Offline fixture forbids real GitHub access")
        return await command(*args, **kwargs)

    cli.GitHub = lambda: fixture  # type: ignore[attr-defined,assignment]
    remote.command = routed  # type: ignore[attr-defined]
    Sandbox.argv = argv  # type: ignore[method-assign]
    native_main()


if __name__ == "__main__":
    main()
