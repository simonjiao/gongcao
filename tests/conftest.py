import subprocess
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
