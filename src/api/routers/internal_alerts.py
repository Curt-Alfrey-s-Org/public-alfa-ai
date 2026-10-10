"""Internal Alertmanager webhook ingest (LAN-only, shared secret)."""

from __future__ import annotations

import hmac
import logging
import os
from typing import Any

from fastapi import APIRouter, Depends, Header, HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field

from src.api.alertmanager import normalize_alertmanager_webhook
from src.api.deps import get_incident_store
from src.api.incident_network import expected_alert_webhook_token, require_alert_webhook_network
from src.api.models.incident import IncidentStore
from src.api.public_errors import SERVICE_UNAVAILABLE
from src.incident.notify import notify_incident_status
from src.incident.queue import enqueue_incident

logger = logging.getLogger(__name__)

router = APIRouter(
    prefix="/alfa-ai/api/internal",
    tags=["internal"],
    dependencies=[Depends(require_alert_webhook_network)],
)


class AlertmanagerWebhookBody(BaseModel):
    model_config = ConfigDict(extra="allow")

    version: str | None = None
    status: str | None = None
    receiver: str | None = None
    groupKey: str | None = None
    alerts: list[dict[str, Any]] = Field(default_factory=list)


def verify_alert_webhook_token(
    x_alfa_alert_token: str | None = Header(None, alias="X-Alfa-Alert-Token"),
    authorization: str | None = Header(None),
) -> None:
    expected = expected_alert_webhook_token()
    if not expected:
        logger.error("ALFA_AI_ALERT_WEBHOOK_TOKEN is not configured")
        raise HTTPException(status_code=503, detail=SERVICE_UNAVAILABLE)

    got = (x_alfa_alert_token or "").strip()
    if not got and authorization and authorization.startswith("Bearer "):
        got = authorization[7:].strip()
    if not got or not hmac.compare_digest(got.encode(), expected.encode()):
        logger.warning("alert webhook: invalid token")
        raise HTTPException(status_code=403, detail=SERVICE_UNAVAILABLE)


@router.post("/alerts")
def ingest_alertmanager_webhook(
    body: AlertmanagerWebhookBody,
    request: Request,
    store: IncidentStore = Depends(get_incident_store),
    _auth: None = Depends(verify_alert_webhook_token),
) -> dict[str, Any]:
    """Accept Alertmanager webhook POST; upsert incidents by fingerprint."""
    payload = body.model_dump()
    normalized = normalize_alertmanager_webhook(payload)
    if not normalized:
        logger.info("alert webhook: empty alerts list from %s", request.client)
        return {"ok": True, "processed": 0, "queued": 0}

    processed = 0
    queued = 0
    incident_ids: list[str] = []

    for alert in normalized:
        incident, should_queue = store.upsert_from_alert(
            fingerprint=alert["fingerprint"],
            alertname=alert["alertname"],
            severity=alert["severity"],
            alert_status=alert["status"],
            labels=alert["labels"],
            annotations=alert["annotations"],
            raw_alert=alert["raw_alert"],
        )
        store.record_event(
            incident.id,
            "webhook_received",
            {
                "status": alert["status"],
                "alertname": alert["alertname"],
                "severity": alert["severity"],
                "receiver": alert.get("receiver"),
            },
        )
        processed += 1
        incident_ids.append(incident.id)

        if alert["status"] == "resolved":
            store.record_event(incident.id, "alert_resolved", {})
            refreshed = store.get_by_id(incident.id)
            if refreshed:
                notify_incident_status(refreshed, reason="Alertmanager resolved")
            continue

        if should_queue and os.getenv("ALFA_AI_INCIDENT_QUEUE", "true").strip().lower() not in (
            "0",
            "false",
            "no",
            "off",
        ):
            try:
                enqueue_incident(incident.id)
                queued += 1
            except Exception:
                logger.exception("failed to enqueue incident %s", incident.id)

    logger.info(
        "alert webhook processed=%s queued=%s receiver=%s",
        processed,
        queued,
        body.receiver,
    )
    return {"ok": True, "processed": processed, "queued": queued, "incident_ids": incident_ids}
