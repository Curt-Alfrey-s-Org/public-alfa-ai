# LoRA adapter operator (two pipelines)

> **Status:** Registry + coordinator wrapper in repo (2026-08-11). This doc covers
> **two separate LoRA paths** -- do not mix them.
>
> Official llama.cpp LoRA:
> [server README `--lora`](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md),
> [convert_lora_to_gguf.py](https://github.com/ggml-org/llama.cpp/blob/master/convert_lora_to_gguf.py),
> [lora hotswap API](https://github.com/ggml-org/llama.cpp/pull/8857).

| Pipeline | Base model | Serve target | Doc |
|----------|------------|--------------|-----|
| **A -- 7B QLoRA** | Qwen2.5-Coder-7B-Instruct | Standalone `llama-server` **`gaming-c:8470`** (`--lora`) | [TRAIN_7B_QLORA_GUI.md](TRAIN_7B_QLORA_GUI.md), [ALFA_7B_SERVE_ALONGSIDE_27B.md](ALFA_7B_SERVE_ALONGSIDE_27B.md) |
| **B -- 27B coordinator LoRA** | Qwen3.8-27B (inference `MODEL_FILE`) | RPC coordinator **`hub:31360`** (`LORA_GGUF`) | [SLEEP_TRAIN_TIER_B.md](SLEEP_TRAIN_TIER_B.md), [DATA_FLYWHEEL_OPERATOR.md](DATA_FLYWHEEL_OPERATOR.md) |

Related: [ALFA_CODER_DRAFT_ALIAS.md](ALFA_CODER_DRAFT_ALIAS.md),
[HUB_ARTIFACTS.md](../HUB_ARTIFACTS.md).

## Policy (both pipelines)

| Rule | Detail |
|------|--------|
| **7B QLoRA is NOT coordinator LoRA** | Qwen2.5-Coder-7B adapters from [TRAIN_7B_QLORA_GUI.md](TRAIN_7B_QLORA_GUI.md) serve on **standalone** `llama-server` `gaming-c:8470` ([ALFA_7B_SERVE_ALONGSIDE_27B.md](ALFA_7B_SERVE_ALONGSIDE_27B.md)). Do **not** set `--lora` on inference `hub:31360` -- base weights and vocab differ from Qwen3.8-27B. **7B eval is standalone on `gaming-c` (sequential base then adapter on `:8470`), not coordinator `--lora`.** |
| Hub-first | Convert + store GGUF on **`hub`** only |
| Eval gate | **>= 70%** is a cluster smoke / operator bar (held-out eval, `train_checkpoint_gate.py`, learning-loop gate). Neither llama.cpp nor LiteLLM enforces this automatically. |
| Full mesh (27B only) | Coordinator LoRA apply requires **coordinator down** -> set env -> full stop + start |

Pipeline **B** LoRA adapters apply on the **coordinator** `llama-server` (`hub:31360`), not on
individual `rpc-server` shards. Pipeline **A** never touches the coordinator.

---

## Pipeline A -- 7B QLoRA (`gaming-c:8470`)

**Goal:** Home-trained Qwen2.5-Coder-7B QLoRA on the train island; serve with
[`llama-server --lora FNAME`](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
on **`gaming-c:8470` only**. Optional LiteLLM alias `alfa-coder-draft` only after eval pass **and**
operator promote ([ALFA_CODER_DRAFT_ALIAS.md](ALFA_CODER_DRAFT_ALIAS.md)).

**Do not** promote 7B GGUF to `hub:31360`. Do not set `LORA_GGUF` in inference `.env.rpc` for
7B adapters.

### A.1 Train (alfa-train on `gaming-c` / `gaming-b`)

See [TRAIN_7B_QLORA_GUI.md](TRAIN_7B_QLORA_GUI.md). Output: PEFT adapter under hub
`training/alfa-train/checkpoints/pool-7b-qlora-v2/` (`adapter_model.safetensors` +
`adapter_config.json`). `inference` stays on inference core -- not a train rank.

### A.2 Convert to GGUF (`hub` only)

Use the **7B** convert wrapper (sets `--base` from the local HF snapshot with
`config.json`; **not** inference `MODEL_FILE`). Restage v2 with `FORCE_LORA_CONVERT=1`
so an existing GGUF is not skipped:

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai
sudo env \
  CHECKPOINT_DIR=/mnt/HDDs/Alfa-AI/training/alfa-train/checkpoints/pool-7b-qlora-v2 \
  ADAPTER_ID=pool-7b-qlora-v2 \
  FORCE_LORA_CONVERT=1 \
  bash deploy/cluster-members/hub/convert-7b-qlora-to-gguf.sh
```

Official flags
([convert_lora_to_gguf.py](https://github.com/ggml-org/llama.cpp/blob/master/convert_lora_to_gguf.py)):
`--outfile`, `--outtype f16`, `--base` = Hugging Face **config directory** (`config.json`),
not the serve GGUF.

Hub layout for 7B:

```
/mnt/HDDs/Alfa-AI/llama-cpp/lora/qwen25-coder-7b/
  pool-7b-qlora-v1.gguf    # parked production default until v2 gate passes
  pool-7b-qlora-v2.gguf    # distinct filename; do not overwrite v1
```

### A.3 Eval / smoke (standalone `gaming-c:8470` -- not LiteLLM)

Sequential eval on one `llama-server` at a time (12 GB GPU). Full SSoT:
[ALFA_7B_SERVE_ALONGSIDE_27B.md](ALFA_7B_SERVE_ALONGSIDE_27B.md) **After training**.

1. `Start-Alfa7bServe.ps1 -NoLora` -> `generate_7b_eval_answers.py` (base) -> stop.
2. `Start-Alfa7bServe.ps1 -LoraGguf pool-7b-qlora-v2.gguf` -> generate checkpoint answers -> stop.
3. `train_checkpoint_gate.py` -- **cluster smoke log** (`promote_allowed` is script
   output; informational). Then **live FAQ chat** on `:8470` (three frozen Yes/No
   prompts in [ALFA_7B_SERVE_ALONGSIDE_27B.md](ALFA_7B_SERVE_ALONGSIDE_27B.md)).

**Do not** set `LLAMACPP_7B_URL` or recreate LiteLLM during eval or live chat. The
>= 70% bar is cluster smoke only -- not enforced by llama.cpp or LiteLLM.

### A.4 Serve (operator -- `gaming-c:8470` only)

After live FAQ Yes/No is correct **and** the operator wants to serve:

```powershell
# From orchestrator (operator) when gaming-c GPU is free
cd C:/Users/operator\alfa-ai
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-Alfa7bServe.ps1 -LoraGguf pool-7b-qlora-v2.gguf
```

Standalone server applies `--lora` per
[server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md).
Verify:

```powershell
curl.exe -fsS --max-time 10 http://orchestrator/health
```

Optional LiteLLM route (post-promote only): set `LLAMACPP_7B_URL` on `hub` and recreate
LiteLLM per [ALFA_CODER_DRAFT_ALIAS.md](ALFA_CODER_DRAFT_ALIAS.md). Production default stays
`frontier-code` on `hub:31360`.

### A.5 Rollback (7B)

`Stop-Alfa7bServe.ps1`. Clear `LLAMACPP_7B_URL` if set. inference coordinator unchanged.

---

## Pipeline B -- 27B coordinator LoRA (`hub:31360`)

**Goal:** LoRA trained for the **same base** as inference production (`qwen3.6-27b` /
Qwen3.8-27B GGUF). Apply via coordinator env `LORA_GGUF` -- **not** the 7B adapter path.

| Rule | Detail |
|------|--------|
| Train source | Learning loop / Tier B sleep train ([SLEEP_TRAIN_TIER_B.md](SLEEP_TRAIN_TIER_B.md)) |
| Base pool frozen | Do not swap `MODEL_FILE` for a partial LoRA; apply `--lora` on coordinator |
| Coordinator only | `LORA_GGUF` on `hub:31360`; shards stay base-only |

### Hub layout (27B)

```
/mnt/HDDs/Alfa-AI/llama-cpp/lora/
  lora-adapters.json          # registry manifest (alfa-ai)
  qwen36-27b/
    my-adapter-20260811.gguf
```

NFS clients: `/mnt/cluster/llama-cpp/lora/`.

### B.1 Train

See [SLEEP_TRAIN_TIER_B.md](SLEEP_TRAIN_TIER_B.md) and [DATA_FLYWHEEL_OPERATOR.md](DATA_FLYWHEEL_OPERATOR.md).
Output: PEFT adapter for the **27B base** (`adapter_model.safetensors` +
`adapter_config.json`).

### B.2 Convert to GGUF (`hub` only)

From hub repo clone, with llama.cpp vendor tree present:

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai
python3 deploy/llamacpp-rpc/vendor/llama.cpp/convert_lora_to_gguf.py \
  /path/to/27b_adapter_dir \
  --outfile /mnt/HDDs/Alfa-AI/llama-cpp/lora/qwen36-27b/my-adapter-20260811.gguf \
  --outtype f16
```

Use the **same base model** path as production inference `MODEL_FILE` when converting.

### B.3 Register + publish

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai
bash deploy/cluster-members/_common/publish-lora-adapter-to-hub.sh \
  /mnt/HDDs/Alfa-AI/llama-cpp/lora/qwen36-27b/my-adapter-20260811.gguf \
  qwen3.6-27b \
  my-adapter-20260811 \
  0.75
```

Arguments: `GGUF_PATH`, `BASE_MODEL`, `ADAPTER_ID`, `EVAL_SCORE` (0-1).

Registry: `lora-adapters.json` on hub. Brain copy:
`{ALFA_AI_DATA}/lora/lora-adapters.json`.

### B.4 Promote to coordinator (`hub:31360` only)

Eval gate (>= 70%) must pass before promote -- operator/cluster smoke, same bar as L3 learning loop.

Add to `deploy/llamacpp-rpc/.env.rpc` on `hub` (via `write-grev27-pool-env.sh`
or manual append):

```bash
LORA_GGUF=my-adapter-20260811.gguf
LORA_SCALE=1.0
LORA_MODELS_DIR=/models/lora
```

Ensure hub lora dir is mounted in coordinator compose (`/models/lora`).

**Full stop** then **start** (orchestrator only -- no piecemeal coordinator restart):

```powershell
# From orchestrator (operator) after cluster stopped and hub env updated
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-Stop-AlfaAi.ps1 start
```

Coordinator wrapper appends `--lora /models/lora/${LORA_GGUF}` when `LORA_GGUF` is set
(see `deploy/llamacpp-rpc/run-llama-server-coordinator.sh` -- do not edit for 7B promote).

### B.5 Verify

```bash
curl -fsS http://127.0.0.1:31360/health
curl -fsS -H "Authorization: Bearer change-me" \
  http://127.0.0.1:31360/v1/models
```

Optional hotswap (adapter pre-loaded with `--lora-init-without-apply` -- not default):

```bash
bash deploy/cluster-members/_common/apply-lora-adapter.sh \
  http://127.0.0.1:31360 0 1.0
```

### B.6 Rollback (27B)

Clear `LORA_GGUF` in `.env.rpc`, full stop + start. Base GGUF unchanged.

---

## Python registry (27B learning loop)

```python
from src.runtime.lora_registry import register_adapter, list_adapters, best_adapter_for_base

register_adapter(
    adapter_id="my-adapter-20260811",
    base_model="qwen3.6-27b",
    gguf_relpath="qwen36-27b/my-adapter-20260811.gguf",
    eval_score=0.75,
    promoted=True,
)
```

CLI inspect:

```bash
python -c "from src.runtime.lora_registry import list_adapters; print(list_adapters())"
```

Sync hub manifest into the brain registry (does **not** set `LORA_GGUF`):

```bash
python -c "from src.runtime.lora_registry import sync_registry_from_hub; print(sync_registry_from_hub())"
```

Or admin JWT: `POST /alfa-ai/api/admin/learning-loop/lora/sync`. Status:
`GET /alfa-ai/api/admin/learning-loop/status`.

The 7B pipeline does **not** use `LORA_GGUF` or this promote path onto `:31360`.
