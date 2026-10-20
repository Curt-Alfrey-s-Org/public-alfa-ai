# Train pack MANIFEST contract (alfa-train ingest)

> **Status:** Schema v1 (2026-08-11). alfa-ai **export** writes MANIFEST; **publish**
> adds `scan_pass`. alfa-train ingest should assert `schema_version` before train.

Related: [SLEEP_TRAIN_TIER_B.md](SLEEP_TRAIN_TIER_B.md),
[DATA_FLYWHEEL_OPERATOR.md](DATA_FLYWHEEL_OPERATOR.md),
[train_export.py](../../src/runtime/train_export.py).

## Pack layout

```
<UTC-timestamp>/
  MANIFEST.json
  preference-pack.jsonl
  preference-dpo.jsonl
  lessons.md
  lessons-chat-sft.jsonl
  error-fix-chat-sft.jsonl
  README.md
  export-report.json
```

Hub path after publish:

```text
/mnt/HDDs/Alfa-AI/training/alfa-train/datasets/from-alfa-ai/<UTC-timestamp>/
```

## MANIFEST.json fields (schema_version `"1"`)

| Field | Required | Set by | Notes |
|-------|----------|--------|-------|
| `schema_version` | yes | export | Always `"1"` for this contract |
| `created_at` | yes | export | ISO-8601 UTC |
| `pack_id` | yes | export | Directory basename (`YYYYMMDDTHHMMSSZ`) |
| `git_sha` | no | export | Short commit when available |
| `base_model_target` | yes | export | Intended train base (e.g. `qwen3.6-27b`) |
| `hub_hint` | yes | export | Documented hub training tree |
| `counts` | yes | export | Row counts per derived file |
| `files` | yes | export | **Relative** filenames + bytes + sha256 |
| `feedback_inbox_rows` | yes | export | Rows in feedback.jsonl |
| `preference_pairs_live` | yes | export | Parsed preference pairs |
| `scan_pass` | yes after publish | publish | `{ok, tool, hit_count, scanned_at}` |

`files.*.path` is **relative to pack root** (e.g. `preference-dpo.jsonl`), not an absolute host path.

## Publish gate

[scripts/publish_train_pack_to_hub.sh](../../scripts/publish_train_pack_to_hub.sh):

1. Runs [scan_pass_jsonl.py](../../scripts/scan_pass_jsonl.py) on the pack.
2. Fails if secrets detected (`exit 1`).
3. rsync to hub training path.
4. Patches `MANIFEST.json` with `scan_pass` on hub copy.

## Operator flow

```bash
# Tier A (export + staging + publish when not --skip-publish)
bash scripts/learning_loop_tier_a.sh

# Manual publish only
bash scripts/publish_train_pack_to_hub.sh
```

## alfa-train ingest (sibling repo)

Ingest should verify:

- `schema_version == "1"`
- `scan_pass.ok == true` (or absent only for legacy packs pre-publish)
- Required files present in `files` with matching sha256

See alfa-train `docs/SLEEP_TIER_B_FROM_ALFA_AI.md`.
