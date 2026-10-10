# AI autonomy and oversight matrix

**Binding companion to** [AI_GOVERNANCE.md](AI_GOVERNANCE.md).  
**Standards:** [docs/standards/](standards/README.md).

Maps every production AI / automation surface to Google SRE autonomy level,
NIST oversight, kill switch, and audit sink.

| Surface | Level | Human gate | Kill switch / default | Audit sink |
|---------|-------|------------|----------------------|------------|
| Alertmanager webhook ingest | L1 (program) | N/A (auth + LAN) | `ALFA_AI_ALERT_WEBHOOK_TOKEN` | `incidents`, `incident_events` |
| Playbook investigate | L1 | N/A | Worker profile | `investigation_*` events |
| Severity / notify routing | L1 (program) | Threshold settings | `ALFA_AI_ALERT_AI_TRIAGE`, `ai_triage_enabled` | `ai_actions` (`created_by=program`) |
| Unknown-alert LLM summary | L1 opt-in | N/A | `ALFA_AI_INCIDENT_LLM_TRIAGE=false` | `llm_triage` event |
| `maybe_tune_settings` | Must not silent-mutate policy | Pending or default off | `ai_can_adjust_settings` → **default false** (Composer) | `setting_changed` |
| Monitoring Analyze | L1 | Operator click | N/A | `incident_remediations` |
| Remediation Apply (PR) | L2 | Checkbox `confirm` | `ALFA_AI_REMEDIATION_ENABLED=false` | `audit_log` |
| Ask ALFa catalog read | T0 | None (inspect) / Approve when proposed explicitly | Host actions enabled | — |
| Ask ALFa inspect (read-only catalog steps auto-run inside a turn) | L1 observe | None per step; every step shown in chat with command + output | SSH catalog: `ask_alfa_inspect_autorun` (default `true`) AND `ALFA_AI_HOST_ACTIONS_ENABLED=1` AND SSH key. **HA** and **`web_search`** inspect: no SSH (HA token / `ALFA_AI_WEB_SEARCH_ENABLED`) | `ai_actions` (`host_inspect_executed`), reply `inspections[]` |
| Ask ALFa catalog mutate | L2 / T1–T2 | Approve (+ tier-2 confirm); reject logged. Queued follow-ups still need Approve when they propose mutate ([CHAT_AGENT_STREAMING.md](CHAT_AGENT_STREAMING.md)) | `ALFA_AI_HOST_ACTIONS_ENABLED=0` | `ai_host_actions`, `ai_actions` (`host_command_executed` / `host_action_rejected`), `audit_log` |
| Ask ALFa CI paste triage | L1 summarize + L2 reproduce | Approve reproduce only | `consumer_ci` pack soft-off | `ci_triage` in reply; no consumer DB |
| Ask ALFa host load/thermal | L1 enrich (Prometheus snapshot) | Probes (`docker_stats`, `prom_query`) are inspectable: auto-run inside the turn when inspect is on; otherwise Approve | No auto-restart | `prometheus_ops` context; `ai_actions` (`host_inspect_executed`) or `ai_host_actions` on Approve |
| Ask ALFa `ha_get_states` / `ha_get_state` / `ha_get_forecasts` | L1 observe | Inspect auto-run when HA env on | `ALFA_AI_HOME_ASSISTANT_ENABLED=0` | `ai_actions` (`host_inspect_executed`) |
| Ask ALFa `ha_switch_on` / `ha_switch_off` | Solar dump (not NIST) | **No Approve** when HA env + token; allowlist | HA env; empty allowlist = no toggles | `host_command_executed` |
| Ask ALFa `ha_set_number` / `ha_select_option` | Solar dump (not NIST) | **No Approve** when HA env + token; dump helper allowlist | HA env | `host_command_executed` |
| Ask ALFa `ha_dump_tick` | L1 observe | Auto when HA env + token | HA env | `solar_dump_observed` / `_recommended` |
| Solar dump load ticker | L1 observe | Settings + env; **no LLM**; **no switch services** | `ALFA_AI_HOME_ASSISTANT_ENABLED=0` | `solar_dump_observed` / `_recommended` |
| Ask ALFa `run_command` | L2 T2 | Approve + tier-2 | Default **disabled** in config | Same |
| Ask ALFa `apply_patch` | L2 T3 | Approve + tier-2 | `consumer_patch` pack **off** | Same |
| Ask ALFa setting change (kill switches) | T3 | Pending Approve | Composer: no immediate apply | `ai_actions` |
| Incident `auto_fix` | L3 candidate | Per-alert allowlist | `ALFA_AI_INCIDENT_AUTO_FIX=false` | `remediation_*` events |
| `/api/runs` agent tools (`web_search`) | Research L1; **LAN admin only** | Bearer `ALFA_AI_API_TOKEN` + flags | `ALFA_AI_WEB_SEARCH_ENABLED=0` fail-closed; never guest/public/consumer chat | Mission events → unify with `ai_actions` |
| Ask ALFa `web_search` inspect (in-chat Q&A) | L1 observe | None per step; answer in this dock — **not** `mission_enqueue` | `ALFA_AI_WEB_SEARCH_ENABLED=0` fail-closed; LAN admin JWT only; never guest/SPA/consumer | `ai_actions` (`host_inspect_executed`), reply `inspections[]` |
| Scheduled audit judge | L1 dual-check | Cursor + operator final | `ALFA_AI_JUDGE_ENABLED=0` | `agent-audit-logs/judged.jsonl`, `cursor-review-*.md` |
| Ask ALFa `draft-judge:` (7B draft + 27B judge loop) | L3 project sandbox | **Optional** LLM loop; dump **on/off** is Home Assistant, not this loop. Explicit prefix; 27B `confirm` auto-writes workspace files **only if** sim dump allowlist is the energy rail | `ALFA_AI_JUDGE_ENABLED=0` (default); HA ready + `switch.sim_ac_plug_*` only; normal chat stays `frontier-code` | `logs/draft-judge/sessions.jsonl`, `draft-judge/applied/{session}.md`, reply `draft_guide` |
| **In repo (default off)** Ask ALFa native OpenAI tools | L1 inspect / L2 propose | Same gates as inspect/propose today | `ALFA_AI_NATIVE_TOOLS=0` (default off) | plan [H1](../.cursor/plans/HARNESS_CUTTING_EDGE_2026-09.md) |
| **In repo** Mission skills progressive disclosure | L1 | Catalog `name`+`description` at start; body on activate | Existing `skills/` load; no new kill switch | [H2](../.cursor/plans/HARNESS_CUTTING_EDGE_2026-09.md) landed |
| **In repo** Ask ALFa inspect compaction (H3) | L1 observe | UI keeps full `inspections[]`; LLM prompt compacts older inspect dumps (last 2 verbatim) | Always on (deterministic extract) | [H3](../.cursor/plans/HARNESS_CUTTING_EDGE_2026-09.md) |
| **In repo** Brain MCP inspect mount (H4) | L1 observe | Admin JWT + LAN; inspectable catalog only (no MCP mutate) | `ALFA_AI_MCP_ENABLED=0` (default off) | [H4](../.cursor/plans/HARNESS_CUTTING_EDGE_2026-09.md) landed |
| Admin Missions tab (www) | L1 observe | Read-only; no create-run | N/A (admin JWT) | Fleet heartbeats + orchestrator runs |
| Per-host agent workers | L1 read-only gather | Host affinity queues | `ALFA_AI_WORKER_HOST` per member | Redis heartbeat + hub export |
| Cluster Start-Stop orchestrator | Operator-only | Operator paste | N/A | Orchestrator logs |
| Ubuntu/Debian `unattended-upgrades` (security only, no reboot) | L1 (vendor) | N/A | Overlay pins reboot false + package blacklist | `/var/log/unattended-upgrades/` |
| Kernel / NVIDIA / Docker / Proxmox `full-upgrade` / hub Apply Pending Update | L2 operator | Cluster stop first; hub idle + secret seed | Never silent | Host apt/UI logs |
| Cursor agents on `orchestrator` | Edit/commit only for cluster start | Operator runs orchestrator | [cluster-start-stop-only.mdc](../.cursor/rules/cluster-start-stop-only.mdc) | Git + session |
| Grok Bot (cloud teammate) | L1 draft / read; L2 only if operator asks for a PR | Operator reviews every write, push, or publish | Local computer **Never allowed**; no routines until a one-off works; no LAN / `.env` on the shared computer; **git/files/connectors by default** (no computer-use unless the task names a URL). Official: [Grok Bot get started](https://docs.x.ai/grok-bot/get-started), [approvals](https://docs.x.ai/grok-bot/approvals-security-and-privacy), [token-efficient Bot jobs](../.cursor/rules/grok-bot-token-efficiency.mdc) | Grok Bot conversation + GitHub (no cluster logs) |

Grok Bot bills the same Grok 4.6 token rates as Cursor ([plans](https://cursor.com/help/grok-bot/plans); [xAI pricing](https://docs.x.ai/developers/pricing)). Extra spend is **agent steps and computer-use images**, so default Bot jobs stay on an existing `/workspace` clone (`git pull`, rg, file reads) and a connector when one exists ([computer and apps](https://docs.x.ai/grok-bot/computer-and-apps)). Do interactive edits in Cursor Grok 4.6. Save a skill after one cheap one-off; add a routine only after a second success ([skills and routines](https://docs.x.ai/grok-bot/skills-routines-and-automations)).

**Scripts vs Bots:** repetitive cluster work belongs in repo scripts and Ask ALFa catalog actions (deterministic; operator Approve). Grok Bot names the script and may dual-check a **truncated** stdout paste against `PASS`/`FAIL` lines. It must not SSH, call Ask ALFa, or re-run the job on the cloud computer. Primary correctness is the script exit code and wait/health helpers ([script-creation-standards.mdc](../.cursor/rules/script-creation-standards.mdc)), not the LLM. Operator loop: [GROK_BOT_SCRIPT_LOOP.md](GROK_BOT_SCRIPT_LOOP.md).

## Determinism matrix (never LLM)

These paths must remain **program code** (NIST: separate judgment from execution;
SRE: deterministic hot paths):

- Webhook auth, fingerprint dedupe, enqueue
- Playbook HTTP/script investigate steps
- Severity label map, quiet hours, dedup, rate limits
- inference / RPC piecemeal blocklist
- Catalog command templates (non-freeform)

Solar dump load observe + watt-ledger stay **program** for the ticker
([HOME_ASSISTANT_BRAIN_INTEGRATION.md](HOME_ASSISTANT_BRAIN_INTEGRATION.md)).
Switch on/off is Home Assistant automations. Ask ALFa dump helper writes
(`ha_set_number` / `ha_select_option`) run immediately when HA env + token are
on (operator 2026-09-19; not under NIST). Dump does **not** require 7B, 27B, or
Path B.

LLM allowed for: Analyze briefing, Ask ALFa diagnosis, optional unknown-alert
summary, ambiguous natural-language Q&A — **not** for selecting destructive
actions without a pending proposal.

## Operator dual-check (verifier loop)

Industry-standard HITL: alfa-ai produces an **enrichment briefing** (evidence +
ranked suggested actions). Operator may paste into a stronger model for a second
opinion, then act manually or Approve an L2 proposal. This is **encouraged** and
does not require code changes beyond better Analyze output (Composer Wave B).

## L4 — When judge + tests may raise autonomy (still no silent mutate)

SSoT for learning-loop L4.2. Complements [AI_GOVERNANCE.md](AI_GOVERNANCE.md)
and [LEARNING_LOOP_JUDGE_SLEEP.md](../.cursor/plans/LEARNING_LOOP_JUDGE_SLEEP.md).

**Primary gate (J0):** deterministic tests + `check-work` `VERDICT: PASS`. The
judge (J1, `gaming-c` 14B when OP-LL-1 is live) is a **dual-check**, never the
sole authority, and **never auto-approves** host mutate or production `.env`.
**Operator 2026-09-15:** Path B 27B-confirmed drafts may auto-write under
`ALFA_AI_WORKSPACE_ROOT/draft-judge/applied/` when `path_b_sim_dump_guardrail()`
passes (simulated dump-load plugs only). That is **not** SSH, inference, cluster, or guest.

| Autonomy bump | Allowed only if | Still forbidden |
|---------------|-----------------|-----------------|
| Scheduled **read-only** audits / sleep curator | Operator enabled the cron/flag | Silent web scrape; guest/public tools |
| Judge on research finals / freeform proposals | `ALFA_AI_JUDGE_ENABLED=1` after OP-LL-1 + calibration | Using judge to skip Approve |
| Coder `edit_file` / `create_file` / `run_cmd` | `ALFA_AI_AGENT_MUTATE_ENABLED=1` **and** human-gated mission | Default-on mutate; unattended prod edits |
| Incident `auto_fix` | Per-alertname allowlist **and** `ALFA_AI_INCIDENT_AUTO_FIX` after drills | Global auto_fix; inference piecemeal |
| Native OpenAI `tools` | `ALFA_AI_NATIVE_TOOLS=1` after 27B or Pool80 smoke | Replacing JSON-in-text as the only path without a fallback |

**Disagreement:** if tests fail, or judge flags a proposal, **stop** — operator
decides. Do not raise autonomy to resolve a conflict.

**Silent L3 host mutate stays off.** Raising Path B project autonomy never means
the model SSHes, restarts shards, or writes production `.env` without Approve.
Simulated dump-load plugs remain the energy rail; a real house entity on the dump
allowlist pauses Path B auto-write.

## Gaps tracked for Composer

See [.cursor/plans/COMPOSER_NIST_SRE_ALIGNMENT.md](../.cursor/plans/COMPOSER_NIST_SRE_ALIGNMENT.md).
