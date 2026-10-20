"""Read-only GitHub Actions context for Ask ALFa (token-gated).

Uses official GitHub REST API:
https://docs.github.com/en/rest/actions/workflow-runs

Default off until ALFA_AI_GITHUB_TOKEN (or ALFA_AI_REMEDIATION_GITHUB_TOKEN) is set.
"""

from __future__ import annotations

import logging
import os
from typing import Any

import httpx

logger = logging.getLogger(__name__)

_ALLOWLIST_REPOS: tuple[str, ...] = (
    "example/contracts-bot",
    "example/Rankings-Bot",
    "example/market-pie5-bot",
)

_LOG_TRIM_CHARS = 10_000


def github_token_configured() -> bool:
    return bool(_github_token())


def _github_token() -> str:
    return (
        (os.getenv("ALFA_AI_GITHUB_TOKEN") or "").strip()
        or (os.getenv("ALFA_AI_REMEDIATION_GITHUB_TOKEN") or "").strip()
    )


async def fetch_github_ci_context() -> dict[str, Any] | None:
    """Latest failed workflow runs for allowlisted repos (read-only)."""
    token = _github_token()
    if not token:
        return None

    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    out: dict[str, Any] = {"repos": [], "configured": True}
    async with httpx.AsyncClient(timeout=20.0) as client:
        for full_name in _ALLOWLIST_REPOS:
            owner, repo = full_name.split("/", 1)
            try:
                runs_resp = await client.get(
                    f"https://api.github.com/repos/{owner}/{repo}/actions/runs",
                    headers=headers,
                    params={"status": "failure", "per_page": 3},
                )
                if runs_resp.status_code == 401:
                    logger.warning("github_ci: token unauthorized")
                    return {"configured": True, "error": "github_token_unauthorized", "repos": []}
                if runs_resp.status_code == 403:
                    logger.warning("github_ci: token forbidden for %s", full_name)
                    continue
                runs_resp.raise_for_status()
                runs_data = runs_resp.json()
                workflow_runs = runs_data.get("workflow_runs") or []
                if not workflow_runs:
                    out["repos"].append({"repo": full_name, "latest_failure": None})
                    continue
                run = workflow_runs[0]
                run_id = run.get("id")
                log_excerpt = ""
                if run_id:
                    jobs_resp = await client.get(
                        f"https://api.github.com/repos/{owner}/{repo}/actions/runs/{run_id}/jobs",
                        headers=headers,
                        params={"per_page": 5},
                    )
                    if jobs_resp.is_success:
                        jobs = (jobs_resp.json().get("jobs") or [])[:2]
                        for job in jobs:
                            log_excerpt += (
                                f"\n--- job {job.get('name')} "
                                f"({job.get('conclusion')}) ---\n"
                            )
                            steps = job.get("steps") or []
                            for step in steps[-3:]:
                                if step.get("conclusion") == "failure":
                                    log_excerpt += (
                                        f"step failed: {step.get('name')}\n"
                                    )
                if len(log_excerpt) > _LOG_TRIM_CHARS:
                    log_excerpt = log_excerpt[-_LOG_TRIM_CHARS:]
                out["repos"].append(
                    {
                        "repo": full_name,
                        "latest_failure": {
                            "id": run_id,
                            "name": run.get("name"),
                            "head_branch": run.get("head_branch"),
                            "html_url": run.get("html_url"),
                            "created_at": run.get("created_at"),
                            "log_excerpt": log_excerpt.strip(),
                        },
                    }
                )
            except httpx.HTTPError as exc:
                logger.warning("github_ci fetch failed for %s: %s", full_name, exc)
                out["repos"].append({"repo": full_name, "error": str(exc)})
    return out
