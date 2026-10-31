import asyncio

from gongcao.model import AgentResult, Role, Stage, State


def register_more(store, repo, sha, snapshot, count):
    return [
        store.register(
            snapshot["url"].rsplit("/", 1)[0] + f"/{i}",
            repo,
            sha,
            snapshot | {"number": i, "url": snapshot["url"].rsplit("/", 1)[0] + f"/{i}"},
        )
        for i in range(2, count + 2)
    ]


def analysis_ready(store, task_id, sha):
    run = store.begin_run(task_id, Role.ANALYST)
    result = AgentResult(
        conclusion="ready",
        summary="Confirmed plan",
        basis=["Inspect sample.txt"],
        target_sha=sha,
        next_steps=["Implement in an isolated worktree"],
    )
    store.finish(
        run, State.COMPLETED, Stage.DEVELOPMENT, State.QUEUED, "planned", result.model_dump_json()
    )


async def wait_for(predicate):
    async with asyncio.timeout(15):
        while not predicate():  # noqa: ASYNC110 -- observing SQLite/OS state across processes
            await asyncio.sleep(0.02)
