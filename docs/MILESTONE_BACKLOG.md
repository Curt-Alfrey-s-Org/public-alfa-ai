# Milestone Backlog and Definition of Done

## Milestone 1 - Core Assistant MVP

Scope:

- Working CLI + interactive mode.
- Deterministic loop with JSON tool calls.
- Sandboxed tools and command timeout policy.
- Multi-provider LLM client with env-driven selection.

Definition of Done:

- Unit tests cover loop transitions and safety checks.
- `README.md` documents setup, run modes, tool protocol, limits.
- No placeholder `NotImplementedError` in MVP path.

## Milestone 2 - Role Collaboration Runtime

Scope:

- Task graph orchestration and role routing.
- Handoff protocol and artifact metadata contracts.
- Retry policy with failure taxonomy.

Definition of Done:

- Runtime spec documented in `docs/COLLABORATION_RUNTIME.md`.
- Role contracts defined in `src/agent/roles/contracts.py`.
- At least one integration test exercises two-role handoff.

## Milestone 3 - Persistence and Queueing

Scope:

- Postgres schema for runs/tasks/artifacts/events.
- Redis-backed queue for async role jobs.
- Idempotent worker claim and retry semantics.

Definition of Done:

- Schema and queue model documented in `docs/DATA_QUEUE_MODEL.md`.
- DB migration scripts exist and run in CI.
- Worker can process queued job and persist result record.

## Milestone 4 - Self-Hosted Deployment Baseline

Scope:

- Docker Compose baseline (api, worker, postgres, redis, nginx).
- Nginx reverse proxy for API/UI paths.
- Networking and security aligned with workspace standards.

Definition of Done:

- Deployment docs include startup and health checks.
- Network and host-bindings follow immutable standards.
- Runbook includes rollback and incident triage notes.

## Milestone 5 - Evaluation and Quality Gates

Scope:

- Benchmarks for coder/debugger/doc-maker/researcher.
- Automated scoring and threshold-based release gates.
- Regression tracking dashboard-friendly outputs.
- **Learning-loop L0 eval smoke** (≥10 gold tasks) — ties to Priority #7 L0 / PR-LL-03.

Definition of Done:

- Evaluation framework documented in `docs/EVALUATION_FRAMEWORK.md`.
- Baseline run recorded for each role benchmark category.
- Release pipeline blocks on critical metric regression.
- Offline eval smoke script runnable (see [LEARNING_LOOP_JUDGE_SLEEP.md](../.cursor/plans/LEARNING_LOOP_JUDGE_SLEEP.md) L0.6).

## Milestone 6 - Distributed AI Cluster (Petals + LiteLLM)

Scope:

- LiteLLM proxy as unified router between Ollama (fast local) and Petals (distributed swarm).
- Petals Gateway: OpenAI-compatible wrapper for Petals distributed inference.
- Petals worker configs for deploying GPU/CPU nodes across multiple PCs on the same LAN first ( optional later).
- ALFa AI LLM client updated with `litellm` provider for transparent backend routing.
- Rankings-bot LiteLLM client for optional distributed inference.

Current operator roadmap:

1. **`apps`** remains the authoritative git checkout / sync source while worker images and compose files stabilize.
2. **hub** is the first live Petals worker and bootstrap node (**`hub`** for SSH/UI, **`.157`** as the current advertised Petals peer).
3. **`hub`** (hub Scale, hostname `hub`) is the **main brain**: ALFa AI + LiteLLM + in-stack Postgres/Redis + Petals worker/gateway (fallback). **Only the `qwen3:8b` `operator_internal` model** (Lane A; no sub-frontier chat) — tiers 0/1/2 = `qwen3.5:27b` on `gaming-c` (quality) + `qwen3.6:35b-a3b` on `orchestrator` (speed). `orchestrator` (Win11, hostname `WOLF1`, user `operator`) runs the **primary Dockge UI** + a single GPU Petals worker (**1× RTX 3060** since 2026-06-21; 2nd card removed) + primary gateway.
4. **`apps`** is now an active **Petals worker** (**GTX 1660 Super 6GB** post-swap with `secondary`; previously 3060 12GB before the `hub` migration swap; confirmed via nvidia-smi; standard `docker-compose.worker.yml`) + Ollama.
5. Add **three more Win11 LAN Petals workers** — **`orchestrator` (gaming-worker-b)**, **`orchestrator` (gaming-worker-c)**, **`orchestrator` (gaming-worker-a)** — per **[ROADMAP.md](ROADMAP.md)**.
6. **Operator UI:** monitor **`hub`** (main brain) in Cluster Health, not only remote workers — see **[ROADMAP.md](ROADMAP.md)**.
7. **Models (June 2026):** tiers 0/1/2 = `qwen3.5:27b` (`gaming-c`, quality) + `qwen3.6:35b-a3b` (`orchestrator`, speed); tier 3a = `Llama-3.3-70B` (Petals, ≈76 GB swarm); tier 3b = `Qwen3-Coder-Next-80B-A3B` (llama.cpp RPC). Models centralized on hub hub, managed via admin UI. See **[ROADMAP.md](ROADMAP.md)**.
8. **PRIMARY WORKING SET (2026-06-22) - four-host frontier pool:** `gaming-c`/`gaming-a`/`gaming-b` are gaming machines (intermittent), so frontier chat + code run on the always-on four hosts `orchestrator`/`apps`/`hub`/`inference` via **llama.cpp RPC pooling GPU+CPU**, coordinator on **`orchestrator:31360`**, one model at a time. Chat = **Qwen3.5-122B-A10B** (pooled; alt **Qwen3.5-27B**); code = **Qwen3.6-27B** on the **`orchestrator`+`inference` 2-GPU pool** (highest fitting SWE-bench Verified; agentic alt **Qwen3-Coder-Next-80B-A3B** pooled). Spare GPUs run embeddings/reranker; concurrency via `--parallel`; caching (LiteLLM/Redis + llama.cpp prompt-cache) + KV-quant for context. 7-host Petals + CPU Ollama pool = opportunistic boost. **Definition of done:** SSoT plan **[.cursor/plans/FOUR_HOST_FRONTIER_POOL.md](../.cursor/plans/FOUR_HOST_FRONTIER_POOL.md)** §8 acceptance all green.

Definition of Done:

- Architecture documented in `docs/DISTRIBUTED_AI.md` (four-host llama.cpp RPC primary; Petals opportunistic).
- `deploy/litellm_config.yaml` maps model names to Ollama or Petals backends.
- `deploy/docker-compose.yml` includes LiteLLM proxy and Petals Gateway services.
- `deploy/petals/` provides worker compose, env template, and native start script.
- hub runs as the first healthy Petals bootstrap worker on the LAN with a supported model family (`hub` management, `.157` worker peer).
- `hub` runs the main brain (ALFa AI + LiteLLM + in-stack Postgres/Redis + Petals worker/gateway; only the `qwen3:8b` `operator_internal` model, Lane A — no sub-frontier chat) and can reach the `apps` bootstrap peer.
- `apps` is an active **Petals** worker (**GTX 1660 Super 6GB** post-swap with `secondary` — previously 3060 12GB) using [deploy/petals/docker-compose.worker.yml](../deploy/petals/docker-compose.worker.yml) and the checked-in GPU Dockerfile. Ollama installed for fast local inference.
- At least three initial LAN nodes (hub **`hub` / `.157`** brain + hub, **`apps`** apps host, **`orchestrator`** Dockge UI + worker) have a documented bring-up order before any extra workers are added.
- LiteLLM health endpoint returns healthy, and test requests route to both backends.
- Rankings-bot `api/services/litellm_client.py` can reach the proxy and return `OllamaResponse`.
- Cross-repo trust-zone checklist: [rankings-bot docs/ALFA_AI_TRUST_ZONES_AND_ROLLOUT.md](../../rankings-bot/docs/ALFA_AI_TRUST_ZONES_AND_ROLLOUT.md) — `public-chat` / `app-chat` aliases, narrative routing via `ai_narrative_llm.py`.
- Operator phased rollout documented and runnable: [rankings-bot docs/ALFA_AI_MULTI_JOB_ROLLOUT.md](../../rankings-bot/docs/ALFA_AI_MULTI_JOB_ROLLOUT.md); preflight via `scripts/alfa_ai_rollout_preflight.sh` and `scripts/preflight_ports.sh`.
- **Deployment pipeline:** hub hub (`scripts/setup_hub_hub.sh`). Per-host deploy via `deploy/cluster-members/*/deploy.{sh,ps1}`. Stage Windows workers with `scripts/stage-cluster-members.ps1`. Workflow: [SOURCE_OF_TRUTH_AND_SYNC.md](SOURCE_OF_TRUTH_AND_SYNC.md).
- **Per-host env:** tracked `env.*.example` under `deploy/cluster-members/<host>/` — operators copy into local `.env` / `.env.worker` / `.env.apps` / `.env.gateway` (never commit secrets). See [docs/petals/PER_HOST_ENV_TEMPLATES.md](petals/PER_HOST_ENV_TEMPLATES.md).

## Milestone 7 - Agentic Development Pipeline

> **Implementation plan (2026-07-01):** Grok-style orchestration on the existing
> FastAPI agent loop — skills, WorkflowRunner, check-work — not a third-party
> framework swap. See
> [.cursor/plans/AGENT_PLATFORM_GROK_ALIGNMENT.md](../.cursor/plans/AGENT_PLATFORM_GROK_ALIGNMENT.md)
> Phases 0–2.

Scope:

- Integrate an agentic coding framework (OpenHands, Aider, or custom) with the distributed cluster.
- Agent points at LiteLLM endpoint for model access (fast models for iteration, heavy models for planning).
- Docker sandbox for agent-generated code execution (build, run, test) isolated from host.
- Task queue: accept development goals, assign to agent, track progress and artifacts.

Definition of Done:

- Agent can receive a goal (e.g. "add dark mode toggle"), plan, write code, run tests, and commit.
- All agent-generated code executes in a sandboxed Docker container.
- Agent loop logs to persistence layer (runs/tasks/artifacts from Milestone 3).
- At least one end-to-end demo: goal in → working code + passing tests out.

## Milestone 8 - Cross-Project Maintenance

Scope:

- Rankings-bot and other projects register as "maintained repos" in ALFa AI.
- Agent can clone, branch, edit, test, and open PRs against maintained repos.
- Overnight batch mode: queue multiple tasks, agent works through them unattended.
- Monitoring: track success rate, token usage, and time per task.

Definition of Done:

- ALFa AI accepts a repo URL + task description and produces a PR or patch.
- Batch runner processes queued tasks with configurable concurrency.
- Dashboard shows task history, pass/fail rates, and token costs.
- At least one real PR opened against rankings-bot by the agent and reviewed by a human.

## Milestone 9 - Learning Loop, Judge, Sleep Training

> **SSoT (2026-07-11):**
> [.cursor/plans/LEARNING_LOOP_JUDGE_SLEEP.md](../.cursor/plans/LEARNING_LOOP_JUDGE_SLEEP.md)
> Phases L0–L4. Research:
> [research/LEARNING_LOOP_AND_JUDGE_RESEARCH.md](research/LEARNING_LOOP_AND_JUDGE_RESEARCH.md).
> ROADMAP Priority **#7**. Master plan Program Wave **I**.
> Train island: sibling **alfa-train** — `gaming-c` / `gaming-b` (optional `gaming-a`); `inference` stays on inference core.

Scope:

- Agent fleet: audit, research, error catalog, corrective analysis, implement→review→check-work.
- Independent **judge** model dual-checks 27B (not self-score only; not every tool call).
- Sleep Tier A: memory consolidation + preference export (no weight train).
- Sleep Tier B: QLoRA overlays via alfa-train (not foundation pretrain).
- Production 27B frozen until eval promotion gate.

Definition of Done:

- L0: `errors.jsonl` + corrective_actions from real rotation; eval smoke ≥10 tasks.
- L1: LiteLLM `judge` on independent mid-size model; freeform dual-check never auto-approves.
- L2: sleep-curator dry run; preference pack on hub.
- L3 (optional for M9 partial): 7B QLoRA checkpoint eval ≥70% vs base; 27B routes unchanged.
- Governance: mutate off default; `safe_to_auto_apply` hard false on judge path.

## Milestone 10 - Conservative agent harness

> **SSoT (2026-09-17):**
> [.cursor/plans/HARNESS_CUTTING_EDGE_2026-09.md](../.cursor/plans/HARNESS_CUTTING_EDGE_2026-09.md)
> Waves H0--H4. ROADMAP Priority **#10**. Master plan Program Wave **J**.

Scope:

- Ask ALFa native OpenAI tools opt-in on 27B (JSON-in-text fallback retained).
- Skills progressive disclosure (`name`+`description` first; body on activate).
- Client-side inspect compaction (UI keeps full `inspections[]`).
- MCP inspect-only mount (admin JWT + LAN; no mutate via MCP).
- No computer-use / CUA on operator or gaming desktops.

Definition of Done:

- H1--H4 **code + unit tests in repo** (flags default off except H3 prompt compact).
- Mutate stays L2 Approve (catalog `propose_host_action` / existing HTTP). MCP cannot mutate.
- Operator smoke on live 27B still optional (`ALFA_AI_NATIVE_TOOLS=1` / `ALFA_AI_MCP_ENABLED=1` after brain rebuild).

