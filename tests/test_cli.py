import argparse
import json

from gongcao.cli import execute, parser
from gongcao.github import GitHub


async def test_status_inspect_and_cancel_are_local(store, task_id, capsys):
    for name in ("status", "inspect", "cancel"):
        args = parser().parse_args([name, str(task_id)])
        assert await execute(args, store) == 0
        assert json.loads(capsys.readouterr().out)


async def test_sync_queries_only_explicitly_registered_targets(
    store, task_id, snapshot, monkeypatch
):
    urls = []

    async def read(self, target):
        urls.append(target.url)
        return snapshot

    monkeypatch.setattr(GitHub, "snapshot", read)
    await execute(argparse.Namespace(command="sync", task=None), store)
    assert urls == [snapshot["url"]]
