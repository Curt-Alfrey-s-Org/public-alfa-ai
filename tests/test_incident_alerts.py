"""Tests for Alertmanager webhook ingest and incident helpers."""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from typing import Any

import pytest
from fastapi.testclient import TestClient

from src.api.alertmanager import normalize_alertmanager_webhook
from src.api.app import app
from src.api.deps import get_incident_store
from src.api.models.incident import IncidentRecord


@dataclass
class _MemIncidentStore:
    items: dict[str, IncidentRecord] = field(default_factory=dict)
    events: list[dict[str, Any]] = field(default_factory=list)

    def upsert_from_alert(self, **kwargs: Any) -> tuple[IncidentRecord, bool]:
        fp = kwargs["fingerprint"]
        existing = self.items.get(fp)
        if existing is None:
            record = IncidentRecord(
                id=str(uuid.uuid4()),
                fingerprint=fp,
                alertname=kwargs["alertname"],
                severity=kwargs["severity"],
                status="resolved" if kwargs["alert_status"] == "resolved" else "received",
                labels=kwargs["labels"],
                annotations=kwargs["annotations"],
                raw_payload=kwargs["raw_alert"],
                summary=kwargs["annotations"].get("summary"),
                opened_at="2026-06-25T00:00:00+00:00",
                resolved_at="2026-06-25T00:00:00+00:00" if kwargs["alert_status"] == "resolved" else None,
                last_seen_at="2026-06-25T00:00:00+00:00",
                updated_at="2026-06-25T00:00:00+00:00",
            )
            self.items[fp] = record
            return record, kwargs["alert_status"] != "resolved"
        return existing, False

    def record_event(self, incident_id: str, event_type: str, payload: dict[str, Any] | None = None) -> None:
        self.events.append(
            {"incident_id": incident_id, "event_type": event_type, "payload": payload or {}}
        )


def test_normalize_alertmanager_webhook_extracts_fingerprint() -> None:
    body = {
        "status": "firing",
        "receiver": "email",
        "groupKey": "{}/{}:{alertname=\"Test\"}",
        "alerts": [
            {
                "status": "firing",
                "fingerprint": "abc123",
                "labels": {"alertname": "TestAlert", "severity": "critical", "instance": "a:1"},
                "annotations": {"summary": "something broke"},
            }
        ],
    }
    out = normalize_alertmanager_webhook(body)
    assert len(out) == 1
    assert out[0]["fingerprint"] == "abc123"
    assert out[0]["alertname"] == "TestAlert"
    assert out[0]["severity"] == "critical"


@pytest.fixture()
def alert_client(monkeypatch: pytest.MonkeyPatch) -> TestClient:
    monkeypatch.setenv("ALFA_AI_ALERT_WEBHOOK_TOKEN", "change-me")
    monkeypatch.setenv("ALFA_AI_ALERT_ALLOWED_CIDRS", "*")
    monkeypatch.setenv("ALFA_AI_INCIDENT_QUEUE", "false")
    store = _MemIncidentStore()
    app.dependency_overrides[get_incident_store] = lambda: store
    client = TestClient(app)
    client._mem_store = store  # type: ignore[attr-defined]
    yield client
    app.dependency_overrides.clear()


def test_alert_webhook_403_without_token(alert_client: TestClient) -> None:
    body = {"alerts": [{"status": "firing", "fingerprint": "x", "labels": {"alertname": "T"}}]}
    r = alert_client.post("/alfa-ai/api/internal/alerts", json=body)
    assert r.status_code == 403


def test_alert_webhook_accepts_firing_alert(alert_client: TestClient) -> None:
    body = {
        "status": "firing",
        "receiver": "alfa-ai",
        "alerts": [
            {
                "status": "firing",
                "fingerprint": "fp-1",
                "labels": {"alertname": "LiteLLMProbeFailed", "severity": "warning"},
                "annotations": {"summary": "probe failed"},
            }
        ],
    }
    r = alert_client.post(
        "/alfa-ai/api/internal/alerts",
        json=body,
        headers={"X-Alfa-Alert-Token": "change-me"},
    )
    assert r.status_code == 200
    data = r.json()
    assert data["ok"] is True
    assert data["processed"] == 1
    store: _MemIncidentStore = alert_client._mem_store  # type: ignore[attr-defined]
    assert len(store.items) == 1
    assert any(e["event_type"] == "webhook_received" for e in store.events)


def test_playbooks_load_brain_health() -> None:
    from src.incident.playbooks import get_playbook

    pb = get_playbook("AlfaAiBrainHealthDown")
    assert pb is not None
    assert len(pb.investigate) >= 1


def test_notify_skips_without_smtp(monkeypatch: pytest.MonkeyPatch) -> None:
    from src.api.models.incident import IncidentRecord
    from src.incident.notify import notify_incident_status

    monkeypatch.delenv("ALFA_AI_INCIDENT_SMTP_HOST", raising=False)
    monkeypatch.delenv("ALFA_AI_INCIDENT_NOTIFY_EMAIL", raising=False)
    inc = IncidentRecord(
        id="x",
        fingerprint="fp",
        alertname="Test",
        severity="warning",
        status="resolved",
        labels={},
        annotations={},
        raw_payload={},
        summary="ok",
        opened_at="2026-06-25T00:00:00+00:00",
        resolved_at="2026-06-25T00:00:00+00:00",
        last_seen_at="2026-06-25T00:00:00+00:00",
        updated_at="2026-06-25T00:00:00+00:00",
    )
    assert notify_incident_status(inc, reason="test") is False


def test_map_reported_severity_prometheus_labels() -> None:
    from src.incident.alert_ai import map_reported_severity

    assert map_reported_severity("critical") == "critical"
    assert map_reported_severity("error") == "high"
    assert map_reported_severity("warning") == "medium"
    assert map_reported_severity("info") == "low"
    assert map_reported_severity("unknown-label") == "medium"
    assert map_reported_severity("") == "medium"


def test_assess_alert_severity_is_deterministic_no_llm() -> None:
    from src.incident.alert_ai import assess_alert_severity

    critical = IncidentRecord(
        id="1",
        fingerprint="fp",
        alertname="LiteLLMProbeFailed",
        severity="critical",
        status="investigating",
        labels={"severity": "critical"},
        annotations={},
        raw_payload={},
        summary="down",
        opened_at="2026-06-25T00:00:00+00:00",
        resolved_at=None,
        last_seen_at="2026-06-25T00:00:00+00:00",
        updated_at="2026-06-25T00:00:00+00:00",
    )
    a = assess_alert_severity(critical)
    assert a.severity == "critical"
    assert a.notify is True
    assert "Mapped Alertmanager" in a.reason

    warning = IncidentRecord(
        id="2",
        fingerprint="fp2",
        alertname="LiteLLMProbeFailed",
        severity="warning",
        status="investigating",
        labels={"severity": "warning"},
        annotations={},
        raw_payload={},
        summary="flaky",
        opened_at="2026-06-25T00:00:00+00:00",
        resolved_at=None,
        last_seen_at="2026-06-25T00:00:00+00:00",
        updated_at="2026-06-25T00:00:00+00:00",
    )
    b = assess_alert_severity(warning)
    assert b.severity == "medium"
    assert b.notify is False


def test_llm_unknown_triage_defaults_off(monkeypatch: pytest.MonkeyPatch) -> None:
    from src.incident.triage import llm_triage_enabled, triage_unknown_alert

    monkeypatch.delenv("ALFA_AI_INCIDENT_LLM_TRIAGE", raising=False)
    assert llm_triage_enabled() is False
    assert (
        triage_unknown_alert(
            alertname="NoPlaybook",
            severity="warning",
            annotations={},
            investigation={},
        )
        is None
    )

