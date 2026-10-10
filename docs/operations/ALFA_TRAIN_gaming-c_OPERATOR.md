# alfa-train on gaming-c (gaming-worker-c) — OP-LL-3 operator steps

Hub pack published from `hub` (example):

```text
/mnt/HDDs/Alfa-AI/training/alfa-train/datasets/from-alfa-ai/20260714T140501Z/
```

SMB from Windows workers (when share exists):

```text
\\hub\training\alfa-train\datasets\from-alfa-ai\20260714T140501Z
```

## Step 1 — Preflight (From `gaming-c`)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\alfa-ai-train\..\alfa-ai\deploy\cluster-members\gaming-worker-c\learning-loop-trainer-preflight.ps1
```

If `alfa-train` is missing:

```powershell
git clone https://github.com/example/alfa-train.git C:\alfa-ai-train
cd C:\alfa-ai-train
git pull --ff-only origin main
```

## Step 2 — Ingest pack (GPU idle; no inference on this host)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:/Users/operator\alfa-ai\deploy\cluster-members\gaming-worker-c\run-qlora-night.ps1 -PackDir \\hub\training\alfa-train\datasets\from-alfa-ai\20260714T140501Z
```

Or copy pack locally first, then:

```powershell
cd C:\alfa-ai-train
python scripts\ingest_alfa_ai_pack.py --pack C:\alfa-ai-cache\train-packs\20260714T140501Z --merge-into data
```

## Step 3 — Train

Follow `alfa-train` GETTING_STARTED / `pool-7b-qlora-sft` when ingest succeeds.

## Step 4 — Eval gate (do not promote `frontier-code`)

On any clone with answers JSONL from base vs checkpoint:

```bash
python scripts/eval/train_checkpoint_gate.py --answers-base base.jsonl --answers-checkpoint ckpt.jsonl
```

`promote_allowed=true` required before optional `alfa-coder-draft` alias.

## Related

- [SLEEP_TRAIN_TIER_B.md](SLEEP_TRAIN_TIER_B.md)
- [ALFA_CODER_DRAFT_ALIAS.md](ALFA_CODER_DRAFT_ALIAS.md)
