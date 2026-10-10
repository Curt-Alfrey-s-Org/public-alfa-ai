# Operator console (LAN chat + missions)

Browser UI for **Grok-style chat** (via LiteLLM, server-side key) and **ALFa orchestrator missions** (runs / tasks / process-next). This is **not** rankings-bot website Ask AI or USPBF demo traffic.

## URL

- **Docker (default):** `http://<docker-host-LAN-IP>:8420/operator/`  
  Port **`8420`** maps to the same FastAPI app as **`127.0.0.1:8412`** (see `deploy/docker-compose.yml`).

## Auth

1. Set **`ALFA_AI_API_TOKEN`** and **`ALFA_AI_REQUIRE_API_AUTH=true`** in production.
2. Open the operator page; paste the token → **Save token** (stored in **sessionStorage** for that tab only).
3. All requests send **`Authorization: Bearer <token>`** to `/api/runs*` and `/operator/api/*`.

## Chat

- **`POST /operator/api/chat`** proxies to LiteLLM using **`LITELLM_BASE_URL`** and **`LITELLM_API_KEY`** / **`LITELLM_MASTER_KEY`** from the environment. The browser never sees the LiteLLM master key.
- Model: **`OPERATOR_CHAT_MODEL`** or **`DEFAULT_MODEL`** (e.g. `qwen3.5:27b` — the quality CPU chat default on `gaming-c` per the June 2026 two-host pool; `hub` itself runs **no Ollama** — removed 2026-07-05, `operator_internal` routes to the RPC pool). The May `gaming-c`-only `qwen3:32b` and April `qwen3-coder:30b-a3b-q4_K_M` MoE fleet are **superseded**; sub-frontier aliases fall back to the other CPU host (`orchestrator` `qwen3.6:35b-a3b` speed), then `frontier` (Petals 70B).

## Missions

Uses existing orchestrator endpoints: **`GET /api/runs`**, **`GET /api/runs/{id}`**, **`POST /api/runs`**, **`POST /api/runs/process-next`**.

**Research-only mission** (single researcher task, 27B agent loop):

```json
POST /api/runs
{"goal": "Research FastAPI lifespan vs on_event", "research_only": true}
```

See [AGENT_RESEARCH_TOOLS.md](AGENT_RESEARCH_TOOLS.md) for tools, model routing, and deploy verify steps.

## Security

- **Bind 8420 to LAN only in practice:** use **UFW** (or your firewall) so only your private subnet can reach the host on **8420**.
- Do not expose **8420** to the public Internet without TLS and a hardened auth story.
- **systemd-only** API on **127.0.0.1:8412** does not get the second port; use Docker for LAN console or add a second listen manually.

## Related

- [DISTRIBUTED_AI.md](DISTRIBUTED_AI.md) — LiteLLM / Ollama
- [DEPLOYMENT_BASELINE.md](DEPLOYMENT_BASELINE.md) — Compose
