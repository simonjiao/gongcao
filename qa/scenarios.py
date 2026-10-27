"""Small versioned fixture; Gongcao's public workflow owns every business stage."""

from pathlib import Path
from typing import Any

from .ledger import digest

VERSION = 6
SCENARIOS = ("smoke", "loop", "recover", "cancel", "copilot", "discovery")
VECTORS = (-500, -1, 0, 1, 99, 100, 101, 500)


def fixture(run_id: str, model: str | None) -> tuple[str, dict[str, Any]]:
    module = f"qa_fixture_{run_id[:12]}"
    requirement = (
        (Path(__file__).parent / "fixtures/requirement.md").read_text().format(module=module)
    )
    scope = f"Only work on {module}.py and tests/test_{module}.py. "
    roles = {
        "analyst": scope + "Read only. Inspect the request and plan the complete final contract. "
        "Execute /usr/bin/sleep 20 after your first inspection command, for the cancel probe. "
        "Return ready and the exact context target_sha. No long tests or credential access.",
        "developer": scope + requirement + " On initial development (confirmed_findings is null) "
        "implement the explicitly authorized missing-lower-bound defect. "
        "For technical check failures (findings with commands or ci), fix only the reported "
        "technical problem and preserve the current algorithm. Implement the complete contract "
        "after independent reviewer findings (conclusion=revise with basis) "
        "reject the lower bound. "
        "Keep imports at the top, Python style clean, and run the relevant stdlib unittest: "
        "uv run --offline --no-project --python /usr/bin/python3.12 python -B -m unittest "
        f"discover -s tests -p test_{module}.py -v. "
        "Do not run full project checks yourself. "
        "Return ready with the original context target_sha.",
        "reviewer": scope + "Read only. Independently inspect actual requirement, diff and tests. "
        "Check negative values return 0, zero/100 are preserved, >100 returns 100. "
        "Passing tests that omit negative inputs are insufficient. Return revise for the initial "
        "lower-bound defect, ready only after the full contract and tests are implemented. "
        "Return exact context target_sha. No credentials or remote writes.",
        "validator": "Read only. Independently inspect quality_evidence for passing project "
        "checks, required real checks, and CI with exact PR/base/head checkout proof. "
        "Draft/merge protection status is controlled separately after validation. "
        "Return ready only for actual passing evidence at exact context target_sha; "
        "revise for code defects or blocked for missing evidence. No credentials or writes.",
    }
    prefix = [
        "/usr/bin/env",
        "HOME=/tmp/gongcao-check-home",
        "UV_CACHE_DIR=/workspace/.venv/uv-cache",
        "UV_PROJECT_ENVIRONMENT=/tmp/gongcao-project-venv",
        "UV_LINK_MODE=copy",
        "uv",
        "run",
        "--locked",
        "--python",
        "{python}",
    ]
    config: dict[str, Any] = {
        "timeout_seconds": 900,
        "max_revisions": 3,
        "roles": roles,
        "quality": {
            "checks": [
                prefix + argv
                for argv in (
                    ["ruff", "check", "."],
                    ["ruff", "format", "--check", "."],
                    ["mypy"],
                    ["python", "-c", pytest_snapshot_script()],
                )
            ],
            "ci_workflows": ["ci.yml"],
            "require_real_checks": True,
            "real_checks": [
                [
                    "uv",
                    "run",
                    "--offline",
                    "--no-project",
                    "--python",
                    "{python}",
                    "python",
                    "-B",
                    "-c",
                    vector_script(module),
                ]
            ],
        },
    }
    if model:
        config["model"] = model
    return requirement, config


def pytest_snapshot_script() -> str:
    # Quality deliberately masks .git. Clone-dependent project tests get fresh,
    # credential-free metadata around an identical source copy, inside the same sandbox.
    return """
import os, subprocess, sys, tempfile
from pathlib import Path
from shutil import copytree, ignore_patterns
with tempfile.TemporaryDirectory(prefix='gongcao-pytest-') as temporary:
    source = Path(temporary) / 'source'
    copytree(Path.cwd(), source, symlinks=True, ignore=ignore_patterns(
        '.git', '.venv', '.qa-runs', '__pycache__', '.pytest_cache', '.mypy_cache', '.ruff_cache'))
    commands = [
        ['git', 'init', '-q'], ['git', 'add', '--all'],
        ['git', '-c', 'user.name=QA', '-c', 'user.email=qa@localhost',
         '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgSign=false',
         'commit', '-qm', 'QA source snapshot'],
    ]
    for command in commands:
        subprocess.run(command, cwd=source, check=True)
    tree = subprocess.check_output(
        ['git', 'rev-parse', 'HEAD^{tree}'], cwd=source, text=True).strip()
    print('QA_SOURCE_TREE=' + tree, flush=True)
    env = os.environ | {'PYTHONPATH': os.pathsep.join((str(source/'src'), str(source)))}
    print('Testing a full source copy of target {sha}', flush=True)
    subprocess.run([sys.executable, '-m', 'pytest', '-q'], cwd=source, env=env, check=True)
""".strip()


def vector_script(module: str) -> str:
    return (
        f"import runpy; clamp=runpy.run_path('{module}.py')['clamp_score']; "
        f"values={VECTORS!r}; assert all(clamp(x)==max(0,min(100,x)) for x in values)"
    )


def version_digest() -> str:
    paths = [Path(__file__), Path(__file__).parent / "fixtures/requirement.md"]
    return digest({path.name: path.read_text() for path in paths})
