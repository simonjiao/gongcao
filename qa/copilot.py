"""Authorized real comments exercise the native persistent control entry points."""

import asyncio
import json
import time
from datetime import datetime

import yaml

from gongcao.github import GitHub, command

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

    async def post(text: str, expected: str = "consumed") -> str:
        # GitHub timestamps have second resolution; wait beyond the local checkpoint.
        since = inspect(run)["control"]["since"]
        while time.time() <= since + 1:
            run.check_cancelled()
            await asyncio.sleep(0.2)
        comment = await github.mutate(endpoint, {"body": text})
        require(comment["user"]["login"] == run.value["github_login"], "Unexpected API actor")
        commands.append(
            {
                "id": comment["id"],
                "actor": comment["user"]["login"],
                "body": text,
                "expected": expected,
                "created_at": comment["created_at"],
            }
        )
        return "github:" + str(comment["id"])

    async def once() -> None:
        require(await core(run, "serve", "--once", "--config", str(path)) == 0, "Serve failed")
        run.check_cancelled()

    denied = await post("/gongcao auto", "rejected")
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

    for probe in ("edited", "expired"):
        rejected = await post("/gongcao auto", "rejected")
        if probe == "edited":
            created = datetime.fromisoformat(commands[-1]["created_at"].replace("Z", "+00:00"))
            await asyncio.sleep(max(0, created.timestamp() + 1.1 - time.time()))
            await command(
                "gh",
                "api",
                "--method",
                "PATCH",
                f"repos/{run.value['repository']}/issues/comments/{rejected.split(':')[1]}",
                "--input",
                "-",
                input_data=json.dumps({"body": "/gongcao step"}),
            )
        else:
            require(await core(run, "control", task_id, "--pause") == 0, "Pause failed")
        before = signature(inspect(run))
        await once()
        task = inspect(run)
        require(
            signature(task) == before and task["state"] == "waiting_instruction",
            f"{probe} command advanced work",
        )
        require(
            any(
                i["id"] == rejected and i["status"] == "rejected"
                for i in task["evidence"]["instructions"]
            ),
            f"Missing {probe} rejection",
        )
        run.archive("copilot-" + probe, task)

    async def wake() -> str:
        stop_event = asyncio.Event()
        serving = asyncio.create_task(
            core(
                run,
                "serve",
                "--poll",
                "1",
                "--config",
                str(path),
                stop_event=stop_event,
            )
        )
        try:
            await asyncio.sleep(0.5)
            accepted = await post("/gongcao step")
            deadline = time.monotonic() + 600
            while time.monotonic() < deadline:
                run.check_cancelled()
                task = inspect(run)
                if (
                    task["stage"] == "pending_development"
                    and task["state"] == "waiting_instruction"
                ):
                    return accepted
                require(not serving.done(), "Continuous serve exited before remote wakeup")
                require(
                    task["state"] not in {"failed", "needs_human", "needs_reconciliation"},
                    task["reason"],
                )
                await asyncio.wait({serving}, timeout=0.5)
            raise ValueError("Remote instruction did not wake the paused task")
        finally:
            stop_event.set()
            await asyncio.wait_for(asyncio.shield(serving), 15)

    for stage, instruction in (
        ("pending_development", "/gongcao step"),
        ("pending_review", "/gongcao step"),
        ("pending_validation", "/gongcao until validation"),
    ):
        if stage == "pending_development":
            accepted = await wake()
        else:
            accepted = await post(instruction)
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
