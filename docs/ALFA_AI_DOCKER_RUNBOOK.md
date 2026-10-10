# ALFa AI — Docker / NVIDIA / PyTorch runbook

Step order follows **NVIDIA Container Toolkit** → **Docker Engine GPU** → **Compose** → **Ollama** → **ALFa** services.

## 1. What you already verified (example: hub)

- **Docker CLI** on the host (`docker --version`).
- **Docker data root** (e.g. `df -h` on `Docker Root Dir` from `docker info`). On hub SCALE this is often under **`/mnt/.ix-apps/docker`** on a data pool — that is where **images and anonymous volumes** live unless you bind-mount elsewhere.

Host **OS disk vs HDD pool** does not change the steps below; it only affects **I/O speed** for image layers and volumes.

## 2. NVIDIA (host)

1. Install a **supported NVIDIA driver** on the host (vendor/OS guide for hub or Ubuntu).
2. Install and configure **NVIDIA Container Toolkit** so the Docker Engine can pass GPUs into containers:  
   [NVIDIA Container Toolkit — install guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
3. **Smoke test** (Docker manual pattern):

   ```bash
   sudo docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
   ```

If this fails, fix toolkit/driver **before** Compose.

## 3. Docker Compose — external network

ALFa’s baseline compose expects an **external** network named **`tunnel_network`**:

```bash
docker network create tunnel_network
```

(Create once per Docker host.)

## 4. Environment and ports

```bash
cd /path/to/alfa-ai/deploy
cp env.example .env
# Edit .env: ports, secrets, OLLAMA_BASE_URL (see below)
bash ../scripts/preflight_ports.sh .env
```

## 5. Inference placement (pick one)

### A) Ollama on the Docker host (common)

- Install **Ollama** on the host per [Ollama docs](https://github.com/ollama/ollama).
- Listen on all interfaces if containers must reach it: e.g. **`OLLAMA_HOST=0.0.0.0`** (see Ollama FAQ / install docs for your OS).
- In **`deploy/.env`**: **`OLLAMA_BASE_URL=http://host.docker.internal:11434`** (already the default in `env.example`; Linux uses `extra_hosts: host-gateway` in compose).

### B) Ollama inside Docker with GPU (optional merge file)

**Only when you merge `-f docker-compose.ollama-gpu.yml`.** The hostname `alfa-ai-ollama`
exists only in that override; `docker-compose.yml` alone will not resolve it (audit CROSS-DOC-007 / backlog #32).

Aligns with Docker’s **device reservations** for GPUs: [Compose GPU support](https://docs.docker.com/compose/how-tos/gpu-support/).

1. In **`deploy/.env`** set:

   ```env
   OLLAMA_BASE_URL=http://alfa-ai-ollama:11434
   ```

2. Start with both files:

   ```bash
   docker compose --env-file .env -f docker-compose.yml -f docker-compose.ollama-gpu.yml up -d
   ```

3. Pull a model:

   ```bash
   docker exec alfa-ai-ollama ollama pull qwen3.5:27b
   ```

   > In the ALFa fleet, tiers 0/1/2 are a two-host CPU pool — dense `qwen3.5:27b`
   > on `gaming-c` (quality, `OLLAMA_FLEET_59_URL`) + `qwen3.6:35b-a3b` MoE on `orchestrator`
   > (speed, `OLLAMA_FLEET_93_URL`); the May `gaming-c`-only `qwen3:32b` and April
   > `qwen3-coder:30b-a3b-q4_K_M` CPU MoE fleet are superseded. **Requires Ollama
   > `0.30.x`** (Gated-DeltaNet). This in-Docker GPU option is for a standalone/dev host only.

## 6. Start the ALFa stack

**Full stack** (from `deploy/`):

```bash
docker compose --env-file .env -f docker-compose.yml up -d
```

**Public web UI (`/alfa-ai/*`):** `deploy/Dockerfile.api` runs **`npm run build`** in a Node stage and copies **`frontend/dist`** into the image. The **`alfa-ai-api`** container serves both **`/alfa-ai/api/*`** (auth, chat, guest, admin) and the SPA shell for routes such as **`/alfa-ai/admin/health`** (see `_register_alfa_ai_spa()` in `src/api/app.py`). Set **`ALFA_AI_JWT_SECRET`** and **`DATABASE_URL`** in **`deploy/.env`** for login and admin APIs. Nginx on `www` only proxies; routing and JWT are documented in **`docs/ADMIN_HEALTH_WEB_WORKFLOW.md`**. Brain-only JSON **`GET /api/admin/health`** (LAN operator port, e.g. `:8420`) is separate from **`GET /alfa-ai/api/admin/health`**; see **`deploy/env.example`** (`ALFA_AI_LOCK_OPERATOR_HEALTH`).

**Hybrid** (API already on host port 8412 via systemd — see
`docs/DEPLOYMENT_BASELINE.md` and `PORT_ASSIGNMENTS.md`):

```bash
docker compose --env-file .env -f docker-compose.yml up -d alfa-ai-litellm
```

## 7. Health checks

```bash
curl -fsS http://127.0.0.1:8413/health/liveliness   # LiteLLM proxy
curl -fsS http://127.0.0.1:8412/health              # ALFa AI API
```

Full checklist:

```bash
bash ../scripts/alfa_ai_rollout_preflight.sh .env
```

## 8. PyTorch in this repo

- **`alfa-ai-api` / worker** (`requirements.txt`): **no PyTorch** — inference goes through **LiteLLM → Ollama** (or Petals), not in-process PyTorch.
- **`alfa-ai-petals-gateway`** (default compose): installs **CPU** PyTorch wheel for the gateway process; **distributed GPU** is via **Petals workers** on GPU hosts (`docs/DISTRIBUTED_AI.md`), not by installing PyTorch on the hub OS for the API container.

For **GPU PyTorch inside a custom container**, follow [PyTorch — Get started](https://pytorch.org/get-started/locally/) and match **CUDA** to your **driver**; that is separate from the default ALFa + Ollama path.

## 9. Troubleshooting: nginx bind mount “not a directory / mount a directory onto a file”

**Current layout:** `deploy/docker-compose.yml` bind-mounts **`./nginx/conf.d`** (a directory) to **`/etc/nginx/conf.d`**, with **`deploy/nginx/conf.d/default.conf`** in git. This avoids Docker Desktop single-file bind quirks.

**Legacy symptom (old single-file mount):** `error mounting ".../deploy/nginx.conf" to ... default.conf` / `Are you trying to mount a directory onto a file`.

**Cause (legacy):** `./nginx.conf` was **missing** on first `compose up`; Docker could create **`nginx.conf` as a directory**.

**Fix after `git pull`:** Remove any stale **`deploy/nginx.conf`** file or directory if present, ensure **`deploy/nginx/conf.d/default.conf`** exists, then recreate nginx:

```bash
rm -rf deploy/nginx.conf   # only if this path still exists as a bad directory/file
git checkout HEAD -- deploy/nginx/conf.d/default.conf
docker compose -f deploy/docker-compose.yml up -d alfa-ai-nginx
```

**Prevention:** Run `bash scripts/preflight_ports.sh deploy/.env` before `compose up`; it verifies `deploy/nginx/conf.d/default.conf` exists and is a regular file.

### `alfa-ai-api` unhealthy / restarts (ImportError in logs)

If `docker logs alfa-ai-api` shows `ModuleNotFoundError` (e.g. `bcrypt`, `pyotp`), the API image’s `pip install -r requirements.txt` is missing a dependency required by the web auth stack. The canonical list is **`requirements.txt`** at the repo root — rebuild the image after `git pull`.

## 10. Related docs

- `docs/ADMIN_HEALTH_WEB_WORKFLOW.md` — `www` `/alfa-ai/*`, edge nginx, JWT vs brain-only health JSON.
- `docs/DEPLOYMENT_BASELINE.md` — networks, hybrid systemd API, ports.
- `docs/DISTRIBUTED_AI.md` — Petals workers + gateway.
- `docs/NODE_INVENTORY.md` — LAN nodes and ports.
