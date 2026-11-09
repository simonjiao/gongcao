"""Version-bound validation plans derived from repository entries and actual changes."""

import hashlib
import json
from pathlib import Path, PurePosixPath
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field


class Check(BaseModel):
    model_config = ConfigDict(extra="forbid", json_schema_serialization_defaults_required=True)

    category: Literal["build", "internal", "e2e"]
    entry: list[str]
    scope: list[str] = Field(min_length=1)
    required: bool
    reason: str = Field(min_length=1)
    environment: Literal["sandbox", "controlled"] = "sandbox"
    network: bool = False
    variables: list[str] = Field(default_factory=list)


def digest(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def binding(task: dict[str, Any]) -> dict[str, Any]:
    from .model import VERSION_FIELDS

    return {
        "repository": task["snapshot"]["repository"],
        "issue_url": task["url"],
        "pr_number": task["pr_number"],
        "base_sha": task["snapshot"].get("base_sha", task["target_sha"]),
        "target_sha": task["target_sha"],
        "request_hash": digest(
            [
                {key: task["snapshot"].get(key) for key in VERSION_FIELDS},
                task.get("control", {}).get("feedback", []),
            ]
        ),
    }


def propose(context: dict[str, Any]) -> list[dict[str, Any]]:
    """Conservative controller defaults; a task-specific confirmed plan can refine them."""
    files, builds = context["repository_files"], context["build_files"]
    changed = context.get("diff", {}).get("changed_files", [])
    documentation_only = bool(changed) and all(
        PurePosixPath(path).suffix.lower() in {".md", ".rst"} for path in changed
    )
    items: list[dict[str, Any]] = []

    def add(category: str, entry: list[str], scope: str, environment: str = "sandbox") -> None:
        items.append(
            Check.model_validate(
                {
                    "category": category,
                    "entry": entry,
                    "scope": [scope],
                    "required": True,
                    "reason": f"Repository entry for changed scope {scope}",
                    "environment": environment,
                }
            ).model_dump()
        )

    for path, body in builds.items():
        directory = str(PurePosixPath(path).parent)
        # A PR touching only another component does not run this component's build.
        if documentation_only or (
            changed
            and directory != "."
            and not any(PurePosixPath(name).is_relative_to(directory) for name in changed)
        ):
            continue
        if path.endswith("pom.xml"):
            add("build", ["mvn", "-B", "-f", path, "-DskipTests", "package"], directory)
            add("internal", ["mvn", "-B", "-f", path, "test"], directory)
        elif path.endswith("package.json"):
            scripts = json.loads(body).get("scripts", {})
            for script, category in (("build", "build"), ("test", "internal"), ("test:e2e", "e2e")):
                if script in scripts:
                    add(
                        category,
                        ["npm", "--prefix", directory, "run", script],
                        directory,
                        "controlled" if category == "e2e" else "sandbox",
                    )
        elif path == "pyproject.toml":
            if "ruff" in body:
                add("build", ["uv", "run", "--locked", "ruff", "check", "."], ".")
                add("build", ["uv", "run", "--locked", "ruff", "format", "--check", "."], ".")
            if "mypy" in body:
                add("build", ["uv", "run", "--locked", "mypy"], ".")
            if "pytest" in body:
                if "qa/scenarios.py" in files:
                    from qa.scenarios import pytest_snapshot_script

                add(
                    "internal",
                    [
                        "uv",
                        "run",
                        "--locked",
                        "python",
                        "-c",
                        pytest_snapshot_script(),
                    ]
                    if "qa/scenarios.py" in files
                    else ["uv", "run", "--locked", "pytest", "-q"],
                    "tests",
                )
        elif path == "Makefile":
            for target, category in (("check", "build"), ("test", "internal")):
                if f"{target}:" in body:
                    add(category, ["make", target], ".")
    for category in ("build", "internal", "e2e"):
        if not any(i["category"] == category for i in items):
            # Entry discovery alone cannot establish task-specific acceptance obligations.
            items.append(
                Check(
                    category=category,  # type: ignore[arg-type]
                    entry=[],
                    scope=["."],
                    required=True,
                    reason=(
                        f"Only documentation paths changed: {changed}; no applicable code entry. "
                        "Current Issue/AGENTS applicability assessment required"
                        if documentation_only
                        else "No confirmed repository entry; task-specific acceptance assessment "
                        "required"
                    ),
                    environment="controlled" if category == "e2e" else "sandbox",
                ).model_dump()
            )
    return items


def controlled_entry(workspace: Path, argv: list[str]) -> None:
    if len(argv) == 5 and argv[0:2] == ["npm", "--prefix"] and argv[3:] == ["run", "test:e2e"]:
        package = (workspace / argv[2] / "package.json").resolve()
        if package.is_relative_to(workspace) and package.is_file():
            if "test:e2e" in json.loads(package.read_text()).get("scripts", {}):
                return
    script = (
        argv[1]
        if len(argv) > 1 and argv[0] in {"{python}", "python", "python3", "bash", "sh"}
        else argv[0]
        if argv
        else ""
    )
    path = (workspace / script).resolve()
    if script.startswith("qa/") and path.is_file() and path.is_relative_to(workspace / "qa"):
        return
    raise ValueError("Real checks must invoke an existing QA script or npm test:e2e entry")
