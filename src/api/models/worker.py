"""Worker registry: track registered GPU/RPC workers for health monitoring."""

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
class WorkerRecord:
    id: str
    name: str
    ip_address: str
    monitor_port: int = 31331
    role: str = "gpu-worker"
    status: str = "unknown"
    last_seen: str | None = None
    hardware_summary: str | None = None
    created_at: str = field(default_factory=_now_iso)


_CREATE_WORKERS_TABLE = """\
CREATE TABLE IF NOT EXISTS workers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    ip_address TEXT NOT NULL,
    monitor_port INTEGER NOT NULL DEFAULT 31331,
    role TEXT NOT NULL DEFAULT 'gpu-worker',
    status TEXT NOT NULL DEFAULT 'unknown',
    last_seen TIMESTAMPTZ,
    hardware_summary TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_workers_ip_port ON workers (ip_address, monitor_port);
"""


class WorkerStore:
    def __init__(self, database_url: str) -> None:
        self.database_url = database_url
        self._ensure_table()

    def _conn(self):
        from src.api.db_pool import db_connection
        return db_connection(self.database_url)

    def _ensure_table(self) -> None:
        try:
            with self._conn() as conn:
                conn.execute(_CREATE_WORKERS_TABLE)
                conn.commit()
        except Exception:
            logger.exception("Failed to ensure workers table")
            raise

    def add(self, name: str, ip_address: str, monitor_port: int = 31331, role: str = "gpu-worker") -> WorkerRecord:
        name = name.strip()
        ip_address = ip_address.strip()
        role = role.strip() or "gpu-worker"
        wid = str(uuid.uuid4())
        now = _now_iso()
        with self._conn() as conn:
            conn.execute(
                """
                INSERT INTO workers (id, name, ip_address, monitor_port, role, created_at)
                VALUES (%s, %s, %s, %s, %s, %s)
                ON CONFLICT (ip_address, monitor_port) DO UPDATE
                SET name = EXCLUDED.name, role = EXCLUDED.role
                RETURNING id
                """,
                (wid, name, ip_address, monitor_port, role, now),
            )
            conn.commit()
        return WorkerRecord(id=wid, name=name, ip_address=ip_address, monitor_port=monitor_port, role=role, created_at=now)

    def remove(self, worker_id: str) -> None:
        with self._conn() as conn:
            conn.execute("DELETE FROM workers WHERE id = %s::uuid", (worker_id,))
            conn.commit()

    def list_all(self) -> list[WorkerRecord]:
        with self._conn() as conn:
            rows = conn.execute("SELECT * FROM workers ORDER BY created_at").fetchall()
        return [self._row_to_record(r) for r in rows]

    def update_status(self, worker_id: str, status: str, hardware_summary: str | None = None) -> None:
        with self._conn() as conn:
            conn.execute(
                "UPDATE workers SET status = %s, last_seen = %s, hardware_summary = %s WHERE id = %s::uuid",
                (status, _now_iso(), hardware_summary, worker_id),
            )
            conn.commit()

    @staticmethod
    def _row_to_record(row: dict) -> WorkerRecord:
        return WorkerRecord(
            id=str(row["id"]),
            name=row["name"],
            ip_address=row["ip_address"],
            monitor_port=row.get("monitor_port", 31331),
            role=row.get("role", "gpu-worker"),
            status=row.get("status", "unknown"),
            last_seen=str(row["last_seen"]) if row.get("last_seen") else None,
            hardware_summary=row.get("hardware_summary"),
            created_at=str(row.get("created_at", "")),
        )
