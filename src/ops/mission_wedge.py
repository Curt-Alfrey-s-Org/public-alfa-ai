"""Detect and clear wedged orchestrator missions (stuck running / missing feedback)."""

from __future__ import annotations

import os
from datetime import UTC, datetime
from typing import Any

from src.ops.mission_fleet import build_all_workers_status, build_findings_inbox
from src.runtime.store import run_to_dict, task_to_dict


def stuck_threshold_sec() -> int:
    raw = os.environ.get("ALFA_AI_MISSION_STUCK_SEC", "1800").strip()
    try:
        return max(300, min(int(raw), 86400))
    except ValueError:
        return 1800


def max_active_runs() -> int:
    raw = os.environ.get("ALFA_AI_AUDIT_MAX_ACTIVE", "2").strip()
    try:
        return max(1, min(int(raw), 20))
    except ValueError:
        return 2


def _parse_iso(ts: str | None) -> datetime | None:
    if not ts:
        return None
    text = str(ts).strip()
    if not text:
        return None
    try:
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        when = datetime.fromisoformat(text)
        if when.tzinfo is None:
            when = when.replace(tzinfo=UTC)
        return when
    except ValueError:
        return None


def _age_sec(iso: str | None, *, now: datetime | None = None) -> int | None:
    when = _parse_iso(iso)
    if when is None:
        return None
    ref = now or datetime.now(tz=UTC)
    return max(0, int((ref - when).total_seconds()))


def enrich_run_from_tasks(
    run: dict[str, Any], tasks: list[dict[str, Any]]
) -> dict[str, Any]:
    """Fill skill/target_host from task metadata when Postgres run row lacks them."""
    out = dict(run)
    skill_missing = not str(out.get("skill") or "").strip()
    for task in tasks:
        meta = task.get("metadata") if isinstance(task, dict) else None
        if not isinstance(meta, dict):
            continue
        if skill_missing and meta.get("skill"):
            out["skill"] = str(meta.get("skill") or "")
            skill_missing = False
        if meta.get("target_host"):
            out["target_host"] = str(meta.get("target_host") or "111")
            break
    return out


def _within_day(iso: str, now: datetime) -> bool:
    when = _parse_iso(iso)
    if when is None:
        return False
    return when.date() == now.astimezone(UTC).date()


def detect_mission_wedge(
    runs: list[dict[str, Any]],
    *,
    tasks_by_run: dict[str, list[dict[str, Any]]] | None = None,
    log_dir: Any = None,
    now: datetime | None = None,
) -> dict[str, Any]:
    """Flag stuck runs and missing expected audit feedback (L1 observe)."""
    ref = now or datetime.now(tz=UTC)
    threshold = stuck_threshold_sec()
    max_active = max_active_runs()
    tasks_by_run = tasks_by_run or {}

    enriched: list[dict[str, Any]] = []
    for run in runs:
        run_id = str(run.get("run_id") or "")
        enriched.append(enrich_run_from_tasks(run, tasks_by_run.get(run_id) or []))

    stuck: list[dict[str, Any]] = []
    active: list[dict[str, Any]] = []
    for run in enriched:
        status = str(run.get("status") or "")
        if status not in ("pending", "running"):
            continue
        age = _age_sec(str(run.get("updated_at") or ""), now=ref)
        if age is None:
            age = _age_sec(str(run.get("created_at") or ""), now=ref)
        row = {
            "run_id": run.get("run_id"),
            "goal": (str(run.get("goal") or ""))[:160],
            "status": status,
            "skill": run.get("skill") or "",
            "target_host": run.get("target_host") or "111",
            "age_sec": age,
            "updated_at": run.get("updated_at"),
            "created_at": run.get("created_at"),
        }
        active.append(row)
        if age is not None and age >= threshold:
            stuck.append(row)

    goal_counts: dict[str, int] = {}
    for row in active:
        key = (str(row.get("goal") or "").strip().lower())[:120]
        if key:
            goal_counts[key] = goal_counts.get(key, 0) + 1
    duplicate_goals = [
        {"goal": g[:120], "count": c} for g, c in goal_counts.items() if c >= 2
    ]

    inbox = build_findings_inbox(log_dir)
    structured = int(inbox.get("structured_count") or 0)
    inbox_count = int(inbox.get("count") or 0)
    done_today = [
        r
        for r in enriched
        if str(r.get("status")) == "done"
        and _within_day(str(r.get("updated_at") or r.get("created_at") or ""), ref)
    ]
    missing_findings = bool(done_today) and structured == 0 and inbox_count > 0

    workers = build_all_workers_status().get("workers") or []
    worker_gaps: list[dict[str, Any]] = []
    for row in active:
        host = str(row.get("target_host") or "111")
        match = next(
            (
                w
                for w in workers
                if str(w.get("host_id") or "") == host
                or str(w.get("id") or "") == f"worker-{host}"
            ),
            None,
        )
        hb = (match or {}).get("heartbeat_status") or "unknown"
        enabled = True if match is None else bool(match.get("enabled", True))
        if enabled and hb in ("unknown", "stale"):
            worker_gaps.append(
                {
                    "host": host,
                    "heartbeat_status": hb,
                    "run_id": row.get("run_id"),
                }
            )

    feeder_blocked = len(active) >= max_active
    wedged = bool(
        stuck
        or (feeder_blocked and len(active) > max_active)
        or (duplicate_goals and feeder_blocked)
        or missing_findings
        or worker_gaps
    )

    signals: list[str] = []
    if stuck:
        signals.append(
            f"{len(stuck)} run(s) pending/running longer than {threshold}s "
            "(expected task_done / run terminal status)."
        )
    if feeder_blocked:
        signals.append(
            f"Active runs ({len(active)}) at or above feeder max ({max_active}); "
            "new audits will not enqueue."
        )
    if duplicate_goals:
        signals.append(
            "Duplicate active goals detected (likely repeated enqueue without completion)."
        )
    if missing_findings:
        signals.append(
            "Expected structured ### Finding blocks after done audits today; "
            f"got structured={structured}, inbox_gaps={inbox_count}."
        )
    if worker_gaps:
        signals.append(
            f"{len(worker_gaps)} active run(s) target a worker with stale/unknown heartbeat."
        )

    would_take: list[str] = []
    if stuck or (feeder_blocked and active):
        would_take.append(
            "Approve 'Clear stuck missions' (mission_clear_stuck) to mark wedged "
            "runs failed so the feeder can enqueue productive audits."
        )
    if worker_gaps:
        would_take.append(
            "Restart alfa-ai-worker on affected hosts; confirm ALFA_AI_AUDIT_ROOTS mounts."
        )
    if missing_findings:
        would_take.append(
            "After workers are healthy, re-enqueue audit-repo so reports emit "
            "### Finding N - Severity: blocks."
        )
    if not would_take:
        would_take.append("No corrective action required; continue observing Missions.")

    return {
        "ok": True,
        "wedged": wedged,
        "stuck_threshold_sec": threshold,
        "max_active": max_active,
        "active_count": len(active),
        "stuck_count": len(stuck),
        "stuck_runs": stuck,
        "active_runs": active,
        "duplicate_goals": duplicate_goals,
        "missing_structured_findings": missing_findings,
        "findings_structured_count": structured,
        "findings_inbox_count": inbox_count,
        "worker_gaps": worker_gaps,
        "feeder_blocked": feeder_blocked,
        "signals": signals,
        "would_take_action": would_take,
        "would_auto_apply": False,
        "checked_at": ref.isoformat(),
    }


def clear_stuck_missions(
    *,
    min_age_sec: int | None = None,
    dry_run: bool = False,
) -> dict[str, Any]:
    """Mark stuck pending/running runs (and their open tasks) as failed.

    Does not touch inference. L2: call only after operator Approve on mission_clear_stuck.
    """
    from src.runtime.factory import build_orchestrator

    orch = build_orchestrator()
    threshold = min_age_sec if min_age_sec is not None else stuck_threshold_sec()
    now = datetime.now(tz=UTC)
    runs = [run_to_dict(r) for r in orch.store.list_runs()]
    tasks_by_run: dict[str, list[dict[str, Any]]] = {}
    for run in runs:
        rid = str(run.get("run_id") or "")
        if not rid:
            continue
        tasks_by_run[rid] = [
            task_to_dict(t) for t in orch.store.list_tasks_for_run(rid)
        ]

    report = detect_mission_wedge(runs, tasks_by_run=tasks_by_run, now=now)
    to_clear = list(report.get("stuck_runs") or [])
    if not to_clear and report.get("feeder_blocked") and report.get("duplicate_goals"):
        active = sorted(
            report.get("active_runs") or [],
            key=lambda r: int(r.get("age_sec") or 0),
            reverse=True,
        )
        keep = max(0, max_active_runs() - 1)
        to_clear = active[keep:]

    cleared: list[dict[str, Any]] = []
    for row in to_clear:
        run_id = str(row.get("run_id") or "")
        if not run_id:
            continue
        if dry_run:
            cleared.append({**row, "cleared": False, "dry_run": True})
            continue
        orch.store.update_run_status(run_id, "failed")
        for task in tasks_by_run.get(run_id) or []:
            tstatus = str(task.get("status") or "")
            if tstatus in ("pending", "ready", "running", "blocked"):
                orch.store.update_task_status(str(task.get("task_id")), "failed")
        cleared.append({**row, "cleared": True, "dry_run": False})

    return {
        "ok": True,
        "dry_run": dry_run,
        "stuck_threshold_sec": threshold,
        "cleared_count": len(cleared),
        "cleared": cleared,
        "wedge_before": {
            "wedged": report.get("wedged"),
            "active_count": report.get("active_count"),
            "stuck_count": report.get("stuck_count"),
            "signals": report.get("signals"),
        },
        "note": (
            "Runs marked failed so feeder can enqueue again. "
            "Re-enqueue audit-repo after workers are healthy."
        ),
    }


def format_wedge_report(report: dict[str, Any]) -> str:
    lines: list[str] = []
    if report.get("wedged"):
        lines.append("MISSION WEDGE DETECTED (expected feedback missing).")
    else:
        lines.append("Mission queue looks healthy (no wedge signals).")
    lines.append(
        f"- Active: {report.get('active_count', 0)} "
        f"(max feeder {report.get('max_active', 2)}); "
        f"stuck>={report.get('stuck_threshold_sec')}s: {report.get('stuck_count', 0)}"
    )
    for sig in report.get("signals") or []:
        lines.append(f"- Signal: {sig}")
    for row in (report.get("stuck_runs") or [])[:8]:
        age = row.get("age_sec")
        age_m = f"{int(age) // 60}m" if age is not None else "?"
        lines.append(
            f"- Stuck {str(row.get('run_id') or '')[:8]}... "
            f"age={age_m} host=.{row.get('target_host')} "
            f"status={row.get('status')} -- {(row.get('goal') or '')[:70]}"
        )
    for gap in (report.get("worker_gaps") or [])[:6]:
        lines.append(
            f"- Worker gap: host .{gap.get('host')} heartbeat={gap.get('heartbeat_status')} "
            f"run={str(gap.get('run_id') or '')[:8]}..."
        )
    lines.append("")
    lines.append("Would take (propose-only until Approve):")
    for step in report.get("would_take_action") or []:
        lines.append(f"  - {step}")
    lines.append(
        'Say "Clear stuck missions" for an Approve card, or open Admin -> Missions.'
    )
    return "\n".join(lines)
