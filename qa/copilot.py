"""Authorized real comments exercise the native persistent control entry points."""

import asyncio
import time

import yaml

from gongcao.github import GitHub

from .evidence import require
from .ledger import Run, digest
from .runner import core, inspect, signature


async def exercise(run: Run, github: GitHub) -> None:
    task_id = str(run.value["task_id"])
    path = run.root / "config.yaml"
    issue = run.value["resources"]["issue"]["number"]
    endpoint = f"repos/{run.value['repository']}/issues/{issue}/comments"
    commands = []
    require(await core(run, "control", task_id, "--pause") == 0, "Initial pause failed")

    async def post(text: str) -> str:
        # GitHub timestamps have second resolution; wait beyond the local checkpoint.
        since = inspect(run)["control"]["since"]
        while time.time() <= since + 1:
            run.check_cancelled()
            await asyncio.sleep(0.2)
        comment = await github.mutate(endpoint, {"body": text})
        require(comment["user"]["login"] == run.value["github_login"], "Unexpected API actor")
        commands.append({"id": comment["id"], "actor": comment["user"]["login"], "body": text})
        return "github:" + str(comment["id"])

    async def once() -> None:
        require(await core(run, "serve", "--once", "--config", str(path)) == 0, "Serve failed")
        run.check_cancelled()

    denied = await post("/gongcao auto")
    before = signature(inspect(run))
    await once()
    task = inspect(run)
    require(
        signature(task) == before and task["state"] == "waiting_instruction",
        "Non-operator command advanced work",
    )
    require(
        any(
            i["id"] == denied and i["status"] == "rejected"
            for i in task["evidence"]["instructions"]
        ),
        "Missing rejection audit",
    )
    run.archive("copilot-denied", task)
    config = yaml.safe_load(path.read_text())
    config["copilot"]["operators"] = [run.value["github_login"]]
    path.write_text(yaml.safe_dump(config, sort_keys=True))
    run.value["config_digest"] = digest(config)
    run.archive("configuration", config)

    for stage, command in (
        ("pending_development", "/gongcao step"),
        ("pending_review", "/gongcao step"),
        ("pending_validation", "/gongcao until validation"),
    ):
        accepted = await post(command)
        await once()
        task = inspect(run)
        require(
            task["stage"] == stage and task["state"] == "waiting_instruction",
            f"Command failed to pause at {stage}: {task['reason']}",
        )
        require(
            any(
                i["id"] == accepted and i["status"] == "consumed"
                for i in task["evidence"]["instructions"]
            ),
            "Permission was not consumed",
        )
        before = signature(task)
        await once()  # A fresh CLI process must not consume the same comment again.
        require(signature(inspect(run)) == before, "Restart replayed a permission")
        run.archive("copilot-" + stage.replace("_", "-"), task)
    await post("/gongcao auto")
    await once()
    run.archive("copilot-commands", commands)
    run.event("copilot-controls-verified", task_id=task_id, pr_number=inspect(run)["pr_number"])
