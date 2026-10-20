"""Tests for mission wedge detection and clear-stuck."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from pathlib import Path

from src.ops.mission_wedge import (
    clear_stuck_missions,
    detect_mission_wedge,
    enrich_run_from_tasks,
    format_wedge_report,
)
from src.runtime.models import RunRecord, TaskRecord, now_iso
from src.runtime.orchestrator import RuntimeOrchestrator
from src.runtime.queue import InMemoryQueue
from src.runtime.store import InMemoryStore, run_to_dict, task_to_dict


def test_enrich_run_from_tasks_fills_skill_and_host() -> None:
    run = {"run_id": "r1", "skill": "", "target_host": "111", "goal": "x"}
    tasks = [
        {
            "metadata": {"skill": "audit-repo", "target_host": "102"},
        }
    ]
    out = enrich_run_from_tasks(run, tasks)
    assert out["skill"] == "audit-repo"
    assert out["target_host"] == "102"


def test_detect_stuck_runs_over_threshold(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("ALFA_AI_MISSION_STUCK_SEC", "600")
    monkeypatch.setenv("ALFA_AI_AUDIT_LOG_DIR", str(tmp_path))
    now = datetime(2026, 7, 14, 12, 0, tzinfo=UTC)
    old = (now - timedelta(hours=2)).isoformat()
    runs = [
        {
            "run_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "goal": "Research FastAPI lifespan vs on_event",
            "status": "running",
            "skill": "",
            "target_host": "111",
            "created_at": old,
            "updated_at": old,
        },
        {
            "run_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            "goal": "fresh audit",
            "status": "running",
            "skill": "audit-repo",
            "target_host": "111",
            "created_at": now.isoformat(),
            "updated_at": now.isoformat(),
        },
    ]
    report = detect_mission_wedge(runs, log_dir=tmp_path, now=now)
    assert report["stuck_count"] == 1
    assert report["wedged"] is True
    assert "expected task_done" in (report["signals"][0] if report["signals"] else "")
    text = format_wedge_report(report)
    assert "MISSION WEDGE DETECTED" in text
    assert "Clear stuck missions" in text


def test_clear_stuck_missions_marks_failed(monkeypatch) -> None:
    monkeypatch.setenv("ALFA_AI_MISSION_STUCK_SEC", "60")
    store = InMemoryStore()
    orch = RuntimeOrchestrator(store=store, queue=InMemoryQueue())
    monkeypatch.setattr(
        "src.runtime.factory.build_orchestrator", lambda: orch
    )

    old = (datetime.now(tz=UTC) - timedelta(hours=3)).isoformat()
    run = RunRecord(
        run_id="cccccccc-cccc-cccc-cccc-cccccccccccc",
        goal="Research FastAPI lifespan vs on_event",
        status="running",
        created_at=old,
        updated_at=old,
    )
    store.create_run(run)
    task = TaskRecord(
        task_id="t1",
        run_id=run.run_id,
        role="researcher",
        title="research",
        status="running",
        metadata={"skill": "audit-repo", "target_host": "111"},
        created_at=old,
        updated_at=old,
    )
    store.create_task(task)

    result = clear_stuck_missions()
    assert result["cleared_count"] >= 1
    assert store.get_run(run.run_id).status == "failed"
    assert store.get_task("t1").status == "failed"


def test_process_next_skips_terminal_run(monkeypatch) -> None:
    store = InMemoryStore()
    queue = InMemoryQueue()
    orch = RuntimeOrchestrator(store=store, queue=queue)
    run = RunRecord(
        run_id="dddddddd-dddd-dddd-dddd-dddddddddddd",
        goal="already failed",
        status="failed",
    )
    store.create_run(run)
    task = TaskRecord(
        task_id="t-skip",
        run_id=run.run_id,
        role="researcher",
        title="x",
        status="ready",
        metadata={"target_host": "111"},
    )
    store.create_task(task)
    queue.push_task("t-skip", target_host="111")
    out = orch.process_next_task(worker_host="111")
    assert out is not None
    assert out["status"] == "failed"
    assert "skipped" in (out.get("summary") or "")
    assert store.get_task("t-skip").status == "failed"
