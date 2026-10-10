"""Background agent worker: drain orchestrator task queue for this host."""

from __future__ import annotations

import logging
import os
import time

from src.runtime.factory import build_orchestrator
from src.runtime.worker_host import worker_host_from_env

logger = logging.getLogger(__name__)

_POLL_SEC = max(5, int(os.getenv("ALFA_AI_AGENT_WORKER_POLL_SEC", "15") or "15"))
_BETWEEN_TASK_SEC = max(1, int(os.getenv("ALFA_AI_AGENT_WORKER_BETWEEN_TASK_SEC", "2") or "2"))
_HEARTBEAT_TTL = max(60, int(os.getenv("ALFA_AI_WORKER_HEARTBEAT_TTL_SEC", "120") or "120"))


def _write_worker_heartbeat(*, status: str, last_action: str) -> None:
    host = worker_host_from_env()
    try:
        from src.api.redis_heartbeat import store_worker_heartbeat

        store_worker_heartbeat(
            f"alfa-ai-worker-{host}",
            "agent_worker",
            _HEARTBEAT_TTL,
            extra={"host": host, "status": status, "last_action": last_action},
        )
    except Exception:
        logger.debug("worker heartbeat skipped (redis unavailable)")


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    host = worker_host_from_env()
    orchestrator = build_orchestrator()
    logger.info(
        "agent worker started host=%s poll=%ss between_task=%ss",
        host,
        _POLL_SEC,
        _BETWEEN_TASK_SEC,
    )
    _write_worker_heartbeat(status="alive", last_action="worker started")

    while True:
        try:
            result = orchestrator.process_next_task(worker_host=host)
        except Exception:
            logger.exception("agent worker: process_next_task failed")
            _write_worker_heartbeat(status="alive", last_action="process_next_task error")
            time.sleep(_POLL_SEC)
            continue

        if result is None:
            _write_worker_heartbeat(status="idle", last_action="queue empty")
            time.sleep(_POLL_SEC)
            continue

        logger.info(
            "agent worker: task=%s status=%s summary=%s tools=%s",
            result.get("task_id"),
            result.get("status"),
            (result.get("summary") or "")[:120],
            len(result.get("tool_events") or []),
        )
        _write_worker_heartbeat(
            status="busy",
            last_action=f"task {result.get('task_id')} {result.get('status')}",
        )
        time.sleep(_BETWEEN_TASK_SEC)


if __name__ == "__main__":
    main()
