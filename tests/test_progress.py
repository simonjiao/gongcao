import asyncio
import json
import logging

import pytest

from gongcao.config import Config
from gongcao.events import Journal, Redactor, progress, terminal_logging
from gongcao.github import GitHub
from gongcao.model import Role, State
from gongcao.scheduler import Scheduler


def test_terminal_summary_is_redacted_and_private_details_stay_in_journal(store, task_id, capsys):
    run = store.begin_run(task_id, Role.ANALYST)
    journal = Journal(store, run, 4096, Redactor())
    with terminal_logging():
        logging.getLogger("gongcao").warning("失败 github_pat_testsecret123\nforged")
        journal.emit("tool", {"prompt": "private prompt", "output": "private SDK output"})
        journal.emit("started", {"task_id": task_id})
        progress(store, task_id)
        progress(store, task_id)
    output = capsys.readouterr()
    assert not output.out
    assert "testsecret123" not in output.err and "[REDACTED]" in output.err
    assert "\\nforged" in output.err and "\nforged" not in output.err
    assert "private prompt" not in output.err and "private SDK output" not in output.err
    assert output.err.count("阶段：") == 1
    assert "Agent" not in output.err
    assert (
        json.loads(journal.path.read_text().splitlines()[0])["data"]["prompt"] == "private prompt"
    )


async def test_idle_heartbeat_uses_elapsed_time_not_poll_count(store, monkeypatch, caplog):
    caplog.set_level(logging.INFO, logger="gongcao")
    # Only the scheduler clock is advanced; don't globally patch the asyncio event-loop clock.
    from types import SimpleNamespace

    now = store.last_activity
    monkeypatch.setattr("gongcao.scheduler.time", SimpleNamespace(monotonic=lambda: now))
    intervals = iter((1, 1, 297, 1, 1, 299, 1))

    async def sleep(delay):
        nonlocal now
        try:
            now += next(intervals)
        except StopIteration:
            raise asyncio.CancelledError from None

    monkeypatch.setattr("gongcao.scheduler.asyncio.sleep", sleep)
    with pytest.raises(asyncio.CancelledError):
        await Scheduler(store, Config(), GitHub()).schedule(once=False, poll=1.0)
    assert caplog.text.count("空闲心跳") == 2


def test_dependency_environment_failure_and_retry_are_logged_once_per_change(
    store, task_id, caplog
):
    caplog.set_level(logging.INFO, logger="gongcao")
    scheduler = Scheduler(store, Config(), GitHub())
    for state in (
        State.WAITING_DEPENDENCY,
        State.WAITING_ENVIRONMENT,
        State.HUMAN,
        State.RECONCILE,
    ):
        store.halt(task_id, state, "private detailed diagnostic")
        progress(store, task_id)
        progress(store, task_id)
        scheduler.failed(task_id)
    assert caplog.text.count("阶段：") == 4
    for status in ("等待依赖", "缺少环境", "待人工处理", "待核对", "异常待重试"):
        assert status in caplog.text
    assert "private detailed diagnostic" not in caplog.text
