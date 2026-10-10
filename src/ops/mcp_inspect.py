"""Authorize MCP inspect tool calls against the host action catalog.

MCP tools annotations (e.g. read_only_hint) are hints only — enforce inspect-only here.
Official: https://py.sdk.modelcontextprotocol.io/servers/tools/
Security: https://modelcontextprotocol.io/specification/2025-11-25/basic/security_best_practices
"""

from __future__ import annotations

from typing import Any

from src.ops.host_catalog import is_inspectable, validate_proposal

# Defense in depth: never allow these via MCP even if catalog metadata changes.
MCP_FORBIDDEN_ACTION_KEYS: frozenset[str] = frozenset(
    {
        "run_command",
        "ha_switch_on",
        "ha_switch_off",
        "ha_dump_tick",
        "cluster_start",
        "cluster_stop",
        "apply_patch",
        "git_push",
    }
)


def authorize_mcp_inspect(
    action_key: str,
    host: str,
    params: dict[str, Any] | None = None,
    config: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Validate an MCP inspect_host call. Does not SSH or execute."""
    action_key = (action_key or "").strip()
    host = (host or "").strip()

    if action_key in MCP_FORBIDDEN_ACTION_KEYS:
        return {
            "ok": False,
            "error": f"Action {action_key} is not allowed via MCP inspect",
        }

    if not is_inspectable(action_key):
        return {
            "ok": False,
            "error": f"Action {action_key} is not inspectable via MCP",
        }

    try:
        spec, host_cfg, normalized_params = validate_proposal(
            action_key,
            host,
            params,
            config,
            enforce_enabled=True,
        )
    except ValueError as exc:
        return {"ok": False, "error": str(exc)}

    return {
        "ok": True,
        "action_key": action_key,
        "host": host,
        "spec_name": spec.key,
        "host_cfg": host_cfg,
        "params": normalized_params,
    }
