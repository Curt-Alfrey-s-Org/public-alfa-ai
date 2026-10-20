"""Validation policy for Analyze / remediation file proposals."""

from __future__ import annotations

import re

_ALLOWED_PATH_PREFIXES: tuple[str, ...] = (
    "deploy/incident-playbooks/",
    "deploy/docker-compose.yml",
    "deploy/litellm_config.yaml",
    "deploy/env.example",
    "prometheus/rules/",
    "alertmanager/",
    "src/",
    "docs/",
)

_SECRET_PATTERN = re.compile(
    r"(?i)(password|secret|api[_-]?key|token|private[_-]?key)\s*[:=]\s*\S+"
)


class ProposalPolicyError(ValueError):
    """Raised when a proposed_change or target_path fails policy checks."""


def validate_target_path(path: str | None) -> None:
    if not path:
        return
    normalized = path.strip().lstrip("/").replace("\\", "/")
    if not any(
        normalized == prefix.rstrip("/") or normalized.startswith(prefix)
        for prefix in _ALLOWED_PATH_PREFIXES
    ):
        raise ProposalPolicyError(
            f"target_path '{path}' is outside the allowed prefix list for automated proposals"
        )


def validate_proposed_change_content(content: str) -> None:
    if _SECRET_PATTERN.search(content or ""):
        raise ProposalPolicyError(
            "proposed_change appears to contain secret-like key=value material; redact before saving"
        )


def validate_file_proposal(target_path: str | None, proposed_change: str) -> None:
    validate_target_path(target_path)
    validate_proposed_change_content(proposed_change)
