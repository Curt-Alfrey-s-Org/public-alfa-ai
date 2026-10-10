"""Tests for multi-host agent fleet queue affinity and host tools."""

from __future__ import annotations

from pathlib import Path

import pytest

from src.agent.host_tools import disk_mem, log_grep
from src.runtime.models import RunRecord, TaskRecord
from src.runtime.orchestrator import RuntimeOrchestrator
from src.runtime.queue import InMemoryQueue
from src.runtime.store import InMemoryStore
from src.runtime.worker_host import normalize_worker_host, queue_name_for_host, task_target_host


def test_normalize_worker_host_defaults_to_111() -> None:
    assert normalize_worker_host(None) == "111"
    assert normalize_worker_host("") == "111"
    assert normalize_worker_host("105") == "105"


def test_queue_name_per_host() -> None:
    assert queue_name_for_host("105") == "alfaai:queue:tasks:105"
    assert queue_name_for_host(None) == "alfaai:queue:tasks:111"


def test_inmemory_queue_host_affinity() -> None:
    q = InMemoryQueue()
    q.push_task("task-105", target_host="105")
    q.push_task("task-111", target_host="111")
    assert q.pop_task(worker_host="105") == "task-105"
    assert q.pop_task(worker_host="105") is None
    assert q.pop_task(worker_host="111") == "task-111"


def test_task_target_host_from_metadata() -> None:
    task = TaskRecord(
        task_id="t1",
        run_id="r1",
        role="researcher",
        title="x",
        metadata={"target_host": "106"},
    )
    assert task_target_host(task.metadata) == "106"


def test_create_run_routes_to_host_queue(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))

    def fake_run_agent(*args, **kwargs):
        from src.agent.loop import AgentRunResult

        return AgentRunResult(text="done")

    monkeypatch.setattr("src.runtime.roles.run_agent", fake_run_agent)

    store = InMemoryStore()
    queue = InMemoryQueue()
    orch = RuntimeOrchestrator(store=store, queue=queue)
    run_id = orch.create_run(
        goal="Host facts on 105",
        skill="host-facts",
        research_only=True,
        target_host="105",
    )
    assert run_id
    run = store.get_run(run_id)
    assert run is not None
    assert run.target_host == "105"

    assert orch.process_next_task(worker_host="111") is None
    result = orch.process_next_task(worker_host="105")
    assert result is not None
    assert result["status"] == "done"


def test_log_grep_rejects_non_allowlisted_path(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    secret = tmp_path / "secrets.txt"
    secret.write_text("error line\n", encoding="utf-8")
    out = log_grep(str(secret), "error")
    assert out["ok"] is False
    assert "allowlisted" in out["error"]


def test_log_grep_finds_in_workspace_log(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    log_file = tmp_path / "app.log"
    log_file.write_text("INFO ok\nERROR boom\n", encoding="utf-8")
    out = log_grep("app.log", "ERROR")
    assert out["ok"] is True
    assert out["match_count"] == 1


def test_disk_mem_returns_tool_key() -> None:
    out = disk_mem()
    assert out.get("tool") == "disk_mem"
