"""LiteLLM agent JSON mode: response_format gating and graceful degradation."""

from __future__ import annotations

from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest
from openai import APIStatusError

from src.llm import client
from src.llm.agent_circuit import reset_agent_circuit_for_tests


def _mock_chat_response(content: str = "ok") -> SimpleNamespace:
    message = SimpleNamespace(content=content, tool_calls=[])
    choice = SimpleNamespace(message=message)
    return SimpleNamespace(choices=[choice])


def _api_status_error(status_code: int, message: str) -> APIStatusError:
    response = MagicMock()
    response.status_code = status_code
    response.text = message
    return APIStatusError(message, response=response, body=None)


@pytest.fixture(autouse=True)
def _litellm_provider(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("LITELLM_API_KEY", "sk-test")
    monkeypatch.setenv("LITELLM_BASE_URL", "http://127.0.0.1:8413")
    monkeypatch.setenv("ALFA_AI_PROVIDER", "litellm")


def test_response_format_absent_when_tools_passed(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_AGENT_JSON_MODE", "1")
    captured: dict = {}

    def fake_create(**kwargs):
        captured.update(kwargs)
        return _mock_chat_response()

    mock_client = MagicMock()
    mock_client.chat.completions.create = fake_create
    monkeypatch.setattr(client, "OpenAI", lambda *args, **kwargs: mock_client)

    tools = [{"type": "function", "function": {"name": "read_file", "parameters": {}}}]
    client._litellm_completion(
        [{"role": "user", "content": "hi"}],
        tools=tools,
        response_format={"type": "json_object"},
    )

    assert "tools" in captured
    assert "response_format" not in captured


def test_response_format_present_when_enabled_no_tools(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_AGENT_JSON_MODE", "1")
    captured: dict = {}

    def fake_create(**kwargs):
        captured.update(kwargs)
        return _mock_chat_response('{"reply":"hello"}')

    mock_client = MagicMock()
    mock_client.chat.completions.create = fake_create
    monkeypatch.setattr(client, "OpenAI", lambda *args, **kwargs: mock_client)

    client._litellm_completion(
        [{"role": "user", "content": "hi"}],
        response_format={"type": "json_object"},
    )

    assert captured.get("response_format") == {"type": "json_object"}
    assert "tools" not in captured


def test_response_format_absent_when_flag_disabled(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_AGENT_JSON_MODE", "0")
    assert client.agent_synthesis_response_format() is None

    captured: dict = {}

    def fake_create(**kwargs):
        captured.update(kwargs)
        return _mock_chat_response()

    mock_client = MagicMock()
    mock_client.chat.completions.create = fake_create
    monkeypatch.setattr(client, "OpenAI", lambda *args, **kwargs: mock_client)

    client._litellm_completion(
        [{"role": "user", "content": "hi"}],
        response_format=None,
    )

    assert "response_format" not in captured


def test_agent_synthesis_response_format_covers_first_turn(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The malformed-JSON reply seen in production was a first turn, not a post-tool turn."""
    monkeypatch.setenv("ALFA_AI_AGENT_JSON_MODE", "1")
    assert client.agent_synthesis_response_format() == {"type": "json_object"}


def test_monitoring_agent_requests_json_mode_on_first_turn(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """get_agent_completion helper sends json_object when ALFA_AI_AGENT_JSON_MODE=1."""
    monkeypatch.setenv("ALFA_AI_AGENT_JSON_MODE", "1")
    reset_agent_circuit_for_tests()
    captured: list[dict] = []

    def fake_create(**kwargs):
        captured.append(dict(kwargs))
        return _mock_chat_response('{"reply":"hi","setting_change":null}')

    mock_client = MagicMock()
    mock_client.chat.completions.create = fake_create
    monkeypatch.setattr(client, "OpenAI", lambda *args, **kwargs: mock_client)

    client.get_agent_completion(
        [{"role": "user", "content": "what jobs have you done?"}],
        response_format=client.agent_synthesis_response_format(),
    )

    assert captured[0].get("response_format") == {"type": "json_object"}
    assert "tools" not in captured[0]


def test_response_format_unsupported_retries_without_it(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_AGENT_JSON_MODE", "1")
    calls: list[dict] = []

    def fake_create(**kwargs):
        calls.append(dict(kwargs))
        if "response_format" in kwargs:
            raise _api_status_error(400, "invalid_request: response_format not supported")
        return _mock_chat_response('{"reply":"recovered"}')

    mock_client = MagicMock()
    mock_client.chat.completions.create = fake_create
    monkeypatch.setattr(client, "OpenAI", lambda *args, **kwargs: mock_client)

    turn = client._litellm_completion(
        [{"role": "user", "content": "hi"}],
        response_format={"type": "json_object"},
    )

    assert len(calls) == 2
    assert "response_format" in calls[0]
    assert "response_format" not in calls[1]
    assert turn.content == '{"reply":"recovered"}'
