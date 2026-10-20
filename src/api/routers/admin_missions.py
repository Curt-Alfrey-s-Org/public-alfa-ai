"""Admin Missions API: read-only agent fleet oversight (admin JWT)."""

from __future__ import annotations

import asyncio
import json
import logging
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import StreamingResponse

from src.api.auth_deps import require_admin_jwt_sse
from src.api.deps import require_role
from src.api.models.user import UserRecord
from src.ops.mission_fleet import (
    _run_skill,
    build_all_workers_status,
    build_artifacts_summary,
    build_findings_inbox,
    build_fleet_response,
    build_worker_status,
    compute_usefulness,
    count_finding_blocks,
)
from src.ops.mission_heartbeat import audit_log_dir
from src.ops.mission_wedge import detect_mission_wedge
from src.runtime.mission_events import mission_event_bus
from src.runtime.store import artifact_to_dict, run_to_dict, task_to_dict

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/missions", tags=["admin-missions"])


def _get_orchestrator():
    from src.api.app import orchestrator

    return orchestrator


def _runs_newest_first(limit: int) -> list[dict[str, Any]]:
    orch = _get_orchestrator()
    runs = [run_to_dict(r) for r in orch.store.list_runs()]
    runs.sort(key=lambda r: str(r.get("created_at") or ""), reverse=True)
    return runs[: max(1, min(limit, 200))]


def _tool_event_count(run_id: str) -> int:
    events, _ = mission_event_bus.get_since(run_id, 0)
    tool_types = {"tool_start", "tool_end", "tool_result", "tool_call", "tool_error"}
    return sum(1 for ev in events if str(ev.get("type") or "") in tool_types)


@router.get("/fleet")
def missions_fleet(
    _user: UserRecord = Depends(require_role("admin")),
) -> dict[str, Any]:
    orch = _get_orchestrator()
    runs = [run_to_dict(r) for r in orch.store.list_runs()]
    return build_fleet_response(runs, audit_log_dir())


@router.get("/runs")
def missions_list_runs(
    limit: int = Query(50, ge=1, le=200),
    _user: UserRecord = Depends(require_role("admin")),
) -> dict[str, Any]:
    return {"ok": True, "runs": _runs_newest_first(limit)}


@router.get("/runs/{run_id}")
def missions_run_detail(
    run_id: str,
    _user: UserRecord = Depends(require_role("admin")),
) -> dict[str, Any]:
    orch = _get_orchestrator()
    run = orch.store.get_run(run_id)
    if run is None:
        raise HTTPException(status_code=404, detail="Run not found")
    tasks = orch.store.list_tasks_for_run(run_id)
    artifacts = orch.store.list_artifacts_for_run(run_id)
    run_dict = run_to_dict(run)
    task_dicts = [task_to_dict(t) for t in tasks]
    artifact_dicts = [artifact_to_dict(a) for a in artifacts]
    tool_count = _tool_event_count(run_id)
    finding_count = 0
    log_root = audit_log_dir()
    if log_root.is_dir():
        for path in sorted(log_root.glob("findings-*.md"), reverse=True)[:3]:
            try:
                finding_count += count_finding_blocks(
                    path.read_text(encoding="utf-8", errors="replace")
                )
            except OSError:
                continue
    usefulness = compute_usefulness(
        run_status=str(run_dict.get("status") or ""),
        artifact_count=len(artifact_dicts),
        tool_event_count=tool_count,
        finding_count=finding_count,
    )
    return {
        "ok": True,
        "run": run_dict,
        "tasks": task_dicts,
        "artifacts": artifact_dicts,
        "usefulness": usefulness,
        "skill": _run_skill(run_dict, task_dicts),
    }


@router.get("/runs/{run_id}/events")
async def missions_run_events_sse(
    run_id: str,
    _: None = Depends(require_admin_jwt_sse),
) -> StreamingResponse:
    orch = _get_orchestrator()
    if orch.store.get_run(run_id) is None:
        raise HTTPException(status_code=404, detail="Run not found")

    async def generate() -> Any:
        offset = 0
        idle_ticks = 0
        max_idle = 240
        while idle_ticks < max_idle:
            new_events, offset = mission_event_bus.get_since(run_id, offset)
            if new_events:
                idle_ticks = 0
                for event in new_events:
                    yield f"data: {json.dumps(event, ensure_ascii=True)}\n\n"
                    if event.get("type") == "task_done":
                        run = orch.store.get_run(run_id)
                        if run and run.status in {"done", "failed"}:
                            payload = {
                                "type": "run_complete",
                                "run_id": run_id,
                                "status": run.status,
                            }
                            yield f"data: {json.dumps(payload, ensure_ascii=True)}\n\n"
                            return
            else:
                idle_ticks += 1
            await asyncio.sleep(0.5)

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@router.get("/artifacts/summary")
def missions_artifacts_summary(
    _user: UserRecord = Depends(require_role("admin")),
) -> dict[str, Any]:
    return build_artifacts_summary(audit_log_dir())


@router.get("/findings")
def missions_findings_inbox(
    _user: UserRecord = Depends(require_role("admin")),
) -> dict[str, Any]:
    """Severity-sorted findings with propose-only would_take_action (L1)."""
    return build_findings_inbox(audit_log_dir())


@router.get("/wedge")
def missions_wedge_status(
    _user: UserRecord = Depends(require_role("admin")),
) -> dict[str, Any]:
    """Detect stuck missions and missing expected audit feedback."""
    orch = _get_orchestrator()
    runs = [run_to_dict(r) for r in orch.store.list_runs()]
    tasks_by_run: dict[str, list[dict[str, Any]]] = {}
    for run in runs:
        rid = str(run.get("run_id") or "")
        if not rid:
            continue
        tasks_by_run[rid] = [
            task_to_dict(t) for t in orch.store.list_tasks_for_run(rid)
        ]
    return detect_mission_wedge(
        runs, tasks_by_run=tasks_by_run, log_dir=audit_log_dir()
    )


@router.post("/clear-stuck")
def missions_clear_stuck(
    dry_run: bool = Query(False),
    min_age_sec: int | None = Query(None, ge=300, le=86400),
    _user: UserRecord = Depends(require_role("admin")),
) -> dict[str, Any]:
    """Mark wedged pending/running runs failed (L2 admin; does not touch inference)."""
    from src.ops.mission_wedge import clear_stuck_missions

    return clear_stuck_missions(min_age_sec=min_age_sec, dry_run=dry_run)


@router.get("/worker")
def missions_worker_status(
    _user: UserRecord = Depends(require_role("admin")),
) -> dict[str, Any]:
    orch = _get_orchestrator()
    runs = [run_to_dict(r) for r in orch.store.list_runs()]
    tasks_by_run: dict[str, list[dict[str, Any]]] = {}
    for run in runs:
        run_id = str(run.get("run_id") or "")
        if not run_id:
            continue
        tasks_by_run[run_id] = [
            task_to_dict(t) for t in orch.store.list_tasks_for_run(run_id)
        ]
    base = build_worker_status(runs, tasks_by_run)
    hosts = build_all_workers_status()
    base["hosts"] = hosts.get("workers", [])
    base["unknown_host_count"] = hosts.get("unknown_count", 0)
    return base
