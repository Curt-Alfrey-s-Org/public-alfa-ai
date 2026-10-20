"""Rate limits for incident auto-fix attempts."""

from __future__ import annotations

import os
import time

import redis


def _redis() -> redis.Redis:
    url = os.getenv("REDIS_URL", "redis://localhost:6379/0")
    return redis.Redis.from_url(url, decode_responses=True)


def auto_fix_rate_limit_ok(alertname: str) -> tuple[bool, str]:
    """Return (allowed, reason). Uses Redis counter per alertname per hour."""
    max_per_hour = max(1, int(os.getenv("ALFA_AI_INCIDENT_AUTO_FIX_MAX_PER_HOUR", "3") or "3"))
    key = f"alfaai:incident:autofix:{alertname}:{time.strftime('%Y%m%d%H')}"
    try:
        client = _redis()
        count = int(client.incr(key))
        if count == 1:
            client.expire(key, 3700)
        if count > max_per_hour:
            return False, f"auto-fix rate limit exceeded ({max_per_hour}/hour for {alertname})"
        return True, ""
    except Exception as exc:  # noqa: BLE001
        return False, f"rate limit check failed: {exc}"[:200]
