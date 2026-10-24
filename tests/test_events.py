import json

from gongcao.events import Journal, Redactor
from gongcao.model import Role


def test_redaction_preserves_usage_counts():
    clean = Redactor(["unique-model-credential"])
    data = clean.clean(
        {
            "access_token": "secret",
            "tokenUsage": {"totalTokens": 42},
            "command": "echo github_pat_abcdef123456 unique-model-credential",
            "output": "Authorization: Bearer opaque1234567",
        }
    )
    assert data["access_token"] == "[REDACTED]"
    assert data["tokenUsage"]["totalTokens"] == 42
    assert "abcdef" not in data["command"]
    assert "unique-model" not in data["command"]
    assert "opaque" not in data["output"]


def test_log_rotation_and_index_are_bounded(store, task_id):
    run_id = store.begin_run(task_id, Role.ANALYST)
    journal = Journal(store, run_id, 4096, Redactor())
    for _ in range(1100):
        journal.emit("tool", {"output": "x" * 120})
    files = list(journal.path.parent.glob("*"))
    assert len(files) == 2
    assert all(p.stat().st_size <= 4096 for p in files)
    assert store.db.execute("SELECT COUNT(*) FROM events").fetchone()[0] == 1000
    for file in files:
        for line in file.read_text().splitlines():
            json.loads(line)


def test_oversized_event_is_valid_json_and_secret_is_redacted(store, task_id):
    run_id = store.begin_run(task_id, Role.ANALYST)
    journal = Journal(store, run_id, 4096, Redactor(["a-secret-credential"]))
    journal.emit("tool", "a-secret-credential" + "💡" * 20000)
    record = json.loads(journal.path.read_text())
    assert record["data"]["truncated"]
    assert "a-secret-credential" not in journal.path.read_text()
