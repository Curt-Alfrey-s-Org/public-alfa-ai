# Brain migration runbook — `apps` → `hub`

> **HISTORICAL / AUDIT TRAIL (April 2026):** This runbook describes the
> **pre–Qwen3-migration** brain move and model set (`qwen2.5-coder`, Qwen-72B
> Petals plans, etc.). **Current** tier matrix and models live in
> **[QWEN3_MIGRATION.md](../QWEN3_MIGRATION.md)** and **[ROADMAP.md](../ROADMAP.md)**.
> Do not follow the Qwen2.5-specific commands below as “today’s” procedure
> without cross-checking those docs.
>
> **April 2026 cluster rebalance update:** the gateway ordering in this
> runbook is stale. **Primary Petals gateway is now `orchestrator`**, **fallback
> in-stack on `hub`**, **last-resort on `apps`**. `hub` additionally runs
> a Petals worker (announce on `.157`) and the CPU MoE
> (`qwen3-coder:30b-a3b-q4_K_M`) for tiers 0/1/2. Embeddings live on `gaming-c`
> (primary) and `gaming-b` (cold-standby). See
> [ROADMAP.md "Cluster rebalance"](../ROADMAP.md#cluster-rebalance-111-petals--cpu-moe-april-2026).

**Status:** brain stack **executed on `hub`** for many operators; this file
remains the phased checklist and rationale archive.

This document is the step-by-step runbook for moving the ALFa AI brain
(`alfa-ai-api`, `alfa-ai-litellm`, `alfa-ai-petals-gateway` fallback,
`alfa-ai-nginx`, Ollama agent tier) **from `apps` (Ubuntu, i7-6700K) to
`hub` (hub Scale 25.04, Ryzen 9 7900X)**.

The migration is intentionally phased so each phase is **revertable** in
minutes. Nothing is destructive until the final sweep in Phase 7.

Context + rationale: [ROADMAP.md § Architecture shift](ROADMAP.md#architecture-shift-april-2026-brain--111)
and [NODE_INVENTORY.md](NODE_INVENTORY.md).

## Scope

**Moves to `hub`:**

- `alfa-ai-api` container (brain FastAPI on `:8420`).
- `alfa-ai-litellm` container (`:4000`).
- `alfa-ai-nginx` (reverse proxy).
- `alfa-ai-petals-gateway` **fallback** (the *primary* gateway stays on `apps`).
- Ollama + agent tier model `qwen2.5-coder:32b-q4_K_M` + `nomic-embed-text`.

**Stays on `apps`:**

- Every website + bot (rankings-bot, atems, USPBF, alfaqd-website,
  contracts-bot, credit-check-bot, market-pie5-bot, rv-auto-finder).
- **Postgres** (brain DB connects over LAN `apps`).
- **Redis** (brain connects over LAN `apps`).
- **Primary** `alfa-ai-petals-gateway` (brain's `PETALS_GATEWAY_URL`
  points here → `http://apps`).
- Petals worker — becomes the DHT bootstrap. **Post-swap the GPU on
  `apps` is now a GTX 1660 Super 6 GB** (later swapped with `secondary` after the `hub` migration).
- libvirt/KVM VMs.

**Leaves the Petals swarm entirely:**

- `hub` (was Petals worker `.157`). Its **RTX 3060 12 GB** (post-swap,
  previously on `apps`) is now dedicated to Ollama tiers 1 and 2. Swarm
  drops from 60 GB (pre-migration, 6 nodes) → 52 GB (5 nodes, pre-swap) →
  **46 GB** (5 nodes, post-swap — `apps` contributes 6 GB instead of 12 GB).

## Pre-flight checklist (before Phase 1)

- [ ] `hub` on hub Scale **25.04** or newer (Docker-native). On 24.x you
      will need to manually enable `k3s.docker=true`. Confirm:
      `cat /etc/version` → `25.04-*`.
- [ ] `hub` has the Samsung 990 (600 GB) installed, visible in
      **Storage → Disks**, **not** part of any existing pool.
- [ ] NVMe pool built per [hub_111_NVME_POOL.md](hub_111_NVME_POOL.md) §§ 1–2.
- [ ] ZFS ARC cap applied (§ 7 of the NVMe doc).
- [ ] Docker data-root moved to NVMe (§ 3 of the NVMe doc).
- [ ] `nvidia-smi` on `hub` shows **RTX 3060 12 GB** (post-swap).
- [ ] `nvidia-smi` on `apps` shows **GTX 1660 Super 6 GB** (post-swap with `secondary`).
- [ ] hub NIC speed-test run — see
      [hub_NIC_SPEEDTEST.md](hub_NIC_SPEEDTEST.md) — fastest NIC
      bound to `hub`.
- [ ] `docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi`
      succeeds (nvidia-container-toolkit wired).
- [ ] Postgres on `apps` reachable from `hub` over LAN:
      `ssh operator@hub 'timeout 3 bash -c "</dev/tcp/apps/5432"' && echo ok`
- [ ] Redis on `apps` reachable from `hub`:
      `ssh operator@hub 'timeout 3 bash -c "</dev/tcp/apps/6379"' && echo ok`
- [ ] `hub` HF_TOKEN available (for gated Meta models if we flip to Llama).
- [ ] Backup of Postgres DB:
      ```bash
      ssh operator@apps 'docker exec alfa-postgres pg_dumpall -U postgres' \
        > /tmp/alfa-ai-postgres-preflight-$(date +%Y%m%d).sql
      ```
- [ ] Backup of `/home/operator/alfa-ai/deploy/.env` from `apps`:
      ```bash
      scp operator@apps:/home/operator/alfa-ai/deploy/.env \
          /tmp/alfa-ai.env.from-105-$(date +%Y%m%d)
      ```

## Phase 1 — Pull `hub` (= old peer `.157`) out of the Petals swarm

Goal: free `hub`'s GPU for Ollama (post-swap that GPU is the 3060 12 GB);
make `apps` the DHT bootstrap.

### 1.1. Stop the Petals worker on `hub`

```bash
# On hub (SSH)
sudo docker stop petals-worker || true
sudo docker rm petals-worker || true
sudo docker ps --filter name=petals   # empty
```

### 1.2. Make `apps` the bootstrap

On `apps`:

```bash
cd /home/operator/alfa-ai/deploy/petals
# Edit .env.worker:
#   PETALS_INITIAL_PEERS=        # empty — apps is now bootstrap
#   WORKER_NAME=web-sites
docker compose --env-file .env.worker -f docker-compose.worker.yml \
  up -d --force-recreate petals-worker

# Get new bootstrap multiaddr
sudo docker logs petals-worker 2>&1 \
  | grep -E 'Running a server on' | tail -1
# Save the /ip4/apps/tcp/31330/p2p/<peer-id> line.
```

### 1.3. Refresh `PETALS_INITIAL_PEERS` on every other worker

Workers to update: `orchestrator`, `gaming-b`, `gaming-c`, `gaming-a`. For each:

- Update the per-machine `.env.worker` with the new `apps` multiaddr.
- `docker compose up -d --force-recreate petals-worker`.

Template files already pre-seed `ALFA_BRAIN_URL=http://apps`
(legacy) — **those will be updated in Phase 5** once the brain on `hub`
is live. Keeping heartbeat flow going to `apps` during Phases 1–4 is fine
because `apps` is still running the brain.

### 1.4. Gate

- Gateway `/health` from `apps`: `reachable_peers >= 4`, all blocks covered.
- `curl http://apps/health | jq '.loaded_models, .reachable_peers'`.

## Phase 2 — Pre-stage models on `hub`

Put the new agent + frontier weights on `hub` so nothing has to download
during the cutover.

### 2.1. Frontier (Qwen 2.5 72B) on HDD → HF cache

```bash
# On hub (docs/CLUSTER_SHARED_STORAGE.md § 2.2)
export HF_TOKEN=hf_xxx   # token with read access
docker run --rm \
  -v /mnt/HDDs/Alfa-AI/models/huggingface:/hf \
  -e HF_HOME=/hf -e HUGGINGFACE_HUB_CACHE=/hf/hub \
  -e HF_TOKEN="$HF_TOKEN" \
  python:3.12-slim bash -c '
    pip install --quiet "huggingface_hub>=0.25" hf_xet
    hf download Qwen/Qwen2.5-72B-Instruct
  '
# ~145 GB. Confirm:
du -sh /mnt/HDDs/Alfa-AI/models/huggingface/hub/models--Qwen--Qwen2.5-72B-Instruct
```

### 2.2. Agent (Qwen 2.5 Coder 32B) on NVMe → Ollama

```bash
# Ollama already pointed at /mnt/nvme/ollama (see hub_111_NVME_POOL.md § 4)
ollama pull qwen2.5-coder:32b-q4_K_M   # ~19 GB
ollama pull nomic-embed-text           # ~250 MB
# Optional future tiers:
# ollama pull qwen2.5-coder:14b-q5_K_M
# ollama pull qwen2.5-coder:1.5b
```

### 2.3. Smoke the 32B model

```bash
time curl -s http://127.0.0.1:11434/api/generate \
  -d '{"model":"qwen2.5-coder:32b-q4_K_M","prompt":"Write hello world in Python.","stream":false,"options":{"num_predict":64}}' \
  | jq '.response'
# Expect first-token in < 2 s, total < 15 s.
```

## Phase 3 — Stand up the brain stack on `hub` (parallel with `apps`)

The brain on `hub` comes up in **parallel** with the one on `apps` until
smoke tests pass. Both bind `:8420` / `:4000` — but `apps`'s are on `apps`
and `hub`'s are on `hub`, so they don't collide.

### 3.1. Clone repo to `hub`

```bash
# On hub
mkdir -p /mnt/HDDs/Alfa-AI/repo
cd /mnt/HDDs/Alfa-AI/repo
git clone operator@example.com:example/alfa-ai.git
cd alfa-ai
git log -1 --oneline
```

### 3.2. Configure `deploy/.env` for the `hub` brain

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy
cp env.example .env
```

Edit `.env` (critical values):

```env
# Host ports
ALFA_AI_API_HOST_PORT=8420
ALFA_AI_LITELLM_HOST_PORT=4000
ALFA_AI_NGINX_HTTP_HOST_PORT=8080
ALFA_AI_NGINX_HTTPS_HOST_PORT=8443

# Upstreams
OLLAMA_BASE_URL=http://host.docker.internal:11434
# If Ollama runs as a hub App, host.docker.internal won't resolve from a
# normal compose bridge. Use the LAN IP instead:
#   OLLAMA_BASE_URL=http://hub

# Petals gateway — PRIMARY lives on apps
PETALS_GATEWAY_URL=http://apps

# Stateful deps on apps
DATABASE_URL=postgresql://alfa@apps/alfa_ai
REDIS_URL=redis://apps/0

# Keys (same value as apps during cutover; rotate after)
LITELLM_MASTER_KEY=<same as apps>
ALFA_WORKER_HEARTBEAT_TOKEN=<same as apps>
ALFA_AI_API_TOKEN=<same as apps>
```

### 3.3. Open the Postgres + Redis firewall on `apps` for `hub`

On `apps`:

```bash
sudo ufw allow from hub to any port 5432 proto tcp
sudo ufw allow from hub to any port 6379 proto tcp
```

Quick check from `hub`:

```bash
ssh operator@hub 'timeout 3 bash -c "</dev/tcp/apps/5432" && echo pg-ok'
ssh operator@hub 'timeout 3 bash -c "</dev/tcp/apps/6379" && echo redis-ok'
```

### 3.4. Bring up the brain on `hub`

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai
bash deploy/cluster-members/hub/deploy.sh
```

### 3.5. Smoke tests (from outside `hub`)

```bash
curl -fsS http://hub/health
curl -fsS http://hub/health/liveliness
curl -fsS http://hub/api/tags | jq '.models[].name'

# Tier-2 agent inference
curl -fsS http://hub/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"agent","messages":[{"role":"user","content":"Say hi."}],"max_tokens":8}'

# Tier-3 frontier (routes through apps Petals gateway)
curl -fsS http://hub/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"frontier","messages":[{"role":"user","content":"Say hi."}],"max_tokens":8}'
```

Both should return non-empty assistant content within ~60 s of cold start.

### 3.6. Gate

- `hub` brain green on `/alfa-ai/admin/health` (load page manually).
- Postgres roundtrip works (admin UI logs in successfully).
- Worker heartbeats still landing (check from `apps`'s admin UI — still
  authoritative at this point).

## Phase 4 — Flip the Petals swarm to Qwen-72B

Do this after the brain on `hub` can route `frontier` calls against the
current swarm model (CodeLlama-7B or whatever is live).

See [ROADMAP.md § "Flip to Qwen-72B on Petals"](ROADMAP.md#flip-to-qwen-72b-on-petals--operator-procedure).
Procedure summary:

1. Weights already pre-staged on `hub` HDD in Phase 2.1; every worker sees
   them via NFS (`/mnt/cluster/models/huggingface`).
2. Edit every worker `.env.worker`:
   `PETALS_MODEL=Qwen/Qwen2.5-72B-Instruct`, `HF_TOKEN=$HF_TOKEN`.
3. On each worker host, **simultaneously**:
   `docker compose ... up -d --force-recreate petals-worker`.
4. Gate: `reachable_peers >= 4`, blocks `[0..80)` covered, smoke test passes.

## Phase 5 — Flip workers' `ALFA_BRAIN_URL` → `hub`

After the `hub` brain is proven, redirect worker heartbeats to it so the
operator UI on `hub` reflects cluster reality.

For each worker (`apps`, `orchestrator`, `gaming-b`, `gaming-c`, `gaming-a`): update `.env.worker`:

```env
ALFA_BRAIN_URL=http://hub
```

Then `docker compose up -d --force-recreate worker-heartbeat` (not the
petals-worker — heartbeat is a sidecar, you don't need to bounce the worker).

Update the canonical templates:

- `deploy/petals/env.worker.example`
- `deploy/petals/.env.worker.example`
- `deploy/cluster-members/<host>/env.worker.example` (replaces removed `deploy/petals/smb-bootstrap/` templates)

(These are updated in this same doc-first pass — see the commit log.)

## Phase 6 — Flip websites + bots on `apps` to call `hub`

Every service on `apps` that previously called its local brain at
`127.0.0.1:8420` or `apps` now calls `hub`.

### 6.1. Sweep bot `.env` files

```bash
# On apps
cd /home/operator
grep -rE '(ALFA_AI_API_URL|LITELLM_BASE_URL)' \
  rankings-bot/.env \
  USPBF/.env \
  alfaqd-website/.env \
  contracts-bot/.env \
  credit-check-bot/.env \
  market-pie5-bot/.env \
  rv-auto-finder/.env \
  atems/.env 2>/dev/null
```

For each `.env`, rewrite:

| Before | After |
|--------|-------|
| `ALFA_AI_API_URL=http://127.0.0.1:8420` | `ALFA_AI_API_URL=http://hub` |
| `ALFA_AI_API_URL=http://apps` | same |
| `LITELLM_BASE_URL=http://127.0.0.1:8013` or `http://127.0.0.1:4000` | `LITELLM_BASE_URL=http://hub` |

Batch example with `sed`:

```bash
for f in \
  /home/operator/rankings-bot/.env \
  /home/operator/USPBF/.env \
  /home/operator/alfaqd-website/.env ; do
  [ -f "$f" ] || continue
  cp "$f" "$f.bak-brain-migration"
  sed -i -E \
    -e 's|^ALFA_AI_API_URL=.*$|ALFA_AI_API_URL=http://hub|' \
    -e 's|^LITELLM_BASE_URL=.*$|LITELLM_BASE_URL=http://hub|' \
    "$f"
done
```

### 6.2. Restart each bot/site

```bash
cd /home/operator/rankings-bot
docker compose restart
# …repeat per bot/site
```

### 6.3. Verify from a public endpoint

```bash
curl -fsS https://example.com/api/health | jq '.ai_brain'
# Expect ai_brain.upstream = "http://hub"
```

## Phase 7 — Tear down the brain on `apps` (point of no return)

Only after Phase 6 has been stable for at least a business day.

### 7.1. Stop the old brain stack on `apps`

```bash
# On apps
cd /home/operator/alfa-ai
docker compose -f deploy/docker-compose.yml --env-file deploy/.env down
# Optional: remove the old containers+networks:
docker compose -f deploy/docker-compose.yml --env-file deploy/.env rm -fsv
```

Leaves Postgres, Redis, petals-gateway, petals-worker, and all websites/bots
untouched (they're in separate compose projects).

### 7.2. Free the host ports

Confirm `:8420` and `:4000` are released on `apps`:

```bash
ss -tlnp | grep -E ':8420|:4000'   # no output expected
```

### 7.3. Archive the old deploy `.env` on `apps`

```bash
mv /home/operator/alfa-ai/deploy/.env /home/operator/alfa-ai/deploy/.env.ARCHIVED-brain-on-105-$(date +%F)
```

`apps`'s `deploy/cluster-members/apps/` scripts use `.env.apps` going
forward (apps-only subset, no brain ports).

### 7.4. Update `src/api/worker_monitoring.py` defaults

The hardcoded cluster-host defaults at
[`src/api/worker_monitoring.py`](../src/api/worker_monitoring.py)
`_CLUSTER_HOSTS_DEFAULT` flip:

- `hub` row → Main brain + agent-tier + hub (checks: alfa-ai-api, litellm,
  ollama, registry-mirror).
- `apps` row → Apps host + Petals gateway primary + Petals worker (checks:
  petals-gateway:8013, postgres, redis, petals-worker monitor:31331).

(Change already committed in this same pass — rebuild the brain image or
`docker compose pull` as appropriate.)

## Phase 8 — Post-migration sanity

Run these from a LAN client that is **not** `hub` or `apps`:

```bash
# Brain + routing
curl -fsS http://hub/alfa-ai/admin/health | jq '.status'
curl -fsS http://hub/health/liveliness

# Tier 2 (32B on hub)
curl -fsS http://hub/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" \
  -d '{"model":"agent","messages":[{"role":"user","content":"Draft an email about our status."}],"max_tokens":200}' \
  | jq '.choices[0].message.content'

# Tier 3 (Qwen-72B on 5-node Petals)
curl -fsS http://hub/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" \
  -d '{"model":"frontier","messages":[{"role":"user","content":"Explain SHAP in 2 paragraphs."}],"max_tokens":400}' \
  | jq '.choices[0].message.content'

# Websites
curl -fsS -I https://probilliardssoftware.com
curl -fsS -I https://example.com

# Worker heartbeats flowing into hub's Redis (via apps)
curl -fsS -H "Authorization: Bearer $ALFA_AI_API_TOKEN" \
  http://hub/api/admin/health \
  | jq '.workers[].payload.worker_name, .hosts[] | {name, lan_ip, reachable}'
```

Expected:

- All seven HTTP checks return 200.
- `workers[]` contains `web-sites`, `win11-dockge`, `gaming-worker-b`, `gaming-worker-c`, `gaming-worker-a`.
- `hosts[]` shows `hub` reachable with brain-api/litellm/ollama green,
  `apps` reachable with petals-gateway/postgres/redis/petals-worker green,
  `orchestrator` reachable with dockge + worker-monitor green.

## Rollback (any phase)

| Phase | Rollback |
|-------|----------|
| 1 | Re-add `hub` petals-worker, set `PETALS_INITIAL_PEERS` back on every other worker to `.157`. |
| 2 | Nothing to undo — weights on disk are harmless. |
| 3 | `docker compose down` on `hub`; keep `apps` brain running. |
| 4 | Flip `PETALS_MODEL` back to `codellama/CodeLlama-7b-Instruct-hf` on every worker. |
| 5 | Revert `ALFA_BRAIN_URL` back to `http://apps` on every worker. |
| 6 | Revert bot `.env` from `*.bak-brain-migration`, `docker compose restart`. |
| 7 | `docker compose up -d` the old brain on `apps` using the archived `.env`. |

Nothing between Phase 1 and Phase 6 is destructive; only Phase 7 requires
the `.env` archive dance to resurrect the `apps` brain.

## Related

- [ROADMAP.md](ROADMAP.md) — architecture shift rationale
- [DOCKGE_111_OPERATOR.md](DOCKGE_111_OPERATOR.md) — post-migration brain runbook
- [DOCKGE_105_OPERATOR.md](DOCKGE_105_OPERATOR.md) — post-migration apps host
- [hub_111_NVME_POOL.md](hub_111_NVME_POOL.md) — hot cache storage
- [petals/WORKER_ROLLOUT.md](petals/WORKER_ROLLOUT.md) — worker-side view
- [CLUSTER_SHARED_STORAGE.md](CLUSTER_SHARED_STORAGE.md) — HDD tree
- [NODE_INVENTORY.md](NODE_INVENTORY.md)
