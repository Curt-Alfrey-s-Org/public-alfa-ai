"""aria2 RPC secret must come from the environment (no hardcoded default)."""

from __future__ import annotations

import asyncio
from typing import Any

import pytest
from fastapi import HTTPException

from src.api.routers import admin as admin_module


def test_aria2_rpc_refuses_without_secret(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(admin_module, "_ARIA2_RPC_KEY", "")
    with pytest.raises(HTTPException) as exc_info:
        asyncio.run(admin_module._aria2_rpc("aria2.getVersion"))
    assert exc_info.value.status_code == 503
    assert "ARIA2_RPC_KEY" in str(exc_info.value.detail)


def test_download_status_reports_missing_secret(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(admin_module, "_ARIA2_RPC_KEY", "")
    result = asyncio.run(admin_module.download_status(_user=None))
    assert result["aria2_reachable"] is False
    assert "ARIA2_RPC_KEY" in result["error"]
    assert result["active"] == [] and result["waiting"] == []


def test_aria2_rpc_sends_env_secret(monkeypatch: pytest.MonkeyPatch) -> None:
    sent: dict[str, Any] = {}

    class _Resp:
        def raise_for_status(self) -> None:
            return None

        def json(self) -> dict:
            return {"result": {"version": "1.37.0"}}

    class _Client:
        def __init__(self, *args: Any, **kwargs: Any) -> None:
            pass

        async def __aenter__(self) -> "_Client":
            return self

        async def __aexit__(self, *exc: Any) -> None:
            return None

        async def post(self, url: str, json: dict) -> _Resp:
            sent["url"] = url
            sent["payload"] = json
            return _Resp()

    monkeypatch.setattr(admin_module, "_ARIA2_RPC_KEY", "test-only-secret")
    monkeypatch.setattr(admin_module.httpx, "AsyncClient", _Client)
    result = asyncio.run(admin_module._aria2_rpc("aria2.getVersion"))
    assert result == {"version": "1.37.0"}
    assert sent["payload"]["params"][0] == "token:test-only-secret"


def test_no_hardcoded_default_secret() -> None:
    import inspect
    import re

    source = inspect.getsource(admin_module)
    # Any non-empty literal default for ARIA2_RPC_KEY is a committed secret.
    assert not re.search(r'getenv\(\s*"ARIA2_RPC_KEY"\s*,\s*"[^"]+"', source)
