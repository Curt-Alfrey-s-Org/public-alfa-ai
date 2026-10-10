"""Shared SSH/mission execution result type (avoids circular imports)."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(slots=True)
class ExecResult:
    ok: bool
    command_run: str
    stdout: str
    stderr: str
    exit_code: int
