# AI governance (NIST AI RMF + Google SRE) — binding

**Status:** Binding for **alfa-ai** and every ALFa consumer repo / cluster host,
**except** (operator 2026-09-19) **victron-ble2mqtt-integration** and the
**alfa-ai Home Assistant solar dump** path (HA dump automations, watt-ledger,
Ask ALFa dump helper writes). Those follow official Home Assistant REST only.
**Standards library:** [docs/standards/](standards/README.md) (NIST PDFs + Google SRE extract).  
**Composer backlog:** [.cursor/plans/COMPOSER_NIST_SRE_ALIGNMENT.md](../.cursor/plans/COMPOSER_NIST_SRE_ALIGNMENT.md).

## Why this exists

Production AI that can notify, mutate hosts, open PRs, or run agents must follow:

1. **[NIST AI RMF 1.0](standards/NIST.AI.100-1.pdf)** — Govern, Map, Measure, Manage;
   human oversight (Map 3.5); documented roles and risk treatment.
2. **[Google SRE AI autonomy](standards/GOOGLE_SRE_AI_AUTONOMY.md)** — Safety Trifecta;
   progressive authorization L0–L4; no jump to L3 without evidence.

If any Cursor rule, plan, or code path conflicts with this doc on **oversight or
autonomy**, **this doc wins** (after RULE #1 for vendor tool behavior).

## NIST functions → ALFa

| RMF function | ALFa requirement |
|--------------|------------------|
| **Govern** | Named owners; kill switches; this doc + [AI_AUTONOMY_AND_OVERSIGHT.md](AI_AUTONOMY_AND_OVERSIGHT.md) |
| **Map** | Every AI surface listed with risk tier, human gate, blast radius |
| **Measure** | Audit trails (`ai_actions`, `audit_log`, incident events); SLOs in [SLO_AND_ERROR_BUDGET.md](SLO_AND_ERROR_BUDGET.md); proposal feedback |
| **Manage** | Default L1/L2; L3 only allowlisted; circuit breakers; rate limits |

## Risk tiers (actions)

| Tier | Examples | Human gate |
|------|----------|------------|
| **T0 Read** | `docker_ps`, health probe, git status, Analyze | None beyond auth |
| **T1 Ops** | `git_pull`, non-RPC `docker_restart`, notify email | Single Approve (L2) |
| **T2 Destructive** | `cluster_start`/`stop`, `brain_redeploy_api`, `run_command`, auto_fix | Explicit tier-2 confirm + Approve |
| **T3 Policy** | Kill switches (`ai_triage_enabled`, host-actions enable) | Pending + Approve (no silent chat apply) |

## Default autonomy (do not raise without operator decision)

- Alert **routing** = program (never LLM on webhook hot path).
- Alert **enrichment / suggested actions** = L1 (Analyze + briefing).
- Operator may **dual-check** suggestions with a stronger model before acting (verifier loop — industry standard HITL).
- Host mutate / PR apply / cluster orchestrator = L2 or operator-only.
- **Operator 2026-09-19 solar dump:** NIST does **not** gate victron HA packages
  or alfa-ai dump helper writes. Ask ALFa `ha_set_number` / `ha_select_option`
  (and `ha_switch_on` / `ha_switch_off`) execute immediately when HA env + token
  are on ([HOME_ASSISTANT_BRAIN_INTEGRATION.md](HOME_ASSISTANT_BRAIN_INTEGRATION.md)).
- **Operator 2026-09-15 Path B:** optional 7B/27B confirmed drafts may auto-write this
  project's workspace sandbox when simulated dump-load plugs are the only dump
  allowlist ([ALFA_7B_27B_WORK_JUDGE.md](operations/ALFA_7B_27B_WORK_JUDGE.md)).
  That does **not** grant SSH, cluster, secrets, or guest autonomy, and it does
  **not** gate dump actuation (dump works with neither 7B nor 27B).
- `ALFA_AI_INCIDENT_AUTO_FIX=false`, `ALFA_AI_HOST_ACTIONS_ENABLED=0`,
  `ALFA_AI_HOME_ASSISTANT_ENABLED=0`,
  `ALFA_AI_INCIDENT_LLM_TRIAGE=false` until explicitly enabled.
  HA device control: operator Settings + allowlist; see
  [HOME_ASSISTANT_BRAIN_INTEGRATION.md](HOME_ASSISTANT_BRAIN_INTEGRATION.md).

## Cross-repo / all hosts

alfa-ai is authoritative ([alfa-ai-authoritative.mdc](../.cursor/rules/alfa-ai-authoritative.mdc)).
After this governance lands:

1. Propagate `docs/standards/` index + this file summary into consumer repos via
   `docs/REPO_HOST_MAPPING.md` sync checklist.
2. Ensure each host clone pulls before deploy ([cluster-sync-order.mdc](../.cursor/rules/cluster-sync-order.mdc)).
3. Consumer bots remain **HTTP consumers** of brain inference — they do not gain
   silent L3 remediation rights.

## Related

- [.cursor/plans/HARNESS_CUTTING_EDGE_2026-09.md](../.cursor/plans/HARNESS_CUTTING_EDGE_2026-09.md) — conservative harness (Priority #10; planned surfaces in autonomy matrix)
- [AI_AUTONOMY_AND_OVERSIGHT.md](AI_AUTONOMY_AND_OVERSIGHT.md) — surface matrix
- [AI_ACTIONS.md](AI_ACTIONS.md) — program vs LLM for alerts
- [ADMIN_AI_HOST_ACTIONS.md](ADMIN_AI_HOST_ACTIONS.md) — L2 host actions
- [GROK_BOT_SCRIPT_LOOP.md](GROK_BOT_SCRIPT_LOOP.md) — Grok Bot names scripts; Ask ALFa runs; Reviewer audits
- [INCIDENT_RESPONSE.md](INCIDENT_RESPONSE.md) — alert loop
- [SLO_AND_ERROR_BUDGET.md](SLO_AND_ERROR_BUDGET.md)
