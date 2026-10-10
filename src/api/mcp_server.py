"""Streamable HTTP MCP server for inspectable host catalog actions (default off).

Official install: https://github.com/modelcontextprotocol/python-sdk
ASGI mount: https://py.sdk.modelcontextprotocol.io/run/asgi/
Transport security: https://py.sdk.modelcontextprotocol.io/run/deploy/
Tools hints: https://py.sdk.modelcontextprotocol.io/servers/tools/
MCP security: https://modelcontextprotocol.io/specification/2025-11-25/basic/security_best_practices

Do not register inspect or secrets on @mcp.custom_route (unauthenticated by SDK design).
"""

from __future__ import annotations

import json
import logging
from typing import Any

logger = logging.getLogger(__name__)


def build_mcp_inspect_server() -> tuple[Any, Any]:
    """Build MCPServer and its streamable HTTP Starlette sub-app.

    Lazy-imports the MCP SDK so brain startup works when mcp is not installed and
    ALFA_AI_MCP_ENABLED=0.
    """
    from mcp.server import MCPServer
    from mcp.server.transport_security import TransportSecuritySettings
    from mcp.types import ToolAnnotations

    from src.config import mcp_allowed_hosts
    from src.ops.mcp_inspect import authorize_mcp_inspect
    from src.ops.ssh_executor import execute_host_action

    mcp = MCPServer("alfa-ai-inspect")

    @mcp.tool(
        name="inspect_host",
        description=(
            "Run a read-only inspectable host catalog action (same allowlist as Ask ALFa L1 observe)."
        ),
        annotations=ToolAnnotations(readOnlyHint=True),
    )
    async def inspect_host(
        action_key: str,
        host: str,
        params: dict[str, Any] | None = None,
    ) -> str:
        auth = authorize_mcp_inspect(action_key, host, params)
        if not auth.get("ok"):
            return json.dumps(auth)
        result = await execute_host_action(
            auth["action_key"],
            auth["host_cfg"],
            auth["params"],
        )
        return json.dumps(
            {
                "ok": result.ok,
                "command_run": result.command_run,
                "stdout": result.stdout,
                "stderr": result.stderr,
                "exit_code": result.exit_code,
            }
        )

    transport_security = TransportSecuritySettings(allowed_hosts=mcp_allowed_hosts())
    starlette_app = mcp.streamable_http_app(
        streamable_http_path="/",
        transport_security=transport_security,
    )
    logger.info("MCP inspect server built (streamable HTTP at /mcp)")
    return mcp, starlette_app
