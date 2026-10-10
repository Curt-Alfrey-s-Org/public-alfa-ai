"""Detect active RPC pool and map chat aliases to pool targets."""

from __future__ import annotations

import os

from src.api.llm_config import (
    _FRONTIER_CODE_ALIASES,
    _SPEED_TIER_ALIASES,
    inference_mode,
)

inference = "inference"
POOL35 = "pool35"
POOL72 = "pool72"
POOL80 = "pool80"

SWITCHABLE_POOLS: frozenset[str] = frozenset({inference, POOL35})


def chat_alias_pool(alias: str) -> str | None:
    cleaned = (alias or "").strip()
    if cleaned in _FRONTIER_CODE_ALIASES:
        return inference
    if cleaned in _SPEED_TIER_ALIASES:
        return POOL35
    return None


def detect_active_pool() -> str | None:
    """Infer which coordinator pool is configured on this brain host."""
    mode = inference_mode()
    if mode == "inference":
        return inference
    if mode == "pool72":
        return POOL72
    if mode == "pool80":
        return POOL80
    litellm_cfg = (os.getenv("LITELLM_CONFIG") or "").strip().lower()
    if "pool80" in litellm_cfg:
        return POOL80
    if "pool72" in litellm_cfg:
        return POOL72
    code27 = (os.getenv("LLAMACPP_CODE27_URL") or "").strip()
    speed35 = (os.getenv("LLAMACPP_35B_URL") or "").strip()
    if ":31399" in code27:
        return POOL35
    if ":31360" in speed35 and "127.0.0.1" in speed35:
        return POOL35
    if ":31360" in code27 and "127.0.0.1" in code27:
        return inference
    return None


def opposite_pool(pool: str) -> str:
    if pool == inference:
        return POOL35
    return inference
