#!/usr/bin/env python3
"""
Reset the web admin password (bcrypt hash in Postgres) for /alfa-ai/* JWT login.

Brain = primary ALFa AI Docker stack on hub (hub), not apps-105.
Canonical primary admin: operator@example.com. Bootstrap on API startup
runs only when ALFA_AI_PRIMARY_ADMIN_PASSWORD is set in deploy/.env (no source-shipped
default anymore — see audit FASTAPI-001 / TF-001). When the env var is missing the API
logs a WARNING and skips bootstrap; this script is the manual fallback.

Run on that host inside the alfa-ai-api container (uses DATABASE_URL from the container env):

  cd deploy
  docker compose build alfa-ai-api
  docker compose up -d alfa-ai-api
  docker compose exec -e ALFA_AI_ADMIN_NEW_PASSWORD='change-me' alfa-ai-api \\
    python /app/scripts/reset_admin_password.py operator@example.com

If the file is missing in an old image:  docker cp scripts/reset_admin_password.py alfa-ai-api:/app/scripts/
  then re-run the exec line (no rebuild).

Omit the email argument to print active admin accounts (email + username) and exit 1.

Also clears 2FA (totp_secret, is_2fa_enabled) and account lockout columns when present,
so the operator can sign in immediately.

Security: pass the new password only via ALFA_AI_ADMIN_NEW_PASSWORD (never on argv).
Minimum length 8 (same as public registration).
"""

from __future__ import annotations

import os
import sys

import bcrypt
import psycopg
from psycopg.rows import dict_row


def _hash_password(password: str) -> str:
    return bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()


def _database_url() -> str:
    url = (os.environ.get("DATABASE_URL") or "").strip()
    if not url:
        raise SystemExit("DATABASE_URL is not set (run inside alfa-ai-api container).")
    return url


def _new_password() -> str:
    pw = (os.environ.get("ALFA_AI_ADMIN_NEW_PASSWORD") or "").strip()
    if len(pw) < 8:
        raise SystemExit(
            "Set ALFA_AI_ADMIN_NEW_PASSWORD to a new password (8+ characters). "
            "Example: docker compose exec -e ALFA_AI_ADMIN_NEW_PASSWORD='...' alfa-ai-api python ..."
        )
    return pw


def _list_admins(conn: psycopg.Connection) -> list[dict]:
    with conn.cursor(row_factory=dict_row) as cur:
        cur.execute(
            """
            SELECT id, email, username, role, is_active, created_at
            FROM users
            WHERE role = 'admin' AND is_active = TRUE
            ORDER BY created_at ASC
            """
        )
        rows = cur.fetchall()
    return [dict(r) for r in rows]


def _resolve_user(conn: psycopg.Connection, token: str) -> dict | None:
    t = token.strip()
    with conn.cursor(row_factory=dict_row) as cur:
        cur.execute(
            "SELECT * FROM users WHERE LOWER(email) = LOWER(%s)",
            (t,),
        )
        row = cur.fetchone()
        if row:
            return dict(row)
        cur.execute(
            "SELECT * FROM users WHERE username = %s",
            (t,),
        )
        row = cur.fetchone()
    return dict(row) if row else None


def main() -> None:
    db_url = _database_url()
    target = (sys.argv[1] if len(sys.argv) > 1 else "").strip()

    with psycopg.connect(db_url, row_factory=dict_row) as conn:
        if not target:
            admins = _list_admins(conn)
            if not admins:
                raise SystemExit("No active admin users found. Register one or fix the database.")
            print("Active admin accounts (pass email or username as first argument):")
            for a in admins:
                print(f"  {a['email']}\t{a['username']}\tuid={a['id']}")
            raise SystemExit(1)

        user = _resolve_user(conn, target)
        if user is None:
            raise SystemExit(f"No user matched {target!r} (email or username).")
        if user.get("role") != "admin":
            raise SystemExit(
                f"User {user.get('email')} has role {user.get('role')!r}, not 'admin'. "
                "Promote in Postgres or use an admin account."
            )

        pw_hash = _hash_password(_new_password())

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
            "password_hash = %(ph)s",
            "updated_at = NOW()",
            "totp_secret = NULL",
            "is_2fa_enabled = FALSE",
        ]
        params: dict = {"ph": pw_hash, "uid": str(user["id"])}
        if "failed_login_attempts" in lock_names:
            sets.append("failed_login_attempts = 0")
        if "account_locked_until" in lock_names:
            sets.append("account_locked_until = NULL")

        sql = f"UPDATE users SET {', '.join(sets)} WHERE id = %(uid)s::uuid"
        with conn.cursor() as cur:
            cur.execute(sql, params)
        conn.commit()

    print(
        f"Password reset for admin {user['email']} ({user['username']}). "
        "Sign in at /alfa-ai/ with that email and ALFA_AI_ADMIN_NEW_PASSWORD."
    )


if __name__ == "__main__":
    main()
