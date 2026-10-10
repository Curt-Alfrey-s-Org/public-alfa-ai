from __future__ import annotations

import uuid
from typing import Any

from src.agent.roles import RoleRequest
from src.runtime.error_catalog import record_mission_failure
from src.runtime.models import ArtifactRecord, RunRecord
from src.runtime.planner import plan_initial_tasks
from src.runtime.queue import RuntimeQueue
from src.runtime.mission_events import mission_event_bus
from src.runtime.roles import execute_role
from src.runtime.run_input import materialize_run_input_files
from src.runtime.store import RuntimeStore, artifact_to_dict
from src.runtime.verify import parse_verdict
from src.runtime.worker_host import normalize_worker_host, task_target_host, worker_host_from_env
from src.runtime.workflow import (
    next_fix_round_plan,
    should_enqueue_fix_round,
    workflow_constraints_from_task,
)


class RuntimeOrchestrator:
    def __init__(self, store: RuntimeStore, queue: RuntimeQueue) -> None:
        self.store = store
        self.queue = queue

    def create_run(
        self,
        goal: str,
        *,
        research_only: bool = False,
        skill: str = "",
        workflow: str = "",
        role: str | None = None,
        input_files: list[dict[str, str]] | None = None,
        target_host: str | None = None,
    ) -> str:
        host = normalize_worker_host(target_host)
        run_id = str(uuid.uuid4())
        run = RunRecord(
            run_id=run_id,
            goal=goal,
            status="running",
            skill=skill.strip(),
            research_only=research_only,
            workflow=workflow.strip(),
            target_host=host,
        )
        self.store.create_run(run)

        if input_files:
            materialize_run_input_files(run_id, input_files)

        role_name = (role or "").strip() or None
        tasks, deps = plan_initial_tasks(
            run_id=run_id,
            goal=goal,
            research_only=research_only,
            role=role_name,
            skill=skill.strip(),
            workflow=workflow.strip(),
            target_host=host,
        )
        for task in tasks:
            self.store.create_task(task)
            if task.status == "ready":
                self.queue.push_task(task.task_id, target_host=task_target_host(task.metadata))
        for task_id, depends_on_task_id in deps:
            self.store.add_dependency(task_id, depends_on_task_id)
        return run_id

    def process_next_task(self, *, worker_host: str | None = None) -> dict[str, Any] | None:
        host = normalize_worker_host(worker_host or worker_host_from_env())
        task_id = self.queue.pop_task(worker_host=host)
        if task_id is None:
            return None
        task = self.store.get_task(task_id)
        if task is None:
            return None

        run = self.store.get_run(task.run_id)
        if run is None:
            return None

        # Do not resurrect runs already terminal (e.g. cleared as stuck / failed).
        if run.status in ("done", "failed"):
            self.store.update_task_status(task_id, "failed")
            mission_event_bus.publish(
                task.run_id,
                "task_done",
                {
                    "task_id": task_id,
                    "role": task.role,
                    "status": "failed",
                    "summary": f"skipped: run already {run.status}",
                    "tool_count": 0,
                    "verdict": None,
                },
            )
            return {
                "task_id": task_id,
                "status": "failed",
                "summary": f"skipped: run already {run.status}",
                "verdict": None,
                "tool_events": [],
            }

        self.store.update_task_status(task_id, "running")
        mission_event_bus.publish(
            task.run_id,
            "task_start",
            {"task_id": task_id, "role": task.role, "title": task.title},
        )
        artifacts_for_run = self.store.list_artifacts_for_run(task.run_id)
        task_constraints = workflow_constraints_from_task(task)
        skill = str(task_constraints.get("skill") or run.skill or "")
        request = RoleRequest(
            run_id=task.run_id,
            task_id=task.task_id,
            role=task.role,
            goal=run.goal,
            context={"artifacts": [artifact_to_dict(item) for item in artifacts_for_run]},
            constraints={
                "skill": skill,
                "research_only": run.research_only,
                "workflow": task_constraints.get("workflow") or run.workflow,
                **{k: v for k, v in task_constraints.items() if k != "skill"},
            },
        )
        result = execute_role(request)

        for artifact in result.artifacts:
            self.store.create_artifact(
                ArtifactRecord(
                    artifact_id=artifact.artifact_id,
                    run_id=task.run_id,
                    task_id=task.task_id,
                    artifact_type=artifact.artifact_type,
                    path=artifact.path,
                    sha256=artifact.sha256,
                    metadata=artifact.metadata,
                )
            )

        new_status = "done" if result.status == "success" else "failed"
        # check-work FAIL is still a successful role execution with a FAIL verdict
        verdict = parse_verdict(result.summary)
        if (
            (task.metadata or {}).get("step") == "check_work"
            and verdict == "FAIL"
            and result.status == "success"
        ):
            new_status = "done"

        self.store.update_task_status(task_id, new_status)
        mission_event_bus.publish(
            task.run_id,
            "task_done",
            {
                "task_id": task_id,
                "role": task.role,
                "status": new_status,
                "summary": result.summary,
                "tool_count": len(result.tool_events),
                "verdict": verdict,
            },
        )

        if new_status == "failed":
            try:
                record_mission_failure(
                    run_id=task.run_id,
                    task_id=task_id,
                    role=task.role,
                    summary=result.summary or f"{task.role} failed",
                )
            except OSError:
                pass

        # Workflow: on check-work FAIL, enqueue another implement→review→fix round
        if should_enqueue_fix_round(
            task,
            task_status=new_status,
            verdict=verdict,
            all_tasks=self.store.list_tasks_for_run(task.run_id),
        ):
            more_tasks, more_deps = next_fix_round_plan(
                task.run_id,
                run.goal,
                self.store.list_tasks_for_run(task.run_id),
            )
            for extra in more_tasks:
                self.store.create_task(extra)
                if extra.status == "ready":
                    self.queue.push_task(
                        extra.task_id,
                        target_host=task_target_host(extra.metadata) or host,
                    )
            for dep_task_id, depends_on in more_deps:
                self.store.add_dependency(dep_task_id, depends_on)

        for dependent_task_id in self.store.list_dependents(task_id):
            dependent_task = self.store.get_task(dependent_task_id)
            if dependent_task is None:
                continue
            if dependent_task.status != "pending":
                continue
            if self.store.dependencies_done(dependent_task_id):
                self.store.update_task_status(dependent_task_id, "ready")
                dep_task = self.store.get_task(dependent_task_id)
                dep_host = task_target_host(dep_task.metadata if dep_task else None)
                self.queue.push_task(dependent_task_id, target_host=dep_host)

        tasks = self.store.list_tasks_for_run(task.run_id)
        statuses = {item.status for item in tasks}
        if "failed" in statuses:
            self.store.update_run_status(task.run_id, "failed")
        elif statuses and statuses.issubset({"done"}):
            self.store.update_run_status(task.run_id, "done")
        else:
            self.store.update_run_status(task.run_id, "running")

        return {
            "task_id": task_id,
            "status": new_status,
            "summary": result.summary,
            "verdict": verdict,
            "tool_events": [
                {
                    "tool_name": event.tool_name,
                    "ok": event.ok,
                    "started_at": event.started_at,
                    "duration_ms": event.duration_ms,
                }
                for event in result.tool_events
            ],
        }

