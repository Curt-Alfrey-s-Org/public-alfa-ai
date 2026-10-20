# inference RPC reliability — root causes and mitigations

Operator reference for **why** the 27B pool wedges, and **what the repo enforces**
to avoid split-brain and silent TCP failures. Complements
[CLUSTER_START_STOP_OPERATOR.md](CLUSTER_START_STOP_OPERATOR.md) and
[GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md).

**Do not** paper over failures with piecemeal redeploys. After any wedge or
coordinator/shard mismatch, run **full stop → full start** from `orchestrator`.

---

## Current topology (Jul 2026)

| Role | Host | GPU / CPU | Port |
|------|------|-----------|------|
| Brain + CPU coordinator | `hub` | Ryzen 9 **7900X**, **RTX 3050 6 GB** (pool tail shard only; **5060 on `inference`**) | `:31360` coord, `:31353` shard, `:8413` LiteLLM |
| Shard (fast) | `inference` | RTX **3060** 12 GB (GPU 1) | `:31356` |
| Shard | `inference` | RTX **5060** 8 GB (GPU 0; moved from `hub`, Jul 2026) | `:31357` |
| Shard | `orchestrator` WSL | RTX **3060** 12 GB (WDDM) | `:31350` |
| Shard | VM100 (`pool-opt-in`) | GTX **1660 Super** | `:31354` |
| Shard (tail) | `hub` | RTX **3050** | `:31353` |
| RAG embed + rerank | `inference` CPU | — | `:11435` embed, `:8360` rerank |

`TENSOR_SPLIT=12,8,10,5` (core) from `deploy/llamacpp-rpc/inference-shards.env`. Opt-in
`secondary`/`pool-opt-in` add 7 and 5 (`12,8,10,7,5,5`).

**Software:** llama.cpp RPC image `alfa-llamacpp-rpc:cuda128` (hub-built on `hub`);
coordinator `CTX_SIZE=262144`, `PARALLEL=5` (52428 per slot), KV `q4_0`, `CACHE_RAM=0`
(see failure mode 6); `GGML_CUDA_DISABLE_GRAPHS=1` on every shard.

---

## Failure modes (research summary)

### 1. Silent TCP wedge (rpc-server)

**Symptom:** Container `Up`, `ss` shows LISTEN on RPC port, but remote `nc` from
`apps` fails. No OOM/CUDA error in logs.

**Cause:** Upstream `rpc-server` is experimental — single-threaded accept path,
`listen(backlog=1)`, CUDA graph warmup can wedge the accept queue
([llama.cpp #20315](https://github.com/ggml-org/llama.cpp/issues/20315)).

**Mitigations in repo:**

| Mitigation | Where |
|------------|--------|
| `GGML_CUDA_DISABLE_GRAPHS=1` on all shard compose files | `docker-compose.rpc-server.*.yml` |
| **Staggered shard startup** (do not blast all GPUs at once) | See below |
| Force-recreate via **full cluster cycle**, not lone `docker restart` | `Invoke-AlfaAiCluster.ps1` |
| TCP preflight | `verify-inference-shards.sh` |

**Gap (not automated yet):** no Docker `healthcheck` on `rpc-server` containers;
TCP verify is the stand-in.

### 2. Coordinator / shard split-brain

**Symptom:** `http://hub/health` → 200, but inference 500/timeout;
`nvidia-smi` on shards shows ~empty VRAM.

**Cause:** Coordinator loaded tensor map against **old** shard set (e.g. coordinator
on `inference` left up after shard force-recreate on `inference`/`orchestrator`).

**Mitigations in repo:**

| Rule | Implementation |
|------|----------------|
| Coordinator deploy **after** all shards TCP OK | `deploy-grev27-pool-coordinator.sh` → `verify-inference-shards.sh` first |
| **No mid-start coordinator redeploy** | Removed from `Invoke-AlfaAiCluster.ps1` |
| Coordinator on **same host as brain** (`hub`) | `operator-cluster-111.sh start-pool` |
| Stop stale `inference` coordinator on cluster stop | `inference-stop-local.sh` + stop verify |

### 3. LiteLLM 503 storm during load

**Symptom:** contracts-bot degraded; LiteLLM logs `Loading model` / 503 to coordinator.

**Mitigations:** `litellm_config.inference.yaml` disables `background_health_checks`;
`scripts/start.sh` waits coordinator `/health` up to **900s** before LiteLLM up.

### 4. LAN / dual-NIC ARP flux

**Symptom:** **All** pool RPC ports fail together from `apps` after brain start.

**Cause:** Second data NIC (`.104`/`.147`) on same `/24` as mgmt — ARP flux.

**Fix:** Policy routing + `arp_ignore=1` / `arp_announce=2` via
`setup-dual-ip-data-plane.sh` on `apps`/`inference`. See [CLUSTER_LAN_AUDIT.md](CLUSTER_LAN_AUDIT.md).

### 5. `orchestrator` WSL firewall

**Symptom:** `:31350` OK locally in WSL, FAIL from `inference` hub verify.

**Cause:** WSL mirrored mode with `firewall=true` blocks remote LAN until
Hyper-V firewall rules exist (Microsoft WSL networking docs).

**Fix:** One-time `install-wsl-lan-firewall.ps1 -Profile operator-93` as
Administrator on `orchestrator` (included in `02-install-docker-wsl-engine.ps1 -HostProfile
operator-93`). Not a per-start workaround -- rules persist until OS reset.

### 6. Server prompt cache aborts the coordinator (`--cache-ram` over RPC)

**Symptom:** Deploy succeeds, the start self-test passes, then the coordinator exits
**134** (SIGABRT) on the **first production request**. `docker inspect` reports
`oom=false`. Shards never crash — each logs a clean `Client connection closed`
*milliseconds after* the coordinator died. The coordinator log ends with:

```
slot get_availabl: id  0 | task -1 | selected slot by LCP similarity, f_sim_best = 0.273
ggml/src/ggml-rpc/ggml-rpc.cpp:519: Remote RPC server crashed or returned malformed response
recv failed (bytes_recv=0, size_to_recv=8)
  ... server_slot::prompt_save
  ... llama_context::state_seq_get_data
  ... server_context_impl::get_available_slot
```

**Cause:** `llama-server`'s **server prompt cache** is on by default — `-cram,
--cache-ram` defaults to **8192 MiB**, and `--cache-idle-slots` defaults to enabled
("save idle slots to the prompt cache on new task"), per the
[server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md).
Saving a slot calls `llama_context::state_seq_get_data()`, which reads KV tensors back
from the backend. KV owned by the **RPC** backend has no local `data` pointer, so the
read aborts the entire server:
[#26128](https://github.com/ggml-org/llama.cpp/issues/26128) (prompt cache incompatible
with RPC backend, triggered as soon as `-np > 1`) and
[#26529](https://github.com/ggml-org/llama.cpp/issues/26529) (`--cache-ram 0` is the
documented avoidance).

**Why it looks random:** deploy leaves every `PARALLEL` slot idle-but-populated — the
self-test decodes on one slot and `keep-inference-warm.sh` pings all four. Because
`--cache-idle-slots` is enabled by default, the next **new task** makes the server save
those idle slots, hitting the abort. So the coordinator reliably survives deploy and
reliably dies on the first real user turn.

Observed 2026-09-01: coordinator ran 2 h 45 m through deploy, self-test and keep-warm,
then exited 134 at the first chat request. All three readable shards logged their
session close 11-2200 ms **after** the coordinator's `FinishedAt`, confirming the
coordinator died first.

**Fix in repo:** every coordinator started with `--rpc` passes **`--cache-ram 0`**,
overridable via the `CACHE_RAM` env var (default `0`).

| Coordinator launch path | File |
|---|---|
| 27B pool (live on `hub`) | `deploy/llamacpp-rpc/run-llama-server-coordinator.sh` |
| Base RPC coordinator | `deploy/llamacpp-rpc/docker-compose.rpc-main.yml` |
| Code27 CPU | `deploy/llamacpp-rpc/docker-compose.rpc-main.code27-cpu.yml` |
| Code cache | `deploy/llamacpp-rpc/docker-compose.rpc-main.code-cache.yml` |
| 35B MoE (retired path) | `deploy/llamacpp-rpc/docker-compose.rpc-main.grev35-coordinator.yml` |
| 72B YaRN | `deploy/llamacpp-rpc/docker-compose.rpc-main.grev72-yarn.yml` |

**No latency cost here:** `--cache-ram 0` disables only the cross-slot prompt cache.
In-slot prefix reuse (`--cache-reuse`) is unaffected, and with `PARALLEL=5` and five or
fewer concurrent conversations nothing is ever evicted, so the prompt cache did no
useful work while its save path aborted the server. `--no-cache-prompt` does **not**
avoid the abort — `server_prompt_cache` is independent of it. `--slot-save-path` is a
separate manual `/slots/{id}?action=save` feature and stays.

---

## Staggered startup (mandatory order)

Orchestrator and deploy scripts enforce delays to reduce concurrent RPC load during
cold start:

```
orchestrator shard :31350
  → sleep inference_SHARD_STAGGER_SEC (default 30s)     [Invoke-AlfaAiCluster.ps1]
inference shard :31356 (3060 only)
  → sleep inference_SHARD_STAGGER_SEC (default 20s)     [deploy-grev27-pool-shard.sh]
inference shard :31357 (5060)
  → verify remote shards (--remote-only skips hub)
OPERATOR hub: 3050 shard :31353
  → sleep inference_SHARD_STAGGER_SEC (default 20s)     [operator-cluster-111.sh]
hub CPU coordinator :31360
  → verify all 4 shards + /health
RAG pool-opt-in → start-brain
```

Override: `inference_SHARD_STAGGER_SEC=45` on any host/orchestrator if wedges persist.

---

## Diagnostics

```bash
# from inference
cd ~/alfa-ai
inference_VERIFY_RETRIES=30 bash deploy/cluster-members/_common/verify-inference-shards.sh
bash scripts/diagnose-inference-ai.sh

# Verbose RPC (temporary, on shard host)
GGML_RPC_DEBUG=1  # inside rpc-server container env — upstream troubleshooting flag
```

inference error capture: STEP 0 in `Start-Stop-AlfaAi.ps1` → `logs/inference-sessions/`.

---

## Related

- [CLUSTER_START_STOP_OPERATOR.md](CLUSTER_START_STOP_OPERATOR.md) — single start/stop path
- [LLAMACPP_RPC_OPERATOR.md](LLAMACPP_RPC_OPERATOR.md) — RPC security and flags
- [PORT_ASSIGNMENTS.md](PORT_ASSIGNMENTS.md) — port map