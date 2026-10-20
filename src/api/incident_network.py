"""Network restrictions for internal Alertmanager webhook ingest."""

from __future__ import annotations

import ipaddress
import logging
import os

from fastapi import HTTPException, Request

from src.api.admin_network import _DOCKER_PROXY_NETWORKS, _is_docker_published_proxy_ip, get_client_ip
from src.api.public_errors import SERVICE_UNAVAILABLE

logger = logging.getLogger(__name__)

_DEFAULT_ALERT_CIDRS = (
    "127.0.0.0/8",
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "100.64.0.0/10",
)


def load_alert_allowed_networks() -> tuple[ipaddress.IPv4Network | ipaddress.IPv6Network, ...]:
    raw = (os.getenv("ALFA_AI_ALERT_ALLOWED_CIDRS") or "").strip()
    if raw.lower() in ("*", "any", "off", "false", "0"):
        return ()
    cidr_text = raw if raw else ",".join(_DEFAULT_ALERT_CIDRS)
    nets: list[ipaddress.IPv4Network | ipaddress.IPv6Network] = []
    for part in cidr_text.split(","):
        token = part.strip()
        if not token:
            continue
        try:
            nets.append(ipaddress.ip_network(token, strict=False))
        except ValueError:
            logger.warning("Ignoring invalid ALFA_AI_ALERT_ALLOWED_CIDRS entry: %s", token)
    return tuple(nets)


def _client_ip_allowed(ip: str | None, networks: tuple[ipaddress.IPv4Network | ipaddress.IPv6Network, ...]) -> bool:
    if not networks:
        return True
    if not ip:
        return False
    if _is_docker_published_proxy_ip(ip):
        bypass = (os.getenv("ALFA_AI_ALERT_DOCKER_PUBLISH") or "true").strip().lower()
        if bypass in ("1", "true", "yes", "on"):
            return True
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return any(addr in net for net in networks) or any(addr in net for net in _DOCKER_PROXY_NETWORKS)


def require_alert_webhook_network(request: Request) -> None:
    networks = load_alert_allowed_networks()
    if not networks:
        return
    ip = get_client_ip(request)
    if not _client_ip_allowed(ip, networks):
        logger.warning("alert webhook blocked from IP %s", ip)
        raise HTTPException(status_code=403, detail=SERVICE_UNAVAILABLE)


def expected_alert_webhook_token() -> str:
    return (os.getenv("ALFA_AI_ALERT_WEBHOOK_TOKEN") or "").strip()
