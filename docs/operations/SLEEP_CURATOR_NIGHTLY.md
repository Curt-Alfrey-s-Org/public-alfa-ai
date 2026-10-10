# Sleep curator nightly (learning-loop L2 / Tier A)

Consolidate mission memory, error catalogs, and preference packs during idle hours.
**No weight training** (Tier B = alfa-train on Blackwell trainer island — full 40 GB pool or 32 GB gaming subset).

SSoT: [.cursor/plans/LEARNING_LOOP_JUDGE_SLEEP.md](../../.cursor/plans/LEARNING_LOOP_JUDGE_SLEEP.md).

## What it does

| Step | Output under `$ALFA_AI_DATA` (default `.alfa_ai/`) |
|------|-----------------------------------------------------|
| Compact implement-memory | `implement-memory/*.md` trimmed to max entries/bytes |
| Lessons | `lessons.md` |
| Error rollup | `errors-rollup.json` |
| Preference export | `preference-pack.jsonl` (from `feedback.jsonl`) |
| Digest | `morning-digest.md`, `sleep-curator-last.json` |

## Manual mission (always allowed)

```bash
export ALFA_TOKEN='…'
export ALFA_API='http://hub'

curl -sS -X POST "$ALFA_API/api/runs" \
  -H "Authorization: Bearer $ALFA_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"goal":"Nightly sleep curation","skill":"sleep-curator"}'

curl -sS -X POST "$ALFA_API/api/runs/process-next" \
  -H "Authorization: Bearer $ALFA_TOKEN"
```

Dry run (goal must contain `dry_run`):

```json
{"goal": "sleep curator dry_run", "skill": "sleep-curator"}
```

## CLI on brain host

```bash
cd /path/to/alfa-ai
python scripts/sleep_curator_nightly.py --dry-run
python scripts/sleep_curator_nightly.py
python scripts/sleep_curator_nightly.py --require-enabled   # for cron
```

## Env

```env
# deploy/.env on hub
ALFA_AI_SLEEP_CURATOR_ENABLED=0   # set 1 only for auto cron
# ALFA_AI_DATA=/mnt/ssd/alfa-ai/data
# ALFA_AI_MEMORY_MAX_ENTRIES=50
# ALFA_AI_MEMORY_MAX_FILE_BYTES=65536
```

## Cron example (operator-owned)

```cron
# 03:30 UTC nightly Tier A (requires ALFA_AI_SLEEP_CURATOR_ENABLED=1)
30 3 * * * cd /opt/alfa-ai && /usr/bin/python3 scripts/sleep_curator_nightly.py --require-enabled >> /var/log/alfa-sleep-curator.log 2>&1
```

Or enqueue via API from a root-only script (same pattern as [SCHEDULED_AUDIT_MISSIONS.md](SCHEDULED_AUDIT_MISSIONS.md)).

## Explicit non-goals

- QLoRA / DPO (Tier B — alfa-train)
- Public web scraping
- Enabling mutate or host actions
- Replacing production 27B

## After sleep: stage Tier B pack (optional)

```bash
python scripts/export_train_pack.py
```

See [SLEEP_TRAIN_TIER_B.md](SLEEP_TRAIN_TIER_B.md).

## Related

- [SCHEDULED_AUDIT_MISSIONS.md](SCHEDULED_AUDIT_MISSIONS.md)
- [JUDGE_INSTALL_59.md](JUDGE_INSTALL_59.md)
- [SLEEP_TRAIN_TIER_B.md](SLEEP_TRAIN_TIER_B.md)
- [AGENT_RESEARCH_TOOLS.md](../AGENT_RESEARCH_TOOLS.md) (implement-memory)
