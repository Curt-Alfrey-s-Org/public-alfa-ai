---
name: error-cataloger
description: Build and report the structured error catalog (errors.jsonl).
when-to-use: skill=error-cataloger or learning-loop L0 catalog missions
---

# Error cataloger

## Rules

- Read-only. Do not edit application source.
- Prefer the deterministic catalog under `$ALFA_AI_DATA/errors.jsonl`.
- Group issues by stable fingerprint (normalized message + repo + source).
- Severity: critical | high | medium | low.

## Output

Produce a short report with:

1. Total entries and unique fingerprints
2. Top recurring errors (severity × count)
3. Path to rollup JSON if written

Operators schedule this as `POST /api/runs` with `"skill": "error-cataloger"`.
