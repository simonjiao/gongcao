async def authorized_fixture() -> None:
    # Explicit execution is restricted to temporary, test-owned QA scripts.
    pass


def items(entry, environment="sandbox"):
    return [
        {
            "category": category,
            "entry": entry
            if category == ("e2e" if environment == "controlled" else "internal")
            else ["true"]
            if category != "e2e"
            else [],
            "scope": ["."],
            "required": category != "e2e" or environment == "controlled",
            "reason": "Execution probe; no real E2E claimed"
            if environment == "sandbox"
            else "Acceptance contract",
            "environment": environment if category == "e2e" else "sandbox",
        }
        for category in ("build", "internal", "e2e")
    ]
