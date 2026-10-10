"""Operator email notifications for incident lifecycle events."""

from __future__ import annotations

import logging
import os
import smtplib
from email.message import EmailMessage
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from src.api.models.incident import IncidentRecord

logger = logging.getLogger(__name__)


def _smtp_configured(to_override: str | None = None) -> bool:
    host = (os.getenv("ALFA_AI_INCIDENT_SMTP_HOST") or "").strip()
    to_addr = (to_override or os.getenv("ALFA_AI_INCIDENT_NOTIFY_EMAIL") or "").strip()
    return bool(host and to_addr)


def _build_message(subject: str, body: str, *, to_override: str | None = None) -> EmailMessage:
    from_addr = (
        (os.getenv("ALFA_AI_INCIDENT_SMTP_FROM") or "").strip()
        or (os.getenv("ALFA_AI_INCIDENT_SMTP_USER") or "").strip()
        or "alfa-ai-incidents@localhost"
    )
    to_addr = (to_override or os.getenv("ALFA_AI_INCIDENT_NOTIFY_EMAIL") or "").strip()
    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = from_addr
    msg["To"] = to_addr
    msg.set_content(body)
    return msg


def _send(msg: EmailMessage) -> bool:
    host = (os.getenv("ALFA_AI_INCIDENT_SMTP_HOST") or "").strip()
    port = int((os.getenv("ALFA_AI_INCIDENT_SMTP_PORT") or "587").strip() or "587")
    user = (os.getenv("ALFA_AI_INCIDENT_SMTP_USER") or "").strip()
    password = (os.getenv("ALFA_AI_INCIDENT_SMTP_PASSWORD") or "").strip()
    use_tls = (os.getenv("ALFA_AI_INCIDENT_SMTP_TLS", "true").strip().lower() in ("1", "true", "yes", "on"))
    with smtplib.SMTP(host, port, timeout=30) as smtp:
        if use_tls:
            smtp.starttls()
        if user and password:
            smtp.login(user, password)
        smtp.send_message(msg)
    return True


def notify_user_alert(
    incident: "IncidentRecord",
    *,
    severity: str,
    reason: str,
    to_email: str | None = None,
) -> bool:
    """Send a direct, AI-authored alert email when the AI judges an alert serious.

    Distinct from notify_incident_status (subject/body) so the operator can tell an
    AI-triaged page apart from the monitoring stack's own emails. See docs/AI_ACTIONS.md.
    """
    to_addr = (to_email or os.getenv("ALFA_AI_INCIDENT_NOTIFY_EMAIL") or "").strip()
    if not _smtp_configured(to_addr):
        logger.debug("user alert notify skipped: SMTP not configured")
        return False

    subject = f"[ALFa AI] Serious: {incident.alertname}"
    summary = (incident.summary or incident.annotations.get("summary") or "").strip()
    body_lines = [
        "ALFa AI flagged this alert as serious and is notifying you directly.",
        "",
        f"Alert: {incident.alertname}",
        f"AI severity: {severity}",
        f"Reported severity: {incident.severity}",
        f"AI reason: {reason}",
        "",
    ]
    if summary:
        body_lines.extend(["Summary:", summary, ""])
    body_lines.extend(
        [
            "Review in Admin -> AI Actions on the ALFa AI console.",
            "",
            f"Incident ID: {incident.id}",
            f"Fingerprint: {incident.fingerprint}",
        ]
    )
    try:
        msg = _build_message(subject, "\n".join(body_lines), to_override=to_addr)
        _send(msg)
        logger.info("user alert notify sent alert=%s severity=%s", incident.alertname, severity)
        return True
    except Exception:
        logger.exception("user alert notify failed for %s", incident.id)
        return False


def notify_incident_status(incident: IncidentRecord, *, reason: str) -> bool:
    """Send operator email when an incident reaches a terminal or action-needed state."""
    if not _smtp_configured():
        logger.debug("incident notify skipped: SMTP not configured")
        return False

    host = (os.getenv("ALFA_AI_INCIDENT_SMTP_HOST") or "").strip()
    port = int((os.getenv("ALFA_AI_INCIDENT_SMTP_PORT") or "587").strip() or "587")
    user = (os.getenv("ALFA_AI_INCIDENT_SMTP_USER") or "").strip()
    password = (os.getenv("ALFA_AI_INCIDENT_SMTP_PASSWORD") or "").strip()
    use_tls = (os.getenv("ALFA_AI_INCIDENT_SMTP_TLS", "true").strip().lower() in ("1", "true", "yes", "on"))

    status = incident.status
    if status == "resolved":
        subject = f"[ALFa AI] Fixed: {incident.alertname}"
    elif status == "needs_human":
        subject = f"[ALFa AI] Action needed: {incident.alertname}"
    else:
        subject = f"[ALFa AI] Incident update: {incident.alertname}"

    summary = (incident.summary or incident.annotations.get("summary") or "").strip()
    body_lines = [
        f"Alert: {incident.alertname}",
        f"Severity: {incident.severity}",
        f"Status: {status}",
        f"Reason: {reason}",
        "",
    ]
    if summary:
        body_lines.extend(["Summary:", summary, ""])
    body_lines.extend(
        [
            "Review in Admin -> Incidents on the ALFa AI console.",
            "",
            f"Incident ID: {incident.id}",
            f"Fingerprint: {incident.fingerprint}",
        ]
    )
    body = "\n".join(body_lines)

    try:
        msg = _build_message(subject, body)
        with smtplib.SMTP(host, port, timeout=30) as smtp:
            if use_tls:
                smtp.starttls()
            if user and password:
                smtp.login(user, password)
            smtp.send_message(msg)
        logger.info("incident notify sent status=%s alert=%s", status, incident.alertname)
        return True
    except Exception:
        logger.exception("incident notify failed for %s", incident.id)
        return False
