"""Discovery adds intake evidence; the existing six-role verifier owns PR acceptance."""

import asyncio
import json
import re
import time
from typing import Any
from urllib.parse import quote

import yaml

from gongcao.config import Config
from gongcao.discovery import Discovery
from gongcao.github import GitHub
from gongcao.recovery import diagnose
from gongcao.store import Store

from .evidence import require
from .ledger import Run, digest
from .resources import Unconfirmed, action, create_issue, optional, settled
from .runner import core, inspect, signature


async def exercise(run: Run, github: GitHub) -> None:
    repo = run.value["repository"]
    path = run.root / "config.yaml"
    config = yaml.safe_load(path.read_text())
    step = await create_issue(
        run, "Analyze this QA request read-only; do not implement code.", github, name="step"
    )
    excluded = await create_issue(
        run, "Excluded: this issue has no discovery label.", github, name="excluded"
    )
    sources = []
    for mode, issue in (("auto", run.value["resources"]["issue"]), ("step", step)):
        label = f"qa-discovery-{run.id[:12]}-{mode}"
        endpoint = f"repos/{repo}/labels/{quote(label, safe='')}"

        async def present(endpoint: str = endpoint) -> Any:
            row = await optional(github, endpoint)
            if row and row.get("description") != run.marker:
                raise Unconfirmed("Discovery QA label ownership changed")
            return row

        run.value["resources"].setdefault("discovery_labels", []).append(label)
        run.save()
        await action(
            run,
            "create-label-" + mode,
            "POST",
            f"repos/{repo}/labels",
            {"name": label, "color": "ededed", "description": run.marker},
            present,
        )
        labels_path = f"repos/{repo}/issues/{issue['number']}/labels"

        async def labelled(labels_path: str = labels_path, label: str = label) -> Any:
            rows = await github.pages(labels_path + "?per_page=100")
            return {"label": label} if any(row["name"] == label for row in rows) else None

        await action(run, "label-" + mode, "POST", labels_path, {"labels": [label]}, labelled)
        sources.append(
            {"repo": repo, "path": str(run.root / "source"), "label": label, "mode": mode}
        )
    config.update(
        scheduler={"jobs": 2},
        copilot={"operators": [run.value["github_login"]]},
        discovery={"enabled": True, "interval_seconds": 5, "sources": sources},
    )
    path.write_text(yaml.safe_dump(config))
    run.value["config_digest"] = digest(config)
    run.save()
    run.archive("configuration", config)
    stop = asyncio.Event()
    serving = asyncio.create_task(
        core(run, "serve", "--poll", "1", "--config", str(path), stop_event=stop)
    )
    pause_id = None
    claims: dict[str, Any] = {}
    try:
        deadline = time.monotonic() + 2400
        while time.monotonic() < deadline:
            run.check_cancelled()
            store = Store(run.root / "state")
            try:
                tasks = store.tasks()
                primary = next(
                    (t for t in tasks if t["url"] == run.value["resources"]["issue"]["url"]), None
                )
                paused = next((t for t in tasks if t["url"] == step["url"]), None)
                require(
                    all(t["url"] != excluded["url"] for t in tasks), "Ineligible issue was claimed"
                )
                if primary:
                    run.value["task_id"] = primary["id"]
                    run.save()
                for current in (primary, paused):
                    if current is None:
                        continue
                    if current["url"] not in claims:
                        claim = store.db.execute(
                            "SELECT * FROM claims WHERE task_id=?", (current["id"],)
                        ).fetchone()
                        claims[current["url"]] = await github.read(
                            f"repos/{repo}/issues/comments/{claim['comment_id']}"
                        )
                    require(
                        current["state"]
                        not in {
                            "failed",
                            "needs_human",
                            "needs_reconciliation",
                            "waiting_environment",
                        },
                        current["reason"],
                    )
                if (
                    paused
                    and paused["state"] == "waiting_instruction"
                    and time.time() > paused["control"]["since"] + 1
                    and pause_id is None
                ):
                    comment = await github.mutate(
                        f"repos/{repo}/issues/{step['number']}/comments", {"body": "/gongcao pause"}
                    )
                    pause_id = "github:" + str(comment["id"])
                accepted = paused and any(
                    i["id"] == pause_id and i["status"] == "consumed"
                    for i in store.evidence(paused["id"])["instructions"]
                )
                if (
                    primary
                    and primary["stage"] == "mergeable"
                    and primary["state"] == "completed"
                    and accepted
                    and not store.db.execute("SELECT 1 FROM leases").fetchone()
                ):
                    assert paused is not None
                    require(
                        paused["stage"] == "pending_development"
                        and len(store.runs(paused["id"])) == 1,
                        "Step task advanced without permission",
                    )
                    break
            finally:
                store.close()
            require(not serving.done(), "Discovery serve exited prematurely")
            await asyncio.wait({serving}, timeout=1)
        else:
            raise ValueError("Discovery QA deadline exceeded")
    finally:
        stop.set()
        await asyncio.wait_for(asyncio.shield(serving), 30)
    before = signature(inspect(run))
    traces = (json.loads(p.read_text())["stderr"] for p in run.root.glob("command-*.json"))
    require(any("GitHub 周期请求：" in text for text in traces), "Missing request accounting")
    store = Store(run.root / "state")
    try:
        records = [dict(row) for row in store.db.execute("SELECT * FROM claims ORDER BY url")]
        require(len(store.tasks()) == 2 and len(records) == 2, "Repeated scan duplicated intake")
        comments = [
            await github.read(f"repos/{repo}/issues/comments/{row['comment_id']}")
            for row in records
        ]
        history_before = [await github.instructions(row) for row in records]
        require(
            await core(run, "serve", "--once", "--config", str(path)) == 0, "Repeat scan failed"
        )
        history_after = [await github.instructions(row) for row in records]
        require(
            len(store.tasks()) == 2
            and store.db.execute("SELECT COUNT(*) FROM claims").fetchone()[0] == 2,
            "Restart duplicated discovery intake",
        )
        run.archive(
            "discovery",
            {
                "records": records,
                "comments": comments,
                "claims": claims,
                "history_before": history_before,
                "history_after": history_after,
                "step": inspect(run, paused["id"]),
                "excluded": excluded,
                "pause_id": pause_id,
                "before": before,
                "after": signature(inspect(run)),
            },
        )
    finally:
        store.close()
    verify(json.loads((run.root / "discovery.json").read_text()), run.value["github_login"])


def verify(data: dict[str, Any], actor: str) -> None:
    require(len(data["records"]) == len(data["comments"]) == 2, "Missing discovery claim evidence")
    require(
        len({row["url"] for row in data["records"]}) == 2
        and len({row["comment_id"] for row in data["records"]}) == 2
        and {json.loads(row["data"])["mode"] for row in data["records"]} == {"step", "auto"}
        and data["excluded"]["url"] not in {row["url"] for row in data["records"]},
        "Discovery eligibility/mode evidence differs",
    )
    require(data["before"] == data["after"], "Repeat scan changed PR/runs/operations")
    require(
        data["step"]["state"] == "waiting_instruction"
        and data["step"]["stage"] == "pending_development"
        and any(
            i["id"] == data["pause_id"]
            and i["status"] == "consumed"
            and i["data"].get("fingerprint")
            and i["data"]["actor"] == actor
            for i in data["step"]["evidence"]["instructions"]
        ),
        "Missing Copilot pause",
    )
    for row, comment, before, after in zip(
        data["records"],
        data["comments"],
        data["history_before"],
        data["history_after"],
        strict=True,
    ):
        require(
            row["task_id"] and not row["intent"] and not row["dirty"], "Claim/status is unconfirmed"
        )
        require(not json.loads(row["data"]).get("progress"), "Progress queue is unconfirmed")
        claim = json.loads(row["data"])
        original = data["claims"][row["url"]]
        require(
            original["body"] == comment["body"]
            and original["id"] == comment["id"]
            and original["user"]["id"] == comment["user"]["id"]
            and "claim pending confirmation" in original["body"],
            "Original claim was overwritten",
        )
        # Reactions/avatar metadata can change; preserve comment identity, author and text.
        require(
            [(c["id"], c["user"]["id"], c["user"]["login"], c["body"]) for c in before]
            == [(c["id"], c["user"]["id"], c["user"]["login"], c["body"]) for c in after],
            "Restart changed or removed milestone history",
        )
        anchors = [c for c in after if claim["marker"] in (c.get("body") or "")]
        require(len(anchors) == 1 and anchors[0]["id"] == comment["id"], "Claim is not unique")
        progress = [c for c in after if "<!-- gongcao-progress:" in (c.get("body") or "")]
        markers = [
            re.findall(r"<!-- gongcao-progress:([0-9a-f]{32}) -->", c["body"]) for c in progress
        ]
        require(
            progress
            and all(len(m) == 1 for m in markers)
            and len({m[0] for m in markers}) == len(progress)
            and len({c["id"] for c in progress}) == len(progress)
            and all(
                c["id"] != comment["id"]
                and c["user"]["login"] == actor
                and c["user"]["id"] == comment["user"]["id"]
                for c in progress
            ),
            "Progress event marker/author/comment ID is not unique",
        )
        require(
            claim["progress_last"]
            == {"event_id": markers[-1][0], "comment_id": progress[-1]["id"]},
            "Last POST does not match the confirmed event",
        )
        if claim["mode"] == "auto":
            require(
                all(
                    any(f"Stage: `{stage}`" in c["body"] for c in progress)
                    for stage in ("pending_review", "pending_validation", "mergeable")
                ),
                "Missing delivery/review/validation milestones",
            )
        require(
            comment["id"] == row["comment_id"]
            and comment["user"]["login"] == actor
            and json.loads(row["data"])["marker"] in comment["body"]
            and comment["body"] == row["confirmed"],
            "Claim ownership differs",
        )


async def cleanup_extras(run: Run, github: GitHub) -> None:
    store = Store(run.root / "state")
    try:
        require(
            not store.db.execute(
                "SELECT 1 FROM claims WHERE intent!='' OR (task_id IS NULL AND confirmed='') "
                "OR COALESCE(json_array_length(data,'$.progress'),0)>0"
            ).fetchone(),
            "Discovery writes need reconciliation before cleanup",
        )
        for task in store.tasks():
            settled(
                task
                | {
                    "runs": store.runs(task["id"]),
                    "evidence": store.evidence(task["id"]),
                    "runtime": diagnose(store, task["id"]),
                }
            )
            if task["id"] != run.value.get("task_id") and task["pr_number"]:
                raise Unconfirmed("Companion issue unexpectedly published a PR")
    finally:
        store.close()
    for name in ("step", "excluded"):
        if name not in run.value["resources"]:
            continue
        issue = run.value["resources"][name]
        endpoint = f"repos/{run.value['repository']}/issues/{issue['number']}"

        async def closed(endpoint: str = endpoint) -> Any:
            row = await github.read(endpoint)
            if (
                run.marker not in (row.get("body") or "")
                or row["user"]["login"] != run.value["github_login"]
            ):
                raise Unconfirmed("Companion QA issue ownership changed")
            return {"state": "closed"} if row["state"] == "closed" else None

        await action(run, "close-" + name, "PATCH", endpoint, {"state": "closed"}, closed)
    for label in run.value["resources"].get("discovery_labels", []):
        endpoint = f"repos/{run.value['repository']}/labels/{quote(label, safe='')}"

        async def deleted(endpoint: str = endpoint) -> Any:
            row = await optional(github, endpoint)
            if row and row.get("description") != run.marker:
                raise Unconfirmed("QA label ownership changed")
            return None if row else {"deleted": True}

        await action(run, "delete-" + label, "DELETE", endpoint, {}, deleted)
    run.archive("discovery-cleanup", {"issues": ["step", "excluded"], "labels_deleted": True})


async def reconcile_claims(run: Run, github: GitHub) -> None:
    """Confirm claim writes for cleanup without registering or executing tasks."""
    store = Store(run.root / "state")
    try:
        require(
            not store.db.execute(
                "SELECT 1 FROM leases UNION SELECT 1 FROM processes WHERE state!='stopped' "
                "UNION SELECT 1 FROM runs WHERE state='running'"
            ).fetchone(),
            "Discovery execution must settle before claim reconciliation",
        )
        publisher = Discovery(store, Config(), github)
        confirmed = []
        for row in publisher.records():
            item = await publisher.owned(row)
            expected = row["intent"] or row["confirmed"]
            if item is None or not expected or item["body"] != expected:
                raise Unconfirmed("Claim write remains unconfirmed; refusing cleanup")
            publisher.save(
                row["url"], comment_id=item["id"], confirmed=expected, intent="", reason=""
            )
            require(
                not json.loads(row["data"]).get("progress"),
                "Progress needs reconciliation before cleanup",
            )
            confirmed.append({"url": row["url"], "comment_id": item["id"], "body": expected})
        run.archive("discovery-claim-reconciliation", confirmed)
    finally:
        store.close()
