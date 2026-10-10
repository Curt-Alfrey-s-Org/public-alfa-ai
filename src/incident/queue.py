"""Redis queue for incident worker jobs."""

from __future__ import annotations

import os

import redis

_QUEUE_NAME = "alfaai:queue:incidents"


def _redis_client() -> redis.Redis:
    url = os.getenv("REDIS_URL", "redis://localhost:6379/0")
    return redis.Redis.from_url(url, decode_responses=True)


def enqueue_incident(incident_id: str) -> None:
    client = _redis_client()
    client.rpush(_QUEUE_NAME, incident_id)


def pop_incident(timeout_sec: int = 5) -> str | None:
    client = _redis_client()
    result = client.blpop(_QUEUE_NAME, timeout=max(1, timeout_sec))
    if not result:
        return None
    _, value = result
    return value if isinstance(value, str) else None
