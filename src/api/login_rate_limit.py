"""Per-client-IP failed-login limit (org code review 2026-09-25, finding 15).

Complements the per-account lockout in ``src/api/routers/auth.py``: the account
lock stops guessing against one user, this stops one client from guessing across
many users (or hammering a locked one). Docs: docs/AUTH_ACCOUNT_LIFECYCLE.md
("Failed-login lockout and per-IP limit").

Same storage pattern as ``src/api/guest_rate_limit.py`` (audit D-011): a Redis
sliding window shared by every API worker, with an in-process fallback when
REDIS_URL is unset or Redis is unreachable (dev / DB-less).

The key MUST be the proxy-resolved client IP
(``src.api.admin_network.get_proxy_resolved_client_ip``), never the raw first
``X-Forwarded-For`` value, otherwise a client picks its own bucket.

Env (read on every call so operators and tests can change them):
- ``ALFA_AI_LOGIN_IP_MAX_FAILURES`` (default 20; ``0`` disables the limit)
- ``ALFA_AI_LOGIN_IP_WINDOW_SEC`` (default 900 = 15 minutes)
"""

from __future__ import annotations

import logging
import os
import time
import uuid
from typing import Callable

import redis

logger = logging.getLogger(__name__)

DEFAULT_LOGIN_IP_MAX_FAILURES = 20
DEFAULT_LOGIN_IP_WINDOW_SEC = 900  # 15 minutes, same as the account lockout window

_REDIS_KEY_PREFIX = "alfaai:login:ipfail:"
# Upper bound on distinct IPs tracked in the in-process fallback (memory safety).
_MEMORY_MAX_KEYS = 10_000

_memory_failures: dict[str, list[float]] = {}

RedisFactory = Callable[[], "redis.Redis | None"]


def _env_int(name: str, default: int) -> int:
    raw = (os.getenv(name) or "").strip()
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        logger.warning("Ignoring invalid %s=%r; using %s", name, raw, default)
        return default


def login_ip_max_failures() -> int:
    """Failed logins allowed per client IP per window; ``<= 0`` disables the limit."""
    return _env_int("ALFA_AI_LOGIN_IP_MAX_FAILURES", DEFAULT_LOGIN_IP_MAX_FAILURES)


def login_ip_window_sec() -> int:
    value = _env_int("ALFA_AI_LOGIN_IP_WINDOW_SEC", DEFAULT_LOGIN_IP_WINDOW_SEC)
    return value if value > 0 else DEFAULT_LOGIN_IP_WINDOW_SEC


def _redis() -> redis.Redis | None:
    url = (os.getenv("REDIS_URL") or "").strip()
    if not url:
        return None
    return redis.Redis.from_url(url, decode_responses=True, socket_connect_timeout=1.5)


def _redis_key(ip: str) -> str:
    return f"{_REDIS_KEY_PREFIX}{ip}"


# ── In-process fallback ─────────────────────────────────────

def _memory_prune(now: float, window_sec: int) -> None:
    cutoff = now - window_sec
    for key in [k for k, ts in _memory_failures.items() if not ts or ts[-1] <= cutoff]:
        _memory_failures.pop(key, None)
    while len(_memory_failures) >= _MEMORY_MAX_KEYS:
        oldest = min(_memory_failures, key=lambda k: _memory_failures[k][-1])
        _memory_failures.pop(oldest, None)


def _memory_count(ip: str, window_sec: int) -> int:
    cutoff = time.time() - window_sec
    timestamps = [t for t in _memory_failures.get(ip, []) if t > cutoff]
    if timestamps:
        _memory_failures[ip] = timestamps
    else:
        _memory_failures.pop(ip, None)
    return len(timestamps)


def _memory_record(ip: str, window_sec: int) -> None:
    now = time.time()
    if ip not in _memory_failures:
        _memory_prune(now, window_sec)
    cutoff = now - window_sec
    timestamps = [t for t in _memory_failures.get(ip, []) if t > cutoff]
    timestamps.append(now)
    _memory_failures[ip] = timestamps


# ── Redis sliding window (ZSET, member=unique, score=unix time) ─

def _redis_count(ip: str, window_sec: int, client: redis.Redis) -> int:
    key = _redis_key(ip)
    pipe = client.pipeline()
    pipe.zremrangebyscore(key, 0, time.time() - window_sec)
    pipe.zcard(key)
    results = pipe.execute()
    return int(results[1] or 0)


def _redis_record(ip: str, window_sec: int, client: redis.Redis) -> None:
    key = _redis_key(ip)
    now = time.time()
    pipe = client.pipeline()
    pipe.zremrangebyscore(key, 0, now - window_sec)
    pipe.zadd(key, {f"{now:.6f}:{uuid.uuid4().hex}": now})
    pipe.expire(key, window_sec + 60)
    pipe.execute()


# ── Public API ──────────────────────────────────────────────

def is_login_ip_limited(
    ip: str | None,
    *,
    max_failures: int | None = None,
    window_sec: int | None = None,
    redis_factory: RedisFactory | None = None,
) -> bool:
    """True when *ip* has reached the failed-login limit for the current window."""
    if not ip:
        return False
    max_f = login_ip_max_failures() if max_failures is None else max_failures
    if max_f <= 0:
        return False
    win = login_ip_window_sec() if window_sec is None else window_sec
    factory = redis_factory or _redis
    try:
        client = factory()
        if client is not None:
            return _redis_count(ip, win, client) >= max_f
    except Exception as exc:  # noqa: BLE001
        logger.warning("login IP limit Redis failed; using memory: %s", exc)
    return _memory_count(ip, win) >= max_f


def record_login_ip_failure(
    ip: str | None,
    *,
    window_sec: int | None = None,
    redis_factory: RedisFactory | None = None,
) -> str | None:
    """Count one failed login for *ip*. Returns backend used: 'redis' | 'memory' | None."""
    if not ip or login_ip_max_failures() <= 0:
        return None
    win = login_ip_window_sec() if window_sec is None else window_sec
    factory = redis_factory or _redis
    try:
        client = factory()
        if client is not None:
            _redis_record(ip, win, client)
            return "redis"
    except Exception as exc:  # noqa: BLE001
        logger.warning("login IP limit Redis failed; using memory: %s", exc)
    _memory_record(ip, win)
    return "memory"


def reset_memory_limits_for_tests() -> None:
    """Test helper — clear in-process counters."""
    _memory_failures.clear()
