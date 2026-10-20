---
name: sleep-curator
description: Nightly memory consolidation, error rollup, and preference export (no weight train).
when-to-use: skill=sleep-curator; sleep hours; learning-loop L2
---

# Sleep curator (Tier A)

## Rules

- **No model weight updates.** Memory and JSONL only.
- Compact `implement-memory/*.md` to configured entry/byte caps.
- Extract heuristic lessons → `lessons.md`.
- Roll up `errors.jsonl` → `errors-rollup.json`.
- Export preference pairs from feedback inbox → `preference-pack.jsonl`.
- Append **morning-digest.md**.
- No public web scraping.

## Trigger

```json
POST /api/runs
{"goal": "Nightly sleep curation", "skill": "sleep-curator"}
```

Dry run (no writes except report artifact): include `dry_run` in the goal text.

## Operator flag

`ALFA_AI_SLEEP_CURATOR_ENABLED=1` is for **cron auto** scripts that pass
`--require-enabled`. Manual missions always run.
