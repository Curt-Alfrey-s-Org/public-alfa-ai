# Phase E - RAG sidecars on hub (embed GPU + rerank llama-server)

Run on **hub shell as `operator`** (SSH requires OTP). One command per step.

Prerequisites:

- Repo: `/mnt/HDDs/Alfa-AI/repo/alfa-ai`
- Hub rerank GGUF (required): `/mnt/HDDs/Alfa-AI/models/downloads/reranker/Qwen3-Reranker-0.6B.Q4_K_M.gguf`
- Seed on `hub` if missing: `sudo bash scripts/seed-qwen3-reranker-gguf-hub.sh`
- `alfa-llamacpp-rpc:cuda128` image loaded (same as rpc-server b8352 tarball)

## E1a - Deploy sidecars

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai && git pull --ff-only origin main
sudo bash deploy/cluster-members/hub/deploy-rag-sidecars.sh all
```

## E1b - Point LiteLLM at always-on endpoints

Add or replace in `deploy/.env`:

```env
EMBED_BASE_URL=http://host.docker.internal:11435
RERANK_BASE_URL=http://hub
```

Embed sidecar must publish `:11435` on all interfaces (not `127.0.0.1` only). See
`docker-compose.embed-gpu.yml` ports mapping `11435:11434`.

Recreate LiteLLM:

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai && sudo docker compose --env-file deploy/.env -f deploy/docker-compose.yml up -d --force-recreate alfa-ai-litellm
bash deploy/cluster-members/_common/wait-litellm-liveliness.sh 120
```

## E1c - Acceptance

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai && set -a && . deploy/.env && set +a
curl -fsS -H "Authorization: Bearer $LITELLM_MASTER_KEY" http://127.0.0.1:8413/v1/models | grep -E 'embed|rerank'
curl -fsS --max-time 120 -X POST http://127.0.0.1:8413/v1/embeddings -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" -d '{"model":"embed","input":"hello world"}'
```

Rerank smoke depends on LiteLLM rerank route wiring for the loaded GGUF alias.
