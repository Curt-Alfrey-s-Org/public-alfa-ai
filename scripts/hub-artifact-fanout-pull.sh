#!/usr/bin/env bash
# Hub artifact fan-out pull -- parallel per worker host, hub-first.
#
# Purpose: during SEED windows, each worker host pulls from the hub hub on
# its own LAN link. This uses aggregate cluster bandwidth (N x 1G paths).
# Do NOT run many parallel streams from ONE client to one file -- that still
# uses a single uplink.
#
# This script does NOT SSH across hosts (no nested SSH; hub is operator-only).
# Use --print-runbook for per-host one-liners the operator runs manually.
#
# Hub-first: workers never download artifacts >100 MB from the public internet
# when the hub has a copy. See docs/HUB_ARTIFACTS.md.
#
# Usage:
#   bash scripts/hub-artifact-fanout-pull.sh --print-runbook [gguf|docker|ollama|all]
#   bash scripts/hub-artifact-fanout-pull.sh --local gguf
#   bash scripts/hub-artifact-fanout-pull.sh --local docker
#   bash scripts/hub-artifact-fanout-pull.sh --local ollama
#
# --local runs pull helpers on THIS host only.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="$REPO_ROOT/deploy/cluster-members/_common"
G93="$REPO_ROOT/deploy/cluster-members/orchestrator"

usage() {
  cat <<'EOF'
hub-artifact-fanout-pull.sh -- hub-first parallel seed (one pull per host)

Modes:
  --print-runbook [artifact]   Print operator one-liners per host (default artifact: all)
  --local <artifact>           Run pull on this host only (gguf|docker|ollama)

Artifacts:
  gguf     inference / llama.cpp GGUF to local MODELS_DIR
  docker   alfa-llamacpp-rpc:cuda128 tarball from hub
  ollama   Ollama tags via pull-models.sh hub merge
  all      All of the above where applicable

Schedule fan-out outside inference decode peaks. See docs/LAN_BANDWIDTH_UTILIZATION.md.
EOF
}

artifact="${2:-all}"

_print_runbook() {
  local art="${1:-all}"
  echo "=== Hub artifact fan-out runbook (operator: one command per host) ==="
  echo "Artifact scope: $art"
  echo "Run pulls in parallel across hosts (separate terminals), not multi-stream from one client."
  echo ""

  if [[ "$art" == "all" || "$art" == "docker" ]]; then
    echo "--- Docker image: alfa-llamacpp-rpc:cuda128 ---"
    echo "From inference (operator):"
    echo "  cd ~/alfa-ai && bash deploy/cluster-members/_common/load-llamacpp-rpc-from-hub.sh"
    echo "From pool-opt-in (operator):"
    echo "  cd ~/alfa-ai && bash deploy/cluster-members/_common/load-llamacpp-rpc-from-hub.sh"
    echo "From orchestrator (PowerShell as operator):"
    echo "  powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\operator\\alfa-ai\\deploy\\cluster-members\\operator-93\\deploy.ps1"
    echo "  (deploy.ps1 loads hub tarballs via load-hub-tarball.ps1 / Get-AlfaWindowsCacheRoot\\docker-images)"
    echo "From hub (operator) -- build/publish only, not worker load:"
    echo "  cd /mnt/hub/alfa-ai/repo/alfa-ai && sudo bash scripts/build-llamacpp-rpc-cuda128-on-hub.sh"
    echo ""
  fi

  if [[ "$art" == "all" || "$art" == "gguf" ]]; then
    echo "--- GGUF: Qwen3.8-27B-Q8_0 (local MODELS_DIR before pool start) ---"
    echo "From hub (operator) -- seed to hub once:"
    echo "  cd /mnt/hub/alfa-ai/repo/alfa-ai && sudo inference_GGUF_PROFILE=q8 bash scripts/hub_hub_models.sh pull gguf27"
    echo "From inference (operator) -- NFS mount then local cache:"
    echo "  cd ~/alfa-ai && bash scripts/mount_nfs_models.sh"
    echo "  rsync -a --progress /mnt/cluster/llama-cpp/models/Qwen3.8-27B-Q8_0.gguf \$HOME/alfa-ai-cache/llama-cpp/models/"
    echo "From orchestrator (PowerShell as operator):"
    echo "  powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\operator\\alfa-ai\\deploy\\cluster-members\\operator-93\\sync-frontier-code-gguf-from-hub.ps1"
    echo "From pool-opt-in (operator) -- if shard needs local copy:"
    echo "  cd ~/alfa-ai && bash scripts/mount_nfs_models.sh"
    echo "  rsync -a /mnt/cluster/llama-cpp/models/Qwen3.8-27B-Q8_0.gguf \$HOME/alfa-ai-cache/llama-cpp/models/ 2>/dev/null || true"
    echo ""
  fi

  if [[ "$art" == "all" || "$art" == "ollama" ]]; then
    echo "--- Ollama tags (hub merge first) ---"
    echo "From gaming-c (operator):"
    echo "  cd /path/to/alfa-ai && bash deploy/cluster-members/_common/pull-models.sh quality"
    echo "From gaming-b (operator):"
    echo "  cd /path/to/alfa-ai && bash deploy/cluster-members/_common/pull-models.sh reranker"
    echo "From orchestrator (PowerShell as operator):"
    echo "  powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\operator\\alfa-ai\\deploy\\cluster-members\\_common\\pull-models.ps1 -Role Speed"
    echo ""
  fi

  echo "Verify hub presence: bash scripts/verify_hub_hub.sh"
  echo "Full policy: docs/HUB_ARTIFACTS.md and docs/LAN_BANDWIDTH_UTILIZATION.md"
}

_local_gguf() {
  echo "== Local GGUF pull on $(hostname -s) =="
  if [[ -f "$G93/sync-frontier-code-gguf-from-hub.ps1" ]] && command -v powershell.exe >/dev/null 2>&1; then
    echo "WARN: Windows orchestrator should use sync-frontier-code-gguf-from-hub.ps1, not this Linux path." >&2
  fi
  if ! mountpoint -q /mnt/cluster 2>/dev/null; then
    if [[ -f "$REPO_ROOT/scripts/mount_nfs_models.sh" ]]; then
      bash "$REPO_ROOT/scripts/mount_nfs_models.sh"
    else
      echo "ERROR: /mnt/cluster not mounted and mount_nfs_models.sh missing." >&2
      exit 1
    fi
  fi
  local src="/mnt/cluster/llama-cpp/models/Qwen3.8-27B-Q8_0.gguf"
  local dest_dir="${ALFA_LOCAL_GGUF_DIR:-$HOME/alfa-ai-cache/llama-cpp/models}"
  mkdir -p "$dest_dir"
  if [[ ! -f "$src" ]]; then
    echo "ERROR: Hub GGUF missing at $src. Seed on hub: inference_GGUF_PROFILE=q8 hub_hub_models.sh pull gguf27" >&2
    exit 1
  fi
  if [[ -f "$dest_dir/Qwen3.8-27B-Q8_0.gguf" ]]; then
    local sz
    sz="$(stat -c%s "$dest_dir/Qwen3.8-27B-Q8_0.gguf" 2>/dev/null || echo 0)"
    if [[ "$sz" -gt 25000000000 ]]; then
      echo "Already present: $dest_dir/Qwen3.8-27B-Q8_0.gguf"
      exit 0
    fi
  fi
  echo "rsync $src -> $dest_dir/"
  rsync -a --progress "$src" "$dest_dir/"
  echo "Done: $dest_dir/Qwen3.8-27B-Q8_0.gguf"
}

_local_docker() {
  echo "== Docker RPC image pull on $(hostname -s) =="
  if [[ ! -f "$COMMON/load-llamacpp-rpc-from-hub.sh" ]]; then
    echo "ERROR: $COMMON/load-llamacpp-rpc-from-hub.sh not found." >&2
    exit 1
  fi
  bash "$COMMON/load-llamacpp-rpc-from-hub.sh"
}

_local_ollama() {
  echo "== Ollama hub merge on $(hostname -s) =="
  local role="${ALFA_PULL_MODELS_ROLE:-quality}"
  if [[ ! -f "$COMMON/pull-models.sh" ]]; then
    echo "ERROR: $COMMON/pull-models.sh not found." >&2
    exit 1
  fi
  bash "$COMMON/pull-models.sh" "$role"
}

mode="${1:-}"
case "$mode" in
  --print-runbook)
    case "$artifact" in
      all|gguf|docker|ollama) _print_runbook "$artifact" ;;
      *) echo "ERROR: unknown artifact '$artifact'. Use gguf|docker|ollama|all." >&2; exit 2 ;;
    esac
    ;;
  --local)
    case "$artifact" in
      gguf)   _local_gguf ;;
      docker) _local_docker ;;
      ollama) _local_ollama ;;
      *)
        echo "ERROR: --local requires artifact gguf|docker|ollama." >&2
        usage
        exit 2
        ;;
    esac
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "ERROR: unknown mode '${mode:-}'. Use --print-runbook or --local." >&2
    usage
    exit 2
    ;;
esac
