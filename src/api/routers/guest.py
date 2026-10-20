"""Guest chat: anonymous demo sessions with per-IP rate limiting."""

from __future__ import annotations

import json
import logging
import uuid
from typing import Any, AsyncGenerator, Literal

import httpx
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from src.api.admin_network import get_client_ip
from src.api.deps import get_ai_setting_store
from src.api.guest_rate_limit import (
    GUEST_MAX_MESSAGES,
    GUEST_WINDOW_SEC,
    check_guest_rate_limit,
)
from src.api.llm_config import llm_tuple
from src.api.models.ai_setting import AiSettingStore
from src.api.qwen_mode import apply_qwen_mode_to_payload, thinking_phrases_from_setting
from src.api.public_errors import (
    UPSTREAM_UNAVAILABLE,
    log_upstream_failure,
    raise_upstream_http_exception,
    sse_public_error_payload,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/alfa-ai/api/guest", tags=["guest"])

# Per-IP sliding window: max messages per window. docs/AUTH_ACCOUNT_LIFECYCLE.md
# Enforcement: Redis when REDIS_URL is set (shared across workers); else memory.
GUEST_MAX_HISTORY = 6  # max messages in context to keep costs down

DEMO_PROMPTS = [
    "Explain quantum computing in simple terms",
    "Write a Python script to analyze CSV data",
    "How would you set up a Kubernetes cluster?",
    "Draft a business email about project delays",
    "What are the OWASP Top 10 security risks?",
    "Compare React, Vue, and Svelte for a new project",
]


class GuestChatMessage(BaseModel):
    # Guests may only send conversation turns. The server prepends its own system
    # prompt; a caller-supplied ``system`` (or ``tool``/other) role would override it,
    # so anything but user/assistant is rejected with 422 (org review 2026-09-25).
    # Integrations that need a primer (e.g. example-site-perch) send it as a leading
    # user/assistant pair, which stays within GUEST_MAX_HISTORY.
    role: Literal["user", "assistant"]
    content: str


class GuestChatRequest(BaseModel):
    messages: list[GuestChatMessage] = Field(..., min_length=1, max_length=GUEST_MAX_HISTORY)
    session_id: str | None = None
    stream: bool = False
    qwen_mode: str | None = None


GUEST_SYSTEM_PROMPT = (
    "You are ALFa AI, an intelligent assistant. "
    "You are helpful, concise, and professional. This is a demo session — "
    "the user is exploring your capabilities. Be impressive but honest. "
    "You have no access to data, accounts, or records from any other website, product, or "
    "business (e.g. ProBilliards/rankings, market-pie5, contracts, credit-check, atems). "
    "You cannot search the internet or browse the web. "
    "If asked about another site or app's specific data, say you don't have access to that "
    "information rather than guessing."
)


@router.get("/config")
def guest_config(settings: AiSettingStore = Depends(get_ai_setting_store)) -> dict:
    return {
        "demo_prompts": DEMO_PROMPTS,
        "max_messages": GUEST_MAX_MESSAGES,
        "window_sec": GUEST_WINDOW_SEC,
        "session_id": str(uuid.uuid4()),
        "thinking_phrases": thinking_phrases_from_setting(settings.get("chat_thinking_label", "")),
    }


@router.post("/chat")
async def guest_chat(body: GuestChatRequest, request: Request) -> Any:
    # Prefer Uvicorn-resolved client (respects trusted proxy headers); fallback XFF.
    ip = get_client_ip(request) or "unknown"
    check_guest_rate_limit(ip)

    base, key, model, timeout = llm_tuple(role="guest")
    if not key:
        logger.error("guest_chat: LiteLLM API key missing")
        raise HTTPException(status_code=503, detail=UPSTREAM_UNAVAILABLE)

    # Prepend system prompt
    api_messages = [{"role": "system", "content": GUEST_SYSTEM_PROMPT}]
    api_messages.extend([m.model_dump() for m in body.messages[-GUEST_MAX_HISTORY:]])

    payload: dict[str, Any] = {
        "model": model,
        "messages": api_messages,
        "temperature": 0.4,
        "max_tokens": 1024,
    }
    payload = apply_qwen_mode_to_payload(payload, model, body.qwen_mode)

    if body.stream:
        payload["stream"] = True
        return StreamingResponse(
            _stream_sse(base, key, timeout, payload),
            media_type="text/event-stream",
            headers={"Cache-Control": "no-cache"},
        )

    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(timeout, connect=10.0)) as client:
            resp = await client.post(
                f"{base}/v1/chat/completions",
                headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
                json=payload,
            )
    except httpx.RequestError as exc:
        raise_upstream_http_exception(
            upstream_status=None,
            location="guest.non_stream",
            logger=logger,
            exc=exc,
        )

    if resp.status_code != 200:
        raise_upstream_http_exception(
            upstream_status=resp.status_code,
            location="guest.non_stream",
            logger=logger,
            response_text=resp.text,
        )

    return resp.json()


async def _stream_sse(
    base: str, key: str, timeout: float, payload: dict,
) -> AsyncGenerator[str, None]:
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(timeout, connect=10.0)) as client:
            async with client.stream(
                "POST",
                f"{base}/v1/chat/completions",
                headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
                json=payload,
            ) as resp:
                if resp.status_code != 200:
                    error_body = await resp.aread()
                    log_upstream_failure(
                        logger,
                        location="guest.stream",
                        status_code=resp.status_code,
                        response_text=error_body.decode(errors="replace"),
                    )
                    yield f"data: {json.dumps(sse_public_error_payload(upstream_status=resp.status_code))}\n\n"
                    return

                async for line in resp.aiter_lines():
                    if not line.startswith("data: "):
                        continue
                    raw = line[6:]
                    if raw.strip() == "[DONE]":
                        yield "data: [DONE]\n\n"
                        break
                    yield f"data: {raw}\n\n"
    except httpx.RequestError as exc:
        log_upstream_failure(logger, location="guest.stream", exc=exc)
        yield f"data: {json.dumps(sse_public_error_payload())}\n\n"
