#!/usr/bin/env bash
# Smoke: qwen3.6-27b via LiteLLM proxy (default hub:8413).
# Usage: bash scripts/smoke-grev27-litellm-chat.sh [litellm_base_url] [api_key]
set -euo pipefail

BASE="${1:-http://hub}"
KEY="${2:-${LITELLM_API_KEY:-change-me}}"
TIMEOUT="${SMOKE_TIMEOUT_SEC:-120}"
export BASE KEY TIMEOUT

python3 - <<'PY'
import httpx, os, sys
base = os.environ["BASE"].rstrip("/")
key = os.environ["KEY"]
timeout = float(os.environ["TIMEOUT"])
body = {
    "model": "qwen3.6-27b",
    "messages": [{"role": "user", "content": "Reply with exactly: OK"}],
    "max_tokens": 8,
}
r = httpx.post(
    f"{base}/v1/chat/completions",
    headers={"Authorization": f"Bearer {key}"},
    json=body,
    timeout=timeout,
)
print("status", r.status_code)
print(r.text[:800])
sys.exit(0 if r.status_code == 200 else 1)
PY
