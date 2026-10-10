"""Prometheus metrics for incident worker / notify path (admin scrape only).

Official client: https://prometheus.io/docs/instrumenting/clientlibs/
Exposed at GET /alfa-ai/api/admin/metrics/prometheus (admin JWT + network).
"""

from __future__ import annotations

import logging
import os
from typing import TYPE_CHECKING

from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, generate_latest

if TYPE_CHECKING:
    from src.api.models.ai_action import AiActionStore
    from src.api.models.incident import IncidentStore

logger = logging.getLogger(__name__)

INCIDENTS_OPEN = Gauge(
    "alfa_ai_incidents_open",
    "Incidents in non-terminal status",
    ["status"],
)
WORKER_LAG_SECONDS = Gauge(
    "alfa_ai_incident_worker_lag_seconds",
    "Age in seconds of oldest received or investigating incident",
)
NOTIFICATIONS_TOTAL = Counter(
    "alfa_ai_notifications_total",
    "Programmatic direct alert notifications",
    ["result"],
)
AUTOFIX_ATTEMPTS_TOTAL = Counter(
    "alfa_ai_autofix_attempts_total",
    "Playbook auto_fix attempts from incident worker",
    ["result"],
)
JWT_SECRET_EPHEMERAL = Gauge(
    "alfa_ai_jwt_secret_ephemeral",
    "1 when ALFA_AI_JWT_SECRET is unset (admin JWTs invalidate on API restart)",
)


def record_notification(result: str) -> None:
    NOTIFICATIONS_TOTAL.labels(result=result).inc()


def record_autofix_attempt(result: str) -> None:
    AUTOFIX_ATTEMPTS_TOTAL.labels(result=result).inc()


def refresh_operational_gauges() -> None:
    configured = bool(os.getenv("ALFA_AI_JWT_SECRET", "").strip())
    JWT_SECRET_EPHEMERAL.set(0.0 if configured else 1.0)


def refresh_incident_gauges(store: IncidentStore) -> None:
    """Recompute gauge metrics from Postgres (called on each admin scrape)."""
    try:
        counts = store.count_by_status()
        for status in ("received", "investigating", "needs_human", "resolved"):
            INCIDENTS_OPEN.labels(status=status).set(float(counts.get(status, 0)))
        lag = store.oldest_active_lag_seconds()
        WORKER_LAG_SECONDS.set(float(lag) if lag is not None else 0.0)
    except Exception:
        logger.exception("failed to refresh incident prometheus gauges")


def prometheus_payload(store: IncidentStore) -> tuple[bytes, str]:
    refresh_operational_gauges()
    refresh_incident_gauges(store)
    return generate_latest(), CONTENT_TYPE_LATEST
