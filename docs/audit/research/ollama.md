# Ollama

> Research-agent output for the ALFa AI architecture audit (2026-05-13).
> Read by `audit-agent` to check `/home/operator/alfa-ai/` against upstream guidance.

## Official documentation

- **Primary docs URL:** https://github.com/ollama/ollama/tree/main/docs (canonical) and https://ollama.com
- **API/reference URL:** https://github.com/ollama/ollama/blob/main/docs/api.md
- **Release notes / changelog URL:** https://github.com/ollama/ollama/releases
- **Source repo URL:** https://github.com/ollama/ollama
- **OpenAI-compatibility doc:** https://github.com/ollama/ollama/blob/main/docs/openai.md

## Current stable / supported version (as of 2026-05-13)

- **Docker Hub (`ollama/ollama`):** **2026-10-03:** live cluster pin is **`ollama/ollama:0.35.1`** (GitHub v0.35.1, `prerelease=false`, 2026-09-29). RC lines such as **`0.40.0-rc0`** are **not** the pin; **`latest`** is a moving pointer. Compose + `hub_hub_models.sh` use **`0.35.1`** — bump only after confirming a newer GA tag on Hub and smoke-testing.
- **GitHub Releases UI:** May list tags that do not appear as Docker Hub image tags on the same day — treat Hub tags as the compose pin source of truth.
- **Pre-release:** `0.30.0-rc15` (2026-05-13). Runtime shifts toward **llama.cpp** — smoke-test before adopting. Source: https://github.com/ollama/ollama/releases
- **EOL policy:** Ollama does not publish a formal long-term support policy. The project ships rolling releases; users are expected to track recent releases and pin via `OLLAMA_VERSION=…` per the install scripts on https://ollama.com/download (Windows: `irm https://ollama.com/install.ps1 | iex`; Linux/macOS: `curl -fsSL https://ollama.com/install.sh | OLLAMA_VERSION=<tag> sh`).

## Key official best practices

- **Networking / bind:** By default `ollama serve` binds to `127.0.0.1:11434`. To expose to other hosts, set `OLLAMA_HOST=0.0.0.0:11434` (or a specific interface). Source: https://github.com/ollama/ollama/blob/main/docs/faq.md#how-do-i-configure-ollama-server (canonical FAQ; may render as `docs/faq.md` in the repo).
- **GPU autoselect (Windows!):** On Windows, Ollama defaults to **full GPU offload** when any CUDA-capable device is present. To force CPU-only inference (a real cluster requirement here on `hub` / `orchestrator` CPU MoE), set `CUDA_VISIBLE_DEVICES=` (empty) and `OLLAMA_NUM_GPU=0` in the service environment. There is no install-time prompt for CPU-only mode. Source: https://github.com/ollama/ollama/blob/main/docs/gpu.md and https://github.com/ollama/ollama/blob/main/docs/faq.md.
- **Process / service management:** Linux installer registers a systemd unit (`/etc/systemd/system/ollama.service`); Windows installer registers Ollama as a user-session app. For "always-on" Windows service behaviour the operator must register a separate service (e.g. `nssm`) or a `SYSTEM`-level Task Scheduler trigger — Ollama itself does not register a Windows service. Source: https://github.com/ollama/ollama/blob/main/docs/linux.md and https://github.com/ollama/ollama/blob/main/docs/windows.md.
- **Persistent state:** Models live under `OLLAMA_MODELS` (default `~/.ollama/models` on Linux/macOS, `%LOCALAPPDATA%\Ollama\models` on Windows when run as a user, `C:\Users\<user>\.ollama\models` per running account, `/usr/share/ollama/.ollama/models` for the systemd service). To share weights across reboots and avoid re-downloading multi-GB models, point `OLLAMA_MODELS` at a persistent volume. Source: https://github.com/ollama/ollama/blob/main/docs/faq.md#where-are-models-stored.
- **Concurrency:** Set `OLLAMA_NUM_PARALLEL` (per-model concurrent requests) and `OLLAMA_MAX_LOADED_MODELS` (number of models held in memory). Default `OLLAMA_NUM_PARALLEL=1` for single-user latency, increase for throughput. Source: https://github.com/ollama/ollama/blob/main/docs/faq.md#how-does-ollama-handle-concurrent-requests.
- **Keep-alive / VRAM eviction:** `OLLAMA_KEEP_ALIVE` (default `5m`) controls how long a loaded model stays resident. Use `-1` for "never unload" (production tier 0/1), `0` for "unload immediately" (CI). Source: https://github.com/ollama/ollama/blob/main/docs/faq.md#how-can-i-keep-a-model-loaded-or-unload-it-immediately.
- **OpenAI-compatible API:** Ollama exposes `/v1/chat/completions`, `/v1/completions`, `/v1/embeddings`, and `/v1/models` for OpenAI-SDK clients. `model` field accepts the Ollama tag (e.g. `qwen3-coder:30b-a3b-q4_K_M`). Source: https://github.com/ollama/ollama/blob/main/docs/openai.md.
- **Logging:** Linux: `journalctl -u ollama --no-pager`. Windows: `%LOCALAPPDATA%\Ollama\server.log`. macOS: `~/.ollama/logs/server.log`. Source: https://github.com/ollama/ollama/blob/main/docs/troubleshooting.md.

## Canonical configuration examples

**Linux systemd override** (verbatim shape from upstream FAQ — used to bind to all interfaces and tune concurrency):

```ini
# /etc/systemd/system/ollama.service.d/override.conf
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_KEEP_ALIVE=-1"
Environment="OLLAMA_NUM_PARALLEL=4"
Environment="OLLAMA_MAX_LOADED_MODELS=2"
Environment="OLLAMA_MODELS=/mnt/ssd/ollama/models"
```

Source: https://github.com/ollama/ollama/blob/main/docs/faq.md#setting-environment-variables-on-linux

**Windows CPU-only** (force CPU MoE on a GPU host such as `orchestrator`):

```powershell
# Set as machine-wide env for the user/service running Ollama
[Environment]::SetEnvironmentVariable("CUDA_VISIBLE_DEVICES","",  "Machine")
[Environment]::SetEnvironmentVariable("OLLAMA_NUM_GPU","0",       "Machine")
[Environment]::SetEnvironmentVariable("OLLAMA_HOST","0.0.0.0:11434","Machine")
```

Source: https://github.com/ollama/ollama/blob/main/docs/windows.md and https://github.com/ollama/ollama/blob/main/docs/gpu.md.

## Common pitfalls / gotchas

- **Windows defaults to GPU offload** even when CPU MoE is intended — must set `CUDA_VISIBLE_DEVICES=`/`OLLAMA_NUM_GPU=0` explicitly. Source: https://github.com/ollama/ollama/blob/main/docs/gpu.md.
- **Default `127.0.0.1` bind** prevents LAN access; LiteLLM running on a different host cannot reach it without `OLLAMA_HOST=0.0.0.0` (or an explicit interface). Source: https://github.com/ollama/ollama/blob/main/docs/faq.md.
- **`OLLAMA_KEEP_ALIVE` default 5m** evicts models from VRAM/RAM under idle; first-token latency after eviction is the full reload time (multi-GB MoE = many seconds). For a "speed tier" set `OLLAMA_KEEP_ALIVE=-1`. Source: https://github.com/ollama/ollama/blob/main/docs/faq.md.
- **0.30.0 RC switches the runtime to llama.cpp** — quantization names, GGUF compatibility, and performance characteristics may shift versus the **`0.23.x`-tagged Docker images** or newer GA tags. Pin an explicit Hub tag until smoke-tested. Source: https://github.com/ollama/ollama/releases (0.30.0-rc15 release note).
- **Ollama on Windows is *not* a Windows service by default.** A logout terminates it unless the operator wraps it in `SYSTEM`-account Task Scheduler or NSSM. Source: https://github.com/ollama/ollama/blob/main/docs/windows.md.
- **`/v1/models` returns Ollama tags, not OpenAI model ids.** LiteLLM `model:` fields must use Ollama tag syntax (`ollama_chat/qwen3-coder:30b-a3b-q4_K_M`) or `openai/<tag>` with `api_base` pointed at `/v1/`. Source: https://github.com/ollama/ollama/blob/main/docs/openai.md.

## Authoritative URLs to cite in our docs

- https://ollama.com
- https://github.com/ollama/ollama
- https://github.com/ollama/ollama/blob/main/docs/api.md
- https://github.com/ollama/ollama/blob/main/docs/openai.md
- https://github.com/ollama/ollama/blob/main/docs/faq.md
- https://github.com/ollama/ollama/blob/main/docs/gpu.md
- https://github.com/ollama/ollama/blob/main/docs/linux.md
- https://github.com/ollama/ollama/blob/main/docs/windows.md
- https://github.com/ollama/ollama/blob/main/docs/troubleshooting.md
- https://github.com/ollama/ollama/releases

## AUDIT CHECKLIST for the Audit Agent

1. Verify upstream Ollama doc URLs above are referenced from at least one of: `alfa-ai/docs/QWEN3_MIGRATION.md`, `alfa-ai/docs/DISTRIBUTED_AI.md`, `alfa-ai/docs/NODE_INVENTORY.md`. If not, flag missing citation.
2. **CPU-only enforcement on `orchestrator` and `hub`:** confirm the CPU MoE Ollama instances on `orchestrator` (Win11) and `hub` (hub) explicitly set `CUDA_VISIBLE_DEVICES=` (empty) and `OLLAMA_NUM_GPU=0` so the GPU is reserved for Petals/`rpc-server`. Check:
   - `orchestrator`: `deploy/cluster-members/orchestrator/deploy.ps1`, `operator-93/env.gateway.example`, any Task Scheduler XML or NSSM wrapper.
   - `hub`: hub Apps Ollama config (Dockge `:31014` chart YAML or `deploy/cluster-members/hub/`).
   - `gaming-c`, `gaming-b`: same env enforcement (these run *both* GPU Petals and CPU Ollama on shared host).
3. **`OLLAMA_HOST` bind:** confirm every Ollama instance referenced as a LiteLLM backend (`OLLAMA_FLEET_*_URL`) binds to `0.0.0.0:11434` or the LAN IP, not `127.0.0.1`. Check `deploy/env.example`, per-host env templates.
4. **Keep-alive on speed-tier hosts:** confirm `orchestrator`/`hub` Ollama services set `OLLAMA_KEEP_ALIVE=-1` (or `>=24h`) so the 30B MoE doesn't evict mid-session. Check per-host env files.
5. **Embedding host:** `gaming-c` runs `nomic-embed-text` on `:11434` per `EMBED_BASE_URL=http://orchestrator`. Confirm that `OLLAMA_HOST` and `OLLAMA_NUM_PARALLEL` are tuned for batch embedding traffic.
6. **Persistent storage:** `OLLAMA_MODELS` must point at the canonical pool: `hub` → `/mnt/ssd/ollama` per `CLUSTER_SHARED_STORAGE.md`; `orchestrator`/`gaming-c`/`gaming-b` → a non-default path that survives Docker Desktop / WSL2 restarts. Verify per-host paths in `deploy/cluster-members/<host>/`.
7. **Windows persistence:** confirm `orchestrator`/`gaming-c`/`gaming-b`/`gaming-a` Ollama is wrapped in a Task Scheduler trigger running as `SYSTEM` (or NSSM service) so it survives logout — Ollama installer alone does not do this. See companion `windows-task-scheduler.md`.
8. **Version pin:** confirm production hosts pin `OLLAMA_VERSION` (or container tag) to a stable 0.29.x release rather than tracking `latest` (which would auto-pull `0.30.0-rc*`).
9. **OpenAI-compat model strings:** verify `deploy/litellm_config.yaml` references match Ollama tag convention: `ollama_chat/qwen3-coder:30b-a3b-q4_K_M` (not `openai/qwen3-coder:...`). Cross-check against the OpenAI-compat doc.
10. **Concurrent requests:** verify `OLLAMA_NUM_PARALLEL` is set per-host based on CPU/RAM headroom (per `NODE_INVENTORY.md` capacity), not left at the default `1` if multiple LiteLLM workers may queue.
