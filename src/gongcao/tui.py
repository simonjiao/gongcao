"""Local, read-only serve display; refreshes on the scheduler's asyncio loop."""

import asyncio
import logging
import os
import re
import sys
import time
from bisect import insort
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager, suppress

from rich.console import Console
from rich.layout import Layout
from rich.live import Live
from rich.panel import Panel
from rich.text import Text

from .events import STAGES, STATES, Redactor, terminal_logging
from .model import State
from .store import Store

ACTIVITY = {
    "turn/started": "Agent 本轮处理开始",
    "turn/plan/updated": "Agent 执行计划更新",
    "item/started": "Agent 工作项开始",
    "item/completed": "Agent 工作项结束",
    "turn/completed": "Agent 本轮处理结束",
}


class Dashboard(logging.Handler):
    def __init__(self, store: Store):
        super().__init__()
        self.store = store
        self.records: list[tuple[float, str]] = []
        self.event_id = store.db.execute("SELECT COALESCE(MAX(id),0) FROM events").fetchone()[0]

    def emit(self, record: logging.LogRecord) -> None:
        insort(self.records, (record.created, self.format(record)[:2000]), key=lambda r: r[0])
        del self.records[:-150]

    def render(self, width: int, height: int) -> Layout:
        tasks = self.store.tasks()
        by_id = {task["id"]: task for task in tasks}
        rows = self.store.db.execute(
            "SELECT e.id,e.at,e.kind,substr(e.summary,1,80) AS header,r.task_id "
            "FROM events e JOIN runs r ON r.id=e.run_id WHERE e.id>? ORDER BY e.id DESC LIMIT 150",
            (self.event_id,),
        ).fetchall()
        for row in reversed(rows):
            self.event_id = row["id"]
            # Journal stores a truncated Python repr; read only its leading method field.
            method = re.match(r"\{'method': '([^']+)',", row["header"])
            activity = ACTIVITY.get(method[1]) if method and row["kind"] == "sdk_event" else None
            if activity is None:
                continue
            task = by_id[row["task_id"]]
            snapshot = task["snapshot"]
            record = logging.LogRecord(
                "gongcao",
                logging.INFO,
                "",
                0,
                f"[{snapshot['repository']} #{snapshot['number']} / 任务{task['id']}] {activity}",
                (),
                None,
            )
            record.created = row["at"]
            self.emit(record)
        runs = {
            row["task_id"]: row
            for row in self.store.db.execute(
                "SELECT r.task_id,r.started,(SELECT at FROM events WHERE run_id=r.id "
                "ORDER BY id DESC LIMIT 1) AS activity FROM runs r WHERE r.state='running'"
            )
        }
        counts = {state: sum(t["state"] == state for t in tasks) for state in State}
        waiting = sum(count for state, count in counts.items() if state.startswith("waiting_"))
        attention = counts[State.HUMAN] + counts[State.RECONCILE] + counts[State.FAILED]
        lines = [
            f"执行 {counts[State.RUNNING]} | 等待 {waiting} | 待处理 {attention}"
            f" | 排队 {counts[State.QUEUED]}"
        ]
        tasks.sort(key=lambda t: (t["state"] != State.RUNNING, t["id"]))
        limit = max(0, min(8, height // 2 - 3))
        now = time.time()
        for task in tasks[:limit]:
            snapshot = task["snapshot"]
            repository = snapshot["repository"]
            if width < 85:
                repository = repository.rsplit("/", 1)[-1]
            label = Redactor().text(f"{repository} #{snapshot['number']}")
            line = f"{label}  {STAGES[task['stage']]}"
            if width >= 85 or task["state"] != State.RUNNING:
                line += f" / {STATES[task['state']]}"
            if run := runs.get(task["id"]):
                seconds = max(0, int(now - run["started"]))
                line += f"  已运行 {seconds // 60}m {seconds % 60}s"
                line += (
                    f"  最近事件 {max(0, int(now - run['activity']))}s 前"
                    if run["activity"] is not None
                    else "  暂无新事件"
                )
            elif task["state"] == State.RUNNING:
                line += "  时长未记录；暂无新事件（无 Agent Run）"
            lines.append(line)
        if len(tasks) > limit:
            lines.append(f"另有 {len(tasks) - limit} 项；详情见 gongcao status / inspect")
        overview_height = min(height - 3, len(lines) + 2)
        recent = [text for _, text in self.records[-max(1, height - overview_height - 2) :]]
        layout = Layout()
        layout.split_column(
            Layout(
                Panel(
                    Text("\n".join(lines), no_wrap=True, overflow="ellipsis"),
                    title="Gongcao · serve",
                ),
                size=max(1, overview_height),
            ),
            Layout(
                Panel(
                    Text("\n".join(recent) or "暂无新日志", no_wrap=True, overflow="ellipsis"),
                    title="最近日志 · 完整记录见 gongcao logs",
                )
            ),
        )
        return layout


@asynccontextmanager
async def serve_display(store: Store, *, enabled: bool) -> AsyncIterator[None]:
    console = Console(stderr=True)
    interactive = (
        enabled
        and sys.stderr.isatty()
        and console.is_terminal
        and not console.is_dumb_terminal
        and os.environ.get("TERM") != "dumb"
    )
    if not interactive:
        with terminal_logging():
            yield
        return
    view = Dashboard(store)
    with terminal_logging(view):
        try:
            with Live(
                console=console,
                screen=True,
                auto_refresh=False,
                redirect_stdout=False,
                redirect_stderr=False,
            ) as live:

                async def refresh() -> None:
                    while True:
                        live.update(view.render(console.width, console.height), refresh=True)
                        await asyncio.sleep(1)

                refresh_task = asyncio.create_task(refresh())
                try:
                    yield
                finally:
                    refresh_task.cancel()
                    with suppress(asyncio.CancelledError):
                        await refresh_task
        finally:
            # Keep recent diagnostics visible after leaving the alternate screen, including errors.
            for _, record in view.records:
                console.print(Text(record), soft_wrap=True)
