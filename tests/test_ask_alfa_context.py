"""Unit tests for Ask ALFa context window ring helpers."""

from __future__ import annotations

import pytest

from src.api.ask_alfa_context import (
    ACTIVITY_CONTEXT_KEYS,
    OPS_CONTEXT_KEYS,
    activity_facts_meta,
    build_context_usage,
    categorize_message,
    categorize_packed_messages,
    compact_inspect_steps,
    estimate_tokens,
    is_dump_observe_action,
    slot_window_tokens,
    split_ai_actions_for_ask_alfa,
    split_ask_alfa_context,
    summarize_inspect_step,
)


def test_estimate_tokens_empty_is_zero() -> None:
    assert estimate_tokens("") == 0


def test_estimate_tokens_non_empty_minimum_one() -> None:
    assert estimate_tokens("a") == 1
    assert estimate_tokens("abcd") == 1
    assert estimate_tokens("abcde") == 2


def test_slot_window_tokens_defaults(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("CTX_SIZE", raising=False)
    monkeypatch.delenv("LLAMA_ARG_CTX_SIZE", raising=False)
    monkeypatch.delenv("PARALLEL", raising=False)
    monkeypatch.delenv("LLAMA_ARG_N_PARALLEL", raising=False)
    assert slot_window_tokens() == 52428


def test_slot_window_tokens_from_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("CTX_SIZE", "81920")
    monkeypatch.setenv("PARALLEL", "2")
    assert slot_window_tokens() == 40960


def test_categorize_message_roles() -> None:
    assert categorize_message({"role": "system", "content": "sys"}) == "system"
    assert (
        categorize_message(
            {"role": "user", "content": "Recent activity (authoritative):\n{}"}
        )
        == "activity"
    )
    assert (
        categorize_message(
            {"role": "user", "content": "Cluster ops (authoritative):\n{}"}
        )
        == "ops"
    )
    assert (
        categorize_message(
            {"role": "user", "content": "Host-action catalog (truncated):\n{}"}
        )
        == "admin_context"
    )
    assert (
        categorize_message({"role": "user", "content": "Admin context (truncated):\n{}"})
        == "admin_context"
    )
    assert (
        categorize_message({"role": "user", "content": "Inspect findings (authoritative):\n{}"})
        == "inspect"
    )
    assert categorize_message({"role": "tool", "content": "{}"}) == "inspect"
    assert (
        categorize_message(
            {"role": "user", "content": "Inspect summary (compacted):\n106 docker_ps ok"}
        )
        == "inspect"
    )
    assert categorize_message({"role": "user", "content": "Operator message: hi"}) == "conversation"
    assert categorize_message({"role": "assistant", "content": "ok"}) == "conversation"


def test_build_context_usage_char_estimate(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("CTX_SIZE", raising=False)
    monkeypatch.delenv("LLAMA_ARG_CTX_SIZE", raising=False)
    monkeypatch.delenv("PARALLEL", raising=False)
    monkeypatch.delenv("LLAMA_ARG_N_PARALLEL", raising=False)
    messages = [
        {"role": "system", "content": "x" * 40},
        {"role": "user", "content": "Recent activity (authoritative):\n" + ("a" * 40)},
        {"role": "user", "content": "Cluster ops (authoritative):\n" + ("o" * 40)},
        {"role": "user", "content": "Host-action catalog (truncated):\n" + ("y" * 40)},
        {"role": "user", "content": "Operator message: "},
    ]
    usage = build_context_usage(messages)
    assert usage["window_tokens"] == 52428
    assert usage["source"] == "char_estimate"
    assert usage["used_tokens"] == sum(c["tokens"] for c in usage["categories"])
    assert [c["key"] for c in usage["categories"]] == [
        "system",
        "activity",
        "ops",
        "admin_context",
        "inspect",
        "conversation",
    ]


def test_build_context_usage_litellm_scales_categories() -> None:
    messages = [
        {"role": "system", "content": "a" * 100},
        {"role": "user", "content": "Host-action catalog (truncated):\n" + ("b" * 100)},
        {"role": "user", "content": "Operator message: hello"},
    ]
    usage = build_context_usage(messages, prompt_tokens=1000, completion_tokens=50)
    assert usage["source"] == "litellm_usage"
    assert usage["used_tokens"] == 1000
    assert usage["completion_tokens"] == 50
    assert sum(c["tokens"] for c in usage["categories"]) == 1000


def test_build_context_usage_litellm_zero_sum_fallback() -> None:
    messages = [{"role": "user", "content": ""}]
    usage = build_context_usage(messages, prompt_tokens=500)
    assert usage["used_tokens"] == 500
    conversation = next(c for c in usage["categories"] if c["key"] == "conversation")
    assert conversation["tokens"] == 500


def test_split_ask_alfa_context_moves_activity_keys() -> None:
    context = {
        "recent_ai_actions": [{"summary": "x"}],
        "host_action_catalog": [{"key": "docker_ps"}],
        "ai_settings": [],
        "missions_fleet": {"recent_runs": []},
        "cluster_health": {"hosts": []},
        "prometheus_ops": {"firing_alerts": []},
    }
    activity, ops, catalog = split_ask_alfa_context(context)
    assert "recent_ai_actions" in activity
    assert "missions_fleet" in activity
    assert "host_action_catalog" in catalog
    assert "ai_settings" in ops
    assert "cluster_health" in ops
    assert "prometheus_ops" in ops
    for key in ACTIVITY_CONTEXT_KEYS:
        if key in context:
            assert key in activity
    for key in OPS_CONTEXT_KEYS:
        if key in context:
            assert key in ops
    for key in activity:
        assert key not in ops
        assert key not in catalog
    for key in ops:
        assert key not in activity
        assert key not in catalog


def test_split_ai_actions_dump_observe_not_jobs() -> None:
    jobs, dump = split_ai_actions_for_ask_alfa(
        [
            {"action_type": "setting_proposal", "summary": "set key"},
            {"action_type": "solar_dump_observed", "summary": "tick"},
            {
                "action_type": "host_command_executed",
                "summary": "ha_dump_tick on 105",
            },
        ]
    )
    assert len(jobs) == 1
    assert jobs[0]["action_type"] == "setting_proposal"
    assert len(dump) == 2
    assert is_dump_observe_action(dump[0])
    meta = activity_facts_meta(jobs_packed=1, dump_in_fetch=2)
    assert "not a time window" in meta["ai_actions_are"]
    assert "not last N hours" in meta["incident_counts_in_window_are"]


def test_split_ask_alfa_context_catalog_holds_leftovers() -> None:
    context = {
        "host_action_catalog": [{"key": "docker_ps"}],
        "custom_leftover": {"note": "not in activity or ops"},
    }
    activity, ops, catalog = split_ask_alfa_context(context)
    assert activity == {}
    assert ops == {}
    assert "host_action_catalog" in catalog
    assert "custom_leftover" in catalog
