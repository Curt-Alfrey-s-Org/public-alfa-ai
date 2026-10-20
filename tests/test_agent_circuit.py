from __future__ import annotations

import time

import pytest

from src.llm import agent_circuit, client
from src.llm.agent_circuit import AgentCircuitOpenError
from src.llm.client import ChatTurn


@pytest.fixture(autouse=True)
def _reset_circuit() -> None:
    agent_circuit.reset_agent_circuit_for_tests()


def test_success_resets_failure_count(monkeypatch: pytest.MonkeyPatch) -> None:
    calls = {"n": 0}

    def flaky_completion(_messages, **kwargs):
        calls["n"] += 1
        if calls["n"] <= 2:
            raise RuntimeError("upstream down")
        return ChatTurn(content="ok")

    monkeypatch.setattr(client, "get_completion_turn", flaky_completion)

    messages = [{"role": "user", "content": "hi"}]
    with pytest.raises(RuntimeError):
        client.get_agent_completion(messages)
    with pytest.raises(RuntimeError):
        client.get_agent_completion(messages)

    assert client.get_agent_completion(messages) == "ok"
    assert client.get_agent_completion(messages) == "ok"


def test_consecutive_failures_open_circuit(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_AGENT_CIRCUIT_FAILURES", "3")

    def always_fail(_messages, **kwargs):
        raise RuntimeError("model down")

    monkeypatch.setattr(client, "get_completion_turn", always_fail)
    messages = [{"role": "user", "content": "hi"}]

    for _ in range(3):
        with pytest.raises(RuntimeError):
            client.get_agent_completion(messages)

    with pytest.raises(AgentCircuitOpenError, match="circuit open"):
        client.get_agent_completion(messages)


def test_circuit_open_fail_fast_without_llm_call(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_AGENT_CIRCUIT_FAILURES", "2")
    llm_calls: list[str] = []

    def failing_completion(_messages, **kwargs):
        llm_calls.append("call")
        raise RuntimeError("down")

    monkeypatch.setattr(client, "get_completion_turn", failing_completion)
    messages = [{"role": "user", "content": "hi"}]

    for _ in range(2):
        with pytest.raises(RuntimeError):
            client.get_agent_completion(messages)

    with pytest.raises(AgentCircuitOpenError):
        client.get_agent_completion(messages)

    assert llm_calls == ["call", "call"]


def test_circuit_closes_after_cooldown_and_success(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_AGENT_CIRCUIT_FAILURES", "2")
    monkeypatch.setenv("ALFA_AI_AGENT_CIRCUIT_OPEN_SEC", "1")
    attempts = {"n": 0}

    def recover_on_third(_messages, **kwargs):
        attempts["n"] += 1
        if attempts["n"] < 3:
            raise RuntimeError("down")
        return ChatTurn(content="recovered")

    monkeypatch.setattr(client, "get_completion_turn", recover_on_third)
    messages = [{"role": "user", "content": "hi"}]

    for _ in range(2):
        with pytest.raises(RuntimeError):
            client.get_agent_completion(messages)

    with pytest.raises(AgentCircuitOpenError):
        client.get_agent_completion(messages)

    time.sleep(1.1)

    assert client.get_agent_completion(messages) == "recovered"
    assert client.get_agent_completion(messages) == "recovered"


def test_check_agent_circuit_message_includes_retry_seconds(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("ALFA_AI_AGENT_CIRCUIT_FAILURES", "1")
    monkeypatch.setenv("ALFA_AI_AGENT_CIRCUIT_OPEN_SEC", "30")

    def fail(_messages, **kwargs):
        raise RuntimeError("down")

    monkeypatch.setattr(client, "get_completion_turn", fail)
    with pytest.raises(RuntimeError):
        client.get_agent_completion([{"role": "user", "content": "x"}])

    with pytest.raises(AgentCircuitOpenError, match=r"retry in \d+s"):
        agent_circuit.check_agent_circuit()
