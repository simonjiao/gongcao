"""Judge controller records against fresh GitHub facts and an independent OS probe."""

import json
import sys
from pathlib import Path
from typing import Any

from gongcao.config import Config
from gongcao.github import GitHub, command
from gongcao.model import Role, State, same_version
from gongcao.quality import ci_gate
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
    for kind, expected in (("checks", config.checks), ("real", config.real_checks)):
        current = [
            a
            for a in artifacts
            if a["kind"] == kind
            and a["valid"]
            and a["sha"] == sha
            and a["policy"] == config.policy_hash
        ]
        require(current, f"Missing {kind} evidence for current policy/SHA")
        data = current[-1]["data"]
        commands = data.get("commands", [])
        require(
            data.get("passed")
            and data.get("target_sha") == sha
            and data.get("policy") == config.policy_hash
            and len(commands) == len(expected)
            and len(commands) > 0
            and all(c["exit_code"] == 0 for c in commands),
            f"Incomplete or failed {kind}",
        )
        for observed, expected_argv in zip(commands, expected, strict=True):
            actual = observed.get("argv", [])
            require(len(actual) == len(expected_argv), f"Wrong command recorded for {kind}")
            for argument, template in zip(actual, expected_argv, strict=True):
                if template == "{python}":
                    require(
                        Path(argument).is_absolute() and Path(argument).name == "python3",
                        "Invalid quality interpreter binding",
                    )
                else:
                    require(
                        argument == template.replace("{sha}", sha),
                        f"Recorded {kind} command differs from configured policy",
                    )
    state, reason = ci_gate(task, facts, config.ci_workflows)
    require(state == State.COMPLETED, reason)
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
        "ci_runs": [
            {
                k: r.get(k)
                for k in (
                    "id",
                    "run_attempt",
                    "head_sha",
                    "path",
                    "conclusion",
                    "target_proof",
                )
            }
            for r in facts["workflows"]
        ],
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
    result = evaluate(task, config, facts)
    # Deliberately corrupt only an in-memory copy, never the business database.
    try:
        evaluate(task | {"target_sha": "0" * 40}, config, facts)
    except ValueError:
        result["stale_sha_rejected"] = True
    else:
        raise ValueError("Verifier accepted stale SHA evidence")
    old = await probe(run, result["initial_sha"])
    final = await probe(run, task["target_sha"])
    require(old == [min(x, 100) for x in VECTORS], "Initial implementation was not the known fault")
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
    reviews = await github.pages(
        f"repos/{run.value['repository']}/pulls/{task['pr_number']}/reviews?per_page=100"
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
            missing = json.loads((run.root / "missing-gate.json").read_text())
            require(
                missing["state"] == "waiting_environment" and not missing["evidence"]["operations"],
                "Missing gate probe did not block",
            )
            boundaries = result["boundary_probe"]
            require(
                boundaries["inputs"] == list(VECTORS)
                and boundaries["initial"] == [min(x, 100) for x in VECTORS]
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
