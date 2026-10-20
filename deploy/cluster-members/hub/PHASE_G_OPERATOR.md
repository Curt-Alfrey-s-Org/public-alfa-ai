# Phase G operator runbook (hub brain)

Phase G GPU tier replan. SSoT: `.cursor/plans/FOUR_HOST_FRONTIER_POOL.md` Phase G.

## G2 — rpc-server on RTX 5060 (:31353) for 27B code pool

On `hub` (OTP SSH):

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai
git pull --ff-only origin main
sudo bash deploy/cluster-members/hub/deploy-llamacpp-rpc-shard.sh
nc -zv 127.0.0.1 31353
```

From `orchestrator`:

```powershell
Test-NetConnection hub -Port 31353
```

## LiteLLM — recreate after litellm_config.yaml Phase G changes

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy
grep -q OLLAMA_FLEET_148 .env 2>/dev/null || echo 'OLLAMA_FLEET_148_URL=http://orchestrator' >> .env
sudo docker compose --env-file .env -f docker-compose.yml up -d --force-recreate alfa-ai-litellm
bash /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/cluster-members/_common/wait-litellm-liveliness.sh 180
```

## Hub — b8352 RPC image (published from orchestrator)

Tarball on hub NFS/SMB:

```text
/mnt/HDDs/Alfa-AI/docker-images/alfa-llamacpp-rpc-cuda128-b8352.tar.gz
\\hub\docker-images\alfa-llamacpp-rpc-cuda128-b8352.tar.gz
```

Reload on `hub` when rpc version mismatch (`Expected HELLO command`):

```bash
sudo docker load -i /mnt/HDDs/Alfa-AI/docker-images/alfa-llamacpp-rpc-cuda128-b8352.tar.gz
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/llamacpp-rpc
sudo docker compose --env-file .env.rpc -f docker-compose.rpc-server.yml up -d --no-build --force-recreate
nc -zv 127.0.0.1 31353
```

## G3 — remove retired tags on hub CPU Ollama (:11434) — DONE 2026-07-05

Superseded: the Ollama App on `hub` was removed entirely (not just the
retired tags) since nothing routes to it anymore. `remove-ollama-qwen3-4b-8b.sh`
is now a no-op on `hub` (kept for `gaming-c`/`orchestrator`, which still run Ollama).

## G1 — remove qwen3.5:27b on gaming-c (when gaming-worker-c is up)

From `gaming-c` (PowerShell):

```powershell
powershell -ExecutionPolicy Bypass -File C:\alfa-ai-worker\deploy\cluster-members\_common\remove-ollama-qwen3-4b-8b.ps1
```

(Hub keeps `qwen3.5:27b` blob.)
