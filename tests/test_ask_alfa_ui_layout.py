"""Ask ALFa UI is brain ChatMessage plus extracted admin cards -- not a third dock."""

from __future__ import annotations

from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
WIDGET = REPO / "frontend/src/components/admin/AskAlfaWidget.tsx"
CARDS = REPO / "frontend/src/components/admin/AskAlfaCards.tsx"
TYPES = REPO / "frontend/src/components/admin/askAlfaTypes.ts"
DOCS = REPO / "docs/ALFA_AI_CHAT_WIDGETS.md"


def test_widget_imports_extracted_cards() -> None:
    src = WIDGET.read_text(encoding="utf-8")
    assert 'from "./AskAlfaCards"' in src
    assert "HostActionApproveCard" in src
    assert "SettingApproveCard" in src
    assert "HostActionResultCard" in src
    assert "function HostActionApproveCard" not in src
    assert "function SettingApproveCard" not in src
    assert "AlfaAskAiDock" not in src


def test_cards_file_owns_approve_markup() -> None:
    src = CARDS.read_text(encoding="utf-8")
    assert "export function HostActionApproveCard" in src
    assert "export function SettingApproveCard" in src
    assert "export function HostActionResultCard" in src
    assert "I confirm this" in src


def test_types_file_exists() -> None:
    src = TYPES.read_text(encoding="utf-8")
    assert "export interface AgentMessage" in src
    assert "export interface ChatSession" in src


def test_docs_name_the_edit_map() -> None:
    src = DOCS.read_text(encoding="utf-8")
    assert "Ask ALFa admin dock (do not invent a third chat)" in src
    assert "AskAlfaCards.tsx" in src
    assert "askAlfaTypes.ts" in src
    assert "ChatMessage.tsx" in src
    assert "frontend/src/components/ExpandableClip.tsx" in src
