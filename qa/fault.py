"""Scoped test fault: real COMMENT confirmed, SIGKILL before its local acknowledgement."""

import os
import signal
from pathlib import Path
from typing import Any

from gongcao.cli import main as gongcao_main
from gongcao.store import Store

from .ledger import Run, write_json


def main() -> None:
    run = Run(Path(os.environ["GONGCAO_QA_DATA"]), os.environ["GONGCAO_QA_RUN"])
    if run.value["scenario"] != "recover" or (run.root / "fault.json").exists():
        raise ValueError("Fault injection requires an unused recovery Run")
    expected_state = run.root / "state"
    original = Store.operation_result

    def interrupt(self: Store, key: str, state: str, response: dict[str, Any] | None) -> None:
        op = self.operation(key)
        if (
            self.root == expected_state
            and op is not None
            and op["kind"] == "review"
            and state == "succeeded"
        ):
            task = self.task(op["task_id"])
            if task["url"] != run.value["resources"]["issue"]["url"]:
                raise ValueError("Fault task is outside this QA Run")
            write_json(
                run.root / "fault.json",
                {
                    "operation": key,
                    "observed_response": response,
                    "target_sha": task["target_sha"],
                    "pid": os.getpid(),
                    "point": "COMMENT observed before local operation_result",
                },
            )
            os.kill(os.getpid(), signal.SIGKILL)
        original(self, key, state, response)

    Store.operation_result = interrupt  # type: ignore[method-assign]
    gongcao_main()


if __name__ == "__main__":
    main()
