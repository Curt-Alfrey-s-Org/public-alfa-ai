"""Pattern C agent HTTP surfaces: review API (and future agent endpoints)."""

from __future__ import annotations

import logging
from typing import Any

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from src.api.auth_deps import require_alfa_ai_api_token
from src.runtime.review_service import run_review

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/agent", tags=["agent"])


class ReviewRequest(BaseModel):
    repo: str
    goal: str = ""
    diff: str = ""
    focus: str = "correctness"
    paths: list[str] = Field(default_factory=list)
    max_issues: int = 50


@router.post("/review")
def agent_review(
    payload: ReviewRequest,
    _: None = Depends(require_alfa_ai_api_token),
) -> dict[str, Any]:
    """Structured code review for LiteLLM consumers (contracts-bot, etc.).

    Auth: Bearer ALFA_AI_API_TOKEN (same as POST /api/runs).
    """
    try:
        return run_review(
            repo=payload.repo,
            goal=payload.goal,
            diff=payload.diff,
            focus=payload.focus,
            paths=payload.paths,
            max_issues=payload.max_issues,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:  # noqa: BLE001
        logger.exception("agent review failed")
        raise HTTPException(
            status_code=503,
            detail=f"Review unavailable: {exc}",
        ) from exc
