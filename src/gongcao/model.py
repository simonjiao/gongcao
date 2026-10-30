"""Business stages are separate from the state of an execution."""

from enum import StrEnum
from typing import Any

from pydantic import BaseModel, ConfigDict, Field

from .plan import Check

VERSION_FIELDS = (
    "title",
    "body",
    "base_sha",
    "base_ref",
    "base_repository",
    "head_repository",
    "head_ref",
    "pull_title",
    "pull_body",
)


def same_version(expected: dict[str, Any], current: dict[str, Any]) -> bool:
    return (
        expected["target_sha"] == current["target_sha"]
        and expected["stage"] == current["stage"]
        and all(
            expected["snapshot"].get(key) == current["snapshot"].get(key) for key in VERSION_FIELDS
        )
    )


class Stage(StrEnum):
    ANALYSIS = "pending_analysis"
    DEVELOPMENT = "pending_development"
    REVIEW = "pending_review"
    REVISION = "pending_revision"
    VALIDATION = "pending_validation"
    MERGEABLE = "mergeable"
    MERGED = "merged"


class State(StrEnum):
    QUEUED = "queued"
    RUNNING = "running"
    WAITING_DEPENDENCY = "waiting_dependency"
    WAITING_ENVIRONMENT = "waiting_environment"
    WAITING_INSTRUCTION = "waiting_instruction"
    RECONCILE = "needs_reconciliation"
    HUMAN = "needs_human"
    FAILED = "failed"
    COMPLETED = "completed"
    CANCELLED = "cancelled"


class Role(StrEnum):
    ANALYST = "analyst"
    DEVELOPER = "developer"
    REVIEWER = "reviewer"
    VALIDATOR = "validator"

    @property
    def writable(self) -> bool:
        return self == Role.DEVELOPER


class AgentResult(BaseModel):
    model_config = ConfigDict(extra="forbid", json_schema_serialization_defaults_required=True)

    conclusion: str = Field(pattern="^(ready|revise|blocked|failed)$")
    summary: str = Field(min_length=1, max_length=8000)
    basis: list[str] = Field(min_length=1, max_length=50)
    target_sha: str = Field(pattern="^[0-9a-f]{40,64}$")
    next_steps: list[str] = Field(min_length=1, max_length=50)
    validation_plan: list[Check] = Field(default_factory=list)
    delivery_complete: bool | None = Field(default=None, strict=True)


def development_complete(report: dict[str, Any]) -> bool:
    """Report eligibility only; controller provenance and safety gates still apply."""
    return (
        report.get("conclusion") == "ready" and report.get("delivery_complete") is not False
    ) or (report.get("conclusion") == "blocked" and report.get("delivery_complete") is True)


def after_run(stage: Stage, role: Role, result: AgentResult, sha: str) -> tuple[Stage, State, str]:
    """Only an analysis plan can advance without external controller evidence gates."""
    if result.target_sha != sha:
        return stage, State.RECONCILE, "Agent result refers to a different commit"
    developer = stage in {Stage.DEVELOPMENT, Stage.REVISION} and role == Role.DEVELOPER
    if (result.delivery_complete is not None and not developer) or (
        developer and not development_complete(result.model_dump())
    ):
        return stage, State.HUMAN, result.summary
    if result.conclusion == "revise" and role not in {Role.REVIEWER, Role.VALIDATOR}:
        return stage, State.HUMAN, "Only review/validation can request a revision"
    if result.conclusion not in {"ready", "revise"} and not developer:
        return stage, State.HUMAN, result.summary
    if stage == Stage.ANALYSIS and role == Role.ANALYST:
        return Stage.DEVELOPMENT, State.QUEUED, "Analysis artifact recorded; development is queued"
    if (
        (stage in {Stage.DEVELOPMENT, Stage.REVISION} and role == Role.DEVELOPER)
        or (stage == Stage.REVIEW and role == Role.REVIEWER)
        or (stage == Stage.VALIDATION and role == Role.VALIDATOR)
    ):
        return (
            stage,
            State.WAITING_DEPENDENCY,
            "Agent artifact retained; controller evidence gates are pending",
        )
    raise ValueError(f"Unsupported stage/role: {stage}/{role}")
