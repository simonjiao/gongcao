"""GitHub facts and low-level transport. Only the controller authorizes mutations."""

import asyncio
import fcntl
import json
import re
import time
from collections import Counter, deque
from contextvars import ContextVar
from dataclasses import dataclass, field
from email.utils import parsedate_to_datetime
from functools import cached_property
from pathlib import Path
from typing import Any

from .events import Redactor
from .model import State
from .processes import completed, launch, stop
from .store import Store

background: ContextVar[bool] = ContextVar("github_background", default=False)
traffic: ContextVar["Traffic | None"] = ContextVar("github_traffic", default=None)


class Deferred(RuntimeError):
    """Request was not sent or was rejected by GitHub's rate limiter."""


def response(raw: str) -> tuple[dict[str, str], str]:
    if not raw.startswith("HTTP/"):
        return {}, raw
    head, body = raw.replace("\r\n", "\n").split("\n\n", 1)
    return {
        key.lower(): value
        for line in head.splitlines()[1:]
        if ": " in line
        for key, value in [line.split(": ", 1)]
    }, body


@dataclass
class Traffic:
    budget: int = 1200
    reserve: float = 0.2
    remaining: int | None = None
    limit: int = 0
    reset: float = 0
    cooldown: float = 0
    spacing: float = 0
    failures: int = 0
    generation: int = 0
    cooldown_path: Path | None = None
    reported_at: float = 0
    reported_cooldown: float = 0
    recent: deque[float] = field(default_factory=deque)
    counts: Counter[str] = field(default_factory=Counter)
    snapshots: dict[tuple[str, int | None], tuple[float, dict[str, Any]]] = field(
        default_factory=dict
    )

    def restore(self, store: Store) -> None:
        self.cooldown_path = store.root / "github-cooldown"
        row = store.db.execute(
            "SELECT MAX(json_extract(data,'$.until')) FROM artifacts WHERE kind='github-cooldown'"
        ).fetchone()
        self.cooldown = max(self.cooldown, row[0] or 0)
        self.persist()

    def persist(self) -> None:
        if self.cooldown_path is None:
            return
        path = self.cooldown_path
        with path.with_suffix(".lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.cooldown = max(self.cooldown, float(path.read_text()) if path.exists() else 0)
            if self.cooldown:
                temporary = path.with_suffix(".tmp")
                temporary.write_text(str(self.cooldown))
                temporary.replace(path)

    def defer(self, store: Store, task_id: int, exc: Deferred, *, recovery: bool = False) -> None:
        self.persist()
        task = store.task(task_id)
        recovery = recovery or bool(
            store.db.execute(
                "SELECT 1 FROM operations WHERE task_id=? AND state!='succeeded'", (task_id,)
            ).fetchone()
        )
        with store.db:
            store.db.execute(
                "INSERT INTO artifacts(task_id,sha,kind,policy,data) "
                "VALUES(?,?,'github-cooldown','',?)",
                (
                    task_id,
                    task["target_sha"],
                    json.dumps({"until": self.cooldown, "recovery": recovery}),
                ),
            )
        store.halt(task_id, State(task["state"]), str(exc))

    def due(self, *, spacing: bool = True) -> float:
        now = time.time()
        while self.recent and self.recent[0] <= now - 3600:
            self.recent.popleft()
        return float(
            max(
                self.cooldown,
                self.spacing if spacing else 0,
                self.recent[0] + 3600 if len(self.recent) >= self.budget else 0,
                self.reset
                if self.remaining is not None and self.remaining <= self.limit * self.reserve
                else 0,
            )
        )

    def start(self, write: bool) -> None:
        now = time.time()
        if now < self.cooldown or (
            background.get() and not write and now < self.due(spacing=False)
        ):
            raise Deferred(f"GitHub requests deferred until {self.due():.0f}")
        self.counts["writes" if write else "background" if background.get() else "checks"] += 1
        if background.get():
            self.recent.append(now)

    def observe(self, raw: str, failed: bool, error: str = "") -> None:
        headers, body = response(raw)
        if headers.get("x-ratelimit-resource") == "core":
            self.remaining = int(headers["x-ratelimit-remaining"])
            self.limit = int(headers["x-ratelimit-limit"])
            self.reset = float(headers["x-ratelimit-reset"])
        status = raw.splitlines()[0] if raw.startswith("HTTP/") else error
        limited = bool(re.search(r"\b429\b", status)) or (
            bool(re.search(r"\b403\b", status))
            and (
                headers.get("x-ratelimit-remaining") == "0"
                or "retry-after" in headers
                or re.search(r"rate limit|abuse detection", body + error, re.I)
            )
        )
        if failed and limited:
            self.failures += 1
            retry = headers.get("retry-after", "0")
            deadline = (
                time.time() + float(retry)
                if retry.isdigit()
                else parsedate_to_datetime(retry).timestamp()
            )
            self.cooldown = max(
                self.cooldown,
                deadline,
                float(headers["x-ratelimit-reset"])
                if headers.get("x-ratelimit-remaining") == "0" and "x-ratelimit-reset" in headers
                else time.time() + min(300, 30 * 2 ** min(self.failures - 1, 4)),
            )
            self.persist()
            raise Deferred(f"GitHub rate limit; cooling until {self.cooldown:.0f}")
        if not failed:
            self.failures = 0


@dataclass(frozen=True)
class Target:
    repository: str
    kind: str
    number: int

    @classmethod
    def parse(cls, url: str) -> "Target":
        match = re.fullmatch(
            r"https://github\.com/([\w.-]+/[\w.-]+)/(issues|pull)/([1-9][0-9]*)/?", url
        )
        if not match:
            raise ValueError("Expected https://github.com/OWNER/REPO/issues/N or /pull/N")
        return cls(match[1].lower(), match[2], int(match[3]))

    @property
    def url(self) -> str:
        return f"https://github.com/{self.repository}/{self.kind}/{self.number}"


async def command(*args: str, cwd: str | None = None, input_data: str | None = None) -> str:
    usage = traffic.get() if args[:2] == ("gh", "api") else None
    if usage:
        usage.start("--method" in args and args[args.index("--method") + 1] != "GET")
        args = (*args, "--include")
    process = await launch(
        *args,
        cwd=cwd,
        stdin=asyncio.subprocess.PIPE if input_data is not None else None,
    )
    try:
        stdout, stderr = await asyncio.wait_for(
            process.communicate(input_data.encode() if input_data is not None else None), timeout=60
        )
    except BaseException:
        await stop(process)
        raise
    completed(process)
    if usage:
        usage.observe(stdout.decode(), bool(process.returncode), stderr.decode(errors="replace"))
    if process.returncode:
        message = Redactor().text(stderr.decode(errors="replace"))[-2000:]
        if args[0] == "gh" and ("HTTP 403" in message or "HTTP 401" in message):
            raise PermissionError(message)
        if args[0] == "gh" and re.search(r"HTTP 5\d\d", message):
            raise ConnectionError(message)
        raise RuntimeError(message)
    return stdout.decode()


async def read_command(*args: str) -> str:
    """Retry only read transports; write ambiguity is owned by Controlled.perform."""
    attempts = 0
    while True:
        try:
            return await command(*args)
        except (RuntimeError, ConnectionError, TimeoutError) as exc:
            if not isinstance(exc, (ConnectionError, TimeoutError)) and not re.search(
                r"\bEOF\b|connection (reset|closed)|TLS handshake timeout|i/o timeout",
                str(exc),
                re.I,
            ):
                raise
            attempts += 1
            if attempts >= 3:
                raise ConnectionError(str(exc)) from exc
            await asyncio.sleep(0.25 * attempts)


class GitHub:
    def report(self) -> None:
        from .events import LOG

        usage = self.traffic
        if (
            any(usage.counts[key] for key in ("background", "checks", "writes"))
            or usage.cooldown != usage.reported_cooldown
            or (usage.counts and time.monotonic() - usage.reported_at >= 300)
        ):
            LOG.info(
                "GitHub 周期请求：%s；后台预算=%s/小时；剩余=%s；下次后台请求/冷却=%.0f",
                dict(usage.counts),
                usage.budget,
                usage.remaining,
                usage.due(),
            )
            usage.counts.clear()
            usage.reported_at = time.monotonic()
            usage.reported_cooldown = usage.cooldown

    @cached_property
    def traffic(self) -> Traffic:
        return Traffic()

    @cached_property
    def pending(self) -> dict[tuple[int, str], asyncio.Task[str]]:
        return {}

    async def api(self, path: str) -> str:
        key = (self.traffic.generation, path)

        async def fetch() -> str:
            token = traffic.set(self.traffic)
            try:
                return await read_command("gh", "api", path)
            finally:
                traffic.reset(token)

        # Foreground safety checks must start after their own checkpoint, never
        # join an older read that could straddle a write or an Agent execution.
        if not background.get():
            return await fetch()
        if key in self.pending and not self.pending[key].done():
            self.traffic.counts["saved"] += 1
            return await self.pending[key]
        task = self.pending[key] = asyncio.create_task(fetch())
        try:
            return await task
        finally:
            if self.pending.get(key) is task:
                self.pending.pop(key, None)

    async def read(self, path: str) -> Any:
        return json.loads(response(await self.api(path))[1])

    async def pages(self, path: str, field: str | None = None) -> list[dict[str, Any]]:
        rows = []
        while path:
            headers, raw = response(await self.api(path))
            page = json.loads(raw)
            rows.extend(page[field] if field else page)
            link = re.search(r'<([^>]+)>; rel="next"', headers.get("link", ""))
            path = link[1] if link else ""
        return rows

    async def mutate(
        self, path: str, payload: dict[str, Any], *, method: str = "POST"
    ) -> dict[str, Any]:
        token = traffic.set(self.traffic)
        self.traffic.generation += 1
        self.traffic.snapshots.clear()
        try:
            raw = await command(
                "gh",
                "api",
                "--method",
                method,
                path,
                "--input",
                "-",
                input_data=json.dumps(payload),
            )
            result: dict[str, Any] = json.loads(response(raw)[1])
            return result
        finally:
            self.traffic.generation += 1
            self.traffic.snapshots.clear()
            traffic.reset(token)

    async def snapshot(self, target: Target) -> dict[str, Any]:
        resource = "issues" if target.kind == "issues" else "pulls"
        data = await self.read(f"repos/{target.repository}/{resource}/{target.number}")
        return self.facts(target, data)

    def facts(self, target: Target, data: dict[str, Any]) -> dict[str, Any]:
        if target.kind == "issues" and "pull_request" in data:
            raise ValueError("This is a pull request; register its /pull/N URL")
        snapshot = {
            "url": target.url,
            "repository": target.repository,
            "kind": target.kind,
            "number": target.number,
            "title": data["title"],
            "body": data.get("body") or "",
            "state": data["state"],
            "updated_at": data["updated_at"],
            "node_id": data.get("node_id"),
            "labels": [item["name"] for item in data.get("labels", [])],
        }
        if target.kind == "pull":
            snapshot.update(
                {
                    "head_sha": data["head"]["sha"],
                    "base_sha": data["base"]["sha"],
                    "base_ref": data["base"]["ref"],
                    "base_repository": data["base"]["repo"]["full_name"],
                    "merged": data["merged"],
                    "head_repository": data["head"]["repo"]["full_name"],
                    "head_ref": data["head"].get("ref", ""),
                    "draft": data.get("draft", False),
                    "author": data.get("user", {}).get("login", ""),
                }
            )
        return Redactor().clean(snapshot)  # type: ignore[no-any-return]

    async def instructions(self, task: dict[str, Any]) -> list[dict[str, Any]]:
        target = Target.parse(task["url"])
        return await self.pages(
            f"repos/{target.repository}/issues/{target.number}/comments?per_page=100"
        )

    async def labels(self, target: Target) -> list[str]:
        rows = await self.pages(
            f"repos/{target.repository}/issues/{target.number}/labels?per_page=100"
        )
        return [row["name"] for row in rows]

    async def task_snapshot(self, task: dict[str, Any]) -> dict[str, Any]:
        key = (task["url"], task.get("pr_number"))
        cached = self.traffic.snapshots.get(key)
        if background.get() and cached and time.monotonic() < cached[0]:
            self.traffic.counts["saved"] += 1
            return dict(cached[1])
        if not background.get():
            self.traffic.generation += 1
        generation = self.traffic.generation
        expires = time.monotonic() + 60
        target = Target.parse(task["url"])
        snapshot = await self.snapshot(target)
        if task.get("pr_number") and target.kind == "issues":
            pull = await self.snapshot(Target(target.repository, "pull", task["pr_number"]))
            snapshot.update(
                {
                    key: value
                    for key, value in pull.items()
                    if key not in {"url", "kind", "number", "title", "body", "state", "updated_at"}
                }
            )
            snapshot.update(pull_url=pull["url"], pull_title=pull["title"], pull_body=pull["body"])
            if pull["state"] != "open":
                snapshot["state"] = "closed"
        cached = self.traffic.snapshots.get(key)
        if generation == self.traffic.generation and (not cached or cached[0] <= expires):
            self.traffic.snapshots[key] = (expires, dict(snapshot))
        return snapshot

    async def gates(self, task: dict[str, Any]) -> dict[str, Any]:
        repository = task["snapshot"]["repository"]
        number = task["pr_number"]
        owner, name = repository.split("/")
        query = (
            f"query{{repository(owner:{json.dumps(owner)},name:{json.dumps(name)})"
            f"{{pullRequest(number:{number}){{headRefOid isDraft reviewDecision "
            "mergeStateStatus mergeable author{login}}}}"
        )
        token = traffic.set(self.traffic)
        try:
            raw = await read_command("gh", "api", "graphql", "-f", "query=" + query)
            data = json.loads(response(raw)[1])
            if data.get("errors"):
                raise RuntimeError(Redactor().text(json.dumps(data["errors"])))
            pull: dict[str, Any] = data["data"]["repository"]["pullRequest"]
            pull["reviewDecision"] = pull.get("reviewDecision") or ""
            return pull
        finally:
            traffic.reset(token)
