# Google SRE — AI autonomy levels (cluster extract)

**Official source (read first):**  
[AI in SRE: How Google is Engineering the Future of Reliable Operations](https://sre.google/resources/practices-and-processes/ai-engineering-reliable-operations/)  
Authors: Papapanagiotou, Malesevic, Heiser, Meshenberg (Google).

**Foundational SRE (CC BY 4.0):**  
[Site Reliability Engineering book](https://sre.google/sre-book/table-of-contents/) — SLOs, error budgets, toil, monitoring.  
[SRE Workbook](https://sre.google/workbook/table-of-contents/).

This file is a **cluster-facing extract** for agents and operators. It does not replace
the official pages. When this extract and the live Google page disagree, **the live
Google page wins** (RULE #1).

## Safety Trifecta (required for any AI that can touch production)

1. **Transparency** — Log chain of thought / reasons, signals used, confidence, and
   deterministic actuation traces. Every decision must be auditable.
2. **Real-time risk evaluation** — Assess proposed actions against context (deployments,
   error budget, active incidents, time of day).
3. **Progressive authorization** — Do not grant full production access on day one.
   Advance autonomy levels only after measured success.

## Architectural guardrails (Google)

- No ambient access / least privilege — agent identity distinct from human operators
- Agentic circuit breakers — rate limits; actions interruptible
- Mandatory dry-run support where APIs allow
- Zero-trust, safe-by-default actuation — mutate only through controlled paths

## Autonomy levels (L0–L4)

| Level | Monitor | Investigate | Mitigate / decide | Actuate | Self-direct |
|-------|---------|-------------|-------------------|---------|-------------|
| **L0** Manual | Auto or human | Human | Human | Human | Human |
| **L1** Assisted | Auto | Auto (enrich / suggest) | Human | Human | Human |
| **L2** Partial | Auto | Auto | Human **approves** | Auto (after approve) | Human |
| **L3** High | Auto | Auto | Auto (bounded) | Auto | Human (novel cases) |
| **L4** Full | Auto | Auto | Auto | Auto | Auto |

**ALFa default posture (2026-07):** **L1** for alert enrichment and Analyze suggestions;
**L2** for host actions and remediation PRs; **L3 only** for hand-written playbook
`auto_fix` after drills and explicit per-alert enable — never by default.

**Operator 2026-09-15:** HA allowlisted switches / dump tick are L3 device actuate.
Path B 7B/27B **confirmed** drafts are L3 **project sandbox writes** gated by simulated
dump-load plugs ([AI_AUTONOMY_AND_OVERSIGHT.md](../AI_AUTONOMY_AND_OVERSIGHT.md)). Neither
is L4 self-direct over SSH, inference, or production `.env`.

## ALFa surface mapping

| Surface | Target level | Notes |
|---------|--------------|-------|
| Alertmanager webhook → incident + playbook investigate | L1 | Program probes; no LLM on hot path |
| Programmatic severity / notify routing | L1 | Deterministic |
| Monitoring **Analyze** (suggestions) | L1 | Operator-triggered enrichment |
| Dual-check with stronger external model | L1 verifier | Operator paste; industry HITL |
| Ask ALFa host actions (catalog) | L2 | Approve every time |
| Ask ALFa Path B `draft-judge:` | L3 sandbox | Auto-write confirmed drafts when sim dump plugs are the rail; not SSH |
| Ask ALFa `run_command` | L2 (high risk) | Default disabled; tier-2 confirm |
| Remediation Apply → GitHub PR | L2 | Opens PR only; merge is human |
| Incident `auto_fix` | L3 candidate | Off until allowlisted + drilled |
| `/api/runs` agent `run_cmd` | Must not be silent L3 | Enforce tool allowlists + gates |

## Related

- [AI_GOVERNANCE.md](../AI_GOVERNANCE.md)
- [AI_AUTONOMY_AND_OVERSIGHT.md](../AI_AUTONOMY_AND_OVERSIGHT.md)
- [NIST AI RMF PDFs](README.md)
