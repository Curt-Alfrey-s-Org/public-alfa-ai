# Qwen3.8-Flash-Next Q8_0 — fit analysis (do not load)

**Decision (2026-10-03):** **CANNOT FIT** on this cluster at **Q8_0**. Do **not** seed,
hub-pull, or add a Web UI / pool switch that would load Flash-Next beside production
**Qwen3.8-27B Q8_0**. **27B Q8 remains the production inference model.** A consumer-facing
switch is deferred until a **later hardware change** makes Flash-Next Q8 **resident**
(weights + KV + runtime headroom). Same-slot **27B** file bumps (e.g. 3.6 → 3.8) stay
[inference_MODEL_UPGRADE.md](inference_MODEL_UPGRADE.md) — Flash-Next is **not** a inference
replacement GGUF in the 27B slot.

**Authority:** [GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md),
[STABLE_RELEASES.md](STABLE_RELEASES.md), [NODE_INVENTORY.md](NODE_INVENTORY.md).

---

## Model facts (official sources)

| Item | Value | Source |
|------|-------|--------|
| Hub GGUF | **Q8_0**, **6 shards**, **188225033248** bytes (**~175.3 GiB** on disk) | [unsloth/Qwen3.8-Flash-Next-GGUF](https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF) |
| Architecture | **`qwen4exp`** | Same model card |
| Native context | **262144** tokens | Same model card |
| Stock llama.cpp (non-prerelease) | **`v0.5.0`** minimum for this arch; RPC protocol **major 7** | [llama.cpp v0.5.0 release](https://github.com/ggml-org/llama.cpp/releases/tag/v0.5.0) |
| Fleet llama.cpp pin | **`b10355`** (RPC protocol **major 5**) | [STABLE_RELEASES.md](STABLE_RELEASES.md) — tag flip alone does not create a fitting pool |
| MTP (optional) | Requires a **fork**; **do not enable** in production | [MTP/README.md](https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/blob/main/MTP/README.md) |
| RPC `--cpu-moe` / `--override-tensor` | **Not documented** on RPC backends | [RPC README (v0.5.0)](https://github.com/ggml-org/llama.cpp/blob/v0.5.0/tools/rpc/README.md) |

---

## Cluster GPU inventory (matches GREV27 + live operator list)

| Host | GPU | Nominal VRAM | Notes |
|------|-----|--------------|--------|
| `orchestrator` | RTX 3060 | 12 GB | Core inference shard |
| `hub` | RTX 3050 | 6 GB | Core shard + CPU coordinator |
| `inference` | RTX 3060 LHR + RTX 5060 | 12 + 8 GB | Core shards; 5060 reports **8151 MiB** |
| `gaming-c` | RTX 5070 | 12 GB | inference opt-in |
| `gaming-b` | RTX 5070 | 12 GB | inference opt-in |
| `gaming-a` | RTX 5060 | 8 GB | **8151 MiB** physical |
| `secondary` | GTX 1070 | 8 GB | Opt-in; **Wi-Fi** — poor RPC link ([NODE_INVENTORY.md](NODE_INVENTORY.md)) |
| `pool-opt-in` | GTX 1660 Super | 6 GB | inference opt-in |

**Nine GPUs — physical VRAM sum:** **83.9 GiB** (two **5060** cards at **8151 MiB** each,
not full 8192 MiB). See hardware table in [NODE_INVENTORY.md](NODE_INVENTORY.md).

**Documented inference `-ts` (all five opt-in joined):** **`12,8,5,9,9,10,7,5,5`** → **70.0 GB**
nominal tensor-split budget ([GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md)). That budget
already reserves headroom for **27B Q8** + KV at **`CTX_SIZE=262144`**; it is **not** spare
capacity for a second 175 GiB model.

**CPU offload (policy):** limited to **`hub`** and **`inference`** host RAM only.

| Host | Installed RAM (documented) |
|------|---------------------------|
| `hub` | **~46 GiB** (2×24 GB DDR5 ECC) |
| `inference` | **48 GiB** |

---

## Arithmetic — why Q8_0 cannot load

### 1. Weights vs GPU budget

| Budget line | GiB (approx.) |
|-------------|----------------|
| Flash-Next Q8_0 (6-shard file set) | **175.3** |
| Nine-GPU physical VRAM | **83.9** |
| Documented max inference `-ts` (all opt-in) | **70.0** (GB nominal in GREV27 tables) |

**Gap (usable `-ts` case):** **70.0** (usable `-ts`) **+ 46** (`hub` RAM) **+ 48** (`inference` RAM) **= 164.0 GiB**, which is **~11.3 GiB short** of **175.3 GiB**, before OS, hub brain stack, ZFS ARC, and KV cache for 262k context. (`-ts` values are treated as GiB here; same order as the GREV27 tables.)

**Gap (GPU-only):** **175.3 − 83.9 ≈ 91.4 GiB** short on physical VRAM alone. Including
`secondary` on Wi-Fi does **not** close the gap (adds 8 GB nominal but unreliable RPC).

### 2. N-gram table (Q8)

The **51B-parameter n-gram table** at Q8 is about **50.5 GiB** — **larger than either**
`hub` (~46 GiB) or `inference` (48 GiB) installed RAM. It cannot live entirely on
one CPU host. **Removing** the n-gram table does **not** make the remainder fit: the remaining
weight tensors still exceed **83.9 GiB** physical VRAM. That remainder does not fit under the CPU-offload policy (`hub` + `inference` RAM only), which the usable-`-ts` sum above already shows is short. The [RPC README](https://github.com/ggml-org/llama.cpp/blob/v0.5.0/tools/rpc/README.md) does not document `--cpu-moe` or `--override-tensor` on RPC backends.

### 3. Software stack (secondary blocker)

Even after a future **`v0.5.0`** hub-wide llama.cpp rebuild (RPC major **7**), **fit** remains
the primary blocker. Fleet stays on **`b10355`** until a coordinated image rollout is planned;
see [STABLE_RELEASES.md](STABLE_RELEASES.md). **`qwen4exp`** / Flash-Next is **not** supported
on the current pin.

---

## Operator actions

| Do | Do not |
|----|--------|
| Keep production **`frontier-code`** / **`frontier`** on **Qwen3.8-27B Q8_0** | Seed or `pull` Flash-Next Q8 on `hub` or workers |
| Use [inference_MODEL_UPGRADE.md](inference_MODEL_UPGRADE.md) for the **next same-class 27B** GGUF | Add a Web UI or API switch that loads Flash-Next |
| Revisit this doc after **material VRAM/RAM** adds or a **documented** llama.cpp offload story | Enable MTP or ad-hoc `--cpu-moe` / `--override-tensor` on RPC without upstream docs |

**Web UI switch:** **not added** until hardware and stack can hold Flash-Next Q8 **resident**
(weights + KV + n-gram policy chosen explicitly). Until then, treat Flash-Next as **research /
inventory only** — documented here, **not** wired in compose, hub scripts, or frontend.
