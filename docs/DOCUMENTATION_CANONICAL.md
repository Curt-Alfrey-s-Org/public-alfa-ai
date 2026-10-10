# Canonical Git branch and production configuration

**Documentation index:** [INDEX.md](INDEX.md)

This file records **which Git line and which env template** are authoritative for the cluster, and gives an **operator checklist** to confirm production matches the repo.

> **Current model routing (Phase H — 2026-08).** Production chat =
> **Qwen3.6-27B** on the inference llama.cpp RPC mesh (`frontier-code` / `frontier` /
> `fast` / `chat` / … via [deploy/litellm_config.yaml](../deploy/litellm_config.yaml)).
> **Coordinator:** `hub:31360`. **Always-on shards:** `inference` `:31356`/`:31357`,
> `orchestrator` `:31350`, `hub` `:31353`. **Opt-in:** `gaming-a` `:31352`, `gaming-c` `:31351`,
> `gaming-b` `:31358`, `secondary` `:31355`, `pool-opt-in` `:31354` (Start-Stop prompt →
> `inference-shards.active.env`). Embed/RAG on **`rag` CPU** (`:11435` / `:8360`;
> see env.example).
>
> **RETIRED (do not deploy as live):** Petals / Hivemind, Llama-3.3-70B,
> Qwen 35B MoE (`qwen3.6:35b-a3b` / `speed-tier-35b` / Ollama on `orchestrator:11434` as
> chat). Optional revive only via `switch-pool-35b.sh` + commented env block.
> Historical: [docs/history/](history/). SoT:
> [.cursor/plans/FOUR_HOST_FRONTIER_POOL.md](../.cursor/plans/FOUR_HOST_FRONTIER_POOL.md)
> + [GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md).

## Canonical Git line

- **Authoritative branch:** **`main`**
- **NAS pull:** [deploy/cluster-members/hub/deploy.sh](../deploy/cluster-members/hub/deploy.sh) defaults to `GIT_BRANCH="${GIT_BRANCH:-main}"`.

## Single source of truth for routing (committed template)

**[deploy/env.example](../deploy/env.example)** (copy to `deploy/.env` on the brain host `hub`).

Per-host worker / apps templates live under `deploy/cluster-members/<host>/`.

Key variables aligned with [deploy/litellm_config.yaml](../deploy/litellm_config.yaml):

| Variable | Purpose |
|----------|---------|
| `LLAMACPP_CODE27_URL` | inference coordinator OpenAI base (brain → `hub:31360`) |
| `LITELLM_BASE_URL` / `LITELLM_MASTER_KEY` | LiteLLM proxy |
| `DEFAULT_MODEL` / `CHAT_MODELS` | `frontier-code` (+ aliases remapped to 27B) |
| `EMBED_BASE_URL` / `RERANK_BASE_URL` | RAG sidecars (`rag` CPU defaults) |
| `LLAMACPP_35B_URL` | **Retired** — unset unless pool35 revive |
| `PETALS_GATEWAY_*` | **Retired** — do not set |

## Admin Health inventory

See [ADMIN_HEALTH_WEB_WORKFLOW.md](ADMIN_HEALTH_WEB_WORKFLOW.md). Host cards and
inference RPC probes are defined in `src/api/worker_monitoring.py` from
`inference-shards.env` + `inference-shards.gaming.env` (+ `active.env` when synced).

## Production verification checklist (run on `hub`)

1. Confirm `LITELLM_CONFIG=litellm_config.yaml` (or `litellm_config.inference.yaml`) and `ALFA_INFERENCE_MODE=inference`.
2. `curl -fsS http://127.0.0.1:31360/health` — coordinator OK.
3. Admin Health → no `speed-tier-35b` / Petals / 70B probes; inference shards + gaming hosts listed.
4. Redact secrets in any pasted env dumps.
