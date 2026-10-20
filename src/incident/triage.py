"""Optional LLM triage when no playbook matches (opt-in; default off).

Uses inference slots. Prefer playbooks + programmatic routing; enable only when
you want a model summary for unknown alertnames. See docs/AI_ACTIONS.md.
"""

from __future__ import annotations

import json
import logging
import os
from typing import Any

logger = logging.getLogger(__name__)


def llm_triage_enabled() -> bool:
    raw = (os.getenv("ALFA_AI_INCIDENT_LLM_TRIAGE") or "false").strip().lower()
    return raw in ("1", "true", "yes", "on")


def triage_unknown_alert(
    *,
    alertname: str,
    severity: str,
    annotations: dict[str, Any],
    investigation: dict[str, Any],
) -> str | None:
    if not llm_triage_enabled():
        return None
    try:
        from src.llm.client import get_completion
    except Exception:
        logger.exception("LLM triage import failed")
        return None

    prompt = (
        "You are a cluster SRE assistant. An alert fired with no registered playbook.\n"
        f"alertname={alertname}\n"
        f"severity={severity}\n"
        f"annotations={json.dumps(annotations, ensure_ascii=True)[:2000]}\n"
        f"investigation={json.dumps(investigation, ensure_ascii=True)[:4000]}\n"
        "Reply in 3-5 sentences: likely cause, what logs to check, and whether a human must act now."
    )
    messages = [
        {"role": "system", "content": "Be concise and actionable. No markdown."},
        {"role": "user", "content": prompt},
    ]
    try:
        reply = get_completion(messages).strip()
        return reply[:4000] if reply else None
    except Exception:
        logger.exception("LLM triage failed for alert %s", alertname)
        return None
