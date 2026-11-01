"""Bounded JSONL events and common secret redaction before any persistence."""

import json
import logging
import re
import time
from collections.abc import Iterator
from contextlib import contextmanager
from typing import Any

from .store import Store

LOG = logging.getLogger("gongcao.progress")
STAGES = {
    "pending_analysis": "分析",
    "pending_development": "开发",
    "pending_revision": "修订",
    "pending_review": "审查",
    "pending_validation": "验证",
    "mergeable": "等待人工合并",
    "merged": "已合并",
}
STATES = {
    "queued": "排队",
    "running": "执行中",
    "waiting_dependency": "等待依赖",
    "waiting_environment": "缺少环境",
    "waiting_instruction": "暂停等待指令",
    "needs_reconciliation": "待核对",
    "needs_human": "待人工处理",
    "failed": "失败",
    "completed": "本次执行结束",
    "cancelled": "已取消",
}


class TerminalFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        text = Redactor().text(super().format(record))
        return re.sub(r"[\x00-\x1f\x7f]", lambda m: repr(m[0])[1:-1], text)


@contextmanager
def terminal_logging(handler: logging.Handler | None = None) -> Iterator[None]:
    logger = logging.getLogger("gongcao")
    handler = handler if handler is not None else logging.StreamHandler()
    handler.setFormatter(
        TerminalFormatter("%(asctime)s %(levelname)s %(message)s", "%Y-%m-%d %H:%M:%S")
    )
    old_level, old_propagate = logger.level, logger.propagate
    logger.setLevel(logging.INFO)
    logger.propagate = False
    logger.addHandler(handler)
    try:
        yield
    finally:
        logger.removeHandler(handler)
        handler.close()
        logger.setLevel(old_level)
        logger.propagate = old_propagate


def task_event(store: Store, task_id: int, message: str) -> None:
    task = store.task(task_id)
    LOG.info(
        "[%s #%s / 任务%s] %s",
        task["snapshot"]["repository"],
        task["snapshot"]["number"],
        task_id,
        message,
    )
    store.last_activity = time.monotonic()


def progress(store: Store, task_id: int) -> None:
    task = store.task(task_id)
    current = (task["stage"], task["state"], task["pr_number"])
    if store.reported.get(task_id) == current:
        return
    previous = store.reported.get(task_id)
    store.reported[task_id] = current
    task_event(store, task_id, f"阶段：{STAGES[task['stage']]}；状态：{STATES[task['state']]}")
    if task["pr_number"] and (previous is None or previous[2] != task["pr_number"]):
        task_event(
            store,
            task_id,
            f"PR 已远端确认：https://github.com/{task['snapshot']['repository']}/pull/{task['pr_number']}",
        )


TOKEN = re.compile(
    r"(?:github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9_]+|(?<![A-Za-z0-9_])sk-[A-Za-z0-9_-]{12,}"
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
    def __init__(
        self, store: Store, run_id: str, limit: int, redactor: Redactor, *, local: bool = False
    ):
        self.store, self.run_id, self.limit, self.redactor = store, run_id, limit, redactor
        self.local = local
        self.execution: dict[str, Any] | None = None
        self.thread_id: str | None = None
        directory = store.root / "logs"
        directory.mkdir(exist_ok=True, mode=0o700)
        self.path = directory / f"{run_id}.jsonl"

    def emit(self, kind: str, data: Any, *, controller: bool = False) -> None:
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
        if not self.local:
            self.store.event(self.run_id, kind, str(record["data"]))
        if controller and kind in {"started", "ended"}:
            run = next(r for r in self.store.runs(data["task_id"]) if r["id"] == self.run_id)
            report = json.loads(run["result"]) if run["result"] else {}
            conclusion = report.get("conclusion", "unavailable")
            if conclusion not in {"ready", "revise", "blocked", "failed"}:
                conclusion = "unavailable"
            task_event(
                self.store,
                data["task_id"],
                f"Agent {run['role']} {'开始' if kind == 'started' else '结束'}；"
                f"结果：{conclusion}",
            )
            progress(self.store, data["task_id"])
