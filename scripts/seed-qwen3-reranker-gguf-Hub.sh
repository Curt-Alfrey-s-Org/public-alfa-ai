#!/usr/bin/env bash
# hub hub only -- download Qwen3-Reranker-0.6B GGUF into hub reranker dir.
#
# Usage (on hub as root):
#   cd /mnt/hub/alfa-ai/repo/alfa-ai
#   sudo bash scripts/seed-qwen3-reranker-gguf-hub.sh
#
# Output: /mnt/hub/alfa-ai/models/downloads/reranker/Qwen3-Reranker-0.6B.Q4_K_M.gguf
# NFS clients: /mnt/cluster/models/downloads/reranker/
#
# Official HF CLI: https://huggingface.co/docs/huggingface_hub/guides/cli
# Model card: https://huggingface.co/Qwen/Qwen3-Reranker-0.6B
set -euo pipefail

HUB_ROOT="${HUB_ROOT:-/mnt/hub/alfa-ai}"
DEST="${HUB_ROOT}/models/downloads/reranker"
REPO="${RERANK_GGUF_REPO:-QuantFactory/Qwen3-Reranker-0.6B-GGUF}"
FILE="${RERANK_GGUF_FILE:-Qwen3-Reranker-0.6B.Q4_K_M.gguf}"
HF_IMAGE="${HF_SEED_IMAGE:-python:3.11-slim}"
ENV_FILE="${HUB_ROOT}/repo/alfa-ai/deploy/.env"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

echo "== seed-qwen3-reranker-gguf-hub.sh =="
echo "  hub:  $HUB_ROOT"
echo "  dest: $DEST"
echo "  repo: $REPO"
echo "  file: $FILE"

[[ "$(id -u)" -eq 0 ]] || die "run as root on hub (sudo bash $0)"

mkdir -p "$DEST"
out="$DEST/$FILE"

if [[ -f "$out" ]]; then
  echo "Already present: $out ($(du -h "$out" | awk '{print $1}'))"
  ls -la "$DEST"
  exit 0
fi

token="change-me"
if [[ -z "$token" && -f "$ENV_FILE" ]]; then
  token="$(grep -E '^HF_TOKEN='change-me'\r' || true)"
fi
if [[ -n "$token" ]]; then
  echo "  auth:  HF_TOKEN set (from env or $ENV_FILE)"
else
  echo "  auth:  no HF_TOKEN (public repo; download may still work)"
fi

command -v docker >/dev/null 2>&1 || die "docker not on PATH on hub"
echo "  check: docker CLI present"
if ! docker info >/dev/null 2>&1; then
  die "docker daemon not reachable on hub (start Docker/Apps engine)"
fi
echo "  check: docker daemon OK"

echo "  runner: docker ($HF_IMAGE)"
docker run --rm \
  -v "$DEST:/out" \
  ${token:+-e HF_TOKEN="$token"} \
  ${token:+-e HUGGING_FACE_HUB_TOKEN="$token"} \
  -e HF_HUB_ENABLE_HF_TRANSFER=1 \
  -e HF_REPO_ID="$REPO" \
  -e HF_FILENAME="$FILE" \
  -e PIP_DISABLE_PIP_VERSION_CHECK=1 \
  "$HF_IMAGE" \
  bash -lc '
    set -euo pipefail
    pip install --quiet --no-cache-dir "huggingface_hub>=1.11" hf_transfer
    python3 - <<PY
import os
from huggingface_hub import hf_hub_download

repo = os.environ["HF_REPO_ID"]
fname = os.environ["HF_FILENAME"]
dest = "/out"
print(f"hf_hub_download(repo_id={repo!r}, filename={fname!r}, local_dir={dest!r})")
path = hf_hub_download(
    repo_id=repo,
    filename=fname,
    local_dir=dest,
    local_dir_use_symlinks=False,
)
print(f"downloaded: {path}")
PY
  '

if [[ ! -f "$out" ]]; then
  echo "WARN: expected $out missing; searching $DEST ..." >&2
  find "$DEST" -maxdepth 2 -type f -name "Qwen3-Reranker*.gguf" -print >&2 || true
  alt="$(find "$DEST" -maxdepth 2 -type f -name "Qwen3-Reranker*.gguf" | head -1 || true)"
  [[ -n "$alt" ]] || die "download finished but no Qwen3-Reranker*.gguf under $DEST"
  if [[ "$alt" != "$out" ]]; then
    echo "  linking $alt -> $out"
    ln -sf "$(basename "$alt")" "$out"
  fi
fi

chown operator:wheel "$out" 2>/dev/null || true
chmod 644 "$out" 2>/dev/null || true

echo "OK: $out ($(du -h "$out" | awk '{print $1}'))"
ls -la "$DEST"
