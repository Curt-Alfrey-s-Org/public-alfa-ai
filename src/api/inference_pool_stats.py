"""Inference pool stats for admin UI (context window, shards, last probe)."""

from __future__ import annotations

import json
import logging
import os
import time
from pathlib import Path
from typing import Any

import httpx
import redis
from redis.exceptions import RedisError

from src.api.pool_targets import inference, POOL35, detect_active_pool
from src.api.inference_shards import check_inference_shards, parse_inference_shard_endpoints
from src.api.worker_monitoring import _strip_v1_suffix

logger = logging.getLogger(__name__)

_LAST_PROBE_KEY = "alfaai:inference:last_probe"
_LAST_PROBE_TTL_SEC = 7 * 24 * 3600


def _repo_llamacpp_dir() -> Path:
    for candidate in (
        Path("/app/deploy/llamacpp-rpc"),
        Path(__file__).resolve().parents[2] / "deploy" / "llamacpp-rpc",
    ):
        if candidate.is_dir():
            return candidate
    return Path(__file__).resolve().parents[2] / "deploy" / "llamacpp-rpc"


def _shards_file_for_pool(pool: str | None) -> Path:
    name = "pool35-shards.env" if pool == POOL35 else "inference-shards.env"
    return _repo_llamacpp_dir() / name


def parse_rpc_shard_endpoints(pool: str | None = None) -> list[tuple[str, int]]:
    """Parse inference or pool35 shard list (same format)."""
    if pool == POOL35:
        path = _shards_file_for_pool(POOL35)
        if path.is_file():
            prev = os.environ.get("ALFA_inference_SHARDS_FILE")
            os.environ["ALFA_inference_SHARDS_FILE"] = str(path)
            try:
                return parse_inference_shard_endpoints()
            finally:
                if prev is None:
                    os.environ.pop("ALFA_inference_SHARDS_FILE", None)
                else:
                    os.environ["ALFA_inference_SHARDS_FILE"] = prev
    return parse_inference_shard_endpoints()


def check_rpc_shards(
    pool: str | None = None,
    *,
    timeout_sec: float = 3.0,
    coordinator_reachable: bool | None = None,
) -> dict[str, Any]:
    """Report GPU shard status for the active pool.

    The llama.cpp ``rpc-server`` is single-client: it accepts one connection
    (the coordinator), then blocks in ``rpc_serve_client()`` until that client
    disconnects. While the coordinator holds a shard, an external TCP probe
    either races the accept backlog or times out, so a direct probe is a
    false-negative (see docs/GREV27_27B_OPERATOR.md guard 4 and
    .cursor/rules/no-piecemeal-cluster-scripts.mdc, B42).

    Therefore:
      * ``coordinator_reachable is True``  -> shards are serving by definition
        (the coordinator connected to every backend at load and its decode
        self-test passed). Report them ``ok`` without probing.
      * ``coordinator_reachable is False`` -> no client is holding the shards,
        so a direct TCP probe is meaningful for diagnosis; probe them.
      * ``coordinator_reachable is None``  -> legacy: probe directly.
    """
    endpoints = parse_rpc_shard_endpoints(pool)
    shards: list[dict[str, Any]] = []
    all_ok = True

    if coordinator_reachable is True:
        for host, port in endpoints:
            shards.append({
                "host": host,
                "port": port,
                "ok": True,
                "source": "coordinator",
                "note": "serving via coordinator (single-client rpc-server; direct probe suppressed)",
            })
    else:
        from src.api.inference_shards import _tcp_reachable

        for host, port in endpoints:
            ok = _tcp_reachable(host, port, timeout_sec=timeout_sec)
            shards.append({"host": host, "port": port, "ok": ok, "source": "tcp-probe"})
            if not ok:
                all_ok = False

    pool_label = pool or inference
    return {
        "pool": pool_label,
        "ok": all_ok,
        "shards": shards,
        "count": len(shards),
        "online": sum(1 for s in shards if s.get("ok")),
        "derived_from_coordinator": coordinator_reachable is True,
    }


def _coordinator_base_url(pool: str | None) -> str:
    if pool == POOL35:
        raw = (os.getenv("LLAMACPP_35B_URL") or "").strip()
        if not raw or ":11434" in raw or "ollama" in raw.lower():
            return ""
        return _strip_v1_suffix(raw)
    raw = (os.getenv("LLAMACPP_CODE27_URL") or "http://127.0.0.1:31360/v1").strip()
    return _strip_v1_suffix(raw)


def _llama_auth_headers() -> dict[str, str] | None:
    api_key = (os.getenv("LLAMA_API_KEY") or "change-me").strip()
    return {"Authorization": f"Bearer {api_key}"} if api_key else None


def fetch_llamacpp_coordinator_stats(base_url: str) -> dict[str, Any]:
    """
    Probe llama-server /health, /props, /v1/models.
    Official: https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md
    """
    if not base_url:
        return {"reachable": False, "error": "coordinator URL unset or Ollama backend"}
    headers = _llama_auth_headers()
    out: dict[str, Any] = {"url": base_url, "reachable": False}
    try:
        with httpx.Client(timeout=8.0) as client:
            health = client.get(f"{base_url}/health", headers=headers)
            if health.status_code == 200:
                body = health.json()
                if body.get("status") == "ok":
                    out["reachable"] = True
                    out["health_latency_ms"] = round(health.elapsed.total_seconds() * 1000, 1)
            elif health.status_code == 503:
                out["loading"] = True
                try:
                    err = health.json().get("error", {})
                    if err.get("message") == "Loading model":
                        out["detail"] = "Loading model"
                except Exception:
                    out["detail"] = "Loading model"

            if out.get("reachable") or out.get("loading"):
                try:
                    props_resp = client.get(f"{base_url}/props", headers=headers)
                    if props_resp.status_code == 200:
                        props = props_resp.json()
                        gen = props.get("default_generation_settings") or {}
                        out["context_window"] = gen.get("n_ctx")
                        out["total_slots"] = props.get("total_slots")
                        out["model_path"] = props.get("model_path")
                        out["is_sleeping"] = props.get("is_sleeping")
                except Exception:
                    logger.debug("coordinator /props fetch failed", exc_info=True)

                try:
                    models_resp = client.get(f"{base_url}/v1/models", headers=headers)
                    if models_resp.status_code == 200:
                        data = models_resp.json().get("data") or []
                        if data and isinstance(data[0], dict):
                            m0 = data[0]
                            out["model_id"] = m0.get("id")
                            meta = m0.get("meta") or {}
                            if meta.get("n_ctx_train"):
                                out["context_train"] = meta.get("n_ctx_train")
                            if meta.get("n_params"):
                                out["param_count"] = meta.get("n_params")
                except Exception:
                    logger.debug("coordinator /v1/models fetch failed", exc_info=True)

            if not out.get("reachable") and not out.get("loading"):
                out["error"] = health.text[:300] if health.text else f"HTTP {health.status_code}"
    except Exception as exc:  # noqa: BLE001
        out["error"] = str(exc)[:300]
    return out


def _redis() -> redis.Redis:
    url = os.getenv("REDIS_URL", "redis://localhost:6379/0")
    return redis.Redis.from_url(url, decode_responses=True)


def record_inference_probe(
    *,
    source: str,
    model: str,
    completion_tokens: int,
    elapsed_sec: float,
    pool: str | None = None,
    decode_tok_per_sec: float | None = None,
    ttft_sec: float | None = None,
) -> dict[str, Any]:
    """Store last warm ping / benchmark for admin UI (Redis TTL 7d)."""
    wall_tok_s = completion_tokens / elapsed_sec if elapsed_sec > 0 and completion_tokens else 0.0
    decode = decode_tok_per_sec
    if decode is None:
        decode = wall_tok_s
    payload: dict[str, Any] = {
        "source": source,
        "model": model,
        "pool": pool or detect_active_pool(),
        "completion_tokens": completion_tokens,
        "elapsed_sec": round(elapsed_sec, 3),
        "tok_per_sec": round(decode, 2),
        "decode_tok_per_sec": round(decode, 2),
        "wall_tok_per_sec": round(wall_tok_s, 2),
        "ts": int(time.time()),
    }
    if ttft_sec is not None:
        payload["ttft_sec"] = round(ttft_sec, 3)
    try:
        r = _redis()
        r.setex(_LAST_PROBE_KEY, _LAST_PROBE_TTL_SEC, json.dumps(payload))
    except RedisError:
        logger.exception("record_inference_probe: redis write failed")
    return payload


def load_last_inference_probe() -> dict[str, Any] | None:
    try:
        r = _redis()
        raw = r.get(_LAST_PROBE_KEY)
        if not raw:
            return None
        data = json.loads(raw)
        return data if isinstance(data, dict) else None
    except (RedisError, json.JSONDecodeError):
        logger.exception("load_last_inference_probe failed")
        return None


def build_inference_pool_stats() -> dict[str, Any]:
    """Aggregate pool config, shard count, context window, and last throughput probe."""
    from src.api.llm_config import inference_mode

    active_pool = detect_active_pool()
    pool_for_shards = active_pool or inference
    # Probe the coordinator first, then derive shard status from it: the
    # single-client rpc-server cannot be probed directly while the coordinator
    # holds it (B42). See check_rpc_shards docstring.
    coordinator = fetch_llamacpp_coordinator_stats(_coordinator_base_url(active_pool))
    shards = check_rpc_shards(
        pool_for_shards,
        coordinator_reachable=bool(coordinator.get("reachable")),
    )

    ctx_env = (os.getenv("CTX_SIZE") or os.getenv("LLAMA_ARG_CTX_SIZE") or "").strip()
    ctx_env_int: int | None = None
    if ctx_env.isdigit():
        ctx_env_int = int(ctx_env)

    return {
        "ts": int(time.time()),
        "active_pool": active_pool,
        "inference_mode": inference_mode(),
        "litellm_config": (os.getenv("LITELLM_CONFIG") or "litellm_config.yaml").strip(),
        "configured_ctx_size": ctx_env_int,
        "coordinator": coordinator,
        "shards": shards,
        "last_probe": load_last_inference_probe(),
    }
