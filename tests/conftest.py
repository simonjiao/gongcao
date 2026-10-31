import asyncio
import hashlib
import subprocess
import sys
from collections import Counter
from copy import deepcopy
from dataclasses import replace
from pathlib import Path

import pytest


@pytest.fixture
def repo(tmp_path):
    path = tmp_path / "repo"
    path.mkdir()
    subprocess.run(["git", "init", "-q", str(path)], check=True)
    subprocess.run(["git", "config", "user.email", "tests@example.invalid"], cwd=path, check=True)
    subprocess.run(["git", "config", "user.name", "Gongcao Test"], cwd=path, check=True)
    subprocess.run(
        ["git", "remote", "add", "origin", "https://github.com/example/demo.git"],
        cwd=path,
        check=True,
    )
    (path / "AGENTS.md").write_text("Only work on the registered task.\n")
    (path / "sample.txt").write_text("original\n")
    (path / "Makefile").write_text(
        "check:\n\tpython3 -c \"assert open('sample.txt').read()\"\n"
        "test:\n\tpython3 -c \"assert open('sample.txt').read()\"\n"
        "test-e2e:\n\tpython3 -c \"assert open('sample.txt').read().strip() == 'complete'\"\n"
    )
    subprocess.run(["git", "add", "."], cwd=path, check=True)
    subprocess.run(["git", "commit", "-qm", "fixture"], cwd=path, check=True)
    return path


@pytest.fixture
def sha(repo):
    return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()


@pytest.fixture
def snapshot():
    return {
        "url": "https://github.com/example/demo/issues/1",
        "repository": "example/demo",
        "kind": "issues",
        "number": 1,
        "title": "Test request",
        "body": "Analyze sample.txt",
        "state": "open",
        "updated_at": "2026-10-24T00:00:00Z",
    }


@pytest.fixture
def store(tmp_path):
    from gongcao.store import Store

    instance = Store(tmp_path / "state")
    yield instance
    instance.close()


@pytest.fixture
def task_id(store, repo, sha, snapshot):
    return store.register(snapshot["url"], repo, sha, snapshot)


@pytest.fixture
def auth_file(tmp_path) -> Path:
    path = tmp_path / "model-auth.json"
    path.write_text('{"OPENAI_API_KEY":"sk-test-credential-not-real-1234567890"}')
    return path


@pytest.fixture
def planned_quality(store, task_id):
    from gongcao.config import Config
    from gongcao.quality import Quality

    def prepare(argv):
        quality = Quality(store, Config())
        quality.confirm(
            store.task(task_id),
            [
                {
                    "category": category,
                    "entry": argv if category == "build" else [],
                    "scope": ["."],
                    "required": category == "build",
                    "environment": "sandbox",
                    "reason": "Execution probe; other categories are not applicable",
                }
                for category in ("build", "internal", "e2e")
            ],
        )
        return quality

    return prepare


@pytest.fixture
def fixture_github(tmp_path, repo, sha, snapshot, monkeypatch):
    from _support.github import FixtureGitHub
    from _support.worker import WORKER, install_worker

    from gongcao.github import command

    bare = tmp_path / "remote.git"
    subprocess.run(["git", "clone", "--bare", "--quiet", str(repo), str(bare)], check=True)
    github = FixtureGitHub(snapshot, sha, bare)

    async def routed(*args, **kwargs):
        if args[:2] in {("git", "push"), ("git", "ls-remote"), ("git", "fetch")}:
            args = (*args[:2], str(bare), *args[3:])
        if args[:3] == ("gh", "pr", "ready"):
            github.pull["draft"] = False
            return "ready"
        return await command(*args, **kwargs)

    monkeypatch.setattr("gongcao.remote.command", routed)
    monkeypatch.setattr("gongcao.recovery.command", routed)
    install_worker(monkeypatch, WORKER)
    return github


@pytest.fixture
def policy(auth_file):
    from gongcao.config import Config

    return Config(auth_file=auth_file)


@pytest.fixture
def intake(store, repo, sha, snapshot):
    from gongcao.config import Config, DiscoveryConfig, Source
    from gongcao.discovery import Discovery
    from gongcao.github import Deferred, GitHub

    name = "example/discovery-" + hashlib.sha256(str(store.root).encode()).hexdigest()[:12]
    snapshot.update(repository=name, url=f"https://github.com/{name}/issues/1")
    subprocess.run(
        ["git", "remote", "set-url", "origin", f"https://github.com/{name}.git"],
        cwd=repo,
        check=True,
    )

    class API(GitHub):
        def __init__(self):
            self.rows = {
                n: snapshot
                | {
                    "number": n,
                    "url": snapshot["url"][:-1] + str(n),
                    "labels": [{"name": "agent-ready"}],
                    "assignees": [],
                }
                for n in range(1, 7)
            }
            self.rows[2]["pull_request"] = {}
            self.rows[3]["labels"] = [{"name": "agent-ready-extra"}]
            self.comments, self.writes, self.failure = [], [], ""
            self.sha = sha
            self.branch = "main"
            self.calls = Counter()

        async def read(self, path):
            self.calls["read"] += 1
            if path == "user":
                return {"login": "owner"}
            if "/comments/" in path:
                item = deepcopy(
                    next(c for c in self.comments if c["id"] == int(path.rsplit("/", 1)[1]))
                )
                # Real GitHub list/detail payloads use different avatar URL variants.
                item["user"]["avatar_url"] = "https://avatars.example/variant"
                return item
            if "/issues/" in path:
                return deepcopy(self.rows[int(path.rsplit("/", 1)[1])])
            current = self.sha if path.endswith("/" + self.branch) else sha
            return (
                {"object": {"sha": current}}
                if "/git/ref/" in path
                else {"default_branch": self.branch}
            )

        async def snapshot(self, target):
            return deepcopy(self.rows[target.number])

        async def pages(self, path, field=None):
            self.calls["pages"] += 1
            if self.failure in {"403", "429"}:
                raise PermissionError("HTTP " + self.failure)
            if "/labels" in path:
                return self.rows[int(path.split("/issues/")[1].split("/")[0])]["labels"]
            if "/timeline" in path:
                return (
                    [{"source": {"issue": {"pull_request": {"url": "handled"}}}}]
                    if "/4/" in path
                    else []
                )
            if "/comments" in path:
                return deepcopy(self.comments)
            return list(reversed(list(self.rows.values())))

        async def mutate(self, path, payload, *, method="POST"):
            self.writes.append(method)
            if self.failure == "limited":
                raise Deferred("HTTP 429: rejected")
            if self.failure == "absent":
                raise ConnectionError("POST result unknown")
            if method == "POST":
                self.comments.append(
                    {"id": len(self.comments) + 1, "user": {"login": "owner"}, **payload}
                )
            else:
                self.comments[0].update(payload)
            if self.failure == "lost":
                raise ConnectionError("Reply lost after remote write")
            if self.failure == "interrupted":
                raise asyncio.CancelledError
            return deepcopy(self.comments[-1])

    config = replace(Config(), discovery=DiscoveryConfig(True, 60, 1, (Source(name, repo),)))
    return Discovery(store, config, API())


@pytest.fixture(scope="module")
def checkout(tmp_path_factory):
    root = tmp_path_factory.mktemp("jobs-offline")
    path = root / "checkout"
    subprocess.run(
        ["git", "clone", "-q", "--local", str(Path(__file__).resolve().parents[1]), str(path)],
        check=True,
    )
    # Only the external gh boundary is substituted. API reads wait on an observable
    # barrier, then report closed targets so the real CLI cannot start an Agent.
    binary = root / "bin"
    binary.mkdir()
    gh = binary / "gh"
    gh.write_text(
        f"#!{sys.executable}\n"
        "import fcntl,json,os,pathlib,sys,time\n"
        "if sys.argv[1:]==['--version']:\n"
        "    print('gh offline protocol fixture');sys.exit(0)\n"
        "gate=pathlib.Path(os.environ['JOBS_TEST_GATE'])\n"
        "def event(kind):\n"
        "    with (gate/'calls.jsonl').open('a') as out:\n"
        "        fcntl.flock(out,fcntl.LOCK_EX)\n"
        "        out.write(json.dumps({'kind':kind,'argv':sys.argv[1:]})+'\\n')\n"
        "event('started')\n"
        "assert len(sys.argv)==4 and sys.argv[1]=='api' and sys.argv[3]=='--include'\n"
        "assert sys.argv[2].startswith('repos/example/demo/issues/')\n"
        "deadline=time.monotonic()+30\n"
        "while not (gate/'release').exists() and time.monotonic()<deadline: time.sleep(.01)\n"
        "assert (gate/'release').exists(),'offline barrier timed out'\n"
        "event('released')\n"
        "print(json.dumps({'title':'offline','body':'','state':'closed',"
        "'updated_at':'2026-10-25T00:00:00Z'}))\n"
    )
    gh.chmod(0o700)
    return path
