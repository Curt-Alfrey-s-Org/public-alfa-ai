---
name: corrective-analyst
description: Turn error catalog fingerprints into ordered corrective actions.
when-to-use: skill=corrective-analyst after error-cataloger
---

# Corrective analyst

## Rules

- Read-only. Propose only — never apply patches unless a separate implement workflow is approved.
- Group by fingerprint; rank by severity then count.
- Each action must include acceptance criteria (command or test to re-run).

## Output

`corrective_actions.md` with sections:

```
## Action N — severity (count=K)
- Fingerprint
- Summary
- Evidence
- Proposed steps (numbered)
- Acceptance: ...
```

Human gate required before any mutate implement run.
