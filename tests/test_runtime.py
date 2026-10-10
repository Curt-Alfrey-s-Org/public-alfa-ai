from __future__ import annotations

from pathlib import Path

from src.agent.loop import AgentRunResult
from src.runtime.orchestrator import RuntimeOrchestrator
from src.runtime.queue import InMemoryQueue
from src.runtime.store import InMemoryStore


def _patch_research_agent(monkeypatch) -> None:
    def fake_run_agent(*args, **kwargs):
        role = kwargs.get("role", "")
        if role == "coder":
            return AgentRunResult(text="Implemented feature in src/app.py.")
        return AgentRunResult(text="Research summary.\n\n## Sources\n- docs/README.md")

    monkeypatch.setattr("src.runtime.roles.run_agent", fake_run_agent)


def test_create_run_creates_four_tasks(monkeypatch, tmp_path: Path) -> None:
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    store = InMemoryStore()
    queue = InMemoryQueue()
    orch = RuntimeOrchestrator(store=store, queue=queue)

    run_id = orch.create_run("Build me a CLI tool")
    tasks = store.list_tasks_for_run(run_id)
    assert len(tasks) == 4
    assert sum(1 for t in tasks if t.status == "ready") == 1
    assert store.get_run(run_id) is not None


def test_process_contracts_role_registers_output_files(monkeypatch, tmp_path: Path) -> None:
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))

    def fake_invoke(request, *, role, prompt, persona=None):
        from src.agent.tools import create_file

        output_rel = f".alfa_ai/artifacts/{request.run_id}/{request.task_id}/analysis.md"
        create_file(output_rel, "# Contract analysis\n\nGo recommendation.")
        return AgentRunResult(text="Wrote analysis.md")

    monkeypatch.setattr("src.runtime.roles._invoke_agent", fake_invoke)

    store = InMemoryStore()
    queue = InMemoryQueue()
    orch = RuntimeOrchestrator(store=store, queue=queue)
    run_id = orch.create_run(
        "Review RFP",
        role="contracts",
        input_files=[{"filename": "rfp.txt", "content": "Requirements here"}],
    )
    result = orch.process_next_task()
    assert result is not None
    assert result["status"] == "done"
    artifacts = store.list_artifacts_for_run(run_id)
    assert len(artifacts) >= 1
    assert store.get_run(run_id).status == "done"


def test_process_next_task_advances_queue(monkeypatch, tmp_path: Path) -> None:
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    _patch_research_agent(monkeypatch)
    store = InMemoryStore()
    queue = InMemoryQueue()
    orch = RuntimeOrchestrator(store=store, queue=queue)

    run_id = orch.create_run("Build me a web app")
    first = orch.process_next_task()
    assert first is not None
    assert first["status"] == "done"

    tasks = store.list_tasks_for_run(run_id)
    assert any(t.status == "ready" for t in tasks)
    assert store.get_run(run_id).status == "running"


def test_full_run_creates_artifacts_for_each_role(monkeypatch, tmp_path: Path) -> None:
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    _patch_research_agent(monkeypatch)
    store = InMemoryStore()
    queue = InMemoryQueue()
    orch = RuntimeOrchestrator(store=store, queue=queue)

    run_id = orch.create_run("Build and document a sample component")
    while True:
        result = orch.process_next_task()
        if result is None:
            break

    run = store.get_run(run_id)
    assert run is not None
    assert run.status == "done"

    artifacts = store.list_artifacts_for_run(run_id)
    assert len(artifacts) == 4
    artifact_types = {item.artifact_type for item in artifacts}
    assert artifact_types == {"audit_report", "code_patch", "debug_report", "doc_page"}

