# gaming-worker-b (gaming-b) — Ollama embedding cold-standby + CPU reranker (planned)

> **2026-06-17 update:** embed model is now **`qwen3-embedding:4b`** (replaces
> `nomic-embed-text` — **re-embed corpora on switch**) and the reranker is
> **`Qwen3-Reranker-0.6B`** (replaces `bge-reranker-v2-m3`), family-matched to the
> embedder. The reranker is **NOT served by Ollama** (Ollama has no rerank
> endpoint) — run it as a **TEI / Infinity / llama.cpp sidecar**. See
> [ROADMAP.md § "Operator-selected models (2026-06-17)"](../../../docs/ROADMAP.md#operator-selected-models-2026-06-17--confirmed).

April 2026 cluster rebalance. Primary embedding host is **`gaming-c` gaming-worker-c**
(**`qwen3-embedding:4b`** via Ollama, `EMBED_BASE_URL=http://orchestrator`).
`gaming-b` keeps the same tag installed but the embed service is **cold-standby** — it
only comes up during a `gaming-c` outage.

**CPU reranker (planned):** `gaming-b` will host **`Qwen3-Reranker-0.6B`** (~0.6 GB)
for RAG chunk ranking via a **sidecar** (TEI/Infinity/llama.cpp) — **not** Ollama,
and **not** a duplicate chat LLM. Research chose `gaming-b` over the dense chat host
because `gaming-c` has the faster CPU (i7-12700 12c vs i7-11700 8c) and owns the
quality LLM role. See [README.md](./README.md) § CPU reranker plan.

**Retired from this host (planned):** `qwen3-coder:30b-a3b-q4_K_M` MoE (~18 GB) —
four-host MoE redundancy is replaced by **`gaming-c` quality** + **`hub`/`orchestrator` speed**.

Why `gaming-c` primary for embed (unchanged):

- `gaming-c` i7-12700 (12c/20t, DDR4) has more CPU headroom than `gaming-b` i7
  11th gen (8c/16t), and its GPU is already fully claimed by the Petals
  swarm and the llama.cpp RPC shard.
- `gaming-b` is the llama.cpp RPC **coordinator** (`:31360`) — adding an
  embedding workload there competes for the same 12 GB 5070 and CPU/net
  I/O during frontier-code turns.
- Keeping the model on `gaming-b` disk makes failover a single `ollama
  serve` command without a fresh pull.

## One-time install (run once on `gaming-b`)

```powershell
# From an Administrator PowerShell on gaming-b (Windows 11 + WSL2).
# Current: embed cold-standby only.
ollama pull qwen3-embedding:4b
# Planned: Qwen3-Reranker-0.6B GGUF/weights on hub — served via a TEI/Infinity/
# llama.cpp sidecar when RAG lands (NOT `ollama pull`).
# Verify.
ollama list
```

`gaming-b` runs **no chat LLM** — do not pull `qwen3.5:27b` / `qwen3.6:35b-a3b` here.

## Failover to `gaming-b` (when `gaming-c` is down)

1. On `gaming-b`: start Ollama and verify the embed model responds.

   ```powershell
   ollama serve  # or: Start-Service ollama
   curl -s http://127.0.0.1:11434/api/tags | Select-String 'nomic-embed-text'
   ```

2. On `hub` (brain): flip `EMBED_BASE_URL` in `deploy/.env` and bounce
   LiteLLM only:

   ```bash
   cd /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy
   sed -i 's|^EMBED_BASE_URL=.*|EMBED_BASE_URL=http://orchestrator|' .env
   docker compose up -d alfa-ai-litellm
   ```

3. Smoke:

   ```bash
   curl -s -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
     -H 'Content-Type: application/json' \
     -d '{"model":"embed","input":"hello"}' \
     http://127.0.0.1:8413/v1/embeddings | head -c 200
   ```

## Failback to `gaming-c`

Reverse step 2 (`EMBED_BASE_URL=http://orchestrator`), bounce
LiteLLM, smoke, then stop Ollama on `gaming-b` again.

## Related

- [deploy/cluster-members/_common/pull-models.sh](../_common/pull-models.sh)
  (roles will gain `quality` / `reranker` when cutover is wired).
- [docs/ROADMAP.md](../../../docs/ROADMAP.md) "Cluster rebalance" and
  supporting models (`bge-reranker-v2-m3`).
- [docs/NODE_INVENTORY.md](../../../docs/NODE_INVENTORY.md) — CPU fleet topology.
- [gaming-worker-c-59/README.md](../gaming-worker-c-59/README.md) — CPU quality LLM on `gaming-c`.
