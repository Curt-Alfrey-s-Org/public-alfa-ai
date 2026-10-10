# VM100 — ALFA-AI cluster member

Proxmox VM on **`pve-i5` (`hypervisor`)**. **GTX 1660 Super** passthrough from VM105.

**inference shard only (2026-07-09+):** RAG (embed `:11435` + rerank `:8360`) retired
from this host; since the 2026-07-18 cutover it runs **CPU-only on `rag`** — see
[RAG_148_TO_110_MIGRATION.md](../../../docs/RAG_148_TO_110_MIGRATION.md).
The 1660 Super now runs a single inference `rpc-server` shard on **`:31354`**. Brain +
DB on **`hub`**.

| Fact | Value |
|------|-------|
| LAN IP | `orchestrator` |
| SSH user | `operator` |
| Repo clone | `/home/operator/alfa-ai` (`~/alfa-ai`) |
| vCPU / RAM | 4 / 16 GB |
| Root disk | ~30 GB LVM (Proxmox virtual disk 100 GB) |
| GPU | GTX 1660 Super (NVIDIA driver 595 + nvidia-container-toolkit) |

## Files

| File | Purpose |
|------|---------|
| `deploy-grev27-pool-shard.sh` | **Canonical bring-up** — stops legacy RAG, deploys inference rpc-server shard `:31354` |
| `operator-cluster-100.sh` | **`start-shard`** / `stop-shard` / `status` (canonical operator entry) |
| `stackspool-opt-in.yml` | Manifest: `dockge-agent` only; legacy `alfa-ai-embed` / `alfa-ai-rerank` are `enabled: false` (`repo_root: /home/operator/alfa-ai`) |
| `deploy.sh` | Stack runner (Dockge manifest) |
| `deploy-rag.sh` / `deploy-embed.sh` / `deploy-rerank.sh` | **Legacy** (pre-2026-07-09 RAG on 1660S) — rollback only; refuse to run unless `ALLOW_LEGACY_VM100_RAG=1` |
| `docker-compose.embed-gpu.yml` / `docker-compose.reranker.yml` | Legacy compose stacks (RAG, retired) |
| `.env.embed.example` | Legacy embed + rerank env template |

## Fresh VM bootstrap (45 GB disk)

Proxmox: GPU passthrough (1660S), **CPU type `host`**, static **orchestrator**, user **operator**.

```bash
# On VM100 after Ubuntu + NVIDIA driver + Docker + nvidia-container-toolkit:
bash deploy/cluster-members/pool-shard-opt-in/bootstrap-vm100.sh
```

Or one-liner before clone:

```bash
curl -fsSL https://raw.githubusercontent.com/example/alfa-ai/main/deploy/cluster-members/pool-shard-opt-in/bootstrap-vm100.sh | bash
```

## Local RPC image (permanent — auto-promoted)

**Done on this host (2026-07-16):** tarball at `~/alfa-ai-cache/docker-images/` and
image `alfa-llamacpp-rpc:cuda128` loaded. Shard deploy calls
`ensure-rpc-image-local-cache.sh` so a missing local copy is re-copied from the
hub **once**, then all future loads are local-disk. See
[HUB_ARTIFACTS.md](../../../docs/HUB_ARTIFACTS.md).

## Quick start (repo already present)

```bash
cd ~/alfa-ai && git pull --ff-only origin main
bash deploy/cluster-members/pool-shard-opt-in/operator-cluster-100.sh start-shard
nc -zv 127.0.0.1 31354
```

Scripts resolve the repo root via `SCRIPT_DIR/../../..` — no `ALFA_AI_REPO` override needed when run from `~/alfa-ai`.

Not yet wired into the live coordinator `RPC_BACKENDS` after a fresh deploy — add
the `pool-opt-in` line to `deploy/llamacpp-rpc/inference-shards.env`, regenerate `.env.rpc`
on `hub`, then run one full `Start-Stop-AlfaAi.ps1 stop`/`start` cycle from `orchestrator`
([cluster-start-stop-only](../../../.cursor/rules/cluster-start-stop-only.mdc) —
no piecemeal coordinator restarts).

RAG (embed/rerank) is CPU-only on `rag` — see
[vm110-alfa-ai/README.md](../vm110-alfa-ai/README.md) and
[DOCKGE_110_OPERATOR.md](../../../docs/DOCKGE_110_OPERATOR.md)
(SSoT: `_common/rag-sidecars.env`).

## Docs

**Plan:** [.cursor/plans/VM100_ALFA_AI_MIGRATION.md](../../../.cursor/plans/VM100_ALFA_AI_MIGRATION.md)  
**Operator:** [docs/DOCKGE_100_OPERATOR.md](../../../docs/DOCKGE_100_OPERATOR.md)