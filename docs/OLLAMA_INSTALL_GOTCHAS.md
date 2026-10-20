# Ollama install gotchas (per OS)

This doc captures non-obvious defaults that bit us during install/rollout.
**Read it BEFORE installing Ollama on a new host.** It is the topic-specific
extension of the general agent rule `pre-install-research.mdc` (stored at the
operator's user-level Cursor rules, `~/.cursor/rules/`): always read the
official docs *for the exact host OS and the role this program will serve in
the cluster* before installing — defaults assume single-purpose machines.

## Docker Hub image pin (cluster repos)

The **`ollama/ollama:latest`** tag is a moving pointer and may not track the same
revision as desktop installers. Docker Hub also publishes **`0.30.0-rc*`** lines
alongside sparse non-RC tags. **ALFa AI pins** the optional in-compose GPU image
and the hub hub helper default to **`ollama/ollama:0.35.1`** — GitHub release
**v0.35.1** is non-prerelease (2026-09-29):
https://github.com/ollama/ollama/releases/tag/v0.35.1 — Docker Hub tag **`0.35.1`**
matches. Do **not** pin **`0.40.0-rc0`** or **`:latest`**. Override per host with
**`OLLAMA_DOCKER_IMAGE`** or a compose **`image:`** edit after smoke-testing.

## Windows — Ollama defaults to full GPU offload (May 2026)

**Affected hosts:** `operator-93` (Win11, dual RTX 3060 12 GB).

### Symptom

- After install + `ollama serve`, `nvidia-smi` shows both GPUs at ~90% memory
  used:
  ```
  0, NVIDIA GeForce RTX 3060, 11250 MiB, 12288 MiB
  1, NVIDIA GeForce RTX 3060, 10889 MiB, 12288 MiB
  ```
- `/api/ps` returns `size_vram` ≈ 20 GB for the 30B MoE model.
- Petals workers and llama.cpp `rpc-server` shards fail to start on `orchestrator`
  (CUDA out-of-memory) because the GPUs they were reserved for are already
  claimed.

### Root cause

The official Ollama Windows installer enables CUDA inference automatically
whenever a CUDA-capable GPU is present. There is **no opt-out prompt during
install** — the default kicks in silently on the first `ollama serve`. The
auto-detection happens at model load time, not install time, so the gotcha
doesn't surface until the first inference request.

Reference: Ollama GPU docs —
[github.com/ollama/ollama/blob/main/docs/gpu.md](https://github.com/ollama/ollama/blob/main/docs/gpu.md).

### Canonical fix (used by `operator-93`)

Set these env vars **before** `ollama.exe serve`, in the launcher batch file
that the SYSTEM scheduled task runs. **Use the quoted `set "VAR=value"` form**
— unquoted `set VAR=` in cmd.exe actually **deletes** the variable, which CUDA
then interprets as "all GPUs visible" (the opposite of what we want):

```cmd
set "OLLAMA_LLM_LIBRARY=cpu"
set "CUDA_VISIBLE_DEVICES="
set "HIP_VISIBLE_DEVICES="
set "OLLAMA_NUM_GPU=0"
```

- `OLLAMA_LLM_LIBRARY=cpu` — **the decisive override** on Ollama **0.23+**.
  Verified May 2026 on Ollama 0.23.3 / Windows 11: with this set, the server
  reports `inference compute id=cpu library=cpu` and the runner logs
  `offloaded 0/49 layers to GPU` regardless of how many CUDA devices exist.
  Without it the other env vars alone are best-effort and may not stop
  fully-resident GPU offload.
- `CUDA_VISIBLE_DEVICES=` (empty, quoted) — canonical NVIDIA pattern, hides
  all GPUs from CUDA-aware processes. Must be **quoted** — see the cmd.exe
  caveat above.
- `HIP_VISIBLE_DEVICES=` (empty, quoted) — defensive equivalent for ROCm-built
  Ollama binaries.
- `OLLAMA_NUM_GPU=0` — explicit Ollama-internal override (best-effort on
  recent versions).

**Defense in depth — set all four.** Ollama internals change between
versions; setting all four ensures CPU-only across releases.

Authoritative template lives at
[`deploy/cluster-members/orchestrator/ollama-service.cmd.example`](../deploy/cluster-members/orchestrator/ollama-service.cmd.example).
Copy to `C:\Program Files\Ollama\ollama-service.cmd` on the host (requires
elevation) and register as a SYSTEM scheduled task with `AtStartup` trigger.

### Verify after restart

```powershell
nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv
Invoke-RestMethod http://127.0.0.1:11434/api/ps | ConvertTo-Json -Depth 3
```

- `memory.used` should be **< ~1 GiB per GPU** (Windows desktop overhead only —
  Cursor, browser, NVIDIA overlay, etc.).
- `/api/ps` should show `size_vram: 0` for the loaded model. The model lives
  entirely in regular RAM.

### GPUs reserved for tier-3 (CPU-only Ollama where present)

The general rule still holds: keep Ollama **CPU-only** so dGPUs stay free for
tier-3 (Petals 70B **OR** llama.cpp RPC 80B, mutually exclusive). **June 2026:**
the CPU chat pool is a two-host split — quality dense **`qwen3.5:27b`** on
**`gaming-c`** + speed **`qwen3.6:35b-a3b`** MoE on **`orchestrator`** (the May `gaming-c`-only
`qwen3:32b` and April `qwen3-coder:30b-a3b-q4_K_M` MoE fleet are superseded;
**requires Ollama `0.30.x`** — Gated-DeltaNet). `orchestrator`'s CPU MoE must run
**CPU-only** so its dGPUs stay free for Petals/RPC; `hub` runs only the
`qwen3:8b` operator model; `apps`/`gaming-a` run no chat LLM. This CPU-only
enforcement still applies wherever Ollama runs.

See [`NODE_INVENTORY.md`](NODE_INVENTORY.md).

## Linux (hub Scale `hub`) — Ollama runs CPU-only by default (Blackwell driver gap)

`hub` runs RTX 5060 (Blackwell). The NVIDIA driver / CUDA stack for Blackwell
on hub Scale 25.10 (Goldeye) is not yet usable for Ollama; the container
falls back to CPU automatically.

This is currently the **desired** behavior — it frees the 5060 for the future
Petals worker role on `hub`. No action required, but verify the same way
(`nvidia-smi` on the host should show 0 MiB used; `/api/ps` should report
`size_vram: 0`).

## Adding a new gotcha

If you discover a default that bites you, **append a section to this doc in
the same commit that fixes the misconfiguration.** Format:

```markdown
## <OS or context> — <one-line title>

### Symptom
### Root cause
### Canonical fix
### Verify
```
