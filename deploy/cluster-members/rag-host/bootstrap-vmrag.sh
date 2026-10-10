#!/usr/bin/env bash
# Fresh VM110 bootstrap — CPU RAG host (embed :11435 + rerank :8360).
#
# Run as operator on rag after Ubuntu + Docker (CPU-only; no NVIDIA passthrough):
#   bash ~/alfa-ai/deploy/cluster-members/rag-host/bootstrap-vm110.sh
#
# Proxmox prerequisites (operator, before this script):
#   - CPU type: host (AVX2 required for llama-server rerank)
#   - LAN IP: orchestrator, user: operator
#   - SSH: operator@orchestrator key via install-agent-ssh-from-93.sh
set -euo pipefail

REPO_URL="${ALFA_AI_REPO_URL:-https://github.com/example/alfa-ai.git}"
REPO_DIR="${ALFA_AI_REPO:-$HOME/alfa-ai}"
MEMBER_DIR="$REPO_DIR/deploy/cluster-members/rag-host"
hub_IP="${hub_IP:-orchestrator}"

die() { echo "ERROR: $*" >&2; exit 1; }

echo "== VM110 bootstrap (CPU RAG host) =="

# Cloned VMs often ship as hostname 101 -- align with LAN rag.
if [[ "$(hostname -s)" != "110" ]]; then
  if sudo -n hostnamectl set-hostname 110 2>/dev/null; then
    echo "  OK hostname -> 110"
    if grep -q $'\t101$' /etc/hosts 2>/dev/null; then
      sudo sed -i 's/\t101$/\t110/' /etc/hosts
    fi
  else
    echo "WARN: run manually: sudo hostnamectl set-hostname 110" >&2
  fi
fi

if ! grep -q avx2 /proc/cpuinfo 2>/dev/null; then
  echo "WARN: CPU has no AVX2 -- set Proxmox VM CPU type to 'host' and reboot before rerank will work." >&2
fi

command -v docker >/dev/null 2>&1 || die "docker not installed -- install Docker Engine first"
docker info >/dev/null 2>&1 || die "docker daemon not running -- sudo systemctl enable --now docker"
echo "  OK Docker (CPU-only rag -- no NVIDIA required)"

if [[ ! -d "$REPO_DIR/.git" ]]; then
  echo "== git clone $REPO_URL -> $REPO_DIR =="
  git clone "$REPO_URL" "$REPO_DIR"
fi
cd "$REPO_DIR"
git fetch origin main
git reset --hard origin/main
echo "  OK repo at $(git log -1 --oneline)"

if [[ -x "$REPO_DIR/scripts/mount_nfs_models.sh" ]]; then
  hub_IP="$hub_IP" bash "$REPO_DIR/scripts/mount_nfs_models.sh" || true
fi

echo "== deploy RAG (embed + rerank) =="
bash "$MEMBER_DIR/operator-cluster-110.sh" start-rag

echo ""
echo "== VM110 bootstrap complete =="
echo "  embed:  http://127.0.0.1:11435/api/tags"
echo "  rerank: http://127.0.0.1:8360/health"
echo ""
echo "Production still uses inference until Phase C cutover:"
echo "  docs/RAG_148_TO_110_MIGRATION.md"
echo ""
echo "Staging verify from inference hub:"
echo "  RAG_SIDECARS_ENV=deploy/cluster-members/_common/rag-sidecarsrag-staging.env \\"
echo "    RAG_REQUIRE_RERANK=1 bash deploy/cluster-members/_common/verify-rag-sidecars.sh"
