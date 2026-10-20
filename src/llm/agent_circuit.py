"""In-process circuit breaker for Ask ALFa agent model (get_agent_completion).

HTTPX timeouts: default 5s network inactivity unless overridden on Client;
ConnectTimeout / ReadTimeout / WriteTimeout / PoolTimeout are TimeoutException
subclasses. See https://www.python-httpx.org/advanced/timeouts/ and
https://www.python-httpx.org/exceptions/
"""

from __future__ import annotations

import time
from threading import Lock

from src.config import get

_lock = Lock()
_failure_count = 0
_opened_until = 0.0


class AgentCircuitOpenError(Exception):
    """Agent model circuit is open; Ask ALFa should fail fast with admin detail."""


def _failure_threshold() -> int:
    raw = get("ALFA_AI_AGENT_CIRCUIT_FAILURES", "3").strip()
    try:
        return max(1, int(raw))
    except ValueError:
        return 3


def _open_seconds() -> int:
    raw = get("ALFA_AI_AGENT_CIRCUIT_OPEN_SEC", "60").strip()
    try:
        return max(1, int(raw))
    except ValueError:
        return 60


def reset_agent_circuit_for_tests() -> None:
    """Clear circuit state (unit tests only)."""
    global _failure_count, _opened_until
    with _lock:
        _failure_count = 0
        _opened_until = 0.0


def check_agent_circuit() -> None:
    """Raise AgentCircuitOpenError while the circuit is open."""
    global _failure_count, _opened_until
    now = time.monotonic()
    with _lock:
        if _opened_until > 0.0:
            if now < _opened_until:
                remaining = max(1, int(_opened_until - now + 0.999))
                threshold = _failure_threshold()
                raise AgentCircuitOpenError(
                    "Agent model circuit open: unreachable after "
                    f"{threshold} consecutive failures; retry in {remaining}s"
                )
            _opened_until = 0.0
            _failure_count = 0


def record_agent_failure() -> None:
    """Count a failed agent completion; open the circuit after N consecutive failures."""
    global _failure_count, _opened_until
    with _lock:
        _failure_count += 1
        threshold = _failure_threshold()
        if _failure_count >= threshold:
            _opened_until = time.monotonic() + _open_seconds()


def record_agent_success() -> None:
    """Reset failure count and close the circuit after a successful completion."""
    global _failure_count, _opened_until
    with _lock:
        _failure_count = 0
        _opened_until = 0.0
