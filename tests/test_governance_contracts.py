"""Governance contract tests (NIST Wave 5)."""

from __future__ import annotations

import ast
from pathlib import Path

import pytest


_REPO_ROOT = Path(__file__).resolve().parents[1]


def test_guest_chat_payload_has_no_tools() -> None:
    """Guest chat must remain a stateless LiteLLM proxy without tools/RAG."""
    source = (_REPO_ROOT / "src" / "api" / "routers" / "guest.py").read_text(encoding="utf-8")
    assert "tools" not in source
    assert "tool_choice" not in source
    assert "GUEST_SYSTEM_PROMPT" in source
    assert "no access to data" in source.lower() or "no access to" in source.lower()
    assert "cannot search the internet" in source.lower()


def test_alert_ai_module_has_no_llm_imports() -> None:
    """Programmatic alert routing must not import LLM client."""
    tree = ast.parse((_REPO_ROOT / "src" / "incident" / "alert_ai.py").read_text(encoding="utf-8"))
    imports = [
        node.names[0].name
        for node in ast.walk(tree)
        if isinstance(node, ast.ImportFrom) and node.module
    ]
    assert "src.llm.client" not in imports
    assert not any("llm" in (m or "") for m in imports)


def test_llm_triage_defaults_off(monkeypatch: pytest.MonkeyPatch) -> None:
    from src.incident.triage import llm_triage_enabled, triage_unknown_alert

    monkeypatch.delenv("ALFA_AI_INCIDENT_LLM_TRIAGE", raising=False)
    assert llm_triage_enabled() is False
    assert (
        triage_unknown_alert(
            alertname="Unknown",
            severity="warning",
            annotations={},
            investigation={},
        )
        is None
    )


def test_analyze_policy_rejects_secrets() -> None:
    from src.incident.analyze_policy import ProposalPolicyError, validate_file_proposal

    with pytest.raises(ProposalPolicyError):
        validate_file_proposal("docs/INCIDENT_RESPONSE.md", "api_key=sk-secret123")


def test_low_confidence_apply_requires_force(monkeypatch: pytest.MonkeyPatch) -> None:
    from src.api.models.incident import IncidentRecord, IncidentRemediationRecord
    from src.incident.remediate import apply_proposal

    monkeypatch.setenv("ALFA_AI_REMEDIATION_ENABLED", "true")
    incident = IncidentRecord(
        id="inc-1",
        fingerprint="fp",
        alertname="Test",
        severity="warning",
        status="needs_human",
        labels={},
        annotations={},
        raw_payload={},
        summary="x",
        opened_at="2026-06-25T00:00:00+00:00",
        resolved_at=None,
        last_seen_at="2026-06-25T00:00:00+00:00",
        updated_at="2026-06-25T00:00:00+00:00",
    )
    proposal = IncidentRemediationRecord(
        id="prop-1",
        incident_id="inc-1",
        classification="ops_action",
        root_cause="test",
        confidence="low",
        target_repo="alfa-ai",
        target_path=None,
        proposed_change="1. Check logs",
        rationale=None,
        briefing=None,
        status="proposed",
        pr_url=None,
        created_by="test",
        created_at="2026-06-25T00:00:00+00:00",
    )
    blocked = apply_proposal(incident, proposal, force=False)
    assert not blocked.ok
    assert "force" in blocked.message.lower()
