from __future__ import annotations

import threading
from collections import defaultdict
from datetime import UTC, datetime
from typing import Any


class MissionEventBus:
    """In-memory mission event stream for operator SSE (per run_id)."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._events: dict[str, list[dict[str, Any]]] = defaultdict(list)

    def publish(self, run_id: str, event_type: str, payload: dict[str, Any] | None = None) -> None:
        if not run_id:
            return
        entry: dict[str, Any] = {
            "type": event_type,
            "run_id": run_id,
            "at": datetime.now(tz=UTC).isoformat(),
        }
        if payload:
            entry.update(payload)
        with self._lock:
            self._events[run_id].append(entry)
            if len(self._events[run_id]) > 500:
                self._events[run_id] = self._events[run_id][-500:]

    def get_since(self, run_id: str, offset: int) -> tuple[list[dict[str, Any]], int]:
        with self._lock:
            events = self._events.get(run_id, [])
            safe_offset = max(0, min(offset, len(events)))
            return events[safe_offset:], len(events)


mission_event_bus = MissionEventBus()