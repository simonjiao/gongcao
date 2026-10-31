"""Score clamping for the QA fixture."""


def clamp_score(value: int) -> int:
    """Clamp a score to the inclusive interval [0, 100]."""
    return max(0, min(100, value))
