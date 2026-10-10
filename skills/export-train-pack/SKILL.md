---
name: export-train-pack
description: Stage preference/lesson/error JSONL for alfa-train (L3). Does not train.
when-to-use: skill=export-train-pack after sleep-curator or before trainer night
---

# Export train pack (Tier B staging)

## Rules

- **No GPU training** on the brain.
- Refresh preference pack from feedback inbox when possible.
- Write under `$ALFA_AI_DATA/train-export/<timestamp>/` with MANIFEST + hashes.
- Operator copies pack to hub; alfa-train `ingest_alfa_ai_pack.py` on `gaming-c`.

## Trigger

```json
POST /api/runs
{"goal": "Export train pack for alfa-train", "skill": "export-train-pack"}
```

CLI: `python scripts/export_train_pack.py`
