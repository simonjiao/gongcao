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


def _load_yaml(path: Path | None) -> dict[str, Any]:
    if path is None:
        return {}
    try:
        raw: Any = yaml.safe_load(path.read_text())
    except yaml.YAMLError as exc:
        raise ValueError(f"Invalid YAML configuration: {exc}") from exc
    if raw is None:
        return {}
    if not isinstance(raw, dict) or raw.keys() - {
        "model",
        "timeout_seconds",
        "max_log_bytes",
        "auth_file",
        "roles",
        "quality",
        "max_revisions",
        "scheduler",
        "qa",
        "copilot",
    }:
        raise ValueError("Invalid configuration keys")
    return raw


def _jobs(raw: dict[str, Any], section: str, default: int, maximum: int | None = None) -> int:
    settings = raw.get(section, {})
    if not isinstance(settings, dict) or settings.keys() - {"jobs"}:
        raise ValueError(f"{section} must be a mapping containing only jobs")
    value = settings.get("jobs", default)
    if type(value) is not int or value < 1 or (maximum is not None and value > maximum):
        bound = f"an integer between 1 and {maximum}" if maximum else "a positive integer"
        raise ValueError(f"{section}.jobs must be {bound}")
    return value


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
    scheduler_jobs: int = 1
    qa_jobs: int = 2
    copilot_operators: list[str] = field(default_factory=list)
    copilot_mode: str | None = None

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
        raw = _load_yaml(path)
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
        copilot = raw.get("copilot", {})
        if not isinstance(copilot, dict) or copilot.keys() - {"operators", "mode"}:
            raise ValueError("copilot must contain only operators and mode")
        operators = copilot.get("operators", [])
        if not isinstance(operators, list) or any(
            not isinstance(login, str) or not login.strip() for login in operators
        ):
            raise ValueError("copilot.operators must contain GitHub account names")
        mode = copilot.get("mode")
        if mode not in {None, "step", "auto"}:
            raise ValueError("copilot.mode must be step or auto")
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
            _jobs(raw, "scheduler", 1, 3),
            _jobs(raw, "qa", 2),
            operators,
            mode,
        )

    @classmethod
    def load_qa_jobs(cls, path: Path | None) -> int:
        """Read only QA parallelism; scene quality/role policies are generated separately."""
        return _jobs(_load_yaml(path), "qa", 2)
