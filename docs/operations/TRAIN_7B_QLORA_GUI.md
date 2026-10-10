# 7B QLoRA trainer -- `orchestrator` desktop GUI

Operator path to run **Qwen2.5-Coder-7B-Instruct** QLoRA on the **train island** from the
`orchestrator` desktop GUI **`train-desktop-menu.ps1`**. Window title: **ALFa Trainer 7B r5**.
Desktop shortcut **`ALFa Trainer 7B.lnk`**. Inference controls
live in **`models-desktop-menu.ps1`**.

**Production island:** `gaming-c` gaming-worker-c (rank 0, rdzv head) + `gaming-b` gaming-worker-b (rank 1).
Two RTX 5070 12 GB cards, WSL Docker. **DDP does not add those 12 GB together.** Each
DDP rank holds a full model replica
([DDP theory](https://docs.pytorch.org/tutorials/beginner/ddp_series_theory.html)).
Axolotl's **7-8B QLoRA ~10-14 GB** line is a **per-replica** peak at seq 512-2048,
micro_batch 1-2
([choosing method](https://docs.axolotl.ai/docs/choosing_method.html)).

**Production Start:** 2-node **DDP QLoRA**. YAML is `configs/pool-7b-qlora-sft.yaml`
with **no** `deepspeed:` and **no** FSDP. Axolotl uses DDP when neither DeepSpeed nor
FSDP is set ([multi-GPU](https://docs.axolotl.ai/docs/multi-gpu.html)). Core **27B stays
up**. Do **not** FSDP+QLoRA for Qwen (supported types are llama / mistral / mixtral only
-- [fsdp_qlora](https://docs.axolotl.ai/docs/fsdp_qlora.html)).

## Adaptive / continued QLoRA (operator: "adaptive learning")

When you add new code to the fleet repos, the trainer runs **continued QLoRA** via Axolotl
`lora_model_dir` — a kind of supervised fine-tuning on the frozen 7B base, **not** Adam
"adaptive learning rate" and **not** crash-resume via `auto_resume_from_checkpoints`.

| Step | Behavior |
|------|----------|
| 1. Corpus | Rebuild + promote the **full** multi-repo JSONL ([MULTI_REPO_CORPUS_OPERATOR.md](MULTI_REPO_CORPUS_OPERATOR.md)). Replay the whole current tree so old files are not forgotten. **Not** git diffs only. |
| 1b. Cluster FAQ chat | Start also stages `alfa-7b-cluster-faq-chat.jsonl` (OpenAI `messages` rows) onto the hub; 7B yaml lists it as a second dataset `type: chat_template`. Teaches **answers** (no 7B LoRA on 27B; train vs 7B-serve mutex on `gaming-c`; trainer island vs `:8470`) because completion dumps alone mix nearby true fragments into wrong Yes/No. Extra `UNIQUE_TURNS` after index 0-2 are **SFT paraphrases** (two per live-gate fact); the frozen live FAQ gate stays the first three exact user prompts in [ALFA_7B_SERVE_ALONGSIDE_27B.md](ALFA_7B_SERVE_ALONGSIDE_27B.md). Start builds with `--repeats 50` and `--extra-repeats-gate-fact13 50` (extra rows for live-gate **facts 1 and 3** only; fact 2 already passes polarity). Official mix rules: [dataset formats](https://docs.axolotl.ai/docs/dataset-formats/). `chat_template: tokenizer_default` uses the base tokenizer template ([conversation](https://docs.axolotl.ai/docs/dataset-formats/conversation.html) -- errors if `chat_template` is null). [Qwen2.5-Coder-7B-Instruct](https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct) ships `chat_template` and `eos_token` `<\|im_end\|>`. Do **not** assume train `tokenizer_default` equals llama.cpp `--chat-template chatml` until GGUF metadata is verified. Axolotl is **silent** on mix-time global `special_tokens.eos_token` -- do **not** add yaml `special_tokens` from this doc. Axolotl `weight` **subsamples** only (0 exclusive, 1 inclusive; cannot upsample) ([config reference](https://docs.axolotl.ai/docs/config-reference.html)). `scripts/build_7b_cluster_faq_chat.py --repeats` is **cluster preprocess** (duplicates unique turns in JSONL), not an Axolotl upsample knob. |
| 2. Start 7B (default) | When `adapter_config.json` exists under hub `checkpoints/pool-7b-qlora-v2`, Start passes `--lora-model-dir` to load the **existing v2 LoRA** and runs a **new** train loop (`num_epochs` as in yaml). Official: [LoRA — Resuming and continuing training](https://docs.axolotl.ai/docs/lora.html), [config `lora_model_dir`](https://docs.axolotl.ai/docs/config-reference.html). |
| 3. First v2 job | If no v2 adapter exists yet, Start behaves as today — fresh LoRA from zeros on the frozen 7B base. |
| 4. v1 parked | Frozen 7B base stays frozen. **`pool-7b-qlora-v1` stays parked — never continue into v1.** |
| 5. Fresh adapter opt-out | GUI checkbox **Fresh adapter**, default off. Checked Start passes `-FreshAdapter` and omits `--lora-model-dir` (new LoRA from zeros). Unchecked continues v2 when the adapter exists. |
| 6. No auto-resume | **Do not** enable `auto_resume_from_checkpoints` or `resume_from_checkpoint`. Those resume **mid-run trainer state**; a finished 2-epoch job would no-op. Use **`lora_model_dir`** (CLI `--lora-model-dir`) for **continued** adapter weights only. |
| 7. Prepared cache | Axolotl **reuses** an explicit `dataset_prepared_path` when that directory already exists ([dataset preprocessing](https://docs.axolotl.ai/docs/dataset_preprocessing.html)). Start therefore passes a **new** path when corpus or FAQ JSONL changes: `--dataset-prepared-path last_run_prepared_v2_<sha256-12>` from `qlora_continue.py --extra-jsonl` (cluster hash suffix; **not** Axolotl's internal cache key). Yaml base is `last_run_prepared_v2` only. CLI kebab: [CLI](https://docs.axolotl.ai/docs/cli.html) (`--dataset-prepared-path`, `--lora-model-dir`). |
| 8. Eval / serve | Sequential eval unchanged (base pass, adapter pass, `train_checkpoint_gate.py` smoke log). **Live FAQ chat** on `:8470` (three frozen Yes/No prompts) is the deployment-like gate. No LiteLLM until live chat passes **and** operator asks. `promote_allowed` is smoke-script output only. Do not GUI-Start 14B. Do not treat `Start-Alfa7bServe` as a required trainer step. Full continue-train + convert + eval + live FAQ from `orchestrator`: `Invoke-AlfaTrain7bEvalCycle.ps1` (wraps existing Start/Stop/convert scripts; does not wire LiteLLM). |

**Do not** set `lora_model_dir` in `pool-7b-qlora-sft.yaml` — an empty v2 `output_dir`
would fail load. Start supplies `--lora-model-dir` at launch when continuing.

**`activation_offloading: false`** (config default)
([config reference](https://docs.axolotl.ai/docs/config-reference.html)). Do not set
`legacy` (hung hub log `162144Z`) and do not set `true` (streamed CPU stash uses pinned
host memory; WSL documents a pinned-system-memory limit that can break DL training
-- [gradient checkpointing](https://docs.axolotl.ai/docs/gradient_checkpointing.html),
[CUDA on WSL](https://docs.nvidia.com/cuda/wsl-user-guide/index.html)). Keep
`gradient_checkpointing: true`.

**Optional diagnostic (GUI checkbox gaming-c only, or CLI):** `-SingleHost59` uses
`--launcher python` and the **same** `configs/pool-7b-qlora-sft.yaml` (still no
`deepspeed:`) ([Axolotl CLI](https://docs.axolotl.ai/docs/cli.html),
[FAQ mpi4py](https://docs.axolotl.ai/docs/faq.html)). Default **off**. One-node torchrun
would use `--rdzv_id alfa-train-pool7b-n1`; the diagnostic path skips rdzv TCP 29500.

**Optional host (GUI checkbox Include gaming-a, or CLI):** `-Include219` adds `gaming-a` gaming-worker-a
(mutually exclusive with `-SingleHost59`).

**Not a train host:** `inference` stays on **inference core** (shards `:31356`/`:31357`). The trainer
does **not** stop the 27B cluster. **Do not** keep an `alfa-train` clone, Axolotl image,
or train venv on `inference` -- those belong on `gaming-c` / `gaming-b` (and `gaming-a` when opted in).
Hub NFS `/mnt/cluster/training/alfa-train` may still be mounted on `inference` (shared dataset);
that is hub data, not a local trainer install.

| Mode | nnodes | Ranks | What each GPU holds | Launch |
|------|--------|-------|---------------------|--------|
| 2-node DDP QLoRA (GUI default) | 2 | 0=gaming-c, 1=gaming-b | Full 7B QLoRA replica (~10-14 GB table) | torchrun `--rdzv_id alfa-train-pool7b-n2` |
| With `gaming-a` (3-node DDP) | 3 | 0=gaming-c, 1=gaming-b, 2=gaming-a | Same replica on an 8 GB rank | torchrun `--rdzv_id alfa-train-pool7b-n3` |
| Diagnostic `gaming-c` only | 1 | 0=gaming-c | Full QLoRA job on 12 GB (same yaml, no DeepSpeed) | `--launcher python` + `pool-7b-qlora-sft.yaml` |

Rendezvous on `gaming-c` (`orchestrator`). Distinct `--rdzv_id` per world size prevents
leftover jobs from joining the wrong group
([torchrun](https://docs.pytorch.org/docs/stable/elastic/run.html),
[Axolotl multi-node](https://docs.axolotl.ai/docs/multi-node.html)).

GUI Start with every checkbox off, and CLI Start without flags, is 2-node DDP plus continue v2 when present.
`-Include219` and `-SingleHost59` cannot be combined. The GUI refuses that pair before launch.

**8 GB rank (`gaming-a`):** optional. Axolotl 7-8B QLoRA is listed **10-14 GB** -- RTX 5060
8 GB may OOM. Drop `gaming-a` after a **measured** exit-1 / CUDA OOM in hub logs. See
alfa-train [MULTI_GPU_TRAIN_POOL.md](../../../alfa-train/docs/MULTI_GPU_TRAIN_POOL.md).

**14B is archived** on hub HDD for later (do **not** Start). Keep yaml / DeepSpeed JSON.
Canonical weights: `/mnt/HDDs/Alfa-AI/models/huggingface/hub/models--Qwen--Qwen2.5-Coder-14B-Instruct`.
Drop SSD copies with `archive-hf-14b-keep-hdd.sh`. See **14B archived** below.

Related: [CLUSTER_START_STOP_OPERATOR.md](../CLUSTER_START_STOP_OPERATOR.md),
[SLEEP_TRAIN_TIER_B.md](SLEEP_TRAIN_TIER_B.md),
alfa-train [MULTI_GPU_TRAIN_POOL.md](../../../alfa-train/docs/MULTI_GPU_TRAIN_POOL.md).

Official references:

- [Axolotl LoRA — resuming and continuing training](https://docs.axolotl.ai/docs/lora.html) (`lora_model_dir` vs checkpoint resume)
- [Axolotl dataset preprocessing](https://docs.axolotl.ai/docs/dataset_preprocessing.html) (`dataset_prepared_path` reuse)
- [Axolotl multi-GPU](https://docs.axolotl.ai/docs/multi-gpu.html) (DDP default if DeepSpeed/FSDP unset)
- [Axolotl multi-node](https://docs.axolotl.ai/docs/multi-node.html) (`--launcher torchrun`)
- [Axolotl CLI](https://docs.axolotl.ai/docs/cli.html) (`--embeddings-skip-upcast` before `--launcher`)
- [Axolotl config `embeddings_skip_upcast` / `activation_offloading`](https://docs.axolotl.ai/docs/config-reference.html)
- [Axolotl choosing method / VRAM table](https://docs.axolotl.ai/docs/choosing_method.html) (7-8B QLoRA ~10-14 GB per replica)
- [Axolotl FSDP+QLoRA](https://docs.axolotl.ai/docs/fsdp_qlora.html) (llama / mistral / mixtral only)
- [Axolotl gradient checkpointing / activation offloading](https://docs.axolotl.ai/docs/gradient_checkpointing.html)
- [CUDA on WSL User Guide](https://docs.nvidia.com/cuda/wsl-user-guide/index.html) (pinned system memory limit)
- [Axolotl FAQ](https://docs.axolotl.ai/docs/faq.html) (remove `deepspeed:` on one GPU)
- [TRL PEFT / QLoRA](https://huggingface.co/docs/trl/peft_integration)
- [Qwen2.5-Coder-7B-Instruct](https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct)

## Concurrent with inference (core stays up)

The trainer must **not** call `Start-Stop-AlfaAi.ps1 stop`. Core 27B
(`inference` / `orchestrator` / `hub` + RAG `rag`) can keep running.

**Same GPU cannot do both.** `gaming-c` / `gaming-b` may opt in to inference 27B when the train
lock is clear. `gaming-a` is a inference opt-in shard when included. If the
running cluster included `gaming-a` as a inference shard, training there would steal VRAM and (if anyone `docker stop`s the shard) crash the coordinator
([no piecemeal](../../.cursor/rules/no-piecemeal-cluster-scripts.mdc)).

Start therefore **fails** unless:

1. No other `orchestrator` `powershell.exe` still running `Start-AlfaTrain7bQlora.ps1`,
   `Stop-AlfaTrain7bQlora.ps1`, or leftover PIDs whose CommandLine still names
   `Start-AlfaTrain14bQlora.ps1` / `Stop-AlfaTrain14bQlora.ps1` (those 14B Start/Stop
   scripts are gone; preflight only catches old sessions). This Start excludes its own
   `$PID`. Command line comes
   from [Win32_Process](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-process)
   via [Get-CimInstance](https://learn.microsoft.com/en-us/powershell/module/cimcmdlets/get-ciminstance?view=powershell-5.1).
2. When coordinator `:31360` is **up**, `deploy/llamacpp-rpc/inference-shards.active.env`
   does **not** list the train host RPC ports (`gaming-c:31351`, `gaming-b:31358`, and
   `gaming-a:31352` when included). If the coordinator is **down**, a stale
   `active.env` does **not** block Start (membership is only live while `--rpc`
   backends are in use -- [RPC README](https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md)).
3. SSH `docker ps` on each train host shows **no** leftover `alfa-train-7b*` or
   `alfa-train-14b*` (running or exited)
   ([docker ps](https://docs.docker.com/reference/cli/docker/container/ps/)).
   Start does **not** probe shard RPC ports (that is racy after the coordinator is up).
4. **Orphan `llamacpp-rpc-server`:** if `docker ps` still shows `llamacpp-rpc` /
   `alfa-llamacpp-rpc` **and** that host is **not** a live coordinator backend
   (coordinator `:31360` down, **or** coordinator up and `inference-shards.active.env`
   exists and does **not** list that host:port), Start SSHs
   `gaming-stop-for-session.ps1 -NoPause` (**no** `-ShutdownWsl`) once, then repeats
   `docker ps`. That is the same local-stop script cluster leftover cleanup uses.
   llama-server lists `--rpc` hosts at start
   ([RPC README](https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md)).
   Start **must not** stop a shard while the coordinator is **up** and that host:port
   **is** listed in `inference-shards.active.env`, or while the coordinator is up with
   **no** `active.env` file -- those cases **throw**. Coordinator **down** plus leftover
   RPC is treated as an orphan even if `active.env` still names the host (stale list).
   If Start throws: full cluster Stop then Start **without** those hosts opted in.
   Do not `docker stop` one shard by hand.

If leftover Start/Stop PIDs or leftover train containers: `Stop-Process` those PIDs if
needed, then `Stop-AlfaTrain7bQlora.ps1`.

## Mutual exclusion (train lock)

While `deploy/llamacpp-rpc/alfa-train.lock` exists (gitignored):

| Action | Allowed? |
|--------|----------|
| **Keep running 27B** (already started) | **Yes** -- trainer does not stop core |
| **Start cluster -- inference core** (`inference`/`orchestrator`/`hub` + RAG `rag`; opt-in `secondary`/`pool-opt-in`) | **Yes** -- orchestrator allows while lock is set |
| **Start cluster -- Pool72 / Pool80** or opt-in **`gaming-c` / `gaming-b`** (or **`gaming-a`** when lock has `INCLUDE_219=1`) | **No** -- orchestrator preflight throws (would redeploy shards onto train GPUs) |
| **Blackwell opt-in shards on Models GUI** (`gaming-c` / `gaming-b`; `gaming-a` when `INCLUDE_219=1`) | **No** -- Models GUI disables those controls while lock exists |
| **Start 7B QLoRA** | **No** -- lock already set |
| **Stop trainer** | **Yes** once `alfa-train.lock` is set -- including while **ALFa Models** cluster Start/Stop holds `alfa-desktop-job.lock` (Trainer GUI r7+). Still **No** while this GUI's own Start child holds the desktop lock. Failed Start nested-stops with `ALFA_DESKTOP_JOB_NEST=1`. |
| **Models Start/Stop while Trainer Start/Stop launcher is running** | **No** -- `alfa-desktop-job.lock` ([FileMode.CreateNew](https://learn.microsoft.com/en-us/dotnet/api/system.io.filemode)). **Yes** while only `alfa-train.lock` + running containers (orchestrator skips `gaming-c`/`gaming-b` docker). |

inference leftover gaming-stop **skips** `gaming-c`/`gaming-b` while the train lock is set so cluster Start does not `docker` on those GPUs during QLoRA.

**Stop trainer** clears the lock when all **required** train hosts were
either killed successfully **or** are unreachable because the host is powered off / offline
(`Connection timed out`, `Connection timedout`, `Connection refused`, `No route to host`,
`Network is unreachable`). Required hosts are `gaming-c` always and `gaming-b` unless the lock has
`SINGLE_HOST_59=1`. **`gaming-a` is best-effort** (not lock-blocking). `gaming-b` is also
best-effort for a `gaming-c`-only diagnostic job.

**Missing SSH keys or auth failure** on a **required** host that should be up **keeps** the lock
so Pool72/Pool80 and train-GPU opt-in starts stay blocked (inference core start still allowed).

## Start failure matrix (root vs follow-on)

Each hub dir `pool-7b-<UTC>/` is usually **one distinct root**. Lines like
`DistNetworkError`, `RendezvousConnectionError`, or `ChildFailedError` **after** a rank crash
are follow-on (peer died), not a second bug to fix separately.

| Root cause | When | Hub / launcher signature | Fix (official path) |
|------------|------|------------------------|---------------------|
| Rendezvous never opens | Aug 23 early | `:29500` closed; no load | `--rdzv_conf is_host=1` on `gaming-c`, `--local-addr`, Docker `--add-host` ([torchrun](https://docs.pytorch.org/docs/stable/elastic/run.html), [docker run --add-host](https://docs.docker.com/reference/cli/docker/container/run/#add-host)) |
| c10d / NCCL LAN blocked | Aug 23 | `DistNetworkError` to peer FQDN or ephemeral port | Hyper-V **LAN inbound TCP** on `gaming-c`/`gaming-b` (not 29500-only) ([WSL networking](https://learn.microsoft.com/en-us/windows/wsl/networking), [Hyper-V firewall](https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/hyper-v-firewall)) |
| Embedding fp32 upcast | Aug 23-24 | `device not ready` in `_convert_embedding_modules_dtype` | `embeddings_skip_upcast: true` + `--embeddings-skip-upcast` ([Axolotl config](https://docs.axolotl.ai/docs/config-reference.html)) |
| CLI boolean typo | Sep 8 | `can't open file .../true` | Never pass a value after `--embeddings-skip-upcast` ([Axolotl CLI](https://docs.axolotl.ai/docs/cli.html)) |
| HF cache locks NFS | Sep 11 `005814Z` | `PermissionError: .../hub/.locks` | `chmod a+rwx` on SSD `hub/` + `hub/.locks` on `hub`; Start preflight `touch` ([huggingface_hub cache](https://huggingface.co/docs/huggingface_hub/en/guides/manage-cache)) |
| HF datasets cache NFS | Sep 11 `185215Z` / `191138Z` | `PermissionError: .../data/hf/datasets` on rank 1 during `load_dataset` | Start sets `HF_DATASETS_CACHE` to hub `training/alfa-train/cache/datasets` (writable HDD); preflight `touch` ([datasets cache](https://huggingface.co/docs/datasets/cache)) |
| Docker `/dev/shm` too small | Sep 11 `191138Z` | After `trainable params`: `Unexpected bus error` / `insufficient shared memory (shm)` | Start adds `--shm-size=16g` on train containers ([docker run --shm-size](https://docs.docker.com/engine/reference/run/#shm-size)) |
| Packed eval on 12 GB WSL | Sep 10-11 / `193437Z` / `203025Z` | Load 100%, then `_evaluate` -> `logits.float()` -> `device not ready` | Unpack flags; `eval_strategy: "no"` is not enough while `test_datasets` still builds `eval_dataset`. Omit `test_datasets` and set `val_set_size: 0` ([Axolotl README](https://github.com/axolotl-ai-cloud/axolotl) `0 for no eval`; [config reference](https://docs.axolotl.ai/docs/config-reference.html) cannot use both). `--bf16 full` rejected by this image (`200119Z`). |
| Auto LoRA kernels on 12 GB WSL | Sep 11 `204731Z` | Eval skipped; first `training_step` -> `apply_lora_mlp_swiglu` NF4 `torch.empty` -> `device not ready` | Set `lora_mlp_kernel` / `lora_qkv_kernel` / `lora_o_kernel` / `lora_embedding_kernel` to `false` ([LoRA optimizations](https://docs.axolotl.ai/docs/lora_optims.html); image auto-enables them unless explicit). |
| Packed 2048 train step on 12 GB WSL | Sep 11 `210834Z` | Kernels off; first `training_step` -> bnb `matmul_4bit` `_dequant_linear_fallback` -> `device not ready` | Skip `flash_attention_2` (FA2 is Ampere/Ada/Hopper; 5070 is Blackwell -- [attention](https://docs.axolotl.ai/docs/attention.html)). Drop `sequence_len` to **512** (table low end; 7-8B QLoRA listed 10-14 GB -- [choosing method](https://docs.axolotl.ai/docs/choosing_method.html)). |
| Activation offload on WSL | `162144Z` / config | `activation_offloading: legacy` hung; `true` uses pinned CPU | Keep **`false`**. `true` overlaps copies onto pinned host memory ([gradient checkpointing](https://docs.axolotl.ai/docs/gradient_checkpointing.html)); WSL limits pinned system memory for DL workloads ([CUDA on WSL](https://docs.nvidia.com/cuda/wsl-user-guide/index.html)). |
| Cluster Start overlapping train GPU Docker | Sep 13 `20260914-001418-start` vs train Start | Rank-0 died after `trainable params` (`Rank-0 container exited before train progress`). Cluster start session still writing logs; leftover gaming-stop SSHes `gaming-c`/`gaming-b` `docker` during Axolotl load. | Serialize Models vs Trainer Start/Stop (`alfa-desktop-job.lock`). Skip leftover `gaming-c`/`gaming-b` gaming-stop while `alfa-train.lock` exists. Do not FSDP+QLoRA for Qwen. |
| Stacked leftover Start/Stop on `orchestrator` | Sep 13 after Rank-0 fail | Ten PIDs whose CommandLine still named removed `Start-AlfaTrain14bQlora` / `Stop-AlfaTrain14bQlora` scripts, alive with **no** `alfa-train.lock`. A new Start would SSH `docker` onto the same WSL engines. | Start preflight lists leftover launcher PIDs (7B plus old 14B script names) via Win32_Process CommandLine and leftover `alfa-train-7b*` / `alfa-train-14b*` via `docker ps -a`. Operator `Stop-Process` then Stop trainer; Start does not auto-kill. Do not run 14B Start (scripts gone). |
| Orphan `llamacpp-rpc-server` on a train GPU | Sep 18 after **Done Gaming** / local `deploy-grev27-pool-shard` while `gaming-c`/`gaming-b` were **not** in `inference-shards.active.env` | Train Start `FAIL: RPC container still running: llamacpp-rpc-server` even though membership check printed `Active shard list does not include train hosts` | **Done Gaming** starts WSL only (does **not** deploy the shard). Train Start auto-runs `gaming-stop-for-session.ps1 -NoPause` when the orphan is safe to stop. If the host **is** in the live active list: full cluster Stop then Start with **N** for that host. |
| GPU-free check `exit System.Object[]` | Sep 18 cycle Start | `Assert-TrainGpuFreeOnHost` compared ssh **stdout plus** `$LASTEXITCODE` ([about_Return](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_return?view=powershell-5.1)). `-eq 5` missed `RPC_BUSY`; threw instead of orphan stop. | Write-Host the remote text; return only the native ssh exit **int** (5 = RPC container, 9 = leftover train). |
| `hub` SSH login banner `CYCLE FAIL` | Sep 23 cycle convert | `Invoke-AlfaCycleConvert111` ran ssh with `2>&1` under `$ErrorActionPreference Stop`; US Gov contractor **stderr MOTD** became `NativeCommandError` before `$LASTEXITCODE` was checked. Train FINISHED and Stop were already OK; convert never ran. | `Invoke-AlfaCycleSsh` sets `Continue` around ssh; success/fail uses **exit code only** ([ssh stderr on Windows](https://learn.microsoft.com/en-us/windows/curl/) same class as other native stderr). Re-run `-SkipTrain` (or `-SkipTrain -SkipConvert` if convert was done manually). |
| Hub NFS preflight exit 2 on `gaming-c` after WSL restart | Sep 24 cycle Start | Old Start only ran one `mount` to `hub`; `/mnt/cluster` was a **non-mountpoint** dir on WSL disk (`df` showed `/dev/sdc`). | `Assert-TrainHubNfsMounted` self-heals: `umount`/`umount -l`, then mount **`hub` then `storage`**. Re-run Start/cycle (no manual paste unless both IPs fail). |
| Preprocess SIGBUS before first `loss` | Sep 24 `190853Z` | Hub log: tokenize / `Dropping Invalid Sequences`; rank `exitcode: -7` or `Signal 7 (SIGBUS)`; `DistNetworkError` on peer is follow-on. | Start **self-heals once**: `docker rm` train containers (lock kept), `rm -rf` partial `dataset_prepared_path` from `qlora_continue.py`, relaunch with `--dataset-num-proc 4` ([Axolotl `dataset_num_proc`](https://docs.axolotl.ai/docs/config-reference.html)). Containers still use `--shm-size=16g` ([docker run](https://docs.docker.com/engine/reference/run/#shm-size)). If retry fails, Stop then investigate NFS / hub cache / lower yaml `dataset_num_proc` in alfa-train. |
| `sudo: ... convert-7b-qlora-to-gguf.sh: command not found` | Sep 23 `-SkipTrain` | Hub clone keeps the script **644** (`-rw-rw----`). Cycle used `sudo ... /absolute/script.sh`; kernel/sudo cannot exec a non-executable path ([chmod](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/chmod.html)). File exists (`test -f` OK). | Remote: `sudo env CHECKPOINT_DIR=... ADAPTER_ID=... FORCE_LORA_CONVERT=1 bash deploy/cluster-members/hub/convert-7b-qlora-to-gguf.sh` from repo root (matches `Get-AlfaCycleConvertPaste`). |
| Launcher lied "OK" | Sep 11 | Footer **Train job: OK** while Status **FAILED** | Watchdog waits for **`loss` / `Total train batch` only** (not `trainable params` alone); GUI footer defers to Status when lock + not TRAINING |

**Watchdog / Status semantics:** `trainable params` and `Loading weights: 100%` mean **STARTING**
(load finished, first eval or train step not proven yet). **TRAINING** requires hub rank-0 log
lines with **`loss`** or **`Total train batch`**. The Start script watchdog and GUI probe use
the same rule.

**Footer vs Status:** bottom-right **Train job: OK** means the **Start launcher process** on
`orchestrator` exited 0. It is **not** epoch completion and must **not** override red **FAILED** or
yellow **STARTING** in the Status hint. After Start exits, click **Refresh** for hub-log phase.

### Eval / CUDA ladder (only if unpacked eval still fails)

Crash in Transformers `ForCausalLMLoss` `logits.float()` is documented HF behavior
([Trainer recipes](https://huggingface.co/docs/transformers/en/trainer_recipes)). NVIDIA
`CUDA_ERROR_NOT_READY` is a driver "not ready" code ([CUDA types](https://docs.nvidia.com/cuda/cuda-driver-api/group__CUDA__TYPES.html)).
Do **not** add NCCL variables from the NCCL **Debugging** section
([NCCL env](https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/env.html) --
`NCCL_P2P_DISABLE` and similar "should not be used in production nor retained in scripts").
Start may set **system** NCCL vars documented for torchrun: `NCCL_SOCKET_IFNAME`
([Axolotl multi-node](https://docs.axolotl.ai/docs/multi-node.html)).

After **one measured Start** with the pushed unpack flags, read the new hub log. Apply **only**
Axolotl-documented YAML keys (no raw HuggingFace-only keys unless listed in
[Axolotl config reference](https://docs.axolotl.ai/docs/config-reference.html)):

1. Still `_evaluate` -> `logits.float()` **CUDA not ready:** this image **rejects**
   `bf16: full` (pydantic `auto`|bool; measured `200119Z`). Use documented
   `eval_strategy: "no"` is not enough if `test_datasets` still builds `eval_dataset`
   (`203025Z`). Omit `test_datasets` and set `val_set_size: 0`.
2. First `training_step` CUDA-dies in `apply_lora_mlp_swiglu` (`204731Z`): set
   `lora_*_kernel: false` ([LoRA optimizations](https://docs.axolotl.ai/docs/lora_optims.html)).
3. Do **not** set `attn_implementation: flash_attention_2` on RTX 5070. Official FA2
   GPUs are Ampere/Ada/Hopper only; FA4 is the Blackwell path and needs extra
   packages ([attention](https://docs.axolotl.ai/docs/attention.html)).
4. Still first-step CUDA in bnb `matmul_4bit` (`210834Z`): lower `sequence_len` to
   **512** (table low end). `torch_empty_cache_steps` only helps *later* steps
   ([choosing method](https://docs.axolotl.ai/docs/choosing_method.html),
   [config reference](https://docs.axolotl.ai/docs/config-reference.html)).
5. Keep **`activation_offloading: false`**. Do not switch to `legacy` or `true` on this
   WSL path. Do not add DeepSpeed / FSDP. Do not FSDP+QLoRA for Qwen. Do not switch
   trainers to archived 14B.

`Invalid peer device id` in Axolotl startup is a **warning** from the P2P probe
(`can_device_access_peer` with a default 8-GPU node size) on 1-GPU-per-host
torchrun. It is not the fatal line unless a later log shows it as the crash.

## VRAM / first-run expectations

Axolotl's hardware table lists **7-8B QLoRA at ~10-14 GB** (seq 512-2048, micro-batch 1-2)
**per replica**. Two 12 GB cards do **not** become 24 GB of model capacity under **DDP**.
Production 2-node uses **DDP** (default; no DeepSpeed/FSDP) + QLoRA, `sequence_len: 512`,
`micro_batch_size: 1`, `eval_batch_size: 1`, `eval_sample_packing: false`, and gradient
checkpointing. Packed **eval** on 12 GB WSL hit `CUDA driver error: device not ready` in
`ForCausalLMLoss` `logits.float()` after a successful weight load (2026-09-11). Axolotl
documents `eval_sample_packing: false` when eval errors with `sample_packing` on
([config reference](https://docs.axolotl.ai/docs/config-reference.html)) and reducing
`eval_batch_size` for memory issues ([multi-GPU](https://docs.axolotl.ai/docs/multi-gpu.html)).
Do **not** switch to FSDP+QLoRA
for Qwen ([supported types](https://docs.axolotl.ai/docs/fsdp_qlora.html) are llama/mistral/mixtral).
Do **not** stop core 27B for this; `nvidia-smi` idle on `gaming-c`/`gaming-b` after Stop is expected.

Dataset in `pool-7b-qlora-sft.yaml` is **two** hub JSONLs: `type: completion` (fleet
corpus / CPT-style text) **plus** `type: chat_template` cluster FAQ
(`alfa-7b-cluster-faq-chat.jsonl`). That FAQ is **not** the Tier B sleep
`from-alfa-ai` pack ([TRAIN_PACK_MANIFEST.md](TRAIN_PACK_MANIFEST.md)).
Do **not** drop the completion corpus when adding the FAQ.

## 14B archived (do not Start)

**Qwen2.5-Coder-14B-Instruct** QLoRA is **archived** until a later GPU class can hold it.
Axolotl lists 13-14B QLoRA at **~16-20 GB** per replica
([choosing method](https://docs.axolotl.ai/docs/choosing_method.html)). On WSL
Blackwell (RTX 5070) the 14B path hit **CUDA 600** / `device not ready` at first step
(DeepSpeed backward, DDP wrap `_broadcast_coalesced`, ZeRO-3 all-gather). Hub logs from
that era are `pool-14b-<UTC>/`.

**Keep (do not delete HDD; do not GUI-Start):**

- HF cache on **HDD only:** `/mnt/HDDs/Alfa-AI/models/huggingface/hub/models--Qwen--Qwen2.5-Coder-14B-Instruct`
- alfa-train `configs/pool-14b-qlora-sft.yaml`, `pool-14b-qlora-sft-single.yaml`, `ds_zero3-14b.json`
- `deploy/cluster-members/hub/promote-hf-14b-to-ssd.sh` (un-archive later only)

**From `hub` (operator)** after `git pull`: verify HDD, then drop SSD/NVMe copies
([rm(1)](https://man7.org/linux/man-pages/man1/rm.1.html)):

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai
sudo bash deploy/cluster-members/hub/archive-hf-14b-keep-hdd.sh
sudo CONFIRM=1 bash deploy/cluster-members/hub/archive-hf-14b-keep-hdd.sh
```

Do **not** run `promote-hf-14b-to-ssd.sh` while archived. Production Start is **7B DDP**.
Do not replace inference 27B with a 14B (or 7B) adapter until the eval gate
([LORA_ADAPTER_OPERATOR.md](LORA_ADAPTER_OPERATOR.md)).

## Prerequisites

| Item | Where |
|------|--------|
| alfa-train clone | `C:\alfa-ai-train` on `gaming-c`/`gaming-b` (and `gaming-a` when included). YAML `configs/pool-7b-qlora-sft.yaml` (**no** `deepspeed:`). Start runs `git pull --ff-only origin main` on those clones ([git-pull](https://git-scm.com/docs/git-pull)) before docker. `inference` is **not** a train rank. alfa-ai Start sets `NCCL_SOCKET_IFNAME` on torchrun jobs and `PYTORCH_ALLOC_CONF=expandable_segments:False` on every job. `-SingleHost59` uses `--launcher python` and the **same** yaml. |
| Hub mount | Required hosts (`gaming-c` / `gaming-b`) must see `/mnt/cluster` (HDD: corpus/logs) **and** `/mnt/cluster-ssd` (SSD: 7B HF). Also `gaming-a` when included. See **Hub NFS** below. |
| SSH keys on `orchestrator` | **Required:** `id_ed25519_93_59`, `id_ed25519_93_249`. **Optional (3-node):** `id_ed25519_93_219` |
| Base weights | **SSD hot** HF cache `Qwen/Qwen2.5-Coder-7B-Instruct` at `/mnt/cluster-ssd/models/huggingface` (promote from HDD on `hub`; hub-first). Not spinning `/mnt/cluster`. |
| Dataset JSONL | Hub `/mnt/cluster/training/alfa-train/datasets/alfa-corpus-{train,val}.jsonl` -- fleet GitHub clones on `orchestrator` ([MULTI_REPO_CORPUS_OPERATOR.md](MULTI_REPO_CORPUS_OPERATOR.md)). Same repo on many hosts is trained once. Do not promote while `alfa-train.lock` is set. |
| Checkpoints | Hub `/mnt/cluster/training/alfa-train/checkpoints/pool-7b-qlora-v2` (v1 August corpus preserved at `pool-7b-qlora-v1` -- **never continue into v1**). When `adapter_config.json` exists under v2, Start **continues** via `--lora-model-dir` ([LoRA](https://docs.axolotl.ai/docs/lora.html), [config](https://docs.axolotl.ai/docs/config-reference.html), [CLI](https://docs.axolotl.ai/docs/cli.html)) -- not `auto_resume_from_checkpoints`. Prepared cache: yaml base `last_run_prepared_v2`; Start suffixes `_<sha256-12>` from `qlora_continue.py` when JSONL changes (cluster hash, not Axolotl cache key). Axolotl reuses explicit paths ([dataset preprocessing](https://docs.axolotl.ai/docs/dataset_preprocessing.html)). |
| Train stdout logs | Hub `/mnt/cluster/training/alfa-train/logs/pool-7b-<UTC>/alfa-train-7b-*.log` (survive `--rm`) |
| CUDA / Axolotl | Official Docker image `axolotlai/axolotl-uv:main-py3.12-cu130-2.12.0` ([install](https://docs.axolotl.ai/docs/installation.html)). Hub tarball: `docker-images/axolotl-uv-main-py3.12-cu130-2.12.0.tar.gz` (load once per host; do not `docker pull` on workers) |
| Firewall | TCP **29500** inbound on **`gaming-c`** (Hyper-V rule for mirrored WSL). Workers egress to `gaming-c:29500`. RPC on train GPUs (`gaming-c:31351`, `gaming-b:31358`, `gaming-a:31352` when that host was a inference shard) must be **idle** (no rpc-server container). Core `inference` RPC stays up with 27B. |

Config: alfa-train `configs/pool-7b-qlora-sft.yaml`.

### Verified bring-up: gaming hosts `gaming-c` / `gaming-b` / `gaming-a` (2026-08-21)

Canonical path that worked on Windows gaming trainers. Do **not** substitute
`docker pull` or public HF downloads (hub-first). `inference` is **not** a train rank
(it keeps inference core).

Accounts: **`gaming-c` Colin**, **`gaming-b` Cody**, **`gaming-a` Corey**. Run paste blocks on that
host's console (WSL `sudo` often needs a local password; agent SSH cannot type it).

Preferred NFS data plane is **`orchestrator`**
([hub-network-aliases](../../.cursor/rules/hub-network-aliases.mdc)).
When `storage` is down, mount via **`hub`** (same export).

#### A. hub once (`hub` as `operator`)

1. Confirm Alfa-AI NFS export covers the LAN and is enabled:

```bash
sudo midclt call sharing.nfs.query | python3 -c "import sys,json; [print(s['id'], s['path'], s.get('networks'), s.get('enabled')) for s in json.load(sys.stdin)]"
```

Expect a row for `/mnt/HDDs/Alfa-AI` (corpus) and a row for `/mnt/ssd/Alfa-AI`
(7B HF hot). Networks including `orchestrator/24`. If the SSD path is missing,
add it in **Shares -> Unix (NFS) Shares -> Add**
([Adding NFS shares](https://www.hub.com/docs/scale/shares/nfs/addingnfsshares/)):
path `/mnt/ssd/Alfa-AI` (not pool root `/mnt/ssd`), Maproot user `operator`,
allowed network `orchestrator/24`. Seed HDD if the 7B snapshot is missing (hub-first;
[HF download](https://huggingface.co/docs/huggingface_hub/en/guides/download#snapshot-download)),
then promote to SSD:

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai
git pull --ff-only origin main
sudo bash scripts/hub_hub_models.sh pull hf Qwen/Qwen2.5-Coder-7B-Instruct
sudo bash deploy/cluster-members/hub/promote-hf-7b-to-ssd.sh
```

Measured 2026-09-14: HDD had 14B Instruct only; 7B was absent. Promote cannot invent the tree.

Archived 14B weights stay on HDD. Do not `promote-hf-14b-to-ssd.sh` while archived.

2. Confirm NFS service config. Both `storage` and `hub` may appear in `bindip`.
   WSL **mirrored** networking needs non-root / insecure mounts
   ([`nfs.update` `allow_nonroot`](https://api.hub.com/v25.04.2/api_methods_nfs.update.html)):

```bash
sudo midclt call nfs.config | python3 -m json.tool
```

If `"allow_nonroot": false`:

```bash
sudo midclt call nfs.update '{"allow_nonroot": true}'
```

Verified result: `"allow_nonroot": true`. Without this, WSL mount fails with
`Operation not permitted` (NFSv4.1) or `access denied by server` (NFSv3).

#### B. Hub NFS on train hosts

| Failure | Cause | Fix |
|---------|--------|-----|
| Mount to `storage` hangs / times out | NFS data-plane alias down | Mount `hub:/mnt/HDDs/Alfa-AI` |
| `bad option` / need `mount.nfs` helper | `nfs-common` missing (`gaming-b`, `gaming-a`) | `apt-get install nfs-common` |
| `Operation not permitted` with `noresvport` | `allow_nonroot` false on hub | Step A |
| PowerShell shows `EXIT:True` for bash `$?` | PS expands `$?` in double quotes | Do not echo `$?` from Windows-wrapped bash |
| WSL `sudo: Authentication failed` (`gaming-a`) | Linux user password unset / wrong | `wsl -d Ubuntu -u root ...` (no sudo) |
| UNC `\\hub\huggingface` Access denied | SMB filesystem ACL | Not required; 7B HF is NFS `/mnt/cluster-ssd` |

These PCs use `.wslconfig` `networkingMode=mirrored`. Mount options must include
`noresvport` ([WSL#12508](https://github.com/microsoft/WSL/issues/12508)).

**Start 7B** remounts `/mnt/cluster` (HDD corpus) and `/mnt/cluster-ssd` (SSD 7B HF)
on each participating host when those paths are not mountpoints (`wsl -d Ubuntu -u root`).
Use the HDD paste below only for a **one-time** `nfs-common` install, or if Start still
fails (hub NFS down). Start does not run `apt-get` on every launch. SSD export
must exist (`/mnt/ssd/Alfa-AI`) and `promote-hf-7b-to-ssd.sh` must have run.

**`gaming-c` / `gaming-b` (sudo works):**

```powershell
wsl -d Ubuntu bash -lc "sudo apt-get update -qq; sudo apt-get install -y -qq nfs-common; sudo mkdir -p /mnt/cluster; timeout 30 sudo mount -t nfs -o vers=4.1,noresvport,soft,timeo=50,retrans=2 hub:/mnt/HDDs/Alfa-AI /mnt/cluster; mountpoint /mnt/cluster; ls /mnt/cluster/training/alfa-train/datasets; ls /mnt/cluster/models/huggingface/hub | head"
```

**`gaming-a` (sudo password failed -- use root user):**

```powershell
wsl -d Ubuntu -u root bash -lc "apt-get update -qq; apt-get install -y -qq nfs-common; mkdir -p /mnt/cluster; timeout 30 mount -t nfs -o vers=4.1,noresvport,soft,timeo=50,retrans=2 hub:/mnt/HDDs/Alfa-AI /mnt/cluster; mountpoint /mnt/cluster; ls /mnt/cluster/training/alfa-train/datasets; ls /mnt/cluster/models/huggingface/hub | head"
```

**Pass criteria (every host in this Start):** required `gaming-c` / `gaming-b`; also `gaming-a` when `-Include219` is set.

- `/mnt/cluster is a mountpoint` (HDD: corpus / logs / checkpoints)
- `alfa-corpus-train.jsonl` and `alfa-corpus-val.jsonl` under `/mnt/cluster/training/alfa-train/datasets`
- `/mnt/cluster-ssd is a mountpoint` (SSD: 7B HF)
- `models--Qwen--Qwen2.5-Coder-7B-Instruct` under `/mnt/cluster-ssd/models/huggingface/hub`

Mount is **not** persistent across WSL restart until `/etc/fstab` (or a boot script)
uses the same options. Start remounts on the next **Start 7B** / **Open TensorBoard**
when `mountpoint` fails.

#### C. Axolotl Docker image (hub tarball -- once per host)

Image: `axolotlai/axolotl-uv:main-py3.12-cu130-2.12.0`
([Axolotl install](https://docs.axolotl.ai/docs/installation.html)).
Hub file: `\\hub\docker-images\axolotl-uv-main-py3.12-cu130-2.12.0.tar.gz`
(~8.3 GB gzip). WSL cannot read a mapped drive letter such as `I:`; copy via **UNC**
to `C:\alfa-ai-cache\docker-images\` then `docker load` from `/mnt/c/...`.

Check free space first (need ~10+ GB free on C: for the copy; the loaded image lives
in Docker/WSL data, not as a second 33 GB file on C:):

```powershell
Get-PSDrive C | Select-Object Used,Free
```

1. Copy from hub SMB:

```powershell
New-Item -ItemType Directory -Force -Path C:\alfa-ai-cache\docker-images | Out-Null; Copy-Item -Force '\\hub\docker-images\axolotl-uv-main-py3.12-cu130-2.12.0.tar.gz' 'C:\alfa-ai-cache\docker-images\'; Get-Item 'C:\alfa-ai-cache\docker-images\axolotl-uv-main-py3.12-cu130-2.12.0.tar.gz' | Select-Object FullName,Length
```

2. Load into WSL Docker engine:

```powershell
wsl -d Ubuntu bash -lc "docker load -i /mnt/c/alfa-ai-cache/docker-images/axolotl-uv-main-py3.12-cu130-2.12.0.tar.gz; docker images axolotlai/axolotl-uv"
```

3. Delete the gzip immediately (reclaims ~8 GB on C:):

```powershell
Remove-Item -Force 'C:\alfa-ai-cache\docker-images\axolotl-uv-main-py3.12-cu130-2.12.0.tar.gz'; Get-PSDrive C | Select-Object Used,Free
```

#### D. Host checklist (after bring-up)

| Host | NFS `/mnt/cluster` (HDD) | NFS `/mnt/cluster-ssd` (SSD HF) | Axolotl image | Notes |
|------|--------------------------|---------------------------------|---------------|--------|
| `gaming-c` gaming-worker-c (Colin) | corpus/logs | 7B HF | OK | Rank 0 rdzv |
| `gaming-b` gaming-worker-b (Cody) | corpus/logs | 7B HF | OK | Rank 1 |
| `gaming-a` gaming-worker-a (Corey) | corpus/logs | 7B HF | OK | Optional rank 2; `wsl -u root` |

Also required before **Start 7B QLoRA**: alfa-train clone on each host, TCP **29500** between
trainers, and no stale `alfa-train.lock` unless intentionally training.

**SMB note:** `\\hub\docker-images` is used only for the tarball copy.
`\\hub\huggingface` ACL may deny gaming users; training uses NFS
`/mnt/cluster/models/huggingface`, not SMB.

## Launch (Start script)

`Start-AlfaTrain7bQlora.ps1` builds `axolotl train`
inside the published image.
Default 2-node/3-node uses `--launcher torchrun` and `configs/pool-7b-qlora-sft.yaml`
(DDP QLoRA; **no** `deepspeed:`)
([Axolotl multi-node](https://docs.axolotl.ai/docs/multi-node.html),
[multi-GPU DDP default](https://docs.axolotl.ai/docs/multi-gpu.html)).
`-SingleHost59` uses `--launcher python` and the **same** yaml on `gaming-c` only and skips
rdzv TCP 29500
([Axolotl CLI](https://docs.axolotl.ai/docs/cli.html),
[FAQ](https://docs.axolotl.ai/docs/faq.html)). Every `docker run` sets
`PYTORCH_ALLOC_CONF=expandable_segments:False`
([CUDA semantics](https://docs.pytorch.org/docs/2.14/notes/cuda.html);
`PYTORCH_CUDA_ALLOC_CONF` is the documented alias). CLI overrides
**before** `--launcher`: `--embeddings-skip-upcast` (bare flag, **no value**),
`--no-eval-sample-packing` (bare `--no-*` flag), `--eval-batch-size 1` (takes a value),
and `--eval-strategy=no` (string `no`; equals form so Click/YAML do not coerce boolean false). Do **not**
pass `--bf16 full` on image `cu130-2.12.0` (schema rejects `full`).
Axolotl builds every boolean config option as a Click flag pair `--name/--no-name`
([`add_options_from_config`](https://github.com/axolotl-ai-cloud/axolotl/blob/main/src/axolotl/cli/utils/args.py),
[config reference](https://docs.axolotl.ai/docs/config-reference.html)). A trailing `true` is
not consumed by a boolean flag; `train` runs with `allow_extra_args`, so the stray token is
forwarded to torchrun as the **training script** and rank 0 dies with `true FAILED` / `can't
open file '/workspace/alfa-train/true'` before TCP 29500 ever opens (2026-09-08 run). The same
options are also set in `configs/pool-7b-qlora-sft.yaml` (`embeddings_skip_upcast: true`,
`eval_sample_packing: false`, `eval_batch_size: 1`) so the YAML is correct on its own; the
flags cover clones that have not pulled yet. Packed eval on 12 GB WSL hit `CUDA driver error:
device not ready` in `ForCausalLMLoss` `logits.float()` after weight load (2026-09-11)
([config reference](https://docs.axolotl.ai/docs/config-reference.html),
[multi-GPU memory](https://docs.axolotl.ai/docs/multi-gpu.html)).
Flags after `--` are passed to torchrun. Endpoint form is `host:port`
([torchrun](https://docs.pytorch.org/docs/stable/elastic/run.html)).

### Leftover launcher / container preflight (mandatory)

Before `alfa-desktop-job.lock` / `alfa-train.lock` / `docker run`, Start:

1. Queries `powershell.exe` on `orchestrator` with `Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe'"`
   ([Get-CimInstance](https://learn.microsoft.com/en-us/powershell/module/cimcmdlets/get-ciminstance?view=powershell-5.1))
   and refuses if another PID's `CommandLine` contains `Start-AlfaTrain7bQlora.ps1`,
   `Stop-AlfaTrain7bQlora.ps1`, or leftover names `Start-AlfaTrain14bQlora.ps1` /
   `Stop-AlfaTrain14bQlora.ps1` from old sessions (14B Start/Stop scripts are gone;
   preflight only)
   ([Win32_Process CommandLine](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-process)).
   The ALFa Trainer GUI (`train-desktop-menu.ps1`) is not that match.
2. After SSH, `docker ps -a --filter name=alfa-train-7b` on each participating host
   ([filter](https://docs.docker.com/reference/cli/docker/container/ps/#filter)).
   Also refuse leftover `alfa-train-14b*` from removed 14B trainer. Any leftover name
   fails Start; run Stop trainer first. This is separate from the rpc-server `docker ps`
   check.

### Hub NFS preflight (mandatory)

Before lock / `docker run`, Start SSHs into **all participating** hosts (always
`gaming-c`, `gaming-b`; plus `gaming-a` only when `-Include219`).

If `mountpoint -q /mnt/cluster` is already true, Start only verifies hub files on
that mount. If it is **not** a mountpoint (WSL restart drops NFS), Start remounts
using the same options as the operator paste
([mount(8)](https://man7.org/linux/man-pages/man8/mount.8.html),
[timeout(1)](https://man7.org/linux/man-pages/man1/timeout.1.html),
WSL `--user root`
([basic commands](https://learn.microsoft.com/en-us/windows/wsl/basic-commands))
so SSH BatchMode does not need a sudo password):

`mount -t nfs -o vers=4.1,noresvport,soft,timeo=50,retrans=2 hub:/mnt/HDDs/Alfa-AI /mnt/cluster`

It also remounts the **SSD** export the same way:

`mount -t nfs -o vers=4.1,noresvport,soft,timeo=50,retrans=2 hub:/mnt/ssd/Alfa-AI /mnt/cluster-ssd`

Then it requires:

1. `mountpoint -q /mnt/cluster` ([mountpoint(1)](https://man7.org/linux/man-pages/man1/mountpoint.1.html))
2. Hub corpus: `training/alfa-train/datasets/alfa-corpus-train.jsonl` on **HDD** `/mnt/cluster`
3. `mountpoint -q /mnt/cluster-ssd`
4. 7B HF snapshot `config.json` under
   `/mnt/cluster-ssd/models/huggingface/hub/models--Qwen--Qwen2.5-Coder-7B-Instruct/snapshots/`
5. Writable `hub/.locks` (`touch` test). `chmod a+rX` on the promote is not enough;
   huggingface_hub writes lock files under the cache root
   ([manage-cache](https://huggingface.co/docs/huggingface_hub/en/guides/manage-cache)).
   If this fails: on `hub`, `mkdir -p` + `chmod a+rwx` on
   `/mnt/ssd/Alfa-AI/models/huggingface/hub` and `hub/.locks`.

Docker `HF_HOME` is `/mnt/cluster-ssd/models/huggingface` (SSD). Container also sets
`HF_HUB_OFFLINE=1` so Transformers does not call huggingface.co
([HF_HUB_OFFLINE](https://huggingface.co/docs/huggingface_hub/en/package_reference/environment_variables),
[Transformers offline](https://huggingface.co/docs/transformers/installation#offline-mode)).
Do not load 7B weights from spinning `/mnt/cluster/models/huggingface`.

Gaming hosts: WSL. Remount runs as `wsl -d Ubuntu -u root`. Start does **not** SSH to `inference`.
If `mount.nfs` is missing, Start fails (install `nfs-common` once; do not `apt-get` on every Start).
If the SSD share or promote is missing, Start fails (do not fall back to HDD HF).

**Open TensorBoard** remounts `/mnt/cluster` on `gaming-c` the same way if needed.

Containers start with **`docker run -d`** so dockerd owns the process after SSH returns
([Docker detached mode](https://docs.docker.com/reference/cli/docker/container/run/#detach)).
Do not use SSH `nohup` / `Start-Process wsl.exe` as the detach path -- official docs are
silent on those, and they killed the rdzv store on `gaming-c`.

The image ENTRYPOINT is `/workspace/axolotl/scripts/uv-entrypoint.sh`
([Axolotl Docker](https://docs.axolotl.ai/docs/installation.html)). The alfa-train clone is
bind-mounted at **`/workspace/alfa-train`** (not `/workspace`).

Launch order: **`gaming-c` first** (c10d store at `--rdzv_endpoint`), wait until TCP **29500** is
open from `orchestrator`, then **`gaming-b`**, then **`gaming-a`** (only if `-Include219`).
Start then **watches hub logs**
(fail-fast). It **returns success** only after rank-0 logs show **`loss` or `Total train batch`**
(real train loop), or **aborts and runs Stop trainer** if logs show hard errors
(`device not ready`, `PermissionError`, `DistNetworkError`, tracebacks) or no progress within
10 minutes. **`trainable params` alone is not success** (first eval may still run). The lock
stays until **Stop trainer**.

### Fail-fast (no silent wedges)

PyTorch process-group connect defaults to **30 minutes** for non-NCCL backends
([`init_process_group` timeout](https://docs.pytorch.org/docs/stable/distributed.html#torch.distributed.init_process_group)).
C10d rendezvous `join_timeout` defaults to **600 seconds**
([RendezvousTimeout](https://docs.pytorch.org/docs/stable/elastic/rendezvous.html)).
This cluster must not sit on green **TRAINING** for that long while ranks only print
IPv6 hostname warnings.

| Guard | What it does |
|-------|----------------|
| `--rdzv_conf join_timeout=180` | Torchrun rendezvous fails in 3 min if a node never joins ([rdzv conf](https://docs.pytorch.org/docs/stable/elastic/rendezvous.html)) |
| `--local-addr` + Docker `--add-host` | Advertise LAN IPs; map peer hostnames so DDP/c10d does not wait on broken DNS |
| Hub-log watchdog (~10 min) | Start greps rank-0 hub log; `device not ready` / `PermissionError` / `DistNetworkError` / traceback **aborts immediately**; `Downloading` / `Loading weights` / `trainable params` alone are **not** success |
| GUI **STARTING** vs **TRAINING** vs **FAILED** | Container Up is not success. Green **TRAINING** only after hub log shows **`loss` or `Total train batch`**. Red **FAILED** on hard errors while lock is set. Footer **Train job: OK** does not override Status |

**Open TensorBoard** can still fail if NFS is down; that is a loud error, not a hang.

**`gaming-c` must pass `--rdzv_conf is_host=1`** (workers `is_host=0`). PyTorch c10d only creates
the TCPStore when the endpoint hostname/IP matches the machine, or when `is_host` is set
([rendezvous backend](https://docs.pytorch.org/docs/stable/elastic/rendezvous.html)).
On gaming WSL, `hostname` often resolves to `127.0.1.1` while the endpoint is
`orchestrator`, so without `is_host=1` every rank only connects as a client and
times out -- nothing listens on 29500.

### Peer hostname DNS (DDP / second TCPStore)

After torchrun rendezvous on `:29500`, Axolotl calls `PartialState` /
`init_process_group`, which peers advertise as WSL FQDNs or Linux hostnames. Those names are
**not** in LAN DNS. Docker `--network host` still uses the **container** `/etc/hosts`, so peers
cannot resolve each other without explicit mapping.

Start script fix ([Docker `--add-host`](https://docs.docker.com/reference/cli/docker/container/run/#add-host),
torchrun `--local-addr` per [elastic run](https://docs.pytorch.org/docs/stable/elastic/run.html)):

| Hostname / FQDN | LAN IP |
|-----------------|--------|
| `QuantumExampleX` / `QuantumExampleX` | `orchestrator` |
| `QuantumBladeX` / `QuantumBladeX.localdomain` | `orchestrator` |
| `DESKTOP-7EOGC3R` / `DESKTOP-7EOGC3R.localdomain` | `orchestrator` |

`--local-addr <LAN-IP>` advertises a reachable address for this node.

If connect still times out **after** names resolve, Hyper-V firewall on mirrored WSL
is blocking DDP/NCCL **ephemeral** TCP (a past failure used port **46437**, not
29500). A rule for **only** `:29500` is not enough
([WSL networking](https://learn.microsoft.com/en-us/windows/wsl/networking),
[New-NetFirewallHyperVRule](https://learn.microsoft.com/en-us/powershell/module/netsecurity/new-netfirewallhypervrule)
`LocalPorts` default Any; `RemoteAddresses` CIDR).

**From `gaming-c`, `gaming-b`, and `gaming-a` (Admin PowerShell)** -- LAN inbound TCP to WSL (not 29500-only):

```powershell
New-NetFirewallHyperVRule -Name AlfaTrainLan -DisplayName AlfaTrainLan -Direction Inbound -VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -Protocol TCP -RemoteAddresses orchestrator/24
```

If launch fails, Start runs Stop trainer to clear containers/lock. Core 27B is not stopped.
That also **removes** `--rm` containers, so Docker logs are gone after a failed Start
unless the wait path dumps them first.

If the GUI shows **Train job: FAIL** and `rdzv port orchestrator not open`:
check the dumped `gaming-c` logs for `RendezvousConnectionError` / client timeout to `:29500`
(missing `is_host=1`) vs Hyper-V firewall
([WSL networking](https://learn.microsoft.com/en-us/windows/wsl/networking)).
Do not start **Pool72/Pool80** or opt-in **`gaming-c`/`gaming-b`/`gaming-a`** (when `INCLUDE_219=1`) from
**ALFa Models** until Train Status is idle with no lock. **inference core** Start may proceed
while 7B trains.

**Stop trainer** `docker rm -f` the named `alfa-train-7b-*` containers on required hosts
(`gaming-c`, `gaming-b`) and best-effort on `gaming-a`. It does **not** stop inference on `inference`.

### Mirrored WSL LAN inbound (TCP -- not 29500-only)

`gaming-c` uses `networkingMode=mirrored`. Microsoft documents LAN access plus **Hyper-V firewall**
(default on for WSL 2.0.9+):
[Accessing network applications with WSL](https://learn.microsoft.com/en-us/windows/wsl/networking)
and [Hyper-V firewall](https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/hyper-v-firewall).

Torchrun rdzv uses **29500**. DDP/NCCL uses an **ephemeral** port
(last measured failure: **46437**). A 29500-only rule does not cover that.

**From `gaming-c`, `gaming-b`, and `gaming-a` (Admin PowerShell)** -- one-time, LAN inbound TCP to WSL:

```powershell
New-NetFirewallHyperVRule -Name AlfaTrainLan -DisplayName AlfaTrainLan -Direction Inbound -VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -Protocol TCP -RemoteAddresses orchestrator/24
```

(`LocalPorts` omitted = Any, which is the documented default.)

If rdzv wait still times out, check `wsl -d Ubuntu docker logs alfa-train-7b-59` on `gaming-c`.

## Desktop GUI (`train-desktop-menu.ps1`)

Desktop shortcut **ALFa Trainer 7B** from
[install-cluster-desktop-shortcut.ps1](../../deploy/cluster-members/orchestrator/install-cluster-desktop-shortcut.ps1)
(alongside **ALFa Models** -> `models-desktop-menu.ps1`). Title bar: **ALFa Trainer 7B r8**.
Trainer-only; no Home cards, pool radios, or cluster Start/Stop.

| Control | Action |
|---------|--------|
| **Train island SSH** | TCP `:22` badges for `gaming-c` / `gaming-b` (not inference RPC ports) |
| **Run settings** | Checkboxes before Start: **Include gaming-a**, **gaming-c only**, **Fresh adapter**. All off is the production 2-node continue. Include gaming-a and gaming-c only cannot both be checked. |
| **Start 7B QLoRA** | Confirm, then `Start-AlfaTrain7bQlora.ps1` with those flags. Does **not** stop core 27B. Fails if train GPUs still run rpc-server. |
| **Stop trainer** | `Stop-AlfaTrain7bQlora.ps1` (`docker rm -f` on required hosts; `gaming-a` best-effort; remove lock when policy allows) |
| **Open TensorBoard** | `Start-AlfaTrainTensorBoard.ps1` (metrics UI at `http://127.0.0.1:6006/`) |
| **Refresh** | Force SSH `docker ps` + hub log tail into Status and terminal |
| **Show terminal** | Collapsed by default; streams train job stdout/stderr. Closing the GUI while Start/Stop trainer runs: **Yes** kills it, **No** leaves it running, **Cancel** stays open. |

Start **does not** return OK just because `docker run -d` succeeded. It watches hub logs
(fail-fast). Use **Stop trainer** to end a healthy job or to clear a **FAILED** / **FINISHED** / **JOB ENDED** lock.
**Stop trainer** is greyed only while this window's **Start** child holds `alfa-desktop-job.lock`.
After Start exits 0, Stop stays enabled even if **ALFa Models** is running cluster Start/Stop;
Status shows TRAINING/STARTING from hub probe, not the Models peer message (r7+). Failed Start
runs nested Stop with `ALFA_DESKTOP_JOB_NEST=1` so cleanup does not deadlock on the parent lock.

Containers use `docker run --rm` ([Docker --rm](https://docs.docker.com/reference/cli/docker/container/run/#rm)),
so when Axolotl exits the named containers disappear. The lock file does **not** clear by itself.

### Persistent train logs (hub)

Each Start mounts hub `training/alfa-train` and runs Axolotl under
`bash -lc '... | tee <hub>/logs/...'` so stdout/stderr survive container removal
([Docker bind mounts](https://docs.docker.com/engine/storage/bind-mounts/),
[tee](https://man7.org/linux/man-pages/man1/tee.1.html)).

| Item | Path |
|------|------|
| Log directory | `/mnt/cluster/training/alfa-train/logs/pool-7b-<yyyyMMddTHHmmssZ>/` |
| Rank 0 (`gaming-c`) | `alfa-train-7b-59.log` |
| Rank 1 (`gaming-b`) | `alfa-train-7b-249.log` |
| `gaming-a` (optional) | `alfa-train-7b-219.log` (only if `-Include219`; then rank 2) |

After **FINISHED** / **FAILED** / **JOB ENDED**, read those files on any host with `/mnt/cluster` (or via `gaming-c` WSL).
Do not rely on `docker logs` after `--rm`. Rank-0 (`alfa-train-7b-59.log`) may stay small (config + load);
DDP progress, `{'loss': ...}`, `train_runtime`, and Axolotl **Training completed!** often land in
rank-1 `alfa-train-7b-249.log`. The GUI probe tails **both** files.

### Train Status readout (GUI)

The Train **Status** line and lock-status text distinguish launch vs job vs idle.
Open **ALFa Trainer 7B r5** and click **Refresh** to probe (30s timer cache; Refresh
force-probes).

The probe SSHs to `gaming-c` using the same base64-wrapped WSL bash as
`Start-AlfaTrain7bQlora.ps1` (avoids nested quote breakage). `docker ps` and `tail`
each have `timeout -k 2 8`
([timeout(1)](https://man7.org/linux/man-pages/man1/timeout.1.html) exit **124** is
normal when `tail` hits the limit). The GUI reads stdout even when ssh's exit code
is non-zero. Process start uses `ProcessStartInfo.Arguments`
([docs](https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.processstartinfo.arguments)),
not `Start-Process -ArgumentList`. stdout/stderr are read with
[`StreamReader.ReadToEndAsync`](https://learn.microsoft.com/en-us/dotnet/api/system.io.streamreader.readtoendasync)
tasks (both streams drained concurrently per the
[Process.StandardOutput](https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process.standardoutput)
deadlock note). **Never** attach PowerShell scriptblocks to `OutputDataReceived` /
`ErrorDataReceived`: those events fire on thread-pool threads with no PowerShell runspace
and terminate `powershell.exe` silently (exit 2, no message) -- that was the "trainer GUI
keeps closing ~16 s after open" symptom (first 12 s timer probe). `ConnectTimeout` is TCP/handshake only
([ssh_config](https://man.openbsd.org/ssh_config.5)). Local `WaitForExit(20000)` then
`Kill` bounds a stuck `ssh`
([WaitForExit](https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process.waitforexit)).
Hub rank-0 log path comes from `LOGDIR=` in the lock file. Container Up alone is not **TRAINING**.

**Reload the menu after script edits:** the **ALFa Trainer 7B** shortcut runs
`powershell -File train-desktop-menu.ps1` once
([about_PowerShell.exe](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_powershell_exe)).
Fully close the window and reopen. The title bar must show **ALFa Trainer 7B r5**.
An old process does not load new probe code.

Train-page SSH badges are TCP `:22` only (updated on open and Refresh). They are **not**
copied from **ALFa Models** inference lights.

**Refresh** force-probes `gaming-c` docker + hub log, updates Status, and appends a hub-log tail
to the terminal. The Start-script stdout stream stops when the launcher exits; the footer may
say **Launcher finished (see Status)** when the lock is still **STARTING** or **FAILED** -- not
**Train job: OK**. Without Refresh, the panel stays on the last `Loading weights` lines.

If a lock file exists, Status probes even while the Start script is still running
(no sticky **LAUNCHING** that skips the hub log).

| Status text | Meaning | What to do |
|-------------|---------|------------|
| **STARTING** | Lock on, container Up, hub log has no **`loss` / `Total train batch`** yet (may show `trainable params` / load) | Wait through first eval; click Refresh if stuck past watchdog |
| **TRAINING** | Lock on, container Up, hub log shows **`loss` or `Total train batch`** | Wait; TensorBoard for curves. **inference core** Start allowed; do not Start Pool72/Pool80 or opt-in `gaming-c`/`gaming-b`/`gaming-a` (when `INCLUDE_219=1`). Core 27B may already be running. |
| **FAILED** | Lock on; hub log has `DistNetworkError` / timeout / traceback / `PermissionError` on `/data/hf/hub/.locks` or `/data/hf/datasets` / `CUDA driver error: device not ready` (or container died with an error) | **Stop trainer**. If `.locks` permission denied: fix SSD HF cache write on `hub` (`chmod a+rwx` on `hub/` and `hub/.locks`). If `/data/hf/datasets` permission denied: pull latest Start script (`HF_DATASETS_CACHE` on hub `training/alfa-train/cache/datasets`) or `chmod a+rwx` that dir on `hub`. If CUDA not-ready after weight load: confirm `nvidia-smi` idle on `gaming-c`/`gaming-b`, pull alfa-train (`eval_sample_packing: false`, `activation_offloading: false`), then Start 7B again. Do not stop core 27B. Do not Start 14B. |
| **FINISHED** | Lock on, containers gone (`--rm`), hub log has a **completion** marker: Axolotl `Training completed!` / `Model successfully saved` ([axolotl.train](https://docs.axolotl.ai/docs/training_stability.html)) or HuggingFace `'train_runtime'` ([Trainer](https://huggingface.co/docs/transformers/main_classes/trainer), `logger.info("Training completed...")` in [trainer.py](https://github.com/huggingface/transformers/blob/main/src/transformers/trainer.py)) | **Stop trainer** to clear lock. Adapter is at hub `checkpoints/pool-7b-qlora-v2`. Do not Start 7B again unless you intend another continue pass. Then follow **After this 7B job finishes** below (convert, sequential eval, live Yes/No). LiteLLM only when operator asks after live Yes/No passes. |
| **JOB ENDED** | Lock on, containers gone, hub log has **neither** a completion marker **nor** a FAILED pattern (killed, `--rm` with empty tail, or probe missed the end) | **Stop trainer** to clear lock, then read both rank logs. Do not treat this as success. |
| **TRAIN LOCK on (probe failed)** | Lock on but `gaming-c` SSH/`docker ps` did not return UP/DOWN | Click **Refresh**. Do **not** Stop trainer -- the 7B container may still be loading weights. Open terminal for probe stderr. |
| **LAUNCHING** | Start script running **and** no lock yet | Wait; after lock, Status follows hub log (STARTING/TRAINING) even if the launcher process is still up |
| **IDLE** / cluster running|stopped | No lock | Start 7B when ready, or use **ALFa Models** for inference |

**Train job: OK** only means the Start *launcher* on `orchestrator` exited 0 **and** the hub log already
shows **`loss` or `Total train batch`**. Otherwise the footer reads **Launcher finished (see
Status)** -- not green success. The terminal line `== launcher finished exit=0 ==` is that
same launcher, **not** epoch completion. Epoch completion is Status **FINISHED** (completion
markers in the hub logs) after containers exit `--rm`.

### Metrics UI (TensorBoard -- not WinForms)

The Train page is **control only** (Start / Stop / lock / SSH). Do **not** expect loss,
step, or epoch in the WinForms status line.

**TensorBoard is available anytime** (GUI idle, mid-run, after **Stop trainer**): the
`gaming-c` sidecar `alfa-train-tb` uses `--restart unless-stopped` (no `--rm`; see
[Docker restart policies](https://docs.docker.com/engine/reference/run/#restart-policies)).
The GUI starts it in the background on open; **Start 7B** also invokes the helper.
**Stop trainer** does **not** remove `alfa-train-tb`.

**Watch training progress in TensorBoard** ([Axolotl training stability](https://docs.axolotl.ai/docs/training_stability.html),
[TensorBoard get started](https://www.tensorflow.org/tensorboard/get_started)).
Live training `output_dir` is per yaml (`pool-7b-qlora-v2`). TensorBoard `--logdir` is
**`output_dir/runs`** (`/tb/runs` in the sidecar), not the parent `checkpoints/` tree and
not the adapter-weight files next to `runs/`
([Axolotl training stability](https://docs.axolotl.ai/docs/training_stability.html)
`tensorboard --logdir output_dir/runs`). Walking the whole job dir delayed
`/data/plugins_listing` so the chrome showed **Data could not be loaded**.

| Item | Value |
|------|--------|
| Event files | Hub `output_dir/runs` (`pool-7b-qlora-sft.yaml` `output_dir`) |
| Default logdir (sidecar) | `/mnt/cluster/training/alfa-train/checkpoints/pool-7b-qlora-v2` mounted at `/tb` |
| Operator URL on `orchestrator` | `http://127.0.0.1:6006/` (SSH tunnel from helper script) |
| Start server | GUI **Shown** (background); **Open TensorBoard** (browser); **Start 7B** (ensure sidecar) |
| TensorBoard flags | `--logdir=/tb/runs --host=0.0.0.0 --port=6006 --load_fast=false --reload_interval=5 --detect_file_replacement=true --reload_multifile=true` |
| Health | Helper polls **`/data/plugins_listing`** inside `gaming-c` WSL (the same handshake the TensorBoard chrome uses), not GET `/` ([issue 4844](https://github.com/tensorflow/tensorboard/issues/4844), [curl](https://curl.se/docs/manpage.html), [WSL mirrored localhost](https://learn.microsoft.com/en-us/windows/wsl/networking)). GET `/` can 200 while the multiplexer is still walking `runs/`; the UI then shows **Data could not be loaded**. TensorBoard may **RST** the first connections; the helper retries up to **120s** and must not treat ssh stderr as a terminating error under `$ErrorActionPreference = 'Stop'` on Windows PowerShell 5.1 ([`$ErrorActionPreference`](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_preference_variables), native stderr to the Error stream ([running commands](https://learn.microsoft.com/en-us/powershell/scripting/learn/shell/running-commands))). On timeout, the helper prints `docker logs --tail 80 alfa-train-tb`. Then OpenSSH `-L` ([ssh](https://man.openbsd.org/ssh)). |
| UI refresh | Since TensorBoard 2.3 the web UI does **not** auto-reload; enable **Reload data** in the gear menu ([README](https://github.com/tensorflow/tensorboard/blob/master/README.md)). Backend reloads event files every 5s (`--reload_interval=5`; `0` = load once at startup per [core_plugin.py](https://github.com/tensorflow/tensorboard/blob/master/tensorboard/plugins/core/core_plugin.py)). |

**From `orchestrator` (PowerShell as `operator`):**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-AlfaTrainTensorBoard.ps1
```

Background sidecar only (no browser):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-AlfaTrainTensorBoard.ps1 -NoBrowser -SkipIfHealthy
```

**Open TensorBoard** recreates the sidecar on `gaming-c` when unhealthy; it does **not** stop
`alfa-train-7b-*` trainers. If `127.0.0.1:6006` listens but HTTP fails (stale SSH
forward), the helper kills the leftover `ssh.exe -L` tunnel and opens a new one.

`--load_fast=false` is TensorBoard's documented escape hatch for the default
`--load_fast=auto` path (RustBoard / gRPC data server). Through the `orchestrator` SSH tunnel,
that default served the TensorBoard chrome with **Data could not be loaded / The
TensorBoard server may be down or inaccessible** while `/data/plugin/scalars` already
had `train/loss`. Official: TensorBoard CLI `--load_fast` choices `false` / `auto` /
`true` ([core_plugin.py](https://github.com/tensorflow/tensorboard/blob/master/tensorboard/plugins/core/core_plugin.py)),
feedback issue [#4784](https://github.com/tensorflow/tensorboard/issues/4784).
The same orange page also appears when GET `/` is already 200 but
`/data/plugins_listing` is still scanning NFS event files
([issue 4844](https://github.com/tensorflow/tensorboard/issues/4844)), **and** when
the default browser **reuses** a tab that already failed (same
`http://127.0.0.1:6006/` URL). Close that tab. The helper opens
`http://127.0.0.1:6006/?v=<unix>#scalars` so Edge starts a new navigation.
That orange page is **not** the empty-logdir state. Waiting with no event files yet is
**No dashboards are active for the current data set**
([TensorBoard get started](https://www.tensorflow.org/tensorboard/get_started),
[Scalars](https://www.tensorflow.org/tensorboard/scalars_and_keras)).

Axolotl logs `train/loss`, `train/learning_rate`, `eval/loss`, and related scalars every
`logging_steps` when `use_tensorboard: true` is set in the YAML
([Axolotl config reference](https://docs.axolotl.ai/docs/config-reference.html),
[training stability](https://docs.axolotl.ai/docs/training_stability.html)).
First scalars are eligible after the first `logging_steps` (this yaml: every 5 steps),
not after an epoch.

Runs started **before** TensorBoard was enabled in config will not have event files until
the next **Start 7B** after `git pull` on trainer clones.

## Verify after this fix set (operator)

**From `orchestrator` (operator):** `git pull --ff-only origin main` in `C:/Users/operator\alfa-ai`.

On **`gaming-c` and `gaming-b`:** `git pull --ff-only origin main` in `C:\alfa-ai-train` (alfa-train repo).

Close and reopen **ALFa Trainer 7B.lnk** (title must show **ALFa Trainer 7B r6**).
Do **not** stop core 27B.

1. Confirm **IDLE** (no lock). Click **Stop trainer** first if Status is FAILED with a lock.
2. Click **Start 7B QLoRA**.
3. Expect **STARTING** through weight load (several minutes); Status must **not** flip green on `trainable params` alone.
4. Success: Status **TRAINING** and hub log `pool-7b-<UTC>/alfa-train-7b-59.log` contains **`loss`** or **`Total train batch`** with containers still Up.
5. Failure: Status **FAILED**; click **Stop trainer**, read hub log. Dump should show **DDP** (no `deepspeed:`), `activation_offloading: false`, and base `Qwen/Qwen2.5-Coder-7B-Instruct`.

Judge from hub log under `/mnt/cluster/training/alfa-train/logs/` (or **Refresh** tail in GUI), not footer text alone.

**ALFa Models** host-status **DN** on RPC/LiteLLM/brain after a successful Stop cluster is
expected -- those are inference ports, not trainer Docker. Use **ALFa Models** **Refresh**
for inference lights; use **ALFa Trainer 7B r5** **Refresh** for train Status (probe reads
`alfa-train.lock` and the train-container check, not coordinator `:31360`).

## CLI (same behavior)

**From `orchestrator` (PowerShell as `operator`):**

```powershell
cd C:/Users/operator\alfa-ai
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-AlfaTrain7bQlora.ps1
```

`gaming-c`-only diagnostic (`--launcher python` + same `pool-7b-qlora-sft.yaml`):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-AlfaTrain7bQlora.ps1 -SingleHost59
```

3-node with optional `gaming-a`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-AlfaTrain7bQlora.ps1 -Include219
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Stop-AlfaTrain7bQlora.ps1
```

Override Windows train root (default `C:\alfa-ai-train`):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-AlfaTrain7bQlora.ps1 -TrainRootWin D:\alfa-ai-train
```

## Launch command (train island)

Per [Axolotl multi-node](https://docs.axolotl.ai/docs/multi-node.html) and
[PyTorch rendezvous `is_host`](https://docs.pytorch.org/docs/stable/elastic/rendezvous.html).
`--nnodes` must equal the number of hosts that actually launch
([torchrun](https://docs.pytorch.org/docs/stable/elastic/run.html)).

**Head (`gaming-c`, node_rank 0)** -- hosts the c10d TCPStore (2-node example):

```bash
axolotl train configs/pool-7b-qlora-sft.yaml --embeddings-skip-upcast --launcher torchrun -- \
  --nnodes 2 --nproc_per_node 1 --node_rank 0 \
  --rdzv_id alfa-train-pool7b-n2 --rdzv_backend c10d \
  --rdzv_endpoint orchestrator \
  --rdzv_conf is_host=1,join_timeout=180 \
  --local-addr orchestrator
```

**Workers** -- same `nnodes` / `rdzv_id` / endpoint; `is_host=0` and matching `node_rank` /
`--local-addr`:

| Host | 2-node rank | 3-node rank | --local-addr |
|------|-------------|-------------|--------------|
| `gaming-b` gaming-worker-b | 1 | 1 | `orchestrator` |
| `gaming-a` gaming-worker-a | (skipped) | 2 | `orchestrator` |

3-node uses `--nnodes 3` and `--rdzv_id alfa-train-pool7b-n3` on every rank.
1-node torchrun (not the python diagnostic) would use `--rdzv_id alfa-train-pool7b-n1`.

Example worker (`gaming-b`, 2-node):

```bash
axolotl train configs/pool-7b-qlora-sft.yaml --embeddings-skip-upcast --launcher torchrun -- \
  --nnodes 2 --nproc_per_node 1 --node_rank 1 \
  --rdzv_id alfa-train-pool7b-n2 --rdzv_backend c10d \
  --rdzv_endpoint orchestrator \
  --rdzv_conf is_host=0,join_timeout=180 \
  --local-addr orchestrator
```

## Continue-train progress (how to read improvement)

**Training loss (hub rank-0 log `alfa-train-7b-249.log`, final `train_loss` line):**

| Hub log dir suffix | `train_loss` (2 epochs) |
|--------------------|-------------------------|
| `20260918T172156Z` | 0.4354 |
| `20260918T234347Z` | 0.2886 |
| `20260923T165604Z` | 0.1992 |

Lower loss means the mixed corpus fits better; it is **not** the deploy gate.

**After each cycle (artifacts on `orchestrator` `D:\alfa-ai-cache\eval\`):**

| Check | Meaning |
|-------|---------|
| `train_checkpoint_gate.py` | Keyword smoke vs `eval/gold/smoke.jsonl` (`promote_allowed` is informational; cycle keeps going on FAIL). |
| `live_7b_faq_gate.py` | **Hard gate:** first three `UNIQUE_TURNS` must answer **No** on `:8470` with LoRA. Cycle exits non-zero if any mismatch. |

Sep 23 checkpoint example: smoke **6/10** (up from base **3/10**); live FAQ **1/3** (FAQ2 only). Next continue uses the FAQ fact-1/3 upsample above before another full `Invoke-AlfaTrain7bEvalCycle.ps1`.

## After this 7B job finishes

**Do not** convert, serve, eval, or LiteLLM while Status is **STARTING** or **TRAINING**.
Launcher **Train job: OK** / `launcher finished exit=0` only means the Start script on
`orchestrator` exited -- containers stay up until you click **Stop trainer**. Full SSoT with
commands: [ALFA_7B_SERVE_ALONGSIDE_27B.md](ALFA_7B_SERVE_ALONGSIDE_27B.md) -- After
training.

**Full cycle wrapper (preferred):** from `orchestrator` (operator), one script runs Start
(continue QLoRA via `lora_model_dir`), waits for hub **FINISHED**, Stop trainer,
convert on `hub`, sequential `:8470` eval, live Yes/No, Stop serve. It does **not**
call `Start-Stop-AlfaAi.ps1`, does **not** start LiteLLM, and does **not** touch
inference shards. GUI Start/Stop trainer still works for a train-only job.

```powershell
cd C:/Users/operator\alfa-ai
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Invoke-AlfaTrain7bEvalCycle.ps1
```

Train already running (lock present): omit a second Start; the cycle waits for
**FINISHED** then continues. Checkpoint already on hub / GGUF already converted:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Invoke-AlfaTrain7bEvalCycle.ps1 -EvalOnly
```

Convert on `hub` uses `sudo env ... bash deploy/cluster-members/hub/convert-7b-qlora-to-gguf.sh` from repo root (hub file is often `644`; do not `sudo` the path directly). If convert SSH hits `sudo: a password is required`, add the script to operator `sudo_commands_nopasswd` ([POOL_SWITCH_OPERATOR.md](../POOL_SWITCH_OPERATOR.md)), or paste convert on `hub`, then `-EvalOnly` / `-SkipTrain -SkipConvert`. `-SkipTrain` alone still SSHes convert.
Click-by-click table below is the same order the wrapper uses.

| Step | Wait until this is true | Then you do this |
|------|-------------------------|------------------|
| 0 | GUI Status **FINISHED** (hub rank-0 log has `Training completed!` or `Model successfully saved`). Not green footer alone. | Nothing yet. TensorBoard may stay open. |
| 1 | Step 0 done | **Stop trainer** (`Stop-AlfaTrain7bQlora.ps1` or GUI). Clears `alfa-train.lock`. Do **not** stop inference core. Leave TensorBoard. |
| 2 | Lock gone; checkpoint on hub `training/alfa-train/checkpoints/pool-7b-qlora-v2` | **From `hub` (operator):** convert adapter to `pool-7b-qlora-v2.gguf` (`convert-7b-qlora-to-gguf.sh` with `ADAPTER_ID=pool-7b-qlora-v2`). Hub only -- [convert_lora_to_gguf.py](https://github.com/ggml-org/llama.cpp/blob/master/convert_lora_to_gguf.py). |
| 3 | Convert finished | **From `gaming-c`:** `git pull --ff-only origin main` only if `C:\alfa-ai-worker` is a git clone. SMB staged copies have no `.git`; the cycle skips pull. |
| 4 | `gaming-c` GPU free (no train container) | **From `orchestrator`:** `Start-Alfa7bServe.ps1 -NoLora` then generate **base** answers only. |
| 5 | Base JSONL written | **From `orchestrator`:** `Stop-Alfa7bServe.ps1`. |
| 6 | Serve down | **From `orchestrator`:** `Start-Alfa7bServe.ps1 -LoraGguf pool-7b-qlora-v2.gguf` then generate **checkpoint** answers. |
| 7 | Both JSONLs exist | Run `train_checkpoint_gate.py` (smoke log only; `promote_allowed` is not LiteLLM). |
| 8 | Adapter still on `:8470` | Ask the **three frozen Yes/No** FAQ prompts in chat. All three must match. |
| 9 | Live Yes/No done (pass or fail) | **From `orchestrator`:** `Stop-Alfa7bServe.ps1`. If any Yes/No was wrong: continue-train FAQ later -- do not LiteLLM. |
| 10 | Step 8 passed **and** you asked for the alias | Only then wire `LLAMACPP_7B_URL` / `alfa-coder-draft` on `hub`. |

Do **not** treat `Start-Alfa7bServe` as part of Train Start. 7B adapters are **not**
inference coordinator `--lora`. After the lock is clear, Pool72/Pool80 and gaming opt-ins
are unrestricted again. **Start cluster** from **ALFa Models** only if 27B was stopped.

## Lock file format

`deploy/llamacpp-rpc/alfa-train.lock` (ASCII):

```text
STARTED_UTC=2026-08-20T16:00:00.0000000Z
MODE=7b-qlora-docker
NNODES=2
INCLUDE_219=0
SINGLE_HOST_59=0
LOGDIR=/mnt/cluster/training/alfa-train/logs/pool-7b-20260820T160000Z
BASE_MODEL=Qwen/Qwen2.5-Coder-7B-Instruct
```

`SINGLE_HOST_59=1` with `NNODES=1` is the `gaming-c`-only python launcher. 2-node DDP writes
`NNODES=2` and `SINGLE_HOST_59=0`. Orchestrator still blocks Pool72/Pool80 and opt-in
`gaming-c`/`gaming-b` while any train lock exists.
