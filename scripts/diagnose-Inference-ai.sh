#!/usr/bin/env bash
# inference + contracts-bot diagnostic snapshot (run from inference).
set -euo pipefail

REPO="${ALFA_REPO_DIR:-/home/operator/alfa-ai}"
ENV_FILE="${ALFA_BRAIN_ENV:-/mnt/cluster/repo/alfa-ai/deploy/.env}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "== inference diagnostic ${TS} =="

echo "--- shard TCP ---"
bash "$REPO/deploy/cluster-members/_common/verify-inference-shards.sh" || true

echo "--- coordinator hub:31360 ---"
curl -fsS --max-time 8 http://hub/health && echo || echo "FAIL coordinator health"

echo "--- LiteLLM hub:8413 liveliness ---"
curl -fsS --max-time 8 http://hub/health/liveliness && echo || echo "FAIL litellm liveliness"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "$ENV_FILE"
  set +a
  echo "--- LiteLLM chat smoke (frontier-code) ---"
  python3 <<PY || echo "FAIL chat smoke"
import os, httpx, time
base = "http://hub"
key = os.environ.get("LITELLM_MASTER_KEY", "")
t0 = time.perf_counter()
r = httpx.post(
    f"{base}/v1/chat/completions",
    headers={"Authorization": f"Bearer {key}"},
    json={"model": "qwen3.6-27b", "messages": [{"role": "user", "content": "Reply OK"}], "max_tokens": 4},
    timeout=120.0,
)
elapsed = time.perf_counter() - t0
print(f"status={r.status_code} elapsed={elapsed:.1f}s")
if r.status_code != 200:
    print(r.text[:400])
else:
    u = r.json().get("usage") or {}
    comp = u.get("completion_tokens") or 0
    print(f"completion_tokens={comp} tok_s={comp/elapsed if elapsed else 0:.1f}")
PY
fi

echo "--- contracts-bot detailed health ---"
curl -fsS --max-time 15 http://127.0.0.1:8002/api/health/detailed | python3 -m json.tool 2>/dev/null | head -50 || echo "FAIL contracts-bot health"

echo "--- contracts-bot connectivity ---"
curl -fsS --max-time 15 http://127.0.0.1:8002/api/health/connectivity 2>/dev/null | python3 -m json.tool || echo "FAIL connectivity endpoint"

echo "== diagnostic done =="
