"""OS exclusion, renewable ownership and a durable journal for controller subprocesses."""

import asyncio
import fcntl
import hashlib
import os
import time
import uuid
from pathlib import Path
from typing import Any, TextIO

from .model import State
from .processes import observer
from .store import Store


def identity(pid: int) -> str | None:
    try:
        fields = (Path("/proc") / str(pid) / "stat").read_text().rsplit(")", 1)[1].split()
        if fields[0] == "Z":
            return None
        return Path("/proc/sys/kernel/random/boot_id").read_text().strip() + ":" + fields[19]
    except (FileNotFoundError, ProcessLookupError):
        return None


def session_alive(pid: int) -> bool:
    for entry in Path("/proc").glob("[0-9]*"):
        try:
            fields = (entry / "stat").read_text().rsplit(")", 1)[1].split()
        except (FileNotFoundError, ProcessLookupError):
            continue
        if fields[0] != "Z" and int(fields[3]) == pid:
            return True
    return False


def resource(task: dict[str, Any]) -> str:
    snapshot = task["snapshot"]
    repo = snapshot.get("head_repository", snapshot["repository"]).lower()
    if task["pr_number"]:
        return (
            f"{repo}:branch:{snapshot['head_ref']}"
            if snapshot.get("head_ref")
            else f"{repo}:pull:{task['pr_number']}"
        )
    slug = hashlib.sha256(task["url"].encode()).hexdigest()[:12]
    return f"{repo}:branch:gongcao/work-{slug}"


class Lease:
    def __init__(self, store: Store, task_id: int, *, recovery: bool = False, ttl: float = 30):
        self.store, self.task_id, self.recovery, self.ttl = store, task_id, recovery, ttl
        self.owner = uuid.uuid4().hex
        self.lost = False
        self.acquired = False
        self.lock: TextIO | None = None
        self.watcher: asyncio.Task[None] | None = None
        self.processes: dict[int, str] = {}

    async def __aenter__(self) -> "Lease":
        self.lock = (self.store.root / f"task-{self.task_id}.lock").open("a")
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self.lock.close()
            self.lock = None
            return self
        try:
            with self.store.db:
                self.store.db.execute("BEGIN IMMEDIATE")
                existing = self.store.db.execute(
                    "SELECT * FROM leases WHERE task_id=?", (self.task_id,)
                ).fetchone()
                unsettled = self.store.db.execute(
                    "SELECT 1 FROM processes WHERE task_id=? AND state!='stopped'",
                    (self.task_id,),
                ).fetchone()
                if (existing or unsettled) and not self.recovery:
                    self.store.db.execute(
                        "UPDATE tasks SET state=?,reason=? WHERE id=? AND state!=? AND stage!=?",
                        (
                            State.RECONCILE,
                            "Previous lease requires recovery",
                            self.task_id,
                            State.CANCELLED,
                            "merged",
                        ),
                    )
                    return self
                leases = self.store.db.execute("SELECT * FROM leases").fetchall()
                active = sum(
                    row["task_id"] != self.task_id and identity(row["pid"]) == row["identity"]
                    for row in leases
                )
                if active >= 3:
                    self.blocked("Global execution capacity is occupied (3 tasks)")
                    return self
                key = resource(self.store.task(self.task_id))
                object_key = self.store.task(self.task_id)["url"].rstrip("/").lower()
                if any(
                    (row["resource"] == key or row["object"] == object_key)
                    and row["task_id"] != self.task_id
                    for row in leases
                ):
                    self.blocked("PR resource is occupied by another registered task")
                    return self
                self.store.db.execute(
                    "INSERT OR REPLACE INTO leases VALUES(?,?,?,?,?,?,?)",
                    (
                        self.task_id,
                        self.owner,
                        os.getpid(),
                        identity(os.getpid()),
                        key,
                        object_key,
                        time.time() + self.ttl,
                    ),
                )
            self.store.owners[self.task_id] = self.owner
            self.acquired = True
            self.token = observer.set(self)
            parent = asyncio.current_task()
            assert parent is not None
            self.watcher = asyncio.create_task(self.watch(parent))
            return self
        except BaseException:
            self.lock.close()
            self.lock = None
            raise

    def blocked(self, reason: str) -> None:
        self.store.db.execute(
            "UPDATE tasks SET state=?,reason=?,updated=? WHERE id=? AND state IN (?,?,?,?)",
            (
                State.WAITING_DEPENDENCY,
                reason,
                time.time(),
                self.task_id,
                State.QUEUED,
                State.WAITING_DEPENDENCY,
                State.WAITING_ENVIRONMENT,
                State.FAILED,
            ),
        )

    async def watch(self, parent: asyncio.Task[Any]) -> None:
        try:
            while True:
                await asyncio.sleep(self.ttl / 3)
                with self.store.db:
                    count = self.store.db.execute(
                        "UPDATE leases SET expires=? WHERE task_id=? AND owner=? AND expires>=?",
                        (time.time() + self.ttl, self.task_id, self.owner, time.time()),
                    ).rowcount
                if not count:
                    raise RuntimeError("Lease ownership expired")
        except asyncio.CancelledError:
            return
        except Exception:
            self.lost = True
            parent.cancel()

    def bind_resource(self) -> None:
        with self.store.db:
            self.store.guard(self.store.task(self.task_id))
            self.store.db.execute(
                "UPDATE leases SET resource=? WHERE task_id=? AND owner=?",
                (resource(self.store.task(self.task_id)), self.task_id, self.owner),
            )

    def intent(self, label: str) -> str:
        if not self.store.db.execute(
            "SELECT 1 FROM leases WHERE task_id=? AND owner=? AND expires>=?",
            (self.task_id, self.owner, time.time()),
        ).fetchone():
            raise RuntimeError("Execution lease lost")
        key = uuid.uuid4().hex
        with self.store.db:
            self.store.db.execute(
                "INSERT INTO processes VALUES(?,?,?,?,NULL,?,?)",
                (key, self.task_id, self.owner, label, identity(os.getpid()), "pending"),
            )
        return key

    def attached(self, key: str, pid: int) -> None:
        self.processes[pid] = key
        with self.store.db:
            self.store.db.execute(
                "UPDATE processes SET pid=?,identity=?,state=? WHERE id=?",
                (pid, identity(pid), "running", key),
            )

    def aborted(self, key: str) -> None:
        with self.store.db:
            self.store.db.execute("UPDATE processes SET state='stopped' WHERE id=?", (key,))

    def stopped(self, pid: int) -> None:
        if key := self.processes.get(pid):
            with self.store.db:
                self.store.db.execute("UPDATE processes SET state=? WHERE id=?", ("stopped", key))
                self.store.db.execute(
                    "DELETE FROM processes WHERE task_id=? AND state='stopped' AND id NOT IN "
                    "(SELECT id FROM processes WHERE task_id=? AND state='stopped' "
                    "ORDER BY rowid DESC LIMIT 1000)",
                    (self.task_id, self.task_id),
                )

    def uncertain(self, pid: int) -> None:
        if key := self.processes.get(pid):
            with self.store.db:
                self.store.db.execute("UPDATE processes SET state='uncertain' WHERE id=?", (key,))

    async def __aexit__(self, *exc: object) -> None:
        try:
            try:
                if self.watcher:
                    self.watcher.cancel()
                    await asyncio.gather(self.watcher, return_exceptions=True)
            finally:
                if self.acquired:
                    observer.reset(self.token)
                    self.store.owners.pop(self.task_id, None)
                    with self.store.db:
                        unresolved = self.store.db.execute(
                            "SELECT 1 FROM processes WHERE task_id=? AND state!='stopped' "
                            "UNION SELECT 1 FROM operations WHERE task_id=? AND state!='succeeded'",
                            (self.task_id, self.task_id),
                        ).fetchone()
                        if unresolved:
                            self.store.db.execute(
                                "UPDATE leases SET expires=0 WHERE task_id=? AND owner=?",
                                (self.task_id, self.owner),
                            )
                        else:
                            self.store.db.execute(
                                "DELETE FROM leases WHERE task_id=? AND owner=?",
                                (self.task_id, self.owner),
                            )
        finally:
            if self.lock:
                self.lock.close()
