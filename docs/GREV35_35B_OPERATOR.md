# G-rev35 operator runbook -- Qwen3.6-35B-A3B MoE RPC pool (Phase H)

Production **`fast`** / **`qwen3.6:35b-a3b`**: **Qwen3.6-35B-A3B UD-Q4_K_XL** MoE on the **same 4-GPU RPC pool**
as inference (**~32 GB** VRAM nominal). **CPU coordinator on `hub` `:31360`** (7900X); four
**`rpc-server`** GPU shards shared with inference (no shard redeploy when swapping models).

**Shard list (must match inference):** `deploy/llamacpp-rpc/pool35-shards.env` --
regenerate `.env.rpc` on `hub` with `write-grev35-env.sh`.

**MoE placement:** coordinator uses **`--fit on`** (CPU-RAM spill for inactive experts);
inference uses fixed **`--tensor-split`** / **`--fit off`**.

SSoT: [.cursor/plans/FOUR_HOST_FRONTIER_POOL.md](../.cursor/plans/FOUR_HOST_FRONTIER_POOL.md).

**Stop on errors.** Do not proceed if the current step exits non-zero.

## Official references

| Topic | URL |
|-------|-----|
| llama.cpp RPC | https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md |
| Multi-GPU / fit | https://github.com/ggml-org/llama.cpp/blob/master/docs/multi-gpu.md |
| `llama-server` flags | https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md |
| HF verify | https://huggingface.co/docs/huggingface_hub/en/guides/cli#hf-cache-verify |

## Topology (4-shard pool, shared with inference)

| Load order | Host | GPU | Port | Notes |
|------------|------|-----|------|-------|
| **coord** | `hub` | **CPU** | `:31360` | **llama-server** MoE coordinator |
| 1 (fastest) | `inference` | RTX 3060 | `:31356` | rpc-server shard |
| 2 | `inference` | RTX 5060 | `:31357` | rpc-server shard |
| 3 | `orchestrator` | RTX 3060 | `:31350` | rpc-server shard (WSL) |
| 4 (slowest) | `hub` | RTX 3050 | `:31353` | rpc-server shard (tail) |

Default from `pool35-shards.env`:

`RPC_BACKENDS=orchestrator,orchestrator,orchestrator,127.0.0.1:31353`

**RAG:** embed/rerank on `pool-opt-in` (orchestrator `start-rag`); unchanged when swapping pools.

## VRAM budget

| Layout | Physical GPU VRAM | Model weights (UD-Q4_K_XL MoE) | Headroom (approx.) |
|--------|-------------------|-------------------------------|--------------------|
| **4-shard (shared)** | **~32 GB** | ~22-24 GB total; ~3B active/token | CPU spill on `hub`/`orchestrator` via `--fit on` |

## Model artifact

| Field | Value |
|-------|-------|
| HF repo | `unsloth/Qwen3.6-35B-A3B-GGUF` |
| File | `Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf` |
| Hub path (`hub`) | `/mnt/HDDs/Alfa-AI/llama-cpp/models/` |
| Worker NFS (`inference`) | `/mnt/cluster/llama-cpp/models/` |
| LiteLLM aliases | `fast`, `chat`, `qwen3.6:35b-a3b`, ... |
| Endpoint | `http://127.0.0.1:31360/v1` (brain on `hub`) |

Seed on `hub` only:

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/llamacpp-rpc
PROFILE=moe35 MODELS_DIR=/mnt/HDDs/Alfa-AI/llama-cpp/models ./scripts/fetch-qwen3-coder.sh
```

## Mutual exclusion

- **27B coordinator** and **35B coordinator** both use **`hub` CPU `:31360`** -- only one at a time.
- **`switch-pool-35b.sh`** stops 27B coordinator containers and sets `LLAMACPP_CODE27_URL` to a
  sentinel (`http://127.0.0.1:31399/v1`) so the picker does not mark `frontier-code` active while 35B
  owns `:31360`.
- **`switch-pool-27b.sh`** restores 27B env and points `LLAMACPP_35B_URL` at Ollama on `orchestrator`
  (kept as a live standby endpoint; not used for the `inference.yaml` universal-alias rows, which
  route through `LLAMACPP_CODE27_URL` instead -- see
  [POOL_SWITCH_OPERATOR.md](POOL_SWITCH_OPERATOR.md#universal-alias-coverage-mandatory----default-for-every-consuming-repo)).
- GPU **shards stay up** when swapping; only coordinator + brain `.env` / LiteLLM overlay change.
- **Universal alias coverage:** `litellm_config.pool35.yaml` also registers `frontier-code` /
  `qwen3.6-27b` / `operator_internal`, routed to the live **35B** model via `LLAMACPP_35B_URL`.
  contracts-bot (or any repo) asking for `frontier-code` while pool35 is active gets answered by
  the 35B model instead of an error -- see
  [POOL_SWITCH_OPERATOR.md](POOL_SWITCH_OPERATOR.md#universal-alias-coverage-mandatory----default-for-every-consuming-repo).

---

## Runbook (ordered)

### Phase 0 -- Repo

**From `hub` (operator):** `git pull --ff-only origin main`

### Phase 0 -- Hub model (`hub`)

Verify or fetch 35B GGUF (hub-only download):

```bash
LEAD=/mnt/HDDs/Alfa-AI/llama-cpp/models/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf
test -f "$LEAD" || (cd /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/llamacpp-rpc && PROFILE=moe35 MODELS_DIR=/mnt/HDDs/Alfa-AI/llama-cpp/models ./scripts/fetch-qwen3-coder.sh)
```

### Phase 1 -- GPU shards (prerequisite)

**Same shards as inference** must be TCP-reachable before starting the 35B coordinator.
If the cluster was running inference, shards are already up. Otherwise follow
[GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md) Phase 2 (`orchestrator`, `inference` deploy scripts).

Verify from **`inference` hub**:

```bash
cd ~/alfa-ai
inference_VERIFY_RETRIES=30 bash deploy/cluster-members/_common/verify-inference-shards.sh deploy/llamacpp-rpc/pool35-shards.env
```

### Phase 2 -- Operator start-pool35 (`hub`)

**From `hub` (operator)** after remote shards pass preflight:

```bash
bash /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/cluster-members/hub/operator-cluster-111.sh start-pool35
```

Or piecemeal: `switch-pool-35b.sh` -> `deploy-grev35-coordinator.sh`.

Sets `LLAMACPP_35B_URL=http://127.0.0.1:31360/v1` in brain `deploy/.env`.

### Phase 3 -- LiteLLM + brain stack (`hub`)

**Canonical start:**

```bash
sudo bash scripts/start.sh
```

Or via orchestrator pause: `operator-cluster-111.sh start-brain`

### Phase 4 -- 35B-only picker + LiteLLM routing

After coordinator is green, **`switch-pool-35b.sh`** (inside `start-pool35`) sets:

| Variable | Value |
|----------|-------|
| `LLAMACPP_35B_URL` | `http://127.0.0.1:31360/v1` |
| `LLAMACPP_CODE27_URL` | `http://127.0.0.1:31399/v1` (sentinel; 27B stopped) |
| `ALFA_INFERENCE_MODE` | `default` |
| `CHAT_MODELS` | `fast,qwen3.6:35b-a3b` |
| `DEFAULT_MODEL` | `fast` |
| `LITELLM_CONFIG` | `litellm_config.pool35.yaml` |

Recreate brain stack so API + LiteLLM pick up env:

```bash
sudo bash scripts/start.sh
```

### Verify

Coordinator health:

```bash
curl -fsS http://127.0.0.1:31360/health
curl -fsS http://127.0.0.1:31360/v1/models | grep qwen3.6-35b-a3b
```

LiteLLM smoke:

```bash
curl -fsS http://127.0.0.1:8413/v1/models | grep -E 'fast|qwen3.6:35b-a3b'
```

**Cold start:** first completion after coordinator restart may take **~4 minutes**
(estimate for UI progress bar until benchmarked in [inference_BENCHMARKS.md](inference_BENCHMARKS.md)).
Warm requests are faster once `/health` returns `ok`.

**Picker smoke (authenticated `/alfa-ai/api/config`):**

- While pool35 is active: `fast` and `qwen3.6:35b-a3b` show **`active: true`**; `frontier-code` is
  shown **inactive** in the picker (`CHAT_MODELS`/`ALFA_INFERENCE_MODE` still say pool35) but
  **still answers requests** (served by the 35B model) per universal alias coverage.
- After switching back with `operator-cluster-111.sh start-pool` + `start-brain`: `frontier-code` /
  `qwen3.6-27b` active; speed-tier aliases inactive in the picker (`ALFA_INFERENCE_MODE=inference`)
  but still answer requests (served by the 27B model).

### Switch back to 27B

**From `hub` (operator):**

```bash
bash deploy/cluster-members/hub/operator-cluster-111.sh start-pool
sudo bash scripts/start.sh
```

Or full cluster cycle from `orchestrator`: `Start-Stop-AlfaAi.ps1 stop` then `start`.

**From chat UI (admin):** see [POOL_SWITCH_OPERATOR.md](POOL_SWITCH_OPERATOR.md) for picker
Activate + progress bar (requires `pool-switchd` on `hub`).

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Shard preflight FAIL | Same as [GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md); shards are shared |
| Coordinator Exited during MoE load | Hub llama.cpp **b8552+** on all hosts; `--fit on` needs CPU RAM headroom on `hub` |
| Picker shows both 27B and 35B active | Confirm `LLAMACPP_CODE27_URL` sentinel (`:31399`) while on pool35; recreate API + LiteLLM |
| `frontier-code` / `qwen3.6-27b` return wrong (35B-quality) answers while pool35 is active | Expected -- universal alias coverage routes them to the live 35B model instead of erroring. Switch to inference if 27B-specific quality is required. |
| 35B vs 27B conflict on `:31360` | Run only one `switch-pool-*` / `start-pool*` at a time |
| GGUF missing | `PROFILE=moe35` fetch on `hub` only (hub-first policy) |
| LiteLLM liveliness timeout | Postgres + Redis up before `--force-recreate alfa-ai-litellm` |
