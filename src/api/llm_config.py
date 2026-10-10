"""Shared LiteLLM (OpenAI-compatible) HTTP settings for chat, guest, and operator routes."""

from __future__ import annotations

import logging
import os
from typing import Literal

logger = logging.getLogger(__name__)

# Hub archive / pre-Phase-G aliases — never routable as production defaults.
RETIRED_CHAT_ALIASES: frozenset[str] = frozenset({
    "qwen3.6:35b-a3b",  # 35B MoE retired 2026-07-10; revive via switch-pool-35b.sh only
    "qwen3.5:27b",
    "qwen3:32b",
    "qwen3:4b",
    "qwen3:8b",
    "qwen3-coder:30b-a3b-q4_K_M",
    "llama3.3-70b-instruct",
})

# Phase H production picker (SSoT: deploy/litellm_config.yaml + FOUR_HOST_FRONTIER_POOL.md).
# fast/chat remain as compat aliases; LiteLLM routes them to the 27B pool.
_DEFAULT_PICKER_ALIASES: tuple[str, ...] = (
    "frontier-code",
    "frontier",
    "fast",
    "chat",
)

# Former 35B speed-tier alias names (now routed to 27B in litellm_config.yaml).
# Empty set: active-check + pool tagging use _FRONTIER_CODE_ALIASES instead.
_SPEED_TIER_ALIASES: frozenset[str] = frozenset()

_FRONTIER_CODE_ALIASES: frozenset[str] = frozenset({
    "frontier",
    "frontier-code",
    "qwen3.6-27b",
    # Compat aliases formerly on 35B MoE — same 27B backend after 2026-07-10:
    "fast",
    "inline",
    "autocomplete",
    "chat",
    "agent",
    "code",
    "public-chat",
    "app-chat",
})


def inference_mode() -> str:
    """Cluster inference mode: inference, pool72, pool80, or default (legacy / other)."""
    raw = (os.getenv("ALFA_INFERENCE_MODE") or "inference").strip().lower()
    if raw in ("inference", "27b", "grev27"):
        return "inference"
    if raw in ("pool72", "72b", "grev72"):
        return "pool72"
    if raw in ("pool80", "80b", "grev80", "coder-next"):
        return "pool80"
    return "default"


def is_inference_mode() -> bool:
    return inference_mode() == "inference"


def is_pool72_mode() -> bool:
    return inference_mode() == "pool72"


def is_pool80_mode() -> bool:
    return inference_mode() == "pool80"


def litellm_base_url() -> str:
    return os.getenv("LITELLM_BASE_URL", "http://127.0.0.1:8413").rstrip("/")


def litellm_bearer_key() -> str:
    return (os.getenv("LITELLM_API_KEY") or os.getenv("LITELLM_MASTER_KEY") or "").strip()


def litellm_timeout_seconds(*, default: str) -> float:
    return float((os.getenv("LITELLM_TIMEOUT") or default).strip() or default)


# Committed production default (SSoT with deploy/model_config_manifest.json).
# Env DEFAULT_MODEL may override at runtime; audits compare this constant, not the env.
PRODUCTION_DEFAULT_ALIAS = "frontier-code"


def _production_default_alias() -> str:
    raw = (os.getenv("DEFAULT_MODEL") or PRODUCTION_DEFAULT_ALIAS).strip() or PRODUCTION_DEFAULT_ALIAS
    if is_retired_chat_alias(raw):
        return PRODUCTION_DEFAULT_ALIAS
    return raw


def default_model_name() -> str:
    return _production_default_alias()


def is_retired_chat_alias(alias: str) -> bool:
    return (alias or "").strip().lower() in RETIRED_CHAT_ALIASES


def sanitize_chat_model_alias(alias: str | None) -> str:
    """Map retired / empty aliases to the current production default."""
    cleaned = (alias or "").strip()
    if not cleaned or is_retired_chat_alias(cleaned):
        if cleaned and is_retired_chat_alias(cleaned):
            logger.info("chat model alias %r is retired; using production default", cleaned)
        return _production_default_alias()
    return cleaned


# LiteLLM alias -> picker label (user-facing; no host topology).
# inference 27B phrase is swapped via allowlisted ALFA_inference_FAMILY (qwen36/qwen38).
# CHAT_MODELS "alias|label" pipes are parsed for ids only -- not shown (public surface).
_CHAT_MODEL_LABELS: dict[str, str] = {
    "frontier": "Frontier - Qwen3.8 27B",
    "frontier-code": "Frontier code - Qwen3.8 27B",
    "qwen3.6-27b": "Code - Qwen3.8 27B",
    "fast": "Fast - Qwen3.8 27B",
    "inline": "Inline - Qwen3.8 27B",
    "autocomplete": "Autocomplete - Qwen3.8 27B",
    "chat": "Quality - Qwen3.8 27B",
    "agent": "Agent - Qwen3.8 27B",
    "code": "Code - Qwen3.8 27B",
    "public-chat": "Public chat - Qwen3.8 27B",
    "app-chat": "App chat - Qwen3.8 27B",
    "qwen3.5-122b-a10b": "Future frontier - Qwen3.5-122B-A10B MoE",
    "qwen3-coder-next-80b-a3b": "Frontier code (80B) - Qwen3-Coder-Next 80B-A3B",
    "alfa-coder-draft": "Draft coder (homelab) — not production default",
}

_inference_FAMILY_DISPLAY: dict[str, str] = {
    "qwen36": "Qwen3.6 27B",
    "qwen38": "Qwen3.8 27B",
}


def inference_family_display() -> str:
    """Allowlisted 27B picker phrase. Unknown values fall back to Qwen3.8 27B."""
    raw = (os.getenv("ALFA_inference_FAMILY") or "qwen38").strip().lower()
    return _inference_FAMILY_DISPLAY.get(raw, _inference_FAMILY_DISPLAY["qwen38"])


def chat_model_display_label(alias: str, custom_label: str | None = None) -> str:
    if custom_label:
        return custom_label
    label = _CHAT_MODEL_LABELS.get(alias, alias)
    if is_inference_mode() and inference_family_display() == "Qwen3.6 27B":
        label = label.replace("Qwen3.8 27B", "Qwen3.6 27B")
    return label


def _chat_model_aliases_from_env() -> list[tuple[str, str | None]]:
    """Parse CHAT_MODELS: comma-separated LiteLLM alias (optional alias|label ignored for UI)."""
    raw = (os.getenv("CHAT_MODELS") or "").strip()
    if not raw:
        return []
    out: list[tuple[str, str | None]] = []
    for part in raw.split(","):
        part = part.strip()
        if not part:
            continue
        if "|" in part:
            alias, label = part.split("|", 1)
            alias = alias.strip()
            label = label.strip() or None
        else:
            alias = part
            label = None
        if not alias or is_retired_chat_alias(alias):
            if alias:
                logger.warning("CHAT_MODELS skips retired alias %r", alias)
            continue
        out.append((alias, label))
    return out


def chat_model_aliases() -> list[str]:
    """LiteLLM alias ids exposed in the web chat model picker."""
    env_entries = _chat_model_aliases_from_env()
    if env_entries:
        return [alias for alias, _ in env_entries]
    seen: set[str] = set()
    models: list[str] = []
    for alias in _DEFAULT_PICKER_ALIASES:
        if alias not in seen:
            models.append(alias)
            seen.add(alias)
    return models


def chat_alias_is_active(alias: str) -> bool:
    """
    Whether the alias's primary inference backend is reachable right now.
    Used to grey out unavailable rows in the chat model picker.
    """
    cleaned = (alias or "").strip()
    if not cleaned or is_retired_chat_alias(cleaned):
        return False

    if is_inference_mode() or is_pool72_mode() or is_pool80_mode():
        if cleaned in _FRONTIER_CODE_ALIASES:
            try:
                from src.api.worker_monitoring import check_frontier_coordinator
            except Exception:
                logger.exception("chat_alias_is_active: pool imports failed")
                return False
            coord = check_frontier_coordinator()
            # Coordinator /health is the live gate for the chat picker. Do not TCP-probe
            # shard RPC ports from the brain container while the pool may be serving (B42:
            # rpc-server is single-client; probes false-negative from bridge/LAN).
            return bool(coord.get("ok"))
        return False

    try:
        from src.api.worker_monitoring import (
            check_frontier_coordinator,
        )
    except Exception:
        logger.exception("chat_alias_is_active: worker_monitoring import failed")
        return False

    if cleaned in _FRONTIER_CODE_ALIASES:
        return bool(check_frontier_coordinator().get("ok"))

    # Former speed-tier aliases remap to 27B in LiteLLM; do not require 35B probe.
    if cleaned in _SPEED_TIER_ALIASES:
        return bool(check_frontier_coordinator().get("ok"))

    return True


def chat_models_for_ui() -> list[dict[str, str | bool]]:
    """Picker rows: {id, label, qwen_mode_supported, active, pool?} for /chat model select."""
    from src.api.pool_targets import chat_alias_pool
    from src.api.qwen_mode import is_qwen_hybrid_model

    def row(alias: str) -> dict[str, str | bool]:
        pool = chat_alias_pool(alias)
        out: dict[str, str | bool] = {
            "id": alias,
            "label": chat_model_display_label(alias),
            "qwen_mode_supported": is_qwen_hybrid_model(alias),
            "active": chat_alias_is_active(alias),
        }
        if pool:
            out["pool"] = pool
        return out

    return [row(alias) for alias in chat_model_aliases()]


def llm_tuple(
    *,
    role: Literal["chat", "guest", "operator"],
    model_override: str | None = None,
) -> tuple[str, str, str, float]:
    """Returns (base_url, api_key, model, timeout_seconds)."""
    base = litellm_base_url()
    key = litellm_bearer_key()
    prod_default = default_model_name()
    if role == "guest":
        model = (
            sanitize_chat_model_alias(model_override)
            if (model_override or "").strip()
            else sanitize_chat_model_alias(os.getenv("GUEST_CHAT_MODEL", "").strip())
            if (os.getenv("GUEST_CHAT_MODEL") or "").strip()
            else prod_default
        )
        timeout = litellm_timeout_seconds(default="120")
    elif role == "operator":
        model = (
            sanitize_chat_model_alias(model_override)
            if (model_override or "").strip()
            else sanitize_chat_model_alias(os.getenv("OPERATOR_CHAT_MODEL", "").strip())
            if (os.getenv("OPERATOR_CHAT_MODEL") or "").strip()
            else prod_default
        )
        timeout = litellm_timeout_seconds(default="600")
    else:
        model = (
            sanitize_chat_model_alias(model_override)
            if (model_override or "").strip()
            else prod_default
        )
        timeout = litellm_timeout_seconds(default="600")
    return base, key, model, timeout
