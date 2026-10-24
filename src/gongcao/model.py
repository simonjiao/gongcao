"""Business stages are separate from the state of an execution."""

from enum import StrEnum

from pydantic import BaseModel, ConfigDict, Field


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
    model_config = ConfigDict(extra="forbid")

    conclusion: str = Field(pattern="^(ready|blocked|failed)$")
    summary: str = Field(min_length=1, max_length=8000)
    basis: list[str] = Field(min_length=1, max_length=50)
    target_sha: str = Field(pattern="^[0-9a-f]{40,64}$")
    next_steps: list[str] = Field(min_length=1, max_length=50)


def after_run(stage: Stage, role: Role, result: AgentResult, sha: str) -> tuple[Stage, State, str]:
    """PR1 can accept an analysis artifact; code waits for the PR2 GitHub gates."""
    if result.target_sha != sha:
        return stage, State.RECONCILE, "Agent result refers to a different commit"
    if result.conclusion != "ready":
        return stage, State.HUMAN, result.summary
    if stage == Stage.ANALYSIS and role == Role.ANALYST:
        return Stage.DEVELOPMENT, State.QUEUED, "Analysis artifact recorded; development is queued"
    if stage == Stage.DEVELOPMENT and role == Role.DEVELOPER:
        return (
            stage,
            State.WAITING_DEPENDENCY,
            "Local changes retained; PR/review gates require PR2",
        )
    raise ValueError(f"Unsupported stage/role in PR1: {stage}/{role}")
