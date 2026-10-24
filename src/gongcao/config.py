"""Small role configuration; security permissions are never supplied by YAML."""

import hashlib
import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

from .model import Role

PROMPTS = {
    Role.ANALYST: "Analyze the request and give a concrete implementation plan. Read only.",
    Role.DEVELOPER: "Implement the confirmed analysis or current-SHA revision findings "
    "in the assigned workspace. Run relevant tests.",
    Role.REVIEWER: "Independently review requirements, diff, design, security, tests and risks. "
    "Read only. Use conclusion revise for actionable defects, ready only when satisfied.",
    Role.VALIDATOR: "Inspect actual quality and CI evidence for the exact revision. Read only. "
    "Use revise for defects, blocked for missing evidence, ready only when satisfied.",
}


@dataclass(frozen=True)
class Config:
    model: str | None = None
    timeout_seconds: int = 900
    max_log_bytes: int = 2_000_000
    auth_file: Path = field(default_factory=lambda: Path.home() / ".codex" / "auth.json")
    prompts: dict[Role, str] = field(default_factory=lambda: dict(PROMPTS))
    checks: list[list[str]] = field(default_factory=list)
    real_checks: list[list[str]] = field(default_factory=list)
    ci_workflows: list[str] = field(default_factory=list)
    require_real_checks: bool = False
    max_revisions: int = 3

    @property
    def policy_hash(self) -> str:
        return hashlib.sha256(
            json.dumps(
                {
                    "checks": self.checks,
                    "real_checks": self.real_checks,
                    "ci_workflows": self.ci_workflows,
                    "require_real_checks": self.require_real_checks,
                    "roles": {role.value: prompt for role, prompt in self.prompts.items()},
                    "model": self.model,
                },
                sort_keys=True,
            ).encode()
        ).hexdigest()

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
            "quality",
            "max_revisions",
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
        quality = raw.get("quality", {})
        if not isinstance(quality, dict) or quality.keys() - {
            "checks",
            "real_checks",
            "ci_workflows",
            "require_real_checks",
        }:
            raise ValueError("Invalid quality policy")
        commands = []
        for key in ("checks", "real_checks"):
            value = quality.get(key, [])
            if not isinstance(value, list) or any(
                not isinstance(argv, list)
                or not argv
                or any(not isinstance(arg, str) or not arg for arg in argv)
                for argv in value
            ):
                raise ValueError(f"quality.{key} must contain command argument lists")
            commands.append(value)
        workflows = quality.get("ci_workflows", [])
        if not isinstance(workflows, list) or any(
            not isinstance(name, str) or not name or "/" in name for name in workflows
        ):
            raise ValueError("ci_workflows must contain workflow filenames")
        real = quality.get("require_real_checks", False)
        revisions = raw.get("max_revisions", 3)
        if type(real) is not bool or type(revisions) is not int or not 0 <= revisions <= 10:
            raise ValueError("Invalid real check requirement or revision limit")
        return cls(
            model,
            timeout,
            limit,
            Path(raw.get("auth_file", cls().auth_file)).expanduser(),
            prompts,
            commands[0],
            commands[1],
            workflows,
            real,
            revisions,
        )
