"""
Worker heartbeat storage (Redis) and aggregated admin health for the brain (hub stack).
"""

from __future__ import annotations

import json
import logging
import os
import re
import socket
import time
from typing import Any
from urllib.parse import urlsplit

import httpx
import redis
from redis.exceptions import RedisError

logger = logging.getLogger(__name__)

WORKER_KEY_PREFIX = "worker:"
# Single TTL surface: WORKER_HEARTBEAT_REDIS_TTL_SEC preferred; legacy WORKER_HEARTBEAT_REDIS_TTL accepted.
_ttl_raw = (
    os.getenv("WORKER_HEARTBEAT_REDIS_TTL_SEC", "").strip()
    or os.getenv("WORKER_HEARTBEAT_REDIS_TTL", "").strip()
    or "120"
)
WORKER_REDIS_TTL_SEC = max(60, min(int(_ttl_raw or "120"), 3600))

def _strip_v1_suffix(url: str) -> str:
    base = url.rstrip("/")
    if base.endswith("/v1"):
        return base[: -len("/v1")]
    return base


def _is_ollama_openai_base(url: str) -> bool:
    low = url.lower()
    return ":11434" in low or "ollama" in low


def _redis() -> redis.Redis:
    url = os.getenv("REDIS_URL", "redis://localhost:6379/0")
    return redis.Redis.from_url(url, decode_responses=True)


def sanitize_worker_id(name: str) -> str:
    cleaned = re.sub(r"[^a-zA-Z0-9_.-]", "_", (name or "").strip())
    return (cleaned[:128] or "unknown")


def store_worker_heartbeat(body: dict[str, Any]) -> tuple[str, str]:
    """Persist worker payload under worker:{id} with TTL. Returns (redis_key, worker_id)."""
    name = str(body.get("worker_name") or body.get("hostname") or "unknown")
    wid = sanitize_worker_id(name)
    key = f"{WORKER_KEY_PREFIX}{wid}"
    r = _redis()
    r.setex(key, WORKER_REDIS_TTL_SEC, json.dumps(body))
    try:
        from src.api import redis_heartbeat as rh

        wn = str(body.get("worker_name") or body.get("hostname") or "unknown")
        role = str(body.get("worker_role") or body.get("role") or "gpu-worker")
        rh.store_worker_heartbeat(wn, role, ttl_sec=WORKER_REDIS_TTL_SEC, extra=body)
    except Exception:
        logger.exception("redis_heartbeat mirror failed for worker heartbeat")
    return key, wid


def load_workers_from_redis() -> list[dict[str, Any]]:
    """Return decoded worker records with staleness hints."""
    r = _redis()
    now = int(time.time())
    out: list[dict[str, Any]] = []
    try:
        for key in r.scan_iter(match=f"{WORKER_KEY_PREFIX}*"):
            raw = r.get(key)
            if not raw:
                continue
            try:
                data = json.loads(raw)
            except json.JSONDecodeError:
                data = {"_parse_error": True, "_raw": raw[:500]}
            ts = data.get("ts")
            age_sec: int | None = None
            stale = True
            if isinstance(ts, int):
                age_sec = max(0, now - ts)
                stale = age_sec > WORKER_REDIS_TTL_SEC
            entry = {
                "redis_key": key,
                "age_sec": age_sec,
                "stale": stale,
                "payload": data,
            }
            out.append(entry)
    except RedisError as exc:
        return [{"error": "redis_scan_failed", "detail": str(exc)[:300]}]
    out.sort(key=lambda x: (x.get("payload") or {}).get("worker_name", ""))
    return out


def _http_check(
    name: str,
    url: str,
    *,
    method: str = "GET",
    path: str = "",
    headers: dict[str, str] | None = None,
    timeout: float = 5.0,
) -> dict[str, Any]:
    full = url.rstrip("/") + path
    t0 = time.perf_counter()
    try:
        with httpx.Client(timeout=timeout) as client:
            resp = client.request(method, full, headers=headers or {})
        latency_ms = round((time.perf_counter() - t0) * 1000, 1)
        ok = resp.status_code < 400
        return {
            "name": name,
            "ok": ok,
            "url": full,
            "status_code": resp.status_code,
            "latency_ms": latency_ms,
        }
    except Exception as exc:  # noqa: BLE001
        latency_ms = round((time.perf_counter() - t0) * 1000, 1)
        return {
            "name": name,
            "ok": False,
            "url": full,
            "error": str(exc)[:300],
            "latency_ms": latency_ms,
        }


def _tcp_check(name: str, url: str, *, timeout: float = 5.0) -> dict[str, Any]:
    """Plain TCP-connect reachability probe (no protocol bytes sent/read).

    Use for services that do not speak HTTP, e.g. llama.cpp ``rpc-server``
    shards, which only understand the raw RPC ``HELLO`` handshake. Sending an
    HTTP request to those ports (via ``_http_check``) leaves the connection
    hanging until timeout and, per upstream docs, risks wedging the shard:
    https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md
    ("Never run the RPC server on an open network..."; non-HELLO bytes can
    wedge a shard). See docs/LLAMACPP_RPC_OPERATOR.md § "Do not curl
    rpc-server ports".
    """
    parts = urlsplit(url if "//" in url else f"//{url}")
    host = parts.hostname or ""
    port = parts.port
    t0 = time.perf_counter()
    if not host or not port:
        return {"name": name, "ok": False, "url": url, "error": f"invalid host/port in {url!r}"}
    try:
        with socket.create_connection((host, port), timeout=timeout):
            pass
        latency_ms = round((time.perf_counter() - t0) * 1000, 1)
        return {"name": name, "ok": True, "url": url, "latency_ms": latency_ms}
    except OSError as exc:
        latency_ms = round((time.perf_counter() - t0) * 1000, 1)
        return {"name": name, "ok": False, "url": url, "error": str(exc)[:300], "latency_ms": latency_ms}


def check_postgres() -> dict[str, Any]:
    url = (os.getenv("DATABASE_URL") or "").strip()
    if not url:
        return {"name": "postgres", "ok": False, "error": "DATABASE_URL unset"}
    try:
        import psycopg

        with psycopg.connect(url, connect_timeout=5) as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
        return {"name": "postgres", "ok": True}
    except Exception as exc:  # noqa: BLE001
        return {"name": "postgres", "ok": False, "error": str(exc)[:300]}


def check_redis_ping() -> dict[str, Any]:
    try:
        r = _redis()
        ok = bool(r.ping())
        return {"name": "redis", "ok": ok}
    except RedisError as exc:
        return {"name": "redis", "ok": False, "error": str(exc)[:300]}


def check_llamacpp_coordinator(name: str, env_var: str, default_url: str) -> dict[str, Any]:
    """Probe an llama.cpp RPC coordinator /health (expects JSON status ok)."""
    raw = (os.getenv(env_var) or default_url).strip()
    if not raw:
        return {"name": name, "ok": False, "error": f"{env_var} unset"}
    base = _strip_v1_suffix(raw)
    api_key = (os.getenv("LLAMA_API_KEY") or "change-me").strip()
    headers = {"Authorization": f"Bearer {api_key}"} if api_key else None
    full = f"{base}/health"
    t0 = time.perf_counter()
    try:
        with httpx.Client(timeout=8.0) as client:
            resp = client.get(full, headers=headers)
            if resp.status_code == 200:
                body = resp.json()
                if body.get("status") == "ok":
                    out: dict[str, Any] = {
                        "name": name,
                        "ok": True,
                        "url": full,
                        "status_code": 200,
                        "latency_ms": round((time.perf_counter() - t0) * 1000, 1),
                    }
                    try:
                        models_resp = client.get(
                            f"{base}/v1/models",
                            headers=headers,
                            timeout=8.0,
                        )
                        if models_resp.status_code == 200:
                            ids = [
                                m.get("id")
                                for m in models_resp.json().get("data", [])
                                if isinstance(m, dict) and m.get("id")
                            ]
                            if ids:
                                out["models"] = ids
                    except Exception:
                        pass
                    return out
            if resp.status_code == 503:
                try:
                    err = resp.json().get("error", {})
                    if err.get("message") == "Loading model":
                        return {
                            "name": name,
                            "ok": False,
                            "loading": True,
                            "url": full,
                            "status_code": 503,
                            "detail": "Loading model",
                        }
                except Exception:
                    pass
            return {
                "name": name,
                "ok": False,
                "url": full,
                "status_code": resp.status_code,
                "error": resp.text[:300],
            }
    except Exception as exc:  # noqa: BLE001
        return {"name": name, "ok": False, "url": full, "error": str(exc)[:300]}


def check_frontier_coordinator() -> dict[str, Any]:
    """Production RPC coordinator (hub :31360) for inference / pool72 / pool80."""
    from src.api.llm_config import is_pool72_mode, is_pool80_mode

    if is_pool80_mode():
        name = "pool80-coordinator"
    elif is_pool72_mode():
        name = "pool72-coordinator"
    else:
        name = "frontier-code-coordinator"
    return check_llamacpp_coordinator(
        name,
        "LLAMACPP_CODE27_URL",
        "http://hub/v1",
    )


def check_speed_tier_backend() -> dict[str, Any]:
    """RETIRED (2026-07): former 35B MoE / Ollama speed tier.

    Kept for optional revive (``switch-pool-35b.sh`` + ``LLAMACPP_35B_URL``).
    Not included in live brain/inference health unless
    ``ALFA_PROBE_SPEED_TIER_35B=1``.
    """
    raw = (os.getenv("LLAMACPP_35B_URL") or "").strip()
    if not raw:
        return {
            "name": "speed-tier-35b",
            "ok": True,
            "skipped": True,
            "retired": True,
            "note": "retired: set ALFA_PROBE_SPEED_TIER_35B=1 and LLAMACPP_35B_URL only for revive",
        }
    if _is_ollama_openai_base(raw):
        base = _strip_v1_suffix(raw)
        res = _check_ollama_endpoint(
            "speed-tier-35b",
            base,
            aliases=["chat", "fast", "public-chat", "inline"],
        )
    else:
        res = check_llamacpp_coordinator(
            "speed-tier-35b",
            "LLAMACPP_35B_URL",
            raw,
        )
    res["retired"] = True
    return res


def check_frontier_coordinator_legacy() -> dict[str, Any]:
    """Legacy dual-GPU coordinator profile (orchestrator :31360). Informational only."""
    return check_llamacpp_coordinator(
        "frontier-legacy-coordinator",
        "LLAMACPP_FRONTIER_URL",
        "http://orchestrator/v1",
    )


def build_brain_services_report() -> dict[str, Any]:
    """Reachability of stack services from the API container (main brain)."""
    ollama_base = (os.getenv("OLLAMA_BASE_URL") or "").strip()
    litellm_base = (os.getenv("LITELLM_BASE_URL") or "").strip()

    master = (os.getenv("LITELLM_MASTER_KEY") or os.getenv("LITELLM_API_KEY") or "").strip()

    services: list[dict[str, Any]] = []

    # Ollama is only a brain dependency when the LLM client actually routes to
    # it (ALFA_AI_PROVIDER=ollama, or no litellm/openai/anthropic configured --
    # see src/llm/client.py _choose_provider). In production LITELLM_BASE_URL is
    # set, so the brain talks to models via LiteLLM and OLLAMA_BASE_URL is unused
    # for inference. deploy/docker-compose.yml hardwires the env default, so the
    # var is never truly unset in-container -- gate on the active provider, not
    # on whether the string is present, or a decommissioned brain-local Ollama
    # shows a permanent false "DOWN" on the admin health surface.
    _provider = (os.getenv("ALFA_AI_PROVIDER") or "").strip().lower()
    _ollama_is_active = _provider == "ollama" or (
        not _provider
        and not (os.getenv("LITELLM_BASE_URL") or "").strip()
        and not (os.getenv("OPENAI_API_KEY") or "").strip()
        and not (os.getenv("ANTHROPIC_API_KEY") or "").strip()
    )
    if ollama_base and _ollama_is_active:
        services.append(_http_check("ollama", ollama_base, path="/api/tags"))
    elif ollama_base:
        # Configured but not the active provider: probe for info, never fail on it.
        probe = _http_check("ollama", ollama_base, path="/api/tags")
        if probe.get("ok"):
            probe["note"] = "optional: brain routes chat via LiteLLM (ALFA_AI_PROVIDER != ollama)"
            services.append(probe)
        else:
            services.append({
                "name": "ollama",
                "ok": True,
                "skipped": True,
                "url": ollama_base,
                "note": "optional: brain routes chat via LiteLLM (ALFA_AI_PROVIDER != ollama); not required",
            })
    else:
        services.append({
            "name": "ollama",
            "ok": True,
            "skipped": True,
            "note": "not a brain dependency (models via LiteLLM); OLLAMA_BASE_URL unset",
        })

    if litellm_base:
        r_litellm = _http_check("litellm", litellm_base, path="/health/liveliness")
        if not r_litellm.get("ok") and master:
            r_litellm = _http_check(
                "litellm",
                litellm_base,
                path="/health",
                headers={"Authorization": f"Bearer {master}"},
            )
        services.append(r_litellm)
    else:
        services.append({"name": "litellm", "ok": False, "error": "LITELLM_BASE_URL unset"})

    services.append(check_postgres())
    services.append(check_redis_ping())
    # 35B MoE / Petals 70B retired -- do not probe as brain dependencies.
    if (os.getenv("ALFA_PROBE_SPEED_TIER_35B") or "").strip() in ("1", "true", "yes"):
        services.append(check_speed_tier_backend())
    frontier = check_frontier_coordinator()
    services.append(frontier)

    try:
        from src.api.inference_pool_stats import check_rpc_shards

        rpc = check_rpc_shards(coordinator_reachable=bool(frontier.get("ok")))
        services.append({
            "name": "inference-shards",
            "ok": bool(rpc.get("ok")),
            "shards": rpc.get("shards"),
            "count": rpc.get("count"),
            "online": rpc.get("online"),
            "derived_from_coordinator": rpc.get("derived_from_coordinator"),
            "note": (
                "serving via coordinator (single-client rpc-server; direct TCP suppressed)"
                if rpc.get("derived_from_coordinator")
                else "TCP probe (coordinator down)"
            ),
        })
    except Exception as exc:  # noqa: BLE001
        services.append({"name": "inference-shards", "ok": False, "error": str(exc)[:300]})

    return {
        "services": services,
        "ts": int(time.time()),
    }


# ── Cluster host roll-up ─────────────────────────────────────
#
# Operator UI surfaces brain + inference hosts (not Petals workers).
# SSoT: docs/NODE_INVENTORY.md, docs/ADMIN_HEALTH_WEB_WORKFLOW.md,
# deploy/llamacpp-rpc/inference-shards.{env,gaming.env}, FOUR_HOST_FRONTIER_POOL.md.
#
# Production inference (Phase H): Qwen3.6-27B RPC pool only.
#   Coordinator hub:31360; always-on shards inference/:31356+31357, orchestrator/:31350, hub/:31353.
#   Opt-in: gaming-a/:31352, gaming-c/:31351, gaming-b/:31358, secondary/:31355, pool-opt-in/:31354.
# Retired: Petals / Llama-3.3-70B, Qwen 35B MoE speed tier, petals-gateway :8013.
#
# brain-api is derived self -- this process *is* alfa-ai-api. Do not HTTP
# GET 127.0.0.1:8000/health from async cluster_health: that blocks the
# event loop (https://fastapi.tiangolo.com/async/#path-operation-functions)
# so uvicorn cannot accept the loopback request
# (https://uvicorn.dev/concepts/asgi/). Compose HEALTHCHECK stays a
# separate process (https://docs.docker.com/reference/compose-file/services/#healthcheck).
# LiteLLM stays Compose DNS alfa-ai-litellm:4000
# (https://docs.docker.com/compose/how-tos/networking/).
#
# Overridable via env ALFA_AI_CLUSTER_HOSTS_JSON.

# Phase H inference hosts (SSoT: .cursor/plans/FOUR_HOST_FRONTIER_POOL.md).
_CLUSTER_HOSTS_DEFAULT: tuple[dict[str, Any], ...] = (
    {
        "key": "brain-111",
        "name": "hub (hub hub)",
        "lan_ip": "hub",
        "role": "Brain: API, LiteLLM :8413, inference coordinator :31360 + RPC shard :31353",
        "checks": [
            {"name": "brain-api", "derived": "self"},
            {"name": "litellm", "url": "http://alfa-ai-litellm:4000", "path": "/health/liveliness"},
            {"name": "litellm-public", "url": "http://hub", "path": "/health/liveliness"},
            {"name": "registry-mirror", "url": "http://hub", "path": "/v2/"},
            {"name": "rpc-shard-111", "derived": "coordinator-rpc", "rpc_host": "hub", "rpc_port": 31353},
        ],
    },
    {
        "key": "ai-148",
        "name": "ai-148 (inference)",
        "lan_ip": "orchestrator",
        "role": "RPC GPU shards :31356/:31357 (CPU RAG moved to rag)",
        "checks": [
            {"name": "rpc-shards-148", "derived": "coordinator-rpc", "rpc_host": "orchestrator", "rpc_port": 31356},
        ],
    },
    {
        "key": "rag-110",
        "name": "VM110 CPU RAG (rag)",
        "lan_ip": "orchestrator",
        "role": "CPU RAG production: embed :11435 + rerank :8360",
        "checks": [
            {"name": "embed-110", "url": "http://orchestrator", "path": "/api/tags"},
            {"name": "rerank-110", "url": "http://orchestrator", "path": "/health"},
        ],
    },
    {
        "key": "dockge-93",
        "name": "win11-dockge (orchestrator)",
        "lan_ip": "orchestrator",
        "role": "Always-on inference RPC shard :31350 (RTX 3060) + Dockge :5002 + cluster orchestrator",
        "checks": [
            {"name": "rpc-shard-93", "derived": "coordinator-rpc", "rpc_host": "orchestrator", "rpc_port": 31350},
            {"name": "dockge", "url": "http://orchestrator"},
        ],
    },
    {
        "key": "gaming-worker-b",
        "name": "gaming-worker-b QuantumBladeX (gaming-b)",
        "lan_ip": "orchestrator",
        "role": "Opt-in inference RPC shard :31358 (RTX 5070); WSL Docker",
        "checks": [
            {"name": "rpc-shard-249", "derived": "coordinator-rpc", "rpc_host": "orchestrator", "rpc_port": 31358},
        ],
    },
    {
        "key": "gaming-worker-c",
        "name": "gaming_worker_c (gaming-c)",
        "lan_ip": "orchestrator",
        "role": "Opt-in inference RPC shard :31351 (RTX 5070)",
        "checks": [
            {"name": "rpc-shard-59", "derived": "coordinator-rpc", "rpc_host": "orchestrator", "rpc_port": 31351},
        ],
    },
    {
        "key": "gaming-worker-a",
        "name": "gaming_worker_a (gaming-a)",
        "lan_ip": "orchestrator",
        "role": "Opt-in inference RPC shard :31352 (RTX 5060)",
        "checks": [
            {"name": "rpc-shard-219", "derived": "coordinator-rpc", "rpc_host": "orchestrator", "rpc_port": 31352},
        ],
    },
    {
        "key": "shard-248",
        "name": "gpu-248 inference shard (secondary)",
        "lan_ip": "orchestrator",
        "role": "Opt-in 27B RPC shard :31355 (GTX 1070 Pascal sm_61; iGPU desktop)",
        "checks": [
            {"name": "rpc-shard-248", "derived": "coordinator-rpc", "rpc_host": "orchestrator", "rpc_port": 31355},
        ],
    },
    {
        "key": "shard-100",
        "name": "VM100 inference shard (pool-opt-in)",
        "lan_ip": "orchestrator",
        "role": "Opt-in 27B/72B RPC shard :31354 (GTX 1660 Super); RAG on rag CPU",
        "checks": [
            {"name": "rpc-shard-100", "derived": "coordinator-rpc", "rpc_host": "orchestrator", "rpc_port": 31354},
        ],
    },
    {
        "key": "apps-105",
        "name": "web-sites (apps)",
        "lan_ip": "apps",
        "role": "Apps: Postgres, Redis, websites + bots (not a inference GPU shard)",
        "checks": [
            {"name": "dockge-105", "url": "http://apps", "path": "/"},
        ],
    },
)


def _load_cluster_hosts() -> tuple[dict[str, Any], ...]:
    """Return host inventory, optionally from ALFA_AI_CLUSTER_HOSTS_JSON env var."""
    override = (os.getenv("ALFA_AI_CLUSTER_HOSTS_JSON") or "").strip()
    if not override:
        return _CLUSTER_HOSTS_DEFAULT
    try:
        parsed = json.loads(override)
        if isinstance(parsed, list):
            return tuple(h for h in parsed if isinstance(h, dict))
    except json.JSONDecodeError:
        pass
    return _CLUSTER_HOSTS_DEFAULT


def build_cluster_hosts_report() -> list[dict[str, Any]]:
    """Per-host reachability roll-up for operator UI (inference + brain + apps)."""
    out: list[dict[str, Any]] = []
    _coordinator_ok: bool | None = None
    _active_shards: set[tuple[str, int]] | None = None

    def _active() -> set[tuple[str, int]]:
        nonlocal _active_shards
        if _active_shards is None:
            try:
                from src.api.inference_shards import parse_inference_shard_endpoints

                _active_shards = set(parse_inference_shard_endpoints())
            except Exception:
                _active_shards = set()
        return _active_shards

    for host in _load_cluster_hosts():
        checks = []
        any_ok = False
        for c in host.get("checks", []):
            check_name = c.get("name") or "check"
            if c.get("derived") == "self":
                checks.append({
                    "name": check_name,
                    "ok": True,
                    "derived": True,
                    "note": "this process is serving the health report",
                })
                any_ok = True
                continue
            if c.get("derived") == "coordinator-rpc":
                if _coordinator_ok is None:
                    _coordinator_ok = bool(check_frontier_coordinator().get("ok"))
                rpc_host = (c.get("rpc_host") or "").strip()
                rpc_port = c.get("rpc_port")
                in_active = True
                if rpc_host and rpc_port is not None:
                    try:
                        in_active = (rpc_host, int(rpc_port)) in _active()
                    except (TypeError, ValueError):
                        in_active = False
                if _coordinator_ok and in_active:
                    checks.append({
                        "name": check_name,
                        "ok": True,
                        "derived": True,
                        "note": "serving via coordinator (single-client rpc-server; direct probe suppressed)",
                    })
                    any_ok = True
                elif _coordinator_ok and not in_active:
                    # ok False so the card stays red (expected for gaming-c/gaming-b/gaming-a
                    # when they are not in the live pool). Do not set any_ok.
                    checks.append({
                        "name": check_name,
                        "ok": False,
                        "skipped": True,
                        "derived": True,
                        "note": "not in inference-shards.active.env this start (opt-in offline)",
                    })
                else:
                    checks.append({
                        "name": check_name,
                        "ok": False,
                        "derived": True,
                        "note": "coordinator down -- shards cannot be confirmed",
                    })
                continue
            res = _http_check(
                check_name,
                c.get("url") or "",
                path=c.get("path") or "",
                timeout=3.0,
            )
            if res.get("ok"):
                any_ok = True
            checks.append(res)
        # Empty checks must not paint the host red (was always-red for apps).
        reachable = any_ok if checks else True
        out.append({
            "key": host.get("key"),
            "name": host.get("name"),
            "lan_ip": host.get("lan_ip"),
            "role": host.get("role"),
            "reachable": reachable,
            "checks": checks,
        })
    return out


def _check_ollama_endpoint(name: str, base_url: str, *, aliases: list[str] | None = None) -> dict[str, Any]:
    """Probe an Ollama host and return model tags + latency."""
    res = _http_check(name, base_url, path="/api/tags", timeout=6.0)
    if not res.get("ok"):
        if aliases:
            res["aliases"] = aliases
        return res
    try:
        with httpx.Client(timeout=6.0) as client:
            resp = client.get(f"{base_url.rstrip('/')}/api/tags")
            if resp.status_code == 200:
                names = [
                    m.get("name")
                    for m in resp.json().get("models", [])
                    if isinstance(m, dict) and m.get("name")
                ]
                if names:
                    res["models"] = names
    except Exception as exc:  # noqa: BLE001
        res["error"] = str(exc)[:200]
    if aliases:
        res["aliases"] = aliases
    res["engine"] = "ollama"
    return res


def _check_litellm_router() -> dict[str, Any]:
    """LiteLLM model list + liveliness from the brain stack."""
    litellm_base = (os.getenv("LITELLM_BASE_URL") or "").strip()
    master = (os.getenv("LITELLM_MASTER_KEY") or os.getenv("LITELLM_API_KEY") or "").strip()
    if not litellm_base:
        return {"name": "litellm-router", "ok": False, "error": "LITELLM_BASE_URL unset", "engine": "litellm"}
    headers = {"Authorization": f"Bearer {master}"} if master else None
    live = _http_check("litellm-liveliness", litellm_base, path="/health/liveliness", headers=headers)
    live["engine"] = "litellm"
    if not live.get("ok") and master:
        live = _http_check("litellm-health", litellm_base, path="/health", headers=headers)
        live["engine"] = "litellm"
    if live.get("ok"):
        try:
            with httpx.Client(timeout=8.0) as client:
                resp = client.get(
                    f"{litellm_base.rstrip('/')}/v1/models",
                    headers=headers,
                )
                if resp.status_code == 200:
                    ids = sorted({
                        m.get("id")
                        for m in resp.json().get("data", [])
                        if isinstance(m, dict) and m.get("id")
                    })
                    if ids:
                        live["models"] = ids
        except Exception:
            pass
    return live


def build_inference_stack_report() -> dict[str, Any]:
    """Live llama.cpp / LiteLLM / RAG endpoints for admin UI (inference Phase H)."""
    endpoints: list[dict[str, Any]] = []

    endpoints.append(_check_litellm_router())
    if (os.getenv("ALFA_PROBE_SPEED_TIER_35B") or "").strip() in ("1", "true", "yes"):
        endpoints.append(check_speed_tier_backend())
    frontier = check_frontier_coordinator()
    endpoints.append(frontier)
    coordinator_ok = bool(frontier.get("ok"))

    # Optional Ollama on orchestrator -- not production chat (35B MoE retired).
    ollama_93 = (os.getenv("OLLAMA_FLEET_93_URL") or "").strip()
    if ollama_93 and (os.getenv("ALFA_PROBE_OLLAMA_93") or "").strip() in ("1", "true", "yes"):
        endpoints.append(
            _check_ollama_endpoint("ollama-93", ollama_93, aliases=["optional-local"])
        )

    embed_url = (os.getenv("EMBED_BASE_URL") or "http://orchestrator").strip()
    if embed_url:
        embed_name = "embed-110" if "orchestrator" in embed_url else (
            "embed-148" if "orchestrator" in embed_url else "embed"
        )
        endpoints.append(
            _check_ollama_endpoint(
                embed_name, embed_url, aliases=["embed", "qwen3-embedding:4b"]
            )
        )

    rerank_url = (os.getenv("RERANK_BASE_URL") or "http://orchestrator").strip()
    if rerank_url:
        rerank_name = "rerank-110" if "orchestrator" in rerank_url else (
            "rerank-148" if "orchestrator" in rerank_url else "rerank"
        )
        rerank_res = _http_check(rerank_name, rerank_url, path="/health", timeout=6.0)
        rerank_res["aliases"] = ["rerank", "qwen3-reranker-0.6b"]
        rerank_res["engine"] = "llama-cpp-rerank"
        endpoints.append(rerank_res)

    # Catalog = core + gaming; status derived from coordinator when healthy (B42).
    try:
        from src.api.inference_shards import parse_inference_catalog_endpoints

        catalog = parse_inference_catalog_endpoints()
    except Exception:
        catalog = [
            ("orchestrator", 31356, "core"),
            ("orchestrator", 31357, "core"),
            ("orchestrator", 31350, "core"),
            ("hub", 31353, "core"),
        ]

    active: set[tuple[str, int]] = set()
    try:
        from src.api.inference_shards import parse_inference_shard_endpoints

        active = set(parse_inference_shard_endpoints())
    except Exception:
        active = set()

    for host, port, label in catalog:
        hostport = f"{host}:{port}"
        name = f"rpc-{label}" if label and label != "core" else f"rpc-{host.split('.')[-1]}-{port}"
        if label in ("core",) or not label:
            # Stable names for always-on shards
            name_map = {
                (31356, "orchestrator"): "rpc-148-3060",
                (31357, "orchestrator"): "rpc-148-5060",
                (31350, "orchestrator"): "rpc-93-3060",
                (31353, "hub"): "rpc-111-3050",
            }
            name = name_map.get((port, host), f"rpc-{host.split('.')[-1]}-{port}")
        else:
            name = f"rpc-{label}"

        in_active = (host, port) in active if active else label == "core"
        if coordinator_ok and in_active:
            res = {
                "name": name,
                "ok": True,
                "url": hostport,
                "source": "coordinator",
                "membership": "active" if in_active else "catalog",
                "note": "serving via coordinator (single-client rpc-server; direct probe suppressed)",
            }
        elif coordinator_ok and not in_active:
            res = {
                "name": name,
                "ok": True,
                "skipped": True,
                "url": hostport,
                "source": "catalog",
                "membership": "opt-in-offline",
                "note": "in gaming catalog but not in active membership this start",
            }
        else:
            res = _tcp_check(name, hostport, timeout=5.0)
            res["source"] = "tcp-probe"
            res["membership"] = "active" if in_active else "catalog"
        res["engine"] = "llama-cpp-rpc"
        res["aliases"] = ["frontier-code"]
        endpoints.append(res)

    online = sum(1 for e in endpoints if e.get("ok") and not e.get("skipped"))
    return {
        "endpoints": endpoints,
        "summary": {
            "total": len(endpoints),
            "online": online,
            "offline": len(endpoints) - online,
        },
        "ts": int(time.time()),
    }
