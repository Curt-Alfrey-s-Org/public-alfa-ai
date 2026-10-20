# Agent research tools (v1 + memory + gated web search)

Operator/LAN-admin-only research missions: repo search, allowlisted vendor-doc fetch,
LAN SearXNG search, and cross-mission memory.

**Who may browse the public internet:** only **LAN/ admin** paths:

| Path | When |
|------|------|
| **Ask ALFa** (admin dock) | Q&A in this chat: inspect `web_search` in-thread, then LLM reply here — **not** `mission_enqueue` for weather/research/zip lookup |
| **Missions** (`POST /api/runs` Bearer token) | Explicit backend jobs (multi-step agent loop with `grep_repo`, `fetch_url`, …) |

**Never** guest chat, WordPress docks, consumer-bot widgets, or signed-in `/alfa-ai` SPA
chat. Those stay LiteLLM-only with no `web_search` / `fetch_url`. SearXNG publishes
**loopback** `:8888` on `hub` only.

> **Roadmap:** implement-review-fix loops, editor fusion, and model-size scaling
> live in
> [.cursor/plans/AGENT_PLATFORM_GROK_ALIGNMENT.md](../.cursor/plans/AGENT_PLATFORM_GROK_ALIGNMENT.md).
> **Learning loop / judge / sleep:** Priority #7 —
> [.cursor/plans/LEARNING_LOOP_JUDGE_SLEEP.md](../.cursor/plans/LEARNING_LOOP_JUDGE_SLEEP.md).

## Scope

| Included | Deferred |
|---|---|
| `grep_repo`, `glob_files`, `fetch_url` (allowlist) | RAG/pgvector index |
| `web_search` (LAN SearXNG on `hub`, gated) | MCP, Playwright |
| Mission memory (`implement-memory/*.md`) | Auto-scheduled web scraping |
| `edit_file` (search/replace patches) | Native OpenAI tools default-off (`ALFA_AI_NATIVE_TOOLS=0`; Phase 3.1 wired) |
| Researcher role via agent loop | Judge model install (L1) |
| **WorkflowRunner** implement→review→check-work (`skill=implement` or `workflow=implement_review_fix`) | Sleep curator (L2) |
| **error-cataloger** / **corrective-analyst** skills | QLoRA nights (L3) |
| **sleep-curator** (Tier A memory + preference export) | |
| **export-train-pack** (L3 staging for alfa-train) | Actual GPU QLoRA on trainer island |
| Eval smoke `scripts/eval/smoke_runner.py --self-check` | |
| `ALFA_AI_AGENT_MODEL=frontier-code` (27B primary) | Pool72: `frontier` while exclusive 72B is up |
| Client retry to `agent` (35B MoE) on LLM errors | |

## Architecture: skills vs SearXNG vs MCP (not a plugin)

Online research on Pool72 is **not** a Cursor MCP server or a LiteLLM plugin.

| Layer | What it is |
|-------|------------|
| **Missions agent loop** | `POST /api/runs` with `research_only: true` -- primary orchestration ([src/agent/loop.py](../src/agent/loop.py)) |
| **Skill** (`skills/*/SKILL.md`) | Procedure injected into the system prompt (e.g. `audit-repo`) -- not the web pipe |
| **`web_search` tool** | HTTP to LAN SearXNG on `hub` ([deploy/searxng/README.md](../deploy/searxng/README.md)) |
| **Pool72 inference** | `ALFA_AI_AGENT_MODEL=frontier` routes tool-calling LLM to the 72B pool via LiteLLM |
| **Cursor `.cursor/skills/`** | IDE ops on `orchestrator` only -- not brain missions |
| **MCP** | Deferred Phase 3 ([AGENT_PLATFORM_GROK_ALIGNMENT.md](../.cursor/plans/AGENT_PLATFORM_GROK_ALIGNMENT.md)) |

**Ask ALFa Q&A stays in this chat.** When the operator asks to **research online** (vendor
manuals, model/release notes) or for **zip-code** weather (`check weather for 37658`),
Ask ALFa runs **pre_inspect + `llm_continue`**: inspect catalog action `web_search` (host
`111`, internal HTTP to SearXNG — reuses [`src.agent.tools.web_search`](../src/agent/tools.py)),
then the model answers in the dock. **Do not** `mission_enqueue` for those Q&A phrases.
`ALFA_AI_WEB_SEARCH_ENABLED=0` → `{ok:false, error:"web_search disabled"}` fail-closed;
**no** mission fallback. No SSH key required for `web_search` inspect.

**Home Assistant weather is not online research.** Local forecast prompts (including bare
"what's the weather" and ones that name host `apps`, HA, or solar weather radar) use
**pre_inspect + `llm_continue`:** `ha_get_forecasts` / `ha_get_state` in Ask ALFa
([HOME_ASSISTANT_BRAIN_INTEGRATION.md](HOME_ASSISTANT_BRAIN_INTEGRATION.md);
[weather.get_forecasts](https://www.home-assistant.io/integrations/weather/)).
**Never** `mission_enqueue` / `audit-repo` for those.

**Missions** still run the full multi-step agent loop (`grep_repo`, `fetch_url`,
`web_search`, …) for **scheduled/background jobs** and **feeder control** (Approve).
Watch **Admin -> Missions -> Live tool events** for mission tool calls. **Audit host N**,
**Review errors**, and **host-facts** inspect in Ask ALFa instead of enqueue.

**One-shot enable on `hub`:** `bash scripts/operator-pool72-research-enable.sh`  
**Verify:** `bash scripts/verify-pool72-research-smoke.sh` (and optional `--enqueue-mission`).

## Mission memory (model-agnostic)

Prior research/implement missions append summaries to:

`$ALFA_AI_DATA/implement-memory/<repo-hash>.md`

Default `ALFA_AI_DATA` is `{ALFA_AI_WORKSPACE_ROOT}/.alfa_ai`. The researcher and
coder roles load this into the system prompt on every run, so **swapping the model
alias does not reset learned context**.

| Env | Default | Purpose |
|-----|---------|---------|
| `ALFA_AI_DATA` | `{workspace}/.alfa_ai` | Persistent data root |
| `ALFA_AI_MEMORY_MAX_CHARS` | `4000` | Max chars injected into system prompt |
| `ALFA_AI_MEMORY_MAX_FILE_BYTES` | `65536` | Max memory file size (oldest entries dropped) |
| `ALFA_AI_MEMORY_MAX_ENTRIES` | `50` | Max mission blocks kept |

After each successful researcher/coder run, the agent appends goal + summary + sources.

## Online research (SearXNG on `hub`)

Self-hosted SearXNG serves JSON search on LAN. Workers call SearXNG only; SearXNG
calls upstream engines (hub-first: image on `hub`, not per-worker public API keys).

| Env | Default | Purpose |
|-----|---------|---------|
| `ALFA_AI_WEB_SEARCH_ENABLED` | `0` | Master switch for `web_search` tool |
| `ALFA_AI_SEARXNG_URL` | `http://alfa-searxng:8080` | SearXNG URL from brain API (Docker DNS on shared network `alfa-searxng`) |
| `ALFA_AI_WEB_SEARCH_MAX_RESULTS` | `5` | Max results per query |

Official refs: [SearXNG Docker](https://docs.searxng.org/admin/installation-docker.html),
[Search API](https://docs.searxng.org/dev/search_api.html) (`format=json` required).

Deploy: [deploy/searxng/README.md](../deploy/searxng/README.md). Port: `:8888` on `hub`
([PORT_ASSIGNMENTS.md](PORT_ASSIGNMENTS.md)). Brain `alfa-ai-api` joins external Docker
network `alfa-searxng` (same network as the SearXNG compose project) so recreates keep
DNS to container `alfa-searxng` without a manual `docker network connect`.

Policy: **LAN admin missions only**; manual trigger per
[no-automatic-scraping.mdc](../.cursor/rules/no-automatic-scraping.mdc). Use
`web_search` for discovery, then `fetch_url` on allowlisted vendor doc URLs.
Do not wire `web_search` into public or guest chat.

## Model routing

| Setting | Default | Purpose |
|---|---|---|
| `ALFA_AI_AGENT_MODEL` | `frontier-code` | Primary LLM for tool-calling loop (Qwen3.8-27B RPC; LiteLLM alias `qwen3.6-27b`) |
| `ALFA_AI_AGENT_FALLBACK_MODEL` | `agent` | One retry per step on timeout/5xx (35B-A3B MoE) |
| `ALFA_AI_AGENT_MAX_STEPS` | `6` | Max tool loop iterations |
| `ALFA_AI_AGENT_SYNTHESIS_MAX_TOKENS` | `2048` | `max_tokens` on LiteLLM calls |

### Pool72 (exclusive Qwen2.5-72B)

While Pool72 is the active inference mode ([GREV72_72B_OPERATOR.md](GREV72_72B_OPERATOR.md)):

```bash
ALFA_AI_AGENT_MODEL=frontier
ALFA_AI_WEB_SEARCH_ENABLED=1
ALFA_AI_SEARXNG_URL=http://alfa-searxng:8080
```

Restore `ALFA_AI_AGENT_MODEL=frontier-code` when switching back to inference
(`switch-pool-27b.sh`). Expect slower missions (`PARALLEL=1`, 128k ctx) -- lower
`ALFA_AI_AGENT_MAX_STEPS` or raise LiteLLM timeouts if missions time out.

**Hardware:** 27B uses the pool ([GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md)).
Pool72 uses the same coordinator port with a different model load. Pools are
**mutually exclusive** on shared GPUs.

Chat and operator console defaults stay on 35B MoE; only the agent loop reads
`ALFA_AI_AGENT_MODEL`.

## Context budgets (27B RPC)

| Setting | Default |
|---|---|
| `ALFA_AI_FETCH_MAX_CHARS` | `6000` |
| `ALFA_AI_TOOL_RESULT_MAX_CHARS` | `8000` |

Tool results are truncated before each LLM turn to protect KV headroom. Expect ~2-5
minutes for a typical 4-6 step research mission.

## Tools

### `grep_repo(pattern, path=".", glob=None, head_limit=50)`

Ripgrep under `ALFA_AI_WORKSPACE_ROOT`. Returns `{ok, matches, truncated}`.

### `glob_files(pattern, path=".")`

Glob under workspace root (max 200 paths).

### `fetch_url(url, max_chars=None)`

HTTP GET with allowlisted host only. Redirects (max 5) are followed by hand and
every hop must again be http(s) on an allowlisted host; otherwise the call fails
(org review 2026-09-25). Extracts readable text (stdlib HTML strip).
Returns `{ok, url, content, truncated}` or `{ok: false, error}`.

`grep_repo` passes the pattern to ripgrep as `-e PATTERN --`, so a pattern that
looks like an rg flag (e.g. `--pre=...`) is searched literally, never executed.

### `web_search(query, max_results=None)`

HTTP GET to SearXNG `/search?q=...&format=json` ([Search API](https://docs.searxng.org/dev/search_api.html)).
Returns `{ok, query, results:[{title,url,content}], truncated}` or `{ok:false, error}` when
disabled. Implementation: [`src/agent/tools.py`](../src/agent/tools.py) `web_search()`.

| Consumer | How it runs |
|----------|-------------|
| **Missions** agent loop | Tool call inside `POST /api/runs` worker |
| **Ask ALFa** Q&A | Inspect catalog action `web_search` (host `111`, internal HTTP) in-thread, then LLM reply — same function, no SSH |

Prefer repo tools first in missions; use results to pick allowlisted URLs for `fetch_url`.
Guest/SPA/consumer chat surfaces never invoke this tool.

### Existing workspace tools

`read_file`, `list_dir`, `create_file`, `edit_file`, `run_cmd` (researcher uses
read/grep/fetch/web_search when enabled; coder prefers `edit_file`).

## Skills (Phase 0)

Skills live under `skills/<name>/SKILL.md`. Missions follow the [Agent Skills](https://agentskills.io/specification) load order: at startup the agent system prompt includes a compact **Skills catalog** (`name`, `description`, optional `when-to-use` from YAML frontmatter only). When a mission sets `skill` on `POST /api/runs` or a role default applies (`coder` -> `implement`, `researcher` + `research_only` -> `audit-repo`), that skill's **instruction body** is appended; other skill bodies are not concatenated. Personas under `personas/*.md` are prepended for coder (`implementer`) and audit missions.

**Cursor IDE skills** (daily cluster ops on `orchestrator`) are a separate track under
`.cursor/skills/` -- see [CURSOR_TOOLS_AND_SKILLS.md](CURSOR_TOOLS_AND_SKILLS.md).

## Fetch allowlist

Hosts must match `ALFA_AI_FETCH_ALLOWLIST` (comma-separated suffixes). Default:

```
learn.microsoft.com,docs.docker.com,docs.python.org,fastapi.tiangolo.com,
vite.dev,nginx.org,postgresql.org,redis.io,github.com,compose-spec.io,
open.gsa.gov,api.data.gov,12factor.net,docs.kernel.org,raw.githubusercontent.com
```

Extend via env; do not disable the allowlist in production.

## Operator runbook

### Prerequisites

1. **RPC pool active** -- inference ([GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md)) or Pool72
   ([GREV72_72B_OPERATOR.md](GREV72_72B_OPERATOR.md)) with coordinator `/health` OK.
2. Brain `deploy/.env` includes agent env vars (see [deploy/env.example](../deploy/env.example)).
3. `ALFA_AI_WORKSPACE_ROOT` points at the repo clone inside the API container.
4. For online search: SearXNG up on `hub` and `ALFA_AI_WEB_SEARCH_ENABLED=1`.
5. Agent runtime tables in Postgres: `bash scripts/ensure-runtime-schema.sh` on `hub`
   (idempotent; required once before first `POST /api/runs`).

**Pool72 online research (`hub`):** after `switch-pool-72b.sh` and coordinator green,
run `bash scripts/operator-pool72-research-enable.sh`, then
`bash scripts/verify-pool72-research-smoke.sh --enqueue-mission`.

### Create a research-only mission (offline)

```json
POST /api/runs
{"goal": "Research FastAPI lifespan vs on_event deprecation", "research_only": true}
```

Then `POST /api/runs/process-next` or enable `agent-worker` profile.

### Implement → review → check-work (WorkflowRunner)

```json
POST /api/runs
{"goal": "Add a healthz endpoint", "skill": "implement"}
```

or `"workflow": "implement_review_fix"`. Creates coder → review → check-work (max 3 fix rounds on `VERDICT: FAIL`). Mutate still requires `ALFA_AI_AGENT_MUTATE_ENABLED=1`.

### Error catalog + corrective actions (L0, no LLM required for skeleton)

```json
POST /api/runs
{"goal": "Catalog recent failures", "skill": "error-cataloger"}
```

```json
POST /api/runs
{"goal": "Propose corrective actions", "skill": "corrective-analyst"}
```

Catalog file: `$ALFA_AI_DATA/errors.jsonl` (default under workspace `.alfa_ai/`).

### Eval smoke (offline)

```bash
python scripts/eval/smoke_runner.py --self-check
```

### Structured review API (consumers)

```json
POST /api/agent/review
{"repo": "alfa-ai", "goal": "Security review", "focus": "security", "max_issues": 20}
```

Auth: Bearer `ALFA_AI_API_TOKEN`. Map multi-repo names via `ALFA_AI_AUDIT_ROOTS`.

### Scheduled audits

Operator runbook: [operations/SCHEDULED_AUDIT_MISSIONS.md](operations/SCHEDULED_AUDIT_MISSIONS.md).

### Judge dual-check (L1, default off)

```env
ALFA_AI_JUDGE_ENABLED=0
ALFA_AI_JUDGE_API_BASE=http://orchestrator/v1
```

Install: [operations/JUDGE_INSTALL_59.md](operations/JUDGE_INSTALL_59.md).

### Sleep curator (L2 Tier A)

```json
POST /api/runs
{"goal": "Nightly sleep curation", "skill": "sleep-curator"}
```

CLI: `python scripts/sleep_curator_nightly.py`  
Runbook: [operations/SLEEP_CURATOR_NIGHTLY.md](operations/SLEEP_CURATOR_NIGHTLY.md).

### Train pack export (L3 staging, no GPU)

```bash
python scripts/export_train_pack.py
# or skill=export-train-pack
```

Runbook: [operations/SLEEP_TRAIN_TIER_B.md](operations/SLEEP_TRAIN_TIER_B.md).

### Verify memory (offline round-trip)

1. Run mission A (`research_only: true`) to completion.
2. Inspect `$ALFA_AI_DATA/implement-memory/<hash>.md` for a new dated block.
3. Run mission B on a related topic in the **same workspace**.
4. Confirm mission B system context includes `## Recent missions` (operator SSE or logs).

### Verify online search

1. Start SearXNG on `hub` (see [deploy/searxng/README.md](../deploy/searxng/README.md)).
2. Set `ALFA_AI_WEB_SEARCH_ENABLED=1` in brain `.env`; recreate `alfa-ai-api`.
3. Run a mission whose goal requires discovering an external doc URL.
4. Confirm tool events include `web_search` and final Sources cite result URLs.

### Verify web_search disabled (fail closed)

With `ALFA_AI_WEB_SEARCH_ENABLED=0`, a `web_search` tool call returns
`{ok:false, error:"web_search disabled"}`. Offline tools still work.

### Deploy after code change

1. Commit/push from owning host.
2. On `hub`: `bash scripts/brain_redeploy_api.sh` (pulls + rebuilds) or
   `bash scripts/operator-pool72-research-enable.sh` when enabling Pool72 research.
3. Confirm coordinator healthy via LiteLLM before running missions (`frontier` on Pool72,
   `frontier-code` on inference).

## Related

- [ARCHITECTURE_SPEC.md](ARCHITECTURE_SPEC.md) - researcher role contract
- [OPERATOR_CONSOLE.md](OPERATOR_CONSOLE.md) - LAN UI
- [GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md) - 27B RPC pool
- [GREV72_72B_OPERATOR.md](GREV72_72B_OPERATOR.md) - Pool72 agent model + research enable
- [deploy/searxng/README.md](../deploy/searxng/README.md) - SearXNG on `hub`
