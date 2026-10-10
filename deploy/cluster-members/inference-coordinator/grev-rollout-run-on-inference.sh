#!/usr/bin/env bash
# G-rev rollout helper -- run on inference (ai-148). Deploys local dual-GPU 27B :31358.
set -euo pipefail

REPO="${ALFA_REPO_DIR:-$HOME/alfa-ai}"
cd "$REPO"
git pull --ff-only origin main 2>/dev/null || true

bash "$REPO/deploy/cluster-members/inference-coordinator/deploy-grev27-local.sh"
echo "G-rev inference startup complete -- verify: curl http://127.0.0.1:31358/health"
