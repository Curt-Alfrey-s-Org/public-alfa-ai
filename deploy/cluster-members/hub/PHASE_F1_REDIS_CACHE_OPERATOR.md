# Phase F1 - LiteLLM Redis response cache (hub brain)

Run on **hub shell as `operator`** after `git pull`.

Prerequisites:

- `alfa-ai-redis` healthy in brain compose (same stack as LiteLLM)
- `REDIS_PASSWORD` set in `deploy/.env`

## F1a - Deploy config

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai && git pull --ff-only origin main
cd deploy && sudo docker compose --env-file .env -f docker-compose.yml up -d --force-recreate alfa-ai-litellm
bash ../deploy/cluster-members/_common/wait-litellm-liveliness.sh 120
```

## F1b - Acceptance (embed cache hit)

Two identical embed requests; second should be much faster and LiteLLM logs a cache hit.

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai && set -a && . deploy/.env && set +a
BODY='{"model":"embed","input":"cache-smoke-test-phrase"}'
curl -fsS --max-time 120 -X POST http://127.0.0.1:8413/v1/embeddings \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" -d "$BODY" >/dev/null
time curl -fsS --max-time 30 -X POST http://127.0.0.1:8413/v1/embeddings \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" -d "$BODY" >/dev/null
sudo docker logs alfa-ai-litellm --tail 30 2>&1 | grep -i cache
```

Second `curl` should complete in under a few seconds if Redis cache is working.
