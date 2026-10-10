# G-rev27 operator runbook — Qwen3.6-27B on `inference`

Production **`frontier-code`** tier: **Qwen3.6-27B Q4_K_M** on **`inference` RTX 3060 (12 GB) +
RTX 3050 (6 GB)** via local **`llama-server`** on **`:31358`**. No RPC, no Petals for this
model.

SSoT plan: [.cursor/plans/FOUR_HOST_FRONTIER_POOL.md](../.cursor/plans/FOUR_HOST_FRONTIER_POOL.md)
Phase **G-rev**.

**Stop on errors.** Do not proceed to the next step if the current step exits non-zero.

## Official references

| Topic | URL |
|-------|-----|
| HF download | https://huggingface.co/docs/huggingface_hub/en/guides/cli#hf-download |
| HF verify (`hf cache verify`) | https://huggingface.co/docs/huggingface_hub/en/guides/cli#hf-cache-verify |
| llama.cpp multi-GPU | https://github.com/ggml-org/llama.cpp/blob/master/docs/multi-gpu.md |
| `llama-server` flags | https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md |

## Model artifact

| Field | Value |
|-------|-------|
| HF repo | `unsloth/Qwen3.6-27B-GGUF` |
| File | `Qwen3.6-27B-Q4_K_M.gguf` (~17 GB) |
| Hub path (`hub`) | `/mnt/HDDs/Alfa-AI/llama-cpp/models/` |
| Worker NFS | `/mnt/cluster/llama-cpp/models/` |
| LiteLLM alias | `frontier-code` / `qwen3.6-27b` |
| Endpoint | `http://orchestrator/v1` |

## `inference` GPU layout (official: layer split + CPU spill)

Per [multi-gpu.md](https://github.com/ggml-org/llama.cpp/blob/master/docs/multi-gpu.md):

| Phase | GPU | Flags |
|-------|-----|-------|
| **1 preflight** | RTX 3060 (12 GB) only | `--split-mode none`, `--fit on`, omit `-ngl`/`-c` |
| **2 production** | 3050 + 3060 | `--split-mode layer`, `-ts 1,2`, `--fit on`, omit `-ngl`/`-c` |

`--fit` sets GPU layer count and context; overflow layers run on **`inference` CPU** (official
last-resort path). Do **not** pin `N_GPU_LAYERS` or `CTX_SIZE` in `.env.rpc`.

| Env | Default | Meaning |
|-----|---------|---------|
| `FIT_TARGET_GPU1` | `1536` | 3060 preflight VRAM margin (MiB) |
| `FIT_TARGET` | `512,1536` | 3050,3060 margins for dual-GPU |
| `FIT_CTX` | `2048` | Minimum ctx `--fit` may use |
| `LOAD_TIMEOUT_GPU1` | `600` | Phase 1 health wait (s); docs silent on 27B load time |
| `LOAD_TIMEOUT_DUAL` | `900` | Phase 2 health wait (s) |
| `THREADS` | `12` | CPU threads for spilled layers |

`deploy-grev27-local.sh` is **one-shot**: phase 2 runs only if phase 1 `/health` passes.
No automatic retries on failure.

---

## Runbook (ordered)

### Phase 0 — Repo (`apps` only)

Commit and push G-rev27 scripts before any host pulls.

**Step 0a — From `apps` (ansible):**

```bash
cd /home/operator/alfa-ai && git pull --ff-only origin main
```

**Step 0b — From `apps` (ansible):** commit + push (author runs after agent edits land).

**Step 0c — From `orchestrator` (operator):**

```powershell
cd C:/Users/operator\alfa-ai
git pull --ff-only origin main
```

---

### Phase 1 — Hub model (`hub` only)

Internet download **only on `hub`**. Verify **before** remove (baseline). Remove, pull,
verify again **before** any worker deploy.

Requires **`hf` CLI** on `hub` for checksum verify
(https://huggingface.co/docs/huggingface_hub/en/guides/cli). Set **`HF_TOKEN`** (read
token) if the repo returns 401.

**Step 1 — From `hub` (hub shell as `operator`):** sync repo.

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai && git pull --ff-only origin main
```

**Step 2 — From `hub` (operator):** hub status (optional diagnostic).

```bash
sudo bash scripts/hub_hub_models.sh status
```

**Step 3 — From `hub` (operator):** verify existing 27B GGUF against Hub checksums.

```bash
sudo bash scripts/hub_hub_models.sh verify gguf27
```

If verify fails, continue to Step 4 (reseed). If verify passes and you do **not** need
reseed, skip Steps 4–6 and go to Phase 2.

**Step 4 — From `hub` (operator):** remove local 27B file (required before re-pull).

```bash
sudo bash scripts/hub_hub_models.sh rm gguf27
```

**Step 5 — From `hub` (operator):** download from Hub + auto-verify after fetch.

```bash
sudo bash scripts/hub_hub_models.sh pull gguf27
```

**Step 6 — From `hub` (operator):** explicit post-pull verify (must pass before `inference`
deploy).

```bash
sudo bash scripts/hub_hub_models.sh verify gguf27
```

Alternative for Steps 4–6 in one logged script:

```bash
bash deploy/cluster-members/hub/reseed-grev27-gguf.sh
```

Log path: `/tmp/reseed-grev27-*.log`. Optional SCP to `inference` hub:

```bash
scp /tmp/reseed-grev27-*.log operator@orchestrator:/home/operator/alfa-ai/logs/hub-seed/
```

---

### Phase 2 — `inference` deploy

`inference` has no GitHub deploy key — sync deploy tree from `apps` **after** push.

**Step 7 — From `apps` (ansible):** rsync deploy to `inference`.

```bash
rsync -av --exclude '.env' /home/operator/alfa-ai/deploy/ operator@orchestrator:~/alfa-ai/deploy/
```

**Step 8 — From `inference` (`operator`):** confirm GGUF on NFS (read-only; no internet fetch).

```bash
test -f /mnt/cluster/llama-cpp/models/Qwen3.6-27B-Q4_K_M.gguf && du -h /mnt/cluster/llama-cpp/models/Qwen3.6-27B-Q4_K_M.gguf
```

**Step 9 — From `inference` (`operator`):** deploy local dual-GPU llama-server.

```bash
bash ~/alfa-ai/deploy/cluster-members/inference-coordinator/deploy-grev27-local.sh
```

Stops Code27 rpc-server (`:31357`) and Ollama; starts `llamacpp-server-148-local` on
`:31358`; waits up to 900s on `/health`.

**Step 10 — From `inference` (`operator`):** verify server health.

```bash
curl -fsS http://127.0.0.1:31358/health
```

**Step 11 — From `inference` (`operator`):** verify model alias.

```bash
curl -fsS http://127.0.0.1:31358/v1/models
```

---

### Phase 3 — LiteLLM (`hub`)

Recreate LiteLLM **only after** Step 10 passes.

**Step 12 — From `hub` (operator):** confirm `deploy/.env` contains:

```
LLAMACPP_CODE27_URL=http://orchestrator/v1
```

**Step 13 — From `hub` (operator):** recreate LiteLLM.

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy && sudo docker compose --env-file .env up -d --force-recreate alfa-ai-litellm
```

**Step 14 — From `hub` (operator):** wait for liveliness.

```bash
bash deploy/cluster-members/_common/wait-litellm-liveliness.sh 120
```

**Step 15 — From `hub` (operator):** smoke test.

```bash
curl -fsS http://127.0.0.1:8413/v1/models | grep -E 'qwen3.6-27b|frontier-code'
```

---

## Retired paths (do not use for 27B)

| Path | Status |
|------|--------|
| Code27 RPC (`hub`/`apps`/`inference:31357` + CPU coordinator `orchestrator:31360`) | Superseded |
| `qwen3.5:27b` Ollama on `gaming-c` | Removed (Phase G-rev) |
| Petals for 27B | Not applicable — Petals serves tier 3a **70B** only |

## Repo files

| File | Role |
|------|------|
| `deploy/llamacpp-rpc/scripts/fetch-qwen3-coder.sh` | `PROFILE=code` hub fetch + `hf cache verify` |
| `deploy/cluster-members/_common/hf-gguf-hub.sh` | Shared HF download/verify helpers |
| `deploy/cluster-members/hub/reseed-grev27-gguf.sh` | Hub remove + pull + verify |
| `deploy/cluster-members/hub/verify-grev27-gguf.sh` | Hub verify only |
| `deploy/cluster-members/inference-coordinator/write-grev27-env.sh` | Writes `.env.rpc` for dual-GPU |
| `deploy/cluster-members/inference-coordinator/deploy-grev27-local.sh` | Deploy entrypoint |
| `deploy/llamacpp-rpc/docker-compose.rpc-main.local-dual-gpu.yml` | Compose overlay |
| `scripts/hub_hub_models.sh` | `pull|verify|rm gguf27` hub commands |
