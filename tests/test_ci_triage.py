"""Tests for paste-first CI triage (Ask ALFa cursor offload Wave A)."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any
from unittest.mock import MagicMock

import pytest

from src.api.ask_alfa_router import try_handle_deterministic
from src.ops.ci_triage import try_parse_ci_triage

RANKINGS_LINT_PASTE = """
[example/Rankings-Bot] Run failed: Lint - main (abc123)
https://github.com/example/Rankings-Bot/actions/runs/12345
flake8 api scrapers database tests --count --select=E9,F63,F7,F82
"""

CONTRACTS_TESTS_PASTE = """
[example/contracts-bot] Run failed: Tests - main
workflow_run completed with failure
pytest tests/backend/test_litellm_health.py
"""


@dataclass
class _FakeHostRecord:
    id: str
    summary: str


def _stores() -> tuple[MagicMock, MagicMock, MagicMock]:
    host_store = MagicMock()
    host_store.create_pending.return_value = _FakeHostRecord(
        id="ci-act-1",
        summary="ci_repro_rankings_lint on host 106 [read-only]",
    )
    return host_store, MagicMock(), MagicMock()


@pytest.fixture(autouse=True)
def _enable_host_actions(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_HOST_ACTIONS_ENABLED", "1")


def test_parse_rankings_lint_paste() -> None:
    triage = try_parse_ci_triage(RANKINGS_LINT_PASTE)
    assert triage is not None
    assert triage.repo == "Rankings-Bot"
    assert triage.host == "106"
    assert triage.failure_class == "lint"
    assert triage.catalog_action_key == "ci_repro_rankings_lint"
    assert "flake8" in triage.reproduce_command
    assert "Cursor" in triage.cursor_handoff or "Fix CI" in triage.cursor_handoff


def test_parse_contracts_tests_paste() -> None:
    triage = try_parse_ci_triage(CONTRACTS_TESTS_PASTE)
    assert triage is not None
    assert triage.repo == "contracts-bot"
    assert triage.host == "105"
    assert triage.catalog_action_key == "ci_repro_contracts_tests"
    assert "pytest" in triage.reproduce_command


def test_ci_triage_router_proposes_catalog_action() -> None:
    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        RANKINGS_LINT_PASTE,
        {"host_actions_enabled": True, "ai_settings": []},
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert result.get("host_action_proposal") is not None
    assert result["host_action_proposal"]["id"] == "ci-act-1"
    assert result.get("cursor_handoff")
    host_store.create_pending.assert_called_once()
    call = host_store.create_pending.call_args
    assert call[0][0] == "ci_repro_rankings_lint"
    assert call[0][1] == "106"


def test_ci_triage_no_llm(monkeypatch: pytest.MonkeyPatch) -> None:
    llm_mock = MagicMock(
        side_effect=AssertionError("get_agent_completion must not run on CI triage")
    )
    monkeypatch.setattr("src.llm.client.get_agent_completion", llm_mock)

    host_store, settings_store, actions_store = _stores()
    result = try_handle_deterministic(
        RANKINGS_LINT_PASTE,
        {"host_actions_enabled": True, "ai_settings": []},
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    llm_mock.assert_not_called()


def test_github_ci_summary_from_context() -> None:
    host_store, settings_store, actions_store = _stores()
    context = {
        "host_actions_enabled": True,
        "ai_settings": [],
        "github_ci": {
            "configured": True,
            "repos": [
                {
                    "repo": "example/Rankings-Bot",
                    "latest_failure": {
                        "name": "Lint",
                        "head_branch": "main",
                        "html_url": "https://github.com/example/actions/1",
                        "created_at": "2026-07-11",
                        "log_excerpt": "flake8 failed",
                    },
                }
            ],
        },
    }
    result = try_handle_deterministic(
        "What's failing in CI?",
        context,
        host_store=host_store,
        settings_store=settings_store,
        actions_store=actions_store,
        config={},
        operator_email="operator@example.com",
    )
    assert result is not None
    assert "Rankings-Bot" in result["reply"]
    assert "Lint" in result["reply"]

