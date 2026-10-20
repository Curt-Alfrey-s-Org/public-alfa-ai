# Dockge / operator guide — VM100 (ALFA-AI RAG host)

**Host:** `orchestrator` (Proxmox VM 100 on **`pve-i5` / `hypervisor`**)  
**SSH user:** `operator`  
**Repo path:** `/home/operator/alfa-ai` (`~/alfa-ai`)  
**Current role (2026-09):** **inference opt-in RPC shard only** — GTX 1660 Super, port **`:31354`**. **Not** the live RAG host (RAG is CPU on **`rag`**).  
**Legacy Track B** (embed `:11435` / rerank `:8360` on VM100) is retired in production; sections below are historical unless you are reviving Track B.  
**Brain + DB:** **`hub`** (unchanged).  
**Edge:** **`inference`** → upstream **`hub:8420`** (Jul 2026; retired on `apps`).  
**GPU OC (LACT):** [GPU_OC_LACT_OPERATOR.md](GPU_OC_LACT_OPERATOR.md) — headless `lactd`, optional LAN TCP **`:12853`** (GTK remote, not a browser UI).  
**Plan:** [.cursor/plans/VM100_ALFA_AI_MIGRATION.md](../.cursor/plans/VM100_ALFA_AI_MIGRATION.md)

## What runs here

| Stack | Compose | Port |
|-------|---------|------|
| `alfa-ai-embed` | `vm100-alfa-ai/docker-compose.embed-gpu.yml` | **`:11435`** |
| `alfa-ai-rerank` | `vm100-alfa-ai/docker-compose.reranker.yml` | **`:8360`** |
| `dockge-agent` | `vm100-alfa-ai/docker-compose.dockge-agent.yml` | `:5001` |

**Not on VM100:** brain api/litellm/nginx, postgres, redis, Petals, pool coordinators.

## VM sizing (Track B)

| Resource | Value | Notes |
|----------|-------|-------|
| vCPU | **4** | Sufficient for Ollama embed sidecar |
| RAM | **16 GB** | Sufficient; no brain/LiteLLM/Postgres |
| Proxmox disk | **100 GB** NVMe | Guest may use a smaller LVM root LV |
| Root filesystem | **~30 GB** (operator-extended) | Enough for Docker + one Ollama embed model |

Track B does **not** need the full 100 GB Proxmox disk inside the guest. After embed is stable, optionally shrink the Proxmox virtual disk (e.g. 100 GB → ~40 GB) — not urgent.

## Disk / LVM (operator)

Ubuntu on VM100 may ship with a **small root LV** (e.g. 15 GB) even when Proxmox allocates 100 GB. The first `ollama pull qwen3-embedding:4b` needs several GB free — extend before deploy if `df -h /` shows &lt;10 GB available.

```bash
# Inspect (paths may vary — confirm with lsblk / vgdisplay)
df -h /
sudo vgdisplay
sudo lvs

# Typical extend (adjust VG/LV names to match your install)
sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
sudo resize2fs /dev/ubuntu-vg/ubuntu-lv
df -h /
```

**Status (2026-07-02):** root extended 15 → 30 GB; ~15 GB free after resize.

## GPU prerequisites

Move **1660 Super** passthrough from VM105 → VM100 on Proxmox `hypervisor`, then in the guest:

1. **NVIDIA driver** (operator used **595** series) — `nvidia-smi` must work after reboot.
2. **nvidia-container-toolkit** — Docker must pass GPU to containers.
3. **Smoke test:**

```bash
nvidia-smi
docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi
```

**Status (2026-07-02):** passthrough, driver 595, container toolkit, and Docker GPU smoke — **done**.

## Proxmox CPU type (mandatory for rerank)

Rerank uses `llama-server` from `alfa-llamacpp-rpc:cuda128`. The binary requires **AVX2** in the guest CPU. Proxmox default **qemu64** hides host AVX2 and rerank crash-loops with **SIGILL (exit 132)** immediately after CUDA init.

**Fix (operator, on Proxmox `hypervisor`):**

1. VM100 -> Hardware -> Processors -> **Type: host** (not qemu64 / kvm64).
2. Reboot VM100 guest.
3. Verify in guest: `grep -q avx2 /proc/cpuinfo && echo AVX2_OK`
4. Redeploy: `bash ~/alfa-ai/deploy/cluster-members/pool-shard-opt-in/deploy-rerank.sh`

`deploy-rerank.sh` calls `preflight-cpu-avx2.sh` and fails fast with this message if AVX2 is missing. Embed (Ollama) works without AVX2; rerank does not.

Official rerank flags: [llama.cpp PR #9510](https://github.com/ggml-org/llama.cpp/pull/9510) (`--reranking` / `--embedding --pooling rank` for BGE reranker GGUF).

## First-time setup

```bash
git clone <origin> ~/alfa-ai
cd ~/alfa-ai && git pull --ff-only origin main

cp deploy/cluster-members/pool-shard-opt-in/.env.embed.example \
   deploy/cluster-members/pool-shard-opt-in/.env.embed

cp deploy/cluster-members/pool-shard-opt-in/env.dockge.example \
   deploy/cluster-members/pool-shard-opt-in/.env.dockge

hub_IP=orchestrator bash scripts/mount_nfs_models.sh
```

## Canonical start (daily)

Use the operator script — it `git pull`s, then runs `deploy-rag.sh` (embed + rerank):

```bash
bash ~/alfa-ai/deploy/cluster-members/pool-shard-opt-in/operator-cluster-100.sh start-rag
```

`REPO_DIR` is auto-detected from the script location (`../../..` → repo root). Override only if needed: `ALFA_AI_REPO=/path/to/alfa-ai`.

During a full cluster start, the `orchestrator` orchestrator runs this via `start-rag-sidecars.sh` after the inference coordinator is healthy.

Lower-level one-shot (same as `start-rag` without pull):

```bash
bash deploy/cluster-members/pool-shard-opt-in/deploy-rag.sh
```

On **`hub`** after RAG is healthy (normally set by `switch-pool-27b.sh` on `start-pool`):

```bash
# deploy/.env
EMBED_BASE_URL=http://orchestrator
RERANK_BASE_URL=http://orchestrator

cd /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy
sudo docker compose --env-file .env -f docker-compose.yml up -d --force-recreate alfa-ai-litellm
```

## Daily commands

```bash
bash ~/alfa-ai/deploy/cluster-members/pool-shard-opt-in/operator-cluster-100.sh start-rag
bash ~/alfa-ai/deploy/cluster-members/pool-shard-opt-in/operator-cluster-100.sh stop-rag
bash ~/alfa-ai/deploy/cluster-members/pool-shard-opt-in/operator-cluster-100.sh status
# Legacy embed-only:
bash ~/alfa-ai/deploy/cluster-members/pool-shard-opt-in/operator-cluster-100.sh start-embed
```

## Tear down mistaken Track A stacks on VM100

If brain/postgres/redis were started on VM100 during Track A testing:

```bash
cd ~/alfa-ai/deploy
sudo docker compose --env-file .env -f docker-compose.yml down
sudo docker compose --env-file .env -f docker-compose.postgres.yml down
sudo docker compose --env-file .env -f docker-compose.redis.yml down
```

Canonical brain + DB remain on **`hub`**.

**Status (2026-07-02):** Track A brain/postgres/redis stacks — **torn down**.

## Health checks

```bash
curl -fsS http://127.0.0.1:11435/api/tags
curl -fsS http://127.0.0.1:8360/health
curl -fsS http://hub/health
```

## Migration status (2026-07-02)

| Step | Status |
|------|--------|
| GPU passthrough VM105 → VM100 | Done |
| NVIDIA driver + container toolkit | Done |
| Root disk extended to ~30 GB | Done |
| Track A brain/postgres/redis removed | Done |
| `.env.embed` created | Done |
| Embed deploy (`start-embed`) | **Done** — `qwen3-embedding:4b` on `:11435` |
| Rerank deploy (`deploy-rerank.sh`) | **Blocked until Proxmox CPU type = host** (AVX2); then `:8360/health` mandatory |
| `hub` `EMBED_BASE_URL` → `pool-opt-in:11435` | **Done** — `alfa-ai-litellm` recreated |
| `apps` old embed stopped | **Done** — `docker-compose.embed-gpu.yml down` |

**Track B cutover complete (2026-07-02).** Optional later: shrink Proxmox VM100 virtual disk (100 GB → ~40 GB).

## NFS hub mount

hub NFS VIP **`orchestrator/32`** lives on **`br1`** (same L2 as mgmt **`hub`**). Prefer **`storage`** when nfsd binds it; **`hub` is a valid fallback** on the same bridge ([hub_111_10G_NIC.md](hub_111_10G_NIC.md)). If one IP refuses NFS, try the other before assuming nfsd is down.

```bash
bash ~/alfa-ai/scripts/mount_nfs_models.sh
# default hub_IP=storage; script falls back to hub on same L2
```

Embed works without NFS (models on local disk); mount is for hub-backed `/mnt/cluster` policy.

## Related

- [DOCKGE_111_OPERATOR.md](DOCKGE_111_OPERATOR.md) — brain operator
- [DOCKGE_105_OPERATOR.md](DOCKGE_105_OPERATOR.md) — apps host (postgres/bots; edge moved to `inference`)
- [apps-105/deploy-rag-embed.sh](../deploy/cluster-members/apps/deploy-rag-embed.sh) — prior embed on VM105
- [vm100-alfa-ai/README.md](../deploy/cluster-members/pool-shard-opt-in/README.md) — member folder index