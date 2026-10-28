"""Exercise the SDK boundary with the service's strict object-schema contract."""

from types import SimpleNamespace

import pytest

from gongcao import worker


async def test_worker_sends_required_properties_for_nested_validation_plan(monkeypatch):
    class Accepted(Exception):
        pass

    async def turn(context, *, output_schema):
        for schema in [output_schema, *output_schema.get("$defs", {}).values()]:
            if schema.get("type") == "object":
                assert schema["additionalProperties"] is False
                assert set(schema["required"]) == set(schema["properties"])
        raise Accepted

    class Codex:
        def __init__(self, config):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            pass

        async def thread_start(self, **kwargs):
            return SimpleNamespace(id="schema-check", turn=turn)

    monkeypatch.setattr(worker, "AsyncCodex", Codex)
    with pytest.raises(Accepted):
        await worker.execute({"writable": False, "context": {}})
