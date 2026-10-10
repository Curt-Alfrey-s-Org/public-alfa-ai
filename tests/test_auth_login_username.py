"""Login accepts email or username."""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from typing import Any

import bcrypt
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from src.api import login_rate_limit
from src.api.deps import get_security_store, get_user_store
from src.api.models.user import UserRecord, UserRole
from src.api.public_errors import (
    ACCOUNT_PENDING_APPROVAL_MSG,
    EMAIL_NOT_VERIFIED_MSG,
    INVALID_CREDENTIALS_MSG,
)
from src.api.routers import auth as auth_router


@dataclass
class _MemSecurity:
    def is_ip_blocked(self, ip: str) -> bool:
        return False

    def record_event(self, *args: Any, **kwargs: Any) -> None:
        return None

    def count_recent_failures(self, user_id: str, window_min: int) -> int:
        return 0

    def lock_account(self, user_id: str, window_min: int) -> None:
        return None

    def reset_failed_attempts(self, user_id: str) -> None:
        return None

    def is_account_locked(self, user_id: str) -> bool:
        return False

    def clear_expired_lock(self, user_id: str) -> None:
        return None


class _MemUserStore:
    def __init__(self) -> None:
        self._by_lower_email: dict[str, UserRecord] = {}
        self._by_lower_username: dict[str, UserRecord] = {}

    def get_by_email_ci(self, email: str) -> UserRecord | None:
        return self._by_lower_email.get((email or "").strip().lower())

    def get_by_username_ci(self, username: str) -> UserRecord | None:
        return self._by_lower_username.get((username or "").strip().lower())

    def _seed(
        self,
        email: str,
        username: str,
        password: str,
        *,
        email_verified: bool = True,
        approved: bool = True,
        is_active: bool = True,
    ) -> UserRecord:
        pw_hash = bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()
        rec = UserRecord(
            id=str(uuid.uuid4()),
            email=email.strip().lower(),
            username=username,
            password_hash=pw_hash,
            role="user",
            email_verified=email_verified,
            approved=approved,
            is_active=is_active,
        )
        self._by_lower_email[rec.email] = rec
        self._by_lower_username[rec.username.lower()] = rec
        return rec


@pytest.fixture
def login_client(monkeypatch: pytest.MonkeyPatch) -> tuple[TestClient, _MemUserStore]:
    # Per-IP failed-login limit: in-process counters only, fresh per test.
    monkeypatch.delenv("REDIS_URL", raising=False)
    login_rate_limit.reset_memory_limits_for_tests()
    app = FastAPI()
    app.include_router(auth_router.router)
    store = _MemUserStore()
    app.dependency_overrides[get_user_store] = lambda: store
    app.dependency_overrides[get_security_store] = lambda: _MemSecurity()
    return TestClient(app), store


def test_login_with_username(login_client: tuple[TestClient, _MemUserStore]) -> None:
    client, store = login_client
    u = uuid.uuid4().hex[:8]
    store._seed(f"bama_{u}@example.com", f"bama_{u}", "longpassword1")

    ok = client.post(
        "/alfa-ai/api/auth/login",
        json={"login": f"bama_{u}", "password": "change-me"},
    )
    assert ok.status_code == 200, ok.text
    assert ok.json().get("access_token")

    by_email = client.post(
        "/alfa-ai/api/auth/login",
        json={"login": f"bama_{u}@example.com", "password": "change-me"},
    )
    assert by_email.status_code == 200, by_email.text

    legacy_email_key = client.post(
        "/alfa-ai/api/auth/login",
        json={"email": f"bama_{u}", "password": "change-me"},
    )
    assert legacy_email_key.status_code == 200, legacy_email_key.text


def test_login_wrong_password_uses_generic_message(
    login_client: tuple[TestClient, _MemUserStore],
) -> None:
    client, store = login_client
    u = uuid.uuid4().hex[:8]
    store._seed(f"user_{u}@example.com", f"user_{u}", "longpassword1")

    bad = client.post(
        "/alfa-ai/api/auth/login",
        json={"login": f"user_{u}", "password": "change-me"},
    )
    assert bad.status_code == 401
    assert bad.json().get("detail") == INVALID_CREDENTIALS_MSG


def test_login_unverified_uses_lifecycle_message(
    login_client: tuple[TestClient, _MemUserStore],
) -> None:
    client, store = login_client
    u = uuid.uuid4().hex[:8]
    store._seed(
        f"uv_{u}@example.com",
        f"uv_{u}",
        "longpassword1",
        email_verified=False,
        approved=False,
    )
    r = client.post(
        "/alfa-ai/api/auth/login",
        json={"login": f"uv_{u}", "password": "change-me"},
    )
    assert r.status_code == 401
    assert r.json().get("detail") == EMAIL_NOT_VERIFIED_MSG


def test_login_unapproved_uses_lifecycle_message(
    login_client: tuple[TestClient, _MemUserStore],
) -> None:
    client, store = login_client
    u = uuid.uuid4().hex[:8]
    store._seed(
        f"ua_{u}@example.com",
        f"ua_{u}",
        "longpassword1",
        email_verified=True,
        approved=False,
    )
    r = client.post(
        "/alfa-ai/api/auth/login",
        json={"login": f"ua_{u}", "password": "change-me"},
    )
    assert r.status_code == 401
    assert r.json().get("detail") == ACCOUNT_PENDING_APPROVAL_MSG
