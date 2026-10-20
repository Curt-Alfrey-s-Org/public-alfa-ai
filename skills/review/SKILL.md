---
name: review
description: Read-only code review with structured issues.
when-to-use: review missions or skill=review
---

# Review

## Rules

- Read-only tools only.
- Review for correctness, security, and maintainability.
- Prefer evidence from repo files over assumptions.

## Output

Use this issue format:

```
### Issue N — Severity: bug|suggestion|nit
- File: path:line
- Description: ...
- Suggestion: ...
- Status: open
```