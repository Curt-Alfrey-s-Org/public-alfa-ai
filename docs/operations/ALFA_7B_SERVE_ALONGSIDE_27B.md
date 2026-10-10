# Serve 7B QLoRA alongside inference 27B

**Production default stays `frontier-code` (Qwen3.8-27B RPC pool).** After 7B QLoRA
train finishes, run sequential smoke log + live FAQ chat on a **standalone** `llama-server`
on **`gaming-c` gaming-worker-c** (not an RPC shard). Opt-in clients use LiteLLM alias
`alfa-coder-draft` only when the operator asks **after** live Yes/No passes. Do **not**
apply the 7B LoRA to the inference coordinator.

Official references:

- llama-server `--lora`: [server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
- LoRA convert: [convert_lora_to_gguf.py](https://github.com/ggml-org/llama.cpp/blob/master/convert_lora_to_gguf.py)
- LiteLLM OpenAI-compatible `api_base`: [docs](https://docs.litellm.ai/docs/providers/openai_compatible)
- Speculative decoding ( **not** used here): [speculative.md](https://github.com/ggml-org/llama.cpp/blob/master/docs/speculative.md)

Related: [ALFA_CODER_DRAFT_ALIAS.md](ALFA_CODER_DRAFT_ALIAS.md),
[TRAIN_7B_QLORA_GUI.md](TRAIN_7B_QLORA_GUI.md),
[LORA_ADAPTER_OPERATOR.md](LORA_ADAPTER_OPERATOR.md),
[PORT_ASSIGNMENTS.md](../PORT_ASSIGNMENTS.md),
[HUB_ARTIFACTS.md](../HUB_ARTIFACTS.md).

## Measurement layers (one rule: smoke log vs live chat vs LiteLLM)

Three layers. Do **not** treat the 10-item keyword smoke as an official benchmark, a
LiteLLM SLO, or a substitute for live Yes/No chat on the standalone server.

| Layer | What | Role |
|-------|------|------|
| **1. Cluster smoke log** | 10 `must_include_any` needles in `eval/gold/smoke.jsonl`, scored by `train_checkpoint_gate.py` (`PASS_THRESHOLD=0.70`, `promote_allowed` in script output) | **Informational cluster log** -- regression signal vs base on held-out keyword checks. Not an official eval. LiteLLM does **not** enforce 70%. |
| **2. Live FAQ chat** | Three frozen prompts on **`gaming-c:8470`** (adapter loaded) | **Deployment-like acceptance** after FAQ continue-train. Wrong Yes/No = adapter not ready to **use**, even when smoke is 6/10 or `promote_allowed=true`. |
| **3. LiteLLM** | `LLAMACPP_7B_URL` + `alfa-coder-draft` on `hub:8413` | **Operator opt-in only** -- set env and recreate LiteLLM **after** layer 2 passes **and** the operator explicitly asks to wire the alias. |

Official references (no vendor prescribes 70% or 8/10 for this experiment):

- NIST AI RMF **Measure 2.3** -- measure prior to deployment in conditions similar to
  expected scenarios; document differences between measurement setting and deployment:
  [NIST AI RMF Measure playbook](https://airc.nist.gov/airmf-resources/playbook/measure/)
- Google SRE -- unrealistic to insist SLOs are met 100% of the time; smoke log is a signal,
  not a perfection bar:
  [SRE Book -- Service level objectives](https://sre.google/sre-book/service-level-objectives/)
- lm-eval `--limit` is for **testing only**, not production acceptance:
  [lm-evaluation-harness interface](https://github.com/EleutherAI/lm-evaluation-harness/blob/main/docs/interface.md)
- LiteLLM OpenAI-compatible `api_base` routes requests; it does **not** score or enforce
  checkpoint gates:
  [OpenAI-compatible providers](https://docs.litellm.ai/docs/providers/openai_compatible),
  [proxy configs](https://docs.litellm.ai/docs/proxy/configs)

### Frozen live acceptance prompts (next-train chat checks)

Same user turns as the first three entries in `UNIQUE_TURNS` in
`scripts/build_7b_cluster_faq_chat.py` -- do not invent new questions for this gate.
Later `UNIQUE_TURNS` (indices 3-8) are **SFT paraphrases** of these three facts for
continued QLoRA generalization; they are **not** live acceptance prompts. Ask each
frozen prompt in **chat** on `http://orchestrator/v1` with the v2 adapter loaded
(`Start-Alfa7bServe.ps1 -LoraGguf pool-7b-qlora-v2.gguf`). The answer must start with
the expected Yes/No (case-insensitive); a wrong polarity fails layer 2 regardless of
smoke score.

| # | Prompt (user turn) | Expected |
|---|-------------------|----------|
| 1 | Can I attach this 7B LoRA to the 27B inference coordinator? | **No** (7B serves `gaming-c:8470` only; not coordinator `:31360`) |
| 2 | Can I apply pool-7b-qlora-v2.gguf onto frontier-code or qwen3.6-27b? | **No** |
| 3 | Can I run 7B QLoRA training and this 7B llama-server on Colin (gaming-c) at the same time? | **No** (train vs 7B-serve mutex on `gaming-c`) |

If any live prompt fails: stop 7B serve, continue v2 QLoRA with the cluster FAQ chat mix
([TRAIN_7B_QLORA_GUI.md](TRAIN_7B_QLORA_GUI.md)), reconvert on `hub`, serve again, and
retest the **same** three prompts. Do **not** raise the 10-item keyword bar or add 8/10
as a new cluster rule.

## Topology

```text
clients (Ask ALFa, opt-in bots)
    -> LiteLLM hub :8413
        -> frontier-code  -> inference RPC hub :31360 (+ shards)
        -> alfa-coder-draft -> llama-server gaming-c :8470 (base GGUF + --lora)
```

| Component | Host | Port | Role |
|-----------|------|------|------|
| inference coordinator | `hub` | `31360` | Production `frontier-code` / `qwen3.6-27b` |
| 7B standalone server | `gaming-c` WSL | **`8470`** | `alfa-coder-draft` only |
| LiteLLM | `hub` | `8413` | Routes aliases; `LLAMACPP_7B_URL` |

**Do not use** `:31361` or any `31350-31360` port for 7B. Those are RPC shard/coordinator
ports ([UI_DRIVEN_GPU_MODEL_RESEARCH.md](../experimental/UI_DRIVEN_GPU_MODEL_RESEARCH.md)).

**Do not** join `gaming-c` as a inference opt-in shard while 7B is serving. Same GPU (RTX 5070
12 GB). `rpc-server` is single-client per shard.

## Operator policy: gaming vs GPU

On gaming hosts (`gaming-c`, `gaming-b`, `gaming-a`), **do not** start QLoRA train, 7B
`llama-server`, or a inference opt-in shard while actively gaming on that GPU.
Inference/training and games are **mutually exclusive** on the same card.

**Disk-only work is OK during a game:** `Start-Alfa7bServe.ps1 -StageOnly` (hub
GGUF/tarball copy to `G:\alfa-ai-cache`), hub/cache staging, and
`alfa-ai-cache` moves off `C:` ([WINDOWS_DOCKER_WSL_DISK_AND_CACHE.md](../WINDOWS_DOCKER_WSL_DISK_AND_CACHE.md)).
Run the full `Start-Alfa7bServe.ps1` (no `-StageOnly`) when the GPU is free.

`Stop-Alfa7bServe.ps1` stops **only** container `llamacpp-7b-serve` via
`wsl.exe -d Ubuntu -- docker rm -f llamacpp-7b-serve` on `gaming-c` (no
`compose down --remove-orphans`). Windows OpenSSH + PS 5.1 strips quoted
`bash -lc` with `;`, so the remote command must have no PowerShell statement
separators ([`docker rm --force`](https://docs.docker.com/reference/cli/docker/container/rm/),
[WSL run a command](https://learn.microsoft.com/en-us/windows/wsl/basic-commands)).
Compose project name is `alfa-7b-serve`, not the directory default `llamacpp-rpc`
([Compose `name`](https://docs.docker.com/reference/compose-file/version-and-name/),
[`compose down --remove-orphans`](https://docs.docker.com/reference/cli/docker/compose/down/)).

**Do not** use llama.cpp speculative decoding (`-md`) with 7B drafting 27B. Qwen2.5-Coder-7B
and Qwen3.8-27B have incompatible vocabularies.

## Mutex rules (`gaming-c` GPU)

| Lock / service | Blocks |
|----------------|--------|
| `alfa-train.lock` (7B QLoRA train) | Pool72/80; opt-in `gaming-c`/`gaming-b` (and `gaming-a` when lock says so) |
| `alfa-7b-serve.lock` (7B inference) | inference opt-in **`gaming-c` only** |
| Ollama judge on `gaming-c:11434` | Same GPU as 7B serve -- do not run both |

Train and 7B-serve are mutually exclusive on `gaming-c`. Stop trainer before starting 7B serve.
Keep **`alfa-train-tb`** (TensorBoard sidecar, no `--gpus`); Stop trainer does not remove it
([TRAIN_7B_QLORA_GUI.md](TRAIN_7B_QLORA_GUI.md) Metrics UI).

**RPC image:** `gaming-c` WSL must already have `alfa-llamacpp-rpc:cuda128` **or**
`Start-Alfa7bServe.ps1` stages `alfa-llamacpp-rpc-cuda128-b10355.tar.gz` from `orchestrator`
cache / `hub` hub and `deploy-7b-llama-server.ps1` runs `docker load` in WSL
([HUB_ARTIFACTS.md](../HUB_ARTIFACTS.md)). Gaming-host NFS `/mnt/cluster/docker-images`
is often empty; do not `docker pull` that image on the worker.

**Compose volumes:** mount one hub root (`/mnt/cluster/llama-cpp` or
`G:\alfa-ai-cache\7b-hub` as `/hub:ro`). Nested `:ro` mounts under `/models`
fail (overlay mkdir on a read-only parent).

### LoRA env and llama-server flags (compose -> script)

`docker-compose.llama-server-7b.yml` passes `LORA_GGUF` and `LORA_SCALE` into the
container; `run-llama-server-7b.sh` maps them to llama-server flags per the
[server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
(`--lora FNAME`; `--lora-scaled FNAME:SCALE,...`).

| Compose env | Default | When `LORA_GGUF` is set |
|-------------|---------|-------------------------|
| `LORA_GGUF` | (empty) | Adapter filename under hub `lora/qwen25-coder-7b/` |
| `LORA_SCALE` | `1.0` | `1.0` or `1` -> `--lora`; any other value -> `--lora-scaled FNAME:SCALE` |

Interpolation uses the same `${VAR:-default}` style as `MAIN_PORT`
([Compose variable interpolation](https://docs.docker.com/compose/how-tos/environment-variables/variable-interpolation/)).
`LORA_GGUF=${LORA_GGUF-}` keeps an explicit empty value (no accidental v1 default).

Hub convert on `hub` only
([convert_lora_to_gguf.py](https://github.com/ggml-org/llama.cpp/blob/master/convert_lora_to_gguf.py)):
`--outfile`, `--outtype f16`, `--base` (Hugging Face **config directory** with
`config.json`; not the serve GGUF). Cluster wrapper `convert-7b-qlora-to-gguf.sh`
passes `--base` at the Qwen2.5-Coder-7B-Instruct snapshot. Serve then loads the
adapter GGUF with `--lora` against the 7B Q8_0 GGUF on `:8470`.

## Hub paths (`hub` only for convert)

| Artifact | Hub path |
|----------|----------|
| Base GGUF Q8_0 | `/mnt/HDDs/Alfa-AI/llama-cpp/models/qwen25-coder-7b/Qwen2.5-Coder-7B-Instruct-Q8_0.gguf` |
| LoRA GGUF (production default) | `/mnt/HDDs/Alfa-AI/llama-cpp/lora/qwen25-coder-7b/pool-7b-qlora-v1.gguf` |
| LoRA GGUF (v2 eval only) | `/mnt/HDDs/Alfa-AI/llama-cpp/lora/qwen25-coder-7b/pool-7b-qlora-v2.gguf` |
| PEFT checkpoint v1 (August corpus) | `/mnt/HDDs/Alfa-AI/training/alfa-train/checkpoints/pool-7b-qlora-v1` |
| PEFT checkpoint v2 (current train) | `/mnt/HDDs/Alfa-AI/training/alfa-train/checkpoints/pool-7b-qlora-v2` |

NFS clients read via `/mnt/cluster/llama-cpp/...` and `/mnt/cluster/training/...`
(same hub tree as `/mnt/HDDs/Alfa-AI/...` on `hub`).

**`gaming-c` serve fallback:** WSL NFS to `storage`/`hub` often times out, and `gaming-c` **C:**
is frequently full (0 bytes free). `Start-Alfa7bServe.ps1` then `scp`s GGUF from
`orchestrator` cache to **`G:\alfa-ai-cache\7b-hub\`** (`ALFA_59_CACHE_WIN`, default `G:\alfa-ai-cache`)
and compose uses `/mnt/g/alfa-ai-cache/7b-hub`. Hub convert still happens only on `hub`.

**Cache root picker:** sibling deploy scripts should resolve the Windows cache parent
via `Get-AlfaWindowsCacheRoot` ([WINDOWS_DOCKER_WSL_DISK_AND_CACHE.md](../WINDOWS_DOCKER_WSL_DISK_AND_CACHE.md))
so `gaming-c` prefers eligible **`G:`** and skips **`C:`** when another drive has room.
Local hub staging on the **calling** host uses `Join-Path (Get-AlfaWindowsCacheRoot) '7b-hub'`.
Remote **`gaming-c`** strings (`ALFA_59_CACHE_WIN`, default `G:\alfa-ai-cache`) must use
`Join-AlfaRemoteWinPath` in `Get-AlfaWindowsCacheRoot.ps1`: Windows PowerShell 5.1
`Join-Path` fails unless the Path drive exists on **this** host
([Join-Path](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/join-path)
Example 5 note). `orchestrator` has no `G:`. `[System.IO.Path]::Combine` does not require the
drive ([Path.Combine](https://learn.microsoft.com/en-us/dotnet/api/system.io.path.combine)).

**Scope:** cache moves and staging apply **only** to `*\alfa-ai-cache\` (GGUF, LoRA,
trainer artifacts, ALFa docker tarballs). Do **not** relocate games, Steam, or unrelated
`C:` data. Staging does **not** require an idle GPU; starting llama-server does.

**Stage-only (while gaming):** from `orchestrator`, copy hub artifacts to `gaming-c` without GPU
preflight or `docker compose`:

```powershell
cd C:/Users/operator\alfa-ai
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-Alfa7bServe.ps1 -StageOnly
```

Optional `-LoraGguf pool-7b-qlora-v2.gguf` stages that LoRA file too. Exit 0 when
files are on `G:\alfa-ai-cache\7b-hub` and `G:\alfa-ai-cache\docker-images`. Run the
full script (no `-StageOnly`) later when the GPU is free.

**Production serve and LiteLLM stay on v1** until v2 passes live FAQ chat (and smoke log is
recorded). Convert v2 to a
**distinct** GGUF filename (`pool-7b-qlora-v2.gguf`); do **not** overwrite v1.

If served v2 answers cluster Yes/No questions wrong (7B LoRA on 27B, train+serve on
`gaming-c` together, `inference` as trainer island), do **not** raise the 10-item keyword bar.
Stop 7B serve, continue v2 QLoRA with the cluster FAQ chat mix in
[TRAIN_7B_QLORA_GUI.md](TRAIN_7B_QLORA_GUI.md) (adaptive / `lora_model_dir`), reconvert,
then serve again and retest the same prompt.

### Sequential eval constraint (`gaming-c` 12 GB)

Only **one** `llama-server` on **`:8470`** at a time. Two Q8_0 7B copies do not fit on the
RTX 5070 12 GB WSL engine. Do **not** run a second container on `:8471` concurrently with
`:8470`. Stop serve, switch mode (base vs `--lora`), start again.

`generate_7b_eval_answers.py` on `gaming-c`: use **`--only base`** then **`--only checkpoint`**
(stop serve between). Do **not** use **`--only both`** with both URLs pointing at
`http://orchestrator/v1` -- that does not mean two concurrent 7B servers on one GPU.
`--only both` is only when base and checkpoint are already live on **different** OpenAI
origins (e.g. two hosts); the script warns if both URLs share the same origin.

LoRA flags and compose env: [LoRA env and llama-server flags](#lora-env-and-llama-server-flags-compose---script).
Official `--lora` / `--lora-scaled`:
[server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md).
LoRA GGUF convert (`--outfile`, `--outtype f16`, `--base` HF config dir):
[convert_lora_to_gguf.py](https://github.com/ggml-org/llama.cpp/blob/master/convert_lora_to_gguf.py).

## When is the train job done?

Train Start launcher exit 0 is **not** done. Containers stay up until **Stop trainer**.
Wait for GUI Status **FINISHED** (hub rank-0 `Training completed!` / `Model successfully
saved`) before any step below. Click-by-click order:
[TRAIN_7B_QLORA_GUI.md](TRAIN_7B_QLORA_GUI.md) -- After this 7B job finishes.

**Full cycle from `orchestrator`:** `Invoke-AlfaTrain7bEvalCycle.ps1` wraps the existing Start
trainer, Stop trainer, `convert-7b-qlora-to-gguf.sh`, `Start-Alfa7bServe.ps1` /
`Stop-Alfa7bServe.ps1`, `generate_7b_eval_answers.py`, `train_checkpoint_gate.py`,
and `scripts/eval/live_7b_faq_gate.py`. It polls llama-server
[`GET /health`](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
(HTTP 503 while loading is normal; wait until 200) via `Wait-AlfaHttpPoll.ps1`. Live
FAQ uses Python `urllib` (OpenAI
[chat/completions](https://platform.openai.com/docs/api-reference/chat/create)) --
do not POST JSON with `curl.exe` from PS 5.1 (quote stripping). Continue QLoRA uses
Axolotl [`lora_model_dir`](https://docs.axolotl.ai/docs/lora.html), not
`resume_from_checkpoint`.

```powershell
cd C:/Users/operator\alfa-ai
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Invoke-AlfaTrain7bEvalCycle.ps1
```

`-EvalOnly` skips train + convert. `-SkipTrain` skips Start (and waits only if a
lock is already present). After a **manual** `hub` convert paste, re-run with
`-EvalOnly` or `-SkipTrain -SkipConvert` -- `-SkipTrain` alone still SSHes convert.
The cycle **never** sets `LLAMACPP_7B_URL`.

| Order | Action |
|-------|--------|
| 1 | Stop trainer (clear lock; leave TensorBoard) |
| 2 | Convert v2 LoRA to GGUF on `hub` only |
| 3 | `git pull` on `gaming-c` worker clone |
| 4 | Sequential eval: base serve, then adapter serve, then `train_checkpoint_gate.py` |
| 5 | Live FAQ Yes/No on `:8470` (three frozen prompts) |
| 6 | Stop 7B serve |
| 7 | LiteLLM `alfa-coder-draft` **only if** step 5 passed **and** the operator asks |

## After training (sequential smoke log + live FAQ chat -- SSoT)

Prerequisite: 7B DDP finished; checkpoint under hub
`training/alfa-train/checkpoints/pool-7b-qlora-v2`.

1. **Stop trainer** (`Stop-AlfaTrain7bQlora.ps1` or GUI **Stop trainer**) so
   `alfa-train.lock` is clear. Do **not** stop inference core if it is already green.
   Leave **`alfa-train-tb`** running. If `gaming-c` WSL `nvidia-smi` still shows more than
   about 3 GiB used with no train/`rpc-server` process (WSL CUDA leak after `--rm`
   train containers), from `gaming-c` (Colin) restart the distro so VRAM is released
   ([WSL shut down](https://learn.microsoft.com/en-us/windows/wsl/basic-commands#shut-down)):

   ```powershell
   wsl --shutdown
   ```

   Then `wsl -d Ubuntu echo WSL_OK`. TensorBoard comes back via `--restart unless-stopped`.

2. **Convert on `hub` only** (hub-first). Script default stays v1. `ADAPTER_ID` **must**
   match the checkpoint directory basename (otherwise the script exits and will not
   overwrite `pool-7b-qlora-v1.gguf`). Existing outfile requires `FORCE_LORA_CONVERT=1`.

   ```bash
   cd /mnt/HDDs/Alfa-AI/repo/alfa-ai
   sudo env CHECKPOINT_DIR=/mnt/HDDs/Alfa-AI/training/alfa-train/checkpoints/pool-7b-qlora-v2 ADAPTER_ID=pool-7b-qlora-v2 bash deploy/cluster-members/hub/convert-7b-qlora-to-gguf.sh
   ```

   NFS equivalent: `CHECKPOINT_DIR=/mnt/cluster/training/alfa-train/checkpoints/pool-7b-qlora-v2`.

3. **From `gaming-c` (gaming-worker-c):** `git pull --ff-only origin main` only if the worker
   path is a git clone (`C:\alfa-ai-worker\.git`). Many gaming hosts use an SMB
   staged copy with no `.git`
   ([SOURCE_OF_TRUTH_AND_SYNC.md](../SOURCE_OF_TRUTH_AND_SYNC.md)).
   `Invoke-AlfaTrain7bEvalCycle.ps1` skips pull in that case; Start/eval still
   run from `orchestrator`. Official: [`git pull`](https://git-scm.com/docs/git-pull),
   [`git -C`](https://git-scm.com/docs/git#Documentation/git.txt--Cltpathgt).

4. **Base pass** -- from `orchestrator` (operator):

   ```powershell
   cd C:/Users/operator\alfa-ai
   powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-Alfa7bServe.ps1 -NoLora
   ```

5. **Generate base answers** (`orchestrator` or any host with repo + LAN to `gaming-c`):

   ```bash
   python scripts/eval/generate_7b_eval_answers.py \
     --only base \
     --base-url http://orchestrator/v1 \
     --out-base D:\alfa-ai-cache\eval\7b-v2-base-answers.jsonl
   ```

   With `-NoLora` up, `--only base` writes the base JSONL. Do not generate checkpoint
   answers on this pass. Do **not** use `--only both` on `gaming-c` (one server on `:8470`).

6. **Stop 7B serve:**

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Stop-Alfa7bServe.ps1
   ```

7. **Adapter pass** -- start with v2 LoRA GGUF ([`--lora`](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)).
   `-LoraGguf` **always restages** that filename from `hub` (hub SSoT after convert) onto
   `gaming-c`, overwriting a same-name cache file. Do not skip this after a reconvert; a
   leftover Sep-15 `pool-7b-qlora-v2.gguf` on `G:\` would otherwise be served.

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-Alfa7bServe.ps1 -LoraGguf pool-7b-qlora-v2.gguf
   ```

8. **Generate checkpoint answers** (adapter on `:8470`):

   ```bash
   python scripts/eval/generate_7b_eval_answers.py \
     --only checkpoint \
     --checkpoint-url http://orchestrator/v1 \
     --out-checkpoint D:\alfa-ai-cache\eval\7b-v2-ckpt-answers.jsonl
   ```

   Keep `7b-v2-ckpt-answers.jsonl` from this pass.

9. **Cluster smoke log** (informational -- not official eval, not LiteLLM SLO) -- run
   `train_checkpoint_gate.py` on the generated answer JSONLs. Script prints `passed=`,
   `total=`, `rate=`, per-id `[PASS]/[FAIL]`, and `promote_allowed` (compat field:
   checkpoint >= 70% **and** not worse than base). Treat output as a **smoke log**
   for regression tracking; neither llama.cpp nor LiteLLM enforces this threshold.

   ```bash
   python scripts/eval/train_checkpoint_gate.py \
     --answers-base D:\alfa-ai-cache\eval\7b-v2-base-answers.jsonl \
     --answers-checkpoint D:\alfa-ai-cache\eval\7b-v2-ckpt-answers.jsonl
   ```

10. **Live FAQ chat** (deployment-like acceptance) -- with the v2 adapter still on
    `:8470`, ask the three [frozen live prompts](#frozen-live-acceptance-prompts-next-train-chat-checks)
    in chat. All three must match expected Yes/No. Wrong polarity = not ready to **use**
    the adapter (continue FAQ train and retest), even if step 9 printed `promote_allowed=true`
    or smoke scored 6/10.

11. **Stop 7B serve** (`Stop-Alfa7bServe.ps1`).

12. **LiteLLM only if operator asks** -- after step 10 passes **and** the operator
    explicitly wants `alfa-coder-draft` wired, set `LLAMACPP_7B_URL` and recreate LiteLLM.
    Do **not** set `LLAMACPP_7B_URL` during steps 4-10. `promote_allowed` is smoke-script
    output only; it does **not** auto-enable LiteLLM. See [ALFA_CODER_DRAFT_ALIAS.md](ALFA_CODER_DRAFT_ALIAS.md).

### After live chat pass (operator opt-in to LiteLLM)

When the three live prompts pass **and** the operator asks to wire the alias:

1. Start production serve with the approved adapter (v2 GGUF or stay on v1 per decision).
2. Set `LLAMACPP_7B_URL=http://orchestrator/v1` on `hub`; recreate LiteLLM; wait helper:

   ```bash
   cd /mnt/HDDs/Alfa-AI/repo/alfa-ai
   bash deploy/cluster-members/_common/wait-litellm-liveliness.sh 120
   curl -fsS -H "Authorization: Bearer $LITELLM_MASTER_KEY" http://127.0.0.1:8413/v1/models | grep alfa-coder-draft
   ```

3. Smoke `:8470/health` from LAN. Confirm inference `:31360/health` still OK.

## Dual-check (7B draft + 27B judge)

Production **Path B** (multi-round draft, judge, revise, JSONL audit):
[ALFA_7B_27B_WORK_JUDGE.md](ALFA_7B_27B_WORK_JUDGE.md) -- not only the single-pass dual-check below.

Sequential app calls (same pattern as [src/llm/judge.py](../../src/llm/judge.py)):

1. Draft with `alfa-coder-draft` (7B on `gaming-c`).
2. Judge with `ALFA_AI_JUDGE_MODEL=frontier-code` and **empty** `ALFA_AI_JUDGE_API_BASE`
   so LiteLLM routes to inference 27B (not `gaming-c:11434` Ollama 14B judge).

Default **off**: `ALFA_AI_JUDGE_ENABLED=0` until live FAQ chat on `:8470` passes
**and** the operator asks to enable Path B (needs `alfa-coder-draft` / LiteLLM).
See [JUDGE_INSTALL_59.md](JUDGE_INSTALL_59.md) for the Ollama judge mutex on `gaming-c`.

Do **not** auto-route `fast` / `inline` / `autocomplete` to 7B in v1.

## Lock file (`orchestrator` runtime)

`deploy/llamacpp-rpc/alfa-7b-serve.lock` (ASCII, gitignored):

```text
STARTED_UTC=2026-09-14T20:00:00.0000000Z
MODE=7b-llama-server
HOST=orchestrator
PORT=8470
ADAPTER=pool-7b-qlora-v1.gguf
```

While set:

- Models GUI disables inference opt-in **`gaming-c`**.
- Orchestrator blocks `-Include59` on cluster start.
- Leftover gaming-stop on `gaming-c` is skipped (7B server owns the GPU).

Clear with `Stop-Alfa7bServe.ps1`.

## Rollback (after an operator LiteLLM promote only)

1. `Stop-Alfa7bServe.ps1` on `orchestrator` (stops `gaming-c` container, clears lock).
2. Unset or comment `LLAMACPP_7B_URL` on `hub`; recreate LiteLLM. Primary yaml
   cannot route the alias when the URL is unset; inference overlay may fall back to
   `frontier-code` ([ALFA_CODER_DRAFT_ALIAS.md](ALFA_CODER_DRAFT_ALIAS.md)).
3. inference unchanged -- no coordinator recycle required for 7B rollback.

## Acceptance checklist

Sequential eval + live chat (no LiteLLM):

- [ ] PS syntax scan passes on new `.ps1` under `deploy/`
- [ ] Convert wrote `pool-7b-qlora-v2.gguf` and did not overwrite v1
- [ ] `curl http://orchestrator/health` OK on base pass and adapter pass
- [ ] `train_checkpoint_gate.py` smoke log recorded (informational; `promote_allowed` is script output, not LiteLLM)
- [ ] Three frozen live FAQ prompts on `:8470` chat return expected Yes/No (deployment-like gate)
- [ ] inference `:31360/health` still OK
- [ ] `gaming-c` opt-in checkbox disabled while `alfa-7b-serve.lock` is set

After operator asks for LiteLLM only:

- [ ] `LLAMACPP_7B_URL` set on `hub`; LiteLLM `/v1/models` lists `frontier-code` and `alfa-coder-draft`
