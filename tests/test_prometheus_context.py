"""Ask ALFa prometheus_ops context (official Prometheus HTTP API)."""

from __future__ import annotations

import asyncio
from unittest.mock import AsyncMock, MagicMock, patch

from src.ops.prometheus_context import (
    classify_host_thermal,
    fetch_prometheus_ops_context,
    filter_snapshot_for_host,
)


def _vector_payload(rows: list[tuple[dict[str, str], float]]) -> dict:
    return {
        "status": "success",
        "data": {
            "resultType": "vector",
            "result": [
                {"metric": metric, "value": [1700000000, str(val)]}
                for metric, val in rows
            ],
        },
    }


def test_fetch_prometheus_ops_context_filters_watchdog() -> None:
    alerts_payload = {
        "status": "success",
        "data": {
            "alerts": [
                {
                    "state": "firing",
                    "labels": {"alertname": "Watchdog", "severity": "none"},
                    "annotations": {},
                },
                {
                    "state": "firing",
                    "labels": {
                        "alertname": "AlfaAiIncidentMetricsScrapeDown",
                        "severity": "warning",
                        "job": "alfa-ai-incident-metrics",
                        "instance": "hub",
                    },
                    "annotations": {"summary": "scrape down"},
                },
                {
                    "state": "pending",
                    "labels": {"alertname": "Other"},
                    "annotations": {},
                },
            ]
        },
    }
    cpu_payload = _vector_payload(
        [
            ({"instance": "hub-111:9100"}, 82.5),
            ({"instance": "apps-105:9100"}, 12.0),
        ]
    )
    load_payload = _vector_payload([({"instance": "hub-111:9100"}, 9.2)])
    temp_payload = _vector_payload(
        [({"instance": "hub-111:9100", "sensor": "temp1"}, 78.0)]
    )
    container_payload = _vector_payload(
        [
            (
                {
                    "instance": "hub-111:9100",
                    "name": "hub-cadvisor",
                },
                9.8,
            )
        ]
    )

    def _mock_get(url: str, *args, **kwargs):
        mock_resp = MagicMock()
        mock_resp.raise_for_status = MagicMock()
        if url.endswith("/api/v1/alerts"):
            mock_resp.json.return_value = alerts_payload
        elif "node_cpu_seconds_total" in str(kwargs.get("params", {})):
            mock_resp.json.return_value = cpu_payload
        elif "node_load1" in str(kwargs.get("params", {})):
            mock_resp.json.return_value = load_payload
        elif "homelab:cpu_temperature_celsius" in str(kwargs.get("params", {})):
            mock_resp.json.return_value = temp_payload
        elif "container_cpu_usage_seconds_total" in str(kwargs.get("params", {})):
            mock_resp.json.return_value = container_payload
        else:
            mock_resp.json.return_value = {"status": "success", "data": {"resultType": "vector", "result": []}}
        return mock_resp

    mock_client = AsyncMock()
    mock_client.get.side_effect = _mock_get
    mock_client.__aenter__.return_value = mock_client
    mock_client.__aexit__.return_value = None

    with (
        patch("src.ops.prometheus_context.httpx.AsyncClient", return_value=mock_client),
        patch(
            "src.ops.prometheus_context.collect_operational_warnings",
            new=AsyncMock(return_value=[{"code": "incident_metrics_scrape"}]),
        ),
    ):
        out = asyncio.run(fetch_prometheus_ops_context())

    assert out["error"] is None
    assert out["firing_count"] == 1
    assert out["firing_alerts"][0]["alertname"] == "AlfaAiIncidentMetricsScrapeDown"
    assert out["operational_warnings"][0]["code"] == "incident_metrics_scrape"
    assert len(out["host_cpu_busy_pct"]) == 2
    assert out["host_cpu_busy_pct"][0]["value"] == 82.5
    assert out["host_load1"][0]["instance"].startswith("hub-111")
    assert out["host_cpu_package_temp_c"][0]["value"] == 78.0
    assert out["top_containers_cpu"][0]["name"] == "hub-cadvisor"
    assert out["snapshot_error"] is None


def test_fetch_prometheus_ops_context_snapshot_fails_soft() -> None:
    alerts_payload = {"status": "success", "data": {"alerts": []}}

    call_count = {"n": 0}

    def _mock_get(url: str, *args, **kwargs):
        mock_resp = MagicMock()
        mock_resp.raise_for_status = MagicMock()
        if url.endswith("/api/v1/alerts"):
            mock_resp.json.return_value = alerts_payload
            return mock_resp
        call_count["n"] += 1
        raise TimeoutError("query timeout")

    mock_client = AsyncMock()
    mock_client.get.side_effect = _mock_get
    mock_client.__aenter__.return_value = mock_client
    mock_client.__aexit__.return_value = None

    with (
        patch("src.ops.prometheus_context.httpx.AsyncClient", return_value=mock_client),
        patch(
            "src.ops.prometheus_context.collect_operational_warnings",
            new=AsyncMock(return_value=[]),
        ),
    ):
        out = asyncio.run(fetch_prometheus_ops_context())

    assert out["firing_count"] == 0
    assert out["host_cpu_busy_pct"] == []
    assert out["snapshot_error"] is not None
    assert "instant queries" in out["snapshot_error"].lower()


def test_filter_snapshot_for_host_and_classify_load_justified() -> None:
    snapshot = {
        "host_cpu_busy_pct": [
            {"instance": "hub-111:9100", "value": 85.0},
            {"instance": "apps-105:9100", "value": 5.0},
        ],
        "host_load1": [{"instance": "hub-111:9100", "value": 10.0}],
        "host_cpu_package_temp_c": [
            {"instance": "hub-111:9100", "sensor": "temp1", "value": 80.0}
        ],
        "top_containers_cpu": [
            {"instance": "hub-111:9100", "name": "hub-cadvisor", "value": 9.5}
        ],
    }
    host_rows = filter_snapshot_for_host(snapshot, "111")
    verdict = classify_host_thermal(host_rows)
    assert "Load-justified" in verdict
    assert "hub-cadvisor" in verdict


def test_classify_idle_hot_cooling_suspect() -> None:
    host_rows = {
        "host_cpu_busy_pct": [{"instance": "hub-111:9100", "value": 8.0}],
        "host_load1": [{"instance": "hub-111:9100", "value": 0.5}],
        "host_cpu_package_temp_c": [
            {"instance": "hub-111:9100", "sensor": "temp1", "value": 82.0}
        ],
        "top_containers_cpu": [],
    }
    verdict = classify_host_thermal(host_rows)
    assert "Idle-hot" in verdict
    assert "cooling" in verdict.lower()
