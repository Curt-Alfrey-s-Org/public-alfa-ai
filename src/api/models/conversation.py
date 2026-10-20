"""Conversation + message persistence (psycopg3)."""

from __future__ import annotations

import logging
import uuid
from dataclasses import dataclass, field
from datetime import UTC, datetime

import psycopg
from psycopg.rows import dict_row

logger = logging.getLogger(__name__)


def _now_iso() -> str:
    return datetime.now(tz=UTC).isoformat()


@dataclass(slots=True)
class ConversationRecord:
    id: str
    user_id: str
    title: str
    model: str | None = None
    created_at: str = field(default_factory=_now_iso)
    updated_at: str = field(default_factory=_now_iso)


@dataclass(slots=True)
class MessageRecord:
    id: str
    conversation_id: str
    role: str
    content: str
    created_at: str = field(default_factory=_now_iso)


_CREATE_TABLES = """\
CREATE TABLE IF NOT EXISTS conversations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title TEXT NOT NULL DEFAULT 'New chat',
    model TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_conversations_user ON conversations (user_id, updated_at DESC);

CREATE TABLE IF NOT EXISTS messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    role TEXT NOT NULL,
    content TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_messages_conv ON messages (conversation_id, created_at);
"""


class ConversationStore:
    def __init__(self, database_url: str) -> None:
        self.database_url = database_url
        self._ensure_tables()

    def _conn(self):
        from src.api.db_pool import db_connection
        return db_connection(self.database_url)

    def _ensure_tables(self) -> None:
        try:
            with self._conn() as conn:
                conn.execute(_CREATE_TABLES)
                conn.commit()
        except Exception:
            logger.exception("Failed to ensure conversation tables")
            raise

    def create(self, user_id: str, title: str = "New chat", model: str | None = None) -> ConversationRecord:
        cid = str(uuid.uuid4())
        now = _now_iso()
        with self._conn() as conn:
            conn.execute(
                "INSERT INTO conversations (id, user_id, title, model, created_at, updated_at) VALUES (%s, %s::uuid, %s, %s, %s, %s)",
                (cid, user_id, title, model, now, now),
            )
            conn.commit()
        return ConversationRecord(id=cid, user_id=user_id, title=title, model=model, created_at=now, updated_at=now)

    def list_for_user(self, user_id: str, limit: int = 50) -> list[ConversationRecord]:
        with self._conn() as conn:
            rows = conn.execute(
                "SELECT * FROM conversations WHERE user_id = %s::uuid ORDER BY updated_at DESC LIMIT %s",
                (user_id, limit),
            ).fetchall()
        return [self._row_to_conv(r) for r in rows]

    def get(self, conv_id: str) -> ConversationRecord | None:
        with self._conn() as conn:
            row = conn.execute("SELECT * FROM conversations WHERE id = %s::uuid", (conv_id,)).fetchone()
        return self._row_to_conv(row) if row else None

    def update_title(self, conv_id: str, title: str) -> None:
        with self._conn() as conn:
            conn.execute(
                "UPDATE conversations SET title = %s, updated_at = %s WHERE id = %s::uuid",
                (title, _now_iso(), conv_id),
            )
            conn.commit()

    def touch(self, conv_id: str) -> None:
        with self._conn() as conn:
            conn.execute("UPDATE conversations SET updated_at = %s WHERE id = %s::uuid", (_now_iso(), conv_id))
            conn.commit()

    def delete(self, conv_id: str) -> None:
        with self._conn() as conn:
            conn.execute("DELETE FROM conversations WHERE id = %s::uuid", (conv_id,))
            conn.commit()

    def add_message(self, conv_id: str, role: str, content: str) -> MessageRecord:
        mid = str(uuid.uuid4())
        now = _now_iso()
        with self._conn() as conn:
            conn.execute(
                "INSERT INTO messages (id, conversation_id, role, content, created_at) VALUES (%s, %s::uuid, %s, %s, %s)",
                (mid, conv_id, role, content, now),
            )
            conn.commit()
        return MessageRecord(id=mid, conversation_id=conv_id, role=role, content=content, created_at=now)

    def get_messages(self, conv_id: str) -> list[MessageRecord]:
        with self._conn() as conn:
            rows = conn.execute(
                "SELECT * FROM messages WHERE conversation_id = %s::uuid ORDER BY created_at",
                (conv_id,),
            ).fetchall()
        return [self._row_to_msg(r) for r in rows]

    def get_message(self, msg_id: str) -> MessageRecord | None:
        with self._conn() as conn:
            row = conn.execute("SELECT * FROM messages WHERE id = %s::uuid", (msg_id,)).fetchone()
        return self._row_to_msg(row) if row else None

    def update_user_message(self, conv_id: str, msg_id: str, content: str) -> MessageRecord | None:
        with self._conn() as conn:
            row = conn.execute(
                """
                UPDATE messages
                SET content = %s
                WHERE id = %s::uuid
                  AND conversation_id = %s::uuid
                  AND role = 'user'
                RETURNING *
                """,
                (content, msg_id, conv_id),
            ).fetchone()
            if row:
                conn.commit()
                return self._row_to_msg(row)
        return None

    def delete_messages_after(self, conv_id: str, msg_id: str) -> None:
        with self._conn() as conn:
            conn.execute(
                """
                DELETE FROM messages m
                USING messages anchor
                WHERE anchor.id = %s::uuid
                  AND anchor.conversation_id = %s::uuid
                  AND m.conversation_id = %s::uuid
                  AND m.created_at > anchor.created_at
                """,
                (msg_id, conv_id, conv_id),
            )
            conn.commit()

    @staticmethod
    def _row_to_conv(row: dict) -> ConversationRecord:
        return ConversationRecord(
            id=str(row["id"]),
            user_id=str(row["user_id"]),
            title=row["title"],
            model=row.get("model"),
            created_at=str(row.get("created_at", "")),
            updated_at=str(row.get("updated_at", "")),
        )

    @staticmethod
    def _row_to_msg(row: dict) -> MessageRecord:
        return MessageRecord(
            id=str(row["id"]),
            conversation_id=str(row["conversation_id"]),
            role=row["role"],
            content=row["content"],
            created_at=str(row.get("created_at", "")),
        )
