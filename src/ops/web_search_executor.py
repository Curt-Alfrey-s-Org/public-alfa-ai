"""Execute web_search catalog action inside the brain API (no SSH).

Reuses src.agent.tools.web_search only. See docs/ADMIN_AI_HOST_ACTIONS.md.
"""

from __future__ import annotations

import json
from typing import Any

from src.agent.tools import web_search
from src.ops.exec_result import ExecResult

_WEB_SEARCH_ACTION = "web_search"


def is_internal_web_search_action(action_key: str) -> bool:
    return action_key == _WEB_SEARCH_ACTION


def is_web_search_inspect_action(action_key: str) -> bool:
    return action_key == _WEB_SEARCH_ACTION


def execute_internal_web_search(params: dict[str, Any] | None) -> ExecResult:
    """Run LAN SearXNG search; map tool dict to ExecResult (fail-closed when disabled)."""
    query = str((params or {}).get("query") or "").strip()
    command_run = f"web_search query={query!r}" if query else "web_search"
    result = web_search(query)
    if result.get("ok"):
        stdout = json.dumps(result, indent=2, ensure_ascii=True, default=str)
        return ExecResult(
            ok=True,
            command_run=command_run,
            stdout=stdout,
            stderr="",
            exit_code=0,
        )
    error = str(result.get("error") or "web_search failed")
    return ExecResult(
        ok=False,
        command_run=command_run,
        stdout="",
        stderr=error,
        exit_code=1,
    )
