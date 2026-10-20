"""Cluster host probe URLs in worker_monitoring."""

from __future__ import annotations

import pytest

from src.api.worker_monitoring import (
    _CLUSTER_HOSTS_DEFAULT,
    _load_cluster_hosts,
    build_cluster_hosts_report,
)


def test_brain_api_host_check_is_derived_self() -> None:
    """Same-process HTTP self-check deadlocks the uvicorn event loop."""
    brain = next(h for h in _CLUSTER_HOSTS_DEFAULT if h.get("key") == "brain-111")
    api = next(c for c in brain["checks"] if c.get("name") == "brain-api")
    assert api["derived"] == "self"
    assert "url" not in api


def test_litellm_host_check_still_uses_compose_service_dns() -> None:
    brain = next(h for h in _CLUSTER_HOSTS_DEFAULT if h.get("key") == "brain-111")
    lite = next(c for c in brain["checks"] if c.get("name") == "litellm")
    assert lite["url"] == "http://alfa-ai-litellm:4000"


def test_apps_105_probes_dockge_agent() -> None:
    apps = next(h for h in _CLUSTER_HOSTS_DEFAULT if h.get("key") == "apps-105")
    dockge = next(c for c in apps["checks"] if c.get("name") == "dockge-105")
    assert dockge["url"] == "http://apps"
    assert dockge.get("path") == "/"


def test_load_cluster_hosts_default_when_env_unset(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("ALFA_AI_CLUSTER_HOSTS_JSON", raising=False)
    loaded = _load_cluster_hosts()
    assert loaded[0]["key"] == "brain-111"


def test_brain_api_derived_self_is_ok_without_http(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("ALFA_AI_CLUSTER_HOSTS_JSON", raising=False)
    monkeypatch.setattr(
        "src.api.worker_monitoring.check_frontier_coordinator",
        lambda: {"ok": True},
    )
    monkeypatch.setattr(
        "src.api.inference_shards.parse_inference_shard_endpoints",
        lambda: [("orchestrator", 31356), ("orchestrator", 31350), ("hub", 31353)],
    )
    monkeypatch.setattr(
        "src.api.worker_monitoring._http_check",
        lambda name, url, path="", timeout=3.0: {
            "name": name,
            "ok": True,
            "url": url + path,
            "status_code": 200,
            "latency_ms": 1.0,
        },
    )
    report = build_cluster_hosts_report()
    brain = next(h for h in report if h.get("key") == "brain-111")
    api = next(c for c in brain["checks"] if c["name"] == "brain-api")
    assert api["ok"] is True
    assert api.get("derived") is True
    assert brain["reachable"] is True


def test_opt_in_offline_host_is_not_reachable(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("ALFA_AI_CLUSTER_HOSTS_JSON", raising=False)
    monkeypatch.setattr(
        "src.api.worker_monitoring.check_frontier_coordinator",
        lambda: {"ok": True},
    )
    monkeypatch.setattr(
        "src.api.inference_shards.parse_inference_shard_endpoints",
        lambda: [("orchestrator", 31356)],
    )
    monkeypatch.setattr(
        "src.api.worker_monitoring._http_check",
        lambda name, url, path="", timeout=3.0: {
            "name": name,
            "ok": True,
            "url": url + path,
            "status_code": 200,
            "latency_ms": 1.0,
        },
    )
    report = build_cluster_hosts_report()
    gaming_worker_c = next(h for h in report if h.get("key") == "gaming-worker-c")
    assert gaming_worker_c["reachable"] is False
    check = gaming_worker_c["checks"][0]
    assert check["ok"] is False
    assert check.get("skipped") is True


def test_empty_checks_host_is_reachable(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv(
        "ALFA_AI_CLUSTER_HOSTS_JSON",
        '[{"key": "empty", "name": "empty", "lan_ip": "orchestrator", "role": "x", "checks": []}]',
    )
    report = build_cluster_hosts_report()
    assert report[0]["reachable"] is True
    assert report[0]["checks"] == []
