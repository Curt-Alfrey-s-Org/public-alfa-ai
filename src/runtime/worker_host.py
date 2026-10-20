"""Worker host id normalization and Redis queue naming."""

from __future__ import annotations

import os

DEFAULT_WORKER_HOST = "111"
_QUEUE_PREFIX = "alfaai:queue:tasks"


def normalize_worker_host(raw: str | None) -> str:
    value = (raw or DEFAULT_WORKER_HOST).strip()
    return value or DEFAULT_WORKER_HOST


def worker_host_from_env() -> str:
    return normalize_worker_host(os.getenv("ALFA_AI_WORKER_HOST"))


def queue_name_for_host(host: str | None) -> str:
    return f"{_QUEUE_PREFIX}:{normalize_worker_host(host)}"


def task_target_host(metadata: dict | None) -> str:
    if not metadata:
        return DEFAULT_WORKER_HOST
    raw = metadata.get("target_host")
    if isinstance(raw, str) and raw.strip():
        return normalize_worker_host(raw)
    return DEFAULT_WORKER_HOST
