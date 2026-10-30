"""Release a process group's pipes before the owning event loop can close."""

import asyncio
import os
import signal
from collections.abc import Sequence
from contextvars import ContextVar
from pathlib import Path
from typing import Any, Protocol, cast


class Observer(Protocol):
    lost: bool

    def intent(self, label: str) -> str: ...
    def attached(self, key: str, pid: int) -> None: ...
    def aborted(self, key: str) -> None: ...
    def stopped(self, pid: int) -> None: ...
    def uncertain(self, pid: int) -> None: ...


observer: ContextVar[Observer | None] = ContextVar("process_observer", default=None)


def lease_lost() -> bool:
    current = observer.get()
    return current is not None and current.lost


def completed(process: asyncio.subprocess.Process) -> None:
    if current := observer.get():
        current.stopped(process.pid)


class NotStarted(OSError):
    """The OS rejected process creation; the command never executed."""


async def launch(
    *args: str, cwd: str | None = None, stdin: int | None = None, limit: int = 65536
) -> asyncio.subprocess.Process:
    current = observer.get()
    label = (
        "pid-sandbox"
        if Path(args[0]).name == "bwrap" and "--unshare-pid" in args and "--die-with-parent" in args
        else Path(args[0]).name
    )
    key = current.intent(label) if current else ""
    try:
        process = await asyncio.create_subprocess_exec(
            *args,
            cwd=cwd,
            stdin=stdin,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            start_new_session=True,
            limit=limit,
        )
    except OSError as exc:
        # asyncio/Popen settles a failed exec before raising OSError. A hard crash
        # or cancellation before attachment leaves the durable pending intent intact.
        if current:
            current.aborted(key)
        raise NotStarted(str(exc)) from exc
    if current:
        try:
            current.attached(key, process.pid)
        except BaseException:
            await stop(process)
            raise
    return process


class CleanupError(RuntimeError):
    pass


async def stop(
    process: asyncio.subprocess.Process, readers: Sequence[asyncio.Task[Any]] = ()
) -> None:
    """Join readers, stop the owned session and close pipes, even under repeated cancellation."""

    def signal_group(value: signal.Signals) -> None:
        try:
            os.killpg(process.pid, value)
        except ProcessLookupError:
            pass

    async def discard(stream: asyncio.StreamReader | None) -> None:
        if stream is not None:
            while await stream.read(65536):
                pass

    async def close() -> None:
        if process.stdin is not None:
            process.stdin.close()
        await asyncio.gather(discard(process.stdout), discard(process.stderr), process.wait())
        if process.stdin is not None:
            try:
                await process.stdin.wait_closed()
            except (BrokenPipeError, ConnectionResetError):
                pass

    async def cleanup() -> None:
        for reader in readers:
            if not reader.done():
                reader.cancel()
        if readers:
            await asyncio.gather(*readers, return_exceptions=True)
        # returncode alone says nothing about descendants still holding a pipe open.
        if process.returncode is None or any(
            stream is not None and not stream.at_eof()
            for stream in (process.stdout, process.stderr)
        ):
            signal_group(signal.SIGTERM)
        closing = asyncio.create_task(close())
        try:
            await asyncio.wait_for(asyncio.shield(closing), timeout=3)
            return
        except TimeoutError:
            signal_group(signal.SIGKILL)
        try:
            await asyncio.wait_for(asyncio.shield(closing), timeout=1)
            return
        except TimeoutError:
            # Process has no public close(). This CPython fallback releases local pipes
            # when a detached descendant retains them; it does not claim to kill that child.
            transport = cast(asyncio.SubprocessTransport, process._transport)  # type: ignore[attr-defined]
            transport.close()
            try:
                await asyncio.wait_for(asyncio.shield(closing), timeout=1)
            except TimeoutError:
                closing.cancel()
                await asyncio.gather(closing, return_exceptions=True)
            raise CleanupError(
                "Local pipes closed; descendant exit could not be confirmed"
            ) from None

    cleanup_task = asyncio.create_task(cleanup())
    cancelled = False
    try:
        while not cleanup_task.done():
            try:
                await asyncio.shield(cleanup_task)
            except asyncio.CancelledError:
                cancelled = True
        cleanup_task.result()
        completed(process)
    except CleanupError:
        if current := observer.get():
            current.uncertain(process.pid)
        raise
    finally:
        if cancelled:
            raise asyncio.CancelledError
