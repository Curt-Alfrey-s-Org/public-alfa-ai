"""Run read-only inspect catalog actions synchronously from a worker thread (Ask ALFa inspect-then-act).

See docs/ADMIN_AI_HOST_ACTIONS.md. ``asyncio.run`` creates a fresh event loop and must not be
called while another loop is running in the same thread
(https://docs.python.org/3/library/asyncio-runner.html#asyncio.run), hence the guard below.
"""

from __future__ import annotations

import asyncio
from typing import Any

from src.ops.exec_result import ExecResult
from src.ops.host_catalog import is_inspectable
from src.ops.ssh_executor import execute_host_action


def run_inspect_action_sync(
    action_key: str,
    host_cfg: dict[str, Any],
    params: dict[str, Any] | None,
    config: dict[str, Any] | None = None,
) -> ExecResult:
    if not is_inspectable(action_key):
        raise ValueError(f"Action {action_key} is not inspectable")
    try:
        asyncio.get_running_loop()
    except RuntimeError:
        pass
    else:
        raise RuntimeError(
            "run_inspect_action_sync must not be called from a running event loop"
        )
    return asyncio.run(execute_host_action(action_key, host_cfg, params, config))


def inspection_step_dict(
    action_key: str,
    host: str,
    result: ExecResult,
    duration_ms: int,
) -> dict[str, Any]:
    return {
        "action_key": action_key,
        "host": host,
        "command_run": result.command_run,
        "stdout": result.stdout,
        "stderr": result.stderr,
        "exit_code": result.exit_code,
        "ok": result.ok,
        "duration_ms": duration_ms,
    }
