"""Capability packs for Ask ALFa host actions (grouped enable/disable).

See docs/ADMIN_AI_HOST_ACTIONS.md. Packs are derived views over disabled_actions --
no separate DB column.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True, slots=True)
class ActionPack:
    id: str
    label: str
    description: str
    actions: tuple[str, ...]
    # When True, pack members are left enabled on fresh install (unless also in
    # SENSITIVE_ACTION_DEFAULTS).
    default_on: bool


# Sensitive actions start disabled until the operator enables their pack.
# Monitoring read+ops (prom_*, reload, bearer refresh) stay available by default
# so Ask ALFa can diagnose flaps once SSH + env are on; Approve still gates mutates.
SENSITIVE_ACTION_DEFAULTS: frozenset[str] = frozenset(
    {
        "run_command",
        "git_pull",
        "git_commit",
        "git_push",
        "docker_restart",
        "brain_redeploy_api",
        "cluster_start",
        "cluster_stop",
        "ci_repro_rankings_lint",
        "ci_repro_contracts_tests",
        "ci_repro_market_tests",
        "apply_patch",
        "ha_switch_on",
        "ha_switch_off",
        "ha_dump_tick",
        "ha_set_number",
        "ha_select_option",
    }
)

ACTION_PACKS: tuple[ActionPack, ...] = (
    ActionPack(
        id="read_basics",
        label="Read basics",
        description="Safe read-only host inspection (containers, disk, git status, health).",
        actions=(
            "docker_ps",
            "docker_stats",
            "docker_logs",
            "disk_usage",
            "health_check",
            "git_status",
            "repo_tree",
            "repo_read_file",
            "repo_grep",
            "web_search",
        ),
        default_on=True,
    ),
    ActionPack(
        id="monitoring",
        label="Monitoring (monitor)",
        description=(
            "Prometheus diagnose on monitor (targets, alerts, PromQL) plus bearer refresh "
            "and config reload. Enable this pack for flap/incident-metrics work."
        ),
        actions=(
            "prom_targets",
            "prom_alerts",
            "prom_query",
            "prometheus_reload",
            "refresh_prometheus_bearer",
        ),
        default_on=True,
    ),
    ActionPack(
        id="git_sync",
        label="Git sync",
        description="Pull / commit / push on a host's repo_dir (owning clone only).",
        actions=("git_pull", "git_commit", "git_push"),
        default_on=False,
    ),
    ActionPack(
        id="cluster",
        label="Cluster lifecycle",
        description="Orchestrator start/stop, brain API redeploy, non-inference container restart.",
        actions=(
            "docker_restart",
            "brain_redeploy_api",
            "cluster_start",
            "cluster_stop",
        ),
        default_on=False,
    ),
    ActionPack(
        id="consumer_ci",
        label="Consumer CI reproduce",
        description=(
            "Named reproduce commands for contracts-bot, Rankings-Bot, and "
            "market-pie5-bot CI failures (lint/tests on owning host)."
        ),
        actions=(
            "ci_repro_rankings_lint",
            "ci_repro_contracts_tests",
            "ci_repro_market_tests",
        ),
        default_on=False,
    ),
    ActionPack(
        id="consumer_patch",
        label="Consumer single-file patch",
        description=(
            "Opt-in apply_patch on one file in a consumer repo (max lines; "
            "no secrets or workflow files). Default off."
        ),
        actions=("apply_patch",),
        default_on=False,
    ),
    ActionPack(
        id="home_energy",
        label="Home energy (HA)",
        description=(
            "Home Assistant REST on apps: read dump-load sensors, optional allowlisted "
            "switch one-shots, observe dump tick (HA automations own on/off; no LLM / 7B / 27B). "
            "Internal httpx (not SSH)."
        ),
        actions=(
            "ha_get_states",
            "ha_get_state",
            "ha_get_forecasts",
            "ha_switch_on",
            "ha_switch_off",
            "ha_dump_tick",
            "ha_set_number",
            "ha_select_option",
        ),
        default_on=False,
    ),
    ActionPack(
        id="freeform",
        label="Freeform shell",
        description="Arbitrary shell/PowerShell via run_command (highest risk; keep off by default).",
        actions=("run_command",),
        default_on=False,
    ),
    ActionPack(
        id="script_verify",
        label="Script verify (read-only)",
        description=(
            "Named read-only script verify for Grok Bot / Ask ALFa loop "
            "(brain_verify, hub_diag_read, ps_syntax_check, draft_judge_guide)."
        ),
        actions=(
            "brain_verify",
            "hub_diag_read",
            "ps_syntax_check",
            "draft_judge_guide",
        ),
        default_on=True,
    ),
    ActionPack(
        id="missions",
        label="Missions",
        description=(
            "Chat-first feeder control: pause/resume the audit feeder and "
            "clear wedged stuck missions on hub. Host audits run in Ask ALFa inspect."
        ),
        actions=(
            "mission_enqueue",
            "mission_feeder_pause",
            "mission_feeder_resume",
            "mission_clear_stuck",
        ),
        default_on=True,
    ),
)


def list_action_packs() -> list[dict[str, Any]]:
    return [
        {
            "id": p.id,
            "label": p.label,
            "description": p.description,
            "actions": list(p.actions),
            "default_on": p.default_on,
        }
        for p in ACTION_PACKS
    ]


def pack_by_id(pack_id: str) -> ActionPack | None:
    for pack in ACTION_PACKS:
        if pack.id == pack_id:
            return pack
    return None


def pack_status(disabled_actions: set[str] | list[str]) -> list[dict[str, Any]]:
    """Return packs with enabled=True when every member action is allowed."""
    disabled = {str(k).strip() for k in disabled_actions if str(k).strip()}
    out: list[dict[str, Any]] = []
    for pack in ACTION_PACKS:
        enabled_members = [a for a in pack.actions if a not in disabled]
        out.append(
            {
                "id": pack.id,
                "label": pack.label,
                "description": pack.description,
                "actions": list(pack.actions),
                "default_on": pack.default_on,
                "enabled": len(enabled_members) == len(pack.actions),
                "enabled_count": len(enabled_members),
                "total_count": len(pack.actions),
            }
        )
    return out


def apply_pack_toggle(
    disabled_actions: list[str],
    *,
    pack_id: str,
    enabled: bool,
    known_actions: set[str],
) -> list[str]:
    """Return a new disabled_actions list after enabling/disabling a pack."""
    pack = pack_by_id(pack_id)
    if pack is None:
        raise ValueError(f"Unknown pack_id: {pack_id}")
    disabled = {str(k).strip() for k in disabled_actions if str(k).strip()}
    members = [a for a in pack.actions if a in known_actions]
    if enabled:
        disabled -= set(members)
    else:
        disabled |= set(members)
    return sorted(disabled)


def pack_for_action(action_key: str) -> ActionPack | None:
    for pack in ACTION_PACKS:
        if action_key in pack.actions:
            return pack
    return None


_AUTH_LEVEL_LABELS: dict[int, str] = {
    1: "Read",
    2: "Ops (mutating)",
    3: "Destructive",
}


def auth_level_label(risk_tier: int) -> str:
    return _AUTH_LEVEL_LABELS.get(risk_tier, _AUTH_LEVEL_LABELS[3])


def proposal_enable_meta(
    action_key: str,
    disabled_actions: set[str] | list[str],
    *,
    risk_tier: int,
) -> dict[str, Any]:
    """Auth + will-enable fields for Approve cards (soft-disabled packs)."""
    disabled = {str(k).strip() for k in disabled_actions if str(k).strip()}
    soft_disabled = action_key in disabled
    pack = pack_for_action(action_key)
    will_enable: list[str] = []
    if soft_disabled and pack is not None:
        will_enable.append(pack.label)
    return {
        "risk_tier": risk_tier,
        "auth_level": auth_level_label(risk_tier),
        "requires_ack": risk_tier >= 2,
        "soft_disabled": soft_disabled,
        "will_enable_packs": will_enable,
        "pack_id": pack.id if pack else None,
        "pack_label": pack.label if pack else None,
    }


def enable_action_in_disabled_list(
    disabled_actions: list[str],
    action_key: str,
    *,
    known_actions: set[str],
) -> list[str]:
    """Remove action_key (and prefer enabling its whole pack) from disabled_actions."""
    if action_key not in known_actions:
        return sorted({str(k).strip() for k in disabled_actions if str(k).strip()})
    pack = pack_for_action(action_key)
    if pack is not None:
        return apply_pack_toggle(
            disabled_actions,
            pack_id=pack.id,
            enabled=True,
            known_actions=known_actions,
        )
    disabled = {str(k).strip() for k in disabled_actions if str(k).strip()}
    disabled.discard(action_key)
    return sorted(disabled)
