"""Background incident worker: investigate firing alerts; programmatic notify routing."""

from __future__ import annotations

import logging
import os
import time

from src.api.models.ai_action import (
    ACTION_ALERT_TRIAGED,
    ACTION_NOTIFICATION_SENT,
    ACTION_NOTIFICATION_SKIPPED,
    AiActionStore,
)
from src.api.models.ai_setting import AiSettingStore
from src.api.models.incident import IncidentStore
from src.api.incident_metrics import record_autofix_attempt, record_notification
from src.incident.alert_ai import (
    ai_triage_enabled,
    assess_alert_severity,
    decide_notification,
    maybe_tune_settings,
)
from src.incident.investigate import (
    auto_fix_allowed_for_alert,
    auto_fix_enabled,
    investigate_incident,
    run_playbook_steps,
)
from src.incident.notify import notify_incident_status, notify_user_alert
from src.incident.playbooks import get_playbook
from src.incident.queue import pop_incident
from src.incident.rate_limit import auto_fix_rate_limit_ok
from src.incident.triage import triage_unknown_alert

logger = logging.getLogger(__name__)

_POLL_SEC = max(2, int(os.getenv("ALFA_AI_INCIDENT_WORKER_POLL_SEC", "5") or "5"))


def _database_url() -> str:
    url = (os.getenv("DATABASE_URL") or "").strip()
    if not url:
        raise RuntimeError("DATABASE_URL is required for incident worker")
    return url


def run_alert_triage(
    incident_id: str,
    store: IncidentStore,
    actions: AiActionStore,
    settings: AiSettingStore,
) -> None:
    """Programmatic severity routing: record decision, email if serious, tune settings.

    Additive to the incident lifecycle; failures never block investigation. See docs/AI_ACTIONS.md.
    No LLM on this path.
    """
    if not ai_triage_enabled() or not settings.get_bool("ai_triage_enabled", True):
        return
    incident = store.get_by_id(incident_id)
    if incident is None:
        return

    assessment = assess_alert_severity(incident)
    actions.record(
        ACTION_ALERT_TRIAGED,
        f"{incident.alertname}: mapped severity {assessment.severity}",
        detail={
            "alertname": incident.alertname,
            "mapped_severity": assessment.severity,
            "reported_severity": incident.severity,
            "notify": assessment.notify,
            "reason": assessment.reason,
            "router": "program",
        },
        severity=assessment.severity,
        incident_id=incident_id,
        created_by="program",
    )

    should_notify, reason = decide_notification(incident, assessment, settings, actions)
    if should_notify:
        to_email = settings.get("notify_email", "").strip() or None
        sent = notify_user_alert(
            incident,
            severity=assessment.severity,
            reason=assessment.reason,
            to_email=to_email,
        )
        actions.record(
            ACTION_NOTIFICATION_SENT if sent else ACTION_NOTIFICATION_SKIPPED,
            (
                f"Emailed you: {incident.alertname} ({assessment.severity})"
                if sent
                else f"Notify attempted but SMTP not configured: {incident.alertname}"
            ),
            detail={
                "alertname": incident.alertname,
                "mapped_severity": assessment.severity,
                "reason": assessment.reason,
                "sent": sent,
            },
            severity=assessment.severity,
            incident_id=incident_id,
            created_by="program",
        )
        record_notification("sent" if sent else "skipped_smtp")
    else:
        actions.record(
            ACTION_NOTIFICATION_SKIPPED,
            f"Held notification for {incident.alertname}: {reason}",
            detail={
                "alertname": incident.alertname,
                "mapped_severity": assessment.severity,
                "reason": reason,
            },
            severity=assessment.severity,
            incident_id=incident_id,
            created_by="program",
        )
        record_notification("skipped")

    maybe_tune_settings(settings, actions)


def process_incident(
    store: IncidentStore,
    incident_id: str,
    ai_actions: AiActionStore | None = None,
    ai_settings: AiSettingStore | None = None,
) -> None:
    incident = store.get_by_id(incident_id)
    if incident is None:
        logger.warning("incident worker: missing incident %s", incident_id)
        return
    if incident.status not in ("received", "investigating"):
        logger.info("incident worker: skip %s status=%s", incident_id, incident.status)
        return

    if incident.status == "received":
        incident = store.claim_by_id(incident_id) or incident
        if incident.status != "investigating":
            return

    store.record_event(incident_id, "investigation_started", {"alertname": incident.alertname})
    playbook = get_playbook(incident.alertname)
    report = investigate_incident(playbook, incident.alertname)
    store.record_event(incident_id, "investigation_complete", report)

    if ai_actions is not None and ai_settings is not None:
        try:
            run_alert_triage(incident_id, store, ai_actions, ai_settings)
        except Exception:
            logger.exception("alert triage failed for %s", incident_id)

    next_status = "needs_human"
    summary = report.get("summary") if isinstance(report.get("summary"), str) else None

    if not playbook:
        llm_note = triage_unknown_alert(
            alertname=incident.alertname,
            severity=incident.severity,
            annotations=incident.annotations,
            investigation=report,
        )
        if llm_note:
            store.record_event(incident_id, "llm_triage", {"summary": llm_note})
            summary = llm_note

    if playbook and auto_fix_allowed_for_alert(incident.alertname, ai_settings) and playbook.auto_fix:
        allowed, limit_reason = auto_fix_rate_limit_ok(incident.alertname)
        if not allowed:
            store.record_event(incident_id, "remediation_skipped", {"reason": limit_reason})
            summary = limit_reason
            record_autofix_attempt("rate_limited")
        else:
            store.record_event(incident_id, "remediation_started", {"steps": len(playbook.auto_fix)})
            fix_results = run_playbook_steps(playbook.auto_fix)
            store.record_event(incident_id, "remediation_complete", {"steps": fix_results})
            if all(item.get("result", {}).get("ok") for item in fix_results):
                verify_results = run_playbook_steps(playbook.investigate)
                if verify_results and all(item.get("result", {}).get("ok") for item in verify_results):
                    next_status = "resolved"
                    summary = f"Auto-fix verified for {incident.alertname}."
                    record_autofix_attempt("verified")
                else:
                    summary = f"Auto-fix ran but verification failed for {incident.alertname}."
                    record_autofix_attempt("verify_failed")
            else:
                summary = f"Auto-fix failed for {incident.alertname}."
                record_autofix_attempt("failed")

    store.update_status(incident_id, next_status, summary=summary)
    store.record_event(
        incident_id,
        "status_changed",
        {"status": next_status, "summary": summary},
    )
    updated = store.get_by_id(incident_id)
    if updated and next_status in ("resolved", "needs_human"):
        notify_incident_status(updated, reason="incident worker finished")
    logger.info("incident worker: %s -> %s", incident_id, next_status)


def run_worker_loop() -> None:
    database_url = _database_url()
    store = IncidentStore(database_url=database_url)
    ai_actions = AiActionStore(database_url=database_url)
    ai_settings = AiSettingStore(database_url=database_url)
    logger.info(
        "incident worker started (auto_fix=%s alert_routing=%s llm_unknown_triage=%s)",
        auto_fix_enabled(),
        ai_triage_enabled(),
        (os.getenv("ALFA_AI_INCIDENT_LLM_TRIAGE") or "false").strip().lower()
        in ("1", "true", "yes", "on"),
    )
    while True:
        incident_id = pop_incident(timeout_sec=_POLL_SEC)
        if incident_id:
            try:
                process_incident(store, incident_id, ai_actions, ai_settings)
            except Exception:
                logger.exception("incident worker failed for %s", incident_id)
            continue

        claimed = store.claim_next_received()
        if claimed:
            try:
                process_incident(store, claimed.id, ai_actions, ai_settings)
            except Exception:
                logger.exception("incident worker failed for claimed %s", claimed.id)
            continue

        time.sleep(1)


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    run_worker_loop()


if __name__ == "__main__":
    main()
