# ALFa AI (public snapshot)

Local LLM brain with Docker-based deploy examples, LiteLLM routing, and optional multi-host
inference workers. This repository is a **scrubbed snapshot**; see `docs/PUBLIC_SNAPSHOT.md`.

## Configure before you run

1. **Prerequisites:** Docker (or your chosen container runtime) on the hosts you control.
2. Copy `config/hosts.example.env` to `config/hosts.env` and set your orchestrator, apps, hub, and
   other roles (do not commit `hosts.env`).
3. Copy `deploy/env.example` to `deploy/.env` where you run the brain stack; replace `change-me`
   placeholders and never commit live `.env` files.

---

# ALFa AI

AI agent that helps build programs. Uses an LLM + local tools (`read_file`, `list_dir`, `create_file`, `run_cmd`) to generate and edit code safely inside a configured workspace.

**Roadmap:** [docs/ROADMAP.md](docs/ROADMAP.md) — cluster status and sequencing. **Docs index:** [docs/INDEX.md](docs/INDEX.md).

**Production topology (Jul 2026):** **llama.cpp RPC only** (Petals **retired**). Brain + LiteLLM + protected Postgres/Redis on **`hub`**; inference coordinator **`hub:31360`**; shards on `inference` / `orchestrator` / `pool-opt-in` / `hub`; **CPU RAG (embed+rerank) on `inference`**; edge admin proxy **`inference:8420`**. Operator cluster start/stop: `orchestrator` `Start-Stop-AlfaAi.ps1` only.

## Setup

**Docker + NVIDIA + Compose (production-style):** see [docs/ALFA_AI_DOCKER_RUNBOOK.md](docs/ALFA_AI_DOCKER_RUNBOOK.md) (order: NVIDIA Toolkit → `docker run --gpus` test → `tunnel_network` → `.env` → compose). Optional GPU Ollama: `deploy/docker-compose.ollama-gpu.yml`.

1. `python -m venv .venv && source .venv/bin/activate` (or `\.venv\Scripts\activate` on Windows)
2. `pip install -r requirements.txt`
3. Copy `env.example` to `.env` and set provider keys or Ollama URL (see below).
4. Set `ALFA_AI_WORKSPACE_ROOT` to the folder ALFa AI is allowed to modify.

## Ubuntu VM + remote Ollama (Win11 on LAN)

When ALFa AI runs on a Linux VM and Ollama runs on a Windows PC on the same subnet:

1. On the Windows host, set **`OLLAMA_HOST=0.0.0.0`** (system environment variable) and restart Ollama so it listens beyond `127.0.0.1`.
2. On the Windows host, pull the canonical tier model with **`ollama pull qwen3-coder:30b-a3b-q4_K_M`** (MoE, 3B active — tiers 0/1/2 after the April 2026 cluster rebalance). Set **`DEFAULT_MODEL=qwen3-coder:30b-a3b-q4_K_M`** in `.env` to match.
3. In this repo’s `.env` on the VM: **`ALFA_AI_PROVIDER=ollama`**, **`OLLAMA_BASE_URL=http://<WIN11_LAN_IP>:11434`**, **`ALFA_AI_WORKSPACE_ROOT`** pointing at a dedicated sandbox directory (create it first).
4. From the VM, verify: **`curl http://<WIN11_LAN_IP>:11434/api/tags`** lists your models.

Set **`OLLAMA_BASE_URL` to exactly one primary host** (e.g. Win11 at `http://orchestrator`). If you also run Ollama on another machine (e.g. hub), it is unused by ALFa AI until you change this URL.

**Win11 + Cursor:** If **Cursor** is running on the same PC as Ollama, it may listen on **`127.0.0.1:11434`**, so `curl http://127.0.0.1:11434` can hit Cursor instead of Ollama. Use the PC’s **LAN IP** for checks and for `OLLAMA_BASE_URL` from other machines (e.g. `http://orchestrator`).

## Run

- `python -m src.main "Create a hello world in Python"`
- Or: `python -m src.main` for interactive mode.
- API + Web UI: `uvicorn src.api.app:app --host 127.0.0.1 --port 8412` (matches compose/systemd `ALFA_AI_API_HOST_PORT`; `8000` if you prefer a container-only port)

**Always-on API (systemd):** Copy [deploy/systemd/alfa-ai-api.service](deploy/systemd/alfa-ai-api.service) to `/etc/systemd/system/alfa-ai-api.service`, adjust `User`/`Group`/`WorkingDirectory`/`ExecStart` paths if needed, then:

`sudo systemctl daemon-reload && sudo systemctl enable --now alfa-ai-api.service`

## Runtime API

**Security:** When exposing this API beyond localhost, set **`ALFA_AI_REQUIRE_API_AUTH=true`** and **`ALFA_AI_API_TOKEN`** to a strong secret; send **`Authorization: Bearer <token>`** on `/api/runs*` requests. Default is **no auth** for local development. See `deploy/env.example` and `src/api/auth_deps.py`.

- `POST /api/runs` with `{ "goal": "..." }` creates a run and task graph.
- `GET /api/runs` lists runs.
- `GET /api/runs/{run_id}` returns run status and tasks.
- `GET /api/runs/{run_id}/artifacts` lists persisted role artifacts.
- `POST /api/runs/process-next` executes the next queued task.

By default, runtime state uses in-memory store/queue. Set `DATABASE_URL` and `REDIS_URL` to enable Postgres/Redis-backed adapters.

Current role executors generate concrete artifacts under `.alfa_ai/artifacts/<run_id>/<task_id>/`:

- `researcher` -> `research.md`
- `coder` -> `implementation.py`
- `debugger` -> `debug-report.json`
- `doc_maker` -> `README.generated.md`

## Web UI

- Start API: `uvicorn src.api.app:app --host 127.0.0.1 --port 8412` (or use systemd — see above)
- Open: `http://127.0.0.1:8412/` (or SSH tunnel from another machine)
- The UI supports creating runs, listing runs, processing next task, and viewing tasks/artifacts.
- For Docker deployment ports, use `docs/PORT_ASSIGNMENTS.md`.
- Run preflight before compose startup: `./scripts/preflight_ports.sh deploy/.env`
- Public **Admin → Health** on `www` (repos, URLs, JWT vs brain-only API): **[docs/ADMIN_HEALTH_WEB_WORKFLOW.md](docs/ADMIN_HEALTH_WEB_WORKFLOW.md)**
- **Local web stack** (Vite + API, `http://127.0.0.1:5173/alfa-ai/`): `./scripts/dev_alfa_web.sh` after `pip install -r requirements.txt` and `cd frontend && npm ci`. Set `DATABASE_URL` and `ALFA_AI_JWT_SECRET` for auth (see `deploy/env.example`).

## Current Capabilities & Use Cases

For a detailed analysis of what ALFa AI can build with current hardware constraints, see `docs/CURRENT_CAPABILITIES_AND_USE_CASES.md`. This includes:

- Realistic project scope (300-800 lines, 2-4 database tables)
- High-value use cases for development and system administration
- Expected code quality and iteration requirements
- Recommended starting projects for immediate value

## Rankings-bot + LiteLLM (Ask AI / public demo)

After LiteLLM is up (`docker compose … alfa-ai-litellm`), enable **`LITELLM_ENABLED`** in rankings-bot — full steps: **[rankings-bot docs/ALFA_AI_HOW_TO_USE.md](../rankings-bot/docs/ALFA_AI_HOW_TO_USE.md)**.

## Operator console (LAN)

Chat + orchestrator missions in the browser: **[docs/OPERATOR_CONSOLE.md](docs/OPERATOR_CONSOLE.md)** — Docker Compose default **`http://<host>:8420/operator/`** (not 8020). Edge path via `inference` admin proxy is documented in [docs/PORT_ASSIGNMENTS.md](docs/PORT_ASSIGNMENTS.md).

**Security (production):** set `ALFA_AI_REQUIRE_API_AUTH=true`, a strong `ALFA_AI_API_TOKEN`, and a unique `LITELLM_API_KEY` / master key (never leave shared dev placeholders). See [docs/audit/SENIOR_AUDITOR_REPORT.md](docs/audit/SENIOR_AUDITOR_REPORT.md).

## Inference (RPC-only)

Petals/Hivemind is **retired** (2026-07-09). Active path: LiteLLM → llama.cpp RPC inference (`frontier-code` / `qwen3.6-27b`). Historical notes only under [docs/history/](docs/history/). Node list: [docs/NODE_INVENTORY.md](docs/NODE_INVENTORY.md). Distributed AI SSoT: [docs/DISTRIBUTED_AI.md](docs/DISTRIBUTED_AI.md).

## Rankings-Bot Reuse Analysis

- Module extraction plan: `docs/RANKINGS_BOT_REUSE_MAP.md`

## Tool Call Protocol

The agent loop supports a simple JSON tool-call protocol from the LLM:

```json
{"tool":"list_dir","args":{"path":"."}}
```

If the model returns valid tool JSON, ALFa AI executes the tool and continues the loop. If the model returns plain text, that text is treated as the final answer.

## Safety

- Filesystem writes/reads are sandboxed to `ALFA_AI_WORKSPACE_ROOT`.
- Commands run with timeout (`ALFA_AI_COMMAND_TIMEOUT_SEC`).
- Dangerous command fragments are blocked (for example `rm -rf /`, `shutdown`, `mkfs`).
- Command output is truncated by `ALFA_AI_MAX_COMMAND_OUTPUT_CHARS`.

## Known Limits

- Tool parsing currently supports one JSON tool call per assistant turn.
- No long-term memory or DB persistence yet (planned next phases).

## Structure

- `src/agent/` – agent loop and tools
- `src/agent/roles/` - role contracts for coder/debugger/doc-maker/researcher
- `src/api/` - FastAPI API entry for self-host deployment baseline
- `src/llm/` – LLM client
- `src/config.py` – configuration
- `docs/` - architecture and planning specs
- `deploy/` - docker compose + nginx baseline
