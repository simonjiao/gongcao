import fcntl
import json
import os
import subprocess
import sys
from pathlib import Path

GONGCAO = str(Path(sys.executable).with_name("gongcao"))


QA = (sys.executable, "-m", "qa")


def cli_env(checkout, gate):
    gate.mkdir(exist_ok=True)
    (gate / "calls.jsonl").touch()
    return {
        **os.environ,
        "PATH": str(checkout.parent / "bin") + os.pathsep + os.environ["PATH"],
        "PYTHONPATH": os.pathsep.join((str(checkout / "src"), str(checkout))),
        "JOBS_TEST_GATE": str(gate),
    }


def events(gate):
    with (gate / "calls.jsonl").open() as stream:
        fcntl.flock(stream, fcntl.LOCK_SH)
        return [json.loads(line) for line in stream]


def run_cli(checkout, env, *argv):
    result = subprocess.run(argv, cwd=checkout, env=env, capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stdout + result.stderr
    return json.loads(result.stdout)
