# G-rev80 operator runbook — Qwen3-Coder-Next 80B-A3B (exclusive)

**Model:** **Qwen3-Coder-Next** (80B total / ~3B active MoE) GGUF **Q5_K_M**
(~**57 GB** weights). Official
[Qwen/Qwen3-Coder-Next-GGUF](https://huggingface.co/Qwen/Qwen3-Coder-Next-GGUF).

**Mode:** **Exclusive** on the RPC mesh — stops production **27B** and **72B**.
Same CPU coordinator **`hub:31360`**. LiteLLM aliases **`frontier-code`** +
**`frontier`** both map to the loaded coder (picker must not 404).

**Operator policy (2026-08-10):** **Q5_K_M** + **`CTX_SIZE=86016`** (shared with
Pool72). Full-mesh `-ts` ~**62 GiB**; estimated weights+KV ~**61.2 GiB**
(upper-bound) — **tight YOLO margin (~0.8 GiB)**. Watch `nvidia-smi` free on
`inference`/`gaming-a` 5060 and `pool-opt-in` 1660S after load; roll back CTX to **65536** if
any card free below ~800 MiB.

**VRAM / shards:** Reuse dense budgets via `pool80-shards.core.env` +
`pool80-shards.gaming.env` (same HOST/PORT/`ts` as Pool72). Orchestrator selects
them when `-InferenceMode Pool80`. Core-only cannot fit ~57 GB weights — require
**full mesh** opt-in: **`gaming-c` / `gaming-a` / `gaming-b` / `secondary` / `pool-opt-in`**. **`gaming-c`/`gaming-b`**
are inference opt-in when not training; required for full Pool80 mesh. Not concurrent
27B/72B/80B on the same GPU.

**Slots:** **`PARALLEL=1`**, **`CTX_SIZE=86016`**. Native train ctx is **262144**;
no YaRN required at 86016. Sampling (Qwen / Unsloth): temp **1.0**, top_p
**0.95**, top_k **40**.

**llama.cpp image:** Fleet pin **`b10355`** (includes **`qwen3next`**;
[llama.cpp releases](https://github.com/ggml-org/llama.cpp/releases)).
Hub tarball: `alfa-llamacpp-rpc-cuda128-b10355.tar.gz` (+ pascal
`alfa-llamacpp-rpc-cuda128-pascal-b10355.tar.gz` for `secondary`). Rebuild on
`hub` with `scripts/build-llamacpp-rpc-cuda128-on-hub.sh` (and pascal twin),
then **`FORCE_HUB_RPC_LOAD=1`** on the first start so warm caches reload
(Pool80 start sets this by default). Unsloth notes Feb 2026 fixes for
looping/output quality — prefer this pin over older **b8552**.

**SSoT:** [.cursor/plans/FOUR_HOST_FRONTIER_POOL.md](../.cursor/plans/FOUR_HOST_FRONTIER_POOL.md).
**Routine ops:** only `Start-Stop-AlfaAi.ps1` with **`-InferenceMode Pool80`**.
On **stop** after Pool80, pass **`-InferenceMode Pool80`**.

## Hub artifact

| Field | Value |
|-------|-------|
| HF repo | `Qwen/Qwen3-Coder-Next-GGUF` |
| Lead file | `Qwen3-Coder-Next-Q5_K_M/Qwen3-Coder-Next-Q5_K_M-00001-of-00004.gguf` |
| Hub path | `/mnt/HDDs/Alfa-AI/llama-cpp/models/` |
| Seed (`hub` only) | `sudo bash scripts/hub_hub_models.sh pull gguf` |

Workers never download from the public internet
([hub-hub-first](../.cursor/rules/hub-hub-first.mdc)).

## Bring-up

1. **Seed** on `hub`: `pull gguf` (Q5_K_M), promote to SSD/NVMe if used.
2. **RPC image** `b10355` on hub + every shard host (`FORCE_HUB_RPC_LOAD=1` once).
3. **Commit/push** repo; **pull** every clone.
4. **Stop** current pool from `orchestrator` (GUI or `Start-Stop-AlfaAi.ps1 stop` with
   matching `-InferenceMode`).
5. **Start exclusive 80B** with **all** opt-in hosts:

```powershell
cd C:/Users/operator\alfa-ai
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-Stop-AlfaAi.ps1 start -InferenceMode Pool80 -GamingMode Flags -Include59 -Include219 -Include249 -Include248 -Include100
```

6. **Verify:** coordinator `/health`; LiteLLM `frontier-code` smoke;
   `nvidia-smi` margins on every shard.

## Tear-down back to 27B

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-Stop-AlfaAi.ps1 stop -InferenceMode Pool80
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-Stop-AlfaAi.ps1 start
```

## Guards (same as inference / pool72)

- **No** piecemeal shard/coordinator restarts while the coordinator is up.
- **No** hot-join/leave — membership only via full stop + start.
- Self-test must pass (`MODEL_ALIAS=qwen3-coder-next-80b-a3b`).
- **SSD/HDD GGUF must be POSIX other-readable.** `sudo` promote used to leave
  `0640` `root:root`; coordinator then `die exit=1` without binding `:31360`.
  `promote-gguf-to-ssd.sh` and `write-grev80-pool-env.sh` now `chmod a+r` /
  `a+rX` and fail start if other-read is missing
  ([HUB_ARTIFACTS.md](HUB_ARTIFACTS.md) sudo promote).
- **`FORCE_HUB_RPC_LOAD=1` must reach `load-llamacpp-rpc-from-hub.sh`.** Nested
  `sudo` drops the env unless the coordinator/shard deploy scripts pass
  `FORCE_HUB_RPC_LOAD=` on the `sudo` line (Pool80 start sets this by default).
- **Coordinator wrapper needs `.env.rpc` inside the container.** CLI
  `--env-file` is interpolation only
  ([Compose interpolation](https://docs.docker.com/compose/how-tos/environment-variables/variable-interpolation/)).
  `docker-compose.rpc-main.grev27-pool-coordinator.yml` replaces `command`
  with `run-llama-server-coordinator.sh`, which reads `RPC_BACKENDS` from
  process env. Service `env_file: .env.rpc` injects that file into the
  container ([Compose env_file](https://docs.docker.com/reference/compose-file/services/#env_file)).
  Without it, logs are `ERROR: RPC_BACKENDS must be set in .env.rpc` and
  `:31360` never binds.

## Related scripts

| Path | Role |
|------|------|
| `scripts/hub_hub_models.sh pull gguf` | Seed Q5_K_M on hub |
| `deploy/cluster-members/hub/switch-pool-80b.sh` | `.env` + LiteLLM overlay |
| `deploy/cluster-members/hub/write-grev80-pool-env.sh` | `.env.rpc` for 80B; GGUF other-read self-heal |
| `deploy/cluster-members/_common/ensure-gguf-posix-other-read.sh` | `chmod a+r` / `a+rX` + fail-fast |
| `deploy/cluster-members/hub/deploy-grev80-pool-coordinator.sh` | Coordinator `:31360` |
| `deploy/cluster-members/hub/operator-cluster-111.sh start-pool80` | `hub` start path |
| `deploy/litellm_config.pool80.yaml` | LiteLLM exclusive overlay |
| `deploy/llamacpp-rpc/pool80-shards.*.env` | Dense-style `-ts` budgets |
