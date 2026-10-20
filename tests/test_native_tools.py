from __future__ import annotations

from src.agent.openai_tools import openai_tools_payload
from src.llm.client import ChatTurn, NativeToolCall


def test_openai_tools_payload_filters_allowlist() -> None:
    payload = openai_tools_payload(frozenset({"read_file", "grep_repo", "nope"}))
    names = {item["function"]["name"] for item in payload}
    assert names == {"read_file", "grep_repo"}
    for item in payload:
        assert item["type"] == "function"
        assert "parameters" in item["function"]


def test_chat_turn_native_call_shape() -> None:
    turn = ChatTurn(
        content="",
        tool_calls=[NativeToolCall(id="call_1", name="list_dir", arguments={"path": "."})],
    )
    assert turn.tool_calls[0].name == "list_dir"
    assert turn.tool_calls[0].arguments["path"] == "."
