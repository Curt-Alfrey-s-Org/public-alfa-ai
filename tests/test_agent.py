from __future__ import annotations

from pathlib import Path
from unittest.mock import MagicMock

import pytest

from src.agent import loop
from src.agent.loop import AgentRunResult
from src.agent.skills import load_skill, resolve_skill_name
from src.agent.tools import create_file, edit_file, fetch_url, glob_files, grep_repo, run_cmd, web_search
from src.agent.roles import RoleRequest
from src.llm import client
from src.runtime import roles as runtime_roles
from src.runtime.orchestrator import RuntimeOrchestrator
from src.runtime.planner import plan_initial_tasks
from src.runtime.queue import InMemoryQueue
from src.runtime.store import InMemoryStore


def test_run_agent_executes_tool_then_returns_final(monkeypatch) -> None:
    replies = iter(
        [
            '{"tool":"list_dir","args":{"path":"."}}',
            "All done.",
        ]
    )

    def fake_completion(_messages):
        return next(replies)

    monkeypatch.setattr(loop, "get_completion", fake_completion)
    result = loop.run_agent("Show me files", max_steps=3)
    assert result.text == "All done."


def test_run_agent_native_tool_calls(monkeypatch) -> None:
    monkeypatch.setenv("ALFA_AI_NATIVE_TOOLS", "1")
    from src.llm.client import ChatTurn, NativeToolCall

    turns = iter(
        [
            ChatTurn(
                content="",
                tool_calls=[NativeToolCall(id="c1", name="list_dir", arguments={"path": "."})],
            ),
            ChatTurn(content="Listed.", tool_calls=[]),
        ]
    )

    def fake_turn(_messages, tools=None):
        assert tools
        return next(turns)

    monkeypatch.setattr(loop, "get_completion_turn", fake_turn)
    result = loop.run_agent("Show me files", max_steps=3)
    assert result.text == "Listed."
    assert result.tool_events
    assert result.tool_events[0].tool_name == "list_dir"


def test_run_agent_researcher_uses_agent_completion(monkeypatch) -> None:
    calls: list[str] = []

    def fake_agent(_messages):
        calls.append("agent")
        return "Research complete."

    monkeypatch.setattr(loop, "get_agent_completion", fake_agent)
    result = loop.run_agent("Research topic", max_steps=2, role="researcher")
    assert result.text == "Research complete."
    assert calls == ["agent"]


def test_run_agent_records_tool_events(monkeypatch) -> None:
    replies = iter(
        [
            '{"tool":"list_dir","args":{"path":"."}}',
            "Done.",
        ]
    )

    def fake_completion(_messages):
        return next(replies)

    monkeypatch.setattr(loop, "get_agent_completion", fake_completion)
    result = loop.run_agent("List files", max_steps=3, role="researcher")
    assert result.text == "Done."
    assert len(result.tool_events) == 1
    assert result.tool_events[0].tool_name == "list_dir"
    assert result.tool_events[0].ok is True


def test_edit_file_replaces_unique_match(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    target = tmp_path / "sample.py"
    target.write_text("alpha = 1\nbeta = 2\n", encoding="utf-8")
    result = edit_file("sample.py", "alpha = 1", "alpha = 42")
    assert result["ok"] is True
    assert target.read_text(encoding="utf-8") == "alpha = 42\nbeta = 2\n"


def test_edit_file_rejects_ambiguous_match(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    target = tmp_path / "sample.py"
    target.write_text("foo\nfoo\n", encoding="utf-8")
    result = edit_file("sample.py", "foo", "bar")
    assert result["ok"] is False


def test_load_audit_repo_skill() -> None:
    body = load_skill("audit-repo")
    assert body is not None
    assert "Findings" in body


def test_resolve_skill_name_defaults() -> None:
    assert resolve_skill_name("coder") == "implement"
    assert resolve_skill_name("researcher", research_only=True) == "audit-repo"


def test_create_file_respects_workspace_root(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    result = create_file("notes/test.txt", "hello")
    assert result["ok"] is True
    assert (tmp_path / "notes/test.txt").read_text(encoding="utf-8") == "hello"

    blocked = create_file("../escape.txt", "nope")
    assert blocked["ok"] is False


def test_run_cmd_blocks_dangerous_command(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    result = run_cmd("rm -rf /")
    assert result["ok"] is False
    assert "blocked" in result["error"].lower()


def test_provider_fallback_to_ollama(monkeypatch) -> None:
    monkeypatch.delenv("ALFA_AI_PROVIDER", raising=False)
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    assert client._choose_provider() == "ollama"


def test_glob_files_finds_files(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    (tmp_path / "src").mkdir()
    (tmp_path / "src" / "main.py").write_text("x", encoding="utf-8")
    result = glob_files("**/*.py", path=".")
    assert result["ok"] is True
    assert "src/main.py" in result["paths"] or "src\\main.py" in result["paths"]


def test_grep_repo_finds_pattern(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    target = tmp_path / "sample.txt"
    target.write_text("hello ALFA_UNIQUE_TOKEN world\n", encoding="utf-8")
    result = grep_repo("ALFA_UNIQUE_TOKEN", path=".")
    if result.get("error") == "ripgrep (rg) is not installed on this host.":
        pytest.skip("rg not installed")
    assert result["ok"] is True
    assert len(result["matches"]) >= 1


def test_fetch_url_rejects_non_allowlisted_host(monkeypatch) -> None:
    monkeypatch.setenv("ALFA_AI_FETCH_ALLOWLIST", "docs.docker.com")
    result = fetch_url("https://example.com/page")
    assert result["ok"] is False
    assert "allowlist" in result["error"].lower()


def test_fetch_url_allowlisted_host(monkeypatch) -> None:
    monkeypatch.setenv("ALFA_AI_FETCH_ALLOWLIST", "docs.docker.com")

    html = (
        "<html><body><h1>Docker Docs</h1>"
        + ("<p>Official documentation content for testing.</p>" * 20)
        + "</body></html>"
    )
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.headers = {"content-type": "text/html"}
    mock_response.text = html
    mock_response.url = "https://docs.docker.com/reference/"

    mock_client = MagicMock()
    mock_client.get.return_value = mock_response
    mock_client.__enter__ = MagicMock(return_value=mock_client)
    mock_client.__exit__ = MagicMock(return_value=False)

    monkeypatch.setattr("src.agent.tools.httpx.Client", lambda **kwargs: mock_client)
    result = fetch_url("https://docs.docker.com/reference/")
    assert result["ok"] is True
    assert "Docker Docs" in result["content"]


def test_get_completion_litellm_fallback_on_retryable_error(monkeypatch) -> None:
    monkeypatch.setenv("ALFA_AI_PROVIDER", "litellm")
    monkeypatch.setenv("LITELLM_BASE_URL", "http://127.0.0.1:8413")
    monkeypatch.setenv("LITELLM_API_KEY", "sk-test")
    calls: list[str | None] = []

    def fake_litellm(messages, *, model=None, max_tokens=None, tools=None, response_format=None):
        calls.append(model)
        if model == "frontier-code":
            raise client.LLMRetryableError("upstream 503")
        return client.ChatTurn(content="fallback ok")

    monkeypatch.setattr(client, "_litellm_completion", fake_litellm)
    out = client.get_completion(
        [{"role": "user", "content": "hi"}],
        model="frontier-code",
        fallback_model="agent",
    )
    assert out == "fallback ok"
    assert calls == ["frontier-code", "agent"]


def test_researcher_role_writes_artifact(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))

    def fake_run_agent(*args, **kwargs):
        return AgentRunResult(
            text="Findings.\n\n## Sources\n- docs/ARCHITECTURE_SPEC.md",
            tool_events=[],
        )

    monkeypatch.setattr(runtime_roles, "run_agent", fake_run_agent)
    request = RoleRequest(
        run_id="run-1",
        task_id="task-1",
        role="researcher",
        goal="Test research",
        constraints={"research_only": True},
    )
    response = runtime_roles.execute_role(request)
    assert response.status == "success"
    assert len(response.artifacts) == 1
    assert response.artifacts[0].artifact_type == "audit_report"
    artifact_path = tmp_path / response.artifacts[0].path
    assert artifact_path.is_file()
    assert "Findings" in artifact_path.read_text(encoding="utf-8")


def test_coder_role_uses_agent_loop(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    calls: list[str] = []

    def fake_run_agent(*args, **kwargs):
        calls.append(kwargs.get("role", ""))
        return AgentRunResult(text="Changed src/main.py via edit_file.", tool_events=[])

    monkeypatch.setattr(runtime_roles, "run_agent", fake_run_agent)
    request = RoleRequest(
        run_id="run-2",
        task_id="task-2",
        role="coder",
        goal="Add logging",
    )
    response = runtime_roles.execute_role(request)
    assert response.status == "success"
    assert calls == ["coder"]
    assert response.artifacts[0].artifact_type == "code_patch"
    artifact_path = tmp_path / response.artifacts[0].path
    assert "Changed src/main.py" in artifact_path.read_text(encoding="utf-8")


def test_debugger_role_uses_agent_loop(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    calls: list[str] = []

    def fake_run_agent(*args, **kwargs):
        calls.append(kwargs.get("role", ""))
        return AgentRunResult(text="Root cause: missing env var.", tool_events=[])

    monkeypatch.setattr(runtime_roles, "run_agent", fake_run_agent)
    request = RoleRequest(
        run_id="run-dbg",
        task_id="task-dbg",
        role="debugger",
        goal="Why did health fail?",
    )
    response = runtime_roles.execute_role(request)
    assert response.status == "success"
    assert calls == ["debugger"]
    assert response.artifacts[0].artifact_type == "debug_report"
    body = (tmp_path / response.artifacts[0].path).read_text(encoding="utf-8")
    assert "missing env var" in body


def test_doc_maker_role_uses_agent_loop(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    calls: list[str] = []

    def fake_run_agent(*args, **kwargs):
        calls.append(kwargs.get("role", ""))
        return AgentRunResult(text="# Operator notes\n\nRestart via orchestrator.", tool_events=[])

    monkeypatch.setattr(runtime_roles, "run_agent", fake_run_agent)
    request = RoleRequest(
        run_id="run-doc",
        task_id="task-doc",
        role="doc_maker",
        goal="Document restart",
    )
    response = runtime_roles.execute_role(request)
    assert response.status == "success"
    assert calls == ["doc_maker"]
    assert response.artifacts[0].artifact_type == "doc_page"
    body = (tmp_path / response.artifacts[0].path).read_text(encoding="utf-8")
    assert "orchestrator" in body


def test_plan_research_only_single_task() -> None:
    tasks, deps = plan_initial_tasks("run-1", "Research FastAPI", research_only=True)
    assert len(tasks) == 1
    assert tasks[0].role == "researcher"
    assert tasks[0].status == "ready"
    assert deps == []


def test_orchestrator_research_only_run(monkeypatch, tmp_path: Path) -> None:
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))

    def fake_run_agent(*args, **kwargs):
        return AgentRunResult(text="Done.")

    monkeypatch.setattr(runtime_roles, "run_agent", fake_run_agent)
    store = InMemoryStore()
    orch = RuntimeOrchestrator(store=store, queue=InMemoryQueue())
    run_id = orch.create_run("Research topic", research_only=True)
    result = orch.process_next_task()
    assert result is not None
    assert result["status"] == "done"
    tasks = store.list_tasks_for_run(run_id)
    assert len(tasks) == 1
    assert tasks[0].role == "researcher"


def test_web_search_disabled_by_default(monkeypatch) -> None:
    monkeypatch.setenv("ALFA_AI_WEB_SEARCH_ENABLED", "0")
    result = web_search("fastapi lifespan")
    assert result["ok"] is False
    assert "disabled" in result["error"].lower()


def test_web_search_enabled_parses_json(monkeypatch) -> None:
    monkeypatch.setenv("ALFA_AI_WEB_SEARCH_ENABLED", "1")
    monkeypatch.setenv("ALFA_AI_SEARXNG_URL", "http://127.0.0.1:8888")

    payload = {
        "results": [
            {
                "title": "FastAPI",
                "url": "https://fastapi.tiangolo.com/",
                "content": "Official docs",
            }
        ]
    }
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.json.return_value = payload

    mock_client = MagicMock()
    mock_client.get.return_value = mock_response
    mock_client.__enter__ = MagicMock(return_value=mock_client)
    mock_client.__exit__ = MagicMock(return_value=False)

    monkeypatch.setattr("src.agent.tools.httpx.Client", lambda **kwargs: mock_client)
    result = web_search("fastapi lifespan", max_results=3)
    assert result["ok"] is True
    assert result["results"][0]["url"] == "https://fastapi.tiangolo.com/"


def test_run_agent_persists_memory_and_injects_prompt(monkeypatch, tmp_path: Path) -> None:
    monkeypatch.setenv("ALFA_AI_DATA", str(tmp_path / "data"))
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path / "repo"))
    (tmp_path / "repo").mkdir()
    seen_system: list[str] = []

    def fake_agent(messages):
        if not seen_system:
            seen_system.append(messages[0]["content"])
        return "Answer.\n\n## Sources\n- docs/test.md"

    monkeypatch.setattr(loop, "get_agent_completion", fake_agent)
    loop.run_agent("First mission goal", max_steps=2, role="researcher")
    assert seen_system
    assert "Prior mission memory" not in seen_system[0]

    def fake_agent_second(messages):
        if not seen_system[1:2]:
            seen_system.append(messages[0]["content"])
        return "Second answer."

    monkeypatch.setattr(loop, "get_agent_completion", fake_agent_second)
    loop.run_agent("Second mission goal", max_steps=2, role="researcher")
    assert len(seen_system) >= 2
    assert "Recent missions" in seen_system[1] or "Prior mission memory" in seen_system[1]
    memory_path = tmp_path / "data" / "implement-memory"
    files = list(memory_path.glob("*.md"))
    assert files
    assert "First mission goal" in files[0].read_text(encoding="utf-8")
