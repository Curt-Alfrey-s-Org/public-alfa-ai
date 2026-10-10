#!/usr/bin/env bash
# Register a LoRA GGUF on the hub and update lora-adapters.json manifest.
#
# Usage (on hub):
#   bash deploy/cluster-members/_common/publish-lora-adapter-to-hub.sh \
#     /mnt/hub/alfa-ai/llama-cpp/lora/qwen36-27b/my-adapter.gguf \
#     qwen3.6-27b my-adapter-20260811 0.75
#
# Args: GGUF_PATH BASE_MODEL ADAPTER_ID EVAL_SCORE [promoted:0|1]
set -euo pipefail

if [[ $# -lt 4 ]]; then
  echo "Usage: $0 GGUF_PATH BASE_MODEL ADAPTER_ID EVAL_SCORE [promoted]" >&2
  exit 2
fi

GGUF_PATH="$1"
BASE_MODEL="$2"
ADAPTER_ID="$3"
EVAL_SCORE="$4"
PROMOTED="${5:-0}"

if [[ ! -f "$GGUF_PATH" ]]; then
  echo "ERROR: missing GGUF: $GGUF_PATH" >&2
  exit 1
fi

HUB_ROOT="${ALFA_LORA_HUB_ROOT:-/mnt/hub/alfa-ai/llama-cpp/lora}"
mkdir -p "$HUB_ROOT"

# Normalize relpath under hub root
case "$GGUF_PATH" in
  "$HUB_ROOT"/*)
    REL="${GGUF_PATH#"$HUB_ROOT"/}"
    ;;
  *)
    SUBDIR="${BASE_MODEL//./}"
    SUBDIR="${SUBDIR//-/_}"
    DEST_DIR="$HUB_ROOT/${SUBDIR}"
    mkdir -p "$DEST_DIR"
    BASENAME="$(basename "$GGUF_PATH")"
    cp -f "$GGUF_PATH" "$DEST_DIR/$BASENAME"
    REL="${SUBDIR}/${BASENAME}"
    echo "Copied to $HUB_ROOT/$REL"
    ;;
esac

MANIFEST="$HUB_ROOT/lora-adapters.json"
python3 - "$MANIFEST" "$ADAPTER_ID" "$BASE_MODEL" "$REL" "$EVAL_SCORE" "$PROMOTED" <<'PY'
import json
import sys
from datetime import UTC, datetime
from pathlib import Path

manifest, adapter_id, base_model, relpath, eval_score, promoted = sys.argv[1:7]
path = Path(manifest)
data = {"adapters": [], "updated_at": ""}
if path.is_file():
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        pass
adapters = [a for a in data.get("adapters", []) if a.get("adapter_id") != adapter_id]
adapters.append(
    {
        "adapter_id": adapter_id,
        "base_model": base_model,
        "gguf_relpath": relpath,
        "eval_score": float(eval_score),
        "promoted": promoted in ("1", "true", "yes"),
        "created_at": datetime.now(tz=UTC).isoformat(),
        "notes": "publish-lora-adapter-to-hub.sh",
    }
)
data["adapters"] = adapters
data["updated_at"] = datetime.now(tz=UTC).isoformat()
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
print(f"Updated {path}")
PY

echo "LoRA adapter registered: $ADAPTER_ID (eval=$EVAL_SCORE promoted=$PROMOTED)"
echo "Set LORA_GGUF=$(basename "$REL") in .env.rpc after full cluster stop, then start."
