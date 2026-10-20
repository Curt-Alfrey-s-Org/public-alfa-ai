"""Format truncated host-action output for Grok Bot dual-check.

See docs/GROK_BOT_SCRIPT_LOOP.md and docs/ADMIN_AI_HOST_ACTIONS.md.
"""

from __future__ import annotations

_STDOUT_TAIL_LINES = 80
_STDERR_TAIL_LINES = 40


def _tail_lines(text: str, max_lines: int) -> str:
    if not text:
        return ""
    lines = text.splitlines()
    if len(lines) <= max_lines:
        return text.rstrip("\n")
    return "\n".join(lines[-max_lines:])


def format_bot_audit_excerpt(
    *,
    action_key: str,
    host: str,
    exit_code: int | None,
    stdout: str | None,
    stderr: str | None,
) -> str:
    """Return a paste-ready excerpt for ALFa Reviewer (ASCII only)."""
    exit_display = str(exit_code) if exit_code is not None else "?"
    stdout_tail = _tail_lines(stdout or "", _STDOUT_TAIL_LINES)
    stderr_tail = _tail_lines(stderr or "", _STDERR_TAIL_LINES)

    parts = [
        "Ask ALFa script-verify audit excerpt",
        f"action_key: {action_key}",
        f"host: {host}",
        f"Exit: {exit_display}",
        "",
        "Primary gate: non-zero Exit means FAIL. Do not request full log dumps.",
        "",
        "--- stdout (last 80 lines) ---",
        stdout_tail if stdout_tail else "(empty)",
    ]
    if stderr_tail:
        parts.extend(
            [
                "",
                "--- stderr (last 40 lines) ---",
                stderr_tail,
            ]
        )
    parts.extend(
        [
            "",
            "Reviewer: judge Exit and PASS/FAIL lines only. Do not dump files.",
        ]
    )
    return "\n".join(parts)
