"""Operator-facing warnings for admin UI and health (JWT secret, Prometheus scrape)."""

from __future__ import annotations

import logging
import os
import time
from typing import Any

import httpx

logger = logging.getLogger(__name__)

_PROMETHEUS_JOB = "alfa-ai-incident-metrics"
_DEFAULT_PROMETHEUS_URL = "http://monitor"


def jwt_secret_is_configured() -> bool:
    return bool(os.getenv("ALFA_AI_JWT_SECRET", "").strip())


def _prometheus_base_url() -> str:
    return (os.getenv("ALFA_AI_PROMETHEUS_URL") or _DEFAULT_PROMETHEUS_URL).strip().rstrip("/")


def _jwt_secret_warning() -> dict[str, str] | None:
    if jwt_secret_is_configured():
        return None
    return {
        "id": "jwt_secret_ephemeral",
        "level": "error",
        "title": "JWT secret not configured",
        "message": (
            "ALFA_AI_JWT_SECRET is unset on the brain API. Every container recreate "
            "invalidates admin logins and the Prometheus scrape bearer on monitor."
        ),
        "hint": (
            "Set ALFA_AI_JWT_SECRET in deploy/.env on hub (openssl rand -hex 32), "
            "recreate alfa-ai-api, log in once, then refresh the bearer on monitor."
        ),
    }


async def _prometheus_scrape_warning(client: httpx.AsyncClient) -> dict[str, str] | None:
    base = _prometheus_base_url()
    if not base:
        return None
    try:
        resp = await client.get(f"{base}/api/v1/targets", timeout=8.0)
        resp.raise_for_status()
        payload = resp.json()
    except (httpx.HTTPError, ValueError) as exc:
        logger.warning("prometheus targets probe failed url=%s err=%s", base, exc)
        return {
            "id": "prometheus_unreachable",
            "level": "warning",
            "title": "Prometheus unreachable from brain",
            "message": (
                f"Could not read scrape targets from {base}. Incident-metric scrape "
                "health is unknown."
            ),
            "hint": "Confirm monitor Prometheus is up and ALFA_AI_PROMETHEUS_URL is correct.",
        }

    targets = payload.get("data", {}).get("activeTargets") or []
    job_targets = [
        t for t in targets if (t.get("labels") or {}).get("job") == _PROMETHEUS_JOB
    ]
    if not job_targets:
        return {
            "id": "prometheus_incident_metrics_missing",
            "level": "warning",
            "title": "Incident metrics scrape job not found",
            "message": (
                f"Prometheus at {base} has no active target for job "
                f"{_PROMETHEUS_JOB}."
            ),
            "hint": (
                "Add alfa-ai-incident-metrics to prometheus.yml on monitor and reload "
                "Prometheus."
            ),
        }

    unhealthy = [t for t in job_targets if t.get("health") != "up"]
    if not unhealthy:
        return None

    last_error = ""
    for t in unhealthy:
        err = (t.get("lastError") or "").strip()
        if err:
            last_error = err
            break

    detail = last_error or "target health is not up"
    return {
        "id": "prometheus_incident_metrics_down",
        "level": "error",
        "title": "Incident metrics Prometheus scrape failing",
        "message": (
            f"Job {_PROMETHEUS_JOB} on monitor is down ({detail}). "
            "SLO and incident gauges are not updating."
        ),
        "hint": (
            "On monitor: if refresh-alfa-ai-prometheus-bearer.sh fails with 401, "
            "re-login (or mint tokens) and re-save alfa_ai_refresh_token + bearer; "
            "see docs/ALFA_AI_OPERATIONAL_ALERTS.md. Do not restart Prometheus."
        ),
    }


async def collect_operational_warnings() -> list[dict[str, str]]:
    warnings: list[dict[str, str]] = []
    jwt_warn = _jwt_secret_warning()
    if jwt_warn:
        warnings.append(jwt_warn)

    async with httpx.AsyncClient() as client:
        prom_warn = await _prometheus_scrape_warning(client)
    if prom_warn:
        warnings.append(prom_warn)

    return warnings


async def operational_warnings_payload() -> dict[str, Any]:
    return {
        "warnings": await collect_operational_warnings(),
        "ts": int(time.time()),
    }
