"""Redis-backed pool switch status (27B inference <-> 35B pool35).

See docs/POOL_SWITCH_OPERATOR.md for schema and key names.
"""

from __future__ import annotations

import json
import logging
import os
from datetime import UTC, datetime
from typing import Any

logger = logging.getLogger(__name__)

_STATUS_KEY = "alfaai:pool_switch:status"
_STATUS_TTL_SEC = 3600

inference_COLD_START_SEC = 210
POOL35_COLD_START_SEC = 240

PHASE_DEFINITIONS: tuple[dict[str, str], ...] = (
    {"id": "stopping_current", "label": "Stopping current model"},
    {"id": "verifying_shards", "label": "Verifying GPU shards"},
    {"id": "switching_env", "label": "Updating configuration"},
    {"id": "starting_coordinator", "label": "Starting coordinator"},
    {"id": "loading_model", "label": "Loading model weights"},
    {"id": "recreating_litellm", "label": "Restarting inference proxy"},
    {"id": "ready", "label": "Ready"},
)

_PHASE_IDS: tuple[str, ...] = tuple(p["id"] for p in PHASE_DEFINITIONS)


def _redis_url() -> str | None:
    u = os.getenv("REDIS_URL", "").strip()
    return u or None


def _redis_client():
    import redis

    url = _redis_url()
    if not url:
        raise RuntimeError("REDIS_URL not configured")
    return redis.from_url(url, decode_responses=True)


def cold_start_estimate_sec(pool: str) -> int:
    if pool == "inference":
        return inference_COLD_START_SEC
    return POOL35_COLD_START_SEC


def _phase_index(phase_id: str) -> int:
    try:
        return _PHASE_IDS.index(phase_id)
    except ValueError:
        return -1


def _build_phases(current_phase: str, *, failed: bool = False) -> list[dict[str, Any]]:
    idx = _phase_index(current_phase)
    out: list[dict[str, Any]] = []
    for i, spec in enumerate(PHASE_DEFINITIONS):
        done = i < idx or (not failed and spec["id"] == "ready" and current_phase == "ready")
        if spec["id"] == current_phase and current_phase == "ready":
            done = True
        out.append(
            {
                "id": spec["id"],
                "label": spec["label"],
                "done": done,
            }
        )
    return out


def compute_estimated_pct(*, phase: str, elapsed_sec: int, target_pool: str) -> tuple[int, bool]:
    """Return (estimated_pct, estimated_label)."""
    if phase == "ready":
        return 100, True
    if phase == "failed":
        return 0, False
    if phase != "loading_model":
        idx = max(0, _phase_index(phase))
        # Rough step progress before loading (loading dominates time).
        return min(40, idx * 8), True
    est = cold_start_estimate_sec(target_pool)
    if est <= 0:
        return 0, True
    pct = min(95, round(100 * elapsed_sec / est))
    return pct, True


def idle_status(*, active_pool: str | None = None) -> dict[str, Any]:
    phases = [{**spec, "done": False} for spec in PHASE_DEFINITIONS]
    return {
        "switching": False,
        "active_pool": active_pool,
        "target_pool": None,
        "from_pool": None,
        "phase": "idle",
        "phases": phases,
        "elapsed_sec": 0,
        "estimated_pct": 0,
        "estimated_label": False,
        "cold_start_estimate_sec": 0,
        "error": None,
    }


def normalize_status(raw: dict[str, Any] | None, *, active_pool: str | None = None) -> dict[str, Any]:
    if not raw:
        return idle_status(active_pool=active_pool)
    phase = str(raw.get("phase") or "idle")
    target = raw.get("target_pool")
    elapsed = int(raw.get("elapsed_sec") or 0)
    est_pct, est_label = compute_estimated_pct(
        phase=phase,
        elapsed_sec=elapsed,
        target_pool=str(target or "pool35"),
    )
    if raw.get("estimated_pct") is not None and phase == "loading_model":
        est_pct = int(raw["estimated_pct"])
    return {
        "switching": bool(raw.get("switching")),
        "active_pool": raw.get("active_pool") or active_pool,
        "target_pool": raw.get("target_pool"),
        "from_pool": raw.get("from_pool"),
        "phase": phase,
        "phases": raw.get("phases") or _build_phases(phase, failed=(phase == "failed")),
        "elapsed_sec": elapsed,
        "estimated_pct": est_pct,
        "estimated_label": bool(raw.get("estimated_label", est_label)),
        "cold_start_estimate_sec": int(
            raw.get("cold_start_estimate_sec") or cold_start_estimate_sec(str(target or "pool35"))
        ),
        "error": raw.get("error"),
        "requested_by_user_id": raw.get("requested_by_user_id"),
        "started_at": raw.get("started_at"),
        "updated_at": raw.get("updated_at"),
    }


def get_pool_switch_status() -> dict[str, Any] | None:
    try:
        r = _redis_client()
        raw = r.get(_STATUS_KEY)
        if not raw:
            return None
        return json.loads(raw)
    except Exception:
        logger.exception("redis_pool_switch: read status")
        return None


def store_pool_switch_status(payload: dict[str, Any]) -> dict[str, Any]:
    r = _redis_client()
    now = datetime.now(tz=UTC).isoformat()
    payload = dict(payload)
    payload.setdefault("updated_at", now)
    r.setex(_STATUS_KEY, _STATUS_TTL_SEC, json.dumps(payload))
    return payload


def clear_pool_switch_status() -> None:
    try:
        r = _redis_client()
        r.delete(_STATUS_KEY)
    except Exception:
        logger.exception("redis_pool_switch: clear status")


def begin_pool_switch(
    *,
    target_pool: str,
    from_pool: str,
    requested_by_user_id: str,
) -> dict[str, Any]:
    now = datetime.now(tz=UTC).isoformat()
    payload: dict[str, Any] = {
        "switching": True,
        "target_pool": target_pool,
        "from_pool": from_pool,
        "active_pool": from_pool,
        "phase": "stopping_current",
        "phases": _build_phases("stopping_current"),
        "elapsed_sec": 0,
        "estimated_pct": 0,
        "estimated_label": True,
        "cold_start_estimate_sec": cold_start_estimate_sec(target_pool),
        "error": None,
        "requested_by_user_id": requested_by_user_id,
        "started_at": now,
        "updated_at": now,
    }
    return store_pool_switch_status(payload)


def update_pool_switch_phase(
    *,
    phase: str,
    elapsed_sec: int | None = None,
    error: str | None = None,
    switching: bool | None = None,
    active_pool: str | None = None,
) -> dict[str, Any]:
    current = get_pool_switch_status() or {}
    target = str(current.get("target_pool") or "pool35")
    elapsed = elapsed_sec if elapsed_sec is not None else int(current.get("elapsed_sec") or 0)
    failed = phase == "failed" or error is not None
    est_pct, est_label = compute_estimated_pct(
        phase=phase,
        elapsed_sec=elapsed,
        target_pool=target,
    )
    payload: dict[str, Any] = {
        **current,
        "phase": phase,
        "phases": _build_phases(phase, failed=failed),
        "elapsed_sec": elapsed,
        "estimated_pct": est_pct,
        "estimated_label": est_label,
        "error": error,
        "updated_at": datetime.now(tz=UTC).isoformat(),
    }
    if switching is not None:
        payload["switching"] = switching
    if active_pool is not None:
        payload["active_pool"] = active_pool
    if phase == "ready":
        payload["switching"] = False
        payload["active_pool"] = target
        payload["estimated_pct"] = 100
    if phase == "failed":
        payload["switching"] = False
    return store_pool_switch_status(payload)
