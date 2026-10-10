#!/usr/bin/env bash
# Install Docker Engine + NVIDIA Container Toolkit inside WSL2 Ubuntu (no Docker Desktop).
#
# Run INSIDE WSL as root or with sudo:
#   bash deploy/cluster-members/_common/wsl-docker/install-docker-engine-in-wsl.sh
#
# Prerequisites (Windows, Administrator):
#   - WSL2 with Ubuntu (wsl --install -d Ubuntu)
#   - NVIDIA Windows driver supporting WSL GPU
#   - /etc/wsl.conf: [boot] systemd=true  (then wsl --shutdown from PowerShell)
#
# References:
#   https://docs.docker.com/engine/install/ubuntu/
#   https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html
set -euo pipefail

if ! grep -qi microsoft /proc/version 2>/dev/null; then
  echo "WARN: this script targets WSL2; /proc/version does not mention Microsoft." >&2
fi

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Re-run with sudo: sudo bash $0" >&2
  exit 1
fi

section() { echo ""; echo "== $* =="; }

section "Enable systemd in WSL (if missing)"
if [[ ! -f /etc/wsl.conf ]] || ! grep -q 'systemd=true' /etc/wsl.conf 2>/dev/null; then
  cat >> /etc/wsl.conf <<'EOF'

[boot]
systemd=true
EOF
  echo "Added systemd=true to /etc/wsl.conf — run 'wsl --shutdown' from Windows, then re-open Ubuntu."
fi

section "Docker apt repository"
apt-get update -qq
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
fi
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${VERSION_CODENAME:-jammy}") stable" \
  > /etc/apt/sources.list.d/docker.list

section "Install Docker Engine + compose plugin"
apt-get update -qq
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

section "Add current login user to docker group"
target_user="${SUDO_USER:-${USER:-}}"
if [[ -n "$target_user" && "$target_user" != root ]]; then
  usermod -aG docker "$target_user" || true
  echo "Added $target_user to docker group (log out/in to WSL session)."
fi

section "Log rotation + registry mirror (anti-bloat + hub hub)"
mkdir -p /etc/docker
mirror_host="${ALFA_REGISTRY_MIRROR:-http://hub}"
mirror_no_scheme="${mirror_host#http://}"; mirror_no_scheme="${mirror_no_scheme#https://}"
if command -v jq &>/dev/null && [[ -f /etc/docker/daemon.json ]]; then
  jq --arg m "$mirror_no_scheme" \
    '. + {"log-driver":"json-file","log-opts":{"max-size":"50m","max-file":"3"},"registry-mirrors":["'"$mirror_host"'"],"insecure-registries":[$m]}' \
    /etc/docker/daemon.json > /tmp/daemon.json && mv /tmp/daemon.json /etc/docker/daemon.json
else
  cat > /etc/docker/daemon.json <<JSON
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" },
  "registry-mirrors": ["$mirror_host"],
  "insecure-registries": ["$mirror_no_scheme"]
}
JSON
fi

section "NVIDIA Container Toolkit"
wsl_has_nvidia() {
  command -v nvidia-smi &>/dev/null && return 0
  [[ -x /usr/bin/nvidia-smi ]] && return 0
  [[ -e /dev/nvidiactl || -e /dev/nvidia0 ]] && return 0
  [[ -d /usr/lib/wsl/lib ]] && ls /usr/lib/wsl/lib/libnvidia-ml.so* &>/dev/null && return 0
  return 1
}

if wsl_has_nvidia; then
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --batch --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  arch="$(dpkg --print-architecture)"
  cat > /etc/apt/sources.list.d/nvidia-container-toolkit.list <<EOF
deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://nvidia.github.io/libnvidia-container/stable/deb/${arch} /
EOF
  apt-get update -qq
  apt-get install -y nvidia-container-toolkit
  nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml 2>/dev/null || true
  nvidia-ctk runtime configure --runtime=docker
else
  echo "WARN: no NVIDIA GPU visible in WSL — install Windows NVIDIA driver + reboot; re-run this script."
fi

section "Weekly Docker cleanup cron (builder + system prune)"
# Staggered Sunday schedule per docs/operations/DOCKER_HOST_CLEANUP.md
# Prefer shared installer when repo is mounted; else write a safe default (Sun 05:00).
_REPO_CLEANUP_INSTALL=""
for _cand in \
  /mnt/c/Users/operator/alfa-ai/deploy/cluster-members/_common/install-docker-cleanup-cron.sh \
  /mnt/d/Users/operator/alfa-ai/deploy/cluster-members/_common/install-docker-cleanup-cron.sh
do
  if [[ -f "$_cand" ]]; then
    _REPO_CLEANUP_INSTALL="$_cand"
    break
  fi
done
if [[ -n "$_REPO_CLEANUP_INSTALL" ]]; then
  ALFA_CLEANUP_HOST="${ALFA_CLEANUP_HOST:-93}" bash "$_REPO_CLEANUP_INSTALL" || true
else
  cat > /etc/cron.d/alfa-docker-cleanup <<'EOF'
# alfa docker host cleanup - docs/operations/DOCKER_HOST_CLEANUP.md
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 5 * * 0 root /usr/bin/docker builder prune -af --filter "until=168h" >/dev/null 2>&1; /usr/bin/docker system prune -af --filter "until=168h" >/dev/null 2>&1
EOF
  chmod 644 /etc/cron.d/alfa-docker-cleanup
  rm -f /etc/cron.d/docker-cleanup
fi

section "Start Docker"
if systemctl is-system-running &>/dev/null; then
  systemctl enable --now docker
else
  echo "WARN: systemd not running — enable [boot] systemd=true in /etc/wsl.conf and wsl --shutdown"
  service docker start || true
fi

section "Smoke test"
docker info >/dev/null && echo "OK: docker info"
if docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi &>/dev/null; then
  echo "OK: GPU in container"
else
  echo "WARN: GPU container test failed — check nvidia-smi in WSL and toolkit config."
fi

echo ""
echo "Done. Verify from Windows PowerShell (repo user, no admin required):"
echo "  wsl -d Ubuntu docker ps"
echo "  wsl -d Ubuntu nvidia-smi"
echo "  wsl -d Ubuntu docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi"
