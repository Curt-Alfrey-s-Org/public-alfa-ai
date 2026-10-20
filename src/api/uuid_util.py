"""UUID parsing helpers for Postgres-backed stores.

Official: https://docs.python.org/3/library/uuid.html
psycopg adapts uuid.UUID to PostgreSQL UUID:
https://www.psycopg.org/psycopg3/docs/basic/adapt.html
Validate before querying so malformed strings (e.g. LLM-invented "12345")
do not raise ``invalid input syntax for type uuid``.
"""

from __future__ import annotations

from uuid import UUID


def parse_uuid(value: object) -> UUID | None:
    """Return a UUID if ``value`` is a valid UUID string; otherwise None."""
    if value is None:
        return None
    try:
        return UUID(str(value).strip())
    except (ValueError, AttributeError, TypeError):
        return None
