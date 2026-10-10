#!/usr/bin/env bash
# ai-148: install NVIDIA driver, Docker Engine, nvidia-container-toolkit.
#
# Run on inference after bond0 is up (console or SSH):
#   sudo bash bootstrap-linux-prereqs.sh
#
# Reboot when prompted if the driver was newly installed, then re-run the
# verification block at the bottom (or run: sudo bash bootstrap-linux-prereqs.sh --verify-only)
set -euo pipefail

VERIFY_ONLY=0
if [[ "${1:-}" == "--verify-only" ]]; then
  VERIFY_ONLY=1
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: run as root (sudo bash $0)" >&2
  exit 1
fi

DEPLOY_USER="${SUDO_USER:-operator}"

run_verify() {
  echo "== Verification =="
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi -L
    nvidia-smi --query-gpu=name,driver_version,compute_cap,memory.total --format=csv
  else
    echo "FAIL: nvidia-smi missing" >&2
    return 1
  fi
  if docker info >/dev/null 2>&1; then
    echo "OK: docker info"
  else
    echo "FAIL: docker not running" >&2
    return 1
  fi
  if docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1; then
    echo "OK: GPU inside container"
  else
    echo "WARN: container GPU smoke failed (fix nvidia-container-toolkit)" >&2
    return 1
  fi
  return 0
}

if [[ "$VERIFY_ONLY" -eq 1 ]]; then
  run_verify
  exit $?
fi

echo "== ai-148 Linux prereqs (NVIDIA + Docker + container toolkit) =="

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  ca-certificates curl gnupg lsb-release \
  ubuntu-drivers-common \
  nfs-common \
  git

echo "== NVIDIA driver (ubuntu-drivers) =="
if command -v nvidia-smi >/dev/null 2>&1; then
  echo "  nvidia-smi already present; skipping driver install"
else
  REC="$(ubuntu-drivers devices 2>/dev/null | awk '/recommended/ {print $3; exit}')"
  if [[ -z "$REC" ]]; then
    REC="nvidia-driver-550"
    echo "  WARN: no recommended driver line; trying $REC"
  else
    echo "  Installing recommended: $REC"
  fi
  apt-get install -y -qq "$REC"
  NEED_REBOOT=1
fi

echo "== Docker Engine =="
if command -v docker >/dev/null 2>&1; then
  echo "  docker already installed"
else
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "${VERSION_CODENAME:-$VERSION_ID}") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
fi

usermod -aG docker "$DEPLOY_USER" 2>/dev/null || true

echo "== NVIDIA Container Toolkit =="
if dpkg -l nvidia-container-toolkit 2>/dev/null | grep -q ^ii; then
  echo "  nvidia-container-toolkit already installed"
else
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update -qq
  apt-get install -y -qq nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker
fi

if [[ "${NEED_REBOOT:-0}" -eq 1 ]]; then
  echo ""
  echo "REBOOT REQUIRED for NVIDIA driver. After reboot, run:"
  echo "  sudo bash $0 --verify-only"
  echo "  newgrp docker   # or log out/in as $DEPLOY_USER"
  exit 0
fi

run_verify
echo ""
echo "Prereqs OK. Next as $DEPLOY_USER:"
echo "  git clone https://github.com/example/alfa-ai.git ~/alfa-ai   # if not cloned"
echo "  bash ~/alfa-ai/scripts/mount_nfs_models.sh"
echo "  Create ~/alfa-ai/deploy/cluster-members/inference-coordinator/.env.worker on this host (gitignored)."
echo "  # edit .env.worker: HF_TOKEN + ALFA_WORKER_HEARTBEAT_TOKEN"
echo "  bash ~/alfa-ai/deploy/cluster-members/inference-coordinator/deploy.sh"
