from __future__ import annotations

import json
import logging
from dataclasses import dataclass, field
from typing import Any

import httpx
from openai import APIConnectionError, APIStatusError, APITimeoutError, OpenAI

from src.api.llm_config import default_model_name, sanitize_chat_model_alias
from src.config import (
    agent_fallback_model,
    agent_model,
    agent_synthesis_max_tokens,
    get,
)
from src.llm.agent_circuit import (
    check_agent_circuit,
    record_agent_failure,
    record_agent_success,
)

logger = logging.getLogger(__name__)


class LLMRetryableError(Exception):
    """LiteLLM/upstream failure that may succeed on fallback model."""


@dataclass(slots=True)
class NativeToolCall:
    id: str
    name: str
    arguments: dict[str, Any]


@dataclass(slots=True)
class ChatTurn:
    content: str
    tool_calls: list[NativeToolCall] = field(default_factory=list)
    # LiteLLM / OpenAI usage when provider returns it:
    # https://docs.litellm.ai/docs/completion/usage
    usage: dict[str, int] | None = None
    # OpenAI Chat Completions `model` (LiteLLM may echo the served group after fallback):
    # https://platform.openai.com/docs/api-reference/chat/object
    # https://docs.litellm.ai/docs/proxy/reliability
    model: str = ""


def _resolved_default_model() -> str:
    """Cluster DEFAULT_MODEL with retired-alias guard."""
    return sanitize_chat_model_alias(get("DEFAULT_MODEL", "") or default_model_name())


def agent_json_mode_enabled() -> bool:
    """When true, Ask ALFa agent turns send OpenAI json_object mode via LiteLLM."""
    raw = get("ALFA_AI_AGENT_JSON_MODE", "1").strip().lower()
    return raw not in ("0", "false", "no", "off")


def agent_synthesis_response_format() -> dict[str, str] | None:
    """JSON mode for Ask ALFa synthesis turns without native tools.

    Default path: JSON-in-text tool protocol on every turn. When
    ``ALFA_AI_NATIVE_TOOLS=1``, tool turns send OpenAI ``tools`` (no json_object);
    the final synthesis turn may still use json_object without tools.
    https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md
    """
    if not agent_json_mode_enabled():
        return None
    return {"type": "json_object"}


def _choose_provider() -> str:
    configured = get("ALFA_AI_PROVIDER", "").strip().lower()
    if configured in {"openai", "anthropic", "ollama", "litellm"}:
        return configured
    if get("LITELLM_BASE_URL", "").strip():
        return "litellm"
    if get("OPENAI_API_KEY", "").strip():
        return "openai"
    if get("ANTHROPIC_API_KEY", "").strip():
        return "anthropic"
    return "ollama"


def _is_retryable_openai_error(exc: Exception) -> bool:
    if isinstance(exc, (APITimeoutError, APIConnectionError)):
        return True
    if isinstance(exc, APIStatusError):
        return exc.status_code >= 500
    return False


def _is_unsupported_response_format_error(exc: Exception) -> bool:
    if not isinstance(exc, APIStatusError):
        return False
    if exc.status_code != 400:
        return False
    message = str(exc).lower()
    return "response_format" in message


def _openai_completion(messages: list[dict[str, str]], model: str | None = None) -> str:
    client = OpenAI(api_key=get("OPENAI_API_KEY"))
    resolved = model or get("DEFAULT_MODEL", "gpt-4o-mini")
    response = client.chat.completions.create(
        model=resolved,
        messages=messages,  # type: ignore[arg-type]
    )
    content = response.choices[0].message.content
    return content or ""


def _anthropic_completion(messages: list[dict[str, str]], model: str | None = None) -> str:
    api_key = get("ANTHROPIC_API_KEY")
    resolved = model or get("DEFAULT_MODEL", "claude-3-5-haiku-latest")
    system_parts = [m["content"] for m in messages if m["role"] == "system"]
    conversation = [
        {"role": m["role"], "content": m["content"]}
        for m in messages
        if m["role"] in {"user", "assistant"}
    ]
    payload: dict[str, Any] = {
        "model": resolved,
        "max_tokens": 1024,
        "messages": conversation,
    }
    if system_parts:
        payload["system"] = "\n".join(system_parts)

    with httpx.Client(timeout=30) as client:
        response = client.post(
            "https://api.anthropic.com/v1/messages",
            headers={
                "x-api-key": api_key,
                "anthropic-version": "2023-06-01",
                "content-type": "application/json",
            },
            json=payload,
        )
        response.raise_for_status()
        data = response.json()
    content = data.get("content", [])
    if content and isinstance(content, list):
        first = content[0]
        if isinstance(first, dict):
            return str(first.get("text", ""))
    return ""


def _ollama_completion(messages: list[dict[str, str]], model: str | None = None) -> str:
    endpoint = get("OLLAMA_BASE_URL", "http://localhost:11434").rstrip("/")
    resolved = sanitize_chat_model_alias(model) if model else _resolved_default_model()
    with httpx.Client(timeout=60) as client:
        response = client.post(
            f"{endpoint}/api/chat",
            json={"model": resolved, "messages": messages, "stream": False},
        )
        response.raise_for_status()
        data = response.json()
    message = data.get("message", {})
    if isinstance(message, dict):
        return str(message.get("content", ""))
    return json.dumps(data, ensure_ascii=True)


def _litellm_completion(
    messages: list[dict[str, Any]],
    *,
    model: str | None = None,
    max_tokens: int | None = None,
    tools: list[dict[str, Any]] | None = None,
    response_format: dict[str, Any] | None = None,
) -> ChatTurn:
    """Route through LiteLLM proxy (OpenAI-compatible API).

    `tools` / `tool_calls`: https://platform.openai.com/docs/guides/function-calling
    LiteLLM: https://docs.litellm.ai/docs/completion/function_call
    JSON mode: https://docs.litellm.ai/docs/completion/json_mode
    """
    base_url = get("LITELLM_BASE_URL", "http://127.0.0.1:8413").rstrip("/")
    api_key = get("LITELLM_API_KEY", "").strip()
    if not api_key:
        raise ValueError(
            "LITELLM_API_KEY is required (no shared dev default; audit D-003 / LiteLLM prod keys)"
        )
    resolved = sanitize_chat_model_alias(model) if model else _resolved_default_model()
    token_cap = max_tokens if max_tokens is not None else agent_synthesis_max_tokens()

    client = OpenAI(base_url=f"{base_url}/v1", api_key=api_key)
    create_kwargs: dict[str, Any] = {
        "model": resolved,
        "messages": messages,
        "max_tokens": token_cap,
        "timeout": 600,
    }
    if tools:
        create_kwargs["tools"] = tools
        create_kwargs["tool_choice"] = "auto"
    elif response_format is not None:
        create_kwargs["response_format"] = response_format

    def _create(kwargs: dict[str, Any]):
        return client.chat.completions.create(**kwargs)

    try:
        response = _create(create_kwargs)
    except Exception as exc:
        if (
            response_format is not None
            and not tools
            and _is_unsupported_response_format_error(exc)
        ):
            logger.warning(
                "LiteLLM rejected response_format; retrying once without it: %s",
                exc,
            )
            retry_kwargs = dict(create_kwargs)
            retry_kwargs.pop("response_format", None)
            try:
                response = _create(retry_kwargs)
            except Exception as retry_exc:
                if _is_retryable_openai_error(retry_exc):
                    raise LLMRetryableError(str(retry_exc)) from retry_exc
                raise
        elif _is_retryable_openai_error(exc):
            raise LLMRetryableError(str(exc)) from exc
        else:
            raise
    message = response.choices[0].message
    usage: dict[str, int] | None = None
    response_usage = getattr(response, "usage", None)
    if isinstance(response_usage, dict):
        prompt_tokens = response_usage.get("prompt_tokens")
        completion_tokens = response_usage.get("completion_tokens")
        total_tokens = response_usage.get("total_tokens")
    elif response_usage is not None:
        prompt_tokens = getattr(response_usage, "prompt_tokens", None)
        completion_tokens = getattr(response_usage, "completion_tokens", None)
        total_tokens = getattr(response_usage, "total_tokens", None)
    else:
        prompt_tokens = completion_tokens = total_tokens = None
    if prompt_tokens is not None:
        usage = {
            "prompt_tokens": int(prompt_tokens),
            "completion_tokens": int(completion_tokens or 0),
            "total_tokens": int(total_tokens or 0),
        }
    calls: list[NativeToolCall] = []
    for item in message.tool_calls or []:
        fn = getattr(item, "function", None)
        if fn is None:
            continue
        raw_args = getattr(fn, "arguments", "") or "{}"
        try:
            parsed = json.loads(raw_args)
        except json.JSONDecodeError:
            parsed = {}
        if not isinstance(parsed, dict):
            parsed = {}
        calls.append(
            NativeToolCall(
                id=str(getattr(item, "id", "") or ""),
                name=str(getattr(fn, "name", "") or ""),
                arguments=parsed,
            )
        )
    served = str(getattr(response, "model", "") or "")
    return ChatTurn(
        content=message.content or "",
        tool_calls=calls,
        usage=usage,
        model=served,
    )


def get_completion_turn(
    messages: list[dict[str, Any]],
    *,
    model: str | None = None,
    fallback_model: str | None = None,
    max_tokens: int | None = None,
    tools: list[dict[str, Any]] | None = None,
    response_format: dict[str, Any] | None = None,
) -> ChatTurn:
    provider = _choose_provider()
    effective = model
    fb = fallback_model

    def _call(chosen_model: str | None) -> ChatTurn:
        if provider == "openai":
            return ChatTurn(content=_openai_completion(messages, model=chosen_model))
        if provider == "anthropic":
            return ChatTurn(content=_anthropic_completion(messages, model=chosen_model))
        if provider == "litellm":
            return _litellm_completion(
                messages,
                model=chosen_model,
                max_tokens=max_tokens,
                tools=tools,
                response_format=response_format,
            )
        return ChatTurn(content=_ollama_completion(messages, model=chosen_model))

    try:
        return _call(effective)
    except LLMRetryableError:
        if fb and fb != effective:
            return _call(fb)
        raise


def get_completion(
    messages: list[dict[str, Any]],
    *,
    model: str | None = None,
    fallback_model: str | None = None,
    max_tokens: int | None = None,
    response_format: dict[str, Any] | None = None,
) -> str:
    return get_completion_turn(
        messages,
        model=model,
        fallback_model=fallback_model,
        max_tokens=max_tokens,
        response_format=response_format,
    ).content


def get_agent_completion_turn(
    messages: list[dict[str, Any]],
    *,
    tools: list[dict[str, Any]] | None = None,
    response_format: dict[str, Any] | None = None,
) -> ChatTurn:
    """Agent loop turn with optional OpenAI tools (circuit breaker)."""
    check_agent_circuit()
    try:
        result = get_completion_turn(
            messages,
            model=agent_model(),
            fallback_model=agent_fallback_model(),
            max_tokens=agent_synthesis_max_tokens(),
            tools=tools,
            response_format=response_format,
        )
    except Exception:
        record_agent_failure()
        raise
    record_agent_success()
    return result


def get_agent_completion(
    messages: list[dict[str, Any]],
    *,
    response_format: dict[str, Any] | None = None,
) -> str:
    """Agent loop: 27B-primary with configured fallback and circuit breaker."""
    return get_agent_completion_turn(
        messages,
        response_format=response_format,
    ).content
