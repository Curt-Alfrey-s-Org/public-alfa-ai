"""Auth router: register, login, 2FA, JWT refresh, IP tracking & lockout.

Lockout + per-IP failed-login limit: docs/AUTH_ACCOUNT_LIFECYCLE.md.
"""

from __future__ import annotations

import logging
import secrets
from datetime import UTC, datetime, timedelta
from typing import Self
import re
import time

import bcrypt
import pyotp
from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import AliasChoices, BaseModel, EmailStr, Field, field_validator, model_validator

from src.api.deps import (
    create_2fa_pending_token,
    create_access_token,
    create_refresh_token,
    decode_token,
    get_current_user,
    get_security_store,
    get_user_store,
)
from src.api.admin_network import assert_admin_client_allowed, get_proxy_resolved_client_ip
from src.api.email_util import public_base_url, send_email
from src.api.login_rate_limit import (
    is_login_ip_limited,
    login_ip_window_sec,
    record_login_ip_failure,
)
from src.api.public_errors import (
    ACCOUNT_PENDING_APPROVAL_MSG,
    AUTH_FAILED_MSG,
    EMAIL_NOT_VERIFIED_MSG,
    INVALID_CREDENTIALS_MSG,
    RATE_LIMIT_GENERIC,
    REGISTRATION_FAILED_MSG,
)
from src.api.models.audit import (
    HONEYPOT_BLOCK_HOURS,
    HONEYPOT_USERNAME,
    LOGIN_WINDOW_MINUTES,
    MAX_LOGIN_ATTEMPTS,
    REGISTER_COOLDOWN_SEC,
    SecurityStore,
)
from src.api.models.user import UserRecord, UserStore

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/alfa-ai/api/auth", tags=["auth"])

_USERNAME_RE = re.compile(r"^[a-zA-Z0-9_-]{3,30}$")

# In-memory per-IP registration cooldown (survives within process lifetime)
_register_last_by_ip: dict[str, float] = {}

# docs/AUTH_ACCOUNT_LIFECYCLE.md: verify link lifetime.
EMAIL_VERIFY_TTL_HOURS = 24


# ── Request / response models ───────────────────────────────

class RegisterRequest(BaseModel):
    email: EmailStr
    username: str = Field(..., min_length=3, max_length=30)
    password: str = Field(..., min_length=8, max_length=128)


class VerifyEmailRequest(BaseModel):
    token: str = Field(..., min_length=10, max_length=200)


class ResendVerificationRequest(BaseModel):
    login: str = Field(..., min_length=1, max_length=254)


class LoginRequest(BaseModel):
    login: str = Field(
        ...,
        min_length=1,
        max_length=254,
        validation_alias=AliasChoices("login", "email"),
    )
    password: str

    @field_validator("login")
    @classmethod
    def login_not_blank(cls, v: str) -> str:
        stripped = v.strip()
        if not stripped:
            raise ValueError("Login is required")
        return stripped


class Verify2FARequest(BaseModel):
    temp_token: str
    code: str = Field(..., min_length=6, max_length=6)


class Enable2FARequest(BaseModel):
    code: str = Field(..., min_length=6, max_length=6)


class ChangePasswordRequest(BaseModel):
    current_password: str = Field(..., min_length=1, max_length=128)
    new_password: str = Field(..., min_length=8, max_length=128)
    new_password_confirm: str = Field(..., min_length=8, max_length=128)

    @model_validator(mode="after")
    def new_passwords_match(self) -> Self:
        if self.new_password != self.new_password_confirm:
            raise ValueError("New password and confirmation do not match")
        return self


class RefreshRequest(BaseModel):
    refresh_token: str


class UserOut(BaseModel):
    id: str
    email: str
    username: str
    is_admin: bool
    is_2fa_enabled: bool


# ── Helpers ──────────────────────────────────────────────────

def _user_out(u: UserRecord) -> dict:
    return UserOut(
        id=u.id,
        email=u.email,
        username=u.username,
        is_admin=u.has_role("admin"),
        is_2fa_enabled=u.is_2fa_enabled,
    ).model_dump()


# bcrypt only uses the first 72 bytes of a password. bcrypt>=5.0 raises ValueError
# instead of silently truncating, which turned any >72-byte password (the models allow
# up to 128 chars, more bytes with non-ASCII) into an unhandled 500 on register, login,
# change-password and admin set-password (round-2 review 2026-09-26).
BCRYPT_MAX_PASSWORD_BYTES = 72
PASSWORD_TOO_LONG_MSG = (
    f"Password is too long: at most {BCRYPT_MAX_PASSWORD_BYTES} bytes "
    "(fewer characters if it uses non-ASCII letters or emoji)."
)


def _hash_password(password: str) -> str:
    raw = password.encode()
    if len(raw) > BCRYPT_MAX_PASSWORD_BYTES:
        raise HTTPException(status_code=422, detail=PASSWORD_TOO_LONG_MSG)
    return bcrypt.hashpw(raw, bcrypt.gensalt()).decode()


def _verify_password(password: str, hashed: str) -> bool:
    # Truncate exactly like bcrypt<5 did, so hashes created before the bcrypt 5 pin
    # (from >72-byte passwords) still verify, and an over-long guess is a normal
    # wrong password (counted by the lockout) instead of a 500.
    return bcrypt.checkpw(password.encode()[:BCRYPT_MAX_PASSWORD_BYTES], hashed.encode())


def _get_client_ip(request: Request) -> str | None:
    forwarded = request.headers.get("x-forwarded-for")
    if forwarded:
        return forwarded.split(",")[0].strip()
    if request.client:
        return request.client.host
    return None


def _get_user_agent(request: Request) -> str | None:
    return request.headers.get("user-agent", "")[:512]


def _resolve_login_user(store: UserStore, login: str) -> UserRecord | None:
    """Look up user by email (contains @) or username."""
    if "@" in login:
        return store.get_by_email_ci(login)
    return store.get_by_username_ci(login)


def _honeypot_login_key(login: str) -> str:
    if "@" in login:
        return login.split("@")[0].lower()
    return login.lower()


def _new_verify_token() -> tuple[str, str]:
    """Returns (token, iso-expiry) per docs/AUTH_ACCOUNT_LIFECYCLE.md."""
    token = secrets.token_urlsafe(32)
    expires = (datetime.now(tz=UTC) + timedelta(hours=EMAIL_VERIFY_TTL_HOURS)).isoformat()
    return token, expires


def _send_verification_email(user: UserRecord, token: str) -> bool:
    """Same SMTP path as register. Returns send_email success (False if skipped/failed)."""
    link = f"{public_base_url()}/alfa-ai/verify-email?token={token}"
    subject = "Verify your ALFa AI account"
    body = (
        f"Hi {user.username},\n\n"
        "Click the link below to verify your email address:\n"
        f"{link}\n\n"
        f"This link expires in {EMAIL_VERIFY_TTL_HOURS} hours.\n"
        "After verifying, an administrator will review and activate your account.\n\n"
        "If you did not create this account, you can ignore this email."
    )
    return send_email(user.email, subject, body)


# ── Endpoints ────────────────────────────────────────────────

@router.post("/register")
def register(
    body: RegisterRequest,
    request: Request,
    store: UserStore = Depends(get_user_store),
    sec: SecurityStore = Depends(get_security_store),
) -> dict:
    ip = _get_client_ip(request)

    # Per-IP registration cooldown
    if ip:
        last = _register_last_by_ip.get(ip, 0)
        if time.time() - last < REGISTER_COOLDOWN_SEC:
            raise HTTPException(status_code=429, detail="Please wait before registering another account")

    if not _USERNAME_RE.match(body.username):
        raise HTTPException(
            status_code=422,
            detail="Username must be 3-30 chars: letters, digits, _ or -",
        )
    if store.get_by_email_ci(str(body.email).strip()):
        raise HTTPException(status_code=409, detail=REGISTRATION_FAILED_MSG)
    if store.get_by_username(body.username):
        raise HTTPException(status_code=409, detail=REGISTRATION_FAILED_MSG)

    password_hash = _hash_password(body.password)
    token, expires = _new_verify_token()
    user = store.create_user(
        email=body.email,
        username=body.username,
        password_hash=password_hash,
        role="user",
        email_verified=False,
        approved=False,
        email_verify_token=token,
        email_verify_expires=expires,
    )

    if ip:
        _register_last_by_ip[ip] = time.time()

    sec.record_event(
        event_type="register",
        success=True,
        user_id=user.id,
        ip_address=ip,
        user_agent=_get_user_agent(request),
    )
    logger.info("New user registered: %s (%s) from %s", user.username, user.email, ip)
    _send_verification_email(user, token)
    return {
        "user": _user_out(user),
        "message": (
            "Your account was created. If a confirmation email arrives, open the "
            "link to verify your address. If it does not arrive, an administrator "
            "can verify and approve your account. You cannot sign in until both "
            "email verification and admin approval are complete."
        ),
    }


@router.post("/verify-email")
def verify_email(
    body: VerifyEmailRequest,
    store: UserStore = Depends(get_user_store),
    sec: SecurityStore = Depends(get_security_store),
) -> dict:
    user = store.get_by_email_verify_token(body.token)
    if user is None:
        raise HTTPException(
            status_code=400,
            detail="This verification link is invalid or has expired.",
        )
    store.mark_email_verified(user.id)
    sec.record_event("email_verified", success=True, user_id=user.id)
    return {
        "ok": True,
        "message": "Email verified. An administrator will review your account before you can sign in.",
    }


@router.post("/resend-verification")
def resend_verification(
    body: ResendVerificationRequest,
    request: Request,
    store: UserStore = Depends(get_user_store),
) -> dict:
    """Always returns the same generic message so this cannot be used to probe
    which emails/usernames have registered accounts (docs/AUTH_ACCOUNT_LIFECYCLE.md)."""
    generic = {"ok": True, "message": "If that account exists and needs verification, a new link has been sent."}
    ip = _get_client_ip(request)
    cooldown_key = f"resend:{ip}" if ip else None
    if cooldown_key:
        last = _register_last_by_ip.get(cooldown_key, 0)
        if time.time() - last < REGISTER_COOLDOWN_SEC:
            return generic
        _register_last_by_ip[cooldown_key] = time.time()

    user = _resolve_login_user(store, body.login)
    if user is None or user.email_verified:
        return generic

    token, expires = _new_verify_token()
    store.set_email_verify_token(user.id, token, expires)
    _send_verification_email(user, token)
    return generic


@router.post("/login")
def login(
    body: LoginRequest,
    request: Request,
    store: UserStore = Depends(get_user_store),
    sec: SecurityStore = Depends(get_security_store),
) -> dict:
    ip = _get_client_ip(request)
    ua = _get_user_agent(request)
    # Per-IP failed-login limit keys on the Uvicorn trusted-proxy-resolved IP, never the
    # raw first X-Forwarded-For value (review finding 15 / medium finding 8).
    limit_ip = get_proxy_resolved_client_ip(request)

    # Check IP block (honeypot)
    if ip and sec.is_ip_blocked(ip):
        sec.record_event("honeypot_blocked_ip", success=False, ip_address=ip, user_agent=ua)
        raise HTTPException(status_code=401, detail=INVALID_CREDENTIALS_MSG)

    # Honeypot: login identifier matching the honeypot username pattern
    if _honeypot_login_key(body.login) == HONEYPOT_USERNAME:
        if ip:
            sec.block_ip(ip, reason="honeypot", hours=HONEYPOT_BLOCK_HOURS)
            sec.record_event(
                "honeypot_trapped", success=False,
                ip_address=ip, user_agent=ua,
                details=f"Tried login as {body.login}",
            )
            logger.warning("Honeypot triggered from %s (login: %s)", ip, body.login)
        raise HTTPException(status_code=401, detail=INVALID_CREDENTIALS_MSG)

    # Per-IP failed-login limit (docs/AUTH_ACCOUNT_LIFECYCLE.md). Checked before any
    # password verification so a limited client learns nothing about credentials.
    if is_login_ip_limited(limit_ip):
        logger.info("Login rate-limited for client IP %s", limit_ip)
        raise HTTPException(
            status_code=429,
            detail=RATE_LIMIT_GENERIC,
            headers={"Retry-After": str(login_ip_window_sec())},
        )

    user = _resolve_login_user(store, body.login)

    # Account lockout: an active lock refuses login even with the correct password,
    # until it expires or an admin clears it. The password is not checked, and the
    # response matches a wrong password so it reveals neither the lock nor whether
    # the password was right. Not counted as login_failed, so it does not extend the lock.
    if user is not None and sec.is_account_locked(user.id):
        sec.record_event(
            "login_locked_refused", success=False,
            user_id=user.id, ip_address=ip, user_agent=ua,
        )
        record_login_ip_failure(limit_ip)
        raise HTTPException(status_code=401, detail=INVALID_CREDENTIALS_MSG)

    if user is None or not _verify_password(body.password, user.password_hash):
        record_login_ip_failure(limit_ip)
        if user:
            sec.record_event(
                "login_failed", success=False,
                user_id=user.id, ip_address=ip, user_agent=ua,
            )
            # Check if we should lock the account
            failures = sec.count_recent_failures(user.id, LOGIN_WINDOW_MINUTES)
            if failures >= MAX_LOGIN_ATTEMPTS:
                sec.lock_account(user.id, LOGIN_WINDOW_MINUTES)
                sec.record_event(
                    "login_locked", success=False,
                    user_id=user.id, ip_address=ip, user_agent=ua,
                    details=f"Locked after {failures} failures in {LOGIN_WINDOW_MINUTES}min",
                )
                logger.warning("Account locked: %s from %s", user.email, ip)
        raise HTTPException(status_code=401, detail=INVALID_CREDENTIALS_MSG)

    if not user.is_active:
        sec.record_event("login_failed", success=False, user_id=user.id, ip_address=ip, user_agent=ua, details="Account deactivated")
        raise HTTPException(status_code=401, detail=INVALID_CREDENTIALS_MSG)

    # Account lifecycle gates (docs/AUTH_ACCOUNT_LIFECYCLE.md). Unlike is_active
    # above, these return distinct messages by explicit operator decision so new
    # users know exactly what to do next.
    if not user.email_verified:
        sec.record_event("login_failed", success=False, user_id=user.id, ip_address=ip, user_agent=ua, details="Email not verified")
        raise HTTPException(status_code=401, detail=EMAIL_NOT_VERIFIED_MSG)

    if not user.approved:
        sec.record_event("login_failed", success=False, user_id=user.id, ip_address=ip, user_agent=ua, details="Pending admin approval")
        raise HTTPException(status_code=401, detail=ACCOUNT_PENDING_APPROVAL_MSG)

    # Valid password and no active lock (refused above): reset the failed-attempt
    # counter and clear an expired lock. Never clears an active lock.
    sec.clear_expired_lock(user.id)

    if user.is_2fa_enabled:
        sec.record_event("login_2fa_pending", success=True, user_id=user.id, ip_address=ip, user_agent=ua)
        temp_token = create_2fa_pending_token(user.id, user.role)
        return {"requires_2fa": True, "temp_token": temp_token}

    assert_admin_client_allowed(request, role=user.role, public_context="login")

    sec.record_event("login_success", success=True, user_id=user.id, ip_address=ip, user_agent=ua)
    access = create_access_token(user.id, user.role)
    refresh = create_refresh_token(user.id, user.role)
    return {
        "access_token": access,
        "refresh_token": refresh,
        "user": _user_out(user),
    }


@router.post("/verify-2fa")
def verify_2fa(
    body: Verify2FARequest,
    request: Request,
    store: UserStore = Depends(get_user_store),
    sec: SecurityStore = Depends(get_security_store),
) -> dict:
    ip = _get_client_ip(request)
    ua = _get_user_agent(request)
    # Same per-IP failed-attempt budget as /login (shared counter), keyed on the
    # trusted-proxy-resolved IP. Checked before the code is verified.
    limit_ip = get_proxy_resolved_client_ip(request)
    if is_login_ip_limited(limit_ip):
        logger.info("2FA verify rate-limited for client IP %s", limit_ip)
        raise HTTPException(
            status_code=429,
            detail=RATE_LIMIT_GENERIC,
            headers={"Retry-After": str(login_ip_window_sec())},
        )

    payload = decode_token(body.temp_token)
    if payload.get("type") != "2fa_pending":
        raise HTTPException(status_code=401, detail=AUTH_FAILED_MSG)

    user = store.get_by_id(payload["sub"])
    if user is None or not user.is_active:
        raise HTTPException(status_code=401, detail=AUTH_FAILED_MSG)
    if not user.totp_secret:
        raise HTTPException(status_code=401, detail=AUTH_FAILED_MSG)

    # 2FA attempt limit (org review 2026-09-25): a 5-minute 2fa_pending token must not
    # allow unlimited code guesses. A locked account is refused without checking the
    # code; MAX_LOGIN_ATTEMPTS wrong codes within LOGIN_WINDOW_MINUTES lock the account
    # exactly like wrong passwords do (admin unlock clears it).
    if sec.is_account_locked(user.id):
        sec.record_event("2fa_locked_refused", success=False, user_id=user.id, ip_address=ip, user_agent=ua)
        record_login_ip_failure(limit_ip)
        raise HTTPException(status_code=401, detail=AUTH_FAILED_MSG)

    totp = pyotp.TOTP(user.totp_secret)
    if not totp.verify(body.code):
        sec.record_event("2fa_failed", success=False, user_id=user.id, ip_address=ip, user_agent=ua)
        record_login_ip_failure(limit_ip)
        failures = sec.count_recent_failures(
            user.id, LOGIN_WINDOW_MINUTES, event_type="2fa_failed",
        )
        if failures >= MAX_LOGIN_ATTEMPTS:
            sec.lock_account(user.id, LOGIN_WINDOW_MINUTES)
            sec.record_event(
                "2fa_locked", success=False,
                user_id=user.id, ip_address=ip, user_agent=ua,
                details=f"Locked after {failures} failed 2FA codes in {LOGIN_WINDOW_MINUTES}min",
            )
            logger.warning("Account locked after failed 2FA codes: %s from %s", user.email, ip)
        raise HTTPException(status_code=401, detail=AUTH_FAILED_MSG)

    assert_admin_client_allowed(request, role=user.role, public_context="login")

    sec.record_event("login_success", success=True, user_id=user.id, ip_address=ip, user_agent=ua, details="via 2FA")
    access = create_access_token(user.id, user.role)
    refresh = create_refresh_token(user.id, user.role)
    return {
        "access_token": access,
        "refresh_token": refresh,
        "user": _user_out(user),
    }


@router.post("/refresh")
def refresh(body: RefreshRequest, request: Request) -> dict:
    payload = decode_token(body.refresh_token)
    if payload.get("type") != "refresh":
        raise HTTPException(status_code=401, detail=AUTH_FAILED_MSG)

    store = get_user_store()
    user = store.get_by_id(payload["sub"])
    if user is None or not user.is_active or not user.email_verified or not user.approved:
        raise HTTPException(status_code=401, detail=AUTH_FAILED_MSG)

    assert_admin_client_allowed(request, role=user.role, public_context="login")

    access = create_access_token(user.id, user.role)
    return {"access_token": access}


@router.get("/me")
def me(user: UserRecord = Depends(get_current_user)) -> dict:
    return {"user": _user_out(user)}


@router.post("/setup-2fa")
def setup_2fa(user: UserRecord = Depends(get_current_user)) -> dict:
    # Re-running setup replaces the secret with enabled=False, i.e. it switches 2FA
    # off. Without this guard any holder of an access token could silently disable
    # an enrolled user's 2FA (round-2 review 2026-09-26). The UI only offers setup
    # when 2FA is off; an admin password reset clears 2FA for device changes.
    if user.is_2fa_enabled:
        raise HTTPException(status_code=409, detail="2FA is already enabled")
    secret = pyotp.random_base32()
    provisioning_uri = pyotp.TOTP(secret).provisioning_uri(
        name=user.email,
        issuer_name="ALFa AI",
    )
    store = get_user_store()
    store.update_totp(user.id, secret, enabled=False)
    return {"secret": secret, "provisioning_uri": provisioning_uri}


@router.post("/enable-2fa")
def enable_2fa(
    body: Enable2FARequest,
    user: UserRecord = Depends(get_current_user),
) -> dict:
    store = get_user_store()
    fresh = store.get_by_id(user.id)
    if fresh is None or not fresh.totp_secret:
        raise HTTPException(status_code=400, detail="Run setup-2fa first")

    totp = pyotp.TOTP(fresh.totp_secret)
    if not totp.verify(body.code):
        raise HTTPException(status_code=400, detail="Invalid code — scan the QR and try again")

    store.update_totp(user.id, fresh.totp_secret, enabled=True)
    return {"message": "2FA enabled successfully"}


@router.post("/change-password")
def change_password(
    body: ChangePasswordRequest,
    request: Request,
    user: UserRecord = Depends(get_current_user),
    store: UserStore = Depends(get_user_store),
    sec: SecurityStore = Depends(get_security_store),
) -> dict:
    """Authenticated user updates their own password (requires current password)."""
    ip = _get_client_ip(request)
    ua = _get_user_agent(request)
    fresh = store.get_by_id(user.id)
    if fresh is None:
        raise HTTPException(status_code=401, detail="User not found")
    if not _verify_password(body.current_password, fresh.password_hash):
        sec.record_event(
            "password_change_failed",
            success=False,
            user_id=user.id,
            ip_address=ip,
            user_agent=ua,
            details="wrong current password",
        )
        raise HTTPException(status_code=400, detail="Current password is incorrect")
    if body.new_password == body.current_password:
        raise HTTPException(status_code=400, detail="New password must differ from current password")
    store.set_password_for_user(user.id, _hash_password(body.new_password))
    sec.record_event(
        "password_changed",
        success=True,
        user_id=user.id,
        ip_address=ip,
        user_agent=ua,
    )
    return {"ok": True, "message": "Password updated"}
