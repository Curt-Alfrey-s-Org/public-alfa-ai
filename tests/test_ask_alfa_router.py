"""Unit tests for Ask ALFa deterministic intent router.

Structured prompts must never invoke get_agent_completion; monitoring_agent
short-circuits when try_handle_deterministic returns a dict (see
tests/test_monitoring_agent_hybrid.py).
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock

import pytest

from src.api.ask_alfa_router import parse_draft_judge_task, try_handle_deterministic
from src.api.models.ai_setting import AiSettingError, validate_setting_value

STRUCTURED_NO_LLM_PROMPTS = (
    "Propose docker_ps on host 111. Read-only only.",
    "Propose run_command on host 148 to run: docker restart llamacpp-rpc-coordinator",
    "Set notify_min_severity to critical",
    (
        "Reply with exactly three lines:\n"
        "1) notify_min_severity=\n"
        "2) notify_dedup_minutes=\n"
        "3) host_actions_enabled="
    ),
)


@dataclass
class _FakeHostRecord:
    id: str
    summary: str


def _sample_context() -> dict[str, Any]:
    return {
        "host_actions_enabled": True,
        "user_count": 2,
        "ai_settings": [
            {"key": "notify_min_severity", "value": "high", "editable_by_ai": True},
            {"key": "notify_dedup_minutes", "value": "30", "editable_by_ai": True},
        ],
    }


def _stores(*, host_enabled: bool = True) -> tuple[MagicMock, MagicMock, MagicMock]:
    host_store = MagicMock()
    host_store.create_pending.return_value = _FakeHostRecord(
        id="act-1",
        summary="docker_ps on host 111 [read-only]",
    )
    settings_store = MagicMock()
    settings_store.get.return_value = "high"
    actions_store = MagicMock()
    return host_store, settings_store, actions_store


@pytest.fixture(autouse=True)
def _enable_host_actions(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_HOST_ACTIONS_ENABLED", "1")


def test_propose_docker_ps_creates_pending_proposal() -> None:
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        "Propose docker_ps on host 111. Read-only only.",
        _sample_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert result["host_action_proposal"] is not None
    assert result["host_action_proposal"]["id"] == "act-1"
    assert result["host_action_proposal"]["status"] == "pending"
    host_store.create_pending.assert_called_once()
    call = host_store.create_pending.call_args
    assert call[0][0] == "docker_ps"
    assert call[0][1] == "111"
    assert call[1]["proposed_by"] == "operator@example.com"


def test_propose_ha_switch_on_without_entity_id_rejects_no_auto_actuate(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Regex propose without entity_id must not queue HA mutate or pending Approve."""
    monkeypatch.setenv("ALFA_AI_HOME_ASSISTANT_ENABLED", "1")
    monkeypatch.setattr(
        "src.ops.home_assistant_client.home_assistant_token_present",
        lambda: True,
    )
    monkeypatch.setattr(
        "src.ops.solar_dump.load_ha_switch_allowlist",
        lambda settings=None: frozenset({"switch.sim_ac_plug_1"}),
    )

    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        "Propose ha_switch_on on host 105",
        _sample_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert result.get("host_action_proposal") is None
    assert result.get("host_action_auto_actuate") is None
    assert "entity_id" in (result.get("reply") or "").lower()
    host_store.create_pending.assert_not_called()


def test_propose_ha_dump_tick_queues_auto_actuate_not_pending(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("ALFA_AI_HOME_ASSISTANT_ENABLED", "1")
    monkeypatch.setattr(
        "src.ops.home_assistant_client.home_assistant_token_present",
        lambda: True,
    )
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        "Propose ha_dump_tick on host 105",
        _sample_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert result.get("host_action_proposal") is None
    assert result.get("host_action_auto_actuate", {}).get("action_key") == "ha_dump_tick"
    host_store.create_pending.assert_not_called()


def test_inference_blocklist_no_proposal() -> None:
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        "Propose run_command on host 148 to run: docker restart llamacpp-rpc-coordinator",
        _sample_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert result["host_action_proposal"] is None
    assert "blocked" in result["reply"].lower()
    host_store.create_pending.assert_not_called()


def test_propose_brain_verify_creates_pending_proposal() -> None:
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        "Propose brain_verify on host 111",
        _sample_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert result["host_action_proposal"] is not None
    assert result["host_action_proposal"]["status"] == "pending"
    host_store.create_pending.assert_called_once()
    call = host_store.create_pending.call_args
    assert call[0][0] == "brain_verify"
    assert call[0][1] == "111"


def test_propose_hub_diag_read_not_blocklisted() -> None:
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        "Propose hub_diag_read on host 148 (read-only inference coordinator snapshot)",
        _sample_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert result["host_action_proposal"] is not None
    assert "blocked" not in result["reply"].lower()
    host_store.create_pending.assert_called_once()
    call = host_store.create_pending.call_args
    assert call[0][0] == "hub_diag_read"
    assert call[0][1] == "148"


def test_policy_setting_creates_pending_proposal() -> None:
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        "Set ai_triage_enabled to false",
        _sample_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert result["applied_setting"] is None
    assert result["pending_setting_proposal"] is not None
    assert result["pending_setting_proposal"]["key"] == "ai_triage_enabled"
    assert result["pending_setting_proposal"]["description"]
    assert result["pending_setting_proposal"]["requires_approve_reason"]
    settings_store.set.assert_not_called()
    actions_store.record.assert_called_once()


def test_setting_set_applied() -> None:
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        "Set notify_min_severity to critical",
        _sample_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert result["applied_setting"] is not None
    assert result["applied_setting"]["key"] == "notify_min_severity"
    assert result["applied_setting"]["new_value"] == "critical"
    assert result["applied_setting"]["description"]
    settings_store.set.assert_called_once_with(
        "notify_min_severity",
        "critical",
        updated_by="operator@example.com",
        by_ai=False,
    )
    actions_store.record.assert_called_once()


def test_structured_read_three_lines() -> None:
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        "Reply with exactly three lines:\n"
        "1) notify_min_severity=\n"
        "2) notify_dedup_minutes=\n"
        "3) host_actions_enabled=",
        _sample_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert "notify_min_severity=high" in result["reply"]
    assert "notify_dedup_minutes=30" in result["reply"]
    assert "host_actions_enabled=true" in result["reply"]


def test_ambiguous_diagnose_returns_none() -> None:
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        "Should we raise notify_min_severity given current dump and load tradeoffs?",
        _sample_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is None


@pytest.mark.parametrize("message", STRUCTURED_NO_LLM_PROMPTS)
def test_structured_intents_never_call_get_agent_completion(
    message: str,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Eval harness: deterministic router must not touch the agent LLM client."""
    llm_mock = MagicMock(
        side_effect=AssertionError("get_agent_completion must not run on structured intent")
    )
    monkeypatch.setattr("src.llm.client.get_agent_completion", llm_mock)

    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        message,
        _sample_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )

    assert result is not None
    llm_mock.assert_not_called()


def test_ambiguous_intent_leaves_llm_path_open(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """None from router means monitoring_agent should call get_agent_completion next."""
    llm_mock = MagicMock(
        side_effect=AssertionError("get_agent_completion must not run inside router")
    )
    monkeypatch.setattr("src.llm.client.get_agent_completion", llm_mock)

    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        "Should we raise notify_min_severity given current dump and load tradeoffs?",
        _sample_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )

    assert result is None
    llm_mock.assert_not_called()


def _missions_context() -> dict[str, Any]:
    ctx = _sample_context()
    ctx["missions_fleet"] = {
        "feeder_paused": False,
        "active_run_count": 1,
        "artifacts_today": {"finding_count": 3, "judged_count": 1},
        "fleet": [
            {
                "id": "audit-repo",
                "label": "Audit repo",
                "kind": "skill",
                "heartbeat_status": "unknown",
                "active_run_count": 1,
                "done_run_count": 4,
                "last_action": None,
            },
            {
                "id": "day-session-feeder",
                "label": "Mission feeder",
                "kind": "side_process",
                "heartbeat_status": "alive",
                "active_run_count": 0,
                "done_run_count": 0,
                "last_action": "enqueued host=105",
            },
        ],
        "active_runs": [
            {
                "run_id": "run-abc123",
                "target_host": "105",
                "skill": "audit-repo",
                "status": "running",
            }
        ],
    }
    return ctx


def test_fleet_status_deterministic() -> None:
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        "Fleet status",
        _missions_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert "Mission fleet status" in result["reply"]
    assert "Active runs: 1" in result["reply"]
    assert "Mission feeder" in result["reply"]
    host_store.create_pending.assert_not_called()


def test_mission_wedge_status_deterministic() -> None:
    host_store, settings_store, actions_store = _stores()
    ctx = _missions_context()
    ctx["missions_fleet"]["wedge"] = {
        "ok": True,
        "wedged": True,
        "stuck_threshold_sec": 1800,
        "max_active": 2,
        "active_count": 3,
        "stuck_count": 3,
        "stuck_runs": [
            {
                "run_id": "68cbb475-0000-0000-0000-000000000001",
                "goal": "Research FastAPI lifespan vs on_event",
                "status": "running",
                "target_host": "111",
                "age_sec": 90000,
            }
        ],
        "signals": ["3 run(s) pending/running longer than 1800s"],
        "would_take_action": ["Approve Clear stuck missions"],
        "worker_gaps": [],
        "duplicate_goals": [],
        "feeder_blocked": True,
        "_formatted": (
            "MISSION WEDGE DETECTED (expected feedback missing).\n"
            "- Active: 3 (max feeder 2); stuck>=1800s: 3\n"
            'Say "Clear stuck missions" for an Approve card'
        ),
    }
    result = try_handle_deterministic(
        "Are missions wedged?",
        ctx,
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert "MISSION WEDGE DETECTED" in result["reply"]
    host_store.create_pending.assert_not_called()


def test_clear_stuck_missions_proposes_action() -> None:
    host_store, settings_store, actions_store = _stores()
    host_store.create_pending.return_value = _FakeHostRecord(
        id="act-clear-1",
        summary="Clear wedged stuck missions on brain hub",
    )
    ctx = _missions_context()
    ctx["missions_fleet"]["wedge"] = {
        "ok": True,
        "wedged": True,
        "stuck_threshold_sec": 1800,
        "max_active": 2,
        "active_count": 3,
        "stuck_count": 3,
        "stuck_runs": [],
        "signals": ["stuck"],
        "would_take_action": ["Approve Clear stuck missions"],
        "worker_gaps": [],
        "duplicate_goals": [],
        "feeder_blocked": True,
        "_formatted": "MISSION WEDGE DETECTED (expected feedback missing).",
    }
    result = try_handle_deterministic(
        "Clear stuck missions",
        ctx,
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert result["host_action_proposal"] is not None
    assert result["host_action_proposal"]["id"] == "act-clear-1"
    host_store.create_pending.assert_called_once()
    assert host_store.create_pending.call_args[0][0] == "mission_clear_stuck"


def test_activity_summary_deterministic_no_llm() -> None:
    host_store, settings_store, actions_store = _stores()
    ctx = _missions_context()
    ctx["recent_ai_actions"] = [
        {
            "summary": "Proposed notify_min_severity change",
            "action_type": "setting_proposal",
            "created_at": "2099-01-01T00:00:00+00:00",
        }
    ]
    ctx["missions_fleet"]["recent_runs"] = [
        {
            "run_id": "51baa78d-5fb2-4626-8208-2ed27cafcaa3",
            "status": "done",
            "skill": "audit-repo",
            "target_host": "102",
            "goal": "Audit host 102",
        }
    ]
    ctx["missions_fleet"]["top_findings"] = [
        {
            "severity": "high",
            "description": "Worker missing on host 102",
            "would_take_action": "Restart alfa-ai-worker-102 with AUDIT_ROOTS",
        }
    ]
    result = try_handle_deterministic(
        "what has alfa-ai been doing for the last 8 hrs? what has it worked on?",
        ctx,
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert result["reply"].startswith("```text")
    assert "no frontier-code call" in result["reply"]
    assert "Missions / agent fleet" in result["reply"]
    assert "51baa78d" in result["reply"]
    assert "Would take (propose-only)" in result["reply"]
    assert result.get("host_action_proposal") is None
    host_store.create_pending.assert_not_called()


@pytest.mark.parametrize(
    "message",
    (
        "analyze what alfa-ai has been doing for the last 1hr",
        "what activities has alfa-ai doing recently?",
        "show me all that activity",
        "what jobs has alfa-ai completed in the last 2 hours?",
        "what did alfa-ai do in the past 3 hours?",
    ),
)
def test_activity_summary_paraphrases_deterministic_no_llm(message: str) -> None:
    host_store, settings_store, actions_store = _stores()
    ctx = _missions_context()
    ctx["recent_ai_actions"] = [
        {
            "summary": "Inspect host 111",
            "action_type": "host_inspect_executed",
            "created_at": "2099-01-01T00:00:00+00:00",
        }
    ]
    result = try_handle_deterministic(
        message,
        ctx,
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert "no frontier-code call" in result["reply"]
    assert result.get("host_action_proposal") is None
    host_store.create_pending.assert_not_called()


def test_activity_summary_last_1hr_window() -> None:
    host_store, settings_store, actions_store = _stores()
    ctx = _missions_context()
    result = try_handle_deterministic(
        "analyze what alfa-ai has been doing for the last 1hr",
        ctx,
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert "last ~1h" in result["reply"]


def test_jobs_completed_last_2h_excludes_dump_ticks_and_row_samples() -> None:
    from datetime import UTC, datetime, timedelta

    host_store, settings_store, actions_store = _stores()
    ctx = _missions_context()
    now = datetime.now(tz=UTC)
    recent = (now - timedelta(minutes=30)).isoformat()
    old = (now - timedelta(hours=10)).isoformat()
    ctx["recent_ai_actions"] = [
        {
            "summary": "Proposed notify_min_severity change",
            "action_type": "setting_proposal",
            "created_at": recent,
        },
        {
            "summary": "Old inspect",
            "action_type": "host_inspect_executed",
            "created_at": old,
        },
    ]
    ctx["missions_fleet"]["active_runs"] = [
        {
            "run_id": "7e15f998-5fb2-4626-8208-2ed27cafcaa3",
            "target_host": "105",
            "skill": "audit-repo",
            "status": "running",
            "created_at": old,
            "updated_at": recent,
            "goal": "Read-only audit contracts-bot deploy surfaces if mounted",
        },
        {
            "run_id": "newrun01-5fb2-4626-8208-2ed27cafcaa3",
            "target_host": "111",
            "skill": "audit-repo",
            "status": "running",
            "created_at": recent,
            "goal": "fresh in-window audit",
        },
    ]
    ctx["dump_observe_sample"] = [
        {
            "summary": "ha_dump_tick observe",
            "action_type": "solar_dump_observed",
            "created_at": recent,
        }
    ]
    ctx["dump_observe_in_sample"] = 15
    ctx["dump_observe_created_at"] = [recent] * 8 + [old]
    ctx["incident_counts_in_window"] = {"resolved": 24, "received": 1}
    ctx["incident_window_kind"] = "last_n_rows"
    ctx["incident_window_row_limit"] = 50
    ctx["open_incidents_by_status"] = {"received": 1}
    ctx["recent_audit_events"] = [
        {"created_at": recent, "action": "login_ok", "detail": "admin"},
        {"created_at": old, "action": "stale_audit", "detail": "should hide"},
    ]
    result = try_handle_deterministic(
        "what jobs has alfa-ai completed in the last 2 hours?",
        ctx,
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    reply = result["reply"]
    assert "no frontier-code call" in reply
    assert "last ~2h" in reply
    assert "Proposed notify_min_severity change" in reply
    assert "Old inspect" not in reply
    assert "not last ~2h" in reply
    assert "last_n_rows" in reply
    assert "Dump observe ticks (not completed jobs)" in reply
    assert "15" in reply
    assert "ha_dump_tick observe" in reply
    assert "8 observe row(s)" in reply
    assert "Active: newrun01" in reply
    assert "Leftover: 7e15f998" in reply
    assert "Active: 7e15f998" not in reply
    assert "login_ok" in reply
    assert "stale_audit" not in reply
    assert result.get("host_action_proposal") is None
    host_store.create_pending.assert_not_called()


def test_overnight_jobs_completed_deterministic_no_llm() -> None:
    from datetime import UTC, datetime, timedelta

    host_store, settings_store, actions_store = _stores()
    ctx = _missions_context()
    recent_iso = (datetime.now(tz=UTC) - timedelta(hours=3)).isoformat()
    ctx["missions_fleet"]["recent_runs"] = [
        {
            "run_id": "a1b2c3d4-5fb2-4626-8208-2ed27cafcaa3",
            "status": "done",
            "skill": "audit-repo",
            "target_host": "148",
            "goal": "Audit host 148 overnight",
            "created_at": recent_iso,
            "updated_at": recent_iso,
        }
    ]
    result = try_handle_deterministic(
        "what jobs were completed overnight?",
        ctx,
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert "no frontier-code call" in result["reply"]
    assert "last ~12h" in result["reply"]
    assert "Completed missions" in result["reply"]
    assert "a1b2c3d4" in result["reply"]
    assert result.get("host_action_proposal") is None
    host_store.create_pending.assert_not_called()


def _cluster_status_context() -> dict[str, Any]:
    return {
        "cluster_health": {
            "hosts": [
                {"key": "111", "name": "hub", "ok": True},
                {"key": "93", "name": "operator", "ok": False},
            ],
            "brain": {
                "services": [
                    {"name": "litellm", "ok": True},
                    {"name": "postgres", "ok": True},
                ],
            },
            "inference": {
                "endpoints": [
                    {"name": "frontier-coordinator", "ok": True},
                    {"name": "embed-110", "ok": False},
                ],
            },
        },
        "prometheus_ops": {
            "firing_alerts": [
                {"alertname": "LowDiskSpace", "severity": "warning", "summary": "disk low"},
            ],
            "firing_count": 1,
        },
        "open_incidents_by_status": {"received": 1},
        "open_incident_alertnames": ["LowDiskSpace"],
        "home_energy_ops": {
            "enabled": True,
            "dump_enabled": True,
            "ha_ready": True,
            "last_skipped": None,
        },
    }


@pytest.mark.parametrize(
    "message",
    (
        "What is wrong with the cluster?",
        "is the cluster healthy?",
        "is dump working?",
    ),
)
def test_cluster_status_deterministic_no_llm(message: str) -> None:
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        message,
        _cluster_status_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert "no frontier-code call" in result["reply"]
    assert "ALFa AI cluster status" in result["reply"]
    assert "Hosts" in result["reply"]
    assert "Firing alerts" in result["reply"]
    assert result.get("host_action_proposal") is None
    host_store.create_pending.assert_not_called()


def test_cluster_status_uses_reachable_when_ok_missing() -> None:
    host_store, settings_store, actions_store = _stores()
    ctx = _cluster_status_context()
    ctx["cluster_health"]["hosts"] = [
        {"key": "111", "name": "hub", "reachable": True},
        {"key": "93", "name": "operator", "reachable": False},
    ]
    result = try_handle_deterministic(
        "cluster status",
        ctx,
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert "111 (hub): ok" in result["reply"]
    assert "93 (operator): down" in result["reply"]
    assert "?: ?" not in result["reply"]


def test_followup_replay_activity_from_history() -> None:
    host_store, settings_store, actions_store = _stores()
    ctx = _missions_context()
    history = [
        {
            "role": "assistant",
            "content": (
                "```text\n"
                "ALFa AI activity (last ~8h, from admin context -- no frontier-code call):\n"
                "## Mission queue health\n"
                "```"
            ),
        }
    ]
    result = try_handle_deterministic(
        "yes, show me all that",
        ctx,
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
        history=history,
    )
    assert result is not None
    assert "no frontier-code call" in result["reply"]
    assert "ALFa AI activity" in result["reply"]
    assert result.get("host_action_proposal") is None


def test_followup_audit_answer_replays_activity_same_hours() -> None:
    host_store, settings_store, actions_store = _stores()
    ctx = _missions_context()
    history = [
        {
            "role": "assistant",
            "content": (
                "```text\n"
                "ALFa AI activity (last ~2h, from admin context -- no frontier-code call):\n"
                "## Completed missions\n"
                "```"
            ),
        }
    ]
    result = try_handle_deterministic(
        "audit your answer, is it correct?",
        ctx,
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
        history=history,
    )
    assert result is not None
    assert "no frontier-code call" in result["reply"]
    assert "last ~2h" in result["reply"]
    assert "I invented" not in result["reply"]
    assert result.get("host_action_proposal") is None
    host_store.create_pending.assert_not_called()


def test_followup_verify_after_llm_uses_packed_fact_check() -> None:
    host_store, settings_store, actions_store = _stores()
    ctx = _missions_context()
    history = [
        {
            "role": "assistant",
            "content": (
                "You're right to ask. I invented run 7e15f998 and there is "
                "no missions_fleet blob."
            ),
        }
    ]
    result = try_handle_deterministic(
        "audit your answer, is it correct?",
        ctx,
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
        history=history,
    )
    assert result is not None
    assert "ALFa AI fact check" in result["reply"]
    assert "no frontier-code call" in result["reply"]
    assert "missions_fleet: present" in result["reply"]
    assert "I invented" not in result["reply"]
    assert result.get("host_action_proposal") is None


def test_followup_show_after_llm_falls_through() -> None:
    host_store, settings_store, actions_store = _stores()
    history = [
        {"role": "assistant", "content": "LiteLLM looks fine from here."},
    ]
    result = try_handle_deterministic(
        "show me all that",
        _sample_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
        history=history,
    )
    assert result is None


def test_followup_verify_replays_fleet_status() -> None:
    host_store, settings_store, actions_store = _stores()
    history = [
        {
            "role": "assistant",
            "content": "Mission fleet status (read-only):\n- Feeder: active",
        }
    ]
    result = try_handle_deterministic(
        "are you sure?",
        _missions_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
        history=history,
    )
    assert result is not None
    assert "Mission fleet status (read-only)" in result["reply"]
    assert result.get("host_action_proposal") is None


def test_followup_replay_cluster_status_from_history() -> None:
    host_store, settings_store, actions_store = _stores()
    history = [
        {
            "role": "assistant",
            "content": (
                "ALFa AI cluster status (from admin context -- no frontier-code call):\n"
                "## Hosts"
            ),
        }
    ]
    result = try_handle_deterministic(
        "show me all that",
        _cluster_status_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
        history=history,
    )
    assert result is not None
    assert "ALFa AI cluster status" in result["reply"]
    assert "firing_count" in result["reply"]
    assert result.get("host_action_proposal") is None


def test_followup_replay_unrelated_history_falls_through() -> None:
    host_store, settings_store, actions_store = _stores()
    history = [
        {"role": "assistant", "content": "LiteLLM on 111 is down per last check."},
    ]
    result = try_handle_deterministic(
        "yes, show me all that",
        _sample_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
        history=history,
    )
    assert result is None


def test_followup_replay_does_not_match_lone_yes_or_approve() -> None:
    host_store, settings_store, actions_store = _stores()
    history = [
        {
            "role": "assistant",
            "content": (
                "ALFa AI activity (last ~8h, from admin context -- no frontier-code call):\n"
            ),
        }
    ]
    for message in ("yes", "click approve"):
        result = try_handle_deterministic(
            message,
            _missions_context(),
            host_store=host_store,
            settings_store=settings_store,
            actions_store=actions_store,
            config={},
            operator_email="operator@example.com",
            history=history,
        )
        assert result is None


def test_audit_host_returns_llm_continue_inspect() -> None:
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        "Audit host 105",
        _missions_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert result.get("llm_continue") is True
    assert result.get("host_action_proposal") is None
    assert result["repo_target"]["host"] == "105"
    pre = result["pre_inspect"]
    keys = [row["action_key"] for row in pre]
    assert "docker_ps" in keys
    assert "git_status" in keys
    assert "disk_usage" in keys
    assert "health_check" in keys
    host_store.create_pending.assert_not_called()


def test_analyze_rankings_bot_repo_returns_inspect_sentinel() -> None:
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        "analyze rankings bot repo, activate all scrapers to update site",
        _missions_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert result.get("llm_continue") is True
    repo_target = result["repo_target"]
    assert repo_target["host"] == "106"
    assert repo_target["repo_dir"] == "/home/operator/rankings-bot"
    pre = result["pre_inspect"]
    assert [row["action_key"] for row in pre] == [
        "repo_tree",
        "git_status",
        "docker_ps",
        "repo_read_file",
        "repo_grep",
    ]
    assert pre[3]["params"]["relative_path"] == "README.md"
    assert pre[4]["params"]["pattern"] == "scraper"
    host_store.create_pending.assert_not_called()


def test_inspect_contracts_bot_phrase_returns_sentinel() -> None:
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        "inspect contracts-bot",
        _missions_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert result.get("llm_continue") is True
    assert result["repo_target"]["host"] == "105"
    assert result["repo_target"]["repo_dir"] == "/home/operator/contracts-bot"
    host_store.create_pending.assert_not_called()


def test_audit_host_enabled_worker_returns_llm_continue() -> None:
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        "Audit host 106",
        _missions_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert result.get("llm_continue") is True
    assert result["repo_target"]["host"] == "106"
    host_store.create_pending.assert_not_called()


def test_research_online_not_treated_as_repo_inspect() -> None:
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        "research online about FastAPI streaming",
        _missions_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert result.get("llm_continue") is True
    assert result.get("host_action_proposal") is None
    pre = result["pre_inspect"]
    assert len(pre) == 1
    assert pre[0]["action_key"] == "web_search"
    assert "FastAPI" in pre[0]["params"]["query"]
    host_store.create_pending.assert_not_called()


def test_annotate_reply_if_no_proposal_appends_when_model_fakes_approve() -> None:
    from src.api.ask_alfa_router import annotate_reply_if_no_proposal

    text = "Proposing now: enqueue audit-repo. Click Approve on the mission below."
    out = annotate_reply_if_no_proposal(text, None)
    assert "No Approve button was created" in out
    assert annotate_reply_if_no_proposal(text, {"id": "x"}) == text


def test_review_errors_returns_llm_continue_skip_ssh() -> None:
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        "review errors in alfa-ai and list them",
        _missions_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert result.get("llm_continue") is True
    assert result.get("skip_ssh") is True
    assert result.get("host_action_proposal") is None
    assert result["repo_target"]["host"] == "111"
    assert result["pre_inspect"] == []
    host_store.create_pending.assert_not_called()


def test_host_facts_returns_llm_continue_inspect() -> None:
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        "Run host-facts on host 105",
        _missions_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert result.get("llm_continue") is True
    assert result["repo_target"]["host"] == "105"
    assert [row["action_key"] for row in result["pre_inspect"]] == [
        "docker_ps",
        "docker_stats",
        "disk_usage",
        "health_check",
    ]
    host_store.create_pending.assert_not_called()


def test_research_online_uses_web_search_pre_inspect() -> None:
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        "research online to see if any updates exist for qwen 3.8 27B q8",
        _missions_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert result.get("llm_continue") is True
    assert result.get("host_action_proposal") is None
    pre = result["pre_inspect"]
    assert pre[0]["action_key"] == "web_search"
    assert "qwen" in pre[0]["params"]["query"].lower()
    assert result["repo_target"]["host"] == "111"
    host_store.create_pending.assert_not_called()


def test_check_weather_zip_uses_web_search_pre_inspect() -> None:
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        "check weather for 37658",
        _missions_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert result.get("llm_continue") is True
    pre = result["pre_inspect"]
    assert pre[0]["action_key"] == "web_search"
    assert "37658" in pre[0]["params"]["query"]
    host_store.create_pending.assert_not_called()


def test_ha_solar_weather_does_not_enqueue_audit_repo() -> None:
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        "whats the weather for the next few hrs looking at the host 105, HA, solar weather radar?",
        _missions_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert result.get("llm_continue") is True
    assert result.get("host_action_proposal") is None
    assert result["repo_target"]["host"] == "105"
    keys = [row["action_key"] for row in result["pre_inspect"]]
    assert keys == ["ha_get_forecasts", "ha_get_state"]
    assert result["pre_inspect"][0]["params"]["type"] == "hourly"
    host_store.create_pending.assert_not_called()


def test_bare_weather_question_uses_ha_inspect_not_mission() -> None:
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        "what's the weather looking like?",
        _missions_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert result.get("llm_continue") is True
    host_store.create_pending.assert_not_called()


def test_audit_host_any_enabled_worker() -> None:
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        "Audit 148",
        _missions_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert result.get("llm_continue") is True
    assert result["repo_target"]["host"] == "148"
    host_store.create_pending.assert_not_called()


def test_audit_host_disabled_stub_rejected() -> None:
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        "Audit host 59",
        _missions_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert result["host_action_proposal"] is None
    assert "not enabled" in result["reply"].lower()
    host_store.create_pending.assert_not_called()


def test_audit_all_hosts_lists_enabled() -> None:
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        "Audit all hosts",
        _missions_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert "Audit host 102" in result["reply"]
    assert "Audit host 148" in result["reply"]
    host_store.create_pending.assert_not_called()


def test_pause_feeder_creates_proposal() -> None:
    host_store, settings_store, actions_store = _stores()
    host_store.create_pending.return_value = _FakeHostRecord(
        id="act-pause-1",
        summary="Pause audit mission feeder",
    )
    result = try_handle_deterministic(
        "Pause audit feeder",
        _missions_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    proposal = result["host_action_proposal"]
    assert proposal is not None
    assert proposal["action_key"] == "mission_feeder_pause"
    assert proposal["action_category"] == "mission"
    host_store.create_pending.assert_called_once()
    call = host_store.create_pending.call_args
    assert call[0][0] == "mission_feeder_pause"
    assert call[0][1] == "111"


def test_hot_host_chip_proposes_docker_stats() -> None:
    host_store, settings_store, actions_store = _stores()
    host_store.create_pending.return_value = _FakeHostRecord(
        id="act-stats-1",
        summary="docker_stats on host 111 [read-only]",
    )
    ctx = _sample_context()
    ctx["prometheus_ops"] = {
        "host_cpu_busy_pct": [{"instance": "hub-111:9100", "value": 90.0}],
        "host_load1": [{"instance": "hub-111:9100", "value": 12.0}],
        "host_cpu_package_temp_c": [
            {"instance": "hub-111:9100", "sensor": "temp1", "value": 85.0}
        ],
        "top_containers_cpu": [
            {"instance": "hub-111:9100", "name": "hub-cadvisor", "value": 9.0}
        ],
        "snapshot_error": None,
    }
    result = try_handle_deterministic(
        "Why is host 111 hot?",
        ctx,
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert "Load-justified" in result["reply"] or "thermal" in result["reply"].lower()
    proposal = result["host_action_proposal"]
    assert proposal is not None
    assert proposal["action_key"] == "docker_stats"
    assert proposal["host"] == "111"
    host_store.create_pending.assert_called_once()
    call = host_store.create_pending.call_args
    assert call[0][0] == "docker_stats"


def test_scope_question_no_llm_needed() -> None:
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        "What data do you have access to in this admin console, "
        "and what data do you explicitly NOT have?",
        _sample_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert "consumer bot" in result["reply"].lower()
    assert "ProBilliards" in result["reply"] or "rankings" in result["reply"]


PRODUCTION_MIXED_INTENT_MESSAGE = (
    "Set notify_email to operator@example.com so critical alerts reach me. "
    "Then explain what else is still required before an email would actually be delivered."
)


def test_mixed_intent_setting_falls_through_to_llm() -> None:
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        PRODUCTION_MIXED_INTENT_MESSAGE,
        _sample_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is None
    settings_store.set.assert_not_called()
    settings_store.get.assert_not_called()
    actions_store.record.assert_not_called()


def test_bare_notify_email_creates_pending_proposal() -> None:
    host_store, settings_store, actions_store = _stores()
    settings_store.get.return_value = ""
    result = try_handle_deterministic(
        "Set notify_email to operator@example.com",
        _sample_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert result["applied_setting"] is None
    assert result["pending_setting_proposal"] is not None
    assert result["pending_setting_proposal"]["key"] == "notify_email"
    assert result["pending_setting_proposal"]["new_value"] == "operator@example.com"
    settings_store.set.assert_not_called()
    actions_store.record.assert_called_once()


def test_notify_email_trailing_period_stripped_from_value() -> None:
    host_store, settings_store, actions_store = _stores()
    settings_store.get.return_value = ""
    result = try_handle_deterministic(
        "Set notify_email to operator@example.com.",
        _sample_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert result["pending_setting_proposal"] is not None
    assert result["pending_setting_proposal"]["new_value"] == "operator@example.com"
    assert not result["pending_setting_proposal"]["new_value"].endswith(".")


@pytest.mark.parametrize(
    "message",
    [
        "Set notify_min_severity to medium.",
        "Set notify_dedup_minutes to 30",
        "Set notify_quiet_hours to 22:00-07:00",
    ],
)
def test_bare_set_trailing_period_capture(message: str) -> None:
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        message,
        _sample_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    applied = result["applied_setting"]
    assert applied is not None
    if "notify_min_severity" in message:
        assert applied["new_value"] == "medium"
    elif "notify_dedup_minutes" in message:
        assert applied["new_value"] == "30"
    elif "notify_quiet_hours" in message:
        assert applied["new_value"] == "22:00-07:00"
    assert not applied["new_value"].endswith(".")


@pytest.mark.parametrize(
    "message",
    [
        "Set notify_quiet_hours to",
        "Set notify_quiet_hours to.",
        "Set chat_thinking_label to",
        "Set chat_thinking_label to.",
    ],
)
def test_incomplete_set_command_falls_through(message: str) -> None:
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        message,
        _sample_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is None
    settings_store.set.assert_not_called()
    actions_store.record.assert_not_called()


def test_bare_clear_token_clears_quiet_hours() -> None:
    host_store, settings_store, actions_store = _stores()
    settings_store.get.return_value = "22:00-07:00"
    result = try_handle_deterministic(
        'Set notify_quiet_hours to ""',
        _sample_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert result["applied_setting"] is not None
    assert result["applied_setting"]["new_value"] == ""
    settings_store.set.assert_called_once_with(
        "notify_quiet_hours",
        "",
        updated_by="operator@example.com",
        by_ai=False,
    )


@pytest.mark.parametrize(
    "key",
    ["notify_min_severity", "notify_dedup_minutes", "ai_triage_enabled"],
)
def test_bare_clear_token_rejected_where_empty_is_illegal(key: str) -> None:
    """`""` must not wipe keys that have no valid empty state.

    Clearing notify_min_severity or ai_triage_enabled would silently change what
    gets emailed, so the clear token has to fail validation rather than store "".
    """
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        f'Set {key} to ""',
        _sample_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )

    assert result is not None
    assert result["applied_setting"] is None
    assert result.get("pending_setting_proposal") is None
    settings_store.set.assert_not_called()
    assert key in result["reply"] or "must be" in result["reply"]


def test_turn_off_non_bool_key_falls_through() -> None:
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        "Turn off chat_thinking_label",
        _sample_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is None
    settings_store.set.assert_not_called()
    actions_store.record.assert_not_called()


def test_address_header_parse_error_converts_to_ai_setting_error() -> None:
    with pytest.raises(AiSettingError):
        validate_setting_value("notify_email", "operator@example.com.")


_HOSTILE_NOTIFY_EMAIL_INPUTS = (
    "foo@",
    "@bar.com",
    "a@b",
    "a operator@example.com",
    "operator@example.com.",
    "<operator@example.com>",
    "",
    "x" * 500 + "@y.com",
)


@pytest.mark.parametrize("value", _HOSTILE_NOTIFY_EMAIL_INPUTS)
def test_validate_notify_email_hostile_inputs_only_ai_setting_error(
    value: str,
) -> None:
    try:
        validate_setting_value("notify_email", value)
    except AiSettingError:
        pass
    except Exception as exc:
        pytest.fail(
            f"validate_setting_value raised {type(exc).__name__}, expected AiSettingError only: {exc}"
        )


def test_malformed_notify_email_rejected() -> None:
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        "Set notify_email to not-an-email",
        _sample_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert result["applied_setting"] is None
    assert result["pending_setting_proposal"] is None
    assert "notify_email" in result["reply"].lower()
    settings_store.set.assert_not_called()
    actions_store.record.assert_not_called()


def test_malformed_notify_dedup_minutes_rejected() -> None:
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        "Set notify_dedup_minutes to abc",
        _sample_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert result["applied_setting"] is None
    assert result["pending_setting_proposal"] is None
    assert "notify_dedup_minutes" in result["reply"].lower()
    settings_store.set.assert_not_called()
    actions_store.record.assert_not_called()


@pytest.mark.parametrize(
    ("key", "value", "expected"),
    [
        ("notify_email", "", ""),
        ("notify_email", "operator@example.com", "operator@example.com"),
        ("notify_min_severity", "CRITICAL", "critical"),
        ("notify_quiet_hours", "", ""),
        ("notify_quiet_hours", "22:00-07:00", "22:00-07:00"),
        ("notify_dedup_minutes", "45", "45"),
        ("notify_dedup_minutes", "0", "0"),
        ("notify_dedup_minutes", "10080", "10080"),
        ("auto_fix_allowlist", "", ""),
        ("auto_fix_allowlist", "DiskFull, HighMemory", "DiskFull,HighMemory"),
        ("ai_triage_enabled", "ON", "true"),
        ("ai_can_adjust_settings", "no", "false"),
        ("chat_thinking_label", "Thinking...", "Thinking..."),
    ],
)
def test_validate_setting_value_accepts(key: str, value: str, expected: str) -> None:
    assert validate_setting_value(key, value) == expected


@pytest.mark.parametrize(
    ("key", "value", "fragment"),
    [
        ("notify_email", "not-an-email", "notify_email"),
        ("notify_email", "a@b", "notify_email"),
        ("notify_email", "a @b.com", "whitespace"),
        ("notify_min_severity", "urgent", "notify_min_severity"),
        ("notify_quiet_hours", "25:00-07:00", "notify_quiet_hours"),
        ("notify_quiet_hours", "22:00", "notify_quiet_hours"),
        ("notify_dedup_minutes", "abc", "notify_dedup_minutes"),
        ("notify_dedup_minutes", "-1", "notify_dedup_minutes"),
        ("notify_dedup_minutes", "+30", "plain"),
        ("notify_dedup_minutes", "1_000", "plain"),
        ("notify_dedup_minutes", "10081", "10080"),
        ("notify_dedup_minutes", "999999999999999999999", "10080"),
        # str.isdigit() accepts these but int() does not.
        ("notify_dedup_minutes", "\u00b2", "plain"),
        ("notify_dedup_minutes", "\u0662", "plain"),
        ("notify_dedup_minutes", "\uff12", "plain"),
        ("notify_dedup_minutes", "1" * 5000, "plain"),
        ("auto_fix_allowlist", "foo bar", "whitespace"),
        ("auto_fix_allowlist", "a,,b", "comma-separated"),
        ("ai_triage_enabled", "maybe", "ai_triage_enabled"),
        ("chat_thinking_label", "line1\nline2", "newline"),
    ],
)
def test_validate_setting_value_rejects(key: str, value: str, fragment: str) -> None:
    with pytest.raises(AiSettingError) as exc_info:
        validate_setting_value(key, value)
    assert fragment.lower() in str(exc_info.value).lower()


@pytest.mark.parametrize(
    ("message", "expected"),
    [
        ("draft-judge: summarize inference", "summarize inference"),
        ("DRAFT-JUDGE:  fix typo", "fix typo"),
        ("  draft-judge:  nested task", "nested task"),
        ("normal ask alfa question", None),
        ("draft-judge:", ""),
        ("draft-judge: ", ""),
    ],
)
def test_parse_draft_judge_task(message: str, expected: str | None) -> None:
    assert parse_draft_judge_task(message) == expected


def test_draft_judge_prefix_skipped_when_disabled(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_JUDGE_ENABLED", "0")
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        "draft-judge: write a helper",
        _sample_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert result["draft_guide"]["skipped"] is True
    assert result["draft_guide"]["safe_to_auto_apply"] is False
    assert "ALFA_AI_JUDGE_ENABLED=0" in result["draft_guide"]["skip_reason"]
    assert result["host_action_proposal"] is None


def test_draft_judge_prefix_runs_loop(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_JUDGE_ENABLED", "1")
    monkeypatch.setenv("ALFA_AI_JUDGE_ON", "research")

    def fake_loop(task: str, **kwargs):
        from src.llm.draft_guide import DraftGuideResult
        from src.llm.judge import JudgeResult

        assert task == "explain health checks"
        return DraftGuideResult(
            task=task,
            final_draft="draft body api_key=sk-shouldnotleak",
            verdict="confirm",
            rounds=1,
            judge_results=[
                JudgeResult(
                    verdict="confirm",
                    confidence="high",
                    issues=[],
                    guidance="looks good",
                    raw="{}",
                    model="frontier-code",
                    safe_to_auto_apply=False,
                )
            ],
            log_path="logs/draft-judge/sessions.jsonl",
        )

    monkeypatch.setattr("src.llm.draft_guide.run_draft_guide_loop", fake_loop)
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        "draft-judge: explain health checks",
        _sample_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    dg = result["draft_guide"]
    assert dg["verdict"] == "confirm"
    assert dg["guidance"] == "looks good"
    assert dg["log_path"] == "logs/draft-judge/sessions.jsonl"
    assert dg["safe_to_auto_apply"] is False
    assert dg["skipped"] is False
    assert dg["project_auto_applied"] is False
    assert "verdict: confirm" in result["reply"]
    assert "project_auto_applied: false" in result["reply"]
    assert "sk-shouldnotleak" not in result["reply"]
    assert "[REDACTED]" in result["reply"]
    assert result["host_action_proposal"] is None


def test_guest_router_does_not_expose_draft_judge() -> None:
    from src.api.routers import guest as guest_mod

    source = Path(guest_mod.__file__).read_text(encoding="utf-8")
    assert "try_handle_deterministic" not in source
    assert "draft-judge" not in source
    assert "run_draft_guide_loop" not in source


def test_draft_judge_does_not_block_normal_propose() -> None:
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        "Propose docker_ps on host 111. Read-only only.",
        _sample_context(),
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert result.get("draft_guide") is None
    assert result["host_action_proposal"] is not None
