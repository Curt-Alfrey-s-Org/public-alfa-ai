from __future__ import annotations

from src.config import get
from src.runtime.orchestrator import RuntimeOrchestrator
from src.runtime.queue import InMemoryQueue, RedisQueue, RuntimeQueue
from src.runtime.store import InMemoryStore, PostgresStore, RuntimeStore


def build_store() -> RuntimeStore:
    database_url = get("DATABASE_URL", "").strip()
    if database_url:
        return PostgresStore(database_url=database_url)
    return InMemoryStore()


def build_queue() -> RuntimeQueue:
    redis_url = get("REDIS_URL", "").strip()
    if redis_url:
        return RedisQueue(redis_url=redis_url)
    return InMemoryQueue()


def build_orchestrator() -> RuntimeOrchestrator:
    return RuntimeOrchestrator(store=build_store(), queue=build_queue())

