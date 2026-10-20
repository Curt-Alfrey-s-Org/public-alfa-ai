# Sleep train Tier B (OP-LL-3) — QLoRA from learning-loop data

**Code does not train on the brain.** This runbook stages packs for **alfa-train** on the Blackwell trainer island.

| Pool tier | Hosts | VRAM | When |
|-----------|-------|------|------|
| **Full Blackwell** | `gaming-c` / `gaming-b` / `gaming-a` / **`inference` GPU 0** | **40 GB** | Full cluster **stop** first (`Start-Stop-AlfaAi.ps1 stop` from `orchestrator`) |
| **Gaming subset** | `gaming-c` / `gaming-b` / `gaming-a` | **32 GB** | inference can stay up; no `inference` |

SSoT plan: [.cursor/plans/LEARNING_LOOP_JUDGE_SLEEP.md](../../.cursor/plans/LEARNING_LOOP_JUDGE_SLEEP.md) Phase L3.  
alfa-train detail: sibling repo `docs/SLEEP_TIER_B_FROM_ALFA_AI.md`.

## Prerequisites

| Item | Notes |
|------|--------|
| L0–L2 | Catalog, feedback thumbs, sleep-curator producing lessons/prefs |
| Hub | hub path for datasets (hub-first) |
| Trainer hosts | Idle Blackwell GPUs; gaming subset = no inference on `gaming-c`/`gaming-b`/`gaming-a`; full pool = cluster stopped including `inference` GPU 0 |
| Secret scan | Review JSONL before train |

## Step A — Export + publish (brain)

```bash
cd /path/to/alfa-ai
bash scripts/learning_loop_tier_a.sh
```

This exports inside `alfa-ai-api`, copies to
`/mnt/HDDs/Alfa-AI/agent-audit-logs/train-export/<timestamp>/`, then runs
`publish_train_pack_to_hub.sh` (secret scan + rsync) unless `--skip-publish`.

Or stepwise:

```bash
python scripts/clear_stuck_missions.py
python scripts/sleep_curator_nightly.py
python scripts/export_train_pack.py
```

Default export staging on `hub` (operator-writable):

```text
/mnt/HDDs/Alfa-AI/agent-audit-logs/train-export/<UTC-timestamp>/
```

Hub publish target (created on first `publish_train_pack_to_hub.sh` if missing):

```text
/mnt/HDDs/Alfa-AI/training/alfa-train/datasets/from-alfa-ai/<UTC-timestamp>/
```

Env override: `ALFA_AI_TRAIN_EXPORT_PATH`.

MANIFEST contract: [TRAIN_PACK_MANIFEST.md](TRAIN_PACK_MANIFEST.md) (`schema_version`, relative
paths, `scan_pass` after publish).

## Step B — Publish to hub (manual override)

Normally done by `learning_loop_tier_a.sh`. Run alone when re-publishing a staging pack:

```bash
bash scripts/publish_train_pack_to_hub.sh
```

Runs `scan_pass_jsonl.py` then rsyncs to
`/mnt/HDDs/Alfa-AI/training/alfa-train/datasets/from-alfa-ai/<timestamp>/`.
Do not invent multi-GB download locations for base models — seed bases via existing hub policy.

## Step C — Ingest + train (`gaming-c` or full pool via GUI)

**7B from `orchestrator` desktop:** [TRAIN_7B_QLORA_GUI.md](TRAIN_7B_QLORA_GUI.md)
(`gaming-c`/`gaming-b`, optional `gaming-a`; core 27B stays up; `alfa-train.lock`; Axolotl torchrun).

Preflight:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\gaming-worker-c\learning-loop-trainer-preflight.ps1
```

Train night:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\gaming-worker-c\run-qlora-night.ps1 -PackDir \\hub\training\alfa-train\datasets\from-alfa-ai\<timestamp>
```

Or manually:

```powershell
cd C:\alfa-ai-train
python scripts\ingest_alfa_ai_pack.py --pack <hub-or-local-pack> --merge-into data
# Then GETTING_STARTED / pool-7b-qlora-sft as appropriate
```

## Step D — Eval gate

```bash
python scripts/eval/train_checkpoint_gate.py --answers-base base.jsonl --answers-checkpoint ckpt.jsonl
```

- Compare checkpoint vs base on held-out prompts (**≥70%**).
- **Do not** point production `frontier-code` at the new weights until gate + operator decision.
- Optional draft alias: **`alfa-coder-draft`** (stub today → real weights after promote).
  See [ALFA_CODER_DRAFT_ALIAS.md](ALFA_CODER_DRAFT_ALIAS.md).

## Scheduling reality

Gaming hosts are intermittent. Jobs must be:

- Hub-checkpointed  
- Interruptible  
- Prefer weekends / known free windows  

Do not run train and judge Ollama on `gaming-c` simultaneously if VRAM is tight.

## Mission hook (optional)

After sleep-curator:

```json
{"goal": "Export train pack for alfa-train", "skill": "export-train-pack"}
```

(If skill not deployed yet, use the CLI above.)

## Related

- [SLEEP_CURATOR_NIGHTLY.md](SLEEP_CURATOR_NIGHTLY.md)
- [TRAIN_PACK_MANIFEST.md](TRAIN_PACK_MANIFEST.md)
- [JUDGE_INSTALL_59.md](JUDGE_INSTALL_59.md)
- [ALFA_TRAIN_59_OPERATOR.md](ALFA_TRAIN_59_OPERATOR.md)
- alfa-train [SLEEP_TIER_B_FROM_ALFA_AI.md](../../../alfa-train/docs/SLEEP_TIER_B_FROM_ALFA_AI.md)
