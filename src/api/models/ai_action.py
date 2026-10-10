"""Persistence for the AI Actions feed (autonomous + operator-visible AI activity).

Records every AI-initiated action in the alert/notification domain so the admin
"AI Actions" tab can show a full, reversible history. See docs/AI_ACTIONS.md.
"""

from __future__ import annotations

import json
import logging
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

import psycopg
from psycopg.rows import dict_row

logger = logging.getLogger(__name__)

# Action types recorded in the ai_actions table.
ACTION_ALERT_TRIAGED = "alert_triaged"
ACTION_NOTIFICATION_SENT = "notification_sent"
ACTION_NOTIFICATION_SKIPPED = "notification_skipped"
ACTION_SETTING_CHANGED = "setting_changed"
ACTION_SETTING_PROPOSAL = "setting_proposal"
ACTION_SETTING_SUGGESTION = "setting_suggestion"
ACTION_AGENT_CONFIG_CHANGED = "agent_config_changed"
ACTION_HOST_COMMAND_EXECUTED = "host_command_executed"
ACTION_HOST_ACTION_REJECTED = "host_action_rejected"
ACTION_HOST_INSPECT_EXECUTED = "host_inspect_executed"
ACTION_SOLAR_DUMP_OBSERVED = "solar_dump_observed"
ACTION_SOLAR_DUMP_RECOMMENDED = "solar_dump_recommended"
ACTION_SOLAR_DUMP_ACTUATED = "solar_dump_actuated"
ACTION_PROPOSAL_FEEDBACK = "proposal_feedback"
ACTION_HOST_ACTION_FEEDBACK = "host_action_feedback"

# Map action_type -> feed category (matches docs/AI_ACTIONS.md sub-tabs).
_CATEGORY_BY_TYPE: dict[str, str] = {
    ACTION_ALERT_TRIAGED: "alert",
    ACTION_NOTIFICATION_SENT: "notifications",
    ACTION_NOTIFICATION_SKIPPED: "notifications",
    ACTION_SETTING_CHANGED: "settings",
    ACTION_SETTING_PROPOSAL: "settings",
    ACTION_SETTING_SUGGESTION: "settings",
    ACTION_AGENT_CONFIG_CHANGED: "settings",
    ACTION_HOST_COMMAND_EXECUTED: "host",
    ACTION_HOST_ACTION_REJECTED: "host",
    ACTION_HOST_INSPECT_EXECUTED: "host",
    ACTION_SOLAR_DUMP_OBSERVED: "dump",
    ACTION_SOLAR_DUMP_RECOMMENDED: "dump",
    ACTION_SOLAR_DUMP_ACTUATED: "dump",
    "solar_soak_observed": "dump",
    "solar_soak_recommended": "dump",
    "solar_soak_actuated": "dump",
    ACTION_PROPOSAL_FEEDBACK: "all",
    ACTION_HOST_ACTION_FEEDBACK: "host",
}


def _now_iso() -> str:
    return datetime.now(tz=UTC).isoformat()


def category_for_action(action_type: str) -> str:
    return _CATEGORY_BY_TYPE.get(action_type, "all")


@dataclass(slots=True)
class AiActionRecord:
    id: str
    action_type: str
    category: str
    summary: str
    detail: dict[str, Any]
    severity: str | None
    incident_id: str | None
    created_by: str
    created_at: str


_CREATE_AI_ACTIONS_TABLE = """\
CREATE TABLE IF NOT EXISTS ai_actions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    action_type TEXT NOT NULL,
    summary TEXT NOT NULL DEFAULT '',
    detail JSONB NOT NULL DEFAULT '{}'::jsonb,
    severity TEXT,
    incident_id UUID,
    created_by TEXT NOT NULL DEFAULT 'ai',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ai_actions_created_at ON ai_actions (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ai_actions_type ON ai_actions (action_type);
"""


def _row_to_action(row: dict[str, Any]) -> AiActionRecord:
    created_at = row["created_at"]
    action_type = row["action_type"]
    return AiActionRecord(
        id=str(row["id"]),
        action_type=action_type,
        category=category_for_action(action_type),
        summary=row.get("summary") or "",
        detail=row.get("detail") or {},
        severity=row.get("severity"),
        incident_id=str(row["incident_id"]) if row.get("incident_id") else None,
        created_by=row.get("created_by") or "ai",
        created_at=created_at.isoformat() if hasattr(created_at, "isoformat") else str(created_at),
    )


class AiActionStore:
    """Postgres persistence for the AI Actions feed."""

    def __init__(self, database_url: str) -> None:
        self.database_url = database_url
        self._ensure_tables()

    def _conn(self):
        from src.api.db_pool import db_connection
        return db_connection(self.database_url)

    def _ensure_tables(self) -> None:
        try:
            with self._conn() as conn:
                conn.execute(_CREATE_AI_ACTIONS_TABLE)
                conn.commit()
        except Exception:
            logger.exception("Failed to ensure ai_actions table")
            raise

    def record(
        self,
        action_type: str,
        summary: str,
        *,
        detail: dict[str, Any] | None = None,
        severity: str | None = None,
        incident_id: str | None = None,
        created_by: str = "ai",
    ) -> AiActionRecord:
        action_id = str(uuid.uuid4())
        body = detail or {}
        with self._conn() as conn:
            conn.execute(
                """
                INSERT INTO ai_actions (
                    id, action_type, summary, detail, severity, incident_id, created_by
                )
                VALUES (%s, %s, %s, %s::jsonb, %s, %s, %s)
                """,
                (
                    action_id,
                    action_type,
                    summary[:2000],
                    json.dumps(body),
                    severity,
                    incident_id,
                    created_by,
                ),
            )
            conn.commit()
        return AiActionRecord(
            id=action_id,
            action_type=action_type,
            category=category_for_action(action_type),
            summary=summary[:2000],
            detail=body,
            severity=severity,
            incident_id=incident_id,
            created_by=created_by,
            created_at=_now_iso(),
        )

    def list_actions(self, *, action_types: list[str] | None = None, limit: int = 100) -> list[AiActionRecord]:
        safe_limit = max(1, min(limit, 500))
        with self._conn() as conn:
            if action_types:
                rows = conn.execute(
                    """
                    SELECT * FROM ai_actions
                    WHERE action_type = ANY(%s)
                    ORDER BY created_at DESC
                    LIMIT %s
                    """,
                    (action_types, safe_limit),
                ).fetchall()
            else:
                rows = conn.execute(
                    "SELECT * FROM ai_actions ORDER BY created_at DESC LIMIT %s",
                    (safe_limit,),
                ).fetchall()
        return [_row_to_action(row) for row in rows]

    def get_by_id(self, action_id: str) -> AiActionRecord | None:
        from src.api.uuid_util import parse_uuid

        uid = parse_uuid(action_id)
        if uid is None:
            return None
        with self._conn() as conn:
            row = conn.execute(
                "SELECT * FROM ai_actions WHERE id = %s",
                (uid,),
            ).fetchone()
        return _row_to_action(row) if row else None

    def count_recent(self, action_type: str, *, minutes: int) -> int:
        cutoff = datetime.now(tz=UTC) - timedelta(minutes=max(1, minutes))
        with self._conn() as conn:
            row = conn.execute(
                """
                SELECT count(*) AS cnt FROM ai_actions
                WHERE action_type = %s AND created_at >= %s
                """,
                (action_type, cutoff),
            ).fetchone()
        return int(row["cnt"]) if row else 0

    def last_notified_at(self, alertname: str) -> datetime | None:
        """Most recent notification_sent timestamp for a given alertname (dedup helper)."""
        with self._conn() as conn:
            row = conn.execute(
                """
                SELECT created_at FROM ai_actions
                WHERE action_type = %s AND detail->>'alertname' = %s
                ORDER BY created_at DESC
                LIMIT 1
                """,
                (ACTION_NOTIFICATION_SENT, alertname),
            ).fetchone()
        if not row or not row.get("created_at"):
            return None
        value = row["created_at"]
        if isinstance(value, datetime):
            return value if value.tzinfo else value.replace(tzinfo=UTC)
        return None

    def update_detail(self, action_id: str, detail: dict[str, Any]) -> AiActionRecord | None:
        """Merge detail JSON for an existing action (e.g. setting proposal status)."""
        with self._conn() as conn:
            row = conn.execute(
                "SELECT * FROM ai_actions WHERE id = %s",
                (action_id,),
            ).fetchone()
            if row is None:
                return None
            merged = dict(row.get("detail") or {})
            merged.update(detail)
            conn.execute(
                """
                UPDATE ai_actions SET detail = %s::jsonb WHERE id = %s
                """,
                (json.dumps(merged), action_id),
            )
            conn.commit()
            updated = conn.execute(
                "SELECT * FROM ai_actions WHERE id = %s",
                (action_id,),
            ).fetchone()
        return _row_to_action(updated) if updated else None
