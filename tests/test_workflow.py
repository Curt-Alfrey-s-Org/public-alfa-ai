from __future__ import annotations

from pathlib import Path

from src.agent.loop import AgentRunResult
from src.runtime.orchestrator import RuntimeOrchestrator
from src.runtime.planner import plan_initial_tasks
from src.runtime.queue import InMemoryQueue
from src.runtime.store import InMemoryStore
from src.runtime.verify import parse_verdict
from src.runtime.workflow import (
    MAX_FIX_ROUNDS,
    wants_implement_review_fix,
)


def test_wants_implement_review_fix() -> None:
    assert wants_implement_review_fix(skill="implement")
    assert wants_implement_review_fix(workflow="implement_review_fix")
    assert not wants_implement_review_fix(skill="audit-repo")


def test_plan_implement_creates_three_tasks() -> None:
    tasks, deps = plan_initial_tasks(
        run_id="r1",
        goal="Add health endpoint",
        skill="implement",
    )
    assert len(tasks) == 3
    assert [t.role for t in tasks] == ["coder", "researcher", "debugger"]
    assert len(deps) == 2
    assert tasks[0].status == "ready"
    assert tasks[1].status == "pending"
    assert tasks[0].metadata["workflow"] == "implement_review_fix"
    assert tasks[2].metadata["skill"] == "check-work"


def test_workflow_run_completes_with_pass(monkeypatch, tmp_path: Path) -> None:
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    monkeypatch.setenv("ALFA_AI_DATA", str(tmp_path / "data"))
    monkeypatch.setenv("ALFA_AI_AGENT_MUTATE_ENABLED", "0")

    def fake_run_agent(*args, **kwargs):
        role = kwargs.get("role", "")
        if role == "coder":
            return AgentRunResult(text="Proposed patch for health endpoint (propose-only).")
        if role == "researcher":
            return AgentRunResult(text="### Issue 1 — Severity: nit\n- File: app.py:1\n- Status: open")
        if role == "debugger":
            return AgentRunResult(text="Goal addressed in summary.\n\nVERDICT: PASS")
        return AgentRunResult(text="ok")

    monkeypatch.setattr("src.runtime.roles.run_agent", fake_run_agent)

    store = InMemoryStore()
    queue = InMemoryQueue()
    orch = RuntimeOrchestrator(store=store, queue=queue)
    run_id = orch.create_run("Add health endpoint", skill="implement")
    steps = 0
    while True:
        result = orch.process_next_task()
        if result is None:
            break
        steps += 1
        assert steps <= 10

    run = store.get_run(run_id)
    assert run is not None
    assert run.status == "done"
    tasks = store.list_tasks_for_run(run_id)
    assert len(tasks) == 3
    assert all(t.status == "done" for t in tasks)
    artifacts = store.list_artifacts_for_run(run_id)
    types = {a.artifact_type for a in artifacts}
    assert "code_patch" in types
    assert "review_report" in types
    assert "check_work_report" in types


def test_workflow_enqueues_fix_round_on_fail(monkeypatch, tmp_path: Path) -> None:
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    monkeypatch.setenv("ALFA_AI_DATA", str(tmp_path / "data"))

    calls = {"n": 0}

    def fake_run_agent(*args, **kwargs):
        role = kwargs.get("role", "")
        calls["n"] += 1
        if role == "debugger":
            # First check-work fails; later rounds pass
            if calls["n"] <= 3:
                return AgentRunResult(text="Missing tests.\n\nVERDICT: FAIL")
            return AgentRunResult(text="Looks good.\n\nVERDICT: PASS")
        return AgentRunResult(text=f"{role} output")

    monkeypatch.setattr("src.runtime.roles.run_agent", fake_run_agent)

    store = InMemoryStore()
    queue = InMemoryQueue()
    orch = RuntimeOrchestrator(store=store, queue=queue)
    run_id = orch.create_run("Fix lint", workflow="implement_review_fix")

    for _ in range(20):
        result = orch.process_next_task()
        if result is None:
            break

    tasks = store.list_tasks_for_run(run_id)
    rounds = {int((t.metadata or {}).get("round") or 0) for t in tasks}
    assert 1 in rounds
    assert 2 in rounds
    assert max(rounds) <= MAX_FIX_ROUNDS


def test_parse_verdict() -> None:
    assert parse_verdict("hello\nVERDICT: PASS\n") == "PASS"
    assert parse_verdict("VERDICT: fail") == "FAIL"
    assert parse_verdict("no verdict here") is None
