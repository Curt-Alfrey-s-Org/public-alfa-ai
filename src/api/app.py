from __future__ import annotations

import asyncio
import contextlib
import hmac
import json
import logging
import os
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

import httpx
from fastapi import Depends, FastAPI, Header, HTTPException, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from src.api.auth_deps import (
    require_alfa_ai_api_token,
    require_alfa_ai_api_token_sse,
    require_brain_operator_health_auth,
)
from src.api.llm_config import default_model_name, llm_tuple, sanitize_chat_model_alias
from src.api.qwen_mode import apply_qwen_mode_to_payload
from src.api.routers import admin as admin_router_module
from src.api.routers import agent as agent_router_module
from src.api.routers import auth as auth_router_module
from src.api.routers import chat as chat_router_module
from src.api.routers import guest as guest_router_module
from src.api.routers import internal_alerts as internal_alerts_router_module
from src.api.routers import pool_switch as pool_switch_router_module
from src.api.public_errors import (
    INVALID_CREDENTIALS_MSG,
    SERVICE_UNAVAILABLE,
    UNEXPECTED_ERROR,
    UPSTREAM_UNAVAILABLE,
    raise_upstream_http_exception,
)
from src.api.worker_monitoring import (
    build_brain_services_report,
    build_cluster_hosts_report,
    load_workers_from_redis,
    store_worker_heartbeat,
)
from src.api.admin_network import assert_admin_client_allowed
from src.config import get as env_get, mcp_enabled, workspace_root
from src.runtime.factory import build_orchestrator
from src.runtime.mission_events import mission_event_bus
from src.runtime.run_input import RunInputError
from src.runtime.orchestrator import RuntimeOrchestrator
from src.runtime.store import artifact_to_dict, run_to_dict, task_to_dict

logger = logging.getLogger(__name__)


def _build_hash() -> str:
    """OCI-style revision: baked at image build (Twelve-Factor build/release/run)."""
    marker = Path("/app/.build-hash")
    if marker.is_file():
        return marker.read_text(encoding="utf-8").strip()[:128]
    return (os.getenv("BUILD_HASH") or "unknown").strip()[:128]


# Public site: www.example.com. Override in deploy/.env if needed.
_DEFAULT_PRIMARY_ADMIN_EMAIL = "operator@example.com"


_mcp_inspect_server: Any | None = None


@asynccontextmanager
async def _core_app_lifespan(app: FastAPI):
    """Create or promote primary admin on startup; run solar dump ticker when DB is set.

    FastAPI lifespan: https://fastapi.tiangolo.com/advanced/events/
    """
    db_url = env_get("DATABASE_URL", "").strip()
    stop_event = asyncio.Event()
    dump_task: asyncio.Task | None = None

    if db_url:
        from src.ops.solar_dump import run_solar_dump_loop

        dump_task = asyncio.create_task(run_solar_dump_loop(stop_event))

        email = (
            env_get("ALFA_AI_PRIMARY_ADMIN_EMAIL", "").strip()
            or _DEFAULT_PRIMARY_ADMIN_EMAIL
        )
        password = env_get("ALFA_AI_PRIMARY_ADMIN_PASSWORD", "").strip()
        if not password:
            logger.warning(
                "Startup: ALFA_AI_PRIMARY_ADMIN_PASSWORD is unset -- skipping primary-admin "
                "bootstrap for %s. Set it in deploy/.env and restart, or run "
                "scripts/reset_admin_password.py to bootstrap manually.",
                email,
            )
        else:
            try:
                from src.api.models.user import UserStore

                UserStore(database_url=db_url).ensure_primary_admin(email, password)
            except Exception:
                logger.exception("Startup: ensure_primary_admin failed for %s", email)

    try:
        yield
    finally:
        if dump_task is not None:
            stop_event.set()
            dump_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await dump_task


@asynccontextmanager
async def _app_lifespan(app: FastAPI):
    """Compose core lifespan with optional MCP session manager.

    MCP mount lifespan: https://py.sdk.modelcontextprotocol.io/run/asgi/
    """
    if _mcp_inspect_server is not None:
        async with _mcp_inspect_server.session_manager.run():
            async with _core_app_lifespan(app):
                yield
    else:
        async with _core_app_lifespan(app):
            yield


_disable_openapi = env_get("ALFA_AI_DISABLE_OPENAPI", "").strip().lower() in (
    "1",
    "true",
    "yes",
)
app = FastAPI(
    title="ALFa AI Orchestrator API",
    version="0.1.0",
    lifespan=_app_lifespan,
    docs_url=None if _disable_openapi else "/docs",
    redoc_url=None if _disable_openapi else "/redoc",
    openapi_url=None if _disable_openapi else "/openapi.json",
)
orchestrator = build_orchestrator()
STATIC_DIR = Path(__file__).resolve().parent / "static"
OPERATOR_STATIC_DIR = STATIC_DIR / "operator"
ADMIN_STATIC_DIR = STATIC_DIR / "admin"
app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")

# Web app (JWT): login, chat, guest demo, admin API — required for /alfa-ai/* SPA on www.
app.include_router(auth_router_module.router)
app.include_router(chat_router_module.router)
app.include_router(guest_router_module.router)
app.include_router(admin_router_module.router)
app.include_router(pool_switch_router_module.router)
app.include_router(internal_alerts_router_module.router)
app.include_router(agent_router_module.router)


@app.exception_handler(RequestValidationError)
async def _auth_login_validation_errors(
    request: Request, exc: RequestValidationError
) -> JSONResponse:
    """Malformed login body returns the same message as wrong credentials."""
    if request.url.path.rstrip("/").endswith("/alfa-ai/api/auth/login"):
        return JSONResponse(status_code=401, content={"detail": INVALID_CREDENTIALS_MSG})
    return JSONResponse(status_code=422, content={"detail": exc.errors()})


@app.exception_handler(Exception)
async def _sanitized_unhandled_exception(request: Request, exc: Exception) -> JSONResponse:
    """Avoid leaking stack traces or internals to API clients; log server-side."""
    logger.error(
        "Unhandled exception path=%s",
        request.url.path,
        exc_info=exc,
    )
    return JSONResponse(status_code=500, content={"detail": UNEXPECTED_ERROR})


class InputFileSpec(BaseModel):
    filename: str
    content: str


class CreateRunRequest(BaseModel):
    goal: str
    research_only: bool = False
    skill: str = ""
    workflow: str = ""
    role: str = ""
    target_host: str = ""
    input_files: list[InputFileSpec] = Field(default_factory=list)


class CreateRunResponse(BaseModel):
    run_id: str


class OperatorChatMessage(BaseModel):
    role: str
    content: str


class OperatorChatRequest(BaseModel):
    messages: list[OperatorChatMessage] = Field(..., min_length=1)
    model: str | None = None
    qwen_mode: str | None = None


@app.get("/operator/api/config")
def operator_api_config(_: None = Depends(require_alfa_ai_api_token)) -> dict[str, str]:
    """LiteLLM model name used by operator chat (for UI label)."""
    raw = (
        os.getenv("OPERATOR_CHAT_MODEL", "").strip()
        or os.getenv("DEFAULT_MODEL", "").strip()
    )
    model = sanitize_chat_model_alias(raw or default_model_name())
    return {"chat_model": model}


@app.post("/operator/api/chat")
async def operator_api_chat(
    body: OperatorChatRequest,
    _: None = Depends(require_alfa_ai_api_token),
) -> dict[str, Any]:
    """
    Proxy chat to LiteLLM (OpenAI-compatible). Does not write rankings-bot ollama_activity_log.
    """
    base, key, model, timeout = llm_tuple(role="operator", model_override=body.model)
    if not key:
        logger.error("operator_chat: LiteLLM API key missing")
        raise HTTPException(status_code=503, detail=UPSTREAM_UNAVAILABLE)
    payload = {
        "model": model,
        "messages": [m.model_dump() for m in body.messages],
        "temperature": 0.3,
    }
    payload = apply_qwen_mode_to_payload(payload, model, body.qwen_mode)
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(timeout, connect=20.0)) as client:
            resp = await client.post(
                f"{base}/v1/chat/completions",
                headers={
                    "Authorization": f"Bearer {key}",
                    "Content-Type": "application/json",
                },
                json=payload,
            )
    except httpx.RequestError as exc:
        raise_upstream_http_exception(
            upstream_status=None,
            location="operator.chat",
            logger=logger,
            exc=exc,
        )

    if resp.status_code != 200:
        raise_upstream_http_exception(
            upstream_status=resp.status_code,
            location="operator.chat",
            logger=logger,
            response_text=resp.text,
        )
    return resp.json()


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/api/health")
def api_health() -> dict[str, str]:
    return {"status": "ok", "build_hash": _build_hash()}


def _expected_worker_token() -> str:
    return (
        os.getenv("ALFA_WORKER_HEARTBEAT_TOKEN", "").strip()
        or os.getenv("ALFA_AI_API_TOKEN", "").strip()
    )


def _verify_worker_heartbeat(authorization: str | None = Header(None)) -> None:
    expected = _expected_worker_token()
    if not expected:
        if os.getenv("ALFA_AI_DEV", "").strip().lower() in ("true", "1", "yes"):
            return
        logger.error("worker heartbeat: ALFA_WORKER_HEARTBEAT_TOKEN not configured")
        raise HTTPException(status_code=503, detail=SERVICE_UNAVAILABLE)
    if authorization is None or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail=SERVICE_UNAVAILABLE)
    if not hmac.compare_digest(authorization[7:].strip().encode(), expected.encode()):
        logger.warning("worker heartbeat: invalid bearer token")
        raise HTTPException(status_code=403, detail=SERVICE_UNAVAILABLE)


@app.post("/api/workers/heartbeat")
def post_worker_heartbeat(
    body: dict[str, Any],
    _: None = Depends(_verify_worker_heartbeat),
) -> dict[str, Any]:
    """
    Called by GPU worker hosts (worker-heartbeat.sh). Stores JSON in Redis with TTL.
    Requires Bearer ALFA_WORKER_HEARTBEAT_TOKEN (or ALFA_AI_API_TOKEN).
    """
    if not body.get("worker_name") and not body.get("hostname"):
        raise HTTPException(
            status_code=400,
            detail="worker_name or hostname is required",
        )
    store_worker_heartbeat(body)
    return {"ok": True}


@app.get("/api/admin/health")
def get_admin_health(_: None = Depends(require_brain_operator_health_auth)) -> dict[str, Any]:
    """
    Brain operator JSON: Redis heartbeats + brain service checks (not the www Admin Health page).

    The SPA at /alfa-ai/admin/health uses GET /alfa-ai/api/admin/health (admin router) instead.

    When ALFA_AI_REQUIRE_API_AUTH or ALFA_AI_LOCK_OPERATOR_HEALTH is set, requires
    Bearer ALFA_AI_API_TOKEN or an admin JWT (same secret/role as the web app).
    """
    workers = load_workers_from_redis()
    brain = build_brain_services_report()
    hosts = build_cluster_hosts_report()
    return {
        "status": "ok",
        "build_hash": _build_hash(),
        "workers": workers,
        "brain": brain,
        "hosts": hosts,
    }


@app.get("/admin/health")
def admin_health_dashboard() -> FileResponse:
    """Operator dashboard: worker + brain health (static UI). Data requires operator token when locked."""
    if not ADMIN_STATIC_DIR.is_dir():
        raise HTTPException(status_code=404, detail="Admin UI not installed")
    return FileResponse(ADMIN_STATIC_DIR / "health.html")


@app.get("/")
def ui_root() -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html")


@app.get("/ui")
def ui_page() -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html")


@app.post("/api/runs", response_model=CreateRunResponse)
def create_run(
    payload: CreateRunRequest,
    _: None = Depends(require_alfa_ai_api_token),
) -> CreateRunResponse:
    input_payload = [
        {"filename": item.filename, "content": item.content}
        for item in payload.input_files
    ]
    role_name = (payload.role or "").strip() or None
    try:
        run_id = orchestrator.create_run(
            goal=payload.goal,
            research_only=payload.research_only,
            skill=payload.skill,
            workflow=payload.workflow,
            role=role_name,
            input_files=input_payload or None,
            target_host=payload.target_host or None,
        )
    except RunInputError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        # Full exception (DB DSN fragments, SQL, paths) goes to the server log only;
        # the client gets a fixed message (org review 2026-09-25).
        logger.exception("create_run failed")
        raise HTTPException(
            status_code=500,
            detail=(
                "create_run failed; see API logs. "
                "If relation runs does not exist, run: bash scripts/ensure-runtime-schema.sh"
            ),
        ) from exc
    return CreateRunResponse(run_id=run_id)


@app.get("/api/runs")
def list_runs(_: None = Depends(require_alfa_ai_api_token)) -> list[dict[str, object]]:
    return [run_to_dict(run) for run in orchestrator.store.list_runs()]


@app.get("/api/runs/{run_id}")
def get_run(
    run_id: str,
    _: None = Depends(require_alfa_ai_api_token),
) -> dict[str, object]:
    run = orchestrator.store.get_run(run_id)
    if run is None:
        return {"ok": False, "error": "Run not found"}
    tasks = orchestrator.store.list_tasks_for_run(run_id)
    artifacts = orchestrator.store.list_artifacts_for_run(run_id)
    return {
        "ok": True,
        "run": run_to_dict(run),
        "tasks": [task_to_dict(task) for task in tasks],
        "artifacts": [artifact_to_dict(item) for item in artifacts],
    }


@app.post("/api/runs/process-next")
def process_next_task(_: None = Depends(require_alfa_ai_api_token)) -> dict[str, object]:
    from src.runtime.worker_host import worker_host_from_env

    result = orchestrator.process_next_task(worker_host=worker_host_from_env())
    if result is None:
        return {"ok": False, "message": "No task available"}
    return {"ok": True, "result": result}


@app.get("/api/runs/{run_id}/events")
async def stream_run_events(
    run_id: str,
    _: None = Depends(require_alfa_ai_api_token_sse),
) -> StreamingResponse:
    """SSE stream of mission tool/task events for operator UI."""

    async def generate() -> Any:
        offset = 0
        idle_ticks = 0
        max_idle = 240  # ~120s at 500ms when no new events
        while idle_ticks < max_idle:
            new_events, offset = mission_event_bus.get_since(run_id, offset)
            if new_events:
                idle_ticks = 0
                for event in new_events:
                    yield f"data: {json.dumps(event, ensure_ascii=True)}\n\n"
                    if event.get("type") == "task_done":
                        run = orchestrator.store.get_run(run_id)
                        if run and run.status in {"done", "failed"}:
                            yield f"data: {json.dumps({'type': 'run_complete', 'run_id': run_id, 'status': run.status}, ensure_ascii=True)}\n\n"
                            return
            else:
                idle_ticks += 1
            await asyncio.sleep(0.5)

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.get("/api/runs/{run_id}/artifacts")
def list_artifacts(
    run_id: str,
    _: None = Depends(require_alfa_ai_api_token),
) -> dict[str, object]:
    run = orchestrator.store.get_run(run_id)
    if run is None:
        return {"ok": False, "error": "Run not found"}
    artifacts = orchestrator.store.list_artifacts_for_run(run_id)
    return {"ok": True, "artifacts": [artifact_to_dict(item) for item in artifacts]}


@app.get("/api/runs/{run_id}/artifacts/{artifact_id}/content")
def get_artifact_content(
    run_id: str,
    artifact_id: str,
    _: None = Depends(require_alfa_ai_api_token),
) -> dict[str, object]:
    run = orchestrator.store.get_run(run_id)
    if run is None:
        return {"ok": False, "error": "Run not found"}
    artifacts = orchestrator.store.list_artifacts_for_run(run_id)
    match = next((item for item in artifacts if item.artifact_id == artifact_id), None)
    if match is None:
        return {"ok": False, "error": "Artifact not found"}
    base = workspace_root()
    path = (base / match.path).resolve()
    try:
        path.relative_to(base.resolve())
    except ValueError:
        return {"ok": False, "error": "Artifact path outside workspace"}
    if not path.is_file():
        return {"ok": False, "error": "Artifact file missing on disk"}
    try:
        content = path.read_text(encoding="utf-8")
    except OSError as exc:
        logger.warning("artifact read failed run=%s artifact=%s: %s", run_id, artifact_id, exc)
        return {"ok": False, "error": "Could not read artifact file"}
    return {
        "ok": True,
        "artifact_id": artifact_id,
        "path": match.path,
        "content": content,
    }


if OPERATOR_STATIC_DIR.is_dir():
    app.mount(
        "/operator",
        StaticFiles(directory=str(OPERATOR_STATIC_DIR), html=True),
        name="operator_console",
    )

if ADMIN_STATIC_DIR.is_dir():
    app.mount(
        "/admin/asset",
        StaticFiles(directory=str(ADMIN_STATIC_DIR)),
        name="admin_assets",
    )


def _register_alfa_ai_spa() -> None:
    """Serve Vite build at /alfa-ai/* when frontend/dist exists (production / www)."""
    dist = Path(__file__).resolve().parent.parent.parent / "frontend" / "dist"
    index = dist / "index.html"
    if not index.is_file():
        logger.info(
            "ALFa web SPA not mounted (%s missing). Run: cd frontend && npm run build",
            index,
        )
        return

    assets = dist / "assets"
    if assets.is_dir():
        app.mount(
            "/alfa-ai/assets",
            StaticFiles(directory=str(assets)),
            name="spa_assets",
        )

    @app.get("/alfa-ai", include_in_schema=False)
    def _alfa_ai_redirect() -> RedirectResponse:
        return RedirectResponse(url="/alfa-ai/", status_code=307)

    @app.get("/alfa-ai/", include_in_schema=False)
    def _alfa_ai_shell() -> FileResponse:
        return FileResponse(index, headers={"Cache-Control": "no-cache"})

    @app.get("/alfa-ai/{full_path:path}", include_in_schema=False)
    def _alfa_ai_spa_fallback(full_path: str) -> FileResponse:
        if ".." in full_path.split("/"):
            raise HTTPException(status_code=404, detail="Not found")
        candidate = (dist / full_path).resolve()
        dist_resolved = dist.resolve()
        try:
            candidate.relative_to(dist_resolved)
        except ValueError as exc:
            raise HTTPException(status_code=404, detail="Not found") from exc
        if candidate.is_file():
            return FileResponse(candidate)
        return FileResponse(index, headers={"Cache-Control": "no-cache"})


_register_alfa_ai_spa()


async def _mcp_admin_auth_middleware(request: Request, call_next) -> Response:
    """Require admin JWT + network allowlist for /mcp (not @mcp.custom_route)."""
    path = request.url.path
    if not path.startswith("/mcp"):
        return await call_next(request)

    from src.api.deps import decode_token, get_user_store

    auth_header = request.headers.get("authorization") or ""
    if not auth_header.lower().startswith("bearer "):
        return JSONResponse(status_code=401, content={"detail": "Not authenticated"})

    token = auth_header[7:].strip()
    try:
        payload = decode_token(token)
    except HTTPException as exc:
        return JSONResponse(status_code=exc.status_code, content={"detail": exc.detail})

    if payload.get("type") != "access":
        return JSONResponse(status_code=401, content={"detail": "Invalid token type"})

    if payload.get("role") != "admin":
        return JSONResponse(status_code=403, content={"detail": "Insufficient permissions"})

    user = get_user_store().get_by_id(payload["sub"])
    if user is None or not user.is_active:
        return JSONResponse(status_code=401, content={"detail": "User not found or deactivated"})

    try:
        assert_admin_client_allowed(request, role="admin", public_context="api")
    except HTTPException as exc:
        return JSONResponse(status_code=exc.status_code, content={"detail": exc.detail})

    return await call_next(request)


def _maybe_mount_mcp_inspect() -> None:
    """Mount Streamable HTTP MCP when ALFA_AI_MCP_ENABLED=1 (default off)."""
    global _mcp_inspect_server
    if not mcp_enabled():
        return
    try:
        from src.api.mcp_server import build_mcp_inspect_server

        _mcp_inspect_server, mcp_mount_app = build_mcp_inspect_server()
        app.mount("/mcp", mcp_mount_app)
        app.middleware("http")(_mcp_admin_auth_middleware)
        logger.info("MCP inspect mounted at /mcp (ALFA_AI_MCP_ENABLED=1)")
    except Exception:
        logger.exception("MCP inspect mount skipped (import or build failed)")


_maybe_mount_mcp_inspect()


def set_orchestrator_for_tests(new_orchestrator: RuntimeOrchestrator) -> None:
    global orchestrator
    orchestrator = new_orchestrator

