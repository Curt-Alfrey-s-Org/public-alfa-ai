# Admin AI host actions (mutating actions approval-gated every time)

**Authority:** [.cursor/rules/admin-ai-host-actions-boundaries.mdc](../.cursor/rules/admin-ai-host-actions-boundaries.mdc)

The admin **Ask ALFa** chat widget can **propose** operational commands on cluster hosts --
either a named catalog action, or a **freeform** shell/PowerShell command via `run_command`
(same command-authoring depth as an agent working the repo directly). **Mutating** actions
(tier 2/3, including `run_command`) stay `pending` until the operator clicks **Approve** in
the widget. **Exception:** Home Assistant solar dump (`ha_switch_on` / `ha_switch_off` /
`ha_set_number` / `ha_select_option` / observe `ha_dump_tick`) runs immediately when HA
env + token are on -- no Approve (operator 2026-09-19; not under NIST).
the chat widget or the **AI Actions -> Host actions** sub-tab -- every single time, with no
"auto-approve next time." Queued follow-ups while a turn is running do **not** bypass
Approve ([CHAT_AGENT_STREAMING.md](CHAT_AGENT_STREAMING.md)). **Read-only tier-1 inspect steps** auto-run inside an Ask ALFa turn
(L1 observe) when inspect auto-run is enabled and SSH is ready; each step is shown in chat and
logged to `ai_actions` (`host_inspect_executed`). Every mutating execution is logged to
`ai_host_actions` and the unified `ai_actions` feed (`host_command_executed`). Operator
**reject** of a pending proposal is logged to `ai_actions` (`host_action_rejected`).

## Scope

- **Admin sees all alfa-ai admin data** in Ask ALFa context: health, incidents (open vs
  recent history -- see [AI_ACTIONS.md](AI_ACTIONS.md) Ask ALFa incident context), AI
  settings/actions, models summary, user count, audit log, pending host actions, Prometheus
  `firing_alerts`, and the action catalog.
- **Consumer bot business data** (ProBilliards player records, market trades, contracts, etc.) is
  **not** included -- see [chat-data-isolation.mdc](../.cursor/rules/chat-data-isolation.mdc).
- **Freeform commands are allowed** via `action_key="run_command"` + `params.command` -- the model
  writes the exact shell (Linux) or PowerShell (`orchestrator`) command text. There is no other way to run
  arbitrary text: unknown `action_key` values are rejected.
- **The operator always sees the literal command before approving** -- `summarize_proposal()`
  renders `params.command` verbatim into the proposal summary shown in the UI.
- **inference/RPC piecemeal is blocked at the text level** -- `run_command` text and Docker
  container names are scanned by `_reject_inference_piecemeal()` for `rpc-server` /
  `llamacpp-rpc` / `inference` / `coordinator`. Named catalog actions use a fixed template
  (script-verify `hub_diag_read` is an allowlisted read-only diagnose). Ask ALFa also
  rejects operator messages that look like piecemeal mutate, except a named catalog
  propose (`Propose brain_verify on host 111`).
  ([no-piecemeal-cluster-scripts.mdc](../.cursor/rules/no-piecemeal-cluster-scripts.mdc)).

## Native OpenAI tools (opt-in)

When `ALFA_AI_NATIVE_TOOLS=1`, Ask ALFa may emit OpenAI `tool_calls` for `inspect_host` and
`propose_host_action` instead of JSON-in-text tool envelopes. The same inspect autorun gates,
inference piecemeal reject, and L2 Approve for mutate actions apply — native tools do not
auto-Approve. Default remains `ALFA_AI_NATIVE_TOOLS=0`; JSON-in-text fallback stays in place.

## MCP inspect mount (opt-in, default off)

When `ALFA_AI_MCP_ENABLED=1`, the brain API mounts a **Streamable HTTP** MCP server at `/mcp`
on **LAN admin port `:8420` only**. Public edge nginx (`deploy/nginx-edge/alfa-ai-edge.conf`)
returns **404** for `/mcp`. Official mount pattern:
https://py.sdk.modelcontextprotocol.io/run/asgi/

| Control | Value |
|---------|-------|
| Env | `ALFA_AI_MCP_ENABLED=0` (default) |
| Auth | Admin JWT (`Authorization: Bearer`) + `ALFA_AI_ADMIN_ALLOWED_CIDRS` network gate (same as Ask ALFa admin API) |
| Tools | One tool: `inspect_host(action_key, host, params?)` — **inspectable catalog only** |
| Mutate | **Rejected server-side** (`run_command`, HA switches, cluster start/stop, `apply_patch`, `git_push`, and any non-inspectable key) — never executes |
| Hints | `readOnlyHint=True` on the tool is a **hint only**; `authorize_mcp_inspect()` enforces the allowlist |

Transport security uses `TransportSecuritySettings(allowed_hosts=...)` (localhost defaults plus
optional `ALFA_AI_MCP_ALLOWED_HOSTS`). Do **not** use `@mcp.custom_route` for inspect — SDK
custom routes are unauthenticated.

## Flow (operator-first: Ask -> Approve)

1. Operator asks Ask ALFa in plain language (or POST `/host-actions/propose`). Explicit catalog
   intent (`Propose docker_ps on host 111`) is deterministic; ambiguous intent uses the LLM
   `propose_host_action` tool (or `run_command` with the exact command).
2. Proposal is validated for safety (blocklist, host, params) and stored as `pending`. Soft pack
   toggles do **not** block proposing -- Ask ALFa may propose a soft-disabled action.
3. The Approve card shows: literal command/summary, **auth level** (read / ops / destructive), and
   any packs that **Approve will enable** (e.g. Freeform shell). In the Ask ALFa dock the card
   sits **above the composer** so a long reply cannot cover Approve
   ([AI_ACTIONS.md](AI_ACTIONS.md) dock layout).
4. Operator **Approve**s or **Reject**s. One Approve:
   - Enables any soft-disabled packs/actions required for that proposal
   - Runs the command via SSH (asyncssh)
5. stdout/stderr/exit code stored; summary written to `ai_actions`.
6. For script-verify catalog actions, the Approve result includes `bot_audit_excerpt`
   (exit code + last 80 log lines). Copy that into ALFa Reviewer -- do not paste the
   full 50k stdout. Loop: [GROK_BOT_SCRIPT_LOOP.md](GROK_BOT_SCRIPT_LOOP.md).

**Operator does not need to visit AI Config** for routine work. Packs are optional defaults /
lockouts for power users -- Approve is the gate.

## One-time infra (only hard prerequisites)

These cannot be flipped from the chat Approve button (require brain deploy / secrets):

1. **Env kill switch** -- `ALFA_AI_HOST_ACTIONS_ENABLED=1` in brain `deploy/.env` (redeploy API).
   Required for **all** host-action proposals, including Missions enqueue.
2. **SSH key mounted** -- `/app/secrets/host-actions/id_ed25519` (+ `known_hosts`) in the API
   container. Required only for **SSH** catalog actions. Not required for `mission_enqueue`.
   Host path on `hub`: `deploy/secrets/host-actions/` inside the repo clone
   (`ALFA_AI_HOST_ACTIONS_SECRETS_DIR`), bind-mounted as a directory, so files copied in
   appear in the running container without a redeploy. **Survives cluster start:** the root
   `.gitignore` ignores `deploy/secrets/host-actions/*` (except `.gitkeep`); this matters
   because `operator-cluster-111.sh` runs `git clean -fd` on every start, which deletes
   untracked files but keeps ignored ones ([git-clean](https://git-scm.com/docs/git-clean)).
   Before 2026-09-10 the ignore rule lived only in an uncommitted per-directory `.gitignore`
   on `orchestrator`, so every cluster start wiped the key on `hub`. **Start preflight** now
   restores the files from the `orchestrator` seed when `hub` is empty
   ([CLUSTER_START_STOP_OPERATOR.md](CLUSTER_START_STOP_OPERATOR.md)).

If the **env kill switch** is off, Ask ALFa explains that and does not propose SSH **or**
missions. A missing **SSH key** blocks **SSH** catalog actions (`docker_ps`, `run_command`, …)
and SSH **inspect auto-run**. It does **not** block `ha_get_*` inspect (HA token) or
`web_search` inspect (internal SearXNG HTTP). Ask ALFa returns a **readiness block**
(`readiness_block` in the reply) with fix steps for SSH failures and **never** substitutes
a mission:

1. From `hub`: `sudo docker exec alfa-ai-api ls -l /app/secrets/host-actions/`
2. Verify `ALFA_AI_HOST_ACTIONS_SECRETS_DIR` in `deploy/.env`
3. `sudo bash scripts/brain_redeploy_api.sh`

Missions remain proposable only for **explicit job** phrases (`Audit host N`, `Review
errors`, feeder control, …) — **never** as a fallback when SSH inspect is blocked, and
**never** for Q&A that belongs in this chat (HA weather, `research online`, zip weather).

**`mission_enqueue` / `mission_clear_stuck` are internal brain API** (no SSH) and stay
proposable when `ALFA_AI_HOST_ACTIONS_ENABLED=1` even if the key is not mounted, but only
when the operator's message matches an explicit mission intent.

## Capability packs (optional defaults)

Packs group catalog actions. Soft-disabled packs still appear in Ask ALFa context; proposing them
is allowed. **Approve enables the pack for that action**, then runs. AI Config pack toggles remain
for operators who want to pre-enable or lock packs without using chat.

| Pack id | Label | Default | Actions |
|---------|-------|---------|---------|
| `read_basics` | Read basics | **on** | `docker_ps`, `docker_stats`, `docker_logs`, `disk_usage`, `health_check`, `git_status`, `repo_tree`, `repo_read_file`, `repo_grep`, `web_search` |
| `script_verify` | Script verify (read-only) | **on** | `brain_verify`, `hub_diag_read`, `ps_syntax_check`, `draft_judge_guide` |
| `monitoring` | Monitoring (monitor) | **on** | `prom_targets`, `prom_alerts`, `prom_query`, `prometheus_reload`, `refresh_prometheus_bearer` |
| `git_sync` | Git sync | **off** | `git_pull`, `git_commit`, `git_push` |
| `cluster` | Cluster lifecycle | **off** | `docker_restart`, `brain_redeploy_api`, `cluster_start`, `cluster_stop` |
| `consumer_ci` | Consumer CI reproduce | **off** | `ci_repro_rankings_lint`, `ci_repro_contracts_tests`, `ci_repro_market_tests` |
| `consumer_patch` | Consumer single-file patch | **off** | `apply_patch` |
| `home_energy` | Home energy (HA) | **off** | `ha_get_states`, `ha_get_state`, `ha_get_forecasts`, `ha_switch_on`, `ha_switch_off`, `ha_dump_tick`, `ha_set_number`, `ha_select_option` |
| `freeform` | Freeform shell | **off** | `run_command` |
| `missions` | Missions | **on** | `mission_enqueue`, `mission_feeder_pause`, `mission_feeder_resume`, `mission_clear_stuck` |

Auth levels on the Approve card:

| risk_tier | Auth level label | Confirm checkbox |
|-----------|------------------|------------------|
| 1 | Read | no |
| 2 | Ops (mutating) | yes (`ack_tier=2`) |
| 3 | Destructive | yes (`ack_tier=2`) |

## Catalog

| action_key | Pack | Mutating | Hosts | Notes |
|------------|------|----------|-------|-------|
| `docker_ps` | read_basics | no | all Phase 1 | List containers |
| `docker_stats` | read_basics | no | all Phase 1 | One-shot per-container CPU% and memory (`docker stats --no-stream`) |
| `docker_logs` | read_basics | no | all | params: `container`, optional `tail` (10-500) |
| `disk_usage` | read_basics | no | all | df / Get-PSDrive |
| `health_check` | read_basics | no | all | curl health_url when defined |
| `git_status` | read_basics | no | all | repo_dir from host config |
| `repo_tree` | read_basics | no | Linux Phase 1 only (not `orchestrator`) | params: optional `subdir`, `limit` (default 200, max 500). `git -C <repo_dir> ls-files` ([git-ls-files](https://git-scm.com/docs/git-ls-files)) |
| `repo_read_file` | read_basics | no | Linux Phase 1 only (not `orchestrator`) | params: `relative_path` (required; `..`, leading `/`, `.env`, `secrets/`, `.ssh/`, key files, `known_hosts` rejected), `start` (default 1), `lines` (default 200, max 400). Git-bounded: `git -C <repo_dir> ls-files --error-unmatch -- '<relative_path>' >/dev/null && sed -n '<start>,<end>p' -- '<repo_dir>/<relative_path>'` (untracked paths fail; [git-ls-files](https://git-scm.com/docs/git-ls-files), [POSIX sed](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/sed.html)) |
| `repo_grep` | read_basics | no | Linux Phase 1 only (not `orchestrator`) | params: `pattern` (required, 1-120 chars; no `'`, backtick, or `$(`), optional `subdir`, `limit` (default 100, max 300). `git -C <repo_dir> grep -n -I -e '<pattern>'` ([git-grep](https://git-scm.com/docs/git-grep)) |

All three `repo_*` actions accept an optional `params.repo_dir` override, used when a host owns
more than one clone (e.g. `probilliards` rankings-bot vs USPBF). The override must be one of the repo
paths listed in `docs/REPO_HOST_MAPPING.md` (`_REPO_DIR_ALLOWLIST` in `host_catalog.py`);
anything else is rejected at validation.
| `brain_verify` | script_verify | no | `hub` | `scripts/brain_verify.sh` in repo_dir |
| `hub_diag_read` | script_verify | no | `inference` | `scripts/diagnose-inference-ai.sh` (read-only snapshot) |
| `ps_syntax_check` | script_verify | no | `orchestrator`, `apps` | `Test-AlfaPowerShellScriptSyntax.ps1 -Recurse deploy` |
| `draft_judge_guide` | script_verify | no | `orchestrator`, `hub` | params: `task` (required, 1-2000 chars; no secrets). `python scripts/eval/run_7b_27b_guide.py --task '<task>'` ([ALFA_7B_27B_WORK_JUDGE.md](operations/ALFA_7B_27B_WORK_JUDGE.md); **Approve-gated SSH**; does not enable `ALFA_AI_JUDGE_ENABLED`). In-process Ask ALFa `draft-judge:` auto-writes confirmed drafts to the workspace when sim dump plugs are the energy rail. |
| `prom_targets` | monitoring | no | `monitor` | Prometheus `GET /api/v1/targets` ([HTTP API](https://prometheus.io/docs/prometheus/latest/querying/api/#targets)) |
| `prom_alerts` | monitoring | no | `monitor` | Prometheus `GET /api/v1/alerts` |
| `prom_query` | monitoring | no | `monitor` | params: `query` (PromQL). `GET /api/v1/query` |
| `prometheus_reload` | monitoring | yes | `monitor` | `POST /-/reload` ([Management API](https://prometheus.io/docs/prometheus/latest/management_api/#reload); requires `--web.enable-lifecycle`) |
| `refresh_prometheus_bearer` | monitoring | yes | `monitor` | `scripts/refresh-alfa-ai-prometheus-bearer.sh` (no Prometheus restart) |
| `git_pull` | git_sync | yes | all | `git pull --ff-only origin main` |
| `git_commit` | git_sync | yes | Phase 1 with `repo_dir` | params: `message`, optional `paths` (space-separated relative paths) |
| `git_push` | git_sync | yes | Phase 1 with `repo_dir` | `git push origin main` only |
| `docker_restart` | cluster | yes | all | **Blocks** inference/RPC container names |
| `brain_redeploy_api` | cluster | yes | `hub` only | `scripts/brain_redeploy_api.sh` |
| `cluster_start` | cluster | yes | `orchestrator` only | `Start-Stop-AlfaAi.ps1 start` |
| `cluster_stop` | cluster | yes | `orchestrator` only | `Start-Stop-AlfaAi.ps1 stop` |
| `ci_repro_rankings_lint` | consumer_ci | yes | `probilliards` | flake8 critical select (rankings-bot `lint.yml`) |
| `ci_repro_contracts_tests` | consumer_ci | yes | `apps` | pytest subset (contracts-bot `tests.yml`) |
| `ci_repro_market_tests` | consumer_ci | yes | `market` | pytest dry-run suite (market-pie5-bot `tests.yml`) |
| `apply_patch` | consumer_patch | yes | `market`, `apps`, `probilliards` | params: `relative_path`, `content` (one file, max 80 lines; blocks secrets/workflows) |
| `run_command` | freeform | yes | all Phase 1 | **Freeform.** params: `command`. Rejected if inference/RPC blocklist matches. |
| `mission_enqueue` | missions | yes | `hub` only | **Internal brain API** (no SSH). params: `goal`, `target_host`, optional `skill`, `research_only=true` required |
| `mission_feeder_pause` | missions | yes | `hub` only | Creates `FEEDER_PAUSE` under hub audit log dir |
| `mission_feeder_resume` | missions | yes | `hub` only | Removes `FEEDER_PAUSE` |
| `mission_clear_stuck` | missions | yes | `hub` only | **Internal brain API**. Fail wedged pending/running runs (optional `min_age_sec`, `dry_run`) |
| `ha_get_states` | home_energy | no (inspect) | `apps` (logical; httpx from brain) | **Internal REST**. Snapshot of dump-load-related states. No SSH. |
| `ha_get_state` | home_energy | no (inspect) | `apps` | **Internal REST**. params: `entity_id` |
| `ha_get_forecasts` | home_energy | no (inspect) | `apps` | **Internal REST** `POST /api/services/weather/get_forecasts?return_response`. params: `entity_id` (`weather.*`), `type` (`daily` / `hourly` / `twice_daily`). Does **not** actuate dump. |
| `web_search` | read_basics | no (inspect) | `hub` (logical) | **Internal HTTP** to LAN SearXNG ([search API](https://docs.searxng.org/dev/search_api.html)). params: `query` (required). Reuses [`src.agent.tools.web_search`](../src/agent/tools.py). **No SSH.** Kill switch: `ALFA_AI_WEB_SEARCH_ENABLED=0` → fail-closed. Ask ALFa Q&A only — not guest/SPA/consumer. |
| `ha_switch_on` | home_energy | yes (auto) | `apps` | **Internal REST** `POST /api/services/switch/turn_on`. Entity must be in `ha_switch_allowlist`. **Runs immediately** when HA env + token (no Approve). |
| `ha_switch_off` | home_energy | yes (auto) | `apps` | Same for `turn_off` |
| `ha_dump_tick` | home_energy | no (inspect / immediate observe) | `apps` | One-shot **observe** dump tick (same as ticker; **no switch services**; **no LLM / 7B / 27B**). HA automations own on/off. **Runs immediately** when HA env + token. |
| `ha_set_number` | home_energy | yes (auto) | `apps` | **Internal REST** `POST /api/services/input_number/set_value`. Allowlisted dump helpers only (float/re-bulk V, min solar W, AC caps, max discharge, min SoC). **Runs immediately** when HA env + token (no Approve). Official: [input_number.set_value](https://www.home-assistant.io/integrations/input_number/). |
| `ha_select_option` | home_energy | yes (auto) | `apps` | **Internal REST** `POST /api/services/input_select/select_option`. Plug inverter `T2`/`KU`/`Sungold` only. **Runs immediately** when HA env + token (no Approve). Official: [input_select.select_option](https://www.home-assistant.io/integrations/input_select/). |

`ha_*` requires `ALFA_AI_HOME_ASSISTANT_ENABLED=1` and the token file -- **not**
`ALFA_AI_HOST_ACTIONS_ENABLED` or the SSH key. See
[HOME_ASSISTANT_BRAIN_INTEGRATION.md](HOME_ASSISTANT_BRAIN_INTEGRATION.md).

### Risk tiers (tier-2 Approve)

| Tier | Class | Examples | Approve |
|------|-------|----------|---------|
| 1 | read | `docker_ps`, `docker_stats`, `prom_targets`, `prom_alerts`, `prom_query`, `git_status`, `repo_tree`, `repo_read_file`, `repo_grep`, `web_search`, `brain_verify`, `hub_diag_read`, `ps_syntax_check`, `draft_judge_guide`, `ha_get_states`, `ha_get_state`, `ha_get_forecasts`, `ha_dump_tick` | single click (inspect auto-run when `is_inspectable`; script-verify keys stay Approve-gated). `ha_*` and `web_search` inspect use internal HTTP (HA token / SearXNG), **not** SSH. |
| 2 | ops | `git_pull`, `docker_restart`, `prometheus_reload`, `refresh_prometheus_bearer`, `ci_repro_*`, `mission_*` | requires `ack_tier: 2` + checkbox in Ask ALFa |
| 2 auto | home_energy | `ha_switch_on`, `ha_switch_off`, `ha_set_number`, `ha_select_option` | **No Approve** when HA env + token; logged to `ai_actions`. Dump on/off remains HA automations. Solar dump is outside NIST. |
| 3 | destructive | `cluster_start`, `cluster_stop`, `brain_redeploy_api`, `git_commit`, `git_push`, `run_command`, `apply_patch` | requires `ack_tier: 2` + checkbox in Ask ALFa |

Approve/reject events are dual-written to `audit_log` (`host_action_approved` /
`host_action_rejected`) **and** the unified `ai_actions` feed (`host_command_executed` /
`host_action_rejected`). NIST AI RMF **Measure** and Google SRE transparency require
declined L2 proposals to appear in the operator AI Actions feed, not only security audit.
See [NIST Core Measure](https://airc.nist.gov/airmf-resources/airmf/5-sec-core/) and
[Google SRE AI ops transparency](https://sre.google/resources/practices-and-processes/ai-engineering-reliable-operations/).

## Inspect (L1 auto-run) vs Approve (L2)

**HA solar dump (not NIST, operator 2026-09-19):** `ha_switch_on` / `ha_switch_off`
and dump helpers `ha_set_number` / `ha_select_option` are **not** pending Approve
actions. When `ALFA_AI_HOME_ASSISTANT_ENABLED=1` and the token file is present, Ask
ALFa **executes on propose**, returns stdout in chat, and logs `host_command_executed`.
Gated by `ha_switch_allowlist` (switches) or dump helper allowlists (numbers/selects).
Dump on/off is Home Assistant automations. `ha_dump_tick` observes immediately
(no switch POST). Official REST: [POST /api/services/{domain}/{service}](https://developers.home-assistant.io/docs/api/rest/).

**Inspectable** catalog actions may auto-run inside an Ask ALFa turn without a click when
`ask_alfa_inspect_autorun` is on (policy `ai_setting`, default `true`) and readiness is OK
(SSH key for SSH catalog; **HA token + `ALFA_AI_HOME_ASSISTANT_ENABLED`** for `ha_get_states` /
`ha_get_state` / `ha_get_forecasts` / `ha_dump_tick`; **`ALFA_AI_WEB_SEARCH_ENABLED=1`** for
`web_search` — SSH is **not** required for HA or `web_search` inspect).

`is_inspectable(action_key)` is true when:

- catalog `mutating=False`, **and**
- `risk_tier == 1`, **and**
- key is **not** in `brain_verify`, `hub_diag_read`, `ps_syntax_check`, or `draft_judge_guide`
  (script-verify stays Approve-gated so the Grok Bot `bot_audit_excerpt` flow is unchanged).

`run_command` is **never** inspectable.

**Budget:** 6 `inspect_host` tool calls and 150 s of LLM-loop inspect time per turn.
Analyze-repo **pre-inspect** (tree, git status, docker ps, README, scraper grep) is extra
and does not consume those 6 calls. Each step logs `host_inspect_executed` to `ai_actions`
and appears in the reply `inspections[]` and SSE `inspect` events.

Inspect findings are sent to the model in a dedicated chat message (not inside the truncated
12k admin-context JSON). That packing is required so `frontier-code` actually reads the
repo instead of inventing a budget error from catalog trivia.

**Setting off:** when `ask_alfa_inspect_autorun=false`, an analyze-repo turn returns the same
`readiness_block` shape with reason `inspect auto-run disabled` and one fix step (Approve the
policy change back to `true`); `inspect_host` tool calls fail closed and the model must propose
the read action for Approve instead.

Mutating SSH / `run_command` / cluster actions stay `pending` -> Approve every time.
HA solar dump helpers and switch one-shots auto-actuate (see above).

inference shards/coordinator: **no piecemeal restart** -- only `cluster_start` / `cluster_stop` on `orchestrator`
([no-piecemeal-cluster-scripts.mdc](../.cursor/rules/no-piecemeal-cluster-scripts.mdc)). Enforced on
`run_command` text too, at propose time (before it can become `pending`) and again at approve time.
The deterministic router also rejects inference piecemeal **before** any LLM call when the operator
message clearly asks for a blocked restart/stop/probe.

### `prom_query` curated examples (host load / thermal)

Use `prom_query` on host `monitor` with params `query` (PromQL). Official API:
`GET /api/v1/query` ([instant queries](https://prometheus.io/docs/prometheus/latest/querying/api/#instant-queries)).

| Use | Example PromQL |
|-----|----------------|
| Host CPU busy % | `100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)` |
| Load 1m | `node_load1` |
| Package / core temp (C) | `homelab:cpu_temperature_celsius` (max of IPMI `TEMP_CPU`, OS hwmon, OhmGraphite; see monitoring `docs/IPMI_CPU_TEMPERATURE.md`) |
| Top containers by CPU | `topk(10, sum by (instance, name) (rate(container_cpu_usage_seconds_total{name!=""}[5m])))` |

Ask ALFa also pulls a compact snapshot of these metrics into `prometheus_ops` context (L1 enrich)
when Prometheus is reachable. Missing hosts (e.g. `apps` not in `node-remote`) appear as gaps -- do
not invent metrics.

## Deterministic vs LLM (Ask ALFa)

See [AI_ACTIONS.md](AI_ACTIONS.md) **Hybrid path**. Summary: programs own explicit catalog proposes,
setting writes, structured context reads, and blocklist enforcement; the LLM owns diagnosis and
ambiguous intent only. **Analyze / inspect / look at** a named repo requests return an
`llm_continue` sentinel with a `pre_inspect` step list (`repo_tree`, `git_status`,
`docker_ps`, `repo_read_file` README.md, `repo_grep` scraper) instead of enqueueing a
mission; the agent loop runs those inspect steps then calls the LLM.
Proposals created via the router use `proposed_by` = the operator's email (same as manual
propose) so the Host actions feed shows who asked.

**`host_action_id` in the final JSON:** must be `null` or the **real UUID** returned by
`propose_host_action`. Invented values (e.g. `"12345"`) are ignored — stores validate UUID
format before querying Postgres (avoids `invalid input syntax for type uuid`). See
[psycopg UUID adaptation](https://www.psycopg.org/psycopg3/docs/basic/adapt.html) and
[Python `uuid.UUID`](https://docs.python.org/3/library/uuid.html).

## Phase 1 hosts (SSH ready)

| key | IP | SSH user | os_type |
|-----|-----|----------|---------|
| 93 | orchestrator | operator | windows |
| 100 | orchestrator | operator | linux |
| 102 | market | operator | linux |
| 103 | atems | operator | linux |
| 105 | apps | ansible | linux |
| 106 | orchestrator | operator | linux |
| 107 | monitor | operator | linux |
| 111 | hub | operator | linux |
| 148 | orchestrator | operator | linux |

**Phase 2 (not in default catalog hosts until you configure SSH):** `gaming-a`, `gaming-c`, `gaming-b` gaming
workers -- require OpenSSH Server + dedicated account on each PC first.

Override inventory: `ALFA_AI_HOST_ACTIONS_HOSTS_JSON` (JSON array, same shape as defaults in
[src/ops/host_catalog.py](../src/ops/host_catalog.py)), **or** live edits in **AI Actions -> AI Config -> Host registry**
(stored in `ai_agent_config.host_overrides`).

## Live operator config (`ai_agent_config` table)

Single Postgres row (`id=default`) editable from **AI Actions -> AI Config**:

| Field | Purpose |
|-------|---------|
| `system_prompt_override` | Full freeform Ask ALFa system prompt; null = in-code default |
| `host_overrides` | JSON array merged over code/env host list; `enabled: false` removes a host |
| `disabled_actions` | Catalog keys the AI cannot propose (re-checked at Approve) |
| `context_sections` | Booleans for incidents, settings, cluster health, etc. |

API: `GET/POST /alfa-ai/api/admin/agent-config/*` (see [AI_ACTIONS.md](AI_ACTIONS.md)).

**Layering:** `ALFA_AI_HOST_ACTIONS_ENABLED=0` is the hard kill switch. DB toggles are soft
per-host/per-action controls on top.

## Environment (brain `deploy/.env`)

```bash
# Default off until SSH keys are provisioned (see runbook below).
ALFA_AI_HOST_ACTIONS_ENABLED=0

# Private key path inside alfa-ai-api container (read-only mount).
ALFA_AI_HOST_ACTIONS_SSH_KEY=/app/secrets/host-actions/id_ed25519

# SSH known_hosts file (asyncssh: https://asyncssh.readthedocs.io/en/latest/api.html#asyncssh.connect)
# Required before approving host actions. Default: <secrets-dir>/known_hosts when present.
# ALFA_AI_HOST_ACTIONS_KNOWN_HOSTS=/app/secrets/host-actions/known_hosts

# Optional: override host list (JSON array).
# ALFA_AI_HOST_ACTIONS_HOSTS_JSON=[{"key":"93",...}]
```

Mount the key in [deploy/docker-compose.yml](../deploy/docker-compose.yml):

```yaml
volumes:
  - ${ALFA_AI_HOST_ACTIONS_SECRETS_DIR:-./secrets/host-actions}:/app/secrets/host-actions:ro
```

## API (admin JWT + CIDR)

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/alfa-ai/api/admin/host-actions/catalog` | Catalog + hosts + enabled flag |
| GET | `/alfa-ai/api/admin/host-actions?status=&limit=` | List proposals/history |
| POST | `/alfa-ai/api/admin/host-actions/propose` | `{ action_key, host, params }` |
| POST | `/alfa-ai/api/admin/host-actions/{id}/approve` | Execute (operator click) |
| POST | `/alfa-ai/api/admin/host-actions/{id}/reject` | Reject pending |
| POST | `/alfa-ai/api/admin/host-actions/{id}/feedback` | Thumbs on completed/rejected action |
| POST | `/alfa-ai/api/admin/monitoring-agent` | Ask ALFa; may return `host_action_proposal` |

## SSH key provisioning runbook (operator)

**Goal:** dedicated Ed25519 key used only by `alfa-ai-api` on `hub` to reach Phase 1 hosts.
Do **not** reuse personal operator keys.

### Step 1 -- From `orchestrator` (PowerShell as `operator`)

Generate key pair (store under repo secrets template; never commit private key):

```powershell
New-Item -ItemType Directory -Force -Path C:/Users/operator\alfa-ai\deploy\secrets\host-actions
ssh-keygen -t ed25519 -f C:/Users/operator\alfa-ai\deploy\secrets\host-actions\id_ed25519 -N '""' -C alfa-ai-host-actions
```

### Step 2 -- Install public key on each Linux host

One host at a time (example `pool-opt-in`):

```powershell
type C:/Users/operator\alfa-ai\deploy\secrets\host-actions\id_ed25519.pub | ssh operator@orchestrator "mkdir -p ~/.ssh; chmod 700 ~/.ssh; cat >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys"
```

Repeat for: `market`, `atems`, `apps`, `probilliards`, `monitor`, `inference` (adjust user per table above).

For `hub` (**operator only** -- From `hub` as `operator`):

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
# paste the public key line into ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

For `orchestrator` (Windows OpenSSH as `operator`) appending the key is **not enough** -- also grant SYSTEM read
(see [Windows `authorized_keys` ACL](#windows-authorized_keys-acl-93) below):

```powershell
type C:/Users/operator\alfa-ai\deploy\secrets\host-actions\id_ed25519.pub >> $env:USERPROFILE\.ssh\authorized_keys
```

```powershell
icacls $env:USERPROFILE\.ssh\authorized_keys /grant "*S-1-5-18:(R)"
```

### Step 3 -- Copy private key **and `known_hosts`** to `hub` brain

Both files are required. `src/ops/ssh_executor.py` refuses every action with exit `127` when
`known_hosts` is missing (asyncssh: never pass `known_hosts=None` in production), so copying only
the private key produces actions that fail after Approve.

From `orchestrator` (operator may paste on `hub` if SCP fails):

```powershell
scp -i $env:USERPROFILE\.ssh\id_ed25519_93_111 C:/Users/operator\alfa-ai\deploy\secrets\host-actions\id_ed25519 C:/Users/operator\alfa-ai\deploy\secrets\host-actions\known_hosts operator@hub:/mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/secrets/host-actions/
```

On `hub`, set permissions:

```bash
chmod 600 /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/secrets/host-actions/id_ed25519
```

Set in `deploy/.env`:

```bash
ALFA_AI_HOST_ACTIONS_SECRETS_DIR=/mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/secrets/host-actions
ALFA_AI_HOST_ACTIONS_ENABLED=1
```

**Why the in-repo path is safe.** `operator-cluster-111.sh` runs `git clean -fd` then
`git reset --hard origin/main` on every cluster start. `git clean` without `-x` does not remove
ignored files ([git-clean docs](https://git-scm.com/docs/git-clean)), and
`deploy/secrets/host-actions/.gitignore` ignores the key, so it survives cluster starts. A path
outside the repo also works; set `ALFA_AI_HOST_ACTIONS_SECRETS_DIR` accordingly.

The API container has no `USER` directive and no compose `user:` override, so it runs as root and
reads the `0600` key regardless of the owning UID on the hub side.

### Step 4 -- Verify from brain API container

Confirm both files are visible inside the container (an empty listing means the mount source is
wrong -- compare against `docker inspect ... .Mounts`):

```bash
sudo docker exec alfa-ai-api ls -l /app/secrets/host-actions/
```

Then propose a read-only action from Ask ALFa (e.g. `docker_ps` on host `111`) and approve. Expect
stdout listing containers, or a clear SSH error if keys are wrong.

**Canonical verification (all hosts, real code path).** Run the same library, key, and `known_hosts`
the executor uses, from inside the container. This isolates SSH from the LLM, the proposal flow, and
the approval gate, and the exception name identifies the failing layer: `PermissionDenied` means
`authorized_keys`, `HostKeyNotVerifiable` means a missing `known_hosts` entry, `TimeoutError` means a
firewall or a host that is down.

```bash
sudo docker exec alfa-ai-api python -c "
import asyncio, asyncssh
HOSTS=[('93','orchestrator','operator'),('100','orchestrator','operator'),('105','apps','ansible'),('106','orchestrator','operator'),('107','monitor','operator'),('111','hub','operator'),('148','orchestrator','operator')]
async def one(k,ip,u):
    try:
        async with asyncssh.connect(ip,username=u,client_keys=['/app/secrets/host-actions/id_ed25519'],known_hosts='/app/secrets/host-actions/known_hosts',connect_timeout=10) as c:
            r=await c.run('hostname',check=False)
            return 'OK   .'+k+'  '+u+'@'+ip+' -> '+r.stdout.strip()
    except Exception as e:
        return 'FAIL .'+k+'  '+u+'@'+ip+' -> '+type(e).__name__+': '+str(e)
async def m():
    for line in await asyncio.gather(*[one(*h) for h in HOSTS]):
        print(line)
asyncio.run(m())
"
```

### Verifying key auth by hand

Always pass **`-o IdentitiesOnly=yes`**. Without it the SSH client offers the operator's personal
keys from `~/.ssh` and the agent forwards, so a host with **no** host-actions key still returns a
false OK ([ssh_config(5)](https://man.openbsd.org/ssh_config.5#IdentitiesOnly)):

```powershell
ssh -i C:/Users/operator\alfa-ai\deploy\secrets\host-actions\id_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=C:/Users/operator\alfa-ai\deploy\secrets\host-actions\known_hosts operator@orchestrator hostname
```

### Troubleshooting

<a id="windows-authorized_keys-acl-93"></a>

| Symptom | Cause | Fix |
|---|---|---|
| `Permission denied (publickey,...)` on **`orchestrator`** although the key is in `authorized_keys` | `C:\Users\<user>\.ssh` grants `SYSTEM` and `Administrators` **folder-only** (no `(OI)(CI)`), so `authorized_keys` inherits only the user ACE. `sshd` runs as SYSTEM and cannot read it. Default `LogLevel INFO` logs nothing useful -- the OpenSSH event log shows only `Connection reset by authenticating user ... [preauth]`. | `icacls $env:USERPROFILE\.ssh\authorized_keys /grant "*S-1-5-18:(R)"` |
| `WARNING: UNPROTECTED PRIVATE KEY FILE!` when testing from `orchestrator` | Private key inherits ACEs for other accounts (e.g. `operator`) | `icacls <key> /inheritance:r /grant "$env:USERNAME:(R)"` |
| Action fails with exit `127` and "SSH known_hosts file missing" | Only `id_ed25519` was copied to `hub` | Copy `known_hosts` too (Step 3) |
| `ls /app/secrets/host-actions/` shows `total 0` | Mount source on `hub` is empty or points elsewhere | `sudo docker inspect alfa-ai-api --format '{{range .Mounts}}{{if eq .Destination "/app/secrets/host-actions"}}{{.Source}}{{end}}{{end}}'` |
| `TimeoutError` from the container to **`orchestrator`**, but SSH from `orchestrator` to itself succeeds | Windows Firewall rule `OpenSSH SSH Server (sshd)` is **disabled**, so inbound tcp/22 is blocked from the LAN. Same-host traffic bypasses the rule, so a loopback test is **not** proof of reachability -- always verify from the container. | Admin PowerShell as `operator`: `Set-NetFirewallRule -DisplayName "OpenSSH SSH Server (sshd)" -Enabled True` |
| `TimeoutError` plus `ping` reporting `Destination host unreachable` | ARP failure -- the host is powered off or off the network, not a firewall drop | Power the host on |

Verified working from inside `alfa-ai-api` on 2026-09-02 -- all six reachable hosts OK: `orchestrator`
(`operator`), `pool-opt-in`, `monitor`, `inference` (`operator`), `apps` (`ansible`), `hub` (`operator`). `market`, `atems`,
and `probilliards` were intentionally powered off and remain untested; install the pubkey per Step 2 when
they come back.

## Deploy

1. Commit/push from owning host (e.g. `orchestrator`).
2. On `hub`: `bash scripts/brain_redeploy_api.sh` (pulls `main`, rebuilds API + frontend, runs `brain_verify`).
   Already pulled: `bash scripts/brain_redeploy_api.sh --skip-pull`.
3. Enable `ALFA_AI_HOST_ACTIONS_ENABLED=1` only after Step 3 above (SSH key mount).
4. Test: propose `health_check` on `111`, approve, confirm exit 0.
5. After API recreate: `brain_redeploy_api.sh` attempts SSH to `monitor` for
   `refresh-alfa-ai-prometheus-bearer.sh` (no Prometheus restart). If `hub`
   has no key, the next **cluster start from `orchestrator`** runs the same refresh
   after brain health ([ALFA_AI_OPERATIONAL_ALERTS.md](ALFA_AI_OPERATIONAL_ALERTS.md)).

## Related

- [AI_ACTIONS.md](AI_ACTIONS.md) -- Ask ALFa widget and unified feed
- [chat-data-isolation.mdc](../.cursor/rules/chat-data-isolation.mdc) -- consumer bot boundary
- [CLUSTER_START_STOP_OPERATOR.md](CLUSTER_START_STOP_OPERATOR.md) -- cluster orchestrator
