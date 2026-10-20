# `ai-148` — 27B RPC pool GPU host (Ubuntu Linux)

## Role

**Phase H (Jul 2026):** **27B RPC pool GPU shards** — **3060** `:31356` + **5060**
`:31357`. CPU coordinator **`:31360`** runs on **`hub`** (brain host).

**RAG moved here 2026-07-09** (CPU-only, GPUs stay reserved for the shards):
**embed `:11435`** + **rerank `:8360`** — see
[.cursor/plans/RAG_248_VM100_SHARD.md](../../../.cursor/plans/RAG_248_VM100_SHARD.md).
Retired the legacy GPU-based rerank sidecar (`docker-compose.reranker-3050.yml`)
and VM100's GPU embed/rerank (VM100's 1660 Super is now a inference shard, `:31354`).

**Cluster hub (Jul 2026):** Orchestrator runs shard verify, RAG verify, SSH jump to `hub`,
and **edge proxy `:8420`** from this host (migrated off `apps` apps host).

Petals worker optional when GPUs are idle.

**SSH:** **`operator@orchestrator`**. Repo: **`~/alfa-ai`**.

## Hardware (2026-07-03 live `nvidia-smi`)

| Field | Value |
|-------|-------|
| Hostname | **ai-148** |
| Board | **Gigabyte Z390 AORUS PRO** |
| CPU | Intel **i7-9700K** 8c/8t |
| RAM | **48 GiB** (2×16 + 2×8 GiB DDR4-2133; re-verified 2026-07-09 — unchanged) |
| GPU 0 | **NVIDIA GeForce RTX 5060** 8 GB (Blackwell) → pool shard **`:31357`** |
| GPU 1 | **NVIDIA GeForce RTX 3060** 12 GB LHR → pool shard **`:31356`** |
| OS | **Ubuntu 26.04 LTS** |
| LAN | **`bond0` = `orchestrator/24`**; USB **`orchestrator/32`** (data plane, table 101). Cabinet cabled via **`hub`** — run [`setup-dual-ip-data-plane.sh`](setup-dual-ip-data-plane.sh), not LACP-to-AXE300 until cabling changes ([AI148_NIC_MAX_USE.md](../../../docs/AI148_NIC_MAX_USE.md), [LAN_ISLAND_GATEWAY_OUTAGE.md](../../../docs/LAN_ISLAND_GATEWAY_OUTAGE.md)) |
| Pool ports | **`:31356`**, **`:31357`** (no coordinator on this host) |

Full inventory: [docs/NODE_INVENTORY.md](../../../docs/NODE_INVENTORY.md).

**GPU overclock / power (LACT):** headless daemon + optional LAN TCP **`:12853`**
(GTK remote, not HTTP). Presets and safety: [docs/GPU_OC_LACT_OPERATOR.md](../../../docs/GPU_OC_LACT_OPERATOR.md).

## Hub one-time setup (after `apps` migration)

**Git without GitHub (hub NFS):** when WAN/DNS is down, orchestrator uses
[`sync-git-origin-hub-lan.sh`](../_common/sync-git-origin-hub-lan.sh) or set
`origin` to `file:///mnt/cluster/repo/alfa-ai/.git` — [LAN_ISLAND_GATEWAY_OUTAGE.md](../../../docs/LAN_ISLAND_GATEWAY_OUTAGE.md).

```bash
cd ~/alfa-ai && git pull --ff-only origin main
# SSH jump to hub (orchestrator keep-warm + log collect):
test -f ~/.ssh/id_ed25519_cluster || echo 'Copy cluster key from inference ansible:~/.ssh/'
ssh -o BatchMode=yes -i ~/.ssh/id_ed25519_cluster operator@hub echo OK
# Edge (first start brings this up; stop legacy on apps manually if still running):
# bash deploy/cluster-members/_common/start-edge-api.sh
```

 bound 2026-07-05 (`sudo  up --hostname=ai-148`, official
[ Linux install](https://.com/docs/install/linux)): node
**`ai-148`**, IP **`100.112.43.57`**. Baked into `Invoke-AlfaAiCluster.ps1`'s
default; override on `orchestrator` only if `inference` gets re-bound to a new  IP:
`$env:ALFA_EDGE__LOGIN_URL = 'http://<148-ts-ip>:8420/alfa-ai/login'`

## inference deploy (shards only)

```bash
cd ~/alfa-ai && bash deploy/cluster-members/inference-coordinator/deploy-grev27-pool-shard.sh
```

Staggered startup: 3060 first, **20s** pause (`inference_SHARD_STAGGER_SEC`), then 5060.
See [docs/inference_RPC_RELIABILITY.md](../../../docs/inference_RPC_RELIABILITY.md).

**Retired on inference:** CPU coordinator `:31360`, local dual-GPU `:31358`, GPU rerank
(`docker-compose.reranker-3050.yml`).

## CPU RAG deploy (embed + rerank)

```bash
cd ~/alfa-ai && bash deploy/cluster-members/inference-coordinator/deploy-rag-cpu.sh
curl -fsS http://127.0.0.1:11435/api/tags
curl -fsS http://127.0.0.1:8360/health
```

Canonical `EMBED_HOST`/`RERANK_HOST` in
[`_common/rag-sidecars.env`](../_common/rag-sidecars.env); orchestrator starts/stops
via `start-rag-sidecars.sh` / `stop-rag-sidecars.sh` (`HOST_LABEL=148`).

## Petals worker (optional)

```bash
bash ~/alfa-ai/deploy/cluster-members/inference-coordinator/deploy.sh
```

Mutual exclusion with inference — stop Petals before pool shard deploy.

## Related

- [docs/GREV27_27B_OPERATOR.md](../../../docs/GREV27_27B_OPERATOR.md)
- [docs/CLUSTER_START_STOP_OPERATOR.md](../../../docs/CLUSTER_START_STOP_OPERATOR.md)