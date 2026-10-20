"""Shared guest-chat rate limit (Redis preferred, in-process fallback).

Audit D-011: multi-worker process-local maps multiply guest quota; Redis gives
one counter per client key across replicas. Falls back to memory if REDIS_URL
is unset or Redis is unreachable (dev / DB-less).
"""

from __future__ import annotations

import logging
import os
import time
import uuid
from typing import Callable

import redis
from fastapi import HTTPException

logger = logging.getLogger(__name__)

GUEST_MAX_MESSAGES = int(os.getenv("GUEST_MAX_MESSAGES", "3"))
GUEST_WINDOW_SEC = int(os.getenv("GUEST_WINDOW_SEC", "3600"))  # 1 hour

_memory_usage: dict[str, list[float]] = {}


def _redis() -> redis.Redis | None:
    url = (os.getenv("REDIS_URL") or "").strip()
    if not url:
        return None
    return redis.Redis.from_url(url, decode_responses=True, socket_connect_timeout=1.5)


def _check_memory(ip: str, *, max_messages: int, window_sec: int) -> None:
    now = time.time()
    timestamps = _memory_usage.get(ip, [])
    cutoff = now - window_sec
    timestamps = [t for t in timestamps if t > cutoff]
    if len(timestamps) >= max_messages:
        raise HTTPException(
            status_code=429,
            detail=(
                f"Guest limit reached ({max_messages} messages per hour). "
                "Create an account for unlimited access."
            ),
        )
    timestamps.append(now)
    _memory_usage[ip] = timestamps


def _check_redis(ip: str, *, max_messages: int, window_sec: int, client: redis.Redis) -> None:
    """Sliding window via Redis ZSET (member=unique, score=unix time)."""
    key = f"alfaai:guest:rl:{ip}"
    now = time.time()
    cutoff = now - window_sec
    member = f"{now:.6f}:{uuid.uuid4().hex}"
    pipe = client.pipeline()
    pipe.zremrangebyscore(key, 0, cutoff)
    pipe.zcard(key)
    pipe.zadd(key, {member: now})
    pipe.expire(key, window_sec + 60)
    results = pipe.execute()
    # results: [zrem..., zcard_before_add, zadd, expire]
    count_before = int(results[1] or 0)
    if count_before >= max_messages:
        # undo the add we just did
        try:
            client.zrem(key, member)
        except Exception:  # noqa: BLE001
            pass
        raise HTTPException(
            status_code=429,
            detail=(
                f"Guest limit reached ({max_messages} messages per hour). "
                "Create an account for unlimited access."
            ),
        )


def check_guest_rate_limit(
    ip: str,
    *,
    max_messages: int | None = None,
    window_sec: int | None = None,
    redis_factory: Callable[[], redis.Redis | None] | None = None,
) -> str:
    """Enforce guest limit. Returns backend used: 'redis' | 'memory'."""
    max_m = GUEST_MAX_MESSAGES if max_messages is None else max_messages
    win = GUEST_WINDOW_SEC if window_sec is None else window_sec
    factory = redis_factory or _redis
    try:
        client = factory()
        if client is not None:
            _check_redis(ip, max_messages=max_m, window_sec=win, client=client)
            return "redis"
    except HTTPException:
        raise
    except Exception as exc:  # noqa: BLE001
        logger.warning("guest rate limit Redis failed; using memory: %s", exc)

    _check_memory(ip, max_messages=max_m, window_sec=win)
    return "memory"


def reset_memory_limits_for_tests() -> None:
    """Test helper — clear in-process counters."""
    _memory_usage.clear()
