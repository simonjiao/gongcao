"""Small role configuration; security permissions are never supplied by YAML."""

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

from .model import Role

PROMPTS = {
    Role.ANALYST: "Analyze the request and give a concrete implementation plan. Read only.",
    Role.DEVELOPER: "Implement the confirmed plan in the assigned workspace. Run relevant tests.",
    Role.REVIEWER: "Review the target revision. Read only; report evidence and defects.",
    Role.VALIDATOR: "Inspect validation evidence for the exact revision. Read only.",
}


@dataclass(frozen=True)
class Config:
    model: str | None = None
    timeout_seconds: int = 900
    max_log_bytes: int = 2_000_000
    auth_file: Path = field(default_factory=lambda: Path.home() / ".codex" / "auth.json")
    prompts: dict[Role, str] = field(default_factory=lambda: dict(PROMPTS))

    @classmethod
    def load(cls, path: Path | None) -> "Config":
        if path is None:
            return cls()
        raw: Any = yaml.safe_load(path.read_text()) or {}
        if not isinstance(raw, dict) or raw.keys() - {
            "model",
            "timeout_seconds",
            "max_log_bytes",
            "auth_file",
            "roles",
        }:
            raise ValueError("Invalid configuration keys")
        prompts = dict(PROMPTS)
        roles = raw.get("roles", {})
        if not isinstance(roles, dict):
            raise ValueError("roles must be a mapping")
        for name, prompt in roles.items():
            if not isinstance(prompt, str) or not prompt.strip():
                raise ValueError("Each role must contain a nonempty prompt string")
            prompts[Role(name)] = prompt
        timeout = raw.get("timeout_seconds", 900)
        limit = raw.get("max_log_bytes", 2_000_000)
        if type(timeout) is not int or not 1 <= timeout <= 86400:
            raise ValueError("timeout_seconds must be an integer between 1 and 86400")
        if type(limit) is not int or not 4096 <= limit <= 20_000_000:
            raise ValueError("max_log_bytes must be between 4096 and 20000000")
        model = raw.get("model")
        if model is not None and (not isinstance(model, str) or not model.strip()):
            raise ValueError("model must be a nonempty string")
        return cls(
            model, timeout, limit, Path(raw.get("auth_file", cls().auth_file)).expanduser(), prompts
        )
