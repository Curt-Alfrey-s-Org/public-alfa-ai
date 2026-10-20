#!/usr/bin/env bash
set -euo pipefail
# Symlink VM100 alfa-ai stacks into /opt/stacks for Dockge visibility.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
STACKS_DIR="/opt/stacks"
REPO="/home/operator/alfa-ai"

for name in alfa-ai-embed alfa-ai-rerank; do
  src="$REPO/deploy/cluster-members/pool-shard-opt-in"
  target="$STACKS_DIR/$name"
  if [[ ! -d "$STACKS_DIR" ]]; then
    sudo mkdir -p "$STACKS_DIR" 2>/dev/null || mkdir -p "$STACKS_DIR"
  fi
  ln -sfn "$src" "$target" 2>/dev/null || sudo ln -sfn "$src" "$target"
  echo "symlink: $target -> $src"
done

echo "Run deploy.sh --only=dockge-agent if agent is not up."
