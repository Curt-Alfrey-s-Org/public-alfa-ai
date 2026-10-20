"""Optional shared Postgres connection helper (audit D-010).

Uses a module-level ConnectionPool when ``psycopg_pool`` is installed and
``DATABASE_URL`` / ``ALFA_AI_DB_POOL`` is configured. Otherwise each call opens
a short-lived connection (legacy behavior).

Hot-path stores can call ``db_connection(database_url)`` as a context manager
instead of ``psycopg.connect`` per request.
"""

from __future__ import annotations

import logging
import os
import threading
from contextlib import contextmanager
from typing import Any, Generator

import psycopg
from psycopg.rows import dict_row

logger = logging.getLogger(__name__)

_pool_lock = threading.Lock()
_pools: dict[str, Any] = {}


def _pool_enabled() -> bool:
    raw = (os.getenv("ALFA_AI_DB_POOL") or "true").strip().lower()
    return raw in ("1", "true", "yes", "on")


def _get_pool(database_url: str) -> Any | None:
    if not _pool_enabled() or not database_url:
        return None
    try:
        from psycopg_pool import ConnectionPool
    except ImportError:
        return None

    with _pool_lock:
        pool = _pools.get(database_url)
        if pool is not None:
            return pool
        min_size = max(1, int(os.getenv("ALFA_AI_DB_POOL_MIN", "1") or "1"))
        max_size = max(min_size, int(os.getenv("ALFA_AI_DB_POOL_MAX", "10") or "10"))
        pool = ConnectionPool(
            conninfo=database_url,
            min_size=min_size,
            max_size=max_size,
            kwargs={"row_factory": dict_row},
            open=True,
        )
        _pools[database_url] = pool
        logger.info(
            "Postgres ConnectionPool opened min=%s max=%s",
            min_size,
            max_size,
        )
        return pool


@contextmanager
def db_connection(database_url: str) -> Generator[psycopg.Connection, None, None]:
    """Yield a dict_row connection from the pool or a one-shot connect."""
    pool = _get_pool(database_url)
    if pool is not None:
        with pool.connection() as conn:
            yield conn
        return
    with psycopg.connect(database_url, row_factory=dict_row) as conn:
        yield conn


def close_all_pools() -> None:
    """Test / shutdown helper."""
    with _pool_lock:
        for url, pool in list(_pools.items()):
            try:
                pool.close()
            except Exception:  # noqa: BLE001
                logger.exception("Error closing pool for %s", url[:40])
            _pools.pop(url, None)
