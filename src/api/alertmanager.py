"""Parse Alertmanager webhook payloads (Prometheus Alerting)."""

from __future__ import annotations

from typing import Any


def normalize_alertmanager_webhook(body: dict[str, Any]) -> list[dict[str, Any]]:
    """Extract normalized alert dicts from an Alertmanager webhook POST body.

    Spec: https://prometheus.io/docs/alerting/latest/notifications/#webhook
    """
    alerts = body.get("alerts")
    if not isinstance(alerts, list):
        return []

    group_status = str(body.get("status") or "").strip().lower()
    receiver = str(body.get("receiver") or "")
    group_key = str(body.get("groupKey") or body.get("group_key") or "")

    normalized: list[dict[str, Any]] = []
    for item in alerts:
        if not isinstance(item, dict):
            continue
        labels = item.get("labels") if isinstance(item.get("labels"), dict) else {}
        annotations = item.get("annotations") if isinstance(item.get("annotations"), dict) else {}
        alert_status = str(item.get("status") or group_status or "firing").strip().lower()
        fingerprint = str(item.get("fingerprint") or "").strip()
        if not fingerprint:
            alertname = str(labels.get("alertname") or "unknown")
            instance = str(labels.get("instance") or labels.get("job") or "")
            fingerprint = f"{group_key}:{alertname}:{instance}"[:512]

        normalized.append(
            {
                "fingerprint": fingerprint,
                "alertname": str(labels.get("alertname") or "unknown"),
                "severity": str(labels.get("severity") or "unknown"),
                "status": alert_status,
                "labels": labels,
                "annotations": annotations,
                "starts_at": item.get("startsAt") or item.get("starts_at"),
                "ends_at": item.get("endsAt") or item.get("ends_at"),
                "generator_url": item.get("generatorURL") or item.get("generator_url"),
                "receiver": receiver,
                "group_key": group_key,
                "raw_alert": item,
            }
        )
    return normalized
