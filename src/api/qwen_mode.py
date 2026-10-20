"""Qwen hybrid thinking (precise) vs instruct mode for LiteLLM upstream payloads."""

from __future__ import annotations

import os
import re
from typing import Any, Literal

QwenChatMode = Literal["precise", "instruct"]

# Reasoning models in "precise" mode emit raw <think>...</think> blocks in message
# content. Strip before persisting chat history; live streaming display is handled
# client-side (frontend/src/lib/thinkTags.ts) so the UI can show a "thinking" indicator
# instead of the raw tag while it streams in.
_THINK_TAG_RE = re.compile(r"<think>.*?</think>", re.IGNORECASE | re.DOTALL)

# Aliases where capped thinking (precise) is the default when no override is set.
_PRECISE_DEFAULT_ALIASES: frozenset[str] = frozenset(
    {
        "frontier-code",
        "qwen3.6-27b",
        "agent",
        "code",
    }
)


def _thinking_budget() -> int:
    raw = (os.getenv("QWEN_THINKING_BUDGET") or "8192").strip()
    try:
        value = int(raw)
    except ValueError:
        value = 8192
    return max(256, value)


def is_qwen_hybrid_model(model: str) -> bool:
    """True when the LiteLLM alias likely supports enable_thinking / think toggle."""
    name = (model or "").strip().lower()
    if not name:
        return False
    if name.startswith("llama3"):
        return False
    if "embed" in name or name == "rerank":
        return False
    return "qwen" in name or name in {"frontier", "frontier-code", "chat", "agent", "code", "fast", "inline", "autocomplete", "public-chat", "app-chat"}


def resolve_qwen_chat_mode(model: str, override: str | None = None) -> QwenChatMode | None:
    """Pick precise (thinking) or instruct (non-thinking) for a model alias."""
    if not is_qwen_hybrid_model(model):
        return None
    if override:
        mode = override.strip().lower()
        if mode in ("precise", "instruct"):
            return mode  # type: ignore[return-value]
    env_mode = (os.getenv("ALFA_QWEN_CHAT_MODE") or "").strip().lower()
    if env_mode in ("precise", "instruct"):
        return env_mode  # type: ignore[return-value]
    alias = (model or "").strip().lower()
    if alias in _PRECISE_DEFAULT_ALIASES:
        return "precise"
    return "instruct"


def litellm_extra_body_for_model(model: str, mode_override: str | None = None) -> dict[str, Any]:
    """
    Build extra_body for LiteLLM /v1/chat/completions.

    - precise: enable_thinking + thinking_budget (Qwen hybrid / llama.cpp / vLLM)
    - instruct: enable_thinking false (direct answer, max IFEval-style adherence)
    """
    mode = resolve_qwen_chat_mode(model, mode_override)
    if mode is None:
        return {}

    enable_thinking = mode == "precise"
    chat_template_kwargs: dict[str, Any] = {"enable_thinking": enable_thinking}
    if enable_thinking:
        chat_template_kwargs["thinking_budget"] = _thinking_budget()

    # Ollama OpenAI-compat: top-level think (not inside options).
    return {
        "think": enable_thinking,
        "chat_template_kwargs": chat_template_kwargs,
    }


def apply_qwen_mode_to_payload(
    payload: dict[str, Any],
    model: str,
    mode_override: str | None = None,
) -> dict[str, Any]:
    """Merge thinking/instruct extra_body into an outbound LiteLLM payload."""
    extra = litellm_extra_body_for_model(model, mode_override)
    if not extra:
        return payload
    merged = dict(payload)
    existing = merged.get("extra_body")
    if isinstance(existing, dict):
        merged_extra = {**existing, **extra}
        existing_kwargs = existing.get("chat_template_kwargs")
        new_kwargs = extra.get("chat_template_kwargs")
        if isinstance(existing_kwargs, dict) and isinstance(new_kwargs, dict):
            merged_extra["chat_template_kwargs"] = {**existing_kwargs, **new_kwargs}
        merged["extra_body"] = merged_extra
    else:
        merged["extra_body"] = extra
    return merged


def strip_think_tags(text: str) -> str:
    """Remove <think>...</think> reasoning blocks before persisting chat history."""
    if not text:
        return text
    return _THINK_TAG_RE.sub("", text).strip()


def thinking_phrases_from_setting(raw: str) -> list[str]:
    """Split the admin-editable 'chat_thinking_label' setting into cycle phrases.

    Pipe-separated so it fits the existing single-line Settings tab input. Empty/blank
    setting means "show nothing" while the model is thinking (operator opt-out).
    """
    if not raw:
        return []
    return [p.strip() for p in raw.split("|") if p.strip()]


def qwen_modes_for_ui() -> list[dict[str, str]]:
    """Picker rows for the web UI mode dropdown."""
    return [
        {"id": "instruct", "label": "Instruct (direct answer)"},
        {"id": "precise", "label": "Thinking (precise)"},
    ]


def default_qwen_mode_for_model(model: str) -> str:
    """Default mode id for UI when the user has not chosen one."""
    resolved = resolve_qwen_chat_mode(model)
    return resolved or "instruct"
