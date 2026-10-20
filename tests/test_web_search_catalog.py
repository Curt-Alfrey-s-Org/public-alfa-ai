"""web_search catalog action: inspectable, internal HTTP only, fail-closed."""

from __future__ import annotations

import pytest

from src.ops.host_catalog import (
    build_command,
    is_inspectable,
    is_web_search_inspect_action,
    validate_proposal,
)
from src.ops.web_search_executor import execute_internal_web_search


_HOST_111 = {
    "key": "111",
    "os_type": "linux",
    "repo_dir": "/mnt/hub/alfa-ai/repo/alfa-ai",
    "lan_ip": "hub",
    "ssh_user": "operator",
}


def test_web_search_is_inspectable() -> None:
    assert is_inspectable("web_search") is True
    assert is_web_search_inspect_action("web_search") is True
    assert is_web_search_inspect_action("docker_ps") is False


def test_web_search_build_command_raises() -> None:
    _, host_cfg, params = validate_proposal(
        "web_search",
        "111",
        {"query": "fastapi lifespan"},
        {},
        enforce_enabled=False,
    )
    with pytest.raises(ValueError, match="no SSH"):
        build_command("web_search", host_cfg, params, {})


def test_web_search_validate_requires_query() -> None:
    with pytest.raises(ValueError, match="query"):
        validate_proposal("web_search", "111", {}, {}, enforce_enabled=False)


def test_web_search_disabled_fail_closed(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("ALFA_AI_WEB_SEARCH_ENABLED", raising=False)
    result = execute_internal_web_search({"query": "fastapi lifespan"})
    assert result.ok is False
    assert result.exit_code == 1
    assert "disabled" in result.stderr.lower()


def test_web_search_host_actions_disabled_still_runs(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Internal web_search branch runs before ALFA_AI_HOST_ACTIONS_ENABLED gate."""
    monkeypatch.setenv("ALFA_AI_WEB_SEARCH_ENABLED", "1")

    def fake_search(query: str, max_results=None):
        return {
            "ok": True,
            "query": query,
            "results": [{"title": "t", "url": "https://example.com", "content": "c"}],
            "truncated": False,
        }

    monkeypatch.setattr(
        "src.ops.web_search_executor.web_search",
        fake_search,
    )
    monkeypatch.setenv("ALFA_AI_HOST_ACTIONS_ENABLED", "0")
    result = execute_internal_web_search({"query": "test query"})
    assert result.ok is True
    assert result.exit_code == 0
    assert "example.com" in result.stdout
