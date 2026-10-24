"""Bounded JSONL events and common secret redaction before any persistence."""

import json
import re
import time
from typing import Any

from .store import Store

TOKEN = re.compile(
    r"(?:github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]{12,}"
    r"|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"
    r"|(?i:bearer)\s+[A-Za-z0-9._~+/-]+=*)"
)
SECRET_KEY = re.compile(
    r"password|secret|authorization|api.?key|^(?:.*_)?(?:access_?token|refresh_?token|id_?token|token)$",
    re.I,
)


class Redactor:
    def __init__(self, secrets: list[str] | None = None):
        self.secrets = sorted([s for s in secrets or [] if len(s) >= 8], key=len, reverse=True)

    def text(self, value: str) -> str:
        for secret in self.secrets:
            value = value.replace(secret, "[REDACTED]")
        return TOKEN.sub("[REDACTED]", value)

    def clean(self, value: Any) -> Any:
        if isinstance(value, dict):
            return {
                k: "[REDACTED]" if SECRET_KEY.search(str(k)) else self.clean(v)
                for k, v in value.items()
            }
        if isinstance(value, list):
            return [self.clean(v) for v in value]
        if isinstance(value, str):
            return self.text(value)
        return value


class Journal:
    def __init__(self, store: Store, run_id: str, limit: int, redactor: Redactor):
        self.store, self.run_id, self.limit, self.redactor = store, run_id, limit, redactor
        directory = store.root / "logs"
        directory.mkdir(exist_ok=True, mode=0o700)
        self.path = directory / f"{run_id}.jsonl"

    def emit(self, kind: str, data: Any) -> None:
        record = self.redactor.clean(
            {
                "at": time.time(),
                "run_id": self.run_id,
                "kind": kind,
                "data": data,
            }
        )
        encoded = json.dumps(record, ensure_ascii=False)
        # Truncate one oversized event as valid JSON, never splice raw credentials or UTF-8.
        if len(encoded.encode()) > self.limit // 2:
            record["data"] = {"truncated": True, "preview": str(record["data"])[: self.limit // 16]}
            encoded = json.dumps(record, ensure_ascii=False)
        if self.path.exists() and self.path.stat().st_size + len(encoded.encode()) + 1 > self.limit:
            self.path.replace(self.path.with_suffix(".jsonl.1"))
        with self.path.open("a", encoding="utf-8") as stream:
            stream.write(encoded + "\n")
        self.store.event(self.run_id, kind, str(record["data"]))
