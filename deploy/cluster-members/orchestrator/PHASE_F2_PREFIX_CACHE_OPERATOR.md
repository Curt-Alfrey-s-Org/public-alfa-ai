# Phase F2 - llama.cpp prefix / slot cache (orchestrator coordinator)

Coordinator flags: `--cache-reuse 256`, `--slot-save-path /slot-cache` (writable volume).

## F2a - Deploy on orchestrator (PowerShell as `operator`)

```powershell
powershell -ExecutionPolicy Bypass -File C:/Users/operator\alfa-ai\deploy\cluster-members\orchestrator\switch-coordinator-profile.ps1 -Profile Chat
powershell -ExecutionPolicy Bypass -File C:/Users/operator\alfa-ai\deploy\cluster-members\orchestrator\deploy-llamacpp-rpc-coordinator.ps1 -Profile Chat
```

122B reload may take 5-15 min after recreate.

## F2b - Acceptance (shared prefix, lower prompt_ms)

From WSL on `orchestrator` after `/health` is OK:

```bash
API=http://127.0.0.1:31360/v1/chat/completions
KEY=change-me
BODY1='{"model":"qwen3.5-122b-a10b","messages":[{"role":"system","content":"You are a terse assistant."},{"role":"user","content":"Reply with one word: alpha"}],"max_tokens":8,"cache_prompt":true}'
BODY2='{"model":"qwen3.5-122b-a10b","messages":[{"role":"system","content":"You are a terse assistant."},{"role":"user","content":"Reply with one word: beta"}],"max_tokens":8,"cache_prompt":true}'
curl -fsS -X POST "$API" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" -d "$BODY1" | tee /tmp/f2-first.json >/dev/null
curl -fsS -X POST "$API" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" -d "$BODY2" | tee /tmp/f2-second.json >/dev/null
grep -o '"prompt_ms":[0-9.]*' /tmp/f2-first.json /tmp/f2-second.json
```

Pass: second `prompt_ms` is clearly lower than the first (prefix reused).
