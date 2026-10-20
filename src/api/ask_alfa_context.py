"""Ask ALFa packed-prompt context usage (admin context ring).

Slot window: llama.cpp --ctx-size / --parallel per
https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md
Char estimate: ~4 chars/token per https://platform.openai.com/tokenizer/
LiteLLM usage: https://docs.litellm.ai/docs/completion/usage
"""

from __future__ import annotations

import json
import os
import re
from typing import Any

INSPECT_COMPACT_KEEP_LAST = 2

DEFAULT_CTX_SIZE = 262144
DEFAULT_PARALLEL = 5

_ACTIVITY_CONTEXT_MAX_CHARS = 8000
_OPS_CONTEXT_MAX_CHARS = 8000

ACTIVITY_CONTEXT_KEYS: tuple[str, ...] = (
    "recent_ai_actions",
    "dump_observe_sample",
    "dump_observe_in_sample",
    "dump_observe_created_at",
    "activity_facts_meta",
    "pending_host_actions",
    "missions_fleet",
    "recent_audit_events",
    "incident_counts_in_window",
    "incident_window_kind",
    "incident_window_row_limit",
    "open_incidents_by_status",
    "open_incident_alertnames",
    "recent_alertnames",
    "home_energy_ops",
)

# Formatter uses dump timestamps; LLM JSON omits them so missions_fleet survives
# the 8000-char activity slice.
LLM_ACTIVITY_OMIT_KEYS: frozenset[str] = frozenset({"dump_observe_created_at"})

# Newest-N fetch from ai_actions (not a clock window). Official datetime windows
# are applied later in the activity formatter:
# https://docs.python.org/3/library/datetime.html#timedelta-objects
ASK_ALFA_AI_ACTIONS_FETCH_LIMIT = 100
ASK_ALFA_AI_ACTIONS_JOB_CAP = 40
ASK_ALFA_DUMP_OBSERVE_SAMPLE_CAP = 5

DUMP_OBSERVE_ACTION_TYPES: frozenset[str] = frozenset(
    {
        "solar_dump_observed",
        "solar_dump_recommended",
    }
)


def is_dump_observe_action(action: dict[str, Any]) -> bool:
    """True for HA dump ticker rows -- not operator jobs / completed missions."""
    action_type = str(action.get("action_type") or "")
    if action_type in DUMP_OBSERVE_ACTION_TYPES:
        return True
    summary = str(action.get("summary") or "").lower()
    return "ha_dump_tick" in summary


def split_ai_actions_for_ask_alfa(
    rows: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Split newest-N ai_actions into (operator jobs, dump-observe ticks)."""
    jobs: list[dict[str, Any]] = []
    dump: list[dict[str, Any]] = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        if is_dump_observe_action(row):
            dump.append(row)
        else:
            jobs.append(row)
    return jobs, dump


def activity_facts_meta(
    *,
    jobs_packed: int,
    dump_in_fetch: int,
    fetch_limit: int = ASK_ALFA_AI_ACTIONS_FETCH_LIMIT,
) -> dict[str, Any]:
    """Labels for LLM turns: samples are not last-N-hours job counts."""
    return {
        "ai_actions_are": (
            "newest N ai_actions rows (not a time window); "
            "dump observe ticks are not completed jobs"
        ),
        "ai_actions_fetch_limit": fetch_limit,
        "recent_ai_actions_count": jobs_packed,
        "dump_observe_in_fetch": dump_in_fetch,
        "incident_counts_in_window_are": (
            "histogram of last 50 mixed-status incident rows, not last N hours"
        ),
    }

OPS_CONTEXT_KEYS: tuple[str, ...] = (
    "cluster_health",
    "prometheus_ops",
    "github_ci",
    "models_summary",
    "user_count",
    "host_actions_enabled",
    "host_actions_readiness",
    "recent_incidents",
    "ai_settings",
)

_CATEGORY_LABELS: dict[str, str] = {
    "system": "System prompt",
    "activity": "Recent activity",
    "ops": "Cluster ops",
    "admin_context": "Host-action catalog",
    "inspect": "Inspect",
    "conversation": "Conversation",
}

_CATEGORY_ORDER = ("system", "activity", "ops", "admin_context", "inspect", "conversation")


def split_ask_alfa_context(
    context: dict[str, Any],
) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    """Split gathered admin context into activity, cluster ops, and catalog."""
    activity: dict[str, Any] = {}
    ops: dict[str, Any] = {}
    catalog: dict[str, Any] = {}
    for key, value in context.items():
        if key in ACTIVITY_CONTEXT_KEYS:
            activity[key] = value
        elif key in OPS_CONTEXT_KEYS:
            ops[key] = value
        else:
            catalog[key] = value
    return activity, ops, catalog


def _positive_int(raw: str | None, default: int) -> int:
    if not raw:
        return default
    text = str(raw).strip()
    if not text.isdigit():
        return default
    value = int(text)
    return value if value > 0 else default


def slot_window_tokens() -> int:
    """One llama.cpp parallel slot (CTX_SIZE / PARALLEL)."""
    ctx = _positive_int(
        (os.getenv("CTX_SIZE") or os.getenv("LLAMA_ARG_CTX_SIZE") or "").strip()
        or None,
        DEFAULT_CTX_SIZE,
    )
    parallel = _positive_int(
        (os.getenv("PARALLEL") or os.getenv("LLAMA_ARG_N_PARALLEL") or "").strip()
        or None,
        DEFAULT_PARALLEL,
    )
    return ctx // parallel


def estimate_tokens(text: str) -> int:
    """OpenAI ~4 chars/token heuristic; empty string -> 0."""
    if not text:
        return 0
    return max(1, (len(text) + 3) // 4)


def _message_text(message: dict[str, Any]) -> str:
    content = message.get("content")
    if content is None:
        return ""
    return str(content)


def _collapse_whitespace(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def summarize_inspect_step(step: dict[str, Any]) -> str:
    """One-line deterministic summary for compacted inspect steps (no secrets dump)."""
    host = str(step.get("host") or "?")
    action_key = str(step.get("action_key") or "?")
    ok = bool(step.get("ok"))
    exit_code = step.get("exit_code", 1)
    stdout = _collapse_whitespace(str(step.get("stdout") or ""))
    snippet = stdout[:80]
    status = "ok" if ok else f"exit_code={exit_code}"
    if snippet:
        return f"{host} {action_key} {status} stdout={snippet}"
    return f"{host} {action_key} {status}"


def compact_inspect_steps(
    steps: list[dict[str, Any]],
    keep_last: int = INSPECT_COMPACT_KEEP_LAST,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Split inspect steps into (older, recent) for LLM prompt compaction."""
    if len(steps) <= keep_last:
        return [], list(steps)
    split_at = len(steps) - keep_last
    return steps[:split_at], steps[split_at:]


def build_inspect_compact_user_message(older: list[dict[str, Any]]) -> str | None:
    if not older:
        return None
    lines = ["Inspect summary (compacted):"]
    lines.extend(summarize_inspect_step(step) for step in older)
    return "\n".join(lines)


def is_pending_propose_tool_content(content: str) -> bool:
    """True when tool JSON is an in-flight propose_host_action (do not compact)."""
    try:
        data = json.loads(content)
    except (json.JSONDecodeError, TypeError):
        return False
    if not isinstance(data, dict):
        return False
    if data.get("action_id"):
        return True
    summary = data.get("summary")
    if isinstance(summary, dict) and summary.get("status") == "pending":
        return True
    return False


def compact_inspect_tool_content(parsed: dict[str, Any]) -> str:
    """Shrink an inspect tool-result JSON for older LLM turns."""
    stdout = _collapse_whitespace(str(parsed.get("stdout") or ""))
    compact = {
        "ok": parsed.get("ok"),
        "action_key": parsed.get("action_key"),
        "host": parsed.get("host"),
        "exit_code": parsed.get("exit_code"),
        "stdout": stdout[:80],
        "compacted": True,
    }
    return json.dumps(compact, ensure_ascii=True)


def categorize_message(message: dict[str, Any]) -> str:
    role = str(message.get("role") or "")
    text = _message_text(message)
    if role == "system":
        return "system"
    if role == "tool":
        return "inspect"
    if role == "user":
        if text.startswith("Recent activity"):
            return "activity"
        if text.startswith("Cluster ops"):
            return "ops"
        if text.startswith("Host-action catalog") or text.startswith("Admin context"):
            return "admin_context"
        if text.startswith("Inspect summary (compacted)"):
            return "inspect"
        if text.startswith("Inspect findings"):
            return "inspect"
        return "conversation"
    return "conversation"


def categorize_packed_messages(messages: list[dict[str, Any]]) -> dict[str, int]:
    totals = {key: 0 for key in _CATEGORY_ORDER}
    for message in messages:
        key = categorize_message(message)
        totals[key] = totals.get(key, 0) + estimate_tokens(_message_text(message))
    return totals


def _scale_category_totals(
    totals: dict[str, int],
    target: int,
) -> dict[str, int]:
    raw_sum = sum(totals.values())
    if target <= 0:
        return {key: 0 for key in _CATEGORY_ORDER}
    if raw_sum <= 0:
        # Avoid 0-sum: attribute everything to conversation.
        return {
            "system": 0,
            "activity": 0,
            "ops": 0,
            "admin_context": 0,
            "inspect": 0,
            "conversation": target,
        }
    scaled: dict[str, int] = {}
    allocated = 0
    keys = list(_CATEGORY_ORDER)
    for index, key in enumerate(keys):
        if index == len(keys) - 1:
            scaled[key] = max(0, target - allocated)
        else:
            value = int(round(totals[key] * target / raw_sum))
            scaled[key] = value
            allocated += value
    return scaled


def build_context_usage(
    messages: list[dict[str, Any]],
    *,
    prompt_tokens: int | None = None,
    completion_tokens: int | None = None,
) -> dict[str, Any]:
    """Build context_usage payload for GET / monitoring-agent responses."""
    window_tokens = slot_window_tokens()
    category_totals = categorize_packed_messages(messages)

    if prompt_tokens is not None and prompt_tokens >= 0:
        used_tokens = int(prompt_tokens)
        source = "litellm_usage"
        final_totals = _scale_category_totals(category_totals, used_tokens)
    else:
        used_tokens = sum(category_totals.values())
        source = "char_estimate"
        final_totals = category_totals

    payload: dict[str, Any] = {
        "used_tokens": used_tokens,
        "window_tokens": window_tokens,
        "source": source,
        "categories": [
            {
                "key": key,
                "label": _CATEGORY_LABELS[key],
                "tokens": final_totals.get(key, 0),
            }
            for key in _CATEGORY_ORDER
        ],
    }
    if completion_tokens is not None and completion_tokens >= 0:
        payload["completion_tokens"] = int(completion_tokens)
    return payload
