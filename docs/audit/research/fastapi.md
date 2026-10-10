# FastAPI

> Research-agent output for the ALFa AI architecture audit (2026-05-13).
> Read by `audit-agent` to check `/home/operator/alfa-ai/` against upstream guidance.

## Official documentation

- **Primary docs URL:** https://fastapi.tiangolo.com
- **Deployment concepts:** https://fastapi.tiangolo.com/deployment/concepts/
- **Server workers:** https://fastapi.tiangolo.com/deployment/server-workers/
- **Containers (Docker):** https://fastapi.tiangolo.com/deployment/docker/
- **HTTPS:** https://fastapi.tiangolo.com/deployment/https/
- **Source repo URL:** https://github.com/fastapi/fastapi
- **Release notes:** https://fastapi.tiangolo.com/release-notes/
- **Releases (GitHub):** https://github.com/fastapi/fastapi/releases
- **PyPI:** https://pypi.org/project/fastapi/

## Current stable / supported version (as of 2026-05-13)

- **Latest stable:** `0.136.1` (released 2026-04-23) — the release notes describe "Update Pydantic v2 code to address deprecations" and a Starlette bump to `1.0.0`. Source: https://pypi.org/project/fastapi/ and https://github.com/fastapi/fastapi/releases.
- **Previous:** `0.136.0` (2026-04-16) — adds support for free-threaded Python 3.14t. Source: https://github.com/fastapi/fastapi/releases.
- **Python requirement:** `>=3.10`. Source: https://pypi.org/project/fastapi/ (project metadata).
- **EOL policy:** FastAPI uses CalVer-ish 0.x release line; pre-1.0 means breaking changes are technically allowed in any release. Track via release notes. Source: https://fastapi.tiangolo.com/release-notes/.
- **Starlette:** `1.0.0` (the underlying ASGI framework) — pinned via `fastapi==0.136.1`. Source: https://github.com/fastapi/fastapi/releases (release `0.136.1` "Bump starlette from 0.52.1 to 1.0.0" PR #15397).

## Key official best practices

- **HTTPS via TLS-termination proxy:** FastAPI explicitly recommends a TLS-termination proxy (Traefik, Caddy, nginx, HAProxy, Kubernetes Ingress) in front of Uvicorn. Don't terminate TLS in Uvicorn directly. Source: https://fastapi.tiangolo.com/deployment/concepts/ ("Security - HTTPS").
- **Process management:** "the same tool used to run on startup is also used for restarts" — upstream recommends Docker, Kubernetes, Compose, Swarm, **systemd**, supervisord, or a cloud platform. Source: https://fastapi.tiangolo.com/deployment/concepts/ ("Restarts" / "Running on Startup").
- **Replication:** **Pick one and only one** of: (a) `uvicorn --workers N` (single container, multi-process), (b) Kubernetes/container orchestration replication (one process per container, N replicas). Don't combine — orchestration replication should run a single Uvicorn process per container, with `replicas: N`. Source: https://fastapi.tiangolo.com/deployment/server-workers/ and https://fastapi.tiangolo.com/deployment/docker/.
- **Worker count rule of thumb:** match worker count to available CPU cores. If running ML model inference *inside* the API process, factor in per-worker memory (loaded model × workers). Source: https://fastapi.tiangolo.com/deployment/concepts/ ("Memory per Process").
- **Single-process previous-steps job:** if there are migrations or one-time bootstrap steps, run them in a single sidecar/init container — not from every worker. Source: https://fastapi.tiangolo.com/deployment/concepts/ ("Previous Steps Before Starting").
- **Resource utilization target:** upstream recommends 50–90% CPU/RAM utilization as the operating band. Source: https://fastapi.tiangolo.com/deployment/concepts/ ("Resource Utilization").
- **Containerization pattern:** the canonical Dockerfile pattern from https://fastapi.tiangolo.com/deployment/docker/ uses a slim Python base, copies `requirements.txt`, installs, copies app, then `CMD ["fastapi", "run", "main.py", "--port", "80"]` (or `uvicorn main:app --host 0.0.0.0 --port 80 --proxy-headers`).
- **Proxy headers:** when behind nginx/Cloudflare, use `--proxy-headers` (or set `forwarded_allow_ips`) so `request.client.host` and scheme are correct. Source: https://www.starlette.io/middleware/ (Starlette ProxyHeadersMiddleware) and the FastAPI deployment guide cross-references.
- **Lifecycle events:** prefer the **lifespan** context manager (introduced as the supported replacement for `@app.on_event("startup")`/`shutdown`). Source: https://fastapi.tiangolo.com/advanced/events/.
- **OpenAPI / docs visibility:** by default `/docs`, `/redoc`, `/openapi.json` are public. To hide in production, pass `docs_url=None`, `redoc_url=None`, `openapi_url=None` to `FastAPI(...)`. Source: https://fastapi.tiangolo.com/how-to/configure-swagger-ui/.

## Canonical configuration examples

**Production Dockerfile** (verbatim shape from https://fastapi.tiangolo.com/deployment/docker/):

```dockerfile
FROM python:3.12-slim

WORKDIR /code

COPY ./requirements.txt /code/requirements.txt
RUN pip install --no-cache-dir --upgrade -r /code/requirements.txt

COPY ./app /code/app

CMD ["fastapi", "run", "app/main.py", "--port", "80"]
```

**Run with multiple workers** (single-container, multi-process — only when *not* under k8s/Compose `deploy.replicas`):

```bash
fastapi run --workers 4 main.py
# or
uvicorn main:app --host 0.0.0.0 --port 8000 --workers 4 --proxy-headers
```

Source: https://fastapi.tiangolo.com/deployment/server-workers/.

**Lifespan startup/shutdown** (canonical pattern):

```python
from contextlib import asynccontextmanager
from fastapi import FastAPI

@asynccontextmanager
async def lifespan(app: FastAPI):
    # startup
    yield
    # shutdown

app = FastAPI(lifespan=lifespan)
```

Source: https://fastapi.tiangolo.com/advanced/events/.

## Common pitfalls / gotchas

- **`--workers` × `replicas: N` double-counts memory.** If your app loads a 1 GB model into RAM and you run `--workers 4` inside each of 3 container replicas, you're consuming 12 GB. Pick one replication tier. Source: https://fastapi.tiangolo.com/deployment/concepts/ ("Memory per Process") and https://fastapi.tiangolo.com/deployment/docker/ ("Replication - Number of Processes").
- **Default bind is project-decision, but FastAPI examples use `0.0.0.0`.** Behind Docker, you must bind `0.0.0.0` inside the container or no traffic reaches the app. Source: https://fastapi.tiangolo.com/deployment/docker/.
- **`--proxy-headers` required behind nginx/CF** so `request.url.scheme` is `https` not `http`. Source: Starlette ProxyHeadersMiddleware docs.
- **Public Swagger/ReDoc on prod APIs** — disable explicitly with `docs_url=None` for non-public services. Source: https://fastapi.tiangolo.com/how-to/configure-swagger-ui/.
- **`@app.on_event` is legacy** in FastAPI 0.130+; use `lifespan=`. Source: https://fastapi.tiangolo.com/advanced/events/.
- **Pydantic v1 → v2 migration:** the `0.100+` release line is on Pydantic v2; v1 is unsupported in current FastAPI. Source: https://fastapi.tiangolo.com/release-notes/ and FastAPI 0.100.0 release notes.
- **Pre-1.0:** every minor release can break API. Pin `fastapi==0.136.1` (or whatever you've smoke-tested) — never `fastapi>=0.136`. Source: https://fastapi.tiangolo.com/release-notes/ (project is pre-1.0; semver is informal).

## Authoritative URLs to cite in our docs

- https://fastapi.tiangolo.com
- https://fastapi.tiangolo.com/deployment/concepts/
- https://fastapi.tiangolo.com/deployment/server-workers/
- https://fastapi.tiangolo.com/deployment/docker/
- https://fastapi.tiangolo.com/deployment/https/
- https://fastapi.tiangolo.com/advanced/events/
- https://fastapi.tiangolo.com/how-to/configure-swagger-ui/
- https://fastapi.tiangolo.com/release-notes/
- https://github.com/fastapi/fastapi
- https://pypi.org/project/fastapi/

## AUDIT CHECKLIST for the Audit Agent

1. **Version pin:** verify `alfa-ai-api`'s `requirements.txt` (or `pyproject.toml`) pins a specific `fastapi` version that matches an upstream release tag. Flag `fastapi>=...`/unpinned. Repo path: `src/api/requirements.txt` and `Dockerfile`.
2. **Python version:** confirm Python `>=3.10` in the Dockerfile base image (`python:3.12-slim` or similar) and uvicorn pin compatibility.
3. **Worker count vs replicas:** the brain stack runs on `hub` (and a copy on `apps`). Verify `deploy/docker-compose.yml` either uses `--workers N` OR `deploy.replicas: N`, not both. Cross-check the `command:` for `alfa-ai-api`.
4. **`--proxy-headers`:** since `alfa-ai-api` sits behind nginx (`alfa-ai-nginx`) which sits behind Cloudflare Tunnel, confirm Uvicorn is launched with `--proxy-headers` (or `forwarded_allow_ips=*`). Otherwise `request.url.scheme` will be wrong and TLS-only middleware will fail.
5. **Lifespan vs `on_event`:** grep `src/api/` for `@app.on_event(` — if any exist, they're legacy and should be migrated to a `lifespan` context manager.
6. **Swagger exposure:** `alfa-ai-api` is reachable from the public internet via Cloudflare Tunnel (per architecture). Confirm `docs_url`/`redoc_url`/`openapi_url` are set to non-default values OR disabled in production. If exposed, document why.
7. **Startup ordering:** confirm any one-time setup (DB schema bootstrap, model warmup, Postgres connection check) happens in `lifespan` startup, NOT at module-import time (which would block worker forks).
8. **Bind address:** verify Uvicorn `--host 0.0.0.0` inside the container; the host port mapping should be the LAN-bound `127.0.0.1:8420:8000` form per the workspace's `port-assignment-rules.mdc`.
9. **Memory budget:** if `alfa-ai-api` loads model state in-process (e.g. embedding model, tokenizer), document the per-worker memory cost. Cross-reference `apps`/`hub` host memory budgets in `NODE_INVENTORY.md`.
10. **Pydantic v2 migration completion:** confirm no `pydantic<2` pin remains (`requirements.txt`); confirm no `*Config` v1-style classes remain in models that haven't been migrated to `model_config = ConfigDict(...)`.
11. **CORS:** if the React/Vite SPA on `apps` calls `alfa-ai-api` at a different origin (e.g. `chat.alfaqd.com` → `api.alfaqd.com`), confirm `CORSMiddleware` is configured with explicit origins (not `allow_origins=["*"]`). Path: `src/api/main.py`.
12. **Health endpoints:** verify `/healthz` (or equivalent) exists and is referenced by nginx upstream health checks and Cloudflare Tunnel ingress.
