"""Fetch Prometheus firing alerts and host load snapshot for Ask ALFa context.

Official HTTP APIs:
- Alerts: https://prometheus.io/docs/prometheus/latest/querying/api/#alerts
- Instant query: https://prometheus.io/docs/prometheus/latest/querying/api/#instant-queries
"""

from __future__ import annotations

import logging
import os
from typing import Any

import httpx

from src.api.operational_warnings import collect_operational_warnings

logger = logging.getLogger(__name__)

_DEFAULT_PROMETHEUS_URL = "http://monitor"
_MAX_FIRING = 25
_QUERY_TIMEOUT_SEC = 6.0
_MAX_HOST_SERIES = 20
_MAX_CONTAINER_SERIES = 10

# PromQL curated for homelab fleet (tune labels in monitoring repo).
_SNAPSHOT_QUERIES: dict[str, str] = {
    "host_cpu_busy_pct": (
        '100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)'
    ),
    "host_load1": "node_load1",
    "host_cpu_package_temp_c": "homelab:cpu_temperature_celsius",
    "top_containers_cpu": (
        'topk(10, sum by (instance, name) (rate(container_cpu_usage_seconds_total{name!=""}[5m])))'
    ),
}

# Instance label markers for fleet hosts (gaps OK when host not scraped).
_HOST_INSTANCE_MARKERS: dict[str, tuple[str, ...]] = {
    "93": ("operator-93", "orchestrator"),
    "100": ("vm100", "orchestrator"),
    "102": ("market-102", "market"),
    "103": ("atems-103", "atems"),
    "105": ("web-sites-105", "apps-105", "apps"),
    "106": ("probilliards-106", "orchestrator"),
    "107": ("monitoring-107", "monitor"),
    "111": ("hub-111", "brain-111", "hub"),
    "148": ("ai-148", "hub-148", "g-rev27", "orchestrator"),
}


def _prometheus_base_url() -> str:
    return (os.getenv("ALFA_AI_PROMETHEUS_URL") or _DEFAULT_PROMETHEUS_URL).strip().rstrip("/")


def _instance_matches_host(instance: str, host_key: str) -> bool:
    inst = (instance or "").lower()
    if not inst:
        return False
    if host_key in inst:
        return True
    for marker in _HOST_INSTANCE_MARKERS.get(host_key, ()):
        if marker.lower() in inst:
            return True
    return False


def _parse_vector_rows(
    payload: dict[str, Any],
    *,
    max_rows: int,
    extra_label_keys: tuple[str, ...] = (),
) -> list[dict[str, Any]]:
    """Parse Prometheus instant vector result into compact dict rows."""
    data = payload.get("data") or {}
    if data.get("resultType") != "vector":
        return []
    rows: list[dict[str, Any]] = []
    for item in data.get("result") or []:
        metric = item.get("metric") or {}
        value_pair = item.get("value")
        if not value_pair or len(value_pair) < 2:
            continue
        try:
            numeric = float(value_pair[1])
        except (TypeError, ValueError):
            continue
        row: dict[str, Any] = {
            "instance": metric.get("instance") or "",
            "value": round(numeric, 2),
        }
        for key in extra_label_keys:
            if metric.get(key):
                row[key] = metric[key]
        rows.append(row)
        if len(rows) >= max_rows:
            break
    return rows


async def _query_prometheus_instant(
    client: httpx.AsyncClient,
    base: str,
    query: str,
) -> list[dict[str, Any]]:
    resp = await client.get(
        f"{base}/api/v1/query",
        params={"query": query},
        timeout=_QUERY_TIMEOUT_SEC,
    )
    resp.raise_for_status()
    payload = resp.json()
    if payload.get("status") != "success":
        return []
    extra = ("sensor", "name") if "container_cpu" in query else ("sensor",)
    cap = _MAX_CONTAINER_SERIES if "container_cpu" in query else _MAX_HOST_SERIES
    return _parse_vector_rows(payload, max_rows=cap, extra_label_keys=extra)


async def _fetch_host_load_snapshot(base: str) -> tuple[dict[str, Any], str | None]:
    """Run curated instant PromQL queries; fail soft."""
    out: dict[str, Any] = {
        "host_cpu_busy_pct": [],
        "host_load1": [],
        "host_cpu_package_temp_c": [],
        "top_containers_cpu": [],
    }
    errors: list[str] = []
    try:
        async with httpx.AsyncClient() as client:
            for key, query in _SNAPSHOT_QUERIES.items():
                try:
                    out[key] = await _query_prometheus_instant(client, base, query)
                except (httpx.HTTPError, ValueError, TypeError) as exc:
                    logger.warning("prometheus snapshot query failed key=%s err=%s", key, exc)
                    errors.append(key)
    except Exception as exc:  # noqa: BLE001 -- snapshot must not break Ask ALFa
        logger.warning("prometheus snapshot failed url=%s err=%s", base, exc)
        return out, f"Could not read instant queries from {base}"
    if errors and not any(out[k] for k in out):
        return out, f"Prometheus snapshot queries failed: {', '.join(errors)}"
    if errors:
        return out, f"Partial snapshot; failed: {', '.join(errors)}"
    return out, None


def filter_snapshot_for_host(snapshot: dict[str, Any], host_key: str) -> dict[str, Any]:
    """Return snapshot rows matching a host key (for deterministic router briefing)."""
    filtered: dict[str, Any] = {}
    for key in ("host_cpu_busy_pct", "host_load1", "host_cpu_package_temp_c"):
        rows = snapshot.get(key) or []
        filtered[key] = [
            row
            for row in rows
            if _instance_matches_host(str(row.get("instance") or ""), host_key)
        ]
    containers = snapshot.get("top_containers_cpu") or []
    filtered["top_containers_cpu"] = [
        row
        for row in containers
        if _instance_matches_host(str(row.get("instance") or ""), host_key)
    ]
    return filtered


def classify_host_thermal(
    host_rows: dict[str, Any],
    *,
    cpu_hot_pct: float = 50.0,
    load_hot: float = 4.0,
    temp_hot_c: float = 70.0,
) -> str:
    """L1 verdict: load-justified heat vs idle-hot (cooling suspect)."""
    cpu_vals = [float(r.get("value") or 0) for r in host_rows.get("host_cpu_busy_pct") or []]
    load_vals = [float(r.get("value") or 0) for r in host_rows.get("host_load1") or []]
    temp_vals = [float(r.get("value") or 0) for r in host_rows.get("host_cpu_package_temp_c") or []]
    containers = host_rows.get("top_containers_cpu") or []

    max_cpu = max(cpu_vals) if cpu_vals else 0.0
    max_load = max(load_vals) if load_vals else 0.0
    max_temp = max(temp_vals) if temp_vals else 0.0

    if not temp_vals and not cpu_vals and not load_vals:
        return "No Prometheus host metrics for this host (may not be in node-remote scrape)."

    hot_temp = max_temp >= temp_hot_c
    elevated_load = max_cpu >= cpu_hot_pct or max_load >= load_hot

    parts: list[str] = []
    if temp_vals:
        parts.append(f"package temp up to {max_temp:.1f} C")
    if cpu_vals:
        parts.append(f"CPU busy up to {max_cpu:.1f}%")
    if load_vals:
        parts.append(f"load1 up to {max_load:.2f}")

    metric_line = "; ".join(parts) if parts else "metrics sparse"

    if hot_temp and elevated_load:
        verdict = "Load-justified heat: high temp with elevated CPU or load."
        if containers:
            top = max(containers, key=lambda r: float(r.get("value") or 0))
            name = top.get("name") or "?"
            cpu = float(top.get("value") or 0)
            verdict += f" Top container by CPU rate: {name} ({cpu:.2f} cores)."
        return f"{verdict} ({metric_line})"

    if hot_temp and not elevated_load:
        return (
            f"Idle-hot pattern: high temp ({max_temp:.1f} C) with low CPU/load -- "
            f"suspect cooling (fans, paste, fan curve), not a runaway process. ({metric_line})"
        )

    if elevated_load:
        line = f"Elevated CPU/load without hot package temp in snapshot. ({metric_line})"
        if containers:
            top = max(containers, key=lambda r: float(r.get("value") or 0))
            name = top.get("name") or "?"
            cpu = float(top.get("value") or 0)
            line += f" Top container: {name} ({cpu:.2f} cores)."
        return line

    return f"Host looks quiet in Prometheus snapshot. ({metric_line})"


async def fetch_prometheus_ops_context() -> dict[str, Any]:
    """Compact monitoring snapshot for Ask ALFa (scrape health + firing alerts + load/temp)."""
    base = _prometheus_base_url()
    out: dict[str, Any] = {
        "prometheus_url": base,
        "operational_warnings": [],
        "firing_alerts": [],
        "firing_count": 0,
        "host_cpu_busy_pct": [],
        "host_load1": [],
        "host_cpu_package_temp_c": [],
        "top_containers_cpu": [],
        "snapshot_error": None,
        "error": None,
    }
    try:
        out["operational_warnings"] = await collect_operational_warnings()
    except Exception as exc:  # noqa: BLE001 -- context must not break Ask ALFa
        logger.warning("operational_warnings for Ask ALFa failed: %s", exc)
        out["operational_warnings"] = []

    try:
        async with httpx.AsyncClient() as client:
            resp = await client.get(f"{base}/api/v1/alerts", timeout=8.0)
            resp.raise_for_status()
            payload = resp.json()
        alerts = payload.get("data", {}).get("alerts") or []
        firing: list[dict[str, Any]] = []
        for row in alerts:
            if row.get("state") != "firing":
                continue
            labels = row.get("labels") or {}
            name = labels.get("alertname") or ""
            if name == "Watchdog":
                continue
            firing.append(
                {
                    "alertname": name,
                    "severity": labels.get("severity"),
                    "job": labels.get("job"),
                    "instance": labels.get("instance"),
                    "summary": (row.get("annotations") or {}).get("summary"),
                }
            )
            if len(firing) >= _MAX_FIRING:
                break
        out["firing_alerts"] = firing
        out["firing_count"] = len(firing)
    except (httpx.HTTPError, ValueError, TypeError) as exc:
        logger.warning("prometheus alerts probe failed url=%s err=%s", base, exc)
        out["error"] = f"Could not read /api/v1/alerts from {base}"

    snapshot, snap_err = await _fetch_host_load_snapshot(base)
    out.update(snapshot)
    out["snapshot_error"] = snap_err

    return out
