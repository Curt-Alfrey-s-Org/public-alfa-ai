"""Persistence for admin AI host action proposals and execution results."""

from __future__ import annotations

import json
import logging
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

import psycopg
from psycopg.rows import dict_row

logger = logging.getLogger(__name__)

STATUS_PENDING = "pending"
STATUS_REJECTED = "rejected"
STATUS_EXECUTED = "executed"
STATUS_FAILED = "failed"


def _now_iso() -> str:
    return datetime.now(tz=UTC).isoformat()


@dataclass(slots=True)
class HostActionRecord:
    id: str
    action_key: str
    host: str
    params: dict[str, Any]
    status: str
    summary: str
    command_run: str | None
    stdout: str | None
    stderr: str | None
    exit_code: int | None
    proposed_by: str
    reviewed_by: str | None
    created_at: str
    executed_at: str | None


_CREATE_HOST_ACTIONS_TABLE = """\
CREATE TABLE IF NOT EXISTS ai_host_actions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    action_key TEXT NOT NULL,
    host TEXT NOT NULL,
    params JSONB NOT NULL DEFAULT '{}'::jsonb,
    status TEXT NOT NULL DEFAULT 'pending',
    summary TEXT NOT NULL DEFAULT '',
    command_run TEXT,
    stdout TEXT,
    stderr TEXT,
    exit_code INTEGER,
    proposed_by TEXT NOT NULL DEFAULT 'ai',
    reviewed_by TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    executed_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_ai_host_actions_status ON ai_host_actions (status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ai_host_actions_created ON ai_host_actions (created_at DESC);
"""


def _row_to_record(row: dict[str, Any]) -> HostActionRecord:
    created_at = row["created_at"]
    executed_at = row.get("executed_at")
    return HostActionRecord(
        id=str(row["id"]),
        action_key=row["action_key"],
        host=row["host"],
        params=row.get("params") or {},
        status=row["status"],
        summary=row.get("summary") or "",
        command_run=row.get("command_run"),
        stdout=row.get("stdout"),
        stderr=row.get("stderr"),
        exit_code=row.get("exit_code"),
        proposed_by=row.get("proposed_by") or "ai",
        reviewed_by=row.get("reviewed_by"),
        created_at=created_at.isoformat() if hasattr(created_at, "isoformat") else str(created_at),
        executed_at=(
            executed_at.isoformat()
            if executed_at is not None and hasattr(executed_at, "isoformat")
            else (str(executed_at) if executed_at else None)
        ),
    )


class HostActionStore:
    """Postgres persistence for curated host action proposals."""

    def __init__(self, database_url: str) -> None:
        self.database_url = database_url
        self._ensure_tables()

    def _conn(self):
        from src.api.db_pool import db_connection
        return db_connection(self.database_url)

    def _ensure_tables(self) -> None:
        try:
            with self._conn() as conn:
                conn.execute(_CREATE_HOST_ACTIONS_TABLE)
                conn.commit()
        except Exception:
            logger.exception("Failed to ensure ai_host_actions table")
            raise

    def create_pending(
        self,
        action_key: str,
        host: str,
        params: dict[str, Any],
        summary: str,
        *,
        proposed_by: str = "ai",
    ) -> HostActionRecord:
        action_id = str(uuid.uuid4())
        body = params or {}
        with self._conn() as conn:
            conn.execute(
                """
                INSERT INTO ai_host_actions (
                    id, action_key, host, params, status, summary, proposed_by
                )
                VALUES (%s, %s, %s, %s::jsonb, %s, %s, %s)
                """,
                (action_id, action_key, host, json.dumps(body), STATUS_PENDING, summary[:2000], proposed_by),
            )
            conn.commit()
        return HostActionRecord(
            id=action_id,
            action_key=action_key,
            host=host,
            params=body,
            status=STATUS_PENDING,
            summary=summary[:2000],
            command_run=None,
            stdout=None,
            stderr=None,
            exit_code=None,
            proposed_by=proposed_by,
            reviewed_by=None,
            created_at=_now_iso(),
            executed_at=None,
        )

    def get_by_id(self, action_id: str) -> HostActionRecord | None:
        from src.api.uuid_util import parse_uuid

        uid = parse_uuid(action_id)
        if uid is None:
            return None
        with self._conn() as conn:
            row = conn.execute(
                "SELECT * FROM ai_host_actions WHERE id = %s",
                (uid,),
            ).fetchone()
        return _row_to_record(row) if row else None

    def list_actions(
        self,
        *,
        status: str | None = None,
        limit: int = 100,
    ) -> list[HostActionRecord]:
        safe_limit = max(1, min(limit, 500))
        with self._conn() as conn:
            if status:
                rows = conn.execute(
                    """
                    SELECT * FROM ai_host_actions
                    WHERE status = %s
                    ORDER BY created_at DESC
                    LIMIT %s
                    """,
                    (status, safe_limit),
                ).fetchall()
            else:
                rows = conn.execute(
                    "SELECT * FROM ai_host_actions ORDER BY created_at DESC LIMIT %s",
                    (safe_limit,),
                ).fetchall()
        return [_row_to_record(row) for row in rows]

    def mark_rejected(self, action_id: str, *, reviewed_by: str) -> HostActionRecord | None:
        with self._conn() as conn:
            row = conn.execute(
                """
                UPDATE ai_host_actions
                SET status = %s, reviewed_by = %s
                WHERE id = %s AND status = %s
                RETURNING *
                """,
                (STATUS_REJECTED, reviewed_by, action_id, STATUS_PENDING),
            ).fetchone()
            conn.commit()
        return _row_to_record(row) if row else None

    def mark_executed(
        self,
        action_id: str,
        *,
        reviewed_by: str,
        command_run: str,
        stdout: str,
        stderr: str,
        exit_code: int,
        success: bool,
    ) -> HostActionRecord | None:
        status = STATUS_EXECUTED if success else STATUS_FAILED
        with self._conn() as conn:
            row = conn.execute(
                """
                UPDATE ai_host_actions
                SET status = %s,
                    reviewed_by = %s,
                    command_run = %s,
                    stdout = %s,
                    stderr = %s,
                    exit_code = %s,
                    executed_at = NOW()
                WHERE id = %s AND status = %s
                RETURNING *
                """,
                (
                    status,
                    reviewed_by,
                    command_run[:8000],
                    stdout[:50000],
                    stderr[:50000],
                    exit_code,
                    action_id,
                    STATUS_PENDING,
                ),
            ).fetchone()
            conn.commit()
        return _row_to_record(row) if row else None
