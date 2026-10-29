"""Validate actual SDK requests and acknowledged session parameters, without inference."""

import json
from types import SimpleNamespace

import pytest
from openai_codex.models import Notification, UnknownNotification

from gongcao import worker
from gongcao.config import Config


@pytest.fixture
def sdk(monkeypatch):
    calls = []
    result = {
        "conclusion": "ready",
        "summary": "test",
        "basis": ["test"],
        "target_sha": "a" * 40,
        "next_steps": ["review"],
        "validation_plan": [],
    }

    class Client:
        available = True
        efforts = ["low", "high", "xhigh"]
        actual_model = "gpt-6.1-sol"
        actual_effort = "xhigh"
        reroute = False

        def __init__(self, config):
            self.events = [
                Notification(
                    "item/completed",
                    UnknownNotification(
                        {"item": {"type": "agentMessage", "text": json.dumps(result)}}
                    ),
                ),
                Notification(
                    "turn/completed", UnknownNotification({"turn": {"status": "completed"}})
                ),
            ]
            if self.reroute:
                self.events.insert(0, Notification("model/rerouted", UnknownNotification({})))

        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            pass

        async def initialize(self):
            pass

        async def model_list(self, **kwargs):
            return SimpleNamespace(
                data=[
                    SimpleNamespace(
                        model=self.actual_model,
                        supported_reasoning_efforts=[
                            SimpleNamespace(reasoning_effort=e) for e in self.efforts
                        ],
                    )
                ]
                if self.available
                else []
            )

        async def thread_start(self, params):
            calls.append(("thread", params))
            return SimpleNamespace(
                thread=SimpleNamespace(id="session"),
                model=self.actual_model,
                reasoning_effort=self.actual_effort,
            )

        async def turn_start(self, thread_id, context, params):
            assert thread_id == "session"
            schema = params["outputSchema"]
            for obj in [schema, *schema.get("$defs", {}).values()]:
                if obj.get("type") == "object":
                    assert obj["additionalProperties"] is False
                    assert set(obj["required"]) == set(obj["properties"])
            calls.append(("turn", params))
            return SimpleNamespace(turn=SimpleNamespace(id="turn"))

        async def next_turn_notification(self, turn_id):
            return self.events.pop(0)

    monkeypatch.setattr(worker, "AsyncCodexClient", Client)
    return Client, calls


@pytest.mark.parametrize("model,effort", [("gpt-6.1-sol", "xhigh"), ("configured-model", "high")])
async def test_worker_explicit_sdk_parameters_and_confirmed_evidence(sdk, capsys, model, effort):
    client, calls = sdk
    client.actual_model, client.actual_effort = model, effort
    await worker.execute(
        {"writable": False, "context": {}, "model": model, "reasoning_effort": effort}
    )
    assert calls[0][1]["model"] == model
    assert calls[0][1]["config"]["model_reasoning_effort"] == effort
    assert calls[0][1]["approvalPolicy"] == "never"
    assert calls[0][1]["sandbox"] == "read-only"
    assert calls[1][1]["model"] == model and calls[1][1]["effort"] == effort
    events = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    actual = next(e["data"] for e in events if e["kind"] == "execution")
    assert actual["model"] == model and actual["reasoning_effort"] == effort
    assert events[-1]["kind"] == "result"


@pytest.mark.parametrize("bad", ["unavailable", "effort", "ack", "reroute"])
async def test_sdk_never_silently_falls_back(sdk, capsys, bad):
    client, calls = sdk
    if bad == "unavailable":
        client.available = False
    if bad == "effort":
        client.efforts = ["low"]
    if bad == "ack":
        client.actual_effort = "low"
    if bad == "reroute":
        client.reroute = True
    with pytest.raises((ValueError, RuntimeError)):
        await worker.execute(
            {"writable": False, "context": {}, "model": "gpt-6.1-sol", "reasoning_effort": "xhigh"}
        )
    assert '"kind": "result"' not in capsys.readouterr().out
    assert len(calls) == (2 if bad == "reroute" else 1 if bad == "ack" else 0)


def test_config_defaults_overrides_sources_and_policy(tmp_path):
    default = Config.load(None)
    assert default.model == "gpt-6.1-sol" and default.reasoning_effort == "xhigh"
    assert set(default.execution["source"].values()) == {"project-default"}
    path = tmp_path / "config.yaml"
    path.write_text("model: gpt-6.1-sol\nreasoning_effort: xhigh\n")
    assert set(Config.load(path).execution["source"].values()) == {"configuration"}
    path.write_text("reasoning_effort: high\n")
    assert Config.load(path).policy_hash != default.policy_hash
    assert Config.load(path).execution["source"]["model"] == "project-default"


@pytest.mark.parametrize(
    "text",
    [
        "model: null",
        'model: ""',
        "reasoning_effort: turbo",
        "reasoning_effort: null",
        "reasoning_effort: []",
    ],
)
def test_invalid_model_configuration_fails_before_session(tmp_path, text):
    path = tmp_path / "config.yaml"
    path.write_text(text)
    with pytest.raises(ValueError):
        Config.load(path)
