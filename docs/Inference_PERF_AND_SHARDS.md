# inference performance, shards, LAN, MTP

**SSoT for operators** who want more tok/s, more slots, or easier shard edits.
Pair with [GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md) and
[inference_BENCHMARKS.md](inference_BENCHMARKS.md).

**Official manuals:**

| Topic | URL |
|-------|-----|
| llama-server flags | https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md |
| llama-server `GET /metrics` | https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md (requires `--metrics`) |
| Prometheus scrape `authorization.credentials_file` | https://prometheus.io/docs/prometheus/latest/configuration/configuration/ |
| Grafana dashboard JSON / file provisioning | https://grafana.com/docs/grafana/latest/administration/provisioning/#dashboards |
| Multi-GPU / `--tensor-split` | https://github.com/ggml-org/llama.cpp/blob/master/docs/multi-gpu.md |
| RPC | https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md |
| Linux bonding / LACP | https://docs.kernel.org/networking/bonding.html |
| Qwen3.6 + MTP (Unsloth) | https://unsloth.ai/docs/models/qwen3.6 |
| hub NIC / iperf | [hub_NIC_SPEEDTEST.md](hub_NIC_SPEEDTEST.md) |

---

## Production defaults (2026-09-11)

| Knob | Value | Notes |
|------|-------|-------|
| `PARALLEL` | **5** | **2 interactive/user + 3 automated**; OOM rollback: `PARALLEL=4` (2+2) after lowering `UBATCH_SIZE` |
| `CTX_SIZE` | **262144** | **52428 tokens/slot** (`262144 / 5`); Qwen3.8 native max. Do not set 327680 without YaRN. |
| `BATCH_SIZE` | **8192** | `--batch-size` (logical prefill) |
| `UBATCH_SIZE` | **1024** | `--ubatch-size` (physical micro-batch; VRAM squeeze for compute) |
| `CACHE_TYPE_K/V` | **q4_0** | KV dtype (not a separate MiB size) |
| `CACHE_REUSE` | **256** | Prefix reuse; limited on hybrid recurrent layers (Qwen3.6/3.8 Gated DeltaNet) |
| Quant | **`Qwen3.8-27B-Q8_0.gguf`** (non-MTP, ~29 GB) | Production; [unsloth/Qwen3.8-27B-GGUF](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF) |
| Rollback quant | **`Qwen3.6-27B-Q8_0.gguf`** (~28.6 GB) | Hub + env `inference_MODEL_FILE` only |
| Core `-ts` | **`12,8,10,5`** | Usable GiB from nvidia-smi 2026-09-11 ([GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md)) |
| Shards | `deploy/llamacpp-rpc/inference-shards.env` | Edit lines → regenerate → full stop+start |

**Rollback to multi-slot Q4:** `inference_GGUF_PROFILE=ud-q4kxl` +
`PARALLEL=10` `CTX_SIZE=163840` (16384/slot) via env overrides on
`write-grev27-pool-env-from-shards.sh`, then full stop+start.

Source: `write-grev27-pool-env-from-shards.sh` → `.env.rpc` →
`docker-compose.rpc-main.grev27-pool-coordinator.yml`.

**VRAM squeeze (2026-09-11):** higher `--batch-size` / `--ubatch-size` spends
remaining headroom on throughput and one extra slot (`PARALLEL=5`). This assumes
**gaming-worker-a `gaming-a` joins** at the next `Start-Stop-AlfaAi.ps1 start` (answer **Y**).
Without `gaming-a`, `hub` 3050 / `inference` 5060 may OOM at `UBATCH_SIZE=1024`.
**OOM rollback order:** `UBATCH_SIZE` **1024 → 512** first, then `PARALLEL` **5 → 4**.
Do not raise `CACHE_RAM` or enable CUDA graphs (`GGML_CUDA_DISABLE_GRAPHS=1` stays).

---

## Add / remove / re-order shards (easy path)

**Gaming hosts (inference opt-in `gaming-a`/`gaming-c`/`gaming-b`/`secondary`/`pool-opt-in`):** prefer the **opt-in prompts** at
`Start-Stop-AlfaAi.ps1 start` (writes `inference-shards.active.env`). No hot-join
or hot-leave while green ([CLUSTER_START_STOP_OPERATOR.md](CLUSTER_START_STOP_OPERATOR.md)).

**Always-on / catalog edits:**

1. Edit **`deploy/llamacpp-rpc/inference-shards.core.env`** (or `.gaming.env` catalog):
   `HOST PORT VRAM_GB [MODEL_PCT]`
2. Preview:

```bash
inference_SHARDS_FILE=deploy/llamacpp-rpc/inference-shards.core.env \
  bash deploy/cluster-members/_common/validate-inference-shards.sh
```

3. On **`hub`**, regenerate `.env.rpc` (orchestrator start does this; or):

```bash
bash deploy/cluster-members/hub/write-grev27-pool-env.sh
```

4. **Full** `Start-Stop-AlfaAi.ps1 stop` then `start` from `orchestrator` -- never piecemeal
   shard restarts ([GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md) guard 4).

**A/B without 1660S:** use
`deploy/llamacpp-rpc/inference-shards.no-1660s.env` via
`inference_SHARDS_FILE=...` when regenerating (see § Drop 1660S below).

---

## Can we link-aggregate the 1 GbE hosts?

**Short answer:** You cannot LACP **`hub` / `storage` / `.157`** together — those are
**IP aliases on one physical NIC** (`enp11s0f0np0`), not three cables
([hub_NIC_SPEEDTEST.md](hub_NIC_SPEEDTEST.md)).

**What LACP actually needs** ([kernel bonding HOWTO](https://docs.kernel.org/networking/bonding.html)
mode `802.3ad`):

1. **Two or more physical NICs** on the host, each cabled.
2. A **switch that supports IEEE 802.3ad** with those ports in one LACP group.
3. Host bond configured for `802.3ad` (not just active-backup).

| Host / IPs | Reality | LAG useful? |
|------------|---------|-------------|
| `hub` + `storage` + `.157` | Same uplink NIC, multiple addresses | **No** — aliases ≠ extra bandwidth |
| `inference` `bond0` | Already **active-backup** (`eno1` + USB) at **1 GbE** | Failover only, **not** 2× throughput |
| `orchestrator` | **2× Intel X540 10GbE installed but disconnected**; 5 GbE in use | **Yes** — cable X540 to AXE300 10G / LACP switch |
| `hub` np0 | 10G NIC often negotiated **1000 Mb/s** | Fix autoneg / cable to AXE300 10G first |
| `.147` / `hypervisor` / `.228` | Proxmox / peer segments at 1 GbE-class | LAG only if **two physical links** + switch LACP |

**Best bandwidth wins for inference RPC (priority order):**

1. Get **`hub` np0 → 10 GbE** to AXE300 (`ethtool -r` / reseat — see hub doc).
2. **Cable `orchestrator` X540 10GbE** into the same 10G fabric as `hub`.
3. Upgrade **`inference`** off 1 GbE (better NIC or LACP pair into a LACP switch).
4. Only then consider LACP on dual-homed hosts.

Until the **switch path** is >1 GbE, iperf stays ~940 Mbps and RPC decode stays
network-bound.

---

## MTP — finish it? Best model for this case?

**Production stays non-MTP `UD-Q4_K_XL`.**

| Question | Answer |
|----------|--------|
| Is MTP available for Qwen3.6-27B? | Yes — `unsloth/Qwen3.6-27B-MTP-GGUF` + `--spec-type draft-mtp` ([Unsloth](https://unsloth.ai/docs/models/qwen3.6)) |
| Can we use it with `PARALLEL=10`? | **No.** Unsloth: **`-np > 1` not yet supported with MTP** |
| Our hub image | **b8552** — MTP needs newer llama.cpp (~b9180+ per compose comments) + hub rebuild |
| RPC + MTP | Untested / fragile; RPC is still PoC upstream |
| Best quant for multi-user inference? | **Non-MTP `UD-Q4_K_XL`** — fits VRAM, multi-slot, stable on b8552 |

**When MTP becomes viable:** single-slot (`PARALLEL=1`) speed experiments after
hub image bump + MTP GGUF seed on `hub` only. Do **not** enable for production
5-slot pool until Unsloth/llama.cpp support `-np > 1`.

Fetch gate already exists: `inference_GGUF_ALLOW_MTP=1` in
`deploy/llamacpp-rpc/scripts/fetch-qwen3-coder.sh`.

---

## Little wins (implemented + consumer env)

### In alfa-ai (coordinator)

- `PARALLEL=5` / `CTX_SIZE=262144` (52428/slot; 2 user + 3 auto)
- `--batch-size 8192` / `--ubatch-size 1024`
- Keep `q4_0` KV, flash-attn, `--no-mmap`, `--cache-reuse 256`
- Tensor-split usable-GiB (`12,8,10,5` core; see [GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md))

### Consumer bots (operator `.env` — not auto-applied)

| Host | Setting | Suggested |
|------|---------|-----------|
| contracts `apps` | `CONTRACT_AI_QUEUE_BATCH_SIZE` | `1` |
| contracts `apps` | `CONTRACT_AI_QUEUE_DRAIN_BATCHES` | `5` |
| market `market` | `ERROR_MONITOR_BATCH_SIZE` | `1` |
| market `market` | `ERROR_MONITOR_INTERVAL_SECONDS` | `600` |
| market `market` | `SENTIMENT_USE_BRAIN` | `false` during peak if trading |
| alfa-ai | `ALFA_AI_INCIDENT_LLM_TRIAGE` | `false` |
| rankings | keep narratives off inference | `OLLAMA_ENABLED=false` |

### Single coordinator — slot budget (no second pool)

Keep **one** `:31360` coordinator. Slots are equal and unassigned; isolate admin
by **not filling all 5** with background jobs:

| Role | Target slots (soft) | How |
|------|---------------------|-----|
| Automations (contracts / market / rankings / triage) | **≤3** | Consumer batch/interval caps above |
| Interactive chat + Ask ALFa / Analyze | **≥2 free** | Leave headroom; do not raise drain batches |
| Spare | **0–1** | Burst / cold-start |

**Not production yet:** LiteLLM [request prioritization](https://docs.litellm.ai/docs/scheduler)
is **beta** (`priority` + `/queue/chat/completions`). Prefer consumer caps until
that API is stable. Do **not** split GPUs into two 27B pools (see GREV27 bang-for-buck).

---

## Drop GTX 1660S (`pool-opt-in`) — prove ≥10% first

**Do not drop by default.** Procedure:

1. With **full 5-shard** pool healthy, from `inference`:

```bash
inference_SKIP_VERIFY=0 BENCH_MODE=both bash scripts/benchmark-inference-litellm.sh
```

Record short + long **decode tok/s** (and wall for comparison) via
`BENCH_WARMUP=1 BENCH_MODE=both bash scripts/benchmark-inference-litellm.sh` and
`nvidia-smi` free on `inference`/`orchestrator`/`hub` in
[inference_BENCHMARKS.md](inference_BENCHMARKS.md).

2. Stop stack. On `hub` after `git pull`:

```bash
inference_SHARDS_FILE=/mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/llamacpp-rpc/inference-shards.no-1660s.env \
  bash deploy/cluster-members/hub/write-grev27-pool-env.sh
```

(Or temporarily point the default file — prefer `inference_SHARDS_FILE` so revert is easy.)

3. Full start. Re-run **same** `BENCH_MODE=both` benchmark + `nvidia-smi` on remaining GPUs.

4. **Keep no-1660s only if** warm short completion tok/s improves by **≥10%** **and**
   no GPU free memory collapses toward OOM under load.

5. Revert: regenerate from `inference-shards.env`, full stop+start.

---

## Benchmark short vs long (batch-size check)

```bash
BENCH_MODE=both bash scripts/benchmark-inference-litellm.sh
```

- **short** — decode-ish (64 tokens)
- **long** — ~8k-char prompt (prefill; benefits from `-b 8192`)

Compare before/after batch change in [inference_BENCHMARKS.md](inference_BENCHMARKS.md).

---

## Live Grafana (tok/s + per-host GPU)

inference is **not** a single-host `llama-server` with four local GPUs. HTTP inference
and official Prometheus metrics live on the **CPU coordinator** (`hub:31360`).
Shard GPUs are `rpc-server` backends. Do **not** probe shard RPC ports while the
coordinator is up ([CLUSTER_START_STOP_OPERATOR.md](CLUSTER_START_STOP_OPERATOR.md)
guard 4).

**Dashboard (Grafana on `monitor`):**
http://monitor/d/inference-inference/inference-inference

| Panel group | Source | Official names |
|-------------|--------|----------------|
| Model tok/s, slots | coordinator `GET /metrics` after `--metrics` | `llamacpp:predicted_tokens_seconds`, `llamacpp:prompt_tokens_seconds`, `llamacpp:requests_processing`, `llamacpp:n_busy_slots_per_decode` ([llama-server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)) |
| GPU util / temp / power / VRAM | existing DCGM + `nvidia-gpu-exporter` scrapes | `DCGM_FI_*` on Linux shards; `nvidia_smi_*` on Windows workers |

`--metrics` is passed by
[`deploy/llamacpp-rpc/run-llama-server-coordinator.sh`](../deploy/llamacpp-rpc/run-llama-server-coordinator.sh)
(env `LLAMA_ARG_ENDPOINT_METRICS`). A **full** cluster stop then start applies it
(do not recreate the coordinator alone).

Prometheus job `llamacpp-inference-coordinator` on `monitor` scrapes
`http://hub/metrics` with `Authorization: Bearer` from
`prometheus/secrets/llamacpp_api_key` (gitignored; must match `.env.rpc`
`LLAMA_API_KEY`). Relabel maps `llamacpp:*` to `llamacpp_*` for PromQL.
Reload: `POST /-/reload` ([Prometheus management API](https://prometheus.io/docs/prometheus/latest/management_api/#reload)).
Do **not** restart Prometheus only to pick up a new credentials file (it is
re-read each scrape).

**Desktop icon on `orchestrator`:**
[`install-inference-grafana-desktop-shortcut.ps1`](../deploy/cluster-members/orchestrator/install-inference-grafana-desktop-shortcut.ps1)
(also invoked from `install-cluster-desktop-shortcut.ps1`). **ALFa Models** GUI
(`models-desktop-menu.ps1`): **inference metrics** opens the same URL.
