"""Score clamping fixture."""


def clamp_score(value: int) -> int:
    """Clamp an integer to the inclusive interval [0, 100]."""
    return max(0, min(value, 100))
