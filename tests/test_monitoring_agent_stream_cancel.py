"""Ask ALFa SSE cancel: disconnect path must not surface done payloads."""

from __future__ import annotations

import ast
from pathlib import Path


def test_monitoring_agent_stream_checks_disconnect() -> None:
    src = (Path(__file__).resolve().parents[1] / "src/api/routers/admin.py").read_text(
        encoding="utf-8"
    )
    assert "is_disconnected" in src
    assert "monitoring_agent_stream" in src
    # Request injected for disconnect detection
    assert "request: Request" in src


def test_widget_uses_abort_controller() -> None:
    src = (
        Path(__file__).resolve().parents[1]
        / "frontend/src/components/admin/AskAlfaWidget.tsx"
    ).read_text(encoding="utf-8")
    assert "AbortController" in src
    assert "signal" in src
    assert "isAbortError" in src
    assert "Cancelled." in src
    assert "stopActive" in src


def test_store_conn_uses_db_pool() -> None:
    models = Path(__file__).resolve().parents[1] / "src/api/models"
    wired = 0
    for p in models.glob("*.py"):
        t = p.read_text(encoding="utf-8")
        if "def _conn" in t and "db_connection" in t:
            wired += 1
    assert wired >= 8, f"expected most stores on db_pool, got {wired}"
