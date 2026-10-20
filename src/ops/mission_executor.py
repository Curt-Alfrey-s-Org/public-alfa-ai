"""Execute mission catalog actions inside the brain API (no SSH)."""

from __future__ import annotations

import logging
from typing import Any

from src.ops.exec_result import ExecResult

logger = logging.getLogger(__name__)

_MISSION_SKILLS = frozenset({"", "audit-repo", "host-facts", "error-cataloger"})
_INTERNAL_MISSION_ACTIONS = frozenset({"mission_enqueue", "mission_clear_stuck"})


def is_internal_mission_action(action_key: str) -> bool:
    return action_key in _INTERNAL_MISSION_ACTIONS


def execute_internal_mission_action(
    action_key: str, params: dict[str, Any] | None
) -> ExecResult:
    if action_key == "mission_enqueue":
        return execute_mission_enqueue(params or {})
    if action_key == "mission_clear_stuck":
        return execute_mission_clear_stuck(params or {})
    return ExecResult(
        ok=False,
        command_run=action_key,
        stdout="",
        stderr=f"not an internal mission action: {action_key}",
        exit_code=2,
    )


def execute_mission_clear_stuck(params: dict[str, Any]) -> ExecResult:
    dry_run = params.get("dry_run") in (True, "true", "1", 1)
    min_age = params.get("min_age_sec")
    min_age_sec: int | None = None
    if min_age is not None and str(min_age).strip() != "":
        try:
            min_age_sec = max(300, min(int(min_age), 86400))
        except (TypeError, ValueError):
            return ExecResult(
                ok=False,
                command_run="mission_clear_stuck",
                stdout="",
                stderr="min_age_sec must be an integer seconds value",
                exit_code=2,
            )
    try:
        from src.ops.mission_wedge import clear_stuck_missions

        result = clear_stuck_missions(min_age_sec=min_age_sec, dry_run=bool(dry_run))
        cleared = result.get("cleared_count", 0)
        lines = [
            f"mission_clear_stuck dry_run={dry_run} cleared_count={cleared}",
            result.get("note") or "",
        ]
        for row in (result.get("cleared") or [])[:12]:
            lines.append(
                f"  {str(row.get('run_id') or '')[:8]}... "
                f"age={row.get('age_sec')}s goal={(row.get('goal') or '')[:60]}"
            )
        msg = "\n".join(lines).strip()
        logger.info("mission_clear_stuck ok %s", msg.replace("\n", " | "))
        return ExecResult(
            ok=True,
            command_run="mission_clear_stuck",
            stdout=msg,
            stderr="",
            exit_code=0,
        )
    except Exception as exc:
        logger.exception("mission_clear_stuck failed")
        return ExecResult(
            ok=False,
            command_run="mission_clear_stuck",
            stdout="",
            stderr=str(exc),
            exit_code=1,
        )


def execute_mission_enqueue(params: dict[str, Any]) -> ExecResult:
    goal = str(params.get("goal") or "").strip()
    if not goal:
        return ExecResult(
            ok=False,
            command_run="mission_enqueue",
            stdout="",
            stderr="goal is required",
            exit_code=2,
        )
    if len(goal) > 500:
        return ExecResult(
            ok=False,
            command_run="mission_enqueue",
            stdout="",
            stderr="goal exceeds 500 characters",
            exit_code=2,
        )

    from src.ops.mission_fleet import validate_mission_target_host

    try:
        target_host = validate_mission_target_host(str(params.get("target_host") or "111"))
    except ValueError as exc:
        return ExecResult(
            ok=False,
            command_run="mission_enqueue",
            stdout="",
            stderr=str(exc),
            exit_code=2,
        )
    skill = str(params.get("skill") or "audit-repo").strip() or "audit-repo"
    if skill not in _MISSION_SKILLS:
        return ExecResult(
            ok=False,
            command_run="mission_enqueue",
            stdout="",
            stderr=f"unsupported skill: {skill}",
            exit_code=2,
        )

    research_only = params.get("research_only", True)
    if research_only not in (True, False, "true", "false", 1, 0):
        research_only = True
    if isinstance(research_only, str):
        research_only = research_only.lower() in ("1", "true", "yes")
    if not research_only:
        return ExecResult(
            ok=False,
            command_run="mission_enqueue",
            stdout="",
            stderr="mission_enqueue requires research_only=true (L1 read-only)",
            exit_code=2,
        )

    try:
        from src.runtime.factory import build_orchestrator

        orchestrator = build_orchestrator()
        run_id = orchestrator.create_run(
            goal,
            research_only=True,
            skill=skill,
            target_host=target_host,
        )
        msg = (
            f"Enqueued run_id={run_id} target_host={target_host} skill={skill} "
            f"research_only=true"
        )
        logger.info("mission_enqueue ok %s", msg)
        return ExecResult(
            ok=True,
            command_run="mission_enqueue",
            stdout=msg,
            stderr="",
            exit_code=0,
        )
    except Exception as exc:
        logger.exception("mission_enqueue failed")
        return ExecResult(
            ok=False,
            command_run="mission_enqueue",
            stdout="",
            stderr=str(exc),
            exit_code=1,
        )
