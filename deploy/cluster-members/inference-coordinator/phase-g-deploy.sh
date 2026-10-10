#!/usr/bin/env bash
# Phase G on inference: Ollama 35B on RTX 3060 + rpc-server on RTX 3050 for 27B code pool.
#
# Usage (SSH to inference):
#   bash deploy/cluster-members/inference-coordinator/phase-g-deploy.sh
set -euo pipefail

REPO_DIR="${ALFA_REPO_DIR:-$HOME/alfa-ai}"
COMMON="$REPO_DIR/deploy/cluster-members/_common"

echo "== Phase G (inference): pull qwen3.6:35b-a3b (3060 Ollama) =="
if command -v ollama >/dev/null 2>&1; then
  bash "$COMMON/pull-models.sh" speed
else
  echo "WARN: ollama not on PATH"
fi

echo ""
echo "== Phase G (inference): rpc-server on RTX 3050 :31357 (CUDA index 0) =="
bash "$REPO_DIR/deploy/cluster-members/inference-coordinator/start-code27-rpc-shard.sh"

echo ""
echo "== Phase G (inference): pin Ollama to RTX 3060 (GPU index 1) =="
sudo mkdir -p /etc/systemd/system/ollama.service.d
printf '[Service]\nEnvironment=OLLAMA_VISIBLE_DEVICES=1\n' | sudo tee /etc/systemd/system/ollama.service.d/gpu.conf >/dev/null
sudo systemctl daemon-reload
sudo systemctl restart ollama
sleep 3

echo ""
echo "== Phase G (inference): stop rpc-server on :31356 (3060 reserved for Ollama) =="
docker stop llamacpp-rpc-148-gpu0 2>/dev/null || true

echo ""
echo "Done. From orchestrator: nc -zv orchestrator 31357"
echo "Ollama smoke: curl -fsS http://127.0.0.1:11434/api/tags | grep 35b"
