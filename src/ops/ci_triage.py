"""Deterministic CI failure triage for Ask ALFa (paste-first).

Maps consumer-bot GitHub Actions failures to host reproduce commands and
Cursor handoff prompts. See .cursor/plans/ASK_ALFA_CURSOR_OFFLOAD.md.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any

# Repo display names and GitHub org slugs seen in CI notification emails.
_REPO_PATTERNS: tuple[tuple[re.Pattern[str], str, str, str], ...] = (
    (
        re.compile(r"\bRankings[- ]Bot\b", re.IGNORECASE),
        "Rankings-Bot",
        "106",
        "/home/operator/rankings-bot",
    ),
    (
        re.compile(r"\bcontracts-bot\b", re.IGNORECASE),
        "contracts-bot",
        "105",
        "/home/operator/contracts-bot",
    ),
    (
        re.compile(r"\bmarket-pie5-bot\b", re.IGNORECASE),
        "market-pie5-bot",
        "102",
        "/home/operator/market-pie5-bot",
    ),
)

_FAILURE_CLASS_PATTERNS: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"\b(Code Quality|Lint)\b.*\bfailed\b", re.IGNORECASE | re.DOTALL), "lint"),
    (re.compile(r"\bLint\b.*\bfailed\b", re.IGNORECASE | re.DOTALL), "lint"),
    (re.compile(r"\bTests?\b.*\bfailed\b", re.IGNORECASE | re.DOTALL), "unit"),
    (re.compile(r"\bSecurity Scan\b.*\bfailed\b", re.IGNORECASE | re.DOTALL), "security"),
    (re.compile(r"\bEnd-to-End\b.*\bfailed\b", re.IGNORECASE | re.DOTALL), "e2e"),
    (re.compile(r"\bworkflow_run\b", re.IGNORECASE), "workflow"),
    (re.compile(r"actions/runs/\d+", re.IGNORECASE), "workflow"),
)

_CI_MARKER = re.compile(
    r"(github\.com/.+?/actions|workflow_run|pull_request|"
    r"failed:\s*(Tests|Lint|Code Quality|Security|End-to-End))",
    re.IGNORECASE,
)

# Commands mirror each repo's .github/workflows/* (read from owning hosts 2026-07-11).
_REPRODUCE_BY_KEY: dict[tuple[str, str], tuple[str, str | None]] = {
    # (repo_slug, failure_class) -> (shell_command, catalog_action_key)
    (
        "Rankings-Bot",
        "lint",
    ): (
        "cd /home/operator/rankings-bot && git pull --ff-only origin main && "
        "python3 -m pip install -q flake8 pylint black isort bandit && "
        "flake8 api scrapers database tests --count --select=E9,F63,F7,F82 "
        "--show-source --statistics",
        "ci_repro_rankings_lint",
    ),
    (
        "contracts-bot",
        "unit",
    ): (
        "cd /home/operator/contracts-bot && git pull --ff-only origin main && "
        "python3 -m pip install -q pytest pytest-cov pytest-asyncio && "
        "pip install -q -r requirements.txt && "
        "JWT_SECRET=ci-test-jwt-secret-do-not-use-in-production "
        "ADMIN_USERNAME=Bama ADMIN_PASSWORD=RT LITELLM_ENABLED=false "
        "pytest tests/backend/test_litellm_health.py "
        "tests/backend/test_ai_trust_boundary.py tests/test_captcha_service.py "
        "tests/test_email_service.py -v --tb=short --maxfail=10",
        "ci_repro_contracts_tests",
    ),
    (
        "market-pie5-bot",
        "unit",
    ): (
        "cd /home/operator/market-pie5-bot && git pull --ff-only origin main && "
        "python3 -m pip install -q pytest pytest-cov pytest-xdist pytest-timeout "
        "pytest-asyncio && ENABLE_PDT_RULES=false NON_INTERACTIVE=true "
        "pytest test_mode_override.py -v --tb=short --maxfail=5",
        "ci_repro_market_tests",
    ),
    (
        "market-pie5-bot",
        "lint",
    ): (
        "cd /home/operator/market-pie5-bot && git pull --ff-only origin main && "
        "python3 -m pip install -q flake8 pylint black isort && "
        "flake8 . --count --select=E9,F63,F7,F82 --show-source --statistics "
        "--exclude=venv,.venv,node_modules,.git,__pycache__",
        None,
    ),
}

# Fallback failure_class when repo is known but job name is ambiguous.
_DEFAULT_FAILURE_BY_REPO: dict[str, str] = {
    "Rankings-Bot": "lint",
    "contracts-bot": "unit",
    "market-pie5-bot": "unit",
}


@dataclass(frozen=True, slots=True)
class CiTriageResult:
    repo: str
    host: str
    repo_dir: str
    failure_class: str
    root_cause_guess: str
    reproduce_command: str
    catalog_action_key: str | None
    cursor_handoff: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "repo": self.repo,
            "host": self.host,
            "repo_dir": self.repo_dir,
            "failure_class": self.failure_class,
            "root_cause_guess": self.root_cause_guess,
            "reproduce_command": self.reproduce_command,
            "catalog_action_key": self.catalog_action_key,
            "cursor_handoff": self.cursor_handoff,
        }


def _detect_repo(text: str) -> tuple[str, str, str] | None:
    for pattern, slug, host, repo_dir in _REPO_PATTERNS:
        if pattern.search(text):
            return slug, host, repo_dir
    return None


def _detect_failure_class(text: str, repo_slug: str) -> str:
    for pattern, failure_class in _FAILURE_CLASS_PATTERNS:
        if pattern.search(text):
            return failure_class
    return _DEFAULT_FAILURE_BY_REPO.get(repo_slug, "workflow")


def _root_cause_guess(failure_class: str, snippet: str) -> str:
    lower = snippet.lower()
    if "flake8" in lower or "e9" in lower or "f82" in lower:
        return "Python lint/syntax error (flake8 critical select)"
    if "black" in lower or "format" in lower:
        return "Code formatting check failed (black)"
    if "isort" in lower:
        return "Import sort check failed (isort)"
    if "pytest" in lower or "assert" in lower or "failed:" in lower:
        return "Unit/integration test failure (pytest)"
    if "bandit" in lower or "security" in lower:
        return "Security scan finding (bandit or workflow security job)"
    if failure_class == "lint":
        return "Lint job failed; reproduce flake8/black/isort on owning host"
    if failure_class == "unit":
        return "Tests job failed; reproduce pytest suite on owning host"
    return f"CI {failure_class} job failed; paste log tail if reproduce differs"


def _build_cursor_handoff(
    *,
    repo: str,
    host: str,
    repo_dir: str,
    failure_class: str,
    root_cause: str,
    reproduce_command: str,
    snippet: str,
) -> str:
    log_tail = snippet.strip()
    if len(log_tail) > 2000:
        log_tail = log_tail[-2000:]
    return (
        f"Fix CI failure in {repo} ({failure_class}).\n"
        f"Owning host: .{host} clone at {repo_dir}.\n"
        f"Root cause guess: {root_cause}\n"
        f"Reproduce (already run or Approve to run via Ask ALFa):\n"
        f"{reproduce_command}\n\n"
        f"CI snippet:\n{log_tail}\n\n"
        "Edit only the files needed for this failure. Run the same reproduce "
        "command locally before commit. Commit and push from the owning host clone."
    )


def try_parse_ci_triage(message: str) -> CiTriageResult | None:
    """Return structured triage when message looks like a CI failure paste."""
    text = (message or "").strip()
    if len(text) < 40:
        return None
    if not _CI_MARKER.search(text):
        return None

    repo_info = _detect_repo(text)
    if repo_info is None:
        return None

    repo_slug, host, repo_dir = repo_info
    failure_class = _detect_failure_class(text, repo_slug)
    key = (repo_slug, failure_class)
    reproduce_entry = _REPRODUCE_BY_KEY.get(key)
    if reproduce_entry is None:
        # Try default failure class for repo.
        default_fc = _DEFAULT_FAILURE_BY_REPO.get(repo_slug, "unit")
        reproduce_entry = _REPRODUCE_BY_KEY.get((repo_slug, default_fc))
        if reproduce_entry is None:
            return None
        failure_class = default_fc

    reproduce_command, catalog_action_key = reproduce_entry
    root_cause = _root_cause_guess(failure_class, text)
    handoff = _build_cursor_handoff(
        repo=repo_slug,
        host=host,
        repo_dir=repo_dir,
        failure_class=failure_class,
        root_cause=root_cause,
        reproduce_command=reproduce_command,
        snippet=text,
    )
    return CiTriageResult(
        repo=repo_slug,
        host=host,
        repo_dir=repo_dir,
        failure_class=failure_class,
        root_cause_guess=root_cause,
        reproduce_command=reproduce_command,
        catalog_action_key=catalog_action_key,
        cursor_handoff=handoff,
    )


def _build_catalog_commands() -> dict[str, str]:
    out: dict[str, str] = {}
    for (_slug, _fc), (cmd, catalog_key) in _REPRODUCE_BY_KEY.items():
        if catalog_key:
            out[catalog_key] = cmd
    return out


def catalog_action_command(action_key: str) -> str | None:
    """Shell command for a consumer_ci catalog action."""
    return _build_catalog_commands().get(action_key)
