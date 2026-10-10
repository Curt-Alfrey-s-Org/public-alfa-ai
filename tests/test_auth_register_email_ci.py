"""Registration must reject emails that match an existing account case-insensitively (same as login)."""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from typing import Any

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from src.api.deps import get_security_store, get_user_store
from src.api.models.user import UserRecord, UserRole
from src.api.routers import auth as auth_router


@dataclass
class _MemSecurity:
    def record_event(self, *args: Any, **kwargs: Any) -> None:
        return None


class _MemUserStore:
    """Minimal store: normalized email keys (mirrors UserStore after create_user fix)."""

    def __init__(self) -> None:
        self._by_lower_email: dict[str, UserRecord] = {}
        self._by_username: dict[str, UserRecord] = {}

    def get_by_email_ci(self, email: str) -> UserRecord | None:
        return self._by_lower_email.get((email or "").strip().lower())

    def get_by_username(self, username: str) -> UserRecord | None:
        return self._by_username.get(username)

    def create_user(
        self,
        email: str,
        username: str,
        password_hash: str,
        role: UserRole = "user",
        *,
        email_verified: bool = True,
        approved: bool = True,
        email_verify_token: str | None = None,
        email_verify_expires: str | None = None,
    ) -> UserRecord:
        key = (email or "").strip().lower()
        rec = UserRecord(
            id=str(uuid.uuid4()),
            email=key,
            username=username,
            password_hash=password_hash,
            role=role,
            email_verified=email_verified,
            approved=approved,
        )
        self._by_lower_email[key] = rec
        self._by_username[username] = rec
        return rec


@pytest.fixture
def reg_client() -> TestClient:
    app = FastAPI()
    app.include_router(auth_router.router)
    store = _MemUserStore()
    app.dependency_overrides[get_user_store] = lambda: store
    app.dependency_overrides[get_security_store] = lambda: _MemSecurity()
    return TestClient(app)


def test_register_rejects_case_variant_of_existing_email(reg_client: TestClient) -> None:
    u = uuid.uuid4().hex[:10]
    local = f"CaseOnlyDup{u}"
    r1 = reg_client.post(
        "/alfa-ai/api/auth/register",
        headers={"X-Forwarded-For": "203.0.113.10"},
        json={
            "email": f"{local}@Example.com",
            "username": f"user_a_{u}",
            "password": "change-me",
        },
    )
    assert r1.status_code == 200, r1.text
    body = r1.json()
    assert "access_token" not in body
    assert "If a confirmation email arrives" in body.get("message", "")
    r2 = reg_client.post(
        "/alfa-ai/api/auth/register",
        headers={"X-Forwarded-For": "203.0.113.11"},
        json={
            "email": f"{local.lower()}@example.com",
            "username": f"user_b_{u}",
            "password": "change-me",
        },
    )
    assert r2.status_code == 409
    # Public surface: generic conflict copy (no "email already registered" leak).
    from src.api.public_errors import REGISTRATION_FAILED_MSG

    assert r2.json().get("detail") == REGISTRATION_FAILED_MSG
