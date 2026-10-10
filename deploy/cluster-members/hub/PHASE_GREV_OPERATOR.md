# Phase G-rev / Phase H operator (hub brain)

**Phase H (27B):** coordinator on **`inference` RTX 3050 `:31360`** — `hub` is **rpc-server shard `:31353` only** (CPU freed).
**35B MoE** coordinator stays **`hub` CPU `:31360`** when 27B stopped.

Runbook: [GREV27_27B_OPERATOR.md](../../docs/GREV27_27B_OPERATOR.md) (coordinator steps on `inference`).

## Prerequisites

1. Hub GGUF: `Qwen3.6-27B-Q4_K_M.gguf` and `Q4_K_M/Qwen3.6-35B-A3B-Q4_K_M-*.gguf`
   under `/mnt/HDDs/Alfa-AI/llama-cpp/models/` (fetch on `hub`:
   `PROFILE=code` / `PROFILE=moe35` in `deploy/llamacpp-rpc/scripts/fetch-qwen3-coder.sh`).
2. Hub image: `alfa-llamacpp-rpc-cuda128-b8352-single.tar.gz` loaded on `hub`, `apps`, `orchestrator`, `inference`.
3. RPC shards up: `orchestrator:31350`, `apps:31354`, `hub:31353`, `inference:31356`, `inference:31357`.
4. Stop LiteLLM during first pool load (900s timeout).

## G-rev2 — coordinator on `hub`

**From `hub` (hub shell as `operator`):**

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai && git pull --ff-only origin main
```

```bash
sudo bash deploy/cluster-members/hub/deploy-grev35-coordinator.sh
```

```bash
bash deploy/cluster-members/_common/wait-http.sh http://127.0.0.1:31360/health 900
```

## G-rev3 — LiteLLM env + recreate

Add to `deploy/.env` on `hub`:

```
LLAMACPP_35B_URL=http://hub/v1
LLAMACPP_CODE27_URL=http://orchestrator/v1
```

**Prerequisites:** **`alfa-ai-redis`** and **`alfa-ai-postgres`** must be running
before LiteLLM (cache + Prisma). Piecemeal `--force-recreate alfa-ai-litellm` alone
fails if either backing service is down.

After pool coordinator is healthy:

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy && sudo docker compose --env-file .env up -d alfa-ai-redis alfa-ai-postgres
```

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy && sudo docker compose --env-file .env up -d --force-recreate alfa-ai-litellm
```

```bash
bash /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/cluster-members/_common/wait-litellm-liveliness.sh 120
```

## Verify

```bash
curl -fsS http://127.0.0.1:8413/v1/models | grep -E 'qwen3.6-27b|qwen3.6-35b'
```
