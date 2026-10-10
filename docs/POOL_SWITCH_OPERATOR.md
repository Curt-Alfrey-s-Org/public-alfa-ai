# Pool switch operator (27B inference <-> 35B pool35)

Admin-triggered swap of the shared llama.cpp CPU coordinator on `hub` `:31360` between
**inference** (G-rev27 27B) and **pool35** (G-rev35 35B MoE). Same four GPU `rpc-server`
shards; only one coordinator may run at a time.

**Not a replacement** for full cluster start/stop ([CLUSTER_START_STOP_OPERATOR.md](CLUSTER_START_STOP_OPERATOR.md)).
Use this only when shards are already healthy and you want to swap models from the chat picker.

---

## Components

| Piece | Host | Role |
|-------|------|------|
| `pool-switchd` | `hub` host as `operator` | Privileged executor; runs allowlisted deploy scripts with `sudo` |
| `alfa-ai-api` | `hub` container | Step-up auth, audit, Redis status, calls switchd over loopback |
| Chat picker UI | Browser (admin) | Password + optional TOTP, phased progress bar |

Official llama.cpp `/health` reports `"loading model"` vs `"ok"` only (no byte-accurate %).
The UI shows **estimated** load progress during the `loading_model` phase
([llama.cpp server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)).

---

## Ports and network

| Service | Bind | Env |
|---------|------|-----|
| `pool-switchd` HTTP | `127.0.0.1:8421` | `ALFA_POOL_SWITCHD_HOST_PORT` (default **8421**) |
| Brain API -> switchd | `http://host.docker.internal:8421` | `ALFA_POOL_SWITCHD_URL` in `deploy/.env` |

`pool-switchd` must **never** bind `0.0.0.0`. The API container reaches the host via
`extra_hosts: host.docker.internal:host-gateway` (see `deploy/docker-compose.yml`).

---

## Secrets (`deploy/.env` -- never commit)

| Variable | Purpose |
|----------|---------|
| `ALFA_POOL_SWITCH_BEARER_TOKEN` | Shared secret: API -> switchd `Authorization: Bearer` |
| `REDIS_URL` | Status key (API reads; switchd writes via `docker exec alfa-redis redis-cli`) |

Generate token once on `hub`:

```bash
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
```

Add to `deploy/.env`, then recreate `alfa-ai-api` so the container sees it.

---

## Redis status schema

Key: `alfaai:pool_switch:status` (TTL 3600 s while switching; cleared or set to idle on completion).

```json
{
  "switching": true,
  "target_pool": "pool35",
  "from_pool": "inference",
  "phase": "loading_model",
  "phases": [
    {"id": "stopping_current", "label": "Stopping current model", "done": true},
    {"id": "verifying_shards", "label": "Verifying GPU shards", "done": true},
    {"id": "switching_env", "label": "Updating configuration", "done": true},
    {"id": "starting_coordinator", "label": "Starting coordinator", "done": true},
    {"id": "loading_model", "label": "Loading model weights", "done": false},
    {"id": "recreating_litellm", "label": "Restarting inference proxy", "done": false},
    {"id": "ready", "label": "Ready", "done": false}
  ],
  "elapsed_sec": 142,
  "estimated_pct": 68,
  "estimated_label": true,
  "cold_start_estimate_sec": 210,
  "error": null,
  "requested_by_user_id": "uuid",
  "started_at": "2026-07-04T12:00:00+00:00",
  "updated_at": "2026-07-04T12:02:22+00:00"
}
```

Cold-start estimates (seconds, for UI bar only):

| Pool | Estimate | Doc source |
|------|----------|------------|
| inference | 210 | [GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md) (~3-4 min) |
| pool35 | 240 | [GREV35_35B_OPERATOR.md](GREV35_35B_OPERATOR.md) (placeholder until benchmarked) |

`estimated_pct` during `loading_model` = `min(95, round(100 * elapsed / cold_start_estimate))`.
Phase `ready` sets `estimated_pct` to 100.

---

## API endpoints (admin network + admin JWT)

| Method | Path | Body | Response |
|--------|------|------|----------|
| GET | `/alfa-ai/api/admin/pool/status` | -- | Status JSON (idle when not switching) |
| POST | `/alfa-ai/api/admin/pool/switch` | `{target, password, totp_code?}` | `202` accepted |

Step-up: re-verify admin **app password** (+ TOTP if enabled). Never send hub `operator` password.

Audit events: `pool_switch_requested`, `pool_switch_stepup_failed`, `pool_switch_completed`, `pool_switch_failed`.

---

## switchd lifecycle (hub)

1. One-time: scope `sudo_commands_nopasswd` for `operator` (see below).
2. Install Init/Shutdown script (Post Init):

```bash
bash /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/cluster-members/hub/install-pool-switchd-init.sh
```

3. Verify:

```bash
curl -fsS -H "Authorization: Bearer $ALFA_POOL_SWITCH_BEARER_TOKEN" http://127.0.0.1:8421/health
```

---

## `sudo_commands_nopasswd` scope (hub official)

Configure via hub CLI ([account user update](https://www.hub.com/docs/scale/23.10/scaleclireference/printview/))
for user `operator`. **Absolute paths only** - relative `deploy/...` paths fail sudo allowlist
matching and break non-interactive SSH from the `orchestrator` orchestrator.

**Single shared allowlist** for `pool-switchd`, the `orchestrator` orchestrator
(`Invoke-AlfaAiCluster.ps1` / `Start-Stop-AlfaAi.ps1`), and manual
`operator-cluster-111.sh` paste blocks. Do not maintain a second list elsewhere.

```
/mnt/HDDs/Alfa-AI/repo/alfa-ai/scripts/stop.sh
/mnt/HDDs/Alfa-AI/repo/alfa-ai/scripts/start.sh
/mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/cluster-members/hub/switch-pool-27b.sh
/mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/cluster-members/hub/switch-pool-35b.sh
/mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/cluster-members/hub/deploy-grev27-pool-coordinator.sh
/mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/cluster-members/hub/deploy-grev27-pool-shard.sh
/mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/cluster-members/hub/deploy-grev35-coordinator.sh
/mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/cluster-members/hub/write-grev27-pool-env.sh
/mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/cluster-members/hub/write-grev35-env.sh
/mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/cluster-members/hub/install-inference-keep-warm-cron.sh
/mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/cluster-members/_common/inference-stop-local.sh
/mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/cluster-members/_common/stop-rag-sidecars.sh
/mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/cluster-members/_common/start-inference-log-session.sh
/mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/cluster-members/_common/stop-inference-log-session.sh
/mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/cluster-members/_common/preflight-docker-engine.sh
/mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/cluster-members/_common/load-llamacpp-rpc-from-hub.sh
/mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/cluster-members/hub/convert-7b-qlora-to-gguf.sh
/usr/bin/docker
/usr/bin/systemctl
```

`convert-7b-qlora-to-gguf.sh` is **not** a pool-switch step. It is on the same
operator nopasswd list so `orchestrator` `Invoke-AlfaTrain7bEvalCycle.ps1` can SSH
`sudo env CHECKPOINT_DIR=... ADAPTER_ID=... FORCE_LORA_CONVERT=1 bash deploy/cluster-members/hub/convert-7b-qlora-to-gguf.sh`
(run from repo root; hub checkout may be non-executable `644` so do not `sudo` the path directly)
without a password prompt ([user.update `sudo_commands_nopasswd`](https://www.hub.com/docs/scale/23.10/scaleclireference/account/cliuser/),
absolute executable paths). Until hub has that path, the cycle prints the
`hub` paste and exits. Do not add `ALL`.

Scripts invoke `sudo docker` / `sudo bash` internally; listing `/usr/bin/docker` covers compose
recreate steps in `pool-switchd` and `scripts/start.sh` / `scripts/stop.sh`. If hub rejects a
path, use the documented fallback: root-only `deploy/pool-switchd.env` on the **`hub` host**
(never in git, never on `orchestrator`) -- not the browser password and not a `.env` on the orchestrator.

---

## Switch sequence (switchd)

**To pool35:**

1. Stop 27B coordinator containers
2. `verify-inference-shards.sh` with `pool35-shards.env`
3. `switch-pool-35b.sh` (env + sentinel `LLAMACPP_CODE27_URL=:31399`)
4. `deploy-grev35-coordinator.sh` (+ `wait-llamacpp-coordinator-health.sh`)
5. Recreate `alfa-ai-litellm` + `alfa-ai-api`; `wait-litellm-liveliness.sh`

**To inference:** mirror with `switch-pool-27b.sh` + `deploy-grev27-pool-coordinator.sh`.

Orchestrator shortcut (manual, same scripts):

```bash
bash deploy/cluster-members/hub/operator-cluster-111.sh start-pool35
bash deploy/cluster-members/hub/operator-cluster-111.sh start-pool
```

---

## Picker behavior

- Model rows include optional `pool`: `inference` | `pool35` for switchable aliases.
- Admins see **Activate** on inactive pool rows; opens step-up modal.
- While switching, `PoolStatusBanner` polls `/admin/pool/status` every 4 s.
- On `ready`, reload `/config` so `active` flags update for all users.

---

## Universal alias coverage (mandatory -- default for every consuming repo)

**Policy:** whichever pool the operator has picked, **every** standard LiteLLM alias in the
table below must resolve to **that** pool's live model. A client repo (rankings-bot,
contracts-bot, market-pie5-bot, atems, credit-check-bot, etc.) must never see
`Invalid model name` just because the operator picked the other pool. Client repos keep
calling whatever alias fits their feature (`app-chat`, `public-chat`, `frontier-code`,
`qwen3.6-27b`, ...) -- they do **not** need pool-awareness, env-var branching, or a
`*_FALLBACK_ENABLED` escape hatch to avoid going red.

| Alias | inference (`litellm_config.inference.yaml`) | pool35 (`litellm_config.pool35.yaml`) |
|-------|----------------------------------------|----------------------------------------|
| `frontier-code`, `qwen3.6-27b` | **native** -> `LLAMACPP_CODE27_URL` (27B) | aliased -> `LLAMACPP_35B_URL` (35B) |
| `fast`, `inline`, `autocomplete`, `chat`, `public-chat`, `app-chat`, `agent`, `code`, `operator_internal`, `qwen3.6:35b-a3b` | aliased -> `LLAMACPP_CODE27_URL` (27B) | **native** -> `LLAMACPP_35B_URL` (35B) |
| `embed`, `qwen3-embedding:4b`, `rerank`, `qwen3-reranker-0.6b` | unaffected -- `inference` CPU RAG sidecars, always on | unaffected -- `inference` CPU RAG sidecars, always on |

"Aliased" rows are extra `model_list` entries added to the non-native pool's overlay file that
point at the **same** live coordinator URL the native rows in that file use -- not a
`fallbacks:` chain, since a pool-specific overlay only ever has one real backend running. This
means a client asking for `frontier-code` while pool35 is active transparently gets answered by
the 35B model (and vice versa) instead of a 400.

**What stays pool-aware:** the chat-picker UI's `active: true` flag is still driven by
`CHAT_MODELS`/`DEFAULT_MODEL`/`ALFA_INFERENCE_MODE` in `deploy/.env` (see
[GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md) / [GREV35_35B_OPERATOR.md](GREV35_35B_OPERATOR.md)),
so admins still see exactly one pool marked active. Only the LiteLLM `model_list` routing is
made universal.

**When adding a new client-facing alias:** add it to **both** `litellm_config.inference.yaml` and
`litellm_config.pool35.yaml` (native row in the pool it "belongs" to, aliased row in the other),
and to `litellm_config.yaml` (the combined dev/default file) so all three stay in sync.

---

## Related

- [GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md)
- [GREV35_35B_OPERATOR.md](GREV35_35B_OPERATOR.md)
- [CLUSTER_START_STOP_OPERATOR.md](CLUSTER_START_STOP_OPERATOR.md) -- full cluster only
- [PORT_ASSIGNMENTS.md](PORT_ASSIGNMENTS.md) -- port 8421
