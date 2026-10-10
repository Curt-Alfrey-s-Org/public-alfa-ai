"""Inspect-then-act catalog: repo_* actions, is_inspectable, inspect executor."""

from __future__ import annotations

import asyncio
from unittest.mock import AsyncMock, patch

import pytest

from src.api.models.ai_setting import (
    POLICY_SETTING_KEYS,
    inspect_autorun_enabled,
    validate_setting_value,
)
from src.ops.action_packs import pack_by_id
from src.ops.exec_result import ExecResult
from src.ops.host_catalog import (
    build_command,
    get_catalog_for_llm,
    is_inspectable,
    summarize_proposal,
    validate_proposal,
)
from src.ops.inspect_executor import inspection_step_dict, run_inspect_action_sync

_LINUX_HOST_106 = {
    "key": "106",
    "os_type": "linux",
    "repo_dir": "/home/operator/rankings-bot",
    "lan_ip": "orchestrator",
    "ssh_user": "operator",
}


def test_is_inspectable_true_for_docker_ps_and_repo_actions() -> None:
    assert is_inspectable("docker_ps") is True
    assert is_inspectable("repo_tree") is True
    assert is_inspectable("repo_read_file") is True
    assert is_inspectable("repo_grep") is True


def test_is_inspectable_false_for_mutating_and_never_list() -> None:
    assert is_inspectable("run_command") is False
    assert is_inspectable("git_pull") is False
    assert is_inspectable("brain_verify") is False
    assert is_inspectable("hub_diag_read") is False
    assert is_inspectable("ps_syntax_check") is False
    assert is_inspectable("draft_judge_guide") is False


def test_repo_read_file_rejects_bad_paths() -> None:
    for bad in ("../etc/passwd", "/etc/passwd", ".env"):
        with pytest.raises(ValueError):
            validate_proposal(
                "repo_read_file",
                "106",
                {"relative_path": bad},
                {},
                enforce_enabled=False,
            )


def test_repo_grep_rejects_single_quote_and_long_pattern() -> None:
    with pytest.raises(ValueError, match="unsafe"):
        validate_proposal(
            "repo_grep",
            "106",
            {"pattern": "foo'bar"},
            {},
            enforce_enabled=False,
        )
    with pytest.raises(ValueError, match="1-120"):
        validate_proposal(
            "repo_grep",
            "106",
            {"pattern": "x" * 121},
            {},
            enforce_enabled=False,
        )


def test_repo_dir_override_allowlist() -> None:
    with pytest.raises(ValueError, match="allowlist"):
        validate_proposal(
            "repo_tree",
            "106",
            {"repo_dir": "/tmp/evil"},
            {},
            enforce_enabled=False,
        )
    _, _, norm = validate_proposal(
        "repo_tree",
        "106",
        {"repo_dir": "/home/operator/rankings-bot", "limit": 50},
        {},
        enforce_enabled=False,
    )
    assert norm["repo_dir"] == "/home/operator/rankings-bot"
    assert norm["limit"] == 50


def test_repo_actions_rejected_on_windows() -> None:
    with pytest.raises(ValueError, match="Windows"):
        validate_proposal(
            "repo_tree",
            "93",
            {},
            {},
            enforce_enabled=False,
        )


def test_build_command_repo_tree() -> None:
    cmd, timeout = build_command("repo_tree", _LINUX_HOST_106, {"subdir": "docs", "limit": 200})
    assert cmd == "git -C '/home/operator/rankings-bot' ls-files -- 'docs' | head -n 200"
    assert timeout == 60

    cmd_no_sub, _ = build_command("repo_tree", _LINUX_HOST_106, {"limit": 100})
    assert cmd_no_sub == "git -C '/home/operator/rankings-bot' ls-files | head -n 100"


def test_build_command_repo_read_file() -> None:
    cmd, _ = build_command(
        "repo_read_file",
        _LINUX_HOST_106,
        {"relative_path": "README.md", "start": 5, "lines": 10},
    )
    assert cmd == (
        "git -C '/home/operator/rankings-bot' ls-files --error-unmatch -- 'README.md' >/dev/null "
        "&& sed -n '5,14p' -- '/home/operator/rankings-bot/README.md'"
    )


def test_repo_grep_rejects_command_substitution_tokens() -> None:
    for bad in ("$(id)", "foo`id`bar"):
        with pytest.raises(ValueError, match="unsafe"):
            validate_proposal(
                "repo_grep",
                "106",
                {"pattern": bad},
                {},
                enforce_enabled=False,
            )


def test_repo_read_file_rejects_key_material_paths() -> None:
    for bad in (".ssh/config", "deploy/id_ed25519", "ops/known_hosts", "certs/server.key"):
        with pytest.raises(ValueError, match="blocked"):
            validate_proposal(
                "repo_read_file",
                "106",
                {"relative_path": bad},
                {},
                enforce_enabled=False,
            )


def test_build_command_repo_grep() -> None:
    cmd, _ = build_command(
        "repo_grep",
        _LINUX_HOST_106,
        {"pattern": "scraper", "subdir": "src", "limit": 50},
    )
    assert (
        cmd
        == "git -C '/home/operator/rankings-bot' grep -n -I -e 'scraper' -- 'src' | head -n 50"
    )
    cmd_no_sub, _ = build_command(
        "repo_grep",
        _LINUX_HOST_106,
        {"pattern": "TODO"},
    )
    assert cmd_no_sub == "git -C '/home/operator/rankings-bot' grep -n -I -e 'TODO' | head -n 100"


def test_summarize_proposal_repo_tree() -> None:
    summary = summarize_proposal(
        "repo_tree",
        "106",
        {"subdir": "docs", "limit": 200},
        {},
    )
    assert "Read-only repo_tree on host 106" in summary
    assert "/home/operator/rankings-bot" in summary
    assert "subdir=docs" in summary
    assert "limit=200" in summary


def test_read_basics_pack_includes_repo_actions() -> None:
    pack = pack_by_id("read_basics")
    assert pack is not None
    assert "repo_tree" in pack.actions
    assert "repo_read_file" in pack.actions
    assert "repo_grep" in pack.actions


def test_catalog_for_llm_includes_inspectable_flag() -> None:
    rows = get_catalog_for_llm({})
    by_key = {r["key"]: r for r in rows}
    assert by_key["docker_ps"]["inspectable"] is True
    assert by_key["run_command"]["inspectable"] is False
    assert by_key["brain_verify"]["inspectable"] is False
    assert by_key["repo_tree"]["inspectable"] is True


def test_run_inspect_action_sync_rejects_git_pull() -> None:
    with pytest.raises(ValueError, match="not inspectable"):
        run_inspect_action_sync("git_pull", _LINUX_HOST_106, {})


def test_run_inspect_action_sync_rejects_running_loop() -> None:
    async def _call_from_loop() -> None:
        with pytest.raises(RuntimeError, match="must not be called from a running event loop"):
            run_inspect_action_sync("docker_ps", _LINUX_HOST_106, {})

    asyncio.run(_call_from_loop())


def test_run_inspect_action_sync_calls_execute() -> None:
    fake = ExecResult(ok=True, command_run="docker ps", stdout="ok", stderr="", exit_code=0)
    with patch(
        "src.ops.inspect_executor.execute_host_action",
        new_callable=AsyncMock,
        return_value=fake,
    ):
        result = run_inspect_action_sync("docker_ps", _LINUX_HOST_106, {})
    assert result.ok is True
    assert result.stdout == "ok"


def test_inspection_step_dict_shape() -> None:
    result = ExecResult(
        ok=False,
        command_run="git status",
        stdout="",
        stderr="err",
        exit_code=1,
    )
    step = inspection_step_dict("git_status", "106", result, 42)
    assert step == {
        "action_key": "git_status",
        "host": "106",
        "command_run": "git status",
        "stdout": "",
        "stderr": "err",
        "exit_code": 1,
        "ok": False,
        "duration_ms": 42,
    }


def test_ask_alfa_inspect_autorun_setting_default_true() -> None:
    assert validate_setting_value("ask_alfa_inspect_autorun", "true") == "true"
    assert inspect_autorun_enabled({}) is True
    assert inspect_autorun_enabled([]) is True
    assert inspect_autorun_enabled({"ask_alfa_inspect_autorun": "false"}) is False
    assert "ask_alfa_inspect_autorun" in POLICY_SETTING_KEYS


def test_ha_policy_settings_in_policy_keys() -> None:
    assert "ha_solar_dump_enabled" in POLICY_SETTING_KEYS
    assert "ha_solar_dump_auto_actuate" in POLICY_SETTING_KEYS
    assert "ha_switch_allowlist" in POLICY_SETTING_KEYS


def test_ha_switch_allowlist_normalizes_entity_ids() -> None:
    value = validate_setting_value(
        "ha_switch_allowlist",
        " switch.a , switch.b ",
    )
    assert value == "switch.a,switch.b"
