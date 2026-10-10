from __future__ import annotations

import uuid

from src.runtime.models import TaskRecord
from src.runtime.workflow import plan_implement_review_fix, wants_implement_review_fix


def plan_research_run(
    run_id: str,
    goal: str,
    *,
    target_host: str = "111",
) -> tuple[list[TaskRecord], list[tuple[str, str]]]:
    task_id = str(uuid.uuid4())
    task = TaskRecord(
        task_id=task_id,
        run_id=run_id,
        role="researcher",
        title=f"research step for goal: {goal}",
        status="ready",
        metadata={"target_host": target_host},
    )
    return [task], []


def plan_single_role_run(
    run_id: str,
    goal: str,
    role: str,
    *,
    skill: str = "",
    target_host: str = "111",
) -> tuple[list[TaskRecord], list[tuple[str, str]]]:
    task_id = str(uuid.uuid4())
    metadata: dict = {"target_host": target_host}
    if skill.strip():
        metadata["skill"] = skill.strip()
    task = TaskRecord(
        task_id=task_id,
        run_id=run_id,
        role=role,
        title=f"{role} step for goal: {goal}",
        status="ready",
        metadata=metadata,
    )
    return [task], []


def plan_initial_tasks(
    run_id: str,
    goal: str,
    *,
    research_only: bool = False,
    role: str | None = None,
    skill: str = "",
    workflow: str = "",
    target_host: str = "111",
) -> tuple[list[TaskRecord], list[tuple[str, str]]]:
    if wants_implement_review_fix(skill=skill, workflow=workflow):
        return plan_implement_review_fix(run_id=run_id, goal=goal, round_index=1, target_host=target_host)

    if role:
        return plan_single_role_run(
            run_id=run_id, goal=goal, role=role, skill=skill, target_host=target_host
        )
    if research_only:
        return plan_research_run(run_id=run_id, goal=goal, target_host=target_host)

    # Single-skill mission without implement workflow → one researcher task with that skill
    skill_l = (skill or "").strip().lower()
    if skill_l in (
        "error-cataloger",
        "corrective-analyst",
        "audit-repo",
        "host-facts",
        "review",
        "project-analyst",
        "sleep-curator",
        "export-train-pack",
    ):
        return plan_single_role_run(
            run_id=run_id,
            goal=goal,
            role="researcher",
            skill=skill_l,
            target_host=target_host,
        )

    roles = ["researcher", "coder", "debugger", "doc_maker"]
    tasks: list[TaskRecord] = []
    deps: list[tuple[str, str]] = []
    prev_task_id: str | None = None
    for role_name in roles:
        task_id = str(uuid.uuid4())
        task = TaskRecord(
            task_id=task_id,
            run_id=run_id,
            role=role_name,
            title=f"{role_name} step for goal: {goal}",
            status="ready" if prev_task_id is None else "pending",
            metadata={"target_host": target_host},
        )
        tasks.append(task)
        if prev_task_id is not None:
            deps.append((task_id, prev_task_id))
        prev_task_id = task_id
    return tasks, deps
