"""Admin router: user management, audit log, IP blocks, file browser, cluster health, model management."""

from __future__ import annotations

import asyncio
import json
import logging
import os
import queue
import re
import time
from collections.abc import AsyncGenerator, Callable
from dataclasses import asdict
from pathlib import Path
from typing import Any, Literal, Self

import httpx
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import Response, StreamingResponse
from pydantic import BaseModel, ConfigDict, EmailStr, Field, model_validator

from src.api.admin_network import require_admin_client_network
from src.api.ask_alfa_context import (
    ASK_ALFA_AI_ACTIONS_FETCH_LIMIT,
    ASK_ALFA_AI_ACTIONS_JOB_CAP,
    ASK_ALFA_DUMP_OBSERVE_SAMPLE_CAP,
    INSPECT_COMPACT_KEEP_LAST,
    LLM_ACTIVITY_OMIT_KEYS,
    _ACTIVITY_CONTEXT_MAX_CHARS,
    _OPS_CONTEXT_MAX_CHARS,
    activity_facts_meta,
    build_context_usage,
    build_inspect_compact_user_message,
    compact_inspect_steps,
    compact_inspect_tool_content,
    is_pending_propose_tool_content,
    split_ai_actions_for_ask_alfa,
    split_ask_alfa_context,
)
from src.api.ask_alfa_router import (
    annotate_reply_if_no_proposal,
    parse_draft_judge_task,
    try_handle_deterministic,
)
from src.llm.agent_circuit import AgentCircuitOpenError
from src.api.deps import (
    get_agent_config_store,
    get_ai_action_store,
    get_ai_setting_store,
    get_host_action_store,
    get_security_store,
    get_user_store,
    get_worker_store,
    get_incident_store,
    require_role,
)
from src.api.models.agent_config import DEFAULT_CONTEXT_SECTIONS, AgentConfigStore
from src.api.models.ai_action import (
    ACTION_AGENT_CONFIG_CHANGED,
    ACTION_HOST_ACTION_FEEDBACK,
    ACTION_HOST_ACTION_REJECTED,
    ACTION_HOST_COMMAND_EXECUTED,
    ACTION_HOST_INSPECT_EXECUTED,
    ACTION_PROPOSAL_FEEDBACK,
    ACTION_SETTING_CHANGED,
    ACTION_SETTING_PROPOSAL,
    ACTION_SOLAR_DUMP_ACTUATED,
    ACTION_SOLAR_DUMP_OBSERVED,
    ACTION_SOLAR_DUMP_RECOMMENDED,
    AiActionRecord,
    AiActionStore,
    category_for_action,
)
from src.api.models.host_action import HostActionRecord, HostActionStore, STATUS_PENDING
from src.api.models.ai_setting import (
    AiSettingError,
    AiSettingStore,
    POLICY_SETTING_REQUIRES_APPROVE_REASON,
    inspect_autorun_enabled,
    is_policy_setting,
    normalize_setting_input,
    setting_description,
    validate_setting_value,
)
from src.api.models.audit import SecurityStore
from src.api.routers.auth import _hash_password
from src.api.redis_heartbeat import get_worker_heartbeat
from src.api.models.incident import (
    IncidentEventRecord,
    IncidentRecord,
    IncidentRemediationRecord,
    IncidentStore,
    build_ask_alfa_incident_context,
)
from src.api.models.user import UserRecord, UserRole, UserStore
from src.api.models.worker import WorkerStore
from src.api.inference_pool_stats import build_inference_pool_stats
from src.api.worker_monitoring import (
    build_brain_services_report,
    build_cluster_hosts_report,
    build_inference_stack_report,
)
from src.ops.action_packs import (
    apply_pack_toggle,
    enable_action_in_disabled_list,
    pack_status,
    proposal_enable_meta,
)
from src.ops.bot_audit_excerpt import format_bot_audit_excerpt
from src.ops.host_catalog import (
    action_category,
    default_ssh_key_path,
    get_action_risk_tier,
    get_catalog_for_llm,
    host_actions_enabled,
    is_ha_auto_actuate,
    is_ha_inspect_action,
    is_inspectable,
    is_web_search_inspect_action,
    list_all_catalog_entries,
    list_catalog,
    list_editable_hosts,
    list_merged_hosts,
    load_hosts,
    summarize_proposal,
    validate_proposal,
)
from src.ops.inspect_executor import inspection_step_dict, run_inspect_action_sync
from src.ops.exec_result import ExecResult
from src.ops.home_assistant_client import (
    home_assistant_enabled,
    home_assistant_ready as _home_assistant_ready,
    home_assistant_token_present,
)
from src.ops.mission_fleet import build_missions_chat_context
from src.ops.solar_dump import (
    _DEFAULTS as _SOLAR_DUMP_DEFAULTS,
    _settings_dict as _solar_dump_settings_dict,
    build_home_energy_ops_context,
    get_last_dump_summary,
)
from src.runtime.learning_loop_status import collect_learning_loop_status
from src.runtime.lora_registry import sync_registry_from_hub
from src.runtime.preference_export import append_thumbs
from src.ops.prometheus_context import fetch_prometheus_ops_context
from src.ops.ssh_executor import execute_host_action

logger = logging.getLogger(__name__)

router = APIRouter(
    prefix="/alfa-ai/api/admin",
    tags=["admin"],
    dependencies=[Depends(require_admin_client_network)],
)

_WORKSPACE = Path(os.getenv("ALFA_AI_WORKSPACE_ROOT", "/workspace")).resolve()
_ALLOWED_EXTENSIONS = {
    ".py", ".js", ".ts", ".tsx", ".jsx", ".json", ".yaml", ".yml",
    ".toml", ".cfg", ".ini", ".md", ".txt", ".html", ".css", ".sql",
    ".sh", ".bash", ".dockerignore", ".gitignore",
    ".conf", ".xml", ".csv", ".rst", ".lock",
}
_MAX_FILE_SIZE = 1_000_000  # 1 MB
_WORKER_POLL_TIMEOUT = 5.0  # seconds


def _worker_unreachable_hint(error_text: str) -> str:
    """Short operator hint for common httpx / TCP failures when polling worker-monitor."""
    e = error_text.lower()
    if "connection refused" in e or "errno 111" in e:
        return (
            "TCP connection refused — worker-monitor is probably not listening on this host/port "
            "(start the monitor sidecar or open the firewall for the monitor port)."
        )
    if "timed out" in e or "timeout" in e:
        return (
            "Request timed out — host may be down, wrong LAN IP, or a firewall is dropping traffic "
            "between the API container and the worker."
        )
    if "name or service not known" in e or "nodename nor servname" in e:
        return "Hostname could not be resolved — use a numeric LAN IP in the worker registry, not a .local name."
    if "network unreachable" in e or "no route to host" in e:
        return "No network route to host — check routing/VLAN and that the IP is reachable from the Docker host."
    if "all connection attempts failed" in e:
        return (
            "All connection attempts failed — from the alfa-ai-api container, nothing answered at "
            "http://<worker-ip>:<monitor-port>/. Deploy worker-monitor on the worker and allow port access."
        )
    return "See error detail below; verify worker-monitor is running and the IP/port match the worker machine."


def _safe_path(rel: str) -> Path:
    """Resolve relative path within workspace, rejecting traversal attempts."""
    target = (_WORKSPACE / rel).resolve()
    # Component-wise containment, not a string prefix: /workspace-other must not pass
    # for workspace root /workspace (round-2 review 2026-09-26).
    try:
        target.relative_to(_WORKSPACE)
    except ValueError:
        raise HTTPException(status_code=403, detail="Path traversal not allowed") from None
    return target


# ── User management ──────────────────────────────────────────

class UpdateRoleRequest(BaseModel):
    role: UserRole


class DeactivateRequest(BaseModel):
    active: bool


class ApproveUserRequest(BaseModel):
    approved: bool = True


class MarkEmailVerifiedRequest(BaseModel):
    """Admin SMTP bypass (docs/AUTH_ACCOUNT_LIFECYCLE.md). One-way verify only."""

    verified: bool = True


class AdminCreateUserRequest(BaseModel):
    """Admin -> Users create (docs/AUTH_ACCOUNT_LIFECYCLE.md). Starts verified + approved."""

    email: EmailStr
    username: str = Field(..., min_length=3, max_length=30)
    password: str = Field(..., min_length=8, max_length=128)
    password_confirm: str = Field(..., min_length=8, max_length=128)

    @model_validator(mode="after")
    def passwords_match(self) -> Self:
        if self.password != self.password_confirm:
            raise ValueError("Password and confirmation do not match")
        return self


class AdminSetPasswordRequest(BaseModel):
    new_password: str = Field(..., min_length=8, max_length=128)
    new_password_confirm: str = Field(..., min_length=8, max_length=128)

    @model_validator(mode="after")
    def new_passwords_match(self) -> Self:
        if self.new_password != self.new_password_confirm:
            raise ValueError("New password and confirmation do not match")
        return self


@router.get("/users")
def list_users(
    _user: UserRecord = Depends(require_role("admin")),
    store: UserStore = Depends(get_user_store),
) -> dict:
    with store._conn() as conn:
        rows = conn.execute(
            """
            SELECT id, email, username, role, is_2fa_enabled, is_active,
                   email_verified, approved, approved_by, approved_at, created_at
            FROM users ORDER BY created_at
            """
        ).fetchall()
    return {"users": [dict(r) for r in rows]}


@router.patch("/users/{user_id}/approve")
def approve_user(
    user_id: str,
    body: ApproveUserRequest,
    admin: UserRecord = Depends(require_role("admin")),
    store: UserStore = Depends(get_user_store),
    sec: SecurityStore = Depends(get_security_store),
) -> dict:
    """Docs: docs/AUTH_ACCOUNT_LIFECYCLE.md — required before a self-registered
    account can log in, independent of the is_active ban/deactivate switch."""
    target = store.get_by_id(user_id)
    if target is None:
        raise HTTPException(status_code=404, detail="User not found")
    store.set_approved(user_id, body.approved, approved_by=admin.email)
    sec.record_event(
        "user_approved" if body.approved else "user_approval_revoked",
        success=True,
        user_id=target.id,
        details=f"by admin {admin.email}",
    )
    return {"ok": True}


@router.patch("/users/{user_id}/email-verified")
def mark_user_email_verified(
    user_id: str,
    body: MarkEmailVerifiedRequest,
    admin: UserRecord = Depends(require_role("admin")),
    store: UserStore = Depends(get_user_store),
    sec: SecurityStore = Depends(get_security_store),
) -> dict:
    """Docs: docs/AUTH_ACCOUNT_LIFECYCLE.md — SMTP bypass when verify mail never arrives.

    FastAPI PATCH body: https://fastapi.tiangolo.com/tutorial/body-updates/
    """
    if not body.verified:
        raise HTTPException(
            status_code=400,
            detail="This endpoint can only mark an email as verified.",
        )
    target = store.get_by_id(user_id)
    if target is None:
        raise HTTPException(status_code=404, detail="User not found")
    store.mark_email_verified(user_id)
    sec.record_event(
        "user_email_verified_by_admin",
        success=True,
        user_id=target.id,
        details=f"by admin {admin.email}",
    )
    return {"ok": True}


@router.post("/users/{user_id}/resend-verification")
def admin_resend_verification(
    user_id: str,
    admin: UserRecord = Depends(require_role("admin")),
    store: UserStore = Depends(get_user_store),
    sec: SecurityStore = Depends(get_security_store),
) -> dict:
    """Retry the same SMTP verify path (docs/AUTH_ACCOUNT_LIFECYCLE.md).

    FastAPI POST: https://fastapi.tiangolo.com/tutorial/body/
    """
    from src.api.routers.auth import _new_verify_token, _send_verification_email

    target = store.get_by_id(user_id)
    if target is None:
        raise HTTPException(status_code=404, detail="User not found")
    if target.email_verified:
        raise HTTPException(status_code=400, detail="Email is already verified.")
    token, expires = _new_verify_token()
    store.set_email_verify_token(target.id, token, expires)
    sent = _send_verification_email(target, token)
    sec.record_event(
        "user_verification_resent_by_admin",
        success=True,
        user_id=target.id,
        details=f"by admin {admin.email} smtp_sent={sent}",
    )
    if sent:
        message = "Verification email send succeeded. Ask the user to check inbox and spam."
    else:
        message = (
            "Verification email was not sent (SMTP unconfigured or send failed). "
            "Use Mark verified if the inbox stays empty."
        )
    return {"ok": True, "sent": sent, "message": message}


@router.post("/users")
def admin_create_user(
    body: AdminCreateUserRequest,
    admin: UserRecord = Depends(require_role("admin")),
    store: UserStore = Depends(get_user_store),
    sec: SecurityStore = Depends(get_security_store),
) -> dict:
    """Create a user from Admin -> Users. Starts email_verified and approved.

    FastAPI POST body: https://fastapi.tiangolo.com/tutorial/body/
    Docs: docs/AUTH_ACCOUNT_LIFECYCLE.md
    """
    from src.api.routers.auth import _USERNAME_RE, _hash_password

    if not _USERNAME_RE.match(body.username):
        raise HTTPException(
            status_code=422,
            detail="Username must be 3-30 chars: letters, digits, _ or -",
        )
    if store.get_by_email_ci(str(body.email).strip()):
        raise HTTPException(status_code=409, detail="Email or username is already in use.")
    if store.get_by_username_ci(body.username):
        raise HTTPException(status_code=409, detail="Email or username is already in use.")

    user = store.create_user(
        email=body.email,
        username=body.username,
        password_hash=_hash_password(body.password),
        role="user",
        email_verified=True,
        approved=True,
    )
    store.set_approved(user.id, True, approved_by=admin.email)
    sec.record_event(
        "user_created_by_admin",
        success=True,
        user_id=user.id,
        details=f"by admin {admin.email}",
    )
    return {
        "ok": True,
        "user": {
            "id": user.id,
            "email": user.email,
            "username": user.username,
            "email_verified": True,
            "approved": True,
        },
        "message": "User created. They can sign in now (email verified and approved).",
    }


@router.patch("/users/{user_id}/role")
def update_user_role(
    user_id: str,
    body: UpdateRoleRequest,
    _user: UserRecord = Depends(require_role("admin")),
    store: UserStore = Depends(get_user_store),
) -> dict:
    target = store.get_by_id(user_id)
    if target is None:
        raise HTTPException(status_code=404, detail="User not found")
    with store._conn() as conn:
        conn.execute(
            "UPDATE users SET role = %s, updated_at = NOW() WHERE id = %s::uuid",
            (body.role, user_id),
        )
        conn.commit()
    return {"ok": True, "message": f"Role updated to {body.role}"}


@router.patch("/users/{user_id}/active")
def toggle_user_active(
    user_id: str,
    body: DeactivateRequest,
    _user: UserRecord = Depends(require_role("admin")),
    store: UserStore = Depends(get_user_store),
) -> dict:
    target = store.get_by_id(user_id)
    if target is None:
        raise HTTPException(status_code=404, detail="User not found")
    with store._conn() as conn:
        conn.execute(
            "UPDATE users SET is_active = %s, updated_at = NOW() WHERE id = %s::uuid",
            (body.active, user_id),
        )
        conn.commit()
    return {"ok": True}


@router.patch("/users/{user_id}/password")
def admin_set_user_password(
    user_id: str,
    body: AdminSetPasswordRequest,
    _admin: UserRecord = Depends(require_role("admin")),
    store: UserStore = Depends(get_user_store),
    sec: SecurityStore = Depends(get_security_store),
) -> dict:
    """Set a user's password (disables 2FA; clears lockout). Admin only."""
    target = store.get_by_id(user_id)
    if target is None:
        raise HTTPException(status_code=404, detail="User not found")
    store.set_password_for_user(target.id, _hash_password(body.new_password))
    sec.reset_failed_attempts(target.id)
    sec.record_event(
        "admin_password_set",
        success=True,
        user_id=target.id,
        details=f"set by admin {_admin.id}",
    )
    return {"ok": True, "message": "Password updated for user"}


@router.post("/users/{user_id}/unlock")
def admin_unlock_user(
    user_id: str,
    _admin: UserRecord = Depends(require_role("admin")),
    store: UserStore = Depends(get_user_store),
    sec: SecurityStore = Depends(get_security_store),
) -> dict:
    """Clear a failed-login account lock without changing the password or 2FA. Admin only.

    Docs: docs/AUTH_ACCOUNT_LIFECYCLE.md ("Failed-login lockout and per-IP limit").
    """
    target = store.get_by_id(user_id)
    if target is None:
        raise HTTPException(status_code=404, detail="User not found")
    sec.reset_failed_attempts(target.id)
    sec.record_event(
        "admin_account_unlocked",
        success=True,
        user_id=target.id,
        details=f"unlocked by admin {_admin.id}",
    )
    return {"ok": True, "message": "Account lock cleared"}


# ── Security dashboard ───────────────────────────────────────

@router.get("/audit-log")
def audit_log(
    _user: UserRecord = Depends(require_role("admin")),
    sec: SecurityStore = Depends(get_security_store),
) -> dict:
    return {"events": sec.recent_events(limit=100)}


@router.get("/ip-blocks")
def ip_blocks(
    _user: UserRecord = Depends(require_role("admin")),
    sec: SecurityStore = Depends(get_security_store),
) -> dict:
    return {"blocks": sec.list_ip_blocks()}


# ── Cluster health / workers ─────────────────────────────────

class AddWorkerRequest(BaseModel):
    name: str = Field(..., min_length=1, max_length=100)
    ip_address: str = Field(..., min_length=1)
    monitor_port: int = 31331
    role: str = "gpu-worker"


@router.get("/workers")
def list_workers(
    _user: UserRecord = Depends(require_role("admin")),
    store: WorkerStore = Depends(get_worker_store),
) -> dict:
    workers = store.list_all()
    return {"workers": [asdict(w) for w in workers]}


@router.post("/workers")
def add_worker(
    body: AddWorkerRequest,
    _user: UserRecord = Depends(require_role("admin")),
    store: WorkerStore = Depends(get_worker_store),
) -> dict:
    w = store.add(body.name, body.ip_address, body.monitor_port, body.role)
    return {"worker": asdict(w)}


@router.delete("/workers/{worker_id}")
def remove_worker(
    worker_id: str,
    _user: UserRecord = Depends(require_role("admin")),
    store: WorkerStore = Depends(get_worker_store),
) -> dict:
    store.remove(worker_id)
    return {"ok": True}


async def _poll_worker(client: httpx.AsyncClient, worker: Any) -> dict:
    """Poll a single worker's monitor agent and return enriched data."""
    stats_url = f"http://{worker.ip_address}:{worker.monitor_port}/stats"
    logs_url = f"http://{worker.ip_address}:{worker.monitor_port}/logs"
    result: dict[str, Any] = {
        "id": worker.id,
        "name": worker.name,
        "ip_address": worker.ip_address,
        "monitor_port": worker.monitor_port,
        "role": worker.role,
        "created_at": worker.created_at,
        "reachable": False,
        "stats": None,
        "logs": None,
        "logs_error": None,
        "error": None,
        "attempted_urls": {"stats": stats_url, "logs": logs_url},
        "hint": None,
    }
    try:
        resp = await client.get(stats_url, timeout=_WORKER_POLL_TIMEOUT)
        if resp.status_code == 200:
            result["reachable"] = True
            result["stats"] = resp.json()
        else:
            body = (resp.text or "")[:400]
            result["error"] = f"HTTP {resp.status_code} from worker-monitor GET /stats: {body}"
            result["hint"] = (
                "worker-monitor returned a non-200 response — on the worker host run: "
                "docker logs worker-monitor for details."
            )
    except (httpx.RequestError, httpx.HTTPStatusError) as exc:
        err = str(exc)
        result["error"] = err
        result["hint"] = _worker_unreachable_hint(err)

    if result.get("hint") is None and result.get("error"):
        result["hint"] = _worker_unreachable_hint(result["error"])

    try:
        resp = await client.get(logs_url, timeout=_WORKER_POLL_TIMEOUT)
        if resp.status_code == 200:
            result["logs"] = resp.json().get("lines", [])
        elif not result["reachable"]:
            result["logs_error"] = f"HTTP {resp.status_code} (logs not fetched)"
    except (httpx.RequestError, httpx.HTTPStatusError) as exc:
        if not result["reachable"]:
            result["logs_error"] = str(exc)
        elif result["reachable"]:
            result["logs_error"] = str(exc)

    return result


@router.get("/health")
async def cluster_health(
    _user: UserRecord = Depends(require_role("admin")),
    store: WorkerStore = Depends(get_worker_store),
) -> dict:
    """Poll all registered workers and return cluster-wide health snapshot."""
    workers = store.list_all()

    # Poll all workers concurrently
    worker_results: list[dict] = []
    if workers:
        async with httpx.AsyncClient() as client:
            tasks = [_poll_worker(client, w) for w in workers]
            worker_results = await asyncio.gather(*tasks)

    # Merge Redis heartbeats (workers call POST /api/workers/heartbeat from the LAN)
    for wr in worker_results:
        wr["heartbeat"] = get_worker_heartbeat(wr["name"])

    # Update DB status for each worker
    for wr in worker_results:
        hw_summary = None
        if wr["stats"]:
            gpus = wr["stats"].get("gpus", [])
            sys = wr["stats"].get("system", {})
            gpu_names = ", ".join(g.get("name", "?") for g in gpus)
            hw_summary = f"{gpu_names} | RAM {sys.get('ram_total_mb', '?')}MB"
        if wr["reachable"]:
            status = "online"
        elif wr.get("heartbeat"):
            status = "degraded"
        else:
            status = "offline"
        try:
            store.update_status(wr["id"], status, hw_summary)
        except Exception:
            logger.exception("Failed to update worker %s status", wr["id"])

    healthy_count = sum(1 for w in worker_results if w["reachable"])
    hb_only_count = sum(
        1 for w in worker_results if (not w["reachable"]) and w.get("heartbeat")
    )
    total_gpus = sum(
        len(w.get("stats", {}).get("gpus", []))
        for w in worker_results if w.get("stats")
    )

    # Alerts (include connection detail so the UI matches docker/API diagnosis)
    alerts: list[dict] = []
    for wr in worker_results:
        if not wr["reachable"]:
            hb = wr.get("heartbeat")
            if hb:
                alerts.append({
                    "level": "warning",
                    "worker": wr["name"],
                    "message": (
                        f"Worker-monitor not reachable from API ({wr['ip_address']}:{wr['monitor_port']}), "
                        f"but heartbeat OK at {hb.get('received_at', '?')} — "
                        "check LAN/firewall from brain to worker."
                    ),
                })
                logger.info(
                    "worker_monitor_unreachable_but_heartbeat_ok name=%s",
                    wr["name"],
                )
                continue
            detail = (wr.get("error") or "unknown error")[:500]
            hint = wr.get("hint") or ""
            msg = f"Worker unreachable — {wr['ip_address']}:{wr['monitor_port']}. {detail}"
            if hint:
                msg = f"{msg} — {hint}"
            alerts.append({"level": "error", "worker": wr["name"], "message": msg})
            logger.info(
                "worker_monitor_unreachable name=%s url=%s error=%s",
                wr["name"],
                (wr.get("attempted_urls") or {}).get("stats", ""),
                wr.get("error"),
            )
            continue
        if wr["stats"]:
            for gpu in wr["stats"].get("gpus", []):
                temp = gpu.get("temp_c")
                if temp and temp > 85:
                    alerts.append({"level": "warning", "worker": wr["name"], "message": f"GPU {gpu.get('index', '?')} temp {temp}°C"})
                vram_pct = gpu.get("mem_util_pct")
                if vram_pct and vram_pct > 95:
                    alerts.append({"level": "warning", "worker": wr["name"], "message": f"GPU {gpu.get('index', '?')} VRAM {vram_pct}%"})
            sys = wr["stats"].get("system", {})
            ram_pct = sys.get("ram_used_pct")
            if ram_pct and ram_pct > 90:
                alerts.append({"level": "warning", "worker": wr["name"], "message": f"RAM usage {ram_pct}%"})

    from src.api.operational_warnings import collect_operational_warnings

    operational_warnings = await collect_operational_warnings()

    return {
        "brain": build_brain_services_report(),
        "inference": build_inference_stack_report(),
        "pool_stats": build_inference_pool_stats(),
        "hosts": build_cluster_hosts_report(),
        "summary": {
            "total_workers": len(workers),
            "online": healthy_count,
            "offline": len(workers) - healthy_count,
            "heartbeat_only": hb_only_count,
            "total_gpus": total_gpus,
        },
        "workers": worker_results,
        "alerts": alerts,
        "operational_warnings": operational_warnings,
    }


@router.get("/operational-warnings")
async def operational_warnings(
    _user: UserRecord = Depends(require_role("admin")),
) -> dict:
    """Lightweight poll for admin UI banners (JWT secret, Prometheus scrape health)."""
    from src.api.operational_warnings import operational_warnings_payload

    return await operational_warnings_payload()


# ── Editor AI assistant ───────────────────────────────────────

_EDITOR_AGENT_SYSTEM = (
    "You are ALFa AI editor assistant. Answer questions about the open file and related code. "
    "Cite file paths and line numbers when relevant. Be concise."
)
_EDITOR_CONTEXT_MAX = 8000


class EditorAgentRequest(BaseModel):
    message: str = Field(..., min_length=1, max_length=8000)
    file_path: str | None = None
    file_content: str | None = None


@router.post("/agent")
def editor_agent(
    body: EditorAgentRequest,
    _user: UserRecord = Depends(require_role("admin")),
) -> dict:
    """Ask ALFa about the open editor file (single-shot agent model call)."""
    from src.llm.client import get_agent_completion

    user_parts: list[str] = []
    if body.file_path and body.file_content is not None:
        snippet = body.file_content[:_EDITOR_CONTEXT_MAX]
        truncated = len(body.file_content) > _EDITOR_CONTEXT_MAX
        suffix = "\n...(truncated)" if truncated else ""
        user_parts.append(f"Open file: {body.file_path}\n```\n{snippet}{suffix}\n```")
    user_parts.append(body.message)

    messages = [
        {"role": "system", "content": _EDITOR_AGENT_SYSTEM},
        {"role": "user", "content": "\n\n".join(user_parts)},
    ]
    try:
        reply = get_agent_completion(messages)
    except AgentCircuitOpenError as exc:
        logger.warning("editor_agent circuit open: %s", exc)
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except Exception as exc:
        logger.exception("editor_agent failed")
        raise HTTPException(status_code=502, detail=f"Agent model unavailable: {exc}") from exc

    return {"ok": True, "reply": reply.strip()}


# ── File browser (workspace) ─────────────────────────────────

@router.get("/files")
def list_files(
    path: str = "",
    _user: UserRecord = Depends(require_role("admin")),
) -> dict:
    target = _safe_path(path)
    if not target.is_dir():
        raise HTTPException(status_code=404, detail="Directory not found")

    entries = []
    try:
        for item in sorted(target.iterdir(), key=lambda p: (not p.is_dir(), p.name.lower())):
            if item.name.startswith("."):
                continue
            entries.append({
                "name": item.name,
                "path": str(item.relative_to(_WORKSPACE)),
                "is_dir": item.is_dir(),
                "size": item.stat().st_size if item.is_file() else None,
            })
    except PermissionError:
        raise HTTPException(status_code=403, detail="Permission denied")

    return {"path": path, "entries": entries}


@router.get("/files/read")
def read_file(
    path: str,
    _user: UserRecord = Depends(require_role("admin")),
) -> dict:
    target = _safe_path(path)
    if not target.is_file():
        raise HTTPException(status_code=404, detail="File not found")
    if target.stat().st_size > _MAX_FILE_SIZE:
        raise HTTPException(status_code=413, detail="File too large (>1MB)")
    suffix = target.suffix.lower()
    if suffix not in _ALLOWED_EXTENSIONS and target.name not in ("Dockerfile", "Makefile"):
        raise HTTPException(status_code=415, detail=f"File type {suffix} not supported for editing")

    try:
        content = target.read_text(encoding="utf-8", errors="replace")
    except PermissionError:
        raise HTTPException(status_code=403, detail="Permission denied")

    return {"path": path, "content": content, "size": len(content)}


class WriteFileRequest(BaseModel):
    path: str
    content: str = Field(..., max_length=_MAX_FILE_SIZE)


@router.put("/files/write")
def write_file(
    body: WriteFileRequest,
    _user: UserRecord = Depends(require_role("admin")),
) -> dict:
    target = _safe_path(body.path)
    if not target.parent.is_dir():
        raise HTTPException(status_code=404, detail="Parent directory not found")
    suffix = target.suffix.lower()
    if suffix not in _ALLOWED_EXTENSIONS and target.name not in ("Dockerfile", "Makefile"):
        raise HTTPException(status_code=415, detail=f"File type {suffix} not supported")

    try:
        target.write_text(body.content, encoding="utf-8")
    except PermissionError:
        raise HTTPException(status_code=403, detail="Permission denied")

    return {"ok": True, "path": body.path, "size": len(body.content)}


# ── Model management ─────────────────────────────────────────

_MODELS_DIR = Path(os.getenv("ALFA_AI_MODELS_DIR", "/mnt/cluster/models"))
_ARIA2_RPC_URL = os.getenv("ARIA2_RPC_URL", "http://hub/jsonrpc")
# No default: the aria2 RPC secret must come from the environment (deploy/.env).
_ARIA2_RPC_KEY = os.getenv("ARIA2_RPC_KEY", "").strip()


class ModelDownloadRequest(BaseModel):
    hf_model_id: str = Field(..., min_length=1, description="HuggingFace model ID (e.g. meta-llama/Llama-3.1-8B-Instruct)")
    subdir: str = Field(default="", description="Subdirectory under ALFA_AI_MODELS_DIR (default root of hf/hub)")


def _scan_models_dir() -> list[dict]:
    """Scan the hub models tree (hub NFS layout under ALFA_AI_MODELS_DIR)."""
    models: list[dict] = []

    def _append_dir(name: str, path: Path, model_type: str) -> None:
        total_size = sum(f.stat().st_size for f in path.rglob("*") if f.is_file())
        file_count = sum(1 for f in path.rglob("*") if f.is_file())
        models.append({
            "name": name,
            "type": model_type,
            "path": str(path),
            "size_bytes": total_size,
            "size_gb": round(total_size / (1024**3), 2),
            "file_count": file_count,
        })

    # HuggingFace hub cache: models/huggingface/hub/models--Org--Name
    hf_hub = _MODELS_DIR / "huggingface" / "hub"
    if hf_hub.is_dir():
        for entry in sorted(hf_hub.iterdir()):
            if entry.name.startswith(".") or not entry.is_dir():
                continue
            display = entry.name.removeprefix("models--").replace("--", "/")
            _append_dir(display, entry, "huggingface")

    # Legacy flat huggingface/ dir (pre-migration layout)
    hf_legacy = _MODELS_DIR / "huggingface"
    if hf_legacy.is_dir() and not hf_hub.is_dir():
        for entry in sorted(hf_legacy.iterdir()):
            if entry.name.startswith("."):
                continue
            if entry.is_dir():
                _append_dir(entry.name, entry, "huggingface")
            elif entry.suffix in (".gguf", ".bin", ".safetensors"):
                models.append({
                    "name": entry.name,
                    "type": "huggingface",
                    "path": str(entry),
                    "size_bytes": entry.stat().st_size,
                    "size_gb": round(entry.stat().st_size / (1024**3), 2),
                    "file_count": 1,
                })

    # Ollama blobs: models/ollama/
    ollama_root = _MODELS_DIR / "ollama"
    if ollama_root.is_dir():
        for entry in sorted(ollama_root.iterdir()):
            if entry.name.startswith("."):
                continue
            if entry.is_dir():
                _append_dir(entry.name, entry, "ollama")

    # llama.cpp GGUF pool on hub: sibling of models/ or under llama-cpp/models
    for gguf_root in (
        _MODELS_DIR.parent / "llama-cpp" / "models",
        _MODELS_DIR / "llama-cpp",
    ):
        if not gguf_root.is_dir():
            continue
        for entry in sorted(gguf_root.iterdir()):
            if entry.name.startswith("."):
                continue
            if entry.is_file() and entry.suffix.lower() == ".gguf":
                models.append({
                    "name": entry.name,
                    "type": "llama-cpp",
                    "path": str(entry),
                    "size_bytes": entry.stat().st_size,
                    "size_gb": round(entry.stat().st_size / (1024**3), 2),
                    "file_count": 1,
                })
            elif entry.is_dir():
                _append_dir(entry.name, entry, "llama-cpp")

    return models


async def _aria2_rpc(method: str, params: list | None = None) -> Any:
    """Call aria2 JSON-RPC endpoint."""
    if not _ARIA2_RPC_KEY:
        raise HTTPException(
            status_code=503,
            detail="aria2 downloads are disabled: ARIA2_RPC_KEY is not set on the API host",
        )
    payload = {
        "jsonrpc": "2.0",
        "id": "alfa-admin",
        "method": method,
        "params": [f"token:{_ARIA2_RPC_KEY}"] + (params or []),
    }
    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.post(_ARIA2_RPC_URL, json=payload)
        resp.raise_for_status()
        data = resp.json()
        if "error" in data:
            raise HTTPException(status_code=502, detail=f"aria2 error: {data['error']}")
        return data.get("result")


@router.get("/models")
async def list_models(
    _user: UserRecord = Depends(require_role("admin")),
) -> dict:
    """List installed models and disk usage."""
    models = _scan_models_dir()
    total_gb = sum(m["size_gb"] for m in models)

    disk_info: dict[str, Any] = {}
    if _MODELS_DIR.exists():
        try:
            stat = os.statvfs(str(_MODELS_DIR))
            disk_info = {
                "total_gb": round((stat.f_blocks * stat.f_frsize) / (1024**3), 1),
                "free_gb": round((stat.f_bfree * stat.f_frsize) / (1024**3), 1),
                "used_gb": round(total_gb, 1),
            }
        except OSError:
            pass

    inference = build_inference_stack_report()

    return {
        "models": models,
        "inference": inference,
        "models_dir": str(_MODELS_DIR),
        "models_dir_exists": _MODELS_DIR.is_dir(),
        "total_models_gb": round(total_gb, 2),
        "disk": disk_info,
    }


@router.post("/models/download")
async def trigger_model_download(
    body: ModelDownloadRequest,
    _user: UserRecord = Depends(require_role("admin")),
) -> dict:
    """Trigger a model download via aria2 RPC on hub.

    Constructs HuggingFace download URLs for the model's main files.
    aria2 handles multi-connection downloading for maximum speed.
    """
    hf_base = f"https://huggingface.co/{body.hf_model_id}/resolve/main"
    download_dir = str(_MODELS_DIR / body.subdir / body.hf_model_id.replace("/", "--"))

    files_to_download = [
        "config.json",
        "tokenizer.json",
        "tokenizer_config.json",
        "special_tokens_map.json",
        "generation_config.json",
    ]

    gids: list[str] = []
    try:
        for filename in files_to_download:
            url = f"{hf_base}/{filename}"
            result = await _aria2_rpc("aria2.addUri", [[url], {"dir": download_dir, "out": filename}])
            if result:
                gids.append(result)
    except (httpx.RequestError, httpx.HTTPStatusError) as exc:
        logger.error("aria2 unreachable: %s", exc)
        raise HTTPException(status_code=502, detail="Download service unavailable")

    return {
        "ok": True,
        "message": f"Queued {len(gids)} file(s) for {body.hf_model_id}",
        "download_dir": download_dir,
        "gids": gids,
    }


@router.get("/models/downloads/status")
async def download_status(
    _user: UserRecord = Depends(require_role("admin")),
) -> dict:
    """Poll aria2 for active and waiting downloads."""
    if not _ARIA2_RPC_KEY:
        return {
            "aria2_reachable": False,
            "error": "ARIA2_RPC_KEY is not set on the API host; aria2 downloads are disabled",
            "active": [],
            "waiting": [],
        }
    try:
        active = await _aria2_rpc("aria2.tellActive", [["gid", "status", "totalLength", "completedLength", "downloadSpeed", "files"]])
        waiting = await _aria2_rpc("aria2.tellWaiting", [0, 20, ["gid", "status", "totalLength", "completedLength", "files"]])
    except (httpx.RequestError, httpx.HTTPStatusError) as exc:
        return {
            "aria2_reachable": False,
            "error": f"Cannot reach aria2 at {_ARIA2_RPC_URL}: {exc}",
            "active": [],
            "waiting": [],
        }

    def _simplify(item: dict) -> dict:
        total = int(item.get("totalLength", 0))
        completed = int(item.get("completedLength", 0))
        speed = int(item.get("downloadSpeed", 0))
        files = item.get("files", [])
        filename = Path(files[0]["path"]).name if files else "unknown"
        return {
            "gid": item.get("gid"),
            "status": item.get("status"),
            "filename": filename,
            "total_mb": round(total / (1024**2), 1) if total else 0,
            "completed_mb": round(completed / (1024**2), 1),
            "progress_pct": round((completed / total) * 100, 1) if total else 0,
            "speed_mbps": round(speed / (1024**2), 2) if speed else 0,
        }

    return {
        "aria2_reachable": True,
        "active": [_simplify(d) for d in (active or [])],
        "waiting": [_simplify(d) for d in (waiting or [])],
    }


@router.delete("/models/{model_name}")
async def delete_model(
    model_name: str,
    model_type: str = "huggingface",
    _user: UserRecord = Depends(require_role("admin")),
) -> dict:
    """Remove a model from the models directory."""
    import shutil

    model_path = _MODELS_DIR / model_type / model_name
    if not model_path.exists():
        raise HTTPException(status_code=404, detail=f"Model not found: {model_name}")
    if not str(model_path.resolve()).startswith(str(_MODELS_DIR.resolve())):
        raise HTTPException(status_code=403, detail="Path traversal not allowed")

    if model_path.is_dir():
        shutil.rmtree(model_path)
    else:
        model_path.unlink()

    return {"ok": True, "deleted": model_name}


def _incident_out(record: IncidentRecord) -> dict[str, Any]:
    return {
        "id": record.id,
        "fingerprint": record.fingerprint,
        "alertname": record.alertname,
        "severity": record.severity,
        "status": record.status,
        "labels": record.labels,
        "annotations": record.annotations,
        "summary": record.summary,
        "opened_at": record.opened_at,
        "resolved_at": record.resolved_at,
        "last_seen_at": record.last_seen_at,
        "updated_at": record.updated_at,
    }


@router.get("/incidents")
async def list_incidents(
    status: str | None = None,
    limit: int = 50,
    _user: UserRecord = Depends(require_role("admin")),
    store: IncidentStore = Depends(get_incident_store),
) -> dict[str, Any]:
    """List cluster incidents ingested from Alertmanager."""
    rows = store.list_incidents(status=status, limit=limit)
    return {"ok": True, "incidents": [_incident_out(item) for item in rows]}


@router.get("/incidents/{incident_id}")
async def get_incident(
    incident_id: str,
    _user: UserRecord = Depends(require_role("admin")),
    store: IncidentStore = Depends(get_incident_store),
) -> dict[str, Any]:
    """Incident detail with timeline events."""
    record = store.get_by_id(incident_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Incident not found")
    events = store.list_events(incident_id)
    return {
        "ok": True,
        "incident": _incident_out(record),
        "events": [
            {
                "id": event.id,
                "event_type": event.event_type,
                "payload": event.payload,
                "created_at": event.created_at,
            }
            for event in events
        ],
        "proposals": [_remediation_out(item) for item in store.list_proposals(incident_id)],
    }


def _remediation_out(record: IncidentRemediationRecord) -> dict[str, Any]:
    return {
        "id": record.id,
        "incident_id": record.incident_id,
        "classification": record.classification,
        "root_cause": record.root_cause,
        "confidence": record.confidence,
        "target_repo": record.target_repo,
        "target_path": record.target_path,
        "proposed_change": record.proposed_change,
        "rationale": record.rationale,
        "briefing": record.briefing,
        "status": record.status,
        "pr_url": record.pr_url,
        "created_by": record.created_by,
        "created_at": record.created_at,
    }


class RemediationActionBody(BaseModel):
    proposal_id: str
    confirm: bool = False
    force: bool = False


class ProposalFeedbackBody(BaseModel):
    helpful: bool
    comment: str | None = None


class HostActionFeedbackBody(BaseModel):
    helpful: bool
    comment: str | None = None


@router.get("/metrics/prometheus")
async def admin_prometheus_metrics(
    _user: UserRecord = Depends(require_role("admin")),
    store: IncidentStore = Depends(get_incident_store),
) -> Response:
    """Admin-only Prometheus scrape of incident worker metrics."""
    from src.api.incident_metrics import prometheus_payload

    body, content_type = prometheus_payload(store)
    return Response(content=body, media_type=content_type)


@router.post("/incidents/{incident_id}/analyze")
async def analyze_incident_endpoint(
    incident_id: str,
    user: UserRecord = Depends(require_role("admin")),
    store: IncidentStore = Depends(get_incident_store),
) -> dict[str, Any]:
    """Run on-demand LLM analysis and persist a remediation proposal."""
    record = store.get_by_id(incident_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Incident not found")

    from src.incident.analyze import analyze_incident, analysis_to_remediation_record

    events = store.list_events(incident_id)
    analysis = analyze_incident(record, events=events)
    proposal = analysis_to_remediation_record(
        incident_id,
        analysis,
        created_by=user.email,
        store=store,
    )
    store.record_event(
        incident_id,
        "ai_analysis",
        {
            "proposal_id": proposal.id,
            "classification": proposal.classification,
            "confidence": proposal.confidence,
        },
    )
    logger.info("admin analyze incident=%s proposal=%s by=%s", incident_id, proposal.id, user.email)
    return {"ok": True, "proposal": _remediation_out(proposal)}


@router.post("/incidents/{incident_id}/apply")
async def apply_incident_remediation(
    incident_id: str,
    body: RemediationActionBody,
    request: Request,
    user: UserRecord = Depends(require_role("admin")),
    store: IncidentStore = Depends(get_incident_store),
    sec: SecurityStore = Depends(get_security_store),
) -> dict[str, Any]:
    """Apply a proposal after explicit admin confirmation (opens GitHub PR when enabled)."""
    if not body.confirm:
        raise HTTPException(status_code=400, detail="confirm must be true to apply remediation")

    record = store.get_by_id(incident_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Incident not found")

    proposal = store.get_proposal(body.proposal_id)
    if proposal is None or proposal.incident_id != incident_id:
        raise HTTPException(status_code=404, detail="Proposal not found")

    from src.incident.remediate import apply_proposal, remediation_enabled

    if not remediation_enabled():
        raise HTTPException(status_code=403, detail="Remediation is disabled.")

    result = apply_proposal(record, proposal, force=body.force)
    client_ip = request.client.host if request.client else None
    user_agent = request.headers.get("user-agent")

    if not result.ok:
        sec.record_event(
            "incident_remediation_apply",
            success=False,
            user_id=user.id,
            ip_address=client_ip,
            user_agent=user_agent,
            details=f"incident={incident_id} proposal={body.proposal_id} error={result.message}",
        )
        raise HTTPException(status_code=400, detail=result.message)

    updated = store.set_proposal_status(body.proposal_id, "applied", pr_url=result.pr_url)
    store.record_event(
        incident_id,
        "remediation_pr_opened" if result.pr_url else "remediation_ops_recorded",
        {
            "proposal_id": body.proposal_id,
            "pr_url": result.pr_url,
            "message": result.message,
            "applied_by": user.email,
        },
    )
    sec.record_event(
        "incident_remediation_apply",
        success=True,
        user_id=user.id,
        ip_address=client_ip,
        user_agent=user_agent,
        details=f"incident={incident_id} proposal={body.proposal_id} pr={result.pr_url or 'ops'}",
    )
    return {
        "ok": True,
        "message": result.message,
        "pr_url": result.pr_url,
        "proposal": _remediation_out(updated) if updated else None,
    }


@router.get("/incidents/{incident_id}/postmortem")
async def export_incident_postmortem(
    incident_id: str,
    user: UserRecord = Depends(require_role("admin")),
    store: IncidentStore = Depends(get_incident_store),
) -> dict[str, Any]:
    """Export a blameless postmortem markdown draft from incident timeline."""
    record = store.get_by_id(incident_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Incident not found")
    from src.incident.postmortem import build_postmortem_markdown

    events = store.list_events(incident_id)
    proposals = store.list_proposals(incident_id)
    markdown = build_postmortem_markdown(record, events, proposals)
    logger.info("admin postmortem export incident=%s by=%s", incident_id, user.email)
    return {"ok": True, "markdown": markdown}


@router.post("/incidents/{incident_id}/proposals/{proposal_id}/feedback")
async def proposal_feedback(
    incident_id: str,
    proposal_id: str,
    body: ProposalFeedbackBody,
    user: UserRecord = Depends(require_role("admin")),
    store: IncidentStore = Depends(get_incident_store),
    actions: AiActionStore = Depends(get_ai_action_store),
) -> dict[str, Any]:
    """Operator thumbs-up/down on an Analyze proposal (NIST Measure)."""
    record = store.get_by_id(incident_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Incident not found")
    proposal = store.get_proposal(proposal_id)
    if proposal is None or proposal.incident_id != incident_id:
        raise HTTPException(status_code=404, detail="Proposal not found")
    label = "helpful" if body.helpful else "not_helpful"
    actions.record(
        ACTION_PROPOSAL_FEEDBACK,
        f"{user.email} marked proposal {label} ({proposal.classification})",
        detail={
            "incident_id": incident_id,
            "proposal_id": proposal_id,
            "helpful": body.helpful,
            "comment": (body.comment or "").strip() or None,
            "classification": proposal.classification,
            "confidence": proposal.confidence,
        },
        incident_id=incident_id,
        created_by=user.email,
    )
    _bridge_admin_thumbs(
        prompt=f"incident {record.alertname}: {(record.summary or '').strip()}".strip(),
        response=(proposal.proposed_change or proposal.root_cause or proposal.rationale or "").strip(),
        helpful=body.helpful,
        source="admin-proposal",
        metadata={
            "incident_id": incident_id,
            "proposal_id": proposal_id,
            "classification": proposal.classification,
            "comment": (body.comment or "").strip() or None,
        },
    )
    return {"ok": True}


@router.post("/incidents/{incident_id}/dismiss")
async def dismiss_incident_remediation(
    incident_id: str,
    body: RemediationActionBody,
    user: UserRecord = Depends(require_role("admin")),
    store: IncidentStore = Depends(get_incident_store),
) -> dict[str, Any]:
    """Dismiss a remediation proposal without applying."""
    record = store.get_by_id(incident_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Incident not found")

    proposal = store.get_proposal(body.proposal_id)
    if proposal is None or proposal.incident_id != incident_id:
        raise HTTPException(status_code=404, detail="Proposal not found")

    updated = store.set_proposal_status(body.proposal_id, "dismissed")
    store.record_event(
        incident_id,
        "remediation_dismissed",
        {"proposal_id": body.proposal_id, "dismissed_by": user.email},
    )
    return {"ok": True, "proposal": _remediation_out(updated) if updated else None}


# ── AI Actions feed + settings (docs/AI_ACTIONS.md) ──────────────────────────

# Incident-side AI event types surfaced under the "Incident AI" sub-tab.
_INCIDENT_AI_EVENT_TYPES: list[str] = [
    "ai_analysis",
    "llm_triage",
    "remediation_started",
    "remediation_complete",
    "remediation_pr_opened",
    "remediation_ops_recorded",
]


def _ai_action_out(record: AiActionRecord) -> dict[str, Any]:
    return {
        "id": record.id,
        "category": record.category,
        "action_type": record.action_type,
        "summary": record.summary,
        "detail": record.detail,
        "severity": record.severity,
        "incident_id": record.incident_id,
        "created_by": record.created_by,
        "created_at": record.created_at,
    }


def _incident_event_to_feed(event: IncidentEventRecord) -> dict[str, Any]:
    return {
        "id": event.id,
        "category": "incidents",
        "action_type": event.event_type,
        "summary": f"Incident AI: {event.event_type}",
        "detail": event.payload,
        "severity": None,
        "incident_id": event.incident_id,
        "created_by": "ai",
        "created_at": event.created_at,
    }


_DUMP_ACTION_TYPES = [
    ACTION_SOLAR_DUMP_OBSERVED,
    ACTION_SOLAR_DUMP_RECOMMENDED,
    ACTION_SOLAR_DUMP_ACTUATED,
    "solar_soak_observed",
    "solar_soak_recommended",
    "solar_soak_actuated",
]


@router.get("/dump-status")
async def get_dump_status(
    _user: UserRecord = Depends(require_role("admin")),
    settings: AiSettingStore = Depends(get_ai_setting_store),
) -> dict[str, Any]:
    """Last dump-load tick snapshot for Admin UI (no HA token)."""
    settings_map = _solar_dump_settings_dict(settings)
    last = get_last_dump_summary()
    try:
        interval_seconds = int(settings_map.get("ha_interval_seconds", "900"))
        interval_seconds = max(60, min(interval_seconds, 3600))
    except ValueError:
        interval_seconds = int(_SOLAR_DUMP_DEFAULTS["ha_interval_seconds"])
    dump_enabled = settings_map.get("ha_solar_dump_enabled", "false").strip().lower() in (
        "1",
        "true",
        "yes",
        "on",
    )
    recorded_at = last.get("recorded_at") if isinstance(last, dict) else None
    return {
        "ok": True,
        "ha_ready": _home_assistant_ready(),
        "dump_enabled": dump_enabled,
        "auto_actuate": False,
        "interval_seconds": interval_seconds,
        "recorded_at": recorded_at,
        "last": last,
    }


@router.get("/ai-actions")
async def list_ai_actions(
    category: str = "all",
    limit: int = 100,
    _user: UserRecord = Depends(require_role("admin")),
    actions: AiActionStore = Depends(get_ai_action_store),
    incidents: IncidentStore = Depends(get_incident_store),
) -> dict[str, Any]:
    """Unified AI activity feed. category in all|alert|notifications|settings|host|dump|incidents."""
    category = (category or "all").strip().lower()
    type_map = {
        "alert": ["alert_triaged"],
        "notifications": ["notification_sent", "notification_skipped"],
        "settings": ["setting_changed"],
        "host": [
            ACTION_HOST_COMMAND_EXECUTED,
            ACTION_HOST_ACTION_REJECTED,
            ACTION_HOST_INSPECT_EXECUTED,
        ],
        "dump": _DUMP_ACTION_TYPES,
    }

    feed: list[dict[str, Any]] = []
    if category in ("all", "alert", "notifications", "settings", "host", "dump"):
        action_types = type_map.get(category)
        for rec in actions.list_actions(action_types=action_types, limit=limit):
            feed.append(_ai_action_out(rec))
    if category in ("all", "incidents"):
        for ev in incidents.list_recent_events_by_type(_INCIDENT_AI_EVENT_TYPES, limit=limit):
            feed.append(_incident_event_to_feed(ev))

    feed.sort(key=lambda item: item["created_at"], reverse=True)
    return {"ok": True, "category": category, "actions": feed[:max(1, min(limit, 500))]}


@router.get("/ai-actions/{action_id}")
async def get_ai_action(
    action_id: str,
    _user: UserRecord = Depends(require_role("admin")),
    actions: AiActionStore = Depends(get_ai_action_store),
) -> dict[str, Any]:
    record = actions.get_by_id(action_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Action not found")
    return {"ok": True, "action": _ai_action_out(record)}


def _ai_setting_out(record) -> dict[str, Any]:
    return {
        "key": record.key,
        "value": record.value,
        "description": record.description,
        "editable_by_ai": record.editable_by_ai,
        "updated_by": record.updated_by,
        "updated_at": record.updated_at,
    }


@router.get("/ai-settings")
async def list_ai_settings(
    _user: UserRecord = Depends(require_role("admin")),
    settings: AiSettingStore = Depends(get_ai_setting_store),
) -> dict[str, Any]:
    return {"ok": True, "settings": [_ai_setting_out(item) for item in settings.all()]}


class AiSettingUpdateBody(BaseModel):
    key: str
    value: str
    confirm: bool = False


def _setting_proposal_out(record: AiActionRecord) -> dict[str, Any]:
    detail = record.detail or {}
    key = detail.get("key")
    key_str = str(key) if key is not None else ""
    out: dict[str, Any] = {
        "id": record.id,
        "key": key,
        "old_value": detail.get("old_value"),
        "new_value": detail.get("new_value"),
        "status": detail.get("status"),
        "proposed_by": record.created_by,
        "created_at": record.created_at,
    }
    if key_str:
        out["description"] = setting_description(key_str)
        if is_policy_setting(key_str):
            out["requires_approve_reason"] = POLICY_SETTING_REQUIRES_APPROVE_REASON
    return out


@router.get("/ai-settings/proposals")
async def list_setting_proposals(
    _user: UserRecord = Depends(require_role("admin")),
    actions: AiActionStore = Depends(get_ai_action_store),
) -> dict[str, Any]:
    """Pending policy-setting proposals (kill-switch keys)."""
    rows = actions.list_actions(action_types=[ACTION_SETTING_PROPOSAL], limit=50)
    pending = [
        _setting_proposal_out(r)
        for r in rows
        if (r.detail or {}).get("status") == "pending"
    ]
    return {"ok": True, "proposals": pending}


class SettingProposalActionBody(BaseModel):
    confirm: bool = True


@router.post("/ai-settings/proposals/{proposal_id}/approve")
async def approve_setting_proposal(
    proposal_id: str,
    body: SettingProposalActionBody,
    user: UserRecord = Depends(require_role("admin")),
    settings: AiSettingStore = Depends(get_ai_setting_store),
    actions: AiActionStore = Depends(get_ai_action_store),
) -> dict[str, Any]:
    if not body.confirm:
        raise HTTPException(status_code=400, detail="confirm must be true to apply policy setting")
    record = actions.get_by_id(proposal_id)
    if record is None or record.action_type != ACTION_SETTING_PROPOSAL:
        raise HTTPException(status_code=404, detail="Setting proposal not found")
    detail = record.detail or {}
    if detail.get("status") != "pending":
        raise HTTPException(status_code=409, detail="Proposal is not pending")
    key = str(detail.get("key") or "")
    new_value = str(detail.get("new_value", ""))
    old_value = settings.get(key, "")
    try:
        updated = settings.set(key, new_value, updated_by=user.email, by_ai=False)
    except AiSettingError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    actions.update_detail(proposal_id, {"status": "approved", "reviewed_by": user.email})
    actions.record(
        ACTION_SETTING_CHANGED,
        f"{user.email} approved policy setting {key}: {old_value or '(empty)'} -> {new_value or '(empty)'}",
        detail={
            "key": key,
            "old_value": old_value,
            "new_value": new_value,
            "proposal_id": proposal_id,
            "reason": "Approved policy setting proposal",
        },
        created_by=user.email,
    )
    return {"ok": True, "setting": _ai_setting_out(updated)}


@router.post("/ai-settings/proposals/{proposal_id}/reject")
async def reject_setting_proposal(
    proposal_id: str,
    user: UserRecord = Depends(require_role("admin")),
    actions: AiActionStore = Depends(get_ai_action_store),
) -> dict[str, Any]:
    record = actions.get_by_id(proposal_id)
    if record is None or record.action_type != ACTION_SETTING_PROPOSAL:
        raise HTTPException(status_code=404, detail="Setting proposal not found")
    if (record.detail or {}).get("status") != "pending":
        raise HTTPException(status_code=409, detail="Proposal is not pending")
    updated = actions.update_detail(proposal_id, {"status": "rejected", "reviewed_by": user.email})
    return {"ok": True, "proposal": _setting_proposal_out(updated) if updated else None}


@router.post("/ai-settings")
async def update_ai_setting(
    body: AiSettingUpdateBody,
    user: UserRecord = Depends(require_role("admin")),
    settings: AiSettingStore = Depends(get_ai_setting_store),
    actions: AiActionStore = Depends(get_ai_action_store),
) -> dict[str, Any]:
    """Operator override of an AI setting. Logged to the AI Actions feed."""
    if is_policy_setting(body.key) and not body.confirm:
        raise HTTPException(
            status_code=400,
            detail=f"Policy setting '{body.key}' requires confirm=true",
        )
    old_value = settings.get(body.key, "")
    try:
        updated = settings.set(body.key, body.value, updated_by=user.email, by_ai=False)
    except AiSettingError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    actions.record(
        "setting_changed",
        f"{user.email} set {body.key}: {old_value or '(empty)'} -> {body.value or '(empty)'}",
        detail={
            "key": body.key,
            "old_value": old_value,
            "new_value": body.value,
            "reason": "Operator override",
        },
        created_by=user.email,
    )
    logger.info("admin ai-setting %s -> %s by=%s", body.key, body.value, user.email)
    return {"ok": True, "setting": _ai_setting_out(updated)}


# ── Admin AI agent config (live-editable prompt, hosts, actions, context) ────

def _host_actions_readiness() -> dict[str, Any]:
    """Operator checklist: env master switch + SSH key mount (not secrets).

    ``ready`` means SSH catalog actions can run. ``missions_ready`` is env-only:
    mission_enqueue is internal HTTP and does not need the SSH key.
    HA ``ha_ready`` is separate (ALFA_AI_HOME_ASSISTANT_* + token file).
    """
    key = Path(default_ssh_key_path())
    key_ok = key.is_file()
    env_on = host_actions_enabled()
    ha_env = _home_assistant_ready()
    return {
        "env_enabled": env_on,
        "ssh_key_present": key_ok,
        "ssh_key_path": str(key),
        "ready": env_on and key_ok,
        "missions_ready": env_on,
        "ha_env_enabled": home_assistant_enabled(),
        "ha_token_present": home_assistant_token_present(),
        "ha_ready": ha_env,
        "checklist": [
            {
                "id": "env",
                "ok": env_on,
                "label": "ALFA_AI_HOST_ACTIONS_ENABLED=1 on brain API",
            },
            {
                "id": "ssh_key",
                "ok": key_ok,
                "label": (
                    f"SSH private key mounted at {key} "
                    "(SSH catalog only; Missions enqueue does not need this key)"
                ),
            },
            {
                "id": "home_assistant",
                "ok": ha_env,
                "label": (
                    "Home Assistant REST enabled with token file "
                    "(ALFA_AI_HOME_ASSISTANT_ENABLED=1; ha_* catalog is httpx, not SSH)"
                ),
            },
            {
                "id": "packs",
                "ok": True,
                "label": "Packs are optional -- Approve enables soft-disabled packs for that request",
            },
        ],
    }


def _ha_action_requires_ready(action_key: str) -> bool:
    return action_key.startswith("ha_")


def _require_ha_or_host_actions(action_key: str) -> None:
    if _ha_action_requires_ready(action_key):
        if not _home_assistant_ready():
            raise HTTPException(
                status_code=403,
                detail=(
                    "Home Assistant integration is off or token file missing. "
                    "Set ALFA_AI_HOME_ASSISTANT_* in deploy/.env and redeploy alfa-ai-api."
                ),
            )
        return
    if not host_actions_enabled():
        raise HTTPException(
            status_code=403,
            detail=(
                "Host actions infra is off (ALFA_AI_HOST_ACTIONS_ENABLED=0). "
                "One-time: set it in brain deploy/.env and redeploy the API."
            ),
        )


def _agent_config_out(
    config: dict[str, Any],
    *,
    system_prompt_default: str,
) -> dict[str, Any]:
    disabled = set(config.get("disabled_actions") or [])
    catalog = list_all_catalog_entries()
    for entry in catalog:
        entry["enabled"] = entry["key"] not in disabled
    return {
        "system_prompt_default": system_prompt_default,
        "system_prompt_override": config.get("system_prompt_override"),
        "system_prompt_effective": config.get("system_prompt_override") or system_prompt_default,
        "host_overrides": config.get("host_overrides") or [],
        "hosts_editable": list_editable_hosts(config),
        "hosts_active": list_merged_hosts(config),
        "catalog_actions": catalog,
        "disabled_actions": sorted(disabled),
        "packs": pack_status(disabled),
        "readiness": _host_actions_readiness(),
        "context_sections": config.get("context_sections") or dict(DEFAULT_CONTEXT_SECTIONS),
        "prompt_history": config.get("prompt_history") or [],
        "context_section_labels": {
            "incidents": "Open incidents vs recent history (not live Prometheus firing)",
            "ai_settings": "AI settings values",
            "ai_actions": "Recent AI actions feed",
            "cluster_health": "Cluster health and brain services",
            "models_summary": "Models on disk summary",
            "user_count": "Registered user count",
            "audit_log": "Recent audit log events",
            "pending_host_actions": "Pending host action proposals",
            "prometheus_ops": "Prometheus firing alerts, scrape warnings, and host load/temp snapshot",
            "github_ci": "GitHub Actions failed runs (read-only; needs ALFA_AI_GITHUB_TOKEN)",
            "missions_fleet": "Mission fleet heartbeats, active runs, feeder pause state",
        },
        "updated_by": config.get("updated_by"),
        "updated_at": config.get("updated_at"),
    }


@router.get("/agent-config")
async def get_agent_config(
    _user: UserRecord = Depends(require_role("admin")),
    store: AgentConfigStore = Depends(get_agent_config_store),
) -> dict[str, Any]:
    config = store.get()
    return {"ok": True, "config": _agent_config_out(config, system_prompt_default=_MONITORING_AGENT_SYSTEM)}


class AgentConfigPromptBody(BaseModel):
    text: str | None = None


@router.post("/agent-config/prompt")
async def update_agent_config_prompt(
    body: AgentConfigPromptBody,
    user: UserRecord = Depends(require_role("admin")),
    store: AgentConfigStore = Depends(get_agent_config_store),
    actions: AiActionStore = Depends(get_ai_action_store),
) -> dict[str, Any]:
    before = store.get()
    updated = store.update_prompt(body.text, updated_by=user.email)
    actions.record(
        ACTION_AGENT_CONFIG_CHANGED,
        f"{user.email} updated admin AI system prompt",
        detail={
            "field": "system_prompt_override",
            "old_value": before.get("system_prompt_override"),
            "new_value": updated.get("system_prompt_override"),
        },
        created_by=user.email,
    )
    return {
        "ok": True,
        "config": _agent_config_out(updated, system_prompt_default=_MONITORING_AGENT_SYSTEM),
    }


class AgentConfigHostsBody(BaseModel):
    hosts: list[dict[str, Any]] = Field(default_factory=list)


@router.post("/agent-config/hosts")
async def update_agent_config_hosts(
    body: AgentConfigHostsBody,
    user: UserRecord = Depends(require_role("admin")),
    store: AgentConfigStore = Depends(get_agent_config_store),
    actions: AiActionStore = Depends(get_ai_action_store),
) -> dict[str, Any]:
    before = store.get()
    updated = store.update_hosts(body.hosts, updated_by=user.email)
    actions.record(
        ACTION_AGENT_CONFIG_CHANGED,
        f"{user.email} updated admin AI host registry ({len(body.hosts)} entries)",
        detail={
            "field": "host_overrides",
            "old_value": before.get("host_overrides"),
            "new_value": updated.get("host_overrides"),
        },
        created_by=user.email,
    )
    return {
        "ok": True,
        "config": _agent_config_out(updated, system_prompt_default=_MONITORING_AGENT_SYSTEM),
    }


class AgentConfigActionsBody(BaseModel):
    disabled_actions: list[str] = Field(default_factory=list)


@router.post("/agent-config/actions")
async def update_agent_config_actions(
    body: AgentConfigActionsBody,
    user: UserRecord = Depends(require_role("admin")),
    store: AgentConfigStore = Depends(get_agent_config_store),
    actions: AiActionStore = Depends(get_ai_action_store),
) -> dict[str, Any]:
    before = store.get()
    updated = store.update_disabled_actions(body.disabled_actions, updated_by=user.email)
    actions.record(
        ACTION_AGENT_CONFIG_CHANGED,
        f"{user.email} updated disabled host actions",
        detail={
            "field": "disabled_actions",
            "old_value": before.get("disabled_actions"),
            "new_value": updated.get("disabled_actions"),
        },
        created_by=user.email,
    )
    return {
        "ok": True,
        "config": _agent_config_out(updated, system_prompt_default=_MONITORING_AGENT_SYSTEM),
    }


class AgentConfigPackBody(BaseModel):
    pack_id: str = Field(..., min_length=1, max_length=64)
    enabled: bool


@router.post("/agent-config/packs")
async def update_agent_config_pack(
    body: AgentConfigPackBody,
    user: UserRecord = Depends(require_role("admin")),
    store: AgentConfigStore = Depends(get_agent_config_store),
    actions: AiActionStore = Depends(get_ai_action_store),
) -> dict[str, Any]:
    """Enable or disable a capability pack (grouped host actions)."""
    before = store.get()
    known = {e["key"] for e in list_all_catalog_entries()}
    try:
        new_disabled = apply_pack_toggle(
            list(before.get("disabled_actions") or []),
            pack_id=body.pack_id.strip(),
            enabled=body.enabled,
            known_actions=known,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    updated = store.update_disabled_actions(new_disabled, updated_by=user.email)
    actions.record(
        ACTION_AGENT_CONFIG_CHANGED,
        f"{user.email} {'enabled' if body.enabled else 'disabled'} pack {body.pack_id}",
        detail={
            "field": "packs",
            "pack_id": body.pack_id,
            "enabled": body.enabled,
            "old_value": before.get("disabled_actions"),
            "new_value": updated.get("disabled_actions"),
        },
        created_by=user.email,
    )
    return {
        "ok": True,
        "config": _agent_config_out(updated, system_prompt_default=_MONITORING_AGENT_SYSTEM),
    }


class AgentConfigContextBody(BaseModel):
    context_sections: dict[str, bool] = Field(default_factory=dict)


@router.post("/agent-config/context")
async def update_agent_config_context(
    body: AgentConfigContextBody,
    user: UserRecord = Depends(require_role("admin")),
    store: AgentConfigStore = Depends(get_agent_config_store),
    actions: AiActionStore = Depends(get_ai_action_store),
) -> dict[str, Any]:
    before = store.get()
    updated = store.update_context_sections(body.context_sections, updated_by=user.email)
    actions.record(
        ACTION_AGENT_CONFIG_CHANGED,
        f"{user.email} updated admin AI context visibility",
        detail={
            "field": "context_sections",
            "old_value": before.get("context_sections"),
            "new_value": updated.get("context_sections"),
        },
        created_by=user.email,
    )
    return {
        "ok": True,
        "config": _agent_config_out(updated, system_prompt_default=_MONITORING_AGENT_SYSTEM),
    }


# ── Host actions (curated, approval-gated) ───────────────────────────────────

def _proposal_auth_fields(action_key: str, config: dict[str, Any]) -> dict[str, Any]:
    return proposal_enable_meta(
        action_key,
        config.get("disabled_actions") or [],
        risk_tier=get_action_risk_tier(action_key),
    )


def _host_action_out(record: HostActionRecord, config: dict[str, Any] | None = None) -> dict[str, Any]:
    out: dict[str, Any] = {
        "id": record.id,
        "action_key": record.action_key,
        "host": record.host,
        "params": record.params,
        "status": record.status,
        "summary": record.summary,
        "command_run": record.command_run,
        "stdout": record.stdout,
        "stderr": record.stderr,
        "exit_code": record.exit_code,
        "proposed_by": record.proposed_by,
        "reviewed_by": record.reviewed_by,
        "created_at": record.created_at,
        "executed_at": record.executed_at,
        "risk_tier": get_action_risk_tier(record.action_key),
        "action_category": action_category(record.action_key),
    }
    if config is not None:
        out.update(_proposal_auth_fields(record.action_key, config))
    if (
        record.status in ("executed", "failed")
        and record.exit_code is not None
        and (record.stdout is not None or record.stderr is not None)
    ):
        out["bot_audit_excerpt"] = format_bot_audit_excerpt(
            action_key=record.action_key,
            host=record.host,
            exit_code=record.exit_code,
            stdout=record.stdout,
            stderr=record.stderr,
        )
    return out


class HostActionProposeBody(BaseModel):
    action_key: str = Field(..., min_length=1, max_length=64)
    host: str = Field(..., min_length=1, max_length=32)
    params: dict[str, Any] = Field(default_factory=dict)


@router.get("/host-actions/catalog")
def host_actions_catalog(
    _user: UserRecord = Depends(require_role("admin")),
    agent_config: AgentConfigStore = Depends(get_agent_config_store),
) -> dict[str, Any]:
    config = agent_config.get()
    return {
        "ok": True,
        "enabled": host_actions_enabled(),
        "hosts": [
            {"key": k, "name": h.get("name"), "lan_ip": h.get("lan_ip"), "os_type": h.get("os_type")}
            for k, h in sorted(load_hosts(config).items())
        ],
        "actions": list_catalog(config),
        "all_actions": list_all_catalog_entries(),
        "disabled_actions": config.get("disabled_actions") or [],
    }


@router.get("/host-actions")
def list_host_actions(
    status: str | None = None,
    limit: int = 100,
    _user: UserRecord = Depends(require_role("admin")),
    store: HostActionStore = Depends(get_host_action_store),
    agent_config: AgentConfigStore = Depends(get_agent_config_store),
) -> dict[str, Any]:
    config = agent_config.get()
    records = store.list_actions(status=status, limit=limit)
    return {"ok": True, "actions": [_host_action_out(r, config) for r in records]}


@router.post("/host-actions/propose")
async def propose_host_action(
    body: HostActionProposeBody,
    user: UserRecord = Depends(require_role("admin")),
    store: HostActionStore = Depends(get_host_action_store),
    agent_config: AgentConfigStore = Depends(get_agent_config_store),
    actions: AiActionStore = Depends(get_ai_action_store),
) -> dict[str, Any]:
    _require_ha_or_host_actions(body.action_key)
    config = agent_config.get()
    if is_ha_auto_actuate(body.action_key):
        try:
            summary = summarize_proposal(body.action_key, body.host, body.params, config)
            _, host_cfg, normalized_params = validate_proposal(
                body.action_key, body.host, body.params, config, enforce_enabled=False
            )
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        result = await execute_host_action(
            body.action_key, host_cfg, normalized_params, config
        )
        actions.record(
            ACTION_HOST_COMMAND_EXECUTED,
            f"{user.email} auto {summary} -> exit {result.exit_code}",
            detail={
                "action_key": body.action_key,
                "host": body.host,
                "params": normalized_params,
                "command_run": result.command_run,
                "exit_code": result.exit_code,
                "ok": result.ok,
                "auto_actuate": True,
                "risk_tier": get_action_risk_tier(body.action_key),
            },
            created_by=user.email,
        )
        return {
            "ok": result.ok,
            "executed": True,
            "summary": summary,
            "command_run": result.command_run,
            "stdout": result.stdout,
            "stderr": result.stderr,
            "exit_code": result.exit_code,
        }

    try:
        summary = summarize_proposal(body.action_key, body.host, body.params, config)
        validate_proposal(
            body.action_key, body.host, body.params, config, enforce_enabled=False
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    record = store.create_pending(
        body.action_key,
        body.host,
        body.params,
        summary,
        proposed_by=user.email,
    )
    return {"ok": True, "action": _host_action_out(record, config)}


class HostActionApproveBody(BaseModel):
    ack_tier: int | None = None


@router.post("/host-actions/{action_id}/approve")
async def approve_host_action(
    action_id: str,
    request: Request,
    user: UserRecord = Depends(require_role("admin")),
    store: HostActionStore = Depends(get_host_action_store),
    actions: AiActionStore = Depends(get_ai_action_store),
    agent_config: AgentConfigStore = Depends(get_agent_config_store),
    sec: SecurityStore = Depends(get_security_store),
    body: HostActionApproveBody = HostActionApproveBody(),
) -> dict[str, Any]:
    config = agent_config.get()
    record = store.get_by_id(action_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Host action not found")
    _require_ha_or_host_actions(record.action_key)
    if record.status != STATUS_PENDING:
        raise HTTPException(status_code=409, detail=f"Action is not pending (status={record.status})")
    risk_tier = get_action_risk_tier(record.action_key)
    if risk_tier >= 2 and body.ack_tier != 2:
        raise HTTPException(
            status_code=400,
            detail="Mutating or destructive actions require ack_tier=2 confirmation",
        )
    host_cfg = load_hosts(config).get(record.host)
    if host_cfg is None:
        raise HTTPException(status_code=400, detail=f"Unknown host: {record.host}")

    # Approve enables soft-disabled packs/actions, then runs (operator-first UX).
    enabled_packs: list[str] = []
    before_disabled = list(config.get("disabled_actions") or [])
    auth_meta = _proposal_auth_fields(record.action_key, config)
    if auth_meta.get("soft_disabled"):
        known = {e["key"] for e in list_all_catalog_entries()}
        new_disabled = enable_action_in_disabled_list(
            before_disabled,
            record.action_key,
            known_actions=known,
        )
        if new_disabled != sorted({str(k).strip() for k in before_disabled if str(k).strip()}):
            config = agent_config.update_disabled_actions(new_disabled, updated_by=user.email)
            enabled_packs = list(auth_meta.get("will_enable_packs") or [])
            actions.record(
                ACTION_AGENT_CONFIG_CHANGED,
                (
                    f"{user.email} Approve enabled "
                    f"{', '.join(enabled_packs) if enabled_packs else record.action_key} "
                    f"for host action {action_id}"
                ),
                detail={
                    "field": "disabled_actions",
                    "reason": "approve_enables",
                    "host_action_id": action_id,
                    "action_key": record.action_key,
                    "enabled_packs": enabled_packs,
                    "old_value": before_disabled,
                    "new_value": new_disabled,
                },
                created_by=user.email,
            )

    try:
        validate_proposal(
            record.action_key, record.host, record.params, config, enforce_enabled=True
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    client_ip = request.client.host if request.client else None
    user_agent = request.headers.get("user-agent")

    result = await execute_host_action(record.action_key, host_cfg, record.params, config)
    updated = store.mark_executed(
        action_id,
        reviewed_by=user.email,
        command_run=result.command_run,
        stdout=result.stdout,
        stderr=result.stderr,
        exit_code=result.exit_code,
        success=result.ok,
    )
    if updated is None:
        raise HTTPException(status_code=409, detail="Action was already processed")

    actions.record(
        ACTION_HOST_COMMAND_EXECUTED,
        f"{user.email} approved {record.summary} -> exit {result.exit_code}",
        detail={
            "host_action_id": action_id,
            "action_key": record.action_key,
            "host": record.host,
            "params": record.params,
            "exit_code": result.exit_code,
            "ok": result.ok,
            "risk_tier": risk_tier,
            "ack_tier": body.ack_tier,
            "enabled_packs": enabled_packs,
        },
        created_by=user.email,
    )
    sec.record_event(
        "host_action_approved",
        success=result.ok,
        user_id=user.id,
        ip_address=client_ip,
        user_agent=user_agent,
        details=(
            f"action_id={action_id} key={record.action_key} host={record.host} "
            f"exit={result.exit_code} risk_tier={risk_tier}"
        ),
    )
    out = _host_action_out(updated, config)
    out["enabled_packs"] = enabled_packs
    navigation_hint = None
    if record.action_key == "mission_enqueue" and result.ok:
        from src.ops.mission_fleet import mission_navigation_from_stdout

        navigation_hint = mission_navigation_from_stdout(
            result.stdout,
            record.params if isinstance(record.params, dict) else {},
        )
    payload: dict[str, Any] = {"ok": True, "action": out}
    if navigation_hint:
        payload["navigation_hint"] = navigation_hint
    return payload


@router.post("/host-actions/{action_id}/reject")
def reject_host_action(
    action_id: str,
    request: Request,
    user: UserRecord = Depends(require_role("admin")),
    store: HostActionStore = Depends(get_host_action_store),
    actions: AiActionStore = Depends(get_ai_action_store),
    sec: SecurityStore = Depends(get_security_store),
) -> dict[str, Any]:
    updated = store.mark_rejected(action_id, reviewed_by=user.email)
    if updated is None:
        raise HTTPException(status_code=404, detail="Pending host action not found")
    risk_tier = get_action_risk_tier(updated.action_key)
    client_ip = request.client.host if request.client else None
    user_agent = request.headers.get("user-agent")
    actions.record(
        ACTION_HOST_ACTION_REJECTED,
        f"{user.email} rejected {updated.summary}",
        detail={
            "host_action_id": action_id,
            "action_key": updated.action_key,
            "host": updated.host,
            "params": updated.params,
            "risk_tier": risk_tier,
        },
        created_by=user.email,
    )
    sec.record_event(
        "host_action_rejected",
        success=True,
        user_id=user.id,
        ip_address=client_ip,
        user_agent=user_agent,
        details=(
            f"action_id={action_id} key={updated.action_key} host={updated.host} "
            f"risk_tier={risk_tier}"
        ),
    )
    return {"ok": True, "action": _host_action_out(updated)}


@router.post("/host-actions/{action_id}/feedback")
async def host_action_feedback(
    action_id: str,
    body: HostActionFeedbackBody,
    user: UserRecord = Depends(require_role("admin")),
    store: HostActionStore = Depends(get_host_action_store),
    actions: AiActionStore = Depends(get_ai_action_store),
) -> dict[str, Any]:
    """Operator thumbs-up/down on a completed or rejected host action."""
    record = store.get_by_id(action_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Host action not found")
    label = "helpful" if body.helpful else "not_helpful"
    actions.record(
        ACTION_HOST_ACTION_FEEDBACK,
        f"{user.email} marked host action {label} ({record.action_key})",
        detail={
            "host_action_id": action_id,
            "action_key": record.action_key,
            "host": record.host,
            "status": record.status,
            "helpful": body.helpful,
            "comment": (body.comment or "").strip() or None,
        },
        created_by=user.email,
    )
    _bridge_admin_thumbs(
        prompt=f"host action {record.action_key} on {record.host}",
        response=(record.summary or record.command_run or "").strip(),
        helpful=body.helpful,
        source="admin-host-action",
        metadata={
            "host_action_id": action_id,
            "action_key": record.action_key,
            "host": record.host,
            "comment": (body.comment or "").strip() or None,
        },
    )
    return {"ok": True}


def _bridge_admin_thumbs(
    *,
    prompt: str,
    response: str,
    helpful: bool,
    source: str,
    metadata: dict[str, Any],
) -> None:
    """Write admin thumbs into the learning-loop feedback inbox (DPO source)."""
    try:
        append_thumbs(
            prompt=prompt,
            response=response,
            helpful=helpful,
            source=source,
            metadata=metadata,
        )
    except OSError:
        logger.warning("learning-loop feedback inbox write failed source=%s", source, exc_info=True)


@router.get("/learning-loop/status")
async def learning_loop_status(
    _user: UserRecord = Depends(require_role("admin")),
) -> dict[str, Any]:
    """Flywheel LATEST, train-export counts, LoRA registry (admin JWT).

    FastAPI GET + Depends: https://fastapi.tiangolo.com/tutorial/bigger-applications/
    """
    return collect_learning_loop_status()


@router.post("/learning-loop/lora/sync")
async def learning_loop_lora_sync(
    _user: UserRecord = Depends(require_role("admin")),
) -> dict[str, Any]:
    """Merge hub lora-adapters.json into the brain registry. Does not promote."""
    result = sync_registry_from_hub()
    if not result.get("ok"):
        code = 404 if result.get("reason") == "hub_manifest_missing" else 400
        raise HTTPException(status_code=code, detail="LoRA hub manifest not available")
    return result


# ── Ask ALFa: global admin chat widget (docs/AI_ACTIONS.md) ─────────────────

_MONITORING_AGENT_MAX_STEPS = 8
_INSPECT_MAX_STEPS = 6
_INSPECT_TOTAL_SEC = 150
_ADMIN_CONTEXT_MAX_CHARS = 12000
_INSPECT_FINDINGS_MAX_CHARS = 18000
_INSPECT_STDOUT_PER_STEP = 3000

_INSPECT_TURN_OPERATOR_TAIL = (
    "Inspect findings above already ran this turn (SSH exit 0 unless noted). "
    "You still have inspect_steps_remaining inspect_host calls; pre-inspect does not consume them. "
    "Never claim the read/inspect budget is exhausted unless a tool result said so. "
    "If README or how-the-feature-is-wired is still missing, output ONLY "
    '{"tool":"inspect_host","args":{"action_key":"repo_read_file or repo_grep","host":"...","params":{...}}} '
    "with no reply key. When the operator asked to change something, after facts propose ONE "
    "mutating action via propose_host_action. HTML/undocumented scrapers stay manual "
    "(operator Approve a one-shot command); do not invent a cron."
)

_MONITORING_AGENT_SYSTEM = (
    "You are ALFa AI, embedded in the ALFa AI cluster admin console with FULL read access to "
    "all alfa-ai admin data provided in context: cluster health, incidents, AI settings/actions, "
    "models, users, audit log, and pending host actions. You do NOT have access to consumer bot "
    "business databases (ProBilliards/rankings player data, market-pie5 trades, contracts "
    "opportunities, credit-check, atems, rv-auto-finder, etc.) -- if asked about those, say this "
    "console does not hold that data. "
    "Packed user messages: Recent activity (authoritative) = what ran; Cluster ops "
    "(authoritative) = live health / prometheus / CI / settings; Host-action catalog "
    "(truncated) = action_key picker only. Prefer those JSON blobs over guessing. "
    "activity_facts_meta: recent_ai_actions is a newest-N row sample of operator/"
    "catalog jobs, not last-N-hours. dump_observe_sample / solar_dump_observed / "
    "ha_dump_tick are observe ticks, not completed jobs. "
    "incident_counts_in_window is a histogram of last-N mixed-status incident rows "
    "(incident_window_kind=last_n_rows), not jobs and not last 2 hours. "
    "Do not invent job counts from sample sizes. "
    "A prior assistant message that says 'no frontier-code call' is a program "
    "rollup from admin stores -- never claim those run IDs were invented. "
    "If a packed JSON key is missing, the slice was truncated; say that, "
    "do not conclude the data never existed. "
    "Conversation history is prior dock turns. Do not list catalog keys instead of "
    "answering. JSON final object unchanged (reply / setting_change / host_action_id). "
    "Do not enable native tools. "
    "Answer helpfully using the provided context for diagnosis, prioritization, and tradeoffs. "
    "For 'status right now' / current outages, prefer prometheus_ops.firing_alerts "
    "(Watchdog is omitted; it is the Alertmanager heartbeat). "
    "open_incidents_by_status, open_incident_alertnames, and recent_alertnames are unresolved "
    "incidents only. recent_incidents includes resolved history -- never describe a resolved "
    "row as an outage happening now. Do not blame orchestrator or inference for blackbox failures unless "
    "firing_alerts or cluster_health names that host. "
    "Explicit catalog proposes and setting changes are handled by the server without you -- focus "
    "on judgment when intent is ambiguous. "
    "When the operator asks to analyze, inspect, look at, or change something on a host or repo, "
    "FIRST gather facts with inspect_host (read-only catalog actions: repo_tree, repo_read_file, "
    "repo_grep, git_status, docker_ps, docker_logs, docker_stats, disk_usage, health_check, "
    "prom_targets, prom_alerts, prom_query). Read the repo's own docs (README, AGENTS.md, docs/) "
    "via repo_tree + repo_read_file before deciding how it is operated. You may make up to 6 "
    "inspect_host tool calls per turn; deterministic pre-inspect already ran and does not use "
    "those 6. Never say the inspect budget is exhausted unless a tool result contained "
    "'inspect budget exhausted'. If an Inspect findings message is present, those SSH results "
    "already succeeded -- read them; do not claim you could not inspect. THEN reply with what "
    "you found and, if a change was requested, propose ONE mutating action via propose_host_action. "
    "Do not list unrelated catalog keys (CI lint, git_push) instead of answering the operator. "
    "inspect_host tool (runs immediately, no Approve): "
    "{\"tool\":\"inspect_host\",\"args\":{\"action_key\":\"...\",\"host\":\"...\",\"params\":{...}}}. "
    "Only for catalog entries with inspectable=true. Results come back as a tool message. "
    "Answer Q&A in this chat using inspect_host and the findings you receive. "
    "Audit host N, Review errors, and Run host-facts on host N run inspect steps in this "
    "chat (pre_inspect + llm_continue) -- not mission_enqueue. "
    "mission_feeder_pause / mission_feeder_resume / mission_clear_stuck are ONLY for "
    "explicit feeder pause/resume or clear stuck missions. "
    "Never route an analyze / do-this request to a mission. "
    "When the operator asks to research online, look up vendor manuals, check public "
    "model/release notes, or check weather for a US zip code, use inspect_host "
    "web_search on host 111 in this chat (internal SearXNG; no mission). "
    "Do not enqueue a mission for HA / host 105 / solar weather radar -- inspect "
    "ha_get_forecasts (type hourly when they ask for the next few hours) and ha_get_state "
    "on weather.417373300314 in this chat. "
    "Guest and public chat still must not browse. "
    "To pause or resume the scheduled audit feeder, use "
    "mission_feeder_pause or mission_feeder_resume on host 111. Fleet status is in "
    "missions_fleet context -- cite it when asked. "
    "When prometheus_ops shows high package temp with high CPU/load, attribute heat to workload "
    "and name the top container from top_containers_cpu when present. When temp is high but "
    "CPU/load are low, suggest cooling (fans, paste, fan curve) -- do not propose random "
    "container restarts. For host thermal questions, prefer docker_stats then docker_ps; "
    "use prom_query on host 107 only when snapshot is missing. "
    "Soft-disabled catalog "
    "actions (soft_disabled=true in host_action_catalog) are still proposable; the operator Approve "
    "button enables the pack and runs the command. Prefer named catalog action when one fits; "
    "for script verify use brain_verify, hub_diag_read, or ps_syntax_check instead of run_command "
    "(Grok Bot does not run scripts -- it names the catalog action). "
    "For anything else, use action_key=\"run_command\" with "
    "params={\"command\":\"<exact shell command for Linux hosts, or PowerShell for the Windows "
    "host orchestrator>\"} -- write the full literal command, it is shown to the operator verbatim before "
    "they approve it. Mutating host actions NEVER run until the operator clicks Approve -- you "
    "only propose, and you may propose at most one pending mutate per turn -- except Home "
    "Assistant solar dump: ha_switch_on/off, ha_set_number, and ha_select_option execute "
    "immediately when HA env + token are on (no Approve; not under NIST). Never propose a command "
    "that restarts, stops, or probes an individual inference/RPC shard or coordinator container -- "
    "use cluster_start/cluster_stop on host 93 instead (it will be rejected otherwise). "
    "In your reply text, briefly state the auth level (Read / Ops / Destructive) and that the "
    "operator must Approve (or Reject) for mutating actions. Do not tell them to open AI Config packs. "
    "After the operator Approves mission_enqueue, tell them clearly: open Admin -> Missions, "
    "select the run_id from the approve result, and watch Live tool events for output "
    "(chat only shows enqueue confirmation, not agent tool stream). Offer the next step "
    "(wait, Fleet status, or another host) -- never leave them without a what-to-do-now. "
    "If host_actions_enabled is false (or readiness.missions_ready is false), explain that "
    "ALFA_AI_HOST_ACTIONS_ENABLED=0 and do not propose SSH or missions. "
    "If readiness.ready is false you cannot SSH-inspect. Say so in one sentence with the fix "
    "and stop -- do not propose a mission as a substitute and do not say Click Approve. "
    "HA inspect and web_search do not need SSH. "
    "If readiness.ssh_key_present is false, do not propose SSH catalog actions "
    "(docker_ps, run_command, git_pull, feeder pause/resume, etc.). mission_enqueue and "
    "mission_clear_stuck are internal brain API (not SSH) and stay proposable ONLY for "
    "feeder pause/resume / clear stuck -- never as a stand-in for a blocked inspect or "
    "for online research, Audit host N, Review errors, or host-facts (those inspect here). "
    "Never tell the operator to click Approve unless propose_host_action returned ok in "
    "this turn. Never claim this console has no internet when web_search inspect is available "
    "(ALFA_AI_WEB_SEARCH_ENABLED). "
    "Home energy: Home Assistant automations own dump switch on/off "
    "(victron sim_dump_control.yaml) using Victron float hold and 1-minute "
    "re-bulk (not surplus watts). Claim leftover PV by staging plugs while "
    "the bus stays above re-bulk; turn dumps off when solar stops so packs "
    "stay 95%+. The brain ticker and ha_dump_tick observe and audit "
    "only (no switch.turn_on/off from dump). Dump does not require 7B or 27B -- do not pick "
    "a model size to dump. ha_switch_on/off remain optional one-shots when HA env + token "
    "are on (no Approve). Propose only allowlisted entities (default switch.sim_ac_plug_*); "
    "never dump-actuate standing night loads (LED strip, fan, Pi4, Trailer A/C). "
    "Use ha_get_states / ha_dump_tick to inspect sensors and ha_get_forecasts / ha_get_state "
    "for weather.417373300314. Do not scrape HA dashboards. "
    "When a load is plugged into T2, KU, or Sungold, use live meters: "
    "sensor.battery_1_power / sensor.battery_2_power (SmartShunt; negative = pack "
    "supplying that Renogy) and sensor.sungold_sph302480a_load_power plus cart "
    "battery V*A (Sungold has no Victron shunt). Do not ask the operator to type the "
    "wattage of a random appliance. Dump plug watts are live HA power sensors "
    "(sensor.sim_ac_plug_N_power), not dump_plug_N_watts. Write AC-cap / inverter "
    "helpers immediately with ha_set_number / ha_select_option (no Approve), plus "
    "float/re-bulk V and min solar W. Match VictronConnect programmed float; "
    "24 V LiFePO4 re-bulk is Vfloat minus 0.2 V for 1 minute. "
    "When the operator clearly asks to change an ai_settings key, you may include setting_change "
    "in your final JSON. Operator-initiated changes may target ANY valid ai_settings key "
    "(editable_by_ai only gates autonomous AI tuning, not operator chat). "
    "When finished (no more tools), respond with a single JSON object only, no markdown fences. "
    "Keys: reply (string), setting_change (null or {\"key\":\"...\",\"value\":\"...\"}), "
    "host_action_id (null, or ONLY the UUID string returned by propose_host_action -- "
    "never invent ids such as \"12345\")."
)


def _effective_monitoring_agent_system(config: dict[str, Any]) -> str:
    override = (config.get("system_prompt_override") or "").strip()
    return override or _MONITORING_AGENT_SYSTEM


def _parse_agent_tool_call(text: str) -> tuple[str, dict[str, Any]] | None:
    text = (text or "").strip()
    if not text:
        return None
    try:
        parsed = json.loads(text)
        if isinstance(parsed, dict) and "tool" in parsed:
            args = parsed.get("args") or {}
            return str(parsed["tool"]), args if isinstance(args, dict) else {}
    except json.JSONDecodeError:
        pass
    match = re.search(r"\{[\s\S]*\}", text)
    if not match:
        return None
    try:
        parsed = json.loads(match.group(0))
        if isinstance(parsed, dict) and "tool" in parsed:
            args = parsed.get("args") or {}
            return str(parsed["tool"]), args if isinstance(args, dict) else {}
    except json.JSONDecodeError:
        return None
    return None


def _extract_json_object(text: str) -> dict[str, Any] | None:
    text = (text or "").strip()
    if not text:
        return None
    try:
        parsed = json.loads(text)
        if isinstance(parsed, dict):
            return parsed
    except json.JSONDecodeError:
        pass
    match = re.search(r"\{[\s\S]*\}", text)
    if not match:
        return None
    try:
        parsed = json.loads(match.group(0))
        return parsed if isinstance(parsed, dict) else None
    except json.JSONDecodeError:
        return None


# Tolerate any whitespace/newlines a pretty-printed envelope puts around the
# comma, so the salvaged prose can never swallow a following key.
_REPLY_ENVELOPE_TERMINATOR_RE = re.compile(
    r'"\s*,\s*"(?:setting_change|host_action_id|tool|args)"\s*:'
)
_REPLY_ENVELOPE_END_RE = re.compile(r'"\s*\}\s*$')


def _unescape_json_string_value(raw: str) -> str:
    out: list[str] = []
    idx = 0
    while idx < len(raw):
        ch = raw[idx]
        if ch == "\\" and idx + 1 < len(raw):
            nxt = raw[idx + 1]
            if nxt == "n":
                out.append("\n")
            elif nxt == "t":
                out.append("\t")
            elif nxt == "r":
                out.append("\r")
            elif nxt in ('"', "\\", "/"):
                out.append(nxt)
            else:
                out.append(ch)
                out.append(nxt)
            idx += 2
            continue
        out.append(ch)
        idx += 1
    return "".join(out)


def _salvage_reply_string_from_envelope(text: str) -> str | None:
    """Extract reply prose when strict JSON parse fails (unescaped inner quotes)."""
    text = (text or "").strip()
    key_match = re.search(r'"reply"\s*:\s*"', text)
    if not key_match:
        return None
    rest = text[key_match.end() :]
    terminator = _REPLY_ENVELOPE_TERMINATOR_RE.search(rest)
    if terminator:
        end = terminator.start()
    else:
        # No structural terminator: only trust an explicit envelope close. Guessing
        # at the last quote leaks the trailing keys into operator-visible prose.
        envelope_end = _REPLY_ENVELOPE_END_RE.search(rest)
        if envelope_end is None:
            return None
        end = envelope_end.start()
    return _unescape_json_string_value(rest[:end])


def _parse_monitoring_agent_reply(raw_reply: str) -> tuple[str, dict[str, Any] | None]:
    """Return operator-visible reply text; never pass through a raw JSON envelope."""
    parsed = _extract_json_object(raw_reply)
    if parsed and isinstance(parsed.get("reply"), str):
        return str(parsed["reply"]), parsed

    salvaged = _salvage_reply_string_from_envelope(raw_reply)
    if salvaged is not None:
        logger.warning(
            "monitoring_agent salvaged reply from malformed JSON envelope (len=%d)",
            len(raw_reply or ""),
        )
        # Prose only. A malformed envelope cannot be trusted to yield structured
        # fields: regex-scraping setting_change out of the raw blob would happily
        # pick up a quoted example inside the reply text and apply a non-policy
        # setting with no Approve step.
        return salvaged, {"reply": salvaged}

    stripped = (raw_reply or "").strip()
    if stripped.startswith("{"):
        logger.warning(
            "monitoring_agent could not salvage reply from JSON-like envelope (len=%d)",
            len(stripped),
        )
        return (
            "The model returned a response that could not be displayed cleanly. "
            "Please try again or rephrase your question.",
            None,
        )
    return stripped, None


async def _gather_monitoring_agent_context(
    *,
    incidents: IncidentStore,
    settings: AiSettingStore,
    actions: AiActionStore,
    users: UserStore,
    sec: SecurityStore,
    host_store: HostActionStore,
    config: dict[str, Any],
) -> dict[str, Any]:
    sections = config.get("context_sections") or dict(DEFAULT_CONTEXT_SECTIONS)
    ctx: dict[str, Any] = {
        "host_actions_enabled": host_actions_enabled(),
        "host_action_catalog": get_catalog_for_llm(config),
        "host_actions_readiness": _host_actions_readiness(),
    }

    if sections.get("incidents", True):
        ctx.update(build_ask_alfa_incident_context(incidents.list_incidents(limit=50)))

    if sections.get("ai_settings", True):
        settings_list = settings.all()
        ctx["ai_settings"] = [
            {
                "key": s.key,
                "value": s.value,
                "editable_by_ai": s.editable_by_ai,
                "description": s.description,
            }
            for s in settings_list
        ]
    else:
        ctx["ai_settings"] = []

    if sections.get("ai_actions", True):
        fetched = [
            {
                "summary": a.summary,
                "action_type": a.action_type,
                "created_at": a.created_at,
            }
            for a in actions.list_actions(limit=ASK_ALFA_AI_ACTIONS_FETCH_LIMIT)
        ]
        job_rows, dump_rows = split_ai_actions_for_ask_alfa(fetched)
        ctx["recent_ai_actions"] = job_rows[:ASK_ALFA_AI_ACTIONS_JOB_CAP]
        ctx["dump_observe_sample"] = dump_rows[:ASK_ALFA_DUMP_OBSERVE_SAMPLE_CAP]
        ctx["dump_observe_in_sample"] = len(dump_rows)
        ctx["dump_observe_created_at"] = [
            str(row.get("created_at") or "")
            for row in dump_rows
            if row.get("created_at")
        ]
        ctx["activity_facts_meta"] = activity_facts_meta(
            jobs_packed=len(ctx["recent_ai_actions"]),
            dump_in_fetch=len(dump_rows),
        )
    else:
        ctx["recent_ai_actions"] = []
        ctx["dump_observe_sample"] = []
        ctx["dump_observe_in_sample"] = 0
        ctx["dump_observe_created_at"] = []
        ctx["activity_facts_meta"] = activity_facts_meta(
            jobs_packed=0, dump_in_fetch=0
        )

    if sections.get("pending_host_actions", True):
        ctx["pending_host_actions"] = [
            {"id": h.id, "summary": h.summary, "status": h.status}
            for h in host_store.list_actions(status=STATUS_PENDING, limit=10)
        ]
    else:
        ctx["pending_host_actions"] = []

    if sections.get("cluster_health", True):
        cluster_hosts = build_cluster_hosts_report()
        hosts_summary = [
            {
                "key": h.get("key"),
                "name": h.get("name"),
                "lan_ip": h.get("lan_ip"),
                "ok": h.get("reachable"),
                "reachable": h.get("reachable"),
            }
            for h in cluster_hosts[:12]
        ]
        ctx["cluster_health"] = {
            "hosts": hosts_summary,
            "brain": build_brain_services_report(),
            "inference": build_inference_stack_report(),
        }

    if sections.get("models_summary", True):
        models = _scan_models_dir()
        ctx["models_summary"] = {
            "count": len(models),
            "total_gb": round(sum(m["size_gb"] for m in models), 2),
        }

    if sections.get("user_count", True):
        ctx["user_count"] = users.count()

    if sections.get("audit_log", True):
        ctx["recent_audit_events"] = sec.recent_events(limit=15)

    if sections.get("prometheus_ops", True):
        ctx["prometheus_ops"] = await fetch_prometheus_ops_context()

    if sections.get("github_ci", False):
        from src.ops.github_actions_context import fetch_github_ci_context

        ctx["github_ci"] = await fetch_github_ci_context()

    if sections.get("missions_fleet", True):
        ctx["missions_fleet"] = build_missions_chat_context()

    ctx["home_energy_ops"] = build_home_energy_ops_context(settings)

    return ctx


async def _execute_ha_auto_actuate_step(
    action_key: str,
    host: str,
    params: dict[str, Any],
    *,
    user: UserRecord,
    actions: AiActionStore,
    config: dict[str, Any],
    proposed_by: str,
) -> dict[str, Any]:
    """Run HA dump-load mutate immediately; audit as host_command_executed."""
    try:
        summary = summarize_proposal(action_key, host, params, config)
        _, host_cfg, normalized_params = validate_proposal(
            action_key, host, params, config, enforce_enabled=False
        )
    except ValueError as exc:
        err = str(exc)
        actions.record(
            ACTION_HOST_COMMAND_EXECUTED,
            f"{proposed_by} auto {action_key} on {host} skipped: {err}",
            detail={
                "action_key": action_key,
                "host": host,
                "params": dict(params or {}),
                "ok": False,
                "skipped": True,
                "error": err,
                "exit_code": 2,
                "auto_actuate": True,
                "operator": user.email,
                "risk_tier": get_action_risk_tier(action_key),
            },
            created_by=proposed_by,
        )
        return {"ok": False, "error": err, "executed": False}

    start = time.monotonic()
    result = await execute_host_action(action_key, host_cfg, normalized_params, config)
    duration_ms = int((time.monotonic() - start) * 1000)
    actions.record(
        ACTION_HOST_COMMAND_EXECUTED,
        f"{proposed_by} auto {summary} -> exit {result.exit_code}",
        detail={
            "action_key": action_key,
            "host": host,
            "params": normalized_params,
            "command_run": result.command_run,
            "exit_code": result.exit_code,
            "ok": result.ok,
            "duration_ms": duration_ms,
            "auto_actuate": True,
            "operator": user.email,
            "risk_tier": get_action_risk_tier(action_key),
        },
        created_by=proposed_by,
    )
    return {
        "ok": result.ok,
        "executed": True,
        "action_key": action_key,
        "host": host,
        "summary": summary,
        "command_run": result.command_run,
        "stdout": result.stdout[:4000],
        "stderr": result.stderr[:1000],
        "exit_code": result.exit_code,
        "duration_ms": duration_ms,
    }


async def _propose_host_action_from_agent(
    args: dict[str, Any],
    *,
    proposed_by: str,
    host_store: HostActionStore,
    config: dict[str, Any],
    user: UserRecord | None = None,
    actions: AiActionStore | None = None,
) -> dict[str, Any]:
    action_key = str(args.get("action_key") or "").strip()
    host = str(args.get("host") or "").strip()
    params = args.get("params") if isinstance(args.get("params"), dict) else {}
    if _ha_action_requires_ready(action_key):
        if not _home_assistant_ready():
            return {
                "ok": False,
                "error": (
                    "Home Assistant integration is off or token file missing. "
                    "Set ALFA_AI_HOME_ASSISTANT_* in deploy/.env and redeploy alfa-ai-api."
                ),
            }
    elif not host_actions_enabled():
        return {
            "ok": False,
            "error": (
                "Host actions infra is off (ALFA_AI_HOST_ACTIONS_ENABLED=0). "
                "One-time: set it in brain deploy/.env, mount the SSH key, redeploy API."
            ),
        }

    if is_ha_auto_actuate(action_key):
        if user is None or actions is None:
            return {"ok": False, "error": "HA auto-actuate requires user and actions store"}
        return await _execute_ha_auto_actuate_step(
            action_key,
            host,
            params,
            user=user,
            actions=actions,
            config=config,
            proposed_by=proposed_by,
        )

    try:
        summary = summarize_proposal(action_key, host, params, config)
        validate_proposal(action_key, host, params, config, enforce_enabled=False)
    except ValueError as exc:
        return {"ok": False, "error": str(exc)}
    record = host_store.create_pending(action_key, host, params, summary, proposed_by=proposed_by)
    auth = _proposal_auth_fields(action_key, config)
    return {
        "ok": True,
        "action_id": record.id,
        "summary": record.summary,
        "action_key": action_key,
        "action_category": action_category(action_key),
        **auth,
    }


class HistoryTurn(BaseModel):
    model_config = ConfigDict(extra="ignore")

    role: Literal["user", "assistant"]
    content: str = Field(..., min_length=1, max_length=2000)


class MonitoringAgentRequest(BaseModel):
    model_config = ConfigDict(extra="ignore")

    message: str = Field(..., min_length=1, max_length=4000)
    history: list[HistoryTurn] = Field(default_factory=list, max_length=8)


_MONITORING_AGENT_HEARTBEAT_SEC = 3


def _monitoring_agent_sse_line(payload: dict[str, Any]) -> str:
    return f"data: {json.dumps(payload, ensure_ascii=True, default=str)}\n\n"


def _ha_inspect_block_result() -> dict[str, Any]:
    reason = "Home Assistant integration is off or token file missing"
    return {
        "ok": True,
        "reply": (
            f"Cannot inspect HA weather: {reason}. "
            "Set ALFA_AI_HOME_ASSISTANT_* in deploy/.env and redeploy alfa-ai-api. "
            "I will not queue a mission as a substitute."
        ),
        "applied_setting": None,
        "pending_setting_proposal": None,
        "host_action_proposal": None,
        "readiness_block": {
            "host": "105",
            "reason": reason,
            "fix_steps": [
                "Set ALFA_AI_HOME_ASSISTANT_ENABLED=1 and the HA token file in brain deploy/.env",
                "From hub: sudo bash scripts/brain_redeploy_api.sh",
            ],
        },
        "inspections": [],
    }


def _web_search_inspect_block_result() -> dict[str, Any]:
    reason = "web_search disabled (ALFA_AI_WEB_SEARCH_ENABLED=0)"
    return {
        "ok": True,
        "reply": (
            f"Cannot run web_search: {reason}. "
            "Enable ALFA_AI_WEB_SEARCH_ENABLED=1 and SearXNG in brain deploy/.env, "
            "then redeploy alfa-ai-api. I will not queue a mission as a substitute."
        ),
        "applied_setting": None,
        "pending_setting_proposal": None,
        "host_action_proposal": None,
        "readiness_block": {
            "host": "111",
            "reason": reason,
            "fix_steps": [
                "Set ALFA_AI_WEB_SEARCH_ENABLED=1 and ALFA_AI_SEARXNG_URL in brain deploy/.env",
                "From hub: sudo bash scripts/brain_redeploy_api.sh",
            ],
        },
        "inspections": [],
    }


def _pre_inspect_skips_ssh_readiness(deterministic: dict[str, Any]) -> bool:
    if deterministic.get("skip_ssh"):
        return True
    pre = deterministic.get("pre_inspect") or []
    if not pre:
        return False
    return all(
        is_ha_inspect_action(str(row.get("action_key") or ""))
        or is_web_search_inspect_action(str(row.get("action_key") or ""))
        for row in pre
    )


def _pre_inspect_needs_ha(deterministic: dict[str, Any]) -> bool:
    pre = deterministic.get("pre_inspect") or []
    return any(
        is_ha_inspect_action(str(row.get("action_key") or "")) for row in pre
    )


def _pre_inspect_needs_web_search(deterministic: dict[str, Any]) -> bool:
    pre = deterministic.get("pre_inspect") or []
    return any(
        is_web_search_inspect_action(str(row.get("action_key") or "")) for row in pre
    )


def _pre_inspect_is_ha_only(deterministic: dict[str, Any]) -> bool:
    pre = deterministic.get("pre_inspect") or []
    if not pre:
        return False
    return all(is_ha_inspect_action(str(row.get("action_key") or "")) for row in pre)


def _readiness_block_result(
    host: str,
    readiness: dict[str, Any],
    *,
    inspect_setting_off: bool = False,
) -> dict[str, Any]:
    if inspect_setting_off:
        reason = "inspect auto-run disabled (ask_alfa_inspect_autorun=false)"
        fix_steps = ["Set ask_alfa_inspect_autorun to true (Approve the policy change)"]
    elif not readiness.get("env_enabled"):
        reason = "host actions env off (ALFA_AI_HOST_ACTIONS_ENABLED=0)"
        fix_steps = [
            "Enable ALFA_AI_HOST_ACTIONS_ENABLED=1 in brain deploy/.env",
            "From hub: sudo docker exec alfa-ai-api ls -l /app/secrets/host-actions/",
            "Check ALFA_AI_HOST_ACTIONS_SECRETS_DIR in /mnt/hub/alfa-ai/repo/alfa-ai/deploy/.env "
            "points at the dir holding id_ed25519 + known_hosts",
            "From hub: cd /mnt/hub/alfa-ai/repo/alfa-ai && sudo bash scripts/brain_redeploy_api.sh",
            "Ask again: the inspect steps will run in this chat",
        ]
    else:
        ssh_path = readiness.get("ssh_key_path") or "/app/secrets/host-actions/id_ed25519"
        reason = f"SSH key not mounted in alfa-ai-api ({ssh_path})"
        fix_steps = [
            "From hub: sudo docker exec alfa-ai-api ls -l /app/secrets/host-actions/",
            "Check ALFA_AI_HOST_ACTIONS_SECRETS_DIR in /mnt/hub/alfa-ai/repo/alfa-ai/deploy/.env "
            "points at the dir holding id_ed25519 + known_hosts",
            "From hub: cd /mnt/hub/alfa-ai/repo/alfa-ai && sudo bash scripts/brain_redeploy_api.sh",
            "Ask again: the inspect steps will run in this chat",
        ]
    reply = (
        f"Cannot inspect host {host}: {reason}. "
        "Fix steps are listed below. I will not queue a mission as a substitute."
    )
    return {
        "ok": True,
        "reply": reply,
        "applied_setting": None,
        "pending_setting_proposal": None,
        "host_action_proposal": None,
        "readiness_block": {"host": host, "reason": reason, "fix_steps": fix_steps},
        "inspections": [],
    }


def _execute_inspect_step(
    action_key: str,
    host: str,
    params: dict[str, Any],
    *,
    user: UserRecord,
    actions: AiActionStore,
    config: dict[str, Any],
) -> dict[str, Any]:
    """Run one read-only inspect step; record audit; return step dict."""
    try:
        _, host_cfg, normalized_params = validate_proposal(
            action_key, host, params, config, enforce_enabled=False
        )
    except ValueError as exc:
        result = ExecResult(
            ok=False,
            command_run="",
            stdout="",
            stderr=str(exc),
            exit_code=1,
        )
        step = inspection_step_dict(action_key, host, result, 0)
        actions.record(
            ACTION_HOST_INSPECT_EXECUTED,
            f"Ask ALFa inspected {action_key} on host {host} -> exit {result.exit_code}",
            detail={
                "action_key": action_key,
                "host": host,
                "command_run": result.command_run,
                "exit_code": result.exit_code,
                "duration_ms": 0,
                "operator": user.email,
            },
            created_by=user.email,
        )
        return step

    start = time.monotonic()
    try:
        result = run_inspect_action_sync(action_key, host_cfg, normalized_params, config)
    except Exception as exc:
        result = ExecResult(
            ok=False,
            command_run="",
            stdout="",
            stderr=str(exc),
            exit_code=1,
        )
    duration_ms = int((time.monotonic() - start) * 1000)
    step = inspection_step_dict(action_key, host, result, duration_ms)
    actions.record(
        ACTION_HOST_INSPECT_EXECUTED,
        f"Ask ALFa inspected {action_key} on host {host} -> exit {result.exit_code}",
        detail={
            "action_key": action_key,
            "host": host,
            "command_run": result.command_run,
            "exit_code": result.exit_code,
            "duration_ms": duration_ms,
            "operator": user.email,
        },
        created_by=user.email,
    )
    return step


def _inspect_host_from_agent(
    args: dict[str, Any],
    *,
    user: UserRecord,
    actions: AiActionStore,
    settings: AiSettingStore,
    config: dict[str, Any],
    budget_state: dict[str, Any],
    progress: Callable[[dict[str, Any]], None] | None = None,
) -> dict[str, Any]:
    action_key = str(args.get("action_key") or "").strip()
    host = str(args.get("host") or "").strip()
    params = args.get("params") if isinstance(args.get("params"), dict) else {}

    if is_web_search_inspect_action(action_key):
        from src.config import web_search_enabled

        if not web_search_enabled():
            return {
                "ok": False,
                "error": "web_search disabled (ALFA_AI_WEB_SEARCH_ENABLED=0)",
            }
        if not inspect_autorun_enabled(settings):
            return {
                "ok": False,
                "error": (
                    "inspect auto-run is off (ask_alfa_inspect_autorun=false); propose the action instead"
                ),
            }
        if not is_inspectable(action_key):
            return {
                "ok": False,
                "error": f"{action_key} is not a read-only inspect action; use propose_host_action",
            }
    elif is_ha_inspect_action(action_key):
        if not _home_assistant_ready():
            return {
                "ok": False,
                "error": (
                    "Home Assistant integration is off or token file missing. "
                    "Set ALFA_AI_HOME_ASSISTANT_* in deploy/.env and redeploy alfa-ai-api."
                ),
            }
        if not inspect_autorun_enabled(settings):
            return {
                "ok": False,
                "error": (
                    "inspect auto-run is off (ask_alfa_inspect_autorun=false); propose the action instead"
                ),
            }
        if not is_inspectable(action_key):
            return {
                "ok": False,
                "error": f"{action_key} is not a read-only inspect action; use propose_host_action",
            }
    elif not host_actions_enabled():
        return {
            "ok": False,
            "error": (
                "Host actions infra is off (ALFA_AI_HOST_ACTIONS_ENABLED=0). "
                "One-time: set it in brain deploy/.env, mount the SSH key, redeploy API."
            ),
        }
    else:
        readiness = _host_actions_readiness()
        if not readiness.get("ready"):
            if not readiness.get("env_enabled"):
                return {
                    "ok": False,
                    "error": "Host actions env off (ALFA_AI_HOST_ACTIONS_ENABLED=0)",
                }
            ssh_path = readiness.get("ssh_key_path") or "/app/secrets/host-actions/id_ed25519"
            return {
                "ok": False,
                "error": f"SSH key not mounted in alfa-ai-api ({ssh_path})",
            }

        if not inspect_autorun_enabled(settings):
            return {
                "ok": False,
                "error": (
                    "inspect auto-run is off (ask_alfa_inspect_autorun=false); propose the action instead"
                ),
            }

        if not is_inspectable(action_key):
            return {
                "ok": False,
                "error": f"{action_key} is not a read-only inspect action; use propose_host_action",
            }

    elapsed = time.monotonic() - budget_state["start_time"]
    if (
        budget_state.get("inspect_count", 0) >= _INSPECT_MAX_STEPS
        or elapsed > _INSPECT_TOTAL_SEC
    ):
        return {
            "ok": False,
            "error": "inspect budget exhausted; reply with findings now",
        }

    step = _execute_inspect_step(
        action_key, host, params, user=user, actions=actions, config=config
    )
    budget_state["inspect_count"] = budget_state.get("inspect_count", 0) + 1
    budget_state["inspections"].append(step)

    if progress is not None:
        try:
            progress(step)
        except Exception:
            logger.debug("inspect progress callback failed", exc_info=True)

    result_stdout = step.get("stdout") or ""
    result_stderr = step.get("stderr") or ""
    return {
        "ok": step.get("ok", False),
        "action_key": action_key,
        "host": host,
        "command_run": step.get("command_run") or "",
        "exit_code": step.get("exit_code", 1),
        "stdout": result_stdout[:4000],
        "stderr": result_stderr[:1000],
    }


def _compact_inspection_for_llm(step: dict[str, Any]) -> dict[str, Any]:
    return {
        "action_key": step.get("action_key"),
        "host": step.get("host"),
        "ok": step.get("ok"),
        "exit_code": step.get("exit_code"),
        "command_run": (step.get("command_run") or "")[:500],
        "stdout": (step.get("stdout") or "")[:_INSPECT_STDOUT_PER_STEP],
        "stderr": (step.get("stderr") or "")[:400],
    }


def _inspect_findings_payload(
    *,
    repo_target: dict[str, Any],
    inspections: list[dict[str, Any]],
    remaining_steps: int,
    llm_inspections: list[dict[str, Any]] | None = None,
) -> str:
    shown = llm_inspections if llm_inspections is not None else inspections
    payload = {
        "repo_target": repo_target,
        "inspect_steps_already_run": len(inspections),
        "inspect_steps_remaining": remaining_steps,
        "inspections": [_compact_inspection_for_llm(step) for step in shown],
    }
    return json.dumps(payload, ensure_ascii=True, default=str)[:_INSPECT_FINDINGS_MAX_CHARS]


def _compact_older_inspect_tool_messages(
    messages: list[dict[str, Any]],
    *,
    keep_last: int = INSPECT_COMPACT_KEEP_LAST,
) -> None:
    """Shrink older inspect tool results in-place; keep tool_call_id for OpenAI pairing."""
    inspect_indices: list[int] = []
    for index, message in enumerate(messages):
        if message.get("role") != "tool":
            continue
        content = str(message.get("content") or "")
        if is_pending_propose_tool_content(content):
            continue
        try:
            parsed = json.loads(content)
        except json.JSONDecodeError:
            continue
        if not isinstance(parsed, dict):
            continue
        if parsed.get("compacted"):
            continue
        if "action_key" in parsed or "stdout" in parsed:
            inspect_indices.append(index)
    if len(inspect_indices) <= keep_last:
        return
    for index in inspect_indices[:-keep_last]:
        parsed = json.loads(messages[index]["content"])
        messages[index]["content"] = compact_inspect_tool_content(parsed)


def _history_turns_to_messages(
    history: list[HistoryTurn] | None,
) -> list[dict[str, str]]:
    if not history:
        return []
    return [{"role": turn.role, "content": turn.content} for turn in history]


def _build_monitoring_agent_messages(
    *,
    message: str,
    context: dict[str, Any],
    system_prompt: str,
    repo_target: dict[str, Any] | None,
    pre_inspections: list[dict[str, Any]] | None,
    history: list[HistoryTurn] | None = None,
) -> list[dict[str, str]]:
    """Chat messages for Ask ALFa.

    Activity, cluster ops, and catalog are separate user messages so neither is
    mid-JSON-cut. Inspect stdout is its own user message. Dock history is resent
    before the operator turn -- OpenAI chat message list:
    https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create/
    """
    activity_ctx, ops_ctx, catalog_ctx = split_ask_alfa_context(context)
    activity_for_llm = {
        key: value
        for key, value in activity_ctx.items()
        if key not in LLM_ACTIVITY_OMIT_KEYS
    }
    activity_blob = json.dumps(activity_for_llm, ensure_ascii=True, default=str)[
        :_ACTIVITY_CONTEXT_MAX_CHARS
    ]
    ops_blob = json.dumps(ops_ctx, ensure_ascii=True, default=str)[
        :_OPS_CONTEXT_MAX_CHARS
    ]
    catalog_blob = json.dumps(catalog_ctx, ensure_ascii=True, default=str)[
        :_ADMIN_CONTEXT_MAX_CHARS
    ]
    messages: list[dict[str, str]] = [
        {"role": "system", "content": system_prompt},
        {
            "role": "user",
            "content": f"Recent activity (authoritative):\n{activity_blob}",
        },
        {
            "role": "user",
            "content": f"Cluster ops (authoritative):\n{ops_blob}",
        },
        {
            "role": "user",
            "content": f"Host-action catalog (truncated):\n{catalog_blob}",
        },
    ]
    history_messages = _history_turns_to_messages(history)
    if pre_inspections is not None:
        remaining = _INSPECT_MAX_STEPS
        older, recent = compact_inspect_steps(pre_inspections)
        compact_msg = build_inspect_compact_user_message(older)
        if compact_msg:
            messages.append({"role": "user", "content": compact_msg})
        findings = _inspect_findings_payload(
            repo_target=repo_target or {},
            inspections=pre_inspections,
            remaining_steps=remaining,
            llm_inspections=recent,
        )
        messages.append(
            {
                "role": "user",
                "content": f"Inspect findings (authoritative for this turn):\n{findings}",
            }
        )
        messages.extend(history_messages)
        messages.append(
            {
                "role": "user",
                "content": (
                    f"Operator message: {message}\n\n{_INSPECT_TURN_OPERATOR_TAIL}"
                ),
            }
        )
        return messages
    messages.extend(history_messages)
    messages.append(
        {
            "role": "user",
            "content": f"Operator message: {message}",
        }
    )
    return messages


def _monitoring_agent_packed_messages(
    *,
    message: str,
    context: dict[str, Any],
    config: dict[str, Any],
    pre_inspections: list[dict[str, Any]] | None = None,
    repo_target: dict[str, Any] | None = None,
    history: list[HistoryTurn] | None = None,
) -> list[dict[str, str]]:
    system_prompt = _effective_monitoring_agent_system(config)
    return _build_monitoring_agent_messages(
        message=message,
        context=context,
        system_prompt=system_prompt,
        repo_target=repo_target,
        pre_inspections=pre_inspections,
        history=history,
    )


def _context_usage_for_messages(
    messages: list[dict[str, Any]],
    *,
    prompt_tokens: int | None = None,
    completion_tokens: int | None = None,
) -> dict[str, Any]:
    return build_context_usage(
        messages,
        prompt_tokens=prompt_tokens,
        completion_tokens=completion_tokens,
    )


async def _finalize_deterministic_ha_auto_actuate(
    deterministic: dict[str, Any],
    *,
    user: UserRecord,
    actions: AiActionStore,
    config: dict[str, Any],
) -> dict[str, Any]:
    """Run router-queued HA mutate immediately; audit as host_command_executed."""
    req = deterministic.get("host_action_auto_actuate")
    if not isinstance(req, dict):
        return deterministic
    out = dict(deterministic)
    out.pop("host_action_auto_actuate", None)
    out["host_action_proposal"] = None

    tool_result = await _execute_ha_auto_actuate_step(
        str(req.get("action_key") or ""),
        str(req.get("host") or ""),
        req.get("params") if isinstance(req.get("params"), dict) else {},
        user=user,
        actions=actions,
        config=config,
        proposed_by=user.email,
    )
    inspections: list[dict[str, Any]] = []
    if tool_result.get("ok") and tool_result.get("executed"):
        inspections.append(
            {
                "action_key": tool_result.get("action_key") or req.get("action_key"),
                "host": tool_result.get("host") or req.get("host"),
                "command_run": tool_result.get("command_run") or "",
                "stdout": tool_result.get("stdout") or "",
                "stderr": tool_result.get("stderr") or "",
                "exit_code": tool_result.get("exit_code", 0),
                "ok": tool_result.get("ok", False),
                "duration_ms": tool_result.get("duration_ms", 0),
                "auto_actuate": True,
            }
        )
        lines = [
            "Executed immediately (no Approve).",
            str(tool_result.get("summary") or ""),
            f"exit_code: {tool_result.get('exit_code')}",
        ]
        if tool_result.get("command_run"):
            lines.append(f"command: {tool_result['command_run']}")
        stdout = (tool_result.get("stdout") or "").strip()
        if stdout:
            lines.append(f"stdout:\n{stdout}")
        stderr = (tool_result.get("stderr") or "").strip()
        if stderr:
            lines.append(f"stderr:\n{stderr}")
        out["reply"] = "\n".join(lines)
    else:
        err = tool_result.get("error") or "HA action failed"
        out["reply"] = f"HA auto-actuate failed: {err}"
    out["inspections"] = inspections
    return out


def _run_ask_alfa_deterministic(
    message: str,
    context: dict[str, Any],
    *,
    host_store: HostActionStore,
    settings: AiSettingStore,
    actions: AiActionStore,
    config: dict[str, Any],
    operator_email: str,
    history: list[HistoryTurn] | None = None,
) -> dict[str, Any] | None:
    """Sync Ask ALFa deterministic handlers (Path B loop is LiteLLM I/O)."""
    return try_handle_deterministic(
        message,
        context,
        host_store=host_store,
        settings_store=settings,
        actions_store=actions,
        config=config,
        operator_email=operator_email,
        history=_history_turns_to_messages(history),
    )


def _ensure_context_usage_on_result(
    result: dict[str, Any],
    *,
    message: str,
    context: dict[str, Any],
    config: dict[str, Any],
    history: list[HistoryTurn] | None = None,
) -> dict[str, Any]:
    if "context_usage" in result:
        return result
    packed = _monitoring_agent_packed_messages(
        message=message,
        context=context,
        config=config,
        history=history,
    )
    out = dict(result)
    out["context_usage"] = _context_usage_for_messages(packed)
    return out


def _run_llm_continue_turn(
    *,
    message: str,
    user: UserRecord,
    context: dict[str, Any],
    config: dict[str, Any],
    settings: AiSettingStore,
    actions: AiActionStore,
    host_store: HostActionStore,
    deterministic: dict[str, Any],
    progress: Callable[[dict[str, Any]], None] | None = None,
    history: list[HistoryTurn] | None = None,
) -> dict[str, Any]:
    repo_target = deterministic.get("repo_target") or {}
    host = str(repo_target.get("host") or "")
    repo_dir = repo_target.get("repo_dir")
    host_cfg = load_hosts(config).get(host) or {}
    steps: list[dict[str, Any]] = []

    for pre in deterministic.get("pre_inspect") or []:
        action_key = str(pre.get("action_key") or "").strip()
        params = dict(pre.get("params") or {})
        if action_key.startswith("repo_") and repo_dir:
            if repo_dir != host_cfg.get("repo_dir"):
                params["repo_dir"] = repo_dir
        step = _execute_inspect_step(
            action_key, host, params, user=user, actions=actions, config=config
        )
        steps.append(step)
        if progress is not None:
            try:
                progress(step)
            except Exception:
                logger.debug("pre_inspect progress callback failed", exc_info=True)

    llm_context = dict(context)
    llm_context["repo_target"] = repo_target

    return _monitoring_agent_llm_result(
        message=message,
        user=user,
        context=llm_context,
        config=config,
        settings=settings,
        actions=actions,
        host_store=host_store,
        progress=progress,
        pre_inspections=steps,
        repo_target=repo_target,
        history=history,
    )


def _handle_llm_continue_deterministic(
    deterministic: dict[str, Any],
    *,
    message: str,
    user: UserRecord,
    context: dict[str, Any],
    config: dict[str, Any],
    settings: AiSettingStore,
    actions: AiActionStore,
    host_store: HostActionStore,
    progress: Callable[[dict[str, Any]], None] | None = None,
    history: list[HistoryTurn] | None = None,
) -> dict[str, Any]:
    repo_target = deterministic.get("repo_target") or {}
    target_host = str(repo_target.get("host") or "")
    readiness = _host_actions_readiness()

    if _pre_inspect_skips_ssh_readiness(deterministic):
        if _pre_inspect_needs_ha(deterministic) and not _home_assistant_ready():
            return _ha_inspect_block_result()
        if _pre_inspect_needs_web_search(deterministic):
            from src.config import web_search_enabled

            if not web_search_enabled():
                return _web_search_inspect_block_result()
        if not inspect_autorun_enabled(settings):
            block_host = target_host or (
                "105" if _pre_inspect_needs_ha(deterministic) else "111"
            )
            return _readiness_block_result(
                block_host, readiness, inspect_setting_off=True
            )
        return _run_llm_continue_turn(
            message=message,
            user=user,
            context=context,
            config=config,
            settings=settings,
            actions=actions,
            host_store=host_store,
            deterministic=deterministic,
            progress=progress,
            history=history,
        )

    if not readiness.get("ready"):
        return _readiness_block_result(target_host, readiness)
    if not inspect_autorun_enabled(settings):
        return _readiness_block_result(target_host, readiness, inspect_setting_off=True)

    return _run_llm_continue_turn(
        message=message,
        user=user,
        context=context,
        config=config,
        settings=settings,
        actions=actions,
        host_store=host_store,
        deterministic=deterministic,
        progress=progress,
        history=history,
    )


def _run_monitoring_agent_tool(
    tool_name: str,
    tool_args: dict[str, Any],
    *,
    user: UserRecord,
    actions: AiActionStore,
    settings: AiSettingStore,
    config: dict[str, Any],
    host_store: HostActionStore,
    budget_state: dict[str, Any],
    progress: Callable[[dict[str, Any]], None] | None,
    host_action_proposal: dict[str, Any] | None,
) -> tuple[dict[str, Any], dict[str, Any] | None]:
    """Execute inspect_host or propose_host_action for the Ask ALFa loop."""
    if tool_name == "propose_host_action":
        # LLM result runs in a worker thread (no running loop).
        # https://docs.python.org/3/library/asyncio-runner.html#asyncio.run
        tool_result = asyncio.run(
            _propose_host_action_from_agent(
                tool_args,
                proposed_by="ai",
                host_store=host_store,
                config=config,
                user=user,
                actions=actions,
            )
        )
        if tool_result.get("ok") and tool_result.get("executed"):
            step = {
                "action_key": str(tool_args.get("action_key") or ""),
                "host": str(tool_args.get("host") or ""),
                "command_run": tool_result.get("command_run") or "",
                "stdout": tool_result.get("stdout") or "",
                "stderr": tool_result.get("stderr") or "",
                "exit_code": tool_result.get("exit_code", 0),
                "ok": tool_result.get("ok", False),
                "duration_ms": tool_result.get("duration_ms", 0),
                "auto_actuate": True,
            }
            budget_state["inspections"].append(step)
        elif tool_result.get("ok"):
            host_action_proposal = {
                "id": tool_result.get("action_id"),
                "summary": tool_result.get("summary"),
                "status": STATUS_PENDING,
                "action_key": str(tool_args.get("action_key") or ""),
                "action_category": action_category(
                    str(tool_args.get("action_key") or "")
                ),
                "host": str(tool_args.get("host") or ""),
                "risk_tier": tool_result.get("risk_tier", 3),
                "auth_level": tool_result.get("auth_level"),
                "requires_ack": tool_result.get("requires_ack"),
                "soft_disabled": tool_result.get("soft_disabled"),
                "will_enable_packs": tool_result.get("will_enable_packs") or [],
                "pack_label": tool_result.get("pack_label"),
            }
        return tool_result, host_action_proposal
    if tool_name == "inspect_host":
        tool_result = _inspect_host_from_agent(
            tool_args,
            user=user,
            actions=actions,
            settings=settings,
            config=config,
            budget_state=budget_state,
            progress=progress,
        )
        return tool_result, host_action_proposal
    return (
        {
            "ok": False,
            "error": "unknown tool; use inspect_host or propose_host_action",
        },
        host_action_proposal,
    )


def _monitoring_agent_llm_result(
    *,
    message: str,
    user: UserRecord,
    context: dict[str, Any],
    config: dict[str, Any],
    settings: AiSettingStore,
    actions: AiActionStore,
    host_store: HostActionStore,
    progress: Callable[[dict[str, Any]], None] | None = None,
    pre_inspections: list[dict[str, Any]] | None = None,
    repo_target: dict[str, Any] | None = None,
    history: list[HistoryTurn] | None = None,
) -> dict[str, Any]:
    """LLM path only (sync). Runs in a worker thread for SSE heartbeats."""
    from src.agent.openai_tools import ask_alfa_openai_tools_payload
    from src.config import native_tools_enabled
    from src.llm.client import (
        NativeToolCall,
        agent_synthesis_response_format,
        get_agent_completion_turn,
    )

    setting_keys = {s["key"] for s in context.get("ai_settings") or []}

    messages: list[dict[str, Any]] = _monitoring_agent_packed_messages(
        message=message,
        context=context,
        config=config,
        repo_target=repo_target,
        pre_inspections=pre_inspections,
        history=history,
    )

    raw_reply = ""
    host_action_proposal: dict[str, Any] | None = None
    last_prompt_tokens: int | None = None
    last_completion_tokens: int | None = None
    budget_state: dict[str, Any] = {
        "start_time": time.monotonic(),
        # Pre-inspect is separate; LLM inspect_host calls get a fresh 6-step budget.
        "inspect_count": 0,
        "inspections": list(pre_inspections or []),
    }

    use_native = native_tools_enabled()
    tools_payload = ask_alfa_openai_tools_payload() if use_native else None

    for _ in range(_MONITORING_AGENT_MAX_STEPS):
        _compact_older_inspect_tool_messages(messages)
        try:
            if use_native:
                turn = get_agent_completion_turn(
                    messages,
                    tools=tools_payload,
                    response_format=None,
                )
            else:
                turn = get_agent_completion_turn(
                    messages,
                    response_format=agent_synthesis_response_format(),
                )
            raw_reply = turn.content.strip()
            if turn.usage:
                last_prompt_tokens = turn.usage.get("prompt_tokens")
                last_completion_tokens = turn.usage.get("completion_tokens")
        except AgentCircuitOpenError as exc:
            logger.warning("monitoring_agent circuit open: %s", exc)
            raise HTTPException(status_code=502, detail=str(exc)) from exc
        except Exception as exc:
            logger.exception("monitoring_agent failed")
            raise HTTPException(
                status_code=502, detail=f"Agent model unavailable: {exc}"
            ) from exc

        native_calls: list[NativeToolCall] = (
            [c for c in turn.tool_calls if c.name] if use_native else []
        )
        if native_calls:
            messages.append(
                {
                    "role": "assistant",
                    "content": raw_reply or None,
                    "tool_calls": [
                        {
                            "id": call.id or f"call_{idx}",
                            "type": "function",
                            "function": {
                                "name": call.name,
                                "arguments": json.dumps(
                                    call.arguments, ensure_ascii=True
                                ),
                            },
                        }
                        for idx, call in enumerate(native_calls)
                    ],
                }
            )
            for idx, call in enumerate(native_calls):
                tool_result, host_action_proposal = _run_monitoring_agent_tool(
                    call.name,
                    call.arguments,
                    user=user,
                    actions=actions,
                    settings=settings,
                    config=config,
                    host_store=host_store,
                    budget_state=budget_state,
                    progress=progress,
                    host_action_proposal=host_action_proposal,
                )
                messages.append(
                    {
                        "role": "tool",
                        "tool_call_id": call.id or f"call_{idx}",
                        "content": json.dumps(tool_result, ensure_ascii=True)[:4000],
                    }
                )
            continue

        tool_call = _parse_agent_tool_call(raw_reply)
        if tool_call:
            tool_name, tool_args = tool_call
            tool_result, host_action_proposal = _run_monitoring_agent_tool(
                tool_name,
                tool_args,
                user=user,
                actions=actions,
                settings=settings,
                config=config,
                host_store=host_store,
                budget_state=budget_state,
                progress=progress,
                host_action_proposal=host_action_proposal,
            )
            messages.append({"role": "assistant", "content": raw_reply})
            messages.append(
                {
                    "role": "tool",
                    "content": json.dumps(tool_result, ensure_ascii=True)[:4000],
                }
            )
            continue

        break

    reply_text, parsed = _parse_monitoring_agent_reply(raw_reply)
    setting_change = parsed.get("setting_change") if parsed else None
    if parsed and parsed.get("host_action_id") and not host_action_proposal:
        from src.api.uuid_util import parse_uuid

        raw_ha = str(parsed["host_action_id"]).strip()
        if parse_uuid(raw_ha) is None:
            logger.warning(
                "monitoring_agent ignored non-UUID host_action_id from model: %r",
                raw_ha[:64],
            )
        else:
            pending = host_store.get_by_id(raw_ha)
            if pending and pending.status == STATUS_PENDING:
                auth = _proposal_auth_fields(pending.action_key, config)
                host_action_proposal = {
                    "id": pending.id,
                    "summary": pending.summary,
                    "status": pending.status,
                    "action_key": pending.action_key,
                    "action_category": action_category(pending.action_key),
                    "host": pending.host,
                    **auth,
                }

    applied: dict[str, Any] | None = None
    pending_setting: dict[str, Any] | None = None
    if isinstance(setting_change, dict) and setting_change.get("key") in setting_keys:
        key = str(setting_change["key"])
        new_value = str(setting_change.get("value", ""))
        new_value = normalize_setting_input(key, new_value)
        try:
            new_value = validate_setting_value(key, new_value)
        except AiSettingError as exc:
            reply_text = (
                f"{reply_text.rstrip()}\n\n(Setting change not applied: {exc})"
            )
        else:
            old_value = settings.get(key, "")
            if is_policy_setting(key):
                record = actions.record(
                    ACTION_SETTING_PROPOSAL,
                    f"Proposed {key}: {old_value or '(empty)'} -> {new_value or '(empty)'}",
                    detail={
                        "key": key,
                        "old_value": old_value,
                        "new_value": new_value,
                        "status": "pending",
                        "reason": "Policy setting requires operator Approve",
                        "message": message[:500],
                    },
                    created_by=user.email,
                )
                pending_setting = {
                    "id": record.id,
                    "key": key,
                    "old_value": old_value,
                    "new_value": new_value,
                    "status": "pending",
                    "description": setting_description(key),
                    "requires_approve_reason": POLICY_SETTING_REQUIRES_APPROVE_REASON,
                }
            else:
                try:
                    settings.set(key, new_value, updated_by=user.email, by_ai=False)
                    actions.record(
                        ACTION_SETTING_CHANGED,
                        f"{user.email} (via Ask ALFa) set {key}: {old_value or '(empty)'} -> {new_value or '(empty)'}",
                        detail={
                            "key": key,
                            "old_value": old_value,
                            "new_value": new_value,
                            "reason": "Requested via Ask ALFa chat",
                            "message": message[:500],
                        },
                        created_by=user.email,
                    )
                    applied = {
                        "key": key,
                        "old_value": old_value,
                        "new_value": new_value,
                        "description": setting_description(key),
                    }
                    logger.info("ask-alfa applied setting %s -> %s by=%s", key, new_value, user.email)
                except AiSettingError:
                    logger.exception("ask-alfa setting change rejected for key=%s", key)

    reply_text = annotate_reply_if_no_proposal(reply_text, host_action_proposal)
    return {
        "ok": True,
        "reply": reply_text,
        "applied_setting": applied,
        "pending_setting_proposal": pending_setting,
        "host_action_proposal": host_action_proposal,
        "inspections": budget_state["inspections"],
        "context_usage": _context_usage_for_messages(
            messages,
            prompt_tokens=last_prompt_tokens,
            completion_tokens=last_completion_tokens,
        ),
    }


async def _build_monitoring_agent_result(
    *,
    message: str,
    user: UserRecord,
    incidents: IncidentStore,
    settings: AiSettingStore,
    actions: AiActionStore,
    users: UserStore,
    sec: SecurityStore,
    host_store: HostActionStore,
    config: dict[str, Any],
    pre_context: dict[str, Any] | None = None,
    skip_deterministic: bool = False,
    history: list[HistoryTurn] | None = None,
) -> dict[str, Any]:
    """Shared Ask ALFa logic for non-stream and stream endpoints."""
    context = pre_context
    if context is None:
        context = await _gather_monitoring_agent_context(
            incidents=incidents,
            settings=settings,
            actions=actions,
            users=users,
            sec=sec,
            host_store=host_store,
            config=config,
        )

    if not skip_deterministic:
        if parse_draft_judge_task(message) is not None:
            # Path B LiteLLM rounds are blocking I/O; keep the event loop free.
            # https://fastapi.tiangolo.com/async/
            # https://docs.python.org/3/library/asyncio-task.html#asyncio.to_thread
            deterministic = await asyncio.to_thread(
                _run_ask_alfa_deterministic,
                message,
                context,
                host_store=host_store,
                settings=settings,
                actions=actions,
                config=config,
                operator_email=user.email,
                history=history,
            )
        else:
            deterministic = _run_ask_alfa_deterministic(
                message,
                context,
                host_store=host_store,
                settings=settings,
                actions=actions,
                config=config,
                operator_email=user.email,
                history=history,
            )
        if deterministic is not None:
            if deterministic.get("llm_continue"):
                result = await asyncio.to_thread(
                    _handle_llm_continue_deterministic,
                    deterministic,
                    message=message,
                    user=user,
                    context=context,
                    config=config,
                    settings=settings,
                    actions=actions,
                    host_store=host_store,
                    history=history,
                )
            else:
                result = deterministic
                if deterministic.get("host_action_auto_actuate"):
                    result = await _finalize_deterministic_ha_auto_actuate(
                        deterministic,
                        user=user,
                        actions=actions,
                        config=config,
                    )
            return _ensure_context_usage_on_result(
                result,
                message=message,
                context=context,
                config=config,
                history=history,
            )

    return await asyncio.to_thread(
        _monitoring_agent_llm_result,
        message=message,
        user=user,
        context=context,
        config=config,
        settings=settings,
        actions=actions,
        host_store=host_store,
        history=history,
    )


@router.get("/ask-alfa/context-usage")
async def ask_alfa_context_usage(
    user: UserRecord = Depends(require_role("admin")),
    incidents: IncidentStore = Depends(get_incident_store),
    settings: AiSettingStore = Depends(get_ai_setting_store),
    actions: AiActionStore = Depends(get_ai_action_store),
    users: UserStore = Depends(get_user_store),
    sec: SecurityStore = Depends(get_security_store),
    host_store: HostActionStore = Depends(get_host_action_store),
    agent_config_store: AgentConfigStore = Depends(get_agent_config_store),
) -> dict[str, Any]:
    """Packed-prompt estimate vs slot window for the admin context ring (no LLM call)."""
    config = agent_config_store.get()
    context = await _gather_monitoring_agent_context(
        incidents=incidents,
        settings=settings,
        actions=actions,
        users=users,
        sec=sec,
        host_store=host_store,
        config=config,
    )
    messages = _monitoring_agent_packed_messages(
        message="",
        context=context,
        config=config,
    )
    return {
        "ok": True,
        "context_usage": _context_usage_for_messages(messages),
    }


@router.post("/monitoring-agent")
async def monitoring_agent(
    body: MonitoringAgentRequest,
    user: UserRecord = Depends(require_role("admin")),
    incidents: IncidentStore = Depends(get_incident_store),
    settings: AiSettingStore = Depends(get_ai_setting_store),
    actions: AiActionStore = Depends(get_ai_action_store),
    users: UserStore = Depends(get_user_store),
    sec: SecurityStore = Depends(get_security_store),
    host_store: HostActionStore = Depends(get_host_action_store),
    agent_config_store: AgentConfigStore = Depends(get_agent_config_store),
) -> dict[str, Any]:
    """Global 'Ask ALFa' chat: full admin context, optional setting change, host action proposals."""
    try:
        config = agent_config_store.get()
        return await _build_monitoring_agent_result(
            message=body.message,
            user=user,
            incidents=incidents,
            settings=settings,
            actions=actions,
            users=users,
            sec=sec,
            host_store=host_store,
            config=config,
            history=body.history,
        )
    except HTTPException:
        raise
    except Exception as exc:
        logger.exception("monitoring_agent unexpected error")
        raise HTTPException(
            status_code=502, detail=f"Ask ALFa request failed: {exc}"
        ) from exc


@router.post("/monitoring-agent/stream")
async def monitoring_agent_stream(
    body: MonitoringAgentRequest,
    request: Request,
    user: UserRecord = Depends(require_role("admin")),
    incidents: IncidentStore = Depends(get_incident_store),
    settings: AiSettingStore = Depends(get_ai_setting_store),
    actions: AiActionStore = Depends(get_ai_action_store),
    users: UserStore = Depends(get_user_store),
    sec: SecurityStore = Depends(get_security_store),
    host_store: HostActionStore = Depends(get_host_action_store),
    agent_config_store: AgentConfigStore = Depends(get_agent_config_store),
) -> StreamingResponse:
    """Ask ALFa SSE stream: heartbeats while agent model runs, then done or error.

    Client disconnect / Stop (AbortController) is detected via
    ``request.is_disconnected()`` each heartbeat. After disconnect we never yield
    ``done`` or proposals (NIST L2). Sync LiteLLM in a worker thread may still
    finish in the background (v1 limit) — result is discarded.
    """

    async def generate() -> AsyncGenerator[str, None]:
        config = agent_config_store.get()
        context = await _gather_monitoring_agent_context(
            incidents=incidents,
            settings=settings,
            actions=actions,
            users=users,
            sec=sec,
            host_store=host_store,
            config=config,
        )
        if await request.is_disconnected():
            logger.info("monitoring_agent_stream: client disconnected before reply")
            return

        progress_q: queue.Queue[dict[str, Any]] = queue.Queue()

        def _drain_inspect_progress() -> list[dict[str, Any]]:
            drained: list[dict[str, Any]] = []
            while True:
                try:
                    drained.append(progress_q.get_nowait())
                except queue.Empty:
                    break
            return drained

        if parse_draft_judge_task(body.message) is not None:
            yield _monitoring_agent_sse_line(
                {"type": "status", "message": "Running 7B draft + 27B judge loop..."}
            )
            task = asyncio.create_task(
                asyncio.to_thread(
                    _run_ask_alfa_deterministic,
                    body.message,
                    context,
                    host_store=host_store,
                    settings=settings,
                    actions=actions,
                    config=config,
                    operator_email=user.email,
                    history=body.history,
                )
            )
        else:
            deterministic = _run_ask_alfa_deterministic(
                body.message,
                context,
                host_store=host_store,
                settings=settings,
                actions=actions,
                config=config,
                operator_email=user.email,
                history=body.history,
            )
            if deterministic is not None:
                if deterministic.get("llm_continue"):
                    if await request.is_disconnected():
                        return
                    yield _monitoring_agent_sse_line(
                        {"type": "status", "message": "Running inspect steps..."}
                    )
                    task = asyncio.create_task(
                        asyncio.to_thread(
                            _handle_llm_continue_deterministic,
                            deterministic,
                            message=body.message,
                            user=user,
                            context=context,
                            config=config,
                            settings=settings,
                            actions=actions,
                            host_store=host_store,
                            progress=progress_q.put_nowait,
                            history=body.history,
                        )
                    )
                else:
                    if await request.is_disconnected():
                        return
                    result = deterministic
                    if deterministic.get("host_action_auto_actuate"):
                        result = await _finalize_deterministic_ha_auto_actuate(
                            deterministic,
                            user=user,
                            actions=actions,
                            config=config,
                        )
                    done_payload = _ensure_context_usage_on_result(
                        result,
                        message=body.message,
                        context=context,
                        config=config,
                        history=body.history,
                    )
                    yield _monitoring_agent_sse_line({"type": "done", **done_payload})
                    return
            else:
                yield _monitoring_agent_sse_line(
                    {"type": "status", "message": "Waiting on agent model..."}
                )

                task = asyncio.create_task(
                    asyncio.to_thread(
                        _monitoring_agent_llm_result,
                        message=body.message,
                        user=user,
                        context=context,
                        config=config,
                        settings=settings,
                        actions=actions,
                        host_store=host_store,
                        progress=progress_q.put_nowait,
                        history=body.history,
                    )
                )
        elapsed = 0
        cancelled = False
        try:
            while not task.done():
                if await request.is_disconnected():
                    cancelled = True
                    logger.info(
                        "monitoring_agent_stream: client disconnected; "
                        "abandoning turn (no done/proposals)"
                    )
                    break
                for step in _drain_inspect_progress():
                    if await request.is_disconnected():
                        cancelled = True
                        break
                    yield _monitoring_agent_sse_line({"type": "inspect", "step": step})
                if cancelled:
                    break
                try:
                    await asyncio.wait_for(
                        asyncio.shield(task),
                        timeout=_MONITORING_AGENT_HEARTBEAT_SEC,
                    )
                except asyncio.TimeoutError:
                    elapsed += _MONITORING_AGENT_HEARTBEAT_SEC
                    if await request.is_disconnected():
                        cancelled = True
                        break
                    for step in _drain_inspect_progress():
                        if await request.is_disconnected():
                            cancelled = True
                            break
                        yield _monitoring_agent_sse_line({"type": "inspect", "step": step})
                    if cancelled:
                        break
                    yield _monitoring_agent_sse_line(
                        {"type": "heartbeat", "elapsed_sec": elapsed}
                    )

            if cancelled:
                # Leave LLM thread running; do not emit done/error/proposals.
                return

            if await request.is_disconnected():
                return

            for step in _drain_inspect_progress():
                if await request.is_disconnected():
                    return
                yield _monitoring_agent_sse_line({"type": "inspect", "step": step})

            result = await task
            if await request.is_disconnected():
                return
            if result is None:
                yield _monitoring_agent_sse_line(
                    {"type": "error", "detail": "Ask ALFa request failed"}
                )
                return
            done_payload = _ensure_context_usage_on_result(
                result,
                message=body.message,
                context=context,
                config=config,
            )
            yield _monitoring_agent_sse_line({"type": "done", **done_payload})
        except HTTPException as exc:
            if await request.is_disconnected():
                return
            detail = exc.detail if isinstance(exc.detail, str) else str(exc.detail)
            yield _monitoring_agent_sse_line({"type": "error", "detail": detail})
        except Exception as exc:
            if await request.is_disconnected():
                return
            logger.exception("monitoring_agent_stream unexpected error")
            yield _monitoring_agent_sse_line(
                {"type": "error", "detail": f"Ask ALFa request failed: {exc}"}
            )

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


from src.api.routers.admin_missions import router as missions_router  # noqa: E402

router.include_router(missions_router)
