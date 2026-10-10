"""Shared dependencies for the ALFa AI web application (JWT auth, user store)."""

from __future__ import annotations

import logging
import os
import secrets
from datetime import UTC, datetime, timedelta
from typing import Any

import jwt
from fastapi import Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from src.api.models.agent_config import AgentConfigStore
from src.api.models.ai_action import AiActionStore
from src.api.models.ai_setting import AiSettingStore
from src.api.models.audit import SecurityStore
from src.api.models.conversation import ConversationStore
from src.api.models.host_action import HostActionStore
from src.api.models.incident import IncidentStore
from src.api.models.user import UserRecord, UserRole, UserStore
from src.api.models.worker import WorkerStore
from src.api.public_errors import SERVICE_UNAVAILABLE
from src.config import get

logger = logging.getLogger(__name__)

_bearer = HTTPBearer(auto_error=False)

JWT_ALGORITHM = "HS256"
# Web UI session length (10× prior defaults: was 30 min / 7 days)
ACCESS_TOKEN_MINUTES = 300
REFRESH_TOKEN_DAYS = 70

_security_store: SecurityStore | None = None
_conversation_store: ConversationStore | None = None
_worker_store: WorkerStore | None = None
_incident_store: IncidentStore | None = None
_ai_action_store: AiActionStore | None = None
_ai_setting_store: AiSettingStore | None = None
_host_action_store: HostActionStore | None = None
_agent_config_store: AgentConfigStore | None = None


def _jwt_secret() -> str:
    secret = os.getenv("ALFA_AI_JWT_SECRET", "").strip()
    if not secret:
        logger.warning(
            "ALFA_AI_JWT_SECRET not set — generating ephemeral secret. "
            "Sessions will not survive restarts. Set it in production."
        )
        global _fallback_secret
        if "_fallback_secret" not in globals() or not _fallback_secret:
            _fallback_secret = secrets.token_hex(32)
        return _fallback_secret
    return secret


_fallback_secret: str = ""

_user_store: UserStore | None = None


def _get_database_url() -> str:
    url = get("DATABASE_URL", "").strip()
    if not url:
        raise HTTPException(status_code=503, detail=SERVICE_UNAVAILABLE)
    return url


def get_user_store() -> UserStore:
    global _user_store
    if _user_store is None:
        _user_store = UserStore(database_url=_get_database_url())
    return _user_store


def get_security_store() -> SecurityStore:
    global _security_store
    if _security_store is None:
        _security_store = SecurityStore(database_url=_get_database_url())
    return _security_store


def get_conversation_store() -> ConversationStore:
    global _conversation_store
    if _conversation_store is None:
        _conversation_store = ConversationStore(database_url=_get_database_url())
    return _conversation_store


def get_worker_store() -> WorkerStore:
    global _worker_store
    if _worker_store is None:
        _worker_store = WorkerStore(database_url=_get_database_url())
    return _worker_store


def get_incident_store() -> IncidentStore:
    global _incident_store
    if _incident_store is None:
        _incident_store = IncidentStore(database_url=_get_database_url())
    return _incident_store


def get_ai_action_store() -> AiActionStore:
    global _ai_action_store
    if _ai_action_store is None:
        _ai_action_store = AiActionStore(database_url=_get_database_url())
    return _ai_action_store


def get_ai_setting_store() -> AiSettingStore:
    global _ai_setting_store
    if _ai_setting_store is None:
        _ai_setting_store = AiSettingStore(database_url=_get_database_url())
    return _ai_setting_store


def get_host_action_store() -> HostActionStore:
    global _host_action_store
    if _host_action_store is None:
        _host_action_store = HostActionStore(database_url=_get_database_url())
    return _host_action_store


def get_agent_config_store() -> AgentConfigStore:
    global _agent_config_store
    if _agent_config_store is None:
        _agent_config_store = AgentConfigStore(database_url=_get_database_url())
    return _agent_config_store


def create_token(user_id: str, role: str, token_type: str, expires_delta: timedelta) -> str:
    now = datetime.now(UTC)
    payload: dict[str, Any] = {
        "sub": user_id,
        "role": role,
        "type": token_type,
        "iat": now,
        "exp": now + expires_delta,
    }
    return jwt.encode(payload, _jwt_secret(), algorithm=JWT_ALGORITHM)


def create_access_token(user_id: str, role: str) -> str:
    return create_token(user_id, role, "access", timedelta(minutes=ACCESS_TOKEN_MINUTES))


def create_refresh_token(user_id: str, role: str) -> str:
    return create_token(user_id, role, "refresh", timedelta(days=REFRESH_TOKEN_DAYS))


def create_2fa_pending_token(user_id: str, role: str) -> str:
    return create_token(user_id, role, "2fa_pending", timedelta(minutes=5))


def decode_token(token: str) -> dict[str, Any]:
    try:
        return jwt.decode(token, _jwt_secret(), algorithms=[JWT_ALGORITHM])
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=401, detail="Token expired")
    except jwt.InvalidTokenError:
        raise HTTPException(status_code=401, detail="Invalid token")


def get_current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
) -> UserRecord:
    if credentials is None:
        raise HTTPException(
            status_code=401,
            detail="Not authenticated",
            headers={"WWW-Authenticate": "Bearer"},
        )
    payload = decode_token(credentials.credentials)
    if payload.get("type") != "access":
        raise HTTPException(status_code=401, detail="Invalid token type")

    store = get_user_store()
    user = store.get_by_id(payload["sub"])
    if user is None or not user.is_active:
        raise HTTPException(status_code=401, detail="User not found or deactivated")
    return user


def require_role(minimum: UserRole):
    """Dependency factory: require the current user to have at least *minimum* role."""

    def _check(user: UserRecord = Depends(get_current_user)) -> UserRecord:
        if not user.has_role(minimum):
            raise HTTPException(status_code=403, detail="Insufficient permissions")
        return user

    return _check
