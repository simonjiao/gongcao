"""Offline CLI protocol fixture. GitHub/model substitutes are NOT real QA evidence."""

import json
import os
import sys
from pathlib import Path
from typing import Any

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
        self.path.write_text(json.dumps(self.data))

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
            return dict(self.data["issue"])
        return dict(self.data["pull"]) | {"head_sha": await self.head()}

    async def read(self, path: str) -> Any:
        return (
            {"object": {"sha": self.data["sha"]}}
            if "/git/ref/" in path
            else {"default_branch": "main"}
        )

    async def pages(self, path: str, field: str | None = None) -> list[dict[str, Any]]:
        if "/reviews" in path:
            return self.data["reviews"]  # type: ignore[no-any-return]
        if "/comments" in path:
            return []
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

    async def mutate(self, path: str, payload: dict[str, Any]) -> dict[str, Any]:
        self.data["writes"].append({"path": path, "payload": payload})
        if path.endswith("/reviews"):
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
            payload = (sys.executable, "-c", WORKER)
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
