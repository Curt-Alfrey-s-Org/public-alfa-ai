"""Capability packs and new monitoring/git catalog actions."""

from __future__ import annotations

import pytest

from src.ops.action_packs import (
    ACTION_PACKS,
    SENSITIVE_ACTION_DEFAULTS,
    apply_pack_toggle,
    pack_status,
)
from src.ops.host_catalog import build_command, list_all_catalog_entries, validate_proposal


def _catalog_keys() -> set[str]:
    return {e["key"] for e in list_all_catalog_entries()}


def test_every_catalog_action_is_in_exactly_one_pack() -> None:
    membership: dict[str, str] = {}
    for pack in ACTION_PACKS:
        for key in pack.actions:
            assert key in _catalog_keys(), f"pack {pack.id} references unknown action {key}"
            assert key not in membership, f"{key} in both {membership[key]} and {pack.id}"
            membership[key] = pack.id
    missing = _catalog_keys() - set(membership)
    assert not missing, f"catalog actions missing from packs: {sorted(missing)}"


def test_sensitive_defaults_cover_high_risk_packs() -> None:
    assert "run_command" in SENSITIVE_ACTION_DEFAULTS
    assert "cluster_start" in SENSITIVE_ACTION_DEFAULTS
    assert "git_push" in SENSITIVE_ACTION_DEFAULTS
    # Monitoring mutate stays available by default (Approve still required).
    assert "prometheus_reload" not in SENSITIVE_ACTION_DEFAULTS
    assert "refresh_prometheus_bearer" not in SENSITIVE_ACTION_DEFAULTS


def test_pack_status_and_toggle() -> None:
    disabled = sorted(SENSITIVE_ACTION_DEFAULTS)
    status = {p["id"]: p for p in pack_status(disabled)}
    assert status["read_basics"]["enabled"] is True
    assert status["monitoring"]["enabled"] is True
    assert status["freeform"]["enabled"] is False
    assert status["git_sync"]["enabled"] is False

    known = _catalog_keys()
    after_on = apply_pack_toggle(disabled, pack_id="freeform", enabled=True, known_actions=known)
    assert "run_command" not in after_on
    after_off = apply_pack_toggle(after_on, pack_id="monitoring", enabled=False, known_actions=known)
    for key in ("prom_targets", "prometheus_reload", "refresh_prometheus_bearer"):
        assert key in after_off


def test_docker_stats_build_command() -> None:
    linux_host = {"key": "111", "os_type": "linux", "repo_dir": "/mnt/repo"}
    cmd, timeout = build_command("docker_stats", linux_host, {})
    assert "docker stats --no-stream" in cmd
    assert "CPUPerc" in cmd
    assert timeout >= 60

    win_host = {
        "key": "93",
        "os_type": "windows",
        "repo_dir": r"C:/Users/operator\alfa-ai",
    }
    win_cmd, _ = build_command("docker_stats", win_host, {})
    assert "wsl -d Ubuntu docker stats --no-stream" in win_cmd


def test_prom_query_build_command_uses_data_urlencode() -> None:
    cmd, timeout = build_command(
        "prom_query",
        {"key": "107", "os_type": "linux", "repo_dir": "/home/operator/monitoring"},
        {"query": 'up{job="alfa-ai-incident-metrics"}'},
    )
    assert "--data-urlencode" in cmd
    assert "query=" in cmd
    assert "alfa-ai-incident-metrics" in cmd
    assert timeout >= 30


def test_prom_query_rejects_unsafe_query() -> None:
    with pytest.raises(ValueError, match="prom_query"):
        validate_proposal(
            "prom_query",
            "107",
            {"query": "up; rm -rf /"},
            None,
        )


def test_propose_allows_soft_disabled_run_command() -> None:
    config = {"disabled_actions": ["run_command"]}
    spec, _, params = validate_proposal(
        "run_command",
        "106",
        {"command": "cd /home/operator/USPBF && bash scripts/switch-site.sh production"},
        config,
        enforce_enabled=False,
    )
    assert spec.key == "run_command"
    assert "switch-site.sh" in params["command"]
    with pytest.raises(ValueError, match="disabled"):
        validate_proposal(
            "run_command",
            "106",
            {"command": "echo ok"},
            config,
            enforce_enabled=True,
        )


def test_proposal_enable_meta_and_enable_action() -> None:
    from src.ops.action_packs import enable_action_in_disabled_list, proposal_enable_meta

    disabled = sorted(SENSITIVE_ACTION_DEFAULTS)
    meta = proposal_enable_meta("run_command", disabled, risk_tier=3)
    assert meta["soft_disabled"] is True
    assert meta["auth_level"] == "Destructive"
    assert "Freeform shell" in meta["will_enable_packs"]

    known = _catalog_keys()
    after = enable_action_in_disabled_list(disabled, "run_command", known_actions=known)
    assert "run_command" not in after
    meta2 = proposal_enable_meta("run_command", after, risk_tier=3)
    assert meta2["soft_disabled"] is False
    assert meta2["will_enable_packs"] == []


def test_catalog_for_llm_includes_soft_disabled() -> None:
    from src.ops.host_catalog import get_catalog_for_llm

    rows = get_catalog_for_llm({"disabled_actions": ["run_command", "git_push"]})
    by_key = {r["key"]: r for r in rows}
    assert by_key["run_command"]["soft_disabled"] is True
    assert by_key["docker_ps"]["soft_disabled"] is False
    assert "run_command" in by_key



def test_git_commit_and_push_commands() -> None:
    host = {
        "key": "93",
        "os_type": "windows",
        "repo_dir": r"C:/Users/operator\alfa-ai",
    }
    commit_cmd, _ = build_command(
        "git_commit",
        host,
        {"message": "fix flap alerts", "paths": "docs/AI_ACTIONS.md"},
    )
    assert "git commit" in commit_cmd
    assert "fix flap alerts" in commit_cmd
    push_cmd, _ = build_command("git_push", host, {})
    assert "git push origin main" in push_cmd


def test_prometheus_reload_and_bearer_refresh() -> None:
    host = {"key": "107", "os_type": "linux", "repo_dir": "/home/operator/monitoring"}
    reload_cmd, _ = build_command("prometheus_reload", host, {})
    assert "/-/reload" in reload_cmd
    assert "POST" in reload_cmd
    bearer_cmd, _ = build_command("refresh_prometheus_bearer", host, {})
    assert "refresh-alfa-ai-prometheus-bearer.sh" in bearer_cmd


def test_script_verify_build_commands() -> None:
    brain_host = {
        "key": "111",
        "os_type": "linux",
        "repo_dir": "/mnt/hub/alfa-ai/repo/alfa-ai",
    }
    brain_cmd, brain_timeout = build_command("brain_verify", brain_host, {})
    assert brain_cmd == (
        "cd '/mnt/hub/alfa-ai/repo/alfa-ai' && bash scripts/brain_verify.sh"
    )
    assert brain_timeout >= 180

    hub_host = {"key": "148", "os_type": "linux", "repo_dir": "/home/operator/alfa-ai"}
    hub_cmd, hub_timeout = build_command("hub_diag_read", hub_host, {})
    assert hub_cmd == "cd '/home/operator/alfa-ai' && bash scripts/diagnose-inference-ai.sh"
    assert hub_timeout >= 180

    win_host = {
        "key": "93",
        "os_type": "windows",
        "repo_dir": r"C:/Users/operator\alfa-ai",
    }
    ps_win_cmd, _ = build_command("ps_syntax_check", win_host, {})
    assert "Set-Location -LiteralPath" in ps_win_cmd
    assert "Test-AlfaPowerShellScriptSyntax.ps1" in ps_win_cmd
    assert r"C:/Users/operator\alfa-ai\deploy" in ps_win_cmd
    assert "-Recurse deploy" not in ps_win_cmd

    linux_host = {
        "key": "105",
        "os_type": "linux",
        "repo_dir": "/home/operator/alfa-ai",
    }
    ps_linux_cmd, _ = build_command("ps_syntax_check", linux_host, {})
    assert "pwsh -NoProfile -File" in ps_linux_cmd
    assert "Test-AlfaPowerShellScriptSyntax.ps1 -Recurse deploy" in ps_linux_cmd


def test_script_verify_pack_membership() -> None:
    from src.ops.action_packs import pack_by_id

    pack = pack_by_id("script_verify")
    assert pack is not None
    assert pack.default_on is True
    assert set(pack.actions) == {
        "brain_verify",
        "hub_diag_read",
        "ps_syntax_check",
        "draft_judge_guide",
    }
    for key in pack.actions:
        assert key not in SENSITIVE_ACTION_DEFAULTS


def test_draft_judge_guide_validate_and_build() -> None:
    brain_host = {
        "key": "111",
        "os_type": "linux",
        "repo_dir": "/mnt/hub/alfa-ai/repo/alfa-ai",
    }
    task = "Summarize inference health checks for docs"
    cmd, timeout = build_command("draft_judge_guide", brain_host, {"task": task})
    assert cmd == (
        "cd '/mnt/hub/alfa-ai/repo/alfa-ai' && python3 scripts/eval/run_7b_27b_guide.py "
        f"--task '{task}'"
    )
    assert timeout >= 900

    win_host = {
        "key": "93",
        "os_type": "windows",
        "repo_dir": r"C:/Users/operator\alfa-ai",
    }
    win_cmd, _ = build_command(
        "draft_judge_guide",
        win_host,
        {"task": "Draft a README section on cache roots"},
    )
    assert "Set-Location -LiteralPath" in win_cmd
    assert "python scripts\\eval\\run_7b_27b_guide.py --task" in win_cmd

    with pytest.raises(ValueError, match="non-empty"):
        validate_proposal(
            "draft_judge_guide",
            "111",
            {"task": "   "},
            None,
            enforce_enabled=False,
        )
    with pytest.raises(ValueError, match="secrets"):
        validate_proposal(
            "draft_judge_guide",
            "111",
            {"task": "Use api_key=sk-secret123 in the draft"},
            None,
            enforce_enabled=False,
        )
    with pytest.raises(ValueError, match="not allowed on host"):
        validate_proposal(
            "draft_judge_guide",
            "148",
            {"task": "ok task"},
            None,
            enforce_enabled=False,
        )

    from src.ops.host_catalog import summarize_proposal

    summary = summarize_proposal(
        "draft_judge_guide",
        "111",
        {"task": task},
        None,
    )
    assert f"with task: {task}" in summary
    assert "read-only script verify" in summary
