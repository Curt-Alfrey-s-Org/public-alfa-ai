"""Admin access network restrictions ( / LAN CIDR allowlist)."""

from __future__ import annotations

import ipaddress
import logging
import os
from typing import Any, Literal

from fastapi import HTTPException, Request

from src.api.public_errors import INVALID_CREDENTIALS_MSG

logger = logging.getLogger(__name__)

#  IPv4 tailnet + ULA IPv6 (fd7a:115c:a1e0::/48). Operators may add LAN CIDRs.
_DEFAULT_TAILNET_CIDRS = ("100.64.0.0/10", "fd7a:115c:a1e0::/48")

# Public responses — no internal architecture (see .cursor/rules/public-surface-security.mdc).
PUBLIC_LOGIN_DENIED_DETAIL = INVALID_CREDENTIALS_MSG
PUBLIC_API_DENIED_DETAIL = "Access denied."

# Linux Docker published ports SNAT client -> bridge gateway; container never sees /LAN IP.
_DOCKER_PROXY_NETWORKS: tuple[ipaddress.IPv4Network | ipaddress.IPv6Network, ...] = (
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("10.0.0.0/8"),
)


def _docker_publish_bypass_enabled() -> bool:
    raw = (os.getenv("ALFA_AI_ADMIN_DOCKER_PUBLISH") or "true").strip().lower()
    return raw in ("1", "true", "yes", "on")


def _is_docker_published_proxy_ip(ip: str | None) -> bool:
    if not ip:
        return False
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return any(addr in net for net in _DOCKER_PROXY_NETWORKS)


def get_client_ip(request: Request) -> str | None:
    """Best-effort client IP (respects X-Forwarded-For from nginx / Cloudflare)."""
    forwarded = request.headers.get("x-forwarded-for")
    if forwarded:
        return forwarded.split(",")[0].strip()
    if request.client:
        return request.client.host
    return None


def get_proxy_resolved_client_ip(request: Request) -> str | None:
    """Client IP as resolved by Uvicorn's trusted-proxy handling; never reads X-Forwarded-For.

    Dockerfile.api runs Uvicorn with ``--proxy-headers --forwarded-allow-ips=$FORWARDED_ALLOW_IPS``,
    so ``request.client`` already reflects ``X-Forwarded-For`` only when the direct peer is a
    trusted proxy, taking the right-most untrusted hop (https://uvicorn.dev/deployment/).
    Unlike :func:`get_client_ip` a client cannot choose this value by sending its own
    ``X-Forwarded-For``, so use it for security keys (login lockout / per-IP limits).
    """
    if request.client and request.client.host:
        return request.client.host
    return None


def _parse_allowed_networks(raw: str) -> tuple[ipaddress.IPv4Network | ipaddress.IPv6Network, ...]:
    nets: list[ipaddress.IPv4Network | ipaddress.IPv6Network] = []
    for part in raw.split(","):
        token = part.strip()
        if not token:
            continue
        try:
            nets.append(ipaddress.ip_network(token, strict=False))
        except ValueError:
            logger.warning("Ignoring invalid ALFA_AI_ADMIN_ALLOWED_CIDRS entry: %s", token)
    return tuple(nets)


def load_admin_allowed_networks() -> tuple[ipaddress.IPv4Network | ipaddress.IPv6Network, ...]:
    """Return allowed networks for admin login/API, or empty tuple when unrestricted."""
    raw = (os.getenv("ALFA_AI_ADMIN_ALLOWED_CIDRS") or "").strip()
    if raw.lower() in ("*", "any", "off", "false", "0"):
        return ()
    if not raw:
        return ()
    return _parse_allowed_networks(raw)


def client_ip_allowed(ip: str | None, networks: tuple[Any, ...]) -> bool:
    if not networks:
        return True
    if not ip:
        return False
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return any(addr in net for net in networks)


def assert_admin_client_allowed(
    request: Request,
    *,
    role: str | None = None,
    public_context: Literal["login", "api"] = "api",
) -> None:
    """Raise when admin access is attempted from a disallowed client IP."""
    if role is not None and role != "admin":
        return
    networks = load_admin_allowed_networks()
    if not networks:
        return
    ip = get_client_ip(request)
    if client_ip_allowed(ip, networks):
        return
    if _docker_publish_bypass_enabled() and _is_docker_published_proxy_ip(ip):
        logger.info(
            "Admin %s via Docker published port (seen IP %s is bridge gateway); "
            "host firewall must restrict operator port access",
            public_context,
            ip,
        )
        return
    logger.warning(
        "Admin access denied for client IP %s (not in ALFA_AI_ADMIN_ALLOWED_CIDRS); context=%s",
        ip,
        public_context,
    )
    if public_context == "login":
        raise HTTPException(status_code=401, detail=PUBLIC_LOGIN_DENIED_DETAIL)
    raise HTTPException(status_code=403, detail=PUBLIC_API_DENIED_DETAIL)


def require_admin_client_network(request: Request) -> None:
    """FastAPI dependency: all /alfa-ai/api/admin routes require an allowed client IP."""
    assert_admin_client_allowed(request, role="admin", public_context="api")
