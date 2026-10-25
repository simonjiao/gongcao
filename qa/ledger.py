"""Private, atomic resource inventories survive controller and QA interruptions."""

import fcntl
import hashlib
import json
import os
import re
import time
import uuid
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import Any

from gongcao.events import Redactor


class RunCancelled(Exception):
    """A user cancellation stops new scene work, while owned cleanup remains available."""


def digest(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def write_json(path: Path, value: Any) -> None:
    temporary = path.with_name(f".{path.name}-{uuid.uuid4().hex}")
    try:
        with temporary.open("x", encoding="utf-8") as stream:
            temporary.chmod(0o600)
            json.dump(Redactor().clean(value), stream, indent=2, ensure_ascii=False)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


class Run:
    def __init__(self, data: Path, run_id: str):
        if not re.fullmatch(r"[0-9a-f]{32}", run_id):
            raise ValueError("Expected a 32-character QA Run ID")
        self.root = data.resolve() / "runs" / run_id
        if self.root.is_symlink() or self.root.resolve() != self.root:
            raise ValueError("QA Run directory must not contain symlink components")
        self.path = self.root / "manifest.json"
        self.value: dict[str, Any] = json.loads(self.path.read_text())
        if self.value.get("schema") != 1 or self.value.get("id") != run_id:
            raise ValueError("Unsupported or mismatched QA manifest")

    @classmethod
    def create(cls, data: Path, scenario: str, implementation: str, **metadata: Any) -> "Run":
        run_id = uuid.uuid4().hex
        root = data.resolve() / "runs" / run_id
        root.mkdir(parents=True, mode=0o700)
        root.chmod(0o700)
        write_json(
            root / "manifest.json",
            {
                "schema": 1,
                "id": run_id,
                "scenario": scenario,
                "implementation_sha": implementation,
                "created": time.time(),
                "status": "queued",
                "events": [],
                "actions": {},
                "resources": {},
                **metadata,
            },
        )
        return cls(data, run_id)

    @property
    def id(self) -> str:
        return str(self.value["id"])

    @property
    def marker(self) -> str:
        return f"<!-- gongcao-qa:{self.id} -->"

    def save(self) -> None:
        write_json(self.path, self.value)

    def request_cancel(self) -> dict[str, Any]:
        current = json.loads(self.path.read_text())
        if current["status"] not in {"queued", "running"}:
            return {"run_id": self.id, "cancel_requested": False, "status": current["status"]}
        (self.root / "cancel-requested").touch(mode=0o600)
        current = json.loads(self.path.read_text())
        return {
            "run_id": self.id,
            "cancel_requested": current["status"] in {"queued", "running"},
            "status": current["status"],
        }

    def check_cancelled(self) -> None:
        if (self.root / "cancel-requested").exists():
            raise RunCancelled("QA Run cancelled by user")

    def event(self, kind: str, **data: Any) -> None:
        self.value["events"].append({"at": time.time(), "kind": kind, **data})
        self.save()

    def archive(self, name: str, value: Any) -> None:
        if not re.fullmatch(r"[a-z][a-z0-9-]*", name):
            raise ValueError("Invalid evidence name")
        path = self.root / f"{name}.json"
        write_json(path, value)
        self.value.setdefault("archives", {})[path.name] = hashlib.sha256(
            path.read_bytes()
        ).hexdigest()
        self.save()

    @contextmanager
    def lock(self) -> Iterator[None]:
        with (self.root / ".lock").open("a") as stream:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise ValueError("QA Run is active; request cancel before cleanup") from None
            try:
                yield
            finally:
                fcntl.flock(stream, fcntl.LOCK_UN)

    def check_archives(self) -> None:
        archives = self.value.get("archives", {})
        if not archives:
            raise ValueError("No independently verified evidence archived")
        for name, expected in archives.items():
            if not re.fullmatch(r"[a-z][a-z0-9-]*\.json", name):
                raise ValueError("Invalid archive path")
            if hashlib.sha256((self.root / name).read_bytes()).hexdigest() != expected:
                raise ValueError(f"Evidence changed: {name}")
