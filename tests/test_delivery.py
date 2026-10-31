import hashlib
import json
from contextlib import closing

import pytest
from _support.worker import WORKER, install_worker

from gongcao.control import Controls
from gongcao.github import command
from gongcao.model import Role, Stage, State
from gongcao.recovery import Recovery
from gongcao.remote import Controlled
from gongcao.runner import Runner
from gongcao.store import Store
from gongcao.workflow import Workflow


@pytest.mark.parametrize("final", [False, True])
async def test_metadata_refresh_during_push_delivers_one_draft(
    store, task_id, fixture_github, policy, monkeypatch, final
):
    original = Controlled.before
    checks = 0

    async def refresh(self, task, kind, **kwargs):
        nonlocal checks
        checks += kind == "push"
        if kind == "push" and checks == (3 if final else 2):
            fixture_github.issue["updated_at"] = "2026-10-30T00:55:31Z"
        return await original(self, task, kind, **kwargs)

    monkeypatch.setattr(Controlled, "before", refresh)
    Controls(store).issue(task_id, "until", "review", policy=policy.policy_hash)
    await Workflow(store, policy, fixture_github).run(task_id)
    task = store.task(task_id)
    assert task["stage"] == Stage.REVIEW, task["reason"]
    assert task["snapshot"]["updated_at"] == "2026-10-30T00:55:31Z"
    assert task["state"] == State.WAITING_INSTRUCTION
    assert fixture_github.pull["draft"] and task["pr_number"] == 9
    assert len(fixture_github.writes) == 1
    assert all(op["state"] == "succeeded" for op in store.evidence(task_id)["operations"])


@pytest.mark.parametrize(
    "window,mode,unsafe",
    [
        ("running", "step", ""),
        ("finished", "until", ""),
        ("pushed", "auto", ""),
        ("finished", "until", "base"),
        ("finished", "until", "provenance"),
        ("finished", "until", "branch"),
        ("finished_blocked", "until", ""),
    ],
)
async def test_changed_request_delivery_preserves_review_and_safety(
    store, task_id, fixture_github, policy, monkeypatch, window, mode, unsafe
):
    controls = Controls(store)
    if window == "finished_blocked":
        install_worker(
            monkeypatch,
            WORKER.replace(
                "'conclusion':conclusion",
                "'conclusion':'blocked' if role=='developer' else conclusion,"
                "'delivery_complete':True if role=='developer' else None",
            ),
        )
    controls.issue(task_id, "until", "development", policy=policy.policy_hash)
    await Workflow(store, policy, fixture_github).run(task_id)
    controls.issue(task_id, mode, "review" if mode == "until" else None, policy=policy.policy_hash)
    owner, method = {
        "running": (Runner, "receive"),
        "finished": (Runner, "run"),
        "pushed": (Controlled, "push"),
    }[window.replace("_blocked", "")]
    original = getattr(owner, method)

    async def edited(self, *args, **kwargs):
        result = await original(self, *args, **kwargs)
        fixture_github.issue.update(title="Changed request", body="New requirements")
        row = store.runs(task_id)[-1]
        if unsafe == "provenance":
            store.run_details(row["id"], source=row["details"]["source"] | {"sha": "f" * 40})
        elif unsafe:
            other = (
                await command(
                    "git", "commit-tree", "HEAD^{tree}", "-m", "Other owner", cwd=row["worktree"]
                )
            ).strip()
            if unsafe == "base":
                fixture_github.sha = other
            else:
                branch = (
                    "gongcao/work-"
                    + hashlib.sha256(store.task(task_id)["url"].encode()).hexdigest()[:12]
                )
                await command(
                    "git",
                    "--git-dir",
                    str(fixture_github.bare),
                    "update-ref",
                    "refs/heads/" + branch,
                    other,
                )
        return result

    monkeypatch.setattr(owner, method, edited)
    await Workflow(store, policy, fixture_github).run(task_id)
    task, runs = store.task(task_id), store.runs(task_id)
    assert [r["role"] for r in runs] == ["analyst", "developer"]
    if unsafe:
        assert fixture_github.pull is None and task["stage"] != Stage.REVIEW
        assert not [op for op in store.evidence(task_id)["operations"] if op["state"] == "unknown"]
        return
    assert (task["stage"], task["state"]) == (Stage.REVIEW, State.WAITING_INSTRUCTION), task[
        "reason"
    ]
    assert "requirements changed" in task["reason"].lower()
    assert task["pr_number"] == 9 and fixture_github.pull["draft"]
    assert task["snapshot"]["body"] == "New requirements"
    assert not any(r["evidence_valid"] for r in runs)
    context = json.loads((store.root / "runs" / runs[-1]["id"] / "context.json").read_text())
    assert context["github"]["body"] == "Analyze sample.txt"
    assert fixture_github.head() == task["target_sha"] != runs[-1]["target_sha"]
    assert len(fixture_github.writes) == 1


async def test_changed_request_review_barrier_survives_delivery_interruption(
    store, task_id, fixture_github, policy, monkeypatch
):
    class Interruption(BaseException):
        pass

    publish = Controlled.publish

    async def delivered(self, *args, **kwargs):
        fixture_github.issue["body"] = "Changed request during implicit automatic execution"
        await publish(self, *args, **kwargs)
        raise Interruption

    monkeypatch.setattr(Controlled, "publish", delivered)
    assert not store.task(task_id)["control"]["explicit"]
    with pytest.raises(Interruption):
        await Workflow(store, policy, fixture_github).run(task_id)
    assert fixture_github.pull["draft"] and len(fixture_github.writes) == 1
    context = store.root / "runs" / store.runs(task_id)[-1]["id"] / "context.json"
    original = context.read_text()
    with closing(Store(store.root)) as restarted:
        context.write_text("{}")
        rejected = await Recovery(restarted, fixture_github).recover(task_id)
        assert not rejected["recovered"] and "context" in rejected["reason"], rejected
        context.write_text(original)
        recovered = await Recovery(restarted, fixture_github).recover(task_id)
        assert recovered["recovered"], recovered
        assert restarted.task(task_id)["state"] == State.WAITING_INSTRUCTION
        assert "requirements changed" in restarted.task(task_id)["reason"].lower()
        await Workflow(restarted, policy, fixture_github).run(task_id)
        assert [r["role"] for r in restarted.runs(task_id)] == ["analyst", "developer"]
        assert restarted.task(task_id)["pr_number"] == 9
    assert len(fixture_github.writes) == 1


@pytest.mark.parametrize("fault", ["preflight", "lost_response", "acceptance_blocked"])
async def test_delivery_write_boundary_and_restart_preserve_completed_developer(
    store, task_id, fixture_github, policy, monkeypatch, fault
):
    from gongcao.remote import command as routed

    if fault == "acceptance_blocked":
        install_worker(
            monkeypatch,
            WORKER.replace(
                "'conclusion':conclusion",
                "'conclusion':'blocked' if role=='developer' else conclusion,"
                "'delivery_complete':True if role=='developer' else None",
            )
            .replace("'Check controller gates'", "'NOT_RUN: missing acceptance package'")
            .replace("'basis':['sample.txt must be complete']", "'basis':['x'*100000]"),
        )
    sent, failed = 0, False

    async def transport(*args, **kwargs):
        nonlocal sent, failed
        if args[:2] != ("git", "push") or "refs/heads/gongcao/work-" not in args[-1]:
            return await routed(*args, **kwargs)
        if fault == "preflight" and not failed:
            failed = True
            await command("/does-not-exist-gongcao-git", cwd=kwargs.get("cwd"))
        result = await routed(*args, **kwargs)
        sent += 1
        if fault == "lost_response":
            raise ConnectionError("Response lost after accepted push")
        return result

    monkeypatch.setattr("gongcao.remote.command", transport)
    Controls(store).issue(task_id, "until", "review", policy=policy.policy_hash)
    await Workflow(store, policy, fixture_github).run(task_id)
    runs = [r["id"] for r in store.runs(task_id)]
    operations = store.evidence(task_id)["operations"]
    if fault == "preflight":
        assert sent == 0 and not [op for op in operations if op["kind"] == "push"]
        assert all(op["state"] == "succeeded" for op in operations)  # Existing WIP save contract.
    else:
        assert sent == 1 and store.task(task_id)["pr_number"] == 9
    with closing(Store(store.root)) as restarted:
        if fault == "preflight":
            assert (await Recovery(restarted, fixture_github).retry(task_id))["recovered"]
        await Workflow(restarted, policy, fixture_github).run(task_id)
        assert [r["id"] for r in restarted.runs(task_id)] == runs
        assert sent == 1
        assert restarted.task(task_id)["pr_number"] == 9
        assert len(fixture_github.writes) == 1
        if fault == "acceptance_blocked":
            assert len(fixture_github.pull["body"]) < 60000
            report = json.loads(restarted.runs(task_id)[-1]["result"])
            assert report["conclusion"] == "blocked" and report["delivery_complete"] is True
            assert restarted.task(task_id)["state"] == State.WAITING_INSTRUCTION
            assert all(
                text in fixture_github.pull["body"]
                for text in (
                    "NOT_RUN",
                    "missing acceptance package",
                    runs[-1],
                    "Agent report",
                    "Controller",
                )
            )
            install_worker(
                monkeypatch,
                WORKER.replace(
                    "plan = propose(data) if role=='analyst' else []",
                    "plan = propose(data) if role=='analyst' else []\n"
                    "for item in plan:\n"
                    "    if item['category']=='internal': "
                    "item.update(entry=[],reason='Missing acceptance package')",
                ),
            )
            Controls(restarted).issue(task_id, "until", "validation", policy=policy.policy_hash)
            await Workflow(restarted, policy, fixture_github).run(task_id)
            assert restarted.task(task_id)["state"] == State.WAITING_ENVIRONMENT
            assert (
                restarted.task(task_id)["stage"] != Stage.MERGEABLE and fixture_github.pull["draft"]
            )
            # Pure verifier regression with synthetic SDK facts; this is not real QA.
            from copy import deepcopy

            from gongcao.recovery import diagnose
            from qa.evidence import evaluate_delivery

            task = restarted.task(task_id) | {
                "runs": restarted.runs(task_id),
                "evidence": restarted.evidence(task_id),
                "runtime": diagnose(restarted, task_id),
            }
            developer = next(r for r in task["runs"] if r["role"] == "developer")
            facts = await fixture_github.gates(task)
            facts.update(
                pulls=await fixture_github.pages("pulls"),
                reviews=[],
                commands=[{"run_id": developer["id"], "at": developer["started"]}],
            )
            assert evaluate_delivery(task, facts)["acceptance"] == "NOT_RUN"
            for failure in ("ready", "complete", "draft", "sha", "duplicate", "sdk", "checks"):
                changed, remote = deepcopy(task), deepcopy(facts)
                if failure in {"ready", "complete"}:
                    report = json.loads(developer["result"])
                    report.update(
                        {"conclusion": "ready"}
                        if failure == "ready"
                        else {"delivery_complete": False}
                    )
                    next(r for r in changed["runs"] if r["role"] == "developer")["result"] = (
                        json.dumps(report)
                    )
                elif failure == "draft":
                    remote["isDraft"] = False
                elif failure == "sha":
                    remote["headRefOid"] = "0" * 40
                elif failure == "duplicate":
                    remote["pulls"] *= 2
                elif failure == "sdk":
                    remote["commands"] = []
                else:
                    changed["evidence"]["artifacts"] = []
                with pytest.raises(ValueError):
                    evaluate_delivery(changed, remote)


@pytest.mark.parametrize(
    "conclusion,complete",
    [("blocked", None), ("blocked", False), ("failed", True), ("ready", False)],
)
async def test_incomplete_developer_report_cannot_deliver(
    store, task_id, fixture_github, policy, monkeypatch, conclusion, complete
):
    field = (
        ""
        if complete is None
        else f"'delivery_complete':{complete} if role=='developer' else None,"
    )
    install_worker(
        monkeypatch,
        WORKER.replace(
            "'conclusion':conclusion",
            f"{field}'conclusion':'{conclusion}' if role=='developer' else conclusion",
        ),
    )
    await Workflow(store, policy, fixture_github).run(task_id)
    assert store.runs(task_id)[-1]["role"] == Role.DEVELOPER
    assert store.task(task_id)["state"] == State.HUMAN
    assert fixture_github.pull is None and fixture_github.writes == []
