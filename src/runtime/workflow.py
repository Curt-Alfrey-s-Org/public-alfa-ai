"""WorkflowRunner helpers: implement → review → check-work (max 3 fix rounds).

Opt-in via skill=implement or workflow=implement_review_fix (KD-16).
Mutate remains gated by ALFA_AI_AGENT_MUTATE_ENABLED (KD-18).
"""

from __future__ import annotations

import uuid
from typing import Any

from src.runtime.models import TaskRecord

WORKFLOW_IMPLEMENT_REVIEW_FIX = "implement_review_fix"
MAX_FIX_ROUNDS = 3


def wants_implement_review_fix(
    *,
    skill: str = "",
    workflow: str = "",
) -> bool:
    skill_l = (skill or "").strip().lower()
    workflow_l = (workflow or "").strip().lower()
    if workflow_l == WORKFLOW_IMPLEMENT_REVIEW_FIX:
        return True
    if skill_l == "implement":
        return True
    return False


def plan_implement_review_fix(
    run_id: str,
    goal: str,
    *,
    round_index: int = 1,
    target_host: str = "111",
) -> tuple[list[TaskRecord], list[tuple[str, str]]]:
    """Create coder → reviewer → check-work chain for one round."""
    if round_index < 1:
        round_index = 1
    if round_index > MAX_FIX_ROUNDS:
        return [], []

    coder_id = str(uuid.uuid4())
    review_id = str(uuid.uuid4())
    check_id = str(uuid.uuid4())

    coder = TaskRecord(
        task_id=coder_id,
        run_id=run_id,
        role="coder",
        title=f"implement (round {round_index}): {goal}",
        status="ready",
        metadata={
            "workflow": WORKFLOW_IMPLEMENT_REVIEW_FIX,
            "skill": "implement",
            "round": round_index,
            "step": "implement",
            "target_host": target_host,
        },
    )
    reviewer = TaskRecord(
        task_id=review_id,
        run_id=run_id,
        role="researcher",
        title=f"review (round {round_index}): {goal}",
        status="pending",
        metadata={
            "workflow": WORKFLOW_IMPLEMENT_REVIEW_FIX,
            "skill": "review",
            "round": round_index,
            "step": "review",
            "target_host": target_host,
        },
    )
    checker = TaskRecord(
        task_id=check_id,
        run_id=run_id,
        role="debugger",
        title=f"check-work (round {round_index}): {goal}",
        status="pending",
        metadata={
            "workflow": WORKFLOW_IMPLEMENT_REVIEW_FIX,
            "skill": "check-work",
            "round": round_index,
            "step": "check_work",
            "target_host": target_host,
        },
    )
    tasks = [coder, reviewer, checker]
    deps = [
        (review_id, coder_id),
        (check_id, review_id),
    ]
    return tasks, deps


def current_round_from_tasks(tasks: list[TaskRecord]) -> int:
    """Highest workflow round present on tasks (default 0 if none)."""
    best = 0
    for task in tasks:
        meta = task.metadata or {}
        if meta.get("workflow") != WORKFLOW_IMPLEMENT_REVIEW_FIX:
            continue
        try:
            r = int(meta.get("round") or 0)
        except (TypeError, ValueError):
            r = 0
        if r > best:
            best = r
    return best


def should_enqueue_fix_round(
    completed_task: TaskRecord,
    *,
    task_status: str,
    verdict: str | None,
    all_tasks: list[TaskRecord],
) -> bool:
    """True when check-work finished with FAIL and rounds remain."""
    meta = completed_task.metadata or {}
    if meta.get("workflow") != WORKFLOW_IMPLEMENT_REVIEW_FIX:
        return False
    if meta.get("step") != "check_work":
        return False
    if task_status != "done":
        # check-work may mark task done with FAIL verdict in summary, or failed
        pass
    if verdict != "FAIL":
        return False
    try:
        round_index = int(meta.get("round") or 1)
    except (TypeError, ValueError):
        round_index = 1
    return round_index < MAX_FIX_ROUNDS


def next_fix_round_plan(
    run_id: str,
    goal: str,
    all_tasks: list[TaskRecord],
) -> tuple[list[TaskRecord], list[tuple[str, str]]]:
    nxt = current_round_from_tasks(all_tasks) + 1
    if nxt > MAX_FIX_ROUNDS:
        return [], []
    host = "111"
    for task in all_tasks:
        meta = task.metadata or {}
        if meta.get("target_host"):
            host = str(meta["target_host"])
            break
    return plan_implement_review_fix(run_id, goal, round_index=nxt, target_host=host)


def workflow_constraints_from_task(task: TaskRecord) -> dict[str, Any]:
    meta = task.metadata or {}
    out: dict[str, Any] = {}
    if meta.get("skill"):
        out["skill"] = str(meta["skill"])
    if meta.get("workflow"):
        out["workflow"] = str(meta["workflow"])
    if meta.get("round") is not None:
        out["workflow_round"] = meta["round"]
    if meta.get("step"):
        out["workflow_step"] = str(meta["step"])
    if meta.get("target_host"):
        out["target_host"] = str(meta["target_host"])
    return out
