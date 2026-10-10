# Contracts-bot + ALFa AI integration performance (official sources)

**Scope:** Speed and reliability for contracts-bot consuming `qwen3.6-27b` via LiteLLM
during G-rev27 RPC pool mode (coordinator `hub:31360`).

## Official references

| Topic | URL |
|-------|-----|
| LiteLLM `/health/liveliness` (no LLM call) | https://docs.litellm.ai/docs/proxy/health |
| LiteLLM cooldown / `allowed_fails` | https://docs.litellm.ai/docs/routing |
| LiteLLM `allowed_fails_policy` | https://docs.litellm.ai/docs/proxy/health_check_routing |
| LiteLLM proxy retries / 429 | https://docs.litellm.ai/docs/proxy/load_balancing |
| OpenAI-compatible backend | https://docs.litellm.ai/docs/providers/openai_compatible |
| llama.cpp RPC | https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md |
| llama-server `/health` 503 while loading | https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md |

## Corrected assumptions (2026-06-29 audit)

1. **`allowed_fails: 1`** cools down on the **2nd** failure in the window, not the 1st
   (LiteLLM health-check routing docs: cooldown when `updated_fails > allowed_fails`).
2. **429 cooldown** at router default is **5 seconds** per deployment; our **`cooldown_time: 120`**
   applies after crossing `allowed_fails`. Client-side retries on 429 **stack** on proxy retries
   (default `num_retries: 3`) and worsen cooldown storms.
3. **`/health/liveliness`** is for **container liveness** only — not model inference readiness
   (LiteLLM health docs). contracts-bot must not use chat completions on every header poll.
4. **Coordinator `/health` 503** while model loads is official llama-server behavior; wait for 200
   before queue drain (`docs/GREV27_27B_OPERATOR.md`).

## Implementation plan

### Phase A — contracts-bot (`apps`)

| Change | Rationale |
|--------|-----------|
| Brain `LITELLM_CONFIG=litellm_config.inference.yaml` via `switch-pool-27b.sh` | `/v1/models` lists only 27B + embed/rerank during pool production |
| Readiness = liveliness + model listed + not in 429 cooldown + recent successful completion | LiteLLM liveliness docs; avoid chat probe on 5s UI poll |
| Do **not** retry HTTP 429 in `litellm_client` | Avoid amplifying proxy cooldown (load balancing docs) |
| Queue analyze: **one prompt** (3 sections) when `from_queue=True` | Cuts RPC round trips ~3x; inference coordinator `PARALLEL=10` (ten slots) |
| Header poll 60s when degraded, 5s when online | Less probe traffic during recovery |
| Worker pauses drain during client 429 cooldown | Prevents failed-job churn |

Env (`apps` `contracts-bot` `.env`):

```env
CONTRACT_AI_PROBE_USE_CHAT=false
CONTRACT_AI_INFERENCE_SUCCESS_TTL_SEC=900
CONTRACT_AI_QUEUE_BATCH_SIZE=1
LITELLM_CONTRACT_TIMEOUT=600
CONTRACT_AI_QUEUE_STEP_TIMEOUT_SEC=600
CONTRACT_AI_QUEUE_ITEM_TIMEOUT_SEC=660
CONTRACT_AI_FALLBACK_ENABLED=false
```

### Phase B — alfa-ai LiteLLM (`hub` operator)

| Change | Rationale |
|--------|-----------|
| `allowed_fails_policy` with higher `TimeoutErrorAllowedFails` for slow RPC | health_check_routing docs |
| Fix comment: `allowed_fails: 1` = 2nd failure triggers cooldown | config accuracy |
| `retry_policy.RateLimitErrorRetries: 0` on router (optional tighten) | Reduce proxy 429 retry pile-up |

**Operator Step — From `hub` (operator):** after `git pull`, recreate LiteLLM only when
Postgres/Redis healthy (see `deploy/cluster-members/hub/start-brain` pattern).

### Phase C — Verify

1. `bash scripts/smoke-grev27-litellm-chat.sh` on `apps` -> 200
2. `curl http://127.0.0.1:8002/api/health/connectivity` -> `contract_ai_ready: true`
3. Queue `pending` count decreases over 30 min; no 429 storm in API logs

## Out of scope

- Petals `frontier` fallback for contracts (cluster paused).
- 35B fallback during 27B pool (mutual exclusion unchanged).
