# Distributed AI Cluster

> **PRIMARY WORKING SET (2026-08) — llama.cpp RPC only.** Always-on inference core:
> **`inference` / `orchestrator` / `hub`**. **inference opt-in:** **`gaming-a` / `gaming-c` / `gaming-b` /
> `secondary` / `pool-opt-in`** (prompted at each `Start-Stop-AlfaAi.ps1 start`; never
> required for core green). Max with **`gaming-a`+`secondary`+`pool-opt-in`**: ~**60 GB** physical /
> **52 GB** `-ts`; all five opt-in: **70 GB** `-ts`. **Retired:** 30B coder, 35B MoE, Llama-3.3-70B (Petals), qwen3:8b.
> **Petals/Hivemind retired** (history:
> [history/ARCHIVED_PETALS_PRE_QWEN3_FLIP.md](history/ARCHIVED_PETALS_PRE_QWEN3_FLIP.md)).
> Plan: [.cursor/plans/FOUR_HOST_FRONTIER_POOL.md](../.cursor/plans/FOUR_HOST_FRONTIER_POOL.md).

Private multi-node GPU cluster serving the Qwen3 tier matrix
(see [QWEN3_MIGRATION.md](QWEN3_MIGRATION.md)). **Official Qwen3 lineup and
Transformers requirements:** [QWEN3_MIGRATION.md § Official sources](QWEN3_MIGRATION.md#official-sources-single-source-of-truth).
**Vendor-published accuracy proxies vs this stack:** [MODEL_FIT_AUDIT.md](MODEL_FIT_AUDIT.md).

**Current engine (inference core + opt-in hosts):**

- **llama.cpp RPC frontier pool** - CPU coordinator `llama-server` on **`hub:31360`**
  dials always-on GPU `rpc-server` shards: `inference` RTX 3060 `:31356` + RTX 5060 `:31357`,
  `orchestrator` RTX 3060 `:31350`, `hub` RTX 3050 `:31353` (**`TENSOR_SPLIT` 35.0 GB**;
  core `12,8,10,5`).
  **inference opt-in:** `gaming-a` `:31352`, `gaming-c` `:31351`, `gaming-b` `:31358`, `secondary`
  `:31355`, `pool-opt-in` `:31354` — `gaming-a`+`secondary`+`pool-opt-in`: **`52.0 GB` `-ts` /
  ~60 GB physical** (`12,8,5,10,7,5,5`); all five: **`70.0 GB` `-ts`**
  (`12,8,5,9,9,10,7,5,5`). Same RPC ports as Pool72/80; not concurrent 27B +
  dense 72B/80B on one GPU. Backends fixed
  at coordinator start ([RPC README](https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md)).
  **Production default = `frontier-code` (Qwen3.8-27B)** (**`PARALLEL=5`**,
  **`CTX_SIZE=262144`** / 52428 per slot; native max). **`frontier`** shares the same 27B
  backend today; reserved for a future **dense ~70–72B Q4** exclusive load (fit
  with gaming hosts: [experimental/UI_DRIVEN_GPU_MODEL_RESEARCH.md](experimental/UI_DRIVEN_GPU_MODEL_RESEARCH.md)).
  **Qwen3.6-35B-A3B MoE is retired** — LiteLLM aliases remap to 27B; revive only via
  `switch-pool-35b.sh`. Stack: [`deploy/llamacpp-rpc/`](../deploy/llamacpp-rpc/);
  runbook [GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md).
- **Spare-GPU / RAG:** CPU embed + rerank on **`rag`** (`:11435`/`:8360`) — production SSoT
  ([RAG_148_TO_110_MIGRATION.md](RAG_148_TO_110_MIGRATION.md)). `pool-opt-in` / `secondary` are inference
  opt-in shards, not RAG.
- **LiteLLM** (`hub`) - unified OpenAI-compatible router; concurrency via
  `--parallel` slots.

**Gaming hosts:** **inference opt-in** at each start: **`gaming-a`** `:31352`, **`gaming-c`**
`:31351`, **`gaming-b`** `:31358`, **`secondary`** `:31355`, **`pool-opt-in`** `:31354` — never
required for core green. **Train lock** blocks inference on **`gaming-c`** / **`gaming-b`**
(and **`gaming-a`** when in train). Same RPC ports serve **Pool72** / **Pool80**
when selected — not concurrent 27B + dense 72B/80B on one GPU. Dockge on all
gaming PCs. Join checklist: [inference_GAMING_HOST_JOIN.md](inference_GAMING_HOST_JOIN.md). Historical
**Petals 70B / 7-host swarm** below is **retired** — audit only.

## Petals worker networking (RETIRED — historical)

> **Retired 2026-07-09.** Petals workers/gateways are removed from deploy. This
> section is kept for port audit history only.

Petals worker stacks use **`network_mode: host`** so DHT and QUIC behave like bare-metal peers (Docker bridge DNS does not apply). Expect **`31330/tcp`** on every GPU worker plus **`31331`** for worker-monitor; dual-GPU hosts add shard ports (**`31340`** / **`31341`**). Authoritative table: [PORT_ASSIGNMENTS.md](PORT_ASSIGNMENTS.md) (audit PETALS-002 / backlog #37).

## Node inventory

See **[NODE_INVENTORY.md](NODE_INVENTORY.md)** for hostnames, LAN IPs, GPUs,
and Petals port **31330**. **Per-machine hardware and role stats** (CPU/RAM/GPU,
Petals blocks, compose variant, Dockge): [NODE_INVENTORY.md § Machine stats](NODE_INVENTORY.md#machine-stats-at-a-glance). Keep that file updated when you add or retire
workers. **Petals doc index:** retired — see [history/](history/).

**April 2026 topology (historical — Petals retired 2026-07-09; network superseded 2026-09-04 `br1`):**

- **Brain:** `hub` (hub Scale 25.04, Ryzen 9 7900X, **~46 GiB** DDR5,
  AsrockRack B650D4U, **RTX 5060 8 GB**). **Current LAN:** **`br1`** with mgmt **`hub/24`** + NFS VIP **`orchestrator/32`** (same L2). **`.157` Petals plane — retired.** Runs `alfa-ai-api`, `alfa-ai-litellm`, postgres/redis, `alfa-ai-nginx`, llama.cpp RPC shard/coordinator — **not** Petals workers.
- **Historical only:** Primary Petals gateway on `orchestrator`, Petals workers on `apps`/`secondary`/gaming hosts — **removed from deploy 2026-07-09.**

## Architecture

```mermaid
flowchart LR
  subgraph clients [Websites / bots / dev]
    c1[Cursor / CLI / rankings-bot]
  end

  c1 --> LL[LiteLLM :4000<br/>on hub]

  subgraph ollama ["Ollama tiers (June 2026 two-host pool)"]
    cpu["qwen3.5:27b on gaming-c (quality) + qwen3.6:35b-a3b on orchestrator (speed)<br/>tiers 0/1/2 chat/agent/code + fast/inline/autocomplete<br/>each falls back to other host, then frontier"]
    oe["CPU embed + rerank<br/>rag :11435 / :8360"]
  end

  subgraph rpc ["llama.cpp RPC - frontier-code 27B pool (Phase H)"]
    mc["llama-server :31360<br/>(hub CPU coordinator)"]
    rshard["rpc-server x 4<br/>(inference orchestrator hub)"]
    mc --- rshard
  end

  subgraph petals ["RETIRED historical - Petals swarm (do not deploy)"]
    pg["petals-gateway<br/>orchestrator primary :8413 / hub fallback / apps last-resort :8013"]
    w111["hub 5060 8GB<br/>(Blackwell)"]
    w105["apps 1660S 6GB<br/>(bootstrap)"]
    w93a["orchestrator 3060 12 #1"]
    w93b["orchestrator 3060 12 #2"]
    w248["secondary 3050 6GB"]
    w249["gaming-b 5070 12GB"]
    w59["gaming-c 5070 12GB"]
    w219["gaming-a 5060 8GB"]
    pg --- w111
    pg --- w105
    pg --- w93a
    pg --- w93b
    pg --- w248
    pg --- w249
    pg --- w59
    pg --- w219
  end

  LL -->|inline / fast / agent / code| cpu
  LL -->|frontier + frontier-code| mc
  LL -->|embed / rerank| oe
  ```

## Components

| Component | Role | Where it runs |
|-----------|------|---------------|
| **LiteLLM Proxy** | Tier-based OpenAI-compatible router (`fast` / `inline` / `chat` / `agent` / `code` / `frontier` / `frontier-code` / `public-chat` / `app-chat` / `embed`). | `hub` brain (**`:8413`** host; container `:4000`) |
| **Ollama CPU chat** | Tiers 0/1/2 = two-host pool — `qwen3.5:27b` on `gaming-c` (quality) + `qwen3.6:35b-a3b` on `orchestrator` (speed); June 2026. | `gaming-c` + `orchestrator` (`:11434`); fallback other host → `frontier` |
| **CPU embeddings** | RAG retrieval embed sidecar. | **`rag` `:11435`** (production SSoT; `inference` RAG retired) |
| **Reranker sidecar** | `Qwen3-Reranker-0.6B` for RAG chunk ranking. | **`rag` `:8360`** |
| **Petals Gateway** | *(retired — history only)* | Do not deploy. See [history/](history/). |
| **Petals Workers** | *(retired — history only)* | Do not deploy. |
| **llama.cpp `llama-server`** | OpenAI-compatible coordinator for **27B/35B** pool (one profile at a time). | **`hub` CPU `:31360`** |
| **llama.cpp `rpc-server`** | GPU-backed tensor shard for **27B** pool. | **`inference` `:31356`/`:31357`**, **`orchestrator` `:31350`**, **`hub` `:31353`** (`orchestrator` `:31355` retired) |
| **Postgres** | Brain DB (runs, tasks, artifacts, workers registry). | **`hub`** (protected stack). Consumer bots may still have their own Postgres on `apps` / dedicated VMs. |
| **Redis** | Heartbeats, sessions, queues. | **`hub`** (brain). Shared Redis on `apps` is for remaining apps, not the brain. |
| **** | Encrypted mesh VPN (optional — LAN is the primary transport). | All nodes optional |

## Model Routing (LiteLLM tiers)

| Alias | Backend | Model | Host | Typical latency | Use |
|-------|---------|-------|------|-----------------|-----|
| `chat` / `agent` / `code` / `public-chat` / `app-chat` | Ollama CPU chat (quality) | `qwen3.5:27b` (dense) | `gaming-c` | ~2–6 tok/s | Quality default (June 2026); fallback `orchestrator` → `frontier` |
| `fast` / `inline` / `autocomplete` | Ollama CPU chat (speed) | `qwen3.6:35b-a3b` (MoE, ~3B active) | `orchestrator` | ~18–30 tok/s | Speed tier (June 2026); fallback `gaming-c` → `frontier` |
| `frontier` | llama.cpp RPC | **Qwen3.6-27B** (same pool as `frontier-code` today) | **`hub` coord `:31360`** + GPU shards | inference | Production chat alias; reserved for a future dense ~70B exclusive load |
| `frontier-code` | llama.cpp RPC | **Qwen3.6-27B** | **`hub` coord `:31360`** + GPU shards | inference | Production coding tier (inference) |
| `embed` | CPU sidecar | embed model on `rag` | **`rag` `:11435`** | < 300 ms | RAG embeddings |
| `rerank` | CPU sidecar | `Qwen3-Reranker-0.6B` | **`rag` `:8360`** | < 300 ms | RAG rerank |

Add / remove models by editing [deploy/litellm_config.yaml](../deploy/litellm_config.yaml).

- **Petals `2.2.0.post1`** supports Llama 2/3/3.1/**3.3** / Falcon / Bloom /
  Mixtral; **does NOT** support Qwen3 (see
  [QWEN3_MIGRATION.md](QWEN3_MIGRATION.md)).
- **llama.cpp RPC** supports Qwen3 / Qwen3-Coder / Llama / Mistral / many
  others; stack lives under [`deploy/llamacpp-rpc/`](../deploy/llamacpp-rpc/).
- Fallback Petals frontier model if Llama-3.3-70B is temporarily unavailable
  (e.g. HF license accept pending): `meta-llama/Llama-3.1-70B-Instruct`
  (same 80 blocks, gated).

**nvidia-smi is the single source of truth** for GPU specs. If this document
disagrees with `nvidia-smi` on any node, update this document.

## Trust zones (public website vs internal)

- **Public web AI** (USPBF homepage → rankings-bot `demo-ask`) uses LiteLLM
  model aliases that map only to **Ollama / safe** backends (e.g.
  `public-chat`). Do not point public traffic at heavy internal models.
- **App-authenticated AI** uses `app-chat` or `inline` / `agent` via
  `LITELLM_MODEL_PAGE_QUESTION` / `LITELLM_MODEL_CHAT`.
- **ALFa AI orchestrator** (`/api/runs`, workers, tools) is **internal**. In
  production set `ALFA_AI_REQUIRE_API_AUTH=true` and a strong
  `ALFA_AI_API_TOKEN`; call APIs with `Authorization: Bearer <token>`.
  Default in code/compose is unauthenticated for local dev only.

Full checklist: [rankings-bot docs/ALFA_AI_TRUST_ZONES_AND_ROLLOUT.md](../../rankings-bot/docs/ALFA_AI_TRUST_ZONES_AND_ROLLOUT.md).

## Setup

### Prerequisites

- **Connectivity:** LAN — all nodes share `orchestrator/24`.  is
  optional.
- **NVIDIA:** drivers + CUDA on all GPU nodes; nvidia-container-toolkit on
  all Docker hosts. Blackwell workers (`gaming-b / gaming-c / gaming-a`) need CUDA 12.8.
- **Docker + Docker Compose** on every node.
- **worker-monitor** on gaming workers (`gaming-b` / `gaming-c` / `gaming-a`): Docker sidecar `python:3.12-slim` in [deploy/cluster-members/_common/worker-monitor/](../deploy/cluster-members/_common/worker-monitor/), port **31331**. GPU stats use `nvidia-smi` inside the container ([Compose GPU](https://docs.docker.com/compose/how-tos/gpu-support/)). Petals is not part of this sidecar.

### Step 1: Start `apps` as Petals bootstrap worker + gateway (RETIRED — do not run)

> **Retired 2026-07-09.** Petals deploy and bootstrap API removed. Steps below are audit history only.

```bash
# On apps
ssh operator@apps
cd /home/operator/alfa-ai/deploy/petals
cp env.worker.example .env.worker
# Edit .env.worker:
#   PETALS_MODEL=meta-llama/Llama-3.3-70B-Instruct    # current swarm model (Apr 2026)
#   PETALS_IS_BOOTSTRAP=1                             # apps calls --new_swarm
#   PETALS_ANNOUNCE_IP=apps                  # pinned LAN multiaddr
#   PETALS_INITIAL_PEERS=                             # leave empty (overridden by IS_BOOTSTRAP)
#   ALFA_BRAIN_URL=http://hub          # brain
#   ALFA_WORKER_HEARTBEAT_TOKEN=<shared secret>       # must match brain
#   WORKER_NAME=lancelot-105

docker compose --env-file .env.worker \
  -f docker-compose.worker.yml \
  -f docker-compose.worker.nfs-mounts.override.yml \
  up -d

# Peer-id is pinned by /mnt/cluster/petals/identity/identity.key and will
# be the SAME across --force-recreate. Entry logs the pinned multiaddr:
sudo docker logs petals-worker 2>&1 | grep 'Running a server on' | tail -1

# Bootstrap publisher writes the authoritative record to the brain + NFS cache:
curl -fsS -H "Authorization: Bearer $TOKEN" \
  http://hub/api/petals/bootstrap | jq
sudo cat /mnt/cluster/petals/bootstrap/bootstrap.multiaddr
```

### Bootstrap discovery (RETIRED — historical)

> Petals bootstrap API and `deploy/petals/` removed 2026-07-09.

Petals was P2P (hivemind/libp2p DHT) with no tracker. The `--initial_peers`
contract is unchanged. This repo previously added the discovery layer above Petals:

- **Write path** (bootstrap node only, `PETALS_IS_BOOTSTRAP=1`): the entry
  script parses Petals' own log for the multiaddr and posts it to the
  brain's `POST /api/petals/bootstrap` (Redis-backed, TTL 600 s, refreshed
  every 240 s) plus atomically writes
  `/mnt/cluster/petals/bootstrap/bootstrap.multiaddr` on NFS as a DR cache.
- **Read path** (every joiner): the entry resolves `--initial_peers` in
  order — `PETALS_INITIAL_PEERS` env var → `GET ${ALFA_BRAIN_URL}/api/petals/bootstrap`
  → NFS cache → `--new_swarm` (only if `PETALS_IS_BOOTSTRAP=1`).
- **Peer-id stability**: `--identity_path /data/petals/identity/identity.key`
  (persisted on NFS) keeps the peer-id identical across container recreate,
  image rebuilds, and host reboots.

Source of truth (removed): `src/api/routers/petals_bootstrap.py`, `deploy/petals/`.

### Step 2: Start the brain on `hub`

See [DOCKGE_111_OPERATOR.md](DOCKGE_111_OPERATOR.md) § "First-time setup".
Summary:

```bash
ssh operator@hub
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai
bash deploy/cluster-members/hub/deploy.sh
```

`deploy/.env` on `hub` (key values):

```env
# Canonical keys: deploy/env.example (no Petals). RAG SSoT is rag.
EMBED_BASE_URL=http://orchestrator
RERANK_BASE_URL=http://orchestrator
DATABASE_URL=postgresql://alfaai@alfa-postgres:5432/alfaai   # dedicated protected stack on hub
REDIS_URL=redis://alfa-redis:6379/0
```

Verify:

```bash
curl -fsS http://hub/health/liveliness
curl -fsS http://hub/health
```

### Step 3: Join remaining workers

See [petals/WORKER_ROLLOUT.md](petals/WORKER_ROLLOUT.md) Phase 2–3 for
`orchestrator` (standard CUDA) and `gaming-c / gaming-a / gaming-b` (Blackwell).

### Step 4: Test tier routing

**Automated check:** from a LAN host that can reach the brain (for example
`web-sites` / `apps`), after `git pull` and with `LITELLM_MASTER_KEY` available:

```bash
cd ~/alfa-ai   # or your git checkout root
./scripts/smoke-litellm-tiers.sh deploy/.env
```

The script strips CRLF from `.env`, ignores Docker-only `LITELLM_BASE_URL=…alfa-ai-litellm…`
for host-side `curl`, and targets `http://<brain-ip>:<port>` using
`ALFA_AI_LITELLM_HOST_PORT` from `.env` when set (see `deploy/env.example`; hub
commonly uses **4000** per `deploy/cluster-members/hub/deploy.sh`). Override
with `SMOKE_LITELLM_BASE_URL` if needed. Recreate `alfa-ai-litellm` after compose
changes so the published host port is reachable on the LAN (not loopback-only).

The examples below use **`hub`**; substitute the host IP and
`ALFA_AI_LITELLM_HOST_PORT` you actually publish.

```bash
# Tier 0/1/2 (Ollama CPU chat: qwen3.5:27b on gaming-c quality + qwen3.6:35b-a3b on orchestrator speed; June 2026)
# NOTE: external callers use host port :8413 (container listens on :4000).
curl http://hub/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"inline","messages":[{"role":"user","content":"complete: def fib("}]}'

curl http://hub/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"chat","messages":[{"role":"user","content":"Hi, what can you do?"}]}'

curl http://hub/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"agent","messages":[{"role":"user","content":"Write Python hello world"}]}'

# Tier 3 - llama.cpp RPC frontier (primary working set on orchestrator:31360)
# NOTE: external callers use host port :8413 (container listens on :4000).
# Use --max-time 600 for pooled MoE chat.
curl http://hub/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"frontier","messages":[{"role":"user","content":"Explain pipeline parallelism"}],"max_tokens":64}'

curl http://hub/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"frontier-code","messages":[{"role":"user","content":"Refactor this function..."}],"max_tokens":64}'

# Tier 3a opportunistic (Petals Llama-3.3-70B - only when gaming swarm is up)
# curl ... -d '{"model":"petals-frontier",...}'  # if enabled in litellm_config.yaml

# Embeddings + rerank (production SSoT: rag CPU; both mandatory for cluster start)
curl http://orchestrator/api/tags
curl http://orchestrator/health
curl http://hub/v1/embeddings \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"embed","input":"hello"}'
```

## Rankings-Bot Integration

Rankings-bot routes requests through the LiteLLM proxy on `hub`:

```env
# rankings-bot .env on apps
LITELLM_ENABLED=true
LITELLM_BASE_URL=http://hub
LITELLM_API_KEY=change-me
# Optional: separate proxy keys (LiteLLM virtual keys / teams) for public vs app
# LITELLM_API_KEY_PUBLIC=
# LITELLM_API_KEY_APP=
LITELLM_MODEL_PUBLIC=public-chat
LITELLM_MODEL_PAGE_QUESTION=app-chat
# Heavy default:
LITELLM_MODEL_CHAT=agent
```

When enabled, narrative endpoints route via `complete_narrative_chat` →
LiteLLM using **trust-zone** models (`public_web` vs `app_authenticated`).
See `api/services/litellm_client.py` and `api/services/ai_narrative_llm.py`.

## LAN-only (no ) — **historical Petals bootstrap notes**

> **Petals retired 2026-07-09.** Section kept for firewall audit only.

When every Petals worker and the `apps` gateway host shared `orchestrator/24`,
 is optional. On the LAN, joiners resolve the bootstrap multiaddr
automatically from the brain / NFS (see "Bootstrap discovery" above). For
out-of-LAN  peers, set `PETALS_INITIAL_PEERS` explicitly in their
`.env.worker` (env var wins over brain lookup).
Ensure **31330/tcp** is allowed from every worker to `apps` (UFW on `apps`:
`sudo scripts/petals_worker_ufw_allow.sh`).

### hub `hub` and `br1`: outbound source IP (historical Petals UFW note)

> **Petals retired 2026-07-09.** Keep this section only if auditing old `apps` UFW rules for `31330/tcp`.

**Current LAN:** **`br1`** carries **`hub/24`** + **`storage/32` NFS VIP** (same L2).

When legacy Petals workers used **`network_mode: host`**, traffic could show **`src orchestrator`** (confirm with):

```bash
ip route get apps
```

**On `apps` UFW (historical):** permit **`31330/tcp`** from each joiner source. **`.157` rules obsolete.**

##  + Starlink Notes

##  + Starlink Notes

- **CGNAT bypass:**  handles NAT traversal automatically. No port
  forwarding needed on Starlink.
- **IP conflict:** Starlink and  both use 100.64.0.0/10. If
  connections fail, narrow the  subnet in the admin console JSON
  editor.
- **Latency:** Expect 30-60 ms per hop via Starlink. Pipeline parallelism
  (which Petals uses) tolerates this. Tensor parallelism would not.
- **Fault tolerance:** Petals reroutes around disconnected nodes. Starlink
  hiccups cause temporary slowdowns, not failures.

## Adding a New Model

1. Choose a runtime based on model family:
   - **llama.cpp RPC (production)** — GGUF on the hub, then LiteLLM alias.
     Place the GGUF under `MODELS_DIR` on the coordinator and update
     `MODEL_FILE` / `MODEL_ALIAS` in
     [deploy/llamacpp-rpc/.env.rpc](../deploy/llamacpp-rpc/.env.rpc.example).
   - **Ollama** (optional CPU chat tiers) — hub-first pull only; not the
     production `frontier` / `frontier-code` path.
   - **Petals** — **retired.** Do not add models or restart `petals-worker`.
2. Add a LiteLLM route in
   [deploy/litellm_config.yaml](../deploy/litellm_config.yaml) on `hub`.
3. Apply llama.cpp RPC / coordinator changes with a full
   `Start-Stop-AlfaAi.ps1` stop then start — not piecemeal shard or
   coordinator restarts.

## Monitoring

- **LiteLLM:** host `http://hub` (container `:4000`).
- **Petals Gateway health:** retired — do not probe `:8413` on `orchestrator` as a Petals gateway. Use LiteLLM `curl http://hub/v1/models`.
- **Worker status:** inference shards via orchestrator logs / `docker logs` on `llamacpp-rpc-*` — not `petals-worker`.
- **Cluster hosts panel:** `/alfa-ai/admin/health` on the brain (`hub`) —
  see `build_cluster_hosts_report()` in [src/api/worker_monitoring.py](../src/api/worker_monitoring.py).
- **Rankings-bot AI Monitor:** `/api/admin/ai-monitor` tracks all LLM calls.

## Ports

See `docs/PORT_ASSIGNMENTS.md` for the full port map.

Key brain-side ports on `hub`: `8420` (API), `4000` (LiteLLM), `11434`
(Ollama), `5000` (registry mirror), `31014` (Dockge Apps).

## Operator rollout (phased jobs)

**Rule stack (agents + operators):** [.cursor/rules/RULES.md](../.cursor/rules/RULES.md) — official manuals first, update `docs/` before code, then git on `apps` → push → pull on every host → hub artifacts on `hub` before workers → deploy in order ([cluster-sync-order.mdc](../.cursor/rules/cluster-sync-order.mdc)). Host-specific runbooks in this tree must stay consistent with that sequence.

For a step-by-step bring-up order (secrets, compose, Petals, rankings-bot,
TLS), use **[petals/WORKER_ROLLOUT.md](petals/WORKER_ROLLOUT.md)** and
**[history/BRAIN_MIGRATION_105_TO_111.md](history/BRAIN_MIGRATION_105_TO_111.md)** for the
initial brain move from `apps` to `hub`.
