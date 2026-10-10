"""Tests for MCP inspect authorization (no live MCP session or SSH required)."""

from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from src.config import mcp_enabled
from src.ops.mcp_inspect import authorize_mcp_inspect


@pytest.fixture(autouse=True)
def _clear_mcp_flag(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("ALFA_AI_MCP_ENABLED", raising=False)


def test_mcp_enabled_default_off() -> None:
    assert mcp_enabled() is False


@pytest.mark.parametrize(
    "action_key",
    ["run_command", "ha_switch_on", "cluster_start"],
)
def test_authorize_rejects_forbidden_without_ssh(action_key: str) -> None:
    with patch("src.ops.mcp_inspect.validate_proposal") as validate:
        with patch(
            "src.ops.ssh_executor.execute_host_action",
            new_callable=AsyncMock,
        ) as execute:
            result = authorize_mcp_inspect(action_key, "93", {})
            assert result["ok"] is False
            assert "error" in result
            validate.assert_not_called()
            execute.assert_not_called()


def test_authorize_rejects_non_inspectable_without_ssh() -> None:
    with patch("src.ops.mcp_inspect.is_inspectable", return_value=False):
        with patch("src.ops.mcp_inspect.validate_proposal") as validate:
            result = authorize_mcp_inspect("brain_verify", "111", {})
            assert result["ok"] is False
            validate.assert_not_called()


def test_authorize_docker_ps_ok() -> None:
    host_cfg = {"key": "93", "lan_ip": "orchestrator"}
    spec = MagicMock(key="docker_ps")
    with patch(
        "src.ops.mcp_inspect.validate_proposal",
        return_value=(spec, host_cfg, {}),
    ):
        result = authorize_mcp_inspect("docker_ps", "93", {})
    assert result["ok"] is True
    assert result["action_key"] == "docker_ps"
    assert result["host"] == "93"
    assert result["spec_name"] == "docker_ps"
    assert result["host_cfg"] == host_cfg
    assert result["params"] == {}


def test_authorize_validate_proposal_error() -> None:
    with patch(
        "src.ops.mcp_inspect.validate_proposal",
        side_effect=ValueError("Unknown host: bad"),
    ):
        result = authorize_mcp_inspect("docker_ps", "bad", {})
    assert result["ok"] is False
    assert "Unknown host" in result["error"]
