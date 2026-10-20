"""User-facing error messages vs server logs.

Visitors must not see upstream stack traces, internal hostnames, or LiteLLM/Ollama
details. Log full context here; return only generic copy from HTTP/SSE responses.
"""

from __future__ import annotations

import logging

UPSTREAM_UNAVAILABLE = (
    "The assistant is temporarily unavailable. Please try again later."
)
RATE_LIMIT_GENERIC = "Too many requests. Please wait a moment and try again."
UNEXPECTED_ERROR = "Something went wrong. Please try again later."
INVALID_CREDENTIALS_MSG = "Invalid email, username, or password"
AUTH_FAILED_MSG = "Authentication failed"
REGISTRATION_FAILED_MSG = "Registration could not be completed"
EMAIL_NOT_VERIFIED_MSG = (
    "Please verify your email address first. Check your inbox for the confirmation link."
)
ACCOUNT_PENDING_APPROVAL_MSG = (
    "Your account is pending admin approval. Please contact the administrator."
)
SERVICE_UNAVAILABLE = "Service temporarily unavailable."
ACCESS_DENIED_MSG = "Access denied."


def log_upstream_failure(
    logger: logging.Logger,
    *,
    location: str,
    status_code: int | None = None,
    response_text: str | None = None,
    exc: BaseException | None = None,
) -> None:
    prefix = f"upstream_failure location={location}"
    if status_code is not None:
        prefix += f" http_status={status_code}"
    if response_text:
        logger.error("%s response_body=%s", prefix, response_text[:8000])
    if exc is not None:
        logger.error("%s", prefix, exc_info=exc)
    elif not response_text:
        logger.error("%s", prefix)


def raise_upstream_http_exception(
    *,
    upstream_status: int | None,
    location: str,
    logger: logging.Logger,
    response_text: str | None = None,
    exc: BaseException | None = None,
) -> None:
    """Log details then raise HTTPException with a generic ``detail``."""
    from fastapi import HTTPException

    log_upstream_failure(
        logger,
        location=location,
        status_code=upstream_status,
        response_text=response_text,
        exc=exc,
    )

    if upstream_status == 429:
        raise HTTPException(status_code=429, detail=RATE_LIMIT_GENERIC)

    raise HTTPException(status_code=502, detail=UPSTREAM_UNAVAILABLE)


def sse_public_error_payload(*, upstream_status: int | None = None) -> dict[str, str]:
    if upstream_status == 429:
        return {"error": RATE_LIMIT_GENERIC}
    return {"error": UPSTREAM_UNAVAILABLE}
