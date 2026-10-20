"""Audit log and IP block persistence (psycopg3, matches rankings-bot patterns)."""

from __future__ import annotations

import logging
import uuid
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta

import psycopg
from psycopg.rows import dict_row

logger = logging.getLogger(__name__)


def _now() -> datetime:
    return datetime.now(tz=UTC)


def _now_iso() -> str:
    return _now().isoformat()


# ── Thresholds (match rankings-bot) ─────────────────────────
# Account lockout: MAX_LOGIN_ATTEMPTS wrong passwords within LOGIN_WINDOW_MINUTES lock
# the account for LOGIN_WINDOW_MINUTES (enforced in routers/auth.py login; see
# docs/AUTH_ACCOUNT_LIFECYCLE.md). Per-IP failed-login limit: src/api/login_rate_limit.py.
MAX_LOGIN_ATTEMPTS = 5
LOGIN_WINDOW_MINUTES = 15
HONEYPOT_USERNAME = "admin"
HONEYPOT_BLOCK_HOURS = 720  # 30 days
REGISTER_COOLDOWN_SEC = 120

# ── Data classes ─────────────────────────────────────────────

@dataclass(slots=True)
class AuditEntry:
    id: str
    user_id: str | None
    event_type: str
    ip_address: str | None
    user_agent: str | None
    success: bool
    details: str | None
    created_at: str = field(default_factory=_now_iso)


@dataclass(slots=True)
class IpBlock:
    id: str
    ip_address: str
    reason: str
    blocked_at: str
    expires_at: str | None


# ── DDL ──────────────────────────────────────────────────────

_CREATE_AUDIT_LOG = """\
CREATE TABLE IF NOT EXISTS audit_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    event_type TEXT NOT NULL,
    ip_address TEXT,
    user_agent TEXT,
    success BOOLEAN NOT NULL DEFAULT FALSE,
    details TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_audit_log_user_id ON audit_log (user_id);
CREATE INDEX IF NOT EXISTS idx_audit_log_event_type ON audit_log (event_type);
CREATE INDEX IF NOT EXISTS idx_audit_log_ip ON audit_log (ip_address);
CREATE INDEX IF NOT EXISTS idx_audit_log_created ON audit_log (created_at);
"""

_CREATE_IP_BLOCKS = """\
CREATE TABLE IF NOT EXISTS ip_blocks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    ip_address TEXT NOT NULL,
    reason TEXT NOT NULL DEFAULT 'honeypot',
    blocked_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_ip_blocks_ip ON ip_blocks (ip_address);
"""

_ALTER_USERS_LOCKOUT = """\
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'users' AND column_name = 'failed_login_attempts'
    ) THEN
        ALTER TABLE users ADD COLUMN failed_login_attempts INTEGER NOT NULL DEFAULT 0;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'users' AND column_name = 'account_locked_until'
    ) THEN
        ALTER TABLE users ADD COLUMN account_locked_until TIMESTAMPTZ;
    END IF;
END $$;
"""


class SecurityStore:
    """Audit log, IP blocks, and account lockout queries."""

    def __init__(self, database_url: str) -> None:
        self.database_url = database_url
        self._ensure_tables()

    def _conn(self):
        from src.api.db_pool import db_connection
        return db_connection(self.database_url)

    def _ensure_tables(self) -> None:
        try:
            with self._conn() as conn:
                conn.execute(_ALTER_USERS_LOCKOUT)
                conn.execute(_CREATE_AUDIT_LOG)
                conn.execute(_CREATE_IP_BLOCKS)
                conn.commit()
        except Exception:
            logger.exception("Failed to ensure security tables")
            raise

    # ── Audit log ────────────────────────────────────────────

    def record_event(
        self,
        event_type: str,
        success: bool,
        user_id: str | None = None,
        ip_address: str | None = None,
        user_agent: str | None = None,
        details: str | None = None,
    ) -> None:
        entry_id = str(uuid.uuid4())
        with self._conn() as conn:
            conn.execute(
                """
                INSERT INTO audit_log (id, user_id, event_type, ip_address, user_agent, success, details)
                VALUES (%s, %s::uuid, %s, %s, %s, %s, %s)
                """,
                (entry_id, user_id, event_type, ip_address, user_agent, success, details),
            )
            conn.commit()

    def count_recent_failures(
        self,
        user_id: str,
        window_minutes: int = LOGIN_WINDOW_MINUTES,
        event_type: str = "login_failed",
    ) -> int:
        """Count *event_type* audit rows for *user_id* in the window.

        ``login_failed`` (wrong password) drives the login lockout; ``2fa_failed``
        drives the 2FA attempt limit in routers/auth.py verify_2fa.
        """
        cutoff = _now() - timedelta(minutes=window_minutes)
        with self._conn() as conn:
            row = conn.execute(
                """
                SELECT count(*) AS cnt FROM audit_log
                WHERE user_id = %s::uuid
                  AND event_type = %s
                  AND created_at >= %s
                """,
                (user_id, event_type, cutoff),
            ).fetchone()
        return int(row["cnt"]) if row else 0

    def recent_events(self, limit: int = 50) -> list[dict]:
        with self._conn() as conn:
            rows = conn.execute(
                """
                SELECT a.*, u.email, u.username
                FROM audit_log a
                LEFT JOIN users u ON a.user_id = u.id
                ORDER BY a.created_at DESC
                LIMIT %s
                """,
                (limit,),
            ).fetchall()
        return [dict(r) for r in rows]

    # ── IP blocks ────────────────────────────────────────────

    def is_ip_blocked(self, ip_address: str) -> bool:
        now = _now()
        with self._conn() as conn:
            row = conn.execute(
                """
                SELECT 1 FROM ip_blocks
                WHERE ip_address = %s
                  AND (expires_at IS NULL OR expires_at > %s)
                LIMIT 1
                """,
                (ip_address, now),
            ).fetchone()
        return row is not None

    def block_ip(self, ip_address: str, reason: str = "honeypot", hours: int = HONEYPOT_BLOCK_HOURS) -> None:
        block_id = str(uuid.uuid4())
        now = _now()
        expires = now + timedelta(hours=hours)
        with self._conn() as conn:
            conn.execute(
                """
                INSERT INTO ip_blocks (id, ip_address, reason, blocked_at, expires_at)
                VALUES (%s, %s, %s, %s, %s)
                ON CONFLICT DO NOTHING
                """,
                (block_id, ip_address, reason, now, expires),
            )
            conn.commit()

    def list_ip_blocks(self) -> list[dict]:
        with self._conn() as conn:
            rows = conn.execute(
                "SELECT * FROM ip_blocks ORDER BY blocked_at DESC LIMIT 100"
            ).fetchall()
        return [dict(r) for r in rows]

    # ── Account lockout ──────────────────────────────────────

    def lock_account(self, user_id: str, minutes: int = LOGIN_WINDOW_MINUTES) -> None:
        locked_until = _now() + timedelta(minutes=minutes)
        with self._conn() as conn:
            conn.execute(
                """
                UPDATE users
                SET account_locked_until = %s, failed_login_attempts = 0, updated_at = %s
                WHERE id = %s::uuid
                """,
                (locked_until, _now_iso(), user_id),
            )
            conn.commit()

    def is_account_locked(self, user_id: str) -> bool:
        with self._conn() as conn:
            row = conn.execute(
                "SELECT account_locked_until FROM users WHERE id = %s::uuid",
                (user_id,),
            ).fetchone()
        if row is None or row["account_locked_until"] is None:
            return False
        locked_until = row["account_locked_until"]
        if hasattr(locked_until, "tzinfo") and locked_until.tzinfo is None:
            from datetime import timezone
            locked_until = locked_until.replace(tzinfo=timezone.utc)
        return locked_until > _now()

    def clear_expired_lock(self, user_id: str) -> None:
        """After a successful login: reset the counter and clear a lock only if it has expired.

        Unlike :meth:`reset_failed_attempts` (admin unlock), this never clears an active lock,
        so a correct password cannot undo a lockout (review finding 15).
        """
        now = _now()
        with self._conn() as conn:
            conn.execute(
                """
                UPDATE users
                SET failed_login_attempts = 0, account_locked_until = NULL, updated_at = %s
                WHERE id = %s::uuid
                  AND (account_locked_until IS NULL OR account_locked_until <= %s)
                """,
                (_now_iso(), user_id, now),
            )
            conn.commit()

    def reset_failed_attempts(self, user_id: str) -> None:
        """Clear failed-attempt state and any lock, active or not (admin unlock / password reset)."""
        with self._conn() as conn:
            conn.execute(
                "UPDATE users SET failed_login_attempts = 0, account_locked_until = NULL, updated_at = %s WHERE id = %s::uuid",
                (_now_iso(), user_id),
            )
            conn.commit()
