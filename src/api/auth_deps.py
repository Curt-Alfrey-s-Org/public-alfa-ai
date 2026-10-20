"""
Bearer token gate for ALFa AI HTTP API (internal orchestrator).

Set ALFA_AI_API_TOKEN to a strong secret and ALFA_AI_REQUIRE_API_AUTH=true in production.
For local dev only, ALFA_AI_REQUIRE_API_AUTH=false allows unauthenticated access.

Brain-only JSON GET /api/admin/health (used by the static operator page on :8420/admin/health, not
by the public web app) can be locked with ALFA_AI_LOCK_OPERATOR_HEALTH. The public Admin Health UI
at /alfa-ai/admin/health calls GET /alfa-ai/api/admin/health (admin router); that route is unchanged
and still requires an admin JWT via require_role("admin").
"""

from __future__ import annotations

import hmac
import logging
import os

from fastapi import Header, HTTPException

from src.api.public_errors import ACCESS_DENIED_MSG, SERVICE_UNAVAILABLE

logger = logging.getLogger(__name__)


def _token_matches(got: str, expected: str) -> bool:
    """Constant-time bearer token comparison (org review 2026-09-25: no ``==`` on secrets)."""
    if not got or not expected:
        return False
    return hmac.compare_digest(got.encode("utf-8"), expected.encode("utf-8"))


def _truthy(name: str, default: str = "false") -> bool:
    return os.getenv(name, default).lower() in ("true", "1", "yes")


def operator_brain_health_locked() -> bool:
    """True when GET /api/admin/health (brain JSON) must not be anonymous — not /alfa-ai/api/admin/health."""
    if _truthy("ALFA_AI_REQUIRE_API_AUTH"):
        return True
    lock_raw = os.getenv("ALFA_AI_LOCK_OPERATOR_HEALTH", "true").strip().lower()
    return lock_raw not in ("false", "0", "no", "off")


def require_brain_operator_health_auth(authorization: str | None = Header(None)) -> None:
    """
    Protects GET /api/admin/health (Redis + brain services snapshot) in app.py.

    Does not apply to GET /alfa-ai/api/admin/health (cluster health for www /alfa-ai/admin/health).

    When not locked (see operator_brain_health_locked), allows unauthenticated access (dev).

    When locked, accepts either:
    - Authorization: Bearer <ALFA_AI_API_TOKEN> when ALFA_AI_REQUIRE_API_AUTH is set, or
    - Authorization: Bearer <JWT access token> for an active user with role admin.
    """
    if not operator_brain_health_locked():
        return

    if authorization is None or not authorization.startswith("Bearer "):
        logger.warning("operator health: missing bearer token")
        raise HTTPException(
            status_code=401,
            detail=ACCESS_DENIED_MSG,
            headers={"WWW-Authenticate": "Bearer"},
        )

    token = authorization[7:].strip()
    if not token:
        logger.warning("operator health: empty bearer token")
        raise HTTPException(status_code=401, detail=ACCESS_DENIED_MSG)

    require_api = _truthy("ALFA_AI_REQUIRE_API_AUTH")
    expected_api = os.getenv("ALFA_AI_API_TOKEN", "").strip()
    if require_api:
        if not expected_api:
            logger.error("ALFA_AI_REQUIRE_API_AUTH set but ALFA_AI_API_TOKEN missing")
            raise HTTPException(status_code=503, detail=SERVICE_UNAVAILABLE)
        if _token_matches(token, expected_api):
            return
        # Fall through: allow admin JWT even when API token is required (same as web login).
    elif expected_api and _token_matches(token, expected_api):
        return

    try:
        from src.api.deps import decode_token, get_user_store

        payload = decode_token(token)
        if payload.get("type") != "access":
            logger.warning("operator health: invalid token type")
            raise HTTPException(status_code=403, detail=ACCESS_DENIED_MSG)
        user = get_user_store().get_by_id(payload["sub"])
        if user is None or not user.is_active or not user.has_role("admin"):
            logger.warning("operator health: non-admin or inactive JWT")
            raise HTTPException(status_code=403, detail=ACCESS_DENIED_MSG)
    except HTTPException:
        raise
    except Exception as exc:
        logger.debug("JWT validation failed for operator health: %s", exc)
        raise HTTPException(status_code=403, detail=ACCESS_DENIED_MSG) from exc


def _validate_alfa_ai_api_token_value(got: str) -> None:
    expected = os.getenv("ALFA_AI_API_TOKEN", "").strip()
    if not expected:
        logger.error("ALFA_AI_REQUIRE_API_AUTH set but ALFA_AI_API_TOKEN missing")
        raise HTTPException(status_code=503, detail=SERVICE_UNAVAILABLE)
    if not _token_matches(got, expected):
        logger.warning("Invalid ALFA_AI_API_TOKEN presented")
        raise HTTPException(status_code=403, detail=ACCESS_DENIED_MSG)


def require_alfa_ai_api_token(authorization: str | None = Header(None)) -> None:
    # Default false so local `uvicorn` works; production must set ALFA_AI_REQUIRE_API_AUTH=true
    require = os.getenv("ALFA_AI_REQUIRE_API_AUTH", "false").lower() in (
        "true",
        "1",
        "yes",
    )
    if not require:
        return

    if authorization is None or not authorization.startswith("Bearer "):
        raise HTTPException(
            status_code=401,
            detail=ACCESS_DENIED_MSG,
            headers={"WWW-Authenticate": "Bearer"},
        )

    _validate_alfa_ai_api_token_value(authorization[7:].strip())


def require_alfa_ai_api_token_sse(
    authorization: str | None = Header(None),
    access_token: str | None = None,
) -> None:
    """Bearer header or ?access_token= for EventSource (no custom headers)."""
    require = os.getenv("ALFA_AI_REQUIRE_API_AUTH", "false").lower() in (
        "true",
        "1",
        "yes",
    )
    if not require:
        return

    got = ""
    if authorization and authorization.startswith("Bearer "):
        got = authorization[7:].strip()
    elif access_token:
        got = access_token.strip()

    if not got:
        raise HTTPException(
            status_code=401,
            detail=ACCESS_DENIED_MSG,
            headers={"WWW-Authenticate": "Bearer"},
        )
    _validate_alfa_ai_api_token_value(got)


def require_admin_jwt_sse(
    authorization: str | None = Header(None),
    access_token: str | None = None,
) -> None:
    """Admin JWT for EventSource (Bearer header or ?access_token= query param)."""
    got = ""
    if authorization and authorization.startswith("Bearer "):
        got = authorization[7:].strip()
    elif access_token:
        got = access_token.strip()

    if not got:
        raise HTTPException(
            status_code=401,
            detail=ACCESS_DENIED_MSG,
            headers={"WWW-Authenticate": "Bearer"},
        )

    try:
        from src.api.deps import decode_token, get_user_store

        payload = decode_token(got)
        if payload.get("type") != "access":
            raise HTTPException(status_code=403, detail=ACCESS_DENIED_MSG)
        user = get_user_store().get_by_id(payload["sub"])
        if user is None or not user.is_active or not user.has_role("admin"):
            raise HTTPException(status_code=403, detail=ACCESS_DENIED_MSG)
    except HTTPException:
        raise
    except Exception as exc:
        logger.debug("JWT validation failed for admin missions SSE: %s", exc)
        raise HTTPException(status_code=403, detail=ACCESS_DENIED_MSG) from exc

