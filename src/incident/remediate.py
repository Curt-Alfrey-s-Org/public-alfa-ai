"""Apply admin-approved remediation proposals (GitHub PR or ops record)."""

from __future__ import annotations

import base64
import logging
import os
import re
import time
from dataclasses import dataclass
from typing import Any

import httpx

from src.api.models.incident import IncidentRecord, IncidentRemediationRecord
from src.incident.analyze_policy import ProposalPolicyError, validate_file_proposal

logger = logging.getLogger(__name__)


@dataclass(slots=True)
class ApplyResult:
    ok: bool
    message: str
    pr_url: str | None = None


def remediation_enabled() -> bool:
    raw = (os.getenv("ALFA_AI_REMEDIATION_ENABLED") or "false").strip().lower()
    return raw in ("1", "true", "yes", "on")


def _github_token() -> str:
    return (os.getenv("ALFA_AI_REMEDIATION_GITHUB_TOKEN") or "").strip()


def _repo_slug(target_repo: str) -> str:
    if target_repo == "monitoring":
        return (os.getenv("ALFA_AI_REMEDIATION_MONITORING_REPO") or "example/monitoring").strip()
    return (os.getenv("ALFA_AI_REMEDIATION_ALFA_REPO") or "example/alfa-ai").strip()


def _github_headers() -> dict[str, str]:
    token = _github_token()
    if not token:
        raise RuntimeError("ALFA_AI_REMEDIATION_GITHUB_TOKEN is not configured")
    return {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }


def _safe_branch_suffix(incident_id: str) -> str:
    cleaned = re.sub(r"[^a-zA-Z0-9]", "", incident_id)[:8]
    return cleaned or "incident"


def _get_default_branch(client: httpx.Client, repo_slug: str) -> str:
    response = client.get(f"https://api.github.com/repos/{repo_slug}", headers=_github_headers())
    response.raise_for_status()
    data = response.json()
    return str(data.get("default_branch") or "main")


def _get_ref_sha(client: httpx.Client, repo_slug: str, branch: str) -> str:
    response = client.get(
        f"https://api.github.com/repos/{repo_slug}/git/ref/heads/{branch}",
        headers=_github_headers(),
    )
    response.raise_for_status()
    data = response.json()
    obj = data.get("object") or {}
    return str(obj.get("sha") or "")


def _create_branch(client: httpx.Client, repo_slug: str, branch: str, sha: str) -> None:
    response = client.post(
        f"https://api.github.com/repos/{repo_slug}/git/refs",
        headers=_github_headers(),
        json={"ref": f"refs/heads/{branch}", "sha": sha},
    )
    if response.status_code == 422 and "Reference already exists" in response.text:
        return
    response.raise_for_status()


def _get_file_sha(client: httpx.Client, repo_slug: str, path: str, branch: str) -> str | None:
    encoded_path = path.lstrip("/")
    response = client.get(
        f"https://api.github.com/repos/{repo_slug}/contents/{encoded_path}",
        headers=_github_headers(),
        params={"ref": branch},
    )
    if response.status_code == 404:
        return None
    response.raise_for_status()
    return str(response.json().get("sha") or "")


def _commit_file(
    client: httpx.Client,
    repo_slug: str,
    *,
    branch: str,
    path: str,
    content: str,
    message: str,
    file_sha: str | None,
) -> None:
    encoded_path = path.lstrip("/")
    body: dict[str, Any] = {
        "message": message,
        "content": base64.b64encode(content.encode("utf-8")).decode("ascii"),
        "branch": branch,
    }
    if file_sha:
        body["sha"] = file_sha
    response = client.put(
        f"https://api.github.com/repos/{repo_slug}/contents/{encoded_path}",
        headers=_github_headers(),
        json=body,
    )
    response.raise_for_status()


def _open_pull_request(
    client: httpx.Client,
    repo_slug: str,
    *,
    branch: str,
    base: str,
    title: str,
    body: str,
) -> str:
    response = client.post(
        f"https://api.github.com/repos/{repo_slug}/pulls",
        headers=_github_headers(),
        json={"title": title, "head": branch, "base": base, "body": body},
    )
    response.raise_for_status()
    data = response.json()
    return str(data.get("html_url") or "")


def apply_proposal(
    incident: IncidentRecord,
    proposal: IncidentRemediationRecord,
    *,
    force: bool = False,
) -> ApplyResult:
    """Apply a proposal: ops_action is recorded only; file changes open a GitHub PR."""
    if not remediation_enabled():
        return ApplyResult(ok=False, message="Remediation is disabled (ALFA_AI_REMEDIATION_ENABLED).")

    if proposal.status != "proposed":
        return ApplyResult(ok=False, message=f"Proposal status is {proposal.status}, not proposed.")

    if proposal.confidence == "low" and not force:
        return ApplyResult(
            ok=False,
            message="Proposal confidence is low; set force=true after operator verification.",
        )

    if proposal.classification == "ops_action":
        return ApplyResult(
            ok=True,
            message="Ops action recorded. Run the proposed steps manually; no PR opened.",
            pr_url=None,
        )

    if not proposal.target_path:
        return ApplyResult(ok=False, message="Proposal missing target_path for file-based fix.")

    try:
        validate_file_proposal(proposal.target_path, proposal.proposed_change)
    except ProposalPolicyError as exc:
        return ApplyResult(ok=False, message=str(exc))

    token = _github_token()
    if not token:
        return ApplyResult(ok=False, message="ALFA_AI_REMEDIATION_GITHUB_TOKEN is not configured.")

    repo_slug = _repo_slug(proposal.target_repo)
    branch = f"alfa-ai/remediate-{_safe_branch_suffix(incident.id)}-{int(time.time())}"
    commit_message = f"alfa-ai: remediate {incident.alertname} (incident {incident.id[:8]})"
    pr_title = f"alfa-ai: remediate {incident.alertname}"
    pr_body = (
        f"Automated remediation proposal for incident `{incident.id}`.\n\n"
        f"**Classification:** {proposal.classification}\n\n"
        f"**Root cause:** {proposal.root_cause}\n\n"
        f"**Rationale:** {proposal.rationale or 'n/a'}\n\n"
        "Review and merge on the owning host, then deploy per cluster sync order."
    )

    try:
        with httpx.Client(timeout=60) as client:
            base_branch = _get_default_branch(client, repo_slug)
            base_sha = _get_ref_sha(client, repo_slug, base_branch)
            if not base_sha:
                return ApplyResult(ok=False, message="Could not resolve base branch SHA.")
            _create_branch(client, repo_slug, branch, base_sha)
            file_sha = _get_file_sha(client, repo_slug, proposal.target_path, base_branch)
            _commit_file(
                client,
                repo_slug,
                branch=branch,
                path=proposal.target_path,
                content=proposal.proposed_change,
                message=commit_message,
                file_sha=file_sha,
            )
            pr_url = _open_pull_request(
                client,
                repo_slug,
                branch=branch,
                base=base_branch,
                title=pr_title,
                body=pr_body,
            )
    except httpx.HTTPStatusError as exc:
        detail = (exc.response.text or str(exc))[:500]
        logger.exception("GitHub apply failed for incident %s", incident.id)
        return ApplyResult(ok=False, message=f"GitHub API error: {detail}")
    except Exception as exc:
        logger.exception("apply_proposal failed for incident %s", incident.id)
        return ApplyResult(ok=False, message=str(exc)[:500])

    if not pr_url:
        return ApplyResult(ok=False, message="Pull request created but URL missing.")

    return ApplyResult(ok=True, message="Pull request opened.", pr_url=pr_url)
