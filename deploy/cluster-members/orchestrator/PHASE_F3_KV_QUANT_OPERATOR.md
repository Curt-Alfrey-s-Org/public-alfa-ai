# Phase F3 - KV-cache quantization + larger context (orchestrator coordinator)

Coordinator flags: `--cache-type-k q8_0`, `--cache-type-v q8_0`, `CTX_SIZE=65536` (was 32768).

## F3a - Deploy on orchestrator (PowerShell as `operator`)

```powershell
powershell -ExecutionPolicy Bypass -File C:/Users/operator\alfa-ai\deploy\cluster-members\orchestrator\switch-coordinator-profile.ps1 -Profile Chat
powershell -ExecutionPolicy Bypass -File C:/Users/operator\alfa-ai\deploy\cluster-members\orchestrator\deploy-llamacpp-rpc-coordinator.ps1 -Profile Chat
```

122B reload may take 5-15 min after recreate.

## F3b - Acceptance (65536 ctx, no OOM)

After `/health` is OK:

```powershell
curl.exe -fsS http://127.0.0.1:31360/health
```

```powershell
wsl -d Ubuntu docker logs llamacpp-server 2>&1 | Select-String -Pattern "n_ctx|cache-type|out of memory|OOM" | Select-Object -Last 15
```

Pass:

- `/health` returns `{"status":"ok"}`.
- Logs show `n_ctx = 65536` (or `n_ctx_seq (65536)`).
- No GGML out-of-memory during warm-up.
- Optional: one short completion succeeds:

```bash
curl -fsS -X POST http://127.0.0.1:31360/v1/chat/completions \
  -H "Authorization: Bearer change-me" -H "Content-Type: application/json" \
  -d '{"model":"qwen3.5-122b-a10b","messages":[{"role":"user","content":"Say hi in one word."}],"max_tokens":4}'
```

If OOM at 65536, lower `CTX_SIZE` in `switch-coordinator-profile.ps1` (try 49152) or use `CACHE_TYPE_K=q4_0`.
