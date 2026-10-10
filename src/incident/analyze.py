"""On-demand LLM analysis for admin Monitoring tab proposals."""

from __future__ import annotations

import base64
import json
import logging
import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import httpx

from src.api.models.incident import IncidentEventRecord, IncidentRecord, IncidentRemediationRecord
from src.incident.analyze_policy import ProposalPolicyError, validate_file_proposal
from src.incident.investigate import investigate_incident
from src.incident.playbooks import get_playbook, playbook_source_path

logger = logging.getLogger(__name__)

_REPO_ROOT = Path(__file__).resolve().parents[2]

_VALID_CLASSIFICATIONS: frozenset[str] = frozenset({"alert_tuning", "code_fix", "ops_action"})
_VALID_CONFIDENCE: frozenset[str] = frozenset({"high", "medium", "low"})

# Known monitoring rule paths (alertname -> repo-relative path).
_MONITORING_RULE_PATHS: dict[str, str] = {
    "AlfaAiBrainHealthDown": "prometheus/rules/alfa-ai-brain.yaml",
    "LiteLLMProbeFailed": "prometheus/rules/litellm.yaml",
    "AlfaAiPostgresBackupStale": "prometheus/rules/postgres-backup.yaml",
}


@dataclass(slots=True)
class AnalysisBriefing:
    evidence: list[str] = field(default_factory=list)
    ranked_causes: list[str] = field(default_factory=list)
    suggested_actions: list[str] = field(default_factory=list)
    blast_radius: str = ""
    runbook_links: list[str] = field(default_factory=list)
    copy_for_verifier: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {
            "evidence": self.evidence,
            "ranked_causes": self.ranked_causes,
            "suggested_actions": self.suggested_actions,
            "blast_radius": self.blast_radius,
            "runbook_links": self.runbook_links,
            "copy_for_verifier": self.copy_for_verifier,
        }


@dataclass(slots=True)
class AnalysisResult:
    classification: str
    root_cause: str
    confidence: str
    target_repo: str
    target_path: str | None
    proposed_change: str
    rationale: str | None
    briefing: AnalysisBriefing


def _github_token() -> str:
    return (os.getenv("ALFA_AI_REMEDIATION_GITHUB_TOKEN") or "").strip()


def _repo_slug(name: str) -> str:
    if name == "monitoring":
        return (os.getenv("ALFA_AI_REMEDIATION_MONITORING_REPO") or "example/monitoring").strip()
    return (os.getenv("ALFA_AI_REMEDIATION_ALFA_REPO") or "example/alfa-ai").strip()


def _fetch_github_file(repo_slug: str, path: str) -> str | None:
    token = _github_token()
    if not token or not path:
        return None
    url = f"https://api.github.com/repos/{repo_slug}/contents/{path.lstrip('/')}"
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    try:
        with httpx.Client(timeout=30) as client:
            response = client.get(url, headers=headers)
            if response.status_code == 404:
                return None
            response.raise_for_status()
            data = response.json()
        content_b64 = data.get("content")
        if not content_b64:
            return None
        raw = base64.b64decode(content_b64).decode("utf-8", errors="replace")
        return raw[:12000]
    except Exception:
        logger.exception("failed to fetch GitHub file %s/%s", repo_slug, path)
        return None


def _fetch_local_file(path: str) -> str | None:
    if not path:
        return None
    file_path = (_REPO_ROOT / path.lstrip("/")).resolve()
    try:
        file_path.relative_to(_REPO_ROOT.resolve())
    except ValueError:
        return None
    if not file_path.is_file():
        return None
    try:
        return file_path.read_text(encoding="utf-8")[:12000]
    except OSError:
        return None


def _investigation_from_events(events: list[IncidentEventRecord]) -> dict[str, Any] | None:
    for event in reversed(events):
        if event.event_type == "investigation_complete" and isinstance(event.payload, dict):
            return event.payload
    return None


def _runbook_links(incident: IncidentRecord) -> list[str]:
    links: list[str] = []
    for key in ("runbook_url", "runbook", "dashboard"):
        val = incident.annotations.get(key) or incident.labels.get(key)
        if val and str(val).strip():
            links.append(str(val).strip())
    links.append("docs/INCIDENT_RESPONSE.md")
    links.append("docs/MONITORING_AI_REVIEW.md")
    return links


def _build_context_files(
    incident: IncidentRecord,
    *,
    investigation: dict[str, Any],
) -> list[tuple[str, str, str | None]]:
    """Return (repo_key, path, content_preview) tuples for the LLM."""
    out: list[tuple[str, str, str | None]] = []
    alertname = incident.alertname
    playbook = get_playbook(alertname)
    playbook_path = playbook_source_path(alertname)
    if playbook_path:
        out.append(("alfa-ai", playbook_path, _fetch_local_file(playbook_path)))
    elif playbook:
        out.append(("alfa-ai", f"deploy/incident-playbooks/{alertname}.yaml", None))

    if alertname in ("LiteLLMProbeFailed", "AlfaAiBrainHealthDown"):
        out.append(("alfa-ai", "deploy/docker-compose.yml", _fetch_local_file("deploy/docker-compose.yml")))

    monitoring_path = _MONITORING_RULE_PATHS.get(alertname) or f"prometheus/rules/{alertname}.yaml"
    monitoring_content = _fetch_github_file(_repo_slug("monitoring"), monitoring_path)
    if monitoring_content:
        out.append(("monitoring", monitoring_path, monitoring_content))
    else:
        out.append(("monitoring", monitoring_path, None))

    if investigation.get("steps"):
        out.append(("investigation", "worker/playbook-steps", json.dumps(investigation["steps"])[:8000]))
    return out


def _extract_json_object(text: str) -> dict[str, Any] | None:
    text = text.strip()
    if not text:
        return None
    try:
        parsed = json.loads(text)
        if isinstance(parsed, dict):
            return parsed
    except json.JSONDecodeError:
        pass
    match = re.search(r"\{[\s\S]*\}", text)
    if not match:
        return None
    try:
        parsed = json.loads(match.group(0))
        if isinstance(parsed, dict):
            return parsed
    except json.JSONDecodeError:
        return None
    return None


def _build_briefing(raw: dict[str, Any], incident: IncidentRecord, investigation: dict[str, Any]) -> AnalysisBriefing:
    evidence = raw.get("evidence")
    causes = raw.get("ranked_causes") or raw.get("possible_causes")
    actions = raw.get("suggested_actions") or raw.get("actions")
    blast = str(raw.get("blast_radius") or "").strip()
    verifier = str(raw.get("copy_for_verifier") or "").strip()
    if not verifier:
        verifier = (
            f"Alert {incident.alertname} ({incident.severity}). "
            f"Investigation: {investigation.get('summary', 'n/a')}. "
            f"Root cause hypothesis: {raw.get('root_cause', 'unknown')}. "
            "Please verify before any mutating action."
        )
    return AnalysisBriefing(
        evidence=[str(x) for x in evidence][:8] if isinstance(evidence, list) else [],
        ranked_causes=[str(x) for x in causes][:5] if isinstance(causes, list) else [],
        suggested_actions=[str(x) for x in actions][:8] if isinstance(actions, list) else [],
        blast_radius=blast[:1000],
        runbook_links=_runbook_links(incident),
        copy_for_verifier=verifier[:4000],
    )


def _normalize_analysis(
    raw: dict[str, Any],
    *,
    incident: IncidentRecord,
    investigation: dict[str, Any],
) -> AnalysisResult | None:
    classification = str(raw.get("classification") or "").strip().lower()
    if classification not in _VALID_CLASSIFICATIONS:
        classification = "ops_action"
    confidence = str(raw.get("confidence") or "medium").strip().lower()
    if confidence not in _VALID_CONFIDENCE:
        confidence = "medium"
    target_repo = str(raw.get("target_repo") or "alfa-ai").strip().lower()
    if target_repo not in ("alfa-ai", "monitoring"):
        target_repo = "alfa-ai"
    target_path = raw.get("target_path")
    if target_path is not None:
        target_path = str(target_path).strip() or None

    briefing = _build_briefing(raw, incident, investigation)
    suggested = briefing.suggested_actions
    proposed_change = str(raw.get("proposed_change") or "").strip()
    if not proposed_change and suggested:
        proposed_change = "\n".join(f"{i + 1}. {step}" for i, step in enumerate(suggested))
    if not proposed_change:
        return None

    if classification != "ops_action":
        try:
            validate_file_proposal(target_path, proposed_change)
        except ProposalPolicyError as exc:
            classification = "ops_action"
            target_path = None
            proposed_change = "\n".join(
                [
                    f"Policy blocked file proposal: {exc}",
                    *([f"{i + 1}. {step}" for i, step in enumerate(suggested)] if suggested else [
                        "1. Review incident timeline and Grafana dashboards.",
                        "2. Apply fix manually after operator verification.",
                    ]),
                ]
            )
            confidence = "low"

    root_cause = str(raw.get("root_cause") or "").strip() or "Unknown root cause."
    rationale = raw.get("rationale")
    rationale_str = str(rationale).strip() if rationale else None
    return AnalysisResult(
        classification=classification,
        root_cause=root_cause[:4000],
        confidence=confidence,
        target_repo=target_repo,
        target_path=target_path,
        proposed_change=proposed_change[:50000],
        rationale=rationale_str[:4000] if rationale_str else None,
        briefing=briefing,
    )


def _fallback_ops_result(incident: IncidentRecord, investigation: dict[str, Any], note: str) -> AnalysisResult:
    briefing = AnalysisBriefing(
        evidence=[investigation.get("summary", "Investigation summary unavailable.")],
        ranked_causes=[note],
        suggested_actions=[
            "Review incident timeline in admin Monitoring tab.",
            "Check Grafana dashboards on monitoring host.",
            "Follow docs/INCIDENT_RESPONSE.md before any mutating action.",
        ],
        blast_radius="Cluster operator console and dependent consumer bots if brain/LiteLLM affected.",
        runbook_links=_runbook_links(incident),
        copy_for_verifier=(
            f"Alert {incident.alertname}. {note} Investigation summary: "
            f"{investigation.get('summary', 'n/a')}"
        ),
    )
    return AnalysisResult(
        classification="ops_action",
        root_cause=note[:500],
        confidence="low",
        target_repo="alfa-ai",
        target_path=None,
        proposed_change="\n".join(f"{i + 1}. {s}" for i, s in enumerate(briefing.suggested_actions)),
        rationale="Automatic analysis fallback; operator verification required.",
        briefing=briefing,
    )


def analyze_incident(
    incident: IncidentRecord,
    *,
    events: list[IncidentEventRecord] | None = None,
) -> AnalysisResult:
    """Run LLM analysis and return a structured remediation proposal."""
    from src.llm.client import get_completion

    playbook = get_playbook(incident.alertname)
    stored_investigation = _investigation_from_events(events or [])
    investigation = stored_investigation or investigate_incident(playbook, incident.alertname)
    context_files = _build_context_files(incident, investigation=investigation)
    file_blocks: list[str] = []
    for repo_key, path, content in context_files:
        if content:
            file_blocks.append(f"--- {repo_key}:{path} ---\n{content[:8000]}")
        else:
            file_blocks.append(f"--- {repo_key}:{path} --- (not loaded)")

    system = (
        "You are a cluster SRE assistant for ALFa AI. Respond with a single JSON object only, "
        "no markdown fences. Prefer ops_action with numbered operator steps unless you have loaded "
        "file context for a safe alert_tuning or code_fix. Keys: classification "
        "(alert_tuning|code_fix|ops_action), root_cause, confidence (high|medium|low), "
        "target_repo (alfa-ai|monitoring), target_path (relative path or null), proposed_change "
        "(full file for file fixes OR numbered ops steps), rationale, evidence (string array), "
        "ranked_causes (string array), suggested_actions (string array), blast_radius, "
        "copy_for_verifier (paragraph for a stronger model to dual-check)."
    )
    user = (
        f"Alert: {incident.alertname}\n"
        f"Severity: {incident.severity}\n"
        f"Status: {incident.status}\n"
        f"Labels: {json.dumps(incident.labels, ensure_ascii=True)[:2000]}\n"
        f"Annotations: {json.dumps(incident.annotations, ensure_ascii=True)[:2000]}\n"
        f"Investigation: {json.dumps(investigation, ensure_ascii=True)[:6000]}\n"
        f"Context files:\n" + "\n".join(file_blocks)
    )
    messages = [
        {"role": "system", "content": system},
        {"role": "user", "content": user},
    ]
    try:
        reply = get_completion(messages, max_tokens=4096).strip()
    except Exception as exc:
        logger.exception("analyze_incident LLM failed for %s", incident.id)
        return _fallback_ops_result(incident, investigation, f"LLM analysis failed: {exc!s}")

    parsed = _extract_json_object(reply)
    if parsed:
        normalized = _normalize_analysis(parsed, incident=incident, investigation=investigation)
        if normalized:
            return normalized

    return _fallback_ops_result(
        incident,
        investigation,
        "Could not parse structured LLM response; raw output preserved as ops steps.",
    )


def analysis_to_remediation_record(
    incident_id: str,
    analysis: AnalysisResult,
    *,
    created_by: str | None,
    store,
) -> IncidentRemediationRecord:
    return store.save_proposal(
        incident_id=incident_id,
        classification=analysis.classification,  # type: ignore[arg-type]
        root_cause=analysis.root_cause,
        confidence=analysis.confidence,
        target_repo=analysis.target_repo,
        target_path=analysis.target_path,
        proposed_change=analysis.proposed_change,
        rationale=analysis.rationale,
        briefing=analysis.briefing.to_dict(),
        created_by=created_by,
    )
