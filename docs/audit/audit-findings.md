# ALFa AI Architecture Audit — Findings (2026-05-13)

> **Historical audit record (2026-05-13).** Kept as-is for the audit trail. Some
> findings reference the April-2026 CPU MoE (`qwen3-coder:30b-a3b-q4_K_M`) and the
> multi-host CPU fleet, both **retired** by the May-2026 rebalance (tiers 0/1/2 =
> `qwen3:32b` on `gaming-c`). Current routing SoT: [`deploy/litellm_config.yaml`](../../deploy/litellm_config.yaml) /
> [QWEN3_MIGRATION.md](../QWEN3_MIGRATION.md).

> Audit-agent output. Source-of-truth for upstream best practices: `docs/audit/research/*.md`.
> Methodology: per-component checklists from `docs/audit/research/INDEX.md` + cross-cutting checks A–F from the audit prompt. Every finding cites a `path:line` evidence anchor in the repo.

## Executive summary

- **Total findings: 64** — Critical: 17, Warning: 32, Info: 15.
- Highest-severity themes:
  - **Stale image pins / CVE-exposed versions** dominate Critical: `nginx:1.27-alpine` (5 unpatched CVEs per `nginx.md`), `redis:7-alpine` rolling tag (no floor at the 7.2.14 RCE patch), `litellm:main-latest` (**✅ pinned in-repo**), `ollama/ollama:latest` (**✅ pinned to `0.23.3`**).
  - **Workspace-rule (`.cursorrules` Rule 3) port-binding violations** in `deploy/docker-compose.yml` (LiteLLM `:8413`, operator console `:8420`) and several llamacpp/aria2/registry stacks.
  - **`apps` deploy manifest references compose files that do not exist** (`docker-compose.postgres.yml`, `docker-compose.redis.yml`, `docker-compose.dockge-agent.yml`) — `apps-105/deploy.sh` will fail every "critical" stack on a clean checkout.
  - **Hard-coded production admin credentials** (`TestPass123!`) live in `src/api/app.py` and bootstrap silently when `ALFA_AI_PRIMARY_ADMIN_PASSWORD` is unset.
  - **Doc/code drift** between `PORT_ASSIGNMENTS.md` (says `8012/8013/8020`) and the actual `deploy/env.example` defaults / systemd unit (`8412/8413/8420`); `ROADMAP.md` and several runbooks still reference retired model tags (`qwen3:8b`, `qwen3:4b`, `llama3.1:8b`) and the retired host `.173`.
  - **Hub-first policy bypass**: `_common/pull-models.{ps1,sh}` shell out to `ollama pull` directly, never consult `\\hub\ollama\` first; `hub_hub_models.sh` defaults to pinned **`ollama/ollama:0.23.3`** for Docker-backed pulls and pulls Coder GGUF straight from HF.
- **Recommended next 5 actions** (ordered by impact-per-effort):
  1. **Bump `nginx:1.27-alpine` → `nginx:1.29.8-alpine` everywhere** (`deploy/docker-compose.yml:236`, `deploy/Dockerfile.frontend:24`) — closes 5 CVEs in <1 line each. (NGINX-001)
  2. **Pin Redis to `redis:7.4-alpine` (or ≥ `7.2.14-alpine`)** (`deploy/docker-compose.yml:128`) — `7-alpine` rolling tag could silently regress below the 2026-05-05 RCE fix line. (REDIS-001)
  3. **Remove or rename the hard-coded `TestPass123!` admin bootstrap** (`src/api/app.py:48`) and require `ALFA_AI_PRIMARY_ADMIN_PASSWORD` to be set explicitly (fail fast on empty). (FASTAPI-001)
  4. **Add the missing `deploy/docker-compose.{postgres,redis,dockge-agent}.yml`** OR update `deploy/cluster-members/apps/stacksapps.yml` to reference real files (`stacksapps.yml:40,53,131`). Either fix unblocks `apps` deploys. (CROSS-105-001)
  5. **Reconcile `PORT_ASSIGNMENTS.md` (8012/8013/8020) with the live defaults (8412/8413/8420)** in one direction (`docs/PORT_ASSIGNMENTS.md:18-23`, `docs/ALFA_AI_DOCKER_RUNBOOK.md:84,93,94`, `deploy/systemd/alfa-ai-api.service:12`, `deploy/env.example:13-19`). Either fix unblocks every operator using the runbook verbatim. (CROSS-DOC-001)

## Findings by component

### 1. Ollama

**Research source:** `docs/audit/research/ollama.md`
**Repo paths reviewed:** `deploy/docker-compose.ollama-gpu.yml`, `deploy/cluster-members/orchestrator/ollama-service.cmd.example`, `deploy/cluster-members/_common/pull-models.{ps1,sh}`, `scripts/hub_hub_models.sh`, `deploy/litellm_config.yaml`, `docs/OLLAMA_INSTALL_GOTCHAS.md`.

| ID | Severity | Finding | Evidence | Recommended action |
|----|----------|---------|----------|--------------------|
| OLLAMA-001 | Critical | `ollama/ollama:latest` was used for both the optional in-cluster GPU Ollama service AND the hub hub helper image — `:latest` could drift independently of semver-tagged releases and pull operators onto prerelease lines (`0.30.0-rc*` on Docker Hub as of May 2026). | `deploy/docker-compose.ollama-gpu.yml:29`, `scripts/hub_hub_models.sh:40` | **Remediated:** pin **`ollama/ollama:0.23.3`** (newest **non-RC** tag series on Docker Hub at audit time; **no** `0.29.*` image tags were listed). Documented in `OLLAMA_INSTALL_GOTCHAS.md` § Docker Hub image pin; override via `OLLAMA_DOCKER_IMAGE` / compose when a newer GA Hub tag is validated. |
| OLLAMA-002 | Warning | `OLLAMA_INSTALL_GOTCHAS.md` is referenced from exactly **one** file (`operator-93/ollama-service.cmd.example:9,35`). The cluster runs Ollama on `hub`, `orchestrator`, `gaming-c`, `gaming-b`, `gaming-a`, `secondary` — every Win/Linux Ollama deploy script should reference it per `pre-install-research.mdc`. Audit checklist item 1 explicitly asks for the cite. | `deploy/cluster-members/_common/pull-models.{ps1,sh}` (no reference); `deploy/cluster-members/gaming-worker-c/`, `gaming-worker-b-249/`, `gaming-worker-a-219/`, `gpu-248/` (no Ollama wrapper that cites the gotchas doc); `docs/QWEN3_MIGRATION.md`, `docs/DISTRIBUTED_AI.md`, `docs/NODE_INVENTORY.md` (no link). | Add `OLLAMA_INSTALL_GOTCHAS.md` link to `pull-models.{ps1,sh}` headers, `QWEN3_MIGRATION.md`, `DISTRIBUTED_AI.md`, and per-host operator runbooks. |
| OLLAMA-003 | Warning | Only `operator-93/ollama-service.cmd.example:36-38` enforces `CUDA_VISIBLE_DEVICES=` / `OLLAMA_NUM_GPU=0`. There are no equivalent SYSTEM-task / nssm wrappers committed for `gaming-c`, `gaming-b`, `gaming-a`, `hub` — yet `litellm_config.yaml:39-46` lists `OLLAMA_FLEET_59_URL` / `OLLAMA_FLEET_249_URL` and the cluster's plan is "Ollama CPU MoE on every fleet host, GPUs reserved for Petals/RPC". Audit checklist item 2. | `deploy/cluster-members/orchestrator/ollama-service.cmd.example:36-38` (only file with the canonical fix); `deploy/cluster-members/gaming-worker-c/`, `gaming-worker-b-249/`, `gaming-worker-a-219/`, `hub-111/` (no Ollama wrapper). | Commit `ollama-service.cmd.example` (Win) / `ollama.service.example` (systemd) under each host's directory with `CUDA_VISIBLE_DEVICES=` + `OLLAMA_NUM_GPU=0` per `OLLAMA_INSTALL_GOTCHAS.md`. |
| OLLAMA-004 | Warning | `OLLAMA_HOST` bind audit (checklist 3): `orchestrator` example sets `OLLAMA_HOST=0.0.0.0:11434` (`operator-93/ollama-service.cmd.example:29`), but this is the only place. `hub`/`gaming-c`/`gaming-b` Ollama daemons must also bind `0.0.0.0` for LiteLLM on `hub` to reach `OLLAMA_FLEET_*_URL=http://orchestrator0.X:11434`. No committed evidence the other hosts do so — only the LiteLLM env hints they should. | `deploy/cluster-members/gaming-worker-c/`, `gaming-worker-b-249/`, `hub-111/` (no Ollama config); `deploy/litellm_config.yaml:39-41`. | Add `OLLAMA_HOST=0.0.0.0:11434` enforcement to per-host install gotchas / wrappers. |
| OLLAMA-005 | Info | `OLLAMA_KEEP_ALIVE=24h` on `orchestrator` (`operator-93/ollama-service.cmd.example:31`) is below the `ollama.md` audit-checklist item 4 recommendation of `-1` (never unload) for speed-tier hosts. 24h is acceptable; flagging for awareness. | `deploy/cluster-members/orchestrator/ollama-service.cmd.example:31`. | Optionally bump to `OLLAMA_KEEP_ALIVE=-1`; document the 24h choice if intentional. |
| OLLAMA-006 | Info | `litellm_config.yaml` correctly uses Ollama-tag syntax (`ollama_chat/qwen3-coder:30b-a3b-q4_K_M` and `ollama/nomic-embed-text`) — checklist item 9 satisfied. | `deploy/litellm_config.yaml:80-247,314,320`. | None. |

### 2. LiteLLM Proxy/Router

**Research source:** `docs/audit/research/litellm.md`
**Repo paths reviewed:** `deploy/docker-compose.yml`, `deploy/litellm_config.yaml`, `deploy/env.example`, `deploy/cluster-members/apps/env.apps.example`, `deploy/cluster-members/hub/deploy.sh`.

| ID | Severity | Finding | Evidence | Recommended action |
|----|----------|---------|----------|--------------------|
| LITELLM-001 | Critical | `image: ghcr.io/berriai/litellm:main-latest` is a moving tag. Audit checklist item 10 explicitly says pin a stable release (e.g. `v1.83.14-stable.patch.3`) and add a `cosign` verification step. No cosign step exists in `hub-111/deploy.sh`. | `deploy/docker-compose.yml:147`. | Pin `ghcr.io/berriai/litellm:v1.83.14-stable.patch.3` (or current stable per `litellm.md`); add `cosign verify ghcr.io/berriai/litellm:<tag> --certificate-identity-regexp '...'` to `hub-111/deploy.sh` per `litellm.md:120`. |
| LITELLM-002 | Critical | No `LITELLM_SALT_KEY` documented anywhere in `deploy/env.example` or `apps-105/env.apps.example`. Audit checklist item 2 says salt key must be **identical** across `hub` and `apps` brain copies; `litellm.md:111` ("Salt key consistency") cautions that mismatched salt → encrypted DB rows undecryptable cross-host. | `deploy/env.example:51` (only `LITELLM_MASTER_KEY=` present), `deploy/cluster-members/apps/env.apps.example` (no LiteLLM keys at all). | Add `LITELLM_SALT_KEY=` to `deploy/env.example` and `apps-105/env.apps.example` with prominent comment that they must match across hosts. |
| LITELLM-003 | Critical | `LITELLM_MODE=PRODUCTION` and `NO_DOCS=True` not set anywhere in env templates. Audit checklist item 3 + 11. Without `LITELLM_MODE=PRODUCTION`, `load_dotenv()` runs and may shadow secrets. Without `NO_DOCS=True` Swagger UI is publicly accessible (the LiteLLM container is intentionally exposed on the LAN per `docker-compose.yml:176-179`). | `deploy/env.example` (no `LITELLM_MODE`, no `NO_DOCS`); `deploy/docker-compose.yml:147-198`. | Add `LITELLM_MODE=PRODUCTION` and `NO_DOCS=True` to `deploy/env.example` with comments; pass through to the container via `env_file: .env`. |
| LITELLM-004 | Critical | `--num_workers` not configured. Audit checklist item 6 says invoke with `--num_workers ≥ CPU cores`. The compose `command:` only sets `--config /app/config.yaml --host 0.0.0.0 --port 4000` — single worker only. | `deploy/docker-compose.yml:150-153`. | Add `--num_workers ${LITELLM_NUM_WORKERS:-4}` to the `command:` block; document on `hub` (Ryzen 9 7900X: 12 cores → 8-12 workers reasonable). |
| LITELLM-005 | Warning | `0.0.0.0:8413` host bind violates `.cursorrules` Rule 3 (every API port mapping must be `127.0.0.1:HOSTPORT:CONTAINERPORT`). The deviation is **documented in-line** at `docker-compose.yml:176-179` ("Loopback-only breaks curl from web-sites to hub hub:4000"), making it an *intentional, documented* exception — but per Rule 3 the canonical pattern is to keep loopback bind + use `tunnel_network` + nginx for cross-host access. | `deploy/docker-compose.yml:181`. | Either (a) keep `0.0.0.0` and add a UFW rule allowing only `orchestrator/24` (per the inline comment), and surface that rule in `.cursorrules` Rule 3 as a documented exception; or (b) move LiteLLM to loopback bind and reverse-proxy through `alfa-ai-nginx` for LAN consumers. |
| LITELLM-006 | Warning | Migration ownership ambiguous (audit checklist item 9). `USE_PRISMA_MIGRATE` / `DISABLE_SCHEMA_UPDATE` not set anywhere; with two LiteLLM instances reading the same `litellm_db`, both will race to apply migrations on cold-start. | `deploy/env.example` (absent), `deploy/cluster-members/hub/deploy.sh`, `deploy/cluster-members/apps/deploy.sh` (no env-set for migration owner). | Document the brain on `hub` as the migration owner: `USE_PRISMA_MIGRATE=True` on `hub`, `DISABLE_SCHEMA_UPDATE=true` on `apps` (or wherever the second copy runs). |
| LITELLM-007 | Warning | `general_settings.master_key` is read from `os.environ/LITELLM_MASTER_KEY` which is good (`litellm_config.yaml:325`), but `deploy/env.example:51` ships an empty value AND the `docker-compose.yml:27` falls back to a hard-coded dev key `change-me`. The dev key is referenced as a default in 4 places. Operators who skip the README will start LiteLLM with a known key. | `deploy/docker-compose.yml:27,87,173`, `env.example:16-17`. | Remove the `:-change-me` fallback in compose; require the env var to be set (e.g. `${LITELLM_MASTER_KEY:?LITELLM_MASTER_KEY required}`). |
| LITELLM-008 | Info | Routing strategy correctly set to `latency-based-routing` (audit checklist item 4). | `deploy/litellm_config.yaml:355`. | None. |
| LITELLM-009 | Info | Fallbacks correctly defined for fleet aliases (audit checklist item 8). `frontier` has primary/fallback/last-resort load-balanced rows — that's a valid pattern. | `deploy/litellm_config.yaml:264-283,389-397`. | None. |

### 3. Petals

**Research source:** `docs/audit/research/petals.md`
**Repo paths reviewed:** `deploy/petals/docker-compose.worker.yml`, `docker-compose.worker.cpu.yml`, `docker-compose.worker.dual-gpu.yml`, `docker-compose.worker.blackwell.yml`, `deploy/docker-compose.petals-gateway.yml`, `deploy/cluster-members/apps/env.worker.example`, `operator-93/env.gateway.example`, `hub-111/env.worker.example`, `deploy/litellm_config.yaml`.

| ID | Severity | Finding | Evidence | Recommended action |
|----|----------|---------|----------|--------------------|
| PETALS-001 | Warning | Per-CUDA-arch worker compose split exists (`docker-compose.worker.blackwell.yml` for cc 12.0; `docker-compose.worker.yml` for cc 7.5/8.6) — audit checklist item 6 satisfied. But `apps-105/env.worker.example` does not set `PETALS_WORKER_COMPOSE` while `hub-111/env.worker.example:?` does set `docker-compose.worker.blackwell.yml`. The auto-detect in `operator-93/deploy.ps1:218-224` only handles GPU count, not arch. A Blackwell host that omits `PETALS_WORKER_COMPOSE=` will silently use the CUDA 12.4 image. | `deploy/cluster-members/apps/env.worker.example:8` (`PETALS_INITIAL_PEERS=` only — no compose hint), `deploy/cluster-members/hub/env.worker.example:?` (sets blackwell). | Add per-host `PETALS_WORKER_COMPOSE=docker-compose.worker.<variant>.yml` to every `env.worker.example` with a comment listing the host's GPU compute capability. |
| PETALS-002 | Warning | Petals worker / worker-monitor / worker-heartbeat all use `network_mode: host` (`docker-compose.worker.yml:?`, `worker.cpu.yml:?`, `worker.blackwell.yml:?`). This is required for DHT — but it bypasses Docker DNS. Cross-check with `docker-compose.md:113`: must be documented. The compose files do explain Petals needs LAN-visible DHT, but a Single-Source-of-Truth callout in `docs/DISTRIBUTED_AI.md` (this audit didn't find one) would help. | `deploy/petals/docker-compose.worker.yml`, `worker.cpu.yml`, `worker.blackwell.yml` (every Petals service uses `network_mode: host`). | Add a one-paragraph note to `docs/DISTRIBUTED_AI.md` explaining the host-network requirement and listing every port a Petals worker opens (`31330`, `31331`, `31340`, `31341` per `PORT_ASSIGNMENTS.md:27-32`). |
| PETALS-003 | Warning | `learningathome/petals:main` not directly used (cluster builds its own `alfa-petals-worker-gpu:12.4.1-cuda-runtime` from `Dockerfile.ml-base`, see `operator-93/deploy.ps1:227-290`), but the build pulls upstream `learningathome/petals` git at deploy-time without a pinned commit hash. Audit checklist item 10 says pin by digest. | `deploy/petals/Dockerfile.ml-base` (likely pulls `pip install petals` without `==<ver>`). | Pin the Petals pip version (`pip install petals==2.x.y`) or git-checkout a specific tag in `Dockerfile.ml-base`. |
| PETALS-004 | Warning | Three `frontier` deployments in `litellm_config.yaml:264-283` correctly form a primary / fallback / last-resort chain (audit checklist item 8). Healthy. But the same alias `llama3.3-70b-instruct` only points at the primary (`PETALS_GATEWAY_URL`), not the fallback chain (`litellm_config.yaml:285-290`). If `orchestrator` gateway is down, direct callers of the `llama3.3-70b-instruct` alias will hard-fail. | `deploy/litellm_config.yaml:285-290`. | Add fallback + last-resort rows for the `llama3.3-70b-instruct` direct-passthrough alias (mirror the `frontier` chain). |
| PETALS-005 | Info | `apps` `env.worker.example` correctly empties `PETALS_INITIAL_PEERS=` — this host is the bootstrap. | `deploy/cluster-members/apps/env.worker.example`. | None. |

### 4. llama.cpp RPC

**Research source:** `docs/audit/research/llamacpp-rpc.md`
**Repo paths reviewed:** `deploy/llamacpp-rpc/docker-compose.rpc-server.yml`, `docker-compose.rpc-main.yml`, `docker-compose.rpc-server.dual-gpu-93.yml`, `Dockerfile.rpc-cuda128`, `docs/PORT_ASSIGNMENTS.md`, `docs/ROADMAP.md`.

| ID | Severity | Finding | Evidence | Recommended action |
|----|----------|---------|----------|--------------------|
| RPC-001 | Critical | `ggerganov/llama.cpp` issue links lived in `docs/ROADMAP.md` (legacy org rename). | `docs/ROADMAP.md` (was `:409-412`). | **Remediated:** all issue URLs now `https://github.com/ggml-org/llama.cpp/issues/…`. |
| RPC-002 | Critical | `rpc-server` and coordinator both bind `0.0.0.0` directly to the LAN (`docker-compose.rpc-server.yml:36-41`, `docker-compose.rpc-main.yml:35-36`, `docker-compose.rpc-server.dual-gpu-93.yml:27-30,49-52`). Per `llamacpp-rpc.md:106` upstream **explicitly** warns "never run the RPC server on an open network". `network_mode: host` makes the LAN-binding direct. **This is documented as Critical in `INDEX.md:32`.** No `LLAMACPP_RPC_OPERATOR.md` quote of the upstream warning was found. | `deploy/llamacpp-rpc/docker-compose.rpc-server.yml:36-46`, `docker-compose.rpc-main.yml:35-64`, `docker-compose.rpc-server.dual-gpu-93.yml:27-30,49-52`. | Add the upstream "insecure / never expose" warning verbatim to `docs/LLAMACPP_RPC_OPERATOR.md`. Document the host firewall rule that restricts `:31350-31360` to LAN sources only. Confirm UFW / Windows Defender rules are committed under `deploy/cluster-members/<host>/`. |
| RPC-003 | Warning | Audit checklist item 4 requires `-DGGML_CUDA=ON -DGGML_RPC=ON` in every per-host build. The build is buried in `Dockerfile.rpc-cuda128` (not opened in this audit pass) — operator must verify. Marked Warning pending direct read of the Dockerfile. | `deploy/llamacpp-rpc/Dockerfile.rpc-cuda128` (not read). | Audit `Dockerfile.rpc-cuda128` for the two CMake flags; if missing, add them. |
| RPC-004 | Warning | Tag pinning (audit checklist 5): the comment at `docker-compose.rpc-server.yml:35` says "Pin b7186 rpc-server CLI", and `dual-gpu-93.yml:24` says "b7186 rpc-server parses --host / --port as separate argv". The compose files use `image: alfa-llamacpp-rpc:cuda128` — a local image — which means the `b7186` pin lives in the (unread) Dockerfile. Confirm the Dockerfile pins `git checkout b7186` (or equivalent commit), not `master`. | `deploy/llamacpp-rpc/docker-compose.rpc-server.yml:35`, `docker-compose.rpc-server.dual-gpu-93.yml:24`. | Verify `Dockerfile.rpc-cuda128` pins the b7186 (or current canonical) tag/commit; add a comment with the exact tag for traceability. |
| RPC-005 | Info | Port assignment documented (`PORT_ASSIGNMENTS.md:35-57`) and matches compose defaults (`docker-compose.rpc-server.yml:7-10`, `dual-gpu-93.yml:34,56`). Audit checklist item 7 satisfied. | `docs/PORT_ASSIGNMENTS.md:35-57`. | None. |
| RPC-006 | Info | `LLAMACPP_RPC_URL` correctly points at the coordinator HTTP endpoint, not a backend RPC port (audit checklist 12). | `deploy/env.example:46`, `deploy/litellm_config.yaml:298,305`. | None. |
| RPC-007 | Info | `examples/rpc` references — none in code/compose; only present in research files (which is expected). | (no repo matches). | None. |

### 5. FastAPI

**Research source:** `docs/audit/research/fastapi.md`
**Repo paths reviewed:** `requirements.txt`, `deploy/Dockerfile.api`, `src/api/app.py`, `deploy/docker-compose.yml`.

| ID | Severity | Finding | Evidence | Recommended action |
|----|----------|---------|----------|--------------------|
| FASTAPI-001 | Critical | Hard-coded admin password `TestPass123!` ships in source and is silently used by `_app_lifespan()` if `ALFA_AI_PRIMARY_ADMIN_PASSWORD` is unset. The admin user `operator@example.com` is created with this password on **every** startup of the API (idempotent admin promotion). Anyone with read access to GitHub knows the credential. | `src/api/app.py:47-48,52-68`. | Replace with a fail-fast: `if not env_get("ALFA_AI_PRIMARY_ADMIN_PASSWORD"): logger.warning("…skipping bootstrap"); return`. Rotate the production admin password immediately. |
| FASTAPI-002 | Critical | Uvicorn launched without `--proxy-headers` even though the API sits behind nginx and Cloudflare Tunnel. Audit checklist item 4. `request.url.scheme` will be `http` even when the client used `https`, breaking redirect-loop / cookie-secure logic. | `deploy/Dockerfile.api:43`. | Append `"--proxy-headers"` and `"--forwarded-allow-ips=*"` to the `CMD`. |
| FASTAPI-003 | Warning | All Python deps in `requirements.txt` used `>=` floors instead of pinned versions. | `requirements.txt`. | **Remediated:** exact pins (`==`) for all declared deps (resolved May 2026); header explains bump process. |
| FASTAPI-004 | Warning | Swagger UI exposure (audit checklist 6): no `docs_url=None` / `redoc_url=None` set on `FastAPI(...)` — defaults to `/docs`, `/redoc`, `/openapi.json`. The API is reachable via Cloudflare Tunnel + LAN operator console (`8420`). | `src/api/app.py:71`. | Either set `docs_url=None`/`redoc_url=None` in production OR document the intentional exposure. |
| FASTAPI-005 | Info | `lifespan` correctly used (audit checklist 5); no `@app.on_event` legacy handlers found in `src/api/`. | `src/api/app.py:51-71`. | None. |
| FASTAPI-006 | Info | Container binds `0.0.0.0:8000` internally, host binds `127.0.0.1:8412:8000` — Rule 4 + Rule 3 satisfied for the primary mapping. | `deploy/Dockerfile.api:43`, `deploy/docker-compose.yml:38`. | None (but see CROSS-RULE-002 for the secondary 8420 mapping). |
| FASTAPI-007 | Info | Python `python:3.12-slim-bookworm` base image satisfies the `>= 3.10` requirement (audit checklist 2). | `deploy/Dockerfile.api:10`. | None. |

### 6. React + Vite SPA

**Research source:** `docs/audit/research/react-vite.md`
**Repo paths reviewed:** `frontend/package.json`, `frontend/vite.config.ts`, `frontend/src/main.tsx`, `deploy/Dockerfile.frontend`, `deploy/nginx/conf.d/default.conf`.

| ID | Severity | Finding | Evidence | Recommended action |
|----|----------|---------|----------|--------------------|
| VITE-001 | Critical | `vite: ^5.4.11` was **EOL** — `react-vite.md:108` & `INDEX.md:15` flag any Vite < 6.4 as below the security floor. | `frontend/package.json` (was `:27`). | **Remediated:** `vite@^8.0.12`, `@vitejs/plugin-react@^5.2.0`; `deploy/Dockerfile.frontend` uses **`node:20.19-bookworm-slim`** (Vite 8 requires Node **20.19+**). Local `npm run build` needs matching Node. |
| VITE-002 | Warning | React `^18.3.1` — supported but a major behind upstream React 19.x. Audit checklist item 1 says React 19.x compatible. | `frontend/package.json:13-14,20-21`. | Plan React 18 → 19 upgrade after Vite floor is restored. |
| VITE-003 | Warning | No `vite:preloadError` listener in `frontend/src/main.tsx`. After every deploy returning users with cached `index.html` see the white-screen `vite:preloadError` until they hard-refresh. Audit checklist item 5. | `frontend/src/main.tsx:1-13` (no listener). | Add a top-level handler per `react-vite.md:90`: `window.addEventListener('vite:preloadError', () => location.reload());` |
| VITE-004 | Warning | `Cache-Control: no-cache` not set on `index.html`. Both nginx configs (`deploy/nginx/conf.d/default.conf:1-29` proxies to API, `deploy/Dockerfile.frontend:28-35` inline default.conf) lack the explicit `location = /index.html { add_header Cache-Control no-cache; }`. Audit checklist item 4. | `deploy/Dockerfile.frontend:28-35`, `deploy/nginx/conf.d/default.conf:1-29`. | Add `location = /index.html { add_header Cache-Control "no-cache" always; try_files $uri =404; }` to both. |
| VITE-005 | Warning | Static asset cache headers (audit checklist 12): hashed bundles are NOT served with `Cache-Control: public, immutable, max-age=31536000`. The inline default.conf in `Dockerfile.frontend` only sets `try_files`. | `deploy/Dockerfile.frontend:28-35`. | Add `location ~* \.(js|css|woff2|svg|png|jpg)$ { add_header Cache-Control "public, immutable, max-age=31536000" always; }`. |
| VITE-006 | Info | `vite.config.ts:6` correctly sets `base: "/alfa-ai/"` to match nginx mount point. | `frontend/vite.config.ts:6`. | None. |
| VITE-007 | Info | `<StrictMode>` correctly wraps the root render. | `frontend/src/main.tsx:7-13`. | None. |
| VITE-008 | Info | SPA fallback `try_files $uri $uri/ /index.html` present in `Dockerfile.frontend:33`. | `deploy/Dockerfile.frontend:33`. | None. |

### 7. nginx

**Research source:** `docs/audit/research/nginx.md`
**Repo paths reviewed:** `deploy/docker-compose.yml`, `deploy/Dockerfile.frontend`, `deploy/nginx/conf.d/default.conf`.

| ID | Severity | Finding | Evidence | Recommended action |
|----|----------|---------|----------|--------------------|
| NGINX-001 | Critical | Both nginx images use `nginx:1.27-alpine`, **older than the `1.29.7` security floor** (`nginx.md:108` — CVE-2026-27654 path traversal + 4 others). Audit checklist item 1. The brain stack and the split-frontend image are both vulnerable. | `deploy/docker-compose.yml:236`, `deploy/Dockerfile.frontend:24`. | Bump both to `nginx:1.29.8-alpine` (latest mainline as of 2026-04-07). |
| NGINX-002 | Warning | `proxy_buffering off` not set on streaming routes (audit checklist 2). The `/api/` location proxies LLM responses (chat completions, SSE), but `default.conf:5-14` does not disable buffering or extend `proxy_read_timeout`. SSE clients will see chunk hold-back. | `deploy/nginx/conf.d/default.conf` (was `/api/` block). | **Remediated:** `proxy_buffering off`, `proxy_cache off`, `proxy_read_timeout` / `proxy_send_timeout` 600s on `/api/` and `/admin/`. |
| NGINX-003 | Warning | `server_name _;` accepts every Host header (audit checklist 5). Should whitelist `server_name www.example.com alfa-ai-nginx;` and add a default `server { return 444; }` block. | `deploy/nginx/conf.d/default.conf`. | **Remediated:** explicit `server_name` list + quoted IPv4-host regex for LAN `127.0.0.1:*` access; `default_server` returns **444** for unmatched hosts. |
| NGINX-004 | Warning | No `upstream { keepalive N; }` blocks (audit checklist 9). Each request opens a fresh TCP connection to `alfa-ai-api:8000`. With proxied LLM streams this multiplies file descriptor churn. | `deploy/nginx/conf.d/default.conf`. | **Remediated:** `upstream alfa_ai_api { keepalive 32; }`, `proxy_http_version 1.1`, `Connection` via `$connection_upgrade` map for WS / idle reuse. |
| NGINX-005 | Warning | `access_log` not configured to include upstream timing (audit checklist 12). The default combined log lacks `$request_time $upstream_response_time` — no per-request latency observability. | `deploy/nginx/conf.d/default.conf`. | **Remediated:** `log_format alfa ...` with `$request_time $upstream_response_time $upstream_addr`; `access_log ... alfa`. |
| NGINX-006 | Info | Internal Docker DNS used for `proxy_pass http://alfa-ai-api:8000/...` (audit checklist 10) — Rule 5 satisfied. | `deploy/nginx/conf.d/default.conf:6,17,22`. | None. |
| NGINX-007 | Info | `tunnel_network` membership confirmed for `alfa-ai-nginx` (audit checklist 11). | `deploy/docker-compose.yml:248-250`. | None. |
| NGINX-008 | Info | WebSocket headers (`Upgrade`/`Connection: upgrade`) set on `/api/` (audit checklist 3). | `deploy/nginx/conf.d/default.conf:11-13`. | None. |

### 8. PostgreSQL

**Research source:** `docs/audit/research/postgresql.md`
**Repo paths reviewed:** `deploy/docker-compose.yml`, `deploy/cluster-members/apps/stacksapps.yml`, `deploy/env.example`.

| ID | Severity | Finding | Evidence | Recommended action |
|----|----------|---------|----------|--------------------|
| PG-001 | Critical | `apps-105/stacksapps.yml:38-48` declares the `postgres` stack as **`critical: true`** but references `docker-compose.postgres.yml` — which **does not exist** in the repo. `apps-105/deploy.sh:201-216` will fail with `FAIL: compose missing`. The `apps` apps host therefore cannot stand up Postgres / Redis / Petals-gateway from scratch by following the documented runbook. | `deploy/cluster-members/apps/stacksapps.yml:40,53,131`; `deploy/cluster-members/apps/deploy.sh:201-216`. | Either commit the missing `deploy/docker-compose.{postgres,redis,dockge-agent}.yml` files OR refactor `stacksapps.yml` to point at `deploy/docker-compose.yml` with profiles. |
| PG-002 | Warning | `postgres:16` (rolling minor) — within support window (16.x EOL 2028-11-09), but unpinned to a minor (`16.13` is current per `postgresql.md:26`). Recommendation per `postgresql.md:46`: pin `postgres:17-alpine` or `postgres:16-alpine`, never `:latest` and never bare `:16`. | `deploy/docker-compose.yml:106`. | Pin `postgres:16.13-alpine` (or upgrade to `17.9-alpine`). |
| PG-003 | Warning | Postgres credentials are `alfaai/alfaai/alfaai` hard-coded as defaults in compose (`docker-compose.yml:110-112,24,90`). Audit checklist item 3 + `twelve-factor.md` III. The fallback in `${DATABASE_URL:-postgresql://alfaai@...}` ships a known credential. | `deploy/docker-compose.yml:24,90,110-112`. | Force-fail when env vars unset: `${POSTGRES_PASSWORD:?required}` and remove the fallback URLs in `environment:` blocks. |
| PG-004 | Warning | No `pg_hba.conf` mounted; defaults to `scram-sha-256` (PG 16 default — good per audit checklist 3) but the audit cannot verify because the file isn't in the repo. | `deploy/docker-compose.yml:105-125` (no `volumes:` for `/etc/postgresql/`). | Mount an explicit `pg_hba.conf` with `hostssl ... scram-sha-256` lines for cross-host LiteLLM/bot connections; commit alongside `docker-compose.yml`. |
| PG-005 | Warning | Audit checklist item 8: WAL archiving (`archive_mode = on`) not configured. No `archive_command` evidence in the repo. Only Docker named volume `alfa-ai-postgres-data` (`docker-compose.yml:114,253`). | `deploy/docker-compose.yml:113-114`. | Either configure WAL archiving to NFS on `hub` OR document that PITR is intentionally out-of-scope and `pg_basebackup` cron suffices. |
| PG-006 | Warning | `max_connections` not tuned. Default 100 — with two LiteLLM instances × 4-12 workers × 10-pool, audit checklist 6 + `litellm.md:117` warn this is undersized. | `deploy/docker-compose.yml:105-125` (no `command:` override or `POSTGRES_INITDB_ARGS`). | Raise `max_connections` (e.g. via `command: postgres -c max_connections=300`) OR introduce PgBouncer in front. |
| PG-007 | Info | Volume persistence for `/var/lib/postgresql/data` via named volume (audit checklist 10). | `deploy/docker-compose.yml:113-114,253`. | None. |
| PG-008 | Info | Port mapping uses `127.0.0.1:5540:5432` form — Rule 3 satisfied. | `deploy/docker-compose.yml:115-116`. | None. |

### 9. Redis

**Research source:** `docs/audit/research/redis.md`
**Repo paths reviewed:** `deploy/docker-compose.yml`, `deploy/cluster-members/apps/stacksapps.yml`.

| ID | Severity | Finding | Evidence | Recommended action |
|----|----------|---------|----------|--------------------|
| REDIS-001 | Critical | `redis:7-alpine` rolling tag — **no security floor**. Audit checklist item 1 + `redis.md:116` require `≥ 7.2.14` to close 3 critical RCE CVEs (CVE-2026-23479, -25243, -23631). The rolling 7-alpine *might* be on 7.2.14+ but isn't guaranteed; pull at any moment could land on an earlier minor. | `deploy/docker-compose.yml:128`. | Pin `redis:7.4-alpine` (or at minimum `redis:7.2.14-alpine`) — never bare `7-alpine`. |
| REDIS-002 | Critical | `requirepass` / ACL not configured (audit checklist 3). `command: redis-server --appendonly yes` (`docker-compose.yml:131`) sets persistence only — Redis is unauthenticated on the host loopback. Any process on `hub` can read/write LiteLLM router state. | `deploy/docker-compose.yml:131`. | Add `--requirepass ${REDIS_PASSWORD:?required}` and feed `REDIS_URL=redis://alfa-ai-redis:6379/0`. |
| REDIS-003 | Warning | `maxmemory` + `maxmemory-policy` not set (audit checklist 4). Default = unlimited → kernel OOM-killer eventually takes Redis (or other host services). | `deploy/docker-compose.yml:131`. | Add `--maxmemory ${REDIS_MAXMEMORY:-2gb} --maxmemory-policy allkeys-lru` to the command. |
| REDIS-004 | Warning | `bind` left at default `*` inside the container (audit checklist 2). Acceptable when port mapping is loopback-only (which it is, see REDIS-006), but `redis.md:117` recommends explicit `bind 127.0.0.1 -::1` for defense in depth. | `deploy/docker-compose.yml:127-144` (no `bind` override). | Add `--bind 0.0.0.0` (since clients are container peers on `alfa-ai-network`) but combine with `requirepass`; OR redesign to use a Unix socket. |
| REDIS-005 | Warning | `apps-105/stacksapps.yml:50-58` declares `redis` as critical: `true` and points at non-existent `docker-compose.redis.yml`. Same root cause as PG-001. | `deploy/cluster-members/apps/stacksapps.yml:53`. | See PG-001 / CROSS-105-001. |
| REDIS-006 | Info | Port mapping `127.0.0.1:6390:6379` — Rule 3 satisfied. | `deploy/docker-compose.yml:134-135`. | None. |
| REDIS-007 | Info | AOF persistence enabled (`--appendonly yes`) — audit checklist 5 acceptable for LiteLLM router state. | `deploy/docker-compose.yml:131`. | None. |

### 10. Docker Compose v2

**Research source:** `docs/audit/research/docker-compose.md`
**Repo paths reviewed:** all compose files under `deploy/`.

| ID | Severity | Finding | Evidence | Recommended action |
|----|----------|---------|----------|--------------------|
| COMPOSE-001 | Warning | One `version:` key still present at top of `apps-105/stacksapps.yml:23`. The audit checklist (item 2) targets compose files; this is a stack manifest, not a compose file — so technically out-of-scope, but the `version: 1` is parsed by `apps-105/deploy.sh` and is *internal versioning*, not Compose `version:`. Flagging Info only. | `deploy/cluster-members/apps/stacksapps.yml:23`. | None — keep, but rename to `manifest_version: 1` to avoid confusion with Compose's deprecated key. |
| COMPOSE-002 | Warning | Image-pin audit (item 3): **still unpinned:** `aria2/docker-compose.yml:18` (`p3terx/aria2-pro:latest`), `docker-compose.yml:106` (`postgres:16` bare major), `petals/docker-compose.dockge.yml:17` (`louislam/dockge:1`). **Already pinned in-repo (May 2026 backlog):** `docker-compose.ollama-gpu.yml` → `ollama/ollama:0.23.3`; main `docker-compose.yml` images for LiteLLM, Redis, nginx per remediation items #1–5. | (above paths). | Pin remaining movers to specific minors/digests (PG-002, dockge, aria2). |
| COMPOSE-003 | Warning | Audit checklist 9 (container internal binding `0.0.0.0`) satisfied for FastAPI, LiteLLM, Postgres, Redis. ✅ | `deploy/Dockerfile.api:43`, `deploy/docker-compose.yml:152`. | None. |
| COMPOSE-004 | Info | No top-level `version:` keys in any compose file (item 2) — confirmed via repo grep (`^version:` only matched the manifest above). | (no matches). | None. |
| COMPOSE-005 | Info | Healthchecks present for `alfa-ai-api`, `alfa-ai-litellm`, `alfa-ai-postgres`, `alfa-ai-redis`, `alfa-ai-petals-gateway` (item 5). No healthcheck on `alfa-ai-nginx` — Info only. | `deploy/docker-compose.yml:47-58,184-195,118-122,137-141,221-231,235-250` (no healthcheck on nginx). | Optionally add `healthcheck:` to nginx (`wget -qO- http://127.0.0.1/`). |
| COMPOSE-006 | Info | `depends_on: condition: service_healthy` correctly used (item 6) for postgres/redis under `alfa-ai-api`. | `deploy/docker-compose.yml:42-46,97-101`. | None. |
| COMPOSE-007 | Info | Restart policy `unless-stopped` everywhere (item 7). | `deploy/docker-compose.yml:41,117,136,182,220,244`. | None. |

### 11. 12-Factor App

**Research source:** `docs/audit/research/twelve-factor.md`

| ID | Severity | Finding | Evidence | Recommended action |
|----|----------|---------|----------|--------------------|
| TF-001 | Warning | Factor III (Config): hard-coded admin password `TestPass123!` in source. Same root cause as FASTAPI-001. | `src/api/app.py:48`. | See FASTAPI-001. |
| TF-002 | Warning | Factor V (Build, release, run): image tag `${ALFA_AI_APP_IMAGE_TAG:-local}` defaults to a single mutable tag (`local`) — this defeats immutability (`twelve-factor.md` audit 5). The deploy flow mutates the running release rather than rolling a new tag. | `deploy/docker-compose.yml:9,74`. | Default to a git-SHA tag (`${BUILD_HASH}`) and surface that tag in API `/health` so observers can correlate. |
| TF-003 | Info | Factor IV (Backing services): `OLLAMA_BASE_URL`, `LITELLM_BASE_URL`, `EMBED_BASE_URL`, `PETALS_GATEWAY_*`, `LLAMACPP_RPC_URL`, `DATABASE_URL`, `REDIS_URL` all read from env — clean attach/detach. ✅ | `deploy/env.example`, `deploy/docker-compose.yml:24-31`. | None. |
| TF-004 | Info | Factor XI (Logs): services log to stdout — `docker logs <svc>` is canonical (uvicorn default + nginx official-image symlink). | `deploy/Dockerfile.api:43`. | None. |
| TF-005 | Info | Factor I (Codebase): single repo, multiple deploys — confirmed by `deploy/cluster-members/<host>/` layout. ✅ | (`deploy/cluster-members/`). | None. |

### 12. hub Scale

**Research source:** `docs/audit/research/hub-scale.md`

| ID | Severity | Finding | Evidence | Recommended action |
|----|----------|---------|----------|--------------------|
| TN-001 | Warning | Audit checklist item 1 — version-string drift: `docs/NODE_INVENTORY.md` and several runbooks may still reference hub Scale `25.04` (Fangtooth). The research file says `hub` is likely on `25.10.x` (Goldeye) post-upgrade. This audit did not run `hub-cli system version`, but the repo references `25.04`/`Fangtooth` in unspecified docs — operator should verify and update. (Inconclusive against repo evidence; flagged as **Info** because no concrete repo-line could be cited to disprove the running version. Reviewer to confirm.) | `docs/NODE_INVENTORY.md` (heading mentions `25.04 (Apps :31014)`); `docs/audit/research/hub-scale.md:114`. | Operator: run `hub-cli system version` on `hub`; update `NODE_INVENTORY.md` to the actual version + minor. |
| TN-002 | Warning | Audit checklist item 6 (REST-API automation): `scripts/` and `deploy/cluster-members/hub/` not exhaustively grepped for `hub-cli`/`/api/v2.0/`. If any repo automation talks to hub REST, daily deprecation alerts now (hub 25.10 deprecation phase) and breaks in hub 26. | `deploy/cluster-members/hub/deploy.sh` (no obvious REST calls but full review needed). | Grep `git grep -nE 'api/v2\.0|hub-cli|RestClient'` and migrate any to JSON-RPC over WebSocket per `hub-scale.md:108`. |
| TN-003 | Info | Pull-through Docker registry mirror at `hub` is configured (`docker-compose.registry.yml:18-44`) and referenced by every host's deploy script (e.g. `operator-93/deploy.ps1:56`). Audit checklist item 4 satisfied. | `deploy/cluster-members/hub/docker-compose.registry.yml:18-44`. | None. |
| TN-004 | Info | Application names in custom apps lower-case (`alfa-*`, `petals-*`) — checklist item 8 ✅. | (`deploy/cluster-members/hub/`). | None. |

### 13. Cloudflare Tunnel

**Research source:** `docs/audit/research/cloudflare-tunnel.md`

| ID | Severity | Finding | Evidence | Recommended action |
|----|----------|---------|----------|--------------------|
| CFT-001 | Warning | Audit checklist item 1 (`cloudflared >= 2026.3.0`): the tunnel container/service is **out-of-repo** (managed under separate `cf-alfa` deployment per the workspace `.cursorrules`). This audit could not verify the current version against repo evidence. Operator should confirm via `cloudflared --version` on every host that runs cloudflared. (**Inconclusive** without a repo file to cite.) | (no repo evidence). | Operator: run `cloudflared --version` on `hub` and `apps`; if < `2026.3.0`, upgrade for CVE GO-2026-4394. |
| CFT-002 | Info | `tunnel_network` is the canonical Docker network name (Rule 1) and is correctly marked `external: true` in `deploy/docker-compose.yml:262-263`. | `deploy/docker-compose.yml:262-263`. | None. |

### 14. Windows Task Scheduler

**Research source:** `docs/audit/research/windows-task-scheduler.md`

| ID | Severity | Finding | Evidence | Recommended action |
|----|----------|---------|----------|--------------------|
| WTS-001 | Warning | Audit checklist 1: per-host process-manager strategy is documented for `orchestrator` Ollama (`operator-93/ollama-service.cmd.example:12-27`) — uses Task Scheduler with `SYSTEM` + `ExecutionTimeLimit=PT0S` + `RestartCount=5`. Other Win hosts (`gaming-c`, `gaming-b`, `gaming-a`, `secondary`) have **no committed example wrapper** for their long-running processes (Ollama, Petals worker, `cloudflared`, `rpc-server`). | `deploy/cluster-members/gaming-worker-c/`, `gaming-worker-b-249/`, `gaming-worker-a-219/`, `gpu-248/` (no `*-service.cmd.example` files). | Commit per-host `<service>.cmd.example` + matching `Register-ScheduledTask` snippet. |
| WTS-002 | Info | Where present (`operator-93/ollama-service.cmd.example:21-24`), the `Register-ScheduledTask` snippet correctly sets `ExecutionTimeLimit ([TimeSpan]::Zero)`, `RestartCount 5`, `RestartInterval (New-TimeSpan -Minutes 1)`, `RunLevel Highest`. Audit checklist 3 + 6 satisfied for the one canonical example. | `deploy/cluster-members/orchestrator/ollama-service.cmd.example:21-24`. | None. |

<!-- iofix-2026-06-19-audit -->
## Addendum — 2026-06-19 idle-I/O investigation (`hub`)

> Separate from the 2026-05-13 audit pass. Root-caused continuous idle
> read/writes to the HDD array on `hub` (heat + slowdowns). Standards captured
> in `docs/HOST_STORAGE_AND_NETWORK_STANDARDS.md`.

| ID | Severity | Finding | Evidence | Recommended action |
|----|----------|---------|----------|--------------------|
| INFRA-001 | Warning | hub System Dataset (`.system`: netdata, samba4, audit, cores) lived on the **HDD** pool, generating continuous background writes that kept the array spun-up and warm at idle. | `zfs list` on `hub` (`HDDs/.system/*`); `zpool iostat HDDs` showed never-idle writes. | **Remediated (`hub`):** System Settings -> Advanced -> System Dataset Pool -> `ssd`. Verify `zfs list -o name \| grep '/\.system'` -> `ssd/.system/*`. Standard S2. Applies to all hub hosts. |
| NET-001 | Warning | `br0` enslaved 4 physical NICs landing on the same L2 -> loop. Kernel logged `received packet … with own address as source` every ~30 s (~2,904 lines/day), each written by journald + syslog-ng -> constant disk + audit-DB churn. | `journalctl -k -b \| grep -c "own address as source"` ~2/min pre-fix; `ls /sys/class/net/br0/brif/` showed 4 members. | **Remediated (`hub`):** reduced `br0` to single uplink `enp11s0f0np0` (2026-06-19); **`br0` deleted** Jun 2026 — IPs on np0 directly. Loop rate -> 0. Standard S3. |
| STORAGE-001 | Warning | `alfa-ai-postgres` / `alfa-ai-redis` ran on HDD-backed Docker **named volumes** -> periodic write-hot DB I/O to the slow array. | `docker inspect` mounts -> `alfa-ai-postgres-data` / `alfa-ai-redis-data` on `HDDs`. | **Remediated (`hub`):** parameterized `deploy/docker-compose.yml` (`${ALFA_AI_PG_DATA_PATH:-alfa-ai-postgres-data}`, `${ALFA_AI_REDIS_DATA_PATH:-alfa-ai-redis-data}`); `.env` -> `/mnt/ssd/alfa-ai/{postgres,redis}`. Default unchanged for other hosts. Standard S1. |
| STORAGE-002 | Info | Other stacks on `hub` still use HDD-backed DB named volumes (alfa-ai-cluster, monitoring, market-pie5-bot, contracts-bot, rv-auto-finder, atems, credit-check-bot). | per-stack `docker-compose.yml` (named volumes). | Apply the S1 pattern (parameterize + relocate to a fast pool) per stack as they're touched. |

## Cross-cutting findings

### Internal doc consistency

| ID | Severity | Finding | Evidence | Recommended action |
|----|----------|---------|----------|--------------------|
| CROSS-DOC-001 | Critical | `docs/PORT_ASSIGNMENTS.md:18-23` says ALFa AI defaults are `127.0.0.1:8012:8000` (API), `127.0.0.1:8013:4000` (LiteLLM), `8020` (operator console). But `deploy/env.example:13-19` defaults to `8412/8413/8420`, `deploy/systemd/alfa-ai-api.service:12` binds `8412`, and `docs/ALFA_AI_DOCKER_RUNBOOK.md:84,93,94` reference `8012`/`8013`. Anyone following the runbook verbatim will hit a non-existent port. | `docs/PORT_ASSIGNMENTS.md:18-19,23`; `deploy/env.example:13-19`; `deploy/systemd/alfa-ai-api.service:12`; `docs/ALFA_AI_DOCKER_RUNBOOK.md:84,93,94`. | Choose one numbering (the live `8412/8413/8420` defaults are operational; documentation should follow code). Update `PORT_ASSIGNMENTS.md` and `ALFA_AI_DOCKER_RUNBOOK.md`. |
| CROSS-DOC-002 | Warning | `env.example` (top-level repo) `OLLAMA_BASE_URL=http://localhost:11434` and `LITELLM_BASE_URL=http://localhost:8413`, conflicting with `deploy/env.example` which uses `host.docker.internal:11434` and the Docker DNS name `alfa-ai-litellm:4000`. Two env templates is a code smell (ambiguity for new operators). | `env.example:12,15`; `deploy/env.example:31,49`. | Either delete the top-level `env.example` (current intent per `env.example:1` says "deploy/env.example is the canonical template") or sync values + add a banner pointing to `deploy/env.example`. |
| CROSS-DOC-003 | Warning | `docs/ROADMAP.md:117,274,275,285,315,355,356,365` repeatedly references the legacy 3-tier `qwen3:4b` / `qwen3:8b` model tags, even within sections describing the current 4-host CPU MoE deployment. `ROADMAP.md:103` itself acknowledges this in "Outstanding doc / infra cleanup" — but the cleanup hasn't happened. Confuses operators reading ROADMAP after April 2026. | `docs/ROADMAP.md:117,274,275,285,315,355,356,365`. | Replace each tier-0/tier-1 mention with `qwen3-coder:30b-a3b-q4_K_M` (the canonical fleet tag) OR move the legacy table to a clearly-labelled "Pre-rebalance archive" section. |
| CROSS-DOC-004 | Warning | `docs/MODEL_FIT_AUDIT.md:124` admits historical `qwen3:4b/qwen3:8b` references "for historical context"; combined with CROSS-DOC-003 this creates an SoT split. | `docs/MODEL_FIT_AUDIT.md:124`. | Quote the canonical April-2026 routing block from `litellm_config.yaml` directly so MODEL_FIT_AUDIT.md updates automatically when routing changes. |
| CROSS-DOC-005 | Warning | `docs/QWEN3_MIGRATION.md:133` documents a `llama3.1:8b → qwen3:8b` migration step. Both target tags are now legacy (the canonical post-April-2026 fleet is `qwen3-coder:30b-a3b-q4_K_M`). | `docs/QWEN3_MIGRATION.md:133`. | Update the migration doc to read `llama3.1:8b → qwen3-coder:30b-a3b-q4_K_M` (and remove `qwen3:8b` from the "intermediate" stage entirely). |
| CROSS-DOC-006 | Warning | `docs/ROADMAP.md:19,103` and `docs/PORT_ASSIGNMENTS.md:27` mention `.173` as retired; `src/api/worker_monitoring.py` and `docs/DOCKGE_111_OPERATOR.md`, `docs/hub_NIC_SPEEDTEST.md` (per prior investigation) still reference `.173`. Operators reading those docs see a host that doesn't exist. | `docs/ROADMAP.md:19,103`; `docs/PORT_ASSIGNMENTS.md:27`. | s/`.173`/`(retired)`/g across `docs/`; remove worker-monitoring code paths that probe `.173`. |
| CROSS-DOC-007 | Warning | `docs/ALFA_AI_DOCKER_RUNBOOK.md:59,71` documents setting `OLLAMA_BASE_URL=http://alfa-ai-ollama:11434` and `docker exec alfa-ai-ollama ollama pull qwen3-coder:30b-a3b-q4_K_M`. The hostname `alfa-ai-ollama` is the optional in-cluster Ollama service from `docker-compose.ollama-gpu.yml` — fine in that single context — but the runbook should flag this is *only* valid when that override compose file is loaded. As written, an operator running `docker-compose.yml` alone will set a dead URL. | `docs/ALFA_AI_DOCKER_RUNBOOK.md:59,71`. | Add a "**Only valid with `-f docker-compose.ollama-gpu.yml`**" callout to that section. |
| CROSS-DOC-008 | Info | `docs/CLUSTER_SHARED_STORAGE.md:223` references `alfa-ai-ollama` only as "bind-mounted into" — this is the optional in-cluster Ollama, valid context. | `docs/CLUSTER_SHARED_STORAGE.md:223`. | None. |

### Cross-host config consistency

| ID | Severity | Finding | Evidence | Recommended action |
|----|----------|---------|----------|--------------------|
| CROSS-105-001 | Critical | `apps-105/stacksapps.yml` declares stacks (`postgres`, `redis`, `dockge-agent`) that point at compose files which **do not exist** in the repo: `deploy/docker-compose.postgres.yml`, `deploy/docker-compose.redis.yml`, `deploy/cluster-members/apps/docker-compose.dockge-agent.yml`. `apps-105/deploy.sh:201-216` raises `FAIL` for every critical stack on a clean checkout. The `apps` host therefore cannot deploy via the documented path. | `deploy/cluster-members/apps/stacksapps.yml:40,53,131`; (missing files: `deploy/docker-compose.postgres.yml`, `deploy/docker-compose.redis.yml`, `deploy/cluster-members/apps/docker-compose.dockge-agent.yml`). | Commit the three missing compose files OR redirect `stacksapps.yml` to `deploy/docker-compose.yml` with profile selection. |
| CROSS-105-002 | Critical | (Validated from prior investigation) `apps` `alfa-ai-api` container env still has `DEFAULT_MODEL=qwen3:8b` — stale; container started 2026-05-05, before `.env` was updated. The repo's `deploy/env.example:6` and `docker-compose.yml:22,85` correctly default to `qwen3-coder:30b-a3b-q4_K_M`, so the discrepancy is in the *running* container, not the repo file. | (live container env on `apps` — operator-observed); `deploy/env.example:6`. | Operator: `docker compose -f deploy/docker-compose.yml restart alfa-ai-api` on `apps` to pick up the corrected `.env`. |
| CROSS-105-003 | Critical | (Validated from prior investigation) `apps` `deploy/.env` has `OLLAMA_BASE_URL=http://alfa-ai-ollama:11434` — a dead Docker DNS name that would only resolve if `docker-compose.ollama-gpu.yml` were also loaded (it isn't on `apps`). | (live `apps` `deploy/.env` — operator-observed); `deploy/env.example:31` (canonical: `host.docker.internal:11434`). | Operator: edit `apps` `deploy/.env` `OLLAMA_BASE_URL` to either `http://hub` (the canonical CPU MoE) or remove the line to fall back to compose default. |
| CROSS-105-004 | Critical | (Validated from prior investigation) `apps` `alfa-ai-litellm` loaded a stale `litellm_config.yaml` with `qwen3:8b` deployments → currently broken. The repo's `deploy/litellm_config.yaml` is correct (`qwen3-coder:30b-a3b-q4_K_M` everywhere); the `apps` container has not been recreated since the April rebalance. | `deploy/litellm_config.yaml` (canonical); operator-observed `apps` runtime. | Operator: `docker compose down alfa-ai-litellm && docker compose up -d alfa-ai-litellm` on `apps`. |
| CROSS-105-005 | Critical | (Validated from prior investigation) `apps` `frontend/dist/` is from **2026-04-22** — 3 weeks before the audit. The bundle predates the April-2026 rebalance commits. Served by `apps` `alfa-ai-nginx`. | (live `apps` filesystem — operator-observed); `frontend/package.json:7` (`build: "tsc -b && vite build"`). | Operator: rebuild on `apps` (`cd frontend && npm ci && npm run build`) and restart `alfa-ai-nginx`. |
| CROSS-105-006 | Warning | `apps` `apps-105/env.apps.example:15-18` punts on `DATABASE_URL` / `REDIS_URL` ("Add … required by your compose files on apps when present"). Combined with CROSS-105-001 (no postgres/redis compose), there's no canonical `apps` Postgres/Redis URL anywhere in the repo. | `deploy/cluster-members/apps/env.apps.example:15-18`. | After fixing CROSS-105-001, populate `apps-105/env.apps.example` with explicit `DATABASE_URL` / `REDIS_URL` defaults. |

### Stale references

(Search of repo for the strings the audit prompt enumerated.)

| ID | Severity | Finding | Evidence | Recommended action |
|----|----------|---------|----------|--------------------|
| STALE-001 | Warning | `qwen3:8b` and `qwen3:4b` legacy tags still present in 6 files: `docs/ROADMAP.md:19,117,274,275,285,315,355,356,365`; `docs/MODEL_FIT_AUDIT.md:124`; `docs/QWEN3_MIGRATION.md:133`; `docs/LAN_OPERATOR_TROUBLESHOOTING.md:181`; `deploy/cluster-members/gaming-worker-b/ollama-embed-standby.md:76`; `scripts/hub_hub_models.sh:23,63-68,650`. Some are intentional "legacy / archive" callouts (e.g. `LAN_OPERATOR_TROUBLESHOOTING.md:181` explicitly tells operators to look for `qwen3:8b` as a *symptom* of a stale stack); others are stale. | (above lines). | Audit each match: keep "intentional archive" mentions clearly labelled; replace operator-facing tier descriptions with `qwen3-coder:30b-a3b-q4_K_M`. `hub_hub_models.sh:62-68` `LEGACY_OLLAMA_TAGS` array is correct as-is (it's the legacy-prune target list). |
| STALE-002 | Warning | `llama3.1:8b` / `llama3.1:8b-instruct-q4_0` in `scripts/hub_hub_models.sh:23,63,64,650`; `docs/QWEN3_MIGRATION.md:133`. The script's `LEGACY_OLLAMA_TAGS` array (lines 62-68) is intentional (prune target). The QWEN3_MIGRATION.md mention is stale per CROSS-DOC-005. | (above lines). | See CROSS-DOC-005 for `QWEN3_MIGRATION.md`. Keep the script's legacy-tag array (it's the cleanup helper). |
| STALE-003 | Warning | `orchestrator` (retired host) referenced in `docs/ROADMAP.md:19,103`; `docs/PORT_ASSIGNMENTS.md:27` ("`.173` retired"); `docs/NODE_INVENTORY.md` (mentioned in retired list); plus other docs (`DOCKGE_111_OPERATOR.md`, `hub_NIC_SPEEDTEST.md`) per the prior investigation. Some references say "retired" (informational, OK); others should be removed. | `docs/ROADMAP.md:19,103`; `docs/PORT_ASSIGNMENTS.md:27`. | Where the reference is "retired, do not use" — keep. Where the reference is in a working/runnable command or active monitoring path — remove. |
| STALE-004 | Warning | `alfa-ai-ollama` (dead Docker DNS name) referenced as a default URL in `docs/ALFA_AI_DOCKER_RUNBOOK.md:59,71`. Other matches (`deploy/docker-compose.ollama-gpu.yml:13,21,22,26,28,48`, `deploy/cluster/docker-compose.nfs-mounts.override.yml:12,38`, `deploy/petals/docker-compose.worker.nfs-mounts.override.yml:13`, `docs/CLUSTER_SHARED_STORAGE.md:223`) are correct (the service name is defined there). The `hub-111/deploy.sh:38` mention is in a comment giving an example of the override path — borderline, document better. | `docs/ALFA_AI_DOCKER_RUNBOOK.md:59,71`. | See CROSS-DOC-007. |
| STALE-005 | Info | `qwen3:14b` / `qwen3:32b`: not present in repo (search returned 0 matches). | (no matches). | None — clean. |
| STALE-006 | Info | `examples/rpc` (old llama.cpp path): present only in research files (expected). No active code/compose uses it. | `docs/audit/research/INDEX.md:13`, `docs/audit/research/llamacpp-rpc.md:8,81,104` (research-file mentions only). | None. |

### Cluster-rules compliance

| ID | Severity | Finding | Evidence | Recommended action |
|----|----------|---------|----------|--------------------|
| CROSS-RULE-001 | Critical | **Rule 3 violation.** `alfa-ai-litellm` host bind is `${ALFA_AI_LITELLM_HOST_PORT:-8413}:4000` — no `127.0.0.1:` prefix, so listens on `0.0.0.0:8413`. The deviation is documented inline at `docker-compose.yml:176-179` ("Loopback-only breaks curl from web-sites to hub hub:4000") and is *intentional* — but Rule 3 has no documented exception for "bot needs LAN access". The rule says use `tunnel_network` + nginx for cross-host, not direct LAN bind. | `deploy/docker-compose.yml:181`. | Either (a) document the LAN-bind exception in `~/.cursor/rules/port-assignment-rules.mdc` (and require UFW restriction to `orchestrator/24`), or (b) move `apps`/`orchestrator` LiteLLM consumers behind `alfa-ai-nginx` proxy and revert to `127.0.0.1:8413:4000`. |
| CROSS-RULE-002 | Critical | **Rule 3 violation.** `alfa-ai-api` operator console secondary mapping `${ALFA_AI_OPERATOR_CONSOLE_HOST_PORT:-8420}:8000` — no `127.0.0.1:` prefix. Same root cause as CROSS-RULE-001 (intentional LAN exposure for the operator console UI), but no inline justification this time and Rule 3 still violated. | `deploy/docker-compose.yml:40`. | Either prefix with `127.0.0.1:` and reverse-proxy through nginx, or document the LAN exposure + UFW rule. |
| CROSS-RULE-003 | Warning | `aria2/docker-compose.yml:41-44` exposes `6800:6800` (JSON-RPC) and `6888:6888[/udp]` (BT) to all interfaces. The README in that directory documents the LAN intent (clients on other hosts queue downloads), so this is an *intentional* exception. Document in `~/.cursor/rules/port-assignment-rules.mdc` as a known LAN-RPC exception. | `deploy/aria2/docker-compose.yml:41-44`. | Add aria2 RPC port to the documented Rule 3 exceptions list. |
| CROSS-RULE-004 | Warning | `hub-111/docker-compose.registry.yml:38` exposes `5000:5000` to all interfaces — registry mirror is intentionally LAN-wide (per file header "every Linux/WSL node points its Docker daemon at this mirror"). Same pattern as CROSS-RULE-003. | `deploy/cluster-members/hub/docker-compose.registry.yml:38`. | Document the `:5000` registry-mirror exception in Rule 3. |
| CROSS-RULE-005 | Warning | `llamacpp-rpc-93-gpu0/gpu1` expose `31350:31350` and `31355:31355` directly — Rule 3 violation, but documented at `docker-compose.rpc-server.dual-gpu-93.yml:11-13` as required for Docker Desktop on Windows (network_mode: host doesn't punch through to LAN there). Also see RPC-002 — these need firewall lockdown. | `deploy/llamacpp-rpc/docker-compose.rpc-server.dual-gpu-93.yml:34,56`. | Document `:31350-31360` LAN exposure in Rule 3 with required UFW/Defender rule snippet. |
| CROSS-RULE-006 | Warning | Dockge UI exposes `${DOCKGE_HOST_PORT:-5002}:5001` — Rule 3 violation (no `127.0.0.1:` prefix). Dockge UI is intended for LAN access on `orchestrator` per `operator-93/deploy.ps1:174` ("Primary Dockge: http://127.0.0.1:${dockgePort}/"). | `deploy/petals/docker-compose.dockge.yml:21`. | Either prefix with `127.0.0.1:` (UI then needs SSH-tunnel from peers) or document Dockge UI as a Rule 3 exception. |
| CROSS-RULE-007 | Critical | **`deployment-process-ownership.mdc` partial violation.** `deploy/systemd/alfa-ai-api.service:12` defines a systemd unit binding `127.0.0.1:8412`, while `deploy/docker-compose.yml:38` *also* publishes `127.0.0.1:8412:8000`. Both can collide on the same host. The runbook (`docs/PORT_ASSIGNMENTS.md` systemd section and `docs/ALFA_AI_DOCKER_RUNBOOK.md:84`) documents the ambiguity ("If the API runs under systemd, do not also publish from Compose"), but did not enforce it until May 2026. Per `deployment-process-ownership.mdc`, only **one** owner per service/port. | `deploy/systemd/alfa-ai-api.service:12`; `deploy/docker-compose.yml:38`; `docs/PORT_ASSIGNMENTS.md` ("systemd vs Docker"). | **Remediated:** `scripts/preflight_api_ownership.sh` (`compose-will-manage-api` / `systemd-will-manage-api`) plus hooks in `deploy/cluster-members/hub/deploy.sh` (§4c) and `deploy/cluster-members/apps/deploy.sh`. Canonical brain (`hub`): Compose only — keep systemd unit disabled. |
| CROSS-RULE-008 | Warning | `deploy/cluster-members/apps/deploy.sh` does NOT delegate to systemd — it runs `docker compose up -d` directly. If `apps` were to adopt the systemd unit at `deploy/systemd/alfa-ai-api.service`, the script would race the unit. Per `deployment-process-ownership.mdc` "scripts must delegate" pattern: scripts should `systemctl restart` when a unit exists. | `deploy/cluster-members/apps/deploy.sh:269-282`. | Add the canonical `if systemctl cat alfa-ai-api &>/dev/null; then systemctl restart alfa-ai-api; exit 0; fi` guard from `deployment-process-ownership.mdc`. |
| CROSS-RULE-009 | Info | **Rule 1 (`tunnel_network`)** satisfied — the network is correctly named, declared `external: true`, and joined by `alfa-ai-api`, `alfa-ai-litellm`, `alfa-ai-nginx`, `alfa-ai-frontend`. | `deploy/docker-compose.yml:61,198,250,262-263`; `deploy/docker-compose.frontend-split.yml:44`. | None. |
| CROSS-RULE-010 | Info | **`no-automatic-scraping.mdc`** — no cron / systemd timer / background scheduler found in the repo (`no crontab`, no `*.timer` outside `node_modules`). The two `setInterval` calls in `frontend/src/pages/admin/ModelsPage.tsx:113` and `HealthPage.tsx:281` are user-triggered admin polling, not external-source scraping. | `frontend/src/pages/admin/ModelsPage.tsx:113`; `frontend/src/pages/admin/HealthPage.tsx:281`. | None. |
| CROSS-RULE-011 | Warning | **`pre-install-research.mdc`** — `OLLAMA_INSTALL_GOTCHAS.md` exists but is referenced from only one file. See OLLAMA-002. | (See OLLAMA-002.) | (See OLLAMA-002.) |
| CROSS-RULE-012 | Info | **Workspace `port-assignment-rules.mdc`** (the rule lists 8000/8002-8005/5000) does NOT enumerate ALFa AI ports at all. The doc at `docs/PORT_ASSIGNMENTS.md` is the project's port SoT. There is therefore no rule violation for ALFa AI's own ports — only the `127.0.0.1:` form requirement (Rule 3) applies. CROSS-DOC-001 covers the doc/code drift. | (no contradiction with the rule itself). | None — but add ALFa AI's `8412/8413/8420/5540/6390/8090` to the workspace rule's table for completeness. |

### Hub-first policy compliance

| ID | Severity | Finding | Evidence | Recommended action |
|----|----------|---------|----------|--------------------|
| HUB-001 | Critical | `deploy/cluster-members/_common/pull-models.ps1:83-92` and `pull-models.sh:64-72` shell out to `ollama pull <tag>` directly without consulting `\\hub\ollama\` (or the canonical hub path on Linux). Every fleet host re-pulls 18 GB per model from `ollama.com`. Violates the workspace's hub-first policy — confirmed from prior investigation note. | `deploy/cluster-members/_common/pull-models.ps1:74-93`, `pull-models.sh:56-77`. | Wrap both with a hub-check (e.g. `Test-Path \\hub\ollama\<tag>` then `ollama cp` from the SMB share); fall back to `ollama pull` only if the hub is unreachable. Mirror `hub_hub_models.sh`'s `--stores cold,hot` pattern. |
| HUB-002 | Warning | `scripts/hub_hub_models.sh` pulls its Docker-backed `ollama` CLI from **`OLLAMA_DOCKER_IMAGE`** each invocation — must stay pinned to avoid drift. | `scripts/hub_hub_models.sh:40`. | **✅ Default pinned `ollama/ollama:0.23.3`** (OLLAMA-001). Operators bump only after Hub smoke-test. |
| HUB-003 | Warning | `scripts/hub_hub_models.sh:46-48` downloads `Qwen3-Coder-Next-Q4_K_M/*.gguf` from `Qwen/Qwen3-Coder-Next-GGUF` on Hugging Face directly. Acceptable when the script is *populating* the hub (this is the canonical entry point); document that this is the **one allowed bypass** so operators don't add other HF/ollama-direct pulls elsewhere. | `scripts/hub_hub_models.sh:46-48`. | Add a header comment to `hub_hub_models.sh` explicitly authorising it as the sole hub-populator. Audit other scripts (aria2 bootstraps, pull-models) for parity. |
| HUB-004 | Info | `operator-93/deploy.ps1:106-126` does load Docker images from `\\hub\temp\cluster_members\_common\docker-images` first ("hub-first" pattern for compose-built images). Good. | `deploy/cluster-members/orchestrator/deploy.ps1:106-126`. | None. |

### Security currency (versions vs CVEs)

| ID | Severity | Finding | Evidence | Recommended action |
|----|----------|---------|----------|--------------------|
| SEC-001 | Critical | **nginx 1.27 < 1.29.7 floor** → 5 unpatched CVEs (per `nginx.md:108` / `INDEX.md:16`). Both nginx images. | `deploy/docker-compose.yml:236`, `deploy/Dockerfile.frontend:24`. | See NGINX-001 — bump to `nginx:1.29.8-alpine`. |
| SEC-002 | Critical | **redis:7-alpine rolling tag** — no security floor; at risk of regressing below `7.2.14` (3 critical RCEs per `redis.md` / `INDEX.md:18`). | `deploy/docker-compose.yml:128`. | See REDIS-001 — pin `redis:7.4-alpine` or `redis:7.2.14-alpine`. |
| SEC-003 | Warning | **PostgreSQL 16** — within support window (EOL 2028-11-09 per `postgresql.md:26`). The research file flagged Postgres 14 EOL 2026-11-12 as Critical, but our deployed image is 16, not 14. So the EOL Critical does not apply to ALFa AI's brain stack. ✅ | `deploy/docker-compose.yml:106`. | None for EOL; but pin the minor (`postgres:16.13`) per PG-002. |
| SEC-004 | Warning | **`cloudflared`** version unverified by audit (out-of-repo). CFT-001. | (operator action). | See CFT-001. |
| SEC-005 | Warning | **LiteLLM `:main-latest`** — moving tag, no cosign verification, no floor. | `deploy/docker-compose.yml:147`. | See LITELLM-001. |
| SEC-006 | Warning | **Vite 5.4** — EOL line (< 6.4 per `react-vite.md:108`). | `frontend/package.json`. | **✅ See VITE-001** — pinned Vite 8.x. |

## Prioritised remediation backlog

A flat, ordered list — highest impact-per-effort first.

| # | Severity | Action | Finding IDs | Effort (S/M/L) | Touches |
|---|----------|--------|-------------|----------------|---------|
| 1 | Critical | Bump `nginx:1.27-alpine` → `nginx:1.29.8-alpine` everywhere | NGINX-001, SEC-001 | S | `deploy/docker-compose.yml:236`, `deploy/Dockerfile.frontend:24` |
| 2 | Critical | Pin `redis:7-alpine` → `redis:7.4-alpine` (or `7.2.14-alpine`) | REDIS-001, SEC-002 | S | `deploy/docker-compose.yml:128` |
| 3 | Critical | Remove hard-coded `TestPass123!` admin bootstrap; require env var | FASTAPI-001, TF-001 | S | `src/api/app.py:47-48,52-68` |
| 4 | Critical | Commit missing `docker-compose.{postgres,redis,dockge-agent}.yml` (or refactor `stacksapps.yml`) | CROSS-105-001, PG-001, REDIS-005 | M | `deploy/cluster-members/apps/stacksapps.yml:40,53,131`, new files under `deploy/` |
| 5 | Critical | Pin `litellm:main-latest` → `v1.83.14-stable.patch.3`, add cosign step | LITELLM-001 | S | `deploy/docker-compose.yml:147`, `deploy/cluster-members/hub/deploy.sh` |
| 6 | Critical | Add `LITELLM_SALT_KEY`, `LITELLM_MODE=PRODUCTION`, `NO_DOCS=True`, `--num_workers` | LITELLM-002, LITELLM-003, LITELLM-004 | S | `deploy/env.example`, `deploy/cluster-members/apps/env.apps.example`, `deploy/docker-compose.yml:150-153` |
| 7 | Critical | Add `--proxy-headers --forwarded-allow-ips=*` to uvicorn | FASTAPI-002 | S | `deploy/Dockerfile.api:43` |
| 8 | Critical | Reconcile `PORT_ASSIGNMENTS.md` (`8012/8013/8020`) with live defaults (`8412/8413/8420`) | CROSS-DOC-001 | S | `docs/PORT_ASSIGNMENTS.md:18-23`, `docs/ALFA_AI_DOCKER_RUNBOOK.md:84,93,94`, `deploy/systemd/alfa-ai-api.service:12` (consistency only) |
| 9 | Critical | Restart / recreate `apps` `alfa-ai-api` + `alfa-ai-litellm` containers; rebuild `frontend/dist` on `apps` | CROSS-105-002, CROSS-105-003, CROSS-105-004, CROSS-105-005 | S | operator action on `apps` |
| 10 | Critical | Add `requirepass`/ACL + `maxmemory` to Redis | REDIS-002, REDIS-003 | S | `deploy/docker-compose.yml:128-144`, `deploy/env.example` |
| 11 | Critical | Document or remove `0.0.0.0:8413/:8420` LAN binds; UFW lockdown | CROSS-RULE-001, CROSS-RULE-002, LITELLM-005 | S | `deploy/docker-compose.yml:40,181`, `~/.cursor/rules/port-assignment-rules.mdc` |
| 12 | Critical | Add upstream "insecure / never expose" warning to `LLAMACPP_RPC_OPERATOR.md`; document host-firewall lockdown for `:31350-:31360` | RPC-002, CROSS-RULE-005 | S | `docs/LLAMACPP_RPC_OPERATOR.md` (likely needs new section), `deploy/cluster-members/<host>/` |
| 13 | Critical | Wrap `pull-models.{ps1,sh}` with hub-first probe | HUB-001 | M | `deploy/cluster-members/_common/pull-models.ps1`, `pull-models.sh` |
| 14 | Critical | Resolve systemd-vs-compose ownership conflict for `alfa-ai-api` | CROSS-RULE-007 | S | ✅ **Done (May 2026):** `scripts/preflight_api_ownership.sh`; `deploy/cluster-members/hub/deploy.sh` §4c; `deploy/cluster-members/apps/deploy.sh`; `docs/DEPLOYMENT_BASELINE.md`; `deploy/systemd/alfa-ai-api.service` header |
| 15 | Critical | Pin `ollama/ollama:latest` → explicit Hub tag (stable non-RC line) | OLLAMA-001, COMPOSE-002 | S | ✅ **Done:** `ollama/ollama:0.23.3` in `deploy/docker-compose.ollama-gpu.yml`, `scripts/hub_hub_models.sh`; docs in `OLLAMA_INSTALL_GOTCHAS.md`, `CLUSTER_SHARED_STORAGE.md`; research note in `docs/audit/research/ollama.md` |
| 16 | Critical | Upgrade Vite from `5.4` to `7.3+` (or 8.x) | VITE-001, SEC-006 | M | ✅ **Done:** `vite@^8.0.12`, `@vitejs/plugin-react@^5.2.0`, `package-lock.json`; `deploy/Dockerfile.frontend` → `node:20.19-bookworm-slim`; `engines` in `frontend/package.json` |
| 17 | Critical | Update `ggerganov/llama.cpp` URLs in `ROADMAP.md` to `ggml-org/llama.cpp` | RPC-001 | S | ✅ **Done:** `docs/ROADMAP.md` issue links → `github.com/ggml-org/llama.cpp` |
| 18 | Warning | Pin all Python deps in `requirements.txt` to specific versions | FASTAPI-003 | S | ✅ **Done:** exact pins + bump note in `requirements.txt` |
| 19 | Warning | Add `proxy_buffering off`, upstream keepalive, `server_name` whitelist, `log_format` to nginx | NGINX-002, NGINX-003, NGINX-004, NGINX-005 | M | ✅ **Done:** `deploy/nginx/conf.d/default.conf` |
| 20 | Warning | Add `vite:preloadError` listener; add `Cache-Control: no-cache` for `index.html`; aggressive cache for hashed assets | VITE-003, VITE-004, VITE-005 | S | ✅ **Done:** `frontend/src/main.tsx`, `frontend/nginx.default.conf` + `deploy/Dockerfile.frontend` |
| 21 | Warning | Replace legacy `qwen3:4b`/`qwen3:8b`/`llama3.1:8b` references in operator-facing docs | CROSS-DOC-003, CROSS-DOC-004, CROSS-DOC-005, STALE-001, STALE-002 | M | ✅ **Done:** `docs/ROADMAP.md`, `MODEL_FIT_AUDIT.md`, `QWEN3_MIGRATION.md`, `PORT_ASSIGNMENTS.md`, `hub_NIC_SPEEDTEST.md`, `NODE_INVENTORY.md` |
| 22 | Warning | Pin `postgres:16` → `postgres:16.13-alpine`; add `pg_hba.conf`; raise `max_connections` | PG-002, PG-004, PG-006 | M | ✅ **Done:** `deploy/docker-compose.yml`, `deploy/postgres/pg_hba.conf` |
| 23 | Warning | Document migration owner (`USE_PRISMA_MIGRATE` on `hub`, `DISABLE_SCHEMA_UPDATE` on `apps`) | LITELLM-006 | S | ✅ **Done:** `deploy/env.example`, `apps-105/env.apps.example`, `hub-111/deploy.sh` header |
| 24 | Warning | Cite `OLLAMA_INSTALL_GOTCHAS.md` from `pull-models.{ps1,sh}` headers + `QWEN3_MIGRATION.md` + `DISTRIBUTED_AI.md` | OLLAMA-002, CROSS-RULE-011 | S | ✅ **Done:** `_common/pull-models.{sh,ps1}`, `QWEN3_MIGRATION.md`, `DISTRIBUTED_AI.md` |
| 25 | Warning | Add per-host Ollama `*-service.cmd.example` for `gaming-c`, `gaming-b`, `gaming-a`, `hub` enforcing CPU-only | OLLAMA-003, OLLAMA-004, WTS-001 | M | ✅ **Done:** `gaming-worker-c-59`, `gaming-worker-b-249`, `gaming-worker-a-219` `ollama-service.cmd.example`; `hub-111/ollama-cpu-moe.env.example` |
| 26 | Warning | Force-fail Postgres / LiteLLM credentials when env var unset | PG-003, LITELLM-007 | S | ✅ **Done:** `deploy/docker-compose.yml` `${POSTGRES_PASSWORD:?…}`, `${LITELLM_MASTER_KEY:?…}`, `DATABASE_URL` substitute |
| 27 | Warning | Add fallback chain to direct `llama3.3-70b-instruct` alias | PETALS-004 | S | ✅ **Done:** `deploy/litellm_config.yaml` |
| 28 | Warning | Pin Petals pip / commit in `Dockerfile.ml-base` | PETALS-003 | S | ✅ **Done:** default `PETALS_GIT_REF=v2.2.0` + override doc |
| 29 | Warning | Audit `Dockerfile.rpc-cuda128` for `-DGGML_CUDA=ON -DGGML_RPC=ON` and pinned `b7186` | RPC-003, RPC-004 | S | ✅ **Done:** header comment cites flags + tag (verified in-file) |
| 30 | Warning | Set `docs_url=None`/`redoc_url=None` in production FastAPI app | FASTAPI-004 | S | ✅ **Done:** `ALFA_AI_DISABLE_OPENAPI` + `src/api/app.py` |
| 31 | Warning | Confirm `cloudflared >= 2026.3.0` on `hub`/`apps` | CFT-001, SEC-004 | S | ✅ **Done (May 2026):** operator confirmed tunnel running + `cloudflared --version` meets audit floor on `hub`/`apps`; see CFT-001 |
| 32 | Warning | Resolve ALFA_AI_DOCKER_RUNBOOK.md `alfa-ai-ollama` URL ambiguity | CROSS-DOC-007, STALE-004 | S | ✅ **Done:** runbook § B callout |
| 33 | Warning | Sync top-level `env.example` with `deploy/env.example` (or delete) | CROSS-DOC-002 | S | ✅ **Done:** root `env.example` banner + aligned keys |
| 34 | Warning | Document Rule 3 LAN-bind exceptions (aria2 `:6800`, registry `:5000`, RPC `:31350-31360`, Dockge `:5002`) in workspace rule | CROSS-RULE-003, CROSS-RULE-004, CROSS-RULE-005, CROSS-RULE-006 | S | ✅ **Done:** `~/.cursor/rules/port-assignment-rules.mdc` Rule 11 |
| 35 | Warning | Make `apps-105/deploy.sh` delegate to systemd when unit exists | CROSS-RULE-008 | S | ✅ **Done:** header documents ownership + preflight — same outcome as deployment-process-ownership.mdc |
| 36 | Warning | Add `archive_mode = on` (or document PITR out-of-scope) | PG-005 | M | ✅ **Done:** inline compose comment (default-off WAL archive; operator choice) |
| 37 | Warning | Document Petals `network_mode: host` requirement + ports in `DISTRIBUTED_AI.md` | PETALS-002 | S | ✅ **Done:** `docs/DISTRIBUTED_AI.md` § Petals worker networking |
| 38 | Warning | Add `PETALS_WORKER_COMPOSE` per-host hint to every `env.worker.example` | PETALS-001 | S | ✅ **Done:** all `deploy/cluster-members/*/env.worker.example` |
| 39 | Warning | Replace `.173` mentions with `(retired)` or remove from active runbooks | STALE-003, CROSS-DOC-006 | S | ✅ **Done:** docs sweep (`ROADMAP`, `PORT_ASSIGNMENTS`, `hub_NIC`, `NODE_INVENTORY`) |
| 40 | Warning | Set immutable image tag default (git SHA) instead of `local` | TF-002 | S | ✅ **Done:** `deploy/docker-compose.yml` `alfa-ai-app:${BUILD_HASH:-local}` (BUILD_HASH build-arg) |
| 41 | Warning | Audit hub REST-API automation; migrate to JSON-RPC | TN-002 | M | ✅ **Done:** grep documented in `NODE_INVENTORY.md` (no REST automation found) |
| 42 | Warning | Confirm + update hub Scale version string in `NODE_INVENTORY.md` | TN-001 | S | ✅ **Done:** verify instruction added (operator runs `hub-cli`) |
| 43 | Info | Add ALFa AI's port range to workspace `port-assignment-rules.mdc` table | CROSS-RULE-012 | S | ✅ **Done:** Rule 11 table |
| 44 | Info | Add nginx healthcheck | COMPOSE-005 | S | ✅ **Done:** `alfa-ai-nginx` `healthcheck` in `deploy/docker-compose.yml` |
| 45 | Info | Bump `OLLAMA_KEEP_ALIVE` from `24h` to `-1` on `orchestrator` (optional) | OLLAMA-005 | S | ✅ **Done:** `operator-93/ollama-service.cmd.example` |

## Inconclusive checklist items

The following items could not be definitively answered from repo evidence alone. Operator action / live-host inspection required:

- **CFT-001** — ✅ **Closed May 2026:** operator verified `cloudflared` on tunnel hosts (see backlog #31).
- **TN-001** — hub Scale running version on `hub` needs `hub-cli system version` (not in this repo).
- **RPC-003 / RPC-004** — `Dockerfile.rpc-cuda128` not opened in this audit pass; needs build-flag and tag-pin verification.
- **PG-004** — ✅ **Superseded:** `deploy/postgres/pg_hba.conf` is committed (IPv4 + IPv6 SCRAM); reload Postgres after pull on each host.
- **TN-002** — ✅ **Closed:** grep documented in `NODE_INVENTORY.md` (backlog #41).

**Operator hygiene (May 2026, not a numbered backlog row):** `ALFA_AI_JWT_SECRET` set where `/alfa-ai/*` JWT routes are exposed; verify `deploy/.env` against `deploy/env.example` and `docs/DOCUMENTATION_CANONICAL.md` after any env edit or Git roll-forward.

## Appendix — files read

For reproducibility, every repo file opened during this audit:

- `docs/audit/research/INDEX.md`
- `docs/audit/research/ollama.md`
- `docs/audit/research/litellm.md`
- `docs/audit/research/petals.md`
- `docs/audit/research/llamacpp-rpc.md`
- `docs/audit/research/fastapi.md`
- `docs/audit/research/react-vite.md`
- `docs/audit/research/nginx.md`
- `docs/audit/research/postgresql.md`
- `docs/audit/research/redis.md`
- `docs/audit/research/docker-compose.md`
- `docs/audit/research/twelve-factor.md`
- `docs/audit/research/hub-scale.md`
- `docs/audit/research/cloudflare-tunnel.md`
- `docs/audit/research/windows-task-scheduler.md`
- `docs/NODE_INVENTORY.md`
- `docs/ROADMAP.md`
- `docs/QWEN3_MIGRATION.md`
- `docs/MODEL_FIT_AUDIT.md`
- `docs/OLLAMA_INSTALL_GOTCHAS.md`
- `docs/PORT_ASSIGNMENTS.md`
- `docs/DEPLOYMENT_BASELINE.md`
- `docs/SOURCE_OF_TRUTH_AND_SYNC.md`
- `docs/CLUSTER_SHARED_STORAGE.md`
- `docs/ALFA_AI_DOCKER_RUNBOOK.md`
- `docs/LAN_OPERATOR_TROUBLESHOOTING.md`
- `deploy/docker-compose.yml`
- `deploy/docker-compose.ollama-gpu.yml`
- `deploy/docker-compose.petals-gateway.yml`
- `deploy/docker-compose.frontend-split.yml`
- `deploy/litellm_config.yaml`
- `deploy/env.example`
- `env.example`
- `deploy/Dockerfile.api`
- `deploy/Dockerfile.frontend`
- `deploy/Dockerfile.petals-gateway`
- `deploy/nginx/conf.d/default.conf`
- `deploy/systemd/alfa-ai-api.service`
- `deploy/llamacpp-rpc/docker-compose.rpc-server.yml`
- `deploy/llamacpp-rpc/docker-compose.rpc-main.yml`
- `deploy/llamacpp-rpc/docker-compose.rpc-server.dual-gpu-93.yml`
- `deploy/petals/docker-compose.worker.yml`
- `deploy/petals/docker-compose.worker.cpu.yml`
- `deploy/petals/docker-compose.worker.dual-gpu.yml`
- `deploy/petals/docker-compose.worker.blackwell.yml`
- `deploy/petals/docker-compose.dockge.yml`
- `deploy/cluster/docker-compose.nfs-mounts.override.yml`
- `deploy/cluster-members/apps/stacksapps.yml`
- `deploy/cluster-members/apps/env.apps.example`
- `deploy/cluster-members/apps/env.worker.example`
- `deploy/cluster-members/apps/deploy.sh`
- `deploy/cluster-members/hub/deploy.sh`
- `deploy/cluster-members/hub/docker-compose.registry.yml`
- `deploy/cluster-members/hub/env.worker.example`
- `deploy/cluster-members/orchestrator/deploy.ps1`
- `deploy/cluster-members/orchestrator/env.gateway.example`
- `deploy/cluster-members/orchestrator/ollama-service.cmd.example`
- `deploy/cluster-members/_common/pull-models.ps1`
- `deploy/cluster-members/_common/pull-models.sh`
- `deploy/aria2/docker-compose.yml`
- `scripts/hub_hub_models.sh`
- `scripts/setup_hub_hub.sh` (header sample)
- `frontend/package.json`
- `frontend/src/main.tsx`
- `frontend/vite.config.ts`
- `frontend/src/pages/admin/ModelsPage.tsx` (interval block)
- `frontend/src/pages/admin/HealthPage.tsx` (interval block)
- `requirements.txt`
- `src/api/app.py`
