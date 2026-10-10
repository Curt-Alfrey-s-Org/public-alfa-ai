"""Deterministic fast path for Ask ALFa: structured ops without LLM.

See docs/AI_ACTIONS.md (Hybrid path). Returns None when the message should use frontier-code.
"""

from __future__ import annotations

import logging
import re
from typing import Any

from src.api.models.ai_action import ACTION_SETTING_PROPOSAL, AiActionStore
from src.api.models.ai_setting import (
    AiSettingError,
    AiSettingStore,
    BOOL_SETTING_KEYS,
    POLICY_SETTING_REQUIRES_APPROVE_REASON,
    is_policy_setting,
    setting_description,
    validate_setting_value,
)
from src.api.ask_alfa_context import is_dump_observe_action
from src.api.models.host_action import HostActionStore, STATUS_PENDING
from src.ops.host_catalog import (
    action_category,
    get_action_risk_tier,
    host_actions_enabled,
    is_ha_auto_actuate,
    is_inference_piecemeal_blocked,
    list_all_catalog_keys,
    load_hosts,
    summarize_proposal,
    validate_proposal,
)

logger = logging.getLogger(__name__)

_inference_MUTATING_WORDS = re.compile(
    r"\b(restart|stop|start|probe|recreate|kill)\b",
    re.IGNORECASE,
)

_PROPOSE_RUN_COMMAND_RE = re.compile(
    r"\bpropose\s+run_command\s+on\s+host\s+(\d+)\s+(?:to\s+run:\s*|:\s*)(.+)",
    re.IGNORECASE | re.DOTALL,
)

_PROPOSE_CATALOG_RE = re.compile(
    r"\bpropose\s+([a-z_]+)\s+on\s+host\s+(\d+)\b",
    re.IGNORECASE,
)

_SETTING_SET_RE = re.compile(
    r"^\s*set\s+([a-z_]+)\s+to\s+(\S*[^\s.])\s*\.?\s*$",
    re.IGNORECASE,
)

_TURN_BOOL_RE = re.compile(
    r"^\s*turn\s+(on|off)\s+([a-z_]+)\s*\.?\s*$",
    re.IGNORECASE,
)

_BARE_CLEAR_SETTING_TOKEN = '""'


def _parse_bare_setting_value(raw: str) -> str:
    if raw == _BARE_CLEAR_SETTING_TOKEN:
        return ""
    return raw

_USER_COUNT_RE = re.compile(
    r"\bhow many registered users\b",
    re.IGNORECASE,
)

_SCOPE_QUESTION_RE = re.compile(
    r"what data do you have access to.*what data do you explicitly not have",
    re.IGNORECASE | re.DOTALL,
)

_GITHUB_CI_QUESTION_RE = re.compile(
    r"\bwhat(?:'s| is) failing in ci\b",
    re.IGNORECASE,
)

_FLEET_STATUS_RE = re.compile(r"\bfleet\s+status\b", re.IGNORECASE)

_CLUSTER_STATUS_RE = re.compile(
    r"(?:"
    r"\bcluster\s+status\b"
    r"|what(?:'s| is)\s+wrong\s+with\s+the\s+cluster\b"
    r"|is\s+(?:the\s+)?(?:cluster|brain|inference|inference)\s+(?:ok|healthy|up|down)\b"
    r"|why\s+is\s+(?:inference|the\s+brain|inference)\s+(?:down|degraded)\b"
    r"|firing\s+alerts\b"
    r"|health\s+of\s+(?:the\s+)?(?:cluster|brain)\b"
    r"|is\s+everything\s+(?:ok|healthy|up)\b"
    r"|is\s+(?:the\s+)?(?:solar\s+)?dump\s+(?:on|working|running|ok)\b"
    r")",
    re.IGNORECASE,
)

_ACTIVITY_SUMMARY_FIRST_LINE_PREFIX = "ALFa AI activity ("
_CLUSTER_STATUS_FIRST_LINE_PREFIX = "ALFa AI cluster status ("
_FACT_CHECK_FIRST_LINE_PREFIX = "ALFa AI fact check ("
_FLEET_STATUS_PREFIX = "Mission fleet status (read-only):"
_GITHUB_CI_PREFIX = "GitHub CI summary (read-only"


def _as_copyable_code_block(text: str, *, fence: bool = True) -> str:
    """Wrap plain text so ChatMessage fenced-pre gets a Copy control."""
    body = text.rstrip("\n")
    if not fence:
        return body
    return "```text\n" + body + "\n```"

_FOLLOWUP_SHOW_RE = re.compile(
    r"(?:"
    r"show\s+me\s+all\s+that\b"
    r"|yes,?\s+show\s+me\s+(?:all\s+)?that\b"
    r"|tell\s+me\s+more\s+about\s+that\b"
    r")",
    re.IGNORECASE,
)

_FOLLOWUP_VERIFY_RE = re.compile(
    r"(?:"
    r"audit\s+(?:your|that|the|this)\s+answer\b"
    r"|is\s+(?:that|this|it)\s+(?:correct|true|accurate|right)\b"
    r"|was\s+(?:that|this|it)\s+(?:correct|true|accurate|right)\b"
    r"|are\s+you\s+sure\b"
    r"|verify\s+(?:that|this|your\s+answer|the\s+last)\b"
    r"|fact[\s-]?check\b"
    r"|did\s+you\s+(?:make\s+that\s+up|hallucinate|invent)\b"
    r"|check\s+your\s+(?:answer|work|facts)\b"
    r")",
    re.IGNORECASE,
)

_LONE_YES_RE = re.compile(r"^\s*yes\s*\.?\s*$", re.IGNORECASE)
_LONE_APPROVE_RE = re.compile(r"^\s*approve\s*\.?\s*$", re.IGNORECASE)

_MISSION_WEDGE_RE = re.compile(
    r"(?:"
    r"\bare\s+missions?\s+wedged\b"
    r"|\bmission(?:s)?\s+(?:wedge|health|queue)\b"
    r"|\bis\s+the\s+(?:mission\s+)?(?:queue|feeder)\s+(?:stuck|wedged|blocked)\b"
    r")",
    re.IGNORECASE,
)

_CLEAR_STUCK_MISSIONS_RE = re.compile(
    r"\bclear\s+stuck\s+missions?\b",
    re.IGNORECASE,
)

_REVIEW_ERRORS_RE = re.compile(
    r"(?:"
    r"\b(?:review|list|catalog(?:ue)?|show|find)\s+(?:recent\s+)?errors\b"
    r"|\berrors?\s+(?:in|from)\s+(?:alfa-ai|the cluster|admin)\b"
    r"|\blist\s+(?:them|the errors)\b"
    r")",
    re.IGNORECASE,
)

# Activity / jobs / last-N-hours -- answer from gathered context, not frontier-code.
_ACTIVITY_SUMMARY_RE = re.compile(
    r"(?:"
    r"what\s+has\s+alfa-?ai\s+been\s+doing"
    r"|analy[sz]e\s+what\s+alfa-?ai\s+has\s+been\s+doing"
    r"|what\s+has\s+it\s+worked\s+on"
    r"|what\s+(?:have\s+you|has\s+the\s+(?:brain|agent))\s+been\s+doing"
    r"|what\s+activit(?:y|ies)\s+has\s+alfa-?ai\s+doing"
    r"|recent\s+(?:alfa-?ai\s+)?activity"
    r"|show\s+me\s+all\s+that\s+activity"
    r"|last\s+(\d{1,2})\s*(?:hrs?|hours?)\s+(?:of\s+)?(?:activity|work)"
    r"|what\s+(?:jobs?|missions?|runs?|requests?)\s+(?:were\s+)?completed"
    r"|what\s+(?:jobs?|missions?|runs?|requests?)\s+(?:has|have|did)\s+"
    r"(?:alfa-?ai|the\s+(?:brain|agent)|it)\s+"
    r"|what\s+has\s+alfa-?ai\s+(?:completed|done|finished|handled)"
    r"|(?:jobs?|missions?|requests?)\s+(?:has\s+)?alfa-?ai\s+completed"
    r"|what\s+(?:did|has)\s+alfa-?ai\s+(?:do|done|complete)"
    r"|(?:jobs?|missions?)\s+completed\s+overnight"
    r"|overnight\s+(?:jobs?|missions?|activity)"
    r")",
    re.IGNORECASE,
)

_OVERNIGHT_RE = re.compile(r"\bovernight\b", re.IGNORECASE)

_ACTIVITY_HOURS_RE = re.compile(
    r"\b(?:last|past)\s+(\d{1,2})\s*(?:hrs?|hours?)\b",
    re.IGNORECASE,
)

_ACTIVITY_REPLY_HOURS_RE = re.compile(
    r"last\s+~(\d{1,2})h",
    re.IGNORECASE,
)

_AUDIT_HOST_RE = re.compile(
    r"\baudit\s+(?:host\s+)?(\d{2,3})\b",
    re.IGNORECASE,
)

_ANALYZE_REPO_RE = re.compile(
    r"\b(?:analyze|analyse|inspect|review|look\s+at|check)\s+(?:the\s+)?"
    r"([a-z0-9]+(?:[-\s][a-z0-9]+)*)\s+(?:repo|repository|bot|app)\b",
    re.IGNORECASE,
)

_ANALYZE_VERB_RE = re.compile(
    r"\b(?:analyze|analyse|inspect|review|look\s+at|check)\s+(?:the\s+)?(.+)",
    re.IGNORECASE,
)

# Owning hosts + repo_dir from docs/REPO_HOST_MAPPING.md (consumer clones).
_REPO_OWNING_HOSTS: dict[str, tuple[str, str]] = {
    "rankings-bot": ("106", "/home/operator/rankings-bot"),
    "rankings": ("106", "/home/operator/rankings-bot"),
    "probilliards": ("106", "/home/operator/rankings-bot"),
    "uspbf": ("106", "/home/operator/USPBF"),
    "contracts-bot": ("105", "/home/operator/contracts-bot"),
    "contracts": ("105", "/home/operator/contracts-bot"),
    "market-pie5-bot": ("102", "/home/operator/market-pie5-bot"),
    "market-pie5": ("102", "/home/operator/market-pie5-bot"),
    "market": ("102", "/home/operator/market-pie5-bot"),
    "atems": ("103", "/home/operator/atems"),
    "monitoring": ("107", "/home/operator/monitoring"),
    "alfa-ai": ("111", "/mnt/hub/alfa-ai/repo/alfa-ai"),
}

_FAKE_APPROVE_CLAIM_RE = re.compile(
    r"(?i)\b(click approve|approve the mission|approve the (?:pending )?action|"
    r"proposing now|i(?:'m| am) proposing)\b"
)

_HOST_FACTS_RE = re.compile(
    r"\b(?:run\s+)?host-?facts\s+(?:on\s+host\s+)?(\d{2,3})\b",
    re.IGNORECASE,
)

_AUDIT_ALL_HOSTS_RE = re.compile(
    r"\baudit\s+all\s+(?:worker\s+)?hosts?\b",
    re.IGNORECASE,
)

# Explicit internet lookup only. Do not use bare "weather for" -- that steals HA
# / solar weather radar questions (ha_get_forecasts on host 105).
_WEB_RESEARCH_RE = re.compile(
    r"(?:"
    r"\bresearch\s+online\b"
    r"|\bsearch\s+(?:the\s+)?(?:web|internet)\b"
    r"|\blook\s+up\s+online\b"
    r"|\bcheck\s+weather\s+for\s+\d{5}\b"
    r"|\bweb_search\b"
    r")",
    re.IGNORECASE,
)

_HA_WEATHER_RE = re.compile(
    r"(?:"
    r"\bweather\b"
    r"|\bforecast\b"
    r"|\bweather\s+radar\b"
    r")",
    re.IGNORECASE,
)

_HA_WEATHER_SITE_RE = re.compile(
    r"(?:"
    r"\bhome\s+assistant\b"
    r"|\bha\b"
    r"|\bhost\s+105\b"
    r"|\apps\b"
    r"|\bsolar\b"
    r"|\bweather\s+radar\b"
    r")",
    re.IGNORECASE,
)

_HOURLY_FORECAST_RE = re.compile(r"\b(?:hours?|hrs?|hourly)\b", re.IGNORECASE)

_HOT_HOST_RE = re.compile(
    r"(?:"
    r"why\s+is\s+host\s+(\d{2,3})\s+hot"
    r"|investigate\s+(?:cpu|load|thermal)\s+on\s+(?:host\s+)?(\d{2,3})"
    r"|host\s+(\d{2,3})\s+(?:temperature|temp|thermal|cpu\s+load)"
    r"|runaway\s+container\s+on\s+(?:host\s+)?(\d{2,3})"
    r"|(?:cpu|thermal|temperature)\s+(?:on\s+)?host\s+(\d{2,3})"
    r")",
    re.IGNORECASE,
)

_PAUSE_FEEDER_RE = re.compile(
    r"\bpause\s+(?:audit\s+)?(?:mission\s+)?feeder\b",
    re.IGNORECASE,
)

_RESUME_FEEDER_RE = re.compile(
    r"\bresume\s+(?:audit\s+)?(?:mission\s+)?feeder\b",
    re.IGNORECASE,
)

_STRUCTURED_KEY_RE = re.compile(
    r"\b([a-z_]+)\s*=",
    re.IGNORECASE,
)

_DRAFT_JUDGE_PREFIX_RE = re.compile(r"^\s*draft-judge:\s*", re.IGNORECASE)

_SCOPE_REPLY = (
    "I have read access to alfa-ai admin console context: cluster health, incidents, AI settings "
    "and actions, models summary, user count, audit log, pending host actions, and the host action "
    "catalog. I can propose one host action per turn (you Approve before it runs) and change one "
    "AI setting when you ask.\n\n"
    "I do NOT have access to consumer bot business databases: ProBilliards/rankings player data, "
    "market-pie5 trades, contracts opportunities, credit-check, atems, rv-auto-finder, etc. "
    "If you need that data, use that bot's own admin console."
)

_inference_BLOCK_REPLY = (
    "That request is blocked by policy. Individual inference/RPC shard or coordinator "
    "restart/stop/probe commands are not allowed. Use cluster_stop then cluster_start on host 93 "
    "(Start-Stop-AlfaAi.ps1 orchestrator) instead."
)

_VALID_SETTING_KEYS = frozenset(
    {
        "ai_triage_enabled",
        "ai_can_adjust_settings",
        "notify_email",
        "notify_min_severity",
        "notify_quiet_hours",
        "notify_dedup_minutes",
        "chat_thinking_label",
        "auto_fix_allowlist",
    }
)

_READABLE_CONTEXT_KEYS = frozenset(
    {
        "notify_min_severity",
        "notify_dedup_minutes",
        "notify_quiet_hours",
        "notify_email",
        "ai_triage_enabled",
        "ai_can_adjust_settings",
        "chat_thinking_label",
        "host_actions_enabled",
    }
)


def _result(
    reply: str,
    *,
    applied_setting: dict[str, Any] | None = None,
    pending_setting_proposal: dict[str, Any] | None = None,
    host_action_proposal: dict[str, Any] | None = None,
    cursor_handoff: str | None = None,
    ci_triage: dict[str, Any] | None = None,
    draft_guide: dict[str, Any] | None = None,
) -> dict[str, Any]:
    out: dict[str, Any] = {
        "ok": True,
        "reply": reply,
        "applied_setting": applied_setting,
        "pending_setting_proposal": pending_setting_proposal,
        "host_action_proposal": host_action_proposal,
    }
    if cursor_handoff:
        out["cursor_handoff"] = cursor_handoff
    if ci_triage:
        out["ci_triage"] = ci_triage
    if draft_guide:
        out["draft_guide"] = draft_guide
    return out


def parse_draft_judge_task(message: str) -> str | None:
    """Return task text after ``draft-judge:`` prefix, or None if not prefixed."""
    text = message or ""
    match = _DRAFT_JUDGE_PREFIX_RE.match(text)
    if not match:
        return None
    return text[match.end() :].strip()


def _guidance_from_judge_results(judge_results: list[Any]) -> str:
    if not judge_results:
        return ""
    last = judge_results[-1]
    guidance = getattr(last, "guidance", None) or ""
    if str(guidance).strip():
        return str(guidance).strip()
    parts: list[str] = []
    for issue in getattr(last, "issues", None) or []:
        parts.append(
            f"- [{getattr(issue, 'severity', '?')}] "
            f"{getattr(issue, 'claim', '')}: {getattr(issue, 'reason', '')}"
        )
    for miss in getattr(last, "missing_evidence", None) or []:
        parts.append(f"- missing evidence: {miss}")
    return "\n".join(parts)


def _format_draft_guide_reply(result: Any) -> dict[str, Any]:
    """Build Ask ALFa reply + structured draft_guide payload from loop result."""
    guidance = _guidance_from_judge_results(getattr(result, "judge_results", None) or [])
    payload: dict[str, Any] = {
        "verdict": getattr(result, "verdict", ""),
        "guidance": guidance,
        "log_path": getattr(result, "log_path", ""),
        "rounds": getattr(result, "rounds", 0),
        "skipped": bool(getattr(result, "skipped", False)),
        "skip_reason": getattr(result, "skip_reason", "") or "",
        "safe_to_auto_apply": False,
        "project_auto_applied": bool(getattr(result, "project_auto_applied", False)),
        "applied_path": getattr(result, "applied_path", "") or "",
        "autonomy_reason": getattr(result, "autonomy_reason", "") or "",
        "session_id": getattr(result, "session_id", "") or "",
    }
    if payload["skipped"]:
        reply = (
            "Path B draft-judge skipped (no project auto-write).\n"
            f"skip_reason: {payload['skip_reason'] or 'unknown'}\n"
            f"log_path: {payload['log_path']}\n"
            "safe_to_auto_apply: false"
        )
        return _result(reply, draft_guide=payload)

    lines = [
        "Path B draft-judge loop complete (L3 project sandbox when sim dump guardrail holds).",
        f"verdict: {payload['verdict']}",
        f"rounds: {payload['rounds']}",
        f"log_path: {payload['log_path']}",
        f"project_auto_applied: {str(payload['project_auto_applied']).lower()}",
        f"applied_path: {payload['applied_path'] or '(none)'}",
        f"autonomy_reason: {payload['autonomy_reason'] or '(none)'}",
        "safe_to_auto_apply: false",
    ]
    from src.llm.draft_guide import sanitize_secret_text

    if guidance:
        safe_guidance = sanitize_secret_text(guidance)
        payload["guidance"] = safe_guidance
        lines.extend(["", "--- Judge guidance (last round) ---", safe_guidance])
    final_draft = (getattr(result, "final_draft", None) or "").strip()
    if final_draft:
        lines.extend(["", "--- Final draft ---", sanitize_secret_text(final_draft)])
    return _result("\n".join(lines), draft_guide=payload)


def _try_draft_judge_path(
    message: str,
    *,
    settings_store: Any | None = None,
) -> dict[str, Any] | None:
    """Opt-in 7B draft + 27B judge loop (admin Ask ALFa only)."""
    task = parse_draft_judge_task(message)
    if task is None:
        return None
    if not task:
        return _result(
            "draft-judge: requires a task prompt after the colon.",
            draft_guide={
                "verdict": "",
                "guidance": "",
                "log_path": "",
                "rounds": 0,
                "skipped": True,
                "skip_reason": "empty task after draft-judge: prefix",
                "safe_to_auto_apply": False,
            },
        )
    try:
        from src.llm.draft_guide import run_draft_guide_loop

        loop_result = run_draft_guide_loop(task, settings=settings_store)
    except Exception as exc:  # noqa: BLE001 -- never crash Ask ALFa on loop failure
        logger.exception("draft-judge loop failed")
        return _result(
            f"Path B draft-judge failed: {str(exc)[:300]}",
            draft_guide={
                "verdict": "",
                "guidance": "",
                "log_path": "",
                "rounds": 0,
                "skipped": True,
                "skip_reason": str(exc)[:300],
                "safe_to_auto_apply": False,
            },
        )
    return _format_draft_guide_reply(loop_result)


def annotate_reply_if_no_proposal(
    reply: str,
    host_action_proposal: dict[str, Any] | None,
) -> str:
    """Stop the model from asking for Approve when nothing was queued."""
    text = reply or ""
    if host_action_proposal is not None:
        return text
    if not _FAKE_APPROVE_CLAIM_RE.search(text):
        return text
    return (
        text.rstrip()
        + "\n\nNo Approve button was created: that reply described a host action "
        "but did not queue one. Say exactly: Audit host 106"
    )


def _normalize_repo_alias(raw: str) -> str:
    return re.sub(r"\s+", "-", (raw or "").strip().lower())


def _extract_repo_analyze_alias(message: str) -> str | None:
    """Match analyze/inspect/check + named repo; not Audit host N or research online."""
    if _AUDIT_HOST_RE.search(message) or _AUDIT_ALL_HOSTS_RE.search(message):
        return None
    if _WEB_RESEARCH_RE.search(message):
        return None
    suffix_match = _ANALYZE_REPO_RE.search(message)
    if suffix_match:
        alias = _normalize_repo_alias(suffix_match.group(1))
        if alias in _REPO_OWNING_HOSTS:
            return alias
        return None
    verb_match = _ANALYZE_VERB_RE.search(message)
    if not verb_match:
        return None
    rest = verb_match.group(1).strip()
    if re.match(r"host\s+\d", rest, re.IGNORECASE):
        return None
    words = rest.split()
    for n in range(1, min(4, len(words) + 1)):
        candidate = _normalize_repo_alias(" ".join(words[:n]))
        if candidate in _REPO_OWNING_HOSTS:
            return candidate
    return None


def _try_analyze_named_repo(
    message: str,
    *,
    host_store: HostActionStore,
    config: dict[str, Any],
    proposed_by: str,
) -> dict[str, Any] | None:
    """Return llm_continue sentinel with pre_inspect steps for a named consumer/brain clone."""
    alias = _extract_repo_analyze_alias(message)
    if not alias:
        return None
    host, repo_dir = _REPO_OWNING_HOSTS[alias]
    if host not in load_hosts(config):
        return _result(f"Host {host} is not in the host action registry.")
    return {
        "llm_continue": True,
        "repo_target": {"alias": alias, "host": host, "repo_dir": repo_dir},
        "pre_inspect": [
            {"action_key": "repo_tree", "params": {"limit": 200}},
            {"action_key": "git_status"},
            {"action_key": "docker_ps"},
            {
                "action_key": "repo_read_file",
                "params": {"relative_path": "README.md", "start": 1, "lines": 200},
            },
            {
                "action_key": "repo_grep",
                "params": {"pattern": "scraper", "limit": 100},
            },
        ],
    }


def _setting_value_from_context(context: dict[str, Any], key: str) -> str:
    if key == "host_actions_enabled":
        return "true" if context.get("host_actions_enabled") else "false"
    for row in context.get("ai_settings") or []:
        if isinstance(row, dict) and row.get("key") == key:
            return str(row.get("value") or "")
    return ""


def _is_inference_piecemeal_request(message: str) -> bool:
    catalog_match = _PROPOSE_CATALOG_RE.search(message)
    if catalog_match:
        action_key = catalog_match.group(1).lower()
        if action_key in set(list_all_catalog_keys()) and action_key != "run_command":
            return False
    if not is_inference_piecemeal_blocked(message):
        return False
    lower = message.lower()
    if "run_command" in lower or "propose" in lower:
        return True
    if _inference_MUTATING_WORDS.search(message):
        return True
    return False


def _try_blocklist(message: str) -> dict[str, Any] | None:
    if _is_inference_piecemeal_request(message):
        return _result(_inference_BLOCK_REPLY)
    return None


def _try_scope_question(message: str) -> dict[str, Any] | None:
    if _SCOPE_QUESTION_RE.search(message):
        return _result(_SCOPE_REPLY)
    return None


def _try_github_ci_summary(message: str, context: dict[str, Any]) -> dict[str, Any] | None:
    if not _GITHUB_CI_QUESTION_RE.search(message):
        return None
    gh = context.get("github_ci")
    if not gh:
        return _result(
            "GitHub CI context is off. Enable the github_ci section in AI Config and set "
            "ALFA_AI_GITHUB_TOKEN on the brain, or paste a CI failure email/log here."
        )
    if gh.get("error") == "github_token_unauthorized":
        return _result("GitHub token is unauthorized. Update ALFA_AI_GITHUB_TOKEN on the brain.")
    repos = gh.get("repos") or []
    if not repos:
        return _result("No allowlisted repo CI data returned. Check token scope (actions:read).")
    lines: list[str] = ["GitHub CI summary (read-only, latest failures):"]
    for row in repos:
        name = row.get("repo") or "?"
        failure = row.get("latest_failure")
        if failure is None:
            lines.append(f"- {name}: no recent failed run")
            continue
        if row.get("error"):
            lines.append(f"- {name}: fetch error ({row.get('error')})")
            continue
        lines.append(
            f"- {name}: {failure.get('name')} on {failure.get('head_branch')} "
            f"({failure.get('created_at')})"
        )
        if failure.get("html_url"):
            lines.append(f"  {failure['html_url']}")
        excerpt = (failure.get("log_excerpt") or "").strip()
        if excerpt:
            lines.append(f"  excerpt: {excerpt[:500]}")
    lines.append(
        "\nPaste a full log here for deterministic triage + Approve reproduce, "
        "or ask Cursor after copying the handoff."
    )
    return _result("\n".join(lines))


def _try_user_count(message: str, context: dict[str, Any]) -> dict[str, Any] | None:
    if not _USER_COUNT_RE.search(message):
        return None
    count = context.get("user_count")
    if count is None:
        return _result("User count is not available in the current context.")
    return _result(f"There are currently {count} registered users in the ALFa AI system.")


def _try_structured_read(message: str, context: dict[str, Any]) -> dict[str, Any] | None:
    found: list[str] = []
    for match in _STRUCTURED_KEY_RE.finditer(message):
        key = match.group(1).lower()
        if key in _READABLE_CONTEXT_KEYS and key not in found:
            found.append(key)
    if len(found) < 2:
        return None
    lines: list[str] = []
    for i, key in enumerate(found, 1):
        val = _setting_value_from_context(context, key)
        lines.append(f"{i}) {key}={val}")
    return _result("\n".join(lines))


def _apply_setting_change(
    key: str,
    new_value: str,
    *,
    settings_store: AiSettingStore,
    actions_store: AiActionStore,
    operator_email: str,
    message: str,
) -> tuple[dict[str, Any] | None, dict[str, Any] | None, str | None]:
    """Returns (applied, pending_proposal, reply_or_error)."""
    if key not in _VALID_SETTING_KEYS:
        return None, None, f"Unknown setting key: {key}"
    try:
        new_value = validate_setting_value(key, new_value)
    except AiSettingError as exc:
        return None, None, str(exc)
    old_value = settings_store.get(key, "")
    if is_policy_setting(key):
        record = actions_store.record(
            ACTION_SETTING_PROPOSAL,
            f"Proposed {key}: {old_value or '(empty)'} -> {new_value or '(empty)'}",
            detail={
                "key": key,
                "old_value": old_value,
                "new_value": new_value,
                "status": "pending",
                "reason": "Policy setting requires operator Approve",
                "message": message[:500],
            },
            created_by=operator_email,
        )
        proposal = {
            "id": record.id,
            "key": key,
            "old_value": old_value,
            "new_value": new_value,
            "status": "pending",
            "description": setting_description(key),
            "requires_approve_reason": POLICY_SETTING_REQUIRES_APPROVE_REASON,
        }
        reply = (
            f"Policy setting {key} requires Approve before it takes effect. "
            f"Proposed: {old_value or '(empty)'} -> {new_value or '(empty)'}."
        )
        return None, proposal, reply
    try:
        settings_store.set(key, new_value, updated_by=operator_email, by_ai=False)
    except AiSettingError as exc:
        return None, None, str(exc)
    actions_store.record(
        "setting_changed",
        f"{operator_email} (via Ask ALFa) set {key}: {old_value or '(empty)'} -> {new_value or '(empty)'}",
        detail={
            "key": key,
            "old_value": old_value,
            "new_value": new_value,
            "reason": "Requested via Ask ALFa chat",
            "message": message[:500],
        },
        created_by=operator_email,
    )
    applied = {
        "key": key,
        "old_value": old_value,
        "new_value": new_value,
        "description": setting_description(key),
    }
    reply = f"Applied {key}: {old_value or '(empty)'} -> {new_value or '(empty)'}."
    return applied, None, reply


def _try_setting_write(
    message: str,
    *,
    settings_store: AiSettingStore,
    actions_store: AiActionStore,
    operator_email: str,
) -> dict[str, Any] | None:
    turn = _TURN_BOOL_RE.match(message.strip())
    if turn:
        on_off, key = turn.group(1).lower(), turn.group(2).lower()
        if key not in BOOL_SETTING_KEYS:
            return None
        new_value = "true" if on_off == "on" else "false"
        applied, pending, reply_or_err = _apply_setting_change(
            key,
            new_value,
            settings_store=settings_store,
            actions_store=actions_store,
            operator_email=operator_email,
            message=message,
        )
        if applied is None and pending is None:
            return _result(reply_or_err or "Setting change failed.")
        if pending is not None:
            return _result(reply_or_err or "", pending_setting_proposal=pending)
        return _result(reply_or_err or "", applied_setting=applied)

    setting = _SETTING_SET_RE.match(message.strip())
    if setting:
        key = setting.group(1).lower()
        new_value = _parse_bare_setting_value(setting.group(2))
        applied, pending, reply_or_err = _apply_setting_change(
            key,
            new_value,
            settings_store=settings_store,
            actions_store=actions_store,
            operator_email=operator_email,
            message=message,
        )
        if applied is None and pending is None:
            return _result(reply_or_err or "Setting change failed.")
        if pending is not None:
            return _result(reply_or_err or "", pending_setting_proposal=pending)
        return _result(reply_or_err or "", applied_setting=applied)

    return None


def _create_host_proposal(
    action_key: str,
    host: str,
    params: dict[str, Any],
    *,
    host_store: HostActionStore,
    config: dict[str, Any],
    proposed_by: str,
) -> tuple[dict[str, Any] | None, str]:
    if not host_actions_enabled():
        return (
            None,
            (
                "Host actions infra is off (ALFA_AI_HOST_ACTIONS_ENABLED=0). "
                "One-time: set it in brain deploy/.env, mount the SSH key, redeploy API. "
                "You do not need to toggle packs in AI Config -- Approve enables them."
            ),
        )
    try:
        summary = summarize_proposal(action_key, host, params, config)
        validate_proposal(action_key, host, params, config, enforce_enabled=False)
    except ValueError as exc:
        return None, str(exc)
    record = host_store.create_pending(
        action_key, host, params, summary, proposed_by=proposed_by
    )
    from src.ops.action_packs import proposal_enable_meta

    auth = proposal_enable_meta(
        action_key,
        config.get("disabled_actions") or [],
        risk_tier=get_action_risk_tier(action_key),
    )
    proposal = {
        "id": record.id,
        "summary": record.summary,
        "status": STATUS_PENDING,
        "action_key": action_key,
        "action_category": action_category(action_key),
        "host": host,
        **auth,
    }
    return proposal, summary


def _try_ha_auto_actuate_catalog(
    action_key: str,
    host: str,
    params: dict[str, Any],
    *,
    config: dict[str, Any],
) -> dict[str, Any]:
    """Queue HA dump-load mutate for immediate execution (no pending Approve row)."""
    from src.ops.home_assistant_client import home_assistant_ready

    if not home_assistant_ready():
        return _result(
            "Home Assistant integration is off or token file missing. "
            "Set ALFA_AI_HOME_ASSISTANT_* in deploy/.env and redeploy alfa-ai-api."
        )
    try:
        _, _, normalized = validate_proposal(
            action_key, host, params, config, enforce_enabled=False
        )
        summary = summarize_proposal(action_key, host, params, config)
    except ValueError as exc:
        return _result(str(exc))
    out = _result(f"Executing immediately (no Approve): {summary}")
    out["host_action_auto_actuate"] = {
        "action_key": action_key,
        "host": host,
        "params": normalized,
    }
    return out


def _try_propose_host_action(
    message: str,
    *,
    host_store: HostActionStore,
    config: dict[str, Any],
    proposed_by: str,
) -> dict[str, Any] | None:
    run_match = _PROPOSE_RUN_COMMAND_RE.search(message)
    if run_match:
        host, command = run_match.group(1), run_match.group(2).strip()
        params = {"command": command}
        proposal, summary_or_err = _create_host_proposal(
            "run_command",
            host,
            params,
            host_store=host_store,
            config=config,
            proposed_by=proposed_by,
        )
        if proposal is None:
            return _result(summary_or_err)
        auth = proposal.get("auth_level") or "Read"
        packs = proposal.get("will_enable_packs") or []
        pack_note = (
            f" Approve will enable: {', '.join(packs)}."
            if packs
            else ""
        )
        judge_note = ""
        try:
            from src.llm.judge import run_judge, should_run_judge

            if should_run_judge("run_command") or should_run_judge("freeform"):
                jr = run_judge(
                    subject=f"Freeform run_command on host {host}",
                    context="run_command",
                    claims=command,
                    evidence=f"operator_message={message[:500]}",
                )
                if not jr.skipped:
                    proposal["judge"] = jr.to_dict()
                    judge_note = (
                        f"\nJudge: {jr.verdict} ({jr.confidence}); "
                        f"safe_to_auto_apply=false"
                    )
                    if jr.verdict == "reject":
                        judge_note += " — judge recommends Reject; human still decides."
        except Exception:  # noqa: BLE001 — never block proposal on judge
            judge_note = ""
        return _result(
            f"Auth level: {auth}. Click Approve to run (or Reject).{pack_note}"
            f"{judge_note}\n{summary_or_err}",
            host_action_proposal=proposal,
        )

    catalog_match = _PROPOSE_CATALOG_RE.search(message)
    if catalog_match:
        action_key, host = catalog_match.group(1).lower(), catalog_match.group(2)
        if action_key == "run_command":
            return None
        valid_keys = set(list_all_catalog_keys())
        if action_key not in valid_keys:
            return None
        if is_ha_auto_actuate(action_key):
            return _try_ha_auto_actuate_catalog(
                action_key,
                host,
                {},
                config=config,
            )
        proposal, summary_or_err = _create_host_proposal(
            action_key,
            host,
            {},
            host_store=host_store,
            config=config,
            proposed_by=proposed_by,
        )
        if proposal is None:
            return _result(summary_or_err)
        auth = proposal.get("auth_level") or "Read"
        packs = proposal.get("will_enable_packs") or []
        pack_note = (
            f" Approve will enable: {', '.join(packs)}."
            if packs
            else ""
        )
        return _result(
            f"Auth level: {auth}. Click Approve to run (or Reject).{pack_note}\n{summary_or_err}",
            host_action_proposal=proposal,
        )

    return None


def _format_fleet_status(context: dict[str, Any]) -> str:
    mf = context.get("missions_fleet") or {}
    if not mf:
        return (
            "Mission fleet context is off. Enable the missions_fleet section in AI Config."
        )
    lines: list[str] = ["Mission fleet status (read-only):"]
    if mf.get("feeder_paused"):
        lines.append("- Feeder: PAUSED (FEEDER_PAUSE file present)")
    else:
        lines.append("- Feeder: active (no FEEDER_PAUSE)")
    lines.append(f"- Active runs: {mf.get('active_run_count', 0)}")
    artifacts = mf.get("artifacts_today") or {}
    lines.append(
        f"- Today findings: {artifacts.get('finding_count', 0)} "
        f"(judged {artifacts.get('judged_count', 0)})"
    )
    workers = mf.get("workers") or []
    if workers:
        lines.append("- Worker hosts:")
        for row in workers:
            host = row.get("host") or "?"
            label = row.get("label") or ""
            hb = row.get("heartbeat_status") or "unknown"
            enabled = row.get("enabled", True)
            if not enabled:
                lines.append(f"  .{host} ({label}): disabled (stub)")
                continue
            last = row.get("last_action") or ""
            tail = f" -- {last[:50]}" if last else ""
            lines.append(f"  .{host} ({label}): {hb}{tail}")
    enabled_targets = mf.get("enabled_target_hosts") or []
    if enabled_targets:
        host_list = ", ".join(f".{r.get('host')}" for r in enabled_targets)
        lines.append(f"- Enqueue audits on any enabled host: {host_list}")
        lines.append('  Example: "Audit host 102" or "Run host-facts on host 148"')
    for row in (mf.get("fleet") or [])[:10]:
        if row.get("kind") == "worker_host":
            continue
        label = row.get("label") or row.get("id")
        hb = row.get("heartbeat_status") or "unknown"
        active = row.get("active_run_count", 0)
        done = row.get("done_run_count", 0)
        if row.get("kind") == "skill":
            lines.append(f"- {label}: {active} active / {done} done")
        else:
            last = row.get("last_action") or ""
            tail = f" ({last[:60]})" if last else ""
            lines.append(f"- {label}: heartbeat={hb}{tail}")
    for run in (mf.get("active_runs") or [])[:4]:
        lines.append(
            f"  run {run.get('run_id', '?')[:8]}... "
            f"host={run.get('target_host')} skill={run.get('skill')} "
            f"status={run.get('status')}"
        )
    lines.append("\nOpen Admin -> Missions for live tool output on a selected run.")
    return "\n".join(lines)


def _try_fleet_status(message: str, context: dict[str, Any]) -> dict[str, Any] | None:
    if not _FLEET_STATUS_RE.search(message):
        return None
    return _result(_format_fleet_status(context))


def _wedge_from_context(context: dict[str, Any]) -> dict[str, Any]:
    mf = context.get("missions_fleet") or {}
    wedge = mf.get("wedge")
    if isinstance(wedge, dict) and wedge.get("ok") is not None:
        return wedge
    from src.ops.mission_wedge import detect_mission_wedge, format_wedge_report

    # Fallback if context was built without wedge (tests / partial context).
    runs = list(mf.get("recent_runs") or []) + list(mf.get("active_runs") or [])
    report = detect_mission_wedge(runs)
    report["_formatted"] = format_wedge_report(report)
    return report


def _try_mission_wedge_status(
    message: str, context: dict[str, Any]
) -> dict[str, Any] | None:
    if not _MISSION_WEDGE_RE.search(message):
        return None
    from src.ops.mission_wedge import format_wedge_report

    wedge = _wedge_from_context(context)
    text = wedge.get("_formatted") or format_wedge_report(wedge)
    return _result(text)


def _try_clear_stuck_missions(
    message: str,
    *,
    host_store: HostActionStore,
    config: dict[str, Any],
    proposed_by: str,
    context: dict[str, Any],
) -> dict[str, Any] | None:
    if not _CLEAR_STUCK_MISSIONS_RE.search(message):
        return None
    from src.ops.mission_wedge import format_wedge_report

    wedge = _wedge_from_context(context)
    briefing = wedge.get("_formatted") or format_wedge_report(wedge)
    proposal, summary_or_err = _create_host_proposal(
        "mission_clear_stuck",
        "111",
        {},
        host_store=host_store,
        config=config,
        proposed_by=proposed_by,
    )
    if proposal is None:
        return _result(f"{briefing}\n\nCould not create clear proposal: {summary_or_err}")
    auth = proposal.get("auth_level") or "Ops"
    return _result(
        f"{briefing}\n\nAuth level: {auth}. Click Approve to clear stuck missions "
        f"(marks wedged runs failed; does not touch inference).\n{summary_or_err}",
        host_action_proposal=proposal,
    )


def _parse_iso_utc(raw: str | None):
    """Best-effort ISO timestamp parse for activity windows."""
    from datetime import datetime

    if not raw:
        return None
    text = str(raw).strip()
    if not text:
        return None
    try:
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        return datetime.fromisoformat(text)
    except ValueError:
        return None


def _within_hours(iso: str | None, hours: int, *, now=None) -> bool:
    from datetime import UTC, datetime, timedelta

    when = _parse_iso_utc(iso)
    if when is None:
        return True  # keep undated rows rather than hide work
    if when.tzinfo is None:
        when = when.replace(tzinfo=UTC)
    ref = now or datetime.now(tz=UTC)
    # https://docs.python.org/3/library/datetime.html#timedelta-objects
    return when >= ref - timedelta(hours=max(1, min(hours, 72)))


def _run_window_timestamp(run: dict[str, Any]) -> str | None:
    """Prefer updated_at (completion time) when present, else created_at."""
    updated = run.get("updated_at")
    if updated:
        return str(updated)
    created = run.get("created_at")
    if created:
        return str(created)
    return None


def _run_in_window(run: dict[str, Any], hours: int, *, now=None) -> bool:
    return _within_hours(_run_window_timestamp(run), hours, now=now)


def _run_started_in_window(run: dict[str, Any], hours: int, *, now=None) -> bool:
    """True when the run's created_at is inside the asked hours.

    Used so leftover stuck missions (days old) are not listed as last-Nh active
    jobs. Missing created_at is not treated as in-window.
    """
    created = run.get("created_at")
    if not created:
        return False
    return _within_hours(str(created), hours, now=now)


def _dedupe_runs(runs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    seen: set[str] = set()
    out: list[dict[str, Any]] = []
    for run in runs:
        if not isinstance(run, dict):
            continue
        rid = str(run.get("run_id") or "")
        if rid and rid in seen:
            continue
        if rid:
            seen.add(rid)
        out.append(run)
    return out


def _format_run_line(run: dict[str, Any], *, prefix: str) -> str:
    return (
        f"- {prefix}: {str(run.get('run_id') or '')[:8]}... "
        f"{run.get('status')} skill={run.get('skill')} "
        f"host=.{run.get('target_host')} -- {(str(run.get('goal') or ''))[:70]}"
    )


def _format_activity_summary(
    context: dict[str, Any], *, hours: int = 8, fence: bool = True
) -> str:
    """Read-only rollup of missions / AI actions / incidents (no LLM)."""
    hours = max(1, min(int(hours), 72))
    lines: list[str] = [
        f"ALFa AI activity (last ~{hours}h, from admin context -- no frontier-code call):",
        "",
    ]

    from src.ops.mission_wedge import format_wedge_report

    wedge = _wedge_from_context(context)
    lines.append("## Mission queue health")
    lines.append(wedge.get("_formatted") or format_wedge_report(wedge))
    lines.append("")

    mf = context.get("missions_fleet") or {}
    if mf:
        lines.append("## Missions / agent fleet")
        lines.append(f"- Feeder: {'PAUSED' if mf.get('feeder_paused') else 'active'}")
        lines.append(f"- Active runs now: {mf.get('active_run_count', 0)}")
        artifacts = mf.get("artifacts_today") or {}
        inbox = artifacts.get("inbox_count")
        findings = artifacts.get("finding_count", 0)
        judged = artifacts.get("judged_count", 0)
        if inbox is not None:
            lines.append(
                f"- Today findings inbox: {inbox} "
                f"(structured Finding blocks={findings}, judged={judged})"
            )
        else:
            lines.append(f"- Today findings: {findings} (judged {judged})")
        lines.append("")

        all_runs = _dedupe_runs(
            list(mf.get("active_runs") or []) + list(mf.get("recent_runs") or [])
        )
        completed_statuses = frozenset({"done", "failed"})
        active_statuses = frozenset({"pending", "running"})
        completed_in_window = [
            r
            for r in all_runs
            if str(r.get("status") or "") in completed_statuses
            and _run_in_window(r, hours)
        ]
        active_runs = [
            r for r in all_runs if str(r.get("status") or "") in active_statuses
        ]
        active_in_window = [r for r in active_runs if _run_started_in_window(r, hours)]
        leftover_active = [
            r for r in active_runs if not _run_started_in_window(r, hours)
        ]
        listed_ids = {
            str(r.get("run_id") or "")
            for r in completed_in_window + active_runs
            if r.get("run_id")
        }
        other_in_window = [
            r
            for r in all_runs
            if str(r.get("run_id") or "") not in listed_ids and _run_in_window(r, hours)
        ]

        lines.append(f"## Completed missions (last ~{hours}h)")
        if not completed_in_window:
            lines.append(f"- No completed missions in the last ~{hours}h window.")
        else:
            for run in completed_in_window[:12]:
                lines.append(_format_run_line(run, prefix="Completed"))
        lines.append("")

        lines.append(f"## Active missions (started last ~{hours}h)")
        if not active_in_window:
            lines.append(f"- None started in the last ~{hours}h window.")
        else:
            for run in active_in_window[:6]:
                lines.append(
                    f"- Active: {str(run.get('run_id') or '')[:8]}... "
                    f"host=.{run.get('target_host')} skill={run.get('skill')} "
                    f"status={run.get('status')} -- {(str(run.get('goal') or ''))[:80]}"
                )
        if leftover_active:
            lines.append("")
            lines.append(
                f"## Stuck / leftover active (started before this ~{hours}h window)"
            )
            lines.append(
                "- These are not last-Nh jobs. Say Clear stuck missions for an Approve card."
            )
            for run in leftover_active[:6]:
                lines.append(
                    f"- Leftover: {str(run.get('run_id') or '')[:8]}... "
                    f"host=.{run.get('target_host')} skill={run.get('skill')} "
                    f"status={run.get('status')} -- {(str(run.get('goal') or ''))[:80]}"
                )
        if other_in_window:
            lines.append("")
            lines.append(f"## Other recent missions (last ~{hours}h)")
            for run in other_in_window[:8]:
                lines.append(_format_run_line(run, prefix="Recent"))
        lines.append("")

        for finding in (mf.get("top_findings") or [])[:6]:
            sev = finding.get("severity") or "?"
            would = (finding.get("would_take_action") or finding.get("suggestion") or "")[
                :120
            ]
            desc = (finding.get("description") or "")[:100]
            lines.append(f"- Finding [{sev}]: {desc}")
            if would:
                lines.append(f"  Would take (propose-only): {would}")
        lines.append("")
    else:
        lines.append("## Missions / agent fleet")
        lines.append("- missions_fleet context off (enable in AI Config).")
        lines.append("")

    packed_actions = [
        a for a in (context.get("recent_ai_actions") or []) if isinstance(a, dict)
    ]
    dump_packed = [
        a for a in (context.get("dump_observe_sample") or []) if isinstance(a, dict)
    ]
    if not dump_packed:
        dump_packed = [a for a in packed_actions if is_dump_observe_action(a)]
        packed_actions = [a for a in packed_actions if not is_dump_observe_action(a)]
    job_actions = [
        a
        for a in packed_actions
        if _within_hours(str(a.get("created_at") or ""), hours)
    ][:12]
    dump_in_window = [
        a
        for a in dump_packed
        if _within_hours(str(a.get("created_at") or ""), hours)
    ]
    dump_times = context.get("dump_observe_created_at")
    if isinstance(dump_times, list) and dump_times:
        dump_in_window_n = sum(
            1 for t in dump_times if t and _within_hours(str(t), hours)
        )
    else:
        dump_in_window_n = len(dump_in_window)
    dump_fetch_count = context.get("dump_observe_in_sample")
    if not isinstance(dump_fetch_count, int):
        dump_fetch_count = len(dump_packed)
    lines.append("## Recent AI actions (operator / catalog -- not dump ticks)")
    if not job_actions:
        lines.append("- None in window (or section disabled).")
    else:
        for a in job_actions:
            lines.append(
                f"- [{a.get('action_type') or '?'}] "
                f"{(a.get('summary') or '')[:140]} "
                f"({a.get('created_at') or '?'})"
            )
    lines.append("")
    lines.append("## Dump observe ticks (not completed jobs)")
    lines.append(
        f"- {dump_in_window_n} observe row(s) in this ~{hours}h filter "
        f"(fetch sample held {dump_fetch_count}; ticker is not a job)."
    )
    for a in dump_in_window[:3]:
        lines.append(
            f"- [{a.get('action_type') or '?'}] "
            f"{(a.get('summary') or '')[:100]} "
            f"({a.get('created_at') or '?'})"
        )
    lines.append("")

    pending = context.get("pending_host_actions") or []
    lines.append("## Pending host / mission Approves")
    if not pending:
        lines.append("- None.")
    else:
        for h in pending[:8]:
            if not isinstance(h, dict):
                continue
            lines.append(f"- {h.get('id')}: {(h.get('summary') or '')[:140]}")
    lines.append("")

    incidents = context.get("open_incidents_by_status") or {}
    alertnames = context.get("recent_alertnames") or []
    sample_counts = context.get("incident_counts_in_window") or {}
    row_limit = context.get("incident_window_row_limit") or 50
    window_kind = context.get("incident_window_kind") or "last_n_rows"
    lines.append("## Incidents")
    if incidents:
        parts = [f"{k}={v}" for k, v in incidents.items()]
        lines.append("- Open by status (unresolved now): " + ", ".join(parts))
    else:
        lines.append("- No open-incident summary in context.")
    if sample_counts:
        parts = [f"{k}={v}" for k, v in sample_counts.items()]
        lines.append(
            f"- Last {row_limit} listed rows ({window_kind}, mixed status, "
            f"not last ~{hours}h): "
            + ", ".join(parts)
        )
    if alertnames:
        lines.append("- Open alertnames: " + ", ".join(str(x) for x in alertnames[:8]))
    lines.append("")

    audit = context.get("recent_audit_events") or []
    lines.append(f"## Audit log (sample in last ~{hours}h)")
    audit_in_window: list[Any] = []
    for ev in audit:
        if isinstance(ev, dict):
            stamp = str(ev.get("created_at") or ev.get("at") or "")
            if stamp and _within_hours(stamp, hours):
                audit_in_window.append(ev)
        elif ev:
            audit_in_window.append(ev)
    if not audit_in_window:
        lines.append("- None in this window (older rows may exist in the packed sample).")
    else:
        for ev in audit_in_window[:8]:
            if isinstance(ev, dict):
                lines.append(
                    f"- {ev.get('created_at') or ev.get('at') or '?'} "
                    f"{ev.get('action') or ev.get('event') or ev.get('type') or ''} "
                    f"{(ev.get('detail') or ev.get('message') or '')[:80]}"
                )
            else:
                lines.append(f"- {str(ev)[:120]}")

    lines.append("")
    lines.append(
        "Open Admin -> Missions for live tool output and Findings by severity. "
        "Nothing above was auto-applied (L1 observe / propose)."
    )
    return _as_copyable_code_block("\n".join(lines), fence=fence)


def _try_activity_summary(
    message: str, context: dict[str, Any]
) -> dict[str, Any] | None:
    if not _ACTIVITY_SUMMARY_RE.search(message):
        return None
    hours = 8
    match = _ACTIVITY_HOURS_RE.search(message)
    if match:
        try:
            hours = int(match.group(1))
        except ValueError:
            hours = 8
    elif _OVERNIGHT_RE.search(message):
        hours = 12
    hours = max(1, min(hours, 72))
    return _result(_format_activity_summary(context, hours=hours))


def _format_cluster_status(context: dict[str, Any], *, fence: bool = True) -> str:
    """Read-only cluster / ops rollup (no LLM, no shard probes)."""
    lines: list[str] = [
        "ALFa AI cluster status (from admin context -- no frontier-code call):",
        "",
    ]

    ch = context.get("cluster_health")
    if isinstance(ch, dict):
        hosts = ch.get("hosts") or []
        if hosts:
            lines.append("## Hosts")
            for row in hosts[:12]:
                if not isinstance(row, dict):
                    continue
                key = row.get("key") or row.get("name") or "?"
                name = row.get("name") or key
                ok = row.get("ok")
                if ok is None:
                    ok = row.get("reachable")
                ok_s = "ok" if ok is True else ("down" if ok is False else "?")
                lines.append(f"- {key} ({name}): {ok_s}")
            lines.append("")
        else:
            lines.append("## Hosts")
            lines.append("- (empty host list in cluster_health)")
            lines.append("")

        brain = ch.get("brain")
        if isinstance(brain, dict):
            lines.append("## Brain services")
            for svc in (brain.get("services") or [])[:12]:
                if not isinstance(svc, dict):
                    continue
                name = svc.get("name") or "?"
                ok = svc.get("ok")
                ok_s = "ok" if ok is True else ("down" if ok is False else "?")
                lines.append(f"- {name}: {ok_s}")
            lines.append("")
        else:
            lines.append("## Brain services")
            lines.append("- not in gathered context")
            lines.append("")

        inference = ch.get("inference")
        if isinstance(inference, dict):
            endpoints = inference.get("endpoints") or []
            if endpoints:
                lines.append("## Inference")
                for ep in endpoints[:12]:
                    if not isinstance(ep, dict):
                        continue
                    name = ep.get("name") or "?"
                    ok = ep.get("ok")
                    ok_s = "ok" if ok is True else ("down" if ok is False else "?")
                    if ep.get("skipped"):
                        ok_s = "skipped"
                    lines.append(f"- {name}: {ok_s}")
                lines.append("")
            else:
                lines.append("## Inference")
                lines.append("- (no endpoints in cluster_health.inference)")
                lines.append("")
        else:
            lines.append("## Inference")
            lines.append("- not in gathered context")
            lines.append("")
    else:
        lines.append("## Hosts / Brain / Inference")
        lines.append("- cluster_health not in gathered context")
        lines.append("")

    prom = context.get("prometheus_ops")
    if isinstance(prom, dict):
        lines.append("## Firing alerts")
        firing = prom.get("firing_alerts") or []
        count = prom.get("firing_count", len(firing))
        lines.append(f"- firing_count: {count}")
        if firing:
            for row in firing[:10]:
                if not isinstance(row, dict):
                    continue
                name = row.get("alertname") or "?"
                sev = row.get("severity") or "?"
                summary = (row.get("summary") or "")[:100]
                tail = f" -- {summary}" if summary else ""
                lines.append(f"- [{sev}] {name}{tail}")
        elif count == 0:
            lines.append("- None firing (Watchdog omitted upstream).")
        if prom.get("error"):
            lines.append(f"- prometheus note: {prom.get('error')}")
        lines.append("")
    else:
        lines.append("## Firing alerts")
        lines.append("- prometheus_ops not in gathered context")
        lines.append("")

    open_by_status = context.get("open_incidents_by_status")
    open_alertnames = context.get("open_incident_alertnames")
    lines.append("## Open incidents")
    if open_by_status:
        parts = [f"{k}={v}" for k, v in open_by_status.items()]
        lines.append("- By status: " + ", ".join(parts))
    else:
        lines.append("- No open-incident status summary in context.")
    if open_alertnames:
        lines.append(
            "- Alertnames: " + ", ".join(str(x) for x in open_alertnames[:12])
        )
    lines.append("")

    he = context.get("home_energy_ops")
    lines.append("## Solar dump")
    if isinstance(he, dict):
        lines.append(f"- enabled: {he.get('enabled')}")
        lines.append(f"- dump_enabled: {he.get('dump_enabled')}")
        lines.append(f"- ha_ready: {he.get('ha_ready')}")
        skipped = he.get("last_skipped")
        if skipped:
            lines.append(f"- last_skipped: {skipped}")
    else:
        lines.append("- home_energy_ops not in gathered context")
    lines.append("")

    lines.append(
        "Read-only summary from admin context. For inference repair use cluster_stop "
        "then cluster_start on host 93 (orchestrator only -- no individual shard restart)."
    )
    return _as_copyable_code_block("\n".join(lines), fence=fence)


def _try_cluster_status(message: str, context: dict[str, Any]) -> dict[str, Any] | None:
    if not _CLUSTER_STATUS_RE.search(message):
        return None
    return _result(_format_cluster_status(context))


def _last_assistant_content(history: list[dict[str, str]] | None) -> str:
    if not history:
        return ""
    for turn in reversed(history):
        if (turn.get("role") or "").lower() == "assistant":
            return str(turn.get("content") or "")
    return ""


def _hours_from_last_reply(last: str) -> int:
    match = _ACTIVITY_REPLY_HOURS_RE.search(last)
    if not match:
        return 8
    try:
        return max(1, min(int(match.group(1)), 72))
    except ValueError:
        return 8


def _format_user_count(context: dict[str, Any]) -> str:
    count = context.get("user_count")
    if count is None:
        return "User count is not available in the current context."
    return f"There are currently {count} registered users in the ALFa AI system."


def _format_fact_check(context: dict[str, Any], *, hours: int = 8) -> str:
    """Ground an LLM reply in packed stores without calling frontier-code."""
    hours = max(1, min(int(hours), 72))
    mf = context.get("missions_fleet")
    lines: list[str] = [
        "ALFa AI fact check (packed admin context -- no frontier-code call):",
        "",
        "The previous assistant turn was model judgment unless it said "
        "'no frontier-code call'. Packed stores below are authoritative. "
        "A missing key in an LLM JSON slice is truncation, not proof the "
        "program invented run IDs.",
        "",
        "## Pack presence (this turn)",
    ]
    if isinstance(mf, dict) and mf:
        lines.append(
            f"- missions_fleet: present "
            f"(active_run_count={mf.get('active_run_count', 0)}, "
            f"feeder={'PAUSED' if mf.get('feeder_paused') else 'active'})"
        )
        for run in (mf.get("active_runs") or [])[:6]:
            if not isinstance(run, dict):
                continue
            lines.append(
                f"  run {str(run.get('run_id') or '')[:8]}... "
                f"host=.{run.get('target_host')} status={run.get('status')} "
                f"-- {(str(run.get('goal') or ''))[:70]}"
            )
    else:
        lines.append(
            "- missions_fleet: not in packed context "
            "(AI Config section off or empty)"
        )
    jobs = context.get("recent_ai_actions") or []
    lines.append(
        f"- recent_ai_actions (operator/catalog jobs packed): {len(jobs)}"
    )
    dump_n = context.get("dump_observe_in_sample")
    lines.append(
        f"- dump_observe_in_sample: {dump_n if isinstance(dump_n, int) else 0} "
        "(observe ticks, not jobs)"
    )
    open_inc = context.get("open_incidents_by_status") or {}
    if open_inc:
        parts = [f"{k}={v}" for k, v in open_inc.items()]
        lines.append("- open_incidents_by_status: " + ", ".join(parts))
    else:
        lines.append("- open_incidents_by_status: none")
    firing = 0
    prom = context.get("prometheus_ops")
    if isinstance(prom, dict):
        firing = int(prom.get("firing_count") or len(prom.get("firing_alerts") or []))
    lines.append(f"- prometheus firing_count: {firing}")
    lines.append("")
    lines.append(_format_activity_summary(context, hours=hours, fence=False))
    lines.append("")
    lines.append(_format_cluster_status(context, fence=False))
    return _as_copyable_code_block("\n".join(lines))


def _replay_known_rollup(
    last: str, context: dict[str, Any]
) -> dict[str, Any] | None:
    """Re-run a program formatter when last assistant text matches a known rollup."""
    if _FACT_CHECK_FIRST_LINE_PREFIX in last:
        return _result(
            _format_fact_check(context, hours=_hours_from_last_reply(last))
        )
    if _ACTIVITY_SUMMARY_FIRST_LINE_PREFIX in last:
        return _result(
            _format_activity_summary(
                context, hours=_hours_from_last_reply(last)
            )
        )
    if _CLUSTER_STATUS_FIRST_LINE_PREFIX in last:
        return _result(_format_cluster_status(context))
    if _FLEET_STATUS_PREFIX in last or last.startswith(
        "Mission fleet context is off"
    ):
        return _result(_format_fleet_status(context))
    if last.startswith("MISSION WEDGE DETECTED") or last.startswith(
        "Mission queue looks healthy"
    ):
        return _try_mission_wedge_status("are missions wedged?", context)
    if "registered users in the ALFa AI system" in last or last.startswith(
        "User count is not available"
    ):
        return _result(_format_user_count(context))
    if _GITHUB_CI_PREFIX in last or last.startswith("GitHub CI context is off"):
        return _try_github_ci_summary("what's failing in ci", context)
    if last.startswith("That request is blocked by policy"):
        return _result(_inference_BLOCK_REPLY)
    if last.startswith("I have read access to alfa-ai admin console context"):
        return _result(_SCOPE_REPLY)
    return None


def _try_followup_replay(
    message: str,
    context: dict[str, Any],
    *,
    history: list[dict[str, str]] | None = None,
) -> dict[str, Any] | None:
    text = (message or "").strip()
    is_show = bool(_FOLLOWUP_SHOW_RE.search(text))
    is_verify = bool(_FOLLOWUP_VERIFY_RE.search(text))
    if not text or not (is_show or is_verify):
        return None
    if _LONE_YES_RE.match(text) or _LONE_APPROVE_RE.match(text):
        return None
    if _FAKE_APPROVE_CLAIM_RE.search(text):
        return None

    last = _last_assistant_content(history)
    if not last:
        return None
    known = _replay_known_rollup(last, context)
    if known is not None:
        return known
    if is_verify:
        return _result(
            _format_fact_check(context, hours=_hours_from_last_reply(last))
        )
    return None


def _try_mission_enqueue(
    message: str,
    *,
    host_store: HostActionStore,
    config: dict[str, Any],
    proposed_by: str,
    target_host: str,
    skill: str,
    goal: str,
) -> dict[str, Any]:
    params = {
        "goal": goal,
        "target_host": target_host,
        "skill": skill,
        "research_only": True,
    }
    proposal, summary_or_err = _create_host_proposal(
        "mission_enqueue",
        "111",
        params,
        host_store=host_store,
        config=config,
        proposed_by=proposed_by,
    )
    if proposal is None:
        return _result(summary_or_err)
    auth = proposal.get("auth_level") or "Ops (mutating)"
    return _result(
        f"Auth level: {auth}. Click Approve to enqueue this read-only mission.\n"
        f"{summary_or_err}\n\n"
        "After Approve: use the Open Missions link in chat to watch Live tool events "
        "(output does not stream in this chat window).",
        host_action_proposal=proposal,
    )


def _try_review_errors_mission(
    message: str,
    *,
    host_store: HostActionStore,
    config: dict[str, Any],
    proposed_by: str,
) -> dict[str, Any] | None:
    if not _REVIEW_ERRORS_RE.search(message):
        return None
    return {
        "llm_continue": True,
        "skip_ssh": True,
        "repo_target": {"alias": "brain", "host": "111", "repo_dir": None},
        "pre_inspect": [],
    }


def _try_audit_all_hosts_hint(message: str) -> dict[str, Any] | None:
    if not _AUDIT_ALL_HOSTS_RE.search(message):
        return None
    from src.ops.mission_fleet import enabled_mission_hosts

    lines = [
        "Enabled worker hosts you can audit in this chat:",
    ]
    for host_id, label in enabled_mission_hosts():
        lines.append(f'  - .{host_id} ({label}): say "Audit host {host_id}"')
    lines.append(
        '\nEach "Audit host N" runs inspect steps here and the model replies in this chat '
        "(no Missions Approve)."
    )
    return _result("\n".join(lines))


def _try_audit_host(
    message: str,
    *,
    host_store: HostActionStore,
    config: dict[str, Any],
    proposed_by: str,
) -> dict[str, Any] | None:
    if _AUDIT_ALL_HOSTS_RE.search(message):
        return None
    match = _AUDIT_HOST_RE.search(message)
    if not match:
        return None
    target_host = match.group(1)
    from src.ops.mission_fleet import validate_mission_target_host

    try:
        target_host = validate_mission_target_host(target_host)
    except ValueError as exc:
        return _result(str(exc))
    if target_host not in load_hosts(config):
        return _result(f"Host {target_host} is not in the host action registry.")
    host_cfg = load_hosts(config).get(target_host) or {}
    repo_dir = host_cfg.get("repo_dir")
    pre_inspect: list[dict[str, Any]] = [
        {"action_key": "git_status"},
        {"action_key": "docker_ps"},
        {"action_key": "disk_usage"},
        {"action_key": "health_check"},
    ]
    if repo_dir:
        pre_inspect.insert(0, {"action_key": "repo_tree", "params": {"limit": 200}})
    return {
        "llm_continue": True,
        "repo_target": {
            "alias": f"host-{target_host}",
            "host": target_host,
            "repo_dir": repo_dir,
        },
        "pre_inspect": pre_inspect,
    }


def _try_host_facts_mission(
    message: str,
    *,
    host_store: HostActionStore,
    config: dict[str, Any],
    proposed_by: str,
) -> dict[str, Any] | None:
    match = _HOST_FACTS_RE.search(message)
    if not match:
        return None
    target_host = match.group(1)
    from src.ops.mission_fleet import validate_mission_target_host

    try:
        target_host = validate_mission_target_host(target_host)
    except ValueError as exc:
        return _result(str(exc))
    if target_host not in load_hosts(config):
        return _result(f"Host {target_host} is not in the host action registry.")
    host_cfg = load_hosts(config).get(target_host) or {}
    return {
        "llm_continue": True,
        "repo_target": {
            "alias": f"host-{target_host}",
            "host": target_host,
            "repo_dir": host_cfg.get("repo_dir"),
        },
        "pre_inspect": [
            {"action_key": "docker_ps"},
            {"action_key": "docker_stats"},
            {"action_key": "disk_usage"},
            {"action_key": "health_check"},
        ],
    }


def _is_ha_local_weather(message: str) -> bool:
    """HA / host 105 / solar weather radar -- not zip-code web search."""
    return bool(_HA_WEATHER_RE.search(message) and _HA_WEATHER_SITE_RE.search(message))


def _try_ha_weather_forecast(message: str) -> dict[str, Any] | None:
    """Inspect HA weather in this chat. Do not enqueue audit-repo."""
    if not _HA_WEATHER_RE.search(message):
        return None
    if _WEB_RESEARCH_RE.search(message) and not _is_ha_local_weather(message):
        return None
    from src.ops.home_assistant_client import DEFAULT_WEATHER_ENTITY

    forecast_type = "hourly" if _HOURLY_FORECAST_RE.search(message) else "daily"
    return {
        "llm_continue": True,
        "repo_target": {"alias": "home-assistant", "host": "105", "repo_dir": None},
        "pre_inspect": [
            {
                "action_key": "ha_get_forecasts",
                "params": {"entity_id": DEFAULT_WEATHER_ENTITY, "type": forecast_type},
            },
            {
                "action_key": "ha_get_state",
                "params": {"entity_id": DEFAULT_WEATHER_ENTITY},
            },
        ],
    }


def _try_web_research_mission(
    message: str,
    *,
    host_store: HostActionStore,
    config: dict[str, Any],
    proposed_by: str,
) -> dict[str, Any] | None:
    """LAN-admin online lookup via in-chat web_search inspect (no SSH key required)."""
    if _is_ha_local_weather(message):
        return None
    if not _WEB_RESEARCH_RE.search(message):
        return None
    query = " ".join((message or "").split())
    if len(query) > 500:
        query = query[:497] + "..."
    return {
        "llm_continue": True,
        "repo_target": {"alias": "brain", "host": "111", "repo_dir": None},
        "pre_inspect": [
            {
                "action_key": "web_search",
                "params": {"query": query},
            },
        ],
    }


def _try_feeder_control(
    message: str,
    *,
    host_store: HostActionStore,
    config: dict[str, Any],
    proposed_by: str,
    action_key: str,
) -> dict[str, Any] | None:
    proposal, summary_or_err = _create_host_proposal(
        action_key,
        "111",
        {},
        host_store=host_store,
        config=config,
        proposed_by=proposed_by,
    )
    if proposal is None:
        return _result(summary_or_err)
    auth = proposal.get("auth_level") or "Ops (mutating)"
    verb = "pause" if action_key == "mission_feeder_pause" else "resume"
    return _result(
        f"Auth level: {auth}. Click Approve to {verb} the audit mission feeder.\n{summary_or_err}",
        host_action_proposal=proposal,
    )


def _try_pause_feeder(
    message: str,
    *,
    host_store: HostActionStore,
    config: dict[str, Any],
    proposed_by: str,
) -> dict[str, Any] | None:
    if not _PAUSE_FEEDER_RE.search(message):
        return None
    return _try_feeder_control(
        message,
        host_store=host_store,
        config=config,
        proposed_by=proposed_by,
        action_key="mission_feeder_pause",
    )


def _try_resume_feeder(
    message: str,
    *,
    host_store: HostActionStore,
    config: dict[str, Any],
    proposed_by: str,
) -> dict[str, Any] | None:
    if not _RESUME_FEEDER_RE.search(message):
        return None
    return _try_feeder_control(
        message,
        host_store=host_store,
        config=config,
        proposed_by=proposed_by,
        action_key="mission_feeder_resume",
    )


def _extract_hot_host_key(message: str) -> str | None:
    match = _HOT_HOST_RE.search(message)
    if not match:
        return None
    for group in match.groups():
        if group:
            return group
    return None


def _try_hot_host_diagnosis(
    message: str,
    context: dict[str, Any],
    *,
    host_store: HostActionStore,
    config: dict[str, Any],
    proposed_by: str,
) -> dict[str, Any] | None:
    host_key = _extract_hot_host_key(message)
    if not host_key:
        return None

    from src.ops.prometheus_context import classify_host_thermal, filter_snapshot_for_host

    prom = context.get("prometheus_ops") or {}
    host_rows = filter_snapshot_for_host(prom, host_key)
    verdict = classify_host_thermal(host_rows)

    lines: list[str] = [
        f"Host .{host_key} load/thermal briefing (L1, read-only):",
        verdict,
    ]
    snap_err = prom.get("snapshot_error")
    if snap_err:
        lines.append(f"Prometheus snapshot note: {snap_err}")

    proposal, summary_or_err = _create_host_proposal(
        "docker_stats",
        host_key,
        {},
        host_store=host_store,
        config=config,
        proposed_by=proposed_by,
    )
    if proposal is None:
        lines.append(f"Next probe blocked: {summary_or_err}")
        lines.append(
            "You can still Approve prom_query on host 107 for ad-hoc PromQL, "
            "or host-facts / docker_ps on this host."
        )
        return _result("\n".join(lines))

    auth = proposal.get("auth_level") or "Read"
    packs = proposal.get("will_enable_packs") or []
    pack_note = f" Approve will enable: {', '.join(packs)}." if packs else ""
    lines.extend(
        [
            "",
            f"Next step: per-container CPU% via docker_stats (Auth level: {auth})."
            f" Click Approve to run (or Reject).{pack_note}",
            summary_or_err,
        ]
    )
    return _result("\n".join(lines), host_action_proposal=proposal)


def _try_ci_triage(
    message: str,
    *,
    host_store: HostActionStore,
    config: dict[str, Any],
    proposed_by: str,
) -> dict[str, Any] | None:
    from src.ops.ci_triage import try_parse_ci_triage

    triage = try_parse_ci_triage(message)
    if triage is None:
        return None

    action_key = triage.catalog_action_key or "run_command"
    params: dict[str, Any] = (
        {} if triage.catalog_action_key else {"command": triage.reproduce_command}
    )
    proposal, summary_or_err = _create_host_proposal(
        action_key,
        triage.host,
        params,
        host_store=host_store,
        config=config,
        proposed_by=proposed_by,
    )
    lines = [
        f"CI triage: {triage.repo} ({triage.failure_class}) on host .{triage.host}",
        f"Guess: {triage.root_cause_guess}",
    ]
    if proposal is None:
        lines.append(f"Reproduce blocked: {summary_or_err}")
        lines.append(
            "\n--- Cursor handoff (copy below) ---\n" + triage.cursor_handoff
        )
        return _result(
            "\n".join(lines),
            cursor_handoff=triage.cursor_handoff,
            ci_triage=triage.to_dict(),
        )

    auth = proposal.get("auth_level") or "Ops (mutating)"
    packs = proposal.get("will_enable_packs") or []
    pack_note = f" Approve will enable: {', '.join(packs)}." if packs else ""
    lines.extend(
        [
            f"Auth level: {auth}. Click Approve to reproduce locally.{pack_note}",
            summary_or_err,
            "\n--- Cursor handoff (after reproduce) ---\n" + triage.cursor_handoff,
        ]
    )
    return _result(
        "\n".join(lines),
        host_action_proposal=proposal,
        cursor_handoff=triage.cursor_handoff,
        ci_triage=triage.to_dict(),
    )


def try_handle_deterministic(
    message: str,
    context: dict[str, Any],
    *,
    host_store: HostActionStore,
    settings_store: AiSettingStore,
    actions_store: AiActionStore,
    config: dict[str, Any],
    operator_email: str,
    history: list[dict[str, str]] | None = None,
) -> dict[str, Any] | None:
    """Handle structured Ask ALFa intent without calling the LLM.

    None = use LLM path. A dict with llm_continue=True means: run pre_inspect then the LLM.
    """
    text = (message or "").strip()
    if not text:
        return None

    for handler in (
        lambda: _try_draft_judge_path(text, settings_store=settings_store),
        lambda: _try_blocklist(text),
        lambda: _try_scope_question(text),
        lambda: _try_followup_replay(text, context, history=history),
        lambda: _try_github_ci_summary(text, context),
        lambda: _try_user_count(text, context),
        lambda: _try_structured_read(text, context),
        lambda: _try_setting_write(
            text,
            settings_store=settings_store,
            actions_store=actions_store,
            operator_email=operator_email,
        ),
        lambda: _try_activity_summary(text, context),
        lambda: _try_cluster_status(text, context),
        lambda: _try_fleet_status(text, context),
        # Clear-stuck before wedge status (both mention "stuck missions").
        lambda: _try_clear_stuck_missions(
            text,
            host_store=host_store,
            config=config,
            proposed_by=operator_email,
            context=context,
        ),
        lambda: _try_mission_wedge_status(text, context),
        lambda: _try_review_errors_mission(
            text,
            host_store=host_store,
            config=config,
            proposed_by=operator_email,
        ),
        lambda: _try_audit_all_hosts_hint(text),
        lambda: _try_analyze_named_repo(
            text,
            host_store=host_store,
            config=config,
            proposed_by=operator_email,
        ),
        lambda: _try_audit_host(
            text,
            host_store=host_store,
            config=config,
            proposed_by=operator_email,
        ),
        lambda: _try_host_facts_mission(
            text,
            host_store=host_store,
            config=config,
            proposed_by=operator_email,
        ),
        lambda: _try_ha_weather_forecast(text),
        lambda: _try_web_research_mission(
            text,
            host_store=host_store,
            config=config,
            proposed_by=operator_email,
        ),
        lambda: _try_pause_feeder(
            text,
            host_store=host_store,
            config=config,
            proposed_by=operator_email,
        ),
        lambda: _try_resume_feeder(
            text,
            host_store=host_store,
            config=config,
            proposed_by=operator_email,
        ),
        lambda: _try_hot_host_diagnosis(
            text,
            context,
            host_store=host_store,
            config=config,
            proposed_by=operator_email,
        ),
        lambda: _try_propose_host_action(
            text,
            host_store=host_store,
            config=config,
            proposed_by=operator_email,
        ),
        lambda: _try_ci_triage(
            text,
            host_store=host_store,
            config=config,
            proposed_by=operator_email,
        ),
    ):
        result = handler()
        if result is not None:
            logger.info("ask-alfa deterministic path handled message prefix=%r", text[:80])
            return result

    return None
