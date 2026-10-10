# Phase D - LiteLLM frontier wire (hub) + rpc-server b8352

Run on **hub shell as `operator`** (SSH requires OTP). One command per step;
paste output back before the next.

Prerequisites on `hub`:

- Repo: `/mnt/HDDs/Alfa-AI/repo/alfa-ai` (or your canonical clone path)
- Coordinator healthy: `curl -fsS http://orchestrator/health`
- Hub tarball staged: `\\hub\temp\cluster_members\_common\docker-images\alfa-llamacpp-rpc-cuda128-b8352.tar.gz`

## D0 - Upgrade `hub` rpc-server to b8352 (required before re-adding `:31353`)

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/llamacpp-rpc && docker load -i /mnt/HDDs/Alfa-AI/docker-images/alfa-llamacpp-rpc-cuda128-b8352.tar.gz
```

(If tarball is only on SMB, copy once: `cp /mnt/HDDs/Alfa-AI/temp/cluster_members/_common/docker-images/alfa-llamacpp-rpc-cuda128-b8352.tar.gz /tmp/` then `docker load -i /tmp/alfa-llamacpp-rpc-cuda128-b8352.tar.gz`.)

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/llamacpp-rpc && docker compose --env-file .env.rpc -f docker-compose.rpc-server.yml up -d --force-recreate --no-build
```

```bash
nc -zv 127.0.0.1 31353
```

Then on **`orchestrator` (operator)**, add `hub` to `RPC_BACKENDS` in
`deploy/llamacpp-rpc/.env.rpc` and recreate the coordinator:

```powershell
powershell -ExecutionPolicy Bypass -File C:/Users/operator\alfa-ai\deploy\cluster-members\orchestrator\deploy-llamacpp-rpc-coordinator.ps1
```

## D1 - Set `LLAMACPP_FRONTIER_URL` in brain `deploy/.env`

Ensure this line exists (add or replace `LLAMACPP_RPC_URL`):

```env
LLAMACPP_FRONTIER_URL=http://orchestrator/v1
```

Template: `deploy/env.example` (already documents the value).

## D2 - Reload LiteLLM

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai && bash deploy/cluster-members/hub/deploy.sh
```

Or LiteLLM-only:

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai && sudo docker compose --env-file deploy/.env -f deploy/docker-compose.yml up -d --force-recreate alfa-ai-litellm
```

```bash
bash deploy/cluster-members/_common/wait-litellm-liveliness.sh 120
```

## D3 - Acceptance

```bash
curl -fsS -H "Authorization: Bearer $LITELLM_MASTER_KEY" http://127.0.0.1:8413/v1/models | grep -E 'frontier|qwen3'
```

```bash
curl -fsS --max-time 300 -X POST http://127.0.0.1:8413/v1/chat/completions -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" -d '{"model":"frontier","messages":[{"role":"user","content":"Say OK in one word."}],"max_tokens":8,"temperature":0.1}'
```

Expect routing to `orchestrator:31360` (not Petals) while coordinator is healthy. Allow 2-4
minutes for first token on the pooled 122B MoE.
