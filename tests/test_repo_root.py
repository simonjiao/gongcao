import asyncio
import hashlib
from dataclasses import replace
from pathlib import Path

import pytest
from test_discovery import intake as intake

from gongcao.config import DiscoveryConfig, Source
from gongcao.discovery import Discovery
from gongcao.github import command
from gongcao.model import State
from gongcao.processes import CleanupError
from gongcao.scheduler import Scheduler
from gongcao.workspace import prepare_repository


def test_root_derivation_explicit_override_and_no_path_collision(tmp_path):
    config = DiscoveryConfig.load(
        {
            "repo_root": str(tmp_path),
            "sources": [
                {"repo": "SimonJiao/AirDB"},
                {"repo": "simonjiao/gongcao", "path": str(tmp_path / "existing")},
            ],
        }
    )
    assert config.sources == (
        Source("simonjiao/airdb", tmp_path / "simonjiao/airdb"),
        Source("simonjiao/gongcao", tmp_path / "existing"),
    )
    with pytest.raises(ValueError, match="conflicting"):
        DiscoveryConfig.load(
            {
                "sources": [
                    {"repo": "a/b", "path": str(tmp_path)},
                    {"repo": "c/d", "path": str(tmp_path)},
                ]
            }
        )
    with pytest.raises(ValueError, match="path or"):
        DiscoveryConfig.load({"sources": [{"repo": "a/b"}]})


@pytest.mark.parametrize(
    "name", ["a/..", "./b", "../b", "a//b", "/a/b", "a/b/", "a/b/c", "a/%2e%2e", "a/."]
)
def test_repository_names_cannot_escape_root(tmp_path, name):
    with pytest.raises(ValueError):
        DiscoveryConfig.load({"repo_root": str(tmp_path), "sources": [{"repo": name}]})


@pytest.mark.parametrize("suffix", ["/../escape", "/./same", "//empty"])
def test_repository_paths_reject_ambiguous_segments(tmp_path, suffix):
    with pytest.raises(ValueError):
        DiscoveryConfig.load({"repo_root": str(tmp_path) + suffix})


def test_symlink_ancestors_are_rejected_for_root_and_override(tmp_path):
    link = tmp_path / "link"
    link.symlink_to(tmp_path, target_is_directory=True)
    for settings in (
        {"repo_root": str(link / "new")},
        {"sources": [{"repo": "a/b", "path": str(link / "new")}]},
    ):
        with pytest.raises(ValueError, match="symlinks"):
            DiscoveryConfig.load(settings)


@pytest.fixture
def clone_transport(repo, monkeypatch):
    calls = []

    async def transport(*args, **kwargs):
        if "clone" not in args:
            return await command(*args, **kwargs)
        calls.append(args)
        destination = args[-1]
        await command("git", "clone", "--", str(repo), destination)
        await command("git", "remote", "set-url", "origin", args[-2], cwd=destination)
        return ""

    monkeypatch.setattr("gongcao.workspace.command", transport)
    return transport, calls


async def test_clone_and_restart_preserve_existing_head_and_dirty_worktree(
    tmp_path, clone_transport
):
    _, calls = clone_transport
    source = Source("example/demo", tmp_path / "clones/example/demo")
    assert await prepare_repository(source) == "已克隆"
    head = await command("git", "rev-parse", "HEAD", cwd=str(source.path))
    (source.path / "sample.txt").write_text("keep local work")
    assert await prepare_repository(source) == "已复用"
    assert len(calls) == 1 and "credential.helper=!gh auth git-credential" in calls[0]
    assert await command("git", "rev-parse", "HEAD", cwd=str(source.path)) == head
    assert (source.path / "sample.txt").read_text() == "keep local work"
    assert not list(source.path.parent.glob(".gongcao-clone-*"))


@pytest.mark.parametrize(
    "fault", ["network", "auth", "cancel", "cleanup", "race", "origin", "symlink"]
)
async def test_clone_failures_preserve_foreign_directories_and_clean_only_own_clone(
    tmp_path, clone_transport, monkeypatch, fault
):
    original, _ = clone_transport
    source = Source("example/demo", tmp_path / "clones/example/demo")
    other = tmp_path / "foreign"
    other.mkdir()
    (other / "sentinel").write_text("untouched")

    async def inject(*args, **kwargs):
        result = await original(*args, **kwargs)
        if "clone" in args:
            if fault in {"network", "auth", "cancel", "cleanup"}:
                raise {
                    "network": ConnectionError,
                    "auth": PermissionError,
                    "cancel": asyncio.CancelledError,
                    "cleanup": CleanupError,
                }[fault]("injected")
            if fault == "race":
                source.path.mkdir()  # Even an empty competing target must never be replaced.
            if fault == "origin":
                await command(
                    "git",
                    "remote",
                    "set-url",
                    "origin",
                    "https://github.com/other/repo.git",
                    cwd=args[-1],
                )
            if fault == "symlink":
                source.path.symlink_to(other, target_is_directory=True)
        return result

    monkeypatch.setattr("gongcao.workspace.command", inject)
    with pytest.raises((OSError, ValueError, CleanupError, asyncio.CancelledError)):
        await prepare_repository(source)
    assert (other / "sentinel").read_text() == "untouched"
    if fault in {"cancel", "cleanup"}:
        assert len(list(source.path.parent.glob(".gongcao-clone-*"))) == 2
        with pytest.raises(CleanupError, match="Unconfirmed clone intent"):
            await prepare_repository(source)
    else:
        assert not list(source.path.parent.glob(".gongcao-clone-*"))
    if fault == "race":
        assert source.path.is_dir() and list(source.path.iterdir()) == []
    elif fault == "symlink":
        assert source.path.is_symlink()
    else:
        assert not source.path.exists()


async def test_existing_nonrepo_wrong_origin_and_nested_path_are_never_modified(tmp_path, repo):
    empty = tmp_path / "empty"
    empty.mkdir()
    for source in (
        Source("example/demo", empty),
        Source("wrong/repo", repo),
        Source("example/demo", repo / "nested"),
    ):
        source.path.mkdir(exist_ok=True)
        before = await command("git", "status", "--porcelain", cwd=str(repo))
        with pytest.raises((RuntimeError, ValueError)):
            await prepare_repository(source)
        assert await command("git", "status", "--porcelain", cwd=str(repo)) == before


@pytest.mark.parametrize("backlog", [False, True])
async def test_preparation_ignores_backlog_and_isolates_repository_failure(
    intake, store, tmp_path, clone_transport, backlog
):
    if backlog:
        await intake.scan()
        assert len(store.tasks()) == intake.config.discovery.max_new_per_scan
    slug = hashlib.sha256(str(tmp_path).encode()).hexdigest()[:12]
    good = Source("other/good-" + slug, tmp_path / "clones/other/good")
    bad = Source("other/bad-" + slug, tmp_path / "bad")
    bad.path.mkdir()
    config = replace(
        intake.config,
        discovery=replace(
            intake.config.discovery, sources=(bad, *intake.config.discovery.sources, good)
        ),
    )
    discovery = Discovery(store, config, intake.github)
    async with discovery.active(once=True):
        assert discovery.repositories[good.repo] == "已克隆"
        assert discovery.repositories[bad.repo].startswith("准备失败")
        assert len(store.tasks()) == 1  # Preparation never consumes additional claim capacity.


async def test_invalid_historical_path_does_not_abort_other_tasks_or_migrate(
    intake, store, tmp_path, monkeypatch, auth_file
):
    from test_runner import SUCCESS, install_worker

    install_worker(monkeypatch, SUCCESS)
    await intake.scan()
    old = store.tasks()[0]
    missing = tmp_path / "gone"
    with store.db:
        store.db.execute(
            "UPDATE tasks SET repo_path=?,state=? WHERE id=?",
            (str(missing), State.RECONCILE, old["id"]),
        )
    config = replace(
        intake.config,
        auth_file=auth_file,
    )
    other = intake.github.rows[5] | {"labels": ["agent-ready"]}
    store.register(
        other["url"],
        intake.config.discovery.sources[0].path,
        intake.github.sha,
        other,
        mode="step",
        policy=config.policy_hash,
    )
    await Scheduler(store, config, intake.github).execute(once=True, poll=1.0)
    scheduled = store.tasks()
    assert len(scheduled) == 2 and scheduled[0]["repo_path"] == str(missing)
    assert scheduled[0]["state"] in {State.RECONCILE, State.WAITING_ENVIRONMENT}
    assert scheduled[1]["state"] == State.WAITING_INSTRUCTION
    assert scheduled[1]["stage"] == "pending_development"
    assert not missing.exists()
    assert "No such file" in scheduled[0]["reason"]


async def test_concurrent_publish_never_replaces_competing_clone(tmp_path, clone_transport):
    source = Source("example/demo", tmp_path / "clones/demo")
    results = await asyncio.gather(
        prepare_repository(source), prepare_repository(source), return_exceptions=True
    )
    assert results.count("已克隆") == 1
    assert sum(isinstance(result, (FileExistsError, CleanupError)) for result in results) == 1
    assert (source.path / ".git").is_dir()
    assert not list(source.path.parent.glob(".gongcao-clone-*"))


async def test_parent_replaced_during_clone_does_not_redirect_cleanup(
    tmp_path, clone_transport, monkeypatch
):
    original, _ = clone_transport
    source = Source("example/demo", tmp_path / "clones/demo")
    foreign = tmp_path / "foreign"
    foreign.mkdir()
    (foreign / "sentinel").write_text("preserve")
    moved = tmp_path / "moved"

    async def replace_parent(*args, **kwargs):
        result = await original(*args, **kwargs)
        if "clone" in args:
            source.path.parent.rename(moved)
            source.path.parent.symlink_to(foreign, target_is_directory=True)
        return result

    monkeypatch.setattr("gongcao.workspace.command", replace_parent)
    with pytest.raises(ValueError, match="symlinks"):
        await prepare_repository(source)
    assert (foreign / "sentinel").read_text() == "preserve"
    assert list(moved.iterdir()) == []


async def test_preparation_failure_backs_off_and_recovers(intake, store, monkeypatch):
    from types import SimpleNamespace

    from gongcao import discovery

    original = discovery.prepare_repository
    calls, now = 0, 100.0

    async def failed(source):
        nonlocal calls
        calls += 1
        raise PermissionError("Authentication unavailable")

    monkeypatch.setattr(discovery, "time", SimpleNamespace(monotonic=lambda: now))
    monkeypatch.setattr(discovery, "prepare_repository", failed)
    await intake.scan()
    await intake.scan()
    assert calls == 1 and not store.tasks()
    now += 10
    await intake.scan()
    assert calls == 2
    monkeypatch.setattr(discovery, "prepare_repository", original)
    now += 20
    await intake.scan()
    assert len(store.tasks()) == 1
    assert intake.repositories[intake.config.discovery.sources[0].repo] == "已复用"


@pytest.mark.parametrize("arrival", ["after_clone", "after_validate"])
async def test_replaced_clone_is_never_published(
    tmp_path, repo, clone_transport, monkeypatch, arrival
):
    original, _ = clone_transport
    source = Source("example/demo", tmp_path / "clones/demo")
    replaced = False
    moved = tmp_path / "owned-moved"

    async def substitute(*args, **kwargs):
        nonlocal replaced
        result = await original(*args, **kwargs)
        clone = Path(args[-1]) if "clone" in args else Path(kwargs.get("cwd", "/"))
        boundary = (
            "clone" in args
            if arrival == "after_clone"
            else args == ("git", "rev-parse", "HEAD^{commit}")
        )
        if boundary and ".gongcao-clone-" in str(clone) and not replaced:
            replaced = True
            clone.rename(moved)
            await command("git", "clone", str(repo), str(clone))
            await command(
                "git",
                "remote",
                "set-url",
                "origin",
                "https://github.com/example/demo.git",
                cwd=str(clone),
            )
            (clone / "foreign-sentinel").write_text("not ours")
        return result

    monkeypatch.setattr("gongcao.workspace.command", substitute)
    with pytest.raises(CleanupError, match="ownership changed"):
        await prepare_repository(source)
    assert replaced and not source.path.exists()
    assert moved.is_dir()
    foreign = next(p for p in source.path.parent.glob(".gongcao-clone-*") if p.is_dir())
    assert (foreign / "foreign-sentinel").read_text() == "not ours"
    with pytest.raises(CleanupError, match="Unconfirmed clone intent"):
        await prepare_repository(source)


async def test_unknown_clone_blocks_retries_across_discovery_restart_but_not_other_repos(
    intake, store, tmp_path, clone_transport, monkeypatch
):
    transport, calls = clone_transport
    slug = hashlib.sha256(str(tmp_path).encode()).hexdigest()[:12]
    unknown = Source("other/unknown-" + slug, tmp_path / "clones/unknown")

    async def unconfirmed(*args, **kwargs):
        result = await transport(*args, **kwargs)
        if "clone" in args:
            raise CleanupError("descendant exit not confirmed")
        return result

    monkeypatch.setattr("gongcao.workspace.command", unconfirmed)
    config = replace(
        intake.config,
        discovery=replace(
            intake.config.discovery, sources=(unknown, *intake.config.discovery.sources)
        ),
    )
    for _ in range(2):
        discovery = Discovery(store, config, intake.github)
        async with discovery.active(once=True):
            await discovery.scan()
            assert discovery.repositories[unknown.repo].startswith("待核对")
        assert len(calls) == 1 and len(store.tasks()) == 1
        assert not unknown.path.exists()
