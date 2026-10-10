"""Per-IP failed-login limit store: memory path + Redis sliding window (finding 15)."""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest

from src.api import login_rate_limit
from src.api.login_rate_limit import (
    is_login_ip_limited,
    login_ip_max_failures,
    login_ip_window_sec,
    record_login_ip_failure,
    reset_memory_limits_for_tests,
)

_NO_REDIS = lambda: None  # noqa: E731


@pytest.fixture(autouse=True)
def _clear(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("ALFA_AI_LOGIN_IP_MAX_FAILURES", raising=False)
    monkeypatch.delenv("ALFA_AI_LOGIN_IP_WINDOW_SEC", raising=False)
    reset_memory_limits_for_tests()
    yield
    reset_memory_limits_for_tests()


def test_defaults_and_env(monkeypatch: pytest.MonkeyPatch) -> None:
    assert login_ip_max_failures() == 20
    assert login_ip_window_sec() == 900
    monkeypatch.setenv("ALFA_AI_LOGIN_IP_MAX_FAILURES", "7")
    monkeypatch.setenv("ALFA_AI_LOGIN_IP_WINDOW_SEC", "60")
    assert login_ip_max_failures() == 7
    assert login_ip_window_sec() == 60
    monkeypatch.setenv("ALFA_AI_LOGIN_IP_MAX_FAILURES", "nope")
    monkeypatch.setenv("ALFA_AI_LOGIN_IP_WINDOW_SEC", "0")
    assert login_ip_max_failures() == 20
    assert login_ip_window_sec() == 900


def test_memory_limits_at_threshold_and_isolates_ips() -> None:
    for _ in range(2):
        assert not is_login_ip_limited("1.2.3.4", max_failures=3, redis_factory=_NO_REDIS)
        record_login_ip_failure("1.2.3.4", redis_factory=_NO_REDIS)
    assert not is_login_ip_limited("1.2.3.4", max_failures=3, redis_factory=_NO_REDIS)
    assert record_login_ip_failure("1.2.3.4", redis_factory=_NO_REDIS) == "memory"
    assert is_login_ip_limited("1.2.3.4", max_failures=3, redis_factory=_NO_REDIS)
    assert not is_login_ip_limited("1.2.3.5", max_failures=3, redis_factory=_NO_REDIS)


def test_memory_window_expires() -> None:
    for _ in range(3):
        record_login_ip_failure("5.5.5.5", window_sec=900, redis_factory=_NO_REDIS)
    login_rate_limit._memory_failures["5.5.5.5"] = [
        t - 1000 for t in login_rate_limit._memory_failures["5.5.5.5"]
    ]
    assert not is_login_ip_limited("5.5.5.5", max_failures=3, window_sec=900, redis_factory=_NO_REDIS)


def test_disabled_and_missing_ip(monkeypatch: pytest.MonkeyPatch) -> None:
    assert not is_login_ip_limited(None, max_failures=1, redis_factory=_NO_REDIS)
    assert record_login_ip_failure(None, redis_factory=_NO_REDIS) is None
    monkeypatch.setenv("ALFA_AI_LOGIN_IP_MAX_FAILURES", "0")
    assert record_login_ip_failure("1.1.1.1", redis_factory=_NO_REDIS) is None
    assert not is_login_ip_limited("1.1.1.1", redis_factory=_NO_REDIS)


def test_memory_is_bounded(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(login_rate_limit, "_MEMORY_MAX_KEYS", 5)
    for i in range(20):
        record_login_ip_failure(f"10.9.0.{i}", redis_factory=_NO_REDIS)
    assert len(login_rate_limit._memory_failures) <= 5


def test_redis_counts_and_records() -> None:
    zset: list[float] = []

    class FakePipe:
        def __init__(self) -> None:
            self.ops: list[str] = []

        def zremrangebyscore(self, *a, **k):
            self.ops.append("zrem")
            return self

        def zcard(self, *a, **k):
            self.ops.append("zcard")
            return self

        def zadd(self, key, mapping):
            self.ops.append("zadd")
            zset.extend(mapping.values())
            return self

        def expire(self, *a, **k):
            self.ops.append("expire")
            return self

        def execute(self):
            return [0 if op != "zcard" else len(zset) for op in self.ops]

    client = MagicMock()
    client.pipeline.side_effect = FakePipe
    factory = lambda: client  # noqa: E731

    for _ in range(3):
        assert not is_login_ip_limited("r-ip", max_failures=3, redis_factory=factory)
        assert record_login_ip_failure("r-ip", redis_factory=factory) == "redis"
    assert is_login_ip_limited("r-ip", max_failures=3, redis_factory=factory)
    # Memory fallback untouched when Redis works.
    assert login_rate_limit._memory_failures == {}


def test_redis_error_falls_back_to_memory() -> None:
    def boom():
        raise ConnectionError("redis down")

    assert record_login_ip_failure("fb-ip", redis_factory=boom) == "memory"
    assert is_login_ip_limited("fb-ip", max_failures=1, redis_factory=boom)
