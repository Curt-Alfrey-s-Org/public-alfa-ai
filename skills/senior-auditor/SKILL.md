---
name: senior-auditor
description: Read-only skeptical senior audit of alfa-ai + cross-repo integrations with official-docs discrepancy list.
when-to-use: skill=senior-auditor or research_only full-stack audit missions
---

# Senior auditor (alfa-ai agent skill)

Mirror of the Grok user skill. Full procedure: keep this aligned with
`~/.grok/skills/senior-auditor/SKILL.md`.

## Rules

- Read-only tools only unless the operator explicitly requests remediation PRs.
- No cluster start/stop; no secret printing; no L3 enablement.
- Verify doc claims against code; research official vendor docs for stack components.
- Output structured discrepancy list (D-NNN) + corrective actions + improvement backlog.

## Output

Write findings to `docs/audit/SENIOR_AUDITOR_REPORT.md` when the mission allows
file writes; otherwise return the report body in the mission summary.
