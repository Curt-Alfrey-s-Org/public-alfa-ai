# Archived: pre-Qwen3 Petals model flip (do not execute)

> **RETIRED 2026-07-09:** Petals/Hivemind is permanently removed from the cluster.
> This file is historical audit only.

**April 2026:** Tier **3a** was **`meta-llama/Llama-3.3-70B-Instruct`** on Petals.
This file preserves an old procedure that targeted a **72B instruct** model
from the **Qwen 2.5** HuggingFace line. It is **not** operator guidance today.

See [QWEN3_MIGRATION.md](../QWEN3_MIGRATION.md).

---

## Original Phase 4 steps (archived verbatim)

1. Pre-stage weights on `hub` HDD:
   ```bash
   HF_TOKEN=hf_xxx docker run --rm \
     -v /mnt/HDDs/Alfa-AI/models/huggingface:/hf \
     -e HF_HOME=/hf -e HUGGINGFACE_HUB_CACHE=/hf/hub -e HF_TOKEN \
     python:3.12-slim bash -c 'pip install -q "huggingface_hub>=0.25" hf_xet \
       && hf download Qwen/Qwen2.5-72B-Instruct'
   ```
2. Every worker's `.env.worker`:
   ```env
   PETALS_MODEL=Qwen/Qwen2.5-72B-Instruct
   HF_TOKEN=hf_xxx
   ```
3. On every worker host, **simultaneously**:
   ```bash
   docker compose --env-file .env.worker -f docker-compose.worker.yml \
     up -d --force-recreate petals-worker
   ```
4. Gate: `reachable_peers >= 4`, blocks `[0..80)` covered, smoke test:
   ```bash
   curl http://hub/v1/chat/completions \
     -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" \
     -d '{"model":"frontier","messages":[{"role":"user","content":"Hi"}],"max_tokens":8}'
   ```
