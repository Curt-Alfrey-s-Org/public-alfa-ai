"""User model and Postgres store (psycopg3, consistent with runtime.store)."""

from __future__ import annotations

import logging
import re
import uuid
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Any, Literal

import bcrypt
import psycopg
from psycopg.rows import dict_row

logger = logging.getLogger(__name__)

UserRole = Literal["guest", "user", "admin"]

_ROLE_HIERARCHY: dict[UserRole, int] = {"guest": 0, "user": 1, "admin": 2}


def _now_iso() -> str:
    return datetime.now(tz=UTC).isoformat()


@dataclass(slots=True)
class UserRecord:
    id: str
    email: str
    username: str
    password_hash: str
    role: UserRole = "user"
    totp_secret: str | None = None
    is_2fa_enabled: bool = False
    is_active: bool = True
    # Account lifecycle gates (docs/AUTH_ACCOUNT_LIFECYCLE.md). Default True so
    # code paths that build a UserRecord without these (tests, bootstrap admin)
    # are never accidentally locked out.
    email_verified: bool = True
    approved: bool = True
    created_at: str = field(default_factory=_now_iso)
    updated_at: str = field(default_factory=_now_iso)

    def has_role(self, required: UserRole) -> bool:
        return _ROLE_HIERARCHY.get(self.role, 0) >= _ROLE_HIERARCHY.get(required, 0)


_CREATE_USERS_TABLE = """\
CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email TEXT NOT NULL,
    username TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT 'user'
        CHECK (role IN ('guest', 'user', 'admin')),
    totp_secret TEXT,
    is_2fa_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_users_email ON users (email);
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_username ON users (username);

-- Account lifecycle (docs/AUTH_ACCOUNT_LIFECYCLE.md). Backfilled TRUE for
-- existing rows so no currently-active account is retroactively locked out;
-- only new self-registrations explicitly insert FALSE for both.
ALTER TABLE users ADD COLUMN IF NOT EXISTS email_verified BOOLEAN NOT NULL DEFAULT TRUE;
ALTER TABLE users ADD COLUMN IF NOT EXISTS email_verify_token TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS email_verify_expires TIMESTAMPTZ;
ALTER TABLE users ADD COLUMN IF NOT EXISTS approved BOOLEAN NOT NULL DEFAULT TRUE;
ALTER TABLE users ADD COLUMN IF NOT EXISTS approved_by TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS approved_at TIMESTAMPTZ;
CREATE INDEX IF NOT EXISTS idx_users_email_verify_token ON users (email_verify_token);
"""


class UserStore:
    """Thin Postgres persistence for user accounts (mirrors RuntimeStore pattern)."""

    def __init__(self, database_url: str) -> None:
        self.database_url = database_url
        self._ensure_table()

    def _conn(self):
        from src.api.db_pool import db_connection
        return db_connection(self.database_url)

    def _ensure_table(self) -> None:
        try:
            with self._conn() as conn:
                conn.execute(_CREATE_USERS_TABLE)
                conn.commit()
        except Exception:
            logger.exception("Failed to ensure users table")
            raise

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
        email_norm = (email or "").strip().lower()
        user_id = str(uuid.uuid4())
        now = _now_iso()
        with self._conn() as conn:
            conn.execute(
                """
                INSERT INTO users (
                    id, email, username, password_hash, role,
                    email_verified, email_verify_token, email_verify_expires,
                    approved, created_at, updated_at
                )
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                """,
                (
                    user_id, email_norm, username, password_hash, role,
                    email_verified, email_verify_token, email_verify_expires,
                    approved, now, now,
                ),
            )
            conn.commit()
        return UserRecord(
            id=user_id,
            email=email_norm,
            username=username,
            password_hash=password_hash,
            role=role,
            email_verified=email_verified,
            approved=approved,
            created_at=now,
            updated_at=now,
        )

    def get_by_email_verify_token(self, token: str) -> UserRecord | None:
        """Only returns a row while the token is unexpired (docs/AUTH_ACCOUNT_LIFECYCLE.md)."""
        if not token:
            return None
        with self._conn() as conn:
            row = conn.execute(
                """
                SELECT * FROM users
                WHERE email_verify_token = %s AND email_verify_expires > NOW()
                """,
                (token,),
            ).fetchone()
        return self._row_to_record(row) if row else None

    def mark_email_verified(self, user_id: str) -> None:
        with self._conn() as conn:
            conn.execute(
                """
                UPDATE users
                SET email_verified = TRUE, email_verify_token = NULL,
                    email_verify_expires = NULL, updated_at = NOW()
                WHERE id = %s::uuid
                """,
                (user_id,),
            )
            conn.commit()

    def set_email_verify_token(self, user_id: str, token: str, expires: str) -> None:
        with self._conn() as conn:
            conn.execute(
                """
                UPDATE users
                SET email_verify_token = %s, email_verify_expires = %s, updated_at = NOW()
                WHERE id = %s::uuid
                """,
                (token, expires, user_id),
            )
            conn.commit()

    def set_approved(self, user_id: str, approved: bool, *, approved_by: str | None = None) -> None:
        with self._conn() as conn:
            conn.execute(
                """
                UPDATE users
                SET approved = %s,
                    approved_by = %s,
                    approved_at = CASE WHEN %s THEN NOW() ELSE approved_at END,
                    updated_at = NOW()
                WHERE id = %s::uuid
                """,
                (approved, approved_by, approved, user_id),
            )
            conn.commit()

    def get_by_email(self, email: str) -> UserRecord | None:
        with self._conn() as conn:
            row = conn.execute(
                "SELECT * FROM users WHERE email = %s",
                (email,),
            ).fetchone()
        return self._row_to_record(row) if row else None

    def get_by_email_ci(self, email: str) -> UserRecord | None:
        """Case-insensitive email match (helps operators who mis-capitalize)."""
        with self._conn() as conn:
            row = conn.execute(
                "SELECT * FROM users WHERE LOWER(email) = LOWER(%s)",
                (email.strip(),),
            ).fetchone()
        return self._row_to_record(row) if row else None

    def get_by_username(self, username: str) -> UserRecord | None:
        with self._conn() as conn:
            row = conn.execute(
                "SELECT * FROM users WHERE username = %s",
                (username,),
            ).fetchone()
        return self._row_to_record(row) if row else None

    def get_by_username_ci(self, username: str) -> UserRecord | None:
        """Case-insensitive username match (mirrors get_by_email_ci)."""
        with self._conn() as conn:
            row = conn.execute(
                "SELECT * FROM users WHERE LOWER(username) = LOWER(%s)",
                (username.strip(),),
            ).fetchone()
        return self._row_to_record(row) if row else None

    def get_by_id(self, user_id: str) -> UserRecord | None:
        from src.api.uuid_util import parse_uuid

        uid = parse_uuid(user_id)
        if uid is None:
            return None
        with self._conn() as conn:
            row = conn.execute(
                "SELECT * FROM users WHERE id = %s",
                (uid,),
            ).fetchone()
        return self._row_to_record(row) if row else None

    def update_totp(self, user_id: str, totp_secret: str | None, enabled: bool) -> None:
        with self._conn() as conn:
            conn.execute(
                """
                UPDATE users
                SET totp_secret = %s, is_2fa_enabled = %s, updated_at = %s
                WHERE id = %s::uuid
                """,
                (totp_secret, enabled, _now_iso(), user_id),
            )
            conn.commit()

    def count(self) -> int:
        with self._conn() as conn:
            row = conn.execute("SELECT count(*) AS cnt FROM users").fetchone()
        return int(row["cnt"]) if row else 0

    def update_password_hash(self, user_id: str, password_hash: str) -> None:
        now = _now_iso()
        with self._conn() as conn:
            conn.execute(
                """
                UPDATE users
                SET password_hash = %s, updated_at = %s
                WHERE id = %s::uuid
                """,
                (password_hash, now, user_id),
            )
            conn.commit()

    def set_password_for_user(self, user_id: str, password_hash: str) -> None:
        """
        Set password hash, disable 2FA (admin reset / self-service), clear lockout columns if present.
        """
        with self._conn() as conn:
            with conn.cursor(row_factory=dict_row) as cur:
                cur.execute(
                    """
                    SELECT column_name FROM information_schema.columns
                    WHERE table_schema = 'public' AND table_name = 'users'
                      AND column_name IN ('failed_login_attempts', 'account_locked_until')
                    """
                )
                lock_names = {r["column_name"] for r in cur.fetchall()}
            sets = [
                "password_hash = %s",
                "totp_secret = NULL",
                "is_2fa_enabled = FALSE",
                "updated_at = NOW()",
            ]
            params: list[Any] = [password_hash]
            if "failed_login_attempts" in lock_names:
                sets.append("failed_login_attempts = 0")
            if "account_locked_until" in lock_names:
                sets.append("account_locked_until = NULL")
            params.append(user_id)
            sql = f"UPDATE users SET {', '.join(sets)} WHERE id = %s::uuid"
            with conn.cursor() as cur2:
                cur2.execute(sql, params)
            conn.commit()

    def list_admin_users(self, limit: int = 20) -> list[UserRecord]:
        """Return users with role admin (for operator diagnostics / password reset)."""
        with self._conn() as conn:
            rows = conn.execute(
                """
                SELECT * FROM users
                WHERE role = 'admin' AND is_active = TRUE
                ORDER BY created_at ASC
                LIMIT %s
                """,
                (limit,),
            ).fetchall()
        return [self._row_to_record(r) for r in rows]

    def _allocate_unique_username(self, base: str) -> str:
        """Username must match auth registration: ^[a-zA-Z0-9_-]{3,30}$."""
        raw = re.sub(r"[^a-zA-Z0-9_-]", "_", (base or "admin").strip())
        raw = raw.strip("_") or "admin"
        raw = raw[:24]
        for i in range(0, 80):
            cand = raw if i == 0 else f"{raw}_{i}"
            if len(cand) > 30:
                cand = f"{raw[:20]}_{i}"
            if len(cand) < 3:
                cand = f"u_{cand}_{i}"
            cand = cand[:30]
            if self.get_by_username(cand) is None:
                return cand
        return f"adm_{uuid.uuid4().hex[:12]}"

    def ensure_primary_admin_by_email(self, email: str) -> bool:
        """
        If a row exists for this email (case-insensitive), set role=admin and is_active=TRUE.
        Does not create users or change passwords.
        """
        e = (email or "").strip().lower()
        if not e:
            return False
        user = self.get_by_email_ci(e)
        if user is None:
            return False
        if user.role == "admin" and user.is_active:
            return True
        with self._conn() as conn:
            conn.execute(
                """
                UPDATE users
                SET role = 'admin', is_active = TRUE, updated_at = NOW()
                WHERE LOWER(email) = LOWER(%s)
                """,
                (e,),
            )
            conn.commit()
        logger.info("Primary admin: set role=admin, is_active=TRUE for %s", e)
        return True

    def ensure_primary_admin(
        self,
        email: str,
        initial_password: str,
        *,
        default_username: str = "example",
    ) -> None:
        """
        Ensure the primary admin account exists with admin role.

        * If no user row for ``email``: create one with ``initial_password`` (bcrypt)
          and role admin. Does not run if password is shorter than 8 characters.
        * If the user exists: only promote to admin / active; **never** overwrites password.
        """
        e = (email or "").strip().lower()
        pw = (initial_password or "").strip()
        if not e:
            return
        if len(pw) < 8:
            logger.warning("Primary admin bootstrap skipped: initial password must be 8+ characters")
            return
        if len(pw.encode()) > 72:
            # bcrypt>=5 raises ValueError above 72 bytes; skip instead of crashing startup.
            logger.warning("Primary admin bootstrap skipped: initial password must be at most 72 bytes")
            return
        if self.get_by_email_ci(e) is not None:
            self.ensure_primary_admin_by_email(e)
            return
        pw_hash = bcrypt.hashpw(pw.encode(), bcrypt.gensalt()).decode()
        uname = self._allocate_unique_username(default_username)
        self.create_user(email=e, username=uname, password_hash=pw_hash, role="admin")
        logger.info(
            "Primary admin: created %s (username=%s) with bootstrap password — change after login.",
            e,
            uname,
        )

    @staticmethod
    def _row_to_record(row: dict) -> UserRecord:
        return UserRecord(
            id=str(row["id"]),
            email=row["email"],
            username=row["username"],
            password_hash=row["password_hash"],
            role=row["role"],
            totp_secret=row.get("totp_secret"),
            is_2fa_enabled=bool(row.get("is_2fa_enabled", False)),
            is_active=bool(row.get("is_active", True)),
            email_verified=bool(row.get("email_verified", True)),
            approved=bool(row.get("approved", True)),
            created_at=str(row.get("created_at", "")),
            updated_at=str(row.get("updated_at", "")),
        )
