# Container rebuild strategy (fast iteration, slim images)

The cluster's three slowest images were rewritten so a normal commit only
rebuilds a thin app layer (~5-30s) instead of reinstalling ML wheels or
apt chromium packages. The shared base layers live on the `hub` registry
mirror and are cached once per cluster.

## alfa-petals-ml-base (cpu + cuda)

- Dockerfile: [deploy/petals/Dockerfile.ml-base](../deploy/petals/Dockerfile.ml-base)
- Contents: torch 2.2.2 (forced after install), **Petals from GitHub** (`PETALS_GIT_REF`,
  default `main`) so **transformers 4.43.x** matches Llama 3.3 configs; hivemind
  from git per upstream `setup.cfg`; grpcio-tools; fastapi/uvicorn/pydantic; hf
  stack per Petals pins (not the old PyPI `petals==2.2.0.post1` / `transformers<4.35`).
- **hub / NFS wheel hub:** LAN hosts must mount **`/mnt/cluster`**
  ([scripts/mount_nfs_models.sh](../scripts/mount_nfs_models.sh)) before
  **`sync-petals-wheels-from-hub.sh`**. Dirs `deploy/petals/build-contexts/wheels-{cpu,cuda}/`
  feed `PIP_FIND_LINKS` during build (see [CLUSTER_SHARED_STORAGE.md](CLUSTER_SHARED_STORAGE.md)
  §2–3). Empty dirs on a mounted hub mean seed wheels on hub; empty dirs
  off-hub fall back to public PyPI (avoid on cluster members).
- Two tags published: `alfa-petals-ml-base:cpu` and `alfa-petals-ml-base:cuda`.
- Built via `docker buildx bake ml-base` (bake file:
  [deploy/cluster/docker-bake.hcl](../deploy/cluster/docker-bake.hcl)).

Downstream images:
- `alfa-ai-petals-gateway` -> [deploy/Dockerfile.petals-gateway](../deploy/Dockerfile.petals-gateway)
  `FROM alfa-petals-ml-base:cpu`
- `alfa-petals-worker-gpu` -> [deploy/petals/Dockerfile.petals-worker.gpu](../deploy/petals/Dockerfile.petals-worker.gpu)
  `FROM alfa-petals-ml-base:cuda`

Result: a gateway code change no longer reinstalls torch/hivemind/petals.

## alfa-ai-api + alfa-ai-frontend split

- Dockerfile.api still builds fine as-is. A new optional compose file,
  [deploy/docker-compose.frontend-split.yml](../deploy/docker-compose.frontend-split.yml),
  adds an `alfa-ai-frontend` service that uses
  [deploy/Dockerfile.frontend](../deploy/Dockerfile.frontend) (Vite build on
  `node:20-bookworm-slim` -> `nginx:1.29.8-alpine`).
- Enable:
  ```bash
  docker compose -f docker-compose.yml -f docker-compose.frontend-split.yml up -d --build
  ```
- After enabling, update `alfa-ai-nginx` conf so `/alfa-ai/*` upstream is
  `alfa-ai-frontend:80` and `/api/*` stays on `alfa-ai-api:8000`.

Result: frontend-only changes rebuild ~20 MB in ~10s without touching the
Python image.

## rankings-bot base

- Base: [rankings-bot/Dockerfile.base](../../rankings-bot/Dockerfile.base)
  (apt chromium + docker CLI + pip wheels).
- App: [rankings-bot/Dockerfile](../../rankings-bot/Dockerfile) now
  `FROM rankings-bot-base:${BASE_TAG}` and only copies app dirs.
- The rankings-bot `docker-compose.yml` / `production/docker-compose.prod.yml`
  continues to build `rankings-bot:local`; the base image is built once via
  bake and cached on hub.

Result: API / celery-worker code changes rebuild in ~5s instead of
reinstalling chromium and the wheel set every time.

## atems scoped COPY + .dockerignore

- Old: `COPY . .` pulled 1 GB of markdown, local `.db`, logs, and `vatems/`
  virtualenv into the build context.
- New: [atems/Dockerfile](../../atems/Dockerfile) copies only `atems.py`,
  `extensions.py`, `forms.py`, `routes.py`, `gunicorn.conf.py`, and the
  needed package dirs (`models/`, `utils/`, `scripts/`, `templates/`,
  `static/`, `migrations/`).
- [atems/.dockerignore](../../atems/.dockerignore) strips `*.md`, `*.db`,
  `*.log`, `venv/`, `vatems/`, `tests/`, `selftest/`, `frontend/` from the
  context so `docker build` starts in <1s.

## Rebuild cadence cheat sheet

| Layer | Rebuild trigger | Who runs it |
|-------|-----------------|-------------|
| `alfa-petals-ml-base:{cpu,cuda}` | requirements bump / base Dockerfile change | nightly bake job on apps |
| `rankings-bot-base` | `requirements-*.txt` change | nightly bake job on apps |
| `alfa-ai-frontend` | `frontend/**` change | frontend devs / auto on commit |
| `alfa-ai-api` | `src/**` or `requirements.txt` change | brain deploy on apps |
| `rankings-bot` | `api/`, `scrapers/`, etc. | rankings deploy on apps |
| `atems` | one of the scoped `COPY` sources | atems deploy on apps |

## Failure isolation

If a base rebuild fails (pinned torch drops, protobuf mismatch, etc.), the
thin app images keep running with the previous base tag pulled from the
`hub` mirror. Promote a new base by retagging in the registry, then
redeploy the downstream images.
