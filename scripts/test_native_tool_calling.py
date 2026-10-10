#!/usr/bin/env python3
"""GATE-TC: native OpenAI tool calling through LiteLLM -> inference coordinator.

OpenCode and alfa-ai Phase 3 require the model to return structured tool_calls
(not JSON-in-text). Run only when the cluster pool and LiteLLM are up.

Usage (from orchestrator or any LAN host with pool up):
  set LITELLM_API_KEY=sk-...
  python scripts/test_native_tool_calling.py
  python scripts/test_native_tool_calling.py --base-url http://hub

Exit 0 only when both cases PASS.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

DEFAULT_BASE = "http://hub"
DEFAULT_MODEL = "frontier-code"
DEFAULT_TIMEOUT = 120.0

GET_WEATHER_TOOL: dict[str, Any] = {
    "type": "function",
    "function": {
        "name": "get_weather",
        "description": "Get current weather for a city.",
        "parameters": {
            "type": "object",
            "properties": {
                "city": {"type": "string", "description": "City name"},
            },
            "required": ["city"],
        },
    },
}


def _api_key(explicit: str | None) -> str:
    if explicit:
        return explicit
    for name in ("LITELLM_API_KEY", "LITELLM_MASTER_KEY"):
        val = os.environ.get(name, "").strip()
        if val:
            return val
    print("FAIL setup: set LITELLM_API_KEY or pass --api-key", file=sys.stderr)
    sys.exit(2)


def _post_chat(
    base_url: str,
    api_key: str,
    body: dict[str, Any],
    timeout: float,
) -> dict[str, Any]:
    url = f"{base_url.rstrip('/')}/v1/chat/completions"
    data = json.dumps(body).encode("utf-8")
    req = Request(
        url,
        data=data,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
    except HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")[:800]
        raise RuntimeError(f"HTTP {exc.code}: {detail}") from exc
    except URLError as exc:
        raise RuntimeError(f"request failed: {exc}") from exc
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"non-JSON response: {raw[:400]}") from exc


def _first_assistant_message(payload: dict[str, Any]) -> dict[str, Any]:
    choices = payload.get("choices")
    if not isinstance(choices, list) or not choices:
        raise ValueError("response missing choices[]")
    message = choices[0].get("message")
    if not isinstance(message, dict):
        raise ValueError("response missing choices[0].message")
    return message


def _validate_tool_call(message: dict[str, Any]) -> dict[str, Any]:
    tool_calls = message.get("tool_calls")
    if not isinstance(tool_calls, list) or not tool_calls:
        raise ValueError("assistant message has no tool_calls")
    tc = tool_calls[0]
    if not isinstance(tc, dict):
        raise ValueError("tool_calls[0] is not an object")
    call_id = tc.get("id")
    if not isinstance(call_id, str) or not call_id.strip():
        raise ValueError("tool_calls[0].id missing or empty")
    fn = tc.get("function")
    if not isinstance(fn, dict):
        raise ValueError("tool_calls[0].function missing")
    name = fn.get("name")
    if name != "get_weather":
        raise ValueError(f"expected function.name get_weather, got {name!r}")
    args_raw = fn.get("arguments")
    if not isinstance(args_raw, str):
        raise ValueError("function.arguments must be a JSON string")
    try:
        args = json.loads(args_raw)
    except json.JSONDecodeError as exc:
        raise ValueError(f"function.arguments not valid JSON: {args_raw!r}") from exc
    if not isinstance(args, dict) or "city" not in args:
        raise ValueError(f"arguments missing city key: {args!r}")
    return tc


def case1_tool_call(
    base_url: str,
    api_key: str,
    model: str,
    timeout: float,
) -> tuple[bool, str, dict[str, Any] | None]:
    """Model must emit one well-formed tool_calls entry."""
    body = {
        "model": model,
        "messages": [
            {
                "role": "user",
                "content": (
                    "What is the weather in Boston? "
                    "You must call the get_weather tool; do not guess."
                ),
            }
        ],
        "tools": [GET_WEATHER_TOOL],
        "tool_choice": "auto",
        "max_tokens": 256,
    }
    try:
        payload = _post_chat(base_url, api_key, body, timeout)
        message = _first_assistant_message(payload)
        tc = _validate_tool_call(message)
        city = json.loads(tc["function"]["arguments"]).get("city", "")
        return True, f"tool_call id={tc['id']!r} city={city!r}", message
    except (RuntimeError, ValueError, KeyError, TypeError) as exc:
        return False, str(exc), None


def case2_tool_result_followup(
    base_url: str,
    api_key: str,
    model: str,
    timeout: float,
    assistant_message: dict[str, Any],
) -> tuple[bool, str]:
    """After tool result, model must answer in plain text."""
    tool_calls = assistant_message.get("tool_calls") or []
    if not tool_calls:
        return False, "missing prior tool_calls for follow-up"
    call_id = tool_calls[0].get("id")
    if not call_id:
        return False, "missing tool call id for follow-up"

    body = {
        "model": model,
        "messages": [
            {
                "role": "user",
                "content": "What is the weather in Boston? Use get_weather.",
            },
            assistant_message,
            {
                "role": "tool",
                "tool_call_id": call_id,
                "content": json.dumps(
                    {"city": "Boston", "temp_f": 72, "conditions": "sunny"}
                ),
            },
        ],
        "tools": [GET_WEATHER_TOOL],
        "max_tokens": 128,
    }
    try:
        payload = _post_chat(base_url, api_key, body, timeout)
        message = _first_assistant_message(payload)
        content = message.get("content")
        if not isinstance(content, str) or not content.strip():
            if message.get("tool_calls"):
                return False, "model returned another tool_call instead of text"
            return False, "assistant content empty"
        if len(content.strip()) < 3:
            return False, f"assistant content too short: {content!r}"
        return True, f"text answer ({len(content)} chars): {content[:120]!r}..."
    except (RuntimeError, ValueError, KeyError, TypeError) as exc:
        return False, str(exc)


def main() -> int:
    parser = argparse.ArgumentParser(description="GATE-TC native tool calling smoke")
    parser.add_argument(
        "--base-url",
        default=os.environ.get("LITELLM_BASE_URL", DEFAULT_BASE),
        help=f"LiteLLM base URL (default {DEFAULT_BASE})",
    )
    parser.add_argument(
        "--api-key",
        default=None,
        help="Bearer token (else LITELLM_API_KEY or LITELLM_MASTER_KEY)",
    )
    parser.add_argument(
        "--model",
        default=os.environ.get("ALFA_AI_AGENT_MODEL", DEFAULT_MODEL),
        help=f"LiteLLM model alias (default {DEFAULT_MODEL})",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=float(os.environ.get("GATE_TC_TIMEOUT_SEC", DEFAULT_TIMEOUT)),
        help=f"HTTP timeout seconds (default {DEFAULT_TIMEOUT})",
    )
    args = parser.parse_args()
    api_key = _api_key(args.api_key)

    print(f"GATE-TC native tool calling  base={args.base_url}  model={args.model}")

    ok1, detail1, assistant_msg = case1_tool_call(
        args.base_url, api_key, args.model, args.timeout
    )
    print(f"case1 tool_call: {'PASS' if ok1 else 'FAIL'}  {detail1}")

    if not ok1 or assistant_msg is None:
        print("case2 follow-up: SKIP (case1 failed)")
        return 1

    ok2, detail2 = case2_tool_result_followup(
        args.base_url, api_key, args.model, args.timeout, assistant_msg
    )
    print(f"case2 follow-up: {'PASS' if ok2 else 'FAIL'}  {detail2}")

    if ok1 and ok2:
        print("GATE-TC: PASS (both cases)")
        return 0
    print("GATE-TC: FAIL")
    return 1


if __name__ == "__main__":
    sys.exit(main())
