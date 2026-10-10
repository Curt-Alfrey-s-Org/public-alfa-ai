# Learning loop — operator checklist

Software (L0–L3 wiring) is in git. This checklist is **deploy + live ops**.

SSoT: [.cursor/plans/LEARNING_LOOP_JUDGE_SLEEP.md](../../.cursor/plans/LEARNING_LOOP_JUDGE_SLEEP.md).

## A. Software preflight (any host with repo)

```bash
cd /path/to/alfa-ai
python scripts/learning_loop_preflight.py
python scripts/eval/smoke_runner.py --self-check
```

Expect preflight all OK and eval **10/10**.

## B. Brain deploy (`hub`)

1. `git pull` brain clone.
2. Merge `deploy/env.example` notes into `deploy/.env` (do not enable judge/mutate by default).
3. Set `ALFA_AI_FLYWHEEL_ENABLED=1` when ready for nightly Tier A + hub publish.
4. Recreate `alfa-ai-api` + LiteLLM (picks up `alfa-coder-draft` alias + agent review router).
5. Confirm:
   - `POST /api/runs` with Bearer works
   - `POST /api/agent/review` with Bearer works (may need inference up)

## B2. L2 flywheel + hub publish (`hub`)

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai
bash scripts/learning_loop_tier_a.sh
```

Verify latest pack on hub:

```bash
ls -lt /mnt/HDDs/Alfa-AI/training/alfa-train/datasets/from-alfa-ai/ | head
python3 -c "import json; m=json.load(open('$(cat /mnt/HDDs/Alfa-AI/agent-audit-logs/train-export/LATEST.txt)/MANIFEST.json')); print(m.get('schema_version'), m.get('scan_pass'))"
```

Expect `schema_version` `1` and `scan_pass.ok` true after publish. See [TRAIN_PACK_MANIFEST.md](TRAIN_PACK_MANIFEST.md).

Admin status (after brain recreate; admin JWT):

```bash
curl -fsS -H "Authorization: Bearer $T" \
  http://127.0.0.1:8420/alfa-ai/api/admin/learning-loop/status
```

Thumbs on Analyze proposals and host actions also append `feedback.jsonl` (DPO source).

## C. Day missions (mutate off)

```bash
# Audit
curl -X POST "$ALFA_API/api/runs" -H "Authorization: Bearer $T" \
  -H "Content-Type: application/json" \
  -d '{"goal":"Audit deploy secrets drift","skill":"audit-repo","research_only":true}'

# Error catalog + corrective
# skill=error-cataloger then skill=corrective-analyst

# Sleep curator (or CLI)
python scripts/sleep_curator_nightly.py --dry-run
python scripts/export_train_pack.py
```

## D. OP-LL-1 Judge (when `gaming-c` free)

Follow [JUDGE_INSTALL_59.md](JUDGE_INSTALL_59.md). Keep `ALFA_AI_JUDGE_ENABLED=0` until smoke.

## E. OP-LL-3 Train night (when trainer island free)

Follow [SLEEP_TRAIN_TIER_B.md](SLEEP_TRAIN_TIER_B.md) + alfa-train `SLEEP_TIER_B_FROM_ALFA_AI.md`.  
Do not change `DEFAULT_MODEL`. Promote [ALFA_CODER_DRAFT_ALIAS.md](ALFA_CODER_DRAFT_ALIAS.md) only after ≥70% eval.

## F. contracts-bot consumer (`apps`)

```env
ALFA_AI_ORCHESTRATOR_ENABLED=true
ALFA_AI_API_TOKEN=…
ALFA_AI_REVIEW_ENABLED=true
ALFA_AI_REVIEW_REPO=contracts-bot
```

Brain: `ALFA_AI_AUDIT_ROOTS=contracts-bot=/path/to/contracts-bot`  
API: `POST /api/ai/review` (see contracts-bot `docs/ALFA_AI_REVIEW_CLIENT.md`).

## Explicit never

- `ALFA_AI_AGENT_MUTATE_ENABLED=1` on scheduled jobs without human
- Judge auto-approve host actions
- `DEFAULT_MODEL=alfa-coder-draft` before promote
- Unattended public scraping
