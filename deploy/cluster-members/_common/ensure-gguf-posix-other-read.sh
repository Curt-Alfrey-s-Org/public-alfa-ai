#!/usr/bin/env bash
# Make coordinator GGUF (and split siblings) POSIX other-readable, then assert.
# Called from write-grev*-pool-env.sh so a skipped promote cannot leave 0640.
#
# Usage:
#   bash deploy/cluster-members/_common/ensure-gguf-posix-other-read.sh MODELS_DIR MODEL_FILE
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 MODELS_DIR MODEL_FILE" >&2
  exit 2
fi

MODELS_DIR="$1"
MODEL_FILE="$2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEAD="$MODELS_DIR/$MODEL_FILE"

if [[ ! -f "$LEAD" ]]; then
  echo "ERROR: missing GGUF $LEAD" >&2
  exit 1
fi

paths=("$MODELS_DIR" "$(dirname "$LEAD")" "$LEAD")
if [[ "$MODEL_FILE" =~ ^(.*)-00001-of-([0-9]+)\.gguf$ ]]; then
  prefix="${BASH_REMATCH[1]}"
  total=$((10#${BASH_REMATCH[2]}))
  for ((i = 1; i <= total; i++)); do
    printf -v shard '%s-%05d-of-%05d.gguf' "$prefix" "$i" "$total"
    paths+=("$MODELS_DIR/$shard")
  done
fi

echo "== ensure POSIX other-read on GGUF under $MODELS_DIR =="
bash "$SCRIPT_DIR/ensure-posix-other-read.sh" "${paths[@]}"
