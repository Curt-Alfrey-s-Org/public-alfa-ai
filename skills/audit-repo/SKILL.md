---
name: audit-repo
description: Read-only repository audit with structured findings.
when-to-use: research_only missions or skill=audit-repo
---

# Audit repo

## Rules

- Read-only: use `grep_repo`, `glob_files`, `read_file`, `list_dir`, `fetch_url`, and `web_search` (when `ALFA_AI_WEB_SEARCH_ENABLED=1`) only.
- Do not use `create_file`, `edit_file`, or `run_cmd`.
- Search the workspace before fetching external docs.
- On brain `hub`, the hub clone is mounted at `alfa-ai/` (see `ALFA_AI_AUDIT_ROOTS`). Use paths like `alfa-ai/deploy/**` and `alfa-ai/docs/**`.

## Output

End with a **Findings** section. For each issue use **exactly** this shape
(parsed by export/judge and shown in Admin -> Missions Findings inbox):

```
### Finding N - Severity: bug|suggestion|nit
- File: path:line
- Description: what is wrong or risky
- Suggestion: concrete fix the operator would take (propose only; do not apply)
```

Severity: `bug` (high), `suggestion` (medium), `nit` (low). If the audit root
is empty or unmounted, emit Finding 1 with Severity `bug` describing the gap and
a Suggestion to fix mounts/`ALFA_AI_AUDIT_ROOTS` -- do not invent code issues.

Include a **Sources** section listing repo paths and any allowlisted URLs consulted.