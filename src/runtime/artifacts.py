from __future__ import annotations


def research_report_body(goal: str, summary: str) -> str:
    return f"# Research Notes\n\nGoal: {goal}\n\n{summary.strip()}\n"


def audit_report_body(goal: str, summary: str) -> str:
    return (
        f"# Audit Report\n\n"
        f"Goal: {goal}\n\n"
        f"{summary.strip()}\n\n"
        "## Findings format (required for export/judge/UI)\n\n"
        "Emit every issue as:\n\n"
        "### Finding N - Severity: bug|suggestion|nit\n"
        "- File: path:line\n"
        "- Description: ...\n"
        "- Suggestion: concrete fix the operator would take (propose only; not applied)\n"
    )


def host_facts_report_body(goal: str, summary: str) -> str:
    return (
        f"# Host Facts Report\n\n"
        f"Goal: {goal}\n\n"
        f"{summary.strip()}\n\n"
        "## Sections\n\n"
        "Include: processes, docker, disk/memory, and relevant log excerpts.\n"
    )


def implementation_summary_body(goal: str, summary: str) -> str:
    return f"# Implementation Summary\n\nGoal: {goal}\n\n{summary.strip()}\n"


def review_report_body(goal: str, summary: str) -> str:
    return (
        f"# Review Report\n\n"
        f"Goal: {goal}\n\n"
        f"{summary.strip()}\n\n"
        "## Issue format\n\n"
        "### Issue N — Severity: bug|suggestion|nit\n"
        "- File: path:line\n"
        "- Description: ...\n"
        "- Suggestion: ...\n"
        "- Status: open|fixed|wontfix\n"
    )


def check_work_report_body(goal: str, summary: str) -> str:
    return f"# Check-work report\n\nGoal: {goal}\n\n{summary.strip()}\n"


def error_catalog_report_body(goal: str, summary: str) -> str:
    return f"# Error catalog report\n\nGoal: {goal}\n\n{summary.strip()}\n"


def corrective_actions_report_body(goal: str, summary: str) -> str:
    return f"# Corrective actions\n\nGoal: {goal}\n\n{summary.strip()}\n"


def sleep_curator_report_body(goal: str, summary: str) -> str:
    return f"# Sleep curator\n\nGoal: {goal}\n\n{summary.strip()}\n"