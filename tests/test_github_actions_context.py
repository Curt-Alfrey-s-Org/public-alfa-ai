"""Tests for read-only GitHub Actions context (Wave C)."""

from __future__ import annotations

import pytest

from src.ops.github_actions_context import github_token_configured


def test_github_token_not_configured_by_default(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("ALFA_AI_GITHUB_TOKEN", raising=False)
    monkeypatch.delenv("ALFA_AI_REMEDIATION_GITHUB_TOKEN", raising=False)
    assert github_token_configured() is False


def test_github_token_fallback_to_remediation(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("ALFA_AI_GITHUB_TOKEN", raising=False)
    monkeypatch.setenv("ALFA_AI_REMEDIATION_GITHUB_TOKEN", "test-token")
    assert github_token_configured() is True
