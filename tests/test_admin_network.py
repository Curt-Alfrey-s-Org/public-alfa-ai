"""Tests for admin /LAN network restrictions."""

from __future__ import annotations

import pytest
from fastapi import HTTPException
from starlette.requests import Request

from src.api.admin_network import (
    assert_admin_client_allowed,
    client_ip_allowed,
    get_client_ip,
    get_proxy_resolved_client_ip,
    load_admin_allowed_networks,
)


def _request(headers: dict[str, str] | None = None, client_host: str = "203.0.113.50") -> Request:
    scope = {
        "type": "http",
        "method": "GET",
        "path": "/",
        "headers": [(k.lower().encode(), v.encode()) for k, v in (headers or {}).items()],
        "client": (client_host, 12345),
    }
    return Request(scope)


def test_get_client_ip_prefers_x_forwarded_for() -> None:
    req = _request({"X-Forwarded-For": "100.64.0.1, orchestrator"})
    assert get_client_ip(req) == "100.64.0.1"


def test_proxy_resolved_ip_ignores_client_supplied_x_forwarded_for() -> None:
    """Security keys use Uvicorn's resolved client, not the raw first XFF value (finding 15)."""
    req = _request({"X-Forwarded-For": "6.6.6.6, 100.64.0.1"}, client_host="203.0.113.50")
    assert get_proxy_resolved_client_ip(req) == "203.0.113.50"


def test_proxy_resolved_ip_none_without_client() -> None:
    scope = {"type": "http", "method": "GET", "path": "/", "headers": [], "client": None}
    assert get_proxy_resolved_client_ip(Request(scope)) is None


def test_proxy_resolved_ip_uses_uvicorn_trusted_proxy_resolution() -> None:
    """Behind a trusted proxy, Uvicorn picks the right-most untrusted XFF hop; spoofed
    left-most entries are ignored. Untrusted peers cannot inject XFF at all."""
    import asyncio

    from uvicorn.middleware.proxy_headers import ProxyHeadersMiddleware

    seen: dict[str, str | None] = {}

    async def app(scope, receive, send):  # type: ignore[no-untyped-def]
        seen["ip"] = get_proxy_resolved_client_ip(Request(scope))

    mw = ProxyHeadersMiddleware(app, trusted_hosts="127.0.0.1,10.0.0.0/8,172.16.0.0/12")

    def run(peer: str, xff: str) -> str | None:
        scope = {
            "type": "http",
            "method": "POST",
            "path": "/",
            "headers": [(b"x-forwarded-for", xff.encode())],
            "client": (peer, 5000),
        }
        asyncio.run(mw(scope, None, None))  # type: ignore[arg-type]
        return seen["ip"]

    assert run("apps", "6.6.6.6, 203.0.113.9") == "203.0.113.9"
    assert run("apps", "7.7.7.7, 203.0.113.9, apps") == "203.0.113.9"
    assert run("198.51.100.20", "6.6.6.6") == "198.51.100.20"


def test__ip_allowed(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_ADMIN_ALLOWED_CIDRS", "100.64.0.0/10")
    nets = load_admin_allowed_networks()
    assert client_ip_allowed("100.64.0.1", nets) is True
    assert client_ip_allowed("203.0.113.50", nets) is False


def test_empty_cidr_allows_all(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("ALFA_AI_ADMIN_ALLOWED_CIDRS", raising=False)
    assert load_admin_allowed_networks() == ()
    assert client_ip_allowed("203.0.113.50", ()) is True


def test_assert_admin_blocks_public_ip_api(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_ADMIN_ALLOWED_CIDRS", "100.64.0.0/10")
    req = _request(client_host="203.0.113.50")
    with pytest.raises(HTTPException) as exc:
        assert_admin_client_allowed(req, role="admin", public_context="api")
    assert exc.value.status_code == 403
    assert exc.value.detail == "Access denied."
    assert "" not in exc.value.detail


def test_assert_admin_blocks_public_ip_login(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_ADMIN_ALLOWED_CIDRS", "100.64.0.0/10")
    req = _request(client_host="203.0.113.50")
    with pytest.raises(HTTPException) as exc:
        assert_admin_client_allowed(req, role="admin", public_context="login")
    assert exc.value.status_code == 401
    assert exc.value.detail == "Invalid email, username, or password"


def test_assert_admin_allows__ip(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_ADMIN_ALLOWED_CIDRS", "100.64.0.0/10")
    req = _request(client_host="100.64.0.42")
    assert_admin_client_allowed(req, role="admin")


def test_assert_admin_skips_non_admin_role(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_ADMIN_ALLOWED_CIDRS", "100.64.0.0/10")
    req = _request(client_host="203.0.113.50")
    assert_admin_client_allowed(req, role="user")


def test_docker_gateway_allowed_when_docker_publish(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_ADMIN_ALLOWED_CIDRS", "100.64.0.0/10")
    monkeypatch.setenv("ALFA_AI_ADMIN_DOCKER_PUBLISH", "true")
    req = _request(client_host="apps")
    assert_admin_client_allowed(req, role="admin", public_context="login")


def test_docker_gateway_blocked_when_docker_publish_off(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_ADMIN_ALLOWED_CIDRS", "100.64.0.0/10")
    monkeypatch.setenv("ALFA_AI_ADMIN_DOCKER_PUBLISH", "false")
    req = _request(client_host="apps")
    with pytest.raises(HTTPException) as exc:
        assert_admin_client_allowed(req, role="admin", public_context="login")
    assert exc.value.status_code == 401
