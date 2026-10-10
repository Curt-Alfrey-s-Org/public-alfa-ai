"""Admin pool switch API (27B inference <-> 35B pool35)."""

from __future__ import annotations

import logging
import os

import httpx
import pyotp
from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field

from src.api.admin_network import require_admin_client_network
from src.api.deps import get_security_store, get_user_store, require_role
from src.api.models.audit import SecurityStore
from src.api.models.user import UserRecord, UserStore
from src.api.pool_targets import SWITCHABLE_POOLS, detect_active_pool, opposite_pool
from src.api.public_errors import INVALID_CREDENTIALS_MSG, SERVICE_UNAVAILABLE
from src.api.redis_pool_switch import (
    begin_pool_switch,
    get_pool_switch_status,
    normalize_status,
    update_pool_switch_phase,
)
from src.api.routers.auth import _verify_password

logger = logging.getLogger(__name__)

router = APIRouter(
    prefix="/alfa-ai/api/admin/pool",
    tags=["admin-pool"],
    dependencies=[Depends(require_admin_client_network)],
)


class PoolSwitchRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    target: str = Field(..., min_length=4, max_length=16)
    password: str = Field(..., min_length=1, max_length=128)
    totp_code: str | None = Field(default=None, min_length=6, max_length=8)


def _switchd_url() -> str:
    return (os.getenv("ALFA_POOL_SWITCHD_URL") or "http://host.docker.internal:8421").rstrip("/")


def _switchd_bearer() -> str:
    return (os.getenv("ALFA_POOL_SWITCH_BEARER_TOKEN") or "").strip()


def _client_ip(request: Request) -> str | None:
    forwarded = request.headers.get("x-forwarded-for")
    if forwarded:
        return forwarded.split(",")[0].strip()
    if request.client:
        return request.client.host
    return None


def _user_agent(request: Request) -> str | None:
    return request.headers.get("user-agent")


@router.get("/status")
def pool_switch_status(
    _user: UserRecord = Depends(require_role("admin")),
) -> dict:
    active = detect_active_pool()
    raw = get_pool_switch_status()
    return normalize_status(raw, active_pool=active)


@router.post("/switch", status_code=202)
async def pool_switch(
    body: PoolSwitchRequest,
    request: Request,
    user: UserRecord = Depends(require_role("admin")),
    store: UserStore = Depends(get_user_store),
    sec: SecurityStore = Depends(get_security_store),
) -> dict:
    target = body.target.strip().lower()
    if target not in SWITCHABLE_POOLS:
        raise HTTPException(status_code=400, detail="Invalid pool target.")

    bearer = _switchd_bearer()
    if not bearer:
        logger.error("pool switch: ALFA_POOL_SWITCH_BEARER_TOKEN not configured")
        raise HTTPException(status_code=503, detail=SERVICE_UNAVAILABLE)

    ip = _client_ip(request)
    ua = _user_agent(request)

    fresh = store.get_by_id(user.id)
    if fresh is None or not fresh.is_active:
        raise HTTPException(status_code=401, detail=INVALID_CREDENTIALS_MSG)

    if not _verify_password(body.password, fresh.password_hash):
        sec.record_event(
            "pool_switch_stepup_failed",
            success=False,
            user_id=user.id,
            ip_address=ip,
            user_agent=ua,
            details="invalid password",
        )
        raise HTTPException(status_code=401, detail=INVALID_CREDENTIALS_MSG)

    if fresh.is_2fa_enabled:
        if not body.totp_code or not fresh.totp_secret:
            sec.record_event(
                "pool_switch_stepup_failed",
                success=False,
                user_id=user.id,
                ip_address=ip,
                user_agent=ua,
                details="2fa required",
            )
            raise HTTPException(status_code=401, detail=INVALID_CREDENTIALS_MSG)
        totp = pyotp.TOTP(fresh.totp_secret)
        if not totp.verify(body.totp_code.strip()):
            sec.record_event(
                "pool_switch_stepup_failed",
                success=False,
                user_id=user.id,
                ip_address=ip,
                user_agent=ua,
                details="invalid totp",
            )
            raise HTTPException(status_code=401, detail=INVALID_CREDENTIALS_MSG)

    active = detect_active_pool()
    if active == target:
        raise HTTPException(status_code=409, detail="Pool already active.")

    existing = get_pool_switch_status()
    if existing and existing.get("switching"):
        raise HTTPException(status_code=409, detail="Switch already in progress.")

    from_pool = active or opposite_pool(target)

    try:
        begin_pool_switch(
            target_pool=target,
            from_pool=from_pool,
            requested_by_user_id=user.id,
        )
    except Exception:
        logger.exception("pool switch: redis begin failed")
        raise HTTPException(status_code=503, detail=SERVICE_UNAVAILABLE) from None

    sec.record_event(
        "pool_switch_requested",
        success=True,
        user_id=user.id,
        ip_address=ip,
        user_agent=ua,
        details=f"target={target}",
    )

    payload = {
        "target": target,
        "from_pool": from_pool,
        "requested_by_user_id": user.id,
    }
    headers = {"Authorization": f"Bearer {bearer}"}
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.post(f"{_switchd_url()}/switch", json=payload, headers=headers)
        if resp.status_code not in (202, 409):
            update_pool_switch_phase(phase="failed", error="switchd rejected request", switching=False)
            sec.record_event(
                "pool_switch_failed",
                success=False,
                user_id=user.id,
                ip_address=ip,
                user_agent=ua,
                details=f"switchd status={resp.status_code}",
            )
            raise HTTPException(status_code=503, detail=SERVICE_UNAVAILABLE)
        if resp.status_code == 409:
            raise HTTPException(status_code=409, detail="Switch already in progress.")
    except HTTPException:
        raise
    except Exception:
        logger.exception("pool switch: switchd unreachable")
        update_pool_switch_phase(phase="failed", error="switchd unreachable", switching=False)
        sec.record_event(
            "pool_switch_failed",
            success=False,
            user_id=user.id,
            ip_address=ip,
            user_agent=ua,
            details="switchd unreachable",
        )
        raise HTTPException(status_code=503, detail=SERVICE_UNAVAILABLE) from None

    return {"accepted": True, "target": target}
