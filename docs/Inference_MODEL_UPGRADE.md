# inference production model upgrade checklist

Reusable runbook for swapping the **inference** production GGUF (same ~27B class,
same RPC mesh) while keeping LiteLLM aliases and consumer apps stable.

**Worked example:** Qwen3.6-27B Q8_0 → **Qwen3.8-27B Q8_0** (2026-08, commit
`cdd637e` and follow-ups). Use this doc the next time the production default
moves again (e.g. 3.8 → a later 27B Q8).

**Authority:** [GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md),
[HUB_ARTIFACTS.md](HUB_ARTIFACTS.md),
[MODEL_CONFIG_DRIFT_PREVENTION.md](MODEL_CONFIG_DRIFT_PREVENTION.md),
[CLUSTER_START_STOP_OPERATOR.md](CLUSTER_START_STOP_OPERATOR.md),
[hub-hub-first](../.cursor/rules/hub-hub-first.mdc),
[cluster-sync-order](../.cursor/rules/cluster-sync-order.mdc).

**Not this doc:** exclusive Pool72 / Pool80 (different GGUF class and
`-InferenceMode`). Those stay [GREV72_72B_OPERATOR.md](GREV72_72B_OPERATOR.md) /
[GREV80_80B_OPERATOR.md](GREV80_80B_OPERATOR.md).

---

## Hard invariants (do not break)

| Rule | Why |
|------|-----|
| Keep llama.cpp / LiteLLM **served id** `qwen3.6-27b` (`MODEL_ALIAS`, `openai/qwen3.6-27b`) | Renaming causes LiteLLM/client **404**. Display names change via `ALFA_inference_FAMILY`, not the served id. |
| Keep LiteLLM aliases `frontier-code` and **`frontier`** pointing at that backend | Ask ALFa and some clients send `model=frontier`; missing alias → HTTP 400. |
| Seed GGUF on **`hub` only** (>100 MB) | [HUB_ARTIFACTS.md](HUB_ARTIFACTS.md); workers never download from HF. |
| Keep prior production GGUF on the hub | Env rollback without re-download. |
| Do **not** invent a new GUI `InferenceMode` radio for a same-slot 27B bump | Normal **inference** start loads the new default; test radios were retired after 3.8. |
| Full orchestrator **stop → start** after the GGUF default flips | Piecemeal shard/coordinator redeploy is forbidden. |
| After brain image/label changes: `GET /api/health` `build_hash` must **not** stay `local` | Compose must `up` the same `BUILD_HASH` tag that was built ([MODEL_CONFIG_DRIFT_PREVENTION.md](MODEL_CONFIG_DRIFT_PREVENTION.md)). |

---

## Phase 0 -- Research and fit (before any code)

1. Confirm official model card + GGUF source (Unsloth / vendor HF).
2. Confirm size fits current `TENSOR_SPLIT` + `PARALLEL` / `CTX_SIZE` (see
   [GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md) VRAM tables). Prefer **Q8_0**
   for dense 27B; do not jump to FP16 for quality (near-zero gain vs Q8).
3. Decide **display family** key for `ALFA_inference_FAMILY` (e.g. `qwen38`) and
   rollback key for the previous file (e.g. `qwen36`).
4. Update **docs first** (this checklist + GREV27 + HUB_ARTIFACTS + ROADMAP /
   INDEX banners) describing the **intended** end state.

---

## Phase 1 -- Hub artifact (`hub` only)

| Step | Action |
|------|--------|
| 1 | Set hub defaults in `scripts/hub_hub_models.sh` (`GGUF27_REPO`, `GGUF27_FILE`, `GGUF27_INCLUDE`). |
| 2 | Align seed helpers: `deploy/llamacpp-rpc/scripts/fetch-qwen3-coder.sh` (`code-q8` profile), `reseed-grev27-gguf.sh`, `verify-grev27-gguf.sh`. |
| 3 | Align fan-out: `scripts/hub-artifact-fanout-pull.sh`, Windows
   `sync-frontier-code-gguf-from-hub.ps1`. |
| 4 | **From `hub` (operator):** pull once, e.g.
   `sudo inference_GGUF_PROFILE=q8 bash scripts/hub_hub_models.sh pull gguf27`
   (exact flags per [HUB_ARTIFACTS.md](HUB_ARTIFACTS.md)). |
| 5 | Verify file under `/mnt/HDDs/Alfa-AI/llama-cpp/models/` (and SSD promote path
   used by `promote-gguf-to-ssd.sh`). |
| 6 | Leave the **previous** production GGUF on disk for rollback. |

---

## Phase 2 -- Defaults that load the GGUF

Update every place that defaults `inference_MODEL_FILE` / model path to the **new**
filename (keep override via env for rollback):

| Area | Paths (3.8 flip examples) |
|------|---------------------------|
| Write env | `deploy/cluster-members/hub/write-grev27-pool-env.sh`, `_common/write-grev27-pool-env-from-shards.sh` |
| Promote / start | `promote-gguf-to-ssd.sh`, `operator-cluster-111.sh` `start-pool` (pass default `inference_MODEL_FILE` into `switch-pool-27b.sh` and promote) |
| Coordinator compose / run | `deploy/llamacpp-rpc/docker-compose.rpc-main.grev27-pool-coordinator.yml`, `run-llama-server-coordinator.sh`, related `code27-cpu` compose if it embeds the filename |
| Deploy helpers | `deploy-grev27-pool-coordinator.sh` defaults |

`switch-pool-27b.sh` must set `ALFA_inference_FAMILY` from `inference_MODEL_FILE`
(substring match on the **previous** family for rollback; else new family).

---

## Phase 3 -- Brain labels, LiteLLM, compose env

| Area | What to change |
|------|----------------|
| Picker labels | `src/api/llm_config.py`: `_CHAT_MODEL_LABELS` default phrase + `_inference_FAMILY_DISPLAY` allowlist; `inference_family_display()` default |
| Tests | `tests/test_llm_config.py` for new default + rollback swap |
| Marketing / static tiers | `frontend/src/content/modelHosts.tsx` (baked into API image) |
| Compose | `deploy/docker-compose.yml`: `ALFA_inference_FAMILY=${ALFA_inference_FAMILY:-<new>}` |
| Env template | `deploy/env.example` comments + default |
| LiteLLM overlay | `deploy/litellm_config.inference.yaml`: ensure **`frontier`** and `frontier-code` both map to `openai/qwen3.6-27b` (served id unchanged) |
| Policy rules / plans | `.cursor/rules/llama-cpp-rpc-only.mdc`, `.cursor/plans/FOUR_HOST_FRONTIER_POOL.md` |

**Do not** change consumer-bot env aliases (`frontier-code` stays). Consumers
follow alfa-ai over HTTP only.

---

## Phase 4 -- Operator UX copy

| Surface | Paths |
|---------|-------|
| Desktop cluster GUI | `models-desktop-menu.ps1` (inference label / hint text) |
| Orchestrator | `Invoke-AlfaAiCluster.ps1`, `Start-Stop-AlfaAi.ps1` help text |
| Operator docs | `CLUSTER_START_STOP_OPERATOR.md`, `GREV27_27B_OPERATOR.md`, `INDEX.md`, `ROADMAP.md`, `LLAMACPP_RPC_OPERATOR.md`, `inference_*`, experimental research if it names the GGUF |

Retire any temporary **test** InferenceMode (the 3.8 flip retired `inference_38`)
once production default is the new GGUF.

---

## Phase 5 -- Docs inventory (same commit as code)

Minimum doc set for a same-class 27B bump:

- [ ] This checklist (note the new → next rollback pair)
- [ ] [GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md) production GGUF + rollback
- [ ] [HUB_ARTIFACTS.md](HUB_ARTIFACTS.md) active vs rollback rows
- [ ] [CLUSTER_START_STOP_OPERATOR.md](CLUSTER_START_STOP_OPERATOR.md) inference hint
- [ ] [INDEX.md](INDEX.md) / [ROADMAP.md](ROADMAP.md) banners
- [ ] [MODEL_CONFIG_DRIFT_PREVENTION.md](MODEL_CONFIG_DRIFT_PREVENTION.md) if env keys change

---

## Phase 6 -- Git and cluster sync

1. Commit + push from the owning clone (usually `orchestrator`).
2. `git pull --ff-only origin main` on every other alfa-ai clone (`pool-opt-in`, `apps`,
   `rag`, `inference`, `secondary`, workers as needed). **Exclude nothing that will
   deploy** — `hub` must pull before start-pool.
3. Pre-commit: if `deploy/*.ps1` changed, run
   `Test-AlfaPowerShellScriptSyntax.ps1 -Recurse deploy`.

---

## Phase 7 -- Cutover (operator)

1. **From `orchestrator`:** open log tails, then
   `Start-Stop-AlfaAi.ps1 stop` → `start` with **inference** (not a one-off test
   mode). Opt-in hosts as usual.
2. Confirm start log promotes the **new** filename and
   `switch-pool-27b` updates `ALFA_inference_FAMILY`.
3. Self-test / keep-warm may still report `model=qwen3.6-27b` — that is the
   **served id**, not the GGUF family.
4. Web picker: `GET http://hub/api/health` must show a 64-char
   `build_hash` (not `local`). If labels stay on the old family, run
   `bash scripts/brain_redeploy_api.sh` on `hub` (brain only; does not restart
   shards). Hard-refresh the browser.
5. After API recreate: `brain_redeploy_api.sh` (and the next cluster start from
   `orchestrator`) refresh the Prometheus bearer on `monitor`
   (`scripts/refresh-alfa-ai-prometheus-bearer.sh`; no Prometheus restart).
6. Smoke: **New chat** + Instruct; expect long first TTFT on full mesh (~minutes),
   not Cursor-like follow-ups on long threads.

---

## Rollback (hub GGUF already present)

1. On `hub` brain `deploy/.env` (or via env for start):
   `inference_MODEL_FILE=<previous>.gguf` and matching `ALFA_inference_FAMILY`.
2. Full **stop → start** inference from `orchestrator`.
3. Recreate brain if picker labels must flip
   (`brain_redeploy_api.sh` or next start-brain with correct `BUILD_HASH`).

---

## Lessons from 3.6 → 3.8 (do not regress)

| Lesson | Detail |
|--------|--------|
| Served id ≠ display name | File became `Qwen3.8-…`; LiteLLM id stayed `qwen3.6-27b`. |
| Missing `frontier` alias | Broke Ask ALFa with 400 until added to `litellm_config.inference.yaml`. |
| Stale SPA | `start-brain` built a hashed image then `compose up` without `BUILD_HASH` → `alfa-ai-app:local` kept "Qwen3.6" labels. Fixed in `scripts/_alfa_compose_env.sh`; verify with `/api/health`. |
| Empty `inference_MODEL_FILE` into `switch-pool-27b` | Could leave family on old value; `operator-cluster-111.sh` must pass the production default filename. |
| Long-thread "unavailable" | Prefill + 600 s brain timeout; not a failed model load. Use New chat for smokes. |
| Q8 vs FP16 | Quantization was not the quality gap vs 72B Q4; stay on Q8 for 27B. |

---

## File checklist (copy for the next bump)

Mark each path when the default filename / family string is updated:

```
docs/inference_MODEL_UPGRADE.md          (this file -- record new/old pair)
docs/GREV27_27B_OPERATOR.md
docs/HUB_ARTIFACTS.md
docs/CLUSTER_START_STOP_OPERATOR.md
docs/INDEX.md
docs/ROADMAP.md
docs/LLAMACPP_RPC_OPERATOR.md
docs/inference_PERF_AND_SHARDS.md
docs/inference_BENCHMARKS.md
docs/experimental/UI_DRIVEN_GPU_MODEL_RESEARCH.md
.cursor/rules/llama-cpp-rpc-only.mdc
.cursor/plans/FOUR_HOST_FRONTIER_POOL.md
scripts/hub_hub_models.sh
scripts/hub-artifact-fanout-pull.sh
deploy/llamacpp-rpc/scripts/fetch-qwen3-coder.sh
deploy/cluster-members/hub/write-grev27-pool-env.sh
deploy/cluster-members/hub/promote-gguf-to-ssd.sh
deploy/cluster-members/hub/operator-cluster-111.sh
deploy/cluster-members/hub/switch-pool-27b.sh
deploy/cluster-members/hub/reseed-grev27-gguf.sh
deploy/cluster-members/hub/verify-grev27-gguf.sh
deploy/cluster-members/hub/deploy-grev27-pool-coordinator.sh
deploy/cluster-members/_common/write-grev27-pool-env-from-shards.sh
deploy/cluster-members/orchestrator/sync-frontier-code-gguf-from-hub.ps1
deploy/cluster-members/orchestrator/models-desktop-menu.ps1
deploy/cluster-members/orchestrator/Invoke-AlfaAiCluster.ps1
deploy/cluster-members/orchestrator/Start-Stop-AlfaAi.ps1
deploy/llamacpp-rpc/docker-compose.rpc-main.grev27-pool-coordinator.yml
deploy/llamacpp-rpc/docker-compose.rpc-main.code27-cpu.yml
deploy/llamacpp-rpc/run-llama-server-coordinator.sh
deploy/litellm_config.inference.yaml
deploy/docker-compose.yml
deploy/env.example
src/api/llm_config.py
tests/test_llm_config.py
frontend/src/content/modelHosts.tsx
```

---

## Related

- [GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md) -- day-to-day inference ops
- [MODEL_CONFIG_DRIFT_PREVENTION.md](MODEL_CONFIG_DRIFT_PREVENTION.md) -- brain rebuild / BUILD_HASH
- [CLUSTER_START_STOP_OPERATOR.md](CLUSTER_START_STOP_OPERATOR.md) -- stop/start only via orchestrator
