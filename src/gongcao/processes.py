"""Release a process group's pipes before the owning event loop can close."""

import asyncio
import os
import signal


async def stop(process: asyncio.subprocess.Process) -> None:
    """Call after cancelling/joining pipe readers; the process must own its session."""

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

    # returncode alone says nothing about descendants still holding a pipe open.
    if process.returncode is None or any(
        stream is not None and not stream.at_eof() for stream in (process.stdout, process.stderr)
    ):
        signal_group(signal.SIGTERM)
    closing = asyncio.create_task(close())
    try:
        await asyncio.wait_for(asyncio.shield(closing), timeout=3)
    except TimeoutError:
        signal_group(signal.SIGKILL)
        await closing
