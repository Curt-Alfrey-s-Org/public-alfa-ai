"""Ask ALFa assistant bubbles expand like a disclosure, not a wheel-trapping pre."""

from __future__ import annotations

from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
CHAT_MESSAGE = REPO / "frontend/src/components/ChatMessage.tsx"
EXPANDABLE = REPO / "frontend/src/components/ExpandableClip.tsx"
WIDGET = REPO / "frontend/src/components/admin/AskAlfaWidget.tsx"
CSS = REPO / "frontend/src/index.css"


def test_expandable_clip_is_aria_disclosure() -> None:
    src = EXPANDABLE.read_text(encoding="utf-8")
    assert 'aria-expanded={expanded}' in src
    assert "aria-controls={panelId}" in src
    assert 'type="button"' in src
    assert "overflow-hidden" in src
    assert "ResizeObserver" in src
    assert "overflow-y-auto" not in src


def test_chat_message_uses_expandable_clip_when_scroll_body() -> None:
    src = CHAT_MESSAGE.read_text(encoding="utf-8")
    assert "AssistantMarkdown" in src
    assert "collapsible={scrollBody}" in src
    assert "max-h-40 overflow-y-auto" not in src
    assert 'expandLabel="Expand code"' in src
    assert 'aria-label={copied ? "Copied" : "Copy code"}' in src
    assert "navigator.clipboard.writeText" in src
    assert "markdownNodeText" in src


def test_ask_alfa_widget_still_collapses_assistant_bubbles() -> None:
    src = WIDGET.read_text(encoding="utf-8")
    assert "scrollBody={m.role === \"assistant\"}" in src


def test_prose_chat_pre_does_not_use_overflow_auto() -> None:
    src = CSS.read_text(encoding="utf-8")
    block = src.split(".prose-chat pre {", 1)[1].split(".prose-chat pre code", 1)[0]
    assert "overflow-auto" not in block
    assert "max-h-48" not in block
