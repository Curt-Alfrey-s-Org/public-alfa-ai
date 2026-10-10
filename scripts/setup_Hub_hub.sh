#!/usr/bin/env bash
set -euo pipefail

# Run ON hub to set up the centralized download hub for the ALFa AI cluster.
# Creates the shared folder structure, NFS export, aria2 RPC daemon, and clones the git repo.
#
# Supersedes the narrower setup_hub_nfs_models.sh (models-only).
#
# Usage (SSH into hub as a user with sudo):
#   sudo bash setup_hub_hub.sh
#   sudo bash setup_hub_hub.sh --skip-aria2    # skip aria2 install (already running)
#   sudo bash setup_hub_hub.sh --skip-git      # skip git clone (no internet or already cloned)
#
# Folder layout created (see docs/CLUSTER_SHARED_STORAGE.md for the full spec):
#   /mnt/hub/alfa-ai/
#     docker/registry/              pull-through docker registry mirror volume
#     docker/images/                prebuilt ALFa image tarballs (docker save)
#     docker/buildkit-cache/        docker buildx bake local cache
#     nvidia/drivers/{rtx-30xx,rtx-50xx-blackwell}/   NVIDIA driver installers
#     nvidia/cuda-toolkit/          CUDA host-side installers (optional)
#     nvidia/cudnn/                 cuDNN redistributables
#     ollama/models/                OLLAMA_MODELS blob+manifest store
#     ollama/installers/            OllamaSetup / ollama-linux binaries
#     hf/hub/                       HuggingFace HF_HOME cache (models--*/)
#     hf/tokens/                    per-node .env with HF_TOKEN (0600)
#     wheels/{cu124,cu128,cpu}/     pip wheelhouse for offline rebuilds
#     installers/{docker-desktop,wsl2-kernel,python}/   generic installers
#     aria2/{config,session,downloads-tmp}/   aria2 daemon working set
#     repo/                         live git clone of alfa-ai
#     smb-scratch/                  \\hub\alfa-ai\smb-scratch\ target (prune freely)

HUB_ROOT="/mnt/hub/alfa-ai"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARIA2_RPC_PORT=6800
ARIA2_RPC_KEY="${ARIA2_RPC_KEY:-}"   # required unless --skip-aria2 (no default)
GIT_REPO="operator@example.com:example/alfa-ai.git"
GIT_BRANCH="${GIT_BRANCH:-main}"
NFS_SUBNET="orchestrator/24"

SKIP_ARIA2=0
SKIP_GIT=0
for arg in "$@"; do
  case "$arg" in
    --skip-aria2) SKIP_ARIA2=1 ;;
    --skip-git)   SKIP_GIT=1 ;;
    -h|--help)    sed -n '1,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)            echo "Unknown: $arg" >&2; exit 1 ;;
  esac
done

echo "=== ALFa AI Cluster Hub Setup ==="
echo "Root: $HUB_ROOT"
echo ""

# ── 1. Directory structure ──────────────────────────────────────────────────

DIRS=(
  "$HUB_ROOT/docker/registry"
  "$HUB_ROOT/docker/images"
  "$HUB_ROOT/docker/buildkit-cache"
  "$HUB_ROOT/nvidia/drivers/rtx-30xx"
  "$HUB_ROOT/nvidia/drivers/rtx-50xx-blackwell"
  "$HUB_ROOT/nvidia/cuda-toolkit"
  "$HUB_ROOT/nvidia/cudnn"
  "$HUB_ROOT/ollama/models"
  "$HUB_ROOT/ollama/installers"
  "$HUB_ROOT/hf/hub"
  "$HUB_ROOT/hf/tokens"
  "$HUB_ROOT/wheels/cu124"
  "$HUB_ROOT/wheels/cu128"
  "$HUB_ROOT/wheels/cpu"
  "$HUB_ROOT/installers/docker-desktop"
  "$HUB_ROOT/installers/wsl2-kernel"
  "$HUB_ROOT/installers/python"
  "$HUB_ROOT/aria2/config"
  "$HUB_ROOT/aria2/session"
  "$HUB_ROOT/aria2/downloads-tmp"
  "$HUB_ROOT/repo"
  "$HUB_ROOT/smb-scratch"
)

for d in "${DIRS[@]}"; do
  if [[ ! -d "$d" ]]; then
    mkdir -p "$d"
    echo "  Created $d"
  fi
done

chown -R nobody:nogroup "$HUB_ROOT"
chmod -R 775 "$HUB_ROOT"
echo "Permissions set (nobody:nogroup, 775)."

# ── 2. NFS export ───────────────────────────────────────────────────────────

NFS_EXPORT="$HUB_ROOT $NFS_SUBNET(rw,sync,no_subtree_check,no_root_squash)"

if ! grep -qF "$HUB_ROOT" /etc/exports 2>/dev/null; then
  echo "$NFS_EXPORT" >> /etc/exports
  exportfs -ra
  echo "NFS export added: $NFS_EXPORT"
else
  echo "NFS export already present for $HUB_ROOT"
fi

# ── 3. aria2 RPC daemon ─────────────────────────────────────────────────────

if [[ "$SKIP_ARIA2" -eq 0 && -z "$ARIA2_RPC_KEY" ]]; then
  echo "ERROR: ARIA2_RPC_KEY is not set. Export a long random secret (openssl rand -hex 24) or pass --skip-aria2." >&2
  exit 1
fi
if [[ "$SKIP_ARIA2" -eq 0 ]]; then
  if ! command -v aria2c &>/dev/null; then
    echo "Installing aria2..."
    apt-get update -qq && apt-get install -y -qq aria2
  fi

  ARIA2_CONF="/etc/aria2/aria2.conf"
  mkdir -p /etc/aria2
  cat > "$ARIA2_CONF" <<CONF
dir=$HUB_ROOT/aria2/downloads-tmp
enable-rpc=true
rpc-listen-all=true
rpc-listen-port=$ARIA2_RPC_PORT
rpc-secret=$ARIA2_RPC_KEY
max-connection-per-server=16
split=16
min-split-size=10M
max-concurrent-downloads=3
continue=true
auto-file-renaming=false
allow-overwrite=false
file-allocation=falloc
log=/var/log/aria2.log
log-level=notice
CONF
  echo "aria2 config: $ARIA2_CONF"

  cat > /etc/systemd/system/aria2-rpc.service <<SVC
[Unit]
Description=aria2 Download Manager (JSON-RPC)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/aria2c --conf-path=$ARIA2_CONF
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC

  systemctl daemon-reload
  systemctl enable aria2-rpc
  systemctl restart aria2-rpc
  echo "aria2 RPC running on port $ARIA2_RPC_PORT"
else
  echo "Skipping aria2 (--skip-aria2)"
fi

# ── 4. Cache Ollama installer ────────────────────────────────────────────────

OLLAMA_INSTALLER="$HUB_ROOT/ollama/installers/install.sh"
if [[ ! -f "$OLLAMA_INSTALLER" ]]; then
  echo "Downloading Ollama installer..."
  mkdir -p "$(dirname "$OLLAMA_INSTALLER")"
  if [[ -f "$SCRIPT_DIR/lib/http_fetch.sh" ]]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/http_fetch.sh"
    if http_fetch_to "https://ollama.com/install.sh" "$OLLAMA_INSTALLER"; then
      chmod +x "$OLLAMA_INSTALLER"
      echo "Cached: $OLLAMA_INSTALLER"
    else
      echo "WARN: http_fetch_to failed for Ollama install.sh (try curl manually)."
    fi
  elif curl -fsSL https://ollama.com/install.sh -o "$OLLAMA_INSTALLER" 2>/dev/null; then
    chmod +x "$OLLAMA_INSTALLER"
    echo "Cached: $OLLAMA_INSTALLER"
  else
    echo "WARN: Could not download Ollama installer (no internet?). Members can download it themselves."
  fi
else
  echo "Ollama installer already cached: $OLLAMA_INSTALLER"
fi

# ── 5. Ollama models (download once, share via NFS) ──────────────────────────

OLLAMA_MODELS_DIR="$HUB_ROOT/ollama/models"
# April 2026 cluster rebalance — tiers 0/1/2 collapsed onto qwen3-coder:30b-a3b-q4_K_M
# (CPU MoE on hub). Embeddings stay pre-pulled on the hub for gaming-c + gaming-b.
# Override with OLLAMA_MODELS="tag1 tag2 ..." when a host needs a different set.
OLLAMA_MODELS_TO_PULL="${OLLAMA_MODELS:-qwen3-coder:30b-a3b-q4_K_M nomic-embed-text}"

if command -v ollama &>/dev/null; then
  export OLLAMA_MODELS="$OLLAMA_MODELS_DIR"
  echo "Pulling Ollama models to $OLLAMA_MODELS_DIR ..."
  for model in $OLLAMA_MODELS_TO_PULL; do
    echo "  Pulling $model ..."
    ollama pull "$model" 2>&1 || echo "  WARN: Failed to pull $model (try manually: OLLAMA_MODELS=$OLLAMA_MODELS_DIR ollama pull $model)"
  done
else
  echo "Ollama not installed on hub. Install it first to pre-download models:"
  echo "  bash $HUB_ROOT/installers/ollama/install.sh"
  echo "  OLLAMA_MODELS=$OLLAMA_MODELS_DIR ollama pull qwen3-coder:30b-a3b-q4_K_M"
fi

# ── 6. Git clone ─────────────────────────────────────────────────────────────

REPO_DIR="$HUB_ROOT/repo/alfa-ai"
if [[ "$SKIP_GIT" -eq 0 ]]; then
  if ! command -v git &>/dev/null; then
    echo "Installing git..."
    apt-get update -qq && apt-get install -y -qq git
  fi

  if [[ -d "$REPO_DIR/.git" ]]; then
    echo "Repo exists, pulling latest..."
    (cd "$REPO_DIR" && git pull --ff-only origin "$GIT_BRANCH" 2>&1) || echo "WARN: git pull failed; resolve manually."
  else
    echo "Cloning $GIT_REPO -> $REPO_DIR ..."
    git clone --branch "$GIT_BRANCH" "$GIT_REPO" "$REPO_DIR" 2>&1 || {
      echo "WARN: git clone failed. Ensure SSH key is installed on hub and added as a deploy key on GitHub."
      echo "  ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ''"
      echo "  cat ~/.ssh/id_ed25519.pub  # add to GitHub -> Settings -> Deploy keys"
    }
  fi
else
  echo "Skipping git clone (--skip-git)"
fi

# ── 7. Summary ───────────────────────────────────────────────────────────────

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Hub root:       $HUB_ROOT"
echo "NFS share:      $HUB_ROOT  (exported to $NFS_SUBNET)"
echo "aria2 RPC:      http://$(hostname -I | awk '{print $1}'):$ARIA2_RPC_PORT/jsonrpc  (secret: from ARIA2_RPC_KEY, not printed)"
echo "Git repo:       $REPO_DIR"
echo "Ollama install: $OLLAMA_INSTALLER"
echo ""
echo "Cluster members mount with:"
echo "  Linux:   sudo mount -t nfs hub:$HUB_ROOT /mnt/alfa"
echo "  Windows: net use Z: \\\\hub\\alfa-ai  (if SMB 'alfa-ai' share configured)"
echo ""
echo "Or run: bash scripts/mount_nfs_models.sh  (on each Linux member)"
