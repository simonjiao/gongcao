import subprocess

from gongcao.github import GitHub


class ReadOnlyGitHub(GitHub):
    def __init__(self, snapshot):
        self.value = snapshot

    async def snapshot(self, target):
        return dict(self.value)


class FixtureGitHub(GitHub):
    def __init__(self, snapshot, sha, bare):
        self.issue = dict(snapshot)
        self.sha, self.bare = sha, bare
        self.pull = None
        self.reviews = []
        self.ci = "success"
        self.decision = ""
        self.writes = []
        self.head_override = None

    def head(self):
        if self.head_override:
            return self.head_override
        if self.pull:
            return subprocess.check_output(
                [
                    "git",
                    "--git-dir",
                    str(self.bare),
                    "rev-parse",
                    f"refs/heads/{self.pull['head_ref']}",
                ],
                text=True,
            ).strip()
        return self.sha

    async def snapshot(self, target):
        if target.kind == "issues":
            return dict(self.issue)
        return self.pull | {"head_sha": self.head()}

    async def read(self, path):
        return {"object": {"sha": self.sha}} if "/git/ref/" in path else {"default_branch": "main"}

    async def pages(self, path, field=None):
        if "/reviews" in path:
            return list(self.reviews)
        if self.pull:
            return [
                {
                    "number": 9,
                    "state": self.pull["state"],
                    "body": self.pull["body"],
                    "head": {"sha": self.head()},
                    "base": {"ref": "main"},
                }
            ]
        return []

    async def mutate(self, path, payload):
        if path == "graphql":
            self.pull["draft"] = False
            return {"data": {}}
        self.writes.append((path, payload))
        if path.endswith("/reviews"):
            self.reviews.append(payload | {"id": len(self.reviews) + 1})
            return {"id": len(self.reviews)}
        self.pull = self.issue | {
            "url": "https://github.com/example/demo/pull/9",
            "kind": "pull",
            "number": 9,
            "node_id": "PR_fixture",
            "body": payload["body"],
            "base_ref": "main",
            "base_sha": self.sha,
            "base_repository": "example/demo",
            "head_repository": "example/demo",
            "head_ref": payload["head"],
            "draft": True,
            "merged": False,
            "author": "same-account",
        }
        return {"number": 9}

    async def gates(self, task):
        return {
            "headRefOid": self.head(),
            "isDraft": self.pull["draft"],
            "reviewDecision": self.decision,
            "mergeable": "MERGEABLE",
            "mergeStateStatus": "CLEAN" if not self.decision else "BLOCKED",
            "workflows": [
                {
                    "id": 1,
                    "run_attempt": 1,
                    "head_sha": self.head(),
                    "event": "pull_request",
                    "path": ".github/workflows/ci.yml",
                    "head_branch": self.pull["head_ref"],
                    "status": "completed" if self.ci else "in_progress",
                    "conclusion": self.ci,
                    "target_proof": {
                        "pr_number": 9,
                        "repository": "example/demo",
                        "head_sha": self.head(),
                        "base_sha": self.pull["base_sha"],
                        "base_ref": self.pull["base_ref"],
                        "run_id": 1,
                        "attempt": 1,
                    },
                }
            ],
        }


class RegisteredGitHub(GitHub):
    def __init__(self, store):
        self.store = store
        self.review_rows = []
        self.writes = 0

    async def snapshot(self, target):
        return next(dict(t["snapshot"]) for t in self.store.tasks() if t["url"] == target.url)

    async def pages(self, path, field=None):
        return self.review_rows

    async def mutate(self, path, payload):
        self.writes += 1
        raise AssertionError("Recovery must never write remotely")
