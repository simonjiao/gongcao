"""Persistent permissions for the existing workflow, never a second stage machine."""

import asyncio
import hashlib
import json
import time
import uuid
from collections.abc import AsyncIterator, Iterator
from contextlib import asynccontextmanager, contextmanager
from contextvars import Context
from datetime import datetime
from typing import Any

from .config import Config
from .events import Redactor
from .github import GitHub
from .model import VERSION_FIELDS, Stage, State
from .store import Store

TARGETS = {name: Stage("pending_" + name) for name in ("development", "review", "validation")}
TARGETS["mergeable"] = Stage.MERGEABLE
ORDER = [Stage.ANALYSIS, Stage.DEVELOPMENT, Stage.REVIEW, Stage.VALIDATION, Stage.MERGEABLE]
RANK = {stage: float(index) for index, stage in enumerate(ORDER)} | {Stage.REVISION: 1.5}
LABELS = {
    "gongcao:step": ("step", None),
    "gongcao:auto": ("auto", None),
    "gongcao:until-review": ("until", "review"),
    "gongcao:until-validation": ("until", "validation"),
}
UNSAFE = {State.HUMAN, State.RECONCILE, State.CANCELLED}


class Paused(ValueError):
    pass


class InstructionChanged(ValueError):
    pass


def baseline(task: dict[str, Any]) -> str:
    return hashlib.sha256(
        json.dumps(
            [
                task["target_sha"],
                {key: task["snapshot"].get(key) for key in VERSION_FIELDS},
                [
                    (item["source"], item["feedback"])
                    for item in task.get("control", {}).get("feedback", [])
                ],
            ],
            sort_keys=True,
        ).encode()
    ).hexdigest()


def bind(task: dict[str, Any], data: dict[str, Any]) -> dict[str, Any]:
    return data | {"stage": task["stage"], "sha": task["target_sha"], "baseline": baseline(task)}


def rejection(
    task: dict[str, Any],
    data: dict[str, Any],
    *,
    received: dict[str, Any] | None = None,
) -> str:
    """The same immutable command rules apply at receipt and again at consumption."""
    mode, target = data["mode"], data["target"]
    if mode not in {"step", "until", "auto", "pause"} or (
        target not in TARGETS if mode == "until" else target is not None
    ):
        return "Invalid instruction or target"
    if (
        task["stage"] == Stage.MERGED
        or task["state"] == State.COMPLETED
        or (task["state"] in UNSAFE and (mode != "pause" or data["feedback"]))
    ):
        return "Task requires manual recovery or is terminal"
    if received and (
        received["sha"] != task["target_sha"]
        or received["baseline"] != baseline(task)
        or (mode != "pause" and not data["feedback"] and received["stage"] != task["stage"])
    ):
        return "Instruction no longer matches the current stage/SHA/request"
    return ""


class Controls:
    def __init__(self, store: "Store"):
        self.store, self.db = store, store.db

    @contextmanager
    def transaction(self) -> Iterator[None]:
        if self.db.in_transaction:
            yield
        else:
            with self.db:
                self.db.execute("BEGIN IMMEDIATE")
                yield

    def save(self, task_id: int, control: dict[str, Any]) -> None:
        self.db.execute("UPDATE tasks SET control=? WHERE id=?", (json.dumps(control), task_id))

    def mark(self, task_id: int, command_id: str, status: str, reason: str) -> None:
        self.db.execute(
            "UPDATE instructions SET status=?,reason=? WHERE task_id=? AND id=?"
            + (" AND status='accepted' AND reason=''" if status == "consumed" else ""),
            (status, reason, task_id, command_id),
        )

    def owns_checkpoint(self, task_id: int) -> bool:
        lease = self.db.execute(
            "SELECT owner,expires FROM leases WHERE task_id=?", (task_id,)
        ).fetchone()
        owner = self.store.owners.get(task_id)
        return (
            owner is None
            if lease is None
            else owner == lease["owner"] and lease["expires"] >= time.time()
        )

    def fence(self, task_id: int) -> None:
        if not self.owns_checkpoint(task_id):
            raise ValueError("Execution lease lost; control cannot advance")

    def initialize(
        self,
        task_id: int,
        *,
        source: str = "manual",
        mode: str | None = None,
        policy: str | None = None,
    ) -> None:
        """Called once by registration; discovery in #56 can use source='discovery'."""
        with self.transaction():
            task = self.store.task(task_id)
            if task["control"]:
                return
            labels = [
                LABELS[label] for label in task["snapshot"].get("labels", []) if label in LABELS
            ]
            selected, target = (
                labels[0]
                if len(labels) == 1
                else (mode or ("step" if source == "discovery" else "auto"), None)
            )
            self.save(
                task_id,
                {
                    "mode": selected,
                    "target": target,
                    "source": source,
                    "explicit": bool(labels) or mode is not None or source == "discovery",
                    "command_id": None,
                    "spent": False,
                    "pause_requested": len(labels) > 1,
                    "since": time.time(),
                    "request_since": time.time(),
                    "baseline": baseline(task),
                    "policy": policy,
                    "feedback": [],
                    "pause_reason": "Conflicting initial mode labels" if len(labels) > 1 else "",
                },
            )
            self.checkpoint(task_id)

    def record(
        self, task_id: int, command_id: str, data: dict[str, Any], status: str, reason: str = ""
    ) -> None:
        self.db.execute(
            "INSERT INTO instructions VALUES(?,?,?,?,?) ON CONFLICT(task_id,id) DO UPDATE SET "
            "data=excluded.data,status=excluded.status,reason=excluded.reason",
            (task_id, command_id, json.dumps(data), status, reason),
        )

    def issue(
        self,
        task_id: int,
        mode: str,
        target: str | None = None,
        *,
        command_id: str | None = None,
        actor: str = "local",
        created: float | None = None,
        policy: str | None = None,
        feedback: str = "",
        safe: bool = False,
        received: dict[str, Any] | None = None,
        defer_checkpoint: bool = False,
    ) -> bool:
        with self.transaction():
            task = self.store.task(task_id)
            control = task["control"]
            command_id = command_id or "local:" + uuid.uuid4().hex
            existing = self.db.execute(
                "SELECT status FROM instructions WHERE task_id=? AND id=?", (task_id, command_id)
            ).fetchone()
            if existing and not (received and existing[0] == "pending"):
                return False
            if safe or task_id in self.store.owners:
                self.fence(task_id)
            if mode == "pause":
                policy = control.get("policy")
            created = time.time() if created is None else created
            data = bind(
                task,
                {
                    "mode": mode,
                    "target": target,
                    "actor": actor,
                    "created": created,
                    "policy": policy,
                    "feedback": feedback,
                    "fingerprint": (received or {}).get("fingerprint")
                    or hashlib.sha256(json.dumps([mode, target, feedback]).encode()).hexdigest(),
                },
            )
            reason = rejection(task, data, received=received)
            occupied = self.db.execute(
                "SELECT 1 FROM leases WHERE task_id=?", (task_id,)
            ).fetchone()
            if not reason and not safe and mode != "pause" and occupied:
                reason = "Task is occupied; pause first and wait for a safe checkpoint"
            if not reason and mode != "pause" and policy:
                self.check_policy(task_id, policy)
                task = self.store.task(task_id)
                control, data = task["control"], bind(task, data)
            if not reason and mode == "until":
                if RANK[Stage(task["stage"])] > RANK[TARGETS[str(target)]]:
                    reason = "Target is behind the current stage"
                elif (
                    target == "development"
                    and task["pr_number"]
                    and task["stage"] == Stage.ANALYSIS
                ):
                    reason = (
                        "Existing PR analysis proceeds directly to review; target is unreachable"
                    )
            self.record(task_id, command_id, data, "rejected" if reason else "accepted", reason)
            if reason:
                return False
            if received is None:
                self.db.execute(
                    "UPDATE instructions SET status='superseded',reason='New local instruction' "
                    "WHERE task_id=? AND status='pending'",
                    (task_id,),
                )
            self.db.execute(
                "UPDATE instructions SET status='superseded',reason='New instruction' "
                "WHERE task_id=? AND id=? AND status='accepted'",
                (task_id, control.get("command_id")),
            )
            if feedback:
                self.db.execute("UPDATE runs SET evidence_valid=0 WHERE task_id=?", (task_id,))
                self.db.execute("UPDATE artifacts SET valid=0 WHERE task_id=?", (task_id,))
                self.db.execute("UPDATE tasks SET stage=? WHERE id=?", (Stage.ANALYSIS, task_id))
            control = control | {
                "mode": mode,
                "explicit": True,
                "target": target,
                "command_id": command_id,
                "spent": False,
                "pause_requested": mode == "pause",
                "pause_reason": "Pause requested" if mode == "pause" else "",
                "policy": policy,
                "since": max(created, control.get("since", 0)),
                "request_since": max(created, control.get("request_since", 0)),
                "feedback": control.get("feedback", [])
                + ([data | {"source": command_id}] if feedback else []),
            }
            control["baseline"] = baseline(task | {"control": control})
            self.save(task_id, control)
            if task["state"] == State.WAITING_INSTRUCTION:
                self.db.execute(
                    "UPDATE tasks SET state=?,reason='' WHERE id=?", (State.QUEUED, task_id)
                )
            if not defer_checkpoint and not (mode == "pause" and occupied and not safe):
                self.checkpoint(task_id)
            return True

    def invalidate(self, task_id: int, reason: str) -> None:
        """Called within the snapshot/policy transaction; uncertain work keeps its state."""
        with self.transaction():
            task = self.store.task(task_id)
            control = task["control"]
            if not control:
                return  # Migrated manual tasks retain their historical auto behavior.
            explicit = control.get("explicit", False)
            if explicit and (command_id := control.get("command_id")):
                self.mark(task_id, command_id, "stale", reason)
            self.save(
                task_id,
                control
                | {
                    "pause_requested": explicit,
                    "spent": explicit,
                    "since": time.time(),
                    "request_since": time.time(),
                    "baseline": baseline(task),
                    "pause_reason": reason,
                },
            )
            self.checkpoint(task_id)

    def checkpoint(self, task_id: int, *, previous_stage: str | None = None) -> bool:
        """Also runs in Store.finish/transition's transaction, so a step cannot replay."""
        with self.transaction():
            task = self.store.task(task_id)
            control = task["control"]
            if not control:
                return bool(task["state"] != State.WAITING_INSTRUCTION)
            if task["state"] in UNSAFE or task["stage"] == Stage.MERGED:
                return False
            self.fence(task_id)
            if self.db.execute(
                "SELECT 1 FROM runs WHERE task_id=? AND state=?", (task_id, State.RUNNING)
            ).fetchone():
                return True
            moved = previous_stage is not None and previous_stage != task["stage"]
            if moved:
                control["since"] = time.time()
                control["baseline"] = baseline(task)
            reached = (
                control["mode"] == "until"
                and RANK[Stage(task["stage"])] >= RANK[TARGETS[control["target"]]]
                and (task["stage"] != Stage.MERGEABLE or task["state"] == State.COMPLETED)
            )
            final = task["stage"] == Stage.MERGEABLE and task["state"] == State.COMPLETED
            consumed = (control["mode"] == "step" and (moved or final)) or reached
            pause = control.get("pause_requested") or control.get("spent") or consumed
            if consumed or (pause and control["mode"] == "pause"):
                control["spent"] = True
                if command_id := control.get("command_id"):
                    self.mark(task_id, command_id, "consumed", "Safe checkpoint reached")
            elif final and control["mode"] == "auto" and control.get("command_id"):
                self.mark(task_id, control["command_id"], "consumed", "Ready for human merge")
            self.save(task_id, control)
            if pause:
                self.db.execute(
                    "UPDATE tasks SET state=?,reason=?,updated=? WHERE id=?",
                    (
                        State.WAITING_INSTRUCTION,
                        control.get("pause_reason")
                        or "Waiting for instruction at a safe checkpoint",
                        time.time(),
                        task_id,
                    ),
                )
            return not pause

    def revalidate(self, task_id: int, config: Config) -> bool:
        return self.check_policy(
            task_id,
            config.policy_hash,
            operators={name.casefold() for name in config.copilot_operators},
        )

    def check_policy(self, task_id: int, policy: str, *, operators: set[str] | None = None) -> bool:
        with self.transaction():
            task = self.store.task(task_id)
            if (
                task["state"] in UNSAFE
                or task["state"] == State.COMPLETED
                or task["stage"] == Stage.MERGED
            ):
                return False
            self.fence(task_id)
            control = task["control"]
            command_id = control.get("command_id") or ""
            if operators is not None and command_id.startswith("github:"):
                row = self.db.execute(
                    "SELECT data FROM instructions WHERE task_id=? AND id=?", (task_id, command_id)
                ).fetchone()
                if row and json.loads(row[0])["actor"].casefold() not in operators:
                    self.invalidate(task_id, "Operator authorization changed; renew instruction")
                    return False
            if control and control.get("policy") not in {None, policy}:
                self.db.execute("UPDATE runs SET evidence_valid=0 WHERE task_id=?", (task_id,))
                self.db.execute("UPDATE artifacts SET valid=0 WHERE task_id=?", (task_id,))
                self.db.execute(
                    "UPDATE tasks SET stage=? WHERE id=?",
                    (Stage.REVIEW if task["pr_number"] else Stage.ANALYSIS, task_id),
                )
                if control.get("explicit"):
                    self.invalidate(task_id, "Execution policy changed; renew instruction")
                control = self.store.task(task_id)["control"]
            if control and control.get("policy") != policy:
                self.save(task_id, control | {"policy": policy})
            return self.checkpoint(task_id)

    def apply_pending(
        self, task_id: int, config: Config, *, defer_checkpoint: bool = False
    ) -> None:
        with self.transaction():
            if not self.owns_checkpoint(task_id):
                return
            if self.db.execute(
                "SELECT 1 FROM instructions WHERE task_id=? AND status='pending' AND reason!=''",
                (task_id,),
            ).fetchone():
                return
            operators = {name.casefold() for name in config.copilot_operators}
            pending = []
            for row in self.db.execute(
                "SELECT id,data FROM instructions WHERE task_id=? AND status='pending' "
                "AND reason=''",
                (task_id,),
            ):
                data = json.loads(row["data"])
                if data["actor"].casefold() in operators:
                    pending.append((row["id"], data))
                else:
                    self.mark(task_id, row["id"], "rejected", "Operator is not authorized")
            if not pending:
                return
            pending.sort(key=lambda item: int(item[0].split(":")[1]), reverse=True)
            task = self.store.task(task_id)
            fingerprints = {data.get("fingerprint", key) for key, data in pending}
            row = self.db.execute(
                "SELECT id,data FROM instructions WHERE task_id=? AND id=? AND status='accepted'",
                (task_id, task["control"].get("command_id")),
            ).fetchone()
            if row:
                current = json.loads(row["data"])
                if (
                    not task["control"].get("pause_requested")
                    and not task["control"].get("spent")
                    and current["actor"].casefold() in operators
                ):
                    fingerprints.add(current.get("fingerprint", row["id"]))
            if len(fingerprints) > 1:
                for key, _ in pending:
                    self.mark(task_id, key, "rejected", "Conflicting comment IDs")
                self.issue(task_id, "pause", safe=True, defer_checkpoint=defer_checkpoint)
                control = self.store.task(task_id)["control"]
                self.save(task_id, control | {"pause_reason": "Conflicting GitHub instructions"})
                if not defer_checkpoint:
                    self.checkpoint(task_id)
                return
            accepted = False
            for key, data in pending:
                if accepted:
                    self.mark(task_id, key, "rejected", "Superseded by a newer command")
                    continue
                if data["feedback"] and (
                    defer_checkpoint
                    or self.db.execute(
                        "SELECT 1 FROM runs WHERE task_id=? AND state=?", (task_id, State.RUNNING)
                    ).fetchone()
                ):
                    return  # Requirements wait for the completed result/write acknowledgement.
                reached = data["mode"] == "until" and task["stage"] == TARGETS[data["target"]]
                if reached and defer_checkpoint and data["target"] == "development":
                    self.mark(task_id, key, "rejected", "Target entry completed during publication")
                    self.issue(task_id, "pause", safe=True, defer_checkpoint=True)
                    return
                accepted = self.issue(
                    task_id,
                    data["mode"],
                    data["target"],
                    command_id=key,
                    actor=data["actor"],
                    created=data["created"],
                    feedback=data["feedback"],
                    policy=config.policy_hash,
                    safe=True,
                    received=data,
                    defer_checkpoint=defer_checkpoint and not reached,
                )

    async def collect(self, task_id: int, config: Config, github: GitHub) -> None:
        task = self.store.task(task_id)
        if (
            not config.copilot_operators
            or task["snapshot"].get("kind") != "issues"
            or task["state"] == State.COMPLETED
            or task["stage"] == Stage.MERGED
        ):
            return
        watched = {
            row["id"]: row["status"]
            for row in self.db.execute(
                "SELECT id,status FROM instructions WHERE task_id=? AND "
                "(status='pending' OR (id=? AND status='accepted'))",
                (task_id, task["control"].get("command_id")),
            )
            if row["id"].startswith("github:")
        }
        failures = {}
        try:
            comments = list(await github.instructions(task))  # Requires complete pagination.
        except Exception as exc:
            comments = []
            failures = dict.fromkeys(watched, Redactor().text(str(exc)))
        else:
            present = {"github:" + str(comment["id"]) for comment in comments}
            for key in watched.keys() - present:
                try:
                    comment = await github.read(
                        f"repos/{task['snapshot']['repository']}/issues/comments/{key.split(':')[1]}"
                    )
                    if "github:" + str(comment["id"]) != key:
                        raise ValueError("Comment ID did not match the direct read")
                    comments.append(comment)
                except Exception as exc:
                    failures[key] = Redactor().text(str(exc))
        operators = {name.casefold() for name in config.copilot_operators}
        with self.transaction():
            task = self.store.task(task_id)
            if task["state"] == State.COMPLETED or task["stage"] == Stage.MERGED:
                return
            for key, error in failures.items():
                reason = "Instruction verification pending: " + error
                changed = self.db.execute(
                    "UPDATE instructions SET reason=? WHERE task_id=? AND id=? "
                    "AND status IN ('pending','accepted')",
                    (reason, task_id, key),
                )
                if not changed.rowcount:
                    continue  # A newer checkpoint may already have retired this permission.
                if watched[key] == "pending" or (
                    task["control"].get("command_id") == key and not task["control"].get("spent")
                ):
                    self.save(
                        task_id, task["control"] | {"pause_requested": True, "pause_reason": reason}
                    )
                    task = self.store.task(task_id)
            for comment in comments:
                body = comment.get("body") or ""
                command_id = "github:" + str(comment["id"])
                fingerprint = hashlib.sha256(body.encode()).hexdigest()
                known = self.db.execute(
                    "SELECT data,status FROM instructions WHERE task_id=? AND id=?",
                    (task_id, command_id),
                ).fetchone()
                edited = comment.get("updated_at") != comment["created_at"]
                if known:
                    if (
                        edited
                        or json.loads(known["data"]).get("fingerprint", fingerprint) != fingerprint
                        or json.loads(known["data"])["actor"].casefold()
                        != comment.get("user", {}).get("login", "").casefold()
                    ):
                        self.mark(task_id, command_id, "stale", "Comment content was edited")
                        if task["control"].get("command_id") == command_id and not task[
                            "control"
                        ].get("spent"):
                            self.save(
                                task_id,
                                task["control"]
                                | {
                                    "pause_requested": True,
                                    "pause_reason": "Authorized comment was edited",
                                },
                            )
                            task = self.store.task(task_id)
                    elif known["status"] in {"pending", "accepted"}:
                        self.mark(task_id, command_id, known["status"], "")
                    continue
                header, _, feedback = body.strip().partition("\n")
                if not header.startswith("/gongcao "):
                    continue
                words = header.split()[1:]
                actor = comment.get("user", {}).get("login", "")
                data = bind(
                    task,
                    {
                        "actor": actor,
                        "created": datetime.fromisoformat(
                            comment["created_at"].replace("Z", "+00:00")
                        ).timestamp(),
                        "fingerprint": fingerprint,
                        "mode": words[0] if words else "",
                        "target": words[1] if len(words) == 2 else None,
                        "feedback": Redactor().text(feedback.strip())
                        if actor.casefold() in operators
                        else "",
                    },
                )
                reason = (
                    "Operator is not authorized"
                    if actor.casefold() not in operators
                    else "Edited comments require a new command"
                    if edited
                    else "Invalid command syntax"
                    if len(words) not in {1, 2}
                    else rejection(task, data)
                )
                self.record(task_id, command_id, data, "rejected" if reason else "pending", reason)

    async def poll(self, task_id: int, config: Config, github: GitHub) -> None:
        # Transport tasks inherit no Agent lease/process observer and take no jobs slot.
        await asyncio.create_task(self.collect(task_id, config, github), context=Context())
        self.apply_pending(task_id, config)
        if self.owns_checkpoint(task_id):
            self.checkpoint(task_id)

    @asynccontextmanager
    async def listen(
        self,
        config: Config,
        github: GitHub,
        task_id: int | None = None,
    ) -> AsyncIterator[None]:
        async def receive() -> None:
            while True:
                selected = [self.store.task(task_id)] if task_id is not None else self.store.tasks()
                for task in selected:
                    try:
                        await self.collect(task["id"], config, github)
                    except Exception:
                        pass  # Foreground polling reports errors; background reads retry later.
                await asyncio.sleep(5)

        listener = (
            asyncio.create_task(receive(), context=Context()) if config.copilot_operators else None
        )
        try:
            yield
        finally:
            if listener:
                listener.cancel()
                await asyncio.gather(listener, return_exceptions=True)
