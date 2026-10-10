#!/usr/bin/env bash
set -euo pipefail

# Deploy script for ai-148 (Ubuntu Linux llama.cpp RPC / frontier-code host).
#
# Usage (SSH to inference):
#   bash deploy/cluster-members/inference-coordinator/deploy.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_REPO_DIR:-$HOME/alfa-ai}"
DEPLOY_DIR="$REPO_DIR/deploy"
CLUSTER_COMMON="$DEPLOY_DIR/cluster/_common"

MACHINE_NAME="ai-148"
MACHINE_IP="${ALFA_MACHINE_IP:-orchestrator}"

echo "== ALFa AI inference deploy: llama.cpp RPC host (Linux) =="
echo "  Repo:  $REPO_DIR"
echo "  Host:  $MACHINE_NAME / $MACHINE_IP"
echo ""

docker_wrap() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  elif sudo docker info >/dev/null 2>&1; then
    sudo docker "$@"
  else
    echo "ERROR: Docker is not reachable. Install Docker Engine first." >&2
    exit 1
  fi
}

if [[ -f "$CLUSTER_COMMON/nvidia_preflight.sh" ]]; then
  # shellcheck source=/dev/null
  source "$CLUSTER_COMMON/nvidia_preflight.sh"
  ALFA_REPO_ROOT="$REPO_DIR" alfa_nvidia_preflight --role gpu-worker || {
    echo "ERROR: nvidia preflight failed." >&2
    exit 1
  }
fi
if [[ -f "$CLUSTER_COMMON/configure-docker-mirror.sh" ]]; then
  ALFA_REGISTRY_MIRROR="http://hub" \
    bash "$CLUSTER_COMMON/configure-docker-mirror.sh" || \
    echo "WARN: mirror configuration skipped"
fi

if [[ -d "$REPO_DIR/.git" ]]; then
  echo "== Git pull =="
  (cd "$REPO_DIR" && git pull --ff-only) || echo "WARN: git pull failed."
  echo ""
fi

if [[ -x "$REPO_DIR/scripts/mount_nfs_models.sh" ]]; then
  bash "$REPO_DIR/deploy/cluster-members/_common/preflight-nfs-hub.sh"
  echo ""
fi

echo "== Dockge agent =="
DOCKGE_ENV="$SCRIPT_DIR/.env.dockge"
AGENT_COMPOSE="$REPO_DIR/deploy/cluster-members/apps/docker-compose.dockge-agent.yml"
STACKS_DIR="/opt/stacks"
mkdir -p "$STACKS_DIR" 2>/dev/null || sudo mkdir -p "$STACKS_DIR" 2>/dev/null || true
if [[ -f "$AGENT_COMPOSE" && -f "$DOCKGE_ENV" ]]; then
  ln -sfn "$REPO_DIR/deploy/cluster-members/apps" "$STACKS_DIR/dockge-agent" 2>/dev/null \
    || sudo ln -sfn "$REPO_DIR/deploy/cluster-members/apps" "$STACKS_DIR/dockge-agent" 2>/dev/null || true
  AGENT_CWD="$REPO_DIR/deploy/cluster-members/apps"
  [[ -L "$STACKS_DIR/dockge-agent" ]] && AGENT_CWD="$STACKS_DIR/dockge-agent"
  if ! docker_wrap network inspect alfa-shared-network >/dev/null 2>&1; then
    docker_wrap network create --driver bridge alfa-shared-network >/dev/null
  fi
  cd "$AGENT_CWD"
  docker_wrap compose -f docker-compose.dockge-agent.yml --env-file "$DOCKGE_ENV" up -d 2>&1 | sed 's/^/  /' || \
    echo "  WARN: dockge agent compose up failed"
  echo "  Register on orchestrator: http://${MACHINE_IP}:5001/"
else
  echo "  SKIP: dockge agent compose or .env.dockge missing"
fi
echo ""

echo "== inference deploy complete =="
echo "  RPC:     bash deploy/cluster-members/inference-coordinator/deploy-grev27-pool-coordinator.sh (orchestrator-owned)"
echo "  Verify:  curl -fsS http://127.0.0.1:31360/health"
echo ""
