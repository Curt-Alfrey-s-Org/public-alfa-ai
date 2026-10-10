"""Tests for admin operational warnings (JWT secret, Prometheus scrape)."""

from __future__ import annotations

import asyncio

import httpx
import pytest

from src.api.operational_warnings import (
    collect_operational_warnings,
    jwt_secret_is_configured,
)


def test_jwt_secret_ephemeral_warning(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("ALFA_AI_JWT_SECRET", raising=False)

    async def fake_scrape(_client: httpx.AsyncClient):
        return None

    monkeypatch.setattr(
        "src.api.operational_warnings._prometheus_scrape_warning",
        fake_scrape,
    )

    warnings = asyncio.run(collect_operational_warnings())
    ids = [w["id"] for w in warnings]
    assert "jwt_secret_ephemeral" in ids


def test_no_jwt_warning_when_configured(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_JWT_SECRET", "change-me")

    async def fake_scrape(_client: httpx.AsyncClient):
        return None

    monkeypatch.setattr(
        "src.api.operational_warnings._prometheus_scrape_warning",
        fake_scrape,
    )

    warnings = asyncio.run(collect_operational_warnings())
    assert all(w["id"] != "jwt_secret_ephemeral" for w in warnings)


def test_prometheus_scrape_down_warning(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_JWT_SECRET", "change-me")

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/api/v1/targets"
        body = {
            "data": {
                "activeTargets": [
                    {
                        "labels": {"job": "alfa-ai-incident-metrics"},
                        "health": "down",
                        "lastError": "server returned HTTP status 401 Unauthorized",
                    }
                ]
            }
        }
        return httpx.Response(200, json=body)

    async def run() -> None:
        transport = httpx.MockTransport(handler)
        async with httpx.AsyncClient(transport=transport) as client:
            from src.api.operational_warnings import _prometheus_scrape_warning

            warning = await _prometheus_scrape_warning(client)

        assert warning is not None
        assert warning["id"] == "prometheus_incident_metrics_down"
        assert warning["level"] == "error"
        assert "401" in warning["message"]

    asyncio.run(run())


def test_jwt_secret_is_configured_empty(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_JWT_SECRET", "   ")
    assert jwt_secret_is_configured() is False
