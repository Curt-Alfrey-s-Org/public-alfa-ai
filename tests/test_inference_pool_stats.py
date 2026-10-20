"""Tests for inference pool stats aggregation."""

from __future__ import annotations

from unittest.mock import MagicMock, patch

from src.api.inference_pool_stats import (
    build_inference_pool_stats,
    fetch_llamacpp_coordinator_stats,
    record_inference_probe,
)


def test_fetch_llamacpp_coordinator_stats_empty_url():
    out = fetch_llamacpp_coordinator_stats("")
    assert out["reachable"] is False
    assert "error" in out


def test_fetch_llamacpp_coordinator_stats_parses_props_and_models():
    health_resp = MagicMock()
    health_resp.status_code = 200
    health_resp.json.return_value = {"status": "ok"}
    health_resp.elapsed.total_seconds.return_value = 0.05
    health_resp.text = ""

    props_resp = MagicMock()
    props_resp.status_code = 200
    props_resp.json.return_value = {
        "default_generation_settings": {"n_ctx": 4096},
        "total_slots": 2,
        "model_path": "/models/test.gguf",
        "is_sleeping": False,
    }

    models_resp = MagicMock()
    models_resp.status_code = 200
    models_resp.json.return_value = {
        "data": [
            {
                "id": "qwen3.6-27b",
                "meta": {"n_ctx_train": 131072, "n_params": 27000000000},
            }
        ]
    }

    client = MagicMock()
    client.get.side_effect = [health_resp, props_resp, models_resp]
    client.__enter__ = MagicMock(return_value=client)
    client.__exit__ = MagicMock(return_value=False)

    with patch("src.api.inference_pool_stats.httpx.Client", return_value=client):
        out = fetch_llamacpp_coordinator_stats("http://127.0.0.1:31360")

    assert out["reachable"] is True
    assert out["context_window"] == 4096
    assert out["total_slots"] == 2
    assert out["context_train"] == 131072
    assert out["model_id"] == "qwen3.6-27b"


def test_build_inference_pool_stats_includes_shards_and_pool():
    coord = {
        "url": "http://127.0.0.1:31360",
        "reachable": True,
        "context_window": 4096,
        "total_slots": 1,
    }
    shards = {"pool": "inference", "ok": True, "count": 2, "online": 2, "shards": []}
    with patch("src.api.inference_pool_stats.detect_active_pool", return_value="inference"), patch(
        "src.api.inference_pool_stats.check_rpc_shards", return_value=shards
    ), patch(
        "src.api.inference_pool_stats.fetch_llamacpp_coordinator_stats", return_value=coord
    ), patch(
        "src.api.inference_pool_stats.load_last_inference_probe", return_value=None
    ), patch.dict(
        "os.environ",
        {"LITELLM_CONFIG": "litellm_config.inference.yaml", "ALFA_INFERENCE_MODE": "inference"},
        clear=False,
    ):
        out = build_inference_pool_stats()

    assert out["active_pool"] == "inference"
    assert out["litellm_config"] == "litellm_config.inference.yaml"
    assert out["coordinator"]["context_window"] == 4096
    assert out["shards"]["online"] == 2


def test_record_inference_probe_stores_decode_tok_per_sec():
    mock_redis = MagicMock()
    with patch("src.api.inference_pool_stats._redis", return_value=mock_redis), patch(
        "src.api.inference_pool_stats.detect_active_pool", return_value="inference"
    ):
        payload = record_inference_probe(
            source="test",
            model="qwen3.6-27b",
            completion_tokens=64,
            elapsed_sec=10.0,
            pool="inference",
            decode_tok_per_sec=8.5,
            ttft_sec=2.0,
        )
    assert payload["tok_per_sec"] == 8.5
    assert payload["decode_tok_per_sec"] == 8.5
    assert payload["wall_tok_per_sec"] == 6.4
    assert payload["ttft_sec"] == 2.0
    mock_redis.setex.assert_called_once()


def test_record_inference_probe_stores_wall_when_no_decode():
    mock_redis = MagicMock()
    with patch("src.api.inference_pool_stats._redis", return_value=mock_redis), patch(
        "src.api.inference_pool_stats.detect_active_pool", return_value="inference"
    ):
        payload = record_inference_probe(
            source="test",
            model="qwen3.6-27b",
            completion_tokens=64,
            elapsed_sec=0.2,
            pool="inference",
        )
    assert payload["tok_per_sec"] == 320.0
    mock_redis.setex.assert_called_once()
