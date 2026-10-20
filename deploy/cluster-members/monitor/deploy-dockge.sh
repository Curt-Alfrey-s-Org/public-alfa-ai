#!/usr/bin/env bash
set -euo pipefail
# Deploy Dockge agent + stack symlinks on VM107 (Grafana / monitoring).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
bash "$REPO_ROOT/deploy/cluster-members/_common/install-dockge-agent-linux.sh" \
  deploy/cluster-members/monitor stacksmonitor.yml monitor
