# ALFa AI documentation index

**PRIMARY WORKING SET (2026-08):** inference **always-on core** = `inference` / `orchestrator` / `hub`
(4 GPU shards + CPU coordinator `hub:31360`). **inference opt-in at each start:**
**`gaming-a` (gaming-worker-a) / `gaming-c` (gaming-worker-c) / `gaming-b` (gaming-worker-b) / `secondary` / `pool-opt-in`** — ports
`:31352` / `:31351` / `:31358` / `:31355` / `:31354`. Never required for core green.
Max with `gaming-a`+`secondary`+`pool-opt-in`: ~**60 GB** physical / **52 GB** `-ts`; all five:
**70 GB** `-ts`. Brain on **`hub`**; apps on **`apps`**. **Frontier = llama.cpp RPC only** (Petals retired):
`frontier` / `frontier-code` = **Qwen3.8-27B** (**`PARALLEL=5`**,
**`CTX_SIZE=262144`**). All five opt-in: **70 GB** `-ts`; `gaming-a`+`secondary`+`pool-opt-in`: **52 GB** `-ts`.
Perf: [inference_PERF_AND_SHARDS.md](inference_PERF_AND_SHARDS.md);
join: [inference_GAMING_HOST_JOIN.md](inference_GAMING_HOST_JOIN.md).
**35B MoE retired**; compat aliases remap to 27B. **Future `frontier`:** dense
**Qwen2.5-72B-Instruct Q4_K_M** exclusive via `-InferenceMode Pool72`
([GREV72_72B_OPERATOR.md](GREV72_72B_OPERATOR.md)).
Retired: Petals 70B swarm, local `inference:31358` 27B dual-GPU.
**SSoT:** [.cursor/plans/FOUR_HOST_FRONTIER_POOL.md](../.cursor/plans/FOUR_HOST_FRONTIER_POOL.md);
agent platform (skills, tools, browser UX): [.cursor/plans/AGENT_PLATFORM_GROK_ALIGNMENT.md](../.cursor/plans/AGENT_PLATFORM_GROK_ALIGNMENT.md);
conservative harness (native tools, skills disclosure, inspect compaction, MCP inspect-only): [.cursor/plans/HARNESS_CUTTING_EDGE_2026-09.md](../.cursor/plans/HARNESS_CUTTING_EDGE_2026-09.md);
learning loop / judge / sleep: [.cursor/plans/LEARNING_LOOP_JUDGE_SLEEP.md](../.cursor/plans/LEARNING_LOOP_JUDGE_SLEEP.md);
context window / Ask-AI limits: [.cursor/plans/CONTEXT_WINDOW_ASK_AI.md](../.cursor/plans/CONTEXT_WINDOW_ASK_AI.md);
routing SoT: [`deploy/litellm_config.yaml`](../deploy/litellm_config.yaml).

Historical migration runbooks live under [`history/`](history/) — not for day-to-day ops.

---

## Start here

| Doc | Purpose |
|-----|---------|
| [AI_GOVERNANCE.md](AI_GOVERNANCE.md) | **NIST AI RMF + Google SRE** binding oversight (tier 1b) |
| [standards/README.md](standards/README.md) | Downloaded NIST PDFs + Google SRE autonomy extract |
| [AI_AUTONOMY_AND_OVERSIGHT.md](AI_AUTONOMY_AND_OVERSIGHT.md) | Per-surface L0–L4 matrix |
| [GROK_BOT_SCRIPT_LOOP.md](GROK_BOT_SCRIPT_LOOP.md) | Grok Bot names scripts; Ask ALFa Approve; Reviewer audits truncated logs |
| [SLO_AND_ERROR_BUDGET.md](SLO_AND_ERROR_BUDGET.md) | Reliability targets |
| [USERS_MANUAL.md](USERS_MANUAL.md) | In-app Users Manual (`/manual`); admin section gated to admins |
| [DOCUMENTATION_CANONICAL.md](DOCUMENTATION_CANONICAL.md) | Git branch, env SoT, prod verification |
| [MODEL_CONFIG_DRIFT_PREVENTION.md](MODEL_CONFIG_DRIFT_PREVENTION.md) | Audit tool, BUILD_HASH, silent config drift |
| [NODE_INVENTORY.md](NODE_INVENTORY.md) | Hosts, IPs, GPUs, roles |
| [CLUSTER_IDLE_POWER.md](CLUSTER_IDLE_POWER.md) | Idle watts on `hub` / `inference` / `hypervisor` (CPU HWP, disks vs SSD) |
| Victron [SOLAR_POWER_BALANCE.md](https://github.com/example/victron-ble2mqtt-integration/blob/main/docs/SOLAR_POWER_BALANCE.md) | T2 vs KU 24 V buses, two Renogy 2 kW; 10-11 Sep A3 = trailer; 15 Sep A3 = Sungold AC-in (lives in victron repo) |
| [FLEET_OS_AND_APP_UPDATES.md](FLEET_OS_AND_APP_UPDATES.md) | Non-Windows OS security updates + app image pull policy |
| [FLEET_HOST_READINESS.md](FLEET_HOST_READINESS.md) | Rolling readiness snapshot (refresh after rollout) |
| [SOURCE_OF_TRUTH_AND_SYNC.md](SOURCE_OF_TRUTH_AND_SYNC.md) | Git per-host clone; GitHub sync bus |
| [PORT_ASSIGNMENTS.md](PORT_ASSIGNMENTS.md) | Port map |
| [LAN_OPERATOR_TROUBLESHOOTING.md](LAN_OPERATOR_TROUBLESHOOTING.md) | Cross-host failures |
| [WOLF1_92_X540_BRIDGE.md](WOLF1_92_X540_BRIDGE.md) | `orchestrator` 10G bridge, MACs, Large Send Offload V2 off |
| [LAN_BANDWIDTH_UTILIZATION.md](LAN_BANDWIDTH_UTILIZATION.md) | LAN bottleneck SSoT; multi-host NIC plan |
| [CLUSTER_LAN_AUDIT.md](CLUSTER_LAN_AUDIT.md) | Per-host max I/O + iperf matrix (peak **1.83 Gbps** hub) |
| [CURSOR_TOOLS_AND_SKILLS.md](CURSOR_TOOLS_AND_SKILLS.md) | Cursor IDE + ALFa skills/tools inventory (daily ops) |
| [RULES.md](RULES.md) | Pointer to Cursor rule hierarchy |
| [community/HOMELAB_WRITEUP.md](community/HOMELAB_WRITEUP.md) | Public arch/benchmark note (Qwen3.8-27B Q8, exclusive 72B/80B, start/opt-in, QLoRA). Forum copy: [alfa-homelab](https://github.com/example/alfa-homelab/blob/main/docs/HOMELAB_WRITEUP.md) |

---

## Per-host operator guides

| Host | Doc |
|------|-----|
| `pool-opt-in` ALFA-AI (GPU embed, Track B) | [DOCKGE_100_OPERATOR.md](DOCKGE_100_OPERATOR.md) |
| `hub` brain + hub | [DOCKGE_111_OPERATOR.md](DOCKGE_111_OPERATOR.md) |
| `apps` apps + bootstrap worker | [DOCKGE_105_OPERATOR.md](DOCKGE_105_OPERATOR.md); HA + MQTT [HOMEASSISTANT_105_OPERATOR.md](HOMEASSISTANT_105_OPERATOR.md) (Energy `:8123`) |
| `orchestrator` Dockge + Ollama speed tier | [../deploy/cluster-members/orchestrator/README.md](../deploy/cluster-members/orchestrator/README.md) |
| `gaming-c` / `gaming-a` / `gaming-b` / `inference` | [../deploy/cluster-members/](../deploy/cluster-members/) `*/README.md` |
| `inference` LACP / dual-NIC | [AI148_NIC_MAX_USE.md](AI148_NIC_MAX_USE.md) |
| `hypervisor` dual-bridge | [hypervisor_NIC_MAX_USE.md](hypervisor_NIC_MAX_USE.md) |
| `hub` 10G BCM | [hub_111_10G_NIC.md](hub_111_10G_NIC.md) |
| Dockge control plane | [DOCKGE_AGENTS_WORKERS.md](DOCKGE_AGENTS_WORKERS.md) |

**Deploy entrypoints:** `deploy/cluster-members/<host>/deploy.{sh,ps1}` after `git pull`.

---

## Windows fleet hosts

| Doc | Purpose |
|-----|---------|
| [WINDOWS_WSL_DOCKER_ENGINE.md](WINDOWS_WSL_DOCKER_ENGINE.md) | WSL2 + Docker Engine (no Desktop) — `orchestrator`, `gaming-c`, `gaming-a`, `gaming-b` |
| [WINDOWS_DOCKER_WSL_DISK_AND_CACHE.md](WINDOWS_DOCKER_WSL_DISK_AND_CACHE.md) | Docker disk image, WSL cache, `C:` pressure |
| [WINDOWS_WSL_ROLLOUT_CHECKLIST.md](WINDOWS_WSL_ROLLOUT_CHECKLIST.md) | Rollout checklist for WSL migration |

---

## Inference & storage

| Doc | Purpose |
|-----|---------|
| [../.cursor/plans/AGENT_PLATFORM_GROK_ALIGNMENT.md](../.cursor/plans/AGENT_PLATFORM_GROK_ALIGNMENT.md) | Skills, tools, browser UX, auditor mode, Grok alignment |
| [../.cursor/plans/HARNESS_CUTTING_EDGE_2026-09.md](../.cursor/plans/HARNESS_CUTTING_EDGE_2026-09.md) | Conservative harness: native tools opt-in, skills progressive disclosure, inspect compaction, MCP inspect-only (Priority #10) |
| [../.cursor/plans/LEARNING_LOOP_JUDGE_SLEEP.md](../.cursor/plans/LEARNING_LOOP_JUDGE_SLEEP.md) | Learning loop, judge dual-check 27B, sleep memory/QLoRA (Priority #7) |
| [research/LEARNING_LOOP_AND_JUDGE_RESEARCH.md](research/LEARNING_LOOP_AND_JUDGE_RESEARCH.md) | Research synthesis for learning loop / judge / sleep |
| [operations/SCHEDULED_AUDIT_MISSIONS.md](operations/SCHEDULED_AUDIT_MISSIONS.md) | Nightly/weekly read-only audit rotation |
| [operations/JUDGE_INSTALL_59.md](operations/JUDGE_INSTALL_59.md) | OP-LL-1 install independent judge on `gaming-c` |
| [operations/SLEEP_CURATOR_NIGHTLY.md](operations/SLEEP_CURATOR_NIGHTLY.md) | L2 Tier A night memory / preference export |
| [operations/SLEEP_TRAIN_TIER_B.md](operations/SLEEP_TRAIN_TIER_B.md) | L3/OP-LL-3 stage packs for alfa-train QLoRA |
| [operations/TRAIN_7B_QLORA_GUI.md](operations/TRAIN_7B_QLORA_GUI.md) | `orchestrator` **ALFa Trainer 7B** GUI (`train-desktop-menu.ps1`) + conditional `alfa-train.lock` |
| [operations/TRAIN_14B_QLORA_GUI.md](operations/TRAIN_14B_QLORA_GUI.md) | Stub: 14B archived (12 GB cards cannot hold it); live runbook is TRAIN_7B |
| [operations/ALFA_CODER_DRAFT_ALIAS.md](operations/ALFA_CODER_DRAFT_ALIAS.md) | PR-LL-08 draft LiteLLM alias (stub until promote) |
| [operations/ALFA_7B_27B_WORK_JUDGE.md](operations/ALFA_7B_27B_WORK_JUDGE.md) | 7B work + 27B judge/guide; L3 sandbox auto-write gated by sim dump plugs (Path B) |
| [operations/LEARNING_LOOP_OPERATOR_CHECKLIST.md](operations/LEARNING_LOOP_OPERATOR_CHECKLIST.md) | Deploy + live ops checklist for Priority #7 |
| [../.cursor/plans/CONTEXT_WINDOW_ASK_AI.md](../.cursor/plans/CONTEXT_WINDOW_ASK_AI.md) | Ask-AI prompt vs inference n_ctx (3072); contracts-bot trim + optional CTX_SIZE |
| [AGENT_RESEARCH_TOOLS.md](AGENT_RESEARCH_TOOLS.md) | v1 research tools (grep, fetch, 27B routing) |
| [EVALUATION_FRAMEWORK.md](EVALUATION_FRAMEWORK.md) | Role eval suites and quality gates (M5 / L0 smoke) |
| [DISTRIBUTED_AI.md](DISTRIBUTED_AI.md) | LiteLLM tiers, RPC topology |
| [QWEN3_MIGRATION.md](QWEN3_MIGRATION.md) | Current model/tier matrix |
| [CLUSTER_SHARED_STORAGE.md](CLUSTER_SHARED_STORAGE.md) | NFS/SMB hub, wheels, HF models |
| [LLAMACPP_RPC_OPERATOR.md](LLAMACPP_RPC_OPERATOR.md) | Tier 3b RPC |
| [GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md) | 27B inference topology and runbook |
| [inference_MODEL_UPGRADE.md](inference_MODEL_UPGRADE.md) | Checklist to bump inference GGUF (3.6→3.8 worked example; next upgrade) |
| [inference_PERF_AND_SHARDS.md](inference_PERF_AND_SHARDS.md) | PARALLEL/CTX, batch, LAG, MTP, shard A/B, live Grafana tok/s + GPU |
| [CLUSTER_START_STOP_OPERATOR.md](CLUSTER_START_STOP_OPERATOR.md) | Single start/stop from `orchestrator`; **ALFa Models** GUI (`models-desktop-menu.ps1`) |
| [inference_GAMING_HOST_JOIN.md](inference_GAMING_HOST_JOIN.md) | inference opt-in join checklist (`gaming-a`/`gaming-c`/`gaming-b`/`secondary`/`pool-opt-in`) |
| [inference_RPC_RELIABILITY.md](inference_RPC_RELIABILITY.md) | RPC wedges, stagger startup, split-brain |
| [OLLAMA_INSTALL_GOTCHAS.md](OLLAMA_INSTALL_GOTCHAS.md) | CPU MoE / GPU grab prevention |
| [GPU_OC_LACT_OPERATOR.md](GPU_OC_LACT_OPERATOR.md) | LACT GPU OC/power on `inference` / `pool-opt-in` (TCP **12853**, not HTTP) |

---

## Apps host data plane

| Doc | Purpose |
|-----|---------|
| [DOT105_SHARED_DATA_PLANE.md](DOT105_SHARED_DATA_PLANE.md) | Postgres/Redis on `apps` vs per-bot DBs |

---

## Auth & public surface

| Doc | Purpose |
|-----|---------|
| [AUTH_ACCOUNT_LIFECYCLE.md](AUTH_ACCOUNT_LIFECYCLE.md) | Register -> email verify -> admin approval; guest 3-message limit |
| [PUBLIC_SURFACE_SECURITY_ROADMAP.md](PUBLIC_SURFACE_SECURITY_ROADMAP.md) | Public error strings, enumeration tradeoffs |

---

## Backup & disaster recovery

| Doc | Purpose |
|-----|---------|
| [operations/POSTGRES_BACKUP_RESTORE_111.md](operations/POSTGRES_BACKUP_RESTORE_111.md) | Brain Postgres nightly pg_dump sidecar, restore runbook, restore drill, Redis no-backup decision |

---

## Observability & incidents

| Doc | Purpose |
|-----|---------|
| [INCIDENT_RESPONSE.md](INCIDENT_RESPONSE.md) | Alertmanager → alfa-ai flow, playbooks, env vars |
| [HOME_ASSISTANT_BRAIN_INTEGRATION.md](HOME_ASSISTANT_BRAIN_INTEGRATION.md) | Solar dump load / HA load control from brain API (allowlist, ticker, Ask ALFa `ha_*`) |
| [HOMEASSISTANT_105_OPERATOR.md](HOMEASSISTANT_105_OPERATOR.md) | HA Container + MQTT on `apps`; canonical Energy dashboard |
| [MONITORING_AI_REVIEW.md](MONITORING_AI_REVIEW.md) | Monitoring admin tab, AI review, Phase 0 webhook wiring |
| [../.cursor/plans/ALERT_INCIDENT_RESPONSE.md](../.cursor/plans/ALERT_INCIDENT_RESPONSE.md) | Full phased plan (Phase 0 wired 2026-07-07) |
| [monitoring/ALERTMANAGER_ALFA_AI_WEBHOOK.example.yaml](monitoring/ALERTMANAGER_ALFA_AI_WEBHOOK.example.yaml) | Alertmanager receiver template (`credentials_file`) |

---

## Archive (read-only)

| Doc | Purpose |
|-----|---------|
| [history/BRAIN_MIGRATION_105_TO_111.md](history/BRAIN_MIGRATION_105_TO_111.md) | Completed brain migration audit trail |
| [history/APR_2026_HW_SWAP_RUNBOOK.md](history/APR_2026_HW_SWAP_RUNBOOK.md) | April 2026 GPU swap runbook |
| [history/](history/) | Pre-Qwen3 Petals/Ollama archives |
