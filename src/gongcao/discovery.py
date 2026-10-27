"""Opt-in issue intake and the sole publisher of controller-owned status comments."""

import asyncio
import fcntl
import hashlib
import json
import logging
import os
import time
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, TextIO
from urllib.parse import urlencode

from .config import Config, Source
from .events import Redactor
from .github import GitHub, Target
from .model import Stage, State
from .recovery import Recovery
from .store import Store
from .workspace import repository

LOG = logging.getLogger(__name__)


def lock_path(repo: str) -> Path:
    root = Path("/tmp") / f"gongcao-claims-{os.getuid()}"
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    if root.is_symlink() or root.stat().st_uid != os.getuid() or root.stat().st_mode & 0o077:
        raise ValueError("Discovery lock directory must be private and owned by this user")
    return root / (hashlib.sha256(repo.lower().encode()).hexdigest() + ".lock")


class Discovery:
    def __init__(self, store: Store, config: Config, github: GitHub):
        self.store, self.config, self.github = store, config, github
        self.controller = store.db.execute("SELECT id FROM controller").fetchone()[0]
        self.locks: list[TextIO] = []
        self.retry: dict[str, tuple[int, float]] = {}
        self.next_scan = 0.0
        self.next_facts = 0.0

    def records(self) -> list[dict[str, Any]]:
        return [dict(row) for row in self.store.db.execute("SELECT * FROM claims ORDER BY url")]

    def save(self, url: str, **values: Any) -> None:
        assert not values.keys() - {
            "data",
            "task_id",
            "comment_id",
            "intent",
            "confirmed",
            "dirty",
            "reason",
        }
        with self.store.db:
            self.store.db.execute(
                "UPDATE claims SET " + ",".join(key + "=?" for key in values) + " WHERE url=?",
                (*values.values(), url),
            )

    def warning(self, key: str, exc: Exception) -> None:
        failures = self.retry.get(key, (0, 0))[0] + 1
        self.retry[key] = failures, time.monotonic() + min(300, 5 * 2 ** min(failures, 6))
        message = Redactor().text(f"{type(exc).__name__}: {exc}")
        LOG.warning("Discovery/status %s: %s", key, message)
        self.save(key, reason=message)

    def due(self, key: str) -> bool:
        return self.retry.get(key, (0, 0))[1] <= time.monotonic()

    @asynccontextmanager
    async def active(self, *, once: bool) -> AsyncIterator[None]:
        repos = {json.loads(row["data"])["repo"] for row in self.records()}
        if self.config.discovery.enabled:
            repos.update(source.repo for source in self.config.discovery.sources)
        ticker = None
        entered = False
        try:
            for repo in sorted(repos):
                handle = os.fdopen(
                    os.open(lock_path(repo), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600), "a"
                )
                try:
                    fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    handle.close()
                    raise ValueError(
                        f"Discovery controller already owns {repo} on this machine"
                    ) from None
                self.locks.append(handle)
            entered = True
            await self.cycle(discover=True)
            if repos:
                ticker = asyncio.create_task(self.watch(discover=not once))
            yield
        finally:
            try:
                if ticker:
                    ticker.cancel()
                    await asyncio.gather(ticker, return_exceptions=True)
                if entered:
                    await self.cycle(discover=False)
            finally:
                for locked in self.locks:
                    locked.close()
                self.locks.clear()

    async def watch(self, *, discover: bool) -> None:
        while True:
            await asyncio.sleep(1)
            await self.cycle(discover=discover)

    async def cycle(self, *, discover: bool) -> None:
        # Reconcile old claims and pending PATCHes before admitting new work.
        facts_due = time.monotonic() >= self.next_facts
        if facts_due:
            self.next_facts = time.monotonic() + self.config.discovery.interval_seconds
        for row in self.records():
            if not self.due(row["url"]):
                continue
            try:
                if row["task_id"] is None:
                    await self.claim(row)
                else:
                    if facts_due:
                        await self.lifecycle(row["task_id"])
                        row = dict(
                            self.store.db.execute(
                                "SELECT * FROM claims WHERE url=?", (row["url"],)
                            ).fetchone()
                        )
                    if row["dirty"] or row["intent"]:
                        await self.publish(row)
                self.retry.pop(row["url"], None)
            except Exception as exc:
                self.warning(row["url"], exc)
        if discover and self.config.discovery.enabled and time.monotonic() >= self.next_scan:
            self.next_scan = time.monotonic() + self.config.discovery.interval_seconds
            await self.scan()

    async def lifecycle(self, task_id: int) -> None:
        task = self.store.task(task_id)
        if (
            task["stage"] == Stage.MERGED
            or self.store.db.execute("SELECT 1 FROM leases WHERE task_id=?", (task_id,)).fetchone()
        ):
            return
        snapshot = await self.github.task_snapshot(task)
        if (
            self.store.task(task_id)["updated"] != task["updated"]
            or self.store.db.execute("SELECT 1 FROM leases WHERE task_id=?", (task_id,)).fetchone()
        ):
            return
        self.store.sync(task_id, snapshot)
        if (
            task["pr_number"]
            and snapshot.get("state") == "open"
            and not snapshot.get("merged")
            and snapshot.get("base_sha") != task["snapshot"].get("base_sha")
        ):
            self.store.halt(
                task_id,
                State.RECONCILE,
                "Published PR baseline changed; manual reconciliation required",
            )

    async def eligible(self, target: Target, label: str, marker: str = "") -> dict[str, Any]:
        raw = await self.github.read(f"repos/{target.repository}/issues/{target.number}")
        if (
            raw["state"] != "open"
            or "pull_request" in raw
            or raw.get("assignees")
            or label not in [item["name"] for item in raw.get("labels", [])]
        ):
            raise ValueError(
                "Issue is closed, assigned, a PR, or no longer has the exact intake label"
            )
        timeline = await self.github.pages(
            f"repos/{target.repository}/issues/{target.number}/timeline?per_page=100"
        )
        if any(
            item.get("source", {}).get("issue", {}).get("pull_request")
            or item.get("event") in {"connected", "closed", "reopened", "assigned", "unassigned"}
            for item in timeline
        ):
            raise ValueError(
                "Issue has prior handling or a linked PR; manual reconciliation required"
            )
        comments = await self.github.instructions({"url": target.url})
        if any(
            "<!-- gongcao:" in item.get("body", "") and (not marker or marker not in item["body"])
            for item in comments
        ):
            raise ValueError("Another controller/unknown Gongcao status marker already exists")
        snapshot = await self.github.snapshot(target)
        snapshot["labels"] = [item["name"] for item in raw["labels"]]
        return snapshot

    async def scan(self) -> None:
        maximum = self.config.discovery.max_new_per_scan
        backlog = self.store.db.execute(
            "SELECT count(*) FROM claims c LEFT JOIN tasks t ON c.task_id=t.id "
            "WHERE t.id IS NULL OR (t.stage!=? AND t.state!=?)",
            (Stage.MERGED, State.CANCELLED),
        ).fetchone()[0]
        available = max(0, maximum - backlog)
        for source in sorted(
            self.config.discovery.sources, key=lambda item: (item.repo, item.label)
        ):
            if not available or not self.due(source.repo):
                continue
            try:
                await repository(source.path, Target(source.repo, "issues", 1))
                query = urlencode(
                    {
                        "state": "open",
                        "labels": source.label,
                        "sort": "created",
                        "direction": "asc",
                        "per_page": 100,
                    }
                )
                rows = await self.github.pages(f"repos/{source.repo}/issues?{query}")
                for item in sorted(rows, key=lambda item: int(item["number"])):
                    if not available:
                        break
                    if "pull_request" in item:
                        continue
                    target = Target(source.repo, "issues", item["number"])
                    if (
                        self.store.db.execute(
                            "SELECT 1 FROM tasks WHERE lower(url)=?", (target.url,)
                        ).fetchone()
                        or self.store.db.execute(
                            "SELECT 1 FROM claims WHERE url=?", (target.url,)
                        ).fetchone()
                    ):
                        continue
                    try:
                        await self.prepare(source, target)
                    except ValueError as exc:
                        LOG.warning(
                            "Discovery skipped %s: %s", target.url, Redactor().text(str(exc))
                        )
                        continue
                    available -= 1
                self.retry.pop(source.repo, None)
            except Exception as exc:
                self.warning(source.repo, exc)

    async def prepare(self, source: Source, target: Target) -> None:
        snapshot = await self.eligible(target, source.label)
        actor = (await self.github.read("user"))["login"].lower()
        sha = await Recovery(self.store, self.github).default_base(
            {
                "url": target.url,
                "repo_path": str(source.path),
                "snapshot": snapshot,
            }
        )
        marker = f"<!-- gongcao:controller={self.controller};issue={target.url} -->"
        data = {
            "repo": source.repo,
            "path": str(source.path),
            "label": source.label,
            "mode": source.mode,
            "policy": self.config.policy_hash,
            "actor": actor,
            "base_sha": sha,
            "marker": marker,
            "attempted": False,
        }
        with self.store.db:
            self.store.db.execute(
                "INSERT INTO claims(url,data) VALUES(?,?)", (target.url, json.dumps(data))
            )
        row = dict(
            self.store.db.execute("SELECT * FROM claims WHERE url=?", (target.url,)).fetchone()
        )
        try:
            await self.claim(row)
        except Exception as exc:
            self.warning(target.url, exc)

    async def owned(self, row: dict[str, Any]) -> dict[str, Any] | None:
        data = json.loads(row["data"])
        comments = await self.github.instructions({"url": row["url"]})
        matches = [item for item in comments if data["marker"] in item.get("body", "")]
        if len(matches) > 1:
            raise ValueError("Duplicate claim markers; refusing to choose a status comment")
        if not matches:
            if row["comment_id"]:
                raise ValueError("Owned status comment is missing; refusing to recreate it")
            return None
        item = matches[0]
        if item["user"]["login"].lower() != data["actor"] or (
            row["comment_id"] is not None and item["id"] != row["comment_id"]
        ):
            raise ValueError("Claim comment author or ID does not match the recorded owner")
        # Verify the ID directly as well as uniqueness across all comment pages.
        target = Target.parse(row["url"])
        observed = await self.github.read(f"repos/{target.repository}/issues/comments/{item['id']}")
        if any(observed.get(key) != item.get(key) for key in ("id", "body", "user")):
            raise ValueError("Status comment changed during observation")
        return item

    async def claim(self, row: dict[str, Any]) -> None:
        data = json.loads(row["data"])
        target = Target.parse(row["url"])
        item = await self.owned(row)
        if item is None:
            if data["attempted"]:
                raise ValueError("Unconfirmed claim POST; refusing replay or Agent execution")
            if not self.config.discovery.enabled:
                raise ValueError("Discovery disabled; retaining the planned claim without a POST")
            await self.eligible(target, data["label"], data["marker"])
            body = (
                data["marker"]
                + f"\nGongcao claim pending confirmation. Mode: {data['mode']}."
                + f" SHA: `{data['base_sha']}`"
            )
            data["attempted"] = True
            self.save(row["url"], data=json.dumps(data), intent=body)
            try:
                response = await self.github.mutate(
                    f"repos/{target.repository}/issues/{target.number}/comments", {"body": body}
                )
                self.save(row["url"], comment_id=response["id"])
                row["comment_id"] = response["id"]
            except Exception:
                item = await self.owned(row)
                if item is None:
                    raise
            row["intent"] = body
            item = await self.owned(row)
        expected = row["intent"] or row["confirmed"]
        if item is None or not expected or item["body"] != expected:
            raise ValueError("Claim content was not confirmed; Agent execution is prohibited")
        self.save(row["url"], comment_id=item["id"], confirmed=item["body"], intent="")
        # A confirmed claim survives label removal; lifecycle changes remain a registration gate.
        snapshot = await self.github.snapshot(target)
        snapshot["labels"] = await self.github.labels(target)
        task_id = self.store.register(
            target.url,
            Path(data["path"]),
            data["base_sha"],
            snapshot,
            source="discovery",
            mode=data["mode"],
            policy=data["policy"],
        )
        self.save(row["url"], task_id=task_id, dirty=1, reason="")
        row.update(task_id=task_id, comment_id=item["id"], confirmed=item["body"], intent="")
        await self.publish(row)

    def render(self, row: dict[str, Any]) -> str:
        task = self.store.task(row["task_id"])
        control = task["control"]
        pull = (
            f"https://github.com/{task['snapshot']['repository']}/pull/{task['pr_number']}"
            if task["pr_number"]
            else "pending"
        )
        action = (
            "Await trusted instruction / local gongcao control"
            if task["state"] == State.WAITING_INSTRUCTION
            else "Await human merge"
            if task["stage"] == Stage.MERGEABLE
            else task["reason"] or "Controller will advance within the configured policy"
        )
        marker: str = json.loads(row["data"])["marker"]
        return (
            marker + "\n**Gongcao**\n"
            f"Stage: `{task['stage']}` · State: `{task['state']}`\n"
            f"Mode: `{control['mode']}` · Until: `{control.get('target') or '-'}`\n"
            f"PR: {pull}\nTarget SHA: `{task['target_sha']}`\nNext / reason: {action}"
            f"\nReason: {task['reason'] or '-'}"
        )

    async def publish(self, row: dict[str, Any]) -> None:
        item = await self.owned(row)
        if item is None:
            raise ValueError("Claim comment is missing")
        if row["intent"]:
            if item["body"] != row["intent"]:
                raise ValueError("Unconfirmed status PATCH; refusing replay")
            self.save(row["url"], confirmed=item["body"], intent="", reason="")
            row.update(confirmed=item["body"], intent="")
        if item["body"] != row["confirmed"]:
            raise ValueError("Owned status comment was edited outside the recorded intent")
        body = self.render(row)
        if item["body"] != body:
            self.save(row["url"], intent=body)
            target = Target.parse(row["url"])
            try:
                await self.github.mutate(
                    f"repos/{target.repository}/issues/comments/{item['id']}",
                    {"body": body},
                    method="PATCH",
                )
            except Exception:
                observed = await self.owned(row)
                if observed is None or observed["body"] != body:
                    raise
            observed = await self.owned(row)
            if observed is None or observed["body"] != body:
                raise ValueError("Status PATCH was not confirmed")
            self.save(row["url"], confirmed=body, intent="", reason="")
        self.save(row["url"], dirty=int(self.render(row) != body))
