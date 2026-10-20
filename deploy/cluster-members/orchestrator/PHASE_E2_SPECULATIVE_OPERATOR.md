# Phase E2 - Speculative decoding draft (orchestrator coordinator GPU)

Draft model runs on the **coordinator RTX 3060** via `LLAMA_ARG_*` env vars while the
main frontier model stays on the RPC pool (`N_GPU_LAYERS=0` for chat).

Default draft: **`Qwen2.5-0.5B-Instruct-Q4_K_M.gguf`** (~400 MB).

## E2a - Seed draft GGUF on hub (`hub` only)

One-time download to hub (not on workers). From a shell on **`hub`**:

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/llamacpp-rpc && sudo MODELS_DIR=/mnt/HDDs/Alfa-AI/llama-cpp/models PROFILE=draft bash scripts/fetch-qwen3-coder.sh
```

Verify on hub (same path NFS exports to `inference` as `/mnt/cluster/llama-cpp/models/`):

```bash
ls -lh /mnt/HDDs/Alfa-AI/llama-cpp/models/Qwen2.5-0.5B-Instruct-Q4_K_M.gguf
```

If the HF repo uses a different filename, copy or symlink it to that exact name.

## E2b - Sync to `orchestrator` (PowerShell as `operator`)

```powershell
powershell -ExecutionPolicy Bypass -File C:/Users/operator\alfa-ai\deploy\cluster-members\orchestrator\sync-speculative-draft-gguf-from-hub.ps1
```

## E2c - Enable + redeploy coordinator

```powershell
powershell -ExecutionPolicy Bypass -File C:/Users/operator\alfa-ai\deploy\cluster-members\orchestrator\switch-coordinator-profile.ps1 -Profile Chat -EnableSpeculative
powershell -ExecutionPolicy Bypass -File C:/Users/operator\alfa-ai\deploy\cluster-members\orchestrator\deploy-llamacpp-rpc-coordinator.ps1 -Profile Chat
```

122B reload may take 5-15 min after recreate.

## E2d - Acceptance (tokens/s improves)

After `/health` is OK, compare two identical completions (ignore first warm request):

```bash
API=http://127.0.0.1:31360/v1/chat/completions
KEY=change-me
BODY='{"model":"qwen3.5-122b-a10b","messages":[{"role":"user","content":"List three colors, one per line."}],"max_tokens":32,"temperature":0}'
curl -fsS -X POST "$API" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" -d "$BODY" | tee /tmp/e2-a.json >/dev/null
curl -fsS -X POST "$API" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" -d "$BODY" | tee /tmp/e2-b.json >/dev/null
grep -o '"predicted_ms":[0-9.]*' /tmp/e2-a.json /tmp/e2-b.json
grep -o '"tokens_per_second":[0-9.]*' /tmp/e2-a.json /tmp/e2-b.json
```

Pass: second run shows higher `tokens_per_second` (or lower `predicted_ms`) vs a
baseline taken **before** enabling `-EnableSpeculative` on the same prompt.

Also verify draft loaded:

```powershell
wsl -d Ubuntu docker logs llamacpp-server 2>&1 | Select-String -Pattern "draft|speculative" | Select-Object -Last 10
```

To disable: rerun `switch-coordinator-profile.ps1 -Profile Chat` **without**
`-EnableSpeculative`, then redeploy coordinator.
