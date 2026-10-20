"""Guest rate limit: memory path + Redis sliding window (audit D-011)."""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest
from fastapi import HTTPException

from src.api.guest_rate_limit import (
    check_guest_rate_limit,
    reset_memory_limits_for_tests,
)


@pytest.fixture(autouse=True)
def _clear_memory() -> None:
    reset_memory_limits_for_tests()
    yield
    reset_memory_limits_for_tests()


def test_memory_allows_under_limit() -> None:
    backend = check_guest_rate_limit(
        "1.2.3.4",
        max_messages=3,
        window_sec=3600,
        redis_factory=lambda: None,
    )
    assert backend == "memory"
    check_guest_rate_limit("1.2.3.4", max_messages=3, window_sec=3600, redis_factory=lambda: None)
    check_guest_rate_limit("1.2.3.4", max_messages=3, window_sec=3600, redis_factory=lambda: None)


def test_memory_blocks_at_limit() -> None:
    for _ in range(3):
        check_guest_rate_limit("9.9.9.9", max_messages=3, window_sec=3600, redis_factory=lambda: None)
    with pytest.raises(HTTPException) as ei:
        check_guest_rate_limit("9.9.9.9", max_messages=3, window_sec=3600, redis_factory=lambda: None)
    assert ei.value.status_code == 429


def test_memory_isolates_ips() -> None:
    for _ in range(3):
        check_guest_rate_limit("apps", max_messages=3, window_sec=3600, redis_factory=lambda: None)
    # Different IP still allowed
    check_guest_rate_limit("apps", max_messages=3, window_sec=3600, redis_factory=lambda: None)


def test_redis_sliding_window_blocks() -> None:
    """Fake Redis pipeline: first three OK, fourth zcard_before_add=3 → 429."""
    call_n = {"n": 0}

    class FakePipe:
        def zremrangebyscore(self, *a, **k):
            return self

        def zcard(self, *a, **k):
            return self

        def zadd(self, *a, **k):
            return self

        def expire(self, *a, **k):
            return self

        def execute(self):
            call_n["n"] += 1
            # zcard before add: 0,1,2 then 3
            before = call_n["n"] - 1
            return [0, before, 1, True]

    client = MagicMock()
    client.pipeline.return_value = FakePipe()
    client.zrem = MagicMock()

    for _ in range(3):
        assert (
            check_guest_rate_limit(
                "redis-ip",
                max_messages=3,
                window_sec=3600,
                redis_factory=lambda: client,
            )
            == "redis"
        )
    with pytest.raises(HTTPException) as ei:
        check_guest_rate_limit(
            "redis-ip",
            max_messages=3,
            window_sec=3600,
            redis_factory=lambda: client,
        )
    assert ei.value.status_code == 429
    client.zrem.assert_called()


def test_redis_error_falls_back_to_memory() -> None:
    def boom() -> None:
        raise ConnectionError("redis down")

    backend = check_guest_rate_limit(
        "fallback-ip",
        max_messages=2,
        window_sec=3600,
        redis_factory=boom,  # type: ignore[arg-type]
    )
    assert backend == "memory"
