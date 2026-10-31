import asyncio
import io
import logging

import pytest
from rich.cells import cell_len
from rich.console import Console

from gongcao.events import Journal, Redactor, terminal_logging
from gongcao.model import Role, State
from gongcao.tui import Dashboard, serve_display


def test_dashboard_uses_local_activity_and_bounded_redacted_logs(
    store, task_id, repo, sha, snapshot
):
    run_id = store.begin_run(task_id, Role.ANALYST)
    view = Dashboard(store)
    stream = io.StringIO()
    console = Console(file=stream, width=100, height=18)
    console.print(view.render(100, 18))
    assert "暂无新事件" in stream.getvalue()
    stream.seek(0)
    stream.truncate()
    with terminal_logging(view):
        for number in range(160):
            logging.getLogger("gongcao").info("[%s] github_pat_secret123\x1b[2J", number)
    journal = Journal(store, run_id, 4096, Redactor())
    journal.emit(
        "sdk_event", {"method": "item/started", "payload": {"prompt": "private prompt" * 40}}
    )
    journal.emit("sdk_event", {"method": "unknown", "payload": {"method": "item/completed"}})
    with terminal_logging(view):
        logging.getLogger("gongcao").info("after SDK event")
    for number in range(2, 10):
        other = snapshot | {"url": snapshot["url"][:-1] + str(number), "number": number}
        other_id = store.register(other["url"], repo, sha, other)
        store.halt(other_id, State.WAITING_INSTRUCTION, "Paused")
    store.halt(other_id, State.RUNNING, "Executing validation plan")
    store.db.execute("PRAGMA query_only=ON")
    console.print(view.render(100, 18))
    text = stream.getvalue()
    assert "example/demo #1" in text and "执行 2" in text and "最近事件" in text
    assert "时长未记录；暂无新事件（无 Agent Run）" in text
    assert "[example/demo #1 / 任务1] Agent 工作项开始" in text
    assert "工作项结束" not in text and text.index("工作项开始") < text.index("after SDK event")
    assert "private prompt" not in text and "secret123" not in text and "\x1b" not in text
    assert "[159]" in text and "[0]" not in text and len(view.records) == 150
    assert "等待 7" in text and "另有 3 项" in text
    stream.seek(0)
    stream.truncate()
    console.print(view.render(100, 18))
    assert stream.getvalue().count("Agent 工作项开始") == 1
    narrow = io.StringIO()
    Console(file=narrow, width=46, height=12).print(view.render(46, 12))
    assert "另有 6 项" in narrow.getvalue() and "demo #1" in narrow.getvalue()


def test_dashboard_wraps_long_logs_and_indents_continuations(store):
    view = Dashboard(store)
    with terminal_logging(view):
        logging.getLogger("gongcao").info("长日志：%s 末尾标记", "中文数据" * 22)
    lines = view.log_lines(56, 10)
    assert len(lines) >= 3
    assert lines[0].startswith("20") and " INFO " in lines[0]
    assert all(line.startswith("    ") for line in lines[1:])
    assert all(cell_len(line) <= 52 for line in lines)
    assert "末尾标记" in "".join(lines)
    assert view.log_lines(56, 2) == lines[-2:]

    stream = io.StringIO()
    Console(file=stream, width=56, height=17).print(view.render(56, 17))
    assert "末尾标记" in stream.getvalue()


@pytest.mark.parametrize(
    "enabled,tty,term,tui",
    [
        (True, True, "xterm", True),
        (False, True, "xterm", False),
        (True, False, "xterm", False),
        (True, True, "dumb", False),
    ],
)
async def test_display_selection_and_error_restore(store, monkeypatch, enabled, tty, term, tui):
    stream = io.StringIO()
    monkeypatch.setattr(stream, "isatty", lambda: tty)
    monkeypatch.setattr("sys.stderr", stream)
    monkeypatch.setenv("TERM", term)
    logger = logging.getLogger("gongcao")
    previous = logger.handlers[:], logger.level, logger.propagate
    with pytest.raises(ValueError, match="display probe"):
        async with serve_display(store, enabled=enabled):
            logger.error("retained diagnostic github_pat_secret123")
            await asyncio.sleep(0)
            raise ValueError("display probe")
    text = stream.getvalue()
    assert "retained diagnostic" in text and "secret123" not in text
    assert ("\x1b[?1049h" in text) == tui
    if tui:
        assert "\x1b[?1049l" in text and text.rfind("\x1b[?25h") > text.find("\x1b[?25l")
    assert (logger.handlers, logger.level, logger.propagate) == previous
