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
from .control import Controls, baseline
from .events import Redactor, task_event
from .github import Deferred, GitHub, Target, background
from .model import Stage, State
from .processes import CleanupError, NotStarted
from .recovery import Recovery
from .store import Store
from .workspace import clone_prefix, prepare_repository

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
        github.traffic.restore(store)
        self.controller = store.db.execute("SELECT id FROM controller").fetchone()[0]
        self.locks: list[TextIO] = []
        self.retry: dict[str, tuple[int, float]] = {}
        self.next_scan = 0.0
        self.next_facts = 0.0
        self.repositories: dict[str, str] = {}
        self.scan_results: dict[tuple[str, str], tuple[int, ...]] = {}

    def records(self) -> list[dict[str, Any]]:
        return [dict(row) for row in self.store.db.execute("SELECT * FROM claims ORDER BY url")]

    def manual(self, task_id: int) -> None:
        """Explicit registration owns a status anchor, never an intake claim."""
        task = self.store.task(task_id)
        data = {
            "kind": "manual",
            "repo": task["snapshot"]["repository"],
            "path": task["repo_path"],
            "base_sha": task["target_sha"],
            "mode": task["control"]["mode"],
            "policy": self.config.policy_hash,
            "marker": f"<!-- gongcao:controller={self.controller};task={task['url']} -->",
            "attempted": False,
        }
        with self.store.db:
            self.store.db.execute(
                "INSERT OR IGNORE INTO claims(url,data,task_id) VALUES(?,?,?)",
                (task["url"], json.dumps(data), task_id),
            )
            self.store.progress(task_id)

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
        LOG.warning("[%s] 扫描/同步异常（%s），退避后重试", key, type(exc).__name__)
        self.save(key, dirty=1, reason=message)
        row = self.store.db.execute("SELECT * FROM claims WHERE url=?", (key,)).fetchone()
        if row and row["task_id"]:

            def failed(data: dict[str, Any]) -> None:
                previous = data.get("status_retry", {})
                failures = previous.get("failures", 0) + 1
                data["status_retry"] = {
                    "failures": failures,
                    "next_at": time.time() + min(300, 5 * 2 ** min(failures, 6)),
                }

            self.store.claim_data(key, failed)

    def due(self, key: str) -> bool:
        row = self.store.db.execute("SELECT * FROM claims WHERE url=?", (key,)).fetchone()
        if row and row["task_id"]:
            retry = json.loads(row["data"]).get("status_retry", {})
            if retry:
                return bool(retry["next_at"] <= time.time())
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
            token = background.set(True)
            try:
                await self.cycle(discover=discover)
            finally:
                background.reset(token)

    async def cycle(self, *, discover: bool) -> None:
        # Reconcile old claims and pending PATCHes before admitting new work.
        facts_due = time.monotonic() >= self.next_facts and time.time() >= self.github.traffic.due()
        if facts_due:
            self.next_facts = time.monotonic() + self.config.discovery.interval_seconds
        for row in self.records():
            if not self.due(row["url"]):
                continue
            try:
                if row["task_id"] is None:
                    await self.claim(row)
                elif not row["confirmed"]:
                    await self.publish(row)
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
        if (
            discover
            and self.config.discovery.enabled
            and time.monotonic() >= self.next_scan
            and time.time() >= self.github.traffic.due()
        ):
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

    async def eligible(
        self,
        target: Target,
        label: str,
        marker: str = "",
        *,
        raw: dict[str, Any] | None = None,
        comments: list[dict[str, Any]] | None = None,
    ) -> dict[str, Any]:
        if raw is None:
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
        if comments is None:
            comments = await self.github.instructions({"url": target.url})
        if any(
            "<!-- gongcao:" in item.get("body", "") and (not marker or marker not in item["body"])
            for item in comments
        ):
            raise ValueError("Another controller/unknown Gongcao status marker already exists")
        return self.github.facts(target, raw)

    async def scan(self) -> None:
        # Preparation is independent of claim capacity and pending-task backlog.
        prepared = set()
        for source in self.config.discovery.sources:
            if source.repo in prepared:
                continue
            prepared.add(source.repo)
            key = "prepare:" + source.repo
            if not self.due(key):
                continue
            try:
                if self.locks:
                    result = await prepare_repository(source)
                else:
                    # Direct one-shot scans share the same OS lock as serve.
                    with lock_path(source.repo).open("a") as handle:
                        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        result = await prepare_repository(source)
                if self.repositories.get(source.repo) not in {"已复用", "已克隆"}:
                    LOG.info("[%s] 仓库%s：%s", source.repo, result, source.path)
                    self.store.last_activity = time.monotonic()
                if self.repositories.get(source.repo) != "已克隆":
                    self.repositories[source.repo] = result
                self.retry.pop(key, None)
            except CleanupError:
                self.repositories[source.repo] = "待核对：clone 归属或进程收束未确认"
                self.retry[key] = (0, float("inf"))
                LOG.warning(
                    "[%s] 仓库准备待核对，暂停自动重试；保留临时目录及 JSON 意图，"
                    "位置：%s；先核对子进程/目录归属，勿直接删除",
                    source.repo,
                    source.path.parent / (clone_prefix(source.path) + "*"),
                )
            except Exception as exc:
                reason = (
                    "目标目录已存在或发生竞争"
                    if isinstance(exc, FileExistsError)
                    else "目录或认证权限不足"
                    if isinstance(exc, PermissionError) or "Authentication failed" in str(exc)
                    else "现有目录不是 Git 仓库"
                    if "not a git repository" in str(exc)
                    else "网络不可达或超时"
                    if isinstance(exc, (ConnectionError, TimeoutError))
                    or any(word in str(exc) for word in ("Could not resolve", "Failed to connect"))
                    else str(exc).splitlines()[0][:160]
                    if isinstance(exc, ValueError)
                    else f"Git/文件系统不可用（{type(exc).__name__}）"
                )
                self.repositories[source.repo] = "准备失败：" + Redactor().text(reason)
                self.warning(key, exc)
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
            if (
                not available
                or not self.due(source.repo)
                or self.repositories.get(source.repo) not in {"已复用", "已克隆"}
            ):
                continue
            try:
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
                found = tuple(sorted(item["number"] for item in rows if "pull_request" not in item))
                scan_key = (source.repo, source.label)
                previous = self.scan_results.get(scan_key, ())
                if found != previous:
                    LOG.info(
                        "[%s] 扫描变化：标签 %s，候选 %s，新增 %s，移除 %s",
                        source.repo,
                        source.label,
                        len(found),
                        len(set(found) - set(previous)),
                        len(set(previous) - set(found)),
                    )
                    self.store.last_activity = time.monotonic()
                self.scan_results[scan_key] = found
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
                        await self.prepare(source, target, item)
                    except ValueError:
                        # Rejected candidates remain visible in read-only diagnostics; don't
                        # repeat one warning per candidate on every empty-progress scan.
                        if found != previous:
                            LOG.info("[%s #%s] 未领取：资格核验未通过", source.repo, target.number)
                        continue
                    available -= 1
                self.retry.pop(source.repo, None)
            except Exception as exc:
                self.warning(source.repo, exc)

    async def prepare(
        self, source: Source, target: Target, raw: dict[str, Any] | None = None
    ) -> None:
        snapshot = await self.eligible(target, source.label, raw=raw)
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

    async def owned(
        self, row: dict[str, Any], comments: list[dict[str, Any]] | None = None
    ) -> dict[str, Any] | None:
        data = json.loads(row["data"])
        target = Target.parse(row["url"])
        proof = self.store.owned_comments.get(row["url"])
        if (
            proof
            and row["comment_id"] == proof[0]
            and row["confirmed"]
            and not row["intent"]
            and not row["reason"]
        ):
            try:
                item: dict[str, Any] = await self.github.read(
                    f"repos/{target.repository}/issues/comments/{proof[0]}"
                )
                if (
                    (
                        item["id"],
                        item["user"].get("id"),
                        item["user"]["login"].lower(),
                        data["marker"],
                    )
                    == proof
                    and data["marker"] in item.get("body", "")
                    and item["body"] == row["confirmed"]
                ):
                    return item
            except Deferred:
                raise
            except Exception:
                pass  # An anomalous direct read requires full uniqueness/ownership reconciliation.
            self.store.owned_comments.pop(row["url"], None)
        if comments is None:
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
        observed = await self.github.read(f"repos/{target.repository}/issues/comments/{item['id']}")
        if (
            any(observed.get(key) != item.get(key) for key in ("id", "body"))
            or observed.get("user", {}).get("login", "").lower() != data["actor"]
            or observed.get("user", {}).get("id") != item["user"].get("id")
        ):
            raise ValueError("Status comment changed during observation")
        self.store.owned_comments[row["url"]] = (
            item["id"],
            item["user"].get("id"),
            data["actor"],
            data["marker"],
        )
        return item

    async def claim(self, row: dict[str, Any]) -> None:
        token = background.set(False)
        try:
            await self._claim(row)
        finally:
            background.reset(token)

    async def _claim(self, row: dict[str, Any]) -> None:
        data = json.loads(row["data"])
        target = Target.parse(row["url"])
        manual = data.get("kind") == "manual"
        if manual and "actor" not in data:
            data["actor"] = (await self.github.read("user"))["login"].lower()
            self.store.claim_data(row["url"], lambda current: current.update(actor=data["actor"]))
            row["data"] = json.dumps(data)
        comments = await self.github.instructions({"url": row["url"]})
        item = await self.owned(row, comments)
        if item is None:
            if data["attempted"]:
                raise ValueError("Unconfirmed claim POST; refusing replay or Agent execution")
            if not manual and not self.config.discovery.enabled:
                raise ValueError("Discovery disabled; retaining the planned claim without a POST")
            if not manual:
                await self.eligible(target, data["label"], data["marker"], comments=comments)
            body = (
                data["marker"]
                + (
                    "\nGongcao 手工登记状态锚点。"
                    if manual
                    else "\nGongcao claim pending confirmation."
                )
                + f" Mode: {data['mode']}."
                + f" SHA: `{data['base_sha']}`"
            )
            data["attempted"] = True
            with Controls(self.store).transaction():
                self.store.claim_data(row["url"], lambda current: current.update(attempted=True))
                self.store.db.execute("UPDATE claims SET intent=? WHERE url=?", (body, row["url"]))
            try:
                response = await self.github.mutate(
                    f"repos/{target.repository}/issues/{target.number}/comments", {"body": body}
                )
                self.save(row["url"], comment_id=response["id"])
                row["comment_id"] = response["id"]
            except Deferred:
                data["attempted"] = False
                with Controls(self.store).transaction():
                    self.store.claim_data(
                        row["url"], lambda current: current.update(attempted=False)
                    )
                    self.store.db.execute("UPDATE claims SET intent='' WHERE url=?", (row["url"],))
                raise
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
        if manual:
            return
        # A confirmed claim survives label removal; lifecycle changes remain a registration gate.
        snapshot = self.github.facts(
            target, await self.github.read(f"repos/{target.repository}/issues/{target.number}")
        )
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
        task_event(self.store, task_id, "领取已远端确认")
        row.update(task_id=task_id, comment_id=item["id"], confirmed=item["body"], intent="")
        await self.publish(row)

    def overview(self, *, once: bool, config_path: Path | None, jobs: int) -> None:
        sources = self.config.discovery.sources
        LOG.info(
            "启动概览：%s；配置=%s；状态目录=%s；仓库根目录=%s；已登记任务=%s；jobs=%s；扫描间隔=%s秒；授权操作员=%s",
            "单次运行（--once）" if once else "持续运行",
            config_path or "默认配置",
            self.store.root,
            self.config.discovery.repo_root or "显式来源路径",
            len(self.store.tasks()),
            jobs,
            self.config.discovery.interval_seconds,
            ",".join(self.config.copilot_operators) or "未配置",
        )
        for source in sources:
            LOG.info(
                "[%s] %s；路径=%s；标签=%s；模式=%s",
                source.repo,
                self.repositories.get(source.repo, "未初始化（发现已禁用）"),
                source.path,
                source.label,
                source.mode,
            )

    def render(self, row: dict[str, Any], event: dict[str, Any] | None = None) -> str:
        task = event["task"] if event else self.store.task(row["task_id"])
        control = task["control"]
        runs = event["runs"] if event else self.store.runs(task["id"])
        retry_available = bool(
            runs and runs[-1]["details"].get("source", {}).get("baseline") == baseline(task)
        )
        pull = (
            f"https://github.com/{task['snapshot']['repository']}/pull/{task['pr_number']}"
            if task["pr_number"]
            else "pending"
        )
        action = (
            "在本登记对象发新的 /gongcao step，推进一个业务阶段"
            if task["state"] == State.WAITING_INSTRUCTION
            else "补齐所列材料后，在本登记对象发新的 /gongcao step；高级命令 /gongcao retry 仍可用"
            if task["state"] in {State.HUMAN, State.FAILED, State.WAITING_ENVIRONMENT}
            and task["snapshot"].get("state") == "open"
            and not task["cancel_requested"]
            and retry_available
            else "需人工核对来源、进程清理或未知写入；step 不能绕过核验"
            if task["state"] in {State.RECONCILE, State.HUMAN}
            else "已完成自动流程，等待所有者人工合并"
            if task["stage"] == Stage.MERGEABLE
            else task["reason"][:2000] or "Controller will advance within the configured policy"
        )
        marker = (
            f"<!-- gongcao-progress:{event['id']} -->"
            if event
            else json.loads(row["data"])["marker"]
        )
        body = (
            marker + f"\n**Gongcao** · Task `{task['id']}`\n"
            f"Stage: `{task['stage']}` · State: `{task['state']}`\n"
            f"Mode: `{control['mode']}` · Until: `{control.get('target') or '-'}`\n"
            f"PR: {pull}\nTarget SHA: `{task['target_sha']}`\nNext / reason: {action}"
            f"\nReason: {task['reason'][:2000] or '-'}"
        )
        if step := control.get("step_result"):
            body += (
                "\n本次 Step："
                + {
                    "advanced": "已推进一个阶段",
                    "checked": "只读核对完成，未推进阶段",
                    "blocked": "本次仍受阻，需新 Step 才会再尝试",
                }[step["status"]]
            )
            body += "; " + step["reason"][:1000]
        from .coordination import current

        advice = event.get("coordination") if event else current(self.store, task["id"])
        if advice and advice.get("status") == "completed":
            report = advice["report"]
            body += "\n协调 Agent 建议（非控制器确认事实，不构成执行授权）："
            body += "\n依据：" + "; ".join(report["facts"])[:1500]
            body += "\n阻塞分析：" + "; ".join(report["blockers"])[:1000]
            body += (
                "\n建议："
                + "; ".join(
                    f"{s['action']}；责任方={s['owner']}；所需输入={s['inputs']}"
                    for s in report["suggestions"]
                )[:2000]
            )
        if event and (corrects := event.get("corrects")):
            body += (
                f"\nCorrection of event `{corrects['event_id']}`: "
                f"[comment {corrects['comment_id']}]"
                f"({task['url']}#issuecomment-{corrects['comment_id']})"
            )

        if runs:
            run = runs[-1]
            result = json.loads(run["result"]) if run["result"] else {}
            body += (
                f"\nRun: `{run['id']}` · session: `{run['state']}`"
                f" · report: `{result.get('conclusion', 'unavailable')}`"
                "\nA session ending does not complete the business stage or acceptance gates."
            )
            if result:
                body += (
                    "\nAgent report excerpts (full report retained locally): "
                    + result["summary"][:4000]
                )
                body += "\nReported checks/basis: " + "; ".join(result["basis"])[:6000]
                body += "\nRemaining / missing inputs: " + "; ".join(result["next_steps"])[:6000]
            save = run["details"].get("save", {})
            body += "\nRemote checkpoint: " + save.get("state", "not confirmed")
            saved = next(
                (
                    r["details"]["save"]
                    for r in reversed(runs)
                    if r["details"].get("save", {}).get("state") == "confirmed"
                    and r["details"]["save"]["target_sha"] == task["target_sha"]
                    and r["details"]["save"]["baseline"] == baseline(task)
                ),
                None,
            )
            if saved:
                url = f"https://github.com/{task['snapshot']['repository']}"
                body += (
                    f"\nSaved WIP: [{saved['branch']}]({url}/tree/{saved['branch']})"
                    f" · [{saved['sha']}]({url}/commit/{saved['sha']})"
                    f" · Run: `{saved['run_id']}` (last confirmed for this task version)"
                    f"\nChanges: {saved['summary'][:4000]}"
                )
            if run["details"].get("save_error"):
                body += "\nSave error: " + run["details"]["save_error"][:2000]
            execution = run["details"].get("execution")
            if execution:
                body += (
                    f"\nSDK confirmed: `{execution['model']}` / "
                    f"`{execution['reasoning_effort']}` · source: {execution['source']}"
                )
            else:
                requested = run["details"].get("requested_execution")
                body += "\nActual model/effort: unconfirmed (historical values are not inferred)"
                if requested:
                    body += (
                        f"; requested: `{requested['model']}` / `{requested['reasoning_effort']}`"
                    )
            source = run["details"].get("source")
            if source:
                body += (
                    f"\nHost verified source: `{source['sha']}`; original target: "
                    f"`{run['target_sha']}`. Sandbox .git is intentionally inaccessible."
                )
        quality = [
            a["data"]
            for a in (event["artifacts"] if event else self.store.evidence(task["id"])["artifacts"])
            if a["kind"] == "quality-results" and a["valid"] and a["sha"] == task["target_sha"]
        ]
        if quality:
            body += "\nController checks: " + "; ".join(
                f"{item.get('category', 'check')}: "
                + {"passed": "PASS", "failed": "FAIL", "blocked": "NOT_RUN"}.get(
                    item.get("status"), "NOT_RUN"
                )
                for item in quality[-1].get("items", [])
            )
        else:
            body += "\nController acceptance: NOT_RUN (no current-version check evidence)"
        return Redactor().text(body)

    async def handoff(self, task_id: int) -> None:
        """Await the sole status publisher even while serve holds the discovery lock."""
        for row in self.records():
            if (
                row["task_id"] == task_id
                and (row["dirty"] or row["intent"])
                and self.due(row["url"])
            ):
                try:
                    await self.publish(row)
                except Exception as exc:
                    self.warning(row["url"], exc)

    async def publish(self, row: dict[str, Any]) -> None:
        token = background.set(False)
        try:
            await self._publish_locked(row)
        finally:
            background.reset(token)

    async def reconcile_status(self, task_id: int) -> None:
        """Recovery observes uncertain comments without sending any new feedback."""
        for row in self.records():
            if row["task_id"] != task_id:
                continue
            data = json.loads(row["data"])
            if (
                row["intent"]
                or (data.get("attempted") and not row["confirmed"])
                or any(e["attempted"] for e in data.get("progress", []))
            ):
                await self._publish_locked(row, read_only=True)

    async def _publish_locked(self, row: dict[str, Any], *, read_only: bool = False) -> None:
        # Foreground handoff and the background ticker share one persistent event queue.
        key = hashlib.sha256(row["url"].encode()).hexdigest()
        with (self.store.root / f"status-{key}.lock").open("a") as lock:
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    await asyncio.sleep(0.05)
            current = self.store.db.execute(
                "SELECT * FROM claims WHERE url=?", (row["url"],)
            ).fetchone()
            if (
                not read_only
                and not current["confirmed"]
                and json.loads(current["data"]).get("kind") == "manual"
            ):
                await self.claim(dict(current))
                current = self.store.db.execute(
                    "SELECT * FROM claims WHERE url=?", (row["url"],)
                ).fetchone()
            await self._publish(dict(current), read_only=read_only)
            self.store.claim_data(row["url"], lambda data: data.pop("status_retry", None))

    async def _publish(self, row: dict[str, Any], *, read_only: bool = False) -> None:
        item = await self.owned(row)
        if item is None:
            raise ValueError("Claim comment is missing")
        if row["intent"]:
            if item["body"] != row["intent"]:
                raise ValueError("Unconfirmed status PATCH; refusing replay")
            self.save(
                row["url"], comment_id=item["id"], confirmed=item["body"], intent="", reason=""
            )
            row.update(comment_id=item["id"], confirmed=item["body"], intent="")
        if item["body"] != row["confirmed"]:
            raise ValueError("Owned status comment was edited outside the recorded intent")
        while True:
            with Controls(self.store).transaction():
                data = json.loads(
                    self.store.db.execute(
                        "SELECT data FROM claims WHERE url=?", (row["url"],)
                    ).fetchone()[0]
                )
                queue = data.get("progress", [])
                if not queue:
                    self.store.db.execute(
                        "UPDATE claims SET dirty=0,reason='' WHERE url=?", (row["url"],)
                    )
                    return
            event = queue[0]
            body = event.get("body") or self.render(row, event)

            async def observe(
                event: dict[str, Any] = event, body: str = body, actor: str = data["actor"]
            ) -> dict[str, Any] | None:
                matches = [
                    c
                    for c in await self.github.instructions({"url": row["url"]})
                    if f"<!-- gongcao-progress:{event['id']} -->" in (c.get("body") or "")
                ]
                if len(matches) > 1 or (
                    matches
                    and (
                        matches[0]["body"] != body
                        or matches[0]["user"]["login"].lower() != actor
                        or matches[0]["user"].get("id") != item["user"].get("id")
                        or (
                            event.get("comment_id") is not None
                            and matches[0]["id"] != event["comment_id"]
                        )
                    )
                ):
                    raise ValueError("Progress POST ownership/content is not uniquely confirmed")
                return matches[0] if matches else None

            observed = await observe()
            if observed is None:
                if event["attempted"]:
                    raise ValueError("Unconfirmed progress POST; refusing replay")
                if read_only:
                    return

                def attempt(current: dict[str, Any], body: str = body) -> None:
                    current["progress"][0].update(body=body, attempted=True)

                self.store.claim_data(row["url"], attempt)
                target = Target.parse(row["url"])
                try:
                    response = await self.github.mutate(
                        f"repos/{target.repository}/issues/{target.number}/comments", {"body": body}
                    )
                    event["comment_id"] = response["id"]

                    def received(current: dict[str, Any], comment_id: int = response["id"]) -> None:
                        current["progress"][0]["comment_id"] = comment_id

                    self.store.claim_data(row["url"], received)
                except (Deferred, NotStarted):
                    self.store.claim_data(
                        row["url"], lambda d: d["progress"][0].update(attempted=False)
                    )
                    raise
                except Exception:
                    observed = await observe()
                    if observed is None:
                        raise
                else:
                    observed = await observe()
                if observed is None:
                    raise ValueError("Progress POST was not confirmed; refusing replay")

            assert observed is not None

            def confirm(
                current: dict[str, Any],
                event_id: str = event["id"],
                comment_id: int = observed["id"],
            ) -> None:
                if current["progress"][0]["id"] != event_id:
                    raise ValueError("Progress queue changed before confirmation")
                current["progress"].pop(0)
                current["progress_last"] = {"event_id": event_id, "comment_id": comment_id}

            self.store.claim_data(row["url"], confirm)

    async def refresh(self, task_id: int) -> None:
        """Publish only this task's dirty status; an active serve owns its own refresh."""
        rows = [
            r for r in self.records() if r["task_id"] == task_id and (r["dirty"] or r["intent"])
        ]
        for row in rows:
            repo = Target.parse(row["url"]).repository
            with os.fdopen(
                os.open(lock_path(repo), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600), "a"
            ) as handle:
                try:
                    fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    continue
                try:
                    await self.publish(row)
                except Exception as exc:
                    self.warning(row["url"], exc)
