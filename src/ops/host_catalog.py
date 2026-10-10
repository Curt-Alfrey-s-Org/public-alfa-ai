"""Host action catalog for admin AI: curated actions plus operator-approved freeform
commands (`run_command`). See docs/ADMIN_AI_HOST_ACTIONS.md."""

from __future__ import annotations

import json
import logging
import os
import re
from dataclasses import dataclass
from typing import Any

logger = logging.getLogger(__name__)

# inference / llama.cpp RPC containers must not be restarted piecemeal (no-piecemeal-cluster-scripts.mdc).
_inference_CONTAINER_BLOCKLIST = re.compile(
    r"(rpc-server|llamacpp-rpc|llamacpp-server|inference|pool-27|grev27|coordinator)",
    re.IGNORECASE,
)
_CONTAINER_NAME_PATTERN = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}$")
_REPO_DIR_PATTERN = re.compile(r"^[a-zA-Z0-9/_.\-:\\]+$")
# PromQL subset safe for shell (no single quotes -- use double-quoted labels in PromQL).
_PROMQL_SAFE = re.compile(r"""^[a-zA-Z0-9_\s\{\}\[\]\(\)=!~".:\-+*/,<>]+$""")
_GIT_MSG_SAFE = re.compile(r"""^[a-zA-Z0-9 .,_:;'"!?()/\-]{1,200}$""")
_GIT_PATH_SAFE = re.compile(r"^[a-zA-Z0-9_./\-]{1,180}$")
_GREP_PATTERN_SAFE = re.compile(
    r"""^[A-Za-z0-9_ .,:;/"()\[\]\-|*+?{}^$\\=<>@#%&!~]+$"""
)
# Defense in depth on top of single-quoting: never let a command-substitution
# token into the pattern even though quoting already neutralises it.
_GREP_PATTERN_FORBIDDEN_SUBSTRINGS = ("$(", "`")
# repo_read_file reads the working tree with sed; block key material and SSH
# config paths in addition to _APPLY_PATCH_BLOCKED.
_REPO_READ_BLOCKED = re.compile(
    r"(^|/)\.ssh(/|$)|id_ed25519|id_ecdsa|id_dsa|\.key$|known_hosts|authorized_keys|\.tokens?$",
    re.IGNORECASE,
)
_REPO_DIR_ALLOWLIST = frozenset(
    {
        "/home/operator/rankings-bot",
        "/home/operator/USPBF",
        "/home/operator/contracts-bot",
        "/home/operator/market-pie5-bot",
        "/home/operator/atems",
        "/home/operator/monitoring",
        "/mnt/hub/alfa-ai/repo/alfa-ai",
        "/home/operator/alfa-ai",
        "/home/operator/alfa-ai",
    }
)
_REPO_ACTION_KEYS = frozenset({"repo_tree", "repo_read_file", "repo_grep"})
_APPLY_PATCH_BLOCKED = re.compile(
    r"(\.env$|secrets/|credentials|\.github/workflows/|id_rsa|\.pem$)",
    re.IGNORECASE,
)
_APPLY_PATCH_MAX_LINES = 80
_APPLY_PATCH_MAX_CHARS = 8000
_DRAFT_JUDGE_TASK_MAX_LEN = 2000
_DRAFT_JUDGE_TASK_SECRET = re.compile(
    r"(?i)(password|secret|api[_-]?key|token|private[_-]?key|authorization)\s*[:=]\s*\S+"
    r"|bearer\s+[a-z0-9._\-+/=]{8,}",
)
_GIT_OWNING_HOSTS = frozenset({"93", "100", "105", "106", "107", "148"})

_DEFAULT_HOSTS: tuple[dict[str, Any], ...] = (
    {
        "key": "93",
        "name": "operator-93",
        "lan_ip": "orchestrator",
        "ssh_user": "operator",
        "os_type": "windows",
        "repo_dir": r"C:/Users/operator\alfa-ai",
    },
    {
        "key": "100",
        "name": "vm100",
        "lan_ip": "orchestrator",
        "ssh_user": "operator",
        "os_type": "linux",
        "repo_dir": "/home/operator/alfa-ai",
    },
    {
        "key": "102",
        "name": "market-102",
        "lan_ip": "market",
        "ssh_user": "operator",
        "os_type": "linux",
        "repo_dir": "/home/operator/market-pie5-bot",
    },
    {
        "key": "103",
        "name": "atems-103",
        "lan_ip": "atems",
        "ssh_user": "operator",
        "os_type": "linux",
        "repo_dir": "/home/operator/atems",
    },
    {
        "key": "105",
        "name": "apps-105",
        "lan_ip": "apps",
        "ssh_user": "ansible",
        "os_type": "linux",
        "repo_dir": "/home/operator/alfa-ai",
    },
    {
        "key": "106",
        "name": "probilliards-106",
        "lan_ip": "orchestrator",
        "ssh_user": "operator",
        "os_type": "linux",
        "repo_dir": "/home/operator/rankings-bot",
    },
    {
        "key": "107",
        "name": "monitoring-107",
        "lan_ip": "monitor",
        "ssh_user": "operator",
        "os_type": "linux",
        "repo_dir": "/home/operator/monitoring",
    },
    {
        "key": "111",
        "name": "brain-111",
        "lan_ip": "hub",
        "ssh_user": "operator",
        "os_type": "linux",
        "repo_dir": "/mnt/hub/alfa-ai/repo/alfa-ai",
        "health_url": "http://127.0.0.1:8420/alfa-ai/health",
    },
    {
        "key": "148",
        "name": "hub-148",
        "lan_ip": "orchestrator",
        "ssh_user": "operator",
        "os_type": "linux",
        "repo_dir": "/home/operator/alfa-ai",
    },
)


@dataclass(frozen=True, slots=True)
class ActionSpec:
    key: str
    description: str
    mutating: bool
    risk_tier: int  # 1=read, 2=ops, 3=destructive (tier-2 Approve ack required)
    timeout_sec: int
    allowed_hosts: frozenset[str] | None
    params: tuple[str, ...]


_CATALOG: dict[str, ActionSpec] = {
    "docker_ps": ActionSpec(
        key="docker_ps",
        description="List running Docker containers on the host.",
        mutating=False,
        risk_tier=1,
        timeout_sec=60,
        allowed_hosts=None,
        params=(),
    ),
    "docker_stats": ActionSpec(
        key="docker_stats",
        description="One-shot per-container CPU% and memory (docker stats --no-stream).",
        mutating=False,
        risk_tier=1,
        timeout_sec=90,
        allowed_hosts=None,
        params=(),
    ),
    "docker_logs": ActionSpec(
        key="docker_logs",
        description="Tail logs for one Docker container (params: container, optional tail default 100).",
        mutating=False,
        risk_tier=1,
        timeout_sec=120,
        allowed_hosts=None,
        params=("container", "tail"),
    ),
    "disk_usage": ActionSpec(
        key="disk_usage",
        description="Show disk usage on the host root/C: drive.",
        mutating=False,
        risk_tier=1,
        timeout_sec=60,
        allowed_hosts=None,
        params=(),
    ),
    "health_check": ActionSpec(
        key="health_check",
        description="HTTP health probe when host defines health_url, else uptime.",
        mutating=False,
        risk_tier=1,
        timeout_sec=60,
        allowed_hosts=None,
        params=(),
    ),
    "git_status": ActionSpec(
        key="git_status",
        description="git status and latest commit in the host repo_dir.",
        mutating=False,
        risk_tier=1,
        timeout_sec=60,
        allowed_hosts=None,
        params=(),
    ),
    "repo_tree": ActionSpec(
        key="repo_tree",
        description=(
            "List tracked files in the host repo (git ls-files), optional subdir; read-only."
        ),
        mutating=False,
        risk_tier=1,
        timeout_sec=60,
        allowed_hosts=None,
        params=("subdir", "limit", "repo_dir"),
    ),
    "repo_read_file": ActionSpec(
        key="repo_read_file",
        description=(
            "Print a line range of one tracked file in the host repo (sed -n); read-only."
        ),
        mutating=False,
        risk_tier=1,
        timeout_sec=60,
        allowed_hosts=None,
        params=("relative_path", "start", "lines", "repo_dir"),
    ),
    "repo_grep": ActionSpec(
        key="repo_grep",
        description=(
            "git grep -n a fixed pattern in the host repo, optional subdir; read-only."
        ),
        mutating=False,
        risk_tier=1,
        timeout_sec=60,
        allowed_hosts=None,
        params=("pattern", "subdir", "limit", "repo_dir"),
    ),
    "git_pull": ActionSpec(
        key="git_pull",
        description="git pull --ff-only origin main in repo_dir (or params.repo_dir override).",
        mutating=True,
        risk_tier=2,
        timeout_sec=180,
        allowed_hosts=None,
        params=("repo_dir",),
    ),
    "docker_restart": ActionSpec(
        key="docker_restart",
        description="Restart one Docker container (params: container). inference/RPC containers blocked.",
        mutating=True,
        risk_tier=2,
        timeout_sec=180,
        allowed_hosts=None,
        params=("container",),
    ),
    "brain_redeploy_api": ActionSpec(
        key="brain_redeploy_api",
        description="Pull main then rebuild/recreate alfa-ai-api on brain hub (scripts/brain_redeploy_api.sh).",
        mutating=True,
        risk_tier=3,
        timeout_sec=900,
        allowed_hosts=frozenset({"111"}),
        params=(),
    ),
    "cluster_start": ActionSpec(
        key="cluster_start",
        description="Full cluster start via Start-Stop-AlfaAi.ps1 on orchestrator (orchestrator only).",
        mutating=True,
        risk_tier=3,
        timeout_sec=1800,
        allowed_hosts=frozenset({"93"}),
        params=(),
    ),
    "cluster_stop": ActionSpec(
        key="cluster_stop",
        description="Full cluster stop via Start-Stop-AlfaAi.ps1 on orchestrator (orchestrator only).",
        mutating=True,
        risk_tier=3,
        timeout_sec=1800,
        allowed_hosts=frozenset({"93"}),
        params=(),
    ),
    "run_command": ActionSpec(
        key="run_command",
        description=(
            "Run an arbitrary shell (Linux/bash) or PowerShell (Windows) command on the host. "
            "Freeform -- the exact command text is shown in the proposal summary for operator "
            "review before Approve. inference/RPC piecemeal commands are still blocked."
        ),
        mutating=True,
        risk_tier=3,
        timeout_sec=300,
        allowed_hosts=None,
        params=("command",),
    ),
    "prom_targets": ActionSpec(
        key="prom_targets",
        description="List Prometheus scrape targets on monitor (GET /api/v1/targets).",
        mutating=False,
        risk_tier=1,
        timeout_sec=60,
        allowed_hosts=frozenset({"107"}),
        params=(),
    ),
    "prom_alerts": ActionSpec(
        key="prom_alerts",
        description="List Prometheus alerts on monitor (GET /api/v1/alerts).",
        mutating=False,
        risk_tier=1,
        timeout_sec=60,
        allowed_hosts=frozenset({"107"}),
        params=(),
    ),
    "prom_query": ActionSpec(
        key="prom_query",
        description="Run a PromQL instant query on monitor (params: query). GET /api/v1/query.",
        mutating=False,
        risk_tier=1,
        timeout_sec=90,
        allowed_hosts=frozenset({"107"}),
        params=("query",),
    ),
    "prometheus_reload": ActionSpec(
        key="prometheus_reload",
        description=(
            "Reload Prometheus config/rules on monitor (POST /-/reload; requires "
            "--web.enable-lifecycle)."
        ),
        mutating=True,
        risk_tier=2,
        timeout_sec=60,
        allowed_hosts=frozenset({"107"}),
        params=(),
    ),
    "refresh_prometheus_bearer": ActionSpec(
        key="refresh_prometheus_bearer",
        description=(
            "Refresh alfa-ai incident-metrics scrape bearer on monitor "
            "(scripts/refresh-alfa-ai-prometheus-bearer.sh; no Prometheus restart)."
        ),
        mutating=True,
        risk_tier=2,
        timeout_sec=120,
        allowed_hosts=frozenset({"107"}),
        params=(),
    ),
    "git_commit": ActionSpec(
        key="git_commit",
        description=(
            "git add + commit in repo_dir (params: message, optional paths). "
            "Owning clones only; no amend/force."
        ),
        mutating=True,
        risk_tier=3,
        timeout_sec=120,
        allowed_hosts=_GIT_OWNING_HOSTS,
        params=("message", "paths"),
    ),
    "git_push": ActionSpec(
        key="git_push",
        description="git push origin main in repo_dir (owning clones only; no force).",
        mutating=True,
        risk_tier=3,
        timeout_sec=180,
        allowed_hosts=_GIT_OWNING_HOSTS,
        params=("repo_dir",),
    ),
    "ci_repro_rankings_lint": ActionSpec(
        key="ci_repro_rankings_lint",
        description=(
            "Reproduce Rankings-Bot lint on probilliards (flake8 critical select; "
            "matches .github/workflows/lint.yml)."
        ),
        mutating=True,
        risk_tier=2,
        timeout_sec=600,
        allowed_hosts=frozenset({"106"}),
        params=(),
    ),
    "ci_repro_contracts_tests": ActionSpec(
        key="ci_repro_contracts_tests",
        description=(
            "Reproduce contracts-bot unit tests on apps (pytest subset; "
            "matches .github/workflows/tests.yml)."
        ),
        mutating=True,
        risk_tier=2,
        timeout_sec=900,
        allowed_hosts=frozenset({"105"}),
        params=(),
    ),
    "ci_repro_market_tests": ActionSpec(
        key="ci_repro_market_tests",
        description=(
            "Reproduce market-pie5-bot tests on market (pytest; "
            "matches .github/workflows/tests.yml)."
        ),
        mutating=True,
        risk_tier=2,
        timeout_sec=900,
        allowed_hosts=frozenset({"102"}),
        params=(),
    ),
    "apply_patch": ActionSpec(
        key="apply_patch",
        description=(
            "Write one file under repo_dir (params: relative_path, content). "
            "Max 80 lines; blocks .env, secrets, and workflow files."
        ),
        mutating=True,
        risk_tier=3,
        timeout_sec=120,
        allowed_hosts=frozenset({"102", "105", "106"}),
        params=("relative_path", "content"),
    ),
    "mission_enqueue": ActionSpec(
        key="mission_enqueue",
        description=(
            "Enqueue a read-only orchestrator mission (params: goal, target_host, "
            "optional skill default audit-repo). Runs inside brain API -- no SSH. "
            "research_only must be true (L1)."
        ),
        mutating=True,
        risk_tier=2,
        timeout_sec=60,
        allowed_hosts=frozenset({"111"}),
        params=("goal", "target_host", "skill", "research_only"),
    ),
    "mission_feeder_pause": ActionSpec(
        key="mission_feeder_pause",
        description=(
            "Pause audit_mission_feeder.sh by creating FEEDER_PAUSE in hub audit log dir (hub)."
        ),
        mutating=True,
        risk_tier=2,
        timeout_sec=60,
        allowed_hosts=frozenset({"111"}),
        params=(),
    ),
    "mission_feeder_resume": ActionSpec(
        key="mission_feeder_resume",
        description=(
            "Resume audit_mission_feeder.sh by removing FEEDER_PAUSE from hub audit log dir (hub)."
        ),
        mutating=True,
        risk_tier=2,
        timeout_sec=60,
        allowed_hosts=frozenset({"111"}),
        params=(),
    ),
    "mission_clear_stuck": ActionSpec(
        key="mission_clear_stuck",
        description=(
            "Mark wedged pending/running orchestrator missions failed so the feeder "
            "can enqueue again (params optional: min_age_sec, dry_run). Brain API only."
        ),
        mutating=True,
        risk_tier=2,
        timeout_sec=60,
        allowed_hosts=frozenset({"111"}),
        params=("min_age_sec", "dry_run"),
    ),
    "brain_verify": ActionSpec(
        key="brain_verify",
        description="Run scripts/brain_verify.sh in repo_dir (hub brain stack HTTP health).",
        mutating=False,
        risk_tier=1,
        timeout_sec=180,
        allowed_hosts=frozenset({"111"}),
        params=(),
    ),
    "hub_diag_read": ActionSpec(
        key="hub_diag_read",
        description=(
            "Read-only inference snapshot via scripts/diagnose-inference-ai.sh on inference "
            "(allowed diagnose; not a shard restart)."
        ),
        mutating=False,
        risk_tier=1,
        timeout_sec=180,
        allowed_hosts=frozenset({"148"}),
        params=(),
    ),
    "ps_syntax_check": ActionSpec(
        key="ps_syntax_check",
        description=(
            "ASCII + PS 5.1 parse check for deploy/ via "
            "Test-AlfaPowerShellScriptSyntax.ps1 -Recurse deploy."
        ),
        mutating=False,
        risk_tier=1,
        timeout_sec=300,
        allowed_hosts=frozenset({"93", "105"}),
        params=(),
    ),
    "draft_judge_guide": ActionSpec(
        key="draft_judge_guide",
        description=(
            "Run scripts/eval/run_7b_27b_guide.py (7B draft + 27B judge loop; "
            "params: task). Script-verify; does not enable ALFA_AI_JUDGE_ENABLED."
        ),
        mutating=False,
        risk_tier=1,
        timeout_sec=900,
        allowed_hosts=frozenset({"93", "111"}),
        params=("task",),
    ),
    "ha_get_states": ActionSpec(
        key="ha_get_states",
        description=(
            "Read dump-load sensor entities and allowlisted switches from Home Assistant REST (apps)."
        ),
        mutating=False,
        risk_tier=1,
        timeout_sec=30,
        allowed_hosts=frozenset({"105"}),
        params=(),
    ),
    "ha_get_state": ActionSpec(
        key="ha_get_state",
        description="Read one Home Assistant entity state (params: entity_id).",
        mutating=False,
        risk_tier=1,
        timeout_sec=30,
        allowed_hosts=frozenset({"105"}),
        params=("entity_id",),
    ),
    "ha_get_forecasts": ActionSpec(
        key="ha_get_forecasts",
        description=(
            "Read Home Assistant weather.get_forecasts for a weather.* entity "
            "(params: entity_id, type=daily|hourly|twice_daily). Observe only; no dump toggle."
        ),
        mutating=False,
        risk_tier=1,
        timeout_sec=30,
        allowed_hosts=frozenset({"105"}),
        params=("entity_id", "type"),
    ),
    "ha_switch_on": ActionSpec(
        key="ha_switch_on",
        description=(
            "Call HA switch.turn_on for an allowlisted entity (params: entity_id)."
        ),
        mutating=True,
        risk_tier=2,
        timeout_sec=30,
        allowed_hosts=frozenset({"105"}),
        params=("entity_id",),
    ),
    "ha_switch_off": ActionSpec(
        key="ha_switch_off",
        description=(
            "Call HA switch.turn_off for an allowlisted entity (params: entity_id)."
        ),
        mutating=True,
        risk_tier=2,
        timeout_sec=30,
        allowed_hosts=frozenset({"105"}),
        params=("entity_id",),
    ),
    "ha_dump_tick": ActionSpec(
        key="ha_dump_tick",
        description=(
            "Observe one deterministic solar dump tick (solar_dump.py; no switch services; "
            "HA automations own on/off). No LLM / 7B / 27B."
        ),
        mutating=False,
        risk_tier=1,
        timeout_sec=60,
        allowed_hosts=frozenset({"105"}),
        params=(),
    ),
    "web_search": ActionSpec(
        key="web_search",
        description=(
            "LAN SearXNG JSON search on brain hub (params: query). Internal HTTP only -- "
            "no SSH. Kill switch: ALFA_AI_WEB_SEARCH_ENABLED=0 fail-closed."
        ),
        mutating=False,
        risk_tier=1,
        timeout_sec=30,
        allowed_hosts=frozenset({"111"}),
        params=("query",),
    ),
    "ha_set_number": ActionSpec(
        key="ha_set_number",
        description=(
            "Call HA input_number.set_value for an allowlisted dump helper "
            "(params: entity_id, value). Runs immediately when HA env + token; "
            "not dump switch on/off."
        ),
        mutating=True,
        risk_tier=2,
        timeout_sec=30,
        allowed_hosts=frozenset({"105"}),
        params=("entity_id", "value"),
    ),
    "ha_select_option": ActionSpec(
        key="ha_select_option",
        description=(
            "Call HA input_select.select_option for an allowlisted dump plug inverter "
            "(params: entity_id, option=T2|KU|Sungold). Runs immediately when HA env + token; "
            "not dump switch on/off."
        ),
        mutating=True,
        risk_tier=2,
        timeout_sec=30,
        allowed_hosts=frozenset({"105"}),
        params=("entity_id", "option"),
    ),
}

# Deprecated catalog keys accepted until operator scripts migrate (FastAPI route aliases N/A).
_CATALOG_ACTION_ALIASES: dict[str, str] = {"ha_soak_tick": "ha_dump_tick"}

INSPECT_NEVER: frozenset[str] = frozenset(
    {"brain_verify", "hub_diag_read", "ps_syntax_check", "draft_judge_guide"}
)

MISSION_ACTION_KEYS = frozenset(
    {
        "mission_enqueue",
        "mission_feeder_pause",
        "mission_feeder_resume",
        "mission_clear_stuck",
    }
)

# Hub audit log dir on brain hub (SSH target path, not in-container mount).
_BRAIN_AUDIT_LOG_DIR = "/mnt/hub/alfa-ai/agent-audit-logs"
_FEEDER_PAUSE_FILE = "FEEDER_PAUSE"
_MISSION_SKILLS = frozenset({"", "audit-repo", "host-facts", "error-cataloger"})
_HA_HOST = "105"
_HA_SWITCH_ACTIONS = frozenset({"ha_switch_on", "ha_switch_off"})
_HA_HELPER_NUMBER_ACTIONS = frozenset({"ha_set_number"})
_HA_HELPER_SELECT_ACTIONS = frozenset({"ha_select_option"})
_HA_INSPECT_ACTIONS = frozenset(
    {"ha_get_states", "ha_get_state", "ha_get_forecasts", "ha_dump_tick"}
)
_HA_AUTO_ACTUATE_ACTIONS = frozenset(
    {
        "ha_switch_on",
        "ha_switch_off",
        "ha_dump_tick",
        "ha_set_number",
        "ha_select_option",
    }
)


def _validate_draft_judge_task(task: str) -> str:
    cleaned = task.strip()
    if not cleaned:
        raise ValueError("draft_judge_guide requires a non-empty params.task")
    if len(cleaned) > _DRAFT_JUDGE_TASK_MAX_LEN:
        raise ValueError(
            f"draft_judge_guide task exceeds {_DRAFT_JUDGE_TASK_MAX_LEN} characters"
        )
    if "\n" in cleaned or "\r" in cleaned:
        raise ValueError("draft_judge_guide task must be a single line")
    if _DRAFT_JUDGE_TASK_SECRET.search(cleaned):
        raise ValueError("draft_judge_guide task must not contain secrets or credentials")
    return cleaned


def _shell_single_quote(value: str) -> str:
    return value.replace("'", "'\\''")


def _ps_single_quote(value: str) -> str:
    return value.replace("'", "''")


def _resolve_ha_settings(settings: Any | None) -> Any | None:
    """Live ai_settings store/dict for HA validation; None falls back to dump defaults."""
    if settings is not None:
        return settings
    db_url = (os.getenv("DATABASE_URL") or "").strip()
    if not db_url:
        return None
    try:
        from src.api.models.ai_setting import AiSettingStore

        return AiSettingStore(db_url)
    except Exception:
        logger.debug("host_catalog: AiSettingStore unavailable for HA validate", exc_info=True)
        return None


def _validate_ha_proposal(
    action_key: str,
    host_key: str,
    normalized: dict[str, Any],
    settings: Any | None = None,
) -> None:
    if host_key != _HA_HOST:
        raise ValueError(f"Action {action_key} is only allowed on host {_HA_HOST}")
    from src.ops.home_assistant_client import validate_entity_id
    from src.ops.solar_dump import (
        DUMP_HA_NUMBER_HELPERS,
        DUMP_HA_SELECT_HELPERS,
        DUMP_HA_SELECT_OPTIONS,
        load_ha_never_auto,
        load_ha_switch_allowlist,
    )

    ha_settings = _resolve_ha_settings(settings)

    if action_key == "ha_get_state":
        entity_id = validate_entity_id(str(normalized.get("entity_id") or ""))
        normalized["entity_id"] = entity_id
        return
    if action_key == "ha_get_forecasts":
        from src.ops.home_assistant_client import (
            DEFAULT_WEATHER_ENTITY,
            validate_forecast_type,
            validate_weather_entity_id,
        )

        entity_id = validate_weather_entity_id(
            str(normalized.get("entity_id") or DEFAULT_WEATHER_ENTITY)
        )
        forecast_type = validate_forecast_type(str(normalized.get("type") or "daily"))
        normalized["entity_id"] = entity_id
        normalized["type"] = forecast_type
        return
    if action_key in _HA_SWITCH_ACTIONS:
        entity_id = validate_entity_id(str(normalized.get("entity_id") or ""))
        allowlist = load_ha_switch_allowlist(ha_settings)
        if not allowlist:
            raise ValueError("ha_switch_allowlist is empty -- all switch actions rejected")
        if entity_id not in allowlist:
            raise ValueError(f"entity_id {entity_id!r} not in ha_switch_allowlist")
        if entity_id in load_ha_never_auto(ha_settings):
            raise ValueError(f"entity_id {entity_id!r} is in ha_never_auto")
        normalized["entity_id"] = entity_id
        return
    if action_key in _HA_HELPER_NUMBER_ACTIONS:
        entity_id = validate_entity_id(str(normalized.get("entity_id") or ""))
        if entity_id not in DUMP_HA_NUMBER_HELPERS:
            raise ValueError(f"entity_id {entity_id!r} is not an allowlisted dump number helper")
        raw_value = normalized.get("value")
        try:
            value = float(raw_value)
        except (TypeError, ValueError) as exc:
            raise ValueError("ha_set_number requires numeric params.value") from exc
        if value < 0 or value > 4000:
            raise ValueError("ha_set_number value must be 0-4000")
        normalized["entity_id"] = entity_id
        normalized["value"] = value
        return
    if action_key in _HA_HELPER_SELECT_ACTIONS:
        entity_id = validate_entity_id(str(normalized.get("entity_id") or ""))
        if entity_id not in DUMP_HA_SELECT_HELPERS:
            raise ValueError(f"entity_id {entity_id!r} is not an allowlisted dump inverter select")
        option = str(normalized.get("option") or "").strip()
        if option not in DUMP_HA_SELECT_OPTIONS:
            raise ValueError("ha_select_option option must be T2, KU, or Sungold")
        normalized["entity_id"] = entity_id
        normalized["option"] = option
        return


def is_inspectable(action_key: str) -> bool:
    """Read-only tier-1 catalog actions that Ask ALFa may auto-run inside a turn (L1 observe)."""
    spec = _CATALOG.get(action_key)
    return (
        bool(spec)
        and not spec.mutating
        and spec.risk_tier == 1
        and action_key not in INSPECT_NEVER
    )


def is_ha_inspect_action(action_key: str) -> bool:
    """HA catalog reads that use the HA token (not SSH), including observe dump tick."""
    resolved = _CATALOG_ACTION_ALIASES.get(action_key, action_key)
    return resolved in _HA_INSPECT_ACTIONS


def is_web_search_inspect_action(action_key: str) -> bool:
    """SearXNG catalog read that uses internal HTTP (not SSH)."""
    return action_key == "web_search"


def is_ha_auto_actuate(action_key: str) -> bool:
    """HA catalog actions that execute immediately when HA env + token are on.

    `ha_switch_on` / `ha_switch_off` POST switch services. `ha_set_number` /
    `ha_select_option` POST dump helper services. `ha_dump_tick` observes only
    (Home Assistant automations own dump on/off). Solar dump is outside NIST.
    """
    resolved = _CATALOG_ACTION_ALIASES.get(action_key, action_key)
    return resolved in _HA_AUTO_ACTUATE_ACTIONS


def inspectable_action_keys() -> tuple[str, ...]:
    return tuple(sorted(k for k in _CATALOG if is_inspectable(k)))


def action_category(action_key: str) -> str:
    """UI grouping: mission catalog actions vs SSH host actions."""
    return "mission" if action_key in MISSION_ACTION_KEYS else "host"


def host_actions_enabled() -> bool:
    raw = (os.getenv("ALFA_AI_HOST_ACTIONS_ENABLED") or "0").strip().lower()
    return raw in ("1", "true", "yes", "on")


def _config_disabled_actions(config: dict[str, Any] | None) -> set[str]:
    if not config:
        return set()
    raw = config.get("disabled_actions") or []
    if not isinstance(raw, list):
        return set()
    return {str(k).strip() for k in raw if str(k).strip()}


def _config_host_overrides(config: dict[str, Any] | None) -> list[dict[str, Any]]:
    if not config:
        return []
    raw = config.get("host_overrides")
    if not isinstance(raw, list):
        return []
    return [h for h in raw if isinstance(h, dict)]


def _base_load_hosts() -> dict[str, dict[str, Any]]:
    """Build host map from env / code defaults only (no DB overrides)."""
    override = (os.getenv("ALFA_AI_HOST_ACTIONS_HOSTS_JSON") or "").strip()
    rows: list[dict[str, Any]]
    if override:
        try:
            parsed = json.loads(override)
            rows = [h for h in parsed if isinstance(h, dict)] if isinstance(parsed, list) else list(_DEFAULT_HOSTS)
        except json.JSONDecodeError:
            rows = list(_DEFAULT_HOSTS)
    else:
        rows = list(_DEFAULT_HOSTS)
    out: dict[str, dict[str, Any]] = {}
    key_path = default_ssh_key_path()
    for row in rows:
        key = str(row.get("key") or "").strip()
        if not key:
            continue
        cfg = dict(row)
        cfg.setdefault("key_path", key_path)
        out[key] = cfg
    return out


def load_hosts(config: dict[str, Any] | None = None) -> dict[str, dict[str, Any]]:
    """Return host key -> config dict, merged with optional agent config overrides."""
    out = _base_load_hosts()
    key_path = default_ssh_key_path()
    for override in _config_host_overrides(config):
        key = str(override.get("key") or "").strip()
        if not key:
            continue
        if override.get("enabled") is False:
            out.pop(key, None)
            continue
        base = dict(out.get(key, {}))
        merged = {**base, **override}
        merged.pop("enabled", None)
        merged.setdefault("key_path", key_path)
        merged["key"] = key
        out[key] = merged
    return out


def list_merged_hosts(config: dict[str, Any] | None = None) -> list[dict[str, Any]]:
    """Hosts visible to the AI with source hint (default vs override)."""
    base = _base_load_hosts()
    override_keys = {
        str(h.get("key") or "").strip()
        for h in _config_host_overrides(config)
        if str(h.get("key") or "").strip()
    }
    disabled_keys = {
        str(h.get("key") or "").strip()
        for h in _config_host_overrides(config)
        if h.get("enabled") is False and str(h.get("key") or "").strip()
    }
    merged = load_hosts(config)
    rows: list[dict[str, Any]] = []
    for key in sorted(set(base.keys()) | override_keys):
        if key in disabled_keys or key not in merged:
            continue
        host = merged[key]
        rows.append(
            {
                "key": key,
                "name": host.get("name"),
                "lan_ip": host.get("lan_ip"),
                "ssh_user": host.get("ssh_user"),
                "os_type": host.get("os_type"),
                "repo_dir": host.get("repo_dir"),
                "health_url": host.get("health_url"),
                "enabled": True,
                "source": "override" if key in override_keys else "default",
            }
        )
    return rows


def list_editable_hosts(config: dict[str, Any] | None = None) -> list[dict[str, Any]]:
    """All hosts for the admin editor (defaults + overrides, including disabled)."""
    base = _base_load_hosts()
    overrides_by_key: dict[str, dict[str, Any]] = {}
    for entry in _config_host_overrides(config):
        key = str(entry.get("key") or "").strip()
        if key:
            overrides_by_key[key] = entry

    keys = sorted(set(base.keys()) | set(overrides_by_key.keys()))
    rows: list[dict[str, Any]] = []
    for key in keys:
        override = overrides_by_key.get(key, {})
        base_host = base.get(key, {})
        merged = {**base_host, **override}
        enabled = override.get("enabled") is not False
        if key not in base and key not in overrides_by_key:
            continue
        if key in overrides_by_key and override.get("enabled") is False:
            enabled = False
        rows.append(
            {
                "key": key,
                "name": merged.get("name") or "",
                "lan_ip": merged.get("lan_ip") or "",
                "ssh_user": merged.get("ssh_user") or "",
                "os_type": merged.get("os_type") or "linux",
                "repo_dir": merged.get("repo_dir") or "",
                "health_url": merged.get("health_url") or "",
                "enabled": enabled,
                "source": "override" if key in overrides_by_key else "default",
            }
        )
    return rows


def get_action_risk_tier(action_key: str) -> int:
    spec = _CATALOG.get(action_key)
    return spec.risk_tier if spec else 3


def list_all_catalog_entries() -> list[dict[str, Any]]:
    """Full catalog (ignores disabled_actions) for admin toggles."""
    hosts = _base_load_hosts()
    out: list[dict[str, Any]] = []
    for spec in _CATALOG.values():
        if spec.allowed_hosts is None:
            allowed = sorted(hosts.keys())
        else:
            allowed = sorted(spec.allowed_hosts & set(hosts.keys()))
        out.append(
            {
                "key": spec.key,
                "description": spec.description,
                "mutating": spec.mutating,
                "risk_tier": spec.risk_tier,
                "timeout_sec": spec.timeout_sec,
                "allowed_hosts": allowed,
                "params": list(spec.params),
            }
        )
    return sorted(out, key=lambda x: x["key"])


def default_ssh_key_path() -> str:
    return (os.getenv("ALFA_AI_HOST_ACTIONS_SSH_KEY") or "/app/secrets/host-actions/id_ed25519").strip()


def get_host(host_key: str, config: dict[str, Any] | None = None) -> dict[str, Any] | None:
    return load_hosts(config).get(host_key)


def list_all_catalog_keys() -> list[str]:
    return sorted(_CATALOG.keys())


def list_catalog(config: dict[str, Any] | None = None) -> list[dict[str, Any]]:
    """Enabled-only catalog (legacy). Prefer list_all_catalog_entries + soft flags for LLM."""
    disabled = _config_disabled_actions(config)
    hosts = load_hosts(config)
    out: list[dict[str, Any]] = []
    for spec in _CATALOG.values():
        if spec.key in disabled:
            continue
        if spec.allowed_hosts is None:
            allowed = sorted(hosts.keys())
        else:
            allowed = sorted(spec.allowed_hosts & set(hosts.keys()))
        out.append(
            {
                "key": spec.key,
                "description": spec.description,
                "mutating": spec.mutating,
                "risk_tier": spec.risk_tier,
                "timeout_sec": spec.timeout_sec,
                "allowed_hosts": allowed,
                "params": list(spec.params),
            }
        )
    return sorted(out, key=lambda x: x["key"])


def get_catalog_for_llm(config: dict[str, Any] | None = None) -> list[dict[str, Any]]:
    """Full catalog for Ask ALFa, including soft-disabled actions (Approve enables them)."""
    from src.ops.action_packs import pack_for_action

    disabled = _config_disabled_actions(config)
    hosts = load_hosts(config)
    out: list[dict[str, Any]] = []
    for spec in _CATALOG.values():
        if spec.allowed_hosts is None:
            allowed = sorted(hosts.keys())
        else:
            allowed = sorted(spec.allowed_hosts & set(hosts.keys()))
        pack = pack_for_action(spec.key)
        out.append(
            {
                "key": spec.key,
                "description": spec.description,
                "mutating": spec.mutating,
                "risk_tier": spec.risk_tier,
                "allowed_hosts": allowed,
                "params": list(spec.params),
                "soft_disabled": spec.key in disabled,
                "pack": pack.id if pack else None,
                "inspectable": is_inspectable(spec.key),
            }
        )
    return sorted(out, key=lambda x: x["key"])


def validate_proposal(
    action_key: str,
    host_key: str,
    params: dict[str, Any] | None,
    config: dict[str, Any] | None = None,
    *,
    settings: Any | None = None,
    enforce_enabled: bool = True,
) -> tuple[ActionSpec, dict[str, Any], dict[str, Any]]:
    """Validate action_key/host/params. Returns (spec, host_config, normalized_params).

    When enforce_enabled=False, soft-disabled actions may still be proposed; Approve enables them.
    """
    action_key = _CATALOG_ACTION_ALIASES.get(action_key, action_key)
    if enforce_enabled and action_key in _config_disabled_actions(config):
        raise ValueError(f"Action {action_key} is disabled by operator config")
    spec = _CATALOG.get(action_key)
    if spec is None:
        raise ValueError(f"Unknown action_key: {action_key}")
    host_cfg = get_host(host_key, config)
    if host_cfg is None:
        raise ValueError(f"Unknown host: {host_key}")
    if spec.allowed_hosts is not None and host_key not in spec.allowed_hosts:
        raise ValueError(f"Action {action_key} is not allowed on host {host_key}")
    normalized = dict(params or {})
    if action_key == "run_command":
        command = str(normalized.get("command") or "").strip()
        if not command:
            raise ValueError("run_command requires a non-empty params.command")
        _reject_inference_piecemeal(command)
    if action_key == "prom_query":
        query = str(normalized.get("query") or "").strip()
        if not query or len(query) > 500 or not _PROMQL_SAFE.match(query):
            raise ValueError("prom_query requires a safe non-empty params.query (PromQL)")
        normalized["query"] = query
    if action_key == "git_commit":
        message = str(normalized.get("message") or "").strip()
        if not message or not _GIT_MSG_SAFE.match(message):
            raise ValueError("git_commit requires a safe params.message (1-200 chars)")
        normalized["message"] = message
        paths_raw = str(normalized.get("paths") or "").strip()
        path_list: list[str] = []
        if paths_raw:
            for part in paths_raw.split():
                token = part.strip()
                if (
                    not token
                    or ".." in token
                    or token.startswith("/")
                    or token.startswith("\\")
                    or not _GIT_PATH_SAFE.match(token)
                ):
                    raise ValueError(f"Invalid git_commit path: {token!r}")
                path_list.append(token)
        normalized["paths"] = " ".join(path_list)
    if action_key == "apply_patch":
        rel = str(normalized.get("relative_path") or "").strip()
        content = str(normalized.get("content") or "")
        if not rel or ".." in rel or rel.startswith("/") or rel.startswith("\\"):
            raise ValueError("apply_patch requires safe params.relative_path")
        if not _GIT_PATH_SAFE.match(rel):
            raise ValueError("apply_patch relative_path has invalid characters")
        if _APPLY_PATCH_BLOCKED.search(rel):
            raise ValueError("apply_patch path is blocked (secrets/workflows/.env)")
        if not content or len(content) > _APPLY_PATCH_MAX_CHARS:
            raise ValueError(
                f"apply_patch content must be 1-{_APPLY_PATCH_MAX_CHARS} chars"
            )
        line_count = content.count("\n") + 1
        if line_count > _APPLY_PATCH_MAX_LINES:
            raise ValueError(f"apply_patch content exceeds {_APPLY_PATCH_MAX_LINES} lines")
        normalized["relative_path"] = rel
        normalized["content"] = content
    if action_key == "mission_enqueue":
        goal = str(normalized.get("goal") or "").strip()
        if not goal:
            raise ValueError("mission_enqueue requires a non-empty params.goal")
        if len(goal) > 500:
            raise ValueError("mission_enqueue goal exceeds 500 characters")
        from src.ops.mission_fleet import validate_mission_target_host

        target_host = validate_mission_target_host(
            str(normalized.get("target_host") or "111")
        )
        skill = str(normalized.get("skill") or "audit-repo").strip() or "audit-repo"
        if skill not in _MISSION_SKILLS:
            raise ValueError(f"mission_enqueue unsupported skill: {skill}")
        research_only = normalized.get("research_only", True)
        if isinstance(research_only, str):
            research_only = research_only.lower() in ("1", "true", "yes")
        if research_only not in (True, False, 1, 0):
            research_only = True
        if not research_only:
            raise ValueError("mission_enqueue requires research_only=true (L1 read-only)")
        normalized["goal"] = goal
        normalized["target_host"] = target_host
        normalized["skill"] = skill
        normalized["research_only"] = True
    if action_key in _REPO_ACTION_KEYS:
        if str(host_cfg.get("os_type") or "linux") == "windows":
            raise ValueError("repo_* actions are not supported on Windows hosts")
        override = str(normalized.get("repo_dir") or "").strip()
        if override:
            if not _REPO_DIR_PATTERN.match(override):
                raise ValueError("Invalid repo_dir override")
            if override not in _REPO_DIR_ALLOWLIST:
                raise ValueError(f"repo_dir override not in allowlist: {override}")
            normalized["repo_dir"] = override
        else:
            repo = str(host_cfg.get("repo_dir") or "").strip()
            if not repo or not _REPO_DIR_PATTERN.match(repo):
                raise ValueError("Invalid or missing repo_dir")
            normalized["repo_dir"] = repo
        if action_key == "repo_tree":
            subdir = str(normalized.get("subdir") or "").strip()
            if subdir:
                _validate_repo_subpath(subdir, "subdir")
                normalized["subdir"] = subdir
            else:
                normalized.pop("subdir", None)
            limit = int(normalized.get("limit") or 200)
            if limit < 1 or limit > 500:
                raise ValueError("repo_tree limit must be 1-500")
            normalized["limit"] = limit
        elif action_key == "repo_read_file":
            rel = str(normalized.get("relative_path") or "").strip()
            if not rel or ".." in rel or rel.startswith("/") or rel.startswith("\\"):
                raise ValueError("repo_read_file requires safe params.relative_path")
            if not _GIT_PATH_SAFE.match(rel):
                raise ValueError("repo_read_file relative_path has invalid characters")
            if _APPLY_PATCH_BLOCKED.search(rel) or _REPO_READ_BLOCKED.search(rel):
                raise ValueError("repo_read_file path is blocked (secrets/keys/workflows/.env)")
            normalized["relative_path"] = rel
            start = int(normalized.get("start") or 1)
            if start < 1:
                raise ValueError("repo_read_file start must be >= 1")
            normalized["start"] = start
            lines = int(normalized.get("lines") or 200)
            if lines < 1 or lines > 400:
                raise ValueError("repo_read_file lines must be 1-400")
            normalized["lines"] = lines
        elif action_key == "repo_grep":
            pattern = str(normalized.get("pattern") or "").strip()
            if not pattern or len(pattern) > 120:
                raise ValueError("repo_grep requires a pattern of 1-120 chars")
            if not _GREP_PATTERN_SAFE.match(pattern) or any(
                token in pattern for token in _GREP_PATTERN_FORBIDDEN_SUBSTRINGS
            ):
                raise ValueError("repo_grep pattern contains unsafe characters")
            normalized["pattern"] = pattern
            subdir = str(normalized.get("subdir") or "").strip()
            if subdir:
                _validate_repo_subpath(subdir, "subdir")
                normalized["subdir"] = subdir
            else:
                normalized.pop("subdir", None)
            limit = int(normalized.get("limit") or 100)
            if limit < 1 or limit > 300:
                raise ValueError("repo_grep limit must be 1-300")
            normalized["limit"] = limit
    if action_key == "web_search":
        query = str(normalized.get("query") or "").strip()
        if not query:
            raise ValueError("web_search requires a non-empty params.query")
        if len(query) > 500:
            raise ValueError("web_search query exceeds 500 characters")
        normalized["query"] = query
    if action_key.startswith("ha_"):
        _validate_ha_proposal(action_key, host_key, normalized, settings)
    if action_key == "draft_judge_guide":
        normalized["task"] = _validate_draft_judge_task(str(normalized.get("task") or ""))
    return spec, host_cfg, normalized


def _reject_inference_piecemeal(text: str) -> None:
    """Freeform commands and container names must not touch inference/RPC containers directly
    (no-piecemeal-cluster-scripts.mdc). Only cluster_start/cluster_stop on orchestrator may do so."""
    if _inference_CONTAINER_BLOCKLIST.search(text):
        raise ValueError(
            "Command/container matches inference/RPC blocklist -- use cluster_start/cluster_stop "
            "on orchestrator instead (no piecemeal shard/coordinator commands)"
        )


def is_inference_piecemeal_blocked(text: str) -> bool:
    """True when text matches the inference/RPC blocklist regex."""
    return bool(_inference_CONTAINER_BLOCKLIST.search(text))


def _validate_container(name: str) -> str:
    container = (name or "").strip()
    if not container or not _CONTAINER_NAME_PATTERN.match(container):
        raise ValueError("Invalid container name")
    _reject_inference_piecemeal(container)
    return container


def _validate_repo_subpath(token: str, field_name: str) -> None:
    if ".." in token or token.startswith("/") or token.startswith("\\"):
        raise ValueError(f"Invalid {field_name}: path traversal or absolute path")
    if not _GIT_PATH_SAFE.match(token):
        raise ValueError(f"Invalid {field_name}: unsafe characters")


def _repo_dir(host_cfg: dict[str, Any], params: dict[str, Any]) -> str:
    repo = str(params.get("repo_dir") or host_cfg.get("repo_dir") or "").strip()
    if not repo or not _REPO_DIR_PATTERN.match(repo):
        raise ValueError("Invalid or missing repo_dir")
    return repo


def _docker_prefix(os_type: str) -> str:
    if os_type == "windows":
        return "wsl -d Ubuntu docker"
    return "docker"


def build_command(
    action_key: str,
    host_cfg: dict[str, Any],
    params: dict[str, Any],
    config: dict[str, Any] | None = None,
) -> tuple[str, int]:
    """Return (shell command string, timeout_sec)."""
    spec, _, normalized = validate_proposal(action_key, str(host_cfg["key"]), params, config)
    if action_key.startswith("ha_"):
        raise ValueError(f"{action_key} is internal Home Assistant httpx (no SSH command)")
    os_type = str(host_cfg.get("os_type") or "linux")
    repo_dir = _repo_dir(host_cfg, normalized)
    docker = _docker_prefix(os_type)

    if action_key == "docker_ps":
        if os_type == "windows":
            cmd = f'{docker} ps --format "table {{{{.Names}}}}\\t{{{{.Status}}}}\\t{{{{.Ports}}}}"'
        else:
            cmd = 'docker ps --format "table {{.Names}}\\t{{.Status}}\\t{{.Ports}}"'
        return cmd, spec.timeout_sec

    if action_key == "docker_stats":
        fmt = "table {{.Name}}\\t{{.CPUPerc}}\\t{{.MemUsage}}"
        if os_type == "windows":
            cmd = f'{docker} stats --no-stream --format "{fmt}"'
        else:
            cmd = f'docker stats --no-stream --format "{fmt}"'
        return cmd, spec.timeout_sec

    if action_key == "docker_logs":
        container = _validate_container(str(normalized.get("container") or ""))
        tail = int(normalized.get("tail") or 100)
        tail = max(10, min(tail, 500))
        return f"{docker} logs --tail {tail} {container} 2>&1", spec.timeout_sec

    if action_key == "disk_usage":
        if os_type == "windows":
            return "Get-PSDrive C | Select-Object Name,Used,Free", spec.timeout_sec
        return "df -h /", spec.timeout_sec

    if action_key == "health_check":
        health_url = str(host_cfg.get("health_url") or "").strip()
        if health_url:
            if os_type == "windows":
                return f'curl.exe -fsS --max-time 10 "{health_url}"', spec.timeout_sec
            return f'curl -fsS --max-time 10 "{health_url}"', spec.timeout_sec
        if os_type == "windows":
            return "$env:COMPUTERNAME; Get-Date -Format o", spec.timeout_sec
        return "uptime", spec.timeout_sec

    if action_key == "git_status":
        if os_type == "windows":
            rd = repo_dir.replace("'", "''")
            return (
                f"Set-Location -LiteralPath '{rd}'; "
                "git status -sb; git log -1 --oneline"
            ), spec.timeout_sec
        return f"cd '{repo_dir}' && git status -sb && git log -1 --oneline", spec.timeout_sec

    if action_key == "git_pull":
        if os_type == "windows":
            rd = repo_dir.replace("'", "''")
            return (
                f"Set-Location -LiteralPath '{rd}'; "
                "git pull --ff-only origin main"
            ), spec.timeout_sec
        return f"cd '{repo_dir}' && git pull --ff-only origin main", spec.timeout_sec

    if action_key == "docker_restart":
        container = _validate_container(str(normalized.get("container") or ""))
        return f"{docker} restart {container}", spec.timeout_sec

    if action_key == "brain_redeploy_api":
        return "bash scripts/brain_redeploy_api.sh", spec.timeout_sec

    if action_key == "cluster_start":
        rd = repo_dir.replace("\\", "\\\\")
        return (
            f'powershell -NoProfile -ExecutionPolicy Bypass -File "{rd}\\deploy\\cluster-members\\operator-93\\Start-Stop-AlfaAi.ps1" start'
        ), spec.timeout_sec

    if action_key == "cluster_stop":
        rd = repo_dir.replace("\\", "\\\\")
        return (
            f'powershell -NoProfile -ExecutionPolicy Bypass -File "{rd}\\deploy\\cluster-members\\operator-93\\Start-Stop-AlfaAi.ps1" stop'
        ), spec.timeout_sec

    if action_key == "run_command":
        command = str(normalized.get("command") or "").strip()
        if not command:
            raise ValueError("run_command requires a non-empty params.command")
        _reject_inference_piecemeal(command)
        return command, spec.timeout_sec

    if action_key == "prom_targets":
        return (
            "curl -fsS --max-time 20 'http://127.0.0.1:9092/api/v1/targets' "
            "| python3 -c \"import sys,json; d=json.load(sys.stdin); "
            "ts=d.get('data',{}).get('activeTargets',[]); "
            "print('targets',len(ts)); "
            "[print(t.get('health'), (t.get('labels') or {}).get('job'), "
            "(t.get('labels') or {}).get('instance'), (t.get('lastError') or '')[:120]) "
            "for t in ts]\""
        ), spec.timeout_sec

    if action_key == "prom_alerts":
        return (
            "curl -fsS --max-time 20 'http://127.0.0.1:9092/api/v1/alerts' "
            "| python3 -c \"import sys,json; from collections import Counter; "
            "d=json.load(sys.stdin); alerts=d.get('data',{}).get('alerts',[]); "
            "c=Counter((a.get('labels',{}).get('alertname'), a.get('state')) for a in alerts); "
            "print('alert_count', len(alerts)); "
            "[print(k,v) for k,v in c.most_common(40)]\""
        ), spec.timeout_sec

    if action_key == "prom_query":
        import shlex

        query = str(normalized.get("query") or "").strip()
        return (
            "curl -fsS --max-time 30 --get 'http://127.0.0.1:9092/api/v1/query' "
            f"--data-urlencode {shlex.quote('query=' + query)}"
        ), spec.timeout_sec

    if action_key == "prometheus_reload":
        # Official management API: https://prometheus.io/docs/prometheus/latest/management_api/#reload
        return "curl -fsS -X POST --max-time 15 'http://127.0.0.1:9092/-/reload'", spec.timeout_sec

    if action_key == "refresh_prometheus_bearer":
        return (
            "bash /home/operator/monitoring/scripts/refresh-alfa-ai-prometheus-bearer.sh"
        ), spec.timeout_sec

    if action_key == "git_commit":
        message = str(normalized.get("message") or "").replace("'", "'\"'\"'")
        paths = str(normalized.get("paths") or "").strip()
        add_cmd = f"git add -- {paths}" if paths else "git add -A"
        if os_type == "windows":
            rd = repo_dir.replace("'", "''")
            msg = str(normalized.get("message") or "").replace("'", "''")
            path_ps = paths.replace("'", "''")
            add_ps = f"git add -- {path_ps}" if path_ps else "git add -A"
            return (
                f"Set-Location -LiteralPath '{rd}'; {add_ps}; "
                f"git commit -m '{msg}'"
            ), spec.timeout_sec
        return (
            f"cd '{repo_dir}' && {add_cmd} && git commit -m '{message}'"
        ), spec.timeout_sec

    if action_key == "git_push":
        if os_type == "windows":
            rd = repo_dir.replace("'", "''")
            return (
                f"Set-Location -LiteralPath '{rd}'; git push origin main"
            ), spec.timeout_sec
        return f"cd '{repo_dir}' && git push origin main", spec.timeout_sec

    if action_key in (
        "ci_repro_rankings_lint",
        "ci_repro_contracts_tests",
        "ci_repro_market_tests",
    ):
        from src.ops.ci_triage import catalog_action_command

        cmd = catalog_action_command(action_key)
        if not cmd:
            raise ValueError(f"No command template for {action_key}")
        return cmd, spec.timeout_sec

    if action_key == "apply_patch":
        import base64

        rel = str(normalized.get("relative_path") or "").strip()
        content = str(normalized.get("content") or "")
        b64 = base64.b64encode(content.encode("utf-8")).decode("ascii")
        return (
            f"cd '{repo_dir}' && python3 -c "
            f"\"import base64, pathlib; "
            f"p=pathlib.Path({rel!r}); p.parent.mkdir(parents=True, exist_ok=True); "
            f"p.write_bytes(base64.b64decode({b64!r}))\""
        ), spec.timeout_sec

    if action_key == "mission_feeder_pause":
        pause_path = f"{_BRAIN_AUDIT_LOG_DIR}/{_FEEDER_PAUSE_FILE}"
        return f"mkdir -p '{_BRAIN_AUDIT_LOG_DIR}' && touch '{pause_path}'", spec.timeout_sec

    if action_key == "mission_feeder_resume":
        pause_path = f"{_BRAIN_AUDIT_LOG_DIR}/{_FEEDER_PAUSE_FILE}"
        return f"rm -f '{pause_path}'", spec.timeout_sec

    if action_key == "mission_enqueue":
        raise ValueError("mission_enqueue is internal to brain API (no SSH command)")

    if action_key == "web_search":
        raise ValueError("web_search is internal to brain API (no SSH command)")

    if action_key == "mission_clear_stuck":
        raise ValueError("mission_clear_stuck is internal to brain API (no SSH command)")

    if action_key == "brain_verify":
        return f"cd '{repo_dir}' && bash scripts/brain_verify.sh", spec.timeout_sec

    if action_key == "hub_diag_read":
        return f"cd '{repo_dir}' && bash scripts/diagnose-inference-ai.sh", spec.timeout_sec

    if action_key == "ps_syntax_check":
        if os_type == "windows":
            rd = repo_dir.replace("'", "''")
            return (
                f"Set-Location -LiteralPath '{rd}'; "
                f"& '.\\deploy\\cluster-members\\_common\\Test-AlfaPowerShellScriptSyntax.ps1' "
                f"-Recurse '{rd}\\deploy'"
            ), spec.timeout_sec
        return (
            f"cd '{repo_dir}' && pwsh -NoProfile -File "
            f"deploy/cluster-members/_common/Test-AlfaPowerShellScriptSyntax.ps1 -Recurse deploy"
        ), spec.timeout_sec

    if action_key == "draft_judge_guide":
        task = str(normalized.get("task") or "")
        if os_type == "windows":
            rd = repo_dir.replace("'", "''")
            task_ps = _ps_single_quote(task)
            return (
                f"Set-Location -LiteralPath '{rd}'; "
                f"python scripts\\eval\\run_7b_27b_guide.py --task '{task_ps}'"
            ), spec.timeout_sec
        task_sh = _shell_single_quote(task)
        return (
            f"cd '{repo_dir}' && python3 scripts/eval/run_7b_27b_guide.py "
            f"--task '{task_sh}'"
        ), spec.timeout_sec

    if action_key == "repo_tree":
        limit = int(normalized.get("limit") or 200)
        subdir = str(normalized.get("subdir") or "").strip()
        if subdir:
            return (
                f"git -C '{repo_dir}' ls-files -- '{subdir}' | head -n {limit}"
            ), spec.timeout_sec
        return f"git -C '{repo_dir}' ls-files | head -n {limit}", spec.timeout_sec

    if action_key == "repo_read_file":
        rel = str(normalized.get("relative_path") or "")
        start = int(normalized.get("start") or 1)
        lines = int(normalized.get("lines") or 200)
        end = start + lines - 1
        # git-bounded: only a path git tracks in repo_dir can be read
        # (--error-unmatch exits non-zero otherwise; https://git-scm.com/docs/git-ls-files).
        # sed line range per POSIX: https://pubs.opengroup.org/onlinepubs/9699919799/utilities/sed.html
        return (
            f"git -C '{repo_dir}' ls-files --error-unmatch -- '{rel}' >/dev/null "
            f"&& sed -n '{start},{end}p' -- '{repo_dir}/{rel}'"
        ), spec.timeout_sec

    if action_key == "repo_grep":
        pattern = str(normalized.get("pattern") or "")
        limit = int(normalized.get("limit") or 100)
        subdir = str(normalized.get("subdir") or "").strip()
        if subdir:
            return (
                f"git -C '{repo_dir}' grep -n -I -e '{pattern}' -- '{subdir}' | head -n {limit}"
            ), spec.timeout_sec
        return (
            f"git -C '{repo_dir}' grep -n -I -e '{pattern}' | head -n {limit}"
        ), spec.timeout_sec

    raise ValueError(f"Unhandled action_key: {action_key}")


def summarize_proposal(
    action_key: str,
    host_key: str,
    params: dict[str, Any] | None,
    config: dict[str, Any] | None = None,
) -> str:
    spec, host_cfg, normalized = validate_proposal(
        action_key, host_key, params, config, enforce_enabled=False
    )
    if action_key == "mission_enqueue":
        goal = str(normalized.get("goal") or "")[:120]
        target = normalized.get("target_host") or "?"
        skill = normalized.get("skill") or "audit-repo"
        return (
            f"Enqueue read-only mission skill={skill} target_host={target} "
            f"on brain hub: {goal}"
        )
    if action_key == "mission_clear_stuck":
        age = normalized.get("min_age_sec") or "(default ALFA_AI_MISSION_STUCK_SEC)"
        dry = normalized.get("dry_run")
        dry_s = f" dry_run={dry}" if dry not in (None, "", False, "false", "0") else ""
        return (
            f"Clear wedged stuck missions on brain hub "
            f"(fail pending/running older than {age}s){dry_s} [mutating]"
        )
    if action_key == "mission_feeder_pause":
        return (
            f"Pause audit mission feeder (create {_FEEDER_PAUSE_FILE} under "
            f"{_BRAIN_AUDIT_LOG_DIR}) on host {host_key} [mutating]"
        )
    if action_key == "mission_feeder_resume":
        return (
            f"Resume audit mission feeder (remove {_FEEDER_PAUSE_FILE} from "
            f"{_BRAIN_AUDIT_LOG_DIR}) on host {host_key} [mutating]"
        )
    if action_key == "web_search":
        query = str(normalized.get("query") or "")[:120]
        return f"LAN SearXNG web_search on brain hub: {query} [read-only]"
    if action_key == "ha_get_states":
        return "Read Home Assistant dump-load sensors and allowlist states on host 105 [read-only]"
    if action_key == "ha_get_state":
        eid = normalized.get("entity_id") or "?"
        return f"Read Home Assistant state for {eid} on host 105 [read-only]"
    if action_key == "ha_get_forecasts":
        eid = normalized.get("entity_id") or "?"
        ftype = normalized.get("type") or "daily"
        return (
            f"Read Home Assistant weather.get_forecasts {ftype} for {eid} "
            "on host 105 [read-only; no dump toggle]"
        )
    if action_key == "ha_switch_on":
        eid = normalized.get("entity_id") or "?"
        return f"Home Assistant turn_on {eid} on host 105 [mutating]"
    if action_key == "ha_switch_off":
        eid = normalized.get("entity_id") or "?"
        return f"Home Assistant turn_off {eid} on host 105 [mutating]"
    if action_key == "ha_set_number":
        eid = normalized.get("entity_id") or "?"
        value = normalized.get("value")
        return (
            f"Home Assistant input_number.set_value {eid}={value} on host 105 "
            "[mutating; Approve; not dump switch on/off]"
        )
    if action_key == "ha_select_option":
        eid = normalized.get("entity_id") or "?"
        option = normalized.get("option") or "?"
        return (
            f"Home Assistant input_select.select_option {eid}={option} on host 105 "
            "[mutating; Approve; not dump switch on/off]"
        )
    if spec.key == "ha_dump_tick":
        return (
            "Observe one deterministic solar dump tick on host 105 "
            "(solar_dump.py; no switch services; HA automations own on/off). "
            "No LLM / 7B / 27B. [read-only]"
        )
    if action_key == "draft_judge_guide":
        task = str(normalized.get("task") or "")
        return (
            f"Run 7B/27B draft-judge guide loop on host {host_key} "
            f"with task: {task} [read-only script verify]"
        )
    if action_key in _REPO_ACTION_KEYS:
        repo = normalized.get("repo_dir") or host_cfg.get("repo_dir") or "?"
        extras: list[str] = []
        if action_key == "repo_tree":
            if normalized.get("subdir"):
                extras.append(f"subdir={normalized['subdir']}")
            extras.append(f"limit={normalized.get('limit', 200)}")
        elif action_key == "repo_read_file":
            extras.append(f"path={normalized.get('relative_path')}")
            extras.append(f"start={normalized.get('start', 1)}")
            extras.append(f"lines={normalized.get('lines', 200)}")
        elif action_key == "repo_grep":
            extras.append(f"pattern={normalized.get('pattern')}")
            if normalized.get("subdir"):
                extras.append(f"subdir={normalized['subdir']}")
            extras.append(f"limit={normalized.get('limit', 100)}")
        detail = ", ".join(extras)
        return f"Read-only {action_key} on host {host_key} ({repo}, {detail})"
    mut = "mutating" if spec.mutating else "read-only"
    extra = ""
    if normalized:
        extra = f" ({', '.join(f'{k}={v}' for k, v in normalized.items())})"
    return f"{action_key} on host {host_key}{extra} [{mut}]"
