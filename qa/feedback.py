"""Real manual Issue/PR conversation readback within the existing delivery Run."""

import json
from typing import Any

import yaml

from gongcao.github import GitHub
from gongcao.store import Store

from .evidence import require
from .ledger import Run


def identity(comment: dict[str, Any]) -> tuple[Any, ...]:
    return (comment["id"], comment["body"], comment["user"]["id"], comment["user"]["login"].lower())


async def exercise(run: Run, github: GitHub) -> None:
    from .runner import core, inspect

    task = inspect(run)
    pull = f"https://github.com/{run.value['repository']}/pull/{task['pr_number']}"
    config = yaml.safe_load((run.root / "config.yaml").read_text())
    config["copilot"] = {"operators": [run.value["github_login"]]}
    path = run.root / "feedback-config.yaml"
    path.write_text(yaml.safe_dump(config))
    require(
        await core(run, "register", pull, "--repo", str(run.root / "source"), "--config", str(path))
        == 0,
        "Direct PR registration failed",
    )
    store = Store(run.root / "state")
    try:
        direct = next(t for t in store.tasks() if t["url"] == pull)
        records = [dict(r) for r in store.db.execute("SELECT * FROM claims ORDER BY task_id")]
        anchors = [
            await github.read(f"repos/{run.value['repository']}/issues/comments/{r['comment_id']}")
            for r in records
        ]
        require(
            len(records) == 2
            and all(json.loads(r["data"]).get("kind") == "manual" for r in records),
            "Manual Issue/PR anchors not confirmed",
        )
    finally:
        store.close()
    command = await github.mutate(
        f"repos/{run.value['repository']}/issues/{task['pr_number']}/comments",
        {"body": "/gongcao pause"},
    )
    require(
        await core(run, "run", str(direct["id"]), "--config", str(path)) == 0,
        "PR conversation instruction failed",
    )
    direct = inspect(run, direct["id"])
    require(
        not direct["runs"] and direct["state"] == "waiting_instruction", "Pause started an Agent"
    )
    require(
        any(
            i["id"] == f"github:{command['id']}"
            and i["status"] == "consumed"
            and i["data"]["actor"] == run.value["github_login"]
            for i in direct["evidence"]["instructions"]
        ),
        "PR top-level command not consumed by its actual author",
    )
    histories = [await github.instructions({"url": r["url"]}) for r in records]
    require(
        await core(run, "run", str(direct["id"]), "--config", str(path)) == 0,
        "Repeated PR pause failed",
    )
    data = {"records": records, "anchors": anchors, "histories": histories, "command": command}
    run.archive("manual-feedback", data)
    await verify(run, github)


async def verify(run: Run, github: GitHub) -> None:
    data = json.loads((run.root / "manual-feedback.json").read_text())
    for row, anchor, before in zip(
        data["records"], data["anchors"], data["histories"], strict=True
    ):
        comments = await github.instructions({"url": row["url"]})
        require(
            list(map(identity, comments)) == list(map(identity, before)),
            "Repeat changed manual feedback history",
        )
        observed = await github.read(
            f"repos/{run.value['repository']}/issues/comments/{anchor['id']}"
        )
        require(identity(observed) == identity(anchor), "Manual status anchor was edited")
        events = [c for c in comments if (c.get("body") or "").startswith("<!-- gongcao-progress:")]
        require(
            events
            and len({c["body"].splitlines()[0] for c in events}) == len(events)
            and all(c["user"]["id"] == anchor["user"]["id"] for c in events),
            "Missing, duplicate or foreign manual progress",
        )
