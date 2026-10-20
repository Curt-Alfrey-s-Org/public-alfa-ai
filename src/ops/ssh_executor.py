"""Execute curated host actions via SSH. See docs/ADMIN_AI_HOST_ACTIONS.md."""

from __future__ import annotations

import asyncio
import logging
import os

from src.ops.exec_result import ExecResult
from src.ops.host_catalog import build_command, default_ssh_key_path, host_actions_enabled

logger = logging.getLogger(__name__)

# Re-export for callers that import ExecResult from this module.
__all__ = ["ExecResult", "execute_host_action"]


def _max_output_chars() -> int:
    try:
        return max(1000, int(os.getenv("ALFA_AI_MAX_COMMAND_OUTPUT_CHARS", "12000")))
    except ValueError:
        return 12000


def _truncate(text: str) -> str:
    limit = _max_output_chars()
    if len(text) <= limit:
        return text
    return text[: limit - 40] + "\n...(truncated)..."


def _known_hosts_path() -> str | None:
    """Path to SSH known_hosts for host actions (asyncssh docs: never use None in production)."""
    configured = (os.getenv("ALFA_AI_HOST_ACTIONS_KNOWN_HOSTS") or "").strip()
    if configured:
        return configured if os.path.isfile(configured) else None
    default = os.path.join(os.path.dirname(default_ssh_key_path()), "known_hosts")
    return default if os.path.isfile(default) else None


async def _ssh_exec(
    host_cfg: dict,
    command: str,
    *,
    timeout_sec: int,
    shell: str,
) -> ExecResult:
    try:
        import asyncssh
    except ImportError:
        return ExecResult(
            ok=False,
            command_run=command,
            stdout="",
            stderr="asyncssh is not installed in the API image",
            exit_code=127,
        )

    key_path = str(host_cfg.get("key_path") or default_ssh_key_path())
    if not os.path.isfile(key_path):
        return ExecResult(
            ok=False,
            command_run=command,
            stdout="",
            stderr=f"SSH key not found: {key_path}",
            exit_code=127,
        )

    lan_ip = str(host_cfg.get("lan_ip") or "")
    ssh_user = str(host_cfg.get("ssh_user") or "")
    if not lan_ip or not ssh_user:
        return ExecResult(
            ok=False,
            command_run=command,
            stdout="",
            stderr="Host missing lan_ip or ssh_user",
            exit_code=127,
        )

    remote_command = command
    if shell == "powershell":
        escaped = command.replace("'", "''")
        remote_command = f"powershell -NoProfile -Command '{escaped}'"

    known_hosts = _known_hosts_path()
    if known_hosts is None:
        return ExecResult(
            ok=False,
            command_run=command,
            stdout="",
            stderr=(
                "SSH known_hosts file missing. Set ALFA_AI_HOST_ACTIONS_KNOWN_HOSTS or "
                "create <key-dir>/known_hosts before approving host actions."
            ),
            exit_code=127,
        )

    try:
        async with asyncssh.connect(
            lan_ip,
            username=ssh_user,
            client_keys=[key_path],
            known_hosts=known_hosts,
        ) as conn:
            result = await asyncio.wait_for(
                conn.run(remote_command, check=False),
                timeout=timeout_sec,
            )
            stdout = _truncate(result.stdout or "")
            stderr = _truncate(result.stderr or "")
            code = int(result.exit_status or 0)
            return ExecResult(
                ok=code == 0,
                command_run=remote_command,
                stdout=stdout,
                stderr=stderr,
                exit_code=code,
            )
    except asyncio.TimeoutError:
        return ExecResult(
            ok=False,
            command_run=remote_command,
            stdout="",
            stderr="SSH command timed out",
            exit_code=124,
        )
    except Exception as exc:
        logger.exception("ssh_exec failed host=%s", host_cfg.get("key"))
        return ExecResult(
            ok=False,
            command_run=remote_command,
            stdout="",
            stderr=_truncate(str(exc)),
            exit_code=1,
        )


async def execute_host_action(
    action_key: str,
    host_cfg: dict,
    params: dict | None,
    config: dict | None = None,
) -> ExecResult:
    """Run a catalog action on the given host via SSH or internal httpx."""
    from src.ops.ha_executor import execute_internal_ha_action, is_internal_ha_action
    from src.ops.mission_executor import (
        execute_internal_mission_action,
        is_internal_mission_action,
    )

    if is_internal_ha_action(action_key):
        return await execute_internal_ha_action(action_key, params or {})

    from src.ops.web_search_executor import (
        execute_internal_web_search,
        is_internal_web_search_action,
    )

    if is_internal_web_search_action(action_key):
        return execute_internal_web_search(params or {})

    if not host_actions_enabled():
        return ExecResult(
            ok=False,
            command_run="",
            stdout="",
            stderr="Host actions disabled (ALFA_AI_HOST_ACTIONS_ENABLED=0)",
            exit_code=127,
        )

    if is_internal_mission_action(action_key):
        return execute_internal_mission_action(action_key, params or {})

    command, timeout_sec = build_command(action_key, host_cfg, params or {}, config)
    os_type = str(host_cfg.get("os_type") or "linux")
    shell = "powershell" if os_type == "windows" else "bash"
    return await _ssh_exec(host_cfg, command, timeout_sec=timeout_sec, shell=shell)
