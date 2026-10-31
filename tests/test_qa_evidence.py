import copy
import json
from copy import deepcopy

import pytest
from _support.qa import new_run

from gongcao.github import command
from gongcao.recovery import diagnose
from gongcao.workflow import Workflow
from qa.evidence import evaluate, probe, verify_archived, verify_recovery
from qa.ledger import Run, digest, write_json
from qa.resources import Unconfirmed
from qa.runner import model_activity


def test_manifest_locks_paths_redaction_and_archive_tamper(tmp_path):
    run = new_run(tmp_path)
    with run.lock(), pytest.raises(ValueError, match="active"):
        with Run(tmp_path, run.id).lock():
            pass
    run.archive("verdict", {"passed": True, "at": 1, "password": "private"})
    assert "private" not in (run.root / "verdict.json").read_text()
    run.check_archives()
    (run.root / "verdict.json").write_text("{}")
    with pytest.raises(ValueError, match="changed"):
        run.check_archives()
    with pytest.raises(ValueError, match="Run ID"):
        Run(tmp_path, "../foreign")
    (tmp_path / "runs" / ("f" * 32)).symlink_to(run.root, target_is_directory=True)
    with pytest.raises(ValueError, match="symlink"):
        Run(tmp_path, "f" * 32)


async def test_verifier_requires_current_controller_evidence_not_agent_ready(
    store,
    task_id,
    fixture_github,
    policy,
):
    await Workflow(store, policy, fixture_github).run(task_id)
    task = store.task(task_id) | {
        "runs": store.runs(task_id),
        "evidence": store.evidence(task_id),
        "runtime": diagnose(store, task_id),
    }
    facts = await fixture_github.gates(task)
    assert evaluate(task, policy, facts)["revision_count"] == 1
    for failure in ("stale", "old", "e2e", "plan", "pending", "ready", "argv", "no_reject"):
        changed, remote = copy.deepcopy(task), copy.deepcopy(facts)
        if failure == "stale":
            changed["target_sha"] = "0" * 40
        elif failure == "old":
            changed["runs"][2]["evidence_valid"] = 1
        elif failure == "e2e":
            for artifact in changed["evidence"]["artifacts"]:
                if artifact["kind"] == "quality-results":
                    artifact["valid"] = 0
        elif failure == "plan":
            for artifact in changed["evidence"]["artifacts"]:
                if artifact["kind"] == "quality-plan" and artifact["valid"]:
                    artifact["data"]["base_sha"] = "0" * 40
        elif failure == "pending":
            changed["evidence"]["operations"][0]["state"] = "pending"
        elif failure == "argv":
            for artifact in changed["evidence"]["artifacts"]:
                if artifact["kind"] == "quality-results" and artifact["valid"]:
                    artifact["data"]["items"][0]["entry"] = ["true"]
        elif failure == "no_reject":
            for role in changed["runs"]:
                if role["role"] == "reviewer":
                    result = json.loads(role["result"])
                    result["conclusion"] = "ready"
                    role["result"] = json.dumps(result)
        else:
            changed["stage"] = "pending_validation"
        with pytest.raises((ValueError, Unconfirmed)):
            evaluate(changed, policy, remote)


async def test_independent_boundary_probe_uses_actual_read_only_sandbox(tmp_path, repo):
    run = new_run(tmp_path)
    await command("git", "clone", "-q", str(repo), str(run.root / "source"))
    source = run.root / "source"
    module = f"qa_fixture_{run.id[:12]}"
    (source / f"{module}.py").write_text(
        "def clamp_score(value: int) -> int:\n    return min(value, 100)\n"
    )
    await command("git", "add", ".", cwd=str(source))
    await command(
        "git",
        "-c",
        "user.name=QA",
        "-c",
        "user.email=qa@example.invalid",
        "commit",
        "-qm",
        "known fault",
        cwd=str(source),
    )
    sha = (await command("git", "rev-parse", "HEAD", cwd=str(source))).strip()
    assert await probe(run, sha) == [-500, -1, 0, 1, 99, 100, 100, 100]


def test_partial_sdk_log_never_counts_thread_start_as_inference(tmp_path):
    run = new_run(tmp_path)
    directory = run.root / "state/logs"
    directory.mkdir(parents=True)
    path = directory / "example.jsonl"
    write_json(path, {"kind": "thread", "data": {"thread_id": "not-proof"}})
    # Journal uses one JSON object per line, unlike pretty-printed manifests.
    path.write_text(json.dumps({"kind": "thread", "data": {"thread_id": "not-proof"}}) + "\n{")
    assert not model_activity(run)


def test_recovery_verifier_requires_pending_to_confirmed_exact_comment(tmp_path):
    run = new_run(tmp_path, "recover")
    op = {
        "id": "review-1",
        "kind": "review",
        "state": "pending",
        "sha": "a" * 40,
        "payload": {"body": "owned marker", "commit_id": "a" * 40},
        "response": None,
    }
    before = {"evidence": {"operations": [op]}}
    witness = {
        "point": "COMMENT observed before local operation_result",
        "operation": "review-1",
        "target_sha": "a" * 40,
        "observed_response": {"id": 31},
    }
    confirmed = op | {"state": "succeeded", "response": {"id": 31}}
    final = {"evidence": {"operations": [confirmed]}}
    reviews = [{"id": 31, "body": "owned marker", "commit_id": "a" * 40, "state": "COMMENTED"}]
    with pytest.raises(FileNotFoundError):
        verify_recovery(run, final, reviews)
    run.archive("interrupted", {"task": before, "witness": witness})
    run.archive("recovered", final)
    verify_recovery(run, final, reviews)
    with pytest.raises(ValueError, match="duplicated"):
        verify_recovery(run, final, reviews * 2)


def test_cancel_archive_requires_real_command_evidence(tmp_path):
    run = new_run(tmp_path, "cancel")
    url = "https://github.com/example/demo/issues/19"
    run.value.update(status="passed", config_digest=digest({}))
    run.value["resources"]["issue"] = {"url": url}
    run.archive("configuration", {})
    run.archive(
        "task",
        {
            "url": url,
            "state": "cancelled",
            "runs": [],
            "runtime": {"lease": None, "processes": []},
            "evidence": {"operations": []},
        },
    )
    run.archive("verdict", {"passed": True, "at": 1})
    with pytest.raises(FileNotFoundError):
        verify_archived(run)
    run.archive("cancellation", {"commands": []})
    with pytest.raises(ValueError, match="real SDK command"):
        verify_archived(run)


def test_discovery_qa_evidence_rejects_unknown_writes_and_false_control_claims():
    from qa.discovery import verify

    data = {
        "records": [
            {
                "url": f"issue:{number}",
                "task_id": 1,
                "intent": "",
                "dirty": 0,
                "comment_id": number,
                "confirmed": "claim",
                "data": json.dumps({"marker": "claim", "mode": mode}),
            }
            for number, mode in ((10, "step"), (11, "auto"))
        ],
        "comments": [
            {"id": number, "user": {"login": "owner"}, "body": "claim"} for number in (10, 11)
        ],
        "excluded": {"url": "issue:12"},
        "step": {
            "state": "waiting_instruction",
            "stage": "pending_development",
            "evidence": {
                "instructions": [
                    {
                        "id": "github:1",
                        "status": "consumed",
                        "data": {"actor": "owner", "fingerprint": "proof"},
                    }
                ]
            },
        },
        "pause_id": "github:1",
        "before": {},
        "after": {},
    }
    data["history_before"] = []
    for row, comment in zip(data["records"], data["comments"], strict=True):
        comment.update(body=f"<!-- claim:{row['comment_id']} --> claim pending confirmation")
        comment["user"]["id"] = 42
        history = [deepcopy(comment)] + [
            {
                "id": row["comment_id"] * 10 + i,
                "user": {"id": 42, "login": "owner"},
                "body": f"<!-- gongcao-progress:{row['comment_id'] * 10 + i:032x} -->"
                f"\nStage: `{stage}`",
            }
            for i, stage in enumerate(("pending_review", "pending_validation", "mergeable"), 1)
        ]
        row.update(
            confirmed=comment["body"],
            data=json.dumps(
                {
                    "marker": f"<!-- claim:{row['comment_id']} -->",
                    "mode": json.loads(row["data"])["mode"],
                    "progress_last": {
                        "event_id": f"{history[-1]['id']:032x}",
                        "comment_id": history[-1]["id"],
                    },
                }
            ),
        )
        data["history_before"].append(history)
    data["history_after"] = deepcopy(data["history_before"])
    data["claims"] = {
        row["url"]: deepcopy(comment)
        for row, comment in zip(data["records"], data["comments"], strict=True)
    }
    verify(data, "owner")
    for change in (
        lambda d: d["records"][0].update(intent="unknown"),
        lambda d: d["comments"][0]["user"].update(login="other"),
        lambda d: d["step"]["evidence"]["instructions"][0].update(status="pending"),
        lambda d: d.update(after={"runs": ["new"]}),
        lambda d: d["history_after"][0].pop(),
        lambda d: d["claims"]["issue:10"].update(body="overwritten"),
        lambda d: d["history_after"][0].append(d["history_after"][0][-1]),
        lambda d: d["history_before"][0][-1]["user"].update(id=99),
    ):
        invalid = deepcopy(data)
        change(invalid)
        with pytest.raises(ValueError):
            verify(invalid, "owner")
    for field, value in (
        ("id", 101),
        ("body", data["history_before"][0][-2]["body"]),
        ("user", {"login": "other", "id": 99}),
    ):
        invalid = deepcopy(data)
        for name in ("history_before", "history_after"):
            invalid[name][0][-1][field] = value
        with pytest.raises(ValueError):
            verify(invalid, "owner")
