"""Login lockout + per-IP failed-login limit (org code review 2026-09-25, finding 15).

Docs: docs/AUTH_ACCOUNT_LIFECYCLE.md ("Failed-login lockout and per-IP limit").
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta
from typing import Any

import bcrypt
import pyotp
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from uvicorn.middleware.proxy_headers import ProxyHeadersMiddleware

from src.api import login_rate_limit
from src.api.deps import get_security_store, get_user_store
from src.api.models.audit import LOGIN_WINDOW_MINUTES, MAX_LOGIN_ATTEMPTS
from src.api.models.user import UserRecord
from src.api.public_errors import INVALID_CREDENTIALS_MSG, RATE_LIMIT_GENERIC
from src.api.routers import auth as auth_router

LOGIN = "/alfa-ai/api/auth/login"
PASSWORD = "change-me"


class _LockSecurity:
    """In-memory SecurityStore with the same lockout semantics as models/audit.py."""

    def __init__(self) -> None:
        self.events: list[dict[str, Any]] = []
        self.locked_until: dict[str, datetime] = {}

    def is_ip_blocked(self, ip: str) -> bool:
        return False

    def record_event(self, event_type: str, success: bool, **kwargs: Any) -> None:
        self.events.append({"event_type": event_type, "success": success, **kwargs})

    def event_types(self) -> list[str]:
        return [e["event_type"] for e in self.events]

    def count_recent_failures(
        self,
        user_id: str,
        window_minutes: int = LOGIN_WINDOW_MINUTES,
        event_type: str = "login_failed",
    ) -> int:
        return sum(
            1 for e in self.events
            if e["event_type"] == event_type and e.get("user_id") == user_id
        )

    def lock_account(self, user_id: str, minutes: int = LOGIN_WINDOW_MINUTES) -> None:
        self.locked_until[user_id] = datetime.now(tz=UTC) + timedelta(minutes=minutes)

    def is_account_locked(self, user_id: str) -> bool:
        until = self.locked_until.get(user_id)
        return until is not None and until > datetime.now(tz=UTC)

    def clear_expired_lock(self, user_id: str) -> None:
        if not self.is_account_locked(user_id):
            self.locked_until.pop(user_id, None)

    def reset_failed_attempts(self, user_id: str) -> None:
        self.locked_until.pop(user_id, None)


class _MemUserStore:
    def __init__(self) -> None:
        self.users: dict[str, UserRecord] = {}

    def get_by_email_ci(self, email: str) -> UserRecord | None:
        key = (email or "").strip().lower()
        return next((u for u in self.users.values() if u.email == key), None)

    def get_by_username_ci(self, username: str) -> UserRecord | None:
        key = (username or "").strip().lower()
        return next((u for u in self.users.values() if u.username.lower() == key), None)

    def get_by_id(self, user_id: str) -> UserRecord | None:
        return self.users.get(user_id)

    def seed(self, username: str, password: str = PASSWORD) -> UserRecord:
        rec = UserRecord(
            id=str(uuid.uuid4()),
            email=f"{username}@example.com",
            username=username,
            password_hash=bcrypt.hashpw(password.encode(), bcrypt.gensalt(4)).decode(),
            role="user",
            email_verified=True,
            approved=True,
            is_active=True,
        )
        self.users[rec.id] = rec
        return rec


@pytest.fixture(autouse=True)
def _fresh_ip_limit(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("REDIS_URL", raising=False)
    monkeypatch.delenv("ALFA_AI_LOGIN_IP_WINDOW_SEC", raising=False)
    # Account-lock tests: keep the per-IP limit out of the way unless a test lowers it.
    monkeypatch.setenv("ALFA_AI_LOGIN_IP_MAX_FAILURES", "1000")
    login_rate_limit.reset_memory_limits_for_tests()
    yield
    login_rate_limit.reset_memory_limits_for_tests()


def _app(store: _MemUserStore, sec: _LockSecurity) -> FastAPI:
    app = FastAPI()
    app.include_router(auth_router.router)
    app.dependency_overrides[get_user_store] = lambda: store
    app.dependency_overrides[get_security_store] = lambda: sec
    return app


@pytest.fixture
def env() -> tuple[TestClient, _MemUserStore, _LockSecurity]:
    store, sec = _MemUserStore(), _LockSecurity()
    return TestClient(_app(store, sec)), store, sec


def _login(client: TestClient, login: str, password: str, **kw: Any):
    return client.post(LOGIN, json={"login": login, "password": password}, **kw)


# ── Account lockout ─────────────────────────────────────────

def test_lock_after_max_failures_refuses_correct_password(env) -> None:
    client, store, sec = env
    user = store.seed(f"lk_{uuid.uuid4().hex[:8]}")
    for _ in range(MAX_LOGIN_ATTEMPTS):
        r = _login(client, user.username, "wrongpassword")
        assert r.status_code == 401
    assert "login_locked" in sec.event_types()
    assert sec.is_account_locked(user.id)

    r = _login(client, user.username, PASSWORD)
    assert r.status_code == 401
    assert r.json()["detail"] == INVALID_CREDENTIALS_MSG
    assert "access_token" not in r.json()
    assert "login_success" not in sec.event_types()
    assert sec.event_types()[-1] == "login_locked_refused"


def test_correct_password_does_not_clear_active_lock(env) -> None:
    client, store, sec = env
    user = store.seed(f"lk_{uuid.uuid4().hex[:8]}")
    sec.lock_account(user.id, LOGIN_WINDOW_MINUTES)
    until = sec.locked_until[user.id]

    for _ in range(3):
        r = _login(client, user.username, PASSWORD)
        assert r.status_code == 401
    # Lock still active and unchanged; refused attempts are not counted as login_failed
    # (so they do not extend the lock) and the password was never accepted.
    assert sec.is_account_locked(user.id)
    assert sec.locked_until[user.id] == until
    assert sec.count_recent_failures(user.id) == 0
    assert sec.event_types().count("login_locked_refused") == 3


def test_expired_lock_allows_login_and_is_cleared(env) -> None:
    client, store, sec = env
    user = store.seed(f"lk_{uuid.uuid4().hex[:8]}")
    sec.locked_until[user.id] = datetime.now(tz=UTC) - timedelta(seconds=1)

    r = _login(client, user.username, PASSWORD)
    assert r.status_code == 200, r.text
    assert r.json().get("access_token")
    assert user.id not in sec.locked_until


def test_admin_clear_unlocks(env) -> None:
    """Admin unlock (POST /admin/users/{id}/unlock) calls reset_failed_attempts."""
    client, store, sec = env
    user = store.seed(f"lk_{uuid.uuid4().hex[:8]}")
    sec.lock_account(user.id, LOGIN_WINDOW_MINUTES)
    assert _login(client, user.username, PASSWORD).status_code == 401

    sec.reset_failed_attempts(user.id)
    r = _login(client, user.username, PASSWORD)
    assert r.status_code == 200, r.text


# ── Per-IP failed-login limit ───────────────────────────────

def test_ip_limit_blocks_after_failures_even_with_correct_password(
    env, monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("ALFA_AI_LOGIN_IP_MAX_FAILURES", "3")
    client, store, sec = env
    victims = [store.seed(f"ip_{uuid.uuid4().hex[:8]}") for _ in range(3)]
    # Spread across different accounts (no single account reaches its lock threshold)
    # plus unknown usernames: all count against the client IP.
    _login(client, victims[0].username, "wrongpassword")
    _login(client, "no_such_user_xyz", "wrongpassword")
    _login(client, victims[1].username, "wrongpassword")

    r = _login(client, victims[2].username, PASSWORD)
    assert r.status_code == 429
    assert r.json()["detail"] == RATE_LIMIT_GENERIC
    assert r.headers.get("retry-after") == "900"
    assert not any(sec.is_account_locked(v.id) for v in victims)

    # Another client IP is unaffected.
    other = TestClient(client.app, client=("198.51.100.7", 40000))
    assert _login(other, victims[2].username, PASSWORD).status_code == 200


def test_ip_limit_disabled_with_zero(env, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_LOGIN_IP_MAX_FAILURES", "0")
    client, store, _sec = env
    for _ in range(5):
        assert _login(client, "no_such_user_xyz", "wrongpassword").status_code == 401


def test_ip_limit_ignores_spoofed_x_forwarded_for(monkeypatch: pytest.MonkeyPatch) -> None:
    """Behind the trusted proxy (Uvicorn --proxy-headers, Dockerfile.api defaults), rotating
    the client-supplied left-most X-Forwarded-For value does not escape the limit."""
    monkeypatch.setenv("ALFA_AI_LOGIN_IP_MAX_FAILURES", "3")
    store, sec = _MemUserStore(), _LockSecurity()
    user = store.seed(f"xff_{uuid.uuid4().hex[:8]}")
    app = ProxyHeadersMiddleware(
        _app(store, sec), trusted_hosts="127.0.0.1,10.0.0.0/8,172.16.0.0/12",
    )
    # Direct peer = nginx on the Docker bridge (trusted).
    client = TestClient(app, client=("apps", 40000))

    for i in range(3):
        r = _login(
            client, "no_such_user_xyz", "wrongpassword",
            headers={"X-Forwarded-For": f"6.6.6.{i}, 203.0.113.9"},
        )
        assert r.status_code == 401
    r = _login(
        client, user.username, PASSWORD,
        headers={"X-Forwarded-For": "6.6.6.99, 203.0.113.9"},
    )
    assert r.status_code == 429

    # A different real client behind the same proxy still gets in.
    r = _login(client, user.username, PASSWORD, headers={"X-Forwarded-For": "203.0.113.10"})
    assert r.status_code == 200, r.text


# ── 2FA attempt limit (org review 2026-09-25, low: "No 2FA attempt limit") ──

VERIFY_2FA = "/alfa-ai/api/auth/verify-2fa"


def _seed_2fa(store: _MemUserStore) -> tuple[UserRecord, pyotp.TOTP]:
    user = store.seed(f"tf_{uuid.uuid4().hex[:8]}")
    user.totp_secret = pyotp.random_base32()
    user.is_2fa_enabled = True
    return user, pyotp.TOTP(user.totp_secret)


def _wrong_code(totp: pyotp.TOTP) -> str:
    good = {totp.now(), totp.at(datetime.now(tz=UTC) - timedelta(seconds=30)),
            totp.at(datetime.now(tz=UTC) + timedelta(seconds=30))}
    return next(c for c in ("000000", "111111", "222222", "333333") if c not in good)


def _temp_token(client: TestClient, user: UserRecord) -> str:
    r = _login(client, user.username, PASSWORD)
    assert r.status_code == 200, r.text
    assert r.json()["requires_2fa"] is True
    return r.json()["temp_token"]


def test_2fa_correct_code_succeeds(env) -> None:
    client, store, sec = env
    user, totp = _seed_2fa(store)
    temp = _temp_token(client, user)
    r = client.post(VERIFY_2FA, json={"temp_token": temp, "code": totp.now()})
    assert r.status_code == 200, r.text
    assert r.json().get("access_token")


def test_2fa_wrong_codes_lock_account(env) -> None:
    client, store, sec = env
    user, totp = _seed_2fa(store)
    temp = _temp_token(client, user)
    bad = _wrong_code(totp)
    for _ in range(MAX_LOGIN_ATTEMPTS):
        r = client.post(VERIFY_2FA, json={"temp_token": temp, "code": bad})
        assert r.status_code == 401
    assert "2fa_locked" in sec.event_types()
    assert sec.is_account_locked(user.id)

    # Locked: even the right code is refused and no tokens are issued.
    r = client.post(VERIFY_2FA, json={"temp_token": temp, "code": totp.now()})
    assert r.status_code == 401
    assert "access_token" not in r.json()
    assert sec.event_types()[-1] == "2fa_locked_refused"
    assert "login_success" not in sec.event_types()


def test_2fa_failures_count_toward_ip_limit(env, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_LOGIN_IP_MAX_FAILURES", "3")
    client, store, sec = env
    user, totp = _seed_2fa(store)
    temp = _temp_token(client, user)
    bad = _wrong_code(totp)
    for _ in range(3):
        assert client.post(VERIFY_2FA, json={"temp_token": temp, "code": bad}).status_code == 401
    r = client.post(VERIFY_2FA, json={"temp_token": temp, "code": totp.now()})
    assert r.status_code == 429
    assert r.json()["detail"] == RATE_LIMIT_GENERIC
    assert r.headers.get("Retry-After")
