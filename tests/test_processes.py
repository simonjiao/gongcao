import asyncio
import os
import signal
import sys

import pytest

from gongcao.github import command
from gongcao.processes import CleanupError, stop

pytestmark = pytest.mark.skipif(sys.platform != "linux", reason="Requires POSIX process groups")

# The leader exits after its child has installed its handler and inherited both output pipes.
ORPHAN = """
import os, pathlib, signal, sys, time
ready = pathlib.Path(sys.argv[1])
if os.fork() == 0:
    if sys.argv[2] == 'escape':
        os.setsid()
    if sys.argv[2] == 'ignore':
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    ready.write_text(str(os.getpid()))
    time.sleep(30)
else:
    while not ready.exists():
        time.sleep(0.001)
    os._exit(0)
"""


async def exited(process):
    # Process.wait() also waits for inherited pipes; this test needs the earlier leader exit.
    async with asyncio.timeout(5):
        while process.returncode is None:  # noqa: ASYNC110
            await asyncio.sleep(0.001)


async def cleanup(process, ready):
    # Also clean up on the old implementation, where the assertion below fails.
    if ready.exists():
        try:
            os.kill(int(ready.read_text()), signal.SIGKILL)
        except ProcessLookupError:
            pass
    if process.returncode is None:
        process.kill()
    await process.communicate()


@pytest.mark.parametrize("handler", ["default", "ignore"])
async def test_stop_releases_pipes_even_after_the_leader_has_exited(tmp_path, handler):
    ready = tmp_path / "child.pid"
    process = await asyncio.create_subprocess_exec(
        sys.executable,
        "-c",
        ORPHAN,
        str(ready),
        handler,
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        start_new_session=True,
    )
    try:
        await exited(process)
        assert process.returncode == 0
        await stop(process)
        assert process.stdout.at_eof()
        assert process.stderr.at_eof()
        assert process.stdin.is_closing()
        await process.stdin.wait_closed()
    finally:
        await cleanup(process, ready)


@pytest.mark.parametrize("mode", ["escape", "repeated_cancel"])
async def test_stop_has_bounded_cleanup_and_does_not_abandon_pipes(tmp_path, mode):
    ready = tmp_path / "child.pid"
    process = await asyncio.create_subprocess_exec(
        sys.executable,
        "-c",
        ORPHAN,
        str(ready),
        "escape" if mode == "escape" else "ignore",
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        start_new_session=True,
    )
    try:
        await exited(process)
        task = asyncio.create_task(stop(process))
        if mode == "repeated_cancel":
            await asyncio.sleep(0)
            task.cancel()
            await asyncio.sleep(0)
            task.cancel()
        expected = CleanupError if mode == "escape" else asyncio.CancelledError
        with pytest.raises(expected):
            await asyncio.wait_for(task, timeout=6)
        assert process.stdout.at_eof()
        assert process.stderr.at_eof()
        await process.stdin.wait_closed()
    finally:
        await cleanup(process, ready)


@pytest.mark.parametrize("failure", ["cancel", "timeout"])
async def test_command_failure_reaps_descendants_and_drains_pipes(tmp_path, monkeypatch, failure):
    ready = tmp_path / "child.pid"
    created = []
    spawned = asyncio.Event()
    spawn = asyncio.create_subprocess_exec
    wait_for = asyncio.wait_for

    async def capture(*args, **kwargs):
        process = await spawn(*args, **kwargs)
        created.append(process)
        spawned.set()
        return process

    async def short_timeout(awaitable, timeout):  # noqa: ASYNC109 - matches asyncio.wait_for
        return await wait_for(awaitable, timeout=0.5 if timeout == 60 else timeout)

    monkeypatch.setattr(asyncio, "create_subprocess_exec", capture)
    if failure == "timeout":
        monkeypatch.setattr(asyncio, "wait_for", short_timeout)
    task = asyncio.create_task(command(sys.executable, "-c", ORPHAN, str(ready), "default"))
    try:
        await asyncio.wait_for(spawned.wait(), timeout=5)
        process = created[0]
        await exited(process)
        if failure == "cancel":
            task.cancel()
        with pytest.raises(asyncio.CancelledError if failure == "cancel" else TimeoutError):
            await task
        assert process.stdout.at_eof()
        assert process.stderr.at_eof()
    finally:
        if not task.done():
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
        if created:
            await cleanup(created[0], ready)
