"""Judge controller records against fresh GitHub facts and an independent OS probe."""

import json
import sys
from pathlib import Path
from typing import Any
from urllib.parse import urlencode

from gongcao.config import Config
from gongcao.github import GitHub, command
from gongcao.model import Role, same_version
from gongcao.plan import binding
from gongcao.plan import digest as plan_digest
from gongcao.quality import verdict
from gongcao.sandbox import Sandbox

from .ledger import Run, digest
from .resources import settled
from .scenarios import VECTORS


def require(condition: Any, reason: str) -> None:
    if not condition:
        raise ValueError(reason)


def command_activity(run: Run) -> list[dict[str, Any]]:
    """Facts emitted by the SDK after an actual model command, not a thread-start claim."""
    commands = []
    for path in (run.root / "state/logs").glob("*.jsonl*"):
        try:
            contents = path.read_text()
        except FileNotFoundError:
            continue
        for line in contents.splitlines(keepends=True):
            if not line.endswith("\n"):
                continue
            event = json.loads(line)
            data = event.get("data", {})
            item = data.get("payload", {}).get("item", {}) if isinstance(data, dict) else {}
            if (
                event["kind"] == "sdk_event"
                and data.get("method") == "item/started"
                and item.get("type") == "commandExecution"
            ):
                commands.append(
                    {
                        "at": event["at"],
                        "run_id": event["run_id"],
                        "method": data["method"],
                        "item_id": item["id"],
                        "type": item["type"],
                    }
                )
    return sorted(commands, key=lambda row: (row["at"], row["run_id"], row["item_id"]))


def verify_recovery(run: Run, task: dict[str, Any], reviews: list[dict[str, Any]]) -> None:
    interrupted = json.loads((run.root / "interrupted.json").read_text())
    recovered = json.loads((run.root / "recovered.json").read_text())
    witness = interrupted["witness"]
    require(
        witness["point"] == "COMMENT observed before local operation_result",
        "Wrong recovery fault point",
    )
    key = witness["operation"]
    before = [o for o in interrupted["task"]["evidence"]["operations"] if o["id"] == key]
    after = [o for o in recovered["evidence"]["operations"] if o["id"] == key]
    final = [o for o in task["evidence"]["operations"] if o["id"] == key]
    require(len(before) == len(after) == len(final) == 1, "Recovered operation identity is missing")
    require(
        before[0]["kind"] == "review"
        and before[0]["state"] == "pending"
        and before[0]["sha"] == witness["target_sha"]
        and after[0]["state"] == final[0]["state"] == "succeeded"
        and after[0]["response"] == final[0]["response"] == witness["observed_response"],
        "COMMENT was not reconciled from pending to the observed result",
    )
    matches = [
        r
        for r in reviews
        if r["body"] == before[0]["payload"]["body"]
        and r["commit_id"] == before[0]["payload"]["commit_id"]
        and r["state"] == "COMMENTED"
    ]
    require(
        len(matches) == 1 and matches[0]["id"] == witness["observed_response"]["id"],
        "Recovery duplicated or lost the COMMENT",
    )


def evaluate(task: dict[str, Any], config: Config, facts: dict[str, Any]) -> dict[str, Any]:
    settled(task)
    sha = task["target_sha"]
    require(task["stage"] == "mergeable" and task["state"] == "completed", "Task is not mergeable")
    require(
        task["snapshot"]["state"] == "open" and not task["snapshot"].get("merged"),
        "QA issue/PR is closed or merged",
    )
    require(task["revision_count"] >= 1, "Deliberate defect was not revised")
    runs = task["runs"]
    old_reviews = [r for r in runs if r["role"] == "reviewer" and r["target_sha"] != sha]
    require(
        any(json.loads(r["result"] or "{}").get("conclusion") == "revise" for r in old_reviews),
        "Independent reviewer did not reject the initial defect",
    )
    require(
        all(not r["evidence_valid"] for r in runs if r["target_sha"] != sha),
        "Old SHA role evidence is still valid",
    )
    for role in ("reviewer", "validator"):
        valid = [r for r in runs if r["role"] == role and r["evidence_valid"]]
        require(
            valid
            and all(
                r["target_sha"] == sha
                and r["state"] == "completed"
                and json.loads(r["result"] or "{}").get("target_sha") == sha
                and json.loads(r["result"] or "{}").get("conclusion") == "ready"
                for r in valid
            ),
            f"No current-SHA {role} evidence",
        )
    artifacts = task["evidence"]["artifacts"]
    require(
        all(not a["valid"] for a in artifacts if a["sha"] != sha), "Old SHA artifacts remain valid"
    )
    plans = [
        a["data"]
        for a in artifacts
        if a["kind"] == "quality-plan" and a["valid"] and a["sha"] == sha
    ]
    require(plans, "Missing current validation plan")
    plan = plans[-1]
    require(all(plan.get(k) == v for k, v in binding(task).items()), "Plan version mismatch")
    require(
        plan["plan_hash"] == plan_digest({k: v for k, v in plan.items() if k != "plan_hash"}),
        "Plan hash mismatch",
    )
    results = [
        a["data"]
        for a in artifacts
        if a["kind"] == "quality-results" and a["valid"] and a["policy"] == plan["plan_hash"]
    ]
    require(results and verdict(results[-1]) == "passed", "Missing or failed required plan results")
    require(len(results[-1]["items"]) == len(plan["items"]), "Incomplete plan results")
    for item, expected in zip(results[-1]["items"], plan["items"], strict=True):
        require(
            all(item.get(k) == v for k, v in expected.items()), "Result entry differs from plan"
        )
        if item["required"]:
            require(item.get("exit_code") == 0 and item.get("argv"), "Missing actual execution")
    require(facts["headRefOid"] == sha, "PR head changed")
    require(
        not facts["isDraft"]
        and facts["mergeable"] == "MERGEABLE"
        and facts["mergeStateStatus"] == "CLEAN"
        and facts["reviewDecision"] in {"", "APPROVED"},
        "GitHub merge gates do not pass",
    )
    threads = [r["thread_id"] for r in runs if r["thread_id"]]
    require(len(threads) == len(set(threads)), "Role sessions were reused")
    return {
        "target_sha": sha,
        "revision_count": task["revision_count"],
        "initial_sha": old_reviews[0]["target_sha"],
        "plan_hash": plan["plan_hash"],
        "sessions": [
            {
                k: r[k]
                for k in (
                    "id",
                    "role",
                    "state",
                    "target_sha",
                    "thread_id",
                    "evidence_valid",
                )
            }
            for r in runs
        ],
    }


def evaluate_delivery(task: dict[str, Any], facts: dict[str, Any]) -> dict[str, Any]:
    """Expected blocked acceptance is successful delivery QA, never merge readiness."""
    settled(task)
    sha, snapshot = task["target_sha"], task["snapshot"]
    require(
        (task["stage"], task["state"]) == ("pending_review", "waiting_environment")
        and snapshot["state"] == "open"
        and not snapshot.get("merged")
        and facts["headRefOid"] == sha
        and facts["isDraft"],
        "Delivery must stop at blocked review with an open draft at the exact SHA",
    )
    developers = [r for r in task["runs"] if r["role"] == "developer"]
    require(len(developers) == 1, "Delivery must preserve one original Developer Run")
    developer = developers[0]
    report = json.loads(developer["result"])
    saved = developer["details"]["save"]
    require(
        developer["state"] == "completed"
        and report["conclusion"] == "blocked"
        and report.get("delivery_complete") is True
        and report["target_sha"] == developer["target_sha"] == snapshot["base_sha"]
        and saved["state"] == "confirmed"
        and saved["sha"] == sha
        and saved["parent"] == developer["details"]["source"]["sha"] == developer["target_sha"],
        "Blocked report, original target or controller checkpoint was lost",
    )
    operations = task["evidence"]["operations"]
    require(
        [o["kind"] for o in operations] == ["checkpoint", "push", "pull"]
        and operations[0]["payload"]["sha"] == operations[1]["payload"]["sha"] == sha
        and operations[0]["payload"]["branch"] == saved["branch"]
        and operations[1]["payload"]["branch"] == snapshot["head_ref"]
        and operations[2]["response"]["number"] == task["pr_number"],
        "Delivery duplicated writes or lost commit/PR identity",
    )
    require(
        not any(r["role"] in {"reviewer", "validator"} for r in task["runs"])
        and not any(a["kind"] == "validation" and a["valid"] for a in task["evidence"]["artifacts"])
        and not facts["reviews"],
        "Delivery bypassed Review/Validation gates",
    )
    checks = [
        a["data"]
        for a in task["evidence"]["artifacts"]
        if a["kind"] == "quality-results" and a["valid"] and a["sha"] == sha
    ]
    require(
        checks
        and all(checks[-1].get(k) == v for k, v in binding(task).items())
        and verdict(checks[-1], include_e2e=False) == "blocked"
        and any(
            i["category"] == "internal"
            and i["required"]
            and i["status"] == "blocked"
            and not i["entry"]
            for i in checks[-1]["items"]
        ),
        "Missing controller-owned current-version NOT_RUN acceptance evidence",
    )
    pulls = facts["pulls"]
    body = snapshot["pull_body"]
    require(
        len(pulls) == 1
        and pulls[0]["number"] == task["pr_number"]
        and pulls[0]["head"]["sha"] == sha
        and pulls[0]["body"] == body
        and all(
            text in body
            for text in (
                developer["id"],
                sha,
                developer["target_sha"],
                "`blocked`",
                "delivery_complete=True",
                "NOT_RUN",
                "missing acceptance package",
            )
        ),
        "Draft PR is duplicated or does not disclose pending acceptance and provenance",
    )
    require(
        developer["thread_id"]
        and any(
            c["run_id"] == developer["id"] and developer["started"] <= c["at"] <= developer["ended"]
            for c in facts["commands"]
        ),
        "Delivery has no actual SDK command in its Developer session",
    )
    return {
        "target_sha": sha,
        "developer_run": developer["id"],
        "original_target": developer["target_sha"],
        "acceptance": "NOT_RUN",
    }


async def probe(run: Run, sha: str) -> list[int]:
    module = f"qa_fixture_{run.id[:12]}"
    directory = run.root / "probes" / sha
    workspace = directory / "workspace"
    workspace.mkdir(parents=True, exist_ok=True)
    (workspace / ".git").touch()
    source = await command("git", "show", f"{sha}:{module}.py", cwd=str(run.root / "source"))
    (workspace / f"{module}.py").write_text(source)
    sandbox = Sandbox(workspace, directory, Role.REVIEWER)
    sandbox.prepare(Config(), authentication=False)
    await sandbox.verify(run.root / "source")
    output = await command(
        *sandbox.argv(
            sys.executable,
            "-B",
            "-c",
            f"import runpy,json; f=runpy.run_path('{module}.py')['clamp_score']; "
            f"print(json.dumps([f(x) for x in {VECTORS!r}]))",
        )
    )
    values: list[int] = json.loads(output)
    return values


async def verify_live(
    run: Run, task: dict[str, Any], config: Config, github: GitHub
) -> dict[str, Any]:
    current = await github.task_snapshot(task)
    require(
        current["state"] == "open" and not current.get("merged"), "QA issue/PR is closed or merged"
    )
    require(
        same_version(task, task | {"snapshot": current, "target_sha": current.get("head_sha")}),
        "GitHub target/version changed; archived evidence is stale",
    )
    facts = await github.gates(task)
    reviews = await github.pages(
        f"repos/{run.value['repository']}/pulls/{task['pr_number']}/reviews?per_page=100"
    )
    delivery = run.value["scenario"] == "delivery"
    if delivery:
        query = urlencode(
            {
                "state": "all",
                "head": f"{run.value['repository'].split('/')[0]}:{current['head_ref']}",
                "per_page": 100,
            }
        )
        facts.update(
            pulls=await github.pages(f"repos/{run.value['repository']}/pulls?{query}"),
            commands=command_activity(run),
            reviews=reviews,
        )
        result = evaluate_delivery(task | {"snapshot": current}, facts)
    else:
        result = evaluate(task, config, facts)
    # Deliberately corrupt only an in-memory copy, never the business database.
    try:
        if delivery:
            evaluate_delivery(task | {"target_sha": "0" * 40}, facts)
        else:
            evaluate(task | {"target_sha": "0" * 40}, config, facts)
    except ValueError:
        result["stale_sha_rejected"] = True
    else:
        raise ValueError("Verifier accepted stale SHA evidence")
    old = None if delivery else await probe(run, result["initial_sha"])
    final = await probe(run, task["target_sha"])
    if not delivery:
        require(
            old == [min(x, 100) for x in VECTORS], "Initial implementation was not the known fault"
        )
    require(final == [max(0, min(100, x)) for x in VECTORS], "Independent boundary probe failed")
    files = (
        await command(
            "git",
            "diff",
            "--name-only",
            run.value["base_sha"],
            task["target_sha"],
            cwd=str(run.root / "source"),
        )
    ).splitlines()
    module = f"qa_fixture_{run.id[:12]}"
    require(
        set(files) == {f"{module}.py", f"tests/test_{module}.py"},
        "Agent changed files outside fixture scope",
    )
    require(
        not (await command("git", "status", "--porcelain", cwd=str(run.root / "source"))).strip(),
        "Original clone was modified",
    )
    ref = await github.read(
        f"repos/{run.value['repository']}/git/ref/heads/{run.value['base_branch']}"
    )
    require(
        ref["object"]["sha"] == run.value["base_sha"],
        "Target main changed during QA; rerun against a fixed base",
    )
    for op in task["evidence"]["operations"]:
        if op["kind"] == "review":
            matches = [
                r
                for r in reviews
                if r["body"] == op["payload"]["body"]
                and r["commit_id"] == op["payload"]["commit_id"]
                and r["state"] == "COMMENTED"
            ]
            require(
                len(matches) == 1 and matches[0]["id"] == op["response"]["id"],
                "Review is missing or duplicated",
            )
    run.archive("github", {"snapshot": current, "facts": facts, "reviews": reviews})
    if run.value["scenario"] == "discovery":
        from .discovery import verify

        discovery = json.loads((run.root / "discovery.json").read_text())
        discovery["history_after"] = [
            await github.instructions(row) for row in discovery["records"]
        ]
        verify(discovery, run.value["github_login"])
    if run.value["scenario"] == "recover":
        verify_recovery(run, task, reviews)
    result.update(
        boundary_probe={"inputs": VECTORS, "initial": old, "final": final},
        changed_files=files,
        review_ids=[r["id"] for r in reviews],
    )
    return result


def verify_archived(run: Run) -> dict[str, Any]:
    run.check_archives()
    require(run.value["status"] == "passed", run.value.get("failure", "Run has not passed"))
    result: dict[str, Any] = json.loads((run.root / "verdict.json").read_text())
    require(result.get("passed") is True, "Archived verdict did not pass")
    if run.value["scenario"] != "smoke":
        task = json.loads((run.root / "task.json").read_text())
        settled(task)
        require(task["url"] == run.value["resources"]["issue"]["url"], "Task ownership mismatch")
        configuration = json.loads((run.root / "configuration.json").read_text())
        require(
            digest(configuration) == run.value["config_digest"], "Configuration digest mismatch"
        )
        if run.value["scenario"] == "cancel":
            require(
                task["state"] == "cancelled" and not task["evidence"]["operations"],
                "Expected cancellation is not confirmed",
            )
            cancellation = json.loads((run.root / "cancellation.json").read_text())
            recorded = cancellation["commands"]
            require(
                recorded and recorded == command_activity(run),
                "Cancellation has no real SDK command evidence",
            )
            require(
                any(
                    command["run_id"] == role["id"]
                    and role["thread_id"]
                    and role["started"] <= command["at"] <= role["ended"]
                    for command in recorded
                    for role in task["runs"]
                ),
                "Cancellation command is outside recorded SDK sessions",
            )
        else:
            github = json.loads((run.root / "github.json").read_text())
            delivery = run.value["scenario"] == "delivery"
            if delivery:
                require(
                    github["facts"]["commands"] == command_activity(run), "SDK evidence differs"
                )
                verified = evaluate_delivery(
                    task | {"snapshot": github["snapshot"]}, github["facts"]
                )
            else:
                verified = evaluate(task, Config.load(run.root / "config.yaml"), github["facts"])
            if run.value["scenario"] == "recover":
                verify_recovery(run, task, github["reviews"])
            require(verified["target_sha"] == result["target_sha"], "Verdict SHA mismatch")
            repeat = json.loads((run.root / "repeat.json").read_text())
            require(
                repeat["before"] == repeat["after"]
                and repeat["review_ids_before"] == repeat["review_ids_after"],
                "Repeated execution changed remote effects or sessions",
            )
            if run.value["scenario"] == "copilot":
                commands = json.loads((run.root / "copilot-commands.json").read_text())
                require(len(commands) == 7, "Missing real control comments")
                for command in commands:
                    require(
                        any(
                            row["id"] == "github:" + str(command["id"])
                            and row["status"] == command["expected"]
                            and row["data"].get("fingerprint")
                            and row["data"]["actor"]
                            == command["actor"]
                            == run.value["github_login"]
                            for row in task["evidence"]["instructions"]
                        ),
                        "Control comment acceptance/consumption mismatch",
                    )
                for stage in ("pending_development", "pending_review", "pending_validation"):
                    checkpoint = json.loads(
                        (run.root / f"copilot-{stage.replace('_', '-')}.json").read_text()
                    )
                    require(
                        checkpoint["id"] == task["id"]
                        and checkpoint["stage"] == stage
                        and checkpoint["state"] == "waiting_instruction",
                        "Control checkpoint continuity failed",
                    )
            elif run.value["scenario"] == "discovery":
                from .discovery import verify

                verify(
                    json.loads((run.root / "discovery.json").read_text()), run.value["github_login"]
                )
            boundaries = result["boundary_probe"]
            require(
                boundaries["inputs"] == list(VECTORS)
                and boundaries["initial"] == (None if delivery else [min(x, 100) for x in VECTORS])
                and boundaries["final"] == [max(0, min(100, x)) for x in VECTORS],
                "Boundary evidence is missing or failed",
            )
    return {
        "run_id": run.id,
        "passed": True,
        "as_of": result["at"],
        "cleaned": run.value.get("cleaned", False),
        "evidence": "archived, digest-checked",
    }


def verify_batch(data: Path, batch_id: str, *, require_isolation: bool = False) -> dict[str, Any]:
    # Run validates the ID before it can be used in a path.
    Run(data, batch_id)
    report = json.loads((data / f"batch-{batch_id}.json").read_text())
    require(report["id"] == batch_id and report["jobs"] >= 1, "Invalid batch identity")
    runs = [Run(data, run_id) for run_id in report["runs"]]
    require(len(runs) == len(set(report["runs"])), "Duplicate batch Run IDs")
    for run in runs:
        verify_archived(run)
    active: set[str] = set()
    peak = 0
    starts: dict[str, float] = {}
    ends: dict[str, float] = {}
    for event in report["events"]:
        run_id = event["run_id"]
        require(run_id in report["runs"], "Batch event has an unknown owner")
        if event["kind"] == "started":
            require(run_id not in starts, "Run started twice")
            starts[run_id] = event["at"]
            active.add(run_id)
            peak = max(peak, len(active))
            require(peak <= report["jobs"], "Batch exceeded concurrency limit")
        elif event["kind"] == "released":
            require(run_id in active, "Run released without a slot")
            ends[run_id] = event["at"]
            active.remove(run_id)
        else:
            raise ValueError("Unknown batch event")
    require(not active and len(starts) == len(runs), "Batch is incomplete")
    real = [run for run in runs if run.value["scenario"] != "smoke"]
    issues = [r.value["resources"]["issue"]["url"] for r in real]
    branches = [r.value["resources"]["branch"] for r in real]
    require(
        len(set(issues)) == len(issues) and len(set(branches)) == len(branches),
        "Remote resources overlap between Runs",
    )
    overlap = False
    cleanup_isolated = False
    for run in real:
        task = json.loads((run.root / "task.json").read_text())
        for peer in real:
            if run is peer:
                continue
            other = json.loads((peer.root / "task.json").read_text())
            own_commands, other_commands = command_activity(run), command_activity(peer)
            overlap |= any(
                a["thread_id"]
                and b["thread_id"]
                and a["id"] == own["run_id"]
                and b["id"] == theirs["run_id"]
                and max(own["at"], theirs["at"]) < min(a["ended"], b["ended"])
                for a in task["runs"]
                for b in other["runs"]
                for own in own_commands
                for theirs in other_commands
            )
            cleanup_isolated |= (
                run.value["scenario"] == "cancel"
                and any(
                    event["kind"] == "cleaned"
                    and starts[peer.id]
                    < event["at"]
                    < min(row["at"] for row in peer.value["events"] if row["kind"] == "finished")
                    for event in run.value["events"]
                )
                and peer.value["scenario"] in {"loop", "recover"}
            )
    if require_isolation:
        require(
            report["jobs"] == 2 and peak == 2 and len(real) >= 3 and overlap and cleanup_isolated,
            "Batch did not prove 2 real Runs, queueing and cancel/cleanup isolation",
        )
    return {
        "passed": True,
        "batch_id": batch_id,
        "peak_runs": peak,
        "queued": len(runs) > report["jobs"],
        "real_model_overlap": overlap,
        "cancel_cleanup_isolated": cleanup_isolated,
        "runs": report["runs"],
    }
