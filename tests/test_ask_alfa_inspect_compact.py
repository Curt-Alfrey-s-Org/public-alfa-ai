"""Unit tests for Ask ALFa inspect dump compaction (H3, LLM prompt only)."""

from __future__ import annotations

import json
from typing import Any
from unittest.mock import MagicMock

import pytest

from src.api.ask_alfa_context import (
    INSPECT_COMPACT_KEEP_LAST,
    build_inspect_compact_user_message,
    categorize_message,
    categorize_packed_messages,
    compact_inspect_steps,
    summarize_inspect_step,
)
from src.api.models.user import UserRecord
from src.api.routers import admin as admin_module
from src.llm.client import ChatTurn
from src.ops.exec_result import ExecResult


def _inspect_step(
    index: int,
    *,
    stdout: str | None = None,
    action_key: str = "docker_ps",
    host: str = "106",
) -> dict[str, Any]:
    marker = stdout or f"FULL_STDOUT_MARKER_{index}_" + ("x" * 500)
    return {
        "action_key": action_key,
        "host": host,
        "command_run": "docker ps",
        "stdout": marker,
        "stderr": "",
        "exit_code": 0,
        "ok": True,
        "duration_ms": 1,
    }


def test_compact_inspect_steps_splits_older_and_recent() -> None:
    steps = [_inspect_step(i) for i in range(5)]
    older, recent = compact_inspect_steps(steps, keep_last=INSPECT_COMPACT_KEEP_LAST)
    assert len(older) == 3
    assert len(recent) == 2
    assert recent[0]["stdout"].startswith("FULL_STDOUT_MARKER_3")
    assert recent[1]["stdout"].startswith("FULL_STDOUT_MARKER_4")


def test_compact_inspect_steps_short_list_returns_all_recent() -> None:
    steps = [_inspect_step(0), _inspect_step(1)]
    older, recent = compact_inspect_steps(steps)
    assert older == []
    assert len(recent) == 2


def test_summarize_inspect_step_collapses_whitespace() -> None:
    step = {
        "host": "106",
        "action_key": "repo_tree",
        "ok": True,
        "exit_code": 0,
        "stdout": "line one\n\n  line two",
    }
    line = summarize_inspect_step(step)
    assert "106 repo_tree ok" in line
    assert "line one line two" in line


def test_build_inspect_compact_user_message_none_when_empty() -> None:
    assert build_inspect_compact_user_message([]) is None


def test_build_inspect_compact_user_message_prefix() -> None:
    msg = build_inspect_compact_user_message([_inspect_step(0)])
    assert msg is not None
    assert msg.startswith("Inspect summary (compacted):")


def test_categorize_compacted_summary_as_inspect() -> None:
    assert (
        categorize_message(
            {"role": "user", "content": "Inspect summary (compacted):\n106 docker_ps ok"}
        )
        == "inspect"
    )


def test_five_pre_inspections_pack_last_two_full_in_findings() -> None:
    steps = [_inspect_step(i) for i in range(5)]
    messages = admin_module._build_monitoring_agent_messages(
        message="check hosts",
        context={"ai_settings": []},
        system_prompt="sys",
        repo_target={"alias": "rankings-bot", "host": "106"},
        pre_inspections=steps,
    )
    compact_msgs = [
        m for m in messages if (m.get("content") or "").startswith("Inspect summary (compacted)")
    ]
    assert len(compact_msgs) == 1
    findings_msgs = [
        m for m in messages if (m.get("content") or "").startswith("Inspect findings")
    ]
    assert len(findings_msgs) == 1
    findings_blob = findings_msgs[0]["content"]
    payload = json.loads(findings_blob.split("\n", 1)[1])
    assert payload["inspect_steps_already_run"] == 5
    assert payload["inspect_steps_remaining"] == admin_module._INSPECT_MAX_STEPS
    assert len(payload["inspections"]) == 2
    full_blob = json.dumps(payload)
    for index in range(3):
        assert f"FULL_STDOUT_MARKER_{index}_" not in full_blob
    for index in (3, 4):
        assert f"FULL_STDOUT_MARKER_{index}_" in full_blob
    for index in range(3):
        assert f"FULL_STDOUT_MARKER_{index}_" in compact_msgs[0]["content"]


def test_packed_messages_include_recent_activity_when_present() -> None:
    messages = admin_module._build_monitoring_agent_messages(
        message="hi",
        context={
            "recent_ai_actions": [{"summary": "setting changed", "action_type": "x"}],
            "dump_observe_created_at": ["2026-09-22T19:45:00+00:00"] * 20,
            "missions_fleet": {"active_run_count": 2},
            "ai_settings": [],
            "cluster_health": {"hosts": [{"key": "111", "ok": True}]},
            "host_action_catalog": [{"key": "docker_ps"}],
        },
        system_prompt="sys",
        repo_target={},
        pre_inspections=None,
    )
    activity_msgs = [
        m
        for m in messages
        if (m.get("content") or "").startswith("Recent activity (authoritative)")
    ]
    assert len(activity_msgs) == 1
    assert "setting changed" in activity_msgs[0]["content"]
    assert "dump_observe_created_at" not in activity_msgs[0]["content"]
    assert "missions_fleet" in activity_msgs[0]["content"]
    ops_msgs = [
        m
        for m in messages
        if (m.get("content") or "").startswith("Cluster ops (authoritative)")
    ]
    assert len(ops_msgs) == 1
    assert "cluster_health" in ops_msgs[0]["content"]
    assert "recent_ai_actions" not in ops_msgs[0]["content"]
    catalog_msgs = [
        m
        for m in messages
        if (m.get("content") or "").startswith("Host-action catalog (truncated)")
    ]
    assert len(catalog_msgs) == 1
    assert "host_action_catalog" in catalog_msgs[0]["content"]
    assert "recent_ai_actions" not in catalog_msgs[0]["content"]
    assert "cluster_health" not in catalog_msgs[0]["content"]


def test_packed_messages_huge_catalog_not_in_cluster_ops() -> None:
    huge_catalog = [{"key": f"action_{i}", "description": "x" * 500} for i in range(40)]
    messages = admin_module._build_monitoring_agent_messages(
        message="hi",
        context={
            "cluster_health": {"hosts": []},
            "host_action_catalog": huge_catalog,
        },
        system_prompt="sys",
        repo_target={},
        pre_inspections=None,
    )
    ops_msgs = [
        m
        for m in messages
        if (m.get("content") or "").startswith("Cluster ops (authoritative)")
    ]
    assert len(ops_msgs) == 1
    assert "action_0" not in ops_msgs[0]["content"]
    assert "action_39" not in ops_msgs[0]["content"]
    catalog_msgs = [
        m
        for m in messages
        if (m.get("content") or "").startswith("Host-action catalog (truncated)")
    ]
    assert len(catalog_msgs) == 1
    assert "action_0" in catalog_msgs[0]["content"]


def test_packed_messages_empty_slices_still_emit_prefixes() -> None:
    messages = admin_module._build_monitoring_agent_messages(
        message="hi",
        context={},
        system_prompt="sys",
        repo_target={},
        pre_inspections=None,
    )
    assert any(
        (m.get("content") or "").startswith("Recent activity (authoritative):\n{}")
        for m in messages
    )
    assert any(
        (m.get("content") or "").startswith("Cluster ops (authoritative):\n{}")
        for m in messages
    )
    assert any(
        (m.get("content") or "").startswith("Host-action catalog (truncated):\n{}")
        for m in messages
    )


def test_packed_messages_history_before_operator_message() -> None:
    from src.api.routers.admin import HistoryTurn

    messages = admin_module._build_monitoring_agent_messages(
        message="follow up",
        context={"ai_settings": []},
        system_prompt="sys",
        repo_target={},
        pre_inspections=None,
        history=[
            HistoryTurn(role="user", content="what happened?"),
            HistoryTurn(role="assistant", content="incident on host 111"),
        ],
    )
    roles_contents = [(m["role"], m.get("content", "")) for m in messages]
    user_idx = next(
        i for i, (role, content) in enumerate(roles_contents) if content == "what happened?"
    )
    asst_idx = next(
        i
        for i, (role, content) in enumerate(roles_contents)
        if content == "incident on host 111"
    )
    op_idx = next(
        i
        for i, (role, content) in enumerate(roles_contents)
        if content.startswith("Operator message: follow up")
    )
    assert user_idx < asst_idx < op_idx


def test_one_or_two_pre_inspections_no_compact_summary() -> None:
    for count in (1, 2):
        steps = [_inspect_step(i) for i in range(count)]
        messages = admin_module._build_monitoring_agent_messages(
            message="hi",
            context={"ai_settings": []},
            system_prompt="sys",
            repo_target={},
            pre_inspections=steps,
        )
        compact_msgs = [
            m
            for m in messages
            if (m.get("content") or "").startswith("Inspect summary (compacted)")
        ]
        assert compact_msgs == []


def test_compaction_reduces_inspect_token_estimate() -> None:
    steps = [_inspect_step(i) for i in range(5)]
    full_messages = admin_module._build_monitoring_agent_messages(
        message="hi",
        context={"ai_settings": []},
        system_prompt="sys",
        repo_target={},
        pre_inspections=steps,
    )
    # Hypothetical unpackaged list: all 5 full stdout blobs in findings only.
    older, recent = compact_inspect_steps(steps)
    unpackaged_findings = admin_module._inspect_findings_payload(
        repo_target={},
        inspections=steps,
        remaining_steps=6,
        llm_inspections=steps,
    )
    unpackaged = [
        {"role": "system", "content": "sys"},
        {
            "role": "user",
            "content": f"Inspect findings (authoritative for this turn):\n{unpackaged_findings}",
        },
    ]
    full_totals = categorize_packed_messages(full_messages)
    unpackaged_totals = categorize_packed_messages(unpackaged)
    assert full_totals["inspect"] < unpackaged_totals["inspect"]


def _fake_user() -> UserRecord:
    return UserRecord(
        id="admin-1",
        email="operator@example.com",
        username="admin",
        password_hash="x",
        role="admin",
        is_active=True,
    )


def test_llm_result_inspections_stay_full_with_five_inspect_calls(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """HTTP inspections[] keeps all steps; compaction is prompt-only."""
    exec_count = 0
    completions = [
        '{"tool":"inspect_host","args":{"action_key":"docker_ps","host":"106","params":{}}}',
    ] * 5 + [
        '{"reply":"done","setting_change":null,"host_action_id":null}',
    ]

    def fake_run(*a: Any, **k: Any) -> ExecResult:
        nonlocal exec_count
        exec_count += 1
        return ExecResult(
            ok=True,
            command_run="docker ps",
            stdout=f"RUNTIME_STDOUT_{exec_count}",
            stderr="",
            exit_code=0,
        )

    monkeypatch.setattr(
        "src.llm.client.get_agent_completion_turn",
        lambda messages, **kw: ChatTurn(content=completions.pop(0), tool_calls=[]),
    )
    monkeypatch.setattr(admin_module, "run_inspect_action_sync", fake_run)
    monkeypatch.setattr(
        admin_module,
        "validate_proposal",
        lambda action_key, host, params, config, enforce_enabled=True: (
            MagicMock(),
            {"repo_dir": "/tmp"},
            dict(params or {}),
        ),
    )
    monkeypatch.setattr(
        admin_module,
        "_host_actions_readiness",
        lambda: {
            "env_enabled": True,
            "ssh_key_present": True,
            "ready": True,
            "missions_ready": True,
            "ssh_key_path": "/app/secrets/host-actions/id_ed25519",
        },
    )
    monkeypatch.setattr(admin_module, "host_actions_enabled", lambda: True)

    result = admin_module._monitoring_agent_llm_result(
        message="inspect five times",
        user=_fake_user(),
        context={"ai_settings": []},
        config={},
        settings=MagicMock(),
        actions=MagicMock(),
        host_store=MagicMock(),
    )

    assert exec_count == 5
    assert len(result["inspections"]) == 5
