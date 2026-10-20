# VM110 — ALFA-AI RAG sidecar host

Dedicated **CPU embed + rerank** (same stack as `inference` today). **No inference shard.**

| Fact | Value |
|------|-------|
| LAN IP | `orchestrator` |
| SSH user | `operator` |
| Repo clone | `/home/operator/alfa-ai` |
| Embed | `:11435` (`alfa-ai-embed-ollama`) |
| Rerank | `:8360` (`alfa-ai-reranker`) |
| Disk | Root LV is ~15G; models bind from NFS (not `~/alfa-ai-cache`) |

**Production cutover:** [docs/RAG_148_TO_110_MIGRATION.md](../../../docs/RAG_148_TO_110_MIGRATION.md)  
**Operator:** [docs/DOCKGE_110_OPERATOR.md](../../../docs/DOCKGE_110_OPERATOR.md)

## Files

| File | Purpose |
|------|---------|
| `bootstrap-vm110.sh` | Fresh guest: clone, NFS, start RAG |
| `operator-cluster-110.sh` | `start-rag` / `stop-rag` / `status` |
| `deploy-rag-cpu.sh` | Canonical RAG deploy |
| `docker-compose.embed-cpu.yml` | Ollama CPU embed |
| `docker-compose.reranker-cpu.yml` | llama-server CPU rerank (official ghcr image, no NVIDIA) |
| `install-agent-ssh-from-93.sh` | One-time SSH pubkey for `orchestrator` agent |

## Quick start

```bash
cd ~/alfa-ai && git pull --ff-only origin main
bash deploy/cluster-members/rag-host/operator-cluster-110.sh start-rag
```

Orchestrator uses `HOST_LABEL=110` + `start-rag-sidecars.sh` after Phase C cutover only.
