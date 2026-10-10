"""Redis keys for worker heartbeats (out-of-band reachability from worker to brain)."""

from __future__ import annotations

import json
import logging
import os
from datetime import UTC, datetime
from typing import Any

logger = logging.getLogger(__name__)

_KEY_PREFIX = "alfaai:worker:hb:"


def _redis_url() -> str | None:
    u = os.getenv("REDIS_URL", "").strip()
    return u or None


def heartbeat_key(worker_name: str) -> str:
    return f"{_KEY_PREFIX}{worker_name}"


def store_worker_heartbeat(worker_name: str, role: str, ttl_sec: int, extra: dict[str, Any] | None = None) -> None:
    import redis

    url = _redis_url()
    if not url:
        raise RuntimeError("REDIS_URL not configured")
    r = redis.from_url(url, decode_responses=True)
    display_name = worker_name.strip()
    key_suffix = display_name.casefold()
    if not key_suffix:
        raise ValueError("worker_name is empty")
    payload = {
        "worker_name": display_name,
        "role": role,
        "received_at": datetime.now(tz=UTC).isoformat(),
    }
    if extra:
        payload["extra"] = extra
    r.setex(heartbeat_key(key_suffix), ttl_sec, json.dumps(payload))


def _get_heartbeat_raw_case_insensitive(r: Any, worker_name: str) -> str | None:
    """Match Redis key when Admin registry name and WORKER_NAME differ only by case/whitespace."""
    target = worker_name.strip().casefold()
    if not target:
        return None
    try:
        for key in r.scan_iter(match=f"{_KEY_PREFIX}*", count=256):
            suffix = key.removeprefix(_KEY_PREFIX)
            if suffix.casefold() == target:
                return r.get(key)
    except Exception:
        logger.exception("Redis scan heartbeats for %s", worker_name)
    return None


def get_worker_heartbeat(worker_name: str) -> dict[str, Any] | None:
    import redis

    url = _redis_url()
    if not url:
        return None
    try:
        r = redis.from_url(url, decode_responses=True)
        wn = worker_name.strip()
        raw = r.get(heartbeat_key(wn.casefold()))
        if not raw:
            raw = r.get(heartbeat_key(wn))
        if not raw:
            raw = _get_heartbeat_raw_case_insensitive(r, wn)
        if not raw:
            return None
        return json.loads(raw)
    except Exception:
        logger.exception("Redis read heartbeat for %s", worker_name)
        return None
