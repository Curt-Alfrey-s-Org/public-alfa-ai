"""Generic SMTP email helper for account lifecycle emails (verification, etc.).

Reuses the incident SMTP relay by default (ALFA_AI_INCIDENT_SMTP_*) since most
deployments only configure one relay. Set ALFA_AI_SMTP_* to point account
emails at a different relay/from-address than incident alerts. See
docs/AUTH_ACCOUNT_LIFECYCLE.md.
"""

from __future__ import annotations

import logging
import os
import smtplib
from email.message import EmailMessage

logger = logging.getLogger(__name__)


def _env(name: str, fallback_name: str, default: str = "") -> str:
    v = (os.getenv(name) or "").strip()
    if v:
        return v
    return (os.getenv(fallback_name) or default).strip()


def smtp_configured() -> bool:
    return bool(_env("ALFA_AI_SMTP_HOST", "ALFA_AI_INCIDENT_SMTP_HOST"))


def public_base_url() -> str:
    return (os.getenv("ALFA_AI_PUBLIC_URL") or "https://www.example.com").rstrip("/")


def send_email(to_addr: str, subject: str, body: str) -> bool:
    """Send a plain-text email via the configured SMTP relay.

    Never raises -- logs and returns False if unconfigured or the send fails, so
    callers (e.g. registration) can proceed without blocking on mail delivery.
    """
    to_addr = (to_addr or "").strip()
    host = _env("ALFA_AI_SMTP_HOST", "ALFA_AI_INCIDENT_SMTP_HOST")
    if not host or not to_addr:
        logger.warning("send_email skipped: SMTP not configured or missing recipient")
        return False
    port = int(_env("ALFA_AI_SMTP_PORT", "ALFA_AI_INCIDENT_SMTP_PORT", "587") or "587")
    user = _env("ALFA_AI_SMTP_USER", "ALFA_AI_INCIDENT_SMTP_USER")
    password = _env("ALFA_AI_SMTP_PASSWORD", "ALFA_AI_INCIDENT_SMTP_PASSWORD")
    from_addr = _env("ALFA_AI_SMTP_FROM", "ALFA_AI_INCIDENT_SMTP_FROM") or user or "alfa-ai@localhost"
    use_tls = _env("ALFA_AI_SMTP_TLS", "ALFA_AI_INCIDENT_SMTP_TLS", "true").lower() in (
        "1", "true", "yes", "on",
    )

    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = from_addr
    msg["To"] = to_addr
    msg.set_content(body)
    try:
        with smtplib.SMTP(host, port, timeout=30) as smtp:
            if use_tls:
                smtp.starttls()
            if user and password:
                smtp.login(user, password)
            smtp.send_message(msg)
        return True
    except Exception:
        logger.exception("send_email failed to=%s subject=%s", to_addr, subject)
        return False
