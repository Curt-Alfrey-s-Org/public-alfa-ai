"""Admin Users: create, mark verified, resend verification (AUTH_ACCOUNT_LIFECYCLE)."""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from typing import Any
from unittest.mock import patch

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from src.api.deps import get_current_user, get_security_store, get_user_store
from src.api.models.user import UserRecord
from src.api.routers import admin as admin_router


@dataclass
class _MemSecurity:
    events: list[str] = field(default_factory=list)

    unlocked: list[str] = field(default_factory=list)

    def record_event(self, event_type: str, *args: Any, **kwargs: Any) -> None:
        self.events.append(event_type)

    def reset_failed_attempts(self, user_id: str) -> None:
        self.unlocked.append(user_id)


class _MemUserStore:
    def __init__(self) -> None:
        self.users: dict[str, UserRecord] = {}
        self.tokens: dict[str, str] = {}

    def get_by_id(self, user_id: str) -> UserRecord | None:
        return self.users.get(user_id)

    def get_by_email_ci(self, email: str) -> UserRecord | None:
        key = (email or "").strip().lower()
        for u in self.users.values():
            if u.email == key:
                return u
        return None

    def get_by_username_ci(self, username: str) -> UserRecord | None:
        key = (username or "").strip().lower()
        for u in self.users.values():
            if u.username.lower() == key:
                return u
        return None

    def create_user(
        self,
        email: str,
        username: str,
        password_hash: str,
        role: str = "user",
        *,
        email_verified: bool = True,
        approved: bool = True,
        email_verify_token: str | None = None,
        email_verify_expires: str | None = None,
    ) -> UserRecord:
        rec = UserRecord(
            id=str(uuid.uuid4()),
            email=(email or "").strip().lower(),
            username=username,
            password_hash=password_hash,
            role=role,  # type: ignore[arg-type]
            email_verified=email_verified,
            approved=approved,
        )
        self.users[rec.id] = rec
        if email_verify_token:
            self.tokens[rec.id] = email_verify_token
        return rec

    def mark_email_verified(self, user_id: str) -> None:
        u = self.users[user_id]
        u.email_verified = True
        self.tokens.pop(user_id, None)

    def set_email_verify_token(self, user_id: str, token: str, expires: str) -> None:
        self.tokens[user_id] = token

    def set_approved(self, user_id: str, approved: bool, *, approved_by: str | None = None) -> None:
        self.users[user_id].approved = approved


@pytest.fixture
def admin_client() -> tuple[TestClient, _MemUserStore, _MemSecurity]:
    store = _MemUserStore()
    sec = _MemSecurity()
    admin = UserRecord(
        id=str(uuid.uuid4()),
        email="operator@example.com",
        username="admin",
        password_hash="x",
        role="admin",
        email_verified=True,
        approved=True,
    )
    store.users[admin.id] = admin

    app = FastAPI()
    app.include_router(admin_router.router)
    app.dependency_overrides[get_user_store] = lambda: store
    app.dependency_overrides[get_security_store] = lambda: sec
    app.dependency_overrides[get_current_user] = lambda: admin
    return TestClient(app), store, sec


def test_admin_create_user_starts_verified_and_approved(
    admin_client: tuple[TestClient, _MemUserStore, _MemSecurity],
) -> None:
    client, store, sec = admin_client
    u = uuid.uuid4().hex[:8]
    r = client.post(
        "/alfa-ai/api/admin/users",
        json={
            "email": f"new_{u}@example.com",
            "username": f"new_{u}",
            "password": "change-me",
            "password_confirm": "change-me",
        },
    )
    assert r.status_code == 200, r.text
    data = r.json()
    assert data["ok"] is True
    assert data["user"]["email_verified"] is True
    assert data["user"]["approved"] is True
    created = store.get_by_id(data["user"]["id"])
    assert created is not None
    assert created.email_verified is True
    assert created.approved is True
    assert "user_created_by_admin" in sec.events


def test_admin_create_user_conflict(
    admin_client: tuple[TestClient, _MemUserStore, _MemSecurity],
) -> None:
    client, store, _sec = admin_client
    store.create_user("operator@example.com", "takenuser", "hash")
    r = client.post(
        "/alfa-ai/api/admin/users",
        json={
            "email": "operator@example.com",
            "username": "othername",
            "password": "change-me",
            "password_confirm": "change-me",
        },
    )
    assert r.status_code == 409
    assert r.json().get("detail") == "Email or username is already in use."


def test_admin_mark_email_verified(
    admin_client: tuple[TestClient, _MemUserStore, _MemSecurity],
) -> None:
    client, store, sec = admin_client
    target = store.create_user(
        "operator@example.com",
        "stuckuser",
        "hash",
        email_verified=False,
        approved=False,
    )
    r = client.patch(
        f"/alfa-ai/api/admin/users/{target.id}/email-verified",
        json={"verified": True},
    )
    assert r.status_code == 200, r.text
    assert store.get_by_id(target.id).email_verified is True  # type: ignore[union-attr]
    assert "user_email_verified_by_admin" in sec.events


def test_admin_resend_verification_uses_existing_smtp_helper(
    admin_client: tuple[TestClient, _MemUserStore, _MemSecurity],
) -> None:
    client, store, sec = admin_client
    target = store.create_user(
        "operator@example.com",
        "mailuser",
        "hash",
        email_verified=False,
        approved=False,
    )
    with patch("src.api.routers.auth.send_email", return_value=True) as send:
        r = client.post(f"/alfa-ai/api/admin/users/{target.id}/resend-verification")
    assert r.status_code == 200, r.text
    assert r.json().get("sent") is True
    send.assert_called_once()
    assert send.call_args[0][0] == "operator@example.com"
    assert target.id in store.tokens
    assert "user_verification_resent_by_admin" in sec.events


def test_admin_resend_rejected_when_already_verified(
    admin_client: tuple[TestClient, _MemUserStore, _MemSecurity],
) -> None:
    client, store, _sec = admin_client
    target = store.create_user("operator@example.com", "okuser", "hash", email_verified=True)
    r = client.post(f"/alfa-ai/api/admin/users/{target.id}/resend-verification")
    assert r.status_code == 400


def test_admin_unlock_clears_account_lock(
    admin_client: tuple[TestClient, _MemUserStore, _MemSecurity],
) -> None:
    """Review finding 15: admin clears a failed-login lock without touching password/2FA."""
    client, store, sec = admin_client
    target = store.create_user("operator@example.com", "lockeduser", "hash")
    r = client.post(f"/alfa-ai/api/admin/users/{target.id}/unlock")
    assert r.status_code == 200, r.text
    assert r.json().get("ok") is True
    assert sec.unlocked == [target.id]
    assert "admin_account_unlocked" in sec.events
    assert store.get_by_id(target.id).password_hash == "hash"  # type: ignore[union-attr]


def test_admin_unlock_unknown_user_404(
    admin_client: tuple[TestClient, _MemUserStore, _MemSecurity],
) -> None:
    client, _store, sec = admin_client
    r = client.post(f"/alfa-ai/api/admin/users/{uuid.uuid4()}/unlock")
    assert r.status_code == 404
    assert sec.unlocked == []
