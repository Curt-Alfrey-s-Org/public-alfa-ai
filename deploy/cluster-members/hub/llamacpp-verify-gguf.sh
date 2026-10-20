#!/usr/bin/env bash
# Verify Qwen3-Coder-Next Q4_K_M four-shard layout on the hub hub (no network).
set -euo pipefail
DIR="${1:-/mnt/hub/alfa-ai/llama-cpp/models/Qwen3-Coder-Next-Q4_K_M}"
ok=1
for i in 1 2 3 4; do
  f=$(printf '%s/Qwen3-Coder-Next-Q4_K_M-%05d-of-00004.gguf' "$DIR" "$i")
  if [[ -f "$f" ]]; then
    echo "OK $f ($(du -h "$f" | awk '{print $1}'))"
  else
    echo "MISSING $f" >&2
    ok=0
  fi
done
if [[ "$ok" -eq 1 ]]; then
  echo "Total: $(du -sh "$DIR" | awk '{print $1}')"
  exit 0
fi
exit 1
