"""Chat router: conversation CRUD, LiteLLM proxy with SSE streaming, JWT auth."""

from __future__ import annotations

import json
import logging
from dataclasses import asdict
from typing import Any, AsyncGenerator

import httpx
from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from src.api.deps import get_ai_setting_store, get_conversation_store, get_current_user
from src.api.llm_config import (
    chat_models_for_ui,
    llm_tuple,
    sanitize_chat_model_alias,
)
from src.api.pool_targets import detect_active_pool
from src.api.qwen_mode import (
    apply_qwen_mode_to_payload,
    default_qwen_mode_for_model,
    is_qwen_hybrid_model,
    qwen_modes_for_ui,
    strip_think_tags,
    thinking_phrases_from_setting,
)
from src.api.models.ai_setting import AiSettingStore
from src.api.models.conversation import ConversationStore
from src.api.models.user import UserRecord
from src.api.public_errors import (
    UPSTREAM_UNAVAILABLE,
    log_upstream_failure,
    raise_upstream_http_exception,
    sse_public_error_payload,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/alfa-ai/api", tags=["chat"])


class ChatMessage(BaseModel):
    role: str
    content: str


class ChatRequest(BaseModel):
    messages: list[ChatMessage] = Field(..., min_length=1)
    model: str | None = None
    conversation_id: str | None = None
    stream: bool = False
    # Qwen hybrid: precise = thinking + thinking_budget; instruct = enable_thinking false
    qwen_mode: str | None = None


class ConversationCreateRequest(BaseModel):
    title: str = "New chat"
    model: str | None = None


class ConversationRenameRequest(BaseModel):
    title: str = Field(..., min_length=1, max_length=200)


class MessageEditRequest(BaseModel):
    content: str = Field(..., min_length=1, max_length=100_000)


# ── Conversations ────────────────────────────────────────────

@router.get("/conversations")
def list_conversations(
    user: UserRecord = Depends(get_current_user),
    store: ConversationStore = Depends(get_conversation_store),
) -> dict:
    convs = store.list_for_user(user.id)
    return {"conversations": [asdict(c) for c in convs]}


@router.post("/conversations")
def create_conversation(
    body: ConversationCreateRequest,
    user: UserRecord = Depends(get_current_user),
    store: ConversationStore = Depends(get_conversation_store),
) -> dict:
    conv = store.create(
        user.id,
        title=body.title,
        model=sanitize_chat_model_alias(body.model) if body.model else None,
    )
    return {"conversation": asdict(conv)}


@router.get("/conversations/{conv_id}")
def get_conversation(
    conv_id: str,
    user: UserRecord = Depends(get_current_user),
    store: ConversationStore = Depends(get_conversation_store),
) -> dict:
    conv = store.get(conv_id)
    if conv is None or conv.user_id != user.id:
        raise HTTPException(status_code=404, detail="Conversation not found")
    messages = store.get_messages(conv_id)
    return {"conversation": asdict(conv), "messages": [asdict(m) for m in messages]}


@router.patch("/conversations/{conv_id}")
def rename_conversation(
    conv_id: str,
    body: ConversationRenameRequest,
    user: UserRecord = Depends(get_current_user),
    store: ConversationStore = Depends(get_conversation_store),
) -> dict:
    conv = store.get(conv_id)
    if conv is None or conv.user_id != user.id:
        raise HTTPException(status_code=404, detail="Conversation not found")
    store.update_title(conv_id, body.title)
    return {"ok": True}


@router.delete("/conversations/{conv_id}")
def delete_conversation(
    conv_id: str,
    user: UserRecord = Depends(get_current_user),
    store: ConversationStore = Depends(get_conversation_store),
) -> dict:
    conv = store.get(conv_id)
    if conv is None or conv.user_id != user.id:
        raise HTTPException(status_code=404, detail="Conversation not found")
    store.delete(conv_id)
    return {"ok": True}


@router.patch("/conversations/{conv_id}/messages/{msg_id}")
def edit_message(
    conv_id: str,
    msg_id: str,
    body: MessageEditRequest,
    user: UserRecord = Depends(get_current_user),
    store: ConversationStore = Depends(get_conversation_store),
) -> dict:
    conv = store.get(conv_id)
    if conv is None or conv.user_id != user.id:
        raise HTTPException(status_code=404, detail="Conversation not found")
    existing = store.get_message(msg_id)
    if existing is None or existing.conversation_id != conv_id:
        raise HTTPException(status_code=404, detail="Message not found")
    if existing.role != "user":
        raise HTTPException(status_code=400, detail="Only user messages can be edited")
    updated = store.update_user_message(conv_id, msg_id, body.content.strip())
    if updated is None:
        raise HTTPException(status_code=404, detail="Message not found")
    store.delete_messages_after(conv_id, msg_id)
    store.touch(conv_id)
    messages = store.get_messages(conv_id)
    return {"messages": [asdict(m) for m in messages]}


# ── Chat (non-streaming + SSE streaming) ─────────────────────

@router.post("/chat")
async def chat(
    body: ChatRequest,
    user: UserRecord = Depends(get_current_user),
    conv_store: ConversationStore = Depends(get_conversation_store),
) -> Any:
    base, key, default_model, timeout = llm_tuple(role="chat")
    if not key:
        logger.error("chat: LiteLLM API key missing (LITELLM_API_KEY / LITELLM_MASTER_KEY)")
        raise HTTPException(status_code=503, detail=UPSTREAM_UNAVAILABLE)

    conv_id = body.conversation_id
    if conv_id:
        conv = conv_store.get(conv_id)
        if conv is None or conv.user_id != user.id:
            raise HTTPException(status_code=404, detail="Conversation not found")
        model = sanitize_chat_model_alias(body.model or conv.model or default_model)
    else:
        model = sanitize_chat_model_alias(body.model or default_model)
        first_msg = body.messages[0].content[:80] if body.messages else "New chat"
        conv = conv_store.create(user.id, title=first_msg, model=model)
        conv_id = conv.id

    # Persist user message (skip if already stored — e.g. after edit + regenerate).
    last_user_msg = next((m for m in reversed(body.messages) if m.role == "user"), None)
    if last_user_msg:
        existing = conv_store.get_messages(conv_id)
        last_db_user = next((m for m in reversed(existing) if m.role == "user"), None)
        if last_db_user is None or last_db_user.content != last_user_msg.content:
            conv_store.add_message(conv_id, "user", last_user_msg.content)

    api_messages = [m.model_dump() for m in body.messages]
    payload: dict[str, Any] = {
        "model": model,
        "messages": api_messages,
        "temperature": 0.3,
    }
    payload = apply_qwen_mode_to_payload(payload, model, body.qwen_mode)

    if body.stream:
        payload["stream"] = True
        return StreamingResponse(
            _stream_sse(base, key, timeout, payload, conv_id, conv_store),
            media_type="text/event-stream",
            headers={"Cache-Control": "no-cache", "X-Conversation-Id": conv_id},
        )

    # Non-streaming
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(timeout, connect=20.0)) as client:
            resp = await client.post(
                f"{base}/v1/chat/completions",
                headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
                json=payload,
            )
    except httpx.RequestError as exc:
        raise_upstream_http_exception(
            upstream_status=None,
            location="chat.non_stream",
            logger=logger,
            exc=exc,
        )

    if resp.status_code != 200:
        raise_upstream_http_exception(
            upstream_status=resp.status_code,
            location="chat.non_stream",
            logger=logger,
            response_text=resp.text,
        )

    data = resp.json()
    reply = data.get("choices", [{}])[0].get("message", {}).get("content", "")
    clean_reply = strip_think_tags(reply)
    if clean_reply:
        conv_store.add_message(conv_id, "assistant", clean_reply)
        conv_store.touch(conv_id)
    if data.get("choices"):
        data["choices"][0].setdefault("message", {})["content"] = clean_reply

    data["conversation_id"] = conv_id
    return data


async def _stream_sse(
    base: str,
    key: str,
    timeout: float,
    payload: dict,
    conv_id: str,
    conv_store: ConversationStore,
) -> AsyncGenerator[str, None]:
    """Stream SSE chunks from LiteLLM, accumulate full response, persist on done."""
    full_content = ""
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(timeout, connect=20.0)) as client:
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
                        location="chat.stream",
                        status_code=resp.status_code,
                        response_text=error_body.decode(errors="replace"),
                    )
                    yield f"data: {json.dumps(sse_public_error_payload(upstream_status=resp.status_code))}\n\n"
                    return

                # Send conversation_id as first event
                yield f"data: {json.dumps({'conversation_id': conv_id})}\n\n"

                async for line in resp.aiter_lines():
                    if not line.startswith("data: "):
                        continue
                    raw = line[6:]
                    if raw.strip() == "[DONE]":
                        yield "data: [DONE]\n\n"
                        break
                    try:
                        chunk = json.loads(raw)
                        delta = chunk.get("choices", [{}])[0].get("delta", {})
                        content = delta.get("content", "")
                        if content:
                            full_content += content
                        yield f"data: {raw}\n\n"
                    except json.JSONDecodeError:
                        yield f"data: {raw}\n\n"
    except httpx.RequestError as exc:
        log_upstream_failure(logger, location="chat.stream", exc=exc)
        yield f"data: {json.dumps(sse_public_error_payload())}\n\n"

    # Persist the full assistant response (stripped of <think> reasoning blocks --
    # the live SSE chunks already sent to the client keep the raw tags so the
    # frontend can show a "thinking" indicator while streaming).
    clean_content = strip_think_tags(full_content)
    if clean_content:
        try:
            conv_store.add_message(conv_id, "assistant", clean_content)
            conv_store.touch(conv_id)
        except Exception:
            logger.exception("Failed to persist streamed response")


@router.get("/config")
def chat_config(
    user: UserRecord = Depends(get_current_user),
    settings: AiSettingStore = Depends(get_ai_setting_store),
) -> dict[str, Any]:
    _, _, model, _ = llm_tuple(role="chat")
    model = sanitize_chat_model_alias(model)
    options = chat_models_for_ui()
    out: dict[str, Any] = {
        "chat_model": model,
        "models": options,
        "qwen_modes": qwen_modes_for_ui(),
        "default_qwen_mode": default_qwen_mode_for_model(model),
        "qwen_mode_supported": is_qwen_hybrid_model(model),
        "thinking_phrases": thinking_phrases_from_setting(settings.get("chat_thinking_label", "")),
    }
    if user.has_role("admin"):
        out["pool_switch"] = {
            "enabled": True,
            "active_pool": detect_active_pool(),
        }
    return out
