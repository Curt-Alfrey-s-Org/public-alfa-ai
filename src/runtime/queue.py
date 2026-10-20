from __future__ import annotations

from collections import defaultdict, deque
from typing import Protocol

import redis

from src.runtime.worker_host import queue_name_for_host, worker_host_from_env


class RuntimeQueue(Protocol):
    def push_task(self, task_id: str, *, target_host: str | None = None) -> None: ...
    def pop_task(self, *, worker_host: str | None = None) -> str | None: ...


class InMemoryQueue:
    def __init__(self) -> None:
        self._queues: dict[str, deque[str]] = defaultdict(deque)

    def push_task(self, task_id: str, *, target_host: str | None = None) -> None:
        name = queue_name_for_host(target_host)
        self._queues[name].append(task_id)

    def pop_task(self, *, worker_host: str | None = None) -> str | None:
        name = queue_name_for_host(worker_host or worker_host_from_env())
        q = self._queues.get(name)
        if not q:
            return None
        return q.popleft() if q else None


class RedisQueue:
    def __init__(self, redis_url: str, queue_name: str = "alfaai:queue:tasks") -> None:
        self.client = redis.from_url(redis_url, decode_responses=True)
        # Legacy default queue name kept for reference; per-host keys use queue_name_for_host().
        self._legacy_queue_name = queue_name

    def push_task(self, task_id: str, *, target_host: str | None = None) -> None:
        self.client.rpush(queue_name_for_host(target_host), task_id)

    def pop_task(self, *, worker_host: str | None = None) -> str | None:
        value = self.client.lpop(queue_name_for_host(worker_host or worker_host_from_env()))
        return value if isinstance(value, str) else None
