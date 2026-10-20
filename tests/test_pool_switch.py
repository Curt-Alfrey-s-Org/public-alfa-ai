"""Tests for pool switch API and pool target detection."""

from __future__ import annotations

import json
from unittest.mock import MagicMock, patch

import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def pool_switch_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_POOL_SWITCH_BEARER_TOKEN", "change-me")
    monkeypatch.setenv("ALFA_POOL_SWITCHD_URL", "http://switchd.test")
    monkeypatch.setenv("REDIS_URL", "redis://localhost:6379/0")
    monkeypatch.setenv("DATABASE_URL", "sqlite:///:memory:")
    monkeypatch.setenv("ALFA_AI_JWT_SECRET", "change-me")


def test_detect_active_inference(monkeypatch: pytest.MonkeyPatch) -> None:
    from src.api.pool_targets import detect_active_pool

    monkeypatch.setenv("ALFA_INFERENCE_MODE", "inference")
    assert detect_active_pool() == "inference"


def test_detect_active_pool35_sentinel(monkeypatch: pytest.MonkeyPatch) -> None:
    from src.api.pool_targets import detect_active_pool

    monkeypatch.setenv("ALFA_INFERENCE_MODE", "default")
    monkeypatch.setenv("LLAMACPP_CODE27_URL", "http://127.0.0.1:31399/v1")
    monkeypatch.setenv("LLAMACPP_35B_URL", "http://127.0.0.1:31360/v1")
    assert detect_active_pool() == "pool35"


def test_chat_alias_pool_mapping() -> None:
    from src.api.pool_targets import chat_alias_pool

    assert chat_alias_pool("frontier-code") == "inference"
    assert chat_alias_pool("frontier") == "inference"
    assert chat_alias_pool("fast") == "inference"


def test_normalize_status_idle() -> None:
    from src.api.redis_pool_switch import normalize_status

    out = normalize_status(None, active_pool="inference")
    assert out["switching"] is False
    assert out["phase"] == "idle"
    assert out["active_pool"] == "inference"


def test_compute_estimated_pct_loading() -> None:
    from src.api.redis_pool_switch import compute_estimated_pct

    pct, labeled = compute_estimated_pct(phase="loading_model", elapsed_sec=105, target_pool="inference")
    assert labeled is True
    assert 40 <= pct <= 95


def test_inference_frontier_active_when_coordinator_ok_shards_unreachable(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Picker must not TCP-probe shard RPC while coordinator serves (B42 false negatives)."""
    from src.api import inference_shards as p27
    from src.api import worker_monitoring as wm
    from src.api.llm_config import chat_alias_is_active

    monkeypatch.setenv("ALFA_INFERENCE_MODE", "inference")
    monkeypatch.setattr(wm, "check_frontier_coordinator", lambda: {"ok": True})
    monkeypatch.setattr(p27, "check_inference_shards", lambda **kw: {"ok": False, "shards": []})

    assert chat_alias_is_active("frontier-code") is True


def test_chat_models_for_ui_includes_pool(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from src.api import inference_shards as p27
    from src.api import worker_monitoring as wm
    from src.api.llm_config import chat_models_for_ui

    monkeypatch.setenv("ALFA_INFERENCE_MODE", "inference")
    monkeypatch.setattr(wm, "check_frontier_coordinator", lambda: {"ok": True})
    monkeypatch.setattr(p27, "check_inference_shards", lambda **kw: {"ok": True, "shards": []})

    by_id = {row["id"]: row for row in chat_models_for_ui()}
    assert by_id["frontier-code"]["pool"] == "inference"
    assert by_id["frontier"]["pool"] == "inference"
    assert by_id["fast"]["pool"] == "inference"


def test_pool_switch_stepup_wrong_password(
    pool_switch_env: None,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from src.api.app import app
    from src.api.deps import get_current_user, get_security_store, get_user_store
    from src.api.models.user import UserRecord

    admin = UserRecord(
        id="admin-1",
        email="operator@example.com",
        username="admin",
        password_hash="change-me",
        role="admin",
        is_2fa_enabled=False,
        is_active=True,
        totp_secret=None,
        created_at="2026-01-01T00:00:00Z",
    )

    store = MagicMock()
    store.get_by_id.return_value = admin
    sec = MagicMock()

    app.dependency_overrides[get_current_user] = lambda: admin
    app.dependency_overrides[get_user_store] = lambda: store
    app.dependency_overrides[get_security_store] = lambda: sec

    with patch("src.api.routers.pool_switch._verify_password", return_value=False):
        client = TestClient(app)
        resp = client.post(
            "/alfa-ai/api/admin/pool/switch",
            json={"target": "pool35", "password": "wrong"},
            headers={"Authorization": "Bearer fake"},
        )
        assert resp.status_code == 401
        sec.record_event.assert_called()

    app.dependency_overrides.clear()


def test_pool_switch_status_shape(
    pool_switch_env: None,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from src.api.app import app
    from src.api.deps import get_current_user
    from src.api.models.user import UserRecord

    admin = UserRecord(
        id="admin-1",
        email="operator@example.com",
        username="admin",
        password_hash="x",
        role="admin",
        is_2fa_enabled=False,
        is_active=True,
        totp_secret=None,
        created_at="2026-01-01T00:00:00Z",
    )
    app.dependency_overrides[get_current_user] = lambda: admin

    raw = {
        "switching": True,
        "target_pool": "pool35",
        "from_pool": "inference",
        "phase": "loading_model",
        "elapsed_sec": 60,
    }
    with patch("src.api.routers.pool_switch.get_pool_switch_status", return_value=raw):
        with patch("src.api.routers.pool_switch.detect_active_pool", return_value="inference"):
            client = TestClient(app)
            resp = client.get(
                "/alfa-ai/api/admin/pool/status",
                headers={"Authorization": "Bearer fake"},
            )
            assert resp.status_code == 200
            data = resp.json()
            assert data["switching"] is True
            assert data["phase"] == "loading_model"
            assert "estimated_pct" in data

    app.dependency_overrides.clear()


def test_pool35_mode_compat_aliases_still_need_frontier(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """35B MoE retired: fast/chat map to inference backends even in default mode."""
    from src.api import worker_monitoring as wm
    from src.api.llm_config import chat_alias_is_active

    monkeypatch.setenv("ALFA_INFERENCE_MODE", "default")
    monkeypatch.setenv("LLAMACPP_CODE27_URL", "http://127.0.0.1:31399/v1")
    monkeypatch.setenv("LLAMACPP_35B_URL", "http://127.0.0.1:31360/v1")
    monkeypatch.setattr(wm, "check_frontier_coordinator", lambda: {"ok": False})
    monkeypatch.setattr(wm, "check_speed_tier_backend", lambda: {"ok": True})

    assert chat_alias_is_active("frontier-code") is False
    assert chat_alias_is_active("fast") is False
