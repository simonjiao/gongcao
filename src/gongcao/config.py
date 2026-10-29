"""Small role configuration; security permissions are never supplied by YAML."""

import hashlib
import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

from .github import Target
from .model import Role

PROMPTS = {
    Role.ANALYST: "Analyze the request and give a concrete implementation plan. "
    "Propose validation_plan items for build/internal/e2e using repository entries, "
    "scope, required, reason and sandbox/controlled environment. Read only.",
    Role.DEVELOPER: "Implement the confirmed analysis or current-SHA revision findings "
    "in the assigned workspace. Run relevant tests.",
    Role.REVIEWER: "Independently review requirements, diff, design, security, tests and risks. "
    "Read only. Use conclusion revise for actionable defects, ready only when satisfied.",
    Role.VALIDATOR: "Inspect actual quality plan and execution evidence for the exact revision. "
    "Read only. "
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
        "reasoning_effort",
        "timeout_seconds",
        "max_log_bytes",
        "auth_file",
        "roles",
        "max_revisions",
        "scheduler",
        "qa",
        "copilot",
        "discovery",
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
class Source:
    repo: str
    path: Path
    label: str = "agent-ready"
    mode: str = "step"


def repository_path(value: Any) -> Path:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise ValueError("Repository path must be an absolute path")
    path = Path(value).expanduser()
    if (
        not path.is_absolute()
        or "//" in value
        or any(part in {"", ".", ".."} for part in value.rstrip("/").split("/")[1:])
        or any(part.is_symlink() for part in (path, *path.parents))
    ):
        raise ValueError("Repository path must be absolute without traversal or symlinks")
    return path


@dataclass(frozen=True)
class DiscoveryConfig:
    enabled: bool = False
    interval_seconds: int = 60
    max_new_per_scan: int = 10
    sources: tuple[Source, ...] = ()
    repo_root: Path | None = None

    @classmethod
    def load(cls, raw: Any) -> "DiscoveryConfig":
        if not isinstance(raw, dict) or raw.keys() - {
            "enabled",
            "interval_seconds",
            "max_new_per_scan",
            "sources",
            "repo_root",
        }:
            raise ValueError("Invalid discovery configuration")
        enabled, interval, maximum = (
            raw.get("enabled", False),
            raw.get("interval_seconds", 60),
            raw.get("max_new_per_scan", 10),
        )
        if (
            type(enabled) is not bool
            or type(interval) is not int
            or interval < 1
            or type(maximum) is not int
            or not 1 <= maximum <= 100
        ):
            raise ValueError("Invalid discovery enabled, interval_seconds or max_new_per_scan")
        sources = raw.get("sources", [])
        if not isinstance(sources, list):
            raise ValueError("discovery.sources must be a list")
        parsed: list[Source] = []
        root = repository_path(raw["repo_root"]) if "repo_root" in raw else None
        for item in sources:
            if (
                not isinstance(item, dict)
                or item.keys() - {"repo", "path", "label", "mode"}
                or not isinstance(item.get("repo"), str)
                or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+", item["repo"])
                or item["repo"].split("/")[-1] in {".", ".."}
            ):
                raise ValueError("Each discovery source requires a valid owner/repo")
            target = Target.parse(f"https://github.com/{item['repo']}/issues/1")
            if "path" not in item and root is None:
                raise ValueError("Each discovery source requires path or discovery.repo_root")
            path, label, mode = (
                repository_path(item.get("path", str(root / target.repository) if root else "")),
                item.get("label", "agent-ready"),
                item.get("mode", "step"),
            )
            if (
                not path.is_absolute()
                or not isinstance(label, str)
                or not label.strip()
                or not isinstance(mode, str)
                or mode not in {"step", "auto"}
            ):
                raise ValueError("Invalid discovery source path, label or mode")
            if any(
                (
                    source.repo == target.repository
                    and (source.label == label or source.path != path)
                )
                or (source.repo != target.repository and source.path == path)
                for source in parsed
            ):
                raise ValueError("Duplicate discovery source or conflicting repository paths")
            parsed.append(Source(target.repository, path, label, mode))
        if enabled and not parsed:
            raise ValueError("Enabled discovery requires sources")
        return cls(enabled, interval, maximum, tuple(parsed), root)


@dataclass(frozen=True)
class Config:
    model: str = "gpt-6.1-sol"
    timeout_seconds: int = 900
    max_log_bytes: int = 2_000_000
    auth_file: Path = field(default_factory=lambda: Path.home() / ".codex" / "auth.json")
    prompts: dict[Role, str] = field(default_factory=lambda: dict(PROMPTS))
    max_revisions: int = 3
    scheduler_jobs: int = 1
    qa_jobs: int = 2
    copilot_operators: list[str] = field(default_factory=list)
    copilot_mode: str | None = None
    discovery: DiscoveryConfig = field(default_factory=DiscoveryConfig)
    reasoning_effort: str = "xhigh"
    configured: frozenset[str] = frozenset()

    def __post_init__(self) -> None:
        if (
            not isinstance(self.model, str)
            or not self.model.strip()
            or self.model != self.model.strip()
        ):
            raise ValueError("model must be a nonempty model identifier without surrounding spaces")
        if not isinstance(self.reasoning_effort, str) or self.reasoning_effort not in {
            "none",
            "minimal",
            "low",
            "medium",
            "high",
            "xhigh",
            "max",
            "ultra",
        }:
            raise ValueError("Invalid reasoning_effort; use a supported named reasoning level")

    @property
    def execution(self) -> dict[str, Any]:
        values = {"model": self.model, "reasoning_effort": self.reasoning_effort}
        defaults = {"model": "gpt-6.1-sol", "reasoning_effort": "xhigh"}
        return values | {
            "source": {
                key: "configuration"
                if key in self.configured or value != defaults[key]
                else "project-default"
                for key, value in values.items()
            }
        }

    @property
    def roles_hash(self) -> str:
        return hashlib.sha256(json.dumps(self.prompts, sort_keys=True).encode()).hexdigest()

    @property
    def policy_hash(self) -> str:
        return hashlib.sha256(
            json.dumps(
                {
                    "roles": {role.value: prompt for role, prompt in self.prompts.items()},
                    "model": self.model,
                    "reasoning_effort": self.reasoning_effort,
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
        model = raw.get("model", "gpt-6.1-sol")
        if not isinstance(model, str) or not model.strip():
            raise ValueError("model must be a nonempty string")
        if not isinstance(raw.get("reasoning_effort", "xhigh"), str):
            raise ValueError("reasoning_effort must be a named reasoning level")
        revisions = raw.get("max_revisions", 3)
        if type(revisions) is not int or not 0 <= revisions <= 10:
            raise ValueError("Invalid revision limit")
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
            revisions,
            _jobs(raw, "scheduler", 1, 3),
            _jobs(raw, "qa", 2),
            operators,
            mode,
            DiscoveryConfig.load(raw.get("discovery", {})),
            raw.get("reasoning_effort", "xhigh"),
            frozenset(raw.keys() & {"model", "reasoning_effort"}),
        )

    @classmethod
    def load_qa_jobs(cls, path: Path | None) -> int:
        """Read only QA parallelism; scene quality/role policies are generated separately."""
        return _jobs(_load_yaml(path), "qa", 2)
