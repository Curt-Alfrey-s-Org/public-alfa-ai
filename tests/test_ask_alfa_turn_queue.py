"""Ask ALFa client FIFO: queue helper contract and widget send-while-busy wiring."""

from __future__ import annotations

import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
QUEUE_TS = REPO / "frontend/src/lib/askAlfaTurnQueue.ts"
WIDGET_TSX = REPO / "frontend/src/components/admin/AskAlfaWidget.tsx"


def test_queue_helper_exports() -> None:
    src = QUEUE_TS.read_text(encoding="utf-8")
    assert "MAX_QUEUED_TURNS = 8" in src
    assert "export function enqueueFollowUp" in src
    assert "export function dequeueFollowUp" in src
    assert "export function newQueuedTurnId" in src
    assert 'rejected: null | "empty" | "full"' in src


def test_enqueue_rejects_full_without_mutation() -> None:
    src = QUEUE_TS.read_text(encoding="utf-8")
    assert "queue.length >= MAX_QUEUED_TURNS" in src
    assert 'return { queue, rejected: "full" }' in src


def test_widget_pending_queue_and_drain() -> None:
    src = WIDGET_TSX.read_text(encoding="utf-8")
    assert "pendingQueue" in src
    assert "dequeueFollowUp" in src
    assert "tryDrainQueue" in src
    assert "enqueueFollowUp" in src
    assert "sessionsRef.current" in src
    drain = src.split("function tryDrainQueue")[1].split("async function runTurn")[0]
    assert "void runTurn(sessionId" in drain
    assert "drained =" not in drain


def test_widget_send_while_busy_not_disabled_on_busy() -> None:
    src = WIDGET_TSX.read_text(encoding="utf-8")
    assert "Queue a follow-up" in src
    assert "disabled={busy}" not in src
    assert "atSessionLlmCap" in src


def test_widget_queued_user_bubble_label() -> None:
    src = WIDGET_TSX.read_text(encoding="utf-8")
    assert "queued: true" in src
    assert re.search(r">\s*Queued\s*<", src)


def test_widget_load_stored_drops_queued() -> None:
    src = WIDGET_TSX.read_text(encoding="utf-8")
    assert "pendingQueue: []" in src
    assert re.search(r"filter\(\(m\) => !m\.queued\)", src)


def test_widget_busy_enqueue_does_not_start_second_stream() -> None:
    src = WIDGET_TSX.read_text(encoding="utf-8")
    assert "if (active.busy)" in src
    busy_block = src.split("if (active.busy)")[1].split("if (busyCount >= MAX_CONCURRENT_BUSY)")[0]
    assert "runTurn" not in busy_block
    assert "monitoringAgentStream" not in busy_block


def test_widget_monitoring_agent_post_includes_history() -> None:
    src = WIDGET_TSX.read_text(encoding="utf-8")
    assert "JSON.stringify({ message, history })" in src
    assert "buildMonitoringAgentHistory" in src


def test_widget_history_clip_and_last_eight() -> None:
    src = WIDGET_TSX.read_text(encoding="utf-8")
    assert "MAX_HISTORY_CONTENT_CHARS = 2000" in src
    assert "MAX_HISTORY_ITEMS = 8" in src
    assert ".slice(-MAX_HISTORY_ITEMS)" in src
    assert "clipHistoryContent" in src
