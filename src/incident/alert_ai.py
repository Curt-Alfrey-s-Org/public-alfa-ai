"""Programmatic alert severity routing + conservative settings self-tuning.

Runs inside the background incident worker. Maps Alertmanager severity labels to an
internal scale, decides whether to email the operator directly (threshold / quiet hours /
dedup), records the decision in the AI Actions feed, and may conservatively adjust the
notify severity threshold. No LLM on this path -- see docs/AI_ACTIONS.md.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from datetime import UTC, datetime

from src.api.models.ai_action import (
    ACTION_NOTIFICATION_SENT,
    ACTION_SETTING_SUGGESTION,
    AiActionStore,
)
from src.api.models.ai_setting import (
    SEVERITY_ORDER,
    AiSettingError,
    AiSettingStore,
    program_auto_tune_enabled,
)
from src.api.models.incident import IncidentRecord

logger = logging.getLogger(__name__)

# Common Prometheus / Alertmanager severity label values -> internal scale.
# Convention in the ecosystem is labels such as critical / warning / info (and often error);
# there is no single enforced schema. Map conservatively so unknown labels do not page.
# Refs: Alertmanager routing by severity label; PagerDuty severity set critical|error|warning|info.
_PROMETHEUS_SEVERITY_MAP: dict[str, str] = {
    "critical": "critical",
    "error": "high",
    "warning": "medium",
    "warn": "medium",
    "info": "low",
    "none": "low",
    # Already on internal scale (passthrough).
    "high": "high",
    "medium": "medium",
    "low": "low",
}

# Mapped severities that warrant a direct ops email intent (still gated by ai_settings).
_NOTIFY_AT_OR_ABOVE = "high"


def alert_routing_enabled() -> bool:
    """Env kill switch for programmatic notify routing (no LLM)."""
    raw = (os.getenv("ALFA_AI_ALERT_AI_TRIAGE") or "true").strip().lower()
    return raw in ("1", "true", "yes", "on")


# Back-compat alias used by worker / docs historically named "AI triage".
ai_triage_enabled = alert_routing_enabled


@dataclass(slots=True)
class AlertAssessment:
    severity: str
    notify: bool
    reason: str


def _severity_rank(severity: str) -> int:
    try:
        return SEVERITY_ORDER.index(severity)
    except ValueError:
        return SEVERITY_ORDER.index("medium")


def map_reported_severity(reported: str | None) -> str:
    """Map Alertmanager / Prometheus severity label to internal low|medium|high|critical."""
    key = (reported or "").strip().lower()
    if not key:
        return "medium"
    return _PROMETHEUS_SEVERITY_MAP.get(key, "medium")


def assess_alert_severity(incident: IncidentRecord) -> AlertAssessment:
    """Deterministic severity + notify intent from the alert's own labels (no LLM)."""
    mapped = map_reported_severity(incident.severity)
    notify = _severity_rank(mapped) >= _severity_rank(_NOTIFY_AT_OR_ABOVE)
    reported = (incident.severity or "").strip() or "(none)"
    reason = (
        f"Mapped Alertmanager severity {reported!r} -> {mapped}; "
        f"direct notify intent={'yes' if notify else 'no'} "
        f"(notify at or above {_NOTIFY_AT_OR_ABOVE})."
    )
    return AlertAssessment(severity=mapped, notify=notify, reason=reason)


def _within_quiet_hours(window: str, now: datetime | None = None) -> bool:
    """window is 'HH:MM-HH:MM' (local wall clock). Empty/invalid -> not quiet."""
    window = (window or "").strip()
    if not window or "-" not in window:
        return False
    try:
        start_s, end_s = window.split("-", 1)
        sh, sm = (int(x) for x in start_s.strip().split(":", 1))
        eh, em = (int(x) for x in end_s.strip().split(":", 1))
    except (ValueError, IndexError):
        return False
    ref = now or datetime.now()
    minutes = ref.hour * 60 + ref.minute
    start = sh * 60 + sm
    end = eh * 60 + em
    if start == end:
        return False
    if start < end:
        return start <= minutes < end
    # Overnight window (e.g. 22:00-07:00).
    return minutes >= start or minutes < end


def decide_notification(
    incident: IncidentRecord,
    assessment: AlertAssessment,
    settings: AiSettingStore,
    actions: AiActionStore,
) -> tuple[bool, str]:
    """Return (should_notify, reason). Applies threshold, quiet hours, and dedup."""
    if not assessment.notify:
        return False, "Mapped severity does not warrant a direct notification."

    min_sev = settings.get("notify_min_severity", "high").strip().lower()
    if min_sev not in SEVERITY_ORDER:
        min_sev = "high"
    if _severity_rank(assessment.severity) < _severity_rank(min_sev):
        return False, f"Severity {assessment.severity} below threshold {min_sev}."

    quiet = settings.get("notify_quiet_hours", "")
    if _within_quiet_hours(quiet):
        return False, f"Within quiet hours ({quiet})."

    dedup_minutes = settings.get_int("notify_dedup_minutes", 30)
    if dedup_minutes > 0:
        last = actions.last_notified_at(incident.alertname)
        if last is not None:
            elapsed_min = (datetime.now(tz=UTC) - last).total_seconds() / 60.0
            if elapsed_min < dedup_minutes:
                return False, f"Duplicate within {dedup_minutes}m (last {int(elapsed_min)}m ago)."

    return True, assessment.reason


def maybe_tune_settings(settings: AiSettingStore, actions: AiActionStore) -> None:
    """Conservatively adjust notify_min_severity based on recent notification volume.

    v1 policy (bounded to one key, one step at a time):
      - Too noisy: many notifications in the last hour -> raise threshold one step.
      - Missed-signal: threshold above 'high' with no recent sends -> lower one step.
    Every change is logged to the AI Actions feed and is revertable by the operator.
    Requires ALFA_AI_PROGRAM_AUTO_TUNE=1 and ai_can_adjust_settings=true (both default off).
    When gates are off but volume would trigger a tune, records a suggestion only (no mutation).
    """
    current = settings.get("notify_min_severity", "high").strip().lower()
    if current not in SEVERITY_ORDER:
        current = "high"
    rank = SEVERITY_ORDER.index(current)

    sent = actions.count_recent(ACTION_NOTIFICATION_SENT, minutes=60)

    new_rank = rank
    reason = ""
    # Noisy: raise threshold (make it harder to notify) but never past 'critical'.
    if sent >= 8 and rank < len(SEVERITY_ORDER) - 1:
        new_rank = rank + 1
        reason = f"{sent} direct notifications in the last hour; raising threshold to reduce noise."
    # Very quiet threshold set too high with volume of sends: lower one step toward 'high' min.
    elif sent == 0 and rank > SEVERITY_ORDER.index("high"):
        new_rank = rank - 1
        reason = "No notifications recently and threshold above 'high'; lowering one step."

    if new_rank == rank:
        return

    new_value = SEVERITY_ORDER[new_rank]
    can_apply = program_auto_tune_enabled() and settings.get_bool("ai_can_adjust_settings", False)
    if not can_apply:
        actions.record(
            ACTION_SETTING_SUGGESTION,
            f"Program would adjust notify_min_severity: {current} -> {new_value}",
            detail={
                "key": "notify_min_severity",
                "old_value": current,
                "new_value": new_value,
                "reason": reason,
                "status": "suggestion",
            },
            created_by="program",
        )
        logger.info(
            "program tuning suggestion (not applied) notify_min_severity %s -> %s (%s)",
            current,
            new_value,
            reason,
        )
        return

    try:
        settings.set("notify_min_severity", new_value, updated_by="program", by_ai=True)
    except AiSettingError:
        return
    actions.record(
        "setting_changed",
        f"Program adjusted notify_min_severity: {current} -> {new_value}",
        detail={
            "key": "notify_min_severity",
            "old_value": current,
            "new_value": new_value,
            "reason": reason,
        },
        created_by="program",
    )
    logger.info("program tuned notify_min_severity %s -> %s (%s)", current, new_value, reason)
