# Official standards library (binding)

**Purpose:** Local copies and cluster mappings of **NIST AI RMF** and **Google SRE**
AI-ops autonomy guidance. These materials **override** conflicting repo docs, Cursor
rules, and plans on **AI oversight, progressive autonomy, and human approval** for
production actions.

**Authority stack:** See [AI_GOVERNANCE.md](../AI_GOVERNANCE.md) and
[.cursor/rules/RULES.md](../../.cursor/rules/RULES.md). Tier **1b** (this library)
sits immediately under RULE #1 (vendor tool manuals) for **AI risk / SRE autonomy**.

## Downloaded manuals (in this directory)

| File | Source | Notes |
|------|--------|-------|
| [NIST.AI.100-1.pdf](NIST.AI.100-1.pdf) | [nvlpubs.nist.gov](https://nvlpubs.nist.gov/nistpubs/ai/NIST.AI.100-1.pdf) | NIST AI Risk Management Framework (AI RMF 1.0) |
| [NIST-AI-RMF-Playbook.pdf](NIST-AI-RMF-Playbook.pdf) | [airc.nist.gov](https://airc.nist.gov/docs/AI_RMF_Playbook.pdf) | AI RMF Playbook (Govern / Map / Measure / Manage actions) |

US government works: public domain. Re-download if files are missing:

```bash
curl -fsSL -o docs/standards/NIST.AI.100-1.pdf \
  https://nvlpubs.nist.gov/nistpubs/ai/NIST.AI.100-1.pdf
curl -fsSL -o docs/standards/NIST-AI-RMF-Playbook.pdf \
  https://airc.nist.gov/docs/AI_RMF_Playbook.pdf
```

## Online authorities (must stay current)

| Standard | URL | Cluster use |
|----------|-----|-------------|
| NIST AI RMF Core | https://airc.nist.gov/airmf-resources/airmf/5-sec-core/ | Govern / Map / Measure / Manage |
| Google SRE — AI reliable operations | https://sre.google/resources/practices-and-processes/ai-engineering-reliable-operations/ | Safety Trifecta, L0–L4 autonomy |
| Google SRE Book (CC BY 4.0) | https://sre.google/sre-book/table-of-contents/ | SLOs, error budgets, toil, alerting |
| Google SRE Workbook | https://sre.google/workbook/table-of-contents/ | Practical SLO / incident practices |
| Cluster mapping | [GOOGLE_SRE_AI_AUTONOMY.md](GOOGLE_SRE_AI_AUTONOMY.md) | L0–L4 applied to alfa-ai surfaces |

## Related cluster docs

| Doc | Role |
|-----|------|
| [AI_GOVERNANCE.md](../AI_GOVERNANCE.md) | Binding NIST + SRE policy for all ALFa repos/hosts |
| [AI_AUTONOMY_AND_OVERSIGHT.md](../AI_AUTONOMY_AND_OVERSIGHT.md) | Per-surface autonomy matrix + kill switches |
| [SLO_AND_ERROR_BUDGET.md](../SLO_AND_ERROR_BUDGET.md) | Reliability targets |
| [STABLE_RELEASES.md](../STABLE_RELEASES.md) | Numbered stable pins; no beta fleet for upstream |
| [.cursor/plans/COMPOSER_NIST_SRE_ALIGNMENT.md](../../.cursor/plans/COMPOSER_NIST_SRE_ALIGNMENT.md) | Composer 2.5 fix backlog |

## Refresh policy

When NIST or Google publish a new edition, update the PDF (or dated extract), bump the
"Last synced" line below, and re-check the Composer plan for new gaps.

**Last synced:** 2026-07-10
