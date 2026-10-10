#!/usr/bin/env bash
# Fresh VM100 bootstrap — inference rpc-server shard host (:31354 on GTX 1660 Super).
# RAG (embed/rerank) is NOT on this host any more: it runs on rag. Brain + DB on hub.
#
# Run as operator on a new VM100 guest (45 GB disk is enough):
#   curl -fsSL https://raw.githubusercontent.com/example/alfa-ai/main/deploy/cluster-members/pool-shard-opt-in/bootstrap-vm100.sh -o /tmp/bootstrap-vm100.sh
#   bash /tmp/bootstrap-vm100.sh
#
# Or after git clone:
#   bash ~/alfa-ai/deploy/cluster-members/pool-shard-opt-in/bootstrap-vm100.sh
#
# Proxmox prerequisites (operator, before this script):
#   - GTX 1660 Super GPU passthrough
#   - CPU type: host (AVX2 required by llama.cpp builds)
#   - LAN IP: orchestrator, user: operator
#   - SSH: operator@orchestrator key in ~/.ssh/authorized_keys
set -euo pipefail

REPO_URL="${ALFA_AI_REPO_URL:-https://github.com/example/alfa-ai.git}"
REPO_DIR="${ALFA_AI_REPO:-$HOME/alfa-ai}"
MEMBER_DIR="$REPO_DIR/deploy/cluster-members/pool-shard-opt-in"
hub_IP="${hub_IP:-orchestrator}"

die() { echo "ERROR: $*" >&2; exit 1; }

echo "== VM100 bootstrap (inference shard host) =="

if ! grep -q avx2 /proc/cpuinfo 2>/dev/null; then
  echo "WARN: CPU has no AVX2 — set Proxmox VM CPU type to 'host' and reboot." >&2
fi

command -v docker >/dev/null 2>&1 || die "docker not installed — install Docker Engine first"
docker info >/dev/null 2>&1 || die "docker daemon not running — sudo systemctl enable --now docker"

if ! command -v nvidia-smi >/dev/null 2>&1; then
  die "nvidia-smi missing — install NVIDIA driver + reboot (see docs/DOCKGE_100_OPERATOR.md)"
fi
nvidia-smi >/dev/null 2>&1 || die "nvidia-smi failed — fix GPU passthrough / driver"

if ! docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1; then
  die "Docker GPU smoke failed — install nvidia-container-toolkit and restart docker"
fi
echo "  OK GPU + Docker"

if [[ ! -d "$REPO_DIR/.git" ]]; then
  echo "== git clone $REPO_URL -> $REPO_DIR =="
  git clone "$REPO_URL" "$REPO_DIR"
fi
cd "$REPO_DIR"
git fetch origin main
git reset --hard origin/main
echo "  OK repo at $(git log -1 --oneline)"

mkdir -p "$MEMBER_DIR"
if [[ ! -f "$MEMBER_DIR/.env.dockge" ]] && [[ -f "$MEMBER_DIR/env.dockge.example" ]]; then
  cp "$MEMBER_DIR/env.dockge.example" "$MEMBER_DIR/.env.dockge"
  echo "  created $MEMBER_DIR/.env.dockge (optional Dockge agent)"
fi

if [[ -x "$REPO_DIR/scripts/mount_nfs_models.sh" ]]; then
  hub_IP="$hub_IP" bash "$REPO_DIR/scripts/mount_nfs_models.sh" || true
fi

echo "== deploy inference rpc-server shard (:31354) =="
SKIP_PULL=1 bash "$MEMBER_DIR/operator-cluster-100.sh" start-shard

echo ""
echo "== VM100 bootstrap complete =="
echo "  shard:  nc -zv 127.0.0.1 31354"
echo "  RAG is on rag (hub deploy/.env: EMBED_BASE_URL=http://orchestrator,"
echo "    RERANK_BASE_URL=http://orchestrator) — nothing to set for pool-opt-in."
echo "  Add the pool-opt-in shard to deploy/llamacpp-rpc/inference-shards.env if it is not listed,"
echo "  then do one full cluster stop/start from orchestrator (see README.md)."